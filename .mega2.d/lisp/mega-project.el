;;; mega-project.el --- Projects, their files, the file tree  -*- lexical-binding: t; -*-

;;; Commentary:

;; A project is what Emacs's own project.el says it is: normally a version
;; control checkout.  MEGA adds one case to that definition: a directory
;; that is not under version control but holds a file only a project's root
;; has, such as Cargo.toml (`mega-project-markers').  Without it a fresh
;; `cargo new --vcs none', or an unpacked archive, would have no root to
;; build, search or debug from.
;;
;; The files of a project are listed by whoever knows them best.  In a
;; checkout that is the version control program, by way of project.el: what
;; it tracks, and what it neither tracks nor ignores.  A project found by a
;; marker has nobody to ask, so MEGA lists it itself, with ripgrep if that is
;; installed and with `find' otherwise, leaving out what a build produces
;; (`mega-project-ignored-directories').  Nothing is cached: a listing is
;; quick, and a list that is right is worth more than one that is instant.
;;
;; `C-c p' is project.el's whole command map.  The ones used most:
;;
;;   C-c p f   open a file in the project, matching fuzzily
;;             (`C-u C-c p f' also offers ignored files)
;;   C-c p p   switch to another project
;;   C-c p b   switch to a buffer of the project
;;   C-c p g   search the project into a results buffer
;;   C-c p c   compile        C-c p s   shell       C-c p k   close its buffers
;;
;; `C-c t' toggles a file tree in a side window.
;;
;; MEGA remembers a project when you open a file in it, so the list of recent
;; projects fills itself in.  Remote and private locations are not remembered.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)

(declare-function project-root "project")
(declare-function project-current "project")
(declare-function project-remember-project "project")
(declare-function speedbar-window-mode "speedbar")

(defvar project-vc-include-untracked)
(defvar project-vc-cache-timeout)
(defvar project-vc-non-essential-cache-timeout)
(defvar project-vc-merge-submodules)
(defvar project-kill-buffers-display-buffer-list)
(defvar speedbar-prefer-window)
(defvar speedbar-window-default-width)
(defvar speedbar-show-unknown-files)
(defvar speedbar-use-images)
(defvar speedbar-directory-unshown-regexp)
(defvar imenu-flatten)
(defvar imenu-auto-rescan)

(setq project-vc-include-untracked t
      ;; Say which buffers are about to be closed before closing them.
      project-kill-buffers-display-buffer-list t
      imenu-flatten 'prefix
      imenu-auto-rescan t)

;; `C-c p' is bound to this name.  A key can only be a prefix through a symbol
;; if the symbol's function is the keymap, and Emacs's own map is a variable.
(defalias 'mega-project-map project-prefix-map)

(defvar mega-project-kinds
  '(("Cargo.toml" :root t :debug rust
     :format ("cargo" "fmt")
     :tasks ((build "cargo" "build") (run "cargo" "run") (test "cargo" "test")
             (check "cargo" "check") (clippy "cargo" "clippy") (doc "cargo" "doc")))
    ("go.mod" :root t
     :format ("gofmt" "-w" ".")
     :tasks ((build "go" "build" "./...") (run "go" "run" ".")
             (test "go" "test" "./...")))
    ("build.zig" :root t
     :format ("zig" "fmt" ".")
     :tasks ((build "zig" "build") (run "zig" "build" "run")
             (test "zig" "build" "test")))
    ("CMakeLists.txt" :root t
     :tasks ((configure "cmake" "-S" "." "-B" "build")
             (build "cmake" "--build" "build")
             (test "ctest" "--test-dir" "build")))
    ("Makefile"
     :tasks ((build "make") (test "make" "test") (run "make" "run")
             (clean "make" "clean")))
    ("justfile" :also ("Justfile" ".justfile")
     :tasks ((build "just" "build") (test "just" "test") (run "just" "run")))
    ("pyproject.toml" :root t
     :tasks ((test "python3" "-m" "pytest") (build "python3" "-m" "build")))
    ("package.json" :root t)
    (".devcontainer" :root t))
  "Every kind of project MEGA knows, by the file that says so: (FILE . PLIST).
A project is of every kind whose FILE is at its root, and where two
kinds say something about the same thing, the one listed first counts.

  :root    non-nil if FILE is found only at the root of a project, so
           that it marks one where there is no version control
  :also    other names FILE goes by
  :tasks   what `C-c x' offers there: a list of (NAME PROGRAM ARG...)
  :format  the command line that formats the whole project
  :debug   the kind of debugger its programs need, a key of
           `mega-debug-languages', for a buffer whose language does not
           say

What belongs to a language, whatever the project, is in `mega-languages'.")

(defun mega-project-kinds-of (root)
  "The rows of `mega-project-kinds' that the project at ROOT is of, in order."
  (seq-filter (lambda (kind)
                (seq-some (lambda (name) (file-exists-p (expand-file-name name root)))
                          (cons (car kind) (plist-get (cdr kind) :also))))
              mega-project-kinds))

(defcustom mega-project-markers
  (mapcar #'car (seq-filter (lambda (kind) (plist-get (cdr kind) :root))
                            mega-project-kinds))
  "Files that mark the root of a project that is not under version control.
By default, the kinds of project marked :root in `mega-project-kinds'.
The nearest directory at or above a file that holds one of these is the
root.  Version control is asked first, so inside a checkout these mean
nothing: a crate of a workspace stays part of the workspace's project.
Keep to names that are found only at a root; a Makefile is not one."
  :type '(repeat string)
  :group 'mega)

(defun mega-project-try-markers (directory)
  "The project DIRECTORY is in, found by `mega-project-markers', or nil.
For `project-find-functions', after version control has had its say."
  ;; Not on another machine: every directory on the way up is a round trip.
  (unless (file-remote-p directory)
    (when-let* ((found (locate-dominating-file
                        directory
                        (lambda (candidate)
                          (seq-some (lambda (marker)
                                      (file-exists-p (expand-file-name marker candidate)))
                                    mega-project-markers)))))
      (let ((root (file-name-as-directory (expand-file-name found))))
        ;; A marker in the home directory, or at the top of the disk, does
        ;; not make everything below it one project.
        (unless (member root (list "/" (file-name-as-directory (expand-file-name "~"))))
          (cons 'mega root))))))

;;;; The files of a project without version control

(defcustom mega-project-ignored-directories
  '("target" "node_modules" ".zig-cache" "zig-cache" "zig-out" "__pycache__"
    ".venv" "venv" ".mypy_cache" ".pytest_cache" ".ruff_cache" ".tox"
    "build" "dist")
  "Directories that hold no files of a project without version control.
They are where a build puts its results: thousands of files nobody opens
by name or searches.  In a checkout this list means nothing, since the
checkout's own ignore rules say it better.  `C-u C-c p f' offers the
files in them all the same."
  :type '(repeat string)
  :group 'mega)

(defcustom mega-project-list-timeout 20
  "Seconds after which listing the files of a project is given up."
  :type 'number
  :group 'mega)

(defconst mega-project--version-control-directories
  '(".git" ".hg" ".svn" ".bzr" ".jj" "_darcs")
  "Where version control programs keep their own files.")

(defun mega-project--skipped ()
  "The names of the directories a project without version control leaves out."
  (append mega-project--version-control-directories
          mega-project-ignored-directories))

(defun mega-project-left-out (&optional directory)
  "The directory names to pass over in the project DIRECTORY is in.
Nil in a checkout, where version control decides, and outside a project."
  (and (eq (car-safe (mega-project-current directory)) 'mega)
       (mega-project--skipped)))

(defun mega-project--glob-quote (name)
  "NAME as a glob pattern that matches nothing but NAME."
  (replace-regexp-in-string "[][*?{}!\\]" "\\\\\\&" name))

(defun mega-project-list-command (root)
  "Return (PROGRAM . ARGS) that lists the files below ROOT, run there.
The names are relative and each ends in a null byte, which is the one
thing a file name cannot contain."
  (let ((skipped (mapcar #'mega-project--glob-quote (mega-project--skipped))))
    (if (mega-exec-find "rg" root t)
        ;; ripgrep also honours a .gitignore or an .ignore file, if the
        ;; project has one in spite of having no repository.
        `("rg" "--files" "--hidden" "--no-require-git" "--null"
          ,@(mapcar (lambda (name) (concat "--glob=!" name "/")) skipped))
      `("find" "." "("
        ,@(cdr (mapcan (lambda (name) (list "-o" "-name" name)) skipped))
        ")" "-prune" "-o" "-type" "f" "-print0"))))

(defun mega-project-list-files (root)
  "The files of the project without version control at ROOT, in order.
The names are absolute.  Reading a project runs none of its code, so
this needs no trust."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (command (mega-project-list-command root))
         (result (mega-exec-run (car command) (cdr command)
                                :directory root :local t
                                :timeout mega-project-list-timeout)))
    (when (plist-get result :stopped)
      (error "Listing the files of %s took more than %s seconds"
             (abbreviate-file-name root) mega-project-list-timeout))
    (sort (mapcar (lambda (name)
                    (concat root (if (string-prefix-p "./" name)
                                     (substring name 2)
                                   name)))
                  (split-string (plist-get result :output) "\0" t))
          #'string<)))

;; After project.el has loaded, never before: its own list of finders is a
;; default that a value set earlier would replace, and the methods below
;; belong to its generic functions.
(with-eval-after-load 'project
  (add-hook 'project-find-functions #'mega-project-try-markers 90)

  (cl-defmethod project-root ((project (head mega)))
    (cdr project))

  (cl-defmethod project-files ((project (head mega)) &optional dirs)
    (mapcan #'mega-project-list-files (or dirs (list (project-root project)))))

  (cl-defmethod project-ignores ((_project (head mega)) _dir)
    (mapcar (lambda (name) (concat name "/")) (mega-project--skipped))))

(defun mega-project-current (&optional directory)
  "The project DIRECTORY is in, as things are now, or nil.  Never prompts.
DIRECTORY defaults to `default-directory'.

Emacs remembers whether a directory was in a checkout, and to a caller
that does not prompt it gives an answer up to five minutes old.  MEGA
decides by the root of a project what may run in it, so it asks for the
answer a command gets: one that is at most two seconds old."
  (require 'project)
  (let ((default-directory (or directory default-directory))
        (project-vc-non-essential-cache-timeout project-vc-cache-timeout))
    (ignore-errors (project-current nil))))

(defun mega-project-root (&optional directory)
  "Return the root of the project containing DIRECTORY, or nil.
DIRECTORY defaults to `default-directory'.  Never prompts."
  (when-let* ((project (mega-project-current directory)))
    (expand-file-name (project-root project))))

(defun mega-project-directory (&optional directory)
  "The root of the project DIRECTORY is in, or DIRECTORY outside any project.
DIRECTORY defaults to `default-directory'.  The answer is absolute and
ends in a slash: it is where a project's tools are run from."
  (let ((directory (or directory default-directory)))
    (file-name-as-directory
     (expand-file-name (or (mega-project-root directory) directory)))))

;;;; Remembering projects

(defun mega-project--rememberable-p (root)
  "Non-nil if the project at ROOT may be listed among recent projects."
  (not (or (file-remote-p root)
           (mega-forgettable-file-p root))))

(defun mega-project-remember ()
  "Remember the project of the file this buffer visits.
Runs when a file is opened.  It only reads the project list when the
project is not already at the front of it."
  (when (and buffer-file-name (not (file-remote-p buffer-file-name)))
    (when-let* ((project (mega-project-current))
                ((mega-project--rememberable-p (project-root project))))
      (project-remember-project project))))

(add-hook 'find-file-hook #'mega-project-remember)

;;;; The file tree
;;
;; Emacs 31 can show Speedbar in a side window of the current frame, which is
;; what makes it usable in a terminal.

(setq speedbar-prefer-window t
      speedbar-window-default-width 32
      speedbar-show-unknown-files t
      speedbar-use-images nil
      ;; Show dotfiles: in a repository they are half of what matters.
      speedbar-directory-unshown-regexp "^\\(\\.git\\|\\.\\.?\\)\\'")

;;;###autoload
(defun mega-project-tree ()
  "Show or hide the file tree."
  (interactive)
  (require 'speedbar)
  ;; No argument toggles; this is a plain function, not a minor mode.
  (speedbar-window-mode))

(provide 'mega-project)
;;; mega-project.el ends here
