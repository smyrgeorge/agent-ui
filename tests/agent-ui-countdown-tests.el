;;; agent-ui-countdown-tests.el --- Tests for Agent UI: the countdown component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-countdown.el: the countdown component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/countdown ()
  "Elapsed since a start; left until an end, in the warning colour its last
WARN seconds; past it, ended so long ago (never negative). From the clock."
  (let ((agent-ui-clock (lambda () 1800000000.0)))
    (should (equal (agent-ui-test-aue-draw '(:type "countdown" :label "Build" :since 1799999240.0)) "Build  12m 40s"))
    (should (equal (agent-ui-test-aue-draw '(:type "countdown" :label "Resets in" :until 1800000252.0)) "Resets in  4m 12s left"))
    (should (eq (agent-ui-test-aue-face-at '(:type "countdown" :until 1800000252.0 :warn 300) "4m") 'agent-ui-warning))
    (should (eq (agent-ui-test-aue-face-at '(:type "countdown" :until 1800000252.0 :warn 60) "4m") 'bold))
    (should (equal (agent-ui-test-aue-draw '(:type "countdown" :until 1799999875.0)) "ended 2m 05s ago"))
    ;; Seconds from now, drawn without being shown: from now.
    (should (equal (agent-ui-test-aue-draw '(:type "countdown" :until 90)) "1m 30s left"))
    (should (equal (agent-ui-test-aue-draw '(:type "countdown" :label "a long label for a narrow pane" :until 90) :width 20)
                   "a long…  1m 30s left"))
    ;; The GUI: a tile, the time big.
    (let ((text (agent-ui-render '(:type "countdown" :label "Resets in" :until 1800000252.0)
                                 (agent-ui-context :width 40 :graphic t :char-width 8 :line-height 16))))
      (should (string-match-p ">4m 12s</text>" (plist-get (cdr (get-text-property 0 'display text)) :data))))
    (should (agent-ui-animated-p '(:type "countdown" :until 90)))))

(ert-deftest agent-ui-components/countdown-time-kept-whole ()
  "The time whole at 16 columns and up, in text and the GUI: the label cut
first, then the word left out (the line was cut from its end: \"Rate limit
resets in  4…\" at 24; in the GUI, \"12h 30m\" overlapped \"elapsed\")."
  (let ((agent-ui-clock (lambda () 1800000000.0))
        (resets '(:type "countdown" :label "Rate limit resets in" :until 1800000252.0))
        (long '(:type "countdown" :label "The deploy window for the production cluster closes in"
                :until 1800045000.0))
        (since '(:type "countdown" :label "Build running" :since 1799955000.0)))
    (should (equal (agent-ui-test-aue-draw resets :width 24) "Rate limit…  4m 12s left"))
    (should (equal (agent-ui-test-aue-draw resets :width 16) "4m 12s left"))
    (should (string-suffix-p "…  12h 30m left" (agent-ui-test-aue-draw long :width 60)))
    (dolist (width (number-sequence 16 60))
      (should (string-search "4m 12s" (agent-ui-test-aue-draw resets :width width)))
      (should (string-search "12h 30m" (agent-ui-test-aue-draw long :width width)))
      (should (<= (string-width (agent-ui-test-aue-draw long :width width)) width)))
    ;; The GUI: the time and its word apart, or the word left out; the time
    ;; within the tile.
    (dolist (component (list resets since))
      (dolist (width (number-sequence 16 30))
        (let* ((svg (plist-get (cdr (get-text-property
                                     0 'display
                                     (agent-ui-render component (agent-ui-context :width width :graphic t
                                                                                :char-width 11 :line-height 25))))
                               :data))
               (texts (let ((out nil) (start 0))
                        (while (string-match "font-size=\"\\([0-9]+\\)\"[^>]*x=\"\\([0-9.]+\\)\">\\([^<]*\\)</text>"
                                             svg start)
                          (push (list (match-string 3 svg) (string-to-number (match-string 1 svg))
                                      (string-to-number (match-string 2 svg)))
                                out)
                          (setq start (match-end 0)))
                        (nreverse out)))
               (time (cl-find-if (lambda (text) (string-match-p "\\`[0-9]" (car text))) texts))
               (word (cl-find-if (lambda (text) (member (car text) '("left" "elapsed"))) texts))
               (time-end (+ (nth 2 time) (* 0.6 (nth 1 time) (string-width (car time)))))
               (tile (* 11 (min width 28))))
          (should (<= time-end (- tile 11)))
          (when word
            (should (<= (+ time-end 11) (- (nth 2 word) (* 0.6 (nth 1 word) (string-width (car word))))))))))))

(ert-deftest agent-ui-components/countdown-a-time-when-shown ()
  "Shown, seconds from now become a time: it goes on from there (shown
again or redrawn later, it doesn't start again); a timestamp in epoch
seconds."
  (agent-ui-test-aue-canvas
    (let* ((now 1800000000.0)
           (agent-ui-clock (lambda () now)))
      (agent-ui-show '(:id "rl" :type "countdown" :label "Resets in" :until 300))
      (should (= (plist-get (agent-ui-get "rl") :until) 1800000300.0))
      (setq now (+ now 61))
      (agent-ui-update "rl" '(:label "Reset in"))
      (should (= (plist-get (agent-ui-get "rl") :until) 1800000300.0))
      (with-current-buffer canvas
        (agent-ui--flush)
        (should (string-search "Reset in  3m 59s left" (buffer-string))))
      (agent-ui-show '(:id "w" :type "countdown" :until "2026-11-10T18:30:00Z"))
      (should (= (plist-get (agent-ui-get "w") :until) (float-time (parse-iso8601-time-string "2026-11-10T18:30:00Z")))))))

(ert-deftest agent-ui-components/countdown-wrong ()
  (should (string-match-p "give since .* or until" (agent-ui-test-aue-error '(:type "countdown"))))
  (should (string-match-p "give since .* or until" (agent-ui-test-aue-error '(:type "countdown" :since 1 :until 2))))
  (should (string-match-p "until is a timestamp" (agent-ui-test-aue-error '(:type "countdown" :until "soon"))))
  (should (string-match-p "warn is seconds" (agent-ui-test-aue-error '(:type "countdown" :until 10 :warn -1)))))

;;; agent-ui-countdown-tests.el ends here
