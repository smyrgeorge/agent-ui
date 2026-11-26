;;; agent-ui-choice-tests.el --- Tests for Agent UI: the choice component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-choice.el: the choice component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/choice-one ()
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "fix" :type "choice" :question "Which fix?"
                       :options ((:label "Change the test" :detail "keeps the new message") "Revert")))
      (with-current-buffer canvas
        (agent-ui--flush)
        (should (string-match-p (concat "Which fix\\?\n ( ) Change the test  keeps the new message\n"
                                        " ( ) Revert\n ⏵ Answer")
                                (buffer-substring-no-properties (point-min) (point-max))))
        ;; Nothing chosen: nothing to answer.
        (should-error (agent-ui-test-aue-press "⏵ Answer") :type 'user-error)
        (agent-ui-test-aue-press "Change the test")
        (should (equal (plist-get (agent-ui-get "fix") :selected) '("Change the test")))
        ;; One only: choosing another replaces it; choosing it again, none.
        (agent-ui-test-aue-press "Revert")
        (should (equal (plist-get (agent-ui-get "fix") :selected) '("Revert")))
        (agent-ui--flush)
        (should (string-match-p "(•) Revert" (buffer-string)))
        (agent-ui-test-aue-press "⏵ Answer")
        (should (equal sent '(("Answer to choice fix (Which fix?): Revert" t))))
        ;; Answered: said, no more buttons.
        (agent-ui--flush)
        (should (string-match-p "Which fix\\?\n✓ Answered: Revert" (buffer-string)))
        (should-not (string-search "⏵ Answer" (buffer-string)))))))

(ert-deftest agent-ui-components/choice-the-cursor-stays-on-the-option ()
  "An option pressed: the cursor stays on it (the choice drawn again)."
  (agent-ui-test-aue-canvas
    (let ((agent-ui-action-function #'ignore))
      (agent-ui-show '(:id "c" :type "choice" :question "Which?" :options ("Alpha" "Beta" "Gamma")))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "Gamma")
        (agent-ui--flush)
        (should (looking-at "Gamma"))))))

(ert-deftest agent-ui-components/choice-several-and-a-note ()
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "pick" :type "choice" :question "Which tests?" :multiple t :note t
                       :options ("lexer" "parser" "checker") :selected ("lexer")))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "parser")
        (agent-ui-test-aue-press "lexer")
        (agent-ui-test-aue-press "checker")
        (should (equal (plist-get (agent-ui-get "pick") :selected) '("parser" "checker")))
        (agent-ui--flush)
        (should (string-match-p "\\[ \\] lexer\n \\[x\\] parser\n \\[x\\] checker" (buffer-string)))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "only the slow ones")))
          (agent-ui-test-aue-press "Add a note"))
        (agent-ui-test-aue-press "⏵ Answer")
        (should (equal sent '(("Answer to choice pick (Which tests?): parser, checker. Note: only the slow ones" t))))
        (should (equal (plist-get (agent-ui-get "pick") :answered) "parser, checker · note: only the slow ones"))))))

;; doom-nwj.71
(ert-deftest agent-ui-components/choice-options-fit ()
  "Options are wrapped within the width, under their label's start; details
in a column as wide as the labels that have one (all of them: a gap of 40
before short ones'), or under their label when there's no room (a label
without a detail was never cut nor wrapped: 66 columns at 30)."
  (let ((component '(:type "choice" :question "Which fix?"
                   :options ("Change the test so that it expects the new error message text"
                             (:label "Revert" :detail "back to the old message")
                             (:label "Both" :detail "a flag choosing one")))))
    (dolist (width (number-sequence 15 120))
      (let ((lines (split-string (agent-ui-test-aue-draw component :width width) "\n")))
        (dolist (line lines) (should (<= (string-width line) width)))
        ;; Every word of every label.
        (dolist (word '("Change" "expects" "text" "Revert" "Both"))
          (should (seq-some (lambda (l) (string-search word l)) lines)))))
    (should (equal (agent-ui-test-aue-draw component :width 120)
                   (concat "Which fix?\n"
                           " ( ) Change the test so that it expects the new error message text\n"
                           " ( ) Revert  back to the old message\n"
                           " ( ) Both    a flag choosing one\n"
                           " ⏵ Answer")))
    ;; Too little room for a column (20 at least, or the widest detail):
    ;; each detail under its label.
    (should (equal (agent-ui-test-aue-draw component :width 30)
                   (concat "Which fix?\n"
                           " ( ) Change the test so that\n"
                           "     it expects the new error\n"
                           "     message text\n"
                           " ( ) Revert\n"
                           "     back to the old message\n"
                           " ( ) Both\n"
                           "     a flag choosing one\n"
                           " ⏵ Answer")))
    ;; No room for a column: its detail under its label.
    (should (equal (agent-ui-test-aue-draw component :width 20)
                   (concat "Which fix?\n"
                           " ( ) Change the test\n"
                           "     so that it\n"
                           "     expects the new\n"
                           "     error message\n"
                           "     text\n"
                           " ( ) Revert\n"
                           "     back to the old\n"
                           "     message\n"
                           " ( ) Both\n"
                           "     a flag choosing\n"
                           "     one\n"
                           " ⏵ Answer")))))

(ert-deftest agent-ui-components/choice-wrong ()
  ;; None, or an empty list (JSON's []: the same): required.
  (should (string-match-p "options is required" (agent-ui-test-aue-error '(:type "choice" :question "Q?" :options ()))))
  (should (string-match-p "option 2 must be" (agent-ui-test-aue-error '(:type "choice" :question "Q?" :options ("a" 3)))))
  (should (string-match-p "same label" (agent-ui-test-aue-error '(:type "choice" :question "Q?" :options ("a" "a")))))
  (should (string-match-p "selected \"c\" isn't an option"
                          (agent-ui-test-aue-error '(:type "choice" :question "Q?" :options ("a" "b") :selected ("c")))))
  (should (string-match-p "one option only"
                          (agent-ui-test-aue-error '(:type "choice" :question "Q?" :options ("a" "b") :selected ("a" "b")))))
  ;; Its buttons, outside a canvas (a render): said.
  (let ((text (agent-ui-render '(:type "choice" :question "Q?" :options ("a")) (agent-ui-context))))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (search-forward " a")
      (goto-char (match-beginning 0))
      (should-error (agent-ui-button-press) :type 'user-error))))

;;; agent-ui-choice-tests.el ends here
