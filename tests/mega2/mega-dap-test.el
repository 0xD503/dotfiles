;;; mega-dap-test.el --- Tests for mega-dap.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; The adapter is a script, fake-debug-adapter.py, written after a real
;; conversation with gdb 16 and keeping its habits: it answers `launch'
;; late, calls breakpoints unverified, and refuses a frame id from an
;; earlier stop.  A client that only works with a polite adapter fails here.

;;; Code:

(require 'mega-test-helper)
(require 'mega-trust)
(require 'mega-debug)
(require 'mega-dap)

(defconst mega-dap-test-adapter
  (expand-file-name "fake-debug-adapter.py" mega-test-dir))

;;;; The wire

(defmacro mega-dap-test--with-bytes (&rest body)
  "Run BODY in a buffer of bytes, as the adapter's output is kept."
  (declare (indent 0))
  `(with-temp-buffer
     (set-buffer-multibyte nil)
     ,@body))

(ert-deftest mega-dap-a-message-survives-the-wire ()
  (let ((message '(:seq 3 :type "request" :command "evaluate"
                   :arguments (:expression "naïve → 日本" :frameId 0))))
    (mega-dap-test--with-bytes
      (insert (mega-dap-encode message))
      (should (equal (mega-dap-take (current-buffer)) (list message)))
      (should (= (buffer-size) 0)))))

(ert-deftest mega-dap-the-length-counts-bytes-not-characters ()
  (let ((bytes (mega-dap-encode '(:output "日本"))))
    (should-not (multibyte-string-p bytes))
    (should (string-match "\\`Content-Length: \\([0-9]+\\)\r\n\r\n" bytes))
    (should (= (string-to-number (match-string 1 bytes))
               (- (length bytes) (match-end 0))))
    ;; Two characters, six bytes.
    (should (= (string-to-number (match-string 1 bytes))
               (length "{\"output\":\"xxxxxx\"}")))))

(ert-deftest mega-dap-messages-arrive-in-any-pieces ()
  (let ((one (mega-dap-encode '(:seq 1 :type "event" :event "output")))
        (two (mega-dap-encode '(:seq 2 :type "event" :event "stopped"))))
    (mega-dap-test--with-bytes
      ;; Two at once.
      (insert one two)
      (should (equal (mapcar (lambda (message) (plist-get message :seq))
                             (mega-dap-take (current-buffer)))
                     '(1 2)))
      ;; One in three pieces: nothing until it is whole.
      (insert (substring one 0 9))
      (should-not (mega-dap-take (current-buffer)))
      (goto-char (point-max))
      (insert (substring one 9 30))
      (should-not (mega-dap-take (current-buffer)))
      (goto-char (point-max))
      (insert (substring one 30) (substring two 0 5))
      (should (= (length (mega-dap-take (current-buffer))) 1))
      ;; What is left is the start of the next one.
      (should (equal (buffer-string) (substring two 0 5))))))

(ert-deftest mega-dap-stray-output-before-a-message-is-skipped ()
  (mega-dap-test--with-bytes
    (insert "warning: something a program printed\n"
            (mega-dap-encode '(:seq 7 :type "event" :event "output")))
    (should (equal (plist-get (car (mega-dap-take (current-buffer))) :seq) 7))))

;;;; Breakpoints

(defmacro mega-dap-test--with-source (&rest body)
  "Run BODY in a buffer BUFFER visiting FILE, a fifteen-line file in DIR.
No session is on and no breakpoint is set."
  (declare (indent 0))
  `(mega-test-with-directory dir
     (let* ((file (apply #'mega-test-write (expand-file-name "main.c" dir)
                         (append (mapcar (lambda (n) (format "line %d;" n))
                                         (number-sequence 1 15))
                                 '(""))))
            (mega-dap-breakpoints nil)
            (mega-dap--process nil)
            (mega-dap--state nil)
            (mega-dap--frames nil)
            (mega-dap--locals nil)
            (mega-dap--output nil)
            (inhibit-message t))
       (ignore file)
       (mega-test-visiting buffer file
         ,@body))))

(defun mega-dap-test--goto-line (line)
  "Go to LINE of the current buffer."
  (goto-char (point-min))
  (forward-line (1- line)))

(ert-deftest mega-dap-a-breakpoint-is-set-shown-and-taken-off-again ()
  (mega-dap-test--with-source
    (mega-dap-test--goto-line 5)
    (mega-dap-toggle-breakpoint)
    (mega-dap-test--goto-line 11)
    (mega-dap-toggle-breakpoint)
    (should (equal (mega-dap-lines file) '(5 11)))
    (should (equal mega-dap-breakpoints (list (cons file '(5 11)))))
    ;; It shows on that line and no other.
    (mega-dap-test--goto-line 5)
    (should (eq (get-char-property (point) 'face) 'mega-dap-breakpoint))
    (mega-dap-test--goto-line 6)
    (should-not (get-char-property (point) 'face))
    (mega-dap-test--goto-line 5)
    (mega-dap-toggle-breakpoint)
    (should (equal (mega-dap-lines file) '(11)))
    (should-not (get-char-property (point) 'face))
    ;; Removing where there is none is an error, not a new breakpoint.
    (should-error (mega-dap-toggle-breakpoint t) :type 'user-error)
    (should (equal (mega-dap-lines file) '(11)))
    (mega-dap-test--goto-line 11)
    (mega-dap-toggle-breakpoint t)
    (should-not mega-dap-breakpoints)))

(ert-deftest mega-dap-a-breakpoint-stays-on-its-line-of-code-while-you-edit ()
  (mega-dap-test--with-source
    (mega-dap-test--goto-line 5)
    (mega-dap-toggle-breakpoint)
    (goto-char (point-min))
    (insert "a new first line;\nand a second;\n")
    (should (equal (mega-dap-lines file) '(7)))
    (mega-dap-test--goto-line 7)
    (should (looking-at-p "line 5;"))
    ;; Deleting the line takes its breakpoint with it.
    (delete-region (line-beginning-position) (line-beginning-position 2))
    (should-not (mega-dap-lines file))
    (set-buffer-modified-p nil)))

(ert-deftest mega-dap-breakpoints-outlive-the-buffer ()
  (mega-test-with-directory dir
    (let ((file (apply #'mega-test-write (expand-file-name "main.c" dir)
                       (mapcar (lambda (n) (format "line %d;" n)) (number-sequence 1 9))))
          (mega-dap-breakpoints nil)
          (mega-dap--process nil)
          (mega-dap--state nil)
          (inhibit-message t))
      (mega-test-visiting buffer file
        (mega-dap-test--goto-line 4)
        (mega-dap-toggle-breakpoint))
      (should-not (get-file-buffer file))
      (should (equal (mega-dap-lines file) '(4)))
      (mega-test-visiting buffer file
        (mega-dap-test--goto-line 4)
        (should (eq (get-char-property (point) 'face) 'mega-dap-breakpoint))
        (should (equal (mega-dap-lines file) '(4)))))))

(ert-deftest mega-dap-a-breakpoint-needs-a-file ()
  (with-temp-buffer
    (insert "text\n")
    (should-error (mega-dap-toggle-breakpoint) :type 'user-error)))

;;;; The window

(ert-deftest mega-dap-the-window-says-what-is-known ()
  (should (equal (mega-dap-info-lines nil nil nil 0 nil nil)
                 '("No debugger is running")))
  (should (equal (mega-dap-info-lines 'running nil nil 0 nil '("9"))
                 '("Running" "" "Output" "  9")))
  (should (equal (mega-dap-info-lines
                  'stopped "breakpoint"
                  '((:id 10 :name "square" :file "/p/src/main.c" :line 5)
                    (:id 11 :name "main" :file "/p/src/main.c" :line 11)
                    (:id 12 :name "start" :file nil :line 0))
                  1
                  '(("a" . "3") ("b" . "9"))
                  '("second" "first"))
                 '("Stopped: breakpoint"
                   ""
                   "Stack"
                   "  square                   main.c:5"
                   "> main                     main.c:11"
                   "  start                    "
                   ""
                   "Variables"
                   "  a = 3"
                   "  b = 9"
                   ""
                   "Output"
                   "  first"
                   "  second"))))

(ert-deftest mega-dap-the-window-shows-only-the-latest-output ()
  (let* ((output (mapcar #'number-to-string (number-sequence 40 1 -1)))
         (lines (mega-dap-info-lines 'running nil nil 0 nil output)))
    (should (equal (car (last lines)) "  40"))
    (should (= (length lines) 15))))

;;;; Which adapter

(defmacro mega-dap-test--with-gdb (version &rest body)
  "Run BODY where `gdb' is a script that says it is VERSION.
VERSION is the first line `gdb --version' prints, or nil for no gdb."
  (declare (indent 1))
  `(mega-test-with-directory dir
     (let* ((bin (expand-file-name "bin/" dir))
            (exec-path (list bin "/usr/bin" "/bin"))
            (process-environment (cons (concat "PATH=" bin ":/usr/bin:/bin")
                                       process-environment))
            (mega--exe-cache (make-hash-table :test #'equal))
            (mega-dap--usable (make-hash-table :test #'equal))
            (mega-exec-context-functions nil))
       (make-directory bin t)
       (when ,version
         (set-file-modes (mega-test-write (expand-file-name "gdb" bin)
                                          "#!/bin/sh"
                                          (format "echo '%s'" ,version)
                                          "echo 'Copyright (C) 2024'" "")
                         #o755))
       ,@body)))

(ert-deftest mega-dap-an-adapter-must-exist-and-be-new-enough ()
  (mega-dap-test--with-gdb "GNU gdb (Debian 16.3-1) 16.3"
    (should (eq (car (mega-dap-choose 'native dir)) 'gdb))
    ;; rust-gdb is not there, so a Rust project gets plain gdb.
    (should (eq (car (mega-dap-choose 'rust dir)) 'gdb)))
  (mega-dap-test--with-gdb "GNU gdb (GDB) Fedora Linux 14.2-1.fc40"
    (should (mega-dap-choose 'native dir)))
  ;; Too old to be an adapter: Emacs's own interface will be used instead.
  (mega-dap-test--with-gdb "GNU gdb (Ubuntu 12.1-0ubuntu1~22.04) 12.1"
    (should-not (mega-dap-choose 'native dir)))
  (mega-dap-test--with-gdb "something else entirely"
    (should-not (mega-dap-choose 'native dir)))
  (mega-dap-test--with-gdb nil
    (should-not (mega-dap-choose 'native dir)))
  (mega-dap-test--with-gdb "GNU gdb (GDB) 16.3"
    (should-not (mega-dap-choose 'python dir))))

(ert-deftest mega-dap-lldb-is-found-under-the-name-a-distribution-gives-it ()
  (mega-dap-test--with-gdb "GNU gdb (GDB) 16.3"
    (set-file-modes (mega-test-write (expand-file-name "bin/lldb-dap-19" dir)
                                     "#!/bin/sh" "")
                    #o755)
    (let ((entry (assq 'lldb-dap mega-dap-adapters)))
      (should (equal (mega-dap-program entry dir) "lldb-dap-19")))
    ;; With both there, the family you prefer decides.
    (should (eq (car (mega-dap-choose 'native dir '(lldb gdb))) 'lldb-dap))
    (should (eq (car (mega-dap-choose 'rust dir '(lldb gdb))) 'lldb-dap))
    (should (eq (car (mega-dap-choose 'native dir '(gdb lldb))) 'gdb))))

(ert-deftest mega-dap-the-version-is-asked-once ()
  (mega-dap-test--with-gdb "GNU gdb (GDB) 16.3"
    (should (mega-dap-choose 'native dir))
    (delete-file (expand-file-name "bin/gdb" dir))
    (should (mega-dap-choose 'native dir))))

;;;; A session

(defmacro mega-dap-test--session (&rest body)
  "Run BODY with the stand-in adapter ready to start on a program in DIR.
FILE is the source, visited in BUFFER, with breakpoints on lines 5 and 11.
LOG is the file the adapter writes the requests it receives to."
  (declare (indent 0))
  `(mega-dap-test--with-source
     (let* ((log (expand-file-name "adapter.log" dir))
            (process-environment (cons (concat "MEGA_FAKE_DAP_LOG=" log)
                                       process-environment))
            (mega-dap-adapters
             (list (list 'fake :programs '("python3")
                         :arguments (list mega-dap-test-adapter))))
            (mega-dap-languages '((native fake)))
            (mega-dap--usable (make-hash-table :test #'equal))
            (mega-dap--pending (make-hash-table))
            (mega-dap--arrow nil)
            (mega-dap--thread nil)
            (mega-dap--frame 0)
            (mega-dap--greeted nil)
            (mega-exec-context-functions mega-exec-context-functions))
       (ignore log)
       (save-window-excursion
         (unwind-protect
             (progn
               (mega-dap-test--goto-line 5)
               (mega-dap-toggle-breakpoint)
               (mega-dap-test--goto-line 11)
               (mega-dap-toggle-breakpoint)
               ,@body)
           (mega-dap--end)
           (when (get-buffer mega-dap-info-buffer)
             (kill-buffer mega-dap-info-buffer)))))))

(defun mega-dap-test--start (dir)
  "Start the stand-in adapter for the project at DIR and wait until it stops."
  (mega-dap-start (assq 'fake mega-dap-adapters) (expand-file-name "prog" dir) dir)
  (should (mega-test-wait-for (lambda () (and (eq mega-dap--state 'stopped)
                                              mega-dap--locals))
                              20)))

(defun mega-dap-test--requests (log)
  "The requests the adapter wrote to LOG, oldest first, as plists."
  (when (file-exists-p log)
    (with-temp-buffer
      (insert-file-contents log)
      (let (requests)
        (while (not (eobp))
          (push (json-parse-string (buffer-substring (point) (line-end-position))
                                   :object-type 'plist :array-type 'list
                                   :null-object nil :false-object nil)
                requests)
          (forward-line 1))
        (nreverse requests)))))

(defun mega-dap-test--commands (log)
  "The names of the requests in LOG, oldest first."
  (delq nil (mapcar (lambda (request) (plist-get request :command))
                    (mega-dap-test--requests log))))

(defun mega-dap-test--arrow-line ()
  "The line the program is shown stopped at, as (FILE . LINE), or nil."
  (when (and (overlayp mega-dap--arrow) (overlay-buffer mega-dap--arrow))
    (with-current-buffer (overlay-buffer mega-dap--arrow)
      (cons buffer-file-name
            (line-number-at-pos (overlay-start mega-dap--arrow))))))

(ert-deftest mega-dap-a-session-starts-in-the-order-the-adapter-needs ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (let ((commands (mega-dap-test--commands log)))
      ;; Breakpoints go after "initialized" and before "configurationDone",
      ;; and nobody waits for the answer to "launch", which comes last.
      (should (equal (take 4 commands)
                     '("initialize" "launch" "setBreakpoints" "configurationDone"))))
    (let ((launch (seq-find (lambda (request)
                              (equal (plist-get request :command) "launch"))
                            (mega-dap-test--requests log))))
      (should (equal (plist-get (plist-get launch :arguments) :program)
                     (expand-file-name "prog" dir)))
      (should (equal (plist-get (plist-get launch :arguments) :cwd)
                     (directory-file-name dir))))
    (let ((set (seq-find (lambda (request)
                           (equal (plist-get request :command) "setBreakpoints"))
                         (mega-dap-test--requests log))))
      (should (equal (plist-get (plist-get (plist-get set :arguments) :source) :path)
                     file))
      (should (equal (plist-get (plist-get set :arguments) :breakpoints)
                     '((:line 5) (:line 11)))))))

(ert-deftest mega-dap-stopping-shows-the-line-the-stack-and-the-variables ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (should (equal mega-dap--reason "breakpoint"))
    (should (equal (mega-dap-test--arrow-line) (cons file 5)))
    (should (equal (mapcar (lambda (frame) (plist-get frame :name)) mega-dap--frames)
                   '("square" "main" "__libc_start_call_main")))
    ;; The locals, not the registers the adapter lists first.
    (should (equal mega-dap--locals '(("x" . "3"))))
    (let ((shown (mega-test-buffer-string mega-dap-info-buffer)))
      (should (string-match-p "^Stopped: breakpoint$" shown))
      (should (string-match-p "^> square +main\\.c:5$" shown))
      (should (string-match-p "^  x = 3$" shown))
      ;; What the debugger says once it is going is shown.  Its banner is
      ;; not, and nor is what it reports for its makers.
      (should (string-match-p "^  Breakpoint 1 pending\\.$" shown))
      (should-not (string-match-p "GNU gdb (stand-in)" shown))
      (should-not (string-match-p "not for the user" shown)))))

(ert-deftest mega-dap-stepping-moves-the-line-and-asks-for-the-stack-again ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (mega-dap-do 'next)
    ;; At once, without waiting: the program is running and nothing is stale.
    (should (eq mega-dap--state 'running))
    (should-not (mega-dap-test--arrow-line))
    (should-not mega-dap--frames)
    (should (mega-test-wait-for (lambda () (and (eq mega-dap--state 'stopped)
                                                mega-dap--locals))
                                20))
    (should (equal mega-dap--reason "step"))
    (should (equal (mega-dap-test--arrow-line) (cons file 6)))
    ;; The adapter refuses a frame from before the step; the value came back,
    ;; so the frame asked about was the new one.
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments)
                   (setq said (apply #'format-message format arguments)))))
        (with-current-buffer buffer
          (goto-char (point-min))
          (search-forward "line 6")
          (mega-dap-do 'print))
        (should (mega-test-wait-for (lambda () said) 20)))
      (should (equal said "6 = 9")))
    (should-not (seq-some (lambda (line) (string-match-p "failed" line))
                          mega-dap--output))))

(ert-deftest mega-dap-going-up-the-stack-shows-that-frame ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (should-error (mega-dap-do 'down) :type 'user-error)
    (mega-dap-do 'up)
    (should (= mega-dap--frame 1))
    (should (mega-test-wait-for (lambda () (equal mega-dap--locals
                                                  '(("a" . "3") ("b" . "ünïcödé"))))
                                20))
    (should (equal (mega-dap-test--arrow-line) (cons file 11)))
    (should (string-match-p "^> main +main\\.c:11$"
                            (mega-test-buffer-string mega-dap-info-buffer)))
    ;; A frame without a source is selected without a line to show.
    (mega-dap-do 'up)
    (should (= mega-dap--frame 2))
    (should-not (mega-dap-test--arrow-line))
    (should-error (mega-dap-do 'up) :type 'user-error)
    (mega-dap-do 'down)
    (should (= mega-dap--frame 1))))

(ert-deftest mega-dap-a-breakpoint-set-while-running-is-sent-at-once ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (with-current-buffer buffer
      (mega-dap-test--goto-line 8)
      (mega-dap-toggle-breakpoint))
    (should (mega-test-wait-for
             (lambda ()
               (equal (plist-get
                       (plist-get (car (last (seq-filter
                                              (lambda (request)
                                                (equal (plist-get request :command)
                                                       "setBreakpoints"))
                                              (mega-dap-test--requests log))))
                                  :arguments)
                       :breakpoints)
                      '((:line 5) (:line 8) (:line 11))))
             20))))

(ert-deftest mega-dap-running-to-the-end-ends-the-session-and-keeps-the-output ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (let ((process mega-dap--process))
      (mega-dap-do 'continue)
      (should (mega-test-wait-for (lambda () (null mega-dap--state)) 20))
      (should-not (process-live-p process))
      (should-not mega-dap--process))
    (should-not (mega-dap-test--arrow-line))
    (should (member "9" mega-dap--output))
    (should (member "The program ended with code 0" mega-dap--output))
    (let ((shown (mega-test-buffer-string mega-dap-info-buffer)))
      (should (string-match-p "^No debugger is running$" shown))
      (should (string-match-p "^  9$" shown)))
    ;; The breakpoints are MEGA's: still there for the next run.
    (should (equal (mega-dap-lines file) '(5 11)))
    ;; The keys now say there is nothing to step.
    (should-error (mega-dap-do 'next) :type 'user-error)))

(ert-deftest mega-dap-quitting-stops-the-program-and-the-adapter ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (let ((process mega-dap--process))
      (mega-dap-quit)
      (should (mega-test-wait-for (lambda () (not (process-live-p process))) 20))
      (should (mega-test-wait-for (lambda () (null mega-dap--state)) 20)))
    (let ((disconnect (seq-find (lambda (request)
                                  (equal (plist-get request :command) "disconnect"))
                                (mega-dap-test--requests log))))
      (should (eq (plist-get (plist-get disconnect :arguments) :terminateDebuggee) t)))
    (should-not (mega-dap-test--arrow-line))))

(ert-deftest mega-dap-what-the-adapter-asks-of-mega-is-declined ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (let ((answer (seq-find (lambda (message)
                              (equal (plist-get message :type) "response"))
                            (mega-dap-test--requests log))))
      (should answer)
      (should (equal (plist-get answer :command) "runInTerminal"))
      (should-not (plist-get answer :success)))))

(ert-deftest mega-dap-only-one-session-at-a-time ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (mega-dap-test--start dir)
    (should-error (mega-dap-start (assq 'fake mega-dap-adapters)
                                  (expand-file-name "prog" dir) dir)
                  :type 'user-error)))

(ert-deftest mega-dap-a-program-without-breakpoints-just-runs ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (with-current-buffer buffer
      (mega-dap-test--goto-line 5)
      (mega-dap-toggle-breakpoint)
      (mega-dap-test--goto-line 11)
      (mega-dap-toggle-breakpoint))
    (mega-dap-start (assq 'fake mega-dap-adapters) (expand-file-name "prog" dir) dir)
    (should (mega-test-wait-for (lambda () (member "9" mega-dap--output)) 20))
    (should (mega-test-wait-for (lambda () (null mega-dap--state)) 20))
    (should-not (member "setBreakpoints" (mega-dap-test--commands log)))))

(ert-deftest mega-dap-an-adapter-that-dies-ends-the-session-quietly ()
  (mega-dap-test--session
    (let ((mega-dap-adapters '((fake :programs ("sh")
                                     :arguments ("-c" "cat > /dev/null; exit 3")))))
      (mega-dap-start (assq 'fake mega-dap-adapters) (expand-file-name "prog" dir) dir)
      (delete-process mega-dap--process)
      (should (mega-test-wait-for (lambda () (null mega-dap--state)) 20))
      (should-not mega-dap--process)
      (should (member "The debugger has ended" mega-dap--output))
      (should-error (mega-dap-do 'continue) :type 'user-error))))

(ert-deftest mega-dap-nonsense-from-the-adapter-is-noted-not-raised ()
  (mega-dap-test--session
    (let ((mega-dap--state 'running))
      (mega-dap--receive '(:type "event" :event "something-new" :body (:x 1)))
      (mega-dap--receive '(:type "response" :request_seq 999 :success t :command "x"))
      (mega-dap--receive '(:type "response" :request_seq 998 :command "next"
                           :message "not now"))
      (mega-dap--receive '(:type "who-knows"))
      (should (member "next failed: not now" mega-dap--output)))))

;;;; lldb's adapter, which behaves differently in every detail that matters

(ert-deftest mega-dap-a-session-with-lldb-runs-from-breakpoint-to-end ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (let ((process-environment (cons "MEGA_FAKE_DAP_STYLE=lldb" process-environment)))
      ;; It says "initialized" only after `launch'; nothing may wait for it.
      (mega-dap-test--start dir)
      (should (equal (take 4 (mega-dap-test--commands log))
                     '("initialize" "launch" "setBreakpoints" "configurationDone")))
      (should (equal (mega-dap-test--arrow-line) (cons file 5)))
      (should (equal mega-dap--locals '(("x" . "3"))))
      (should (= mega-dap--thread 20))
      ;; It announces a step before it answers the request for one.
      (mega-dap-do 'next)
      (should (mega-test-wait-for (lambda () (and (eq mega-dap--state 'stopped)
                                                  mega-dap--locals
                                                  (equal (mega-dap-test--arrow-line)
                                                         (cons file 6))))
                                  20))
      (let ((process mega-dap--process))
        (mega-dap-do 'continue)
        (should (mega-test-wait-for (lambda () (null mega-dap--state)) 20))
        (should-not (process-live-p process)))
      ;; The program's line, without the carriage return it came with.
      (should (member "9" mega-dap--output))
      (should-not (seq-some (lambda (line) (string-search "\r" line)) mega-dap--output))
      (should (member "Process 20 exited with status = 0 (0x00000000) " mega-dap--output))
      ;; It crashes when told to go, and says so at length: not your concern.
      (should-not (seq-some (lambda (line)
                              (string-match-p "invalid pointer\\|bug report" line))
                            mega-dap--output)))))

(ert-deftest mega-dap-rust-values-are-readable-with-lldb ()
  "lldb is given the commands `rust-lldb' gives it, where Rust has them."
  (mega-test-with-directory dir
    (let* ((bin (expand-file-name "bin/" dir))
           (sysroot (expand-file-name "toolchain" dir))
           (support (concat sysroot "/lib/rustlib/etc/"))
           (exec-path (list bin "/usr/bin" "/bin"))
           (process-environment (cons (concat "PATH=" bin ":/usr/bin:/bin")
                                      process-environment))
           (mega--exe-cache (make-hash-table :test #'equal))
           (mega-dap--rust-support (make-hash-table :test #'equal))
           (mega-exec-context-functions nil))
      (set-file-modes (mega-test-write (expand-file-name "rustc" bin)
                                       "#!/bin/sh" (format "echo '%s'" sysroot) "")
                      #o755)
      ;; A Rust without the scripts: nothing is made up.
      (should-not (mega-dap-lldb-launch 'rust dir))
      (clrhash mega-dap--rust-support)
      (mega-test-write (concat support "lldb_lookup.py") "")
      (let ((import (format "command script import \"%slldb_lookup.py\"" support))
            (source (format "command source -s 0 \"%slldb_commands\"" support)))
        ;; Newer Rust ships one script, older Rust two: name what is there.
        (should (equal (mega-dap-lldb-launch 'rust dir)
                       (list :initCommands (vector import))))
        (clrhash mega-dap--rust-support)
        (mega-test-write (concat support "lldb_commands") "")
        (should (equal (mega-dap-lldb-launch 'rust dir)
                       (list :initCommands (vector import source)))))
      ;; Only for Rust.
      (should-not (mega-dap-lldb-launch 'native dir)))))

(ert-deftest mega-dap-what-an-adapter-needs-besides-the-program-is-sent ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (let ((mega-dap-adapters
           (list (list 'fake :programs '("python3")
                       :arguments (list mega-dap-test-adapter)
                       :launch (lambda (language _root)
                                 (list :initCommands (vector (format "for %s" language))))))))
      (mega-dap-start (assq 'fake mega-dap-adapters) (expand-file-name "prog" dir) dir 'rust)
      (should (mega-test-wait-for (lambda () (eq mega-dap--state 'stopped)) 20))
      (let ((launch (seq-find (lambda (request)
                                (equal (plist-get request :command) "launch"))
                              (mega-dap-test--requests log))))
        (should (equal (plist-get (plist-get launch :arguments) :initCommands)
                       '("for rust")))
        (should (equal (plist-get (plist-get launch :arguments) :program)
                       (expand-file-name "prog" dir)))))))

;;;; In a container

(ert-deftest mega-dap-file-names-are-translated-both-ways ()
  (skip-unless (executable-find "python3"))
  (mega-dap-test--session
    (setq mega-exec-context-functions
          (list (lambda (directory)
                  (when (file-in-directory-p directory dir)
                    (list :kind 'container :name "box"
                          ;; The stand-in runs here; only the names change.
                          :wrap (lambda (program args _where) (cons program args))
                          :find (lambda (_program) t)
                          :to-inside (lambda (name)
                                       (let ((within (file-relative-name name dir)))
                                         (concat "/workspaces/p/"
                                                 (if (member within '("." "./"))
                                                     ""
                                                   within))))
                          :to-host (lambda (name)
                                     (if (string-prefix-p "/workspaces/p/" name)
                                         (expand-file-name
                                          (string-remove-prefix "/workspaces/p/" name)
                                          dir)
                                       name)))))))
    (mega-dap-test--start dir)
    (let* ((requests (mega-dap-test--requests log))
           (launch (seq-find (lambda (request)
                               (equal (plist-get request :command) "launch"))
                             requests))
           (set (seq-find (lambda (request)
                            (equal (plist-get request :command) "setBreakpoints"))
                          requests)))
      ;; The adapter is told names as the container has them...
      (should (equal (plist-get (plist-get launch :arguments) :program)
                     "/workspaces/p/prog"))
      (should (equal (plist-get (plist-get launch :arguments) :cwd) "/workspaces/p"))
      (should (equal (plist-get (plist-get (plist-get set :arguments) :source) :path)
                     "/workspaces/p/main.c")))
    ;; ...and what it reports is shown in the file you are editing.
    (should (equal (mega-dap-test--arrow-line) (cons file 5)))
    (should-not (seq-some (lambda (name) (string-prefix-p "/workspaces" name))
                          (delq nil (mapcar #'buffer-file-name (buffer-list)))))))

;;;; Through the debugger keys

(defmacro mega-dap-test--project (&rest body)
  "Run BODY in a trusted project DIR that has a gdb new enough to be an adapter.
CONTAINER is a context function that puts the project in a container."
  (declare (indent 0))
  `(mega-dap-test--with-gdb "GNU gdb (GDB) 16.3"
     (let* ((mega-trust-file (expand-file-name "trusted.eld" dir))
            (mega-trust--decisions nil)
            (mega-debug--targets nil)
            (mega-dap-breakpoints nil)
            (mega-dap--process nil)
            (mega-dap--state nil)
            (program (mega-test-write (expand-file-name "build/app" dir) ""))
            (default-directory dir)
            (inhibit-message t)
            (container (lambda (directory)
                         (when (file-in-directory-p directory dir)
                           (list :kind 'container :name "box"
                                 :wrap (lambda (program args _where) (cons program args))
                                 :find (lambda (program) (equal program "gdb"))
                                 :to-inside #'identity :to-host #'identity)))))
       (ignore container)
       (mega-trust--record dir t)
       (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) program)))
         ,@body))))

(ert-deftest mega-dap-is-used-in-a-container-and-emacs-own-interface-outside ()
  (mega-dap-test--project
    (let (started)
      (cl-letf (((symbol-function 'mega-dap-start)
                 (lambda (entry target root &rest _)
                   (setq started (list 'dap (car entry) target root))))
                ((symbol-function 'gdb)
                 (lambda (line) (setq started (list 'gud line))))
                ((symbol-function 'gud-gdb)
                 (lambda (line) (setq started (list 'plain line)))))
        ;; On this machine: Emacs's own, full interface.
        (with-temp-buffer (mega-debug))
        (should (eq (car started) 'gud))
        ;; In a container: the adapter.
        (let ((mega-exec-context-functions (list container)))
          (with-temp-buffer (mega-debug))
          (should (equal started (list 'dap 'gdb program dir)))
          ;; Unless you say otherwise.
          (let ((mega-debug-backend 'gud))
            (with-temp-buffer (mega-debug))
            (should (eq (car started) 'plain))))
        (let ((mega-debug-backend 'dap))
          (with-temp-buffer (mega-debug))
          (should (eq (car started) 'dap)))))))

(ert-deftest mega-dap-the-debugger-you-prefer-outranks-the-better-interface ()
  "With lldb there but only gdb as an adapter, lldb is used, as a console."
  (mega-dap-test--project
    (let* ((started nil)
           (has (lambda (programs)
                  (lambda (directory)
                    (when (file-in-directory-p directory dir)
                      (list :kind 'container :name (format "box-%s" programs)
                            :wrap (lambda (program args _where) (cons program args))
                            :find (lambda (program) (member program programs))
                            :to-inside #'identity :to-host #'identity))))))
      (cl-letf (((symbol-function 'mega-dap-start)
                 (lambda (entry &rest _) (setq started (list 'dap (car entry)))))
                ((symbol-function 'lldb)
                 (lambda (line) (setq started (list 'gud 'lldb line))))
                ((symbol-function 'gud-gdb)
                 (lambda (line) (setq started (list 'gud 'gdb line)))))
        ;; gdb can be an adapter, lldb is only a console: lldb, as preferred.
        (let ((mega-exec-context-functions (list (funcall has '("gdb" "lldb")))))
          (with-temp-buffer (mega-debug))
          (should (equal (take 2 started) '(gud lldb)))
          ;; Prefer gdb, and its adapter is used.
          (let ((mega-debug-prefer '(gdb lldb)))
            (with-temp-buffer (mega-debug))
            (should (equal started '(dap gdb))))
          ;; Insist on an adapter, and the one there is, is used.
          (let ((mega-debug-backend 'dap))
            (with-temp-buffer (mega-debug))
            (should (equal started '(dap gdb)))))
        ;; lldb with its adapter: the preferred debugger, the better interface.
        (let ((mega-exec-context-functions
               (list (funcall has '("gdb" "lldb" "lldb-dap-19")))))
          (with-temp-buffer (mega-debug))
          (should (equal started '(dap lldb-dap))))))))

(ert-deftest mega-dap-an-old-gdb-in-a-container-falls-back-to-its-console ()
  (mega-dap-test--project
    (let (started)
      (cl-letf (((symbol-function 'mega-dap-start)
                 (lambda (&rest _) (setq started 'dap)))
                ((symbol-function 'gud-gdb)
                 (lambda (_line) (setq started 'plain))))
        (mega-test-write (expand-file-name "bin/gdb" dir)
                         "#!/bin/sh" "echo 'GNU gdb (GDB) 12.1'" "")
        (clrhash mega-dap--usable)
        (let ((mega-exec-context-functions (list container)))
          (with-temp-buffer (mega-debug))
          (should (eq started 'plain)))))))

(ert-deftest mega-dap-an-untrusted-project-starts-no-adapter ()
  (mega-dap-test--project
    (setq mega-trust--decisions nil)
    (delete-file mega-trust-file)
    (let (started)
      (cl-letf (((symbol-function 'mega-dap-start)
                 (lambda (&rest _) (setq started t))))
        (let ((mega-exec-context-functions (list container)))
          (should-error (with-temp-buffer (mega-debug)) :type 'user-error))
        (should-not started)))))

(ert-deftest mega-dap-the-breakpoint-key-works-before-the-debugger-in-a-container ()
  (mega-dap-test--project
    (let ((file (mega-test-write (expand-file-name "main.c" dir) "one;" "two;" "three;" "")))
      (mega-test-visiting buffer file
        (forward-line 1)
        ;; On this machine a breakpoint needs a running debugger...
        (should-error (mega-debug-break) :type 'user-error)
        (should-not mega-dap-breakpoints)
        ;; ...in a container it is kept until one is started.
        (let ((mega-exec-context-functions (list container)))
          (mega-debug-break)
          (should (equal (mega-dap-lines file) '(2)))
          (mega-debug-break)
          (should-not (mega-dap-lines file))
          (mega-debug-break)
          (mega-debug-remove)
          (should-not (mega-dap-lines file)))))))

(ert-deftest mega-dap-the-debugger-keys-go-to-the-adapter-session ()
  (let ((mega-dap--state 'stopped)
        (did nil))
    (cl-letf (((symbol-function 'mega-dap-active-p) #'always)
              ((symbol-function 'mega-dap-do) (lambda (action) (push action did)))
              ((symbol-function 'mega-dap-quit) (lambda () (push 'quit did)))
              ((symbol-function 'y-or-n-p) #'always))
      (mega-debug-next)
      (mega-debug-step)
      (mega-debug-finish)
      (mega-debug-continue)
      (mega-debug-run)
      (mega-debug-up)
      (mega-debug-down)
      (mega-debug-print)
      (mega-debug-until)
      (mega-debug-quit)
      (should (equal (reverse did)
                     '(next step finish continue continue up down print nil quit))))))

(ert-deftest mega-dap-what-an-adapter-cannot-do-is-said ()
  (should-error (mega-dap-do nil) :type 'user-error)
  (should-error (mega-dap-do 'until) :type 'user-error))

(provide 'mega-dap-test)
;;; mega-dap-test.el ends here
