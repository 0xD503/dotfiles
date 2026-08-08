;;; mega-completion.el --- Minibuffer and in-buffer completion  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two minibuffer backends live here, selected by `mega-completion-backend'.
;; Only the chosen one is installed and loaded.
;;
;; The important invariant: no keybinding depends on which one is active.  Keys
;; are bound (in mega-keys.el) to the `mega-*' commands below, and those
;; dispatch.  Flipping the backend and restarting must change how things look
;; and nothing about what keys do.  That invariant is the whole justification
;; for having two code paths, so it is worth checking after any edit here.
;;
;; In-buffer completion is corfu in both cases — helm does not do
;; completion-at-point, so it is not a fork.

;;; Code:

(require 'mega-lib)
(require 'mega-keys)   ; embark binds into `mega-keys-mode-map'

(defcustom mega-completion-backend 'helm
  "Which minibuffer completion UI MEGA uses.
`helm' keeps the interface you already know.  `vertico' is roughly a
tenth of the code and noticeably quicker, built directly on Emacs'
`completing-read'.  Set this in local.el and restart."
  :type '(choice (const :tag "Helm" helm)
                 (const :tag "Vertico + Consult + Orderless" vertico))
  :group 'mega)

(defun mega-completion-helm-p () "Non-nil when helm is the active backend." (eq mega-completion-backend 'helm))
(defun mega-completion-vertico-p () "Non-nil when vertico is the active backend." (eq mega-completion-backend 'vertico))

(defun mega--with-initial-input (input command)
  "Call COMMAND interactively with INPUT pre-inserted in the minibuffer.
Works for helm and for `completing-read' alike, because both read their
pattern from the minibuffer."
  (if (null input)
      (call-interactively command)
    (minibuffer-with-setup-hook (lambda () (insert input))
      (call-interactively command))))

;;;; Backend: helm

(use-package helm
  :ensure t
  :if (mega-completion-helm-p)
  :commands (helm-M-x helm-find-files helm-mini helm-imenu
             helm-show-kill-ring helm-do-grep-ag helm-occur)
  :custom
  (helm-echo-input-in-header-line t)
  (helm-split-window-inside-p t)
  (helm-move-to-line-cycle-in-source nil)
  (helm-scroll-amount 8)
  (helm-display-header-line nil)
  (helm-completion-style 'helm)
  (helm-candidate-number-limit 200)
  ;; helm ships its own ripgrep support and picks rg up automatically when it
  ;; is on PATH, which it is here.  helm-rg is a separate, unmaintained package
  ;; that MEGA deliberately does not use.
  (helm-grep-file-path-style 'relative)
  (helm-follow-mode-persistent t)
  :config
  (require 'helm-autoloads nil t)
  (helm-mode 1))

(use-package helm-flx
  :ensure t
  :if (mega-completion-helm-p)
  :after helm
  :config (helm-flx-mode 1))

;; helm-icons is not on any package archive — it has no MELPA recipe, which is
;; why Doom installs it from a git recipe.  package-vc does the same job.
(use-package helm-icons
  :vc (:url "https://github.com/yyoncho/helm-icons" :rev :newest)
  :if (mega-completion-helm-p)
  :after helm
  :custom (helm-icons-provider 'nerd-icons)  ; not all-the-icons: works in a TTY
  :config (helm-icons-enable))

;;;; Backend: vertico

(use-package vertico
  :ensure t
  :if (mega-completion-vertico-p)
  :custom
  (vertico-cycle t)
  (vertico-count 15)
  (vertico-resize nil)
  :config (vertico-mode 1))

(use-package orderless
  :ensure t
  :if (mega-completion-vertico-p)
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))

(use-package marginalia
  :ensure t
  :if (mega-completion-vertico-p)
  :config (marginalia-mode 1))

(use-package nerd-icons-completion
  :ensure t
  :if (mega-completion-vertico-p)
  :after marginalia
  :config
  (nerd-icons-completion-mode 1)
  (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup))

(use-package consult
  :ensure t
  :if (mega-completion-vertico-p)
  :commands (consult-ripgrep consult-buffer consult-imenu consult-yank-pop consult-line)
  :custom
  (consult-narrow-key "<")
  (xref-show-xrefs-function #'consult-xref)
  (xref-show-definitions-function #'consult-xref))

(use-package embark
  :ensure t
  :if (mega-completion-vertico-p)
  :bind (:map mega-keys-mode-map
         ("C-." . embark-act)
         ("C-h B" . embark-bindings)))

(use-package embark-consult
  :ensure t
  :if (mega-completion-vertico-p)
  :after (embark consult))

;;;; The dispatch layer
;;
;; Six commands.  This is the entire cost of supporting two backends.

(defun mega-execute-command ()
  "Run a command (M-x)."
  (interactive)
  (if (mega-completion-helm-p)
      (call-interactively #'helm-M-x)
    (call-interactively #'execute-extended-command)))

(defun mega-find-file ()
  "Open a file."
  (interactive)
  (if (mega-completion-helm-p)
      (call-interactively #'helm-find-files)
    (call-interactively #'find-file)))

(defun mega-switch-buffer ()
  "Switch buffer."
  (interactive)
  (if (mega-completion-helm-p)
      (call-interactively #'helm-mini)
    (call-interactively #'consult-buffer)))

(defun mega-yank-pop ()
  "Browse the kill ring."
  (interactive)
  (if (mega-completion-helm-p)
      (call-interactively #'helm-show-kill-ring)
    (call-interactively #'consult-yank-pop)))

(defun mega-imenu ()
  "Jump to a definition in this buffer."
  (interactive)
  (if (mega-completion-helm-p)
      (call-interactively #'helm-imenu)
    (call-interactively #'consult-imenu)))

(defun mega-search-project (&optional initial)
  "Search the whole project with ripgrep, starting from INITIAL.
Bound to \\[mega-search-project]."
  (interactive)
  (let ((default-directory (or (mega-project-root) default-directory)))
    (if (mega-completion-helm-p)
        (mega--with-initial-input initial #'helm-do-grep-ag)
      (consult-ripgrep default-directory initial))))

(defun mega-search-symbol-at-point ()
  "Search the project for the symbol under point."
  (interactive)
  (mega-search-project (thing-at-point 'symbol t)))

;;;; In-buffer completion (both backends)

(use-package corfu
  :ensure t
  :custom
  (corfu-auto t)
  (corfu-auto-delay 0.15)
  (corfu-auto-prefix 2)
  (corfu-cycle t)
  (corfu-preselect 'prompt)
  (corfu-quit-no-match 'separator)
  (corfu-on-exact-match nil)
  :config
  (global-corfu-mode 1)
  (corfu-history-mode 1)
  ;; Completing with TAB, and letting TAB indent when there is nothing to
  ;; complete, is what makes corfu feel native.
  (setq tab-always-indent 'complete
        text-mode-ispell-word-completion nil
        read-extended-command-predicate #'command-completion-default-include-p))

;; corfu draws with child frames, which do not exist in a terminal.
;; corfu-terminal re-implements the popup over popon — the same overlay layer
;; MEGA uses for documentation popups.
(use-package corfu-terminal
  :ensure t
  :if (not (display-graphic-p))
  :after corfu
  :config (corfu-terminal-mode 1))

(use-package nerd-icons-corfu
  :ensure t
  :after corfu
  :config (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))

(use-package cape
  :ensure t
  :init
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-dabbrev)
  :custom
  (cape-dabbrev-min-length 3)
  (dabbrev-ignored-buffer-regexps '("\\` " "\\`\\*.*\\*\\'")))

;; corfu-popupinfo is child-frame based and therefore useless in a terminal.
;; `corfu-info-documentation' (bound to M-h in corfu-map) opens a real buffer
;; and works everywhere, so that is the documented route.

(provide 'mega-completion)
;;; mega-completion.el ends here
