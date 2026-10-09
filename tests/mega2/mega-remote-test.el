;;; mega-remote-test.el --- Tests for mega-remote.el and mega-zone.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; No machine is contacted here: a remote file name is only ever taken
;; apart, which Emacs does without connecting.

;;; Code:

(require 'mega-test-helper)
(require 'mega-remote)
(require 'mega-zone)

(defvar tramp-default-method)
(defvar tramp-persistency-file-name)
(defvar tramp-histfile-override)
(defvar tramp-verbose)
(defvar zone-programs)
(require 'zone)

;;;; Remote files

(ert-deftest mega-remote-costs-nothing-until-a-remote-file-is-opened ()
  (should-not (memq 'tramp mega-test-features-at-startup))
  (should-not (memq 'files-x mega-test-features-at-startup)))

(ert-deftest mega-remote-settings-survive-loading-tramp ()
  (require 'tramp)
  (should (equal tramp-default-method "ssh"))
  (should (= tramp-verbose 1))
  (should remote-file-name-inhibit-locks)
  ;; What TRAMP remembers about your machines stays private, and out of the
  ;; configuration directory.
  (should (file-in-directory-p tramp-persistency-file-name mega-cache-dir))
  ;; Its own shell commands are not left in a history file over there.
  (should (eq tramp-histfile-override t)))

(ert-deftest mega-remote-asks-only-git-about-a-remote-file ()
  (require 'tramp)
  (with-temp-buffer
    ;; Elsewhere every backend is asked.
    (should (> (length vc-handled-backends) 1))
    (setq default-directory "/ssh:mega-test.invalid:/srv/project/")
    (hack-connection-local-variables-apply
     (connection-local-criteria-for-default-directory))
    (should (equal vc-handled-backends '(Git)))
    (should (local-variable-p 'vc-handled-backends)))
  ;; A container opened through TRAMP is remote in the same sense.
  (with-temp-buffer
    (setq default-directory "/podman:mega-test:/workspaces/project/")
    (hack-connection-local-variables-apply
     (connection-local-criteria-for-default-directory))
    (should (equal vc-handled-backends '(Git)))))

(ert-deftest mega-remote-backups-and-auto-saves-of-remote-files-stay-here ()
  "They follow the same rules as every other file: see mega-core.el."
  (let ((remote "/ssh:mega-test.invalid:/etc/motd"))
    (should (file-in-directory-p
             (car (find-backup-file-name remote)) mega-cache-dir))
    (with-temp-buffer
      (setq buffer-file-name remote)
      (unwind-protect
          (should (file-in-directory-p (make-auto-save-file-name) mega-cache-dir))
        (setq buffer-file-name nil)))))

;;;; The screensaver

(ert-deftest mega-zone-is-off-and-unloaded-unless-asked-for ()
  (should-not mega-zone-idle-seconds)
  (should-not (memq 'zone mega-test-features-at-startup))
  (should-not (timerp mega-zone--timer)))

(ert-deftest mega-zone-timer-follows-the-setting ()
  (let ((mega-zone--timer nil))
    (unwind-protect
        (progn
          (let ((mega-zone-idle-seconds 300))
            (mega-zone-refresh)
            (should (timerp mega-zone--timer))
            (should (memq mega-zone--timer timer-idle-list))
            (let ((first mega-zone--timer))
              ;; Changing the setting replaces the timer, it does not add one.
              (mega-zone-refresh)
              (should-not (memq first timer-idle-list))
              (should (memq mega-zone--timer timer-idle-list))))
          (let ((mega-zone-idle-seconds nil)
                (previous mega-zone--timer))
            (mega-zone-refresh)
            (should-not mega-zone--timer)
            (should-not (memq previous timer-idle-list))))
      (when (timerp mega-zone--timer) (cancel-timer mega-zone--timer)))))

(ert-deftest mega-zone-does-not-start-over-something-you-are-waiting-for ()
  (let (zoned programs)
    (cl-letf (((symbol-function 'zone)
               (lambda (&rest _) (setq zoned t programs zone-programs))))
      (should (mega-zone-safe-p))
      (mega-zone-maybe)
      (should zoned)
      ;; Only the cheap programs MEGA lists.
      (should (equal programs (vconcat mega-zone-programs)))
      (setq zoned nil)
      ;; A build, a debugger, a shell: anything Emacs would ask about on exit.
      (let ((process (start-process "mega-zone-test" nil "sleep" "30")))
        (unwind-protect
            (progn
              (should-not (mega-zone-safe-p))
              (mega-zone-maybe)
              (should-not zoned)
              ;; A helper running in the background does not count.
              (set-process-query-on-exit-flag process nil)
              (should (mega-zone-safe-p)))
          (delete-process process)))
      (let ((executing-kbd-macro t))
        (should-not (mega-zone-safe-p))))))

(ert-deftest mega-zone-a-failing-screensaver-fails-silently ()
  (cl-letf (((symbol-function 'zone) (lambda (&rest _) (error "Broken"))))
    (mega-zone-maybe)))

(provide 'mega-remote-test)
;;; mega-remote-test.el ends here
