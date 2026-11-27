;;; agent-ui-bug-tests.el --- Tests for Agent UI: bug  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-bug.el, config/beads/file.el and their wiring
;; (agent-ui.el): a bug in Agent UI itself filed from any session into
;; its own issues. The report (what's wrong, the repro drawn, the live
;; component, the environment); filing it through `agent-ui-bug-function'
;; (stood in for); not filed, the report given back; the agent's way (a
;; request) and the user's (b on a component). Then filing into real Beads
;; issues: bd, in temp repos with a temp HOME (never this config's issues).

;;; Code:

(require 'agent-ui-test-helper)


;; ====== HELPERS ======

(defmacro agent-ui-test-aub (&rest body)
  "BODY with a canvas of its own (`canvas', the default: killed after), no
window shown, no sessions; the filing stood in for: what it was given in
`filed' (TITLE DESCRIPTION LIBRARY NEW, the latest first), its answer
`answer' (a plist, or an error's message to signal), the issues filed in
`hooked'."
  (declare (indent 0))
  `(let* ((agent-ui-default-canvas (make-temp-name "bug-"))
          (agent-ui-display-function #'ignore)
          (canvas (agent-ui-canvas))
          (filed nil)
          (hooked nil)
          (answer '(:id "lib-1" :new t :dir "/lib/"))
          (agent-ui-bug-report-url nil)
          ;; Each report filed (the same one twice: see its own test).
          (agent-ui-bug-same-within 0)
          (agent-ui--bugs-filed (make-hash-table :test #'equal))
          (agent-ui-bug-function (lambda (title description library new)
                                   (push (list title description library new) filed)
                                   (if (stringp answer) (error "%s" answer) answer)))
          (agent-ui-bug-filed-functions (list (lambda (&rest args) (push args hooked)))))
     (ignore filed hooked answer)
     (cl-letf (((symbol-function 'agent-ui--sessions) #'ignore))
       (unwind-protect (progn ,@body)
         (kill-buffer canvas)))))

(defun agent-ui-test-aub-request (payload &optional cwd)
  "bin/agent-ui bug's reply (parsed) to PAYLOAD (JSON text), from CWD."
  (let ((dir (make-temp-file (agent-ui-test-tmp-file "aub-") t)))
    (with-temp-file (expand-file-name "request" dir)
      (insert (format "bug\n\n\n%s\n" (or cwd ""))))
    (with-temp-file (expand-file-name "payload" dir) (insert payload))
    (should (eq (agent-ui-request dir) t))
    (agent-ui-parse-json (with-temp-buffer
                           (insert-file-contents (expand-file-name "reply" dir))
                           (buffer-string)))))

(defconst agent-ui-test-aub-props
  '(:title "a tile's label overlaps the next tile" :description "Long labels run into the next tile."
    :expected "The label cut inside its tile" :workaround "Shorter labels" :component "kpis"
    :repro (:type "text" :text "repro"))
  "A bug, as the agent tells of it.")

;; ====== THE REPORT ======

(ert-deftest agent-ui-bug/the-report ()
  "Its title led by \"Agent UI: \"; what's wrong, expected, the workaround;
the repro (its JSON, drawn at the pane's width); the live component (its
JSON, its drawing); the environment."
  (agent-ui-test-aub
    (agent-ui-show '(:id "kpis" :type "text" :text "Coverage 87%"))
    (pcase-let ((`(,title . ,description)
                 (agent-ui-bug-report agent-ui-test-aub-props :canvas canvas :session "S" :cwd "/work/proj/"
                                      :by "the agent")))
      (should (equal title "Agent UI: a tile's label overlaps the next tile"))
      (dolist (part (list "Long labels run into the next tile."
                          "**Expected:** The label cut inside its tile"
                          "**Workaround:** Shorter labels"
                          "## Repro\n\n```json\n{\"type\":\"text\",\"text\":\"repro\"}\n```"
                          "Drawn as text at 80 columns:\n\n```text\nrepro\n```"
                          "## The component as shown: kpis (text)\n\n```json\n{\"id\":\"kpis\",\"type\":\"text\",\"text\":\"Coverage 87%\"}\n```"
                          "```text\nCoverage 87%\n```"
                          "## Environment\n\n- Filed by the agent (session S)"
                          "- A terminal, the pane 80 columns wide"
                          (format "- Emacs %s" emacs-version)
                          (concat "- Agent UI: " (abbreviate-file-name agent-ui-library-directory) ", at ")
                          "- The session's directory: /work/proj/"))
        (should (string-search part description)))
      ;; Its commit: git's.
      (should (string-match-p "- Agent UI: .*, at [0-9a-f]\\{7,\\}" description))
      (should-not (string-search "Drawing it fails" description)))
    ;; Already led so: as it is; on one line. Nothing but what's wrong.
    (pcase-let ((`(,title . ,description)
                 (agent-ui-bug-report '(:title "Agent UI: two\nlines" :description "Only this."))))
      (should (equal title "Agent UI: two lines"))
      (should (string-prefix-p "Only this.\n\n## Environment\n\n- Filed by the agent\n" description))
      (should-not (string-search "## Repro" description)))))

(ert-deftest agent-ui-bug/drawing-errors-said ()
  "A component whose drawing fails: its error said, under its drawing (the
error drawn in its place); a fence longer than any backticks in it."
  (agent-ui-test-aub
    (let ((agent-ui--types (copy-hash-table agent-ui--types)))
      (agent-ui-define buggy "Fails." :text (lambda (_p _c) (error "Boom")))
      (agent-ui-show '(:id "b" :type "buggy"))
      (let ((description (cdr (agent-ui-bug-report '(:title "x" :description "y" :component "b"
                                                     :repro (:type "buggy"))
                                                   :canvas canvas))))
        (should (string-search "```text\n⚠ Boom\n```\n\nDrawing it fails: Boom" description))
        (should (= (cl-count-if (lambda (_) t) (split-string description "Drawing it fails: Boom")) 3))))
    (should (equal (agent-ui--fence "text" "a ``` b") "````text\na ``` b\n````"))))

(ert-deftest agent-ui-bug/wrong-reports-refused ()
  (agent-ui-test-aub
    (cl-flet ((err (props) (agent-ui-error-message
                            (should-error (agent-ui-bug-report props :canvas canvas) :type 'agent-ui-error))))
      (should (equal (err '(:description "y")) "bug: title is required (text)"))
      (should (equal (err '(:title "x" :description " ")) "bug: description is required (text)"))
      (should (string-match-p "unknown property \"frob\"; a bug has: title, description, expected"
                              (err '(:title "x" :description "y" :frob 1))))
      (should (string-match-p "expected must be text" (err '(:title "x" :description "y" :expected 3))))
      (should (string-match-p "repro is a component" (err '(:title "x" :description "y" :repro "z"))))
      (should (string-match-p "unknown type \"nope\"" (err '(:title "x" :description "y" :repro (:type "nope")))))
      (should (string-match-p "no component \"gone\"" (err '(:title "x" :description "y" :component "gone"))))
      (should (string-match-p "give a JSON object" (err '(1 2)))))))

;; ====== FILING IT ======

(ert-deftest agent-ui-bug/filed ()
  "Filed by `agent-ui-bug-function': its title, its description, the
library's directory (its issues found from there), whether new anyway."
  (agent-ui-test-aub
    (agent-ui-show '(:id "kpis" :type "text" :text "87%"))
    (should (equal (agent-ui-file-bug agent-ui-test-aub-props :canvas canvas)
                   '(:id "lib-1" :new t :dir "/lib/" :title "Agent UI: a tile's label overlaps the next tile")))
    (pcase-let ((`(,title ,description ,library ,new) (car filed)))
      (should (equal title "Agent UI: a tile's label overlaps the next tile"))
      (should (string-search "## The component as shown: kpis" description))
      (should (equal library agent-ui-library-directory))
      (should-not new))
    (should (equal (car hooked) '("lib-1" "Agent UI: a tile's label overlaps the next tile" t "/lib/")))
    ;; New anyway: said to it.
    (agent-ui-file-bug '(:title "x" :description "y" :new t))
    (should (nth 3 (car filed)))))

(ert-deftest agent-ui-bug/not-filed-the-report-given-back ()
  "Nothing files them, or it fails (no issues set up, no bd): nothing filed,
an error saying why, to report by hand (where, if known), the report
written."
  (agent-ui-test-aub
    (let ((agent-ui-bug-function nil))
      (let ((err (should-error (agent-ui-file-bug '(:title "x" :description "y")) :type 'agent-ui-bug-not-filed)))
        (should (equal (nth 1 err) "Agent UI's bug wasn't filed: nothing files them here (agent-ui-bug-function). Report it by hand: the report is written"))
        (should (string-prefix-p "# Agent UI: x\n\ny\n\n## Environment\n" (nth 2 err)))))
    (setq answer "no Beads issues (.beads) in ~/lib or above")
    (let* ((agent-ui-bug-report-url "https://example.com/issues")
           (err (should-error (agent-ui-file-bug '(:title "x" :description "y")) :type 'agent-ui-bug-not-filed)))
      (should (equal (nth 1 err) "Agent UI's bug wasn't filed: no Beads issues (.beads) in ~/lib or above. Report it by hand at https://example.com/issues: the report is written")))
    (should-not hooked)))

;; ====== THE AGENT'S WAY ======

(ert-deftest agent-ui-bug/the-agents-request ()
  "bin/agent-ui bug: filed (the issue, whether new; a note when it went to
a similar open one); not filed: why, and the report; a wrong one: why."
  (agent-ui-test-aub
    (agent-ui-show '(:id "kpis" :type "text" :text "87%"))
    (should (equal (agent-ui-test-aub-request "{\"title\":\"x\",\"description\":\"y\",\"component\":\"kpis\"}" "/work/proj/")
                   '(:ok t :issue "lib-1" :new t)))
    (pcase-let ((`(,_ ,description ,_ ,_) (car filed)))
      (should (string-search "- Filed by the agent" description))
      (should (string-search "- The session's directory: /work/proj/" description))
      (should (string-search "## The component as shown: kpis" description)))
    (setq answer '(:id "lib-1" :new nil :dir "/lib/"))
    (let ((reply (agent-ui-test-aub-request "{\"title\":\"x\",\"description\":\"y\"}")))
      (should (eq (plist-get reply :new) :false))
      (should (string-match-p "A similar bug is open" (plist-get reply :note))))
    (setq answer "bd isn't installed")
    (let ((reply (agent-ui-test-aub-request "{\"title\":\"x\",\"description\":\"y\"}")))
      (should (eq (plist-get reply :ok) :false))
      (should (string-match-p "wasn't filed: bd isn't installed. Report it by hand" (plist-get reply :error)))
      (should (string-prefix-p "# Agent UI: x\n\ny\n" (plist-get reply :report))))
    (should (equal (agent-ui-test-aub-request "{\"description\":\"y\"}")
                   '(:ok :false :error "bug: title is required (text)")))))

(ert-deftest agent-ui-bug/the-same-report-filed-once ()
  "The agent's same report again (it was told Emacs didn't answer, filing
took long): not filed again, the issue it was filed as said; another
report, filed (doom-ht6.146)."
  (agent-ui-test-aub
    (let ((agent-ui-bug-same-within 600))
      (should (equal (agent-ui-test-aub-request "{\"title\":\"x\",\"description\":\"y\"}")
                     '(:ok t :issue "lib-1" :new t)))
      (setq answer '(:id "lib-2" :new t :dir "/lib/"))
      (let ((reply (agent-ui-test-aub-request "{\"title\":\"x\",\"description\":\"y\"}")))
        (should (equal (plist-get reply :issue) "lib-1"))
        (should (string-match-p "already filed" (plist-get reply :note))))
      (should (= (length filed) 1))
      (should (equal (plist-get (agent-ui-test-aub-request "{\"title\":\"z\",\"description\":\"y\"}") :issue)
                     "lib-2"))
      (should (= (length filed) 2)))))

;; ====== THE USER'S WAY ======

(ert-deftest agent-ui-bug/the-users-b ()
  "b on a component: what's wrong, what you expected; filed with the component
\(RET right after opens it); not filed: the report shown and copied."
  (agent-ui-test-aub
    (agent-ui-show '(:id "t" :type "text" :text "Cut off"))
    (should (eq (keymap-lookup agent-ui-canvas-mode-map "b") #'agent-ui-report-bug))
    (with-current-buffer canvas
      (agent-ui--flush)
      (goto-char (point-min))
      (search-forward "Cut")
      (let ((answers (list "it's cut off\nat 40 columns" "all of it"))
            (said nil) (map nil) (opened nil))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                  ((symbol-function 'message) (lambda (&rest args) (setq said (apply #'format args))))
                  ((symbol-function 'set-transient-map) (lambda (m &rest _) (setq map m)))
                  (agent-ui-open-issue-function (lambda (id dir) (setq opened (list id dir)))))
          (call-interactively #'agent-ui-report-bug)
          (funcall (keymap-lookup map "RET")))
        (pcase-let ((`(,title ,description ,_ ,_) (car filed)))
          (should (equal title "Agent UI: it's cut off"))
          (should (string-prefix-p "it's cut off\nat 40 columns\n\n**Expected:** all of it" description))
          (should (string-search "## The component as shown: t (text)" description))
          (should (string-search (format "- Filed by the user (session %s)" agent-ui-default-canvas) description)))
        (should (equal said "Filed lib-1: Agent UI: it's cut off (RET: open it)"))
        (should (equal opened '("lib-1" "/lib/")))))
    ;; Not filed: the report in a buffer, copied.
    (setq answer "no Beads issues (.beads) in ~/lib or above")
    (with-current-buffer canvas
      (let ((answers (list "wrong" "")) (kill-ring nil))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                  ((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (call-interactively #'agent-ui-report-bug))
        (let ((report (with-current-buffer "*Agent UI: bug report*" (buffer-string))))
          (should (string-prefix-p "# Agent UI: wrong\n\nwrong\n\n## The component as shown" report))
          (should (equal (car kill-ring) report)))
        (kill-buffer "*Agent UI: bug report*")))
    ;; Nothing said: nothing filed.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) " ")))
      (should-error (call-interactively #'agent-ui-report-bug) :type 'user-error))))

;; ====== INTO REAL ISSUES ======


(defun agent-ui-test-aub-issues (dir &rest args)
  "DIR's issues (bd list --json ARGS, run there without the BEADS_DIR a test
set for another project's session)."
  (let ((default-directory dir)
        (process-environment (seq-remove (lambda (v) (string-prefix-p "BEADS_DIR=" v)) process-environment)))
    (json-parse-string (with-temp-buffer
                         (apply #'call-process "bd" nil '(t nil) nil "list" "--json" "--all" "--limit" "0" args)
                         (buffer-string))
                       :object-type 'plist :array-type 'list :null-object nil)))




;;; agent-ui-bug-tests.el ends here
