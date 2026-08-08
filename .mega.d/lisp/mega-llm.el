;;; mega-llm.el --- Claude, two ways  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two tiers with very different prerequisites.
;;
;; Tier 1 — the `claude' CLI (C-c l c).  Needs no API key: it uses the CLI's
;; own authentication, which is already set up on this machine.  This is the
;; one to start with.  It is twenty lines over `eat' rather than one of the
;; several competing third-party Claude-in-Emacs packages, because that corner
;; of the ecosystem is churning and twenty lines have no upstream to break.
;; `eat' is pure Lisp on NonGNU ELPA and needs no compilation, unlike vterm.
;;
;; Tier 2 — gptel (the rest of C-c l).  Needs an Anthropic API key, read
;; through auth-source and never stored in this repository.  See the Secrets
;; section below; `mega-doctor' tells you whether a key was found.

;;; Code:

(require 'mega-lib)
(require 'auth-source)

;;;; Secrets
;;
;; The rule: the key is fetched by a function at call time, never written into
;; a tracked file.  .mega.d is deployed by update.sh and .my_profile is tracked,
;; so neither may ever contain it.  auth-source reads ~/.authinfo.gpg (best) or
;; ~/.authinfo with mode 0600 (acceptable); this machine currently has neither,
;; which is why `mega-claude' — needing no key at all — is the recommended
;; starting point.

(defcustom mega-llm-api-host "api.anthropic.com"
  "auth-source host entry holding the Anthropic API key."
  :type 'string :group 'mega)

(defun mega-llm-api-key ()
  "Return the Anthropic API key from auth-source, or nil.
Add a line to ~/.authinfo.gpg:

  machine api.anthropic.com login apikey password sk-ant-..."
  (or (auth-source-pick-first-password :host mega-llm-api-host :user "apikey")
      (auth-source-pick-first-password :host mega-llm-api-host)))

;;;; Tier 1: the Claude CLI in a terminal buffer

(use-package eat
  :ensure t
  :commands (eat eat-make)
  :custom
  (eat-kill-buffer-on-exit t)
  (eat-enable-yank-to-terminal t))

(defun mega-claude--buffer-name (root)
  "Name of the Claude buffer for project ROOT."
  (format "claude: %s" (file-name-nondirectory (directory-file-name root))))

;;;###autoload
(defun mega-claude ()
  "Open (or return to) a Claude CLI session rooted at this project.
One session per project, reused.  Needs no API key — the CLI carries its
own authentication."
  (interactive)
  (unless (mega-exe-p "claude")
    (user-error "The `claude' CLI is not on PATH"))
  (unless (require 'eat nil :noerror)
    (user-error "eat is not installed: M-x package-install RET eat RET"))
  (let* ((root (or (mega-project-root) default-directory))
         (label (mega-claude--buffer-name root))
         (existing (get-buffer (format "*%s*" label))))
    (pop-to-buffer
     (or existing
         (let ((default-directory root))
           (eat-make label "claude"))))))

;;;###autoload
(defun mega-claude-send-region (start end)
  "Send the region from START to END to this project's Claude session."
  (interactive "r")
  (let ((text (buffer-substring-no-properties start end))
        (origin (current-buffer)))
    (save-window-excursion (mega-claude))
    (let ((buffer (get-buffer (format "*%s*" (mega-claude--buffer-name
                                              (or (with-current-buffer origin (mega-project-root))
                                                  default-directory))))))
      (unless buffer (user-error "No Claude session to send to"))
      (with-current-buffer buffer
        (eat-term-send-string eat-terminal text))
      (message "MEGA: sent %d characters to Claude" (length text)))))

;;;; Tier 2: gptel

(use-package gptel
  :ensure t
  :commands (gptel gptel-send gptel-menu gptel-rewrite)
  :custom
  ;; The current Opus models REMOVED the sampling parameters: sending
  ;; `temperature' at all returns HTTP 400.  gptel sets it by default, so
  ;; clearing it here is not a preference, it is what makes requests work.
  (gptel-temperature nil)
  ;; Thinking is on by default on claude-opus-5, and max_tokens caps thinking
  ;; plus answer text together — a tight budget truncates mid-answer.  gptel
  ;; streams, so a large value costs nothing in latency.
  (gptel-max-tokens 32768)
  (gptel-stream t)
  (gptel-default-mode 'markdown-ts-mode)
  ;; Transcripts contain your code.  Nothing is persisted unless you ask, and
  ;; when you do it lands outside both the repo and the config directory.
  (gptel-log-level nil)
  :config
  (setq gptel-backend
        (gptel-make-anthropic "claude"
          :stream t
          :key #'mega-llm-api-key
          ;; gptel ships a model list that predates these IDs, so name them
          ;; explicitly rather than inheriting a stale one.
          :models '(claude-opus-5 claude-sonnet-5 claude-haiku-4-5))
        gptel-model 'claude-opus-5)
  ;; Agentic tool use stays off: MEGA does not hand an LLM write access to
  ;; your filesystem by default.  That is what `mega-claude' is for, where you
  ;; can see every action in the terminal.
  (setq gptel-use-tools nil))

(use-package gptel-quick
  :vc (:url "https://github.com/karthink/gptel-quick" :rev :newest)
  :commands (gptel-quick))

(defun mega-llm--require-key ()
  "Signal a useful error if no API key is configured."
  (unless (mega-llm-api-key)
    (user-error
     "No Anthropic API key in auth-source for %s.  Add to ~/.authinfo.gpg:\n  machine %s login apikey password sk-ant-...\n(Or use C-c l c, which needs no key.)"
     mega-llm-api-host mega-llm-api-host)))

;;;###autoload
(defun mega-llm-chat ()
  "Open a gptel chat buffer for this project."
  (interactive)
  (mega-llm--require-key)
  (let ((default-directory (or (mega-project-root) default-directory)))
    (call-interactively #'gptel)))

;;;###autoload
(defun mega-llm-send ()
  "Send the region, or the buffer up to point, to Claude."
  (interactive)
  (mega-llm--require-key)
  (call-interactively #'gptel-send))

;;;###autoload
(defun mega-llm-rewrite ()
  "Rewrite the region with Claude, showing a diff before applying."
  (interactive)
  (mega-llm--require-key)
  (call-interactively #'gptel-rewrite))

;;;###autoload
(defun mega-llm-quick ()
  "Explain the thing at point, briefly, in a popup."
  (interactive)
  (mega-llm--require-key)
  (call-interactively #'gptel-quick))

;;;###autoload
(defun mega-llm-menu ()
  "The gptel transient menu: model, backend, scope, directives."
  (interactive)
  (mega-llm--require-key)
  (call-interactively #'gptel-menu))

(provide 'mega-llm)
;;; mega-llm.el ends here
