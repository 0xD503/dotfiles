;;; mega-exec-test.el --- Tests for mega-exec.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-exec)

(defun mega-exec-test--leftovers ()
  "Processes `mega-exec-run' started that are still alive."
  (seq-filter (lambda (process)
                (and (string-prefix-p "mega-exec" (process-name process))
                     (process-live-p process)))
              (process-list)))

(ert-deftest mega-exec-run-returns-status-output-and-errors-apart ()
  (let ((result (mega-exec-run "sh" '("-c" "echo out; echo err >&2; exit 3"))))
    (should (eql (plist-get result :status) 3))
    (should (equal (plist-get result :output) "out\n"))
    (should (equal (plist-get result :error) "err\n"))
    (should-not (plist-get result :stopped))))

(ert-deftest mega-exec-run-sends-input ()
  (let ((result (mega-exec-run "cat" nil :input "one\ntwo\n")))
    (should (eql (plist-get result :status) 0))
    (should (equal (plist-get result :output) "one\ntwo\n"))))

(ert-deftest mega-exec-run-runs-in-the-directory-given ()
  (mega-test-with-directory dir
    (should (equal (plist-get (mega-exec-run "pwd" nil :directory dir) :output)
                   (concat (directory-file-name dir) "\n")))))

(ert-deftest mega-exec-arguments-never-reach-a-shell ()
  "An argument is data.  Whatever it looks like, nothing in it runs."
  (mega-test-with-directory dir
    (let* ((nasty "$(touch pwned); `touch pwned2` && touch pwned3 | x > pwned4")
           (result (mega-exec-run "printf" (list "%s" nasty) :directory dir)))
      (should (equal (plist-get result :output) nasty))
      (should-not (directory-files dir nil "pwned")))))

(ert-deftest mega-exec-run-stops-at-the-line-limit ()
  (let ((result (mega-exec-run "sh" '("-c" "while :; do echo line; done")
                               :limit 5)))
    (should (eq (plist-get result :stopped) 'limit))
    (should-not (plist-get result :status))
    (should-not (mega-exec-test--leftovers))))

(ert-deftest mega-exec-run-stops-at-the-timeout ()
  (let* ((start (float-time))
         (result (mega-exec-run "sleep" '("30") :timeout 0.2)))
    (should (eq (plist-get result :stopped) 'timeout))
    (should (< (- (float-time) start) 5))
    (should-not (mega-exec-test--leftovers))))

(ert-deftest mega-exec-an-abandoned-run-kills-its-program ()
  "Leaving the wait early — as typing does to a search — leaves nothing running."
  (should (eq (with-timeout (0.2 'abandoned)
                (mega-exec-run "sleep" '("30")))
              'abandoned))
  (should-not (mega-exec-test--leftovers)))

(ert-deftest mega-exec-a-missing-program-is-an-error-not-a-hang ()
  (should-error (mega-exec-run "mega-test-no-such-program" nil))
  (should-not (mega-exec-test--leftovers)))

(ert-deftest mega-exec-lines-splits-and-limits ()
  (should (equal (mega-exec-lines "printf" '("a\\nb\\n\\nc\\n")) '("a" "b" "c")))
  (should (= 3 (length (mega-exec-lines "sh" '("-c" "while :; do echo x; done")
                                        :limit 3)))))

;;;; Contexts

(defmacro mega-exec-test--in-context (context &rest body)
  "Run BODY with every directory claimed by CONTEXT."
  (declare (indent 1))
  `(let ((mega-exec-context-functions (list (lambda (_directory) ,context))))
     ,@body))

(ert-deftest mega-exec-the-default-context-is-local ()
  (let ((mega-exec-context-functions nil))
    (should (eq (plist-get (mega-exec-context "/tmp/") :kind) 'local))
    (should (equal (mega-exec-command "prog" '("a" "b") "/tmp/") '("prog" "a" "b")))
    (should (equal (mega-exec-translate "/tmp/x" 'inside "/tmp/") "/tmp/x"))))

(ert-deftest mega-exec-a-context-wraps-the-command ()
  (mega-exec-test--in-context
      (list :kind 'test
            :wrap (lambda (program args directory)
                    (append (list "env" "MEGA_TEST_WRAPPED=yes"
                                  (concat "MEGA_TEST_DIR=" directory)
                                  program)
                            args)))
    (mega-test-with-directory dir
      (should (equal (plist-get (mega-exec-run
                                 "sh" '("-c" "echo $MEGA_TEST_WRAPPED $MEGA_TEST_DIR")
                                 :directory dir)
                                :output)
                     (format "yes %s\n" dir)))
      ;; :local runs where the files are, whatever the context.
      (should (equal (plist-get (mega-exec-run
                                 "sh" '("-c" "echo ${MEGA_TEST_WRAPPED:-no}")
                                 :directory dir :local t)
                                :output)
                     "no\n")))))

(ert-deftest mega-exec-a-context-answers-what-exists-inside-it ()
  (mega-exec-test--in-context
      (list :kind 'test :find (lambda (program) (equal program "only-inside")))
    (should (mega-exec-find "only-inside" "/tmp/"))
    (should-not (mega-exec-find "sh" "/tmp/"))
    (should (mega-exec-find "sh" "/tmp/" :local))))

(ert-deftest mega-exec-a-context-translates-file-names ()
  (mega-exec-test--in-context
      (list :kind 'test
            :to-inside (lambda (file) (concat "/app" file))
            :to-host (lambda (file) (string-remove-prefix "/app" file)))
    (should (equal (mega-exec-translate "/src/a.rs" 'inside "/tmp/") "/app/src/a.rs"))
    (should (equal (mega-exec-translate "/app/src/a.rs" 'host "/tmp/") "/src/a.rs"))))

(ert-deftest mega-exec-the-first-context-function-to-answer-wins ()
  (let ((mega-exec-context-functions
         (list (lambda (_) nil)
               (lambda (_) '(:kind first))
               (lambda (_) '(:kind second)))))
    (should (eq (plist-get (mega-exec-context "/tmp/") :kind) 'first))))

;;;; Programs that do not wait for their input

(ert-deftest mega-exec-a-program-that-is-already-gone-is-not-an-error ()
  "A quick program on a busy machine finishes before its input is closed."
  (let ((process (make-process :name "mega-exec-test-gone" :command '("true")
                               :connection-type 'pipe :noquery t
                               :sentinel #'ignore)))
    (should (mega-test-wait-for (lambda () (not (process-live-p process)))))
    ;; This is what Emacs would say, left to itself.
    (should-error (process-send-eof process))
    (mega-exec--feed process nil)
    (mega-exec--feed process "some input\n")))

;; A program that closes its input while it is still being written to is the
;; other half of this.  It cannot be tried here: a batch Emacs is killed by
;; the write, where the Emacs you edit in gets an error.  The terminal stage
;; tries it, in a real session (mega-terminal-probe.el).

(ert-deftest mega-exec-the-answer-is-given-once-whatever-emacs-reports ()
  "Emacs may tell about the end of a program more than once."
  (let* ((answers nil)
         (process (mega-exec-start "true" nil
                                   :then (lambda (answer) (push answer answers)))))
    (should (mega-test-wait-for (lambda () answers)))
    (mega-exec--finish process)
    (funcall (process-sentinel process) process "finished\n")
    (should (= (length answers) 1))))

;;;; Not waiting

(ert-deftest mega-exec-start-returns-at-once-and-answers-later ()
  (let* (result
         (process (mega-exec-start "sh" '("-c" "cat; echo err >&2; exit 4")
                                   :input "sent\n"
                                   :then (lambda (answer) (setq result answer)))))
    (should (processp process))
    (should (mega-test-wait-for (lambda () result)))
    (should (eql (plist-get result :status) 4))
    (should (equal (plist-get result :output) "sent\n"))
    (should (equal (plist-get result :error) "err\n"))
    (should-not (plist-get result :stopped))
    (should-not (mega-exec-test--leftovers))))

(ert-deftest mega-exec-start-runs-in-the-directory-given ()
  (mega-test-with-directory dir
    (let (result)
      (mega-exec-start "pwd" nil :directory dir
                       :then (lambda (answer) (setq result answer)))
      (should (mega-test-wait-for (lambda () result)))
      (should (equal (plist-get result :output)
                     (concat (directory-file-name dir) "\n"))))))

(ert-deftest mega-exec-stop-ends-the-program-and-says-so-once ()
  (let* ((answers nil)
         (process (mega-exec-start "sleep" '("30")
                                   :then (lambda (answer) (push answer answers)))))
    (should (process-live-p process))
    (mega-exec-stop process)
    (should (mega-test-wait-for (lambda () answers)))
    (should-not (process-live-p process))
    (should (eq (plist-get (car answers) :stopped) 'killed))
    (should-not (plist-get (car answers) :status))
    ;; Stopping twice is harmless, and the answer is given only once.
    (mega-exec-stop process)
    (accept-process-output nil 0.1)
    (should (= (length answers) 1))
    (should-not (mega-exec-test--leftovers))))

(ert-deftest mega-exec-start-survives-a-failing-then ()
  "A mistake in the caller's function is reported, and nothing is left behind.
It runs in the middle of whatever else is going on, so it must not raise."
  (let ((before (length (buffer-list)))
        (done nil)
        (said nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest arguments)
                 (setq said (apply #'format-message format arguments)))))
      (mega-exec-start "true" nil
                       :then (lambda (_answer) (setq done t) (error "Caller's bug")))
      (should (mega-test-wait-for (lambda () done))))
    (should (string-match-p "Caller.s bug" said))
    (should (= (length (buffer-list)) before))
    (should-not (mega-exec-test--leftovers))))

(provide 'mega-exec-test)
;;; mega-exec-test.el ends here
