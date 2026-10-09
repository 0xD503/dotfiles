;;; mega-mode-markdown.el --- Markdown  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs ships no mode for Markdown.  This is a small one, for reading and
;; writing documentation in a terminal: headings, emphasis, code, links,
;; quotes and lists are highlighted; headings fold and are listed in the
;; buffer index.
;;
;;   TAB on a heading        fold or unfold what is under it
;;   S-TAB                   fold or unfold the whole buffer
;;   C-c C-n / C-c C-p       next / previous heading
;;
;; It does not render anything, and it does not highlight the code inside a
;; fenced block as its language: the block is shown as code, verbatim.

;;; Code:

(require 'mega-lib)
(require 'outline)

(defface mega-markdown-code '((t :inherit font-lock-string-face))
  "Inline code and fenced code blocks." :group 'mega)
(defface mega-markdown-bold '((t :inherit bold))
  "Strongly emphasised text." :group 'mega)
(defface mega-markdown-italic '((t :inherit italic))
  "Emphasised text." :group 'mega)
(defface mega-markdown-link '((t :inherit link))
  "The text of a link." :group 'mega)
(defface mega-markdown-url '((t :inherit shadow))
  "The destination of a link." :group 'mega)
(defface mega-markdown-quote '((t :inherit font-lock-doc-face))
  "A block quote." :group 'mega)
(defface mega-markdown-marker '((t :inherit font-lock-builtin-face))
  "List markers and rules." :group 'mega)

(defconst mega-markdown-fence-regexp "^[ \t]*\\(?:```\\|~~~\\)"
  "Matches a line that opens or closes a fenced code block.")

(defun mega-markdown--in-fence-p (position)
  "Non-nil if POSITION is inside a fenced code block."
  (save-excursion
    (save-match-data
      (goto-char (point-min))
      (let ((inside nil))
        (while (re-search-forward mega-markdown-fence-regexp position t)
          (setq inside (not inside))
          (forward-line 1))
        inside))))

(defun mega-markdown--match-fenced-block (limit)
  "Font-lock matcher: a whole fenced code block before LIMIT."
  (when (re-search-forward mega-markdown-fence-regexp limit t)
    (let ((start (match-beginning 0)))
      (forward-line 1)
      (if (re-search-forward mega-markdown-fence-regexp nil t)
          (end-of-line)
        (goto-char (point-max)))
      (set-match-data (list start (point)))
      t)))

(defun mega-markdown--extend-region ()
  "Make a region being highlighted cover any code block it cuts through."
  (defvar font-lock-beg)
  (defvar font-lock-end)
  (let ((changed nil))
    (when (mega-markdown--in-fence-p font-lock-beg)
      (save-excursion
        (goto-char font-lock-beg)
        (when (re-search-backward mega-markdown-fence-regexp nil t)
          (setq font-lock-beg (point) changed t))))
    (when (mega-markdown--in-fence-p font-lock-end)
      (save-excursion
        (goto-char font-lock-end)
        (setq font-lock-end
              (if (re-search-forward mega-markdown-fence-regexp nil t)
                  (line-end-position)
                (point-max))
              changed t)))
    changed))

(defun mega-markdown--heading-face (level)
  "The face for a heading of LEVEL."
  (intern (format "outline-%d" (min level 8))))

(defconst mega-markdown-font-lock-keywords
  `((mega-markdown--match-fenced-block 0 'mega-markdown-code t)
    ("^\\(#\\{1,6\\}\\)[ \t]+.*$"
     0 (mega-markdown--heading-face (- (match-end 1) (match-beginning 1))))
    ("^[^\n]+\n\\(=+\\)[ \t]*$" 0 'outline-1)
    ("^[ \t]*>.*$" 0 'mega-markdown-quote)
    ("^[ \t]*\\([-*+]\\|[0-9]+[.)]\\)[ \t]" 1 'mega-markdown-marker)
    ("^[ \t]*\\(?:[-*_][ \t]*\\)\\{3,\\}$" 0 'mega-markdown-marker)
    ("`[^`\n]+`" 0 'mega-markdown-code)
    ("\\(\\*\\*\\|__\\)[^ \t\n*_][^\n]*?\\1" 0 'mega-markdown-bold)
    ("\\(?:^\\|[^*[:alnum:]]\\)\\(\\*[^ \t\n*][^*\n]*\\*\\)" 1 'mega-markdown-italic)
    ("\\(?:^\\|[^_[:alnum:]]\\)\\(_[^ \t\n_][^_\n]*_\\)\\(?:[^_[:alnum:]]\\|$\\)"
     1 'mega-markdown-italic)
    ("!?\\[\\([^]\n]+\\)\\](\\([^)\n]+\\))"
     (1 'mega-markdown-link) (2 'mega-markdown-url))
    ("<https?://[^>\n]+>" 0 'mega-markdown-link))
  "Highlighting for `mega-markdown-mode'.")

(defun mega-markdown-outline-level ()
  "The level of the heading at point: the number of # characters."
  (- (match-end 0) (match-beginning 0) 1))

(defun mega-markdown--imenu ()
  "Return the headings of the buffer, indented by level, for the index."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\(#\\{1,6\\}\\)[ \t]+\\(.*?\\)[ \t#]*$" nil t)
        (unless (mega-markdown--in-fence-p (match-beginning 0))
          (push (cons (concat (make-string (* 2 (1- (length (match-string 1)))) ?\s)
                              (match-string-no-properties 2))
                      (match-beginning 0))
                index))))
    (nreverse index)))

(defvar mega-markdown-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'mega-markdown-tab)
    (define-key map (kbd "<backtab>") #'outline-cycle-buffer)
    (define-key map (kbd "C-c C-n") #'outline-next-visible-heading)
    (define-key map (kbd "C-c C-p") #'outline-previous-visible-heading)
    map)
  "Keys of `mega-markdown-mode'.")

(defun mega-markdown-tab ()
  "Fold or unfold on a heading; indent anywhere else."
  (interactive)
  (if (save-excursion (beginning-of-line) (looking-at-p "#\\{1,6\\}[ \t]"))
      (outline-cycle)
    (indent-for-tab-command)))

;;;###autoload
(define-derived-mode mega-markdown-mode text-mode "Markdown"
  "A small mode for Markdown."
  (setq-local font-lock-defaults '(mega-markdown-font-lock-keywords t)
              font-lock-multiline t
              comment-start "<!-- "
              comment-end " -->"
              comment-start-skip "<!--[ \t]*"
              outline-regexp "#\\{1,6\\} "
              outline-level #'mega-markdown-outline-level
              imenu-create-index-function #'mega-markdown--imenu
              ;; A list item or a quote is not a paragraph to refill into the
              ;; line above it.
              paragraph-start "\f\\|[ \t]*$\\|[ \t]*[-*+>][ \t]\\|[ \t]*[0-9]+[.)][ \t]\\|#\\|```\\|~~~"
              paragraph-separate "[ \t\f]*$\\|#\\|```\\|~~~"
              adaptive-fill-regexp "[ \t]*\\(?:[-*+>][ \t]+\\|[0-9]+[.)][ \t]+\\)?")
  (add-hook 'font-lock-extend-region-functions
            #'mega-markdown--extend-region nil t)
  (outline-minor-mode 1))

(provide 'mega-mode-markdown)
;;; mega-mode-markdown.el ends here
