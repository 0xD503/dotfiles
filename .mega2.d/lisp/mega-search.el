;;; mega-search.el --- Search the project as you type  -*- lexical-binding: t; -*-

;;; Commentary:

;; `M-g a' searches the whole project and shows the hits while you type; RET
;; jumps to the highlighted one.  `M-g s' starts from the symbol at point.
;;
;; The search is done by whichever of these exists, best first:
;;
;;   rg       ripgrep, with --hidden
;;   git      `git grep --perl-regexp --line-number -I'
;;   grep     recursive GNU grep
;;
;; While the prompt is open, `C-o' followed by a letter changes how it
;; searches, and the list updates in place:
;;
;;   C-o c    case: smart -> ignore -> sensitive
;;   C-o u    include untracked files           (git)
;;   C-o i    include files that are ignored
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
;; The search always runs where the files are, on the host, even when the
;; project's tools live in a container.

;;; Code:

(require 'mega-lib)
(require 'mega-exec)
(require 'mega-pick)

(declare-function mega-project-root "mega-project")
(declare-function grep-mode "grep")

(defcustom mega-search-backend 'auto
  "Which program searches the project.
`auto' takes the first of rg, git and grep that can be used."
  :type '(choice (const auto) (const rg) (const git) (const grep))
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
(defvar mega-search-hidden t "Non-nil to include hidden files.")
(defvar mega-search-literal nil "Non-nil to take the pattern literally.")
(defvar mega-search-word nil "Non-nil to match whole words only.")

(defvar mega-search-history nil "What was searched for.")

(defvar mega-search--directory nil "Where the active search runs.")
(defvar mega-search--backend nil "The program the active search uses.")
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
  "The search programs usable in DIRECTORY, best first."
  (seq-filter (lambda (backend) (mega-search--usable-p backend directory))
              '(rg git grep)))

(defun mega-search-backend-for (directory)
  "The search program to use in DIRECTORY, or nil if there is none."
  (if (and (not (eq mega-search-backend 'auto))
           (mega-search--usable-p mega-search-backend directory))
      mega-search-backend
    (car (mega-search-backends directory))))

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
         ,@(when mega-search-ignored '("--no-ignore"))
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
         ,@(when (or mega-search-untracked mega-search-ignored) '("--untracked"))
         ,@(when mega-search-ignored '("--no-exclude-standard"))
         ,@(when mega-search-word '("--word-regexp"))
         "-e" ,pattern
         "--" ,@paths))
      ('grep
       `("grep" "--recursive" "--line-number" "--binary-files=without-match"
         "--color=never" "--exclude-dir=.git"
         ,(if mega-search-literal "--fixed-strings" "--perl-regexp")
         ,@(when ignore-case '("--ignore-case"))
         ,@(unless mega-search-hidden '("--exclude=.*" "--exclude-dir=.*"))
         ,@(when mega-search-word '("--word-regexp"))
         ,(concat "--regexp=" pattern)
         ,@(or paths '(".")))))))

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

(defun mega-search-describe ()
  "One line saying how the search currently works."
  (format "%s  case:%s%s%s%s%s%s"
          (or mega-search--backend "no search program")
          mega-search-case
          (if mega-search-untracked " +untracked" "")
          (if mega-search-ignored " +ignored" "")
          (if mega-search-hidden " +hidden" "")
          (if mega-search-literal " literal" "")
          (if mega-search-word " words" "")))

(defun mega-search--changed ()
  "Search again with the new settings, and say what they are."
  (mega-pick-refresh)
  (minibuffer-message "[%s]" (mega-search-describe)))

(defmacro mega-search--define-toggle (name variable doc)
  "Define command NAME that flips VARIABLE; DOC is its docstring."
  `(defun ,name ()
     ,doc
     (interactive)
     (setq ,variable (not ,variable))
     (mega-search--changed)))

(mega-search--define-toggle mega-search-toggle-untracked mega-search-untracked
                            "Include or leave out files git does not track.")
(mega-search--define-toggle mega-search-toggle-ignored mega-search-ignored
                            "Include or leave out ignored files.")
(mega-search--define-toggle mega-search-toggle-hidden mega-search-hidden
                            "Include or leave out hidden files.")
(mega-search--define-toggle mega-search-toggle-literal mega-search-literal
                            "Take the pattern literally, or as a regular expression.")
(mega-search--define-toggle mega-search-toggle-word mega-search-word
                            "Match whole words only, or anywhere.")

(defun mega-search-cycle-case ()
  "Change how case is treated: smart, then ignore, then sensitive."
  (interactive)
  (setq mega-search-case (pcase mega-search-case
                           ('smart 'ignore) ('ignore 'sensitive) (_ 'smart)))
  (mega-search--changed))

(defun mega-search-cycle-backend ()
  "Search with the next usable program."
  (interactive)
  (let* ((usable (mega-search-backends mega-search--directory))
         (rest (cdr (memq mega-search--backend usable))))
    (setq mega-search--backend (or (car rest) (car usable))))
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
  (let* ((directory (file-name-as-directory
                     (or (mega-project-root) default-directory)))
         (mega-search--directory directory)
         (mega-search--backend (mega-search-backend-for directory))
         (mega-search--export nil))
    (unless mega-search--backend
      (user-error "No search program found: install ripgrep, or use this in a git repository"))
    (let ((choice (mega-pick-read
                   (format "Search %s: "
                           (file-name-nondirectory (directory-file-name directory)))
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
