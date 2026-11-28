;;; agent-ui.el --- A canvas where coding agents show their work  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yorgos S.

;; Author: Yorgos S. <https://github.com/smyrgeorge>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/smyrgeorge/agent-ui
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.99.0") (vui "1.4.0"))
;; Keywords: tools, convenience

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Agent UI gives a coding agent running in agent-shell a canvas in Emacs:
;; progress bars, checklists, tables, charts, diffs, diagrams and
;; questions for you, at the bottom of its session's pane, each updated
;; in place as the work goes on.
;;
;; The agent drives it from its shell with one command, bin/agent-ui
;; (show, update, append, remove... a component as JSON, a JSON reply),
;; which reaches Emacs through emacsclient, or through the same
;; operations as MCP tools (agent-ui-mcp.el).  Each agent-shell session
;; gets a canvas of its own, which closes with it and comes back when
;; the session is resumed.
;;
;; Setup:
;;
;;   (require 'agent-ui)
;;   (server-start)        ; the command reaches Emacs through its server
;;   (agent-ui-mode 1)
;;
;; `agent-ui-mode' ties Agent UI to agent-shell: each session's agent
;; finds its own canvas, is told about it (`agent-ui-system-prompt') and
;; gets its MCP tools (`agent-ui-mcp').  The guide agents read before
;; using it is skills/agent-ui/SKILL.md; see the README for more.
;; M-x agent-ui-doctor checks what it needs, and says how to fix what's
;; missing.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst agent-ui--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Agent UI's folder, this file's: its parts' and its MCP server's.")

;; ====== ITS PARTS, LOADED WHEN NEEDED ======

;; Only this file is loaded with Emacs; the rest (agent-ui-parts.el), the
;; first time agent-shell is loaded (`agent-ui-mode') or Agent UI used:
;; bin/agent-ui's requests, these commands, the mode's hooks in a
;; session, its Lisp interface (docs/lisp.md).  An option of its parts is
;; there once they're loaded: `setq' it any time; to `let'-bind it
;; before, (require 'agent-ui-parts) first (bound before it's defined,
;; it's lexical: an error then).
(dolist (fn '(agent-ui-request agent-ui-agent-context
              agent-ui--client-environment-a agent-ui--watch-questions-h
              agent-ui--persist-watch
              agent-ui-show agent-ui-update agent-ui-append agent-ui-remove
              agent-ui-clear agent-ui-set-title agent-ui-canvas-title agent-ui-get
              agent-ui-components agent-ui-reveal agent-ui-section agent-ui-sections
              agent-ui-remove-section agent-ui-host agent-ui-unhost))
  (autoload fn "agent-ui-parts"))
(dolist (command '(agent-ui-open-dashboard agent-ui-open-dashboard-here
                   agent-ui-dashboard-forget-project agent-ui-goto-question
                   agent-ui-pane-toggle))
  (autoload command "agent-ui-parts" nil t))
;; Types, defined or drawn (docs/custom-types.md): its core only.
(dolist (fn '(agent-ui-autoload-type agent-ui-load-types agent-ui-types
              agent-ui-undefine agent-ui-render agent-ui-context))
  (autoload fn "agent-ui-core"))
(autoload 'agent-ui-define "agent-ui-core" nil nil 'macro)
;; Loaded when first used, their parts with them: the doctor (loading
;; nothing else, there when the rest fails to load), bugs, the types the
;; agent makes, snapshots (Agent UI's links).
(autoload 'agent-ui-doctor "agent-ui-doctor"
  "Check what Agent UI needs in this Emacs, and show what's missing." t)
(autoload 'agent-ui-doctor-request "agent-ui-doctor"
  "Answer bin/agent-ui doctor's request in FOLDER: its reply written there.")
(autoload 'agent-ui-report-bug "agent-ui-bug"
  "Report a bug in Agent UI." t)
(autoload 'agent-ui-review "agent-ui-review"
  "List the component types the agent made, to keep or discard." t)
(autoload 'agent-ui-open-link "agent-ui-snapshot"
  "Open URL, an agent-ui:// link.")

(defvar agent-shell-mcp-servers)
(defvar agent-shell--state)
(defvar browse-url-handlers)
(defvar agent-ui-agent-identifier)
(defvar agent-ui-agent-mcp)
(defvar agent-ui-kept-directory)
(defvar agent-ui-staging-directory)
(defvar agent-ui-command)
(defvar agent-ui--question-mode-line-entry)
;; agent-shell's, loaded with it: only called in its sessions.
(declare-function map-elt "map" (map key &optional default testfn))
(declare-function map-nested-elt "map" (map keys &optional default))
(declare-function agent-shell-cwd "agent-shell-project")
;; Its parts'.
(declare-function agent-ui--session-name "agent-ui-agent" (buffer))
(declare-function agent-ui--type-files "agent-ui-core" (directory))
(declare-function agent-ui--require "agent-ui-core" (feature))
(declare-function agent-ui-load-kept "agent-ui-staging" ())
(declare-function agent-ui--persist-all-now "agent-ui-persist" ())
(declare-function agent-ui--font-changed "agent-ui-canvas" ())
(declare-function agent-ui--pane-sync-h "agent-ui-pane" (frame))
(declare-function agent-ui-mermaid--redraw "agent-ui-mermaid" (&optional diagram))

;; ====== OPTIONS ======

(defcustom agent-ui-system-prompt t
  "Non-nil: agents are told about their canvas in their system prompt.
What they're told is `agent-ui-agent-context', appended to agent-shell's
system prompt for the agents that take one (`agent-shell-system-prompt').
Set it to nil to tell them yourself."
  :type 'boolean :group 'agent-ui)

(defcustom agent-ui-mcp t
  "Non-nil: each `agent-shell' session gets Agent UI as MCP tools too.
A batch Emacs runs agent-ui-mcp.el for each session that starts after
`agent-ui-mode' is on (`agent-shell-mcp-servers')."
  :type 'boolean :group 'agent-ui)

;; ====== MCP ======

(defun agent-ui-mcp-server ()
  "Agent UI's MCP server, as `agent-shell-mcp-servers' has them.
Its session's name and directory are read when the session starts, in
its buffer."
  `((name . "agent-ui")
    (command . ,(expand-file-name invocation-name invocation-directory))
    (args . ("--batch" "-Q" "-l" ,(expand-file-name "agent-ui-mcp.el" agent-ui--directory)
             "-f" "agent-ui-mcp-main"))
    (env . (((name . "AGENT_UI_SESSION")
             (value . ,(lambda () (agent-ui--session-name (current-buffer)))))
            ((name . "AGENT_UI_DIR")
             (value . ,(lambda () (if (fboundp 'agent-shell-cwd)
                                      (agent-shell-cwd)
                                    default-directory))))))))

(defun agent-ui--mcp-unregister ()
  "Take Agent UI's MCP server out of `agent-shell-mcp-servers'."
  (setq agent-shell-mcp-servers
        (seq-remove (lambda (server) (equal (alist-get 'name server) "agent-ui"))
                    (bound-and-true-p agent-shell-mcp-servers))))

(defun agent-ui--mcp-register ()
  "Add (or replace) Agent UI's MCP server in `agent-shell-mcp-servers'."
  (agent-ui--mcp-unregister)
  (setq agent-shell-mcp-servers
        (append agent-shell-mcp-servers (list (agent-ui-mcp-server)))
        agent-ui-agent-mcp t))

;; ====== THE SYSTEM PROMPT ======

(defun agent-ui--system-prompt-a (prompt)
  "PROMPT, agent-shell's system prompt for a session, with its canvas's text.
Only for an agent that takes one; nil stays nil when it doesn't."
  (if (and agent-ui-system-prompt
           (boundp 'agent-shell--state)
           (map-elt agent-shell--state :supports-system-prompt))
      (progn
        ;; Before binding its option: loaded inside, it would warn.
        (require 'agent-ui-parts)
        (let* ((agent-ui-agent-identifier
                (map-nested-elt agent-shell--state '(:agent-config :identifier)))
               (context (agent-ui-agent-context)))
          (if context
              (string-join (delq nil (list prompt context)) "\n\n")
            prompt)))
    prompt))

;; ====== DIAGRAMS, AFTER A THEME SWITCH ======

(defun agent-ui-mermaid-theme-changed ()
  "Draw each diagram again, in the colours of the theme now.
For a hook run after a theme switch.  Nothing before a diagram was
drawn (agent-ui-mermaid.el not loaded): a theme's hooks run as Emacs
starts, and loading it with its parts there took ~25 ms."
  (when (featurep 'agent-ui-mermaid)
    (agent-ui-mermaid--redraw)))

;; ====== THE MODE ======

(defun agent-ui--command-executable ()
  "Make bin/agent-ui executable: a package's files may lose their modes."
  (when (and (file-exists-p agent-ui-command)
             (not (file-executable-p agent-ui-command)))
    (ignore-error file-error (set-file-modes agent-ui-command #o755))))

(defvar agent-ui--kept-loaded nil
  "Non-nil once the types the user kept were loaded.")

(defvar agent-ui--mode-started nil
  "Non-nil once the mode's hooks that need Agent UI's parts are on.")

(defvar agent-ui--loading nil
  "Non-nil while the mode loads Agent UI's parts.")

(defconst agent-ui--link-handler '("\\`agent-ui:" . agent-ui-open-link)
  "Agent UI's entry in `browse-url-handlers': its links opened in Emacs.")

(defun agent-ui--mode-start ()
  "Turn on what of the mode needs Agent UI's parts (agent-ui-parts.el).
Not with the mode, before they're loaded: its pane's and canvases'
hooks (each change of windows, each font set, at Emacs's end), the mode
line's question, the types the user kept and the agent made."
  (setq agent-ui--mode-started t)
  (add-hook 'kill-emacs-hook #'agent-ui--persist-all-now)
  (add-hook 'after-setting-font-hook #'agent-ui--font-changed)
  (add-hook 'window-state-change-functions #'agent-ui--pane-sync-h)
  (add-to-list 'mode-line-misc-info agent-ui--question-mode-line-entry t)
  (agent-ui--command-executable)
  (unless agent-ui--kept-loaded
    (setq agent-ui--kept-loaded t)
    ;; agent-ui-staging.el loaded only when there are any.
    (when (agent-ui--type-files agent-ui-kept-directory)
      (agent-ui-load-kept)))
  ;; Types the agent made, waiting for the user: their header on each
  ;; canvas, their list (agent-ui-review.el).
  (when (agent-ui--type-files agent-ui-staging-directory)
    (agent-ui--require 'agent-ui-review)))

(defun agent-ui--after-load (&optional _file)
  "What `agent-ui-mode' waits for, once loaded (FILE a file just loaded).

In `after-load-functions' while the mode is on, until done: `agent-shell'
loaded, Agent UI's parts loaded with it (each session needs them);
those loaded, however they were, the rest of the mode on
\(`agent-ui--mode-start'); `browse-url' loaded, Agent UI's links
handled (`agent-ui--link-handler').  Loading it for this (url,
auth-source, eieio with it) took 0.2 s of Emacs's start, and the first
link opened loads it anyway."
  (when (and (featurep 'agent-shell) (not (featurep 'agent-ui-parts))
             (not agent-ui--loading))
    (let ((agent-ui--loading t)
          (load-path (cons agent-ui--directory load-path)))
      (require 'agent-ui-parts)))
  (when (and (featurep 'agent-ui-parts) (not agent-ui--mode-started))
    (agent-ui--mode-start))
  (when (featurep 'browse-url)
    (add-to-list 'browse-url-handlers agent-ui--link-handler))
  (when (and agent-ui--mode-started (featurep 'browse-url))
    (remove-hook 'after-load-functions #'agent-ui--after-load)))

;;;###autoload
(define-minor-mode agent-ui-mode
  "Tie Agent UI to `agent-shell' and to Emacs's windows.
Each `agent-shell' session's agent finds its own canvas (from its
environment's AGENT_UI_SESSION), is told about it
\(`agent-ui-system-prompt') and gets its MCP tools (`agent-ui-mcp', for
the sessions started from now on).  A question left waiting when a turn
ends is shown, the mode line saying so; canvases are kept with their
sessions; the canvas's views follow their session's pane.

Agent UI's parts are loaded the first time `agent-shell' is, or Agent
UI used: not with Emacs."
  :global t
  :group 'agent-ui
  (if agent-ui-mode
      (progn
        (advice-add 'agent-shell--make-acp-client :filter-args
                    #'agent-ui--client-environment-a)
        (advice-add 'agent-shell--system-prompt :filter-return
                    #'agent-ui--system-prompt-a)
        (add-hook 'agent-shell-mode-hook #'agent-ui--watch-questions-h)
        (add-hook 'agent-shell-mode-hook #'agent-ui--persist-watch)
        (add-to-list 'window-persistent-parameters '(agent-ui-pane . writable))
        (when agent-ui-mcp
          (agent-ui--mcp-register))
        (add-hook 'after-load-functions #'agent-ui--after-load)
        (agent-ui--after-load))
    (advice-remove 'agent-shell--make-acp-client #'agent-ui--client-environment-a)
    (advice-remove 'agent-shell--system-prompt #'agent-ui--system-prompt-a)
    (remove-hook 'agent-shell-mode-hook #'agent-ui--watch-questions-h)
    (remove-hook 'agent-shell-mode-hook #'agent-ui--persist-watch)
    (remove-hook 'kill-emacs-hook #'agent-ui--persist-all-now)
    (remove-hook 'after-setting-font-hook #'agent-ui--font-changed)
    (remove-hook 'window-state-change-functions #'agent-ui--pane-sync-h)
    (setq window-persistent-parameters
          (assq-delete-all 'agent-ui-pane window-persistent-parameters))
    (when (boundp 'agent-ui--question-mode-line-entry)
      (setq mode-line-misc-info (delete agent-ui--question-mode-line-entry mode-line-misc-info)))
    (remove-hook 'after-load-functions #'agent-ui--after-load)
    (when (boundp 'browse-url-handlers)
      (setq browse-url-handlers (delete agent-ui--link-handler browse-url-handlers)))
    (agent-ui--mcp-unregister)
    (setq agent-ui-agent-mcp nil
          agent-ui--mode-started nil)))

(provide 'agent-ui)

;;; agent-ui.el ends here
