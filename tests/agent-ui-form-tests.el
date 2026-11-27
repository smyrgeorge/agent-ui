;;; agent-ui-form-tests.el --- Tests for Agent UI: the form component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-form.el: the form component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defconst agent-ui-test-aue-ticket
  '(:type "form" :question "What should it say?"
    :fields ((:name "title" :label "Title" :required t)
             (:name "priority" :label "Priority" :type "integer" :min 0 :max 4 :value 2)
             (:name "type" :label "Type" :type "select" :options ("bug" "task"))
             (:name "blocking" :label "Blocking" :type "boolean")))
  "A form: a new ticket's details.")

(ert-deftest agent-ui-components/form ()
  "On the canvas: its fields and values (defaults, then the user's), Fill
in; answered, Sent instead; no button in a still picture."
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-ticket)
                 (concat "What should it say?\n"
                         " Title     —\n"
                         " Priority  2\n"
                         " Type      —\n"
                         " Blocking  no\n"
                         " ⏵ Fill in")))
  (let ((filled (append '(:values (:title "Fix the parser" :priority 3 :type "bug" :blocking t)) agent-ui-test-aue-ticket)))
    (should (equal (agent-ui-test-aue-draw filled :still t)
                   (concat "What should it say?\n"
                           " Title     Fix the parser\n"
                           " Priority  3\n"
                           " Type      bug\n"
                           " Blocking  yes")))
    (should (string-suffix-p " Blocking  yes\n ✓ Sent"
                             (agent-ui-test-aue-draw (append '(:answered "x") filled)))))
  ;; Waits until answered.
  (should (agent-ui-ask-waiting-p agent-ui-test-aue-ticket))
  (should-not (agent-ui-ask-waiting-p (append '(:answered "x") agent-ui-test-aue-ticket))))

(ert-deftest agent-ui-components/form-wrong ()
  (should (string-match-p "fields is required" (agent-ui-test-aue-error '(:type "form"))))
  (dolist (case '(((:label "x") . "field 1 has no name")
                  ((:name "a b") . "field 1 has no name")
                  ((:name "a" :type "date") . "field 1 has type \"date\"")
                  ((:name "a" :type "select") . "field 1 is a select: give its options")
                  ((:name "a" :options ("x")) . "field 1 has options: only a select")
                  ((:name "a" :min 1) . "field 1 has min: only a number")
                  ((:name "a" :type "integer" :max "4") . "field 1 has a max that isn't a number")
                  ((:name "a" :colour "red") . "field 1 has \"colour\"")
                  ;; Its value its type's (doom-ht6.62).
                  ((:name "a" :value ("a" "b")) . "not text")
                  ((:name "a" :type "integer" :value "abc") . "not an integer")
                  ((:name "a" :type "integer" :value 2.5) . "not an integer")
                  ((:name "a" :type "integer" :min 1 :max 5 :value 9) . "over its max 5")
                  ((:name "a" :type "boolean" :value "yes") . "not a boolean")
                  ((:name "a" :type "select" :options ("x" "y") :value "z") . "not one of its options")))
    (should (string-match-p (regexp-quote (cdr case))
                            (agent-ui-test-aue-error (list :type "form" :fields (list (car case)))))))
  (should (agent-ui-check "form" '(:fields ((:name "a" :value "t") (:name "n" :type "number" :value 2.5)
                                             (:name "b" :type "boolean" :value :false)
                                             (:name "s" :type "select" :options ("x") :value "x")))))
  (should (string-match-p "same name" (agent-ui-test-aue-error '(:type "form" :fields ((:name "a") (:name "a"))))))
  (should (string-match-p "values has b, not a field"
                          (agent-ui-test-aue-error '(:type "form" :fields ((:name "a")) :values (:b 1))))))

(defmacro agent-ui-test-aue-form (&rest body)
  "BODY with agent-ui-test-aue-ticket on a canvas (`canvas'), Fill in pressed: in the
form's buffer; what's sent in `sent'."
  (declare (indent 0))
  `(agent-ui-test-aue-canvas
     (let* ((sent nil)
            (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
       (agent-ui-show (append '(:id "ticket") agent-ui-test-aue-ticket))
       (save-window-excursion
         (with-current-buffer canvas (agent-ui-test-aue-press "⏵ Fill in"))
         (unwind-protect
             (with-current-buffer (agent-ui-form--buffer-name canvas "ticket") ,@body)
           (when (get-buffer (agent-ui-form--buffer-name canvas "ticket"))
             (kill-buffer (agent-ui-form--buffer-name canvas "ticket"))))))))

(defun agent-ui-test-aue-type (name text)
  "TEXT typed into the form's field NAME (in place of what's there); vui's
redraws done."
  (let ((w (seq-find (lambda (w) (equal (widget-get w :vui-key) name)) widget-field-list)))
    (should w)
    (delete-region (widget-field-start w) (widget-field-end w))
    (goto-char (widget-field-start w))
    (insert text))
  (agent-ui-test-aue-settle))

(defun agent-ui-test-aue-settle ()
  "vui's redraws (timers) done, 0.2 s at least: `agent-ui-test-timers-run'."
  (agent-ui-test-timers-run 0.2))

(ert-deftest agent-ui-components/form-filled-in-and-sent ()
  "Fill in: the form in its buffer (vui's fields, Emacs's keys there, the
cursor on the first field); typed values reach its component; required ones
empty, or a wrong one: said, nothing sent; Send: the answer as JSON, the
form answered on the canvas, its buffer gone."
  (agent-ui-test-aue-form
    (should (derived-mode-p 'agent-ui-form-mode))
    (should (eq (key-binding (kbd "C-c C-c")) #'agent-ui-form-send))
    (should (eq (key-binding (kbd "C-c C-k")) #'agent-ui-form-cancel))
    (should (equal (widget-get (widget-field-at (point)) :vui-key) "title"))
    (should (string-search "Priority  2" (buffer-string)))
    ;; Nothing typed: refused.
    (agent-ui-form-send)
    (agent-ui-test-aue-settle)
    (should (string-search "Fill in Title first" (buffer-string)))
    (should-not sent)
    ;; Typed: kept in the component.
    (agent-ui-test-aue-type "title" "Fix the parser")
    (should (equal (plist-get (agent-ui-get "ticket" :canvas canvas) :values) '(:title "Fix the parser")))
    ;; Out of its range: said, refused.
    (agent-ui-test-aue-type "priority" "9")
    (should (string-search "Must be at most 4" (buffer-string)))
    (agent-ui-form-send)
    (agent-ui-test-aue-settle)
    (should (string-search "Fix priority first" (buffer-string)))
    (should-not sent)
    (agent-ui-test-aue-type "priority" "3")
    (agent-ui-form-send)
    (should (equal sent '(("Answer to form ticket (What should it say?): {\"title\":\"Fix the parser\",\"priority\":3,\"type\":null,\"blocking\":false}" t))))
    (should-not (get-buffer (agent-ui-form--buffer-name canvas "ticket")))
    (with-current-buffer canvas
      (agent-ui--flush)
      (should (string-search " Priority  3\n Type      —\n Blocking  no\n ✓ Sent" (buffer-string)))
      (should-not (string-search "Fill in" (buffer-string))))
    ;; Answered: not opened again.
    (should-error (agent-ui-form-open canvas "ticket") :type 'user-error)))

(ert-deftest agent-ui-components/form-laid-out-for-its-window ()
  "The form's buffer laid out for its window: in 49 columns, its lines
within it (a 40-column field after the labels and an 86-column help line
wrapped mid-field), a text field narrowed beside its label; in 30, each
field under its label, no wider than the window."
  (agent-ui-test-aue-canvas
    (agent-ui-show (append '(:id "ticket") agent-ui-test-aue-ticket))
    (dolist (case '((49 . t) (30 . nil)))
      (save-window-excursion
        (delete-other-windows)
        (let ((window (split-window-right)))
          (select-window window)
          (window-resize window (- (car case) (window-width window)) t)
          (should (= (window-width window) (car case)))
          (let ((display-buffer-overriding-action '(display-buffer-same-window)))
            (agent-ui-form-open canvas "ticket"))
          (unwind-protect
              (with-current-buffer (agent-ui-form--buffer-name canvas "ticket")
                (agent-ui-test-aue-settle)
                (should (eq (get-buffer-window) window))
                (dolist (line (split-string (buffer-string) "\n"))
                  (should (< (string-width line) (car case))))
                ;; Beside its label, or under it.
                (should (eq (cdr case) (and (string-match-p "^Priority  2" (buffer-string)) t)))
                (should (string-search "C-c C-c sends it" (buffer-string)))
                ;; Each field still typed into.
                (agent-ui-test-aue-type "title" "Fix the parser")
                (should (equal (plist-get (agent-ui-get "ticket" :canvas canvas) :values) '(:title "Fix the parser"))))
            (kill-buffer (agent-ui-form--buffer-name canvas "ticket"))))))))

;; In its canvas's window: the form takes the canvas's place there (its view
;; in a session's pane still the canvas's), and gives it back when it's
;; sent or cancelled; the other windows and their buffers left as they were.
(ert-deftest agent-ui-components/form-in-its-canvas-window ()
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent)))
           (session (agent-ui-test-buffer "Claude Agent @ form" "The conversation.\n")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer session)
            (let* ((canvas-window (split-window nil nil 'below))
                   (session-window (selected-window)))
              (set-window-buffer canvas-window canvas)
              ;; A view's window in a session's pane is dedicated to it.
              (set-window-dedicated-p canvas-window t)
              (select-window canvas-window)
              (agent-ui-show (append '(:id "ticket") agent-ui-test-aue-ticket))
              (dolist (finish '(cancel send))
                (with-current-buffer canvas (agent-ui-test-aue-press "⏵ Fill in"))
                (let ((form (get-buffer (agent-ui-form--buffer-name canvas "ticket"))))
                  (should form)
                  ;; In the canvas's window, selected; no other window made.
                  (should (eq (window-buffer canvas-window) form))
                  (should (eq (selected-window) canvas-window))
                  (should (= (length (window-list)) 2))
                  ;; Its view still the canvas's.
                  (should (eq (agent-ui--pane-view canvas-window) canvas))
                  (with-current-buffer form
                    (pcase finish
                      ('cancel (agent-ui-form-cancel))
                      ('send (agent-ui-test-aue-type "title" "Fix the parser")
                             (agent-ui-form-send))))
                  (should-not (buffer-live-p form)))
                ;; The canvas back in its window, dedicated again, selected;
                ;; the session's window as it was.
                (should (eq (window-buffer canvas-window) canvas))
                (should (window-dedicated-p canvas-window))
                (should (eq (selected-window) canvas-window))
                (should (eq (window-buffer session-window) session))
                (should (buffer-live-p session)))
              (should (= (length sent) 1))))
        (kill-buffer session)))))

(ert-deftest agent-ui-components/form-cancelled-kept ()
  "Cancel: nothing sent, what was typed kept, there when it's opened again."
  (agent-ui-test-aue-form
    (agent-ui-test-aue-type "title" "Half a title")
    (agent-ui-form-cancel)
    (should-not (get-buffer (agent-ui-form--buffer-name canvas "ticket")))
    (should-not sent)
    (with-current-buffer canvas
      (agent-ui--flush)
      (should (string-search " Title     Half a title" (buffer-string)))
      (agent-ui-test-aue-press "⏵ Fill in"))
    (with-current-buffer (agent-ui-form--buffer-name canvas "ticket")
      (should (equal (widget-value (seq-find (lambda (w) (equal (widget-get w :vui-key) "title")) widget-field-list))
                     "Half a title")))))

;; doom-ht6.112
(ert-deftest agent-ui-components/form-buffer-its-canvas-own ()
  "Two canvases' forms of the same id: each in a buffer of its own, bound
to its canvas, each answer sent from its own canvas (they shared one: the
second opened over the first, its answer the only one, from the wrong
canvas)."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt _submit) (push (cons (current-buffer) prompt) sent)))
           (other (let ((agent-ui-default-canvas (make-temp-name "form-")))
                    (agent-ui-show '(:id "first" :type "text" :text "x"))
                    (agent-ui-canvas)))
           (forms nil))
      (unwind-protect
          (save-window-excursion
            (dolist (c (list canvas other))
              (agent-ui-show (append '(:id "ticket") agent-ui-test-aue-ticket) :canvas c)
              (with-current-buffer c (agent-ui-test-aue-press "⏵ Fill in"))
              (push (window-buffer (selected-window)) forms))
            (setq forms (nreverse forms))
            (should-not (eq (nth 0 forms) (nth 1 forms)))
            (should (cl-every #'buffer-live-p forms))
            (should (eq (buffer-local-value 'agent-ui-form--canvas (nth 0 forms)) canvas))
            (should (eq (buffer-local-value 'agent-ui-form--canvas (nth 1 forms)) other))
            ;; The other's sent first, then the first's: each from its canvas.
            (dolist (case (list (list (nth 1 forms) other "Other's") (list (nth 0 forms) canvas "First's")))
              (with-current-buffer (nth 0 case)
                (agent-ui-test-aue-type "title" (nth 2 case))
                (agent-ui-form-send))
              (should (eq (caar sent) (nth 1 case)))
              (should (string-search (format "\"title\":\"%s\"" (nth 2 case)) (cdar sent)))
              (should (plist-get (agent-ui-get "ticket" :canvas (nth 1 case)) :answered)))
            (should (= (length sent) 2)))
        (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) forms)
        (kill-buffer other)))))

;; doom-0ej
(ert-deftest agent-ui-components/form-slider-image-texts-read-whole ()
  "A form's labels and values, a slider's label and an image's alt too long
for their room are wrapped, every word read (they were cut with …, their
rest nowhere): a form's label in its column and its value in the rest, the
row as tall as the taller; a slider's label above it; an image's alt under
its name, unless it fits whole beside it."
  (let* ((label "Why the pool should keep this many sessions running at once")
         (value "a prefilled answer long enough to be cut at the right edge of a normal pane, its end lost")
         (form (list :type "form" :fields (list (list :name "reason" :label label :value value)
                                                '(:name "n" :label "Sessions" :type "integer" :value 3))))
         (slider (list :type "slider" :label "How many sessions should the pool keep running at once, at most" :min 1 :max 8 :value 3))
         (image '(:type "image" :file "/tmp/aui-0ej/missing.png" :alt "The login page after the fix, its button moved under the form")))
    (dolist (width '(30 40 60 98))
      (dolist (component (list form slider image))
        (let ((text (agent-ui-test-aue-draw component :width width)))
          (dolist (line (split-string text "\n")) (should (<= (string-width line) width)))
          (dolist (word (split-string (or (plist-get component :alt) (plist-get component :label)
                                          (concat label " " value))))
            (should (string-search word text))))))
    (should (equal (agent-ui-test-aue-draw form)
                   (concat " Why the pool should   a prefilled answer long enough to be\n"
                           " keep this many        cut at the right edge of a normal\n"
                           " sessions running at   pane, its end lost\n"
                           " once\n"
                           " Sessions              3\n"
                           " ⏵ Fill in")))
    (should (eq (agent-ui-test-aue-face-at form "keep this") 'agent-ui-muted))
    (should (string-prefix-p "How many sessions should the pool keep running at once, at\nmost\n"
                             (agent-ui-test-aue-draw slider)))
    (should (equal (agent-ui-test-aue-draw image)
                   (concat "▣ /tmp/aui-0ej/missing.png  (not found)\n"
                           "  The login page after the fix, its button moved under the\n  form")))
    ;; Room for it: the alt beside its name, as before.
    (should (equal (agent-ui-test-aue-draw '(:type "image" :file "/tmp/aui-0ej/missing.png" :alt "After the fix"))
                   "▣ /tmp/aui-0ej/missing.png  After the fix  (not found)"))))

;;; agent-ui-form-tests.el ends here
