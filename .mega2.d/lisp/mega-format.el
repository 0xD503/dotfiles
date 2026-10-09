;;; mega-format.el --- Format on save  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two things shape a file when you save it.
;;
;; * The project's .editorconfig: indentation, line endings, the final
;;   newline, trailing whitespace, the line-length limit.  That is Emacs's own
;;   editorconfig support, switched on in mega-core.el; nothing here.
;;
;; * The language's own formatter, which is what this file runs.  For Rust
;;   that is rustfmt, the program `cargo fmt' runs, with the edition and the
;;   rustfmt.toml of the project; so what you save is what `cargo fmt' would
;;   have produced.  Where a language has no formatter program installed but
;;   its language server can format, the server does it.
;;
;;   C-c c f     format the buffer now
;;   C-c c F     format the whole project (`cargo fmt', `gofmt', ...)
;;
;; The rules, in MEGA's order of priorities:
;;
;; * Formatting is all or nothing.  The buffer is replaced only by the
;;   complete output of a formatter that succeeded; if it fails, times out or
;;   prints nothing, the buffer is left exactly as it was.
;;
;; * Formatting never stops a save.  Whatever goes wrong, the file is saved.
;;
;; * A formatter is a program reading the project's configuration, so it runs
;;   only in a project you have trusted (see mega-trust.el).  Formatters whose
;;   configuration is itself a program, such as prettier, are not in the
;;   table for that reason; add them in local.el if you want them.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)
(require 'mega-trust)

(declare-function mega-project-root "mega-project")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-server-capable "eglot")
(declare-function eglot-format-buffer "eglot")

(defcustom mega-format-on-save t
  "Whether saving a file formats it first.
Set it to nil in a buffer, or in local.el, to save without formatting."
  :type 'boolean :group 'mega :safe #'booleanp)

(defcustom mega-format-timeout 5
  "Seconds a formatter may take before MEGA gives up on it."
  :type 'number :group 'mega)

(defcustom mega-format-max-size (* 1024 1024)
  "Largest buffer, in characters, that is formatted on save."
  :type 'integer :group 'mega)

(defvar mega-formatters
  '(((rust-ts-mode mega-rust-mode) ("rustfmt" "--emit" "stdout" edition))
    ((c-mode c-ts-mode c++-mode c++-ts-mode)
     ("clang-format" assume-filename))
    ((python-mode python-ts-mode)
     ("ruff" "format" "--stdin-filename" file "-")
     ("black" "--quiet" "-"))
    ((sh-mode bash-ts-mode) ("shfmt" "-"))
    ((go-ts-mode) ("gofmt"))
    ((mega-zig-mode) ("zig" "fmt" "--stdin"))
    ((lua-mode lua-ts-mode) ("stylua" "-"))
    ((conf-toml-mode toml-ts-mode) ("taplo" "format" "-")))
  "Formatters by major mode: each element is (MODES COMMAND...).
A COMMAND is an argument list for a program that reads the code on
standard input and writes the formatted code on standard output; the
first whose program exists is used.  The symbols `file', `edition' and
`assume-filename' stand for arguments worked out for the buffer.")

(defvar mega-format-project-commands
  '(("Cargo.toml" "cargo" "fmt")
    ("go.mod" "gofmt" "-w" ".")
    ("build.zig" "zig" "fmt" "."))
  "Whole-project formatters: (MARKER-FILE PROGRAM ARG...) per kind of project.")

;;;; Choosing the formatter

(defun mega-format--rust-edition ()
  "The edition in the nearest Cargo.toml, or nil."
  (when-let* ((directory (locate-dominating-file default-directory "Cargo.toml")))
    (with-temp-buffer
      (insert-file-contents (expand-file-name "Cargo.toml" directory) nil 0 8192)
      (when (re-search-forward "^edition[ \t]*=[ \t]*\"\\([0-9]+\\)\"" nil t)
        (match-string 1)))))

(defun mega-format--expand (command)
  "Return COMMAND with its placeholder symbols replaced for this buffer."
  (let ((file (mega-exec-translate (or buffer-file-name "stdin") 'inside)))
    (apply #'append
           (mapcar (lambda (argument)
                     (pcase argument
                       ('file (list file))
                       ('assume-filename (list (concat "--assume-filename=" file)))
                       ('edition (when-let* ((edition (mega-format--rust-edition)))
                                   (list "--edition" edition)))
                       (_ (list argument))))
                   command))))

(defun mega-format-command ()
  "The formatter command for this buffer, as an argument list, or nil."
  (when-let* ((entry (seq-find (lambda (entry) (apply #'derived-mode-p (car entry)))
                               mega-formatters))
              (command (seq-find (lambda (command) (mega-exec-find (car command)))
                                 (cdr entry))))
    (mega-format--expand command)))

(defun mega-format--server-p ()
  "Non-nil if this buffer's language server can format it."
  (and (fboundp 'eglot-managed-p)
       (eglot-managed-p)
       (ignore-errors (eglot-server-capable :documentFormattingProvider))))

;;;; Formatting

(defun mega-format--apply (formatted)
  "Make the buffer's text FORMATTED, keeping the cursor where it was.
Only what differs is touched, so undo, markers and the view all survive."
  (unless (string= formatted (buffer-string))
    (let ((source (generate-new-buffer " *mega-format*" t)))
      (unwind-protect
          (progn
            (with-current-buffer source (insert formatted))
            (replace-region-contents (point-min) (point-max) source 1))
        (kill-buffer source)))
    t))

(defun mega-format-run (command)
  "Format the buffer with COMMAND and return what happened.
The result is `changed', `unchanged', or a string saying why nothing was
done.  The buffer is modified only in the first case."
  (let* ((result (condition-case err
                     (mega-exec-run (car command) (cdr command)
                                    :input (buffer-string)
                                    :timeout mega-format-timeout)
                   (error (list :failed (error-message-string err)))))
         (output (plist-get result :output)))
    (cond ((plist-get result :failed))
          ((eq (plist-get result :stopped) 'timeout)
           (format "%s took more than %s seconds" (car command) mega-format-timeout))
          ((not (eql (plist-get result :status) 0))
           (format "%s failed: %s" (car command)
                   (car (split-string (concat (plist-get result :error) "\n") "\n"))))
          ;; A formatter that prints nothing for a buffer with text in it has
          ;; not formatted anything; never replace code with emptiness.
          ((and (string-empty-p output) (> (buffer-size) 0))
           (format "%s printed nothing" (car command)))
          ((mega-format--apply output) 'changed)
          (t 'unchanged))))

;;;###autoload
(defun mega-format-buffer (&optional quiet)
  "Format the buffer with its language's formatter.
Returns non-nil if the buffer was changed.  With QUIET, which is how
saving calls it, say nothing unless something went wrong."
  (interactive)
  (let ((command (mega-format-command)))
    (cond
     ((not (mega-trust-p default-directory (not quiet) "run its formatter"))
      (unless quiet
        (message "Not formatting: this project is not trusted"))
      nil)
     (command
      (let ((outcome (mega-format-run command)))
        (cond ((stringp outcome) (message "Not formatted: %s" outcome) nil)
              ((not quiet) (message "Formatted with %s: %s" (car command) outcome)
               (eq outcome 'changed))
              (t (eq outcome 'changed)))))
     ((mega-format--server-p)
      (condition-case err
          (progn (eglot-format-buffer) t)
        (error (message "Not formatted: %s" (error-message-string err)) nil)))
     (t (unless quiet
          (message "No formatter for %s is installed" major-mode))
        nil))))

(defun mega-format-before-save ()
  "Format the buffer as it is being saved.  Never prevents the save."
  (when (and mega-format-on-save
             buffer-file-name
             (not (file-remote-p buffer-file-name))
             (<= (buffer-size) mega-format-max-size))
    (condition-case err
        (mega-format-buffer :quiet)
      (error (message "Not formatted: %s" (error-message-string err))))))

(add-hook 'before-save-hook #'mega-format-before-save)

;;;###autoload
(defun mega-format-project ()
  "Format every file of the project with its own tool, such as `cargo fmt'.
Unsaved buffers are offered for saving first; open buffers pick the
result up by themselves."
  (interactive)
  (let* ((root (or (mega-project-root) default-directory))
         (command (cdr (seq-find (lambda (entry)
                                   (file-exists-p (expand-file-name (car entry) root)))
                                 mega-format-project-commands))))
    (unless command
      (user-error "MEGA knows no whole-project formatter for %s"
                  (abbreviate-file-name root)))
    (unless (mega-trust-p root t (format "run `%s'" (string-join command " ")))
      (user-error "This project is not trusted"))
    (save-some-buffers nil (lambda () (and buffer-file-name
                                           (file-in-directory-p buffer-file-name root))))
    (let ((result (mega-exec-run (car command) (cdr command)
                                 :directory root :timeout 120)))
      (if (eql (plist-get result :status) 0)
          (message "Formatted %s with `%s'" (abbreviate-file-name root)
                   (string-join command " "))
        (message "`%s' failed: %s" (string-join command " ")
                 (string-trim (concat (plist-get result :error)
                                      (plist-get result :output))))))))

;;;; The doctor

(declare-function mega-doctor-heading "mega-doctor")
(declare-function mega-doctor-row "mega-doctor")

(defun mega-format--doctor ()
  "Insert the doctor's section about formatters."
  (mega-doctor-heading "Formatters")
  (dolist (entry mega-formatters)
    (let* ((programs (mapcar #'car (cdr entry)))
           (found (seq-find #'mega-exe-p programs)))
      (mega-doctor-row (replace-regexp-in-string
                        "\\(?:-ts\\)?-mode\\'" "" (symbol-name (caar entry)))
                       (if found
                           (format "%s  (on save, in a trusted project)" found)
                         (format "not found: %s" (string-join programs ", ")))
                       (unless found 'shadow))))
  (insert "\n  Without its formatter a file is saved as you wrote it.\n"))

(add-to-list 'mega-doctor-sections #'mega-format--doctor t)

(provide 'mega-format)
;;; mega-format.el ends here
