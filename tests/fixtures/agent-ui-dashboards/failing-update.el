;;; failing-update.el --- a test dashboard changing a component it hasn't -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :text "")
 :fetch (lambda (dashboard) (agent-ui-dashboard-update dashboard "nope" :text "x")))
