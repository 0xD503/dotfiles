;;; mega-search-test.el --- Tests for mega-search.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'project)
(require 'mega-search)
(require 'ert-x)

(defmacro mega-search-test--defaults (&rest body)
  "Run BODY with every search setting at its default."
  (declare (indent 0))
  `(let ((mega-search-case 'smart) (mega-search-untracked t)
         (mega-search-ignored nil) (mega-search-hidden t)
         (mega-search-literal nil) (mega-search-word nil)
         (mega-search-backend 'auto) (mega-search-min-input 2)
         (mega-search-max-results 500))
     ,@body))

(defun mega-search-test--git (directory &rest args)
  "Run git with ARGS in DIRECTORY, isolated from the user's configuration."
  (let ((default-directory directory)
        (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null"
                                       "GIT_CONFIG_NOSYSTEM=1")
                                     process-environment)))
    (unless (eql 0 (apply #'call-process "git" nil nil nil args))
      (error "git %s failed" args))))

(defmacro mega-search-test--with-repository (dir &rest body)
  "Run BODY with DIR bound to a small git repository.
It has a tracked file, an untracked one, an ignored one and a hidden one,
each containing the word needle in a different case."
  (declare (indent 1))
  `(mega-test-with-directory ,dir
     (mega-test-write (expand-file-name "tracked.txt" ,dir)
                      "first line" "a needle here" "a Needle there" "")
     (mega-test-write (expand-file-name "src/deep/code.rs" ,dir)
                      "fn needle_finder() {}" "")
     (mega-test-write (expand-file-name ".gitignore" ,dir) "*.log" "")
     (mega-test-write (expand-file-name ".hidden/secret.txt" ,dir) "hidden needle" "")
     (mega-search-test--git ,dir "init" "--quiet")
     (mega-search-test--git ,dir "add" "--all")
     (mega-test-write (expand-file-name "untracked.txt" ,dir) "untracked needle" "")
     (mega-test-write (expand-file-name "ignored.log" ,dir) "ignored needle" "")
     ,@body))

(defun mega-search-test--files (hits)
  "The distinct files among HITS, sorted."
  (sort (delete-dups (mapcar (lambda (hit)
                               (car (mega-search-parse (substring-no-properties hit))))
                             hits))
        #'string<))

;;;; Reading the input

(ert-deftest mega-search-input-splits-into-pattern-and-paths ()
  (should (equal (mega-search-split "needle") '("needle")))
  (should (equal (mega-search-split "two words") '("two words")))
  (should (equal (mega-search-split "needle -- src/*.rs docs") '("needle" "src/*.rs" "docs")))
  (should (equal (mega-search-split "a--b") '("a--b"))))

(ert-deftest mega-search-smart-case-looks-for-a-capital ()
  (let ((mega-search-case 'smart))
    (should (mega-search--ignore-case-p "needle"))
    (should-not (mega-search--ignore-case-p "Needle")))
  (let ((mega-search-case 'ignore))
    (should (mega-search--ignore-case-p "Needle")))
  (let ((mega-search-case 'sensitive))
    (should-not (mega-search--ignore-case-p "needle"))))

;;;; The command lines

(ert-deftest mega-search-rg-command ()
  (mega-search-test--defaults
    (should (equal (mega-search-command 'rg "needle" nil)
                   '("rg" "--line-number" "--no-heading" "--color=never"
                     "--max-columns=300" "--max-columns-preview"
                     "--ignore-case" "--hidden" "--glob=!.git"
                     "--no-require-git" "--regexp=needle" ".")))
    (let ((mega-search-hidden nil) (mega-search-ignored t)
          (mega-search-literal t) (mega-search-word t))
      (should (equal (mega-search-command 'rg "Needle" '("src/*.rs"))
                     '("rg" "--line-number" "--no-heading" "--color=never"
                       "--max-columns=300" "--max-columns-preview"
                       "--case-sensitive" "--no-ignore" "--fixed-strings"
                       "--word-regexp" "--glob=src/*.rs" "--regexp=Needle" "."))))))

(ert-deftest mega-search-git-command ()
  "The base is the user's `git grep -PnI', spelled with long options."
  (mega-search-test--defaults
    (should (equal (mega-search-command 'git "needle" nil)
                   '("git" "--no-pager" "grep" "--line-number" "-I" "--color=never"
                     "--perl-regexp" "--ignore-case" "--untracked"
                     "-e" "needle" "--")))
    (let ((mega-search-untracked nil) (mega-search-case 'sensitive))
      (should (equal (mega-search-command 'git "needle" '("src"))
                     '("git" "--no-pager" "grep" "--line-number" "-I" "--color=never"
                       "--perl-regexp" "-e" "needle" "--" "src"))))
    (let ((mega-search-ignored t) (mega-search-literal t) (mega-search-word t))
      (should (equal (mega-search-command 'git "Needle" nil)
                     '("git" "--no-pager" "grep" "--line-number" "-I" "--color=never"
                       "--fixed-strings" "--untracked" "--no-exclude-standard"
                       "--word-regexp" "-e" "Needle" "--"))))))

(ert-deftest mega-search-grep-command ()
  (mega-search-test--defaults
    (should (equal (mega-search-command 'grep "needle" nil)
                   '("grep" "--recursive" "--line-number"
                     "--binary-files=without-match" "--color=never"
                     "--exclude-dir=.git" "--perl-regexp" "--ignore-case"
                     "--regexp=needle" "--" ".")))
    (let ((mega-search-hidden nil))
      (should (member "--exclude-dir=.*" (mega-search-command 'grep "x" nil))))
    ;; A path that begins with a dash is still a path.
    (should (equal (last (mega-search-command 'grep "x" '("-rf")) 2)
                   '("--" "-rf")))))

(ert-deftest mega-search-a-project-without-version-control-is-searched-without-its-build ()
  "Nothing tells ripgrep to skip target/ there, so MEGA does."
  (mega-test-with-directory dir
    (mega-test-write (expand-file-name "Cargo.toml" dir) "[package]" "")
    (mega-test-write (expand-file-name "src/main.rs" dir) "fn needle() {}" "")
    (mega-test-write (expand-file-name "target/debug/main.d" dir) "needle: src/main.rs" "")
    (mega-test-write (expand-file-name "notes/target.txt" dir) "needle in a note" "")
    (mega-test-write (expand-file-name ".gitignore" dir) "scratch.txt" "")
    (mega-test-write (expand-file-name "scratch.txt" dir) "needle, scratched" "")
    (mega-search-test--defaults
      (dolist (backend (seq-filter (lambda (backend) (mega-search--usable-p backend dir))
                                   '(rg grep)))
        (let* ((mega-search--left-out (mega-project-left-out dir))
               (files (lambda ()
                        (sort (mapcar (lambda (hit) (car (mega-search-parse hit)))
                                      (mega-search-run "needle" dir backend))
                              #'string<))))
          (should (member "target" mega-search--left-out))
          (should (equal (funcall files)
                         (if (eq backend 'rg)
                             '("notes/target.txt" "src/main.rs")
                           ;; grep knows nothing of ignore files.
                           '("notes/target.txt" "scratch.txt" "src/main.rs"))))
          ;; Asking for ignored files brings them back.
          (let ((mega-search-ignored t))
            (should (member "target/debug/main.d" (funcall files)))))))
    ;; In a checkout its own rules decide, and MEGA adds none.  (Emacs
    ;; remembers for two seconds that a directory was no checkout.)
    (mega-test-write (expand-file-name ".git/HEAD" dir) "ref: refs/heads/main" "")
    (let ((project-vc-cache-timeout 0))
      (should-not (mega-project-left-out dir)))))

(ert-deftest mega-search-a-pattern-is-one-argument-whatever-it-contains ()
  (mega-search-test--defaults
    (dolist (backend '(rg git grep))
      (let* ((nasty "a b; $(touch x) `id` -- --help 'q' \"w\"")
             (command (mega-search-command backend nasty nil)))
        (should (seq-some (lambda (argument)
                            (or (equal argument nasty)
                                (equal argument (concat "--regexp=" nasty))))
                          command))))))

;;;; Hits

(ert-deftest mega-search-a-hit-is-parsed ()
  (should (equal (mega-search-parse "src/a.rs:12:let x = 1;") '("src/a.rs" 12 "let x = 1;")))
  (should (equal (mega-search-parse "./src/a.rs:3:x") '("src/a.rs" 3 "x")))
  (should (equal (mega-search-parse "a.txt:7:has: colons: 9: inside")
                 '("a.txt" 7 "has: colons: 9: inside")))
  (should-not (mega-search-parse "Binary file x matches"))
  (should-not (mega-search-parse "")))

(ert-deftest mega-search-a-hit-is-shown-with-faces-and-still-parses ()
  (let ((hit (mega-search--present "./src/a.rs:12:let x = 1;")))
    (should (equal (substring-no-properties hit) "src/a.rs:12:let x = 1;"))
    (should (eq (get-text-property 0 'face hit) 'mega-search-file))
    (should (eq (get-text-property 9 'face hit) 'mega-search-line))
    (should-not (get-text-property 12 'face hit))))

;;;; Searching for real

(ert-deftest mega-search-too-short-an-input-runs-nothing ()
  (mega-search-test--defaults
    (let (ran)
      (cl-letf (((symbol-function 'mega-exec-lines)
                 (lambda (&rest _) (setq ran t) nil)))
        (should-not (mega-search-run "n" "/tmp/" 'grep))
        (should-not ran)
        (mega-search-run "ne" "/tmp/" 'grep)
        (should ran)))))

(ert-deftest mega-search-grep-finds-hits ()
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (mega-test-write (expand-file-name "a.txt" dir) "one" "a needle" "")
      (mega-test-write (expand-file-name "sub/b.txt" dir) "Needle two" "")
      (should (equal (sort (mapcar #'substring-no-properties
                                   (mega-search-run "needle" dir 'grep))
                           #'string<)
                     '("a.txt:2:a needle" "sub/b.txt:1:Needle two")))
      ;; A capital in the pattern makes case matter.
      (should (equal (mapcar #'substring-no-properties
                             (mega-search-run "Needle" dir 'grep))
                     '("sub/b.txt:1:Needle two"))))))

(ert-deftest mega-search-git-honours-untracked-and-ignored ()
  (skip-unless (executable-find "git"))
  (mega-search-test--defaults
    (mega-search-test--with-repository dir
      (should (equal (mega-search-test--files (mega-search-run "needle" dir 'git))
                     '(".hidden/secret.txt" "src/deep/code.rs" "tracked.txt"
                       "untracked.txt")))
      (let ((mega-search-untracked nil))
        (should (equal (mega-search-test--files (mega-search-run "needle" dir 'git))
                       '(".hidden/secret.txt" "src/deep/code.rs" "tracked.txt"))))
      (let ((mega-search-ignored t))
        (should (member "ignored.log"
                        (mega-search-test--files (mega-search-run "needle" dir 'git))))))))

(ert-deftest mega-search-git-honours-case-word-and-literal ()
  (skip-unless (executable-find "git"))
  (mega-search-test--defaults
    (mega-search-test--with-repository dir
      (let ((mega-search-untracked nil))
        (should (= 2 (length (mega-search-run "needle -- tracked.txt" dir 'git))))
        (let ((mega-search-case 'sensitive))
          (should (= 1 (length (mega-search-run "needle -- tracked.txt" dir 'git)))))
        ;; needle_finder is one word; as a whole word "needle" is not in it.
        (should (mega-search-run "needle -- src" dir 'git))
        (let ((mega-search-word t))
          (should-not (mega-search-run "needle -- src" dir 'git)))
        ;; As a regular expression "n..dle" matches; literally it does not.
        (should (mega-search-run "n..dle" dir 'git))
        (let ((mega-search-literal t))
          (should-not (mega-search-run "n..dle" dir 'git)))))))

(ert-deftest mega-search-rg-honours-hidden-and-ignored ()
  (skip-unless (executable-find "rg"))
  (skip-unless (executable-find "git"))
  (mega-search-test--defaults
    (mega-search-test--with-repository dir
      (should (equal (mega-search-test--files (mega-search-run "needle" dir 'rg))
                     '(".hidden/secret.txt" "src/deep/code.rs" "tracked.txt"
                       "untracked.txt")))
      (let ((mega-search-hidden nil))
        (should-not (member ".hidden/secret.txt"
                            (mega-search-test--files (mega-search-run "needle" dir 'rg)))))
      (let ((mega-search-ignored t))
        (should (member "ignored.log"
                        (mega-search-test--files (mega-search-run "needle" dir 'rg)))))
      (should (equal (mega-search-test--files (mega-search-run "needle -- *.rs" dir 'rg))
                     '("src/deep/code.rs"))))))

(ert-deftest mega-search-a-pattern-cannot-run-a-command ()
  "Search for something that would create a file if a shell ever saw it."
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (mega-test-write (expand-file-name "a.txt" dir) "text" "")
      (dolist (backend (mega-search-backends dir))
        (ignore-errors
          (mega-search-run "$(touch pwned-by-search) `touch pwned2`" dir backend)))
      (should-not (directory-files dir nil "pwned")))))

(ert-deftest mega-search-stops-at-the-result-limit ()
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (with-temp-file (expand-file-name "many.txt" dir)
        (dotimes (i 3000) (insert (format "needle %d\n" i))))
      (let ((mega-search-max-results 25))
        (should (= 25 (length (mega-search-run "needle" dir 'grep))))))))

;;;; Choosing the program

(ert-deftest mega-search-picks-the-best-program-available ()
  (mega-test-with-directory dir
    (let ((mega-search-backend 'auto))
      (cl-letf (((symbol-function 'mega-exec-find)
                 (lambda (program &rest _) (member program '("grep")))))
        (should (eq (mega-search-backend-for dir) 'grep)))
      (cl-letf (((symbol-function 'mega-exec-find)
                 (lambda (program &rest _) (member program '("rg" "grep")))))
        (should (eq (mega-search-backend-for dir) 'rg))
        ;; An explicit choice wins when it is usable...
        (let ((mega-search-backend 'grep))
          (should (eq (mega-search-backend-for dir) 'grep)))
        ;; ...and is dropped when it is not: no .git here.
        (let ((mega-search-backend 'git))
          (should (eq (mega-search-backend-for dir) 'rg))))
      (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
        (should-not (mega-search-backend-for dir))))))

;;;; The prompt's settings keys

(ert-deftest mega-search-the-setting-keys-change-the-settings ()
  (mega-search-test--defaults
    (cl-letf (((symbol-function 'mega-search--changed) #'ignore))
      (mega-search-cycle-case) (should (eq mega-search-case 'ignore))
      (mega-search-cycle-case) (should (eq mega-search-case 'sensitive))
      (mega-search-cycle-case) (should (eq mega-search-case 'smart))
      (mega-search-toggle-untracked) (should-not mega-search-untracked)
      (mega-search-toggle-ignored) (should mega-search-ignored)
      (mega-search-toggle-hidden) (should-not mega-search-hidden)
      (mega-search-toggle-literal) (should mega-search-literal)
      (mega-search-toggle-word) (should mega-search-word))))

(ert-deftest mega-search-every-setting-key-is-bound-after-C-o ()
  (dolist (key '("c" "u" "i" "h" "l" "w" "b" "e" "?"))
    (should (commandp (lookup-key mega-search-map (kbd (concat "C-o " key)))))))

(ert-deftest mega-search-the-description-names-what-is-on ()
  (mega-search-test--defaults
    (let ((mega-search--backend 'rg))
      (should (equal (mega-search-describe) "rg  case:smart +untracked +hidden"))
      (let ((mega-search-word t) (mega-search-hidden nil))
        (should (equal (mega-search-describe) "rg  case:smart +untracked words"))))))

;;;; The whole command

(ert-deftest mega-search-project-jumps-to-the-chosen-hit ()
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (mega-test-write (expand-file-name "a.txt" dir) "one" "two" "the needle" "")
      (let ((default-directory dir)
            (mega-search-backend 'grep))
        (save-window-excursion
          (mega-test-with-scripted-prompt "needle"
            (mega-search-project))
          (unwind-protect
              (progn
                (should (equal buffer-file-name (expand-file-name "a.txt" dir)))
                (should (= (line-number-at-pos) 3)))
            (kill-buffer (current-buffer))))))))

(ert-deftest mega-search-a-setting-key-changes-the-live-list ()
  "Typing the pattern, then C-o c twice, makes the search case-sensitive."
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (mega-test-write (expand-file-name "a.txt" dir) "NEEDLE" "needle" "")
      (let ((default-directory dir)
            (mega-search-backend 'grep)
            ;; The settings are echoed for this long; nobody is reading.
            (minibuffer-message-timeout 0))
        (save-window-excursion
          (mega-test-with-scripted-prompt
              (list "needle" #'mega-search-cycle-case #'mega-search-cycle-case)
            (mega-search-project))
          (unwind-protect
              (progn
                (should (eq mega-search-case 'sensitive))
                (should (= (line-number-at-pos) 2)))
            (kill-buffer (current-buffer))))))))

(ert-deftest mega-search-export-puts-every-hit-in-a-grep-buffer ()
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (mega-test-write (expand-file-name "a.txt" dir) "needle one" "needle two" "")
      (let ((default-directory dir)
            (mega-search-backend 'grep))
        (save-window-excursion
          (ert-simulate-keys (kbd "needle C-o e")
            (mega-search-project))
          (with-current-buffer "*mega-search*"
            (should (derived-mode-p 'grep-mode))
            (should (equal default-directory dir))
            (should (string-match-p "a.txt:1:needle one\na.txt:2:needle two"
                                    (buffer-string)))
            (should (string-match-p "2 hits" (buffer-string))))
          (kill-buffer "*mega-search*"))))))

(ert-deftest mega-search-without-any-program-says-what-to-do ()
  (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
    (should-error (mega-search-project) :type 'user-error)))

(ert-deftest mega-search-symbol-quotes-the-symbol ()
  (let (started)
    (cl-letf (((symbol-function 'mega-search-project)
               (lambda (&optional initial) (setq started initial))))
      (with-temp-buffer
        (emacs-lisp-mode)
        (insert "foo.bar*")
        (goto-char 2)
        (mega-search-symbol)
        (should (equal started (regexp-quote (thing-at-point 'symbol t))))
        (should (string-match-p "\\\\" started))))))

(provide 'mega-search-test)
;;; mega-search-test.el ends here
