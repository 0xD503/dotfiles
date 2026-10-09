;;; mega-terminal-probe.el --- Check a real terminal session  -*- lexical-binding: t; -*-

;;; Commentary:

;; Not an ERT file.  tests/test_mega2.sh starts a real, interactive Emacs in a
;; pseudo-terminal — through `--init-directory', through chemacs2, or with an
;; Emacs too old for MEGA — and loads this file with `-l'.  By then the init
;; files have run, so this only looks, writes what it saw to the file named by
;; MEGA_TEST_REPORT, and exits.
;;
;; MEGA_TEST_EXPECT says what a correct start looks like: "supported" for a
;; configured MEGA, "refused" for an old Emacs that must be left plain.
;;
;; This file has to load on the old Emacs too: nothing newer than Emacs 27.

;;; Code:

(defvar mega-terminal-probe-problems nil
  "What the probe found wrong.")

(defun mega-terminal-probe--problem (format-string &rest arguments)
  "Record a problem described by FORMAT-STRING and ARGUMENTS."
  (push (apply #'format format-string arguments) mega-terminal-probe-problems))

(defun mega-terminal-probe--warnings ()
  "The text of the warnings buffer, or the empty string."
  (if (get-buffer "*Warnings*")
      (with-current-buffer "*Warnings*" (buffer-string))
    ""))

(defun mega-terminal-probe--modeline ()
  "The modeline of the current buffer as plain text.
The buffer is named explicitly: by default Emacs renders the modeline of
whatever buffer the selected window shows."
  (substring-no-properties
   (format-mode-line mode-line-format nil nil (current-buffer))))

(defun mega-terminal-probe--supported ()
  "Check a session in which MEGA is expected to be fully configured."
  (unless (bound-and-true-p mega-supported-p)
    (mega-terminal-probe--problem "MEGA refused this Emacs"))
  (when (bound-and-true-p mega-module-failures)
    (mega-terminal-probe--problem "modules failed: %S" mega-module-failures))
  (dolist (module '(mega-lib mega-core mega-ui mega-keys mega-session))
    (unless (featurep module)
      (mega-terminal-probe--problem "%s did not load" module)))
  (unless (string= (mega-terminal-probe--warnings) "")
    (mega-terminal-probe--problem "warnings: %s" (mega-terminal-probe--warnings)))
  (when (display-graphic-p)
    (mega-terminal-probe--problem "expected a terminal frame"))
  (unless (equal (number-to-string (display-color-cells))
                 (getenv "MEGA_TEST_COLOURS"))
    (mega-terminal-probe--problem "%s colours, expected %s"
                                  (display-color-cells) (getenv "MEGA_TEST_COLOURS")))
  (if (>= (display-color-cells) 256)
      ;; The theme reached the screen, not merely the theme list.
      (progn
        (unless (equal (face-attribute 'default :background) "#2E3440")
          (mega-terminal-probe--problem "default background is %s"
                                        (face-attribute 'default :background)))
        (unless (equal (face-attribute 'font-lock-string-face :foreground) "#A3BE8C")
          (mega-terminal-probe--problem "strings are %s"
                                        (face-attribute 'font-lock-string-face
                                                        :foreground))))
    ;; Too few colours to approximate the palette: the theme must stay out of
    ;; the way and leave the terminal's own colours alone.
    (when (equal (face-attribute 'default :background) "#2E3440")
      (mega-terminal-probe--problem "the theme was applied with only %s colours"
                                    (display-color-cells))))
  (unless (eql (frame-parameter nil 'menu-bar-lines) 0)
    (mega-terminal-probe--problem "the menu bar is showing"))
  (with-temp-buffer
    (prog-mode)
    (unless (bound-and-true-p display-fill-column-indicator-mode)
      (mega-terminal-probe--problem "no ruler in a code buffer"))
    (unless (bound-and-true-p display-line-numbers-mode)
      (mega-terminal-probe--problem "no line numbers in a code buffer")))
  ;; The modeline only renders on a real display, so this is where the
  ;; assembled line is checked.
  (with-temp-buffer
    (rename-buffer "mega-probe-buffer" t)
    (insert "one\ntwo\nthree")
    (let ((line (mega-terminal-probe--modeline)))
      (dolist (expected '("mega-probe-buffer" "3:5" "Fundamental"))
        (unless (string-match-p (regexp-quote expected) line)
          (mega-terminal-probe--problem "the modeline lacks %S: %S" expected line)))
      (when (string-match-p "Narrow" line)
        (mega-terminal-probe--problem "the modeline says Narrow in a whole buffer")))
    (narrow-to-region 1 4)
    (unless (string-match-p "Narrow" (mega-terminal-probe--modeline))
      (mega-terminal-probe--problem "the modeline does not say a buffer is narrowed")))
  (unless (eq (key-binding (kbd "C-c ?")) 'mega-help)
    (mega-terminal-probe--problem "C-c ? is %s" (key-binding (kbd "C-c ?"))))
  (when (and (equal (getenv "MEGA_TEST_LAUNCHER") "chemacs")
             (not (featurep 'chemacs)))
    (mega-terminal-probe--problem "chemacs was expected to have started this session")))

(defun mega-terminal-probe--refused ()
  "Check a session on an Emacs too old for MEGA: plain, warned, and tidy."
  (when (bound-and-true-p mega-supported-p)
    (mega-terminal-probe--problem "MEGA accepted Emacs %s" emacs-version))
  (dolist (module '(mega-core mega-ui mega-keys mega-session))
    (when (featurep module)
      (mega-terminal-probe--problem "%s loaded on an unsupported Emacs" module)))
  (unless (string-match-p "needs Emacs [0-9.]+ or newer"
                          (mega-terminal-probe--warnings))
    (mega-terminal-probe--problem "no warning explains the refusal; got: %s"
                                  (mega-terminal-probe--warnings)))
  (when custom-enabled-themes
    (mega-terminal-probe--problem "a theme was enabled: %S" custom-enabled-themes)))

(defun mega-terminal-probe--report ()
  "Check the session, write the report, and exit."
  (condition-case err
      (progn
        ;; True in every mode: even a refused session writes nowhere near the
        ;; configuration.
        (let ((config (getenv "MEGA_TEST_CONFIG")))
          (dolist (path (list user-emacs-directory custom-file))
            (when (or (null path)
                      (string-prefix-p (file-name-as-directory (expand-file-name config))
                                       (expand-file-name path)))
              (mega-terminal-probe--problem "%S points into the configuration" path))))
        (if (equal (getenv "MEGA_TEST_EXPECT") "refused")
            (mega-terminal-probe--refused)
          (mega-terminal-probe--supported)))
    (error (mega-terminal-probe--problem "the probe itself failed: %S" err)))
  (with-temp-file (getenv "MEGA_TEST_REPORT")
    (insert (format "emacs=%s\n" emacs-version)
            (format "term=%s\n" (getenv "TERM"))
            (format "colours=%s\n" (display-color-cells))
            (format "init-ms=%.1f\n"
                    (* 1000.0 (float-time (time-subtract after-init-time
                                                         before-init-time)))))
    (dolist (problem (reverse mega-terminal-probe-problems))
      (insert (format "problem: %s\n" problem)))
    (insert (format "verdict=%s\n" (if mega-terminal-probe-problems "bad" "ok"))))
  (kill-emacs (if mega-terminal-probe-problems 1 0)))

;; Depth 100, added last: runs after everything the init files put there,
;; including the warning an unsupported Emacs gets.
(add-hook 'emacs-startup-hook #'mega-terminal-probe--report 100)

;;; mega-terminal-probe.el ends here
