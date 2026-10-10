;;; mega-task.el --- Build, run, test  -*- lexical-binding: t; -*-

;;; Commentary:

;; A task is a command of the project: build it, run it, test it.  MEGA works
;; out the usual ones from what kind of project it is, so there is nothing to
;; set up for a Cargo, Go, Zig, Make, CMake or just project.
;;
;;   C-c x b / r / t   build / run / test
;;   C-c x x           choose from every task of the project
;;   C-c x g           run the last task again
;;   C-c x k           stop the running task
;;   M-g n / M-g p     next / previous error in the output   (Emacs's keys)
;;
;; The output is an ordinary compilation buffer: errors are links, and it
;; follows the output until the first error.
;;
;; A task runs the project's own code, so it needs a project you have trusted
;; (mega-trust.el), and it runs where the project's tools are, which may be
;; its container.  To change or add tasks for a project, put them in
;; `mega-task-overrides' in local.el.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)
(require 'mega-trust)

(require 'mega-project)
(declare-function compilation-start "compile")
(declare-function kill-compilation "compile")
(declare-function recompile "compile")

(defvar compilation-scroll-output)
(defvar compilation-ask-about-save)
(defvar compilation-always-kill)
(defvar compilation-filter-hook)

(defcustom mega-task-overrides nil
  "Tasks you define yourself, per project.
An alist of (ROOT . TASKS): ROOT is a project root as `C-c x x' shows
it, TASKS a list of (NAME PROGRAM ARG...) like in `mega-project-kinds'.
They come before, and so replace, the ones MEGA works out."
  :type '(alist :key-type directory :value-type sexp)
  :group 'mega)

(defvar mega-task--last nil
  "The last task run: (ROOT NAME PROGRAM ARG...).")

;;;; Which tasks a project has

(defun mega-task-list (root)
  "The tasks of the project at ROOT: a list of (NAME PROGRAM ARG...).
Your own from `mega-task-overrides' come first, then those of each kind
of project it is (`mega-project-kinds'); each name appears once."
  (let ((tasks (copy-sequence
                (cdr (assoc (abbreviate-file-name (file-name-as-directory root))
                            mega-task-overrides)))))
    (dolist (kind (mega-project-kinds-of root))
      (dolist (task (plist-get (cdr kind) :tasks))
        (unless (assq (car task) tasks)
          (setq tasks (append tasks (list task))))))
    tasks))

;;;; Running one

(defun mega-task-command-line (root task)
  "The shell command line that runs TASK, a (NAME PROGRAM ARG...), for ROOT.
Compilation buffers take a command line, so the argument list is quoted
into one, word by word; nothing in it is interpreted by the shell."
  (mapconcat #'shell-quote-argument
             (mega-exec-command (cadr task) (cddr task) root)
             " "))

(defun mega-task-run (root task)
  "Run TASK, a (NAME PROGRAM ARG...), in the project at ROOT."
  (unless (mega-trust-p root t (format "run `%s'" (string-join (cdr task) " ")))
    (user-error "This project is not trusted; see M-x mega-trust-project"))
  (unless (mega-exec-find (cadr task) root)
    (user-error "%s is not installed" (cadr task)))
  (setq mega-task--last (cons root task))
  (let ((default-directory (file-name-as-directory root)))
    (compilation-start (mega-task-command-line root task)
                       nil
                       (lambda (_mode)
                         (format "*%s: %s*"
                                 (file-name-nondirectory (directory-file-name root))
                                 (car task))))))

(defun mega-task--root ()
  "The project the current buffer's tasks belong to."
  (mega-project-directory))

(defun mega-task--run-named (name)
  "Run the task called NAME in the current project."
  (let* ((root (mega-task--root))
         (task (assq name (mega-task-list root))))
    (unless task
      (user-error "This project has no `%s' task (C-c x x lists what it has)" name))
    (mega-task-run root task)))

;;;###autoload
(defun mega-task-build () "Build the project." (interactive) (mega-task--run-named 'build))
;;;###autoload
(defun mega-task-run-project () "Run the project." (interactive) (mega-task--run-named 'run))
;;;###autoload
(defun mega-task-test () "Test the project." (interactive) (mega-task--run-named 'test))

;;;###autoload
(defun mega-task-choose ()
  "Choose one of the project's tasks and run it."
  (interactive)
  (let* ((root (mega-task--root))
         (tasks (mega-task-list root)))
    (unless tasks
      (user-error "MEGA knows no tasks for %s" (abbreviate-file-name root)))
    (let* ((names (mapcar (lambda (task)
                            (format "%-10s %s" (car task) (string-join (cdr task) " ")))
                          tasks))
           (choice (completing-read
                    (format "Task in %s: " (abbreviate-file-name root)) names nil t)))
      (mega-task-run root (nth (seq-position names choice) tasks)))))

;;;###autoload
(defun mega-task-again ()
  "Run the last task again."
  (interactive)
  (unless mega-task--last
    (user-error "No task has been run yet"))
  (mega-task-run (car mega-task--last) (cdr mega-task--last)))

;;;###autoload
(defun mega-task-stop ()
  "Stop the task that is running."
  (interactive)
  (kill-compilation))

;;;; How task output behaves

(with-eval-after-load 'compile
  (setq compilation-scroll-output 'first-error
        ;; Unsaved buffers are offered for saving before a task runs, never
        ;; saved silently and never ignored.
        compilation-ask-about-save t)
  ;; Tools colour their output; show the colours, not the escape codes.
  (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter))

(provide 'mega-task)
;;; mega-task.el ends here
