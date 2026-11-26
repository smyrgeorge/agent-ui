;;; agent-ui.el --- A canvas where coding agents show their work  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yorgos S.

;; Author: Yorgos S. <https://github.com/smyrgeorge>
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

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'agent-ui-request)
(require 'agent-ui-agent)
(require 'agent-ui-pane)
(require 'agent-ui-persist)
(require 'agent-ui-ask)
(require 'agent-ui-components)
(require 'agent-ui-finished)
(require 'agent-ui-staging)
(require 'agent-ui-review)
(require 'agent-ui-source)
(require 'agent-ui-panels)
(require 'agent-ui-snapshot)
(require 'agent-ui-bug)

(defvar agent-shell-mcp-servers)
(defvar agent-shell--state)
(defvar browse-url-handlers)
(declare-function agent-shell-cwd "agent-shell-project")

;; ====== OPTIONS ======

(defcustom agent-ui-system-prompt t
  "Non-nil: agents are told about their canvas in their system prompt.
What they're told is `agent-ui-agent-context', appended to agent-shell's
system prompt for the agents that take one (`agent-shell-system-prompt').
Set it to nil to tell them yourself."
  :type 'boolean :group 'agent-ui)

(defcustom agent-ui-mcp t
  "Non-nil: each agent-shell session gets Agent UI as MCP tools too.
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
    (args . ("--batch" "-Q" "-l" ,(expand-file-name "agent-ui-mcp.el" agent-ui-directory)
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
      (let* ((agent-ui-agent-identifier
              (map-nested-elt agent-shell--state '(:agent-config :identifier)))
             (context (agent-ui-agent-context)))
        (if context
            (string-join (delq nil (list prompt context)) "\n\n")
          prompt))
    prompt))

;; ====== THE MODE ======

(defun agent-ui--command-executable ()
  "Make bin/agent-ui executable: a package's files may lose their modes."
  (when (and (file-exists-p agent-ui-command)
             (not (file-executable-p agent-ui-command)))
    (ignore-errors (set-file-modes agent-ui-command #o755))))

(defvar agent-ui--kept-loaded nil
  "Non-nil once the types the user kept were loaded.")

;;;###autoload
(define-minor-mode agent-ui-mode
  "Tie Agent UI to agent-shell and to Emacs's windows.
Each agent-shell session's agent finds its own canvas (from its
environment's AGENT_UI_SESSION), is told about it
\(`agent-ui-system-prompt') and gets its MCP tools (`agent-ui-mcp', for
the sessions started from now on).  A question left waiting when a turn
ends is shown, the mode line saying so; canvases are kept with their
sessions; the canvas's views follow their session's pane."
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
        (add-hook 'kill-emacs-hook #'agent-ui--persist-all-now)
        (add-hook 'after-setting-font-hook #'agent-ui--font-changed)
        (add-hook 'window-state-change-functions #'agent-ui--pane-sync-h)
        (add-to-list 'window-persistent-parameters '(agent-ui-pane . writable))
        (add-to-list 'mode-line-misc-info agent-ui--question-mode-line-entry t)
        (require 'browse-url)
        (add-to-list 'browse-url-handlers '("\\`agent-ui:" . agent-ui-open-link))
        (when agent-ui-mcp
          (agent-ui--mcp-register))
        (agent-ui--command-executable)
        (unless agent-ui--kept-loaded
          (setq agent-ui--kept-loaded t)
          (agent-ui-load-kept)))
    (advice-remove 'agent-shell--make-acp-client #'agent-ui--client-environment-a)
    (advice-remove 'agent-shell--system-prompt #'agent-ui--system-prompt-a)
    (remove-hook 'agent-shell-mode-hook #'agent-ui--watch-questions-h)
    (remove-hook 'agent-shell-mode-hook #'agent-ui--persist-watch)
    (remove-hook 'kill-emacs-hook #'agent-ui--persist-all-now)
    (remove-hook 'after-setting-font-hook #'agent-ui--font-changed)
    (remove-hook 'window-state-change-functions #'agent-ui--pane-sync-h)
    (setq window-persistent-parameters
          (assq-delete-all 'agent-ui-pane window-persistent-parameters))
    (setq mode-line-misc-info (delete agent-ui--question-mode-line-entry mode-line-misc-info))
    (when (boundp 'browse-url-handlers)
      (setq browse-url-handlers (delete '("\\`agent-ui:" . agent-ui-open-link) browse-url-handlers)))
    (agent-ui--mcp-unregister)
    (setq agent-ui-agent-mcp nil)))

(provide 'agent-ui)

;;; agent-ui.el ends here
