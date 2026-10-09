;;; mega-minibuffer.el --- Choosing from a list  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every prompt that offers choices — commands, files, buffers, anything —
;; shows them as a vertical list that narrows as you type, matching fuzzily:
;; "mgki" finds `mega-keys-mode'.  All of it ships with Emacs: the list is
;; `fido-vertical-mode', the matching is the `flex' completion style, which
;; Emacs 31 rewrote to be fast.
;;
;; `C-n'/`C-p' or the arrows move, RET takes the highlighted entry, `M-j'
;; takes exactly what you typed.

;;; Code:

(require 'mega-lib)

(defvar icomplete-compute-delay)
(defvar icomplete-prospects-height)
(defvar icomplete-scroll)
(defvar icomplete-show-matches-on-no-input)

(setq completion-ignore-case t
      read-file-name-completion-ignore-case t
      read-buffer-completion-ignore-case t
      ;; Say what a candidate is next to its name, where Emacs knows.
      completions-detailed t
      ;; A command run from a prompt may itself need to prompt.
      enable-recursive-minibuffers t
      icomplete-show-matches-on-no-input t
      icomplete-prospects-height 12
      icomplete-scroll t
      ;; The list is recomputed while you type, and abandoned if you type
      ;; again first, so a short delay costs nothing and saves work.
      icomplete-compute-delay 0.05
      max-mini-window-height 0.4)

(fido-vertical-mode 1)
(minibuffer-depth-indicate-mode 1)

(provide 'mega-minibuffer)
;;; mega-minibuffer.el ends here
