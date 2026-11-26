;;; agent-ui-slider-tests.el --- Tests for Agent UI: the slider component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-slider.el: the slider component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/slider ()
  "Its track, the knob at its value (snapped to its steps), its ends and the
value with its unit; the hint and Set; set: the value, nothing to move; a
still picture: the track only."
  (let ((slider '(:type "slider" :label "Timeout" :min 0 :max 120 :step 5 :unit "s" :value 31)))
    (should (equal (agent-ui-test-aue-draw slider :width 40)
                   (concat "Timeout\n"
                           " 0 ━━━━━━●────────────────── 120   30 s\n"
                           " h / l move it (H / L ten steps), a\n"
                           " click puts it there\n"
                           " ⏵ Set")))
    (should (equal (agent-ui-test-aue-draw slider :width 40 :still t)
                   "Timeout\n 0 ━━━━━━●────────────────── 120   30 s"))
    (should (equal (agent-ui-test-aue-draw (append '(:answered "30 s") slider) :width 40)
                   "Timeout\n 0 ━━━━━━●────────────────── 120   30 s\n ✓ Set: 30 s"))
    (should (agent-ui-ask-waiting-p slider))
    (should-not (agent-ui-ask-waiting-p (append '(:answered "30 s") slider)))
    (should-not (agent-ui-ask-waiting-p (append '(:live t) slider))))
  ;; No value: at its min; a float's steps.
  (should (string-search " 0 ●───" (agent-ui-test-aue-draw '(:type "slider" :min 0 :max 1 :step 0.25) :width 30)))
  (should (string-search "   0.5" (agent-ui-test-aue-draw '(:type "slider" :min 0 :max 1 :step 0.25 :value 0.4)))))

(ert-deftest agent-ui-components/slider-fits-the-width ()
  "A slider's lines within the width: its value on a line of its own when it
leaves the track under 5 columns, its ends left out too when narrower (the
line ran past the width, cut there: \"… 1000000   300\" read as 300)."
  (let ((ms '(:type "slider" :label "Request timeout" :min 0 :max 1000000 :step 5 :unit "milliseconds"
              :value 300000)))
    (dolist (width (number-sequence 8 60))
      (let ((text (agent-ui-test-aue-draw ms :width width)))
        (dolist (line (split-string text "\n"))
          (should (<= (string-width line) width)))
        (should (string-search "●" text))
        (when (>= width 22)
          (should (string-search "300000 milliseconds" text)))))
    (should (equal (agent-ui-test-aue-draw ms :width 24 :still t)
                   (concat "Request timeout\n"
                           " 300000 milliseconds\n"
                           " 0 ━━━━●──────── 1000000")))
    ;; Its ends left out where there's no room for them.
    (should (string-match-p "\n ━+●─+\\'" (agent-ui-test-aue-draw ms :width 14 :still t))))
  ;; Room enough: on one line, as before.
  (should (string-search " 0 ━━●────── 120   30 s"
                         (agent-ui-test-aue-draw '(:type "slider" :min 0 :max 120 :step 5 :unit "s" :value 30) :width 24))))

(ert-deftest agent-ui-components/slider-moved-and-set ()
  "On its track: h / l a step, H / L ten (its own keys there), never past
its ends; a click there; Set sends the value; then locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "t" :type "slider" :label "Timeout" :min 0 :max 120 :step 5 :unit "s" :value 30))
      (with-current-buffer canvas
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "●")
        (should (eq (key-binding (kbd "h")) #'agent-ui-slider-left))
        (should (eq (key-binding (kbd "L")) #'agent-ui-slider-right-more))
        (agent-ui-slider-right)
        (should (= (plist-get (agent-ui-get "t") :value) 35))
        (agent-ui-slider-left-more)
        (should (= (plist-get (agent-ui-get "t") :value) 0))
        (agent-ui-slider-right-more)
        (agent-ui-slider-right-more)
        (should (= (plist-get (agent-ui-get "t") :value) 100))
        (agent-ui-slider-right-more)
        (should (= (plist-get (agent-ui-get "t") :value) 120))
        ;; A click on the track's middle.
        (goto-char (point-min))
        (search-forward "120 ")
        (let* ((start (text-property-not-all (line-beginning-position) (line-end-position) 'agent-ui-slide-to nil))
               ;; Each of its characters has its own: the first without one.
               (end (text-property-any start (line-end-position) 'agent-ui-slide-to nil)))
          (funcall (get-text-property (/ (+ start end) 2) 'agent-ui-slide-to)))
        (should (= (plist-get (agent-ui-get "t") :value) 60))
        ;; Elsewhere, h is the cursor's.
        (goto-char (point-min))
        (should-not (eq (key-binding (kbd "h")) #'agent-ui-slider-left))
        (should-error (agent-ui-slider-left) :type 'user-error)
        (agent-ui-test-aue-press "⏵ Set")
        (should (equal sent '(("Answer to slider t (Timeout): 60 s" t))))
        (agent-ui--flush)
        (should (string-search "✓ Set: 60 s" (buffer-string)))
        (goto-char (point-min))
        (search-forward "●")
        (should-error (agent-ui-slider-left) :type 'user-error)))))

(ert-deftest agent-ui-components/slider-live ()
  "Live: no Set; the value sent once the knob rests (moved twice: once, the
last), at once; never locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-slider-live-delay 0.05)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "th" :type "slider" :label "Threshold" :min 0 :max 1 :step 0.1 :value 0.5 :live t))
      (with-current-buffer canvas
        (agent-ui--flush)
        (should-not (string-search "⏵ Set" (buffer-string)))
        (goto-char (point-min))
        (search-forward "●")
        (agent-ui-slider-right)
        (agent-ui-slider-right)
        (should-not sent)
        (let ((end (+ (float-time) 0.3)))
          (while (and (not sent) (< (float-time) end)) (accept-process-output nil 0.02)))
        (should (equal sent '(("Slider th (Threshold) set to 0.7" t))))
        (agent-ui-slider-left)
        (should (= (plist-get (agent-ui-get "th") :value) 0.6))))))

(ert-deftest agent-ui-components/slider-live-sent-as-itself ()
  "A live slider's value sent as its own (the component acting it, not
point's; no label: value); removed before it rests, nothing sent
\(doom-ht6.63)."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-slider-live-delay 0.05)
           (agent-ui-action-function (lambda (prompt _submit) (push (list prompt agent-ui-pressed) sent)))
           (wait (lambda () (let ((end (+ (float-time) 0.3)))
                              (while (< (float-time) end) (accept-process-output nil 0.02))))))
      (agent-ui-show '(:id "s" :type "slider" :min 0 :max 10 :value 5 :live t))
      (agent-ui-show '(:id "other" :type "text" :text "elsewhere"))
      (with-current-buffer canvas
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "●")
        (agent-ui-slider-right)
        (goto-char (point-max))
        (funcall wait)
        (should (equal sent '(("Slider s (value) set to 6" "s"))))
        (setq sent nil)
        (goto-char (point-min))
        (search-forward "●")
        (agent-ui-slider-right)
        (agent-ui-remove "s")
        (funcall wait)
        (should-not sent)))))

(ert-deftest agent-ui-components/slider-wrong ()
  (should (string-match-p "min is required" (agent-ui-test-aue-error '(:type "slider" :max 1))))
  (should (string-match-p "min must be below max" (agent-ui-test-aue-error '(:type "slider" :min 2 :max 1))))
  (should (string-match-p "step must be above 0" (agent-ui-test-aue-error '(:type "slider" :min 0 :max 1 :step 0))))
  (should (string-match-p "value 12 is outside 0 to 10" (agent-ui-test-aue-error '(:type "slider" :min 0 :max 10 :value 12)))))

;;; agent-ui-slider-tests.el ends here
