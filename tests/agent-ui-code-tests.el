;;; agent-ui-code-tests.el --- Tests for Agent UI: the code component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-code.el: the code component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/code ()
  (let ((component '(:type "code" :language "emacs-lisp" :from 10
                   :code "(defun f (x)\n  (error \"no\"))"
                   :marks ((:line 11 :kind "error" :note "always fails")))))
    (should (equal (agent-ui-test-aue-draw component)
                   "10 │ (defun f (x)\n11 ✗   (error \"no\"))  ← always fails"))
    ;; Highlighted by its mode; its mark, its note.
    (should (eq (agent-ui-test-aue-face-at component "defun") 'font-lock-keyword-face))
    (should (eq (agent-ui-test-aue-face-at component "✗") 'agent-ui-error))
    (should (eq (agent-ui-test-aue-face-at component "← always") 'agent-ui-error))))

(ert-deftest agent-ui-components/code-only-a-major-mode ()
  "Its language a major mode for code or text: never a minor mode (turned
on), nor one doing something of its own (a special mode) (doom-ht6.49)."
  (let ((global-auto-revert-mode nil))
    (agent-ui-test-aue-draw '(:type "code" :code "x" :language "global-auto-revert"))
    (should-not global-auto-revert-mode))
  (should-not (agent-ui-code--mode "auto-save-visited" nil))
  (should-not (agent-ui-code--mode "doc-view" nil))
  (should-not (agent-ui-code--mode "special" nil))
  (should (eq (agent-ui-code--mode "emacs-lisp" nil) 'emacs-lisp-mode))
  (should (eq (agent-ui-code--mode "python" nil) 'python-mode))
  (should (eq (agent-ui-code--mode "diff" nil) 'diff-mode))
  (should (eq (agent-ui-code--mode nil "a.py") (agent-ui-code--major-mode (assoc-default "a.py" auto-mode-alist #'string-match)))))

;; doom-nwj.69
(ert-deftest agent-ui-components/code-long-line-keeps-its-note ()
  "A mark's note is shown whole at widths 40 to 80: after its line if both
fit, else under it, wrapped (the line was cut with its note: \"{  ← …\")."
  (let ((component '(:type "code" :language "c" :from 40
                   :code "static Node *parse_expr(Parser *p, int precedence, ParseFlags flags) {\n  return NULL;"
                   :marks ((:line 40 :kind "error" :note "precedence unused")
                           (:line 41 :kind "warning" :note "never NULL")))))
    (dolist (width (number-sequence 40 80))
      (let ((text (agent-ui-test-aue-draw component :width width)))
        (dolist (line (split-string text "\n")) (should (<= (string-width line) width)))
        (should (string-search "← precedence unused" text))
        (should (string-search "  return NULL;  ← never NULL" text))))
    ;; Its line wrapped (it was cut: "int prece…"), its note under it.
    (should (equal (agent-ui-test-aue-draw component :width 50)
                   (concat "40 ✗ static Node *parse_expr(Parser *p, int\n"
                           "   │ precedence, ParseFlags flags) {\n"
                           "     ← precedence unused\n"
                           "41 !   return NULL;  ← never NULL")))
    (should (eq (agent-ui-test-aue-face-at component "← precedence" :width 50) 'agent-ui-error))
    ;; Under it: its line's button too.
    (let ((text (agent-ui-render (append component '(:file "/tmp/x.c")) (agent-ui-context :width 50))))
      (should (functionp (get-text-property (string-search "← precedence" text) 'agent-ui-action text))))
    ;; A long note at a narrow width: wrapped under it.
    (should (equal (agent-ui-test-aue-draw '(:type "code" :from 1 :code "x = 1"
                                     :marks ((:line 1 :kind "info" :note "this is set once and read everywhere")))
                                   :width 30)
                   "1 • x = 1\n    ← this is set once and\n    read everywhere"))))

(ert-deftest agent-ui-components/code-from-its-file ()
  (let* ((file (make-temp-file (agent-ui-test-tmp-file "code-") nil ".py"
                               (mapconcat (lambda (n) (format "x%d = %d" n n)) (number-sequence 1 30) "\n")))
         (opened nil)
         (agent-ui-open-file-function (lambda (f) (push f opened) (find-file f)))
         (component (list :type "code" :file file :from 5 :to 7))
         ;; Wide: its temp file's long name whole.
         (text (agent-ui-render component (agent-ui-context :width 300))))
    ;; Its lines FROM to TO, its file named above; python-mode's colours (by its name).
    (should (equal (substring-no-properties text)
                   (concat (abbreviate-file-name file) "\n5 │ x5 = 5\n6 │ x6 = 6\n7 │ x7 = 7")))
    ;; Its line found by its text: "x6" alone can be in the temp file's
    ;; random name, above it (no button there: (funcall nil), now and then).
    (should (get-text-property (string-search "x6 = 6" text) 'face text))
    ;; RET on a line: its file, there.
    (funcall (get-text-property (string-search "x6 = 6" text) 'agent-ui-action text))
    (should (equal (car opened) file))
    (should (= (line-number-at-pos) 6))
    (kill-buffer (current-buffer))
    (should (string-suffix-p "not found" (agent-ui-test-aue-draw '(:type "code" :file "/no/such.py"))))))

;; doom-nwj.70
(ert-deftest agent-ui-components/code-file-name-fits ()
  "Its file's name above it, and a missing file's line, are cut to the width
at their start, the file's name kept (never cut: 66 and 72 columns)."
  (let* ((dir (make-temp-file (agent-ui-test-tmp-file "code-") t))
         (deep (expand-file-name "some/deeper/directory/structure/" dir))
         (file (expand-file-name "file_name.txt" deep)))
    (unwind-protect
        (progn
          (make-directory deep t)
          (with-temp-file file (insert "one\ntwo\n"))
          (dolist (width '(15 20 30))
            (let ((lines (split-string (agent-ui-test-aue-draw (list :type "code" :file file :from 1 :to 2) :width width) "\n")))
              (dolist (line lines) (should (<= (string-width line) width)))
              (should (string-suffix-p "file_name.txt" (car lines)))
              (should (equal (cdr lines) '("1 │ one" "2 │ two"))))
            (let ((missing (agent-ui-test-aue-draw (list :type "code" :file (concat file ".gone")) :width width)))
              (should (<= (string-width missing) width))
              (should (string-suffix-p ": not found" missing))))
          (should (equal (agent-ui-test-aue-draw (list :type "code" :file (concat file ".gone")) :width 30)
                         "…file_name.txt.gone: not found")))
      (delete-directory dir t))))

;; doom-nwj.77
(ert-deftest agent-ui-components/code-trailing-newlines-and-crlf ()
  "Code ending in newlines, or with CRLF's, draws its lines only (a numbered
empty line came after it, widening the gutter from 99; ^M at their ends)."
  (should (equal (agent-ui-test-aue-draw '(:type "code" :from 9 :code "int x;\nint y;\n"))
                 " 9 │ int x;\n10 │ int y;"))
  (should (equal (agent-ui-test-aue-draw '(:type "code" :from 98 :code "int x;\nint y;\n\n"))
                 "98 │ int x;\n99 │ int y;"))
  (should (equal (agent-ui-test-aue-draw '(:type "code" :from 1 :code "a\r\nb\r\n"))
                 "1 │ a\n2 │ b"))
  ;; Empty lines inside it: kept.
  (should (equal (agent-ui-test-aue-draw '(:type "code" :from 1 :code "a\n\nb\n"))
                 "1 │ a\n2 │ \n3 │ b")))

;; doom-nwj.88
(ert-deftest agent-ui-components/code-from-past-its-end ()
  "FROM past its file's end is said (it was an empty line numbered FROM)."
  (let ((file (make-temp-file (agent-ui-test-tmp-file "code-") nil ".txt" "a\nb\nc\n")))
    (should (equal (agent-ui-test-aue-draw (list :type "code" :file file :from 40) :width 300)
                   (concat (abbreviate-file-name file) ": lines 40–59 are past its end (3 lines)")))
    (should (string-suffix-p ": lines 4–5 are past its end (3 lines)"
                             (agent-ui-test-aue-draw (list :type "code" :file file :from 4 :to 5) :width 300)))
    ;; Its last line, and past it: what's there.
    (should (string-suffix-p "\n3 │ c" (agent-ui-test-aue-draw (list :type "code" :file file :from 3 :to 9) :width 300)))
    (with-temp-file file (insert "only"))
    (should (string-suffix-p "past its end (1 line)" (agent-ui-test-aue-draw (list :type "code" :file file :from 2) :width 300)))
    (should (string-suffix-p "\n1 │ only" (agent-ui-test-aue-draw (list :type "code" :file file) :width 300)))))

;; doom-nwj.89
(ert-deftest agent-ui-components/code-two-marks-on-a-line ()
  "Marks on one line: the worst kind's sign, every note, the worst's first,
each in its kind's colour (the first mark only was shown)."
  (let ((component '(:type "code" :from 1 :code "x = f(y)"
                   :marks ((:line 1 :kind "info" :note "called often")
                           (:line 1 :kind "error" :note "y undefined")
                           (:line 1 :kind "warning")))))
    (should (equal (agent-ui-test-aue-draw component) "1 ✗ x = f(y)  ← y undefined; called often"))
    (should (eq (agent-ui-test-aue-face-at component "✗") 'agent-ui-error))
    (should (eq (agent-ui-test-aue-face-at component "called") 'agent-ui-accent))
    (should (eq (agent-ui-test-aue-face-at component "y undefined") 'agent-ui-error))
    ;; Under it when they don't fit: both, wrapped.
    (should (equal (agent-ui-test-aue-draw component :width 24)
                   "1 ✗ x = f(y)\n    ← y undefined;\n    called often"))))

(ert-deftest agent-ui-components/code-wrong ()
  (should (string-match-p "give code, or a file" (agent-ui-test-aue-error '(:type "code"))))
  (should (string-match-p "from is a line" (agent-ui-test-aue-error '(:type "code" :code "x" :from 0))))
  (should (string-match-p "to is before from" (agent-ui-test-aue-error '(:type "code" :file "a" :from 5 :to 2))))
  (should (string-match-p "mark 1's kind" (agent-ui-test-aue-error '(:type "code" :code "x" :marks ((:line 1 :kind "bad"))))))
  (should (string-match-p "mark 1 must be" (agent-ui-test-aue-error '(:type "code" :code "x" :marks ((:kind "error")))))))

;;; agent-ui-code-tests.el ends here
