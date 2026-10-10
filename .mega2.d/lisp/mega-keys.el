;;; mega-keys.el --- Every MEGA binding, in one table  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every key MEGA binds is a row of `mega-keys' below.  The keymap is built
;; from that table, and so is the cheat sheet (`C-c ?'), so the two cannot
;; drift apart: a key that is not in the table does not exist.
;;
;; The bindings live in a global minor-mode keymap rather than the global map,
;; for one concrete reason: minor-mode maps outrank major-mode maps, so a
;; MEGA key means the same thing in every buffer.  `M-x mega-keys-mode' turns
;; the whole layer off.
;;
;; A row is (KEY COMMAND DESCRIPTION [WHERE]).  KEY is in `kbd' notation, or
;; nil for a command that has no key and is listed in the cheat sheet as
;; `M-x'.  COMMAND may also name a keymap, which makes KEY a prefix.
;; DESCRIPTION is what the cheat sheet shows; it is written here, not taken
;; from the docstring, so that showing the sheet never loads a module.
;;
;; WHERE, when given, limits a key to buffers where it makes sense, leaving
;; what Emacs had there alone everywhere else:
;;
;;   :code   buffers of source code and configuration files
;;   :text   those, and prose
;;
;; That is what keeps `M-n' meaning "next in history" at a prompt and "next
;; error" in a compilation buffer.
;;
;; Keys of your own go in the same table, so that the cheat sheet shows them.
;; In local.el, which loads before this file:
;;
;;   (with-eval-after-load 'mega-keys
;;     (mega-keys-add "Mine"
;;                    '("C-c m" my-command "What it does")
;;                    '("C-c d" my-doc     "Replaces MEGA's C-c d"))
;;     (mega-keys-remove "C-c D"))
;;
;; Some keys mean something only in one place: inside the completion menu,
;; in the undo tree, on the home page.  Those live in the keymaps of the
;; modules they belong to and are described in `mega-keys-elsewhere', which
;; the cheat sheet prints after the table.  A test holds that description to
;; the keymaps, key by key and in both directions.

;;; Code:

(require 'mega-lib)

(defvar mega-keys
  '(("Help"
     ("C-c ?" mega-help   "This cheat sheet")
     ("C-c h" mega-home   "The home page: continue, recent projects")
     (nil     mega-doctor "What works on this machine, and what is missing")
     ("C-c y" mega-trust-project "Trust this project: let its server, checks, formatter and tasks run"))
    ("Find"
     ("M-g a" mega-search-project "Search the project as you type")
     ("M-g s" mega-search-symbol  "Search the project for the symbol at point")
     ("M-g i" imenu               "Jump to a definition in this buffer")
     ("C-c p" mega-project-map    "Project: f file, p switch, b buffer, g grep, c compile, s shell")
     ("C-c t" mega-project-tree   "Show or hide the file tree"))
    ("Edit"
     ("C-c C-c" mega-comment-dwim "Comment or uncomment the region or the line" :code)
     ("C-c C-v" mega-major-mode-ctrl-c-ctrl-c "What this mode itself has on C-c C-c" :code)
     ("M-n"     mega-symbol-next     "Next occurrence of the symbol at point" :text)
     ("M-p"     mega-symbol-previous "Previous occurrence of the symbol at point" :text)
     ("C-c s"   mega-snippet-insert  "Insert a snippet")
     ("C-c f"   mega-fold-toggle     "Fold or unfold the block the cursor is in" :code)
     ("C-c F"   mega-fold-all        "Fold every block, or unfold everything" :code)
     ("C-x u"   mega-undo-tree       "The undo history as a tree: every state the text was in"))
    ("Code"
     ("C-c d"   mega-doc-buffer   "Documentation for the thing at point, in a side window")
     ("C-c D"   mega-doc-popup    "The same, in a popup")
     ("C-c c f" mega-format-buffer  "Format the buffer")
     ("C-c c F" mega-format-project "Format the whole project")
     ("C-c c r" eglot-rename      "Rename the symbol at point everywhere")
     ("C-c c a" eglot-code-actions "Offer fixes and refactorings here")
     ("C-c c i" eglot-find-implementation "Go to the implementation")
     ("C-c c t" eglot-find-typeDefinition "Go to the definition of the type")
     ("C-c c h" eglot-show-call-hierarchy "Who calls this, and what it calls")
     ("C-c c o" eglot-code-action-organize-imports "Tidy the imports")
     ("C-c c n" flymake-goto-next-error "Next problem")
     ("C-c c p" flymake-goto-prev-error "Previous problem")
     ("C-c c e" flymake-show-buffer-diagnostics  "List the problems in this buffer")
     ("C-c c E" flymake-show-project-diagnostics "List the problems in the project"))
    ("Tasks"
     ("C-c x b" mega-task-build       "Build the project")
     ("C-c x r" mega-task-run-project "Run the project")
     ("C-c x t" mega-task-test        "Test the project")
     ("C-c x x" mega-task-choose      "Choose a task of the project and run it")
     ("C-c x g" mega-task-again       "Run the last task again")
     ("C-c x k" mega-task-stop        "Stop the running task"))
    ("Debug"
     ("C-c g g" mega-debug          "Start a debugger on the project's program")
     ("C-c g r" mega-debug-run      "Run the program from the start")
     ("C-c g b" mega-debug-break    "Breakpoint on this line")
     ("C-c g d" mega-debug-remove   "Remove the breakpoint on this line")
     ("C-c g n" mega-debug-next     "Step over; then n again repeats")
     ("C-c g s" mega-debug-step     "Step into")
     ("C-c g f" mega-debug-finish   "Run until this function returns")
     ("C-c g u" mega-debug-until    "Run to this line")
     ("C-c g c" mega-debug-continue "Continue to the next breakpoint")
     ("C-c g p" mega-debug-print    "Print the expression at point")
     ("C-c g <" mega-debug-up       "Up one stack frame")
     ("C-c g >" mega-debug-down     "Down one stack frame")
     ("C-c g q" mega-debug-quit     "Stop the debugger"))
    ("Claude"
     ("C-c l c" mega-claude             "This project's Claude session: start it or go to it")
     ("C-c l v" mega-claude-send-region "Paste the selected text into that session")
     ("C-c l a" mega-claude-ask         "Ask a question; selected text goes with it")
     ("C-c l e" mega-claude-explain     "Explain the selected text or the function at point")
     ("C-c l r" mega-claude-rewrite     "Rewrite it as you say; shows the difference first")
     ("C-c l k" mega-claude-stop        "Stop waiting for an answer"))
    ("Containers"
     ("C-c k u" mega-container-up      "Start or join the project's dev container")
     ("C-c k d" mega-container-detach  "Go back to the tools of this machine")
     ("C-c k s" mega-container-shell   "A shell inside the container")
     ("C-c k i" mega-container-info    "Which container this project is using")
     ("C-c k x" mega-container-stop    "Stop the container")
     ("C-c k r" mega-container-rebuild "Remove the container and start a new one"))
    ("Workspaces"
     ("C-c w s" mega-workspace-save   "Save the open files and the window layout under a name")
     ("C-c w r" mega-workspace-resume "Bring a saved workspace back")
     ("C-c w n" mega-workspace-new    "Open an empty tab")
     ("C-c w w" tab-bar-switch-to-tab "Switch to another tab")
     ("C-c w k" mega-workspace-forget "Forget a saved workspace"))
    ("Windows"
     ("M-{" shrink-window-horizontally  "Make the window narrower")
     ("M-}" enlarge-window-horizontally "Make the window wider")))
  "Every binding MEGA defines, grouped for the cheat sheet.
Each element is (GROUP ROW...); see the Commentary for a ROW.
Change it with `mega-keys-add' and `mega-keys-remove', which keep the
keymap in step.")

(defconst mega-keys-elsewhere
  '(("In the completion menu" mega-complete-menu-map mega-complete
     ("C-n, <down>" mega-complete-next     "Choose the next candidate")
     ("C-p, <up>"   mega-complete-previous "Choose the previous candidate")
     ("TAB"         mega-complete-accept   "Take the chosen candidate, or the first" ("<tab>"))
     ("RET"         mega-complete-return   "Take the chosen candidate; with none chosen, a new line"
      ("<return>"))
     ("C-g"         mega-complete-close    "Close the menu"))
    ("While a snippet is being filled in" mega-snippet-map mega-snippet
     ("TAB"       mega-snippet-next     "Go to the next place; after the last one, finish" ("<tab>"))
     ("<backtab>" mega-snippet-previous "Go back to the previous place" ("S-TAB"))
     ("C-g"       mega-snippet-finish   "Stop filling it in"))
    ("In the search prompt, after C-o" mega-search-options-map mega-search
     ("c" mega-search-cycle-case       "Case: smart, ignore, sensitive")
     ("u" mega-search-toggle-untracked "Files git does not track: in or out")
     ("i" mega-search-toggle-ignored   "Ignored files: in or out")
     ("h" mega-search-toggle-hidden    "Hidden files: in or out")
     ("l" mega-search-toggle-literal   "Take the pattern literally, or as a regexp")
     ("w" mega-search-toggle-word      "Whole words only, or anywhere")
     ("b" mega-search-cycle-backend    "Search with the next usable program")
     ("e" mega-search-export           "Leave the prompt and put every hit in a buffer")
     ("?" mega-search-show-settings    "Show how the search currently works"))
    ("In the undo tree" mega-undo-tree-mode-map mega-undo-tree
     ("b, <left>, C-b"  mega-undo-tree-backward        "The older state this one was made from")
     ("f, <right>, C-f" mega-undo-tree-forward         "The newer state made from this one")
     ("n, <down>, C-n"  mega-undo-tree-next-branch     "The next branch of this fork")
     ("p, <up>, C-p"    mega-undo-tree-previous-branch "The previous branch of this fork")
     ("a, C-a"          mega-undo-tree-branch-start    "Back to where this branch forks off")
     ("e, C-e"          mega-undo-tree-branch-end      "The end of this branch")
     ("RET, q"          mega-undo-tree-quit            "Close the tree and keep the text as it is now")
     ("C-g"             mega-undo-tree-cancel          "Close the tree and put the text back"))
    ("After a stepping key of the debugger" mega-debug-repeat-map mega-debug
     ("n" mega-debug-next     "Step over again")
     ("s" mega-debug-step     "Step into again")
     ("f" mega-debug-finish   "Run until this function returns")
     ("u" mega-debug-until    "Run until a later line")
     ("c" mega-debug-continue "Continue")
     ("<" mega-debug-up       "Up one frame")
     (">" mega-debug-down     "Down one frame"))
    ("On the home page" mega-home-mode-map mega-home
     ("RET" mega-home-act          "Do what the line under the cursor offers")
     ("r"   mega-home-continue     "Continue from the session that was closed last")
     ("1"   mega-home-open-nth     "Open that recent project; so 2 to 9"
      ("2" "3" "4" "5" "6" "7" "8" "9"))
     ("f"   find-file              "Open a file")
     ("p"   project-switch-project "Switch to a project")
     ("w"   mega-workspace-resume  "Bring a saved workspace back")
     ("?"   mega-help              "This cheat sheet")
     ("d"   mega-doctor            "What works on this machine")
     ("g"   mega-home              "Draw the page again")
     ("q"   mega-home-leave        "Leave the home page"))
    ("In the buffer with Claude's answer" mega-claude-answer-mode-map mega-llm
     ("RET, C-c C-c" mega-claude-apply "Apply the rewrite, if the text is still what was sent"))
    ("In a Markdown file" mega-markdown-mode-map mega-mode-markdown
     ("TAB"       mega-markdown-tab    "Fold or unfold on a heading; indent anywhere else")
     ("<backtab>" outline-cycle-buffer "Fold or unfold the whole file")
     ("C-c C-n"   outline-next-visible-heading     "The next heading")
     ("C-c C-p"   outline-previous-visible-heading "The previous heading")))
  "The keys that mean something in one place only.
Each element is (PLACE MAP FEATURE ROW...): the keys of keymap MAP,
which module FEATURE defines.  A ROW is (KEYS COMMAND DESCRIPTION
[ALSO]): KEYS, in `kbd' notation and separated by a comma and a space,
is what the cheat sheet shows; ALSO lists further keys for the same
command that are not worth a reader's time, such as the name a
graphical frame has for TAB.")

(defun mega-keys--applies-p (where)
  "Non-nil if a key limited to WHERE applies in the current buffer."
  (pcase where
    (:code (derived-mode-p 'prog-mode 'conf-mode))
    (:text (derived-mode-p 'prog-mode 'conf-mode 'text-mode))
    (_ t)))

(defun mega-keys--binding (row)
  "What ROW's key is bound to: its command, limited to where it applies."
  (let ((command (nth 1 row))
        (where (nth 3 row)))
    (if where
        `(menu-item "" ,command
                    :filter ,(lambda (command)
                               (and (mega-keys--applies-p where) command)))
      command)))

(defvar mega-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (group mega-keys)
      (dolist (row (cdr group))
        (when (car row)
          (define-key map (kbd (car row)) (mega-keys--binding row)))))
    map)
  "Keymap holding every binding MEGA defines.  Built from `mega-keys'.")

;;;; Changing the table

(defun mega-keys-remove (key)
  "Take KEY, in `kbd' notation, out of the table and out of the keymap.
What Emacs had on KEY is in force again."
  (setq mega-keys
        (mapcar (lambda (group)
                  (cons (car group)
                        (seq-remove (lambda (row) (equal (car row) key))
                                    (cdr group))))
                mega-keys))
  ;; The third argument removes the binding; nil would leave one that says
  ;; "nothing here", and hide the key of the mode underneath.
  (define-key mega-keys-mode-map (kbd key) nil t))

(defun mega-keys-prune ()
  "Take out of the table every key whose command does not exist.
A feature that was removed, by deleting its line in init.el, must not
leave keys behind that do nothing but fail.  Called once the modules
are in; a command that loads its module on first use exists already."
  (dolist (group mega-keys)
    (dolist (row (cdr group))
      (unless (or (fboundp (nth 1 row)) (null (car row)))
        (mega-keys-remove (car row)))))
  ;; And the rows that had no key, with the groups this leaves empty.
  (setq mega-keys
        (delq nil
              (mapcar (lambda (group)
                        (when-let* ((rows (seq-filter (lambda (row) (fboundp (nth 1 row)))
                                                      (cdr group))))
                          (cons (car group) rows)))
                      mega-keys))))

(defun mega-keys-add (group &rest rows)
  "Add ROWS to GROUP of the table, and their keys to the keymap.
GROUP is the heading the cheat sheet shows them under; a new name makes
a new group.  A ROW is (KEY COMMAND DESCRIPTION [WHERE]), as in the
Commentary.  A key that is in the table already gets its new meaning
and loses its old row, so the cheat sheet stays true."
  (dolist (row rows)
    (unless (and (or (null (car row)) (stringp (car row)))
                 (symbolp (nth 1 row))
                 (stringp (nth 2 row))
                 (memq (nth 3 row) '(nil :code :text)))
      (error "Not a row of `mega-keys': %S" row))
    (when (car row)
      (mega-keys-remove (car row))
      (define-key mega-keys-mode-map (kbd (car row)) (mega-keys--binding row))))
  (if (assoc group mega-keys)
      (setq mega-keys
            (mapcar (lambda (existing)
                      (if (equal (car existing) group)
                          (append existing (copy-sequence rows))
                        existing))
                    mega-keys))
    (setq mega-keys (append mega-keys (list (cons group (copy-sequence rows)))))))

;;;###autoload
(define-minor-mode mega-keys-mode
  "Global minor mode carrying MEGA's keybindings.
Disable it to get stock Emacs bindings back for a moment."
  :global t
  :init-value nil
  :lighter nil
  :group 'mega
  :keymap mega-keys-mode-map)

(mega-keys-mode 1)

(provide 'mega-keys)
;;; mega-keys.el ends here
