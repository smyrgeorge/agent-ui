;;; agent-ui-finished.el --- A finished component closing itself  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yorgos S.

;; Author: Yorgos S. <https://github.com/smyrgeorge>
;; Assisted-by: Claude:claude-opus-5-5
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

;; A finished component closes itself.
;;
;; A component of a type that finishes (its :finished: steps, todo, progress),
;; once all of it went well (`done'), closes itself `agent-ui-close-finished'
;; seconds later, or its own :close's (false: never); a line under it counts
;; them down, with a Keep button: \"closing\" if it's its canvas's last
;; component (the canvas goes with it), else \"removed\" (the canvas stays, with
;; the others).  Closed, it's removed: its canvas's pane
;; closes if it was the last (as an emptied canvas's does), the cursor back in
;; the session if it was there.  Some of it failed: it stays.  It changing
;; meanwhile starts its countdown again, or stops it (not finished well any
;; more); Keep stops it until it changes.  The countdown runs while its canvas
;; is in a window: you see it go.  A project's dashboard
;; (agent-ui-dashboards.el) never closes: it stays.

;;; Code:

(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'agent-ui-agent)

(require 'cl-lib)

;; ====== VARIABLES ======

(defcustom agent-ui-close-finished 10
  "Seconds a finished component (see above) stays before it closes itself;
nil: only those whose :close gives seconds close."
  :type '(choice (const :tag "Only when the component says" nil) number)
  :group 'agent-ui)

(defvar-local agent-ui--closing nil
  "In a canvas, its components counting down, by id.
\(COMPONENT . SECONDS-LEFT), COMPONENT as it was when it started (it changing starts it again).")

(defvar-local agent-ui--kept nil
  "In a canvas, its finished components the user kept, by id.
Each as it was then (it changing forgets it).")

(defvar-local agent-ui--closing-timer nil
  "In a canvas: the countdowns' timer, a tick a second.")

;; ====== COUNTING DOWN ======

(defun agent-ui--close-seconds (component)
  "The seconds COMPONENT stays once finished.
Its :close, else `agent-ui-close-finished'; or nil: it doesn't close."
  (let ((close (plist-get component :close)))
    (cond ((eq close :false) nil)
          ((numberp close) close)
          ((eq close t) (or agent-ui-close-finished 10))
          (t agent-ui-close-finished))))

(defun agent-ui--finished-check ()
  "The current canvas changed (`agent-ui-changed-hook').
Its finished components' countdowns started, started again or stopped
\(see above)."
  (unless (bound-and-true-p agent-ui-dashboards--state)
    (let ((closing (or agent-ui--closing (make-hash-table :test #'equal)))
          (kept (or agent-ui--kept (make-hash-table :test #'equal))))
      ;; Gone from it: forgotten.
      (dolist (table (list closing kept))
        (let (gone)
          (maphash (lambda (id _) (unless (member id agent-ui--order) (push id gone))) table)
          (dolist (id gone) (remhash id table))))
      (dolist (id agent-ui--order)
        (let* ((component (agent-ui--entry-component (gethash id agent-ui--entries)))
               (counting (gethash id closing))
               (seconds (agent-ui--close-seconds component)))
          ;; Changed since the user kept it: forgotten.
          (unless (eq (gethash id kept component) component)
            (remhash id kept))
          (if (and seconds
                   (not (gethash id kept))
                   (eq (agent-ui-finished component) 'done))
              (unless (eq (car counting) component)
                (puthash id (cons component (max 0 (ceiling seconds))) closing)
                (agent-ui--dirty (list id)))
            (when counting
              (remhash id closing)
              (agent-ui--dirty (list id))))))
      (setq agent-ui--closing closing
            agent-ui--kept kept)
      (agent-ui--closing-timer))))

(add-hook 'agent-ui-changed-hook #'agent-ui--finished-check)

(defun agent-ui--closing-timer ()
  "The current canvas's countdowns' timer.
Running while one counts down, stopped once none does."
  (if (and agent-ui--closing (> (hash-table-count agent-ui--closing) 0))
      (unless (timerp agent-ui--closing-timer)
        (let ((buffer (current-buffer))
              (timer nil))
          (setq timer (run-with-timer 1 1 (lambda () (agent-ui--closing-tick buffer timer)))
                agent-ui--closing-timer timer)))
    (when (timerp agent-ui--closing-timer)
      (cancel-timer agent-ui--closing-timer))
    (setq agent-ui--closing-timer nil)))

(defun agent-ui--closing-tick (canvas timer)
  "A second gone: CANVAS's countdowns a second down.
That's if it's in a window (else they wait); those at 0 closed.  TIMER,
the timer: stopped once CANVAS is gone."
  (if (not (buffer-live-p canvas))
      (cancel-timer timer)
    (with-current-buffer canvas
      (when (agent-ui--window)
        (let (over)
          (maphash (lambda (id counting)
                     (setcdr counting (1- (cdr counting)))
                     (if (<= (cdr counting) 0)
                         (push id over)
                       (agent-ui--dirty (list id))))
                   agent-ui--closing)
          (when over
            (agent-ui--close-finished canvas over)))
        ;; Killed with its last one (a session's other canvas: nothing left
        ;; to count down), not looked at again.
        (when (buffer-live-p canvas)
          (with-current-buffer canvas
            (agent-ui--closing-timer)))))))

(defvar-local agent-ui-closes-with nil
  "In a canvas, the key of the component whose countdown closes it all.
Its sections too (an agent workflow's run's checklist: the run done, its pane
goes): \"closing\", not \"removed\", under it; once it's over, the canvas
cleared, its panes closed, it killed.")

(defun agent-ui--close-finished (canvas ids)
  "IDS of CANVAS removed, their countdown over.
The cursor back in its session if it was in CANVAS's pane, closed now
\(or CANVAS killed, emptied: `agent-ui--close-emptied')."
  (let ((focused (eq (window-buffer (selected-window)) canvas))
        (session (with-current-buffer canvas (bound-and-true-p agent-ui--session-buffer))))
    (dolist (id ids)
      (when (buffer-live-p canvas)
        (with-current-buffer canvas
          (remhash id agent-ui--closing)
          (when (member id agent-ui--order)
            (if (equal id agent-ui-closes-with)
                (progn (agent-ui-clear :canvas canvas)
                       (when (buffer-live-p canvas) (kill-buffer canvas)))
              (agent-ui-remove id :canvas canvas))))))
    (when-let* (((and focused (not (and (buffer-live-p canvas) (get-buffer-window canvas)))))
                (window (and (buffer-live-p session) (get-buffer-window session))))
      (select-window window))))

;; ====== ITS LINE ======

(defun agent-ui--closing-footer (id &optional width)
  "Component ID's countdown, a line under it, while it counts down.
Two lines if WIDTH is too narrow for one, its words shortened if need
be: closing, its canvas with it (its last component), or removed, the
canvas staying (`agent-ui-footer-functions')."
  (when-let* ((counting (and agent-ui--closing (gethash id agent-ui--closing))))
    (let* ((verb (if (and (not (equal id agent-ui-closes-with))
                          (or agent-ui--sections (cl-some (lambda (other) (not (equal other id))) agent-ui--order)))
                     "removed"
                   "closing"))
           (said (format "All done, %s in %ds" verb (cdr counting))))
      (when (and width (> (+ 2 (string-width said)) width))
        (setq said (format "%s in %ds" (capitalize verb) (cdr counting))))
      (agent-ui-button-row
       (list (concat (propertize "✓ " 'face 'agent-ui-success) (propertize said 'face 'agent-ui-muted))
             (agent-ui-button (propertize "⏵ Keep" 'face 'agent-ui-action)
                              (lambda () (agent-ui-keep-finished id))
                              "RET: keep it, not closed"))
       width))))

(add-hook 'agent-ui-footer-functions #'agent-ui--closing-footer)

(defun agent-ui-keep-finished (id &optional canvas)
  "Keep finished component ID of CANVAS (default: the current buffer's).
Not closed, until it changes (see above)."
  (agent-ui--in (or canvas (current-buffer))
    (when-let* ((entry (gethash id agent-ui--entries)))
      (puthash id (agent-ui--entry-component entry)
               (or agent-ui--kept (setq agent-ui--kept (make-hash-table :test #'equal))))
      (when agent-ui--closing
        (remhash id agent-ui--closing))
      (agent-ui--dirty (list id))
      (agent-ui--closing-timer))))


(provide 'agent-ui-finished)

;;; agent-ui-finished.el ends here
