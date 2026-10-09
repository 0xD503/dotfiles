;;; mega-exec.el --- The one way MEGA runs a program  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every program MEGA starts goes through this file.  That buys three things.
;;
;; * Security.  A program is always an argument list, never a shell string, so
;;   a file name or a search pattern cannot become a command.
;;
;; * Context.  A project may live on this machine, on a remote one (TRAMP), or
;;   have its tools inside a dev container.  Callers say what to run and
;;   where; this file works out how.  A context is found by asking
;;   `mega-exec-context-functions', which is how the container module plugs in
;;   without any other module knowing about containers.
;;
;; * Responsiveness.  `mega-exec-run' waits for the program but stays
;;   interruptible: under `while-no-input' a keystroke abandons the wait, and
;;   the program is killed on the way out, never left running.
;;   `mega-exec-start' does not wait at all, for a program that takes long.
;;
;; A context is a plist:
;;
;;   :kind      `local', or whatever the module providing it calls it
;;   :name      a short label for the modeline and the doctor
;;   :wrap      function (PROGRAM ARGS DIRECTORY) returning the argument list
;;              that runs PROGRAM inside the context
;;   :find      function (PROGRAM) returning non-nil if PROGRAM exists there
;;   :to-inside / :to-host
;;              functions translating a file name in each direction

;;; Code:

(require 'mega-lib)

(defvar mega-exec-context-functions nil
  "Functions that may claim a directory for a non-local context.
Each is called with a directory and returns a context plist or nil; the
first non-nil answer wins.  See the Commentary for the plist.")

(defconst mega-exec-local-context '(:kind local :name nil)
  "The context of a program that simply runs here.")

(defun mega-exec-context (&optional directory)
  "Return the execution context of DIRECTORY, by default `default-directory'."
  (or (run-hook-with-args-until-success
       'mega-exec-context-functions
       (expand-file-name (or directory default-directory)))
      mega-exec-local-context))

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

;;;; Running a program and waiting for it

(defun mega-exec--feed (process input)
  "Send INPUT, if any, to PROCESS, and then the end of its input.
A program may finish, or stop reading, before it has been sent
everything; a quick one on a busy machine may be gone before it is sent
anything.  Neither is an error here: what the program printed and how it
ended are the answer, and the caller has both."
  (condition-case nil
      (progn
        (when input
          (process-send-string process input))
        (process-send-eof process))
    (error nil)))

(defun mega-exec--drain (errors)
  "Read the rest of a program's error output into the buffer ERRORS.
The program has ended, but the last thing it wrote may still be on its
way.  Wait for the end of it, briefly: something the program started
may be holding the other end open for good."
  (when-let* ((stderr (get-buffer-process errors)))
    (let ((deadline (+ (float-time) 0.5)))
      (while (and (process-live-p stderr) (< (float-time) deadline))
        (accept-process-output stderr 0.01 nil t)))))

(defun mega-exec--count-lines (buffer)
  "Number of complete lines in BUFFER."
  (with-current-buffer buffer
    (count-lines (point-min) (point-max))))

(defun mega-exec-run (program args &rest options)
  "Run PROGRAM with ARGS, wait for it, and return what happened.
OPTIONS is a plist:

  :directory  where to run it (default `default-directory')
  :local      ignore any container context, see `mega-exec-command'
  :input      a string to send on standard input
  :limit      stop the program once it has printed this many lines
  :timeout    stop it after this many seconds

The result is a plist: :status (the exit code, or nil if it was stopped),
:output and :error (strings), and :stopped (`limit' or `timeout', or nil).

The wait can be abandoned: under `while-no-input', or on `C-g', control
leaves this function and the program is killed."
  (let* ((directory (expand-file-name
                     (or (plist-get options :directory) default-directory)))
         (default-directory directory)
         (limit (plist-get options :limit))
         (timeout (plist-get options :timeout))
         (input (plist-get options :input))
         (output (generate-new-buffer " *mega-exec*" t))
         (errors (generate-new-buffer " *mega-exec-stderr*" t))
         (start (float-time))
         process stopped)
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "mega-exec"
                 :buffer output
                 :stderr errors
                 :command (mega-exec-command program args directory
                                             (plist-get options :local))
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :sentinel #'ignore
                 :file-handler t))
          (when-let* ((stderr (get-buffer-process errors)))
            (set-process-query-on-exit-flag stderr nil)
            (set-process-sentinel stderr #'ignore))
          (mega-exec--feed process input)
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
      (when (and process (process-live-p process))
        (delete-process process))
      (when-let* ((stderr (get-buffer-process errors)))
        (delete-process stderr))
      (kill-buffer output)
      (kill-buffer errors))))

;;;; Running a program without waiting for it

(defun mega-exec--finish (process)
  "Hand the result of PROCESS to whoever started it, once."
  (when-let* ((then (process-get process 'mega-exec-then)))
    (process-put process 'mega-exec-then nil)
    (let* ((output (process-buffer process))
           (errors (process-get process 'mega-exec-errors))
           (killed (not (eq (process-status process) 'exit))))
      (unless killed
        (mega-exec--drain errors))
      (when-let* ((stderr (get-buffer-process errors)))
        (delete-process stderr))
      (let ((result
             (list :status (unless killed (process-exit-status process))
                   :output (if (buffer-live-p output)
                               (with-current-buffer output (buffer-string))
                             "")
                   :error (if (buffer-live-p errors)
                              (with-current-buffer errors (buffer-string))
                            "")
                   :stopped (and killed 'killed))))
        (when (buffer-live-p output) (kill-buffer output))
        (when (buffer-live-p errors) (kill-buffer errors))
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
  :local      ignore any container context, see `mega-exec-command'
  :input      a string to send on standard input
  :then       function called once, with the result, when the program ends

The result is the plist `mega-exec-run' returns; its :stopped is `killed'
if the program was stopped, for instance by `mega-exec-stop'."
  (let* ((directory (expand-file-name
                     (or (plist-get options :directory) default-directory)))
         (default-directory directory)
         (input (plist-get options :input))
         (output (generate-new-buffer " *mega-exec*" t))
         (errors (generate-new-buffer " *mega-exec-stderr*" t))
         (process
          (make-process
           :name "mega-exec"
           :buffer output
           :stderr errors
           :command (mega-exec-command program args directory
                                       (plist-get options :local))
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (mega-exec--finish process)))
           :file-handler t)))
    (process-put process 'mega-exec-then (or (plist-get options :then) #'ignore))
    (process-put process 'mega-exec-errors errors)
    (when-let* ((stderr (get-buffer-process errors)))
      (set-process-query-on-exit-flag stderr nil)
      (set-process-sentinel stderr #'ignore))
    (mega-exec--feed process input)
    process))

(defun mega-exec-stop (process)
  "Stop PROCESS, a program started with `mega-exec-start'.
Its :then function is still called, with :stopped set."
  (when (process-live-p process)
    (delete-process process)))

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

(provide 'mega-exec)
;;; mega-exec.el ends here
