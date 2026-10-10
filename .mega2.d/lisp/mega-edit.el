;;; mega-edit.el --- Comments, whitespace, pairs, small conveniences  -*- lexical-binding: t; -*-

;;; Commentary:

;; Text-editing behaviour that is not about any one language.
;;
;;   C-c C-c     comment or uncomment the region, or the line
;;   C-c C-v     what the major mode itself has on C-c C-c
;;   M-n / M-p   next / previous occurrence of the symbol at point
;;
;; Without asking, MEGA also: closes brackets and quotes as you type them;
;; replaces the selection when you type over it; highlights TODO, FIXME and
;; friends in comments; and, on saving, removes trailing whitespace from the
;; lines you changed — only those, so a file you opened to fix one line does
;; not come back as a diff of four hundred.
;;
;; In a terminal, what you copy also goes to the system clipboard, and what
;; you paste comes from it, when xclip, wl-clipboard or pbcopy is installed.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)

(defvar electric-pair-inhibit-predicate)
(declare-function electric-pair-conservative-inhibit "elec-pair")

;;;; Comments

(defun mega-comment-dwim (&optional arg)
  "Comment or uncomment the region, or the current line.
With ARG, that many lines."
  (interactive "P")
  (if (use-region-p)
      (comment-or-uncomment-region (region-beginning) (region-end))
    (comment-line (or arg 1))))

(defun mega-major-mode-ctrl-c-ctrl-c ()
  "Run what `C-c C-c' means in this major mode.
MEGA binds that key to commenting in every buffer; this is the way to
what the mode had there, such as sending a buffer to an interpreter."
  (interactive)
  (let* ((keys (kbd "C-c C-c"))
         (local (current-local-map))
         (command (or (and local (lookup-key local keys))
                      (lookup-key global-map keys))))
    (if (commandp command)
        (progn
          (setq this-command command)
          (call-interactively command))
      (user-error "%s has nothing on C-c C-c" major-mode))))

;;;; Moving between occurrences of a symbol

(defun mega-symbol--jump (backward)
  "Go to the next occurrence of the symbol at point, or the previous if BACKWARD."
  (let ((symbol (thing-at-point 'symbol t)))
    (unless symbol
      (user-error "No symbol at point"))
    (let* ((regexp (concat "\\_<" (regexp-quote symbol) "\\_>"))
           (bounds (bounds-of-thing-at-point 'symbol))
           (offset (- (point) (car bounds)))
           (case-fold-search nil)
           (found (save-excursion
                    (goto-char (if backward (car bounds) (cdr bounds)))
                    (or (if backward
                            (re-search-backward regexp nil t)
                          (re-search-forward regexp nil t))
                        ;; Wrap around.
                        (progn
                          (goto-char (if backward (point-max) (point-min)))
                          (if backward
                              (re-search-backward regexp nil t)
                            (re-search-forward regexp nil t))))
                    (match-beginning 0))))
      (if (= found (car bounds))
          (message "No other occurrence of %s" symbol)
        (push-mark nil t)
        (goto-char (+ found offset))))))

(defun mega-symbol-next ()
  "Go to the next occurrence of the symbol at point."
  (interactive)
  (mega-symbol--jump nil))

(defun mega-symbol-previous ()
  "Go to the previous occurrence of the symbol at point."
  (interactive)
  (mega-symbol--jump t))

;;;; Trailing whitespace, on the lines you changed

(defun mega-edit--note-change (start end _length)
  "Remember that the lines from START to END were changed."
  (when (and (not undo-in-progress) (< start end))
    (with-silent-modifications
      (put-text-property (save-excursion (goto-char start) (line-beginning-position))
                         (save-excursion (goto-char end) (line-end-position))
                         'mega-edit-changed t))))

(defcustom mega-edit-trim-except-modes
  '(mega-markdown-mode markdown-mode markdown-ts-mode diff-mode)
  "Modes in which trailing whitespace is left alone on save.
In Markdown two spaces at the end of a line are a line break, and in a
diff they are part of what is being compared.  A project's
.editorconfig, when it says anything about it, decides instead."
  :type '(repeat symbol)
  :group 'mega)

(defvar editorconfig-properties-hash)

(defun mega-edit-trim-wanted-p ()
  "Non-nil if trailing whitespace should be removed from this buffer on save.
The project decides, if its .editorconfig says anything
\(`trim_trailing_whitespace\='); otherwise MEGA does, by the mode."
  (pcase (and (bound-and-true-p editorconfig-properties-hash)
              (gethash 'trim_trailing_whitespace editorconfig-properties-hash))
    ("false" nil)
    ("true" t)
    (_ (not (apply #'derived-mode-p mega-edit-trim-except-modes)))))

(defun mega-edit-trim-changed-lines ()
  "Remove trailing whitespace from the lines changed since the last save.
The line the cursor is on keeps whitespace before the cursor, so saving
in the middle of typing does not pull the cursor back.  Nothing is
removed where `mega-edit-trim-wanted-p' says no."
  (save-excursion
    (save-restriction
      (widen)
      (when (mega-edit-trim-wanted-p)
        (let ((position (point-min)) (point (point)))
          (while (setq position (text-property-any position (point-max)
                                                   'mega-edit-changed t))
            (let ((end (copy-marker (or (next-single-property-change
                                         position 'mega-edit-changed)
                                        (point-max)))))
              (goto-char position)
              (while (< (point) end)
                (end-of-line)
                (let ((line-end (point)))
                  (skip-chars-backward " \t")
                  (when (and (< (point) line-end)
                             (not (and (>= point (point)) (<= point line-end))))
                    (delete-region (point) line-end)))
                (forward-line 1))
              (setq position (marker-position end))
              (set-marker end nil)))))
      (with-silent-modifications
        (remove-text-properties (point-min) (point-max) '(mega-edit-changed nil))))))

(define-minor-mode mega-edit-trim-mode
  "Remove trailing whitespace on save, from the lines you changed only."
  :group 'mega
  (if mega-edit-trim-mode
      (progn
        (add-hook 'after-change-functions #'mega-edit--note-change nil t)
        (add-hook 'before-save-hook #'mega-edit-trim-changed-lines nil t))
    (remove-hook 'after-change-functions #'mega-edit--note-change t)
    (remove-hook 'before-save-hook #'mega-edit-trim-changed-lines t)))

(dolist (hook '(prog-mode-hook text-mode-hook conf-mode-hook))
  (add-hook hook #'mega-edit-trim-mode))

;;;; TODO and friends

(defface mega-edit-todo '((t :inherit warning))
  "TODO, HACK, XXX, NOTE and REVIEW in a comment." :group 'mega)
(defface mega-edit-fixme '((t :inherit error))
  "FIXME and BUG in a comment." :group 'mega)

(defconst mega-edit-todo-regexp
  "\\<\\(?:\\(FIXME\\|BUG\\)\\|\\(TODO\\|HACK\\|XXX\\|NOTE\\|REVIEW\\)\\)\\>"
  "Matches the words highlighted in comments.
Word boundaries, not symbol boundaries: in many languages the colon of
\"TODO:\" is part of the symbol.")

(defun mega-edit--match-todo (limit)
  "Font-lock matcher: the next TODO-like word before LIMIT inside a comment."
  (let ((case-fold-search nil) found)
    (while (and (not found) (re-search-forward mega-edit-todo-regexp limit t))
      (setq found (save-match-data (nth 4 (syntax-ppss)))))
    found))

(defun mega-edit-highlight-todo ()
  "Highlight TODO, FIXME and friends in the comments of this buffer."
  (font-lock-add-keywords
   nil
   '((mega-edit--match-todo (1 'mega-edit-fixme prepend t)
                            (2 'mega-edit-todo prepend t)))
   'append))

(add-hook 'prog-mode-hook #'mega-edit-highlight-todo)

;;;; Folding
;;
;; Emacs's own Hide/Show, with two keys instead of its eight.  It is switched
;; on in a buffer the first time you fold something there, so a buffer you
;; never fold in pays nothing for it.

(declare-function hs-toggle-hiding "hideshow")
(declare-function hs-hide-all "hideshow")
(declare-function hs-show-all "hideshow")
(defvar hs-minor-mode)

(defun mega-fold--ready ()
  "Switch Hide/Show on in the current buffer, if it is not."
  (unless (bound-and-true-p hs-minor-mode)
    (hs-minor-mode 1)))

(defun mega-fold--any-p ()
  "Non-nil if something in the current buffer is folded."
  (seq-some (lambda (overlay) (overlay-get overlay 'hs))
            (overlays-in (point-min) (point-max))))

;;;###autoload
(defun mega-fold-toggle ()
  "Fold the block the cursor is in, or unfold it."
  (interactive)
  (mega-fold--ready)
  (hs-toggle-hiding))

;;;###autoload
(defun mega-fold-all ()
  "Fold every block of the buffer; if anything is folded, unfold everything."
  (interactive)
  (mega-fold--ready)
  (if (mega-fold--any-p)
      (hs-show-all)
    (hs-hide-all)))

;;;; Indentation guides
;;
;; The mode itself is in mega-indent-guides.el and loads with the first code
;; buffer.

(autoload 'mega-indent-guides-mode "mega-indent-guides" nil t)
(add-hook 'prog-mode-hook #'mega-indent-guides-mode)

;;;; Typing conveniences, all from Emacs itself

(delete-selection-mode 1)

;; Conservative: pair only where it is unambiguous, which is what keeps
;; pairing from fighting you inside strings and comments.
(setq electric-pair-inhibit-predicate #'electric-pair-conservative-inhibit)
(electric-pair-mode 1)

;; After a command that makes sense repeated, its last key repeats it.
(mega-after-startup #'repeat-mode)

;;;; The system clipboard, in a terminal

(defun mega-clipboard--tool ()
  "Return (COPY-COMMAND . PASTE-COMMAND) for this session, or nil.
Each is an argument list.  Nil in a graphical Emacs, which needs no
help, and wherever no clipboard is reachable."
  (unless (display-graphic-p)
    (cond ((and (getenv "WAYLAND_DISPLAY") (mega-exe-p "wl-copy") (mega-exe-p "wl-paste"))
           '(("wl-copy") . ("wl-paste" "--no-newline")))
          ((and (getenv "DISPLAY") (mega-exe-p "xclip"))
           '(("xclip" "-selection" "clipboard" "-in")
             . ("xclip" "-selection" "clipboard" "-out")))
          ((and (mega-exe-p "pbcopy") (mega-exe-p "pbpaste"))
           '(("pbcopy") . ("pbpaste"))))))

(defvar mega-clipboard--last nil
  "The text MEGA last gave to, or took from, the system clipboard.")

(defun mega-clipboard-copy (text)
  "Give TEXT to the system clipboard.  Never signals."
  (ignore-errors
    (when-let* ((command (car (mega-clipboard--tool))))
      (setq mega-clipboard--last text)
      ;; Not waited for: xclip stays alive to serve the selection.  And on
      ;; this machine, where the clipboard is, whatever file is being edited.
      (mega-exec-start (car command) (cdr command) :here t :input text))))

(defun mega-clipboard-paste ()
  "Return the text of the system clipboard, if it is new.
Nil when it is what Emacs put there itself, so that pasting keeps using
the kill ring, with its history.  Never signals."
  (ignore-errors
    (when-let* ((command (cdr (mega-clipboard--tool))))
      (let* ((result (mega-exec-run (car command) (cdr command)
                                    :here t :timeout 1))
             (text (plist-get result :output)))
        (when (and (eql (plist-get result :status) 0)
                   (not (string-empty-p text))
                   (not (equal text mega-clipboard--last)))
          (setq mega-clipboard--last text)
          text)))))

(defun mega-clipboard-setup ()
  "Connect killing and yanking to the system clipboard, where one is reachable."
  (when (mega-clipboard--tool)
    (setq interprogram-cut-function #'mega-clipboard-copy
          interprogram-paste-function #'mega-clipboard-paste)))

;; The terminal, and with it DISPLAY, is known once startup is over.
(add-hook 'emacs-startup-hook #'mega-clipboard-setup)

(provide 'mega-edit)
;;; mega-edit.el ends here
