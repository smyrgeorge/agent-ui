;;; waiting.el --- a test dashboard whose fetch's command runs a while -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :text "")
 :every 0.1
 :fetch (lambda (dashboard)
          (push 'fetch agent-ui-test-aud-calls)
          (agent-ui-dashboard-run dashboard '("sleep" "0.6") (lambda (_) (push 'done agent-ui-test-aud-calls)))))
