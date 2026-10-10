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
(require 'mega-lang)

(defcustom mega-indent-guides-character ?│
  "The character a guide is drawn with.
`|' is used instead on a terminal that cannot display it."
  :type 'character :group 'mega)

(defface mega-indent-guide '((t :inherit fill-column-indicator))
  "An indentation guide." :group 'mega)

(defvar mega-indent-guides-variables
  '((java-mode . c-basic-offset)
    (css-mode . css-indent-offset)
    (emacs-lisp-mode . lisp-body-indent))
  "Which variable holds the indentation width of a major mode.
For modes of languages that are not in `mega-languages', and ahead of
what a row there says.  A mode that is not listed uses the entry of the
mode it derives from.")

(defvar-local mega-indent-guides--offset nil
  "Columns per indentation level in this buffer, once worked out.")

(defun mega-indent-guides-variable (&optional mode)
  "The variable that holds the indentation width of MODE, or nil.
MODE defaults to the mode of the current buffer."
  (let ((mode (or mode major-mode)))
    (or (seq-some (lambda (parent)
                    (cdr (assq parent mega-indent-guides-variables)))
                  (derived-mode-all-parents mode))
        (mega-lang-indent-variable mode))))

(defun mega-indent-guides-offset ()
  "Columns per indentation level in this buffer.
It is the value of the mode's own indentation variable, which is also
what a project's .editorconfig sets; `standard-indent' if neither
`mega-indent-guides-variables' nor `mega-languages' knows the mode."
  (or mega-indent-guides--offset
      (setq mega-indent-guides--offset
            (let* ((variable (mega-indent-guides-variable))
                   (value (and variable (boundp variable) (symbol-value variable))))
              (if (and (integerp value) (> value 0))
                  value
                standard-indent)))))

(defvar-local mega-indent-guides--string nil
  "The one-character string a guide is displayed as, in this buffer.")

(defun mega-indent-guides--string ()
  "The one-character string a guide is displayed as.
Made once per buffer: it is asked for at every guide."
  (or mega-indent-guides--string
      (setq mega-indent-guides--string
            (propertize (string (if (char-displayable-p mega-indent-guides-character)
                                    mega-indent-guides-character
                                  ?|))
                        'face 'mega-indent-guide))))

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

;; A guide is drawn by giving a space of the indentation something else to
;; be displayed as.  Emacs's property for that is `display', which other
;; features use too, and whoever lets font-lock manage a property has it
;; removed from the whole buffer at every re-highlighting.  So the guides get
;; a property of their own, which Emacs is told to treat as `display'.

(defconst mega-indent-guides--keywords
  '((mega-indent-guides--match
     (0 (list 'face nil 'mega-indent-guides-display (mega-indent-guides--string)))))
  "The font-lock rule that draws the guides.")

(defun mega-indent-guides--alias (on)
  "Make `mega-indent-guides-display' stand in for `display' here, if ON."
  (let* ((entry (assq 'display char-property-alias-alist))
         (others (remq 'mega-indent-guides-display (cdr entry)))
         (names (if on (cons 'mega-indent-guides-display others) others)))
    (setq-local char-property-alias-alist
                (append (and names (list (cons 'display names)))
                        (assq-delete-all 'display
                                         (copy-alist char-property-alias-alist))))))

;;;###autoload
(define-minor-mode mega-indent-guides-mode
  "Draw a thin line at each level of indentation."
  :group 'mega
  (setq mega-indent-guides--offset nil
        mega-indent-guides--string nil)
  (if mega-indent-guides-mode
      (progn
        (mega-indent-guides--alias t)
        (add-to-list (make-local-variable 'font-lock-extra-managed-props)
                     'mega-indent-guides-display)
        (font-lock-add-keywords nil mega-indent-guides--keywords 'append))
    (font-lock-remove-keywords nil mega-indent-guides--keywords)
    (with-silent-modifications
      (remove-text-properties (point-min) (point-max)
                              '(mega-indent-guides-display nil)))
    (setq-local font-lock-extra-managed-props
                (remq 'mega-indent-guides-display font-lock-extra-managed-props))
    (mega-indent-guides--alias nil))
  (when font-lock-mode
    (font-lock-flush)))

(provide 'mega-indent-guides)
;;; mega-indent-guides.el ends here
