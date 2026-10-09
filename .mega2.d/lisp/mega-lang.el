;;; mega-lang.el --- Languages, as data  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every language MEGA knows is one row in `mega-languages'.  Adding one is
;; adding a row; nothing else in MEGA knows a language name.
;;
;; A row is (NAME . PLIST):
;;
;;   :ts        the tree-sitter mode, the best there is when its parser is
;;              installed
;;   :parser    the parser that mode needs
;;   :plain     the mode to use without the parser: Emacs's classic mode
;;              where one exists, a mode of MEGA's own where none does
;;   :patterns  file name regexps, for files Emacs would not otherwise send
;;              to one of the modes above
;;   :servers   language server command lines, best first; the first whose
;;              program exists is used, and if none does, none is started
;;
;; Tree-sitter parsers are not bundled with Emacs.  The first time you open a
;; file whose language has one, Emacs asks whether to fetch and build it;
;; that is Emacs's own prompt, and the only download MEGA ever leads to.  Say
;; no and the file opens in the :plain mode; the question is not asked again
;; for that language until `M-x mega-lang-ask-again'.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)
(require 'mega-trust)

(declare-function treesit-available-p "treesit.c")
(declare-function treesit-language-available-p "treesit.c")
(declare-function treesit-ensure-installed "treesit")
(declare-function eglot-ensure "eglot")
(declare-function mega-doctor-heading "mega-doctor")
(declare-function mega-doctor-row "mega-doctor")

(defvar treesit-auto-install-grammar)
(defvar treesit-extra-load-path)
(defvar eglot-server-programs)

(defvar mega-languages
  '((c          :ts c-ts-mode :parser c :plain c-mode
                :servers (("clangd" "--background-index" "--clang-tidy"
                           "--header-insertion=never")))
    (cpp        :ts c++-ts-mode :parser cpp :plain c++-mode
                :servers (("clangd" "--background-index" "--clang-tidy"
                           "--header-insertion=never")))
    (rust       :ts rust-ts-mode :parser rust :plain mega-rust-mode
                :patterns ("\\.rs\\'")
                :servers (("rust-analyzer")))
    (python     :ts python-ts-mode :parser python :plain python-mode
                :servers (("basedpyright-langserver" "--stdio")
                          ("pyright-langserver" "--stdio")
                          ("pylsp")))
    (shell      :ts bash-ts-mode :parser bash :plain sh-mode
                :servers (("bash-language-server" "start")))
    (javascript :ts js-ts-mode :parser javascript :plain js-mode
                :servers (("typescript-language-server" "--stdio")))
    (typescript :ts typescript-ts-mode :parser typescript :plain js-mode
                :patterns ("\\.[cm]?ts\\'")
                :servers (("typescript-language-server" "--stdio")))
    (tsx        :ts tsx-ts-mode :parser tsx :plain js-mode
                :patterns ("\\.tsx\\'")
                :servers (("typescript-language-server" "--stdio")))
    (go         :ts go-ts-mode :parser go
                :patterns ("\\.go\\'")
                :servers (("gopls")))
    (lua        :ts lua-ts-mode :parser lua :plain lua-mode
                :servers (("lua-language-server")))
    (json       :ts json-ts-mode :parser json :plain js-json-mode
                :servers (("vscode-json-language-server" "--stdio")))
    (yaml       :ts yaml-ts-mode :parser yaml :plain conf-colon-mode
                :patterns ("\\.ya?ml\\'")
                :servers (("yaml-language-server" "--stdio")))
    (toml       :ts toml-ts-mode :parser toml :plain conf-toml-mode
                :servers (("taplo" "lsp" "stdio")))
    (cmake      :ts cmake-ts-mode :parser cmake
                :patterns ("\\(?:CMakeLists\\.txt\\|\\.cmake\\)\\'"))
    (dockerfile :ts dockerfile-ts-mode :parser dockerfile
                :patterns ("\\(?:Dockerfile\\(?:\\..*\\)?\\|\\.[Dd]ockerfile\\)\\'"))
    (markdown   :plain mega-markdown-mode
                :patterns ("\\.\\(?:md\\|markdown\\|mdown\\)\\'")
                :servers (("marksman" "server")))
    (zig        :plain mega-zig-mode
                :patterns ("\\.\\(?:zig\\|zon\\)\\'")
                :servers (("zls")))
    (just       :plain mega-just-mode
                :patterns ("\\(?:\\`\\|/\\)\\.?[Jj]ustfile\\'" "\\.just\\'"))
    (verilog    :plain verilog-mode
                :servers (("verible-verilog-ls") ("svls") ("veridian"))))
  "Every language MEGA configures.  See the Commentary for the row format.")

;;;; Parsers

(defconst mega-lang-declined-file (mega-state "parsers-declined.eld")
  "Where the parsers you declined to install are remembered.")

(defvar mega-lang--declined 'unread
  "Parsers you declined to install, or `unread' before the file is read.")

(defun mega-lang--declined ()
  "The parsers you declined to install."
  (when (eq mega-lang--declined 'unread)
    (setq mega-lang--declined
          (ignore-errors
            (with-temp-buffer
              (insert-file-contents mega-lang-declined-file)
              (let ((list (read (current-buffer))))
                (and (listp list) (seq-every-p #'symbolp list) list))))))
  mega-lang--declined)

(defun mega-lang--decline (parser)
  "Remember that the user does not want PARSER."
  (unless (memq parser (mega-lang--declined))
    (push parser mega-lang--declined)
    (with-temp-file mega-lang-declined-file
      (prin1 mega-lang--declined (current-buffer)))))

(defun mega-lang-ask-again ()
  "Forget which parsers were declined, so Emacs offers them again."
  (interactive)
  (setq mega-lang--declined nil)
  (when (file-exists-p mega-lang-declined-file)
    (delete-file mega-lang-declined-file))
  (message "Emacs will offer to install missing parsers again"))

(defun mega-lang-parser-p (parser)
  "Non-nil if PARSER is installed, or the user just agreed to install it.
When it is missing and has not been declined before, this is where
Emacs's own prompt appears; a no is remembered."
  (cond ((not (and (fboundp 'treesit-available-p) (treesit-available-p))) nil)
        ((treesit-language-available-p parser) t)
        ((memq parser (mega-lang--declined)) nil)
        ;; Emacs's tree-sitter library is loaded only now, when a file
        ;; actually needs it; the prompt's setting lives there.
        ((or noninteractive
             (not (require 'treesit nil t))
             (not treesit-auto-install-grammar))
         nil)
        ((ignore-errors (treesit-ensure-installed parser)) t)
        (t (mega-lang--decline parser) nil)))

;; Parsers are built into the data directory: recreating them needs the
;; network, so they do not belong in a cache.
(with-eval-after-load 'treesit
  (add-to-list 'treesit-extra-load-path (mega-data "tree-sitter/")))

;;;; Choosing the mode

(defun mega-lang-row (name)
  "The plist of the language called NAME."
  (cdr (assq name mega-languages)))

(defun mega-lang-enter (name)
  "Put the current buffer in the best available mode for language NAME."
  (let* ((row (mega-lang-row name))
         (ts (plist-get row :ts))
         (plain (plist-get row :plain)))
    (cond ((and ts (fboundp ts) (mega-lang-parser-p (plist-get row :parser)))
           (funcall ts))
          ((and plain (fboundp plain))
           (funcall plain))
          (t (fundamental-mode)))))

(defun mega-lang--dispatcher (name)
  "The command that enters language NAME, defined on first use."
  (let ((symbol (intern (format "mega-lang-%s" name))))
    (unless (fboundp symbol)
      (defalias symbol
        (lambda () (interactive) (mega-lang-enter name))
        (format "Enter the best available mode for %s.
See `mega-languages'." name)))
    symbol))

(defun mega-lang-apply (spec)
  "Route files of the language SPEC, a row of `mega-languages', to its modes."
  (let* ((name (car spec))
         (row (cdr spec))
         (dispatcher (mega-lang--dispatcher name))
         (plain (plist-get row :plain)))
    (dolist (pattern (plist-get row :patterns))
      (add-to-list 'auto-mode-alist (cons pattern dispatcher)))
    ;; Where Emacs already sends a file to the classic mode, send it through
    ;; the dispatcher, which upgrades to the tree-sitter mode when it can.
    (when (and plain (plist-get row :ts) (not (plist-get row :patterns)))
      (add-to-list 'major-mode-remap-alist (cons plain dispatcher)))))

;;;; Language servers

(defun mega-lang--modes (row)
  "The major modes of ROW."
  (delq nil (list (plist-get row :ts) (plist-get row :plain))))

(defun mega-lang-row-for-mode (mode)
  "The row of `mega-languages' that MODE belongs to, or nil."
  (seq-find (lambda (spec)
              (and (plist-get (cdr spec) :servers)
                   (memq mode (mega-lang--modes (cdr spec)))))
            mega-languages))

(defun mega-lang-server (spec &optional directory)
  "The command line of the language server to use for SPEC, or nil.
It is the first of the row's candidates whose program exists where
DIRECTORY's tools run, which may be inside a container."
  (seq-find (lambda (command)
              (mega-exec-find (car command) (or directory default-directory)))
            (plist-get (cdr spec) :servers)))

(defun mega-lang--contact (&rest _)
  "Tell eglot how to start the server for the current buffer.
The command goes through `mega-exec-command', which is what lets a
server run inside the project's container."
  (let* ((spec (mega-lang-row-for-mode major-mode))
         (server (and spec (mega-lang-server spec))))
    (unless server
      (user-error "No language server for %s is installed" major-mode))
    (unless (mega-trust-p default-directory t "start its language server")
      (user-error "This project is not trusted; see M-x mega-trust-project"))
    (mega-exec-command (car server) (cdr server) default-directory)))

(defun mega-lang-start-server ()
  "Start the language server for this buffer, if one is installed.
Runs when a file of a known language is opened.  A server builds the
project to understand it, which runs the project's own code, so the
project has to be trusted first: this is where MEGA asks, once.  Remote
files are left alone: `M-x eglot' starts a server there on request."
  (when (and buffer-file-name
             (not (file-remote-p buffer-file-name)))
    (when-let* ((spec (mega-lang-row-for-mode major-mode))
                ((mega-lang-server spec))
                ((mega-trust-p default-directory t "start its language server")))
      (eglot-ensure))))

(defun mega-lang--register-servers ()
  "Tell eglot which modes MEGA's server table covers."
  (dolist (spec mega-languages)
    (when (plist-get (cdr spec) :servers)
      (add-to-list 'eglot-server-programs
                   (cons (mega-lang--modes (cdr spec)) #'mega-lang--contact)))))

(with-eval-after-load 'eglot
  (mega-lang--register-servers))

;;;; Applying the table

(defun mega-lang-setup ()
  "Apply every row of `mega-languages'."
  (dolist (spec mega-languages)
    (mega-lang-apply spec)
    (when (plist-get (cdr spec) :servers)
      (dolist (mode (mega-lang--modes (cdr spec)))
        (add-hook (intern (format "%s-hook" mode)) #'mega-lang-start-server)))))

(mega-lang-setup)

;; MEGA's own modes, loaded when a file needs one.
(autoload 'mega-rust-mode "mega-mode-rust" nil t)
(autoload 'mega-zig-mode "mega-mode-zig" nil t)
(autoload 'mega-just-mode "mega-mode-just" nil t)
(autoload 'mega-markdown-mode "mega-mode-markdown" nil t)

;;;; The doctor's section

(defun mega-lang--doctor ()
  "Insert the languages section of the doctor report."
  (mega-doctor-heading "Languages")
  (dolist (spec mega-languages)
    (let* ((row (cdr spec))
           (parser (plist-get row :parser))
           (server (mega-lang-server spec))
           (candidates (plist-get row :servers)))
      (mega-doctor-row
       (symbol-name (car spec))
       (concat
        (cond ((not parser) "own mode       ")
              ((and (fboundp 'treesit-language-available-p)
                    (treesit-language-available-p parser))
               "parser built   ")
              ((memq parser (mega-lang--declined)) "parser declined")
              (t "parser missing "))
        "  "
        (cond (server (format "server: %s" (car server)))
              (candidates (format "no server (%s)"
                                  (mapconcat #'car candidates ", ")))
              (t ""))))))
  (insert "\n  A missing parser is offered when you open such a file.\n"
          "  A missing server is simply not started; install it to get one.\n"))

(add-to-list 'mega-doctor-sections #'mega-lang--doctor t)

(provide 'mega-lang)
;;; mega-lang.el ends here
