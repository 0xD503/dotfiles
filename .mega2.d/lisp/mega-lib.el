;;; mega-lib.el --- Paths and helpers shared by every MEGA module  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded from `early-init.el', before anything else, so this file depends on
;; nothing but Emacs itself.  It is also the one file that has to load on an
;; Emacs older than MEGA supports: the version gate in `early-init.el' needs
;; the paths below to keep even a refused session from writing into the
;; configuration directory.  Keep it free of anything newer than Emacs 27.
;;
;; It has four jobs.
;;
;; 1. Decide where things live.  MEGA treats its own directory as read-only:
;;    it is a deployed copy of the dotfiles repo, and every mutable byte goes
;;    to a private XDG directory instead.  That is what lets
;;    `./update.sh diff' report real drift rather than runtime churn.
;;
;; 2. Say which files are private, in one place, so that history, recent
;;    files, saved places and (later) persistent undo all agree.
;;
;; 3. Probe the machine for optional programs, cheaply.
;;
;; 4. Load modules without betting the session on any one of them.

;;; Code:

(defconst mega-version "2.0.0-m2"
  "The MEGA version.  The suffix names the last finished milestone.")

(defgroup mega nil
  "MEGA: a self-sufficient, terminal-first Emacs configuration.
Every choice MEGA offers is a user option in this group, so
\\[customize-group] mega lists them all.  Set them in local.el."
  :group 'convenience
  :prefix "mega-")

(defconst mega-lisp-dir (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding MEGA's own Lisp.")

(defconst mega-dir (file-name-directory (directory-file-name mega-lisp-dir))
  "MEGA's configuration directory, the deployed copy of `.mega2.d'.
Nothing is written here at runtime.")

;;;; Where mutable state lives

(defun mega--xdg (env fallback)
  "Return MEGA's subdirectory of the XDG directory named by ENV.
FALLBACK, relative to the home directory, is used when ENV is unset,
empty or not absolute, as the XDG specification requires."
  (let ((value (getenv env)))
    (file-name-as-directory
     (expand-file-name
      "mega2"
      (if (and value (file-name-absolute-p value))
          value
        (expand-file-name fallback "~"))))))

(defconst mega-cache-dir (mega--xdg "XDG_CACHE_HOME" ".cache")
  "Regenerable data: the eln cache, backups, auto-saves, lock files.
Deleting this directory loses nothing that cannot be rebuilt offline.")

(defconst mega-state-dir (mega--xdg "XDG_STATE_HOME" ".local/state")
  "State worth keeping across restarts: history, places, custom.el.")

(defconst mega-data-dir (mega--xdg "XDG_DATA_HOME" ".local/share")
  "Data that needs the network to recreate: tree-sitter parsers.")

(defun mega--private-directory (dir)
  "Create DIR and its parents if needed, readable by the owner only."
  (unless (file-directory-p dir)
    (with-file-modes #o700 (make-directory dir t)))
  dir)

(defun mega-protect-directories ()
  "Make MEGA's three state directories private, creating them if needed.
They hold history, backups of your files and undo data; a directory that
only the owner can enter protects everything below it, whatever mode the
files inside were created with."
  (dolist (dir (list mega-cache-dir mega-state-dir mega-data-dir))
    (mega--private-directory dir)
    (unless (= (logand (file-modes dir) #o777) #o700)
      (set-file-modes dir #o700))))

(defun mega--in (dir name)
  "Expand NAME inside DIR, creating the containing directory."
  (let ((path (expand-file-name name dir)))
    (mega--private-directory (file-name-directory path))
    path))

(defun mega-cache (name) "Path to NAME in `mega-cache-dir'." (mega--in mega-cache-dir name))
(defun mega-state (name) "Path to NAME in `mega-state-dir'." (mega--in mega-state-dir name))
(defun mega-data  (name) "Path to NAME in `mega-data-dir'."  (mega--in mega-data-dir  name))

;;;; Private files

(defcustom mega-private-file-regexps
  '("\\.gpg\\'" "\\.age\\'" "\\.asc\\'" "\\.pem\\'" "\\.key\\'"
    "\\.p12\\'" "\\.pfx\\'" "\\.kdbx?\\'"
    "/\\.ssh/" "/\\.gnupg/" "/\\.password-store/" "/\\.aws/"
    "/id_\\(?:rsa\\|dsa\\|ecdsa\\|ed25519\\)[^/]*\\'"
    "/\\.env\\(?:\\.[^/]*\\)?\\'"
    "/\\.netrc\\'" "/\\.authinfo\\'" "/\\.npmrc\\'" "/\\.pypirc\\'"
    "/\\.?\\(?:secrets?\\|credentials\\)\\(?:\\.\\(?:ya?ml\\|json\\|toml\\|ini\\|env\\|txt\\)\\)?\\'"
    ;; Where `pass', `sudoedit' and friends put a secret while you edit it.
    "\\`/dev/shm/" "\\`/run/user/")
  "Regexps matching files whose names or contents MEGA must not remember.
A file matching any of these is left out of the recent-files list and
saved cursor places, and will be left out of persistent undo.  Backups
and auto-saves still cover it: losing work is worse than keeping a copy
in a directory only you can read."
  :type '(repeat regexp)
  :group 'mega)

(defun mega-private-file-p (file)
  "Non-nil if FILE matches one of `mega-private-file-regexps'."
  (let ((name (expand-file-name file))
        (case-fold-search nil)
        (found nil))
    (dolist (regexp mega-private-file-regexps found)
      (when (string-match-p regexp name)
        (setq found t)))))

;;;; Probing the machine

(defvar mega--exe-cache (make-hash-table :test #'equal)
  "Memo table for `mega-exe-p'.  Cleared by `mega-forget-executables'.")

(defun mega-exe-p (name)
  "Return the full path of executable NAME, or nil.
Memoised: MEGA asks about the same dozen programs repeatedly, and
`executable-find' walks $PATH every time."
  (let ((hit (gethash name mega--exe-cache 'miss)))
    (if (eq hit 'miss)
        (puthash name (executable-find name) mega--exe-cache)
      hit)))

(defun mega-forget-executables ()
  "Forget cached `mega-exe-p' answers, after installing a tool mid-session."
  (interactive)
  (clrhash mega--exe-cache)
  (message "MEGA: executable cache cleared"))

;;;; Loading modules without betting the session on them

(defvar mega-module-times nil
  "Alist of (MODULE . MILLISECONDS) recorded by `mega-load-module'.")

(defvar mega-module-failures nil
  "Alist of (MODULE . MESSAGE) for modules that signalled while loading.")

(defvar mega-lazy-modules nil
  "Alist of (MODULE . COMMANDS) for modules that load on first use.")

(defvar mega-doctor-sections nil
  "Functions that each insert one more section into the `mega-doctor' report.
Lives here, not in mega-doctor.el, so that a module can add its section
without loading the doctor: `(add-to-list \\='mega-doctor-sections #\\='f t)'.")

(defun mega-load-module (spec)
  "Load one entry of `mega-modules'.
SPEC is either a feature symbol, which is required now, or a list
\(FEATURE :commands (COMMAND...)), which only arranges for FEATURE to
load the first time one of its COMMANDs runs.

A module that signals while loading is recorded and skipped; every other
module still loads and you land in a working Emacs.  The cost of a bad
change is one restart, never a rescue session in `--debug-init'."
  (if (consp spec)
      (let ((module (car spec))
            (commands (plist-get (cdr spec) :commands)))
        (dolist (command commands)
          (autoload command (symbol-name module) nil t))
        (push (cons module commands) mega-lazy-modules))
    (let ((start (current-time)))
      (condition-case err
          (progn
            (require spec)
            (push (cons spec (* 1000.0 (float-time (time-since start))))
                  mega-module-times))
        (error
         (push (cons spec (error-message-string err)) mega-module-failures))))))

(defun mega-report-module-failures ()
  "Warn about modules that failed to load, once, after startup."
  (when mega-module-failures
    (display-warning
     'mega
     (concat "These modules failed to load; the rest of MEGA is running.\n\n"
             (mapconcat (lambda (failure)
                          (format "  %s: %s" (car failure) (cdr failure)))
                        (reverse mega-module-failures) "\n")
             "\n\nRun M-x mega-doctor for the full picture.")
     :error)))

(provide 'mega-lib)
;;; mega-lib.el ends here
