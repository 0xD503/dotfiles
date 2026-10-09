;;; mega-pick.el --- A prompt whose choices come from a program  -*- lexical-binding: t; -*-

;;; Commentary:

;; Ordinary prompts choose from a list that exists up front.  Searching a
;; project is different: the choices are whatever a program prints for what
;; you have typed so far.  `mega-pick-read' is that prompt.
;;
;; It adds as little as possible to Emacs.  The prompt is `completing-read',
;; so it looks and behaves like every other prompt, with the same vertical
;; list and keys.  The two additions are:
;;
;; * a completion table that calls your function with the current input, and
;;   remembers the answer so that moving through the list does not ask again;
;;
;; * a completion style, `mega-pick-all', that shows what the table returns
;;   as it is.  Emacs normally filters candidates against the input itself,
;;   which would throw away a search hit that does not contain the pattern
;;   literally.
;;
;; The function runs while the minibuffer list is being computed, which Emacs
;; abandons when you type again.  If it runs a program through `mega-exec-run'
;; the program dies with it: typing is never blocked by a slow search.

;;; Code:

(require 'mega-lib)

(defvar completion-all-sorted-completions)

;;;; The pass-through completion style

(defun mega-pick--try (string table predicate _point)
  "Completion style function: STRING is as complete as it gets.
TABLE and PREDICATE only decide whether there is anything to offer."
  (and (all-completions string table predicate) string))

(defun mega-pick--all (string table predicate _point)
  "Completion style function: everything TABLE offers for STRING, unfiltered.
PREDICATE is honoured.  STRING is handed to the table as the query; it
is not used to filter what comes back."
  (all-completions string table predicate))

(add-to-list 'completion-styles-alist
             '(mega-pick-all mega-pick--try mega-pick--all
               "Offer exactly what the completion table returns."))

;;;; The table

(defvar mega-pick--refresh nil
  "Function that makes the active pick prompt ask its source again.
Bound while `mega-pick-read' is reading.")

(defun mega-pick-table (source category)
  "Return (TABLE . FORGET) for candidates computed by SOURCE.
TABLE is a completion table: asked about an input, it calls SOURCE with
that input, which returns a list of strings.  CATEGORY is the completion
category it reports.  FORGET is a function that drops the remembered
answer, so that the next request asks SOURCE again."
  (let ((known-input 'none)
        (known nil))
    (cons
     (lambda (input predicate action)
       (cond
        ((eq action 'metadata)
         `(metadata (category . ,category)
                    ;; The source's order is the order: a search prints hits
                    ;; file by file, and re-sorting would scatter them.
                    (display-sort-function . identity)
                    (cycle-sort-function . identity)))
        ((eq (car-safe action) 'boundaries) nil)
        ;; "Is this a valid choice?"  Emacs asks that about the candidate
        ;; being accepted.  It is answered from what is already known:
        ;; asking SOURCE would run a search for a search hit.
        ((and (not (eq action t)) (member input known))
         t)
        (t
         (unless (equal input known-input)
           ;; Assigned only after SOURCE returns: if it is interrupted, the
           ;; next request starts over, never offering a partial answer.
           (setq known (funcall source input)
                 known-input input))
         (let ((candidates (if predicate (seq-filter predicate known) known)))
           (cond ((eq action t) candidates)
                 ((eq action 'lambda) (and (member input candidates) t))
                 (t (and candidates input)))))))
     (lambda () (setq known-input 'none)))))

(defun mega-pick-refresh ()
  "Ask the source of the active pick prompt again, for the same input.
For a command that changes how the source searches, such as a case toggle."
  (when mega-pick--refresh
    (funcall mega-pick--refresh)
    ;; Emacs keeps its own copy of the list, per minibuffer, until the text
    ;; changes.
    (setq-local completion-all-sorted-completions nil)))

;;;; The prompt

(defun mega-pick-read (prompt source &rest options)
  "Read a choice from the candidates SOURCE returns for the input so far.
PROMPT is the prompt string.  SOURCE is called with the current input
and returns a list of strings; it may be slow, and may be abandoned.

OPTIONS is a plist: :category (a symbol, default `mega-pick'), :initial
(text to start with), :history (a history variable), and :keymap (extra
keys for the prompt, consulted before the usual ones).

Returns the chosen string, or the typed input if nothing matched."
  (let* ((category (or (plist-get options :category) 'mega-pick))
         (table+forget (mega-pick-table source category))
         (keymap (plist-get options :keymap))
         (mega-pick--refresh (cdr table+forget))
         ;; Whatever the user's styles are, this category is shown unfiltered.
         (completion-category-overrides
          (cons `(,category (styles mega-pick-all)) completion-category-overrides)))
    (minibuffer-with-setup-hook
        (lambda ()
          (when keymap
            (use-local-map (make-composed-keymap keymap (current-local-map)))))
      (completing-read prompt (car table+forget) nil nil
                       (plist-get options :initial)
                       (plist-get options :history)))))

(provide 'mega-pick)
;;; mega-pick.el ends here
