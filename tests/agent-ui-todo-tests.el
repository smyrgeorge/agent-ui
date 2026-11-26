;;; agent-ui-todo-tests.el --- Tests for Agent UI: the todo component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-todo.el: the todo component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/todo ()
  "Ticked or not, who ticked it or added it after it; Add, and Send once the
user changed something; none of its buttons in a still picture."
  (let ((todo '(:type "todo"
                :items ((:label "Reproduce the bug" :done t)
                        (:label "Write a failing test" :done t :by "user")
                        "Fix the parser"
                        (:label "Check Windows paths" :added t))
                :changes ((:label "Write a failing test" :change "done")
                          (:label "Check Windows paths" :change "added")))))
    (should (equal (agent-ui-test-aue-draw todo)
                   (concat " [x] Reproduce the bug\n"
                           " [x] Write a failing test  you\n"
                           " [ ] Fix the parser\n"
                           " [ ] Check Windows paths   added by you\n"
                           " ✚ Add an item\n"
                           " ⏵ Send your changes (2)")))
    (should (equal (agent-ui-test-aue-draw todo :still t)
                   (concat " [x] Reproduce the bug\n"
                           " [x] Write a failing test  you\n"
                           " [ ] Fix the parser\n"
                           " [ ] Check Windows paths   added by you"))))
  ;; Nothing changed: no Send. Nothing yet: said. Narrow: no room for who.
  (should (equal (agent-ui-test-aue-draw '(:type "todo" :items ("a"))) " [ ] a\n ✚ Add an item"))
  (should (equal (agent-ui-test-aue-draw '(:type "todo")) " nothing to do yet\n ✚ Add an item"))
  (should (equal (substring-no-properties
                  (agent-ui-render '(:type "todo" :items ((:label "Write the tests" :done t :by "user" :added t)))
                                   (agent-ui-context :width 30 :still t)))
                 " [x] Write the tests")))

(ert-deftest agent-ui-components/todo-the-user-ticks-and-adds ()
  "The user ticks (the item theirs), unticks, adds: the changes kept, a
tick undone no change; Send puts them into the prompt, then they're
cleared; it goes on, never locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "plan" :type "todo"
                       :items ((:label "Reproduce" :done t) "Write a test" "Fix it" "Docs")))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "Write a test")
        (agent-ui-test-aue-press "Reproduce")
        (agent-ui-test-aue-press "Docs")
        (agent-ui-test-aue-press "Docs")
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  Check Windows paths ")))
          (agent-ui-test-aue-press "Add an item"))
        (let ((component (agent-ui-get "plan")))
          (should (equal (plist-get component :items)
                         '((:label "Reproduce" :done nil) (:label "Write a test" :done t :by "user")
                           (:label "Fix it" :done nil) (:label "Docs" :done nil)
                           (:label "Check Windows paths" :done nil :added t))))
          (should (equal (plist-get component :changes)
                         '((:label "Write a test" :change "done") (:label "Reproduce" :change "undone")
                           (:label "Check Windows paths" :change "added")))))
        ;; An added one ticked: still added, said done.
        (agent-ui-test-aue-press "Check Windows paths")
        (agent-ui--flush)
        (should (string-search "[x] Check Windows paths  added and done by you" (buffer-string)))
        ;; One that's there: refused.
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Fix it")))
          (should-error (agent-ui-test-aue-press "Add an item") :type 'user-error))
        (agent-ui-test-aue-press "Send your changes (3)")
        (should (equal sent '(("Changes to todo plan by the user: done: Write a test; not done: Reproduce; added: Check Windows paths (done)." t))))
        (should-not (plist-get (agent-ui-get "plan") :changes))
        (agent-ui--flush)
        (should-not (string-search "Send your changes" (buffer-string)))
        ;; It goes on.
        (agent-ui-test-aue-press "Fix it")
        (agent-ui-test-aue-press "Send your changes (1)")
        (should (equal (car sent) '("Changes to todo plan by the user: done: Fix it." t)))))))

(ert-deftest agent-ui-components/todo-sent-at-once ()
  "The user's changes go straight to the agent (doom-ik2)."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "plan" :type "todo" :items ("a" "b")))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "b")
        (agent-ui-test-aue-press "Send your changes (1)")
        (should (equal sent '(("Changes to todo plan by the user: done: b." t))))))))

(ert-deftest agent-ui-components/todo-the-agent-ticks-by-appending ()
  "The agent's append: an item there changes in its place (the agent's tick),
a new label after; its tick drops the user's change not sent of that item."
  (agent-ui-test-aue-canvas
    (agent-ui-show '(:id "plan" :type "todo" :items ("Reproduce" "Fix it")))
    (with-current-buffer canvas
      (agent-ui-test-aue-press "Fix it"))
    (agent-ui-append "plan" '(:items ((:label "Reproduce" :done t) "Docs")))
    (let ((component (agent-ui-get "plan")))
      (should (equal (mapcar (lambda (i) (agent-ui-todo--label i)) (plist-get component :items))
                     '("Reproduce" "Fix it" "Docs")))
      (should (equal (plist-get component :changes) '((:label "Fix it" :change "done")))))
    (with-current-buffer canvas
      (agent-ui--flush)
      (should (string-search " [x] Reproduce\n" (buffer-string)))
      (should (string-search " [x] Fix it     you" (buffer-string))))
    ;; The agent unticks the user's: theirs no more, the change dropped.
    (agent-ui-append "plan" '(:items ((:label "Fix it" :done :false))))
    (should-not (plist-get (agent-ui-get "plan") :changes))
    (should (string-match-p "only items" (agent-ui-error-message
                                          (should-error (agent-ui-append "plan" '(:submit t))
                                                        :type 'agent-ui-error))))))

(ert-deftest agent-ui-components/todo-wrong ()
  (should (string-match-p "item 2 must be a label"
                          (agent-ui-test-aue-error '(:type "todo" :items ("a" 3)))))
  (should (string-match-p "item 1 has no label" (agent-ui-test-aue-error '(:type "todo" :items ((:done t))))))
  (should (string-match-p "item 1 has \"colour\"" (agent-ui-test-aue-error '(:type "todo" :items ((:label "a" :colour "red"))))))
  (should (string-match-p "item 1's done must be true or false"
                          (agent-ui-test-aue-error '(:type "todo" :items ((:label "a" :done "yes"))))))
  (should (string-match-p "item 1's by must be"
                          (agent-ui-test-aue-error '(:type "todo" :items ((:label "a" :done t :by "bob"))))))
  (should (string-match-p "same label" (agent-ui-test-aue-error '(:type "todo" :items ("a" "a")))))
  (should (string-match-p "change 1 must be"
                          (agent-ui-test-aue-error '(:type "todo" :items ("a") :changes ((:label "a" :change "gone")))))))

(ert-deftest agent-ui-components/todo-kept-as-json ()
  "Saved with the session as JSON, and back: the same component."
  (let* ((component '(:id "plan" :type "todo"
                    :items ((:label "a" :done t :by "user") (:label "b" :done nil :added t))
                    :changes ((:label "a" :change "done") (:label "b" :change "added"))))
         (back (agent-ui-parse-json (json-serialize (agent-ui-to-json component)))))
    (should (equal (agent-ui-test-aue-draw back) (agent-ui-test-aue-draw component)))
    (should (equal (plist-get (agent-ui-check "todo" back) :changes) (plist-get component :changes)))))

;;; agent-ui-todo-tests.el ends here
