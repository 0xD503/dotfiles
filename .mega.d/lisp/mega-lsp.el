;;; mega-lsp.el --- eglot, eldoc, and a documentation popup that works in a TTY  -*- lexical-binding: t; -*-

;;; Commentary:

;; eglot rather than lsp-mode, and the deciding argument is the terminal:
;; lsp-ui-doc, lsp-ui-peek and company-box are all child-frame based and render
;; nothing without a window system, so lsp-mode's headline features are dead
;; weight here.  eglot ships with Emacs, speaks native JSON, and keeps no state
;; outside the server process.
;;
;; What that costs: no code-lens UI, no breadcrumb, and helm-lsp/lsp-treemacs
;; are unavailable.  imenu, xref and flymake cover the ground that matters.
;;
;; Documentation display is the part that needs real work in a terminal, so
;; there are three levels: eldoc in the echo area (always), a doc buffer in a
;; side window (`C-c d'), and a genuine floating popup drawn with popon
;; (`C-c D') — the same overlay layer corfu-terminal uses.

;;; Code:

(require 'mega-lib)

;;;; eglot

(use-package eglot
  :commands (eglot eglot-ensure)
  :custom
  ;; The events buffer is a genuine memory and latency sink on a chatty
  ;; server; keep it off unless you are debugging the protocol.
  (eglot-events-buffer-config '(:size 0 :format full))
  (eglot-autoshutdown t)                ; no orphan servers after killing buffers
  (eglot-sync-connect nil)              ; never block the UI waiting to connect
  (eglot-connect-timeout 30)
  (eglot-extend-to-xref t)
  (eglot-report-progress nil)           ; the echo area is not a progress bar
  (eglot-send-changes-idle-time 0.4)
  :config
  ;; Inlay hints add visual noise in a terminal and cost a round trip per
  ;; change.  Turn them on per-language in local.el if you want them.
  (add-to-list 'eglot-ignored-server-capabilities :inlayHintProvider))

(use-package flymake
  :hook (prog-mode . flymake-mode)
  :custom
  (flymake-no-changes-timeout 0.5)
  (flymake-fringe-indicator-position nil)   ; no fringe in a TTY
  (flymake-margin-indicators-string
   '((error "E" compilation-error) (warning "W" compilation-warning)
     (note "N" compilation-info)))
  (flymake-show-diagnostics-at-end-of-line nil))

(use-package xref
  :custom
  ;; ripgrep is present and is dramatically faster than the default grep.
  (xref-search-program (if (mega-exe-p "rg") 'ripgrep 'grep))
  (xref-history-storage 'xref-window-local-history))

;;;; eldoc

(use-package eldoc
  :custom
  (eldoc-idle-delay 0.2)
  ;; Three lines is enough for a signature plus a summary, and does not make
  ;; the echo area jump around while you type.
  (eldoc-echo-area-use-multiline-p 3)
  (eldoc-echo-area-display-truncation-message nil)
  (eldoc-documentation-strategy #'eldoc-documentation-compose)
  :config (global-eldoc-mode 1))

(defun mega-doc-buffer ()
  "Show documentation for the thing at point in a side window.
The reliable option everywhere, and the fallback for `mega-doc-at-point'."
  (interactive)
  (let ((buffer (eldoc-doc-buffer t)))
    (unless buffer (user-error "No documentation at point"))
    (display-buffer buffer
                    '((display-buffer-in-side-window)
                      (side . bottom) (window-height . 0.3)
                      (dedicated . t)))))

;;;; A documentation popup for the terminal
;;
;; popon draws with overlays, so unlike child frames it works in a TTY.  It is
;; already installed as a corfu-terminal dependency.  This is the one piece of
;; genuinely new code in MEGA; if it misbehaves, `mega-doc-buffer' is the
;; documented fallback and nothing else depends on it.

(defcustom mega-doc-popup-max-lines 16
  "Most lines `mega-doc-at-point' will draw."
  :type 'integer :group 'mega)

(defcustom mega-doc-popup-max-width 82
  "Widest column `mega-doc-at-point' will draw."
  :type 'integer :group 'mega)

(defface mega-doc-popup '((t :inherit tooltip))
  "Face for the terminal documentation popup."
  :group 'mega)

(defvar mega--doc-popon nil "The live popon, if any.")
(defvar mega--doc-pending nil "Non-nil while waiting for eldoc to answer.")

(defun mega-doc-popup-hide ()
  "Remove the documentation popup."
  (when mega--doc-popon
    (ignore-errors (popon-kill mega--doc-popon))
    (setq mega--doc-popon nil)
    (remove-hook 'pre-command-hook #'mega-doc-popup-hide)))

(defun mega--doc-popup-show (text)
  "Draw TEXT as a popup just below point."
  (mega-doc-popup-hide)
  (let* ((body (string-trim text)))
    (unless (string-empty-p body)
      (let* ((lines (seq-take (split-string body "\n") mega-doc-popup-max-lines))
             (width (min mega-doc-popup-max-width
                         (apply #'max 1 (mapcar #'string-width lines))))
             (padded (mapcar (lambda (l)
                               (propertize (truncate-string-to-width l width nil ?\s)
                                           'face 'mega-doc-popup))
                             lines))
             (pos (posn-col-row (posn-at-point)))
             (row (cdr pos))
             ;; Draw above point when there is not room below.
             (above (> (+ row (length padded) 2) (window-body-height)))
             (y (if above (max 0 (- row (length padded))) (1+ row))))
        (setq mega--doc-popon
              (popon-create (cons (string-join padded "\n") width)
                            (cons (car pos) y)))
        (add-hook 'pre-command-hook #'mega-doc-popup-hide)))))

(defun mega--doc-display (docs _interactive)
  "eldoc display function: draw DOCS as a popup, but only when asked.
Installed permanently because eldoc answers asynchronously — a
dynamically bound display function would be long gone by the time the
server replies."
  (when mega--doc-pending
    (setq mega--doc-pending nil)
    (mega--doc-popup-show
     (mapconcat (lambda (d) (if (consp d) (car d) (format "%s" d))) docs "\n"))))

(defun mega-doc-at-point ()
  "Show documentation for the thing at point in a floating terminal popup.
Falls back to `mega-doc-buffer' in a GUI frame, or if popon is missing."
  (interactive)
  (if (or (display-graphic-p) (not (require 'popon nil :noerror)))
      (mega-doc-buffer)
    (add-hook 'eldoc-display-functions #'mega--doc-display)
    (setq mega--doc-pending t)
    (eldoc-print-current-symbol-info t)))

(provide 'mega-lsp)
;;; mega-lsp.el ends here
