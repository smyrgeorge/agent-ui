;;; failing-run.el --- a test dashboard whose command fails -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :text "")
 :fetch (lambda (dashboard)
          (agent-ui-dashboard-run dashboard '("sh" "-c" "echo boom >&2; exit 3")
                              (lambda (_out) (push 'called agent-ui-test-aud-calls)))))
