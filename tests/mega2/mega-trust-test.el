;;; mega-trust-test.el --- What an untrusted project may not do  -*- lexical-binding: t; -*-

;;; Commentary:

;; The promise under test is the one MEGA's security rests on: a repository
;; cannot run code by being opened.  So the first test here opens a file of
;; every kind MEGA knows in a directory nobody has trusted, and counts the
;; programs that start.  The rest pin down what a decision covers and how
;; it is stored.  (The store's basics are in mega-format-test.el.)

;;; Code:

(require 'mega-test-helper)
(require 'mega-trust)
(require 'mega-lsp)
(require 'mega-lang)

(defvar flymake-mode)
(defvar trusted-content)
(declare-function flymake-start "flymake")

(defmacro mega-trust-test--store (&rest body)
  "Run BODY with an empty trust store, in a fresh directory DIR."
  (declare (indent 0))
  `(mega-test-with-directory dir
     (let ((mega-trust-file (expand-file-name "trusted.eld" dir))
           (mega-trust--decisions nil)
           (mega-lang--told nil)
           (inhibit-message t))
       ,@body)))

(defmacro mega-trust-test--watching-programs (&rest body)
  "Run BODY and return the names of the programs started meanwhile."
  (declare (indent 0))
  `(let* ((started nil)
          (note-make (lambda (&rest arguments)
                       (push (car (plist-get arguments :command)) started)))
          (note-call (lambda (program &rest _) (push program started))))
     (advice-add 'make-process :before note-make)
     (advice-add 'call-process :before note-call)
     (advice-add 'process-file :before note-call)
     (unwind-protect
         (progn ,@body)
       (advice-remove 'make-process note-make)
       (advice-remove 'call-process note-call)
       (advice-remove 'process-file note-call))
     (delete-dups (delq nil started))))

(defconst mega-trust-test--files
  '(("main.c" "int main(void) { return 0; }")
    ("tool.cpp" "int main() { return 0; }")
    ("script.pl" "BEGIN { open(my $f, '>', 'ran-perl'); } print 1;")
    ("tool.py" "print(1)")
    ("run.sh" "#!/bin/sh" "echo 1")
    ("lib.rb" "puts 1")
    ("main.rs" "fn main() {}")
    ("init.el" "(message \"1\")")
    ("build.zig" "pub fn build() void {}")
    ("main.go" "package main")
    ("app.js" "console.log(1)")
    ("notes.md" "# notes")
    ("Cargo.toml" "[package]" "name = \"x\"")
    ("settings.yaml" "a: 1")
    ("justfile" "build:" "\techo 1"))
  "A file of every kind, as a hostile repository might hold them.")

(defun mega-trust-test--hostile-project (dir)
  "Fill DIR with `mega-trust-test--files' and a Makefile that leaves a mark."
  (mega-test-write (expand-file-name "Makefile" dir)
                   "$(shell touch ran-make-parse)"
                   "check-syntax:"
                   "\ttouch ran-make-target"
                   "")
  (dolist (file mega-trust-test--files)
    (apply #'mega-test-write (expand-file-name (car file) dir)
           (append (cdr file) '("")))))

;;;; Opening a file runs nothing

(ert-deftest mega-trust-opening-any-file-in-an-untrusted-project-runs-nothing ()
  "Not a checker, not a server, not a question: whatever the file is."
  (mega-trust-test--store
    (mega-trust-test--hostile-project dir)
    (let ((asked nil)
          (buffers nil)
          ;; A session in which somebody could be asked.
          (noninteractive nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked t) nil))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (setq asked t) nil))
                ;; Every server is "installed": the worst case.
                ((symbol-function 'mega-exec-find) (lambda (&rest _) t))
                ;; Emacs's offer to build a parser is a question too, but
                ;; not this one: leave it out of the count.
                ((symbol-function 'mega-lang-parser-p) #'ignore))
        (unwind-protect
            (let ((started
                   (mega-trust-test--watching-programs
                     (dolist (file mega-trust-test--files)
                       (let ((buffer (find-file-noselect
                                      (expand-file-name (car file) dir))))
                         (push buffer buffers)
                         (with-current-buffer buffer
                           ;; Had a checker been switched on, a buffer on
                           ;; screen would start it: do what the screen does.
                           (when (bound-and-true-p flymake-mode)
                             (flymake-start nil t))
                           (run-hooks 'post-command-hook)))))))
              (should-not started)
              (should-not asked)
              (dolist (buffer buffers)
                (with-current-buffer buffer
                  (should-not (bound-and-true-p flymake-mode))
                  (should-not (bound-and-true-p eglot--managed-mode))
                  (when (derived-mode-p 'prog-mode 'conf-mode)
                    (should mega-trust-held)))))
          (mapc #'kill-buffer buffers))))
    (should-not (directory-files dir nil "\\`ran-"))))

(ert-deftest mega-trust-a-trusted-project-gets-its-checks ()
  "The contrast: with trust, the same file is checked as you type."
  (mega-trust-test--store
    (mega-trust-test--hostile-project dir)
    (let ((default-directory dir))
      (mega-trust-project))
    (mega-test-visiting buffer (expand-file-name "main.c" dir)
      (should flymake-mode)
      (should-not mega-trust-held)
      ;; Emacs's own guards are told the same thing.
      (should (eq trusted-content :all)))
    ;; A file of another project stays as it was.
    (mega-test-with-directory other
      (mega-test-visiting buffer (mega-test-write (expand-file-name "x.c" other) "int x;")
        (should-not (bound-and-true-p flymake-mode))
        (should mega-trust-held)
        (should-not (local-variable-p 'trusted-content))))))

(ert-deftest mega-trust-deciding-starts-what-was-waiting-in-open-buffers ()
  (mega-trust-test--store
    (mega-trust-test--hostile-project dir)
    (let ((servers nil))
      (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) t))
                ((symbol-function 'eglot-ensure)
                 (lambda () (push (buffer-name) servers))))
        (mega-test-visiting c-buffer (expand-file-name "main.c" dir)
          (mega-test-visiting rust-buffer (expand-file-name "main.rs" dir)
            (should-not servers)
            (should mega-trust-held)
            (mega-trust-project)
            ;; Both buffers, not only the one the key was pressed in.
            (should (member "main.rs" servers))
            (should flymake-mode)
            (should-not mega-trust-held)
            (with-current-buffer c-buffer
              (should flymake-mode)
              (should-not mega-trust-held))
            ;; And taking it back stops the checking.
            (mega-distrust-project)
            (should-not flymake-mode)
            (should mega-trust-held)
            (with-current-buffer c-buffer
              (should-not flymake-mode))))))))

;;;; What a decision covers

(ert-deftest mega-trust-a-lone-directory-does-not-cover-what-is-below-it ()
  (mega-trust-test--store
    (let ((downloads (expand-file-name "downloads/" dir))
          (unpacked (expand-file-name "downloads/unpacked/" dir)))
      (make-directory unpacked t)
      (let ((default-directory downloads))
        (mega-trust-project))
      (should (mega-trust-p downloads))
      (should-not (mega-trust-p unpacked))
      (should (equal (cdr (assoc (abbreviate-file-name downloads)
                                 (mega-trust--decisions)))
                     'directory)))))

(ert-deftest mega-trust-a-lone-directory-grant-does-not-become-a-project-grant ()
  "A manifest dropped into a directory you once allowed inherits nothing."
  (mega-trust-test--store
    (let ((downloads (expand-file-name "downloads/" dir))
          (deep (expand-file-name "downloads/src/" dir)))
      (make-directory deep t)
      (let ((default-directory downloads))
        (mega-trust-project))
      (should (mega-trust-p downloads))
      (mega-test-write (expand-file-name "package.json" downloads) "{}")
      ;; Now a project, rooted there, covering src/ too: not what was allowed.
      (should (equal (mega-trust-root deep) (abbreviate-file-name downloads)))
      (should-not (mega-trust-p downloads))
      (should-not (mega-trust-p deep))
      (should-not (mega-trust-decision deep))
      ;; Saying yes again, knowingly, covers the project.
      (let ((default-directory deep))
        (mega-trust-project))
      (should (mega-trust-p downloads))
      (should (mega-trust-p deep)))))

(ert-deftest mega-trust-home-is-never-a-project ()
  "A checkout or a manifest in the home directory must not cover all of it."
  (mega-trust-test--store
    (let* ((home (file-name-as-directory (expand-file-name "~")))
           (marker (expand-file-name "pyproject.toml" home))
           (git (expand-file-name ".git/HEAD" home))
           (below (expand-file-name "mega-trust-test-below/" home)))
      (unwind-protect
          (progn
            (make-directory below t)
            (mega-test-write git "ref: refs/heads/main" "")
            (mega-test-write marker "")
            (should (equal (mega-trust-root below) (abbreviate-file-name below)))
            (let ((default-directory home))
              (mega-trust-project))
            ;; The files of the home directory itself, and nothing below it.
            (should (mega-trust-p home))
            (should-not (mega-trust-p below)))
        (delete-file marker)
        (delete-directory (expand-file-name ".git" home) t)
        (delete-directory below t)))))

;;;; The store, with more than one Emacs running

(ert-deftest mega-trust-another-session-s-decision-is-seen-and-kept ()
  (mega-trust-test--store
    (let ((one (file-name-as-directory (expand-file-name "one" dir)))
          (two (file-name-as-directory (expand-file-name "two" dir)))
          (three (file-name-as-directory (expand-file-name "three" dir))))
      (dolist (each (list one two three)) (make-directory each))
      (let ((default-directory one)) (mega-trust-project))
      (should (mega-trust-p one))
      ;; Another Emacs takes `one' back and trusts `two'.
      (sleep-for 0.02)
      (mega-test-write mega-trust-file
                       (prin1-to-string (list (cons (abbreviate-file-name one) nil)
                                              (cons (abbreviate-file-name two) 'directory))))
      ;; This one sees it without being restarted...
      (should-not (mega-trust-p one))
      (should (mega-trust-p two))
      ;; ...and does not write its old view back over it.
      (let ((default-directory three)) (mega-trust-project))
      (setq mega-trust--decisions 'unread)
      (should-not (mega-trust-p one))
      (should (mega-trust-p two))
      (should (mega-trust-p three)))))

(ert-deftest mega-trust-the-store-is-never-left-half-written ()
  (mega-trust-test--store
    (let ((default-directory dir))
      (mega-trust-project)
      (should-not (file-exists-p (concat mega-trust-file ".new")))
      ;; A failure to write leaves the old file whole.
      (let ((before (with-temp-buffer (insert-file-contents mega-trust-file)
                                      (buffer-string))))
        (cl-letf (((symbol-function 'rename-file)
                   (lambda (&rest _) (error "Disk full"))))
          (should-error (mega-distrust-project)))
        (should (equal before (with-temp-buffer (insert-file-contents mega-trust-file)
                                                (buffer-string))))
        (setq mega-trust--decisions 'unread)
        (should (mega-trust-p dir))))))

(ert-deftest mega-trust-a-change-is-announced ()
  (mega-trust-test--store
    (let ((heard nil)
          (default-directory dir))
      (let ((mega-trust-change-functions
             (list (lambda (root) (push root heard)))))
        (mega-trust-project)
        (mega-distrust-project)
        (should (equal heard (list (abbreviate-file-name dir)
                                   (abbreviate-file-name dir))))))))

(provide 'mega-trust-test)
;;; mega-trust-test.el ends here
