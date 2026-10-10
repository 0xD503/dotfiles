;;; mega-exec.el --- The one way MEGA runs a program  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every program MEGA starts goes through this file.  That buys four things.
;;
;; * Security.  A program is always an argument list, never a shell string, so
;;   a file name or a search pattern cannot become a command.
;;
;; * Context.  A project's tools may live inside a dev container.  Callers
;;   say what to run and for which directory; this file works out how.  A
;;   context is found by asking `mega-exec-context-functions', which is how
;;   the container module plugs in without any other module knowing about
;;   containers.  A project on another machine needs no context of its own:
;;   its directory is a remote file name, and Emacs starts the program there.
;;
;; * Place.  Three answers to "where does this run", chosen by the caller:
;;
;;     (nothing)   where the project's tools are: its container if it has
;;                 one, else the machine its files are on
;;     :local t    where the files are, never a container: right for what
;;                 only reads the project, such as a search
;;     :here t     this machine, whatever the buffer is visiting: right for
;;                 what belongs to your desk and not to the project, such as
;;                 the clipboard, tmux, the container program itself
;;
;; * Responsiveness.  Three ways to run, by how long the caller can wait:
;;
;;     `mega-exec-run'    waits, but stays interruptible: a keystroke under
;;                        `while-no-input', or C-g, abandons the wait and the
;;                        program is killed on the way out.  A timeout covers
;;                        everything, sending the input included.
;;     `mega-exec-start'  returns at once and calls back with the result.
;;     `mega-exec-open'   returns at once and hands over what the program
;;                        prints as it comes: for a conversation, such as
;;                        the one with a debug adapter.
;;
;; A few programs need a terminal of their own and are started by Emacs's
;; terminal emulator or its debugger front end instead.  Those callers still
;; get their argument list from `mega-exec-command', so the container and the
;; quoting are decided here.
;;
;; A context is a plist:
;;
;;   :kind      `local', or whatever the module providing it calls it
;;   :name      a short label for the modeline and the doctor
;;   :key       what tells this context from every other, for remembering
;;              what was found out about it; nil for this machine
;;   :wrap      function (PROGRAM ARGS DIRECTORY) returning the argument list
;;              that runs PROGRAM inside the context.  It honours
;;              `mega-exec-environment' and `mega-exec-terminal'.
;;   :find      function (PROGRAM) returning non-nil if PROGRAM exists there
;;   :to-inside / :to-host
;;              functions translating a file name in each direction

;;; Code:

(require 'mega-lib)

(defvar mega-exec-context-functions nil
  "Functions that may claim a directory for a non-local context.
Each is called with a directory and returns a context plist or nil; the
first non-nil answer wins.  See the Commentary for the plist.")

(defconst mega-exec-local-context '(:kind local :name nil :key nil)
  "The context of a program that simply runs where the files are.")

(defvar mega-exec-environment nil
  "Environment settings for the program about to be started: (\"NAME=VALUE\"...).
Bind it around a call.  It reaches the program wherever it runs: on
this machine through the process environment, in a container through
whatever the container program offers for that.")

(defvar mega-exec-terminal nil
  "Non-nil if the program about to be started will be given a terminal.
Bind it around `mega-exec-command' when the result goes to Emacs's
terminal emulator; a container context then asks for one inside too.")

(defvar mega-exec-input-seconds 30
  "How long a program may take to accept its input when no timeout is given.")

(defun mega-exec-context (&optional directory)
  "Return the execution context of DIRECTORY, by default `default-directory'."
  (or (run-hook-with-args-until-success
       'mega-exec-context-functions
       (expand-file-name (or directory default-directory)))
      mega-exec-local-context))

(defun mega-exec-context-key (&optional directory)
  "What tells the context of DIRECTORY from every other.
For remembering what was found out about the programs there.  It is the
context's :key, or its :name if it has none; `here' for this machine."
  (let ((context (mega-exec-context directory)))
    (or (plist-get context :key) (plist-get context :name) 'here)))

(defun mega-exec-command (program args &optional directory local)
  "Return the argument list that runs PROGRAM with ARGS for DIRECTORY.
With LOCAL non-nil, ignore any context: the program runs where the files
are.  That is right for anything that only reads the project, such as
searching it, and wrong for the project's own toolchain."
  (let* ((context (if local mega-exec-local-context (mega-exec-context directory)))
         (wrap (plist-get context :wrap)))
    (if wrap
        (funcall wrap program args (expand-file-name (or directory default-directory)))
      (cons program args))))

(defun mega-exec-find (program &optional directory local)
  "Return non-nil if PROGRAM can be run for DIRECTORY.
LOCAL means the same as in `mega-exec-command'."
  (let* ((directory (or directory default-directory))
         (context (if local mega-exec-local-context (mega-exec-context directory)))
         (find (plist-get context :find)))
    (cond (find (funcall find program))
          ((file-remote-p directory)
           (let ((default-directory directory))
             (executable-find program t)))
          (t (mega-exe-p program)))))

(defun mega-exec-translate (file direction &optional directory)
  "Translate FILE for DIRECTORY's context; DIRECTION is `inside' or `host'.
Outside a container this is the identity."
  (let* ((context (mega-exec-context (or directory default-directory)))
         (function (plist-get context (if (eq direction 'inside) :to-inside :to-host))))
    (if function (funcall function file) file)))

;;;; Starting a program

(defun mega-exec--make (program args options &rest more)
  "Start PROGRAM with ARGS as OPTIONS say and return (PROCESS . ERRORS).
OPTIONS is the caller's plist; :directory, :local and :here are read
from it.  MORE is passed on to `make-process'.  ERRORS is the buffer
that takes what the program writes to its error output."
  (let* ((here (plist-get options :here))
         (directory (expand-file-name
                     (or (plist-get options :directory) default-directory)))
         ;; On this machine means on this machine: a buffer visiting a file
         ;; elsewhere does not move the program there.
         (directory (if (and here (file-remote-p directory))
                        (expand-file-name "~/")
                      directory))
         (default-directory directory)
         (process-environment (append mega-exec-environment process-environment))
         (errors (generate-new-buffer " *mega-exec-stderr*" t))
         (process
          (condition-case err
              (apply #'make-process
                     :stderr errors
                     :command (mega-exec-command program args directory
                                                 (or here (plist-get options :local)))
                     :connection-type 'pipe
                     :noquery t
                     :file-handler (not here)
                     more)
            ;; A program that cannot be started leaves nothing behind.
            (error (kill-buffer errors)
                   (signal (car err) (cdr err))))))
    (when-let* ((stderr (get-buffer-process errors)))
      (set-process-query-on-exit-flag stderr nil)
      (set-process-sentinel stderr #'ignore))
    (cons process errors)))

(defun mega-exec--feed (process input &optional seconds)
  "Send INPUT, if any, to PROCESS, and then the end of its input.
Return `timeout' if that took more than SECONDS, else nil.

A program may finish, or stop reading, before it has been sent
everything; a quick one on a busy machine may be gone before it is sent
anything.  Neither is an error here: what the program printed and how it
ended are the answer, and the caller has both.  A program that neither
reads nor ends would hold Emacs for ever once the pipe is full, which is
what SECONDS is for; the caller then kills it."
  (with-timeout ((or seconds mega-exec-input-seconds) 'timeout)
    (condition-case nil
        (progn
          (when input
            (process-send-string process input))
          (process-send-eof process))
      (error nil))
    nil))

(defun mega-exec--drain (errors)
  "Read the rest of a program's error output into the buffer ERRORS.
The program has ended, but the last thing it wrote may still be on its
way.  Wait for the end of it, briefly: something the program started
may be holding the other end open for good."
  (when-let* ((stderr (get-buffer-process errors)))
    (let ((deadline (+ (float-time) 0.5)))
      (while (and (process-live-p stderr) (< (float-time) deadline))
        (accept-process-output stderr 0.01 nil t)))))

(defun mega-exec--discard (process errors)
  "Kill PROCESS if it lives, and remove its buffer and ERRORS."
  (when (and process (process-live-p process))
    (delete-process process))
  (when (buffer-live-p errors)
    (when-let* ((stderr (get-buffer-process errors)))
      (delete-process stderr))
    (kill-buffer errors))
  (when (and process (buffer-live-p (process-buffer process)))
    (kill-buffer (process-buffer process))))

;;;; Running a program and waiting for it

(defun mega-exec--count-lines (buffer)
  "Number of complete lines in BUFFER."
  (with-current-buffer buffer
    (count-lines (point-min) (point-max))))

(defun mega-exec-run (program args &rest options)
  "Run PROGRAM with ARGS, wait for it, and return what happened.
OPTIONS is a plist:

  :directory  where to run it (default `default-directory')
  :local      ignore any container context: run where the files are
  :here       run on this machine, whatever DIRECTORY is
  :input      a string to send on standard input
  :limit      stop the program once it has printed this many lines
  :timeout    stop it after this many seconds, input included

The result is a plist: :status (the exit code, or nil if it was stopped),
:output and :error (strings), and :stopped (`limit' or `timeout', or nil).

The wait can be abandoned: under `while-no-input', or on `C-g', control
leaves this function and the program is killed."
  (let* ((limit (plist-get options :limit))
         (timeout (plist-get options :timeout))
         (start (float-time))
         (output (generate-new-buffer " *mega-exec*" t))
         process errors stopped)
    (unwind-protect
        (progn
          (let ((made (mega-exec--make program args options
                                       :name "mega-exec" :buffer output
                                       :coding 'utf-8-unix :sentinel #'ignore)))
            (setq process (car made)
                  errors (cdr made)))
          (setq stopped (mega-exec--feed process (plist-get options :input) timeout))
          (while (and (process-live-p process) (not stopped))
            (accept-process-output process 0.05)
            (cond ((and limit (>= (mega-exec--count-lines output) limit))
                   (setq stopped 'limit))
                  ((and timeout (> (- (float-time) start) timeout))
                   (setq stopped 'timeout))))
          (if stopped
              (delete-process process)
            ;; Collect whatever was still in the pipes when it exited.
            (while (accept-process-output process 0 nil t))
            (mega-exec--drain errors))
          (list :status (unless stopped (process-exit-status process))
                :output (with-current-buffer output (buffer-string))
                :error (with-current-buffer errors (buffer-string))
                :stopped stopped))
      (mega-exec--discard process errors)
      (when (buffer-live-p output) (kill-buffer output)))))

(defun mega-exec-lines (program args &rest options)
  "Run PROGRAM with ARGS and return its output as a list of lines.
OPTIONS are those of `mega-exec-run'.  With :limit, at most that many
lines come back."
  (let* ((result (apply #'mega-exec-run program args options))
         (lines (split-string (plist-get result :output) "\n" t))
         (limit (plist-get options :limit)))
    (if (and limit (> (length lines) limit))
        (take limit lines)
      lines)))

;;;; Running a program without waiting for it

(defun mega-exec--finish (process &optional stopped)
  "Hand the result of PROCESS to whoever started it, once.
STOPPED, if given, is why it did not run to its end."
  (when-let* ((then (process-get process 'mega-exec-then)))
    (process-put process 'mega-exec-then nil)
    (let* ((output (process-buffer process))
           (errors (process-get process 'mega-exec-errors))
           (killed (not (eq (process-status process) 'exit))))
      (unless killed
        (mega-exec--drain errors))
      (let ((result
             (list :status (unless (or killed stopped) (process-exit-status process))
                   :output (if (buffer-live-p output)
                               (with-current-buffer output (buffer-string))
                             "")
                   :error (if (buffer-live-p errors)
                              (with-current-buffer errors (buffer-string))
                            "")
                   :stopped (or stopped (and killed 'killed)))))
        (mega-exec--discard process errors)
        ;; This runs whenever the program happens to end, in the middle of
        ;; whatever you are doing: a mistake in THEN is reported, not raised.
        (condition-case err
            (funcall then result)
          (error (message "MEGA: %s" (error-message-string err))))))))

(defun mega-exec-start (program args &rest options)
  "Start PROGRAM with ARGS and return its process at once.
For a program that may take a while: Emacs stays usable, and the answer
arrives later.  OPTIONS is a plist:

  :directory  where to run it (default `default-directory')
  :local      ignore any container context: run where the files are
  :here       run on this machine, whatever DIRECTORY is
  :input      a string to send on standard input
  :then       function called once, with the result, when the program ends

The result is the plist `mega-exec-run' returns; its :stopped is `killed'
if the program was stopped, for instance by `mega-exec-stop', and
`timeout' if it would not take its input."
  (let* ((output (generate-new-buffer " *mega-exec*" t))
         (made (condition-case err
                   (mega-exec--make program args options
                                    :name "mega-exec" :buffer output
                                    :coding 'utf-8-unix
                                    :sentinel (lambda (process _event)
                                                (unless (process-live-p process)
                                                  (mega-exec--finish process))))
                 (error (kill-buffer output)
                        (signal (car err) (cdr err)))))
         (process (car made)))
    (process-put process 'mega-exec-then (or (plist-get options :then) #'ignore))
    (process-put process 'mega-exec-errors (cdr made))
    (when (mega-exec--feed process (plist-get options :input))
      (mega-exec--finish process 'timeout))
    process))

(defun mega-exec-stop (process)
  "Stop PROCESS, a program started with `mega-exec-start' or `mega-exec-open'.
A :then or :sentinel function is still called."
  (when (process-live-p process)
    (delete-process process)))

;;;; Talking to a program

(defun mega-exec-open (program args &rest options)
  "Start PROGRAM with ARGS for a conversation and return its process.
What it prints is handed over as it arrives.  OPTIONS is a plist:

  :directory  where to run it (default `default-directory')
  :local      ignore any container context: run where the files are
  :here       run on this machine, whatever DIRECTORY is
  :name       a name for the process
  :coding     how to read what it prints; by default not at all: the
              filter gets raw bytes, as a protocol needs them
  :filter     function (PROCESS OUTPUT) called with what it prints
  :errors     function (PROCESS TEXT) called with what it writes to its
              error output; without one that is dropped
  :sentinel   function (PROCESS) called once it has ended

Send to it with `process-send-string'.  What it writes to its error
output is kept out of the conversation.  Errors in the three functions
are reported, never raised: they run between your keystrokes."
  (let* ((filter (or (plist-get options :filter) #'ignore))
         (errors (plist-get options :errors))
         (sentinel (or (plist-get options :sentinel) #'ignore))
         (guarded (lambda (function &rest arguments)
                    (condition-case err
                        (apply function arguments)
                      (error (message "MEGA: %s" (error-message-string err))))))
         (made
          (mega-exec--make
           program args options
           :name (or (plist-get options :name) "mega-exec-open")
           :buffer nil
           :coding (or (plist-get options :coding) 'binary)
           :filter (lambda (process output)
                     (funcall guarded filter process output))
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         ;; The last of what it wrote may still be on its way.
                         (mega-exec--drain (process-get process 'mega-exec-errors))
                         (mega-exec--discard nil (process-get process 'mega-exec-errors))
                         (funcall guarded sentinel process)))))
         (process (car made)))
    (process-put process 'mega-exec-errors (cdr made))
    (when errors
      (when-let* ((stderr (get-buffer-process (cdr made))))
        (set-process-filter stderr (lambda (_stderr text)
                                     (funcall guarded errors process text)))))
    process))

(provide 'mega-exec)
;;; mega-exec.el ends here
