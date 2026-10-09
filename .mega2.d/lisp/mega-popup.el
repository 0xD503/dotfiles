;;; mega-popup.el --- A small window that floats over the text  -*- lexical-binding: t; -*-

;;; Commentary:

;; A popup is a child frame: a borderless frame drawn over part of its parent.
;; Emacs 31 supports those in a terminal, which is what makes a completion
;; menu or a documentation box possible without a window system.
;;
;; This file is the primitive.  It knows how to put some lines of text near a
;; position and take them away again; what the lines are is the caller's
;; business (mega-complete.el, mega-lsp.el).
;;
;; Where a popup goes is decided by `mega-popup-geometry', which is plain
;; arithmetic on numbers and therefore testable without a display.  Everything
;; that needs a real frame is in `mega-popup-show' and `mega-popup-hide'.
;;
;; `mega-popup-available-p' says whether popups can be drawn at all.  Callers
;; must have something else to do when it says no.

;;; Code:

(require 'mega-lib)

(defface mega-popup '((t :inherit tooltip))
  "The body of a popup." :group 'mega)

(defface mega-popup-selected '((t :inherit highlight))
  "The selected line of a popup." :group 'mega)

(defvar mega-popup--frames nil
  "Alist of (NAME . FRAME) for the popups that exist.")

(defun mega-popup-available-p ()
  "Non-nil if this display can draw a popup."
  (and (not noninteractive)
       (or (display-graphic-p) (featurep 'tty-child-frames))))

;;;; Where a popup goes

(defun mega-popup-geometry (column row width height frame-width frame-height)
  "Place a WIDTH by HEIGHT popup for the character at COLUMN, ROW.
All numbers are in character cells of a FRAME-WIDTH by FRAME-HEIGHT
frame.  Returns (LEFT TOP WIDTH HEIGHT).

The popup goes on the line below ROW, starting at COLUMN.  If there is
not room below it goes above, never covering ROW itself; if there is not
room either way it takes the larger side and is cut to fit.  It is
shifted left as far as needed to stay inside the frame."
  (let* ((width (max 1 (min width frame-width)))
         (below (- frame-height row 1))
         (above row)
         (fits-below (<= height below))
         (use-below (or fits-below (>= below above)))
         (height (max 1 (min height (if use-below below above))))
         (top (if use-below (1+ row) (- row height)))
         (left (max 0 (min column (- frame-width width)))))
    (list left top width height)))

(defun mega-popup--position (&optional position window)
  "Return (COLUMN . ROW) of POSITION in WINDOW, in frame character cells.
POSITION defaults to point, WINDOW to the selected window.  Nil if
POSITION is not on screen."
  (let* ((window (or window (selected-window)))
         (posn (posn-at-point (or position (window-point window)) window)))
    (when posn
      (let ((col-row (posn-col-row posn))
            (edges (window-inside-edges window)))
        (cons (+ (nth 0 edges) (car col-row))
              (+ (nth 1 edges) (cdr col-row)))))))

;;;; Drawing

(defun mega-popup--buffer (name)
  "The buffer behind the popup called NAME."
  (let ((buffer (get-buffer-create (format " *mega-popup-%s*" name))))
    (with-current-buffer buffer
      (setq-local mode-line-format nil
                  header-line-format nil
                  tab-line-format nil
                  cursor-type nil
                  truncate-lines t
                  left-margin-width 0
                  right-margin-width 0
                  show-trailing-whitespace nil
                  buffer-read-only nil))
    buffer))

(defun mega-popup--fill (buffer lines width selected)
  "Put LINES into BUFFER, each padded to WIDTH; highlight line SELECTED."
  (with-current-buffer buffer
    (erase-buffer)
    (let ((index 0))
      (dolist (line lines)
        (let ((start (point)))
          (insert (truncate-string-to-width line width nil ?\s))
          (add-face-text-property start (point)
                                  (if (eql index selected)
                                      'mega-popup-selected
                                    'mega-popup)
                                  t)
          (insert "\n"))
        (setq index (1+ index))))
    ;; No final newline: it would show as an empty last row.
    (when (> (point-max) (point-min))
      (delete-region (1- (point-max)) (point-max)))
    (goto-char (point-min))))

(defun mega-popup--frame (name parent)
  "The frame of the popup called NAME, a child of PARENT; made if needed."
  (let ((frame (alist-get name mega-popup--frames)))
    (unless (and (frame-live-p frame) (eq (frame-parent frame) parent))
      (when (frame-live-p frame)
        (delete-frame frame))
      (setq frame
            (make-frame
             `((parent-frame . ,parent)
               (minibuffer . nil)
               (visibility . nil)
               (undecorated . t)
               (no-accept-focus . t)
               (no-focus-on-map . t)
               (no-other-frame . t)
               (unsplittable . t)
               (skip-taskbar . t)
               (desktop-dont-save . t)
               (no-special-glyphs . t)
               (cursor-type . nil)
               (menu-bar-lines . 0)
               (tool-bar-lines . 0)
               (tab-bar-lines . 0)
               (vertical-scroll-bars . nil)
               (horizontal-scroll-bars . nil)
               (left-fringe . 0)
               (right-fringe . 0)
               (internal-border-width . 0)
               (child-frame-border-width . 0)
               (width . 1)
               (height . 1))))
      (setf (alist-get name mega-popup--frames) frame))
    frame))

(defun mega-popup-show (name lines &optional selected position max-width max-height)
  "Show LINES in the popup called NAME, near POSITION in the selected window.
SELECTED is the index of a line to highlight, or nil.  POSITION defaults
to point.  The popup is at most MAX-WIDTH columns and MAX-HEIGHT lines,
and never larger than the frame; lines beyond that are cut.

Returns the popup's frame, or nil when a popup cannot be drawn here:
no child frames, nothing to show, or POSITION off screen."
  (let ((where (and lines (mega-popup-available-p) (mega-popup--position position))))
    (if (not where)
        (progn (mega-popup-hide name) nil)
      (let* ((parent (selected-frame))
             (wanted-width (min (or max-width 80)
                                (apply #'max 1 (mapcar #'string-width lines))))
             (geometry (mega-popup-geometry
                        (car where) (cdr where)
                        wanted-width (min (or max-height 12) (length lines))
                        (frame-width parent) (frame-height parent)))
             (width (nth 2 geometry))
             (height (nth 3 geometry))
             (buffer (mega-popup--buffer name))
             (frame (mega-popup--frame name parent))
             ;; Keep the selected line among the rows that fit.
             (first (if (and selected (>= selected height))
                        (- selected (1- height))
                      0)))
        (mega-popup--fill buffer (take height (nthcdr first lines)) width
                          (and selected (- selected first)))
        (let ((window (frame-root-window frame)))
          (set-window-buffer window buffer)
          (set-window-dedicated-p window t)
          (set-window-point window (point-min)))
        (modify-frame-parameters
         frame `((width . ,width) (height . ,height)
                 (left . ,(* (nth 0 geometry) (frame-char-width parent)))
                 (top . ,(* (nth 1 geometry) (frame-char-height parent)))))
        (make-frame-visible frame)
        ;; Showing a frame may select it; typing must stay in the parent.
        (unless (eq (selected-frame) parent)
          (select-frame-set-input-focus parent))
        frame))))

(defun mega-popup-hide (name)
  "Take the popup called NAME off the screen."
  (let ((frame (alist-get name mega-popup--frames)))
    (when (and (frame-live-p frame) (frame-visible-p frame))
      (make-frame-invisible frame))))

(defun mega-popup-visible-p (name)
  "Non-nil if the popup called NAME is on screen."
  (let ((frame (alist-get name mega-popup--frames)))
    (and (frame-live-p frame) (frame-visible-p frame) t)))

(provide 'mega-popup)
;;; mega-popup.el ends here
