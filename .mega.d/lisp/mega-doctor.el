;;; mega-doctor.el --- What is actually working on this machine  -*- lexical-binding: t; -*-

;;; Commentary:

;; `M-x mega-doctor' answers the question a config normally leaves you
;; guessing about: which of this is really running?
;;
;; The motivating case is concrete.  A Doom configuration on this machine
;; enabled +lsp for seven languages and +tree-sitter for five, while exactly
;; two language servers and one grammar were actually installed.  Nothing
;; reported that; the features simply did nothing.  This buffer reports it, and
;; prints the command that fixes each gap.
;;
;; It reports.  It never installs.

;;; Code:

(require 'mega-lib)
(require 'mega-treesit)

;; The doctor reports on these, but it must not depend on them *loading*: the
;; moment you most need the doctor is when one of them is broken.  A hard
;; `require' here means a failure in mega-zone takes out mega-doctor too, which
;; testing duly demonstrated.  Soft requires, and every reference below guarded.
(dolist (module '(mega-lang mega-llm mega-completion mega-edit mega-zone))
  (require module nil :noerror))

(defconst mega-doctor-install-hints
  '(("rust-analyzer"              . "rustup component add rust-analyzer")
    ("clangd"                     . "sudo pacman -S clang")
    ("zls"                        . "paru -S zls")
    ("basedpyright-langserver"    . "paru -S basedpyright   # or: pipx install basedpyright")
    ("pyright-langserver"         . "sudo npm i -g pyright")
    ("verible-verilog-ls"         . "paru -S verible-bin")
    ("svls"                       . "cargo install svls")
    ("veridian"                   . "cargo install --git https://github.com/vivekmalneedi/veridian")
    ("typescript-language-server" . "sudo npm i -g typescript typescript-language-server")
    ("lua-language-server"        . "sudo pacman -S lua-language-server")
    ("marksman"                   . "paru -S marksman")
    ("bash-language-server"       . "sudo npm i -g bash-language-server")
    ("taplo"                      . "sudo pacman -S taplo-cli   # or: cargo install taplo-cli --features lsp")
    ("yaml-language-server"       . "sudo npm i -g yaml-language-server")
    ("vscode-json-language-server" . "sudo npm i -g vscode-langservers-extracted")
    ("rg"                         . "sudo pacman -S ripgrep")
    ("fd"                         . "sudo pacman -S fd")
    ("cc"                         . "sudo pacman -S gcc")
    ("git"                        . "sudo pacman -S git")
    ("claude"                     . "https://claude.com/claude-code"))
  "How to install each tool MEGA looks for, on this distribution.")

(defun mega-doctor--hint (tool)
  "Installation hint for TOOL."
  (or (alist-get tool mega-doctor-install-hints nil nil #'string=)
      "see the tool's documentation"))

(defun mega-doctor--insert-heading (text)
  (insert (propertize (concat "\n" text "\n") 'face 'bold)))

(defun mega-doctor--insert-row (label value &optional face)
  (insert (format "  %-30s %s\n" label (if face (propertize value 'face face) value))))

(defun mega-doctor--yes-no (ok yes no)
  (if ok (propertize yes 'face 'success) (propertize no 'face 'error)))

;;;###autoload
(defun mega-doctor ()
  "Report what MEGA found on this machine, and what is missing."
  (interactive)
  (with-current-buffer (get-buffer-create "*mega-doctor*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (special-mode)
      (insert (propertize "MEGA doctor\n" 'face '(bold underline)))

      ;;;; Emacs itself
      (mega-doctor--insert-heading "Emacs")
      (mega-doctor--insert-row "version" emacs-version)
      (mega-doctor--insert-row "native compilation"
                               (mega-doctor--yes-no
                                (and (fboundp 'native-comp-available-p) (native-comp-available-p))
                                "yes" "NO"))
      (mega-doctor--insert-row "tree-sitter"
                               (if (treesit-available-p)
                                   (format "yes (grammar ABI %s-%s)"
                                           (treesit-library-abi-version t)
                                           (treesit-library-abi-version))
                                 (propertize "NO" 'face 'error)))
      (mega-doctor--insert-row "display"
                               (format "%s, %s colours"
                                       (if (display-graphic-p) "GUI" "terminal")
                                       (display-color-cells)))
      (when (and (not (display-graphic-p)) (< (display-color-cells) 16777216))
        (mega-doctor--insert-row "" "Nord needs 24-bit colour: set COLORTERM=truecolor" 'warning)
        (mega-doctor--insert-row "" "and tmux_conf_24b_colour=true in ~/.tmux.conf.local" 'warning))

      ;;;; Startup
      (mega-doctor--insert-heading "Startup")
      (mega-doctor--insert-row "init time" (emacs-init-time))
      (mega-doctor--insert-row "garbage collections" (format "%d in %.2fs" gcs-done gc-elapsed))
      (mega-doctor--insert-row "packages installed" (number-to-string (length package-alist)))
      (insert "\n  Module load times (slowest first):\n")
      (dolist (entry (seq-take (sort (copy-sequence mega-module-times)
                                     (lambda (a b) (> (cdr a) (cdr b))))
                               20))
        (insert (format "    %-24s %6.1f ms\n" (car entry) (cdr entry))))
      (when mega-module-failures
        (insert (propertize "\n  Modules that FAILED to load:\n" 'face 'error))
        (dolist (failure (reverse mega-module-failures))
          (insert (format "    %-24s %s\n" (car failure) (cdr failure)))))

      ;;;; Grammars
      (mega-doctor--insert-heading "Tree-sitter grammars")
      (dolist (lang (mega-treesit-registered))
        (mega-doctor--insert-row (symbol-name lang)
                                 (mega-doctor--yes-no (mega-treesit-ready-p lang)
                                                      "installed" "missing")))
      (when (mega-treesit-missing)
        (insert "\n  Build the missing ones with:  ")
        (insert (propertize "M-x mega-treesit-install-all\n" 'face 'success)))

      ;;;; Language servers
      (mega-doctor--insert-heading "Language servers")
      (dolist (spec (bound-and-true-p mega-languages))
        (let* ((name (symbol-name (car spec)))
               (candidates (plist-get (cdr spec) :servers))
               (found (seq-find (lambda (cmd) (mega-exe-p (car cmd))) candidates)))
          (if found
              (mega-doctor--insert-row name (propertize (car found) 'face 'success))
            (mega-doctor--insert-row
             name (propertize (format "missing — %s" (mega-doctor--hint (caar candidates)))
                              'face 'warning)))))

      ;;;; LLM
      (mega-doctor--insert-heading "LLM")
      (mega-doctor--insert-row
       "claude CLI (C-c l c)"
       (if (mega-exe-p "claude")
           (propertize "found — needs no API key" 'face 'success)
         (propertize (format "missing — %s" (mega-doctor--hint "claude")) 'face 'warning)))
      (mega-doctor--insert-row
       "Anthropic API key (gptel)"
       (if (and (fboundp 'mega-llm-api-key) (ignore-errors (mega-llm-api-key)))
           (propertize "found in auth-source" 'face 'success)
         (propertize "not configured" 'face 'warning)))
      (unless (and (fboundp 'mega-llm-api-key) (ignore-errors (mega-llm-api-key)))
        (insert "\n  gptel needs a key; the claude CLI does not.  To add one:\n")
        (insert "    gpg --quick-generate-key \"$USER\" default default never\n")
        (insert (format "    printf 'machine %s login apikey password sk-ant-...\\n' > ~/.authinfo\n"
                        (or (bound-and-true-p mega-llm-api-host) "api.anthropic.com")))
        (insert "    gpg -e -r \"$USER\" -o ~/.authinfo.gpg ~/.authinfo && shred -u ~/.authinfo\n")
        (insert "  A plain ~/.authinfo with chmod 600 also works — worse than encrypted,\n")
        (insert "  far better than a key in the repository.\n"))

      ;;;; Tools
      (mega-doctor--insert-heading "Tools")
      (dolist (tool '("rg" "fd" "git" "cc" "gpg"))
        (mega-doctor--insert-row
         tool (or (mega-exe-p tool)
                  (propertize (format "missing — %s" (mega-doctor--hint tool)) 'face 'warning))))

      ;;;; Choices
      (mega-doctor--insert-heading "Active choices  (change in ~/.mega.d/local.el)")
      (mega-doctor--insert-row "mega-completion-backend"
                               (format "%s" (bound-and-true-p mega-completion-backend)))
      (mega-doctor--insert-row "mega-undo-backend"
                               (format "%s" (bound-and-true-p mega-undo-backend)))
      (mega-doctor--insert-row "mega-enable-kkp"
                               (if (bound-and-true-p mega-enable-kkp) "on" "off (saves ~250ms)"))
      (mega-doctor--insert-row "mega-zone-idle-seconds"
                               (if (bound-and-true-p mega-zone-idle-seconds)
                                   (format "%ss" mega-zone-idle-seconds) "off"))
      (goto-char (point-min))))
  (pop-to-buffer "*mega-doctor*"))

;;;###autoload
(defun mega-compile ()
  "Byte-compile MEGA's own Lisp, and queue native compilation.
MEGA is deployed as source, so this is opt-in.  Safe to re-run, and safe
to forget: `load-prefer-newer' is on, so a stale .elc is never loaded in
preference to the .el you just edited.  Remove the .elc files to undo."
  (interactive)
  (let ((files (append (directory-files mega-lisp-dir t "\\.el\\'")
                       (list (expand-file-name "early-init.el" mega-dir)
                             (expand-file-name "init.el" mega-dir)))))
    (dolist (file files)
      (byte-compile-file file))
    (when (and (fboundp 'native-comp-available-p) (native-comp-available-p))
      (native-compile-async files nil))
    (message "MEGA: byte-compiled %d files%s" (length files)
             (if (and (fboundp 'native-comp-available-p) (native-comp-available-p))
                 "; native compilation queued in the background" ""))))

(provide 'mega-doctor)
;;; mega-doctor.el ends here
