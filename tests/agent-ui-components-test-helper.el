;;; agent-ui-components-test-helper.el --- What the component tests share  -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers the component tests (tests/agent-ui-*-tests.el) share: a
;; component drawn, its face at a string, its check's error, a canvas.

;;; Code:

(require 'agent-ui-test-helper)

(defun agent-ui-test-aue-draw (component &rest ctx)
  "COMPONENT drawn, its text only, in CTX (`agent-ui-context''s keys; width 60)."
  (substring-no-properties
   (agent-ui-render component (apply #'agent-ui-context (append ctx '(:width 60))))))

(defun agent-ui-test-aue-face-at (component string &rest ctx)
  "The face of STRING's first character in COMPONENT's drawing."
  (let* ((text (agent-ui-render component (apply #'agent-ui-context (append ctx '(:width 60)))))
         (at (string-search string (substring-no-properties text))))
    (should at)
    (get-text-property at 'face text)))

(defun agent-ui-test-aue-error (component)
  (agent-ui-error-message
   (should-error (agent-ui-check (plist-get component :type) component) :type 'agent-ui-error)))

(defmacro agent-ui-test-aue-canvas (&rest body)
  "BODY with a canvas of its own (`canvas'), no window shown; killed after."
  (declare (indent 0))
  `(let* ((agent-ui-default-canvas (make-temp-name "choice-"))
          (agent-ui-display-function #'ignore)
          (canvas (progn (agent-ui-show '(:id "first" :type "text" :text "x")) (agent-ui-canvas))))
     (unwind-protect (progn ,@body) (kill-buffer canvas))))

(defun agent-ui-test-aue-press (text)
  "Press the button on TEXT in the current canvas."
  (agent-ui--flush)
  (goto-char (point-min))
  (search-forward text)
  (goto-char (match-beginning 0))
  (agent-ui-button-press))

(defconst agent-ui-test-aue-two-hunks
  (concat "diff --git a/src/parser.c b/src/parser.c\n--- a/src/parser.c\n+++ b/src/parser.c\n"
          "@@ -40,3 +40,3 @@ parse_expr\n   int depth = 0;\n-  return NULL;\n+  return parse_term(p);\n }\n"
          "diff --git a/src/lexer.c b/src/lexer.c\n--- a/src/lexer.c\n+++ b/src/lexer.c\n"
          "@@ -10,2 +10,2 @@\n-  int n = 0;\n+  size_t n = 0;\n   return n;\n")
  "A diff of two files, a hunk each.")

;; doom-cer
(defun agent-ui-test-aue--region (id)
  "Component ID's drawing in the current canvas, as it is there."
  (let ((entry (gethash id agent-ui--entries)))
    (buffer-substring (agent-ui--entry-start entry) (agent-ui--entry-end entry))))

(defun agent-ui-test-aue--drawn-whole (id)
  "Component ID drawn whole now, as the canvas draws it (its id on it)."
  (propertize (agent-ui-render (agent-ui-get id) (plist-put (agent-ui--context) :id id)) 'agent-ui-id id))

(defun agent-ui-test-aue--same-drawing-p (a b)
  "Whether A and B have the same text and, at each position, the same
properties (however they're split)."
  (and (string= a b)
       (cl-loop for i below (length a)
                always (equal (sort (seq-partition (text-properties-at i a) 2) (lambda (x y) (string< (car x) (car y))))
                              (sort (seq-partition (text-properties-at i b) 2) (lambda (x y) (string< (car x) (car y))))))))

(defmacro agent-ui-test-aue--counting-whole-draws (&rest body)
  "BODY, the components drawn whole counted in `whole' (by id)."
  `(let ((whole nil))
     (cl-letf* ((draw (symbol-function 'agent-ui--draw))
                ((symbol-function 'agent-ui--draw)
                 (lambda (entry ctx) (push (agent-ui--entry-id entry) whole) (funcall draw entry ctx))))
       ,@body)))

(defun agent-ui-test-aue-svg-dom (component width)
  "COMPONENT drawn for the GUI at WIDTH columns: its SVG, parsed."
  (with-temp-buffer
    (insert (agent-ui-test-aue-svg component width))
    (libxml-parse-xml-region (point-min) (point-max))))

(defun agent-ui-test-aue-rects (dom)
  "DOM's rectangles as plists: :x :width :rx :clip, numbers read."
  (mapcar (lambda (rect)
            (let ((get (lambda (attr) (dom-attr rect attr))))
              (list :x (string-to-number (funcall get 'x))
                    :width (string-to-number (funcall get 'width))
                    :rx (and (funcall get 'rx) (string-to-number (funcall get 'rx)))
                    :clip (funcall get 'clip-path)
                    :fill (funcall get 'fill))))
          (dom-by-tag dom 'rect)))

(defun agent-ui-test-aue-svg (component width)
  "COMPONENT drawn for the GUI at WIDTH columns (8 px, lines 16 px): its SVG."
  (let ((text (agent-ui-render component (agent-ui-context :width width :graphic t :char-width 8 :line-height 16))))
    (plist-get (cdr (get-text-property (text-property-not-all 0 (length text) 'display nil text) 'display text))
               :data)))

(provide 'agent-ui-components-test-helper)

;;; agent-ui-components-test-helper.el ends here
