;;; mega-dap.el --- Debugging through a debug adapter  -*- lexical-binding: t; -*-

;;; Commentary:

;; A debug adapter is a debugger that talks in messages instead of in a
;; terminal: "stopped at this line", "these are the local variables".  gdb
;; has been one since version 14 (`gdb -i=dap').  That matters most where a
;; terminal is awkward: inside a dev container.  There Emacs's own gdb
;; interface can only show a console; through the adapter MEGA shows the
;; line, the stack and the variables.
;;
;; You do not call anything here by name.  The debugger keys of
;; mega-debug.el (C-c g ...) use it when `mega-debug-backend' says so, which
;; by default is: in a container, when the adapter is there.
;;
;;   C-c g b   breakpoint on this line, or off again.  Works before the
;;             debugger is started; breakpoints are MEGA's and outlive it.
;;   C-c g g   start.  The program runs to the first breakpoint.
;;   C-c g n / s / f / c   over / into / out / continue
;;   C-c g < / >           up / down the stack; the variables follow
;;   C-c g p   the value of the expression at point, or of the region
;;   C-c g q   stop
;;
;; A window below shows why the program stopped, the stack, the variables
;; of the selected frame, and what the program printed.
;;
;; How it is built.  Three layers, each testable without the next:
;;
;; * The wire: `mega-dap-encode' and `mega-dap-take' turn messages into
;;   bytes and back.  Nothing else knows about framing.
;;
;; * The session: what was asked, what is known (state, stack, variables).
;;   Everything is asynchronous: a key sends a request and returns; the
;;   answer arrives through the process filter.  No command waits.
;;
;; * The display: `mega-dap-info-lines' is a plain function from what is
;;   known to the lines shown.
;;
;; There is one session at a time.  File names cross the container boundary
;; in both directions and are translated by mega-exec, like everywhere else.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)

(defface mega-dap-breakpoint '((t :inherit error :inverse-video t))
  "A line with a breakpoint on it."
  :group 'mega)

(defface mega-dap-current '((t :inherit highlight))
  "The line the program is stopped at."
  :group 'mega)

(defvar mega-dap-adapters
  '((rust-gdb :command ("rust-gdb" "-i=dap") :version ("rust-gdb" "--version") :minimum 14)
    (gdb      :command ("gdb" "-i=dap")      :version ("gdb" "--version")      :minimum 14))
  "The debug adapters MEGA can start: (NAME PROPERTY VALUE...).
:command is the argument list that starts one talking on its standard
input and output.  :version, with :minimum, is a command whose first
line of output must hold a version number at least that large.")

(defvar mega-dap-languages
  '((rust rust-gdb gdb)
    (native gdb))
  "Which adapters to try for a language, in order: (LANGUAGE NAME...).")

;;;; The wire

(defun mega-dap-encode (message)
  "MESSAGE, a plist, as the bytes that go to the adapter."
  (let ((body (encode-coding-string (json-serialize message) 'utf-8 t)))
    (concat (format "Content-Length: %d\r\n\r\n" (length body)) body)))

(defun mega-dap-take (buffer)
  "Remove the complete messages at the start of BUFFER and return them.
BUFFER holds the bytes received so far; a message that has not arrived
whole is left there.  Each message is a plist."
  (with-current-buffer buffer
    (let ((messages nil) (more t))
      (while more
        (goto-char (point-min))
        ;; A header ends at the first empty line, and at no other: the body
        ;; of one message is followed at once by the header of the next.
        (if (not (search-forward "\r\n\r\n" nil t))
            (setq more nil)
          (let* ((start (point))
                 (length (progn
                           (goto-char (point-min))
                           (and (re-search-forward "Content-Length: *\\([0-9]+\\)\r\n"
                                                   start t)
                                (string-to-number (match-string 1))))))
            (cond ((null length)
                   ;; Not a header at all: something printed in between.
                   (delete-region (point-min) start))
                  ((> (+ start length) (point-max))
                   (setq more nil))
                  (t
                   (let ((text (decode-coding-string
                                (buffer-substring start (+ start length)) 'utf-8)))
                     (delete-region (point-min) (+ start length))
                     (push (json-parse-string text :object-type 'plist :array-type 'list
                                              :null-object nil :false-object nil)
                           messages)))))))
      (nreverse messages))))

;;;; Breakpoints
;;
;; They belong to MEGA, not to a session: set them before starting, and
;; they are still there after the debugger has gone.  In a buffer each is an
;; overlay, which moves with the text as you edit; the table below is what
;; is known about files that are not open.

(defvar mega-dap-breakpoints nil
  "Breakpoints by file: an alist (FILE . LINES), lines ascending.")

(defun mega-dap--overlays (&optional start end)
  "The breakpoint overlays of the current buffer, between START and END."
  (seq-filter (lambda (overlay) (overlay-get overlay 'mega-dap-breakpoint))
              (overlays-in (or start (point-min)) (or end (point-max)))))

(defun mega-dap--mark (line)
  "Put a breakpoint overlay on LINE of the current buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- line))
      (let ((overlay (make-overlay (line-beginning-position)
                                   (min (point-max) (1+ (line-end-position)))
                                   nil t nil)))
        (overlay-put overlay 'mega-dap-breakpoint t)
        (overlay-put overlay 'face 'mega-dap-breakpoint)
        (overlay-put overlay 'evaporate t)))))

(defun mega-dap-lines (file)
  "The lines of FILE that have a breakpoint, ascending.
For a file that is open, this is where its overlays are now."
  (let ((buffer (get-file-buffer file)))
    (if (not buffer)
        (cdr (assoc file mega-dap-breakpoints))
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (let ((lines (sort (delete-dups
                              (mapcar (lambda (overlay)
                                        (line-number-at-pos (overlay-start overlay)))
                                      (mega-dap--overlays)))
                             #'<)))
            (setf (alist-get file mega-dap-breakpoints nil t #'equal) lines)
            lines))))))

(defun mega-dap--restore-marks ()
  "Mark the breakpoints of the file just opened."
  (when buffer-file-name
    (dolist (line (cdr (assoc buffer-file-name mega-dap-breakpoints)))
      (mega-dap--mark line))))

(add-hook 'find-file-hook #'mega-dap--restore-marks)

(defun mega-dap-toggle-breakpoint (&optional remove-only)
  "Set a breakpoint on the current line, or remove the one that is there.
With REMOVE-ONLY non-nil, only remove.  A running debugger is told."
  (unless buffer-file-name
    (user-error "A breakpoint needs a file"))
  (let ((here (mega-dap--overlays (line-beginning-position)
                                  (min (point-max) (1+ (line-end-position))))))
    (cond (here (mapc #'delete-overlay here))
          (remove-only (user-error "No breakpoint on this line"))
          (t (mega-dap--mark (line-number-at-pos nil t))))
    (mega-dap-lines buffer-file-name)
    (when (mega-dap-active-p)
      (mega-dap--send-breakpoints buffer-file-name))
    (message (if here "Breakpoint removed" "Breakpoint set"))))

;;;; The session

(defvar mega-dap--process nil "The adapter, while a session is on.")
(defvar mega-dap--root nil "The project being debugged.")
(defvar mega-dap--seq 0 "The number of the last message sent.")
(defvar mega-dap--pending (make-hash-table) "What to do with each answer still awaited.")
(defvar mega-dap--state nil
  "Where the session is, or nil for none.
One of `starting', `running', `stopped' and `ending'.")
(defvar mega-dap--reason nil "Why the program stopped, or how it ended.")
(defvar mega-dap--thread nil "The thread that stopped.")
(defvar mega-dap--frames nil
  "The stack, innermost first: plists with :id, :name, :file and :line.")
(defvar mega-dap--frame 0 "Which of `mega-dap--frames' is selected.")
(defvar mega-dap--locals nil "The variables of the selected frame: (NAME . VALUE).")
(defvar mega-dap--output nil "What the program and the debugger printed, newest first.")
(defvar mega-dap--arrow nil "The overlay on the line the program is stopped at.")
(defvar mega-dap--greeted nil
  "Non-nil once the adapter has answered the first request.
What it prints before that is its banner, which nobody needs to read
at every start.")

(defconst mega-dap-info-buffer "*debug*"
  "The buffer that shows the state of the session.")

(defun mega-dap-active-p ()
  "Non-nil while a debug adapter session is on."
  (and mega-dap--state (process-live-p mega-dap--process)))

(defun mega-dap--send (message)
  "Send MESSAGE, a plist without its :seq, to the adapter."
  (setq mega-dap--seq (1+ mega-dap--seq))
  (process-send-string mega-dap--process
                       (mega-dap-encode (append (list :seq mega-dap--seq) message)))
  mega-dap--seq)

(defun mega-dap--request (command arguments &optional then)
  "Ask the adapter to do COMMAND with ARGUMENTS, a plist.
THEN, if given, is called with the body of the answer when it succeeded."
  (when (process-live-p mega-dap--process)
    (let ((seq (mega-dap--send (list :type "request" :command command
                                     :arguments (or arguments (make-hash-table))))))
      (when then
        (puthash seq then mega-dap--pending)))))

(defun mega-dap--inside (file)
  "FILE as the adapter knows it."
  (mega-exec-translate file 'inside mega-dap--root))

(defun mega-dap--host (file)
  "FILE, named by the adapter, as this machine knows it."
  (mega-exec-translate file 'host mega-dap--root))

(defun mega-dap--send-breakpoints (file)
  "Tell the adapter which lines of FILE have breakpoints."
  (mega-dap--request
   "setBreakpoints"
   (list :source (list :name (file-name-nondirectory file)
                       :path (mega-dap--inside file))
         :breakpoints (vconcat (mapcar (lambda (line) (list :line line))
                                       (mega-dap-lines file))))))

;;;; What the adapter says

(defun mega-dap--note (text)
  "Add TEXT to what the program and the debugger have printed."
  (dolist (line (split-string text "\n" t))
    (push line mega-dap--output))
  (when (nthcdr 500 mega-dap--output)
    (setcdr (nthcdr 499 mega-dap--output) nil)))

(defun mega-dap--stopped (body)
  "The program stopped: BODY says why.  Ask for the stack."
  (setq mega-dap--state 'stopped
        mega-dap--reason (or (plist-get body :description) (plist-get body :reason))
        mega-dap--thread (plist-get body :threadId))
  (mega-dap--request
   "stackTrace" (list :threadId mega-dap--thread :levels 50)
   (lambda (answer)
     (setq mega-dap--frames
           (mapcar (lambda (frame)
                     (let ((path (plist-get (plist-get frame :source) :path)))
                       (list :id (plist-get frame :id)
                             :name (plist-get frame :name)
                             :file (and path (mega-dap--host path))
                             :line (plist-get frame :line))))
                   (plist-get answer :stackFrames)))
     (mega-dap--select 0))))

(defun mega-dap--select (index)
  "Make frame INDEX of the stack the one shown, and ask for its variables."
  (setq mega-dap--frame index
        mega-dap--locals nil)
  (let ((frame (nth index mega-dap--frames)))
    (mega-dap--show-line frame)
    (mega-dap--refresh)
    (when frame
      (mega-dap--request
       "scopes" (list :frameId (plist-get frame :id))
       (lambda (answer)
         ;; The first scope that is cheap to read: the locals.  Registers
         ;; and the like are marked expensive.
         (when-let* ((scope (seq-find (lambda (scope) (not (plist-get scope :expensive)))
                                      (plist-get answer :scopes))))
           (mega-dap--request
            "variables" (list :variablesReference (plist-get scope :variablesReference))
            (lambda (answer)
              (setq mega-dap--locals
                    (mapcar (lambda (variable)
                              (cons (plist-get variable :name)
                                    (plist-get variable :value)))
                            (plist-get answer :variables)))
              (mega-dap--refresh)))))))))

(defun mega-dap--event (event body)
  "Act on EVENT from the adapter, with its BODY."
  (pcase event
    ("initialized"
     ;; Now, and not before, it takes breakpoints; then it is told to go.
     (dolist (entry (copy-sequence mega-dap-breakpoints))
       (when (mega-dap-lines (car entry))
         (mega-dap--send-breakpoints (car entry))))
     (mega-dap--request "configurationDone" nil))
    ("stopped" (mega-dap--stopped body))
    ("continued"
     (setq mega-dap--state 'running mega-dap--reason nil)
     (mega-dap--hide-line)
     (mega-dap--refresh))
    ("output"
     (unless (or (not mega-dap--greeted)
                 (equal (plist-get body :category) "telemetry"))
       (mega-dap--note (or (plist-get body :output) ""))
       (mega-dap--refresh)))
    ("exited"
     (mega-dap--note (format "The program ended with code %s" (plist-get body :exitCode))))
    ("terminated" (mega-dap-quit))))

(defun mega-dap--receive (message)
  "Act on MESSAGE, one plist from the adapter."
  (pcase (plist-get message :type)
    ("event" (mega-dap--event (plist-get message :event) (plist-get message :body)))
    ("response"
     (let* ((seq (plist-get message :request_seq))
            (then (gethash seq mega-dap--pending)))
       (remhash seq mega-dap--pending)
       (cond ((not (plist-get message :success))
              (mega-dap--note (format "%s failed: %s" (plist-get message :command)
                                      (or (plist-get message :message) "no reason given")))
              (mega-dap--refresh))
             (then (funcall then (plist-get message :body))))))
    ("request"
     ;; The adapter asks MEGA for something, such as a terminal to run the
     ;; program in.  MEGA offers none of it, and says so.
     (mega-dap--send (list :type "response" :request_seq (plist-get message :seq)
                           :success :false :command (plist-get message :command)
                           :message "not supported")))))

(defun mega-dap--filter (process bytes)
  "Take in BYTES from PROCESS, the adapter, and act on whole messages."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (goto-char (point-max))
      (insert bytes))
    (dolist (message (mega-dap-take (process-buffer process)))
      ;; This runs between your keystrokes: a message MEGA cannot make
      ;; sense of is noted, never raised.
      (condition-case err
          (mega-dap--receive message)
        (error (mega-dap--note (format "MEGA: %s" (error-message-string err))))))))

(defun mega-dap--sentinel (process _event)
  "Clean up when PROCESS, the adapter, has ended."
  (unless (process-live-p process)
    (when (eq process mega-dap--process)
      (mega-dap--note "The debugger has ended")
      (mega-dap--end))))

(defun mega-dap--end ()
  "Forget the session.  Breakpoints and what was printed stay."
  (when-let* ((process mega-dap--process))
    (setq mega-dap--process nil)
    (when (process-live-p process) (delete-process process))
    (when-let* ((errors (process-get process 'mega-dap-errors)))
      (when-let* ((stderr (get-buffer-process errors))) (delete-process stderr))
      (when (buffer-live-p errors) (kill-buffer errors)))
    (when (buffer-live-p (process-buffer process))
      (kill-buffer (process-buffer process))))
  (clrhash mega-dap--pending)
  (setq mega-dap--state nil
        mega-dap--reason nil
        mega-dap--frames nil
        mega-dap--locals nil)
  (mega-dap--hide-line)
  (mega-dap--refresh))

;;;; The display

(defun mega-dap-info-lines (state reason frames selected locals output)
  "The lines of the session window, from what is known.
STATE and REASON say where the session is; FRAMES is the stack and
SELECTED the index of the frame shown; LOCALS are its variables, as
\(NAME . VALUE); OUTPUT is what was printed, newest first."
  (append
   (list (pcase state
           ('starting "Starting...")
           ('running "Running")
           ('stopped (format "Stopped: %s" (or reason "no reason given")))
           ('ending "Stopping...")
           (_ "No debugger is running")))
   (when frames
     (cons "" (cons "Stack"
                    (let ((index -1))
                      (mapcar (lambda (frame)
                                (setq index (1+ index))
                                (format "%s %-24s %s"
                                        (if (= index selected) ">" " ")
                                        (plist-get frame :name)
                                        (if (plist-get frame :file)
                                            (format "%s:%s"
                                                    (file-name-nondirectory
                                                     (plist-get frame :file))
                                                    (plist-get frame :line))
                                          "")))
                              frames)))))
   (when locals
     (cons "" (cons "Variables"
                    (mapcar (lambda (variable)
                              (format "  %s = %s" (car variable) (cdr variable)))
                            locals))))
   (when output
     (cons "" (cons "Output"
                    (mapcar (lambda (line) (concat "  " line))
                            (reverse (take 12 output))))))))

(define-derived-mode mega-dap-info-mode special-mode "Debug"
  "The state of a debugging session.  The keys are under C-c g."
  (setq truncate-lines t))

(defun mega-dap--refresh ()
  "Redraw the session window, if its buffer exists."
  (when-let* ((buffer (get-buffer mega-dap-info-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (line (mega-dap-info-lines mega-dap--state mega-dap--reason
                                           mega-dap--frames mega-dap--frame
                                           mega-dap--locals mega-dap--output))
          (insert line "\n"))
        (goto-char (point-min))))))

(defun mega-dap--hide-line ()
  "Remove the mark from the line the program was stopped at."
  (when (overlayp mega-dap--arrow)
    (delete-overlay mega-dap--arrow)
    (setq mega-dap--arrow nil)))

(defun mega-dap--show-line (frame)
  "Show the line FRAME, an element of the stack, is at."
  (mega-dap--hide-line)
  (let ((file (plist-get frame :file))
        (line (plist-get frame :line)))
    (when (and file line (file-readable-p file))
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (goto-char (point-min))
            (forward-line (1- line))
            (setq mega-dap--arrow
                  (make-overlay (line-beginning-position)
                                (min (point-max) (1+ (line-end-position)))))
            (overlay-put mega-dap--arrow 'face 'mega-dap-current)
            (overlay-put mega-dap--arrow 'priority 10)))
        ;; In a window that shows code, never in the session window.
        (when-let* ((window (display-buffer
                             buffer '((display-buffer-reuse-window
                                       display-buffer-use-some-window)
                                      (inhibit-same-window . nil)))))
          (set-window-point window (overlay-start mega-dap--arrow)))))))

;;;; Which adapter

(defvar mega-dap--usable (make-hash-table :test #'equal)
  "Whether an adapter was found usable: (CONTEXT-NAME . ADAPTER) -> yes or no.")

(defun mega-dap--usable-p (entry root)
  "Non-nil if the adapter ENTRY exists and is new enough for the project at ROOT."
  (let* ((properties (cdr entry))
         (key (cons (plist-get (mega-exec-context root) :name) (car entry)))
         (known (gethash key mega-dap--usable)))
    (unless known
      (setq known
            (if (and (mega-exec-find (car (plist-get properties :command)) root)
                     (or (not (plist-get properties :minimum))
                         (let* ((version (plist-get properties :version))
                                (result (mega-exec-run (car version) (cdr version)
                                                       :directory root :timeout 10))
                                (line (car (split-string (plist-get result :output) "\n"))))
                           (and (string-match "\\([0-9]+\\)\\.[0-9]+[^ ]*\\'" (or line ""))
                                (>= (string-to-number (match-string 1 line))
                                    (plist-get properties :minimum))))))
                'yes
              'no))
      (puthash key known mega-dap--usable))
    (eq known 'yes)))

(defun mega-dap-choose (language root)
  "The first adapter for LANGUAGE usable where the tools of ROOT run, or nil."
  (seq-some (lambda (name)
              (let ((entry (assq name mega-dap-adapters)))
                (and entry (mega-dap--usable-p entry root) entry)))
            (cdr (assq language mega-dap-languages))))

;;;; Starting and stopping

(defun mega-dap-start (entry target root)
  "Start the adapter ENTRY on the program TARGET for the project at ROOT."
  (when (mega-dap-active-p)
    (user-error "A debugger is already running (C-c g q stops it)"))
  (mega-dap--end)
  (let* ((default-directory root)
         (command (mega-exec-command (car (plist-get (cdr entry) :command))
                                     (cdr (plist-get (cdr entry) :command))
                                     root))
         (errors (generate-new-buffer " *mega-dap-stderr*" t))
         (buffer (generate-new-buffer " *mega-dap*" t)))
    (with-current-buffer buffer (set-buffer-multibyte nil))
    (setq mega-dap--root root
          mega-dap--seq 0
          mega-dap--state 'starting
          mega-dap--output nil
          mega-dap--greeted nil
          mega-dap--process
          (make-process :name "mega-dap" :buffer buffer :stderr errors
                        :command command :connection-type 'pipe
                        :coding 'binary :noquery t
                        :filter #'mega-dap--filter
                        :sentinel #'mega-dap--sentinel))
    (process-put mega-dap--process 'mega-dap-errors errors)
    (when-let* ((stderr (get-buffer-process errors)))
      (set-process-query-on-exit-flag stderr nil)
      (set-process-sentinel stderr #'ignore))
    (with-current-buffer (get-buffer-create mega-dap-info-buffer)
      (mega-dap-info-mode))
    (display-buffer mega-dap-info-buffer
                    '((display-buffer-reuse-window display-buffer-in-side-window)
                      (side . bottom) (window-height . 0.3)))
    (mega-dap--refresh)
    (mega-dap--request
     "initialize"
     (list :clientID "mega" :clientName "MEGA" :adapterID (symbol-name (car entry))
           :linesStartAt1 t :columnsStartAt1 t :pathFormat "path"
           :supportsRunInTerminalRequest :false)
     (lambda (_capabilities)
       (setq mega-dap--greeted t)
       ;; The answer to this one may come only after the breakpoints have
       ;; been sent, which the "initialized" event asks for: do not wait.
       (mega-dap--request
        "launch"
        (list :program (mega-dap--inside target)
              :cwd (directory-file-name (mega-dap--inside root))
              :args [])
        (lambda (_) (when (eq mega-dap--state 'starting)
                      (setq mega-dap--state 'running)
                      (mega-dap--refresh))))))))

(defun mega-dap-quit ()
  "End the session: stop the program and the adapter."
  (when (process-live-p mega-dap--process)
    (let ((process mega-dap--process))
      (mega-dap--request "disconnect" (list :terminateDebuggee t))
      ;; It should go by itself; do not wait for ever if it does not.
      (run-with-timer 2 nil (lambda ()
                              (when (and (process-live-p process)
                                         (eq process mega-dap--process))
                                (mega-dap--end))))))
  (setq mega-dap--state (and (process-live-p mega-dap--process) 'ending)
        mega-dap--reason nil
        mega-dap--frames nil
        mega-dap--locals nil)
  (mega-dap--hide-line)
  (mega-dap--refresh))

;;;; What the keys do

(defun mega-dap--stopped-p ()
  "Signal an error unless the program is stopped."
  (unless (eq mega-dap--state 'stopped)
    (user-error (if (mega-dap-active-p)
                    "The program is not stopped"
                  "No debugger is running (C-c g g starts one)"))))

(defun mega-dap--go (command)
  "Send the stepping request COMMAND for the stopped thread."
  (mega-dap--stopped-p)
  (setq mega-dap--state 'running
        mega-dap--reason nil
        mega-dap--frames nil
        mega-dap--locals nil)
  (mega-dap--hide-line)
  (mega-dap--refresh)
  (mega-dap--request command (list :threadId mega-dap--thread)))

(defun mega-dap--expression ()
  "The expression to evaluate: the region, or the symbol at point."
  (or (and (use-region-p)
           (buffer-substring-no-properties (region-beginning) (region-end)))
      (thing-at-point 'symbol t)
      (user-error "Nothing to evaluate at point")))

(defun mega-dap-do (action)
  "Do ACTION, one of the debugger keys, in the adapter session.
ACTION is `next', `step', `finish', `continue', `up', `down' or `print'."
  (pcase action
    ('next (mega-dap--go "next"))
    ('step (mega-dap--go "stepIn"))
    ('finish (mega-dap--go "stepOut"))
    ('continue (mega-dap--go "continue"))
    ((or 'up 'down)
     (mega-dap--stopped-p)
     (let ((index (+ mega-dap--frame (if (eq action 'up) 1 -1))))
       (unless (nth index mega-dap--frames)
         (user-error (if (eq action 'up) "This is the outermost frame"
                       "This is the innermost frame")))
       (when (< index 0) (user-error "This is the innermost frame"))
       (mega-dap--select index)))
    ('print
     (mega-dap--stopped-p)
     (let ((expression (mega-dap--expression)))
       (mega-dap--request
        "evaluate"
        (list :expression expression :context "watch"
              :frameId (plist-get (nth mega-dap--frame mega-dap--frames) :id))
        (lambda (answer)
          (let ((text (format "%s = %s" expression (plist-get answer :result))))
            (mega-dap--note text)
            (mega-dap--refresh)
            (message "%s" text))))))
    (_ (user-error "This debugger cannot do that"))))

(provide 'mega-dap)
;;; mega-dap.el ends here
