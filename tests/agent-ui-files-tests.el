;;; agent-ui-files-tests.el --- Tests for Agent UI: the files component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-files.el: the files component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

;; doom-ord.5
(ert-deftest agent-ui-components/files-select ()
  "Files asking: a mark before each, picking it (RET on its name still opens
it); a folder's mark picks its files ([-]: some); Send names their paths in
order."
  (agent-ui-test-aue-canvas
    (let* ((sent nil) (opened nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent)))
           (agent-ui-open-file-function (lambda (f) (push f opened))))
      (agent-ui-show '(:id "f" :type "files" :tree t :dir "/work/"
                       :files ((:path "src/parser.c" :status "changed") (:path "src/lexer.h" :status "added")
                               (:path "tests/t.c" :status "failing"))
                       :select (:question "Which should I change?" :multiple t)))
      (with-current-buffer canvas
        (agent-ui--flush)
        (should (string-search "Which should I change?\n[ ] ▾ src/\n[ ]     M parser.c" (buffer-string)))
        ;; Its name opens it, its mark picks it.
        (agent-ui-test-aue-press "parser.c")
        (should (equal opened '("/work/src/parser.c")))
        (should-not (plist-get (agent-ui-get "f") :selected))
        (goto-char (point-min))
        (search-forward "parser.c")
        (beginning-of-line)
        (agent-ui-button-press)
        (agent-ui--flush)
        (should (equal (plist-get (agent-ui-get "f") :selected) '("src/parser.c")))
        (should (string-search "[-] ▾ src/" (buffer-string)))
        ;; The folder's mark: all its files, then none.
        (goto-char (point-min)) (search-forward "▾ src/") (beginning-of-line) (agent-ui-button-press)
        (should (equal (plist-get (agent-ui-get "f") :selected) '("src/parser.c" "src/lexer.h")))
        (agent-ui--flush)
        (should (string-search "[x] ▾ src/" (buffer-string)))
        (goto-char (point-min)) (search-forward "▾ tests/") (beginning-of-line) (agent-ui-button-press)
        (agent-ui-test-aue-press "⏵ Answer (3 chosen)")
        (should (equal sent '(("Answer to f (Which should I change?): src/parser.c, src/lexer.h, tests/t.c" t))))
        (agent-ui--flush)
        (should (string-search "✓ Answered: src/parser.c, src/lexer.h, tests/t.c" (buffer-string))))))
  (should (string-match-p "selected \"nope.c\" isn't an option"
                          (agent-ui-test-aue-error '(:type "files" :files ("a.c") :select (:question "?") :selected ("nope.c")))))
  (should (string-match-p "select's question is required"
                          (agent-ui-test-aue-error '(:type "files" :files ("a.c") :select (:note t))))))

(ert-deftest agent-ui-components/files-flat-and-tree ()
  (let ((files '((:path "src/parser.c" :status "changed" :added 12 :removed 3)
                 (:path "src/lexer.h" :status "added" :added 40)
                 (:path "tests/parser_test.c" :status "failing" :errors 1 :line 88)
                 "README.md")))
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files files))
                   (concat "M src/parser.c         +12 −3\n"
                           "A src/lexer.h          +40\n"
                           "✗ tests/parser_test.c  1 error\n"
                           "  README.md")))
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files files :tree t))
                   (concat "▾ src/\n"
                           "    M parser.c  +12 −3\n"
                           "    A lexer.h   +40\n"
                           "▾ tests/\n"
                           "    ✗ parser_test.c  1 error\n"
                           "  README.md")))
    (should (eq (agent-ui-test-aue-face-at (list :type "files" :files files) "✗") 'agent-ui-error))
    (should (equal (agent-ui-test-aue-draw '(:type "files")) "no files"))))

;; doom-nwj.64
(ert-deftest agent-ui-components/files-fit-the-width ()
  "At widths 15 to 60, flat or a tree, folded or not: every line within the
width, each file's name (or its end) shown. The name column was the width
less 20 (or 24): under that, names went (\"M   +1200 −345 12 errors needs
review\" at 20), and the counts, a name without them and folder lines were
never cut."
  (let ((files '((:path "src/components/very/deep/path/parser_module.c" :status "changed"
                  :added 1200 :removed 345 :errors 12 :note "needs review")
                 (:path "src/a_really_long_file_name_without_counts_at_all.c" :status "deleted")
                 (:path "lib/x.c" :status "added" :added 3))))
    (dolist (width (number-sequence 15 60))
      (dolist (tree '(nil t))
        (dolist (folded (if tree '(nil ("src/components/very/deep/path/")) '(nil)))
          (let ((lines (split-string (agent-ui-test-aue-draw (list :type "files" :files files :tree tree :folded folded)
                                                     :width width)
                                     "\n")))
            (dolist (line lines) (should (<= (string-width line) width)))
            (unless folded
              ;; Each file's name, or its end.
              (dolist (end '("le.c" "all.c" "x.c"))
                (should (seq-some (lambda (line) (string-match-p (concat "[…/]?" (regexp-quote end) "\\b") line))
                                  lines))))))))
    ;; The name narrowed first (8 columns at least), then the note cut; the
    ;; counts whole or left out (\"+12…\" misread +1200), the name taking
    ;; their room.
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files files) :width 50)
                   (concat "M …ser_module.c  +1200 −345 12 errors needs review\n"
                           "D …a_really_long_file_name_without_counts_at_all.c\n"
                           "A lib/x.c        +3")))
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files (list (car files))) :width 40)
                   "M …odule.c  +1200 −345 12 errors needs …"))
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files files) :width 15)
                   "M …ser_module.c\nD …nts_at_all.c\nA lib/x.c   +3"))
    ;; A tree's folder line: cut at its start too.
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files files :tree t) :width 20)
                   (concat "▾ …s/very/deep/path/\n"
                           "    M …rser_module.c\n"
                           "▾ src/\n"
                           "    D …unts_at_all.c\n"
                           "▾ lib/\n"
                           "    A x.c  +3")))))

(ert-deftest agent-ui-components/files-long-note-cut-not-the-names ()
  "One long note is cut, the paths whole when they fit (it squeezed every
name to 8 columns: \"M …arser.c  +12345 −3 A rather long…\" at 100)."
  (let ((files '(:type "files"
                 :files ((:path "src/parser.c" :status "changed" :added 12345 :removed 3
                          :note "A rather long note about why this file changed so much, and more")
                         (:path "tests/parser_test.c" :status "failing" :errors 2)))))
    (dolist (width '(60 80 100))
      (let ((text (agent-ui-test-aue-draw files :width width)))
        (should (string-match-p "^M src/parser\\.c +\\+12345 −3 A rather" text))
        (should (string-match-p "^✗ tests/parser_test\\.c  2 errors$" text))))
    (should (string-match-p "A rather long note about w…$" (agent-ui-test-aue-draw files :width 60)))))

;; doom-nwj.90
(ert-deftest agent-ui-components/files-paths-written-differently ()
  "./src/a.c, src//b.c and src/c.c are in one src/ folder (they made three),
and a path ending in / is that folder, its mark and counts on its line (it
was a file without a name: a blank row)."
  (let ((files '("./src/a.c" "src//b.c" (:path "src/c.c" :status "changed" :added 2)
                 (:path "build/" :status "deleted" :removed 40) "./README.md" "src/./d.c")))
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files files :tree t))
                   (concat "▾ src/\n"
                           "      a.c\n"
                           "      b.c\n"
                           "    M c.c  +2\n"
                           "      d.c\n"
                           "▾ D build/  −40\n"
                           "  README.md")))
    ;; Flat: written one way too.
    (should (equal (agent-ui-test-aue-draw (list :type "files" :files '("./src/a.c" "src//b.c")))
                   "  src/a.c\n  src/b.c"))
    (should (equal (plist-get (agent-ui-check "files" '(:files ("./a//b.c" "../x.c" "./"))) :files)
                   '((:path "a/b.c" :status none) (:path "../x.c" :status none) (:path "./" :status none))))
    ;; No blank row: each line has a name.
    (dolist (line (split-string (agent-ui-test-aue-draw (list :type "files" :files files :tree t)) "\n"))
      (should (string-match-p "[[:alnum:]]" line)))))

(ert-deftest agent-ui-components/files-open-and-fold ()
  (agent-ui-test-aue-canvas
    (let* ((opened nil)
           (agent-ui-open-file-function (lambda (f) (push f opened) (set-buffer (get-buffer-create " *opened*")))))
      (with-current-buffer (get-buffer-create " *opened*") (erase-buffer) (insert (make-string 100 ?\n)))
      (agent-ui-show '(:id "f" :type "files" :tree t :dir "/work/"
                       :files ((:path "src/a.c" :status "changed") (:path "tests/t.c" :status "failing" :line 42))))
      (with-current-buffer canvas
        ;; A file: opened at its line.
        (agent-ui-test-aue-press "t.c")
        (should (equal (car opened) "/work/tests/t.c"))
        (should (= (with-current-buffer " *opened*" (line-number-at-pos)) 42))
        ;; A folder: folded, its files counted; again, unfolded.
        (agent-ui-test-aue-press "src/")
        (agent-ui--flush)
        (should (equal (plist-get (agent-ui-get "f") :folded) '("src/")))
        (should (string-match-p "▸ src/  1 files\n▾ tests/" (buffer-string)))
        (agent-ui-test-aue-press "src/")
        (should-not (plist-get (agent-ui-get "f") :folded))))
    (kill-buffer " *opened*")))

(ert-deftest agent-ui-components/files-wrong ()
  (should (string-match-p "file 2 has no path" (agent-ui-test-aue-error '(:type "files" :files ("a" (:status "added"))))))
  (should (string-match-p "status \"edited\"" (agent-ui-test-aue-error '(:type "files" :files ((:path "a" :status "edited"))))))
  (should (string-match-p "file 1's added must be a count" (agent-ui-test-aue-error '(:type "files" :files ((:path "a" :added -1))))))
  (should (string-match-p "has \"size\"" (agent-ui-test-aue-error '(:type "files" :files ((:path "a" :size 3)))))))

;;; agent-ui-files-tests.el ends here
