;;; mega-lib.el --- Paths and helpers shared by every MEGA module  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded from `early-init.el', before package.el initialises, so this file
;; must depend on nothing but Emacs itself.  It has two jobs.
;;
;; 1. Decide where things live.  MEGA treats `user-emacs-directory' as
;;    read-only: it is a deployed copy of the dotfiles repo, and every mutable
;;    byte goes to an XDG directory instead.  That is what lets
;;    `./update.sh diff' report real drift rather than runtime churn.
;;
;; 2. Provide the three helpers every other module leans on: `mega-exe-p',
;;    `mega-when-exe' and `mega-load-module'.

;;; Code:

(defgroup mega nil
  "MEGA: a small, terminal-first Emacs configuration.
Every choice MEGA offers is a defcustom in this group, so
\\[customize-group] mega lists them all.  Set them in local.el."
  :group 'convenience
  :prefix "mega-")

(defconst mega-lisp-dir (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding MEGA's own Lisp.")

(defconst mega-dir (file-name-directory (directory-file-name mega-lisp-dir))
  "MEGA's configuration directory — the deployed copy of `.mega.d'.")

;;;; Where mutable state lives

(defun mega--xdg (env fallback)
  "Return the MEGA subdirectory of ENV, or of FALLBACK under $HOME."
  (file-name-as-directory
   (expand-file-name "mega" (or (getenv env) (expand-file-name fallback "~")))))

(defconst mega-cache-dir (mega--xdg "XDG_CACHE_HOME" ".cache")
  "Regenerable data: caches, compiled grammars, the eln cache.
Deleting this directory must never lose anything you care about.")

(defconst mega-state-dir (mega--xdg "XDG_STATE_HOME" ".local/state")
  "State worth keeping across restarts: history, places, custom.el.")

(defconst mega-data-dir (mega--xdg "XDG_DATA_HOME" ".local/share")
  "Installed packages.")

(defun mega--in (dir name)
  "Expand NAME inside DIR, creating the containing directory."
  (let ((path (expand-file-name name dir)))
    (make-directory (file-name-directory path) t)
    path))

(defun mega-cache (name) "Path to NAME in `mega-cache-dir'." (mega--in mega-cache-dir name))
(defun mega-state (name) "Path to NAME in `mega-state-dir'." (mega--in mega-state-dir name))
(defun mega-data  (name) "Path to NAME in `mega-data-dir'."  (mega--in mega-data-dir  name))

;;;; Probing the machine

(defvar mega--exe-cache (make-hash-table :test #'equal)
  "Memo table for `mega-exe-p'.  Cleared by `mega-forget-executables'.")

(defun mega-exe-p (name)
  "Return the full path of executable NAME, or nil.
Memoised: MEGA asks about the same dozen binaries repeatedly during
startup, and `executable-find' walks $PATH every time."
  (let ((hit (gethash name mega--exe-cache 'miss)))
    (if (eq hit 'miss)
        (puthash name (executable-find name) mega--exe-cache)
      hit)))

(defun mega-forget-executables ()
  "Forget cached `mega-exe-p' answers, after installing a tool mid-session."
  (interactive)
  (clrhash mega--exe-cache)
  (message "MEGA: executable cache cleared"))

(defun mega-project-root ()
  "Return the current project root, or nil.
Lives here rather than in mega-project.el because mega-completion.el
needs it too, and a shared helper is better than a load-order cycle.
Prefers projectile when it is loaded, and falls back to built-in
`project.el', so this keeps answering if projectile is ever dropped."
  (or (and (fboundp 'projectile-project-root) (projectile-project-root))
      (when-let* ((proj (project-current nil)))
        (project-root proj))))

(defmacro mega-when-exe (name &rest body)
  "Evaluate BODY only if executable NAME exists on this machine.
This is how MEGA stays inert rather than broken on a machine that is
missing a language server: no binary, no configuration, no error."
  (declare (indent 1) (debug (form body)))
  `(when (mega-exe-p ,name) ,@body))

;;;; Loading modules without betting the session on them

(defvar mega-module-times nil
  "Alist of (MODULE . MILLISECONDS) recorded by `mega-load-module'.")

(defvar mega-module-failures nil
  "Alist of (MODULE . MESSAGE) for modules that signalled while loading.")

(defun mega-load-module (module)
  "Require MODULE, timing it and surviving any error it signals.
A module that breaks is recorded and skipped; every other module still
loads and you land in a working Emacs.  That is what makes editing this
configuration cheap: the cost of a bad change is one restart, never a
rescue session in `--debug-init'."
  (let ((start (current-time)))
    (condition-case err
        (progn
          (require module)
          (push (cons module (* 1000.0 (float-time (time-since start))))
                mega-module-times))
      (error
       (push (cons module (error-message-string err)) mega-module-failures)))))

(defun mega-report-module-failures ()
  "Warn about modules that failed to load, once, after startup."
  (when mega-module-failures
    (display-warning
     'mega
     (concat "These modules failed to load; the rest of MEGA is running.\n\n"
             (mapconcat (lambda (f) (format "  %s: %s" (car f) (cdr f)))
                        (reverse mega-module-failures) "\n")
             "\n\nRun M-x mega-doctor for the full picture.")
     :error)))

(provide 'mega-lib)
;;; mega-lib.el ends here
