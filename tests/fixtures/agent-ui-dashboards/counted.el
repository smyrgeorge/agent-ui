;;; counted.el --- a test dashboard counting its fetches -*- lexical-binding: t; -*-
(agent-ui-dashboard
 :ui (:type "text" :id "t" :text "")
 :every 0.1
 :start (lambda (_dashboard) (push 'start agent-ui-test-aud-calls))
 :stop (lambda (_dashboard) (push 'stop agent-ui-test-aud-calls))
 :fetch (lambda (_dashboard) (push 'fetch agent-ui-test-aud-calls)))
