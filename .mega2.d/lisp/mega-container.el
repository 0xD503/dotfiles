;;; mega-container.el --- Dev Containers  -*- lexical-binding: t; -*-

;;; Commentary:

;; A project with a devcontainer.json says which container its tools live
;; in.  `C-c k u' starts that container, or joins it if it is already
;; running, and from then on the project's language server, tasks, formatter
;; and debugger run inside it.  Your files stay where they are: Emacs edits
;; them on the host, as always, and only the tools move.
;;
;;   C-c k u   up: start or join the project's container
;;   C-c k d   detach: go back to the tools of this machine
;;   C-c k s   a shell inside the container
;;   C-c k i   what the container is and what runs in it
;;   C-c k x   stop the container, or give up starting it
;;   C-c k r   rebuild it
;;
;; Starting can take minutes: an image is fetched, dependencies are
;; installed.  It happens in the background.  A window shows each command
;; and what it prints, Emacs stays yours meanwhile, and nothing is cut short
;; by a time limit; `C-c k x' gives up.
;;
;; How the container gets made:
;;
;; * If the official `devcontainer' command is installed, MEGA hands the job
;;   to it.  It understands the whole specification.
;;
;; * Otherwise MEGA does it itself with podman or docker, for the part of the
;;   specification that needs nothing else: an image, mounts, environment,
;;   run arguments, users, ports and the lifecycle commands.  A file that
;;   asks for more is refused, naming what it asked for, rather than
;;   half-started: that goes for what needs the official command (an image
;;   built from a Dockerfile, Features, Compose) and for anything MEGA does
;;   not know, since a setting it would silently ignore might be the one
;;   that mattered.
;;
;; Safety and security:
;;
;; * A devcontainer.json can name commands to run, one of them on this
;;   machine before the container exists, and directories of this machine to
;;   hand to the container.  MEGA shows all of it, as it will really be
;;   passed on, and asks, once per version of the file and of the files it
;;   names: change any of them and it asks again.  The project must be
;;   trusted as well (mega-trust.el).
;;
;; * Stopping or rebuilding a container asks first.  Nothing here deletes a
;;   volume.
;;
;; A file that exists only inside the container, such as a dependency's
;; source, opens through Emacs's own container support (TRAMP).

;;; Code:

(require 'mega-lib)
(require 'mega-exec)
(require 'mega-trust)
(require 'mega-project)
(require 'subr-x)
(require 'cl-lib)

(declare-function make-term "term")
(declare-function term-char-mode "term")

(defvar compilation-parse-errors-filename-function)

(defcustom mega-container-engine 'auto
  "The program that runs containers: `auto', \"podman\" or \"docker\".
`auto' takes podman if it is installed, else docker."
  :type '(choice (const auto) string) :group 'mega)

(defconst mega-container-approved-file (mega-state "containers-approved.eld")
  "Which devcontainer.json files, in which version, you agreed to run.")

(defconst mega-container-log-buffer "*mega-container*"
  "The buffer that shows a container being started, and what is asked first.")

(defvar mega-container--attached nil
  "The containers in use: an alist of (ROOT . PLIST).
PLIST has :id, :engine, :user, :folder (the workspace inside), :name and
:env (extra environment for what runs inside, a list of \"K=V\").")

(defvar mega-container--starting nil
  "The containers being started: an alist of (ROOT . PROCESS).
PROCESS is the step that is running now.")

(defvar mega-container--found (make-hash-table :test #'equal)
  "Which programs exist in which container: (ID . PROGRAM) to t or `no'.")

(add-hook 'mega-forget-functions (lambda () (clrhash mega-container--found)))

;;;; Reading devcontainer.json

(defun mega-container-strip-comments (text)
  "Return TEXT, JSON with comments and trailing commas, as plain JSON.
devcontainer.json allows // and /* */ comments and a comma before a
closing bracket; the JSON reader allows neither."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (pending-comma)
      (while (not (eobp))
        (let ((char (char-after)))
          (cond
           ((eq char ?\")
            (setq pending-comma nil)
            (forward-char 1)
            (while (and (not (eobp)) (not (eq (char-after) ?\")))
              (forward-char (if (eq (char-after) ?\\) 2 1)))
            (unless (eobp) (forward-char 1)))
           ((looking-at "//")
            (delete-region (point) (line-end-position)))
           ((looking-at "/\\*")
            (delete-region (point) (or (save-excursion (search-forward "*/" nil t))
                                       (point-max))))
           ((eq char ?,)
            (setq pending-comma (point))
            (forward-char 1))
           ((memq char '(?\] ?\}))
            (when pending-comma
              (save-excursion (goto-char pending-comma) (delete-char 1))
              (backward-char 1))
            (setq pending-comma nil)
            (forward-char 1))
           ((memq char '(?\s ?\t ?\n ?\r))
            (forward-char 1))
           (t (setq pending-comma nil)
              (forward-char 1))))))
    (buffer-string)))

(defun mega-container-read (file)
  "Return the contents of the devcontainer.json FILE as an alist.
Arrays become lists, false becomes `:false', null becomes nil."
  (json-parse-string
   (mega-container-strip-comments
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string)))
   :object-type 'alist :array-type 'list :null-object nil :false-object :false))

(defun mega-container-config-file (root)
  "Return the devcontainer.json of the project at ROOT, or nil."
  (seq-find #'file-readable-p
            (append
             (list (expand-file-name ".devcontainer/devcontainer.json" root)
                   (expand-file-name ".devcontainer.json" root))
             (and (file-directory-p (expand-file-name ".devcontainer" root))
                  (sort (file-expand-wildcards
                         (expand-file-name ".devcontainer/*/devcontainer.json" root))
                        #'string<)))))

;;;; From the file to a plan
;;
;; Every key of a devcontainer.json falls into one of four sets.  Which set
;; decides what MEGA does with it, and nothing is left to chance: a key in
;; none of the first three is in the fourth.

(defconst mega-container-handled-keys
  '(name image workspaceFolder workspaceMount mounts runArgs capAdd securityOpt
    privileged init containerEnv remoteEnv containerUser remoteUser forwardPorts
    initializeCommand onCreateCommand updateContentCommand postCreateCommand
    postStartCommand postAttachCommand)
  "What MEGA acts on itself.")

(defconst mega-container-harmless-keys
  '($schema customizations shutdownAction hostRequirements waitFor userEnvProbe
    portsAttributes otherPortsAttributes updateRemoteUserUID overrideCommand)
  "What MEGA does not act on and need not: settings for other editors, or
about things MEGA does not do.")

(defconst mega-container-unsupported-keys
  '(build dockerFile context features overrideFeatureInstallOrder
    dockerComposeFile service runServices appPort)
  "What MEGA cannot do without the official devcontainer command.")

(defun mega-container--substitute (value root folder)
  "Expand the ${...} variables of the specification in VALUE.
ROOT is the project on this machine, FOLDER its place in the container.
VALUE may be a string, a list or an alist; anything else is returned.
${containerEnv:...} is left for when the container exists; see
`mega-container--resolve-environment'."
  (cond
   ((stringp value)
    (replace-regexp-in-string
     "\\${\\([^}]+\\)}"
     (lambda (match)
       ;; The caller replaces the match once this returns, so its match data
       ;; must survive anything done in here.
       (save-match-data
        (let ((name (match-string 1 match)))
         (pcase name
           ("localWorkspaceFolder" (directory-file-name root))
           ("localWorkspaceFolderBasename"
            (file-name-nondirectory (directory-file-name root)))
           ("containerWorkspaceFolder" folder)
           ("containerWorkspaceFolderBasename" (file-name-nondirectory folder))
           ("devcontainerId" (substring (secure-hash 'sha256 root) 0 24))
           ((pred (string-prefix-p "localEnv:"))
            (let ((parts (split-string (substring name 9) ":")))
              (or (getenv (car parts)) (cadr parts) "")))
           (_ match)))))
     value t t))
   ((consp value)
    (cons (mega-container--substitute (car value) root folder)
          (mega-container--substitute (cdr value) root folder)))
   (t value)))

(defun mega-container--mount (mount)
  "MOUNT from devcontainer.json as the container program takes it, or nil.
The specification allows a string, passed on as it is, or an object
with source, target and type."
  (cond ((stringp mount) mount)
        ((and (consp mount) (alist-get 'target mount))
         (string-join
          (delq nil
                (list (format "type=%s" (or (alist-get 'type mount) "volume"))
                      (and (alist-get 'source mount)
                           (format "source=%s" (alist-get 'source mount)))
                      (format "target=%s" (alist-get 'target mount))))
          ","))))

(defun mega-container--port (port)
  "PORT from `forwardPorts' as a number in a string, or nil.
\"host:port\" names a service of a Compose file, which MEGA does not do."
  (cond ((integerp port) (number-to-string port))
        ((and (stringp port) (string-match-p "\\`[0-9]+\\'" port)) port)))

(defun mega-container-referenced-files (config directory)
  "The files CONFIG, a parsed devcontainer.json in DIRECTORY, builds from.
What they say runs when the container is made, so agreeing to the one
file is agreeing to these as well."
  (let* ((build (alist-get 'build config))
         (compose (alist-get 'dockerComposeFile config))
         (names (append (list (alist-get 'dockerFile config)
                              (and (consp build) (alist-get 'dockerfile build)))
                        (if (stringp compose) (list compose) compose))))
    (seq-filter #'file-readable-p
                (mapcar (lambda (name) (expand-file-name name directory))
                        (seq-filter #'stringp names)))))

(defun mega-container-plan (config root)
  "Turn CONFIG, a parsed devcontainer.json, into a plan for the project at ROOT.
The plan is a plist; see the keys it is built from below.  :unsupported
lists, as strings, what the file asks for that MEGA cannot do by itself,
and :unknown the keys it does not know at all."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (base (file-name-nondirectory (directory-file-name root)))
         (folder (or (alist-get 'workspaceFolder config)
                     (concat "/workspaces/" base)))
         (folder (mega-container--substitute folder root folder))
         (get (lambda (key)
                (mega-container--substitute (alist-get key config) root folder)))
         (list-of (lambda (value) (if (listp value) value (list value))))
         (mounts (funcall list-of (funcall get 'mounts)))
         (ports (funcall list-of (funcall get 'forwardPorts)))
         (pairs (lambda (key)
                  (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
                          (funcall get key)))))
    (list :name (or (funcall get 'name) base)
          :root root
          :image (funcall get 'image)
          :folder folder
          :workspace-mount (or (funcall get 'workspaceMount)
                               (format "type=bind,source=%s,target=%s"
                                       (directory-file-name root) folder))
          :mounts (delq nil (mapcar #'mega-container--mount mounts))
          :run-args (funcall get 'runArgs)
          :cap-add (funcall get 'capAdd)
          :security-opt (funcall get 'securityOpt)
          :privileged (eq (alist-get 'privileged config) t)
          :init (eq (alist-get 'init config) t)
          :env (funcall pairs 'containerEnv)
          :remote-env (funcall pairs 'remoteEnv)
          :container-user (funcall get 'containerUser)
          :user (or (funcall get 'remoteUser) (funcall get 'containerUser))
          :ports (delq nil (mapcar #'mega-container--port ports))
          ;; One command, kept as a list of one like the others.
          :initialize (delq nil (list (funcall get 'initializeCommand)))
          :created (delq nil (mapcar get '(onCreateCommand updateContentCommand
                                           postCreateCommand)))
          :started (delq nil (mapcar get '(postStartCommand)))
          :attached (delq nil (mapcar get '(postAttachCommand)))
          :unsupported
          (append
           (mapcar #'symbol-name
                   (seq-filter (lambda (key) (assq key config))
                               mega-container-unsupported-keys))
           (mapcar (lambda (mount) (format "mounts entry %S" mount))
                   (seq-remove #'mega-container--mount mounts))
           (mapcar (lambda (port) (format "forwardPorts entry %S" port))
                   (seq-remove #'mega-container--port ports)))
          :unknown
          (mapcar #'symbol-name
                  (seq-remove (lambda (key)
                                (or (memq key mega-container-handled-keys)
                                    (memq key mega-container-harmless-keys)
                                    (memq key mega-container-unsupported-keys)))
                              (mapcar #'car config))))))

(defun mega-container-run-arguments (plan)
  "The arguments of `ENGINE run' that create the container PLAN describes."
  (append
   (list "run" "--detach"
         "--label" (concat "devcontainer.local_folder="
                           (directory-file-name (plist-get plan :root)))
         "--mount" (plist-get plan :workspace-mount)
         "--workdir" (plist-get plan :folder))
   (mapcan (lambda (mount) (list "--mount" mount)) (plist-get plan :mounts))
   (mapcan (lambda (cap) (list "--cap-add" cap)) (plist-get plan :cap-add))
   (mapcan (lambda (option) (list "--security-opt" option))
           (plist-get plan :security-opt))
   (and (plist-get plan :privileged) (list "--privileged"))
   (and (plist-get plan :init) (list "--init"))
   (mapcan (lambda (env) (list "--env" env)) (plist-get plan :env))
   (mapcan (lambda (port) (list "--publish" (format "%s:%s" port port)))
           (plist-get plan :ports))
   (when-let* ((user (plist-get plan :container-user)))
     (list "--user" user))
   (plist-get plan :run-args)
   ;; Keep the container alive, as every devcontainer tool does: its real
   ;; work is what gets run inside it afterwards.
   (list (plist-get plan :image)
         "/bin/sh" "-c" "trap 'exit 0' TERM; while :; do sleep 3600 & wait $!; done")))

(defun mega-container--command (command)
  "COMMAND from devcontainer.json as an argument list.
The specification lets a command be a string, which a shell runs, or a
list of words, which runs directly."
  (cond ((stringp command) (list "/bin/sh" "-c" command))
        ((and (listp command) (seq-every-p #'stringp command)) command)))

(defun mega-container--commands (value)
  "Every command in VALUE, which may also be an object of named commands."
  (if (and (consp value) (consp (car value)) (symbolp (caar value)))
      (delq nil (mapcar (lambda (pair) (mega-container--command (cdr pair))) value))
    (delq nil (list (mega-container--command value)))))

(defun mega-container--all-commands (plan key)
  "The commands PLAN holds under KEY, each an argument list."
  (mapcan #'mega-container--commands (copy-sequence (plist-get plan key))))

;;;; Agreeing to run what the file says

(defun mega-container--approved ()
  "The recorded approvals: an alist of (FILE . HASH)."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents mega-container-approved-file)
      (let ((data (read (current-buffer))))
        (and (listp data)
             (seq-every-p (lambda (entry) (and (consp entry) (stringp (car entry))
                                               (stringp (cdr entry))))
                          data)
             data)))))

(defun mega-container--hash (file &optional others)
  "The fingerprint of FILE's contents, and of those of OTHERS with it."
  (secure-hash
   'sha256
   (mapconcat (lambda (each)
                (with-temp-buffer
                  (insert-file-contents-literally each)
                  (concat (file-name-nondirectory each) ":"
                          (secure-hash 'sha256 (current-buffer)))))
              (cons file others) "\n")))

(defun mega-container-summary (plan &optional cli others)
  "Describe, for the user, everything PLAN would run and mount.
CLI non-nil means the official command will make the container, and
OTHERS are the files it builds from besides the devcontainer.json."
  (let ((lines nil))
    (cl-flet ((say (line) (push line lines))
              (add (label values)
                (dolist (value values)
                  (push (format "  %-14s %s" label value) lines)
                  (setq label ""))))
      (say (format "Container for %s" (abbreviate-file-name (plist-get plan :root))))
      (say "")
      (add "image" (list (or (plist-get plan :image) "(none named)")))
      ;; As it is passed on, not as it is usually: a file may mount
      ;; something quite different from the project in its place.
      (add "workspace" (list (plist-get plan :workspace-mount)))
      (add "works in" (list (plist-get plan :folder)))
      (when (plist-get plan :privileged)
        (say "")
        (say "  PRIVILEGED: the container may do anything on this machine that you may."))
      (when-let* ((initialize (mega-container--all-commands plan :initialize)))
        (say "")
        (say "  RUNS ON THIS MACHINE, before the container exists:")
        (add "" (mapcar (lambda (command) (string-join command " ")) initialize))
        (say ""))
      (add "runs inside" (mapcar (lambda (command) (string-join command " "))
                                 (append (mega-container--all-commands plan :created)
                                         (mega-container--all-commands plan :started)
                                         (mega-container--all-commands plan :attached))))
      (add "mounts" (plist-get plan :mounts))
      (add "run arguments" (plist-get plan :run-args))
      (add "capabilities" (plist-get plan :cap-add))
      (add "security" (plist-get plan :security-opt))
      (add "environment" (append (plist-get plan :env) (plist-get plan :remote-env)))
      (add "ports" (plist-get plan :ports))
      (add "user" (delq nil (list (plist-get plan :user))))
      (when-let* ((beyond (append (plist-get plan :unsupported) (plist-get plan :unknown))))
        (say "")
        (say (if cli
                 "  ALSO IN THE FILE, and acted on by the devcontainer command, not shown here:"
               "  ALSO IN THE FILE, which MEGA cannot do by itself:"))
        (add "" beyond))
      (when others
        (say "")
        (say "  BUILT FROM these files as well; what they say runs too:")
        (add "" (mapcar #'abbreviate-file-name others))))
    (string-join (nreverse lines) "\n")))

(defun mega-container--show (text)
  "Show TEXT in the container buffer, replacing what was there."
  (with-current-buffer (get-buffer-create mega-container-log-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text "\n"))
    (special-mode)
    (goto-char (point-min))
    (current-buffer)))

(defun mega-container-approve (file plan &optional cli)
  "Return non-nil if the user agrees to run what FILE, parsed as PLAN, says.
Asked once per version of the file and of the files it builds from.  CLI
is as in `mega-container-summary'.  A batch Emacs is never asked, and
never agrees."
  (let* ((others (mega-container-referenced-files
                  (mega-container-read file) (file-name-directory file)))
         (hash (mega-container--hash file others))
         (approved (mega-container--approved)))
    (or (equal (cdr (assoc file approved)) hash)
        (and (not noninteractive)
             (save-window-excursion
               (pop-to-buffer (mega-container--show
                               (mega-container-summary plan cli others)))
               (yes-or-no-p (format "Start this container, as %s describes? "
                                    (abbreviate-file-name file))))
             (let ((temporary (concat mega-container-approved-file ".new")))
               (setf (alist-get file approved nil nil #'equal) hash)
               (with-temp-file temporary
                 (prin1 approved (current-buffer)))
               (rename-file temporary mega-container-approved-file t)
               t)))))

;;;; Talking to the engine

(defun mega-container-engine ()
  "The container program to use, or nil if none is installed."
  (if (stringp mega-container-engine)
      (and (mega-exe-p mega-container-engine) mega-container-engine)
    (seq-find #'mega-exe-p '("podman" "docker"))))

(defun mega-container--engine (engine args &rest options)
  "Run ENGINE with ARGS on this machine; return the result of `mega-exec-run'.
OPTIONS are passed on.  For a question that is answered at once; what
may take long goes through `mega-container--step'."
  (apply #'mega-exec-run engine args :here t options))

(defun mega-container--ok (engine args &rest options)
  "Run ENGINE with ARGS and return its trimmed output; signal if it fails."
  (let ((result (apply #'mega-container--engine engine args options)))
    (unless (eql (plist-get result :status) 0)
      (user-error "`%s %s' failed: %s" engine (string-join args " ")
                  (string-trim (concat (plist-get result :error)
                                       (plist-get result :output)))))
    (string-trim (plist-get result :output))))

(defun mega-container-find-existing (engine root)
  "Return (ID . STATE) of the container that belongs to ROOT, or nil.
It is found by the label every devcontainer tool puts on its containers,
so one that another editor started is found too."
  (let ((line (car (split-string
                    (mega-container--ok
                     engine
                     ;; Full ids, so that one found here equals the one
                     ;; `run' printed when it was created.
                     (list "ps" "--all" "--no-trunc" "--filter"
                           (concat "label=devcontainer.local_folder="
                                   (directory-file-name root))
                           "--format" "{{.ID}} {{.State}}")
                     :timeout 30)
                    "\n" t))))
    (when (and line (string-match "\\`\\([^ ]+\\) +\\(.*\\)\\'" line))
      (cons (match-string 1 line) (downcase (match-string 2 line))))))

(defun mega-container--exec-arguments (attached directory)
  "The `ENGINE exec' arguments, before the program, for ATTACHED and DIRECTORY.
What the caller asks for through `mega-exec-environment' and
`mega-exec-terminal' is passed on to the container program."
  (append (list "exec" "--interactive")
          (and mega-exec-terminal (list "--tty"))
          (when-let* ((user (plist-get attached :user)))
            (list "--user" user))
          (list "--workdir" directory)
          (mapcan (lambda (env) (list "--env" env))
                  (append (plist-get attached :env) mega-exec-environment))
          (list (plist-get attached :id))))

;;;; Starting, one step after another, in the background

(defun mega-container--log (text)
  "Add TEXT to the container buffer, keeping its windows at the end."
  (with-current-buffer (get-buffer-create mega-container-log-buffer)
    (let ((inhibit-read-only t)
          (follow (seq-filter (lambda (window) (= (window-point window) (point-max)))
                              (get-buffer-window-list nil nil t))))
      (save-excursion
        (goto-char (point-max))
        (insert text))
      (dolist (window follow)
        (set-window-point window (point-max))))))

(defun mega-container--give-up (root reason)
  "Stop starting the container of ROOT, and say REASON."
  (setq mega-container--starting (assoc-delete-all root mega-container--starting))
  (mega-container--log (format "\n%s\n" reason))
  (message "%s (see %s)" reason mega-container-log-buffer))

(defun mega-container--step (root description program args directory then)
  "Run PROGRAM with ARGS in DIRECTORY as one step of starting ROOT's container.
DESCRIPTION is what the log shows for it.  THEN is called with what the
program printed, if it succeeded; otherwise the start is given up.  The
program runs on this machine and is not waited for."
  (when (assoc root mega-container--starting)
    (mega-container--log (format "\n$ %s\n" description))
    (let ((printed ""))
      (setf (alist-get root mega-container--starting nil nil #'equal)
            (mega-exec-open
             program args
             :here t :directory directory :name "mega-container" :coding 'utf-8-unix
             :filter (lambda (_process text)
                       (setq printed (concat printed text))
                       (mega-container--log text))
             :errors (lambda (_process text) (mega-container--log text))
             :sentinel
             (lambda (process)
               (cond
                ;; Given up on meanwhile, with `C-c k x': say nothing more.
                ((not (eq process (cdr (assoc root mega-container--starting)))))
                ((and (eq (process-status process) 'exit)
                      (eql (process-exit-status process) 0))
                 (funcall then printed))
                (t (mega-container--give-up
                    root (format "Not started: `%s' failed" description))))))))))

(defun mega-container--steps (root steps then)
  "Run STEPS for ROOT's container in order, then call THEN.
Each step is (DESCRIPTION PROGRAM ARGS DIRECTORY)."
  (if (null steps)
      (funcall then)
    (pcase-let ((`(,description ,program ,args ,directory) (car steps)))
      (mega-container--step root description program args directory
                            (lambda (_printed)
                              (mega-container--steps root (cdr steps) then))))))

(defun mega-container--inside (attached commands)
  "Steps that run each of COMMANDS, argument lists, in the container ATTACHED."
  (mapcar (lambda (command)
            (list (concat "in the container: " (string-join command " "))
                  (plist-get attached :engine)
                  (append (mega-container--exec-arguments
                           attached (plist-get attached :folder))
                          command)
                  nil))
          commands))

(defun mega-container--resolve-environment (attached then)
  "Fill in ${containerEnv:NAME} in the environment of ATTACHED, then call THEN.
THEN gets ATTACHED with the values the container really has, which are
only known once it exists: its environment is read from it, once."
  (let ((root (plist-get attached :root))
        (needed (seq-some (lambda (setting) (string-search "${containerEnv:" setting))
                          (plist-get attached :env))))
    (if (not needed)
        (funcall then attached)
      (mega-container--step
       root "read the container's environment"
       (plist-get attached :engine)
       (list "exec" (plist-get attached :id) "env")
       nil
       (lambda (printed)
         (let ((inside (mapcar (lambda (line)
                                 (let ((at (string-search "=" line)))
                                   (and at (cons (substring line 0 at)
                                                 (substring line (1+ at))))))
                               (split-string printed "\n" t))))
           (funcall
            then
            (plist-put
             (copy-sequence attached) :env
             (mapcar (lambda (setting)
                       (replace-regexp-in-string
                        "\\${containerEnv:\\([^}:]+\\)\\(?::\\([^}]*\\)\\)?}"
                        (lambda (match)
                          (save-match-data
                            (string-match "containerEnv:\\([^}:]+\\)\\(?::\\([^}]*\\)\\)?}" match)
                            (or (cdr (assoc (match-string 1 match) inside))
                                (match-string 2 match)
                                "")))
                        setting t t))
                     (plist-get attached :env))))))))))

(defun mega-container--attach (attached)
  "Make ATTACHED the container the tools of its project run in."
  (mega-container--resolve-environment
   attached
   (lambda (attached)
     (let ((root (plist-get attached :root)))
       (setq mega-container--starting (assoc-delete-all root mega-container--starting))
       (setf (alist-get root mega-container--attached nil nil #'equal) attached)
       (let ((say (format "Tools of %s now run in its container (%s)"
                          (abbreviate-file-name root)
                          (substring (plist-get attached :id) 0
                                     (min 12 (length (plist-get attached :id)))))))
         (mega-container--log (format "\n%s\n" say))
         (message "%s" say)
         (force-mode-line-update t))))))

(defun mega-container--refuse-what-it-cannot-do (plan)
  "Signal an error if PLAN asks for what MEGA cannot do by itself."
  (when-let* ((unsupported (plist-get plan :unsupported)))
    (user-error "This devcontainer.json needs the official `devcontainer' command: MEGA alone cannot do %s"
                (string-join unsupported ", ")))
  (when-let* ((unknown (plist-get plan :unknown)))
    (user-error "This devcontainer.json has settings MEGA does not know, and will not guess at: %s"
                (string-join unknown ", ")))
  (unless (plist-get plan :image)
    (user-error "This devcontainer.json names no image")))

(defun mega-container--up-native (engine plan)
  "Start or join the container of PLAN with ENGINE, in the background."
  (let* ((root (plist-get plan :root))
         (existing (mega-container-find-existing engine root))
         (running (and existing (string-prefix-p "running" (cdr existing))))
         (attached (list :root root
                         :engine engine
                         :id (car existing)
                         :user (plist-get plan :user)
                         :folder (plist-get plan :folder)
                         :name (plist-get plan :name)
                         :env (plist-get plan :remote-env)))
         (inside (lambda (attached key)
                   (mega-container--inside attached
                                           (mega-container--all-commands plan key))))
         (finish (lambda (attached keys)
                   ;; First, what the container's own environment holds:
                   ;; the commands below run with the environment the file
                   ;; asks for, and a PATH built on the container's PATH
                   ;; finds nothing until that is filled in.
                   (mega-container--resolve-environment
                    attached
                    (lambda (attached)
                      (mega-container--steps
                       root
                       (mapcan (lambda (key) (funcall inside attached key)) keys)
                       (lambda () (mega-container--attach attached))))))))
    (cond
     ;; Already there and running: join it.
     (running (funcall finish attached '(:attached)))
     ;; There, but stopped.
     (existing
      (mega-container--step
       root (format "%s start" engine) engine (list "start" (car existing)) nil
       (lambda (_printed) (funcall finish attached '(:started :attached)))))
     ;; Not there: what the file says to do on this machine first, then make it.
     (t
      (mega-container--steps
       root
       (mapcar (lambda (command)
                 (list (concat "on this machine: " (string-join command " "))
                       (car command) (cdr command) root))
               (mega-container--all-commands plan :initialize))
       (lambda ()
         (mega-container--step
          root (format "%s run %s" engine (plist-get plan :image))
          engine (mega-container-run-arguments plan) nil
          (lambda (printed)
            ;; The id is the last thing it prints, after any progress.
            (let ((id (car (last (split-string printed "[ \t\n\r]+" t)))))
              (if (not id)
                  (mega-container--give-up root "Not started: no container was made")
                (funcall finish (plist-put (copy-sequence attached) :id id)
                         '(:created :started :attached))))))))))))

(defun mega-container--up-cli (engine plan file)
  "Start the container of PLAN, described in FILE, with the official command."
  (let ((root (plist-get plan :root)))
    (mega-container--step
     root "devcontainer up" "devcontainer"
     (list "up" "--workspace-folder" (directory-file-name root)
           "--config" file "--docker-path" engine)
     root
     (lambda (printed)
       (let* ((line (car (last (split-string printed "\n" t))))
              (answer (ignore-errors
                        (json-parse-string (or line "") :object-type 'alist))))
         (if (not (equal (alist-get 'outcome answer) "success"))
             (mega-container--give-up
              root (format "Not started: %s"
                           (or (alist-get 'message answer)
                               "the devcontainer command did not say it succeeded")))
           (mega-container--attach
            (list :root root
                  :engine engine
                  :id (alist-get 'containerId answer)
                  :user (or (alist-get 'remoteUser answer) (plist-get plan :user))
                  :folder (or (alist-get 'remoteWorkspaceFolder answer)
                              (plist-get plan :folder))
                  :name (plist-get plan :name)
                  :env (plist-get plan :remote-env)))))))))

;;;; Being attached: where tools run, and what files are called there

(defun mega-container-attached (&optional directory)
  "Return (ROOT . PLIST) of the container in use for DIRECTORY, or nil."
  (let ((directory (expand-file-name (or directory default-directory))))
    (seq-find (lambda (entry) (string-prefix-p (car entry) directory))
              mega-container--attached)))

(defun mega-container-to-inside (file entry)
  "The name FILE has inside the container of ENTRY, a (ROOT . PLIST)."
  (let ((file (expand-file-name file)))
    (if (string-prefix-p (car entry) file)
        (concat (file-name-as-directory (plist-get (cdr entry) :folder))
                (substring file (length (car entry))))
      file)))

(defun mega-container-to-host (file entry)
  "The name on this machine of FILE, a name inside the container of ENTRY.
A file under the workspace is the project's own file.  Any other exists
only in the container, and gets a name Emacs can open it by."
  (let ((folder (file-name-as-directory (plist-get (cdr entry) :folder)))
        (attached (cdr entry)))
    (cond ((not (file-name-absolute-p file)) file)
          ;; The workspace itself, named without its final slash.
          ((equal (file-name-as-directory file) folder) (car entry))
          ((string-prefix-p folder file)
           (concat (car entry) (substring file (length folder))))
          (t (format "/%s:%s%s:%s"
                     (plist-get attached :engine)
                     (if-let* ((user (plist-get attached :user))) (concat user "@") "")
                     (plist-get attached :id)
                     file)))))

(defun mega-container--find (attached program)
  "Non-nil if PROGRAM exists in the container ATTACHED.
An answer is remembered; not having been able to ask is not an answer."
  (let* ((key (cons (plist-get attached :id) program))
         (known (gethash key mega-container--found)))
    (unless known
      (let ((status (plist-get
                     (mega-container--engine
                      (plist-get attached :engine)
                      (append (mega-container--exec-arguments
                               attached (plist-get attached :folder))
                              (list "/bin/sh" "-c" "command -v \"$1\"" "sh" program))
                      :timeout 20)
                     :status)))
        (setq known (pcase status (0 t) ((or 1 127) 'no)))
        (when known
          (puthash key known mega-container--found))))
    (eq known t)))

(defun mega-container-context (directory)
  "The execution context of DIRECTORY, if its project's container is in use.
This is what `mega-exec' asks; see the Commentary of mega-exec.el."
  (when-let* ((entry (mega-container-attached directory)))
    (let ((attached (cdr entry)))
      (list :kind 'container
            :name (plist-get attached :name)
            :key (plist-get attached :id)
            :wrap (lambda (program args where)
                    (append (list (plist-get attached :engine))
                            (mega-container--exec-arguments
                             attached (mega-container-to-inside where entry))
                            (cons program args)))
            :find (lambda (program) (mega-container--find attached program))
            :to-inside (lambda (file) (mega-container-to-inside file entry))
            :to-host (lambda (file) (mega-container-to-host file entry))))))

(add-hook 'mega-exec-context-functions #'mega-container-context)

(defun mega-container--modeline ()
  "Say in the modeline that this buffer's tools run in a container."
  (when-let* ((entry (and mega-container--attached (mega-container-attached))))
    (format " [box:%s]" (plist-get (cdr entry) :name))))

(add-to-list 'mode-line-misc-info '(:eval (mega-container--modeline)) t)

;;;; The language server sees the container's file names
;;
;; A server inside a container names files as the container has them.  Which
;; container, when a name comes in, depends on which server said it and not
;; on where the cursor happens to be: Emacs handles a server's messages on
;; its own time, in a buffer of no project at all.  So each server is noted
;; with its project when it is made, and while one of its messages is being
;; handled, that project is the one names are translated for.

(defvar mega-container--servers (make-hash-table :test #'eq :weakness 'key)
  "The project root each language server was started for.")

(defvar mega-container--speaking nil
  "The project root of the server whose message is being handled, if any.")

(defun mega-container--note-server (server)
  "Note which project SERVER, just made, belongs to.
For `eglot-server-initialized-hook', which runs in the project's root."
  (puthash server (file-name-as-directory (expand-file-name default-directory))
           mega-container--servers))

(defun mega-container--receive (function connection &rest arguments)
  "Call FUNCTION on CONNECTION and ARGUMENTS, knowing whose message it is.
Advice around the function that handles a message from a server."
  (let ((mega-container--speaking (or (gethash connection mega-container--servers)
                                      mega-container--speaking)))
    (apply function connection arguments)))

(defun mega-container--path-to-uri (arguments)
  "Advice: give eglot the container's name for a file of an attached project."
  (let ((path (car arguments)))
    (if-let* ((entry (and (stringp path) (mega-container-attached path))))
        (cons (mega-container-to-inside path entry) (cdr arguments))
      arguments)))

(defun mega-container--uri-to-path (path)
  "Advice: turn a file name from a server in a container into this machine's."
  (if-let* ((entry (and (stringp path)
                        (mega-container-attached
                         (or mega-container--speaking default-directory)))))
      (mega-container-to-host path entry)
    path))

(with-eval-after-load 'eglot
  (add-hook 'eglot-server-initialized-hook #'mega-container--note-server)
  (advice-add 'eglot-path-to-uri :filter-args #'mega-container--path-to-uri)
  (advice-add 'eglot-uri-to-path :filter-return #'mega-container--uri-to-path))

(with-eval-after-load 'jsonrpc
  (advice-add 'jsonrpc-connection-receive :around #'mega-container--receive))

(defun mega-container--error-file-name (file)
  "Translate FILE, named in a tool's output, from the container to this machine."
  (if-let* ((entry (mega-container-attached)))
      (mega-container-to-host file entry)
    file))

(with-eval-after-load 'compile
  (setq compilation-parse-errors-filename-function
        #'mega-container--error-file-name))

;;;; Commands

(defun mega-container--root ()
  "The project root of the current buffer, as attached containers key it."
  (mega-project-directory))

;;;###autoload
(defun mega-container-up ()
  "Start the project's dev container, or join it, and run its tools there.
What can be asked is asked now; the rest happens in the background, and
a window shows it."
  (interactive)
  (let* ((root (mega-container--root))
         (file (or (mega-container-config-file root)
                   (user-error "No devcontainer.json in %s" (abbreviate-file-name root))))
         (engine (or (mega-container-engine)
                     (user-error "Neither podman nor docker is installed")))
         (cli (and (mega-exe-p "devcontainer") t))
         (plan (mega-container-plan (mega-container-read file) root)))
    (when (assoc root mega-container--starting)
      (user-error "This project's container is being started (C-c k x gives up)"))
    (unless (mega-trust-p root t "start its dev container")
      (user-error "This project is not trusted; C-c y trusts it"))
    (unless cli
      (mega-container--refuse-what-it-cannot-do plan))
    (unless (mega-container-approve file plan cli)
      (user-error "Not started"))
    (push (cons root nil) mega-container--starting)
    (display-buffer (mega-container--show
                     (format "Starting the container of %s" (plist-get plan :name)))
                    '((display-buffer-reuse-window display-buffer-in-side-window)
                      (side . bottom) (window-height . 0.3)))
    (message "Starting the container of %s in the background..." (plist-get plan :name))
    (condition-case err
        (if cli
            (mega-container--up-cli engine plan file)
          (mega-container--up-native engine plan))
      (error
       (mega-container--give-up root (format "Not started: %s" (error-message-string err)))))))

;;;###autoload
(defun mega-container-detach ()
  "Stop using the project's container; its tools run on this machine again.
The container itself is left running."
  (interactive)
  (let ((entry (or (mega-container-attached)
                   (user-error "This project is not using a container"))))
    (setq mega-container--attached (delq entry mega-container--attached))
    (force-mode-line-update t)
    (message "Detached; the container is still running")))

;;;###autoload
(defun mega-container-stop ()
  "Stop the project's container, after asking; or give up starting it."
  (interactive)
  (if-let* ((starting (assoc (mega-container--root) mega-container--starting)))
      (let ((process (cdr starting)))
        (mega-container--give-up (car starting) "Given up starting the container")
        (when (processp process)
          (mega-exec-stop process)))
    (let* ((entry (or (mega-container-attached)
                      (user-error "This project is not using a container")))
           (attached (cdr entry)))
      (when (yes-or-no-p (format "Stop the container of %s? " (plist-get attached :name)))
        (mega-container--ok (plist-get attached :engine)
                            (list "stop" (plist-get attached :id)) :timeout 60)
        (setq mega-container--attached (delq entry mega-container--attached))
        (force-mode-line-update t)
        (message "Stopped")))))

;;;###autoload
(defun mega-container-rebuild ()
  "Remove the project's container and start a fresh one, after asking.
Volumes are kept."
  (interactive)
  (let* ((root (mega-container--root))
         (engine (or (mega-container-engine)
                     (user-error "Neither podman nor docker is installed")))
         (existing (mega-container-find-existing engine root)))
    (when (and existing
               (yes-or-no-p "Remove this project's container and start a new one? "))
      (mega-container--ok engine (list "rm" "--force" (car existing)) :timeout 60)
      (setq mega-container--attached
            (assoc-delete-all root mega-container--attached)))
    (mega-container-up)))

;;;###autoload
(defun mega-container-shell ()
  "Open a shell inside the project's container."
  (interactive)
  (let* ((entry (or (mega-container-attached)
                    (user-error "This project is not using a container; C-c k u starts it")))
         (attached (cdr entry))
         ;; The same command every other tool of the project gets, with the
         ;; user, the directory and the environment that implies, plus a
         ;; terminal.  The line handed to the shell is fixed text.
         (command (let ((mega-exec-terminal t))
                    (mega-exec-command
                     "/bin/sh"
                     '("-c" "command -v bash >/dev/null && exec bash || exec sh")
                     (car entry)))))
    (require 'term)
    (pop-to-buffer
     (apply #'make-term (format "container: %s" (plist-get attached :name))
            (car command) nil (cdr command)))
    (term-char-mode)))

;;;###autoload
(defun mega-container-info ()
  "Say which container the project is using, if any."
  (interactive)
  (cond
   ((mega-container-attached)
    (let ((attached (cdr (mega-container-attached))))
      (message "%s: %s container %s, user %s, workspace %s"
               (plist-get attached :name) (plist-get attached :engine)
               (plist-get attached :id)
               (or (plist-get attached :user) "default")
               (plist-get attached :folder))))
   ((assoc (mega-container--root) mega-container--starting)
    (message "This project's container is being started; %s shows how far it is"
             mega-container-log-buffer))
   ((mega-container-config-file (mega-container--root))
    (message "Not using a container.  This project has one: C-c k u starts it"))
   (t (message "Not using a container, and this project describes none"))))

;;;; The doctor

(defun mega-container--doctor ()
  "Insert the doctor's section about dev containers."
  (mega-doctor-heading "Dev containers")
  (let ((engine (mega-container-engine))
        (cli (mega-exe-p "devcontainer")))
    (mega-doctor-row "container program"
                     (or engine "not found: podman, docker")
                     (unless engine 'shadow))
    (mega-doctor-row "devcontainer CLI"
                     (cond (cli "found: it creates the containers")
                           (engine "not found: MEGA creates them itself, from a subset")
                           (t "not found"))
                     (unless cli 'shadow))))

(add-to-list 'mega-doctor-sections #'mega-container--doctor t)

(provide 'mega-container)
;;; mega-container.el ends here
