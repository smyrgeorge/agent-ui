;;; sourced.el --- a test dashboard with a source and a script -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "panel" :id "p"
      :children ((:type "text" :id "log" :text "" :source (:poll "echo hi" :every 60 :tail 1))))
 :fetch (lambda (_dashboard) (push 'fetch agent-ui-test-aud-calls)))
