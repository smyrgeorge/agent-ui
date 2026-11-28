;;; agent-ui-mermaid-tests.el --- Tests for Agent UI: mermaid  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-mermaid.el: the mermaid type (its diagram an
;; image in the GUI once the stand-in mmdc drew it, sized to the canvas, in
;; a snapshot as it's shown; its source meanwhile, in a terminal, or with
;; Mermaid's message; an update draws anew; a theme switch draws again); the
;; markdown type's ```mermaid blocks drawn the same; its example right.

;;; Code:

(require 'agent-ui-test-helper)

;; mermaid-mode colours a diagram's source, if it's installed.
(require 'mermaid-mode nil t)

;; ====== A STAND-IN MMDC ======
;; A script taking mmdc's arguments: the diagram in -i's file, its SVG (the
;; source in it) written to -o; a source saying ERROR fails as Mermaid does.
;; Each run's arguments logged.

(defconst agent-ui-test-mermaid--mmdc-script
  "#!/bin/sh
dir=$(dirname \"$0\")
echo \"$*\" >> \"$dir/runs.log\"
in= out=
while [ $# -gt 0 ]; do
  case \"$1\" in -i) in=$2; shift ;; -o) out=$2; shift ;; esac
  shift
done
source=$(cat \"$in\")
case \"$source\" in
  *ERROR*)
    echo 'Error: Parse error on line 2:' >&2
    echo '...A --> ERROR' >&2
    exit 1 ;;
esac
printf '<svg id=\"my-svg\" viewBox=\"0 0 400 100\" style=\"max-width: 400px;\"><text><tspan>Write</tspan><tspan> the</tspan></text><desc>%s</desc></svg>' \"$source\" > \"$out\"
"
  "The stand-in mmdc (see above).")

(defun agent-ui-test-mermaid--make-mmdc ()
  "A stand-in mmdc in a folder of its own: its path."
  (let ((file (expand-file-name "mmdc" (make-temp-file (agent-ui-test-tmp-file "mermaid/bin-") t))))
    (with-temp-file file (insert agent-ui-test-mermaid--mmdc-script))
    (set-file-modes file #o755)
    file))

(defmacro agent-ui-test-mermaid--with-mmdc (&rest body)
  "BODY with the stand-in mmdc (`mmdc' its path), an empty cache."
  (declare (indent 0))
  `(let* ((mmdc (agent-ui-test-mermaid--make-mmdc))
          (agent-ui-mmdc mmdc)
          (agent-ui-mermaid-render-function #'agent-ui-mermaid-render)
          (agent-ui-mermaid-cache-directory
           (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "mermaid/cache-") t)))
          (agent-ui-mermaid--waiting (make-hash-table :test #'equal)))
     ,@body))

(defconst agent-ui-test-mermaid--dark 'dark "A dark frame.")
(defconst agent-ui-test-mermaid--light 'light "A light frame.")

(defmacro agent-ui-test-mermaid--theme (mode &rest body)
  "BODY with the selected frame's background MODE (dark or light)."
  (declare (indent 1))
  `(cl-letf* ((parameter (symbol-function 'frame-parameter))
              ((symbol-function 'frame-parameter)
               (lambda (frame name)
                 (if (eq name 'background-mode) ,mode (funcall parameter frame name)))))
     ,@body))

(defun agent-ui-test-mermaid--runs (mmdc)
  "The stand-in MMDC's runs: each its arguments (a list), oldest first."
  (let ((log (expand-file-name "runs.log" (file-name-directory mmdc))))
    (when (file-exists-p log)
      (mapcar #'split-string
              (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t)))))

(defun agent-ui-test-mermaid--wait (predicate &optional seconds)
  "Wait (processes and timers running) until PREDICATE, SECONDS at most (10)."
  (let ((end (+ (float-time) (or seconds 10))))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defmacro agent-ui-test-aum (&rest body)
  "BODY in a GUI (faked: images made, not drawn), the stand-in mmdc, a
stand-in theme, no diagram failed yet; `redrawn' the diagrams whose components
were to be redrawn."
  (declare (indent 0))
  `(agent-ui-test-mermaid--with-mmdc
     (let ((agent-ui-mermaid--errors (make-hash-table :test #'equal))
           (redrawn nil))
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                 ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                 ((symbol-function 'agent-ui-mermaid--redraw)
                  (lambda (&optional diagram) (push diagram redrawn))))
         (agent-ui-test-mermaid--theme agent-ui-test-mermaid--dark
           ,@body)))))

(defun agent-ui-test-aum--gui (&optional width)
  (agent-ui-context :width (or width 60) :graphic t :char-width 8 :line-height 16))

(defun agent-ui-test-aum--draw (component &optional ctx)
  (agent-ui-render component (or ctx (agent-ui-test-aum--gui))))

(defun agent-ui-test-aum--image (text)
  "The image TEXT shows, or nil."
  (let ((pos (text-property-not-all 0 (length text) 'display nil text)))
    (and pos (get-text-property pos 'display text))))

(defconst agent-ui-test-aum--flow '(:type "mermaid" :id "flow" :diagram "flowchart LR\n    build --> test"))


(ert-deftest agent-ui-mermaid/in-a-terminal-its-source-coloured ()
  (skip-unless (fboundp 'mermaid-mode))
  (let ((text (agent-ui-render agent-ui-test-aum--flow (agent-ui-context :width 60))))
    (should (equal (substring-no-properties text) "flowchart LR\n    build --> test"))
    (should (memq 'font-lock-keyword-face (ensure-list (get-text-property 0 'face text))))))

(ert-deftest agent-ui-mermaid/its-source-fits-the-width ()
  "Its source, shown in a terminal or until drawn, wrapped to the width,
each line's rest under its indent (a line ran 190 columns at every width)."
  (let* ((component '(:type "mermaid" :diagram "flowchart LR\n    parser[The parser module] --> checker[The type checker, slow on big files]"))
         (text (substring-no-properties (agent-ui-render component (agent-ui-context :width 24)))))
    (should (equal text (concat "flowchart LR\n"
                                "    parser[The parser\n"
                                "    module] -->\n"
                                "    checker[The type\n"
                                "    checker, slow on big\n"
                                "    files]")))
    (agent-ui-test-aum
      (dolist (line (split-string (substring-no-properties (agent-ui-test-aum--draw component (agent-ui-test-aum--gui 24))) "\n"))
        (should (<= (string-width line) 24))))))

(ert-deftest agent-ui-mermaid/drawn-in-the-background ()
  (agent-ui-test-aum
    (let ((text (agent-ui-test-aum--draw agent-ui-test-aum--flow)))
      ;; Its source meanwhile.
      (should (string-prefix-p "flowchart LR\n    build --> test\ndrawing…" (substring-no-properties text)))
      (should-not (agent-ui-test-aum--image text)))
    ;; Drawn: its components redrawn, now its image.
    (should (agent-ui-test-mermaid--wait (lambda () redrawn)))
    (should (equal redrawn '("flowchart LR\n    build --> test")))
    (let* ((text (agent-ui-test-aum--draw agent-ui-test-aum--flow))
           (image (agent-ui-test-aum--image text)))
      (should (eq (car image) 'image))
      (should (eq (image-property image :type) 'svg))
      ;; Its size in its data, pixels (the stand-in's has none: its source's).
      (should (string-search "build --> test" (image-property image :data)))
      ;; Its labels' spaces kept (librsvg drops a tspan's first space).
      (should (string-search "xml:space=\"preserve\"" (image-property image :data))))
    (should (= (length (agent-ui-test-mermaid--runs mmdc)) 1))))

(ert-deftest agent-ui-mermaid/sized-to-the-canvas ()
  (let ((svg "<svg xml:space=\"preserve\" id=\"my-svg\" width=\"100%\" style=\"max-width: 1200px; background-color: transparent;\" viewBox=\"0 0 1200 300\"><g/></svg>"))
    ;; Wider than the canvas (59 columns of 8 px): as wide as it.
    (let ((sized (agent-ui-mermaid--sized svg (agent-ui-test-aum--gui 60))))
      (should (string-prefix-p "<svg width=\"472\" height=\"118\" xml:space=\"preserve\" id=\"my-svg\"" sized))
      (should-not (string-search "max-width" sized))
      (should (string-search "background-color: transparent;" sized))
      ;; The snapshot reads its size there.
      (should (equal (agent-ui-snapshot--svg-size sized) '(472 . 118))))
    ;; Narrower: as it is.
    (should (string-prefix-p "<svg width=\"1200\" height=\"300\""
                             (agent-ui-mermaid--sized svg (agent-ui-test-aum--gui 200))))))

(ert-deftest agent-ui-mermaid/text-at-the-svgs-weight ()
  "mmdc's SVG at `agent-ui-svg-font-weight': on its root (its labels inherit
it), and in place of the regular weight a sequence's actors set inline; bold
stays bold; at 400, as it is."
  (let ((svg (concat "<?xml version=\"1.0\"?>\n<svg id=\"my-svg\" viewBox=\"0 0 10 10\">"
                     "<text style=\"text-anchor: middle; font-size: 16px; font-weight: 400;\">actor</text>"
                     "<text style=\"font-weight:normal\">note</text>"
                     "<text font-weight=\"bold\">title</text></svg>")))
    (let* ((agent-ui-svg-font-weight 600)
           (weighted (agent-ui-mermaid--weighted svg)))
      (should (string-prefix-p "<?xml version=\"1.0\"?>\n<svg font-weight=\"600\" id=\"my-svg\"" weighted))
      (should (string-search "font-size: 16px; font-weight: 600;\">actor" weighted))
      (should (string-search "font-weight: 600\">note" weighted))
      (should (string-search "font-weight=\"bold\">title" weighted)))
    (let ((agent-ui-svg-font-weight 400))
      (should (equal (agent-ui-mermaid--weighted svg) svg)))))

(ert-deftest agent-ui-mermaid/an-update-draws-anew ()
  (agent-ui-test-aum
    (agent-ui-test-aum--draw agent-ui-test-aum--flow)
    (should (agent-ui-test-mermaid--wait (lambda () redrawn)))
    (let ((text (agent-ui-test-aum--draw '(:type "mermaid" :diagram "flowchart LR\n    build --> deploy"))))
      (should (string-search "drawing…" (substring-no-properties text))))
    (should (agent-ui-test-mermaid--wait (lambda () (= (length redrawn) 2))))
    (should (string-search "build --> deploy"
                           (image-property (agent-ui-test-aum--image (agent-ui-test-aum--draw '(:type "mermaid" :diagram "flowchart LR\n    build --> deploy")))
                                           :data)))))

(ert-deftest agent-ui-mermaid/an-error-mermaid-s-message ()
  (agent-ui-test-aum
    (let ((component '(:type "mermaid" :diagram "flowchart LR\n    a --> ERROR")))
      (agent-ui-test-aum--draw component)
      (should (agent-ui-test-mermaid--wait (lambda () redrawn)))
      (let ((text (agent-ui-test-aum--draw component)))
        (should (string-prefix-p "flowchart LR\n    a --> ERROR\nParse error on line 2:" (substring-no-properties text)))
        (should (eq (get-text-property (string-search "Parse" text) 'face text) 'agent-ui-error)))
      ;; Not drawn again.
      (agent-ui-test-aum--draw component)
      (accept-process-output nil 0.1)
      (should (= (length (agent-ui-test-mermaid--runs mmdc)) 1)))))

(ert-deftest agent-ui-mermaid/a-markdown-component-s-blocks ()
  (agent-ui-test-aum
    (let ((component '(:type "markdown" :id "notes" :markdown "The flow:\n\n```mermaid\nflowchart LR\n    build --> test\n```\n\nThat's it.")))
      (let ((text (substring-no-properties (agent-ui-test-aum--draw component))))
        (should (string-search "The flow:" text))
        (should (string-search "flowchart LR\n    build --> test\ndrawing…" text))
        (should (string-search "That's it." text))
        (should-not (string-search "```" text)))
      (should (agent-ui-test-mermaid--wait (lambda () redrawn)))
      (let ((text (agent-ui-test-aum--draw component)))
        (should (eq (car (agent-ui-test-aum--image text)) 'image))
        (should (string-search "That's it." (substring-no-properties text)))))))

(ert-deftest agent-ui-mermaid/redrawn-where-it-shows ()
  "The components showing a diagram, in a canvas: a mermaid component's, a
markdown one's block, inside a panel too."
  (should (agent-ui-mermaid--shows-p '(:type "mermaid" :diagram " a\n") "a"))
  (should-not (agent-ui-mermaid--shows-p '(:type "mermaid" :diagram "b") "a"))
  (should (agent-ui-mermaid--shows-p '(:type "markdown" :markdown "x\n```mermaid\na\n```") "a"))
  (should-not (agent-ui-mermaid--shows-p '(:type "markdown" :markdown "no diagram")))
  (should (agent-ui-mermaid--shows-p '(:type "markdown" :markdown "x\n~~~ mermaid\na\n~~~")))
  (should-not (agent-ui-mermaid--shows-p '(:type "text" :text "a") "a")))


(ert-deftest agent-ui-mermaid/its-example ()
  (let ((example (agent-ui-type-example (agent-ui-type 'mermaid))))
    (should (string-search "-->" (plist-get example :diagram)))
    (should (agent-ui-check "mermaid" (append '(:type "mermaid") example)))))

;; Drawn dark or light as the frame, on a transparent background.
(ert-deftest agent-ui-mermaid/dark-or-light-as-the-frame ()
  (agent-ui-test-mermaid--with-mmdc
    (agent-ui-test-mermaid--theme 'dark
      (let (done)
        (should-not (agent-ui-mermaid-render "flowchart LR\n    a --> b" (lambda (file _) (setq done file))))
        (should (agent-ui-test-mermaid--wait (lambda () done)))
        ;; Drawn already: its file at once.
        (should (equal (agent-ui-mermaid-render "flowchart LR\n    a --> b" #'ignore) done))))
    (agent-ui-test-mermaid--theme 'light
      (let (done)
        (agent-ui-mermaid-render "flowchart LR\n    a --> b" (lambda (file _) (setq done file)))
        (should (agent-ui-test-mermaid--wait (lambda () done)))))
    (let ((runs (agent-ui-test-mermaid--runs mmdc)))
      (should (= (length runs) 2))
      (should (equal (cadr (member "-t" (nth 0 runs))) "dark"))
      (should (equal (cadr (member "-t" (nth 1 runs))) "default"))
      (should (equal (cadr (member "-b" (nth 0 runs))) "transparent"))
      ;; Labels as SVG text: Emacs draws no HTML.
      (let ((config (cadr (member "-c" (nth 0 runs)))))
        (should (string-search "\"htmlLabels\": false"
                               (with-temp-buffer (insert-file-contents config) (buffer-string))))))))

;; Without mmdc: what to install, said as the diagram's error.
(ert-deftest agent-ui-mermaid/without-mmdc ()
  (let ((agent-ui-mmdc "agent-ui-no-such-mmdc")
        (agent-ui-mermaid-cache-directory (agent-ui-test-tmp-file "mermaid/none/"))
        message)
    (should-not (agent-ui-mermaid-render "flowchart LR\n    x --> y" (lambda (_ m) (setq message m))))
    (should (agent-ui-test-mermaid--wait (lambda () message)))
    (should (string-search "npm install -g @mermaid-js/mermaid-cli" message))))

;; Another renderer, or none: their source.
(ert-deftest agent-ui-mermaid/no-renderer ()
  (let ((agent-ui-mermaid-render-function nil))
    (should (equal (substring-no-properties
                    (agent-ui-render agent-ui-test-aum--flow
                                     (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
                   "flowchart LR\n    build --> test"))))

;; A theme switch: each diagram drawn again.
(ert-deftest agent-ui-mermaid/a-theme-switch-draws-again ()
  (let (redrawn)
    (cl-letf (((symbol-function 'agent-ui-mermaid--redraw)
               (lambda (&optional diagram) (push (or diagram 'all) redrawn))))
      (agent-ui-mermaid-theme-changed))
    (should (equal redrawn '(all)))))

(ert-deftest agent-ui-mermaid/a-theme-switch-before-any-diagram ()
  "A theme's hooks run as Emacs starts: before a diagram was drawn, a
theme switch loads nothing (agent-ui-mermaid.el and Agent UI's parts
with it took ~25 ms of Emacs's start)."
  (should (equal (agent-ui-test-fresh
                  '(progn (agent-ui-mermaid-theme-changed)
                          (seq-filter #'featurep '(agent-ui-mermaid agent-ui-core agent-ui-canvas))))
                 nil)))

;; mmdc (node, puppeteer) reads its configuration from its working folder up:
;; a project's .puppeteerrc.cjs is JavaScript it runs.
(ert-deftest agent-ui-mermaid/mmdc-run-outside-the-project ()
  "mmdc runs in Agent UI's cache folder, never in the canvas's folder (the
agent's project, whose .puppeteerrc.cjs it would run, doom-ht6.136)."
  (agent-ui-test-mermaid--with-mmdc
    (let* ((project (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "mermaid/project-") t)))
           (pwd (expand-file-name "pwd" (file-name-directory mmdc)))
           (done nil))
      (with-temp-file mmdc
        (insert "#!/bin/sh\npwd > \"$(dirname \"$0\")/pwd\"\n"
                "while [ $# -gt 0 ]; do case \"$1\" in -o) out=\"$2\"; shift ;; esac; shift; done\n"
                "printf '<svg viewBox=\"0 0 1 1\"></svg>' > \"$out\"\n"))
      (let ((default-directory project))
        (agent-ui-mermaid-render "graph TD\n  A --> B" (lambda (file _error) (setq done (or file t)))))
      (should (agent-ui-test-mermaid--wait (lambda () done)))
      (let ((ran (string-trim (with-temp-buffer (insert-file-contents pwd) (buffer-string)))))
        (should-not (equal (file-truename (file-name-as-directory ran)) (file-truename project)))
        (should (equal (file-truename (file-name-as-directory ran))
                       (file-truename agent-ui-mermaid-cache-directory)))))))

;;; agent-ui-mermaid-tests.el ends here
