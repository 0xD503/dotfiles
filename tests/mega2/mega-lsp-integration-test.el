;;; mega-lsp-integration-test.el --- A real eglot session, a scripted server  -*- lexical-binding: t; -*-

;;; Commentary:

;; The unit tests check MEGA's pieces around the language server.  These
;; check that they add up, over the wire: a file of a known language is
;; opened in a trusted project, eglot starts the server MEGA's table names,
;; and then
;;
;;   * what the server offers reaches MEGA's completion menu, and taking a
;;     candidate does what the server meant: a plain word, an edit with a
;;     second edit elsewhere, a snippet;
;;   * the problems it reports reach the buffer;
;;   * it formats the buffer, within the time any formatter gets;
;;   * it is told that telemetry is off, whatever the project's files say.
;;
;; The last is checked in what the server received, not in a variable.  The
;; server is fake-language-server.py, so the tests need python3 and nothing
;; else; they are skipped without it.

;;; Code:

(require 'mega-test-helper)
(require 'mega-lang)
(require 'mega-lsp)
(require 'mega-complete)
(require 'mega-format)
(require 'mega-snippet)
(require 'eglot)
(require 'flymake)
(require 'treesit)

(defconst mega-lsp-integration-test-server
  (expand-file-name "fake-language-server.py" mega-test-dir)
  "The scripted language server.")

(defvar mega-lsp-integration-test-environment nil
  "More environment settings for the scripted server, as NAME=VALUE.")

(defun mega-lsp-integration-test--wait (predicate seconds)
  "Wait up to SECONDS for PREDICATE to return non-nil; return its value."
  (let ((deadline (+ (float-time) seconds)) value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    value))

(defmacro mega-lsp-integration-test--session (spec &rest body)
  "Open a Rust file in a trusted project and run BODY in it, connected.
SPEC is (LINES [SETUP]): the file holds LINES, a list of strings, and
SETUP is a form evaluated before the file is opened.  In SETUP and BODY,
`project' is the project's directory, `file' the file, `log' the file
the server lists the methods it receives in, and `seen' the one it
writes down what it was told in."
  (declare (indent 1))
  `(progn
     (skip-unless (executable-find "python3"))
     (mega-test-with-directory project
       (mega-test-with-directory store
         (let* ((file (apply #'mega-test-write (expand-file-name "main.rs" project)
                             ,(car spec)))
                (log (expand-file-name "lsp.log" store))
                (seen (expand-file-name "lsp.seen" store))
                (process-environment
                 (append (list (concat "MEGA_TEST_LSP_LOG=" log)
                               (concat "MEGA_TEST_LSP_SEEN=" seen))
                         mega-lsp-integration-test-environment
                         process-environment))
                ;; A row with a server and nothing else: no formatter of its
                ;; own, so that formatting is the server's to do.
                (mega-languages
                 `((rust :ts rust-ts-mode :parser rust :plain mega-rust-mode
                         :servers (("python3" ,mega-lsp-integration-test-server)))))
                (treesit-auto-install-grammar nil)
                (mega-lang--declined nil)
                (eglot-sync-connect 10)
                (eglot-server-programs nil)
                (mega-exec-context-functions nil)
                ;; The user said yes to this project, and it is on record.
                (mega-trust-file (expand-file-name "trusted.eld" store))
                (mega-trust--decisions 'unread)
                (inhibit-message t)
                buffer)
           (ignore log seen)
           (let ((default-directory project))
             (mega-trust-project))
           ,(cadr spec)
           (mega-lang--register-servers)
           (unwind-protect
               (progn
                 (setq buffer (find-file-noselect file))
                 (with-current-buffer buffer
                   ;; No parser is installed in the sandbox, so MEGA's own mode.
                   (should (eq major-mode 'mega-rust-mode))
                   ;; eglot connects after the command that opened the file;
                   ;; a batch Emacs runs no commands, so finish one by hand.
                   (run-hooks 'post-command-hook)
                   (should (mega-lsp-integration-test--wait #'eglot-current-server 10))
                   ,@body))
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (eglot-current-server)
                   (ignore-errors (eglot-shutdown (eglot-current-server) nil 3)))
                 (set-buffer-modified-p nil))
               (kill-buffer buffer))))))))

(defun mega-lsp-integration-test--told (seen what)
  "Wait for the server to note WHAT in the file SEEN; return the last such note.
A note is a plist; false is `:false' and null is nil."
  (mega-lsp-integration-test--wait
   (lambda ()
     (when (file-readable-p seen)
       (let (found)
         (with-temp-buffer
           (insert-file-contents seen)
           (dolist (line (split-string (buffer-string) "\n" t))
             (let ((note (json-parse-string line :object-type 'plist
                                            :array-type 'list
                                            :false-object :false
                                            :null-object nil)))
               (when (equal (plist-get note :what) what)
                 (setq found note)))))
         found)))
   5))

(defun mega-lsp-integration-test--candidates ()
  "What MEGA's menu would list at point: (START PROPERTIES BASE . CANDIDATES)."
  (pcase (mega-complete--capf)
    (`(,start ,end ,table . ,properties)
     (cons start (cons properties
                       (mega-complete-candidates start end table nil))))
    (_ (ert-fail "the buffer offered no completion"))))

(defun mega-lsp-integration-test--take (label)
  "Open MEGA's menu at point and take the candidate called LABEL."
  (pcase-let* ((`(,start ,properties . ,found) (mega-lsp-integration-test--candidates))
               (index (cl-position label (cdr found)
                                   :test (lambda (label candidate)
                                           (equal label (substring-no-properties
                                                         candidate))))))
    (should index)
    ;; Nothing to draw on: this Emacs has no screen.
    (cl-letf (((symbol-function 'mega-popup-show) #'ignore)
              ((symbol-function 'mega-popup-hide) #'ignore))
      (mega-complete--open start found properties nil index)
      (mega-complete-accept))))

;;;; Completion

(ert-deftest mega-lsp-a-server-from-the-table-feeds-the-completion-menu ()
  (mega-lsp-integration-test--session ('("fn main() {" "    ser" "}" ""))
    (should (equal (plist-get (eglot--server-info (eglot-current-server)) :name)
                   "mega-fake-server"))
    (goto-char (point-min))
    (search-forward "ser")
    ;; In the server's order, not MEGA's shortest-first: the server knows
    ;; what is most likely.
    (should (equal (mapcar #'substring-no-properties
                           (cdddr (mega-lsp-integration-test--candidates)))
                   '("server_alpha" "server_beta" "server_edit" "server_snippet")))
    (should (string-match-p "textDocument/completion"
                            (with-temp-buffer
                              (insert-file-contents log)
                              (buffer-string))))))

(ert-deftest mega-lsp-a-plain-completion-replaces-what-was-typed ()
  (mega-lsp-integration-test--session ('("fn main() {" "    ser" "}" ""))
    (goto-char (point-min))
    (search-forward "ser")
    (mega-lsp-integration-test--take "server_beta")
    (should (equal (buffer-string) "fn main() {\n    server_beta\n}\n"))
    (should (looking-back "server_beta" (line-beginning-position)))))

(ert-deftest mega-lsp-a-completion-that-is-an-edit-is-applied-as-the-server-says ()
  "The label is not what goes in, and a second edit lands elsewhere."
  (mega-lsp-integration-test--session ('("fn main() {" "    ser" "}" ""))
    (goto-char (point-min))
    (search-forward "ser")
    (mega-lsp-integration-test--take "server_edit")
    (should (equal (buffer-string)
                   "use server::edit;\nfn main() {\n    server_edit_done\n}\n"))
    ;; The cursor stays with what was completed, not with the import.
    (should (looking-back "server_edit_done" (line-beginning-position)))))

(ert-deftest mega-lsp-a-completion-that-is-a-snippet-is-expanded-by-mega ()
  "A server sends snippets only to an editor that says it can expand them."
  (mega-lsp-integration-test--session ('("fn main() {" "    ser" "}" ""))
    (should (eq (plist-get (mega-lsp-integration-test--told seen "initialize") :snippets)
                t))
    (goto-char (point-min))
    (search-forward "ser")
    (unwind-protect
        (progn
          (mega-lsp-integration-test--take "server_snippet")
          (should (equal (buffer-string)
                         "fn main() {\n    server_snippet(first, second)\n}\n"))
          ;; On the first place, with its text selected to be typed over.
          (should (region-active-p))
          (should (equal (buffer-substring (region-beginning) (region-end)) "first"))
          (mega-snippet-next)
          (should (equal (buffer-substring (region-beginning) (region-end)) "second")))
      (mega-snippet-finish))))

;;;; Diagnostics

(ert-deftest mega-lsp-the-server-s-diagnostics-reach-the-buffer ()
  (mega-lsp-integration-test--session ('("fn main() {" "    let BUG = 1;" "}" ""))
    (should flymake-mode)
    ;; Checking waits for the buffer to be on screen; this one never is.
    (flymake-start)
    (let ((found (mega-lsp-integration-test--wait #'flymake-diagnostics 5)))
      (should (= (length found) 1))
      (should (string-match-p "by its own admission"
                              (flymake-diagnostic-text (car found))))
      (should (equal (buffer-substring (flymake-diagnostic-beg (car found))
                                       (flymake-diagnostic-end (car found)))
                     "BUG")))))

;;;; Formatting

(ert-deftest mega-lsp-the-server-formats-a-buffer-that-has-no-other-formatter ()
  (mega-lsp-integration-test--session ('("fn main() {   " "    let  x = 1;" "}" ""))
    (should-not (mega-format-command))
    (goto-char (point-min))
    (search-forward "x = ")
    (should (mega-format-buffer))
    (should (equal (buffer-string) "fn main() {\n    let x = 1;\n}\n"))
    ;; The cursor is where it was in the text, not where it was in the file.
    (should (looking-at-p "1;"))))

(ert-deftest mega-lsp-a-server-that-never-answers-does-not-hold-up-a-save ()
  "It gets as long as any formatter gets, and then the file is saved as it is."
  (let ((mega-lsp-integration-test-environment
         '("MEGA_TEST_LSP_HANG=textDocument/formatting"))
        (mega-format-timeout 0.5)
        (mega-format-on-save t))
    (mega-lsp-integration-test--session ('("fn main() {   " "    let  x = 1;" "}" ""))
      (goto-char (point-max))
      (insert "// more\n")
      (let ((started (float-time)))
        (save-buffer)
        (should (< (- (float-time) started) 5)))
      (should-not (buffer-modified-p))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                     "fn main() {   \n    let  x = 1;\n}\n// more\n"))
      ;; It was asked, and it is still there to be asked other things.
      (should (string-match-p "textDocument/formatting"
                              (with-temp-buffer (insert-file-contents log)
                                                (buffer-string))))
      (should (process-live-p (jsonrpc--process (eglot-current-server)))))))

;;;; What the server is told

(ert-deftest mega-lsp-the-server-is-told-that-telemetry-is-off ()
  "In the settings it is sent, and in the answer when it asks."
  (mega-lsp-integration-test--session ('("fn main() {}" ""))
    (let ((answer (plist-get (mega-lsp-integration-test--told seen "configuration")
                             :result)))
      ;; telemetry, redhat, gopls: in the order it asked.
      (should (equal answer '((:enableTelemetry :false)
                              (:telemetry (:enabled :false))
                              nil))))
    (let ((settings (plist-get (mega-lsp-integration-test--told seen "settings")
                               :settings)))
      (should (eq (plist-get (plist-get settings :telemetry) :enableTelemetry) :false))
      (should (eq (plist-get (plist-get (plist-get settings :redhat) :telemetry)
                             :enabled)
                  :false)))))

(ert-deftest mega-lsp-a-project-s-files-cannot-switch-telemetry-on ()
  "A project may configure its server.  It may not undo this."
  (mega-lsp-integration-test--session
      ('("fn main() {}" "")
       (mega-test-write
        (expand-file-name ".dir-locals.el" project)
        (prin1-to-string
         '((nil . ((eglot-workspace-configuration
                    . (:telemetry (:enableTelemetry t :level "all")
                       :redhat (:telemetry (:enabled t))
                       :gopls (:staticcheck t)))))))
        ""))
    (let ((answer (plist-get (mega-lsp-integration-test--told seen "configuration")
                             :result)))
      (should (eq (plist-get (nth 0 answer) :enableTelemetry) :false))
      ;; What it said beside that is passed on.
      (should (equal (plist-get (nth 0 answer) :level) "all"))
      (should (eq (plist-get (plist-get (nth 1 answer) :telemetry) :enabled) :false))
      (should (equal (nth 2 answer) '(:staticcheck t))))
    (let ((settings (plist-get (mega-lsp-integration-test--told seen "settings")
                               :settings)))
      (should (eq (plist-get (plist-get settings :telemetry) :enableTelemetry) :false))
      (should (equal (plist-get settings :gopls) '(:staticcheck t))))))

(provide 'mega-lsp-integration-test)
;;; mega-lsp-integration-test.el ends here
