;;; mega-snippet.el --- Templates with places to fill in  -*- lexical-binding: t; -*-

;;; Commentary:

;; A snippet is a piece of text with numbered places to fill in:
;;
;;     for ${1:item} in ${2:items} {
;;         $0
;;     }
;;
;; Expanding it inserts the text and selects the first place; typing replaces
;; what is selected, TAB goes to the next place and S-TAB to the previous
;; one.  After the last place the cursor lands on $0 and the snippet is done.
;; `C-g', or moving out of the snippet, ends it early.
;;
;; The syntax is the one language servers use, so this is also what expands a
;; completion the server sends as a snippet (a function call with its
;; arguments as places, say).  MEGA's own snippets are in `mega-snippets';
;; their names are offered by the completion menu, and `C-c s' lists them.
;;
;; Understood: $1, ${1}, ${1:default}, ${1|a,b|} (the first choice is
;; used), $0, variables as ${NAME:default}, and backslash escapes.  A number
;; that appears twice is a place once; the repeats are plain text.
;;
;; eglot looks for a snippet expander through a function of its own that is
;; not public API.  MEGA replaces that one function; the doctor reports if it
;; ever disappears.

;;; Code:

(require 'mega-lib)
(require 'cl-lib)

(defvar mega-snippets
  '(((prog-mode)
     ("todo" . "TODO: $0")
     ("fixme" . "FIXME: $0"))
    ((rust-ts-mode mega-rust-mode)
     ("fn" . "fn ${1:name}(${2}) ${3:-> ${4:()} }{\n    $0\n}")
     ("test" . "#[test]\nfn ${1:name}() {\n    $0\n}")
     ("impl" . "impl ${1:Type} {\n    $0\n}")
     ("match" . "match ${1:value} {\n    ${2:pattern} => $0,\n}")
     ("for" . "for ${1:item} in ${2:items} {\n    $0\n}"))
    ((python-mode python-ts-mode)
     ("def" . "def ${1:name}(${2}):\n    $0")
     ("class" . "class ${1:Name}:\n    def __init__(self${2}):\n        $0")
     ("main" . "if __name__ == \"__main__\":\n    $0"))
    ((c-mode c-ts-mode c++-mode c++-ts-mode)
     ("for" . "for (${1:int i = 0}; ${2:i < n}; ${3:i++}) {\n    $0\n}")
     ("main" . "int main(int argc, char **argv)\n{\n    $0\n    return 0;\n}"))
    ((sh-mode bash-ts-mode)
     ("if" . "if ${1:condition}; then\n    $0\nfi")
     ("for" . "for ${1:item} in ${2:items}; do\n    $0\ndone")))
  "MEGA's snippets: each element is (MODES (NAME . TEMPLATE)...).
A snippet is available in buffers whose mode derives from one of MODES.")

;;;; Reading a template

(defun mega-snippet--closing-brace (template start)
  "Return the index of the } that closes the { before START in TEMPLATE."
  (let ((depth 1) (index start) (length (length template)))
    (while (and (< index length) (> depth 0))
      (pcase (aref template index)
        (?\\ (setq index (1+ index)))
        (?{ (setq depth (1+ depth)))
        (?} (setq depth (1- depth))))
      (setq index (1+ index)))
    (and (zerop depth) (1- index))))

(defun mega-snippet-parse (template)
  "Parse TEMPLATE into (TEXT . PLACES).
TEXT is what gets inserted.  PLACES is a list of (NUMBER START END),
positions within TEXT, one per numbered place, in order of appearance;
a number that repeats is listed for its first appearance only."
  (let ((index 0) (length (length template)) (text "") (places nil))
    (cl-flet ((place (number string)
                (unless (assq number places)
                  (push (list number (length text) (+ (length text) (length string)))
                        places))
                (setq text (concat text string))))
      (while (< index length)
        (let ((char (aref template index)))
          (cond
           ((and (eq char ?\\) (< (1+ index) length))
            (setq text (concat text (string (aref template (1+ index))))
                  index (+ index 2)))
           ((and (eq char ?$) (string-match "\\`[0-9]+" (substring template (1+ index))))
            (let ((digits (match-string 0 (substring template (1+ index)))))
              (place (string-to-number digits) "")
              (setq index (+ index 1 (length digits)))))
           ((and (eq char ?$) (< (1+ index) length) (eq (aref template (1+ index)) ?{))
            (let* ((close (mega-snippet--closing-brace template (+ index 2)))
                   (body (and close (substring template (+ index 2) close))))
              (cond
               ((null body)
                (setq text (concat text "$") index (1+ index)))
               ((string-match "\\`\\([0-9]+\\)\\(?::\\(\\(?:.\\|\n\\)*\\)\\||\\([^|]*\\)|\\)?\\'" body)
                (let* ((number (string-to-number (match-string 1 body)))
                       (default (match-string 2 body))
                       (choices (match-string 3 body))
                       ;; A default may itself contain places.
                       (inner (and default (mega-snippet-parse default)))
                       (string (cond (inner (car inner))
                                     (choices (car (split-string choices ",")))
                                     (t "")))
                       (base (length text)))
                  (place number string)
                  (dolist (nested (reverse (cdr inner)))
                    (unless (assq (car nested) places)
                      (push (list (car nested) (+ base (nth 1 nested)) (+ base (nth 2 nested)))
                            places)))
                  (setq index (1+ close))))
               (t
                ;; A variable: its default, or nothing.
                (when (string-match "\\`[[:alpha:]_]+:\\(\\(?:.\\|\n\\)*\\)\\'" body)
                  (setq text (concat text (car (mega-snippet-parse (match-string 1 body))))))
                (setq index (1+ close))))))
           ((and (eq char ?$) (string-match "\\`[[:alpha:]_]+" (substring template (1+ index))))
            ;; A bare variable expands to nothing.
            (setq index (+ index 1 (length (match-string 0 (substring template (1+ index)))))))
           (t (setq text (concat text (string char))
                    index (1+ index)))))))
    (cons text (nreverse places))))

;;;; A snippet being filled in

(defvar-local mega-snippet--active nil
  "Non-nil while a snippet is being filled in in this buffer.")
(defvar-local mega-snippet--places nil
  "The places still to visit, in order: a list of (START . END) markers.")
(defvar-local mega-snippet--bounds nil
  "Markers (START . END) around the whole snippet.")
(defvar-local mega-snippet--visited nil
  "The places already visited, most recent first.")

(defun mega-snippet--order (places)
  "PLACES sorted for visiting: by number, with 0 last."
  (sort (copy-sequence places)
        (lambda (a b)
          (cond ((zerop (car a)) nil)
                ((zerop (car b)) t)
                (t (< (car a) (car b)))))))

(defun mega-snippet-finish ()
  "Stop filling in the snippet."
  (interactive)
  (dolist (place (append mega-snippet--places mega-snippet--visited))
    (set-marker (car place) nil)
    (set-marker (cdr place) nil))
  (when mega-snippet--bounds
    (set-marker (car mega-snippet--bounds) nil)
    (set-marker (cdr mega-snippet--bounds) nil))
  (setq mega-snippet--active nil
        mega-snippet--places nil
        mega-snippet--visited nil
        mega-snippet--bounds nil)
  (remove-hook 'post-command-hook #'mega-snippet--watch t)
  (deactivate-mark))

(defun mega-snippet--go (place)
  "Put the cursor on PLACE, selecting its text so that typing replaces it."
  (goto-char (cdr place))
  (if (= (car place) (cdr place))
      (deactivate-mark)
    (set-mark (car place))
    (activate-mark)))

(defun mega-snippet-next ()
  "Go to the next place of the snippet; after the last one, finish."
  (interactive)
  (let ((place (pop mega-snippet--places)))
    (cond ((null place) (mega-snippet-finish))
          ((null mega-snippet--places)
           ;; The last place is where the cursor is left.
           (goto-char (car place))
           (push place mega-snippet--visited)
           (mega-snippet-finish))
          (t (push place mega-snippet--visited)
             (mega-snippet--go place)))))

(defun mega-snippet-previous ()
  "Go back to the previous place of the snippet."
  (interactive)
  (when (cdr mega-snippet--visited)
    (push (pop mega-snippet--visited) mega-snippet--places)
    (mega-snippet--go (car mega-snippet--visited))))

(defun mega-snippet--watch ()
  "End the snippet when the cursor has left it."
  (when (and mega-snippet--active mega-snippet--bounds
             (or (< (point) (car mega-snippet--bounds))
                 (> (point) (cdr mega-snippet--bounds))))
    (mega-snippet-finish)))

(defvar mega-snippet-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'mega-snippet-next)
    (define-key map (kbd "<tab>") #'mega-snippet-next)
    (define-key map (kbd "<backtab>") #'mega-snippet-previous)
    (define-key map (kbd "S-TAB") #'mega-snippet-previous)
    (define-key map (kbd "C-g") #'mega-snippet-finish)
    map)
  "Keys in force while a snippet is being filled in.")

(defvar mega-snippet--emulation-alist
  `((mega-snippet--active . ,mega-snippet-map))
  "Puts `mega-snippet-map' above ordinary keymaps while a snippet is active.")

;; At the end of the list: the completion menu, when open, keeps TAB.
(add-to-list 'emulation-mode-map-alists 'mega-snippet--emulation-alist t)

;;;###autoload
(defun mega-snippet-expand (template)
  "Insert the snippet TEMPLATE at point and start filling it in.
Lines after the first are indented like the line it is inserted on."
  (when mega-snippet--active
    (mega-snippet-finish))
  (let* ((parsed (mega-snippet-parse template))
         (indentation (make-string (current-indentation) ?\s))
         (start (point))
         (text (car parsed))
         (places (cdr parsed))
         ;; Each newline in TEXT gains INDENTATION, which shifts what follows.
         (shift (lambda (position)
                  (let ((count 0) (from 0))
                    (while (and (string-match "\n" text from)
                                (< (match-beginning 0) position))
                      (setq count (1+ count) from (match-end 0)))
                    (+ start position (* count (length indentation)))))))
    (insert (replace-regexp-in-string "\n" (concat "\n" indentation) text t t))
    (let ((end (point)))
      (if (null places)
          (goto-char end)
        (setq mega-snippet--bounds (cons (copy-marker start) (copy-marker end t))
              mega-snippet--places
              (mapcar (lambda (place)
                        (cons (copy-marker (funcall shift (nth 1 place)))
                              (copy-marker (funcall shift (nth 2 place)) t)))
                      (mega-snippet--order
                       ;; Without a $0, the end of the snippet is the last stop.
                       (if (assq 0 places)
                           places
                         (append places (list (list 0 (length text) (length text)))))))
              mega-snippet--visited nil
              mega-snippet--active t)
        (add-hook 'post-command-hook #'mega-snippet--watch nil t)
        (mega-snippet-next)))))

;;;; MEGA's own snippets

(defun mega-snippet-available ()
  "The snippets available in this buffer: an alist of (NAME . TEMPLATE)."
  (let (found)
    (dolist (entry mega-snippets)
      (when (apply #'derived-mode-p (car entry))
        (setq found (append found (cdr entry)))))
    found))

(defun mega-snippet-capf ()
  "Offer the names of MEGA's snippets as completions of the word at point."
  (when-let* ((snippets (mega-snippet-available))
              (bounds (bounds-of-thing-at-point 'symbol))
              ((= (cdr bounds) (point)))
              (prefix (buffer-substring-no-properties (car bounds) (cdr bounds)))
              ((seq-some (lambda (snippet) (string-prefix-p prefix (car snippet)))
                         snippets)))
    (list (car bounds) (cdr bounds) (mapcar #'car snippets)
          :exclusive 'no
          :annotation-function (lambda (_) " snippet")
          :exit-function
          (lambda (name status)
            (when (eq status 'finished)
              (when-let* ((template (cdr (assoc name snippets))))
                (delete-region (- (point) (length name)) (point))
                (mega-snippet-expand template)))))))

;; After the mode's own completion, before words from other buffers.
(add-hook 'completion-at-point-functions #'mega-snippet-capf 80)

;;;###autoload
(defun mega-snippet-insert (name)
  "Insert the snippet called NAME, chosen from those of this buffer's mode."
  (interactive
   (let ((snippets (mega-snippet-available)))
     (unless snippets
       (user-error "MEGA has no snippets for %s" major-mode))
     (list (completing-read "Snippet: " (mapcar #'car snippets) nil t))))
  (let ((template (cdr (assoc name (mega-snippet-available)))))
    (unless template
      (user-error "No snippet called %s here" name))
    (mega-snippet-expand template)))

;;;; Snippets from the language server

(defun mega-snippet--expander-for-eglot ()
  "What eglot should expand a snippet with: `mega-snippet-expand'."
  #'mega-snippet-expand)

(with-eval-after-load 'eglot
  (when (fboundp 'eglot--snippet-expansion-fn)
    (advice-add 'eglot--snippet-expansion-fn :override
                #'mega-snippet--expander-for-eglot)))

(provide 'mega-snippet)
;;; mega-snippet.el ends here
