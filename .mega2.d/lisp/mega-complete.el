;;; mega-complete.el --- A completion menu where you are typing  -*- lexical-binding: t; -*-

;;; Commentary:

;; While you type in a buffer, a small menu offers ways to finish the word.
;; The candidates are whatever the buffer's completion functions provide: the
;; language server when one is running, the language mode otherwise, and
;; words from open buffers as a last resort.
;;
;;   C-n / C-p or the arrows   choose
;;   TAB                       take the chosen candidate, or the first one
;;   RET                       take the chosen candidate; with none chosen it
;;                             is an ordinary RET
;;   C-g                       close the menu
;;
;; Nothing is chosen when the menu appears, so typing on, or pressing RET at
;; the end of a line, never inserts something you did not ask for.
;; `M-TAB' (or TAB on an already indented line) opens the menu on request,
;; with the first candidate chosen.
;;
;; The menu never blocks typing: candidates are computed after a short pause,
;; and the computation is abandoned the moment you press another key.
;;
;; The state — what is offered, what is chosen — is kept apart from the
;; drawing, which is `mega-popup-show'.  Where popups cannot be drawn, MEGA
;; turns on Emacs's own inline preview instead and leaves TAB alone.

;;; Code:

(require 'mega-lib)
(require 'mega-popup)

(autoload 'dabbrev-capf "dabbrev")

(defcustom mega-complete-delay 0.15
  "Seconds to pause after a keystroke before the menu appears."
  :type 'number :group 'mega)

(defcustom mega-complete-min-prefix 2
  "Fewest characters to type before the menu appears on its own."
  :type 'integer :group 'mega)

(defcustom mega-complete-max-lines 10
  "Most candidates the menu shows at once."
  :type 'integer :group 'mega)

(defcustom mega-complete-max-candidates 200
  "Most candidates the menu keeps; a longer list is cut."
  :type 'integer :group 'mega)

(defface mega-complete-annotation '((t :inherit completions-annotations))
  "What a candidate is, shown beside it." :group 'mega)

;;;; State

(defvar mega-complete--active nil
  "Non-nil while the menu is open.  Also what turns its keys on.")
(defvar mega-complete--buffer nil "The buffer the menu belongs to.")
(defvar mega-complete--start nil "Marker: start of the text being completed.")
(defvar mega-complete--candidates nil "The candidates on offer.")
(defvar mega-complete--index -1 "The chosen candidate, or -1 for none.")
(defvar mega-complete--properties nil "The completion properties in force.")
(defvar mega-complete--source nil
  "How to recompute the candidates: (TABLE . PREDICATE), or nil.")
(defvar mega-complete--timer nil "The timer that opens the menu after a pause.")

;;;; The model: no display below this line until "Drawing"

(defun mega-complete-move (index count delta)
  "Return the index DELTA steps from INDEX among COUNT candidates.
INDEX -1 means nothing is chosen: stepping forward from there chooses
the first, stepping back the last.  The choice wraps around."
  (cond ((<= count 0) -1)
        ((and (< index 0) (> delta 0)) (min (1- count) (1- delta)))
        ((< index 0) (max 0 (+ count delta)))
        (t (mod (+ index delta) count))))

(defun mega-complete--annotation (candidate)
  "The annotation of CANDIDATE under the current properties, or nil."
  (when-let* ((function (plist-get mega-complete--properties :annotation-function))
              (text (ignore-errors (funcall function candidate))))
    (and (stringp text) (not (string-blank-p text)) (string-trim text))))

(defun mega-complete-lines (candidates)
  "Return the menu lines for CANDIDATES: each name, then what it is."
  (let ((width (apply #'max 1 (mapcar #'string-width candidates))))
    (mapcar (lambda (candidate)
              (let ((annotation (mega-complete--annotation candidate)))
                (concat " "
                        candidate
                        (if annotation
                            (concat (make-string (- (1+ width) (string-width candidate)) ?\s)
                                    (propertize annotation 'face 'mega-complete-annotation))
                          "")
                        " ")))
            candidates)))

(defun mega-complete-candidates (start end table predicate)
  "Return the completions of the text from START to END in TABLE.
PREDICATE filters them.  The result is a cons (BASE . CANDIDATES): the
candidates replace the text from START plus BASE to END.  It is nil when
there are none, or when the computation was interrupted by a keystroke."
  (let* ((input (buffer-substring-no-properties start end))
         (metadata (completion-metadata input table predicate))
         (all (while-no-input
                (completion-all-completions input table predicate
                                            (length input) metadata))))
    (when (consp all)
      (let ((base (or (cdr (last all)) 0))
            (sort (completion-metadata-get metadata 'display-sort-function)))
        (setcdr (last all) nil)
        (setq all (delete-dups all))
        (setq all (if sort
                      (funcall sort all)
                    (sort all (lambda (a b)
                                (or (< (length a) (length b))
                                    (and (= (length a) (length b)) (string< a b)))))))
        (cons base (take mega-complete-max-candidates all))))))

(defun mega-complete--capf ()
  "Ask the buffer's completion functions about point.
Returns (START END TABLE . PROPERTIES) from the first that answers."
  (run-hook-wrapped
   'completion-at-point-functions
   (lambda (function)
     (let ((result (ignore-errors (funcall function))))
       (and (consp result)
            (integer-or-marker-p (car result))
            (integer-or-marker-p (cadr result))
            result)))))

;;;; Drawing

(defun mega-complete--draw ()
  "Show the menu as the state describes it."
  (mega-popup-show 'complete
                   (mega-complete-lines mega-complete--candidates)
                   (and (>= mega-complete--index 0) mega-complete--index)
                   (marker-position mega-complete--start)
                   60 mega-complete-max-lines))

(defun mega-complete-close ()
  "Close the menu."
  (interactive)
  (when mega-complete--timer
    (cancel-timer mega-complete--timer)
    (setq mega-complete--timer nil))
  (when mega-complete--active
    (setq mega-complete--active nil
          mega-complete--candidates nil
          mega-complete--index -1
          mega-complete--source nil)
    (when (markerp mega-complete--start)
      (set-marker mega-complete--start nil))
    (mega-popup-hide 'complete)))

(defun mega-complete--open (start base+candidates properties source index)
  "Open the menu on the text from START to point.
BASE+CANDIDATES is what `mega-complete-candidates' returned, PROPERTIES
the completion properties, SOURCE how to recompute, INDEX the candidate
chosen at first."
  (mega-complete-close)
  (setq mega-complete--active t
        mega-complete--buffer (current-buffer)
        mega-complete--start (copy-marker (+ start (car base+candidates)))
        mega-complete--candidates (cdr base+candidates)
        mega-complete--index index
        mega-complete--properties properties
        mega-complete--source source)
  (mega-complete--draw))

;;;; The keys of the open menu

(defun mega-complete-next ()
  "Choose the next candidate."
  (interactive)
  (setq mega-complete--index
        (mega-complete-move mega-complete--index
                            (length mega-complete--candidates) 1))
  (mega-complete--draw))

(defun mega-complete-previous ()
  "Choose the previous candidate."
  (interactive)
  (setq mega-complete--index
        (mega-complete-move mega-complete--index
                            (length mega-complete--candidates) -1))
  (mega-complete--draw))

(defun mega-complete--insert (candidate)
  "Replace the text being completed with CANDIDATE and close the menu."
  (let ((start (marker-position mega-complete--start))
        (exit (plist-get mega-complete--properties :exit-function)))
    (mega-complete-close)
    (delete-region start (point))
    (insert (substring-no-properties candidate))
    ;; The language server finishes its part here: imports, snippets.  It
    ;; finds what it needs on the candidate itself, properties and all.
    (when exit
      (funcall exit candidate 'finished))))

(defun mega-complete-accept ()
  "Take the chosen candidate, or the first one if none is chosen."
  (interactive)
  (when-let* ((candidate (nth (max 0 mega-complete--index) mega-complete--candidates)))
    (mega-complete--insert candidate)))

(defun mega-complete-return ()
  "Take the chosen candidate; with none chosen, do what RET normally does."
  (interactive)
  (if (>= mega-complete--index 0)
      (mega-complete-accept)
    (mega-complete-close)
    (when-let* ((command (key-binding (kbd "RET"))))
      (setq this-command command)
      (call-interactively command))))

(defvar mega-complete-menu-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-n") #'mega-complete-next)
    (define-key map (kbd "<down>") #'mega-complete-next)
    (define-key map (kbd "C-p") #'mega-complete-previous)
    (define-key map (kbd "<up>") #'mega-complete-previous)
    (define-key map (kbd "TAB") #'mega-complete-accept)
    (define-key map (kbd "<tab>") #'mega-complete-accept)
    (define-key map (kbd "RET") #'mega-complete-return)
    (define-key map (kbd "<return>") #'mega-complete-return)
    (define-key map (kbd "C-g") #'mega-complete-close)
    map)
  "Keys in force while the menu is open.")

(defvar mega-complete--emulation-alist
  `((mega-complete--active . ,mega-complete-menu-map))
  "Puts `mega-complete-menu-map' above every other keymap while the menu is open.")

;;;; Keeping the menu in step with the buffer

(defconst mega-complete--typing-commands
  '(self-insert-command delete-backward-char backward-delete-char-untabify)
  "Commands after which an open menu is recomputed, not closed.")

(defun mega-complete--refresh ()
  "Recompute the open menu for the text as it is now, or close it."
  (let* ((start (marker-position mega-complete--start))
         (source mega-complete--source)
         (found (and source (> (point) start)
                     (mega-complete-candidates start (point) (car source) (cdr source)))))
    (if (and found (cdr found))
        (progn
          (setq mega-complete--candidates (cdr found)
                mega-complete--index -1)
          (mega-complete--draw))
      (mega-complete-close))))

(defun mega-complete--auto ()
  "Open the menu for the word before point, if there is something to offer."
  (setq mega-complete--timer nil)
  (unless (or mega-complete--active (minibufferp) buffer-read-only
              (not (mega-popup-available-p)))
    (pcase (mega-complete--capf)
      (`(,start ,end ,table . ,properties)
       (when (and (= end (point))
                  (>= (- end start) mega-complete-min-prefix))
         (let* ((predicate (plist-get properties :predicate))
                (found (mega-complete-candidates start end table predicate)))
           ;; A single candidate that is already typed in full is no help.
           (when (and found (cdr found)
                      (not (equal (cdr found)
                                  (list (buffer-substring-no-properties start end)))))
             (mega-complete--open start found properties
                                  (cons table predicate) -1))))))))

(defun mega-complete--post-command ()
  "Keep the menu in step with what the last command did."
  (cond
   (mega-complete--active
    (cond ((memq this-command '(mega-complete-next mega-complete-previous)))
          ((and (eq (current-buffer) mega-complete--buffer)
                (memq this-command mega-complete--typing-commands)
                (>= (point) (marker-position mega-complete--start)))
           (mega-complete--refresh))
          (t (mega-complete-close))))
   ((and (eq this-command 'self-insert-command)
         (not (minibufferp))
         (not buffer-read-only))
    (when mega-complete--timer
      (cancel-timer mega-complete--timer))
    (let ((buffer (current-buffer)) (point (point)))
      (setq mega-complete--timer
            (run-with-idle-timer
             mega-complete-delay nil
             (lambda ()
               (when (and (eq (current-buffer) buffer) (= (point) point))
                 (mega-complete--auto)))))))))

;;;; Completion on request

(defun mega-complete-in-region (start end collection &optional predicate)
  "Complete the text from START to END in COLLECTION through the menu.
PREDICATE filters the candidates.  This is MEGA's
`completion-in-region-function': it is what `M-TAB' and a completing
TAB run."
  (let ((found (mega-complete-candidates start end collection predicate))
        (properties completion-extra-properties))
    (cond ((not (and found (cdr found)))
           (message "No completion")
           nil)
          ((null (cddr found))
           ;; One candidate: take it, no menu needed.
           (setq mega-complete--start (copy-marker (+ start (car found)))
                 mega-complete--properties properties)
           (mega-complete--insert (cadr found))
           t)
          (t
           (mega-complete--open start found properties
                                (cons collection predicate) 0)
           t))))

;;;; The mode

(defvar mega-complete--previous-in-region nil
  "The `completion-in-region-function' in force before the mode was enabled.")

;;;###autoload
(define-minor-mode mega-complete-mode
  "Offer completions in a menu at point while typing."
  :global t
  :group 'mega
  (if mega-complete-mode
      (progn
        (setq mega-complete--previous-in-region completion-in-region-function
              completion-in-region-function #'mega-complete-in-region)
        (add-to-list 'emulation-mode-map-alists 'mega-complete--emulation-alist)
        (add-hook 'post-command-hook #'mega-complete--post-command))
    (mega-complete-close)
    (setq completion-in-region-function
          (or mega-complete--previous-in-region #'completion--in-region))
    (setq emulation-mode-map-alists
          (delq 'mega-complete--emulation-alist emulation-mode-map-alists))
    (remove-hook 'post-command-hook #'mega-complete--post-command)))

;; TAB indents first and completes on a line that is already indented.
(setq tab-always-indent 'complete)

;; Words from open buffers, after everything more specific has had its say.
(add-hook 'completion-at-point-functions #'dabbrev-capf 90)

(if (mega-popup-available-p)
    (mega-complete-mode 1)
  ;; No way to draw a menu here: fall back on Emacs's own inline preview.
  (unless noninteractive
    (global-completion-preview-mode 1)))

(provide 'mega-complete)
;;; mega-complete.el ends here
