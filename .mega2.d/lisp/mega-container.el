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
;;   C-c k x   stop the container            C-c k r   rebuild it
;;
;; How the container gets made:
;;
;; * If the official `devcontainer' command is installed, MEGA hands the job
;;   to it.  It understands the whole specification.
;;
;; * Otherwise MEGA does it itself with podman or docker, for the part of the
;;   specification that needs nothing else: an image, mounts, environment,
;;   run arguments, users, ports and the lifecycle commands.  A file that
;;   asks for more — an image built from a Dockerfile, Features, Compose — is
;;   refused, naming what it asked for, rather than half-started.
;;
;; Safety and security:
;;
;; * A devcontainer.json can name commands to run, one of them on this
;;   machine before the container exists.  MEGA shows what the file would
;;   run and asks, once per version of the file: change the file and it asks
;;   again.  The project must be trusted as well (mega-trust.el).
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
(require 'subr-x)
(require 'cl-lib)

(declare-function mega-project-root "mega-project")
(declare-function eglot-uri-to-path "eglot")
(declare-function eglot-path-to-uri "eglot")
(declare-function make-term "term")
(declare-function term-char-mode "term")

(defvar compilation-parse-errors-filename-function)

(defcustom mega-container-engine 'auto
  "The program that runs containers: `auto', \"podman\" or \"docker\".
`auto' takes podman if it is installed, else docker."
  :type '(choice (const auto) string) :group 'mega)

(defconst mega-container-approved-file (mega-state "containers-approved.eld")
  "Which devcontainer.json files, in which version, you agreed to run.")

(defvar mega-container--attached nil
  "The containers in use: an alist of (ROOT . PLIST).
PLIST has :id, :engine, :user, :folder (the workspace inside), :name and
:env (extra environment for what runs inside, a list of \"K=V\").")

(defvar mega-container--found (make-hash-table :test #'equal)
  "Which programs exist in which container: (ID . PROGRAM) to t or `no'.")

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

(defconst mega-container-unsupported-keys
  '(build dockerFile features dockerComposeFile)
  "What MEGA cannot do without the official devcontainer command.")

(defun mega-container--substitute (value root folder)
  "Expand the ${...} variables of the specification in VALUE.
ROOT is the project on this machine, FOLDER its place in the container.
VALUE may be a string, a list or an alist; anything else is returned."
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

(defun mega-container-plan (config root)
  "Turn CONFIG, a parsed devcontainer.json, into a plan for the project at ROOT.
The plan is a plist; see the keys it is built from below.  :unsupported
lists what the file asks for that MEGA cannot do by itself."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (base (file-name-nondirectory (directory-file-name root)))
         (folder (or (alist-get 'workspaceFolder config)
                     (concat "/workspaces/" base)))
         (folder (mega-container--substitute folder root folder))
         (get (lambda (key)
                (mega-container--substitute (alist-get key config) root folder)))
         (list-of (lambda (value) (if (stringp value) (list value) value))))
    (list :name (or (funcall get 'name) base)
          :root root
          :image (funcall get 'image)
          :folder folder
          :workspace-mount (or (funcall get 'workspaceMount)
                               (format "type=bind,source=%s,target=%s"
                                       (directory-file-name root) folder))
          :mounts (seq-filter #'stringp (funcall get 'mounts))
          :run-args (funcall get 'runArgs)
          :cap-add (funcall get 'capAdd)
          :security-opt (funcall get 'securityOpt)
          :env (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
                       (funcall get 'containerEnv))
          :remote-env (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
                              (funcall get 'remoteEnv))
          :container-user (funcall get 'containerUser)
          :user (or (funcall get 'remoteUser) (funcall get 'containerUser))
          :ports (mapcar (lambda (port) (format "%s" port))
                         (funcall list-of (funcall get 'forwardPorts)))
          :initialize (funcall get 'initializeCommand)
          :created (delq nil (mapcar get '(onCreateCommand updateContentCommand
                                           postCreateCommand)))
          :started (delq nil (mapcar get '(postStartCommand)))
          :unsupported (seq-filter (lambda (key) (assq key config))
                                   mega-container-unsupported-keys))))

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

(defun mega-container--hash (file)
  "The fingerprint of FILE's contents."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun mega-container-summary (plan)
  "Describe, for the user, everything PLAN would run and mount."
  (let ((lines (list (format "Container for %s" (abbreviate-file-name (plist-get plan :root)))
                     ""
                     (format "  image          %s" (or (plist-get plan :image) "(none)"))
                     (format "  workspace      %s  ->  %s"
                             (abbreviate-file-name (plist-get plan :root))
                             (plist-get plan :folder)))))
    (cl-flet ((add (label values)
                (dolist (value values)
                  (push (format "  %-14s %s" label value) lines)
                  (setq label ""))))
      (when-let* ((initialize (mega-container--commands (plist-get plan :initialize))))
        (push "" lines)
        (push "  RUNS ON THIS MACHINE, before the container exists:" lines)
        (add "" (mapcar (lambda (command) (string-join command " ")) initialize))
        (push "" lines))
      (add "runs inside" (mapcar (lambda (command) (string-join command " "))
                                 (mapcan #'mega-container--commands
                                         (append (plist-get plan :created)
                                                 (plist-get plan :started)))))
      (add "mounts" (plist-get plan :mounts))
      (add "run arguments" (plist-get plan :run-args))
      (add "capabilities" (plist-get plan :cap-add))
      (add "security" (plist-get plan :security-opt))
      (add "environment" (append (plist-get plan :env) (plist-get plan :remote-env)))
      (add "ports" (plist-get plan :ports))
      (add "user" (delq nil (list (plist-get plan :user)))))
    (string-join (nreverse lines) "\n")))

(defun mega-container-approve (file plan)
  "Return non-nil if the user agrees to run what FILE, parsed as PLAN, says.
Asked once per version of the file.  A batch Emacs is never asked, and
never agrees."
  (let ((hash (mega-container--hash file))
        (approved (mega-container--approved)))
    (or (equal (cdr (assoc file approved)) hash)
        (and (not noninteractive)
             (save-window-excursion
               (with-current-buffer (get-buffer-create "*mega-container*")
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert (mega-container-summary plan) "\n"))
                 (special-mode)
                 (goto-char (point-min))
                 (pop-to-buffer (current-buffer)))
               (yes-or-no-p (format "Start this container, as %s describes? "
                                    (abbreviate-file-name file))))
             (progn
               (setf (alist-get file approved nil nil #'equal) hash)
               (with-temp-file mega-container-approved-file
                 (prin1 approved (current-buffer)))
               t)))))

;;;; Talking to the engine

(defun mega-container-engine ()
  "The container program to use, or nil if none is installed."
  (if (stringp mega-container-engine)
      (and (mega-exe-p mega-container-engine) mega-container-engine)
    (seq-find #'mega-exe-p '("podman" "docker"))))

(defun mega-container--engine (engine args &rest options)
  "Run ENGINE with ARGS on this machine; return the result of `mega-exec-run'.
OPTIONS are passed on."
  (apply #'mega-exec-run engine args :local t options))

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
                           "--format" "{{.ID}} {{.State}}"))
                    "\n" t))))
    (when (and line (string-match "\\`\\([^ ]+\\) +\\(.*\\)\\'" line))
      (cons (match-string 1 line) (downcase (match-string 2 line))))))

(defun mega-container--exec-arguments (attached directory)
  "The `ENGINE exec' arguments, before the program, for ATTACHED and DIRECTORY."
  (append (list "exec" "--interactive")
          (when-let* ((user (plist-get attached :user)))
            (list "--user" user))
          (list "--workdir" directory)
          (mapcan (lambda (env) (list "--env" env)) (plist-get attached :env))
          (list (plist-get attached :id))))

(defun mega-container--run-inside (attached commands)
  "Run each of COMMANDS, argument lists, inside the container ATTACHED."
  (dolist (command commands)
    (message "In the container: %s" (string-join command " "))
    (mega-container--ok (plist-get attached :engine)
                        (append (mega-container--exec-arguments
                                 attached (plist-get attached :folder))
                                command)
                        :timeout 1800)))

;;;; Starting, natively and through the official command

(defun mega-container--up-native (engine plan)
  "Start or join the container of PLAN with ENGINE; return what to attach to."
  (when-let* ((unsupported (plist-get plan :unsupported)))
    (user-error "This devcontainer.json needs the official `devcontainer' command: MEGA alone cannot do %s"
                (mapconcat #'symbol-name unsupported ", ")))
  (unless (plist-get plan :image)
    (user-error "This devcontainer.json names no image"))
  (let* ((root (plist-get plan :root))
         (existing (mega-container-find-existing engine root))
         (attached (list :engine engine
                         :user (plist-get plan :user)
                         :folder (plist-get plan :folder)
                         :name (plist-get plan :name)
                         :env (plist-get plan :remote-env)))
         (created nil))
    (cond
     ((and existing (string-prefix-p "running" (cdr existing)))
      (setq attached (plist-put attached :id (car existing))))
     (existing
      (mega-container--ok engine (list "start" (car existing)))
      (setq attached (plist-put attached :id (car existing))))
     (t
      (dolist (command (mega-container--commands (plist-get plan :initialize)))
        (message "On this machine: %s" (string-join command " "))
        (let ((result (mega-exec-run (car command) (cdr command)
                                     :directory root :local t :timeout 1800)))
          (unless (eql (plist-get result :status) 0)
            (user-error "initializeCommand failed: %s"
                        (string-trim (concat (plist-get result :error)
                                             (plist-get result :output)))))))
      (setq attached
            (plist-put attached :id
                       (mega-container--ok engine (mega-container-run-arguments plan)
                                           :timeout 600)))
      (setq created t)))
    (when created
      (mega-container--run-inside
       attached (mapcan #'mega-container--commands (plist-get plan :created))))
    (unless (and existing (string-prefix-p "running" (cdr existing)))
      (mega-container--run-inside
       attached (mapcan #'mega-container--commands (plist-get plan :started))))
    attached))

(defun mega-container--up-cli (engine plan)
  "Start the container of PLAN with the official command; return what to attach to."
  (let* ((root (plist-get plan :root))
         (result (mega-exec-run "devcontainer"
                                (list "up" "--workspace-folder" (directory-file-name root)
                                      "--docker-path" engine)
                                :directory root :local t :timeout 3600))
         (line (car (last (split-string (plist-get result :output) "\n" t))))
         (answer (ignore-errors (json-parse-string (or line "") :object-type 'alist))))
    (unless (equal (alist-get 'outcome answer) "success")
      (user-error "`devcontainer up' failed: %s"
                  (string-trim (concat (alist-get 'message answer) "\n"
                                       (plist-get result :error)))))
    (list :engine engine
          :id (alist-get 'containerId answer)
          :user (or (alist-get 'remoteUser answer) (plist-get plan :user))
          :folder (or (alist-get 'remoteWorkspaceFolder answer) (plist-get plan :folder))
          :name (plist-get plan :name)
          :env (plist-get plan :remote-env))))

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
          ((string-prefix-p folder (file-name-as-directory file))
           (concat (car entry) (string-remove-prefix folder file)))
          (t (format "/%s:%s%s:%s"
                     (plist-get attached :engine)
                     (if-let* ((user (plist-get attached :user))) (concat user "@") "")
                     (plist-get attached :id)
                     file)))))

(defun mega-container--find (attached program)
  "Non-nil if PROGRAM exists in the container ATTACHED.  Remembered."
  (let* ((key (cons (plist-get attached :id) program))
         (known (gethash key mega-container--found)))
    (unless known
      (setq known
            (if (eql 0 (plist-get
                        (mega-container--engine
                         (plist-get attached :engine)
                         (append (mega-container--exec-arguments
                                  attached (plist-get attached :folder))
                                 (list "/bin/sh" "-c" "command -v \"$1\"" "sh" program))
                         :timeout 20)
                        :status))
                t
              'no))
      (puthash key known mega-container--found))
    (eq known t)))

(defun mega-container-context (directory)
  "The execution context of DIRECTORY, if its project's container is in use.
This is what `mega-exec' asks; see the Commentary of mega-exec.el."
  (when-let* ((entry (mega-container-attached directory)))
    (let ((attached (cdr entry)))
      (list :kind 'container
            :name (plist-get attached :name)
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

(defun mega-container--path-to-uri (arguments)
  "Advice: give eglot the container's name for a file of an attached project."
  (let ((path (car arguments)))
    (if-let* ((entry (and (stringp path) (mega-container-attached path))))
        (cons (mega-container-to-inside path entry) (cdr arguments))
      arguments)))

(defun mega-container--uri-to-path (path)
  "Advice: turn a file name from a server in a container into this machine's."
  (if-let* ((entry (and (stringp path) (mega-container-attached))))
      (mega-container-to-host path entry)
    path))

(with-eval-after-load 'eglot
  (advice-add 'eglot-path-to-uri :filter-args #'mega-container--path-to-uri)
  (advice-add 'eglot-uri-to-path :filter-return #'mega-container--uri-to-path))

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
  (file-name-as-directory
   (expand-file-name (or (mega-project-root) default-directory))))

;;;###autoload
(defun mega-container-up ()
  "Start the project's dev container, or join it, and run its tools there."
  (interactive)
  (let* ((root (mega-container--root))
         (file (or (mega-container-config-file root)
                   (user-error "No devcontainer.json in %s" (abbreviate-file-name root))))
         (engine (or (mega-container-engine)
                     (user-error "Neither podman nor docker is installed")))
         (plan (mega-container-plan (mega-container-read file) root)))
    (unless (mega-trust-p root t "start its dev container")
      (user-error "This project is not trusted; see M-x mega-trust-project"))
    (unless (mega-container-approve file plan)
      (user-error "Not started"))
    (message "Starting the container of %s..." (plist-get plan :name))
    (let ((attached (if (mega-exe-p "devcontainer")
                        (mega-container--up-cli engine plan)
                      (mega-container--up-native engine plan))))
      (setf (alist-get root mega-container--attached nil nil #'equal) attached)
      (message "Tools of %s now run in its container (%s)"
               (abbreviate-file-name root)
               (substring (plist-get attached :id) 0
                          (min 12 (length (plist-get attached :id))))))))

;;;###autoload
(defun mega-container-detach ()
  "Stop using the project's container; its tools run on this machine again.
The container itself is left running."
  (interactive)
  (let ((entry (or (mega-container-attached)
                   (user-error "This project is not using a container"))))
    (setq mega-container--attached (delq entry mega-container--attached))
    (message "Detached; the container is still running")))

;;;###autoload
(defun mega-container-stop ()
  "Stop the project's container, after asking."
  (interactive)
  (let* ((entry (or (mega-container-attached)
                    (user-error "This project is not using a container")))
         (attached (cdr entry)))
    (when (yes-or-no-p (format "Stop the container of %s? " (plist-get attached :name)))
      (mega-container--ok (plist-get attached :engine)
                          (list "stop" (plist-get attached :id)) :timeout 60)
      (setq mega-container--attached (delq entry mega-container--attached))
      (message "Stopped"))))

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
         (arguments (append (list "exec" "--interactive" "--tty")
                            (when-let* ((user (plist-get attached :user)))
                              (list "--user" user))
                            (list "--workdir" (plist-get attached :folder)
                                  (plist-get attached :id) "/bin/sh" "-c"
                                  "command -v bash >/dev/null && exec bash || exec sh"))))
    (require 'term)
    (pop-to-buffer
     (apply #'make-term (format "container: %s" (plist-get attached :name))
            (plist-get attached :engine) nil arguments))
    (term-char-mode)))

;;;###autoload
(defun mega-container-info ()
  "Say which container the project is using, if any."
  (interactive)
  (if-let* ((entry (mega-container-attached)))
      (message "%s: %s container %s, user %s, workspace %s"
               (plist-get (cdr entry) :name) (plist-get (cdr entry) :engine)
               (plist-get (cdr entry) :id)
               (or (plist-get (cdr entry) :user) "default")
               (plist-get (cdr entry) :folder))
    (let ((file (mega-container-config-file (mega-container--root))))
      (message (if file
                   "Not using a container.  This project has one: C-c k u starts it"
                 "Not using a container, and this project describes none")))))

(provide 'mega-container)
;;; mega-container.el ends here
