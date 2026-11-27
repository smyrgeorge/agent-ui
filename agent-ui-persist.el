;;; agent-ui-persist.el --- Canvases kept with their sessions, back when resumed  -*- lexical-binding: t; -*-

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

;; Agent UI's canvases kept with their sessions: back when a session is
;; resumed.
;;
;; A session's canvas is data, its components: as they change, saved (a moment
;; later, together) as JSON in the session's .agent-shell/agent-ui/, named by
;; its ACP session id, beside agent-shell's transcripts.  When a session
;; starts with that id (resumed: picked when agent-shell asks, its
;; restart), its canvas comes back, as it was.  Its components' sources aren't
;; started again (a command run twice): they come back as they last were.
;; One of a type gone since (discarded; dropped from Agent UI, as the issues
;; board) is left out, a panel's child too, the panel back with the others.
;; Closing a canvas, or its session, doesn't change what's saved; clearing it
;; does (an empty canvas, saved).  A canvas closed (q) and made again by the
;; agent's next component keeps what was saved before in its saves, before its
;; own components (it saved only these, the others lost for good); its
;; clearing drops them.  A save waiting when Emacs exits is done then.  A
;; session's other canvases ("SESSION / tests") are kept beside it,
;; ID@tests.json, and come back with it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'agent-ui-agent)

(declare-function agent-ui--finished-check "agent-ui-finished")
(defvar agent-ui--kept)

;; ====== VARIABLES ======

(defcustom agent-ui-persist-directory ".agent-shell/agent-ui/"
  "Where sessions' canvases are kept, in a session's directory."
  :type 'string :group 'agent-ui)

(defcustom agent-ui-persist-delay 1.0
  "Seconds after a canvas's change before it's saved.
Changes within it are saved together."
  :type 'number :group 'agent-ui)

(defvar-local agent-ui--persist-timer nil "In a canvas: its save, waiting.")

(defvar-local agent-ui--persist-kept nil
  "In a canvas made again (closed, its session going on): saved components.
The components its session saved before, kept in its saves before
its own (see above).")

(declare-function agent-shell-session-id "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")

;; ====== WHERE ======

(defun agent-ui-persist--stem (session)
  "Return the start of SESSION's (an agent-shell buffer) files' names.
Its folder and id; nil while it has no session id."
  (when-let* (((buffer-live-p session))
              ((fboundp 'agent-shell-session-id))
              (id (agent-shell-session-id :shell-buffer session))
              ((not (string-empty-p id))))
    (expand-file-name (replace-regexp-in-string "[^A-Za-z0-9_.-]" "_" id)
                      (expand-file-name agent-ui-persist-directory (agent-ui--session-cwd session)))))

(defun agent-ui-persist-file (session &optional part)
  "Return where SESSION's (an agent-shell buffer) canvas is kept.
Or its other canvas PART's (ID@PART.json, PART hex-escaped: read
back as it was): nil while it has no session id."
  (when-let* ((stem (agent-ui-persist--stem session)))
    (concat stem (if part (concat "@" (url-hexify-string part)) "") ".json")))

(defun agent-ui-persist--parts (session)
  "SESSION's other canvases kept: their names."
  (when-let* ((stem (agent-ui-persist--stem session))
              ((file-directory-p (file-name-directory stem))))
    (mapcar (lambda (file)
              (decode-coding-string
               (url-unhex-string (substring (file-name-base file) (1+ (length (file-name-nondirectory stem)))))
               'utf-8))
            (directory-files (file-name-directory stem) t
                             (concat "\\`" (regexp-quote (file-name-nondirectory stem)) "@.+\\.json\\'")))))

;; ====== SAVING ======

(defvar-local agent-ui--persist-failed nil
  "Why this canvas's last save failed, or what it left out: said once.")

(defun agent-ui--persist-said (why)
  "Say WHY the current canvas wasn't saved (whole), once; nil: it was."
  (unless (or (null why) (equal why agent-ui--persist-failed))
    (message "%s" (format "Agent UI: %s couldn't be saved: %s" (buffer-name) why)))
  (setq agent-ui--persist-failed why))

(defun agent-ui-persist--json (components)
  "COMPONENTS as a JSON array, and those that can't be written: (TEXT . IDS).
A component that can't be written as JSON left out: the others saved."
  (let ((written nil) (bad nil))
    (dolist (component components)
      (condition-case nil
          (push (json-serialize (agent-ui-to-json component)) written)
        (error (push (plist-get component :id) bad))))
    (cons (concat "[" (string-join (nreverse written) ",") "]") (nreverse bad))))

(defun agent-ui-persist-save (&optional canvas)
  "Save CANVAS (default: the current buffer's), if it has a session id.
Its components, as JSON; one that can't be written left out, said (once).
Returns the file, or nil."
  (with-current-buffer (or canvas (current-buffer))
    (when (timerp agent-ui--persist-timer)
      (cancel-timer agent-ui--persist-timer))
    (setq agent-ui--persist-timer nil)
    (when-let* ((file (agent-ui-persist-file agent-ui--session-buffer agent-ui--canvas-part)))
      ;; Its own: not its sections' (another session's canvas shown in
      ;; one is that one's).
      (let ((components (append agent-ui--persist-kept
                              (mapcar (lambda (id) (agent-ui--entry-component (gethash id agent-ui--entries)))
                                      (agent-ui--section-keys nil)))))
        (pcase-let ((`(,json . ,bad) (agent-ui-persist--json components)))
          (make-directory (file-name-directory file) t)
          (let ((coding-system-for-write 'utf-8))
            (write-region (decode-coding-string json 'utf-8) nil file nil 'silent))
          (agent-ui--persist-said
           (and bad (format "%s left out: %s written as JSON" (string-join bad ", ")
                            (if (cdr bad) "they can't be" "it can't be")))))
        file))))

(defun agent-ui--persist-later ()
  "The current canvas changed: saved `agent-ui-persist-delay' from now."
  (when (and agent-ui--session-buffer (not agent-ui--persist-timer))
    (let ((canvas (current-buffer)))
      (setq agent-ui--persist-timer
            (run-with-timer agent-ui-persist-delay nil
                            (lambda ()
                              (when (buffer-live-p canvas)
                                ;; Failing (its folder can't be written):
                                ;; said once, not an error at each change.
                                (condition-case err
                                    (agent-ui-persist-save canvas)
                                  (error
                                   (with-current-buffer canvas
                                     (agent-ui--persist-said (error-message-string err))))))))))))

(defun agent-ui--persist-closing ()
  "Save at once, as the canvas closes, what's waiting (what's saved stays).
A save failing is said, never stops it closing (nor its session)."
  (when (timerp agent-ui--persist-timer)
    ;; Not `with-demoted-errors': with `debug-on-error' on, it lets the
    ;; error through, and the canvas stays open.
    (condition-case err
        (agent-ui-persist-save (current-buffer))
      (error (message "Agent UI: the canvas couldn't be saved: %S" err)))))

(add-hook 'agent-ui-changed-hook #'agent-ui--persist-later)
(add-hook 'agent-ui-canvas-hook
          (lambda () (add-hook 'kill-buffer-hook #'agent-ui--persist-closing -50 t)))

(defun agent-ui--persist-kept-h ()
  "Keep what was saved before, when a canvas is made, tied to its session.
After `agent-ui--link-session'.  What was saved for it before is kept
in its saves (see above); not one coming back with its session
\(those are its components)."
  (unless (bound-and-true-p agent-ui--restoring)
    (when-let* ((file (agent-ui-persist-file agent-ui--session-buffer agent-ui--canvas-part))
                ((file-readable-p file)))
      (setq agent-ui--persist-kept (seq-filter #'agent-ui--plist-p (agent-ui-persist--read file))))))

(add-hook 'agent-ui-canvas-hook #'agent-ui--persist-kept-h t)

(defun agent-ui--persist-shown-h (id _component)
  "Drop the component kept from before, when component ID is shown.
The one with its id is replaced (removed, it's gone)."
  (when agent-ui--persist-kept
    (setq agent-ui--persist-kept
          (seq-remove (lambda (e) (equal (plist-get e :id) id)) agent-ui--persist-kept))))

(add-hook 'agent-ui-shown-functions #'agent-ui--persist-shown-h)

(defun agent-ui--persist-cleared-h ()
  "The canvas cleared: what was kept from before dropped too, saved empty."
  (when agent-ui--persist-kept
    (setq agent-ui--persist-kept nil)
    (agent-ui--persist-later)))

(add-hook 'agent-ui-cleared-hook #'agent-ui--persist-cleared-h)

(defun agent-ui--persist-all-now ()
  "Do the canvases' saves waiting now, as Emacs exits.
Their last second of changes was lost."
  (dolist (canvas (agent-ui-canvases))
    (when (timerp (buffer-local-value 'agent-ui--persist-timer canvas))
      (with-demoted-errors "Agent UI: a canvas not saved: %S"
        (agent-ui-persist-save canvas)))))

;; In `kill-emacs-hook', by `agent-ui-mode' (agent-ui.el).

;; ====== RESTORING ======

(defun agent-ui-persist--without-sources (component)
  "COMPONENT without its source, nor its panel's children theirs."
  (let ((component (agent-ui--plist-delete component :source)))
    (if-let* ((children (plist-get component :children)))
        (plist-put component :children (mapcar (lambda (c) (if (agent-ui--plist-p c) (agent-ui-persist--without-sources c) c))
                                             children))
      component)))

(defun agent-ui-persist--gone-p (component)
  "Whether COMPONENT is of a type gone since it was saved.
A type discarded, or dropped from Agent UI."
  (and (agent-ui--plist-p component)
       (plist-get component :type)
       (not (ignore-errors (agent-ui-type (plist-get component :type))))))

(defun agent-ui-persist--without-gone (component)
  "Return COMPONENT without its panel's children of a type gone.
Their weights too, nor its children's: the panel back with the
others."
  (let ((children (plist-get component :children)))
    (if (not (and children (listp children)))
        component
      (let ((weights (plist-get component :weights))
            (component (copy-sequence component)))
        (when (and (listp weights) (= (length weights) (length children)))
          (plist-put component :weights (cl-loop for c in children for w in weights
                                               unless (agent-ui-persist--gone-p c) collect w)))
        (plist-put component :children
                   (cl-loop for c in children
                            unless (agent-ui-persist--gone-p c)
                            collect (if (agent-ui--plist-p c) (agent-ui-persist--without-gone c) c)))))))

(defun agent-ui-persist--read (file)
  "The components saved in FILE; nil if it can't be read."
  (condition-case nil
      (agent-ui-parse-json (with-temp-buffer
                             (let ((coding-system-for-read 'utf-8))
                               (insert-file-contents file))
                             (buffer-string)))
    ((agent-ui-error file-error) nil)))

(defun agent-ui-persist-restore (session)
  "Bring SESSION's canvases back, an agent-shell buffer with a session id.
Its own and its others, each kept and empty now, its components shown
again, their sources not started.  Returns how many; nil if none was."
  (let* ((counts (mapcar (lambda (part) (agent-ui-persist--restore-canvas session part))
                         (cons nil (agent-ui-persist--parts session))))
         (restored (delq nil counts)))
    (when restored
      (let ((count (apply #'+ restored)))
        (when (> count 0)
          (message "Agent UI: this session's canvas%s, back (%d component%s)"
                   (if (cdr restored) "es" "") count (if (= count 1) "" "s")))
        count))))

(defvar agent-ui--restoring nil
  "Non-nil while a canvas's components come back (see agent-ui-agent.el).")

(defun agent-ui-persist--restore-canvas (session part)
  "Bring SESSION's canvas (PART nil) or its other canvas PART back.
If kept and empty: how many of its components; nil if not."
  (when-let* ((file (agent-ui-persist-file session part))
              ((file-readable-p file))
              (name (agent-ui-sub-canvas (agent-ui--session-name session) part))
              ((not (agent-ui-components :canvas name))))
    (let ((components (agent-ui-persist--read file))
          (count 0)
          ;; Coming back: its questions don't take the focus.
          (agent-ui--restoring t))
      (dolist (component components)
        (when (agent-ui--plist-p component)
          (condition-case nil
              (progn (agent-ui-show (agent-ui-persist--without-sources
                                    (agent-ui-persist--without-gone component))
                                   :canvas name)
                     (cl-incf count))
            ;; One of a type gone since (discarded, dropped): left out.
            (agent-ui-error nil))))
      ;; Those finished come back kept, no countdown (the user's Keep isn't
      ;; saved; theirs was running as it ended): until they change.
      (when-let* ((canvas (get-buffer (agent-ui-canvas-buffer-name name))))
        (with-current-buffer canvas
          (unless agent-ui--kept (setq agent-ui--kept (make-hash-table :test #'equal)))
          (dolist (id agent-ui--order)
            (let ((component (agent-ui--entry-component (gethash id agent-ui--entries))))
              (when (eq (agent-ui-finished component) 'done)
                (puthash id component agent-ui--kept))))
          (agent-ui--finished-check)))
      count)))

(defun agent-ui--persist-watch ()
  "In a new agent-shell buffer: its canvas back once its session is known."
  (when (fboundp 'agent-shell-subscribe-to)
    (let ((session (current-buffer)))
      (agent-shell-subscribe-to
       :shell-buffer session
       :event 'init-session
       :on-event (lambda (_event)
                   (condition-case err
                       (agent-ui-persist-restore session)
                     (error (message "Agent UI: the canvas couldn't come back: %s"
                                     (error-message-string err)))))))))

;; In `agent-shell-mode-hook', by `agent-ui-mode' (agent-ui.el).


(provide 'agent-ui-persist)

;;; agent-ui-persist.el ends here
