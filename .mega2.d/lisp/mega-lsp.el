;;; mega-lsp.el --- The language server, diagnostics, documentation  -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything here ships with Emacs: eglot speaks to the language server,
;; flymake shows what it reports, eldoc shows documentation, xref navigates.
;; This file sets them up; which server belongs to which language is data,
;; in mega-lang.el.
;;
;;   M-.  M-?  M-,     definition, references, back        (Emacs's own keys)
;;   C-c d  /  C-c D   documentation in a side window / in a popup
;;   C-c c r           rename                C-c c a   code actions
;;   C-c c i           implementation        C-c c t   type definition
;;   C-c c h           call hierarchy        C-c c o   organise imports
;;   C-c c n / p       next / previous problem
;;   C-c c e / E       list the problems of the buffer / the project
;;
;; A server is started only when its program exists, so a machine without
;; one simply has no server: no error, no prompt.
;;
;; Privacy: MEGA switches telemetry off for the servers that have a switch,
;; and keeps no log of the conversation with a server.

;;; Code:

(require 'mega-lib)
(require 'mega-popup)

(defvar eglot-events-buffer-config)
(defvar eglot-autoshutdown)
(defvar eglot-sync-connect)
(defvar eglot-connect-timeout)
(defvar eglot-extend-to-xref)
(defvar eglot-report-progress)
(defvar eglot-send-changes-idle-time)
(defvar eglot-ignored-server-capabilities)
(defvar eglot-workspace-configuration)
(defvar flymake-no-changes-timeout)
(defvar flymake-show-diagnostics-at-end-of-line)
(defvar xref-search-program)
(defvar xref-history-storage)
(defvar eldoc-idle-delay)
(defvar eldoc-echo-area-use-multiline-p)
(defvar eldoc-echo-area-display-truncation-message)
(defvar eldoc-documentation-strategy)
(defvar eldoc-display-functions)

;;;; eglot

;; The commands MEGA binds keys to, so that a key works before the library
;; that defines it has been loaded.
(dolist (command '(eglot-rename eglot-code-actions eglot-find-implementation
                   eglot-find-typeDefinition eglot-show-call-hierarchy
                   eglot-code-action-organize-imports))
  (autoload command "eglot" nil t))
(dolist (command '(flymake-goto-next-error flymake-goto-prev-error
                   flymake-show-buffer-diagnostics
                   flymake-show-project-diagnostics))
  (autoload command "flymake" nil t))

(setq
 ;; The log of every message is a memory and latency sink on a chatty
 ;; server, and a record of your code.  Off unless you are debugging.
 eglot-events-buffer-config '(:size 0 :format full)
 eglot-autoshutdown t                ; no orphan servers after closing buffers
 eglot-sync-connect nil              ; never block the editor waiting to connect
 eglot-connect-timeout 30
 eglot-extend-to-xref t
 eglot-report-progress nil           ; the echo area is not a progress bar
 eglot-send-changes-idle-time 0.4)

;; Telemetry off, for the servers that would otherwise send it.
(setq-default eglot-workspace-configuration
              '(:redhat (:telemetry (:enabled :json-false))
                :telemetry (:enableTelemetry :json-false)))

(with-eval-after-load 'eglot
  ;; Inlay hints add noise in a terminal and cost a round trip per change.
  ;; `M-x eglot-inlay-hints-mode' turns them on in a buffer.
  (add-to-list 'eglot-ignored-server-capabilities :inlayHintProvider))

;;;; Diagnostics

(setq flymake-no-changes-timeout 0.5
      flymake-show-diagnostics-at-end-of-line nil)

(add-hook 'prog-mode-hook #'flymake-mode)

;;;; Navigation

(setq xref-search-program (if (mega-exe-p "rg") 'ripgrep 'grep)
      xref-history-storage 'xref-window-local-history)

;;;; Documentation
;;
;; Three levels: a line or three in the echo area, always; the full text in a
;; side window on `C-c d'; a popup at point on `C-c D'.

(setq eldoc-idle-delay 0.2
      eldoc-echo-area-use-multiline-p 3
      eldoc-echo-area-display-truncation-message nil
      eldoc-documentation-strategy #'eldoc-documentation-compose)

(defcustom mega-doc-popup-max-lines 16
  "Most lines the documentation popup shows."
  :type 'integer :group 'mega)

(defcustom mega-doc-popup-max-width 80
  "Widest the documentation popup gets, in columns."
  :type 'integer :group 'mega)

;;;###autoload
(defun mega-doc-buffer ()
  "Show documentation for the thing at point in a side window."
  (interactive)
  (let ((buffer (eldoc-doc-buffer t)))
    (unless buffer
      (user-error "No documentation at point"))
    (display-buffer buffer
                    '((display-buffer-in-side-window)
                      (side . bottom) (window-height . 0.3)))))

(defvar mega-doc--pending nil
  "Non-nil between asking for the documentation popup and getting an answer.")

(defun mega-doc-lines (text max-width max-lines)
  "Split TEXT into at most MAX-LINES lines of at most MAX-WIDTH columns.
Long lines are wrapped at spaces.  Markdown code fences are dropped: the
text is shown as it is, not rendered."
  (let (lines)
    (dolist (line (split-string (string-trim text) "\n"))
      (unless (string-match-p "\\`[ \t]*```" line)
        (if (<= (string-width line) max-width)
            (push line lines)
          (with-temp-buffer
            (insert line)
            (let ((fill-column max-width))
              (fill-region (point-min) (point-max)))
            (dolist (wrapped (split-string (buffer-string) "\n"))
              (push wrapped lines))))))
    (take max-lines (nreverse lines))))

(defun mega-doc-popup-hide ()
  "Take the documentation popup away."
  (mega-popup-hide 'doc)
  (remove-hook 'pre-command-hook #'mega-doc-popup-hide))

(defun mega-doc--display (docs _interactive)
  "Show DOCS, as eldoc hands them over, in a popup — but only when asked.
On the hook permanently, because the answer arrives later: a function
bound just for the request would be gone by then."
  (when mega-doc--pending
    (setq mega-doc--pending nil)
    (let ((lines (mega-doc-lines
                  (mapconcat (lambda (doc) (if (consp doc) (car doc) (format "%s" doc)))
                             docs "\n\n")
                  mega-doc-popup-max-width mega-doc-popup-max-lines)))
      (when (and lines
                 (mega-popup-show 'doc
                                  (mapcar (lambda (line) (concat " " line " ")) lines)
                                  nil nil
                                  (+ 2 mega-doc-popup-max-width)
                                  mega-doc-popup-max-lines))
        ;; Any key takes it away again.
        (add-hook 'pre-command-hook #'mega-doc-popup-hide)))))

;;;###autoload
(defun mega-doc-popup ()
  "Show documentation for the thing at point in a popup.
Where a popup cannot be drawn, show it in a side window instead."
  (interactive)
  (if (not (mega-popup-available-p))
      (mega-doc-buffer)
    (add-hook 'eldoc-display-functions #'mega-doc--display)
    (setq mega-doc--pending t)
    (eldoc-print-current-symbol-info t)))

(provide 'mega-lsp)
;;; mega-lsp.el ends here
