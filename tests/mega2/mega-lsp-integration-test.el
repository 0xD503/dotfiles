;;; mega-lsp-integration-test.el --- A real eglot session, a scripted server  -*- lexical-binding: t; -*-

;;; Commentary:

;; The unit tests check MEGA's pieces around the language server.  This one
;; checks that they add up: a file of a known language is opened, eglot
;; starts the server MEGA's table names, and what the server offers reaches
;; MEGA's completion menu.  The server is fake-language-server.py, so the
;; test needs python3 and nothing else; it is skipped without it.

;;; Code:

(require 'mega-test-helper)
(require 'mega-lang)
(require 'mega-lsp)
(require 'mega-complete)
(require 'eglot)
(require 'treesit)

(defconst mega-lsp-integration-test-server
  (expand-file-name "fake-language-server.py" mega-test-dir)
  "The scripted language server.")

(defun mega-lsp-integration-test--wait (predicate seconds)
  "Wait up to SECONDS for PREDICATE to return non-nil; return its value."
  (let ((deadline (+ (float-time) seconds)) value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    value))

(ert-deftest mega-lsp-a-server-from-the-table-feeds-the-completion-menu ()
  (skip-unless (executable-find "python3"))
  (mega-test-with-directory project
    (let* ((file (mega-test-write (expand-file-name "main.rs" project)
                                  "fn main() {" "    ser" "}" ""))
           (log (expand-file-name "lsp.log" project))
           (process-environment (cons (concat "MEGA_TEST_LSP_LOG=" log)
                                      process-environment))
           (mega-languages
            `((rust :ts rust-ts-mode :parser rust :plain mega-rust-mode
                    :servers (("python3" ,mega-lsp-integration-test-server)))))
           (treesit-auto-install-grammar nil)
           (mega-lang--declined nil)
           (eglot-sync-connect 10)
           (eglot-server-programs nil)
           (mega-exec-context-functions nil)
           buffer)
      (mega-lang--register-servers)
      (unwind-protect
          (progn
            (setq buffer (find-file-noselect file))
            (with-current-buffer buffer
              ;; No parser is installed in the sandbox, so MEGA's own mode.
              (should (eq major-mode 'mega-rust-mode))
              ;; Opening the file asked eglot for the server from MEGA's
              ;; table.  eglot connects after the command that opened the
              ;; file; a batch Emacs runs no commands, so finish one by hand.
              (run-hooks 'post-command-hook)
              (should (mega-lsp-integration-test--wait #'eglot-current-server 10))
              (should (equal (plist-get (eglot--server-info (eglot-current-server)) :name)
                             "mega-fake-server"))
              ;; What the server offers is what the menu would show.
              (goto-char (point-min))
              (search-forward "ser")
              (pcase (mega-complete--capf)
                (`(,start ,end ,table . ,_)
                 (let ((found (mega-complete-candidates start end table nil)))
                   ;; In the server's order, not MEGA's shortest-first: the
                   ;; server knows what is most likely.
                   (should (equal (mapcar #'substring-no-properties (cdr found))
                                  '("server_alpha" "server_beta")))))
                (_ (ert-fail "the buffer offered no completion")))
              (should (string-match-p "textDocument/completion"
                                      (with-temp-buffer
                                        (insert-file-contents log)
                                        (buffer-string))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (eglot-current-server)
              (ignore-errors (eglot-shutdown (eglot-current-server) nil 3)))
            (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(provide 'mega-lsp-integration-test)
;;; mega-lsp-integration-test.el ends here
