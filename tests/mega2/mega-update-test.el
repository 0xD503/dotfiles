;;; mega-update-test.el --- What an update of MEGA finds in its state  -*- lexical-binding: t; -*-

;;; Commentary:

;; MEGA is updated by replacing its files; what it remembers stays where it
;; was, written by whatever version was running before.  The promise to
;; whoever updates is that this cannot hurt: a file MEGA cannot make sense
;; of, because another version wrote it or because it is damaged, is not
;; guessed at.  It is ignored, which costs a question asked again or a
;; history forgotten, and never an error at start or a file of yours.
;;
;; So each store is given two things to read: bytes that are no Lisp at
;; all, and Lisp of a shape no version has written yet.

;;; Code:

(require 'mega-test-helper)
(require 'mega-trust)
(require 'mega-workspace)
(require 'mega-home)
(require 'mega-undo)
(require 'mega-container)
(require 'mega-lang)

(defconst mega-update-test--strange
  '("\0\377 not lisp ((( \n"
    "(:format 99 :entries [(\"a\" . #s(thing 1))] :note \"from a version to come\")\n"
    "")
  "What a store may hold that this version did not write.")

(defun mega-update-test--put (file content)
  "Make FILE hold CONTENT, byte for byte: some of it is no text at all."
  (let ((coding-system-for-write 'no-conversion))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert content))))

(ert-deftest mega-update-a-trust-store-of-another-version-means-untrusted ()
  "The safe way round: what cannot be read allows nothing."
  (mega-test-with-directory dir
    (dolist (content mega-update-test--strange)
      (let ((mega-trust-file (expand-file-name "trusted.eld" dir))
            (mega-trust--decisions 'unread)
            (mega-trust--stamp nil)
            (inhibit-message t))
        (mega-update-test--put mega-trust-file content)
        (should-not (mega-trust-p dir))
        (should-not (mega-trust-decision dir))
        ;; And deciding still works, and leaves a store this version reads.
        (let ((default-directory dir))
          (mega-trust-project))
        (setq mega-trust--decisions 'unread)
        (should (mega-trust-p dir))))))

(ert-deftest mega-update-workspaces-of-another-version-are-passed-over ()
  (mega-test-with-directory dir
    (let ((mega-workspace-directory dir)
          (inhibit-message t)
          (index 0))
      (dolist (content mega-update-test--strange)
        (mega-update-test--put
         (expand-file-name (format "w%d.eld" (setq index (1+ index))) dir)
         content))
      (should-not (mega-workspace-all))
      (should-not (mega-workspace-last))
      (should-not (mega-workspace-read "w1"))
      ;; The page Emacs opens on is drawn regardless.
      (let ((buffer (mega-home-render)))
        (should (buffer-live-p buffer))
        (kill-buffer buffer))
      ;; One that this version wrote, among them, is still found.
      (mega-workspace-write '(:name "mine" :saved 1.0 :files (("/a" 1))))
      (should (equal (mapcar (lambda (workspace) (plist-get workspace :name))
                             (mega-workspace-all))
                     '("mine"))))))

(ert-deftest mega-update-an-undo-history-of-another-version-is-not-applied ()
  "Applied to the text, records of another shape would scramble it."
  (mega-test-with-directory dir
    (let ((file (expand-file-name "notes.txt" dir))
          (mega-undo-persist t)
          (inhibit-message t)
          ;; As in the Emacs you use: a failure in here is a message.
          (debug-on-error nil))
      (mega-test-write file "one" "")
      (mega-test-visiting buffer file
        (goto-char (point-max))
        (insert "two\n")
        (undo-boundary)
        (save-buffer))
      (let ((stored (mega-undo--file file)))
        (should (file-exists-p stored))
        (dolist (content (append mega-update-test--strange
                                 ;; The right text, and a format this version
                                 ;; does not know.
                                 (list (format "%S\n((1 . 4))\n"
                                               (cons 'mega-undo
                                                     (cons 2 (with-temp-buffer
                                                               (insert-file-contents file)
                                                               (mega-undo--fingerprint))))))))
          (mega-update-test--put stored content)
          (mega-test-visiting buffer file
            (should (equal (buffer-string) "one\ntwo\n"))
            (should-not buffer-undo-list)
            (should-not (buffer-modified-p))))))))

(ert-deftest mega-update-approvals-and-refusals-of-another-version-are-asked-again ()
  (mega-test-with-directory dir
    (dolist (content mega-update-test--strange)
      (let ((mega-container-approved-file (expand-file-name "approved.eld" dir))
            (mega-lang-declined-file (expand-file-name "declined.eld" dir))
            (mega-lang--declined 'unread))
        (mega-update-test--put mega-container-approved-file content)
        (mega-update-test--put mega-lang-declined-file content)
        ;; Nothing is taken as approved, nothing as refused.
        (should-not (mega-container--approved))
        (should-not (mega-lang--declined))))))

(provide 'mega-update-test)
;;; mega-update-test.el ends here
