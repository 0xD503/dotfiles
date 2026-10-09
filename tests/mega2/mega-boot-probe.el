;;; mega-boot-probe.el --- Watch what starting MEGA does  -*- lexical-binding: t; -*-

;;; Commentary:

;; Not an ERT file: it has to be in place before MEGA loads.  It records every
;; attempt to run a program or open a connection, starts MEGA exactly as the
;; unit tests do, and then checks what happened.  tests/test_mega2.sh runs it
;; in a fresh batch Emacs, requires its "verdict=ok" line, and reads the
;; "load-ms" line for the startup budget.
;;
;; Two things about batch mode shape this file:
;;
;; * Emacs never runs `emacs-startup-hook' in batch mode, so the probe runs it
;;   itself.  Without that, everything MEGA defers to that hook would go
;;   unchecked while the probe still exited cleanly.
;;
;; * Warnings go to stderr instead of a buffer, so they are recorded here.
;;
;; Emacs's own background native compilation is switched off.  It is Emacs
;; compiling its bundled libraries on first use, not something MEGA starts,
;; and it would drown the one thing this probe is listening for.

;;; Code:

(defvar mega-boot-probe-calls nil
  "Every recorded attempt to start a process or open a connection.")

(defvar mega-boot-probe-warnings nil
  "Every warning raised during startup.")

(defvar mega-boot-probe-problems nil
  "What the probe found wrong.")

(defvar native-comp-jit-compilation)
(setq native-comp-jit-compilation nil)

(dolist (function '(make-process call-process call-process-region process-file
                    start-file-process make-network-process make-pipe-process
                    make-serial-process open-network-stream
                    url-retrieve url-retrieve-synchronously))
  (when (fboundp function)
    (advice-add function :before
                (lambda (&rest arguments)
                  (push (cons function arguments) mega-boot-probe-calls))
                '((name . mega-boot-probe)))))

(advice-add 'display-warning :before
            (lambda (type message &rest _)
              (push (format "%s: %s" type message) mega-boot-probe-warnings))
            '((name . mega-boot-probe)))

;; Intercepting a built-in function makes a natively compiling Emacs build a
;; small shim for it, which may itself run a compiler.  That was the probe,
;; not MEGA: start counting from here.
(setq mega-boot-probe-calls nil)

(defun mega-boot-probe--problem (format-string &rest arguments)
  "Record a problem described by FORMAT-STRING and ARGUMENTS."
  (push (apply #'format format-string arguments) mega-boot-probe-problems))

(defvar mega-boot-probe-load-ms
  (let ((config (file-name-as-directory (getenv "MEGA_TEST_CONFIG")))
        (start (current-time)))
    (load (expand-file-name "early-init.el" config) nil :nomessage)
    (load (expand-file-name "init.el" config) nil :nomessage)
    (* 1000.0 (float-time (time-since start))))
  "How long early-init.el and init.el took to load, in milliseconds.")

(run-hooks 'emacs-startup-hook)

(unless (bound-and-true-p mega-supported-p)
  (mega-boot-probe--problem "this Emacs is not supported: %s" emacs-version))
(when (bound-and-true-p mega-module-failures)
  (mega-boot-probe--problem "modules failed: %S" mega-module-failures))
(unless (bound-and-true-p mega-modules)
  (mega-boot-probe--problem "there is no module list"))
(dolist (spec (bound-and-true-p mega-modules))
  (if (consp spec)
      (when (featurep (car spec))
        (mega-boot-probe--problem "%s loaded at startup; it should be lazy" (car spec)))
    (unless (featurep spec)
      (mega-boot-probe--problem "%s did not load" spec))))
(when mega-boot-probe-calls
  (mega-boot-probe--problem "startup ran a program or opened a connection: %S"
                            (reverse mega-boot-probe-calls)))
(when mega-boot-probe-warnings
  (mega-boot-probe--problem "startup produced warnings: %S"
                            (reverse mega-boot-probe-warnings)))
(when (file-in-directory-p user-emacs-directory (getenv "MEGA_TEST_CONFIG"))
  (mega-boot-probe--problem "user-emacs-directory is inside the configuration"))
(unless (eql gc-cons-threshold (bound-and-true-p mega-gc-cons-threshold))
  (mega-boot-probe--problem "the garbage collector was left at %s" gc-cons-threshold))
(dolist (feature '(package ispell flyspell eglot tramp url))
  (when (featurep feature)
    (mega-boot-probe--problem "%s was loaded at startup" feature)))

(princ (format "load-ms=%.1f\n" mega-boot-probe-load-ms))
(dolist (problem (reverse mega-boot-probe-problems))
  (princ (format "problem: %s\n" problem)))
(princ (format "verdict=%s\n" (if mega-boot-probe-problems "bad" "ok")))
(kill-emacs (if mega-boot-probe-problems 1 0))

;;; mega-boot-probe.el ends here
