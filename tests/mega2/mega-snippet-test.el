;;; mega-snippet-test.el --- Tests for mega-snippet.el and mega-task.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-snippet)
(require 'mega-task)
(require 'mega-complete)

;;;; Reading a template

(ert-deftest mega-snippet-plain-text-has-no-places ()
  (should (equal (mega-snippet-parse "just text") '("just text"))))

(ert-deftest mega-snippet-numbered-places-are-found ()
  (should (equal (mega-snippet-parse "a $1 b ${2} c $0")
                 '("a  b  c " (1 2 2) (2 5 5) (0 8 8)))))

(ert-deftest mega-snippet-a-place-may-have-a-default ()
  (should (equal (mega-snippet-parse "for ${1:item} in ${2:items}")
                 '("for item in items" (1 4 8) (2 12 17)))))

(ert-deftest mega-snippet-a-default-may-contain-places ()
  (should (equal (mega-snippet-parse "${1:fn(${2:arg})}")
                 '("fn(arg)" (1 0 7) (2 3 6)))))

(ert-deftest mega-snippet-a-choice-uses-its-first-option ()
  (should (equal (mega-snippet-parse "${1|pub,private|} fn")
                 '("pub fn" (1 0 3)))))

(ert-deftest mega-snippet-escapes-are-literal ()
  (should (equal (mega-snippet-parse "cost: \\$5 \\} \\\\") '("cost: $5 } \\"))))

(ert-deftest mega-snippet-variables-give-their-default-or-nothing ()
  (should (equal (mega-snippet-parse "${TM_FILENAME:untitled}-$TM_SELECTED_TEXT.")
                 '("untitled-."))))

(ert-deftest mega-snippet-a-repeated-number-is-one-place ()
  (should (equal (mega-snippet-parse "${1:x} = $1 + $1")
                 '("x =  + " (1 0 1)))))

(ert-deftest mega-snippet-an-unclosed-brace-is-just-text ()
  (should (equal (car (mega-snippet-parse "a ${1:oops")) "a ${1:oops")))

;;;; Filling one in

(defmacro mega-snippet-test--buffer (&rest body)
  "Run BODY in an empty buffer, ending any snippet afterwards."
  (declare (indent 0))
  `(with-temp-buffer
     (transient-mark-mode 1)
     (unwind-protect
         (progn ,@body)
       (mega-snippet-finish))))

(defun mega-snippet-test--selected ()
  "The selected text, or nil if nothing is selected."
  (and (region-active-p)
       (buffer-substring-no-properties (region-beginning) (region-end))))

(ert-deftest mega-snippet-expanding-selects-the-first-place ()
  (mega-snippet-test--buffer
    (mega-snippet-expand "for ${1:item} in ${2:items} {$0}")
    (should (equal (buffer-string) "for item in items {}"))
    (should mega-snippet--active)
    (should (equal (mega-snippet-test--selected) "item"))))

(ert-deftest mega-snippet-tab-walks-the-places-and-ends-on-zero ()
  (mega-snippet-test--buffer
    (mega-snippet-expand "for ${1:item} in ${2:items} {$0}")
    (mega-snippet-next)
    (should (equal (mega-snippet-test--selected) "items"))
    (mega-snippet-next)
    (should-not mega-snippet--active)
    (should-not (region-active-p))
    (should (looking-at-p "}"))))

(ert-deftest mega-snippet-typing-replaces-a-place-and-the-rest-follows ()
  (mega-snippet-test--buffer
    (mega-snippet-expand "let ${1:name} = ${2:value};$0")
    ;; What typing over a selection does.
    (delete-region (region-beginning) (region-end))
    (insert "a_much_longer_name")
    (mega-snippet-next)
    (should (equal (mega-snippet-test--selected) "value"))
    (delete-region (region-beginning) (region-end))
    (insert "1")
    (mega-snippet-next)
    (should (equal (buffer-string) "let a_much_longer_name = 1;"))
    (should (= (point) (point-max)))))

(ert-deftest mega-snippet-shift-tab-goes-back ()
  (mega-snippet-test--buffer
    (mega-snippet-expand "${1:one} ${2:two} ${3:three}")
    (mega-snippet-next)
    (mega-snippet-next)
    (should (equal (mega-snippet-test--selected) "three"))
    (mega-snippet-previous)
    (should (equal (mega-snippet-test--selected) "two"))
    (mega-snippet-previous)
    (should (equal (mega-snippet-test--selected) "one"))
    (mega-snippet-previous)
    (should (equal (mega-snippet-test--selected) "one"))))

(ert-deftest mega-snippet-without-a-zero-the-end-is-the-last-stop ()
  (mega-snippet-test--buffer
    (mega-snippet-expand "call(${1:arg})")
    (mega-snippet-next)
    (should-not mega-snippet--active)
    (should (= (point) (point-max)))))

(ert-deftest mega-snippet-later-lines-take-the-indentation-of-the-first ()
  (mega-snippet-test--buffer
    (insert "    ")
    (mega-snippet-expand "if ${1:cond} {\n    $0\n}")
    (should (equal (buffer-string) "    if cond {\n        \n    }"))
    (should (equal (mega-snippet-test--selected) "cond"))
    (mega-snippet-next)
    ;; $0 is on the middle line, after its indentation.
    (should (= (line-number-at-pos) 2))
    (should (= (current-column) 8))))

(ert-deftest mega-snippet-plain-text-leaves-the-cursor-at-its-end ()
  (mega-snippet-test--buffer
    (mega-snippet-expand "nothing to fill in")
    (should-not mega-snippet--active)
    (should (= (point) (point-max)))))

(ert-deftest mega-snippet-leaving-it-ends-it ()
  (mega-snippet-test--buffer
    (insert "before ")
    (mega-snippet-expand "${1:a} ${2:b}")
    (goto-char (point-min))
    (mega-snippet--watch)
    (should-not mega-snippet--active)))

(ert-deftest mega-snippet-its-keys-apply-only-while-it-is-active ()
  (mega-snippet-test--buffer
    (should-not (eq (key-binding (kbd "TAB")) #'mega-snippet-next))
    (mega-snippet-expand "${1:a} ${2:b}")
    (should (eq (key-binding (kbd "TAB")) #'mega-snippet-next))
    (should (eq (key-binding (kbd "<backtab>")) #'mega-snippet-previous))
    (mega-snippet-finish)
    (should-not (eq (key-binding (kbd "TAB")) #'mega-snippet-next))))

(ert-deftest mega-snippet-the-completion-menu-keeps-tab-while-it-is-open ()
  "Both claim TAB; whichever comes first in Emacs's list gets it."
  (let ((emulation-mode-map-alists emulation-mode-map-alists)
        (completion-in-region-function completion-in-region-function)
        (post-command-hook post-command-hook))
    (unwind-protect
        (progn
          (mega-complete-mode 1)
          (should (< (seq-position emulation-mode-map-alists
                                   'mega-complete--emulation-alist)
                     (seq-position emulation-mode-map-alists
                                   'mega-snippet--emulation-alist))))
      (mega-complete-mode -1))))

;;;; MEGA's own snippets

(ert-deftest mega-snippet-every-shipped-template-parses-and-has-a-name ()
  (dolist (entry mega-snippets)
    (should (seq-every-p #'symbolp (car entry)))
    (dolist (snippet (cdr entry))
      (should (string-match-p "\\`[a-z]+\\'" (car snippet)))
      (should (stringp (car (mega-snippet-parse (cdr snippet))))))))

(ert-deftest mega-snippet-a-buffer-gets-the-snippets-of-its-mode ()
  (with-temp-buffer
    (python-mode)
    (let ((names (mapcar #'car (mega-snippet-available))))
      (should (member "def" names))
      (should (member "todo" names))    ; from prog-mode
      (should-not (member "impl" names))))
  (with-temp-buffer
    (text-mode)
    (should-not (mega-snippet-available))))

(ert-deftest mega-snippet-names-are-offered-as-completions ()
  (with-temp-buffer
    (python-mode)
    (insert "cl")
    (pcase (mega-snippet-capf)
      (`(,start ,end ,names . ,properties)
       (should (equal (buffer-substring start end) "cl"))
       (should (member "class" names))
       (should (equal (funcall (plist-get properties :annotation-function) "class")
                      " snippet"))
       ;; Accepting the name replaces it with the template.
       (delete-region start end)
       (insert "class")
       (funcall (plist-get properties :exit-function) "class" 'finished)
       (should (string-prefix-p "class Name:" (buffer-string)))
       (mega-snippet-finish))
      (_ (ert-fail "no completion offered")))))

(ert-deftest mega-snippet-says-nothing-when-no-name-could-match ()
  "So that the next completion source, words from buffers, gets its turn."
  (with-temp-buffer
    (python-mode)
    (insert "zzz")
    (should-not (mega-snippet-capf))))

(ert-deftest mega-snippet-insert-by-name ()
  (with-temp-buffer
    (python-mode)
    (mega-test-with-scripted-prompt "main"
      (call-interactively #'mega-snippet-insert))
    (should (string-prefix-p "if __name__" (buffer-string)))
    (mega-snippet-finish))
  (with-temp-buffer
    (text-mode)
    (should-error (call-interactively #'mega-snippet-insert) :type 'user-error)))

(ert-deftest mega-snippet-the-language-server-expands-through-mega ()
  "eglot offers snippet support only if it finds an expander."
  (require 'eglot)
  (should (fboundp 'eglot--snippet-expansion-fn))
  (should (eq (eglot--snippet-expansion-fn) #'mega-snippet-expand)))

;;;; Tasks

(defmacro mega-snippet-test--project (files &rest body)
  "Run BODY with DIR bound to a trusted directory holding the marker FILES."
  (declare (indent 1))
  `(mega-test-with-directory dir
     (dolist (file ,files)
       (mega-test-write (expand-file-name file dir) ""))
     (let ((mega-task-overrides nil)
           (mega-task--last nil)
           (mega-exec-context-functions nil))
       (cl-letf (((symbol-function 'mega-trust-p) (lambda (&rest _) t))
                 ((symbol-function 'mega-project-root) (lambda (&rest _) dir)))
         ,@body))))

(ert-deftest mega-task-a-cargo-project-has-the-cargo-tasks ()
  (mega-snippet-test--project '("Cargo.toml")
    (let ((tasks (mega-task-list dir)))
      (should (equal (assq 'build tasks) '(build "cargo" "build")))
      (should (equal (assq 'test tasks) '(test "cargo" "test")))
      (should (equal (assq 'run tasks) '(run "cargo" "run"))))))

(ert-deftest mega-task-kinds-combine-and-the-first-kind-wins-a-name ()
  (mega-snippet-test--project '("Cargo.toml" "Makefile")
    (let ((tasks (mega-task-list dir)))
      (should (equal (assq 'build tasks) '(build "cargo" "build")))
      ;; Only make has a clean task.
      (should (equal (assq 'clean tasks) '(clean "make" "clean")))
      (should (= (length tasks) (length (delete-dups (mapcar #'car tasks))))))))

(ert-deftest mega-task-a-justfile-under-any-of-its-names-counts ()
  (mega-snippet-test--project '("Justfile")
    (should (equal (assq 'build (mega-task-list dir)) '(build "just" "build")))))

(ert-deftest mega-task-your-own-tasks-come-first ()
  (mega-snippet-test--project '("Cargo.toml")
    (let ((mega-task-overrides
           `((,(abbreviate-file-name dir) (build "just" "release") (deploy "just" "deploy")))))
      (let ((tasks (mega-task-list dir)))
        (should (equal (assq 'build tasks) '(build "just" "release")))
        (should (assq 'deploy tasks))
        (should (assq 'test tasks))))))

(ert-deftest mega-task-a-project-of-no-known-kind-has-no-tasks ()
  (mega-snippet-test--project nil
    (should-not (mega-task-list dir))
    (let ((default-directory dir))
      (should-error (mega-task-build) :type 'user-error)
      (should-error (mega-task-choose) :type 'user-error))))

(ert-deftest mega-task-the-command-line-is-quoted-word-by-word ()
  (should (equal (mega-task-command-line "/tmp/" '(x "tool" "two words" "$(touch pwned)" "a;b"))
                 "tool two\\ words \\$\\(touch\\ pwned\\) a\\;b")))

(ert-deftest mega-task-the-command-runs-where-the-tools-are ()
  (let ((mega-exec-context-functions
         (list (lambda (_) (list :kind 'test
                                 :wrap (lambda (program args _)
                                         (append '("podman" "exec" "box") (cons program args))))))))
    (should (equal (mega-task-command-line "/tmp/" '(build "cargo" "build"))
                   "podman exec box cargo build"))))

(ert-deftest mega-task-runs-in-the-project-root-in-a-named-buffer ()
  (mega-snippet-test--project '("Cargo.toml")
    (let (started)
      (cl-letf (((symbol-function 'compilation-start)
                 (lambda (command _mode name-function)
                   (setq started (list command default-directory
                                       (funcall name-function nil)))))
                ((symbol-function 'mega-exec-find) (lambda (&rest _) t)))
        (let ((default-directory dir))
          (mega-task-test))
        (should (equal started
                       (list "cargo test" dir
                             (format "*%s: test*"
                                     (file-name-nondirectory (directory-file-name dir))))))
        ;; And again, from anywhere.
        (setq started nil)
        (let ((default-directory "/"))
          (mega-task-again))
        (should (equal (car started) "cargo test"))))))

(ert-deftest mega-task-needs-a-trusted-project-and-an-installed-tool ()
  (mega-snippet-test--project '("Cargo.toml")
    (let (started)
      (cl-letf (((symbol-function 'compilation-start) (lambda (&rest _) (setq started t))))
        (let ((default-directory dir))
          (cl-letf (((symbol-function 'mega-trust-p) (lambda (&rest _) nil)))
            (should-error (mega-task-build) :type 'user-error))
          (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
            (should-error (mega-task-build) :type 'user-error)))
        (should-not started)))))

(ert-deftest mega-task-choosing-lists-every-task-with-its-command ()
  (mega-snippet-test--project '("Cargo.toml")
    (let (ran)
      (cl-letf (((symbol-function 'mega-task-run) (lambda (_root task) (setq ran task))))
        (let ((default-directory dir))
          (mega-test-with-scripted-prompt "clippy"
            (mega-task-choose)))
        (should (equal ran '(clippy "cargo" "clippy")))
        ;; Each choice shows the task's name and the command behind it.
        (should (equal (cdar mega-test-prompt-log) '("clippy     cargo clippy")))))))

(ert-deftest mega-task-again-with-nothing-run-says-so ()
  (let ((mega-task--last nil))
    (should-error (mega-task-again) :type 'user-error)))

(provide 'mega-snippet-test)
;;; mega-snippet-test.el ends here
