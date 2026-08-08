;;; mega-lang-verilog.el --- SystemVerilog  -*- lexical-binding: t; -*-

;;; Commentary:

;; The only language that needs its own file.  It is the sole entry in
;; `mega-languages' with no mode in core, a non-obvious grammar, and a real
;; choice of server.
;;
;; Grammar: gmlarumbe/tree-sitter-systemverilog, not the tree-sitter org's
;; tree-sitter-verilog.  verilog-ts-mode requires it specifically, and its
;; author describes it as substantially more robust.  The language is called
;; `systemverilog' to tree-sitter, which is why the row below does not simply
;; say `verilog'.
;;
;; Server: verible-verilog-ls is the recommendation — a single Google-maintained
;; binary with no npm or Verilator dependency, unlike svlangserver (needs both)
;; and veridian (needs slang).  svls and veridian are listed as fallbacks so
;; that whichever you already have is used.
;;
;; None of these are installed on this machine yet; `mega-doctor' prints the
;; install command.

;;; Code:

(require 'mega-lib)

;; Defined in mega-lang.el, which requires this file after declaring it.  The
;; forward declaration keeps the byte-compiler quiet without a circular require.
(defvar mega-languages)

(use-package verilog-ts-mode
  :ensure t
  :commands (verilog-ts-mode verilog-ts-install-grammar))

;; verilog-mode ships with Emacs and stays the fallback when the grammar is
;; missing, which is what `mega-lang-apply' arranges via :remap.
;;
;; This is a constant rather than an `add-to-list' call, because the byte
;; compiler evaluates top-level `require' forms: mutating `mega-languages' from
;; here would run during the compilation of mega-lang.el, before its `defvar'
;; has given the variable a value.  mega-lang.el appends this instead.
(defconst mega-lang-verilog-spec
  '(systemverilog
    :grammars ((systemverilog
                "https://github.com/gmlarumbe/tree-sitter-systemverilog"
                "v0.4.0"))
    :remap ((verilog-mode . verilog-ts-mode))
    :modes (verilog-ts-mode)
    :auto-mode (("\\.s?vh?\\'" . verilog-ts-mode))
    :servers (("verible-verilog-ls")
              ("svls")
              ("veridian")))
  "The SystemVerilog row of `mega-languages'.")

(provide 'mega-lang-verilog)
;;; mega-lang-verilog.el ends here
