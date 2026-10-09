;;; mega-doctor-test.el --- Tests for mega-doctor.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-doctor)

;; Bound dynamically by the tests below, before package.el has defined it.
(defvar package-archives)

(defun mega-doctor-test--report ()
  "Run the doctor and return its report as plain text."
  (save-window-excursion
    (mega-doctor)
    (mega-test-buffer-string "*mega-doctor*")))

(defun mega-doctor-test--says (text report)
  "Non-nil if REPORT contains TEXT, matching case exactly."
  (let ((case-fold-search nil))
    (string-match-p (regexp-quote text) report)))

(ert-deftest mega-doctor-reports-every-section ()
  (let ((report (mega-doctor-test--report)))
    (dolist (heading '("MEGA doctor" "\nEmacs\n" "\nStartup\n"
                       "\nSafety, privacy, security\n" "\nOptional programs\n"))
      (should (string-match-p (regexp-quote heading) report)))
    (should (string-match-p (regexp-quote emacs-version) report))
    (should (string-match-p (regexp-quote mega-version) report))
    (should-not (string-match-p "could not report" report))))

(ert-deftest mega-doctor-finds-nothing-wrong-with-a-fresh-start ()
  "Every safety row must read as good on a healthy configuration."
  (let ((report (mega-doctor-test--report)))
    (dolist (good '("on, outside project trees" "moves them to the trash"
                    "read-only: Emacs writes elsewhere"
                    "none: package.el is off and has no archives"
                    "safe ones only, no eval" "not saved to disk"))
      (should (mega-doctor-test--says good report)))
    (should (= 3 (mega-doctor-test--count " private$" report)))
    (dolist (bad '("OFF" "is permanent" "readable by others" "may write into it"
                   "package.el is active" "UNSAFE" "SAVED to disk"))
      (should-not (mega-doctor-test--says bad report)))))

(defun mega-doctor-test--count (regexp string)
  "How many times REGEXP matches in STRING."
  (let ((count 0) (start 0))
    (while (string-match regexp string start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(ert-deftest mega-doctor-notices-what-is-wrong ()
  "Break each promise in turn and check the doctor says so."
  (let ((enable-local-eval t))
    (should (string-match-p "UNSAFE ones are allowed" (mega-doctor-test--report))))
  (let ((make-backup-files nil))
    (should (string-match-p "OFF or misplaced" (mega-doctor-test--report))))
  (let ((delete-by-moving-to-trash nil))
    (should (string-match-p "is permanent" (mega-doctor-test--report))))
  (let ((savehist-additional-variables '(kill-ring)))
    (should (string-match-p "SAVED to disk" (mega-doctor-test--report))))
  (let ((package-archives '(("gnu" . "https://elpa.gnu.org/packages/"))))
    (should (string-match-p "package.el is active" (mega-doctor-test--report))))
  (let ((user-emacs-directory mega-dir))
    (should (string-match-p "may write into it" (mega-doctor-test--report))))
  (unwind-protect
      (progn
        (set-file-modes mega-state-dir #o755)
        (should (string-match-p "readable by others" (mega-doctor-test--report))))
    (set-file-modes mega-state-dir #o700)))

(ert-deftest mega-doctor-lists-startup-and-lazy-modules ()
  (let ((report (mega-doctor-test--report)))
    (dolist (module '("mega-core" "mega-ui" "mega-keys" "mega-session"))
      (should (string-match-p (concat module " +[0-9.]+ ms") report)))
    (should (string-match-p "mega-doctor +in use" report))
    (should-not (string-match-p "FAILED\\|FAILS" report))))

(ert-deftest mega-doctor-loads-every-module-and-shows-its-section ()
  "The doctor is where a module that cannot load has to show up."
  (let ((report (mega-doctor-test--report)))
    (dolist (entry mega-lazy-modules)
      (should (featurep (car entry))))
    (dolist (heading '("Languages" "Undo" "Formatters" "Snippets" "Debuggers"
                       "Claude" "Dev containers"
                       "Projects that may run their own tools"))
      (should (string-match-p (concat "\n" (regexp-quote heading) "\n") report)))
    (should-not (string-match-p "could not report" report))))

(ert-deftest mega-doctor-says-when-a-module-cannot-load ()
  (let* ((mega-lazy-modules (cons '(mega-test-no-such-module mega-test-command)
                                  mega-lazy-modules))
         (report (mega-doctor-test--report)))
    (should (string-match-p "mega-test-no-such-module +FAILS TO LOAD: " report))
    ;; The rest of the report is still there.
    (should (string-match-p "\nOptional programs\n" report))))

(ert-deftest mega-doctor-lists-a-module-that-failed ()
  (let* ((mega-module-failures '((mega-test-broken . "deliberately broken")))
         (report (mega-doctor-test--report)))
    (should (string-match-p "FAILED to load" report))
    (should (string-match-p "mega-test-broken +deliberately broken" report))))

(ert-deftest mega-doctor-shows-a-section-a-module-added ()
  (let* ((mega-doctor-sections
          (list (lambda ()
                  (mega-doctor-heading "Test feature")
                  (mega-doctor-row "probe" "present"))))
         (report (mega-doctor-test--report)))
    (should (string-match-p "\nTest feature\n" report))
    (should (string-match-p "probe +present" report))))

(ert-deftest mega-doctor-survives-a-section-that-breaks ()
  (let* ((mega-doctor-sections (list (lambda () (error "section exploded"))))
         (report (mega-doctor-test--report)))
    (should (string-match-p "could not report: section exploded" report))
    (should (string-match-p "\nOptional programs\n" report))))

(ert-deftest mega-doctor-says-which-optional-programs-exist ()
  (mega-test-with-directory dir
    (let ((tool (mega-test-write (expand-file-name "rg" dir) "#!/bin/sh" ""))
          (exec-path (list dir))
          (mega--exe-cache (make-hash-table :test #'equal)))
      (set-file-modes tool #o755)
      (let ((report (mega-doctor-test--report)))
        (should (string-match-p (concat "rg +" (regexp-quote tool)) report))
        (should (string-match-p "git +not found" report))))))

(ert-deftest mega-doctor-runs-no-program-and-opens-no-connection ()
  "It reports; it never installs, connects or executes."
  (let (called)
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest args) (push args called) 1))
              ((symbol-function 'make-process)
               (lambda (&rest args) (push args called) nil))
              ((symbol-function 'make-network-process)
               (lambda (&rest args) (push args called) nil)))
      (mega-doctor-test--report))
    (should-not called)))

(ert-deftest mega-doctor-the-report-is-read-only ()
  (save-window-excursion
    (mega-doctor)
    (with-current-buffer "*mega-doctor*"
      (should buffer-read-only)
      (should (derived-mode-p 'special-mode)))))

(provide 'mega-doctor-test)
;;; mega-doctor-test.el ends here
