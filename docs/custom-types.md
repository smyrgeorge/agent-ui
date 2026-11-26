# Custom types

Each component type is defined once in Lisp, with `agent-ui-define`. You can define your own in your init file, and
the agent can make one when none of the 30 built-in types fits ([below](#types-the-agent-makes)).

## Defining a type

```elisp
;;; dial.el --- Agent UI type dial -*- lexical-binding: t; -*-

(defun agent-ui-dial--text (props ctx)
  "PROPS drawn in CTX's width: [#####.....] 50% LABEL."
  (let* ((value (plist-get props :value))
         (cells (min 20 (max 5 (- (plist-get ctx :width) 30))))
         (full (round (* cells (/ value 100.0)))))
    (concat "[" (propertize (make-string full ?#) 'face 'agent-ui-accent)
            (make-string (- cells full) ?.) "] "
            (format "%d%%" value)
            (if-let* ((label (plist-get props :label))) (concat "  " label) ""))))

(agent-ui-define dial
  "A dial: VALUE percent, with a LABEL."
  :props ((value integer "Percent, 0 to 100" :default 0)
          (label string "What it measures"))
  :example (:value 42 :label "disk")
  :check (lambda (props)
           (unless (<= 0 (plist-get props :value) 100)
             (agent-ui--fail "dial: value must be from 0 to 100"))
           props)
  :text #'agent-ui-dial--text)
```

```sh
agent-ui show '{"id":"disk","type":"dial","value":42,"label":"disk"}'
```

```text
[########............] 42%  disk
```

The type's name is a symbol of `a-z`, `0-9` and `-`. Its documentation string is what the agent reads in the catalog
(`agent-ui types`), so it should say what the type is for. Defining a type again replaces it.

| Keyword | What it is |
|---|---|
| `:props` | Its properties, each `(NAME KIND DOC [:default VALUE] [:required t])`. KIND is `string`, `number`, `integer`, `boolean`, `list`, `any`, `file` (a name relative to the agent's directory; `:default :here` is that directory), or `(choice SYMBOL...)`, whose JSON strings become the symbol. DOC is shown in the catalog. A component is checked against them before it's drawn, and an unknown property is an error listing them. |
| `:example` | A component of the type, as a plist. It's checked when the type is defined and shown in the catalog, where the agent copies it. |
| `:text` | `(lambda (PROPS CTX) ...)`: draws it as text, returning a string, maybe with faces. Required. |
| `:gui` | The same, for a graphical frame: a string, typically with an SVG image on it. Optional; without it, `:text` draws in both. |
| `:animated` | `t`, or `(lambda (PROPS) ...)`: whether it's redrawn as time passes, CTX's `:tick` counting up. |
| `:check` | `(lambda (PROPS) ...)`: checks what a property's kind can't, such as a list's items or properties that go together. It returns PROPS, maybe normalized, or signals `agent-ui-error` (with `agent-ui--fail`). What it returns is drawn; what's kept is the component as given. |
| `:append` | `(lambda (COMPONENT PATCH) ...)`: how `agent-ui append` adds to it, such as a table's rows replaced by key. Without it, each list is appended to. |
| `:prepare` | `(lambda (COMPONENT) ...)`: the component as it's kept, each time it's shown or changed. It's for what the component notes as time passes, such as when a step started. Called again on its own result, it must change nothing. |
| `:extend` | `(lambda (OLD NEW CTX) ...)`: for components that grow, such as a long log. When the component was drawn as OLD and is now NEW, it returns edits that turn OLD's drawing into NEW's, done in order on its lines (from 0): `(replace LINE TEXT)`, `(delete LINE COUNT)`, `(insert BEFORE-END TEXT)`. Or it returns nil, to draw it again. An append then draws only what's appended. |
| `:finished` | `(lambda (PROPS) ...)`: `done` when all of it went well, `failed` when some of it didn't, nil while it isn't finished. A type that finishes takes `close` and closes itself once done ([Finished components close](canvas.md#finished-components-close)). |
| `:whole` | `t`: its drawing isn't cut at `agent-ui-max-chars` as a whole; the type keeps its own size in bounds (as a panel does). |

`:text` and `:gui` take the component's properties (checked, defaults filled) and a context, `CTX`, a plist:

| Key | What it is |
|---|---|
| `:width` | The width in characters. Fit it. |
| `:graphic` | Non-nil in a graphical frame. |
| `:tick` | Counts up, for animations. |
| `:char-width`, `:line-height` | A character's width and a line's height in pixels, to size an image to the text. |
| `:still` | Non-nil for a still picture (a snapshot): draw no buttons, since they'd do nothing there. |
| `:id` | The component's id, on a canvas. |

They return the text to insert and don't touch the buffer, so a type can be tested by calling them. Drawing runs in
Emacs's only thread, on each change, so keep it quick. A drawing that signals an error shows the error in the
component's place.

### Helpers

- Text: `agent-ui-pad`, `agent-ui-truncate`, `agent-ui-wrap`, `agent-ui-wrap-hanging` (a list item's rest under its
  text), `agent-ui-format-number`, `agent-ui-format-duration`, `agent-ui-spinner`.
- Faces: `agent-ui-accent`, `agent-ui-muted`, `agent-ui-success`, `agent-ui-warning`, `agent-ui-error`, and `bold`.
- Buttons: `(agent-ui-button TEXT ACTION [HELP])` makes text a button that `RET` or a click presses, and
  `(agent-ui-button-row BUTTONS WIDTH)` lays buttons out on lines no wider than WIDTH.
- Badges: `(agent-ui-pill LABEL CTX :face F :filled t :count N)` is a rounded tag, and
  `(agent-ui-pie FRACTION CTX FACE)` shows a fraction as a pie. In a terminal they're text (`[bug 3]`, `◑`); in a
  graphical frame, an SVG of the same width shows over that text, in the theme's colours.
- A type that asks (picks, a note, an answer for the agent) uses the helpers in `agent-ui-ask.el`:
  `agent-ui-ask-pick-button`, `agent-ui-ask-mark`, `agent-ui-ask-all-none`, `agent-ui-ask-note-button`,
  `agent-ui-ask-answer-button`, `agent-ui-ask-answered-line` (the answer once given, locked) and `agent-ui-ask-check`
  (checks a selection). Its state is the component's own `selected`, `note-text` and `answered` properties, saved with
  the session. `choice` is made of them.

## Types the agent makes

When none of the types fits, the agent can write one: an Emacs Lisp file with one `agent-ui-define` and the
definitions it uses, like the example above. `agent-ui define FILE` (the MCP tool `define`) stages it:

1. **Checked.** Its forms are read. It must hold exactly one `agent-ui-define`, of a type that isn't already there
   (built in or kept). Every other form must be a definition (`defun`, `defconst`, `defvar`, `defface` and the like)
   named after the type, `agent-ui-NAME-...`, or a `require` of one of `agent-ui-staging-requires` (`cl-lib`, `subr-x`,
   `seq`, `map`, `pcase`, `rx`, `svg`). Nothing else: no `setq`, nothing run at load.
2. **Compiled** by the byte compiler, with nothing written. Errors refuse it; warnings go back to the agent, by line.
3. **Loaded**, and **its example drawn.** The reply has that drawing as text (`preview`), so the agent sees what it
   made. An example that doesn't draw refuses it.

A refused type leaves nothing behind. A staged type can be used at once. A message says the agent made one, and each
canvas's header line lists the types waiting for your review.

| Key | What it does |
|---|---|
| `R` (in a canvas), or `M-x agent-ui-review` | List the types waiting for your review. |
| `RET` | Preview it: what it is, its properties, its example drawn (as SVG if it has a graphical drawing), its code. |
| `a` | Keep it: its file moves to `agent-ui-kept-directory`, and it's loaded at each start from now on. |
| `x` | Discard it: its file is deleted, and its components are removed from every canvas. |
| `v` | Its code, read-only. |
| `q` | Close the list. |

- Staged types wait in `agent-ui-staging-directory`. After a restart they aren't loaded again, but stay listed for
  your review, which loads one to preview it.
- Kept types are loaded when `agent-ui-mode` is first turned on. One that fails to load is reported, and the others
  still load.
- `agent-ui-staged-functions` and `agent-ui-kept-functions` run when a type is staged or kept
  ([Customization](customization.md#hooks)).
