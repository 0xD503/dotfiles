;; package system settings
(require 'package)
;(add-to-list 'package-archives '("elpa" . "https://elpa.org/packages/") t)
(add-to-list 'package-archives '("melpa-stable" . "https://stable.melpa.org/packages/") t)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

(package-initialize)


(when (not package-archive-contents)
    (package-refresh-contents))

(unless (package-installed-p 'use-package)
  (package-install 'use-package))

(require 'use-package)
(setq use-package-always-ensure t)

;; load custom load path, where custom files for Emacs will be placed
(add-to-list 'load-path "~/.emacs.d/custom")

;; #############################################################################


(require 'setup-general)
(require 'setup-helm)
(require 'setup-helm-gtags)
;(require 'setup-ggtags)

(require 'setup-cedet)
(require 'setup-editing)



;; #############################################################################

(setq
 helm-gtags-ignore-case t
 helm-gtags-auto-update t
 helm-gtags-use-input-at-cursor t
 helm-gtags-pulse-at-cursor t
 helm-gtags-prefix-key "\C-cg"
 helm-gtags-suggested-key-mapping t
 )

(require 'helm-gtags)
;; Enable helm-gtags-mode
(add-hook 'dired-mode-hook 'helm-gtags-mode)
(add-hook 'eshell-mode-hook 'helm-gtags-mode)
(add-hook 'c-mode-hook 'helm-gtags-mode)
(add-hook 'c++-mode-hook 'helm-gtags-mode)
(add-hook 'asm-mode-hook 'helm-gtags-mode)

(define-key helm-gtags-mode-map (kbd "C-c g a") 'helm-gtags-tags-in-this-function)
(define-key helm-gtags-mode-map (kbd "C-j") 'helm-gtags-select)
(define-key helm-gtags-mode-map (kbd "M-.") 'helm-gtags-dwim)
(define-key helm-gtags-mode-map (kbd "M-,") 'helm-gtags-pop-stack)
(define-key helm-gtags-mode-map (kbd "C-c <") 'helm-gtags-previous-history)
(define-key helm-gtags-mode-map (kbd "C-c >") 'helm-gtags-next-history)


;; #############################################################################


;; #############################################################################

;(require 'auto-complete)
;(require 'auto-complete-config)
;(ac-config-default)

;(require 'yasnippet)
;(yas-global-mode 1)

;;; init C headers autocompletion in C/C++ mode
;(defun my:ac-c-header-init()
;  (require 'auto-complete-c-headers)
;  (add-to-list 'ac-sources 'ac-source-c-headers)
;  (add-to-list 'achead:include-directories "path/to/gcc/lib/dir"))
;
;(add-hook 'c-mode-hook 'my:ac-c-header-init)
;(add-hook 'c++-mode-hook 'my:ac-c-header-init)


;; restore menubar, etc...
(defun restore-window-items()
  (interactive)
  (if (fboundp 'scroll-bar-mode) (scroll-bar-mode 1))
  (if (fboundp 'menu-bar-mode) (menu-bar-mode 1)))

(restore-window-items)


;; key bindings
(global-set-key (kbd "C-M-[") 'shrink-window-horizontally)
(global-set-key (kbd "C-M-]") 'enlarge-window-horizontally)
;(global-set-key (kbd "M-o") 'ace-window)
(global-set-key (kbd "M-s o") 'helm-do-ag)

;; CEDET
(semantic-mode 1)

;(setq speedbar-show-unknown-files t)

;; #############################################################################


;; #################################################
(require 'company)

(add-hook 'after-init-hook 'global-company-mode)
(add-to-list 'company-backends 'company-c-headers)
;; #################################################


;; #######################################
(require 'cc-mode)
(require 'semantic)

(global-semanticdb-minor-mode 1)
(global-semantic-idle-scheduler-mode 1)

(semantic-mode 1)
;; #######################################


;; function-args
;; (require 'function-args)
;; (fa-config-default)
;; (define-key c-mode-map  [(tab)] 'company-complete)
;; (define-key c++-mode-map  [(tab)] 'company-complete)
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(ansi-color-faces-vector
   [default default default italic underline success warning error])
 '(ansi-color-names-vector
   ["#242424" "#e5786d" "#95e454" "#cae682" "#8ac6f2" "#333366" "#ccaa8f" "#f6f3e8"])
 '(column-number-mode t)
 '(custom-enabled-themes '(wheatgrass))
 '(custom-safe-themes
   '("0511293cecfff89edd24781b0c31b42ee8017ae3a53c292befd51ac94a63c031" "197cefea731181f7be51e9d498b29fb44b51be33484b17416b9855a2c4243cb1" default))
 '(display-battery-mode t)
 '(display-line-numbers-type 'relative)
 '(display-time-mode t)
 '(fci-rule-color "#4C566A")
 '(global-linum-mode t)
 '(indent-tabs-mode nil)
 '(inhibit-startup-screen nil)
 '(package-selected-packages
   '(neotree company-c-headers sr-speedbar function-args fzf helm-ag ace-window avy helm-swoop helm-gtags helm iedit anzu comment-dwim-2 dtrt-indent clean-aindent-mode yasnippet undo-tree volatile-highlights ggtags zygospore projectile company use-package ws-butler chess nordless-theme nord-theme jabber))
 '(ps-font-size '(17 . 18.5))
 '(show-paren-mode t)
 '(show-trailing-whitespace t)
 '(tab-width 4))

(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(default ((t (:inherit nil :extend nil :stipple nil :background "black" :foreground "wheat" :inverse-video nil :box nil :strike-through nil :overline nil :underline nil :slant normal :weight normal :height 143 :width normal :foundry "Bits" :family "Bitstream Vera Sans")))))



;; custom functions

;; ;; supercharged ido version of imenu
;; (defun ido-goto-symbol (&optional symbol-list)
;;   "Refresh imenu and jump to a place in the buffer using Ido."
;;   (interactive)
;;   (unless (featurep 'imenu)
;;     (require 'imenu nil t))
;;   (cond
;;    ((not symbol-list)
;;     (let ((ido-mode ido-mode)
;;           (ido-enable-flex-matching
;;            (if (boundp 'ido-enable-flex-matching)
;;                ido-enable-flex-matching t))
;;           name-and-pos symbol-names position)
;;       (unless ido-mode
;;         (ido-mode 1)
;;         (setq ido-enable-flex-matching t))
;;       (while (progn
;;                (imenu--cleanup)
;;                (setq imenu--index-alist nil)
;;                (ido-goto-symbol (imenu--make-index-alist))
;;                (setq selected-symbol
;;                      (ido-completing-read "Symbol? " symbol-names))
;;                (string= (car imenu--rescan-item) selected-symbol)))
;;       (unless (and (boundp 'mark-active) mark-active)
;;         (push-mark nil t nil))
;;       (setq position (cdr (assoc selected-symbol name-and-pos)))
;;       (cond
;;        ((overlayp position)
;;         (goto-char (overlay-start position)))
;;        (t
;;         (goto-char position)))))
;;    ((listp symbol-list)
;;     (dolist (symbol symbol-list)
;;       (let (name position)
;;         (cond
;;          ((and (listp symbol) (imenu--subalist-p symbol))
;;           (ido-goto-symbol symbol))
;;          ((listp symbol)
;;           (setq name (car symbol))
;;           (setq position (cdr symbol)))
;;          ((stringp symbol)
;;           (setq name symbol)
;;           (setq position
;;                 (get-text-property 1 'org-imenu-marker symbol))))
;;         (unless (or (null position) (null name)
;;                     (string= (car imenu--rescan-item) name))
;;           (add-to-list 'symbol-names name)
;;           (add-to-list 'name-and-pos (cons name position))))))))

;; (global-set-key (kbd "M-i") 'ido-goto-symbol)

;; ;; turn on IDO mode
;; (ido-mode 1)
;; (setq ido-enable-flex-matching t)
;; (setq ido-everywhere t)


;; advanced command bindings
(put 'upcase-region 'disabled nil)
(put 'downcase-region 'disabled nil)


;; tabs/spaces/indentation settings
;(setq-default indent-tabs-mode nil)
(defvaralias 'c-default-offset 'tab-width)
(defvaralias 'cperl-indent-level 'tab-width)
;(setq-default show-trailing-whitespace t)
;; trim whitespaces
(add-hook 'before-save-hook 'delete-trailing-whitespace)
;; 80-column ruller
(defun set-column-ruller ()
  (display-fill-column-indicator-mode)
  (set-fill-column 80))
(add-hook 'prog-mode-hook #'set-column-ruller)

;; enable auto-indentation globally
(define-key global-map (kbd "RET") 'newline-and-indent)


;; IDE settings

;; enable smart scan mode
(global-smartscan-mode 1)

;; #############################################################################

;; #############################################################################


;; #############################################################################

;; setup "recent files" feature
(require 'recentf)
;; get rid of `find-file-read-only' and replace it with something
;; more useful.
(global-set-key (kbd "C-x C-r") 'ido-recentf-open)
;; enable recent files mode.
(recentf-mode t)
; 50 files ought to be enough.
(setq recentf-max-saved-items 50)

(defun ido-recentf-open ()
  "Use `ido-completing-read' to \\[find-file] a recent file"
  (interactive)
  (if (find-file (ido-completing-read "Find recent file: " recentf-list))
      (message "Opening file...")
    (message "Aborting")))

;; #############################################################################
