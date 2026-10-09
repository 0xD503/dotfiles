;;; mega-mode-zig.el --- Zig  -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs ships no mode for Zig.  This is a small one; see mega-mode-simple.el
;; for what it does and does not do.  The zls language server, when it is
;; installed, supplies completion, diagnostics, navigation and formatting.

;;; Code:

(require 'mega-mode-simple)

(defconst mega-zig-keywords
  '("addrspace" "align" "allowzero" "and" "anyframe" "anytype" "asm" "async"
    "await" "break" "callconv" "catch" "comptime" "const" "continue" "defer"
    "else" "enum" "errdefer" "error" "export" "extern" "fn" "for" "if"
    "inline" "linksection" "noalias" "noinline" "nosuspend" "opaque" "or"
    "orelse" "packed" "pub" "resume" "return" "struct" "suspend" "switch"
    "test" "threadlocal" "try" "union" "unreachable" "usingnamespace" "var"
    "volatile" "while")
  "Zig keywords.")

(defconst mega-zig-types
  '("bool" "void" "noreturn" "type" "anyerror" "anyopaque" "comptime_int"
    "comptime_float" "usize" "isize" "f16" "f32" "f64" "f80" "f128"
    "c_char" "c_short" "c_ushort" "c_int" "c_uint" "c_long" "c_ulong"
    "c_longlong" "c_ulonglong")
  "Zig types worth recognising by name.")

(defconst mega-zig-font-lock-keywords
  `(("\\_<fn[ \t]+\\([[:alnum:]_]+\\)" 1 'font-lock-function-name-face)
    ("\\_<\\(?:const\\|var\\)[ \t]+\\([[:alnum:]_]+\\)" 1 'font-lock-variable-name-face)
    ("@[[:alpha:]_][[:alnum:]_]*" 0 'font-lock-builtin-face)
    (,(regexp-opt mega-zig-keywords 'symbols) 0 'font-lock-keyword-face)
    (,(regexp-opt '("true" "false" "null" "undefined") 'symbols) 0 'font-lock-constant-face)
    (,(regexp-opt mega-zig-types 'symbols) 0 'font-lock-type-face)
    ("\\_<[iu][0-9]+\\_>" 0 'font-lock-type-face)
    ("\\_<[A-Z][[:alnum:]_]*\\_>" 0 'font-lock-type-face)
    ("^[ \t]*\\(\\\\\\\\.*\\)$" 1 'font-lock-string-face t)
    ("\\_<[0-9][0-9a-fA-FxXob_.]*\\_>" 0 'font-lock-number-face))
  "Highlighting for `mega-zig-mode'.")

(defconst mega-zig-imenu-expression
  '(("Functions" "^[ \t]*\\(?:pub[ \t]+\\)?\\(?:export[ \t]+\\|inline[ \t]+\\|extern[ \t]+\\)*fn[ \t]+\\([[:alnum:]_]+\\)" 1)
    ("Types" "^[ \t]*\\(?:pub[ \t]+\\)?const[ \t]+\\([[:alnum:]_]+\\)[ \t]*=[ \t]*\\(?:packed[ \t]+\\|extern[ \t]+\\)?\\(?:struct\\|enum\\|union\\|opaque\\|error\\)" 1)
    ("Tests" "^[ \t]*test[ \t]+\"\\([^\"]+\\)\"" 1))
  "Definitions `mega-zig-mode' lists in the buffer index.")

;;;###autoload
(define-derived-mode mega-zig-mode prog-mode "Zig"
  "A small mode for Zig."
  :syntax-table (mega-simple-syntax-table nil)
  (mega-simple-setup "//")
  (setq-local font-lock-defaults '(mega-zig-font-lock-keywords)
              imenu-generic-expression mega-zig-imenu-expression))

(provide 'mega-mode-zig)
;;; mega-mode-zig.el ends here
