;;; agent-ui-stats-tests.el --- Tests for Agent UI: the stats component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-stats.el: the stats component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/stats ()
  (let ((component '(:type "stats" :figures ((:label "Coverage" :value 87.1 :unit "%" :change 2.3)
                                          (:label "Tests" :value 412 :change "all pass")
                                          (:label "Build" :value 29 :unit "s" :change -12 :good "down")
                                          (:label "Errors" :value 3 :change 1 :good "down")))))
    (should (equal (agent-ui-test-aue-draw component :width 60)
                   (concat "Coverage       Tests          Build          Errors\n"
                           "87.1% ▲2.3     412 all pass   29 s ▼12       3 ▲1")))
    ;; A rise good (up), a fall good (down), a rise bad (down).
    (should (eq (agent-ui-test-aue-face-at component "▲2.3") 'agent-ui-success))
    (should (eq (agent-ui-test-aue-face-at component "▼12") 'agent-ui-success))
    (should (eq (agent-ui-test-aue-face-at component "▲1") 'agent-ui-error))
    ;; Narrow: wrapped.
    (should (string-match-p "\\`Coverage +Tests\n87.1% ▲2.3 +412 all pass\n\nBuild +Errors\n29 s ▼12 +3 ▲1\\'"
                            (agent-ui-test-aue-draw component :width 30)))
    ;; In the GUI: tiles, an SVG.
    (let ((svg (plist-get (cdr (get-text-property 0 'display (agent-ui-render component (agent-ui-context :width 80 :graphic t)))) :data)))
      (should (= 4 (cl-count ?\n (replace-regexp-in-string "<rect" "\n" svg))))
      (should (string-match-p ">87.1%</text>" svg))))
  (should (equal (agent-ui-test-aue-draw '(:type "stats")) "no figures")))

(ert-deftest agent-ui-components/stats-tiles-fit ()
  "In the GUI, a tile's value and change side by side when they fit; in a
narrow pane, the change on a line of its own under the value (its row a line
taller), both cut to the tile: nothing overlaps, nothing spills out."
  (let* ((component '(:type "stats" :figures ((:label "p50" :value 11.8 :unit "s" :change "max 36.6 s")
                                          (:label "p95" :value 20.1 :unit "s" :change "max 40.2 s")
                                          (:label "Runs" :value 412 :change 3)
                                          (:label "Failed" :value 2 :change -1 :good "down")
                                          (:label "Longest" :value "123456789012345678901234567890" :change "x"))))
         (svg-of (lambda (width)
                   (plist-get (cdr (get-text-property 0 'display
                                                      (agent-ui-render component (agent-ui-context :width width :graphic t
                                                                                                :char-width 8 :line-height 16))))
                              :data))))
    ;; Narrow: 16-column tiles, 3 a row; "11.8 s" and "max 36.6 s" don't fit
    ;; side by side: the change under, at the tile's left, rows 4 lines tall.
    (let ((svg (funcall svg-of 60)))
      (should (string-match-p "<svg[^>]* height=\"136\"" svg))
      (should (string-match-p "<text[^>]* y=\"54.4\" x=\"8\">max 36.6 s</text>" svg))
      (should-not (string-match-p "text-anchor=\"end\"[^>]*>max 36.6 s<" svg))
      ;; A text value wider than its tile even smaller: cut.
      (should (string-match-p "font-size=\"12\"[^>]*>12345678901234&#8230;</text>" svg)))
    ;; Wide: side by side, the change at the tile's right; 3 lines, but
    ;; for a value as wide as its tile (its change under).
    (let ((svg (funcall svg-of 160)))
      (should (string-match-p "<svg[^>]* height=\"64\"" svg))
      (should (string-match-p "text-anchor=\"end\"[^>]*>max 36.6 s</text>" svg)))
    (setq component (list :type "stats" :figures (butlast (plist-get component :figures))))
    (should (string-match-p "<svg[^>]* height=\"48\"" (funcall svg-of 160)))))

(ert-deftest agent-ui-components/stats-tiles-in-one-row-when-they-fit ()
  "Tiles that fit side by side are drawn in one row (the gaps between them
weren't counted: 3 figures wrapped 2 and 1 from 50 to 79 columns)."
  (let ((rows-of (lambda (figures width)
                   (let ((svg (plist-get (cdr (get-text-property
                                               0 'display (agent-ui-render (list :type "stats" :figures figures)
                                                                           (agent-ui-context :width width :graphic t
                                                                                             :char-width 8 :line-height 16))))
                                         :data))
                         (ys nil) (start 0))
                     (while (string-match "<rect [^>]*y=\"\\([0-9.]+\\)\"" svg start)
                       (cl-pushnew (match-string 1 svg) ys :test #'equal)
                       (setq start (match-end 0)))
                     (length ys))))
        (three '((:label "Coverage" :value 87.1 :unit "%" :change 2.3) (:label "Tests" :value 412 :change "all pass")
                 (:label "Build" :value 29 :unit "s" :change -12 :good "down")))
        (four '((:label "a" :value 1) (:label "b" :value 2) (:label "c" :value 3) (:label "d" :value 4))))
    (dolist (width '(55 60 70 78))
      (should (= (funcall rows-of three width) 1)))
    (should (= (funcall rows-of four 80) 1))
    ;; Too narrow: they wrap still.
    (should (= (funcall rows-of three 40) 2))))

(ert-deftest agent-ui-components/stats-tiles-at-its-top ()
  "Its tiles at its image's top (at a canvas's top, its empty top line is
above them: no pad of its own, it's gone); under a title, a line lower,
the image as much taller."
  (should-not (cl-find :pad (agent-ui-type-props (agent-ui-type "stats")) :key #'agent-ui-prop-key))
  (let ((drawn (lambda (title)
                 (let* ((text (agent-ui-render (append (list :type "stats" :figures '((:label "a" :value 1)))
                                                       (and title (list :title title)))
                                               (agent-ui-context :width 60 :graphic t
                                                                 :char-width 8 :line-height 16)))
                        (svg (plist-get (cdr (get-text-property (if title (1+ (string-search "\n" text)) 0)
                                                                'display text))
                                        :data)))
                   (list (and (string-match "<svg [^>]*height=\"\\([0-9.]+\\)\"" svg) (string-to-number (match-string 1 svg)))
                         (and (string-match "<rect [^>]*y=\"\\([0-9.]+\\)\"" svg) (string-to-number (match-string 1 svg))))))))
    (pcase-let ((`(,height ,y) (funcall drawn nil))
                (`(,titled-height ,titled-y) (funcall drawn "Run")))
      (should (= y 0))
      (should (= titled-y 16))
      (should (= titled-height (+ height 16))))))

(ert-deftest agent-ui-components/stats-narrow-pane-and-unit ()
  "Under 16 columns a tile is no wider than the pane (it was 128 px in 96);
a unit that isn't text is refused (it broke the drawing)."
  (let ((svg (plist-get (cdr (get-text-property
                              0 'display (agent-ui-render '(:type "stats" :figures ((:label "Heap" :value 512 :unit "MB")))
                                                          (agent-ui-context :width 12 :graphic t :char-width 8 :line-height 16))))
                        :data)))
    (should (string-match-p "<svg width=\"96\"" svg))
    (should (string-match-p "<rect width=\"96\"" svg)))
  (should (string-match-p "figure 1 has unit 1024: a unit is text"
                          (agent-ui-test-aue-error '(:type "stats" :figures ((:label "Heap" :value 512 :unit 1024)))))))

(ert-deftest agent-ui-components/stats-wrong ()
  (should (string-match-p "figure 1 has no label" (agent-ui-test-aue-error '(:type "stats" :figures ((:value 1))))))
  (should (string-match-p "figure 1 has no value" (agent-ui-test-aue-error '(:type "stats" :figures ((:label "a"))))))
  (should (string-match-p "good is up, down or none" (agent-ui-test-aue-error '(:type "stats" :figures ((:label "a" :value 1 :good "yes"))))))
  (should (string-match-p "has \"trend\"" (agent-ui-test-aue-error '(:type "stats" :figures ((:label "a" :value 1 :trend 2)))))))

(ert-deftest agent-ui-components/stats-face ()
  "A figure's FACE colours its value (a state: running, failed); a face it
doesn't know is refused."
  (let ((text (agent-ui-render '(:type "stats" :figures ((:label "State" :value "✗ failed" :face "error")
                                                        (:label "Time" :value "15m")))
                               (agent-ui-context :width 60))))
    (should (equal (get-text-property (string-search "✗ failed" text) 'face text) '(bold agent-ui-error)))
    (should (eq (get-text-property (string-search "15m" text) 'face text) 'bold)))
  (let ((svg (agent-ui-test-aue-svg '(:type "stats" :figures ((:label "State" :value "failed" :face "error"))) 60)))
    (should (string-search (format "fill=\"%s\"" (agent-ui-chart--color 'agent-ui-error)) svg)))
  (let ((text (agent-ui-render '(:type "stats" :figures ((:label "State" :value "● running" :face "accent")))
                               (agent-ui-context :width 60))))
    (should (equal (get-text-property (string-search "● running" text) 'face text) '(bold agent-ui-accent))))
  ;; Under a title, a line above its tiles (they touched it); without one,
  ;; none.
  (dolist (case '((nil . 0) ("Run" . 16)))
    (let ((svg (agent-ui-test-aue-svg (append (and (car case) (list :title (car case)))
                                      '(:type "stats" :figures ((:label "a" :value 1))))
                              60)))
      (should (string-match "<rect [^>]*y=\"\\([0-9.]+\\)\"" svg))
      (should (= (string-to-number (match-string 1 svg)) (cdr case)))))
  (should (string-match-p "face is plain, accent, success, warning, error or muted"
                          (agent-ui-test-aue-error '(:type "stats" :figures ((:label "a" :value 1 :face "loud")))))))

;;; agent-ui-stats-tests.el ends here
