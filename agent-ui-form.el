;;; agent-ui-form.el --- The form component  -*- lexical-binding: t; -*-

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

;; Agent UI's form: several fields answered together (a new ticket's
;; details).
;;
;; On the canvas, its fields and their values, and Fill in: RET opens the form
;; in a buffer of its own, its fields vui.el's (typed, validated as you type:
;; text, a number within a range, yes / no, one of, a file), not inline (the
;; canvas redraws its regions itself: two renderers on one region would
;; fight).  There, Send (C-c C-c) puts "Answer to form ID (QUESTION): {JSON of
;; the values}" into the session's prompt (sent at once); then the
;; form is answered on the canvas, and can't be changed.  Cancel (C-c C-k)
;; closes it, what was typed kept.  Its values are the component's own (:values,
;; saved with the session), as each one is typed.  In a terminal: the same
;; buffer (vui is text).
;;
;;   What should the ticket say?
;;    Title     Fix the parser
;;    Priority  2
;;    Type      bug
;;    Blocking  no
;;    ⏵ Fill in

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'agent-ui-ask)
(require 'vui)
(require 'vui-components)

(defconst agent-ui-form--types '("text" "integer" "number" "boolean" "select" "file" "directory")
  "A field's types.")

(defconst agent-ui-form--keys '(:name :label :type :required :min :max :options :placeholder :value)
  "What a field has.")

;; ====== ITS FIELDS AND VALUES ======

(defun agent-ui-form--key (name)
  "Field NAME's key in the values (a plist): :NAME."
  (intern (concat ":" name)))

(defun agent-ui-form--type (field)
  "FIELD's type, \"text\" when it has none."
  (or (plist-get field :type) "text"))

(defun agent-ui-form--label (field)
  "FIELD's label, its name when it has none."
  (or (plist-get field :label) (plist-get field :name)))

(defun agent-ui-form--values (props)
  "PROPS' values: the user's, else each field's own (its default)."
  (let ((values (copy-sequence (plist-get props :values))))
    (dolist (field (plist-get props :fields))
      (let ((key (agent-ui-form--key (plist-get field :name))))
        (unless (plist-member values key)
          (when (plist-member field :value)
            (setq values (plist-put values key (plist-get field :value)))))))
    values))

(defun agent-ui-form--empty-p (value)
  "Non-nil when VALUE is empty: nil, false or a blank string."
  (or (null value) (eq value :false) (and (stringp value) (string-blank-p value))))

(defun agent-ui-form--missing (props values)
  "Return the labels of PROPS' required fields VALUES leaves empty.
A yes / no one is never empty."
  (cl-loop for field in (plist-get props :fields)
           when (and (eq (plist-get field :required) t)
                     (not (equal (agent-ui-form--type field) "boolean"))
                     (agent-ui-form--empty-p (plist-get values (agent-ui-form--key (plist-get field :name)))))
           collect (agent-ui-form--label field)))

(defun agent-ui-form--answer (id props values)
  "Return VALUES as the agent reads them, of form ID with PROPS.
\"Answer to form ID (QUESTION): {JSON}\", each field there (yes / no
as true / false, an empty one null)."
  (let ((object (cl-loop for field in (plist-get props :fields)
                         for name = (plist-get field :name)
                         for value = (plist-get values (agent-ui-form--key name))
                         nconc (list (agent-ui-form--key name)
                                     (cond ((equal (agent-ui-form--type field) "boolean") (if (eq value t) t :false))
                                           ((agent-ui-form--empty-p value) :null)
                                           (t value))))))
    (format "Answer to form %s%s: %s" id
            (if-let* ((question (plist-get props :question))) (format " (%s)" question) "")
            (decode-coding-string (json-serialize object) 'utf-8))))

;; ====== CHECKING ======

(defun agent-ui-form--check-field (field i)
  "Check FIELD, the Ith of its form, or fail with what is wrong."
  (cl-flet ((bad (fmt &rest args) (agent-ui--fail "form: field %d %s" i (apply #'format fmt args))))
    (unless (agent-ui--plist-p field)
      (bad "must be {\"name\": ..., \"type\": ...}"))
    (cl-loop for (k _) on field by #'cddr
             unless (memq k agent-ui-form--keys)
             do (bad "has %s: a field has name, label, type, required, min, max, options, placeholder, value"
                     (agent-ui--show-value (substring (symbol-name k) 1))))
    (let ((name (plist-get field :name))
          (type (agent-ui-form--type field)))
      (unless (and (stringp name) (string-match-p "\\`[A-Za-z_][A-Za-z0-9_-]*\\'" name))
        (bad "has no name, or not one of letters, digits, _ and -"))
      (unless (member type agent-ui-form--types)
        (bad "has type %s; one of: %s" (agent-ui--show-value type) (string-join agent-ui-form--types ", ")))
      (dolist (k '(:label :placeholder))
        (when (and (plist-get field k) (not (stringp (plist-get field k))))
          (bad "has a %s that isn't text" (substring (symbol-name k) 1))))
      (dolist (k '(:min :max))
        (when (plist-member field k)
          (unless (member type '("integer" "number"))
            (bad "has %s: only a number has one" (substring (symbol-name k) 1)))
          (unless (numberp (plist-get field k))
            (bad "has a %s that isn't a number" (substring (symbol-name k) 1)))))
      (if (equal type "select")
          (let ((options (plist-get field :options)))
            (unless (and options (listp options) (cl-every (lambda (o) (and (stringp o) (not (string-blank-p o)))) options))
              (bad "is a select: give its options, [\"bug\", \"task\"]")))
        (when (plist-member field :options)
          (bad "has options: only a select has them")))
      (unless (memq (plist-get field :required) '(nil t :false))
        (bad "has required that isn't true or false"))
      ;; Its value one its type takes (Send failed, or sent it as it was).
      (when-let* ((value (plist-get field :value)))
        (unless (pcase type
                  ((or "text" "file" "directory") (stringp value))
                  ("integer" (integerp value))
                  ("number" (numberp value))
                  ("boolean" (memq value '(t :false)))
                  ("select" (member value (plist-get field :options)))
                  (_ t))
          (bad "has value %s: %s" (agent-ui--show-value value)
               (pcase type
                 ("select" "not one of its options")
                 ("integer" "not an integer")
                 ((or "text" "file" "directory") "not text")
                 (_ (format "not a %s" type)))))
        (when (numberp value)
          (when (and (numberp (plist-get field :min)) (< value (plist-get field :min)))
            (bad "has value %s, under its min %s" (agent-ui--show-value value) (plist-get field :min)))
          (when (and (numberp (plist-get field :max)) (> value (plist-get field :max)))
            (bad "has value %s, over its max %s" (agent-ui--show-value value) (plist-get field :max))))))))

(defun agent-ui-form--check (props)
  "Check form PROPS (its fields and values), or fail; return PROPS."
  (let ((fields (plist-get props :fields)))
    (unless fields
      (agent-ui--fail "form: give its fields: [{\"name\": \"title\", \"type\": \"text\"}, ...]"))
    (cl-loop for field in fields for i from 1 do (agent-ui-form--check-field field i))
    (let ((names (mapcar (lambda (f) (plist-get f :name)) fields)))
      (when (/= (length names) (length (delete-dups (copy-sequence names))))
        (agent-ui--fail "form: two fields have the same name"))
      (let ((values (plist-get props :values)))
        (unless (or (null values) (agent-ui--plist-p values))
          (agent-ui--fail "form: values are an object, {\"title\": ...}"))
        (cl-loop for (k _) on values by #'cddr
                 unless (member (substring (symbol-name k) 1) names)
                 do (agent-ui--fail "form: values has %s, not a field" (substring (symbol-name k) 1))))))
  props)

;; ====== ON THE CANVAS ======

(defun agent-ui-form--shown (field value)
  "VALUE of FIELD as the canvas shows it."
  (cond
   ((equal (agent-ui-form--type field) "boolean") (if (eq value t) "yes" "no"))
   ((agent-ui-form--empty-p value) (propertize "—" 'face 'agent-ui-muted))
   ((numberp value) (agent-ui-format-number value))
   (t (replace-regexp-in-string "[\n\r]+" " " (format "%s" value)))))

(defun agent-ui-form--draw (props ctx)
  "Draw form PROPS on the canvas, laid out as CTX says."
  (let* ((width (plist-get ctx :width))
         (values (agent-ui-form--values props))
         (fields (plist-get props :fields))
         (label-width (min (apply #'max 0 (mapcar (lambda (f) (string-width (agent-ui-form--label f))) fields))
                           (max 6 (/ width 3))))
         (question (plist-get props :question)))
    (string-join
     (append
      (and question (list (propertize (agent-ui-wrap question width) 'face 'bold)))
      ;; Each field a row: its label wrapped in its column, its value in the
      ;; rest, the row as tall as the taller (they were cut with …, their
      ;; rest nowhere).
      (mapcar (lambda (field)
                (let* ((value-width (max 1 (- width label-width 3)))
                       (fit (lambda (text room)
                              (if (<= (string-width text) room) (list text) (agent-ui-wrap-lines text room))))
                       (labels (funcall fit (agent-ui-form--label field) label-width))
                       (shown (funcall fit (agent-ui-form--shown field (plist-get values (agent-ui-form--key (plist-get field :name))))
                                       value-width)))
                  (string-join
                   (cl-loop for i below (max (length labels) (length shown))
                            collect (let ((label (or (nth i labels) "")))
                                      (if (nth i shown)
                                          (concat " " (propertize (agent-ui-pad label label-width) 'face 'agent-ui-muted)
                                                  "  " (nth i shown))
                                        (concat " " (propertize label 'face 'agent-ui-muted)))))
                   "\n")))
              fields)
      (cond
       ((agent-ui-ask-answered-p props)
        (list (concat " " (propertize "✓ " 'face 'agent-ui-success) (propertize "Sent" 'face 'agent-ui-muted))))
       ((plist-get ctx :still) nil)
       (t
        (let ((canvas (current-buffer))
              (id (plist-get ctx :id)))
          (list (concat " " (agent-ui-button (propertize "⏵ Fill in" 'face 'agent-ui-action)
                                             (lambda () (agent-ui-form-open canvas id))
                                             "RET: fill the form in, in a buffer of its own")))))))
     "\n")))

;; ====== ITS BUFFER (vui) ======

(defvar agent-ui-pane-view-of)
(defvar-local agent-ui-form--canvas nil "In a form's buffer: its canvas.")
(defvar-local agent-ui-form--id nil "In a form's buffer: its component's id.")
(defvar-local agent-ui-form--window nil
  "In a form's buffer: the canvas's window it was opened in.
\(WINDOW . DEDICATED), DEDICATED whether that window was dedicated; nil
when it was opened in a window of its own.")

(defvar agent-ui-form-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c C-c" #'agent-ui-form-send)
    (keymap-set map "C-c C-k" #'agent-ui-form-cancel)
    map)
  "Keys of a form's buffer: a minor mode's, above its fields' own maps.")

(define-minor-mode agent-ui-form-keys-mode
  "A form's keys.
\\<agent-ui-form-keys-mode-map>\\[agent-ui-form-send] sends it, \\[agent-ui-form-cancel] cancels it."
  :keymap agent-ui-form-keys-mode-map)

(defun agent-ui-form--self-insert ()
  "Typing in a field; outside one, nothing (vui's mode is special-mode's)."
  (interactive)
  (if (widget-field-at (point))
      (call-interactively #'self-insert-command)
    (undefined)))

(defvar agent-ui-form-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "<remap> <self-insert-command>" #'agent-ui-form--self-insert)
    map))


;; vui's mode is the parent: TAB to the next field, a field's keys.
(define-derived-mode agent-ui-form-mode vui-mode "Agent UI form"
  "A form of Agent UI's, filled in: its fields vui's (TAB to the next).
\\{agent-ui-form-keys-mode-map}"
  (agent-ui-form-keys-mode 1))

(defun agent-ui-form--buffer-name (canvas id)
  "Name of the buffer of form ID of CANVAS.
Its canvas's name in it: two canvases' forms of the same id (two
sessions') each in a buffer of its own."
  (format "*Agent UI form: %s · %s*"
          (or (buffer-local-value 'agent-ui--canvas-name canvas) (buffer-name canvas))
          id))

(defun agent-ui-form--set-value (canvas id name value)
  "Set field NAME to VALUE, typed, in form ID on CANVAS.
It goes to the form's own state, and to its component's values on
CANVAS (the canvas follows, it's saved)."
  (vui-set-state :values (lambda (old) (plist-put (copy-sequence old) (agent-ui-form--key name) value)))
  (when (buffer-live-p canvas)
    (ignore-error agent-ui-error
      (let ((component (agent-ui-get id :canvas canvas)))
        (unless (plist-get component :answered)
          (agent-ui-update id (list :values (plist-put (copy-sequence (plist-get component :values))
                                                       (agent-ui-form--key name) value))
                           :canvas canvas))))))

(defun agent-ui-form--set-error (name message)
  "Field NAME's error (MESSAGE), or none (nil)."
  (vui-set-state :errors (lambda (old)
                           (let ((old (cl-remove name old :key #'car :test #'equal)))
                             (if message (cons (cons name message) old) old)))))

(defun agent-ui-form--size (field)
  "Return how wide FIELD's input is drawn, at most.
40 a text, a file, 10 a number, 3 a yes / no, a select as its
longest option."
  (pcase (agent-ui-form--type field)
    ((or "text" "file" "directory") 40)
    ("boolean" 3)
    ("select" (+ 4 (apply #'max 1 (mapcar (lambda (o) (string-width (format "%s" o)))
                                          (plist-get field :options)))))
    (_ 10)))

(defun agent-ui-form--width (canvas id)
  "Return the columns form ID of CANVAS's buffer is laid out in.
Its window's, less one (a line as wide wraps in a terminal); 79
while it's in none."
  (let ((window (get-buffer-window (agent-ui-form--buffer-name canvas id) t)))
    (max 20 (1- (if window (window-width window) 80)))))

(defun agent-ui-form--input (canvas id field value &optional width)
  "FIELD's input, vui's, VALUE in it; WIDTH columns at most.
Its changes go to form ID on CANVAS."
  (let* ((name (plist-get field :name))
         (type (agent-ui-form--type field))
         (size (min (agent-ui-form--size field) (or width most-positive-fixnum)))
         (set (lambda (v) (agent-ui-form--set-value canvas id name v)))
         (on-error (lambda (message _raw) (agent-ui-form--set-error name message))))
    (pcase type
      ("text" (vui-field :value (if (stringp value) value "") :size size :key name
                         :placeholder (plist-get field :placeholder) :on-change set))
      ("boolean" (vui-checkbox :checked (eq value t) :key name :on-change (lambda (v) (funcall set (and v t)))))
      ("select" (vui-select :value value :options (plist-get field :options) :key name
                            :prompt (concat (agent-ui-form--label field) ": ") :on-change set))
      (_ (vui-typed-field :type (intern type) :value value :key name :size size
                          :min (plist-get field :min) :max (plist-get field :max)
                          :placeholder (plist-get field :placeholder)
                          :show-error 'inline :on-change set :on-error on-error)))))

(defun agent-ui-form--hint (field)
  "What FIELD takes, after its input: its range, required."
  (let ((min (plist-get field :min)) (max (plist-get field :max)))
    (string-join
     (delq nil (list (cond ((and min max) (format "%s to %s" min max))
                           (min (format "%s or more" min))
                           (max (format "%s at most" max)))
                     (and (eq (plist-get field :required) t)
                          (not (equal (agent-ui-form--type field) "boolean"))
                          "required")))
     ", ")))


(vui-defcomponent agent-ui-form--view (canvas id title question fields initial)
  :state ((values initial) (errors nil) (problem nil))
  :render
  ;; Laid out for its window (it was 40-column fields after the labels,
  ;; an 86-column help line: split mid-field in a narrow one): each
  ;; field after its label while they all fit there (a text field
  ;; narrowed), else under it; no input wider than the window; its
  ;; texts wrapped.
  (let* ((width (agent-ui-form--width canvas id))
         (label-width (apply #'max 0 (mapcar (lambda (f) (string-width (agent-ui-form--label f))) fields)))
         (hint-width (lambda (f) (let ((hint (agent-ui-form--hint f)))
                                   (if (string-empty-p hint) 0 (+ 2 (string-width hint))))))
         ;; The room for a field's input after its label (and before its
         ;; hint): a text field narrowed to 20 at most.
         (room (lambda (f) (- width label-width 2 (funcall hint-width f))))
         (beside (cl-every (lambda (f) (>= (funcall room f) (min (agent-ui-form--size f) 20))) fields))
         (lines (lambda (text face)
                  (mapcar (lambda (line) (vui-text line :face face))
                          (split-string (agent-ui-wrap text width) "\n")))))
    ;; Its question, its fields, its buttons: a blank line between.
    (vui-vstack
     :spacing 1
     (and (or title question)
          (vui-vstack (and title (funcall lines title 'agent-ui-title))
                      (and question (funcall lines question 'bold))))
     (vui-vstack
      :spacing (if beside 0 1)
      (mapcar (lambda (field)
                (let* ((hint (agent-ui-form--hint field))
                       (hint (and (not (string-empty-p hint)) (vui-text hint :face 'agent-ui-muted)))
                       (value (plist-get values (agent-ui-form--key (plist-get field :name)))))
                  (if beside
                      (vui-hstack
                       :spacing 2
                       (vui-text (string-pad (agent-ui-form--label field) label-width) :face 'agent-ui-muted)
                       (agent-ui-form--input canvas id field value (funcall room field))
                       hint)
                    ;; Its label over it; its hint after it, or under it.
                    (let ((input (agent-ui-form--input canvas id field value width)))
                      (vui-vstack
                       (funcall lines (agent-ui-form--label field) 'agent-ui-muted)
                       (if (and hint (<= (+ (min width (agent-ui-form--size field)) (funcall hint-width field))
                                         width))
                           (vui-hstack :spacing 2 input hint)
                         (delq nil (list input hint))))))))
              fields))
     (vui-vstack
      (and problem (funcall lines problem 'agent-ui-error))
      (vui-hstack
       :spacing 3
       (vui-button "Send" :on-click #'agent-ui-form-send :face 'agent-ui-action)
       (vui-button "Cancel" :on-click #'agent-ui-form-cancel))
      (funcall lines "C-c C-c sends it, C-c C-k cancels (what you typed is kept), TAB goes to the next field"
               'agent-ui-muted)))))

(defun agent-ui-form-open (canvas id)
  "Open form ID of CANVAS in a buffer of its own, selected; again: that one."
  (let* ((component (agent-ui-get id :canvas canvas))
         (props (agent-ui-check "form" component))
         (name (agent-ui-form--buffer-name canvas id))
         (open (get-buffer name)))
    (when (agent-ui-ask-answered-p props)
      (user-error "This form is answered"))
    (if (and open (eq (buffer-local-value 'agent-ui-form--canvas open) canvas))
        (agent-ui-form--show open canvas)
      (let ((buffer (get-buffer-create name)))
        (with-current-buffer buffer
          (agent-ui-form-mode)
          (setq agent-ui-form--canvas canvas
                agent-ui-form--id id))
        (let ((instance (vui-mount (vui-component 'agent-ui-form--view
                                                  :canvas canvas :id id
                                                  :title (plist-get component :title)
                                                  :question (plist-get props :question)
                                                  :fields (plist-get props :fields)
                                                  :initial (agent-ui-form--values props))
                                   name t)))
          (agent-ui-form--show buffer canvas)
          ;; Laid out again for the window it's in (then as that changes:
          ;; vui's resize hook).
          (with-current-buffer buffer (vui-rerender instance)))
        ;; On its first field.
        (goto-char (point-min))
        (ignore-errors (widget-forward 1))))))

(defun agent-ui-form--show (buffer canvas)
  "Show BUFFER, a form of CANVAS, in CANVAS's window, selected.
That's the selected window if it shows CANVAS, else one that does: the
form takes the canvas's place there until it's sent or cancelled (its
view in a session's pane stays the canvas's, `agent-ui-pane-view-of').
CANVAS in no window: a window of its own."
  (let ((window (if (eq (window-buffer (selected-window)) canvas)
                    (selected-window)
                  (get-buffer-window canvas))))
    (if (not (window-live-p window))
        (pop-to-buffer buffer)
      (with-current-buffer buffer
        (setq-local agent-ui-pane-view-of canvas)
        (unless agent-ui-form--window
          (setq agent-ui-form--window (cons window (window-dedicated-p window)))))
      (set-window-dedicated-p window nil)
      (set-window-buffer window buffer)
      (select-window window))))

(defun agent-ui-form--close ()
  "The form's buffer killed; its canvas back in its window.
Opened in its canvas's window, the canvas is shown there again, as it
was (dedicated or not), selected; opened in a window of its own, that
window closed as it was before.  No other window or buffer touched.
That window made again by its pane (laid out anew), the form shown in
the new one: that one."
  (let* ((buffer (current-buffer))
         (canvas agent-ui-form--canvas)
         (window (let ((window (car agent-ui-form--window)))
                   (if (and agent-ui-form--window
                            (not (and (window-live-p window) (eq (window-buffer window) buffer))))
                       (get-buffer-window buffer t)
                     window)))
         (dedicated (cdr agent-ui-form--window)))
    (if (and (window-live-p window) (eq (window-buffer window) buffer)
             (buffer-live-p canvas))
        (progn
          ;; Its pane may have dedicated the window to the form meanwhile.
          (set-window-dedicated-p window nil)
          (set-window-buffer window canvas)
          (set-window-dedicated-p window dedicated)
          (select-window window))
      (quit-window nil))
    (kill-buffer buffer)))

(defun agent-ui-form-cancel ()
  "Close the form, nothing sent: what was typed is kept in its component."
  (interactive)
  (agent-ui-form--close))

(defun agent-ui-form-send ()
  "Send the form: its answer into its session's prompt (sent at once).
The form is answered on its canvas.  Required fields empty, or a field
wrong: said in the form, nothing sent."
  (interactive)
  (let* ((instance (vui-get-instance))
         (values (vui-get-state instance :values))
         (errors (vui-get-state instance :errors))
         (canvas agent-ui-form--canvas)
         (id agent-ui-form--id))
    (unless (and instance (buffer-live-p canvas))
      (user-error "This form's canvas is gone"))
    (let* ((component (condition-case nil (agent-ui-get id :canvas canvas)
                      (agent-ui-error (user-error "This form is gone from its canvas"))))
           (props (agent-ui-check "form" component))
           (missing (agent-ui-form--missing props values)))
      (cond
       ((agent-ui-ask-answered-p props) (user-error "This form is answered"))
       (errors
        (vui-set-state :problem (format "Fix %s first: %s" (caar errors) (cdar errors)) instance))
       (missing
        (vui-set-state :problem (format "Fill in %s first" (string-join missing ", ")) instance))
       (t
        (let ((answer (agent-ui-form--answer id props values)))
          (with-current-buffer canvas
            ;; Its values its own first (a canvas answering itself reads
            ;; them), its component the one acting (a section's session's).
            (agent-ui-update id (list :values values) :canvas canvas)
            (let ((agent-ui-pressed id))
              (funcall agent-ui-action-function answer t))
            (agent-ui-update id (list :values values :answered answer) :canvas canvas))
          (agent-ui-form--close)))))))

(agent-ui-define form
  "Several fields the user answers together: a new ticket's details.
FIELDS, each {\"name\", \"label\", \"type\", \"required\", \"min\", \"max\",
\"options\", \"placeholder\", \"value\"}, type text (the default), integer,
number (min, max), boolean (yes / no), select (one of its options), file,
directory.  The user fills it in, in a buffer of its own (typed and checked
as they type), and sends it: \"Answer to form ID (QUESTION): {\\\"name\\\":
value, ...}\" comes into your prompt (sent at once).  Then it shows the
values, answered.  Show it, say so in a line, end your turn."
  :props ((question string "What it's for")
          (fields list "The fields: {\"name\": ..., \"type\": ..., ...}" :required t)
          (values any "The values so far, {\"name\": value}: defaults, or the user's")
          (answered string "The answer given (then it can't be changed)"))
  :example (:title "New ticket"
            :question "What should the ticket say?"
            :fields ((:name "title" :label "Title" :required t :value "Fix the parser")
                     (:name "priority" :label "Priority" :type "integer" :min 0 :max 4 :value 2)
                     (:name "type" :label "Type" :type "select" :options ("bug" "task" "feature") :value "bug")
                     (:name "blocking" :label "Blocking" :type "boolean")))
  :check #'agent-ui-form--check
  :text #'agent-ui-form--draw)


(provide 'agent-ui-form)

;;; agent-ui-form.el ends here
