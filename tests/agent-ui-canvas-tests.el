;;; agent-ui-canvas-tests.el --- Tests for Agent UI: canvas  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-canvas.el: Agent UI's canvas. Components shown, replaced,
;; updated (redrawn together, later), appended to, removed; the canvas shown
;; when a component is added, at its window's width; animations' timer; errors.
;; Types of the tests' own; each test's canvas killed after it.

;;; Code:

(require 'agent-ui-test-helper)

;; ====== HELPERS ======

(defvar agent-ui-test-auc-draws 0 "How many times a `meter' was drawn.")
(defvar agent-ui-test-auc-displayed nil "The canvases `agent-ui-display-function' was given.")

(defmacro agent-ui-test-auc (&rest body)
  "BODY with a canvas of its own, `canvas' (killed after), and only the
tests' types: meter (VALUE/MAX), spinner (animated), broken (fails)."
  (declare (indent 0))
  `(let ((agent-ui--types (make-hash-table :test #'eq))
         (agent-ui-default-canvas (make-temp-name "test-"))
         (agent-ui-display-function (lambda (b) (push b agent-ui-test-auc-displayed)))
         (agent-ui-test-auc-draws 0)
         (agent-ui-test-auc-displayed nil))
     (agent-ui-define meter "VALUE of MAX."
       :props ((value number "Done" :default 0)
               (max number "Total" :default 10)
               (marks list "Marks")
               (wide boolean "Its width shown"))
       :text (lambda (props ctx)
               (cl-incf agent-ui-test-auc-draws)
               (format "%s/%s%s%s" (plist-get props :value) (plist-get props :max)
                       (if (plist-get props :marks)
                           (concat " " (string-join (plist-get props :marks) ","))
                         "")
                       (if (plist-get props :wide) (format " w%s" (plist-get ctx :width)) ""))))
     (agent-ui-define spinner "Spins." :animated t
       :text (lambda (_props ctx) (format "spin %d" (plist-get ctx :tick))))
     (agent-ui-define broken "Fails." :text (lambda (_p _c) (error "Boom")))
     (let ((canvas (agent-ui-canvas)))
       (unwind-protect (progn ,@body)
         (kill-buffer canvas)))))

(defun agent-ui-test-auc-text (&optional canvas)
  "CANVAS's text under its top line (an empty line of its own: checked)."
  (with-current-buffer (or canvas (agent-ui-canvas))
    (should (eql (char-after (point-min)) ?\n))
    (buffer-substring-no-properties (1+ (point-min)) (point-max))))

(defun agent-ui-test-auc-flush ()
  (with-current-buffer (agent-ui-canvas) (agent-ui--flush)))

(defun agent-ui-test-auc-message (fn &rest args)
  (agent-ui-error-message (should-error (apply fn args) :type 'agent-ui-error)))

;; ====== THE CANVAS ======

(ert-deftest agent-ui-canvas/cleared-in-its-selected-window-it-alone ()
  "A canvas cleared in its window, selected (its pane, made for it, closing
as it's emptied: the window selected next another buffer's, a session's):
the canvas alone erased, the other buffer left as it was, its read-only
text too (it was erased whole: the clear's erase went on in the buffer
current after the window closed)."
  (agent-ui-test-auc
    (let ((session (get-buffer-create "*test-auc-session*")))
      (unwind-protect
          (progn
            (with-current-buffer session
              (let ((inhibit-read-only t)) (erase-buffer))
              (insert (propertize "The conversation so far.\nClaude> " 'read-only t)))
            (save-window-excursion
              (delete-other-windows)
              (switch-to-buffer session)
              (let ((window (split-window-right)))
                (set-window-buffer window canvas)
                (set-window-prev-buffers window nil)
                (set-window-parameter window 'quit-restore (list 'window 'window (selected-window) canvas))
                (select-window window)
                (agent-ui-show '(:id "a" :type "meter" :value 1))
                (agent-ui-show '(:id "b" :type "meter" :value 2))
                (agent-ui-clear :canvas canvas)
                (should-not (window-live-p window))
                (should (equal (with-current-buffer session (buffer-substring-no-properties (point-min) (point-max)))
                               "The conversation so far.\nClaude> "))
                (should (equal (agent-ui-test-auc-text canvas) "")))))
        (kill-buffer session)))))

(ert-deftest agent-ui-canvas/settings ()
  (should (= (default-value 'agent-ui-redraw-delay) 0.1))
  (should (= (default-value 'agent-ui-max-components) 100))
  (should (equal (default-value 'agent-ui-default-canvas) "default"))
  ;; By default, a session's canvases in its session's pane
  ;; (agent-ui-pane.el, agent-ui-pane-tests.el).
  (should (eq (eval (car (get 'agent-ui-display-function 'standard-value)) t) #'agent-ui-pane-display)))


(ert-deftest agent-ui-canvas/a-top-line-of-its-own ()
  "A canvas starts with an empty line of its own, the cursor on it: its first
component (an image, say: a box cursor frames it whole) under it. Its components
shown, replaced, removed, the canvas cleared: the line stays, the cursor on
it. It alone is nothing shown (`agent-ui-canvas-shows-p')."
  (agent-ui-test-auc
    (with-current-buffer canvas
      (should (equal (buffer-string) "\n"))
      (should (= (point) 1))
      (should-not (agent-ui-canvas-shows-p canvas))
      (agent-ui-show '(:id "a" :type "meter" :value 1))
      (should (agent-ui-canvas-shows-p canvas))
      (should (equal (buffer-substring-no-properties 1 2) "\n"))
      (should-not (get-text-property 1 'agent-ui-id))
      (should (equal (get-text-property 2 'agent-ui-id) "a"))
      (should (= (point) 1))
      (agent-ui-show '(:id "a" :type "meter" :value 2))
      (agent-ui-update "a" '(:value 3))
      (agent-ui--flush)
      (should (equal (buffer-string) "\n3/10\n\n"))
      (should (= (point) 1))
      (agent-ui-remove "a")
      (should (equal (buffer-string) "\n"))
      (should-not (agent-ui-canvas-shows-p canvas))
      (agent-ui-show '(:id "b" :type "meter"))
      (goto-char (point-max))
      (let ((agent-ui-close-emptied-functions nil))
        (agent-ui-clear))
      (should (equal (buffer-string) "\n"))
      (should (= (point) 1)))
    (with-temp-buffer
      (insert "text")
      (should-not (agent-ui-canvas-shows-p (current-buffer))))))

;; Only showing a component makes a canvas: looking at one doesn't.
(ert-deftest agent-ui-canvas/made-by-showing-only ()
  (agent-ui-test-auc
    (let ((name (make-temp-name "unmade-")))
      (should-not (agent-ui-components :canvas name))
      (should-not (agent-ui-clear :canvas name))
      (dolist (call (list (lambda () (agent-ui-get "a" :canvas name))
                          (lambda () (agent-ui-update "a" '(:value 1) :canvas name))
                          (lambda () (agent-ui-append "a" '(:marks ("x")) :canvas name))
                          (lambda () (agent-ui-remove "a" :canvas name))))
        (should (equal (agent-ui-error-message (should-error (funcall call) :type 'agent-ui-error))
                       (format "canvas %s has no components yet" name))))
      (should-not (get-buffer (agent-ui-canvas-buffer-name name)))
      (agent-ui-show '(:id "a" :type "meter") :canvas name)
      (let ((made (get-buffer (agent-ui-canvas-buffer-name name))))
        (should made)
        (kill-buffer made)))))

;; ====== SHOWING ======

(ert-deftest agent-ui-canvas/components-shown-in-order ()
  (agent-ui-test-auc
    (should (equal (agent-ui-show '(:id "a" :type "meter" :value 1)) "a"))
    (should (equal (agent-ui-show '(:id "b" :type meter :value 2 :title "B")) "b"))
    ;; Drawn at once, a blank line after each.
    (should (equal (agent-ui-test-auc-text) "1/10\n\nB\n2/10\n\n"))
    (should (equal (agent-ui-components) '((:id "a" :type "meter") (:id "b" :type "meter"))))
    ;; Each component's text knows its id (under the canvas's top line, no
    ;; component's).
    (with-current-buffer canvas
      (should-not (get-text-property 1 'agent-ui-id))
      (should (equal (get-text-property 2 'agent-ui-id) "a"))
      (should (equal (get-text-property 8 'agent-ui-id) "b")))
    ;; Its type a string, as JSON's.
    (should (equal (agent-ui-get "b") '(:id "b" :type "meter" :value 2 :title "B")))))

(ert-deftest agent-ui-canvas/shown-again-replaced-in-place ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter" :value 1))
    (agent-ui-show '(:id "b" :type "meter" :value 2))
    ;; All of it replaced (no :max: its default), in its place, drawn soon.
    (agent-ui-show '(:id "a" :type "spinner"))
    (agent-ui-test-auc-flush)
    (should (equal (agent-ui-test-auc-text) "spin 0\n\n2/10\n\n"))
    (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components)) '("a" "b")))))

(ert-deftest agent-ui-canvas/an-id-made ()
  (agent-ui-test-auc
    (should (equal (agent-ui-show '(:type "meter")) "meter-1"))
    (should (equal (agent-ui-show '(:type "meter")) "meter-2"))
    ;; One the agent chose is skipped.
    (agent-ui-show '(:id "meter-3" :type "meter"))
    (should (equal (agent-ui-show '(:type "meter")) "meter-4"))
    (should (string-match-p "an id is letters"
                            (agent-ui-test-auc-message #'agent-ui-show '(:id "a b" :type "meter"))))
    (should (string-match-p "an id is letters"
                            (agent-ui-test-auc-message #'agent-ui-show '(:id 3 :type "meter"))))))

(ert-deftest agent-ui-canvas/a-wrong-component-refused ()
  (agent-ui-test-auc
    (should (string-match-p "unknown property \"total\""
                            (agent-ui-test-auc-message #'agent-ui-show '(:id "a" :type "meter" :total 3))))
    (should (string-match-p "unknown type"
                            (agent-ui-test-auc-message #'agent-ui-show '(:id "a" :type "metre"))))
    (should (string-match-p "a title is text"
                            (agent-ui-test-auc-message #'agent-ui-show '(:id "a" :type "meter" :title 3))))
    ;; Nothing added, nothing shown.
    (should-not (agent-ui-components))
    (should (equal (agent-ui-test-auc-text) ""))
    (should-not agent-ui-test-auc-displayed)))

(ert-deftest agent-ui-canvas/a-failing-drawing-in-its-place ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "broken"))
    (agent-ui-show '(:id "b" :type "meter"))
    (should (equal (agent-ui-test-auc-text) "⚠ Boom\n\n0/10\n\n"))))

(ert-deftest agent-ui-canvas/at-most-so-many ()
  (agent-ui-test-auc
    (let ((agent-ui-max-components 2))
      (agent-ui-show '(:type "meter"))
      (agent-ui-show '(:id "b" :type "meter"))
      (should (string-match-p "the most it holds"
                              (agent-ui-test-auc-message #'agent-ui-show '(:type "meter"))))
      ;; One shown again is no more.
      (should (agent-ui-show '(:id "b" :type "meter"))))))

;; ====== SHOWN IN A WINDOW ======

(ert-deftest agent-ui-canvas/shown-when-an-component-is-added ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter"))
    (should (equal agent-ui-test-auc-displayed (list canvas)))
    ;; Updates, a component shown again: not shown again.
    (agent-ui-update "a" '(:value 3))
    (agent-ui-show '(:id "a" :type "meter"))
    (should (= (length agent-ui-test-auc-displayed) 1))
    ;; Hidden, then a new component: shown again.
    (agent-ui-show '(:id "b" :type "meter"))
    (should (= (length agent-ui-test-auc-displayed) 2))
    ;; In a window already: not.
    (save-window-excursion
      (switch-to-buffer canvas)
      (agent-ui-show '(:id "c" :type "meter"))
      (should (= (length agent-ui-test-auc-displayed) 2)))))

(ert-deftest agent-ui-canvas/shown-without-the-focus ()
  (agent-ui-test-auc
    (let ((agent-ui-display-function #'agent-ui-display-canvas))
      (save-window-excursion
        (delete-other-windows)
        (let ((before (selected-window)))
          (agent-ui-show '(:id "a" :type "meter"))
          (should (eq (selected-window) before))
          (should (get-buffer-window canvas)))))))

(defun agent-ui-test-auc-settle ()
  "Timers due now run, 0.1 s at least: `agent-ui-test-timers-run'."
  (agent-ui-test-timers-run 0.1))

(ert-deftest agent-ui-canvas/shown-once-the-minibuffer-closes ()
  "A component shown while the minibuffer is open: drawn, its canvas shown
once it's closed (opened then, it took another pane's place: tiling steps
aside while it's open); not if it's in a window by then, or gone. Another
minibuffer still open (one opened from it): once that one's closed."
  (agent-ui-test-auc
    (let ((open t))
      (cl-letf (((symbol-function 'active-minibuffer-window)
                 (lambda () (and open (minibuffer-window)))))
        (unwind-protect
            (progn
              (agent-ui-show '(:id "a" :type "meter"))
              (should (equal (agent-ui-test-auc-text) "0/10\n\n"))
              (should-not agent-ui-test-auc-displayed)
              (should (memq #'agent-ui--minibuffer-exit-h minibuffer-exit-hook))
              ;; Its exit hook runs while it's still open: just after.
              (run-hooks 'minibuffer-exit-hook)
              (setq open nil)
              (should-not agent-ui-test-auc-displayed)
              (agent-ui-test-auc-settle)
              (should (equal agent-ui-test-auc-displayed (list canvas)))
              (should-not (memq #'agent-ui--minibuffer-exit-h minibuffer-exit-hook))
              ;; Still open after its exit (another one): waiting again.
              (setq open t agent-ui-test-auc-displayed nil)
              (agent-ui-show '(:id "b" :type "meter"))
              (run-hooks 'minibuffer-exit-hook)
              (agent-ui-test-auc-settle)
              (should-not agent-ui-test-auc-displayed)
              (setq open nil)
              (run-hooks 'minibuffer-exit-hook)
              (agent-ui-test-auc-settle)
              (should (equal agent-ui-test-auc-displayed (list canvas)))
              ;; In a window by then: not shown again; gone: not either.
              (setq open t agent-ui-test-auc-displayed nil)
              (agent-ui-show '(:id "c" :type "meter"))
              (save-window-excursion
                (switch-to-buffer canvas)
                (setq open nil)
                (run-hooks 'minibuffer-exit-hook)
                (agent-ui-test-auc-settle))
              (should-not agent-ui-test-auc-displayed)
              (let ((other (agent-ui-canvas "test-gone")))
                (setq open t)
                (agent-ui-show '(:id "d" :type "meter") :canvas other)
                (kill-buffer other)
                (setq open nil)
                (run-hooks 'minibuffer-exit-hook)
                (agent-ui-test-auc-settle)
                (should-not agent-ui-test-auc-displayed)))
          (remove-hook 'minibuffer-exit-hook #'agent-ui--minibuffer-exit-h)
          (setq agent-ui--after-minibuffer nil))))))

(ert-deftest agent-ui-canvas/shown-though-its-pane-cant-open ()
  "Its pane can't open (tiling's \"No room for another pane\"): the component
shown all the same, drawn, its sources started (`agent-ui-shown-functions'),
said; its pane tried again at the next change, opened once there's room
(it was half added: in the canvas's order, not drawn, its source never
started, every later component failing the same way)."
  (agent-ui-test-auc
    (let* ((room nil)
           (shown nil)
           (agent-ui-display-function
            (lambda (b) (if room (push b agent-ui-test-auc-displayed) (user-error "No room for another pane"))))
           (agent-ui-shown-functions (list (lambda (id _component) (push id shown)))))
      (should (equal (agent-ui-show '(:id "a" :type "meter" :value 1)) "a"))
      (should (equal (agent-ui-test-auc-text) "1/10\n\n"))
      (should (equal shown '("a")))
      (should (equal (buffer-local-value 'agent-ui--hidden canvas) "No room for another pane"))
      (should (= (agent-ui-test-messages "can't be shown (No room for another pane)") 1))
      ;; Another: the same, said once.
      (agent-ui-test-clear-messages)
      (agent-ui-show '(:id "b" :type "meter" :value 2))
      (should (equal (agent-ui-test-auc-text) "1/10\n\n2/10\n\n"))
      (should (equal shown '("b" "a")))
      (should (= (agent-ui-test-messages "can't be shown") 0))
      ;; Room made: shown at its next change.
      (setq room t)
      (agent-ui-update "a" '(:value 3))
      (should (equal agent-ui-test-auc-displayed (list canvas)))
      (should-not (buffer-local-value 'agent-ui--hidden canvas))
      (agent-ui-test-auc-flush)
      (should (equal (agent-ui-test-auc-text) "3/10\n\n2/10\n\n"))
      ;; Shown once: its next changes don't show it again.
      (agent-ui-update "a" '(:value 4))
      (should (= (length agent-ui-test-auc-displayed) 1))
      ;; g r tries again too.
      (setq room nil)
      (agent-ui-show '(:id "c" :type "meter"))
      (should (buffer-local-value 'agent-ui--hidden canvas))
      (setq room t)
      (agent-ui-canvas-redraw canvas)
      (should (= (length agent-ui-test-auc-displayed) 2)))))

(ert-deftest agent-ui-canvas/drawn-at-its-windows-width ()
  (agent-ui-test-auc
    ;; In no window: `agent-ui-default-width'.
    (let ((agent-ui-default-width 33))
      (agent-ui-show '(:id "a" :type "meter" :wide t)))
    (should (equal (agent-ui-test-auc-text) "0/10 w33\n\n"))
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer canvas)
      (agent-ui-canvas-redraw)
      ;; A column short of the window's.
      (should (equal (agent-ui-test-auc-text)
                     (format "0/10 w%d\n\n" (1- (window-max-chars-per-line))))))))

;; ====== UPDATES ======

(ert-deftest agent-ui-canvas/to-its-windows-last-column-in-the-gui ()
  "A component drawn for a window takes all its columns in the GUI (a line
that wide fits: a column left empty made its right side twice its left),
one fewer in a terminal (a line as wide as it ends in its cut's $)."
  (cl-letf (((symbol-function 'window-max-chars-per-line) (lambda (&rest _) 99)))
    (should (= (agent-ui-window-columns (selected-window)) 98))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (should (= (agent-ui-window-columns (selected-window)) 99)))))

(ert-deftest agent-ui-canvas/updated-later-together ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter" :value 1))
    (setq agent-ui-test-auc-draws 0)
    (should (equal (agent-ui-update "a" '(:value 2)) "a"))
    (agent-ui-update "a" '(:value 3 :max 5))
    ;; Not yet.
    (should (equal (agent-ui-test-auc-text) "1/10\n\n"))
    (should (= agent-ui-test-auc-draws 0))
    ;; Once, with both.
    (agent-ui-test-auc-flush)
    (should (equal (agent-ui-test-auc-text) "3/5\n\n"))
    (should (= agent-ui-test-auc-draws 1))
    ;; nil: back to its default.
    (agent-ui-update "a" '(:max nil))
    (agent-ui-test-auc-flush)
    (should (equal (agent-ui-test-auc-text) "3/10\n\n"))))

(ert-deftest agent-ui-canvas/glyphs-in-their-cells ()
  "In the GUI, a component's text goes into the canvas evened out
\(`agent-ui-even-glyphs'): the space after a glyph wider than its column
narrower, a panel's border after it in line; in a terminal, as it is."
  (agent-ui-test-auc
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'frame-char-width) (lambda (&optional _) 11))
              ((symbol-function 'agent-ui--glyph)
               (lambda (char _face _buffer) (if (eq char ?✎) '(17) '(11)))))
      (agent-ui-show '(:id "a" :type "meter" :marks ("✎ a")))
      (should (equal (agent-ui-test-auc-text) "0/10 ✎ a\n\n"))
      (with-current-buffer canvas
        (should (equal (get-text-property 8 'display) '(space :width (5))))))
    (agent-ui-show '(:id "a" :type "meter" :marks ("✎ b")))
    (agent-ui-test-auc-flush)
    (with-current-buffer canvas
      (should-not (get-text-property 8 'display)))))

(ert-deftest agent-ui-canvas/redrawn-when-the-font-changes ()
  "A frame's font changed (its size): every canvas drawn again, for its new
cells (its window's size in pixels the same, no size change said it); a
size change with the same width in columns but other cells too."
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter"))
    (agent-ui-test-auc-flush)
    (let ((draws agent-ui-test-auc-draws))
      (run-hooks 'after-setting-font-hook)
      (with-current-buffer canvas (should agent-ui--dirty))
      (agent-ui-test-auc-flush)
      (should (= agent-ui-test-auc-draws (1+ draws))))
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer canvas)
      (agent-ui-canvas-redraw)
      (agent-ui-test-auc-flush)
      (let ((draws agent-ui-test-auc-draws))
        ;; Same width, same cells: as it is.
        (agent-ui--size-changed (selected-window))
        (agent-ui-test-auc-flush)
        (should (= agent-ui-test-auc-draws draws))
        ;; Same width, other cells: drawn again.
        (with-current-buffer canvas (setq agent-ui--cell '(11 25)))
        (agent-ui--size-changed (selected-window))
        (agent-ui-test-auc-flush)
        (should (= agent-ui-test-auc-draws (1+ draws)))
        (with-current-buffer canvas
          (should (equal agent-ui--cell (list (frame-char-width) (frame-char-height)))))))))

(ert-deftest agent-ui-canvas/redrawn-when-its-text-is-scaled ()
  "Its text scaled (C-x C-+): drawn again at its window's new width, for its
cells as scaled (no window size changed: drawn for the old ones until g r)."
  (agent-ui-test-auc
    (with-current-buffer canvas (should (memq #'agent-ui--text-scaled text-scale-mode-hook)))
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer canvas)
      (agent-ui-show '(:id "a" :type "meter" :wide t))
      (agent-ui-canvas-redraw)
      (let ((columns (window-max-chars-per-line)))
        (should (equal (agent-ui-test-auc-text) (format "0/10 w%d\n\n" (1- columns))))
        ;; As a scaled text's window says.
        (cl-letf (((symbol-function 'window-max-chars-per-line) (lambda (&rest _) 38))
                  ((symbol-function 'window-font-width) (lambda (&rest _) 14)))
          (with-current-buffer canvas (text-scale-increase 3))
          (with-current-buffer canvas (should agent-ui--dirty))
          (agent-ui-test-auc-flush)
          (should (equal (agent-ui-test-auc-text) "0/10 w37\n\n"))
          (with-current-buffer canvas (should (equal (car agent-ui--cell) 14))))
        (with-current-buffer canvas (text-scale-set 0))
        (agent-ui-test-auc-flush)
        (should (equal (agent-ui-test-auc-text) (format "0/10 w%d\n\n" (1- columns))))))))

(ert-deftest agent-ui-canvas/redrawn-by-its-timer ()
  (agent-ui-test-auc
    (let ((agent-ui-redraw-delay 0.01))
      (agent-ui-show '(:id "a" :type "meter"))
      (agent-ui-update "a" '(:value 4))
      (with-timeout (2 (ert-fail "Not redrawn"))
        (while (not (equal (agent-ui-test-auc-text) "4/10\n\n"))
          (accept-process-output nil 0.01)))
      (should-not (buffer-local-value 'agent-ui--redraw-timer canvas)))))

(ert-deftest agent-ui-canvas/many-updates-quick ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter"))
    (setq agent-ui-test-auc-draws 0)
    (let ((start (float-time)))
      (dotimes (i 1000)
        (agent-ui-update "a" (list :value i)))
      ;; A thousand updates: well under a second, nothing drawn yet.
      (should (< (- (float-time) start) 1.0)))
    (should (= agent-ui-test-auc-draws 0))
    (agent-ui-test-auc-flush)
    (should (= agent-ui-test-auc-draws 1))
    (should (equal (agent-ui-test-auc-text) "999/10\n\n"))))

(ert-deftest agent-ui-canvas/a-wrong-update-refused ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter" :value 1))
    (agent-ui-show '(:id "b" :type "meter"))
    (should (equal (agent-ui-test-auc-message #'agent-ui-update "c" '(:value 2))
                   (format "no component \"c\" in canvas %s; its components: a, b"
                           agent-ui-default-canvas)))
    (should (string-match-p "must be a number"
                            (agent-ui-test-auc-message #'agent-ui-update "a" '(:value "x"))))
    (should (string-match-p "can't change the type"
                            (agent-ui-test-auc-message #'agent-ui-update "a" '(:type "spinner"))))
    ;; Unchanged.
    (should (equal (agent-ui-get "a") '(:id "a" :type "meter" :value 1)))))

(ert-deftest agent-ui-canvas/appended-to ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter" :marks ("x")))
    (should (equal (agent-ui-append "a" '(:marks ("y" "z"))) "a"))
    (agent-ui-test-auc-flush)
    (should (equal (agent-ui-test-auc-text) "0/10 x,y,z\n\n"))
    (should (string-match-p "only lists"
                            (agent-ui-test-auc-message #'agent-ui-append "a" '(:value 3))))))

(ert-deftest agent-ui-canvas/point-kept ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter"))
    (agent-ui-show '(:id "b" :type "meter" :value 2))
    (with-current-buffer canvas
      ;; On b's text; a grows before it.
      (goto-char (point-min))
      (search-forward "2/")
      (agent-ui-update "a" '(:value 123456 :marks ("long" "marks")))
      (agent-ui--flush)
      (should (looking-at "10\n"))
      (should (looking-back "2/" 2)))))

(ert-deftest agent-ui-canvas/the-mark-kept-in-a-redrawn-component ()
  "The mark inside a component drawn again: kept at its line and column (its
text replaced, it fell to the component's start: a region there, text being
selected, stretched to it), as active as it was (doom-8gh)."
  (agent-ui-test-auc
    (agent-ui-define lines "Its text." :props ((text string "The text")) :text (lambda (p _c) (plist-get p :text)))
    (agent-ui-show '(:id "intro" :type "lines" :text "hello"))
    (agent-ui-show '(:id "t" :type "lines" :text "one\ntwo\nthree"))
    (with-current-buffer canvas
      (agent-ui--flush)
      (let ((transient-mark-mode t))
        (goto-char (point-min))
        (search-forward "two")
        (backward-char 1)
        (push-mark (point) t t)
        (search-forward "thr")
        (agent-ui-update "t" '(:text "ONE\nTWO\nTHREE"))
        (agent-ui--flush)
        (should (equal (buffer-substring-no-properties (region-beginning) (region-end)) "O\nTHR"))
        (should (region-active-p))
        ;; Not active: still where it was.
        (deactivate-mark)
        (agent-ui-update "t" '(:text "one\ntwo\nthree"))
        (agent-ui--flush)
        (should-not (region-active-p))
        (should (equal (buffer-substring-no-properties (mark) (point)) "o\nthr"))))))


(ert-deftest agent-ui-canvas/point-kept-in-a-redrawn-component ()
  "Point, a window's point and its start inside a component drawn again:
kept at their line and column in it (its text replaced, they went to its
start); past its new end, at its end."
  (agent-ui-test-auc
    (agent-ui-define lines "Its text." :props ((text string "The text")) :text (lambda (p _c) (plist-get p :text)))
    (agent-ui-show '(:id "intro" :type "lines" :text "hello"))
    (agent-ui-show '(:id "t" :type "lines" :text "one\ntwo\nthree\nfour"))
    (with-current-buffer canvas
      (agent-ui--flush)
      (goto-char (point-min))
      (search-forward "three")
      (backward-char 2)
      (agent-ui-update "t" '(:text "ONE\nTWO\nTHREE\nFOUR"))
      (agent-ui--flush)
      (should (looking-at "EE"))
      ;; Shorter: on its last line.
      (agent-ui-update "t" '(:text "just one"))
      (agent-ui--flush)
      (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "just one"))
      ;; Before it: where it was.
      (goto-char (+ (point-min) 2))
      (agent-ui-update "t" '(:text "again\nand again"))
      (agent-ui--flush)
      (should (= (point) (+ (point-min) 2))))
    ;; A window showing it, not selected: its point and start kept.
    (save-window-excursion
      (delete-other-windows)
      (let ((window (split-window)))
        (set-window-buffer window canvas)
        (agent-ui-update "t" '(:text "a\nb\nc\nd\ne"))
        (with-current-buffer canvas (agent-ui--flush))
        (let ((d (with-current-buffer canvas
                   (goto-char (point-min)) (search-forward "d") (match-beginning 0))))
          (set-window-point window d)
          (set-window-start window d)
          (with-current-buffer canvas (goto-char (point-min)))
          (agent-ui-update "t" '(:text "A\nB\nC\nD\nE"))
          (with-current-buffer canvas (agent-ui--flush))
          (with-current-buffer canvas
            (should (equal (char-after (window-point window)) ?D))
            (should (equal (char-after (window-start window)) ?D))))))))

;; ====== REMOVING ======

(ert-deftest agent-ui-canvas/removed ()
  (agent-ui-test-auc
    (dolist (id '("a" "b" "c"))
      (agent-ui-show (list :id id :type "meter" :title id)))
    (should (equal (agent-ui-remove "b") "b"))
    (should (equal (agent-ui-test-auc-text) "a\n0/10\n\nc\n0/10\n\n"))
    ;; A pending redraw of it: forgotten.
    (agent-ui-update "c" '(:value 5))
    (agent-ui-remove "c")
    (agent-ui-test-auc-flush)
    (should (equal (agent-ui-test-auc-text) "a\n0/10\n\n"))
    (should (string-match-p "no component \"c\"" (agent-ui-test-auc-message #'agent-ui-remove "c")))
    ;; Shown again: at the end.
    (agent-ui-show '(:id "b" :type "meter"))
    (should (equal (agent-ui-test-auc-text) "a\n0/10\n\n0/10\n\n"))
    (agent-ui-clear)
    (should (equal (agent-ui-test-auc-text) ""))
    (should-not (agent-ui-components))))

(ert-deftest agent-ui-canvas/empty-its-pane-closes ()
  "Cleared, or its last component removed: its pane closes (it stayed open,
empty); shown again, it opens. A pane made for it (a new window: tiling's,
with nothing before; display-buffer's, marked so) closes; a window that
showed another buffer goes back to it; a frame's last window stays."
  (agent-ui-test-auc
    (save-window-excursion
      (delete-other-windows)
      (let* ((window nil)
             (agent-ui-display-function
              (lambda (b)
                (setq window (split-window (frame-root-window) nil 'right))
                (set-window-buffer window b)
                ;; As tiling makes it: nothing shown there before.
                (set-window-prev-buffers window nil))))
        (agent-ui-show '(:id "a" :type "meter"))
        (agent-ui-show '(:id "b" :type "meter"))
        (should (eq (window-buffer window) canvas))
        (agent-ui-remove "a")
        (should (eq (window-buffer window) canvas))
        (agent-ui-remove "b")
        (should-not (window-live-p window))
        (should (one-window-p))
        ;; Shown again: a pane; cleared: gone.
        (agent-ui-show '(:id "c" :type "meter"))
        (should (window-live-p window))
        (agent-ui-clear)
        (should-not (window-live-p window))
        (should (buffer-live-p canvas)))
      ;; Made by display-buffer for it (marked so): closes, though the split
      ;; window showed another buffer first.
      (let* ((window nil)
             (agent-ui-display-function
              (lambda (b)
                (setq window (split-window (frame-root-window) nil 'right))
                (set-window-buffer window b)
                (set-window-parameter window 'quit-restore (list 'window 'window (selected-window) b)))))
        (agent-ui-show '(:id "d" :type "meter"))
        (agent-ui-clear)
        (should-not (window-live-p window)))
      ;; A window that showed another buffer: back to it.
      (let ((other (get-buffer-create "*test-before*")))
        (unwind-protect
            (let* ((window (split-window (frame-root-window) nil 'right))
                   (agent-ui-display-function (lambda (b) (set-window-buffer window b))))
              (set-window-buffer window other)
              (agent-ui-show '(:id "e" :type "meter"))
              (should (eq (window-buffer window) canvas))
              (agent-ui-clear)
              (should (window-live-p window))
              (should (eq (window-buffer window) other)))
          (kill-buffer other)))
      ;; The frame's last window: stays.
      (delete-other-windows)
      (let ((agent-ui-display-function (lambda (b) (set-window-buffer (selected-window) b)
                                         (set-window-prev-buffers (selected-window) nil))))
        (agent-ui-show '(:id "f" :type "meter"))
        (agent-ui-clear)
        (should (window-live-p (selected-window)))))))

;; ====== ANIMATION ======

(ert-deftest agent-ui-canvas/animated-while-there-are ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "a" :type "meter"))
    (should-not (buffer-local-value 'agent-ui--animation-timer canvas))
    (agent-ui-show '(:id "s" :type "spinner"))
    (should (timerp (buffer-local-value 'agent-ui--animation-timer canvas)))
    ;; A frame: drawn only while the canvas is in a window.
    (agent-ui--frame canvas)
    (should (equal (agent-ui-test-auc-text) "0/10\n\nspin 0\n\n"))
    (save-window-excursion
      (switch-to-buffer canvas)
      (agent-ui--frame canvas)
      (agent-ui--frame canvas))
    (should (equal (agent-ui-test-auc-text) "0/10\n\nspin 2\n\n"))
    ;; None left: its timer stopped.
    (agent-ui-remove "s")
    (should-not (buffer-local-value 'agent-ui--animation-timer canvas))))

(ert-deftest agent-ui-canvas/animation-stopped-while-hidden ()
  "A frame checks only the components animated, not every one; in no window,
the canvas's animation stops, and starts again once it's shown
\(doom-ht6.113)."
  (agent-ui-test-auc
    (agent-ui-define blinker "Animated while ON." :props ((on boolean "Animated"))
      :animated (lambda (props) (eq (plist-get props :on) t))
      :text (lambda (_props _ctx) "blink"))
    (dotimes (i 3)
      (agent-ui-show (list :id (format "m%d" i) :type "meter")))
    (agent-ui-show '(:id "b" :type "blinker"))
    (agent-ui-show '(:id "s" :type "spinner"))
    (should (timerp (buffer-local-value 'agent-ui--animation-timer canvas)))
    (save-window-excursion
      (switch-to-buffer canvas)
      (let ((checked nil))
        (cl-letf* ((check (symbol-function 'agent-ui-check))
                   ((symbol-function 'agent-ui-check)
                    (lambda (type component)
                      (push (plist-get component :type) checked)
                      (funcall check type component))))
          (agent-ui--frame canvas)
          (agent-ui--frame canvas))
        (should-not (member "blinker" checked))
        (should (equal (agent-ui-test-auc-text) "0/10\n\n0/10\n\n0/10\n\nblink\n\nspin 2\n\n"))))
    ;; In no window: its timer stopped, nothing drawn.
    (agent-ui--frame canvas)
    (should-not (buffer-local-value 'agent-ui--animation-timer canvas))
    (should (string-suffix-p "spin 2\n\n" (agent-ui-test-auc-text)))
    ;; Shown again: started again.
    (save-window-excursion
      (switch-to-buffer canvas)
      (with-current-buffer canvas
        (run-hook-with-args 'window-buffer-change-functions (selected-window)))
      (should (timerp (buffer-local-value 'agent-ui--animation-timer canvas)))
      (agent-ui--frame canvas)
      (should (string-suffix-p "spin 3\n\n" (agent-ui-test-auc-text))))))

(ert-deftest agent-ui-canvas/timers-stopped-when-killed ()
  (agent-ui-test-auc
    (agent-ui-show '(:id "s" :type "spinner"))
    (agent-ui-update "s" '(:title "x"))
    (let ((timers (with-current-buffer canvas
                    (list agent-ui--redraw-timer agent-ui--animation-timer))))
      (should (cl-every #'timerp timers))
      (kill-buffer canvas)
      (dolist (timer timers)
        (should-not (memq timer timer-list))))
    ;; The macro kills it again: a live one.
    (setq canvas (agent-ui-canvas))))

;; ====== A PANEL'S CHILDREN ======

(defconst agent-ui-test-auc-panel-type (gethash 'panel agent-ui--types)
  "The real panel type (the tests' registry, bound in each test, lacks it).")

(defun agent-ui-test-auc-with-panels ()
  "The real panel type, in the tests' registry."
  (puthash 'panel agent-ui-test-auc-panel-type agent-ui--types))

(defconst agent-ui-test-auc-panel
  '(:id "dash" :type "panel" :layout "row" :min-width 5
    :children ((:id "a" :type "meter" :value 1)
               (:type "panel" :border :false :children ((:id "b" :type "meter" :value 2)))))
  "A panel: a, and b in a panel in it.")

(ert-deftest agent-ui-canvas/a-panels-children-by-id ()
  (agent-ui-test-auc
    (agent-ui-test-auc-with-panels)
    (agent-ui-show agent-ui-test-auc-panel)
    ;; Listed after their panel; one without an id given its place's
    ;; (doom-ht6.51).
    (should (equal (agent-ui-components)
                   '((:id "dash" :type "panel") (:id "a" :type "meter" :panel "dash")
                     (:id "dash.2" :type "panel" :panel "dash") (:id "b" :type "meter" :panel "dash"))))
    (should (equal (agent-ui-get "b") '(:id "b" :type "meter" :value 2)))
    ;; Updated by its own id: its panel redrawn.
    (agent-ui-update "b" '(:value 7))
    (agent-ui-test-auc-flush)
    (should (string-match-p "1/10 +│ 7/10" (agent-ui-test-auc-text)))
    (should (equal (plist-get (agent-ui-get "b") :value) 7))
    ;; Appended to.
    (agent-ui-append "a" '(:marks ("x")))
    (agent-ui-test-auc-flush)
    (should (string-match-p "1/10 x" (agent-ui-test-auc-text)))
    ;; Shown again by its id: replaced in its place.
    (agent-ui-show '(:id "a" :type "spinner"))
    (agent-ui-test-auc-flush)
    (should (string-match-p "spin [0-9]+ +│ 7/10" (agent-ui-test-auc-text)))
    ;; Removed: out of its panel.
    (agent-ui-remove "a")
    (agent-ui-test-auc-flush)
    (should-not (agent-ui--find-child (agent-ui-get "dash") "a"))
    (should (string-match-p "7/10" (agent-ui-test-auc-text)))
    (should (string-match-p "no component \"a\"" (agent-ui-test-auc-message #'agent-ui-get "a")))))

(ert-deftest agent-ui-canvas/a-childs-id-taken ()
  (agent-ui-test-auc
    (agent-ui-test-auc-with-panels)
    (agent-ui-show agent-ui-test-auc-panel)
    (should (string-match-p "the id \"b\" is taken"
                            (agent-ui-test-auc-message #'agent-ui-show '(:id "other" :type "panel" :children ((:id "b" :type "meter"))))))
    ;; A wrong change to a child: refused, the panel as it was.
    (should (string-match-p "must be a number" (agent-ui-test-auc-message #'agent-ui-update "b" '(:value "x"))))
    (should (equal (plist-get (agent-ui-get "b") :value) 2))))

(ert-deftest agent-ui-canvas/a-childs-text-knows-it ()
  (agent-ui-test-auc
    (agent-ui-test-auc-with-panels)
    (agent-ui-show agent-ui-test-auc-panel)
    (with-current-buffer canvas
      (agent-ui--flush)
      (goto-char (point-min))
      (search-forward "2/10")
      (should (equal (get-text-property (match-beginning 0) 'agent-ui-child) "b"))
      (should (equal (get-text-property (match-beginning 0) 'agent-ui-id) "dash"))
      ;; Its link, its start.
      (should (equal (get-text-property (agent-ui--component-start canvas "b") 'agent-ui-child) "b")))))

(ert-deftest agent-ui-canvas/drawn-in-its-own-buffer-whatever-is-current ()
  "A component drawn while another buffer is current (what showed its canvas
selected another window, its buffer current): drawn in its canvas, the
other buffer untouched (a session's start was replaced by a component)."
  (agent-ui-test-auc
    (let ((other (agent-ui-test-buffer "agent-ui-other" "Other text.\n")))
      (unwind-protect
          (progn
            ;; Showing the canvas makes another buffer current.
            (let ((agent-ui-display-function (lambda (_canvas) (set-buffer other))))
              (agent-ui-show '(:id "m" :type "meter" :value 3 :max 4)))
            (should (equal (with-current-buffer other (buffer-string)) "Other text.\n"))
            (with-current-buffer canvas
              (should (string-search "3/4" (buffer-string)))
              (should (eq (marker-buffer (agent-ui--entry-end (gethash "m" agent-ui--entries))) canvas)))
            ;; Drawn again from the other buffer: in the canvas still.
            (with-current-buffer other
              (agent-ui--draw (gethash "m" (buffer-local-value 'agent-ui--entries canvas))
                              (with-current-buffer canvas (agent-ui--context)))
              (should (equal (buffer-string) "Other text.\n"))))
        (kill-buffer other)))))

(ert-deftest agent-ui-canvas/a-canvas-made ()
  (agent-ui-test-auc
    (should (equal (buffer-name canvas) (format "Agent UI: %s" agent-ui-default-canvas)))
    (with-current-buffer canvas
      (should (eq major-mode 'agent-ui-canvas-mode))
      (should buffer-read-only)
      (should truncate-lines)
      ;; Its keys: g redraws it, q kills it.
      (should (eq (lookup-key agent-ui-canvas-mode-map "g") #'agent-ui-canvas-redraw))
      (should (eq (lookup-key agent-ui-canvas-mode-map "q") #'agent-ui-quit)))
    ;; The same one again; others by name.
    (should (eq (agent-ui-canvas) canvas))
    (let ((other (agent-ui-canvas "other-test")))
      (unwind-protect
          (progn (should-not (eq other canvas))
                 (should (memq other (agent-ui-canvases)))
                 (should (memq canvas (agent-ui-canvases))))
        (kill-buffer other)))
    ;; Not a canvas: an error.
    (with-temp-buffer
      (should (string-match-p "isn't a live canvas"
                              (agent-ui-test-auc-message #'agent-ui-show '(:type "meter")
                                                 :canvas (current-buffer)))))))

;; doom-ht6.154
(ert-deftest agent-ui-canvas/a-title-given ()
  "A canvas showing several components, given a title: its bar and its
tab say it (they said Canvas, or its name), but a lone panel's, more
precise; taken back with \"\", or with its components when it's cleared;
its newlines spaces; the same title again, nothing told."
  (let ((panel (agent-ui-type "panel")))
    (agent-ui-test-auc
      (puthash 'panel panel agent-ui--types)
      (let* ((told 0)
             (agent-ui-title-changed-hook (list (lambda () (cl-incf told)))))
        (agent-ui-show '(:id "a" :type "meter"))
        (agent-ui-show '(:id "b" :type "meter"))
        (should-not (agent-ui-canvas-title canvas))
        (should-not (agent-ui-canvas-label canvas))
        (should (equal (agent-ui-set-title "  Demo\nrun ") "Demo run"))
        (should (= told 1))
        (should (equal (agent-ui-canvas-title canvas) "Demo run"))
        (should (equal (agent-ui-canvas-label canvas) "Agent UI: Demo run"))
        (agent-ui-set-title "Demo run")
        (should (= told 1))
        ;; Drawn as before: it names the canvas, not a component.
        (agent-ui-test-auc-flush)
        (should (equal (agent-ui-test-auc-text) "0/10\n\n0/10\n\n"))
        ;; A lone panel with a title: its title, as ever; gone, the given one.
        (agent-ui-remove "a")
        (agent-ui-remove "b")
        (agent-ui-show '(:id "p" :type "panel" :title "Release" :children ((:id "m" :type "meter"))))
        (should (equal (agent-ui-canvas-title canvas) "Release"))
        (agent-ui-show '(:id "c" :type "meter"))
        (should (equal (agent-ui-canvas-title canvas) "Demo run"))
        ;; Taken back.
        (should-not (agent-ui-set-title ""))
        (should-not (agent-ui-canvas-title canvas))
        ;; Told each time: the panel come and gone too.
        (should (= told 4))
        (agent-ui-set-title "Again")
        (agent-ui-clear)
        (should-not (agent-ui-canvas-title canvas))
        (should-not (buffer-local-value 'agent-ui--given-title canvas))
        (should (= told 6))))))

;; doom-ht6.156
(ert-deftest agent-ui-canvas/panels-titles-in-their-borders ()
  "Panels with borders on a session's canvas: each its title in its top
border, none over it.  One left alone: its title on its bar (see
`agent-ui-canvas-title'), its border plain.  Another component shown: in
its border again."
  (let ((panel (agent-ui-type "panel")))
    (agent-ui-test-auc
      (puthash 'panel panel agent-ui--types)
      (agent-ui-show '(:id "p" :type "panel" :title "Release" :children ((:id "m" :type "meter"))))
      (agent-ui-show '(:id "q" :type "panel" :title "Health" :children ((:id "n" :type "meter"))))
      (agent-ui-test-auc-flush)
      (let ((text (agent-ui-test-auc-text)))
        (should (string-match-p "^╭─ Release ─+╮$" text))
        (should (string-match-p "^╭─ Health ─+╮$" text))
        (should-not (string-match-p "^\\(Release\\|Health\\)$" text)))
      (agent-ui-remove "q")
      (agent-ui-test-auc-flush)
      (should (equal (agent-ui-canvas-title canvas) "Release"))
      (should (string-match-p "\\`╭─+╮$" (agent-ui-test-auc-text)))
      (should-not (string-search "Release" (agent-ui-test-auc-text)))
      (agent-ui-show '(:id "c" :type "meter"))
      (agent-ui-test-auc-flush)
      (should (string-match-p "^╭─ Release ─+╮$" (agent-ui-test-auc-text))))))

(ert-deftest agent-ui-canvas/a-title-given-wrong-or-early ()
  "A title that isn't text, or for a canvas going by a name of its own (a
dashboard): refused. For a canvas not there yet: it's made, its pane not
opened (its first component opens it); taken back from one not there:
nothing made."
  (agent-ui-test-auc
    (should (string-match-p "give a title, text" (agent-ui-test-auc-message #'agent-ui-set-title 5)))
    (with-current-buffer canvas (setq-local agent-ui-canvas-name "service"))
    (should (string-match-p "goes by its name, service: it takes no title"
                            (agent-ui-test-auc-message #'agent-ui-set-title "X")))
    (should-not (agent-ui-canvas-title canvas))
    (let ((other (make-temp-name "titled-")))
      (unwind-protect
          (progn
            (should-not (agent-ui-set-title "" :canvas other))
            (should-not (get-buffer (agent-ui-canvas-buffer-name other)))
            (should (equal (agent-ui-set-title "Early" :canvas other) "Early"))
            (let ((buffer (get-buffer (agent-ui-canvas-buffer-name other))))
              (should buffer)
              (should-not (memq buffer agent-ui-test-auc-displayed))
              (should-not (agent-ui-canvas-shows-p buffer))
              (should (equal (agent-ui-canvas-title buffer) "Early"))
              (agent-ui-show '(:id "x" :type "meter") :canvas other)
              (should (memq buffer agent-ui-test-auc-displayed))
              (should (equal (agent-ui-canvas-title buffer) "Early"))))
        (when (get-buffer (agent-ui-canvas-buffer-name other))
          (kill-buffer (agent-ui-canvas-buffer-name other)))))))

;;; agent-ui-canvas-tests.el ends here
