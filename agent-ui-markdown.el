;;; agent-ui-markdown.el --- The markdown component  -*- lexical-binding: t; -*-

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

;; Agent UI's Markdown, drawn as agent-shell draws the agent's replies
;; (headings, emphasis, lists, tables, highlighted code, links), at the
;; canvas's width; without agent-shell, as it's written, wrapped.  Its
;; ```mermaid blocks: agent-ui-mermaid.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)

(declare-function agent-ui-mermaid-draw "agent-ui-mermaid")

(declare-function agent-shell-markdown-replace-markup "agent-shell-markdown")

(defconst agent-ui-markdown--diagram-regexp
  "^\\([ \t]*\\)\\(```\\|~~~\\)[ \t]*mermaid[ \t]*\n\\(\\(?:.*\n\\)*?\\)[ \t]*\\2[ \t]*$"
  "A fenced Mermaid block: its indent, its fence, its diagram.")

(defun agent-ui-markdown--take-diagrams (markdown)
  "MARKDOWN with its Mermaid blocks taken out: (TEXT . DIAGRAMS).
Each block is a line of its own in TEXT, a placeholder its drawing
replaces (`agent-ui-markdown--put-diagrams')."
  (let ((diagrams nil)
        (start 0)
        (parts nil))
    (while (string-match agent-ui-markdown--diagram-regexp markdown start)
      (push (substring markdown start (match-beginning 0)) parts)
      (push (format "AGENTUIDIAGRAM%dX" (length diagrams)) parts)
      (push (match-string 3 markdown) diagrams)
      (setq start (match-end 0)))
    (push (substring markdown start) parts)
    (cons (apply #'concat (nreverse parts)) (nreverse diagrams))))

(defun agent-ui-markdown--put-diagrams (diagrams ctx)
  "Replace the placeholders of DIAGRAMS in the current buffer by them.
They are drawn for CTX (`agent-ui-mermaid-draw')."
  (when diagrams
    ;; Loaded when a diagram is drawn: the mermaid type's file.
    (require 'agent-ui-mermaid))
  (cl-loop for diagram in diagrams
           for i from 0
           do (goto-char (point-min))
           (when (search-forward (format "AGENTUIDIAGRAM%dX" i) nil t)
             (delete-region (match-beginning 0) (match-end 0))
             (insert (agent-ui-mermaid-draw diagram ctx)))))

(defun agent-ui-markdown--render (markdown width &optional ctx)
  "MARKDOWN drawn by agent-shell's renderer; nil without `agent-shell'.
Its tables are WIDTH wide, its diagrams drawn for CTX."
  (when (require 'agent-shell-markdown nil t)
    (let ((taken (agent-ui-markdown--take-diagrams markdown)))
      (with-temp-buffer
        (insert (car taken))
        ;; The buffer is in no window: the renderer would size tables to the
        ;; selected one's.
        (cl-letf (((symbol-function 'agent-shell-markdown--display-width)
                   (lambda (&optional _window) width)))
          (agent-shell-markdown-replace-markup
           ;; Images are the image type's: here, their text.
           :render-images nil :highlight-blocks t :complete t))
        (agent-ui-markdown--put-diagrams (cdr taken) ctx)
        (string-trim (buffer-string) "\n+" "\n+")))))

(defun agent-ui-markdown--text (props ctx)
  "PROPS' markdown as text, for CTX."
  (let ((markdown (plist-get props :markdown))
        (width (plist-get ctx :width)))
    ;; Its lines wrapped: agent-shell leaves that to its window, and a
    ;; canvas's lines are cut (its tables already fit).  Each line's rest
    ;; under its text's start: a list item's, a code line's indent.
    (agent-ui-wrap-hanging (or (agent-ui-markdown--render markdown width ctx) markdown)
                           width)))

(agent-ui-define markdown
  "Markdown, drawn as your replies are in your session.
Headings, bold, italic, inline code, lists, task lists, tables, fenced code
highlighted by its language, links, ```mermaid blocks drawn as diagrams.
For notes, summaries, a plan that stays in view while the conversation
scrolls.  Images in it show as their text."
  :props ((markdown string "The Markdown" :required t))
  :example (:id "plan" :title "Plan"
            :markdown "1. **Parse** the config\n2. Check it against `schema.json`\n3. Write the report")
  :text #'agent-ui-markdown--text)


(provide 'agent-ui-markdown)

;;; agent-ui-markdown.el ends here
