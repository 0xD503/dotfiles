;;; mega-trust.el --- Which projects may run their own code  -*- lexical-binding: t; -*-

;;; Commentary:

;; Editing a file runs nothing.  The tools around editing do: a language
;; server builds the project to understand it, which for Rust means running
;; its build scripts and macros; a formatter or a task runner may load
;; plugins and configuration that are programs.  All of that is code from
;; the project, running as you.
;;
;; So MEGA asks, once per project, before the first of those tools would
;; start, and remembers the answer.  In a project you have not trusted MEGA
;; is a text editor: no language server, no formatting on save, no tasks.
;;
;;   M-x mega-trust-project      trust the project of this buffer
;;   M-x mega-distrust-project   take that back
;;
;; The answers are kept in MEGA's state directory, as data.  A script is
;; never asked and never trusted: in a batch Emacs an undecided project
;; counts as untrusted.

;;; Code:

(require 'mega-lib)

(declare-function mega-project-root "mega-project")

(defconst mega-trust-file (mega-state "trusted-projects.eld")
  "Where the decisions are kept: an alist of (ROOT . TRUSTED).")

(defvar mega-trust--decisions 'unread
  "Alist of (ROOT . TRUSTED), or `unread' before the file is read.")

(defun mega-trust--decisions ()
  "The recorded decisions."
  (when (eq mega-trust--decisions 'unread)
    (setq mega-trust--decisions
          (ignore-errors
            (with-temp-buffer
              (insert-file-contents mega-trust-file)
              (let ((data (read (current-buffer))))
                (and (listp data)
                     (seq-every-p (lambda (entry)
                                    (and (consp entry) (stringp (car entry))
                                         (booleanp (cdr entry))))
                                  data)
                     data))))))
  mega-trust--decisions)

(defun mega-trust--record (root trusted)
  "Record that ROOT is TRUSTED, or not."
  (setf (alist-get root mega-trust--decisions nil nil #'equal) trusted)
  (let ((print-length nil) (print-level nil))
    (with-temp-file mega-trust-file
      (insert ";; Projects MEGA may run tools in.  Data: read, never evaluated.\n")
      (prin1 (mega-trust--decisions) (current-buffer))
      (insert "\n"))))

(defun mega-trust-root (&optional directory)
  "The directory a trust decision for DIRECTORY applies to.
It is the root of the project, or DIRECTORY itself outside any project."
  (let ((directory (expand-file-name (or directory default-directory))))
    (abbreviate-file-name
     (file-name-as-directory (or (mega-project-root directory) directory)))))

(defun mega-trust-decision (&optional directory)
  "What was decided about DIRECTORY's project: `trusted', `untrusted' or nil."
  (let ((entry (assoc (mega-trust-root directory) (mega-trust--decisions))))
    (cond ((null entry) nil)
          ((cdr entry) 'trusted)
          (t 'untrusted))))

(defun mega-trust-p (&optional directory ask why)
  "Non-nil if the project of DIRECTORY may run its own tools.
An undecided project is not trusted.  With ASK non-nil the user is asked
first, unless this is a batch Emacs; WHY, a short phrase such as \"start
its language server\", says what the answer allows right now."
  (pcase (mega-trust-decision directory)
    ('trusted t)
    ('untrusted nil)
    (_ (and ask
            (not noninteractive)
            (let* ((root (mega-trust-root directory))
                   (answer (y-or-n-p
                            (format "Trust %s?  MEGA wants to %s, which can run code from it. "
                                    root (or why "run its tools")))))
              (mega-trust--record root answer)
              answer)))))

;;;###autoload
(defun mega-trust-project ()
  "Let MEGA run tools in the project of this buffer."
  (interactive)
  (let ((root (mega-trust-root)))
    (mega-trust--record root t)
    (message "Trusted %s" root)))

;;;###autoload
(defun mega-distrust-project ()
  "Stop MEGA from running tools in the project of this buffer.
Tools that are already running are not stopped."
  (interactive)
  (let ((root (mega-trust-root)))
    (mega-trust--record root nil)
    (message "No longer trusting %s" root)))

(provide 'mega-trust)
;;; mega-trust.el ends here
