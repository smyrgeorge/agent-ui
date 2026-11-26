;;; agent-ui-text.el --- The text component  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yorgos S.

;; Author: Yorgos S.
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

;; Agent UI's text: a paragraph, its lines wrapped to the width, in a
;; face saying what it is (a success, a warning...).

;;; Code:

(require 'subr-x)
(require 'agent-ui-core)

(defun agent-ui-text--text (props ctx)
  "PROPS' text, for CTX."
  (let ((face (pcase (plist-get props :face)
                ('muted 'agent-ui-muted)
                ('success 'agent-ui-success)
                ('warning 'agent-ui-warning)
                ('error 'agent-ui-error)
                (_ nil)))
        (text (agent-ui-wrap (plist-get props :text) (plist-get ctx :width))))
    (if face (propertize text 'face face) text)))

(agent-ui-define text
  "Plain text, its lines wrapped to the width: a note, a result, a status
line. FACE says what it is: plain, muted (secondary), success, warning,
error. For formatting (headings, lists, code), use markdown."
  :props ((text string "The text; newlines kept" :required t)
          (face (choice plain muted success warning error) "What it is, its colour"
                :default plain))
  :example (:id "status" :text "All 412 tests pass." :face "success")
  :text #'agent-ui-text--text)


(provide 'agent-ui-text)

;;; agent-ui-text.el ends here
