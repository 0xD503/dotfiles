;;; mega-lang.el --- Languages, as data  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every language MEGA knows is one row in `mega-languages'.  Adding Go is a
;; row; removing Markdown is deleting one.  There is exactly one function that
;; reads the table, and nothing else in MEGA knows a language name.
;;
;; Each row is (NAME . PLIST) with these keys, all optional except :grammars:
;;
;;   :grammars   list of (LANG URL REVISION [SOURCE-DIR]) — the first is the
;;               primary, and its presence decides whether :remap applies
;;   :remap      alist of (CLASSIC-MODE . TS-MODE), applied only when the
;;               primary grammar is actually installed
;;   :modes      the tree-sitter modes this language uses
;;   :auto-mode  extra (REGEXP . MODE) entries for modes Emacs does not know
;;   :servers    candidate LSP command lines, best first; the first whose
;;               binary exists on this machine wins, and if none do, nothing
;;               is registered at all
;;   :setup      a function added to each mode's hook
;;
;; Revisions are pinned to upstream release tags.  Run `M-x mega-treesit-freeze'
;; to convert them to immutable commit SHAs once a set is known good.

;;; Code:

(require 'mega-lib)
(require 'mega-treesit)

(defvar mega-languages
  '((c
     :grammars ((c "https://github.com/tree-sitter/tree-sitter-c" "v0.24.2"))
     :remap ((c-mode . c-ts-mode))
     :modes (c-ts-mode)
     :servers (("clangd" "--background-index" "--clang-tidy"
                "--header-insertion=never" "--completion-style=detailed")))

    (cpp
     :grammars ((cpp "https://github.com/tree-sitter/tree-sitter-cpp" "v0.23.4"))
     :remap ((c++-mode . c++-ts-mode))
     :modes (c++-ts-mode)
     :servers (("clangd" "--background-index" "--clang-tidy"
                "--header-insertion=never" "--completion-style=detailed")))

    (rust
     :grammars ((rust "https://github.com/tree-sitter/tree-sitter-rust" "v0.24.2"))
     :remap ((rust-mode . rust-ts-mode))
     :modes (rust-ts-mode)
     :auto-mode (("\\.rs\\'" . rust-ts-mode))
     :servers (("rust-analyzer")))

    (python
     :grammars ((python "https://github.com/tree-sitter/tree-sitter-python" "v0.25.0"))
     :remap ((python-mode . python-ts-mode))
     :modes (python-ts-mode)
     ;; basedpyright is a maintained fork of pyright with stricter defaults;
     ;; plain pyright is the fallback.  ruff is a linter/formatter rather than
     ;; a full server — eglot runs one server per buffer, so it is not listed
     ;; here.  Wire it up as a formatter in local.el if you want it.
     :servers (("basedpyright-langserver" "--stdio")
               ("pyright-langserver" "--stdio")))

    (typescript
     :grammars ((typescript "https://github.com/tree-sitter/tree-sitter-typescript"
                            "v0.23.2" "typescript/src"))
     :modes (typescript-ts-mode)
     :auto-mode (("\\.ts\\'" . typescript-ts-mode))
     :servers (("typescript-language-server" "--stdio")))

    (tsx
     :grammars ((tsx "https://github.com/tree-sitter/tree-sitter-typescript"
                     "v0.23.2" "tsx/src"))
     :modes (tsx-ts-mode)
     :auto-mode (("\\.tsx\\'" . tsx-ts-mode))
     :servers (("typescript-language-server" "--stdio")))

    (bash
     :grammars ((bash "https://github.com/tree-sitter/tree-sitter-bash" "v0.25.1"))
     :remap ((sh-mode . bash-ts-mode))
     :modes (bash-ts-mode)
     :servers (("bash-language-server" "start")))

    (lua
     :grammars ((lua "https://github.com/tree-sitter-grammars/tree-sitter-lua" "v0.5.0"))
     :remap ((lua-mode . lua-ts-mode))
     :modes (lua-ts-mode)
     :auto-mode (("\\.lua\\'" . lua-ts-mode))
     :servers (("lua-language-server")))

    (json
     :grammars ((json "https://github.com/tree-sitter/tree-sitter-json" "v0.24.8"))
     :remap ((js-json-mode . json-ts-mode))
     :modes (json-ts-mode)
     :auto-mode (("\\.json\\'" . json-ts-mode))
     :servers (("vscode-json-language-server" "--stdio")))

    (yaml
     :grammars ((yaml "https://github.com/tree-sitter-grammars/tree-sitter-yaml" "v0.7.2"))
     :modes (yaml-ts-mode)
     :auto-mode (("\\.ya?ml\\'" . yaml-ts-mode))
     :servers (("yaml-language-server" "--stdio")))

    (toml
     :grammars ((toml "https://github.com/tree-sitter-grammars/tree-sitter-toml" "v0.7.0"))
     :remap ((conf-toml-mode . toml-ts-mode))
     :modes (toml-ts-mode)
     :auto-mode (("\\.toml\\'" . toml-ts-mode))
     :servers (("taplo" "lsp" "stdio")))

    (markdown
     :grammars ((markdown "https://github.com/tree-sitter-grammars/tree-sitter-markdown"
                          "v0.5.3" "tree-sitter-markdown/src")
                (markdown-inline "https://github.com/tree-sitter-grammars/tree-sitter-markdown"
                                 "v0.5.3" "tree-sitter-markdown-inline/src"))
     :modes (markdown-ts-mode)
     :auto-mode (("\\.md\\'" . markdown-ts-mode))
     :servers (("marksman" "server")))

    (zig
     :grammars ((zig "https://github.com/tree-sitter-grammars/tree-sitter-zig" "v1.1.2"))
     :modes (zig-ts-mode)
     :auto-mode (("\\.\\(zig\\|zon\\)\\'" . zig-ts-mode))
     :servers (("zls"))))
  "Every language MEGA configures.  See the Commentary for the row format.
SystemVerilog is the one exception: it needs real work and lives in
mega-lang-verilog.el, which appends its row here.")

;;;; The one function that reads the table

(defun mega-lang--hook (mode)
  "The hook symbol for major MODE."
  (intern (format "%s-hook" mode)))

(defun mega-lang--first-available-server (candidates)
  "Return the first command line in CANDIDATES whose binary exists."
  (seq-find (lambda (cmd) (mega-exe-p (car cmd))) candidates))

(defun mega-lang-apply (spec)
  "Configure one language from SPEC, a row of `mega-languages'."
  (let* ((plist (cdr spec))
         (grammars (plist-get plist :grammars))
         (primary (caar grammars))
         (modes (plist-get plist :modes))
         (server (mega-lang--first-available-server (plist-get plist :servers)))
         (setup (plist-get plist :setup)))

    ;; Grammar sources are always registered, so `mega-treesit-install-all' can
    ;; build a language whose grammar is not present yet.
    (dolist (grammar grammars)
      (apply #'mega-treesit-register grammar))

    ;; Remap only when the grammar is actually installed.  Without this guard a
    ;; missing grammar means every buffer of that language opens broken; with
    ;; it, you simply get the classic mode until you run the installer.
    (when (mega-treesit-ready-p primary)
      (dolist (remap (plist-get plist :remap))
        (add-to-list 'major-mode-remap-alist remap))
      (dolist (entry (plist-get plist :auto-mode))
        (add-to-list 'auto-mode-alist entry)))

    ;; No server binary, no configuration.  Opening a .py file on a machine
    ;; without a language server should do nothing, not error on every save.
    (when (and server modes)
      (with-eval-after-load 'eglot
        (add-to-list 'eglot-server-programs (cons modes server)))
      (dolist (mode modes)
        (add-hook (mega-lang--hook mode) #'eglot-ensure)))

    (when setup
      (dolist (mode modes)
        (add-hook (mega-lang--hook mode) setup)))))

(defun mega-lang-reload ()
  "Re-apply every row of `mega-languages'.
Run this after installing a grammar or a language server to pick it up
without restarting Emacs."
  (interactive)
  (mega-forget-executables)
  (mapc #'mega-lang-apply mega-languages)
  (message "MEGA: %d languages applied" (length mega-languages)))

;;;; The three modes Emacs does not ship

(use-package markdown-ts-mode
  :ensure t
  :commands (markdown-ts-mode))

(use-package zig-ts-mode
  :ensure t
  :commands (zig-ts-mode))

;; SystemVerilog is the one language that needs its own file; its row joins the
;; table here, before the table is walked.
(require 'mega-lang-verilog)
(add-to-list 'mega-languages mega-lang-verilog-spec :append)

(mapc #'mega-lang-apply mega-languages)

(provide 'mega-lang)
;;; mega-lang.el ends here
