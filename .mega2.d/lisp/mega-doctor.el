;;; mega-doctor.el --- What is actually working on this machine  -*- lexical-binding: t; -*-

;;; Commentary:

;; `M-x mega-doctor' answers the question a configuration normally leaves you
;; guessing about: which of this is really running?  A feature that is
;; configured but missing its program does nothing, silently; this buffer
;; says so.
;;
;; It reports.  It never installs, never connects, and runs no program.
;;
;; The report is a list of sections.  The ones below describe Emacs and MEGA
;; itself; a feature module adds its own by putting a function on
;; `mega-doctor-sections' (defined in mega-lib.el, so that doing so does not
;; load this file).

;;; Code:

(require 'mega-lib)

(defvar package-archives)
(defvar package--initialized)

(defconst mega-doctor-tools '("git" "rg" "fd" "fdfind" "cc")
  "Optional programs the base reports on.  Feature modules report their own.")

(defun mega-doctor-heading (text)
  "Insert TEXT as a section heading."
  (insert (propertize (concat "\n" text "\n") 'face 'bold)))

(defun mega-doctor-row (label value &optional face)
  "Insert one row: LABEL, then VALUE, optionally in FACE."
  (insert (format "  %-28s %s\n" label
                  (if face (propertize value 'face face) value))))

(defun mega-doctor-check (label ok good bad)
  "Insert a row for LABEL saying GOOD if OK is non-nil, else BAD.
Returns OK, so callers can count problems."
  (mega-doctor-row label (if ok good bad) (if ok 'success 'error))
  ok)

(defun mega-doctor--private-p (dir)
  "Non-nil if DIR exists and only its owner can enter it."
  (and (file-directory-p dir)
       (= (logand (file-modes dir) #o077) 0)))

(defun mega-doctor--inside-config-p (path)
  "Non-nil if PATH lies inside MEGA's read-only configuration directory."
  (and (stringp path)
       (file-in-directory-p (expand-file-name path) mega-dir)))

;;;; Sections

(defun mega-doctor--emacs ()
  "Insert the section about Emacs itself."
  (mega-doctor-heading "Emacs")
  (mega-doctor-row "version" emacs-version)
  (mega-doctor-row "MEGA" mega-version)
  (mega-doctor-check "native compilation"
                     (and (fboundp 'native-comp-available-p)
                          (native-comp-available-p))
                     "yes" "no")
  (mega-doctor-check "tree-sitter"
                     (and (fboundp 'treesit-available-p) (treesit-available-p))
                     "yes" "no")
  (mega-doctor-row "display"
                   (format "%s, %s colours"
                           (if (display-graphic-p) "GUI" "terminal")
                           (display-color-cells)))
  (unless (display-graphic-p)
    (mega-doctor-check "popups in the terminal"
                       (featurep 'tty-child-frames)
                       "yes (child frames)" "no: popups fall back to the echo area")
    (when (< (display-color-cells) 256)
      (mega-doctor-row "" "The theme needs 256 colours; 24-bit is best:" 'warning)
      (mega-doctor-row "" "set COLORTERM=truecolor in the terminal" 'warning))))

(defun mega-doctor--startup ()
  "Insert the section about startup."
  (mega-doctor-heading "Startup")
  (mega-doctor-row "init time" (emacs-init-time))
  (mega-doctor-row "garbage collections" (format "%d in %.2fs" gcs-done gc-elapsed))
  (insert "\n  Loaded at startup (slowest first):\n")
  (dolist (entry (sort (copy-sequence mega-module-times)
                       (lambda (a b) (> (cdr a) (cdr b)))))
    (insert (format "    %-24s %6.1f ms\n" (car entry) (cdr entry))))
  (when mega-lazy-modules
    (insert "\n  Loaded on first use:\n")
    (dolist (entry (reverse mega-lazy-modules))
      (insert (format "    %-24s %s\n" (car entry)
                      (if (featurep (car entry)) "loaded" "not yet")))))
  (when mega-module-failures
    (insert (propertize "\n  Modules that FAILED to load:\n" 'face 'error))
    (dolist (failure (reverse mega-module-failures))
      (insert (format "    %-24s %s\n" (car failure) (cdr failure))))))

(defun mega-doctor--safety ()
  "Insert the section checking the safety, privacy and security settings.
Every row is read from the running Emacs, not asserted."
  (mega-doctor-heading "Safety, privacy, security")
  (mega-doctor-check "backups" (and make-backup-files
                                    (not (mega-doctor--inside-config-p
                                          (cdr (assoc "." backup-directory-alist)))))
                     "on, outside project trees" "OFF or misplaced")
  (mega-doctor-check "auto-save" auto-save-default "on" "OFF")
  (mega-doctor-check "deleting files" delete-by-moving-to-trash
                     "moves them to the trash" "is permanent")
  (dolist (dir (list mega-state-dir mega-cache-dir mega-data-dir))
    (mega-doctor-check (abbreviate-file-name dir) (mega-doctor--private-p dir)
                       "private" "readable by others: chmod 700 it"))
  (mega-doctor-check "configuration directory"
                     (not (mega-doctor--inside-config-p user-emacs-directory))
                     "read-only: Emacs writes elsewhere"
                     "Emacs may write into it")
  (mega-doctor-check "packages"
                     (and (null package-archives)
                          (not (bound-and-true-p package--initialized)))
                     "none: package.el is off and has no archives"
                     "package.el is active")
  (mega-doctor-check "file-local variables"
                     (and (eq enable-local-variables :safe)
                          (not enable-local-eval))
                     "safe ones only, no eval" "UNSAFE ones are allowed")
  (mega-doctor-check "kill ring"
                     (not (memq 'kill-ring
                                (bound-and-true-p savehist-additional-variables)))
                     "not saved to disk" "SAVED to disk"))

(defun mega-doctor--tools ()
  "Insert the section listing optional programs."
  (mega-doctor-heading "Optional programs")
  (dolist (tool mega-doctor-tools)
    (let ((path (mega-exe-p tool)))
      (mega-doctor-row tool (or path "not found") (unless path 'shadow))))
  (insert "\n  None of these is required; a feature that wants one says so.\n"))

;;;; The command

(defun mega-doctor--insert ()
  "Insert the whole report at point."
  (insert (propertize "MEGA doctor\n" 'face '(bold underline)))
  (dolist (section (append '(mega-doctor--emacs mega-doctor--startup
                             mega-doctor--safety mega-doctor--tools)
                           mega-doctor-sections))
    ;; A section that breaks must not take the rest of the report with it:
    ;; the moment you most need the doctor is when something is broken.
    (condition-case err
        (funcall section)
      (error
       (mega-doctor-row (format "%s" section)
                        (format "could not report: %s" (error-message-string err))
                        'error)))))

;;;###autoload
(defun mega-doctor ()
  "Report what MEGA found on this machine, and what is missing."
  (interactive)
  (with-current-buffer (get-buffer-create "*mega-doctor*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (special-mode)
      (mega-doctor--insert)
      (goto-char (point-min))))
  (pop-to-buffer "*mega-doctor*"))

(provide 'mega-doctor)
;;; mega-doctor.el ends here
