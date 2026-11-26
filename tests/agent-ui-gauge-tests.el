;;; agent-ui-gauge-tests.el --- Tests for Agent UI: the gauge component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-gauge.el: the gauge component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defconst agent-ui-test-aue-coverage
  '(:type "gauge" :value 78 :unit "%" :target 80 :label "covered"
    :thresholds ((:at 0 :face "error") (:at 70 :face "warning") (:at 80 :face "success")))
  "Coverage against a target.")

(ert-deftest agent-ui-components/gauge ()
  "A bar: filled in its value's zone's face, the rest of the track in each
zone's, the target a ┃; the value with its unit; the target left out when
narrow, then the label on a line of its own (it was left out)."
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-coverage :width 60)
                 ;; 34 cells: 27 filled, the target's, 6 not.
                 (concat "covered  " (make-string 27 ?█) "┃" (make-string 6 ?░) "  78%  target 80%")))
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-coverage :width 30) "covered  ████████████┃░░░  78%"))
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-coverage :width 14) "covered\n███████┃░  78%"))
  (should (equal (agent-ui-test-aue-draw (plist-put (copy-sequence agent-ui-test-aue-coverage) :label "lines covered") :width 24)
                 "lines covered\n███████████████┃░░░  78%"))
  (should (equal (agent-ui-test-aue-draw (plist-put (copy-sequence agent-ui-test-aue-coverage) :label (make-string 120 ?x))
                                 :width 100)
                 (concat (make-string 99 ?x) "…\n" (make-string 31 ?█) "░┃" (make-string 7 ?░) "  78%  target 80%")))
  ;; Each zone's face: the fill's by the value; the track's by its place.
  (let ((text (agent-ui-render agent-ui-test-aue-coverage (agent-ui-context :width 60))))
    (should (eq (get-text-property 9 'face text) 'agent-ui-warning))
    ;; Past the target: the success zone's track.
    (should (eq (get-text-property (string-search "░" text) 'face text) 'agent-ui-success))
    (should (eq (get-text-property (1- (string-search "  78%" text)) 'face text) 'agent-ui-success)))
  (dolist (case '((30 . agent-ui-error) (75 . agent-ui-warning) (95 . agent-ui-success)))
    (should (eq (get-text-property 9 'face (agent-ui-render (plist-put (copy-sequence agent-ui-test-aue-coverage) :value (car case))
                                                         (agent-ui-context :width 60)))
                (cdr case))))
  ;; Lower is better: a latency.
  (should (equal (agent-ui-test-aue-draw '(:type "gauge" :value 230 :max 1000 :unit "ms") :width 30)
                 "█████░░░░░░░░░░░░░░░░░  230 ms"))
  ;; No zones: the accent's, the track muted.
  (should (eq (get-text-property 0 'face (agent-ui-render '(:type "gauge" :value 50) (agent-ui-context :width 30)))
              'agent-ui-accent))
  ;; Past its range: the bar full, the value as it is.
  (should (string-suffix-p "█  120%" (agent-ui-test-aue-draw '(:type "gauge" :value 120 :unit "%") :width 30))))

(ert-deftest agent-ui-components/gauge-in-the-gui ()
  "An arc: its zones' track, the value's arc in its zone's colour, the
target's tick, the value, the label and target under; too narrow: text."
  (let* ((text (agent-ui-render agent-ui-test-aue-coverage (agent-ui-context :width 40 :graphic t :char-width 8 :line-height 16)))
         (svg (plist-get (cdr (get-text-property 0 'display text)) :data)))
    (should (= 4 (with-temp-buffer (insert svg) (how-many "<path" (point-min) (point-max)))))
    (should (string-match-p (format "stroke=\"%s\"" (regexp-quote (agent-ui-color 'agent-ui-warning))) svg))
    (should (string-match-p "<line" svg))
    (should (string-match-p ">78%</text>" svg))
    (should (string-match-p ">covered &#183; target 80%</text>" svg)))
  (should (equal (substring-no-properties
                  (agent-ui-render agent-ui-test-aue-coverage (agent-ui-context :width 4 :graphic t :char-width 8 :line-height 16)))
                 "cov…\n██┃…")))

(ert-deftest agent-ui-components/gauge-gui-value-fits ()
  "In the GUI the value fits inside the arc, its font smaller if need be,
and the range's ends don't meet (\"123456789.12 requests/s\" needed 441 px
in a 330 px arc, clipped both sides; at 16 columns \"1234 ms\" ran over the
arc)."
  (dolist (component '((:type "gauge" :value 123456789.123 :min -1e9 :max 1e9 :unit "requests/s" :label "throughput")
                     (:type "gauge" :value 1234 :min -1e9 :max 2000 :unit "ms" :label "p95")))
    (dolist (width (number-sequence 16 60 2))
      (let* ((svg (plist-get (cdr (get-text-property
                                   0 'display (agent-ui-render component (agent-ui-context :width width :graphic t
                                                                                        :char-width 11 :line-height 25))))
                             :data))
             (w (progn (string-match "<svg width=\"\\([0-9]+\\)\"" svg) (string-to-number (match-string 1 svg))))
             (texts (let ((out nil) (start 0))
                      (while (string-match "font-size=\"\\([0-9]+\\)\" text-anchor=\"\\([a-z]+\\)\" y=\"[0-9.]+\" x=\"\\([0-9.]+\\)\">\\([^<]*\\)</text>" svg start)
                        (let* ((size (string-to-number (match-string 1 svg))) (x (string-to-number (match-string 3 svg)))
                               (text (match-string 4 svg)) (tw (* 0.6 size (string-width text)))
                               (from (pcase (match-string 2 svg) ("middle" (- x (/ tw 2))) ("start" x) (_ (- x tw)))))
                          (push (list text from (+ from tw)) out))
                        (setq start (match-end 0)))
                      (nreverse out)))
             (value (cl-find-if (lambda (text) (string-match-p " \\(ms\\|requests/s\\)\\'" (car text))) texts))
             (low (cl-find-if (lambda (text) (string-prefix-p "-1000000000" (car text))) texts))
             (high (car (last texts)))
             ;; The arc's inside: its stroke's (0.55 of a line) inner edge.
             (stroke (round (* 0.55 25))) (r (- (/ w 2.0) stroke)))
        (should value)
        (should (>= (nth 1 value) (- (/ w 2.0) (- r (/ stroke 2.0)))))
        (should (<= (nth 2 value) (+ (/ w 2.0) (- r (/ stroke 2.0)))))
        (should (< (nth 2 low) (nth 1 high)))))))

(ert-deftest agent-ui-components/gauge-wrong ()
  (should (string-match-p "value is required" (agent-ui-test-aue-error '(:type "gauge"))))
  (should (string-match-p "min must be below max" (agent-ui-test-aue-error '(:type "gauge" :value 1 :min 5 :max 5))))
  (should (string-match-p "threshold 1 is" (agent-ui-test-aue-error '(:type "gauge" :value 1 :thresholds ((:at 0 :face "loud")))))))

(defun agent-ui-test-aue-gauge-ends (component)
  "COMPONENT, a gauge, drawn for the GUI: its round ends, the points (X . Y)
of its circles, and its arcs' (START . END) points."
  (let* ((dom (agent-ui-test-aue-svg-dom component 40))
         (point (lambda (text) (cons (string-to-number (car text)) (string-to-number (cadr text))))))
    (list (mapcar (lambda (c) (cons (string-to-number (dom-attr c 'cx)) (string-to-number (dom-attr c 'cy))))
                  (dom-by-tag dom 'circle))
          (mapcar (lambda (path)
                    (let ((d (split-string (dom-attr path 'd))))
                      (cons (funcall point (list (nth 1 d) (nth 2 d)))
                            (funcall point (last d 2)))))
                  (dom-by-tag dom 'path))
          dom)))

(ert-deftest agent-ui-components/a-gauge-s-ends-rounded ()
  "A gauge's track: round at its two outer ends only (a dot each, its
colour), its arcs flat where they meet, nothing below the baseline; the
value's arc round at its start, flat at its end, round at the max
\(doom-ht6.36)."
  (pcase-let* ((`(,dots ,arcs ,dom) (agent-ui-test-aue-gauge-ends agent-ui-test-aue-coverage))
               (baseline (apply #'max (mapcar #'cdr (append (mapcar #'car arcs) (mapcar #'cdr arcs)))))
               (radius (string-to-number (dom-attr (car (dom-by-tag dom 'circle)) 'r))))
    (should-not (string-search "stroke-linecap" (agent-ui-test-aue-svg agent-ui-test-aue-coverage 40)))
    ;; The track's two ends and the value's start: 3 dots, at the arc's
    ;; first and last points.
    (should (= (length dots) 3))
    (let ((left (apply #'min (mapcar #'car dots)))
          (right (apply #'max (mapcar #'car dots))))
      (should (= (seq-count (lambda (d) (< (abs (- (car d) left)) 0.01)) dots) 2))
      (should (= (seq-count (lambda (d) (< (abs (- (car d) right)) 0.01)) dots) 1)))
    ;; Each dot no lower than the baseline's line less its radius: nothing
    ;; under the baseline but the half dot reaching it.
    (dolist (dot dots)
      (should (<= (+ (cdr dot) radius) (+ baseline radius 0.5))))
    ;; Zones meet end to end: each arc but the value's starts where one ends.
    (let ((track (butlast arcs)))
      (cl-loop for (a b) on track while b
               do (should (< (abs (- (car (cdr a)) (car (car b)))) 0.01)))))
  ;; At its max: its end round too (4 dots); without zones, the track's two.
  (pcase-let ((`(,dots . ,_) (agent-ui-test-aue-gauge-ends (append '(:value 100) agent-ui-test-aue-coverage))))
    (should (= (length dots) 4)))
  (pcase-let ((`(,dots . ,_) (agent-ui-test-aue-gauge-ends '(:type "gauge" :value 0 :min 0 :max 10))))
    (should (= (length dots) 2))))

;;; agent-ui-gauge-tests.el ends here
