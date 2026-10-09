;;; mega-lib-test.el --- Tests for mega-lib.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)

;;;; Where state lives

(ert-deftest mega-lib-xdg-follows-the-environment ()
  (let ((process-environment (cons "MEGA_TEST_XDG=/somewhere/else" process-environment)))
    (should (equal (mega--xdg "MEGA_TEST_XDG" ".fallback") "/somewhere/else/mega2/"))))

(ert-deftest mega-lib-xdg-falls-back-when-the-variable-is-unusable ()
  "Unset, empty and relative values are all invalid in the XDG specification."
  (let ((fallback (file-name-as-directory (expand-file-name ".fallback/mega2" "~"))))
    (dolist (setting '("MEGA_TEST_XDG" "MEGA_TEST_XDG=" "MEGA_TEST_XDG=relative/dir"))
      (let ((process-environment (cons setting process-environment)))
        (should (equal (mega--xdg "MEGA_TEST_XDG" ".fallback") fallback))))))

(ert-deftest mega-lib-state-is-kept-apart-from-mega-1 ()
  (dolist (dir (list mega-cache-dir mega-state-dir mega-data-dir))
    (should (string-suffix-p "/mega2/" dir))))

(ert-deftest mega-lib-state-directories-are-in-the-sandbox-and-private ()
  (dolist (dir (list mega-cache-dir mega-state-dir mega-data-dir))
    (should (file-in-directory-p dir (getenv "MEGA_TEST_SANDBOX")))
    (should (file-directory-p dir))
    (should (= (logand (file-modes dir) #o777) #o700))))

(ert-deftest mega-lib-protect-directories-repairs-loose-permissions ()
  (set-file-modes mega-state-dir #o755)
  (mega-protect-directories)
  (should (= (logand (file-modes mega-state-dir) #o777) #o700)))

(ert-deftest mega-lib-paths-create-their-directory-private ()
  (let ((path (mega-cache "lib-test/deep/file")))
    (should (file-in-directory-p path mega-cache-dir))
    (should (file-directory-p (file-name-directory path)))
    (should-not (file-exists-p path))
    (should (= (logand (file-modes (file-name-directory path)) #o777) #o700))))

(ert-deftest mega-lib-nothing-lives-in-the-configuration-directory ()
  (dolist (dir (list mega-cache-dir mega-state-dir mega-data-dir user-emacs-directory))
    (should-not (file-in-directory-p dir mega-dir))))

;;;; Private files

(ert-deftest mega-lib-private-files-are-recognised ()
  (dolist (file '("~/.ssh/config" "~/.ssh/id_ed25519" "/srv/keys/id_rsa.pub"
                  "~/.gnupg/gpg.conf" "~/.password-store/mail.gpg"
                  "/home/u/notes.gpg" "/home/u/key.age" "/etc/ssl/server.pem"
                  "/etc/ssl/server.key" "/home/u/db.kdbx"
                  "/home/u/app/.env" "/home/u/app/.env.local"
                  "~/.netrc" "~/.authinfo" "~/.npmrc" "~/.aws/credentials"
                  "/home/u/app/secrets.yaml" "/home/u/app/credentials.json"
                  "/home/u/app/.secrets"
                  "/dev/shm/pass.abc/mail.txt" "/run/user/1000/tmp/sudoedit"))
    (should (mega-private-file-p file))))

(ert-deftest mega-lib-ordinary-files-are-not-private ()
  (dolist (file '("/home/u/src/main.rs" "/home/u/src/env.rs" "/home/u/README.md"
                  "/home/u/src/keymap.c" "/home/u/src/monkey.py"
                  "/home/u/src/secret_santa.py" "/home/u/app/.environment"
                  "/home/u/app/credentials.rs" "/run/media/u/usb/notes.txt"
                  "/home/u/app/environment.yaml"))
    (should-not (mega-private-file-p file))))

(ert-deftest mega-lib-private-list-is-extensible ()
  (let ((mega-private-file-regexps (cons "/vault/" mega-private-file-regexps)))
    (should (mega-private-file-p "/home/u/vault/plan.txt")))
  (should-not (mega-private-file-p "/home/u/vault/plan.txt")))

;;;; Probing the machine

(ert-deftest mega-lib-exe-p-finds-and-remembers ()
  (mega-test-with-directory dir
    (let ((tool (expand-file-name "mega-test-tool" dir))
          (mega--exe-cache (make-hash-table :test #'equal)))
      (mega-test-write tool "#!/bin/sh" "")
      (set-file-modes tool #o755)
      (let ((exec-path (list dir)))
        (should (equal (mega-exe-p "mega-test-tool") tool))
        (should-not (mega-exe-p "mega-test-no-such-tool")))
      ;; Both answers are remembered, even once $PATH no longer agrees.
      (let ((exec-path nil))
        (should (equal (mega-exe-p "mega-test-tool") tool)))
      (let ((exec-path (list dir)))
        (mega-test-write (expand-file-name "mega-test-no-such-tool" dir) "#!/bin/sh" "")
        (set-file-modes (expand-file-name "mega-test-no-such-tool" dir) #o755)
        (should-not (mega-exe-p "mega-test-no-such-tool"))
        (mega-forget-executables)
        (should (mega-exe-p "mega-test-no-such-tool"))))))

;;;; Loading modules

(defconst mega-lib-test--cookie ";;; -*- lexical-binding: t; -*-"
  "First line of every module the tests below write.")

(defmacro mega-lib-test--with-modules (dir &rest body)
  "Run BODY with DIR on `load-path' and the module records empty."
  (declare (indent 1))
  `(mega-test-with-directory ,dir
     (let ((load-path (cons ,dir load-path))
           (mega-module-times nil)
           (mega-module-failures nil)
           (mega-lazy-modules nil))
       ,@body)))

(ert-deftest mega-lib-load-module-loads-and-times ()
  (mega-lib-test--with-modules dir
    (mega-test-write (expand-file-name "mega-test-good.el" dir)
                     mega-lib-test--cookie
                     "(defvar mega-test-good-loaded t)" "(provide 'mega-test-good)")
    (mega-load-module 'mega-test-good)
    (should (featurep 'mega-test-good))
    (should (numberp (alist-get 'mega-test-good mega-module-times)))
    (should-not mega-module-failures)))

(ert-deftest mega-lib-a-broken-module-is-recorded-not-fatal ()
  (mega-lib-test--with-modules dir
    (mega-test-write (expand-file-name "mega-test-broken.el" dir)
                     mega-lib-test--cookie
                     "(error \"deliberately broken\")" "(provide 'mega-test-broken)")
    (mega-test-write (expand-file-name "mega-test-after.el" dir)
                     mega-lib-test--cookie
                     "(provide 'mega-test-after)")
    ;; No error escapes, and the module after the broken one still loads.
    (mega-load-module 'mega-test-broken)
    (mega-load-module 'mega-test-after)
    (should-not (featurep 'mega-test-broken))
    (should (featurep 'mega-test-after))
    (should (equal (alist-get 'mega-test-broken mega-module-failures)
                   "deliberately broken"))))

(ert-deftest mega-lib-a-missing-module-is-recorded-not-fatal ()
  (mega-lib-test--with-modules dir
    (mega-load-module 'mega-test-does-not-exist)
    (should (alist-get 'mega-test-does-not-exist mega-module-failures))))

(ert-deftest mega-lib-a-lazy-module-loads-on-first-use ()
  (mega-lib-test--with-modules dir
    (mega-test-write (expand-file-name "mega-test-lazy.el" dir)
                     mega-lib-test--cookie
                     "(defun mega-test-lazy-command () (interactive) 'ran)"
                     "(provide 'mega-test-lazy)")
    (mega-load-module '(mega-test-lazy :commands (mega-test-lazy-command)))
    (should-not (featurep 'mega-test-lazy))
    (should (commandp 'mega-test-lazy-command))
    (should (equal (alist-get 'mega-test-lazy mega-lazy-modules)
                   '(mega-test-lazy-command)))
    (should (eq (mega-test-lazy-command) 'ran))
    (should (featurep 'mega-test-lazy))))

(ert-deftest mega-lib-failures-are-reported-once-startup-is-over ()
  (let (warned)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (setq warned message))))
      (let ((mega-module-failures nil))
        (mega-report-module-failures)
        (should-not warned))
      (let ((mega-module-failures '((mega-test-x . "bad thing"))))
        (mega-report-module-failures)
        (should (string-match-p "mega-test-x: bad thing" warned))))))

;;;; The real module list

(ert-deftest mega-lib-every-listed-module-exists-and-loaded-cleanly ()
  (should-not mega-module-failures)
  (dolist (spec mega-modules)
    (let ((module (if (consp spec) (car spec) spec)))
      (should (locate-library (symbol-name module)))
      (if (consp spec)
          (dolist (command (plist-get (cdr spec) :commands))
            (should (commandp command)))
        (should (featurep module))))))

(ert-deftest mega-lib-lazy-modules-stay-out-of-startup ()
  (dolist (spec mega-modules)
    (when (consp spec)
      (should-not (memq (car spec) mega-test-features-at-startup)))))

;;;; The source itself

(defun mega-lib-test--source-files ()
  "Every Lisp file MEGA consists of."
  (append (directory-files mega-lisp-dir t "\\.el\\'")
          (list (expand-file-name "early-init.el" mega-dir)
                (expand-file-name "init.el" mega-dir))))

(defun mega-lib-test--setq-variables (form)
  "Every variable assigned with a plain `setq' anywhere in FORM."
  (when (consp form)
    (append (when (eq (car form) 'setq)
              (let ((rest (cdr form)) variables)
                (while (consp rest)
                  (when (symbolp (car rest)) (push (car rest) variables))
                  (setq rest (cdr-safe (cdr rest))))
                variables))
            (let (found)
              (while (consp form)
                (setq found (append (mega-lib-test--setq-variables (car form)) found)
                      form (cdr form)))
              found))))

(ert-deftest mega-lib-no-buffer-local-variable-is-set-with-plain-setq ()
  "A variable that becomes buffer-local when set needs `setq-default'.
Plain `setq' on one changes only the buffer that is current during
startup, so the setting silently does nothing anywhere else."
  (let ((count 0))
    (dolist (file (mega-lib-test--source-files))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil
            (while t
              (dolist (variable (mega-lib-test--setq-variables (read (current-buffer))))
                (setq count (1+ count))
                (when (local-variable-if-set-p variable)
                  (ert-fail (format "%s: use setq-default for `%s'"
                                    (file-name-nondirectory file) variable)))))
          (end-of-file nil))))
    ;; Guard against the walker quietly finding nothing.
    (should (> count 50))))

(ert-deftest mega-lib-every-file-uses-lexical-binding ()
  (dolist (file (mega-lib-test--source-files))
    (with-temp-buffer
      (insert-file-contents file nil 0 200)
      (should (string-match-p "lexical-binding: t" (buffer-string))))))

(provide 'mega-lib-test)
;;; mega-lib-test.el ends here
