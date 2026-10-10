;;; mega-container-probe.el --- MEGA against a real container  -*- lexical-binding: t; -*-

;;; Commentary:

;; Not an ERT file, and not run unless asked for:
;;
;;   MEGA_REAL_IMAGE=some/image:tag tests/test_mega2.sh container
;;
;; The unit tests meet a container program and two debuggers that are
;; scripts written for the purpose.  A script does what its author knew the
;; real thing to do.  This probe starts a real container with podman, from a
;; devcontainer.json, and uses it the way a person would: runs programs in
;; it, builds a C program, and debugs that with each debugger the image has,
;; through MEGA's adapter client and through the debugger's own console.
;; The first time it was run it found three things no stand-in had: the
;; commands of the file ran before the container's PATH was known, lldb's
;; adapter started nothing where the kernel refuses to fix addresses, and
;; with gdb only a function's arguments were shown, not its variables.
;;
;; What it needs: podman; an image that is on this machine already and holds
;; a C compiler; gdb 14 or newer, or lldb with its adapter, for the debugger
;; part, which is left out, and said to be, for whichever is missing.
;;
;; What it does to the machine: one container, made from that image with no
;; network, labelled with a folder in the test sandbox, and removed by the
;; runner afterwards whatever happened here.  Nothing is downloaded.  No
;; other container is looked at.
;;
;; A probe that plays the person has to answer questions, and one that says
;; yes to everything will say yes to something nobody meant: the first
;; version of this file agreed, in passing, to Emacs's offer to fetch a
;; parser for C.  So the answers here are to named questions only.  Any
;; other question is answered no and reported as a failure, and Emacs's
;; offer of a parser is switched off before a file is opened.
;;
;; A line of output is a verdict, a tab, and the text: `ok', `bad', `skip'
;; or `note'.

;;; Code:

(require 'mega-test-helper)
(require 'mega-container)
(require 'mega-debug)
(require 'mega-dap)
(require 'mega-trust)
(require 'gud)

;; Special before it is bound below: bound as a lexical variable, it would
;; switch nothing off.
(defvar treesit-auto-install-grammar)

(defvar mega-container-probe--failed 0)

(defvar mega-container-probe--unexpected nil
  "Questions the probe was asked and had no answer for, newest first.")

(defconst mega-container-probe--agreed
  '("\\`Start this container" "\\`Stop the container of "
    "\\`Stop the debugger and the program it is running")
  "The questions a person running this probe would say yes to.")

(defun mega-container-probe--answer (prompt &rest _)
  "Say yes to PROMPT if it is one of the expected questions; else note it."
  (or (seq-some (lambda (regexp) (string-match-p regexp prompt))
                mega-container-probe--agreed)
      (progn (push prompt mega-container-probe--unexpected) nil)))

(defun mega-container-probe--say (verdict text &optional detail)
  "Print one line: VERDICT, TEXT and, for a failure, DETAIL."
  (princ (format "%s\t%s%s\n" verdict text
                 (if (and detail (equal verdict "bad"))
                     (format "   [%s]"
                             (truncate-string-to-width
                              (replace-regexp-in-string "\n" " | " (format "%s" detail))
                              600))
                   ""))))

(defun mega-container-probe--check (text passed &optional detail)
  "Report TEXT as held if PASSED is non-nil, with DETAIL if it is not."
  (unless passed
    (setq mega-container-probe--failed (1+ mega-container-probe--failed)))
  (mega-container-probe--say (if passed "ok" "bad") text detail)
  passed)

(defun mega-container-probe--wait (predicate seconds)
  "Wait up to SECONDS for PREDICATE to return non-nil; return its value."
  (let ((deadline (+ (float-time) seconds)) value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    value))

(defun mega-container-probe--text (buffer)
  "The text of BUFFER, a buffer or its name; empty if there is none."
  (if (and buffer (get-buffer buffer))
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun mega-container-probe--project (root image)
  "Write a small project into ROOT, to run in a container made from IMAGE."
  (mega-test-write (expand-file-name ".devcontainer/devcontainer.json" root)
                   "{"
                   "    // Made by MEGA's tests.  No network; removed afterwards."
                   "    \"name\": \"mega-container-probe\","
                   (format "    \"image\": %s," (json-serialize image))
                   ;; Never fetched; and your user inside, so that what you
                   ;; own here can be read and written there.
                   "    \"runArgs\": [\"--network\", \"none\", \"--pull=never\", \"--userns=keep-id\"],"
                   "    \"remoteEnv\": {"
                   "        \"PATH\": \"${containerEnv:PATH}:/opt/mega-probe\","
                   "        \"MEGA_PROBE\": \"yes\""
                   "    },"
                   "    \"onCreateCommand\": \"echo created > /tmp/mega-created\","
                   "    \"postStartCommand\": [\"sh\", \"-c\", \"sleep 2; echo started > /tmp/mega-started\"],"
                   "    \"customizations\": {\"vscode\": {\"extensions\": []}},"
                   "    \"somethingNobodyKnows\": true"
                   "}"
                   "")
  (mega-test-write (expand-file-name "main.c" root)
                   "#include <stdio.h>"
                   "static int twice(int value) {"
                   "    int result = value * 2;"
                   "    return result;"
                   "}"
                   "int main(void) {"
                   "    int answer = twice(21);"
                   "    printf(\"the answer is %d\\n\", answer);"
                   "    return 0;"
                   "}"
                   ""))

(defun mega-container-probe--container (root buffer)
  "Start the container of the project at ROOT, whose main.c is in BUFFER.
Return non-nil if it came up."
  (let ((check #'mega-container-probe--check)
        (shown nil)
        (file (expand-file-name ".devcontainer/devcontainer.json" root)))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (prompt &rest _)
                 (push (mega-container-probe--text mega-container-log-buffer) shown)
                 (mega-container-probe--answer prompt))))
      (with-current-buffer buffer
        (funcall check "a setting MEGA does not know is refused by name, and nothing starts"
                 (and (string-match-p
                       "somethingNobodyKnows"
                       (condition-case err (progn (mega-container-up) "started")
                         (user-error (error-message-string err))))
                      (not (assoc root mega-container--starting))
                      (null shown)))
        (with-temp-file file
          (insert-file-contents file)
          (goto-char (point-min))
          (re-search-forward ",\n *\"somethingNobodyKnows\": true")
          (replace-match ""))
        (let ((started (float-time)))
          (mega-container-up)
          (funcall check "starting returns at once" (< (- (float-time) started) 2.0)
                   (format "%.2f s" (- (float-time) started)))
          (funcall check "and the container is not there yet: it is being started"
                   (and (assoc root mega-container--starting)
                        (not (mega-container-attached root)))))))
    (let ((screen (or (car shown) "")))
      (funcall check "before anything ran, the screen showed the image, the commands and the mount"
               (and (string-match-p "mega-created" screen)
                    (string-match-p "mega-started" screen)
                    (string-match-p (regexp-quote (directory-file-name root)) screen)
                    (string-match-p "network" screen))
               screen))
    (funcall check "the container comes up in the background"
             (mega-container-probe--wait (lambda () (mega-container-attached root)) 180)
             (mega-container-probe--text mega-container-log-buffer))))

(defun mega-container-probe--inside (root source)
  "Check that programs run in the container of ROOT; SOURCE is its main.c.
Return non-nil if the project could be built there."
  (let* ((check #'mega-container-probe--check)
         (result (mega-exec-run
                  "sh" '("-c" "echo $MEGA_PROBE; echo $PATH; cat /tmp/mega-created /tmp/mega-started; pwd")
                  :directory root :timeout 30))
         (lines (split-string (plist-get result :output) "\n")))
    (funcall check "a program runs inside, with the environment the file asks for"
             (and (eql (plist-get result :status) 0) (equal (nth 0 lines) "yes"))
             (concat (plist-get result :output) (plist-get result :error)))
    (funcall check "${containerEnv:PATH} was filled in from the container"
             (and (string-suffix-p ":/opt/mega-probe" (or (nth 1 lines) ""))
                  (string-match-p "/bin" (nth 1 lines))
                  (not (string-match-p "containerEnv" (nth 1 lines))))
             (nth 1 lines))
    (funcall check "the commands of the file ran, each to its end, a list of words included"
             (and (equal (nth 2 lines) "created") (equal (nth 3 lines) "started"))
             (plist-get result :output))
    (funcall check "programs start in the project's folder inside"
             (equal (nth 4 lines)
                    (directory-file-name (mega-exec-translate root 'inside root)))
             (nth 4 lines))
    (let ((inside (mega-exec-translate source 'inside root)))
      (funcall check "file names are translated both ways"
               (and (not (equal inside source))
                    (equal (mega-exec-translate inside 'host root) source))
               inside))
    (funcall check "a program meant for this machine still runs on this machine"
             (equal (string-trim
                     (plist-get (mega-exec-run
                                 "sh" '("-c" "test -e /run/.containerenv -o -e /.dockerenv && echo inside || echo outside")
                                 :directory root :here t :timeout 10)
                                :output))
                    "outside"))
    (if (not (mega-exec-find "cc" root))
        (progn (mega-container-probe--say "skip" "building and debugging: the image has no C compiler")
               nil)
      (let ((built (mega-exec-run "cc" '("-g" "-O0" "-o" "prog" "main.c")
                                  :directory root :timeout 120)))
        (funcall check "the project builds in the container, and the result is here"
                 (and (eql (plist-get built :status) 0)
                      (file-exists-p (expand-file-name "prog" root)))
                 (concat (plist-get built :error) (plist-get built :output)))))))

(defun mega-container-probe--adapter (family root source buffer)
  "Debug the program of ROOT through the debug adapter of FAMILY.
SOURCE is its main.c, visited in BUFFER."
  (let* ((check #'mega-container-probe--check)
         (mega-debug-prefer (list family))
         (mega-debug-backend 'dap)
         (plan (mega-debug-plan (mega-debug-language root) root))
         (label (format "%s as a debug adapter" family)))
    (if (not (and (eq (car plan) 'dap) (eq (plist-get (cddr plan) :family) family)))
        (mega-container-probe--say "skip" (format "%s: the image has none that will do" label))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line 2)
        (setq mega-dap-breakpoints nil)
        (mapc #'delete-overlay (mega-dap--overlays))
        (mega-debug-break)
        (funcall check (format "%s: a breakpoint is set in the file here, before starting" label)
                 (equal (mega-dap-lines source) '(3)) mega-dap-breakpoints)
        (mega-debug)
        (funcall check (format "%s: the program stops at it" label)
                 (mega-container-probe--wait
                  (lambda () (and (eq mega-dap--state 'stopped) mega-dap--frames)) 60)
                 (format "state %S, reason %S, said %S" mega-dap--state mega-dap--reason
                         (take 6 mega-dap--output)))
        (let ((frame (car mega-dap--frames)))
          (funcall check (format "%s: in the function, at the line, in the file on this machine" label)
                   (and (string-match-p "twice" (or (plist-get frame :name) ""))
                        (eql (plist-get frame :line) 3)
                        (equal (plist-get frame :file) source))
                   frame))
        (funcall check (format "%s: the argument and the local variable are both shown" label)
                 (mega-container-probe--wait
                  (lambda () (and (equal (cdr (assoc "value" mega-dap--locals)) "21")
                                  (assoc "result" mega-dap--locals)))
                  20)
                 mega-dap--locals)
        (funcall check (format "%s: the line is marked in the buffer here" label)
                 (mega-container-probe--wait
                  (lambda () (and (overlayp mega-dap--arrow)
                                  (eq (overlay-buffer mega-dap--arrow) buffer)
                                  (= (line-number-at-pos (overlay-start mega-dap--arrow)) 3)))
                  10))
        (when (eq mega-dap--state 'stopped)
          (mega-dap-do 'next)
          (funcall check (format "%s: a step goes to the next line, and the variable has its value" label)
                   (mega-container-probe--wait
                    (lambda () (and (eq mega-dap--state 'stopped)
                                    (eql (plist-get (car mega-dap--frames) :line) 4)
                                    (equal (cdr (assoc "result" mega-dap--locals)) "42")))
                    30)
                   (list (car mega-dap--frames) mega-dap--locals))
          (when (eq mega-dap--state 'stopped)
            (mega-dap-do 'continue)))
        (funcall check (format "%s: the program runs to its end, and what it printed is kept" label)
                 (mega-container-probe--wait
                  (lambda () (and (not (mega-dap-active-p))
                                  (string-match-p "the answer is 42"
                                                  (mega-container-probe--text mega-dap-info-buffer))))
                  30)
                 (mega-container-probe--text mega-dap-info-buffer))
        (when (mega-dap-active-p)
          (ignore-errors (mega-dap-quit)))
        (mega-container-probe--wait (lambda () (not (process-live-p mega-dap--process))) 10)))))

(defun mega-container-probe--console (family root buffer)
  "Debug the program of ROOT through the console of the debugger of FAMILY.
That is Emacs's own interface; its main.c is visited in BUFFER."
  (let* ((check #'mega-container-probe--check)
         (mega-debug-prefer (list family))
         (mega-debug-backend 'gud)
         (plan (mega-debug-plan (mega-debug-language root) root))
         (label (format "%s through its console" family))
         (prompt (format "(%s) " family))
         (seen (lambda (regexp)
                 (lambda ()
                   (and (buffer-live-p gud-comint-buffer)
                        (string-match-p regexp
                                        (mega-container-probe--text gud-comint-buffer))))))
         (say (lambda (text)
                (with-current-buffer gud-comint-buffer
                  (goto-char (point-max))
                  (insert text)
                  (comint-send-input)))))
    (if (not (and (eq (car plan) 'gud) (eq (plist-get (cddr plan) :family) family)))
        (mega-container-probe--say "skip" (format "%s: the image has none" label))
      (with-current-buffer buffer
        (save-window-excursion
          (mega-debug)
          (when (funcall check (format "%s: it starts in the container" label)
                         (mega-container-probe--wait (funcall seen (regexp-quote prompt)) 60)
                         (mega-container-probe--text gud-comint-buffer))
            ;; lldb's console takes what arrives in its first second for
            ;; Python: see the open points in DESIGN.md.
            (sleep-for 2)
            (funcall say (if (eq family 'gdb) "break twice" "breakpoint set --name twice"))
            (funcall check (format "%s: a breakpoint is set" label)
                     (mega-container-probe--wait (funcall seen "Breakpoint 1") 30)
                     (mega-container-probe--text gud-comint-buffer))
            (funcall say "run")
            ;; The debugger names the file as the container sees it; what
            ;; Emacs opens for that name must be the file of this machine.
            (funcall check (format "%s: the program stops, and the line is shown in the file here" label)
                     (mega-container-probe--wait
                      (lambda ()
                        (let ((frame (or gud-last-frame gud-last-last-frame)))
                          (and frame
                               (eql (if (consp (cdr frame)) (cadr frame) (cdr frame)) 3)
                               (eq (gud-find-file (car frame)) buffer))))
                      60)
                     (list gud-last-frame gud-last-last-frame
                           (mega-container-probe--text gud-comint-buffer)))
            (funcall say "continue")
            (funcall check (format "%s: the program runs to its end" label)
                     (mega-container-probe--wait (funcall seen "the answer is 42") 30)
                     (mega-container-probe--text gud-comint-buffer)))
          (when (mega-debug-running-p)
            (mega-debug-quit))
          (funcall check (format "%s: quitting ends it" label)
                   (mega-container-probe--wait (lambda () (not (mega-debug-running-p))) 20)))))))

(defun mega-container-probe-run ()
  "Run the probe and exit: 0 if everything held."
  (let* ((image (or (getenv "MEGA_REAL_IMAGE") (error "MEGA_REAL_IMAGE is not set")))
         (root (file-name-as-directory (getenv "MEGA_PROBE_PROJECT")))
         (source (expand-file-name "main.c" root))
         (check #'mega-container-probe--check)
         (inhibit-message t)
         (treesit-auto-install-grammar nil)
         ;; A session in which a person could be asked, and is: by these.
         (noninteractive nil)
         buffer)
    (mega-container-probe--project root image)
    (cl-letf (((symbol-function 'y-or-n-p) #'mega-container-probe--answer)
              ((symbol-function 'yes-or-no-p) #'mega-container-probe--answer)
              ((symbol-function 'read-file-name)
               (lambda (prompt &rest _) (error "Asked: %s" prompt)))
              ;; No parser is offered, so none can be agreed to.
              ((symbol-function 'mega-lang-parser-p) #'ignore))
      (condition-case err
          (progn
            (setq buffer (find-file-noselect source))
            (with-current-buffer buffer
              (funcall check "the file opens in the plain mode: no parser was offered or fetched"
                       (eq major-mode 'c-mode) major-mode)
              (funcall check "the project starts out untrusted, and nothing checks it"
                       (and mega-trust-held (not (bound-and-true-p flymake-mode))))
              (mega-trust-project)
              (funcall check "trusting it starts the checking in the open buffer"
                       (and (not mega-trust-held) (bound-and-true-p flymake-mode)))
              (funcall check "no container yet: the tools are this machine's"
                       (eq (plist-get (mega-exec-context root) :kind) 'local)))
            (when (mega-container-probe--container root buffer)
              (mega-container-probe--say "note" "the log of the start:")
              (dolist (line (split-string (mega-container-probe--text
                                           mega-container-log-buffer)
                                          "\n" t))
                (mega-container-probe--say "note" (concat "  " line)))
              (funcall check "the project's tools now run in the container"
                       (not (eq (plist-get (mega-exec-context root) :kind) 'local)))
              (when (mega-container-probe--inside root source)
                (setf (alist-get root mega-debug--targets nil nil #'equal)
                      (expand-file-name "prog" root))
                (dolist (family '(lldb gdb))
                  (mega-container-probe--adapter family root source buffer))
                (dolist (family '(gdb lldb))
                  (mega-container-probe--console family root buffer)))
              (with-current-buffer buffer
                (mega-container-stop)
                (funcall check "stopping the container gives the tools back to this machine"
                         (and (not (mega-container-attached root))
                              (eq (plist-get (mega-exec-context root) :kind) 'local))))))
        (error
         (funcall check "the probe ran to its end" nil (error-message-string err)))))
    (funcall check "nothing was asked but what a person would expect to be asked"
             (null mega-container-probe--unexpected)
             (reverse mega-container-probe--unexpected))
    (kill-emacs (if (> mega-container-probe--failed 0) 1 0))))

(provide 'mega-container-probe)
;;; mega-container-probe.el ends here
