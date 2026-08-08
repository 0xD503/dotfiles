;;; mega-core.el --- Encoding, files, security, sane defaults  -*- lexical-binding: t; -*-

;;; Commentary:

;; The settings that should be true before any other module runs.  If you are
;; looking for where to change a global default, it is here.

;;; Code:

(require 'mega-lib)

;;;; Identity

(setq user-full-name "Ruslan Vostretsov"
      user-mail-address "antanta.twwk@gmail.com")

;;;; Encoding
;;
;; UTF-8 and Unix line endings everywhere, including the terminal and the
;; clipboard.  `mega-edit' handles the file-local side (existing CRLF files are
;; preserved rather than silently rewritten).

(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8-unix)
(set-default-coding-systems 'utf-8-unix)
(set-terminal-coding-system 'utf-8-unix)
(set-keyboard-coding-system 'utf-8-unix)
(setq locale-coding-system 'utf-8-unix
      default-process-coding-system '(utf-8-unix . utf-8-unix))

;;;; Files: backups, auto-saves, locks
;;
;; All of it goes to the cache directory.  Backups are real protection and stay
;; on; what changes is that they never litter a project tree.

(setq backup-directory-alist         `(("." . ,(mega-cache "backup/")))
      auto-save-list-file-prefix     (mega-cache "auto-save/list-")
      auto-save-file-name-transforms `((".*" ,(mega-cache "auto-save/") t))
      lock-file-name-transforms      `((".*" ,(mega-cache "lock/") t))
      backup-by-copying t          ; never break a hardlink or a symlink
      version-control t
      delete-old-versions t
      kept-new-versions 6
      kept-old-versions 2
      auto-save-default t
      auto-save-timeout 20
      auto-save-interval 200
      create-lockfiles t)          ; concurrent-edit protection is worth keeping

;; Custom must never rewrite a tracked file.
(setq custom-file (mega-state "custom.el"))
(when (file-readable-p custom-file)
  (load custom-file :noerror :nomessage))

;;;; Security
;;
;; A cloned repository must not be able to run code just because you opened a
;; file in it.  `:safe' allows only variables Emacs already knows are harmless,
;; and `enable-local-eval' nil refuses `eval:' forms outright.  Both are
;; deliberate: dir-locals are a supply-chain surface.
;;
;; The network variables are set before their libraries load, on purpose: a
;; `defvar' does not overwrite a value that already exists, so this guarantees
;; the safe setting is in place before the first connection rather than after.
;; The byte-compiler cannot see that, hence the declarations.

(defvar gnutls-verify-error)
(defvar gnutls-min-prime-bits)
(defvar network-security-level)
(defvar nsm-settings-file)
(defvar ange-ftp-generate-anonymous-password)

(setq enable-local-variables :safe
      enable-local-eval nil
      ;; Refuse to talk to a server whose certificate does not verify, rather
      ;; than downgrading and warning.
      gnutls-verify-error t
      gnutls-min-prime-bits 2048
      network-security-level 'medium
      nsm-settings-file (mega-state "network-security.data")
      ;; Never send the real address as an anonymous FTP password.
      ange-ftp-generate-anonymous-password nil)

;;;; Surviving large and pathological files

(setq large-file-warning-threshold (* 64 1024 1024)
      ;; Long lines are the classic Emacs hang; both of these are cheap.
      bidi-inhibit-bpa t
      bidi-paragraph-direction 'left-to-right)
(setq-default bidi-display-reordering 'left-to-right)

(use-package so-long
  :config (global-so-long-mode 1))

;;;; General behaviour

(setq use-short-answers t                  ; y/n instead of yes/no
      ring-bell-function #'ignore
      visible-bell nil
      confirm-kill-emacs nil               ; as you have it in Doom today
      confirm-kill-processes nil
      require-final-newline t
      sentence-end-double-space nil
      what-cursor-show-names t
      uniquify-buffer-name-style 'forward
      kill-do-not-save-duplicates t
      save-interprogram-paste-before-kill t
      mouse-yank-at-point t
      scroll-conservatively 101            ; never recentre on scroll
      scroll-margin 3
      scroll-preserve-screen-position t
      fast-but-imprecise-scrolling t
      hscroll-step 1
      hscroll-margin 2
      select-enable-clipboard t
      history-length 1000
      auto-revert-verbose nil
      global-auto-revert-non-file-buffers t)

(setq-default indent-tabs-mode nil
              tab-width 4
              fill-column 80)

;; Files changed underneath you (a rebase, a formatter) should just update.
(global-auto-revert-mode 1)

;; Terminal Emacs has no system clipboard of its own; xclip bridges it when a
;; display is reachable.  Absent that, kills stay inside Emacs — no error.
(use-package xclip
  :ensure t
  :if (and (not (display-graphic-p)) (or (mega-exe-p "xclip") (mega-exe-p "wl-copy")))
  :config (xclip-mode 1))

(defcustom mega-enable-kkp nil
  "Negotiate the Kitty keyboard protocol at startup.
It lets a supporting terminal tell `C-.' from `C-,', `C-RET' from `RET',
and so on — genuinely useful where it works.

Off by default because it is not free: `global-kkp-mode' queries the
terminal and blocks until it answers or times out, which measured 250 ms
here — two thirds of MEGA's entire startup.  tmux does not forward that
query by default, so the usual result under tmux is a quarter-second tax
for no new keys.  Set it to t in local.el if your terminal answers."
  :type 'boolean
  :group 'mega)

(use-package kkp
  :ensure t
  :if (and mega-enable-kkp (not (display-graphic-p)))
  :config (global-kkp-mode 1))

(provide 'mega-core)
;;; mega-core.el ends here
