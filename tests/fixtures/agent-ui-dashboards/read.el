;;; read.el --- a test dashboard read by an agent: a short query each fetch -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :text "")
 :every 1
 :fetch (lambda (dashboard)
          (push 'fetch agent-ui-test-aud-calls)
          (agent-ui-dashboard-run dashboard '("sh" "-c" "sleep 0.3; echo 42")
                              (lambda (out)
                                (push 'done agent-ui-test-aud-calls)
                                (agent-ui-dashboard-update dashboard "t" :text (string-trim out)))
                              :component "t")))
