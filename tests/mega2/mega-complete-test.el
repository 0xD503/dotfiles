;;; mega-complete-test.el --- Tests for mega-popup.el and mega-complete.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; A batch Emacs cannot draw a popup, so these tests replace the drawing with
;; a recorder and check everything up to it: where a popup would go, what the
;; menu offers, what each key does to the buffer.  That a popup really
;; appears on a terminal is checked by mega-terminal-probe.el.

;;; Code:

(require 'mega-test-helper)
(require 'mega-popup)
(require 'mega-complete)

;;;; Where a popup goes

(ert-deftest mega-popup-goes-below-the-line-when-there-is-room ()
  (should (equal (mega-popup-geometry 10 5 20 4 80 24) '(10 6 20 4))))

(ert-deftest mega-popup-goes-above-when-there-is-no-room-below ()
  ;; Row 21 of 24: two rows below, four wanted.  It must not cover row 21.
  (should (equal (mega-popup-geometry 10 21 20 4 80 24) '(10 17 20 4))))

(ert-deftest mega-popup-is-cut-to-the-larger-side-when-neither-fits ()
  (should (equal (mega-popup-geometry 0 3 10 30 80 10) '(0 4 10 6)))
  (should (equal (mega-popup-geometry 0 7 10 30 80 10) '(0 0 10 7))))

(ert-deftest mega-popup-is-shifted-left-to-stay-in-the-frame ()
  (should (equal (mega-popup-geometry 75 5 20 3 80 24) '(60 6 20 3)))
  (should (equal (mega-popup-geometry 5 5 200 3 80 24) '(0 6 80 3))))

(ert-deftest mega-popup-never-covers-the-line-it-belongs-to ()
  (dotimes (row 24)
    (dolist (height '(1 3 10 40))
      (pcase-let ((`(,_left ,top ,_width ,h) (mega-popup-geometry 4 row 12 height 80 24)))
        (should (>= h 1))
        (should (or (> top row) (<= (+ top h) row)))
        (should (>= top 0))
        (should (<= (+ top h) 24))))))

(ert-deftest mega-popup-cannot-be-drawn-in-batch-and-says-so ()
  (should-not (mega-popup-available-p))
  (should-not (mega-popup-show 'test '("a" "b")))
  (should-not (mega-popup-visible-p 'test)))

(ert-deftest mega-popup-text-is-padded-cut-and-highlighted ()
  (with-temp-buffer
    (mega-popup--fill (current-buffer) '("one" "a much longer line" "x") 6 1)
    (should (equal (buffer-string) "one   \na much\nx     "))
    (should (memq 'mega-popup (ensure-list (get-text-property 1 'face))))
    (should (memq 'mega-popup-selected (ensure-list (get-text-property 8 'face))))))

;;;; The menu's model

(ert-deftest mega-complete-moving-through-the-candidates ()
  ;; Nothing chosen: forward takes the first, back takes the last.
  (should (= (mega-complete-move -1 5 1) 0))
  (should (= (mega-complete-move -1 5 -1) 4))
  (should (= (mega-complete-move 0 5 1) 1))
  (should (= (mega-complete-move 4 5 1) 0))
  (should (= (mega-complete-move 0 5 -1) 4))
  (should (= (mega-complete-move 0 0 1) -1)))

(ert-deftest mega-complete-lines-align-the-annotations ()
  (let ((mega-complete--properties
         (list :annotation-function
               (lambda (candidate) (if (equal candidate "ab") " fn" nil)))))
    (should (equal (mapcar #'substring-no-properties
                           (mega-complete-lines '("ab" "abcdef")))
                   '(" ab     fn " " abcdef ")))))

;;;; A buffer with something to complete

(defvar mega-complete-test--exits nil "What the exit function was called with.")
(defvar mega-complete-test--drawn nil "The last (LINES SELECTED) drawn.")

(defun mega-complete-test--capf ()
  "Complete the word before point from a few fixed words."
  (list (save-excursion (skip-chars-backward "a-z") (point))
        (point)
        '("alpha" "alphabet" "alpine" "beta")
        :annotation-function (lambda (candidate)
                               (and (equal candidate "alpha") " letter"))
        :exit-function (lambda (candidate status)
                         (push (list (substring-no-properties candidate) status)
                               mega-complete-test--exits))))

(defmacro mega-complete-test--buffer (text &rest body)
  "Run BODY in a buffer holding TEXT, point at its end, popups recorded."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (setq-local completion-at-point-functions '(mega-complete-test--capf))
     (setq mega-complete-test--exits nil
           mega-complete-test--drawn nil)
     (cl-letf (((symbol-function 'mega-popup-available-p) (lambda () t))
               ((symbol-function 'mega-popup-show)
                (lambda (_name lines &optional selected &rest _)
                  (setq mega-complete-test--drawn
                        (list (mapcar #'substring-no-properties lines) selected))
                  t))
               ((symbol-function 'mega-popup-hide) #'ignore))
       (unwind-protect
           (progn ,@body)
         (mega-complete-close)))))

(defun mega-complete-test--type (string)
  "Insert STRING as if typed, one character at a time."
  (dolist (char (string-to-list string))
    (insert char)
    (let ((this-command 'self-insert-command))
      (mega-complete--post-command))))

(ert-deftest mega-complete-candidates-are-the-matches-shortest-first ()
  (mega-complete-test--buffer "x al"
    (should (equal (mega-complete-candidates 3 5 '("alpine" "alphabet" "alpha" "beta") nil)
                   '(0 "alpha" "alpine" "alphabet")))))

(ert-deftest mega-complete-candidates-are-nil-when-nothing-matches ()
  (mega-complete-test--buffer "zz"
    (should-not (mega-complete-candidates 1 3 '("alpha") nil))))

(ert-deftest mega-complete-the-menu-opens-by-itself-with-nothing-chosen ()
  (mega-complete-test--buffer "al"
    (mega-complete--auto)
    (should mega-complete--active)
    (should (= mega-complete--index -1))
    (should (equal mega-complete-test--drawn
                   '((" alpha    letter " " alpine " " alphabet ") nil)))))

(ert-deftest mega-complete-the-menu-waits-for-enough-characters ()
  (mega-complete-test--buffer "a"
    (mega-complete--auto)
    (should-not mega-complete--active))
  (let ((mega-complete-min-prefix 1))
    (mega-complete-test--buffer "a"
      (mega-complete--auto)
      (should mega-complete--active))))

(ert-deftest mega-complete-nothing-is-offered-for-a-finished-word ()
  (mega-complete-test--buffer "beta"
    (mega-complete--auto)
    (should-not mega-complete--active)))

(ert-deftest mega-complete-the-menu-stays-shut-in-a-read-only-buffer ()
  (mega-complete-test--buffer "al"
    (setq buffer-read-only t)
    (mega-complete--auto)
    (should-not mega-complete--active)))

(ert-deftest mega-complete-arrows-choose-and-the-drawing-follows ()
  (mega-complete-test--buffer "al"
    (mega-complete--auto)
    (mega-complete-next)
    (should (= mega-complete--index 0))
    (should (eql (cadr mega-complete-test--drawn) 0))
    (mega-complete-next)
    (mega-complete-next)
    (mega-complete-next)
    (should (= mega-complete--index 0))
    (mega-complete-previous)
    (should (= mega-complete--index 2))))

(ert-deftest mega-complete-tab-takes-the-first-when-none-is-chosen ()
  (mega-complete-test--buffer "say al"
    (mega-complete--auto)
    (mega-complete-accept)
    (should (equal (buffer-string) "say alpha"))
    (should (equal mega-complete-test--exits '(("alpha" finished))))
    (should-not mega-complete--active)))

(ert-deftest mega-complete-tab-takes-the-chosen-candidate ()
  (mega-complete-test--buffer "say al"
    (mega-complete--auto)
    (mega-complete-next)
    (mega-complete-next)
    (mega-complete-accept)
    (should (equal (buffer-string) "say alpine"))
    (should (= (point) (point-max)))))

(ert-deftest mega-complete-return-with-nothing-chosen-is-an-ordinary-return ()
  "The menu must never insert something that was not asked for."
  (mega-complete-test--buffer "al"
    (mega-complete--auto)
    (mega-complete-return)
    (should (equal (buffer-string) "al\n"))
    (should-not mega-complete--active)
    (should-not mega-complete-test--exits)))

(ert-deftest mega-complete-return-takes-a-chosen-candidate ()
  (mega-complete-test--buffer "al"
    (mega-complete--auto)
    (mega-complete-next)
    (mega-complete-return)
    (should (equal (buffer-string) "alpha"))))

(ert-deftest mega-complete-typing-on-narrows-the-menu ()
  (mega-complete-test--buffer "al"
    (mega-complete--auto)
    (mega-complete-test--type "ph")
    (should mega-complete--active)
    (should (equal (car mega-complete-test--drawn) '(" alpha    letter " " alphabet ")))
    ;; Narrowing drops any choice: the list under the cursor has changed.
    (should (= mega-complete--index -1))))

(ert-deftest mega-complete-typing-past-every-candidate-closes-the-menu ()
  (mega-complete-test--buffer "al"
    (mega-complete--auto)
    (mega-complete-test--type "zz")
    (should-not mega-complete--active)))

(ert-deftest mega-complete-moving-away-closes-the-menu ()
  (mega-complete-test--buffer "one al"
    (mega-complete--auto)
    (goto-char (point-min))
    (let ((this-command 'beginning-of-buffer))
      (mega-complete--post-command))
    (should-not mega-complete--active)))

(ert-deftest mega-complete-deleting-back-before-the-word-closes-the-menu ()
  (mega-complete-test--buffer "x al"
    (mega-complete--auto)
    (delete-char -3)
    (let ((this-command 'delete-backward-char))
      (mega-complete--post-command))
    (should-not mega-complete--active)))

(ert-deftest mega-complete-quit-closes-and-changes-nothing ()
  (mega-complete-test--buffer "al"
    (mega-complete--auto)
    (mega-complete-next)
    (mega-complete-close)
    (should (equal (buffer-string) "al"))
    (should-not mega-complete--active)))

(ert-deftest mega-complete-typing-arms-a-timer-not-a-computation ()
  "A keystroke only schedules the menu; the work happens in the pause."
  (mega-complete-test--buffer "a"
    (mega-complete-test--type "l")
    (should-not mega-complete--active)
    (should (timerp mega-complete--timer))))

(ert-deftest mega-complete-an-interrupted-computation-offers-nothing ()
  ;; `while-no-input' yields t when a key arrives before its body finishes.
  (mega-complete-test--buffer "al"
    (cl-letf (((symbol-function 'completion-all-completions) (lambda (&rest _) t)))
      (should-not (mega-complete-candidates 1 3 '("alpha") nil)))))

;;;; Completion on request

(ert-deftest mega-complete-on-request-opens-with-the-first-chosen ()
  (mega-complete-test--buffer "al"
    (should (mega-complete-in-region 1 3 '("alpha" "alpine" "beta")))
    (should mega-complete--active)
    (should (= mega-complete--index 0))))

(ert-deftest mega-complete-on-request-takes-a-single-candidate-at-once ()
  (mega-complete-test--buffer "be"
    (let ((completion-extra-properties
           (list :exit-function (lambda (c s) (push (list c s) mega-complete-test--exits)))))
      (should (mega-complete-in-region 1 3 '("alpha" "beta"))))
    (should (equal (buffer-string) "beta"))
    (should (equal mega-complete-test--exits '(("beta" finished))))
    (should-not mega-complete--active)))

(ert-deftest mega-complete-on-request-with-no-match-says-so ()
  (mega-complete-test--buffer "zz"
    (should-not (mega-complete-in-region 1 3 '("alpha")))
    (should (equal (buffer-string) "zz"))))

;;;; The mode

(ert-deftest mega-complete-the-menu-keys-outrank-everything-while-it-is-open ()
  (mega-complete-test--buffer "al"
    (let ((mega-complete-mode t)
          (emulation-mode-map-alists (cons 'mega-complete--emulation-alist
                                           emulation-mode-map-alists)))
      (should-not (eq (key-binding (kbd "TAB")) #'mega-complete-accept))
      (mega-complete--auto)
      (should (eq (key-binding (kbd "TAB")) #'mega-complete-accept))
      (should (eq (key-binding (kbd "RET")) #'mega-complete-return))
      (should (eq (key-binding (kbd "C-n")) #'mega-complete-next))
      (should (eq (key-binding (kbd "C-g")) #'mega-complete-close))
      (mega-complete-close)
      (should-not (eq (key-binding (kbd "C-n")) #'mega-complete-next)))))

(ert-deftest mega-complete-the-mode-installs-and-removes-itself-cleanly ()
  (let ((completion-in-region-function #'completion--in-region)
        (emulation-mode-map-alists emulation-mode-map-alists)
        (post-command-hook post-command-hook))
    (unwind-protect
        (progn
          (mega-complete-mode 1)
          (should (eq completion-in-region-function #'mega-complete-in-region))
          (should (memq #'mega-complete--post-command post-command-hook))
          (mega-complete-mode -1)
          (should (eq completion-in-region-function #'completion--in-region))
          (should-not (memq #'mega-complete--post-command post-command-hook))
          (should-not (memq 'mega-complete--emulation-alist emulation-mode-map-alists)))
      (mega-complete-mode -1))))

(ert-deftest mega-complete-words-from-buffers-are-the-last-resort ()
  (should (eq (car (last (default-value 'completion-at-point-functions)))
              #'dabbrev-capf))
  (should (eq tab-always-indent 'complete)))

(provide 'mega-complete-test)
;;; mega-complete-test.el ends here
