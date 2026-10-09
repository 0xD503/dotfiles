;;; local.el --- Machine-specific MEGA settings  -*- lexical-binding: t; -*-

;;; Commentary:

;; This file is tracked as a stub and left alone by every plain update.sh
;; command, exactly like .bashrc.local: deploying it would clobber whatever
;; this machine keeps here, and collecting it would push one machine's
;; overrides to every other.  `./update.sh local user' installs it once.
;;
;; It loads BEFORE the modules, because its main job is choosing.  Anything
;; that has to run after a module has loaded goes in `with-eval-after-load',
;; which works regardless of ordering.
;;
;; Examples — all commented out:
;;
;;   ;; A different line-length limit, and so a different ruler, by default.
;;   ;; A project's .editorconfig still overrides it.
;;   (setq-default fill-column 100)
;;
;;   ;; No ruler in prose.
;;   (with-eval-after-load 'mega-ui
;;     (remove-hook 'text-mode-hook #'mega-ui-ruler))
;;
;;   ;; One more kind of file MEGA must not remember.
;;   (add-to-list 'mega-private-file-regexps "/vault/")

;;; Code:



;;; local.el ends here
