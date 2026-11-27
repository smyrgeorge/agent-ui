;;; agent-ui-timeline-tests.el --- Tests for Agent UI: the timeline component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-timeline.el: the timeline component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/timeline-a-late-running-task ()
  "A running task (seconds) starting after the last end: the axis reaches its
start, its bar there, inside the SVG (it lay past the axis: clamped to its
end in text, outside the image in the GUI)."
  (let ((component '(:type "timeline" :tasks ((:name "build" :start 0 :duration 8) (:name "test" :start 10)))))
    (should (string-match-p "10s\\'" (agent-ui-test-aue-draw component :width 50)))
    (let* ((svg (agent-ui-test-aue-svg component 60))
           (width (progn (string-match "<svg width=\"\\([0-9]+\\)\"" svg) (string-to-number (match-string 1 svg))))
           (start 0) (xs nil))
      (while (string-match "<rect width=\"\\([0-9.]+\\)\"[^>]* x=\"\\([0-9.]+\\)\"" svg start)
        (push (+ (string-to-number (match-string 2 svg)) (string-to-number (match-string 1 svg))) xs)
        (setq start (match-end 0)))
      (should (cl-every (lambda (x) (<= x width)) xs))))
  (should (string-match-p "3s\\'" (agent-ui-test-aue-draw '(:type "timeline" :tasks ((:name "a" :start 0) (:name "b" :start 3))) :width 50))))

(ert-deftest agent-ui-components/timeline-gui-names-cut ()
  "In the GUI a long task name is wrapped in its column, its row taller
(whole on one line it ran under the bars; cut, its rest was nowhere:
doom-cbj)."
  (let ((svg (agent-ui-test-aue-svg '(:type "timeline" :tasks ((:name "integration-tests-shard-1" :start 0 :duration 8)
                                                       (:name "unit" :start 4 :duration 10 :status "failed")))
                            60)))
    (should-not (string-match-p "&#8230;" svg))
    (should (string-match-p ">integration-tests-sh</text>.*>ard-1</text>" svg))
    ;; The next task a line lower: "unit" under the wrapped name.
    (should (string-match-p "y=\"53.4\" x=\"0\">unit<" svg))))

(ert-deftest agent-ui-components/timeline-text-fits-narrow-widths ()
  "Narrow: the names' column shrinks, then the bars, every line within the
width, the scale's labels apart (\"0s  13s26s\"; 21 columns at 20)."
  (dolist (component '((:type "timeline" :tasks ((:name "build" :start 0 :duration 8) (:name "test-1" :start 8 :duration 14)
                                               (:name "test-2" :start 8 :duration 11 :status "failed")
                                               (:name "deploy" :start 22 :duration 4 :status "queued")))
                     (:type "timeline" :tasks ((:name "a" :start 0 :duration 48) (:name "b" :start 48 :duration 77)))))
    (dolist (width '(15 20 25 30 36 40))
      (let ((text (agent-ui-test-aue-draw component :width width)))
        (dolist (line (split-string text "\n"))
          (should (<= (string-width line) width)))
        ;; The scale: its labels a space apart at least.
        (should-not (string-match-p "s[0-9]" (car (last (split-string text "\n")))))))))

(ert-deftest agent-ui-components/timeline-gui-narrow ()
  "In the GUI at 10, 15, 20 columns: every bar inside the image, right of the
names, the scale's labels apart (bars went left of their start, over their
names; the end label outside the image, or on \"0s\")."
  (let ((component '(:type "timeline" :tasks ((:name "build" :start 0 :duration 8) (:name "test-1" :start 8 :duration 14)
                                            (:name "test-2" :start 8 :duration 11 :status "failed")))))
    (dolist (columns '(10 15 20))
      (let* ((svg (agent-ui-test-aue-svg component columns))
             (width (* 8 columns)) (start 0))
        (while (string-match "<rect width=\"\\([0-9.]+\\)\"[^>]* x=\"\\([0-9.]+\\)\"" svg start)
          (let ((x (string-to-number (match-string 2 svg))) (w (string-to-number (match-string 1 svg))))
            (should (>= x 16))
            (should (<= (+ x w) width)))
          (setq start (match-end 0)))
        ;; The end label, if shown, past \"0s\" and within the image.
        (when (string-match "text-anchor=\"end\"[^>]*x=\"\\([0-9.]+\\)\">[0-9]" svg)
          (should (<= (string-to-number (match-string 1 svg)) width)))))))

(ert-deftest agent-ui-components/timeline-seconds-or-timestamps ()
  "Tasks in seconds and others in timestamps (or one task's start and end
mixed): refused, saying so (an axis of \"249209h 03m\")."
  (should (string-match-p "all use seconds or all timestamps"
                          (agent-ui-test-aue-error '(:type "timeline" :tasks ((:name "secs" :start 0 :duration 10)
                                                                      (:name "stamp" :start "2026-11-09T12:01:00Z" :duration 30))))))
  (should (string-match-p "task 1's start and end must both be"
                          (agent-ui-test-aue-error '(:type "timeline" :tasks ((:name "x" :start "2026-11-09T12:01:00Z" :end 1762689700)))))))

(ert-deftest agent-ui-components/timeline-finished-stamped-spans-its-tasks ()
  "Finished tasks given timestamps: the axis spans them (it ran to now: a day
later, 22 hours wide); one still running: to now."
  (let* ((agent-ui-clock (lambda () (+ (float-time (date-to-time "2026-11-09T12:10:00Z")) 86400)))
         (done '(:type "timeline" :tasks ((:name "build" :start "2026-11-09T12:00:00Z" :end "2026-11-09T12:05:00Z")
                                          (:name "test" :start "2026-11-09T12:05:00Z" :end "2026-11-09T12:10:00Z"))))
         (text (agent-ui-test-aue-draw done :width 60)))
    (should (string-match-p "10m 00s\\'" text))
    (should-not (string-match-p "h " text))
    ;; Running: to now, a day on.
    (should (string-match-p "24h" (agent-ui-test-aue-draw '(:type "timeline" :tasks ((:name "deploy" :start "2026-11-09T12:10:00Z")))
                                                  :width 60)))))

(ert-deftest agent-ui-components/timeline ()
  (let ((component '(:type "timeline" :tasks ((:name "build" :start 0 :duration 10)
                                           (:name "test" :start 10 :end 20 :status "failed")
                                           (:name "deploy" :start 20 :duration 10 :status "queued")))))
    (should (equal (agent-ui-test-aue-draw component :width 50)
                   (concat "build   ██████████                      10s\n"
                           "test              ██████████            10s\n"
                           "deploy                      ░░░░░░░░░░  10s\n"
                           "        0s            15s          30s")))
    (should (eq (agent-ui-test-aue-face-at component "░") 'agent-ui-muted))
    (let ((text (agent-ui-render component (agent-ui-context :width 50))))
      (should (eq (get-text-property (string-search "10s" text (string-search "test" text)) 'face text)
                  'agent-ui-error)))
    (should-not (agent-ui-animated-p component)))
  ;; Running, in seconds: until the latest end; not animated.
  (should (string-match-p "  running"
                          (agent-ui-test-aue-draw '(:type "timeline" :tasks ((:name "a" :start 0 :duration 4) (:name "b" :start 2))))))
  ;; Timestamps: running ones until now, animated (they grow).
  (let* ((start (format-time-string "%FT%TZ" (time-subtract nil 30) t))
         (component (list :type "timeline" :tasks (list (list :name "job" :start start)))))
    (should (agent-ui-animated-p component))
    ;; Whole seconds in the timestamp: 30 or 31 ago.
    (should (string-match-p "3[01]s\\'" (agent-ui-test-aue-draw component))))
  ;; In the GUI: SVG bars.
  (let ((svg (plist-get (cdr (get-text-property 0 'display (agent-ui-render '(:type "timeline" :tasks ((:name "a" :start 0 :duration 1)))
                                                                            (agent-ui-context :graphic t))))
                        :data)))
    (should (string-match-p "<rect" svg)))
  (should (equal (agent-ui-test-aue-draw '(:type "timeline")) "no tasks")))

(ert-deftest agent-ui-components/timeline-milliseconds ()
  "Times under 1.5 s in milliseconds, a task's and the scale's, in text and
in the GUI (0.34 s was 0s, 1.2 s 1s); longer ones in seconds; the
threshold `agent-ui-milliseconds-below'."
  (should (equal (agent-ui-format-time-taken 0.34) "340ms"))
  (should (equal (agent-ui-format-time-taken 1.2) "1200ms"))
  (should (equal (agent-ui-format-time-taken 1.4994) "1499ms"))
  (should (equal (agent-ui-format-time-taken 1.5) "2s"))
  (should (equal (agent-ui-format-time-taken 8) "8s"))
  (let ((agent-ui-milliseconds-below 0))
    (should (equal (agent-ui-format-time-taken 0.34) "0s")))
  (let ((component '(:type "timeline" :tasks ((:name "parse" :start 0 :duration 0.12)
                                           (:name "check" :start 0.12 :duration 0.34 :status "failed")
                                           (:name "emit" :start 0.46 :duration 0.54)))))
    (let ((text (agent-ui-test-aue-draw component :width 50)))
      (should (string-match-p "  120ms\n" text))
      (should (string-match-p "  340ms\n" text))
      (should (string-match-p "  540ms\n" text))
      ;; The scale in milliseconds, its start too.
      (should (string-match-p "^ +0ms +500ms +1000ms\\'" (car (last (split-string text "\n")))))
      (dolist (width '(15 20 25 30))
        (dolist (line (split-string (agent-ui-test-aue-draw component :width width) "\n"))
          (should (<= (string-width line) width)))))
    (let ((svg (agent-ui-test-aue-svg component 60)))
      (should (string-match-p ">340ms</text>" svg))
      (should (string-match-p ">0ms</text>" svg))
      (should (string-match-p ">1000ms</text>" svg))))
  ;; Over 1.5 s: seconds, the scale from 0s.
  (let ((text (agent-ui-test-aue-draw '(:type "timeline" :tasks ((:name "a" :start 0 :duration 0.4) (:name "b" :start 0.4 :duration 3.6)))
                              :width 50)))
    (should (string-match-p "  400ms\n" text))
    (should (string-match-p "  4s\n" text))
    (should (string-match-p "^ +0s +2s +4s\\'" (car (last (split-string text "\n")))))))

(ert-deftest agent-ui-components/timeline-stamps-to-the-millisecond ()
  "Timestamps keep their fraction of a second (a task of 690 ms was drawn as
1 s: `date-to-time' drops it); whole seconds, another zone and a date of
another form as before."
  (should (string-match-p "  690ms\n"
                          (agent-ui-test-aue-draw '(:type "timeline" :tasks ((:name "check" :start "2026-11-25T21:17:49.461Z"
                                                                       :end "2026-11-25T21:17:50.151Z")))
                                          :width 50)))
  (should (= (agent-ui-timeline--time "2026-11-25T23:17:49.5+02:00") 1795641469.5))
  (should (= (agent-ui-timeline--time "2026-11-09T12:01:00Z") (float-time (date-to-time "2026-11-09T12:01:00Z"))))
  (should (= (agent-ui-timeline--time "Mon, 09 Nov 2026 12:01:00 +0000")
             (float-time (date-to-time "2026-11-09T12:01:00Z"))))
  (should-not (agent-ui-timeline--time "soon")))

(ert-deftest agent-ui-components/timeline-coloured-as-the-others ()
  "Its bars coloured as a checklist's steps and a graph's nodes are: running
the accent (blue), done success (green), failed error; not running yellow
\(what needs you) and done blue."
  (let ((text (agent-ui-render '(:type "timeline" :tasks ((:name "build" :start 0 :end 10 :status "done")
                                                         (:name "green" :start 10 :end 20 :status "running")
                                                         (:name "lint" :start 0 :end 5 :status "failed")))
                               (agent-ui-context :width 60))))
    (cl-flet ((bar-face (name)
                (let* ((line (string-search name text))
                       (bar (string-match "[█▒]" text line)))
                  (get-text-property bar 'face text))))
      (should (eq (bar-face "build") 'agent-ui-success))
      (should (eq (bar-face "green") 'agent-ui-accent))
      (should (eq (bar-face "lint") 'agent-ui-error)))))

(ert-deftest agent-ui-components/timeline-wrong ()
  (should (string-match-p "task 1 has no name" (agent-ui-test-aue-error '(:type "timeline" :tasks ((:start 0))))))
  (should (string-match-p "start must be seconds or a timestamp" (agent-ui-test-aue-error '(:type "timeline" :tasks ((:name "a" :start "soon"))))))
  (should (string-match-p "ends before it starts" (agent-ui-test-aue-error '(:type "timeline" :tasks ((:name "a" :start 5 :end 1))))))
  (should (string-match-p "status is running, done" (agent-ui-test-aue-error '(:type "timeline" :tasks ((:name "a" :start 0 :status "slow"))))))
  (should (string-match-p "has \"stop\"" (agent-ui-test-aue-error '(:type "timeline" :tasks ((:name "a" :start 0 :stop 3)))))))

;; A running timeline's frames, the clock faked: drawn again only once a second.
(ert-deftest agent-ui-components/timeline-a-frame-draws-once-a-second ()
  "A running timeline (timestamps): its frames within a second draw it once
\(they built a new SVG every 0.15 s, now a float clock), again once the
second changes; drawn as it would be whole (doom-ht6.114)."
  (agent-ui-test-aue-canvas
    (let* ((t0 (float-time (date-to-time "2026-11-09T12:10:00Z")))
           (now (+ t0 30.1))
           (agent-ui-clock (lambda () now)))
      (agent-ui-show '(:id "tl" :type "timeline"
                       :tasks ((:name "build" :start "2026-11-09T12:10:00Z" :duration 8)
                               (:name "deploy" :start "2026-11-09T12:10:08Z"))))
      (with-current-buffer canvas (agent-ui--flush))
      (save-window-excursion
        (switch-to-buffer canvas)
        (let ((drawn 0))
          (cl-letf* ((text (symbol-function 'agent-ui-timeline--text))
                     ((symbol-function 'agent-ui-timeline--text)
                      (lambda (&rest args) (cl-incf drawn) (apply text args))))
            (dotimes (_ 5)
              (agent-ui--frame canvas)
              (setq now (+ now 0.15)))
            (should (= drawn 1))
            ;; The next second: drawn again.
            (setq now (+ t0 31.2))
            (agent-ui--frame canvas)
            (should (= drawn 2)))
          (should (string-match-p "31s\\'" (substring-no-properties (agent-ui-test-aue--region "tl"))))
          (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "tl")
                                                     (agent-ui-test-aue--drawn-whole "tl"))))))))

(ert-deftest agent-ui-components/timeline-gui-the-same-within-a-second ()
  "A running timeline's SVG is the same all through a second (its bars'
geometry moved every 0.15 s); a frame builds it once (doom-ht6.114)."
  (let* ((t0 (float-time (date-to-time "2026-11-09T12:10:00Z")))
         (now (+ t0 30.05))
         (agent-ui-clock (lambda () now))
         (component '(:type "timeline" :tasks ((:name "build" :start "2026-11-09T12:10:00Z" :duration 8)
                                               (:name "deploy" :start "2026-11-09T12:10:08.250Z"))))
         (svg (agent-ui-test-aue-svg component 60)))
    (setq now (+ t0 30.95))
    (should (equal (agent-ui-test-aue-svg component 60) svg))
    (setq now (+ t0 31.05))
    (should-not (equal (agent-ui-test-aue-svg component 60) svg))
    ;; In an animation's frames: built once a second.
    (let ((agent-ui--memo (make-hash-table :test #'equal))
          (built 0)
          (ctx (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
      (cl-letf* ((gui (symbol-function 'agent-ui-timeline--gui))
                 ((symbol-function 'agent-ui-timeline--gui)
                  (lambda (&rest args) (cl-incf built) (apply gui args))))
        (dotimes (i 6)
          (setq now (+ t0 31.05 (* i 0.15)))
          (agent-ui-render component (plist-put (copy-sequence ctx) :tick i)))
        (should (= built 1))
        (setq now (+ t0 32.05))
        (agent-ui-render component ctx)
        (should (= built 2))))))

;;; agent-ui-timeline-tests.el ends here
