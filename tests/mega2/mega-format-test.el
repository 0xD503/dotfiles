;;; mega-format-test.el --- Tests for mega-trust.el and mega-format.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-trust)
(require 'mega-format)

(defvar mega-test-pwned)

;;;; Trust

(defmacro mega-format-test--trust-store (&rest body)
  "Run BODY with an empty, private trust store."
  (declare (indent 0))
  `(mega-test-with-directory trust-dir
     (let ((mega-trust-file (expand-file-name "trusted.eld" trust-dir))
           (mega-trust--decisions nil))
       ,@body)))

(ert-deftest mega-trust-an-undecided-project-is-not-trusted ()
  (mega-format-test--trust-store
    (mega-test-with-directory dir
      (should-not (mega-trust-decision dir))
      (should-not (mega-trust-p dir)))))

(ert-deftest mega-trust-a-script-is-never-asked-and-never-trusted ()
  (mega-format-test--trust-store
    (mega-test-with-directory dir
      (let (asked)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked t) t)))
          (should-not (mega-trust-p dir t "run its formatter"))
          (should-not asked)
          (should-not (mega-trust-decision dir)))))))

(ert-deftest mega-trust-the-user-is-asked-once-and-the-answer-kept ()
  (mega-format-test--trust-store
    (mega-test-with-directory dir
      (let ((noninteractive nil) (asked 0) question)
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt) (setq asked (1+ asked) question prompt) t)))
          (should (mega-trust-p dir t "start its language server"))
          (should (mega-trust-p dir t "start its language server"))
          (should (= asked 1))
          ;; The question says which project and what for.
          (should (string-match-p (regexp-quote (abbreviate-file-name dir)) question))
          (should (string-match-p "start its language server" question))
          ;; The answer survives a restart.
          (setq mega-trust--decisions 'unread)
          (should (mega-trust-p dir t))
          (should (= asked 1)))))))

(ert-deftest mega-trust-a-no-is-remembered-too ()
  (mega-format-test--trust-store
    (mega-test-with-directory dir
      (let ((noninteractive nil) (asked 0))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked (1+ asked)) nil)))
          (should-not (mega-trust-p dir t))
          (should-not (mega-trust-p dir t))
          (should (= asked 1))
          (should (eq (mega-trust-decision dir) 'untrusted)))))))

(ert-deftest mega-trust-can-be-given-and-taken-back ()
  (mega-format-test--trust-store
    (mega-test-with-directory dir
      (let ((default-directory dir))
        (mega-trust-project)
        (should (mega-trust-p dir))
        (mega-distrust-project)
        (should-not (mega-trust-p dir))))))

(ert-deftest mega-trust-covers-the-project-not-just-one-directory ()
  (skip-unless (executable-find "git"))
  (mega-format-test--trust-store
    (mega-test-with-directory dir
      (make-directory (expand-file-name "src/deep" dir) t)
      (let ((default-directory dir)
            (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null") process-environment)))
        (call-process "git" nil nil nil "init" "--quiet")
        (mega-trust-project))
      (should (mega-trust-p (expand-file-name "src/deep/" dir)))
      (should (equal (mega-trust-root (expand-file-name "src/deep/" dir))
                     (abbreviate-file-name dir))))))

(ert-deftest mega-trust-the-store-is-data-and-kept-in-the-state-directory ()
  (should (file-in-directory-p (default-value 'mega-trust-file) mega-state-dir))
  (makunbound 'mega-test-pwned)
  (mega-format-test--trust-store
    (dolist (content '("(progn (setq mega-test-pwned t))" "((\"/x/\" . maybe))"
                       "garbage (((" ""))
      (mega-test-write mega-trust-file content)
      (setq mega-trust--decisions 'unread)
      (should-not (mega-trust--decisions)))
    (should-not (boundp 'mega-test-pwned))))

;;;; Formatting

(defmacro mega-format-test--with-formatter (script &rest body)
  "Run BODY with a formatter for text files that is the shell SCRIPT.
The project is trusted.  DIR is bound to a fresh directory."
  (declare (indent 1))
  `(mega-test-with-directory dir
     (let* ((bin (expand-file-name "bin/" dir))
            (tool (mega-test-write (expand-file-name "mega-test-fmt" bin)
                                   "#!/bin/sh" ,script ""))
            (exec-path (cons bin exec-path))
            (mega--exe-cache (make-hash-table :test #'equal))
            (mega-formatters '(((text-mode) ("mega-test-fmt"))))
            (mega-exec-context-functions nil))
       (set-file-modes tool #o755)
       (cl-letf (((symbol-function 'mega-trust-p) (lambda (&rest _) t)))
         ,@body))))

(ert-deftest mega-format-chooses-the-first-installed-formatter ()
  (let ((mega-formatters '(((text-mode) ("first" "-a") ("second" "-b")))))
    (with-temp-buffer
      (text-mode)
      (cl-letf (((symbol-function 'mega-exec-find)
                 (lambda (program &rest _) (equal program "second"))))
        (should (equal (mega-format-command) '("second" "-b"))))
      (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
        (should-not (mega-format-command))))
    (with-temp-buffer
      (prog-mode)
      (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) t)))
        (should-not (mega-format-command))))))

(ert-deftest mega-format-rust-uses-rustfmt-with-the-edition-of-the-crate ()
  "What `cargo fmt' runs, with what `cargo fmt' passes."
  (mega-test-with-directory dir
    (mega-test-write (expand-file-name "Cargo.toml" dir)
                     "[package]" "name = \"x\"" "edition = \"2021\"" "")
    (mega-test-visiting buffer (mega-test-write (expand-file-name "src/main.rs" dir)
                                                "fn main() {}" "")
      (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) t)))
        (let ((mega-formatters (default-value 'mega-formatters))
              (mega-exec-context-functions nil))
          (setq major-mode 'mega-rust-mode)
          (should (equal (mega-format-command)
                         '("rustfmt" "--emit" "stdout" "--edition" "2021"))))))))

(ert-deftest mega-format-placeholders-become-the-file-name ()
  (with-temp-buffer
    (setq buffer-file-name "/src/thing.c")
    (unwind-protect
        (let ((mega-exec-context-functions nil))
          (should (equal (mega-format--expand '("fmt" assume-filename file "-"))
                         '("fmt" "--assume-filename=/src/thing.c" "/src/thing.c" "-"))))
      (setq buffer-file-name nil))))

(ert-deftest mega-format-no-formatter-whose-configuration-is-a-program ()
  (should-not (seq-some (lambda (entry)
                          (seq-some (lambda (command) (equal (car command) "prettier"))
                                    (cdr entry)))
                        mega-formatters)))

(ert-deftest mega-format-replaces-the-buffer-with-the-formatters-output ()
  (mega-format-test--with-formatter "tr a-z A-Z"
    (with-temp-buffer
      (text-mode)
      (insert "one\ntwo\n")
      (should (mega-format-buffer))
      (should (equal (buffer-string) "ONE\nTWO\n")))))

(ert-deftest mega-format-leaves-an-already-formatted-buffer-unmodified ()
  (mega-format-test--with-formatter "cat"
    (with-temp-buffer
      (text-mode)
      (insert "one\n")
      (set-buffer-modified-p nil)
      (should-not (mega-format-buffer))
      (should-not (buffer-modified-p)))))

(ert-deftest mega-format-keeps-the-cursor-in-place ()
  (mega-format-test--with-formatter "sed 's/^  */    /'"
    (with-temp-buffer
      (text-mode)
      (insert "a\n  indented here\nz\n")
      (goto-char (point-min))
      (search-forward "indented ")
      (mega-format-buffer)
      (should (equal (buffer-string) "a\n    indented here\nz\n"))
      (should (looking-at-p "here")))))

(ert-deftest mega-format-a-failing-formatter-changes-nothing ()
  (mega-format-test--with-formatter "echo 'broken output'; echo 'syntax error on line 3' >&2; exit 1"
    (with-temp-buffer
      (text-mode)
      (insert "precious\n")
      (should (equal (mega-format-run '("mega-test-fmt"))
                     "mega-test-fmt failed: syntax error on line 3"))
      (should-not (mega-format-buffer))
      (should (equal (buffer-string) "precious\n")))))

(ert-deftest mega-format-a-formatter-that-prints-nothing-changes-nothing ()
  "Empty output is a formatter that did not work, not an empty file."
  (mega-format-test--with-formatter "exit 0"
    (with-temp-buffer
      (text-mode)
      (insert "precious\n")
      (should (equal (mega-format-run '("mega-test-fmt")) "mega-test-fmt printed nothing"))
      (should (equal (buffer-string) "precious\n")))))

(ert-deftest mega-format-a-formatter-that-hangs-is-given-up-on ()
  (mega-format-test--with-formatter "sleep 30"
    (with-temp-buffer
      (text-mode)
      (insert "precious\n")
      (let ((mega-format-timeout 0.3))
        (should (string-match-p "took more than" (mega-format-run '("mega-test-fmt")))))
      (should (equal (buffer-string) "precious\n")))))

(ert-deftest mega-format-a-missing-formatter-is-reported-not-signalled ()
  (with-temp-buffer
    (insert "precious\n")
    (should (stringp (mega-format-run '("mega-test-no-such-formatter"))))
    (should (equal (buffer-string) "precious\n"))))

;;;; On save

(defun mega-format-test--save (file text)
  "Visit FILE, add TEXT, save, and return what is then on disk."
  (mega-test-visiting buffer file
    (goto-char (point-max))
    (insert text)
    (let ((inhibit-message t))
      (save-buffer)))
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest mega-format-saving-formats-in-a-trusted-project ()
  (mega-format-test--with-formatter "tr a-z A-Z"
    (should (memq #'mega-format-before-save (default-value 'before-save-hook)))
    (let ((file (mega-test-write (expand-file-name "a.txt" dir) "one" "")))
      (should (equal (mega-format-test--save file "two\n") "ONE\nTWO\n")))))

(ert-deftest mega-format-saving-does-not-format-in-an-untrusted-project ()
  (mega-format-test--with-formatter "tr a-z A-Z"
    (cl-letf (((symbol-function 'mega-trust-p)
               ;; Saving must not stop to ask, either.
               (lambda (_dir ask &rest _) (should-not ask) nil)))
      (let ((file (mega-test-write (expand-file-name "a.txt" dir) "one" "")))
        (should (equal (mega-format-test--save file "two\n") "one\ntwo\n"))))))

(ert-deftest mega-format-a-failing-formatter-never-stops-the-save ()
  (mega-format-test--with-formatter "exit 1"
    (let ((file (mega-test-write (expand-file-name "a.txt" dir) "one" "")))
      (should (equal (mega-format-test--save file "two\n") "one\ntwo\n")))))

(ert-deftest mega-format-even-an-error-in-mega-never-stops-the-save ()
  (mega-format-test--with-formatter "cat"
    (cl-letf (((symbol-function 'mega-format-buffer) (lambda (&rest _) (error "bug"))))
      (let ((file (mega-test-write (expand-file-name "a.txt" dir) "one" "")))
        (should (equal (mega-format-test--save file "two\n") "one\ntwo\n"))))))

(ert-deftest mega-format-on-save-can-be-switched-off-and-skips-huge-buffers ()
  (mega-format-test--with-formatter "tr a-z A-Z"
    (let ((file (mega-test-write (expand-file-name "a.txt" dir) "one" "")))
      (let ((mega-format-on-save nil))
        (should (equal (mega-format-test--save file "two\n") "one\ntwo\n")))
      (let ((mega-format-max-size 3))
        (should (equal (mega-format-test--save file "x\n") "one\ntwo\nx\n"))))))

;;;; The whole project

(ert-deftest mega-format-project-runs-the-projects-own-tool-at-its-root ()
  (mega-test-with-directory dir
    (let* ((bin (expand-file-name "bin/" dir))
           (cargo (mega-test-write (expand-file-name "cargo" bin)
                                   "#!/bin/sh" "echo \"$@\" > ran-in-\"$(basename \"$PWD\")\"" ""))
           (project (file-name-as-directory (expand-file-name "crate" dir)))
           (exec-path (cons bin exec-path))
           (mega--exe-cache (make-hash-table :test #'equal))
           (mega-exec-context-functions nil))
      (set-file-modes cargo #o755)
      (mega-test-write (expand-file-name "Cargo.toml" project) "[package]" "")
      (make-directory (expand-file-name "src" project))
      (cl-letf (((symbol-function 'mega-trust-p) (lambda (&rest _) t))
                ((symbol-function 'mega-project-root) (lambda (&rest _) project)))
        (let ((default-directory (expand-file-name "src/" project))
              (inhibit-message t))
          (mega-format-project)))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name "ran-in-crate" project))
                       (buffer-string))
                     "fmt\n")))))

(ert-deftest mega-format-project-refuses-an-untrusted-or-unknown-project ()
  (mega-test-with-directory dir
    (cl-letf (((symbol-function 'mega-project-root) (lambda (&rest _) dir)))
      (let ((default-directory dir))
        (should-error (mega-format-project) :type 'user-error)
        (mega-test-write (expand-file-name "Cargo.toml" dir) "[package]" "")
        (cl-letf (((symbol-function 'mega-trust-p) (lambda (&rest _) nil)))
          (should-error (mega-format-project) :type 'user-error))))))

(provide 'mega-format-test)
;;; mega-format-test.el ends here
