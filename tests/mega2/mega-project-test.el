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
  (let ((temporary-file-directory "/nonexistent-temporary-directory/"))
    (should (mega-project--rememberable-p "/home/u/src/thing/"))
    (should-not (mega-project--rememberable-p "/ssh:host:/home/u/src/thing/"))
    (should-not (mega-project--rememberable-p "/home/u/.password-store/"))
    (should-not (mega-project--rememberable-p "/home/u/.ssh/")))
  (let ((temporary-file-directory "/tmp/"))
    (should-not (mega-project--rememberable-p "/tmp/scratch-checkout/"))))

(ert-deftest mega-project-opening-a-file-remembers-its-project ()
  (skip-unless (executable-find "git"))
  (mega-project-test--with-repository dir
    (let ((project--list nil)
          (project-list-file (expand-file-name "projects-test" mega-state-dir))
          ;; The sandbox is under the temporary directory, which is exactly
          ;; what is normally left out.
          (temporary-file-directory "/nonexistent-temporary-directory/"))
      (should (memq #'mega-project-remember find-file-hook))
      (mega-test-visiting buffer (expand-file-name "src/main.rs" dir)
        (should (member dir (project-known-project-roots)))))))

(ert-deftest mega-project-a-file-under-tmp-is-not-remembered ()
  (skip-unless (executable-find "git"))
  (mega-project-test--with-repository dir
    (let ((project--list nil)
          (project-list-file (expand-file-name "projects-test-2" mega-state-dir))
          (temporary-file-directory (file-name-directory (directory-file-name dir))))
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
