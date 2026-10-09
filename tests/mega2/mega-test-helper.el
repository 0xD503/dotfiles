;;; mega-test-helper.el --- Shared setup for the MEGA 2.0 tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded first by tests/test_mega2.sh.  It starts MEGA the way Emacs would —
;; early-init.el, then init.el — inside the sandbox the runner prepared, and
;; offers the few helpers the test files share.
;;
;; The tests then examine a configured Emacs.  That is deliberate: most of
;; what MEGA promises is a property of the running session ("backups never
;; land in a project", "an eval: line is ignored"), and the honest way to
;; check a promise like that is to try it.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; MEGA writes history, backups and caches.  Refuse to do that anywhere but
;; in a sandbox, so running a test by hand cannot touch the real state.
(let ((sandbox (getenv "MEGA_TEST_SANDBOX")))
  (unless (and sandbox
               (file-in-directory-p (expand-file-name "~") sandbox)
               (file-in-directory-p (or (getenv "XDG_STATE_HOME") "/") sandbox))
    (error "Run the MEGA tests through tests/test_mega2.sh")))

(defconst mega-test-dir (file-name-directory (or load-file-name buffer-file-name))
  "The directory holding the MEGA 2.0 tests.")

(defconst mega-test-config-dir
  (file-name-as-directory
   (expand-file-name (or (getenv "MEGA_TEST_CONFIG")
                         (expand-file-name "../../.mega2.d" mega-test-dir))))
  "The MEGA configuration under test.")

(load (expand-file-name "early-init.el" mega-test-config-dir) nil :nomessage)
(load (expand-file-name "init.el" mega-test-config-dir) nil :nomessage)

(defconst mega-test-features-at-startup (copy-sequence features)
  "What was loaded once init.el had finished, before any test ran.
Tests load more; a claim about startup has to be checked against this.")

(defun mega-test-write (file &rest lines)
  "Write LINES to FILE, creating its directory.  Return FILE."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (mapconcat #'identity lines "\n") nil file nil :silent))
  file)

(defmacro mega-test-with-directory (var &rest body)
  "Run BODY with VAR bound to a fresh, empty directory in the sandbox."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (file-name-as-directory
                (make-temp-file (expand-file-name "t-" (getenv "MEGA_TEST_SANDBOX"))
                                :directory))))
     ,@body))

(defmacro mega-test-visiting (var file &rest body)
  "Run BODY in a buffer visiting FILE, bound to VAR, then discard the buffer."
  (declare (indent 2) (debug (symbolp form body)))
  `(let ((,var (find-file-noselect ,file)))
     (unwind-protect
         (with-current-buffer ,var ,@body)
       (with-current-buffer ,var (set-buffer-modified-p nil))
       (kill-buffer ,var))))

(defun mega-test-buffer-string (name)
  "The text of buffer NAME, without properties."
  (with-current-buffer name
    (buffer-substring-no-properties (point-min) (point-max))))

(provide 'mega-test-helper)
;;; mega-test-helper.el ends here
