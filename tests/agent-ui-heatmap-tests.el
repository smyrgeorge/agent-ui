;;; agent-ui-heatmap-tests.el --- Tests for Agent UI: the heatmap component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-heatmap.el: the heatmap component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/heatmap-gui-numbers-fit-their-cells ()
  "In the GUI a cell's number is shown only if it fits the cell (\"130.25\"
overlapped the next cell's, \"1234\" spilled out of the last)."
  (let ((svg (agent-ui-test-aue-svg (list :type "heatmap" :rows '("build" "test")
                                  :columns (mapcar (lambda (i) (format "c%d" i)) (number-sequence 1 12))
                                  :values (list (list 12.5 130.25 14 1 2 3 4 5 6 7 22 1234)
                                                (number-sequence 1 12)))
                            50)))
    ;; Cells of 28 px: two digits fit, five and four don't.
    (should (string-match-p ">12</text>" svg))
    (should-not (string-match-p ">130.25</text>" svg))
    (should-not (string-match-p ">1234</text>" svg))))

(ert-deftest agent-ui-components/heatmap-legend-whole ()
  "A legend wider than the width: on more lines, each swatch with its word
(\"█\" was left at a line's end, \"skipped\" alone on the next), and all of
its lines in the GUI too (only the last was kept)."
  (let* ((component '(:type "heatmap" :rows ("lexer" "parser" "checker") :columns ("linux" "macos" "windows")
                    :values (("passed" "passed" "passed") ("passed" "flaky" "passed") ("failed" "passed" "skipped"))))
         (text (agent-ui-test-aue-draw component :width 30))
         ;; Its last lines (above them, the columns' key: "windows" doesn't
         ;; fit its cell, so they're numbered).
         (legend (last (split-string text "\n") 2)))
    (should (equal legend '("█ passed  █ flaky  █ failed" "█ skipped")))
    (let ((gui (substring-no-properties
                (agent-ui-render component (agent-ui-context :width 30 :graphic t :char-width 8 :line-height 16)))))
      (should (string-match-p "█ passed  █ flaky  █ failed\n█ skipped\\'" gui)))))

(ert-deftest agent-ui-components/heatmap-latest-columns-that-fit ()
  "More columns than fit (a month of days): the latest that fit, the earlier
ones said left out, text and GUI (it ran 97 columns wide at 60, the SVG 784
px in 480)."
  (let* ((days (mapcar (lambda (i) (format "d%d" i)) (number-sequence 1 30)))
         (component (list :type "heatmap" :rows '("lexer" "parser") :columns days
                        :values (list (make-list 30 "passed") (append (make-list 29 "passed") '("failed")))))
         (text (agent-ui-test-aue-draw component :width 60)))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 60)))
    (should (string-match-p "… 13 earlier columns left out" text))
    ;; The latest kept: the last day's failure among them (the legend says
    ;; the states shown).
    (should (string-match-p "█ failed" text))
    (let ((svg (agent-ui-test-aue-svg component 60)))
      (string-match "<svg width=\"\\([0-9]+\\)\"" svg)
      (should (<= (string-to-number (match-string 1 svg)) 480)))
    (should (string-match-p "earlier columns left out\n.*█ failed"
                            (substring-no-properties
                             (agent-ui-render component (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))))
    ;; Few columns: all of them, no note.
    (should-not (string-match-p "left out" (agent-ui-test-aue-draw '(:type "heatmap" :rows ("a") :columns ("x" "y") :values (("passed" "failed"))))))))

(ert-deftest agent-ui-components/heatmap-column-labels-whole ()
  "Column labels whole when the width allows, the cells widened for them
\(cut to 6: \"macos…\" with 72 columns free); else cut, or numbered with
a key under the grid when cut they'd read under 5 columns or alike (every
one \"c…\" at 20), text and GUI."
  (let ((component '(:type "heatmap" :rows ("lexer" "parser") :columns ("linux" "macos-long-name" "windows")
                   :values (("passed" "failed" "passed") ("passed" "flaky" "passed")))))
    (should (string-prefix-p "        linux           macos-long-name windows\n"
                             (agent-ui-test-aue-draw component :width 60)))
    (let ((text (agent-ui-test-aue-draw component :width 24)))
      (should (string-prefix-p "        1    2    3\n" text))
      (should (string-search "\n1 linux\n2 macos-long-name\n3 windows\n" text))
      (dolist (line (split-string text "\n"))
        (should (<= (string-width line) 24))))
    ;; The GUI: whole with room, numbered and keyed in a narrow pane.
    (let ((svg (agent-ui-test-aue-svg component 100)))
      (should (string-match-p ">macos-long-name</text>" svg)))
    (let* ((text (agent-ui-render component (agent-ui-context :width 20 :graphic t :char-width 8 :line-height 16)))
           (svg (plist-get (cdr (get-text-property 0 'display text)) :data)))
      (should (string-match-p ">1</text>.*>2</text>.*>3</text>" svg))
      (should-not (string-match-p "&#8230;</text>" (car (split-string svg ">lexer<"))))
      (should (string-search "\n1 linux\n2 macos-long-name\n3 windows\n" (substring-no-properties text))))))

(ert-deftest agent-ui-components/heatmap-gui-row-labels-cut ()
  "In the GUI a long row label is wrapped in its column, its cells taller
(whole on one line it ran through the cells; cut, its rest was nowhere:
doom-cbj)."
  (let ((svg (agent-ui-test-aue-svg '(:type "heatmap" :rows ("test_parser_handles_unicode_identifiers" "lexer")
                              :columns ("linux" "macos" "windows")
                              :values (("passed" "failed" "passed") ("passed" "passed" "flaky")))
                            40)))
    (should-not (string-match-p "&#8230;" svg))
    (should (string-match-p ">test_parser_h</text>.*>andles_unicod</text>.*>e_identifiers</text>" svg))
    ;; Its cells as tall as its three lines; the next row's one.
    (should (string-match-p "<rect width=\"[0-9.]+\" height=\"54\"" svg))
    (should (string-match-p "<rect width=\"[0-9.]+\" height=\"22\"" svg))))

(ert-deftest agent-ui-components/heatmap-numbers ()
  (let ((component '(:type "heatmap" :rows ("a" "b") :columns ("mon" "tue") :values ((1 5) (nil 9)))))
    (should (equal (agent-ui-test-aue-draw component)
                   "   mon tue\na  ███ ███\nb  ··· ███\n1 █████ 9"))
    ;; Coloured on the scale: the lowest faint, the highest strong.
    (let* ((text (agent-ui-render component (agent-ui-context :width 60)))
           (colour (lambda (n) (plist-get (get-text-property (+ (string-search "\na  " text) 4 (* n 4)) 'face text) :foreground))))
      (should (stringp (funcall colour 0)))
      (should-not (equal (funcall colour 0) (funcall colour 1))))
    ;; green-red: low good, high bad.
    (let ((text (agent-ui-render (plist-put (copy-sequence component) :scale "green-red") (agent-ui-context))))
      (should (stringp (plist-get (get-text-property (+ (string-search "\na  " text) 4) 'face text) :foreground))))))

(ert-deftest agent-ui-components/heatmap-states ()
  (let ((text (agent-ui-test-aue-draw '(:type "heatmap" :rows ("lexer") :columns ("linux" "macos") :values (("passed" "failed"))))))
    (should (equal text "       linux macos\nlexer  █████ █████\n█ passed  █ failed")))
  ;; In the GUI: SVG cells, a number's value in it; the legend as text.
  (let* ((text (agent-ui-render '(:type "heatmap" :rows ("a") :columns ("x" "y") :values ((3 7)))
                                (agent-ui-context :width 40 :graphic t)))
         (svg (plist-get (cdr (get-text-property 0 'display text)) :data)))
    (should (= 2 (cl-count ?\n (replace-regexp-in-string "<rect" "\n" svg))))
    (should (string-match-p ">7</text>" svg))
    (should (string-suffix-p "3 █████ 7" (substring-no-properties text)))))

(ert-deftest agent-ui-components/heatmap-wrong ()
  (should (string-match-p "values has 1 rows, for 2" (agent-ui-test-aue-error '(:type "heatmap" :rows ("a" "b") :columns ("x") :values ((1))))))
  (should (string-match-p "row 1 has 2 cells, for 1" (agent-ui-test-aue-error '(:type "heatmap" :rows ("a") :columns ("x") :values ((1 2))))))
  (should (string-match-p "a cell is a number, a word or null" (agent-ui-test-aue-error '(:type "heatmap" :rows ("a") :columns ("x") :values (((1)))))))
  (should (string-match-p "rows must be labels" (agent-ui-test-aue-error '(:type "heatmap" :rows (1) :columns ("x") :values ((1)))))))

;;; agent-ui-heatmap-tests.el ends here
