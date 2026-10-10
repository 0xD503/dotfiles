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

;;;; Keys of your own

(defmacro mega-keys-test--scratch (&rest body)
  "Run BODY on a copy of the table and of the keymap."
  (declare (indent 0))
  `(let ((mega-keys (copy-tree mega-keys))
         (mega-keys-mode-map (copy-keymap mega-keys-mode-map)))
     ,@body))

(ert-deftest mega-keys-a-row-of-your-own-is-bound-and-shown ()
  (mega-keys-test--scratch
    (mega-keys-add "Mine" '("C-c m" forward-word "Go on a word")
                   '(nil backward-word "Go back a word"))
    (should (eq (lookup-key mega-keys-mode-map (kbd "C-c m")) #'forward-word))
    (should (equal (car (last mega-keys))
                   '("Mine" ("C-c m" forward-word "Go on a word")
                     (nil backward-word "Go back a word"))))
    ;; An existing group grows; no second one of the same name appears.
    (mega-keys-add "Edit" '("C-c e" ignore "Do nothing" :code))
    (should (= 1 (seq-count (lambda (group) (equal (car group) "Edit")) mega-keys)))
    (should (member '("C-c e" ignore "Do nothing" :code) (cdr (assoc "Edit" mega-keys))))
    ;; Limited to code, as asked.
    (with-temp-buffer
      (fundamental-mode)
      (should-not (eq (key-binding (kbd "C-c e")) #'ignore)))
    (save-window-excursion
      (mega-help)
      (let ((sheet (mega-test-buffer-string "*mega-help*")))
        (should (string-match-p "^Mine$" sheet))
        (should (string-match-p "^  C-c m +Go on a word$" sheet))
        (should (string-match-p "^  M-x backward-word +Go back a word$" sheet))))))

(ert-deftest mega-keys-taking-over-a-key-leaves-one-row-for-it ()
  "The cheat sheet must not go on describing what a key used to do."
  (mega-keys-test--scratch
    (should (eq (lookup-key mega-keys-mode-map (kbd "C-c d")) #'mega-doc-buffer))
    (mega-keys-add "Mine" '("C-c d" forward-word "Mine now"))
    (should (eq (lookup-key mega-keys-mode-map (kbd "C-c d")) #'forward-word))
    (should (equal (seq-filter (lambda (row) (equal (car row) "C-c d"))
                               (mega-keys-test--rows))
                   '(("C-c d" forward-word "Mine now"))))))

(ert-deftest mega-keys-a-removed-key-is-emacs-s-again ()
  (mega-keys-test--scratch
    (should (lookup-key mega-keys-mode-map (kbd "M-{")))
    (mega-keys-remove "M-{")
    (should-not (lookup-key mega-keys-mode-map (kbd "M-{")))
    (should-not (assoc "M-{" (mega-keys-test--rows)))
    ;; Not hidden behind a binding that says "nothing": what Emacs has shows.
    (let ((minor-mode-map-alist (list (cons 'mega-keys-mode mega-keys-mode-map))))
      (should (eq (key-binding (kbd "M-{")) #'backward-paragraph)))))

(ert-deftest mega-keys-a-malformed-row-is-refused-whole ()
  (mega-keys-test--scratch
    (let ((before (copy-tree mega-keys)))
      (should-error (mega-keys-add "Mine" '("C-c m" forward-word "Fine")
                                   '("C-c n" "not a command" "Broken")))
      (should-error (mega-keys-add "Mine" '("C-c m" forward-word "Fine" :everywhere)))
      (should (equal (assoc "Edit" mega-keys) (assoc "Edit" before))))))

(ert-deftest mega-keys-a-removed-feature-takes-its-keys-along ()
  "Deleting a module's line in init.el must not leave keys that only fail."
  (mega-keys-test--scratch
    ;; As after a start with nothing removed: every row is still there.
    (let ((before (copy-tree mega-keys)))
      (mega-keys-prune)
      (should (equal mega-keys before)))
    (mega-keys-add "Gone" '("C-c z z" mega-keys-test-no-such-command "Does nothing")
                   '(nil mega-keys-test-no-such-command-either "Nor this"))
    (mega-keys-add "Edit" '("C-c z e" mega-keys-test-no-such-command "Does nothing"))
    (should (lookup-key mega-keys-mode-map (kbd "C-c z e")))
    (mega-keys-prune)
    (should-not (assoc "Gone" mega-keys))
    (should-not (assoc "C-c z e" (mega-keys-test--rows)))
    ;; Not bound at all: a binding to a command that does not exist would
    ;; hide what Emacs has on the key, and fail when pressed.
    (should-not (lookup-key mega-keys-mode-map (kbd "C-c z e")))
    (should-not (lookup-key mega-keys-mode-map (kbd "C-c z z")))
    ;; What exists is untouched.
    (should (eq (lookup-key mega-keys-mode-map (kbd "C-c d")) #'mega-doc-buffer))))

;;;; Keys that work in one place only

(defun mega-keys-test--place-keys (row)
  "Every key ROW of `mega-keys-elsewhere' claims for its command."
  (append (split-string (car row) ", ") (nth 3 row)))

(ert-deftest mega-keys-the-keys-of-each-place-are-what-the-sheet-says ()
  "Key by key, and in both directions: nothing listed that is not bound,
nothing bound that is not listed."
  (dolist (place mega-keys-elsewhere)
    (pcase-let ((`(,title ,map ,feature . ,rows) place))
      (should (stringp title))
      (require feature)
      (let ((listed nil))
        (dolist (row rows)
          (should (stringp (nth 2 row)))
          (dolist (key (mega-keys-test--place-keys row))
            (should (equal (list title key (lookup-key (symbol-value map) (kbd key)))
                           (list title key (nth 1 row))))
            (push (key-description (kbd key)) listed)))
        ;; The map's own keys: what it inherits, from `special-mode' say,
        ;; is Emacs's to describe.
        (let ((own (copy-keymap (symbol-value map))))
          (set-keymap-parent own nil)
          (should (equal (list title (sort (mapcar #'car (mega-keys-test--bound own))
                                           #'string<))
                         (list title (sort (delete-dups listed) #'string<)))))))))

(ert-deftest mega-keys-the-cheat-sheet-lists-the-keys-of-each-place ()
  (save-window-excursion
    (mega-help)
    (let ((sheet (mega-test-buffer-string "*mega-help*")))
      (dolist (place mega-keys-elsewhere)
        (should (string-match-p (concat "^" (regexp-quote (car place)) "$") sheet))
        (dolist (row (nthcdr 3 place))
          (should (string-match-p
                   (concat "^  " (regexp-quote (car row)) " +"
                           (regexp-quote (nth 2 row)) "$")
                   sheet)))))))

(ert-deftest mega-keys-no-keymap-of-mega-s-is-missing-from-the-sheet ()
  "A module that grows a keymap of its own has to say so here."
  (let ((described (cons 'mega-keys-mode-map
                         ;; The prompt's map holds one key, C-o, which leads
                         ;; to the options map; that one is described.
                         (cons 'mega-search-map
                               (mapcar #'cadr mega-keys-elsewhere))))
        (found nil))
    (dolist (file (directory-files (expand-file-name "lisp" mega-dir) t "\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward
                "^(\\(?:defvar\\|defvar-keymap\\|defconst\\) +\\(mega-[a-z0-9-]+-map\\)\\_>"
                nil t)
          (push (intern (match-string 1)) found))))
    (should (> (length found) 5))
    (dolist (map found)
      (should (memq map described)))))

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
