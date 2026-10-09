;;; mega-indent-guides.el --- A thin line at each level of indentation  -*- lexical-binding: t; -*-

;;; Commentary:

;; In code, a faint vertical line is drawn at every indentation level inside
;; a line's leading spaces, so that it is easy to see which block a line
;; belongs to.  The lines are characters, so they work in a terminal.
;;
;; A guide replaces how a space is displayed; the buffer's text is not
;; changed, and nothing of it is copied or saved.  Lines indented with tabs
;; get no guides, and neither do empty lines.
;;
;; `M-x mega-indent-guides-mode' turns them on or off in a buffer.

;;; Code:

(require 'mega-lib)

(defcustom mega-indent-guides-character ?│
  "The character a guide is drawn with.
`|' is used instead on a terminal that cannot display it."
  :type 'character :group 'mega)

(defface mega-indent-guide '((t :inherit fill-column-indicator))
  "An indentation guide." :group 'mega)

(defvar mega-indent-guides-variables
  '((c-mode . c-basic-offset) (c++-mode . c-basic-offset)
    (java-mode . c-basic-offset)
    (c-ts-mode . c-ts-mode-indent-offset) (c++-ts-mode . c-ts-mode-indent-offset)
    (rust-ts-mode . rust-ts-mode-indent-offset)
    (python-mode . python-indent-offset) (python-ts-mode . python-indent-offset)
    (sh-mode . sh-basic-offset) (bash-ts-mode . sh-basic-offset)
    (js-mode . js-indent-level) (js-ts-mode . js-indent-level)
    (js-json-mode . js-indent-level)
    (typescript-ts-mode . typescript-ts-mode-indent-offset)
    (tsx-ts-mode . typescript-ts-mode-indent-offset)
    (json-ts-mode . json-ts-mode-indent-offset)
    (go-ts-mode . go-ts-mode-indent-offset)
    (lua-mode . lua-indent-level) (lua-ts-mode . lua-ts-indent-offset)
    (css-mode . css-indent-offset) (verilog-mode . verilog-indent-level)
    (emacs-lisp-mode . lisp-body-indent)
    (mega-rust-mode . mega-simple-indent-offset)
    (mega-zig-mode . mega-simple-indent-offset)
    (mega-just-mode . mega-simple-indent-offset))
  "Which variable holds the indentation width of each major mode.
A mode that is not listed uses the entry of the mode it derives from.")

(defvar-local mega-indent-guides--offset nil
  "Columns per indentation level in this buffer, once worked out.")

(defun mega-indent-guides-offset ()
  "Columns per indentation level in this buffer.
It is the value of the mode's own indentation variable, which is also
what a project's .editorconfig sets; `standard-indent' if the mode is
not in `mega-indent-guides-variables'."
  (or mega-indent-guides--offset
      (setq mega-indent-guides--offset
            (let* ((variable (seq-some (lambda (mode)
                                         (cdr (assq mode mega-indent-guides-variables)))
                                       (derived-mode-all-parents major-mode)))
                   (value (and variable (boundp variable) (symbol-value variable))))
              (if (and (integerp value) (> value 0))
                  value
                standard-indent)))))

(defun mega-indent-guides--string ()
  "The one-character string a guide is displayed as."
  (propertize (string (if (char-displayable-p mega-indent-guides-character)
                          mega-indent-guides-character
                        ?|))
              'face 'mega-indent-guide))

(defun mega-indent-guides--match (limit)
  "Font-lock matcher: the next space before LIMIT that should show a guide.
That is a space in a line's leading indentation whose column is a whole
number of levels, with code somewhere after it on the line."
  (let ((offset (mega-indent-guides-offset)) found)
    (while (and (not found) (< (point) limit))
      (let ((indentation-end (save-excursion (back-to-indentation) (point))))
        (cond ((or (>= (point) indentation-end)
                   (= indentation-end (line-end-position)))
               ;; Past the indentation, or the line is blank: next line.
               (forward-line 1))
              ((and (eq (char-after) ?\s)
                    (zerop (% (current-column) offset)))
               (set-match-data (list (point) (1+ (point))))
               (forward-char 1)
               (setq found t))
              (t (forward-char 1)))))
    found))

(defconst mega-indent-guides--keywords
  '((mega-indent-guides--match
     (0 (list 'face nil 'display (mega-indent-guides--string)))))
  "The font-lock rule that draws the guides.")

;;;###autoload
(define-minor-mode mega-indent-guides-mode
  "Draw a thin line at each level of indentation."
  :group 'mega
  (setq mega-indent-guides--offset nil)
  (if mega-indent-guides-mode
      (progn
        ;; Font-lock owns the `display' property it puts on a guide: it is
        ;; removed again whenever the text is re-highlighted.
        (add-to-list (make-local-variable 'font-lock-extra-managed-props) 'display)
        (font-lock-add-keywords nil mega-indent-guides--keywords 'append))
    (font-lock-remove-keywords nil mega-indent-guides--keywords)
    (with-silent-modifications
      (remove-text-properties (point-min) (point-max) '(display nil))))
  (when font-lock-mode
    (font-lock-flush)))

(provide 'mega-indent-guides)
;;; mega-indent-guides.el ends here
