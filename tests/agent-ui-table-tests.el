;;; agent-ui-table-tests.el --- Tests for Agent UI: the table component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-table.el: the table component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/table-row-buttons-don-t-squeeze-it ()
  "Row buttons beside the cells while the cells keep their widths; else on a
line of their own under each row (they cut the cells to 3 columns, the rows
past the width); clickable either way."
  (let ((component '(:type "table" :columns ("Test" "Result" "Time") :rows (("lexer" "passed" "0.4s") ("parser" "failed" "1.2s"))
                   :row-actions ((:label "Fix it" :prompt "Fix {Test}") (:label "Explain" :prompt "Explain {row}")))))
    ;; Wide: beside.
    (should (string-match-p "lexer +│ passed │ 0.4s +⏵ Fix it  ⏵ Explain" (agent-ui-test-aue-draw component :width 60)))
    ;; Narrow: under, the cells whole, every line within the width.
    (let ((text (agent-ui-test-aue-draw component :width 34)))
      (should (string-match-p "lexer +│ passed │ 0.4s\n +⏵ Fix it  ⏵ Explain" text))
      (dolist (line (split-string text "\n"))
        (should (<= (string-width line) 34))))
    (let ((text (agent-ui-render component (agent-ui-context :width 34))))
      (should (get-text-property (string-search "⏵ Fix it" text) 'agent-ui-action text)))))

;; RET or a click on a row: its prompt, its cells filled in.
(ert-deftest agent-ui-components/table-rows-opened-on-one-line ()
  "ROW-OPEN: the row itself a button (no button drawn), its prompt's {0} its
first cell; its help hovered. NOWRAP: a cell too wide cut, …, the row a
line. A row-open not an action: refused."
  (let* ((component '(:type "table" :columns ("" "") :nowrap t
                    :rows (("abc1234" "A commit whose subject is far too long for the pane it is in")
                           ("def5678" "Short"))
                    :row-open (:prompt "{0}" :help "show this commit")))
         (text (agent-ui-render component (agent-ui-context :width 40)))
         (lines (split-string (substring-no-properties text) "\n" t)))
    (should (= (length lines) 2))
    (should (string-suffix-p "…" (string-trim-right (car lines))))
    (dolist (line lines) (should (<= (string-width line) 40)))
    (should-not (string-search "⏵" text))
    (let* ((at (string-search "def5678" text))
           (pressed nil)
           (agent-ui-action-function (lambda (prompt submit) (setq pressed (list prompt submit)))))
      (should (equal (get-text-property at 'help-echo text) "RET: show this commit"))
      (funcall (get-text-property at 'agent-ui-action text))
      (should (equal pressed '("def5678" nil)))))
  ;; Wrapped without NOWRAP.
  (should (> (length (split-string (agent-ui-test-aue-draw '(:type "table" :columns ("" "")
                                                     :rows (("abc1234" "A commit whose subject is far too long for the pane it is in"))
                                                     :row-open (:prompt "{0}"))
                                                   :width 40)
                                   "\n" t))
             1))
  (should (string-match-p "row-open" (agent-ui-test-aue-error '(:type "table" :columns ("a") :rows (("x")) :row-open "open")))))

(ert-deftest agent-ui-components/table-columns-that-fit ()
  "More columns than fit, each cut to its narrowest: those on the left that
fit, the others said under it (it stayed wider than its width)."
  (let ((six '(:type "table" :columns ("Name" "Status" "Time" "Owner" "Branch" "Commit")
               :rows (("a" "ok" "1s" "me" "main" "abc123") ("b" "ok" "2s" "you" "dev" "def456")))))
    (dolist (width '(15 20 30))
      (let ((text (agent-ui-test-aue-draw six :width width)))
        (dolist (line (split-string text "\n"))
          (should (<= (string-width line) width)))
        (should (string-match-p "… [0-9]+ more[ \n]+col" text))))
    ;; Wide enough: all of them, no note.
    (should-not (string-match-p "more columns" (agent-ui-test-aue-draw six :width 60)))
    (should (string-match-p "… 2 more columns: Branch,\n   Commit" (agent-ui-test-aue-draw six :width 30)))))

(ert-deftest agent-ui-components/table-columns-left-out-not-squeezed ()
  "In a narrow canvas, columns are left out rather than every one squeezed
to 3 (\"do… │ Ta… │ 202…\"): the key column (else the first) whole, the
others 6 wide at least at 24, their cells wrapped, those left out named,
the note wrapped."
  (let ((issues '(:type "table" :columns ("ID" "Title" "Status" "Created at")
                  :rows (("doom-ht6.13" "Tabs squeeze columns" "open" "2026-11-14")
                         ("doom-ht6.14" "Sort dates" "closed" "2026-11-13")))))
    (let ((text (agent-ui-test-aue-draw issues :width 30)))
      (should (string-match-p "^ doom-ht6.13 │ Tabs squeeze\n +│ columns$" text))
      (should (string-match-p "… 2 more columns: Status,\n   Created at\\'" text)))
    (dolist (width '(24 30 40))
      (let* ((text (agent-ui-test-aue-draw issues :width width))
             (lines (split-string text "\n")))
        (dolist (line lines)
          (should (<= (string-width line) width)))
        ;; Each cell shown whole, its words on its lines; the columns 6
        ;; wide at least.
        (dolist (word '("doom-ht6.13" "Tabs" "squeeze" "columns" "doom-ht6.14" "Sort" "dates"))
          (should (string-search word text)))
        (should (>= (string-width (cadr (split-string (cadr lines) "┼"))) 6)))))
  ;; A key column not the first: whole, the first one wrapped.
  (should (string-match-p "^ Tabs +│ doom-ht6.13\n squeeze +│\n columns +│$"
                          (agent-ui-test-aue-draw '(:type "table" :columns ("Title" "ID") :key "ID"
                                            :rows (("Tabs squeeze columns" "doom-ht6.13")))
                                          :width 24))))

(ert-deftest agent-ui-components/table-sorted-by-durations ()
  "Durations sorted by their length, units and all (the leading numbers
alone put 850ms between 41s and 2m 05s)."
  (let ((text (agent-ui-test-aue-draw '(:type "table" :columns ("Test" "Time") :sort "Time" :descending t
                                :rows (("a" "2m 05s") ("b" "41s") ("c" "850ms") ("d" "1.2s") ("e" "1h"))))))
    (should (string-match-p "e .*1h\n.*a .*2m 05s\n.*b .*41s\n.*d .*1.2s\n.*c .*850ms" text)))
  (should (= (agent-ui-table--duration "2m 05s") 125))
  (should (= (agent-ui-table--duration "850ms") 0.85))
  (should-not (agent-ui-table--duration "5 apples"))
  (should-not (agent-ui-table--duration "12"))
  ;; Plain numbers: as numbers still.
  (should (string-match-p " 2\n.* 10" (agent-ui-test-aue-draw '(:type "table" :columns ("N") :sort "N" :rows (("10") ("2")))))))

(ert-deftest agent-ui-components/table-sorted-dates-times-versions ()
  "Dates, times and versions sorted by each of their numbers, both ways (by
their leading number alone, ties left in their order: 2026-11-14 before
2026-01-20, 1.2.10 before 1.2.9); numbers with a unit or % as numbers."
  (cl-flet ((sorted (cells &optional descending)
              (mapcar (lambda (line) (string-trim line))
                      (nthcdr 2 (split-string
                                 (agent-ui-test-aue-draw `(:type "table" :columns ("V") :sort "V" :descending ,descending
                                                   :rows ,(mapcar #'list cells)))
                                 "\n")))))
    (dolist (case '(("2025-12-31" "2026-01-20" "2026-03-01" "2026-11-14")
                    ("9:59:59" "12:00:59" "12:01:03")
                    ("1.2.9" "1.2.10" "1.10.0" "2.0.0")
                    ("2 %" "45%" "300 MB" "1,204 MB")))
      (should (equal (sorted (reverse case)) case))
      (should (equal (sorted (append (cdr case) (list (car case))) t) (reverse case)))))
  (should (= (agent-ui-table--number "1,204") 1204))
  (should (= (agent-ui-table--number "0.4s") 0.4))
  (should-not (agent-ui-table--number "2026-11-14"))
  (should-not (agent-ui-table--number "1.2.10")))

(ert-deftest agent-ui-components/table-numbers-to-the-right-versions-and-dates-not ()
  "A column of numbers aligned right (a sign, decimals, commas, % maybe);
one of versions, dates or times left, as text (versions were taken for
numbers: right)."
  (let ((lines (split-string (agent-ui-test-aue-draw '(:type "table" :columns ("Version" "Date" "Time" "N" "Pct")
                                               :rows (("1.2.10" "2026-11-14" "12:01:03" "1,204" "-4.5%")
                                                      ("2.0.0" "2026-1-2" "9:59" "7" "45%"))))
                             "\n")))
    (should (equal (nth 2 lines) " 1.2.10  │ 2026-11-14 │ 12:01:03 │ 1,204 │ -4.5%"))
    (should (equal (nth 3 lines) " 2.0.0   │ 2026-1-2   │ 9:59     │     7 │   45%")))
  (dolist (cell '("12" "-3" "+5" "1,204" "3.5" ".5" "45%"))
    (should (agent-ui-table--right-p cell)))
  (dolist (cell '("1.2.10" "2026-11-14" "12:01:03" "0.4s" "12 MB" "v2"))
    (should-not (agent-ui-table--right-p cell))))

(ert-deftest agent-ui-components/table-sort-arrow-kept ()
  "A sorted column's name with its arrow, in a narrow canvas too (it was cut
first)."
  (let ((text (agent-ui-test-aue-draw '(:type "table" :columns ("Name" "Status" "Duration" "Owner" "Branch" "Commit")
                                :sort "Duration" :descending t
                                :rows (("lexer" "passed" "0.4s" "me" "main" "abc123def") ("parser" "failed" "1.2s" "you" "dev" "def456abc")))
                              :width 40)))
    (should (string-match-p "…? ↓" (car (split-string text "\n"))))))

(ert-deftest agent-ui-components/table-align-misspelt-refused ()
  "A misspelt align is refused (it was taken as automatic, silently); left,
right, center and null are taken."
  (dolist (wrong '("rigth" "centre" "Right" "middle"))
    (should (string-match-p "align is left, right, center or null"
                            (agent-ui-test-aue-error `(:type "table" :columns ("A") :rows (("x")) :align (,wrong))))))
  (should (equal (plist-get (agent-ui-check "table" '(:type "table" :columns ("A" "B" "C") :rows (("x" "y" "z"))
                                                       :align ("right" nil "center")))
                            :align)
                 '(right nil center))))

(ert-deftest agent-ui-components/table-cells-on-one-line ()
  "A cell's line breaks and tabs: on its line (they broke the table's lines,
and a panel's border around it)."
  (let ((text (agent-ui-test-aue-draw '(:type "table" :columns ("Test" "Error")
                                :rows (("lexer" "AssertionError: x\n  at foo.js:3") ("parser" "got\tvalue"))))))
    (should (= (length (split-string text "\n")) 4))
    (should (string-match-p "AssertionError: x⏎  at foo" text))
    (should (string-match-p "got value" text))
    (should-not (string-match-p "\t" text))))

(ert-deftest agent-ui-components/table ()
  (let ((component '(:type "table" :columns ("Test" "Result" "Time" "N")
                   :rows (("lexer" "passed" "0.4s" 12) ("parser" "running" nil 3.5) ("x")))))
    (should (equal (agent-ui-test-aue-draw component)
                   (concat " Test   │ Result  │ Time │   N\n"
                           "────────┼─────────┼──────┼────\n"
                           " lexer  │ passed  │ 0.4s │  12\n"
                           " parser │ running │      │ 3.5\n"
                           " x      │         │      │")))
    (should (eq (agent-ui-test-aue-face-at component "Test") 'bold))
    (should (eq (agent-ui-test-aue-face-at component "passed") 'agent-ui-success))
    (should (eq (agent-ui-test-aue-face-at component "running") 'agent-ui-accent)))
  ;; Alignment given; true, false, null.
  (should (equal (agent-ui-test-aue-draw '(:type "table" :columns ("A" "B") :align ("right" "center")
                                   :rows (("x" t) ("yy" :false))))
                 (concat "  A │   B\n"
                         "────┼──────\n"
                         "  x │ true\n"
                         " yy │ false")))
  (should (equal (agent-ui-test-aue-draw '(:type "table" :columns ("A" "B")))
                 " A │ B\n───┼──\n no rows yet")))

(ert-deftest agent-ui-components/table-fits-the-width ()
  "Its lines within the width, a cell too long for its column wrapped in it
\(cut with …, the rest of it was nowhere to be read)."
  (let ((text (agent-ui-test-aue-draw '(:type "table" :columns ("Name" "Description")
                                :rows (("a long name, longer than that" "a description much too long for the width it's given"))))))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 60)))
    (should-not (string-search "…" text))
    (should (string-match-p "a description much too long\n +│ for the width it's given\\'" text)))
  ;; Too many rows: what's left out said.
  (let ((agent-ui-max-rows 2))
    (should (string-suffix-p "… 1 rows more"
                             (agent-ui-test-aue-draw '(:type "table" :columns ("A") :rows (("1") ("2") ("3"))))))))

;; doom-s84
(ert-deftest agent-ui-components/table-long-cells-wrapped ()
  "A cell too long for its column wrapped onto more lines in it: the row as
tall as its tallest cell, the others blank under theirs, the bars in line,
every word shown (cut with …, most of a table of options and their costs
was nowhere to be read)."
  (should (equal (agent-ui-test-aue-draw '(:type "table" :columns ("Option" "Costs")
                                   :rows (("Files" "a format to write and keep in step") ("DB" "more records")))
                                 :width 24)
                 (concat " Option │ Costs\n"
                         "────────┼───────────────\n"
                         " Files  │ a format to\n"
                         "        │ write and keep\n"
                         "        │ in step\n"
                         " DB     │ more records")))
  (let* ((rows '(("Plain files" "one file per kind of work, read by every agent at the start"
                  "the whole graph seen in one place; easy to review" "a format to write and keep in step with the code")
                 ("A database" "each record's own child records, linked by their ids"
                  "queries schedule the work; fan-out and joins come free" "more records to keep; no cycles, so retries need care")))
         (component `(:type "table" :columns ("Option" "Lives in" "Good at" "Costs") :rows ,rows)))
    (dolist (width '(60 80 129))
      (let* ((text (agent-ui-test-aue-draw component :width width))
             (lines (split-string text "\n"))
             (bars (lambda (line) (cl-loop for c across line for i from 0 when (eq c ?│) collect i))))
        (should-not (string-search "…" text))
        (dolist (word (split-string (mapconcat (lambda (row) (string-join row " ")) rows " ")))
          (should (string-search word text)))
        (dolist (line lines)
          (should (<= (string-width line) width)))
        ;; Each row's lines' bars where the header's are.
        (dolist (line (cddr lines))
          (should (equal (funcall bars line) (funcall bars (car lines)))))))))

(ert-deftest agent-ui-components/table-cell-lines-at-most ()
  "A cell wrapped onto `agent-ui-max-cell-lines' lines at most, the last
ending with …; a long one (a log's) only as far as that."
  (let ((agent-ui-max-cell-lines 2))
    (should (equal (agent-ui-test-aue-draw '(:type "table" :columns ("Option" "Costs")
                                     :rows (("Files" "a format to write and keep in step")))
                                   :width 24)
                   (concat " Option │ Costs\n"
                           "────────┼───────────────\n"
                           " Files  │ a format to\n"
                           "        │ write and kee…"))))
  (let ((agent-ui-max-cell-lines 3))
    (should (equal (nthcdr 2 (split-string
                              (agent-ui-test-aue-draw `(:type "table" :columns ("A" "B")
                                                :rows (("x" ,(mapconcat #'identity (make-list 4000 "word") " "))))
                                              :width 20)
                              "\n"))
                   '(" x │ word word word" "   │ word word word" "   │ word word word…")))))

(ert-deftest agent-ui-components/table-appended-by-key ()
  (dolist (key '(0 "Test"))
    (let ((component (list :type "table" :columns '("Test" "Result") :key key
                         :rows '(("lexer" "running") ("parser" "running")))))
      (should (equal (plist-get (agent-ui-append-to component '(:rows (("parser" "failed") ("ast" "running"))))
                                :rows)
                     '(("lexer" "running") ("parser" "failed") ("ast" "running"))))))
  ;; No key: added.
  (should (equal (plist-get (agent-ui-append-to '(:type "table" :columns ("A") :rows (("x")))
                                                '(:rows (("x"))))
                            :rows)
                 '(("x") ("x"))))
  ;; Numbers as keys: as their text.
  (should (equal (plist-get (agent-ui-append-to '(:type "table" :columns ("N" "V") :key 0 :rows ((1 "a")))
                                                '(:rows ((1 "b"))))
                            :rows)
                 '((1 "b")))))

;; doom-ht6.117
(ert-deftest agent-ui-components/table-appended-by-key-a-batch ()
  "A batch appended by key: a row whose key is there (or earlier in the
batch) replaces it in place, the first of those with it; the others after,
in order; a row without its key cell keyed by an empty one; the rows given
untouched."
  (let* ((rows (list '("a" "1") '("b" "1") '("c" "1")))
         (component (list :type "table" :columns '("K" "V") :key 0 :rows rows)))
    (should (equal (plist-get (agent-ui-append-to component '(:rows (("b" "2") ("d" "1") ("d" "2") ("a" "2")
                                                                      ("e" "1") ("b" "3") ("e" "2"))))
                              :rows)
                   '(("a" "2") ("b" "3") ("c" "1") ("d" "2") ("e" "2"))))
    (should (equal rows '(("a" "1") ("b" "1") ("c" "1")))))
  ;; Keys there twice: the first replaced.
  (should (equal (plist-get (agent-ui-append-to '(:type "table" :columns ("K" "V") :key 0
                                                  :rows (("x" "1") ("x" "2")))
                                                '(:rows (("x" "3"))))
                            :rows)
                 '(("x" "3") ("x" "2"))))
  ;; No key cell, a null one: alike.
  (should (equal (plist-get (agent-ui-append-to '(:type "table" :columns ("V" "K") :key 1
                                                  :rows (("p" nil) ("q" "k")))
                                                '(:rows (("r") ("s" "k") ("t" "u"))))
                            :rows)
                 '(("r") ("s" "k") ("t" "u")))))

(ert-deftest agent-ui-components/table-appended-by-key-looks-rows-up ()
  "A batch appended by key looks rows up by their keys, each row's key read
once: not every row's for each appended."
  (let ((component (list :type "table" :columns '("K" "V") :key 0
                         :rows (mapcar (lambda (i) (list (format "r%d" i) "1")) (number-sequence 1 400))))
        (patch (list :rows (mapcar (lambda (i) (list (format "r%d" (* 3 i)) "2")) (number-sequence 1 200))))
        (calls 0))
    (let ((cell (symbol-function 'agent-ui-cell)))
      (cl-letf (((symbol-function 'agent-ui-cell) (lambda (v) (cl-incf calls) (funcall cell v))))
        (let ((rows (plist-get (agent-ui-append-to component patch) :rows)))
          (should (= (length rows) 467))
          (should (equal (nth 2 rows) '("r3" "2")))
          (should (equal (nth 399 rows) '("r400" "1")))
          (should (equal (nth 400 rows) '("r402" "2"))))))
    (should (<= calls (+ 400 200)))))

(ert-deftest agent-ui-components/table-many-rows-converts-the-drawn ()
  "A table of more rows than drawn converts only the drawn rows' cells
\(sorted, its sort column's every cell too); what's drawn the same."
  (let* ((rows (mapcar (lambda (i) (list (format "test_%04d" i) "passed" (format "%ds" (% (* i 7919) 5000))))
                       (number-sequence 1 5000)))
         (component (list :type "table" :columns '("Test" "Result" "Time") :rows rows))
         (calls 0))
    (let ((cell (symbol-function 'agent-ui-cell)))
      (cl-letf (((symbol-function 'agent-ui-cell) (lambda (v) (cl-incf calls) (funcall cell v))))
        (let ((text (agent-ui-test-aue-draw component)))
          (should (<= calls (* 3 agent-ui-max-rows)))
          (should (string-match-p "\n test_0001 .*\n test_0002 " text))
          (should (string-suffix-p "\n … 4500 rows more" text)))
        (setq calls 0)
        (let ((text (agent-ui-test-aue-draw (append component '(:sort "Time" :descending t)))))
          (should (<= calls (+ 5000 (* 3 agent-ui-max-rows))))
          ;; The largest first: 4999s (row 2321), then 4998s (row 4642).
          (should (string-match-p "Time ↓\n.*\n test_2321 .* 4999s\n test_4642 .* 4998s\n" text))
          (should (string-suffix-p "\n … 4500 rows more" text)))))))

(ert-deftest agent-ui-components/table-wrong ()
  (should (equal (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows (("x" "y"))))
                 "table: row 1 has 2 cells, for 1 columns"))
  (should (equal (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows ("x")))
                 "table: row 1 must be an array of cells, not \"x\""))
  (should (string-match-p "a cell is text"
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows (((:k 1)))))))
  (should (string-match-p "columns must be names"
                          (agent-ui-test-aue-error '(:type "table" :columns (1 2)))))
  (should (string-match-p "key must be a column"
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :key "B"))))
  (should (string-match-p "key must be a column"
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :key 1))))
  (should (string-match-p "align is left, right, center or null"
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :align ("middle")))))
  (should (equal (agent-ui-test-aue-error '(:type "table"))
                 "table: columns is required")))

;; doom-nkr
(ert-deftest agent-ui-components/table-properties-each-cells-own ()
  "Its properties (put on the drawing once, not on each cell's string): each
cell's column over the cell, faces over its text, bars muted; a line's end
trimmed, its last cell's properties not past it (the next line's own)."
  (let* ((text (agent-ui-render '(:type "table" :columns ("Name" "State" "Note")
                                  :rows (("alpha" "passed" "") ("beta" "FAILED" "x")))
                                (agent-ui-context :width 60)))
         (lines (split-string (substring-no-properties text) "\n")))
    (should (equal lines '(" Name  │ State  │ Note" "───────┼────────┼─────" " alpha │ passed │" " beta  │ FAILED │ x")))
    (cl-flet ((at (line col) (+ (cl-loop for l in (seq-take lines line) sum (1+ (length l))) col))
              (prop (pos p) (get-text-property pos p text)))
      ;; The header: bold names, each its column, the bars muted.
      (should (eq (prop (at 0 1) 'face) 'bold))
      (should-not (prop (at 0 0) 'face))
      (should (eql (prop (at 0 0) 'agent-ui-table-column) 0))
      (should (eq (prop (at 0 7) 'face) 'agent-ui-muted))
      (should-not (prop (at 0 7) 'agent-ui-table-column))
      (should (eql (prop (at 0 9) 'agent-ui-table-column) 1))
      (should (eql (prop (at 0 (1- (length (nth 0 lines)))) 'agent-ui-table-column) 2))
      ;; A state's colour, by its whole text, any case.
      (should (eq (prop (at 2 9) 'face) 'agent-ui-success))
      (should (eq (prop (at 3 9) 'face) 'agent-ui-error))
      (should-not (prop (at 2 1) 'face))
      ;; "alpha"'s line ends at its bar (its empty last cell trimmed): the
      ;; newline and the next line aren't that cell's.
      (should-not (prop (at 2 (length (nth 2 lines))) 'agent-ui-table-column))
      (should (eql (prop (at 3 0) 'agent-ui-table-column) 0))
      (should (eql (prop (at 3 (1- (length (nth 3 lines)))) 'agent-ui-table-column) 2)))
    ;; A cell wrapped in its column: its state's colour and its column on
    ;; each of its lines.
    (let ((narrow (agent-ui-render '(:type "table" :columns ("N" "S") :rows (("a" "succeeded"))) (agent-ui-context :width 9))))
      (should (equal (substring-no-properties narrow) " N │ S\n───┼─────\n a │ succ\n   │ eede\n   │ d"))
      (dolist (piece '("succ" "eede" "d\\'"))
        (let ((at (string-match piece narrow)))
          (should (eq (get-text-property at 'face narrow) 'agent-ui-success))
          (should (eql (get-text-property at 'agent-ui-table-column narrow) 1))))
      ;; Under it, the first column's blank cell its column's still.
      (should-not (get-text-property (string-match "\n   │ eede" narrow) 'agent-ui-table-column narrow))
      (should (eql (get-text-property (1+ (string-match "\n   │ eede" narrow)) 'agent-ui-table-column narrow) 0)))))

;; doom-ord.4
(defconst agent-ui-test-aue-bugs
  '(:id "bugs" :type "table" :columns ("ID" "P" "Bug") :key "ID"
    :rows (("doom-1ms" "P2" "Tabs: a new buffer loses its tab")
           ("doom-3z6" "P2" "Large Markdown freezes Emacs")
           ("doom-nwj.22" "P2" "Stats: value and change overlap"))
    :select (:question "Which should I fix?" :multiple t :note t))
  "A table asking which bugs to fix.")

(ert-deftest agent-ui-components/table-select-picked-and-sent ()
  "A table with select: a mark before each row, the row picking it (RET, a
click), All / None, a note; Send puts its keys (in the table's order) and the
note into the prompt, at once; then it's answered, locked, its marks kept."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show agent-ui-test-aue-bugs)
      (with-current-buffer canvas
        (agent-ui--flush)
        (should (string-search "Which should I fix?\n     ID          │ P  │ Bug\n    ──"
                               (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-search "[ ]  doom-1ms" (buffer-string)))
        (should-error (agent-ui-test-aue-press "⏵ Answer (0 chosen)") :type 'user-error)
        ;; Picked by their rows, anywhere on them: the last first.
        (agent-ui-test-aue-press "Stats: value")
        (agent-ui-test-aue-press "doom-1ms")
        (should (equal (plist-get (agent-ui-get "bugs") :selected) '("doom-nwj.22" "doom-1ms")))
        (agent-ui--flush)
        (should (string-search "[x]  doom-1ms" (buffer-string)))
        (should (string-search "[ ]  doom-3z6" (buffer-string)))
        (should (string-search "⏵ Answer (2 chosen)   ⏵ All   ⏵ None" (buffer-string)))
        ;; All, None, again.
        (agent-ui-test-aue-press "⏵ All")
        (should (equal (plist-get (agent-ui-get "bugs") :selected) '("doom-1ms" "doom-3z6" "doom-nwj.22")))
        (agent-ui-test-aue-press "⏵ None")
        (agent-ui-test-aue-press "doom-nwj.22")
        (agent-ui-test-aue-press "doom-1ms")
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "the tabs first")))
          (agent-ui-test-aue-press "Add a note"))
        ;; Sorted by another column: still picked (by key).
        (agent-ui-update "bugs" '(:sort "Bug"))
        (agent-ui--flush)
        (should (string-search "[x]  doom-nwj.22" (buffer-string)))
        (agent-ui-test-aue-press "⏵ Answer (2 chosen)")
        (should (equal sent '(("Answer to bugs (Which should I fix?): doom-1ms, doom-nwj.22. Note: the tabs first" t))))
        (agent-ui--flush)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-search "✓ Answered: doom-1ms, doom-nwj.22 · note: the tabs first" text))
          (should (string-search "[x]  doom-1ms" text))
          (should-not (string-search "⏵" text)))
        ;; Locked: a row picks nothing now.
        (goto-char (point-min))
        (search-forward "doom-3z6")
        (should-not (get-text-property (match-beginning 0) 'agent-ui-action))))))

(ert-deftest agent-ui-components/table-select-one-and-its-first-column ()
  "One to pick: ( ) marks, another replacing it; without a key, rows answer
with their first cell; in a still picture: marks, no buttons."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "pick" :type "table" :columns ("Approach" "Cost") :rows (("rewrite" "high") ("patch" "low"))
                       :select (:question "Which?")))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "rewrite")
        (agent-ui-test-aue-press "patch")
        (should (equal (plist-get (agent-ui-get "pick") :selected) '("patch")))
        (agent-ui--flush)
        (should (string-search "( )  rewrite" (buffer-string)))
        (should (string-search "(•)  patch" (buffer-string)))
        (should-not (string-search "⏵ All" (buffer-string)))
        (agent-ui-test-aue-press "⏵ Answer (1 chosen)")
        (should (equal sent '(("Answer to pick (Which?): patch" t)))))))
  (let ((still (agent-ui-test-aue-draw (append agent-ui-test-aue-bugs '(:selected ("doom-3z6"))) :still t)))
    (should (string-search "[x]  doom-3z6" still))
    (should-not (string-search "⏵" still))
    (should-not (string-search "Add a note" still))))

(ert-deftest agent-ui-components/table-select-a-number-s-key ()
  "Rows whose key cells are numbers: picked before by their numbers, as
given (doom-ht6.66)."
  (let ((drawn (agent-ui-test-aue-draw '(:type "table" :columns ("N" "Name") :key 0 :rows ((1 "a") (2 "b"))
                                 :select (:question "Which?") :selected (2)))))
    (should (string-search "(•)  2" drawn))
    (should (string-search "( )  1" drawn))))

(ert-deftest agent-ui-components/table-select-a-row-appended-like-a-picked-one ()
  "Without a key, a row appended with the first cell of one picked: taken,
the picked one still picked, as it answers now (its cells) (doom-ht6.65)."
  (agent-ui-test-aue-canvas
    (agent-ui-show '(:id "t" :type "table" :columns ("Test" "Result") :rows (("lexer" "a") ("parser" "b"))
                     :select (:question "Which?" :multiple t) :selected ("lexer")))
    (agent-ui-append "t" '(:rows (("lexer" "c"))))
    (should (= (length (plist-get (agent-ui-get "t") :rows)) 3))
    (should (equal (plist-get (agent-ui-get "t") :selected) '("lexer · a")))))

(ert-deftest agent-ui-components/table-select-rows-sharing-a-key ()
  "Two rows with the same key cell: picking one marks only it, the answer
naming that row by its cells (both were marked, the answer their key);
sorted too; a unique key cell still answers alone."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "pick" :type "table" :columns ("Test" "Result" "OS")
                       :rows (("parser" "failed" "linux") ("parser" "failed" "macos") ("lexer" "passed" "linux"))
                       :select (:question "Which to rerun?" :multiple t)))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "macos")
        (should (equal (plist-get (agent-ui-get "pick") :selected) '("parser · failed · macos")))
        (agent-ui--flush)
        (should (string-search "[ ]  parser │ failed │ linux" (buffer-string)))
        (should (string-search "[x]  parser │ failed │ macos" (buffer-string)))
        (agent-ui-test-aue-press "lexer")
        (agent-ui-test-aue-press "⏵ Answer")
        (should (equal sent '(("Answer to pick (Which to rerun?): parser · failed · macos, lexer" t)))))))
  ;; Sorted: each row its own answer still.
  (let ((text (agent-ui-test-aue-draw '(:type "table" :columns ("Test" "OS") :sort "OS" :descending t
                                :rows (("parser" "linux") ("parser" "macos"))
                                :select (:question "Which?") :selected ("parser · linux")))))
    (should (string-search "( )  parser │ macos" text))
    (should (string-search "(•)  parser │ linux" text)))
  ;; Rows alike in every cell: numbered.
  (should (equal (agent-ui-table--row-answers '(("a" "x") ("a" "x") ("b" "y")) 0) '("a · x (1)" "a · x (2)" "b"))))

(ert-deftest agent-ui-components/table-select-wrong ()
  (should (string-match-p "select is {\"question\""
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows (("a")) :select "yes"))))
  (should (string-match-p "select has \"multi\""
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows (("a")) :select (:question "?" :multi t)))))
  (should (string-match-p "select's question is required"
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows (("a")) :select (:multiple t)))))
  (should (string-match-p "selected \"z\" isn't an option"
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows (("a")) :select (:question "?") :selected ("z")))))
  (should (string-match-p "one option only"
                          (agent-ui-test-aue-error '(:type "table" :columns ("A") :rows (("a") ("b")) :select (:question "?") :selected ("a" "b"))))))

;; doom-s84
(ert-deftest agent-ui-components/table-select-wrapped-row ()
  "Asking, a row wrapped onto more lines: those under its cells, past its
mark, all of it picking the row."
  (let* ((text (agent-ui-render '(:type "table" :columns ("ID" "Title") :key "ID"
                                  :select (:question "Which?" :multiple t)
                                  :rows (("a1" "a rather long title that wraps over lines") ("b2" "short")))
                                (agent-ui-context :width 30)))
         (plain (substring-no-properties text)))
    (should (string-search (concat "     ID │ Title\n"
                                   "    ────┼─────────────────────\n"
                                   "[ ]  a1 │ a rather long title\n"
                                   "        │ that wraps over\n"
                                   "        │ lines\n"
                                   "[ ]  b2 │ short\n")
                           plain))
    (dolist (word '("a rather" "that wraps" "lines"))
      (should (get-text-property (string-search word plain) 'agent-ui-action text)))))

(ert-deftest agent-ui-components/table-appended-draws-only-its-rows ()
  "Rows appended to a table: their lines after the others (before what's
left out), not drawn whole, the same as drawn whole; drawn whole when a
column widens, it's sorted, or its rows are more than drawn."
  (agent-ui-test-aue-canvas
    (with-current-buffer canvas
      (agent-ui-show (list :id "t" :type "table" :columns '("Test" "Result" "Time")
                           :rows (mapcar (lambda (i) (list (format "test_%03d" i) "passed" (format "%.1fs" (/ i 10.0))))
                                         (number-sequence 1 300))))
      (agent-ui--flush)
      (agent-ui-test-aue--counting-whole-draws
        (agent-ui-append "t" '(:rows (("test_301" "FAILED" "0.2s"))))
        (agent-ui--flush)
        (agent-ui-append "t" '(:rows (("test_302" "passed" "1.0s") ("test_303" "error" ""))))
        (agent-ui--flush)
        (should-not whole)
        (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "t") (agent-ui-test-aue--drawn-whole "t")))
        (should (string-suffix-p " test_303 │ error  │" (substring-no-properties (agent-ui-test-aue--region "t"))))
        ;; A wider cell: the column widens, drawn whole.
        (agent-ui-append "t" '(:rows (("a much longer test name" "passed" "1s"))))
        (agent-ui--flush)
        (should (equal whole '("t")))
        (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "t") (agent-ui-test-aue--drawn-whole "t"))))
      ;; Columns left out: the rows before their note.
      (agent-ui-show (list :id "w" :type "table" :columns (mapcar (lambda (i) (format "C%d" i)) (number-sequence 1 30))
                           :rows (list (mapcar (lambda (i) (format "cell%d" i)) (number-sequence 1 30)))))
      (agent-ui--flush)
      (agent-ui-test-aue--counting-whole-draws
        (agent-ui-append "w" (list :rows (list (mapcar (lambda (i) (format "x%d" i)) (number-sequence 1 30)))))
        (agent-ui--flush)
        (should-not whole)
        (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "w") (agent-ui-test-aue--drawn-whole "w")))
        (should (string-match-p "\n … [0-9]+ more columns: \\(.\\|\n   \\)*\\'"
                                (substring-no-properties (agent-ui-test-aue--region "w")))))
      ;; Sorted: drawn whole.
      (agent-ui-show '(:id "s" :type "table" :columns ("N") :sort "N" :rows (("b") ("c"))))
      (agent-ui--flush)
      (agent-ui-test-aue--counting-whole-draws
        (agent-ui-append "s" '(:rows (("a"))))
        (agent-ui--flush)
        (should (equal whole '("s")))
        (should (string-search " a\n b\n c" (substring-no-properties (agent-ui-test-aue--region "s"))))))))

;; doom-s84
(ert-deftest agent-ui-components/table-appended-wrapped-rows ()
  "Rows appended whose cells wrap: their lines after the others, not drawn
whole, the same as drawn whole."
  (agent-ui-test-aue-canvas
    (with-current-buffer canvas
      (agent-ui-show (list :id "t" :type "table" :columns '("Option" "Costs")
                           :rows (list (list "Files" (mapconcat #'identity (make-list 30 "a format to keep") " ")))))
      (agent-ui--flush)
      (agent-ui-test-aue--counting-whole-draws
        (agent-ui-append "t" '(:rows (("DB" "more records to keep; no cycles, so retries need care, and every one of those takes a while"))))
        (agent-ui--flush)
        (should-not whole)
        (should (agent-ui-test-aue--same-drawing-p (agent-ui-test-aue--region "t") (agent-ui-test-aue--drawn-whole "t")))
        (should (string-match-p "\n DB +│ more records to keep.*\n +│ [a-z]"
                                (substring-no-properties (agent-ui-test-aue--region "t"))))))))

(ert-deftest agent-ui-components/table-without-column-names ()
  ;; No column named: no header nor rule, the rows alone.
  (should (equal (agent-ui-test-aue-draw '(:type "table" :columns ("" "") :rows (("build" "29s") ("tests" "1.4s"))))
                 " build │ 29s\n tests │ 1.4s"))
  (should (equal (agent-ui-test-aue-draw '(:type "table" :columns ("") :rows ()))
                 " no rows yet"))
  ;; One named: the header, as before.
  (should (string-match-p "\\` +│ Time\n─+┼─+\n" (agent-ui-test-aue-draw '(:type "table" :columns ("" "Time") :rows (("a" "1")))))))

(ert-deftest agent-ui-components/table-sorted ()
  (let ((component '(:type "table" :columns ("Test" "Time")
                   :rows (("parser" "1.1s") ("lexer" "10.2s") ("codegen" nil) ("Checker" "0.7s")))))
    ;; By a column's name: as numbers where they're numbers, empty last; the
    ;; column marked.
    (should (equal (agent-ui-test-aue-draw (append component '(:sort "Time")))
                   (concat " Test    │ Time ↑\n"
                           "─────────┼───────\n"
                           " Checker │ 0.7s\n"
                           " parser  │ 1.1s\n"
                           " lexer   │ 10.2s\n"
                           " codegen │")))
    ;; By index, the other way; text without case.
    (should (string-match-p "\\` Test ↓ +│ Time\n.*\n parser .*\n lexer .*\n codegen .*\n Checker "
                            (agent-ui-test-aue-draw (append component '(:sort 0 :descending t)))))
    ;; Not a column: said so.
    (should (string-match-p "table: sort must be a column" (agent-ui-test-aue-error (append component '(:sort "Size")))))))

(ert-deftest agent-ui-components/table-sorted-in-the-canvas ()
  (let* ((agent-ui-default-canvas (make-temp-name "table-"))
         (agent-ui-display-function #'ignore)
         (canvas (agent-ui-canvas)))
    (unwind-protect
        (with-current-buffer canvas
          (agent-ui-show '(:id "t" :type "table" :columns ("Name" "Size") :rows (("b" 2) ("a" 10) ("c" 1))))
          (agent-ui--flush)
          (cl-flet ((rows () (agent-ui--flush)
                      (mapcar (lambda (l) (car (split-string l)))
                              (cddr (split-string (string-trim (buffer-string)) "\n")))))
            ;; s on the Size column: by it; again: the other way.
            (goto-char (point-min))
            (search-forward "10")
            (backward-char)
            (agent-ui-table-sort)
            (should (equal (plist-get (agent-ui-get "t") :sort) "Size"))
            (should (equal (rows) '("c" "b" "a")))
            (goto-char (point-min))
            (search-forward "Size")
            (agent-ui-table-sort)
            (should (eq (plist-get (agent-ui-get "t") :descending) t))
            (should (equal (rows) '("a" "b" "c")))
            ;; Another column: ascending again.
            (goto-char (point-min))
            (search-forward "Name")
            (agent-ui-table-sort)
            (should (equal (rows) '("a" "b" "c")))
            (should-not (plist-get (agent-ui-get "t") :descending))
            ;; Elsewhere: nothing to sort.
            (goto-char (point-max))
            (should-error (agent-ui-table-sort) :type 'user-error)))
      (kill-buffer canvas))))

(ert-deftest agent-ui-components/table-row-actions ()
  (let* ((component '(:type "table" :columns ("Test" "Result")
                    :rows (("lexer" "passed") ("checker" "failed"))
                    :row-actions ((:label "Fix" :prompt "Fix {Test}: it {Result}. ({row}, {Other})")
                                  (:label "Run" :prompt "Run {Test}" :submit t))))
         (text (agent-ui-render component (agent-ui-context :width 60)))
         (sent nil)
         (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
    ;; Buttons at each row's end.
    (should (string-match-p "^ checker │ failed  ⏵ Fix  ⏵ Run$" (substring-no-properties text)))
    ;; Pressed: their prompts with the row's cells.
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (search-forward "checker")
      (search-forward "⏵ Fix")
      (backward-char)
      (agent-ui-button-press)
      (search-forward "⏵ Run")
      (backward-char)
      (agent-ui-button-press))
    (should (equal (reverse sent)
                   '(("Fix checker: it failed. (Test: checker, Result: failed, {Other})" nil)
                     ("Run checker" t))))
    ;; Wrong ones: said so.
    (should (string-match-p "table: row-actions: action 1 must be"
                            (agent-ui-test-aue-error '(:type "table" :columns ("A") :row-actions ("x")))))))

;;; agent-ui-table-tests.el ends here
