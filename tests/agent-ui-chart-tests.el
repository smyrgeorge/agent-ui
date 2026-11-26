;;; agent-ui-chart-tests.el --- Tests for Agent UI: the chart component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-chart.el: the chart component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/chart-equal-huge-values ()
  "Equal huge values (1e17): a flat line, one bin (the range's widening was
lost in float precision: a span of 0, \"Arithmetic overflow error\")."
  (dolist (kind '("line" "sparkline" "histogram" "bar"))
    (let ((component (list :type "chart" :kind kind :values '(1e17 1e17))))
      (should-not (string-search "⚠" (agent-ui-test-aue-draw component :width 30)))
      (unless (equal kind "sparkline")
        (should (agent-ui-test-aue-svg component 30)))))
  (should (> (agent-ui-chart--above 1e17) 1e17))
  (should (= (agent-ui-chart--above 5) 6)))

(ert-deftest agent-ui-components/chart-a-time-for-each-value ()
  "Times and values counted the same, else refused, saying so (fewer times
broke the drawing, more squeezed the line); an append of values without
their times too."
  (should (string-match-p "3 values but 2 times"
                          (agent-ui-test-aue-error '(:type "chart" :values (1 2 3) :times (0 600)))))
  (should (string-match-p "3 values but 6 times"
                          (agent-ui-test-aue-error '(:type "chart" :values (1 2 3) :times (0 600 1200 1800 2400 3000)))))
  (let ((component '(:type "chart" :times ("2026-11-10T09:00:00" "2026-11-10T12:00:00") :values (120 340))))
    (should (string-match-p "3 values but 2 times"
                            (agent-ui-error-message
                             (should-error (agent-ui--checked (agent-ui-append-to component '(:values (410))))
                                           :type 'agent-ui-error))))
    ;; Together: fine.
    (should (agent-ui--checked (agent-ui-append-to component '(:values (410) :times ("2026-11-10T13:00:00")))))))

(ert-deftest agent-ui-components/chart-times-in-any-order ()
  "Times newest first (git log's order) or unsorted: the same line as in
order (the text's plot drew nothing for them)."
  (let ((sorted '(:type "chart" :height 3 :values (10 20 30)
                  :times ("2026-11-10T10:00:00" "2026-11-10T11:00:00" "2026-11-10T12:00:00")))
        (newest-first '(:type "chart" :height 3 :values (30 20 10)
                        :times ("2026-11-10T12:00:00" "2026-11-10T11:00:00" "2026-11-10T10:00:00")))
        (unsorted '(:type "chart" :height 3 :values (20 10 30)
                    :times ("2026-11-10T11:00:00" "2026-11-10T10:00:00" "2026-11-10T12:00:00"))))
    (should (string-match-p "[⠀-⣿]" (agent-ui-test-aue-draw newest-first :width 40)))
    (should (equal (agent-ui-test-aue-draw newest-first :width 40) (agent-ui-test-aue-draw sorted :width 40)))
    (should (equal (agent-ui-test-aue-draw unsorted :width 40) (agent-ui-test-aue-draw sorted :width 40)))
    (should (equal (agent-ui-test-aue-svg newest-first 40) (agent-ui-test-aue-svg sorted 40)))))

(ert-deftest agent-ui-components/chart-first-and-last-labels-fit ()
  "A line chart's first and last labels each cut to half the plot (in the
GUI they were drawn over each other; in text the last ran past the width)."
  (let ((component '(:type "chart" :height 3 :labels ("2026-11-01 build" "x" "2026-11-10 nightly build") :values (1 3 2))))
    (dolist (width '(20 30 40))
      (dolist (line (split-string (agent-ui-test-aue-draw component :width width) "\n"))
        (should (<= (string-width line) width))))
    (let ((svg (agent-ui-test-aue-svg component 30)))
      (should-not (string-match-p ">2026-11-10 nightly build<" svg))
      (should-not (string-match-p ">2026-11-01 build<" svg)))
    ;; Wide: whole.
    (let ((svg (agent-ui-test-aue-svg component 100)))
      (should (string-match-p ">2026-11-10 nightly build<" svg)))))

(ert-deftest agent-ui-components/chart-legend-wraps ()
  "A legend wider than the chart: on more lines (rows in the GUI), its items
whole (one line ran past the width, and the SVG's right edge)."
  (let ((bars '(:type "chart" :kind "bar" :labels ("v1" "v2")
                :series ((:name "compile" :values (25 20)) (:name "test" :values (9 6))
                         (:name "lint" :values (2 3)) (:name "package" :values (4 4)))))
        (lines '(:type "chart" :height 3 :series ((:name "p50 latency" :values (1 2 3)) (:name "p95 latency" :values (2 3 4))
                                                 (:name "p99 latency" :values (3 4 5))))))
    (dolist (component (list bars lines))
      (let ((text (agent-ui-test-aue-draw component :width 30)))
        (dolist (line (split-string text "\n"))
          (should (<= (string-width line) 30)))
        (should (string-match-p "● package\\|● p99 latency" text)))
      ;; In the GUI: every legend name drawn inside the image.
      (let* ((svg (agent-ui-test-aue-svg component 30))
             (width (progn (string-match "<svg width=\"\\([0-9]+\\)\"" svg) (string-to-number (match-string 1 svg))))
             (start 0))
        (while (string-match "x=\"\\([0-9.]+\\)\">\\(compile\\|test\\|lint\\|package\\|p[0-9]+ latency\\)<" svg start)
          (should (< (+ (string-to-number (match-string 1 svg)) (* 8 (length (match-string 2 svg)))) (+ width 8)))
          (setq start (match-end 0)))))))

(ert-deftest agent-ui-components/chart-labels-and-figures-fit ()
  "Long units and values: a sparkline's figures left out from the end, bar
values and line axis labels cut to a third of the width, every line within
it (they ran past it); in the GUI the plot stays inside the image."
  (let ((spark '(:type "chart" :kind "sparkline" :unit "ms" :values (1234.56 1500.25 1000.12 1300.5)))
        (bars '(:type "chart" :kind "bar" :unit "requests per second" :labels ("api" "web") :values (1200 800)))
        (line '(:type "chart" :height 3 :unit "requests per second" :values (1000.55 2000.25 1500))))
    (dolist (component (list spark bars line))
      (dolist (width '(20 30 40))
        (dolist (text-line (split-string (agent-ui-test-aue-draw component :width width) "\n"))
          (should (<= (string-width text-line) width)))))
    ;; Wide: the sparkline's figures all there.
    (should (string-match-p "last 1300.5 ms  min 1000.12  max 1500.25" (agent-ui-test-aue-draw spark :width 80)))
    ;; The line's plot inside its image at 20 columns (its left was 232 in 160).
    (let ((svg (agent-ui-test-aue-svg line 20)))
      (string-match "points=\"\\([0-9.]+\\)" svg)
      (should (< (string-to-number (match-string 1 svg)) 160)))))

(ert-deftest agent-ui-components/chart-svg-within-min-and-max ()
  "Values past a line chart's min or max: at the plot's edge in the GUI (the
line left the image at the top and crossed the labels' row)."
  (let* ((svg (agent-ui-test-aue-svg '(:type "chart" :height 4 :min 0 :max 10 :labels ("a" "b" "c" "d") :values (5 20 -10 5)) 40))
         (points (progn (string-match "points=\"\\([^\"]+\\)\"" svg) (match-string 1 svg)))
         (ys (mapcar (lambda (p) (string-to-number (cadr (split-string (string-trim p) " "))))
                     (split-string points ","))))
    (should (cl-every (lambda (y) (and (>= y 0) (<= y (* 4 16)))) ys))))

(ert-deftest agent-ui-components/chart-bars-start-at-min ()
  "A bar chart's min: its bars start at it (95 and 100 from 90: half and
whole; it was ignored, both near the full width); stacked bars from 0."
  (let* ((text (agent-ui-test-aue-draw '(:type "chart" :kind "bar" :min 90 :labels ("a" "b") :values (95 100)) :width 40))
         (bars (mapcar (lambda (line) (cl-count-if (lambda (c) (memq c '(?█ ?▉ ?▊ ?▋ ?▌ ?▍ ?▎ ?▏))) line))
                       (split-string text "\n"))))
    (should (< (abs (- (* 2 (car bars)) (cadr bars))) 2)))
  (let ((stacked (agent-ui-test-aue-draw '(:type "chart" :kind "bar" :stacked t :min 90 :labels ("a")
                                   :series ((:name "x" :values (50)) (:name "y" :values (50))))
                                 :width 40)))
    (should (string-match-p "100" stacked))))

(ert-deftest agent-ui-components/chart-stacked-bars-not-too-long ()
  "A stacked bar no longer than its total says: 99.5 not longer than 100 (it
came out a cell too long, its line past the width)."
  (let* ((text (agent-ui-test-aue-draw '(:type "chart" :kind "bar" :stacked t :labels ("a" "b")
                                 :series ((:name "x" :values (99 100)) (:name "y" :values (0.5 0))))
                               :width 42))
         (lines (split-string text "\n"))
         (cells (lambda (line) (cl-count-if (lambda (c) (memq c '(?█ ?▉ ?▊ ?▋ ?▌ ?▍ ?▎ ?▏))) line))))
    (dolist (line lines) (should (<= (string-width line) 42)))
    (should (<= (funcall cells (car lines)) (funcall cells (cadr lines))))))

(ert-deftest agent-ui-components/chart-time-labels-by-columns ()
  "Time-axis labels with wide characters (a CJK locale's months): placed by
their columns, under their ticks, within the width (by characters, they
drifted right and past it)."
  (cl-letf (((symbol-function 'agent-ui-chart--ticks)
             (lambda (&rest _) (list (cons 0.0 "11月 01") (cons 0.5 "11月 04") (cons 1.0 "11月 07")))))
    (let* ((axis (agent-ui-chart--time-axis '(:times (0 600)) 40))
           (labels (cdr axis)))
      (should (<= (string-width labels) 40))
      ;; The middle one centred under its tick (column 19 or 20).
      (let* ((tick (cl-position ?┬ (car axis) :start 1))
             (start (string-search "11月 04" labels))
             (column (string-width (substring labels 0 start))))
        (should (<= (abs (- (+ column 3) tick)) 1))))))

(ert-deftest agent-ui-components/chart-time-axis-over-years ()
  "A span of years: a few ticks on months or years, labelled with the year
(a tick every 30 days without it made a comb of ┬)."
  (let* ((years (mapcar (lambda (i) (+ 1735689600 (* i 365 86400))) (number-sequence 0 24)))
         (component (list :type "chart" :height 3 :values (number-sequence 1 25) :times years))
         (text (agent-ui-test-aue-draw component :width 60))
         (axis (car (last (split-string text "\n") 2))))
    (should (<= (cl-count ?┬ axis) 6))
    (should (string-match-p "20[2-4][0-9]" (car (last (split-string text "\n")))))
    (should (<= (cl-count ?\n (replace-regexp-in-string "<line" "\n" (agent-ui-test-aue-svg component 60))) 12)))
  ;; Two years, monthly: months with their years.
  (let ((ticks (agent-ui-chart--ticks 1735689600 (+ 1735689600 (* 730 86400)) 6)))
    (should (<= (length ticks) 6))
    (should (cl-every (lambda (tick) (string-match-p "\\`[A-Za-z]+ 20[0-9][0-9]\\'" (cdr tick))) ticks)))
  ;; Days apart: as before.
  (should (string-match-p "\\`[A-Za-z]+ [0-9][0-9]\\'" (cdar (agent-ui-chart--ticks 1735689600 (+ 1735689600 (* 10 86400)) 6)))))

(ert-deftest agent-ui-components/chart-bars-of-nothing ()
  "Bars whose highest value is 0 (all 0 or below, or max 0): drawn, empty, text
and GUI (it divided by 0: \"Arithmetic overflow error\")."
  (dolist (component '((:type "chart" :kind "bar" :labels ("a" "b" "c") :values (-2 -1 0))
                     (:type "chart" :kind "bar" :labels ("a") :values (0))))
    (let ((text (agent-ui-test-aue-draw component :width 40)))
      (should-not (string-search "⚠" text))
      (should-not (string-search "█" text)))
    (should (agent-ui-test-aue-svg component 40)))
  ;; Max 0 and a min below: bars from the min (doom-nwj.52), no break.
  (should-not (string-search "⚠" (agent-ui-test-aue-draw '(:type "chart" :kind "bar" :min -10 :max 0 :values (-5 -3)) :width 40))))

(ert-deftest agent-ui-components/chart-bars ()
  (let ((component '(:type "chart" :kind "bar" :unit "ms" :labels ("mon" "tue" "wed" "thu")
                   :values (120 95 180 60))))
    (should (equal (agent-ui-test-aue-draw component :width 50)
                   (concat "mon  ████████████████████████▋              120 ms\n"
                           "tue  ███████████████████▌                    95 ms\n"
                           "wed  █████████████████████████████████████  180 ms\n"
                           "thu  ████████████▎                           60 ms")))
    (should (eq (agent-ui-test-aue-face-at component "█") 'agent-ui-accent)))
  ;; No labels: numbered.
  (should (string-prefix-p "1  " (agent-ui-test-aue-draw '(:type "chart" :kind "bar" :values (1 2))))))

(ert-deftest agent-ui-components/chart-sparkline ()
  (should (equal (agent-ui-test-aue-draw '(:type "chart" :kind "sparkline" :unit "ms" :values (3 5 9 4 12 20 15 8 3 1 7)))
                 "▁▂▄▂▅█▆▃▁▁▃  last 7 ms  min 1  max 20"))
  ;; The latest that fit.
  (let ((text (agent-ui-test-aue-draw (list :type "chart" :kind "sparkline" :values (number-sequence 1 100))
                              :width 40)))
    (should (= (string-width text) 40))
    (should (string-suffix-p "last 100  min 1  max 100" text))))

(ert-deftest agent-ui-components/chart-lines ()
  (let* ((component '(:type "chart" :height 4 :labels ("a" "b" "c")
                    :series ((:name "up" :values (1 2 3)) (:name "down" :values (3 2 1)))))
         (lines (split-string (agent-ui-test-aue-draw component :width 30) "\n")))
    ;; The height, then the labels, then the legend.
    (should (= (length lines) 6))
    (should (string-prefix-p "3 ┤" (nth 0 lines)))
    (should (string-prefix-p "  │" (nth 1 lines)))
    (should (string-prefix-p "1 ┤" (nth 3 lines)))
    (should (string-match-p "\\`   a +c\\'" (nth 4 lines)))
    (should (equal (nth 5 lines) "   ● up  ● down"))
    (dolist (line lines) (should (<= (string-width line) 30)))
    ;; Braille, each series its colour: up starts low, down high.
    (should (string-match-p "[⠀-⣿]" (nth 0 lines)))
    (should (eq (agent-ui-test-aue-face-at component "● up") 'agent-ui-accent))
    (should (eq (agent-ui-test-aue-face-at component "● down") 'agent-ui-warning)))
  ;; The plot: a rising line's first dot at the bottom left, its last at the
  ;; top right.
  (let ((plot (agent-ui-chart--plot '((:values (0 10))) '(0 . 10) 2 1)))
    ;; 4 dots wide, 4 high: (0,3) in the first cell, (3,0) in the second.
    (should (/= 0 (logand (aref (car plot) 0) #x40)))
    (should (/= 0 (logand (aref (car plot) 1) #x08))))
  (should (equal (agent-ui-test-aue-draw '(:type "chart")) "no values yet")))

(ert-deftest agent-ui-components/chart-as-svg ()
  (let* ((text (agent-ui-render '(:type "chart" :labels ("a" "c") :values (1 5 3) :title "T")
                                (agent-ui-context :width 50 :graphic t :char-width 8 :line-height 16)))
         (image (get-text-property 2 'display text))
         (svg (plist-get (cdr image) :data)))
    (should (string-prefix-p "T\n" (substring-no-properties text)))
    (should (eq (car image) 'image))
    (should (eq (plist-get (cdr image) :type) 'svg))
    ;; As wide as the text's 50 columns.
    (should (string-match-p "<svg width=\"400\"" svg))
    (should (string-match-p "<polyline" svg))
    (should (string-match-p ">5</text>" svg))
    (should (string-match-p ">a</text>" svg)))
  (let ((svg (plist-get (cdr (get-text-property
                              0 'display
                              (agent-ui-render '(:type "chart" :kind "bar" :labels ("x" "y") :values (1 2))
                                               (agent-ui-context :graphic t))))
                        :data)))
    (should (= (cl-count ?\n (replace-regexp-in-string "<rect" "\n" svg)) 2)))
  ;; A sparkline, or nothing to draw: text.
  (should-not (get-text-property 0 'display (agent-ui-render '(:type "chart" :kind "sparkline" :values (1 2))
                                                             (agent-ui-context :graphic t))))
  (should (equal (substring-no-properties (agent-ui-render '(:type "chart") (agent-ui-context :graphic t)))
                 "no values yet")))

(ert-deftest agent-ui-components/chart-live ()
  ;; Values appended, the latest WINDOW kept.
  (let* ((component '(:type "chart" :window 3 :values (1 2)))
         (more (agent-ui-append-to component '(:values (3 4 5)))))
    (should (equal (plist-get more :values) '(3 4 5)))
    (should (equal (plist-get (car (plist-get (agent-ui-check "chart" more) :series)) :values) '(3 4 5))))
  ;; Series by name; a new one added.
  (let ((more (agent-ui-append-to '(:type "chart" :series ((:name "a" :values (1))))
                                  '(:series ((:name "a" :values (2)) (:name "b" :values (9)))))))
    (should (equal (plist-get more :series) '((:name "a" :values (1 2)) (:name "b" :values (9))))))
  (should (string-match-p "only values, series, labels and times"
                          (agent-ui-error-message
                           (should-error (agent-ui-append-to '(:type "chart") '(:unit "x"))
                                         :type 'agent-ui-error)))))

(ert-deftest agent-ui-components/chart-window-keeps-only-its-values ()
  "Appending keeps only the window's latest values, a series' too, and as
many labels and times (only those drawn were trimmed: 2000 appends to a
window of 3 kept 2000, each append copying them all); no window: all."
  (let ((component '(:type "chart" :window 3 :values ())))
    (dotimes (i 2000)
      (setq component (agent-ui-append-to component (list :values (list i)))))
    (should (equal (plist-get component :values) '(1997 1998 1999))))
  (let ((component '(:type "chart" :window 2 :series ((:name "a" :values (1)) (:name "b" :values ())))))
    (dotimes (i 100)
      (setq component (agent-ui-append-to component (list :series (list (list :name "a" :values (list i))
                                                                    (list :name "b" :values (list (- i))))))))
    (should (equal (plist-get component :series) '((:name "a" :values (98 99)) (:name "b" :values (-98 -99))))))
  (let ((component (agent-ui-append-to '(:type "chart" :window 2 :values (1 2) :labels ("a" "b")
                                       :times (100 200))
                                     '(:values (3) :labels ("c") :times (300)))))
    (should (equal (plist-get component :values) '(2 3)))
    (should (equal (plist-get component :labels) '("b" "c")))
    (should (equal (plist-get component :times) '(200 300))))
  (should (equal (plist-get (agent-ui-append-to '(:type "chart" :values (1 2)) '(:values (3))) :values)
                 '(1 2 3))))

(ert-deftest agent-ui-components/chart-without-window-keeps-what-it-draws ()
  "A live chart without a window keeps as many of its latest values as it
draws (`agent-ui-max-rows'), not every one appended, each append copying
them all; a histogram, which counts them all, many more."
  (let ((component '(:type "chart" :values ())))
    (dotimes (i 10000)
      (setq component (agent-ui-append-to component (list :values (list i)))))
    (should (= (length (plist-get component :values)) agent-ui-max-rows))
    (should (equal (last (plist-get component :values) 2) '(9998 9999)))
    ;; Drawn as before: its latest.
    (should (equal (plist-get (car (plist-get (agent-ui-check "chart" component) :series)) :values)
                   (plist-get component :values))))
  (let ((component (agent-ui-append-to '(:type "chart" :series ((:name "a" :values ())))
                                     (list :series (list (list :name "a" :values (number-sequence 1 (* 2 agent-ui-max-rows))))))))
    (should (= (length (plist-get (car (plist-get component :series)) :values)) agent-ui-max-rows)))
  (let ((component (agent-ui-append-to '(:type "chart" :kind "histogram" :values ())
                                     (list :values (number-sequence 1 (* 2 agent-ui-max-rows))))))
    (should (= (length (plist-get component :values)) (* 2 agent-ui-max-rows)))))

(ert-deftest agent-ui-components/chart-wrong ()
  (should (equal (agent-ui-test-aue-error '(:type "chart" :values (1 "x")))
                 "chart: values must be numbers; value 2 is \"x\""))
  (should (string-match-p "values (one series) or series, not both"
                          (agent-ui-test-aue-error '(:type "chart" :values (1) :series ((:values (1)))))))
  (should (string-match-p "a histogram chart has one series"
                          (agent-ui-test-aue-error '(:type "chart" :kind "histogram" :series ((:values (1)) (:values (2)))))))
  (should (string-match-p "series 1 has \"color\""
                          (agent-ui-test-aue-error '(:type "chart" :series ((:values (1) :color "red"))))))
  (should (string-match-p "height must be from 2 to 40"
                          (agent-ui-test-aue-error '(:type "chart" :height 1))))
  (should (string-match-p "min must be below max"
                          (agent-ui-test-aue-error '(:type "chart" :min 5 :max 5)))))

(ert-deftest agent-ui-components/a-stacked-bar-s-ends-rounded ()
  "A stacked bar: its parts square, end to end, clipped to one rounded
rectangle their total length (its outer ends rounded as a plain bar's); a
plain or grouped bar's own corners rounded, as before (doom-ht6.35)."
  (let* ((dom (agent-ui-test-aue-svg-dom '(:type "chart" :kind "bar" :stacked t :labels ("a" "b")
                                   :series ((:name "x" :values (3 0)) (:name "y" :values (2 5))))
                                 60))
         (clips (dom-by-tag dom 'clipPath))
         (parts (seq-filter (lambda (rect) (plist-get rect :clip)) (agent-ui-test-aue-rects dom))))
    ;; Row a: two parts, one clip; row b: one part of 5 (and an empty one).
    (should (= (length clips) 2))
    (let* ((clip (car clips))
           (shape (car (dom-by-tag clip 'rect)))
           (id (dom-attr clip 'id))
           (mine (seq-filter (lambda (rect) (equal (plist-get rect :clip) (format "url(#%s)" id))) parts)))
      (should (equal (dom-attr shape 'rx) "2"))
      (should (= (length mine) 2))
      ;; Square, touching, together the clip's length.
      (should-not (plist-get (car mine) :rx))
      (should (< (abs (- (+ (plist-get (car mine) :x) (plist-get (car mine) :width)) (plist-get (cadr mine) :x))) 0.01))
      (should (< (abs (- (+ (plist-get (car mine) :width) (plist-get (cadr mine) :width))
                         (string-to-number (dom-attr shape 'width))))
                 0.01))))
  ;; Plain and grouped: rounded, no clip.
  (dolist (component '((:type "chart" :kind "bar" :labels ("a" "b") :series ((:values (3 5))))
                     (:type "chart" :kind "bar" :labels ("a") :series ((:name "x" :values (3)) (:name "y" :values (5))))))
    (let ((dom (agent-ui-test-aue-svg-dom component 60)))
      (should-not (dom-by-tag dom 'clipPath))
      (dolist (rect (agent-ui-test-aue-rects dom))
        (should (equal (plist-get rect :rx) 2))))))

(ert-deftest agent-ui-components/chart-bars-grouped-and-stacked ()
  (let ((grouped '(:type "chart" :kind "bar" :labels ("a" "b")
                   :series ((:name "x" :values (2 4)) (:name "y" :values (1 3))))))
    ;; Grouped: a bar per series under each label, each its colour; a legend.
    (should (equal (agent-ui-test-aue-draw grouped :width 20)
                   (concat "a  ███████         2\n"
                           "   ███▌            1\n"
                           "b  ██████████████  4\n"
                           "   ██████████▌     3\n"
                           "   ● x  ● y")))
    (should (eq (agent-ui-test-aue-face-at grouped "███▌" :width 20) (agent-ui-chart--face 1)))
    ;; Stacked: a bar per label, its series end to end, their total.
    (let ((text (agent-ui-render (append '(:stacked t) grouped) (agent-ui-context :width 20))))
      (should (equal (substring-no-properties text)
                     "a  ██████          3\nb  ██████████████  7\n   ● x  ● y"))
      ;; b: 4 of 7 in x's colour (8 cells), 3 in y's (6).
      (let ((b (cadr (split-string text "\n"))))
        (should (eq (get-text-property 10 'face b) (agent-ui-chart--face 0)))
        (should (eq (get-text-property 11 'face b) (agent-ui-chart--face 1)))
        (should (eq (get-text-property 3 'face b) (agent-ui-chart--face 0)))))
    ;; As SVG: a rectangle per segment (clipped to its bar's: doom-ht6.35),
    ;; a legend.
    (let ((svg (plist-get (cdr (get-text-property 0 'display (agent-ui-render (append '(:stacked t) grouped)
                                                                              (agent-ui-context :width 40 :graphic t :char-width 8 :line-height 16))))
                          :data)))
      (with-temp-buffer
        (insert svg)
        (should (= (count-matches "<rect[^>]*clip-path" (point-min) (point-max)) 4))
        (should (= (count-matches "<circle" (point-min) (point-max)) 2))))))

(ert-deftest agent-ui-components/chart-histogram ()
  (let ((component '(:type "chart" :kind "histogram" :unit "ms" :bins 4 :values (0 1 2 3 4 5 6 7 8 9 10 40))))
    ;; Counted in 4 bins of 10, 0 to 40, each its range.
    (should (equal (plist-get (car (plist-get (agent-ui-chart--histogram (agent-ui-check "chart" component)) :series))
                              :values)
                   '(10 1 0 1)))
    (should (string-match-p "\\`0–10 ms  +█+ +10\n10–20 ms  .* 1\n20–30 ms  +0\n30–40 ms  .* 1\\'"
                            (agent-ui-test-aue-draw component)))
    ;; Its min and max: its bins' span (the counts' axis from 0).
    (should (string-match-p "\\`0–25 ms .*\n25–50 ms "
                            (agent-ui-test-aue-draw '(:type "chart" :kind "histogram" :unit "ms" :bins 2 :min 0 :max 50
                                              :values (5 30)))))
    (should (string-match-p "bins must be from 1 to 50"
                            (agent-ui-test-aue-error '(:type "chart" :kind "histogram" :bins 0 :values (1)))))))

(ert-deftest agent-ui-components/chart-a-time-axis ()
  (let ((zone (getenv "TZ")))
    (unwind-protect
        (progn
          (set-time-zone-rule "UTC")
          ;; Times as dates and times, or seconds; wrong ones said so.
          (should (= (agent-ui-chart--time "1970-01-02") 86400.0))
          (should (= (agent-ui-chart--time "1970-01-01T00:01:00Z") 60.0))
          (should (= (agent-ui-chart--time 5) 5.0))
          (should (string-match-p "time 2 is \"soon\""
                                  (agent-ui-test-aue-error '(:type "chart" :values (1 2) :times (0 "soon")))))
          ;; Ticks at round times: hours over a day's hours, midnights over days.
          (should (equal (mapcar #'cdr (agent-ui-chart--ticks (* 9.5 3600) (* 17 3600) 5))
                         '("10:00" "12:00" "14:00" "16:00")))
          (should (equal (car (agent-ui-chart--ticks 0 (* 6 86400) 7)) '(0.0 . "Jan 01")))
          ;; Drawn: the values placed by their times; the axis, ┬ at each tick.
          (let* ((component '(:type "chart" :height 2 :values (1 2 3) :times (0 600 3600)))
                 (lines (split-string (agent-ui-test-aue-draw component :width 30) "\n")))
            (should (string-match-p "\\` +└┬─+┬─+┬─*\\'" (nth 2 lines)))
            (should (string-match-p "00:00 +00:30 +01:00" (nth 3 lines))))
          ;; As SVG: the axis's ticks, labelled.
          (let ((svg (plist-get (cdr (get-text-property 0 'display (agent-ui-render '(:type "chart" :values (1 2 3) :times (0 600 3600))
                                                                                    (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16))))
                                :data)))
            (should (string-match-p ">00:20</text>" svg)))
          ;; Appended, with values: kept as many as they are.
          (should (equal (plist-get (agent-ui-append-to '(:type "chart" :values (1) :times (0)) '(:values (2) :times (60))) :times)
                         '(0 60))))
      (set-time-zone-rule zone))))

;;; agent-ui-chart-tests.el ends here
