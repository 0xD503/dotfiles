;;; mega-bench.el --- How long the things you wait for take  -*- lexical-binding: t; -*-

;;; Commentary:

;; Not an ERT file.  `tests/test_mega2.sh bench' loads it after the real init
;; files, in the same sandbox as the tests, and it times the paths of MEGA
;; that a person waits on: a keystroke, the completion menu, finding a file,
;; a search, a save, the undo tree, a debugger message.
;;
;; Each benchmark has a budget, in milliseconds.  A budget is not what the
;; machine can do; it is roughly when a person would start to notice, a few
;; times what the code takes today.  The run prints every time next to its
;; budget, so a slowdown shows long before it fails, and fails only when a
;; budget is exceeded.
;;
;; Budgets are stated for the machine they were set on.  So that a slower
;; machine, or one that is busy with something else, does not fail the run,
;; a fixed piece of work is timed first (`mega-bench--reference'); however
;; many times longer than `mega-bench-reference-ms' it takes, every budget
;; is stretched by that much.  Budgets are never shrunk.  The price is that
;; this measures MEGA against Emacs on the same machine at the same moment,
;; not against the clock on the wall; that is the comparison that says
;; whether MEGA's own code got slower.
;;
;;   MEGA_BENCH_SCALE=2      multiply every budget once more, by hand
;;   MEGA_BENCH_SAVE=file    write the times of this run to FILE
;;   MEGA_BENCH_COMPARE=file compare with a saved run, and fail when
;;                           something is more than MEGA_BENCH_TOLERANCE
;;                           times slower than it was (default 2), the
;;                           speed of the machine at each run allowed for
;;
;; So, before a change that might cost time: save a run.  After it: compare.
;;
;; Start-up has its own budget in the boot stage; it is not timed here.
;;
;; A benchmark is a function that prepares what it needs and returns the
;; function to time.  Preparation is not timed.  The best of three rounds
;; counts, which is what keeps a busy machine from failing the run.  The
;; timed function may return (:ms N :note TEXT) to report a time of its own
;; instead of the clock's, with a word about it.
;;
;; To add one: `mega-bench-define', a name that says what a person does, a
;; budget, and the function.  Order matters only for the first, which must
;; run before anything has loaded the modules it times.

;;; Code:

(require 'mega-test-helper)

(defvar mega-bench--list nil
  "The benchmarks, newest first: (NAME BUDGET FUNCTION ROUNDS).")

(defun mega-bench-define (name budget function &optional rounds)
  "Define the benchmark NAME, which should take at most BUDGET milliseconds.
FUNCTION prepares the work and returns the function that does it; only
the latter is timed.  ROUNDS, by default 3, is how often that is done;
the best time counts."
  (push (list name budget function (or rounds 3)) mega-bench--list))

(defun mega-bench--time (function)
  "How long FUNCTION takes, garbage collected beforehand: (MILLISECONDS . NOTE).
What FUNCTION reports itself, as (:ms N :note TEXT), wins over the clock."
  (garbage-collect)
  (let* ((start (float-time))
         (value (funcall function))
         (elapsed (* 1000.0 (- (float-time) start))))
    (if (and (consp value) (eq (car value) :ms))
        (cons (plist-get value :ms) (plist-get value :note))
      (cons elapsed nil))))

(defun mega-bench--measure (benchmark)
  "The best time of BENCHMARK: (MILLISECONDS . NOTE)."
  (let ((best nil))
    (dotimes (_ (nth 3 benchmark))
      (let ((time (mega-bench--time (funcall (nth 2 benchmark)))))
        (when (or (null best) (< (car time) (car best)))
          (setq best time))))
    best))

;;;; How fast the machine is right now

(defconst mega-bench-reference-ms 75.0
  "What `mega-bench--reference' takes on the machine the budgets were set on.")

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

(defun mega-bench--machine ()
  "How many times slower than the reference this machine is now; at least 1."
  (let ((best nil))
    (dotimes (_ 3)
      (let ((time (car (mega-bench--time #'mega-bench--reference))))
        (when (or (null best) (< time best))
          (setq best time))))
    (cons (max 1.0 (/ best mega-bench-reference-ms)) best)))

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
 "first use of a feature: load its module (slowest)" 60
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
 1)

(mega-bench-define
 "type 1000 characters in code" 150
 (lambda ()
   (require 'mega-complete)
   (require 'mega-edit)
   (let ((buffer (generate-new-buffer " *mega-bench*")))
     (with-current-buffer buffer
       (prog-mode)
       (insert (mega-bench--source 400)))
     (lambda ()
       (unwind-protect
           (with-current-buffer buffer
             (goto-char (point-max))
             ;; What MEGA does around every character: note the change for
             ;; trimming, and schedule the completion menu.
             (let ((this-command 'self-insert-command)
                   (last-command-event ?x))
               (dotimes (_ 1000)
                 (run-hooks 'pre-command-hook)
                 (self-insert-command 1)
                 (mega-complete--post-command)
                 (run-hooks 'post-command-hook))))
         (when (timerp (bound-and-true-p mega-complete--timer))
           (cancel-timer mega-complete--timer))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))))))

(mega-bench-define
 "completion menu: choose from 5000 candidates" 30
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
 "find a file: fuzzy match in 100,000 paths" 600
 (lambda ()
   (let ((paths nil))
     (dotimes (index 100000)
       (push (format "crates/part%02d/src/module%03d/file%05d.rs"
                     (% index 40) (% index 500) index)
             paths))
     (push "src/bin/main.rs" paths)
     (lambda ()
       ;; As the prompt does it: `flex' is the style its vertical list uses.
       (let* ((completion-styles '(flex))
              (found (completion-all-completions "srcmain" paths nil 7)))
         (unless (consp found) (error "No match")))))))

(mega-bench-define
 "search: show 2000 hits" 30
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
 "search: a real one, 300 files, with grep" 150
 (lambda ()
   (require 'mega-search)
   (let ((directory (mega-bench--directory "bench-search-")))
     (dotimes (index 300)
       (mega-test-write (expand-file-name (format "src/file%03d.txt" index) directory)
                        "one line" (format "the needle is in file %d" index) "last line" ""))
     (lambda ()
       (unless (= (length (mega-search-run "needle" directory 'grep 1000)) 300)
         (error "Hits were lost"))))))

(mega-bench-define
 "run a program and wait for it, ten times" 100
 (lambda ()
   (require 'mega-exec)
   (lambda ()
     (dotimes (_ 10)
       (unless (eql (plist-get (mega-exec-run "true" nil) :status) 0)
         (error "The program failed"))))))

(mega-bench-define
 "format a 2000-line buffer on save" 60
 (lambda ()
   (require 'mega-format)
   (let ((text (mega-bench--source 2000)))
     (lambda ()
       (with-temp-buffer
         (insert text)
         ;; A formatter that changes one line in eight, as a real one might.
         (unless (eq (mega-format-run '("sed" "s/  *$//")) 'changed)
           (error "The formatter did not change the buffer")))))))

(dolist (mode '(mega-rust-mode mega-zig-mode mega-markdown-mode))
  (mega-bench-define
   (format "open a 4000-line file: %s, highlighted throughout" mode) 400
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
 "indentation guides over 4000 lines" 400
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
 "save a file after a small edit" 20
 (lambda ()
   (require 'mega-undo)
   (let* ((mega-undo-exclude-regexps nil)
          (file (expand-file-name "small.txt" (mega-bench--directory "bench-save-")))
          (buffer (progn (mega-test-write file (mega-bench--source 500))
                         (find-file-noselect file))))
     (with-current-buffer buffer
       (goto-char (point-max))
       (insert "one more line  \n"))
     (lambda ()
       (let ((mega-undo-exclude-regexps nil) (inhibit-message t))
         (unwind-protect
             (with-current-buffer buffer (save-buffer))
           (kill-buffer buffer)))))))

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
 "save a file with a megabyte of undo history" 200
 (lambda ()
   (require 'mega-undo)
   (let* ((mega-undo-exclude-regexps nil)
          (file (expand-file-name "long.txt" (mega-bench--directory "bench-undo-")))
          (buffer (find-file-noselect file)))
     (mega-bench--long-history buffer)
     (lambda ()
       (let ((mega-undo-exclude-regexps nil) (inhibit-message t))
         (unwind-protect
             (with-current-buffer buffer (save-buffer))
           (kill-buffer buffer)))))))

(mega-bench-define
 "open a file and get its undo history back" 300
 (lambda ()
   (require 'mega-undo)
   (let* ((mega-undo-exclude-regexps nil)
          (inhibit-message t)
          (file (expand-file-name "long.txt" (mega-bench--directory "bench-undo-")))
          (buffer (find-file-noselect file)))
     (mega-bench--long-history buffer)
     (with-current-buffer buffer (save-buffer))
     (kill-buffer buffer)
     (lambda ()
       (let ((mega-undo-exclude-regexps nil))
         (with-current-buffer (find-file-noselect file)
           (unwind-protect
               (unless (consp buffer-undo-list)
                 (error "The history did not come back"))
             (kill-buffer (current-buffer)))))))))

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
 "undo tree: draw a history of 2000 changes" 80
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
 "undo tree: twenty moves in a history of 2000 changes" 800
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
 "debugger: take in 1000 messages" 30
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
 "the home page" 30
 (lambda ()
   (require 'mega-home)
   (lambda ()
     (let ((buffer (mega-home-render)))
       (when (buffer-live-p buffer) (kill-buffer buffer))))))

(mega-bench-define
 "the cheat sheet" 40
 (lambda ()
   (require 'mega-help)
   (lambda ()
     (with-temp-buffer (mega-help--insert)))))

;;;; Running them

(defun mega-bench--saved (file)
  "The run saved in FILE: a plist of :machine and :times, or nil.
:times is an alist (NAME . MILLISECONDS); :machine is how slow the
machine was then, as `mega-bench--machine' says."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((saved (ignore-errors (read (current-buffer)))))
        (and (plistp saved) (numberp (plist-get saved :machine)) saved)))))

(defun mega-bench-run ()
  "Run every benchmark, print one line each, and exit: 0 if all are in budget.
A line is a verdict, a tab, and the text: `ok', `bad', or `note'."
  (let* ((machine (mega-bench--machine))
         (scale (string-to-number (or (getenv "MEGA_BENCH_SCALE") "1")))
         (scale (* (car machine) (if (> scale 0) scale 1)))
         (tolerance (string-to-number (or (getenv "MEGA_BENCH_TOLERANCE") "2")))
         (tolerance (if (> tolerance 0) tolerance 2))
         (saved (mega-bench--saved (getenv "MEGA_BENCH_COMPARE")))
         (before (plist-get saved :times))
         ;; How much slower the machine is now than when that run was saved.
         (since (if saved (/ (car machine) (plist-get saved :machine)) 1.0))
         (times nil)
         (failed 0))
    (princ (format "note\tthe reference work took %.0f ms (%.0f ms where the budgets were set)%s\n"
                   (cdr machine) mega-bench-reference-ms
                   (if (> scale 1.0)
                       (format ": budgets are stretched %.1f times" scale)
                     "")))
    (dolist (benchmark (reverse mega-bench--list))
      (let* ((name (car benchmark))
             (budget (* scale (nth 1 benchmark)))
             (measured (condition-case err
                           (mega-bench--measure benchmark)
                         (error (format "%s" (error-message-string err)))))
             (was (cdr (assoc name before))))
        (cond
         ((stringp measured)
          (setq failed (1+ failed))
          (princ (format "bad\t%s: could not run: %s\n" name measured)))
         (t
          (push (cons name (car measured)) times)
          (let* ((time (car measured))
                 (slower (and was (> was 0) (/ time was since)))
                 (over (> time budget))
                 (drifted (and slower (> slower tolerance)
                               ;; Below a millisecond the clock is the noise.
                               (> time 1.0)))
                 (text (format "%-52s %8.1f ms   budget %5.0f ms%s%s"
                               name time budget
                               (if (cdr measured) (format "   (%s)" (cdr measured)) "")
                               (if slower (format "   x%.2f of the saved run" slower) ""))))
            (when (or over drifted) (setq failed (1+ failed)))
            (princ (format "%s\t%s%s\n"
                           (if (or over drifted) "bad" "ok")
                           text
                           (cond (over "   OVER BUDGET")
                                 (drifted "   SLOWER THAN IT WAS")
                                 (t "")))))))))
    (when-let* ((file (getenv "MEGA_BENCH_SAVE")))
      (unless (string-empty-p file)
        (with-temp-file file
          (insert ";; Times of one run of tests/test_mega2.sh bench, in milliseconds.\n")
          (prin1 (list :machine (car machine) :times (reverse times))
                 (current-buffer))
          (insert "\n"))
        (princ (format "note\tsaved to %s\n" file))))
    (kill-emacs (if (> failed 0) 1 0))))

(provide 'mega-bench)
;;; mega-bench.el ends here
