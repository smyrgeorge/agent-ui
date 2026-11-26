;;; agent-ui-mermaid.el --- The mermaid component  -*- lexical-binding: t; -*-

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

;; Agent UI's Mermaid diagrams: the mermaid type, and the markdown type's
;; ```mermaid blocks (agent-ui-markdown.el).
;;
;; In the GUI, the diagram drawn by `agent-ui-mermaid-render-function'
;; (by default, Mermaid's CLI, mmdc, in the background, cached, dark or
;; light as the frame), at its size, at most the canvas's width; until it's
;; there, its source.  An error: Mermaid's message under its source.  In a
;; terminal, or without a renderer, its source, coloured by mermaid-mode if
;; it's installed.  `agent-ui-mermaid-theme-changed' draws them again (after
;; a theme switch).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)

(declare-function mermaid-mode "ext:mermaid-mode")

(defvar agent-ui-mermaid--errors (make-hash-table :test #'equal)
  "The diagrams that failed, by theme and source.
Mermaid's message (or what to install), not drawn again.")

;; ====== THE RENDERER ======

(defcustom agent-ui-mermaid-render-function #'agent-ui-mermaid-render
  "Draws a Mermaid diagram as an SVG file, in the background.
Called with the diagram's SOURCE and a CALLBACK.  Drawn already: it
returns the SVG's file, CALLBACK not called.  Else it returns nil and
later calls CALLBACK with the file and nil, or nil and an error message.
nil: diagrams show as their source."
  :type '(choice (const :tag "None: their source" nil) function)
  :group 'agent-ui)

(defcustom agent-ui-mermaid-key-function #'agent-ui-mermaid-theme-key
  "Returns a string naming how diagrams are drawn now (their colours).
A diagram that failed isn't drawn again until it changes."
  :type 'function :group 'agent-ui)

(defcustom agent-ui-mmdc "mmdc"
  "Mermaid's command line tool (npm install -g @mermaid-js/mermaid-cli)."
  :type 'string :group 'agent-ui)

(defcustom agent-ui-mermaid-cache-directory (locate-user-emacs-file "agent-ui/mermaid/")
  "Where the diagrams `agent-ui-mermaid-render' drew are kept."
  :type 'directory :group 'agent-ui)

(defvar agent-ui-mermaid--waiting (make-hash-table :test #'equal)
  "The drawings running: their file, the callbacks waiting for them.")

(defun agent-ui-mermaid-theme-key ()
  "How diagrams are drawn now: dark or light, as the selected frame."
  (if (eq (frame-parameter nil 'background-mode) 'dark) "dark" "default"))

(defun agent-ui-mermaid--config-file ()
  "Mermaid's config for `agent-ui-mermaid-render', written once: its file.
Labels as SVG text, not HTML: Emacs's SVG renderer doesn't draw HTML."
  (let ((file (expand-file-name "mermaid-config.json" agent-ui-mermaid-cache-directory)))
    (unless (file-exists-p file)
      (make-directory agent-ui-mermaid-cache-directory t)
      (with-temp-file file
        (insert "{\"htmlLabels\": false, \"flowchart\": {\"htmlLabels\": false}}\n")))
    file))

;; Emacs's SVG library (librsvg) drops the space a <tspan> starts with, and
;; Mermaid writes each word of a label in one: "Run the tests" showed as
;; "Runthetests".  The SVG's root keeps them (xml:space).
(defun agent-ui-mermaid--fix-svg (file)
  "Make FILE, an SVG mmdc wrote, keep its labels' spaces in Emacs."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (and (re-search-forward "<svg\\b" nil t)
               (not (looking-at "[^>]*xml:space=")))
      (insert " xml:space=\"preserve\"")
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region nil nil file nil 'silent)))))

(defun agent-ui-mermaid--message (output)
  "Mermaid's message in OUTPUT, mmdc's: its error, without its stack."
  (let ((lines (seq-take-while
                (lambda (line) (not (string-match-p "\\`[ \t]*at \\|\\.m?js:[0-9]" line)))
                (split-string (string-trim output) "\n"))))
    (string-remove-prefix "Error: " (string-trim (string-join lines "\n")))))

(defun agent-ui-mermaid-render (source callback)
  "Draw SOURCE, a Mermaid diagram, as an SVG with mmdc, in the background.
Drawn already: its file.  Else nil, CALLBACK called later with the file and
nil, or nil and Mermaid's message (or what to install).  Dark or light as
the selected frame, on a transparent background."
  (let* ((theme (agent-ui-mermaid-theme-key))
         (file (expand-file-name (concat (sha1 (concat theme "\n" source)) ".svg")
                                 agent-ui-mermaid-cache-directory)))
    (cond
     ((file-exists-p file) file)
     ((not (executable-find agent-ui-mmdc))
      (run-at-time 0 nil callback nil
                   (format "Diagrams need Mermaid's CLI, %s: npm install -g @mermaid-js/mermaid-cli"
                           agent-ui-mmdc))
      nil)
     ((gethash file agent-ui-mermaid--waiting)
      (push callback (gethash file agent-ui-mermaid--waiting))
      nil)
     (t
      (make-directory agent-ui-mermaid-cache-directory t)
      (let ((input (make-temp-file "agent-ui-mermaid" nil ".mmd" source))
            (output (make-temp-file "agent-ui-mermaid" nil ".svg"))
            (log (generate-new-buffer " *agent-ui mmdc*")))
        (puthash file (list callback) agent-ui-mermaid--waiting)
        (make-process
         :name "agent-ui-mmdc" :buffer log :noquery t :connection-type 'pipe
         :command (list agent-ui-mmdc "-q" "-i" input "-o" output
                        "-t" theme "-b" "transparent"
                        "-c" (agent-ui-mermaid--config-file))
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (let ((ok (and (zerop (process-exit-status process))
                            (file-exists-p output)
                            (> (file-attribute-size (file-attributes output)) 0)))
                   (message (with-current-buffer log
                              (agent-ui-mermaid--message (buffer-string)))))
               (when ok
                 (agent-ui-mermaid--fix-svg output)
                 (rename-file output file t))
               (ignore-errors (delete-file input))
               (ignore-errors (delete-file output))
               (kill-buffer log)
               (dolist (callback (prog1 (gethash file agent-ui-mermaid--waiting)
                                   (remhash file agent-ui-mermaid--waiting)))
                 (if ok
                     (funcall callback file nil)
                   (funcall callback nil (if (string-empty-p message)
                                             "Mermaid couldn't draw it"
                                           message))))))))
        nil)))))

(defun agent-ui-mermaid--p ()
  "Non-nil if diagrams can be drawn: there's a renderer."
  (and agent-ui-mermaid-render-function t))

(defun agent-ui-mermaid--highlight (diagram)
  "DIAGRAM coloured by mermaid-mode, if it's there."
  (if (not (fboundp 'mermaid-mode))
      diagram
    (with-temp-buffer
      (insert diagram)
      (delay-mode-hooks (mermaid-mode))
      (font-lock-ensure)
      (buffer-string))))

(defun agent-ui-mermaid--sized (svg ctx)
  "SVG (mmdc's, 100% wide) with its size in pixels.
As wide as it is, at most CTX's width.  Sized in its data: a snapshot
nests it as it's shown."
  (if (not (string-match "<svg\\b[^>]*>" svg))
      svg
    (let* ((root (match-string 0 svg))
           (start (match-beginning 0))
           (end (match-end 0))
           (box (and (string-match "viewBox=\"[-0-9.]+[ ,]+[-0-9.]+[ ,]+\\([0-9.]+\\)[ ,]+\\([0-9.]+\\)\"" root)
                     (cons (string-to-number (match-string 1 root)) (string-to-number (match-string 2 root))))))
      (if (not (and box (> (car box) 0)))
          svg
        (let* ((room (* (plist-get ctx :char-width) (max 1 (1- (plist-get ctx :width)))))
               (scale (min 1.0 (/ (float room) (car box))))
               (root (replace-regexp-in-string " \\(?:width\\|height\\)=\"[^\"]*\"" "" root t t))
               (root (replace-regexp-in-string "max-width: *[^;\"]*;? *" "" root t t)))
          (concat (substring svg 0 start)
                  (replace-regexp-in-string
                   "\\`<svg\\b" (format "<svg width=\"%d\" height=\"%d\""
                                        (round (* scale (car box))) (round (* scale (cdr box))))
                   root t t)
                  (substring svg end)))))))

(defun agent-ui-mermaid--weighted (svg)
  "SVG (mmdc's) with its text at `agent-ui-svg-font-weight'.
See THE SVGS' TEXT in agent-ui-core.el.  It is set on its root, which
its labels inherit, and in place of the regular weight some of them
set (a sequence's actors, in their style).  Bold stays bold."
  (if (or (eql agent-ui-svg-font-weight 400) (not (string-match "<svg\\b" svg)))
      svg
    (let ((at (match-end 0))
          (weight (number-to-string agent-ui-svg-font-weight)))
      (replace-regexp-in-string
       "font-weight: *\\(?:400\\|normal\\)\\b" (concat "font-weight: " weight)
       (concat (substring svg 0 at) " font-weight=\"" weight "\"" (substring svg at))
       t t))))

(defun agent-ui-mermaid--image (file ctx)
  "FILE's SVG as an image sized for CTX.
See `agent-ui-mermaid--sized'; its text's weight Agent UI's
\(`agent-ui-mermaid--weighted')."
  (propertize "diagram" 'display
              (agent-ui-image (create-image (agent-ui-mermaid--sized
                                             (agent-ui-mermaid--weighted
                                              (with-temp-buffer (insert-file-contents file) (buffer-string)))
                                             ctx)
                                            'svg t :ascent 'center))))

(defun agent-ui-mermaid-draw (diagram ctx)
  "DIAGRAM (Mermaid) drawn for CTX: its image, or its source (see above)."
  (let* ((diagram (string-trim diagram))
         (width (plist-get ctx :width))
         ;; Its source wrapped, each line's rest under its indent (whole, a
         ;; line ran 190 columns past the width).
         (text (if width
                   (agent-ui-wrap-hanging (agent-ui-mermaid--highlight diagram) width)
                 (agent-ui-mermaid--highlight diagram))))
    (if (not (and (plist-get ctx :graphic) (plist-get ctx :char-width) (agent-ui-mermaid--p)))
        text
      (let* ((key (concat (funcall agent-ui-mermaid-key-function) "\n" diagram))
             (failed (gethash key agent-ui-mermaid--errors))
             (file (and (not failed)
                        (funcall agent-ui-mermaid-render-function diagram
                                            (lambda (_file message)
                                              (when message (puthash key message agent-ui-mermaid--errors))
                                              (agent-ui-mermaid--redraw diagram))))))
        (cond (file (agent-ui-mermaid--image file ctx))
              (failed (concat text "\n" (propertize (agent-ui-wrap failed width) 'face 'agent-ui-error)))
              (t (concat text "\n" (propertize "drawing…" 'face 'agent-ui-muted))))))))

(defun agent-ui-mermaid--shows-p (component &optional diagram)
  "Non-nil if COMPONENT shows DIAGRAM (any, if nil).
A mermaid component's, or a markdown component's block."
  (pcase (plist-get component :type)
    ("mermaid" (or (null diagram) (equal (string-trim (or (plist-get component :diagram) "")) diagram)))
    ("markdown" (let ((markdown (or (plist-get component :markdown) "")))
                  (if diagram
                      (string-search diagram markdown)
                    (string-match-p "^[ \t]*\\(```\\|~~~\\)[ \t]*mermaid" markdown))))))

(defun agent-ui-mermaid--redraw (&optional diagram)
  "Redraw the components showing DIAGRAM (any, if nil), everywhere."
  (dolist (canvas (agent-ui-canvases))
    (with-current-buffer canvas
      (agent-ui--dirty
       (cl-loop for id in agent-ui--order
                for component = (agent-ui--entry-component (gethash id agent-ui--entries))
                when (or (agent-ui-mermaid--shows-p component diagram)
                         (seq-some (lambda (child) (agent-ui-mermaid--shows-p child diagram))
                                   (agent-ui--descendants component)))
                collect id)))))

(defun agent-ui-mermaid-theme-changed ()
  "Draw each diagram again, in the colours of the theme now.
For a hook run after a theme switch."
  (agent-ui-mermaid--redraw))

(defun agent-ui-mermaid--draw (props ctx)
  "PROPS' diagram drawn for CTX."
  (agent-ui-mermaid-draw (plist-get props :diagram) ctx))

(agent-ui-define mermaid
  "A Mermaid diagram: DIAGRAM in Mermaid's syntax (flowchart, sequence,
state, class, ER, Gantt, mind map...). For a diagram that stays in view and
changes as work goes on: an update with a new diagram draws it anew. An
image in the GUI, in the theme's colours (mmdc, if installed); its source in
a terminal."
  :props ((diagram string "The diagram, in Mermaid's syntax: flowchart LR; build --> test" :required t))
  :example (:title "Release" :diagram "flowchart LR\n    build --> test --> deploy")
  :text #'agent-ui-mermaid--draw)


(provide 'agent-ui-mermaid)

;;; agent-ui-mermaid.el ends here
