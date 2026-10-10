;;; mega-project-test.el --- Tests for mega-project.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'project)

(defmacro mega-project-test--with-repository (dir &rest body)
  "Run BODY with DIR bound to a git repository holding two files."
  (declare (indent 1))
  `(mega-test-with-directory ,dir
     (mega-test-write (expand-file-name "src/main.rs" ,dir) "fn main() {}" "")
     (mega-test-write (expand-file-name "README.md" ,dir) "# readme" "")
     (let ((default-directory ,dir)
           (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null"
                                          "GIT_CONFIG_NOSYSTEM=1")
                                        process-environment)))
       (call-process "git" nil nil nil "init" "--quiet")
       (call-process "git" nil nil nil "add" "--all"))
     ,@body))

(ert-deftest mega-project-root-is-found-from-anywhere-inside ()
  (skip-unless (executable-find "git"))
  (mega-project-test--with-repository dir
    (should (equal (mega-project-root dir) dir))
    (should (equal (mega-project-root (expand-file-name "src/" dir)) dir))))

(ert-deftest mega-project-root-is-nil-outside-a-project-and-never-prompts ()
  (mega-test-with-directory dir
    ;; A prompt would try to read from the terminal and fail the test.
    (should-not (mega-project-root dir))))

(ert-deftest mega-project-only-local-ordinary-places-are-remembered ()
  (should (mega-project--rememberable-p "/home/u/src/thing/"))
  (should-not (mega-project--rememberable-p "/ssh:host:/home/u/src/thing/"))
  (should-not (mega-project--rememberable-p "/home/u/.password-store/"))
  (should-not (mega-project--rememberable-p "/home/u/.ssh/"))
  (let ((mega-temporary-directories mega-test-temporary-directories))
    (should-not (mega-project--rememberable-p "/tmp/scratch-checkout/"))))

(ert-deftest mega-project-opening-a-file-remembers-its-project ()
  (skip-unless (executable-find "git"))
  (mega-project-test--with-repository dir
    (let ((project--list nil)
          (project-list-file (expand-file-name "projects-test" mega-state-dir)))
      (should (memq #'mega-project-remember find-file-hook))
      (mega-test-visiting buffer (expand-file-name "src/main.rs" dir)
        (should (member dir (project-known-project-roots)))))))

(ert-deftest mega-project-a-file-under-tmp-is-not-remembered ()
  (skip-unless (executable-find "git"))
  (mega-project-test--with-repository dir
    (let ((project--list nil)
          (project-list-file (expand-file-name "projects-test-2" mega-state-dir))
          ;; As shipped: the sandbox is under the temporary directory.
          (mega-temporary-directories mega-test-temporary-directories))
      (mega-test-visiting buffer (expand-file-name "src/main.rs" dir)
        (should-not (member dir (project-known-project-roots)))))))

(ert-deftest mega-project-files-include-untracked-ones ()
  (skip-unless (executable-find "git"))
  (mega-project-test--with-repository dir
    (mega-test-write (expand-file-name "new.txt" dir) "new" "")
    (let* ((default-directory dir)
           (files (mapcar (lambda (file) (file-relative-name file dir))
                          (project-files (project-current nil dir)))))
      (should (member "src/main.rs" files))
      (should (member "new.txt" files)))))

(ert-deftest mega-project-the-list-of-projects-is-kept-in-the-state-directory ()
  (should (file-in-directory-p project-list-file mega-state-dir)))

(ert-deftest mega-project-the-tree-is-a-side-window-not-a-frame ()
  (should (commandp 'mega-project-tree))
  (should speedbar-prefer-window)
  (should-not speedbar-use-images))

;;;; Projects that are not under version control

(ert-deftest mega-project-a-manifest-marks-a-root-without-version-control ()
  (mega-test-with-directory dir
    (let ((deep (expand-file-name "src/bin/" dir)))
      (make-directory deep t)
      ;; Nothing marks it yet.
      (should-not (mega-project-root deep))
      (mega-test-write (expand-file-name "Cargo.toml" dir) "[package]" "")
      (should (equal (mega-project-root deep) dir))
      (should (equal (mega-project-root dir) dir))
      ;; Emacs's own project commands see the same project.
      (let ((default-directory deep))
        (should (equal (expand-file-name (project-root (project-current nil))) dir))))))

(defun mega-project-test--files (dir)
  "The files of the project at DIR as project.el reports them, relative."
  (let ((default-directory dir))
    (mapcar (lambda (file) (file-relative-name file dir))
            (project-files (project-current nil)))))

(defun mega-project-test--unpacked (dir)
  "Fill DIR like a Rust project that was built and is under no version control."
  (dolist (file '("Cargo.toml" "src/main.rs" "src/bin/tool.rs" ".cargo/config.toml"
                  "target/debug/build/x/out.d" "target/CACHEDIR.TAG"
                  "web/node_modules/left-pad/index.js" "web/app.js"
                  "notes/target.txt" "a name with spaces.txt" "-dash.txt"
                  "arch/riscv/boot.S" ".git-old/HEAD"))
    (mega-test-write (expand-file-name file dir) "x" "")))

(defconst mega-project-test--expected
  '("-dash.txt" ".cargo/config.toml" ".git-old/HEAD" "Cargo.toml"
    "a name with spaces.txt" "arch/riscv/boot.S" "notes/target.txt"
    "src/bin/tool.rs" "src/main.rs" "web/app.js")
  "What `mega-project-test--unpacked' holds that is a file of the project.")

(ert-deftest mega-project-files-without-version-control-leave-out-what-a-build-made ()
  "The case the markers exist for: `C-c p f' must not offer all of target/."
  (mega-test-with-directory dir
    (mega-project-test--unpacked dir)
    (should (equal (mega-project-test--files dir) mega-project-test--expected))
    ;; The same without ripgrep.
    (cl-letf (((symbol-function 'mega-exec-find)
               (lambda (program &rest _) (equal program "find"))))
      (should (equal (car (mega-project-list-command dir)) "find"))
      (should (equal (mega-project-test--files dir) mega-project-test--expected)))
    ;; What is left out is yours to say.
    (let ((mega-project-ignored-directories '("notes")))
      (should (member "target/CACHEDIR.TAG" (mega-project-test--files dir)))
      (should-not (member "notes/target.txt" (mega-project-test--files dir))))))

(ert-deftest mega-project-files-without-version-control-honour-an-ignore-file ()
  (skip-unless (executable-find "rg"))
  (mega-test-with-directory dir
    (mega-project-test--unpacked dir)
    (mega-test-write (expand-file-name ".gitignore" dir) "notes/" "")
    (should (equal (mega-project-test--files dir)
                   (sort (cons ".gitignore"
                               (remove "notes/target.txt"
                                       (copy-sequence mega-project-test--expected)))
                         #'string<)))))

(ert-deftest mega-project-a-left-out-name-is-a-name-and-not-a-pattern ()
  "A directory called {arch} or [x] must not take others with it."
  (mega-test-with-directory dir
    (mega-project-test--unpacked dir)
    (mega-test-write (expand-file-name "{arch}/log" dir) "x" "")
    (dolist (finder '("rg" "find"))
      (when (executable-find finder)
        (cl-letf (((symbol-function 'mega-exec-find)
                   (lambda (program &rest _) (equal program finder))))
          (let* ((mega-project-ignored-directories '("{arch}" "s?c" "*"))
                 (files (mega-project-test--files dir)))
            (should (member "arch/riscv/boot.S" files))
            (should (member "src/main.rs" files))
            (should-not (member "{arch}/log" files))))))))

(ert-deftest mega-project-listing-files-runs-where-the-files-are-and-is-bounded ()
  (mega-test-with-directory dir
    (mega-project-test--unpacked dir)
    (let ((seen nil))
      (cl-letf (((symbol-function 'mega-exec-run)
                 (lambda (program _args &rest options)
                   (setq seen (cons program options))
                   (list :status nil :output "" :error "" :stopped 'timeout))))
        ;; Too slow is an error with a reason, not an empty project.
        (should (string-match-p
                 "took more than"
                 (cadr (should-error (mega-project-list-files dir))))))
      ;; Never in a container: this reads the project, it does not build it.
      (should (plist-get (cdr seen) :local))
      (should (equal (plist-get (cdr seen) :directory) dir))
      (should (numberp (plist-get (cdr seen) :timeout))))))

;;;; Kinds of project

(ert-deftest mega-project-every-kind-is-well-formed ()
  (dolist (kind mega-project-kinds)
    (should (stringp (car kind)))
    (let ((row (cdr kind)) (keys nil))
      (let ((rest row))
        (while rest (push (car rest) keys) (setq rest (cddr rest))))
      (dolist (key keys)
        (should (memq key '(:root :also :tasks :format :debug))))
      (should (seq-every-p #'stringp (plist-get row :also)))
      (should (seq-every-p #'stringp (plist-get row :format)))
      (dolist (task (plist-get row :tasks))
        (should (symbolp (car task)))
        (should (cdr task))
        (should (seq-every-p #'stringp (cdr task))))
      (should (memq (plist-get row :debug) '(nil rust python native)))))
  ;; A file name appears once: that is the point of the table.
  (should (equal (mapcar #'car mega-project-kinds)
                 (delete-dups (mapcar #'car mega-project-kinds)))))

(ert-deftest mega-project-a-project-is-of-every-kind-its-root-shows ()
  (mega-test-with-directory dir
    (should-not (mega-project-kinds-of dir))
    (mega-test-write (expand-file-name "Makefile" dir) "all:" "")
    (mega-test-write (expand-file-name "Cargo.toml" dir) "[package]" "")
    (mega-test-write (expand-file-name ".justfile" dir) "build:" "")
    ;; In the order of the table, whatever the order they were made in.
    (should (equal (mapcar #'car (mega-project-kinds-of dir))
                   '("Cargo.toml" "Makefile" "justfile")))))

(ert-deftest mega-project-the-markers-are-the-kinds-found-only-at-a-root ()
  (should (equal (default-value 'mega-project-markers)
                 '("Cargo.toml" "go.mod" "build.zig" "CMakeLists.txt"
                   "pyproject.toml" "package.json" ".devcontainer")))
  ;; A Makefile is in every directory of some projects: never a marker.
  (should-not (member "Makefile" mega-project-markers))
  (should-not (member "justfile" mega-project-markers)))

(ert-deftest mega-project-a-new-repository-is-noticed-at-once ()
  "Emacs would go on saying \"no checkout here\" for five minutes.
What may run in a project is decided by its root, so MEGA cannot wait."
  (mega-test-with-directory dir
    (let ((inner (expand-file-name "unpacked/app/" dir)))
      (mega-test-write (expand-file-name "package.json" inner) "{}" "")
      (should (equal (mega-project-root inner) inner))
      (should (eq (car (mega-project-current inner)) 'mega))
      ;; A repository appears around it: `git init' two directories up.
      (mega-test-write (expand-file-name ".git/HEAD" dir) "ref: refs/heads/main" "")
      ;; As long as Emacs itself keeps an answer for a command: two seconds.
      (should (equal project-vc-cache-timeout '((file-remote-p) (always . 2))))
      (let ((project-vc-cache-timeout 0))
        (should (equal (mega-project-root inner) dir))
        (should-not (mega-project-left-out inner))))))

(ert-deftest mega-project-version-control-is-asked-before-the-markers ()
  "A crate inside a checkout stays part of the checkout's project."
  (mega-test-with-directory dir
    (mega-test-write (expand-file-name ".git/HEAD" dir) "ref: refs/heads/main" "")
    (mega-test-write (expand-file-name "crates/emu/Cargo.toml" dir) "[package]" "")
    (should (equal (mega-project-root (expand-file-name "crates/emu/" dir)) dir))))

(ert-deftest mega-project-a-marker-never-makes-home-or-the-disk-a-project ()
  (mega-test-with-directory dir
    (let* ((home (file-name-as-directory (expand-file-name "~")))
           (marker (expand-file-name "pyproject.toml" home))
           (below (expand-file-name "notes/" dir)))
      (make-directory below t)
      (unwind-protect
          (progn
            (mega-test-write marker "")
            (should-not (mega-project-try-markers home))
            (should-not (mega-project-try-markers "/")))
        (delete-file marker))
      ;; Which names count is yours to say.
      (mega-test-write (expand-file-name "Makefile" dir) "all:" "")
      (should-not (mega-project-root below))
      (let ((mega-project-markers '("Makefile")))
        (should (equal (mega-project-root below) dir))))))

(ert-deftest mega-project-markers-are-not-looked-for-on-another-machine ()
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (&rest _) (error "Walked a remote tree"))))
    (should-not (mega-project-try-markers "/ssh:mega-test.invalid:/srv/app/src/"))))

(provide 'mega-project-test)
;;; mega-project-test.el ends here
