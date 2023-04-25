;;
(require 'package)

(add-to-list 'package-archives '("elpa" . "https://elpa.org/packages/") t)
;(add-to-list 'package-archives '("melpa-stable" . "https://stable.melpa.org/packages/") t)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

;; Added by Package.el.  This must come before configurations of
;; installed packages.  Don't delete this line.  If you don't want it,
;; just comment it out by adding a semicolon to the start of the line.
;; You may delete these explanatory comments.
(package-initialize)

(unless (package-installed-p 'use-package)
  (package-install 'use-package))

(require 'use-package)
(setq use-package-always-ensure t)

;; load custom load path, where custom files for Emacs will be placed
(add-to-list 'load-path "~/.emacs.d/custom")

;(require 'setup-helm)
(require 'fill-column-indicator)
(require 'smartscan)

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(custom-enabled-themes (quote (wheatgrass)))
 '(indent-tabs-mode nil)
 '(package-selected-packages
   (quote
    (treemacs-projectile treemacs-icons-dired treemacs-all-the-icons treemacs helm-fuzzier helm-flymake helm-dictionary helm helm-lsp setup smartscan helm-rg)))
 '(show-trailing-whitespace t))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )



;; line numbers
(global-linum-mode)

;; keybindings
(global-set-key (kbd "C-M-[") 'shrink-window-horizontally)
(global-set-key (kbd "C-M-]") 'enlarge-window-horizontally)
(global-set-key (kbd "M-g a") 'helm-rg)

;(put 'upcase-region 'disabled nil)
;(put 'downcase-region 'disabled nil)

;; tabs/spaces/indentation settings
;(setq-default indent-tabs-mode nil)
(defvaralias 'c-default-offset 'tab-width)
(defvaralias 'cperl-indent-level 'tab-width)
(setq-default show-trailing-whitespace t)
;;; trim whitespaces
;(add-hook 'before-save-hook 'delete-trailing-whitespace)

;; 80-column ruller
(set-fill-column 80)
(add-hook 'prog-mode-hook #'fci-mode)

;; enable auto-indentation globally
(define-key global-map (kbd "RET") 'newline-and-indent)

(global-smartscan-mode 1)
(setq-default c-basic-offset 4)



;; tags management
(defun create-etags (project-dir-name)
  "Create tags file using etags."
  (interactive "Project root directory: ")
  (eshell-command
   (format "find %s -type f -iname \"*.c\" -o -iname \"*.h\" -o -iname \"*.cpp\" -o -iname \"*.hpp\" -o -iname \"*.cc\" -not -path \"./out/*\" | etags -" project-dir-name)))
