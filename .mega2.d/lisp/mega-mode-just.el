;;; mega-mode-just.el --- justfiles  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small mode for the recipe files of `just'.  It knows recipes, their
;; bodies, variables, settings and comments, and lists the recipes in the
;; buffer index.
;;
;; Indentation follows the one rule that matters in a justfile: a recipe's
;; body is indented, everything else starts at the left edge.  A line that
;; follows a recipe header or another body line is indented one level; a
;; line that is itself a header, an assignment or a setting goes back to
;; column 0.  TAB on a body line you want to end the recipe with takes it
;; back out.

;;; Code:

(require 'mega-mode-simple)
(require 'subr-x)

(defconst mega-just-recipe-regexp
  "^@?\\([[:alpha:]_][[:alnum:]_-]*\\)\\(?:[ \t]+[^:\n]*\\)?:\\(?:[^=]\\|$\\)"
  "Matches a recipe header; group 1 is the recipe's name.
Parameters may have defaults, so an = is allowed before the colon; what
tells a recipe from an assignment is that its colon is not a `:='.")

(defconst mega-just-top-level-regexp
  (concat "\\(?:" mega-just-recipe-regexp "\\)"
          "\\|^\\(?:export[ \t]+\\)?[[:alpha:]_][[:alnum:]_-]*[ \t]*:="
          "\\|^\\(?:set\\|alias\\|import\\|mod\\|export\\)\\_>"
          "\\|^\\[")
  "Matches a line that belongs at the left edge.")

(defconst mega-just-font-lock-keywords
  `((,mega-just-recipe-regexp 1 'font-lock-function-name-face)
    ("^\\(?:export[ \t]+\\)?\\([[:alpha:]_][[:alnum:]_-]*\\)[ \t]*:=" 1 'font-lock-variable-name-face)
    ("^\\[[^]\n]*\\]" 0 'font-lock-preprocessor-face)
    (,(concat "^" (regexp-opt '("set" "alias" "import" "mod" "export") 'symbols)) 0 'font-lock-keyword-face)
    (,(regexp-opt '("if" "else" "true" "false") 'symbols) 0 'font-lock-keyword-face)
    ("{{[^}\n]*}}" 0 'font-lock-variable-use-face t)
    ("^[ \t]+\\([@-]+\\)" 1 'font-lock-builtin-face))
  "Highlighting for `mega-just-mode'.")

(defvar mega-just-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?' "\"" table)
    (modify-syntax-entry ?` "\"" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?- "_" table)
    table)
  "Syntax table of `mega-just-mode'.")

(defun mega-just--previous-line-indentation ()
  "Describe the previous non-blank line: `header', or its indentation."
  (save-excursion
    (forward-line -1)
    (while (and (not (bobp)) (looking-at-p "^[ \t]*$"))
      (forward-line -1))
    (cond ((looking-at-p "^[ \t]*$") 0)
          ((looking-at-p mega-just-recipe-regexp) 'header)
          (t (current-indentation)))))

(defun mega-just-indentation ()
  "Return the column the current line should be indented to."
  (save-excursion
    (back-to-indentation)
    (let ((previous (mega-just--previous-line-indentation))
          (case-fold-search nil))
      (cond ((save-excursion (beginning-of-line)
                             (looking-at-p (concat "[ \t]*\\(?:"
                                                   (string-remove-prefix
                                                    "^" mega-just-recipe-regexp)
                                                   "\\)")))
             0)
            ((looking-at-p "\\(?:export[ \t]+\\)?[[:alpha:]_][[:alnum:]_-]*[ \t]*:=") 0)
            ((looking-at-p "\\(?:set\\|alias\\|import\\|mod\\)\\_>\\|\\[") 0)
            ((eq previous 'header) mega-simple-indent-offset)
            (t previous)))))

(defun mega-just-indent-line ()
  "Indent the current line of a justfile.
Pressed again on a body line, it takes the line back to the left edge,
which is how a recipe ends."
  (interactive)
  (let ((column (mega-just-indentation)))
    (when (and (eq this-command last-command)
               (eq this-command 'indent-for-tab-command)
               (> (current-indentation) 0))
      (setq column 0))
    (if (<= (current-column) (current-indentation))
        (indent-line-to column)
      (save-excursion (indent-line-to column)))))

;;;###autoload
(define-derived-mode mega-just-mode prog-mode "Just"
  "A small mode for justfiles."
  (setq-local comment-start "# "
              comment-start-skip "#+[ \t]*"
              comment-end ""
              indent-line-function #'mega-just-indent-line
              indent-tabs-mode nil
              font-lock-defaults '(mega-just-font-lock-keywords)
              imenu-generic-expression
              `((nil ,mega-just-recipe-regexp 1))))

(provide 'mega-mode-just)
;;; mega-mode-just.el ends here
