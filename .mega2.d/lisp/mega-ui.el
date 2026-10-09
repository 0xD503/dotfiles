;;; mega-ui.el --- Theme, modeline, line numbers, the ruler  -*- lexical-binding: t; -*-

;;; Commentary:

;; Terminal-first.  Everything here renders with no window system: the theme
;; is plain colours, the ruler is a character, the modeline is text.
;;
;; On colour: Emacs honours COLORTERM=truecolor, including under tmux, and
;; falls back to approximating in 256 colours.  `mega-doctor' reports the
;; depth Emacs actually got.

;;; Code:

(require 'mega-lib)

(defvar display-line-numbers-width-start)
(defvar which-key-idle-delay)
(defvar which-key-add-column-padding)

;;;; Theme
;;
;; The theme is a file of MEGA's own, next to this one.

(add-to-list 'custom-theme-load-path mega-lisp-dir)
(load-theme 'mega-nord :no-confirm)

;;;; Modeline
;;
;; Hand-written and deliberately cheap: a few short strings per redisplay, no
;; icons, no path shortening.  It still shows what protects you from a
;; mistake — unsaved changes, read-only, a remote file — and the status of
;; whatever process owns the buffer.

(defface mega-modeline-modified '((t :inherit warning))
  "Unsaved-changes marker in the modeline." :group 'mega)
(defface mega-modeline-read-only '((t :inherit shadow))
  "Read-only marker in the modeline." :group 'mega)
(defface mega-modeline-remote '((t :inherit warning))
  "Remote-file marker in the modeline." :group 'mega)
(defface mega-modeline-vc '((t :inherit shadow))
  "Version-control branch in the modeline." :group 'mega)

(defun mega-modeline--glyph (glyph fallback)
  "Return GLYPH if this terminal can display it, else FALLBACK."
  (if (char-displayable-p (string-to-char glyph)) glyph fallback))

(defun mega-modeline--status ()
  "Two columns saying whether the buffer is modified or read-only."
  (cond ((and buffer-read-only buffer-file-name)
         (propertize (concat " " (mega-modeline--glyph "∅" "%"))
                     'face 'mega-modeline-read-only))
        ((and (buffer-modified-p) buffer-file-name)
         (propertize (concat " " (mega-modeline--glyph "●" "*"))
                     'face 'mega-modeline-modified))
        (t "  ")))

(defun mega-modeline--remote ()
  "The host of a remote buffer, or nil for a local one."
  (when-let* ((host (file-remote-p default-directory 'host)))
    (propertize (concat " @" host) 'face 'mega-modeline-remote)))

(defun mega-modeline--vc ()
  "Branch name only.  `vc-mode' is already computed by Emacs; just trim it."
  (when (and (stringp vc-mode) buffer-file-name)
    (propertize (replace-regexp-in-string "\\` *\\(?:Git[:-]\\)?" "  " vc-mode)
                'face 'mega-modeline-vc)))

(setq-default
 mode-line-format
 '("%e"
   (:eval (mega-modeline--status))
   " " mode-line-buffer-identification
   (:eval (mega-modeline--remote))
   "  %l:%c"
   (:eval (when (buffer-narrowed-p) " Narrow"))
   "  " mode-name mode-line-process
   (:eval (mega-modeline--vc))
   ;; Diagnostics, drawn by flymake itself whenever it is on in the buffer.
   (flymake-mode ("  " flymake-mode-line-counters))
   "  " mode-line-misc-info))

(column-number-mode 1)

;;;; Line numbers and the ruler
;;
;; The ruler is a vertical line at the line-length limit.  That limit is
;; `fill-column': 80 unless the project's .editorconfig sets
;; `max_line_length', in which case the ruler moves with it.

(defun mega-ui-line-numbers ()
  "Show line numbers in this buffer."
  (display-line-numbers-mode 1))

(defun mega-ui-ruler ()
  "Show the ruler at `fill-column' in this buffer."
  (display-fill-column-indicator-mode 1))

(setq display-line-numbers-width-start t)

(add-hook 'prog-mode-hook #'mega-ui-line-numbers)
(dolist (hook '(prog-mode-hook conf-mode-hook text-mode-hook))
  (add-hook hook #'mega-ui-ruler))

;;;; Parentheses

(setq show-paren-delay 0
      show-paren-when-point-inside-paren t
      show-paren-context-when-offscreen 'overlay)

;;;; Key hints
;;
;; which-key ships with Emacs: pause after a prefix key and it lists what can
;; follow.

(setq which-key-idle-delay 0.5
      which-key-add-column-padding 1)
(which-key-mode 1)

(provide 'mega-ui)
;;; mega-ui.el ends here
