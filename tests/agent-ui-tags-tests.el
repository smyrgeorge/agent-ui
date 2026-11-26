;;; agent-ui-tags-tests.el --- Tests for Agent UI: the tags component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-tags.el: the tags component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defconst agent-ui-test-aue-labels
  '(:type "tags" :tags ((:label "bug" :face "error" :count 12) (:label "feature" :face "success" :count 4)
                        (:label "agent-ui" :count 31) (:label "P1" :face "warning" :count 2)
                        (:label "docs" :face "plain")))
  "A project's labels.")

(ert-deftest agent-ui-components/tags ()
  "Chips, each in its face with its count; wrapped to the width, a chip
never split (cut to fit when wider than it)."
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-labels) "[bug 12] [feature 4] [agent-ui 31] [P1 2] [docs]"))
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-labels :width 40)
                 "[bug 12] [feature 4] [agent-ui 31]\n[P1 2] [docs]"))
  (should (equal (agent-ui-test-aue-draw agent-ui-test-aue-labels :width 20)
                 "[bug 12] [feature 4]\n[agent-ui 31] [P1 2]\n[docs]"))
  (should (equal (agent-ui-test-aue-draw '(:type "tags" :tags ("a-very-long-label")) :width 10) "[a-very-…]"))
  (should (eq (agent-ui-test-aue-face-at agent-ui-test-aue-labels "bug") 'agent-ui-error))
  (should (eq (agent-ui-test-aue-face-at agent-ui-test-aue-labels "agent-ui") 'agent-ui-accent))
  (should (eq (agent-ui-test-aue-face-at agent-ui-test-aue-labels "docs") 'default))
  (should (equal (get-text-property 1 'face (agent-ui-render '(:type "tags" :tags ((:label "x" :color "#d19a66")))
                                                             (agent-ui-context :width 40)))
                 '(:foreground "#d19a66")))
  (should (equal (agent-ui-test-aue-draw '(:type "tags")) "no tags"))
  ;; The GUI: each chip a pill over its text.
  (let ((text (agent-ui-render agent-ui-test-aue-labels (agent-ui-context :width 80 :graphic t :char-width 8 :line-height 16))))
    (should (equal (substring-no-properties text) "[bug 12] [feature 4] [agent-ui 31] [P1 2] [docs]"))
    (should (string-match-p ">bug 12</text>" (plist-get (cdr (get-text-property 0 'display text)) :data)))))

(ert-deftest agent-ui-components/tags-a-colour-is-a-colour ()
  "A tag's color: #RGB to #RRGGBBAA or a colour's name, nothing that would
go into an SVG's attributes as more (doom-ht6.72)."
  (dolist (color '("#fff" "#12ab34" "#12ab34cc" "red"))
    (ert-info (color) (should (agent-ui-check "tags" (list :tags (list (list :label "a" :color color)))))))
  (dolist (color '("#fff\" onload=\"alert(1)" "#f00\"/><script>alert(1)</script>" "#zzz" "nope-colour"))
    (ert-info (color)
      (should-error (agent-ui-check "tags" (list :tags (list (list :label "a" :color color)))) :type 'agent-ui-error)))
  ;; A snapshot's colour escaped, whatever it is.
  (should (string-search "fill=\"a&quot;b\"" (agent-ui-snapshot--run "x" 0 0 "a\"b" nil 8 16))))

(ert-deftest agent-ui-components/tags-a-chips-prompt-and-appended ()
  "A chip with a prompt puts it into the session's prompt; appending a tag
whose label is there changes it in its place."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "labels" :type "tags"
                       :tags ((:label "bug" :count 12 :prompt "Show me the open bugs") "docs")))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "[bug 12]")
        (should (equal sent '(("Show me the open bugs" nil))))
        ;; A chip without one: nothing to press.
        (goto-char (point-min))
        (search-forward "[docs]")
        (goto-char (match-beginning 0))
        (should-error (agent-ui-button-press) :type 'user-error))
      (agent-ui-append "labels" '(:tags ((:label "bug" :count 11) "ci")))
      (with-current-buffer canvas
        (agent-ui--flush)
        (should (string-search "[bug 11] [docs] [ci]" (buffer-string))))
      (should (string-match-p "only tags" (agent-ui-error-message
                                           (should-error (agent-ui-append "labels" '(:title "x"))
                                                         :type 'agent-ui-error)))))))

(ert-deftest agent-ui-components/tags-to-pick ()
  "With select: the question, a picked chip filled (its text and the GUI's
pill), the others outlined; the note, Answer, All / None; answered: the
answer, locked; a still picture: the chips only."
  (let ((tags '(:type "tags" :tags ("bug" "docs" "ci") :selected ("docs")
                :select (:question "Which labels?" :multiple t :note t))))
    (should (equal (agent-ui-test-aue-draw tags)
                   (concat "Which labels?\n"
                           "[bug]  docs  [ci]\n"
                           " ✎ Add a note\n"
                           " ⏵ Answer (1 chosen)   ⏵ All   ⏵ None")))
    (should (equal (agent-ui-test-aue-face-at tags "docs") '(:inherit agent-ui-accent :inverse-video t)))
    (should (equal (agent-ui-test-aue-draw tags :still t) "Which labels?\n[bug]  docs  [ci]"))
    (should (equal (agent-ui-test-aue-draw (append '(:answered "docs") tags))
                   "Which labels?\n[bug]  docs  [ci]\n✓ Answered: docs"))
    (should (agent-ui-ask-waiting-p tags))
    ;; The GUI: the picked one's pill filled, the others outlined on a tint.
    (let* ((text (agent-ui-render tags (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
           (svg (lambda (word) (plist-get (cdr (get-text-property (string-search word (substring-no-properties text))
                                                                   'display text))
                                          :data)))
           (color (regexp-quote (agent-ui-color 'agent-ui-accent))))
      (should (string-match-p (format "<rect [^>]*fill=\"%s\"" color) (funcall svg "docs")))
      (should-not (string-match-p (format "<rect [^>]*fill=\"%s\"" color) (funcall svg "bug"))))))

(ert-deftest agent-ui-components/tags-picked-and-sent ()
  "RET on a chip (un)picks it; one only without multiple; Answer sends the
labels picked; then locked."
  (agent-ui-test-aue-canvas
    (let* ((sent nil)
           (agent-ui-action-function (lambda (prompt submit) (push (list prompt submit) sent))))
      (agent-ui-show '(:id "labels" :type "tags" :tags ("bug" "docs" "ci")
                       :select (:question "Which labels?" :multiple t)))
      (with-current-buffer canvas
        (agent-ui-test-aue-press "[bug]")
        (agent-ui-test-aue-press "[ci]")
        (agent-ui-test-aue-press " bug ")
        (should (equal (plist-get (agent-ui-get "labels") :selected) '("ci")))
        (agent-ui-test-aue-press "[docs]")
        (agent-ui-test-aue-press "⏵ Answer (2 chosen)")
        (should (equal sent '(("Answer to labels (Which labels?): docs, ci" t))))
        (agent-ui--flush)
        (should (string-search "✓ Answered: docs, ci" (buffer-string)))
        (goto-char (point-min))
        (search-forward "[bug]")
        (goto-char (match-beginning 0))
        (should-error (agent-ui-button-press) :type 'user-error)))
    ;; One only.
    (agent-ui-show '(:id "os" :type "tags" :tags ("linux" "macos") :select (:question "Build for?")))
    (with-current-buffer canvas
      (agent-ui-test-aue-press "[linux]")
      (agent-ui-test-aue-press "[macos]")
      (should (equal (plist-get (agent-ui-get "os") :selected) '("macos"))))))

(ert-deftest agent-ui-components/tags-wrong ()
  (should (string-match-p "tag 2 must be a label" (agent-ui-test-aue-error '(:type "tags" :tags ("a" 3)))))
  (should (string-match-p "tag 1 has no label" (agent-ui-test-aue-error '(:type "tags" :tags ((:count 3))))))
  (should (string-match-p "tag 1's face is plain" (agent-ui-test-aue-error '(:type "tags" :tags ((:label "a" :face "loud"))))))
  (should (string-match-p "tag 1's color isn't a colour" (agent-ui-test-aue-error '(:type "tags" :tags ((:label "a" :color "notacolour"))))))
  (should (string-match-p "same label" (agent-ui-test-aue-error '(:type "tags" :tags ("a" "a")))))
  (should (string-match-p "tag 1 has \"size\"" (agent-ui-test-aue-error '(:type "tags" :tags ((:label "a" :size 3))))))
  (should (string-match-p "select's question is required"
                          (agent-ui-test-aue-error '(:type "tags" :tags ("a") :select (:multiple t)))))
  (should (string-match-p "\"b\""
                          (agent-ui-test-aue-error '(:type "tags" :tags ("a") :select (:question "q") :selected ("b"))))))

;;; agent-ui-tags-tests.el ends here
