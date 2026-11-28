;;; agent-ui-parts.el --- Agent UI's parts, loaded together  -*- lexical-binding: t; -*-

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

;; What Agent UI needs whenever it shows anything, loaded together: each
;; part hooks into the canvas as it loads (its questions, its pane, what's
;; kept of it...).  Loaded the first time agent-shell is loaded or Agent
;; UI is used (`agent-ui-mode', agent-ui.el's autoloads), not with Emacs:
;; they took 65-90 ms of its start.
;;
;; Found in their own folder first: in a long `load-path' (265 folders,
;; Agent UI's the 195th), finding each one took ~2 ms, longer than loading
;; some of them.

;;; Code:

(let ((load-path (cons (file-name-directory (or load-file-name buffer-file-name))
                       load-path)))
  (require 'agent-ui-core)
  (require 'agent-ui-canvas)
  (require 'agent-ui-request)
  (require 'agent-ui-agent)
  (require 'agent-ui-pane)
  (require 'agent-ui-persist)
  (require 'agent-ui-ask)
  (require 'agent-ui-components)
  (require 'agent-ui-finished)
  (require 'agent-ui-source)
  (require 'agent-ui-dashboards))

(provide 'agent-ui-parts)

;;; agent-ui-parts.el ends here
