;;; ~/.emacs-profiles.el -- chemacs2 profile definitions.
;;
;; Each entry is (PROFILE-NAME . ALIST). Select one with:
;;   emacs --with-profile legacy
;; The profile named "default" is used when none is given.

(("default" . ((user-emacs-directory . "~/.config/emacs")))
 ("mega"    . ((user-emacs-directory . "~/.mega.d")))
 ("legacy"  . ((user-emacs-directory . "~/.emacs.d"))))
