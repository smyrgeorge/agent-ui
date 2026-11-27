;;; refreshed.el --- a test dashboard whose query is quick, slow once a file is there -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :title "Orders" :text "")
 :fetch (lambda (dashboard)
          (agent-ui-dashboard-run dashboard '("sh" "-c" "if test -f slow; then sleep 2; fi; echo orders")
                              (lambda (out) (push 'done agent-ui-test-aud-calls)
                                (agent-ui-dashboard-update dashboard "t" :text (string-trim out)))
                              :component "t")))
