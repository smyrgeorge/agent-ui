;;; agent-ui-panel-tests.el --- Tests for Agent UI: the panel component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-panel.el: the panel component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

;; doom-1ck
(ert-deftest agent-ui-components/panel-image-sizes-whatever-their-scale ()
  "An image's size in a panel, whatever its :scale: an image component's
create-image puts :scale default in it (a symbol), which failed the whole
panel (\"⚠ Wrong type argument: number-or-marker-p, default\"); a file's
size, from image-size, counts its scale already (a number scaled it twice);
an SVG's data size is scaled by a number."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'imagep) #'always)
            ((symbol-function 'image-size) (lambda (&rest _) '(552.4 . 135))))
    (should (equal (agent-ui-panel--image-size '(image :type png :file "x.png" :scale default)) '(552 . 135)))
    (should (equal (agent-ui-panel--image-size '(image :type png :file "x.png" :scale 2)) '(552 . 135)))
    (should (equal (agent-ui-panel--image-size '(image :type svg :data "<svg width=\"40\" height=\"16\"/>" :scale default))
                   '(552 . 135))))
  (should (equal (agent-ui-panel--image-size '(image :type svg :data "<svg width=\"40\" height=\"16\"/>" :scale 2))
                 '(80 . 32)))
  ;; Not in a graphic frame: an SVG's own size, a file's unknown.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
    (should (equal (agent-ui-panel--image-size '(image :type svg :data "<svg width=\"40\" height=\"16\"/>" :scale default))
                   '(40 . 16)))
    (should-not (agent-ui-panel--image-size '(image :type png :file "x.png" :scale default))))
  ;; An image component in a panel, as the canvas has it: drawn, no error.
  (let* ((file (expand-file-name "tests/fixtures/image.png" agent-ui-test-root))
         (text (cl-letf (((symbol-function 'image-size) (lambda (&rest _) '(300 . 200))))
                 (agent-ui-render (list :type "panel" :layout "column"
                                        :children (list (list :type "image" :id "a" :file file)
                                                        (list :type "text" :id "b" :text "under it")))
                                  (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))))
    (should-not (string-search "⚠" (substring-no-properties text)))
    (should (string-search "under it" (substring-no-properties text)))))

(ert-deftest agent-ui-components/panel-past-the-cap-its-frame-whole ()
  "A panel past `agent-ui-max-chars' (doom-coj): each child cut, inside the
frame, the children after it shown, the bottom border kept."
  (let* ((agent-ui-max-chars 2000)
         (row (make-string 60 ?a))
         (component `(:type "panel" :id "cap"
                    :children ((:type "table" :id "big" :columns ("Row" "Text")
                                      :rows ,(mapcar (lambda (i) (list (format "row %d" i) row)) (number-sequence 1 180)))
                               (:type "text" :id "after" :text "The text after the table"))))
         (lines (split-string (agent-ui-test-aue-draw component) "\n")))
    (should (string-prefix-p "╭" (car lines)))
    (should (string-prefix-p "╰" (car (last lines))))
    ;; Each line inside the frame (no note outside it).
    (dolist (line (butlast (cdr lines)))
      (should (string-prefix-p "│" line))
      (should (string-suffix-p "│" line)))
    ;; The table's own cut, inside it; the child after it shown.
    (should (seq-some (lambda (line) (string-match-p "│ … [0-9]+ characters more +│" line)) lines))
    (should (seq-some (lambda (line) (string-search "The text after the table" line)) lines))))

(ert-deftest agent-ui-components/panel-its-own-limit ()
  "A panel's lines past `agent-ui-panel-max-chars': cut, a line inside its
frame saying how many more, its bottom border kept; nested ones too."
  (let* ((agent-ui-panel-max-chars 600)
         (child (lambda (id) `(:type "text" :id ,id :text ,(mapconcat (lambda (i) (format "line %d" i))
                                                                       (number-sequence 1 30) "\n"))))
         (component `(:type "panel" :id "outer"
                    :children (,(funcall child "a")
                               (:type "panel" :id "inner" :children (,(funcall child "b") ,(funcall child "c"))))))
         (text (agent-ui-test-aue-draw component))
         (lines (split-string text "\n")))
    ;; Its lines' characters within the limit (its frame's sides added):
    ;; not the 90 lines' 5,000 of them.
    (should (< (length text) (* 2 600)))
    (should (string-prefix-p "╰" (car (last lines))))
    (should (string-match-p "│ … [0-9]+ lines more +│" (car (last lines 2))))
    (should (= (length (car (last lines 2))) (length (car lines))))))

(ert-deftest agent-ui-components/panel-row-and-column ()
  (let ((row '(:type "panel" :layout "row" :min-width 8
               :children ((:type "text" :title "A" :text "one") (:type "text" :title "B" :text "two\nlines")))))
    (should (equal (agent-ui-test-aue-draw row :width 30)
                   (concat "╭────────────────────────────╮\n"
                           "│ A           │ B            │\n"
                           "│ one         │ two          │\n"
                           "│             │ lines        │\n"
                           "╰────────────────────────────╯")))
    ;; Weights: shares of the width.
    (should (string-prefix-p "╭────────────────────────────╮\n│ A       │ B"
                             (agent-ui-test-aue-draw (plist-put (plist-put (copy-sequence row) :weights '(1 2)) :min-width 4) :width 30)))
    ;; Too narrow for its children: stacked.
    (should (equal (agent-ui-test-aue-draw (plist-put (copy-sequence row) :min-width 20) :width 30)
                   (concat "╭────────────────────────────╮\n"
                           "│ A                          │\n│ one                        │\n"
                           "│                            │\n"
                           "│ B                          │\n│ two                        │\n│ lines                      │\n"
                           "╰────────────────────────────╯"))))
  ;; A column without a border.
  (should (equal (agent-ui-test-aue-draw '(:type "panel" :border :false
                                   :children ((:type "text" :text "x") (:type "text" :text "y"))))
                 "x\n\ny")))

;; doom-ht6.156
(ert-deftest agent-ui-components/panel-its-title-in-its-border ()
  "A panel with a border has its title in its top border, not over it, in
the title's face, cut with … when narrow, its newlines spaces; each nested
panel its own, its children not given it.  No title, or a blank one: a
plain border.  Without a border, or no room for a character of it: over
it.  A caption still over it.  Left out (CTX's :untitled, a canvas's lone
panel): a plain border, a nested panel's its own."
  (let* ((panel (lambda (title &rest props)
                  (append (list :type "panel"
                                :children '((:type "panel" :title "Inner" :children ((:type "text" :text "x")))))
                          (and title (list :title title))
                          props)))
         (drawn (lambda (component width &optional ctx)
                  (agent-ui-render component (append ctx (agent-ui-context :width width)))))
         (draw (lambda (&rest args) (substring-no-properties (apply drawn args)))))
    (should (equal (funcall draw (funcall panel "Alerts") 20)
                   (concat "╭─ Alerts ─────────╮\n"
                           "│ ╭─ Inner ──────╮ │\n"
                           "│ │ x            │ │\n"
                           "│ ╰──────────────╯ │\n"
                           "╰──────────────────╯")))
    (let ((text (funcall drawn (funcall panel "Alerts") 20)))
      (should (eq (get-text-property (string-search "Alerts" text) 'face text) 'agent-ui-title))
      (should (eq (get-text-property 0 'face text) 'agent-ui-muted)))
    ;; Narrow: cut with …, the border as wide; its newlines spaces.
    (should (string-prefix-p "╭─ IC aler… ─╮\n" (funcall draw (funcall panel "IC alerts: Datadog") 14)))
    (should (string-prefix-p "╭─ IC alerts ─╮\n" (funcall draw (funcall panel "IC\nalerts") 15)))
    ;; No title, or a blank one: plain.
    (should (string-prefix-p "╭──────────────────╮\n│ ╭─ Inner" (funcall draw (funcall panel nil) 20)))
    (should (string-prefix-p "╭──────────────────╮\n│ ╭─ Inner" (funcall draw (funcall panel "  ") 20)))
    ;; No room for a character of it: over it.
    (should (string-prefix-p "Alerts\n╭────╮\n" (funcall draw (funcall panel "Alerts") 6)))
    ;; Without a border: over it, a nested panel's in its own.
    (should (string-prefix-p "Alerts\n╭─ Inner" (funcall draw (funcall panel "Alerts" :border :false) 20)))
    ;; A caption: over it still.
    (should (string-prefix-p "2 firing\n╭─ Alerts ─"
                             (funcall draw (funcall panel "Alerts" :caption "2 firing") 20)))
    ;; Left out: plain, a nested panel's its own.
    (should (string-prefix-p "╭──────────────────╮\n│ ╭─ Inner"
                             (funcall draw (funcall panel "Alerts") 20 '(:untitled t))))))

(ert-deftest agent-ui-components/panel-nested-and-live ()
  ;; A panel in a panel; an animated child makes it animated.
  (let ((component '(:type "panel" :layout "row"
                   :children ((:type "panel" :border :false :children ((:type "text" :text "in")))
                              (:type "progress" :title "Wait")))))
    (should (string-match-p "│ in +│ Wait" (agent-ui-test-aue-draw component :width 60)))
    (should (agent-ui-animated-p component)))
  ;; A child's buttons get its id (they change it).
  (let (seen)
    (cl-letf (((symbol-function 'agent-ui-ask-change) (lambda (ctx _patch) (setq seen (plist-get ctx :id)))))
      (let ((text (agent-ui-render '(:type "panel" :children ((:id "q" :type "choice" :question "?" :options ("a"))))
                                   (agent-ui-context :width 40 :id "outer"))))
        (funcall (get-text-property (string-search "( ) a" text) 'agent-ui-action text))
        (should (equal seen "q"))))))

(ert-deftest agent-ui-components/panel-wrong ()
  (should (string-match-p "child 2 (text): text: text is required"
                          (agent-ui-test-aue-error '(:type "panel" :children ((:type "text" :text "x") (:type "text"))))))
  (should (string-match-p "child 1 must be a component" (agent-ui-test-aue-error '(:type "panel" :children ("x")))))
  (should (string-match-p "two children are \"a\""
                          (agent-ui-test-aue-error '(:type "panel" :children ((:id "a" :type "text" :text "x")
                                                                      (:type "panel" :children ((:id "a" :type "text" :text "y"))))))))
  (should (string-match-p "weights are a positive number for each child"
                          (agent-ui-test-aue-error '(:type "panel" :weights (1) :children ((:type "text" :text "x") (:type "text" :text "y"))))))
  (should (string-match-p "nest 2 deep at most"
                          (let ((agent-ui-panel-depth 2))
                            (agent-ui-test-aue-error '(:type "panel" :children ((:type "panel" :children ((:type "panel" :children ()))))))))))

(ert-deftest agent-ui-components/panel-empty ()
  "No children (shown empty, appended to later): its placeholder, row or
column, bordered or not (it broke working out widths for none)."
  (dolist (component '((:type "panel" :layout "row") (:type "panel" :children ())
                     (:type "panel" :layout "row" :border :false)))
    (let ((text (agent-ui-test-aue-draw component :width 30)))
      (should-not (string-search "⚠" text))
      (should (string-search "no components" text))))
  ;; Bordered: its sides in line with its frame (the text wasn't padded).
  (dolist (width '(100 60 24))
    (let ((lines (split-string (agent-ui-test-aue-draw '(:type "panel" :border t :children ()) :width width) "\n")))
      (should (= (length lines) 3))
      (dolist (line lines)
        (should (= (string-width line) width)))
      (should (string-match-p "\\`│ no components +│\\'" (nth 1 lines))))))

(ert-deftest agent-ui-components/panel-never-under-a-column ()
  "However narrow: no child laid out at 0 columns or less (they hung, or
broke), the border left out where it can't fit, every line within the width."
  (let ((calls 0)
        (truncate (symbol-function 'truncate-string-to-width))
        (row '(:type "panel" :layout "row" :min-width 0
               :children ((:type "text" :text "Build ok") (:type "text" :text "Tests ok")
                          (:type "text" :text "Lint ok"))))
        (nested '(:type "panel" :children ((:type "panel" :children ((:type "panel" :children ((:type "text" :text "hi")))))))))
    (cl-letf (((symbol-function 'truncate-string-to-width)
               (lambda (&rest args)
                 (when (> (cl-incf calls) 100000) (error "a loop"))
                 (apply truncate args))))
      (dolist (width (number-sequence 1 20))
        (dolist (component (list row nested))
          (let ((text (agent-ui-test-aue-draw component :width width)))
            (should-not (string-search "⚠" text))
            (dolist (line (split-string text "\n"))
              (should (<= (string-width line) (max width 1))))))))
    ;; Wide enough: its border, as before.
    (should (string-prefix-p "╭" (agent-ui-test-aue-draw row :width 30)))))

(ert-deftest agent-ui-components/panel-row-with-a-chart-in-the-gui ()
  (let* ((component '(:type "panel" :layout "row" :min-width 8
                    :children ((:type "chart" :title "p95" :values (1 3 2)) (:type "text" :title "Note" :text "fine"))))
         (gui (agent-ui-render component (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
         (lines (split-string gui "\n")))
    ;; Its border's top and bottom as text; the row between, one SVG.
    (should (= (length lines) 3))
    (let* ((image (get-text-property 0 'display (nth 1 lines)))
           (svg (plist-get (cdr image) :data)))
      (should (eq (car image) 'image))
      (should (string-match-p "\\`<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"480\"" svg))
      ;; Each child nested: the chart's own SVG (a polyline), the text's.
      (should (string-match-p "<svg x=\"8\" y=\"0\"" svg))
      (should (string-match-p "<polyline" svg))
      (should (string-match-p ">fine</text>" svg))))
  ;; Without an image: text, its children's buttons kept.
  (let ((gui (agent-ui-render '(:type "panel" :layout "row" :min-width 8
                                :children ((:type "text" :text "a") (:type "choice" :question "?" :options ("x"))))
                              (agent-ui-context :width 60 :graphic t))))
    (should-not (text-property-not-all 0 (length gui) 'display nil gui))
    (should (text-property-any 0 (length gui) 'keymap agent-ui-button-map gui)))
  ;; In a terminal: text, as before.
  (should-not (string-match-p "<svg" (agent-ui-test-aue-draw '(:type "panel" :layout "row" :min-width 8
                                                       :children ((:type "chart" :values (1 2)) (:type "text" :text "x")))))))

(ert-deftest agent-ui-components/panel-row-with-chips-stays-text ()
  "A GUI row whose images are a line high at most (a tags component's chips):
text, its children's marks and buttons there to press, each line its
width's pixels (drawn as one SVG, none could be pressed); one taller (a
chart): one SVG still."
  (let* ((ctx (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16))
         (gui (agent-ui-render '(:type "panel" :layout "row" :min-width 8
                                 :children ((:type "files" :files ("a.el" "b.el") :select (:question "Which?" :multiple t))
                                            (:type "tags" :tags ("bug" "docs") :select (:question "Labels?" :multiple t))))
                               ctx))
         (lines (split-string gui "\n"))
         (chips (seq-find (lambda (line) (string-search "[bug] [docs]" line)) lines)))
    ;; Lines of text, the chips images among them.
    (should (> (length lines) 3))
    (should chips)
    (should (eq (car (get-text-property (string-search "[bug]" chips) 'display chips)) 'image))
    (should (string-search "[ ]" gui))
    ;; Pressable: the files' marks, the chips.
    (should (get-text-property (string-search "[ ]" gui) 'keymap gui))
    (should (get-text-property (string-search "[bug]" chips) 'keymap chips))
    ;; Each line as wide as the panel, to the pixel: its borders in line.
    (dolist (line lines)
      (should (= (agent-ui-panel--pixels line 8) (* 60 8)))))
  (let ((ctx (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16))
        (chip (lambda (h) (propertize "[bug]" 'display (list 'image :type 'svg :scale 1
                                                              :data (format "<svg width=\"40\" height=\"%d\"/>" h))))))
    ;; A line high, as wide as its columns: inline.
    (should (agent-ui-panel--inline-p (concat "a " (funcall chip 16) "\nb") 10 ctx))
    (should (agent-ui-panel--inline-p (concat "x" (propertize " " 'display '(space :width (3)))) 10 ctx))
    ;; A line of text wider than its room: inline still (cut to it).
    (should (agent-ui-panel--inline-p (concat (funcall chip 16) "\nabcdefghijklmnop") 10 ctx))
    ;; Taller, wider than its room, no images' sizes known: not.
    (should-not (agent-ui-panel--inline-p (funcall chip 17) 10 ctx))
    (should-not (agent-ui-panel--inline-p (concat "abcdefgh " (funcall chip 16)) 10 ctx))
    (should-not (agent-ui-panel--inline-p "x" 10 (agent-ui-context :width 60 :graphic t :char-width nil)))
    ;; A slice of a taller image: not (a row of one, as before).
    (should-not (agent-ui-panel--inline-p (propertize "pic" 'display (list '(slice 0 0 20 16) '(image :type svg :data "<svg/>")))
                                          10 ctx))))

(ert-deftest agent-ui-components/panel-a-childs-files-by-full-names ()
  "A panel's children's files, and their :here folders, by their full names
in the agent's directory, as its own: a redraw elsewhere finds them
\(doom-ht6.46)."
  (agent-ui-test-aue-canvas
    (let* ((dir (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "agent-dir-") t)))
           (agent-ui-file-directory dir))
      (agent-ui-show '(:id "p" :type "panel"
                       :children ((:id "c" :type "code" :file "notes.txt")
                                  (:id "f" :type "files" :files ("a.el")))))
      (should (equal (plist-get (agent-ui-get "c") :file) (expand-file-name "notes.txt" dir)))
      (should (equal (plist-get (agent-ui-get "f") :dir) dir)))))

(ert-deftest agent-ui-components/panel-a-child-replaced-its-ids-checked ()
  "A panel's child replaced by one whose own children have an id taken:
refused, the canvas as it was (doom-ht6.58)."
  (agent-ui-test-aue-canvas
    (agent-ui-show '(:id "x" :type "text" :text "top"))
    (agent-ui-show '(:id "p" :type "panel" :children ((:id "c" :type "text" :text "child"))))
    (should (string-match-p "the id \"x\" is taken"
                            (agent-ui-error-message
                             (should-error (agent-ui-show '(:id "c" :type "panel" :children ((:id "x" :type "text" :text "again"))))
                                           :type 'agent-ui-error))))
    (should (equal (plist-get (agent-ui-get "c") :text) "child"))
    (should (equal (plist-get (agent-ui-get "x") :text) "top"))))

(ert-deftest agent-ui-components/panel-a-child-without-an-id ()
  "A panel's child without an id: given one by its place (PANEL.N, its own
children the same, not one taken), so its buttons and keys change it, not
its panel; kept as the panel changes (doom-ht6.51)."
  (agent-ui-test-aue-canvas
    (agent-ui-show '(:id "p" :type "panel"
                     :children ((:type "table" :columns ("A") :rows (("x") ("y")))
                                (:id "p.2" :type "text" :text "taken")
                                (:type "text" :text "third")
                                (:type "panel" :children ((:type "text" :text "deep"))))))
    (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components))
                   '("first" "p" "p.1" "p.2" "p.3" "p.4" "p.4.1")))
    ;; Its table sorted: the child changed, the panel accepting it.
    (agent-ui-update "p.1" '(:sort "A" :descending t))
    (should (eq (plist-get (agent-ui-get "p.1") :descending) t))
    ;; The panel changed: its children's ids as they were.
    (agent-ui-update "p" '(:title "P"))
    (should (equal (plist-get (agent-ui-get "p.3") :text) "third"))
    ;; Shown with no id at all: its children named after the id made.
    (let ((id (agent-ui-show '(:type "panel" :children ((:type "text" :text "x"))))))
      (should (equal (plist-get (car (plist-get (agent-ui-get id) :children)) :id) (concat id ".1"))))))

(ert-deftest agent-ui-components/panel-borderless-keeps-its-images ()
  "Without a border, in the GUI: a row drawn as one SVG, and an image line in
a column, kept (trimming the lines' spaces deleted them: an image is a
space showing it); plain lines still trimmed."
  (let* ((ctx (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16))
         (row (agent-ui-render '(:type "panel" :layout "row" :border :false
                                 :children ((:type "chart" :title "Latency" :values (1 3 2 5 4))
                                            (:type "text" :text "hello")))
                               ctx))
         (column (agent-ui-render '(:type "panel" :border :false
                                    :children ((:type "chart" :values (1 3 2)) (:type "text" :text "hi")))
                                  ctx)))
    (should (agent-ui-panel--image-p row))
    (should (agent-ui-panel--image-p column))
    (should (string-match-p "^hi$" (substring-no-properties column))))
  (should (equal (agent-ui-panel--trim-right "ab   ") "ab"))
  (let ((image (concat "x " (propertize " " 'display '(space :width (3))))))
    (should (equal (agent-ui-panel--trim-right image) image))))

(ert-deftest agent-ui-components/panel-gui-row-children-fit-their-columns ()
  "A GUI row drawn as one SVG: each child's text fitted to its column (a long
title ran across the line between them into the next child)."
  (let* ((text (agent-ui-render '(:type "panel" :layout "row"
                                  :children ((:type "table" :title "Slowest tests in the parser module this week"
                                                    :columns ("Test" "Result") :rows (("lexer" "passed") ("parser" "failed")))
                                             (:type "chart" :title "Latency" :values (1 3 2 5 4))))
                                (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
         ;; The row's image: under the border's top line.
         (svg (plist-get (cdr (get-text-property (text-property-not-all 0 (length text) 'display nil text)
                                                 'display text))
                         :data))
         (nested (progn (string-match "<svg x=\"[0-9]+\" y=\"0\" [^>]*width=\"\\([0-9]+\\)\"" svg)
                        (string-to-number (match-string 1 svg)))))
    ;; The table's column: 26 of 60 (border and separator out), and the
    ;; snapshot's padding (a column each side).
    (should (<= nested (* 8 (+ 26 2))))
    ;; The title wrapped in its column (a word a <text>), every word of it:
    ;; it was cut, its end gone (doom-ny5).
    (should-not (string-match-p "…\\|&#8230;" svg))
    (should (string-match-p ">week<" svg))
    (should (string-match-p "y=\"20\"[^>]*>Slowest<" svg))
    (should (string-match-p "y=\"36\"[^>]*>parser<" svg))))

(ert-deftest agent-ui-components/panel-its-border-beside-an-image ()
  "An image in a bordered panel, in the GUI: both sides kept for a
fractional width (a formula's: counted as Emacs shows it, whole). One
taller than a line: cut into slices a line high each, the image padded to
whole lines (itself in their middle), the sides the font's │ on every line
\(beside a tall line they had gaps, drawn as images they didn't align). One
that can't be cut (scaled): sides as tall, drawn."
  (let ((agent-ui--types (copy-hash-table agent-ui--types)))
    (agent-ui-define picture "An SVG, W by H." :props ((w number "Width") (h number "Height") (scale number "Scale"))
      :text (lambda (props _ctx)
              (concat "  " (propertize "pic" 'display (list 'image :type 'svg :scale (or (plist-get props :scale) 1) :ascent 'center
                                                            :data (format "<svg width=\"%s\" height=\"%s\"/>"
                                                                          (plist-get props :w) (plist-get props :h)))))))
    (let* ((ctx (agent-ui-context :width 30 :graphic t :char-width 8 :line-height 16))
           (lines (lambda (w h &optional scale)
                    (cdr (butlast (split-string (agent-ui-render (list :type "panel" :children (list (list :type "picture" :w w :h h :scale scale)))
                                                                 ctx)
                                                "\n")))))
           (display (lambda (text) (get-text-property (string-search "pic" text) 'display text))))
      (should (equal (agent-ui-panel--image-size '(image :type svg :scale 1 :data "<svg width=\"102.87\" height=\"16\"/>"))
                     '(102 . 16)))
      ;; A line high: one line, the font's sides; 102.87 counted 102.
      (let ((flat (funcall lines 102.87 16)))
        (should (= (length flat) 1))
        (should (string-prefix-p "│   pic" (substring-no-properties (car flat))))
        (should (string-suffix-p " │" (substring-no-properties (car flat))))
        (should (= (agent-ui-panel--pixels (car flat) 8) (* 30 8))))
      ;; 39 high: 3 lines of 16 (48: 4 above and 5 below), the sides text.
      (let ((tall (funcall lines 102 39)))
        (should (= (length tall) 3))
        (dolist (line tall)
          (should (string-prefix-p "│ " (substring-no-properties line)))
          (should (string-suffix-p " │" (substring-no-properties line)))
          (should-not (get-text-property 0 'display line))
          (should (= (agent-ui-panel--pixels line 8) (* 30 8))))
        (should (equal (mapcar (lambda (line) (car (funcall display line))) tall)
                       '((slice 0 0 102 16) (slice 0 16 102 16) (slice 0 32 102 16))))
        (let ((padded (cadr (funcall display (car tall)))))
          (should-not (plist-member (cdr padded) :background))
          (should (string-match-p "\\`<svg [^>]*width=\"102\" height=\"48\"><g transform=\"translate(0 4)\"><svg width=\"102\" height=\"39\"/>"
                                  (plist-get (cdr padded) :data))))
        ;; Its indent on the first line, blanks on the others.
        (should (string-prefix-p "│   " (substring-no-properties (cadr tall)))))
      ;; Scaled, it isn't cut: its sides drawn as tall.
      (let* ((tall (funcall lines 80 78 0.5)))
        (should (= (length tall) 1))
        (should (string-match-p "<line x1=\"4.0\" x2=\"4.0\" y1=\"0\" y2=\"39\""
                                (plist-get (cdr (get-text-property 0 'display (car tall))) :data))))))
  ;; A snapshot draws a slice: the SVG in a box of its size, moved up to it.
  (let* ((image (agent-ui-image (create-image "<svg width=\"20\" height=\"32\"/>" 'svg t)))
         (line (propertize "pic" 'display (list '(slice 0 16 20 16) image)))
         (svg (agent-ui-snapshot-svg line (agent-ui-context :width 10 :graphic t :char-width 8 :line-height 16))))
    (should (string-match-p "<svg x=\"8\" y=\"8\" width=\"20\" height=\"16\"><g transform=\"translate(0 -16)\"><svg width=\"20\" height=\"32\"/></g></svg>" svg))))

(ert-deftest agent-ui-components/panel-an-image-line-in-its-border ()
  ;; An image's line padded to the panel's width: a filler to its last
  ;; column's end, spaces, the border's right side.
  (let* ((image (lambda (w) (propertize "img" 'display (list 'image :type 'svg :scale 1
                                                             :data (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"16\"/>" w)))))
         (ctx (agent-ui-context :width 20 :graphic t :char-width 8 :line-height 16))
         (lines (agent-ui-panel--lines (concat (funcall image 45) "\nab") 10 ctx))
         (line (car lines)))
    ;; 45 px: 6 columns, 3 px of filler, 4 spaces.
    (should (equal (substring-no-properties line) "img     "))
    (should (equal (get-text-property 3 'display line) '(space :width (3))))
    (should (= (agent-ui-panel--pixels line 8) 80))
    (should (equal (cadr lines) "ab        "))
    ;; Wider than its room: as it is.
    (should (equal (substring-no-properties (car (agent-ui-panel--lines (funcall image 200) 10 ctx))) "img"))
    ;; A fraction of a pixel (a formula's 102.87): as Emacs shows it (38),
    ;; padded to its column's end exactly.
    (let ((line (car (agent-ui-panel--lines (propertize "img" 'display (list 'image :type 'svg :scale 1 :data "<svg width=\"38.87\" height=\"16\"/>"))
                                            10 ctx))))
      (should (= (agent-ui-panel--pixels line 8) 80))
      (should (equal (get-text-property 3 'display line) '(space :width (2))))))
  ;; A chart in a column panel, in the GUI: both sides of the border.
  (let* ((gui (agent-ui-render '(:type "panel" :children ((:type "chart" :values (1 3 2))))
                               (agent-ui-context :width 30 :graphic t :char-width 8 :line-height 16)))
         (chart-line (seq-find #'agent-ui-panel--image-p (split-string gui "\n"))))
    (should (string-prefix-p "│ " (substring-no-properties chart-line)))
    (should (string-suffix-p " │" (substring-no-properties chart-line)))
    (should (= (agent-ui-panel--pixels chart-line 8) (* 30 8)))))

(ert-deftest agent-ui-components/panel-a-frame-draws-only-its-animated-children ()
  "A panel animated by a child: its frames draw that child again, the others
\(code, a table) as last drawn, not anew; the panel drawn as it would be
whole (doom-ht6.113)."
  (agent-ui-test-aue-canvas
    (agent-ui-show '(:id "p" :type "panel"
                     :children ((:id "bar" :type "progress" :title "Build")
                                (:id "src" :type "code" :code "int x = 1;" :language "c")
                                (:id "t" :type "table" :columns ("A" "B") :rows (("1" "2"))))))
    (with-current-buffer canvas (agent-ui--flush))
    (save-window-excursion
      (switch-to-buffer canvas)
      (let ((drawn nil))
        (cl-letf* ((render (symbol-function 'agent-ui-render))
                   ((symbol-function 'agent-ui-render)
                    (lambda (component ctx)
                      (push (plist-get component :type) drawn)
                      (funcall render component ctx))))
          (dotimes (_ 5) (agent-ui--frame canvas)))
        (should (= (seq-count (lambda (type) (equal type "progress")) drawn) 5))
        (should (<= (seq-count (lambda (type) (equal type "code")) drawn) 1))
        (should (<= (seq-count (lambda (type) (equal type "table")) drawn) 1)))
      (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "p")
                                                 (agent-ui-test-aue--drawn-whole "p")))
      ;; Changed: its children drawn anew.
      (agent-ui-update "p" '(:children ((:id "bar" :type "progress" :title "Build")
                                        (:id "src" :type "code" :code "int y = 2;" :language "c"))))
      (agent-ui--flush)
      (agent-ui--frame canvas)
      (should (string-search "int y = 2;" (substring-no-properties (agent-ui-test-aue--region "p"))))
      (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "p")
                                                 (agent-ui-test-aue--drawn-whole "p"))))))

;;; agent-ui-panel-tests.el ends here
