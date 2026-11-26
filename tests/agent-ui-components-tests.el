;;; agent-ui-components-tests.el --- Tests for Agent UI: what all its components share  -*- lexical-binding: t; -*-

;;; Commentary:

;; What all of Agent UI's component types share: the catalog, captions,
;; buttons, numbers, long lines and labels read whole, a file relative to
;; the agent's directory.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/the-types ()
  (should (equal (agent-ui-types) '(activity chart choice code compare confirm countdown diff files form gauge graph heatmap html image log markdown math mermaid panel progress rank slider stats steps table tags text timeline todo)))
  ;; Each with an example (checked when defined), drawn without an error.
  (dolist (name (agent-ui-types))
    (let* ((type (agent-ui-type name))
           (example (append (list :type (symbol-name name)) (agent-ui-type-example type))))
      (should (agent-ui-type-example type))
      (should (equal (agent-ui-type-file type)
                     (expand-file-name (format "agent-ui-%s.el" name) agent-ui-test-root)))
      (dolist (width '(20 60 200))
        (let ((text (agent-ui-render example (agent-ui-context :width width))))
          (should-not (string-match-p "⚠" text))
          ;; No line wider than the width.
          (dolist (line (split-string text "\n"))
            (should (equal (list name width line (string-width line))
                           (list name width line (min (string-width line) (max width 30)))))))))))

;; doom-ht6.29
(ert-deftest agent-ui-components/no-issues-board ()
  "The issues board is gone (Beads' own list shows the same): an issues
component is refused as any unknown type, and nothing of it is left."
  (should (string-match-p "\\`unknown type \"issues\"; types: activity, chart, "
                          (agent-ui-test-aue-error '(:type "issues" :parent "doom-ht6"))))
  (should-not (apropos-internal "\\`agent-ui-issues"
                                (lambda (symbol) (or (fboundp symbol) (boundp symbol))))))

(ert-deftest agent-ui-components/a-caption-above-any-component ()
  "CAPTION: a muted line above a component (under its title), as a log's
counts: cut to the width, its newlines spaces. None, nothing more drawn
(a component drawn as it was). Not text: refused."
  (let ((text (agent-ui-render '(:type "text" :title "Its files" :caption "12 files changed" :text "a.el")
                               (agent-ui-context :width 40))))
    (should (equal (substring-no-properties text) "Its files\n12 files changed\na.el"))
    (should (eq (get-text-property (string-search "12" text) 'face text) 'agent-ui-muted)))
  (should (equal (agent-ui-test-aue-draw '(:type "text" :caption "a\nb" :text "x")) "a b\nx"))
  (should (equal (agent-ui-test-aue-draw '(:type "text" :text "x")) "x"))
  (should (string-suffix-p "…" (car (split-string (agent-ui-test-aue-draw (list :type "text" :caption (make-string 80 ?c) :text "x"))
                                                 "\n"))))
  (should (string-match-p "a caption is text"
                          (agent-ui-error-message
                           (should-error (agent-ui--checked '(:type "text" :caption 3 :text "x")) :type 'agent-ui-error)))))

(ert-deftest agent-ui-components/small-numbers-read-apart ()
  "Values under 0.01: a histogram's bins, a progress bar's counts read apart
\(with 2 decimals bins all read \"0.01–0.01 s\", 0.004 of 0.01 read \"0/0.01\")."
  (let ((text (agent-ui-test-aue-draw '(:type "chart" :kind "histogram" :unit "s"
                                :values (0.0112 0.0123 0.0131 0.0135 0.0142 0.0151 0.0118 0.0127))
                              :width 60)))
    (should-not (string-match-p "0.01–0.01 s" text))
    (should (string-match-p "0.0112–" text)))
  (should (string-match-p "0.004/0.01 GB" (agent-ui-test-aue-draw '(:type "progress" :value 0.004 :max 0.01 :unit "GB"))))
  (should (string-match-p "0.00005/0.0001" (agent-ui-test-aue-draw '(:type "progress" :value 0.00005 :max 0.0001)))))

(ert-deftest agent-ui-components/a-file-relative-to-the-agent ()
  (let ((agent-ui-file-directory "/work/proj/"))
    (should (equal (plist-get (agent-ui-check "image" '(:file "shots/a.png")) :file) "/work/proj/shots/a.png"))
    (should (equal (plist-get (agent-ui-check "image" '(:file "/abs/a.png")) :file) "/abs/a.png")))
  (should (string-match-p "file must be a file's name"
                          (agent-ui-test-aue-error '(:type "image" :file 3)))))

(ert-deftest agent-ui-components/a-button ()
  (let* ((pressed nil)
         (text (agent-ui-button "open" (lambda () (setq pressed t)) "RET: open it")))
    (should (eq (get-text-property 0 'keymap text) agent-ui-button-map))
    (should (equal (get-text-property 0 'help-echo text) "RET: open it"))
    (with-temp-buffer
      (insert "x " text)
      (goto-char 4)
      (should (eq (key-binding (kbd "RET")) #'agent-ui-button-press))
      (agent-ui-button-press)
      (should pressed)
      (goto-char 1)
      (should-error (agent-ui-button-press) :type 'user-error))))

;; doom-nwj.81
(ert-deftest agent-ui-components/a-folder-isnt-a-file ()
  "A folder given as a code or html component's file is said not to be one
(reading it failed: \"Read error: Is a directory\")."
  (let ((dir (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "proj-") t))))
    (unwind-protect
        (progn
          (should (equal (agent-ui-test-aue-draw (list :type "code" :file dir :from 1) :width 300)
                         (concat (abbreviate-file-name dir) ": not a file")))
          (should (equal (agent-ui-test-aue-draw (list :type "html" :file dir) :width 300)
                         (concat "◫ " (file-name-nondirectory dir) "\n" (abbreviate-file-name dir) "  (not a file)")))
          ;; Missing: as before.
          (should (string-suffix-p ": not found" (agent-ui-test-aue-draw (list :type "code" :file (concat dir "x.c")) :width 300)))
          (should (string-suffix-p "  (not found)" (agent-ui-test-aue-draw (list :type "html" :file (concat dir "x.html")) :width 300))))
      (delete-directory dir t))))

(ert-deftest agent-ui-components/pressed-again-before-a-redraw ()
  "Two options pressed at once, no redraw between: both picked (the second
press acted on the drawing before the first's change, undoing it)."
  (agent-ui-test-aue-canvas
    (let ((agent-ui-action-function #'ignore))
      (agent-ui-show '(:id "c" :type "choice" :question "Which?" :options ("Alpha" "Beta") :multiple t))
      (with-current-buffer canvas
        (agent-ui--flush)
        (dolist (option '("Alpha" "Beta"))
          (goto-char (point-min))
          (search-forward option)
          (goto-char (match-beginning 0))
          (agent-ui-button-press))
        (should (equal (plist-get (agent-ui-get "c") :selected) '("Alpha" "Beta")))))))

(ert-deftest agent-ui-components/options-wrapped-never-cut ()
  "Choice's, rank's and todo's labels and details, and compare's labels, are
wrapped at every width, never cut with …, their lines hanging under the
label's start (a wide canvas cut a long label at 50, its detail too; a rank
always cut its labels)."
  (let ((choice '(:type "choice" :question "Which fix?"
                  :options ((:label "Change the test's expected message to the new one"
                             :detail "keeps the new error text, which reads better for users who hit it")
                            (:label "Revert" :detail "as it was"))))
        (rank '(:type "rank" :question "First?"
                :items ("supercalifragilisticexpialidocious handler refactor"
                        (:label "Fix the parser" :detail "the root cause of the three failing tests") "Docs")))
        (todo '(:type "todo" :items ((:label "Write the migration for the new users table and backfill it"
                                      :done t :by "user")
                                     (:label "Docs"))))
        (compare '(:type "compare" :question "Which?"
                   :options ((:label "A: the loop version, explicit and step by step"
                              :component (:type "text" :text "for x in xs: t += x"))
                             (:label "B: sum" :component (:type "text" :text "t = sum(xs)"))))))
    (dolist (component (list choice rank todo compare))
      (dolist (width '(24 30 40 60 100))
        (let ((text (agent-ui-test-aue-draw component :width width)))
          (should-not (string-search "…" text))
          (dolist (line (split-string text "\n"))
            (should (<= (string-width line) width)))
          ;; Every word there (whole, those narrower than the width).
          (dolist (word (append '("expected" "users" "hit" "refactor" "failing" "backfill" "step")
                                (and (>= width 40) '("supercalifragilisticexpialidocious"))))
            (when (string-search word (format "%S" component))
              (should (string-search word (replace-regexp-in-string "\n *" " " text))))))))
    ;; Continuation lines under the label's start; details in their column.
    (should (string-prefix-p
             (concat "Which fix?\n"
                     " ( ) Change the test's expected message to the new one  keeps the new error text, which reads better\n"
                     "                                                        for users who hit it\n"
                     " ( ) Revert                                             as it was\n")
             (agent-ui-test-aue-draw choice :width 100)))
    (should (string-search (concat " 1. supercalifragilisticexpialidocious\n"
                                   "    handler refactor\n"
                                   " 2. Fix the parser  the root cause of\n"
                                   "                    the three failing\n"
                                   "                    tests\n")
                           (agent-ui-test-aue-draw rank :width 40)))
    (should (string-prefix-p (concat " [x] Write the migration for the     you\n"
                                     "     new users table and backfill\n"
                                     "     it\n")
                             (agent-ui-test-aue-draw todo :width 40)))
    (should (string-search (concat " ( ) A: the loop version, explicit and\n"
                                   "     step by step\n")
                           (agent-ui-test-aue-draw compare :width 40)))))

;; doom-nwj.80
(ert-deftest agent-ui-components/notes-and-details-are-text ()
  "A file's note, a code mark's note and a choice option's detail must be
text: refused when shown (they were accepted, then drawing them failed:
\"Wrong type argument: stringp, 5\")."
  (should (string-match-p "files: file 2's note must be text"
                          (agent-ui-test-aue-error '(:type "files" :files ("b.c" (:path "a.c" :note 5))))))
  (should (string-match-p "code: mark 1's note must be text"
                          (agent-ui-test-aue-error '(:type "code" :code "x" :marks ((:line 1 :note 5))))))
  (should (string-match-p "choice: option 2's detail must be text"
                          (agent-ui-test-aue-error '(:type "choice" :question "Q?" :options ("a" (:label "b" :detail 5))))))
  ;; Shown: refused whole, nothing shown.
  (agent-ui-test-aue-canvas
    (should-error (agent-ui-show '(:id "f" :type "files" :files ((:path "a.c" :note 5)))) :type 'agent-ui-error)
    (should-error (agent-ui-get "f") :type 'agent-ui-error))
  ;; Text: as before.
  (should (equal (agent-ui-test-aue-draw '(:type "files" :files ((:path "a.c" :note "ok")))) "  a.c  ok")))

(ert-deftest agent-ui-components/answers-always-sent ()
  "A question's answer goes straight to the agent: none takes submit (it
only put the answer into the prompt), nor approve, accept or select
(doom-ik2). Actions, rows' and chips' prompts keep theirs: suggestions."
  (dolist (component '((:type "choice" :question "q" :options ("a") :submit :false)
                     (:type "compare" :question "q" :submit :false
                      :options ((:label "a" :component (:type "text" :text "x")) (:label "b" :component (:type "text" :text "y"))))
                     (:type "confirm" :question "q" :submit :false)
                     (:type "form" :question "q" :fields ((:name "a")) :submit :false)
                     (:type "rank" :question "q" :items ("a" "b") :submit :false)
                     (:type "slider" :label "x" :min 0 :max 10 :submit :false)
                     (:type "todo" :items ("a") :submit :false)
                     (:type "steps" :steps ("a") :approve (:question "q" :submit :false))
                     (:type "diff" :diff "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n" :accept (:question "q" :submit :false))
                     (:type "table" :columns ("a") :rows (("x")) :select (:question "q" :submit :false))))
    (should-error (agent-ui-check (plist-get component :type) component) :type 'agent-ui-error))
  (should (agent-ui-check "text" '(:type "text" :text "x" :actions ((:label "Go" :prompt "go" :submit :false))))))

(ert-deftest agent-ui-components/select-as-its-types-say ()
  "A select's keys as agent-ui types lists them, each taken: question,
multiple, note; no submit (its answer is sent at once) (doom-ht6.64)."
  (dolist (type '(table files tags))
    (ert-info ((symbol-name type))
      (let ((doc (agent-ui-prop-doc (cl-find :select (agent-ui-type-props (agent-ui-type type)) :key #'agent-ui-prop-key))))
        (should-not (string-search "submit" doc))
        (should (string-search "\"question\", \"multiple\", \"note\"" doc)))))
  (should-not (agent-ui-ask-select-check "table" '(:question "Q?" :multiple t :note t))))

(ert-deftest agent-ui-components/numbers-never-cut ()
  "No number cut with … at 24 columns: a line chart's axis (its unit over
it, the numbers compact: \"34567…\" for 3456789), a bar's values, a
histogram's bins (rounded, their unit over them: all \"200.8–4…\"), a stats
tile's value (compact, or smaller: \"1234567…\", \"29 seco…\"); text and GUI."
  (let ((line '(:type "chart" :unit "requests" :height 4 :values (1234567 2345678 3456789 123)))
        (bars '(:type "chart" :kind "bar" :unit "requests" :labels ("a" "b") :values (1234567 3456789)))
        (histogram '(:type "chart" :kind "histogram" :unit "ms" :bins 5
                     :values (12 15 18 22 25 31 33 41 58 90 1000 1004)))
        (stats '(:type "stats" :figures ((:label "Tests" :value 123456789)
                                         (:label "Build" :value 29 :unit "seconds" :change -12 :good "down")))))
    (dolist (component (list line bars histogram stats))
      (dolist (width '(18 24 30))
        (let ((text (agent-ui-test-aue-draw component :width width)))
          (should-not (string-search "…" text))
          (dolist (row (split-string text "\n"))
            (should (<= (string-width row) width))))
        (let ((svg (agent-ui-test-aue-svg component width)))
          (should-not (string-search "&#8230;" svg)))))
    (should (string-prefix-p "requests\n3.46M ┤" (agent-ui-test-aue-draw line :width 18)))
    (should (string-prefix-p "requests\n3456789 ┤" (agent-ui-test-aue-draw line :width 30)))
    (should (string-prefix-p "ms\n10–210    █" (agent-ui-test-aue-draw histogram :width 24)))
    (should (string-match-p "\n810–1000  █+ +2\\'" (agent-ui-test-aue-draw histogram :width 24)))
    (should (string-match-p ">123456789</text>" (agent-ui-test-aue-svg stats 24)))
    (should (string-match-p ">29 seconds</text>" (agent-ui-test-aue-svg stats 24)))
    ;; Wide: as before, the unit with each number.
    (should (string-prefix-p "3456789 requests ┤" (agent-ui-test-aue-draw line :width 60)))
    (should (string-prefix-p "10–210 ms  " (agent-ui-test-aue-draw histogram :width 60)))))

;; doom-nwj.84
(ert-deftest agent-ui-components/negative-show-refused ()
  "A log's show below 0 is refused (it showed no lines)."
  (should (string-match-p "log: show must be 0 or more, not -3"
                          (agent-ui-test-aue-error '(:type "log" :lines "a\nb" :show -3))))
  ;; 0: allowed (the counts only).
  (should (equal (agent-ui-test-aue-draw '(:type "log" :lines "a\nb" :show 0)) "2 lines")))

(ert-deftest agent-ui-components/svg-text-at-its-weight ()
  "The SVGs' text at `agent-ui-svg-font-weight': SemiBold on macOS (librsvg
doesn't thicken it as macOS does the editor's: thin and washed out beside it),
regular elsewhere; a chart's, a graph's, a gauge's; a bold one stays bold."
  (should (eql (eval (car (get 'agent-ui-svg-font-weight 'standard-value)) t)
               (if (eq system-type 'darwin) 600 400)))
  (let ((agent-ui-svg-font-weight 600))
    (dolist (component '((:type "chart" :kind "bar" :labels ("a" "b") :values (1 2))
                       (:type "graph" :nodes ("a" "b") :edges (("a" "b")))
                       (:type "timeline" :tasks ((:name "build" :start 0 :duration 8)))
                       (:type "gauge" :value 3 :max 10)))
      (let ((svg (agent-ui-test-aue-svg component 60)))
        (should (string-match-p "<text [^>]*font-weight=\"600\"" svg))
        (should-not (string-match-p "font-weight=\"[^\"]*\"[^>]*font-weight=" svg))))
    (let ((svg (with-temp-buffer
                 (let ((s (svg-create 10 10)))
                   (agent-ui-chart--svg-text s (agent-ui-context :graphic t) "x" 0 0 :font-weight "bold")
                   (svg-print s)
                   (buffer-string)))))
      (should (string-search "font-weight=\"bold\"" svg))
      (should-not (string-search "font-weight=\"600\"" svg)))))

(ert-deftest agent-ui-components/long-lines-wrapped ()
  "A log's, code's or a diff's line too long for the pane is wrapped, every
word of it read (it was cut with …, its rest nowhere; doom-c2o): a log's
next lines indented 2, in its level's face; code's and a diff's after the
gutter, its number blank, under the line's indent; a diff's tint on each in
the GUI; `agent-ui-max-cell-lines' lines at most, the last ending with …"
  (let* ((long "the quick brown fox jumps over the lazy dog, again and again, until the very end")
         (log (list :type "log" :lines (list "12:01:03 INFO  up" (concat "12:01:09 ERROR db: " long) "12:01:10 WARN  slow")))
         (code (list :type "code" :language "python" :code (concat "def f():\n    x = call(\"" long "\")\n    return x")))
         (diff (list :type "diff" :diff (concat "--- a/f.py\n+++ b/f.py\n@@ -1,2 +1,2 @@\n def f():\n-    x = 1\n+    x = call(\"" long "\")\n"))))
    (dolist (width '(30 40 60 98))
      (dolist (component (list log code diff))
        (let ((text (agent-ui-test-aue-draw component :width width)))
          (should-not (string-search "…" text))
          (should (string-search "end" text))
          (dolist (line (split-string text "\n")) (should (<= (string-width line) width))))))
    (should (equal (agent-ui-test-aue-draw log)
                   (concat "1 error · 1 warning · 3 lines\n12:01:03 INFO  up\n"
                           "12:01:09 ERROR db: the quick brown fox jumps over the lazy\n"
                           "  dog, again and again, until the very end\n12:01:10 WARN  slow")))
    (should (eq (agent-ui-test-aue-face-at log "dog, again") 'agent-ui-error))
    (should (equal (agent-ui-test-aue-draw code)
                   (concat "1 │ def f():\n"
                           "2 │     x = call(\"the quick brown fox jumps over the lazy\n"
                           "  │     dog, again and again, until the very end\")\n"
                           "3 │     return x")))
    (should (equal (agent-ui-test-aue-draw diff)
                   (concat "▾ f.py  +1 −1\n  @@ -1,2 +1,2 @@\n      1   def f():\n        −     x = 1\n"
                           "      2 +     x = call(\"the quick brown fox jumps over the\n"
                           "              lazy dog, again and again, until the very\n"
                           "              end\")")))
    (should (eq (agent-ui-test-aue-face-at diff "lazy dog") 'agent-ui-success))
    ;; RET on a wrapped line's next lines: its file at its line.
    (let ((text (agent-ui-render (append code '(:file "/tmp/f.py")) (agent-ui-context :width 60))))
      (should (eq (get-text-property (string-search "dog," text) 'agent-ui-line text) 2)))
    ;; In the GUI: each of a diff line's lines tinted the pane's width.
    (let* ((text (agent-ui-render diff (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
           (lines (split-string text "\n")))
      (dolist (line (seq-filter (lambda (l) (string-match-p "lazy\\|end\"" l)) lines))
        (should (= (string-width line) 60))
        (should (string-search ":background" (format "%S" (get-text-property (1- (length line)) 'face line))))))
    ;; A line of megabytes: its lines capped, the last ending with ….
    (let ((lines (split-string (agent-ui-test-aue-draw (list :type "log" :lines (list (make-string 100000 ?x)))) "\n")))
      (should (= (length lines) (1+ agent-ui-max-cell-lines)))
      (should (string-suffix-p "x…" (car (last lines)))))))

;; doom-cbj
(ert-deftest agent-ui-components/names-in-columns-read-whole ()
  "A bar chart's labels, a timeline's task names, a heatmap's row labels and
a graph's node names (and targets) too long for their column are wrapped in
it, every word read, the row taller (they were cut with …, their rest
nowhere); a heatmap's column labels that don't fit their cells are numbered,
their labels in a key under it (cut, only part of each was read)."
  (let* ((long "agent-workflow pool: sessions with no role or name")
         (chart (list :type "chart" :kind "bar" :labels (list long "parser") :values '(3 4)))
         (timeline (list :type "timeline" :tasks (list (list :name long :start 0 :end 8) '(:name "b" :start 8 :end 14))))
         (heatmap (list :type "heatmap" :rows (list long "beads") :columns '("macos-14-arm64-large-runner" "linux")
                        :values '((1 2) (3 4))))
         (graph (list :type "graph" :nodes (list long "beads" "worktree for each issue, locked")
                      :edges (list (list long "beads") (list long "worktree for each issue, locked")))))
    (dolist (width '(30 40 60 98))
      (dolist (component (list chart timeline heatmap graph))
        (let ((text (agent-ui-test-aue-draw component :width width)))
          (should-not (string-search "…" text))
          (dolist (line (split-string text "\n")) (should (<= (string-width line) width)))
          ;; Every word, where the column is wider than the longest (narrower,
          ;; a word is broken in it).
          (when (>= width 60)
            (dolist (word (split-string long))
              (should (string-search word text)))))))
    (should (equal (agent-ui-test-aue-draw chart)
                   (concat "agent-workflow pool:  ██████████████████████████▎          3\n"
                           "sessions with no\nrole or name\n"
                           "parser                ███████████████████████████████████  4")))
    (should (string-prefix-p (concat "agent-workflow pool:  ███████████████             8s\n"
                                     "sessions with no\nrole or name\n")
                             (agent-ui-test-aue-draw timeline)))
    ;; Numbered heads, their labels in a key.
    (let ((text (agent-ui-test-aue-draw heatmap)))
      (should (string-prefix-p "                      1                  2\n" text))
      (should (string-search "\n1 macos-14-arm64-large-runner  2 linux\n" text)))
    (should (string-prefix-p (concat "agent-workflow pool: ─▶ beads, worktree for each issue,\n"
                                     "sessions with no        locked\n"
                                     "role or name\n")
                             (agent-ui-test-aue-draw graph)))
    ;; In the GUI: each wrapped, whole.
    (dolist (component (list chart timeline heatmap))
      (let ((svg (agent-ui-test-aue-svg component 60)))
        (should-not (string-match-p "&#8230;" svg))
        (should (string-match-p ">agent-workflow pool:" svg))
        (should (string-match-p ">role or name<" svg))))))

;; doom-sg6
(ert-deftest agent-ui-components/gui-labels-read-whole ()
  "In the GUI a stats tile's label, a gauge's and a countdown's are read
whole (they were cut with … at 20 to 27 characters with room to spare): a
tile as wide as its label needs within its share of the pane, else its
label wrapped in it, the tile taller, the row's values in line; a change
under its value wrapped; a gauge's label wrapped under its arc, taller; a
countdown's card wider for its label, else wrapped, taller."
  (let* ((label "Tickets closed in this epic since it started")
         (texts (lambda (svg) (let (acc (start 0))
                                (while (string-match ">\\([^<>]+\\)</text>" svg start)
                                  (push (match-string 1 svg) acc)
                                  (setq start (match-end 0)))
                                (nreverse acc))))
         (height (lambda (svg) (and (string-match "height=\"\\([0-9.]+\\)\"" svg)
                                    (string-to-number (match-string 1 svg)))))
         (words-in (lambda (words svg)
                     (let ((shown (split-string (string-join (funcall texts svg) " "))))
                       (cl-every (lambda (w) (member w shown)) words)))))
    ;; Stats at 98 columns, two tiles: the label whole, on one line.
    (let ((svg (agent-ui-test-aue-svg (list :type "stats" :figures (list (list :label label :value 7) '(:label "Open" :value 11))) 98)))
      (should-not (string-match-p "…\\|&#8230;" svg))
      (should (funcall words-in (split-string label) svg)))
    ;; Narrow: wrapped in its tile, taller than a tile of one line.
    (let ((svg (agent-ui-test-aue-svg (list :type "stats" :figures (list (list :label label :value 7 :change "+3 since this morning"))) 30))
          (short (agent-ui-test-aue-svg '(:type "stats" :figures ((:label "Open" :value 11))) 30)))
      (should-not (string-match-p "…\\|&#8230;" svg))
      (should (funcall words-in (append (split-string label) '("+3" "since" "this" "morning")) svg))
      (should (> (funcall height svg) (funcall height short))))
    ;; A gauge's label under its arc, wrapped, its drawing taller.
    (let ((svg (agent-ui-test-aue-svg '(:type "gauge" :label "Coverage of the agent-workflow module's tests" :value 70 :target 80) 98))
          (short (agent-ui-test-aue-svg '(:type "gauge" :label "Coverage" :value 70) 98)))
      (should-not (string-match-p "…\\|&#8230;" svg))
      (should (funcall words-in '("Coverage" "of" "the" "agent-workflow" "module's" "tests" "target" "80") svg))
      (should (> (funcall height svg) (funcall height short))))
    ;; A countdown's label: its card wider, on one line; narrow, wrapped.
    (let ((label "Waiting for the CI run of the branch agent-workflow"))
      (let ((svg (agent-ui-test-aue-svg (list :type "countdown" :label label :since 125) 98)))
        (should (member label (funcall texts svg))))
      (let ((svg (agent-ui-test-aue-svg (list :type "countdown" :label label :since 125) 30)))
        (should-not (string-match-p "…\\|&#8230;" svg))
        (should (funcall words-in (split-string label) svg))))))

;; doom-ny5
(ert-deftest agent-ui-components/appended-under-a-title-and-above-actions ()
  "Lines appended to a component drawn alone (its type's :extend) are put in
its own drawing: under its title, however many lines it takes, above its
actions (a titled log's counts went over its title, its lines past its
show kept; appended lines went under its buttons): the same as drawn
whole."
  (agent-ui-test-aue-canvas
    (dolist (extra '((:title "server.log")
                     (:title "the server's log, from its start this morning to now, every line of it")
                     (:actions ((:label "Fix it" :prompt "fix")))
                     (:title "server.log" :actions ((:label "Fix it" :prompt "fix") (:label "Show more" :prompt "more")))))
      (agent-ui-clear)
      (agent-ui-show (append '(:id "l" :type "log" :show 3 :lines ("one" "two")) extra))
      (agent-ui-show (append '(:id "t" :type "table" :columns ("A") :rows (("1"))) extra))
      (with-current-buffer canvas (agent-ui--flush))
      (agent-ui-append "l" '(:lines ("three" "four")))
      (agent-ui-append "t" '(:rows (("2") ("3"))))
      (let ((appended (with-current-buffer canvas
                        (agent-ui--flush)
                        (buffer-substring-no-properties (point-min) (point-max))))
            (log (agent-ui-get "l"))
            (table (agent-ui-get "t")))
        ;; The same components shown afresh: drawn whole.
        (agent-ui-clear)
        (agent-ui-show log)
        (agent-ui-show table)
        (with-current-buffer canvas
          (agent-ui--flush)
          (should (equal appended (buffer-substring-no-properties (point-min) (point-max)))))))))

;; doom-nwj.83
(ert-deftest agent-ui-components/tabs-to-their-stops ()
  "A tab is spaces up to the next tab stop (every 8 columns) in code, diff
and log: tab-aligned text stays aligned (each was 4 spaces: \"a    b\" and
\"abc    b\")."
  (should (equal (agent-ui-untabify "a\tb\nabc\tb\n\tc\nabcdefgh\ti") "a       b\nabc     b\n        c\nabcdefgh        i"))
  (should (equal (agent-ui-untabify "é\tx" 4) "é   x"))
  (should (equal (agent-ui-test-aue-draw '(:type "code" :code "a\tb\nabc\tb"))
                 "1 │ a       b\n2 │ abc     b"))
  (should (equal (agent-ui-test-aue-draw '(:type "log" :lines "a\tb\nabc\tb"))
                 "2 lines\na       b\nabc     b"))
  ;; In a diff: from its line's start, past its mark.
  (should (equal (cddr (split-string (agent-ui-test-aue-draw '(:type "diff" :diff "@@ -1,2 +1,2 @@\n-a\tb\n+abc\tb\n")) "\n"))
                 '("        − a       b" "      1 + abc     b"))))

;;; agent-ui-components-tests.el ends here
