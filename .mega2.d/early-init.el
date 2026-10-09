;;; early-init.el --- Runs before package.el and the first frame  -*- lexical-binding: t; -*-

;;; Commentary:

;; Three concerns only: whether this Emacs is new enough, where files go, and
;; what startup costs.  Nothing here is about editing text.
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

(add-to-list 'load-path
             (expand-file-name "lisp" (file-name-directory
                                       (or load-file-name buffer-file-name))))
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
