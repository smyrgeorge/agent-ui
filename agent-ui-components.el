;;; agent-ui-components.el --- The component types  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yorgos S.

;; Author: Yorgos S. <https://github.com/smyrgeorge>
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
;; with `agent-ui-define' (agent-ui-core.el).

;;; Code:

(require 'agent-ui-text)
(require 'agent-ui-markdown)
(require 'agent-ui-progress)
(require 'agent-ui-steps)
(require 'agent-ui-table)
(require 'agent-ui-chart)
(require 'agent-ui-image)
(require 'agent-ui-html)
(require 'agent-ui-diff)
(require 'agent-ui-choice)
(require 'agent-ui-todo)
(require 'agent-ui-confirm)
(require 'agent-ui-form)
(require 'agent-ui-rank)
(require 'agent-ui-slider)
(require 'agent-ui-tags)
(require 'agent-ui-gauge)
(require 'agent-ui-countdown)
(require 'agent-ui-math)
(require 'agent-ui-mermaid)
(require 'agent-ui-files)
(require 'agent-ui-stats)
(require 'agent-ui-log)
(require 'agent-ui-activity)
(require 'agent-ui-timeline)
(require 'agent-ui-graph)
(require 'agent-ui-code)
(require 'agent-ui-heatmap)
(require 'agent-ui-panel)
;; Its options are components of the others, laid out as a panel's row: last.
(require 'agent-ui-compare)

(provide 'agent-ui-components)

;;; agent-ui-components.el ends here
