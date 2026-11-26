# Bugs in Agent UI

When Agent UI itself misbehaves (a component drawn wrong, an error, a property it lacks), the report concerns Agent
UI, never the project the agent is working on. You or the agent can write one, with the component and the environment
attached.

| Key or command | What it does |
|---|---|
| `b` (on a component in a canvas) | Report a bug about it: you're asked what's wrong and what you expected. |
| `M-x agent-ui-report-bug` | The same, from anywhere. |
| `agent-ui bug JSON` | The agent reports one (the MCP tool `bug`). |

## The report

- **The agent's report** is JSON with a `title` and `description` (both required), `expected`, `workaround`,
  `component` (the id of the component showing the problem) and `repro` (a component that shows it with neutral data).
  The agent is told to ask you first, then carry on with a workaround.

  ```json
  {"title": "table: a wide cell breaks the border",
   "description": "A cell wider than its column pushes the right border out of line.",
   "expected": "The cell wraps inside its column.",
   "component": "tests",
   "repro": {"type": "table", "columns": ["A", "B"], "rows": [["x", "a very long cell indeed"]]}}
  ```

- **What it carries:** its title (led by `Agent UI: `) and description, what was expected and the workaround used, the
  repro drawn as text, the component as shown (its JSON, its drawing, its error), and the environment: GUI or terminal,
  the pane's width, Emacs's version, Agent UI's directory and git commit (when it's a git checkout), and the session.

## Where it goes

By default, nothing is filed anywhere: `agent-ui-bug-function` is nil, so the report is given back, written in
Markdown, for you to file by hand at <https://github.com/smyrgeorge/agent-ui/issues>.

- From `b` or `M-x agent-ui-report-bug`, the report opens in a buffer, `*Agent UI: bug report*`, and is copied to the
  kill ring.
- From the agent, the reply is `{"ok": false, "error": ..., "report": ...}` and exits with status 1. The agent shows
  you the report.
- `agent-ui-bug-report-url` (by default, this repository's issues) is named in the message saying the bug wasn't filed.

### Filing into your own tracker

Set `agent-ui-bug-function` to file reports yourself. It's called with the title, the description (Markdown), Agent
UI's directory and whether to file it as new even if a similar bug is open (the agent's `"new": true`). It returns
`(:id ID :new BOOL :dir DIR)`: the issue's id, whether it's new (nil when the report was added to a similar open bug)
and the issues' directory. When it can't file (no tracker set up, a tool failing), it signals an error saying what's
missing; the report is then given back as above.

```elisp
(setq agent-ui-bug-function
      (lambda (title description _directory _new)
        (let ((file (expand-file-name "agent-ui-bugs.org" org-directory)))
          (with-temp-buffer
            (insert "* TODO " title "\n" description "\n")
            (append-to-file (point-min) (point-max) file))
          (list :id title :new t :dir (file-name-directory file)))))

(setq agent-ui-open-issue-function
      (lambda (_id directory)
        (find-file (expand-file-name "agent-ui-bugs.org" directory))))
```

Once a bug is filed:

- You see a message; `RET` right after it opens the issue, with `agent-ui-open-issue-function` (called with its id
  and directory).
- The agent's reply is `{"ok": true, "issue": ID, "new": true}`; when the report was added to a similar open bug,
  `new` is false and a `note` says so.
- `agent-ui-bug-filed-functions` run with the issue's id, its title, whether it's new and the issues' directory.
