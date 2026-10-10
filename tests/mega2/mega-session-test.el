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
  (let ((mega-temporary-directories mega-test-temporary-directories))
    (dolist (file (list "/tmp/scratch.txt" "/var/tmp/scratch.txt"
                        "/home/u/repo/.git/COMMIT_EDITMSG"
                        "/home/u/repo/.git/MERGE_MSG"
                        "/home/u/repo/.git/rebase-merge/git-rebase-todo"
                        "/ssh:host:/etc/hosts"
                        (expand-file-name "backup/x" mega-cache-dir)
                        (expand-file-name "history" mega-state-dir)))
      (should-not (recentf-include-p file)))))

(ert-deftest mega-session-opening-a-private-file-leaves-no-trace ()
  "Visit a real secret and a real ordinary file; only one may be listed."
  (mega-test-with-directory project
    (let ((secret (mega-test-write (expand-file-name ".env" project) "TOKEN=x" ""))
          (plain (mega-test-write (expand-file-name "main.c" project) "int x;" ""))
          (recentf-list nil)
          (save-place-alist nil))
      (dolist (file (list secret plain))
        (mega-test-visiting buffer file
          (goto-char (point-max))
          (save-place-to-alist)))
      (should (member plain recentf-list))
      (should-not (member secret recentf-list))
      (should (assoc plain save-place-alist))
      (should-not (assoc secret save-place-alist)))))

;;;; Cursor places

(defun mega-session-test--place-kept-p (file)
  "Non-nil if a buffer visiting FILE gets its cursor position remembered."
  (let ((save-place-alist nil))
    (with-temp-buffer
      (insert "some text\n")
      (setq buffer-file-name file)
      (unwind-protect
          (save-place-to-alist)
        (setq buffer-file-name nil)))
    (and save-place-alist t)))

(ert-deftest mega-session-places-skip-what-is-not-to-be-remembered ()
  (should (mega-session-test--place-kept-p "/home/u/src/main.rs"))
  (dolist (file '("/home/u/app/.env" "/home/u/.ssh/config" "/home/u/.pgpass"
                  "/repo/.git/COMMIT_EDITMSG"))
    (should-not (mega-session-test--place-kept-p file)))
  (let ((mega-temporary-directories mega-test-temporary-directories))
    (should-not (mega-session-test--place-kept-p "/tmp/scratch.txt"))))

(ert-deftest mega-session-places-follow-the-rule-as-it-is-now ()
  "A pattern added after start-up, say in local.el, counts at once."
  (should (mega-session-test--place-kept-p "/home/u/vault/plan.txt"))
  (let ((mega-private-file-regexps (cons "/vault/" mega-private-file-regexps)))
    (should-not (mega-session-test--place-kept-p "/home/u/vault/plan.txt"))))

;;;; One rule for everything that remembers

(defconst mega-session-test--not-to-be-remembered
  '("/home/u/.ssh/config" "/home/u/app/.env" "/home/u/notes.gpg"
    "/home/u/.git-credentials" "/home/u/.pgpass" "/home/u/.kube/config"
    "/home/u/.docker/config.json" "/home/u/infra/prod.tfvars"
    "/srv/www/.htpasswd" "/dev/shm/pass.abc/mail.txt"
    "/home/u/repo/.git/COMMIT_EDITMSG" "/tmp/scratch.txt" "/var/tmp/x.c")
  "Files of which nothing may be written down, each for its own reason.")

(defun mega-session-test--remembered-by (file)
  "The features that would write something about FILE to disk."
  (delq nil
        (list (and (recentf-include-p file) 'recent-files)
              (and (mega-session-test--place-kept-p file) 'cursor-place)
              (and (let ((buffer-file-name file)
                         (mega-undo-persist t))
                     (mega-undo--wanted-p))
                   'undo-history)
              (and (mega-workspace--recordable-p file) 'workspace)
              (and (let ((file-name-history (list file)))
                     (mega-session--forget-names)
                     file-name-history)
                   'prompt-history))))

(ert-deftest mega-session-everything-that-remembers-agrees-on-what-not-to ()
  "Several features keep notes about files.  None may know better than the rest."
  (require 'mega-undo)
  (require 'mega-workspace)
  (let ((mega-temporary-directories mega-test-temporary-directories))
    (dolist (file mega-session-test--not-to-be-remembered)
      (should (equal (cons file (mega-session-test--remembered-by file))
                     (list file))))
    ;; The list of projects holds directories, and goes by the same rule.
    (dolist (directory '("/home/u/.ssh/" "/home/u/.password-store/work/"
                         "/tmp/checkout/" "/dev/shm/unpacked/"))
      (should-not (mega-project--rememberable-p directory)))
    ;; The contrast, without which the above could pass by remembering nothing.
    (should (mega-project--rememberable-p "/home/u/src/"))
    (should (equal (mega-session-test--remembered-by "/home/u/src/main.rs")
                   '(recent-files cursor-place undo-history workspace
                                  prompt-history)))))

;;;; The whole of it, on disk

(defun mega-session-test--state-files-mentioning (text)
  "The files under MEGA's state directory that contain TEXT."
  (seq-filter (lambda (file)
                (with-temp-buffer
                  (insert-file-contents-literally file)
                  (search-forward text nil t)))
              (directory-files-recursively mega-state-dir "" nil)))

(ert-deftest mega-session-working-on-a-secret-leaves-nothing-in-the-state-directory ()
  "Open, change, save and close a secret; then save all that MEGA saves.
Nothing under the state directory may hold its name or a word of it.
An ordinary file gets the same treatment, to show that the features
under test were at work."
  (require 'mega-undo)
  (require 'mega-workspace)
  (mega-test-with-directory project
    (let* ((secret (mega-test-write (expand-file-name "mega-leak-probe.tfvars" project)
                                    "password = \"word-of-the-leak-probe\"" ""))
           (plain (mega-test-write (expand-file-name "mega-leak-contrast.c" project)
                                   "int word_of_the_leak_contrast;" ""))
           (recentf-list nil)
           (save-place-alist nil)
           (save-place-loaded t)
           (project--list nil)
           (file-name-history (list secret plain))
           (savehist-minibuffer-history-variables '(file-name-history))
           (mega-undo-persist t)
           (inhibit-message t))
      (mega-test-write (expand-file-name "Cargo.toml" project) "[package]" "")
      (save-window-excursion
        (delete-other-windows)
        (dolist (file (list secret plain))
          (switch-to-buffer (find-file-noselect file))
          ;; Deleted text is what an undo history holds.
          (goto-char (point-min))
          (search-forward "word")
          (undo-boundary)
          (delete-region (point) (line-end-position))
          (undo-boundary)
          (save-buffer))
        ;; The window shows the ordinary file now and showed the secret before.
        (mega-workspace-write (mega-workspace-capture "mega-leak-workspace"))
        (dolist (file (list secret plain))
          (kill-buffer (get-file-buffer file))))
      (savehist-save)
      (recentf-save-list)
      (save-place-alist-to-file)
      (project--write-project-list)
      (unwind-protect
          (progn
            (should-not (mega-session-test--state-files-mentioning "leak-probe"))
            ;; Recent files, cursor places, prompt history, the workspace,
            ;; and the undo history, which holds the deleted word.
            (should (>= (length (mega-session-test--state-files-mentioning
                                 "mega-leak-contrast"))
                        4))
            (should (mega-session-test--state-files-mentioning "the_leak_contrast")))
        (mega-workspace-delete "mega-leak-workspace")))))

(ert-deftest mega-session-file-names-typed-at-a-prompt-are-saved-without-secrets ()
  "Write the history file for real: the name of a secret is not in it."
  (let ((file-name-history (list "/home/u/src/main.rs" "~/.ssh/id_ed25519"
                                 "/home/u/app/.env" "/home/u/notes.txt"))
        (savehist-minibuffer-history-variables '(file-name-history)))
    (savehist-save)
    (let ((saved (with-temp-buffer
                   (insert-file-contents savehist-file)
                   (buffer-string))))
      (should (string-match-p "/home/u/src/main\\.rs" saved))
      (should (string-match-p "/home/u/notes\\.txt" saved))
      (should-not (string-match-p "id_ed25519" saved))
      (should-not (string-match-p "\\.env" saved)))))

(provide 'mega-session-test)
;;; mega-session-test.el ends here
