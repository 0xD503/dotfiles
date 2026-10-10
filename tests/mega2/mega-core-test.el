;;; mega-core-test.el --- Tests for mega-core.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)

(defvar mega-test-pwned)
(defvar compilation-read-command)
(defvar compile-command)

;;;; Safety

(ert-deftest mega-core-a-backup-is-made-outside-the-project ()
  (mega-test-with-directory project
    (let ((file (mega-test-write (expand-file-name "src/notes.txt" project)
                                 "original" ""))
          ;; Emacs makes no backups under the temporary directory, which is
          ;; where the sandbox is.  Lift that here; what is being tested is
          ;; where a backup goes, not whether this directory deserves one.
          (backup-enable-predicate #'always))
      (mega-test-visiting buffer file
        (goto-char (point-max))
        (insert "edited\n")
        (save-buffer))
      ;; Nothing but the file itself in the project...
      (should (equal (directory-files (file-name-directory file) nil "\\`[^.]")
                     '("notes.txt")))
      ;; ...and a copy of the original in the cache.
      (let ((backups (directory-files (expand-file-name "backup" mega-cache-dir)
                                      t "notes\\.txt")))
        (should backups)
        (should (equal (with-temp-buffer
                         (insert-file-contents (car backups))
                         (buffer-string))
                       "original\n"))))))

(ert-deftest mega-core-auto-saves-and-locks-go-to-the-cache ()
  (mega-test-with-directory project
    (let ((file (mega-test-write (expand-file-name "notes.txt" project) "x" "")))
      (mega-test-visiting buffer file
        (should auto-save-default)
        (should (file-in-directory-p (make-auto-save-file-name)
                                     (expand-file-name "auto-save" mega-cache-dir))))
      (should create-lockfiles)
      (should (file-in-directory-p (make-lock-file-name file)
                                   (expand-file-name "lock" mega-cache-dir))))))

(ert-deftest mega-core-a-deep-path-still-gets-an-auto-save-name ()
  "Hashed names: a long path must not make the auto-save file uncreatable."
  (let* ((deep (concat "/" (mapconcat #'identity (make-list 60 "directory") "/")
                       "/file.txt"))
         (name (with-temp-buffer
                 (setq buffer-file-name deep)
                 (prog1 (make-auto-save-file-name)
                   (setq buffer-file-name nil)))))
    (should (< (length (file-name-nondirectory name)) 128))))

(ert-deftest mega-core-deleting-moves-to-the-trash ()
  (should delete-by-moving-to-trash)
  (should remote-file-name-inhibit-delete-by-moving-to-trash))

(ert-deftest mega-core-auto-revert-is-on ()
  (should global-auto-revert-mode))

;;;; Privacy

(ert-deftest mega-core-no-packages-and-no-archives ()
  (should-not package-enable-at-startup)
  (should-not package-archives)
  (should-not (bound-and-true-p package--initialized))
  (should-not (file-in-directory-p package-user-dir mega-dir)))

(ert-deftest mega-core-custom-never-writes-a-tracked-file ()
  (should (file-in-directory-p custom-file mega-state-dir)))

(ert-deftest mega-core-passwords-are-never-offered-for-saving ()
  (should-not auth-source-save-behavior))

(ert-deftest mega-core-no-spell-or-grammar-checking ()
  (should-not text-mode-ispell-word-completion)
  (with-temp-buffer
    (text-mode)
    (should-not (bound-and-true-p flyspell-mode))
    (should-not (memq 'ispell-completion-at-point completion-at-point-functions)))
  (with-temp-buffer
    (prog-mode)
    (should-not (bound-and-true-p flyspell-mode)))
  ;; Not merely switched off: the libraries were never loaded.
  (should-not (memq 'ispell mega-test-features-at-startup))
  (should-not (memq 'flyspell mega-test-features-at-startup)))

;;;; Security

(ert-deftest mega-core-local-variable-policy ()
  (should (eq enable-local-variables :safe))
  (should-not enable-local-eval)
  (should-not enable-remote-dir-locals))

(ert-deftest mega-core-an-eval-line-in-a-file-does-not-run ()
  "Opening a file must not run its code, and must not stop to ask either."
  (makunbound 'mega-test-pwned)
  (mega-test-with-directory project
    (let ((file (mega-test-write
                 (expand-file-name "innocent.txt" project)
                 ";; -*- eval: (setq mega-test-pwned t); fill-column: 72 -*-" "")))
      (mega-test-visiting buffer file
        (should-not (boundp 'mega-test-pwned))
        ;; A variable Emacs knows to be harmless is still honoured.
        (should (= fill-column 72))))))

(ert-deftest mega-core-unsafe-directory-variables-are-ignored ()
  (makunbound 'mega-test-pwned)
  (mega-test-with-directory project
    (mega-test-write (expand-file-name ".dir-locals.el" project)
                     "((nil . ((eval . (setq mega-test-pwned t))"
                     "         (shell-file-name . \"/tmp/evil-shell\")"
                     "         (exec-path . (\"/tmp/evil-bin\"))"
                     "         (fill-column . 90))))" "")
    (let ((file (mega-test-write (expand-file-name "a.txt" project) "x" "")))
      (mega-test-visiting buffer file
        (should-not (boundp 'mega-test-pwned))
        (should-not (local-variable-p 'shell-file-name))
        (should-not (local-variable-p 'exec-path))
        (should (= fill-column 90))))))

(ert-deftest mega-core-a-project-may-suggest-a-build-command-only-if-trusted ()
  "Emacs accepts `compile-command' from a project because `compile' shows
the command and waits.  A command can hide its tail off the screen, so
MEGA takes one only from a project you trust, and only while it is shown."
  (should compilation-read-command)
  (mega-test-with-directory project
    (let ((mega-trust-file (expand-file-name "trusted.eld" project))
          (mega-trust--decisions nil)
          (file (mega-test-write (expand-file-name "a.txt" project) "x" ""))
          (inhibit-message t))
      (mega-test-write (expand-file-name ".dir-locals.el" project)
                       "((nil . ((compile-command . \"make suspicious\"))))" "")
      ;; Not trusted: the project's command is not taken.
      (mega-test-visiting buffer file
        (should-not (equal compile-command "make suspicious")))
      (let ((default-directory project))
        (mega-trust-project))
      (mega-test-visiting buffer file
        (should (equal compile-command "make suspicious"))
        ;; With the confirmation off, the same value is no longer accepted.
        (let ((compilation-read-command nil))
          (should-not (safe-local-variable-p 'compile-command "make suspicious"))))
      ;; Loading the library that owns the variable does not undo this.
      (require 'compile)
      (let ((default-directory project))
        (mega-distrust-project))
      (mega-test-visiting buffer file
        (should-not (equal compile-command "make suspicious"))))))

(ert-deftest mega-core-a-repository-cannot-make-git-run-a-program ()
  "A directory inside a clone can pose as a repository with its own config.
Emacs runs git on opening a file; git must not obey that config."
  (skip-unless (executable-find "git"))
  (mega-test-with-directory clone
    (let* ((inner (expand-file-name "vendor/x/" clone))
           (ran (expand-file-name "ran-by-git" clone))
           (status (lambda ()
                     (let ((default-directory inner))
                       (ignore-errors (process-file "git" nil nil nil "status"))))))
      (make-directory (expand-file-name "objects" inner) t)
      (make-directory (expand-file-name "refs" inner) t)
      (mega-test-write (expand-file-name "HEAD" inner) "ref: refs/heads/main" "")
      (mega-test-write (expand-file-name "readme.txt" inner) "hello" "")
      (mega-test-write (expand-file-name "config" inner)
                       "[core]" "\trepositoryformatversion = 0" "\tbare = false"
                       "\tworktree = ."
                       (format "\tfsmonitor = touch %s" ran) "")
      ;; First without MEGA's settings: if this git is not fooled at all,
      ;; there is nothing here to test.
      (let ((process-environment
             (seq-remove (lambda (entry) (string-prefix-p "GIT_CONFIG_" entry))
                         process-environment)))
        (funcall status))
      (skip-unless (file-exists-p ran))
      (delete-file ran)
      ;; Now as Emacs runs it with MEGA loaded.
      (should (member "GIT_CONFIG_KEY_0=safe.bareRepository" process-environment))
      (funcall status)
      (should-not (file-exists-p ran))
      ;; Opening the file, which is what a person would do.
      (mega-test-visiting buffer (expand-file-name "readme.txt" inner)
        (vc-refresh-state))
      (should-not (file-exists-p ran)))))

(ert-deftest mega-core-git-settings-already-in-the-environment-are-kept ()
  (let ((process-environment (list "GIT_CONFIG_COUNT=1"
                                   "GIT_CONFIG_KEY_0=user.name"
                                   "GIT_CONFIG_VALUE_0=someone")))
    (mega-core-harden-git)
    (should (equal (getenv "GIT_CONFIG_COUNT") "3"))
    (should (equal (getenv "GIT_CONFIG_KEY_0") "user.name"))
    (should (equal (getenv "GIT_CONFIG_KEY_1") "safe.bareRepository"))
    (should (equal (getenv "GIT_CONFIG_VALUE_1") "explicit"))
    (should (equal (getenv "GIT_CONFIG_KEY_2") "core.fsmonitor"))
    (should (equal (getenv "GIT_CONFIG_VALUE_2") "false"))))

(ert-deftest mega-core-a-mistake-in-local-el-does-not-switch-mega-off ()
  "The safety settings must not depend on a file that is edited by hand."
  (mega-test-with-directory dir
    (let ((copy (expand-file-name "config/" dir))
          (report (expand-file-name "report" dir)))
      (copy-directory mega-test-config-dir copy nil t t)
      (mega-test-write (expand-file-name "local.el" copy)
                       ";;; -*- lexical-binding: t; -*-"
                       "(this-function-does-not-exist)" "")
      (call-process (expand-file-name invocation-name invocation-directory)
                    nil nil nil "-Q" "--batch"
                    "-l" (expand-file-name "early-init.el" copy)
                    "-l" (expand-file-name "init.el" copy)
                    "--eval"
                    (format "(with-temp-file %S (prin1 (list enable-local-variables enable-local-eval (length mega-module-times) make-backup-files mega-module-failures) (current-buffer)))"
                            report))
      (let ((seen (with-temp-buffer (insert-file-contents report)
                                    (read (current-buffer)))))
        (should (eq (nth 0 seen) :safe))
        (should-not (nth 1 seen))
        (should (> (nth 2 seen) 10))
        (should (nth 3 seen))
        ;; And it says what went wrong, where the other failures are said.
        (should (equal (mapcar #'car (nth 4 seen)) '(local.el)))
        (should (string-match-p "this-function-does-not-exist"
                                (cdr (car (nth 4 seen)))))))))

(ert-deftest mega-core-network-settings-refuse-bad-certificates ()
  (should (eq gnutls-verify-error t))
  (should (eq network-security-level 'medium))
  (should (file-in-directory-p nsm-settings-file mega-state-dir)))

;;;; Project conventions

(ert-deftest mega-core-defaults-for-new-text ()
  (should (= (default-value 'fill-column) 80))
  (should-not (default-value 'indent-tabs-mode))
  (should (eq (default-value 'buffer-file-coding-system) 'utf-8-unix))
  (should require-final-newline))

(ert-deftest mega-core-editorconfig-overrides-the-defaults ()
  (mega-test-with-directory project
    (mega-test-write (expand-file-name ".editorconfig" project)
                     "root = true" "" "[*]"
                     "indent_style = tab" "max_line_length = 100" "")
    (let ((file (mega-test-write (expand-file-name "src/a.c" project)
                                 "int x;" "")))
      (mega-test-visiting buffer file
        (should (= fill-column 100))
        (should indent-tabs-mode)))))

(provide 'mega-core-test)
;;; mega-core-test.el ends here
