;;; mega-ui.el --- Theme, modeline, icons, guides  -*- lexical-binding: t; -*-

;;; Commentary:

;; Terminal-first.  Everything here is chosen to render correctly with no
;; window system: character-based indent guides, a hand-written modeline, and
;; Nerd Font glyphs rather than image icons.
;;
;; On colour: Emacs 30.2 honours COLORTERM=truecolor and reports 16.7M colours
;; even under TERM=tmux-256color (verified on this machine — with COLORTERM
;; unset it drops to 256).  So Emacs needs no help here; what matters is that
;; tmux passes 24-bit through instead of quantising it, which is the
;; `tmux_conf_24b_colour' setting in ~/.tmux.conf.local.  `mega-doctor' reports
;; the colour depth Emacs actually got.

;;; Code:

(require 'mega-lib)

;; Under tmux, Emacs looks for term/tmux-256color.el, which does not exist, and
;; so skips xterm's terminal initialisation (key sequences, focus events).
;; Alias it to xterm and that setup applies.
(add-to-list 'term-file-aliases '("tmux-256color" . "xterm-256color"))
(add-to-list 'term-file-aliases '("tmux-direct" . "xterm-direct"))

;;;; Theme

(defconst mega-nord
  '((bg . "#2E3440") (bg1 . "#3B4252") (bg2 . "#434C5E") (dim . "#4C566A")
    (fg . "#D8DEE9") (fg1 . "#E5E9F0") (fg2 . "#ECEFF4")
    (teal . "#8FBCBB") (cyan . "#88C0D0") (blue . "#81A1C1") (deep . "#5E81AC")
    (red . "#BF616A") (orange . "#D08770") (yellow . "#EBCB8B")
    (green . "#A3BE8C") (purple . "#B48EAD"))
  "The Nord palette, so face tweaks below do not hard-code hex twice.")

(defun mega-nord-color (name)
  "Return the Nord colour called NAME."
  (alist-get name mega-nord))

(use-package nord-theme
  :ensure t
  :config
  (load-theme 'nord :no-confirm)
  ;; nord-theme predates most of what MEGA uses, so these are unstyled without
  ;; help: the modeline, corfu, hl-todo, tab-bar, indent guides and helm.
  (let ((bg1 (mega-nord-color 'bg1))
        (bg2 (mega-nord-color 'bg2)) (dim (mega-nord-color 'dim))
        (fg (mega-nord-color 'fg))   (fg2 (mega-nord-color 'fg2))
        (cyan (mega-nord-color 'cyan)) (blue (mega-nord-color 'blue))
        (red (mega-nord-color 'red)) (green (mega-nord-color 'green))
        (yellow (mega-nord-color 'yellow)) (orange (mega-nord-color 'orange))
        (purple (mega-nord-color 'purple)))
    (custom-set-faces
     `(mode-line             ((t (:background ,bg2 :foreground ,fg2 :box nil))))
     `(mode-line-inactive    ((t (:background ,bg1 :foreground ,dim :box nil))))
     `(mode-line-buffer-id   ((t (:foreground ,cyan :weight bold))))
     `(vertical-border       ((t (:foreground ,bg2 :background unspecified))))
     `(fringe                ((t (:background unspecified))))
     `(line-number           ((t (:foreground ,dim :background unspecified))))
     `(line-number-current-line ((t (:foreground ,cyan :weight bold))))
     `(fill-column-indicator ((t (:foreground ,bg1))))
     ;; Completion popup
     `(corfu-default         ((t (:background ,bg1 :foreground ,fg))))
     `(corfu-current         ((t (:background ,bg2 :foreground ,fg2))))
     `(corfu-border          ((t (:background ,dim))))
     `(corfu-bar             ((t (:background ,cyan))))
     ;; Minibuffer completion, whichever backend is active
     `(vertico-current       ((t (:background ,bg2 :extend t))))
     `(helm-selection        ((t (:background ,bg2 :extend t))))
     `(helm-source-header    ((t (:background ,bg1 :foreground ,cyan :weight bold :height 1.0))))
     `(helm-match            ((t (:foreground ,yellow :weight bold))))
     `(helm-ff-directory     ((t (:foreground ,blue))))
     `(helm-ff-file          ((t (:foreground ,fg))))
     `(orderless-match-face-0 ((t (:foreground ,cyan :weight bold))))
     ;; Workspaces
     `(tab-bar               ((t (:background ,bg1 :foreground ,dim))))
     `(tab-bar-tab           ((t (:background ,bg2 :foreground ,fg2 :weight bold))))
     `(tab-bar-tab-inactive  ((t (:background ,bg1 :foreground ,dim))))
     ;; Annotations
     `(hl-todo               ((t (:weight bold))))
     `(show-paren-match      ((t (:background ,dim :foreground ,fg2 :weight bold))))
     `(mega-modeline-modified ((t (:foreground ,orange))))
     `(mega-modeline-error    ((t (:foreground ,red))))
     `(mega-modeline-ok       ((t (:foreground ,green))))
     `(mega-modeline-vc       ((t (:foreground ,purple)))))))

;;;; Icons
;;
;; nerd-icons draws from the patched font the terminal is already using, so it
;; works in a TTY.  all-the-icons does not.

(use-package nerd-icons
  :ensure t
  :custom (nerd-icons-scale-factor 1.0))

(use-package nerd-icons-dired
  :ensure t
  :hook (dired-mode . nerd-icons-dired-mode))

;;;; Annotations and guides

(use-package hl-todo
  :ensure t
  :custom
  (hl-todo-keyword-faces
   `(("TODO"   . ,(mega-nord-color 'yellow))
     ("FIXME"  . ,(mega-nord-color 'red))
     ("BUG"    . ,(mega-nord-color 'red))
     ("HACK"   . ,(mega-nord-color 'orange))
     ("XXX"    . ,(mega-nord-color 'orange))
     ("NOTE"   . ,(mega-nord-color 'cyan))
     ("REVIEW" . ,(mega-nord-color 'purple))
     ("SAFETY" . ,(mega-nord-color 'green))))
  :config (global-hl-todo-mode 1))

(use-package indent-bars
  :ensure t
  :hook ((prog-mode conf-mode yaml-ts-mode) . indent-bars-mode)
  :custom
  ;; indent-bars already falls back to characters when `display-graphic-p' is
  ;; nil; setting this makes the terminal behaviour explicit so it cannot
  ;; change underneath us.
  (indent-bars-prefer-character t)
  (indent-bars-no-descend-string t)
  ;; The tree-sitter scope feature is genuinely nice and genuinely costs;
  ;; MEGA leaves it off.  Set to t in local.el if you want it.
  (indent-bars-treesit-support nil)
  (indent-bars-color '(shadow :face-bg nil :blend 0.35))
  (indent-bars-highlight-current-depth '(:blend 0.7)))

;;;; Modeline
;;
;; Hand-written and deliberately cheap: no icon lookup, no path shortening, no
;; per-redisplay string building beyond two short `format' calls.  doom-modeline
;; is a lot of work to run on every keystroke for information you can read from
;; the buffer anyway.

(defface mega-modeline-modified '((t :inherit warning)) "Unsaved-changes marker." :group 'mega)
(defface mega-modeline-error    '((t :inherit error))   "Diagnostics count."      :group 'mega)
(defface mega-modeline-ok       '((t :inherit success)) "Clean diagnostics."      :group 'mega)
(defface mega-modeline-vc       '((t :inherit shadow))  "Version-control branch." :group 'mega)

(defun mega-modeline--flymake ()
  "Compact diagnostics count, or nil when flymake is not running here."
  (when (bound-and-true-p flymake-mode)
    (let ((errors 0) (warnings 0))
      (dolist (d (flymake-diagnostics))
        (pcase (flymake-diagnostic-type d)
          ((or :error 'eglot-error) (cl-incf errors))
          ((or :warning 'eglot-warning) (cl-incf warnings))))
      (if (and (zerop errors) (zerop warnings))
          (propertize " ✓" 'face 'mega-modeline-ok)
        (propertize (format " %d/%d" errors warnings) 'face 'mega-modeline-error)))))

(defun mega-modeline--vc ()
  "Branch name only.  `vc-mode' is already computed by Emacs; just trim it."
  (when (and vc-mode buffer-file-name)
    (propertize (replace-regexp-in-string "\\` *\\(Git[:-]\\)?" " " vc-mode)
                'face 'mega-modeline-vc)))

(setq-default
 mode-line-format
 '("%e"
   (:eval (if (and (buffer-modified-p) buffer-file-name)
              (propertize " ●" 'face 'mega-modeline-modified)
            "  "))
   " " mode-line-buffer-identification
   "  %l:%c"
   "  " mode-name
   (:eval (mega-modeline--vc))
   (:eval (mega-modeline--flymake))
   "  " mode-line-misc-info))

;;;; Buffer appearance

(use-package display-line-numbers
  :hook (prog-mode . display-line-numbers-mode)
  :custom (display-line-numbers-width-start t))

(use-package display-fill-column-indicator
  :hook (prog-mode . display-fill-column-indicator-mode)
  :custom (display-fill-column-indicator-column 80))

(setq show-paren-delay 0
      show-paren-when-point-inside-paren t
      show-paren-context-when-offscreen 'overlay)
(show-paren-mode 1)

(column-number-mode 1)
(global-visual-line-mode -1)

;;;; which-key (built into Emacs 30)

(use-package which-key
  :custom
  (which-key-idle-delay 0.5)
  (which-key-add-column-padding 1)
  :config (which-key-mode 1))

(provide 'mega-ui)
;;; mega-ui.el ends here
