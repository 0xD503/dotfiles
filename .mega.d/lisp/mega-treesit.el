;;; mega-treesit.el --- Grammar sources, installation, safe remapping  -*- lexical-binding: t; -*-

;;; Commentary:

;; The machinery only.  Which languages exist is data, and lives in
;; `mega-languages' in mega-lang.el.
;;
;; Two safety properties matter here:
;;
;; * Revisions are pinned.  A grammar is arbitrary C compiled on this machine,
;;   and an unpinned HEAD can also outrun the ABI this Emacs supports (13-15
;;   here), which breaks every buffer of that language.  `mega-treesit-freeze'
;;   turns the tag pins into immutable commit SHAs once you have a set that
;;   works.
;;
;; * Remapping is conditional.  A missing grammar degrades to the classic major
;;   mode; it never leaves you in a broken buffer.

;;; Code:

(require 'mega-lib)
(require 'treesit)

(defconst mega-treesit-dir (mega-cache "tree-sitter/")
  "Where MEGA compiles and loads grammars.")

(defconst mega-treesit-pins-file (mega-state "treesit-pins.el")
  "Optional alist of (LANGUAGE . COMMIT) written by `mega-treesit-freeze'.")

(add-to-list 'treesit-extra-load-path mega-treesit-dir)

(defvar mega-treesit-pins nil
  "Alist of (LANGUAGE . REVISION) overriding the defaults in `mega-languages'.")

(when (file-readable-p mega-treesit-pins-file)
  (with-temp-buffer
    (insert-file-contents mega-treesit-pins-file)
    (setq mega-treesit-pins (ignore-errors (read (current-buffer))))))

(defun mega-treesit-register (lang url revision &optional source-dir)
  "Register grammar LANG from URL at REVISION, optionally under SOURCE-DIR.
A pin recorded by `mega-treesit-freeze' wins over REVISION."
  (let ((rev (or (alist-get lang mega-treesit-pins) revision)))
    (setf (alist-get lang treesit-language-source-alist)
          (list url rev source-dir))))

(defun mega-treesit-ready-p (lang)
  "Non-nil if grammar LANG is installed and loadable, quietly."
  (treesit-ready-p lang :quiet))

(defun mega-treesit-registered ()
  "Languages MEGA knows how to build, in a stable order."
  (sort (mapcar #'car treesit-language-source-alist) #'string<))

(defun mega-treesit-missing ()
  "Registered languages whose grammar is not installed."
  (seq-remove #'mega-treesit-ready-p (mega-treesit-registered)))

;;;###autoload
(defun mega-treesit-install-all (&optional force)
  "Build every grammar MEGA knows about that is not already installed.
With FORCE (a prefix argument), rebuild them all.  Needs a C compiler and
git, both of which `mega-doctor' checks for."
  (interactive "P")
  (unless (mega-exe-p "cc")
    (user-error "No C compiler on PATH; tree-sitter grammars are compiled from source"))
  (unless (mega-exe-p "git")
    (user-error "No git on PATH; grammar sources are cloned"))
  (let ((targets (if force (mega-treesit-registered) (mega-treesit-missing)))
        (built 0) (failed nil))
    (if (null targets)
        (message "MEGA: every registered grammar is already installed")
      (dolist (lang targets)
        (message "MEGA: building tree-sitter grammar for %s..." lang)
        (condition-case err
            (progn (treesit-install-language-grammar lang mega-treesit-dir)
                   (cl-incf built))
          (error (push (cons lang (error-message-string err)) failed))))
      (message "MEGA: %d grammar(s) built%s" built
               (if failed (format ", %d failed: %s" (length failed)
                                  (mapconcat (lambda (f) (symbol-name (car f))) failed ", "))
                 "")))))

;;;###autoload
(defun mega-treesit-freeze ()
  "Pin every registered grammar to the exact commit its revision resolves to.
Tags are stable in practice but mutable in principle; this records
immutable SHAs in `mega-treesit-pins-file' so another machine — or this
one after an upstream retag — builds byte-identical grammars."
  (interactive)
  (let (pins)
    (dolist (entry treesit-language-source-alist)
      (pcase-let* ((`(,lang ,url ,rev . ,_) (cons (car entry) (cdr entry)))
                   (sha (mega-treesit--resolve url rev)))
        (if sha
            (push (cons lang sha) pins)
          (message "MEGA: could not resolve %s@%s" url rev))))
    (with-temp-file mega-treesit-pins-file
      (insert ";; Written by M-x mega-treesit-freeze.  Delete to float back to tags.\n")
      (pp (nreverse pins) (current-buffer)))
    (message "MEGA: pinned %d grammars in %s" (length pins) mega-treesit-pins-file)))

(defun mega-treesit--resolve (url revision)
  "Resolve REVISION in remote URL to a commit SHA, or nil."
  (with-temp-buffer
    (when (zerop (call-process "git" nil t nil "ls-remote" url revision))
      (goto-char (point-min))
      (when (looking-at "\\([0-9a-f]\\{40\\}\\)")
        (match-string 1)))))

;;;###autoload
(defun mega-treesit-doctor ()
  "Report grammar status and the ABI window this Emacs accepts."
  (interactive)
  (message "MEGA tree-sitter: ABI %s-%s, %d installed, missing: %s"
           (treesit-library-abi-version t)
           (treesit-library-abi-version)
           (length (seq-filter #'mega-treesit-ready-p (mega-treesit-registered)))
           (or (mapconcat #'symbol-name (mega-treesit-missing) ", ") "none")))

(provide 'mega-treesit)
;;; mega-treesit.el ends here
