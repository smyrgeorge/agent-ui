;;; checkdoc-batch.el --- Run checkdoc on files, fail on any finding  -*- lexical-binding: t -*-
(require 'checkdoc)
(setq checkdoc-diagnostic-buffer "*warn*")
;; Its guess at a non-imperative verb flags any verb in the first sentence
;; ("Return the answer as the agent reads it"); off by default from Emacs 31.
(setq checkdoc-verb-check-experimental-flag nil)
(let ((files command-line-args-left) (n 0))
  (setq command-line-args-left nil)
  ;; Each file loaded first, as melpazoid has them (installed): checkdoc then
  ;; knows what's a symbol (`agent-shell') and which macros take a docstring
  ;; (`agent-ui-define'), which it can't tell from the text alone.  agent-shell
  ;; too, which Agent UI loads only once a session starts.
  (require 'agent-shell)
  (dolist (f files)
    (require (intern (file-name-base f)) (expand-file-name f)))
  (dolist (f files)
    (with-current-buffer (find-file-noselect f)
      (let ((checkdoc-create-error-function
             (lambda (text start _end &optional _unfixable)
               (setq n (1+ n))
               (princ (format "%s:%d: %s\n" f (line-number-at-pos start) text))
               nil)))
        (condition-case err (checkdoc-current-buffer t)
          (error (princ (format "%s: ERROR %S\n" f err)))))))
  (kill-emacs (if (> n 0) 1 0)))
