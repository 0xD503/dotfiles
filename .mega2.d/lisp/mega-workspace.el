;;; mega-workspace.el --- Put a set of files and windows away, bring it back  -*- lexical-binding: t; -*-

;;; Commentary:

;; A workspace is which files were open, where the cursor was in each, and
;; how the windows were arranged.  Nothing else: no file contents, no shell
;; history, no processes.
;;
;; Two kinds are kept, in MEGA's state directory:
;;
;; * Automatic.  When Emacs exits, the session is saved under the project it
;;   was in.  That is what the home page offers as "continue", and what makes
;;   reopening a recent project bring its windows back.
;;
;; * Named.  `C-c w s' saves the current tab under a name you choose, and
;;   `C-c w r' brings one back.
;;
;;   C-c w s   save          C-c w r   resume a saved one
;;   C-c w n   new tab       C-c w w   switch tab        C-c w k   forget one
;;
;; Three rules, in MEGA's order of priorities:
;;
;; * Resuming never closes anything.  It opens files and arranges windows; in
;;   a session that already has work on screen it does so in a new tab.
;;
;; * A file `mega-private-file-p' recognises is never recorded, and neither
;;   is a remote one: resuming must not open a network connection.
;;
;; * A workspace file is data.  It is read, never evaluated.
;;
;; `desktop-save-mode' is not used: it restores everything at startup, remote
;; files included, which is the stall this module exists to avoid.

;;; Code:

(require 'mega-lib)

(declare-function mega-project-root "mega-project")

(defcustom mega-workspace-save-on-exit t
  "Whether leaving Emacs saves the session as an automatic workspace."
  :type 'boolean :group 'mega)

(defcustom mega-workspace-keep-automatic 20
  "How many automatic workspaces to keep; the oldest go first."
  :type 'integer :group 'mega)

(defconst mega-workspace-directory (mega-state "workspaces/")
  "Where workspaces are stored, one file each.")

;;;; What a workspace records

(defun mega-workspace--recordable-p (file)
  "Non-nil if FILE may be recorded in a workspace."
  (and file
       (not (file-remote-p file))
       (not (mega-private-file-p file))
       (not (string-match-p "\\(?:COMMIT_EDITMSG\\|git-rebase-todo\\)\\'" file))
       (not (file-in-directory-p file temporary-file-directory))))

(defun mega-workspace--buffers ()
  "The buffers a workspace records, most recently used first."
  (seq-filter (lambda (buffer)
                (mega-workspace--recordable-p (buffer-file-name buffer)))
              (buffer-list)))

(defun mega-workspace-key ()
  "The name the current session is saved under automatically.
It is the root of the project of the most recently used file, or that
file's directory when it is in no project."
  (when-let* ((buffer (car (mega-workspace--buffers))))
    (with-current-buffer buffer
      (abbreviate-file-name
       (or (mega-project-root) (file-name-directory buffer-file-name))))))

(defun mega-workspace-capture (name &optional automatic)
  "Return the current session as a workspace called NAME, or nil.
Nil means there is nothing worth recording: no file is open.  AUTOMATIC
marks it as saved by Emacs, not by you."
  (when-let* ((buffers (mega-workspace--buffers)))
    (list :name name
          :automatic (and automatic t)
          :saved (float-time)
          :files (mapcar (lambda (buffer)
                           (with-current-buffer buffer
                             (list buffer-file-name (point))))
                         buffers)
          ;; The window layout names buffers; these are the files behind the
          ;; names, since the same file may get another name next time.
          :buffers (mapcar (lambda (buffer)
                             (cons (buffer-name buffer) (buffer-file-name buffer)))
                           buffers)
          :windows (window-state-get (frame-root-window) t))))

;;;; Storing

(defun mega-workspace--file (name)
  "The file that stores the workspace called NAME.
Anything but letters, digits, dot, dash and underscore is written as
%XX, so that a name can be a path, or anything else, safely."
  (expand-file-name
   (concat (replace-regexp-in-string
            "[^[:alnum:]._-]"
            (lambda (char)
              (mapconcat (lambda (byte) (format "%%%02X" byte))
                         (encode-coding-string char 'utf-8) ""))
            name t t)
           ".eld")
   mega-workspace-directory))

(defun mega-workspace-write (workspace)
  "Store WORKSPACE and return it."
  (let ((print-length nil) (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file (mega-workspace--file (plist-get workspace :name))
      (insert ";; A MEGA workspace.  Data only: this file is read, never evaluated.\n")
      (prin1 workspace (current-buffer))
      (insert "\n")))
  workspace)

(defun mega-workspace--valid-p (workspace)
  "Non-nil if WORKSPACE has the shape `mega-workspace-capture' produces."
  (and (plistp workspace)
       (stringp (plist-get workspace :name))
       (numberp (plist-get workspace :saved))
       (listp (plist-get workspace :files))
       (seq-every-p (lambda (entry)
                      (and (consp entry) (stringp (car entry))
                           (integerp (car-safe (cdr entry)))))
                    (plist-get workspace :files))))

(defun mega-workspace--read-file (file)
  "Return the workspace stored in FILE, or nil if it is not a valid one."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (let ((workspace (read (current-buffer))))
        (and (mega-workspace--valid-p workspace) workspace)))))

(defun mega-workspace-read (name)
  "Return the stored workspace called NAME, or nil."
  (let ((file (mega-workspace--file name)))
    (and (file-readable-p file) (mega-workspace--read-file file))))

(defun mega-workspace-all ()
  "Every stored workspace, newest first."
  (sort (delq nil (mapcar #'mega-workspace--read-file
                          (directory-files mega-workspace-directory t "\\.eld\\'")))
        (lambda (a b) (> (plist-get a :saved) (plist-get b :saved)))))

(defun mega-workspace-last ()
  "The most recently saved automatic workspace, or nil."
  (seq-find (lambda (workspace) (plist-get workspace :automatic))
            (mega-workspace-all)))

(defun mega-workspace-delete (name)
  "Forget the stored workspace called NAME."
  (let ((file (mega-workspace--file name)))
    (when (file-exists-p file)
      (delete-file file))))

(defun mega-workspace--prune ()
  "Drop the oldest automatic workspaces beyond `mega-workspace-keep-automatic'."
  (let ((automatic (seq-filter (lambda (workspace) (plist-get workspace :automatic))
                               (mega-workspace-all))))
    (dolist (workspace (nthcdr mega-workspace-keep-automatic automatic))
      (mega-workspace-delete (plist-get workspace :name)))))

;;;; Bringing one back

(defun mega-workspace--rename-buffers (state names)
  "Return window STATE with buffer names replaced according to NAMES.
NAMES is an alist of (SAVED-NAME . CURRENT-NAME).  A saved name that is
not in it is replaced by one no buffer has, so that its window is
dropped instead of showing whatever happens to carry that name now."
  (cond ((and (consp state) (eq (car state) 'buffer)
              (stringp (car-safe (cdr state))))
         (cons 'buffer
               (cons (or (cdr (assoc (cadr state) names))
                         (concat " mega-workspace-gone: " (cadr state)))
                     (cddr state))))
        ((consp state)
         (cons (mega-workspace--rename-buffers (car state) names)
               (mega-workspace--rename-buffers (cdr state) names)))
        (t state)))

(defun mega-workspace--fresh-session-p ()
  "Non-nil if this frame shows nothing that resuming could get in the way of."
  (and (one-window-p t)
       (null (cdr (funcall tab-bar-tabs-function)))
       (not (buffer-file-name (window-buffer)))))

(defun mega-workspace-restore (workspace)
  "Open the files of WORKSPACE and arrange its windows.
Files that no longer exist are skipped.  Returns the number of files
opened.  Nothing is closed: unless the frame is still empty, the
workspace gets a tab of its own."
  (let ((names nil) (opened 0) (first nil))
    (dolist (entry (plist-get workspace :files))
      (let ((file (car entry)))
        (when (and (mega-workspace--recordable-p file) (file-readable-p file))
          (let ((buffer (find-file-noselect file)))
            (with-current-buffer buffer
              (goto-char (min (max (cadr entry) (point-min)) (point-max))))
            (setq opened (1+ opened)
                  first (or first buffer))
            (when-let* ((saved (car (rassoc file (plist-get workspace :buffers)))))
              (push (cons saved (buffer-name buffer)) names))))))
    (when first
      (unless (mega-workspace--fresh-session-p)
        (tab-bar-new-tab))
      (tab-bar-rename-tab (plist-get workspace :name))
      (delete-other-windows)
      (switch-to-buffer first)
      ;; The layout is a convenience.  If it cannot be applied — a frame too
      ;; small for it, a state from another Emacs — the files are still open.
      (ignore-errors
        (window-state-put (mega-workspace--rename-buffers
                           (plist-get workspace :windows) names)
                          (frame-root-window) 'safe)))
    opened))

;;;; Saving on exit

(defun mega-workspace-save-session ()
  "Save the session as the automatic workspace of its project.
Returns the workspace, or nil if no file was open."
  (when-let* ((key (mega-workspace-key))
              (workspace (mega-workspace-capture key t)))
    (mega-workspace-write workspace)
    (mega-workspace--prune)
    workspace))

(defun mega-workspace--on-exit ()
  "Save the session when Emacs exits.  Never stands in the way of exiting."
  (when (and mega-workspace-save-on-exit (not noninteractive))
    (ignore-errors (mega-workspace-save-session))))

(add-hook 'kill-emacs-hook #'mega-workspace--on-exit)

;;;; Tabs

(setq tab-bar-show 1                       ; no bar until there are two tabs
      tab-bar-new-tab-choice "*scratch*"
      tab-bar-close-button-show nil
      ;; The tabs and nothing else: no buttons to click in a terminal.
      tab-bar-format '(tab-bar-format-tabs tab-bar-separator))

;;;; Commands

(defun mega-workspace--read-name (prompt)
  "Read the name of a stored workspace with PROMPT."
  (let ((names (mapcar (lambda (workspace) (plist-get workspace :name))
                       (mega-workspace-all))))
    (unless names
      (user-error "No workspace has been saved yet"))
    (completing-read prompt names nil t)))

;;;###autoload
(defun mega-workspace-save (name)
  "Save the files and windows on screen as the workspace called NAME."
  (interactive
   (list (read-string "Save workspace as: "
                      (alist-get 'name (assq 'current-tab
                                             (funcall tab-bar-tabs-function))))))
  (let ((workspace (mega-workspace-capture name)))
    (unless workspace
      (user-error "No file is open, so there is nothing to save"))
    (mega-workspace-write workspace)
    (tab-bar-rename-tab name)
    (message "Saved workspace %s (%d files)" name
             (length (plist-get workspace :files)))))

;;;###autoload
(defun mega-workspace-resume (name)
  "Bring back the stored workspace called NAME."
  (interactive (list (mega-workspace--read-name "Resume workspace: ")))
  (let ((workspace (mega-workspace-read name)))
    (unless workspace
      (user-error "No workspace called %s" name))
    (let ((opened (mega-workspace-restore workspace)))
      (if (zerop opened)
          (message "None of the files of %s exist any more" name)
        (message "Resumed %s (%d files)" name opened)))))

;;;###autoload
(defun mega-workspace-new (name)
  "Open an empty tab called NAME."
  (interactive "sNew workspace: ")
  (tab-bar-new-tab)
  (tab-bar-rename-tab name))

;;;###autoload
(defun mega-workspace-forget (name)
  "Forget the stored workspace called NAME.  Open files are not touched."
  (interactive (list (mega-workspace--read-name "Forget workspace: ")))
  (when (yes-or-no-p (format "Forget the saved workspace %s? " name))
    (mega-workspace-delete name)
    (message "Forgot workspace %s" name)))

(provide 'mega-workspace)
;;; mega-workspace.el ends here
