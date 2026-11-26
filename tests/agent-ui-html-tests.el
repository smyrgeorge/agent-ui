;;; agent-ui-html-tests.el --- Tests for Agent UI: the html component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-html.el: the html component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defun agent-ui-test-aue-html (html)
  (let ((file (make-temp-file (agent-ui-test-tmp-file "page-") nil ".html")))
    (with-temp-file file (insert html))
    file))

(ert-deftest agent-ui-components/html ()
  (let* ((file (agent-ui-test-aue-html "<html><head><title>Coverage &amp; report</title>
<style>p { color: red }</style></head><body><h1>Coverage: 87%</h1>
<p>Lines covered: <b>4,120</b> of&nbsp;4,735.</p><script>alert('x')</script>
<!-- a comment --><ul><li>parser.c 92%</li><li>lexer.c 78%</li></ul></body></html>"))
         (opened nil)
         (agent-ui-open-page-function (lambda (p) (setq opened p)))
         (component (list :type "html" :file file :lines 3))
         (text (agent-ui-render component (agent-ui-context :width 300))))
    (should (equal (substring-no-properties text)
                   (concat "◫ Coverage & report\n" (abbreviate-file-name file) "\n"
                           "Coverage: 87%\nLines covered: 4,120 of 4,735.\nparser.c 92%")))
    ;; Its title opens it.
    (funcall (get-text-property 2 'agent-ui-action text))
    (should (equal opened file)))
  ;; A URL: its address.
  (should (equal (agent-ui-test-aue-draw '(:type "html" :url "https://example.com/report"))
                 "◫ https://example.com/report\nhttps://example.com/report"))
  (should (string-suffix-p "(not found)" (agent-ui-test-aue-draw '(:type "html" :file "/no/page.html"))))
  (should (string-match-p "give a file or a url" (agent-ui-test-aue-error '(:type "html"))))
  (should (string-match-p "give a file or a url" (agent-ui-test-aue-error '(:type "html" :file "a" :url "b")))))

;; doom-nwj.82
(ert-deftest agent-ui-components/html-entities-once ()
  "An HTML card reads its entities once (&amp;lt; is &lt;: it was <), the
numeric ones and the common named ones (&mdash; &#8212; were kept as
they were), and its title on one line (it kept its newlines)."
  (let ((file (agent-ui-test-aue-html "<html><head><title>Code coverage report for
     src/parser</title></head><body>
<p>Write &amp;lt;b&amp;gt; here; &amp;amp; is; &mdash; &#8212; &#x2014;</p>
<p>&ldquo;Done&rdquo;&hellip; &copy; 2026 &unknown; &#0; &lt;tag&gt;</p></body></html>")))
    (should (equal (agent-ui-test-aue-draw (list :type "html" :file file :lines 2) :width 300)
                   (concat "◫ Code coverage report for src/parser\n" (abbreviate-file-name file) "\n"
                           "Write &lt;b&gt; here; &amp; is; — — —\n"
                           "“Done”… © 2026 &unknown; &#0; <tag>")))
    (should (equal (agent-ui-html--entities "&AMP; &amp;amp; &#65;&#x42;") "&AMP; &amp; AB"))))

;;; agent-ui-html-tests.el ends here
