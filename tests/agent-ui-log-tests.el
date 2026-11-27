;;; agent-ui-log-tests.el --- Tests for Agent UI: the log component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-log.el: the log component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/log ()
  (let ((component '(:type "log" :lines "start\nWARN: slow query\nERROR db: refused\ndebug: retry\nPanic! at the disco\nok")))
    (should (equal (agent-ui-test-aue-draw component)
                   (concat "2 errors · 1 warning · 6 lines\n"
                           "start\nWARN: slow query\nERROR db: refused\ndebug: retry\nPanic! at the disco\nok")))
    (should (eq (agent-ui-test-aue-face-at component "ERROR db") 'agent-ui-error))
    (should (eq (agent-ui-test-aue-face-at component "WARN:") 'agent-ui-warning))
    (should (eq (agent-ui-test-aue-face-at component "debug:") 'agent-ui-muted))
    (should-not (agent-ui-test-aue-face-at component "start")))
  ;; Words, not parts of words: "errorless" isn't an error.
  (should (equal (agent-ui-test-aue-draw '(:type "log" :lines "errorless run")) "1 line\nerrorless run"))
  ;; Given levels; the last SHOW shown, KEEP counted.
  (should (equal (agent-ui-test-aue-draw '(:type "log" :show 2 :keep 3
                                   :lines ((:level "error" :text "a") "b" "c" (:level "warning" :text "d"))))
                 "1 warning · 3 lines\nc\nd"))
  (should (equal (agent-ui-test-aue-draw '(:type "log")) "no lines yet")))

;; doom-4qj
(ert-deftest agent-ui-components/log-levels-given-by-their-words ()
  "A line's given level is read by the words its text is, case aside, and
syslog's, Datadog's and Java's names: a script passing Datadog's status
(warn) had its log refused, the panel's whole update with it."
  (dolist (given '(("error" . error) ("ERROR" . error) ("Error" . error) ("err" . error) ("fatal" . error)
                   ("critical" . error) ("CRITICAL" . error) ("crit" . error) ("emerg" . error)
                   ("emergency" . error) ("alert" . error) ("SEVERE" . error)
                   ("warning" . warning) ("warn" . warning) ("WARN" . warning) ("WARNING" . warning)
                   ("info" . info) ("INFO" . info) ("notice" . info) ("ok" . info)
                   ("debug" . debug) ("trace" . debug) ("TRACE" . debug) ("fine" . debug)
                   (warning . warning) (warn . warning)))
    (should (eq (agent-ui-log--given (car given)) (cdr given))))
  (dolist (none '(nil "loud" "" 3 :false))
    (should-not (agent-ui-log--given none)))
  ;; Coloured and counted as given; none, not found in the text.
  (should (equal (agent-ui-test-aue-draw '(:type "log" :lines ((:level "info" :text "started")
                                                       (:level "warn" :text "slow query")
                                                       (:level "CRITICAL" :text "down")
                                                       (:text "an error, given no level"))))
                 "1 error · 1 warning · 4 lines\nstarted\nslow query\ndown\nan error, given no level"))
  (should (eq (get-text-property 0 'face (agent-ui-log--line-text (agent-ui-log--line '(:level "warn" :text "slow")) 80))
              'agent-ui-warning))
  ;; Alert, ok, fine in a line's text are no level.
  (should-not (agent-ui-log--level "alert: ok, all fine")))

;; doom-nwj.75
(ert-deftest agent-ui-components/log-summaries-of-none-arent-errors ()
  "Success summaries aren't errors: a count of none (cargo's \"0 failed\",
\"Errors: 0\") nor error_count (_ is part of a word); failures still are."
  (dolist (line '("test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured"
                  "============================== 12 passed in 0.12s =============================="
                  "Tests:       12 passed, 12 total"
                  "Tests run: 12, Failures: 0, Errors: 0, Skipped: 0"
                  "error_count=0 warning_count=0"
                  "    0 Warning(s)"
                  "    0 Error(s)"
                  "Compiled with no errors"
                  "build: 0 errors, 0 warnings"))
    (should-not (agent-ui-log--level line)))
  (dolist (line '("test result: FAILED. 11 passed; 1 failed; 0 ignored"
                  "========================= 1 failed, 11 passed in 0.31s ========================="
                  "FAILED tests/test_parser.py::test_empty - AssertionError"
                  "error[E0308]: mismatched types"
                  "Tests run: 12, Failures: 0, Errors: 1, Skipped: 0 <<< FAILURE!"
                  "10 failed"
                  "ERROR: 0 is not a valid port"))
    (should (eq (agent-ui-log--level line) 'error)))
  (should (eq (agent-ui-log--level "12 passed, 1 warning in 0.5s") 'warning))
  (should (equal (agent-ui-test-aue-draw '(:type "log" :lines "running 12 tests\ntest result: ok. 12 passed; 0 failed; 0 ignored"))
                 "2 lines\nrunning 12 tests\ntest result: ok. 12 passed; 0 failed; 0 ignored")))

;; doom-nwj.76
(ert-deftest agent-ui-components/log-counts-fit ()
  "Its counts line fits the width: its last parts left out, the errors'
cut last (never cut: 30 columns at 15)."
  (let ((component '(:type "log" :lines "error a\nerror b\nerror c\nwarning d\ne\nf\ng")))
    (should (equal (car (split-string (agent-ui-test-aue-draw component :width 40) "\n"))
                   "3 errors · 1 warning · 7 lines"))
    (should (equal (car (split-string (agent-ui-test-aue-draw component :width 25) "\n")) "3 errors · 1 warning"))
    (should (equal (car (split-string (agent-ui-test-aue-draw component :width 15) "\n")) "3 errors"))
    (should (equal (car (split-string (agent-ui-test-aue-draw component :width 6) "\n")) "3 err…"))
    (dolist (width (number-sequence 5 40))
      (should (<= (string-width (car (split-string (agent-ui-test-aue-draw component :width width) "\n"))) width)))))

;; doom-nwj.91
(ert-deftest agent-ui-components/log-without-terminal-codes ()
  "Coloured tools' output reads as plain text: their escape sequences left
out (shown raw: ^[[31m...), its level found in what's left."
  (let ((component (list :type "log"
                       :lines (concat "\e[1m\e[32m   Compiling\e[0m parser v0.1.0\n"
                                      "\e[0;31mERROR\e[0m db: refused\n"
                                      "\e]0;a title\afetched \e]8;;https://x.y\e\\link\e]8;;\e\\\n"
                                      "\e[2K\e[1Gprogress 100%"))))
    (should (equal (agent-ui-test-aue-draw component)
                   (concat "1 error · 4 lines\n"
                           "   Compiling parser v0.1.0\n"
                           "ERROR db: refused\n"
                           "fetched link\n"
                           "progress 100%")))
    (should (eq (agent-ui-test-aue-face-at component "ERROR db") 'agent-ui-error))
    ;; Given as {level, text}: its text too.
    (should (equal (agent-ui-test-aue-draw '(:type "log" :lines ((:level "warning" :text "\e[33mslow\e[0m"))))
                   "1 warning · 1 line\nslow"))))

(ert-deftest agent-ui-components/log-appended-draws-only-its-lines ()
  "A line appended to a long log: its counts line again, the lines shown no
more dropped, the new ones at its end; not drawn whole (each line read again:
12.9 ms at 1000 lines). The same as drawn whole; drawn whole when it shows
as many as were appended, or its width changed."
  (agent-ui-test-aue-canvas
    (with-current-buffer canvas
      (agent-ui-show (list :id "log" :type "log" :show 5
                           :lines (mapcar (lambda (i) (format "12:00:%02d INFO line %d" (% i 60) i)) (number-sequence 1 1000))))
      (agent-ui--flush)
      (agent-ui-test-aue--counting-whole-draws
        (dolist (lines '(("13:00:00 ERROR db: refused") ("a" "WARN b" "c") ("d")))
          (agent-ui-append "log" (list :lines lines))
          (agent-ui--flush)
          (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "log") (agent-ui-test-aue--drawn-whole "log"))))
        (should-not whole)
        ;; Counted: the last 1000 kept (keep).
        (should (string-prefix-p "1 error · 1 warning · 1000 lines\n" (agent-ui-test-aue--region "log")))
        ;; As many as it shows: drawn whole.
        (agent-ui-append "log" (list :lines '("1" "2" "3" "4" "5")))
        (agent-ui--flush)
        (should (equal whole '("log")))
        (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "log") (agent-ui-test-aue--drawn-whole "log")))
        ;; Another width: drawn whole.
        (setq whole nil)
        (cl-letf* ((context (symbol-function 'agent-ui--context))
                   ((symbol-function 'agent-ui--context)
                    (lambda () (plist-put (funcall context) :width 30))))
          (agent-ui-append "log" (list :lines '("e")))
          (agent-ui--flush)
          ;; It whole, the canvas's others too (drawn at the old width).
          (should (equal (sort (copy-sequence whole) #'string<) '("first" "log")))
          (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "log") (agent-ui-test-aue--drawn-whole "log")))))
      ;; The component after it untouched.
      (agent-ui-show '(:id "after" :type "text" :text "below"))
      (agent-ui--flush)
      (agent-ui-append "log" (list :lines '("f")))
      (agent-ui--flush)
      (should (string-suffix-p "f\n\nbelow\n\n" (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest agent-ui-components/log-appended-past-its-cut ()
  "A log drawn past `agent-ui-max-chars' (cut, what's left out said): a
line appended, the same as drawn whole, no stale cut left (doom-ht6.69)."
  (agent-ui-test-aue-canvas
    (with-current-buffer canvas
      (agent-ui-show (list :id "log" :type "log" :show 300
                           :lines (mapcar (lambda (i) (format "%04d %s" i (make-string 70 ?x))) (number-sequence 1 300))))
      (agent-ui--flush)
      (dolist (n '(301 302))
        (agent-ui-append "log" (list :lines (list (format "%04d appended line" n))))
        (agent-ui--flush)
        (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "log") (agent-ui-test-aue--drawn-whole "log")))))))

(ert-deftest agent-ui-components/log-appended ()
  (should (equal (plist-get (agent-ui-append-to '(:type "log" :lines "a\nb") '(:lines "c\n")) :lines) '("a" "b" "c")))
  (should (equal (plist-get (agent-ui-append-to '(:type "log" :lines ("a")) '(:lines ("b" "c"))) :lines) '("a" "b" "c")))
  (should (string-match-p "only lines" (agent-ui-error-message (should-error (agent-ui-append-to '(:type "log") '(:show 3)) :type 'agent-ui-error)))))

(ert-deftest agent-ui-components/log-appended-a-number-refused ()
  "A number or a boolean appended to a log's lines: refused, the log as it
was, drawn, the canvas still saved as JSON; a chart's times too
\(doom-ht6.132)."
  (agent-ui-test-aue-canvas
    (agent-ui-show '(:id "build" :type "log" :lines ("compiling" "linking")))
    (dolist (lines '(42 t :false))
      (should (string-match-p "lines is text or a list"
                              (agent-ui-error-message
                               (should-error (agent-ui-append "build" (list :lines lines)) :type 'agent-ui-error)))))
    (should (equal (plist-get (agent-ui-get "build") :lines) '("compiling" "linking")))
    (with-current-buffer canvas
      (agent-ui--flush)
      (should-not (string-search "⚠" (buffer-string))))
    (agent-ui-show '(:id "c" :type "chart" :values (1 2) :times (100 200)))
    (should-error (agent-ui-append "c" '(:times 300)) :type 'agent-ui-error)
    (should (equal (plist-get (agent-ui-get "c") :times) '(100 200)))
    (should (json-serialize (vconcat (mapcar #'agent-ui-to-json (agent-ui-components)))))))

(ert-deftest agent-ui-components/log-wrong ()
  (should (string-match-p "line 1's level \"loud\" is none of error, warning, info, debug"
                          (agent-ui-test-aue-error '(:type "log" :lines ((:level "loud" :text "x"))))))
  (should (string-match-p "line 2 must be text" (agent-ui-test-aue-error '(:type "log" :lines ("a" (:level "info"))))))
  (should (string-match-p "keep is 1 to 5000" (agent-ui-test-aue-error '(:type "log" :keep 0))))
  (should (string-match-p "lines is text or a list" (agent-ui-test-aue-error '(:type "log" :lines 3)))))

(defconst agent-ui-test-aue--columns
  '(:type "log" :unit "event" :right "16:22 – 16:41 · 19m" :sources ("green" "docs")
    :lines ((:time "16:22" :mark "▸" :mark-face "accent" :text ("started" (:text " with " :face "muted") "github"))
            (:time "16:22" :mark "▸" :mark-face "accent" :source "green" :text "started")
            (:time "16:22" :mark "›" :mark-face "muted" :source "green" :indent 1
             :text ("watch" (:text " started" :face "muted")))
            (:gap "17m")
            (:time "16:39" :mark "✗" :mark-face "error" :source "green" :indent 1 :level "error"
             :text ("watch" (:text " exited 1" :face "error")) :right "16m 32s")
            (:time "16:39" :mark "↻" :mark-face "warning" :source "docs" :level "warning" :text "fixes it")))
  "A log in columns: its parts, a pause, a step's line under its job's.")

(ert-deftest agent-ui-components/log-in-columns ()
  "A log's lines in columns: each one's time (muted, shown when it changes),
its mark in its face, its source in its own colour (by its place in
SOURCES) padded to the widest, its text's pieces in theirs (alone, in its
level's), indented, RIGHT at its end; a pause, ┊ and how long, not counted.
Its counts marked as its lines (✗, ◆), what it counts (UNIT), its RIGHT at
their end."
  (let ((component agent-ui-test-aue--columns))
    (should (equal (agent-ui-test-aue-draw component)
                   (concat "✗ 1 error · ◆ 1 warning · 5 events       16:22 – 16:41 · 19m\n"
                           "16:22  ▸         started with github\n"
                           "       ▸  green  started\n"
                           "       ›  green    watch started\n"
                           "       ┊  17m\n"
                           "16:39  ✗  green    watch exited 1                    16m 32s\n"
                           "       ↻  docs   fixes it")))
    (should (eq (agent-ui-test-aue-face-at component "16:22") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at component "▸") 'agent-ui-accent))
    (should (eq (agent-ui-test-aue-face-at component "green") (nth 0 agent-ui-log-source-faces)))
    (should (eq (agent-ui-test-aue-face-at component "docs") (nth 1 agent-ui-log-source-faces)))
    (should (eq (agent-ui-test-aue-face-at component " with ") 'agent-ui-muted))
    (should-not (agent-ui-test-aue-face-at component "github"))
    (should-not (agent-ui-test-aue-face-at component "watch exited"))
    (should (eq (agent-ui-test-aue-face-at component " exited 1") 'agent-ui-error))
    (should (eq (agent-ui-test-aue-face-at component "16m 32s") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at component "┊") 'agent-ui-muted))
    ;; Its text alone: its level's colour.
    (should (eq (agent-ui-test-aue-face-at component "fixes it") 'agent-ui-warning))
    (should (eq (agent-ui-test-aue-face-at component "16:22 – 16:41") 'agent-ui-muted))
    ;; Narrow (its text under 12 columns with it): its right left out; its
    ;; text wrapped under its own start.
    (should (equal (agent-ui-test-aue-draw (list :type "log" :lines '((:time "09:00" :mark "✓" :source "a" :right "2s"
                                                               :text "one two three four five six")))
                                   :width 26)
                   (concat "1 line\n"
                           "09:00  ✓  a  one two three\n"
                           "             four five six")))
    ;; A source not in SOURCES: its colour by its name, the same each time.
    (let ((log '(:type "log" :lines ((:source "web" :text "up")))))
      (should (eq (agent-ui-test-aue-face-at log "web") (agent-ui-test-aue-face-at log "web")))
      (should (memq (agent-ui-test-aue-face-at log "web") agent-ui-log-source-faces)))))

(ert-deftest agent-ui-components/log-in-columns-appended ()
  "Lines in columns appended (its extend): the same as drawn whole, its
counts and their right again, a line's time shown once the one before it
that had it is no longer shown, a wrapped one counted as drawn."
  (let* ((line (lambda (time text) (list :time time :mark "·" :source "a" :text text)))
         (long (mapconcat #'identity (make-list 12 "word") " "))
         (cases (list
                 ;; Its first line shown dropped: the next one's time shown.
                 (list (list (funcall line "09:00" "a") (funcall line "09:00" "b") (funcall line "09:00" "c"))
                       (list (funcall line "09:00" "d")))
                 ;; A pause, then a wrapped line.
                 (list (list (funcall line "09:00" "a") (funcall line "09:00" "b"))
                       (list '(:gap "17m") (funcall line "09:17" long)))
                 ;; The same time as the last: not shown again.
                 (list (list (funcall line "09:00" "a"))
                       (list (funcall line "09:00" "b")))
                 ;; A wider source: its column wider, each line again.
                 (list (list (funcall line "09:00" "a") (funcall line "09:01" "b"))
                       (list (list :time "09:02" :source "a longer one" :text "c"))))))
    (pcase-dolist (`(,before ,added) cases)
      (let* ((old (list :type "log" :show 3 :right "a" :lines before))
             (new (list :type "log" :show 3 :right "b" :lines (append before added)))
             (ctx (agent-ui-context :width 40))
             (edits (funcall (agent-ui-type-extend (agent-ui-type 'log))
                             (agent-ui-check 'log (copy-sequence old)) (agent-ui-check 'log (copy-sequence new)) ctx)))
        (should edits)
        (with-temp-buffer
          (insert (agent-ui-render old ctx))
          (dolist (edit edits)
            (pcase edit
              (`(replace ,line ,text) (goto-char (point-min)) (forward-line line)
               (delete-region (point) (line-end-position)) (insert text))
              (`(delete ,line ,count) (goto-char (point-min)) (forward-line line)
               (delete-region (point) (progn (forward-line count) (point))))
              (`(insert ,_ ,text) (goto-char (point-max)) (insert "\n" text))))
          (should (equal-including-properties (buffer-string) (agent-ui-render new ctx))))))))

(ert-deftest agent-ui-components/log-in-columns-wrong ()
  "A line in columns: its mark's face, its indent and its text's pieces
checked; a pause given alone."
  (should (string-match-p "line 1's mark-face \"pink\" is none of plain, muted"
                          (agent-ui-test-aue-error '(:type "log" :lines ((:mark "x" :mark-face "pink" :text "a"))))))
  (should (string-match-p "line 1's indent is 0 to 4, not 9"
                          (agent-ui-test-aue-error '(:type "log" :lines ((:indent 9 :text "a"))))))
  (should (string-match-p "line 1's piece's face \"loud\""
                          (agent-ui-test-aue-error '(:type "log" :lines ((:text ("a" (:text "b" :face "loud"))))))))
  (should (string-match-p "line 1's text is text, or a list of pieces"
                          (agent-ui-test-aue-error '(:type "log" :lines ((:text ("a" (:face "muted"))))))))
  (should (agent-ui-check 'log '(:type "log" :lines ((:gap "5m")))))
  ;; Its right replaced as lines are appended; nothing else.
  (should (equal (plist-get (agent-ui-append-to '(:type "log" :lines ("a") :right "x") '(:lines ("b") :right "y")) :right) "y"))
  (should (string-match-p "only lines" (agent-ui-error-message
                                        (should-error (agent-ui-append-to '(:type "log") '(:unit "x")) :type 'agent-ui-error)))))

(ert-deftest agent-ui-components/log-appended-wrapped-lines ()
  "Lines appended to a log, drawn alone (its extend), its wrapped lines
counted as drawn: the same as drawn whole, the lines no longer shown gone
whole (a wrapped one left a piece behind)."
  (let* ((long (concat "ERROR " (mapconcat #'identity (make-list 30 "word") " ")))
         (old (list :type "log" :show 3 :lines (list long "two" long)))
         (new (list :type "log" :show 3 :lines (list long "two" long "four" long)))
         (ctx (agent-ui-context :width 40))
         (old-p (agent-ui-check 'log (copy-sequence old)))
         (new-p (agent-ui-check 'log (copy-sequence new)))
         (edits (funcall (agent-ui-type-extend (agent-ui-type 'log)) old-p new-p ctx)))
    (should edits)
    ;; Applied to the old drawing: the new one.
    (with-temp-buffer
      (insert (substring-no-properties (agent-ui-render old ctx)))
      (dolist (edit edits)
        (pcase edit
          (`(replace ,line ,text) (goto-char (point-min)) (forward-line line)
           (delete-region (point) (line-end-position)) (insert (substring-no-properties text)))
          (`(delete ,line ,count) (goto-char (point-min)) (forward-line line)
           (delete-region (point) (progn (forward-line count) (point))))
          (`(insert ,_ ,text) (goto-char (point-max)) (insert "\n" (substring-no-properties text)))))
      (should (equal (buffer-string) (substring-no-properties (agent-ui-render new ctx)))))))

;;; agent-ui-log-tests.el ends here
