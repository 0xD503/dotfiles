;;; mega-bench.el --- How long the things you wait for take  -*- lexical-binding: t; -*-

;;; Commentary:

;; Not an ERT file.  `tests/test_mega2.sh bench' loads it after the real init
;; files, in the same sandbox as the tests, and it times the paths of MEGA
;; that a person waits on: a keystroke, the modeline, the completion menu,
;; listing and finding a file, a search, a save, the undo tree, a debugger
;; message, the first start of a language server.
;;
;; Each benchmark is expected to take a certain time, in milliseconds: what
;; it took on the machine the figures were set on.  Those figures are not in
;; this file.  They are in mega-bench-history.eld, each with the commit that
;; made it what it is and the reason, and the top of that file says what is
;; expected of whoever finds a benchmark over its time: find the cause; fix
;; it; and only if the slowdown is the reasonable, direct and minimised
;; price of a change that is wanted, record the new time, the commit and
;; the reason.
;;
;; The run prints every time next to its figure, and how many times the one
;; is of the other, so a slowdown shows as soon as it is there.  Over one and a half times the
;; expected, a line is marked SLOW: the run still passes, and somebody
;; should look.  Over three times, the run fails.  Three, because a tighter
;; limit fails on a machine that is merely busy, and a looser one lets a
;; real slowdown through.
;;
;; What makes a figure set on one machine mean something on another:
;;
;; * Two fixed pieces of work are timed first, one that is all Lisp
;;   (`mega-bench--reference') and one that is all starting programs and
;;   reading files (`mega-bench--process-reference').  However many times
;;   longer than on the reference machine they take, the expectations are
;;   stretched by that much: by the first for a benchmark that computes, by
;;   the larger of the two for one that runs programs or uses the disk.
;;   Expectations are never shrunk.
;;
;; * A benchmark that fails is not believed at once.  The two pieces of
;;   work are timed again, there and then, and the benchmark is run again;
;;   it has failed if it is over the limit both times.  A machine that got
;;   busy halfway does not fail the run; code that got slower does.
;;
;; * Memory is collected as in a running session: every
;;   `mega-gc-cons-threshold' bytes.  Emacs is told never to collect while
;;   it starts, and a batch Emacs never gets to the hook that ends that, so
;;   it is ended here.  The time a collection takes inside a benchmark is
;;   part of its time, and is shown.
;;
;; The price of the first point is that this measures MEGA against Emacs on
;; the same machine at the same moment, not against the clock on the wall;
;; that is the comparison that says whether MEGA's own code got slower.
;;
;; MEGA's Lisp is timed as source.  A session runs it that way only until
;; its compiled copy is made, and faster ever after; but source is the form
;; every machine has from the first start, the slowest there is, and the
;; one in which a slowdown in MEGA's own code shows most.
;;
;;   MEGA_BENCH_ONLY=regexp  run the benchmarks whose names match, as when
;;                           looking for the commit that made one slower
;;   MEGA_BENCH_SCALE=2      multiply every expectation once more, by hand
;;   MEGA_BENCH_TOLERANCE=4  fail at four times the expected, not three
;;   MEGA_BENCH_SAVE=file    write the times of this run to FILE
;;   MEGA_BENCH_COMPARE=file compare with a saved run as well, and fail when
;;                           something is more than twice as slow as it was
;;                           (or MEGA_BENCH_TOLERANCE times), the speed of
;;                           the machine at each run allowed for
;;
;; So, before a change that might cost time: save a run.  After it: compare.
;;
;; Start-up has its own budget in the boot stage; it is not timed here.
;;
;; A benchmark is a function that prepares what it needs and returns the
;; function to time.  Preparation is not timed.  The best of three rounds
;; counts.  The timed function may return (:ms N :note TEXT) to report a
;; time of its own instead of the clock's, with a word about it, or
;; (:skip TEXT) when what it needs is not on this machine.
;;
;; To add one: `mega-bench-define', a name that says what a person does,
;; and the function.  Run the stage: it says the benchmark has no record,
;; and prints the one to put into mega-bench-history.eld once the benchmark
;; is committed.  A piece of work that takes under a few milliseconds is too
;; small to time: make it do the thing a hundred times.  Order matters only
;; for the first, which must run before anything has loaded the modules it
;; times.

;;; Code:

(require 'mega-test-helper)

(defvar mega-bench--list nil
  "The benchmarks, newest first: (NAME FUNCTION . OPTIONS).")

(defun mega-bench-define (name function &rest options)
  "Define the benchmark NAME.
What it is expected to take is not said here but in the history file:
see `mega-bench-history-file'.  FUNCTION prepares the work and returns
the function that does it; only the latter is timed.  OPTIONS is a
plist:

  :rounds   how often that is done, by default 3; the best time counts
  :kind     `process' for work that starts programs or uses the disk,
            which the speed of Lisp says little about"
  (push (append (list name function) options) mega-bench--list))

;;;; What is expected, and how it came to be

(defconst mega-bench-history-file
  (expand-file-name "mega-bench-history.eld" mega-test-dir)
  "The file that holds what each benchmark is expected to take.
Its commentary gives the format, and the rule for changing a figure.")

(defconst mega-bench-machine-entries
  '("the reference machine: computing" "the reference machine: programs and disk")
  "The two entries of the history that are not benchmarks.
They are what `mega-bench--reference' and `mega-bench--process-reference'
took on the machine the figures were set on.")

(defvar mega-bench--history 'unread
  "The history as read: an alist (NAME RECORD...), or `unread'.")

(defun mega-bench-history ()
  "The history: an alist (NAME RECORD...), each record a plist, oldest first."
  (when (eq mega-bench--history 'unread)
    (setq mega-bench--history
          (condition-case nil
              (with-temp-buffer
                (insert-file-contents mega-bench-history-file)
                (read (current-buffer)))
            (error nil))))
  mega-bench--history)

(defun mega-bench-established (name)
  "The record NAME is held to: the last in its entry of the history, or nil."
  (car (last (cdr (assoc name (mega-bench-history))))))

(defun mega-bench--commit-known-p (commit)
  "Whether the checked-out history contains COMMIT: `yes', `no', or nil.
Nil means it could not be asked: no git, or no repository here."
  (let ((default-directory mega-test-dir))
    (condition-case nil
        (cond ((not (eql 0 (call-process "git" nil nil nil "rev-parse" "--git-dir")))
               nil)
              ((eql 0 (call-process "git" nil nil nil "merge-base" "--is-ancestor"
                                    (concat commit "^{commit}") "HEAD"))
               'yes)
              (t 'no))
      (error nil))))

(defun mega-bench-history-problems (&optional names)
  "What is wrong with the history, as a list of strings; nil if nothing is.
NAMES are the benchmarks there are, by default those defined.  A figure
is only as good as its record: every benchmark has an entry, every entry
a benchmark, every record says when, in which commit and why, the dates
do not go backwards, and every commit is one the repository has."
  (let ((names (or names (mapcar #'car mega-bench--list)))
        (history (mega-bench-history))
        (problems nil)
        (asked (make-hash-table :test #'equal)))
    (cl-flet ((problem (format-string &rest arguments)
                (push (apply #'format format-string arguments) problems)))
      (cond
       ((not (and history (listp history)))
        (problem "%s cannot be read" (file-name-nondirectory mega-bench-history-file)))
       (t
        (dolist (name (append mega-bench-machine-entries names))
          (unless (assoc name history)
            (problem "`%s' has no record of what it is expected to take" name)))
        (dolist (entry history)
          (let ((name (car-safe entry))
                (records (cdr-safe entry))
                (before nil))
            (cond
             ((not (and (stringp name) (consp records)))
              (problem "an entry is not a name and its records: %S" entry))
             (t
              (unless (or (member name names) (member name mega-bench-machine-entries))
                (problem "`%s' is in the history, and no benchmark is called that: a benchmark that is renamed takes its history along" name))
              (when (cdr (seq-filter (lambda (other) (equal (car-safe other) name)) history))
                (problem "`%s' has two entries" name))
              (dolist (record records)
                (let ((ms (plist-get record :ms))
                      (limit (plist-get record :limit))
                      (date (plist-get record :date))
                      (commit (plist-get record :commit))
                      (reason (plist-get record :reason)))
                  (unless (and (numberp ms) (> ms 0))
                    (problem "`%s': a record without a time: %S" name record))
                  (unless (or (null limit) (and (numberp limit) (numberp ms) (>= limit ms)))
                    (problem "`%s': a limit that is no number, or under the time: %S" name record))
                  (if (not (and (stringp date)
                                (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\'" date)))
                      (problem "`%s': a record without its date, as YYYY-MM-DD: %S" name record)
                    (when (and before (string< date before))
                      (problem "`%s': the record of %s comes after that of %s" name date before))
                    (setq before date))
                  (unless (and (stringp reason) (not (string-blank-p reason)))
                    (problem "`%s': the record of %s gives no reason" name date))
                  (if (not (and (stringp commit)
                                (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" commit)))
                      (problem "`%s': the record of %s names no commit" name date)
                    (when (eq 'no (or (gethash commit asked)
                                      (puthash commit
                                               (or (mega-bench--commit-known-p commit)
                                                   'unknown)
                                               asked)))
                      (problem "`%s': the record of %s names commit %s, which is not in the history of what is checked out"
                               name date commit))))))))))))
    (nreverse problems)))

(defun mega-bench--time (function)
  "Call FUNCTION and return how long it took: (MILLISECONDS . NOTE).
What FUNCTION reports itself, as (:ms N :note TEXT), wins over the
clock.  A collection of memory during the call is noted.  If FUNCTION
returns (:skip TEXT), so does this."
  (let* ((collecting gc-elapsed)
         (start (float-time))
         (value (funcall function))
         (elapsed (* 1000.0 (- (float-time) start)))
         (collected (* 1000.0 (- gc-elapsed collecting))))
    (cond ((eq (car-safe value) :skip) value)
          ((eq (car-safe value) :ms)
           (cons (plist-get value :ms) (plist-get value :note)))
          (t (cons elapsed
                   (and (> collected 0.05)
                        (format "%.0f ms of it collecting memory" collected)))))))

(defun mega-bench--measure (benchmark)
  "The best time of BENCHMARK: (MILLISECONDS . NOTE), or (:skip TEXT)."
  (let ((best nil) (skipped nil))
    ;; What the benchmark before this one left behind is not this one's.
    (garbage-collect)
    (dotimes (_ (or (plist-get (nthcdr 2 benchmark) :rounds) 3))
      (unless skipped
        (let ((time (mega-bench--time (funcall (nth 1 benchmark)))))
          (cond ((eq (car time) :skip) (setq skipped time))
                ((or (null best) (< (car time) (car best)))
                 (setq best time))))))
    (or skipped best)))

;;;; How fast the machine is right now

(defun mega-bench-reference-ms ()
  "What `mega-bench--reference' takes on the machine the figures were set on."
  (or (plist-get (mega-bench-established (nth 0 mega-bench-machine-entries)) :ms)
      (error "The history does not say what the reference machine does")))

(defun mega-bench-process-reference-ms ()
  "What `mega-bench--process-reference' takes on that machine."
  (or (plist-get (mega-bench-established (nth 1 mega-bench-machine-entries)) :ms)
      (error "The history does not say what the reference machine does")))

(defun mega-bench--reference ()
  "A fixed piece of work of the kind MEGA does: strings, lists, a regexp."
  (let ((words nil) (count 0))
    (dotimes (index 40000)
      (let ((word (format "module%05d/file%d.rs" (% (* index 7919) 100000) index)))
        (when (string-match "\\([0-9]+\\)/file\\([0-9]+\\)" word)
          (setq count (+ count (length (match-string 2 word)))))
        (push word words)))
    (setq words (sort words #'string<))
    (dolist (word words)
      (when (string-prefix-p "module0" word)
        (setq count (1+ count))))
    count))

(defun mega-bench--process-reference ()
  "A fixed piece of work that is all starting programs and using the disk.
Done with Emacs's own means, not with MEGA's: it is what MEGA's way of
running a program is measured against."
  (let ((file (expand-file-name "bench-reference" (getenv "MEGA_TEST_SANDBOX"))))
    (dotimes (_ 20)
      (call-process "true" nil nil nil)
      (with-temp-file file (insert (make-string 4096 ?x)))
      (with-temp-buffer (insert-file-contents file)))))

(defun mega-bench--best-of-three (function)
  "The best of three times of FUNCTION, in milliseconds."
  (let ((best nil))
    (dotimes (_ 3)
      (let ((time (car (mega-bench--time function))))
        (when (or (null best) (< time best))
          (setq best time))))
    best))

(defun mega-bench--machine ()
  "How slow this machine is right now, against the reference machine.
A plist: :lisp and :process are factors, at least 1; :lisp-ms and
:process-ms are the times they come from."
  (let ((lisp (mega-bench--best-of-three #'mega-bench--reference))
        (process (mega-bench--best-of-three #'mega-bench--process-reference)))
    (list :lisp (max 1.0 (/ lisp (mega-bench-reference-ms)))
          :process (max 1.0 (/ process (mega-bench-process-reference-ms)))
          :lisp-ms lisp :process-ms process)))

(defun mega-bench--factor (benchmark machine)
  "By how much MACHINE stretches what BENCHMARK is expected to take."
  (if (eq (plist-get (nthcdr 2 benchmark) :kind) 'process)
      (max (plist-get machine :lisp) (plist-get machine :process))
    (plist-get machine :lisp)))

(defun mega-bench--limit (record tolerance)
  "The time over which a benchmark held to RECORD has failed.
On the reference machine: its own :limit if the record states one; else
TOLERANCE times what it is expected to take, and never less than two
milliseconds over that, below which the clock is the noise."
  (let ((expected (plist-get record :ms)))
    (or (plist-get record :limit)
        (max (* tolerance expected) (+ expected 2.0)))))

;;;; What is timed

(defun mega-bench--directory (name)
  "A fresh directory in the sandbox whose name starts with NAME."
  (file-name-as-directory
   (make-temp-file (expand-file-name name (getenv "MEGA_TEST_SANDBOX")) t)))

(defun mega-bench--source (lines)
  "LINES lines of something shaped like code, indented and commented."
  (let ((text nil))
    (dotimes (index lines)
      (push (pcase (% index 8)
              (0 (format "fn function_%d(argument: usize) -> usize {\n" index))
              (1 "    // TODO: say what this is for\n")
              (2 "    let mut total = 0;\n")
              (3 "    for index in 0..argument {\n")
              (4 "        if index % 2 == 0 {\n")
              (5 (format "            total += index * %d;  \n" index))
              (6 "        }\n    }\n")
              (_ "    total\n}\n\n"))
            text))
    (apply #'concat (nreverse text))))

;; First, before anything below loads a module: what the first press of a
;; key costs when its module has waited for that press.
(mega-bench-define
 "first use of a feature: load its module (slowest)"
 (lambda ()
   (let ((modules (seq-remove #'featurep (mapcar #'car mega-lazy-modules))))
     (lambda ()
       (let ((slowest 0) (which nil))
         (dolist (module modules)
           (let ((start (float-time)))
             (require module)
             (when (> (- (float-time) start) slowest)
               (setq slowest (- (float-time) start)
                     which module))))
         ;; The time that counts is the slowest module, not their sum.
         (list :ms (* 1000.0 slowest) :note (format "%s" which))))))
 :rounds 1 :kind 'process)

(defun mega-bench--type (buffer after-each)
  "Type 1000 characters at the end of BUFFER, then discard it.
Around each one, what MEGA does around every character: note the change
for trimming, and schedule the completion menu.  AFTER-EACH, if non-nil,
is called after each character as well."
  (unwind-protect
      (with-current-buffer buffer
        (goto-char (point-max))
        (let ((this-command 'self-insert-command)
              (last-command-event ?x))
          (dotimes (_ 1000)
            (run-hooks 'pre-command-hook)
            (self-insert-command 1)
            (mega-complete--post-command)
            (run-hooks 'post-command-hook)
            (when after-each (funcall after-each)))))
    (when (timerp (bound-and-true-p mega-complete--timer))
      (cancel-timer mega-complete--timer))
    (with-current-buffer buffer (set-buffer-modified-p nil))
    (kill-buffer buffer)))

(mega-bench-define
 "type 1000 characters in code"
 (lambda ()
   (require 'mega-complete)
   (require 'mega-edit)
   (let ((buffer (generate-new-buffer " *mega-bench*")))
     (with-current-buffer buffer
       (prog-mode)
       (insert (mega-bench--source 400)))
     (lambda () (mega-bench--type buffer nil)))))

(mega-bench-define
 "type 1000 characters in Rust, each one highlighted"
 (lambda ()
   (require 'mega-complete)
   (require 'mega-edit)
   (require 'mega-mode-rust)
   (require 'mega-indent-guides)
   (let ((buffer (generate-new-buffer " *mega-bench*")))
     (with-current-buffer buffer
       (insert (mega-bench--source 400))
       (mega-rust-mode)
       (mega-indent-guides-mode 1)
       (font-lock-ensure))
     (lambda ()
       ;; What the screen does after a key: the changed line is highlighted
       ;; again, guides and all.
       (mega-bench--type buffer
                         (lambda ()
                           (font-lock-fontify-region (line-beginning-position)
                                                     (line-end-position))))))))

(mega-bench-define
 "modeline: what MEGA works out for it, 5000 times"
 (lambda ()
   (require 'mega-ui)
   (require 'mega-trust)
   (let* ((directory (mega-bench--directory "bench-modeline-"))
          (inhibit-message t)
          (buffer (progn
                    (mega-test-write (expand-file-name "Cargo.toml" directory)
                                     "[package]" "")
                    (find-file-noselect
                     (mega-test-write (expand-file-name "src/main.rs" directory)
                                      "fn main() {}" ""))))
          ;; A batch Emacs has no modeline to draw.  What MEGA adds to each
          ;; drawing is the forms it put into the format, so those are run.
          (forms (mapcar #'cadr
                         (seq-filter (lambda (element) (eq (car-safe element) :eval))
                                     (default-value 'mode-line-format)))))
     (unless (>= (length forms) 3)
       (error "The modeline is not the one this benchmark knows"))
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (dotimes (_ 5000)
               (dolist (form forms) (eval form t))
               (bound-and-true-p mega-trust-held)))
         (kill-buffer buffer))))))

(mega-bench-define
 "completion menu: choose from 5000 candidates"
 (lambda ()
   (require 'mega-complete)
   (let ((table (mapcar (lambda (index) (format "mega_candidate_%04d" index))
                        (number-sequence 1 5000))))
     (lambda ()
       (with-temp-buffer
         (insert "mega_c")
         (let ((found (mega-complete-candidates (point-min) (point-max) table nil)))
           (unless (cdr found) (error "No candidates"))))))))

(mega-bench-define
 "completion menu: draw it 300 times"
 (lambda ()
   (require 'mega-complete)
   (require 'mega-popup)
   (let ((candidates (mapcar (lambda (index) (format "candidate_number_%03d" index))
                             (number-sequence 1 12)))
         (buffer (generate-new-buffer " *mega-bench-popup*")))
     (lambda ()
       (unwind-protect
           ;; Everything about drawing it short of the terminal: the lines,
           ;; where it goes, and the text with its faces.
           (dotimes (index 300)
             (mega-popup-geometry 40 10 60 12 120 40)
             (mega-popup--fill buffer (mega-complete-lines candidates) 60 (% index 12)))
         (kill-buffer buffer))))))

(defvar mega-bench--tree nil
  "A project without version control, made once: 3000 files and a build.")

(defun mega-bench--tree ()
  "The directory of `mega-bench--tree', made on first use."
  (or mega-bench--tree
      (let ((directory (mega-bench--directory "bench-tree-")))
        (mega-test-write (expand-file-name "Cargo.toml" directory) "[package]" "")
        (dotimes (index 3000)
          (mega-test-write (expand-file-name (format "crates/part%02d/src/file%04d.rs"
                                                     (% index 30) index)
                                             directory)
                           "fn f() {}" "")
          (mega-test-write (expand-file-name (format "target/debug/deps/unit%04d.d" index)
                                             directory)
                           "x" ""))
        (setq mega-bench--tree directory))))

(mega-bench-define
 "project files: list 3000, pass over 3000 built ones"
 (lambda ()
   (require 'mega-project)
   (let ((directory (mega-bench--tree)))
     (lambda ()
       (unless (= (length (mega-project-list-files directory)) 3001)
         (error "The list is not the 3000 sources and the manifest")))))
 :kind 'process)

(mega-bench-define
 "narrow 100,000 file names at the prompt (Emacs's flex)"
 (lambda ()
   (let ((paths nil))
     (dotimes (index 100000)
       (push (format "crates/part%02d/src/module%03d/file%05d.rs"
                     (% index 40) (% index 500) index)
             paths))
     (push "src/bin/main.rs" paths)
     (lambda ()
       ;; Not MEGA's code, but MEGA's choice: `flex' is the style its
       ;; prompts match with, and this is what that choice costs.
       (let* ((completion-styles '(flex))
              (found (completion-all-completions "srcmain" paths nil 7)))
         (unless (consp found) (error "No match")))))))

(mega-bench-define
 "search: show 2000 hits"
 (lambda ()
   (require 'mega-search)
   (let ((lines (mapcar (lambda (index)
                          (format "src/part%02d/file%04d.rs:%d:    let needle = value_%d;"
                                  (% index 30) index (* 3 index) index))
                        (number-sequence 1 2000))))
     (lambda ()
       (unless (= (length (delq nil (mapcar #'mega-search--present lines))) 2000)
         (error "Hits were lost"))))))

(mega-bench-define
 "search: a real one, 300 files, with grep"
 (lambda ()
   (require 'mega-search)
   (let ((directory (mega-bench--directory "bench-search-")))
     (dotimes (index 300)
       (mega-test-write (expand-file-name (format "src/file%03d.txt" index) directory)
                        "one line" (format "the needle is in file %d" index) "last line" ""))
     (lambda ()
       (unless (= (length (mega-search-run "needle" directory 'grep 1000)) 300)
         (error "Hits were lost")))))
 :kind 'process)

(mega-bench-define
 "run a program and wait for it, ten times"
 (lambda ()
   (require 'mega-exec)
   (lambda ()
     (dotimes (_ 10)
       (unless (eql (plist-get (mega-exec-run "true" nil) :status) 0)
         (error "The program failed")))))
 :kind 'process)

(mega-bench-define
 "copy to and paste from the clipboard, ten times"
 (lambda ()
   (require 'mega-edit)
   (let ((text (make-string 20000 ?x)))
     (lambda ()
       ;; Stand-ins for the clipboard programs: yours is not touched.
       (cl-letf (((symbol-function 'mega-clipboard--tool)
                  (lambda () '(("sh" "-c" "cat > /dev/null")
                               . ("printf" "%s" "from the clipboard")))))
         (let ((mega-clipboard--last nil)
               (copies nil))
           (dotimes (_ 10)
             (push (mega-clipboard-copy text) copies)
             (unless (equal (mega-clipboard-paste) "from the clipboard")
               (error "Nothing came back from the clipboard")))
           ;; Copying does not wait for its program; this run does, so
           ;; that none is left behind.
           (while (seq-some (lambda (copy) (and (processp copy) (process-live-p copy)))
                            copies)
             (accept-process-output nil 0.01)))))))
 :kind 'process)

(mega-bench-define
 "format a 2000-line buffer on save"
 (lambda ()
   (require 'mega-format)
   (let ((text (mega-bench--source 2000)))
     (lambda ()
       (with-temp-buffer
         (insert text)
         ;; A formatter that changes one line in eight, as a real one might.
         (unless (eq (mega-format-run '("sed" "s/  *$//")) 'changed)
           (error "The formatter did not change the buffer"))))))
 :kind 'process)

(dolist (mode '(mega-rust-mode mega-zig-mode mega-markdown-mode))
  (mega-bench-define
   (format "open 4000 lines, highlighted: %s" mode)
   (lambda ()
     (require 'mega-mode-rust)
     (require 'mega-mode-zig)
     (require 'mega-mode-markdown)
     (let ((text (mega-bench--source 4000)))
       (lambda ()
         (with-temp-buffer
           (insert text)
           (funcall mode)
           (font-lock-ensure)))))))

(mega-bench-define
 "indentation guides over 4000 lines"
 (lambda ()
   (require 'mega-indent-guides)
   (let ((text (mega-bench--source 4000)))
     (lambda ()
       (with-temp-buffer
         (insert text)
         (prog-mode)
         (mega-indent-guides-mode 1)
         (font-lock-ensure))))))

(mega-bench-define
 "save a file after a small edit, ten times"
 (lambda ()
   (require 'mega-undo)
   (let* ((file (expand-file-name "small.txt" (mega-bench--directory "bench-save-")))
          (buffer (progn (mega-test-write file (mega-bench--source 500))
                         (find-file-noselect file))))
     (lambda ()
       (let ((inhibit-message t))
         (unwind-protect
             (with-current-buffer buffer
               (dotimes (_ 10)
                 (goto-char (point-max))
                 (insert "one more line  \n")
                 (save-buffer)))
           (kill-buffer buffer))))))
 :kind 'process)

(defun mega-bench--long-history (buffer)
  "Give BUFFER about a megabyte of undo history."
  (with-current-buffer buffer
    (let ((line (concat (make-string 99 ?x) "\n")))
      (dotimes (_ 5000)
        (insert line)
        (undo-boundary)
        (delete-region (- (point) 100) (point))
        (undo-boundary))
      (insert line))))

(mega-bench-define
 "save a file with a megabyte of undo history"
 (lambda ()
   (require 'mega-undo)
   (let* ((file (expand-file-name "long.txt" (mega-bench--directory "bench-undo-")))
          (buffer (find-file-noselect file)))
     (mega-bench--long-history buffer)
     (lambda ()
       (let ((inhibit-message t))
         (unwind-protect
             (with-current-buffer buffer (save-buffer))
           (kill-buffer buffer))))))
 :kind 'process)

(mega-bench-define
 "open a file and get its undo history back"
 (lambda ()
   (require 'mega-undo)
   (let* ((inhibit-message t)
          (file (expand-file-name "long.txt" (mega-bench--directory "bench-undo-")))
          (buffer (find-file-noselect file)))
     (mega-bench--long-history buffer)
     (with-current-buffer buffer (save-buffer))
     (kill-buffer buffer)
     (lambda ()
       (with-current-buffer (find-file-noselect file)
         (unwind-protect
             (unless (consp buffer-undo-list)
               (error "The history did not come back"))
           (kill-buffer (current-buffer)))))))
 :kind 'process)

(defun mega-bench--branchy-buffer (changes)
  "A buffer with CHANGES changes and a branch in its history every tenth."
  (let ((buffer (generate-new-buffer " *mega-bench-undo*"))
        (inhibit-message t))
    (with-current-buffer buffer
      (buffer-enable-undo)
      (dotimes (index changes)
        (undo-boundary)
        (insert (format "%d\n" index))
        (when (= (% index 10) 9)
          (undo-boundary)
          (let ((last-command nil)) (undo 1))))
      (undo-boundary))
    buffer))

(mega-bench-define
 "undo tree: draw a history of 2000 changes"
 (lambda ()
   (require 'mega-undo-tree)
   (let ((buffer (mega-bench--branchy-buffer 2000)))
     (lambda ()
       (unwind-protect
           (let* ((tree (plist-get (mega-undo-tree--read buffer) :tree))
                  (places (mega-undo-tree-layout tree)))
             (mega-undo-tree-lines tree places (mega-undo-tree-current tree)
                                   (mega-undo-tree-glyphs)))
         (kill-buffer buffer))))))

(mega-bench-define
 "undo tree: twenty moves in a history of 2000 changes"
 (lambda ()
   (require 'mega-undo-tree)
   (let ((buffer (mega-bench--branchy-buffer 2000)))
     (lambda ()
       (unwind-protect
           (dotimes (_ 10)
             (mega-undo-tree-go buffer #'mega-undo-tree-parent)
             (mega-undo-tree-go buffer #'mega-undo-tree-child))
         (kill-buffer buffer))))))

(mega-bench-define
 "debugger: take in 1000 messages"
 (lambda ()
   (require 'mega-dap)
   (let ((bytes (mapconcat
                 (lambda (index)
                   (mega-dap-encode
                    (list :seq index :type "event" :event "output"
                          :body (list :category "stdout"
                                      :output (format "line %d of output\n" index)))))
                 (number-sequence 1 1000) "")))
     (lambda ()
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (insert bytes)
         (unless (= (length (mega-dap-take (current-buffer))) 1000)
           (error "Messages were lost")))))))

(mega-bench-define
 "draw the home page 50 times"
 (lambda ()
   (require 'mega-home)
   (require 'mega-workspace)
   (require 'project)
   ;; The same page every time, whatever ran before: nine recent projects,
   ;; each with a saved workspace, as after some weeks of use.
   (let* ((base (mega-bench--directory "bench-home-"))
          (store (mega-bench--directory "bench-home-store-"))
          (roots (mapcar (lambda (index)
                           (let ((root (expand-file-name (format "project%d/" index) base)))
                             (make-directory root t)
                             (abbreviate-file-name root)))
                         (number-sequence 1 9))))
     (let ((mega-workspace-directory store))
       (dolist (root roots)
         (mega-workspace-write (list :name root :automatic t :saved (float-time)
                                     :files (list (list (expand-file-name "main.rs" root)
                                                        1))))))
     (lambda ()
       (let ((mega-workspace-directory store)
             (project--list (mapcar #'list roots)))
         (dotimes (_ 50)
           (let ((buffer (mega-home-render)))
             (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(mega-bench-define
 "draw the cheat sheet 20 times"
 (lambda ()
   (require 'mega-help)
   (lambda ()
     (dotimes (_ 20)
       (with-temp-buffer (mega-help--insert))))))

;; Last, because it loads eglot, and nothing above should have had it.
(mega-bench-define
 "language server: load eglot and connect, first time"
 (lambda ()
   (lambda ()
     (if (not (executable-find "python3"))
         (list :skip "python3, which the stand-in server needs, is not installed")
       (require 'mega-lang)
       (require 'mega-trust)
       (let* ((project (mega-bench--directory "bench-lsp-"))
              (file (mega-test-write (expand-file-name "main.rs" project)
                                     "fn main() {}" ""))
              (mega-languages
               `((rust :plain mega-rust-mode :patterns ("\\.rs\\'")
                       :servers (("python3" ,(expand-file-name "fake-language-server.py"
                                                               mega-test-dir))))))
              (mega-trust-file (expand-file-name "trusted.eld"
                                                 (mega-bench--directory "bench-lsp-store-")))
              (mega-trust--decisions 'unread)
              (mega-exec-context-functions nil)
              (inhibit-message t)
              (loaded (featurep 'eglot))
              (start nil) (elapsed nil) (buffer nil))
         (let ((default-directory project))
           (mega-trust-project))
         (unwind-protect
             (progn
               (setq start (float-time))
               (require 'eglot)
               (mega-lang--register-servers)
               (setq buffer (find-file-noselect file))
               (with-current-buffer buffer
                 ;; eglot connects after the command that opened the file.
                 (run-hooks 'post-command-hook)
                 (let ((deadline (+ (float-time) 20)))
                   (while (and (not (eglot-current-server))
                               (< (float-time) deadline))
                     (accept-process-output nil 0.005)))
                 (unless (eglot-current-server)
                   (error "The stand-in server did not connect"))
                 (setq elapsed (* 1000.0 (- (float-time) start)))))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (and (fboundp 'eglot-current-server) (eglot-current-server))
                 (ignore-errors (eglot-shutdown (eglot-current-server) nil 3))))
             (kill-buffer buffer)))
         (list :ms elapsed
               :note (if loaded "eglot was loaded already" "eglot loaded on the way"))))))
 :rounds 1 :kind 'process)

;;;; Running them

(defun mega-bench--saved (file)
  "The run saved in FILE: a plist of :machine and :times, or nil.
:times is an alist (NAME . MILLISECONDS); :machine is how slow the
machine was then, as the :lisp of `mega-bench--machine' says."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((saved (ignore-errors (read (current-buffer)))))
        (and (plistp saved) (numberp (plist-get saved :machine)) saved)))))

(defun mega-bench--number (name default)
  "The positive number in the environment variable NAME, or DEFAULT."
  (let ((value (string-to-number (or (getenv name) ""))))
    (if (> value 0) value default)))

(defun mega-bench--describe (machine)
  "MACHINE, as `mega-bench--machine' returns it, in words."
  (format "computing %.0f ms (%.0f where the figures were set), programs and disk %.0f ms (%.0f)"
          (plist-get machine :lisp-ms) (mega-bench-reference-ms)
          (plist-get machine :process-ms) (mega-bench-process-reference-ms)))

(defun mega-bench--record-to-add (name time factor)
  "The record to put into the history if NAME is to be held to TIME.
FACTOR is how slow this machine is; the record is for the reference one."
  (format "(:ms %s :date %S :commit \"<the commit that changed it>\" :reason \"<why, and why not for less>\")"
          (let ((ms (/ time factor)))
            (if (< ms 10) (format "%.1f" ms) (format "%.0f" ms)))
          (format-time-string "%Y-%m-%d")))

(defun mega-bench-run ()
  "Run every benchmark, print one line each, and exit: 0 if none failed.
A line is a verdict, a tab, and the text: `ok', `slow', `bad', or `note'.
`slow' is over one and a half times the expected, and not a failure."
  ;; As in a session that has finished starting.
  (setq gc-cons-threshold mega-gc-cons-threshold)
  (let* ((only (getenv "MEGA_BENCH_ONLY"))
         (only (and only (not (string-empty-p only)) only))
         (problems (mega-bench-history-problems))
         (machine (and (mega-bench-established (nth 0 mega-bench-machine-entries))
                       (mega-bench-established (nth 1 mega-bench-machine-entries))
                       (mega-bench--machine)))
         (by-hand (mega-bench--number "MEGA_BENCH_SCALE" 1))
         (tolerance (mega-bench--number "MEGA_BENCH_TOLERANCE" 3))
         (saved (mega-bench--saved (getenv "MEGA_BENCH_COMPARE")))
         (before (plist-get saved :times))
         (drift (mega-bench--number "MEGA_BENCH_TOLERANCE" 2))
         (times nil)
         (over nil)
         (failed 0))
    ;; First, the figures themselves: a time is only as good as its record.
    (dolist (problem problems)
      (setq failed (1+ failed))
      (princ (format "bad\tthe history: %s\n" problem)))
    (unless machine
      (princ "bad\tnothing can be timed: the history does not say what the reference machine does\n")
      (kill-emacs 1))
    (princ (format "note\tthe machine now: %s\n" (mega-bench--describe machine)))
    (dolist (benchmark (reverse mega-bench--list))
      (when (or (null only) (string-match-p only (car benchmark)))
        (let* ((name (car benchmark))
               (record (mega-bench-established name))
               (expected (plist-get record :ms))
               (measure (lambda ()
                          (condition-case err
                              (mega-bench--measure benchmark)
                            (error (format "%s" (error-message-string err))))))
               (measured (funcall measure))
               (factor (* by-hand (mega-bench--factor benchmark machine)))
               (first-try nil))
          ;; Over the limit: is it the code, or the machine just now?
          (when (and expected (consp measured) (numberp (car measured))
                     (> (car measured) (* factor (mega-bench--limit record tolerance))))
            (setq first-try (car measured)
                  machine (mega-bench--machine)
                  factor (* by-hand (mega-bench--factor benchmark machine))
                  measured (funcall measure)))
          (cond
           ((stringp measured)
            (setq failed (1+ failed))
            (princ (format "bad\t%s: could not run: %s\n" name measured)))
           ((eq (car measured) :skip)
            (princ (format "note\t%s: not timed: %s\n" name (cadr measured))))
           (t
            (push (cons name (car measured)) times)
            (let* ((time (car measured))
                   (was (cdr (assoc name before)))
                   ;; How much slower the machine is now than at the saved run.
                   (since (if saved
                              (/ (plist-get machine :lisp) (plist-get saved :machine))
                            1.0))
                   (slower (and was (> was 0) (/ time was since)))
                   (limit (and expected (* factor (mega-bench--limit record tolerance))))
                   (too-slow (and limit (> time limit)))
                   (drifted (and slower (> slower drift) (> time 2.0)))
                   ;; Not a failure, and not to be read past either.
                   (slow (and expected
                              (not (plist-get record :limit))
                              (> time (* factor (max (* 1.5 expected) (+ expected 1.0))))))
                   (text (concat
                          (format "%-55s %7.1f ms" name time)
                          (if expected
                              (format "   expected %5.1f   x%.1f"
                                      (* factor expected) (/ time (* factor expected)))
                            "   nothing is expected of it yet")
                          (if (cdr measured) (format "   (%s)" (cdr measured)) "")
                          (if first-try (format "   (%.1f ms at first)" first-try) "")
                          (if slower (format "   x%.2f of the saved run" slower) ""))))
              (when (or too-slow drifted) (setq failed (1+ failed)))
              (when (or too-slow slow)
                (push (list name time factor record) over))
              (princ (format "%s\t%s%s\n"
                             (cond ((or too-slow drifted) "bad")
                                   (slow "slow")
                                   (t "ok"))
                             text
                             (cond (too-slow (format "   OVER THE LIMIT of %.1f ms" limit))
                                   (drifted "   SLOWER THAN IT WAS")
                                   (t ""))))
              ;; A benchmark nobody has put on record yet: the record to add.
              (unless expected
                (princ (format "note\t  once it is committed, into %s:  (%S %s)\n"
                               (file-name-nondirectory mega-bench-history-file) name
                               (mega-bench--record-to-add name time factor))))))))))
    (princ (format "note\tthe machine at the end: %s\n"
                   (mega-bench--describe (mega-bench--machine))))
    ;; What to do about a slow one, said where it will be read.
    (when over
      (princ (format "note\t\nnote\tOver its time: %s.  What is expected of whoever sees this is at the top of\n"
                     (mapconcat (lambda (one) (format "`%s'" (car one))) (reverse over) ", ")))
      (princ (format "note\t%s: first the cause, then the fix.\n"
                     (file-relative-name mega-bench-history-file
                                         (expand-file-name "../.." mega-test-dir))))
      (dolist (one (reverse over))
        (pcase-let ((`(,name ,time ,factor ,record) one))
          (princ (format "note\t\nnote\t%s\n" name))
          (princ (format "note\t  to find the commit:  git bisect start HEAD %s && git bisect run env MEGA_BENCH_ONLY=%s tests/test_mega2.sh bench\n"
                         (plist-get record :commit)
                         ;; In quotes a person can read: all of it literal
                         ;; but a quote of its own, which ends them, is
                         ;; said, and opens them again.
                         (concat "'"
                                 (string-replace "'" "'\\''"
                                                 (concat "^" (regexp-quote name) "$"))
                                 "'")))
          (princ (format "note\t  only if it is the reasonable, direct and minimised price of a change that is wanted, one more record:\n"))
          (princ (format "note\t    %s\n" (mega-bench--record-to-add name time factor))))))
    (when-let* ((file (getenv "MEGA_BENCH_SAVE")))
      (unless (string-empty-p file)
        (with-temp-file file
          (insert ";; Times of one run of tests/test_mega2.sh bench, in milliseconds.\n")
          (prin1 (list :machine (plist-get machine :lisp)
                       :process (plist-get machine :process)
                       :times (reverse times))
                 (current-buffer))
          (insert "\n"))
        (princ (format "note\tsaved to %s\n" file))))
    (kill-emacs (if (> failed 0) 1 0))))

(provide 'mega-bench)
;;; mega-bench.el ends here
