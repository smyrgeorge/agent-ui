;;; stand-in.el --- A stand-in coding agent for the README's media  -*- lexical-binding: t; -*-

;;; Commentary:

;; A stand-in coding agent: it speaks ACP (JSON-RPC, a message a line, on
;; stdin and stdout) as claude-agent-acp does, so agent-shell runs a real
;; session with it, offline, at no cost.  scripts/media.el's session scene
;; runs it in a batch Emacs:
;;
;;   emacs --batch -Q -l scripts/media/stand-in.el -f stand-in-main
;;
;; A prompt starting with "Release" runs the tests (one fails, 3 s), then
;; the build (3 s), says one test fails and ends its turn; any other prompt
;; is answered "ok: PROMPT".

;;; Code:

(require 'json)
(require 'subr-x)

(defun stand-in--send (object)
  "Write OBJECT as a JSON line."
  (princ (concat (json-serialize object) "\n")))

(defun stand-in--result (id result)
  "Answer request ID with RESULT."
  (stand-in--send `(:jsonrpc "2.0" :id ,id :result ,result)))

(defun stand-in--update (session update)
  "Send SESSION's UPDATE."
  (stand-in--send `(:jsonrpc "2.0" :method "session/update"
                    :params (:sessionId ,session :update ,update))))

(defun stand-in--say (session text)
  "Say TEXT in SESSION."
  (stand-in--update session `(:sessionUpdate "agent_message_chunk"
                              :content (:type "text" :text ,text))))

(defun stand-in--prompt (id params)
  "Prompt ID with PARAMS: do what it says (see the Commentary)."
  (let ((session (gethash "sessionId" params))
        (text (mapconcat (lambda (block) (or (gethash "text" block) ""))
                         (gethash "prompt" params) "")))
    (if (not (string-match-p "\\`Release" text))
        (stand-in--say session (format "ok: %s" text))
      (stand-in--update session '(:sessionUpdate "tool_call" :toolCallId "v1" :title "make test"
                                  :kind "execute" :status "in_progress"))
      (sleep-for 3)
      (stand-in--update session '(:sessionUpdate "tool_call_update" :toolCallId "v1" :status "failed"))
      (stand-in--update session '(:sessionUpdate "tool_call" :toolCallId "v2" :title "make build"
                                  :kind "execute" :status "in_progress"))
      (sleep-for 3)
      (stand-in--update session '(:sessionUpdate "tool_call_update" :toolCallId "v2" :status "completed"))
      (stand-in--say session "The build is done, but `checker` fails: its test still expects the old error message. I haven't published v2.4; the steps, the tests and the build are under us, and I've asked you there how to go on."))
    (stand-in--result id '(:stopReason "end_turn"))))

(defun stand-in--handle (message)
  "Handle MESSAGE, a JSON-RPC object (a hash table)."
  (let ((id (gethash "id" message))
        (method (gethash "method" message))
        (params (gethash "params" message)))
    (pcase method
      ("initialize"
       (stand-in--result id '(:protocolVersion 1
                              :agentCapabilities (:loadSession :false
                                                  :promptCapabilities (:image :false :embeddedContext :false))
                              :authMethods [])))
      ("session/new"
       (stand-in--result id '(:sessionId "stand-in"
                              :modes (:currentModeId "default"
                                      :availableModes [(:id "default" :name "Default")]))))
      ("session/set_mode" (stand-in--result id '()))
      ("session/set_model" (stand-in--result id '()))
      ("session/prompt" (stand-in--prompt id params))
      ('nil nil)
      (_
       (when id
         (stand-in--send `(:jsonrpc "2.0" :id ,id
                           :error (:code -32601 :message ,(format "no method %s" method)))))))))

(defun stand-in-main ()
  "Serve ACP on stdin and stdout until stdin closes."
  (while t
    (let ((line (condition-case nil
                    (read-from-minibuffer "")
                  (error (kill-emacs 0)))))
      (unless (string-empty-p (string-trim line))
        (stand-in--handle (json-parse-string line :null-object nil :false-object nil))))))

;;; stand-in.el ends here
