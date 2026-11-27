;;; agent-ui-html.el --- The html component  -*- lexical-binding: t; -*-

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

;; Agent UI's web page: an HTML file (or a URL) as a card, its title and
;; the start of its text.
;;
;; RET or a click opens it (`agent-ui-open-page-function': by default,
;; `browse-url').  Its
;; text read from the file (scripts, styles and tags left out), not from the
;; web: a URL's card is its address.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)

(defcustom agent-ui-open-page-function #'agent-ui-html-browse
  "Opens a page a component shows, given a file's name or a URL."
  :type 'function :group 'agent-ui)

(defcustom agent-ui-html-max-bytes 500000
  "The most of an HTML file read for its card."
  :type 'natnum :group 'agent-ui)

(defun agent-ui-html-browse (page)
  "Open PAGE (a file's name or a URL) in the browser."
  (if (string-match-p "\\`[a-z]+://" page)
      (browse-url page)
    (browse-url-of-file page)))

(defconst agent-ui-html--entities
  '(("nbsp" . " ") ("lt" . "<") ("gt" . ">") ("quot" . "\"") ("apos" . "'") ("amp" . "&")
    ("mdash" . "—") ("ndash" . "–") ("hellip" . "…") ("copy" . "©") ("reg" . "®") ("trade" . "™")
    ("laquo" . "«") ("raquo" . "»") ("lsquo" . "‘") ("rsquo" . "’") ("ldquo" . "“") ("rdquo" . "”")
    ("bull" . "•") ("middot" . "·") ("times" . "×") ("divide" . "÷") ("deg" . "°") ("plusmn" . "±")
    ("euro" . "€") ("pound" . "£") ("yen" . "¥") ("cent" . "¢") ("sect" . "§") ("para" . "¶")
    ("larr" . "←") ("rarr" . "→") ("uarr" . "↑") ("darr" . "↓") ("le" . "≤") ("ge" . "≥") ("ne" . "≠")
    ("check" . "✓") ("shy" . "") ("zwj" . "") ("zwnj" . "") ("thinsp" . " ") ("ensp" . " ") ("emsp" . " "))
  "HTML's common named entities, as text.")

(defun agent-ui-html--entities (text)
  "TEXT with its entities read once (&amp;lt; is &lt;: it was read twice):
&#N;, &#xN; and the common named ones; others as they are."
  (let ((case-fold-search nil))
    (replace-regexp-in-string
     "&\\(?:#\\([0-9]\\{1,7\\}\\)\\|#[xX]\\([0-9a-fA-F]\\{1,6\\}\\)\\|\\([a-zA-Z][a-zA-Z0-9]*\\)\\);"
     (lambda (m)
       (let ((n (cond ((match-string 1 m) (string-to-number (match-string 1 m)))
                      ((match-string 2 m) (string-to-number (match-string 2 m) 16)))))
         (cond (n (if (and (> n 0) (<= n #x10FFFF)) (string n) m))
               ((cdr (assoc (match-string 3 m) agent-ui-html--entities)))
               (t m))))
     text t t)))

(defun agent-ui-html--text-of (html)
  "HTML's title and its text: (TITLE . TEXT).
Scripts, styles and tags are left out, its entities read, its spaces one."
  (with-temp-buffer
    (insert html)
    (let ((case-fold-search t)
          (title nil))
      ;; Its title and its blocks found by their tags, not matched whole: a
      ;; lazy regexp over a block of a few hundred KB overflowed the regexp
      ;; matcher's stack.
      (goto-char (point-min))
      (when (re-search-forward "<title[^>]*>" nil t)
        (let ((start (point)))
          (when (search-forward "</title>" nil t)
            (setq title (buffer-substring-no-properties start (match-beginning 0))))))
      ;; Scripts, styles, the head and comments gone: one the read cut runs
      ;; to the end (a head left open stays, its close often left out).
      (pcase-dolist (`(,open ,close ,to-end) '(("<script\\b" "</script>" t) ("<style\\b" "</style>" t)
                                               ("<head\\b" "</head>" nil) ("<!--" "-->" t)))
        (goto-char (point-min))
        (while (re-search-forward open nil t)
          (let ((start (match-beginning 0))
                (end (if (search-forward close nil t) (point) (and to-end (point-max)))))
            (if (not end)
                (goto-char (point-max))
              (delete-region start end)
              (insert " ")))))
      (setq html (buffer-string))
      ;; Blocks as lines; tags gone.
      (setq html (replace-regexp-in-string "<\\(?:br\\|/p\\|/h[1-6]\\|/li\\|/tr\\|/div\\)\\b[^>]*>" "\n" html))
      (setq html (replace-regexp-in-string "<[^>]*>" " " html))
      ;; Its entities read once; its title on one line (its newlines kept, it
      ;; was two).
      (cl-flet ((spaces (s) (string-trim (replace-regexp-in-string "[ \t\r]+" " " s))))
        (cons (and title (spaces (replace-regexp-in-string "[\n\r]+" " " (agent-ui-html--entities title))))
              (string-join (seq-remove #'string-empty-p
                                       (mapcar #'spaces (split-string (agent-ui-html--entities html) "\n")))
                           "\n"))))))

(defun agent-ui-html--text (props ctx)
  "PROPS' page as text, for CTX."
  (let* ((file (plist-get props :file))
         (page (or file (plist-get props :url)))
         (width (plist-get ctx :width))
         ;; Why it can't be read (a folder too: reading it failed).
         (why (and file (cond ((not (file-readable-p file)) "not found")
                              ((not (file-regular-p file)) "not a file"))))
         (read (and file (not why)
                    (agent-ui-html--text-of
                     (with-temp-buffer
                       (let ((coding-system-for-read 'utf-8))
                         (insert-file-contents file nil 0 agent-ui-html-max-bytes))
                       (buffer-string)))))
         (title (or (car read) (if file (file-name-nondirectory file) page)))
         (open (lambda () (funcall agent-ui-open-page-function page))))
    (concat
     (propertize "◫ " 'face 'agent-ui-accent)
     (agent-ui-button (propertize (agent-ui-truncate title (- width 2)) 'face 'bold) open "RET: open the page")
     "\n"
     (propertize (agent-ui-truncate (abbreviate-file-name page) (if why (- width 4 (string-width why)) width))
                 'face 'agent-ui-muted)
     (cond
      (why (propertize (format "  (%s)" why) 'face 'agent-ui-muted))
      ((and read (not (string-empty-p (cdr read))))
       (concat "\n" (string-join (seq-take (split-string (agent-ui-wrap (cdr read) width) "\n")
                                           (plist-get props :lines))
                                 "\n")))
      (t "")))))

(agent-ui-define html
  "A web page as a card: its title and the start of its text, from an HTML
FILE (relative to your directory) or a URL (its address only). RET opens it
for the user (in the browser, unless Emacs is set otherwise). For a report
or a page you made, to look at closer."
  :props ((file file "An HTML file")
          (url string "A web page's address")
          (lines integer "How many lines of its text the card shows" :default 4))
  :example (:file "coverage/index.html" :lines 3)
  :check (lambda (props)
           (unless (xor (plist-get props :file) (plist-get props :url))
             (agent-ui--fail "html: give a file or a url"))
           (unless (<= 0 (plist-get props :lines) 50)
             (agent-ui--fail "html: lines is 0 to 50"))
           props)
  :text #'agent-ui-html--text)


(provide 'agent-ui-html)

;;; agent-ui-html.el ends here
