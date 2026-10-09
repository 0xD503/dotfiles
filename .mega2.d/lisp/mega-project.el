;;; mega-project.el --- Projects, their files, the file tree  -*- lexical-binding: t; -*-

;;; Commentary:

;; A project is what Emacs's own project.el says it is: normally a version
;; control checkout.  MEGA adds nothing to that definition.
;;
;; `C-c p' is project.el's whole command map.  The ones used most:
;;
;;   C-c p f   open a file in the project, matching fuzzily
;;             (`C-u C-c p f' also offers ignored files)
;;   C-c p p   switch to another project
;;   C-c p b   switch to a buffer of the project
;;   C-c p g   search the project into a results buffer
;;   C-c p c   compile        C-c p s   shell       C-c p k   close its buffers
;;
;; `C-c t' toggles a file tree in a side window.
;;
;; MEGA remembers a project when you open a file in it, so the list of recent
;; projects fills itself in.  Remote and private locations are not remembered.

;;; Code:

(require 'mega-lib)

(declare-function project-root "project")
(declare-function project-remember-project "project")
(declare-function speedbar-window-mode "speedbar")

(defvar project-vc-include-untracked)
(defvar project-vc-merge-submodules)
(defvar project-kill-buffers-display-buffer-list)
(defvar speedbar-prefer-window)
(defvar speedbar-window-default-width)
(defvar speedbar-show-unknown-files)
(defvar speedbar-use-images)
(defvar speedbar-directory-unshown-regexp)
(defvar imenu-flatten)
(defvar imenu-auto-rescan)

(setq project-vc-include-untracked t
      ;; Say which buffers are about to be closed before closing them.
      project-kill-buffers-display-buffer-list t
      imenu-flatten 'prefix
      imenu-auto-rescan t)

;; `C-c p' is bound to this name.  A key can only be a prefix through a symbol
;; if the symbol's function is the keymap, and Emacs's own map is a variable.
(defalias 'mega-project-map project-prefix-map)

(defun mega-project-root (&optional directory)
  "Return the root of the project containing DIRECTORY, or nil.
DIRECTORY defaults to `default-directory'.  Never prompts."
  (let ((default-directory (or directory default-directory)))
    (when-let* ((project (ignore-errors (project-current nil))))
      (expand-file-name (project-root project)))))

;;;; Remembering projects

(defun mega-project--rememberable-p (root)
  "Non-nil if the project at ROOT may be listed among recent projects."
  (not (or (file-remote-p root)
           (mega-private-file-p root)
           (file-in-directory-p root temporary-file-directory))))

(defun mega-project-remember ()
  "Remember the project of the file this buffer visits.
Runs when a file is opened.  It only reads the project list when the
project is not already at the front of it."
  (when (and buffer-file-name (not (file-remote-p buffer-file-name)))
    (when-let* ((project (ignore-errors (project-current nil)))
                ((mega-project--rememberable-p (project-root project))))
      (project-remember-project project))))

(add-hook 'find-file-hook #'mega-project-remember)

;;;; The file tree
;;
;; Emacs 31 can show Speedbar in a side window of the current frame, which is
;; what makes it usable in a terminal.

(setq speedbar-prefer-window t
      speedbar-window-default-width 32
      speedbar-show-unknown-files t
      speedbar-use-images nil
      ;; Show dotfiles: in a repository they are half of what matters.
      speedbar-directory-unshown-regexp "^\\(\\.git\\|\\.\\.?\\)\\'")

;;;###autoload
(defun mega-project-tree ()
  "Show or hide the file tree."
  (interactive)
  (require 'speedbar)
  ;; No argument toggles; this is a plain function, not a minor mode.
  (speedbar-window-mode))

(provide 'mega-project)
;;; mega-project.el ends here
