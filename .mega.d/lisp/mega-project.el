;;; mega-project.el --- Projects, the file tree, project-wide search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Projectile keeps the whole `C-c p' map you already use.  It is bound into
;; `mega-keys-mode-map' rather than the global map so MEGA's key surface stays
;; in one place.

;;; Code:

(require 'mega-lib)

(use-package projectile
  :ensure t
  ;; `C-c p' is bound in mega-keys.el and loads this on first use.  The idle
  ;; load here is so projectile-mode is running (for project detection) shortly
  ;; after startup without being on the critical path.
  :defer 1
  :custom
  (projectile-cache-file (mega-cache "projectile.cache"))
  (projectile-known-projects-file (mega-state "projectile-bookmarks.eld"))
  ;; "alien" delegates indexing to fd or git ls-files instead of walking the
  ;; tree in Lisp.  On a large repository this is the difference between
  ;; instant and several seconds, and both binaries are present here.
  (projectile-indexing-method 'alien)
  (projectile-enable-caching t)
  (projectile-sort-order 'recentf)
  (projectile-require-project-root 'prompt)
  ;; Never let projectile index a remote tree; see mega-remote.el.
  (projectile-file-exists-remote-cache-expire nil)
  :config
  (projectile-mode 1)
  (when (mega-exe-p "fd")
    (setq projectile-generic-command
          "fd . --type f --hidden --no-ignore-vcs --strip-cwd-prefix --print0")))

;; helm-projectile replaces the C-c p commands with helm equivalents, so the
;; same keys keep working when helm is the active backend.
(use-package helm-projectile
  :ensure t
  :if (mega-completion-helm-p)
  :after (helm projectile)
  :config (helm-projectile-on))

;; `mega-project-root' lives in mega-lib.el: mega-completion.el needs it too,
;; and a shared helper beats a load-order cycle between the two modules.

;;;; File tree

(use-package treemacs
  :ensure t
  :commands (treemacs treemacs-select-window treemacs-add-project-to-workspace)
  :custom
  (treemacs-persist-file (mega-state "treemacs-persist"))
  (treemacs-last-error-persist-file (mega-cache "treemacs-persist-at-last-error"))
  (treemacs-width 32)
  (treemacs-follow-after-init t)
  (treemacs-is-never-other-window t)
  (treemacs-space-between-root-nodes nil)
  ;; Git status via a subprocess is the expensive part of treemacs; "simple"
  ;; keeps the useful colouring without the deferred-worker machinery.
  (treemacs-git-mode 'simple)
  :config
  (treemacs-follow-mode 1)
  (treemacs-filewatch-mode 1))

(use-package treemacs-projectile
  :ensure t
  :after (treemacs projectile))

(use-package treemacs-nerd-icons
  :ensure t
  :after treemacs
  :config (treemacs-load-theme "nerd-icons"))

(provide 'mega-project)
;;; mega-project.el ends here
