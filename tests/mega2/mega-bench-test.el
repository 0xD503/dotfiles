;;; mega-bench-test.el --- Tests for the record of what the benchmarks may take  -*- lexical-binding: t; -*-

;;; Commentary:

;; The benchmarks time MEGA; these test the bookkeeping around them.  The
;; rule is that an expected time changes only with a record: which commit
;; made the thing slower, and why that was worth it.  A rule nobody can
;; break by accident needs two things, and both are tested here: there is
;; no number to edit beside a benchmark, and a history that is missing a
;; record, a commit or a reason fails the bench stage.

;;; Code:

(require 'mega-test-helper)
(require 'mega-bench)

(defmacro mega-bench-test--history (history &rest body)
  "Run BODY with HISTORY as the history, and every commit in it known."
  (declare (indent 1))
  `(let ((mega-bench--history ,history))
     (cl-letf (((symbol-function 'mega-bench--commit-known-p) (lambda (_) 'yes)))
       ,@body)))

(defconst mega-bench-test--machine
  '(("the reference machine: computing"
     (:ms 80 :date "2026-01-01" :commit "abc1234" :reason "Established."))
    ("the reference machine: programs and disk"
     (:ms 20 :date "2026-01-01" :commit "abc1234" :reason "Established.")))
  "The two entries every history has.")

(defun mega-bench-test--with (&rest entries)
  "A history of the machine's entries and ENTRIES."
  (append mega-bench-test--machine entries))

;;;; The history that is shipped

(ert-deftest mega-bench-the-history-is-in-order ()
  "As the bench stage checks it, commits and all."
  (should-not (mega-bench-history-problems))
  ;; And it is about the benchmarks there are: all of them, and the machine.
  (should (> (length mega-bench--list) 20))
  (should (= (length (mega-bench-history))
             (+ (length mega-bench--list) (length mega-bench-machine-entries))))
  (should (> (mega-bench-reference-ms) 0))
  (should (> (mega-bench-process-reference-ms) 0)))

(ert-deftest mega-bench-no-benchmark-carries-its-own-figure ()
  "A number beside a benchmark could be changed without a word of why."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "mega-bench.el" mega-test-dir))
    (let ((defined 0))
      (while (re-search-forward "^ *(mega-bench-define\n? *\\(?:\"[^\"]*\"\\|(format[^\n]*)\\)\\([^\n]*\\)\n\\([^\n]*\\)"
                                nil t)
        (setq defined (1+ defined))
        ;; After the name, on that line or the next: the function, never a number.
        (should-not (string-match-p "\\`[ \t]*[0-9]" (match-string 1)))
        (should-not (string-match-p "\\`[ \t]*[0-9]" (match-string 2))))
      (should (> defined 20)))
    (goto-char (point-min))
    (should-not (re-search-forward "(defconst mega-bench-[a-z-]*-ms " nil t))))

(ert-deftest mega-bench-a-benchmark-is-held-to-its-last-record ()
  (mega-bench-test--history
      (mega-bench-test--with
       '("typing"
         (:ms 20 :date "2026-01-01" :commit "abc1234" :reason "Established.")
         (:ms 26 :date "2026-03-01" :commit "def5678" :reason "Trims lines as you type.")))
    (should (= (plist-get (mega-bench-established "typing") :ms) 26))
    (should (equal (plist-get (mega-bench-established "typing") :commit) "def5678"))
    (should-not (mega-bench-established "something else"))
    (should (= (mega-bench-reference-ms) 80))))

(ert-deftest mega-bench-how-far-over-is-too-far ()
  ;; Three times what is expected...
  (should (= (mega-bench--limit '(:ms 100) 3) 300))
  ;; ...never less than two milliseconds over, where the clock is the noise...
  (should (= (mega-bench--limit '(:ms 0.5) 3) 2.5))
  ;; ...and the record's own word, where it has one.
  (should (= (mega-bench--limit '(:ms 2.3 :limit 40) 3) 40)))

;;;; What makes a history wrong

(ert-deftest mega-bench-every-benchmark-needs-a-record-and-every-record-a-benchmark ()
  (mega-bench-test--history
      (mega-bench-test--with
       '("typing" (:ms 20 :date "2026-01-01" :commit "abc1234" :reason "Established.")))
    (should-not (mega-bench-history-problems '("typing")))
    ;; A new benchmark with nothing said about it.
    (let ((problems (mega-bench-history-problems '("typing" "saving"))))
      (should (= (length problems) 1))
      (should (string-match-p "`saving' has no record" (car problems))))
    ;; A benchmark renamed, its history left behind under the old name.
    (let ((problems (mega-bench-history-problems '("typing fast"))))
      (should (seq-some (lambda (problem) (string-match-p "`typing fast' has no record" problem))
                        problems))
      (should (seq-some (lambda (problem) (string-match-p "no benchmark is called that" problem))
                        problems))))
  ;; The machine's own two figures are part of it.
  (mega-bench-test--history
      '(("typing" (:ms 20 :date "2026-01-01" :commit "abc1234" :reason "Established.")))
    (should (= 2 (seq-count (lambda (problem) (string-match-p "the reference machine" problem))
                            (mega-bench-history-problems '("typing")))))))

(ert-deftest mega-bench-a-record-says-when-in-which-commit-and-why ()
  "The part of the rule a person could forget: a slower time with no reason."
  (dolist (case '(((:ms 30 :date "2026-03-01" :commit "def5678") "gives no reason")
                  ((:ms 30 :date "2026-03-01" :commit "def5678" :reason "  ") "gives no reason")
                  ((:ms 30 :date "2026-03-01" :reason "It got slower.") "names no commit")
                  ((:ms 30 :date "2026-03-01" :commit "the last one" :reason "It got slower.")
                   "names no commit")
                  ((:ms 30 :commit "def5678" :reason "It got slower.") "without its date")
                  ((:ms 30 :date "March" :commit "def5678" :reason "It got slower.")
                   "without its date")
                  ((:date "2026-03-01" :commit "def5678" :reason "It got slower.")
                   "without a time")
                  ((:ms 30 :limit 10 :date "2026-03-01" :commit "def5678" :reason "It got slower.")
                   "under the time")
                  ;; Older than the record before it.
                  ((:ms 30 :date "2025-12-31" :commit "def5678" :reason "It got slower.")
                   "comes after")))
    (mega-bench-test--history
        (mega-bench-test--with
         (list "typing"
               '(:ms 20 :date "2026-01-01" :commit "abc1234" :reason "Established.")
               (car case)))
      (let ((problems (mega-bench-history-problems '("typing"))))
        (should (equal (list (car case) (length problems)) (list (car case) 1)))
        (should (string-match-p (cadr case) (car problems))))))
  ;; A good one, for contrast.
  (mega-bench-test--history
      (mega-bench-test--with
       '("typing"
         (:ms 20 :date "2026-01-01" :commit "abc1234" :reason "Established.")
         (:ms 30 :date "2026-03-01" :commit "def5678abc"
          :reason "Highlights the line again after each key; cannot be put off.")))
    (should-not (mega-bench-history-problems '("typing")))))

(ert-deftest mega-bench-a-record-names-a-commit-the-repository-has ()
  (let ((mega-bench--history
         (mega-bench-test--with
          '("typing" (:ms 20 :date "2026-01-01" :commit "abc1234" :reason "Established."))))
        (asked nil))
    (cl-letf (((symbol-function 'mega-bench--commit-known-p)
               (lambda (commit) (push commit asked) 'no)))
      (let ((problems (mega-bench-history-problems '("typing"))))
        (should (= (length problems) 3))
        (should (string-match-p "names commit abc1234, which is not in the history"
                                (car problems))))
      ;; Each commit is asked about once, however many records name it.
      (should (equal asked '("abc1234"))))
    ;; Where it cannot be asked, no git or no repository, that is no fault.
    (cl-letf (((symbol-function 'mega-bench--commit-known-p) #'ignore))
      (should-not (mega-bench-history-problems '("typing"))))))

(ert-deftest mega-bench-git-is-really-asked-about-a-commit ()
  (skip-unless (executable-find "git"))
  (let* ((default-directory mega-test-dir)
         (head (with-temp-buffer
                 (and (eql 0 (call-process "git" nil t nil "rev-parse" "HEAD"))
                      (string-trim (buffer-string))))))
    (skip-unless head)
    (should (eq (mega-bench--commit-known-p head) 'yes))
    (should (eq (mega-bench--commit-known-p (substring head 0 8)) 'yes))
    (should (eq (mega-bench--commit-known-p "0123456789abcdef0123456789abcdef01234567") 'no))))

(ert-deftest mega-bench-a-history-that-cannot-be-read-is-said-to-be-so ()
  (let ((mega-bench--history nil))
    (should (string-match-p "cannot be read" (car (mega-bench-history-problems '("typing"))))))
  (mega-bench-test--history (append mega-bench-test--machine '("not an entry"))
    (should (seq-some (lambda (problem) (string-match-p "not a name and its records" problem))
                      (mega-bench-history-problems nil)))))

(ert-deftest mega-bench-the-record-to-add-is-written-out-for-whoever-needs-it ()
  "In the reference machine's terms, with today's date; the rest is theirs."
  (let ((record (mega-bench--record-to-add "typing" 60.0 2.0)))
    (should (string-match-p "\\`(:ms 30 " record))
    (should (string-search (format-time-string "%Y-%m-%d") record))
    (should (string-match-p ":commit \"<" record))
    (should (string-match-p ":reason \"<" record)))
  (should (string-match-p "\\`(:ms 2\\.5 " (mega-bench--record-to-add "typing" 2.5 1.0))))

(provide 'mega-bench-test)
;;; mega-bench-test.el ends here
