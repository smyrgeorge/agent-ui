;;; agent-ui-agent.el --- Each agent-shell session and its own canvas  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yorgos S.

;; Author: Yorgos S. <https://github.com/smyrgeorge>
;; URL: https://github.com/smyrgeorge/agent-ui

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

;; Agent UI and agent-shell's sessions: each session's agent finds its
;; own canvas, which closes with it.
;;
;; - agent-shell starts each session's agent with AGENT_UI_SESSION in its
;;   environment, the session's name (its buffer's, when it started); the
;;   agent's shell inherits it, so bin/agent-ui says whose request it is.
;; - Without it (an agent started otherwise, a session older than this), the
;;   session working in the request's directory: the deepest one, of those
;;   the most recently used.
;; - A canvas is named after its session, its others after it ("SESSION /
;;   tests"); killing the session kills them.
;; - A session's canvas shown in a section of another (`agent-ui-host'): its
;;   components there are its, as on its own canvas (its actions, questions);
;;   killing the session removes them, the section staying.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'agent-ui-request)

(declare-function agent-ui-ask-done-p "agent-ui-ask")
(declare-function agent-ui-ask-waiting-p "agent-ui-ask")

;; ====== VARIABLES ======

(defvar-local agent-ui-session nil
  "In an `agent-shell' buffer: its session's name for Agent UI (its canvas's).")

;; Kept if the buffer's major mode is set after its agent was started.
(put 'agent-ui-session 'permanent-local t)

(defvar-local agent-ui--session-buffer nil
  "In a canvas: its session's `agent-shell' buffer, if it has one.")

(defvar-local agent-ui--canvas-part nil
  "The name of this canvas within its session.

In a session's other canvas: its own name (\"tests\"); nil in the
session's canvas.")

;; ====== THE SESSION'S ENVIRONMENT ======

(defun agent-ui--session-name (buffer)
  "BUFFER's session name (`agent-ui-session'): given once, its name then.
Its own: a name another live session has (its buffer renamed since, or
restarted: its client made before its buffer was renamed back) gets the
first of <2>, <3>... free after it (its own <N> left out).  Two agents
with one name would share a canvas, each's answers going to the other."
  (with-current-buffer buffer
    (or agent-ui-session
        (setq agent-ui-session
              (let ((taken (delq nil (mapcar (lambda (other)
                                               (and (not (eq other buffer))
                                                    (buffer-local-value 'agent-ui-session other)))
                                             (agent-ui--sessions))))
                    (name (buffer-name))
                    (n 1))
                (while (member name taken)
                  (setq name (format "%s<%d>" (replace-regexp-in-string "<[0-9]+>\\'" "" (buffer-name))
                                     (cl-incf n))))
                name)))))

(defun agent-ui--client-environment-a (args)
  "Add AGENT_UI_SESSION to the environment of an ACP client.

`agent-shell--make-acp-client''s ARGS, AGENT_UI_SESSION added to its
environment when it has a context buffer (the session's)."
  (let ((buffer (plist-get args :context-buffer)))
    (if (buffer-live-p buffer)
        (plist-put (copy-sequence args) :environment-variables
                   (cons (concat "AGENT_UI_SESSION=" (agent-ui--session-name buffer))
                         (plist-get args :environment-variables)))
      args)))

;; Installed by `agent-ui-mode' (agent-ui.el).

;; ====== FINDING THE SESSION ======

(defun agent-ui--sessions ()
  "Return agent-shell's session buffers.

agent-shell's session buffers, the most recently used first."
  (when (fboundp 'agent-shell-buffers)
    (seq-filter #'buffer-live-p (agent-shell-buffers))))

(defun agent-ui--session-cwd (buffer)
  "Return the working directory of the session BUFFER."
  (file-name-as-directory
   (expand-file-name (with-current-buffer buffer
                       (if (fboundp 'agent-shell-cwd) (agent-shell-cwd) default-directory)))))

(defun agent-ui--session-buffer (session cwd)
  "Return the session buffer named SESSION.

The session buffer named SESSION (its `agent-ui-session'); else the one
working in CWD or above it, the deepest, then the most recently used."
  (let ((sessions (agent-ui--sessions)))
    (or (and session
             (seq-find (lambda (b) (equal (buffer-local-value 'agent-ui-session b) session))
                       sessions))
        (and cwd
             (let* ((dir (file-name-as-directory (expand-file-name cwd)))
                    (matches (seq-filter (lambda (b)
                                           (string-prefix-p (agent-ui--session-cwd b) dir))
                                         sessions)))
               ;; Stable: of the deepest, the most recent first.
               (car (cl-stable-sort matches #'>
                                    :key (lambda (b) (length (agent-ui--session-cwd b))))))))))

(defun agent-ui--project-session (root)
  "Return the latest session working in the project at ROOT.
One working at ROOT or under it; never one working above it (a session in
~ isn't the project's), nil if none."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (seq-find (lambda (b) (string-prefix-p root (agent-ui--session-cwd b)))
              (agent-ui--sessions))))

(defun agent-ui-session-canvas (session cwd)
  "Return the canvas for an agent's request.

The canvas for an agent's request (`agent-ui-canvas-function'), its
name: its session's (SESSION, else the one in CWD), named after it; else
SESSION, else the default.  Made when a component is first shown in it
\(`agent-ui--link-session' then ties it to its session)."
  (let ((buffer (agent-ui--session-buffer session cwd)))
    (if buffer
        (agent-ui--session-name buffer)
      (agent-ui-request-canvas session cwd))))


(defun agent-ui--canvas-session (name)
  "Return the session a canvas named NAME is of.

The session a canvas named NAME is of: (BUFFER . PART), PART its other
canvas's name (nil for the session's canvas); nil if none."
  (let ((sessions (agent-ui--sessions)))
    (cl-flet ((named (session)
                (seq-find (lambda (b) (equal (buffer-local-value 'agent-ui-session b) session))
                          sessions)))
      (if-let* ((buffer (named name)))
          (cons buffer nil)
        ;; "SESSION / PART": the session's other canvas.
        (let ((at (string-search agent-ui-canvas-separator name)))
          (while (and at (not (named (substring name 0 at))))
            (setq at (string-search agent-ui-canvas-separator name (1+ at))))
          (when at
            (cons (named (substring name 0 at))
                  (substring name (+ at (length agent-ui-canvas-separator))))))))))

(defun agent-ui--link-session ()
  "Tie a new canvas to the session it's named after.

In a new canvas: tied to the session it's named after, if there's one
\(killed with it)."
  (when-let* ((name agent-ui--canvas-name)
              (found (agent-ui--canvas-session name)))
    (setq agent-ui--session-buffer (car found)
          agent-ui--canvas-part (cdr found))
    (add-hook 'kill-buffer-hook #'agent-ui--question-closed-h nil t)
    (with-current-buffer (car found)
      (add-hook 'kill-buffer-hook #'agent-ui--kill-canvas nil t))))

(add-hook 'agent-ui-canvas-hook #'agent-ui--link-session)

(defun agent-ui-session-canvases (session)
  "SESSION's (an `agent-shell' buffer) canvases: its own and its others."
  (seq-filter (lambda (b) (eq (buffer-local-value 'agent-ui--session-buffer b) session))
              (agent-ui-canvases)))

(defun agent-ui--session-window (canvas)
  "Show CANVAS in a window of another canvas of its session.

A window of the selected frame showing another canvas of CANVAS's
session, its own first, not as a view in the session's pane
\(`agent-ui-share-window-functions'): CANVAS goes there, a tab beside it,
not in a pane of its own (five canvases took five panes, each a few lines
high).  In the session's pane: agent-ui-pane.el."
  (when-let* ((session (buffer-local-value 'agent-ui--session-buffer canvas))
              ((buffer-live-p session)))
    (seq-some (lambda (other)
                (and (not (eq other canvas))
                     (seq-find (lambda (window) (not (window-parameter window 'agent-ui-pane)))
                               (get-buffer-window-list other 'nomini))))
              (sort (agent-ui-session-canvases session)
                    (lambda (a b) (and (null (buffer-local-value 'agent-ui--canvas-part a))
                                       (buffer-local-value 'agent-ui--canvas-part b)
                                       t))))))

(add-hook 'agent-ui-share-window-functions #'agent-ui--session-window)

(defun agent-ui--kill-canvas ()
  "The session's buffer is killed: its canvases too."
  (mapc #'kill-buffer (agent-ui-session-canvases (current-buffer))))

(defun agent-ui--key-hosts (canvas key)
  "Return the canvas hosted by the section of key KEY in CANVAS.

The canvas (its name) the section of the component of key KEY in CANVAS
hosts (`agent-ui-host'), or nil."
  (with-current-buffer canvas
    (when-let* ((section (agent-ui--find-section (agent-ui--key-section key))))
      (agent-ui--section-hosts section))))

(defun agent-ui--key-session (canvas key)
  "Return the session the component of key KEY in CANVAS is of.

The session the component of key KEY in CANVAS is of: the one whose canvas
its section hosts (`agent-ui-host'), else CANVAS's (nil: none)."
  (if-let* ((hosted (agent-ui--key-hosts canvas key)))
      (car (agent-ui--canvas-session hosted))
    (buffer-local-value 'agent-ui--session-buffer canvas)))

(defun agent-ui--canvas-sessions (canvas)
  "Return the sessions with components in CANVAS.

The sessions with components in CANVAS: its own, those whose canvases its
sections host."
  (with-current-buffer canvas
    (delete-dups (delq nil (cons agent-ui--session-buffer
                                 (mapcar (lambda (section)
                                           (when-let* ((hosted (agent-ui--section-hosts section)))
                                             (car (agent-ui--canvas-session hosted))))
                                         agent-ui--sections))))))

(defun agent-ui--hosted-h (name host _section)
  "Watch canvas NAME shown in a section of HOST.

Canvas NAME shown in a section of HOST (`agent-ui-host-functions'): if
it's a session's, the session killed removes its components there; HOST
killed, the session's question mark looked at again."
  (when-let* ((session (car (agent-ui--canvas-session name))))
    (with-current-buffer session
      (add-hook 'kill-buffer-hook #'agent-ui--unhost-session nil t))
    (with-current-buffer host
      (add-hook 'kill-buffer-hook #'agent-ui--question-closed-h nil t))))

(add-hook 'agent-ui-host-functions #'agent-ui--hosted-h)

(defun agent-ui--unhost-session ()
  "Remove a killed session's components from the sections hosting its canvas.

The session's buffer is killed: its canvas shown in another's section
no longer, its components there removed (`agent-ui-unhost')."
  (when agent-ui-session
    (agent-ui-unhost agent-ui-session)))

;; A session's other canvas emptied (cleared, its last component removed) is
;; killed, as an answered question's: it stayed, an empty tab beside its
;; session's canvas.  The next component shown there makes it again.  The
;; session's own canvas stays, its pane closed.
(defun agent-ui--close-emptied-p (canvas)
  "Whether CANVAS, emptied, is killed (`agent-ui-close-emptied-functions'):
a session's other canvas (see above)."
  (and (buffer-local-value 'agent-ui--canvas-part canvas) t))

(add-hook 'agent-ui-close-emptied-functions #'agent-ui--close-emptied-p)

;; ====== WHAT THE AGENT IS TOLD ======

(defvar agent-ui-agent-mcp nil
  "Non-nil when agents get Agent UI as MCP tools too (agent-ui-mcp.el):
their system prompt says so.")

(defcustom agent-ui-skill
  (expand-file-name "skills/agent-ui/SKILL.md" agent-ui-directory)
  "The agent-ui skill: the guide the agent reads before using the canvas."
  :type 'file :group 'agent-ui)

(defvar agent-ui-agent-identifier nil
  "The agent in use, while `agent-ui-agent-context' runs.

While `agent-ui-agent-context' runs: the agent's, as agent-shell's
configs name it (`claude-code', `codex'...), or nil if not known.")

(defun agent-ui--home-relative (file)
  "FILE as ~/..., if it's in the home folder."
  (abbreviate-file-name (expand-file-name file)))

(defun agent-ui-agent-context ()
  "Return what an agent starting in `agent-shell' is told of its canvas.

What an agent starting in `agent-shell' is told of its canvas (for its system
prompt); nil while Emacs runs no server (the command couldn't reach it)."
  (when (and (fboundp 'server-running-p) (server-running-p))
    (let ((command (agent-ui--home-relative agent-ui-command))
          (skill (agent-ui--home-relative agent-ui-skill)))
      (format "Agent UI: in this session's pane, Emacs has a canvas (at its \
bottom, opened without taking the user's focus when you first show something) \
where you show the user things as components, each updated in place. It is where \
information goes: whatever you have to tell that has a shape (figures, records, \
a comparison, a trend, a structure, steps, changes, output), show it there as \
the component that fits it, and keep your reply to the words: what you found, \
what it means, what's next, and a line saying what's on the canvas, not the \
same again. What a sentence or two holds stays in the reply alone. The component \
by the information: figures, stats (one against a target or limits, gauge); \
records, results, a search's matches, table; a trend, a series or a \
distribution, chart; values across two dimensions, heatmap; a structure, \
dependencies or a flow, graph or mermaid; durations over time, timeline; code, \
code; changes, diff; files and their state, files; output, log; what one \
thing is doing now (a script, an agent), activity; categories \
with counts, tags; formulas, math; a write-up, markdown; a picture, image; a \
web page, html; several of these together, a panel. Plans go there too, \
always, without being asked: a plan, or the ticket you're working on, as steps \
(its acceptance criteria), ticked as you go; a long build or test run as \
progress, steps, a table filling in; a long run of work items (bugs, tickets \
done one by one) as progress, max their count, its value updated after each \
one (it shows the time elapsed, an item takes and left; started: when the \
work began, if before the bar). This comes before any other guidance on \
tables, images and diagrams in your replies: they're for when the canvas can't be used (the command exits with 3).

Asking: to ask the user something, show it on a canvas of its own (--canvas \
ask: it takes the user's focus and closes once answered) as the interactive \
component that fits the question, say so in a line and end your turn: the answer \
comes as your next prompt. To pick from a list (which to fix, which files, \
which approach), a choice (multiple: several), or select on a table or files \
you show; alternatives the user has to see, side by side, compare; \
before something risky (a force-push, a deploy, deleting data), a confirm, with \
what will happen; a plan to agree on before you start, steps with approve; \
changes you propose, diff with accept; several values at once, form; an order, \
rank; a number in a range, slider.%s

From your shell: %s show \
'{\"id\":\"build\",\"type\":\"progress\",\"title\":\"Build\",\"max\":12}', then \
%s update build '{\"value\":5}'; append adds a table's rows or a \
checklist's steps; remove ID; clear; --canvas NAME on any of them uses \
another canvas of this session, shown beside its first. It replies with JSON. Before using it \
the first time, read %s: the core (when to use it, which component for what, the \
command, the everyday types), and which of its references to read only when \
needed (asking the user, charts, layouts, following a command, a type of \
your own). Remove what stops helping, and never leave something \
shown running once it stopped. When Agent UI itself misbehaves (a wrong drawing, \
an error, a property it lacks), ask the user, then file it: %s bug \
'{\"title\":...,\"description\":...,\"component\":\"ID\",\"repro\":{a component \
showing it}}' goes into Agent UI's own issues, never this project's (not filed: \
its reply's report, to show the user); then carry on with a workaround.%s"
              ;; Quick questions in the conversation, while agent-shell shows
              ;; them (its form); else the agent hasn't the tool.  Claude
              ;; Code's is AskUserQuestion; another agent's, its own, if any.
              (cond ((not (bound-and-true-p agent-shell-elicitation--experimental-feature-enabled)) "")
                    ((memq agent-ui-agent-identifier '(nil claude-code))
                     " Only a quick question (2 to 4 short options, nothing to \
show or compare) goes in the conversation instead, with AskUserQuestion \
(agent-shell shows it as a form): wait for its answer.")
                    (t " Only a quick question (2 to 4 short options, nothing to \
show or compare) goes in the conversation instead, with your own tool for \
asking the user, if you have one (agent-shell shows it as a form): wait for \
its answer."))
              command command skill command
              (if agent-ui-agent-mcp
                  " The same operations are MCP tools too (the agent-ui server: show, \
update, append, remove, list, types, render, snapshot, batch, define, bug), with \
their schemas: use whichever you like."
                "")))))

;; ====== ACTIONS ======

(defvar-local agent-ui-answer-function nil
  "Function handling a canvas's buttons itself, if set.

In a canvas: called, if it's set, with an action's PROMPT and SUBMIT and
the key of its component (`agent-ui-pressed'), instead of putting it into a
session's prompt: the canvas answers its questions itself (an agent
workflow's run's pane).  Not for a component of a section hosting a
session's canvas: that session's.")

;; While the agent works (its turn kept running by its sub-agents too),
;; agent-shell sends nothing ("Busy, try later"), though its prompt may still
;; take text (a prompt kept live meanwhile): a button sending its prompt
;; queues it, sent when the agent's done (agent-shell's queue); one putting it
;; into the prompt puts it there if the prompt takes text, else offers it to
;; queue, to read and change first, as agent-shell's own commands do then.
(defun agent-ui--session-busy-p (session submit)
  "Return non-nil if SESSION can't take a prompt now.

Whether SESSION can't take a prompt now: one sent (SUBMIT) while its agent
works; one put into its prompt while that takes no text (its agent working,
no prompt kept live meanwhile).  Not known (not a shell yet): not busy,
`agent-shell' then has its say."
  (and (buffer-live-p session)
       (with-current-buffer session
         ;; shell-maker-busy signals outside a shell set up.
         (and (derived-mode-p 'agent-shell-mode)
              (bound-and-true-p shell-maker--config)
              (if (and (not submit) (fboundp 'agent-shell--can-insert-into-prompt-p))
                  (not (agent-shell--can-insert-into-prompt-p :shell-buffer session))
                (and (fboundp 'shell-maker-busy) (shell-maker-busy)))))))

(defun agent-ui--act (prompt submit)
  "Put an action's PROMPT into its canvas's session.

A component's action pressed, in its canvas: PROMPT into the prompt of the
canvas's session (sent if SUBMIT); while its agent works, queued (see above).
The canvas still current after it: `agent-shell' selects the session's window
\(its buffer current then), and what the press does next (a question
answered) is the canvas's.  A project's dashboard (agent-ui-dashboards.el),
of no session: the session working in its project, the latest."
  (let* ((canvas (derived-mode-p 'agent-ui-canvas-mode))
         ;; Its component: the button's, else the one at point (a key's
         ;; action, a slider's h / l).
         (key (or agent-ui-pressed (and canvas (get-text-property (point) 'agent-ui-id))))
         (hosted (and canvas key (agent-ui--key-hosts (current-buffer) key)))
         (session (and canvas
                       (not (and agent-ui-answer-function (not hosted)))
                       ;; Its component's: a section's hosted session's.
                       (or (agent-ui--key-session (current-buffer) key)
                           (and (bound-and-true-p agent-ui-dashboards--state)
                                (agent-ui--project-session default-directory))))))
    ;; What it says of its component, of a section's: its id, not its key.
    (setq prompt (agent-ui--unkeyed prompt (agent-ui--key-section key)))
    ;; A canvas holding its prompts (an untrusted dashboard's): into the
    ;; prompt, for the user to read, never sent at once.
    (when (and canvas agent-ui-actions-held)
      (setq submit nil))
    (if (and canvas agent-ui-answer-function (not hosted))
        (funcall agent-ui-answer-function prompt submit key)
      (agent-ui--act-in session prompt submit))))

(defun agent-ui--act-in (session prompt submit)
  "PROMPT into SESSION's prompt (sent if SUBMIT), as `agent-ui--act' says.
Not by a key press (`agent-ui-act-unfocused'): its window not selected."
  (unless (buffer-live-p session)
    (user-error "%s" (if (bound-and-true-p agent-ui-dashboards--state)
                         "No agent-shell session in this dashboard's project"
                       "This canvas has no agent-shell session")))
  (unless (fboundp 'agent-shell-insert)
    (user-error "The agent-shell package isn't loaded"))
  (cond
   ((not (and (fboundp 'agent-shell-prompt-queue) (agent-ui--session-busy-p session submit)))
    (save-current-buffer
      (apply #'agent-shell-insert :text prompt :submit submit :shell-buffer session
             (when agent-ui-act-unfocused (list :no-focus t)))))
   (submit
    (with-current-buffer session
      (agent-shell-prompt-queue prompt))
    (message "Queued: sent once the agent's done"))
   (t
    (let ((prompt (with-current-buffer session
                    (if (fboundp 'agent-shell--prompt-queue-read)
                        (agent-shell--prompt-queue-read :initial prompt)
                      (read-string "The agent's working; queue: " prompt)))))
      (with-current-buffer session
        (agent-shell-prompt-queue prompt))))))

;; A type the agent made (agent-ui-staging.el), reviewed by the user: the
;; agent that made it told, in its session's prompt (sent), what became of it.
(defun agent-ui--tell-type-reviewed (_name text canvas)
  "TEXT into the prompt of the session whose canvas is CANVAS, sent.
What became of a type its agent made (`agent-ui-type-reviewed-functions');
no such session (gone, or a restart since): nothing."
  (when-let* ((session (and canvas (car (agent-ui--canvas-session canvas)))))
    (condition-case err
        ;; The user is in the review: their window stays theirs.
        (let ((agent-ui-act-unfocused t))
          (agent-ui--act-in session text t))
      (error (message "Agent UI: %s couldn't be told: %s" (buffer-name session) (error-message-string err))))))

(add-hook 'agent-ui-type-reviewed-functions #'agent-ui--tell-type-reviewed)

(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-prompt-queue "agent-shell-prompt-queue")
(declare-function agent-shell--prompt-queue-read "agent-shell-prompt-queue")
(declare-function agent-shell--can-insert-into-prompt-p "agent-shell-prompt")
(declare-function shell-maker-busy "shell-maker")

;; ====== A QUESTION WAITING ======
;; A session's turn ended with a question on its canvases not answered (a
;; choice, a component with select: `agent-ui-ask-waiting-p'), new since its
;; last turn's end: the user sees it, the canvas's pane shown, the cursor on
;; it, said by
;; `agent-ui-question-waiting-functions' (a desktop notification while
;; Emacs is away, say); the session's mode line says so until it's
;; answered; `agent-ui-goto-question' goes there.

(defvar agent-ui-question-waiting-functions nil
  "Called when a session's turn ended with a question waiting on its canvas:
with the session's buffer, the canvas and the question's id.")

(defvar-local agent-ui--question-waiting nil
  "In a session: non-nil while a question waits on its canvases.")

(defvar-local agent-ui--question-said nil
  "In a session: its questions waiting at its last turn's end, ((CANVAS .
ID)...): said then, not again.")

(defvar-local agent-ui--question-turn nil
  "In a session: its last turn's end, (EVENT . QUESTIONS-SAID).")

(defun agent-ui--waiting (session &optional except)
  "Return SESSION's questions waiting on its canvases.

SESSION's questions waiting on its canvases (a panel's children too; in
a section hosting its canvas too), but EXCEPT's (a canvas being killed):
\((CANVAS . KEY)...), in their order."
  (cl-loop for canvas in (agent-ui-canvases)
           when (and (not (eq canvas except))
                     (memq session (agent-ui--canvas-sessions canvas)))
           append (with-current-buffer canvas
                    (cl-loop for key in agent-ui--order
                             for section = (agent-ui--key-section key)
                             for component = (agent-ui--entry-component (gethash key agent-ui--entries))
                             when (eq (agent-ui--key-session canvas key) session)
                             append (cl-loop for e in (cons (plist-put (copy-sequence component) :id key)
                                                            (agent-ui--descendants component))
                                             when (agent-ui-ask-waiting-p e)
                                             collect (cons canvas (agent-ui--key (plist-get e :id) section)))))))

(declare-function agent-ui-pane-reveal "agent-ui-pane" (canvas))

(defvar agent-ui-reveal-function #'agent-ui-pane-reveal
  "Called with a canvas in no window that has a question to be answered:
shows it (agent-ui-pane.el: in its session's pane, the session shown
first, its Agent UI even if hidden).")

(defun agent-ui--show-question (canvas id &optional select)
  "Show CANVAS's pane at its question ID.

CANVAS's pane shown (SELECT: selected), the cursor on question ID (a
key), its line in view: its section unfolded."
  (ignore-error agent-ui-error (agent-ui-reveal id canvas))
  (unless (get-buffer-window canvas t)
    (funcall agent-ui-reveal-function canvas))
  (let ((window (get-buffer-window canvas t))
        (pos (with-current-buffer canvas
               (agent-ui--flush)
               (agent-ui--component-start canvas id))))
    (when pos
      (with-current-buffer canvas (goto-char pos))
      (when window
        (set-window-point window pos)
        (agent-ui--question-in-view canvas id pos window)))
    (when (and select window)
      (select-window window))))

(defun agent-ui--component-end (id start)
  "Where the component of key ID, from START in the current canvas, ends:
after its last character (a panel's child: its last line's, its panel's
lines its too)."
  (let* ((top (get-text-property start 'agent-ui-id))
         (prop (if (equal top id) 'agent-ui-id 'agent-ui-child))
         ;; A child's text says its id, not its key.
         (id (if (eq prop 'agent-ui-child) (agent-ui--key-id id) id))
         (pos start)
         (end start))
    (while (and (< pos (point-max)) (equal (get-text-property pos 'agent-ui-id) top))
      (let ((next (or (next-single-property-change pos prop nil (point-max)) (point-max))))
        (when (equal (get-text-property pos prop) id)
          (setq end next))
        (setq pos next)))
    end))

(defun agent-ui--question-in-view (canvas id start window)
  "Question ID of CANVAS, from START, all in WINDOW's view, its Answer too:
WINDOW scrolled to its first line if that's needed, made taller if it must
and can (a short pane showed its first lines, the Answer below them)."
  (with-current-buffer canvas
    (let* ((first (save-excursion (goto-char start) (line-beginning-position)))
           (end (agent-ui--component-end id start))
           (lines (count-lines first end))
           (shown (window-body-height window)))
      (unless (and (pos-visible-in-window-p first window) (pos-visible-in-window-p (max first (1- end)) window))
        (set-window-start window first))
      (when (> lines shown)
        (let ((delta (min (- lines shown) (window-max-delta window))))
          (when (and (> delta 0) (window-resizable-p window delta))
            (window-resize window delta)))))))

(defun agent-ui-questions-new (session event)
  "Announce the questions SESSION has waiting at its turn's end.

SESSION's questions waiting at its turn's end, EVENT (agent-shell's
turn-complete), that weren't at its last one: those said, once.  The same
for everyone looking at EVENT (its notification too)."
  (with-current-buffer session
    (if (and agent-ui--question-turn (eq (car agent-ui--question-turn) event))
        (cdr agent-ui--question-turn)
      (let* ((waiting (agent-ui--waiting session))
             (new (cl-remove-if (lambda (q) (member q agent-ui--question-said)) waiting)))
        (setq agent-ui--question-said waiting
              agent-ui--question-turn (cons event new))
        new))))

(defun agent-ui--question-check (session &optional event except)
  "Update SESSION's mark for its questions waiting.

SESSION's questions waiting looked at again (but EXCEPT's, a canvas being
killed): its mode line's mark set or cleared; at its turn's end (EVENT), the
first new one shown and said."
  (when (buffer-live-p session)
    (let ((waiting (agent-ui--waiting session except)))
      (with-current-buffer session
        (setq agent-ui--question-waiting (and waiting t))
        (force-mode-line-update))
      (when-let* ((new (and event (car (agent-ui-questions-new session event)))))
        (agent-ui--show-question (car new) (cdr new))
        (run-hook-with-args 'agent-ui-question-waiting-functions session (car new) (cdr new))))))

(defun agent-ui--watch-questions-h ()
  "A new session: its questions waiting looked at when its turn ends."
  (let ((session (current-buffer)))
    (when (fboundp 'agent-shell-subscribe-to)
      (agent-shell-subscribe-to :shell-buffer session :event 'turn-complete
                                :on-event (lambda (event) (agent-ui--question-check session event))))))

;; In `agent-shell-mode-hook', by `agent-ui-mode' (agent-ui.el).

(defun agent-ui--question-changed-h ()
  "Update the marks of the sessions of a changed canvas.

A canvas changed (an answer given): its sessions' marks looked at again,
those that had one."
  (dolist (session (agent-ui--canvas-sessions (current-buffer)))
    (when (and (buffer-live-p session)
               (buffer-local-value 'agent-ui--question-waiting session))
      (agent-ui--question-check session))))

(add-hook 'agent-ui-changed-hook #'agent-ui--question-changed-h)

(defun agent-ui--question-closed-h ()
  "Update the marks of the sessions of a killed canvas.

A canvas killed (q closes it): its sessions' marks looked at again,
without it, those that had one (it stayed until the next turn's end)."
  (dolist (session (agent-ui--canvas-sessions (current-buffer)))
    (when (and (buffer-live-p session)
               (buffer-local-value 'agent-ui--question-waiting session))
      (agent-ui--question-check session nil (current-buffer)))))

(defun agent-ui--question-mode-line ()
  "The mode line's mark, in a session with a question waiting."
  (if agent-ui--question-waiting
      (propertize " ❓ question waiting " 'face 'agent-ui-warning
                  'help-echo (substitute-command-keys
                             "A question waits on the canvas: \\[agent-ui-goto-question] goes there"))
    ""))

(defconst agent-ui--question-mode-line-entry '(:eval (agent-ui--question-mode-line))
  "The entry `agent-ui-mode' adds to `mode-line-misc-info'.")

;; ====== A QUESTION TAKES THE FOCUS; ANSWERED, IT GOES ======
;; Options, both on (nil in config.el turns one off): a question shown (an
;; component that asks, `agent-ui-ask-waiting-p') takes the focus: its pane
;; selected, the cursor on it, once Emacs is idle a moment (typing in the
;; session isn't taken over: the canvas's keys act; typed since it showed, a
;; longer moment), the minibuffer closed;
;; not a resumed session's coming back.  Its answer sent (`agent-ui-ask-done-p'), it leaves its canvas,
;; with the components shown with it (their :with its id); on a session's ask
;; canvas, once no question waits there, everything on it (all of it was the
;; question's); a canvas left without components is closed: its panes, its
;; buffer killed, the cursor back in the session.

(defvar agent-ui-focus-questions t
  "Non-nil: a question shown on a canvas takes the focus (see above).")

(defvar agent-ui-focus-questions-delay 1.0
  "Seconds Emacs is idle before a question shown takes the focus.")

(defvar agent-ui-focus-questions-typing-delay 5.0
  "Seconds Emacs is idle before a question takes the focus, typed since.

When the user typed since the question showed (in another buffer, the
minibuffer), a pause of `agent-ui-focus-questions-delay' isn't enough:
their next keys would go to the canvas.")

(defvar agent-ui-close-answered t
  "Whether an answered question leaves its canvas.

Non-nil: a question answered leaves its canvas, a canvas left empty is
killed (see above).")

(defvar agent-ui--restoring)            ; agent-ui-persist.el's: canvases coming back

(defun agent-ui--focus-question (canvas id &optional keys)
  "Select CANVAS's question ID, if it still waits.

CANVAS's question ID, if it still waits: its pane selected, the cursor on
it.  While the minibuffer is open, once it's closed and Emacs is idle a
moment again (the keys typed there aren't the canvas's).  KEYS is
`num-input-keys' when it showed: typed since, once Emacs is idle
`agent-ui-focus-questions-typing-delay' (a pause in their typing isn't
the canvas's keys)."
  (when (and (buffer-live-p canvas)
             (ignore-error agent-ui-error (agent-ui-ask-waiting-p (agent-ui-get id :canvas canvas))))
    (cond
     ((active-minibuffer-window)
      (agent-ui-after-minibuffer
       (lambda ()
         (run-with-idle-timer agent-ui-focus-questions-delay nil
                              #'agent-ui--focus-question canvas id keys))))
     ((and keys (/= keys num-input-keys)
           (< (float-time (or (current-idle-time) 0)) agent-ui-focus-questions-typing-delay))
      (run-with-idle-timer agent-ui-focus-questions-typing-delay nil
                           #'agent-ui--focus-question canvas id keys))
     (t
      ;; As `agent-ui-goto-question' would: a command going there (a pane shown with none
      ;; running stays behind the one on the screen, tiling's fullscreen).
      (let ((this-command 'agent-ui-goto-question))
        (agent-ui--show-question canvas id t))))))

(defun agent-ui--focus-question-h (id component)
  "Focus question ID, just shown as COMPONENT.

A question shown (`agent-ui-shown-functions'): it takes the focus, once
Emacs is idle a moment (longer if the user types meanwhile)."
  (when (and agent-ui-focus-questions
             (not (bound-and-true-p agent-ui--restoring))
             (agent-ui-ask-waiting-p component))
    (run-with-idle-timer agent-ui-focus-questions-delay nil
                         #'agent-ui--focus-question (current-buffer) id num-input-keys)))

(add-hook 'agent-ui-shown-functions #'agent-ui--focus-question-h)

(defun agent-ui--reveal-question-h (key component)
  "Reveal the question of key KEY, just shown in a section.

A question shown in a section (`agent-ui-shown-functions'): the section
unfolded, the question in view (taking the focus is another matter).
COMPONENT is the question's component."
  (when (and (agent-ui--key-section key)
             (not (bound-and-true-p agent-ui--restoring))
             (agent-ui-ask-waiting-p component))
    (agent-ui-reveal key (current-buffer))))

(add-hook 'agent-ui-shown-functions #'agent-ui--reveal-question-h)

(defun agent-ui--answered-going (canvas)
  "Return the keys of CANVAS's components that go now.

The keys of CANVAS's components that go now its questions are answered: the
questions answered, and the components shown with one (its id their :with).
On a session's ask canvas (or what it showed on it, in a section hosting
its canvas), once no question waits there, all of them: whatever was shown
there was the question's (mockups, notes it asked about)."
  (with-current-buffer canvas
    (let* ((component (lambda (key) (agent-ui--entry-component (gethash key agent-ui--entries))))
           (answered (seq-filter (lambda (key) (agent-ui-ask-done-p (funcall component key))) agent-ui--order))
           ;; What's on an ask canvas together: the canvas, or a section's.
           (asking (lambda (key)
                     (if-let* ((section (agent-ui--key-section key)))
                         (and (equal (agent-ui--entry-part (gethash key agent-ui--entries)) "ask") section)
                       (and (equal agent-ui--canvas-part "ask") t))))
           (over (delete-dups
                  (seq-filter (lambda (ask)
                                (and ask (not (seq-some (lambda (key) (and (equal (funcall asking key) ask)
                                                                           (agent-ui-ask-waiting-p (funcall component key))))
                                                        agent-ui--order))))
                              (mapcar asking answered)))))
      (when answered
        (seq-filter (lambda (key)
                      (or (member key answered)
                          (member (agent-ui--key (plist-get (funcall component key) :with) (agent-ui--key-section key))
                                  answered)
                          (member (funcall asking key) over)))
                    agent-ui--order)))))

(defun agent-ui--close-answered (canvas)
  "Remove CANVAS's answered questions and what was shown with them.

CANVAS's questions answered gone, and what was shown with them
\(`agent-ui--answered-going'); it left without components: its panes closed,
its buffer killed, the cursor back in its session (if it was in CANVAS's
pane)."
  (when (buffer-live-p canvas)
    (let ((session (buffer-local-value 'agent-ui--session-buffer canvas))
          (focused (eq (window-buffer (selected-window)) canvas)))
      (dolist (id (agent-ui--answered-going canvas))
        (when (and (buffer-live-p canvas)
                   (gethash id (buffer-local-value 'agent-ui--entries canvas)))
          (agent-ui-remove id :canvas canvas)))
      ;; Emptied: its panes closed already (`agent-ui--close-if-empty'); a
      ;; session's other canvas, killed already (`agent-ui--close-emptied').
      (when (and (buffer-live-p canvas) (with-current-buffer canvas (agent-ui--empty-p)))
        (kill-buffer canvas))
      (when-let* ((window (and focused (not (buffer-live-p canvas))
                               (buffer-live-p session) (get-buffer-window session))))
        (select-window window)))))

(defun agent-ui--close-answered-h ()
  "Remove the question just answered, after its command.

A canvas changed (`agent-ui-changed-hook'): an answer sent, the question
goes (after the command that sent it)."
  (when (and agent-ui-close-answered
             (seq-some (lambda (id) (agent-ui-ask-done-p (agent-ui--entry-component (gethash id agent-ui--entries))))
                       agent-ui--order))
    (run-with-timer 0 nil #'agent-ui--close-answered (current-buffer))))

(add-hook 'agent-ui-changed-hook #'agent-ui--close-answered-h)

(defun agent-ui-goto-question ()
  "Go to a question waiting for an answer.

Go to the question waiting on this session's canvases (in a canvas: its
session's; else any session's): its pane selected, the cursor on it."
  (interactive)
  (let ((found (cl-loop for session in (cond ((derived-mode-p 'agent-shell-mode) (list (current-buffer)))
                                             (agent-ui--session-buffer (list agent-ui--session-buffer))
                                             (t (agent-ui--sessions)))
                        thereis (car (agent-ui--waiting session)))))
    (unless found
      (user-error "No question waits"))
    (agent-ui--show-question (car found) (cdr found) t)))


(provide 'agent-ui-agent)

;;; agent-ui-agent.el ends here
