;;; mega-keys.el --- Every MEGA binding, in one table  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every key MEGA binds is a row of `mega-keys' below.  The keymap is built
;; from that table, and so is the cheat sheet (`C-c ?'), so the two cannot
;; drift apart: a key that is not in the table does not exist.
;;
;; The bindings live in a global minor-mode keymap rather than the global map,
;; for one concrete reason: minor-mode maps outrank major-mode maps, so a
;; MEGA key means the same thing in every buffer.  `M-x mega-keys-mode' turns
;; the whole layer off.
;;
;; A row is (KEY COMMAND DESCRIPTION).  KEY is in `kbd' notation, or nil for
;; a command that has no key and is listed in the cheat sheet as `M-x'.
;; COMMAND may also name a keymap, which makes KEY a prefix.
;; DESCRIPTION is what the cheat sheet shows; it is written here, not taken
;; from the docstring, so that showing the sheet never loads a module.

;;; Code:

(require 'mega-lib)

(defconst mega-keys
  '(("Help"
     ("C-c ?" mega-help   "This cheat sheet")
     (nil     mega-doctor "What works on this machine, and what is missing"))
    ("Find"
     ("M-g a" mega-search-project "Search the project as you type")
     ("M-g s" mega-search-symbol  "Search the project for the symbol at point")
     ("M-g i" imenu               "Jump to a definition in this buffer")
     ("C-c p" mega-project-map    "Project: f file, p switch, b buffer, g grep, c compile, s shell")
     ("C-c t" mega-project-tree   "Show or hide the file tree"))
    ("Code"
     ("C-c d"   mega-doc-buffer   "Documentation for the thing at point, in a side window")
     ("C-c D"   mega-doc-popup    "The same, in a popup")
     ("C-c c r" eglot-rename      "Rename the symbol at point everywhere")
     ("C-c c a" eglot-code-actions "Offer fixes and refactorings here")
     ("C-c c i" eglot-find-implementation "Go to the implementation")
     ("C-c c t" eglot-find-typeDefinition "Go to the definition of the type")
     ("C-c c h" eglot-show-call-hierarchy "Who calls this, and what it calls")
     ("C-c c o" eglot-code-action-organize-imports "Tidy the imports")
     ("C-c c n" flymake-goto-next-error "Next problem")
     ("C-c c p" flymake-goto-prev-error "Previous problem")
     ("C-c c e" flymake-show-buffer-diagnostics  "List the problems in this buffer")
     ("C-c c E" flymake-show-project-diagnostics "List the problems in the project"))
    ("Workspaces"
     ("C-c h"   mega-home             "The home page: continue, recent projects")
     ("C-c w s" mega-workspace-save   "Save the files and windows on screen under a name")
     ("C-c w r" mega-workspace-resume "Bring a saved workspace back")
     ("C-c w n" mega-workspace-new    "Open an empty tab")
     ("C-c w w" tab-bar-switch-to-tab "Switch to another tab")
     ("C-c w k" mega-workspace-forget "Forget a saved workspace"))
    ("Windows"
     ("M-{" shrink-window-horizontally  "Make the window narrower")
     ("M-}" enlarge-window-horizontally "Make the window wider")))
  "Every binding MEGA defines, grouped for the cheat sheet.
Each element is (GROUP ROW...), and each ROW is (KEY COMMAND DESCRIPTION).")

(defvar mega-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (group mega-keys)
      (dolist (row (cdr group))
        (when (car row)
          (define-key map (kbd (car row)) (nth 1 row)))))
    map)
  "Keymap holding every binding MEGA defines.  Built from `mega-keys'.")

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

(provide 'mega-keys)
;;; mega-keys.el ends here
