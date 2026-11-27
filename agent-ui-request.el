;;; agent-ui-request.el --- Requests from the command line, through emacsclient  -*- lexical-binding: t; -*-

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

;; Agent UI's way in for the command line (bin/agent-ui): a request in a
;; folder, its reply written there.
;;
;; bin/agent-ui makes a folder holding:
;;   request   lines: the operation, an id, the agent's session
;;             ($AGENT_UI_SESSION), its working directory, its options
;;             (render's ansi), the session's other canvas it's for
;;             (--canvas NAME), the project's open dashboard it's for
;;             (--dashboard NAME), each empty when none
;;   payload   the agent's JSON, as it gave it (absent if none)
;; and runs emacsclient --eval '(agent-ui-request "FOLDER")'.  Emacs writes
;; reply (JSON: {"ok": true, ...} or {"ok": false, "error": "..."}) there,
;; which the script prints.  No JSON is quoted into Lisp, whatever it holds.
;;
;; A session has its canvas and, named, others ("SESSION / tests"), tabs of
;; its pane: --canvas NAME, or "canvas": NAME in the JSON (a component's, a
;; change's, a batch's operation's), says which.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'agent-ui-doctor)

(declare-function agent-ui-bug-reply "agent-ui-bug")
(declare-function agent-ui-open-dashboard "agent-ui-dashboards")
(declare-function agent-ui-dashboard-canvas "agent-ui-dashboards")
(declare-function agent-ui-dashboard-check "agent-ui-dashboards")
(declare-function agent-ui-dashboard-fetched "agent-ui-dashboards")
(declare-function agent-ui-dashboard-file "agent-ui-dashboards")
(declare-function agent-ui-dashboard-read "agent-ui-dashboards")
(declare-function agent-ui-dashboard-trusted-p "agent-ui-dashboards")
(declare-function agent-ui-dashboards "agent-ui-dashboards")
(declare-function agent-ui-dashboards--code-p "agent-ui-dashboards")
(declare-function agent-ui-snapshot "agent-ui-snapshot")
(declare-function agent-ui-stage "agent-ui-staging")
(declare-function agent-ui-dashboards--name "agent-ui-dashboards" (cl-x) t)
(declare-function agent-ui-dashboards--root "agent-ui-dashboards" (cl-x) t)
(declare-function agent-ui-dashboards--file "agent-ui-dashboards" (cl-x) t)

;; ====== VARIABLES ======

(defcustom agent-ui-command (expand-file-name "bin/agent-ui" agent-ui-directory)
  "The command line agents run, bin/agent-ui (as the agent is told)."
  :type 'file :group 'agent-ui)

(declare-function agent-ui-session-canvas "agent-ui-agent" (session cwd))

(defvar agent-ui-canvas-function #'agent-ui-session-canvas
  "Function finding the canvas a request is for.
Called with the agent's session (a string, or nil) and its working
directory (or nil); returns the canvas its request is for (a buffer, or a
canvas's name).  agent-ui-agent.el finds agent-shell's sessions.")

(defvar agent-ui--request-options nil
  "While a request is answered: its options (strings: \"ansi\").")

(defvar agent-ui--request-canvas nil
  "While a request is answered: its session's canvas.
Its other canvases' names start with it.")

(defvar agent-ui--request-cwd nil
  "While a request is answered: the agent's directory (its sources' default).")

(defconst agent-ui-operations
  '("show" "update" "append" "remove" "clear" "list" "get" "types" "batch" "render" "define" "snapshot" "bug" "check"
    "dashboards" "open" "doctor")
  "What bin/agent-ui does.")

;; ====== THE CANVAS ======

(defun agent-ui-request-canvas (session _cwd)
  "The canvas for an agent's request: its SESSION's, else the default."
  (if (and session (not (string-empty-p session)))
      session
    agent-ui-default-canvas))

;; ====== OPERATIONS ======

(defun agent-ui--payload-object (payload what)
  "PAYLOAD if it's a JSON object (nil: {}, or null); else an error for WHAT."
  (unless (or (null payload) (agent-ui--plist-p payload))
    (agent-ui--fail "%s: give a JSON object, not %s" what (agent-ui--show-value payload)))
  payload)

(defun agent-ui--take-canvas (payload)
  "Return PAYLOAD's \"canvas\" taken out, as (NAME . PAYLOAD without it).
Only if it's an object with one; else (nil . PAYLOAD)."
  (if (and (agent-ui--plist-p payload) (plist-member payload :canvas))
      (let ((name (plist-get payload :canvas)))
        (unless (or (null name) (stringp name))
          (agent-ui--fail "canvas: give a name, not %s" (agent-ui--show-value name)))
        (cons name (agent-ui--plist-delete payload :canvas)))
    (cons nil payload)))

(defun agent-ui--need-id (op id)
  "Return ID, a component's id; for OP, an error if it's missing."
  (when (or (null id) (string-empty-p id))
    (agent-ui--fail "%s: which component? give its id" op))
  (agent-ui--agent-id id))

(defun agent-ui--agent-id (id)
  "Return ID, a component's id an agent gave.
An error if it has a / (a key, of a component in a section of its
canvas: see agent-ui-canvas.el)."
  (when (and (stringp id) (string-search "/" id))
    (agent-ui--fail "an id is letters, digits, -, _ or ., not %s" (agent-ui--show-value id)))
  id)

(defun agent-ui--canvas-label (canvas)
  "Return CANVAS as the agent names it.
Its name as given (its session's, shown in another's section:
still its own), else its buffer's canvas's."
  (if (stringp canvas)
      canvas
    (buffer-local-value 'agent-ui--canvas-name (agent-ui--buffer canvas))))

(defun agent-ui-do (op id payload canvas)
  "Do OP (one of `agent-ui-operations', a string) on CANVAS.
ID and PAYLOAD (parsed JSON) are as OP needs; returns the reply, a
plist for `agent-ui-to-json'.  Signals `agent-ui-error' if it can't."
  (agent-ui--agent-id id)
  (pcase op
    ("show"
     (let ((component (agent-ui--payload-object payload "show")))
       (when (and id (not (string-empty-p id)))
         (setq component (plist-put (copy-sequence component) :id id)))
       ;; Its sources (a panel's children's too) run in the agent's directory
       ;; (`agent-ui-file-directory'), unless they say.
       (let* ((id (agent-ui-show component :canvas canvas))
              (source (and (fboundp 'agent-ui-source-status) (agent-ui-source-status id :canvas canvas)))
              (log (plist-get source :log))
              (hidden (buffer-local-value 'agent-ui--hidden (agent-ui--buffer canvas))))
         (append (list :ok t :id id)
                 ;; A link to it, for the agent's reply (agent-ui-snapshot.el).
                 (when (fboundp 'agent-ui-link)
                   (list :link (agent-ui-link (agent-ui--canvas-label canvas) id)))
                 (when log (list :log log))
                 ;; Shown, its source not run (its dir missing): why.
                 (when (plist-get source :error) (list :source source))
                 ;; Shown, but its pane couldn't open: for the agent to say.
                 (when hidden
                   (list :hidden (format "the canvas's pane couldn't open (%s): it opens at its next change, once there's room"
                                         hidden)))))))
    ("update"
     (list :ok t :id (agent-ui-update (agent-ui--need-id op (or id (plist-get payload :id)))
                                      (agent-ui--payload-object payload "update")
                                      :canvas canvas)))
    ("append"
     (list :ok t :id (agent-ui-append (agent-ui--need-id op (or id (plist-get payload :id)))
                                      (agent-ui--payload-object payload "append")
                                      :canvas canvas)))
    ("remove"
     (list :ok t :id (agent-ui-remove (agent-ui--need-id op (or id (plist-get payload :id)))
                                      :canvas canvas)))
    ("clear"
     (agent-ui-clear :canvas canvas)
     (list :ok t))
    ("list"
     (list :ok t :components
           (vconcat (mapcar (lambda (e)
                              (let ((source (and (fboundp 'agent-ui-source-status)
                                                 (agent-ui-source-status (plist-get e :id) :canvas canvas))))
                                (append e (when source (list :source source)))))
                            (agent-ui-components :canvas canvas)))))
    ;; What it shows, as data: never a picture (see `agent-ui--get').
    ("get" (agent-ui--get id canvas))
    ("render"
     ;; Drawn as text at the canvas's width (its window's, else the default):
     ;; for the agent to see what it draws.
     (let* ((component (agent-ui--payload-object payload "render"))
            (type (agent-ui-type (plist-get component :type)))
            (buffer (and (agent-ui--live-canvas-p canvas) (agent-ui--buffer canvas)))
            (window (and buffer (get-buffer-window buffer t))))
       (agent-ui-check type component)
       (let ((text (agent-ui-render component
                                    (agent-ui-context
                                     :width (if window (agent-ui-window-columns window)
                                              agent-ui-default-width)))))
         ;; --ansi: in its faces' colours, for a terminal.
         (list :ok t :text (if (and (member "ansi" agent-ui--request-options) (fboundp 'agent-ui-ansi))
                               (agent-ui-ansi text)
                             (substring-no-properties text))))))
    ("snapshot"
     (append (list :ok t)
             (agent-ui-snapshot (agent-ui--need-id op id) :canvas canvas :directory agent-ui--request-cwd)))
    ;; The project's dashboards (agent-ui-dashboards.el): which, opening one.
    ("dashboards"
     (list :ok t :dashboards
           (vconcat (mapcar (lambda (name)
                              (list :name name
                                    :open (if (ignore-error agent-ui-error (agent-ui-dashboard-canvas name agent-ui--request-cwd)) t :false)))
                            (agent-ui-dashboards agent-ui--request-cwd)))))
    ("open"
     (when (or (null id) (string-empty-p id))
       (agent-ui--fail "open: which dashboard? agent-ui open NAME%s"
                       (if-let* ((dashboards (agent-ui-dashboards agent-ui--request-cwd)))
                           (format " (this project's: %s)" (string-join dashboards ", "))
                         "")))
     (let* ((canvas (agent-ui-open-dashboard id agent-ui--request-cwd t))
            (file (agent-ui-dashboards--file (buffer-local-value 'agent-ui-dashboards--state canvas))))
       (list :ok t :dashboard id :canvas (buffer-name canvas)
             ;; Not: the user is asked to let its code run, once they
             ;; select it (a dashboard with no code: nothing to ask).
             :trusted (if (or (agent-ui-dashboard-trusted-p file)
                              (let ((read (agent-ui-dashboard-read file)))
                                (not (agent-ui-dashboards--code-p (plist-get read :form) (plist-get read :ui)))))
                          t :false))))
    ;; A project dashboard's file checked, nothing run (agent-ui-dashboards.el).
    ("check"
     (when (or (null id) (string-empty-p id))
       (agent-ui--fail "check: which dashboard? agent-ui check NAME%s"
                       (if-let* ((dashboards (agent-ui-dashboards agent-ui--request-cwd)))
                           (format " (this project's: %s)" (string-join dashboards ", "))
                         "")))
     (agent-ui-dashboard-check (agent-ui-dashboard-file id agent-ui--request-cwd)))
    ;; What Agent UI needs, checked (agent-ui-doctor.el): bin/agent-ui asks
    ;; `agent-ui-doctor-request' itself, with its own checks.
    ("doctor" (agent-ui-doctor-reply))
    ;; A bug in Agent UI itself, filed in its own issues (agent-ui-bug.el).
    ("bug"
     (agent-ui-bug-reply (agent-ui--payload-object payload "bug") canvas))
    ("define"
     (unless (and (stringp payload) (not (string-empty-p (string-trim payload))))
       (agent-ui--fail "define: give a type's code (a file, or on stdin)"))
     (append (list :ok t) (agent-ui-stage payload agent-ui--request-canvas)))
    ("types"
     (let ((catalog (agent-ui-catalog)))
       (when (and id (not (string-empty-p id)))
         (agent-ui-type id)             ; an error naming the types
         (setq catalog (seq-filter (lambda (e) (equal (plist-get e :name) id)) catalog)))
       (list :ok t :types (vconcat catalog))))
    ("batch"
     (unless (and (listp payload) (not (agent-ui--plist-p payload)))
       (agent-ui--fail "batch: give a JSON array of operations, each {\"op\": ..., ...}"))
     (let ((results (mapcar (lambda (item) (agent-ui--batch-item item canvas)) payload)))
       (list :ok (if (cl-every (lambda (r) (eq (plist-get r :ok) t)) results) t :false)
             :results (vconcat results))))
    (_
     (agent-ui--fail "unknown operation %s; operations: %s"
                     (agent-ui--show-value op) (string-join agent-ui-operations ", ")))))

(defun agent-ui--batch-item (item canvas)
  "Do one operation of a batch on CANVAS.
ITEM is {\"op\": OP, ...} with what OP takes \(show: the component;
update, append: the id and the change; remove: the id)."
  (condition-case err
      (let* ((item (agent-ui--payload-object item "batch"))
             (op (plist-get item :op))
             (taken (agent-ui--take-canvas (agent-ui--plist-delete item :op)))
             (rest (cdr taken))
             ;; Its own canvas, if it names one: its session's other.
             (canvas (if (and (car taken) agent-ui--request-canvas)
                         (agent-ui-sub-canvas agent-ui--request-canvas (car taken))
                       canvas)))
        (cond
         ((not (stringp op))
          (agent-ui--fail "batch: each operation has \"op\": show, update, append or remove"))
         ((member op '("batch" "types" "list" "get" "render" "define" "snapshot" "bug" "check" "dashboards" "open"
                       "doctor"))
          (agent-ui--fail "batch: %s isn't done in a batch" op)))
        (agent-ui-do op (plist-get rest :id)
                     (if (equal op "show") rest (agent-ui--plist-delete rest :id))
                     canvas))
    (error (list :ok :false :error (agent-ui-error-message err)))))

;; ====== READING IT: get ======
;; An agent reads what a canvas or a dashboard shows as data (its components
;; with their properties and values), never as a picture.  A dashboard hidden
;; whose data is old is fetched first (agent-ui-dashboards.el): the reply says
;; it's fetching, and bin/agent-ui reads again once its queries end. --changed:
;; only the components changed since this session's last read of that canvas
;; (and the ones gone), each session's reads remembered by the canvas.

(defvar-local agent-ui--reads nil
  "In a canvas: what each session read last, by its canvas's name.
A hash table of a component's id to a copy of its data, compared with
`equal' (a hash such as `sxhash-equal' misses deep or late parts).")

(defun agent-ui--get (id canvas)
  "Return the reply to get (see above): ID's component, or all of CANVAS's."
  (let* ((buffer (agent-ui--buffer canvas))
         (dashboard (and (boundp 'agent-ui-dashboards--state) (buffer-local-value 'agent-ui-dashboards--state buffer)))
         (fetching (and dashboard (fboundp 'agent-ui-dashboard-read-fetch) (agent-ui-dashboard-read-fetch dashboard)))
         (ids (if (and id (not (string-empty-p id)))
                  (progn (agent-ui-get id :canvas canvas) (list id))
                (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components :canvas canvas))))
         (components (mapcar (lambda (id) (agent-ui-get id :canvas canvas)) ids))
         (changed (member "changed" agent-ui--request-options))
         (reader (or agent-ui--request-canvas ""))
         (seen (with-current-buffer buffer
                 (or (cdr (assoc reader agent-ui--reads))
                     (let ((table (make-hash-table :test #'equal)))
                       (push (cons reader table) agent-ui--reads)
                       table))))
         (shown (if changed
                    (seq-remove (lambda (e) (equal (gethash (plist-get e :id) seen) e)) components)
                  components))
         ;; Gone since the last read (all of them read: no ID).
         (gone (when (and changed (not (and id (not (string-empty-p id)))))
                 (seq-remove (lambda (old) (member old ids)) (hash-table-keys seen)))))
    ;; Remembered once read for good: not while its fetch runs (read again).
    (unless fetching
      (dolist (e components) (puthash (plist-get e :id) (copy-tree e t) seen))
      (dolist (old gone) (remhash old seen)))
    (append (list :ok t :canvas (agent-ui--canvas-label canvas))
            (when dashboard
              (list :dashboard (agent-ui-dashboards--name dashboard)
                    :root (abbreviate-file-name (agent-ui-dashboards--root dashboard))
                    :fetched (let ((ago (agent-ui-dashboard-fetched dashboard))) (and ago (round ago)))
                    :fetching (if fetching t :false)))
            (list :components (vconcat shown))
            (when changed (list :removed (vconcat gone))))))

;; ====== THE REQUEST ======

(defun agent-ui--read-file (file)
  "Return the contents of FILE, read as UTF-8."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (buffer-string)))

(defun agent-ui-request (folder)
  "Answer bin/agent-ui's request in FOLDER (see the top of this file):
its reply written there, as JSON.  Never signals: an error is the reply."
  (let ((reply
         (condition-case err
             (let* ((lines (split-string (agent-ui--read-file (expand-file-name "request" folder))
                                         "\n"))
                    (op (nth 0 lines))
                    (id (nth 1 lines))
                    (session (nth 2 lines))
                    (cwd (nth 3 lines))
                    (options (split-string (or (nth 4 lines) "") " " t))
                    (part (nth 5 lines))
                    (dashboard (nth 6 lines))
                    (payload-file (expand-file-name "payload" folder))
                    (payload (when (file-exists-p payload-file)
                               (let ((json (string-trim (agent-ui--read-file payload-file))))
                                 (cond
                                  ((string-empty-p json) (agent-ui--fail "%s: no JSON given" op))
                                  ;; A type's code, not JSON.
                                  ((equal op "define") json)
                                  (t (agent-ui-parse-json json))))))
                    ;; Its canvas named in its JSON (not a batch's: each
                    ;; operation its own), else on its command line.
                    (taken (if (member op '("show" "update" "append" "render" "bug"))
                               (agent-ui--take-canvas payload)
                             (cons nil payload)))
                    (payload (cdr taken))
                    (part (or (car taken) part))
                    (base (funcall agent-ui-canvas-function
                                   (unless (equal session "") session)
                                   (unless (equal cwd "") cwd)))
                    (base-name (if (bufferp base) (buffer-local-value 'agent-ui--canvas-name base) base))
                    (canvas (cond
                             ;; One of the project's dashboards, open.
                             ((not (member dashboard '(nil "")))
                              (agent-ui-dashboard-canvas dashboard (unless (equal cwd "") cwd)))
                             ((member part '(nil "")) base)
                             (t (agent-ui-sub-canvas base-name part)))))
               (let* ((agent-ui--request-options options)
                      (agent-ui--request-canvas base-name)
                      (agent-ui--request-cwd (unless (equal cwd "") cwd))
                      (agent-ui-file-directory (and agent-ui--request-cwd
                                                    (file-name-as-directory agent-ui--request-cwd))))
                 (agent-ui-do op (unless (equal id "") id) payload canvas)))
           (error (list :ok :false :error (agent-ui-error-message err)))))
        (json nil))
    ;; Written as JSON here too: a reply that can't be is an error said,
    ;; not none (bin/agent-ui would take it for no Emacs).
    (setq json (condition-case err
                   (json-serialize (agent-ui-to-json reply))
                 (error (json-serialize
                         (agent-ui-to-json
                          (list :ok :false
                                :error (format "its reply couldn't be written as JSON: %s"
                                               (error-message-string err))))))))
    (with-temp-file (expand-file-name "reply" folder)
      (setq-local coding-system-for-write 'utf-8)
      (insert json "\n"))
    t))


(provide 'agent-ui-request)

;;; agent-ui-request.el ends here
