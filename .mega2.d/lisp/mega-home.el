;;; mega-home.el --- The page Emacs opens on  -*- lexical-binding: t; -*-

;;; Commentary:

;; When Emacs starts without being given a file, it shows this page instead
;; of an empty scratch buffer.  It answers "where was I?" in one screen:
;;
;;   r        continue from the session you last closed
;;   1 .. 9   open a recent project; its windows come back if it has a
;;            saved workspace, otherwise you choose a file in it
;;   f p w    open a file, a project, a saved workspace
;;   ? d      the keys, the doctor
;;   g q      refresh, leave
;;
;; RET does the same for the line the cursor is on.  The first line says how
;; long Emacs took to start.
;;
;; The page only lists.  Nothing is opened until you choose, so a remote or
;; vanished project cannot slow startup down; a project whose directory is
;; gone is simply not shown.  `M-x mega-home' brings the page back any time.

;;; Code:

(require 'mega-lib)
(require 'mega-workspace)

(declare-function project-known-project-roots "project")
(declare-function project-find-file "project")
(declare-function mega-help "mega-help")
(declare-function mega-doctor "mega-doctor")

(defcustom mega-home-at-startup t
  "Whether Emacs opens on the home page when it is given no file."
  :type 'boolean :group 'mega)

(defcustom mega-home-projects 9
  "How many recent projects the home page lists, at most 9."
  :type 'integer :group 'mega)

(defconst mega-home-buffer "*MEGA*"
  "Name of the home page buffer.")

(defface mega-home-title '((t :inherit bold))
  "The first line of the home page." :group 'mega)
(defface mega-home-heading '((t :inherit font-lock-keyword-face))
  "A section heading on the home page." :group 'mega)
(defface mega-home-key '((t :inherit help-key-binding))
  "A key on the home page." :group 'mega)
(defface mega-home-detail '((t :inherit shadow))
  "Secondary text on the home page." :group 'mega)

;;;; What the page knows

(defvar mega-home--started nil
  "When starting was over: noted once, at the end of `emacs-startup-hook'.")

(defun mega-home-startup-time ()
  "How long starting took, in milliseconds, or nil if still starting.
From Emacs opening its first init file to the end of what MEGA put off
until Emacs had started: all of what is waited for before the first key,
not only the part Emacs itself calls init."
  (when (and before-init-time mega-home--started)
    (* 1000.0 (float-time (time-subtract mega-home--started before-init-time)))))

(defun mega-home-projects ()
  "Recent projects that can be opened right now, most recent first.
A remote project is listed without being checked; a local one only if
its directory still exists."
  (let ((roots (ignore-errors
                 (require 'project)
                 (project-known-project-roots))))
    (take (min mega-home-projects 9)
          (seq-filter (lambda (root)
                        (or (file-remote-p root) (file-directory-p root)))
                      roots))))

(defun mega-home--age (time)
  "Describe how long ago TIME, a float, was."
  (let ((seconds (- (float-time) time)))
    (cond ((< seconds 90) "just now")
          ((< seconds 5400) (format "%d minutes ago" (round seconds 60)))
          ((< seconds 129600) (format "%d hours ago" (round seconds 3600)))
          (t (format "%d days ago" (round seconds 86400))))))

;;;; What choosing does

(defun mega-home-open-project (root)
  "Open the project at ROOT.
Its saved workspace is resumed if there is one; otherwise you are asked
which of its files to open."
  (let ((workspace (mega-workspace-read (abbreviate-file-name root))))
    (if (and workspace (> (mega-workspace-restore workspace) 0))
        (message "Resumed %s" (abbreviate-file-name root))
      (let ((default-directory root))
        (project-find-file)))))

(defun mega-home-continue ()
  "Continue from the session that was closed last."
  (interactive)
  (let ((workspace (mega-workspace-last)))
    (unless workspace
      (user-error "There is no earlier session to continue"))
    (when (zerop (mega-workspace-restore workspace))
      (message "None of the files of %s exist any more"
               (plist-get workspace :name)))))

(defun mega-home-open-nth (&optional n)
  "Open the Nth recent project.
Interactively, N is the digit that was typed."
  (interactive)
  (let* ((n (or n (- last-command-event ?0)))
         (root (nth (1- n) (mega-home-projects))))
    (unless root
      (user-error "There is no project %d" n))
    (mega-home-open-project root)))

(defun mega-home-act ()
  "Do what the line under the cursor offers."
  (interactive)
  (let ((action (get-text-property (line-beginning-position) 'mega-home-action)))
    (if action
        (funcall action)
      (user-error "Nothing to open on this line"))))

(defun mega-home-leave ()
  "Leave the home page."
  (interactive)
  (quit-window))

;;;; The page

(defun mega-home--line (key text detail action)
  "Insert one choice: KEY, TEXT and DETAIL, doing ACTION when chosen."
  (let ((start (point)))
    (insert "   " (propertize (format "%-3s" key) 'face 'mega-home-key) " " text)
    (when detail
      (insert "  " (propertize detail 'face 'mega-home-detail)))
    (insert "\n")
    (put-text-property start (point) 'mega-home-action action)))

(defun mega-home--insert ()
  "Insert the home page at point."
  (let ((time (mega-home-startup-time))
        (last (mega-workspace-last))
        (projects (mega-home-projects)))
    (insert " "
            (propertize (format "MEGA %s" mega-version) 'face 'mega-home-title)
            (propertize (format "  ·  Emacs %s" emacs-version) 'face 'mega-home-detail)
            (if time
                (propertize (format "  ·  started in %.0f ms" time)
                            'face 'mega-home-detail)
              "")
            "\n\n")
    (when last
      (insert " " (propertize "Continue" 'face 'mega-home-heading) "\n")
      (mega-home--line "r" (plist-get last :name)
                       (format "%d files, closed %s"
                               (length (plist-get last :files))
                               (mega-home--age (plist-get last :saved)))
                       #'mega-home-continue)
      (insert "\n"))
    (when projects
      (insert " " (propertize "Recent projects" 'face 'mega-home-heading) "\n")
      (let ((n 0))
        (dolist (root projects)
          (setq n (1+ n))
          (let ((workspace (mega-workspace-read (abbreviate-file-name root)))
                (root root))
            (mega-home--line (number-to-string n)
                             (abbreviate-file-name root)
                             (and workspace
                                  (format "%d files in its workspace"
                                          (length (plist-get workspace :files))))
                             (lambda () (mega-home-open-project root))))))
      (insert "\n"))
    (unless (or last projects)
      (insert " "
              (propertize "Nothing to continue yet: open a file with f, and it will be here next time."
                          'face 'mega-home-detail)
              "\n\n"))
    (insert " ")
    (dolist (hint '(("f" . "open file") ("p" . "open project") ("w" . "workspaces")
                    ("?" . "keys") ("d" . "doctor") ("q" . "leave")))
      (insert (propertize (car hint) 'face 'mega-home-key) " " (cdr hint) "    "))
    (insert "\n")))

(defvar mega-home-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'mega-home-act)
    (define-key map "r" #'mega-home-continue)
    (dotimes (n 9)
      (define-key map (number-to-string (1+ n)) #'mega-home-open-nth))
    (define-key map "f" #'find-file)
    (define-key map "p" #'project-switch-project)
    (define-key map "w" #'mega-workspace-resume)
    (define-key map "?" #'mega-help)
    (define-key map "d" #'mega-doctor)
    (define-key map "g" #'mega-home)
    (define-key map "q" #'mega-home-leave)
    map)
  "Keys of the home page.")

(define-derived-mode mega-home-mode special-mode "Home"
  "The page Emacs opens on.  See the Commentary of mega-home.el."
  (setq-local cursor-type nil
              truncate-lines t))

(defun mega-home-render ()
  "Create or refresh the home page buffer and return it."
  (with-current-buffer (get-buffer-create mega-home-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (unless (derived-mode-p 'mega-home-mode)
        (mega-home-mode))
      (mega-home--insert)
      (goto-char (point-min))
      ;; Start on the first thing that can be chosen.
      (when-let* ((first (text-property-not-all (point-min) (point-max)
                                                'mega-home-action nil)))
        (goto-char first)))
    (current-buffer)))

;;;###autoload
(defun mega-home ()
  "Show the home page."
  (interactive)
  (switch-to-buffer (mega-home-render)))

;;;; At startup

(defun mega-home--wanted-p ()
  "Non-nil if this session should open on the home page.
That is: it is interactive, and Emacs was not asked to show anything —
no file, no directory, no buffer of its own choosing."
  (and mega-home-at-startup
       (not noninteractive)
       (not (daemonp))
       (not initial-buffer-choice)
       (one-window-p t)
       (equal (buffer-name (window-buffer)) "*scratch*")
       (not (seq-some (lambda (buffer)
                        (or (buffer-file-name buffer)
                            (with-current-buffer buffer
                              (derived-mode-p 'dired-mode))))
                      (buffer-list)))))

(defun mega-home-at-startup ()
  "Open on the home page, unless Emacs was started on something else."
  (setq mega-home--started (current-time))
  (when (mega-home--wanted-p)
    (mega-home)))

;; Depth 95: after MEGA's own startup work, so the page reports the real time.
(add-hook 'emacs-startup-hook #'mega-home-at-startup 95)

(provide 'mega-home)
;;; mega-home.el ends here
