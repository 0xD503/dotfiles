;;; mega-search.el --- Search the project as you type  -*- lexical-binding: t; -*-

;;; Commentary:

;; `M-g a' searches the whole project and shows the hits while you type; RET
;; jumps to the highlighted one.  `M-g s' starts from the symbol at point.
;;
;; The search is done by one of three programs, and the prompt says which:
;;
;;   git      `git grep --perl-regexp --line-number -I': the default.  It
;;            knows what the checkout tracks and ignores, and needs nothing
;;            installed that the checkout does not need already.
;;   rg       ripgrep, with --hidden
;;   grep     recursive GNU grep
;;
;; `git grep' can only search a checkout, so anywhere else the next of the
;; three that is installed is used.  `C-o b' in the prompt switches to the
;; next program, and the session stays with it; to start with another for
;; good, in local.el:   (setq mega-search-backend 'rg)
;;
;; While the prompt is open, `C-o' followed by a letter changes how it
;; searches, and the list updates in place:
;;
;;   C-o c    case: smart -> ignore -> sensitive
;;   C-o u    include untracked files           (git)
;;   C-o i    include files that are ignored    (git, rg)
;;   C-o s    search the submodules as well     (git)
;;   C-o h    include hidden files              (rg, grep)
;;   C-o l    take the pattern literally, not as a regular expression
;;   C-o w    match whole words only
;;   C-o b    switch to the next search program
;;   C-o e    put every hit in a buffer you can navigate and edit
;;   C-o ?    show the current settings
;;
;; The settings stay for the session.  To search only part of the project,
;; add a path or glob after " -- ":   handler -- src/*.rs
;;
;; Which files are searched is the one thing the three programs do not
;; agree on, because only git knows what a checkout tracks:
;;
;;                       git grep           ripgrep           grep
;;   tracked files       always             always            always
;;   untracked files     C-o u (on)         always            always
;;   ignored files       C-o i (off)        C-o i (off)       always
;;   hidden files        always             C-o h (on)        C-o h (on)
;;   submodules          C-o s (off)        always            always
;;
;; In brackets, how each starts out.  With git grep, ignored files are
;; untracked files, so C-o i brings both; and C-o s leaves both out, since
;; git will not search submodules and untracked files in one go.  A key
;; that the program in use cannot act on says so, and is remembered for
;; when you switch to one that can.
;;
;; The search always runs where the files are, on the host, even when the
;; project's tools live in a container.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)
(require 'mega-pick)

(require 'mega-project)
(declare-function grep-mode "grep")

(defcustom mega-search-backend 'git
  "The program that searches the project: `git', `rg' or `grep'.
Where it cannot be used, the next of those three that can is: `git grep'
searches a checkout and nothing else, and a program may not be installed.
`C-o b' in the search prompt changes this for the session; set it in
local.el to change it for good.  (`auto', an older value, means `git'.)"
  :type '(choice (const git) (const rg) (const grep))
  :group 'mega)

(defcustom mega-search-max-results 500
  "Most hits a search collects before it stops the program."
  :type 'integer :group 'mega)

(defcustom mega-search-min-input 2
  "Fewest characters to type before a search runs."
  :type 'integer :group 'mega)

(defface mega-search-file '((t :inherit xref-file-header))
  "The file name of a search hit." :group 'mega)
(defface mega-search-line '((t :inherit xref-line-number))
  "The line number of a search hit." :group 'mega)

;;;; How to search: settings that last for the session

(defvar mega-search-case 'smart
  "How case is treated: `smart', `ignore' or `sensitive'.
`smart' means case matters only if the pattern contains a capital.")
(defvar mega-search-untracked t "Non-nil to include files git does not track.")
(defvar mega-search-ignored nil "Non-nil to include files that are ignored.")
(defvar mega-search-submodules nil
  "Non-nil to search the submodules of a checkout as well, with `git grep'.
Git then searches what is tracked and nothing else: it will not do both.")
(defvar mega-search-hidden t "Non-nil to include hidden files.")
(defvar mega-search-literal nil "Non-nil to take the pattern literally.")
(defvar mega-search-word nil "Non-nil to match whole words only.")

(defvar mega-search-history nil "What was searched for.")

(defvar mega-search--directory nil "Where the active search runs.")
(defvar mega-search--backend nil "The program the active search uses.")
(defvar mega-search--left-out nil
  "Directory names the active search passes over, unless it includes ignored files.
Set for a project without version control: see `mega-project-left-out'.")
(defvar mega-search--export nil "Set by `mega-search-export' as it leaves the prompt.")

;;;; Choosing the program

(defun mega-search--usable-p (backend directory)
  "Non-nil if BACKEND can search DIRECTORY."
  (pcase backend
    ('rg (mega-exec-find "rg" directory :local))
    ('git (and (mega-exec-find "git" directory :local)
               (locate-dominating-file directory ".git")))
    ('grep (mega-exec-find "grep" directory :local))))

(defun mega-search-backends (directory)
  "The search programs usable in DIRECTORY: the one you prefer first.
That is `mega-search-backend', then the rest of git, rg and grep."
  (let ((preferred (if (memq mega-search-backend '(git rg grep))
                       mega-search-backend
                     'git)))
    (seq-filter (lambda (backend) (mega-search--usable-p backend directory))
                (cons preferred (remq preferred '(git rg grep))))))

(defun mega-search-backend-for (directory)
  "The search program to use in DIRECTORY, or nil if there is none."
  (car (mega-search-backends directory)))

(defun mega-search-backend-name (backend)
  "What BACKEND is called where a person reads it."
  (pcase backend
    ('git "git grep") ('rg "ripgrep") ('grep "grep") (_ "no search program")))

;;;; Building the command

(defun mega-search-split (input)
  "Split INPUT into (PATTERN . PATHS) at \" -- \"."
  (if (string-match "\\(.*?\\) +-- +\\(.*\\)" input)
      (cons (match-string 1 input)
            (split-string (match-string 2 input) " +" t))
    (cons input nil)))

(defun mega-search--ignore-case-p (pattern)
  "Non-nil if PATTERN should be matched without regard to case."
  (pcase mega-search-case
    ('ignore t)
    ('sensitive nil)
    (_ (let ((case-fold-search nil))
         (not (string-match-p "[[:upper:]]" pattern))))))

(defun mega-search-command (backend pattern paths)
  "Return (PROGRAM . ARGS) searching for PATTERN with BACKEND.
PATHS, a list of paths or globs, limits the search; nil means everything.
The command reflects the current search settings, and is an argument
list: PATTERN and PATHS are passed as they are, never through a shell."
  (let ((ignore-case (mega-search--ignore-case-p pattern)))
    (pcase backend
      ('rg
       `("rg" "--line-number" "--no-heading" "--color=never"
         "--max-columns=300" "--max-columns-preview"
         ,(if ignore-case "--ignore-case" "--case-sensitive")
         ,@(when mega-search-hidden '("--hidden" "--glob=!.git"))
         ;; Without a repository ripgrep reads no .gitignore unless told to.
         ,@(if mega-search-ignored
               '("--no-ignore")
             (cons "--no-require-git"
                   (mapcar (lambda (name) (concat "--glob=!" name "/"))
                           mega-search--left-out)))
         ,@(when mega-search-literal '("--fixed-strings"))
         ,@(when mega-search-word '("--word-regexp"))
         ,@(mapcar (lambda (path) (concat "--glob=" path)) paths)
         ,(concat "--regexp=" pattern)
         ;; An explicit directory: with none, rg reads standard input.
         "."))
      ('git
       `("git" "--no-pager" "grep" "--line-number" "-I" "--color=never"
         ,(if mega-search-literal "--fixed-strings" "--perl-regexp")
         ,@(when ignore-case '("--ignore-case"))
         ;; Submodules, or what is not tracked: git refuses to do both.
         ,@(cond (mega-search-submodules '("--recurse-submodules"))
                 (mega-search-ignored '("--untracked" "--no-exclude-standard"))
                 (mega-search-untracked '("--untracked")))
         ,@(when mega-search-word '("--word-regexp"))
         "-e" ,pattern
         "--" ,@paths))
      ('grep
       `("grep" "--recursive" "--line-number" "--binary-files=without-match"
         "--color=never" "--exclude-dir=.git"
         ,(if mega-search-literal "--fixed-strings" "--perl-regexp")
         ,@(when ignore-case '("--ignore-case"))
         ;; Names of a dot and something more.  Plain ".*" would take in
         ;; ".", the directory the search starts from, and so find nothing.
         ,@(unless mega-search-hidden '("--exclude=.?*" "--exclude-dir=.?*"))
         ,@(unless mega-search-ignored
             (mapcar (lambda (name) (concat "--exclude-dir=" name))
                     mega-search--left-out))
         ,@(when mega-search-word '("--word-regexp"))
         ,(concat "--regexp=" pattern)
         ;; A path is a path, even one that begins with a dash.
         "--" ,@(or paths '(".")))))))

;;;; Running it

(defun mega-search-parse (line)
  "Parse LINE as a hit: (FILE LINE-NUMBER TEXT), or nil."
  (when (string-match "\\`\\(?:\\./\\)?\\(.+?\\):\\([0-9]+\\):\\(.*\\)\\'" line)
    (list (match-string 1 line)
          (string-to-number (match-string 2 line))
          (match-string 3 line))))

(defun mega-search--present (line)
  "Return LINE as a candidate: FILE:LINE:TEXT, with the first two in faces."
  (pcase (mega-search-parse line)
    (`(,file ,number ,text)
     (concat (propertize file 'face 'mega-search-file) ":"
             (propertize (number-to-string number) 'face 'mega-search-line) ":"
             text))))

(defun mega-search-run (input &optional directory backend limit)
  "Search DIRECTORY for INPUT with BACKEND and return the hits as strings.
Each hit is FILE:LINE:TEXT, FILE relative to DIRECTORY.  At most LIMIT
hits come back, by default `mega-search-max-results'.  An INPUT shorter
than `mega-search-min-input' finds nothing, without running anything."
  (let* ((directory (or directory mega-search--directory default-directory))
         (backend (or backend mega-search--backend
                      (mega-search-backend-for directory)))
         (split (mega-search-split input))
         (pattern (car split)))
    (when (and backend (>= (length pattern) mega-search-min-input))
      (let ((command (mega-search-command backend pattern (cdr split))))
        (delq nil
              (mapcar #'mega-search--present
                      (mega-exec-lines (car command) (cdr command)
                                       :directory directory
                                       :local t
                                       :limit (or limit mega-search-max-results))))))))

;;;; Changing the settings from the prompt

(defconst mega-search-fixed
  '((git  (hidden . "git grep searches hidden files always"))
    (rg   (untracked . "ripgrep cannot tell untracked files: it searches them always")
          (submodules . "ripgrep goes into a submodule as into any directory"))
    (grep (untracked . "grep cannot tell untracked files: it searches them always")
          (ignored . "grep knows no ignore files: it searches them always")
          (submodules . "grep goes into a submodule as into any directory")))
  "What each search program does whatever the setting, and so cannot be told.
An alist of (PROGRAM (SETTING . WHY)...).  Only git knows what a checkout
tracks, and only it searches hidden files unasked.")

(defun mega-search--fixed (setting)
  "Why the program in use cannot act on SETTING, or nil if it can."
  (cdr (assq setting (cdr (assq mega-search--backend mega-search-fixed)))))

(defun mega-search-describe ()
  "One line saying how the search currently works.
It names the settings that are on and that the program in use acts on:
what a program does regardless is not a setting of it."
  (let* ((on (lambda (setting value) (and value (not (mega-search--fixed setting)))))
         (submodules (funcall on 'submodules mega-search-submodules))
         (ignored (and (funcall on 'ignored mega-search-ignored) (not submodules)))
         ;; To git, ignored files are untracked ones: asking for them brings
         ;; both.  And with submodules it searches tracked files only.
         (untracked (and (or (funcall on 'untracked mega-search-untracked)
                             (and ignored (eq mega-search--backend 'git)))
                         (not submodules))))
    (format "%s  case:%s%s%s%s%s%s%s"
            (or mega-search--backend "no search program")
            mega-search-case
            (if untracked " +untracked" "")
            (if ignored " +ignored" "")
            (if submodules " +submodules" "")
            (if (funcall on 'hidden mega-search-hidden) " +hidden" "")
            (if mega-search-literal " literal" "")
            (if mega-search-word " words" ""))))

(defun mega-search--changed (&optional setting)
  "Search again with the new settings, and say what they are.
SETTING, if given, is the one that was changed: when the program in use
cannot act on it, that is said too, so that a key never does nothing
without a word."
  (mega-pick-refresh)
  (let ((fixed (and setting (mega-search--fixed setting))))
    (minibuffer-message (if fixed "[%s]  %s" "[%s]")
                        (mega-search-describe) fixed)))

(defmacro mega-search--define-toggle (name variable setting doc)
  "Define command NAME that flips VARIABLE, the setting called SETTING.
DOC is its docstring."
  `(defun ,name ()
     ,doc
     (interactive)
     (setq ,variable (not ,variable))
     (mega-search--changed ',setting)))

(mega-search--define-toggle mega-search-toggle-untracked mega-search-untracked untracked
                            "Include or leave out files git does not track.")
(mega-search--define-toggle mega-search-toggle-ignored mega-search-ignored ignored
                            "Include or leave out ignored files.")
(mega-search--define-toggle mega-search-toggle-submodules mega-search-submodules submodules
                            "Search the submodules as well, or leave them out.")
(mega-search--define-toggle mega-search-toggle-hidden mega-search-hidden hidden
                            "Include or leave out hidden files.")
(mega-search--define-toggle mega-search-toggle-literal mega-search-literal literal
                            "Take the pattern literally, or as a regular expression.")
(mega-search--define-toggle mega-search-toggle-word mega-search-word word
                            "Match whole words only, or anywhere.")

(defun mega-search-cycle-case ()
  "Change how case is treated: smart, then ignore, then sensitive."
  (interactive)
  (setq mega-search-case (pcase mega-search-case
                           ('smart 'ignore) ('ignore 'sensitive) (_ 'smart)))
  (mega-search--changed))

(defun mega-search-cycle-backend ()
  "Search with the next usable program, and stay with it for the session."
  (interactive)
  ;; Round a fixed circle, not the order of preference: that order changes
  ;; with every step taken here, and would send the third step back.
  (let* ((usable (seq-filter (lambda (backend)
                               (mega-search--usable-p backend mega-search--directory))
                             '(git rg grep)))
         (rest (cdr (memq mega-search--backend usable)))
         (next (or (car rest) (car usable))))
    (setq mega-search--backend next)
    ;; Like the other settings of the prompt: the next search starts as
    ;; this one was left.
    (when next (setq mega-search-backend next)))
  (mega-search--changed))

(defun mega-search-show-settings ()
  "Show how the search currently works."
  (interactive)
  (minibuffer-message "[%s]" (mega-search-describe)))

(defun mega-search-export ()
  "Leave the prompt and put every hit in a buffer."
  (interactive)
  (setq mega-search--export t)
  (exit-minibuffer))

(defvar mega-search-options-map
  (let ((map (make-sparse-keymap)))
    (define-key map "c" #'mega-search-cycle-case)
    (define-key map "u" #'mega-search-toggle-untracked)
    (define-key map "i" #'mega-search-toggle-ignored)
    (define-key map "s" #'mega-search-toggle-submodules)
    (define-key map "h" #'mega-search-toggle-hidden)
    (define-key map "l" #'mega-search-toggle-literal)
    (define-key map "w" #'mega-search-toggle-word)
    (define-key map "b" #'mega-search-cycle-backend)
    (define-key map "e" #'mega-search-export)
    (define-key map "?" #'mega-search-show-settings)
    map)
  "What follows `C-o' in the search prompt.")

(defvar mega-search-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-o") mega-search-options-map)
    map)
  "Extra keys of the search prompt.")

;;;; Going to a hit, and the results buffer

(defun mega-search-visit (hit directory)
  "Go to HIT, a FILE:LINE:TEXT string found under DIRECTORY."
  (pcase (mega-search-parse (substring-no-properties hit))
    (`(,file ,number ,_)
     (push-mark nil t)
     (find-file (expand-file-name file directory))
     (goto-char (point-min))
     (forward-line (1- number))
     (when (fboundp 'pulse-momentary-highlight-one-line)
       (pulse-momentary-highlight-one-line (point)))
     t)))

(defun mega-search-results-buffer (input directory backend)
  "Show every hit for INPUT under DIRECTORY in a buffer.
The buffer is in `grep-mode': `n'/`p' and RET move between hits, and `e'
makes them editable in place."
  (let ((hits (let ((mega-search--directory directory)
                    (mega-search--backend backend))
                (mega-search-run input directory backend 10000)))
        (buffer (get-buffer-create "*mega-search*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq default-directory (file-name-as-directory directory))
        (insert (format "Search for \"%s\" in %s  (%s, %d hits)\n\n"
                        input (abbreviate-file-name directory)
                        (let ((mega-search--backend backend)) (mega-search-describe))
                        (length hits)))
        (dolist (hit hits)
          (insert (substring-no-properties hit) "\n")))
      (grep-mode)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

;;;; The commands

;;;###autoload
(defun mega-search-project (&optional initial)
  "Search the project as you type, starting from INITIAL.
See the Commentary of mega-search.el for the keys of the prompt."
  (interactive)
  (let* ((directory (mega-project-directory))
         (mega-search--directory directory)
         (mega-search--backend (mega-search-backend-for directory))
         (mega-search--left-out (mega-project-left-out directory))
         (mega-search--export nil))
    (unless mega-search--backend
      (user-error "No search program found: install ripgrep, or use this in a git repository"))
    (let ((choice (mega-pick-read
                   (format "Search %s with %s: "
                           (file-name-nondirectory (directory-file-name directory))
                           (mega-search-backend-name mega-search--backend))
                   #'mega-search-run
                   :category 'mega-search
                   :initial initial
                   :history 'mega-search-history
                   :keymap mega-search-map)))
      (cond (mega-search--export
             (mega-search-results-buffer choice directory mega-search--backend))
            ((mega-search-visit choice directory))
            (t (message "No hit chosen"))))))

;;;###autoload
(defun mega-search-symbol ()
  "Search the project for the symbol at point."
  (interactive)
  (let ((symbol (thing-at-point 'symbol t)))
    (mega-search-project (and symbol (regexp-quote symbol)))))

(provide 'mega-search)
;;; mega-search.el ends here
