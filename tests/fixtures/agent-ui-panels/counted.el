;;; counted.el --- a test panel counting its fetches -*- lexical-binding: t; -*-
(agent-ui-panel
 :ui (:type "text" :id "t" :text "")
 :every 0.1
 :start (lambda (_panel) (push 'start agent-ui-test-aup-calls))
 :stop (lambda (_panel) (push 'stop agent-ui-test-aup-calls))
 :fetch (lambda (_panel) (push 'fetch agent-ui-test-aup-calls)))
