;;; mega-edit-test.el --- Tests for mega-edit.el and mega-indent-guides.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-edit)
(require 'mega-indent-guides)

;;;; Comments

(ert-deftest mega-edit-comment-toggles-the-line ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(one)\n(two)\n")
    (goto-char (point-min))
    (mega-comment-dwim)
    (should (equal (buffer-string) ";; (one)\n(two)\n"))
    (goto-char (point-min))
    (mega-comment-dwim)
    (should (equal (buffer-string) "(one)\n(two)\n"))))

(ert-deftest mega-edit-comment-toggles-the-region ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(one)\n(two)\n(three)\n")
    (transient-mark-mode 1)
    (goto-char (point-min))
    (set-mark (point))
    (forward-line 2)
    (activate-mark)
    (mega-comment-dwim)
    (should (equal (buffer-string) ";; (one)\n;; (two)\n(three)\n"))))

(ert-deftest mega-edit-the-modes-own-key-stays-reachable ()
  (with-temp-buffer
    (let (ran)
      (use-local-map (make-sparse-keymap))
      (local-set-key (kbd "C-c C-c") (lambda () (interactive) (setq ran t)))
      (mega-major-mode-ctrl-c-ctrl-c)
      (should ran)))
  (with-temp-buffer
    (use-local-map (make-sparse-keymap))
    (should-error (mega-major-mode-ctrl-c-ctrl-c) :type 'user-error)))

;;;; Folding

(defun mega-edit-test--visible ()
  "The text of the current buffer that is not folded away."
  (let ((text "") (position (point-min)))
    (while (< position (point-max))
      (let ((next (next-single-char-property-change position 'invisible nil (point-max))))
        (unless (invisible-p position)
          (setq text (concat text (buffer-substring-no-properties position next))))
        (setq position next)))
    text))

(ert-deftest mega-edit-folding-costs-nothing-until-it-is-used ()
  (should-not (memq 'hideshow mega-test-features-at-startup))
  (with-temp-buffer
    (emacs-lisp-mode)
    (should-not (bound-and-true-p hs-minor-mode))))

(ert-deftest mega-edit-a-block-folds-and-unfolds ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun one ()\n  (first)\n  (second))\n\n(defun two ()\n  (third))\n")
    (set-buffer-modified-p nil)
    ;; The cursor is somewhere in the body of the first function.
    (goto-char (point-min))
    (search-forward "(first)")
    (beginning-of-line)
    (mega-fold-toggle)
    (should (bound-and-true-p hs-minor-mode))
    (let ((visible (mega-edit-test--visible)))
      (should (string-match-p "(defun one ()" visible))
      (should-not (string-match-p "first\\|second" visible))
      ;; Only the block the cursor was in.
      (should (string-match-p "(third)" visible)))
    ;; Folding hides text; it never changes it.
    (should-not (buffer-modified-p (current-buffer)))
    (should (string-match-p "(second)" (buffer-string)))
    (mega-fold-toggle)
    (should (equal (mega-edit-test--visible) (buffer-string)))))

(ert-deftest mega-edit-everything-folds-and-unfolds-at-once ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun one ()\n  (first))\n\n(defun two ()\n  (third))\n")
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (mega-fold-all)
    (let ((visible (mega-edit-test--visible)))
      (should (string-match-p "(defun one ()" visible))
      (should (string-match-p "(defun two ()" visible))
      (should-not (string-match-p "first\\|third" visible)))
    ;; With anything folded, the same key unfolds everything.
    (mega-fold-all)
    (should (equal (mega-edit-test--visible) (buffer-string)))
    (should-not (buffer-modified-p))))

;;;; Symbol jump

(ert-deftest mega-edit-jumps-between-occurrences-of-a-symbol-and-wraps ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(foo 1)\n(foobar 2)\n(foo 3)\n(bar foo)\n")
    (goto-char 3)                       ; inside the first foo
    (mega-symbol-next)
    (should (= (line-number-at-pos) 3)) ; not foobar on line 2
    (should (= (current-column) 2))     ; same place within the symbol
    (mega-symbol-next)
    (should (= (line-number-at-pos) 4))
    (mega-symbol-next)
    (should (= (line-number-at-pos) 1)) ; wrapped
    (mega-symbol-previous)
    (should (= (line-number-at-pos) 4))))

(ert-deftest mega-edit-a-symbol-that-occurs-once-stays-put ()
  (with-temp-buffer
    (insert "alone here")
    (goto-char 2)
    (let ((inhibit-message t))
      (mega-symbol-next))
    (should (= (point) 2)))
  (with-temp-buffer
    (insert "   ")
    (should-error (mega-symbol-next) :type 'user-error)))

;;;; Trailing whitespace

(ert-deftest mega-edit-saving-trims-only-the-lines-that-were-changed ()
  (mega-test-with-directory dir
    (let ((file (mega-test-write (expand-file-name "a.txt" dir)
                                 "untouched   " "to edit" "also untouched\t" "")))
      (mega-test-visiting buffer file
        (should mega-edit-trim-mode)
        (goto-char (point-min))
        (forward-line 1)
        (end-of-line)
        (insert " now   ")
        (goto-char (point-min))
        (let ((inhibit-message t)) (save-buffer)))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "untouched   \nto edit now\nalso untouched\t\n")))))

(ert-deftest mega-edit-trimming-does-not-pull-the-cursor-back ()
  (with-temp-buffer
    (text-mode)
    (insert "typing here   ")
    (mega-edit-trim-changed-lines)
    (should (equal (buffer-string) "typing here   "))
    (should (= (point) (point-max)))))

(ert-deftest mega-edit-a-second-save-has-nothing-left-to-trim ()
  (with-temp-buffer
    (text-mode)
    (insert "a  \nb  \n")
    (goto-char (point-min))
    (mega-edit-trim-changed-lines)
    (should (equal (buffer-string) "a\nb\n"))
    (should-not (text-property-any (point-min) (point-max) 'mega-edit-changed t))))

(ert-deftest mega-edit-the-project-decides-about-trailing-whitespace ()
  "An .editorconfig that says to leave it is obeyed, on a real save."
  (mega-test-with-directory dir
    (mega-test-write (expand-file-name ".editorconfig" dir)
                     "root = true" "" "[*.txt]" "trim_trailing_whitespace = false"
                     "" "[*.md]" "trim_trailing_whitespace = true" "")
    (let ((inhibit-message t))
      (mega-test-visiting buffer (expand-file-name "notes.txt" dir)
        (insert "kept as typed   \nsecond line\t\n")
        (goto-char (point-min))
        (save-buffer))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name "notes.txt" dir))
                       (buffer-string))
                     "kept as typed   \nsecond line\t\n"))
      ;; And one that says to trim is obeyed where MEGA alone would not.
      (mega-test-visiting buffer (expand-file-name "page.md" dir)
        (insert "trimmed  \nlast\n")
        (goto-char (point-max))
        (save-buffer))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name "page.md" dir))
                       (buffer-string))
                     "trimmed\nlast\n")))))

(ert-deftest mega-edit-a-markdown-line-break-survives-a-save ()
  "Two spaces at the end of a line are a line break there, not litter."
  (mega-test-with-directory dir
    (let ((file (expand-file-name "page.md" dir))
          (inhibit-message t))
      (mega-test-visiting buffer file
        (should (derived-mode-p 'mega-markdown-mode))
        (insert "hard break here  \nnext line\n")
        (goto-char (point-max))
        (save-buffer))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "hard break here  \nnext line\n"))
      ;; The contrast: the same text in a file of code is trimmed.
      (let ((code (expand-file-name "tool.sh" dir)))
        (mega-test-visiting buffer code
          (insert "echo one  \necho two\n")
          (goto-char (point-max))
          (save-buffer))
        (should (equal (with-temp-buffer (insert-file-contents code) (buffer-string))
                       "echo one\necho two\n"))))))

(ert-deftest mega-edit-trimming-is-on-where-text-is-written ()
  (dolist (mode '(prog-mode text-mode conf-mode))
    (with-temp-buffer (funcall mode) (should mega-edit-trim-mode)))
  (with-temp-buffer (special-mode) (should-not mega-edit-trim-mode)))

;;;; TODO highlighting

(defun mega-edit-test--face-at (needle)
  "The faces on the first character of NEEDLE in the current buffer."
  (font-lock-ensure)
  (goto-char (point-min))
  (search-forward needle)
  (ensure-list (get-text-property (match-beginning 0) 'face)))

(ert-deftest mega-edit-todo-words-are-highlighted-in-comments-only ()
  (with-temp-buffer
    (insert ";; TODO: later\n;; FIXME: now\n(setq TODO 1)\n\"a NOTE in a string\"\n")
    (emacs-lisp-mode)
    (should (memq 'mega-edit-todo (mega-edit-test--face-at "TODO: later")))
    (should (memq 'mega-edit-fixme (mega-edit-test--face-at "FIXME")))
    (should-not (memq 'mega-edit-todo (mega-edit-test--face-at "TODO 1")))
    (should-not (memq 'mega-edit-todo (mega-edit-test--face-at "NOTE in")))))

(ert-deftest mega-edit-todo-is-a-whole-word ()
  (with-temp-buffer
    (insert ";; TODOS and AUTODOC\n")
    (emacs-lisp-mode)
    (should-not (memq 'mega-edit-todo (mega-edit-test--face-at "TODOS")))))

;;;; Typing conveniences

(ert-deftest mega-edit-emacs-own-conveniences-are-on ()
  (should delete-selection-mode)
  (should electric-pair-mode)
  (should repeat-mode))

;;;; Clipboard

(ert-deftest mega-clipboard-picks-the-tool-of-the-session ()
  (cl-letf (((symbol-function 'mega-exe-p) (lambda (name) (concat "/bin/" name))))
    (let ((process-environment '("WAYLAND_DISPLAY=wayland-0" "DISPLAY=:0")))
      (should (equal (caar (mega-clipboard--tool)) "wl-copy")))
    (let ((process-environment '("DISPLAY=:0")))
      (should (equal (caar (mega-clipboard--tool)) "xclip"))))
  ;; No display and no macOS tools: nothing to talk to, and no error.
  ;; (Emacs answers DISPLAY from the frame, not the environment, hence the
  ;; replacement of `getenv' itself.)
  (cl-letf (((symbol-function 'mega-exe-p)
             (lambda (name) (and (equal name "xclip") "/bin/xclip")))
            ((symbol-function 'getenv) (lambda (&rest _) nil)))
    (should-not (mega-clipboard--tool))))

(ert-deftest mega-clipboard-copies-and-pastes-through-the-tool ()
  (mega-test-with-directory dir
    (let* ((bin (expand-file-name "bin/" dir))
           (store (expand-file-name "clipboard" dir))
           (tool (mega-test-write
                  (expand-file-name "xclip" bin)
                  "#!/bin/sh"
                  (format "case \"$*\" in *-out*) cat '%s' ;; *) cat > '%s' ;; esac" store store)
                  ""))
           (exec-path (cons bin exec-path))
           (process-environment (cons "DISPLAY=:99" process-environment))
           (mega--exe-cache (make-hash-table :test #'equal))
           (mega-clipboard--last nil))
      (set-file-modes tool #o755)
      (mega-clipboard-copy "from emacs")
      (should (mega-test-wait-for (lambda () (and (file-exists-p store)
                                                   (> (file-attribute-size
                                                       (file-attributes store))
                                                      0)))))
      (should (equal (with-temp-buffer (insert-file-contents store) (buffer-string))
                     "from emacs"))
      ;; What Emacs put there itself is not news; the kill ring has it.
      (should-not (mega-clipboard-paste))
      ;; Something another program copied is.
      (mega-test-write store "from elsewhere")
      (should (equal (mega-clipboard-paste) "from elsewhere"))
      (should-not (mega-clipboard-paste)))))

(ert-deftest mega-clipboard-is-the-one-on-this-machine ()
  "Killing and yanking in a buffer of a remote file must not reach for the
clipboard of the other machine, at every kill and every yank."
  (mega-test-with-directory dir
    (let* ((bin (expand-file-name "bin/" dir))
           (store (expand-file-name "clipboard" dir))
           (tool (mega-test-write
                  (expand-file-name "xclip" bin)
                  "#!/bin/sh"
                  (format "case \"$*\" in *-out*) cat '%s' ;; *) cat > '%s' ;; esac" store store)
                  ""))
           (exec-path (cons bin exec-path))
           (process-environment (cons "DISPLAY=:99" process-environment))
           (mega--exe-cache (make-hash-table :test #'equal))
           (mega-clipboard--last nil)
           ;; A host that does not exist: touching it would fail or hang.
           (default-directory "/ssh:mega-test.invalid:/srv/"))
      (set-file-modes tool #o755)
      (mega-clipboard-copy "copied here")
      (should (mega-test-wait-for (lambda () (and (file-exists-p store)
                                                   (> (file-attribute-size
                                                       (file-attributes store))
                                                      0)))))
      (setq mega-clipboard--last nil)
      (should (equal (mega-clipboard-paste) "copied here")))))

(ert-deftest mega-clipboard-never-signals ()
  (cl-letf (((symbol-function 'mega-clipboard--tool)
             (lambda () '(("mega-test-no-such-tool") . ("mega-test-no-such-tool")))))
    (mega-clipboard-copy "text")
    (should-not (mega-clipboard-paste))))

;;;; Indentation guides

(defun mega-edit-test--guide-columns ()
  "Columns of the current line that show an indentation guide."
  (let (columns)
    (save-excursion
      (beginning-of-line)
      (while (not (eolp))
        (when (get-text-property (point) 'display)
          (push (current-column) columns))
        (forward-char 1)))
    (nreverse columns)))

(ert-deftest mega-indent-guides-leave-other-features-display-alone ()
  "A guide is one way of displaying a space; it must not claim them all."
  (with-temp-buffer
    (insert "top\n    one\n        two\n")
    (prog-mode)
    ;; Something else shows the word `top' as something else.
    (with-silent-modifications
      (put-text-property 1 4 'display "TOP"))
    (mega-indent-guides-mode 1)
    (font-lock-ensure)
    (should (equal (get-text-property 1 'display) "TOP"))
    ;; Re-highlighting, which removes and redraws the guides...
    (font-lock-flush)
    (font-lock-ensure)
    (should (equal (get-text-property 1 'display) "TOP"))
    (goto-char (point-min))
    (forward-line 2)
    (should (mega-edit-test--guide-columns))
    ;; ...and switching the guides off, leave it where it was.
    (mega-indent-guides-mode -1)
    (should (equal (get-text-property 1 'display) "TOP"))
    (goto-char (point-min))
    (forward-line 2)
    (should-not (mega-edit-test--guide-columns))
    (should-not (memq 'mega-indent-guides-display
                      (cdr (assq 'display char-property-alias-alist))))))

(ert-deftest mega-indent-guides-mark-each-level-inside-the-indentation ()
  (with-temp-buffer
    (insert "top\n    one\n        two\n\n            three  spaced\n")
    (prog-mode)
    (setq-local mega-indent-guides--offset 4)
    (mega-indent-guides-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (should-not (mega-edit-test--guide-columns))
    (forward-line 1) (should (equal (mega-edit-test--guide-columns) '(0)))
    (forward-line 1) (should (equal (mega-edit-test--guide-columns) '(0 4)))
    (forward-line 1) (should-not (mega-edit-test--guide-columns))
    ;; Only in the indentation: the two spaces inside the line get nothing.
    (forward-line 1) (should (equal (mega-edit-test--guide-columns) '(0 4 8)))))

(ert-deftest mega-indent-guides-change-what-is-shown-not-what-is-there ()
  (with-temp-buffer
    (insert "    one\n")
    (prog-mode)
    (set-buffer-modified-p nil)
    (mega-indent-guides-mode 1)
    (font-lock-ensure)
    (should (text-property-not-all (point-min) (point-max) 'display nil))
    (should (equal (buffer-substring-no-properties (point-min) (point-max)) "    one\n"))
    (should-not (buffer-modified-p))
    (mega-indent-guides-mode -1)
    (should-not (text-property-not-all (point-min) (point-max) 'display nil))))

(ert-deftest mega-indent-guides-follow-the-modes-indentation-width ()
  (with-temp-buffer
    (insert "{\n  \"a\": {\n    \"b\": 1\n  }\n}\n")
    (js-json-mode)
    (setq-local js-indent-level 2)
    (mega-indent-guides-mode 1)
    (should (= (mega-indent-guides-offset) 2))
    (font-lock-ensure)
    (goto-char (point-min))
    (forward-line 2)
    (should (equal (mega-edit-test--guide-columns) '(0 2)))))

(ert-deftest mega-indent-guides-skip-tabs ()
  (with-temp-buffer
    (insert "\tone\n")
    (prog-mode)
    (mega-indent-guides-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (should-not (mega-edit-test--guide-columns))))

(ert-deftest mega-indent-guides-are-on-in-code ()
  (with-temp-buffer (prog-mode) (should mega-indent-guides-mode))
  (with-temp-buffer (text-mode) (should-not mega-indent-guides-mode)))

(provide 'mega-edit-test)
;;; mega-edit-test.el ends here
