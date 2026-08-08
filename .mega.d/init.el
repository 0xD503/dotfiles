;;; init.el --- MEGA: Make Emacs Great Again  -*- lexical-binding: t; -*-

;;; Commentary:

;; MEGA is a small, terminal-first Emacs configuration built on Emacs 30's own
;; features: `use-package', `eglot', `treesit', `editorconfig', `project' and
;; `which-key' all ship with Emacs and are used as-is.  A package is added only
;; where the built-in genuinely does not exist.
;;
;; There is no DSL and no bootstrap.  Reading this file tells you exactly what
;; runs and in what order; reading `mega-modules' below tells you what MEGA
;; consists of.  Removing a feature is deleting a line from that list.
;;
;; Where a new setting goes is documented in README.md.

;;; Code:

(when (version< emacs-version "30.1")
  (error "MEGA requires Emacs 30.1 or newer; this is %s" emacs-version))

(require 'mega-lib)   ; already loaded by early-init.el; this is a no-op

;;;; Package archives
;;
;; GNU and NonGNU ELPA are curated and signed, so they outrank MELPA wherever a
;; package exists on both.  MELPA is still needed for a handful of things
;; (helm, treemacs, verilog-ts-mode) that are not on ELPA at all.

(require 'package)

(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/"))
      package-archive-priorities
      '(("gnu" . 30) ("nongnu" . 20) ("melpa" . 10))
      ;; Signature checking is the point of preferring ELPA; keep it on.
      package-check-signature 'allow-unsigned)

;; On a fresh machine the archive contents are empty and the first install
;; would fail rather than fetch.  Refresh once, lazily, only if we need to.
(defvar mega--archives-refreshed nil)
(defun mega--refresh-archives-once (&rest _)
  (unless (or mega--archives-refreshed package-archive-contents)
    (package-refresh-contents)
    (setq mega--archives-refreshed t)))
(advice-add 'package-install :before #'mega--refresh-archives-once)

(require 'use-package)
(setq use-package-enable-imenu-support t
      use-package-compute-statistics nil
      ;; Expand to the minimum when compiled; keep the debuggable form when not.
      use-package-expand-minimally (bound-and-true-p byte-compile-current-file))

;;;; Machine-specific overrides
;;
;; local.el is tracked as an empty stub and excluded from update.sh in both
;; directions, exactly like .bashrc.local and .gitconfig.local.
;;
;; It loads *before* the modules, because its main job is choosing: which
;; completion backend, which undo backend, which theme, extra package
;; archives — all of which must be set before the module that reads them runs.
;; Anything that has to happen after a package loads goes in a
;; `with-eval-after-load' form, which works regardless of ordering.

(let ((local (expand-file-name "local.el" mega-dir)))
  (when (file-readable-p local)
    (load local :noerror :nomessage)))

;;;; The modules
;;
;; Order matters and is explicit.  `mega-load-module' times each one and
;; survives its errors: a module that breaks is reported after startup instead
;; of dropping you into `--debug-init'.

(defconst mega-modules
  '(mega-core        ; encoding, files, security, sane defaults
    mega-ui          ; theme, modeline, icons, hl-todo, indent guides
    mega-keys        ; the single keymap holding every MEGA binding
    mega-completion  ; helm | vertico, plus corfu for in-buffer completion
    mega-project     ; projectile, treemacs, ripgrep
    mega-edit        ; whitespace, editorconfig, smartscan, undo, comments
    mega-treesit     ; grammar sources and safe major-mode remapping
    mega-lsp         ; eglot, eldoc, the terminal documentation popup
    mega-lang        ; the language table, and the code that reads it
    mega-session     ; workspaces, history, places
    mega-remote      ; tramp
    mega-llm         ; gptel and the Claude CLI bridge
    mega-zone        ; idle screensaver
    mega-doctor)     ; M-x mega-doctor
  "Modules MEGA loads at startup, in order.
Delete a line to remove that feature; add a file to `lisp/' and a line
here to add one.  Nothing else scans the directory.")

(mapc #'mega-load-module mega-modules)

(add-hook 'emacs-startup-hook #'mega-report-module-failures 90)

;;; init.el ends here
