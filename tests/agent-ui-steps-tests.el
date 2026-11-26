;;; agent-ui-steps-tests.el --- Tests for Agent UI: the steps component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-steps.el: the steps component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/steps ()
  (let ((component '(:type "steps"
                   :steps ((:name "Run the tests" :status "done" :detail "412 passed")
                           (:name "Build" :status "running")
                           "Publish"
                           (:name "Tag" :status "failed" :detail "exists")
                           (:name "Notify" :status "skipped")))))
    ;; Drawn as given (not kept on a canvas: no times noted).
    (should (equal (agent-ui-test-aue-draw component :tick 2)
                   (concat "✓ Run the tests  412 passed\n"
                           "● Build\n"
                           "○ Publish\n"
                           "✗ Tag            exists\n"
                           "– Notify")))
    ;; None timed: no times' column.
    (should (equal (agent-ui-test-aue-draw '(:type "steps" :steps ((:name "a" :status "done" :detail "x") "bb")))
                   "✓ a   x\n○ bb"))
    ;; The spinner glows: the same dot, its colour changing tick by tick.
    (should (string-match-p "● Build" (agent-ui-test-aue-draw component :tick 3)))
    (let ((at (lambda (tick)
                (let ((text (agent-ui-render component (agent-ui-context :width 60 :tick tick))))
                  (get-text-property (string-search "● Build" text) 'face text)))))
      (should-not (equal (funcall at 0) (funcall at 4)))
      (should (eq (cadr (funcall at 4)) 'agent-ui-accent)))
    (should (agent-ui-animated-p component))
    (should (eq (agent-ui-test-aue-face-at component "✓") 'agent-ui-success))
    (should (eq (agent-ui-test-aue-face-at component "exists") 'agent-ui-error))
    (should (eq (agent-ui-test-aue-face-at component "Publish") 'agent-ui-muted)))
  (should-not (agent-ui-animated-p '(:type "steps" :steps ("a" (:name "b" :status "done")))))
  ;; Waiting: timed as running, its time ticking (doom-ht6.53).
  (should (agent-ui-animated-p '(:type "steps" :steps ("a" (:name "b" :status "waiting")))))
  (should (equal (agent-ui-test-aue-draw '(:type "steps")) "no steps yet")))

(ert-deftest agent-ui-components/steps-appended-by-name ()
  (let ((component '(:type "steps" :steps ("a" (:name "b" :status "running" :detail "x")))))
    (should (equal (plist-get (agent-ui-append-to component
                                                  '(:steps ((:name "b" :status "done") "c" "a")))
                              :steps)
                   ;; b changed in its place, its detail kept; c added; a as it was.
                   '("a" (:name "b" :status "done" :detail "x") "c")))
    (should (string-match-p "only steps"
                            (agent-ui-error-message
                             (should-error (agent-ui-append-to component '(:title "x"))
                                           :type 'agent-ui-error))))))

(ert-deftest agent-ui-components/steps-a-plan-to-approve ()
  "With approve: its question, the plan as the user has it (dropped steps
skipped, reworded ones renamed), x / e hinted, Approve and Reject; answered:
what was, nothing to press; a still picture: no hint nor button."
  (let ((plan '(:type "steps" :approve t
                :steps ("Reproduce the bug" (:name "Fix the parser" :detail "tokenizer.el") "Update the docs")
                :dropped ("Update the docs")
                :edits ((:name "Fix the parser" :text "Fix the tokenizer")))))
    (should (equal (agent-ui-test-aue-draw plan)
                   (concat "Go ahead with this plan?\n"
                           "○ Reproduce the bug\n"
                           "○ Fix the tokenizer  edited · tokenizer.el\n"
                           "– Update the docs    dropped\n"
                           "x drops the step at the cursor (again: back), e rewords it\n"
                           "✎ Add a note\n"
                           "⏵ Approve   ⏵ Reject")))
    (should (equal (agent-ui-test-aue-draw plan :still t)
                   (concat "Go ahead with this plan?\n"
                           "○ Reproduce the bug\n"
                           "○ Fix the tokenizer  edited · tokenizer.el\n"
                           "– Update the docs    dropped")))
    (should (agent-ui-ask-waiting-p plan))
    (should-not (agent-ui-ask-waiting-p (append '(:answered "approved") plan)))
    (should-not (agent-ui-ask-waiting-p '(:type "steps" :approve :false :steps ("a")))))
  (should (equal (agent-ui-test-aue-draw '(:type "steps" :approve (:question "Start?") :steps ("a") :answered "rejected"
                                   :note-text "too risky"))
                 "○ a\n✗ Rejected · note: too risky"))
  ;; Without approve: as ever.
  (should (equal (agent-ui-test-aue-draw '(:type "steps" :steps ("a"))) "○ a")))

(ert-deftest agent-ui-components/steps-a-plan-approved ()
  "x drops a step (again: back), e rewords one; Approve sends the plan as
the user has it, the steps becoming it (the agent's appends by the new
names), answered."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "plan" :type "steps" :approve t
                       :steps ("Reproduce the bug" "Fix the parser" "Update the docs" "Release")))
      (with-current-buffer canvas
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "Update the docs")
        (agent-ui-drop-item)
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "Release")
        (agent-ui-drop-item)
        (agent-ui-drop-item)
        (should (equal (plist-get (agent-ui-get "plan") :dropped) '("Update the docs")))
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "Fix the parser")
        (cl-letf (((symbol-function 'read-string) (lambda (_prompt initial) (should (equal initial "Fix the parser"))
                                                     " Fix the tokenizer ")))
          (agent-ui-edit-item))
        ;; Blank: refused.
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "Fix the tokenizer")
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) " ")))
          (should-error (agent-ui-edit-item) :type 'user-error))
        ;; Not on a step: said.
        (goto-char (point-min))
        (search-forward "Go ahead")
        (should-error (agent-ui-drop-item) :type 'user-error)
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "docs later")))
          (agent-ui-test-aue-press "Add a note"))
        (agent-ui-test-aue-press "⏵ Approve")
        (should (equal sent '(("Answer to steps plan (Go ahead with this plan?): approved: 1. Reproduce the bug; 2. Fix the tokenizer (edited, was: Fix the parser); 3. Release. Dropped: Update the docs. Note: docs later" t))))
        (let ((component (agent-ui-get "plan")))
          (should (equal (mapcar #'agent-ui-steps--name (plist-get component :steps))
                         '("Reproduce the bug" "Fix the tokenizer" "Release")))
          (should (equal (plist-get component :answered) "approved")))
        (agent-ui--flush)
        (should (string-search "✓ Approved · note: docs later" (buffer-string)))
        (should-not (string-search "⏵" (buffer-string)))
        ;; It runs as usual: the agent's appends, by the new names.
        (agent-ui-append "plan" '(:steps ((:name "Fix the tokenizer" :status "done"))))
        (agent-ui--flush)
        (should (string-search "✓ Fix the tokenizer" (buffer-string)))
        ;; Answered: nothing to drop.
        (goto-char (point-min))
        (search-forward "Release")
        (should-error (agent-ui-drop-item) :type 'user-error)))))

(ert-deftest agent-ui-components/steps-a-plan-rejected ()
  "Reject: asked why (none: no note), said; every step dropped: Approve
refused."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "plan" :type "steps" :approve (:question "Start?") :steps ("a" "b")))
      (with-current-buffer canvas
        (agent-ui--flush)
        (dolist (step '("○ a" "○ b"))
          (goto-char (point-min))
          (search-forward step)
          (agent-ui-drop-item)
          (agent-ui--flush))
        (should-error (agent-ui-test-aue-press "⏵ Approve") :type 'user-error)
        (should-not sent)
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "too risky")))
          (agent-ui-test-aue-press "⏵ Reject"))
        (should (equal sent '(("Answer to steps plan (Start?): rejected. Note: too risky" t))))
        (agent-ui--flush)
        (should (string-search "✗ Rejected · note: too risky" (buffer-string)))))))

(ert-deftest agent-ui-components/steps-a-plan-readable ()
  "A plan being decided on: its kept steps in the text's colour (they were
muted, as the hint under them), a dropped one struck through; answered, or
without approve, a step not started muted (doom-8fo)."
  (let ((plan '(:type "steps" :approve t
                :steps ("Reproduce the bug" "Fix the parser" "Update the docs")
                :dropped ("Update the docs")
                :edits ((:name "Fix the parser" :text "Fix the tokenizer")))))
    (should-not (agent-ui-test-aue-face-at plan "Reproduce the bug"))
    (should-not (agent-ui-test-aue-face-at plan "Fix the tokenizer"))
    (should (eq (agent-ui-test-aue-face-at plan "Update the docs") 'agent-ui-steps-dropped))
    (should (face-attribute 'agent-ui-steps-dropped :strike-through nil t))
    ;; Its notes and its hint muted.
    (should (eq (agent-ui-test-aue-face-at plan "edited") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at plan "dropped") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at plan "x drops") 'agent-ui-muted)))
  ;; Answered: a checklist, its steps not started muted.
  (should (eq (agent-ui-test-aue-face-at '(:type "steps" :approve t :answered "approved"
                                   :steps ("Write it" (:name "Ship it" :status "done")))
                                 "Write it")
              'agent-ui-muted))
  ;; Without approve: as ever.
  (let ((checklist '(:type "steps" :steps ("Write it" (:name "Ship it" :status "skipped")))))
    (should (eq (agent-ui-test-aue-face-at checklist "Write it") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at checklist "Ship it") 'agent-ui-muted))))

(defconst agent-ui-test-aue-long-step
  "Trust: a repo's panel asks once before running any of its commands, remembered by the file's content"
  "A plan's step longer than the width.")

(ert-deftest agent-ui-components/steps-a-plan-shown-whole ()
  "A plan's long step wrapped, not cut with …: its lines after the first
under its words; reworded or dropped, its note after it (it was cut to half
the width for it); answered, still whole (doom-mri)."
  (let* ((long agent-ui-test-aue-long-step)
         (plan `(:type "steps" :approve t :steps (,long "Ship it"))))
    (should (equal (seq-take (split-string (agent-ui-test-aue-draw plan :width 50) "\n") 5)
                   '("Go ahead with this plan?"
                     "○ Trust: a repo's panel asks once before running"
                     "  any of its commands, remembered by the file's"
                     "  content"
                     "○ Ship it")))
    ;; Reworded: its note on its last line.
    (should (equal (seq-take (split-string (agent-ui-test-aue-draw (append plan `(:edits ((:name ,long :text ,(concat long ", again if changed")))))
                                                           :width 50)
                                           "\n")
                             5)
                   '("Go ahead with this plan?"
                     "○ Trust: a repo's panel asks once before running"
                     "  any of its commands, remembered by the file's"
                     "  content, again if changed  edited"
                     "○ Ship it")))
    ;; Dropped: struck through on each of its lines.
    (let ((dropped (append plan `(:dropped (,long)))))
      (should (equal (seq-take (split-string (agent-ui-test-aue-draw dropped :width 46) "\n") 6)
                     '("Go ahead with this plan?"
                       "– Trust: a repo's panel asks once before"
                       "  running any of its commands, remembered by"
                       "  the file's content  dropped"
                       "○ Ship it"
                       "x drops the step at the cursor (again: back),")))
      (should (eq (agent-ui-test-aue-face-at dropped "the file's content" :width 46) 'agent-ui-steps-dropped)))
    ;; A note that doesn't fit after its step's last line: on a line of its
    ;; own, under its words.
    (let ((full "Update the docs and the skill for project panels"))
      (should (equal (seq-take (split-string (agent-ui-test-aue-draw `(:type "steps" :approve t :steps (,full) :dropped (,full))
                                                             :width 50)
                                             "\n")
                               3)
                     (list "Go ahead with this plan?"
                           (concat "– " full)
                           "  dropped"))))
    ;; From 10 columns, within the width, sub-steps and notes too.
    (let ((nested `(:type "steps" :approve t :dropped ("Ship it")
                    :steps ((:name ,long :detail "the panel's trust file" :steps ((:name ,long))) "Ship it"))))
      (dolist (width (number-sequence 10 40))
        (dolist (line (split-string (agent-ui-test-aue-draw nested :width width :still t) "\n"))
          (should (<= (string-width line) width)))))
    ;; Answered: whole too, its time and detail after it.
    (should (equal (agent-ui-test-aue-draw `(:type "steps" :approve t :answered "approved"
                                     :steps ((:name ,long :status "done" :seconds 41 :detail "ok") "Ship it"))
                                   :width 50)
                   (concat "✓ Trust: a repo's panel asks once before running\n"
                           "  any of its commands, remembered by the file's\n"
                           "  content  41s  ok\n"
                           "○ Ship it\n"
                           "✓ Approved")))))

(ert-deftest agent-ui-components/steps-a-plan-wrapped-step-keys ()
  "x and e on any line of a wrapped step (doom-mri)."
  (agent-ui-test-aue-canvas
    (let ((long agent-ui-test-aue-long-step))
      (agent-ui-show `(:id "plan" :type "steps" :approve t :steps (,long "Ship it")))
      (with-current-buffer canvas
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "content")
        ;; On its last line, not its first.
        (should-not (string-search "Trust" (buffer-substring (line-beginning-position) (line-end-position))))
        (agent-ui-drop-item)
        (should (equal (plist-get (agent-ui-get "plan") :dropped) (list long)))
        (goto-char (point-min))
        (search-forward "content")
        (cl-letf (((symbol-function 'read-string) (lambda (_prompt initial) (should (equal initial long))
                                                     "Trust: asked once")))
          (agent-ui-edit-item))
        (should (equal (plist-get (agent-ui-get "plan") :edits) `((:name ,long :text "Trust: asked once"))))))))

(ert-deftest agent-ui-components/steps-a-checklist-a-line-each ()
  "Without approve, a step stays on its line, its times and details in
columns, while they all fit; a name past half the width isn't cut for its
detail's sake when the line fits. A step too long: wrapped, as a plan's
(it was cut with …, every name cut to half the width: doom-1j3)."
  (should (equal (agent-ui-test-aue-draw '(:type "steps" :steps ((:name "Open on demand, the project's panels listed" :status "done") "b"))
                                 :width 30)
                 "✓ Open on demand, the\n  project's panels listed\n○ b"))
  ;; One step too long: the others whole too (they were cut to 49 columns
  ;; of 99), its time after it.
  (let ((text (agent-ui-test-aue-draw '(:type "steps" :steps ((:name "with: on a uses step (merge's suite)" :status "running" :seconds 665)
                                                      "run: a script, async, in the job's place, its environment the job's, its exit code its result"
                                                      "Exit 0 next; 1 to the job's agent (or on-fail's), with its output"
                                                      "Tests"))
                              :width 60)))
    (should-not (string-search "…" text))
    (should (string-search "its exit code its result" text))
    (should (string-search "with its\n  output" text))
    (should (string-match-p "\\`. with: on a uses step (merge's suite)  11m 05s\n" text))
    (dolist (line (split-string text "\n")) (should (<= (string-width line) 60))))
  ;; Columns kept while they all fit.
  (should (equal (agent-ui-test-aue-draw '(:type "steps" :steps ((:name "Trust: a repo's panel asks once" :status "done" :detail "ok")
                                                         "Lifecycle: polls paused while hidden")))
                 "✓ Trust: a repo's panel asks once       ok\n○ Lifecycle: polls paused while hidden")))

(ert-deftest agent-ui-components/steps-wrong ()
  (should (equal (agent-ui-test-aue-error '(:type "steps" :steps ("a" (:name "b" :status "paused"))))
                 "steps: step 2 has status \"paused\"; one of: pending, running, waiting, done, failed, skipped"))
  (should (equal (agent-ui-test-aue-error '(:type "steps" :steps ((:status "done"))))
                 "steps: step 1 has no name"))
  (should (equal (agent-ui-test-aue-error '(:type "steps" :steps ((:name "a" :state "done"))))
                 "steps: step 1 has \"state\": a step has name, status, detail, body, seconds, steps"))
  (should (string-match-p "step 1 is 3" (agent-ui-test-aue-error '(:type "steps" :steps (3)))))
  ;; A plan to approve.
  (should (string-match-p "approve is true, or"
                          (agent-ui-test-aue-error '(:type "steps" :steps ("a") :approve (:asks "x")))))
  (should (string-match-p "dropped is the steps' names"
                          (agent-ui-test-aue-error '(:type "steps" :steps ("a") :approve t :dropped (1)))))
  (should (string-match-p "edits are"
                          (agent-ui-test-aue-error '(:type "steps" :steps ("a") :approve t :edits ((:name "a"))))))
  (should (string-match-p "answered is \"approved\" or \"rejected\""
                          (agent-ui-test-aue-error '(:type "steps" :steps ("a") :approve t :answered "maybe")))))

(ert-deftest agent-ui-components/steps-their-times ()
  (let* ((now 100.0)
         (agent-ui-clock (lambda () now))
         (component (agent-ui--checked '(:type "steps" :steps ((:name "a" :status "running") "b")))))
    ;; Running: when it began, noted; its time counts.
    (should (equal (plist-get (car (plist-get component :steps)) :started) 100.0))
    (setq now 112.0)
    (should (string-match-p "a  12s" (agent-ui-test-aue-draw component)))
    ;; Done: how long it ran, kept; the next one starts.
    (setq now 141.0)
    (setq component (agent-ui--checked (agent-ui-append-to component '(:steps ((:name "a" :status "done")
                                                                            (:name "b" :status "running"))))))
    (should (equal (plist-get (car (plist-get component :steps)) :seconds) 41.0))
    (setq now 150.0)
    (should (equal (agent-ui-test-aue-draw component) "✓ a  41s\n● b   9s"))
    ;; Kept again (a panel's re-check): nothing changes.
    (should (equal (agent-ui--checked component) component))
    ;; A panel's: noted too.
    (should (equal (plist-get (car (plist-get (car (plist-get (agent-ui--checked '(:type "panel" :children ((:type "steps" :steps ((:name "c" :status "running"))))))
                                                              :children))
                                              :steps))
                              :started)
                   150.0))
    ;; Given: as given; a step not run has none.
    (should (equal (agent-ui-test-aue-draw '(:type "steps" :steps ((:name "x" :status "done" :seconds 125) "y")))
                   "✓ x  2m 05s\n○ y"))
    ;; Run again (failed, then running): timed anew, not with its first run's
    ;; time (it stayed frozen at 41s).
    (setq component (agent-ui--checked (agent-ui-append-to component '(:steps ((:name "a" :status "failed"))))))
    (setq now 300.0)
    (setq component (agent-ui--checked (agent-ui-append-to component '(:steps ((:name "a" :status "running"))))))
    (setq now 312.0)
    (should (string-match-p "a +12s" (agent-ui-test-aue-draw component)))
    (setq now 330.0)
    (setq component (agent-ui--checked (agent-ui-append-to component '(:steps ((:name "a" :status "done"))))))
    (should (equal (plist-get (car (plist-get component :steps)) :seconds) 30.0))))

(ert-deftest agent-ui-components/steps-times-in-milliseconds ()
  "A finished step under 1.5 s: its time in milliseconds, given or timed
(0.4 s was 0s, 1.2 s 1s); a running one's ticking time in seconds."
  (should (equal (agent-ui-test-aue-draw '(:type "steps" :steps ((:name "lint" :status "done" :seconds 0.4)
                                                         (:name "compile" :status "failed" :seconds 1.2)
                                                         (:name "test" :status "done" :seconds 41))))
                 "✓ lint      400ms\n✗ compile  1200ms\n✓ test        41s"))
  (let* ((now 100.0)
         (agent-ui-clock (lambda () now))
         (component (agent-ui--checked '(:type "steps" :steps ((:name "a" :status "running"))))))
    (setq now 100.25)
    (should (string-match-p "a  0s\\'" (agent-ui-test-aue-draw component)))
    (setq component (agent-ui--checked (agent-ui-append-to component '(:steps ((:name "a" :status "done"))))))
    (should (equal (agent-ui-test-aue-draw component) "✓ a  250ms"))))

(ert-deftest agent-ui-components/steps-on-one-line-each ()
  "A step's name or detail with line breaks (a failing test's): on its line
(it ran onto lines of its own, at column 0)."
  (let ((text (agent-ui-test-aue-draw '(:type "steps" :steps ((:name "Run the tests" :status "failed" :seconds 3
                                                      :detail "AssertionError: x\n  at foo.js:3")
                                                     (:name "Build\nthe app" :status "done" :seconds 2)
                                                     (:name "Ship")))
                              :width 70)))
    (should (= (length (split-string text "\n")) 3))
    (should (string-match-p "AssertionError: x⏎  at foo.js:3" text))
    (should (string-match-p "✓ Build⏎the app" text))))

(ert-deftest agent-ui-components/steps-fit-narrow-widths ()
  "From 10 columns, steps with times, details and sub-steps within the width
(the names' column was 10 at least, past it under ~20)."
  (let ((component (agent-ui--checked
                  '(:type "steps" :steps ((:name "Build the project" :status "done" :seconds 100)
                                          (:name "Run the tests" :status "failed" :seconds 3 :detail "2 failed")
                                          (:name "Deploy" :steps ((:name "upload" :steps ((:name "chunks" :steps ((:name "chunk 1")))))))))))
        (agent-ui-clock (lambda () 0.0)))
    (dolist (width (number-sequence 10 24))
      (dolist (line (split-string (agent-ui-test-aue-draw component :width width) "\n"))
        (should (<= (string-width line) width))))
    ;; Wide: the times shown.
    (should (string-match-p "1m 40s" (agent-ui-test-aue-draw component :width 60)))))

(ert-deftest agent-ui-components/steps-with-steps-of-their-own ()
  (let ((agent-ui-clock (lambda () 0.0)))
    ;; Drawn under theirs, indented; the names' column fits them.
    (should (equal (agent-ui-test-aue-draw '(:type "steps"
                                     :steps ((:name "Build" :status "done" :seconds 12
                                              :steps ((:name "compile" :status "done" :seconds 8)
                                                      (:name "link" :status "done" :seconds 4 :detail "ok")))
                                             "Publish")))
                   "✓ Build      12s\n  ✓ compile   8s\n  ✓ link      4s  ok\n○ Publish"))
    ;; Appended by their parent's name, at any depth; merged by name.
    (let* ((component '(:type "steps" :steps ((:name "Build" :steps ((:name "compile"))) "Publish")))
           (component (agent-ui-append-to component '(:steps ((:name "link" :parent "Build" :status "running")
                                                         (:name "ld" :parent "link")
                                                         (:name "Publish" :steps ("upload"))))))
           (steps (plist-get component :steps)))
      (should (equal (mapcar #'agent-ui-steps--name (plist-get (car steps) :steps)) '("compile" "link")))
      (should (equal (plist-get (cadr (plist-get (car steps) :steps)) :steps) '((:name "ld"))))
      (should (equal (plist-get (cadr steps) :steps) '("upload")))
      ;; A nested step merged by name: its own steps too.
      (let ((merged (agent-ui-append-to component '(:steps ((:name "Build" :steps ((:name "compile" :status "done"))))))))
        (should (equal (plist-get (car (plist-get (car (plist-get merged :steps)) :steps)) :status) "done"))
        (should (= (length (plist-get (car (plist-get merged :steps)) :steps)) 2)))
      ;; Running deep down: it animates.
      (should (agent-ui-animated-p (agent-ui--checked component)))
      ;; A parent not there: said so.
      (should (string-match-p "no step \"nope\" to put \"x\" under"
                              (agent-ui-error-message
                               (should-error (agent-ui-append-to component '(:steps ((:name "x" :parent "nope"))))
                                             :type 'agent-ui-error)))))
    ;; Wrong ones: where they are.
    (should (equal (agent-ui-test-aue-error '(:type "steps" :steps ((:name "a" :steps ((:name "b" :status "x"))))))
                   "steps: step 1.1 has status \"x\"; one of: pending, running, waiting, done, failed, skipped"))
    (should (string-match-p "step 1 has seconds -1" (agent-ui-test-aue-error '(:type "steps" :steps ((:name "a" :seconds -1))))))
    (should (string-match-p "steps 5 deep: 4 at most"
                            (agent-ui-test-aue-error '(:type "steps" :steps ((:name "1" :steps ((:name "2" :steps ((:name "3" :steps ((:name "4" :steps ("5")))))))))))))))

;; A step's body: folded under ▸, RET unfolding it (Markdown) under it.
(ert-deftest agent-ui-components/steps-a-step-s-body-unfolds ()
  "A step with a body: ▸ before its detail, its body nowhere; its lines a
button. OPEN naming it: ▾, its body under it, drawn as Markdown, indented.
A body not text: refused."
  (let* ((component '(:type "steps" :steps ((:name "green" :status "done" :detail "20:47 · Not fixed"
                                           :body "Not fixed: **cause** unknown.\n\n- one\n- two")
                                          (:name "docs" :status "done" :detail "Wrote it"))))
         (folded (agent-ui-render component (agent-ui-context :width 60)))
         (open (agent-ui-test-aue-draw (plist-put (copy-sequence component) :open '("green")))))
    (should (string-search "▸ 20:47 · Not fixed" folded))
    (should-not (string-search "one" folded))
    (should-not (string-search "▸ Wrote it" folded))
    (should (equal (get-text-property (string-search "green" folded) 'help-echo folded) "RET: unfold it"))
    (should-not (get-text-property (string-search "docs" folded) 'agent-ui-action folded))
    (should (string-search "▾ 20:47 · Not fixed" open))
    (should (string-match-p "\n  Not fixed: cause unknown\\." open))
    (should (string-match-p "\n  .*one\n  .*two" open)))
  (should (string-match-p "body" (agent-ui-test-aue-error '(:type "steps" :steps ((:name "a" :body 3)))))))

;;; agent-ui-steps-tests.el ends here
