;;; agent-ui-diff-tests.el --- Tests for Agent UI: the diff component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-diff.el: the diff component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defconst agent-ui-test-aue-diff
  "diff --git a/src/parser.c b/src/parser.c
index 1111111..2222222 100644
--- a/src/parser.c
+++ b/src/parser.c
@@ -40,4 +40,5 @@ parse_expr
   int depth = 0;
-  return NULL;
+  if (!p) return NULL;
+  return parse_term(p);
 }
\\ No newline at end of file
diff --git a/README.md b/README.md
new file mode 100644
--- /dev/null
+++ b/README.md
@@ -0,0 +1,2 @@
+# Parser
+A parser.
")

(ert-deftest agent-ui-components/diff ()
  (let* ((opened nil)
         (agent-ui-open-file-function (lambda (f) (push f opened) (set-buffer (get-buffer-create " *opened*"))))
         (component (list :type "diff" :diff agent-ui-test-aue-diff :dir "/work/"))
         (text (agent-ui-render component (agent-ui-context :width 60))))
    (should (equal (substring-no-properties text)
                   (concat "▾ src/parser.c  +2 −1\n"
                           "  @@ -40,4 +40,5 @@ parse_expr\n"
                           "     40     int depth = 0;\n"
                           "        −   return NULL;\n"
                           "     41 +   if (!p) return NULL;\n"
                           "     42 +   return parse_term(p);\n"
                           "     43   }\n"
                           "        \\ No newline at end of file\n"
                           "▾ README.md  +2 −0\n"
                           "  @@ -0,0 +1,2 @@\n"
                           "      1 + # Parser\n"
                           "      2 + A parser.")))
    (should (eq (agent-ui-test-aue-face-at component "+2 −1") 'agent-ui-success))
    (should (eq (get-text-property (string-search "−   return" text) 'face text) 'agent-ui-error))
    ;; RET on an added line: its file, at its line.
    (funcall (get-text-property (string-search "if (!p)" text) 'agent-ui-action text))
    (should (equal (car opened) "/work/src/parser.c"))
    (should (= (with-current-buffer " *opened*" (line-number-at-pos)) 1))
    (kill-buffer " *opened*")
    ;; In the GUI: added and removed lines on a tint as wide as the pane.
    (let ((gui (agent-ui-render component (agent-ui-context :width 60 :graphic t))))
      (should (seq-some (lambda (f) (and (consp f) (keywordp (car f)) (plist-get f :background)))
                        (ensure-list (get-text-property (string-search "−   return" gui) 'face gui))))
      (should (= (string-width (nth 3 (split-string (substring-no-properties gui) "\n"))) 60))))
  (should (equal (agent-ui-test-aue-draw '(:type "diff" :diff "")) "no changes"))
  ;; Too many lines: what's left out said.
  (let ((agent-ui-max-rows 3))
    (should (string-suffix-p "… 5 lines more" (agent-ui-test-aue-draw (list :type "diff" :diff agent-ui-test-aue-diff))))))

;; doom-nwj.65
(ert-deftest agent-ui-components/diff-removed-lines-open-where-they-were ()
  "RET on a removed line opens the new file where it was (it opened at the
old file's number: off by every earlier hunk's change in lines)."
  (let* ((diff (concat "--- a/src/parser.c\n+++ b/src/parser.c\n"
                       "@@ -10,3 +10,5 @@\n a\n+b\n+c\n d\n e\n"
                       "@@ -100,4 +102,3 @@\n x\n-gone1\n-gone2\n+new\n y\n"))
         (opened nil)
         (agent-ui-open-file-function (lambda (f) (push f opened) (set-buffer (get-buffer-create " *opened*"))))
         (text (agent-ui-render (list :type "diff" :diff diff :dir "/work/") (agent-ui-context :width 60))))
    (with-current-buffer (get-buffer-create " *opened*") (erase-buffer) (insert (make-string 200 ?\n)))
    (unwind-protect
        (cl-flet ((target (what)
                    (funcall (get-text-property (string-search what text) 'agent-ui-action text))
                    (with-current-buffer " *opened*" (line-number-at-pos))))
          (should (= (target "x") 102))
          (should (= (target "gone1") 103))
          (should (= (target "gone2") 103))
          (should (= (target "new") 103))
          (should (= (target "y") 104))
          (should (equal (car opened) "/work/src/parser.c")))
      (kill-buffer " *opened*"))))

;; doom-nwj.66
(ert-deftest agent-ui-components/diff-header-fits ()
  "A file's header is cut to the width, its path at its start, its counts
kept (it was never cut: 49 columns at 20, the canvas hiding its counts)."
  (let ((component '(:type "diff" :diff "--- a/src/components/very/deep/parser_module.c
+++ b/src/components/very/deep/parser_module.c
@@ -1,2 +1,2 @@
-old
+new
 same
")))
    (dolist (width '(12 15 20 30 40 60))
      (dolist (gui '(nil t))
        (let ((header (car (split-string (agent-ui-test-aue-draw component :width width :graphic gui) "\n"))))
          (should (<= (string-width header) width))
          (should (string-suffix-p "  +1 −1" header)))))
    (should (equal (car (split-string (agent-ui-test-aue-draw component :width 30) "\n"))
                   "▾ …deep/parser_module.c  +1 −1"))
    (should (equal (car (split-string (agent-ui-test-aue-draw component :width 60) "\n"))
                   "▾ src/components/very/deep/parser_module.c  +1 −1"))))

;; doom-nwj.67
(ert-deftest agent-ui-components/diff-files-not-from-git ()
  "A hunk ends when its counts are used up: diff -u outputs one after
another, diff -ru and a patch (format-patch's) show each file apart, its
signature not a line (they were merged into the first file)."
  (let ((two (concat "--- x.c\t2024-01-01 10:00:00\n+++ x.c\t2024-01-02 10:00:00\n"
                     "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
                     "--- y.c\t2024-01-01 10:00:00\n+++ y.c\t2024-01-02 10:00:00\n"
                     "@@ -1,2 +1,2 @@\n-p\n+P\n q\n"))
        (ru (concat "diff -ru a/x.c b/x.c\n--- a/x.c\t2024-01-01\n+++ b/x.c\t2024-01-02\n"
                    "@@ -1 +1 @@\n-old\n+new\n"
                    "diff -ru a/y.c b/y.c\n--- a/y.c\t2024-01-01\n+++ b/y.c\t2024-01-02\n"
                    "@@ -1,2 +1,3 @@\n p\n+P\n q\n"
                    "Only in b: z.c\n"))
        (patch (concat "From 1234 Mon Sep 17 00:00:00 2001\nFrom: A <a@b.c>\nSubject: [PATCH] Fix it\n\n"
                       "---\n x.c | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n\n"
                       "diff --git a/x.c b/x.c\nindex 1111..2222 100644\n--- a/x.c\n+++ b/x.c\n"
                       "@@ -1,2 +1,2 @@\n-a\n+b\n c\n-- \n2.39.0\n\n")))
    (should (equal (agent-ui-test-aue-draw (list :type "diff" :diff two))
                   (concat "▾ x.c  +1 −1\n  @@ -1,3 +1,3 @@\n"
                           "      1   a\n        − b\n      2 + B\n      3   c\n"
                           "▾ y.c  +1 −1\n  @@ -1,2 +1,2 @@\n"
                           "        − p\n      1 + P\n      2   q")))
    (should (equal (agent-ui-test-aue-draw (list :type "diff" :diff ru))
                   (concat "▾ x.c  +1 −1\n  @@ -1 +1 @@\n        − old\n      1 + new\n"
                           "▾ y.c  +1 −0\n  @@ -1,2 +1,3 @@\n      1   p\n      2 + P\n      3   q")))
    (should (equal (agent-ui-test-aue-draw (list :type "diff" :diff patch))
                   "▾ x.c  +1 −1\n  @@ -1,2 +1,2 @@\n        − a\n      1 + b\n      2   c"))
    ;; Counts written wrong by hand (too few): its lines kept.
    (should (equal (agent-ui-test-aue-draw (list :type "diff" :diff "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n c\n+d\n"))
                   "▾ f  +2 −1\n  @@ -1 +1 @@\n        − a\n      1 + b\n      2   c\n      3 + d"))))

;; doom-nwj.68
(ert-deftest agent-ui-components/diff-quoted-names ()
  "git quotes names that aren't ASCII or have a quote (core.quotePath):
unquoted, their octal escapes UTF-8 (shown escaped, and RET opened
\".../\\\"b/\\317...\")."
  (let* ((diff (concat "diff --git \"a/\\317\\203\\316\\267\\316\\274\\316\\265\\316\\271\\317\\216\\317\\203\\316\\265\\316\\271\\317\\202.md\" \"b/\\317\\203\\316\\267\\316\\274\\316\\265\\316\\271\\317\\216\\317\\203\\316\\265\\316\\271\\317\\202.md\"\nindex 1111..2222 100644\n"
                       "--- \"a/\\317\\203\\316\\267\\316\\274\\316\\265\\316\\271\\317\\216\\317\\203\\316\\265\\316\\271\\317\\202.md\"\n+++ \"b/\\317\\203\\316\\267\\316\\274\\316\\265\\316\\271\\317\\216\\317\\203\\316\\265\\316\\271\\317\\202.md\"\n@@ -1 +1 @@\n-a\n+b\n"
                       "diff --git \"a/with \\\"quote\\\".txt\" \"b/with \\\"quote\\\".txt\"\nnew file mode 100644\n"
                       "--- /dev/null\n+++ \"b/with \\\"quote\\\".txt\"\n@@ -0,0 +1 @@\n+x\n"
                       "diff --git a/plain.txt \"b/\\317\\203\\316\\267\\316\\274\\316\\265\\316\\271\\317\\216\\317\\203\\316\\265\\316\\271\\317\\202.md\"\nsimilarity index 100%\n"))
         (opened nil)
         (agent-ui-open-file-function (lambda (f) (push f opened)))
         (text (agent-ui-render (list :type "diff" :diff diff :dir "/work/") (agent-ui-context :width 60))))
    (should (equal (substring-no-properties text)
                   (concat "▾ σημειώσεις.md  +1 −1\n  @@ -1 +1 @@\n        − a\n      1 + b\n"
                           "▾ with \"quote\".txt  +1 −0\n  @@ -0,0 +1 @@\n      1 + x\n"
                           "▾ σημειώσεις.md  +0 −0")))
    (funcall (get-text-property 3 'agent-ui-action text))
    (should (equal (car opened) "/work/σημειώσεις.md"))
    (funcall (get-text-property (string-search "with" text) 'agent-ui-action text))
    (should (equal (car opened) "/work/with \"quote\".txt"))
    ;; A deleted one: its old name.
    (should (string-prefix-p "▾ σημειώσεις.md  +0 −1"
                             (agent-ui-test-aue-draw '(:type "diff" :diff "--- \"a/\\317\\203\\316\\267\\316\\274\\316\\265\\316\\271\\317\\216\\317\\203\\316\\265\\316\\271\\317\\202.md\"\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n"))))))

;; doom-nwj.78
(ert-deftest agent-ui-components/diff-six-digit-line-numbers ()
  "The line numbers' gutter is as wide as the largest number (it was 5
digits: lines from 100000 a column past the width)."
  (let ((component (list :type "diff" :diff (concat "--- a/big.c\n+++ b/big.c\n@@ -99999,2 +99999,3 @@\n"
                                                  " a\n-" (make-string 40 ?o) "\n+" (make-string 40 ?n)
                                                  "\n+b\n"))))
    (dolist (gui '(nil t))
      (dolist (line (split-string (agent-ui-test-aue-draw component :width 30 :graphic gui) "\n"))
        (should (<= (string-width line) 30))))
    (should (equal (agent-ui-test-aue-draw component :width 30)
                   (concat "▾ big.c  +2 −1\n  @@ -99999,2 +99999,3 @@\n"
                           "   99999   a\n"
                           "         − ooooooooooooooooooo\n"
                           "           ooooooooooooooooooo\n"
                           "           oo\n"
                           "  100000 + nnnnnnnnnnnnnnnnnnn\n"
                           "           nnnnnnnnnnnnnnnnnnn\n"
                           "           nn\n"
                           "  100001 + b"))))
  ;; Up to 5 digits: as before.
  (should (string-match-p "^     40   a$" (agent-ui-test-aue-draw '(:type "diff" :diff "@@ -40 +40 @@\n a\n")))))

;; doom-nwj.79
(ert-deftest agent-ui-components/diff-stops-at-its-cap ()
  "Past `agent-ui-max-rows' lines nothing more is drawn but what's left out
(later files and hunks were drawn, empty, the note at the very end)."
  (let ((agent-ui-max-rows 4)
        (diff (concat "--- a/a.c\n+++ b/a.c\n@@ -1,3 +1,6 @@\n x\n+1\n+2\n+3\n y\n z\n"
                      "--- a/b.c\n+++ b/b.c\n@@ -1 +1,2 @@\n p\n+q\n@@ -9 +10,2 @@\n r\n+s\n")))
    (should (equal (agent-ui-test-aue-draw (list :type "diff" :diff diff))
                   (concat "▾ a.c  +3 −0\n  @@ -1,3 +1,6 @@\n"
                           "      1   x\n      2 + 1\n      3 + 2\n      4 + 3\n"
                           "… 6 lines more")))
    ;; Ending at a hunk's end: the next file not begun.
    (let ((agent-ui-max-rows 6))
      (should (string-suffix-p "      6   z\n… 4 lines more" (agent-ui-test-aue-draw (list :type "diff" :diff diff)))))
    ;; All of it within the cap: all drawn, no note.
    (let ((agent-ui-max-rows 10))
      (should (string-suffix-p "     11 + s" (agent-ui-test-aue-draw (list :type "diff" :diff diff)))))))

;; doom-nwj.85
(ert-deftest agent-ui-components/diff-names-with-b-slash ()
  "A name with \" b/\" in it: a rename's new name from its rename to line,
others' where diff --git's halves match (split at the first \" b/\", a
rename of x b/y.txt to c b/a.txt was named \"y.txt b/c b/a.txt\")."
  (should (equal (agent-ui-test-aue-draw '(:type "diff" :diff "diff --git a/x b/y.txt b/c b/a.txt
similarity index 100%
rename from x b/y.txt
rename to c b/a.txt
"))
                 "▾ c b/a.txt  +0 −0"))
  (should (equal (agent-ui-test-aue-draw '(:type "diff" :diff "diff --git a/p b/q.c b/p b/q.c
old mode 100644
new mode 100755
"))
                 "▾ p b/q.c  +0 −0"))
  ;; A rename with changes: its +++ line agrees.
  (should (string-prefix-p "▾ c b/a.txt  +1 −1"
                           (agent-ui-test-aue-draw '(:type "diff" :diff "diff --git a/x b/y.txt b/c b/a.txt
similarity index 90%
rename from x b/y.txt
rename to c b/a.txt
--- a/x b/y.txt
+++ b/c b/a.txt
@@ -1 +1 @@
-a
+b
"))))
  ;; As before: a plain name.
  (should (equal (agent-ui-diff--git-name "a/src/x.c b/src/x.c") "src/x.c")))

;; doom-nwj.86
(ert-deftest agent-ui-components/diff-combined ()
  "A combined diff (git diff during a merge, diff --cc): its @@@ hunks' lines
read, a mark for each parent (it was an empty file, \"+0 −0\")."
  ;; As git writes a conflict.
  (let ((diff "diff --cc f.c
index 9740c89,a7bc997..0000000
--- a/f.c
+++ b/f.c
@@@ -1,5 -1,4 +1,11 @@@
  a
++<<<<<<< HEAD
 +b2
++||||||| 38bcd62
++b
++=======
+ B
++>>>>>>> other
  c
  d
 +e
diff --cc g.c
index 1,2..3
--- a/g.c
+++ b/g.c
@@@ -1,3 -1,3 +1,2 @@@
  x
- y
 -z
  w
"))
    (should (equal (agent-ui-test-aue-draw (list :type "diff" :diff diff))
                   (concat "▾ f.c  +8 −0\n  @@@ -1,5 -1,4 +1,11 @@@\n"
                           "      1   a\n      2 + <<<<<<< HEAD\n      3 + b2\n      4 + ||||||| 38bcd62\n"
                           "      5 + b\n      6 + =======\n      7 + B\n      8 + >>>>>>> other\n"
                           "      9   c\n     10   d\n     11 + e\n"
                           "▾ g.c  +0 −2\n  @@@ -1,3 -1,3 +1,2 @@@\n"
                           "      1   x\n        − y\n        − z\n      2   w")))))

;; doom-nwj.87
(ert-deftest agent-ui-components/diff-no-newline-note-aligned ()
  "git's \"\\ No newline at end of file\" is drawn like other lines: its
mark, one space, its words (it had two spaces)."
  (let ((lines (split-string (agent-ui-test-aue-draw '(:type "diff" :diff "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"))
                             "\n")))
    (should (equal (nthcdr 2 lines)
                   '("        − a" "        \\ No newline at end of file"
                     "      1 + b" "        \\ No newline at end of file")))
    ;; Its words start where other lines' do.
    (should (= (string-search "No" (nth 3 lines)) (string-search "a" (nth 2 lines))))))

(ert-deftest agent-ui-components/diff-dir-the-agents ()
  ;; Its dir: the agent's directory, when shown (relative names resolve there).
  (let ((agent-ui-file-directory "/proj/")
        (agent-ui-default-canvas (make-temp-name "diff-"))
        (agent-ui-display-function #'ignore))
    (unwind-protect
        (progn
          (agent-ui-show '(:id "d" :type "diff" :diff ""))
          (should (equal (plist-get (agent-ui-get "d") :dir) "/proj/"))
          (agent-ui-show '(:id "e" :type "diff" :dir "sub"))
          (should (equal (plist-get (agent-ui-get "e") :dir) "/proj/sub")))
      (kill-buffer (agent-ui-canvas)))))

(ert-deftest agent-ui-components/diff-hunks-to-accept ()
  "With accept: each hunk's mark (accepted, or rejected and dimmed), the
hint, Send counting them, Accept all / Reject all; answered: what was sent,
the marks kept; a still picture: the marks, no button."
  (let ((diff (list :type "diff" :diff agent-ui-test-aue-two-hunks :accept t
                    :rejected '((:file "src/lexer.c" :hunk 1)))))
    (should (equal (agent-ui-test-aue-draw diff)
                   (concat "▾ src/parser.c  +1 −1\n"
                           "  ✓ @@ -40,3 +40,3 @@ parse_expr\n"
                           "     40     int depth = 0;\n"
                           "        −   return NULL;\n"
                           "     41 +   return parse_term(p);\n"
                           "     42   }\n"
                           "▾ src/lexer.c  +1 −1\n"
                           "  ✗ @@ -10,2 +10,2 @@\n"
                           "        −   int n = 0;\n"
                           "     10 +   size_t n = 0;\n"
                           "     11     return n;\n"
                           "x on a hunk rejects it (again: back), c comments on a line\n"
                           ;; 61 columns on a line: broken to the width (60).
                           "⏵ Send (1 accepted, 1 rejected)   ⏵ Accept all\n"
                           "⏵ Reject all")))
    ;; Rejected: dimmed.
    (should (eq (agent-ui-test-aue-face-at diff "size_t") 'agent-ui-muted))
    (should (eq (agent-ui-test-aue-face-at diff "parse_term(p)") 'agent-ui-success))
    (should (string-suffix-p "     11     return n;" (agent-ui-test-aue-draw diff :still t)))
    (should (string-suffix-p "     11     return n;\n✓ Sent: 1 accepted, 1 rejected"
                             (agent-ui-test-aue-draw (append '(:answered "1 accepted, 1 rejected") diff))))
    (should (agent-ui-ask-waiting-p diff))
    (should-not (agent-ui-ask-waiting-p (append '(:answered "x") diff))))
  ;; Without accept: as ever.
  (should-not (string-search "✓" (agent-ui-test-aue-draw (list :type "diff" :diff agent-ui-test-aue-two-hunks)))))

(ert-deftest agent-ui-components/diff-a-file-twice ()
  "A file in two sections (git log -p, patches joined): its hunks counted on
across them, so rejecting one rejects it alone (doom-ht6.50)."
  (let* ((section (lambda (from) (format "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -%d,2 +%d,2 @@\n-a\n+b\n c\n" from from)))
         (text (concat (funcall section 1) (funcall section 20)))
         (diff (list :type "diff" :diff text :accept t :rejected '((:file "x" :hunk 2)))))
    (should (equal (mapcar (lambda (h) (list (car h) (cadr h)))
                           (agent-ui-diff--hunks (agent-ui-diff--parse text)))
                   '(("x" 1) ("x" 2))))
    (let ((drawn (agent-ui-test-aue-draw diff)))
      (should (string-match-p "✓ @@ -1,2 \\+1,2 @@" drawn))
      (should (string-match-p "✗ @@ -20,2 \\+20,2 @@" drawn)))
    (should (equal (agent-ui-diff--decided diff (agent-ui-diff--parse text))
                   '(("x @@ -1,2 +1,2 @@") . ("x @@ -20,2 +20,2 @@"))))))

(ert-deftest agent-ui-components/diff-hunks-accepted-and-sent ()
  "x on any line of a hunk rejects it (the cursor staying), again: back; RET
on its mark too; Reject all, Accept all; Send names them by file and header,
with the comments; then locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show (list :id "fix" :type "diff" :diff agent-ui-test-aue-two-hunks :accept t))
      (with-current-buffer canvas
        (agent-ui--flush)
        (goto-char (point-min))
        (search-forward "size_t")
        (agent-ui-drop-item)
        (should (looking-back "size_t" 6))
        (should (equal (plist-get (agent-ui-get "fix") :rejected) '((:file "src/lexer.c" :hunk 1))))
        (agent-ui-drop-item)
        (should-not (plist-get (agent-ui-get "fix") :rejected))
        ;; Its mark, pressed.
        (goto-char (point-min))
        (search-forward "@@ -40")
        (goto-char (- (match-beginning 0) 2))
        (agent-ui-button-press)
        (should (equal (plist-get (agent-ui-get "fix") :rejected) '((:file "src/parser.c" :hunk 1))))
        (agent-ui-test-aue-press "⏵ Reject all")
        (should (= (length (plist-get (agent-ui-get "fix") :rejected)) 2))
        (agent-ui-test-aue-press "⏵ Accept all")
        (should-not (plist-get (agent-ui-get "fix") :rejected))
        ;; One rejected, a comment, sent.
        (goto-char (point-min))
        (search-forward "size_t")
        (agent-ui-drop-item)
        (goto-char (point-min))
        (search-forward "parse_term(p)")
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "check p for NULL")))
          (agent-ui-comment (point) (point)))
        (agent-ui-test-aue-press "⏵ Send (1 accepted, 1 rejected, 1 comment)")
        (should (equal sent '(("Answer to diff fix (Apply these changes?): accepted: src/parser.c @@ -40,3 +40,3 @@ parse_expr. rejected: src/lexer.c @@ -10,2 +10,2 @@. Review of fix: src/parser.c:41: check p for NULL" t))))
        (agent-ui--flush)
        (should (string-search "✓ Sent: 1 accepted, 1 rejected, 1 comment" (buffer-string)))
        ;; Locked.
        (goto-char (point-min))
        (search-forward "size_t")
        (should-error (agent-ui-drop-item) :type 'user-error)))))

(ert-deftest agent-ui-components/diff-hunks-wrong ()
  (should (string-match-p "accept is true, or"
                          (agent-ui-test-aue-error '(:type "diff" :diff "" :accept (:ask "x")))))
  (should (string-match-p "rejected is"
                          (agent-ui-test-aue-error '(:type "diff" :diff "" :accept t :rejected ((:file "a")))))))

;;; agent-ui-diff-tests.el ends here
