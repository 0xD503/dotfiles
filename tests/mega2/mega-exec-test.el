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

(provide 'mega-exec-test)
;;; mega-exec-test.el ends here
