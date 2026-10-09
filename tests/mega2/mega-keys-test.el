;;; mega-keys-test.el --- Tests for mega-keys.el and the cheat sheet  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'ert-x)
(require 'compile)

(defun mega-keys-test--rows ()
  "Every (KEY COMMAND DESCRIPTION) row of `mega-keys'."
  (apply #'append (mapcar #'cdr mega-keys)))

(defun mega-keys-test--bound (map &optional prefix)
  "Every (KEY-DESCRIPTION . COMMAND) reachable in MAP, below PREFIX.
A prefix that is bound to a named keymap counts as one binding: what is
inside belongs to whoever owns that keymap."
  (let (found)
    (map-keymap
     (lambda (event binding)
       (let ((key (vconcat prefix (vector event))))
         (cond ((eq (car-safe binding) 'menu-item)
                (push (cons (key-description key) (nth 2 binding)) found))
               ((and (keymapp binding) (not (symbolp binding)))
                (setq found (append (mega-keys-test--bound binding key) found)))
               (t (push (cons (key-description key) binding) found)))))
     map)
    found))

(defun mega-keys-test--command (binding)
  "The command behind BINDING, looking through a where-it-applies filter."
  (if (eq (car-safe binding) 'menu-item) (nth 2 binding) binding))

(defun mega-keys-test--runnable-p (binding)
  "Non-nil if BINDING is a command or names a keymap."
  (or (commandp binding)
      (and (symbolp binding) (fboundp binding) (keymapp (symbol-function binding)))))

(ert-deftest mega-keys-the-mode-is-on ()
  (should mega-keys-mode)
  (should (eq (alist-get 'mega-keys-mode minor-mode-map-alist) mega-keys-mode-map)))

(ert-deftest mega-keys-every-row-is-well-formed ()
  (dolist (group mega-keys)
    (should (stringp (car group)))
    (should (cdr group)))
  (dolist (row (mega-keys-test--rows))
    (should (memq (length row) '(3 4)))
    (should (memq (nth 3 row) '(nil :code :text)))
    (should (or (null (car row)) (stringp (car row))))
    (should (symbolp (nth 1 row)))
    (should (stringp (nth 2 row)))
    (should-not (string-empty-p (nth 2 row)))))

(ert-deftest mega-keys-every-key-in-the-table-is-bound-to-its-command ()
  ;; Looked up in a code buffer, where every key applies: a key limited to
  ;; code is, by design, not there in other buffers.
  (with-temp-buffer
    (prog-mode)
    (dolist (row (mega-keys-test--rows))
      (when (car row)
        (should (eq (mega-keys-test--command
                     (lookup-key mega-keys-mode-map (kbd (car row))))
                    (nth 1 row)))))))

(ert-deftest mega-keys-a-limited-key-leaves-other-buffers-alone ()
  "M-n is the symbol jump in code and prose, and Emacs's own elsewhere."
  (with-temp-buffer
    (prog-mode)
    (should (eq (key-binding (kbd "M-n")) #'mega-symbol-next))
    (should (eq (key-binding (kbd "C-c C-c")) #'mega-comment-dwim)))
  (with-temp-buffer
    (text-mode)
    (should (eq (key-binding (kbd "M-n")) #'mega-symbol-next))
    ;; Commenting is for code; prose keeps whatever its mode has there.
    (should-not (eq (key-binding (kbd "C-c C-c")) #'mega-comment-dwim)))
  (with-temp-buffer
    (special-mode)
    (should-not (eq (key-binding (kbd "M-n")) #'mega-symbol-next)))
  (with-temp-buffer
    (compilation-mode)
    (should (eq (key-binding (kbd "M-n")) #'compilation-next-error)))
  ;; At a prompt M-n and M-p walk the history.
  (should (eq (lookup-key minibuffer-local-map (kbd "M-n")) #'next-history-element))
  (should (eq (ert-simulate-keys (kbd "C-o RET")
                (minibuffer-with-setup-hook
                    (lambda ()
                      (local-set-key (kbd "C-o")
                                     (lambda () (interactive)
                                       (insert (symbol-name (key-binding (kbd "M-n")))))))
                  (intern (read-string "x: "))))
              'next-history-element)))

(ert-deftest mega-keys-nothing-is-bound-that-the-table-does-not-list ()
  (let ((table (delq nil (mapcar (lambda (row)
                                   (and (car row)
                                        (cons (key-description (kbd (car row)))
                                              (nth 1 row))))
                                 (mega-keys-test--rows)))))
    (should (equal (sort (mega-keys-test--bound mega-keys-mode-map)
                         (lambda (a b) (string< (car a) (car b))))
                   (sort table (lambda (a b) (string< (car a) (car b))))))))

(ert-deftest mega-keys-no-key-is-listed-twice ()
  (let ((keys (delq nil (mapcar (lambda (row)
                                  (and (car row) (key-description (kbd (car row)))))
                                (mega-keys-test--rows)))))
    (should (equal keys (delete-dups (copy-sequence keys))))))

(ert-deftest mega-keys-every-command-exists ()
  (dolist (row (mega-keys-test--rows))
    (should (mega-keys-test--runnable-p (nth 1 row)))))

(ert-deftest mega-keys-the-find-keys-of-mega-1-keep-their-meaning ()
  (should (eq (lookup-key mega-keys-mode-map (kbd "M-g a")) #'mega-search-project))
  (should (eq (lookup-key mega-keys-mode-map (kbd "M-g s")) #'mega-search-symbol))
  (should (eq (lookup-key mega-keys-mode-map (kbd "C-c t")) #'mega-project-tree))
  ;; C-c p is the whole project map, as it was; f still finds a file.
  (should (eq (lookup-key mega-keys-mode-map (kbd "C-c p")) 'mega-project-map))
  (should (eq (key-binding (kbd "C-c p f")) #'project-find-file))
  (should (eq (key-binding (kbd "C-c p p")) #'project-switch-project)))

(ert-deftest mega-keys-the-keys-win-over-a-major-mode ()
  "They live in a minor-mode map, so no major mode can shadow them."
  (with-temp-buffer
    (text-mode)
    (local-set-key (kbd "M-{") #'ignore)
    (should (eq (key-binding (kbd "M-{")) #'shrink-window-horizontally))))

(ert-deftest mega-keys-turning-the-mode-off-restores-emacs ()
  (unwind-protect
      (progn
        (mega-keys-mode -1)
        (should (eq (key-binding (kbd "M-{")) #'backward-paragraph)))
    (mega-keys-mode 1))
  (should (eq (key-binding (kbd "M-{")) #'shrink-window-horizontally)))

(ert-deftest mega-keys-mega-1-keys-keep-their-meaning ()
  (should (eq (lookup-key mega-keys-mode-map (kbd "M-{")) #'shrink-window-horizontally))
  (should (eq (lookup-key mega-keys-mode-map (kbd "M-}")) #'enlarge-window-horizontally)))

;;;; The cheat sheet

(ert-deftest mega-keys-the-cheat-sheet-lists-every-row ()
  (save-window-excursion
    (mega-help)
    (let ((sheet (mega-test-buffer-string "*mega-help*")))
      (dolist (group mega-keys)
        (should (string-match-p (regexp-quote (car group)) sheet)))
      (dolist (row (mega-keys-test--rows))
        (should (string-match-p
                 (concat "^  "
                         (regexp-quote (or (car row) (format "M-x %s" (nth 1 row))))
                         " +" (regexp-quote (nth 2 row)) "$")
                 sheet))))))

(ert-deftest mega-keys-the-cheat-sheet-is-read-only-and-loads-nothing ()
  (let ((before (copy-sequence features)))
    (save-window-excursion
      (mega-help)
      (with-current-buffer "*mega-help*"
        (should buffer-read-only)
        (should (derived-mode-p 'special-mode))))
    ;; Showing the sheet may load the sheet itself, and nothing else of MEGA.
    (dolist (feature features)
      (unless (memq feature before)
        (should (memq feature '(mega-help)))))))

;;;; The user guide

(ert-deftest mega-keys-every-key-in-the-guide-really-does-something ()
  "README.md shows keys in table rows that start with a backquoted key."
  (let ((guide (expand-file-name "README.md" mega-dir))
        (count 0))
    (should (file-readable-p guide))
    (with-temp-buffer
      (insert-file-contents guide)
      (while (re-search-forward "^| `\\([^`]+\\)`" nil t)
        (let ((key (match-string 1)))
          (setq count (1+ count))
          (if (string-prefix-p "M-x " key)
              (should (commandp (intern (substring key 4))))
            (should (mega-keys-test--runnable-p (key-binding (kbd key))))))))
    (should (> count 5))))

(provide 'mega-keys-test)
;;; mega-keys-test.el ends here
