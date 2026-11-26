;;; agent-ui-markdown-tests.el --- Tests for Agent UI: the markdown component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-markdown.el: the markdown component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/markdown ()
  (let ((component '(:type "markdown" :markdown "# Plan\n\nSome **bold** and `code`.\n\n- one\n- two\n")))
    (should (equal (agent-ui-test-aue-draw component) "Plan\n\nSome bold and code.\n\n• one\n• two"))
    ;; As agent-shell draws it: its faces.
    (should (eq (agent-ui-test-aue-face-at component "bold") 'agent-shell-markdown-bold))
    ;; Wrapped to the width, its faces kept.
    (should (equal (agent-ui-test-aue-draw component :width 10) "Plan\n\nSome bold\nand code.\n\n• one\n• two"))
    (should (eq (agent-ui-test-aue-face-at component "code" :width 10) 'agent-shell-markdown-inline-code)))
  ;; A table: at the canvas's width, not the selected window's.
  (let ((text (agent-ui-test-aue-draw (list :type "markdown"
                                    :markdown (concat "| A | B |\n|---|---|\n| "
                                                      (string-join (make-list 30 "word") " ")
                                                      " | x |\n"))
                              :width 40)))
    (should (string-match-p "│" text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 40)))))

(ert-deftest agent-ui-components/markdown-wrapped-under-its-indent ()
  "Wrapped, a list item's, a task's and a code line's next lines stay under
their text's start (they began at column 0: at 24 a task's box alone, a
code line's indent lost)."
  (let ((text (agent-ui-test-aue-draw '(:type "markdown"
                                :markdown "- [ ] Write the migration for the users table\n- a list item long enough to wrap\n\n```\n    return parse_term(p, depth + 1);\n```")
                              :width 24)))
    (should (string-search "□ Write the migration\n  for the users table\n" text))
    (should (string-search "• a list item long\n  enough to wrap\n" text))
    (should (string-search "    return parse_term(p,\n    depth + 1);" text))
    (dolist (line (split-string text "\n"))
      (should (<= (string-width line) 24))))
  (should (equal (agent-ui-wrap-hanging "  1. one two three four" 12) "  1. one two\n     three\n     four"))
  ;; A start wider than half the width: not hung under.
  (should (equal (agent-ui-wrap-hanging "            abc def" 16) "            abc\ndef")))

(ert-deftest agent-ui-components/markdown-without-agent-shell ()
  ;; As written, wrapped.
  (cl-letf (((symbol-function 'agent-ui-markdown--render) #'ignore))
    (should (equal (agent-ui-test-aue-draw '(:type "markdown" :markdown "Some **bold** words") :width 12)
                   "Some\n**bold**\nwords"))))

;;; agent-ui-markdown-tests.el ends here
