;;; agent-ui-compare-tests.el --- Tests for Agent UI: the compare component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-compare.el: the compare component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defconst agent-ui-test-aue-two-ways
  '(:type "compare" :question "Which reads better?"
    :options ((:label "A: a loop" :component (:type "text" :text "for x in xs:\n    total += x"))
              (:label "B: sum" :component (:type "text" :text "total = sum(xs)"))))
  "Two alternatives to compare.")

(ert-deftest agent-ui-components/compare ()
  "Side by side, each under its mark; stacked when a column would be too
narrow; answered: the answer, the one picked marked; a still picture: no
note nor Answer."
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-two-ways)
                 (concat "Which reads better?\n"
                         " ( ) A: a loop                │ ( ) B: sum\n"
                         " for x in xs:                 │ total = sum(xs)\n"
                         ;; The divider down to the longest's end, as a panel's.
                         "     total += x               │\n"
                         " ✎ Add a note\n"
                         " ⏵ Answer")))
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-two-ways :width 40)
                 (concat "Which reads better?\n"
                         " ( ) A: a loop\n"
                         "   for x in xs:\n"
                         "       total += x\n"
                         "\n"
                         " ( ) B: sum\n"
                         "   total = sum(xs)\n"
                         " ✎ Add a note\n"
                         " ⏵ Answer")))
  (should (string-suffix-p " (•) B: sum\n   total = sum(xs)\n ✓ Answered: B: sum"
                           (agent-ui-test-aue-draw (append '(:selected ("B: sum") :answered "B: sum") agent-ui-test-aue-two-ways)
                                           :width 40)))
  (should-not (string-search "Answer" (agent-ui-test-aue-draw agent-ui-test-aue-two-ways :still t)))
  (should (agent-ui-ask-waiting-p agent-ui-test-aue-two-ways))
  ;; Images, in the GUI: one under another, to be seen.
  (let ((charts '(:type "compare" :question "Which chart?"
                  :options ((:label "Bars" :component (:type "chart" :kind "bar" :labels ("a" "b") :values (1 2)))
                            (:label "Line" :component (:type "chart" :kind "line" :labels ("a" "b") :values (1 2)))))))
    (should-not (string-search "│ ( ) Line" (agent-ui-test-aue-draw charts :width 100 :graphic t)))
    (should (string-search "│ ( ) Line" (agent-ui-test-aue-draw charts :width 100)))))

(ert-deftest agent-ui-components/compare-picked-and-answered ()
  "A mark picks its option; Answer sends its label and the note; locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show (append '(:id "ways") agent-ui-test-aue-two-ways))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "( ) B: sum")
        (should (equal (plist-get (agent-ui-get "ways") :selected) '("B: sum")))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "shorter")))
          (agent-ui-test-aue-press "Add a note"))
        (agent-ui-test-aue-press "⏵ Answer")
        (should (equal sent '(("Answer to compare ways (Which reads better?): B: sum. Note: shorter" t))))
        (agent-ui--flush)
        (should (string-search "✓ Answered: B: sum · note: shorter" (buffer-string)))
        (should-not (string-search "⏵ Answer" (buffer-string)))))))

(ert-deftest agent-ui-components/compare-wrong ()
  (should (string-match-p "2 to 4 options"
                          (agent-ui-test-aue-error '(:type "compare" :question "q" :options ((:label "a" :component (:type "text" :text "x")))))))
  (should (string-match-p "option 2 must be"
                          (agent-ui-test-aue-error '(:type "compare" :question "q"
                                             :options ((:label "a" :component (:type "text" :text "x")) (:component (:type "text" :text "y")))))))
  (should (string-match-p "option 1's component must be a component"
                          (agent-ui-test-aue-error '(:type "compare" :question "q" :options ((:label "a") (:label "b"))))))
  (should (string-match-p "option 1: text: text is required"
                          (agent-ui-test-aue-error '(:type "compare" :question "q"
                                             :options ((:label "a" :component (:type "text")) (:label "b" :component (:type "text" :text "y")))))))
  (should (string-match-p "same label"
                          (agent-ui-test-aue-error '(:type "compare" :question "q"
                                             :options ((:label "a" :component (:type "text" :text "x")) (:label "a" :component (:type "text" :text "y"))))))))

;;; agent-ui-compare-tests.el ends here
