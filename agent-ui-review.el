;;; agent-ui-review.el --- Reviewing the component types the agent made  -*- lexical-binding: t; -*-

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

;; Agent UI's review of the types the agent made (agent-ui-staging.el): a list of
;; them, a preview of each (what it is, its properties, its example, its
;; code: read, nothing of it run), keep (its code then compiled, loaded and
;; run, the user's yes) or discard.
;;
;; M-x agent-ui-review, or R in a canvas (whose header says when types wait).
;;   RET  its preview          a  keep it          x  discard it
;;   v    its code             g  the list again

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Its previews in a canvas, from anywhere (M-x): all of Agent UI's parts.
(require 'agent-ui-parts)
(require 'agent-ui-staging)
(require 'tabulated-list)

;; ====== VARIABLES ======

(defconst agent-ui-review-buffer "Agent UI: types to review"
  "The list of the types the agent made.")

(defvar-local agent-ui-review--type nil "In a preview: its type's name.")

;; ====== THE LIST ======

(defvar-keymap agent-ui-review-mode-map
  :doc "Keys of the list of types the agent made."
  "RET" #'agent-ui-review-preview
  "a" #'agent-ui-review-keep
  "x" #'agent-ui-review-discard
  "v" #'agent-ui-review-source)

(define-derived-mode agent-ui-review-mode tabulated-list-mode "Agent UI review"
  "Major mode for the component types the agent made, waiting for review.
They wait for you to keep or discard them.

\\{agent-ui-review-mode-map}"
  (setq tabulated-list-format [("Type" 18 t) ("Made" 17 t) ("What it is" 0 nil)]
        tabulated-list-padding 1
        ;; The columns' names in the buffer: the header line says the keys.
        tabulated-list-use-header-line nil)
  (tabulated-list-init-header)
  (setq header-line-format
        (substitute-command-keys
         " \\<agent-ui-review-mode-map>\\[agent-ui-review-preview] preview   \\[agent-ui-review-keep] keep   \\[agent-ui-review-discard] discard   \\[agent-ui-review-source] code"))
  (add-hook 'tabulated-list-revert-hook #'agent-ui-review--entries nil t))

(defun agent-ui-review--define (file)
  "The `agent-ui-define' form of the type in FILE, read (never evaluated)."
  (let ((forms (ignore-error (agent-ui-error file-error)
                 (agent-ui--read-forms (with-temp-buffer (insert-file-contents file) (buffer-string))))))
    (seq-find (lambda (f) (eq (car-safe f) 'agent-ui-define)) forms)))

(defun agent-ui-review--doc (file)
  "The first line of the documentation of the type in FILE."
  (let ((doc (nth 2 (agent-ui-review--define file))))
    (if (stringp doc) (car (split-string doc "\n")) "")))

(defun agent-ui-review--entries ()
  "Set `tabulated-list-entries' to the staged types, one per file."
  (setq tabulated-list-entries
        (mapcar (lambda (file)
                  (let ((name (intern (file-name-base file))))
                    (list name
                          (vector (symbol-name name)
                                  (format-time-string "%Y-%m-%d %H:%M"
                                                      (file-attribute-modification-time (file-attributes file)))
                                  (agent-ui-review--doc file)))))
                (agent-ui-staged-files))))

(defun agent-ui-review ()
  "List the component types the agent made, to keep or discard."
  (interactive)
  (let ((buffer (get-buffer-create agent-ui-review-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-ui-review-mode)
        (agent-ui-review-mode))
      (agent-ui-review--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun agent-ui-review--refresh ()
  "The list again, where it's open; the canvases' headers."
  (when-let* ((buffer (get-buffer agent-ui-review-buffer)))
    (with-current-buffer buffer
      (agent-ui-review--entries)
      (tabulated-list-print t)))
  (agent-ui-review--canvas-headers)
  (force-mode-line-update t))

(defun agent-ui-review--name ()
  "The type at point, in the list or a preview."
  (or agent-ui-review--type
      (tabulated-list-get-id)
      (user-error "No type here")))

;; ====== A PREVIEW ======

(defvar-keymap agent-ui-review-preview-mode-map
  :doc "Keys of a preview of a type the agent made."
  "a" #'agent-ui-review-keep
  "x" #'agent-ui-review-discard
  "v" #'agent-ui-review-source)

(define-derived-mode agent-ui-review-preview-mode special-mode "Agent UI type"
  "A type the agent made: what it is, its example drawn, its code.

\\{agent-ui-review-preview-mode-map}"
  (setq-local truncate-lines t)
  (setq header-line-format
        (substitute-command-keys
         " \\<agent-ui-review-preview-mode-map>\\[agent-ui-review-keep] keep   \\[agent-ui-review-discard] discard   \\[agent-ui-review-source] its code   \\[quit-window] close")))

(defun agent-ui-review--code (file)
  "FILE's code, highlighted as Emacs Lisp."
  (with-temp-buffer
    (insert-file-contents file)
    (delay-mode-hooks (emacs-lisp-mode))
    (font-lock-ensure)
    (buffer-string)))

(defun agent-ui-review--heading (text)
  "TEXT as a heading line, in the title face."
  (propertize (concat text "\n") 'face 'agent-ui-title))

(defun agent-ui-review--props (name keys)
  "The lines saying type NAME's properties, its define's KEYS (:props ...)."
  (let ((props (plist-get keys :props)))
    (if (not (and props (proper-list-p props)))
        "  none\n"
      (mapconcat
       (lambda (entry)
         (if-let* ((prop (ignore-error agent-ui-error (agent-ui--parse-prop name entry))))
             (format "  %-12s %-28s %s%s\n"
                     (substring (symbol-name (agent-ui-prop-key prop)) 1)
                     (agent-ui--kind-name (agent-ui-prop-kind prop))
                     (agent-ui-prop-doc prop)
                     (cond ((agent-ui-prop-required prop) " (required)")
                           ((agent-ui-prop-default prop)
                            (format " (default %s)" (agent-ui--show-value
                                                    (agent-ui-to-json (agent-ui-prop-default prop)))))
                           (t "")))
           (format "  %S (not a property: it'll be refused)\n" entry)))
       props ""))))

(defun agent-ui-review-preview (&optional name)
  "Preview the type NAME (at point), as its file says.
What it is, its properties, its example, its code.  Nothing of it is run:
it's read, not loaded (its code runs once kept: compiled, loaded, its
example drawn)."
  (interactive)
  (let* ((name (or name (agent-ui-review--name)))
         (file (agent-ui--staged-file name))
         (define (agent-ui-review--define file))
         (doc (nth 2 define))
         (keys (and (proper-list-p define) (nthcdr 3 define)))
         (example (plist-get keys :example))
         (buffer (get-buffer-create (format "Agent UI type: %s" name))))
    (display-buffer buffer '(nil (inhibit-same-window . t)))
    (with-current-buffer buffer
      (agent-ui-review-preview-mode)
      (setq agent-ui-review--type name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-ui-review--heading (format "%s, made by the agent" name))
                (if (stringp doc) doc "") "\n\n"
                (agent-ui-review--heading "Properties")
                (agent-ui-review--props name keys)
                "\n" (agent-ui-review--heading "Its example")
                (or (ignore-error (json-error wrong-type-argument) (json-serialize (agent-ui-to-json example))) (format "%S" example))
                "\n" (propertize "Drawn once you keep it: its code runs then (compiled, loaded, at each start)."
                                 'face 'agent-ui-muted)
                "\n\n" (agent-ui-review--heading (format "Its code (%s)" (abbreviate-file-name file)))
                (agent-ui-review--code file))
        (goto-char (point-min))))
    buffer))

(defun agent-ui-review-source ()
  "Visit the code of the type at point (read-only)."
  (interactive)
  (let ((file (agent-ui--staged-file (agent-ui-review--name))))
    (with-current-buffer (find-file-other-window file)
      (read-only-mode 1))))

;; ====== KEEP, DISCARD ======

(defun agent-ui-review--close-preview (name)
  "Close the preview window of the type NAME."
  (when-let* ((buffer (get-buffer (format "Agent UI type: %s" name))))
    (quit-windows-on buffer t)))

(defun agent-ui-review-keep (&optional name)
  "Keep the type NAME (at point), asked first.
Its code runs then, for the first time: compiled, loaded (at each start
from now on), its example drawn (`agent-ui-keep'); the agent that made it
told.  It can't be kept (it doesn't compile, its example doesn't draw):
said, the agent told why, its file left here."
  (interactive)
  (let ((name (or name (agent-ui-review--name))))
    (when (or (not (called-interactively-p 'any))
              (y-or-n-p (format "Keep the type %s, its code run in Emacs (now, and at each start)? " name)))
      (let ((kept (condition-case err
                      (agent-ui-keep name)
                    (agent-ui-error
                     (agent-ui-review--refresh)
                     (user-error "Agent UI: %s can't be kept: %s (the agent is told)"
                                 name (agent-ui-error-message err))))))
        (agent-ui-review--close-preview name)
        (agent-ui-review--refresh)
        (message "Agent UI: %s kept, in %s" name (abbreviate-file-name (plist-get kept :file)))
        kept))))

(defun agent-ui-review-discard (&optional name)
  "Discard the type NAME (at point), asked first.
Its file is deleted, the agent that made it told (`agent-ui-discard')."
  (interactive)
  (let ((name (or name (agent-ui-review--name))))
    (when (or (not (called-interactively-p 'any))
              (y-or-n-p (format "Discard the type %s (its file deleted)? " name)))
      (agent-ui-discard name)
      (agent-ui-review--close-preview name)
      (agent-ui-review--refresh)
      (message "Agent UI: %s discarded" name)
      name)))

;; ====== THE CANVAS SAYS SO ======

(defun agent-ui-review--header ()
  "A canvas's header while types the agent made wait for review (nil else):
fitted to its window's width as it's drawn (`agent-ui-review--header-line')."
  (when-let* ((files (agent-ui-staged-files)))
    `(:eval (agent-ui-review--header-line ',(mapcar #'file-name-base files)
                                          (1- (window-max-chars-per-line nil 'header-line))))))

(defun agent-ui-review--header-line (names width)
  "The header saying NAMES, the types made by the agent, wait for review.
It is WIDTH columns wide: shortened as it must be, their names cut, its
key kept (it was cut off in a narrow pane)."
  (let* ((key (substitute-command-keys "\\<agent-ui-canvas-mode-map>\\[agent-ui-review]"))
         (count (format "%d type%s" (length names) (if (cdr names) "s" "")))
         (list (string-join names ", "))
         (fit (lambda (text hint)
                (and (<= (+ 1 (string-width text) (string-width hint)) width)
                     (concat " " (propertize text 'face 'agent-ui-warning) hint))))
         (room (- width 1 (string-width (concat count " to review: ")) (string-width (concat "   " key " review")))))
    (or (funcall fit (format "%s made by the agent to review: %s" count list) (concat "   " key " review"))
        (and (>= room 8)
             (funcall fit (format "%s to review: %s" count (agent-ui-truncate list room)) (concat "   " key " review")))
        (funcall fit (format "%s to review" count) (concat "  " key))
        (funcall fit (format "%d to review" (length names)) (concat " " key))
        (concat " " key))))

(defun agent-ui-review--canvas-header ()
  "The current canvas's header: none while no type waits (not an empty line)."
  (setq header-line-format (agent-ui-review--header)))

(defun agent-ui-review--canvas-headers ()
  "Set the review header of every canvas."
  (dolist (canvas (agent-ui-canvases))
    (with-current-buffer canvas (agent-ui-review--canvas-header))))


(defun agent-ui-review--staged (name)
  "The agent staged NAME: said, the list and the headers redrawn."
  (agent-ui-review--refresh)
  (message "Agent UI: the agent made a type, %s; review it with M-x agent-ui-review (R in its canvas): it runs once you keep it" name))



(provide 'agent-ui-review)

;;; agent-ui-review.el ends here
