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
;; * A file `mega-forgettable-file-p' recognises is not listed as recent, its
;;   cursor position is not recorded, and its name is dropped from the
;;   history of file prompts: for a secret, even the name and the fact that
;;   you opened it are worth not writing down.  That one function is asked
;;   by everything in MEGA that remembers something about a file.
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
(defvar bookmark-default-file)
(defvar project-list-file)
(declare-function recentf-track-opened-file "recentf")

;;;; Prompt history

(defun mega-session--forget-names ()
  "Drop from the history of file names those of files not to be remembered.
A name typed at a prompt is kept by Emacs like any other answer; the
name of a secret is not worth keeping, and says that the secret exists."
  (setq file-name-history
        (seq-remove (lambda (name)
                      (and (stringp name) (mega-forgettable-file-p name)))
                    file-name-history)))

(setq savehist-file (mega-state "history")
      ;; Searches are worth keeping.  The kill ring is not: see above.
      savehist-additional-variables '(search-ring regexp-search-ring)
      savehist-autosave-interval 60)
(add-hook 'savehist-save-hook #'mega-session--forget-names)
(savehist-mode 1)

;;;; Recent files

(setq recentf-save-file (mega-state "recentf")
      recentf-max-saved-items 300
      ;; The automatic cleanup stats every file, which hangs on a remote one.
      recentf-auto-cleanup 'never
      recentf-exclude (list #'mega-forgettable-file-p
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

(defun mega-session--place-wanted-p ()
  "Non-nil if the cursor position of the current buffer may be remembered."
  (not (and buffer-file-name (mega-forgettable-file-p buffer-file-name))))

;; Asked each time a position is about to be noted, so that the answer is
;; the rule's answer now and not a list made when Emacs started.
(advice-add 'save-place-to-alist :before-while #'mega-session--place-wanted-p)
(save-place-mode 1)

;;;; Bookmarks, projects, window layouts

(setq bookmark-default-file (mega-state "bookmarks")
      project-list-file (mega-state "projects"))

;; `C-c <left>' and `C-c <right>' step back and forth through window layouts.
(mega-after-startup #'winner-mode)

(provide 'mega-session)
;;; mega-session.el ends here
