;;; mega-debug.el --- Debugging  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs has had a debugger front end for decades: GUD.  It runs gdb, lldb
;; or Python's pdb in a buffer, follows the program through your source
;; files with an arrow in the margin, and sets breakpoints on the line you
;; are on.  It only wants to be told what to run, as a command line, every
;; time.  MEGA works that out:
;;
;;   C-c g g   start: picks the debugger for the language and the program to
;;             debug (a Cargo project's binary, the Python file you are in),
;;             and asks only when it cannot tell
;;   C-c g r   run the program, from the start
;;   C-c g b   breakpoint on this line          C-c g d   remove it
;;   C-c g n   step over                        C-c g s   step into
;;   C-c g f   run until the function returns   C-c g u   run to this line
;;   C-c g c   continue                         C-c g p   print what is at point
;;   C-c g <   up one stack frame               C-c g >   down one
;;   C-c g q   stop the debugger
;;
;; After any of the stepping keys, the last letter alone repeats: C-c g n n n.
;; The debugger's own buffer takes its commands as usual, and with gdb
;; `M-x gdb-many-windows' adds the locals, the stack and the breakpoints.
;;
;; A debugger runs the program, so it needs a project you have trusted
;; (mega-trust.el), and it runs where the project's tools are: in the
;; project's container if you joined one.  File names the debugger reports
;; are translated back to the files you are editing.
;;
;; In a container Emacs's full gdb interface cannot be used: it wants a
;; terminal of this machine for the program's input and output.  MEGA talks
;; to gdb as a debug adapter there instead (mega-dap.el), which shows the
;; stack and the variables in a window below and lets you set breakpoints
;; before starting.  That needs gdb 14 or newer in the container; with an
;; older one you get gdb's plain console.  `mega-debug-backend' overrides
;; the choice.
;;
;; Privacy: gdb can fetch missing debug information from a "debuginfod"
;; server, which tells that server what you are debugging.  MEGA switches
;; that off; set `gdb-debuginfod-enable-setting' to `ask' in local.el to be
;; asked instead.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)
(require 'mega-trust)

(declare-function mega-project-root "mega-project")
(declare-function mega-dap-choose "mega-dap")
(declare-function mega-dap-start "mega-dap")
(declare-function mega-dap-active-p "mega-dap")
(declare-function mega-dap-do "mega-dap")
(declare-function mega-dap-quit "mega-dap")
(declare-function mega-dap-toggle-breakpoint "mega-dap")
(declare-function gdb "gdb-mi")
(declare-function gud-gdb "gud")
(declare-function lldb "gud")
(declare-function pdb "gud")

(defvar gud-comint-buffer)
(defvar gdb-debuginfod-enable-setting)
(defvar gdb-show-main)
(defvar gdb-many-windows)
(defvar gdb-restore-window-configuration-after-quit)
(defvar gud-highlight-current-line)

;; Set before the libraries load, so the first session already has them.
(setq gdb-debuginfod-enable-setting nil
      ;; Two windows, the debugger and the source; the rest on request.
      gdb-many-windows nil
      gdb-show-main t
      ;; Your windows come back the way they were when the debugger exits.
      gdb-restore-window-configuration-after-quit t
      gud-highlight-current-line t)

;;;; Which debugger

(defcustom mega-debug-backend 'auto
  "How MEGA talks to a debugger.
`gud' is Emacs's own debugger interface; `dap' is a debug adapter, see
mega-dap.el.  `auto' takes the adapter where the full interface cannot
be had, which is inside a container, and Emacs's own everywhere else.
Wherever no usable adapter is found, Emacs's own interface is used."
  :type '(choice (const auto) (const gud) (const dap))
  :group 'mega)

(defun mega-debug-adapter (language root)
  "The debug adapter to use for LANGUAGE in the project at ROOT, or nil.
Nil means Emacs's own debugger interface."
  (when (pcase mega-debug-backend
          ('dap t)
          ('auto (plist-get (mega-exec-context root) :wrap)))
    (require 'mega-dap)
    (mega-dap-choose language root)))

(defvar mega-debuggers
  '((rust-gdb  :program "rust-gdb"  :arguments ("-i=mi") :start gdb
               :plain ("--fullname"))
    (gdb       :program "gdb"       :arguments ("-i=mi") :start gdb
               :plain ("--fullname"))
    (rust-lldb :program "rust-lldb" :arguments nil       :start lldb)
    (lldb      :program "lldb"      :arguments nil       :start lldb)
    (pdb       :program "python3"   :arguments ("-m" "pdb") :start pdb))
  "The debuggers MEGA can start: (NAME PROPERTY VALUE...).
:program is what to run and :arguments what to give it before the thing
to debug; :start is the Emacs command that takes the command line.
:plain, when present, replaces :arguments inside a container, where
`gud-gdb' is used instead of :start.")

(defvar mega-debug-languages
  '((python pdb)
    (rust rust-gdb gdb rust-lldb lldb)
    (native gdb lldb))
  "Which debuggers to try for a language, in order: (LANGUAGE NAME...).")

(defvar mega-debug--targets nil
  "What was debugged last in each project: an alist (ROOT . TARGET).")

(defun mega-debug-language (root)
  "The language to debug in the current buffer, a key of `mega-debug-languages'.
ROOT is the root of its project."
  (cond ((derived-mode-p 'python-base-mode) 'python)
        ((or (derived-mode-p 'rust-ts-mode 'mega-rust-mode)
             (file-exists-p (expand-file-name "Cargo.toml" root)))
         'rust)
        (t 'native)))

(defun mega-debug-choose (language root)
  "The first debugger for LANGUAGE that exists where ROOT's tools run.
Return its entry in `mega-debuggers', or nil."
  (seq-some (lambda (name)
              (let ((entry (assq name mega-debuggers)))
                (and (mega-exec-find (plist-get (cdr entry) :program) root)
                     entry)))
            (cdr (assq language mega-debug-languages))))

;;;; What to debug

(defun mega-debug--cargo-binary (root)
  "The debug binary a Cargo project at ROOT builds, or nil.
Read from the `name' of the [package] table; never by running cargo."
  (let ((manifest (expand-file-name "Cargo.toml" root)))
    (when (file-readable-p manifest)
      (with-temp-buffer
        (insert-file-contents manifest)
        (when (and (re-search-forward "^\\[package\\]" nil t)
                   (re-search-forward
                    "^\\(?:\\[\\|name[ \t]*=[ \t]*\"\\([^\"\n]+\\)\"\\)" nil t)
                   (match-string 1))
          (expand-file-name (concat "target/debug/" (match-string 1)) root))))))

(defun mega-debug-default-target (language root)
  "The likeliest thing to debug for LANGUAGE in the project at ROOT, or nil."
  (or (cdr (assoc root mega-debug--targets))
      (pcase language
        ('python buffer-file-name)
        ('rust (mega-debug--cargo-binary root)))))

(defun mega-debug--read-target (language root)
  "Ask what to debug for LANGUAGE in the project at ROOT."
  (let ((default (mega-debug-default-target language root)))
    (expand-file-name
     (read-file-name (if (eq language 'python) "Python file to debug: "
                       "Program to debug: ")
                     (if default (file-name-directory default) root)
                     default t
                     (and default (file-name-nondirectory default))))))

;;;; Starting

(defun mega-debug-command (entry target root)
  "How to start the debugger ENTRY on TARGET for the project at ROOT.
Return (FUNCTION . COMMAND-LINE): FUNCTION is the Emacs command to call
with COMMAND-LINE.  The line is made by quoting an argument list word
by word; GUD splits it back into words and runs no shell."
  (let* ((properties (cdr entry))
         (inside (plist-get (mega-exec-context root) :wrap))
         (plain (and inside (plist-get properties :plain))))
    (cons (if plain 'gud-gdb (plist-get properties :start))
          (combine-and-quote-strings
           (mega-exec-command
            (plist-get properties :program)
            (append (or plain (plist-get properties :arguments))
                    (list (mega-exec-translate target 'inside root)))
            root)))))

;;;###autoload
(defun mega-debug (&optional choose)
  "Start a debugger on the program of this project.
MEGA picks the debugger for the language and guesses the program; with
a prefix argument CHOOSE, or when it cannot guess, it asks which."
  (interactive "P")
  (let* ((root (file-name-as-directory
                (expand-file-name (or (mega-project-root) default-directory))))
         (language (mega-debug-language root))
         (adapter (mega-debug-adapter language root))
         (entry (mega-debug-choose language root)))
    (when (or (mega-debug-running-p) (mega-debug--adapter-running-p))
      (user-error "A debugger is already running (C-c g q stops it)"))
    (unless (or adapter entry)
      (user-error "No debugger for this is installed (tried: %s)"
                  (mapconcat (lambda (name)
                               (plist-get (cdr (assq name mega-debuggers)) :program))
                             (cdr (assq language mega-debug-languages)) ", ")))
    (unless (mega-trust-p root t "debug its program")
      (user-error "This project is not trusted; see M-x mega-trust-project"))
    (let* ((guess (mega-debug-default-target language root))
           (target (if (and guess (not choose) (file-exists-p guess))
                       guess
                     (mega-debug--read-target language root)))
           (default-directory root))
      (setf (alist-get root mega-debug--targets nil nil #'equal) target)
      (if adapter
          (mega-dap-start adapter target root)
        (let ((command (mega-debug-command entry target root)))
          (funcall (car command) (cdr command)))))))

;;;; File names from inside a container

(defun mega-debug--to-host (arguments)
  "Translate the file name in ARGUMENTS, those of `gud-find-file'.
A debugger running in a container names files as the container sees
them; the file to show is the one on this machine."
  (list (mega-exec-translate (car arguments) 'host)))

(with-eval-after-load 'gud
  (advice-add 'gud-find-file :filter-args #'mega-debug--to-host))

;;;; The keys

(defun mega-debug-running-p ()
  "Non-nil if a debugger is running."
  (and (bound-and-true-p gud-comint-buffer)
       (buffer-live-p gud-comint-buffer)
       (process-live-p (get-buffer-process gud-comint-buffer))))

(defun mega-debug--adapter-running-p ()
  "Non-nil if a debug adapter session is on."
  (and (featurep 'mega-dap) (mega-dap-active-p)))

(defconst mega-debug--actions
  '((gud-next . next) (gud-step . step) (gud-finish . finish)
    (gud-cont . continue) (gud-run . continue)
    (gud-up . up) (gud-down . down) (gud-print . print))
  "What each of Emacs's debugger commands is called in an adapter session.")

(defun mega-debug--call (command argument)
  "Run the debugger's COMMAND with ARGUMENT, if there is a debugger and it has one.
COMMAND names the command of Emacs's own interface; in an adapter
session the action of the same meaning is done instead."
  (cond ((mega-debug--adapter-running-p)
         (mega-dap-do (cdr (assq command mega-debug--actions))))
        ((not (mega-debug-running-p))
         (user-error "No debugger is running (C-c g g starts one)"))
        ((not (fboundp command))
         (user-error "This debugger cannot do that"))
        (t (funcall command argument))))

(defun mega-debug--breakpoint (command argument remove)
  "Set or, with REMOVE, remove a breakpoint on this line.
Emacs's own interface needs a running debugger and is given COMMAND
with ARGUMENT.  Where an adapter is or would be used, the breakpoint is
MEGA's own and can be set at any time."
  (cond ((mega-debug-running-p)
         (mega-debug--call command argument))
        ((or (mega-debug--adapter-running-p)
             (let ((root (file-name-as-directory
                          (expand-file-name (or (mega-project-root) default-directory)))))
               (mega-debug-adapter (mega-debug-language root) root)))
         (mega-dap-toggle-breakpoint remove))
        (t (user-error "No debugger is running (C-c g g starts one)"))))

(defmacro mega-debug--define (name command description)
  "Define the command NAME, which runs the debugger's COMMAND.
DESCRIPTION is its docstring."
  `(defun ,name (&optional argument)
     ,(concat description "\nARGUMENT is passed on to the debugger's own command.")
     (interactive "p")
     (mega-debug--call ',command (or argument 1))))

;;;###autoload
(defun mega-debug-break (&optional argument)
  "Set a breakpoint on this line.
In a debug adapter session, or before one, the same key takes it off
again.  ARGUMENT is passed on to Emacs's own debugger command."
  (interactive "p")
  (mega-debug--breakpoint 'gud-break (or argument 1) nil))

;;;###autoload
(defun mega-debug-remove (&optional argument)
  "Remove the breakpoint on this line.
ARGUMENT is passed on to Emacs's own debugger command."
  (interactive "p")
  (mega-debug--breakpoint 'gud-remove (or argument 1) t))

(mega-debug--define mega-debug-next gud-next "Run the line, stepping over calls.")
(mega-debug--define mega-debug-step gud-step "Run the line, stepping into calls.")
(mega-debug--define mega-debug-finish gud-finish "Run until this function returns.")
(mega-debug--define mega-debug-until gud-until "Run until this line is reached.")
(mega-debug--define mega-debug-continue gud-cont "Run until the next breakpoint.")
(mega-debug--define mega-debug-print gud-print "Print the value of the expression at point.")
(mega-debug--define mega-debug-up gud-up "Look at the function that called this one.")
(mega-debug--define mega-debug-down gud-down "Look at the function this one called.")

;;;###autoload
(defun mega-debug-run ()
  "Run the program being debugged, from the start.
gdb and lldb load a program and wait; this is what sets it going.  A
debugger that starts its program at once, as pdb does, continues it."
  (interactive)
  (mega-debug--call (if (fboundp 'gud-run) 'gud-run 'gud-cont) 1))

;;;###autoload
(defun mega-debug-quit ()
  "Stop the debugger, and the program with it."
  (interactive)
  (unless (or (mega-debug-running-p) (mega-debug--adapter-running-p))
    (user-error "No debugger is running"))
  (when (y-or-n-p "Stop the debugger and the program it is running? ")
    (if (mega-debug--adapter-running-p)
        (mega-dap-quit)
      ;; Asked once, above; not a second time by the buffer being killed.
      (set-process-query-on-exit-flag (get-buffer-process gud-comint-buffer) nil)
      (kill-buffer gud-comint-buffer))))

;; After a stepping key, the last letter alone repeats.
(defvar-keymap mega-debug-repeat-map
  :doc "Keys that repeat after a stepping command."
  :repeat t
  "n" #'mega-debug-next
  "s" #'mega-debug-step
  "f" #'mega-debug-finish
  "u" #'mega-debug-until
  "c" #'mega-debug-continue
  "<" #'mega-debug-up
  ">" #'mega-debug-down)

;;;; The doctor

(declare-function mega-doctor-heading "mega-doctor")
(declare-function mega-doctor-row "mega-doctor")

(defun mega-debug--doctor ()
  "Insert the doctor's section about debuggers."
  (mega-doctor-heading "Debuggers")
  (dolist (entry mega-debuggers)
    (let ((path (mega-exe-p (plist-get (cdr entry) :program))))
      (mega-doctor-row (symbol-name (car entry)) (or path "not found")
                       (unless path 'shadow))))
  (mega-doctor-row "in a container"
                   (pcase mega-debug-backend
                     ('gud "gdb's plain console")
                     (_ "stack and variables, with gdb 14 or newer there")))
  (mega-doctor-row "debuginfod"
                   (pcase gdb-debuginfod-enable-setting
                     ('nil "off: gdb fetches nothing from the network")
                     ('ask "gdb asks before fetching debug information")
                     (_ "ON: gdb tells a server what you debug"))
                   (and (eq gdb-debuginfod-enable-setting t) 'warning)))

(add-to-list 'mega-doctor-sections #'mega-debug--doctor t)

(provide 'mega-debug)
;;; mega-debug.el ends here
