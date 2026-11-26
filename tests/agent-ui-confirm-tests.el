;;; agent-ui-confirm-tests.el --- Tests for Agent UI: the confirm component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-confirm.el: the confirm component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/confirm ()
  "Its question and what will happen; high danger in red, the word to type
said; answered, the answer instead of its buttons; none in a still picture."
  (let ((push '(:type "confirm" :question "Force-push to origin/main?"
                :details ("Rewrites the last 3 commits" "Others' work on main may be lost")
                :danger "high" :word "main")))
    (should (equal (agent-ui-test-aue-draw push)
                   (concat "▲ Force-push to origin/main?\n"
                           "  • Rewrites the last 3 commits\n"
                           "  • Others' work on main may be lost\n"
                           "⏵ Proceed   ⏵ Cancel   type \"main\" to proceed")))
    (should (memq 'agent-ui-error (ensure-list (agent-ui-test-aue-face-at push "Force-push"))))
    (should (equal (agent-ui-test-aue-draw push :still t)
                   (concat "▲ Force-push to origin/main?\n"
                           "  • Rewrites the last 3 commits\n"
                           "  • Others' work on main may be lost")))
    (should (equal (agent-ui-test-aue-draw (append '(:answered "proceed") push))
                   (concat "▲ Force-push to origin/main?\n"
                           "  • Rewrites the last 3 commits\n"
                           "  • Others' work on main may be lost\n"
                           "✓ Answered: Proceed"))))
  ;; Low: no word unless given; its labels; a detail wrapped under itself.
  (should (equal (agent-ui-test-aue-draw '(:type "confirm" :question "Deploy?" :proceed "Deploy" :cancel "Not now"))
                 "Deploy?\n⏵ Deploy   ⏵ Not now"))
  (should (equal (substring-no-properties
                  (agent-ui-render '(:type "confirm" :question "Deploy?"
                                     :details ("three services restart, one at a time") :answered "cancel")
                                   (agent-ui-context :width 24)))
                 "Deploy?\n  • three services\n    restart, one at a\n    time\n✗ Answered: Cancel"))
  ;; A diff, as the diff component draws it.
  (should (string-search "▾ db.sql  +1 −1"
                         (agent-ui-test-aue-draw '(:type "confirm" :question "Migrate?"
                                           :diff "--- a/db.sql\n+++ b/db.sql\n@@ -1 +1 @@\n-a\n+b\n")))))

(ert-deftest agent-ui-components/confirm-and-plan-buttons-fit ()
  "A confirm's Proceed / Cancel and a plan's Approve / Reject are broken
onto lines of their own where they don't fit the width (on one line, the
last one was off screen), each still a button."
  (dolist (case '(((:type "confirm" :question "Deploy?" :proceed "Deploy to production" :cancel "Not now")
                   24 "⏵ Deploy to production\n⏵ Not now")
                  ((:type "confirm" :question "Push?" :danger "high" :word "main") 30
                   "⏵ Proceed   ⏵ Cancel\ntype \"main\" to proceed")
                  ((:type "steps" :steps ("Fix the parser") :approve (:question "Go?")) 18
                   "⏵ Approve\n⏵ Reject")))
    (pcase-let ((`(,component ,width ,end) case))
      (let ((text (agent-ui-render component (agent-ui-context :width width))))
        (should (string-suffix-p end (substring-no-properties text)))
        (dolist (line (split-string text "\n"))
          (should (<= (string-width line) width)))
        (dolist (label '("⏵ Deploy" "⏵ Not now" "⏵ Approve" "⏵ Reject" "⏵ Cancel"))
          (when-let* ((at (string-search label text)))
            (should (get-text-property at 'agent-ui-action text))))))))

(ert-deftest agent-ui-components/confirm-proceed-or-cancel ()
  "Proceed or Cancel sends its answer at once; then locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "deploy" :type "confirm" :question "Deploy v2.3 to staging?"))
      (agent-ui-show '(:id "cache" :type "confirm" :question "Delete the cache?"))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "⏵ Proceed")
        (should (equal sent '(("Answer to confirm deploy (Deploy v2.3 to staging?): proceed" t))))
        (should (equal (plist-get (agent-ui-get "deploy") :answered) "proceed"))
        (agent-ui--flush)
        (should (string-search "✓ Answered: Proceed" (buffer-string)))
        ;; The other's Cancel (the first's buttons gone).
        (agent-ui-test-aue-press "⏵ Cancel")
        (should (equal (car sent) '("Answer to confirm cache (Delete the cache?): cancel" t)))
        (agent-ui--flush)
        (should-not (string-search "⏵" (buffer-string)))))))

(ert-deftest agent-ui-components/confirm-typing-the-word ()
  "High danger: Proceed asks to type the word (\"yes\" if none); a wrong one
refused, nothing sent; Cancel asks nothing."
  (agent-ui-test-aue-canvas
    (let* ((sent nil) (typed nil) (asked nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (cl-letf (((symbol-function 'read-string) (lambda (prompt &rest _) (push prompt asked) typed)))
        (agent-ui-show '(:id "push" :type "confirm" :question "Force-push?" :danger "high" :word "main"))
        (with-current-buffer canvas
          (setq typed "master")
          (should (equal (cadr (should-error (agent-ui-test-aue-press "⏵ Proceed") :type 'user-error))
                         "Not proceeding: type main to proceed"))
          (should-not sent)
          (should-not (plist-get (agent-ui-get "push") :answered))
          (setq typed " main ")
          (agent-ui-test-aue-press "⏵ Proceed")
          (should (equal (car asked) "Type main to proceed: "))
          (should (equal sent '(("Answer to confirm push (Force-push?): proceed" t)))))
        (agent-ui-show '(:id "drop" :type "confirm" :question "Drop the table?" :danger "high"))
        (with-current-buffer canvas
          (setq typed "yes")
          (agent-ui-test-aue-press "⏵ Proceed")
          (should (equal (car asked) "Type yes to proceed: ")))
        (agent-ui-show '(:id "wipe" :type "confirm" :question "Wipe it?" :danger "high"))
        (with-current-buffer canvas
          (setq asked nil)
          (agent-ui-test-aue-press "⏵ Cancel")
          (should-not asked)
          (should (equal (car sent) '("Answer to confirm wipe (Wipe it?): cancel" t))))))))

(ert-deftest agent-ui-components/confirm-wrong ()
  (should (string-match-p "question is required" (agent-ui-test-aue-error '(:type "confirm"))))
  (should (string-match-p "details are lines" (agent-ui-test-aue-error '(:type "confirm" :question "q" :details ("a" 2)))))
  (should (string-match-p "danger" (agent-ui-test-aue-error '(:type "confirm" :question "q" :danger "medium"))))
  (should (string-match-p "word, if given" (agent-ui-test-aue-error '(:type "confirm" :question "q" :word " "))))
  (should (string-match-p "proceed\" or \"cancel" (agent-ui-test-aue-error '(:type "confirm" :question "q" :answered "maybe"))))
  ;; A question waiting until answered.
  (should (agent-ui-ask-waiting-p '(:type "confirm" :question "q")))
  (should-not (agent-ui-ask-waiting-p '(:type "confirm" :question "q" :answered "cancel"))))

(ert-deftest agent-ui-components/a-diff-inside-a-confirm-is-still ()
  "A confirm's diff, a compare's option: drawn still, nothing to comment
on: c there says so, writing nothing to the confirm (doom-ht6.67)."
  (agent-ui-test-aue-canvas
    (agent-ui-show (list :id "ok" :type "confirm" :question "Apply?" :diff agent-ui-test-aue-two-hunks))
    (agent-ui-show (list :id "cmp" :type "compare" :question "Which?"
                         :options (list (list :label "A" :component (list :type "code" :code "x = 1"))
                                        (list :label "B" :component (list :type "code" :code "y = 2")))))
    (with-current-buffer canvas
      (agent-ui--flush)
      (goto-char (point-min))
      (search-forward "size_t")
      (should-not (get-text-property (point) 'agent-ui-line))
      (should (equal (cadr (should-error (agent-ui-comment (point) (point)) :type 'user-error))
                     "Comment on a line of code or of a diff"))
      (should-not (plist-get (agent-ui-get "ok") :comments))
      (search-forward "x = 1")
      (should-not (get-text-property (1- (point)) 'agent-ui-line)))))

;;; agent-ui-confirm-tests.el ends here
