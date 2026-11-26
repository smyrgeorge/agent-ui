;;; agent-ui-progress-tests.el --- Tests for Agent UI: the progress component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-progress.el: the progress component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/progress-as-a-pie ()
  "Pie: drawn small, one line: a pie (a spinner running without a max), its
counts, its mark, its label; in the GUI the pie an SVG."
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 7 :max 12 :label "linking" :pie t))
                 "◑ 7/12  58%  linking"))
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 12 :max 12 :status "done" :pie t))
                 "● 12/12  100%  ✓"))
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 3 :label "indexing" :pie t) :tick 0)
                 "● 3  indexing"))
  ;; A label too long for its line: under its counts, wrapped (it was cut:
  ;; "◑ 7/12  58%  a long…"); nothing beside the pie but it: from there.
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 7 :max 12 :label "a long label for a narrow pane" :pie t)
                                 :width 20)
                 "◑ 7/12  58%\n  a long label for a\n  narrow pane"))
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :label "indexing the whole project's files" :pie t) :width 20)
                 "● indexing the whole\n  project's files"))
  (let ((text (agent-ui-render '(:type "progress" :value 7 :max 12 :pie t)
                               (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16))))
    (should (string-match-p "<path" (plist-get (cdr (get-text-property 0 'display text)) :data)))))

(ert-deftest agent-ui-components/progress ()
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 7 :max 12 :label "linking"))
                 "████████████████▎░░░░░░░░░░░  7/12  58%  linking"))
  ;; No label: the bar takes the room.
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 1 :max 4))
                 (concat (make-string 10 ?█) (make-string 30 ?░) "  1/4  25%")))
  ;; Over its max: full.
  (should (string-prefix-p (make-string 40 ?█) (agent-ui-test-aue-draw '(:type "progress" :value 9 :max 4))))
  (should (string-suffix-p "  9/4  100%" (agent-ui-test-aue-draw '(:type "progress" :value 9 :max 4))))
  ;; Floats, a unit.
  (should (string-match-p "  1.5/3 MB  50%\\'"
                          (agent-ui-test-aue-draw '(:type "progress" :value 1.5 :max 3 :unit "MB"))))
  ;; A label too long for the line: under the bar, wrapped (a word wider
  ;; than the width within it), never cut.
  (let ((lines (split-string (agent-ui-test-aue-draw (list :type "progress" :value 1 :max 2 :label (make-string 100 ?x))) "\n")))
    (should (equal (cdr lines) (list (make-string 60 ?x) (make-string 40 ?x))))
    (should (string-suffix-p "  1/2  50%" (car lines)))))

(ert-deftest agent-ui-components/progress-a-long-label-read-whole ()
  "A label too long for its share of the line: the bar narrowed for it (down
to 10 cells); longer still, or of several lines, on lines of its own under
the bar, wrapped, the bar as without a label, its mark kept on its line
(the label was cut with …, the bar keeping its 40 cells: \"... agent
sessions …\" at 98 columns, its rest nowhere; doom-qh6)."
  (let ((label "doom-38o.2: the pool, agent sessions with no role or name, in agent-shell"))
    ;; At 98 columns: the bar of 40 and its counts, the label whole under it.
    (should (equal (agent-ui-test-aue-draw (list :type "progress" :value 1 :max 18 :unit "tickets" :label label) :width 98)
                   (concat "██▏" (make-string 37 ?░) "  1/18 tickets  5%\n" label)))
    ;; Wide enough: on the line, after the bar.
    (should (equal (agent-ui-test-aue-draw (list :type "progress" :value 1 :max 18 :unit "tickets" :label label) :width 160)
                   (concat "██▏" (make-string 37 ?░) "  1/18 tickets  5%  " label)))
    ;; Narrow: wrapped under it, every word, every line within the width.
    (dolist (width '(10 20 30 40 60))
      (let* ((text (agent-ui-test-aue-draw (list :type "progress" :value 1 :max 18 :unit "tickets" :label label) :width width))
             (under (cdr (split-string text "\n"))))
        (should-not (string-search "…" (string-join under)))
        (when (>= width 20)
          (should (equal (split-string label) (split-string (string-join under " ")))))
        (dolist (line (split-string text "\n")) (should (<= (string-width line) width))))))
  ;; A little too long for its share: the bar gives way, the label beside it.
  (let* ((label (concat "doom-38o.2: the pool, " (make-string 38 ?x)))
         (text (agent-ui-test-aue-draw (list :type "progress" :value 1 :max 18 :unit "tickets" :label label) :width 98)))
    (should-not (string-search "\n" text))
    (should (string-suffix-p (concat "  1/18 tickets  5%  " label) text))
    (should (= (string-width text) 98))
    (should (= (length (car (split-string text " "))) 18)))
  ;; Done: its ✓ on the bar's line, its label under it.
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 12 :max 12 :status "done"
                                   :label "built every target of the project in 41 seconds") :width 40)
                 (concat (make-string 24 ?█) "  12/12  100%  ✓\nbuilt every target of the project in 41\nseconds")))
  ;; Of several lines: under the bar, as they are.
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 1 :max 2 :label "linking\nthe final binary"))
                 (concat (make-string 20 ?█) (make-string 20 ?░) "  1/2  50%\nlinking\nthe final binary")))
  ;; Too narrow for a label beside the bar: under it (it was left out).
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :value 7 :max 12 :label "linking") :width 15)
                 "█▊░  7/12  58%\nlinking"))
  ;; In the GUI: the same text, the label's lines under the SVG bar.
  (let* ((component '(:type "progress" :value 1 :max 4 :label "linking the final binary of the whole project, every target"))
         (gui (agent-ui-render component (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16))))
    (should (equal (substring-no-properties gui) (agent-ui-test-aue-draw component)))
    (should (string-match-p "\nlinking the final" (substring-no-properties gui)))))

(ert-deftest agent-ui-components/progress-states ()
  (let ((done '(:type "progress" :value 12 :max 12 :status "done" :label "built"))
        (failed '(:type "progress" :value 3 :max 12 :status "failed" :label "cc: error")))
    (should (string-suffix-p "12/12  100%  ✓ built" (agent-ui-test-aue-draw done)))
    (should (eq (agent-ui-test-aue-face-at done "█") 'agent-ui-success))
    (should (string-suffix-p "3/12  25%  ✗ cc: error" (agent-ui-test-aue-draw failed)))
    (should (eq (agent-ui-test-aue-face-at failed "█") 'agent-ui-error))
    (should (eq (agent-ui-test-aue-face-at failed "░") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at '(:type "progress" :value 1 :max 2) "█") 'agent-ui-accent))
    ;; Only one without a max, running, is animated.
    (should-not (agent-ui-animated-p done))
    (should-not (agent-ui-animated-p '(:type "progress" :max 2)))
    (should (agent-ui-animated-p '(:type "progress")))
    (should-not (agent-ui-animated-p '(:type "progress" :status "done")))))

(ert-deftest agent-ui-components/progress-without-an-end ()
  (cl-flet ((at (tick) (string-search "█" (agent-ui-test-aue-draw '(:type "progress" :label "waiting")
                                                           :tick tick))))
    ;; The block moves with the ticks, then back.
    (should (= (at 0) 0))
    (should (= (at 3) 3))
    (should (> (at 20) (at 3)))
    (should (= (at (* 2 (- 33 4))) 0)))
  (should (string-match-p "  37 files  waiting\\'"
                          (agent-ui-test-aue-draw '(:type "progress" :value 37 :unit "files" :label "waiting"))))
  ;; Done: full, no counts.
  (should (equal (agent-ui-test-aue-draw '(:type "progress" :status "done"))
                 (concat (make-string 40 ?█) "  ✓"))))

(ert-deftest agent-ui-components/progress-wrong ()
  (should (equal (agent-ui-test-aue-error '(:type "progress" :max 0))
                 "progress: max must be above 0, not 0"))
  (should (equal (agent-ui-test-aue-error '(:type "progress" :status "paused"))
                 "progress: status must be one of: running, done, failed, not \"paused\"")))

(ert-deftest agent-ui-components/a-progress-bar-rounded-in-the-gui ()
  "In the GUI a progress bar is an SVG over its cells: a rounded track and a
rounded fill (its colour by status), what follows it where it was; without
a max, its moving block rounded; in a terminal, as before (doom-ht6.37)."
  (let* ((component '(:type "progress" :value 1 :max 4 :label "linking"))
         (ctx (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16))
         (gui (agent-ui-render component ctx))
         (text (agent-ui-render component (agent-ui-context :width 60))))
    ;; The same columns, the same words after the bar.
    (should (equal (substring-no-properties gui) (substring-no-properties text)))
    (should (string-match-p "\\`█+░+  1/4  25%  linking\\'" (substring-no-properties text)))
    (let* ((dom (agent-ui-test-aue-svg-dom component 60))
           (rects (agent-ui-test-aue-rects dom))
           (svg-width (string-to-number (dom-attr dom 'width))))
      (should (= (length rects) 2))
      (dolist (rect rects) (should (equal (plist-get rect :rx) 2)))
      ;; Its track the bar's cells' width; its fill a quarter of it.
      (should (= (plist-get (car rects) :width) svg-width))
      (should (= svg-width (* 8 (length (car (split-string (substring-no-properties text) " "))))))
      (should (< (abs (- (plist-get (cadr rects) :width) (/ svg-width 4.0))) 0.01))
      (should (equal (plist-get (cadr rects) :fill) (agent-ui-color 'agent-ui-accent)))))
  ;; Done, failed: their colours; at 0, nothing filled.
  (pcase-dolist (`(,status . ,face) '((done . agent-ui-success) (failed . agent-ui-error)))
    (let ((rects (agent-ui-test-aue-rects (agent-ui-test-aue-svg-dom (list :type "progress" :value 4 :max 4 :status (symbol-name status)) 60))))
      (should (equal (plist-get (cadr rects) :fill) (agent-ui-color face)))))
  (should (= 1 (length (agent-ui-test-aue-rects (agent-ui-test-aue-svg-dom '(:type "progress" :value 0 :max 4) 60)))))
  ;; Without a max: the block, rounded, where its text has it.
  (let* ((rects (agent-ui-test-aue-rects (agent-ui-test-aue-svg-dom '(:type "progress" :label "waiting") 60)))
         (block (cadr rects)))
    (should (= (length rects) 2))
    (should (equal (plist-get block :rx) 2))
    (should (= (plist-get block :width) (* 8 4)))))

;; A bar on a canvas, updated as the clock goes (its times noted with it).
(defconst agent-ui-test-aue-t0 1794335400.0 "The clock's start: 2026-11-10T18:30:00Z.")

(defvar agent-ui-test-aue-now nil "The clock now (`agent-ui-clock'), in the bars' tests.")

(defmacro agent-ui-test-aue-clocked (&rest body)
  "BODY on a canvas of its own (`agent-ui-test-aue-canvas'), the clock faked:
`agent-ui-test-aue-bar' moves it."
  (declare (indent 0))
  `(let* ((agent-ui-test-aue-now agent-ui-test-aue-t0)
          (agent-ui-clock (lambda () agent-ui-test-aue-now)))
     (agent-ui-test-aue-canvas ,@body)))

(defun agent-ui-test-aue-bar-draw (id &optional width)
  "Bar ID as the canvas draws it, WIDTH wide (100), its text only."
  (substring-no-properties
   (agent-ui-render (agent-ui-get id) (agent-ui-context :width (or width 100) :id id))))

(defun agent-ui-test-aue-bar (time id patch &optional width)
  "At TIME (seconds from `agent-ui-test-aue-t0'), bar ID changed by PATCH (shown,
a progress, if it isn't there), then drawn WIDTH wide (100)."
  (setq agent-ui-test-aue-now (+ agent-ui-test-aue-t0 time))
  (if (ignore-errors (agent-ui-get id))
      (agent-ui-update id patch)
    (agent-ui-show (append (list :id id :type "progress") patch)))
  (agent-ui-test-aue-bar-draw id width))

(ert-deftest agent-ui-components/progress-fits-its-width ()
  "However narrow: a bar of 3 cells at least, its figures left out from the
end (time left, rate, percentage) and its counts cut last, every line within
the width (the bar was 10 at least and nothing was cut: 44 columns at 40)."
  (agent-ui-test-aue-clocked
    (cl-flet ((at (time value width)
                (agent-ui-test-aue-bar time "dl" (list :value value :max 100 :unit "MB"
                                               :label "downloading dependencies")
                               width)))
      (at 100.0 10 40) (at 101.0 14 40)
      (dolist (width '(10 20 30 40))
        (dolist (line (split-string (at 102.0 18 width) "\n"))
          (should (<= (string-width line) width))))
      ;; Wide: all of it.
      (should (string-match-p "18/100 MB  18%  4 MB/s  [0-9]+s left" (at 102.0 18 100)))))
  (dolist (component '((:type "progress" :value 7 :max 12 :label "linking the final binary")
                     (:type "progress" :value 123456 :max 1000000 :unit "files" :label "indexing")))
    (dolist (width '(10 15 20 30))
      (dolist (line (split-string (agent-ui-test-aue-draw component :width width) "\n"))
        (should (<= (string-width line) width))))))

(ert-deftest agent-ui-components/progress-done-shows-its-mark ()
  "A done or failed bar without a label keeps its ✓ or ✗ at any width (under
~58 columns it was left out: done and failed alike in a terminal)."
  (dolist (width '(20 30 40 50 56 80))
    (should (string-match-p "✓" (agent-ui-test-aue-draw '(:type "progress" :value 12 :max 12 :status "done") :width width)))
    (should (string-match-p "✗" (agent-ui-test-aue-draw '(:type "progress" :value 3 :max 12 :status "failed") :width width)))
    (should (string-match-p "✓" (agent-ui-test-aue-draw '(:type "progress" :status "done") :width width)))
    (should (<= (string-width (agent-ui-test-aue-draw '(:type "progress" :value 12 :max 12 :status "done") :width width)) width))))

(ert-deftest agent-ui-components/progress-stalled ()
  "A bar not moving: past its foreseen end, no time left; past the window, no
rate either (it kept 4 MB/s and \"1s left\" forever)."
  (agent-ui-test-aue-clocked
    (cl-flet ((at (time value) (agent-ui-test-aue-bar time "dl" (list :value value :max 100 :unit "MB"))))
      (at 100.0 10) (at 101.0 14)
      (should (string-match-p "4 MB/s  20s left" (at 102.0 18)))
      ;; 25 s on, still 18: past the 20 s it foresaw, under the window.
      (let ((text (at 127.0 18)))
        (should (string-match-p "4 MB/s" text))
        (should-not (string-match-p "left" text)))
      ;; 98 s on: stalled.
      (should-not (string-match-p "/s\\|left" (at 200.0 18)))
      (should-not (string-match-p "/s\\|left" (at 1000.0 18)))))
  ;; Animated while its rate is said, and a moment after, so the canvas
  ;; draws it once more without (it kept them, nothing else drawing it:
  ;; doom-ht6.52).
  (agent-ui-test-aue-clocked
    (cl-flet ((at (time value) (agent-ui-test-aue-bar time "dl" (list :value value :max 100 :unit "MB"))))
      (at 100.0 10) (at 101.0 14) (at 102.0 18)
      (should (agent-ui-animated-p (agent-ui-get "dl")))
      (setq agent-ui-test-aue-now (+ agent-ui-test-aue-t0 132.5))
      (should (agent-ui-animated-p (agent-ui-get "dl")))
      (should-not (string-match-p "/s\\|left" (agent-ui-test-aue-bar-draw "dl")))
      (setq agent-ui-test-aue-now (+ agent-ui-test-aue-t0 140.0))
      (should-not (agent-ui-animated-p (agent-ui-get "dl"))))))

(ert-deftest agent-ui-components/progress-its-rate-and-time-left ()
  "Values seconds apart (a download): its rate and time left on its line,
as its values go; no second line."
  (agent-ui-test-aue-clocked
    (cl-flet ((at (time value &optional props)
                (agent-ui-test-aue-bar time "dl" (append (list :value value :max 100 :unit "MB") props))))
      ;; Not steady yet: two values, then three over under 2 seconds.
      (should-not (string-match-p "/s" (at 100.0 10)))
      (should-not (string-match-p "/s" (at 101.0 14)))
      ;; Steady: 3 values over 2 seconds, 4 MB a second; 82 MB left: 20s.
      (should (string-match-p "18/100 MB  18%  4 MB/s  20s left" (at 102.0 18)))
      ;; Drawn again, nothing new: the time left counts down.
      (should (string-match-p "4 MB/s  18s left" (at 104.5 18)))
      ;; Slower: 13 MB over 5 seconds, under 10 to a decimal.
      (let ((text (at 105.0 23)))
        (should (string-match-p "2.6 MB/s" text))
        (should-not (string-search "\n" text)))
      ;; Done, or failed: neither.
      (should-not (string-match-p "/s" (at 106.0 30 '(:status "done"))))
      ;; A lower value: starts again.
      (should-not (string-match-p "/s" (at 107.0 1 '(:status "running"))))
      ;; Without a max: the rate, no time left; slow ones a minute.
      (cl-flet ((open (time value) (agent-ui-test-aue-bar time "n" (list :value value) 80)))
        ;; 2 more in 30 seconds (the window's): 4 a minute.
        (open 200.0 1) (open 215.0 2)
        (let ((text (open 230.0 3)))
          (should (string-match-p "  3  4/min" text))
          (should-not (string-match-p "left" text))))
      ;; Updates many times a second (a command's output): noted a second
      ;; apart, the rate the same.
      (dotimes (i 50)
        (at (+ 300.0 (* i 0.1)) (* 2 i) '(:status "running")))
      (should (string-match-p "  98/100 MB  98%  20 MB/s" (agent-ui-test-aue-bar-draw "dl")))
      (should (<= (length (plist-get (plist-get (agent-ui-get "dl") :times) :values)) 12))))
  ;; Not on a canvas (render, a snapshot): neither.
  (should-not (string-match-p "/s" (agent-ui-test-aue-draw '(:type "progress" :value 5 :max 10)))))

;; doom-ht6.31
(ert-deftest agent-ui-components/progress-work-items ()
  "Values minutes apart (bugs fixed one by one): no rate on its line (its
window never had more than one value), a second line: the time elapsed,
an item takes (the median of the latest 8) and left, and when it should
end; ticking."
  (agent-ui-test-aue-clocked
    (agent-ui-test-aue-bar 0 "bugs" '(:value 0 :max 58 :unit "bugs" :label "fixing"))
    ;; One value: no second line yet.
    (should-not (string-search "\n" (agent-ui-test-aue-bar-draw "bugs")))
    (let ((time 0))
      (cl-loop for gap in '(8 10 9 11 8 9 10 9 12 8 9 10) for value from 1
               do (cl-incf time (* gap 60)) (agent-ui-test-aue-bar time "bugs" (list :value value))))
    ;; 3 minutes after the 12th: the last 8 took 8 to 12 minutes, 9 their
    ;; median; 46 left, the one going on begun 3 minutes ago: 411 minutes.
    (pcase-let ((`(,line ,timing) (split-string (agent-ui-test-aue-bar (* 116 60) "bugs" '(:label "tiling: SPC w SPC"))
                                                "\n")))
      (should (string-suffix-p "  12/58 bugs  20%  tiling: SPC w SPC" line))
      (should (equal timing (concat "1h 56m elapsed · ~9 min a bug (last 8) · ~6h 50m left, about "
                                    (format-time-string "%H:%M" (+ agent-ui-test-aue-now (* 411 60)))))))
    ;; Ticking: elapsed and left as the clock goes.
    (should (agent-ui-animated-p (agent-ui-get "bugs")))
    (should (string-search "1h 57m elapsed" (agent-ui-test-aue-bar (* 117 60) "bugs" nil)))
    ;; In the GUI too, under the bar.
    (should (string-search "\n1h 57m elapsed · ~9 min a bug"
                           (substring-no-properties
                            (agent-ui-render (agent-ui-get "bugs")
                                             (agent-ui-context :width 100 :id "bugs" :graphic t
                                                               :char-width 8 :line-height 16)))))
    ;; Without a max: the time an item takes, no time left.
    (agent-ui-test-aue-bar 0 "open" '(:value 0 :unit "issues"))
    (agent-ui-test-aue-bar 600 "open" '(:value 1))
    (should (string-suffix-p "\n10m 00s elapsed · ~10 min an issue" (agent-ui-test-aue-bar 600 "open" '(:value 1))))
    ;; Without a unit: each.
    (agent-ui-test-aue-bar 0 "x" '(:value 0 :max 4))
    (should (string-search "~5 min each · ~15 min left" (agent-ui-test-aue-bar 300 "x" '(:value 1))))))

(ert-deftest agent-ui-components/progress-work-items-pauses-and-several ()
  "A gap over the pause limit (a night) left out of the time an item takes;
a rise of several, several items, the gap shared."
  (agent-ui-test-aue-clocked
    (agent-ui-test-aue-bar 0 "fixes" '(:value 0 :max 20 :unit "fixes"))
    (agent-ui-test-aue-bar (* 10 60) "fixes" '(:value 1))
    (agent-ui-test-aue-bar (* 22 60) "fixes" '(:value 2))
    ;; The night: 10 hours.
    (agent-ui-test-aue-bar (* 622 60) "fixes" '(:value 3))
    ;; Two at once, 20 minutes on: 10 each.
    (let ((timing (cadr (split-string (agent-ui-test-aue-bar (* 642 60) "fixes" '(:value 5)) "\n"))))
      ;; 10, 10, 12, 10: 10 their median; 15 left.
      (should (string-prefix-p "10h 42m elapsed · ~10 min a fix (last 4) · ~2h 30m left, about " timing)))
    ;; Only pauses so far: no time an item takes.
    (agent-ui-test-aue-bar 0 "slow" '(:value 0 :max 3))
    (should (equal (cadr (split-string (agent-ui-test-aue-bar (* 50 60) "slow" '(:value 1)) "\n"))
                   "50m 00s elapsed"))))

(ert-deftest agent-ui-components/progress-work-items-a-range ()
  "The time left: one time while the items take about as long, a range
when they vary a lot (a quarter's to three quarters'), the end's clock time
too."
  (agent-ui-test-aue-clocked
    (agent-ui-test-aue-bar 0 "t" '(:value 0 :max 30 :unit "tickets"))
    (let ((time 0))
      (cl-loop for gap in '(4 25 6 30 5 28 7 22) for value from 1
               do (cl-incf time (* gap 60)) (agent-ui-test-aue-bar time "t" (list :value value)))
      ;; 4 to 30 minutes, 14.5 their median: 22 left, at 5.75 to 25.75
      ;; minutes an item, 126.5 to 566.5 minutes.
      (should (equal (cadr (split-string (agent-ui-test-aue-bar-draw "t") "\n"))
                     (format "2h 07m elapsed · ~14 min a ticket (last 8) · 2–9h left, about %s–%s"
                             (format-time-string "%H:%M" (+ agent-ui-test-aue-now (* 126.5 60)))
                             (format-time-string "%H:%M" (+ agent-ui-test-aue-now (* 566.5 60)))))))
    ;; Under an hour: minutes.
    (agent-ui-test-aue-bar 0 "m" '(:value 0 :max 6))
    (let ((time 0))
      (cl-loop for gap in '(1 5 1 5) for value from 1
               do (cl-incf time (* gap 60)) (agent-ui-test-aue-bar time "m" (list :value value))))
    (should (string-search "· 2–10 min left, about " (agent-ui-test-aue-bar-draw "m")))))

(ert-deftest agent-ui-components/progress-started ()
  "STARTED given (a timestamp, epoch seconds, or seconds ago), the work
begun before the bar: the time elapsed counts from it, from its first value;
kept as epoch seconds; a wrong one said."
  (agent-ui-test-aue-clocked
    (should (equal (cadr (split-string (agent-ui-test-aue-bar 0 "b" '(:max 10 :started 5400)) "\n"))
                   "1h 30m elapsed"))
    (should (equal (plist-get (agent-ui-get "b") :started) (- agent-ui-test-aue-t0 5400)))
    (should (agent-ui-animated-p (agent-ui-get "b")))
    (should (string-suffix-p "\n1h 40m elapsed" (agent-ui-test-aue-bar 600 "b" nil)))
    ;; A timestamp: half an hour before the clock's start.
    (should (string-suffix-p "\n30m 00s elapsed" (agent-ui-test-aue-bar 0 "c" '(:max 10 :started "2026-11-10T18:00:00Z")))))
  (should (string-match-p "progress: started is a timestamp"
                          (agent-ui-test-aue-error '(:type "progress" :started "yesterday")))))

(ert-deftest agent-ui-components/progress-work-items-stopped ()
  "Done or failed: the time it took only, no time left; no longer ticking."
  (agent-ui-test-aue-clocked
    (dolist (status '("done" "failed"))
      (let ((id (concat "w-" status)))
        (agent-ui-test-aue-bar 0 id '(:value 0 :max 10 :unit "bugs"))
        (agent-ui-test-aue-bar 600 id '(:value 1))
        (agent-ui-test-aue-bar 1200 id '(:value 2))
        (should (string-match-p "\n20m 00s elapsed · .* left" (agent-ui-test-aue-bar-draw id)))
        (should (equal (cadr (split-string (agent-ui-test-aue-bar 1500 id (list :status status)) "\n"))
                       "25m 00s elapsed"))
        (should-not (agent-ui-animated-p (agent-ui-get id)))
        ;; An hour on: the same.
        (should (equal (cadr (split-string (agent-ui-test-aue-bar 5100 id nil) "\n")) "25m 00s elapsed"))))
    ;; At its max: stopped too.
    (agent-ui-test-aue-bar 0 "m" '(:value 0 :max 2))
    (agent-ui-test-aue-bar 600 "m" '(:value 1))
    (agent-ui-test-aue-bar 1200 "m" '(:value 2))
    (should (equal (cadr (split-string (agent-ui-test-aue-bar 4800 "m" nil) "\n")) "20m 00s elapsed"))))

(ert-deftest agent-ui-components/progress-work-items-narrow ()
  "Narrow panes: the timing line's figures dropped from the right, the
first cut, nothing past the width; the label under the bar where it doesn't
fit beside it (it was cut); a pie's time elapsed and left after its counts
as room allows, its label whole, beside them or under them."
  (agent-ui-test-aue-clocked
    (agent-ui-test-aue-bar 0 "bugs" '(:value 0 :max 58 :unit "bugs" :label "tiling: SPC w SPC"))
    (cl-loop for value from 1 to 12
             do (agent-ui-test-aue-bar (* value 9 60) "bugs" (list :value value)))
    (agent-ui-test-aue-bar (* 111 60) "bugs" nil)
    (dolist (width '(8 12 20 30 40 50 60 70 80 100 120))
      (dolist (line (split-string (agent-ui-test-aue-bar-draw "bugs" width) "\n"))
        (should (<= (string-width line) width))))
    ;; At 40: the label under the bar, the timing line under it.
    (should (equal (cadr (split-string (agent-ui-test-aue-bar-draw "bugs" 40) "\n")) "tiling: SPC w SPC"))
    (cl-flet ((timing (width) (car (last (split-string (agent-ui-test-aue-bar-draw "bugs" width) "\n")))))
      (should (string-prefix-p "1h 51m elapsed · ~9 min a bug (last 8) · ~6h 50m left, about " (timing 100)))
      ;; Too wide: the items it's taken from left out first.
      (should (string-prefix-p "1h 51m elapsed · ~9 min a bug · ~6h 50m left, about " (timing 60)))
      (should (equal (timing 50) "1h 51m elapsed · ~9 min a bug · ~6h 50m left"))
      (should (equal (timing 40) "1h 51m elapsed · ~9 min a bug"))
      (should (equal (timing 20) "1h 51m elapsed"))
      (should (equal (timing 10) "1h 51m el…")))
    ;; A pie: its figures giving way to its label, beside them while it
    ;; fits whole there (it was cut: "tiling: SPC w …"), else under them.
    (cl-flet ((pie (width) (substring-no-properties
                            (agent-ui-render (append (agent-ui-get "bugs") '(:pie t))
                                             (agent-ui-context :width width :id "bugs")))))
      (should (equal (pie 80) "◔ 12/58 bugs  20%  1h 51m elapsed  ~6h 50m left  tiling: SPC w SPC"))
      (should (equal (pie 50) "◔ 12/58 bugs  20%  tiling: SPC w SPC"))
      (should (equal (pie 30) "◔ 12/58 bugs  20%\n  tiling: SPC w SPC"))
      (dolist (width '(10 20 40 60))
        (should (equal (last (split-string (pie width) "[ \n]+" t) 4) '("tiling:" "SPC" "w" "SPC")))
        (dolist (line (split-string (pie width) "\n"))
          (should (<= (string-width line) width)))))))

;;; agent-ui-progress-tests.el ends here
