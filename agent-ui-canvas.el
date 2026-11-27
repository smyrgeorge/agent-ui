;;; agent-ui-canvas.el --- The canvas: a buffer of components drawn in place  -*- lexical-binding: t; -*-

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

;; Agent UI's canvas: a buffer per agent session holding the components it
;; shows, in the order shown, each redrawn in place when it changes.
;;
;; Each component is the text between two markers, a blank line after it.  A new
;; component is drawn at once; an update marks it dirty, and a timer redraws the
;; dirty ones `agent-ui-redraw-delay' later, so a stream of updates costs a
;; few redraws.  Animated components (a spinner) are redrawn by a timer of the
;; canvas while there are any.  Components are checked when given: a wrong one is
;; an error to the caller, not a drawing.  A canvas may be divided in sections,
;; each under its divider, and a session's canvas shown in another's section
;; (see SECTIONS below).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)

;; ====== VARIABLES ======

(defcustom agent-ui-redraw-delay 0.1
  "Seconds between a component's update and its redraw.
Updates within it are drawn together."
  :type 'number :group 'agent-ui)

(defcustom agent-ui-animation-interval 0.15
  "Seconds between frames of animated components (a spinner)."
  :type 'number :group 'agent-ui)

(defcustom agent-ui-default-width 80
  "The width components are drawn at while their canvas isn't in a window."
  :type 'natnum :group 'agent-ui)

(defcustom agent-ui-max-components 100
  "The most components a canvas holds; showing one more is an error."
  :type 'natnum :group 'agent-ui)

(defcustom agent-ui-default-canvas "default"
  "The canvas used when none is named."
  :type 'string :group 'agent-ui)

(declare-function agent-ui-pane-display "agent-ui-pane" (canvas))
(declare-function agent-ui-source-check "agent-ui-source" (source))

(defcustom agent-ui-display-function #'agent-ui-pane-display
  "Called with a canvas's buffer when a new component is shown in it.
That's while it's in no window (the minibuffer open: once it's closed):
shows it, without selecting it.  By default, in its session's pane
\(`agent-ui-pane-display'); `agent-ui-display-canvas' shows it as
`display-buffer' would."
  :type 'function :group 'agent-ui)

(defvar agent-ui-canvas-hook nil
  "Run in a canvas's buffer once it's made.")

(defvar agent-ui-check-source-function #'agent-ui-source-check
  "Called with a component's :source: an error if it's wrong.")

(defvar agent-ui-shown-functions nil
  "Called in a canvas with a component's id and itself, once it's shown.
It's new, or shown again.")

(defvar agent-ui-changed-hook nil
  "Run in a canvas when its components change.
They're shown, updated, appended to, removed, cleared; not when the
canvas closes.")

(defvar agent-ui-cleared-hook nil
  "Run in a canvas once it's cleared (every component removed at once).")

(defvar agent-ui-title-changed-hook nil
  "Run in a canvas once its title changed (`agent-ui-canvas-title').
Its lone panel's, come, changed or gone.  Its view's bar names it again.")

(defvar agent-ui-removed-functions nil
  "Called in a canvas with a component's id once it's gone.
It's removed, or its canvas killed.")

(defvar agent-ui-close-emptied-functions nil
  "Called with a canvas left without components, its panes closed.
That's cleared, or its last one removed.  Non-nil from one: it's killed
too, gone from the windows' tabs (agent-ui-agent.el: a session's other
canvas); else it stays.  The first one's.")

(defvar agent-ui-footer-functions nil
  "Called in a canvas with a component's id and the width it's drawn at (nil:
any), as it's drawn: lines to draw under it, that wide at most (the
canvas's, not the component's: a finished one's countdown), or nil.  The first
one's are drawn.")

(cl-defstruct (agent-ui--entry (:constructor agent-ui--make-entry))
  "A component of a canvas: its key (ID: its id, SECTION/ID in a section, see
SECTIONS below), itself (a plist, its own id in it), where it's drawn, and
what's drawn there: (COMPONENT WIDTH GRAPHIC FOOTER UNTITLED), its type's
:extend editing it (FOOTER: a line drawn under it, `agent-ui-footer-functions';
UNTITLED: its title not drawn, `agent-ui-canvas-title');
SHOWN, it as it was shown, before updates and its sources' changes (its
data left out: what a dashboard saved from it keeps); PART, in a section
hosting a session's canvas, the session's other canvas it was shown on
\(\"ask\"), nil for its own; MEMO, the drawings of its parts its
animation's frames reuse (`agent-ui-memo') and its last frame's, until
it's drawn otherwise."
  id component start end drawn shown part memo)

(defvar-local agent-ui--canvas-name nil "This canvas's name.")
(defvar-local agent-ui--entries nil "This canvas's components, by id.")
(defvar-local agent-ui--order nil "This canvas's components' ids, in order.")
(defvar-local agent-ui--dirty nil "Ids of the components to redraw.")
(defvar-local agent-ui--redraw-timer nil)
(defvar-local agent-ui--animation-timer nil)
(defvar-local agent-ui--animated nil
  "This canvas's animated components' ids, as of its last change.")
(defvar-local agent-ui--tick 0 "Counts animation frames.")
(defvar-local agent-ui--width nil "The width its components were drawn at.")
(defvar-local agent-ui--cell nil
  "The size of a character cell its components were drawn for, in pixels:
\(WIDTH HEIGHT) (their images, their glyphs evened out are sized from it).")
(defvar-local agent-ui--counter 0 "For ids made for components shown without one.")
(defvar-local agent-ui-canvas-name nil
  "A name of its own the canvas goes by where its name shows (its tab:
Agent UI: NAME), set by what made it: a project dashboard's, its name.
Its lone panel's title is then drawn in the panel's top border, not given
to its tab (see A LONE PANEL'S TITLE).")
(defvar-local agent-ui--untitled nil
  "The canvas's lone panel and its title, as last seen: (ID . TITLE).
Not drawn on it (see `agent-ui-canvas-title'); nil: none.")
(defvar-local agent-ui--hidden nil
  "Why the canvas's pane couldn't open (an error's message), until it does.")
(defvar-local agent-ui--sections nil
  "This canvas's sections, in their order.
They are `agent-ui--section's (see SECTIONS below).")
(defvar-local agent-ui--dirty-sections nil "Names of the sections whose dividers to redraw.")

(defvar agent-ui--in-section nil
  "The section of the components being shown, changed or looked at in a canvas.
Its name; nil, the canvas's own (outside its sections), or components
given by their keys (see SECTIONS below).")

(defvar agent-ui--in-part nil
  "The session's other canvas a component is shown on, while it is shown.
That's in the section hosting a session's canvas (`agent-ui-host'):
\"ask\" for one, nil for its own.")

(defvar agent-ui--hosts nil
  "The canvases shown in a section of another (`agent-ui-host').
It's ((NAME BUFFER . SECTION)...).")

;; ====== THE BUFFER ======

(defvar-keymap agent-ui-canvas-mode-map
  :doc "Keys of an Agent UI canvas.
Its commands are its parts' (quoted: defined in the files after this one)."
  "g" #'agent-ui-canvas-redraw
  "q" 'agent-ui-quit
  "a" 'agent-ui-send-component
  "b" 'agent-ui-report-bug
  "c" 'agent-ui-comment
  "d" 'agent-ui-uncomment
  "s" 'agent-ui-table-sort
  "x" 'agent-ui-drop-item
  "e" 'agent-ui-edit-item
  "K" 'agent-ui-move-item-up
  "J" 'agent-ui-move-item-down
  "M-<up>" 'agent-ui-move-item-up
  "M-<down>" 'agent-ui-move-item-down
  "R" 'agent-ui-review
  "r" 'agent-ui-dashboard-reload
  "S" 'agent-ui-save-dashboard
  "E" 'agent-ui-export-pdf
  "u" 'agent-ui-pane-toggle)

(define-derived-mode agent-ui-canvas-mode special-mode "Agent UI"
  "What a coding agent shows: its components, updated as they change.

\\{agent-ui-canvas-mode-map}"
  (setq-local truncate-lines t
              buffer-undo-list t
              cursor-in-non-selected-windows nil)
  (setq agent-ui--entries (make-hash-table :test #'equal))
  (add-hook 'window-size-change-functions #'agent-ui--size-changed nil t)
  (add-hook 'window-buffer-change-functions #'agent-ui--shown nil t)
  (add-hook 'text-scale-mode-hook #'agent-ui--text-scaled nil t)
  (add-hook 'kill-buffer-hook #'agent-ui--stop-timers nil t))

(defun agent-ui-canvas-buffer-name (name)
  "The name of the buffer of the canvas named NAME."
  (format "Agent UI: %s" name))

(defconst agent-ui-canvas-separator " / "
  "Between a canvas's name and the name of another canvas of its session.")

(defun agent-ui-check-canvas-part (part)
  "PART if it's a fit name for another canvas of a session (\"tests\");
else an error."
  (unless (and (stringp part) (<= 1 (length part) 40)
               (string-match-p "\\`[[:alnum:]][[:alnum:] _.-]*\\'" part))
    (agent-ui--fail "canvas: a name of letters, digits, spaces, _ . or -, up to 40, not %s"
                    (agent-ui--show-value part)))
  part)

(defun agent-ui-sub-canvas (canvas part)
  "The name of CANVAS's other canvas PART (\"SESSION / tests\").
CANVAS itself when PART is nil or empty."
  (if (or (null part) (equal part ""))
      canvas
    (concat canvas agent-ui-canvas-separator (agent-ui-check-canvas-part part))))

(defun agent-ui-canvas (&optional name)
  "The canvas named NAME (default `agent-ui-default-canvas'), its buffer.
Made if there's none."
  (let* ((name (or name agent-ui-default-canvas))
         (buffer (get-buffer-create (agent-ui-canvas-buffer-name name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-ui-canvas-mode)
        (agent-ui-canvas-mode)
        (setq agent-ui--canvas-name name)
        (agent-ui--top-line)
        (run-hooks 'agent-ui-canvas-hook)))
    buffer))

;; ITS TOP LINE
;; A canvas starts with an empty line of its own, no component's: where the
;; cursor is when it opens.  Its first component may start with an image (stats'
;; tiles, a chart, a lone panel), and a box cursor on an image frames the
;; whole of it.  Under its bar or tab, a line of room too, as between its
;; components.  Made with it, put back when it's cleared.
(defun agent-ui--top-line ()
  "The current canvas's top line (see above), the cursor on it."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (insert "\n")))
  (goto-char (point-min)))

(defun agent-ui--start ()
  "Where the current canvas's components start: under its top line."
  (min (point-max) (1+ (point-min))))

(defun agent-ui-canvas-shows-p (buffer)
  "Whether canvas BUFFER shows something.
A component, a section (its top line alone is nothing)."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'agent-ui-canvas-mode)
              (or agent-ui--order agent-ui--sections)
              t))))

(defun agent-ui-canvases ()
  "The canvases' buffers."
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'agent-ui-canvas-mode))
              (buffer-list)))

(defun agent-ui--buffer (canvas &optional create)
  "CANVAS's buffer: CANVAS a buffer, a canvas's name, or nil (the default);
a canvas shown in a section of another (`agent-ui-host'), that one's.  A
canvas by name that isn't there: made if CREATE, else an error (only
showing a component makes one: looking at one doesn't)."
  (car (agent-ui--target canvas nil create)))

(defun agent-ui--target (canvas &optional section create)
  "Where CANVAS's components are: (BUFFER SECTION PART).
CANVAS a buffer, a canvas's name, or nil (see `agent-ui--buffer');
SECTION one of its sections (nil: its own components), an error if it
hasn't it; CREATE non-nil makes CANVAS if there's none.  A canvas shown
in a section of another (`agent-ui-host'): that one's buffer and
section, PART the session's other canvas it is (\"ask\" for
\"SESSION / ask\"), nil for its own."
  (if-let* ((hosted (agent-ui--hosted canvas)))
      (if section
          (agent-ui--fail "canvas %s is shown in section %s of canvas %s: it has no sections"
                          canvas (nth 1 hosted) (buffer-local-value 'agent-ui--canvas-name (car hosted)))
        hosted)
    (let ((buffer (agent-ui--canvas-buffer canvas create)))
      (when section
        (with-current-buffer buffer
          (unless (agent-ui--find-section section)
            (agent-ui--fail "canvas %s has no section %s; its sections: %s"
                            agent-ui--canvas-name (agent-ui--show-value section)
                            (if agent-ui--sections
                                (mapconcat #'agent-ui--section-name agent-ui--sections ", ")
                              "none")))))
      (list buffer section nil))))

(defun agent-ui--canvas-buffer (canvas create)
  "CANVAS's own buffer (see `agent-ui--buffer'): not another's it's shown in.
CREATE non-nil makes it if there's none."
  (if (bufferp canvas)
      (if (and (buffer-live-p canvas)
               (eq (buffer-local-value 'major-mode canvas) 'agent-ui-canvas-mode))
          canvas
        (agent-ui--fail "%S isn't a live canvas" canvas))
    (let* ((name (or canvas agent-ui-default-canvas))
           (buffer (get-buffer (agent-ui-canvas-buffer-name name))))
      (cond
       ((and buffer (eq (buffer-local-value 'major-mode buffer) 'agent-ui-canvas-mode)) buffer)
       (create (agent-ui-canvas name))
       (t (agent-ui--fail "canvas %s has no components yet" name))))))

(defun agent-ui--live-canvas-p (canvas)
  "Whether CANVAS (see `agent-ui--buffer') is there."
  (condition-case nil (and (agent-ui--buffer canvas) t) (agent-ui-error nil)))

(defmacro agent-ui--within (spec &rest body)
  "Run BODY in the buffer of the canvas SPEC says.
SPEC is (CANVAS SECTION [CREATE]) as `agent-ui--target' takes them,
`agent-ui--in-section' its section (and `agent-ui--in-part'): an error
if it isn't there."
  (declare (indent 1))
  (let ((target (make-symbol "target")))
    `(let* ((,target (agent-ui--target ,@spec))
            (agent-ui--in-section (nth 1 ,target))
            (agent-ui--in-part (nth 2 ,target)))
       (with-current-buffer (car ,target) ,@body))))

(defmacro agent-ui--in (canvas &rest body)
  "Run BODY in CANVAS's buffer (see `agent-ui--buffer').
In its section if it's shown in another's (`agent-ui--within'): an
error if it isn't there."
  (declare (indent 1))
  `(agent-ui--within (,canvas nil) ,@body))

(defvar agent-ui-share-window-functions nil
  "Called with a canvas's buffer about to be shown.
A window to show it in, a tab there beside what it shows
\(agent-ui-agent.el: another canvas of its session's), or nil: a window
of its own.  The first one's.")

(defvar agent-ui--restoring)            ; agent-ui-persist.el's: canvases coming back

(defun agent-ui-display-canvas (buffer)
  "Show BUFFER, a canvas, in another window, without selecting it.
In the window `agent-ui-share-window-functions' gives, a tab there
\(coming back with its session: behind what it shows), else in one of
its own."
  (if-let* ((window (run-hook-with-args-until-success 'agent-ui-share-window-functions buffer)))
      (agent-ui--display-in buffer window (bound-and-true-p agent-ui--restoring))
    (display-buffer buffer '(nil (inhibit-same-window . t)))))

(defun agent-ui--display-in (buffer window &optional behind)
  "BUFFER shown in WINDOW, what it showed kept as a tab.
That's its previous buffers; BEHIND: a tab behind it, what it showed
still shown.  Not where the window manager (tiling) would put it:
there, as asked."
  (let ((before (window-buffer window))
        (display-buffer-overriding-action '(nil . nil)))
    (display-buffer buffer `((display-buffer-use-some-window)
                             (some-window . ,(lambda (_buffer _alist) window))
                             (inhibit-same-window . nil)))
    (when (and behind (buffer-live-p before) (eq (window-buffer window) buffer))
      (set-window-buffer window before))
    window))

;; ====== WHILE THE MINIBUFFER IS OPEN ======
;; A canvas's pane opened while the minibuffer is open took another pane's
;; place (tiling steps aside then, Emacs reusing a window), and a question
;; taking the focus took the keys typed there.  Both wait for it to close.

(defvar agent-ui--after-minibuffer nil
  "What waits for the minibuffer to close.
Functions of no argument, the latest first.")

(defun agent-ui-after-minibuffer (function)
  "Call FUNCTION (of no argument) now.
While the minibuffer is open: once it's closed (see above)."
  (if (not (active-minibuffer-window))
      (funcall function)
    (push function agent-ui--after-minibuffer)
    (add-hook 'minibuffer-exit-hook #'agent-ui--minibuffer-exit-h)))

(defun agent-ui--minibuffer-exit-h ()
  "The minibuffer closing.
What waits for it called just after (it's still open while this hook
runs)."
  (remove-hook 'minibuffer-exit-hook #'agent-ui--minibuffer-exit-h)
  (run-with-timer 0 nil #'agent-ui--minibuffer-closed))

(defun agent-ui--minibuffer-closed ()
  "What waits for the minibuffer called, in order.
Waiting again while another is still open (one opened from it)."
  (let ((waiting (reverse agent-ui--after-minibuffer)))
    (setq agent-ui--after-minibuffer nil)
    (dolist (function waiting)
      (with-demoted-errors "Agent UI: %S"
        (agent-ui-after-minibuffer function)))))

(defun agent-ui--display (buffer)
  "BUFFER, a canvas in no window, shown (`agent-ui-display-function').
While the minibuffer is open, once it's closed, if it's still in none.
Its pane not opening (tiling's \"No room for another pane\") isn't an error: its
components are drawn and go on, it's said (`agent-ui--hidden'), and tried
again at its next change."
  (let ((display agent-ui-display-function))
    (agent-ui-after-minibuffer
     (lambda ()
       (when (and (buffer-live-p buffer) (not (get-buffer-window buffer t)))
         ;; The current buffer kept: what showed it may have deleted the
         ;; selected window (another selected, its buffer current), and the
         ;; canvas's new component was then drawn there (a session's start
         ;; replaced by it).
         (let ((hidden (condition-case err
                           (progn (save-current-buffer (funcall display buffer)) nil)
                         (error (error-message-string err)))))
           (with-current-buffer buffer
             (when (and hidden (not agent-ui--hidden))
               (message "%s" (format "%s can't be shown (%s): it opens at its next change, once there's room"
                                     (buffer-name) hidden)))
             (setq agent-ui--hidden hidden))))))))

(defun agent-ui--show-if-hidden ()
  "The current canvas shown, if its pane couldn't open before.
That's if it's still in no window (room made since)."
  (when (and agent-ui--hidden (not (agent-ui--window)))
    (agent-ui--display (current-buffer))))

;; ====== DRAWING ======

(defun agent-ui--window ()
  "A window showing the current canvas, the selected frame's first."
  (or (get-buffer-window (current-buffer))
      (get-buffer-window (current-buffer) t)))

(defun agent-ui--context ()
  "The context the current canvas's components are drawn in (`agent-ui-context')."
  (let* ((window (agent-ui--window))
         (frame (if window (window-frame window) (selected-frame)))
         (font (agent-ui--font-metrics window)))
    (agent-ui-context
     :width (if window
                (max 10 (agent-ui-window-columns window))
              agent-ui-default-width)
     :graphic (display-graphic-p frame)
     :tick agent-ui--tick
     ;; Its cells as its window shows them: scaled with its text (C-x C-+).
     :char-width (if window (window-font-width window) (frame-char-width frame))
     :line-height (if window (window-font-height window) (frame-char-height frame))
     ;; Its text's font, as the window shows it: its size and ascent.
     :font-size (car font)
     :font-ascent (cdr font))))

(defun agent-ui--font-metrics (window)
  "The current canvas's text's font as WINDOW shows it.
\(SIZE . ASCENT) in pixels, or nil (not in a window, empty, a terminal)."
  (when-let* ((window window)
              ((window-live-p window))
              ;; font-at signals for a window showing another buffer.
              ((eq (window-buffer window) (current-buffer)))
              ((display-graphic-p (window-frame window)))
              ((> (buffer-size) 0))
              ;; Its first character, its top line's.
              (font (font-at (point-min) window))
              (info (query-font font)))
    (cons (aref info 2) (aref info 4))))

(defun agent-ui--places-in (start end)
  "Point, the mark, and the windows' points and starts within START..END.
Those of the windows showing this buffer: ((WHAT LINE . COLUMN)...),
WHAT nil (point), `mark', a window (its point) or (start . WINDOW);
LINE counted from START's line.  (The mark too: left to fall to the
text's start, a region
in it, text being selected, stretched to it.)"
  (cl-flet ((place (what pos)
              (and (<= start pos end)
                   (save-excursion
                     (goto-char pos)
                     (cons what (cons (count-lines start (line-beginning-position)) (current-column)))))))
    (delq nil (cons (place nil (point))
                    (cons (and (mark t) (place 'mark (mark t)))
                          (mapcan (lambda (w) (list (place w (window-point w))
                                                    (place (cons 'start w) (window-start w))))
                                  (get-buffer-window-list (current-buffer) nil t)))))))

(defun agent-ui--restore-places (places start end)
  "PLACES (`agent-ui--places-in') put back in START..END.
At their line and column there (its last line at most)."
  (pcase-dolist (`(,what ,line . ,column) places)
    (let ((pos (save-excursion
                 (goto-char start)
                 (forward-line line)
                 (when (> (point) end) (goto-char end))
                 (move-to-column column)
                 (min (point) end))))
      (pcase what
        ('nil (goto-char pos))
        ;; Where it was, as active (or not) as it was.
        ('mark (set-marker (mark-marker) pos))
        (`(start . ,window) (set-window-start window (save-excursion (goto-char pos) (line-beginning-position)) t))
        (window (set-window-point window pos))))))

(defun agent-ui--even (text)
  "TEXT as the canvas shows it, its glyphs as wide as their columns.
That's if the canvas is in the GUI (its window's frame, else the
selected one): `agent-ui-even-glyphs'."
  (let* ((window (agent-ui--window))
         (frame (if window (window-frame window) (selected-frame))))
    (cond ((not (display-graphic-p frame)) text)
          ((eq frame (selected-frame)) (agent-ui-even-glyphs text))
          (t (with-selected-frame frame (agent-ui-even-glyphs text))))))

(defun agent-ui--drawn-at (ctx)
  "The current canvas drawn at CTX's width from now.
What was drawn at another (a new component, a section's divider, drawn at
once while the canvas was in no window, at the default width) all drawn
again soon."
  (let ((width (plist-get ctx :width)))
    (when (and agent-ui--width (not (equal width agent-ui--width)))
      (agent-ui--dirty-all))
    (setq agent-ui--width width)))

;; A LONE PANEL'S TITLE
;; A canvas showing one component only, a panel with a title, has the
;; title in its view's bar (agent-ui-pane.el; a pane of its
;; own: its tab), not drawn over the panel too: two headings for one thing.
;; A second component shown, a section: drawn over it again, the bar the
;; canvas's name.  Its snapshot, its PDF and what's sent to the prompt keep
;; it: drawn by `agent-ui-render' as ever.  A canvas with a name of its own
;; (`agent-ui-canvas-name': a project dashboard) goes by it, in its tab (Agent
;; UI: alerts) and its view's bar, and draws its lone panel's title in the
;; panel's top border (╭─ TITLE ───╮, cut with … when narrow): a title a
;; sentence long made its tab as long.  A panel without a border: its title
;; drawn over it, as any component's.

(defun agent-ui--lone-panel ()
  "The current canvas's lone panel (see above).
It's (ID . TITLE) if it has no sections and one component only, a panel
with a title (its newlines spaces); else nil."
  (when-let* (((null agent-ui--sections))
              ((null (cdr agent-ui--order)))
              (id (car agent-ui--order))
              (entry (gethash id agent-ui--entries))
              (component (agent-ui--entry-component entry))
              ((equal (plist-get component :type) "panel"))
              (title (plist-get component :title))
              ((stringp title))
              ((not (string-blank-p title))))
    (cons id (string-trim (replace-regexp-in-string "[\n\r]+" " " title)))))

(defun agent-ui--canvas-p (buffer)
  "Non-nil if BUFFER is a live canvas buffer."
  (and (buffer-live-p buffer) (eq (buffer-local-value 'major-mode buffer) 'agent-ui-canvas-mode)))

(defun agent-ui-canvas-title (&optional buffer)
  "The title of canvas BUFFER (default: the current one).
When it shows a lone panel (see above): its bar or tab says it, the
canvas doesn't draw it over the panel.  nil otherwise, and for a canvas
with a name of its own (its panel's top border says it)."
  (let ((buffer (or buffer (current-buffer))))
    (and (agent-ui--canvas-p buffer)
         (not (buffer-local-value 'agent-ui-canvas-name buffer))
         (with-current-buffer buffer (cdr (agent-ui--lone-panel))))))

(defun agent-ui-canvas-label (buffer)
  "What names canvas BUFFER where its name would (a tab): \"Agent UI:
NAME\" for a canvas with a name of its own (a project dashboard), \"Agent UI:
TITLE\" when it shows a lone panel (see above), nil otherwise."
  (when-let* ((name (and (agent-ui--canvas-p buffer)
                         (or (buffer-local-value 'agent-ui-canvas-name buffer)
                             (agent-ui-canvas-title buffer)))))
    (agent-ui-canvas-buffer-name name)))

(defun agent-ui--untitled-p (entry)
  "Whether ENTRY is its canvas's lone panel, its title not drawn over it.
\(See above.)  In a canvas with a name of its own, if it has a border
\(its title drawn there)."
  (and (equal (agent-ui--entry-id entry) (car (agent-ui--lone-panel)))
       (or (not agent-ui-canvas-name)
           (not (eq (plist-get (agent-ui--entry-component entry) :border) :false)))))

(defun agent-ui--entry-context (entry ctx)
  "CTX for drawing ENTRY.
Its title not drawn over it if it's the lone panel (see above); in a
canvas with a name of its own, drawn in its top border (:border-title)."
  (if (not (agent-ui--untitled-p entry))
      ctx
    (let ((ctx (plist-put (copy-sequence ctx) :untitled t)))
      (if agent-ui-canvas-name
          (plist-put ctx :border-title (cdr (agent-ui--lone-panel)))
        ctx))))

(defun agent-ui--check-untitled ()
  "In a canvas, after its components changed.
Its lone panel come, gone or retitled (see above), it drawn again, with
its title or without; its view's bar and its tab told
\(`agent-ui-title-changed-hook')."
  (when (derived-mode-p 'agent-ui-canvas-mode)
    (let ((lone (agent-ui--lone-panel)))
      (unless (equal lone agent-ui--untitled)
        (let ((ids (seq-filter (lambda (id) (and id (gethash id agent-ui--entries)))
                               (delete-dups (list (car agent-ui--untitled) (car lone))))))
          (setq agent-ui--untitled lone)
          (when ids (agent-ui--dirty ids))
          (run-hooks 'agent-ui-title-changed-hook)
          (force-mode-line-update t))))))

(add-hook 'agent-ui-changed-hook #'agent-ui--check-untitled)

(defun agent-ui--draw (entry ctx)
  "Draw ENTRY again at CTX's width, in its place.
Point and the windows' inside it kept at their line and column (its
text replaced, they went to its start).  In its canvas, whatever buffer
is current (another's text replaced by it, else)."
  (with-current-buffer (marker-buffer (agent-ui--entry-start entry))
    (agent-ui--draw-here entry ctx)))

(defun agent-ui--draw-here (entry ctx)
  "Draw ENTRY again (see `agent-ui--draw') for CTX, in the current canvas.
ENTRY is its own."
  (agent-ui--drawn-at ctx)
  ;; Drawn otherwise than as an animation's frame: its frames' drawings
  ;; drawn anew.
  (unless agent-ui--memo
    (setf (agent-ui--entry-memo entry) nil))
  (let* ((inhibit-read-only t)
         (ctx (agent-ui--entry-context entry ctx))
         (start (agent-ui--entry-start entry))
         (end (agent-ui--entry-end entry))
         (footer (run-hook-with-args-until-success 'agent-ui-footer-functions (agent-ui--entry-id entry)
                                                   (plist-get ctx :width)))
         ;; Its id in the context: a component's buttons may change it (a choice).
         (text (concat (agent-ui-render (agent-ui--entry-component entry)
                                        (plist-put (copy-sequence ctx) :id (agent-ui--entry-id entry)))
                       (when footer (concat "\n" footer)))))
    ;; A frame drawing it as the last one did (a countdown's time as shown
    ;; the same): left as it is.
    (unless (and agent-ui--memo (equal-including-properties text (gethash :drawn agent-ui--memo)))
      (when agent-ui--memo
        (puthash :drawn text agent-ui--memo))
      (let ((places (agent-ui--places-in start end)))
        (save-excursion
          (delete-region start end)
          (goto-char start)
          (insert (propertize (agent-ui--even text) 'agent-ui-id (agent-ui--entry-id entry)))
          ;; The end follows what's inserted at it; the start stays before it.
          (set-marker end (point)))
        (when places
          (agent-ui--restore-places places start end))))
    (setf (agent-ui--entry-drawn entry)
          (list (agent-ui--entry-component entry) (plist-get ctx :width) (plist-get ctx :graphic) (and footer t)
                (plist-get ctx :untitled)))))

(defun agent-ui--edit (entry edits &optional head tail)
  "EDITS (see `agent-ui-define''s :extend) done on ENTRY's drawing.
In its place: its lines from its type's drawing's first, under HEAD lines (its
title's), its end above TAIL lines (its actions')."
  ;; Drawn otherwise than as an animation's frame: its frames' drawings
  ;; drawn anew.
  (setf (agent-ui--entry-memo entry) nil)
  (let ((head (or head 0))
        (tail (or tail 0))
        (inhibit-read-only t)
        (id (agent-ui--entry-id entry))
        (places (agent-ui--places-in (agent-ui--entry-start entry) (agent-ui--entry-end entry))))
    (save-excursion
      (save-restriction
        (narrow-to-region (agent-ui--entry-start entry) (agent-ui--entry-end entry))
        (dolist (edit edits)
          (pcase edit
            (`(replace ,line ,text)
             (goto-char (point-min))
             (forward-line (+ head line))
             (delete-region (point) (line-end-position))
             (insert (propertize (agent-ui--even text) 'agent-ui-id id)))
            (`(delete ,line ,count)
             (goto-char (point-min))
             (forward-line (+ head line))
             (delete-region (point) (progn (forward-line count) (point))))
            (`(insert ,before-end ,text)
             (goto-char (point-max))
             (setq before-end (+ before-end tail))
             (if (= before-end 0)
                 (insert (propertize (concat "\n" (agent-ui--even text)) 'agent-ui-id id))
               (forward-line (- 1 before-end))
               (beginning-of-line)
               (insert (propertize (concat (agent-ui--even text) "\n") 'agent-ui-id id))))
            (_ (error "Not an edit: %S" edit))))
        (set-marker (agent-ui--entry-end entry) (point-max))))
    (when places
      (agent-ui--restore-places places (agent-ui--entry-start entry) (agent-ui--entry-end entry)))))

(defun agent-ui--extend (entry ctx)
  "ENTRY drawn again by editing its drawing (its type's :extend), for CTX.
From the component it was drawn as: an append draws only what's appended
\(a long log was drawn again whole, each line).  Non-nil if so; nil if
its type can't (then it's drawn whole)."
  (let* ((drawn (agent-ui--entry-drawn entry))
         (old (car drawn))
         (new (agent-ui--entry-component entry))
         (ctx (agent-ui--entry-context entry ctx))
         ;; Drawn at this width, for this kind of frame, no line under it
         ;; then or now, its title drawn then as now: else drawn whole.
         (type (and old (not (eq old new))
                    (equal (cdr drawn) (list (plist-get ctx :width) (plist-get ctx :graphic) nil
                                             (plist-get ctx :untitled)))
                    ;; Its title and actions as they were: the lines around
                    ;; its drawing the same.
                    (equal (plist-get old :title) (plist-get new :title))
                    (equal (plist-get old :caption) (plist-get new :caption))
                    (equal (plist-get old :actions) (plist-get new :actions))
                    (not (run-hook-with-args-until-success 'agent-ui-footer-functions (agent-ui--entry-id entry)
                                                           (plist-get ctx :width)))
                    (equal (plist-get old :type) (plist-get new :type))
                    (ignore-error agent-ui-error (agent-ui-type (plist-get new :type)))))
         (extend (and type (agent-ui-type-extend type)))
         (edits (and extend
                     ;; Wrong (`agent-ui-error'): drawn whole, which says
                     ;; so.  Its :extend failing (a bug, maybe an agent's
                     ;; type's): said, and drawn whole.
                     (with-demoted-errors "Agent UI: drawing only what changed failed, drawn whole: %S"
                       (ignore-error agent-ui-error
                         (funcall extend (agent-ui-check type old) (agent-ui-check type new)
                                  (plist-put (copy-sequence ctx) :id (agent-ui--entry-id entry))))))))
    (when edits
      ;; Its drawing's lines counted from its own first, under its title's
      ;; (they were the entry's: a titled log's counts went over its title),
      ;; its end before its actions' (lines appended went under them).
      (agent-ui--edit entry edits
                      (cl-count ?\n (or (agent-ui--title-text new ctx) ""))
                      (cl-count ?\n (or (agent-ui--actions-text new ctx) "")))
      (setf (car (agent-ui--entry-drawn entry)) new)
      t)))

(defun agent-ui--flush-before-press ()
  "In a canvas, draw its dirty components.
That's before a button's action is looked up
\(`agent-ui-before-press-hook')."
  (when (derived-mode-p 'agent-ui-canvas-mode)
    (agent-ui--flush)))

(add-hook 'agent-ui-before-press-hook #'agent-ui--flush-before-press)

(defun agent-ui--flush ()
  "Redraw the current canvas's dirty components."
  (when (timerp agent-ui--redraw-timer)
    (cancel-timer agent-ui--redraw-timer))
  (setq agent-ui--redraw-timer nil)
  (when (or agent-ui--dirty agent-ui--dirty-sections)
    (let* ((ctx (agent-ui--context))
           ;; Drawn at another width before (at once, out of a window):
           ;; all of it drawn now.
           (all (and agent-ui--width (not (equal agent-ui--width (plist-get ctx :width)))))
           (dirty (if all agent-ui--order agent-ui--dirty))
           (sections (if all (mapcar #'agent-ui--section-name agent-ui--sections) agent-ui--dirty-sections)))
      (setq agent-ui--dirty nil
            agent-ui--dirty-sections nil
            agent-ui--width (plist-get ctx :width)
            agent-ui--cell (agent-ui--cell-size ctx))
      (dolist (id agent-ui--order)
        (when (member id dirty)
          (let ((entry (gethash id agent-ui--entries)))
            (or (agent-ui--extend entry ctx)
                (agent-ui--draw entry ctx)))))
      (dolist (section agent-ui--sections)
        (when (member (agent-ui--section-name section) sections)
          (agent-ui--draw-section section ctx)))
      (agent-ui--fold-refresh)))
  (agent-ui--animate))

(defun agent-ui--dirty (ids)
  "Redraw IDS of the current canvas `agent-ui-redraw-delay' from now.
With any others by then."
  (dolist (id ids)
    (cl-pushnew id agent-ui--dirty :test #'equal))
  (unless agent-ui--redraw-timer
    (let ((buffer (current-buffer)))
      (setq agent-ui--redraw-timer
            (run-with-timer agent-ui-redraw-delay nil
                            (lambda ()
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer
                                  (agent-ui--flush)))))))))

(defun agent-ui-canvas-redraw (&optional canvas)
  "Redraw every component of CANVAS (default: the current buffer's) now."
  (interactive)
  (agent-ui--in (or canvas (current-buffer))
    (agent-ui--show-if-hidden)
    (agent-ui--dirty-all)
    (agent-ui--flush)))

(defun agent-ui--dirty-all ()
  "Every component and divider of the current canvas redrawn soon."
  (setq agent-ui--dirty-sections (mapcar #'agent-ui--section-name agent-ui--sections))
  (agent-ui--dirty agent-ui--order))

(defun agent-ui--cell-size (ctx)
  "CTX's character cell: (WIDTH HEIGHT) in pixels."
  (list (plist-get ctx :char-width) (plist-get ctx :line-height)))

(defun agent-ui--size-changed (window)
  "Its window's width changed, or its font's size (WINDOW).
Draw the components at the new width, for the new cells."
  (with-current-buffer (window-buffer window)
    (let ((ctx (agent-ui--context)))
      (when (and (or agent-ui--order agent-ui--sections)
                 (not (and (equal agent-ui--width (plist-get ctx :width))
                           (equal agent-ui--cell (agent-ui--cell-size ctx)))))
        (agent-ui--dirty-all)))))

(defun agent-ui--text-scaled ()
  "The canvas's text scaled (C-x C-+, C-x C--).
Its components drawn again for its new width and cells (no window's size
changed: they stayed drawn for the old ones until g r)."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (agent-ui--size-changed window)))

(defun agent-ui--font-changed ()
  "A frame's font changed.
Its size: `text-scale-adjust' aside, `set-frame-font'.  The canvases
drawn again, for their new cells.  Their windows' size in pixels stays:
`window-size-change-functions' doesn't say."
  (dolist (buffer (agent-ui-canvases))
    (with-current-buffer buffer
      (when (or agent-ui--order agent-ui--sections)
        (agent-ui--dirty-all)))))

;; In `after-setting-font-hook', by `agent-ui-mode' (agent-ui.el).

;; ====== ANIMATION ======

(defun agent-ui--animated-ids ()
  "The ids of the current canvas's animated components, in order."
  (seq-filter (lambda (id)
                (agent-ui-animated-p (agent-ui--entry-component (gethash id agent-ui--entries))))
              agent-ui--order))

(defun agent-ui--running-sections ()
  "The current canvas's sections running: their mark glows."
  (seq-filter (lambda (section) (eq (agent-ui--section-state section) 'running)) agent-ui--sections))

(defun agent-ui--animate ()
  "Start the current canvas's animation timer if a component is animated.
Or if a section runs; stop it if none is.  Its animated components kept
\(`agent-ui--animated'): its frames look at them alone."
  (setq agent-ui--animated (agent-ui--animated-ids))
  (if (or agent-ui--animated (agent-ui--running-sections))
      (unless agent-ui--animation-timer
        (let ((buffer (current-buffer)))
          (setq agent-ui--animation-timer
                (run-with-timer agent-ui-animation-interval agent-ui-animation-interval
                                #'agent-ui--frame buffer))))
    (agent-ui--stop-animation)))

(defun agent-ui--stop-animation ()
  "Stop the current canvas's animation timer."
  (when (timerp agent-ui--animation-timer)
    (cancel-timer agent-ui--animation-timer))
  (setq agent-ui--animation-timer nil))

(defun agent-ui--shown (window)
  "WINDOW shows the canvas now (its `window-buffer-change-functions').
Its animation, stopped while it was in no window, started again."
  (with-current-buffer (window-buffer window)
    (agent-ui--animate)))

(defun agent-ui--frame (buffer)
  "The next frame of BUFFER's animated components, if it's in a window.
Those animated at its last change looked at alone (not every component
each frame), those still animated drawn again: their parts drawn the
same as time passes as last drawn (`agent-ui-memo'), one drawn as the
last frame drew it left as it is.  In no window, its timer stopped,
started again once it's shown (`agent-ui--shown')."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (not (agent-ui--window))
          (agent-ui--stop-animation)
        (let ((ids (setq agent-ui--animated
                         (seq-filter (lambda (id)
                                       (when-let* ((entry (gethash id agent-ui--entries)))
                                         (agent-ui-animated-p (agent-ui--entry-component entry))))
                                     agent-ui--animated)))
              (sections (agent-ui--running-sections)))
          (if (not (or ids sections))
              (agent-ui--animate)
            (cl-incf agent-ui--tick)
            (let ((ctx (agent-ui--context)))
              (dolist (id ids)
                (let* ((entry (gethash id agent-ui--entries))
                       (agent-ui--memo (or (agent-ui--entry-memo entry)
                                           (setf (agent-ui--entry-memo entry)
                                                 (make-hash-table :test #'equal)))))
                  (agent-ui--draw entry ctx)))
              (dolist (section sections)
                (agent-ui--draw-section section ctx))
              (when sections
                (agent-ui--fold-refresh)))))))))

(defun agent-ui--stop-timers ()
  "Stop the current canvas's timers, and its components with them.
Its components go with it, panels' children too; the canvases its
sections hosted, on their own again."
  (dolist (id agent-ui--order)
    (run-hook-with-args 'agent-ui-removed-functions id)
    (agent-ui--children-stopped (agent-ui--entry-component (gethash id agent-ui--entries))
                                nil (agent-ui--key-section id)))
  (setq agent-ui--hosts (seq-remove (lambda (host) (eq (cadr host) (current-buffer))) agent-ui--hosts))
  (dolist (timer (list agent-ui--redraw-timer agent-ui--animation-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (setq agent-ui--redraw-timer nil
        agent-ui--animation-timer nil))

;; ====== COMPONENTS ======
;; Each component is kept by its key: its id, in a section SECTION/ID (see
;; SECTIONS below).  Looking one up by its id is done in the section
;; `agent-ui--in-section' says; by its key (a canvas's hooks, buttons and
;; timers get keys), in its own, whatever that says.

(defun agent-ui--key (id section)
  "The key of component ID in SECTION (a name; nil: the canvas's own).
ID, or SECTION/ID; ID itself if it's a key already (it has a /: an id
hasn't)."
  (if (or (null section) (not (stringp id)) (string-search "/" id))
      id
    (concat section "/" id)))

(defun agent-ui--key-section (key)
  "The section a component of key KEY is in: its name; nil for the canvas's own."
  (when-let* ((at (and (stringp key) (string-search "/" key))))
    (substring key 0 at)))

(defun agent-ui--key-id (key)
  "The id of the component of key KEY."
  (if-let* ((at (and (stringp key) (string-search "/" key))))
      (substring key (1+ at))
    key))

(defun agent-ui--unkeyed (text section)
  "TEXT with the keys of SECTION's components in it as their ids.
They're SECTION/ID: an answer's \"Answer to confirm ID\" drawn with its
component's key, as the section's components' agent knows them."
  (if (not section)
      text
    (replace-regexp-in-string (concat "\\(\\`\\|[^A-Za-z0-9_./-]\\)" (regexp-quote section) "/\\([A-Za-z0-9_.-]\\)")
                              "\\1\\2" text t)))

(defun agent-ui--section-keys (section)
  "The keys of the current canvas's components in SECTION, in their order.
SECTION is a name; nil: its own."
  (seq-filter (lambda (key) (equal (agent-ui--key-section key) section)) agent-ui--order))

(defun agent-ui--where (&optional section)
  "The current canvas, or its SECTION, as said in a message."
  (if section
      (format "section %s of canvas %s" section agent-ui--canvas-name)
    (format "canvas %s" agent-ui--canvas-name)))

(defun agent-ui--entry (id)
  "The current canvas's component ID (in `agent-ui--in-section').
Or of key ID; an error naming the others if none."
  (let ((key (agent-ui--key id agent-ui--in-section)))
    (or (and (stringp id) (gethash key agent-ui--entries))
        (let ((section (if (stringp key) (agent-ui--key-section key) agent-ui--in-section)))
          (agent-ui--fail "no component %s in %s; its components: %s"
                          (agent-ui--show-value (if (stringp key) (agent-ui--key-id key) id))
                          (agent-ui--where section)
                          (if-let* ((keys (agent-ui--section-keys section)))
                              (mapconcat #'agent-ui--key-id keys ", ")
                            "none"))))))

;; ====== A PANEL'S CHILDREN ======
;; A panel's children are components too, each its own id, unique in its
;; canvas (in its section): they're shown, updated, appended to, removed by
;; it, their panel (the canvas's component holding them) redrawn; their
;; sources started and stopped with them, by their keys.

(defun agent-ui--descendants (component)
  "COMPONENT's children, theirs...: a flat list."
  (cl-loop for child in (and (listp component) (plist-get component :children))
           when (agent-ui--plist-p child)
           append (cons child (agent-ui--descendants child))))

(defun agent-ui--children-named (component &optional id)
  "COMPONENT with each child of its (a panel's) without an id given one.
By its place: ID.N (ID COMPONENT's id, N from 1), its own children the same.
Their buttons, keys and updates are then theirs, not their panel's."
  (let ((id (or id (plist-get component :id)))
        (children (and (listp component) (plist-get component :children))))
    (if (not (and (stringp id) (consp children) (proper-list-p children)))
        component
      (let ((taken (delq nil (mapcar (lambda (c) (plist-get c :id)) (agent-ui--descendants component)))))
        (plist-put (copy-sequence component) :children
                   (cl-loop for child in children
                            for i from 1
                            collect (if (not (agent-ui--plist-p child))
                                        child
                                      (agent-ui--children-named
                                       (if (plist-get child :id)
                                           child
                                         (let ((new (format "%s.%d" id i)))
                                           (while (member new taken) (setq new (concat new "_")))
                                           (push new taken)
                                           (plist-put (copy-sequence child) :id new)))))))))))

(defun agent-ui--find-child (component id)
  "The descendant of COMPONENT with id ID, or nil."
  (seq-find (lambda (child) (equal (plist-get child :id) id)) (agent-ui--descendants component)))

(defun agent-ui--replace-child (component id new)
  "COMPONENT with its descendant ID replaced by NEW (removed, NEW nil)."
  (if (not (plist-get component :children))
      component
    (plist-put (copy-sequence component) :children
               (delq nil (mapcar (lambda (child)
                                   (if (equal (plist-get child :id) id)
                                       new
                                     (agent-ui--replace-child child id new)))
                                 (plist-get component :children))))))

(defun agent-ui--owner (id)
  "The current canvas's component (its entry) holding child ID.
In `agent-ui--in-section'; or of key ID; else nil."
  (let ((key (agent-ui--key id agent-ui--in-section)))
    (seq-find (lambda (entry) (agent-ui--find-child (agent-ui--entry-component entry) (agent-ui--key-id key)))
              (mapcar (lambda (top) (gethash top agent-ui--entries))
                      (agent-ui--section-keys (agent-ui--key-section key))))))

(defun agent-ui--resolve (id)
  "Component ID of the current canvas (in `agent-ui--in-section').
Or of key ID: (ENTRY . CHILD), CHILD nil for one of the canvas's own,
else the child of ENTRY's panel.  An error if none."
  (let ((key (and (stringp id) (agent-ui--key id agent-ui--in-section))))
    (if-let* ((entry (and key (gethash key agent-ui--entries))))
        (cons entry nil)
      (if-let* ((owner (and key (agent-ui--owner key))))
          (cons owner (agent-ui--find-child (agent-ui--entry-component owner) (agent-ui--key-id key)))
        (agent-ui--entry id)))))

(defun agent-ui--children-started (component &optional section)
  "COMPONENT's descendants shown (in SECTION).
Their sources started (`agent-ui-shown-functions', with their keys)."
  (dolist (child (agent-ui--descendants component))
    (when (plist-get child :id)
      (run-hook-with-args 'agent-ui-shown-functions (agent-ui--key (plist-get child :id) section) child))))

(defun agent-ui--children-stopped (component &optional keep section)
  "COMPONENT's descendants (in SECTION) gone, but those whose ids are in KEEP:
their sources stopped (`agent-ui-removed-functions', with their keys)."
  (dolist (child (agent-ui--descendants component))
    (let ((id (plist-get child :id)))
      (when (and id (not (member id keep)))
        (run-hook-with-args 'agent-ui-removed-functions (agent-ui--key id section))))))

(defun agent-ui--children-changed (old new &optional section)
  "A panel (in SECTION) changed from OLD to NEW.
The children gone stopped, the new ones started (those staying, left
running)."
  (let ((old-ids (delq nil (mapcar (lambda (c) (plist-get c :id)) (agent-ui--descendants old))))
        (new-ids (delq nil (mapcar (lambda (c) (plist-get c :id)) (agent-ui--descendants new)))))
    (agent-ui--children-stopped old new-ids section)
    (dolist (child (agent-ui--descendants new))
      (when (and (plist-get child :id) (not (member (plist-get child :id) old-ids)))
        (run-hook-with-args 'agent-ui-shown-functions (agent-ui--key (plist-get child :id) section) child)))))

(defun agent-ui--ids-free (component section &optional except)
  "An error if an id of COMPONENT or its descendants is taken in SECTION.
That's SECTION of the current canvas (but by the component of key EXCEPT,
its own place)."
  (let ((keys (agent-ui--section-keys section)))
    (dolist (id (cons (plist-get component :id)
                      (delq nil (mapcar (lambda (c) (plist-get c :id)) (agent-ui--descendants component)))))
      (when id
        (dolist (top keys)
          (unless (equal top except)
            (let ((other (agent-ui--entry-component (gethash top agent-ui--entries))))
              (when (or (and (equal (agent-ui--key-id top) id) (not (equal id (plist-get component :id))))
                        (agent-ui--find-child other id))
                (agent-ui--fail "the id %s is taken in %s" (agent-ui--show-value id) (agent-ui--where section))))))))))

(defun agent-ui--check-id (id)
  "An error unless ID is letters, digits, -, _ or ., as a string."
  (unless (and (stringp id) (string-match-p "\\`[A-Za-z0-9_.-]+\\'" id))
    (agent-ui--fail "an id is letters, digits, -, _ or ., not %s" (agent-ui--show-value id))))

(defun agent-ui--new-id (type)
  "A new id for a component of TYPE, in `agent-ui--in-section'."
  (let (id)
    (while (gethash (agent-ui--key (setq id (format "%s-%d" type (cl-incf agent-ui--counter))) agent-ui--in-section)
                    agent-ui--entries))
    id))

(defun agent-ui--checked (component)
  "COMPONENT, if it's right (its type known, its properties right).
Else an error saying what's wrong.  Its :type a string, as JSON gives
it."
  (let ((type (agent-ui-type (plist-get component :type))))
    (agent-ui-check type component)
    (let ((title (plist-get component :title))
          (caption (plist-get component :caption)))
      (when (and title (not (stringp title)))
        (agent-ui--fail "a title is text, not %s" (agent-ui--show-value title)))
      (when (and caption (not (stringp caption)))
        (agent-ui--fail "a caption is text, not %s" (agent-ui--show-value caption))))
    (when-let* ((source (plist-get component :source)))
      (funcall agent-ui-check-source-function source))
    ;; Its panel's children's too: started once it's in, a wrong one failed
    ;; then, half shown.
    (dolist (child (agent-ui--descendants component))
      (when-let* ((source (plist-get child :source)))
        (condition-case err
            (funcall agent-ui-check-source-function source)
          (agent-ui-error
           (agent-ui--fail "panel: child %s: %s" (or (plist-get child :id) (plist-get child :type))
                           (agent-ui-error-message err))))))
    (when-let* ((actions (plist-get component :actions)))
      (agent-ui-check-actions actions))
    (when-let* ((close (plist-get component :close)))
      (agent-ui-check-close close type))
    (when-let* ((with (plist-get component :with)))
      (unless (and (stringp with) (string-match-p "\\`[A-Za-z0-9_.-]+\\'" with))
        (agent-ui--fail "with: the id of the question it's shown with, not %s" (agent-ui--show-value with))))
    (agent-ui--prepared (plist-put (copy-sequence component) :type (symbol-name (agent-ui-type-name type))))))

(defun agent-ui--full-names (component)
  "COMPONENT with its files by their full names, under the agent's directory.
That's `agent-ui-file-directory': drawn later, wherever the canvas's
directory is; a :here one with none given, that directory, now."
  (let ((component (copy-sequence component)))
    (dolist (prop (agent-ui-type-props (agent-ui-type (plist-get component :type))))
      (when (eq (agent-ui-prop-kind prop) 'file)
        (let ((key (agent-ui-prop-key prop)))
          (cond
           ((stringp (plist-get component key))
            (setq component (plist-put component key (expand-file-name (plist-get component key)
                                                                   agent-ui-file-directory))))
           ((eq (agent-ui-prop-default prop) :here)
            (setq component (plist-put component key
                                     (file-name-as-directory
                                      (expand-file-name (or agent-ui-file-directory default-directory))))))))))
    component))

(defun agent-ui--source-dir (component)
  "COMPONENT with its source's dir a full name.
That's while `agent-ui-file-directory' is known (a request: the agent's
directory; a project dashboard's root): a relative one under it, none it.
Its source ran in its canvas's directory (that of whatever buffer was
current when the canvas was made)."
  (let ((source (plist-get component :source)))
    (if (and agent-ui-file-directory
             (agent-ui--plist-p source)
             (or (null (plist-get source :dir)) (stringp (plist-get source :dir))))
        (plist-put (copy-sequence component) :source
                   (plist-put (copy-sequence source) :dir
                              (file-name-as-directory
                               (expand-file-name (or (plist-get source :dir) ".") agent-ui-file-directory))))
      component)))

(defun agent-ui--prepared (component)
  "COMPONENT as it's kept.
Its files by their full names (`agent-ui--full-names'), its type's
:prepare, if it has one, its source's dir (`agent-ui--source-dir'); its
panel's children's too."
  (let* ((type (agent-ui-type (plist-get component :type)))
         (component (agent-ui--full-names component))
         (component (if-let* ((fn (agent-ui-type-prepare type))) (funcall fn component) component))
         (component (agent-ui--source-dir component))
         (children (plist-get component :children)))
    (if (and children (listp children))
        (plist-put (copy-sequence component) :children
                   (mapcar (lambda (c) (if (and (agent-ui--plist-p c) (plist-get c :type)) (agent-ui--prepared c) c))
                           children))
      component)))

(cl-defun agent-ui-show (component &key canvas section)
  "Show COMPONENT, a plist (:type, :id, :title, its type's properties).
It's shown in CANVAS (a buffer or a name; default
`agent-ui-default-canvas'), in its SECTION (a name; nil: the canvas's
own, see SECTIONS below).  A component
with its id there already is replaced in its place; a new one goes at the
end (of its section), drawn at once, and the canvas is shown if it's in no
window (`agent-ui-display-function').  Without an id, one is made.  Returns
the id.  Signals `agent-ui-error' if COMPONENT is wrong."
  (agent-ui--within (canvas section t)
    (let* ((section agent-ui--in-section)
           (id (or (plist-get component :id)
                   (agent-ui--new-id (plist-get component :type))))
           ;; Its children without an id given theirs.
           (component (agent-ui--children-named component id))
           (given component)
           (component (agent-ui--checked component))
           (component (plist-put component :id id))
           (given (plist-put (plist-put (copy-sequence given) :id id) :type (plist-get component :type)))
           (key (progn (agent-ui--check-id id) (agent-ui--key id section)))
           (entry (gethash key agent-ui--entries))
           (owner (and (not entry) (agent-ui--owner key))))
      (cond
       (owner
        ;; A panel's child: replaced in its place, its panel redrawn.
        (let ((old (agent-ui--find-child (agent-ui--entry-component owner) id)))
          ;; The panel with it replaced: its own children's ids checked too.
          (agent-ui--ids-free (agent-ui--replace-child (agent-ui--entry-component owner) id component)
                              section (agent-ui--entry-id owner))
          (setf (agent-ui--entry-component owner)
                (agent-ui--checked (agent-ui--replace-child (agent-ui--entry-component owner) id component))
                (agent-ui--entry-shown owner)
                (agent-ui--replace-child (or (agent-ui--entry-shown owner) (agent-ui--entry-component owner))
                                         id given))
          (run-hook-with-args 'agent-ui-removed-functions key)
          (agent-ui--children-stopped old nil section)
          (agent-ui--show-if-hidden)
          (agent-ui--dirty (list (agent-ui--entry-id owner)))))
       (entry
          (progn
            (agent-ui--ids-free component section key)
            (agent-ui--children-stopped (agent-ui--entry-component entry) nil section)
            (setf (agent-ui--entry-component entry) component
                  (agent-ui--entry-shown entry) given)
            (agent-ui--show-if-hidden)
            (agent-ui--dirty (list key))))
       (t
        (agent-ui--ids-free component section)
        (when (>= (length (agent-ui--section-keys section)) agent-ui-max-components)
          (agent-ui--fail "%s has %d components, the most it holds: remove some"
                          (agent-ui--where section) agent-ui-max-components))
        (let ((room (agent-ui--make-room (agent-ui--section-tail section))))
          (setq entry (agent-ui--make-entry :id key :component component :start (car room) :end (cdr room)
                                            :shown given :part agent-ui--in-part))
          (puthash key entry agent-ui--entries)
          (setq agent-ui--order (append agent-ui--order (list key)))
          ;; Drawn first, then the canvas shown if it's in no window: what
          ;; shows it sees what it shows (a session's views laid out by what
          ;; they hold); drawn again at its window's width then.
          (agent-ui--draw entry (agent-ui--context))
          (unless (agent-ui--window)
            (agent-ui--display (current-buffer)))
          (agent-ui--section-counted section)
          (agent-ui--animate))))
      (run-hook-with-args 'agent-ui-shown-functions key component)
      (agent-ui--children-started component section)
      (run-hooks 'agent-ui-changed-hook)
      id)))

(cl-defun agent-ui-update (id patch &key canvas section)
  "Change component ID of CANVAS (in its SECTION) by PATCH.
PATCH as in `agent-ui-merge'; redrawn `agent-ui-redraw-delay' from now.
Returns ID.
Signals `agent-ui-error' if there's no such component or the change makes it
wrong (then it's unchanged)."
  (agent-ui--within (canvas section)
    (agent-ui--change id (lambda (component) (agent-ui-merge component patch)))))

(defun agent-ui--change (id change)
  "Component ID of the current canvas (or a panel's child) changed by CHANGE.
CHANGE is a function of it returning it changed: checked, its panel's children
started or stopped as they came or went, redrawn soon.  Returns ID."
  (pcase-let* ((`(,entry . ,child) (agent-ui--resolve id))
               (key (agent-ui--entry-id entry))
               (section (agent-ui--key-section key))
               (old (or child (agent-ui--entry-component entry)))
               (new (agent-ui--checked (agent-ui--children-named (funcall change old) (plist-get old :id)))))
    (if child
        (let ((replaced (agent-ui--replace-child (agent-ui--entry-component entry) (plist-get child :id) new)))
          (agent-ui--ids-free replaced section key)
          (setf (agent-ui--entry-component entry) (agent-ui--checked replaced)))
      (agent-ui--ids-free new section key)
      (setf (agent-ui--entry-component entry) new))
    (agent-ui--children-changed old new section)
    (agent-ui--show-if-hidden)
    (agent-ui--dirty (list key))
    (run-hooks 'agent-ui-changed-hook)
    id))

(cl-defun agent-ui-append (id patch &key canvas section)
  "Add PATCH's lists to component ID of CANVAS (in its SECTION).
See `agent-ui-append-to'; as `agent-ui-update' changes it."
  (agent-ui--within (canvas section)
    (agent-ui--change id (lambda (component) (agent-ui-append-to component patch)))))

(defun agent-ui--empty-p ()
  "Whether the current canvas has nothing: no component, no section."
  (not (or agent-ui--order agent-ui--sections)))

(defun agent-ui--close-if-empty ()
  "The current canvas, without components (nor sections) now.
Its panes close, as a pane does with its last tab (it stayed open,
empty, after a clear).  A
window that showed something else before goes back to it (another canvas
it's a tab beside, a session's: `agent-ui-share-window-functions'); one it
alone showed is deleted, but a frame's last.  The canvas itself stays, with
its session (unless `agent-ui-close-emptied-functions' say, once it's
emptied: `agent-ui--close-emptied'); the next component shown opens a pane
again."
  (when (agent-ui--empty-p)
    ;; The current buffer kept: deleting a selected window selects another,
    ;; its buffer current then (what called this goes on in the canvas).
    (save-current-buffer
      (let ((canvas (current-buffer)))
        (dolist (window (get-buffer-window-list canvas nil t))
          (let* ((other (lambda (test)
                          (seq-some (lambda (entry) (and (buffer-live-p (car entry)) (not (eq (car entry) canvas))
                                                         (funcall test (car entry))))
                                    (window-prev-buffers window))))
                 (made (eq (car-safe (window-parameter window 'quit-restore)) 'window))
                 (before (funcall other #'always))
                 (canvas-before (funcall other (lambda (b) (eq (buffer-local-value 'major-mode b)
                                                               'agent-ui-canvas-mode)))))
            (cond ((and (not canvas-before) (or made (not before)) (eq (window-deletable-p window) t))
                   (delete-window window))
                  (before (switch-to-prev-buffer window 'bury)))))))))

(defun agent-ui--close-emptied (canvas)
  "CANVAS, left without components, killed if it's to be.
That's if `agent-ui-close-emptied-functions' say so (its panes closed
already: `agent-ui--close-if-empty').  Called once what emptied it is
done, outside it: its buffer current no more."
  (when (and (buffer-live-p canvas)
             (with-current-buffer canvas (agent-ui--empty-p))
             (run-hook-with-args-until-success 'agent-ui-close-emptied-functions canvas))
    (kill-buffer canvas)))

(cl-defun agent-ui-remove (id &key canvas section)
  "Remove component ID from CANVAS (from its SECTION).
Returns ID.  Its last one: CANVAS's panes closed, CANVAS killed if it's to be
\(`agent-ui--close-emptied')."
  (let ((buffer (agent-ui--buffer canvas)))
    (prog1 (agent-ui--within (canvas section) (agent-ui--remove id))
      (agent-ui--close-emptied buffer))))

(defun agent-ui--remove (id)
  "Remove component ID from the current canvas (see `agent-ui-remove').
The canvas kept.  Returns ID."
  (pcase (agent-ui--resolve id)
    (`(,owner . ,(and child (pred identity)))
     ;; A panel's child: out of its panel, redrawn.
     (let ((child-id (plist-get child :id))
           (section (agent-ui--key-section (agent-ui--entry-id owner))))
       (setf (agent-ui--entry-component owner)
             (agent-ui--checked (agent-ui--replace-child (agent-ui--entry-component owner) child-id nil))
             (agent-ui--entry-shown owner)
             (and (agent-ui--entry-shown owner) (agent-ui--replace-child (agent-ui--entry-shown owner) child-id nil)))
       (run-hook-with-args 'agent-ui-removed-functions (agent-ui--key child-id section))
       (agent-ui--children-stopped child nil section)
       (agent-ui--dirty (list (agent-ui--entry-id owner)))
       (run-hooks 'agent-ui-changed-hook)
       id))
    (`(,entry . ,_)
     (let* ((key (agent-ui--entry-id entry))
            (section (agent-ui--key-section key))
            (inhibit-read-only t))
       ;; Its text and the blank line after it.
       (delete-region (agent-ui--entry-start entry)
                      (min (point-max) (+ (agent-ui--entry-end entry) 2)))
       (set-marker (agent-ui--entry-start entry) nil)
       (set-marker (agent-ui--entry-end entry) nil)
       (remhash key agent-ui--entries)
       (setq agent-ui--order (delete key agent-ui--order)
             agent-ui--dirty (delete key agent-ui--dirty))
       (agent-ui--section-counted section)
       (agent-ui--animate)
       (run-hook-with-args 'agent-ui-removed-functions key)
       (agent-ui--children-stopped (agent-ui--entry-component entry) nil section)
       (run-hooks 'agent-ui-changed-hook)
       (agent-ui--close-if-empty)
       id))))

(cl-defun agent-ui-clear (&key canvas section)
  "Remove every component from CANVAS (if it's there), and its sections.
With SECTION (or CANVAS shown in another's section), that section's
components only.  CANVAS emptied: its panes closed, it killed if it's to be
\(`agent-ui--close-emptied')."
  (when (agent-ui--live-canvas-p canvas)
    (let ((buffer (agent-ui--buffer canvas)))
      (agent-ui--within (canvas section)
        ;; Each step in the canvas's own buffer, whatever the one before
        ;; made current (a hook selecting a window): its erase never
        ;; another's (an agent-shell session was erased whole so).
        (let ((self (current-buffer)))
          (if agent-ui--in-section
              (dolist (key (agent-ui--section-keys agent-ui--in-section))
                (with-current-buffer self (agent-ui--remove key)))
            (dolist (section (copy-sequence agent-ui--sections))
              (with-current-buffer self (agent-ui--remove-section section)))
            (dolist (id (copy-sequence agent-ui--order))
              (with-current-buffer self (agent-ui--remove id)))
            (with-current-buffer self
              (let ((inhibit-read-only t))
                (erase-buffer))
              (agent-ui--top-line)
              (run-hooks 'agent-ui-cleared-hook)
              (agent-ui--close-if-empty)))))
      (agent-ui--close-emptied buffer)))
  nil)

(cl-defun agent-ui-get (id &key canvas section)
  "Component ID of CANVAS (in its SECTION), a plist."
  (agent-ui--within (canvas section)
    (pcase-let ((`(,entry . ,child) (agent-ui--resolve id)))
      (copy-sequence (or child (agent-ui--entry-component entry))))))

(cl-defun agent-ui-shown-component (id &key canvas section)
  "Component ID of CANVAS (in its SECTION) as it was shown.
Before its updates, appends and its sources' changes (a panel's child
as its panel, or itself, was shown)."
  (agent-ui--within (canvas section)
    (pcase-let* ((`(,entry . ,child) (agent-ui--resolve id))
                 (shown (or (agent-ui--entry-shown entry) (agent-ui--entry-component entry))))
      (copy-sequence (if child (agent-ui--find-child shown (plist-get child :id)) shown)))))

(cl-defun agent-ui-components (&key canvas section)
  "CANVAS's components in order.
Its SECTION's; nil: its own, outside its sections: plists (:id ID :type
TYPE); none if it isn't there."
  (when (agent-ui--live-canvas-p canvas)
   (agent-ui--within (canvas section)
    (cl-loop for key in (agent-ui--section-keys agent-ui--in-section)
             for id = (agent-ui--key-id key)
             for component = (agent-ui--entry-component (gethash key agent-ui--entries))
             collect (list :id id :type (plist-get component :type))
             ;; A panel's children (with ids), after it.
             append (cl-loop for child in (agent-ui--descendants component)
                             when (plist-get child :id)
                             collect (list :id (plist-get child :id) :type (plist-get child :type) :panel id))))))

;; ====== SECTIONS ======
;; A canvas may be divided in sections, each under its divider: a rule
;; across the pane with its title and its state's mark (▾ review ● 3m ───).
;; The canvas's own components come first, then each section's, in their
;; order.  A section's components are its own: their ids too (another section
;; may have one so named).  The canvas keeps each by its key, SECTION/ID (an
;; id has no /: a key is never an id); its hooks, its buttons, its timers
;; get keys.  Each call (`agent-ui-show'...) is in a section, its :section,
;; or by keys (none given).  TAB (or RET, a click) on a divider folds its
;; section to it, and again unfolds it.
;;
;; A canvas, a session's, can be shown in a section of another
;; (`agent-ui-host'): everything shown in it (its session's other canvases
;; too) goes into that section, with no buffer or pane of its own; its
;; list, get and clear see that section only.

(cl-defstruct (agent-ui--section (:constructor agent-ui--make-section))
  "A section of a canvas: its NAME, TITLE, STATE (a symbol of
`agent-ui-section-states': its mark) and NOTE (after it), whether it's
FOLDED, where its divider is drawn (START and END markers, as an entry's: a
blank line after it), the OVERLAY hiding it folded, the canvas it HOSTS (a
name, or nil), what RET on its divider does (OPEN: a function, or nil:
folds it), what it says while it holds nothing (EMPTY: a line under its
divider, or nil)."
  name title state note folded start end overlay hosts open empty)

(defface agent-ui-section-title '((t :inherit agent-ui-title))
  "A section's title, on its divider."
  :group 'agent-ui)

(defface agent-ui-section-rule '((t :inherit agent-ui-muted))
  "A section's divider's rule."
  :group 'agent-ui)

(defconst agent-ui-section-states
  '((running "●" agent-ui-accent "running")
    (needs-you "◆" agent-ui-warning "needs you")
    (waiting "○" agent-ui-muted "waiting")
    (paused "‖" agent-ui-muted "paused")
    (done "✓" agent-ui-success "done")
    (failed "✗" agent-ui-error "failed"))
  "A section's states: (STATE MARK FACE WORDS).
Its MARK drawn after its title in FACE (running's glowing, as a
spinner), WORDS said over it.")

(defvar agent-ui-host-functions nil
  "Called with a canvas's name, a canvas's buffer and a section's name.
That's once the first is shown in that section (`agent-ui-host').")

(defvar-keymap agent-ui-section-map
  :doc "Keys of a section's divider."
  "TAB" #'agent-ui-section-toggle
  "<tab>" #'agent-ui-section-toggle
  "RET" #'agent-ui-section-open
  "<mouse-1>" #'agent-ui-section-toggle
  "<mouse-2>" #'agent-ui-section-toggle
  "<follow-link>" 'mouse-face)

(defun agent-ui--find-section (name)
  "The current canvas's section NAME, or nil."
  (and name (seq-find (lambda (section) (equal (agent-ui--section-name section) name)) agent-ui--sections)))

(defun agent-ui--check-section-name (name)
  "NAME if it's a section's (as an id: letters, digits, -, _ or .).
Else an error."
  (unless (and (stringp name) (<= (length name) 60) (string-match-p "\\`[A-Za-z0-9_.-]+\\'" name))
    (agent-ui--fail "a section's name is letters, digits, -, _ or ., not %s" (agent-ui--show-value name)))
  name)

(defun agent-ui--check-state (state)
  "STATE, a section's, as a symbol of `agent-ui-section-states'.
It's a symbol or a string; nil: none; else an error."
  (let ((symbol (if (stringp state) (intern-soft state) state)))
    (cond ((memq state '(nil :false)) nil)
          ((assq symbol agent-ui-section-states) symbol)
          (t (agent-ui--fail "a section's state is one of %s, or none; not %s"
                             (mapconcat (lambda (s) (symbol-name (car s))) agent-ui-section-states ", ")
                             (agent-ui--show-value state))))))

(defun agent-ui--section-tail (section)
  "Where what's added at the end of SECTION goes.
SECTION is a name; nil: the canvas's own components.  After its last
component's blank line, else after its divider's; the canvas's own, else
at its start, under its top line."
  (if-let* ((last (car (last (agent-ui--section-keys section)))))
      (+ (agent-ui--entry-end (gethash last agent-ui--entries)) 2)
    (if section
        (+ (agent-ui--section-end (agent-ui--find-section section)) 2)
      (agent-ui--start))))

(defun agent-ui--make-room (pos)
  "Room at POS of the current canvas for something new before what's there:
its blank line inserted, a divider starting at POS moved after it.  Returns
\(START . END): markers at POS, END following what's inserted at it."
  (let ((inhibit-read-only t)
        (next (seq-find (lambda (section) (= (agent-ui--section-start section) pos)) agent-ui--sections)))
    (save-excursion
      (goto-char pos)
      (insert "\n\n"))
    (when next
      (set-marker (agent-ui--section-start next) (+ pos 2)))
    (cons (copy-marker pos) (copy-marker pos t))))

(defun agent-ui--divider (section ctx)
  "SECTION's divider, drawn for CTX.
Its fold's arrow, its title, its state's mark, its note, folded how
many components it holds, a rule to the width."
  (let* ((width (max 10 (or (plist-get ctx :width) agent-ui-default-width)))
         (folded (agent-ui--section-folded section))
         (state (assq (agent-ui--section-state section) agent-ui-section-states))
         (note (agent-ui--section-note section))
         (held (and folded (length (agent-ui--section-keys (agent-ui--section-name section)))))
         (help (format "TAB: %s this section%s" (if folded "unfold" "fold")
                       (if (agent-ui--section-open section) "; RET: open what it shows" "")))
         (one-line (lambda (text) (replace-regexp-in-string "[\n\r]+" " " text)))
         (head (concat (propertize (if folded "▸" "▾") 'face 'agent-ui-muted 'help-echo help)
                       (propertize " " 'help-echo help)
                       (propertize (funcall one-line (or (agent-ui--section-title section) (agent-ui--section-name section)))
                                   'face 'agent-ui-section-title 'help-echo help)
                       (when state
                         (concat " " (propertize (if (eq (car state) 'running)
                                                     (agent-ui-spinner ctx (nth 2 state))
                                                   (propertize (nth 1 state) 'face (nth 2 state)))
                                                 'help-echo (nth 3 state))))
                       (when (and note (not (string-empty-p note)))
                         (concat " " (propertize (funcall one-line note) 'face 'agent-ui-muted 'help-echo help)))
                       (when (and held (> held 0))
                         (propertize (format " · %d hidden" held) 'face 'agent-ui-muted 'help-echo help))))
         (head (agent-ui-truncate head (- width 2))))
    (concat (propertize head 'mouse-face 'highlight)
            " "
            (propertize (make-string (max 1 (- width (string-width head) 1)) ?─)
                        'face 'agent-ui-section-rule 'help-echo help)
            ;; Holding nothing, unfolded: what it says then, under it.
            (when-let* ((empty (agent-ui--section-empty section))
                        ((not (string-empty-p empty)))
                        ((not folded))
                        ((null (agent-ui--section-keys (agent-ui--section-name section)))))
              (concat "\n\n" (propertize (agent-ui-truncate (funcall one-line empty) width)
                                          'face 'agent-ui-muted 'help-echo help))))))

(defun agent-ui--draw-section (section ctx)
  "Draw SECTION's divider again for CTX, in its place.
As `agent-ui--draw' a component."
  (agent-ui--drawn-at ctx)
  (let* ((inhibit-read-only t)
         (start (agent-ui--section-start section))
         (end (agent-ui--section-end section))
         (places (agent-ui--places-in start end)))
    (save-excursion
      (delete-region start end)
      (goto-char start)
      (insert (propertize (agent-ui--even (agent-ui--divider section ctx))
                          'agent-ui-section (agent-ui--section-name section)
                          'keymap agent-ui-section-map))
      (set-marker end (point)))
    (when places
      (agent-ui--restore-places places start end))))

(defun agent-ui--dirty-section (section)
  "SECTION's divider redrawn soon (with the components by then)."
  (cl-pushnew (agent-ui--section-name section) agent-ui--dirty-sections :test #'equal)
  (agent-ui--dirty nil))

(defun agent-ui--section-counted (name)
  "A component came into section NAME (a name; nil: none) or left it.
Its divider redrawn if it says how many it holds (folded) or what it says
holding nothing (empty), its fold kept on what it holds."
  (when-let* ((section (agent-ui--find-section name)))
    (when (or (agent-ui--section-folded section) (agent-ui--section-empty section))
      (agent-ui--dirty-section section)))
  (agent-ui--fold-refresh))

;; ------ Folding ------

(defun agent-ui--fold-refresh ()
  "The current canvas's folded sections hidden but their dividers.
From the end of a divider's line to the next divider (or the canvas's
end)."
  (cl-loop for (section next) on agent-ui--sections
           do (let ((overlay (agent-ui--section-overlay section)))
                (if (not (agent-ui--section-folded section))
                    (when overlay
                      (delete-overlay overlay)
                      (setf (agent-ui--section-overlay section) nil))
                  (let ((beg (min (point-max) (1+ (agent-ui--section-end section))))
                        (end (if next (agent-ui--section-start next) (point-max))))
                    (if overlay
                        (move-overlay overlay beg end)
                      (setq overlay (make-overlay beg end nil t nil))
                      (overlay-put overlay 'invisible t)
                      (overlay-put overlay 'agent-ui-fold (agent-ui--section-name section))
                      (overlay-put overlay 'isearch-open-invisible #'agent-ui--fold-opened)
                      (setf (agent-ui--section-overlay section) overlay)))))))

(defun agent-ui--fold (section fold)
  "SECTION of the current canvas folded (FOLD non-nil) or unfolded.
Its divider redrawn; folded, the points inside it put on its divider."
  (unless (eq (and fold t) (agent-ui--section-folded section))
    (setf (agent-ui--section-folded section) (and fold t))
    (agent-ui--fold-refresh)
    (when-let* ((fold)
                (overlay (agent-ui--section-overlay section))
                (divider (marker-position (agent-ui--section-start section))))
      (let ((inside (lambda (pos) (and (>= pos (overlay-start overlay)) (< pos (overlay-end overlay))))))
        (when (funcall inside (point))
          (goto-char divider))
        (dolist (window (get-buffer-window-list (current-buffer) nil t))
          (when (funcall inside (window-point window))
            (set-window-point window divider)))))
    (agent-ui--dirty-section section)))

(defun agent-ui--fold-opened (overlay)
  "OVERLAY's section unfolded: isearch found something in it."
  (with-current-buffer (overlay-buffer overlay)
    (when-let* ((section (agent-ui--find-section (overlay-get overlay 'agent-ui-fold))))
      (agent-ui--fold section nil)
      (agent-ui--flush))))

(defun agent-ui-section-toggle (&optional event)
  "Fold the section whose divider is at point (or EVENT's, a click).
Or unfold it."
  (interactive (list last-nonmenu-event))
  (let* ((mouse (mouse-event-p event))
         (pos (if mouse (posn-point (event-end event)) (point)))
         (buffer (if mouse (window-buffer (posn-window (event-end event))) (current-buffer))))
    (with-current-buffer buffer
      (when mouse
        (deactivate-mark))
      (let ((section (agent-ui--find-section (get-text-property pos 'agent-ui-section))))
        (unless section
          (user-error "No section's divider here"))
        (agent-ui--fold section (not (agent-ui--section-folded section)))
        (agent-ui--flush)))))

(defun agent-ui-section-open ()
  "What RET on the section's divider at point does.
Its :open (its session, an agent workflow's agent's), else fold it, or
unfold it."
  (interactive)
  (let ((section (agent-ui--find-section (get-text-property (point) 'agent-ui-section))))
    (unless section
      (user-error "No section's divider here"))
    (if-let* ((open (agent-ui--section-open section)))
        (funcall open)
      (agent-ui-section-toggle))))

(defun agent-ui-reveal (id &optional canvas)
  "Component ID of CANVAS (default: the current buffer, ID a key) in view.
Its section unfolded, drawn, each window showing CANVAS scrolled to it
if it starts out of its view."
  (agent-ui--in (or canvas (current-buffer))
    (pcase-let ((`(,entry . ,_) (agent-ui--resolve id)))
      (when-let* ((section (agent-ui--find-section (agent-ui--key-section (agent-ui--entry-id entry)))))
        (agent-ui--fold section nil))
      (agent-ui--flush)
      (let ((pos (marker-position (agent-ui--entry-start entry))))
        (dolist (window (get-buffer-window-list (current-buffer) nil t))
          (unless (pos-visible-in-window-p pos window)
            (set-window-start window (save-excursion (goto-char pos) (line-beginning-position)))))))))

;; ------ Making, changing, removing ------

(cl-defun agent-ui-section (canvas name &key (title nil title-p) (state nil state-p) (note nil note-p)
                                   (folded nil folded-p) (open nil open-p) (empty nil empty-p) after)
  "Make section NAME of CANVAS, or change it.
CANVAS is a buffer, or a canvas's name: made if it isn't there.  TITLE:
what its divider says (default: NAME);
STATE: its mark, one of `agent-ui-section-states' (`running', `needs-you',
`waiting', `paused', `done', `failed'; nil: none); NOTE: a few words after
it (3m); FOLDED: folded to its divider; OPEN: a function RET on its
divider calls (else RET folds it, as TAB); EMPTY: a line it shows under
its divider while it holds nothing (an agent's that has shown nothing
yet).  A new one goes AFTER section AFTER
\(its components), else at the end; the canvas shown if it's in no window.
Given again, only what's given changes.  Returns NAME.  Signals
`agent-ui-error' if something's wrong."
  (agent-ui--check-section-name name)
  (dolist (text (list (and title-p title) (and note-p note) (and empty-p empty)))
    (when (and text (not (stringp text)))
      (agent-ui--fail "section %s: a title or a note is text, not %s" name (agent-ui--show-value text))))
  (let ((state (and state-p (agent-ui--check-state state))))
    (agent-ui--within (canvas nil t)
      (when agent-ui--in-section
        (agent-ui--fail "canvas %s is shown in section %s of canvas %s: it has no sections"
                        canvas agent-ui--in-section agent-ui--canvas-name))
      (if-let* ((section (agent-ui--find-section name)))
          (progn
            (when title-p (setf (agent-ui--section-title section) title))
            (when state-p (setf (agent-ui--section-state section) state))
            (when note-p (setf (agent-ui--section-note section) note))
            (when folded-p (agent-ui--fold section folded))
            (when open-p (setf (agent-ui--section-open section) open))
            (when empty-p (setf (agent-ui--section-empty section) empty))
            (agent-ui--dirty-section section)
            (agent-ui--animate))
        (when (and after (not (agent-ui--find-section after)))
          (agent-ui--fail "canvas %s has no section %s to put %s after" agent-ui--canvas-name
                          (agent-ui--show-value after) name))
        (let* ((room (agent-ui--make-room (if after (agent-ui--section-tail after) (point-max))))
               (section (agent-ui--make-section :name name :title title :state state :note note :open open
                                                :empty empty :folded (and folded t) :start (car room) :end (cdr room)))
               (at (and after (1+ (cl-position after agent-ui--sections
                                               :key #'agent-ui--section-name :test #'equal)))))
          (setq agent-ui--sections (if at
                                       (append (seq-take agent-ui--sections at) (list section)
                                               (seq-drop agent-ui--sections at))
                                     (append agent-ui--sections (list section))))
          (unless (agent-ui--window)
            (agent-ui--display (current-buffer)))
          (agent-ui--draw-section section (agent-ui--context))
          (agent-ui--fold-refresh)
          (agent-ui--animate)))
      (run-hooks 'agent-ui-changed-hook)
      name)))

(defun agent-ui-sections (&optional canvas)
  "CANVAS's sections, in order.
Plists (:name :title :state :note :folded :hosts :empty :components),
:components how many it holds; none if it isn't there."
  (when-let* ((buffer (ignore-error agent-ui-error (agent-ui--canvas-buffer canvas nil))))
    (with-current-buffer buffer
      (mapcar (lambda (section)
                (list :name (agent-ui--section-name section)
                      :title (or (agent-ui--section-title section) (agent-ui--section-name section))
                      :state (agent-ui--section-state section)
                      :note (agent-ui--section-note section)
                      :folded (agent-ui--section-folded section)
                      :hosts (agent-ui--section-hosts section)
                      :empty (agent-ui--section-empty section)
                      :components (length (agent-ui--section-keys (agent-ui--section-name section)))))
              agent-ui--sections))))

(defun agent-ui--remove-section (section)
  "SECTION of the current canvas gone.
Its components, its divider; the canvas it hosted, on its own again."
  (let ((name (agent-ui--section-name section))
        (inhibit-read-only t))
    (dolist (key (agent-ui--section-keys name))
      (agent-ui--remove key))
    (delete-region (agent-ui--section-start section)
                   (min (point-max) (+ (agent-ui--section-end section) 2)))
    (set-marker (agent-ui--section-start section) nil)
    (set-marker (agent-ui--section-end section) nil)
    (when (agent-ui--section-overlay section)
      (delete-overlay (agent-ui--section-overlay section)))
    (setq agent-ui--sections (delq section agent-ui--sections)
          agent-ui--dirty-sections (delete name agent-ui--dirty-sections)
          agent-ui--hosts (seq-remove (lambda (host) (and (eq (cadr host) (current-buffer)) (equal (cddr host) name)))
                                      agent-ui--hosts))
    (agent-ui--fold-refresh)
    (agent-ui--animate)))

(defun agent-ui-remove-section (canvas name)
  "Remove section NAME of CANVAS.
Its components, its divider; the canvas it hosted (`agent-ui-host') gets
its own again, with its next component.  CANVAS emptied: its panes
closed, it killed if it's to be.  Returns NAME."
  (let ((buffer (agent-ui--canvas-buffer canvas nil)))
    (with-current-buffer buffer
      (let ((section (or (agent-ui--find-section name)
                         (agent-ui--fail "canvas %s has no section %s" agent-ui--canvas-name (agent-ui--show-value name)))))
        (agent-ui--remove-section section)
        (run-hooks 'agent-ui-changed-hook)
        (agent-ui--close-if-empty)))
    (agent-ui--close-emptied buffer)
    name))

;; ------ A canvas shown in another's section ------

(defun agent-ui--hosted (canvas)
  "Where CANVAS (a name) is shown, if it's in a section of another.
That's `agent-ui-host': (BUFFER SECTION PART), PART the session's other canvas
it is (\"ask\" for \"SESSION / ask\"), nil for its own; else nil."
  (when (stringp canvas)
    (cl-loop for (name buffer . section) in agent-ui--hosts
             for prefix = (concat name agent-ui-canvas-separator)
             when (and (or (equal canvas name) (string-prefix-p prefix canvas))
                       (buffer-live-p buffer)
                       (with-current-buffer buffer (agent-ui--find-section section)))
             return (list buffer section (and (not (equal canvas name)) (substring canvas (length prefix)))))))

(defun agent-ui-host (name canvas section)
  "Show canvas NAME (a session's: its other canvases, \"NAME / PART\", too)
in SECTION of CANVAS from now on: what's shown in it goes there (see
SECTIONS above), with no buffer or pane of its own.  Its canvases there
already: their components shown in SECTION, in order, and they're closed.
Until SECTION's removed, or `agent-ui-unhost'.  Returns NAME."
  (unless (and (stringp name) (not (string-empty-p name)))
    (agent-ui--fail "a canvas to show in a section: its name, not %s" (agent-ui--show-value name)))
  (let ((host (agent-ui--canvas-buffer canvas nil))
        (prefix (concat name agent-ui-canvas-separator)))
    (with-current-buffer host
      (when (or (equal agent-ui--canvas-name name) (string-prefix-p prefix agent-ui--canvas-name))
        (agent-ui--fail "canvas %s can't be shown in its own section" name))
      (unless (agent-ui--find-section section)
        (agent-ui--fail "canvas %s has no section %s" agent-ui--canvas-name (agent-ui--show-value section))))
    (when (agent-ui--hosted (buffer-local-value 'agent-ui--canvas-name host))
      (agent-ui--fail "canvas %s is shown in another's section: it has none of its own"
                      (buffer-local-value 'agent-ui--canvas-name host)))
    (agent-ui-unhost name)
    (let ((own (seq-filter (lambda (buffer)
                             (let ((other (buffer-local-value 'agent-ui--canvas-name buffer)))
                               (or (equal other name) (string-prefix-p prefix other))))
                           (agent-ui-canvases))))
      (push (cons name (cons host section)) agent-ui--hosts)
      (with-current-buffer host
        (setf (agent-ui--section-hosts (agent-ui--find-section section)) name))
      ;; What they show, into it, by their names: the session's own first.
      (dolist (buffer (sort own (lambda (a _b) (equal (buffer-local-value 'agent-ui--canvas-name a) name))))
        (let ((as (buffer-local-value 'agent-ui--canvas-name buffer)))
          (dolist (key (with-current-buffer buffer (agent-ui--section-keys nil)))
            (with-demoted-errors "Agent UI: %S"
              (agent-ui-show (agent-ui-get key :canvas buffer) :canvas as)))
          (kill-buffer buffer)))
      (run-hook-with-args 'agent-ui-host-functions name host section)
      name)))

(defun agent-ui-unhost (name &optional keep)
  "Canvas NAME no longer shown in a section of another (`agent-ui-host'):
its components there removed (KEEP: kept, the section's own now, as they
were), its next component on a canvas of its own."
  (when-let* ((host (assoc name agent-ui--hosts)))
    (setq agent-ui--hosts (delq host agent-ui--hosts))
    (let ((buffer (cadr host)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when-let* ((section (agent-ui--find-section (cddr host))))
            (setf (agent-ui--section-hosts section) nil)
            (unless keep
              (dolist (key (agent-ui--section-keys (cddr host)))
                (with-current-buffer buffer (agent-ui--remove key))))
            (run-hooks 'agent-ui-changed-hook)))))
    name))


(provide 'agent-ui-canvas)

;;; agent-ui-canvas.el ends here
