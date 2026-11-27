;;; agent-ui-request-tests.el --- Tests for Agent UI: request  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-request.el and bin/agent-ui: the agent's way in. Each
;; operation through `agent-ui-request' (a request folder, its reply), then the
;; script itself, run as the agent runs it, its emacsclient answered by a
;; server started in this test Emacs (never the user's).

;;; Code:

(require 'agent-ui-test-helper)

(require 'server)

;; ====== HELPERS ======

(defconst agent-ui-test-aur-script (expand-file-name "bin/agent-ui" agent-ui-test-root))

(defmacro agent-ui-test-aur (&rest body)
  "BODY with a canvas of its own (the default: killed after), the real
component types, no window shown, no agent-shell sessions."
  (declare (indent 0))
  `(let* ((agent-ui-default-canvas (make-temp-name "test-"))
          (agent-ui-display-function #'ignore)
          (canvas (agent-ui-canvas)))
     (cl-letf (((symbol-function 'agent-ui--sessions) #'ignore))
       (unwind-protect (progn ,@body)
         (kill-buffer canvas)))))

(defun agent-ui-test-aur-request (op &optional id payload session cwd)
  "OP's reply (parsed) as bin/agent-ui gets it: a request folder with ID,
SESSION, CWD and PAYLOAD (a string), answered by `agent-ui-request'."
  (let ((dir (make-temp-file (agent-ui-test-tmp-file "aur-") t)))
    (with-temp-file (expand-file-name "request" dir)
      (insert (format "%s\n%s\n%s\n%s\n" op (or id "") (or session "") (or cwd ""))))
    (when payload
      (with-temp-file (expand-file-name "payload" dir) (insert payload)))
    (should (eq (agent-ui-request dir) t))
    (agent-ui-parse-json (with-temp-buffer
                           (insert-file-contents (expand-file-name "reply" dir))
                           (buffer-string)))))

(defun agent-ui-test-aur-request-with (op id options)
  "OP's reply (parsed) for ID with OPTIONS (a string: \"changed\")."
  (let ((dir (make-temp-file (agent-ui-test-tmp-file "aur-") t)))
    (with-temp-file (expand-file-name "request" dir)
      (insert (format "%s\n%s\n\n\n%s\n" op (or id "") (or options ""))))
    (should (eq (agent-ui-request dir) t))
    (agent-ui-parse-json (with-temp-buffer
                           (insert-file-contents (expand-file-name "reply" dir))
                           (buffer-string)))))

(defun agent-ui-test-aur-text ()
  "The canvas's text under its top line (an empty line of its own: checked)."
  (with-current-buffer (agent-ui-canvas)
    (agent-ui--flush)
    (should (eql (char-after (point-min)) ?\n))
    (buffer-substring-no-properties (1+ (point-min)) (point-max))))

;; ====== OPERATIONS ======

(ert-deftest agent-ui-request/get-what-it-shows-as-data ()
  "get: the canvas's components with their properties and values, or one;
--changed: only those changed since this session's last read, and those
gone."
  (agent-ui-test-aur
    (agent-ui-test-aur-request "show" nil "{\"id\":\"build\",\"type\":\"progress\",\"max\":12,\"value\":3}")
    (agent-ui-test-aur-request "show" nil "{\"id\":\"tests\",\"type\":\"table\",\"columns\":[\"Test\",\"Result\"],\"rows\":[[\"lexer\",\"passed\"]]}")
    (let ((reply (agent-ui-test-aur-request "get")))
      (should (eq (plist-get reply :ok) t))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (plist-get reply :components)) '("build" "tests")))
      (should (equal (plist-get (car (plist-get reply :components)) :value) 3))
      (should (equal (plist-get (cadr (plist-get reply :components)) :rows) '(("lexer" "passed"))))
      (should-not (plist-member reply :dashboard)))
    (should (equal (mapcar (lambda (e) (plist-get e :id)) (plist-get (agent-ui-test-aur-request "get" "tests") :components))
                   '("tests")))
    (should (string-match-p "no component" (plist-get (agent-ui-test-aur-request "get" "nope") :error)))
    ;; --changed: nothing, all read already (any read counts); then only
    ;; what changed, and what's gone.
    (should-not (plist-get (agent-ui-test-aur-request-with "get" nil "changed") :components))
    (agent-ui-test-aur-request "update" "build" "{\"value\":7}")
    (let ((reply (agent-ui-test-aur-request-with "get" nil "changed")))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (plist-get reply :components)) '("build")))
      (should (equal (plist-get (car (plist-get reply :components)) :value) 7))
      (should-not (plist-get reply :removed)))
    (agent-ui-test-aur-request "remove" "tests")
    (should (equal (plist-get (agent-ui-test-aur-request-with "get" nil "changed") :removed) '("tests")))))

(ert-deftest agent-ui-request/get-changed-deep-or-late ()
  "get --changed: a change deep or late in a component counts (an 8th
step's status, a row past the 7th, a form's value inside a panel), not
only what `sxhash-equal' sees."
  (agent-ui-test-aur
    (let ((steps (lambda (eighth)
                   (json-encode `((id . "plan") (type . "steps")
                                  (steps . ,(vconcat (mapcar (lambda (i)
                                                               `((name . ,(format "Step %d" i))
                                                                 (status . ,(if (= i 8) eighth "done"))))
                                                             (number-sequence 1 10))))))))
          (rows (lambda (tenth)
                  (vconcat (mapcar (lambda (i) (vector (format "test %d" i) (if (= i 10) tenth "passed")))
                                   (number-sequence 1 30))))))
      (agent-ui-test-aur-request "show" nil (funcall steps "pending"))
      (agent-ui-test-aur-request "show" nil (json-encode `((id . "tests") (type . "table") (columns . ["Test" "Result"])
                                                           (rows . ,(funcall rows "running")))))
      (agent-ui-test-aur-request "show" nil "{\"id\":\"box\",\"type\":\"panel\",\"children\":[{\"id\":\"ask\",\"type\":\"form\",\"question\":\"q\",\"fields\":[{\"name\":\"a\",\"value\":\"x\"}]}]}")
      (agent-ui-test-aur-request-with "get" nil "changed")
      (agent-ui-test-aur-request "show" nil (funcall steps "failed"))
      (agent-ui-test-aur-request "update" "tests" (json-encode `((rows . ,(funcall rows "failed")))))
      (agent-ui-test-aur-request "update" "ask" "{\"fields\":[{\"name\":\"a\",\"value\":\"y\"}]}")
      (should (equal (mapcar (lambda (e) (plist-get e :id))
                             (plist-get (agent-ui-test-aur-request-with "get" nil "changed") :components))
                     '("plan" "tests" "box" "ask")))
      ;; Read: nothing changed since.
      (should-not (plist-get (agent-ui-test-aur-request-with "get" nil "changed") :components)))))


(ert-deftest agent-ui-request/shown-though-its-pane-cant-open ()
  "Its canvas's pane can't open: shown all the same, the reply ok, saying
so (it was ok false, the component half added)."
  (agent-ui-test-aur
    (let ((agent-ui-display-function (lambda (_b) (user-error "No room for another pane"))))
      (let ((reply (agent-ui-test-aur-request "show" nil "{\"id\":\"b\",\"type\":\"progress\",\"max\":4}")))
        (should (eq (plist-get reply :ok) t))
        (should (string-match-p "pane couldn't open (No room for another pane)" (plist-get reply :hidden))))
      (should (string-match-p "0/4" (agent-ui-test-aur-text))))
    ;; Shown: not said.
    (should-not (plist-get (agent-ui-test-aur-request "show" nil "{\"id\":\"c\",\"type\":\"progress\",\"max\":4}")
                           :hidden))))

(ert-deftest agent-ui-request/show-update-append-remove ()
  (agent-ui-test-aur
    ;; Its link too, for the agent's reply.
    (should (equal (agent-ui-test-aur-request "show" nil "{\"id\":\"b\",\"type\":\"progress\",\"max\":4}")
                   (list :ok t :id "b" :link (agent-ui-link agent-ui-default-canvas "b"))))
    (should (string-match-p "\\`░+  0/4  0%\n\n\\'" (agent-ui-test-aur-text)))
    (should (equal (agent-ui-test-aur-request "update" "b" "{\"value\":2,\"label\":\"half\"}")
                   '(:ok t :id "b")))
    (should (string-match-p "2/4  50%  half" (agent-ui-test-aur-text)))
    ;; null: back to its default.
    (agent-ui-test-aur-request "update" "b" "{\"label\":null}")
    (should-not (string-match-p "half" (agent-ui-test-aur-text)))
    (agent-ui-test-aur-request "show" nil "{\"id\":\"t\",\"type\":\"table\",\"columns\":[\"A\"]}")
    (should (equal (agent-ui-test-aur-request "append" "t" "{\"rows\":[[\"x\"],[\"y\"]]}")
                   '(:ok t :id "t")))
    (should (string-match-p " x\n y" (agent-ui-test-aur-text)))
    (should (equal (agent-ui-test-aur-request "list")
                   '(:ok t :components ((:id "b" :type "progress") (:id "t" :type "table")))))
    (should (equal (agent-ui-test-aur-request "remove" "b") '(:ok t :id "b")))
    (should (equal (agent-ui-test-aur-request "clear") '(:ok t)))
    (should (equal (agent-ui-test-aur-request "list") '(:ok t :components nil)))))

(ert-deftest agent-ui-request/show-with-an-id-given ()
  (agent-ui-test-aur
    ;; Made, or the one given beside the JSON.
    (should (equal (plist-get (agent-ui-test-aur-request "show" nil "{\"type\":\"progress\"}") :id)
                   "progress-1"))
    (should (equal (plist-get (agent-ui-test-aur-request "show" "mine" "{\"type\":\"progress\"}") :id)
                   "mine"))))

(ert-deftest agent-ui-request/types ()
  (agent-ui-test-aur
    (let ((reply (agent-ui-test-aur-request "types")))
      (should (eq (plist-get reply :ok) t))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) (plist-get reply :types))
                     '("activity" "chart" "choice" "code" "compare" "confirm" "countdown" "diff" "files" "form" "gauge" "graph" "heatmap" "html" "image" "log" "markdown" "math" "mermaid" "panel" "progress" "rank" "slider" "stats" "steps" "table" "tags" "text" "timeline" "todo"))))
    (let ((reply (agent-ui-test-aur-request "types" "table")))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) (plist-get reply :types)) '("table"))))
    (should (string-match-p "unknown type \"tabel\""
                            (plist-get (agent-ui-test-aur-request "types" "tabel") :error)))))

(ert-deftest agent-ui-request/batch ()
  (agent-ui-test-aur
    (let ((reply (agent-ui-test-aur-request
                  "batch" nil
                  "[{\"op\":\"show\",\"id\":\"p\",\"type\":\"progress\",\"max\":2},
                    {\"op\":\"update\",\"id\":\"p\",\"value\":1},
                    {\"op\":\"update\",\"id\":\"nope\",\"value\":1},
                    {\"op\":\"list\"},
                    {\"op\":\"remove\",\"id\":\"p\"}]")))
      ;; Each done, or why not; not ok if one wasn't.
      (should (eq (plist-get reply :ok) :false))
      (let ((results (plist-get reply :results)))
        (should (equal (nth 0 results) (list :ok t :id "p" :link (agent-ui-link agent-ui-default-canvas "p"))))
        (should (equal (nth 1 results) '(:ok t :id "p")))
        (should (string-match-p "no component \"nope\"" (plist-get (nth 2 results) :error)))
        (should (string-match-p "list isn't done in a batch" (plist-get (nth 3 results) :error)))
        (should (equal (nth 4 results) '(:ok t :id "p")))))
    (should (string-match-p "a JSON array"
                            (plist-get (agent-ui-test-aur-request "batch" nil "{\"op\":\"show\"}") :error)))
    (should (eq (plist-get (agent-ui-test-aur-request "batch" nil "[]") :ok) t))))

(ert-deftest agent-ui-request/errors-replied ()
  (agent-ui-test-aur
    (cl-flet ((err (&rest args) (let ((reply (apply #'agent-ui-test-aur-request args)))
                                  (should (eq (plist-get reply :ok) :false))
                                  (plist-get reply :error))))
      (should (string-match-p "\\`bad JSON" (err "show" nil "{\"type\":")))
      (should (equal (err "show" nil "") "show: no JSON given"))
      (should (equal (err "show" nil "[1]") "show: give a JSON object, not (1)"))
      (should (equal (err "update" nil "{\"value\":1}") "update: which component? give its id"))
      (should (string-match-p "unknown property \"total\""
                              (err "show" nil "{\"type\":\"progress\",\"total\":1}")))
      (should (string-match-p "unknown operation \"frob\"" (err "frob")))
      ;; No request at all.
      (let ((dir (make-temp-file (agent-ui-test-tmp-file "aur-") t)))
        (agent-ui-request dir)
        (should (string-match-p "request"
                                (with-temp-buffer
                                  (insert-file-contents (expand-file-name "reply" dir))
                                  (buffer-string))))))))

(ert-deftest agent-ui-request/the-canvas-by-session ()
  (agent-ui-test-aur
    (let ((name (make-temp-name "session-")))
      (unwind-protect
          (progn
            (agent-ui-test-aur-request "show" nil "{\"id\":\"a\",\"type\":\"progress\"}" name)
            (should (get-buffer (agent-ui-canvas-buffer-name name)))
            (should-not (agent-ui-components)))
        (kill-buffer (agent-ui-canvas-buffer-name name))))))

(defun agent-ui-test-aur-request-in (canvas op &optional id payload)
  "OP's reply, its request naming the other canvas CANVAS (its 6th line)."
  (let ((dir (make-temp-file (agent-ui-test-tmp-file "aur-") t)))
    (with-temp-file (expand-file-name "request" dir)
      (insert (format "%s\n%s\n\n\n\n%s\n" op (or id "") canvas)))
    (when payload
      (with-temp-file (expand-file-name "payload" dir) (insert payload)))
    (agent-ui-request dir)
    (agent-ui-parse-json (with-temp-buffer
                           (insert-file-contents (expand-file-name "reply" dir))
                           (buffer-string)))))

(ert-deftest agent-ui-request/another-canvas ()
  (agent-ui-test-aur
    (let ((tests (concat agent-ui-default-canvas " / tests"))
          (logs (concat agent-ui-default-canvas " / my logs")))
      (unwind-protect
          (progn
            ;; --canvas: the session's other canvas, its own buffer; linked so.
            (should (equal (agent-ui-test-aur-request-in "tests" "show" nil "{\"id\":\"a\",\"type\":\"text\",\"text\":\"x\"}")
                           (list :ok t :id "a" :link (agent-ui-link tests "a"))))
            (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components :canvas tests)) '("a")))
            (should-not (agent-ui-components))
            ;; Its ids its own: the same id in the session's canvas.
            (agent-ui-test-aur-request "show" nil "{\"id\":\"a\",\"type\":\"text\",\"text\":\"main\"}")
            (should (equal (plist-get (agent-ui-get "a" :canvas tests) :text) "x"))
            ;; "canvas" in the JSON: the same, not kept in the component.
            (agent-ui-test-aur-request "show" nil "{\"id\":\"l\",\"type\":\"text\",\"text\":\"y\",\"canvas\":\"my logs\"}")
            (should (equal (agent-ui-get "l" :canvas logs) '(:id "l" :type "text" :text "y")))
            (agent-ui-test-aur-request "update" "l" "{\"text\":\"z\",\"canvas\":\"my logs\"}")
            (should (equal (plist-get (agent-ui-get "l" :canvas logs) :text) "z"))
            ;; list and clear: a canvas's.
            (should (= (length (plist-get (agent-ui-test-aur-request-in "tests" "list") :components)) 1))
            (agent-ui-test-aur-request-in "tests" "clear")
            (should-not (agent-ui-components :canvas tests))
            (should (agent-ui-components))
            ;; A batch's operations, each its canvas.
            (should (eq (plist-get (agent-ui-test-aur-request "batch" nil "[{\"op\":\"show\",\"id\":\"b\",\"type\":\"text\",\"text\":\"1\",\"canvas\":\"tests\"},{\"op\":\"remove\",\"id\":\"l\",\"canvas\":\"my logs\"},{\"op\":\"remove\",\"id\":\"a\"}]")
                                   :ok)
                        t))
            (should (agent-ui-get "b" :canvas tests))
            (should-not (agent-ui-components :canvas logs))
            (should-not (agent-ui-components))
            ;; A name that won't do: said so.
            (should (string-match-p "canvas: a name of letters"
                                    (plist-get (agent-ui-test-aur-request-in "a/b" "list") :error)))
            (should (string-match-p "canvas: give a name"
                                    (plist-get (agent-ui-test-aur-request "show" nil "{\"type\":\"text\",\"canvas\":3}") :error))))
        (dolist (name (list tests logs))
          (when (get-buffer (agent-ui-canvas-buffer-name name))
            (kill-buffer (agent-ui-canvas-buffer-name name))))))))

(ert-deftest agent-ui-request/unicode-both-ways ()
  (agent-ui-test-aur
    (agent-ui-test-aur-request "show" nil "{\"id\":\"u\",\"type\":\"progress\",\"label\":\"ünïcødé ✓ 日本\"}")
    (should (string-match-p "ünïcødé ✓ 日本" (agent-ui-test-aur-text)))
    (should (string-match-p "\"ünïcødé\""
                            (plist-get (agent-ui-test-aur-request "show" nil "{\"type\":\"ünïcødé\"}") :error)))))

;; Raw bytes in a string (a file or a command printing what isn't UTF-8):
;; U+FFFD in its reply, never no reply (doom-ht6.45).
(ert-deftest agent-ui-request/raw-bytes-replied ()
  (agent-ui-test-aur
    (agent-ui-show (list :id "r" :type "text" :text (string-to-multibyte "a\377b")))
    (agent-ui-show (list :id "u" :type "text" :text (unibyte-string #xce #xb1)))
    (let ((reply (agent-ui-test-aur-request "get")))
      (should (eq (plist-get reply :ok) t))
      (should (equal (mapcar (lambda (e) (plist-get e :text)) (plist-get reply :components))
                     '("a\uFFFDb" "α"))))
    ;; One that can't be written anyway: an error said.
    (cl-letf (((symbol-function 'agent-ui-do) (lambda (&rest _) (list :ok t :x (current-buffer)))))
      (let ((reply (agent-ui-test-aur-request "get")))
        (should (eq (plist-get reply :ok) :false))
        (should (string-match-p "couldn't be written as JSON" (plist-get reply :error)))))))

;; A list starting with false: an array, not an object (doom-ht6.57).
(ert-deftest agent-ui-request/false-first-in-a-list ()
  (should (equal (json-serialize (agent-ui-to-json '(:rows ((:false "beta-ui") (:false 1 :false 2)))))
                 "{\"rows\":[[false,\"beta-ui\"],[false,1,false,2]]}"))
  (should (equal (json-serialize (agent-ui-to-json '(:a :false :b nil))) "{\"a\":false,\"b\":null}")))

;; render, define: the agent sees what it draws; makes a type.
(ert-deftest agent-ui-request/render ()
  (agent-ui-test-aur
    (should (equal (agent-ui-test-aur-request "render" nil "{\"type\":\"text\",\"text\":\"hello\",\"title\":\"T\"}")
                   '(:ok t :text "T\nhello")))
    ;; Nothing shown.
    (should-not (agent-ui-components))
    ;; Wrong: an error, not a drawing of one.
    (should (string-match-p "unknown property"
                            (plist-get (agent-ui-test-aur-request "render" nil "{\"type\":\"text\",\"txt\":1}") :error)))))

(ert-deftest agent-ui-request/define ()
  (agent-ui-test-aur
    (let ((agent-ui-staging-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "staged-") t)))
          (agent-ui--types (copy-hash-table agent-ui--types)))
      (let ((reply (agent-ui-test-aur-request
                    "define" nil
                    "(agent-ui-define dots \"Dots.\" :props ((n integer \"How many\" :default 3))
  :example (:n 5) :text (lambda (props _ctx) (make-string (plist-get props :n) ?.)))")))
        (should (eq (plist-get reply :ok) t))
        (should (equal (plist-get reply :type) "dots"))
        (should (equal (plist-get reply :status) "waiting")))
      ;; Usable once the user keeps it.
      (should (string-match-p "dots"
                              (plist-get (agent-ui-test-aur-request "show" nil "{\"id\":\"d\",\"type\":\"dots\",\"n\":2}")
                                         :error)))
      (let ((agent-ui-kept-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "kept-") t))))
        (agent-ui-keep 'dots))
      (should (equal (plist-get (agent-ui-test-aur-request "show" nil "{\"id\":\"d\",\"type\":\"dots\",\"n\":2}") :id)
                     "d"))
      (should (string-match-p "one type (one agent-ui-define), not 0"
                              (plist-get (agent-ui-test-aur-request "define" nil "(setq x 1)") :error)))
      (should (string-match-p "define: no JSON given\\|give a type's code"
                              (plist-get (agent-ui-test-aur-request "define" nil "  ") :error))))))

;; ====== THE SCRIPT ======

(defmacro agent-ui-test-aur-with-server (&rest body)
  "BODY with this Emacs a server only the script talks to (EMACS_SOCKET_NAME)."
  (declare (indent 0))
  `(let* ((server-socket-dir (make-temp-file "/tmp/aui-" t))
          (server-name "test")
          (process-environment
           (append (list (concat "EMACS_SOCKET_NAME=" (expand-file-name server-name server-socket-dir))
                         "AGENT_UI_SESSION")
                   process-environment)))
     (unwind-protect
         (progn (server-start nil t) ,@body)
       (server-force-delete)
       (delete-directory server-socket-dir t))))

(defun agent-ui-test-aur-run (args &optional stdin)
  "Run bin/agent-ui with ARGS (STDIN given, else closed): (STATUS . OUTPUT).
Asynchronously: this Emacs, its server, answers it meanwhile."
  (let* ((output (generate-new-buffer " *agent-ui-run*"))
         (process (make-process :name "agent-ui" :buffer output
                                :command (cons agent-ui-test-aur-script args)
                                :connection-type 'pipe :noquery t :sentinel #'agent-ui-test-process-sentinel
                                :stderr (get-buffer-create " *agent-ui-stderr*"))))
    ;; A wrong use may have exited already (at once, 2): a finished process
    ;; can't be sent its input or its end ("Process agent-ui not running",
    ;; CI's Linux once).
    (when (process-live-p process)
      (condition-case nil
          (progn (when stdin (process-send-string process stdin))
                 (process-send-eof process))
        (error (when (process-live-p process)
                 (error "Couldn't send bin/agent-ui its input")))))
    (with-timeout (20 (delete-process process) (ert-fail "bin/agent-ui didn't end"))
      ;; Its output all read: not merely ended (`agent-ui-test-process-sentinel').
      (while (not (agent-ui-test-process-ended-p process))
        (accept-process-output nil 0.02)))
    (prog1 (cons (process-exit-status process)
                 (with-current-buffer output (string-trim (buffer-string))))
      (kill-buffer output))))

(ert-deftest agent-ui-request/the-script ()
  (agent-ui-test-aur
    (agent-ui-test-aur-with-server
      ;; get, --changed taken as its option.
      (agent-ui-test-aur-run '("show" "{\"id\":\"g\",\"type\":\"text\",\"text\":\"hi\"}"))
      (let ((run (agent-ui-test-aur-run '("get" "g" "--changed"))))
        (should (= (car run) 0))
        (should (string-match-p "\"text\":\"hi\"" (cdr run))))
      (should (= (car (agent-ui-test-aur-run '("get" "a" "b"))) 2))
      (agent-ui-test-aur-run '("remove" "g"))
      ;; JSON as an argument, or on stdin.
      (should (equal (agent-ui-test-aur-run '("show" "{\"id\":\"p\",\"type\":\"progress\",\"max\":4}"))
                     (cons 0 (format "{\"ok\":true,\"id\":\"p\",\"link\":\"%s\"}"
                                     (agent-ui-link agent-ui-default-canvas "p")))))
      (should (equal (agent-ui-test-aur-run '("update" "p") "{\"value\": 3, \"label\": \"a \\\"quote\\\" and \\\\\"}")
                     '(0 . "{\"ok\":true,\"id\":\"p\"}")))
      (should (string-match-p "3/4  75%  a \"quote\" and \\\\" (agent-ui-test-aur-text)))
      ;; Not done: 1, the reply says why.
      (let ((run (agent-ui-test-aur-run '("update" "q" "{}"))))
        (should (= (car run) 1))
        (should (string-match-p "\\`{\"ok\":false,\"error\":\"no component \\\\\"q\\\\\"" (cdr run))))
      (should (equal (car (agent-ui-test-aur-run '("list"))) 0))
      (should (string-match-p "\"name\":\"table\"" (cdr (agent-ui-test-aur-run '("types" "table")))))
      ;; A type's code from a file.
      (let ((agent-ui-staging-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "staged-") t)))
            (agent-ui--types (copy-hash-table agent-ui--types))
            (file (make-temp-file (agent-ui-test-tmp-file "type-") nil ".el"
                                  "(agent-ui-define bang \"!\" :example () :text (lambda (_p _c) \"!\"))")))
        (let ((run (agent-ui-test-aur-run (list "define" file))))
          (should (= (car run) 0))
          (should (string-match-p "\"status\":\"waiting\"" (cdr run))))
        (with-temp-file file
          (insert "(setq bang 1)"))
        (let ((run (agent-ui-test-aur-run (list "define" file))))
          (should (= (car run) 1))
          (should (string-match-p "one type (one agent-ui-define)" (cdr run))))
        (should (= (car (agent-ui-test-aur-run '("define" "/no/such/file.el"))) 2)))
      ;; render --ansi: in colour.
      (let ((run (agent-ui-test-aur-run '("render" "--ansi" "{\"type\":\"text\",\"text\":\"ok\",\"face\":\"success\"}"))))
        (should (= (car run) 0))
        (should (string-match-p "\\\\u001b\\[" (cdr run))))
      ;; --canvas NAME, wherever it is: the session's other canvas.
      (let ((tests (concat agent-ui-default-canvas " / tests")))
        (unwind-protect
            (progn
              (should (= (car (agent-ui-test-aur-run '("show" "--canvas" "tests" "{\"id\":\"c\",\"type\":\"text\",\"text\":\"t\"}"))) 0))
              (should (agent-ui-get "c" :canvas tests))
              (should (= (car (agent-ui-test-aur-run '("--canvas=tests" "remove" "c"))) 0))
              (should-not (agent-ui-components :canvas tests))
              (should (= (car (agent-ui-test-aur-run '("list" "--canvas"))) 2)))
          (when (get-buffer (agent-ui-canvas-buffer-name tests))
            (kill-buffer (agent-ui-canvas-buffer-name tests)))))
      ;; This directory's: the request says where it came from.
      (should (= (car (agent-ui-test-aur-run '("remove" "p"))) 0))
      (should-not (agent-ui-components)))))

(ert-deftest agent-ui-request/the-script-files-a-bug ()
  "agent-ui bug: JSON as an argument or on stdin; filed: 0; not filed: 1,
its reply with the report (agent-ui-bug.el, the filing stood in for)."
  (agent-ui-test-aur
    (agent-ui-test-aur-with-server
      (let* ((answer '(:id "lib-1" :new t :dir "/lib/"))
             (agent-ui-bug-filed-functions nil)
             ;; The same report filed each time (see agent-ui-bug's own test).
             (agent-ui-bug-same-within 0)
             (agent-ui--bugs-filed (make-hash-table :test #'equal))
             (agent-ui-bug-function (lambda (&rest _) (if (stringp answer) (error "%s" answer) answer))))
        (should (equal (agent-ui-test-aur-run '("bug" "{\"title\":\"x\",\"description\":\"y\"}"))
                       '(0 . "{\"ok\":true,\"issue\":\"lib-1\",\"new\":true}")))
        (setq answer "bd isn't installed")
        (let ((run (agent-ui-test-aur-run '("bug") "{\"title\":\"x\",\"description\":\"y\"}")))
          (should (= (car run) 1))
          (should (string-match-p "\"error\":\"Agent UI's bug wasn't filed: bd isn't installed" (cdr run)))
          (should (string-match-p "\"report\":\"# Agent UI: x\\\\n\\\\ny\\\\n" (cdr run))))
        (should (= (car (agent-ui-test-aur-run '("bug" "a" "b"))) 2))))))

(ert-deftest agent-ui-request/the-script-used-wrong ()
  (agent-ui-test-aur
    (agent-ui-test-aur-with-server
      (dolist (case '((("frob") . "unknown operation \\\\\"frob\\\\\"")
                      (("update") . "which component")
                      (("update" "a" "{}" "x") . "too many")
                      (("remove") . "agent-ui remove ID")
                      (("list" "x") . "takes no arguments")
                      (("show" "a" "b") . "too many")))
        (let ((run (agent-ui-test-aur-run (car case))))
          (should (= (car run) 2))
          (should (string-match-p "\\`{\"ok\":false,\"error\":" (cdr run)))
          (should (string-match-p (cdr case) (cdr run)))))
      ;; Nothing on stdin, no argument: nothing sent.
      (let ((run (agent-ui-test-aur-run '("show"))))
        (should (= (car run) 1))
        (should (string-match-p "show: no JSON given" (cdr run))))
      ;; Help: its header.
      (let ((run (agent-ui-test-aur-run '("--help"))))
        (should (= (car run) 0))
        (should (string-match-p "agent-ui show \\[JSON\\]" (cdr run))))
      (should (= (car (agent-ui-test-aur-run nil)) 2)))))

(ert-deftest agent-ui-request/the-script-without-emacs ()
  (let ((process-environment (cons "EMACS_SOCKET_NAME=/tmp/no-such-agent-ui-server"
                                   process-environment)))
    (let ((run (agent-ui-test-aur-run '("list"))))
      (should (= (car run) 3))
      (should (string-match-p "no Emacs server answered" (cdr run))))))

;; ====== doctor ======

(defun agent-ui-test-aur-doctor ()
  "Run bin/agent-ui doctor: (STATUS REPLY CHECKS), its checks as (NAME STATUS)."
  (let* ((run (agent-ui-test-aur-run '("doctor")))
         (reply (json-parse-string (cdr run) :object-type 'plist :array-type 'list)))
    (list (car run) reply
          (mapcar (lambda (c) (list (plist-get c :name) (plist-get c :status))) (plist-get reply :checks)))))

(ert-deftest agent-ui-request/the-script-doctor ()
  "bin/agent-ui doctor: its own checks (Command), then Emacs's."
  (agent-ui-test-aur
    (agent-ui-test-aur-with-server
      (let ((agent-ui-doctor-functions '(agent-ui-doctor--json-support agent-ui-doctor--server)))
        (pcase-let ((`(,status ,reply ,checks) (agent-ui-test-aur-doctor)))
          (should (= status 0))
          (should (eq (plist-get reply :ok) t))
          (should (equal (plist-get reply :summary) "1 warning, 4 passed"))
          ;; Its copy is the one Emacs gives agents; no session here.
          (should (equal checks '(("emacsclient" "ok") ("Session" "warn") ("Its copy" "ok")
                                  ("JSON" "ok") ("Emacs server" "ok"))))
          (should (equal (plist-get (car (plist-get reply :checks)) :group) "Command")))
        ;; One failing: exit 1.
        (cl-letf (((symbol-function 'agent-ui-doctor--json-support)
                   (lambda () (agent-ui-doctor--check "Required" "JSON" 'fail "none" "Get it"))))
          (pcase-let ((`(,status ,reply ,_) (agent-ui-test-aur-doctor)))
            (should (= status 1))
            (should (eq (plist-get reply :ok) :false))))
        ;; Emacs without Agent UI: this side's checks, and that, exit 3.
        (cl-letf (((symbol-function 'agent-ui-doctor-request) nil))
          (pcase-let ((`(,status ,reply ,checks) (agent-ui-test-aur-doctor)))
            (should (= status 3))
            (should (equal (plist-get reply :error) "Emacs runs, but without Agent UI"))
            (should (equal (car (last checks)) '("Agent UI in Emacs" "fail")))))
        ;; No arguments.
        (should (= (car (agent-ui-test-aur-run '("doctor" "x"))) 2))))))

(ert-deftest agent-ui-request/the-script-doctor-without-emacs ()
  "No Emacs to ask: the command's own checks, what's wrong, exit 3."
  (let ((process-environment (append '("EMACS_SOCKET_NAME=/tmp/no-such-agent-ui-server" "AGENT_UI_SESSION=s1")
                                     process-environment)))
    (pcase-let ((`(,status ,reply ,checks) (agent-ui-test-aur-doctor)))
      (should (= status 3))
      (should (eq (plist-get reply :ok) :false))
      (should (equal (plist-get reply :error) "no Emacs server answered"))
      (should (equal (plist-get reply :summary) "1 failed, 2 passed"))
      (should (equal checks '(("emacsclient" "ok") ("Session" "ok") ("Emacs server" "fail"))))
      (should (string-match-p "server-start" (plist-get (car (last (plist-get reply :checks))) :fix))))
    ;; No emacsclient: said, nothing asked.
    (let ((process-environment (cons "EMACSCLIENT=/no/such/emacsclient" process-environment)))
      (pcase-let ((`(,status ,reply ,checks) (agent-ui-test-aur-doctor)))
        (should (= status 3))
        (should (equal (plist-get reply :error) "no emacsclient to reach Emacs with"))
        (should (equal (car checks) '("emacsclient" "fail")))))))

(ert-deftest agent-ui-request/a-bug-given-time-to-be-filed ()
  "bin/agent-ui bug waits longer for Emacs than other operations (filing
runs bd, git: past 30 s, the agent was told Emacs didn't answer, and filed
it again) (doom-ht6.146)."
  (let* ((dir (make-temp-file (agent-ui-test-tmp-file "client-") t))
         (client (expand-file-name "emacsclient" dir))
         (args (expand-file-name "args" dir)))
    (with-temp-file client
      (insert (format "#!/bin/sh\necho \"$@\" >> %s\nexit 1\n" (shell-quote-argument args))))
    (set-file-modes client #o755)
    (let ((process-environment (cons (concat "EMACSCLIENT=" client) process-environment)))
      (agent-ui-test-aur-run '("bug" "{\"title\":\"x\",\"description\":\"y\"}"))
      (agent-ui-test-aur-run '("list")))
    (let ((runs (split-string (with-temp-buffer (insert-file-contents args) (buffer-string)) "\n" t)))
      (should (string-match-p "--timeout=120 " (nth 0 runs)))
      (should (string-match-p "--timeout=30 " (nth 1 runs))))))

;;; agent-ui-request-tests.el ends here
