;;; mega-core.el --- Encoding, files, safety, privacy, security  -*- lexical-binding: t; -*-

;;; Commentary:

;; The settings that should be true before any other module runs.  If you are
;; looking for where to change a global default, it is here.
;;
;; MEGA's priorities are, in order: safety, privacy, security, stability,
;; extensibility, maintainability, performance.  Most of what that ordering
;; decides is decided in this file, and each section says which one it serves.

;;; Code:

(require 'mega-lib)

;;;; Encoding
;;
;; UTF-8 and Unix line endings everywhere, including the terminal and the
;; clipboard.  A file that already has CRLF endings keeps them: these are
;; defaults for new text, not a rewrite of what exists.

(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8-unix)
(set-default-coding-systems 'utf-8-unix)
(set-terminal-coding-system 'utf-8-unix)
(set-keyboard-coding-system 'utf-8-unix)
(setq locale-coding-system 'utf-8-unix
      default-process-coding-system '(utf-8-unix . utf-8-unix))

;;;; Safety: never lose or damage your work
;;
;; Backups, auto-saves and lock files all stay on, and all go to the cache
;; directory so they never litter a project tree.  The file names are hashed:
;; a deep path would otherwise produce a name too long to create, and a backup
;; that silently fails is worse than none.

(setq backup-directory-alist         `(("." . ,(mega-cache "backup/")))
      auto-save-list-file-prefix     (mega-cache "auto-save/list-")
      auto-save-file-name-transforms `((".*" ,(mega-cache "auto-save/") sha1))
      lock-file-name-transforms      `((".*" ,(mega-cache "lock/") sha1))
      make-backup-files t
      backup-by-copying t          ; never break a hardlink or a symlink
      version-control t
      delete-old-versions t
      kept-new-versions 6
      kept-old-versions 2
      auto-save-default t
      auto-save-timeout 20
      auto-save-interval 200
      create-lockfiles t           ; concurrent-edit protection is worth keeping
      ;; Deleting a file from Emacs moves it to the trash.  Remote files are
      ;; the exception: trashing one means downloading it first.
      delete-by-moving-to-trash t
      remote-file-name-inhibit-delete-by-moving-to-trash t)

;; Files changed underneath you (a rebase, a formatter) should just update.
;; Auto-revert never touches a buffer with unsaved changes.
(defvar auto-revert-verbose)
(defvar global-auto-revert-non-file-buffers)

(setq auto-revert-verbose nil
      global-auto-revert-non-file-buffers t)
(mega-after-startup #'global-auto-revert-mode)

;; `custom-file' was pointed at the state directory in init.el.
(when (file-readable-p custom-file)
  (load custom-file :noerror :nomessage))

;;;; Privacy: nothing leaves the machine unless you ask
;;
;; MEGA opens no network connection and installs nothing.  What is left to
;; decide here is what Emacs itself may write down or look up.

(defvar auth-source-save-behavior)

(setq
 ;; Never offer to store a password you typed in a plain-text file.
 auth-source-save-behavior nil
 ;; No dictionary lookups while typing.  Emacs 30 added word completion from
 ;; the spelling dictionary to every text buffer; MEGA has no spell or grammar
 ;; checking at all, and this is the one piece that is on by default.
 text-mode-ispell-word-completion nil)

;;;; Security: a cloned repository cannot run code by being opened
;;
;; `:safe' accepts only file-local variables Emacs already knows are harmless
;; and silently ignores the rest; `enable-local-eval' nil refuses `eval:'
;; forms outright.  Both are deliberate: dir-locals are a supply-chain surface.
;;
;; The network variables are set before their libraries load, on purpose: a
;; `defvar' does not overwrite a value that already exists, so the safe
;; setting is in place before the first connection rather than after.  The
;; byte-compiler cannot see that, hence the declarations.

(defvar gnutls-verify-error)
(defvar gnutls-min-prime-bits)
(defvar network-security-level)
(defvar nsm-settings-file)
(defvar ange-ftp-generate-anonymous-password)
(defvar compilation-read-command)

(setq enable-local-variables :safe
      enable-local-eval nil
      enable-remote-dir-locals nil
      ;; Emacs counts a project's `compile-command' as safe, but only because
      ;; `compile' shows the command and waits for RET before running it.
      ;; That confirmation is therefore part of the security model: pin it.
      compilation-read-command t
      ;; Refuse a server whose certificate does not verify, rather than
      ;; downgrading and warning.
      gnutls-verify-error t
      gnutls-min-prime-bits 2048
      network-security-level 'medium
      nsm-settings-file (mega-state "network-security.data")
      ;; Never send the real address as an anonymous FTP password.
      ange-ftp-generate-anonymous-password nil)

;;;; Stability: surviving large and pathological files

(setq large-file-warning-threshold (* 64 1024 1024)
      ;; Long lines are the classic Emacs hang; both of these are cheap.
      bidi-inhibit-bpa t)
(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)

(global-so-long-mode 1)

;;;; Project conventions
;;
;; These are the defaults.  A project's .editorconfig then overrides them per
;; buffer — indentation, line endings, the final newline, trailing whitespace
;; and the line-length limit — so the project always wins.

;; All four become buffer-local when set, so a plain `setq' would change only
;; whichever buffer happened to be current during startup.
(setq-default indent-tabs-mode nil
              tab-width 4
              fill-column 80
              require-final-newline t)

(editorconfig-mode 1)

;;;; General behaviour

(setq use-short-answers t                  ; y/n instead of yes/no
      ring-bell-function #'ignore
      visible-bell nil
      ;; Quitting still asks about unsaved buffers and running processes;
      ;; only the extra "really quit?" is dropped.
      confirm-kill-emacs nil
      sentence-end-double-space nil
      what-cursor-show-names t
      uniquify-buffer-name-style 'forward
      kill-do-not-save-duplicates t
      save-interprogram-paste-before-kill t
      mouse-yank-at-point t
      scroll-conservatively 101            ; never recentre on scroll
      scroll-margin 3
      scroll-preserve-screen-position t
      hscroll-step 1
      hscroll-margin 2
      history-length 1000
      history-delete-duplicates t)

(provide 'mega-core)
;;; mega-core.el ends here
