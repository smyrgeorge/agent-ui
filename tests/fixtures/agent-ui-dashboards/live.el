;;; live.el --- a test dashboard, filled by its script -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :version 1
 :ui (:type "panel" :id "live"
      :children ((:type "table" :id "runs" :columns ("Run" "Status") :key "Run")
                 (:type "chart" :id "errors" :values ())
                 (:type "text" :id "where" :text "")))
 :every 0.2
 :start (lambda (_dashboard) (push 'start agent-ui-test-aud-calls))
 :stop (lambda (_dashboard) (push 'stop agent-ui-test-aud-calls))
 :fetch (lambda (dashboard)
          (push 'fetch agent-ui-test-aud-calls)
          (agent-ui-dashboard-update dashboard "where" :text default-directory)
          (agent-ui-dashboard-append dashboard "errors" :values (list 3))
          (agent-ui-dashboard-run
           dashboard '("printf" "[{\"run\":\"#812\",\"ok\":true},{\"run\":\"#811\",\"ok\":false}]")
           (lambda (runs)
             (agent-ui-dashboard-update
              dashboard "runs"
              :rows (mapcar (lambda (r) (list (alist-get 'run r) (if (alist-get 'ok r) "passed" "failed")))
                            runs))))))
