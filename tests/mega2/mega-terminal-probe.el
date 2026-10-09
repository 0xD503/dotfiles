;;; mega-terminal-probe.el --- Check a real terminal session  -*- lexical-binding: t; -*-

;;; Commentary:

;; Not an ERT file.  tests/test_mega2.sh starts a real, interactive Emacs in a
;; pseudo-terminal — through `--init-directory', through chemacs2, or with an
;; Emacs too old for MEGA — and loads this file with `-l'.  By then the init
;; files have run, so this only looks, writes what it saw to the file named by
;; MEGA_TEST_REPORT, and exits.
;;
;; MEGA_TEST_EXPECT says what a correct start looks like: "supported" for a
;; configured MEGA, "refused" for an old Emacs that must be left plain.
;;
;; This file has to load on the old Emacs too: nothing newer than Emacs 27.

;;; Code:

(defvar mega-terminal-probe-problems nil
  "What the probe found wrong.")

(defun mega-terminal-probe--problem (format-string &rest arguments)
  "Record a problem described by FORMAT-STRING and ARGUMENTS."
  (push (apply #'format format-string arguments) mega-terminal-probe-problems))

(defun mega-terminal-probe--warnings ()
  "The text of the warnings buffer, or the empty string."
  (if (get-buffer "*Warnings*")
      (with-current-buffer "*Warnings*" (buffer-string))
    ""))

(defun mega-terminal-probe--modeline ()
  "The modeline of the current buffer as plain text.
The buffer is named explicitly: by default Emacs renders the modeline of
whatever buffer the selected window shows."
  (substring-no-properties
   (format-mode-line mode-line-format nil nil (current-buffer))))

(defmacro mega-terminal-probe--typing (keys &rest body)
  "Run BODY as if KEYS were typed at the prompt it opens.
Unlike the simulated keys of the unit tests, this leaves the live
minibuffer list on: the keys are simply waiting in the input queue."
  (declare (indent 1))
  `(progn
     (setq unread-command-events (listify-key-sequence (kbd ,keys)))
     (prog1 (progn ,@body)
       (setq unread-command-events nil))))

(defun mega-terminal-probe--navigation ()
  "Check the prompts, the search and the file tree on the live terminal."
  (declare-function mega-pick-read "mega-pick")
  (declare-function mega-search-project "mega-search")
  (declare-function mega-project-tree "mega-project")
  (require 'mega-pick)
  ;; The live list: RET takes the highlighted entry, not the typed text.
  (let ((choice (mega-terminal-probe--typing "an RET"
                  (mega-pick-read
                   "Fruit: "
                   (lambda (input)
                     (seq-filter (lambda (fruit) (string-search input fruit))
                                 '("apple" "banana" "mango")))))))
    (unless (equal choice "banana")
      (mega-terminal-probe--problem "the prompt returned %S, not the entry" choice)))
  ;; Fuzzy matching in an ordinary prompt.
  (let ((choice (mega-terminal-probe--typing "srcmn RET"
                  (completing-read "File: " '("README.md" "src/lib.rs" "src/main.rs")))))
    (unless (equal choice "src/main.rs")
      (mega-terminal-probe--problem "fuzzy matching chose %S" choice)))
  ;; A real search with a real program, from typing to landing on the line.
  (let* ((project (file-name-as-directory
                   (make-temp-file (expand-file-name "probe-" (getenv "MEGA_TEST_SANDBOX"))
                                   t)))
         (file (expand-file-name "notes.txt" project))
         (default-directory project))
    (with-temp-file file (insert "one\ntwo\nthe needle is here\n"))
    (condition-case err
        (save-window-excursion
          (mega-terminal-probe--typing "needle RET"
            (mega-search-project))
          (unless (and (equal buffer-file-name file) (= (line-number-at-pos) 3))
            (mega-terminal-probe--problem "the search ended in %S, line %s"
                                          (or buffer-file-name (buffer-name))
                                          (line-number-at-pos))))
      (error (mega-terminal-probe--problem "the search failed: %S" err))))
  ;; The file tree is a window of this frame, and goes away again.
  (condition-case err
      (let ((before (length (window-list))))
        (mega-project-tree)
        (unless (= (length (window-list)) (1+ before))
          (mega-terminal-probe--problem "the file tree opened %s windows"
                                        (- (length (window-list)) before)))
        (unless (= (length (frame-list)) 1)
          (mega-terminal-probe--problem "the file tree opened a frame"))
        (mega-project-tree)
        (unless (= (length (window-list)) before)
          (mega-terminal-probe--problem "the file tree did not close")))
    (error (mega-terminal-probe--problem "the file tree failed: %S" err))))

(defun mega-terminal-probe--completion ()
  "Check the completion menu on the live terminal: it is drawn, and TAB works.
The text \"popup-marker\" in the report tells the runner to look for the
menu's text in what the terminal was actually sent."
  (declare-function mega-complete--auto "mega-complete")
  (declare-function mega-complete-next "mega-complete")
  (declare-function mega-complete-accept "mega-complete")
  (declare-function mega-popup-visible-p "mega-popup")
  (defvar mega-complete--active)
  (defvar mega-complete-mode)
  (condition-case err
      (save-window-excursion
        (unless mega-complete-mode
          (mega-terminal-probe--problem "the completion menu is not enabled"))
        (switch-to-buffer (get-buffer-create "mega-probe-completion"))
        (erase-buffer)
        (setq-local completion-at-point-functions
                    (list (lambda ()
                            (list (save-excursion (skip-chars-backward "a-z") (point))
                                  (point)
                                  '("megaprobealpha" "megaprobebeta" "other")))))
        (insert "megapr")
        (redisplay t)
        (mega-complete--auto)
        (redisplay t)
        (unless (and mega-complete--active (mega-popup-visible-p 'complete))
          (mega-terminal-probe--problem "the completion menu did not appear"))
        (unless (= (length (frame-list)) 2)
          (mega-terminal-probe--problem "%d frames with the menu open" (length (frame-list))))
        (unless (eq (selected-window) (get-buffer-window "mega-probe-completion"))
          (mega-terminal-probe--problem "the menu took the cursor away"))
        ;; Shortest first: beta, then alpha.  Take the second, so that the
        ;; word "beta" reaches the terminal only as part of the menu.
        (mega-complete-next)
        (mega-complete-next)
        (redisplay t)
        (mega-complete-accept)
        (redisplay t)
        (unless (equal (buffer-string) "megaprobealpha")
          (mega-terminal-probe--problem "accepting inserted %S" (buffer-string)))
        (when (mega-popup-visible-p 'complete)
          (mega-terminal-probe--problem "the menu stayed after accepting"))
        (set-buffer-modified-p nil)
        (kill-buffer "mega-probe-completion"))
    (error (mega-terminal-probe--problem "the completion menu failed: %S" err))))

(defun mega-terminal-probe--home ()
  "Check the home page and workspaces on the live terminal.
MEGA_TEST_FILE names a file Emacs was started on, if any: then the page
must stay out of the way."
  (declare-function mega-workspace-capture "mega-workspace")
  (declare-function mega-workspace-write "mega-workspace")
  (declare-function mega-workspace-restore "mega-workspace")
  (declare-function mega-home-render "mega-home")
  (defvar mega-home-buffer)
  (let ((given (getenv "MEGA_TEST_FILE")))
    (if (and given (not (string= given "")))
        (progn
          (unless (equal (buffer-file-name (window-buffer)) (expand-file-name given))
            (mega-terminal-probe--problem "started on a file, but showing %s"
                                          (buffer-name (window-buffer))))
          (when (get-buffer mega-home-buffer)
            (mega-terminal-probe--problem "the home page opened although a file was given")))
      (unless (equal (buffer-name (window-buffer)) mega-home-buffer)
        (mega-terminal-probe--problem "started on %s, not the home page"
                                      (buffer-name (window-buffer))))
      (let ((page (with-current-buffer (mega-home-render)
                    (buffer-substring-no-properties (point-min) (point-max)))))
        (unless (string-match-p "started in [0-9]+ ms" page)
          (mega-terminal-probe--problem "the home page shows no startup time: %S" page)))))
  ;; A two-window layout survives being saved and brought back.
  (let* ((dir (file-name-as-directory
               (make-temp-file (expand-file-name "ws-" (getenv "MEGA_TEST_SANDBOX")) t)))
         (a (expand-file-name "a.txt" dir))
         (b (expand-file-name "b.txt" dir))
         ;; The sandbox is under the temporary directory, which workspaces
         ;; normally leave out.
         (temporary-file-directory "/nonexistent-temporary-directory/"))
    (with-temp-file a (insert "alpha\nbeta\n"))
    (with-temp-file b (insert "gamma\ndelta\n"))
    (condition-case err
        (save-window-excursion
          (delete-other-windows)
          (find-file a)
          (goto-char 7)
          (select-window (split-window-right))
          (find-file b)
          (let ((workspace (mega-workspace-capture "probe")))
            (delete-other-windows)
            (kill-buffer (get-file-buffer a))
            (kill-buffer (get-file-buffer b))
            (switch-to-buffer "*scratch*")
            (mega-workspace-restore workspace)
            (let ((shown (sort (mapcar (lambda (window)
                                         (buffer-file-name (window-buffer window)))
                                       (window-list))
                               #'string<)))
              (unless (equal shown (list a b))
                (mega-terminal-probe--problem "the workspace came back showing %S" shown)))
            (unless (= 7 (with-current-buffer (get-file-buffer a) (point)))
              (mega-terminal-probe--problem "the cursor was not put back")))
          (ignore-errors (tab-bar-close-other-tabs)))
      (error (mega-terminal-probe--problem "workspaces failed: %S" err)))))

(defun mega-terminal-probe--supported ()
  "Check a session in which MEGA is expected to be fully configured."
  ;; First, before anything below changes what is on screen.
  (mega-terminal-probe--home)
  (unless (bound-and-true-p mega-supported-p)
    (mega-terminal-probe--problem "MEGA refused this Emacs"))
  (when (bound-and-true-p mega-module-failures)
    (mega-terminal-probe--problem "modules failed: %S" mega-module-failures))
  (dolist (module '(mega-lib mega-core mega-ui mega-keys mega-session))
    (unless (featurep module)
      (mega-terminal-probe--problem "%s did not load" module)))
  (unless (string= (mega-terminal-probe--warnings) "")
    (mega-terminal-probe--problem "warnings: %s" (mega-terminal-probe--warnings)))
  (when (display-graphic-p)
    (mega-terminal-probe--problem "expected a terminal frame"))
  (unless (equal (number-to-string (display-color-cells))
                 (getenv "MEGA_TEST_COLOURS"))
    (mega-terminal-probe--problem "%s colours, expected %s"
                                  (display-color-cells) (getenv "MEGA_TEST_COLOURS")))
  (if (>= (display-color-cells) 256)
      ;; The theme reached the screen, not merely the theme list.
      (progn
        (unless (equal (face-attribute 'default :background) "#2E3440")
          (mega-terminal-probe--problem "default background is %s"
                                        (face-attribute 'default :background)))
        (unless (equal (face-attribute 'font-lock-string-face :foreground) "#A3BE8C")
          (mega-terminal-probe--problem "strings are %s"
                                        (face-attribute 'font-lock-string-face
                                                        :foreground))))
    ;; Too few colours to approximate the palette: the theme must stay out of
    ;; the way and leave the terminal's own colours alone.
    (when (equal (face-attribute 'default :background) "#2E3440")
      (mega-terminal-probe--problem "the theme was applied with only %s colours"
                                    (display-color-cells))))
  (unless (eql (frame-parameter nil 'menu-bar-lines) 0)
    (mega-terminal-probe--problem "the menu bar is showing"))
  (with-temp-buffer
    (prog-mode)
    (unless (bound-and-true-p display-fill-column-indicator-mode)
      (mega-terminal-probe--problem "no ruler in a code buffer"))
    (unless (bound-and-true-p display-line-numbers-mode)
      (mega-terminal-probe--problem "no line numbers in a code buffer")))
  ;; The modeline only renders on a real display, so this is where the
  ;; assembled line is checked.
  (with-temp-buffer
    (rename-buffer "mega-probe-buffer" t)
    (insert "one\ntwo\nthree")
    (let ((line (mega-terminal-probe--modeline)))
      (dolist (expected '("mega-probe-buffer" "3:5" "Fundamental"))
        (unless (string-match-p (regexp-quote expected) line)
          (mega-terminal-probe--problem "the modeline lacks %S: %S" expected line)))
      (when (string-match-p "Narrow" line)
        (mega-terminal-probe--problem "the modeline says Narrow in a whole buffer")))
    (narrow-to-region 1 4)
    (unless (string-match-p "Narrow" (mega-terminal-probe--modeline))
      (mega-terminal-probe--problem "the modeline does not say a buffer is narrowed")))
  (unless (eq (key-binding (kbd "C-c ?")) 'mega-help)
    (mega-terminal-probe--problem "C-c ? is %s" (key-binding (kbd "C-c ?"))))
  (mega-terminal-probe--navigation)
  (mega-terminal-probe--completion)
  (when (and (equal (getenv "MEGA_TEST_LAUNCHER") "chemacs")
             (not (featurep 'chemacs)))
    (mega-terminal-probe--problem "chemacs was expected to have started this session")))

(defun mega-terminal-probe--refused ()
  "Check a session on an Emacs too old for MEGA: plain, warned, and tidy."
  (when (bound-and-true-p mega-supported-p)
    (mega-terminal-probe--problem "MEGA accepted Emacs %s" emacs-version))
  (dolist (module '(mega-core mega-ui mega-keys mega-session))
    (when (featurep module)
      (mega-terminal-probe--problem "%s loaded on an unsupported Emacs" module)))
  (unless (string-match-p "needs Emacs [0-9.]+ or newer"
                          (mega-terminal-probe--warnings))
    (mega-terminal-probe--problem "no warning explains the refusal; got: %s"
                                  (mega-terminal-probe--warnings)))
  (when custom-enabled-themes
    (mega-terminal-probe--problem "a theme was enabled: %S" custom-enabled-themes)))

(defun mega-terminal-probe--report ()
  "Check the session, write the report, and exit."
  (condition-case err
      (progn
        ;; True in every mode: even a refused session writes nowhere near the
        ;; configuration.
        (let ((config (getenv "MEGA_TEST_CONFIG")))
          (dolist (path (list user-emacs-directory custom-file))
            (when (or (null path)
                      (string-prefix-p (file-name-as-directory (expand-file-name config))
                                       (expand-file-name path)))
              (mega-terminal-probe--problem "%S points into the configuration" path))))
        (if (equal (getenv "MEGA_TEST_EXPECT") "refused")
            (mega-terminal-probe--refused)
          (mega-terminal-probe--supported)))
    (error (mega-terminal-probe--problem "the probe itself failed: %S" err)))
  (with-temp-file (getenv "MEGA_TEST_REPORT")
    (insert (format "emacs=%s\n" emacs-version)
            (format "term=%s\n" (getenv "TERM"))
            (format "colours=%s\n" (display-color-cells))
            (format "init-ms=%.1f\n"
                    (* 1000.0 (float-time (time-subtract after-init-time
                                                         before-init-time)))))
    (dolist (problem (reverse mega-terminal-probe-problems))
      (insert (format "problem: %s\n" problem)))
    (insert (format "verdict=%s\n" (if mega-terminal-probe-problems "bad" "ok"))))
  (kill-emacs (if mega-terminal-probe-problems 1 0)))

;; Depth 100, added last: runs after everything the init files put there,
;; including the warning an unsupported Emacs gets.
(add-hook 'emacs-startup-hook #'mega-terminal-probe--report 100)

;;; mega-terminal-probe.el ends here
