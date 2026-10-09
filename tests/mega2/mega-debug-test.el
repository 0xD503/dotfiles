;;; mega-debug-test.el --- Tests for mega-debug.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; What MEGA adds to Emacs's debugger front end is a decision: which debugger,
;; on what, started how, and where.  Those are tested with stand-in programs.
;; The last test then runs a real session, with Python's pdb, when there is a
;; Python on this machine.

;;; Code:

(require 'mega-test-helper)
(require 'mega-trust)
(require 'mega-debug)

(defvar gud-comint-buffer)
(defvar gud-last-frame)
(defvar gud-last-last-frame)
(defvar gdb-debuginfod-enable-setting)

(defmacro mega-debug-test--with-tools (tools &rest body)
  "Run BODY in a trusted project DIR where only the programs TOOLS exist."
  (declare (indent 1) (debug (form body)))
  `(mega-test-with-directory dir
     (let* ((bin (expand-file-name "bin/" dir))
            (exec-path (list bin))
            (mega--exe-cache (make-hash-table :test #'equal))
            (mega-trust-file (expand-file-name "trusted.eld" dir))
            (mega-trust--decisions nil)
            (mega-debug--targets nil)
            (mega-exec-context-functions nil))
       (dolist (tool ,tools)
         (set-file-modes (mega-test-write (expand-file-name tool bin) "#!/bin/sh" "")
                         #o755))
       (mega-trust--record dir t)
       ,@body)))

(defun mega-debug-test--container (dir)
  "A context function that puts the project at DIR in a container."
  (lambda (directory)
    (when (file-in-directory-p directory dir)
      (list :kind 'container :name "box"
            :wrap (lambda (program args _where)
                    (append (list "podman" "exec" "cid") (cons program args)))
            :find (lambda (program) (member program '("gdb" "python3")))
            :to-inside (lambda (file)
                         (concat "/workspaces/p/" (file-relative-name file dir)))
            :to-host (lambda (file)
                       (if (string-prefix-p "/workspaces/p/" file)
                           (expand-file-name
                            (string-remove-prefix "/workspaces/p/" file) dir)
                         file))))))

;;;; Which debugger, on what

(ert-deftest mega-debug-language-follows-the-buffer-then-the-project ()
  (mega-test-with-directory dir
    (with-temp-buffer
      (should (eq (mega-debug-language dir) 'native))
      (mega-test-write (expand-file-name "Cargo.toml" dir) "[package]" "name = \"x\"")
      (should (eq (mega-debug-language dir) 'rust))
      ;; The file you are in says more than the project around it.
      (let ((inhibit-message t)) (python-mode))
      (should (eq (mega-debug-language dir) 'python)))))

(ert-deftest mega-debug-chooses-the-preferred-debugger-that-exists ()
  ;; lldb before gdb, where both are there.
  (mega-debug-test--with-tools '("gdb" "lldb")
    (should (eq (car (mega-debug-choose 'rust dir)) 'lldb))
    (should (eq (car (mega-debug-choose 'native dir)) 'lldb))
    (should-not (mega-debug-choose 'python dir)))
  ;; Rust's own wrapper before the plain debugger of the same family.
  (mega-debug-test--with-tools '("gdb" "rust-gdb" "lldb" "rust-lldb" "python3")
    (should (eq (car (mega-debug-choose 'rust dir)) 'rust-lldb))
    (should (eq (car (mega-debug-choose 'native dir)) 'lldb))
    (should (eq (car (mega-debug-choose 'python dir)) 'pdb)))
  ;; Whatever there is, when the preferred one is not.
  (mega-debug-test--with-tools '("gdb" "rust-gdb")
    (should (eq (car (mega-debug-choose 'rust dir)) 'rust-gdb))
    (should (eq (car (mega-debug-choose 'native dir)) 'gdb)))
  (mega-debug-test--with-tools nil
    (should-not (mega-debug-choose 'native dir))))

(ert-deftest mega-debug-the-preference-is-yours-to-turn-round ()
  (mega-debug-test--with-tools '("gdb" "rust-gdb" "lldb" "rust-lldb")
    (should (equal mega-debug-prefer '(lldb gdb)))
    (let ((mega-debug-prefer '(gdb lldb)))
      (should (eq (car (mega-debug-choose 'rust dir)) 'rust-gdb))
      (should (eq (car (mega-debug-choose 'native dir)) 'gdb)))
    ;; A family left out of the list comes after those in it.
    (let ((mega-debug-prefer '(gdb)))
      (should (eq (car (mega-debug-choose 'native dir)) 'gdb))
      (should (equal (mapcar #'car (mega-debug-candidates 'rust))
                     '(rust-gdb gdb rust-lldb lldb))))))

(ert-deftest mega-debug-looks-for-the-debugger-where-the-tools-are ()
  (mega-debug-test--with-tools nil
    ;; Nothing on this machine, gdb in the container.
    (let ((mega-exec-context-functions (list (mega-debug-test--container dir))))
      (should (eq (car (mega-debug-choose 'native dir)) 'gdb)))))

(ert-deftest mega-debug-finds-the-binary-a-cargo-project-builds ()
  (mega-test-with-directory dir
    (let ((manifest (expand-file-name "Cargo.toml" dir)))
      (should-not (mega-debug--cargo-binary dir))
      (mega-test-write manifest
                       "[package]" "edition = \"2024\"" "name = \"riscvmulator\""
                       "" "[dependencies]" "name = \"not-this\"")
      (should (equal (mega-debug--cargo-binary dir)
                     (expand-file-name "target/debug/riscvmulator" dir)))
      ;; A workspace has no package of its own, and no binary to guess.
      (mega-test-write manifest "[workspace]" "members = [\"a\"]"
                       "" "[workspace.package]" "name = \"not-this\"")
      (should-not (mega-debug--cargo-binary dir))
      ;; A name that belongs to a later table is not the package's.
      (mega-test-write manifest "[package]" "version = \"1\""
                       "" "[lib]" "name = \"not-this\"")
      (should-not (mega-debug--cargo-binary dir)))))

(ert-deftest mega-debug-finds-the-binary-of-the-package-you-are-in ()
  "A workspace builds its packages into the `target' at its root."
  (mega-test-with-directory dir
    (mega-test-write (expand-file-name "Cargo.toml" dir)
                     "[workspace]" "members = [\"crates/*\"]")
    (mega-test-write (expand-file-name "crates/emu/Cargo.toml" dir)
                     "[package]" "name = \"emu\"")
    (mega-test-write (expand-file-name "crates/tool/Cargo.toml" dir)
                     "[package]" "name = \"tool\"")
    (let ((default-directory (expand-file-name "crates/emu/src/" dir)))
      (make-directory default-directory t)
      (should (equal (mega-debug--cargo-binary dir)
                     (expand-file-name "target/debug/emu" dir))))
    (let ((default-directory (expand-file-name "crates/tool/" dir)))
      (should (equal (mega-debug--cargo-binary dir)
                     (expand-file-name "target/debug/tool" dir)))
      ;; A package built on its own has its own `target'; what exists wins.
      (mega-test-write (expand-file-name "crates/tool/target/debug/tool" dir) "")
      (should (equal (mega-debug--cargo-binary dir)
                     (expand-file-name "crates/tool/target/debug/tool" dir))))
    ;; At the root of a workspace there is no one package to guess.
    (let ((default-directory dir))
      (should-not (mega-debug--cargo-binary dir)))))

(ert-deftest mega-debug-remembers-what-was-debugged-last ()
  (mega-test-with-directory dir
    (let ((mega-debug--targets (list (cons dir "/somewhere/prog"))))
      (should (equal (mega-debug-default-target 'native dir) "/somewhere/prog")))
    (let ((mega-debug--targets nil))
      (should-not (mega-debug-default-target 'native dir)))))

;;;; The command line

(ert-deftest mega-debug-command-line-is-an-argument-list-quoted-word-by-word ()
  (mega-debug-test--with-tools '("gdb")
    (let* ((target (expand-file-name "target/debug/my prog; rm -rf x" dir))
           (command (mega-debug-command (assq 'gdb mega-debuggers) target dir)))
      (should (eq (car command) 'gdb))
      ;; GUD splits the line back into words; they must be the same words.
      (should (equal (split-string-and-unquote (cdr command))
                     (list "gdb" "-i=mi" target))))))

(ert-deftest mega-debug-in-a-container-uses-the-plain-interface-and-inside-names ()
  (mega-debug-test--with-tools nil
    (let* ((mega-exec-context-functions (list (mega-debug-test--container dir)))
           (target (expand-file-name "target/debug/prog" dir))
           (command (mega-debug-command (assq 'gdb mega-debuggers) target dir)))
      (should (eq (car command) 'gud-gdb))
      (should (equal (split-string-and-unquote (cdr command))
                     '("podman" "exec" "cid" "gdb" "--fullname"
                       "/workspaces/p/target/debug/prog")))
      ;; pdb has one interface; only where it runs changes.
      (let ((command (mega-debug-command (assq 'pdb mega-debuggers)
                                         (expand-file-name "run.py" dir) dir)))
        (should (eq (car command) 'pdb))
        (should (equal (split-string-and-unquote (cdr command))
                       '("podman" "exec" "cid" "python3" "-m" "pdb"
                         "/workspaces/p/run.py")))))))

(ert-deftest mega-debug-file-names-from-a-container-become-the-files-you-edit ()
  (mega-debug-test--with-tools nil
    (let ((mega-exec-context-functions (list (mega-debug-test--container dir)))
          (default-directory dir))
      (should (equal (mega-debug--to-host '("/workspaces/p/src/main.c"))
                     (list (expand-file-name "src/main.c" dir))))
      (should (equal (mega-debug--to-host '("main.c")) '("main.c"))))
    ;; Outside a container nothing is translated.
    (let ((default-directory dir))
      (should (equal (mega-debug--to-host '("/workspaces/p/src/main.c"))
                     '("/workspaces/p/src/main.c"))))
    (require 'gud)
    (should (advice-member-p #'mega-debug--to-host 'gud-find-file))))

;;;; Starting

(defmacro mega-debug-test--recording-starts (&rest body)
  "Run BODY with the debugger front ends replaced by a recorder.
STARTED becomes (FUNCTION COMMAND-LINE DIRECTORY) when one is called."
  (declare (indent 0))
  `(let (started)
     (cl-letf (((symbol-function 'gdb)
                (lambda (line) (setq started (list 'gdb line default-directory))))
               ((symbol-function 'pdb)
                (lambda (line) (setq started (list 'pdb line default-directory)))))
       ,@body)))

(ert-deftest mega-debug-starts-the-project-binary-without-asking ()
  (mega-debug-test--with-tools '("gdb" "rust-gdb")
    (mega-test-write (expand-file-name "Cargo.toml" dir) "[package]" "name = \"emu\"")
    (mega-test-write (expand-file-name "target/debug/emu" dir) "")
    (mega-test-write (expand-file-name ".git/HEAD" dir) "ref: refs/heads/main")
    (mega-debug-test--recording-starts
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) (error "Asked which program"))))
        (let ((default-directory (expand-file-name "src/" dir)))
          (make-directory default-directory t)
          (with-temp-buffer (mega-debug))))
      (should (eq (car started) 'gdb))
      (should (equal (split-string-and-unquote (cadr started))
                     (list "rust-gdb" "-i=mi" (expand-file-name "target/debug/emu" dir))))
      ;; From the root of the project, wherever you were in it.
      (should (equal (nth 2 started) dir)))))

(ert-deftest mega-debug-asks-when-it-cannot-tell-and-when-told-to ()
  (mega-debug-test--with-tools '("gdb")
    (let ((program (mega-test-write (expand-file-name "build/app" dir) ""))
          (asked 0)
          (default-directory dir))
      (mega-debug-test--recording-starts
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) (setq asked (1+ asked)) program)))
          (with-temp-buffer (mega-debug))
          (should (= asked 1))
          (should (equal (split-string-and-unquote (cadr started))
                         (list "gdb" "-i=mi" program)))
          ;; The second time it knows...
          (with-temp-buffer (mega-debug))
          (should (= asked 1))
          ;; ...unless you want to choose again.
          (with-temp-buffer (mega-debug t))
          (should (= asked 2)))))))

(ert-deftest mega-debug-refuses-a-project-that-is-not-trusted ()
  (mega-debug-test--with-tools '("gdb")
    (let ((program (mega-test-write (expand-file-name "build/app" dir) "")))
      (setq mega-trust--decisions nil)
      (delete-file mega-trust-file)
      (mega-debug-test--recording-starts
        ;; Were the check missing, this is what would let a debugger start;
        ;; the test must then fail, not wait at a prompt.
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) program)))
          (let ((default-directory dir))
            (should-error (with-temp-buffer (mega-debug)) :type 'user-error)))
        (should-not started)))))

(ert-deftest mega-debug-says-what-is-missing ()
  (mega-debug-test--with-tools nil
    (let* ((default-directory dir)
           (err (should-error (with-temp-buffer (mega-debug)) :type 'user-error)))
      (should (string-match-p "lldb, gdb" (error-message-string err))))))

;;;; The keys

(ert-deftest mega-debug-keys-need-a-running-debugger ()
  (let ((gud-comint-buffer nil))
    (should-not (mega-debug-running-p))
    (dolist (command '(mega-debug-break mega-debug-next mega-debug-continue
                       mega-debug-quit))
      (should-error (funcall command) :type 'user-error))))

(ert-deftest mega-debug-keys-run-the-debuggers-own-commands ()
  (with-temp-buffer
    (let* ((process (start-process "mega-debug-test" (current-buffer) "cat"))
           (gud-comint-buffer (current-buffer))
           (calls nil))
      (set-process-query-on-exit-flag process nil)
      (unwind-protect
          (cl-letf (((symbol-function 'gud-next)
                     (lambda (argument) (push (list 'next argument) calls)))
                    ((symbol-function 'gud-break)
                     (lambda (argument) (push (list 'break argument) calls))))
            (should (mega-debug-running-p))
            (mega-debug-next)
            (mega-debug-next 3)
            (mega-debug-break)
            (should (equal (reverse calls) '((next 1) (next 3) (break 1))))
            ;; Not every debugger has every command.
            (cl-letf (((symbol-function 'gud-until) nil))
              (should-error (mega-debug-until) :type 'user-error)))
        (delete-process process)))))

(ert-deftest mega-debug-run-sets-the-program-going-whatever-the-debugger ()
  (with-temp-buffer
    (let* ((process (start-process "mega-debug-test" (current-buffer) "cat"))
           (gud-comint-buffer (current-buffer))
           (calls nil))
      (set-process-query-on-exit-flag process nil)
      (unwind-protect
          (cl-letf (((symbol-function 'gud-run) (lambda (_) (push 'run calls)))
                    ((symbol-function 'gud-cont) (lambda (_) (push 'continue calls))))
            (mega-debug-run)
            (should (equal calls '(run)))
            ;; pdb has no "run": its program is already waiting on line one.
            (cl-letf (((symbol-function 'gud-run) nil))
              (mega-debug-run))
            (should (equal calls '(continue run))))
        (delete-process process)))))

(ert-deftest mega-debug-stepping-keys-repeat ()
  (dolist (command '(mega-debug-next mega-debug-step mega-debug-finish
                     mega-debug-continue mega-debug-up mega-debug-down))
    (should (eq (get command 'repeat-map) 'mega-debug-repeat-map)))
  ;; Setting a breakpoint does not: the next key is more likely text.
  (should-not (get 'mega-debug-break 'repeat-map)))

;;;; Privacy

(ert-deftest mega-debug-gdb-fetches-nothing-from-the-network ()
  (require 'gdb-mi)
  (should-not gdb-debuginfod-enable-setting))

;;;; A real session

(ert-deftest mega-debug-a-real-pdb-session-steps-through-a-file ()
  (skip-unless (executable-find "python3"))
  (mega-test-with-directory dir
    (let* ((mega--exe-cache (make-hash-table :test #'equal))
           (mega-trust-file (expand-file-name "trusted.eld" dir))
           (mega-trust--decisions nil)
           (mega-debug--targets nil)
           (script (mega-test-write (expand-file-name "run.py" dir)
                                    "x = 1" "y = x + 1" "print(y)" ""))
           (inhibit-message t)
           (frame (lambda () (or gud-last-frame gud-last-last-frame))))
      (mega-trust--record dir t)
      (save-window-excursion
        (mega-test-visiting buffer script
          (unwind-protect
              (progn
                (mega-debug)
                (should (mega-debug-running-p))
                ;; pdb stops on the first line and says where.
                (should (mega-test-wait-for
                         (lambda () (equal (funcall frame) (cons script 1))) 20))
                (with-current-buffer buffer (mega-debug-next))
                (should (mega-test-wait-for
                         (lambda () (equal (funcall frame) (cons script 2))) 20))
                (cl-letf (((symbol-function 'y-or-n-p) #'always))
                  (mega-debug-quit))
                (should-not (mega-debug-running-p)))
            (when (and (bound-and-true-p gud-comint-buffer)
                       (buffer-live-p gud-comint-buffer))
              (when-let* ((process (get-buffer-process gud-comint-buffer)))
                (set-process-query-on-exit-flag process nil))
              (kill-buffer gud-comint-buffer))))))))

(provide 'mega-debug-test)
;;; mega-debug-test.el ends here
