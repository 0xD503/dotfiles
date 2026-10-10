;;; mega-compile.el --- A compiled copy of MEGA's own Lisp  -*- lexical-binding: t; -*-

;;; Commentary:

;; MEGA's Lisp is deployed as source, and the directory it is deployed to is
;; never written to.  Run as source it is fast enough; compiled it is faster,
;; and Emacs turns compiled files into native code by itself.  So a compiled
;; copy is kept where things that can be made again belong, in the cache
;; directory, and you need do nothing to have it:
;;
;;   the first start after an update   runs the source, and a few seconds
;;                                     after Emacs is on screen compiles a
;;                                     copy, in the background
;;   the starts after that             load the compiled copy; Emacs compiles
;;                                     each file it loads to native code, in
;;                                     the background, and switches to that
;;                                     as it gets there
;;   after that                        native code from the first moment
;;
;; `M-x mega-doctor' says which of these a session is.  Nothing compiled is
;; ever written into the configuration directory or the repository it came
;; from.
;;
;; Safety.  Which copy is loaded is decided in early-init.el, by a
;; fingerprint of the source: a compiled copy made from anything but the
;; source that is there now is not used.  A copy is made whole or not at
;; all: in a directory of its own, moved into place when the last file has
;; compiled.  One file that does not compile means no copy, the reason in
;; the doctor's report, and MEGA running as source, as before.
;;
;; The compiling is done by another Emacs, started for the purpose, so that
;; this one is never held up and cannot be disturbed by what compiling
;; loads.  That Emacs is given state directories of its own to throw away,
;; and leaves without running exit hooks: compiling a module loads the ones
;; it requires, and should one of those ever be a module that saves history
;; on the way out, it must not write an empty one over yours.
;;
;;   MEGA_SOURCE=1 emacs       run the source this once, whatever is there
;;   (setq mega-compile nil)   in local.el: make no copies
;;   M-x mega-compile-now      make the copy now
;;   M-x mega-compile-forget   delete it

;;; Code:

(require 'mega-lib)
(require 'mega-exec)

;; Defined by early-init.el, which decides what is loaded before anything is.
(defvar mega-compiled-dir)
(defvar mega-compiled-p)
(declare-function mega-fingerprint "early-init")
(declare-function native-comp-function-p "data.c")

;; The compiler's, and special before the compiler is loaded: bound below
;; as anything else they would switch nothing, and stop it from loading.
(defvar byte-compile-error-on-warn)
(defvar byte-compile-verbose)

(defcustom mega-compile t
  "Non-nil to keep a compiled copy of MEGA's own Lisp, made when needed.
It is made in the background after a start that had to run from source,
and used from the next start on.  Nil means MEGA makes none; a copy that
is there already is still used: `M-x mega-compile-forget' deletes it."
  :type 'boolean
  :group 'mega)

(defvar mega-compile--process nil
  "The Emacs that is making the compiled copy, while it is.")

(defvar mega-compile--made nil
  "Non-nil once this session has made a compiled copy, for the next start.")

;;;; Making the copy
;;
;; This part runs in the other Emacs, and in the tests.

(defun mega-compile--sweep (target)
  "Delete what builds of TARGET that died half way left beside it."
  (let ((name (file-name-nondirectory target)))
    (dolist (file (directory-files (file-name-directory target) t
                                   (concat "\\`" (regexp-quote name)
                                           "\\.\\(?:new\\|old\\)-")))
      ;; Not one that is being made this minute, by another Emacs.
      (when (> (float-time (time-since (file-attribute-modification-time
                                        (file-attributes file))))
               3600)
        (ignore-errors (delete-directory file t))))))

(defun mega-compile-build (&optional target source)
  "Compile the Lisp in SOURCE into the directory TARGET, all of it or none.
SOURCE defaults to `mega-lisp-dir' and TARGET to `mega-compiled-dir'.
TARGET ends up holding a copy of every source file, its compiled file,
and the fingerprint of those copies; or, if a file would not compile,
it is left as it was and an error is signalled.  Returns TARGET."
  (let* ((source (file-name-as-directory (or source mega-lisp-dir)))
         (target (directory-file-name (or target mega-compiled-dir)))
         (work nil)
         (done nil))
    (with-file-modes #o700
      (make-directory (file-name-directory target) t))
    (mega-compile--sweep target)
    (setq work (make-temp-file (concat target ".new-") t))
    (unwind-protect
        (let ((copies nil))
          (dolist (file (directory-files source t "\\`[^.].*\\.el\\'"))
            (let ((copy (expand-file-name (file-name-nondirectory file) work)))
              (copy-file file copy)
              (push copy copies)))
          (setq copies (nreverse copies))
          ;; Against the copies: what one file takes from another while it
          ;; is compiled is then what it will meet when it runs.
          (let ((load-path (cons work load-path))
                (byte-compile-error-on-warn nil)
                (byte-compile-verbose nil))
            (dolist (copy copies)
              (unless (eq (byte-compile-file copy) t)
                (error "%s did not compile" (file-name-nondirectory copy)))))
          ;; A copy that somebody finds and edits would be an edit lost.
          (dolist (copy copies)
            (set-file-modes copy #o444))
          ;; Of the copies, not of the source: it says what was compiled,
          ;; whatever happened to the source meanwhile.  Written last.
          (with-temp-file (expand-file-name "fingerprint" work)
            (insert (mega-fingerprint work)))
          (let ((old (and (file-exists-p target)
                          (make-temp-name (concat target ".old-")))))
            (when old (rename-file target old))
            (rename-file work target)
            (setq done t)
            (when old (ignore-errors (delete-directory old t)))))
      (unless done
        (ignore-errors (delete-directory work t))))
    (file-name-as-directory target)))

(defun mega-compile-batch (target)
  "Make the compiled copy in TARGET and leave Emacs: 0 if it was made.
For the Emacs that `mega-compile-start' starts.  It leaves without
running what the modules it loaded put on the way out."
  (let ((status (condition-case err
                    (progn (mega-compile-build target) 0)
                  (error (message "%s" (error-message-string err)) 1)))
        (kill-emacs-hook nil))
    (kill-emacs status)))

;;;; Asking for it, from the Emacs you are in

(defun mega-compile--failure-file ()
  "The file that remembers a copy that could not be made, and why."
  (concat (directory-file-name mega-compiled-dir) ".failed"))

(defun mega-compile--failure ()
  "The last failure to make a copy: (FINGERPRINT . REASON), or nil."
  (let ((file (mega-compile--failure-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (cons (buffer-substring (point) (line-end-position))
              (string-trim (buffer-substring (line-end-position) (point-max))))))))

(defun mega-compile-command (target)
  "How to start the Emacs that makes the compiled copy in TARGET.
Return (PROGRAM . ARGS).  It is this Emacs again, without anybody's
settings, told where MEGA is and what to do."
  (list (expand-file-name invocation-name invocation-directory)
        "-Q" "--batch"
        "-l" (expand-file-name "early-init.el" mega-dir)
        "--eval" (format "(progn (require 'mega-compile) (mega-compile-batch %S))"
                         (directory-file-name target))))

(defun mega-compile--finished (result fingerprint scratch quiet)
  "Take note of how making the copy went.
RESULT is what the other Emacs came to, FINGERPRINT the source it was
asked to compile, SCRATCH the directory it was given to throw away;
QUIET non-nil means nobody is waiting to hear."
  (setq mega-compile--process nil)
  (ignore-errors (delete-directory scratch t))
  (let ((stamp (expand-file-name "fingerprint" mega-compiled-dir)))
    (if (and (eql (plist-get result :status) 0)
             (file-readable-p stamp))
        (progn
          (setq mega-compile--made t)
          (ignore-errors (delete-file (mega-compile--failure-file)))
          (message "MEGA: its Lisp is compiled; the next start uses that"))
      (let ((reason (string-trim
                     (concat (plist-get result :error) "\n" (plist-get result :output)))))
        (with-temp-file (mega-compile--failure-file)
          (insert fingerprint "\n"
                  (if (plist-get result :stopped)
                      (format "It was stopped (%s)." (plist-get result :stopped))
                    "")
                  ;; The end of it: that is where the reason is.
                  (substring reason (max 0 (- (length reason) 2000)))))
        (unless quiet
          (message "MEGA: its Lisp could not be compiled; M-x mega-doctor says why"))))))

(defun mega-compile-start (&optional quiet)
  "Start making the compiled copy, in the background.  Return the process.
With QUIET non-nil, say nothing if it does not work out."
  (unless (process-live-p mega-compile--process)
    (let* ((scratch (make-temp-file "mega-compile-" t))
           (fingerprint (mega-fingerprint mega-lisp-dir))
           (command (mega-compile-command mega-compiled-dir))
           ;; Its own, to throw away: see the Commentary.  And the source,
           ;; whatever copy there is: this is what makes the copy.
           (process-environment
            (append (list "MEGA_SOURCE=1"
                          (concat "XDG_STATE_HOME=" (expand-file-name "state" scratch))
                          (concat "XDG_CACHE_HOME=" (expand-file-name "cache" scratch))
                          (concat "XDG_DATA_HOME=" (expand-file-name "data" scratch)))
                    process-environment)))
      (setq mega-compile--process
            (mega-exec-start (car command) (cdr command)
                             :here t
                             :directory temporary-file-directory
                             :then (lambda (result)
                                     (mega-compile--finished result fingerprint
                                                             scratch quiet))))))
  mega-compile--process)

;;;###autoload
(defun mega-compile-now ()
  "Make the compiled copy of MEGA's Lisp now, in the background.
It is used from the next start on."
  (interactive)
  (when (process-live-p mega-compile--process)
    (user-error "It is being made already"))
  (mega-compile-start)
  (message "MEGA: compiling its Lisp in the background..."))

;;;###autoload
(defun mega-compile-forget ()
  "Delete the compiled copy of MEGA's Lisp.
The next start runs the source; and makes a new copy, unless
`mega-compile' is nil."
  (interactive)
  (when (process-live-p mega-compile--process)
    (mega-exec-stop mega-compile--process))
  (when (file-directory-p mega-compiled-dir)
    (delete-directory mega-compiled-dir t))
  (ignore-errors (delete-file (mega-compile--failure-file)))
  (setq mega-compile--made nil)
  (message "MEGA: the compiled copy is gone; the next start runs the source"))

;;;; By itself, when a session had to run from source

(defun mega-compile--wanted-p ()
  "Non-nil if this session should make the compiled copy by itself.
That is: it runs from source for want of one, not because it was asked
to, and the same source has not failed to compile before."
  (and mega-compile
       (not noninteractive)
       (not mega-compiled-p)
       (not mega-compile--made)
       (member (getenv "MEGA_SOURCE") '(nil ""))
       (not (equal (car (mega-compile--failure))
                   (mega-fingerprint mega-lisp-dir)))))

(defun mega-compile--when-idle ()
  "Make the compiled copy if this session wants one."
  (when (mega-compile--wanted-p)
    (mega-compile-start :quiet)))

;; A few seconds after Emacs is on screen: nothing of this is in the way of
;; the first key.
(unless noninteractive
  (add-hook 'emacs-startup-hook
            (lambda () (run-with-idle-timer 3 nil #'mega-compile--when-idle))
            100))

;;;; The doctor

(defun mega-compile-forms ()
  "How MEGA's functions are held in this session: (NATIVE BYTE SOURCE), counts."
  (let ((native 0) (byte 0) (source 0))
    (mapatoms
     (lambda (symbol)
       (when (and (fboundp symbol)
                  (string-prefix-p "mega-" (symbol-name symbol)))
         (let ((function (symbol-function symbol)))
           (cond ((and (fboundp 'native-comp-function-p)
                       (native-comp-function-p function))
                  (setq native (1+ native)))
                 ((byte-code-function-p function) (setq byte (1+ byte)))
                 ((functionp function) (setq source (1+ source))))))))
    (list native byte source)))

(defun mega-compile--doctor ()
  "Insert the doctor's section about how MEGA's own Lisp is run."
  (mega-doctor-heading "MEGA's own Lisp")
  (pcase-let ((`(,native ,byte ,source) (mega-compile-forms))
              (failure (mega-compile--failure)))
    (mega-doctor-row "this session runs"
                     (cond ((not mega-compiled-p) "the source")
                           ((zerop native) "the compiled copy")
                           (t "the compiled copy, as native code where Emacs has got to")))
    (mega-doctor-row "its functions"
                     (format "%d native, %d compiled, %d source" native byte source))
    (mega-doctor-row
     "the compiled copy"
     (cond (mega-compiled-p (abbreviate-file-name mega-compiled-dir))
           ((process-live-p mega-compile--process) "is being made now")
           (mega-compile--made "is made; the next start uses it")
           ((not (member (getenv "MEGA_SOURCE") '(nil "")))
            "set aside for this session: MEGA_SOURCE is set")
           ((and failure (equal (car failure) (mega-fingerprint mega-lisp-dir)))
            "could not be made from this source")
           ((not mega-compile) "none, and none is made: `mega-compile' is nil")
           (t "none yet: made in the background, a few seconds after starting"))
     (and failure (not mega-compiled-p) 'error))
    (when (and failure (not mega-compiled-p)
               (equal (car failure) (mega-fingerprint mega-lisp-dir)))
      (insert "\n  What the compiler said, at the end:\n")
      (dolist (line (last (split-string (cdr failure) "\n" t) 8))
        (insert "    " line "\n"))
      (insert "\n  M-x mega-compile-now tries again.\n"))))

(add-to-list 'mega-doctor-sections #'mega-compile--doctor t)

(provide 'mega-compile)
;;; mega-compile.el ends here
