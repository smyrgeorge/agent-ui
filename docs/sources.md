# Sources

The agent's tool calls run one after another, so a bar it updates itself stands still while it waits on a long
command. A component's `source` has Emacs follow what changes instead, and update the component while the agent goes on.

| Source | What Emacs follows |
|---|---|
| `{"command": "make -j8"}` | A command Emacs runs, in the agent's directory (or `dir`). Its output is kept in a log the `show` reply names (in `agent-ui-source-log-directory`). |
| `{"file": "build.log", "from": "end"}` | A file followed as it grows, looked at every `agent-ui-source-file-interval` seconds (0.5). `"from": "start"` (the default) reads what's already there; `"from": "end"` only what's added. When the file is truncated (written again), it's read from its start again. |
| `{"poll": "df -h /", "every": 10}` | A command run every so many seconds. |

## Rules

Rules turn the source's lines into changes to the component. A source has `rules`, a list of `{"match", "set",
"append"}`, or a single rule's `match`, `set` and `append` given directly.

- Each line that matches a rule's `match` applies its `set` (as an update) and its `append` (as an append).
- `match` is a regular expression as in `grep -E` or PCRE: groups, `\d`, `\s`, `\w`, `|`, `?`, `+`, `*`, `{n,m}`. In
  JSON, each backslash is doubled (`\\d`, `\\[`).
- In `set` and `append`, a string that is only `"$1"` is that group's value (a number if it reads as one), `"$0"` is
  the whole match, and `$N` inside other text is replaced.
- `\r` ends a line too, as progress meters use it.
- A chunk of output is one update, however many lines it has.

Instead of rules:

- `"tail": N` sets a `text` component's text to the last N lines.
- `"into": PROP` sets the property PROP to all of the output (a `diff`'s `diff`, from a poll of `git diff`), or to its
  last N lines with `tail`. A `log` follows a file with `"into": "lines"`.

When a command ends, its `done` patch applies if it exited with 0, its `failed` patch otherwise; `$code` in them is the
exit code. A `progress` bar marks itself done or failed when there's no such patch.

## Examples

A build's progress, from ninja's `[3/12] compiling parser.c` lines:

```json
{"id": "build", "type": "progress", "title": "Build", "max": 1,
 "source": {"command": "ninja -C build", "match": "^\\[(\\d+)/(\\d+)\\] (.*)$",
            "set": {"value": "$1", "max": "$2", "label": "$3"}}}
```

Tests filling a table as they run, a row per test by its key:

```json
{"id": "tests", "type": "table", "title": "Tests", "columns": ["Test", "Result"], "key": "Test",
 "source": {"command": "cargo test 2>&1",
            "rules": [{"match": "^test (\\S+) \\.\\.\\. (ok|FAILED|ignored)$",
                       "append": {"rows": [["$1", "$2"]]}}],
            "failed": {"title": "Tests: failed (exit $code)"}}}
```

The last lines of a server's log:

```json
{"id": "log", "type": "text", "title": "Server log", "text": "",
 "source": {"file": "server.log", "from": "end", "tail": 8}}
```

A process's memory, polled every 5 seconds, as a live chart:

```json
{"id": "mem", "type": "chart", "title": "Memory", "unit": "MB", "window": 60, "values": [],
 "source": {"poll": "ps -o rss= -p 4242", "every": 5, "match": "(\\d+)", "append": {"values": ["$1"]}}}
```

The work tree's changes, kept up to date:

```json
{"id": "changes", "type": "diff", "title": "Changes",
 "source": {"poll": "git diff", "every": 5, "into": "diff"}}
```

## How a source runs

- `agent-ui list` gives each source's state: whether it's running, its exit code, how many lines it read, its log. It
  also gives the error of a change the component refused (a value that isn't a number, say), or why the source couldn't
  run.
- When its `dir` is missing, or the command can't start, the component is shown without it, and `show`'s reply says so.
- A source stops when its component is removed (or closes by itself, finished) or shown again, or its canvas is closed.
  A command still running is killed and its log deleted. One that ended keeps its log, for the agent to read, until its
  canvas is closed.
- An update can't change a source; showing the component again does.
- A canvas that comes back with its resumed session doesn't start its sources again, so a command isn't run twice.
- A project panel's sources are its code: they don't start until you let the panel run
  ([Project panels](panels.md#its-code)).
