;;; mega-mode-rust.el --- Rust without a parser  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs's Rust mode is `rust-ts-mode', which needs the tree-sitter parser
;; for Rust.  When that parser is not built, a Rust file would open with no
;; mode at all; it opens in this one instead.  See mega-lang.el for the
;; choice, and mega-mode-simple.el for what this mode does and does not do.
;; With rust-analyzer running you still get completion, diagnostics,
;; navigation and semantic highlighting.

;;; Code:

(require 'mega-mode-simple)

(defconst mega-rust-keywords
  '("as" "async" "await" "break" "const" "continue" "crate" "dyn" "else"
    "enum" "extern" "fn" "for" "if" "impl" "in" "let" "loop" "match" "mod"
    "move" "mut" "pub" "ref" "return" "static" "struct" "super" "trait"
    "type" "union" "unsafe" "use" "where" "while" "yield")
  "Rust keywords.")

(defconst mega-rust-types
  '("bool" "char" "str" "String" "Self" "Vec" "Option" "Result" "Box"
    "u8" "u16" "u32" "u64" "u128" "usize"
    "i8" "i16" "i32" "i64" "i128" "isize" "f32" "f64")
  "Rust types worth recognising by name.")

(defconst mega-rust-font-lock-keywords
  `(("^[ \t]*#!?\\[[^]\n]*\\]" 0 'font-lock-preprocessor-face)
    (,(concat "\\_<fn[ \t]+\\(" "[[:alnum:]_]+" "\\)")
     1 'font-lock-function-name-face)
    (,(concat "\\_<\\(?:struct\\|enum\\|trait\\|type\\|union\\|impl\\|mod\\)[ \t]+"
              "\\([[:alnum:]_]+\\)")
     1 'font-lock-type-face)
    (,(regexp-opt mega-rust-keywords 'symbols) 0 'font-lock-keyword-face)
    (,(regexp-opt '("true" "false" "self" "None" "Some" "Ok" "Err") 'symbols) 0 'font-lock-constant-face)
    (,(regexp-opt mega-rust-types 'symbols) 0 'font-lock-type-face)
    ("\\_<[[:alpha:]_][[:alnum:]_]*!" 0 'font-lock-preprocessor-face)
    ("'[[:alpha:]_][[:alnum:]_]*\\_>[^']" 0 'font-lock-variable-name-face)
    ("\\_<[A-Z][A-Z0-9_]+\\_>" 0 'font-lock-constant-face)
    ("\\_<[A-Z][[:alnum:]]*[a-z][[:alnum:]]*\\_>" 0 'font-lock-type-face)
    ("\\_<[0-9][0-9a-fA-FxXob_.]*\\(?:[iuf][0-9]+\\|usize\\|isize\\)?\\_>" 0 'font-lock-number-face))
  "Highlighting for `mega-rust-mode'.")

(defconst mega-rust-imenu-expression
  '(("Functions" "^[ \t]*\\(?:pub\\(?:([^)]*)\\)?[ \t]+\\)?\\(?:\\(?:async\\|const\\|unsafe\\|extern[ \t]+\"[^\"]*\"\\)[ \t]+\\)*fn[ \t]+\\([[:alnum:]_]+\\)" 1)
    ("Types" "^[ \t]*\\(?:pub\\(?:([^)]*)\\)?[ \t]+\\)?\\(?:struct\\|enum\\|trait\\|type\\|union\\)[ \t]+\\([[:alnum:]_]+\\)" 1)
    ("Impls" "^[ \t]*impl\\(?:<[^>]*>\\)?[ \t]+\\([^{\n]+?\\)[ \t]*\\(?:{\\|where\\|$\\)" 1)
    ("Modules" "^[ \t]*\\(?:pub\\(?:([^)]*)\\)?[ \t]+\\)?mod[ \t]+\\([[:alnum:]_]+\\)" 1)
    ("Macros" "^[ \t]*macro_rules![ \t]+\\([[:alnum:]_]+\\)" 1))
  "Definitions `mega-rust-mode' lists in the buffer index.")

;;;###autoload
(define-derived-mode mega-rust-mode prog-mode "Rust"
  "A small mode for Rust, used when the tree-sitter parser is not built."
  :syntax-table (mega-simple-syntax-table t)
  (mega-simple-setup "//")
  (setq-local font-lock-defaults '(mega-rust-font-lock-keywords)
              imenu-generic-expression mega-rust-imenu-expression))

(provide 'mega-mode-rust)
;;; mega-mode-rust.el ends here
