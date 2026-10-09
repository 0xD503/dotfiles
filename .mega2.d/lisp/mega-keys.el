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

;;; Code:

(require 'mega-lib)

(defconst mega-keys
  '(("Help"
     ("C-c ?" mega-help   "This cheat sheet")
     ("C-c h" mega-home   "The home page: continue, recent projects")
     (nil     mega-doctor "What works on this machine, and what is missing"))
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
     ("C-c w s" mega-workspace-save   "Save the files and windows on screen under a name")
     ("C-c w r" mega-workspace-resume "Bring a saved workspace back")
     ("C-c w n" mega-workspace-new    "Open an empty tab")
     ("C-c w w" tab-bar-switch-to-tab "Switch to another tab")
     ("C-c w k" mega-workspace-forget "Forget a saved workspace"))
    ("Windows"
     ("M-{" shrink-window-horizontally  "Make the window narrower")
     ("M-}" enlarge-window-horizontally "Make the window wider")))
  "Every binding MEGA defines, grouped for the cheat sheet.
Each element is (GROUP ROW...); see the Commentary for a ROW.")

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
