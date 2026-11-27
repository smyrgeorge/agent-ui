;;; frozen.el --- a test dashboard whose fetch waits itself -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :text "")
 :fetch (lambda (_dashboard) (sleep-for 0.25)))
