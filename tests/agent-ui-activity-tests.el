;;; agent-ui-activity-tests.el --- Tests for Agent UI: the activity component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-activity.el: the activity component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/activity ()
  "An activity: its header a line (its mark in its face, its owner in its
colour as a log's sources, its label, its detail muted, its right at its
end), its last lines on a rail, each cut to the width, a line's mark and
level as a log's (a plain one's found by its words), its footer closing
them (text muted, or pieces); none, its empty said."
  (let ((component '(:type "activity" :label "watch.sh" :owner "green" :sources ("build" "green")
                   :detail "step 2 of 3" :right "1m 15s" :show 3
                   :lines ("old line" (:mark "❯" :mark-face "muted" :level "debug" :text "watch.sh --all")
                           "step two"
                           "error: refused, and a tail of words too long for the box's width")
                   :footer ("the last 3 of 9 lines · " (:text "1 error" :face "error")))))
    (should (equal (agent-ui-test-aue-draw component)
                   (concat "●  green  watch.sh · step 2 of 3                      1m 15s\n"
                           "   │ ❯ watch.sh --all\n"
                           "   │ step two\n"
                           "   │ error: refused, and a tail of words too long for the b…\n"
                           "   ╰ the last 3 of 9 lines · 1 error")))
    (should (eq (agent-ui-test-aue-face-at component "●") 'agent-ui-accent))
    (should (eq (agent-ui-test-aue-face-at component "green") (nth 1 agent-ui-log-source-faces)))
    (should-not (agent-ui-test-aue-face-at component "watch.sh ·"))
    (should (eq (agent-ui-test-aue-face-at component " · step 2") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at component "1m 15s") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at component "   │") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at component "watch.sh --all") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at component "error: refused") 'agent-ui-error))
    (should (eq (agent-ui-test-aue-face-at component "the last") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at component "1 error") 'agent-ui-error)))
  ;; Asking: its mark and right as given; no lines, its empty said.
  (let ((component '(:type "activity" :label "agent review" :mark "◆" :mark-face "warning"
                   :right "asks you" :right-face "warning" :empty "Nothing done yet.")))
    (should (equal (agent-ui-test-aue-draw component :width 40)
                   (concat "◆  agent review                 asks you\n"
                           "   │ Nothing done yet.")))
    (should (eq (agent-ui-test-aue-face-at component "asks you" :width 40) 'agent-ui-warning)))
  ;; Narrow: its label cut short, its right kept while 8 columns are left
  ;; for what's before it; fewer, its right left out.
  (should (equal (agent-ui-test-aue-draw '(:type "activity" :label "a-long-script-name.sh" :right "1h 2m") :width 20)
                 "●  a-long-sc…  1h 2m"))
  (should (equal (agent-ui-test-aue-draw '(:type "activity" :label "a-long-script-name.sh" :right "1h 2m") :width 12)
                 "●  a-long-s…")))

(ert-deftest agent-ui-components/activity-a-gap ()
  "A log's gap line ({\"gap\": \"17m\"}) in an activity: ┊ and its time on the
rail, as a log draws it, not the whole box failing (doom-ht6.68)."
  (let ((drawn (agent-ui-test-aue-draw '(:type "activity" :lines ("a" (:gap "17m") "b")))))
    (should-not (string-search "⚠" drawn))
    (should (string-match-p "┊ 17m" drawn))
    (should (string-match-p "a" drawn))))

(ert-deftest agent-ui-components/activity-wrong ()
  (should (string-match-p "activity: mark-face \"pink\" is none of plain, muted"
                          (agent-ui-test-aue-error '(:type "activity" :mark-face "pink"))))
  (should (string-match-p "activity: show must be 0 or more"
                          (agent-ui-test-aue-error '(:type "activity" :show -1))))
  (should (string-match-p "log: line 1 must be text"
                          (agent-ui-test-aue-error '(:type "activity" :lines ((:level "info"))))))
  (should (string-match-p "piece's face \"loud\""
                          (agent-ui-test-aue-error '(:type "activity" :footer ("a" (:text "b" :face "loud")))))))

;;; agent-ui-activity-tests.el ends here
