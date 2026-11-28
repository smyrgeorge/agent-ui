;;; agent-ui-components.el --- The component types  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yorgos S.

;; Author: Yorgos S. <https://github.com/smyrgeorge>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/smyrgeorge/agent-ui

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Agent UI's component types, a file each (agent-ui-TYPE.el), each defined
;; with `agent-ui-define' (agent-ui-core.el).  None is loaded here: each
;; type's file is loaded the first time the type is used (a component of it
;; shown, checked, drawn, `agent-ui-autoload-type').  Loading them all took
;; 0.3 s of Emacs's start, for types a session may never show.

;;; Code:

(require 'agent-ui-core)

(dolist (type '(activity chart choice code compare confirm countdown diff files form
                gauge graph heatmap html image log markdown math mermaid panel
                progress rank slider stats steps table tags text timeline todo))
  (agent-ui-autoload-type type (intern (format "agent-ui-%s" type))))

;; What of theirs is used before any of them is shown: a key of the canvas,
;; what a user's configuration calls.
(autoload 'agent-ui-table-sort "agent-ui-table"
  "Sort the table at point by the column at point; again, the other way." t)
(autoload 'agent-ui-html-browse "agent-ui-html"
  "Open PAGE (a file's name or a URL) in the browser.")
(autoload 'agent-ui-mermaid-render "agent-ui-mermaid"
  "Draw SOURCE, a Mermaid diagram, as an SVG with mmdc, in the background.")
(autoload 'agent-ui-mermaid-theme-key "agent-ui-mermaid"
  "How diagrams are drawn now: dark or light, as the selected frame.")
(autoload 'agent-ui-mermaid-theme-changed "agent-ui-mermaid"
  "Draw each diagram again, in the colours of the theme now.")

(provide 'agent-ui-components)

;;; agent-ui-components.el ends here
