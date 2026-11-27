;;; agent-ui-mcp.el --- Agent UI as an MCP server  -*- lexical-binding: t; -*-

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

;; Agent UI's operations as MCP tools, for an agent to discover with their
;; schemas (see the README).  A batch Emacs runs it, started by the agent for
;; its session (agent-shell's `agent-shell-mcp-servers', agent-ui.el):
;;
;;   `emacs' --batch -Q -l agent-ui-mcp.el -f agent-ui-mcp-main
;;
;; It speaks MCP over stdio (JSON-RPC, a message a line) and does each tool
;; call through bin/agent-ui, beside it: the same operations, replies and
;; errors as the command line, reaching the user's Emacs with emacsclient.
;; AGENT_UI_SESSION says whose canvas; AGENT_UI_DIR the agent's directory
;; (its files', its sources'), else where it was started.  Tools' descriptions
;; carry the component types, asked of the user's Emacs (agent-ui types).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst agent-ui-mcp-command
  (expand-file-name "bin/agent-ui" (file-name-directory (or load-file-name buffer-file-name)))
  "The command line, bin/agent-ui: what each tool call runs.")

(defconst agent-ui-mcp-version "2025-06-18"
  "The MCP version it speaks (or the client's, if it asks for another).")

;; ====== THE TOOLS ======

(defconst agent-ui-mcp--canvas-schema
  '(:type "string" :description "Optional: another canvas of your session, by name (\"tests\"), shown beside its first; without it, your session's canvas")
  "The canvas argument's schema.")

(defconst agent-ui-mcp--dashboard-schema
  '(:type "string" :description "Optional: one of the project's dashboards, open (agent-ui open NAME), by name: its canvas instead")
  "The dashboard argument's schema.")

(defun agent-ui-mcp--with-canvas (tool)
  "TOOL (a tools/list entry) taking a canvas argument too, and a dashboard."
  (let* ((schema (copy-sequence (plist-get tool :inputSchema)))
         (properties (copy-sequence (plist-get schema :properties))))
    (plist-put tool :inputSchema
               (plist-put schema :properties
                          (plist-put (plist-put properties :canvas agent-ui-mcp--canvas-schema)
                                     :dashboard agent-ui-mcp--dashboard-schema)))))

(defconst agent-ui-mcp--component-schema
  '(:type "object"
    :description "A component: \"type\" (one of the types below), \"id\" (yours, to change it later), an optional \"title\", the type's properties, optionally a \"source\" (a command, file or poll it follows), \"actions\" (buttons putting a prompt into your session's prompt: [{\"label\", \"prompt\", \"submit\"}]) on steps, todo and progress, \"close\" (finished well, it closes itself 10 s after: seconds, or false to keep it), and \"with\" (the id of the question it's shown with: it goes when that's answered)."
    :properties (:type (:type "string") :id (:type "string") :title (:type "string")
                 :source (:type "object"))
    :required ["type"]
    :additionalProperties t)
  "A component's schema: open, each type's properties in the description.")

(defun agent-ui-mcp--types-text ()
  "The component types, a line each (name: properties), from the user's Emacs;
nil if it can't be reached."
  (let ((reply (agent-ui-mcp--run (list "types"))))
    (when (eq (plist-get reply :ok) t)
      (mapconcat (lambda (type)
                   (format "- %s: %s. Properties: %s."
                           (plist-get type :name)
                           (car (split-string (replace-regexp-in-string "\n" " " (plist-get type :doc))
                                              "\\. "))
                           (mapconcat (lambda (p) (format "%s (%s)" (plist-get p :name) (plist-get p :kind)))
                                      (plist-get type :props) ", ")))
                 (plist-get reply :types) "\n"))))

(defun agent-ui-mcp--tools ()
  "The tools, as tools/list gives them."
  (let* ((types (agent-ui-mcp--types-text))
         (id '(:type "string" :description "The component's id"))
         (patch '(:type "object" :description "The properties to change (null: back to the default)"
                  :additionalProperties t)))
    (vconcat
     (mapcar
      (lambda (tool)
        (if (member (plist-get tool :name) '("types" "define" "check" "dashboards" "open" "doctor"))
            tool
          (agent-ui-mcp--with-canvas tool)))
      (list
      (list :name "show"
            :description (concat "Show a component on the canvas in your session's pane (the user's Emacs); one with its id there already is replaced in place. For what changes over time or should stay in view: progress, a checklist, test results, a chart. Types:\n"
                                 (or types "(ask with the types tool)"))
            :inputSchema (list :type "object" :properties (list :component agent-ui-mcp--component-schema)
                               :required ["component"]))
      (list :name "update" :description "Change some of a component's properties, in place."
            :inputSchema (list :type "object" :properties (list :id id :patch patch) :required ["id" "patch"]))
      (list :name "append" :description "Add to a component's lists: a table's rows (by its key column: replaced), a checklist's steps (by name: changed), a chart's values."
            :inputSchema (list :type "object" :properties (list :id id :patch patch) :required ["id" "patch"]))
      (list :name "remove" :description "Remove a component."
            :inputSchema (list :type "object" :properties (list :id id) :required ["id"]))
      (list :name "clear" :description "Remove every component of the canvas."
            :inputSchema '(:type "object"))
      (list :name "title" :description "Give the canvas a title: its pane's bar and its tab say it, whatever it shows (a lone panel with a title: that title, as ever). For a canvas holding several things, which its bar would only call Canvas, or its name. \"\" takes it away; clearing the canvas too."
            :inputSchema '(:type "object"
                           :properties (:title (:type "string" :description "The title (\"\": none)"))
                           :required ["title"]))
      (list :name "list" :description "The canvas's components: ids, types, their sources' state."
            :inputSchema '(:type "object"))
      (list :name "get" :description "What the canvas (or an open dashboard: its dashboard argument) shows, as data: its components, or one, with their properties and values. Read dashboards so, never by a snapshot. changed: only those changed since your last read (and removed: those gone). A dashboard's reply says when it last fetched; one hidden with old data is fetched first."
            :inputSchema (list :type "object"
                               :properties (list :id '(:type "string" :description "One component only")
                                                 :changed '(:type "boolean" :description "Only what changed since your last read"))))
      (list :name "types" :description "The component types: their properties, an example each."
            :inputSchema '(:type "object" :properties (:type (:type "string" :description "One type only"))))
      (list :name "render" :description "A component drawn as text, as the canvas would, nothing shown: to see what it looks like."
            :inputSchema (list :type "object" :properties (list :component agent-ui-mcp--component-schema)
                               :required ["component"]))
      (list :name "snapshot" :description "A component as an image (SVG) in .agent-shell/images/: the reply's markdown, put in your reply, shows it in the conversation."
            :inputSchema (list :type "object" :properties (list :id id) :required ["id"]))
      (list :name "batch" :description "Several operations at once: [{\"op\": \"show\", ...component}, {\"op\": \"update\", \"id\": ..., ...patch}, {\"op\": \"append\", ...}, {\"op\": \"remove\", \"id\": ...}, {\"op\": \"title\", \"title\": ...}]."
            :inputSchema '(:type "object" :properties (:operations (:type "array" :items (:type "object")))
                           :required ["operations"]))
      (list :name "bug" :description "A bug in Agent UI itself (a wrong drawing, an error, a property missing), filed in its own issues, not this project's: ask the user first, then carry on with a workaround. Its title and description; what you expected and the workaround used; the component on the canvas showing it (its JSON and drawing go with it); a repro, a component with neutral data showing it (drawn as text). Replies with the issue; a similar open bug gets the report as a note (new: true files it anyway). Not filed (no issues set up): the reply's report, written, for the user to report by hand."
            :inputSchema '(:type "object"
                           :properties (:title (:type "string") :description (:type "string")
                                        :expected (:type "string") :workaround (:type "string")
                                        :component (:type "string" :description "The id of the component on the canvas showing it")
                                        :repro (:type "object" :description "A component showing it, with neutral data")
                                        :new (:type "boolean" :description "File it even if a similar bug is open"))
                           :required ["title" "description"]))
      (list :name "dashboards" :description "The project's dashboards (PROJECT/.agent-ui/dashboards/NAME.el, kept in its repository, opened on demand, their data fetched afresh): their names, which are open. See the agent-ui skill's references/dashboards.md."
            :inputSchema '(:type "object"))
      (list :name "open" :description "Open one of the project's dashboards in the user's Emacs, in a pane of its own (open already: shown). Its code, if the user hasn't let it run yet, waits until they select the dashboard and are asked (the reply's trusted). The other tools work on it with their dashboard argument."
            :inputSchema '(:type "object"
                           :properties (:name (:type "string" :description "The dashboard's name"))
                           :required ["name"]))
      (list :name "check" :description "A project dashboard's file checked, nothing shown, nothing run: PROJECT/.agent-ui/dashboards/NAME.el (or a file ending .el), its :ui checked as show checks a component, its code compiled (errors refuse it; warnings), its calls that wait (blocking: Emacs frozen while they run) found. See the agent-ui skill's references/dashboards.md."
            :inputSchema '(:type "object"
                           :properties (:name (:type "string" :description "The dashboard's name (its file's, without .el), or its file"))
                           :required ["name"]))
      (list :name "doctor" :description "Is everything Agent UI needs here? Its checks, the command's side (an emacsclient, a server answering, your session) and the user's Emacs's: Emacs and the packages it needs at their versions, the package's files, Emacs's server, agent-ui-mode, its MCP server, and the tools some components use (mmdc for mermaid, MathJax or LaTeX for math, curl, rsvg-convert, SVG support). Each check's status (ok, warn, fail), what it found and its fix. Run it when the canvas can't be reached or a component says something is missing, and tell the user the fixes."
            :inputSchema '(:type "object"))
      (list :name "define" :description "A type of your own: Emacs Lisp code with one agent-ui-define and its definitions, each named agent-ui-NAME-... (see the agent-ui skill). Its code is checked and staged, nothing of it run: the user reviews it, and keeping it runs it (compiled, loaded, its example drawn). You're told in your prompt once they keep or discard it; don't show it until then."
            :inputSchema '(:type "object" :properties (:code (:type "string")) :required ["code"])))))))

;; ====== DOING A CALL ======

(defun agent-ui-mcp--json (value)
  "VALUE as JSON text (decoded: `json-serialize' gives UTF-8 bytes)."
  (decode-coding-string (json-serialize value :null-object :null :false-object :false) 'utf-8))

(defun agent-ui-mcp--run (args &optional input)
  "Run bin/agent-ui with ARGS, in the agent's directory, INPUT on its stdin.
INPUT, the JSON, goes there, not as an argument: an argument has a size
limit, a large component's JSON over it.  Its reply, parsed (or an error
reply if it said nothing readable)."
  (let ((default-directory (file-name-as-directory
                            (or (getenv "AGENT_UI_DIR") default-directory))))
    (with-temp-buffer
      (let* ((status (let ((coding-system-for-read 'utf-8) (coding-system-for-write 'utf-8))
                       (if input
                           (apply #'call-process-region input nil agent-ui-mcp-command
                                  nil (list t nil) nil args)
                         (apply #'call-process agent-ui-mcp-command nil (list t nil) nil args))))
             (text (string-trim (buffer-string)))
             (text (if (multibyte-string-p text) text (decode-coding-string text 'utf-8))))
        (condition-case nil
            ;; null kept null: written again, nil would be {}.
            (json-parse-string text :object-type 'plist :null-object :null :false-object :false)
          (error (list :ok :false :error (format "bin/agent-ui (exit %s): %s" status text))))))))

(defun agent-ui-mcp--call (name arguments)
  "Tool NAME with ARGUMENTS (a plist): (ERROR-P . TEXT)."
  (cl-flet ((arg (key) (plist-get arguments key))
            (json (value) (agent-ui-mcp--json value)))
    (let* ((canvas (let ((c (arg :canvas))) (and (stringp c) (not (string-empty-p c)) c)))
           (dashboard (let ((d (arg :dashboard))) (and (stringp d) (not (string-empty-p d)) d)))
           ;; The JSON on stdin, the rest as arguments.
           (input (pcase name
                    ((or "show" "render") (json (arg :component)))
                    ((or "update" "append") (json (or (arg :patch) (make-hash-table))))
                    ("batch" (json (or (arg :operations) [])))
                    ;; The bug as given, but its canvas (an argument of its own).
                    ("bug" (json (cl-loop for (k v) on arguments by #'cddr
                                          unless (memq k '(:canvas :dashboard)) append (list k v))))))
           (args (pcase name
                   ((or "show" "render" "batch" "bug") (list name))
                   ((or "update" "append") (list name (or (arg :id) "")))
                   ("remove" (list "remove" (or (arg :id) "")))
                   ("snapshot" (list "snapshot" (or (arg :id) "")))
                   ("check" (list "check" (or (arg :name) "")))
                   ("dashboards" (list "dashboards"))
                   ("doctor" (list "doctor"))
                   ("open" (list "open" (or (arg :name) "")))
                   ("clear" (list "clear"))
                   ;; None: none given, the command's usage error.
                   ("title" (cons "title" (let ((title (arg :title))) (and (stringp title) (list title)))))
                   ("list" (list "list"))
                   ("get" (append (list "get") (and (arg :id) (list (arg :id)))
                                  (and (eq (arg :changed) t) (list "--changed"))))
                   ("types" (if (arg :type) (list "types" (arg :type)) (list "types")))))
           (reply
            (cond
             (args
              ;; Another canvas of the session, if it names one.
              (agent-ui-mcp--run (append args
                                         (when (and canvas (not (member name '("types" "doctor"))))
                                           (list "--canvas" canvas))
                                         ;; A project's dashboard, open.
                                         (when (and dashboard (not (member name '("types" "check" "dashboards" "open" "doctor"))))
                                           (list "--dashboard" dashboard)))
                                 input))
             ((equal name "define")
              (let ((file (make-temp-file "agent-ui-type-" nil ".el")))
                (unwind-protect
                    (progn
                      (let ((coding-system-for-write 'utf-8))
                        (write-region (or (arg :code) "") nil file nil 'silent))
                      (agent-ui-mcp--run (list "define" file)))
                  (delete-file file))))
             (t (list :ok :false :error (format "unknown tool %s" name))))))
      (cons (not (eq (plist-get reply :ok) t)) (json reply)))))

;; ====== THE PROTOCOL ======

(defun agent-ui-mcp--send (message)
  "Print MESSAGE as JSON on a line of its own."
  (princ (agent-ui-mcp--json message))
  (terpri))

(defun agent-ui-mcp--answer (id result)
  "Answer the request ID with RESULT."
  (agent-ui-mcp--send (list :jsonrpc "2.0" :id id :result result)))

(defun agent-ui-mcp--fail (id code message)
  "Answer the request ID with an error of CODE and MESSAGE."
  (agent-ui-mcp--send (list :jsonrpc "2.0" :id id :error (list :code code :message message))))

(defun agent-ui-mcp-handle (message)
  "Answer MESSAGE (a JSON-RPC request or notification, parsed)."
  (let ((id (plist-get message :id))
        (method (plist-get message :method))
        (params (plist-get message :params)))
    (pcase method
      ("initialize"
       (agent-ui-mcp--answer
        id (list :protocolVersion (or (plist-get params :protocolVersion) agent-ui-mcp-version)
                 :capabilities '(:tools (:listChanged :false))
                 :serverInfo '(:name "agent-ui" :version "1.0")
                 :instructions "Show the user information in Emacs, on a canvas in your session's pane, as components updated in place: whatever you have to tell that has a shape (figures, records, a comparison, a trend, a structure, a plan, changes, output) goes there as the component that fits it, your reply keeping the words and saying what's on the canvas. Ask there too, beyond a quick question: the interactive component that fits it (choice, compare, confirm, form, rank, slider, select), on a canvas of its own, then end your turn. The agent-ui skill has the details: skills/agent-ui/SKILL.md first, then only the reference it points to for your task. When Agent UI itself misbehaves (a wrong drawing, an error, a property it lacks), ask the user, then file it with the bug tool: it goes into Agent UI's own issues, never the project's; then carry on with a workaround.")))
      ("ping" (agent-ui-mcp--answer id (make-hash-table)))
      ("tools/list" (agent-ui-mcp--answer id (list :tools (agent-ui-mcp--tools))))
      ("tools/call"
       (pcase-let ((`(,error-p . ,text) (agent-ui-mcp--call (plist-get params :name)
                                                            (plist-get params :arguments))))
         (agent-ui-mcp--answer id (list :content (vector (list :type "text" :text text))
                                        :isError (if error-p t :false)))))
      ;; Notifications (no id): nothing to say.
      ((guard (memq id '(nil :null))))
      (_ (agent-ui-mcp--fail id -32601 (format "Method not found: %s" method))))))

(defun agent-ui-mcp-main ()
  "Serve MCP on stdin and stdout until stdin ends."
  ;; UTF-8 both ways, whatever the locale.
  (set-language-environment "UTF-8")
  (prefer-coding-system 'utf-8)
  (setq locale-coding-system 'utf-8)
  (set-terminal-coding-system 'utf-8)
  (set-keyboard-coding-system 'utf-8)
  (let ((coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8))
    (catch 'done
      (while t
        (let ((line (condition-case nil
                        (read-from-minibuffer "")
                      (error (throw 'done nil)))))
          (unless (string-blank-p line)
            ;; Arrays as vectors, null as :null: sent on as they came.
            (let ((message (condition-case nil
                               (json-parse-string line :object-type 'plist :null-object :null
                                                  :false-object :false)
                             (error nil))))
              (if (not message)
                  (agent-ui-mcp--fail :null -32700 "Parse error")
                (condition-case err
                    (agent-ui-mcp-handle message)
                  (error (when (plist-get message :id)
                           (agent-ui-mcp--fail (plist-get message :id) -32603
                                               (error-message-string err)))))))))))
    (kill-emacs 0)))

(provide 'agent-ui-mcp)

;;; agent-ui-mcp.el ends here
