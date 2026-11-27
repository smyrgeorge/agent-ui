;;; independent.el --- a test dashboard: a slow query and a fast one -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "panel" :id "p"
      :children ((:type "text" :id "slow" :title "Slow" :text "")
                 (:type "text" :id "fast" :title "Fast" :text "")))
 :every 0.1
 :fetch (lambda (dashboard)
          (agent-ui-dashboard-run dashboard '("sh" "-c" "sleep 1.5; echo slow done")
                              (lambda (out) (push 'slow agent-ui-test-aud-calls)
                                (agent-ui-dashboard-update dashboard "slow" :text (string-trim out)))
                              :component "slow")
          (agent-ui-dashboard-run dashboard '("printf" "fast")
                              (lambda (out) (push 'fast agent-ui-test-aud-calls)
                                (agent-ui-dashboard-update dashboard "fast" :text out))
                              :component "fast")))
