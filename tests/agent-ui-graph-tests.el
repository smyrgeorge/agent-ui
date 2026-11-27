;;; agent-ui-graph-tests.el --- Tests for Agent UI: the graph component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-graph.el: the graph component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defun agent-ui-test-aue-crossings (svg)
  "The edges of graph SVG (paths with an arrow) crossing a box (a rect): a
list of (D . BOX), D the path's, BOX (X Y W H). Their points sampled along
each line and curve; a box's own edge (2 px) not counted."
  (let ((boxes nil) (crossings nil) (start 0))
    (while (string-match "<rect width=\"\\([0-9.]+\\)\" height=\"\\([0-9.]+\\)\" x=\"\\([0-9.-]+\\)\" y=\"\\([0-9.-]+\\)\"" svg start)
      (push (mapcar #'string-to-number (list (match-string 3 svg) (match-string 4 svg) (match-string 1 svg) (match-string 2 svg)))
            boxes)
      (setq start (match-end 0)))
    (setq start 0)
    (while (string-match "<path d=\"\\([^\"]+\\)\"[^>]*marker-end" svg start)
      ;; Where it ended, first: split-string below changes the match data.
      (let* ((end (match-end 0))
             (d (match-string 1 svg))
             (numbers (mapcar #'string-to-number (split-string d "[^-0-9.]+" t)))
             (points (cl-loop for (x y) on numbers by #'cddr collect (cons x y)))
             (samples nil))
        (setq start end)
        (if (string-search "C" d)
            ;; A cubic: M p0 C p1 p2 p3.
            (pcase-let ((`(,p0 ,p1 ,p2 ,p3) points))
              (dotimes (i 41)
                (let* ((u (/ i 40.0)) (v (- 1 u))
                       (f (lambda (a b c e) (+ (* v v v a) (* 3 v v u b) (* 3 v u u c) (* u u u e)))))
                  (push (cons (funcall f (car p0) (car p1) (car p2) (car p3))
                              (funcall f (cdr p0) (cdr p1) (cdr p2) (cdr p3)))
                        samples))))
          ;; Lines: M p0 L p1 L p2 ...
          (cl-loop for (a b) on points while b
                   do (dotimes (i 31)
                        (let ((u (/ i 30.0)))
                          (push (cons (+ (car a) (* u (- (car b) (car a)))) (+ (cdr a) (* u (- (cdr b) (cdr a)))))
                                samples)))))
        (dolist (box boxes)
          (pcase-let ((`(,x ,y ,w ,h) box))
            (when (seq-some (lambda (p) (and (< (+ x 2) (car p) (- (+ x w) 2)) (< (+ y 2) (cdr p) (- (+ y h) 2))))
                            samples)
              (push (cons d box) crossings))))))
    crossings))

(ert-deftest agent-ui-components/graph-a-long-chain ()
  "A chain of 500 nodes (as many as it takes): laid out, a layer each,
drawn as text, past no nesting limit (doom-ht6.70)."
  (let* ((n 500)
         (edges (cl-loop for i below (1- n) collect (list :from (format "n%d" i) :to (format "n%d" (1+ i)))))
         (component (list :type "graph" :edges edges))
         (max-lisp-eval-depth 1600))
    (should (= (length (agent-ui-graph-layout (plist-get (agent-ui-check "graph" component) :nodes) edges)) n))
    (should-not (string-search "max-lisp-eval-depth" (agent-ui-test-aue-draw component)))))

(ert-deftest agent-ui-components/graph-loops-and-cycles-shown ()
  "A self-loop drawn out into the corridor after its box; an edge going back
(a cycle) routed round through the corridors and a lane, back to the first
layer too: shown, crossing no box (they were lines under the boxes)."
  (dolist (component '((:type "graph" :nodes ("alpha" "beta") :edges (("alpha" "alpha") ("alpha" "beta")))
                     (:type "graph" :nodes ("alpha" "beta") :edges (("alpha" "beta") ("beta" "alpha")))
                     (:type "graph" :nodes ("a" "b" "c" "d") :edges (("a" "b") ("a" "c") ("b" "d") ("c" "d") ("d" "b")))))
    (let ((svg (agent-ui-test-aue-svg component 120)))
      (should-not (agent-ui-test-aue-crossings svg))))
  ;; The self-loop: past its box's end, not within it.
  (let* ((svg (agent-ui-test-aue-svg '(:type "graph" :nodes ("alpha" "beta") :edges (("alpha" "alpha") ("alpha" "beta"))) 120))
         (loop (progn (string-match "<path d=\"\\(M[^\"]*C[^\"]*\\)\"[^>]*marker-end" svg) (match-string 1 svg)))
         (xs (cl-loop for (x _y) on (mapcar #'string-to-number (split-string loop "[^-0-9.]+" t)) by #'cddr collect x)))
    (should (> (apply #'max xs) (+ (car xs) 10))))
  ;; Back to the first layer: it ends at that box's start, from a corridor before it.
  (let ((svg (agent-ui-test-aue-svg '(:type "graph" :nodes ("alpha" "beta") :edges (("alpha" "beta") ("beta" "alpha"))) 120)))
    (should (string-match-p "<path d=\"M[^\"]* L[^\"]* L[^\"]* L[^\"]* L[^\"]* L[^\"]*\"" svg))))

(ert-deftest agent-ui-components/graph-routed-labels-clear-of-boxes ()
  "A routed edge's label on its lane, a loop's beside it: neither on a box
(a skip edge's label sat on the node it skips, under its own label)."
  (dolist (component '((:type "graph" :nodes ("a" "b" "c") :edges (("a" "b") ("b" "c") (:from "a" :to "c" :label "skip")))
                     (:type "graph" :nodes ("a" "b") :edges (("a" "b") (:from "b" :to "a" :label "back")))
                     (:type "graph" :nodes ("a" "b") :edges ((:from "a" :to "a" :label "again") ("a" "b")))))
    (let* ((svg (agent-ui-test-aue-svg component 120))
           (name (seq-some (lambda (e) (and (agent-ui--plist-p e) (plist-get e :label))) (plist-get component :edges)))
           (boxes nil) (start 0))
      (while (string-match "<rect width=\"\\([0-9.]+\\)\" height=\"\\([0-9.]+\\)\" x=\"\\([0-9.-]+\\)\" y=\"\\([0-9.-]+\\)\"" svg start)
        (push (mapcar #'string-to-number (list (match-string 3 svg) (match-string 4 svg) (match-string 1 svg) (match-string 2 svg)))
              boxes)
        (setq start (match-end 0)))
      (should (string-match (format "y=\"\\([0-9.-]+\\)\" x=\"\\([0-9.-]+\\)\">%s<" name) svg))
      (let ((x (string-to-number (match-string 2 svg))) (y (string-to-number (match-string 1 svg))))
        (should-not (seq-some (lambda (b) (pcase-let ((`(,bx ,by ,bw ,bh) b))
                                            (and (< bx x (+ bx bw)) (< by y (+ by bh)))))
                              boxes))))))

(ert-deftest agent-ui-components/graph-edge-labels-whole ()
  "An edge's label between two layers: its corridor wide enough for it, and
drawn over the boxes (6 columns hid \"depends on\" but \"pends\" under them)."
  (let* ((svg (agent-ui-test-aue-svg '(:type "graph" :nodes ("parser" "checker")
                               :edges ((:from "parser" :to "checker" :label "depends on")))
                             120))
         (label-x (progn (string-match "x=\"\\([0-9.]+\\)\">depends on<" svg)
                         (string-to-number (match-string 1 svg))))
         (boxes (let ((all nil) (start 0))
                  (while (string-match "<rect width=\"\\([0-9.]+\\)\" height=\"[0-9.]+\" x=\"\\([0-9.]+\\)\"" svg start)
                    (push (cons (string-to-number (match-string 2 svg)) (string-to-number (match-string 1 svg))) all)
                    (setq start (match-end 0)))
                  (sort all (lambda (a b) (< (car a) (car b)))))))
    ;; ~8 px a character, centred: between parser's box's end and checker's start.
    (should (<= (+ (caar boxes) (cdar boxes)) (- label-x (* 0.5 8 10))))
    (should (<= (+ label-x (* 0.5 8 10)) (car (cadr boxes))))
    ;; Over the boxes: after them in the SVG.
    (should (> (string-search ">depends on<" svg) (string-search "<rect" svg)))))

(ert-deftest agent-ui-components/graph-down ()
  "Direction down: top to bottom (it was ignored, the same as right), its edges
crossing no box either."
  (let* ((right '(:type "graph" :nodes ("lexer" "parser" "codegen") :edges (("lexer" "parser") ("parser" "codegen"))))
         (down (append right '(:direction "down")))
         (svg (agent-ui-test-aue-svg down 120))
         (rects (let ((all nil) (start 0))
                  (while (string-match "<rect width=\"[0-9.]+\" height=\"[0-9.]+\" x=\"\\([0-9.]+\\)\" y=\"\\([0-9.]+\\)\"" svg start)
                    (push (cons (string-to-number (match-string 1 svg)) (string-to-number (match-string 2 svg))) all)
                    (setq start (match-end 0)))
                  (nreverse all))))
    (should-not (equal svg (agent-ui-test-aue-svg right 120)))
    ;; Each layer lower than the one before, at the same x.
    (should (< (cdr (nth 0 rects)) (cdr (nth 1 rects)) (cdr (nth 2 rects))))
    (should (= (car (nth 0 rects)) (car (nth 1 rects)))))
  (dolist (component '((:type "graph" :direction "down" :nodes ("x" "a" "b" "c" "m")
                      :edges (("x" "a") ("x" "m") ("m" "b") ("a" "b") ("b" "c") ("a" "c") ("m" "c")))
                     (:type "graph" :direction "down" :nodes ("alpha" "beta")
                      :edges (("alpha" "alpha") ("alpha" "beta") ("beta" "alpha")))))
    (should-not (agent-ui-test-aue-crossings (agent-ui-test-aue-svg component 120)))))

(ert-deftest agent-ui-components/graph-never-shrunk-unreadable ()
  "In the GUI a graph is shrunk to 0.6 at most: else laid out downwards
(no taller than the pane is wide), else drawn as text (an 11-node chain was
11 pixels high at 24 columns)."
  (let ((chain (list :type "graph" :nodes (mapcar (lambda (i) (format "step%d" i)) (number-sequence 1 11))
                     :edges (cl-loop for i from 1 below 11
                                     collect (list (format "step%d" i) (format "step%d" (1+ i))))))
        (two '(:type "graph" :edges (("a request handler" "the validation step")
                                     ("the validation step" "the database writer")))))
    (cl-flet ((drawn (component width)
                ;; (WIDTH HEIGHT VIEW-WIDTH VIEW-HEIGHT) of its image, or its text.
                (let ((text (agent-ui-render component (agent-ui-context :width width :graphic t
                                                                       :char-width 8 :line-height 16))))
                  (if-let* ((image (get-text-property 0 'display text))
                            (svg (plist-get (cdr image) :data)))
                      (progn (string-match "<svg width=\"\\([0-9]+\\)\" height=\"\\([0-9]+\\)\"[^>]*viewBox=\"0 0 \\([0-9]+\\) \\([0-9]+\\)\"" svg)
                             (mapcar (lambda (i) (string-to-number (match-string i svg))) '(1 2 3 4)))
                    (substring-no-properties text)))))
      (dolist (component (list chain two))
        (dolist (width (number-sequence 16 120 4))
          (let ((drawn (drawn component width)))
            (when (consp drawn)
              (should (>= (/ (float (nth 0 drawn)) (nth 2 drawn)) 0.6))))))
      ;; The chain: an image at 120, text at 24 and 40.
      (should (consp (drawn chain 120)))
      (should (string-prefix-p "step1  ─▶ step2\nstep2  ─▶ step3" (drawn chain 24)))
      (should (stringp (drawn chain 40)))
      ;; Two edges at 40: downwards (three layers of boxes two lines high,
      ;; a row of them at 120), not shrunk.
      (should (< (nth 1 (drawn two 120)) (* 4 16)))
      (let ((drawn (drawn two 40)))
        (should (consp drawn))
        (should (> (nth 1 drawn) (* 3 2 16)))
        (should (= (nth 0 drawn) (nth 2 drawn)))))))

(ert-deftest agent-ui-components/graph-listed-twice ()
  "A node listed twice is one, its later status kept; an edge listed twice,
once (each was drawn twice, the status lost)."
  (should (equal (agent-ui-test-aue-draw '(:type "graph" :nodes ("a" "a") :edges (("a" "b")))) "a ─▶ b\nb"))
  (let ((nodes (plist-get (agent-ui-check "graph" '(:type "graph" :nodes ("a" (:id "a" :status "error")))) :nodes)))
    (should (= (length nodes) 1))
    (should (eq (plist-get (car nodes) :status) 'error)))
  (should (equal (agent-ui-test-aue-draw '(:type "graph" :nodes ("a" "b") :edges (("a" "b") ("a" "b")))) "a ─▶ b\nb")))

(ert-deftest agent-ui-components/graph-labels-are-text ()
  "A node's or an edge's label that isn't text is refused, saying so (it
broke the drawing: \"stringp, 42\")."
  (should (string-match-p "node 1's label is text, not 42"
                          (agent-ui-test-aue-error '(:type "graph" :nodes ((:id "a" :label 42))))))
  (should (string-match-p "edge 1's label is text, not 7"
                          (agent-ui-test-aue-error '(:type "graph" :edges ((:from "a" :to "b" :label 7)))))))

(ert-deftest agent-ui-components/graph-skip-edges-cross-no-box ()
  "An edge skipping a layer goes round through the corridors between layers
and a lane beside the stacks, whatever its ends' places in them (from or to
a box not at a stack's edge, it went straight through the boxes there)."
  (dolist (component '((:type "graph" :nodes ("a" "b" "xxxx" "yyyy")
                      :edges (("a" "b") ("b" "xxxx") ("b" "yyyy") ("a" "yyyy")))
                     (:type "graph" :nodes ("r" "p" "q" "s" "z" "w")
                      :edges (("r" "p") ("r" "q") ("r" "s") ("p" "w") ("w" "z") ("q" "z") ("s" "z") ("q" "w")))
                     (:type "graph" :nodes ("a" "b" "c") :edges (("a" "b") ("b" "c") ("a" "c")))))
    (should-not (agent-ui-test-aue-crossings (agent-ui-test-aue-svg component 120)))))

(ert-deftest agent-ui-components/graph-layout ()
  (cl-flet ((layout (nodes edges)
              (agent-ui-graph-layout (mapcar (lambda (id) (list :id id)) nodes)
                                     (mapcar (lambda (e) (list :from (car e) :to (cadr e))) edges))))
    ;; By the longest path: codegen after checker, not beside it.
    (should (equal (layout '("lexer" "parser" "checker" "codegen")
                           '(("lexer" "parser") ("parser" "checker") ("parser" "codegen") ("checker" "codegen")))
                   '(("lexer") ("parser") ("checker") ("codegen"))))
    ;; A cycle: its edge back left out, no loop.
    (should (equal (layout '("a" "b" "c") '(("a" "b") ("b" "c") ("c" "a"))) '(("a") ("b") ("c"))))
    ;; Unconnected nodes: the first layer.
    (should (equal (layout '("x" "y") nil) '(("x" "y"))))
    ;; Ordered by their parents' places (fewer crossings).
    (should (equal (layout '("a" "b" "c" "d") '(("a" "d") ("b" "c")))
                   '(("a" "b") ("d" "c"))))))

(ert-deftest agent-ui-components/graph-shapes ()
  "A diamond, a cycle, edges listed twice, nodes apart: laid out and drawn as
by the longest path to each node, a cycle's edge back left out."
  (pcase-dolist (`(,component ,layers ,text ,arrows)
                 '(((:type "graph" :nodes ("top" "left" "right" "bottom")
                     :edges (("top" "left") ("top" "right") ("left" "bottom") ("right" "bottom")))
                    (("top") ("left" "right") ("bottom"))
                    "top    ─▶ left, right\nleft   ─▶ bottom\nright  ─▶ bottom\nbottom"
                    4)
                   ((:type "graph" :nodes ("a" "b" "c" "d") :edges (("a" "b") ("b" "c") ("c" "a") ("c" "d")))
                    (("a") ("b") ("c") ("d"))
                    "a ─▶ b\nb ─▶ c\nc ─▶ a, d\nd"
                    4)
                   ((:type "graph" :nodes ("a" "b" "c")
                     :edges (("a" "b") ("b" "c") ("a" "b") (:from "b" :to "c" :label "x")
                             (:from "b" :to "c" :label "x") ("a" "c")))
                    (("a") ("b") ("c"))
                    "a ─▶ b, c\nb ─▶ c, c (x)\nc"
                    4)
                   ((:type "graph" :nodes ("p" "q" "x" "y" "lonely") :edges (("y" "x") ("p" "q")))
                    (("p" "y" "lonely") ("q" "x"))
                    "p      ─▶ q\ny      ─▶ x\nlonely\nq\nx"
                    2)))
    (let ((checked (agent-ui-check "graph" component)))
      (should (equal (agent-ui-graph-layout (plist-get checked :nodes) (plist-get checked :edges)) layers))
      (should (equal (agent-ui-test-aue-draw component) text))
      (should (= arrows (cl-count ?\n (replace-regexp-in-string "marker-end" "\n" (agent-ui-test-aue-svg component 120))))))))

(ert-deftest agent-ui-components/graph-work-linear ()
  "400 nodes and 3000 edges checked, laid out, drawn as text and in the GUI:
each node and edge looked at a few times, not once for every other one (the
layout and the drawings were O(V*E), the edges' de-duplication O(E^2): a
second a drawing)."
  (let* ((n 400) (m 3000)
         ;; At random (the same each time): mostly forward, a few back
         ;; (cycles), a few listed twice.
         (seed 1)
         (next (lambda () (setq seed (mod (+ (* seed 1103515245) 12345) 2147483648)) (mod (ash seed -8) n)))
         (edges (cl-loop for k below m
                         collect (let ((a (funcall next)) (b (funcall next)))
                                   (if (zerop (mod k 50))
                                       (list (format "n%d" (max a b)) (format "n%d" (min a b)))
                                     (list (format "n%d" (min a b)) (format "n%d" (max a b)))))))
         (component (list :type "graph" :nodes (cl-loop for i below n collect (format "n%d" i)) :edges edges))
         (looks 0) (compares 0))
    (cl-letf* ((get (symbol-function 'plist-get))
               (same (symbol-function 'equal))
               ((symbol-function 'plist-get)
                (lambda (plist prop &optional predicate)
                  ;; A node's or an edge's.
                  (when (memq (car-safe plist) '(:id :from)) (cl-incf looks))
                  (funcall get plist prop predicate)))
               ((symbol-function 'equal) (lambda (a b) (cl-incf compares) (funcall same a b))))
      (agent-ui-test-aue-draw component :width 80)
      ;; Too big for the pane: laid out twice, drawn as text.  In a pane wide
      ;; enough: the image.
      (agent-ui-render component (agent-ui-context :width 120 :graphic t :char-width 8 :line-height 16))
      (should (agent-ui-test-aue-svg component 20000)))
    ;; Some 40 times, a few drawings in all (it was some 3000 times).
    (should (< looks (* 100 (+ n m))))
    (should (< compares (* 10 (+ n m))))))

(ert-deftest agent-ui-components/graph-edges-capped ()
  "At most 10 times `agent-ui-max-rows' edges (nodes at most that), counted
once each: more refused, saying so (any number were laid out and drawn)."
  (let ((agent-ui-max-rows 5)
        (edges (lambda (k) (cl-loop for i below k collect (list :from "a" :to "b" :label (format "%d" i))))))
    (should (agent-ui-check "graph" (list :type "graph" :edges (append (funcall edges 50) (funcall edges 10)))))
    (should (string-match-p "at most 50 edges"
                            (agent-ui-test-aue-error (list :type "graph" :edges (funcall edges 51)))))))

(ert-deftest agent-ui-components/graph ()
  (let ((component '(:type "graph" :nodes ("lexer" "parser" (:id "checker" :status "error"))
                   :edges (("lexer" "parser") (:from "parser" :to "checker" :label "types") ("parser" "codegen")))))
    ;; codegen: a node only an edge names.
    (should (equal (agent-ui-test-aue-draw component)
                   (concat "lexer   ─▶ parser\n"
                           "parser  ─▶ checker (types), codegen\n"
                           "checker\n"
                           "codegen")))
    (should (eq (agent-ui-test-aue-face-at component "checker") 'agent-ui-error))
    ;; In the GUI: a box each, an arrow each, shrunk to the pane.
    (let ((svg (plist-get (cdr (get-text-property 0 'display (agent-ui-render component (agent-ui-context :width 20 :graphic t))))
                          :data)))
      (should (= 4 (cl-count ?\n (replace-regexp-in-string "<rect" "\n" svg))))
      (should (= 3 (cl-count ?\n (replace-regexp-in-string "marker-end" "\n" svg))))
      (should (string-match-p "<svg width=\"160\"" svg))
      (should (string-match-p "viewBox=\"0 0 [0-9]+ [0-9]+\"" svg))))
  (should (equal (agent-ui-test-aue-draw '(:type "graph")) "no nodes")))

(ert-deftest agent-ui-components/graph-wrong ()
  (should (string-match-p "edge 1 must be" (agent-ui-test-aue-error '(:type "graph" :edges (("a"))))))
  (should (string-match-p "node 1 must be" (agent-ui-test-aue-error '(:type "graph" :nodes (3)))))
  (should (string-match-p "status is ok, error" (agent-ui-test-aue-error '(:type "graph" :nodes ((:id "a" :status "red"))))))
  (should (string-match-p "direction must be" (agent-ui-test-aue-error '(:type "graph" :direction "up")))))

;;; agent-ui-graph-tests.el ends here
