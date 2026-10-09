;;; mega-ui-test.el --- Tests for mega-ui.el and the theme  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)

;;;; Theme

(defun mega-ui-test--theme-faces ()
  "Alist of (FACE . SPEC) for every face the theme sets."
  (let (faces)
    (dolist (setting (get 'mega-nord 'theme-settings) faces)
      (when (eq (car setting) 'theme-face)
        (push (cons (nth 1 setting) (nth 3 setting)) faces)))))

(defun mega-ui-test--colours (form)
  "Every colour string that appears anywhere in FORM."
  (cond ((stringp form) (and (string-prefix-p "#" form) (list form)))
        ((consp form) (append (mega-ui-test--colours (car form))
                              (mega-ui-test--colours (cdr form))))))

(ert-deftest mega-ui-the-theme-is-on-and-is-the-only-one ()
  (should (equal custom-enabled-themes '(mega-nord))))

(ert-deftest mega-ui-the-theme-covers-the-faces-that-matter ()
  (let ((faces (mapcar #'car (mega-ui-test--theme-faces))))
    (dolist (face '(default region mode-line mode-line-inactive line-number
                    fill-column-indicator minibuffer-prompt isearch
                    show-paren-match error warning success
                    font-lock-comment-face font-lock-string-face
                    font-lock-keyword-face font-lock-function-name-face
                    font-lock-type-face completions-common-part
                    flymake-error diff-added diff-removed
                    ansi-color-red ansi-color-green
                    mega-modeline-modified mega-modeline-vc))
      (should (memq face faces)))))

(ert-deftest mega-ui-every-theme-colour-comes-from-the-palette ()
  (let ((palette (mapcar #'cdr mega-nord-palette))
        (used (mega-ui-test--colours (mega-ui-test--theme-faces))))
    (should (> (length used) 100))
    (dolist (colour used)
      (should (member colour palette)))))

(ert-deftest mega-ui-the-palette-is-valid-and-unambiguous ()
  (dolist (entry mega-nord-palette)
    (should (string-match-p "\\`#[0-9A-F]\\{6\\}\\'" (cdr entry))))
  (should (= (length mega-nord-palette)
             (length (delete-dups (mapcar #'car mega-nord-palette))))))

(ert-deftest mega-ui-the-theme-keeps-out-of-poor-terminals ()
  "Every face is conditional on 256 colours, so 16-colour terminals keep theirs."
  (dolist (face (mega-ui-test--theme-faces))
    (dolist (clause (cdr face))
      (should (equal (car clause) '((class color) (min-colors 256)))))))

(ert-deftest mega-ui-every-themed-mega-face-is-defined ()
  (dolist (face (mapcar #'car (mega-ui-test--theme-faces)))
    (when (string-prefix-p "mega-" (symbol-name face))
      (should (facep face)))))

;;;; Modeline

;; Emacs renders no modeline in batch mode — `format-mode-line' returns "" —
;; so what is checked here is each piece.  That the assembled line really
;; shows the buffer, the position and "Narrow" is checked on a real terminal
;; by mega-terminal-probe.el.

(defun mega-ui-test--eval-forms (format)
  "Every (:eval FORM) form anywhere in the modeline FORMAT."
  (when (consp format)
    (if (eq (car format) :eval)
        (list (nth 1 format))
      (let (found)
        (while (consp format)
          (setq found (append (mega-ui-test--eval-forms (car format)) found)
                format (cdr format)))
        found))))

(ert-deftest mega-ui-every-piece-of-the-modeline-evaluates ()
  "One piece that signals makes Emacs blank the whole line."
  (let ((forms (mega-ui-test--eval-forms (default-value 'mode-line-format))))
    (should (>= (length forms) 4))
    (dolist (mode '(fundamental-mode prog-mode text-mode special-mode))
      (with-temp-buffer
        (funcall mode)
        (dolist (form forms)
          (let ((piece (eval form t)))
            (should (or (null piece) (stringp piece)))))))))

(ert-deftest mega-ui-the-modeline-keeps-what-emacs-needs-to-show ()
  (let ((format (default-value 'mode-line-format)))
    (dolist (piece '("%e" mode-line-buffer-identification mode-name
                     mode-line-process mode-line-misc-info))
      (should (member piece format)))
    (should (seq-some (lambda (piece) (and (stringp piece)
                                           (string-match-p "%l:%c" piece)))
                      format))
    ;; Diagnostics come from flymake itself, only where it is on.
    (should (assq 'flymake-mode format))))

(ert-deftest mega-ui-the-modeline-marks-unsaved-changes ()
  (mega-test-with-directory dir
    (mega-test-visiting buffer (mega-test-write (expand-file-name "a.txt" dir) "x" "")
      (should (equal (mega-modeline--status) "  "))
      (insert "change")
      (let ((marker (mega-modeline--status)))
        (should (member (substring-no-properties marker) '(" ●" " *")))
        (should (eq (get-text-property 1 'face marker) 'mega-modeline-modified))))))

(ert-deftest mega-ui-the-modeline-marks-read-only-files ()
  (mega-test-with-directory dir
    (mega-test-visiting buffer (mega-test-write (expand-file-name "a.txt" dir) "x" "")
      (setq buffer-read-only t)
      (let ((marker (mega-modeline--status)))
        (should (member (substring-no-properties marker) '(" ∅" " %")))
        (should (eq (get-text-property 1 'face marker) 'mega-modeline-read-only))))))

(ert-deftest mega-ui-a-scratch-buffer-is-never-marked-unsaved ()
  (with-temp-buffer
    (insert "text")
    (should (equal (mega-modeline--status) "  "))))

(ert-deftest mega-ui-the-modeline-names-a-remote-host ()
  (with-temp-buffer
    (should-not (mega-modeline--remote))
    (setq default-directory "/ssh:build.example.org:/srv/")
    (should (equal (substring-no-properties (mega-modeline--remote))
                   " @build.example.org"))))

(ert-deftest mega-ui-the-modeline-shows-the-branch-only ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/mega-ui-test-file")
    (unwind-protect
        (progn
          (should-not (mega-modeline--vc))
          (dolist (state '(" Git:main" " Git-main"))
            (setq vc-mode state)
            (should (equal (substring-no-properties (mega-modeline--vc)) "  main"))))
      (setq buffer-file-name nil))))

;;;; Line numbers and the ruler

(ert-deftest mega-ui-the-ruler-is-at-80-in-code-config-and-prose ()
  (dolist (mode '(prog-mode conf-mode text-mode))
    (with-temp-buffer
      (funcall mode)
      (should display-fill-column-indicator-mode)
      ;; t means "wherever `fill-column' is".
      (should (eq display-fill-column-indicator-column t))
      (should (= fill-column 80)))))

(ert-deftest mega-ui-no-ruler-where-there-is-no-text-to-limit ()
  (dolist (mode '(fundamental-mode special-mode))
    (with-temp-buffer
      (funcall mode)
      (should-not display-fill-column-indicator-mode))))

(ert-deftest mega-ui-the-ruler-follows-editorconfig ()
  (mega-test-with-directory project
    (mega-test-write (expand-file-name ".editorconfig" project)
                     "root = true" "" "[*.py]" "max_line_length = 100" "")
    (mega-test-visiting buffer
        (mega-test-write (expand-file-name "tool.py" project) "x = 1" "")
      (should display-fill-column-indicator-mode)
      (should (eq display-fill-column-indicator-column t))
      (should (= fill-column 100)))
    ;; A file the section does not cover keeps the default.
    (mega-test-visiting buffer
        (mega-test-write (expand-file-name "tool.sh" project) "x=1" "")
      (should (= fill-column 80)))))

(ert-deftest mega-ui-line-numbers-in-code-only ()
  (with-temp-buffer
    (prog-mode)
    (should display-line-numbers-mode))
  (with-temp-buffer
    (text-mode)
    (should-not display-line-numbers-mode)))

;;;; The rest

(ert-deftest mega-ui-key-hints-and-column-numbers-are-on ()
  (should which-key-mode)
  (should column-number-mode)
  (should show-paren-mode))

(provide 'mega-ui-test)
;;; mega-ui-test.el ends here
