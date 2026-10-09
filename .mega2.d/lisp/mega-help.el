;;; mega-help.el --- The cheat sheet  -*- lexical-binding: t; -*-

;;; Commentary:

;; `C-c ?' shows every key MEGA binds, on one screen.  The sheet is generated
;; from the `mega-keys' table that also builds the keymap, so it is always
;; exactly what the keys do.  It loads nothing and runs nothing.

;;; Code:

(require 'mega-lib)
(require 'mega-keys)

(defun mega-help--insert ()
  "Insert the cheat sheet at point."
  (insert (propertize (format "MEGA %s — keys\n" mega-version)
                      'face '(bold underline)))
  (dolist (group mega-keys)
    (insert "\n" (propertize (car group) 'face 'bold) "\n")
    (dolist (row (cdr group))
      (let ((key (car row)))
        (insert (format "  %-18s %s\n"
                        (propertize (or key (format "M-x %s" (nth 1 row)))
                                    'face 'help-key-binding)
                        (nth 2 row))))))
  (insert "\n"
          "Pause after a prefix key such as C-c or C-x and Emacs lists what can follow.\n"
          "C-h k KEY describes one key; C-h m the current mode.\n"
          (format "The short guide is %s.\n"
                  (abbreviate-file-name (expand-file-name "README.md" mega-dir)))))

;;;###autoload
(defun mega-help ()
  "Show every key MEGA binds."
  (interactive)
  (with-current-buffer (get-buffer-create "*mega-help*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (special-mode)
      (mega-help--insert)
      (goto-char (point-min))))
  (pop-to-buffer "*mega-help*"))

(provide 'mega-help)
;;; mega-help.el ends here
