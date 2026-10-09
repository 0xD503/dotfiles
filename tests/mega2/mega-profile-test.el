;;; mega-profile-test.el --- Tests for how MEGA 2.0 is launched  -*- lexical-binding: t; -*-

;;; Commentary:

;; MEGA itself is launcher-neutral, which the terminal stage of
;; tests/test_mega2.sh checks by starting it both ways.  What is checked here
;; is the chemacs2 profile list the dotfiles repo deploys.

;;; Code:

(require 'mega-test-helper)

(defconst mega-profile-test-file
  (expand-file-name "../.emacs-profiles.el" mega-test-config-dir)
  "The chemacs2 profile list in the dotfiles repo.")

(defun mega-profile-test--profiles ()
  "The profile list, read the way chemacs2 reads it."
  (with-temp-buffer
    (insert-file-contents mega-profile-test-file)
    (goto-char (point-min))
    (read (current-buffer))))

(ert-deftest mega-profile-mega-2-is-the-default ()
  (skip-unless (file-readable-p mega-profile-test-file))
  (should (equal (alist-get 'user-emacs-directory
                            (cdr (assoc "default" (mega-profile-test--profiles))))
                 "~/.mega2.d")))

(ert-deftest mega-profile-every-profile-is-well-formed-and-distinct ()
  (skip-unless (file-readable-p mega-profile-test-file))
  (let ((profiles (mega-profile-test--profiles)))
    (dolist (profile profiles)
      (should (stringp (car profile)))
      (should (stringp (alist-get 'user-emacs-directory (cdr profile)))))
    (should (equal (mapcar #'car profiles)
                   (delete-dups (mapcar #'car profiles))))))

(ert-deftest mega-profile-mega-never-mentions-its-launcher ()
  "No file of MEGA may depend on chemacs: it must start without it."
  (dolist (file (append (directory-files mega-lisp-dir t "\\.el\\'")
                        (list (expand-file-name "init.el" mega-dir)
                              (expand-file-name "early-init.el" mega-dir))))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not (re-search-forward "chemacs" nil t)))))

(provide 'mega-profile-test)
;;; mega-profile-test.el ends here
