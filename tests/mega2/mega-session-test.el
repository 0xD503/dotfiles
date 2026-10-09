;;; mega-session-test.el --- Tests for mega-session.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'recentf)
(require 'saveplace)
(require 'savehist)

(ert-deftest mega-session-everything-is-stored-in-the-state-directory ()
  (dolist (file (list savehist-file recentf-save-file save-place-file
                      bookmark-default-file project-list-file))
    (should (file-in-directory-p file mega-state-dir))
    (should-not (file-in-directory-p file mega-dir))))

(ert-deftest mega-session-the-modes-are-on ()
  (should savehist-mode)
  (should recentf-mode)
  (should save-place-mode)
  (should winner-mode))

;;;; Prompt history

(ert-deftest mega-session-the-kill-ring-is-not-on-the-save-list ()
  (should-not (memq 'kill-ring savehist-additional-variables))
  (should (memq 'search-ring savehist-additional-variables)))

(ert-deftest mega-session-saved-history-holds-prompts-but-nothing-copied ()
  "Write the history file for real and read back what is in it."
  (let ((kill-ring (list "mega-test-copied-password"))
        (search-ring (list "mega-test-search-term"))
        (extended-command-history (list "mega-test-command"))
        ;; savehist saves the histories of prompts that were actually used.
        (savehist-minibuffer-history-variables '(extended-command-history)))
    (savehist-save)
    (let ((saved (with-temp-buffer
                   (insert-file-contents savehist-file)
                   (buffer-string))))
      (should (string-match-p "mega-test-search-term" saved))
      (should (string-match-p "mega-test-command" saved))
      (should-not (string-match-p "mega-test-copied-password" saved))
      (should-not (string-match-p "kill-ring" saved)))))

;;;; Recent files

(ert-deftest mega-session-ordinary-files-are-remembered-as-recent ()
  (should (recentf-include-p "/home/u/src/main.rs"))
  (should (recentf-include-p "/home/u/README.md")))

(ert-deftest mega-session-private-files-are-not-remembered-as-recent ()
  (dolist (file '("/home/u/.ssh/config" "/home/u/app/.env" "/home/u/notes.gpg"
                  "/dev/shm/pass.abc/mail.txt"))
    (should-not (recentf-include-p file))))

(ert-deftest mega-session-noise-is-not-remembered-as-recent ()
  (dolist (file (list "/tmp/scratch.txt" "/home/u/repo/.git/COMMIT_EDITMSG"
                      "/ssh:host:/etc/hosts"
                      (expand-file-name "backup/x" mega-cache-dir)
                      (expand-file-name "history" mega-state-dir)))
    (should-not (recentf-include-p file))))

(ert-deftest mega-session-opening-a-private-file-leaves-no-trace ()
  "Visit a real secret and a real ordinary file; only one may be listed."
  (mega-test-with-directory project
    (let ((secret (mega-test-write (expand-file-name ".env" project) "TOKEN=x" ""))
          (plain (mega-test-write (expand-file-name "main.c" project) "int x;" ""))
          (recentf-list nil)
          (save-place-alist nil)
          ;; The sandbox is under /tmp, which MEGA also keeps out of the
          ;; list.  Leave only the rule under test.
          (recentf-exclude (list #'mega-private-file-p)))
      (dolist (file (list secret plain))
        (mega-test-visiting buffer file
          (goto-char (point-max))
          (save-place-to-alist)))
      (should (member plain recentf-list))
      (should-not (member secret recentf-list))
      (should (assoc plain save-place-alist))
      (should-not (assoc secret save-place-alist)))))

;;;; Cursor places

(ert-deftest mega-session-places-skip-private-files-and-keep-emacs-defaults ()
  (should (string-match-p save-place-ignore-files-regexp "/home/u/app/.env"))
  (should (string-match-p save-place-ignore-files-regexp "/home/u/.ssh/config"))
  ;; What Emacs ignored before is still ignored.
  (should (string-match-p save-place-ignore-files-regexp "/repo/.git/COMMIT_EDITMSG"))
  (should-not (string-match-p save-place-ignore-files-regexp "/home/u/src/main.rs")))

(provide 'mega-session-test)
;;; mega-session-test.el ends here
