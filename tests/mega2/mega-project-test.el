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

(provide 'mega-project-test)
;;; mega-project-test.el ends here
