;;; mega-undo-tree.el --- The undo history, drawn as a tree  -*- lexical-binding: t; -*-

;;; Commentary:

;; `C-x u' opens a small window under the text showing every state the
;; buffer has been in:
;;
;;     o──o──o──o──@
;;        └──o──o
;;
;; Each `o' is a state; `@' is the one on screen.  A line to the right is a
;; change; a fork is where you undid something and then typed something
;; else.  Moving around the picture changes the text as you go:
;;
;;   b / f   back to the older state / forward to the newer one
;;   p / n   the other branches of the same fork
;;   a / e   the start / the end of this branch
;;   RET, q  keep the text as it is now
;;   C-g     put the text back the way it was when you pressed C-x u
;;
;; Nothing here has a history of its own.  The tree is read off Emacs's own
;; undo list every time it is drawn (mega-undo.el explains how), and moving
;; is undoing: each move is recorded in that list like any other change, so
;; `C-/' works as ever before, during and after.
;;
;; That is also the safety argument.  A move replays the records between two
;; states of the list on a text that is known to be in the first of them,
;; and says afterwards "the text is now in that older state".  Only that
;; second step could ever be wrong, so it is made only when the replay ran
;; exactly from the one state to the other; if anything else happens, the
;; change is still recorded, and the worst case is one more `o' on screen.
;;
;; One thing a move does goes beyond recording: it shortens the list again
;; where the move only led back to where the list once ended.  That throws
;; records away, so it does not rest on any claim that two states are equal:
;; it is done only back to a state in which the text was actually seen, and
;; found, by hash, to be the text there is now.
;;
;; Model and display are separate.  `mega-undo-tree-build', `-route',
;; `-layout' and `-lines' are plain functions of data and are what the tests
;; exercise; the commands at the end are thin.

;;; Code:

(require 'mega-lib)
(require 'mega-undo)

(defcustom mega-undo-tree-max-height 10
  "The tree window is never taller than this many lines."
  :type 'natnum
  :group 'mega)

(defface mega-undo-tree-current '((t :inherit (bold warning)))
  "The state of the text that is on screen."
  :group 'mega)

(defface mega-undo-tree-line '((t :inherit shadow))
  "The lines joining the states of the undo tree."
  :group 'mega)

;;;; The tree

(defun mega-undo-tree-build (same)
  "The tree of distinct states, from SAME, what `mega-undo-equivalents' returns.
Several states of the undo list may be the same text; a NODE is one
text.  Nodes are numbered from 0, the oldest.  The tree is a plist:

  :count     how many nodes there are
  :node      vector, state -> its node
  :parent    vector, node -> the node it was made from; nil for node 0
  :children  vector, node -> the nodes made from it, oldest first
  :states    vector, node -> its states, oldest first"
  (let* ((total (length same))
         (node (make-vector total 0))
         (parent (make-vector total nil))
         (children (make-vector total nil))
         (states (make-vector total nil))
         (count 1))
    (aset states 0 (list 0))
    (dotimes (state total)
      (when (> state 0)
        (let ((older (aref same state)))
          (if older
              (aset node state (aref node older))
            (let ((from (aref node (1- state))))
              (aset node state count)
              (aset parent count from)
              (aset children from (cons count (aref children from)))
              (setq count (1+ count)))))
        (let ((this (aref node state)))
          (aset states this (cons state (aref states this))))))
    (dotimes (index count)
      (aset children index (nreverse (aref children index)))
      (aset states index (nreverse (aref states index))))
    (list :count count :node node :parent parent :children children :states states)))

(defun mega-undo-tree-current (tree)
  "The node of TREE the text is in now: that of the newest state."
  (let ((node (plist-get tree :node)))
    (aref node (1- (length node)))))

(defun mega-undo-tree-route (tree from to)
  "How to take the text from node FROM of TREE to node TO.
Return (SOURCE . DEST), two states with SOURCE newer than DEST, such
that the text is in SOURCE now and undoing down to DEST leaves it in TO;
of all such pairs, the one with the fewest groups between.  Return nil
if FROM and TO are the same node."
  (unless (= from to)
    (let ((sources (aref (plist-get tree :states) from))
          (best nil))
      (dolist (dest (aref (plist-get tree :states) to))
        ;; Both lists are oldest first: the first source newer than DEST
        ;; is the nearest one.
        (when-let* ((source (seq-find (lambda (state) (> state dest)) sources)))
          (when (or (null best) (< (- source dest) (- (car best) (cdr best))))
            (setq best (cons source dest)))))
      best)))

(defun mega-undo-tree-trim-points (tree)
  "The states TREE's undo list could be cut back to without losing a node.
Moving about adds groups to the list that lead only to states it already
had.  The list may end at any state of the current node that is no older
than the newest node: every node then still has the state that made it.
Return those states, oldest first, without the newest state of all, at
which the list ends anyway.

Whether the text really is what such a state says is for the caller to
check; see `mega-undo-tree-go'."
  (let* ((states (plist-get tree :states))
         (last (1- (length (plist-get tree :node))))
         (newest 0))
    (dotimes (node (plist-get tree :count))
      (setq newest (max newest (car (aref states node)))))
    (seq-filter (lambda (state) (and (>= state newest) (< state last)))
                (aref states (mega-undo-tree-current tree)))))

;;;; Where each node is drawn

(defun mega-undo-tree-layout (tree)
  "Where each node of TREE is drawn: a vector, node -> (ROW . COLUMN).
A node's first child continues its row; every other child starts a new
row below everything drawn so far.  Columns count nodes, not characters."
  (let* ((children (plist-get tree :children))
         (places (make-vector (plist-get tree :count) nil))
         (bottom 0)
         (pending (list (cons 0 (aref children 0)))))
    (aset places 0 (cons 0 0))
    ;; Depth first, without recursion: a history is easily deeper than
    ;; Lisp lets a function call itself.
    (while pending
      (let* ((frame (car pending))
             (node (car frame)))
        (if (null (cdr frame))
            (pop pending)
          (let ((child (cadr frame)))
            (setcdr frame (cddr frame))
            (aset places child
                  (cons (if (eq child (car (aref children node)))
                            (car (aref places node))
                          (setq bottom (1+ bottom)))
                        (1+ (cdr (aref places node)))))
            (push (cons child (aref children child)) pending)))))
    places))

(defun mega-undo-tree-glyphs ()
  "The characters the tree is drawn with: a plist.
Box-drawing characters where the terminal has them, ASCII otherwise."
  (if (and (char-displayable-p ?─) (char-displayable-p ?└))
      '(:node ?o :current ?@ :across ?─ :down ?│ :fork ?├ :last ?└)
    '(:node ?o :current ?@ :across ?- :down ?| :fork ?+ :last ?`)))

(defun mega-undo-tree--put (cells row column character)
  "Note in CELLS that CHARACTER is drawn at COLUMN of ROW."
  (aset cells row (cons (cons column character) (aref cells row))))

(defun mega-undo-tree-lines (tree places current glyphs)
  "The picture of TREE as a list of strings, one per row.
PLACES is its `mega-undo-tree-layout', CURRENT the node to mark, GLYPHS
what `mega-undo-tree-glyphs' returns.  A node is drawn in the row of its
place, at three times the column of its place."
  (let* ((count (plist-get tree :count))
         (children (plist-get tree :children))
         (across (plist-get glyphs :across))
         (rows 0))
    (dotimes (node count)
      (setq rows (max rows (1+ (car (aref places node))))))
    (let ((cells (make-vector rows nil)))
      (dotimes (node count)
        (let* ((row (car (aref places node)))
               (column (* 3 (cdr (aref places node))))
               (kids (aref children node))
               (others (cdr kids))
               (from (1+ row)))
          (mega-undo-tree--put cells row column
                               (plist-get glyphs (if (= node current) :current :node)))
          (when kids
            (mega-undo-tree--put cells row (+ column 1) across)
            (mega-undo-tree--put cells row (+ column 2) across))
          ;; The other children hang below, from a line going down.
          (while others
            (let ((to (car (aref places (car others)))))
              (while (< from to)
                (mega-undo-tree--put cells from column (plist-get glyphs :down))
                (setq from (1+ from)))
              (mega-undo-tree--put cells to column
                                   (plist-get glyphs (if (cdr others) :fork :last)))
              (mega-undo-tree--put cells to (+ column 1) across)
              (mega-undo-tree--put cells to (+ column 2) across)
              (setq from (1+ to)
                    others (cdr others))))))
      (mapcar (lambda (row)
                (let ((width 0))
                  (dolist (cell row)
                    (setq width (max width (1+ (car cell)))))
                  ;; A vector, because a string cannot take a character
                  ;; wider than the one it replaces.
                  (let ((line (make-vector width ?\s)))
                    (dolist (cell row)
                      (aset line (car cell) (cdr cell)))
                    (concat line))))
              cells))))

;;;; Moving the text from one state to another

(defun mega-undo-tree--read (buffer)
  "Read BUFFER's undo list: a plist of :list, :states, :origin and :tree."
  (with-current-buffer buffer
    (let* ((list buffer-undo-list)
           (states (mega-undo-states list))
           (origin (mega-undo-origin list)))
      (list :list list :states states :origin origin
            :tree (mega-undo-tree-build (mega-undo-equivalents states origin))))))

(defun mega-undo-tree--strip (list)
  "LIST without the boundaries it starts with."
  (while (and (consp list) (null (car list)))
    (setq list (cdr list)))
  list)

(defun mega-undo-tree--replay (states source dest)
  "Undo, in the current buffer, the groups between states SOURCE and DEST.
STATES is the `mega-undo-states' of the buffer's undo list, and the text
must be in state SOURCE.  Afterwards it is in state DEST, and Emacs is
told so.  Signal an error, and tell Emacs nothing, if the replay did not
end exactly at DEST."
  (let ((list (aref states source))
        (end (aref states dest))
        (undo-in-progress t)
        ;; Emacs shortens undo lists when it collects garbage, by cutting
        ;; them, and this one is being walked.
        (undo-limit most-positive-fixnum)
        (undo-strong-limit most-positive-fixnum)
        (undo-outer-limit nil))
    (while (and (consp list) (not (eq list end)))
      (setq list (mega-undo-tree--strip (primitive-undo 1 list))))
    (unless (eq list end)
      (error "The undo history changed while it was being replayed"))
    (undo-boundary)
    (let ((made (mega-undo-tree--strip buffer-undo-list)))
      (when (and (consp made) (not (eq made (aref states source))))
        (puthash made
                 (or end (mega-undo-origin buffer-undo-list t))
                 undo-equiv-table)))))

(defvar-local mega-undo-tree--seen nil
  "The text this buffer was seen to have in states of its undo list.
A hash table from the tail of the list that begins a state to a hash of
the text, noted whenever the text is known to be in that state: when the
list ends there.")

(defun mega-undo-tree--text-hash ()
  "A hash of the whole text of the current buffer, or nil if it is too large."
  (when (<= (buffer-size) mega-undo-max-file-size)
    (car (mega-undo--fingerprint))))

(defun mega-undo-tree--note-state ()
  "Note that the current text is the state the undo list now ends in."
  (let ((head (mega-undo-tree--strip buffer-undo-list))
        (hash (mega-undo-tree--text-hash)))
    (when (and (consp head) hash)
      (unless mega-undo-tree--seen
        (setq mega-undo-tree--seen (make-hash-table :test #'eq :weakness 'key)))
      (puthash head hash mega-undo-tree--seen))))

(defun mega-undo-tree-go (buffer choose)
  "Move BUFFER's text to another node of its undo tree.
CHOOSE is called with the tree and the current node, and returns the
node to go to, or nil for none.  Return non-nil if the text moved.

A move adds a group to the undo list.  Where that only leads back to a
state the list already ended in once, the list is cut back to there, so
that wandering about does not push your oldest history out.  Cutting
discards records, and is the one thing here that could not be undone, so
it is done on evidence and not on the list's word: only back to a state
in which this very text was seen, compared by hash."
  (with-current-buffer buffer
    (barf-if-buffer-read-only)
    (when (buffer-narrowed-p)
      (user-error "The buffer is narrowed: widen it first (C-x n w)"))
    (undo-boundary)
    (let* ((read (mega-undo-tree--read buffer))
           (tree (plist-get read :tree))
           (current (mega-undo-tree-current tree))
           (target (funcall choose tree current))
           (route (and target (mega-undo-tree-route tree current target))))
      (when route
        (mega-undo-tree--note-state)
        (mega-undo-tree--replay (plist-get read :states) (car route) (cdr route))
        (mega-undo-tree--note-state)
        (let* ((read (mega-undo-tree--read buffer))
               (states (plist-get read :states))
               (hash (mega-undo-tree--text-hash))
               (state (and hash
                           (seq-find (lambda (state)
                                       (equal (gethash (aref states state)
                                                       mega-undo-tree--seen)
                                              hash))
                                     (mega-undo-tree-trim-points (plist-get read :tree))))))
          (when state
            (setq buffer-undo-list (aref states state))
            (undo-boundary)))
        t))))

;;;; Choosing where to go

(defun mega-undo-tree-parent (tree node)
  "The node NODE of TREE was made from."
  (aref (plist-get tree :parent) node))

(defun mega-undo-tree-child (tree node)
  "The first node made from NODE of TREE."
  (car (aref (plist-get tree :children) node)))

(defun mega-undo-tree--sibling (tree node step)
  "The node STEP places after NODE among the children of its parent in TREE."
  (when-let* ((parent (mega-undo-tree-parent tree node)))
    (let* ((siblings (aref (plist-get tree :children) parent))
           (index (+ step (seq-position siblings node))))
      (and (>= index 0) (nth index siblings)))))

(defun mega-undo-tree-next (tree node)
  "The next branch of the fork NODE of TREE hangs from."
  (mega-undo-tree--sibling tree node 1))

(defun mega-undo-tree-previous (tree node)
  "The previous branch of the fork NODE of TREE hangs from."
  (mega-undo-tree--sibling tree node -1))

(defun mega-undo-tree-start (tree node)
  "The nearest fork above NODE of TREE, or the oldest node."
  (let ((parent (mega-undo-tree-parent tree node)))
    (while (and parent
                (mega-undo-tree-parent tree parent)
                (null (cdr (aref (plist-get tree :children) parent))))
      (setq parent (mega-undo-tree-parent tree parent)))
    parent))

(defun mega-undo-tree-end (tree node)
  "The last node of the branch NODE of TREE is on."
  (let ((end nil) (child (mega-undo-tree-child tree node)))
    (while child
      (setq end child
            child (mega-undo-tree-child tree child)))
    end))

;;;; The window

(defvar-local mega-undo-tree--buffer nil
  "The buffer whose history this tree buffer shows.")

(defvar-local mega-undo-tree--entry nil
  "Where the text was when the tree was opened: (STATE-TAIL . LAST-CONS).
STATE-TAIL is the tail of the undo list that begins the oldest state of
that node, or `origin'; LAST-CONS is the last cons the list had.")

(defun mega-undo-tree--draw ()
  "Draw the tree of the buffer this tree buffer belongs to."
  (let* ((tree (plist-get (mega-undo-tree--read mega-undo-tree--buffer) :tree))
         (places (mega-undo-tree-layout tree))
         (current (mega-undo-tree-current tree))
         (glyphs (mega-undo-tree-glyphs))
         (inhibit-read-only t))
    (erase-buffer)
    (dolist (line (mega-undo-tree-lines tree places current glyphs))
      (insert (propertize line 'face 'mega-undo-tree-line) "\n"))
    (goto-char (point-min))
    (forward-line (car (aref places current)))
    (forward-char (* 3 (cdr (aref places current))))
    (put-text-property (point) (1+ (point)) 'face 'mega-undo-tree-current)
    (when-let* ((window (get-buffer-window (current-buffer))))
      (set-window-point window (point)))))

(defun mega-undo-tree--move (choose)
  "Move to the node CHOOSE picks and draw the tree again."
  (let ((buffer mega-undo-tree--buffer))
    (unless (buffer-live-p buffer)
      (mega-undo-tree-quit)
      (user-error "The buffer this tree belonged to is gone"))
    (let ((window (get-buffer-window buffer)))
      ;; Undoing moves point to the change; do it in a window showing the
      ;; text, so that the change is what you see.
      (if window
          (with-selected-window window (mega-undo-tree-go buffer choose))
        (mega-undo-tree-go buffer choose)))
    (mega-undo-tree--draw)))

(defun mega-undo-tree-backward ()
  "Go to the older state this one was made from."
  (interactive)
  (mega-undo-tree--move #'mega-undo-tree-parent))

(defun mega-undo-tree-forward ()
  "Go to the newer state made from this one."
  (interactive)
  (mega-undo-tree--move #'mega-undo-tree-child))

(defun mega-undo-tree-next-branch ()
  "Go to the next branch of this fork."
  (interactive)
  (mega-undo-tree--move #'mega-undo-tree-next))

(defun mega-undo-tree-previous-branch ()
  "Go to the previous branch of this fork."
  (interactive)
  (mega-undo-tree--move #'mega-undo-tree-previous))

(defun mega-undo-tree-branch-start ()
  "Go back to where this branch forks off."
  (interactive)
  (mega-undo-tree--move #'mega-undo-tree-start))

(defun mega-undo-tree-branch-end ()
  "Go to the end of this branch."
  (interactive)
  (mega-undo-tree--move #'mega-undo-tree-end))

(defun mega-undo-tree-quit ()
  "Close the tree and keep the text as it is now."
  (interactive)
  (let ((tree (current-buffer))
        (window (and (buffer-live-p mega-undo-tree--buffer)
                     (get-buffer-window mega-undo-tree--buffer))))
    (when-let* ((own (get-buffer-window tree)))
      (ignore-errors (delete-window own)))
    (kill-buffer tree)
    (when (window-live-p window)
      (select-window window))))

(defun mega-undo-tree-cancel ()
  "Close the tree and put the text back the way it was when it opened."
  (interactive)
  (let ((entry mega-undo-tree--entry)
        (buffer mega-undo-tree--buffer))
    (when (buffer-live-p buffer)
      (if (not (eq (cdr entry) (with-current-buffer buffer (last buffer-undo-list))))
          (message "Emacs has discarded the oldest history meanwhile: the text stays as it is")
        (mega-undo-tree--move
         (lambda (tree _current)
           (if (eq (car entry) 'origin)
               0
             (let* ((states (mega-undo-states
                             (with-current-buffer buffer buffer-undo-list)))
                    (state (seq-position states (car entry) #'eq)))
               (and state (aref (plist-get tree :node) state))))))))
    (mega-undo-tree-quit)))

(defvar mega-undo-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("b" . mega-undo-tree-backward) ("<left>" . mega-undo-tree-backward)
                       ("C-b" . mega-undo-tree-backward)
                       ("f" . mega-undo-tree-forward) ("<right>" . mega-undo-tree-forward)
                       ("C-f" . mega-undo-tree-forward)
                       ("n" . mega-undo-tree-next-branch) ("<down>" . mega-undo-tree-next-branch)
                       ("C-n" . mega-undo-tree-next-branch)
                       ("p" . mega-undo-tree-previous-branch) ("<up>" . mega-undo-tree-previous-branch)
                       ("C-p" . mega-undo-tree-previous-branch)
                       ("a" . mega-undo-tree-branch-start) ("C-a" . mega-undo-tree-branch-start)
                       ("e" . mega-undo-tree-branch-end) ("C-e" . mega-undo-tree-branch-end)
                       ("RET" . mega-undo-tree-quit) ("q" . mega-undo-tree-quit)
                       ("C-g" . mega-undo-tree-cancel)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Keys of the undo tree window.")

(define-derived-mode mega-undo-tree-mode special-mode "Undo"
  "The undo history of a buffer, drawn as a tree.  See mega-undo-tree.el.

\\{mega-undo-tree-mode-map}"
  (setq truncate-lines t
        cursor-type nil
        header-line-format
        " b/f older/newer   p/n other branch   a/e start/end   RET keep   C-g put back"))

;;;###autoload
(defun mega-undo-tree ()
  "Show the undo history of this buffer as a tree, and move around in it."
  (interactive)
  (cond
   ((minibufferp) (call-interactively #'undo))
   ((eq buffer-undo-list t)
    (user-error "This buffer keeps no undo history"))
   (t
    (barf-if-buffer-read-only)
    (when (buffer-narrowed-p)
      (user-error "The buffer is narrowed: widen it first (C-x n w)"))
    (undo-boundary)
    (unless (mega-undo-tree--strip buffer-undo-list)
      (user-error "Nothing has been changed here yet"))
    (let* ((buffer (current-buffer))
           (read (mega-undo-tree--read buffer))
           (tree (plist-get read :tree))
           (node (mega-undo-tree-current tree))
           (first (car (aref (plist-get tree :states) node)))
           (entry (cons (if (= first 0) 'origin (aref (plist-get read :states) first))
                        (last buffer-undo-list)))
           (view (get-buffer-create (format "*undo: %s*" (buffer-name)))))
      (with-current-buffer view
        (mega-undo-tree-mode)
        (setq mega-undo-tree--buffer buffer
              mega-undo-tree--entry entry)
        (mega-undo-tree--draw))
      (select-window
       (display-buffer
        view
        `((display-buffer-in-side-window)
          (side . bottom)
          (window-height . ,(lambda (window)
                              (fit-window-to-buffer
                               window mega-undo-tree-max-height))))))
      ;; Point was put on the current state before there was a window.
      (set-window-point (selected-window) (point))))))

(provide 'mega-undo-tree)
;;; mega-undo-tree.el ends here
