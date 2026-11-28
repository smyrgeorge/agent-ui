# Emacs Lisp interface

Everything the command line does can be done from Lisp, so your own code (a command, a hook, a script run by
`emacsclient`) can show components too. A component here is a plist, as `json-parse-string` makes it with
`:object-type 'plist`, such as `(:type "progress" :id "build" :value 3 :max 12)`.

## Operations

| Function | What it does |
|---|---|
| `(agent-ui-show COMPONENT &key canvas section)` | Shows COMPONENT; one with its id already there is replaced in place. Returns the id (made if there's none). |
| `(agent-ui-update ID PATCH &key canvas section)` | Changes some of a component's properties. A property nil goes back to its default. |
| `(agent-ui-append ID PATCH &key canvas section)` | Adds to a component's lists. |
| `(agent-ui-remove ID &key canvas section)` | Removes a component. |
| `(agent-ui-clear &key canvas section)` | Removes every component (and, for a whole canvas, its sections). |
| `(agent-ui-set-title TITLE &key canvas)` | Gives the canvas TITLE, for its bar and its tab; nil or `""` takes it away. Returns the title it has now. |
| `(agent-ui-canvas-title &optional BUFFER)` | The canvas's title: its lone panel's, else the one given it; nil if none. |
| `(agent-ui-get ID &key canvas section)` | A component's properties now, a plist. |
| `(agent-ui-components &key canvas section)` | The components in order, as `(:id ID :type TYPE)`. |
| `(agent-ui-reveal ID &optional canvas)` | Brings a component into view, unfolding its section. |
| `(agent-ui-render COMPONENT CTX)` | Draws a component as text, nothing shown; CTX comes from `(agent-ui-context :width 80)`. |

CANVAS is a canvas buffer or a canvas's name; it defaults to `agent-ui-default-canvas`. A session's canvas is named
after its session's buffer, and its other canvases `SESSION / NAME`. A wrong component or change signals
`agent-ui-error`, whose message is the one the command line would reply with.

```elisp
(agent-ui-show '(:id "build" :type "progress" :title "Build" :max 12) :canvas "mine")
(agent-ui-update "build" '(:value 5 :label "linking") :canvas "mine")
```

## Sections

A canvas can be divided into sections, from Lisp. Each section starts with its divider, a rule across the window with
its title, its state's mark and a few words:

```text
▾ build ● 3m ─────────────────────────────────
Steps …
▸ review ◆ · 2 hidden ────────────────────────
▾ merge ✓ ────────────────────────────────────
```

The canvas's own components come first, then each section's, in order. A section's components are its own, and so
are their ids: `plan` in one section isn't `plan` in another.

| Key (on a divider) | What it does |
|---|---|
| `TAB` or a click | Fold its section, or unfold it. |
| `RET` | Call the section's `:open` function; without one, fold it. |

| Function | What it does |
|---|---|
| `(agent-ui-section CANVAS NAME &key title state note folded open empty after)` | Makes section NAME (letters, digits, `_ . -`), at the end or after section AFTER. Called again, it changes only what's given. OPEN is a function `RET` on its divider calls; EMPTY a line shown while it holds nothing. |
| `(agent-ui-show COMPONENT :canvas CANVAS :section NAME)` | Shows a component in it. The other operations take `:section` too. |
| `(agent-ui-remove-section CANVAS NAME)` | Removes it, with its components. |
| `(agent-ui-sections CANVAS)` | Its sections: name, title, state, note, folded, the canvas it hosts, how many components. |
| `(agent-ui-host NAME CANVAS SECTION)` | Shows canvas NAME (a session's) in SECTION from now on. |
| `(agent-ui-unhost NAME &optional KEEP)` | Gives NAME its own canvas back, its components in the section removed; with KEEP, they stay there as the section's own. |

- **States:** `running` `●` (glowing), `needs-you` `◆`, `waiting` `○`, `paused` `‖`, `done` `✓`, `failed` `✗`, or
  none. Hovering the mark shows its words.
- **Folding.** A folded section's divider says how many components it hides. What comes in meanwhile stays hidden,
  except a question: it unfolds its section and comes into view.
- **Clearing** a canvas removes its sections too; clearing a section removes its components only. A canvas with a
  section isn't empty, so it stays open.
- **A session's canvas in a section** (`agent-ui-host`): everything the session shows goes there, its other canvases'
  components too. It has no buffer or window of its own; the canvases it had are emptied into the section and closed.
  - Its `list`, `get` and `clear` see that section only. Its links open the canvas it's in, on it.
  - Its buttons act in its session, and its questions wait for it, as on its own canvas.
  - When the session is killed, its components there go, and the section stays. When the section is removed (or
    `agent-ui-unhost` is called), its next component opens its own canvas again.
  - What it shows there isn't kept with the session.

## A canvas that answers itself

A canvas of no session can handle its buttons and questions itself. Set `agent-ui-answer-function` (buffer-local) in
it to a function called with each action's PROMPT, whether it's to be submitted, and its component's key
(`SECTION/ID` in a section), instead of putting the prompt into a session. An action's `help` is then shown when its
button is hovered, as `RET: HELP`. A section hosting a session's canvas still answers to that session.

| Function | What it does |
|---|---|
| `(agent-ui-key-section KEY)`, `(agent-ui-key-id KEY)` | The section (nil: the canvas's own) and the id of the component an answer's KEY names. |
| `(agent-ui-canvas-asks-p CANVAS)` | Whether a question waits in CANVAS, in one of its sections too. |
| `(agent-ui-canvas-session CANVAS)` | The session buffer whose canvas CANVAS is, or nil. |

`agent-ui-closes-with`, set (buffer-local) to the key of one of the canvas's components, closes the whole canvas,
sections too, when that component's countdown ends ([Finished components close](canvas.md#finished-components-close)).

## Trust

A project's code runs as you: its dashboards, and what a package built on Agent UI runs from it (agent-workflow's
workflows). Before it first runs, you're asked; a project you trust runs all of its code unasked, whatever its files
become. It's remembered by its root's true name in `agent-ui-trust-file`; an agent's worktree shares its project's
trust through `agent-ui-trust-root-function`.

| Function | What it does |
|---|---|
| `(agent-ui-project-trusted-p ROOT)` | Whether the project at ROOT is trusted. |
| `(agent-ui-trust-project ROOT)` | Trusts it. `M-x agent-ui-trust-project`: the current project's, confirmed with `yes`. |
| `(agent-ui-forget-project ROOT)` | Stops trusting it. `M-x agent-ui-forget-project`: the trusted ones to pick from. |
| `(agent-ui-trusted-projects)` | The trusted projects, `((ROOT . TIME) ...)`, the latest first. |

## Helpers

What Agent UI draws with, for code of your own that shows things beside it:

| Function | What it does |
|---|---|
| `(agent-ui-truncate STRING WIDTH)`, `(agent-ui-pad STRING WIDTH &optional ALIGN)` | Fitted to a width in columns, cut with `…`. |
| `(agent-ui-format-duration SECONDS)`, `(agent-ui-format-compact N)` | `4m 05s`; `12.3k`. |
| `(agent-ui-time-seconds STRING)` | An ISO 8601 or RFC 822 date and time as epoch seconds, or nil. |
| `(agent-ui-log-level TEXT)` | A line's level as a log finds it by its words: `error`, `warning`, `info`, `debug` or nil. |
| `(agent-ui-to-json VALUE)`, `(agent-ui-parse-json STRING)` | Lisp as `json-serialize` takes it (plists objects, lists arrays, nil null, an alist of numbers an object), and back (false as `:false`). |

## Hooks

| Hook | Called |
|---|---|
| `agent-ui-shown-functions` | In a canvas, with a component's id and the component, once it's shown (new or again). |
| `agent-ui-removed-functions` | In a canvas, with a component's id once it's gone (removed, or its canvas killed). |
| `agent-ui-changed-hook` | In a canvas, when its components change: shown, updated, appended to, removed, cleared. |
| `agent-ui-title-changed-hook` | In a canvas, once its title changed: its lone panel's, or the one given it. |
| `agent-ui-question-waiting-functions` | With the session's buffer, the canvas and the question's id, when a turn ends with a question waiting. |
| `agent-ui-dashboard-open-hook` | In a project dashboard's canvas, once it has opened (not when it's only shown again). |
| `agent-ui-bug-filed-functions` | With the issue's id, its title, whether it's new and the issues' directory, once a bug is filed. |
| `agent-ui-staged-functions` | With a type's name, once the agent staged it. |
| `agent-ui-kept-functions` | With a type's name and its file, once you kept it. |
| `agent-ui-type-reviewed-functions` | With a type's name, what to tell the agent that made it, and its session's canvas (or nil), once you kept or discarded it, or it couldn't be kept. |

For example, a message when a question is left waiting (swap in your notification tool of choice):

```elisp
(add-hook 'agent-ui-question-waiting-functions
          (lambda (session _canvas _id)
            (message "Agent UI: %s asks you something" (buffer-name session))))
```
