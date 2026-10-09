;;; mega-remote.el --- Editing files on another machine  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs opens a file on another machine when its name says so:
;;
;;   C-x C-f /ssh:user@host:/path/to/file
;;   C-x C-f /sudo::/etc/hosts
;;   C-x C-f /podman:container:/path
;;
;; That is TRAMP, and it is built in.  It works without any of this; the
;; settings below are what keeps it quick and quiet, and they are set before
;; TRAMP loads, which happens the first time you open such a file.
;;
;; Two of them are safety trade-offs, made on purpose:
;;
;; * No lock files on the remote machine.  A lock is a round trip per first
;;   keystroke; the price is that two people editing the same remote file are
;;   not warned.  Set `remote-file-name-inhibit-locks' to nil if that is you.
;;
;; * Backups and auto-saves of remote files are kept on this machine, with
;;   all the others, so a dropped connection never costs you work.

;;; Code:

(require 'mega-lib)

(defvar tramp-default-method)
(defvar tramp-persistency-file-name)
(defvar tramp-verbose)
(defvar tramp-histfile-override)

(setq
 ;; One connection carries everything.  The default, scp, starts a second
 ;; program for every file larger than a few kilobytes.
 tramp-default-method "ssh"
 ;; What TRAMP learns about a machine is a list of your hosts and user names:
 ;; it stays in a directory only you can read.
 tramp-persistency-file-name (mega-cache "tramp")
 ;; Errors and warnings only.  Raise it to 6 to see what TRAMP is doing.
 tramp-verbose 1
 ;; The commands TRAMP types into the remote shell are not yours: do not
 ;; leave them in a history file on a machine you may not own.
 tramp-histfile-override t
 remote-file-name-inhibit-locks t)

;;;; What is too slow to do over a network
;;
;; Emacs asks eight version-control systems, one after another, whether they
;; know each file you open; over a network each question is a round trip.
;; Remotely only git is asked.  That keeps what depends on it working there:
;; the branch in the modeline, and finding the root of a project.

(defconst mega-remote-profile
  '((vc-handled-backends . (Git)))
  "Variables that get these values in the buffers of remote files.")

(with-eval-after-load 'tramp
  (connection-local-set-profile-variables 'mega-remote mega-remote-profile)
  (connection-local-set-profiles '(:application tramp) 'mega-remote))

(provide 'mega-remote)
;;; mega-remote.el ends here
