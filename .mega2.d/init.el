;;; init.el --- MEGA 2.0: Make Emacs Great Again  -*- lexical-binding: t; -*-

;;; Commentary:

;; MEGA 2.0 is a self-sufficient, terminal-first Emacs configuration: it uses
;; what Emacs 31 ships and code written for MEGA, and downloads nothing.
;;
;; There is no DSL and no bootstrap.  Reading this file tells you exactly what
;; runs and in what order; reading `mega-modules' below tells you what MEGA
;; consists of.  Removing a feature is deleting a line from that list.
;;
;; README.md is the short user guide.  DESIGN.md holds the requirements, the
;; priorities behind every trade-off, and the architecture.

;;; Code:

;; Normally early-init.el has already run.  This covers an Emacs that was
;; pointed at this file directly.
(unless (featurep 'mega-lib)
  (load (expand-file-name "early-init.el"
                          (file-name-directory (or load-file-name buffer-file-name)))
        nil :nomessage))

;; Defined by early-init.el.  Declared for the byte-compiler, which sees this
;; file on its own.
(defvar mega-supported-p)
(defvar mega-minimum-emacs-version)
(defvar package-user-dir)
(require 'mega-lib)

;;;; The configuration directory is read-only
;;
;; Plenty of Emacs features write below `user-emacs-directory' without asking:
;; auto-save lists, transient history, eshell, url, tramp, abbrevs.  Pointing
;; that variable at the state directory catches all of them at once, including
;; the ones nobody thought to list.  MEGA finds its own files through
;; `mega-dir', so nothing here depends on it.
;;
;; This happens here and not in early-init.el because a profile switcher
;; looks this very file up through `user-emacs-directory'.  It happens on
;; every Emacs, supported or not.

(setq user-emacs-directory (mega-state "emacs/")
      package-user-dir (mega-data "elpa/")
      ;; Custom must never rewrite a tracked file.
      custom-file (mega-state "custom.el"))

;;;; The modules
;;
;; Order matters and is explicit.  A bare name loads at startup.  A list
;; names the commands that load the module on first use, which is how heavy
;; features stay off the startup path.  `mega-load-module' times each eager
;; module and survives its errors.

(defconst mega-modules
  '(mega-core        ; encoding, files, safety, privacy, security
    mega-ui          ; theme, modeline, line numbers, the ruler
    mega-keys        ; the single table holding every MEGA binding
    mega-minibuffer  ; the vertical, fuzzy list every prompt uses
    mega-session     ; history, recent files, places
    mega-project     ; projects, remembering them, the file tree
    mega-workspace   ; files and windows put away and brought back
    mega-home        ; the page Emacs opens on
    mega-exec        ; the one way MEGA runs a program
    mega-popup       ; a small window that floats over the text
    mega-complete    ; the completion menu
    mega-lsp         ; the language server, diagnostics, documentation
    mega-lang        ; the language table, and which mode a file gets
    ;; Loaded on first use.
    (mega-pick)      ; a prompt whose choices come from a program
    (mega-search :commands (mega-search-project mega-search-symbol))
    (mega-mode-simple)                 ; what MEGA's own modes share
    (mega-mode-rust)  (mega-mode-zig)  ; entered through mega-lang's table
    (mega-mode-just)  (mega-mode-markdown)
    (mega-help   :commands (mega-help))
    (mega-doctor :commands (mega-doctor)))
  "Modules MEGA consists of, in load order.
Delete a line to remove that feature; add a file to `lisp/' and a line
here to add one.  Nothing else scans the directory.")

(defun mega--report-unsupported ()
  "Say that this Emacs is too old for MEGA and that nothing was configured."
  (display-warning
   'mega
   (format "MEGA %s needs Emacs %s or newer; this is %s.
Nothing was configured: this is plain Emacs."
           mega-version mega-minimum-emacs-version emacs-version)
   :warning))

(if (not mega-supported-p)
    ;; Too old: configure nothing, say so, leave a plain working Emacs.
    (add-hook 'emacs-startup-hook #'mega--report-unsupported)

  ;; Machine-specific overrides.  local.el is tracked as a stub and never
  ;; deployed by a plain update.sh command.  It loads before the modules
  ;; because its main job is choosing: anything a module reads while loading
  ;; must already be set.  Whatever has to happen after a module loads goes
  ;; in `with-eval-after-load'.
  (let ((local (expand-file-name "local.el" mega-dir)))
    (when (file-readable-p local)
      (load local :noerror :nomessage)))

  (mapc #'mega-load-module mega-modules)

  (add-hook 'emacs-startup-hook #'mega-report-module-failures 90))

;;; init.el ends here
