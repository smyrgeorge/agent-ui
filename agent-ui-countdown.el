;;; agent-ui-countdown.el --- The countdown component  -*- lexical-binding: t; -*-

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

;; Agent UI's countdown: time that matters while waiting, ticking on the
;; canvas.
;;
;; SINCE a start: the time elapsed (a long job).  UNTIL an end: the time left
;; (a deploy window, a rate limit's reset), in the warning colour its last
;; WARN seconds; past it: "ended 2m 05s ago", never negative.  Each a
;; timestamp ("2026-11-10T18:30:00Z"), epoch seconds, or seconds from now (a
;; number under a billion: until in that many, since that many ago), made a
;; time when shown (redrawn, it doesn't start again).  Animated: redrawn while
;; its canvas is in a window only (`agent-ui-animated'), when its time as
;; shown changes.
;;
;;   Rate limit resets  4m 12s left
;;   Build running      12m 40s

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(autoload 'parse-iso8601-time-string "parse-time")
(autoload 'svg-create "svg")
(autoload 'svg-rectangle "svg")
(autoload 'svg-text "svg")
(require 'agent-ui-core)

(defun agent-ui-countdown--time (value)
  "VALUE (a timestamp, epoch seconds, or seconds from now) as epoch seconds.
A relative one is left as it is (made a time when shown); nil if it
isn't a time."
  (cond ((numberp value) value)
        ((stringp value) (agent-ui--time-seconds value))
        (t nil)))

(defun agent-ui-countdown--check (props)
  "Signal an error unless PROPS describe a valid countdown."
  (let ((since (plist-get props :since))
        (until (plist-get props :until)))
    (unless (xor since until)
      (agent-ui--fail "countdown: give since (a start: the time elapsed) or until (an end: the time left)"))
    (unless (agent-ui-countdown--time (or since until))
      (agent-ui--fail "countdown: %s is a timestamp (\"2026-11-10T18:30:00Z\"), epoch seconds, or seconds from now"
                      (if since "since" "until")))
    (when (and (plist-get props :warn) (< (plist-get props :warn) 0))
      (agent-ui--fail "countdown: warn is seconds before the end, 0 or more")))
  props)

(defun agent-ui-countdown--prepare (component)
  "COMPONENT as it's kept.
Its since or until a time (seconds from now made one, from the clock
now; a timestamp in epoch seconds)."
  (let ((component (copy-sequence component))
        (now (funcall agent-ui-clock)))
    (dolist (key '(:since :until))
      (when-let* ((value (plist-get component key))
                  (time (agent-ui-countdown--time value)))
        (setq component (plist-put component key
                                 (if (and (numberp value) (< value 1e9))
                                     (if (eq key :since) (- now value) (+ now value))
                                   time)))))
    component))

(defun agent-ui-countdown--state (props)
  "PROPS' state now: (TEXT FACE WORD).
The time and what it is: elapsed, left, or \"ended ... ago\"."
  (let* ((now (funcall agent-ui-clock))
         ;; Seconds from now still (drawn without being shown: a render):
         ;; from now.
         (at (lambda (key sign)
               (let ((value (plist-get props key)))
                 (if (and (numberp value) (< value 1e9))
                     (+ now (* sign value))
                   (agent-ui-countdown--time value)))))
         (since (funcall at :since -1))
         (until (funcall at :until 1)))
    (cond
     (since (list (agent-ui-format-duration (max 0 (- now since))) 'bold "elapsed"))
     ((>= now until) (list (format "ended %s ago" (agent-ui-format-duration (- now until))) 'agent-ui-muted nil))
     (t (let ((left (- until now)))
          (list (agent-ui-format-duration left)
                (if (and (plist-get props :warn) (<= left (plist-get props :warn))) 'agent-ui-warning 'bold)
                "left"))))))

(defun agent-ui-countdown--text (props ctx &optional state)
  "PROPS' countdown as text, for CTX, its STATE (else now's).
Its label, then the time and its word: the time kept whole, the label cut
first (4 columns at least, else left out), then the word left out (the
whole line was cut: \"Rate limit resets in  4…\")."
  (pcase-let* ((`(,time ,face ,word) (or state (agent-ui-countdown--state props)))
               (width (plist-get ctx :width))
               (label (plist-get props :label))
               (word (and word (plist-get props :until)
                          (<= (+ (string-width time) 1 (string-width word)) width)
                          word))
               (shown (concat (propertize time 'face face) (if word (concat " " word) "")))
               (room (- width (string-width shown) 2)))
    (if (and label (>= room (min 4 (string-width label))))
        (concat (propertize (agent-ui-truncate label room) 'face 'agent-ui-muted) "  " shown)
      (agent-ui-truncate shown width))))

(defun agent-ui-countdown--gui (props ctx &optional state)
  "PROPS' countdown as an image, for CTX, its STATE (else now's)."
  (pcase-let* ((state (or state (agent-ui-countdown--state props)))
               (`(,time ,face ,word) state)
               (cw (plist-get ctx :char-width))
               (lh (plist-get ctx :line-height))
               ;; 28 columns, wider for its label where the pane has room.
               (w (min (* cw (plist-get ctx :width))
                       (max (* 28 cw) (ceiling (+ (* 2 cw) (* 0.5 lh (string-width (or (plist-get props :label) ""))))))))
               (room (- w (* 2 cw)))
               ;; Its label wrapped to the card (its font 0.8 of a line, a
               ;; character ~0.5 of a line wide): it was cut, its rest nowhere.
               (labels (when-let* ((label (plist-get props :label)))
                         (if (<= (string-width label) (floor room (* 0.5 lh)))
                             (list label)
                           (agent-ui-wrap-lines label (max 1 (floor room (* 0.5 lh)))))))
               (extra (max 0 (1- (length labels))))
               (h (* (+ 3 extra) lh))
               ;; The time big, smaller if it doesn't fit; its word beside it
               ;; where there's room, else left out (they overlapped).
               (size (agent-ui-svg-fit-size time (* (if word 1.4 1.0) lh) room))
               (word-size (* 0.8 lh))
               (word (and word (<= (+ (agent-ui-svg-text-width time size) cw
                                      (agent-ui-svg-text-width word word-size))
                                   room)
                          word))
               (font (agent-ui--svg-font))
               (svg (svg-create w h)))
    (if (< (plist-get ctx :width) 16)
        (agent-ui-countdown--text props ctx state)
      (svg-rectangle svg 0 0 w h :rx 6
                     :fill (agent-ui-blend (agent-ui-background) (agent-ui-color 'default) 0.07))
      (cl-loop for label in labels
               for i from 0
               do (svg-text svg label
                            :x cw :y (* (+ 0.95 i) lh) :font-size (round (* 0.8 lh)) :font-family font
                            :fill (agent-ui-color 'agent-ui-muted)))
      (svg-text svg time :x cw :y (* (+ 2.4 extra) lh) :font-size (round size) :font-weight "bold"
                :font-family font :fill (agent-ui-color (if (eq face 'bold) 'default face)))
      (when word
        (svg-text svg word :x (- w cw) :y (* (+ 2.4 extra) lh) :text-anchor "end" :font-size (round word-size)
                  :font-family font :fill (agent-ui-color 'agent-ui-muted)))
      (propertize "countdown" 'display (agent-ui-svg-image svg)))))

(defun agent-ui-countdown--drawn (draw props ctx)
  "PROPS' countdown drawn by DRAW (its text's or image's), for CTX.
In an animation's frames, drawn anew only when its time as shown changes
\(`agent-ui-memo'): once a second, once a minute an hour past its end (a
new image every 0.15 s, for hours after it ended)."
  (let ((state (agent-ui-countdown--state props)))
    (agent-ui-memo (list draw props) ctx (lambda () (funcall draw props ctx state)) state)))

(agent-ui-define countdown
  "Time that matters while waiting, ticking: the time elapsed, or left.
SINCE a start (the time elapsed: a long job) or UNTIL an end (the time left:
a deploy window, a rate limit's reset), each a timestamp, epoch seconds or
seconds from now; LABEL; WARN seconds before the end in the warning colour.
Past the end: \"ended 2m ago\"."
  :props ((since any "A start: a timestamp, epoch seconds, or seconds ago")
          (until any "An end: a timestamp, epoch seconds, or seconds from now")
          (label string "What it counts")
          (warn number "Seconds before the end it's in the warning colour"))
  :example (:title "Rate limit" :label "Resets in" :until 252 :warn 60)
  :animated t
  :check #'agent-ui-countdown--check
  :prepare #'agent-ui-countdown--prepare
  :text (lambda (props ctx) (agent-ui-countdown--drawn #'agent-ui-countdown--text props ctx))
  :gui (lambda (props ctx) (agent-ui-countdown--drawn #'agent-ui-countdown--gui props ctx)))


(provide 'agent-ui-countdown)

;;; agent-ui-countdown.el ends here
