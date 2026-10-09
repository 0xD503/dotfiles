;;; mega-session.el --- History, recent files, places  -*- lexical-binding: t; -*-

;;; Commentary:

;; What Emacs remembers between sessions: what you typed into prompts, which
;; files you had open, and where the cursor was in each.
;;
;; Remembering is a privacy decision, so the rules are explicit:
;;
;; * Everything is stored in MEGA's state directory, which only you can read.
;;
;; * The kill ring is never saved.  It holds whatever you last copied, which
;;   sooner or later is a password.
;;
;; * A file `mega-private-file-p' recognises is not listed as recent and its
;;   cursor position is not recorded: for a secret, even the name and the
;;   fact that you opened it are worth not writing down.
;;
;; Named, saveable workspaces are a later module; `desktop-save-mode' is
;; deliberately not used, because reopening remote files at startup turns it
;; into a network stall.

;;; Code:

(require 'mega-lib)

(defvar savehist-file)
(defvar savehist-additional-variables)
(defvar savehist-autosave-interval)
(defvar recentf-save-file)
(defvar recentf-max-saved-items)
(defvar recentf-auto-cleanup)
(defvar recentf-exclude)
(defvar save-place-file)
(defvar save-place-forget-unreadable-files)
(defvar save-place-ignore-files-regexp)
(defvar bookmark-default-file)
(defvar project-list-file)
(declare-function recentf-track-opened-file "recentf")

(defun mega-session--private-regexp ()
  "One regexp matching every file `mega-private-file-p' recognises."
  (mapconcat (lambda (regexp) (concat "\\(?:" regexp "\\)"))
             mega-private-file-regexps "\\|"))

;;;; Prompt history

(setq savehist-file (mega-state "history")
      ;; Searches are worth keeping.  The kill ring is not: see above.
      savehist-additional-variables '(search-ring regexp-search-ring)
      savehist-autosave-interval 60)
(savehist-mode 1)

;;;; Recent files

(setq recentf-save-file (mega-state "recentf")
      recentf-max-saved-items 300
      ;; The automatic cleanup stats every file, which hangs on a remote one.
      recentf-auto-cleanup 'never
      recentf-exclude (list #'mega-private-file-p
                            (regexp-quote (expand-file-name mega-cache-dir))
                            (regexp-quote (expand-file-name mega-state-dir))
                            "\\`/tmp/" "\\`/var/tmp/"
                            "COMMIT_EDITMSG\\'" "git-rebase-todo\\'"
                            ;; Remote files: listing them is harmless, but
                            ;; checking that they still exist is a round trip.
                            "\\`/[^/:]+:"))
(defun mega-session--start-recent-files ()
  "Start keeping the list of recent files, including the ones already open."
  ;; Reading the list back announces itself in the echo area.
  (let ((inhibit-message t))
    (recentf-mode 1))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when buffer-file-name
        (recentf-track-opened-file)))))

(mega-after-startup #'mega-session--start-recent-files)

;;;; Cursor places

(setq save-place-file (mega-state "places")
      ;; Do not stat a remote file just to remember a line number.
      save-place-forget-unreadable-files nil)
(with-eval-after-load 'saveplace
  (setq save-place-ignore-files-regexp
        (concat save-place-ignore-files-regexp
                "\\|" (mega-session--private-regexp))))
(save-place-mode 1)

;;;; Bookmarks, projects, window layouts

(setq bookmark-default-file (mega-state "bookmarks")
      project-list-file (mega-state "projects"))

;; `C-c <left>' and `C-c <right>' step back and forth through window layouts.
(mega-after-startup #'winner-mode)

(provide 'mega-session)
;;; mega-session.el ends here
