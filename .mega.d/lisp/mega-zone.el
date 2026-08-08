;;; mega-zone.el --- Idle screensaver, on a settable timeout  -*- lexical-binding: t; -*-

;;; Commentary:

;; `zone' ships with Emacs.  All MEGA adds is a timeout you can set, and the
;; restraint not to scramble a buffer while you have unsaved work or a process
;; running — zone rewrites the visible buffer text, and while it restores it on
;; exit, it is not something you want firing over a half-finished edit or in
;; the middle of a compile.

;;; Code:

(require 'mega-lib)

;; Declared special so the `let' in `mega-zone-maybe' is a dynamic binding.
;; Without this it would be lexical — zone.el is not loaded at compile time —
;; and the safe-program list below would be silently ignored.
(defvar zone-programs)

(defcustom mega-zone-idle-seconds nil
  "Idle seconds before `zone' takes over, or nil to disable it.
Set this in local.el; 300 is a reasonable first try."
  :type '(choice (const :tag "Never" nil) integer)
  :group 'mega
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'mega-zone-refresh) (mega-zone-refresh))))

(defcustom mega-zone-safe-programs
  '(zone-pgm-jitter zone-pgm-whack-chars zone-pgm-drip
    zone-pgm-martini-swan-dive zone-pgm-rotate)
  "The `zone' programs MEGA will run.
A deliberately cheap subset: the full list includes programs that spawn
subprocesses or churn the CPU for a while, which is not what you want
from something that fires while you are away."
  :type '(repeat symbol)
  :group 'mega)

(defvar mega--zone-timer nil)

(defun mega-zone--safe-p ()
  "Non-nil when it is reasonable to zone right now."
  (and (not (buffer-modified-p))
       (not (minibufferp))
       ;; Do not scramble a buffer that is attached to something live.
       (not (get-buffer-process (current-buffer)))
       (not (seq-some (lambda (p) (memq (process-status p) '(run stop)))
                      (seq-filter (lambda (p) (process-query-on-exit-flag p))
                                  (process-list))))))

(defun mega-zone-maybe ()
  "Run `zone' if it is safe to do so."
  (when (mega-zone--safe-p)
    (let ((zone-programs (vconcat mega-zone-safe-programs)))
      (ignore-errors (zone)))))

(defun mega-zone-refresh ()
  "Apply `mega-zone-idle-seconds', cancelling any previous timer."
  (interactive)
  (when (timerp mega--zone-timer)
    (cancel-timer mega--zone-timer)
    (setq mega--zone-timer nil))
  (when mega-zone-idle-seconds
    (require 'zone)
    (setq mega--zone-timer
          (run-with-idle-timer mega-zone-idle-seconds :repeat #'mega-zone-maybe))))

(mega-zone-refresh)

(provide 'mega-zone)
;;; mega-zone.el ends here
