;;; agent-ui-rank-tests.el --- Tests for Agent UI: the rank component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-rank.el: the rank component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/rank-wrapped-item-moved ()
  "A wrapped item moves with M-up / M-down (K / J) from any of its lines."
  (let ((agent-ui-default-width 40)
        (long "Fix the parser, the lexer and the checker, which all fail on the new grammar"))
    (agent-ui-test-aue-canvas
      (agent-ui-show `(:id "prio" :type "rank" :question "First?" :items ("Docs" ,long)))
      (with-current-buffer canvas
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "grammar")
        ;; Its last line, not its first.
        (should-not (string-search "2." (buffer-substring (line-beginning-position) (line-end-position))))
        (agent-ui-move-item-up)
        (should (equal (plist-get (agent-ui-get "prio") :order) (list long "Docs")))
        (should (string-prefix-p " 1. Fix the parser" (buffer-substring (line-beginning-position) (line-end-position))))
        (forward-line 2)
        (agent-ui-move-item-down)
        (should (equal (plist-get (agent-ui-get "prio") :order) (list "Docs" long)))))))

(ert-deftest agent-ui-components/rank ()
  "Numbered in the user's order (an item new to it after, one gone left
out); answered: Sent, the note; no hint nor button in a still picture."
  (let ((rank '(:type "rank" :question "What first?"
                :items ((:label "Fix the parser" :detail "the root cause") "Update the docs" "Release"))))
    (should (equal (agent-ui-test-aue-draw rank)
                   (concat "What first?\n"
                           " 1. Fix the parser  the root cause\n"
                           " 2. Update the docs\n"
                           " 3. Release\n"
                           " M-↑ / M-↓ (K / J) move the item at the cursor\n"
                           " ⏵ Answer")))
    (should (equal (agent-ui-test-aue-draw (append '(:order ("Release" "Gone" "Fix the parser")) rank) :still t)
                   (concat "What first?\n"
                           " 1. Release\n"
                           " 2. Fix the parser  the root cause\n"
                           " 3. Update the docs")))
    (should (string-suffix-p " 3. Release\n ✓ Sent · note: soon"
                             (agent-ui-test-aue-draw (append '(:answered "x" :note-text "soon") rank)))))
  ;; Ten or more: numbers aligned.
  (should (string-search "  9. i9\n 10. i10"
                         (agent-ui-test-aue-draw (list :type "rank" :question "q"
                                               :items (mapcar (lambda (i) (format "i%d" i)) (number-sequence 1 10))))))
  (should (agent-ui-ask-waiting-p '(:type "rank" :question "q" :items ("a" "b")))))

(ert-deftest agent-ui-components/rank-moved-and-sent ()
  "M-up / M-down move the item at the cursor (it stays on it; not past the
ends); kept in the component; Answer sends the order and a note; then locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "prio" :type "rank" :question "What first?" :items ("Fix" "Docs" "Release") :note t))
      (with-current-buffer canvas
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "Release")
        (agent-ui-move-item-up)
        (should (equal (get-text-property (line-beginning-position) 'agent-ui-item) "Release"))
        (agent-ui-move-item-up)
        (agent-ui-move-item-up)
        (should (equal (plist-get (agent-ui-get "prio") :order) '("Release" "Fix" "Docs")))
        (should (string-search " 1. Release\n 2. Fix\n 3. Docs" (buffer-string)))
        (search-forward "Fix")
        (agent-ui-move-item-down)
        (should (equal (plist-get (agent-ui-get "prio") :order) '("Release" "Docs" "Fix")))
        ;; Not on an item: said.
        (goto-char (point-min))
        (search-forward "What first")
        (should-error (agent-ui-move-item-up) :type 'user-error)
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "docs are quick")))
          (agent-ui-test-aue-press "Add a note"))
        (agent-ui-test-aue-press "⏵ Answer")
        (should (equal sent '(("Answer to rank prio (What first?): in this order: Release, Docs, Fix. Note: docs are quick" t))))
        (agent-ui--flush)
        (should (string-search "✓ Sent · note: docs are quick" (buffer-string)))
        ;; Locked: nothing moves.
        (goto-char (point-min))
        (search-forward "Docs")
        (should-error (agent-ui-move-item-up) :type 'user-error)))))

(ert-deftest agent-ui-components/rank-wrong ()
  (should (string-match-p "two items at least" (agent-ui-test-aue-error '(:type "rank" :question "q" :items ("a")))))
  (should (string-match-p "item 2 must be" (agent-ui-test-aue-error '(:type "rank" :question "q" :items ("a" 3)))))
  (should (string-match-p "same label" (agent-ui-test-aue-error '(:type "rank" :question "q" :items ("a" "a")))))
  (should (string-match-p "order is the items' labels"
                          (agent-ui-test-aue-error '(:type "rank" :question "q" :items ("a" "b") :order (1))))))

;;; agent-ui-rank-tests.el ends here
