;;; early-init.el --- Runs before package.el and the first frame  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two concerns only: what startup costs, and where files go.  Nothing here is
;; about editing text.
;;
;; chemacs2 has already pointed `user-emacs-directory' at this profile by the
;; time this file runs.

;;; Code:

(add-to-list 'load-path
             (expand-file-name "lisp" (file-name-directory
                                       (or load-file-name buffer-file-name))))
(require 'mega-lib)

;;;; Garbage collection
;;
;; Init allocates hard and briefly; collecting during it is pure waste.  Raise
;; the threshold for the duration, then settle at a figure that keeps
;; interactive pauses invisible, and do the real collecting while the user is
;; reading rather than typing.

(defconst mega-gc-cons-threshold (* 64 1024 1024)
  "Steady-state `gc-cons-threshold' once startup has finished.")

(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

(defvar mega--file-name-handler-alist file-name-handler-alist)
(setq file-name-handler-alist nil)

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold mega-gc-cons-threshold
                  gc-cons-percentage 0.1
                  file-name-handler-alist mega--file-name-handler-alist)
            (run-with-idle-timer 5 t #'garbage-collect))
          100)

;; A long completion session allocates steadily; a collection mid-search is a
;; visible stutter.  Defer it to the moment the minibuffer closes.
(add-hook 'minibuffer-setup-hook
          (lambda () (setq gc-cons-threshold most-positive-fixnum)))
(add-hook 'minibuffer-exit-hook
          (lambda () (setq gc-cons-threshold mega-gc-cons-threshold)))

;;;; Where package.el and the native compiler put things
;;
;; This has to happen here: package.el initialises between early-init.el and
;; init.el, and the eln cache is chosen before any Lisp is compiled.

(setq package-user-dir (mega-data "elpa/")
      package-gnupghome-dir (mega-data "elpa/gnupg/")
      package-quickstart t
      package-quickstart-file (mega-cache "package-quickstart.el"))

(when (fboundp 'startup-redirect-eln-cache)
  (startup-redirect-eln-cache (mega-cache "eln/")))

(setq native-comp-async-report-warnings-errors 'silent
      native-comp-jit-compilation t)

;;;; Frame and startup noise
;;
;; This is a terminal-first configuration, but the GUI settings cost nothing
;; and stop a stray `emacs' from flashing a toolbar.

(setq default-frame-alist '((menu-bar-lines . 0)
                            (tool-bar-lines . 0)
                            (vertical-scroll-bars . nil)
                            (horizontal-scroll-bars . nil))
      menu-bar-mode nil
      tool-bar-mode nil
      scroll-bar-mode nil
      frame-inhibit-implied-resize t
      frame-resize-pixelwise t
      inhibit-x-resources t
      inhibit-startup-screen t
      inhibit-startup-echo-area-message user-login-name
      initial-scratch-message nil
      inhibit-compacting-font-caches t
      site-run-file nil
      ;; MEGA byte-compiles its own Lisp.  Preferring the newer of .el/.elc
      ;; costs one stat per load and means editing a module never silently
      ;; runs yesterday's compiled copy.
      load-prefer-newer t)

;;; early-init.el ends here
