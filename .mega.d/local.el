;;; local.el --- Machine-specific MEGA settings  -*- lexical-binding: t; -*-

;;; Commentary:

;; This file is tracked as an empty stub and excluded from update.sh in both
;; directions, exactly like .bashrc.local and .zshrc.local: deploying it would
;; clobber whatever this machine keeps here, and collecting it would push one
;; machine's overrides to every other.  Copy it into place by hand once.
;;
;; It loads BEFORE the modules, because its main job is choosing.  Anything
;; that has to run after a package has loaded goes in `with-eval-after-load',
;; which works regardless of ordering.
;;
;; Examples — all commented out:
;;
;;   ;; Try the lighter completion stack.
;;   (setq mega-completion-backend 'vertico)
;;
;;   ;; Go back to undo-tree.
;;   (setq mega-undo-backend 'undo-tree)
;;
;;   ;; Zone out after five idle minutes.
;;   (setq mega-zone-idle-seconds 300)
;;
;;   ;; Kitty keyboard protocol: extra key combinations, but it blocks until
;;   ;; the terminal answers — about 250ms here, and tmux does not forward the
;;   ;; query by default.  Only worth it if your terminal replies.
;;   (setq mega-enable-kkp t)
;;
;;   ;; Indent guides that follow tree-sitter scope (prettier, slower).
;;   (setq indent-bars-treesit-support t)
;;
;;   ;; A key of your own.
;;   (with-eval-after-load 'mega-keys
;;     (define-key mega-keys-mode-map (kbd "C-c g") #'magit-status))
;;
;;   ;; Turn inlay hints back on for Rust only.
;;   (with-eval-after-load 'eglot
;;     (add-hook 'rust-ts-mode-hook #'eglot-inlay-hints-mode))

;;; Code:



;;; local.el ends here
