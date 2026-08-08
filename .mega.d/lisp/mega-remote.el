;;; mega-remote.el --- tramp  -*- lexical-binding: t; -*-

;;; Commentary:

;; tramp is fine by default until something walks a remote tree.  The settings
;; here exist to stop version control, project indexing and lock files from
;; turning every keystroke in a remote buffer into a round trip.

;;; Code:

(require 'mega-lib)

(use-package tramp
  :defer t
  :custom
  (tramp-default-method "ssh")           ; scp's default is slower for small files
  (tramp-persistency-file-name (mega-cache "tramp"))
  (tramp-verbose 1)                      ; 3 is chatty; raise it when debugging
  (tramp-use-scp-direct-remote-copying t)
  (remote-file-name-inhibit-locks t)     ; lock files over the network are pure latency
  (tramp-completion-reread-directory-timeout 60)
  :config
  ;; Respect ~/.ssh/config: if you already multiplex there, tramp adding its
  ;; own ControlMaster options fights it.
  (when (boundp 'tramp-use-connection-share)
    (setq tramp-use-connection-share 'suppress))

  ;; The expensive things, disabled only for remote buffers.
  (connection-local-set-profile-variables
   'mega-remote-profile
   '((vc-handled-backends . nil)
     (projectile-enable-caching . nil)
     (find-file-visit-truename . nil)
     (inhibit-file-name-operation . nil)))
  (connection-local-set-profiles '(:application tramp) 'mega-remote-profile)

  ;; Never let tramp's own buffers count as recent files or projects.
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path))

(provide 'mega-remote)
;;; mega-remote.el ends here
