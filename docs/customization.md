# Customization

Agent UI's user options are in the `agent-ui` customization group (`M-x customize-group RET agent-ui`), or can be set
with `setq` in your init file:

```elisp
(setq agent-ui-close-finished nil       ; finished components stay unless they say otherwise
      agent-ui-pane-max-share 0.4)
```

A few settings are plain variables rather than user options; they're marked *(variable)* below and are set with
`setq`. Paths under `user-emacs-directory` are given as `~/.emacs.d/`; they follow wherever yours is.

## Setup

| Option | Default | What it does |
|---|---|---|
| `agent-ui-system-prompt` | `t` | Tell agents about their canvas in their system prompt, for agents that take one. nil: tell them yourself. |
| `agent-ui-mcp` | `t` | Give each agent-shell session Agent UI's MCP tools, for sessions started after `agent-ui-mode` is turned on. |
| `agent-ui-command` | `bin/agent-ui` in the package's directory | The command line agents run, as they're told. |
| `agent-ui-skill` | `skills/agent-ui/SKILL.md` in the package's directory | The guide agents read before using the canvas. |

## The canvas

| Option | Default | What it does |
|---|---|---|
| `agent-ui-close-finished` | `10` | Seconds a finished `steps`, `todo` or `progress` stays before it closes itself. nil: only those whose `close` gives seconds close. |
| `agent-ui-redraw-delay` | `0.1` | Seconds from an update to its redraw. The updates within it are drawn together. |
| `agent-ui-animation-interval` | `0.15` | Seconds between frames of animated components (a spinner). |
| `agent-ui-spinner-frames` | `("●")` | The spinner's frames, one per animation tick, each a column wide, such as `("▟" "▙" "▛" "▜")`. |
| `agent-ui-spinner-pulse` | `8` | Animation ticks over which the spinner's colour glows brighter and dimmer. nil: no glow (frames that move need none). |
| `agent-ui-default-width` | `80` | The width components are drawn at while their canvas isn't in a window. |
| `agent-ui-default-canvas` | `"default"` | The canvas used when none is named and no session is found. |
| `agent-ui-display-function` | `agent-ui-display-canvas` | Called with a canvas's buffer to show it when a new component is shown on it while it's in no window. |
| `agent-ui-max-components` | `100` | The most components a canvas holds; showing one more is an error. |
| `agent-ui-max-rows` | `500` | The most rows (a table's, a heatmap's) or values (a chart's) a component draws. |
| `agent-ui-max-chars` | `20000` | The most characters a component's drawing has; the rest is left out, with a line saying so. |
| `agent-ui-max-cell-lines` | `20` | The most lines a table's cell, or a line of a log, code or diff, wraps onto. |
| `agent-ui-milliseconds-below` | `1.5` | Seconds below which a time taken is shown in milliseconds (a timeline's, a finished step's). |
| `agent-ui-svg-font-weight` | `600` on macOS, `400` elsewhere | The weight of the text in SVG images (charts, graphs, timelines, gauges, chips, snapshots, diagrams). On macOS, SemiBold matches the editor's text, which macOS draws a little heavier. |
| `agent-ui-focus-questions` *(variable)* | `t` | A question shown takes the focus. nil: the focus stays where it is. |
| `agent-ui-focus-questions-delay` *(variable)* | `1.0` | Seconds without typing before a question takes the focus. |
| `agent-ui-focus-questions-typing-delay` *(variable)* | `5.0` | Seconds without typing before a question takes the focus, when you've typed since it showed. |
| `agent-ui-close-answered` *(variable)* | `t` | An answered question leaves its canvas. nil: it stays there. |

## The session's pane

| Option | Default | What it does |
|---|---|---|
| `agent-ui-pane-max-share` | `0.5` | The most of its session's pane that Agent UI takes. |
| `agent-ui-pane-min-lines` | `6` | The fewest lines the conversation and Agent UI each keep. In a pane too short for both, a view opens in a window of its own. |
| `agent-ui-grid-min-width` | `40` | The fewest columns a view gets. |
| `agent-ui-grid-wide-width` | `80` | The fewest columns a view showing a wide type gets. |
| `agent-ui-grid-wide-types` | `("diff" "code" "graph" "mermaid" "heatmap" "timeline" "compare")` | The types that want room across. |
| `agent-ui-pane-keys` | `"q close"` | The keys shown at the right of Agent UI's bar under its views. nil: none. |
| `agent-ui-pane-mode-line` | `nil` | nil: Agent UI's own bar under its views. t: the views at the bottom keep their buffer's own mode line instead (`agent-ui-pane-mode-line-text` gives what the bar would say, for your mode line to show). |

## Kept with the session, snapshots and PDFs

| Option | Default | What it does |
|---|---|---|
| `agent-ui-persist-directory` | `".agent-shell/agent-ui/"` | Where sessions' canvases are kept, in a session's directory. |
| `agent-ui-persist-delay` | `1.0` | Seconds after a canvas's change before it's saved. Changes within it are saved together. |
| `agent-ui-snapshot-directory` | `".agent-shell/images/"` | Where snapshots go, relative to the agent's directory. |
| `agent-ui-snapshot-width` | `80` | The most columns a snapshot is drawn at (narrower to fit the session's window). |
| `agent-ui-pdf-directory` | `".agent-shell/pdf/"` | Where `E` saves a canvas's PDF, in its session's directory. A project dashboard's goes beside its file. |
| `agent-ui-pdf-program` *(variable)* | `"rsvg-convert"` | The program that turns the canvas's SVG into a PDF. |

## Components

| Option | Default | What it does |
|---|---|---|
| `agent-ui-progress-pause` | `2700` (45 minutes) | Seconds an item took above which it counts as a pause (a night, lunch), left out of a progress bar's time per item. |
| `agent-ui-log-source-faces` | `(font-lock-keyword-face font-lock-function-name-face font-lock-constant-face font-lock-variable-name-face)` | The colours of a log's sources (its jobs, its services), in turn. |
| `agent-ui-panel-depth` | `6` | How deep `panel` components may nest. |
| `agent-ui-panel-max-chars` | `200000` | The most characters a panel's lines may have. |
| `agent-ui-open-file-function` | `find-file-other-window` | Opens a file a component shows (an image), given its name. |
| `agent-ui-image-cache-directory` | `~/.emacs.d/agent-ui/images/` | Where images from URLs are kept once downloaded. |
| `agent-ui-open-page-function` | `agent-ui-html-browse` | Opens a page an `html` component shows, given a file's name or a URL. The default uses `browse-url`. |
| `agent-ui-html-max-bytes` | `500000` | The most of an HTML file read for its card. |
| `agent-ui-mermaid-render-function` | `agent-ui-mermaid-render` | Draws a Mermaid diagram as an SVG file in the background. Called with the diagram's source and a callback: it returns the SVG's file if it's drawn already; otherwise it returns nil and later calls the callback with the file and nil, or nil and an error message. |
| `agent-ui-mermaid-key-function` | `agent-ui-mermaid-theme-key` | Returns a string naming how diagrams are drawn now (their colours), so a theme change draws them again. |
| `agent-ui-mmdc` | `"mmdc"` | Mermaid's command line tool, used by `agent-ui-mermaid-render`. |
| `agent-ui-mermaid-cache-directory` | `~/.emacs.d/agent-ui/mermaid/` | Where the diagrams `agent-ui-mermaid-render` drew are kept. |
| `agent-ui-math-tool` *(variable)* | `auto` | What typesets formulas: `mathjax`, `latex`, `none`, or `auto` (MathJax when it's in node's global modules, else LaTeX and `dvisvgm`). |
| `agent-ui-math-cache-directory` *(variable)* | `~/.emacs.d/agent-ui/math/` | Where typeset formulas are kept, by their hash. |

## Sources

| Option | Default | What it does |
|---|---|---|
| `agent-ui-source-log-directory` | `agent-ui/` in `temporary-file-directory` | Where commands' output is kept, for the agent to read. Made with mode 700; one already there that isn't the user's own, closed to others, isn't used (a folder of their own instead, made once per Emacs). |
| `agent-ui-source-file-interval` | `0.5` | Seconds between looks at a followed file. |

## Project dashboards

| Option | Default | What it does |
|---|---|---|
| `agent-ui-dashboard-directory` | `".agent-ui/dashboards/"` | Where a project's dashboards are, in its root. |
| `agent-ui-dashboard-trust-file` | `~/.emacs.d/agent-ui/trusted-dashboards.eld` | Where the dashboards and projects whose code you let run are remembered. |
| `agent-ui-dashboard-loading-delay` | `0.5` | Seconds a refreshing query runs before its component says it's loading. |
| `agent-ui-dashboard-slow` | `0.1` | Seconds a dashboard's fetch may take itself before it's said to be slow. |

## Types the agent makes

| Option | Default | What it does |
|---|---|---|
| `agent-ui-staging-directory` | `~/.emacs.d/agent-ui/staged/` | Where the types the agent made wait for your review. |
| `agent-ui-kept-directory` | `~/.emacs.d/agent-ui/kept/` | Where the types you kept are, loaded at each start. |
| `agent-ui-staging-requires` | `(cl-lib subr-x seq map pcase rx svg)` | What a type the agent made may `require`. |

## Bugs

| Option | Default | What it does |
|---|---|---|
| `agent-ui-bug-function` *(variable)* | `nil` | Files a bug in your own tracker ([Bugs in Agent UI](bugs.md#filing-into-your-own-tracker)). nil: every report is given back, to file by hand. |
| `agent-ui-bug-report-url` | `"https://github.com/smyrgeorge/agent-ui/issues"` | Where to report bugs by hand, named when one can't be filed. |
| `agent-ui-open-issue-function` | `agent-ui-bug-show-issue` | Opens a bug just filed (`RET` right after `b`), given its id and its issues' directory: by default, a URL in the browser, else it's said. Set it along with `agent-ui-bug-function`. |

## Faces

Agent UI's colours come from faces that inherit from standard ones, so they follow your theme: `agent-ui-accent`,
`agent-ui-muted`, `agent-ui-success`, `agent-ui-warning` and `agent-ui-error`, and for the pane, `agent-ui-pane-bar`,
`agent-ui-pane-bar-name` and `agent-ui-pane-bar-keys`. Customize them in the `agent-ui` group.

## Hooks

Hooks for your own code (a desktop notification when a question is left waiting, say) are listed in
[Emacs Lisp interface](lisp.md#hooks). To redraw Mermaid diagrams after a theme switch:

```elisp
(add-hook 'enable-theme-functions (lambda (_theme) (agent-ui-mermaid-theme-changed)))
```
