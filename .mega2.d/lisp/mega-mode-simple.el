;;; mega-mode-simple.el --- What MEGA's small language modes share  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs has no mode at all for some languages, and for others only a
;; tree-sitter mode that needs a parser you may not have built.  MEGA fills
;; those gaps with deliberately small modes: comments, strings, keywords,
;; indentation by brackets, an index of definitions.  The language server,
;; where there is one, supplies everything cleverer.
;;
;; This file holds what the brace-and-semicolon ones have in common.

;;; Code:

(require 'mega-lib)

(defcustom mega-simple-indent-offset 4
  "Columns per level of nesting in MEGA's own language modes.
A project's .editorconfig overrides it, as it does for every mode."
  :type 'integer :group 'mega :safe #'integerp)

(defun mega-simple-syntax-table (&optional block-comments)
  "Return a syntax table for a language with // comments and \"strings\".
With BLOCK-COMMENTS non-nil, /* ... */ is a comment too."
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?/ (if block-comments ". 124b" ". 12b") table)
    (when block-comments
      (modify-syntax-entry ?* ". 23" table))
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?_ "_" table)
    ;; Not a string quote: these languages use it for more than characters.
    (modify-syntax-entry ?' "." table)
    (dolist (char '(?+ ?- ?= ?% ?< ?> ?& ?| ?^ ?! ?~ ?@ ?# ?? ?: ?. ?,))
      (modify-syntax-entry char "." table))
    table))

(defun mega-simple-indentation ()
  "Return the column the current line should be indented to, or nil.
The rule is bracket depth: one level per bracket still open at the start
of the line, one less if the line begins by closing one, and one more if
it continues a chain with a leading dot.  Nil means leave the line
alone, which is the answer inside a string or a block comment."
  (save-excursion
    (back-to-indentation)
    (let ((state (syntax-ppss)))
      (unless (or (nth 3 state) (nth 4 state))
        (* mega-simple-indent-offset
           (max 0 (+ (car state)
                     (cond ((looking-at-p "[]})]") -1)
                           ((looking-at-p "\\.[^.]") 1)
                           (t 0)))))))))

(defun mega-simple-indent-line ()
  "Indent the current line by bracket depth.  See `mega-simple-indentation'."
  (interactive)
  (let ((column (mega-simple-indentation)))
    (when column
      (if (<= (current-column) (current-indentation))
          (indent-line-to column)
        (save-excursion (indent-line-to column))))))

(defun mega-simple-setup (comment)
  "Set the current buffer up as source code whose line comments start COMMENT."
  (setq-local comment-start (concat comment " ")
              comment-start-skip (concat (regexp-quote comment) "+[ \t]*")
              comment-end ""
              indent-line-function #'mega-simple-indent-line
              indent-tabs-mode nil
              electric-indent-chars (append "{}()[];" electric-indent-chars)))

(provide 'mega-mode-simple)
;;; mega-mode-simple.el ends here
