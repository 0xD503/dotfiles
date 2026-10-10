;;; early-init.el --- Runs before package.el and the first frame  -*- lexical-binding: t; -*-

;;; Commentary:

;; Three concerns only: whether this Emacs is new enough, where files go, and
;; what startup costs: which includes whether MEGA's own Lisp is loaded as
;; source or from its compiled copy.  Nothing here is about editing text.
;;
;; MEGA is launcher-neutral.  This file runs the same whether Emacs was
;; started with `--init-directory' or a profile switcher loaded it, so it
;; finds its own directory from `load-file-name' and never asks who called.

;;; Code:

(defconst mega-minimum-emacs-version "31.1"
  "The oldest Emacs MEGA supports.")

(defconst mega-supported-p
  (not (version< emacs-version mega-minimum-emacs-version))
  "Non-nil when this Emacs is new enough to run MEGA.
On an older Emacs MEGA configures nothing: `init.el' says so and leaves a
plain, working Emacs, which is better than a half-loaded configuration.")

(defconst mega-gc-cons-threshold (* 32 1024 1024)
  "Steady-state `gc-cons-threshold' once startup has finished.")

(defconst mega-lisp-dir
  (expand-file-name "lisp/" (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding MEGA's own Lisp, as source.")

(defconst mega-dir (file-name-directory (directory-file-name mega-lisp-dir))
  "MEGA's configuration directory, the deployed copy of `.mega2.d'.
Nothing is written here at runtime.")

;;;; Source, or the compiled copy
;;
;; This directory holds MEGA's Lisp as source and is never written to.  A
;; compiled copy of it is kept in the cache directory: mega-compile.el makes
;; it, in the background, the first time a session has had to run from
;; source.  The copy is used only if it was made from exactly the source
;; that is here now, which a fingerprint of every file settles: so a
;; compiled file can be missing, and then the source runs, but it can never
;; be stale.  From a compiled file Emacs goes on, by itself, to native code.
;;
;; MEGA_SOURCE=1 in the environment runs the source, whatever is there.

(defun mega-fingerprint (directory)
  "Identify the Lisp in DIRECTORY: each file's name and contents, and this Emacs.
Compiled code is good for the Emacs that compiled it, and for no other."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert emacs-version "\n" system-configuration "\n")
    (dolist (file (directory-files directory t "\\`[^.].*\\.el\\'"))
      (insert (file-name-nondirectory file) "\n")
      (insert-file-contents-literally file)
      (goto-char (point-max)))
    ;; Of the bytes as they are.  The hash functions that take a coding
    ;; system cost five times as much on this much text, at every start.
    (buffer-hash)))

(defconst mega-compiled-dir
  (let ((cache (getenv "XDG_CACHE_HOME")))
    (expand-file-name
     ;; One for each place MEGA is installed in, so that a checkout and the
     ;; deployed copy do not take turns at one directory.
     (concat "mega2/compiled/" (substring (secure-hash 'sha1 mega-dir) 0 12) "/")
     (if (and cache (file-name-absolute-p cache))
         cache
       (expand-file-name ".cache" "~"))))
  "Where the compiled copy of `mega-lisp-dir' is kept: under MEGA's cache.
It holds a copy of each source file, the compiled file beside it, and a
file `fingerprint' written last.")

(defconst mega-compiled-p
  (and mega-supported-p
       (member (getenv "MEGA_SOURCE") '(nil ""))
       (let ((stamp (expand-file-name "fingerprint" mega-compiled-dir)))
         (and (file-readable-p stamp)
              (equal (with-temp-buffer
                       (insert-file-contents-literally stamp)
                       (buffer-string))
                     (mega-fingerprint mega-lisp-dir))))
       t)
  "Non-nil if this session loads MEGA's Lisp from its compiled copy.")

(add-to-list 'load-path (directory-file-name mega-lisp-dir))
(when mega-compiled-p
  ;; In front: a file that is there is taken from there.
  (add-to-list 'load-path (directory-file-name mega-compiled-dir)))
(require 'mega-lib)

;;;; Where Emacs writes
;;
;; These apply on any Emacs, supported or not: even a refused session must
;; not write into the configuration directory.  `user-emacs-directory' itself
;; is redirected in init.el, because a profile switcher may still need it to
;; find that file.

(mega-protect-directories)

(when (fboundp 'startup-redirect-eln-cache)
  (startup-redirect-eln-cache (mega-cache "eln/")))

;; MEGA installs nothing.  package.el is never initialised, and with no
;; archives configured it cannot download anything by accident either.
(defvar package-archives)
(defvar package-quickstart)
(defvar native-comp-async-report-warnings-errors)

(setq package-enable-at-startup nil
      package-archives nil
      package-quickstart nil)

(when mega-supported-p

  ;;;; Garbage collection
  ;;
  ;; Init allocates hard and briefly; collecting during it is pure waste.
  ;; Raise the threshold for the duration, then settle at a figure that keeps
  ;; interactive pauses invisible.

  (setq gc-cons-threshold most-positive-fixnum)

  (add-hook 'emacs-startup-hook
            (lambda () (setq gc-cons-threshold mega-gc-cons-threshold))
            100)

  ;;;; Frame and startup noise
  ;;
  ;; A terminal frame shows a menu bar line unless told otherwise, and the
  ;; first terminal frame already exists by now: `default-frame-alist' is too
  ;; late for it, so the mode is switched off by calling it.  The GUI settings
  ;; cost nothing and stop a stray graphical Emacs from flashing a toolbar.

  (menu-bar-mode -1)

  (setq default-frame-alist '((menu-bar-lines . 0)
                              (tool-bar-lines . 0)
                              (vertical-scroll-bars . nil)
                              (horizontal-scroll-bars . nil))
        frame-inhibit-implied-resize t
        inhibit-startup-screen t
        inhibit-startup-echo-area-message user-login-name
        initial-scratch-message nil
        native-comp-async-report-warnings-errors 'silent
        ;; Prefer the newer of .el and .elc, so an edited module never
        ;; silently runs a stale compiled copy.
        load-prefer-newer t)

  ;; These two exist only in an Emacs built with a GUI toolkit.
  (when (boundp 'tool-bar-mode) (setq tool-bar-mode nil))
  (when (boundp 'scroll-bar-mode) (setq scroll-bar-mode nil)))

;;; early-init.el ends here
