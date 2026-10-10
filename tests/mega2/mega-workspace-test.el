;;; mega-workspace-test.el --- Tests for mega-workspace.el and mega-home.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-workspace)
(require 'mega-home)
(require 'project)
(require 'ert-x)

(defvar mega-test-pwned)

(defmacro mega-workspace-test--session (dir &rest body)
  "Run BODY in a clean session: no files open, an empty workspace store.
DIR is bound to a fresh directory.  The sandbox is under the temporary
directory, which workspaces normally leave out, so that rule is pointed
elsewhere."
  (declare (indent 1))
  `(mega-test-with-directory ,dir
     (dolist (buffer (buffer-list))
       (when (buffer-file-name buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer)))
     (mega-test-with-directory store
       (let ((mega-workspace-directory store))
         (unwind-protect
             (progn ,@body)
           (dolist (buffer (buffer-list))
             (when (buffer-file-name buffer)
               (with-current-buffer buffer (set-buffer-modified-p nil))
               (kill-buffer buffer))))))))

(defun mega-workspace-test--open (dir name &rest lines)
  "Create NAME in DIR holding LINES, open it, and return the file name."
  (let ((file (apply #'mega-test-write (expand-file-name name dir) lines)))
    (find-file-noselect file)
    file))

;;;; What is recorded

(ert-deftest mega-workspace-records-ordinary-local-files-only ()
  (should (mega-workspace--recordable-p "/home/u/src/main.rs"))
  (should-not (mega-workspace--recordable-p nil))
  (should-not (mega-workspace--recordable-p "/ssh:host:/home/u/main.rs"))
  (should-not (mega-workspace--recordable-p "/home/u/app/.env"))
  (should-not (mega-workspace--recordable-p "/home/u/.ssh/config"))
  (should-not (mega-workspace--recordable-p "/home/u/repo/.git/COMMIT_EDITMSG"))
  (let ((mega-temporary-directories mega-test-temporary-directories))
    (should-not (mega-workspace--recordable-p "/tmp/scratch.txt"))))

(ert-deftest mega-workspace-the-saved-layout-names-only-what-is-recorded ()
  "A window on a secret, or one that showed a secret before, leaves no name."
  (mega-workspace-test--session dir
    (let ((plain (mega-workspace-test--open dir "plain.txt" "alpha" ""))
          (secret (mega-workspace-test--open dir "prod.tfvars" "token = 1" ""))
          (other (mega-workspace-test--open dir ".pgpass" "host:5432:db:u:pw" "")))
      (save-window-excursion
        (delete-other-windows)
        ;; The first window showed a secret and then an ordinary file...
        (switch-to-buffer (get-file-buffer other))
        (switch-to-buffer (get-file-buffer plain))
        ;; ...and the second one shows a secret now.
        (select-window (split-window-right))
        (switch-to-buffer (get-file-buffer secret))
        (let ((workspace (mega-workspace-capture "mine")))
          (mega-workspace-write workspace)
          (let ((saved (with-temp-buffer
                         (insert-file-contents (mega-workspace--file "mine"))
                         (buffer-string))))
            (should (string-match-p "plain\\.txt" saved))
            (should-not (string-match-p "tfvars" saved))
            (should-not (string-match-p "pgpass" saved))
            (should-not (string-match-p "prev-buffers\\|next-buffers" saved))
            (should-not (string-match-p "scratch" saved))))))))

(ert-deftest mega-workspace-a-cleaned-layout-still-comes-back ()
  (mega-workspace-test--session dir
    (let ((a (mega-workspace-test--open dir "a.txt" "alpha" "beta" ""))
          (b (mega-workspace-test--open dir "b.txt" "gamma" "")))
      (save-window-excursion
        (delete-other-windows)
        (switch-to-buffer (get-file-buffer b))
        (switch-to-buffer (get-file-buffer a))
        (select-window (split-window-right))
        (switch-to-buffer (get-file-buffer b))
        (let ((workspace (mega-workspace-capture "two")))
          (delete-other-windows)
          (mega-workspace-restore workspace)
          (should (equal (sort (mapcar (lambda (window)
                                         (buffer-name (window-buffer window)))
                                       (window-list))
                               #'string<)
                         '("a.txt" "b.txt"))))))))

(ert-deftest mega-workspace-a-long-name-still-gets-a-file ()
  "The path of a deep project is longer than a file name may be."
  (mega-workspace-test--session dir
    (let* ((long (concat "~/src/" (mapconcat #'identity (make-list 40 "a-deep-directory") "/") "/"))
           (other (concat long "x/")))
      (should (< (length (file-name-nondirectory (mega-workspace--file long))) 255))
      ;; Two long names that start alike do not share a file.
      (should-not (equal (mega-workspace--file long) (mega-workspace--file other)))
      (mega-workspace-write (list :name long :saved 1.0 :files '(("/a" 1))))
      (should (equal (plist-get (mega-workspace-read long) :name) long))
      (should (member long (mapcar (lambda (w) (plist-get w :name))
                                   (mega-workspace-all))))
      ;; A short one is still readable in a listing of the directory.
      (should (equal (file-name-nondirectory (mega-workspace--file "~/src/app/"))
                     "%7E%2Fsrc%2Fapp%2F.eld")))))

(ert-deftest mega-workspace-capture-records-files-and-cursor-positions ()
  (mega-workspace-test--session dir
    (let ((a (mega-workspace-test--open dir "a.txt" "alpha" "beta" ""))
          (b (mega-workspace-test--open dir "b.txt" "gamma" "")))
      (with-current-buffer (get-file-buffer a) (goto-char 7))
      (let ((workspace (mega-workspace-capture "mine")))
        (should (equal (plist-get workspace :name) "mine"))
        (should-not (plist-get workspace :automatic))
        (should (equal (sort (copy-sequence (plist-get workspace :files))
                             (lambda (x y) (string< (car x) (car y))))
                       (list (list a 7) (list b 1))))
        (should (equal (cdr (assoc "a.txt" (plist-get workspace :buffers))) a))
        (should (plist-get workspace :windows))))))

(ert-deftest mega-workspace-capture-is-nil-when-no-file-is-open ()
  (mega-workspace-test--session dir
    (should-not (mega-workspace-capture "empty"))))

(ert-deftest mega-workspace-a-private-file-is-never-recorded ()
  (mega-workspace-test--session dir
    (mega-workspace-test--open dir ".env" "TOKEN=x" "")
    (should-not (mega-workspace-capture "x"))
    (let ((plain (mega-workspace-test--open dir "main.c" "int x;" "")))
      (should (equal (mapcar #'car (plist-get (mega-workspace-capture "x") :files))
                     (list plain))))))

;;;; Storing

(ert-deftest mega-workspace-is-stored-and-read-back-unchanged ()
  (mega-workspace-test--session dir
    (mega-workspace-test--open dir "a.txt" "alpha" "")
    (let ((workspace (mega-workspace-capture "~/projects/some thing/")))
      (mega-workspace-write workspace)
      (should (equal (mega-workspace-read "~/projects/some thing/") workspace))
      ;; One plainly named file, inside the store, whatever the name was.
      (should (equal (directory-files mega-workspace-directory nil "\\.eld\\'")
                     '("%7E%2Fprojects%2Fsome%20thing%2F.eld"))))))

(ert-deftest mega-workspace-the-store-is-in-the-state-directory ()
  (should (file-in-directory-p (default-value 'mega-workspace-directory)
                               mega-state-dir)))

(ert-deftest mega-workspace-a-stored-file-is-read-never-evaluated ()
  (makunbound 'mega-test-pwned)
  (mega-workspace-test--session dir
    (dolist (content '("(progn (setq mega-test-pwned t))"
                       "(:name \"x\" :saved \"not a number\" :files nil)"
                       "(:name \"x\" :saved 1.0 :files ((\"/a\" . oops)))"
                       "this is not lisp ((("
                       ""))
      (mega-test-write (expand-file-name "bad.eld" mega-workspace-directory) content)
      (should-not (mega-workspace--read-file
                   (expand-file-name "bad.eld" mega-workspace-directory)))
      (should-not (mega-workspace-all)))
    (should-not (boundp 'mega-test-pwned))))

(ert-deftest mega-workspace-all-is-newest-first-and-last-is-automatic ()
  (mega-workspace-test--session dir
    (mega-workspace-write '(:name "old auto" :automatic t :saved 100.0 :files (("/a" 1))))
    (mega-workspace-write '(:name "new auto" :automatic t :saved 300.0 :files (("/a" 1))))
    (mega-workspace-write '(:name "named" :automatic nil :saved 900.0 :files (("/a" 1))))
    (should (equal (mapcar (lambda (w) (plist-get w :name)) (mega-workspace-all))
                   '("named" "new auto" "old auto")))
    (should (equal (plist-get (mega-workspace-last) :name) "new auto"))))

(ert-deftest mega-workspace-old-automatic-ones-are-pruned-named-ones-kept ()
  (mega-workspace-test--session dir
    (dotimes (i 6)
      (mega-workspace-write (list :name (format "auto %d" i) :automatic t
                                  :saved (float i) :files '(("/a" 1)))))
    (mega-workspace-write '(:name "named" :automatic nil :saved 0.5 :files (("/a" 1))))
    (let ((mega-workspace-keep-automatic 2))
      (mega-workspace--prune))
    (should (equal (sort (mapcar (lambda (w) (plist-get w :name)) (mega-workspace-all))
                         #'string<)
                   '("auto 4" "auto 5" "named")))))

;;;; Bringing one back

(ert-deftest mega-workspace-window-states-follow-renamed-buffers ()
  (let ((state '(leaf (buffer "a.txt" (point . 5))
                      (child (buffer "*grep*" (point . 1)))
                      (other . "a.txt"))))
    (should (equal (mega-workspace--rename-buffers state '(("a.txt" . "a.txt<2>")))
                   '(leaf (buffer "a.txt<2>" (point . 5))
                          (child (buffer " mega-workspace-gone: *grep*" (point . 1)))
                          (other . "a.txt"))))))

(ert-deftest mega-workspace-restore-opens-the-files-at-their-positions ()
  (mega-workspace-test--session dir
    (let ((a (mega-test-write (expand-file-name "a.txt" dir) "alpha" "beta" ""))
          (b (mega-test-write (expand-file-name "b.txt" dir) "gamma" "")))
      (save-window-excursion
        (should (= 2 (mega-workspace-restore
                      (list :name "w" :saved 1.0
                            :files (list (list a 7) (list b 3)
                                         (list (expand-file-name "gone.txt" dir) 1)))))))
      (should (= 7 (with-current-buffer (get-file-buffer a) (point))))
      (should (= 3 (with-current-buffer (get-file-buffer b) (point))))
      (should-not (get-file-buffer (expand-file-name "gone.txt" dir))))))

(ert-deftest mega-workspace-restore-closes-nothing ()
  (mega-workspace-test--session dir
    (let ((open (mega-workspace-test--open dir "open.txt" "unsaved" ""))
          (other (mega-test-write (expand-file-name "other.txt" dir) "x" "")))
      (with-current-buffer (get-file-buffer open) (insert "work in progress"))
      (save-window-excursion
        (mega-workspace-restore (list :name "w" :saved 1.0 :files (list (list other 1)))))
      (should (buffer-live-p (get-file-buffer open)))
      (should (buffer-modified-p (get-file-buffer open))))))

(ert-deftest mega-workspace-restore-refuses-private-and-remote-files ()
  "Even if a stored workspace names one, resuming does not open it."
  (mega-workspace-test--session dir
    (let ((secret (mega-test-write (expand-file-name ".env" dir) "TOKEN=x" "")))
      (save-window-excursion
        (should (zerop (mega-workspace-restore
                        (list :name "w" :saved 1.0
                              :files (list (list secret 1)
                                           (list "/ssh:nowhere.invalid:/etc/hosts" 1)))))))
      (should-not (get-file-buffer secret)))))

(ert-deftest mega-workspace-a-cursor-beyond-a-shortened-file-is-clamped ()
  (mega-workspace-test--session dir
    (let ((a (mega-test-write (expand-file-name "a.txt" dir) "short" "")))
      (save-window-excursion
        (mega-workspace-restore (list :name "w" :saved 1.0 :files (list (list a 9999)))))
      (should (= (with-current-buffer (get-file-buffer a) (point))
                 (with-current-buffer (get-file-buffer a) (point-max)))))))

;;;; The automatic workspace

(ert-deftest mega-workspace-the-session-is-saved-under-its-directory ()
  (mega-workspace-test--session dir
    (should-not (mega-workspace-save-session))
    (mega-workspace-test--open dir "a.txt" "alpha" "")
    (let ((workspace (mega-workspace-save-session)))
      (should (equal (plist-get workspace :name) (abbreviate-file-name dir)))
      (should (plist-get workspace :automatic))
      (should (equal (mega-workspace-last) workspace)))))

(ert-deftest mega-workspace-exit-saves-only-a-real-session ()
  (mega-workspace-test--session dir
    (mega-workspace-test--open dir "a.txt" "alpha" "")
    ;; A batch Emacs is a script, not a session to come back to.
    (mega-workspace--on-exit)
    (should-not (mega-workspace-all))
    (let ((noninteractive nil))
      (let ((mega-workspace-save-on-exit nil))
        (mega-workspace--on-exit)
        (should-not (mega-workspace-all)))
      (mega-workspace--on-exit)
      (should (= 1 (length (mega-workspace-all)))))
    (should (memq #'mega-workspace--on-exit kill-emacs-hook))))

(ert-deftest mega-workspace-a-failing-save-never-blocks-exit ()
  (let ((noninteractive nil))
    (cl-letf (((symbol-function 'mega-workspace-save-session)
               (lambda () (error "disk full"))))
      (mega-workspace--on-exit))))

;;;; Commands

(ert-deftest mega-workspace-save-then-resume ()
  (mega-workspace-test--session dir
    (let ((a (mega-workspace-test--open dir "a.txt" "alpha" "beta" "")))
      (with-current-buffer (get-file-buffer a) (goto-char 4))
      (save-window-excursion
        (mega-workspace-save "review")
        (kill-buffer (get-file-buffer a))
        (mega-test-with-scripted-prompt "review"
          (call-interactively #'mega-workspace-resume)))
      (should (= 4 (with-current-buffer (get-file-buffer a) (point)))))))

(ert-deftest mega-workspace-save-with-nothing-open-says-so ()
  (mega-workspace-test--session dir
    (should-error (mega-workspace-save "x") :type 'user-error)))

(ert-deftest mega-workspace-resume-with-nothing-saved-says-so ()
  (mega-workspace-test--session dir
    (should-error (call-interactively #'mega-workspace-resume) :type 'user-error)))

(ert-deftest mega-workspace-forget-asks-first ()
  (mega-workspace-test--session dir
    (mega-workspace-write '(:name "w" :saved 1.0 :files (("/a" 1))))
    ;; Replacing a built-in function makes Emacs compile a shim into the
    ;; temporary directory, so that has to be a real one here.
    (let ((temporary-file-directory (file-name-as-directory (getenv "TMPDIR"))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (mega-workspace-forget "w"))
      (should (mega-workspace-read "w"))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (mega-workspace-forget "w"))
      (should-not (mega-workspace-read "w")))))

;;;; The home page

(defmacro mega-workspace-test--home (projects &rest body)
  "Run BODY with PROJECTS as the recent projects and a clean store."
  (declare (indent 1))
  `(mega-workspace-test--session dir
     (cl-letf (((symbol-function 'project-known-project-roots)
                (lambda () ,projects)))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer mega-home-buffer)
           (kill-buffer mega-home-buffer))))))

(defun mega-workspace-test--page ()
  "The text of a freshly rendered home page."
  (with-current-buffer (mega-home-render)
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest mega-home-shows-how-long-emacs-took-to-start ()
  (mega-workspace-test--home nil
    (let ((before-init-time '(0 0)) (mega-home--started '(0 0 73000)))
      (should (= (mega-home-startup-time) 73.0))
      (should (string-match-p "started in 73 ms" (mega-workspace-test--page))))
    (let ((mega-home--started nil))
      (should-not (string-match-p "started in" (mega-workspace-test--page))))))

(ert-deftest mega-home-the-time-shown-is-the-time-waited ()
  "Up to the end of what MEGA put off until Emacs had started, not only
what Emacs calls init: that part ends before the hook has run."
  (let ((before-init-time (time-subtract (current-time) 2))
        (after-init-time (time-subtract (current-time) 1))
        (mega-home--started nil)
        (noninteractive t))
    ;; The hook that draws the page is the one that notes the time.
    (should (memq #'mega-home-at-startup emacs-startup-hook))
    (mega-home-at-startup)
    (should (> (mega-home-startup-time) 1999.0))
    (should (< (mega-home-startup-time) 2500.0))))

(ert-deftest mega-home-names-mega-and-emacs ()
  (mega-workspace-test--home nil
    (let ((page (mega-workspace-test--page)))
      (should (string-match-p (regexp-quote (format "MEGA %s" mega-version)) page))
      (should (string-match-p (regexp-quote (format "Emacs %s" emacs-version)) page)))))

(ert-deftest mega-home-with-nothing-to-continue-says-what-to-do ()
  (mega-workspace-test--home nil
    (let ((page (mega-workspace-test--page)))
      (should (string-match-p "Nothing to continue yet" page))
      (should-not (string-match-p "Continue\n" page))
      (should-not (string-match-p "Recent projects" page))
      (should (string-match-p "f open file" page)))))

(ert-deftest mega-home-offers-the-last-session ()
  (mega-workspace-test--home nil
    (mega-workspace-write (list :name "~/projects/thing/" :automatic t
                                :saved (- (float-time) 7200)
                                :files '(("/a" 1) ("/b" 1) ("/c" 1))))
    (let ((page (mega-workspace-test--page)))
      (should (string-match-p "Continue\n +r +~/projects/thing/ +3 files, closed 2 hours ago"
                              page)))))

(ert-deftest mega-home-lists-recent-projects-that-still-exist ()
  (mega-workspace-test--home (list dir "/nonexistent-project/" "/ssh:host:/remote/")
    (mega-workspace-write (list :name (abbreviate-file-name dir) :automatic t
                                :saved 1.0 :files '(("/a" 1) ("/b" 1))))
    (let ((page (mega-workspace-test--page)))
      (should (string-match-p
               (concat "Recent projects\n +1 +" (regexp-quote (abbreviate-file-name dir))
                       " +2 files in its workspace\n +2 +/ssh:host:/remote/")
               page))
      (should-not (string-match-p "nonexistent-project" page)))))

(ert-deftest mega-home-lists-at-most-nine-projects ()
  (mega-test-with-directory parent
    (let (roots)
      (dotimes (i 12)
        (let ((root (file-name-as-directory (expand-file-name (format "p%02d" i) parent))))
          (make-directory root)
          (push root roots)))
      (mega-workspace-test--home (reverse roots)
        (should (= 9 (length (mega-home-projects))))
        (let ((mega-home-projects 3))
          (should (= 3 (length (mega-home-projects)))))))))

(ert-deftest mega-home-age-reads-naturally ()
  (let ((now (float-time)))
    (should (equal (mega-home--age (- now 20)) "just now"))
    (should (equal (mega-home--age (- now 600)) "10 minutes ago"))
    (should (equal (mega-home--age (- now 10800)) "3 hours ago"))
    (should (equal (mega-home--age (- now 259200)) "3 days ago"))))

(ert-deftest mega-home-return-opens-what-the-line-offers ()
  (mega-workspace-test--home (list dir)
    (let (opened)
      (cl-letf (((symbol-function 'mega-home-open-project)
                 (lambda (root) (setq opened root))))
        (with-current-buffer (mega-home-render)
          ;; The cursor starts on the first thing that can be chosen.
          (mega-home-act)
          (should (equal opened dir))
          (goto-char (point-min))
          (should-error (mega-home-act) :type 'user-error))))))

(ert-deftest mega-home-a-digit-opens-that-project ()
  (mega-test-with-directory second
    (mega-workspace-test--home (list dir second)
      (let (opened)
        (cl-letf (((symbol-function 'mega-home-open-project)
                   (lambda (root) (setq opened root))))
          (let ((last-command-event ?2))
            (mega-home-open-nth))
          (should (equal opened second))
          (should-error (mega-home-open-nth 7) :type 'user-error))))))

(ert-deftest mega-home-opening-a-project-resumes-its-workspace ()
  (mega-workspace-test--home (list dir)
    (let ((a (mega-test-write (expand-file-name "a.txt" dir) "alpha" "beta" "")))
      (mega-workspace-write (list :name (abbreviate-file-name dir) :automatic t
                                  :saved 1.0 :files (list (list a 7))))
      (save-window-excursion
        (mega-home-open-project dir))
      (should (= 7 (with-current-buffer (get-file-buffer a) (point)))))))

(ert-deftest mega-home-opening-a-project-without-one-asks-for-a-file ()
  (mega-workspace-test--home (list dir)
    (let (asked-in)
      (cl-letf (((symbol-function 'project-find-file)
                 (lambda (&rest _) (setq asked-in default-directory))))
        (mega-home-open-project dir))
      (should (equal asked-in dir)))))

(ert-deftest mega-home-continue-resumes-the-last-session ()
  (mega-workspace-test--home nil
    (should-error (mega-home-continue) :type 'user-error)
    (let ((a (mega-test-write (expand-file-name "a.txt" dir) "alpha" "")))
      (mega-workspace-write (list :name "last" :automatic t :saved 1.0
                                  :files (list (list a 3))))
      (save-window-excursion
        (mega-home-continue))
      (should (get-file-buffer a)))))

(ert-deftest mega-home-every-key-on-the-page-is-bound ()
  (dolist (key '("r" "1" "9" "f" "p" "w" "?" "d" "g" "q" "RET"))
    (should (commandp (lookup-key mega-home-mode-map (kbd key))))))

(ert-deftest mega-home-is-read-only-and-opens-nothing-by-itself ()
  (mega-workspace-test--home (list dir)
    (let ((before (length (buffer-list))))
      (with-current-buffer (mega-home-render)
        (should buffer-read-only)
        (should (derived-mode-p 'special-mode)))
      ;; Only the page itself is new: no project file was touched.
      (should (<= (length (buffer-list)) (1+ before))))))

(ert-deftest mega-home-opens-only-when-emacs-was-given-nothing ()
  (should (memq #'mega-home-at-startup emacs-startup-hook))
  ;; A batch Emacs never gets the page.
  (should-not (mega-home--wanted-p))
  (mega-workspace-test--session dir
    (save-window-excursion
      (let ((noninteractive nil))
        (switch-to-buffer (get-buffer-create "*scratch*"))
        (delete-other-windows)
        (should (mega-home--wanted-p))
        (let ((mega-home-at-startup nil))
          (should-not (mega-home--wanted-p)))
        (let ((initial-buffer-choice t))
          (should-not (mega-home--wanted-p)))
        ;; A file named on the command line is open by now.
        (mega-workspace-test--open dir "given.txt" "x" "")
        (should-not (mega-home--wanted-p))))))

(provide 'mega-workspace-test)
;;; mega-workspace-test.el ends here
