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
         (mega-search-submodules nil)
         (mega-search-backend 'git) (mega-search-min-input 2)
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
      (should (member "--exclude-dir=.?*" (mega-search-command 'grep "x" nil))))
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

(defun mega-search-test--found (dir backend &rest settings)
  "The files BACKEND finds needle in under DIR, with SETTINGS on.
SETTINGS are among `untracked', `ignored' and `hidden'; the rest are off."
  (let ((mega-search-untracked (and (memq 'untracked settings) t))
        (mega-search-ignored (and (memq 'ignored settings) t))
        (mega-search-hidden (and (memq 'hidden settings) t)))
    (mega-search-test--files (mega-search-run "needle" dir backend))))

(ert-deftest mega-search-which-files-each-program-searches ()
  "The table in the Commentary of mega-search.el, tried on a real checkout.
The programs disagree, because only git knows what is tracked: this
holds each to what the table says of it."
  (skip-unless (executable-find "git"))
  (mega-search-test--defaults
    (mega-search-test--with-repository dir
      (let ((tracked '("src/deep/code.rs" "tracked.txt"))
            (hidden '(".hidden/secret.txt"))
            (untracked '("untracked.txt"))
            (ignored '("ignored.log"))
            ;; Of a copy: sorting rearranges the list it is given.
            (all (lambda (&rest lists)
                   (sort (copy-sequence (apply #'append lists)) #'string<))))
        ;; git grep: hidden files always; untracked and ignored when asked,
        ;; and ignored files, being untracked, bring the untracked along.
        (should (equal (mega-search-test--found dir 'git)
                       (funcall all tracked hidden)))
        (should (equal (mega-search-test--found dir 'git 'hidden)
                       (funcall all tracked hidden)))
        (should (equal (mega-search-test--found dir 'git 'untracked)
                       (funcall all tracked hidden untracked)))
        (should (equal (mega-search-test--found dir 'git 'ignored)
                       (funcall all tracked hidden untracked ignored)))
        (should (equal (mega-search-test--found dir 'git 'untracked 'ignored)
                       (funcall all tracked hidden untracked ignored)))
        ;; ripgrep: untracked files always; ignored and hidden when asked.
        (when (executable-find "rg")
          (should (equal (mega-search-test--found dir 'rg)
                         (funcall all tracked untracked)))
          (should (equal (mega-search-test--found dir 'rg 'untracked)
                         (funcall all tracked untracked)))
          (should (equal (mega-search-test--found dir 'rg 'hidden)
                         (funcall all tracked untracked hidden)))
          (should (equal (mega-search-test--found dir 'rg 'ignored)
                         (funcall all tracked untracked ignored)))
          (should (equal (mega-search-test--found dir 'rg 'ignored 'hidden)
                         (funcall all tracked untracked ignored hidden))))
        ;; grep: untracked and ignored files always; hidden when asked.
        ;; Without them it must still find the rest: `.' is a name that
        ;; starts with a dot, and once excluded the whole search with it.
        (should (equal (mega-search-test--found dir 'grep)
                       (funcall all tracked untracked ignored)))
        (should (equal (mega-search-test--found dir 'grep 'ignored 'untracked)
                       (funcall all tracked untracked ignored)))
        (should (equal (mega-search-test--found dir 'grep 'hidden)
                       (funcall all tracked untracked ignored hidden)))))))

(ert-deftest mega-search-the-settings-line-says-only-what-the-program-acts-on ()
  "What a program does whatever you say is not shown as a setting of it."
  (mega-search-test--defaults
    (let ((mega-search-untracked t) (mega-search-ignored t)
          (mega-search-hidden t) (mega-search-submodules nil))
      (let ((mega-search--backend 'git))
        (should (equal (mega-search-describe) "git  case:smart +untracked +ignored")))
      (let ((mega-search--backend 'rg))
        (should (equal (mega-search-describe) "rg  case:smart +ignored +hidden")))
      (let ((mega-search--backend 'grep))
        (should (equal (mega-search-describe) "grep  case:smart +hidden"))))
    ;; To git, ignored files are untracked ones: one brings the other.
    (let ((mega-search-untracked nil) (mega-search-ignored t) (mega-search--backend 'git))
      (should (equal (mega-search-describe) "git  case:smart +untracked +ignored")))
    (let ((mega-search-untracked nil) (mega-search-hidden nil))
      (dolist (backend '(git rg grep))
        (let ((mega-search--backend backend))
          (should (equal (mega-search-describe) (format "%s  case:smart" backend))))))))

(ert-deftest mega-search-a-key-the-program-cannot-act-on-says-so ()
  "Never a key that does nothing without a word; and it is remembered."
  (mega-search-test--defaults
    (let ((said nil))
      (cl-letf (((symbol-function 'mega-pick-refresh) #'ignore)
                ((symbol-function 'minibuffer-message)
                 (lambda (format &rest arguments)
                   (setq said (apply #'format format arguments)))))
        (let ((mega-search--backend 'rg))
          (mega-search-toggle-untracked)
          (should-not mega-search-untracked)
          (should (string-match-p "\\`\\[rg  case:smart \\+hidden\\]  ripgrep cannot tell untracked"
                                  said))
          ;; One it does act on: just the settings.
          (mega-search-toggle-hidden)
          (should (equal said "[rg  case:smart]"))
          (mega-search-toggle-submodules)
          (should (string-match-p "goes into a submodule" said)))
        (let ((mega-search--backend 'grep))
          (mega-search-toggle-ignored)
          (should (string-match-p "grep knows no ignore files" said)))
        (let ((mega-search--backend 'git))
          (mega-search-toggle-hidden)
          (should (string-match-p "git grep searches hidden files always" said))
          ;; What was pressed under ripgrep counts now that git is asked.
          (should (string-match-p "\\+submodules" said))
          (mega-search-toggle-word)
          (should-not (string-match-p "always\\|cannot" said)))))))

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

(ert-deftest mega-search-git-grep-first-and-the-next-where-it-cannot-be-used ()
  (mega-test-with-directory dir
    (let ((mega-search-backend (default-value 'mega-search-backend))
          (checkout (expand-file-name "checkout/" dir))
          (plain (expand-file-name "plain/" dir)))
      (should (eq mega-search-backend 'git))
      (mega-test-write (expand-file-name ".git/HEAD" checkout) "ref: refs/heads/main" "")
      (make-directory plain)
      (cl-letf (((symbol-function 'mega-exec-find)
                 (lambda (program &rest _) (member program '("git" "rg" "grep")))))
        ;; In a checkout: git grep, though ripgrep is installed.
        (should (eq (mega-search-backend-for checkout) 'git))
        (should (equal (mega-search-backends checkout) '(git rg grep)))
        ;; Outside one it cannot be used, and the next is.
        (should (eq (mega-search-backend-for plain) 'rg))
        (should (equal (mega-search-backends plain) '(rg grep)))
        ;; The one you prefer comes first, and the rest stay behind it.
        (let ((mega-search-backend 'rg))
          (should (equal (mega-search-backends checkout) '(rg git grep))))
        (let ((mega-search-backend 'grep))
          (should (equal (mega-search-backends checkout) '(grep git rg)))
          (should (eq (mega-search-backend-for plain) 'grep)))
        ;; The old name for "whatever is best" means the default.
        (let ((mega-search-backend 'auto))
          (should (eq (mega-search-backend-for checkout) 'git))))
      (cl-letf (((symbol-function 'mega-exec-find)
                 (lambda (program &rest _) (member program '("grep")))))
        (should (eq (mega-search-backend-for checkout) 'grep)))
      (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
        (should-not (mega-search-backend-for checkout))))))

(ert-deftest mega-search-switching-the-program-lasts-for-the-session ()
  "C-o b is the easy way to ripgrep and back; the next search starts there."
  (mega-test-with-directory dir
    (mega-test-write (expand-file-name ".git/HEAD" dir) "ref: refs/heads/main" "")
    (let ((mega-search-backend 'git)
          (mega-search--directory dir)
          (mega-search--backend 'git))
      (cl-letf (((symbol-function 'mega-exec-find)
                 (lambda (program &rest _) (member program '("git" "rg" "grep"))))
                ((symbol-function 'mega-search--changed) #'ignore))
        (mega-search-cycle-backend)
        (should (eq mega-search--backend 'rg))
        ;; A search started afterwards, anywhere, begins with ripgrep.
        (should (eq mega-search-backend 'rg))
        (should (eq (mega-search-backend-for dir) 'rg))
        ;; Round the circle and home again: every program can be reached.
        (mega-search-cycle-backend)
        (should (eq mega-search-backend 'grep))
        (mega-search-cycle-backend)
        (should (eq mega-search-backend 'git))
        (should (eq mega-search--backend 'git))))))

(ert-deftest mega-search-the-prompt-says-which-program-searches ()
  (should (equal (mapcar #'mega-search-backend-name '(git rg grep nil))
                 '("git grep" "ripgrep" "grep" "no search program")))
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (mega-test-write (expand-file-name "a.txt" dir) "the needle" "")
      (let ((default-directory dir)
            (mega-search-backend 'grep)
            (inhibit-message t)
            (asked nil))
        (cl-letf (((symbol-function 'mega-pick-read)
                   (lambda (prompt &rest _) (setq asked prompt) "")))
          (mega-search-project))
        (should (string-match-p " with grep: \\'" asked))))))

(ert-deftest mega-search-submodules-or-untracked-files-never-both ()
  "As the user's own aliases have it: gs searches submodules, g does not.
And git refuses --recurse-submodules together with --untracked."
  (mega-search-test--defaults
    (let ((mega-search-submodules t))
      (let ((command (mega-search-command 'git "needle" nil)))
        (should (member "--recurse-submodules" command))
        (should-not (member "--untracked" command))
        (should-not (member "--no-exclude-standard" command)))
      (let ((mega-search-ignored t))
        (should-not (member "--untracked" (mega-search-command 'git "needle" nil))))
      ;; The other programs walk the directories; a submodule is one.
      (should-not (seq-some (lambda (argument) (string-search "submodule" argument))
                            (append (mega-search-command 'rg "needle" nil)
                                    (mega-search-command 'grep "needle" nil))))
      (let ((mega-search--backend 'git))
        (should (equal (mega-search-describe) "git  case:smart +submodules")))
      (let ((mega-search--backend 'rg))
        (should (equal (mega-search-describe) "rg  case:smart +hidden"))))))

(ert-deftest mega-search-git-really-searches-the-submodules-when-asked ()
  (skip-unless (executable-find "git"))
  (mega-search-test--defaults
    (mega-test-with-directory dir
      (let ((outer (expand-file-name "outer/" dir))
            (inner (expand-file-name "inner/" dir)))
        (dolist (repository (list outer inner))
          (make-directory repository)
          (mega-search-test--git repository "init" "--quiet"))
        (mega-test-write (expand-file-name "s.txt" inner) "needle in the submodule" "")
        (mega-search-test--git inner "add" "s.txt")
        (mega-search-test--git inner "-c" "user.email=t@example.invalid" "-c" "user.name=t"
                               "commit" "--quiet" "-m" "inner")
        (mega-test-write (expand-file-name "a.txt" outer) "needle tracked" "")
        (mega-search-test--git outer "add" "a.txt")
        (mega-search-test--git outer "-c" "protocol.file.allow=always"
                               "submodule" "--quiet" "add" inner "sub")
        (mega-test-write (expand-file-name "b.txt" outer) "needle untracked" "")
        (let ((files (lambda ()
                       (sort (mapcar (lambda (hit) (car (mega-search-parse hit)))
                                     (mega-search-run "needle" outer 'git))
                             #'string<))))
          (should (equal (funcall files) '("a.txt" "b.txt")))
          (let ((mega-search-submodules t))
            (should (equal (funcall files) '("a.txt" "sub/s.txt")))))))))

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
  (dolist (key '("c" "u" "i" "s" "h" "l" "w" "b" "e" "?"))
    (should (commandp (lookup-key mega-search-map (kbd (concat "C-o " key)))))))

(ert-deftest mega-search-the-description-names-what-is-on ()
  (mega-search-test--defaults
    (let ((mega-search--backend 'rg))
      (should (equal (mega-search-describe) "rg  case:smart +hidden"))
      (let ((mega-search-word t) (mega-search-hidden nil))
        (should (equal (mega-search-describe) "rg  case:smart words"))))
    (let ((mega-search--backend 'git))
      (should (equal (mega-search-describe) "git  case:smart +untracked")))))

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
