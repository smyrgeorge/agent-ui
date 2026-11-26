;;; agent-ui-text-tests.el --- Tests for Agent UI: the text component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-text.el: the text component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/text ()
  (should (equal (agent-ui-test-aue-draw '(:type "text" :text "One line.\nAnother.")) "One line.\nAnother."))
  ;; Wrapped to the width, at spaces.
  (should (equal (agent-ui-test-aue-draw (list :type "text" :text (string-join (make-list 8 "word") " "))
                                 :width 20)
                 "word word word word\nword word word word"))
  (should (eq (agent-ui-test-aue-face-at '(:type "text" :text "Done." :face "success") "Done") 'agent-ui-success))
  (should (eq (agent-ui-test-aue-face-at '(:type "text" :text "Hm." :face "muted") "Hm") 'agent-ui-muted))
  (should-not (agent-ui-test-aue-face-at '(:type "text" :text "Plain.") "Plain"))
  (should (equal (agent-ui-test-aue-error '(:type "text")) "text: text is required"))
  (should (string-match-p "face must be one of"
                          (agent-ui-test-aue-error '(:type "text" :text "x" :face "loud")))))

;;; agent-ui-text-tests.el ends here
