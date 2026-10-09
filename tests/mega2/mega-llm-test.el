;;; mega-llm-test.el --- Tests for mega-llm.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Claude is never contacted here.  `claude' is a script that writes down
;; how it was called — its arguments, its directory, its standard input —
;; and prints a prepared answer; `tmux' is another.  What the tests pin down
;; is what MEGA sends, where from, and what it does with what comes back.

;;; Code:

(require 'mega-test-helper)
(require 'mega-llm)

(defconst mega-llm-test-claude
  "#!/bin/sh
if [ \"$1\" != --print ]; then
  # A session: write down what is typed into it.
  pwd > \"$MEGA_FAKE_DIR/session-cwd\"
  exec cat > \"$MEGA_FAKE_DIR/session-input\"
fi
printf '%s\\n' \"$@\" > \"$MEGA_FAKE_DIR/args\"
pwd > \"$MEGA_FAKE_DIR/cwd\"
cat > \"$MEGA_FAKE_DIR/stdin\"
if [ -f \"$MEGA_FAKE_DIR/slow\" ]; then sleep 30; fi
if [ -f \"$MEGA_FAKE_DIR/fail\" ]; then echo 'not signed in' >&2; exit 1; fi
cat \"$MEGA_FAKE_DIR/reply\"
"
  "A stand-in for the claude program.")

(defconst mega-llm-test-tmux
  "#!/bin/sh
printf '%s\\n' \"$*\" >> \"$MEGA_FAKE_DIR/tmux.log\"
case \"$1\" in
  split-window) echo '%7' ;;
  display-message) if [ -f \"$MEGA_FAKE_DIR/pane-gone\" ]; then exit 1; fi; echo '%7' ;;
  load-buffer) cat > \"$MEGA_FAKE_DIR/pasted\" ;;
esac
"
  "A stand-in for tmux.")

(defvar mega-llm-test--said nil
  "What `message' was last called to say, inside `mega-llm-test--with-claude'.")

(defmacro mega-llm-test--with-claude (&rest body)
  "Run BODY in a project DIR with stand-ins for claude and tmux.
FAKE is the directory the stand-ins write to."
  (declare (indent 0))
  `(mega-test-with-directory dir
     (let* ((bin (expand-file-name "bin/" dir))
            (fake (expand-file-name "fake/" dir))
            (exec-path (cons bin exec-path))
            (process-environment
             (append (list (concat "MEGA_FAKE_DIR=" (directory-file-name fake))
                           (concat "PATH=" bin ":" (getenv "PATH")))
                     process-environment))
            (mega--exe-cache (make-hash-table :test #'equal))
            (mega-claude--request nil)
            (mega-claude--sessions nil)
            (mega-claude-model nil)
            (mega-llm-test--said nil)
            (default-directory dir))
       (make-directory fake t)
       (set-file-modes (mega-test-write (expand-file-name "claude" bin)
                                        mega-llm-test-claude)
                       #o755)
       (set-file-modes (mega-test-write (expand-file-name "tmux" bin)
                                        mega-llm-test-tmux)
                       #o755)
       (mega-test-write (expand-file-name "reply" fake) "The answer." "")
       (unwind-protect
           (cl-letf (((symbol-function 'message)
                      (lambda (format &rest arguments)
                        (setq mega-llm-test--said
                              (and format (apply #'format-message format arguments))))))
             ,@body)
         (when (process-live-p mega-claude--request)
           (delete-process mega-claude--request))
         (when (get-buffer "*claude*") (kill-buffer "*claude*"))))))

(defun mega-llm-test--read (name)
  "The contents of the file NAME the stand-ins wrote, or nil."
  (let ((file (expand-file-name name (getenv "MEGA_FAKE_DIR"))))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defun mega-llm-test--answered ()
  "Wait until the one-shot question in flight is over."
  (should (mega-test-wait-for (lambda () (null mega-claude--request)) 10)))

(defun mega-llm-test--select (start end)
  "Make the text from START to END the active region."
  (transient-mark-mode 1)
  (goto-char start)
  (set-mark (point))
  (goto-char end)
  (activate-mark))

;;;; What is sent, and how

(ert-deftest mega-llm-a-question-goes-in-on-standard-input-and-the-answer-is-shown ()
  (mega-llm-test--with-claude
    (with-temp-buffer
      (insert "SECRET_IN_THE_BUFFER\n")
      (mega-claude-ask "What is a monad?"))
    (mega-llm-test--answered)
    ;; Nothing was selected: the question is all that left.
    (should (equal (mega-llm-test--read "stdin") "What is a monad?"))
    (should-not (string-match-p "monad" (mega-llm-test--read "args")))
    (should (equal (mega-test-buffer-string "*claude*")
                   "What is a monad?\n\nThe answer.\n"))))

(ert-deftest mega-llm-one-shot-questions-can-touch-nothing ()
  (mega-llm-test--with-claude
    (mega-claude-ask "hello")
    (mega-llm-test--answered)
    (let ((arguments (split-string (mega-llm-test--read "args") "\n")))
      (should (equal (car arguments) "--print"))
      ;; No tools: the argument after --tools is the empty string.
      (should (equal (cadr (member "--tools" arguments)) ""))
      (should (member "--strict-mcp-config" arguments))
      (should (member "--no-session-persistence" arguments))
      (should (equal (cadr (member "--setting-sources" arguments)) "user"))
      (should (equal (cadr (member "--permission-prompts" arguments)) "none"))
      (should-not (seq-some (lambda (argument)
                              (string-match-p "dangerously\\|bypass" argument))
                            arguments)))
    ;; And it did not run in the project, whose settings could run commands.
    (let ((where (string-trim (mega-llm-test--read "cwd"))))
      (should-not (file-in-directory-p where dir))
      (should (file-in-directory-p where mega-cache-dir))
      (should (null (directory-files where nil directory-files-no-dot-files-regexp))))))

(ert-deftest mega-llm-only-the-selected-text-is-sent ()
  (mega-llm-test--with-claude
    (mega-test-write (expand-file-name ".git/HEAD" dir) "ref: refs/heads/main" "")
    (mega-test-visiting buffer (mega-test-write (expand-file-name "src/app.el" dir)
                                                "(defun before () 'SECRET_ABOVE)"
                                                "(defun chosen () 'this)"
                                                "(defun after () 'SECRET_BELOW)" "")
      (goto-char (point-min))
      (forward-line 1)
      (mega-llm-test--select (point) (line-beginning-position 2))
      (mega-claude-ask "What does this do?"))
    (mega-llm-test--answered)
    (let ((sent (mega-llm-test--read "stdin")))
      (should (string-prefix-p "What does this do?\n\n" sent))
      (should (string-match-p "(defun chosen () 'this)" sent))
      ;; Named by its place in the project, not by where your home is.
      (should (string-match-p "From src/app\\.el, lines 2-2:" sent))
      (should-not (string-match-p (regexp-quote dir) sent))
      (should-not (string-match-p "SECRET" sent)))
    (should-not (string-match-p "chosen\\|SECRET" (mega-llm-test--read "args")))))

(ert-deftest mega-llm-explain-takes-the-function-at-point ()
  (mega-llm-test--with-claude
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(defun one () 1)\n\n(defun two ()\n  2)\n\n(defun three () 3)\n")
      (goto-char (point-min))
      (search-forward "2")
      (mega-claude-explain))
    (mega-llm-test--answered)
    (let ((sent (mega-llm-test--read "stdin")))
      (should (string-match-p "(defun two ()\n  2)" sent))
      (should-not (string-match-p "one\\|three" sent)))
    (should (string-match-p "The answer\\." (mega-test-buffer-string "*claude*")))))

(ert-deftest mega-llm-nothing-selected-and-nothing-at-point-sends-nothing ()
  (mega-llm-test--with-claude
    (with-temp-buffer
      (should-error (mega-claude-explain) :type 'user-error)
      (should-error (call-interactively #'mega-claude-rewrite) :type 'user-error))
    (should-error (mega-claude-ask "   ") :type 'user-error)
    (should-not mega-claude--request)
    (should-not (mega-llm-test--read "args"))))

(ert-deftest mega-llm-text-that-contains-a-fence-gets-a-longer-one ()
  (should (equal (mega-claude--fence "plain") "```"))
  (should (equal (mega-claude--fence "a ``` b") "````"))
  (should (equal (mega-claude--fence "````` and ```") "``````")))

(ert-deftest mega-llm-the-model-is-passed-when-set ()
  (mega-llm-test--with-claude
    (let ((mega-claude-model "opus"))
      (mega-claude-ask "hello"))
    (mega-llm-test--answered)
    (let ((arguments (split-string (mega-llm-test--read "args") "\n")))
      (should (equal (cadr (member "--model" arguments)) "opus")))))

;;;; Private files

(ert-deftest mega-llm-a-private-file-needs-a-typed-yes ()
  (mega-llm-test--with-claude
    (mega-test-visiting buffer (mega-test-write (expand-file-name ".env" dir)
                                                "TOKEN=hunter2" "")
      (mega-llm-test--select (point-min) (point-max))
      ;; A single key must not be enough to send a secret.
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "Asked with one key")))
                ((symbol-function 'yes-or-no-p) #'ignore))
        (should-error (mega-claude-explain) :type 'user-error)
        (should-error (call-interactively #'mega-claude-ask) :type 'user-error)
        (should-not mega-claude--request)
        (should-not (mega-llm-test--read "stdin")))
      (cl-letf (((symbol-function 'yes-or-no-p) #'always))
        (mega-claude-explain)))
    (mega-llm-test--answered)
    (should (string-match-p "hunter2" (mega-llm-test--read "stdin")))))

;;;; Waiting, failing, stopping

(ert-deftest mega-llm-a-failure-is-reported-and-shows-no-answer ()
  (mega-llm-test--with-claude
    (mega-test-write (expand-file-name "fail" fake) "")
    (mega-claude-ask "hello")
    (mega-llm-test--answered)
    (should (equal mega-llm-test--said "Claude failed: not signed in"))
    (should-not (get-buffer "*claude*"))))

(ert-deftest mega-llm-one-question-at-a-time-and-waiting-can-be-stopped ()
  (mega-llm-test--with-claude
    (mega-test-write (expand-file-name "slow" fake) "")
    (mega-claude-ask "first")
    (let ((process mega-claude--request))
      (should (process-live-p process))
      (should-error (mega-claude-ask "second") :type 'user-error)
      (mega-claude-stop)
      (mega-llm-test--answered)
      (should-not (process-live-p process)))
    (should (equal mega-llm-test--said "Stopped waiting for Claude"))
    (should-not (get-buffer "*claude*"))
    ;; And the next question goes through.
    (delete-file (expand-file-name "slow" fake))
    (mega-claude-ask "third")
    (mega-llm-test--answered)
    (should (get-buffer "*claude*"))))

(ert-deftest mega-llm-says-so-when-the-program-is-missing ()
  (mega-llm-test--with-claude
    (let ((mega-claude-program "mega-no-such-claude"))
      (should-error (mega-claude-ask "hello") :type 'user-error)
      (should-error (mega-claude) :type 'user-error))))

;;;; Rewriting

(ert-deftest mega-llm-strip-fence-removes-only-a-fence-around-everything ()
  (should (equal (mega-claude--strip-fence "```rust\nfn a() {}\n```\n") "fn a() {}"))
  (should (equal (mega-claude--strip-fence "```\none\ntwo\n```") "one\ntwo"))
  (should (equal (mega-claude--strip-fence "plain text") "plain text"))
  ;; A fence inside prose is part of an answer that is not just code.
  (should (equal (mega-claude--strip-fence "Here:\n```\ncode\n```") "Here:\n```\ncode\n```"))
  (should (equal (mega-claude--strip-fence "```") "```")))

(ert-deftest mega-llm-a-replacement-keeps-the-final-newline-as-it-was ()
  (should (equal (mega-claude--replacement "```\nnew\n```\n" "old\n") "new\n"))
  (should (equal (mega-claude--replacement "new\n\n" "old") "new"))
  (should (equal (mega-claude--replacement "new" "old\n") "new\n")))

(defmacro mega-llm-test--rewriting (reply &rest body)
  "Run BODY in a buffer BUFFER after asking to rewrite its second line.
REPLY is what Claude answers.  The answer has arrived when BODY runs."
  (declare (indent 1))
  `(mega-llm-test--with-claude
     (mega-test-write (expand-file-name "reply" fake) ,reply)
     (let ((buffer (generate-new-buffer "rewrite-test")))
       (unwind-protect
           (with-current-buffer buffer
             (insert "keep 1\nold line\nkeep 2\n")
             (buffer-enable-undo)
             (undo-boundary)
             (goto-char (point-min))
             (forward-line 1)
             (mega-llm-test--select (point) (line-beginning-position 2))
             (mega-claude-rewrite "make it new")
             (deactivate-mark)
             (mega-llm-test--answered)
             ,@body)
         (kill-buffer buffer)))))

(ert-deftest mega-llm-a-rewrite-changes-nothing-until-it-is-applied ()
  (mega-llm-test--rewriting "```\nnew line\n```\n"
    (should (string-match-p "Instruction: make it new" (mega-llm-test--read "stdin")))
    (should (string-match-p "old line" (mega-llm-test--read "stdin")))
    (should-not (string-match-p "keep" (mega-llm-test--read "stdin")))
    ;; Shown, not done.
    (should (equal (buffer-string) "keep 1\nold line\nkeep 2\n"))
    (let ((shown (mega-test-buffer-string "*claude*")))
      (should (string-match-p "^-old line$" shown))
      (should (string-match-p "^\\+new line$" shown)))
    (with-current-buffer "*claude*"
      (should (eq (lookup-key (current-local-map) (kbd "RET")) #'mega-claude-apply))
      (mega-claude-apply)
      ;; Applying twice is not possible.
      (should-error (mega-claude-apply) :type 'user-error))
    (should (equal (buffer-string) "keep 1\nnew line\nkeep 2\n"))
    ;; One change: one undo takes it back.
    (undo-boundary)
    (let ((inhibit-message t) (last-command nil)) (undo 1))
    (should (equal (buffer-string) "keep 1\nold line\nkeep 2\n"))))

(ert-deftest mega-llm-a-rewrite-is-refused-if-the-text-moved-on ()
  (mega-llm-test--rewriting "new line\n"
    (goto-char (point-min))
    (search-forward "old")
    (insert "er")
    (with-current-buffer "*claude*"
      (should-error (mega-claude-apply) :type 'user-error))
    (should (equal (buffer-string) "keep 1\nolder line\nkeep 2\n")))
  ;; Edits elsewhere in the buffer do not matter: the place is tracked.
  (mega-llm-test--rewriting "new line\n"
    (goto-char (point-min))
    (insert "a new first line\n")
    (with-current-buffer "*claude*" (mega-claude-apply))
    (should (equal (buffer-string) "a new first line\nkeep 1\nnew line\nkeep 2\n"))))

(ert-deftest mega-llm-a-rewrite-into-a-read-only-buffer-is-refused ()
  (mega-llm-test--rewriting "new line\n"
    (setq buffer-read-only t)
    (with-current-buffer "*claude*"
      (should-error (mega-claude-apply) :type 'buffer-read-only))
    (should (equal (buffer-string) "keep 1\nold line\nkeep 2\n"))))

(ert-deftest mega-llm-an-unchanged-rewrite-proposes-nothing ()
  (mega-llm-test--rewriting "old line\n"
    (should (equal mega-llm-test--said "Claude returned the text unchanged"))
    (should-not (get-buffer "*claude*"))))

(ert-deftest mega-llm-a-rewrite-is-shown-even-without-the-diff-program ()
  (cl-letf (((symbol-function 'mega-claude--difference)
             (lambda (_old new) new)))
    (mega-llm-test--rewriting "new line\n"
      (should (string-match-p "new line" (mega-test-buffer-string "*claude*")))
      (with-current-buffer "*claude*" (mega-claude-apply))
      (should (equal (buffer-string) "keep 1\nnew line\nkeep 2\n")))))

;;;; The session

(ert-deftest mega-llm-the-session-goes-where-emacs-is ()
  (mega-llm-test--with-claude
    (let ((mega-claude-terminal 'auto))
      (let ((process-environment (cons "TMUX=/tmp/tmux-1000/default,1,0"
                                       process-environment)))
        (should (eq (mega-claude--terminal) 'tmux)))
      (let ((process-environment (cons "TMUX" process-environment)))
        (should (eq (mega-claude--terminal) 'emacs))))
    (let ((mega-claude-terminal 'emacs))
      (should (eq (mega-claude--terminal) 'emacs)))))

(ert-deftest mega-llm-a-tmux-session-is-opened-once-per-project ()
  (mega-llm-test--with-claude
    (let ((mega-claude-terminal 'tmux))
      (mega-claude)
      (should (equal (mega-llm-test--read "tmux.log")
                     (format "split-window -h -P -F #{pane_id} -c %s env claude\nselect-pane -t %%7\n"
                             (directory-file-name dir))))
      ;; Again: the pane is still there, so go to it.
      (mega-claude)
      (should (= 1 (with-temp-buffer
                     (insert (mega-llm-test--read "tmux.log"))
                     (how-many "^split-window" (point-min)))))
      ;; Closed meanwhile: open a new one.
      (mega-test-write (expand-file-name "pane-gone" fake) "")
      (mega-claude)
      (should (= 2 (with-temp-buffer
                     (insert (mega-llm-test--read "tmux.log"))
                     (how-many "^split-window" (point-min))))))))

(ert-deftest mega-llm-text-is-pasted-into-the-tmux-session-not-typed-on-a-command-line ()
  (mega-llm-test--with-claude
    (let ((mega-claude-terminal 'tmux))
      (with-temp-buffer
        (insert "line one\nline two; rm -rf $HOME\n")
        ;; No session yet: nothing is started behind your back.
        (should-error (mega-claude-send-region (point-min) (point-max))
                      :type 'user-error)
        (should-not (mega-llm-test--read "tmux.log"))
        (mega-claude)
        (mega-claude-send-region (point-min) (point-max)))
      (should (equal (mega-llm-test--read "pasted")
                     "line one\nline two; rm -rf $HOME\n"))
      (let ((log (mega-llm-test--read "tmux.log")))
        (should (string-match-p "^load-buffer -b mega-claude -$" log))
        (should (string-match-p "^paste-buffer -p -d -b mega-claude -t %7$" log))
        (should-not (string-match-p "line one\\|rm -rf" log))))))

(ert-deftest mega-llm-a-session-in-an-emacs-terminal-runs-in-the-project ()
  (mega-llm-test--with-claude
    (let ((mega-claude-terminal 'emacs)
          session)
      (save-window-excursion
        (unwind-protect
            (progn
              (mega-claude)
              (setq session (cdr (assoc dir mega-claude--sessions)))
              (should (bufferp session))
              (should (eq (current-buffer) session))
              (should (derived-mode-p 'term-mode))
              (should (process-live-p (get-buffer-process session)))
              (should (mega-test-wait-for
                       (lambda () (mega-llm-test--read "session-cwd")) 10))
              (should (equal (string-trim (mega-llm-test--read "session-cwd"))
                             (directory-file-name dir)))
              ;; A second request finds the same session.
              (mega-claude)
              (should (eq (cdr (assoc dir mega-claude--sessions)) session))
              ;; Pasted as one piece, so that a newline is not "send".
              (with-temp-buffer
                (insert "one\ntwo\n")
                (mega-claude-send-region (point-min) (point-max)))
              (should (mega-test-wait-for
                       (lambda ()
                         (string-match-p "\e\\[200~one\ntwo\n"
                                         (or (mega-llm-test--read "session-input") "")))
                       10)))
          (when (buffer-live-p session)
            (when-let* ((process (get-buffer-process session)))
              (set-process-query-on-exit-flag process nil))
            (kill-buffer session)))))))

(provide 'mega-llm-test)
;;; mega-llm-test.el ends here
