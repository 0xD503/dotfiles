;;; mega-llm.el --- Claude, through its own program  -*- lexical-binding: t; -*-

;;; Commentary:

;; MEGA reaches Claude through the `claude' program (Claude Code) and in no
;; other way: Emacs holds no API key, makes no connection of its own and
;; needs no package.  Whatever that program is signed in as is what is used.
;;
;;   C-c l c   this project's Claude session: start it, or go back to it
;;   C-c l v   paste the selected text into that session
;;   C-c l a   ask a question; selected text goes with it
;;   C-c l e   explain the selected text, or the function at point
;;   C-c l r   rewrite the selected text as you say: shows the difference
;;             and changes nothing until you press RET on it
;;   C-c l k   stop waiting for an answer
;;
;; The session (C-c l c) is the full program, in a terminal: in a pane beside
;; Emacs when Emacs runs inside tmux, otherwise in an Emacs buffer.  There
;; Claude can read and change the project, and asks you before it does.
;;
;; The three questions (a, e, r) are one-shot: text goes in, text comes
;; back, and Claude can touch nothing.
;;
;; Privacy.  Text leaves this machine only when you press one of these keys,
;; and only the text you selected, with the file's name inside the project.
;; With nothing selected, `e' and `r' offer the function the cursor is in,
;; say how many lines that is, and send it only on a yes; outside code they
;; send nothing unselected at all.  Nothing is sent in the background, ever.  A file `mega-private-file-p' recognises
;; is sent only after you confirm with a typed "yes".  The text goes to the
;; program on its standard input, never on its command line, where other
;; users of the machine could read it.
;;
;; Security.  A one-shot question never runs in the project: `claude --print'
;; skips the program's own "do you trust this folder?" question, and a
;; project can carry settings that run commands.  It runs in an empty
;; directory of MEGA's, with every tool, every MCP server and the project's
;; and the directory's settings switched off, and nothing saved.  See
;; `mega-claude-print-arguments'.
;;
;; Safety.  A rewrite is never applied by itself.  It is shown as a
;; difference, and applied only if the text is still exactly what was sent.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)

(require 'mega-project)
(declare-function term-mode "term")
(declare-function term-char-mode "term")
(declare-function make-term "term")

(defcustom mega-claude-program "claude"
  "The Claude command-line program."
  :type 'string
  :group 'mega)

(defcustom mega-claude-model nil
  "The model one-shot questions use, or nil for the program's own default."
  :type '(choice (const :tag "The program's default" nil) string)
  :group 'mega)

(defcustom mega-claude-terminal 'auto
  "Where a Claude session runs.
`tmux' opens a pane beside Emacs, `emacs' a terminal buffer; `auto' is
tmux when Emacs itself runs inside tmux."
  :type '(choice (const auto) (const tmux) (const emacs))
  :group 'mega)

(defcustom mega-claude-arguments nil
  "Extra arguments for the program when it starts a session."
  :type '(repeat string)
  :group 'mega)

(defcustom mega-claude-print-arguments
  '("--print" "--output-format" "text"
    "--tools" ""
    "--strict-mcp-config"
    "--setting-sources" "user"
    "--permission-prompts" "none"
    "--no-session-persistence")
  "Arguments for a one-shot question.
As given they mean: answer and exit; no tools, so nothing is read,
written or run; no MCP servers; your own settings only, not a
project's; anything that would need permission is refused; and the
exchange is not kept on disk.  The question is not among them: it is
sent on standard input."
  :type '(repeat string)
  :group 'mega)

;;;; What is sent

(defun mega-claude--root ()
  "The project the current buffer belongs to, or its directory."
  (mega-project-directory))

(defun mega-claude--scope (&optional region-only)
  "What to send from the current buffer: (START . END), or nil.
The region when there is one.  Otherwise, unless REGION-ONLY is non-nil,
the function at point, and only in a buffer of code: elsewhere \"the
function at point\" can be most of the file."
  (cond ((use-region-p) (cons (region-beginning) (region-end)))
        (region-only nil)
        ((derived-mode-p 'prog-mode) (bounds-of-thing-at-point 'defun))))

(defun mega-claude--confirm-scope (scope)
  "Signal an error unless the user agrees to send SCOPE, a (START . END).
Asked only when nothing was selected: text you selected you chose; text
MEGA chose for you, you are shown the size of first."
  (unless (or (use-region-p)
              (y-or-n-p (format "Nothing is selected.  Send the function at point, %d lines, to Claude? "
                                (mega-claude--lines scope))))
    (user-error "Nothing was sent")))

(defun mega-claude--confirm-private ()
  "Signal an error unless text of the current buffer may be sent.
A file MEGA takes for private needs a typed yes, every time."
  (when (and buffer-file-name
             (mega-private-file-p buffer-file-name)
             (not (yes-or-no-p
                   (format "%s looks private.  Send text from it to Claude anyway? "
                           (file-name-nondirectory buffer-file-name)))))
    (user-error "Nothing was sent")))

(defun mega-claude--label ()
  "How the current buffer is named to Claude: its file within the project."
  (if buffer-file-name
      (file-relative-name buffer-file-name (mega-claude--root))
    (buffer-name)))

(defun mega-claude--fence (text)
  "A Markdown fence long enough to hold TEXT."
  (let ((longest 2) (start 0))
    (while (string-match "`+" text start)
      (setq longest (max longest (- (match-end 0) (match-beginning 0)))
            start (match-end 0)))
    (make-string (1+ longest) ?`)))

(defun mega-claude--quote (scope)
  "The text of SCOPE, a (START . END), as a labelled block for Claude."
  (let* ((text (buffer-substring-no-properties (car scope) (cdr scope)))
         (fence (mega-claude--fence text)))
    (format "From %s, lines %d-%d:\n%s\n%s%s%s\n"
            (mega-claude--label)
            (line-number-at-pos (car scope) t)
            (line-number-at-pos (max (car scope) (1- (cdr scope))) t)
            fence text
            (if (string-suffix-p "\n" text) "" "\n")
            fence)))

(defun mega-claude--lines (scope)
  "How many lines SCOPE, a (START . END), spans."
  (count-lines (car scope) (cdr scope)))

;;;; One-shot questions

(defvar mega-claude--request nil
  "The program answering a one-shot question, while there is one.")

(defun mega-claude--directory ()
  "The empty directory one-shot questions run in.
Not the project: see the Commentary."
  (mega-cache "claude/"))

(defun mega-claude--print-command ()
  "The arguments of a one-shot question."
  (append mega-claude-print-arguments
          (and mega-claude-model (list "--model" mega-claude-model))))

(defun mega-claude--ask (prompt then)
  "Send PROMPT to Claude and call THEN with the answer, a string.
On failure THEN is not called and the reason is reported."
  (unless (mega-exe-p mega-claude-program)
    (user-error "The `%s' program is not installed" mega-claude-program))
  (when (process-live-p mega-claude--request)
    (user-error "Claude is still answering the last question (C-c l k stops it)"))
  (setq mega-claude--request
        (mega-exec-start
         mega-claude-program (mega-claude--print-command)
         :directory (mega-claude--directory)
         ;; Your own program and sign-in: on this machine, not in a container
         ;; and not wherever the file being edited happens to live.
         :here t
         :input prompt
         :then (lambda (result)
                 (setq mega-claude--request nil)
                 (cond ((plist-get result :stopped)
                        (message "Stopped waiting for Claude"))
                       ((eql (plist-get result :status) 0)
                        (funcall then (plist-get result :output)))
                       (t
                        (message "Claude failed: %s"
                                 (string-trim
                                  (if (string-empty-p (plist-get result :error))
                                      (plist-get result :output)
                                    (plist-get result :error)))))))))
  (message "Asked Claude; the answer will appear when it is ready (C-c l k stops waiting)"))

;;;###autoload
(defun mega-claude-stop ()
  "Stop waiting for Claude's answer to a one-shot question."
  (interactive)
  (if (process-live-p mega-claude--request)
      (mega-exec-stop mega-claude--request)
    (message "Claude is not answering anything")))

;;;; Showing an answer

(defvar-local mega-claude--rewrite nil
  "The rewrite this buffer proposes: a plist.
:buffer and :start, :end (markers) say where; :old is the text that was
sent and :new what would replace it.")

(defvar mega-claude-answer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'mega-claude-apply)
    (define-key map (kbd "C-c C-c") #'mega-claude-apply)
    map)
  "Keys of the buffer that shows Claude's answers.")

(define-derived-mode mega-claude-answer-mode special-mode "Claude"
  "What Claude answered.  `q' closes the window.
When the answer is a rewrite, \\[mega-claude-apply] applies it."
  (setq-local truncate-lines nil))

(defun mega-claude--show (heading body &optional rewrite)
  "Show BODY under HEADING in the answer buffer, without selecting it.
REWRITE, when non-nil, is the rewrite the buffer then proposes."
  (let ((buffer (get-buffer-create "*claude*")))
    (with-current-buffer buffer
      (mega-claude-answer-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize heading 'face 'bold) "\n\n" body)
        (unless (bolp) (insert "\n"))
        (goto-char (point-min)))
      (setq mega-claude--rewrite rewrite
            header-line-format
            (if rewrite
                " RET apply this rewrite   q leave the text as it is"
              " q close")))
    (display-buffer buffer '((display-buffer-reuse-window
                              display-buffer-in-side-window)
                             (side . bottom) (window-height . 0.35)))
    buffer))

;;;###autoload
(defun mega-claude-ask (question)
  "Ask Claude QUESTION.  The selected text, if any, is sent with it."
  (interactive
   (let ((scope (mega-claude--scope t)))
     (when scope (mega-claude--confirm-private))
     (list (read-string
            (if scope
                (format "Ask Claude (sending the %d selected lines): "
                        (mega-claude--lines scope))
              "Ask Claude (no text is sent with the question): ")))))
  (when (string-empty-p (string-trim question))
    (user-error "Nothing to ask"))
  (let ((scope (mega-claude--scope t)))
    (mega-claude--ask
     (if scope (concat question "\n\n" (mega-claude--quote scope)) question)
     (lambda (answer) (mega-claude--show question answer)))))

;;;###autoload
(defun mega-claude-explain ()
  "Ask Claude to explain the selected text, or the function at point."
  (interactive)
  (let ((scope (mega-claude--scope)))
    (unless scope
      (user-error "Select the text to explain first"))
    (mega-claude--confirm-private)
    (mega-claude--confirm-scope scope)
    (let ((heading (format "%s, %d lines" (mega-claude--label)
                           (mega-claude--lines scope))))
      (mega-claude--ask
       (concat "Explain what this code does and anything surprising about it. "
               "Be brief.\n\n"
               (mega-claude--quote scope))
       (lambda (answer) (mega-claude--show heading answer))))))

;;;; Rewriting

(defun mega-claude--strip-fence (answer)
  "ANSWER without the code fence Claude may have put around all of it.
Blank lines around it go too; the indentation of its first line stays."
  (let* ((text (string-trim answer "[\n\r]+" "[ \t\n\r]+"))
         (fence (and (string-match "\\``\\{3,\\}" text) (match-string 0 text)))
         (first (and fence (string-search "\n" text)))
         (last (and first (- (length text) (length fence) 1))))
    (if (and last (> last first) (string-suffix-p (concat "\n" fence) text))
        (substring text (1+ first) last)
      text)))

(defun mega-claude--replacement (answer old)
  "The text to put in place of OLD, given Claude's ANSWER.
The fence is removed, and the text ends in a newline exactly if OLD did."
  (let ((new (string-trim-right (mega-claude--strip-fence answer) "\n+")))
    (if (string-suffix-p "\n" old) (concat new "\n") new)))

(defun mega-claude--difference (old new)
  "The difference between the strings OLD and NEW, as text to show.
A unified diff when the `diff' program exists, else NEW itself.

`diff' compares files, so both texts are written down for it: into
MEGA's own cache directory, which only you can read, and not into the
shared temporary directory, since the text may come from a private file.
They are deleted at once."
  (if (not (mega-exe-p "diff"))
      new
    (let* ((directory (mega-cache "claude-diff/"))
           (before (make-temp-file (expand-file-name "before-" directory)))
           (after (make-temp-file (expand-file-name "after-" directory)))
           (coding-system-for-write 'utf-8-unix))
      (unwind-protect
          (progn
            (write-region old nil before nil 'silent)
            (write-region new nil after nil 'silent)
            (let* ((result (mega-exec-run "diff" (list "-u" before after)
                                          :here t :timeout 10))
                   (output (plist-get result :output))
                   (hunks (string-match "^@@" output)))
              (cond ((eql (plist-get result :status) 0)
                     "(Claude returned the text unchanged.)")
                    ;; From the first hunk on: the two lines before it name
                    ;; the temporary files.
                    (hunks (string-trim-right (substring output hunks)))
                    (t new))))
        (delete-file before)
        (delete-file after)))))

(defun mega-claude--propose (rewrite answer)
  "Show ANSWER as the rewrite REWRITE proposes, unless the text has moved on."
  (let* ((buffer (plist-get rewrite :buffer))
         (old (plist-get rewrite :old))
         (new (mega-claude--replacement answer old)))
    (cond ((not (buffer-live-p buffer))
           (mega-claude--show "The buffer is gone; this was the rewrite" new))
          ((equal new old)
           (message "Claude returned the text unchanged"))
          (t
           (let ((shown (mega-claude--show
                         (format "Rewrite of %d lines in %s"
                                 (length (split-string
                                          (string-trim-right old "\n") "\n"))
                                 (buffer-name buffer))
                         (mega-claude--difference old new)
                         (plist-put rewrite :new new))))
             (with-current-buffer shown
               (let ((inhibit-read-only t))
                 (save-excursion
                   (goto-char (point-min))
                   (while (re-search-forward "^[-+].*$" nil t)
                     (put-text-property
                      (match-beginning 0) (match-end 0) 'face
                      (if (eq (char-after (match-beginning 0)) ?+)
                          'diff-added 'diff-removed))))))
             (message "Claude's rewrite is ready: RET in *claude* applies it"))))))

;;;###autoload
(defun mega-claude-rewrite (instruction)
  "Ask Claude to rewrite the selected text, or the function at point.
INSTRUCTION says how.  The result is shown as a difference and applied
only when you press RET on it."
  (interactive
   (progn
     (barf-if-buffer-read-only)
     (unless (mega-claude--scope)
       (user-error "Select the text to rewrite first"))
     (mega-claude--confirm-private)
     (list (read-string
            (format (if (use-region-p)
                        "Rewrite these %d lines how? "
                      "Nothing is selected.  Rewrite the function at point, %d lines, how? ")
                    (mega-claude--lines (mega-claude--scope)))))))
  (when (string-empty-p (string-trim instruction))
    (user-error "Say how to rewrite it"))
  (let* ((scope (mega-claude--scope))
         (rewrite (list :buffer (current-buffer)
                        :start (copy-marker (car scope))
                        :end (copy-marker (cdr scope) t)
                        :old (buffer-substring-no-properties (car scope) (cdr scope)))))
    (mega-claude--ask
     (concat "Rewrite the code below as instructed.  Answer with the rewritten "
             "code only: no explanation before or after it.\n\n"
             "Instruction: " instruction "\n\n"
             (mega-claude--quote scope))
     (lambda (answer) (mega-claude--propose rewrite answer)))))

(defun mega-claude-apply ()
  "Apply the rewrite this buffer shows, if the text is still what was sent."
  (interactive)
  (let ((rewrite mega-claude--rewrite))
    (unless rewrite
      (user-error "There is no rewrite here to apply"))
    (let ((buffer (plist-get rewrite :buffer))
          (start (plist-get rewrite :start))
          (end (plist-get rewrite :end)))
      (unless (buffer-live-p buffer)
        (user-error "The buffer this rewrite was for is gone"))
      (with-current-buffer buffer
        (barf-if-buffer-read-only)
        (unless (equal (buffer-substring-no-properties start end)
                       (plist-get rewrite :old))
          (user-error "The text has changed since it was sent; nothing was replaced"))
        ;; One change, so one `C-/' takes it back.
        (replace-region-contents start end (plist-get rewrite :new)))
      (setq mega-claude--rewrite nil
            header-line-format " Applied.   q close")
      (set-marker start nil)
      (set-marker end nil)
      (message "Applied; C-/ in %s undoes it" (buffer-name buffer)))))

;;;; The session

(defvar mega-claude--sessions nil
  "The Claude session of each project: an alist (ROOT . SESSION).
SESSION is a tmux pane id, a string, or a terminal buffer.")

(defun mega-claude--terminal ()
  "Where a new session goes: `tmux' or `emacs'."
  (pcase mega-claude-terminal
    ('auto (if (and (getenv "TMUX") (mega-exe-p "tmux")) 'tmux 'emacs))
    (kind kind)))

(defun mega-claude--tmux (&rest arguments)
  "Run tmux with ARGUMENTS and return what `mega-exec-run' returns."
  (mega-exec-run "tmux" arguments :here t :timeout 5))

(defun mega-claude--session (root)
  "The live Claude session of the project at ROOT, or nil."
  (let ((session (cdr (assoc root mega-claude--sessions))))
    (cond ((bufferp session)
           (and (buffer-live-p session)
                (process-live-p (get-buffer-process session))
                session))
          ((stringp session)
           (and (eql 0 (plist-get (mega-claude--tmux "display-message" "-p" "-t" session
                                                     "#{pane_id}")
                                  :status))
                session)))))

(defun mega-claude--start (root)
  "Start a Claude session for the project at ROOT and return it."
  (let ((default-directory root))
    (pcase (mega-claude--terminal)
      ('tmux
       ;; `env' in front makes tmux run the program itself instead of
       ;; handing a line to a shell.
       (let ((result (apply #'mega-claude--tmux
                            "split-window" "-h" "-P" "-F" "#{pane_id}" "-c"
                            (directory-file-name root)
                            "env" mega-claude-program mega-claude-arguments)))
         (unless (eql 0 (plist-get result :status))
           (error "tmux could not open a pane: %s"
                  (string-trim (plist-get result :error))))
         (string-trim (plist-get result :output))))
      (_
       (require 'term)
       ;; On this machine, and with a terminal of its own, which is why
       ;; Emacs's terminal emulator starts it; the argument list still comes
       ;; from the one place that makes them.
       (let* ((command (mega-exec-command mega-claude-program mega-claude-arguments
                                          root t))
              (buffer (apply #'make-term
                             (format "claude: %s"
                                     (file-name-nondirectory (directory-file-name root)))
                             (car command) nil (cdr command))))
         (with-current-buffer buffer
           (term-mode)
           (term-char-mode))
         buffer)))))

;;;###autoload
(defun mega-claude ()
  "Go to this project's Claude session, starting it if there is none."
  (interactive)
  (unless (mega-exe-p mega-claude-program)
    (user-error "The `%s' program is not installed" mega-claude-program))
  (let* ((root (mega-claude--root))
         (session (or (mega-claude--session root)
                      (setf (alist-get root mega-claude--sessions nil nil #'equal)
                            (mega-claude--start root)))))
    (if (bufferp session)
        (pop-to-buffer session)
      (mega-claude--tmux "select-pane" "-t" session))))

(defun mega-claude--pasteable (text)
  "TEXT as it may be pasted into a terminal: without control characters.
A paste is fenced off by two escape sequences, and the terminal trusts
whatever lies between them.  Text that carried the closing one could end
the paste early, and what followed would be typed, and sent, as if by
you.  Newlines and tabs are kept; a carriage return is not one of them."
  (replace-regexp-in-string "[\u0000-\u0008\u000b-\u001f\u007f-\u009f]" "" text))

;;;###autoload
(defun mega-claude-send-region (start end)
  "Paste the text from START to END into this project's Claude session.
It is pasted, not sent: read it over there and press RET yourself."
  (interactive "r")
  (let ((session (mega-claude--session (mega-claude--root)))
        (text (mega-claude--pasteable (buffer-substring-no-properties start end))))
    (unless session
      (user-error "This project has no Claude session yet (C-c l c starts one)"))
    (mega-claude--confirm-private)
    (if (bufferp session)
        ;; As a bracketed paste, so that a newline is text and not "send".
        (process-send-string (get-buffer-process session)
                             (concat "\e[200~" text "\e[201~"))
      (let ((loaded (mega-exec-run "tmux" '("load-buffer" "-b" "mega-claude" "-")
                                   :here t :input text :timeout 5)))
        (unless (eql 0 (plist-get loaded :status))
          (error "tmux did not take the text: %s"
                 (string-trim (plist-get loaded :error))))
        (mega-claude--tmux "paste-buffer" "-p" "-d" "-b" "mega-claude" "-t" session)))
    (message "Pasted %d lines into the Claude session" (count-lines start end))))

;;;; The doctor


(defun mega-claude--doctor ()
  "Insert the doctor's section about Claude."
  (mega-doctor-heading "Claude")
  (let ((path (mega-exe-p mega-claude-program)))
    (mega-doctor-row mega-claude-program (or path "not found") (unless path 'shadow))
    (when path
      (mega-doctor-row "a session opens in"
                       (if (eq (mega-claude--terminal) 'tmux)
                           "a tmux pane beside Emacs"
                         "an Emacs terminal buffer"))
      (mega-doctor-row "one-shot questions"
                       (if (member "--tools" mega-claude-print-arguments)
                           "text in, text out: no tools, not in the project"
                         "CUSTOM arguments: check mega-claude-print-arguments")
                       (unless (member "--tools" mega-claude-print-arguments)
                         'warning)))))

(add-to-list 'mega-doctor-sections #'mega-claude--doctor t)

(provide 'mega-llm)
;;; mega-llm.el ends here
