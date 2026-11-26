;;; agent-ui-math-tests.el --- Tests for Agent UI: the math component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-math.el: the math component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(ert-deftest agent-ui-components/math-source-broken-between-commands ()
  "A formula's source shown as text is broken at spaces and before its
commands, never within one, each line indented (\\delt / a\\epsilon, its
next lines at column 0)."
  (let ((text (agent-ui-test-aue-draw '(:type "math" :tex "\\mathcal{L}=\\frac{\\partial\\delta}{\\partial\\epsilon}\\left(\\overbrace{a+b}^{n}\\right)")
                              :width 24)))
    (should (equal text (concat "  \\mathcal{L}=\\frac{\n"
                                "  \\partial\\delta}{\n"
                                "  \\partial\\epsilon}\n"
                                "  \\left(\n"
                                "  \\overbrace{a+b}^{n}\n"
                                "  \\right)"))))
  ;; A piece wider than the width: cut within it, still indented.
  (should (equal (agent-ui-test-aue-draw '(:type "math" :tex "\\verylongcommandname") :width 10)
                 "  \\verylon\n  gcommand\n  name")))

(ert-deftest agent-ui-components/math-as-unicode ()
  "In a terminal: Unicode where it's simple, else the source; a block
indented."
  (should (equal (agent-ui-math-unicode "E = mc^2") "E = mc²"))
  (should (equal (agent-ui-math-unicode "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}") "∑ᵢ₌₁ⁿ i = (n(n+1))/2"))
  (should (equal (agent-ui-math-unicode "\\alpha \\le \\beta_i^2") "α ≤ βᵢ²"))
  (should (equal (agent-ui-math-unicode "\\sqrt{x^2 + y^2}") "√(x² + y²)"))
  (should (equal (agent-ui-math-unicode "x \\in \\mathbb{R}") "x ∈ ℝ"))
  (should (equal (agent-ui-math-unicode "P(A \\mid B)") "P(A | B)"))
  ;; Not simple: nil (the source shown).
  (should-not (agent-ui-math-unicode "e^{i\\pi} + 1 = 0"))
  (should-not (agent-ui-math-unicode "\\begin{pmatrix} a \\end{pmatrix}"))
  (should (equal (agent-ui-test-aue-draw '(:type "math" :tex "E = mc^2")) "  E = mc²"))
  (should (equal (agent-ui-test-aue-draw '(:type "math" :tex "E = mc^2" :display "inline")) "E = mc²"))
  (should (equal (agent-ui-test-aue-draw '(:type "math" :tex "e^{i\\pi} + 1 = 0")) "  e^{i\\pi} + 1 = 0")))

(ert-deftest agent-ui-components/math-its-mathjax-script ()
  "The MathJax script node runs: beside it, in components/math/."
  (should (equal agent-ui-math--script
                 (expand-file-name "assets/tex2svg.js" agent-ui-test-root)))
  (should (file-readable-p agent-ui-math--script))
  (should (equal (car (agent-ui-math--command 'mathjax 'block "/tmp")) "node"))
  (should (equal (cdr (agent-ui-math--command 'mathjax 'inline "/tmp")) (list agent-ui-math--script "inline"))))

(defmacro agent-ui-test-aue-math (command &rest body)
  "BODY with a stand-in typesetting tool running COMMAND (its SVG on stdout),
a cache of its own, nothing typeset yet."
  (declare (indent 1))
  `(let ((agent-ui-math-cache-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "math-") t)))
         (agent-ui-math--results (make-hash-table :test #'equal))
         (agent-ui-math--running nil))
     (cl-letf (((symbol-function 'agent-ui-math--tool) (lambda () 'mathjax))
               ((symbol-function 'agent-ui-math--command) (lambda (&rest _) ,command)))
       ,@body)))

(defun agent-ui-test-aue-math-wait ()
  (let ((end (+ (float-time) 5)))
    (while (and agent-ui-math--running (< (float-time) end)) (accept-process-output nil 0.02))))

(ert-deftest agent-ui-components/math-typeset-in-the-background ()
  "In the GUI with a tool: its text and \"typesetting…\" at once (Emacs not
waiting), then the image, sized to the font, in the text's colour; cached:
another session reads it without the tool."
  (let ((gui (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 20))
        (component '(:type "math" :tex "E = mc^2")))
    (agent-ui-test-aue-math (list "sh" "-c" "cat >/dev/null; printf '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10ex\" height=\"2ex\"><path fill=\"currentColor\" d=\"M0 0h1v1z\"/></svg>'")
      (should (equal (substring-no-properties (agent-ui-render component gui)) "  E = mc²\ntypesetting…"))
      (should agent-ui-math--running)
      (agent-ui-test-aue-math-wait)
      (let* ((text (agent-ui-render component gui))
             (image (get-text-property 2 'display text)))
        (should (eq (car image) 'image))
        ;; 10ex at a 20-pixel line: 72 pixels; in the theme's colour.
        (should (string-match-p "width=\"72.00\"" (plist-get (cdr image) :data)))
        (should (string-match-p (regexp-quote (agent-ui-math--color)) (plist-get (cdr image) :data)))
        (should-not (string-search "currentColor" (plist-get (cdr image) :data))))
      ;; MathJax: node given its global modules (NODE_PATH).
      (cl-letf (((symbol-function 'agent-ui-math--node-modules) (lambda () "/opt/node/lib/node_modules/"))
                ((symbol-function 'agent-ui-math--command)
                 (lambda (&rest _) (list "sh" "-c" "cat >/dev/null; printf '<svg width=\"1ex\" height=\"1ex\"><desc>%s</desc></svg>' \"$NODE_PATH\""))))
        (agent-ui-render '(:type "math" :tex "y") gui)
        (agent-ui-test-aue-math-wait)
        (should (string-search "<desc>/opt/node/lib/node_modules</desc>"
                               (plist-get (cdr (get-text-property 2 'display (agent-ui-render '(:type "math" :tex "y") gui)))
                                          :data))))
      ;; Another session: from the cache, no tool run.
      (clrhash agent-ui-math--results)
      (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "Typeset again"))))
        (should (eq (car (get-text-property 2 'display (agent-ui-render component gui))) 'image))))))

(ert-deftest agent-ui-components/math-not-typeset ()
  "The tool failing: its text and why; no tool in the GUI: what to install;
in a terminal: neither."
  (let ((gui (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 20)))
    (agent-ui-test-aue-math (list "sh" "-c" "cat >/dev/null; printf '%s\\n' 'TeX error: Undefined control sequence \\foo' >&2; exit 1")
      (agent-ui-render '(:type "math" :tex "\\foo") gui)
      (agent-ui-test-aue-math-wait)
      (should (equal (substring-no-properties (agent-ui-render '(:type "math" :tex "\\foo") gui))
                     "  \\foo\nNot typeset: TeX error: Undefined control sequence \\foo")))
    (cl-letf (((symbol-function 'agent-ui-math--tool) #'ignore))
      (should (string-match-p "npm install -g\\s-+mathjax-full"
                              (substring-no-properties (agent-ui-render '(:type "math" :tex "e^{i\\pi}") gui))))
      ;; Its Unicode enough: no hint.
      (should (equal (substring-no-properties (agent-ui-render '(:type "math" :tex "x^2") gui)) "  x²"))
      (should (equal (agent-ui-test-aue-draw '(:type "math" :tex "x")) "  x")))))

(ert-deftest agent-ui-components/math-error-read-whole ()
  "The tool's error is read whole before its result is kept, however late
it comes after the tool exits (its sentinel could run first: the error
read \"it failed\", under load)."
  (let ((gui (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 20)))
    (agent-ui-test-aue-math (list "sh" "-c" "cat >/dev/null; (sleep 0.3; printf 'TeX error: late\\n' >&2) & exit 1")
      (agent-ui-render '(:type "math" :tex "\\qux") gui)
      (agent-ui-test-aue-math-wait)
      (should-not agent-ui-math--running)
      (should (equal (substring-no-properties (agent-ui-render '(:type "math" :tex "\\qux") gui))
                     "  \\qux\nNot typeset: TeX error: late"))
      ;; Nothing left running.
      (should-not (seq-some (lambda (p) (string-prefix-p "agent-ui-math" (process-name p))) (process-list))))))

(ert-deftest agent-ui-components/math-redrawn-when-typeset ()
  "Typeset: the components showing it marked to be drawn again (a panel's
child too; one whose TeX has blanks around it, doom-ht6.54)."
  (agent-ui-test-aue-canvas
    (agent-ui-test-aue-math (list "true")
      (agent-ui-show '(:id "f" :type "math" :tex "E = mc^2\n"))
      (agent-ui-show '(:id "p" :type "panel" :children ((:id "g" :type "math" :tex "E = mc^2"))))
      (agent-ui-show '(:id "other" :type "math" :tex "x"))
      (with-current-buffer canvas (agent-ui--flush))
      (agent-ui-math--redraw (agent-ui-math--key 'mathjax "E = mc^2" 'block (agent-ui-math--color)))
      (with-current-buffer canvas
        (should (equal (sort (copy-sequence agent-ui--dirty) #'string<) '("f" "p")))))))

;;; agent-ui-math-tests.el ends here
