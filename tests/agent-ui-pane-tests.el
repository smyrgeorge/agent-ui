;;; agent-ui-pane-tests.el --- Tests for Agent UI: pane  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-pane.el: a session's Agent UI in its session's pane, the
;; bottom half, its views in a grid, the session's mode line under the
;; conversation; synced as windows change (a batch Emacs doesn't run window
;; change functions: the tests sync where Emacs would). No agent runs: the
;; session is a buffer. With tiling: test-agent-ui-tiling.el.

;;; Code:

(require 'agent-ui-test-helper)

;; ====== HELPERS ======

(defmacro agent-ui-test-aupn (&rest body)
  "BODY from one window on a session's buffer (`session', its canvas's name
`name'); its canvases killed after, its Agent UI shown again."
  (declare (indent 0))
  `(agent-ui-test-with-reset
     (let* ((agent-ui-focus-questions nil)
            (agent-ui-close-finished nil)
            (session (agent-ui-test-buffer "Claude Agent @ pane" "The conversation.\n"))
            (sessions (list session)))
       (cl-letf (((symbol-function 'agent-ui--sessions) (lambda () sessions))
                 ((symbol-function 'message) #'ignore))
         (switch-to-buffer session)
         (let ((name (agent-ui--session-name session)))
           (unwind-protect (progn ,@body)
             (dolist (canvas (agent-ui-canvases)) (kill-buffer canvas))
             (when (buffer-live-p session)
               (kill-buffer session))))))))

(defun agent-ui-test-aupn-show (canvas &optional id)
  "A component ID (default \"x\") shown on CANVAS (a name)."
  (agent-ui-show `(:id ,(or id "x") :type "text" :text "something") :canvas canvas))

(defun agent-ui-test-aupn-cells ()
  "The views' windows of the selected frame, in order: their buffers' names."
  (mapcar (lambda (window) (buffer-name (window-buffer window)))
          (agent-ui--pane-cells (selected-frame))))

(defun agent-ui-test-aupn-bar (window &optional parameter)
  "WINDOW's bar (its header line; PARAMETER: that one, its mode line), as
text; nil without one."
  (let ((format (window-parameter window (or parameter 'header-line-format))))
    (and (consp format)
         (mapconcat (lambda (part) (if (stringp part) part "")) format ""))))

(defun agent-ui-test-aupn-canvas (name &optional part)
  (get-buffer (agent-ui-canvas-buffer-name (if part (agent-ui-sub-canvas name part) name))))

;; ====== SETTINGS ======

(ert-deftest agent-ui-pane/settings ()
  (should-not (boundp 'agent-ui-pane-share))
  (should (= (default-value 'agent-ui-pane-max-share) 0.5))
  (should (= (default-value 'agent-ui-pane-min-lines) 6))
  (should (= (default-value 'agent-ui-grid-min-width) 40))
  ;; Agent UI shows a session's canvases so (agent-ui-pane.el).
  (should (eq agent-ui-display-function #'agent-ui-pane-display))
  (should (eq agent-ui-reveal-function #'agent-ui-pane-reveal))
  ;; By default, Agent UI's own bar under the views, with its keys.
  (should-not (eval (car (get 'agent-ui-pane-mode-line 'standard-value)) t))
  (should (memq #'agent-ui--pane-sync-h (default-value 'window-state-change-functions)))
  (should (assq 'agent-ui-pane window-persistent-parameters)))

;; ====== ITS HEIGHT ======

(ert-deftest agent-ui-pane/its-height-bounds ()
  "6 lines at least, half the pane at most, the conversation keeping 6
lines; in between, what the views need."
  (should (= (agent-ui--pane-most 64) 32))
  (should (= (agent-ui--pane-most 14) 7))
  (should (= (agent-ui--pane-most 10) 6)))

(ert-deftest agent-ui-pane/grows-with-what-it-shows ()
  "Something taller shown: Agent UI grows to fit it (its bars too), up to
half the pane; gone again: as small as what's left. Only when what it needs
changes: a height you gave it stays while a component changes without
needing more."
  (agent-ui-test-aupn
    (let* ((window (selected-window))
           (pane (window-total-height window))
           (area (lambda () (window-total-height (window-next-sibling window)))))
      (agent-ui-test-aupn-show name)
      (should (= (funcall area) agent-ui-pane-min-lines))
      ;; 8 lines: 10 with its bar and the one under it.
      (agent-ui-show '(:id "lines" :type "text" :text "1\n2\n3\n4\n5\n6\n7") :canvas name)
      (agent-ui--pane-fit-now)
      (let ((wanted (min (agent-ui--pane-most pane)
                         (max agent-ui-pane-min-lines
                              (+ 2 (with-current-buffer (agent-ui-test-aupn-canvas name)
                                    (count-lines (point-min) (point-max))))))))
        (should (> wanted agent-ui-pane-min-lines))
        (should (= (funcall area) wanted)))
      ;; Much taller: half at most.
      (agent-ui-show `(:id "lines" :type "text" :text ,(mapconcat #'number-to-string (number-sequence 1 60) "\n"))
                     :canvas name)
      (agent-ui--pane-fit-now)
      (should (= (funcall area) (agent-ui--pane-most pane)))
      ;; Gone: as small as what's left.
      (agent-ui-remove "lines" :canvas name)
      (agent-ui--pane-fit-now)
      (should (= (funcall area) agent-ui-pane-min-lines))
      ;; Made taller by hand: kept while what it shows needs no more.
      (window-resize (window-next-sibling window) 2)
      (let ((yours (funcall area)))
        (agent-ui-show '(:id "x" :type "text" :text "something else") :canvas name)
        (agent-ui--pane-fit-now)
        (should (= (funcall area) yours))))))

;; ====== THE GRID ======

(ert-deftest agent-ui-pane/the-layout-planned ()
  "For each count of columns, the views dealt in: the session's own first in
the first column, the others the tallest first, each into the column with
the fewest lines (the leftmost of those), each column's in their order. Of
those, the least height, then the least room left empty, then the fewest
columns; each view at least its width; the room left across shared out; no
column holding more views than its lines have room for."
  ;; Four short views: a wide pane, side by side; 80 columns, two by two.
  (should (equal (agent-ui--pane-plan '(4 4 4 4) '(40 40 40 40) 205 32)
                 '(((0) (1) (2) (3)) (52 51 51 51) 4)))
  (should (equal (car (agent-ui--pane-plan '(4 4 4 4) '(40 40 40 40) 80 32)) '((0 2) (1 3))))
  ;; A tall view: the short ones stacked beside it, not each its own column;
  ;; whatever their order.
  (should (equal (car (agent-ui--pane-plan '(20 4 4) '(40 40 40) 205 32)) '((0) (1 2))))
  (should (equal (car (agent-ui--pane-plan '(4 20 4) '(40 40 40) 205 32)) '((0 2) (1))))
  (should (equal (agent-ui--pane-deal '(4 20 4 3) 2) '((0 2 3) (1))))
  ;; A wide one (80): no room for three columns in 130; two.
  (should (equal (agent-ui--pane-plan '(5 5 5) '(80 40 40) 130 32)
                 '(((0 2) (1)) (85 45) 10)))
  ;; None fits across.
  (should-not (agent-ui--pane-plan '(4) '(80) 60 32))
  ;; Height and room left empty together: three full columns a line taller
  ;; than four with two half empty (a diff wide, 80, among them).
  (should (equal (car (agent-ui--pane-plan '(10 14 12 12 11 10) '(40 40 40 40 40 80) 205 32))
                 '((0 3) (1 5) (2 4))))
  ;; 6 lines: two views a column at most (3 lines each).
  (should (equal (car (agent-ui--pane-plan '(3 3 3) '(40 40 40) 80 6)) '((0 2) (1))))
  (should-not (agent-ui--pane-plan '(3 3 3) '(40 40 40) 40 6)))

(ert-deftest agent-ui-pane/a-wide-view-wider ()
  "A view showing a wide type (a diff, code, a graph...): 80 columns at
least; another, 40."
  (agent-ui-test-aupn
    (agent-ui-show '(:id "x" :type "text" :text "words") :canvas name)
    (agent-ui-show '(:id "d" :type "diff" :diff "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n")
                   :canvas (agent-ui-sub-canvas name "diff"))
    (should (= (agent-ui--pane-view-width (agent-ui-test-aupn-canvas name)) 40))
    (should (= (agent-ui--pane-view-width (agent-ui-test-aupn-canvas name "diff")) 80))))

;; ====== IN THE SESSION'S PANE ======

(ert-deftest agent-ui-pane/the-first-component-in-the-sessions-pane ()
  "The first component: the session's pane split, Agent UI at its bottom (a
quarter of it: little to show), a view of its own; the focus stays in the conversation; the conversation
keeps its mode line, the view has a bar instead (its name, the keys): Agent
UI's own, without `agent-ui-pane-mode-line'."
  (agent-ui-test-aupn
    (let ((agent-ui-pane-mode-line nil)
          (agent-ui-pane-keys "q close a view · SPC m u hide Agent UI")
          (window (selected-window))
          (height (window-total-height)))
      (agent-ui-test-aupn-show name)
      (let ((cell (car (agent-ui--pane-cells (selected-frame))))
            (canvas (agent-ui-test-aupn-canvas name)))
        (should cell)
        (should (eq (window-buffer cell) canvas))
        (should (eq (selected-window) window))
        ;; A quarter, under the conversation, in its pane's group.
        (should (eq (window-next-sibling window) cell))
        (should (= (window-total-height cell) (max 6 (round (* 0.25 height)))))
        (should (= (+ (window-total-height window) (window-total-height cell)) height))
        (should (agent-ui-pane-window-p cell))
        (should-not (agent-ui-pane-window-p window))
        ;; Its name on its bar (Canvas: Agent UI is the bar's under it);
        ;; under it, Agent UI's bar: what it is, its keys. No tab line;
        ;; the conversation's mode line its own.
        (should (eq (window-parameter cell 'tab-line-format) 'none))
        (should-not (window-parameter window 'mode-line-format))
        (should (equal (agent-ui-test-aupn-bar cell) " Canvas"))
        (let ((under (agent-ui-test-aupn-bar cell 'mode-line-format)))
          (should (string-prefix-p " Agent UI" under))
          (should-not (string-search "views" under))
          (should (string-search "q close a view" under)))
        (should (window-dedicated-p cell))
        ;; Synced again: as it is.
        (agent-ui--pane-sync)
        (should (eq (car (agent-ui--pane-cells (selected-frame))) cell))))))


(ert-deftest agent-ui-pane/their-buffers-mode-line-under-its-views ()
  "With `agent-ui-pane-mode-line' (the config's): the views at the bottom
keep their buffer's own mode line (the editor's, as tall as the windows'
beside them), the others none; what Agent UI's bar said there, through
`agent-ui-pane-mode-line-text': what it is and its views under the
leftmost, its keys under the rightmost (one column: both); a view saying
nothing (the config: no keys), nil."
  (agent-ui-test-aupn
    (let ((agent-ui-pane-mode-line t)
          (agent-ui-pane-keys "q close"))
      (agent-ui-test-aupn-show name)
      (let ((cell (car (agent-ui--pane-cells (selected-frame)))))
        (should-not (window-parameter cell 'mode-line-format))
        (should (equal (agent-ui-pane-mode-line-text cell) '("Agent UI" . "q close")))
        (with-selected-window cell
          (should (equal (agent-ui-pane-mode-line-text) '("Agent UI" . "q close")))))
      (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
      (agent-ui-test-aupn-show (agent-ui-sub-canvas name "logs"))
      ;; The first column: the canvas, tests under it; logs beside them.
      (pcase-let ((`(,a ,b ,c) (agent-ui--pane-cells (selected-frame))))
        (should (eq (window-parameter a 'mode-line-format) 'none))
        (should-not (agent-ui-pane-mode-line-text a))
        (should-not (window-parameter b 'mode-line-format))
        (should (equal (agent-ui-pane-mode-line-text b) '("Agent UI · 3 views")))
        (should-not (window-parameter c 'mode-line-format))
        (should (equal (agent-ui-pane-mode-line-text c) '(nil . "q close")))
        (let ((agent-ui-pane-keys nil))
          (should-not (agent-ui-pane-mode-line-text c))))
      ;; Not a view: nothing.
      (should-not (agent-ui-pane-mode-line-text (frame-first-window))))))

(ert-deftest agent-ui-pane/its-views-in-columns ()
  "The session's other canvases: views too, its own first. Two short ones
side by side; a third as tall: dealt into the first column, under the
session's own (80 columns: two at most), the other column across the whole
height; each its name on its bar. Agent UI's bar under them: what it is
under the leftmost column, the keys under the rightmost; the others' none."
  (agent-ui-test-aupn
   (let ((agent-ui-pane-mode-line nil)
         (agent-ui-pane-keys "q close a view · SPC m u hide Agent UI"))
    (agent-ui-test-aupn-show name)
    (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
    (should (equal (agent-ui-test-aupn-cells)
                   (list (agent-ui-canvas-buffer-name name)
                         (agent-ui-canvas-buffer-name (agent-ui-sub-canvas name "tests")))))
    (pcase-let ((`(,a ,b) (agent-ui--pane-cells (selected-frame))))
      (should (= (window-top-line a) (window-top-line b)))
      (should (< (window-left-column a) (window-left-column b)))
      (should (string-prefix-p " Agent UI · 2 views" (agent-ui-test-aupn-bar a 'mode-line-format)))
      (should-not (string-search "q close" (agent-ui-test-aupn-bar a 'mode-line-format)))
      (should (string-search "q close a view" (agent-ui-test-aupn-bar b 'mode-line-format)))
      (should-not (string-search "Agent UI ·" (agent-ui-test-aupn-bar b 'mode-line-format))))
    (agent-ui-test-aupn-show (agent-ui-sub-canvas name "logs"))
    (should (equal (agent-ui-test-aupn-cells)
                   (mapcar #'agent-ui-canvas-buffer-name
                           (list name (agent-ui-sub-canvas name "tests") (agent-ui-sub-canvas name "logs")))))
    (pcase-let ((`(,a ,b ,c) (agent-ui--pane-cells (selected-frame))))
      ;; The first column: Agent UI, tests under it; logs beside them.
      (should (= (window-left-column a) (window-left-column b)))
      (should (> (window-top-line b) (window-top-line a)))
      (should (> (window-left-column c) (window-left-column a)))
      (should (= (window-top-line c) (window-top-line a)))
      (should (= (window-total-height c) (+ (window-total-height a) (window-total-height b))))
      (should (equal (agent-ui-test-aupn-bar a) " Canvas"))
      (should (string-prefix-p " tests" (agent-ui-test-aupn-bar b)))
      (should (string-prefix-p " logs" (agent-ui-test-aupn-bar c)))
      ;; The bar under them: under tests (leftmost), under logs (the keys).
      (should (eq (window-parameter a 'mode-line-format) 'none))
      (should (string-prefix-p " Agent UI · 3 views" (agent-ui-test-aupn-bar b 'mode-line-format)))
      (should (string-search "q close a view" (agent-ui-test-aupn-bar c 'mode-line-format))))
    ;; The conversation's window: only it, above them.
    (should (= (length (window-list nil 'nomini)) 4)))))

(ert-deftest agent-ui-pane/q-closes-a-view ()
  "q in a view: its canvas killed, the others laid out again, the cursor in
the session."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
    (let ((tests (agent-ui-test-aupn-canvas name "tests")))
      (select-window (get-buffer-window tests))
      (agent-ui-quit)
      (agent-ui--pane-sync)
      (should-not (buffer-live-p tests))
      (should (eq (window-buffer (selected-window)) session))
      (should (equal (agent-ui-test-aupn-cells) (list (agent-ui-canvas-buffer-name name))))
      ;; Across the width again.
      (should (= (window-total-width (car (agent-ui--pane-cells (selected-frame))))
                 (window-total-width (selected-window)))))))

(ert-deftest agent-ui-pane/a-views-window-closed-hides-it ()
  "A view's window closed (SPC w d) while it shows something: hidden, the
others laid out again; something new shown in it: back."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
    (delete-window (get-buffer-window (agent-ui-test-aupn-canvas name "tests")))
    (agent-ui--pane-sync)
    (should (equal (agent-ui-test-aupn-cells) (list (agent-ui-canvas-buffer-name name))))
    (should (buffer-live-p (agent-ui-test-aupn-canvas name "tests")))
    (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests") "y")
    (should (equal (length (agent-ui-test-aupn-cells)) 2))))

(ert-deftest agent-ui-pane/emptied-its-view-gone ()
  "A view emptied (its last component removed): its window gone, the others
laid out again; its next component shows it again."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
    (agent-ui-remove "x" :canvas name)
    (agent-ui--pane-sync)
    (should (equal (agent-ui-test-aupn-cells)
                   (list (agent-ui-canvas-buffer-name (agent-ui-sub-canvas name "tests")))))
    (agent-ui-test-aupn-show name "y")
    (should (equal (length (agent-ui-test-aupn-cells)) 2))))

(ert-deftest agent-ui-pane/hidden-and-shown-again ()
  "SPC m u: Agent UI hidden for the session, the conversation its whole
pane; a new component leaves it hidden; SPC m u again, or a question, shows it."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (let ((height (window-total-height (frame-root-window))))
      (agent-ui-pane-toggle)
      (should-not (agent-ui-test-aupn-cells))
      (should (= (window-total-height (selected-window)) (- height (window-total-height (minibuffer-window)) -1)))
      (agent-ui-test-aupn-show name "y")
      (should-not (agent-ui-test-aupn-cells))
      (agent-ui-pane-toggle)
      (should (equal (length (agent-ui-test-aupn-cells)) 1))
      ;; From a view: hidden, the cursor in the conversation.
      (select-window (car (agent-ui--pane-cells (selected-frame))))
      (agent-ui-pane-toggle)
      (should-not (agent-ui-test-aupn-cells))
      (should (eq (window-buffer (selected-window)) session))
      ;; A question shows it anyway.
      (agent-ui-show '(:id "fix" :type "choice" :question "Which?" :options ("A" "B")) :canvas name)
      (agent-ui-goto-question)
      (should (equal (length (agent-ui-test-aupn-cells)) 1))
      (should (eq (window-buffer (selected-window)) (agent-ui-test-aupn-canvas name))))))

(ert-deftest agent-ui-pane/a-session-in-no-window-waits ()
  "The session's pane showing another buffer: its views gone; a component
shown meanwhile opens nothing; the session shown again: they come back."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (switch-to-buffer (agent-ui-test-buffer "notes.txt"))
    (agent-ui--pane-sync)
    (should-not (agent-ui-test-aupn-cells))
    (should (= (length (window-list nil 'nomini)) 1))
    (agent-ui-test-aupn-show name "y")
    (should (= (length (window-list nil 'nomini)) 1))
    (switch-to-buffer session)
    (agent-ui--pane-sync)
    (should (equal (length (agent-ui-test-aupn-cells)) 1))))

(ert-deftest agent-ui-pane/the-conversation-closed-takes-its-views ()
  "The conversation's window deleted (SPC w d): its views' windows with it,
the room to the other window."
  (agent-ui-test-aupn
    (let ((other (split-window nil nil 'right)))
      (set-window-buffer other (agent-ui-test-buffer "notes.txt"))
      (agent-ui-test-aupn-show name)
      (should (equal (length (agent-ui-test-aupn-cells)) 1))
      (delete-window (selected-window))
      (should-not (agent-ui-test-aupn-cells))
      (should (equal (window-list nil 'nomini) (list other))))))

(ert-deftest agent-ui-pane/the-frame-s-main-window-never-deleted ()
  "The conversation the frame's main window (a side window open beside it,
a popup): closing it is refused as Emacs refuses it, its window kept.  A
view left the main window (C-x 1 in it, a side window that stays): never
deleted, a window like any (doom-ht6.129)."
  (agent-ui-test-aupn
    (let ((popup (display-buffer-in-side-window (agent-ui-test-buffer "*popup*") '((side . bottom)))))
      (agent-ui-test-aupn-show name)
      (should (equal (length (agent-ui-test-aupn-cells)) 1))
      (let ((conversation (get-buffer-window session)))
        (should-error (delete-window conversation))
        (should (window-live-p conversation))
        (should (eq (window-buffer conversation) session)))
      (should (window-live-p popup))
      (delete-window popup)))
  (agent-ui-test-aupn
    (let ((popup (display-buffer-in-side-window (agent-ui-test-buffer "*side*") '((side . left)))))
      (set-window-parameter popup 'no-delete-other-windows t)
      (agent-ui-test-aupn-show name)
      (let ((view (get-buffer-window (agent-ui-test-aupn-canvas name))))
        (should view)
        (with-selected-window view (delete-other-windows))
        (agent-ui--pane-sync)
        ;; The view's window, the frame's main one: kept.
        (should (window-live-p view))
        (should (seq-some (lambda (w) (not (window-parameter w 'window-side)))
                          (window-list nil 'nomini))))
      (delete-window popup))))

(ert-deftest agent-ui-pane/a-pane-too-short-a-pane-of-its-own ()
  "A session's pane too short for both halves: the view in a window of its
own, as without a session's pane."
  (agent-ui-test-aupn
    (let ((agent-ui-pane-min-lines 20))
      (agent-ui-test-aupn-show name)
      (should-not (agent-ui-test-aupn-cells))
      (should (get-buffer-window (agent-ui-test-aupn-canvas name))))))

(ert-deftest agent-ui-pane/a-canvas-without-a-session ()
  "A canvas of no session (a shell's request): in a window of its own."
  (agent-ui-test-aupn
    (unwind-protect
        (progn
          (agent-ui-test-aupn-show "from-a-shell")
          (should-not (agent-ui-test-aupn-cells))
          (should (get-buffer-window (agent-ui-test-aupn-canvas "from-a-shell"))))
      (when-let* ((canvas (agent-ui-test-aupn-canvas "from-a-shell")))
        (kill-buffer canvas)))))

(ert-deftest agent-ui-pane/skipped-windows ()
  "A window `agent-ui-pane-skip-functions' leave out (a crew's frame): no
Agent UI in it."
  (agent-ui-test-aupn
    (let ((agent-ui-pane-skip-functions (list (lambda (_window) t))))
      (agent-ui-test-aupn-show name)
      (should-not (agent-ui-test-aupn-cells)))))

(ert-deftest agent-ui-pane/kept-with-the-session-only ()
  "The session's buffer killed: its views' windows gone with its canvases."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (let ((other (split-window nil nil 'right)))
      (set-window-buffer other (agent-ui-test-buffer "notes.txt"))
      (kill-buffer session)
      (agent-ui--pane-sync)
      (should-not (agent-ui-test-aupn-cells)))))

(ert-deftest agent-ui-pane/one-sessions-views-in-one-window ()
  "The session in two windows: its views under the first only."
  (agent-ui-test-aupn
    (let ((second (split-window nil nil 'right)))
      (set-window-buffer second session)
      (agent-ui-test-aupn-show name)
      (should (equal (length (agent-ui-test-aupn-cells)) 1))
      (let ((cell (car (agent-ui--pane-cells (selected-frame)))))
        (should (eq (window-next-sibling (frame-first-window)) cell))))))

(ert-deftest agent-ui-pane/a-session-in-two-windows-its-views-stay ()
  "The session in two windows of different widths, the second selected: its
views under the first, fitted and planned again there, not laid out anew
at each round (they moved under the second, sync made them again under
the first, without end).  Views 20 columns at least: one column under the
first's 30, two would fit under the second's 50."
  (let ((agent-ui-grid-min-width 20))
    (agent-ui-test-aupn
      (let* ((first (selected-window))
             (second (split-window first 30 'right))
             (under-first (lambda ()
                            (and (eq (window-buffer (frame-first-window)) session)
                                 (agent-ui--pane-in-place-p
                                  (frame-first-window) (agent-ui--pane-cells (selected-frame) session)))))
             (rebuilt 0))
        (set-window-buffer second session)
        (select-window second)
        (agent-ui-test-aupn-show name)
        (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
        (agent-ui--pane-sync)
        (should (funcall under-first))
        (advice-add 'agent-ui--pane-attach :after (lambda (&rest _) (cl-incf rebuilt)) '((name . test-rebuilt)))
        (unwind-protect
            (dotimes (_ 3)
              (cl-pushnew session agent-ui--pane-to-fit)
              (agent-ui--pane-fit-now)
              (should (funcall under-first))
              (cl-pushnew session agent-ui--pane-to-replan)
              (agent-ui--pane-replan-now)
              (should (funcall under-first))
              (agent-ui--pane-sync)
              (should (funcall under-first)))
          (advice-remove 'agent-ui--pane-attach 'test-rebuilt)
          (when (timerp agent-ui--pane-fit-timer)
            (cancel-timer agent-ui--pane-fit-timer))
          (when (timerp agent-ui--pane-resize-timer)
            (cancel-timer agent-ui--pane-resize-timer))
          (setq agent-ui--pane-fit-timer nil agent-ui--pane-resize-timer nil
                agent-ui--pane-to-fit nil agent-ui--pane-to-replan nil))
        ;; Planned again once settled, at most: not at each round.
        (should (<= rebuilt 1))))))

(ert-deftest agent-ui-pane/a-view-window-of-no-canvas-left-alone ()
  "A window marked as a view but showing no canvas (a workspace's windows
made again at startup, its buffers gone): a window like any again, kept."
  (agent-ui-test-aupn
    (let ((other (split-window nil nil 'below)))
      (set-window-buffer other (agent-ui-test-buffer "notes.txt"))
      (set-window-parameter other 'agent-ui-pane t)
      (set-window-dedicated-p other t)
      (agent-ui--pane-sync)
      (should (window-live-p other))
      (should-not (agent-ui-pane-window-p other))
      (should-not (window-dedicated-p other)))))

(ert-deftest agent-ui-pane/views-closed-less-room ()
  "Views closed (q, SPC w d): the others laid out again as a grid of their
count (two left in two rows: side by side), Agent UI as high as they need
now, as small as they need."
  (agent-ui-test-aupn
    (let* ((window (selected-window))
           (pane (window-total-height window))
           (area (lambda () (window-total-height (window-next-sibling window))))
           (text "line 1\nline 2"))
      (dolist (canvas (list name (agent-ui-sub-canvas name "b") (agent-ui-sub-canvas name "c")
                            (agent-ui-sub-canvas name "d")))
        (agent-ui-show `(:id "x" :type "text" :text ,text) :canvas canvas))
      (agent-ui--pane-fit-now)
      (let ((four (funcall area)))
        (should (= (length (agent-ui--pane-cells (selected-frame))) 4))
        (should (> four agent-ui-pane-min-lines))
        ;; The top two closed: q on one, SPC w d on the other.
        (select-window (get-buffer-window (agent-ui-test-aupn-canvas name)))
        (agent-ui-quit)
        (agent-ui--pane-sync)
        (delete-window (get-buffer-window (agent-ui-test-aupn-canvas name "b")))
        (agent-ui--pane-sync)
        (let ((cells (agent-ui--pane-cells (selected-frame))))
          (should (= (length cells) 2))
          (should (= (window-top-line (car cells)) (window-top-line (cadr cells)))))
        (should (< (funcall area) four))
        (should (= (funcall area) agent-ui-pane-min-lines))))))

(ert-deftest agent-ui-pane/no-empty-lines-under-its-views ()
  "Views shorter than a quarter of the pane: Agent UI as high as they need
\(their lines, their bars, the bar under them), no empty lines under them,
the conversation keeping the rest."
  (agent-ui-test-aupn
    (let* ((agent-ui-pane-min-lines 3)
           (window (selected-window))
           (pane (window-total-height window)))
      (agent-ui-show '(:id "x" :type "text" :text "one") :canvas name)
      ;; Measured again once drawn (a timer, after the redraw).
      (agent-ui--pane-fit-now)
      (let* ((cell (car (agent-ui--pane-cells (selected-frame))))
             (lines (with-current-buffer (window-buffer cell) (count-lines (point-min) (point-max)))))
        (should (< (window-total-height cell) (round (* 0.25 pane))))
        (should (= (window-total-height cell) (+ lines 2)))
        (should (= (window-body-height cell) lines))
        (should (= (window-total-height window) (- pane lines 2)))))))

(ert-deftest agent-ui-pane/a-view-that-fits-from-its-top ()
  "A view whose content fits its window, scrolled down (shrunk, then grown
again): shown from its top at the next sync, nothing hidden above it."
  (agent-ui-test-aupn
    (agent-ui-show '(:id "x" :type "text" :text "one\ntwo\nthree") :canvas name)
    (let ((cell (car (agent-ui--pane-cells (selected-frame)))))
      (with-current-buffer (window-buffer cell)
        (set-window-start cell (save-excursion (goto-char (point-min)) (forward-line 1) (point)) t))
      (should (> (window-start cell) 1))
      (agent-ui--pane-sync)
      (should (= (window-start cell) (with-current-buffer (window-buffer cell) (point-min)))))))

(ert-deftest agent-ui-pane/each-view-its-own-height ()
  "Views of different heights: each as high as its content in its column (the
short ones stacked beside the tall one), no empty lines under them."
  (agent-ui-test-aupn
    (let ((agent-ui-pane-min-lines 3))
      (agent-ui-test-aupn-show name)
      (agent-ui-test-aupn-show (agent-ui-sub-canvas name "b"))
      (agent-ui-show '(:id "x" :type "text" :text "1\n2\n3\n4\n5") :canvas (agent-ui-sub-canvas name "c"))
      (agent-ui--pane-fit-now)
      (pcase-let ((`(,a ,_b ,c) (agent-ui--pane-cells (selected-frame))))
        (should (< (window-total-height a) (window-total-height c)))
        (dolist (cell (list a c))
          (should (= (window-body-height cell)
                     (with-current-buffer (window-buffer cell) (count-lines (point-min) (point-max))))))))))

(ert-deftest agent-ui-pane/a-window-change-measures-only-what-changed ()
  "Window changes with nothing changed in the views (C-x o, a popup): no view
measured again, no component checked (each view's whole buffer was laid
out, each component looked at, at every one); a component added to one
view: that one measured again alone. Their heights the same."
  (agent-ui-test-aupn
    (let ((agent-ui-pane-min-lines 3)
          (tests (agent-ui-sub-canvas name "tests"))
          measured checked)
      (agent-ui-test-aupn-show name)
      (agent-ui-show '(:id "x" :type "text" :text "1\n2\n3\n4\n5") :canvas tests)
      (agent-ui--pane-fit-now)
      (agent-ui--pane-sync)
      (let ((heights (mapcar #'window-pixel-height (agent-ui--pane-cells (selected-frame))))
            (wanted (buffer-local-value 'agent-ui--pane-height session))
            (size (symbol-function 'window-text-pixel-size))
            (ids (symbol-function 'agent-ui--animated-ids)))
        (cl-letf (((symbol-function 'window-text-pixel-size)
                   (lambda (&optional window &rest args)
                     (push window measured)
                     (apply size window args)))
                  ((symbol-function 'agent-ui--animated-ids)
                   (lambda () (push (current-buffer) checked) (funcall ids))))
          (dotimes (_ 3)
            (agent-ui--pane-sync-h (selected-frame)))
          (should-not measured)
          (should-not checked)
          (should (equal (mapcar #'window-pixel-height (agent-ui--pane-cells (selected-frame))) heights))
          (should (equal (buffer-local-value 'agent-ui--pane-height session) wanted))
          ;; One view changed: it alone measured again.
          (agent-ui-show '(:id "y" :type "text" :text "6") :canvas tests)
          (agent-ui--pane-fit-now)
          (agent-ui--pane-sync)
          (should measured)
          (should (equal (delete-dups measured)
                         (list (get-buffer-window (agent-ui-test-aupn-canvas name "tests"))))))))))

(ert-deftest agent-ui-pane/laid-out-again-from-a-view-touches-no-other-buffer ()
  "A new view laid out while one is selected (its window made again, the
selected one deleted, another selected meanwhile): the new component drawn in
its own canvas, never in the session's buffer (it was: its start replaced
by the component); the view selected still, in its new window."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (let ((before (with-current-buffer session (buffer-string))))
      (select-window (get-buffer-window (agent-ui-test-aupn-canvas name)))
      (agent-ui-test-aupn-show (agent-ui-sub-canvas name "files"))
      (should (equal (with-current-buffer session (buffer-string)) before))
      (with-current-buffer (agent-ui-test-aupn-canvas name "files")
        (should (string-search "something" (buffer-string)))
        (should (eq (marker-buffer (agent-ui--entry-end (gethash "x" agent-ui--entries))) (current-buffer))))
      (should (eq (window-buffer (selected-window)) (agent-ui-test-aupn-canvas name)))
      (should (agent-ui-pane-window-p (selected-window))))))

(ert-deftest agent-ui-pane/a-hidden-view-back-when-shown-again ()
  "A view hidden (its window closed): an update of its component leaves it
hidden (a bar ticking would bring it back each second); the component shown
again, the same id: back."
  (agent-ui-test-aupn
    (let ((tests (agent-ui-sub-canvas name "tests")))
      (agent-ui-test-aupn-show name)
      (agent-ui-test-aupn-show tests)
      (delete-window (get-buffer-window (agent-ui-test-aupn-canvas name "tests")))
      (agent-ui--pane-sync)
      (should (= (length (agent-ui-test-aupn-cells)) 1))
      (agent-ui-update "x" '(:text "changed") :canvas tests)
      (agent-ui--pane-sync)
      (should (= (length (agent-ui-test-aupn-cells)) 1))
      (agent-ui-test-aupn-show tests)
      (should (= (length (agent-ui-test-aupn-cells)) 2))
      (should (get-buffer-window (agent-ui-test-aupn-canvas name "tests"))))))

(ert-deftest agent-ui-pane/wide-views-together ()
  "Two wide views (80) dealt into the columns allowed to be wide: four
columns fit across 205 with both in one (80 + 40 + 40 + 40), not with each
in its own (240); the ten-view experiment's ninth step: 22.1 lines high,
not 27.8 in three columns."
  (let* ((lines '(8.6 7.6 8.1 9.6 14.0 9.6 5.6 6.6 9.6))
         (widths '(40 80 40 80 40 40 40 40 40))
         (plan (agent-ui--pane-plan lines widths 205 33)))
    (should (= (length (car plan)) 4))
    (should (< (nth 2 plan) 23))
    (should (seq-find (lambda (column) (and (memq 1 column) (memq 3 column))) (car plan)))
    (should (= (apply #'+ (nth 1 plan)) 205)))
  ;; A wide session's own view: its column allowed to be wide.
  (should (equal (car (agent-ui--pane-plan '(4 4 4) '(80 40 40) 205 32)) '((0) (1) (2)))))

(ert-deftest agent-ui-pane/a-stack-with-room-for-all ()
  "Views in one column (the pane too narrow for two), the column with room
for them all: each its share, none too small (halving the last window each
time: 1/2, 1/4, 1/8... the last ones failed)."
  (agent-ui-test-aupn
    (let ((agent-ui-grid-min-width 80))
      ;; Four: as many as the 24 lines of a batch Emacs's frame have room
      ;; for (3 lines each); halving, the fourth failed already.
      (dolist (part '(nil "b" "c" "d"))
        (agent-ui-test-aupn-show (if part (agent-ui-sub-canvas name part) name)))
      (let ((cells (agent-ui--pane-cells (selected-frame))))
        (should (= (length cells) 4))
        (should (= (length (window-list nil 'nomini)) 5))
        (dolist (cell cells)
          (should (>= (window-total-height cell) 2)))))))

(ert-deftest agent-ui-pane/a-layout-failing-half-built-leaves-nothing ()
  "A layout failing half built (no room after all): what it made deleted,
the session's window as it was, no window of it left over (each try left
more: 18 windows of the session); its view in a pane of its own then."
  (agent-ui-test-aupn
    (let ((height (window-total-height))
          (calls 0))
      (cl-letf (((symbol-function 'agent-ui--pane-build)
                 (lambda (area _plan)
                   (cl-incf calls)
                   (split-window area nil 'right)
                   (error "Window too small for splitting"))))
        (agent-ui-test-aupn-show name)
        (agent-ui--pane-sync)
        (agent-ui--pane-sync))
      (should (>= calls 1))
      (should-not (agent-ui--pane-cells (selected-frame)))
      (should (= (length (get-buffer-window-list session 'nomini)) 1))
      ;; Its view in a pane of its own then, not one of Agent UI's.
      (should (get-buffer-window (agent-ui-test-aupn-canvas name)))
      (ignore height))))

(ert-deftest agent-ui-pane/the-best-layout-searched ()
  "Dealing and moving or swapping one view at a time can stop short of the
best layout (here 10.4 lines off: the two wide views had to go together,
three views moving at once); the search finds it."
  (let* ((lines '(6.5 13.0 10.7 11.7 8.4 9.8))
         (widths '(40 40 40 40 80 80))
         (plan (agent-ui--pane-plan lines widths 120 40)))
    (should (equal (car plan) '((0 1 2) (3 4 5))))
    (should (< (abs (- (nth 2 plan) 30.2)) 0.01)))
  ;; Better than a bound only; none: nil.
  (should-not (agent-ui--pane-search '(4 4) '(40 40) 80 32 '(4.0 0 2)))
  (should (equal (car (agent-ui--pane-search '(4 4) '(40 40) 80 32 nil)) '((0) (1))))
  ;; Its steps limited: the best found by then.
  (let ((agent-ui-pane-search-limit 3))
    (should-not (agent-ui--pane-search '(4 4 4 4) '(40 40 40 40) 205 32 nil))))

(ert-deftest agent-ui-pane/planned-again-once-settled ()
  "Laid out on a new view's size as drawn at the default width, the layout
planned again once the views are drawn at theirs (the fit after the
redraw): a better one made, once; not again until the views change."
  (agent-ui-test-aupn
    (let ((rebuilt 0))
      ;; Two views laid out badly: one above the other (a planner that knew
      ;; no better), side by side the best in 80 columns.
      (cl-letf (((symbol-function 'agent-ui--pane-plan)
                 (lambda (lines _widths width _most)
                   (list (list (number-sequence 0 (1- (length lines)))) (list width) (apply #'+ lines)))))
        (agent-ui-test-aupn-show name)
        (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests")))
      (pcase-let ((`(,a ,b) (agent-ui--pane-cells (selected-frame))))
        (should (= (window-left-column a) (window-left-column b))))
      (advice-add 'agent-ui--pane-attach :after (lambda (&rest _) (cl-incf rebuilt)) '((name . test-rebuilt)))
      (unwind-protect
          (progn
            (agent-ui--pane-settle (selected-window) session)
            (should (= rebuilt 1))
            (pcase-let ((`(,a ,b) (agent-ui--pane-cells (selected-frame))))
              (should (= (window-top-line a) (window-top-line b))))
            (should (buffer-local-value 'agent-ui--pane-settled session))
            ;; Once: not again.
            (agent-ui--pane-settle (selected-window) session)
            (should (= rebuilt 1)))
        (advice-remove 'agent-ui--pane-attach 'test-rebuilt)))))

(ert-deftest agent-ui-pane/scored-as-cut-at-its-most ()
  "Views needing more than the most Agent UI takes: its columns cut there,
each line they hide a line more. Three views of 21, 25 and 39 lines in 33
at most, 205 columns: three columns (6 lines hidden), not two of 46 and 39
(19 hidden) as when the cut was left out. Nothing cut: as before."
  (should (equal (agent-ui--pane-key '(46 39) 33) '(52.0 0 2)))
  (should (equal (agent-ui--pane-key '(21 25 39) 33) (list (+ 33 (/ 20.0 3) 6) 20 3)))
  ;; Nothing cut: the height and room left empty together, as before.
  (should (equal (agent-ui--pane-key '(10 6) 33) '(12.0 4 2)))
  (let ((plan (agent-ui--pane-plan '(20.76 25.24 39.12) '(40 80 40) 205 33)))
    (should (= (length (car plan)) 3))
    ;; Its height: the tallest column's, uncut (Agent UI cuts it).
    (should (= (nth 2 plan) 39.12)))
  ;; The search finds three too.
  (should (= (length (car (agent-ui--pane-search '(20.76 25.24 39.12) '(40 80 40) 205 33 nil))) 3)))

(ert-deftest agent-ui-pane/laid-out-again-when-its-pane-is-resized ()
  "Its pane resized another way than by tiling (a pane beside it closed or
split, the frame resized): its views planned again for its room once the
resizing stops, each change moving it; laid out again if their columns
don't fit or a layout is better (two views stacked in 40 columns, side by
side in 80, stacked again in 40). Not for a change of what they show, nor
the border between the conversation and them moved."
  (agent-ui-test-aupn
    (let* ((window (selected-window))
           (other (split-window window nil 'right))
           (side-by-side (lambda ()
                           (pcase-let ((`(,a ,b) (agent-ui--pane-cells (selected-frame))))
                             (= (window-top-line a) (window-top-line b)))))
           (replans (lambda ()
                      (seq-count (lambda (timer) (eq (timer--function timer) #'agent-ui--pane-replan-now))
                                 timer-list))))
      (unwind-protect
          (progn
            (agent-ui-test-aupn-show name)
            (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
            (agent-ui--pane-fit-now)
            (should (= (window-total-width window) 40))
            (should (= (length (agent-ui--pane-cells (selected-frame))) 2))
            (should-not (funcall side-by-side))
            ;; What they show changed, the border above them moved: no
            ;; plan again.
            (agent-ui-show '(:id "y" :type "text" :text "more") :canvas name)
            (agent-ui--pane-fit-now)
            (window-resize (window-next-sibling window) 1)
            (agent-ui--pane-sync)
            (should (= (funcall replans) 0))
            ;; The pane beside it closed (not by tiling): 80 columns. Planned
            ;; again once the resizing stops, not at once.
            (delete-window other)
            (agent-ui--pane-sync)
            (should (= (window-total-width window) 80))
            (should-not (funcall side-by-side))
            (should (= (funcall replans) 1))
            ;; Another change: the same plan, moved.
            (agent-ui--pane-resized window session)
            (should (= (funcall replans) 1))
            (agent-ui-test-timers-run 0.3)
            (should (= (funcall replans) 0))
            (should (= (length (agent-ui--pane-cells (selected-frame))) 2))
            (should (funcall side-by-side))
            (should (equal (buffer-local-value 'agent-ui--pane-planned-room session)
                           (agent-ui--pane-room window)))
            ;; Synced again, the room as planned: nothing more.
            (agent-ui--pane-sync)
            (should (= (funcall replans) 0))
            ;; Narrowed again (the pane split): side by side no longer fits.
            (split-window (window-parent window) nil 'right)
            (agent-ui--pane-sync)
            (should (= (window-total-width window) 40))
            (agent-ui-test-timers-run 0.3)
            (should (= (length (agent-ui--pane-cells (selected-frame))) 2))
            (should-not (funcall side-by-side)))
        (when (timerp agent-ui--pane-resize-timer)
          (cancel-timer agent-ui--pane-resize-timer))
        (setq agent-ui--pane-resize-timer nil
              agent-ui--pane-to-replan nil)))))

(ert-deftest agent-ui-pane/resized-from-a-view-keeps-it-selected ()
  "Laid out again for its pane's room while a view is selected: that view
selected again after, in its new window."
  (agent-ui-test-aupn
    (let* ((window (selected-window))
           (other (split-window window nil 'right)))
      (agent-ui-test-aupn-show name)
      (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
      (select-window (get-buffer-window (agent-ui-test-aupn-canvas name "tests")))
      (delete-window other)
      (agent-ui--pane-sync)
      (agent-ui--pane-replan-now)
      (pcase-let ((`(,a ,b) (agent-ui--pane-cells (selected-frame))))
        (should (= (window-top-line a) (window-top-line b))))
      (should (eq (window-buffer (selected-window)) (agent-ui-test-aupn-canvas name "tests")))
      (should (agent-ui-pane-window-p (selected-window))))))

(ert-deftest agent-ui-pane/settled-from-a-view-keeps-it-selected ()
  "Planned again once settled (the fit after a new view's redraw) while a
view is selected: that view selected again after, in its new window (it
was left to the window Emacs chose, a code buffer's often: keys typed
went there)."
  (agent-ui-test-aupn
    ;; Two views stacked (a planner that knew no better), side by side the
    ;; better.
    (cl-letf (((symbol-function 'agent-ui--pane-plan)
               (lambda (lines _widths width _most)
                 (list (list (number-sequence 0 (1- (length lines)))) (list width) (apply #'+ lines)))))
      (agent-ui-test-aupn-show name)
      (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests")))
    (let ((old (get-buffer-window (agent-ui-test-aupn-canvas name "tests"))))
      (select-window old)
      (should-not (buffer-local-value 'agent-ui--pane-settled session))
      (agent-ui--pane-fit-now)
      (should (buffer-local-value 'agent-ui--pane-settled session))
      (should-not (window-live-p old)))
    (pcase-let ((`(,a ,b) (agent-ui--pane-cells (selected-frame))))
      (should (= (window-top-line a) (window-top-line b))))
    (should (eq (window-buffer (selected-window)) (agent-ui-test-aupn-canvas name "tests")))
    (should (agent-ui-pane-window-p (selected-window)))))

(ert-deftest agent-ui-pane/a-form-filled-in-kept-when-laid-out-again ()
  "A form being filled in in a view's window (in place of its canvas): laid
out anew (a new view; or while another window is selected), the form shown
in its canvas's new window, where it was in it, selected if it was; sent or
cancelled, its canvas back in that window, selected."
  (agent-ui-test-aupn
    (let ((ask (agent-ui-sub-canvas name "ask")))
      (agent-ui-test-aupn-show name)
      (agent-ui-show '(:id "f" :type "form" :fields ((:name "title" :label "Title"))) :canvas ask)
      (agent-ui--pane-sync)
      (select-window (get-buffer-window (agent-ui-test-aupn-canvas name "ask")))
      (with-current-buffer (agent-ui-test-aupn-canvas name "ask")
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "Fill in")
        (goto-char (match-beginning 0))
        (agent-ui-button-press))
      (let ((form (get-buffer (agent-ui-form--buffer-name (agent-ui-test-aupn-canvas name "ask") "f"))))
        (should (eq (window-buffer (selected-window)) form))
        (set-window-point (selected-window) (with-current-buffer form (1- (point-max))))
        (let ((place (window-point (selected-window))))
          ;; A new view: laid out anew.
          (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
          (agent-ui--pane-sync)
          (should (= (length (agent-ui--pane-cells (selected-frame))) 3))
          (should (eq (window-buffer (selected-window)) form))
          (should (agent-ui-pane-window-p (selected-window)))
          (should (eq (agent-ui--pane-view (selected-window)) (agent-ui-test-aupn-canvas name "ask")))
          (should (= (window-point (selected-window)) place))
          ;; Laid out anew while the conversation is selected: the form in
          ;; its view's new window still, the conversation selected still.
          (let ((cell (selected-window)))
            (select-window (get-buffer-window session))
            (agent-ui--pane-detach (selected-frame) session)
            (agent-ui--pane-sync)
            (should-not (window-live-p cell))
            (should (eq (window-buffer (selected-window)) session))
            (should (agent-ui-pane-window-p (get-buffer-window form)))
            (select-window (get-buffer-window form)))
          (with-current-buffer form
            (agent-ui-form-cancel))
          (should-not (buffer-live-p form))
          (should (eq (window-buffer (selected-window)) (agent-ui-test-aupn-canvas name "ask")))
          (should (agent-ui-pane-window-p (selected-window)))
          (should (window-dedicated-p (selected-window)))
          (should (= (length (agent-ui--pane-cells (selected-frame))) 3)))))))

(defun agent-ui-test-aupn-wide-three (name)
  "Three views on NAME's session: its own, code (a diff: 80 columns at
least), metrics."
  (agent-ui-show '(:id "x" :type "text" :text "words") :canvas name)
  (agent-ui-show '(:id "d" :type "diff" :diff "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n")
                 :canvas (agent-ui-sub-canvas name "code"))
  (agent-ui-show '(:id "y" :type "text" :text "more words") :canvas (agent-ui-sub-canvas name "metrics")))

(defmacro agent-ui-test-aupn-counting (var &rest body)
  "BODY with VAR counting the windows split and deleted."
  (declare (indent 1))
  `(let* ((,var 0)
          (count (lambda (&rest _) (cl-incf ,var))))
     (advice-add 'split-window :before count '((name . test-counting)))
     (advice-add 'delete-window :before count '((name . test-counting)))
     (unwind-protect (progn ,@body)
       (advice-remove 'split-window 'test-counting)
       (advice-remove 'delete-window 'test-counting))))

(ert-deftest agent-ui-pane/views-left-out-for-want-of-room ()
  "A pane too narrow for a wide view (of three): the other two shown, it
left out; that layout in place, no window changed at each sync (each
rebuilt it: a window change, syncing again in the same redisplay, Emacs
frozen); the pane widened: all three, once the resizing stops.  Laid out
within the batch frame's 80 columns (Emacs 31's batch frame can't be
resized): views 26 columns at least, a wide one 53, so 40 is too narrow
for it and 80 holds all three."
  (let ((agent-ui-grid-min-width 26)
        (agent-ui-grid-wide-width 53))
    (agent-ui-test-aupn
      (should (>= (frame-width) 80))
      (let* ((window (selected-window))
             (other (split-window window 40 'right)))
        (agent-ui-test-aupn-wide-three name)
        (agent-ui--pane-sync)
        (should (= (window-total-width window) 40))
        (should (equal (agent-ui-test-aupn-cells)
                       (mapcar #'agent-ui-canvas-buffer-name
                               (list name (agent-ui-sub-canvas name "metrics")))))
        (agent-ui-test-aupn-counting changes
          (dotimes (_ 5)
            (agent-ui--pane-sync))
          (agent-ui--pane-fit-now)
          (should (= changes 0)))
        (should (buffer-local-value 'agent-ui--pane-wanted session))
        ;; Widened: all three, once the resizing stops.
        (delete-window other)
        (agent-ui--pane-sync)
        (should (= (window-total-width window) (frame-width)))
        (agent-ui--pane-replan-now)
        (should (= (length (agent-ui--pane-cells (selected-frame))) 3))
        ;; Narrowed again: code left out again, at once (its columns
        ;; don't fit).
        (split-window (window-parent window) 40 'right)
        (agent-ui--pane-sync)
        (agent-ui--pane-replan-now)
        (should (= (length (agent-ui--pane-cells (selected-frame))) 2))
        (agent-ui-test-aupn-counting changes
          (agent-ui--pane-sync)
          (should (= changes 0)))))))

(ert-deftest agent-ui-pane/a-rebuild-loop-stopped ()
  "A layout its sync never takes as in place (a bug): rebuilt at most
`agent-ui-pane-rebuild-limit' times a second, then left as it is, said once;
rebuilt again a second later."
  (agent-ui-test-aupn
    (let ((said nil))
      (agent-ui-test-aupn-show name)
      (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
      (cl-letf (((symbol-function 'agent-ui--pane-in-place-p) #'ignore)
                ((symbol-function 'message) (lambda (format &rest args) (push (apply #'format format args) said))))
        (with-current-buffer session
          (setq agent-ui--pane-rebuilds nil))
        (agent-ui-test-aupn-counting changes
          (dotimes (_ 50)
            (agent-ui--pane-sync))
          (let ((stopped changes))
            ;; Each rebuild: its windows deleted, made again.
            (should (> stopped 0))
            (dotimes (_ 10)
              (agent-ui--pane-sync))
            (should (= changes stopped))))
        (should (= (length (seq-filter (lambda (text) (string-search "laid out anew" text)) said)) 1))
        (should (= (length (buffer-local-value 'agent-ui--pane-rebuilds session)) agent-ui-pane-rebuild-limit))
        ;; Its views still shown, as left.
        (should (= (length (agent-ui--pane-cells (selected-frame))) 2))
        ;; A second later: rebuilt again.
        (with-current-buffer session
          (setq agent-ui--pane-rebuilds (mapcar (lambda (time) (- time 1.5)) agent-ui--pane-rebuilds)))
        (agent-ui-test-aupn-counting changes
          (agent-ui--pane-sync)
          (should (> changes 0)))))))

;; doom-ht6.154
(ert-deftest agent-ui-pane/a-views-bar-says-its-title ()
  "A view's bar says the title the agent gave its canvas: the session's
own (it said Canvas) and another (it said its name); taken back, as before."
  (agent-ui-test-aupn
    (agent-ui-test-aupn-show name)
    (agent-ui-test-aupn-show name "y")
    (agent-ui-test-aupn-show (agent-ui-sub-canvas name "tests"))
    (pcase-let ((`(,a ,b) (agent-ui--pane-cells (selected-frame))))
      (should (equal (agent-ui-test-aupn-bar a) " Canvas"))
      (should (equal (agent-ui-test-aupn-bar b) " tests"))
      (agent-ui-set-title "Demo" :canvas name)
      (agent-ui-set-title "Suite 100%" :canvas (agent-ui-sub-canvas name "tests"))
      (should (equal (agent-ui-test-aupn-bar a) " Demo"))
      ;; A % in it, shown as it is.
      (should (equal (agent-ui-test-aupn-bar b) " Suite 100%%"))
      (agent-ui-set-title nil :canvas name)
      (should (equal (agent-ui-test-aupn-bar a) " Canvas")))))

;;; agent-ui-pane-tests.el ends here
