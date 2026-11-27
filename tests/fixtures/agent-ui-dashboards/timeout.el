;;; timeout.el --- a test dashboard whose query never ends -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :title "Orders" :text "")
 :fetch (lambda (dashboard) (agent-ui-dashboard-run dashboard '("sleep" "30") #'ignore :component "t" :timeout 0.3)))
