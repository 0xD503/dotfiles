;;; mega-undo-test.el --- Tests for mega-undo.el and mega-undo-tree.el  -*- lexical-binding: t; -*-

;;; Code:

(require 'mega-test-helper)
(require 'mega-undo)
(require 'mega-undo-tree)

;;;; Making a history
;;
;; The tests below build real histories, with Emacs's own `undo', and write
;; down what the text was in each state.  That record is the witness: wherever
;; MEGA says "the text is now in that state", the text is compared with it.

(defvar mega-undo-test--texts nil
  "Hash table, state -> the text the buffer had in that state.")

(defun mega-undo-test--note ()
  "Write down the text of the newest state of the current buffer."
  (undo-boundary)
  (puthash (1- (length (mega-undo-states buffer-undo-list)))
           (buffer-string) mega-undo-test--texts))

(defun mega-undo-test--do (&rest actions)
  "Carry out ACTIONS in the current buffer, one command each.
A string is typed at the end of the text; (undo N) presses `C-/' N times
in a row; a function is called."
  (let ((inhibit-message t))
    (dolist (action actions)
      (undo-boundary)
      (cond ((stringp action)
             (goto-char (point-max))
             (insert action)
             (mega-undo-test--note))
            ((functionp action)
             (funcall action)
             (mega-undo-test--note))
            (t
             (let ((last-command nil))
               (dotimes (_ (cadr action))
                 (undo-boundary)
                 (undo 1)
                 (setq last-command 'undo)
                 (mega-undo-test--note))))))))

(defmacro mega-undo-test--with-history (actions &rest body)
  "Run BODY in a buffer whose history was made by ACTIONS."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (let ((mega-undo-test--texts (make-hash-table)))
       (buffer-enable-undo)
       (puthash 0 "" mega-undo-test--texts)
       (apply #'mega-undo-test--do ,actions)
       ,@body)))

(defun mega-undo-test--tree ()
  "The undo tree of the current buffer."
  (plist-get (mega-undo-tree--read (current-buffer)) :tree))

(defun mega-undo-test--node-texts (tree)
  "The text of each node of TREE, checking that its states agree on it."
  (let ((texts (make-vector (plist-get tree :count) nil)))
    (dotimes (node (plist-get tree :count))
      (dolist (state (aref (plist-get tree :states) node))
        (let ((text (gethash state mega-undo-test--texts)))
          (should text)
          (if (aref texts node)
              (should (equal text (aref texts node)))
            (aset texts node text)))))
    texts))

(defun mega-undo-test--go (node)
  "Move the current buffer to NODE of its undo tree."
  (mega-undo-tree-go (current-buffer) (lambda (_tree _current) node)))

(defconst mega-undo-test--branchy
  '("a" "b" "c" (undo 2) "x" "y" (undo 2) "z")
  "Three branches from one fork: a-b-c, a-x-y and a-z.")

;;;; Reading an undo list

(ert-deftest mega-undo-states-are-the-groups-of-the-list ()
  (should (equal (mega-undo-states nil) [nil]))
  (let* ((list (list nil '(3 . 4) nil '(2 . 3) 2 nil nil '(1 . 2)))
         (states (mega-undo-states list)))
    (should (= (length states) 4))
    (should (null (aref states 0)))
    ;; Oldest first, each the tail that starts the group; a doubled
    ;; boundary does not make a state.
    (should (equal (car (aref states 1)) '(1 . 2)))
    (should (eq (aref states 2) (nthcdr 3 list)))
    (should (eq (aref states 3) (cdr list)))))

(ert-deftest mega-undo-reads-what-emacs-recorded-about-undoing ()
  (mega-undo-test--with-history '("a" "b" "c" (undo 2))
    (let* ((states (mega-undo-states buffer-undo-list))
           (same (mega-undo-equivalents states nil)))
      (should (equal (buffer-string) "a"))
      ;; Three changes, then two undos that lead back to states 2 and 1.
      (should (equal same [nil nil nil nil 2 1])))))

(ert-deftest mega-undo-tree-has-one-node-per-distinct-text ()
  (mega-undo-test--with-history mega-undo-test--branchy
    (let* ((tree (mega-undo-test--tree))
           (texts (mega-undo-test--node-texts tree)))
      (should (equal texts ["" "a" "ab" "abc" "ax" "axy" "az"]))
      (should (equal (plist-get tree :parent) (vconcat [nil 0 1 2 1 4 1]
                                                       (make-vector 4 nil))))
      (should (equal (aref (plist-get tree :children) 1) '(2 4 6)))
      (should (= (mega-undo-tree-current tree) 6)))))

(ert-deftest mega-undo-does-not-trust-undone-all-the-way-back ()
  "Emacs records that without saying back to where; see mega-undo.el."
  (mega-undo-test--with-history '("a" "b" (undo 2))
    (let* ((tree (mega-undo-test--tree))
           (texts (mega-undo-test--node-texts tree)))
      (should (equal (buffer-string) ""))
      ;; The empty text appears twice: as the oldest state, and as a state
      ;; of its own, rather than being taken for the oldest on Emacs's word.
      (should (equal texts ["" "a" "ab" ""])))))

;;;; The picture

(defconst mega-undo-test--ascii
  '(:node ?o :current ?@ :across ?- :down ?| :fork ?+ :last ?`))

(defun mega-undo-test--picture ()
  "The current buffer's undo tree, drawn in ASCII."
  (let ((tree (mega-undo-test--tree)))
    (mega-undo-tree-lines tree (mega-undo-tree-layout tree)
                          (mega-undo-tree-current tree) mega-undo-test--ascii)))

(ert-deftest mega-undo-tree-is-drawn-with-a-row-per-branch ()
  (mega-undo-test--with-history mega-undo-test--branchy
    (should (equal (mega-undo-test--picture)
                   '("o--o--o--o"
                     "   +--o--o"
                     "   `--@")))))

(ert-deftest mega-undo-tree-lines-run-down-past-the-branches-between ()
  ;; Plain `C-/' walks back through its own undoing: from "abd" it takes
  ;; four presses to reach "a" (abd, ab, abc, ab, a).
  (mega-undo-test--with-history '("a" "b" "c" (undo 1) "d" (undo 4) "z")
    (should (equal (mega-undo-test--picture)
                   '("o--o--o--o"
                     "   |  `--o"
                     "   `--@")))))

(ert-deftest mega-undo-tree-draws-a-long-history-without-recursing ()
  (with-temp-buffer
    (buffer-enable-undo)
    (dotimes (index 4000)
      (insert (format "%d\n" index))
      (undo-boundary))
    (let* ((tree (plist-get (mega-undo-tree--read (current-buffer)) :tree))
           (lines (mega-undo-tree-lines tree (mega-undo-tree-layout tree)
                                        (mega-undo-tree-current tree)
                                        mega-undo-test--ascii)))
      (should (= (plist-get tree :count) 4001))
      (should (= (length lines) 1))
      (should (= (length (car lines)) (1+ (* 3 4000))))
      (should (string-suffix-p "--o--@" (car lines))))))

(ert-deftest mega-undo-tree-glyphs-fall-back-to-ascii ()
  (cl-letf (((symbol-function 'char-displayable-p) #'ignore))
    (should (equal (mega-undo-tree-glyphs) mega-undo-test--ascii)))
  (cl-letf (((symbol-function 'char-displayable-p) #'always))
    (should (eq (plist-get (mega-undo-tree-glyphs) :across) ?─))))

;;;; Moving

(ert-deftest mega-undo-tree-route-is-the-shortest-replay ()
  (mega-undo-test--with-history mega-undo-test--branchy
    (let ((tree (mega-undo-test--tree)))
      ;; From the tip of a branch to its parent: undo the one group.
      (should (equal (mega-undo-tree-route tree 6 1) '(10 . 9)))
      (should-not (mega-undo-tree-route tree 6 6)))))

(ert-deftest mega-undo-tree-every-move-lands-on-the-text-that-was-there ()
  "The safety property: wherever you go, the text is what it was in that state."
  (mega-undo-test--with-history mega-undo-test--branchy
    (let* ((tree (mega-undo-test--tree))
           (texts (mega-undo-test--node-texts tree))
           (count (plist-get tree :count))
           (parents (plist-get tree :parent)))
      (random "mega-undo")
      (dotimes (_ 200)
        (let ((target (random count)))
          (mega-undo-test--go target)
          (should (equal (buffer-string) (aref texts target)))
          (let ((now (mega-undo-test--tree)))
            ;; Moving makes no new state and loses none.
            (should (= (plist-get now :count) count))
            (should (equal (seq-take (plist-get now :parent) count)
                           (seq-take parents count)))
            (should (= (mega-undo-tree-current now) target))))))))

(ert-deftest mega-undo-tree-moves-are-ordinary-undoable-changes ()
  (mega-undo-test--with-history '("a" "b" "c")
    (let ((inhibit-message t))
      (mega-undo-test--go 1)
      (should (equal (buffer-string) "a"))
      ;; `C-/' undoes the move, as it would any change.
      (let ((last-command nil)) (undo 1))
      (should (equal (buffer-string) "abc")))))

(ert-deftest mega-undo-tree-going-there-and-back-leaves-the-list-as-it-was ()
  (mega-undo-test--with-history '("a" "b" "c")
    (let ((before (mega-undo-tree--strip buffer-undo-list)))
      (mega-undo-test--go 1)
      (should-not (eq (mega-undo-tree--strip buffer-undo-list) before))
      (mega-undo-test--go 3)
      (should (equal (buffer-string) "abc"))
      (should (eq (mega-undo-tree--strip buffer-undo-list) before)))))

(ert-deftest mega-undo-tree-never-discards-history-on-the-list-s-word-alone ()
  "Cutting the list back is the one step that cannot be undone.  A claim
that two states are equal, were it ever false, must not make it happen."
  (mega-undo-test--with-history '("a" "b" "c" "d")
    (let* ((states (mega-undo-states buffer-undo-list))
           (fourth (aref states 4)))
      ;; A false claim, of the kind a misbehaving change hook could cause:
      ;; "abcd" is said to be the same text as "ab".
      (puthash fourth (aref states 2) undo-equiv-table)
      (let ((tree (mega-undo-test--tree)))
        (should (= (plist-get tree :count) 4))
        (should (= (mega-undo-tree-current tree) 2))
        ;; Go to "abc".  By the list's word the text would then be in state
        ;; 3, and everything after it could be dropped: "abcd" would be gone.
        (mega-undo-test--go 3)
        (should (equal (buffer-string) "abc"))
        (should (memq (car fourth) buffer-undo-list))
        ;; And so plain undo can still take the text back there.
        (let ((inhibit-message t) (last-command nil))
          (undo 1))
        (should (equal (buffer-string) "abcd"))))))

(ert-deftest mega-undo-tree-does-not-cut-back-when-the-text-cannot-be-compared ()
  (mega-undo-test--with-history '("a" "b" "c")
    (let ((mega-undo-max-file-size 0)
          (before (mega-undo-tree--strip buffer-undo-list)))
      (mega-undo-test--go 1)
      (mega-undo-test--go 3)
      (should (equal (buffer-string) "abc"))
      ;; Longer than it was, and nothing lost: the safe side.
      (should-not (eq (mega-undo-tree--strip buffer-undo-list) before))
      (should (memq (car before) buffer-undo-list)))))

(ert-deftest mega-undo-tree-reaches-the-oldest-state-and-comes-back ()
  (mega-undo-test--with-history '("a" "b")
    (mega-undo-test--go 0)
    (should (equal (buffer-string) ""))
    (should (= (plist-get (mega-undo-test--tree) :count) 3))
    (should (= (mega-undo-tree-current (mega-undo-test--tree)) 0))
    (mega-undo-test--go 2)
    (should (equal (buffer-string) "ab"))
    (should (= (plist-get (mega-undo-test--tree) :count) 3))))

(ert-deftest mega-undo-tree-stays-sound-when-emacs-discards-old-history ()
  "Cutting the list, as garbage collection does, must not fake an equality."
  (mega-undo-test--with-history '("a" "b" "c")
    (mega-undo-test--go 0)              ; state 4 is the oldest text, by token
    (mega-undo-test--note)
    (mega-undo-test--go 1)              ; state 5 is the text of state 1
    (mega-undo-test--note)
    ;; Discard the oldest group the way Emacs does: end the list just before
    ;; the boundary in front of it.
    (let* ((states (mega-undo-states buffer-undo-list))
           (tail buffer-undo-list))
      (while (not (eq (cddr tail) (aref states 1)))
        (setq tail (cdr tail)))
      (setcdr tail nil))
    ;; Every state is one older now, and the oldest text is "a".
    (let ((texts (make-hash-table)))
      (maphash (lambda (state text)
                 (when (> state 0) (puthash (1- state) text texts)))
               mega-undo-test--texts)
      (setq mega-undo-test--texts texts))
    (let* ((tree (mega-undo-test--tree))
           (texts (mega-undo-test--node-texts tree)))
      ;; Neither "back to the oldest state" nor "same as state 1" can be
      ;; believed any more; both become states of their own.
      (should (equal texts ["a" "ab" "abc" "" "a"]))
      (dolist (target '(0 3 2 4 1 0 4))
        (mega-undo-test--go target)
        (should (equal (buffer-string) (aref texts target)))))))

(ert-deftest mega-undo-tree-replay-refuses-to-vouch-for-a-broken-walk ()
  (mega-undo-test--with-history '("a" "b" "c")
    (let* ((states (mega-undo-states buffer-undo-list))
           (stranger (list '(1 . 2))))
      ;; A destination that is not on the way: the walk runs out.
      (aset states 1 stranger)
      (should-error (mega-undo-tree--replay states 3 1))
      ;; What was undone is recorded as changes; nothing claims more.
      (should (equal (buffer-string) ""))
      (should-not (gethash (mega-undo-tree--strip buffer-undo-list)
                           undo-equiv-table)))))

(ert-deftest mega-undo-tree-choosers-follow-the-shape ()
  (mega-undo-test--with-history mega-undo-test--branchy
    (let ((tree (mega-undo-test--tree)))
      (should (= (mega-undo-tree-parent tree 6) 1))
      (should-not (mega-undo-tree-parent tree 0))
      (should (= (mega-undo-tree-child tree 1) 2))
      (should-not (mega-undo-tree-child tree 6))
      (should (= (mega-undo-tree-next tree 2) 4))
      (should (= (mega-undo-tree-previous tree 6) 4))
      (should-not (mega-undo-tree-next tree 6))
      (should-not (mega-undo-tree-previous tree 2))
      (should (= (mega-undo-tree-start tree 5) 1))
      (should (= (mega-undo-tree-start tree 1) 0))
      (should (= (mega-undo-tree-end tree 0) 3))
      (should-not (mega-undo-tree-end tree 3)))))

;;;; The window

(defmacro mega-undo-test--in-window (actions &rest body)
  "Run BODY in a window showing a buffer whose history was made by ACTIONS."
  (declare (indent 1) (debug (form body)))
  `(let ((buffer (generate-new-buffer "undo-test"))
         (mega-undo-test--texts (make-hash-table)))
     (save-window-excursion
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (buffer-enable-undo)
             (apply #'mega-undo-test--do ,actions)
             ,@body)
         (dolist (each (buffer-list))
           (when (string-prefix-p "*undo: " (buffer-name each))
             (kill-buffer each)))
         (kill-buffer buffer)))))

(ert-deftest mega-undo-tree-window-shows-the-tree-and-moves-the-text ()
  (mega-undo-test--in-window '("a" "b" "c")
    (mega-undo-tree)
    (should (derived-mode-p 'mega-undo-tree-mode))
    (should (eq mega-undo-tree--buffer buffer))
    (should (string-match-p "\\`o..o..o..@\n\\'" (buffer-string)))
    ;; Point sits on the current state.
    (should (eq (char-after) ?@))
    (mega-undo-tree-backward)
    (should (equal (mega-test-buffer-string buffer) "ab"))
    (should (string-match-p "\\`o..o..@..o\n\\'" (buffer-string)))
    (should (eq (char-after) ?@))
    (mega-undo-tree-branch-start)
    (should (equal (mega-test-buffer-string buffer) ""))
    (mega-undo-tree-branch-end)
    (should (equal (mega-test-buffer-string buffer) "abc"))
    ;; At the end of a branch, forward is a no-op, not an error.
    (mega-undo-tree-forward)
    (should (equal (mega-test-buffer-string buffer) "abc"))))

(ert-deftest mega-undo-tree-quit-keeps-and-cancel-puts-back ()
  (mega-undo-test--in-window '("a" "b" "c")
    (mega-undo-tree)
    (mega-undo-tree-backward)
    (mega-undo-tree-backward)
    (mega-undo-tree-quit)
    (should (eq (current-buffer) buffer))
    (should (equal (buffer-string) "a"))
    (should-not (get-buffer "*undo: undo-test*"))
    (mega-undo-tree)
    (mega-undo-tree-forward)
    (mega-undo-tree-forward)
    (should (equal (mega-test-buffer-string buffer) "abc"))
    (mega-undo-tree-cancel)
    (should (eq (current-buffer) buffer))
    (should (equal (buffer-string) "a"))))

(ert-deftest mega-undo-tree-refuses-where-undoing-would-be-wrong ()
  (with-temp-buffer
    (buffer-enable-undo)
    (should-error (mega-undo-tree) :type 'user-error)   ; nothing changed yet
    (insert "one\ntwo\n")
    (undo-boundary)
    (save-restriction
      (narrow-to-region 1 4)
      (should-error (mega-undo-tree) :type 'user-error))
    (setq buffer-read-only t)
    (should-error (mega-undo-tree) :type 'buffer-read-only)
    (setq buffer-read-only nil)
    (buffer-disable-undo)
    (should-error (mega-undo-tree) :type 'user-error)
    (should (equal (buffer-string) "one\ntwo\n"))))

;;;; Keeping the history between sessions

(defmacro mega-undo-test--with-file (file &rest body)
  "Run BODY with FILE bound to a file name where undo history may be kept."
  (declare (indent 1) (debug (symbolp body)))
  `(mega-test-with-directory directory
     (let ((,file (expand-file-name "notes.txt" directory))
           ;; The sandbox is under /tmp, which is normally left out.
           (mega-undo-exclude-regexps nil)
           (mega-undo-test--texts (make-hash-table)))
       (puthash 0 "" mega-undo-test--texts)
       ,@body)))

(defun mega-undo-test--save ()
  "Save the current buffer quietly, and exactly as it is.
The texts these tests compare end without a newline; adding one on the
way out would be one more change than they wrote down."
  (let ((inhibit-message t) (require-final-newline nil))
    (save-buffer)))

(ert-deftest mega-undo-history-comes-back-with-the-file ()
  (mega-undo-test--with-file file
    (let (texts parents)
      (mega-test-visiting buffer file
        (apply #'mega-undo-test--do mega-undo-test--branchy)
        (let ((tree (mega-undo-test--tree)))
          (setq texts (mega-undo-test--node-texts tree)
                parents (seq-take (plist-get tree :parent) (plist-get tree :count))))
        (mega-undo-test--save))
      (should (file-exists-p (mega-undo--file file)))
      (mega-test-visiting buffer file
        (should (equal (buffer-string) "az"))
        (should (consp buffer-undo-list))
        (should-not (buffer-modified-p))
        ;; The same tree, and every state of it still holds the same text.
        (let ((tree (mega-undo-test--tree)))
          (should (equal (seq-take (plist-get tree :parent) (plist-get tree :count))
                         parents))
          (dolist (target '(5 0 3 6 2 4 1 0 6))
            (mega-undo-test--go target)
            (should (equal (buffer-string) (aref texts target)))))))))

(ert-deftest mega-undo-plain-undo-works-on-a-restored-history ()
  (mega-undo-test--with-file file
    (mega-test-visiting buffer file
      (mega-undo-test--do "one\n" "two\n" "three\n")
      (mega-undo-test--save))
    (mega-test-visiting buffer file
      (let ((inhibit-message t) (last-command nil))
        (undo 1)
        (should (equal (buffer-string) "one\ntwo\n"))
        (setq last-command 'undo)
        (undo 1)
        (should (equal (buffer-string) "one\n"))))))

(ert-deftest mega-undo-history-is-not-used-on-a-text-that-changed ()
  (mega-undo-test--with-file file
    (mega-test-visiting buffer file
      (mega-undo-test--do "one\n" "two\n")
      (mega-undo-test--save))
    ;; Another program rewrites the file.
    (mega-test-write file "one" "2" "")
    (mega-test-visiting buffer file
      (should (equal (buffer-string) "one\n2\n"))
      (should-not buffer-undo-list))))

(ert-deftest mega-undo-no-history-is-kept-for-private-or-excluded-files ()
  (mega-test-with-directory directory
    (let ((mega-undo-exclude-regexps '("\\.generated\\'")))
      (dolist (name '(".env" "id_ed25519" "secrets.yaml" "COMMIT_EDITMSG"
                      "parser.generated"))
        (let ((file (expand-file-name name directory)))
          (mega-test-visiting buffer file
            (insert "token = hunter2\n")
            (mega-undo-test--save))
          (should (file-exists-p file))
          (should-not (file-exists-p (mega-undo--file file)))))
      ;; The contrast: the same edit in an ordinary file is kept.
      (let ((file (expand-file-name "notes.txt" directory)))
        (mega-test-visiting buffer file
          (insert "hello\n")
          (mega-undo-test--save))
        (should (file-exists-p (mega-undo--file file)))))
    ;; And as shipped, temporary files are left out.
    (let ((buffer-file-name "/tmp/scratch.txt")
          (mega-temporary-directories mega-test-temporary-directories))
      (should-not (mega-undo--wanted-p)))))

(ert-deftest mega-undo-switching-it-off-keeps-nothing ()
  (mega-undo-test--with-file file
    (let ((mega-undo-persist nil))
      (mega-test-visiting buffer file
        (insert "hello\n")
        (mega-undo-test--save)))
    (should-not (file-exists-p (mega-undo--file file)))))

(ert-deftest mega-undo-stored-history-is-private-data-without-the-file-name ()
  (mega-undo-test--with-file file
    (mega-test-visiting buffer file
      (insert (propertize "hello\n" 'face 'bold))
      (undo-boundary)
      (delete-region 1 3)
      (mega-undo-test--save))
    (let ((stored (mega-undo--file file)))
      (should (file-in-directory-p stored mega-state-dir))
      (should (= (logand (file-modes (file-name-directory stored)) #o777) #o700))
      (should-not (file-exists-p (concat stored ".new")))
      (with-temp-buffer
        (insert-file-contents stored)
        ;; Neither the name of the file nor a text property is written.
        (should-not (search-forward "notes.txt" nil t))
        (should-not (search-forward "bold" nil t))
        (goto-char (point-min))
        (should (search-forward "(\"he\" . 1)" nil t))))))

(ert-deftest mega-undo-function-calls-are-never-stored ()
  "Everything older than a record that calls a function is left behind."
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "a") (undo-boundary)
    (push '(apply delete-file "/nonexistent") buffer-undo-list)
    (undo-boundary)
    (insert "b") (undo-boundary)
    (insert "c") (undo-boundary)
    (let ((groups (mega-undo-encode buffer-undo-list)))
      (should (= (length groups) 2))
      (should (mega-undo--valid-p groups))
      (should-not (string-match-p "apply\\|delete-file" (prin1-to-string groups))))))

(ert-deftest mega-undo-reading-accepts-insertions-and-deletions-only ()
  (should (mega-undo--valid-p '((nil (1 . 2)) (2 ("x" . 1) 3) (nil ("y" . -4)))))
  (dolist (bad '(nil
                 "text"
                 ((nil))                                   ; an empty group
                 ((nil (apply delete-file "/etc/passwd")))
                 ((nil (apply 1 1 2 delete-file "/etc/passwd")))
                 ((nil (t . 0)))
                 ((nil (nil face bold 1 . 2)))
                 ((nil (2 . 1)))                           ; ends before it starts
                 ((nil (0 . 1)))
                 ((nil ("x" . 0)))
                 ((nil (#("zz" 0 2 (display (when (danger) . "x"))) . 1)))
                 ((nil (#("zz" 0 1 (modification-hooks (danger))) . 1)))
                 ((nil ("x" . 1) . 5))                     ; not a proper list
                 ((0 (1 . 2)))                             ; "same as itself"
                 ((x (1 . 2)))
                 ((nil #[nil "\300\207" [t] 1]))))
    (should-not (mega-undo--valid-p bad))))

(ert-deftest mega-undo-a-tampered-history-is-ignored ()
  (mega-undo-test--with-file file
    (mega-test-visiting buffer file
      (insert "hello\n")
      (mega-undo-test--save))
    (let ((stored (mega-undo--file file)))
      ;; Keep the fingerprint, replace the history with a function call.
      (with-temp-buffer
        (insert-file-contents stored)
        (goto-char (point-min))
        (forward-line 2)
        (delete-region (point) (point-max))
        (insert "((nil (apply delete-file \"" file "\")))\n")
        (write-region nil nil stored nil :silent))
      (mega-test-visiting buffer file
        (should-not buffer-undo-list))
      (should (file-exists-p file))
      ;; A file that is not even Lisp is ignored as quietly.
      (mega-test-write stored "((((")
      ;; ERT turns errors into failures before anything can catch them;
      ;; outside a test a failure to restore is a line in *Messages*.
      (let ((inhibit-message t) (debug-on-error nil))
        (mega-test-visiting buffer file
          (should-not buffer-undo-list))))))

(ert-deftest mega-undo-a-stored-history-is-read-without-shared-structure ()
  "Nothing MEGA writes refers back to itself; a file that does is not MEGA's."
  (mega-undo-test--with-file file
    (mega-test-visiting buffer file
      (insert "hello\n")
      (mega-undo-test--save))
    (let ((stored (mega-undo--file file)))
      (with-temp-buffer
        (insert-file-contents stored)
        (goto-char (point-min))
        (forward-line 2)
        (delete-region (point) (point-max))
        ;; A list that contains itself.
        (insert "(#1=(nil (1 . 2) . #1#))\n")
        (write-region nil nil stored nil :silent))
      (let ((inhibit-message t) (debug-on-error nil))
        (mega-test-visiting buffer file
          (should-not buffer-undo-list))))))

(ert-deftest mega-undo-only-the-newest-history-is-kept-when-it-is-large ()
  (with-temp-buffer
    (buffer-enable-undo)
    (dotimes (_ 10)
      (insert (make-string 100 ?x))
      (undo-boundary)
      (delete-region 1 101)
      (undo-boundary))
    ;; Each deletion holds 100 characters; room for about four of them.
    (let* ((mega-undo-persist-limit 500)
           (groups (mega-undo-encode buffer-undo-list)))
      (should (< 4 (length groups) 12))
      (should (mega-undo--valid-p groups))
      ;; The newest change is the first one stored.
      (should (equal (car (cadr (car groups))) (make-string 100 ?x))))
    (let ((mega-undo-persist-limit 10))
      (should-not (mega-undo-encode buffer-undo-list)))))

(ert-deftest mega-undo-a-change-of-properties-only-does-not-shift-the-rest ()
  "Such a group is not stored; what pointed past it must still point right."
  (mega-undo-test--with-file file
    (let (texts)
      (mega-test-visiting buffer file
        (mega-undo-test--do "a" "b"
                            (lambda () (put-text-property 1 2 'face 'bold))
                            "c" '(undo 3) "z")
        (setq texts (mega-undo-test--node-texts (mega-undo-test--tree)))
        (should (equal texts ["" "a" "ab" "ab" "abc" "az"]))
        (mega-undo-test--save))
      (mega-test-visiting buffer file
        (let* ((tree (mega-undo-test--tree))
               (count (plist-get tree :count)))
          ;; One state fewer: the two that only differed in a property.
          (should (= count 5))
          (should (equal (seq-take (plist-get tree :parent) count) [nil 0 1 2 1]))
          (dolist (step '((3 . "abc") (1 . "a") (2 . "ab") (4 . "az") (0 . "")))
            (mega-undo-test--go (car step))
            (should (equal (buffer-string) (cdr step)))))))))

(ert-deftest mega-undo-hashing-never-asks-about-an-encoding ()
  (with-temp-buffer
    (insert "λ and 日本語")
    (setq buffer-file-coding-system 'iso-latin-1)
    (let ((select-safe-coding-system-function
           (lambda (&rest _) (error "Asked which encoding to use"))))
      (should (equal (cadr (mega-undo--fingerprint)) (buffer-size)))
      (should (= (length (car (mega-undo--fingerprint))) 40)))))

(ert-deftest mega-undo-forgetting-deletes-what-was-stored ()
  (mega-undo-test--with-file file
    (mega-test-visiting buffer file
      (insert "hello\n")
      (mega-undo-test--save)
      (should (file-exists-p (mega-undo--file file)))
      (let ((inhibit-message t)) (mega-undo-forget))
      (should-not (file-exists-p (mega-undo--file file))))))

(ert-deftest mega-undo-old-histories-are-pruned-and-used-ones-are-not ()
  (mega-undo-test--with-file file
    (let ((other (expand-file-name "other.txt" (file-name-directory file)))
          (long-ago (time-subtract nil (* 200 24 60 60))))
      (dolist (each (list file other))
        (mega-test-visiting buffer each
          (insert "hello\n")
          (mega-undo-test--save))
        (set-file-times (mega-undo--file each) long-ago))
      ;; Opening a file counts as using its history.
      (mega-test-visiting buffer file
        (should (consp buffer-undo-list)))
      (let ((mega-undo-keep-days 90))
        (mega-undo-prune))
      (should (file-exists-p (mega-undo--file file)))
      (should-not (file-exists-p (mega-undo--file other)))
      (set-file-times (mega-undo--file file) long-ago)
      (let ((mega-undo-keep-days nil))
        (mega-undo-prune))
      (should (file-exists-p (mega-undo--file file))))))

(ert-deftest mega-undo-storing-a-megabyte-of-history-does-not-stall-a-save ()
  (mega-undo-test--with-file file
    (mega-test-visiting buffer file
      (let ((line (concat (make-string 99 ?x) "\n")))
        (dotimes (_ 5000)
          (insert line)
          (undo-boundary)
          (delete-region (- (point) 100) (point))
          (undo-boundary))
        (insert line))
      (let ((start (float-time)))
        (mega-undo-test--save)
        ;; Generous: this guards against a quadratic walk, not a slow disk.
        (should (< (- (float-time) start) 2.0)))
      (should (> (file-attribute-size (file-attributes (mega-undo--file file)))
                 (* 300 1024))))))

(ert-deftest mega-undo-failing-to-store-never-fails-the-save ()
  (mega-undo-test--with-file file
    (cl-letf (((symbol-function 'mega-undo--write)
               (lambda (&rest _) (error "Disk full"))))
      (let ((inhibit-message t) (debug-on-error nil))
        (mega-test-visiting buffer file
          (insert "hello\n")
          (save-buffer)
          (should-not (buffer-modified-p)))))
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "hello\n"))))

(provide 'mega-undo-test)
;;; mega-undo-test.el ends here
