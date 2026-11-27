# The canvas

A canvas is a read-only buffer, `Agent UI: SESSION`, in `agent-ui-canvas-mode`. It belongs to an agent-shell session
and holds the components the agent shows, in the order they were shown, each redrawn in place when it changes. It opens
in its session's pane ([below](#in-the-sessions-pane)) the first time a component is shown, without taking the focus.

## Keys

The canvas's keys act on the component at point. They're plain Emacs keys in `agent-ui-canvas-mode-map`; if you use
Evil, bind the ones you want in its normal state (or start canvases in Emacs state, see
[Getting started](getting-started.md#setting-it-up)).

| Key | Command | What it does |
|---|---|---|
| `q` | `agent-ui-quit` | Close the canvas for good, with its components. |
| `g` | `agent-ui-canvas-redraw` | Redraw it. |
| `RET` or a click | `agent-ui-button-press` | Press the button at point, or open what the component shows (a file, an image, a page). |
| `a` | `agent-ui-send-component` | Put the component into the session's prompt, as text ([In the conversation](#in-the-conversation)). |
| `b` | `agent-ui-report-bug` | Report a bug in Agent UI about the component ([Bugs in Agent UI](bugs.md)). |
| `c` | `agent-ui-comment` | On a line of code or a diff, or a region's lines: write a review comment under it. On a comment: edit it. |
| `d` | `agent-ui-uncomment` | On a comment: remove it. |
| `s` | `agent-ui-table-sort` | On a table's column: sort the table by it. Again: the other way. |
| `S` | `agent-ui-save-dashboard` | Save the component as one of the project's dashboards ([Project dashboards](dashboards.md)). |
| `R` | `agent-ui-review` | Review the types the agent made ([Custom types](custom-types.md#types-the-agent-makes)). |
| `E` | `agent-ui-export-pdf` | Save what the canvas shows now as a PDF ([below](#exporting-a-pdf)). |
| `u` | `agent-ui-pane-toggle` | Hide Agent UI in the session's pane, or show it again. |
| `r` | `agent-ui-dashboard-reload` | In a project dashboard: read its file again and run it anew. |
| `x`, `e` | `agent-ui-drop-item`, `agent-ui-edit-item` | In a question: drop or reword a plan's step, reject a diff's hunk. |
| `M-<up>`, `M-<down>` (or `K`, `J`) | `agent-ui-move-item-up`, `agent-ui-move-item-down` | In a `rank`: move the item at point. |

Components that ask have a few keys of their own, listed in [Components](components.md#keys-for-questions), and so do
[section dividers](lisp.md#sections).

## How it behaves

- **Closing it.** `q` closes it for good, with its components, and kills its buffer. A session's saved components come
  back when the session is resumed; a component the agent updates after you closed the canvas is gone.
- **Emptied.** A canvas cleared, or whose last component is removed, hides. It closes with its session, its buffer
  killed.
- **Without a session** (an agent in a terminal, the command run from a plain shell), a canvas opens in a window of its
  own, through `agent-ui-display-function`.
- **Other canvases.** Besides its own canvas, a session may have others, named (`--canvas tests` on the command line,
  `"canvas": "tests"` in the JSON, the MCP tools' `canvas`). `Agent UI: SESSION / tests` has its own components and ids,
  and is a view of its own in the session's pane. They close with the session, and are kept and come back with it.
  An emptied one closes until a component is shown there again.
- **Terminal or GUI.** The frame showing the canvas decides how it's drawn. A graphical frame draws some components
  better (charts and graphs as SVG) and has some of its own (images, diagrams, typeset math). A type without a
  graphical drawing draws as text in both.
- **Its top line** is empty, and the cursor is there when the canvas opens. The first component can then start with an
  image (stat tiles, a chart, a panel), and the cursor on an image frames the whole of it.
- **Redrawing** a component leaves the cursor and each window's scroll where they were.
- **Width.** Components fit the canvas window's width. They're drawn again when the window changes size or the font's
  size changes. While the canvas is in no window, they're drawn at `agent-ui-default-width` columns.
- **Animated components** (a spinner, a bar without an end) are redrawn only while one is shown in a window: in none, the
  animation stops until the canvas is shown again. Each frame redraws only what moves: a panel's other children and a
  step's unfolded body stay as last drawn, and a countdown or a running timeline is drawn again only when what it shows
  changes (once a second; an hour past a countdown's end, once a minute). The spinner is a dot, `●`, whose colour glows
  brighter and dimmer (`agent-ui-spinner-frames`, `agent-ui-spinner-pulse`).
- **Glyphs.** In a graphical frame, a character the default font lacks (`✎`, `⏵`) comes from another font, often
  wider or narrower than a column and taller than a line. The canvas draws it as large as a line holds and adjusts the
  space beside it to match, so borders and the `│` between columns stay in place and every line keeps the same height.
- **Limits** keep drawing quick, since it runs in Emacs's only thread. A table's rows, a chart's values and a
  component's text are capped (`agent-ui-max-rows`, `agent-ui-max-chars`), with a line saying what was left out. A
  canvas holds at most `agent-ui-max-components` components.
- **Updates are batched.** An update redraws its component `agent-ui-redraw-delay` seconds later, and the updates within
  that time are drawn together, so a stream of updates costs a few redraws.
- **A drawing that fails** shows its error in the component's place, in the error face. The canvas and its other
  components go on.

## In the session's pane

A session's Agent UI is shown in its session's pane: the conversation on top, Agent UI at the bottom. It's as tall as
what it shows needs, with no empty lines under its views, and takes at most half the pane (`agent-ui-pane-max-share`).
It grows and shrinks as its views and their components come and go; a height you give it stays until what it shows
needs another.

| Key | What it does |
|---|---|
| `q` (in a view) | Close it for good; the other views are laid out again. |
| Closing a view's window (`C-x 0`) | Hide it until the agent shows something on it again (an update doesn't count). |
| `u` (in a view), or `M-x agent-ui-pane-toggle` (in the session too) | Hide Agent UI for the session, or show it again. |

- **Views.** The session's canvas and its other canvases (`ask`, `tests`, and so on) are views. They're laid out to use
  the room: in columns, each a stack of views, as many columns as fit.
- A view needs `agent-ui-grid-min-width` columns (40), or `agent-ui-grid-wide-width` (80) when it shows one of
  `agent-ui-grid-wide-types`: a diff, code, a graph, a Mermaid diagram, a heatmap, a timeline or a comparison. Short
  views stack beside a tall one, and the session's own canvas comes first.
- When the views need more than Agent UI's share of the pane, the layout that hides the fewest of their lines wins.
- When the pane is too narrow for every view (a wide one in a pane under 80 columns), the views that fit are shown.
  The others come back once the pane has room for them.
- Views are laid out again when they open or close, not while the agent updates them, so nothing moves around while it
  works. They're also laid out again when the session's pane changes size: a window beside it opened or closed, a
  split, the frame resized, a border dragged (once you let go).
- Each view scrolls and is selected on its own, with a bar over it naming it. The session's own canvas reads
  `Canvas`; a canvas showing a single panel with a title has that title there instead of drawing it over the panel.
- Under the views is Agent UI's own bar: `Agent UI · 2 views` on the left and `agent-ui-pane-keys` (`q close`) on the
  right. With `agent-ui-pane-mode-line` set to t, the views at the bottom keep their buffer's own mode line instead.
  The session's mode line stays under the conversation.
- Closing the conversation's window closes its views.
- While the session is in no window (another buffer in its pane, another tab or workspace), Agent UI waits and shows
  with the session.
- While hidden, Agent UI stays hidden as the agent shows things. A question shows it again, and the session too if
  it's in no window.
- When the pane is too short for both (`agent-ui-pane-min-lines`, 6 lines each), a view opens in a window of its own.

## Finished components close

A `steps`, `todo` or `progress` that finished well closes itself `agent-ui-close-finished` seconds later (10 by
default). Finished well means every step done or skipped, every item ticked, or the bar at its end.

- A line under it counts down, with a **Keep** button. It says "closing" when it's the canvas's last component and the
  canvas goes with it, or "removed" when the canvas stays. The view closes with its last component.
- One that failed stays. A change in the meantime starts the countdown again, or stops it.
- The component's `"close"` decides for it: seconds, or `false` to keep it.
- A project dashboard never closes.
- A component that comes back with its resumed session stays, as if kept, until it changes.

## Actions

Any component can have `actions`: buttons under it. Each has a `label` and the `prompt` it puts into the session's
prompt when pressed, for you to read and send.

```json
{"id": "result", "type": "text", "text": "2 tests failed.", "face": "error",
 "actions": [{"label": "Fix them", "prompt": "Fix the 2 failing tests."},
             {"label": "Show the log", "prompt": "Show me the test log.", "submit": true}]}
```

```text
2 tests failed.
⏵ Fix them   ⏵ Show the log
```

- `RET` or a click on a button puts its prompt into the session's prompt. With `"submit": true`, the prompt is sent at
  once.
- Hovering a button shows the prompt it puts there or sends. One with a `help` shows that instead.
- A component has at most 6 actions, checked when it's shown.
- A question's buttons (a choice's, a comparison's, a rank's) sit beside its Answer button, on its row, until it's
  answered.
- While the agent works, a prompt sent at once is queued until it's done. A prompt put into the prompt is offered to
  queue, and you can change it first.
- A snapshot leaves the buttons out; they stay on the canvas.

## A question waiting

The agent asks on a canvas of its own, `--canvas ask` (`Agent UI: SESSION / ask`), a view in the session's pane. The
types that ask, and their keys, are in [Components](components.md#components-that-ask). A question takes the focus
when it shows, and goes once you answer it.

| Key | What it does |
|---|---|
| `M-x agent-ui-goto-question` | Go to a question waiting: in a session or a canvas, that session's; elsewhere, any session's. Its view is selected, with the cursor on the question. |

- **Shown, it takes the focus.** Its view is selected, with the cursor on the question, once you stop typing for a
  moment (`agent-ui-focus-questions-delay`, 1 second), so what you type in the session isn't taken by the canvas's
  keys. If you've typed since it showed, it waits for a longer pause (`agent-ui-focus-questions-typing-delay`, 5
  seconds), so a pause in your typing elsewhere doesn't hand your next keys to it. Set `agent-ui-focus-questions` to nil to keep the focus where it is. Questions that come back with a resumed
  session don't take it.
- **Answered, it goes.** Your answer goes straight to the agent, sent at once: there's no Enter to press, and nothing
  waits in the prompt. While the agent still works, the answer is queued and sent once it's done.
- Once answered, the question leaves its canvas, with the components shown with it (those whose `with` is its id). On
  the session's ask canvas, once no other question waits there, everything on it goes. Set `agent-ui-close-answered`
  to nil to leave answered questions where they are.
- A canvas left empty is closed and its buffer killed, and the cursor goes back to the session.
- A plan you approved goes too. The agent shows its steps again as an ordinary checklist, ticked as it works.

If the agent's turn ends while a question on its session's canvases is still unanswered, you see it:

- The canvas's view is shown (if it was closed) and scrolled to the question, the cursor on it. The focus stays where
  it is.
- The session's mode line says `❓ question waiting` until it's answered or its canvas is closed.
- `agent-ui-question-waiting-functions` run, for a desktop notification, say ([Customization](customization.md#hooks)).
- Each question is brought up once, at the end of the first turn it's waiting at.

A question is a `choice`, a `confirm`, a `form`, a `rank`, a `slider` to set, a `compare`, a plan to approve, hunks to
accept, rows to pick in a `table` or `files`, chips to pick in `tags`, or any of them as a panel's child.

## Review comments

On a `code` or `diff` component, `c` on a line (or with a region, on its lines) writes a review comment, shown under
them. `c` on a comment edits it, and `d` removes it. **Send the review** sends all your comments, with their places,
to the agent at once.

## Kept with the session

A session's canvas is saved as it changes, and comes back when the session is resumed.

- It's saved `agent-ui-persist-delay` seconds (1) after it changes, the changes together, as its components' JSON. It's
  kept in the session's `.agent-shell/agent-ui/` (`agent-ui-persist-directory`), named by its ACP session id, beside
  agent-shell's transcripts. A save still pending when Emacs exits is done then.
- When a session starts with that id (resumed when agent-shell asks, or restarted), its canvas comes back as it was, a
  progress bar's times too.
- Its components' sources aren't started again, so a command isn't run twice.
- Closing a canvas, or its session, leaves what's saved. Clearing it saves it empty.
- Its other canvases are kept beside it (`ID@tests.json`) and come back with it.
- A component of a type that's gone since (a discarded type) is left out.

## In the conversation

agent-shell owns its buffer's text, so a component isn't put there. It goes there in the ways agent-shell already has.

- **From the agent:** `agent-ui snapshot ID` saves the component as it's drawn, without its buttons, as an SVG in the
  session's `.agent-shell/images/` (`agent-ui-snapshot-directory`), at most `agent-ui-snapshot-width` columns wide, and
  replies with a Markdown image link. In the agent's reply, agent-shell shows the image inline, and the transcript
  keeps it. The SVG keeps the text in its faces' colours, each character at its column; a bar's blocks are rectangles,
  borders are lines that meet from line to line, and a chart's own SVG is nested in it.
- **From you:** `a` on a component puts it into the session's prompt as text: its id, its type, and its drawing in a
  code block.
- **Links.** `show`'s reply has the component's link, `agent-ui://canvas/NAME#ID`. In the agent's reply, as a Markdown
  link, agent-shell draws it; a click on it brings up the canvas's view, selected, with the cursor on the component.

## Exporting a PDF

`E` (`agent-ui-export-pdf`) saves what the canvas shows now, in your theme's colours, as a PDF. A session's canvas goes
in its directory's `.agent-shell/pdf/` (`agent-ui-pdf-directory`), named after the canvas with the date and time; a
project dashboard's goes beside its file. It needs `rsvg-convert`, from librsvg.

## Options

See [Customization](customization.md#the-canvas) for the canvas's options and
[Customization](customization.md#the-sessions-pane) for the pane's.
