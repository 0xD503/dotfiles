;;; mega-edit.el --- Whitespace, undo, comments, navigation  -*- lexical-binding: t; -*-

;;; Commentary:

;; Text-editing behaviour.  Two ordering rules matter here:
;;
;; * editorconfig is loaded *after* MEGA's own whitespace defaults, so a
;;   project's .editorconfig always wins.  That is the entire point of
;;   supporting it.
;;
;; * smartscan is disabled in the minibuffer, where M-n/M-p must remain
;;   history navigation.

;;; Code:

(require 'mega-lib)

;;;; Whitespace and line endings
;;
;; ws-butler trims only the lines you actually touched.  Trimming the whole
;; buffer on save is how you end up with a 400-line whitespace diff on a file
;; you opened to read.

(use-package ws-butler
  :ensure t
  :hook ((prog-mode text-mode conf-mode) . ws-butler-mode)
  :custom (ws-butler-keep-whitespace-before-point nil))

;; New files get Unix line endings.  Existing files keep whatever they have —
;; silently rewriting a CRLF file is a diff nobody asked for.
(defun mega-edit--unix-eol-for-new-files ()
  "Use LF for a file that does not exist yet."
  (when (and buffer-file-name (not (file-exists-p buffer-file-name)))
    (setq buffer-file-coding-system 'utf-8-unix)))
(add-hook 'find-file-hook #'mega-edit--unix-eol-for-new-files)

;; editorconfig ships with Emacs 30.  Loaded last so the project wins.
(use-package editorconfig
  :config (editorconfig-mode 1))

;;;; Comments

(defun mega-comment-dwim (&optional arg)
  "Comment or uncomment the region, or the current line.
With ARG, pass it through to `comment-line'.  This is what `C-c C-c' is
bound to.  Note that plain `comment-region' — the usual binding — cannot
uncomment without a prefix argument, which is why MEGA does not use it."
  (interactive "P")
  (if (use-region-p)
      (comment-or-uncomment-region (region-beginning) (region-end))
    (comment-line (or arg 1))))

;;;; Undo
;;
;; vundo draws the same tree UI as undo-tree but over Emacs' own undo data, so
;; there is no parallel structure to corrupt and nothing extra to persist.
;; undo-tree remains selectable; set `mega-undo-backend' in local.el.

(defcustom mega-undo-backend 'vundo
  "Which undo visualiser `mega-undo-visualize' (C-x u) opens.
`vundo' is recommended: it visualises Emacs' built-in undo rather than
maintaining its own history, which is the source of undo-tree's
long-standing history-corruption and large-buffer stalls."
  :type '(choice (const :tag "vundo (built-in undo, recommended)" vundo)
                 (const :tag "undo-tree" undo-tree))
  :group 'mega)

(use-package vundo
  :ensure t
  :if (eq mega-undo-backend 'vundo)
  :commands (vundo)
  :custom (vundo-glyph-alist vundo-unicode-symbols))

(use-package undo-tree
  :ensure t
  :if (eq mega-undo-backend 'undo-tree)
  :custom
  (undo-tree-auto-save-history t)
  ;; Keep undo-tree's history files out of project trees; they are large and
  ;; are the thing that goes wrong.
  (undo-tree-history-directory-alist `(("." . ,(mega-cache "undo-tree/"))))
  :config (global-undo-tree-mode 1))

;; Undo across restarts, for either backend.
(use-package undo-fu-session
  :ensure t
  :if (eq mega-undo-backend 'vundo)
  :custom
  (undo-fu-session-directory (mega-cache "undo-fu-session/"))
  (undo-fu-session-incompatible-files '("\\.gpg\\'" "COMMIT_EDITMSG\\'" "git-rebase-todo\\'"))
  :config (undo-fu-session-global-mode 1))

(defun mega-undo-visualize ()
  "Open the undo visualiser for `mega-undo-backend'."
  (interactive)
  (pcase mega-undo-backend
    ('vundo (call-interactively #'vundo))
    ('undo-tree (call-interactively #'undo-tree-visualize))
    (other (user-error "Unknown `mega-undo-backend': %S" other))))

;;;; Navigating by symbol

(use-package smartscan
  :ensure t
  :config
  (global-smartscan-mode 1)
  ;; M-n/M-p belong to history inside the minibuffer.  smartscan's global
  ;; minor mode would otherwise shadow them there.
  (add-hook 'minibuffer-setup-hook (lambda () (smartscan-mode -1))))

;;;; Ordinary editing conveniences

(delete-selection-mode 1)

(use-package elec-pair
  :custom
  ;; Conservative: only auto-pair where it is unambiguous, which is what keeps
  ;; electric pairing from fighting you in strings and comments.
  (electric-pair-inhibit-predicate #'electric-pair-conservative-inhibit)
  :config (electric-pair-mode 1))

(use-package repeat
  :config (repeat-mode 1))

(provide 'mega-edit)
;;; mega-edit.el ends here
