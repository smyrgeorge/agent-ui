;;; agent-ui-mcp-tests.el --- Tests for Agent UI: mcp  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-mcp.el and its place in agent-ui.el: Agent UI as MCP
;; tools. The protocol (initialize, tools/list, tools/call, errors), each tool
;; as the command line it runs; then the server itself, a batch Emacs as the
;; agent starts it, its calls answered by a server started in this test Emacs
;; (never the user's); its registration for agent-shell's sessions.

;;; Code:

(require 'agent-ui-test-helper)

(require 'server)
(require 'agent-shell)
(load (expand-file-name "agent-ui-mcp.el" agent-ui-test-root) nil t)

;; ====== HELPERS ======

(defvar agent-ui-test-aumcp-sent nil "The messages the server sent, the latest first.")
(defvar agent-ui-test-aumcp-runs nil
  "The command lines it ran (their arguments, then :stdin and its input), the latest first.")

(defmacro agent-ui-test-aumcp (reply &rest body)
  "BODY with what the server sends recorded, bin/agent-ui not run but
recorded, its reply REPLY (a plist)."
  (declare (indent 1))
  `(let ((agent-ui-test-aumcp-sent nil) (agent-ui-test-aumcp-runs nil))
     (cl-letf (((symbol-function 'agent-ui-mcp--send)
                (lambda (m) (push (json-parse-string (agent-ui-mcp--json m) :object-type 'plist
                                                     :null-object nil :false-object :false)
                                  agent-ui-test-aumcp-sent)))
               ((symbol-function 'agent-ui-mcp--run)
                (lambda (args &optional input)
                  (push (append args (and input (list :stdin input))) agent-ui-test-aumcp-runs)
                  ,reply)))
       ,@body)))

(defun agent-ui-test-aumcp-handle (json)
  (agent-ui-mcp-handle (json-parse-string json :object-type 'plist :null-object :null :false-object :false))
  (car agent-ui-test-aumcp-sent))

;; ====== THE PROTOCOL ======

(ert-deftest agent-ui-mcp/initialize ()
  (agent-ui-test-aumcp '(:ok t)
    (let ((answer (agent-ui-test-aumcp-handle "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}")))
      (should (equal (plist-get answer :id) 1))
      (let ((result (plist-get answer :result)))
        ;; The client's version, its tools, its name, what it's for.
        (should (equal (plist-get result :protocolVersion) "2025-03-26"))
        (should (plist-get (plist-get result :capabilities) :tools))
        (should (equal (plist-get (plist-get result :serverInfo) :name) "agent-ui"))
        (should (string-match-p "canvas in your session's pane" (plist-get result :instructions)))
        ;; Information there, each as the component that fits it; questions too
        ;; (doom-ht6.28).
        (should (string-match-p "goes there as the component that fits it" (plist-get result :instructions)))
        (should (string-match-p "Ask there too, beyond a quick question" (plist-get result :instructions)))
        ;; A bug in Agent UI itself: how to file it, and where.
        (should (string-match-p "file it with the bug tool: it goes into Agent UI's own issues, never the project's"
                                (plist-get result :instructions)))))
    ;; A notification: no answer.
    (setq agent-ui-test-aumcp-sent nil)
    (agent-ui-test-aumcp-handle "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
    (should-not agent-ui-test-aumcp-sent)
    (should (equal (plist-get (agent-ui-test-aumcp-handle "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}") :result) nil))
    (should (equal (plist-get (plist-get (agent-ui-test-aumcp-handle "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"nope\"}") :error) :code)
                   -32601))))

(ert-deftest agent-ui-mcp/the-tools ()
  (agent-ui-test-aumcp '(:ok t :types [(:name "progress" :doc "A progress bar: VALUE of MAX.\nMore." :props [(:name "value" :kind "number")])])
    (let ((tools (append (plist-get (plist-get (agent-ui-test-aumcp-handle "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}") :result) :tools) nil)))
      (should (equal (mapcar (lambda (tool) (plist-get tool :name)) tools)
                     '("show" "update" "append" "remove" "clear" "list" "get" "types" "render" "snapshot" "batch" "bug" "panels" "open" "check" "define")))
      ;; Each its schema; show's description has the types, from Emacs.
      (dolist (tool tools)
        (should (equal (plist-get (plist-get tool :inputSchema) :type) "object")))
      (should (string-match-p "^- progress: A progress bar: VALUE of MAX\\. Properties: value (number)\\.$"
                              (plist-get (car tools) :description)))
      (should (equal (plist-get (plist-get (car tools) :inputSchema) :required) ["component"]))
      ;; Another canvas of the session: an argument of each tool that has one.
      (dolist (tool tools)
        (should (eq (and (plist-get (plist-get (plist-get tool :inputSchema) :properties) :canvas) t)
                    (not (member (plist-get tool :name) '("types" "define" "check" "panels" "open")))))
        ;; And one of the project's panels, open, the same tools (doom-3q5.6).
        (should (eq (and (plist-get (plist-get (plist-get tool :inputSchema) :properties) :panel) t)
                    (not (member (plist-get tool :name) '("types" "define" "check" "panels" "open")))))))))

(ert-deftest agent-ui-mcp/null-relayed-as-null ()
  "bin/agent-ui's reply relayed with its nulls null, not {} (doom-ht6.56)."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) (insert "{\"ok\":true,\"a\":null,\"rows\":[[\"x\",null]],\"b\":false}") 0)))
    (should (equal (agent-ui-mcp--json (agent-ui-mcp--run '("get")))
                   "{\"ok\":true,\"a\":null,\"rows\":[[\"x\",null]],\"b\":false}"))))

(ert-deftest agent-ui-mcp/each-tool-a-command-line ()
  (agent-ui-test-aumcp '(:ok t :id "b")
    (cl-flet ((call (name arguments)
                (agent-ui-test-aumcp-handle (format "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":%S,\"arguments\":%s}}"
                                          name arguments))
                (car agent-ui-test-aumcp-runs)))
      (should (equal (call "show" "{\"component\":{\"id\":\"b\",\"type\":\"progress\",\"rows\":[[\"a\",null]],\"x\":false}}")
                     '("show" :stdin "{\"id\":\"b\",\"type\":\"progress\",\"rows\":[[\"a\",null]],\"x\":false}")))
      (should (equal (call "update" "{\"id\":\"b\",\"patch\":{\"value\":3,\"label\":null}}")
                     '("update" "b" :stdin "{\"value\":3,\"label\":null}")))
      (should (equal (call "append" "{\"id\":\"t\",\"patch\":{\"rows\":[[\"x\"]]}}")
                     '("append" "t" :stdin "{\"rows\":[[\"x\"]]}")))
      (should (equal (call "remove" "{\"id\":\"b\"}") '("remove" "b")))
      (should (equal (call "snapshot" "{\"id\":\"b\"}") '("snapshot" "b")))
      ;; A project panel's file checked (doom-3q5.1).
      (should (equal (call "check" "{\"name\":\"service\"}") '("check" "service")))
      ;; The project's panels, opening one, working on one (doom-3q5.6).
      (should (equal (call "panels" "{}") '("panels")))
      (should (equal (call "open" "{\"name\":\"service\"}") '("open" "service")))
      (should (equal (call "update" "{\"id\":\"ci\",\"patch\":{\"rows\":[]},\"panel\":\"service\"}")
                     '("update" "ci" "--panel" "service" :stdin "{\"rows\":[]}")))
      (should (equal (call "clear" "{}") '("clear")))
      (should (equal (call "list" "{}") '("list")))
      (should (equal (call "types" "{}") '("types")))
      (should (equal (call "types" "{\"type\":\"table\"}") '("types" "table")))
      (should (equal (call "render" "{\"component\":{\"type\":\"text\",\"text\":\"ü\"}}")
                     '("render" :stdin "{\"type\":\"text\",\"text\":\"ü\"}")))
      (should (equal (call "remove" "{\"id\":\"b\",\"canvas\":\"tests\"}") '("remove" "b" "--canvas" "tests")))
      (should (equal (call "types" "{\"canvas\":\"tests\"}") '("types")))
      (should (equal (call "batch" "{\"operations\":[{\"op\":\"remove\",\"id\":\"b\"}]}")
                     '("batch" :stdin "[{\"op\":\"remove\",\"id\":\"b\"}]")))
      ;; A bug: as given, its canvas apart.
      (should (equal (call "bug" "{\"title\":\"t\",\"description\":\"d\",\"repro\":{\"type\":\"text\"},\"new\":false,\"canvas\":\"tests\"}")
                     '("bug" "--canvas" "tests"
                       :stdin "{\"title\":\"t\",\"description\":\"d\",\"repro\":{\"type\":\"text\"},\"new\":false}")))
      ;; A type's code: in a file, gone after.
      (let ((run (call "define" "{\"code\":\"(agent-ui-define x)\"}")))
        (should (equal (car run) "define"))
        (should-not (file-exists-p (cadr run))))
      ;; Its reply, as the result's text; not an error.
      (let ((result (plist-get (car agent-ui-test-aumcp-sent) :result)))
        (should (equal (plist-get (aref (plist-get result :content) 0) :text) "{\"ok\":true,\"id\":\"b\"}"))
        (should (eq (plist-get result :isError) :false)))))
  ;; Not done: an error, its reply saying why.
  (agent-ui-test-aumcp '(:ok :false :error "no component \"z\"")
    (let ((result (plist-get (agent-ui-test-aumcp-handle "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"remove\",\"arguments\":{\"id\":\"z\"}}}")
                             :result)))
      (should (eq (plist-get result :isError) t))
      (should (string-match-p "no component" (plist-get (aref (plist-get result :content) 0) :text))))
    (should (string-match-p "unknown tool frob"
                            (plist-get (aref (plist-get (plist-get (agent-ui-test-aumcp-handle "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"frob\",\"arguments\":{}}}") :result) :content) 0) :text)))))

;; A component larger than the command line allows (doom-ht6.107).
(ert-deftest agent-ui-mcp/json-on-stdin ()
  "A component's JSON goes to bin/agent-ui on stdin, not as an argument:
one of megabytes, over the system's argument limit, gets through."
  (let* ((script (make-temp-file "agent-ui-mcp-" nil ".sh"
                                 "#!/bin/sh\nprintf '{\"ok\":true,\"args\":\"%s\",\"bytes\":%s}' \"$*\" \"$(wc -c | tr -d ' ')\"\n"))
         (agent-ui-mcp-command script)
         (text (make-string (* 3 1024 1024) ?x))
         (json (agent-ui-mcp--json (list :id "big" :type "text" :text text))))
    (unwind-protect
        (progn
          (set-file-modes script #o700)
          (let ((reply (agent-ui-mcp--call "show" (list :component (list :id "big" :type "text" :text text)
                                                        :canvas "tests"))))
            (should-not (car reply))
            (let ((reply (json-parse-string (cdr reply) :object-type 'plist)))
              ;; Only the operation and the options as arguments; the JSON whole on stdin.
              (should (equal (plist-get reply :args) "show --canvas tests"))
              (should (equal (plist-get reply :bytes) (string-bytes json)))))
          ;; An update's patch, too, its id an argument.
          (let ((reply (json-parse-string
                        (cdr (agent-ui-mcp--call "update" (list :id "big" :patch (list :text "ü"))))
                        :object-type 'plist)))
            (should (equal (plist-get reply :args) "update big"))
            (should (equal (plist-get reply :bytes) (string-bytes "{\"text\":\"ü\"}"))))
          ;; An operation without JSON: nothing on stdin.
          (should (equal (plist-get (json-parse-string (cdr (agent-ui-mcp--call "remove" (list :id "big")))
                                                       :object-type 'plist)
                                    :bytes)
                         0)))
      (delete-file script))))

;; ====== THE SERVER ITSELF ======

(defun agent-ui-test-aumcp-serve (lines)
  "The server, as the agent starts it, given LINES on stdin: its answers,
parsed."
  (let* ((output (generate-new-buffer " *mcp*"))
         (process (make-process :name "agent-ui-mcp" :buffer output
                                :command (list (expand-file-name invocation-name invocation-directory)
                                               "--batch" "-Q" "-l"
                                               (expand-file-name "agent-ui-mcp.el" agent-ui-test-root)
                                               "-f" "agent-ui-mcp-main")
                                :connection-type 'pipe :noquery t :sentinel #'agent-ui-test-process-sentinel
                                :coding 'utf-8
                                :stderr (get-buffer-create " *mcp-stderr*"))))
    (process-send-string process (concat (string-join lines "\n") "\n"))
    (process-send-eof process)
    (with-timeout (30 (delete-process process) (ert-fail "The MCP server didn't end"))
      ;; Its output all read: not merely ended (`agent-ui-test-process-sentinel').
      (while (not (agent-ui-test-process-ended-p process))
        (accept-process-output nil 0.02)))
    (prog1 (mapcar (lambda (line) (json-parse-string line :object-type 'plist :null-object nil :false-object :false))
                   (split-string (with-current-buffer output (buffer-string)) "\n" t))
      (kill-buffer output))))

(ert-deftest agent-ui-mcp/the-server ()
  (let* ((agent-ui-default-canvas (make-temp-name "mcp-"))
         (agent-ui-display-function #'ignore)
         (server-socket-dir (make-temp-file "/tmp/aui-mcp-" t))
         (server-name "test")
         (process-environment
          (append (list (concat "EMACS_SOCKET_NAME=" (expand-file-name server-name server-socket-dir))
                        (concat "AGENT_UI_SESSION=" agent-ui-default-canvas))
                  process-environment)))
    (unwind-protect
        (progn
          (server-start nil t)
          (let ((answers (agent-ui-test-aumcp-serve
                          (list "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}"
                                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"show\",\"arguments\":{\"component\":{\"id\":\"t\",\"type\":\"text\",\"text\":\"ünïcødé ✓ 日本\"}}}}"
                                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"render\",\"arguments\":{\"component\":{\"type\":\"table\",\"columns\":[\"A\"],\"rows\":[[\"x\"]]}}}}"
                                "not json"))))
            (should (equal (mapcar (lambda (a) (plist-get a :id)) answers) '(1 2 3 4 nil)))
            ;; tools/list: the types, asked of this Emacs.
            (should (string-match-p "^- table: "
                                    (plist-get (aref (plist-get (plist-get (nth 1 answers) :result) :tools) 0) :description)))
            ;; show: on the session's canvas, its text whole.
            (should (eq (plist-get (plist-get (nth 2 answers) :result) :isError) :false))
            (should (equal (plist-get (agent-ui-get "t") :text) "ünïcødé ✓ 日本"))
            ;; render: its drawing back, box characters and all.
            (should (equal (plist-get (json-parse-string
                                       (plist-get (aref (plist-get (plist-get (nth 3 answers) :result) :content) 0) :text)
                                       :object-type 'plist)
                                      :text)
                           " A\n──\n x"))
            (should (equal (plist-get (plist-get (nth 4 answers) :error) :code) -32700))))
      (server-force-delete)
      (delete-directory server-socket-dir t)
      (when (get-buffer (agent-ui-canvas-buffer-name agent-ui-default-canvas))
        (kill-buffer (agent-ui-canvas-buffer-name agent-ui-default-canvas))))))

;; ====== FOR EACH SESSION ======


(ert-deftest agent-ui-mcp/for-each-session ()
  (should agent-ui-mcp)
  (should agent-ui-agent-mcp)
  (let ((server (seq-find (lambda (s) (equal (alist-get 'name s) "agent-ui")) agent-shell-mcp-servers)))
    (should server)
    ;; This Emacs, in batch, the server's file.
    (should (equal (alist-get 'command server) (expand-file-name invocation-name invocation-directory)))
    (should (equal (alist-get 'args server)
                   (list "--batch" "-Q" "-l" (expand-file-name "agent-ui-mcp.el" agent-ui-test-root)
                         "-f" "agent-ui-mcp-main")))
    ;; Its environment, read in the session's buffer when it starts.
    (let ((session (generate-new-buffer "Claude Agent @ test")))
      (unwind-protect
          (with-current-buffer session
            (setq default-directory "/tmp/proj/")
            (let ((env (agent-shell--eval-dynamic-values (alist-get 'env server))))
              (should (equal env '(((name . "AGENT_UI_SESSION") (value . "Claude Agent @ test"))
                                   ((name . "AGENT_UI_DIR") (value . "/tmp/proj/")))))))
        (kill-buffer session))))
  ;; Registered again: replaced, not added.
  (let ((agent-shell-mcp-servers (list '((name . "other")))))
    (agent-ui--mcp-register)
    (agent-ui--mcp-register)
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) agent-shell-mcp-servers) '("other" "agent-ui"))))
  ;; Its system prompt says so.
  (cl-letf (((symbol-function 'server-running-p) (lambda (&rest _) t)))
    (should (string-match-p "MCP tools too" (agent-ui-agent-context)))))

;; The mode off: taken out.
(ert-deftest agent-ui-mcp/unregistered ()
  (let ((agent-shell-mcp-servers (list '((name . "other")))))
    (agent-ui--mcp-register)
    (agent-ui--mcp-unregister)
    (should (equal agent-shell-mcp-servers '(((name . "other")))))))

;;; agent-ui-mcp-tests.el ends here
