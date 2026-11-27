;;; slow.el --- a test dashboard whose command runs long -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :text "")
 :fetch (lambda (dashboard) (agent-ui-dashboard-run dashboard '("sleep" "30") #'ignore)))
