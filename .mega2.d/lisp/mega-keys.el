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
;; DESCRIPTION is what the cheat sheet shows; it is written here, not taken
;; from the docstring, so that showing the sheet never loads a module.

;;; Code:

(require 'mega-lib)

(defconst mega-keys
  '(("Help"
     ("C-c ?" mega-help   "This cheat sheet")
     (nil     mega-doctor "What works on this machine, and what is missing"))
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
