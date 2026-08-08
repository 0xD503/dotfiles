;;; mega-keys.el --- Every MEGA binding, in one keymap  -*- lexical-binding: t; -*-

;;; Commentary:

;; MEGA puts all of its bindings in a single global minor-mode keymap rather
;; than in the global map, for one concrete reason: minor-mode keymaps outrank
;; major-mode maps.  `C-c C-c' therefore means "comment" in `org-mode' and
;; `python-ts-mode' alike, which a plain `global-set-key' does not achieve.
;;
;; The trade-off is real and deliberate: this shadows `org-ctrl-c-ctrl-c',
;; `python-shell-send-buffer' and friends.  `C-c C-v' reaches whatever the
;; major mode wanted `C-c C-c' to do, and `M-x mega-keys-mode' turns the whole
;; layer off.
;;
;; Every binding is in this file, including `C-c p' — see the :filter trick
;; below, which lets a prefix key point at a keymap that does not exist yet.
;; The commands bound here are mostly `mega-*' dispatchers, so that flipping
;; `mega-completion-backend' or `mega-undo-backend' changes no key.

;;; Code:

(require 'mega-lib)

(defvar mega-keys-mode-map (make-sparse-keymap)
  "Keymap holding every binding MEGA defines.")

(defvar mega-llm-map (make-sparse-keymap)
  "Prefix map on `C-c l' for the LLM commands.")

(defvar mega-workspace-map (make-sparse-keymap)
  "Prefix map on `C-c w' for saveable workspaces.")

;;;; Escape hatch for the C-c C-c we shadow

(defun mega-major-mode-ctrl-c-ctrl-c ()
  "Run whatever `C-c C-c' would do with MEGA's keymap out of the way.
This is the escape hatch for `org-ctrl-c-ctrl-c' and friends, which
`mega-comment-dwim' shadows.

It looks the key up in the local (major-mode) map directly rather than
let-binding `mega-keys-mode' off around `key-binding': that would be a
lexical binding here, not a dynamic one, and would silently do nothing."
  (interactive)
  (let* ((keys (kbd "C-c C-c"))
         (local (current-local-map))
         (command (or (and local (lookup-key local keys))
                      (lookup-key global-map keys))))
    (if (commandp command)
        (progn
          (setq this-command command)
          (call-interactively command))
      (user-error "%s does not bind C-c C-c" major-mode))))

;;;; The bindings

(defun mega-lazy-keymap (feature symbol)
  "A prefix binding that loads FEATURE on demand and yields its SYMBOL keymap.
Lets `C-c p' point at `projectile-command-map' without loading projectile
at startup, and without the binding living next to the package."
  `(menu-item
    "" nil :filter
    ,(lambda (&optional _)
       (require feature nil :noerror)
       (and (boundp symbol) (symbol-value symbol)))))

(let ((map mega-keys-mode-map))
  ;; Completion-backend dispatchers: identical keys, either backend.
  (define-key map (kbd "M-x")     #'mega-execute-command)
  (define-key map (kbd "C-x C-f") #'mega-find-file)
  (define-key map (kbd "C-x b")   #'mega-switch-buffer)
  (define-key map (kbd "M-y")     #'mega-yank-pop)

  ;; Projects.  The whole projectile map, loaded on first use.
  (define-key map (kbd "C-c p") (mega-lazy-keymap 'projectile 'projectile-command-map))

  ;; Search and navigation
  (define-key map (kbd "M-g a") #'mega-search-project)
  (define-key map (kbd "M-g s") #'mega-search-symbol-at-point)
  (define-key map (kbd "M-g i") #'mega-imenu)

  ;; Editing
  (define-key map (kbd "C-c C-c") #'mega-comment-dwim)
  (define-key map (kbd "C-c C-v") #'mega-major-mode-ctrl-c-ctrl-c)
  (define-key map (kbd "C-x u")   #'mega-undo-visualize)

  ;; Windows.  Your two from Doom, kept exactly.
  (define-key map (kbd "M-{") #'shrink-window-horizontally)
  (define-key map (kbd "M-}") #'enlarge-window-horizontally)

  ;; Documentation.  In a terminal the doc buffer is the reliable surface;
  ;; `mega-doc-at-point' draws a real popup where popon can.
  (define-key map (kbd "C-c d") #'mega-doc-buffer)
  (define-key map (kbd "C-c D") #'mega-doc-at-point)

  ;; Files and trees
  (define-key map (kbd "C-c t") #'treemacs)

  ;; Prefixes
  (define-key map (kbd "C-c l") mega-llm-map)
  (define-key map (kbd "C-c w") mega-workspace-map))

(let ((map mega-llm-map))
  (define-key map (kbd "c") #'mega-claude)          ; Claude CLI, no API key
  (define-key map (kbd "v") #'mega-claude-send-region)
  (define-key map (kbd "l") #'mega-llm-chat)
  (define-key map (kbd "s") #'mega-llm-send)
  (define-key map (kbd "r") #'mega-llm-rewrite)
  (define-key map (kbd "q") #'mega-llm-quick)
  (define-key map (kbd "m") #'mega-llm-menu))

(let ((map mega-workspace-map))
  (define-key map (kbd "n") #'mega-workspace-new)
  (define-key map (kbd "r") #'mega-workspace-resume)
  (define-key map (kbd "s") #'mega-workspace-save)
  (define-key map (kbd "k") #'mega-workspace-kill)
  (define-key map (kbd "w") #'mega-workspace-switch)
  (define-key map (kbd "l") #'mega-workspace-list))

;;;###autoload
(define-minor-mode mega-keys-mode
  "Global minor mode carrying MEGA's keybindings.
Disable it to get stock Emacs bindings back for a moment."
  :global t
  :init-value nil
  :lighter nil
  :group 'mega
  :keymap mega-keys-mode-map)

(mega-keys-mode 1)

;; smartscan installs M-n/M-p globally, which would shadow history navigation
;; in the minibuffer.  mega-edit.el handles that; the keys are documented here
;; so this file remains the place you look for "what is M-n bound to".

(provide 'mega-keys)
;;; mega-keys.el ends here
