;;; mega-session.el --- Workspaces, history, places  -*- lexical-binding: t; -*-

;;; Commentary:

;; "Saveable workspaces" means two different things, and MEGA provides both:
;;
;; * The small kind — where you were, what you had open recently, what you
;;   typed into a prompt.  savehist/recentf/save-place, always on.
;;
;; * The large kind — a named set of windows and buffers you can put away and
;;   bring back.  `activities' (GNU ELPA, signed) over the built-in tab-bar.
;;
;; `desktop-save-mode' is deliberately NOT enabled.  Combined with tramp it
;; turns startup into a multi-second network stall while it reopens remote
;; files, which is exactly the failure mode MEGA exists to avoid.  Enable it in
;; local.el if you want it.

;;; Code:

(require 'mega-lib)

;;;; Small state

(use-package savehist
  :custom
  (savehist-file (mega-state "history"))
  (savehist-additional-variables '(search-ring regexp-search-ring kill-ring compile-history))
  (savehist-autosave-interval 60)
  :config (savehist-mode 1))

(use-package recentf
  :custom
  (recentf-save-file (mega-state "recentf"))
  (recentf-max-saved-items 300)
  (recentf-auto-cleanup 'never)          ; cleanup stats every remote file
  (recentf-exclude `(,(regexp-quote (expand-file-name mega-cache-dir))
                     ,(regexp-quote (expand-file-name mega-state-dir))
                     "/tmp/" "\\.gz\\'" "COMMIT_EDITMSG\\'" "\\`/[^/:]+:"))
  :config (recentf-mode 1))

(use-package saveplace
  :custom
  (save-place-file (mega-state "places"))
  ;; Do not stat a remote file just to remember a line number.
  (save-place-forget-unreadable-files nil)
  :config (save-place-mode 1))

(use-package winner
  :custom (winner-dont-bind-my-keys nil)
  :config (winner-mode 1))

(use-package bookmark
  :custom (bookmark-default-file (mega-state "bookmarks")))

;;;; Workspaces

(use-package tab-bar
  :custom
  (tab-bar-show 1)                       ; hide the bar until there are 2 tabs
  (tab-bar-new-tab-choice "*scratch*")
  (tab-bar-close-button-show nil)
  (tab-bar-format '(tab-bar-format-tabs tab-bar-separator))
  :config (tab-bar-history-mode 1))

(use-package activities
  :ensure t
  :commands (activities-new activities-resume activities-suspend
             activities-kill activities-switch activities-list)
  :custom
  (activities-bookmark-store t)
  :config
  (activities-mode 1)
  (activities-tabs-mode 1))

;; Thin wrappers so the C-c w keys stay stable if the underlying package is
;; ever swapped, matching how the completion and undo backends are handled.
(defun mega-workspace-new     () "Create a named workspace." (interactive) (call-interactively #'activities-new))
(defun mega-workspace-resume  () "Resume a saved workspace." (interactive) (call-interactively #'activities-resume))
(defun mega-workspace-save    () "Put the current workspace away." (interactive) (call-interactively #'activities-suspend))
(defun mega-workspace-kill    () "Discard a workspace." (interactive) (call-interactively #'activities-kill))
(defun mega-workspace-switch  () "Switch workspace." (interactive) (call-interactively #'activities-switch))
(defun mega-workspace-list    () "List workspaces." (interactive) (call-interactively #'activities-list))

(provide 'mega-session)
;;; mega-session.el ends here
