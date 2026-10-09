;;; mega-zone.el --- A screensaver, if you want one  -*- lexical-binding: t; -*-

;;; Commentary:

;; `zone' ships with Emacs: after a while without a keystroke it plays with
;; a copy of the text on screen until you press a key.  It is off unless you
;; ask for it, in local.el:
;;
;;   (setq mega-zone-idle-seconds 300)
;;
;; Your buffers are never touched: zone works on a copy.  What MEGA adds is a
;; timeout you can set, and the restraint not to start while something is
;; going on — a prompt waiting for an answer, a build, a debugger.

;;; Code:

(require 'mega-lib)

;; Declared special so that the `let' in `mega-zone-maybe' binds it
;; dynamically: zone.el is not loaded when this file is compiled.
(defvar zone-programs)

(defcustom mega-zone-idle-seconds nil
  "Idle seconds before the screensaver starts, or nil for never.
After changing it in a running Emacs, call `mega-zone-refresh'."
  :type '(choice (const :tag "Never" nil) natnum)
  :group 'mega)

(defcustom mega-zone-programs
  '(zone-pgm-jitter zone-pgm-whack-chars zone-pgm-drip
    zone-pgm-martini-swan-dive zone-pgm-rotate)
  "The `zone' programs MEGA runs.
A cheap subset on purpose: some of the others keep the processor busy,
which is not what something that runs while you are away should do."
  :type '(repeat function)
  :group 'mega)

(defvar mega-zone--timer nil
  "The idle timer that starts the screensaver, when there is one.")

(defun mega-zone-safe-p ()
  "Non-nil if nothing is going on that the screensaver would get in the way of."
  (and (not (active-minibuffer-window))
       (not executing-kbd-macro)
       ;; A program you would be asked about on quitting is one you are
       ;; waiting for: a build, a debugger, a shell.
       (not (seq-some (lambda (process)
                        (and (process-query-on-exit-flag process)
                             (memq (process-status process) '(run stop))))
                      (process-list)))))

(defun mega-zone-maybe ()
  "Start the screensaver, unless something is going on."
  (when (mega-zone-safe-p)
    (require 'zone)
    (let ((zone-programs (vconcat mega-zone-programs)))
      ;; A screensaver that fails must fail silently.
      (ignore-errors (zone)))))

(defun mega-zone-refresh ()
  "Apply `mega-zone-idle-seconds'."
  (interactive)
  (when (timerp mega-zone--timer)
    (cancel-timer mega-zone--timer)
    (setq mega-zone--timer nil))
  (when (and mega-zone-idle-seconds (> mega-zone-idle-seconds 0))
    (setq mega-zone--timer
          (run-with-idle-timer mega-zone-idle-seconds t #'mega-zone-maybe))))

;; Nothing a screensaver does is needed in the first instant.
(mega-after-startup #'mega-zone-refresh)

(provide 'mega-zone)
;;; mega-zone.el ends here
