;; package system settings
(require 'package)
;(add-to-list 'package-archives '("elpa" . "https://elpa.org/packages/") t)
(add-to-list 'package-archives '("melpa-stable" . "https://stable.melpa.org/packages/") t)
;(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

(package-initialize)


;; theme/color settings
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
 '(display-time-mode t)
 '(fci-rule-color "#4C566A")
 '(global-linum-mode t)
 '(package-selected-packages '(ws-butler chess nordless-theme nord-theme jabber))
 '(ps-font-size '(17 . 18.5))
 '(show-paren-mode t))

(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(default ((t (:inherit nil :extend nil :stipple nil :background "black" :foreground "wheat" :inverse-video nil :box nil :strike-through nil :overline nil :underline nil :slant normal :weight normal :height 143 :width normal :foundry "Bits" :family "Bitstream Vera Sans")))))



;; custom functions

;; supercharged ido version of imenu
(defun ido-goto-symbol (&optional symbol-list)
  "Refresh imenu and jump to a place in the buffer using Ido."
  (interactive)
  (unless (featurep 'imenu)
    (require 'imenu nil t))
  (cond
   ((not symbol-list)
    (let ((ido-mode ido-mode)
          (ido-enable-flex-matching
           (if (boundp 'ido-enable-flex-matching)
               ido-enable-flex-matching t))
          name-and-pos symbol-names position)
      (unless ido-mode
        (ido-mode 1)
        (setq ido-enable-flex-matching t))
      (while (progn
               (imenu--cleanup)
               (setq imenu--index-alist nil)
               (ido-goto-symbol (imenu--make-index-alist))
               (setq selected-symbol
                     (ido-completing-read "Symbol? " symbol-names))
               (string= (car imenu--rescan-item) selected-symbol)))
      (unless (and (boundp 'mark-active) mark-active)
        (push-mark nil t nil))
      (setq position (cdr (assoc selected-symbol name-and-pos)))
      (cond
       ((overlayp position)
        (goto-char (overlay-start position)))
       (t
        (goto-char position)))))
   ((listp symbol-list)
    (dolist (symbol symbol-list)
      (let (name position)
        (cond
         ((and (listp symbol) (imenu--subalist-p symbol))
          (ido-goto-symbol symbol))
         ((listp symbol)
          (setq name (car symbol))
          (setq position (cdr symbol)))
         ((stringp symbol)
          (setq name symbol)
          (setq position
                (get-text-property 1 'org-imenu-marker symbol))))
        (unless (or (null position) (null name)
                    (string= (car imenu--rescan-item) name))
          (add-to-list 'symbol-names name)
          (add-to-list 'name-and-pos (cons name position))))))))



;; advanced command bindings
(put 'upcase-region 'disabled nil)
(put 'downcase-region 'disabled nil)


;; global key bindings
(global-set-key (kbd "M-i") 'ido-goto-symbol)


;; turn on IDO mode
(ido-mode 1)
(setq ido-enable-flex-matching t)
(setq ido-everywhere t)

;; tabs/spaces/indentation settings
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)
(defvaralias 'c-default-offset 'tab-width)
(defvaralias 'cperl-indent-level 'tab-width)
(setq-default show-trailing-whitespace t)
;; trim whitespaces
(add-hook 'before-save-hook 'delete-trailing-whitespace)
;; 80-column ruller
(add-hook 'prog-mode-hook #'display-fill-column-indicator-mode)

;; enable auto-indentation globally
(define-key global-map (kbd "RET") 'newline-and-indent)


;; IDE settings

;; TAGS support
(require 'etags)
(defun ido-find-tag ()
  "Find tag using ido"
  (interactive)
  (tags-completion-table)
  (let (tag-names)
    (mapc (lambda (x)
            (unless (integerp x)
              (push (prin1-to-string x t) tag-names)))
          tags-completion-table)
    (find-tag (ido-completing-read "Tag: " tag-names))))

(defun ido-find-file-in-tag-files ()
  (interactive)
  (save-excursion
    (let ((enable-recursive-minibuffers t))
      (visit-tags-table-buffer))
    (find-file
     (expand-file-name
      (ido-completing-read
       "Project file: " (tags-table-files) nil t)))))

(global-set-key [remap find-tag] 'ido-find-tag)
;(global-set-key (kbd "C-." 'ido-find-file-in-tag-files)


;; load custom load path, where custom files for Emacs will be placed
(add-to-list 'load-path "~/.emacs.d/custom/")
