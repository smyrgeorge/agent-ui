;;; flaky-component.el --- a test dashboard whose query fails until a file is there -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :title "Deploy" :text "")
 :every 0.2
 :fetch (lambda (dashboard)
          (agent-ui-dashboard-run dashboard '("sh" "-c" "test -f ok || { echo 'no ok yet' >&2; exit 1; }")
                              (lambda (_) (agent-ui-dashboard-update dashboard "t" :text "ok"))
                              :component "t")))
