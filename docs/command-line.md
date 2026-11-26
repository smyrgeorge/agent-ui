# The command line

The agent drives Agent UI with one command, `bin/agent-ui`, in the package's directory (the option
`agent-ui-command`). The text the agent is told gives it the command's full path. Each call is one quick round trip
to Emacs, and the reply is JSON on stdout. The same operations are also [MCP tools](#mcp-tools).

## Operations

```sh
agent-ui show '{"id":"build","type":"progress","title":"Build","max":12}'
agent-ui update build '{"value":5,"label":"linking"}'
agent-ui append tests '{"rows":[["lexer","passed","0.4s"]]}'
agent-ui remove build
agent-ui clear                 # remove every component of the canvas
agent-ui list                  # the canvas's components: ids, types, their sources' state
agent-ui get [ID] [--changed]  # what it shows, as data
agent-ui types [TYPE]          # the catalog: each type, its properties, an example
agent-ui batch < ops.json      # several operations in one trip to Emacs
agent-ui render '{"type":...}' # a component drawn as text, nothing shown
agent-ui render --ansi '{...}' # the same, in its colours (24-bit ANSI), to print in a terminal
agent-ui snapshot build        # the component as an image, for the agent's reply
agent-ui define dial.el        # a type of the agent's own
agent-ui bug < bug.json        # a bug in Agent UI itself
agent-ui panels                # the project's panels, and which are open
agent-ui open service          # one of them opened for the user
agent-ui check service         # a panel's file checked, nothing run
```

| Operation | Arguments | What it does |
|---|---|---|
| `show` | `[JSON]` | Shows a component. One whose id is already on the canvas is replaced in place. |
| `update` | `ID [JSON]` | Changes some of a component's properties. |
| `append` | `ID [JSON]` | Adds to a component's lists. |
| `remove` | `ID` | Removes a component. |
| `clear` | | Removes every component of the canvas. |
| `list` | | The canvas's components: their ids, types and sources' state. |
| `get` | `[ID] [--changed]` | What the canvas shows, as data ([below](#reading-the-canvas-get)). |
| `types` | `[TYPE]` | The component types, each with its properties and an example. |
| `batch` | `[JSON]` | Several operations at once ([below](#batches)). |
| `render` | `[--ansi] [JSON]` | A component drawn as text, as the canvas would draw it, without showing it. |
| `snapshot` | `ID` | The component as an SVG image, with a Markdown link for a reply ([The canvas](canvas.md#in-the-conversation)). |
| `define` | `[FILE]` | Stages a type of the agent's own, from FILE or stdin ([Custom types](custom-types.md)). |
| `bug` | `[JSON]` | Reports a bug in Agent UI itself ([Bugs in Agent UI](bugs.md)). |
| `panels` | | The project's panels: `{"panels": [{"name", "open"}]}` ([Project panels](panels.md)). |
| `open` | `NAME` | Opens one of the project's panels in your Emacs. |
| `check` | `NAME` | Checks a panel's file without running anything. |

`agent-ui --help` prints the command's own summary.

## JSON in and out

JSON comes as the last argument, or on stdin when there's none. The reply is always JSON on stdout, errors included:

| Reply | Meaning |
|---|---|
| `{"ok": true, "id": "build"}` | Done. |
| `{"ok": false, "error": "progress: unknown property \"total\"; its properties: value, max, label, unit, status, started, times, pie"}` | Not done, and why. |

The JSON is written to a temporary file that Emacs reads, so it's never quoted into Lisp, whatever it holds.

`show`'s reply also has the component's `link` (`agent-ui://canvas/NAME#ID`, see
[In the conversation](canvas.md#in-the-conversation)). When the component has a command [source](sources.md), it has the
`log` where the command's output is kept, and when its source couldn't start, the `source` with its error.

### Exit statuses

| Status | Meaning |
|---|---|
| `0` | Done. |
| `1` | Not done; the reply says why. |
| `2` | A wrong use: an unknown operation, a missing or extra argument. |
| `3` | No Emacs to talk to: no server answered, or Emacs runs without Agent UI loaded. |

## A component

```json
{"id": "build", "type": "progress", "title": "Build", "value": 3, "max": 12, "label": "compiling parser.c"}
```

| Property | What it is |
|---|---|
| `id` | A name the agent picks (letters, digits, `_ . -`), unique on its canvas. Without one, one is made and returned. |
| `type` | One of the [component types](components.md). |
| `title` | Optional, any type: a heading above the component, wrapped if it's too long. |
| `caption` | Optional, any type: a muted line under the title. |
| `source` | Optional, any type: a command, file or poll the component follows ([Sources](sources.md)). |
| `actions` | Optional, any type: buttons that put a prompt into the session's prompt ([Actions](canvas.md#actions)). |
| `close` | Optional, for `steps`, `todo` and `progress`: the seconds it stays once it finished well, or `false` to keep it ([Finished components close](canvas.md#finished-components-close)). |
| `with` | Optional, any type: the id of the question it's shown with. It goes when that question is answered ([A question waiting](canvas.md#a-question-waiting)). |
| `canvas` | Optional: the session's other canvas to show it on ([below](#which-canvas)). |
| anything else | The type's own properties. An unknown property is an error that lists the type's properties, so the agent learns them. |

A property of kind `file` is relative to the agent's directory, and kept by its full name.

### Updates and appends

- An **update** is partial: an object with the properties that change. It's merged into the component's properties
  shallowly, so a list given replaces the list. A property set to `null` goes back to its default. An update can't
  change a source; showing the component again does.
- An **append** adds to a component's lists (a table's `rows`, a chart's `values`, a checklist's `steps`) without
  sending them all again. Types say how their lists grow: in a table with a `key` column, a row whose key is already
  there replaces that row instead of adding one, so a row can go from `parser` *running* to `parser` *passed*. A step
  or a todo item with a name already there changes in place.

## Batches

A batch is an array of operations, each a flat object with its `op` and what that operation takes:

```json
[{"op": "show", "id": "build", "type": "progress", "max": 12},
 {"op": "update", "id": "build", "value": 3},
 {"op": "append", "id": "tests", "rows": [["lexer", "passed"]]},
 {"op": "remove", "id": "old"}]
```

The reply has each operation's result, in order: `{"ok": true, "results": [{"ok": true, "id": "build"}, ...]}`. Its
`ok` is false if any of them failed; the others are still done.

## Reading the canvas: get

`agent-ui get` returns what the canvas shows, as data: its components (or the one with ID) with their properties and
values. With `--changed`, it returns only the components changed since the agent's last read, and `removed`, the ids of
those gone since. It's how an agent reads what you changed (a todo item ticked, a form filled in) and how it reads a
project panel's data.

On a project panel (`--panel NAME`), the reply also says when the panel last fetched its data. A panel that was hidden,
with old data, is fetched first; the command waits for it, at most `AGENT_UI_WAIT` seconds (10 by default).

## Rendering and snapshots

- `agent-ui render JSON` draws a component as text at the canvas window's width (or `agent-ui-default-width` when the
  canvas isn't shown), without showing it: `{"ok": true, "text": "..."}`. It lets the agent see what a component looks
  like. With `--ansi`, the text has its colours as 24-bit ANSI escapes, to print in a terminal.
- `agent-ui snapshot ID` saves the component as it's drawn, without its buttons, as an SVG in the agent's
  `.agent-shell/images/`, and replies with `{"file": ..., "markdown": "![...](...)"}`. The agent puts the Markdown in
  its reply, and agent-shell shows the image inline ([The canvas](canvas.md#in-the-conversation)).

## Which canvas

- **The session's own.** agent-shell starts the agent with `AGENT_UI_SESSION` in its environment, naming its session
  (`agent-ui-mode` arranges this). The agent's shell inherits it, so the command finds its session's canvas,
  `Agent UI: SESSION`.
- **Without `AGENT_UI_SESSION`** (a session started before `agent-ui-mode` was on, an agent in a terminal), the command
  uses the session working in its directory or above it: the deepest one, then the most recently used. With no such
  session, it uses the canvas named by `agent-ui-default-canvas` (`default`).
- **Another canvas of the session.** `--canvas NAME`, or `"canvas": "NAME"` in the JSON (a component's, an update's, a
  batch operation's), picks the session's other canvas `Agent UI: SESSION / NAME`. It's a view of its own beside the
  session's canvas, with its own components and ids. A name has letters, digits, spaces and `_ . -`, up to 40
  characters. Questions go on `--canvas ask` by convention.
- **A project panel.** `--panel NAME` works on the project's open panel NAME instead ([Project panels](panels.md)).

`--canvas` and `--panel` can go anywhere on the command line and work with any operation.

## Environment

| Variable | What it does |
|---|---|
| `AGENT_UI_SESSION` | The session whose canvas the command works on. Set by agent-shell for its agents while `agent-ui-mode` is on. |
| `EMACSCLIENT` | The client the command runs (default `emacsclient`). Set it when `emacsclient` isn't on the agent's `PATH`, for example with `(setenv "EMACSCLIENT" "/path/to/emacsclient")` in Emacs before starting sessions. |
| `EMACS_SOCKET_NAME` | The server `emacsclient` talks to, when it isn't the default one. |
| `AGENT_UI_WAIT` | The most seconds `get` waits for a hidden panel's fetch (default 10). |
| `AGENT_UI_DIR` | For the MCP server: the agent's directory (set by `agent-ui-mode` when it registers the server). |

Emacs answers each request through its server, so it must run one (`M-x server-start`). Without one, the command fails
with exit status 3 and says so; it says so too when Emacs runs but Agent UI isn't loaded.

## MCP tools

Each agent-shell session started while `agent-ui-mode` and `agent-ui-mcp` are on gets the same operations as MCP
tools, with their schemas. The server is `agent-ui-mcp.el`, run by a batch Emacs:

```sh
emacs --batch -Q -l agent-ui-mcp.el -f agent-ui-mcp-main
```

It speaks MCP over stdio and does each call through `bin/agent-ui`, so replies and errors are the command line's.

| Tool | Arguments |
|---|---|
| `show` | `component` (its description lists the types) |
| `update`, `append` | `id`, `patch` |
| `remove` | `id` |
| `clear`, `list` | none |
| `get` | `id`, `changed` |
| `types` | `type` |
| `render` | `component` |
| `snapshot` | `id` |
| `batch` | `operations` |
| `bug` | `title`, `description`, `expected`, `workaround`, `component`, `repro`, `new` |
| `panels` | none |
| `open`, `check` | `name` |
| `define` | `code` |

Every tool except `types`, `define`, `check`, `panels` and `open` also takes `canvas` (the session's other canvas)
and `panel` (an open project panel), as `--canvas` and `--panel` do. The server's instructions, which the agent reads
too, say what the system prompt says: information goes on the canvas, questions there beyond a quick one, and Agent
UI's own bugs are reported with the `bug` tool.
