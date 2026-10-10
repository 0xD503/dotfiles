;;; mega-lang-test.el --- Tests for mega-lang.el, mega-lsp.el and MEGA's own modes  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-lang)
(require 'mega-lsp)
(require 'treesit)
(require 'imenu)

(defvar mega-test-pwned)

(defvar mega-lang-test--y-or-n-p (symbol-function 'y-or-n-p)
  "Emacs's own `y-or-n-p', to check that it is put back.")

(defmacro mega-lang-test--with-parsers (available &rest body)
  "Run BODY as if exactly the parsers in AVAILABLE were installed.
Nothing is ever offered for installation, and no decision is recorded."
  (declare (indent 1))
  `(mega-test-with-directory lang-dir
     (let ((treesit-auto-install-grammar nil)
           (mega-lang--declined nil)
           (mega-lang-declined-file (expand-file-name "declined.eld" lang-dir))
           ;; Replacing a built-in needs a real temporary directory.
           (temporary-file-directory (file-name-as-directory (getenv "TMPDIR"))))
       (cl-letf (((symbol-function 'treesit-language-available-p)
                  (lambda (parser &rest _) (memq parser ,available))))
         ,@body))))

(defun mega-lang-test--mode-for (name)
  "The major mode a file called NAME gets."
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name name "/nonexistent-dir/"))
    (unwind-protect
        (progn (set-auto-mode) major-mode)
      (setq buffer-file-name nil))))

;;;; The table

(ert-deftest mega-lang-every-row-is-well-formed ()
  (dolist (spec mega-languages)
    (let ((row (cdr spec)))
      (should (symbolp (car spec)))
      (should (or (plist-get row :ts) (plist-get row :plain)))
      ;; A tree-sitter mode needs to know which parser to ask about.
      (should (eq (and (plist-get row :ts) t) (and (plist-get row :parser) t)))
      (dolist (pattern (plist-get row :patterns))
        (should (stringp pattern))
        (string-match-p pattern ""))
      (dolist (server (plist-get row :servers))
        (should (seq-every-p #'stringp server)))
      ;; A formatter is an argument list; the only symbols in it are the
      ;; ones mega-format.el knows how to fill in.
      (dolist (formatter (plist-get row :formatters))
        (should (stringp (car formatter)))
        (dolist (argument formatter)
          (should (or (stringp argument)
                      (memq argument '(file edition assume-filename))))))
      (dolist (key '(:indent :ts-indent))
        (should (symbolp (plist-get row key))))
      (should (memq (plist-get row :debug) '(nil rust python native)))
      ;; Nothing in a row that no module reads.
      (let ((keys nil) (rest row))
        (while rest (push (car rest) keys) (setq rest (cddr rest)))
        (dolist (key keys)
          (should (memq key '(:ts :parser :plain :patterns :servers :formatters
                              :indent :ts-indent :debug))))))))

(ert-deftest mega-lang-a-mode-belongs-to-one-language ()
  (dolist (expected '((c-mode . c) (c-ts-mode . c) (c++-mode . cpp) (c++-ts-mode . cpp)
                      (rust-ts-mode . rust) (mega-rust-mode . rust)
                      (python-mode . python) (python-ts-mode . python)
                      (sh-mode . shell) (bash-ts-mode . shell)
                      (js-mode . javascript) (js-ts-mode . javascript)
                      (typescript-ts-mode . typescript) (tsx-ts-mode . tsx)
                      ;; Derives from js-mode, and is JSON all the same.
                      (js-json-mode . json) (json-ts-mode . json)
                      (mega-zig-mode . zig) (mega-markdown-mode . markdown)
                      (verilog-mode . verilog)
                      (fundamental-mode . nil) (text-mode . nil) (prog-mode . nil)
                      (emacs-lisp-mode . nil)))
    (should (equal (cons (car expected) (mega-lang-name (car expected))) expected)))
  ;; A mode somebody derives from one of ours is of the same language.
  (define-derived-mode mega-lang-test-child-mode python-mode "Child")
  (should (eq (mega-lang-name 'mega-lang-test-child-mode) 'python))
  (should (equal (mega-lang-get :debug 'mega-lang-test-child-mode) 'python))
  ;; In a buffer, with nothing said, it is the buffer's own mode.
  (with-temp-buffer
    (let ((inhibit-message t)) (c-mode))
    (should (eq (mega-lang-name) 'c))
    (should (equal (mega-lang-get :formatters) '(("clang-format" assume-filename))))))

(ert-deftest mega-lang-the-indentation-variable-is-the-mode-s-own ()
  "A language has two modes, and they do not always share the variable."
  (dolist (expected '((c-mode . c-basic-offset) (c++-mode . c-basic-offset)
                      (c-ts-mode . c-ts-mode-indent-offset)
                      (c++-ts-mode . c-ts-mode-indent-offset)
                      (rust-ts-mode . rust-ts-mode-indent-offset)
                      (mega-rust-mode . mega-simple-indent-offset)
                      (python-mode . python-indent-offset)
                      (python-ts-mode . python-indent-offset)
                      (sh-mode . sh-basic-offset) (bash-ts-mode . sh-basic-offset)
                      (js-mode . js-indent-level) (js-ts-mode . js-indent-level)
                      (js-json-mode . js-indent-level)
                      (json-ts-mode . json-ts-mode-indent-offset)
                      (typescript-ts-mode . typescript-ts-mode-indent-offset)
                      (tsx-ts-mode . typescript-ts-mode-indent-offset)
                      (go-ts-mode . go-ts-mode-indent-offset)
                      (lua-mode . lua-indent-level) (lua-ts-mode . lua-ts-indent-offset)
                      (verilog-mode . verilog-indent-level)
                      (mega-zig-mode . mega-simple-indent-offset)
                      (mega-just-mode . mega-simple-indent-offset)
                      (mega-markdown-mode . nil) (text-mode . nil)))
    (should (equal (cons (car expected) (mega-lang-indent-variable (car expected)))
                   expected))))

(ert-deftest mega-lang-adding-a-language-is-adding-a-row ()
  "One row, and formatting, indentation guides, debugging and snippets follow."
  (require 'mega-format)
  (require 'mega-indent-guides)
  (require 'mega-debug)
  (require 'mega-snippet)
  (define-derived-mode mega-lang-test-kotlin-mode prog-mode "Kotlin")
  (defvar mega-lang-test-kotlin-indent 6)
  (let ((mega-languages
         (cons '(kotlin :plain mega-lang-test-kotlin-mode
                        :formatters (("ktfmt" "--stdin-name" file "-"))
                        :indent mega-lang-test-kotlin-indent
                        :debug python)
               mega-languages))
        (mega-snippets (cons '((kotlin) ("fun" . "fun ${1:name}() {\n    $0\n}"))
                             mega-snippets))
        (mega-exec-context-functions nil))
    (mega-test-with-directory dir
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "Main.kt" dir))
        (unwind-protect
            (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) t)))
              (mega-lang-test-kotlin-mode)
              (should (eq (mega-lang-name) 'kotlin))
              (should (equal (mega-format-command)
                             (list "ktfmt" "--stdin-name" buffer-file-name "-")))
              (should (= (mega-indent-guides-offset) 6))
              (should (eq (mega-debug-language dir) 'python))
              (should (assoc "fun" (mega-snippet-available)))
              ;; And what every code buffer gets is still there.
              (should (assoc "todo" (mega-snippet-available))))
          (setq buffer-file-name nil))))))

(ert-deftest mega-lang-every-mode-in-the-table-exists ()
  (dolist (spec mega-languages)
    (dolist (mode (mega-lang--modes (cdr spec)))
      (should (fboundp mode)))))

;;;; Which mode a file gets

(ert-deftest mega-lang-without-parsers-files-get-the-plain-mode ()
  (mega-lang-test--with-parsers nil
    (dolist (expected '(("main.rs" . mega-rust-mode) ("lib.c" . c-mode)
                        ("tool.py" . python-mode) ("run.sh" . sh-mode)
                        ("app.ts" . js-mode) ("view.tsx" . js-mode)
                        ("ci.yaml" . conf-colon-mode) ("ci.yml" . conf-colon-mode)
                        ("Cargo.toml" . conf-toml-mode) ("data.json" . js-json-mode)
                        ("README.md" . mega-markdown-mode) ("build.zig" . mega-zig-mode)
                        ("justfile" . mega-just-mode) ("Justfile" . mega-just-mode)
                        (".justfile" . mega-just-mode) ("ci.just" . mega-just-mode)
                        ("cpu.sv" . verilog-mode) ("init.lua" . lua-mode)
                        ;; No parser and no plain mode: plain text, not an error.
                        ("main.go" . fundamental-mode)
                        ("CMakeLists.txt" . fundamental-mode)))
      (should (eq (mega-lang-test--mode-for (car expected)) (cdr expected))))))

(ert-deftest mega-lang-with-the-parser-a-file-gets-the-tree-sitter-mode ()
  (mega-lang-test--with-parsers '(rust python)
    (let (entered)
      (cl-letf (((symbol-function 'rust-ts-mode) (lambda () (push 'rust-ts-mode entered)))
                ((symbol-function 'python-ts-mode) (lambda () (push 'python-ts-mode entered))))
        (mega-lang-test--mode-for "main.rs")
        (mega-lang-test--mode-for "tool.py")
        (should (equal (reverse entered) '(rust-ts-mode python-ts-mode))))
      ;; A language whose parser is still missing is unaffected.
      (should (eq (mega-lang-test--mode-for "lib.c") 'c-mode)))))

(ert-deftest mega-lang-ordinary-files-are-not-captured ()
  (mega-lang-test--with-parsers nil
    (should (eq (mega-lang-test--mode-for "notes.txt") 'text-mode))
    (should (eq (mega-lang-test--mode-for "init.el") 'emacs-lisp-mode))
    ;; "justfile" must be the whole name, not the end of one.
    (should-not (eq (mega-lang-test--mode-for "notajustfile") 'mega-just-mode))))

;;;; Parsers: asked once, never in a script

(ert-deftest mega-lang-a-missing-parser-is-never-offered-in-batch ()
  (mega-lang-test--with-parsers nil
    (let ((treesit-auto-install-grammar 'ask) asked)
      (cl-letf (((symbol-function 'treesit-ensure-installed)
                 (lambda (&rest _) (setq asked t) nil)))
        (should-not (mega-lang-parser-p 'rust))
        (should-not asked)))))

(defmacro mega-lang-test--offering (answer builds &rest body)
  "Run BODY with Emacs's parser offer answered ANSWER and the build doing BUILDS.
ASKED counts the offers made.  The stand-in asks its question the way
Emacs does, through `y-or-n-p', and installs only after a yes; BUILDS is
what the installation returns, or `error' to make it signal."
  (declare (indent 2))
  `(let ((treesit-auto-install-grammar 'ask) (noninteractive nil) (asked 0))
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (&rest _) (setq asked (1+ asked)) ,answer))
               ((symbol-function 'treesit-ensure-installed)
                (lambda (&rest _)
                  (and (y-or-n-p "Tree-sitter grammar is missing; install it?")
                       (if (eq ,builds 'error) (error "No compiler") ,builds)))))
       ,@body)))

(ert-deftest mega-lang-a-declined-parser-is-remembered-and-not-offered-again ()
  (mega-lang-test--with-parsers nil
    (mega-lang-test--offering nil nil
      (should-not (mega-lang-parser-p 'rust))
      (should-not (mega-lang-parser-p 'rust))
      (should (= asked 1))
      ;; Remembered across sessions, too.
      (setq mega-lang--declined 'unread)
      (should-not (mega-lang-parser-p 'rust))
      (should (= asked 1))
      ;; Until the user says to ask again.
      (mega-lang-ask-again)
      (should-not (mega-lang-parser-p 'rust))
      (should (= asked 2)))))

(ert-deftest mega-lang-a-parser-that-failed-to-build-is-offered-again ()
  "Saying yes with no network or no compiler is not saying no."
  (mega-lang-test--with-parsers nil
    (dolist (outcome '(nil error))
      (mega-lang-test--offering t outcome
        (should-not (mega-lang-parser-p 'rust))
        (should-not (memq 'rust (mega-lang--declined)))
        ;; The offer comes again the next time such a file is opened.
        (should-not (mega-lang-parser-p 'rust))
        (should (= asked 2))))
    ;; And whatever happened, the question function is Emacs's own again.
    (should (eq (symbol-function 'y-or-n-p)
                (default-toplevel-value 'mega-lang-test--y-or-n-p)))))

(ert-deftest mega-lang-an-accepted-parser-is-used ()
  (mega-lang-test--with-parsers nil
    (mega-lang-test--offering t t
      (should (mega-lang-parser-p 'rust))
      (should (= asked 1))
      (should-not (memq 'rust (mega-lang--declined))))))

(ert-deftest mega-lang-with-the-prompt-switched-off-nothing-is-asked ()
  (mega-lang-test--with-parsers nil
    (let ((noninteractive nil) asked)
      (cl-letf (((symbol-function 'treesit-ensure-installed)
                 (lambda (&rest _) (setq asked t) nil)))
        (should-not (mega-lang-parser-p 'rust))
        (should-not asked)
        ;; And nothing is recorded as declined: nobody was asked.
        (should-not (mega-lang--declined))))))

(ert-deftest mega-lang-the-declined-list-is-data ()
  (mega-lang-test--with-parsers nil
    (mega-test-write mega-lang-declined-file "(progn (setq mega-test-pwned t))")
    (makunbound 'mega-test-pwned)
    (setq mega-lang--declined 'unread)
    ;; It is a list of symbols or it is nothing; this is neither.
    (should-not (mega-lang--declined))
    (should-not (boundp 'mega-test-pwned))
    (mega-test-write mega-lang-declined-file "(rust go)")
    (setq mega-lang--declined 'unread)
    (should (equal (mega-lang--declined) '(rust go)))))

(ert-deftest mega-lang-parsers-are-built-into-the-data-directory ()
  (should (member (expand-file-name "tree-sitter/" mega-data-dir)
                  treesit-extra-load-path)))

;;;; Language servers

(ert-deftest mega-lang-the-first-installed-server-is-used ()
  (let ((spec (assq 'python mega-languages)))
    (cl-letf (((symbol-function 'mega-exec-find)
               (lambda (program &rest _) (member program '("pyright-langserver" "pylsp")))))
      (should (equal (mega-lang-server spec) '("pyright-langserver" "--stdio"))))
    (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
      (should-not (mega-lang-server spec)))))

(ert-deftest mega-lang-a-server-starts-only-when-it-is-installed ()
  (let (started)
    (cl-letf (((symbol-function 'eglot-ensure) (lambda () (setq started t)))
              ((symbol-function 'mega-trust-p) (lambda (&rest _) t)))
      (with-temp-buffer
        (setq buffer-file-name "/nonexistent-dir/main.rs"
              major-mode 'mega-rust-mode)
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
                (mega-lang-start-server)
                (should-not started))
              (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) t)))
                (mega-lang-start-server)
                (should started)))
          (setq buffer-file-name nil))))))

(ert-deftest mega-lang-a-server-starts-only-in-a-trusted-project ()
  "A language server runs the project's build scripts.  Not trusted: no
server, and no question either, because opening a file is not one."
  (let ((started nil) (asked 'not-called) (said nil)
        (mega-lang--told nil))
    (cl-letf (((symbol-function 'eglot-ensure) (lambda () (setq started t)))
              ((symbol-function 'mega-exec-find) (lambda (&rest _) t))
              ((symbol-function 'message)
               (lambda (format &rest arguments)
                 (setq said (and format (apply #'format-message format arguments))))))
      (with-temp-buffer
        (setq buffer-file-name "/nonexistent-dir/main.rs"
              major-mode 'mega-rust-mode)
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'mega-trust-p)
                         (lambda (_dir &optional ask &rest _) (setq asked ask) nil)))
                (mega-lang-start-server)
                (should-not started)
                ;; It did not ask, and said how to let the server run.
                (should-not asked)
                (should (string-match-p "C-c y" said))
                ;; Once per project, not once per file.
                (setq said nil)
                (mega-lang-start-server)
                (should-not said)
                ;; `M-x eglot' is a command you gave: that may ask.
                (cl-letf (((symbol-function 'mega-trust-p)
                           (lambda (_dir &optional ask &rest _) (setq asked ask) nil)))
                  (should-error (mega-lang--contact) :type 'user-error)
                  (should asked)))
              ;; With no stub at all an undecided project counts as untrusted.
              (let ((mega-trust--decisions nil))
                (mega-lang-start-server)
                (should-not started)))
          (setq buffer-file-name nil))))))

(ert-deftest mega-lang-no-server-is-started-for-a-remote-file-or-no-file ()
  (let (started)
    (cl-letf (((symbol-function 'eglot-ensure) (lambda () (setq started t)))
              ((symbol-function 'mega-exec-find) (lambda (&rest _) t)))
      (with-temp-buffer
        (setq major-mode 'mega-rust-mode)
        (mega-lang-start-server)
        (setq buffer-file-name "/ssh:host:/src/main.rs")
        (unwind-protect
            (mega-lang-start-server)
          (setq buffer-file-name nil)))
      (should-not started))))

(ert-deftest mega-lang-the-server-command-goes-through-the-execution-context ()
  "That is what lets a server run inside a project's container."
  (with-temp-buffer
    (setq major-mode 'mega-rust-mode)
    (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) t))
              ((symbol-function 'mega-trust-p) (lambda (&rest _) t)))
      (let ((mega-exec-context-functions nil))
        (should (equal (mega-lang--contact) '("rust-analyzer"))))
      (let ((mega-exec-context-functions
             (list (lambda (_) (list :kind 'test
                                     :find (lambda (_) t)
                                     :wrap (lambda (program args _)
                                             (append '("podman" "exec" "box" ) (cons program args))))))))
        (should (equal (mega-lang--contact) '("podman" "exec" "box" "rust-analyzer")))))))

(ert-deftest mega-lang-asking-for-a-server-that-is-not-installed-says-so ()
  (with-temp-buffer
    (setq major-mode 'mega-rust-mode)
    (cl-letf (((symbol-function 'mega-exec-find) (lambda (&rest _) nil)))
      (should-error (mega-lang--contact) :type 'user-error))))

(ert-deftest mega-lang-eglot-is-told-about-every-language-with-a-server ()
  (require 'eglot)
  (dolist (spec mega-languages)
    (when (plist-get (cdr spec) :servers)
      (dolist (mode (mega-lang--modes (cdr spec)))
        (should (eq (cdr (seq-find (lambda (entry) (memq mode (ensure-list (car entry))))
                                   eglot-server-programs))
                    #'mega-lang--contact))))))

(ert-deftest mega-lang-the-doctor-reports-each-language ()
  (require 'mega-doctor)
  (mega-lang-test--with-parsers '(rust)
    (cl-letf (((symbol-function 'mega-exec-find)
               (lambda (program &rest _) (equal program "rust-analyzer"))))
      (let ((report (with-temp-buffer (mega-lang--doctor) (buffer-string))))
        (should (string-match-p "rust +parser built +server: rust-analyzer" report))
        (should (string-match-p "c +parser missing +no server (clangd)" report))
        (should (string-match-p "just +own mode" report))))))

;;;; The language server setup

(ert-deftest mega-lsp-keeps-no-log-and-sends-no-telemetry ()
  (should (equal (plist-get eglot-events-buffer-config :size) 0))
  (should (eq (plist-get (plist-get (plist-get (default-value 'eglot-workspace-configuration)
                                               :redhat)
                                    :telemetry)
                         :enabled)
              :json-false)))

(ert-deftest mega-lsp-a-project-cannot-switch-telemetry-back-on ()
  "A project may configure its server; MEGA's privacy settings stay on top."
  (with-temp-buffer
    (setq-local eglot-workspace-configuration
                '(:rust-analyzer (:check (:command "clippy"))
                  :telemetry (:enableTelemetry t :level "all")
                  :redhat (:telemetry (:enabled t))))
    (run-hooks 'hack-local-variables-hook)
    (let ((now eglot-workspace-configuration))
      ;; What the project asked for and MEGA has no view on is kept...
      (should (equal (plist-get (plist-get (plist-get now :rust-analyzer) :check) :command)
                     "clippy"))
      (should (equal (plist-get (plist-get now :telemetry) :level) "all"))
      ;; ...and the switches MEGA sets are as MEGA sets them.
      (should (eq (plist-get (plist-get now :telemetry) :enableTelemetry) :json-false))
      (should (eq (plist-get (plist-get (plist-get now :redhat) :telemetry) :enabled)
                  :json-false))))
  ;; The older way of writing it, and a function, are covered too.
  (with-temp-buffer
    (setq-local eglot-workspace-configuration
                '((telemetry . (:enableTelemetry t)) (:gopls . (:staticcheck t))))
    (run-hooks 'hack-local-variables-hook)
    (should (eq (plist-get (plist-get eglot-workspace-configuration :telemetry)
                           :enableTelemetry)
                :json-false))
    (should (plist-get (plist-get eglot-workspace-configuration :gopls) :staticcheck)))
  (with-temp-buffer
    (setq-local eglot-workspace-configuration
                (lambda (_server) '(:telemetry (:enableTelemetry t))))
    (run-hooks 'hack-local-variables-hook)
    (should (eq (plist-get (plist-get (funcall eglot-workspace-configuration nil)
                                      :telemetry)
                           :enableTelemetry)
                :json-false)))
  ;; A buffer whose project says nothing keeps the default, untouched.
  (with-temp-buffer
    (run-hooks 'hack-local-variables-hook)
    (should-not (local-variable-p 'eglot-workspace-configuration))))

(ert-deftest mega-lsp-never-blocks-on-a-server-and-leaves-none-behind ()
  (should-not eglot-sync-connect)
  (should eglot-autoshutdown))


(ert-deftest mega-lsp-documentation-is-wrapped-cut-and-unfenced ()
  (should (equal (mega-doc-lines "fn main()\n\n```rust\nlet x = 1;\n```\nThe end" 40 10)
                 '("fn main()" "" "let x = 1;" "The end")))
  (should (equal (mega-doc-lines "one two three four five six seven" 14 10)
                 '("one two three" "four five six" "seven")))
  (should (= 2 (length (mega-doc-lines "a\nb\nc\nd" 40 2)))))

(ert-deftest mega-lsp-the-popup-falls-back-to-a-window-where-it-cannot-be-drawn ()
  (let (shown)
    (cl-letf (((symbol-function 'mega-doc-buffer) (lambda () (setq shown 'buffer))))
      (mega-doc-popup)
      (should (eq shown 'buffer)))))

(ert-deftest mega-lsp-the-popup-shows-only-when-asked ()
  (let (drawn)
    (cl-letf (((symbol-function 'mega-popup-show)
               (lambda (_name lines &rest _) (setq drawn lines) t)))
      (let ((mega-doc--pending nil))
        (mega-doc--display '(("Some documentation")) nil)
        (should-not drawn))
      (let ((mega-doc--pending t))
        (mega-doc--display '(("Some documentation") ("More")) nil)
        (should (equal drawn '(" Some documentation " "  " " More ")))
        (should-not mega-doc--pending))
      (remove-hook 'pre-command-hook #'mega-doc-popup-hide))))

;;;; MEGA's own modes

(defun mega-lang-test--face-at (text mode needle)
  "The face on the first character of NEEDLE in TEXT highlighted by MODE."
  (with-temp-buffer
    (insert text)
    (funcall mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward needle)
    (get-text-property (match-beginning 0) 'face)))

(defun mega-lang-test--indented (mode &rest lines)
  "LINES with their indentation removed, then re-indented by MODE."
  (with-temp-buffer
    (insert (mapconcat #'string-trim-left lines "\n"))
    (funcall mode)
    (let ((inhibit-message t))
      (indent-region (point-min) (point-max)))
    (split-string (buffer-string) "\n")))

(defun mega-lang-test--index (mode text)
  "The names in the buffer index of TEXT in MODE, flattened."
  (with-temp-buffer
    (insert text)
    (funcall mode)
    (let (names)
      (dolist (entry (funcall imenu-create-index-function))
        (if (imenu--subalist-p entry)
            (dolist (sub (cdr entry)) (push (car sub) names))
          (push (car entry) names)))
      (sort names #'string<))))

(ert-deftest mega-rust-mode-highlights-the-basics ()
  (let ((code "// a comment\npub fn main() {\n    let name: String = \"text\".into();\n    println!(\"{}\", MAX_SIZE);\n}\nstruct Point { x: f64 }\n"))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "a comment") 'font-lock-comment-face))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "fn main") 'font-lock-keyword-face))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "main") 'font-lock-function-name-face))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "\"text\"") 'font-lock-string-face))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "String") 'font-lock-type-face))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "println!") 'font-lock-preprocessor-face))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "MAX_SIZE") 'font-lock-constant-face))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "Point") 'font-lock-type-face))))

(ert-deftest mega-rust-mode-a-lifetime-is-not-an-open-string ()
  "The quote of a lifetime must not swallow the rest of the file."
  (let ((code "fn first<'a>(x: &'a str) -> &'a str { x }\nfn next() {}\n"))
    (should (eq (mega-lang-test--face-at code #'mega-rust-mode "next") 'font-lock-function-name-face))))

(ert-deftest mega-rust-mode-indents-by-nesting ()
  (should (equal (mega-lang-test--indented
                  #'mega-rust-mode
                  "impl Point {" "fn new(" "x: f64," ") -> Self {" "Point { x }" "}"
                  "}" "let value = builder" ".first()" ".second();")
                 '("impl Point {" "    fn new(" "        x: f64," "    ) -> Self {"
                   "        Point { x }" "    }" "}"
                   "let value = builder" "    .first()" "    .second();"))))

(ert-deftest mega-rust-mode-leaves-strings-and-block-comments-alone ()
  (with-temp-buffer
    (insert "fn f() {\n/* a comment\n      shaped by hand */\n}\n")
    (mega-rust-mode)
    (goto-char (point-min))
    (forward-line 2)
    (let ((before (buffer-string)))
      (indent-according-to-mode)
      (should (equal (buffer-string) before)))))

(ert-deftest mega-rust-mode-lists-definitions ()
  (should (equal (mega-lang-test--index
                  #'mega-rust-mode
                  "pub struct Point;\nimpl Point {\n    pub fn new() {}\n}\nasync fn run() {}\nmod tests {}\nmacro_rules! my_macro {}\n")
                 '("Point" "Point" "my_macro" "new" "run" "tests"))))

(ert-deftest mega-rust-mode-comments-with-two-slashes ()
  (with-temp-buffer
    (insert "let x = 1;")
    (mega-rust-mode)
    (comment-line 1)
    (should (equal (buffer-string) "// let x = 1;"))))

(ert-deftest mega-zig-mode-highlights-indents-and-lists ()
  (let ((code "// note\npub fn main() !void {\n    const x: u32 = @intCast(1);\n}\nconst Point = struct {};\ntest \"adds\" {}\n"))
    (should (eq (mega-lang-test--face-at code #'mega-zig-mode "note") 'font-lock-comment-face))
    (should (eq (mega-lang-test--face-at code #'mega-zig-mode "main") 'font-lock-function-name-face))
    (should (eq (mega-lang-test--face-at code #'mega-zig-mode "@intCast") 'font-lock-builtin-face))
    (should (eq (mega-lang-test--face-at code #'mega-zig-mode "u32") 'font-lock-type-face))
    (should (equal (mega-lang-test--index #'mega-zig-mode code) '("Point" "adds" "main"))))
  (should (equal (mega-lang-test--indented #'mega-zig-mode
                                           "fn f() void {" "if (x) {" "y();" "}" "}")
                 '("fn f() void {" "    if (x) {" "        y();" "    }" "}"))))

(ert-deftest mega-zig-mode-has-no-block-comments ()
  "In Zig /* is not a comment; treating it as one would hide code."
  (let ((code "const a = b /* c;\nfn visible() void {}\n"))
    (should (eq (mega-lang-test--face-at code #'mega-zig-mode "visible") 'font-lock-function-name-face))))

(ert-deftest mega-just-mode-highlights-and-lists-recipes ()
  (let ((code "# build things\nset shell := [\"bash\"]\nversion := \"1.0\"\n\nbuild target=\"all\": deps\n    cargo build {{target}}\n\n@test:\n    cargo test\n"))
    (should (eq (mega-lang-test--face-at code #'mega-just-mode "build things") 'font-lock-comment-face))
    (should (eq (mega-lang-test--face-at code #'mega-just-mode "build target") 'font-lock-function-name-face))
    (should (eq (mega-lang-test--face-at code #'mega-just-mode "version") 'font-lock-variable-name-face))
    (should (eq (mega-lang-test--face-at code #'mega-just-mode "set shell") 'font-lock-keyword-face))
    (should (equal (mega-lang-test--index #'mega-just-mode code) '("build" "test")))))

(ert-deftest mega-just-mode-indents-bodies-and-nothing-else ()
  (should (equal (mega-lang-test--indented
                  #'mega-just-mode
                  "version := \"1\"" "" "build: deps" "cargo build" "cargo doc" ""
                  "test:" "cargo test" "alias t := test")
                 '("version := \"1\"" "" "build: deps" "    cargo build" "    cargo doc" ""
                   "test:" "    cargo test" "alias t := test"))))

(ert-deftest mega-markdown-mode-highlights-the-basics ()
  (let ((text "# Title\n\nSome **bold** and *slanted* text with `code`.\n\n## Section\n\n- item one\n> quoted\n\nA [link](https://example.org).\n"))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "# Title") 'outline-1))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "## Section") 'outline-2))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "**bold**") 'mega-markdown-bold))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "*slanted*") 'mega-markdown-italic))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "`code`") 'mega-markdown-code))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "- item") 'mega-markdown-marker))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "> quoted") 'mega-markdown-quote))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "link") 'mega-markdown-link))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "https://") 'mega-markdown-url))))

(ert-deftest mega-markdown-mode-a-code-block-is-code-not-markdown ()
  (let ((text "Intro\n\n```sh\n# not a heading\necho **not bold**\n```\n\n# Real heading\n"))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "# not a heading")
                'mega-markdown-code))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "**not bold**")
                'mega-markdown-code))
    (should (eq (mega-lang-test--face-at text #'mega-markdown-mode "# Real heading")
                'outline-1))
    ;; And a # inside the block is not listed as a heading.
    (should (equal (mega-lang-test--index #'mega-markdown-mode text) '("Real heading")))))

(ert-deftest mega-markdown-mode-lists-headings-by-level ()
  (should (equal (with-temp-buffer
                   (insert "# One\n## Two\n### Three ###\n# Four\n")
                   (mega-markdown-mode)
                   (mapcar #'car (funcall imenu-create-index-function)))
                 '("One" "  Two" "    Three" "Four"))))

(ert-deftest mega-markdown-mode-headings-fold ()
  (with-temp-buffer
    (insert "# One\nbody one\n## Two\nbody two\n# Three\nbody three\n")
    (mega-markdown-mode)
    (should outline-minor-mode)
    (goto-char (point-min))
    (should (looking-at outline-regexp))
    (should (= (funcall outline-level) 1))
    (forward-line 2)
    (should (looking-at outline-regexp))
    (should (= (funcall outline-level) 2))
    (goto-char (point-min))
    (outline-hide-subtree)
    (should (invisible-p (save-excursion (search-forward "body two") (1- (point)))))
    (should-not (invisible-p (save-excursion (search-forward "body three") (1- (point)))))))

(ert-deftest mega-markdown-mode-refilling-keeps-list-items-apart ()
  (with-temp-buffer
    (insert "- first item\n- second item\n")
    (mega-markdown-mode)
    (goto-char (point-min))
    (fill-paragraph)
    (should (equal (buffer-string) "- first item\n- second item\n"))))

(provide 'mega-lang-test)
;;; mega-lang-test.el ends here
