;;; agent-ui-dashboards.el --- Project dashboards, kept in a repository  -*- lexical-binding: t; -*-

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

;; Agent UI's project dashboards: each kept in its project's repository, a
;; file of its own, opened on demand, its data fetched afresh each time it
;; opens (none is kept).
;;
;; PROJECT/.agent-ui/dashboards/NAME.el holds one form:
;;
;;   (agent-ui-dashboard
;;    :version 1
;;    :ui (:type "panel" :id "service" :title "Service" :layout "row"
;;         :children ((:type "table" :id "ci" :title "CI" :columns ("Run" "Status"))
;;                    (:type "gauge" :id "dirty" :title "Unsaved buffers" :max 20)))
;;    :every 30
;;    :fetch (lambda (dashboard) ...))
;;
;; :ui is what it shows, a component (usually a panel of components) with its
;; data left out: read as it is, never evaluated, so it's drawn before its
;; code is trusted.  :every, :fetch, :start and :stop are its script, which
;; fills it.  The UI and its code in one file: ids defined and used in one
;; place.  `agent-ui-dashboard-check' checks a file as the agent writes it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'agent-ui-persist)
(require 'agent-ui-trust)

(declare-function nerd-icons-mdicon "ext:nerd-icons")
(declare-function project-root "project")

;; ====== VARIABLES ======

(defcustom agent-ui-dashboard-directory ".agent-ui/dashboards/"
  "Where a project's dashboards are, in its root."
  :type 'string :group 'agent-ui)

(defconst agent-ui-dashboard-version 1
  "The dashboard files this Agent UI reads: their :version.")

(defconst agent-ui-dashboards--keys '(:version :ui :every :fetch :start :stop)
  "What a dashboard's form has.")

(defvar agent-ui-dashboard-name-function #'agent-ui-dashboard-default-canvas-name
  "Function giving a dashboard's canvas's name, called with its name and root.
Another module names its own (the agent workspace: an agent's, \"tests ·
ada\").")

(defvar agent-ui-dashboard-display-function #'display-buffer
  "Function showing a dashboard's canvas opened for an agent.
Called with a dashboard's canvas opened for an agent (not selected) to show
it; one that shows nothing leaves it hidden (the agent workspace's stage
shows an agent's).")

(defconst agent-ui-dashboard-blocking
  '(shell-command-to-string shell-command call-process call-process-region
    call-process-shell-command process-file process-lines
    url-retrieve-synchronously sleep-for)
  "Calls that wait, with Emacs frozen meanwhile.
Never in a dashboard's script (it runs every so often, in the user's Emacs).
`agent-ui-dashboard-run' instead.")

;; ====== THE FORM ======

(defmacro agent-ui-dashboard (&rest props)
  "A project dashboard (see the top of this file).
PROPS has its :ui as it is (data, not evaluated), the others evaluated
\(:fetch a function...)."
  (cl-loop for (key _) on props by #'cddr
           unless (memq key agent-ui-dashboards--keys)
           do (error "Agent UI: agent-ui-dashboard has %S: it has %s" key
                     (mapconcat (lambda (k) (substring (symbol-name k) 1)) agent-ui-dashboards--keys ", ")))
  `(list ,@(cl-loop for (key value) on props by #'cddr
                    append (list key (if (eq key :ui) (list 'quote value) value)))))

;; ====== A PROJECT'S DASHBOARDS ======

(defun agent-ui-dashboard-root (&optional dir)
  "The project of DIR, its root, or nil if neither.
DIR defaults to `default-directory'.  It is the folder holding its dashboards
\(`agent-ui-dashboard-directory'), else its project's root."
  (let ((dir (expand-file-name (or dir default-directory))))
    (when-let* ((root (or (locate-dominating-file dir agent-ui-dashboard-directory)
                          (when-let* (((fboundp 'project-current))
                                      (project (project-current nil dir)))
                            (project-root project)))))
      (file-name-as-directory (expand-file-name root)))))

(defun agent-ui-dashboards (&optional dir)
  "The names of the dashboards of DIR's project, sorted.
See `agent-ui-dashboard-root'.  Nil if it has none."
  (when-let* ((root (agent-ui-dashboard-root dir))
              (folder (expand-file-name agent-ui-dashboard-directory root))
              ((file-directory-p folder)))
    (sort (mapcar #'file-name-base (directory-files folder nil "\\`[^.#].*\\.el\\'"))
          #'string<)))

(defun agent-ui-dashboard-file (name &optional dir)
  "The file of dashboard NAME, of DIR's project.
NAME ending in .el, a file taken as it is (relative to DIR).  An error
naming the project's dashboards if there's none."
  (let* ((root (agent-ui-dashboard-root dir))
         (file (cond ((string-suffix-p ".el" name) (expand-file-name name (or dir default-directory)))
                     (root (expand-file-name (concat name ".el")
                                             (expand-file-name agent-ui-dashboard-directory root))))))
    (unless (and file (file-readable-p file))
      (let ((dashboards (and root (agent-ui-dashboards root))))
        (agent-ui--fail "dashboard %s: %s" name
                        (cond (dashboards (format "not one of this project's: %s" (string-join dashboards ", ")))
                              (root (format "this project has no dashboards (%s)" agent-ui-dashboard-directory))
                              (t "no project here")))))
    file))

;; ====== READING ONE ======

(defun agent-ui-dashboards--bytes (file)
  "FILE's content, its bytes (a unibyte string)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun agent-ui-dashboards--forms (bytes what)
  "The top-level forms of BYTES (a file's, UTF-8), read, not evaluated.
An error for WHAT saying where it doesn't read."
  (with-temp-buffer
    (insert (decode-coding-string bytes 'utf-8))
    (goto-char (point-min))
    (let (forms)
      (condition-case err
          ;; Lisp's comments skipped (a plain buffer has none: a comment
          ;; after the last form was read as one, cut short).
          (with-syntax-table emacs-lisp-mode-syntax-table
            (while (progn (forward-comment (buffer-size)) (not (eobp)))
              (push (read (current-buffer)) forms)))
        (end-of-file
         (agent-ui--fail "%s: its file ends inside a form (a parenthesis or a quote missing?)" what))
        (error (agent-ui--fail "%s: its file doesn't read, at line %d: %s"
                               what (line-number-at-pos) (error-message-string err))))
      (nreverse forms))))

(defun agent-ui-dashboard-read (file)
  "FILE, a dashboard's (see the top of this file), read, never evaluated.
The value is a plist, :name (its file's), :file, :ui (its component, right
as show has it), :every, :form (the whole, for its script) and :hash (the
sha256 of the content read: its code, as let run).  An error saying
what's wrong with it."
  (let* ((name (file-name-base file))
         (what (format "dashboard %s" name))
         (bytes (agent-ui-dashboards--bytes file))
         (forms (agent-ui-dashboards--forms bytes what))
         (form (car forms))
         (props (cdr-safe form)))
    (unless (and (= (length forms) 1) (eq (car-safe form) 'agent-ui-dashboard))
      (agent-ui--fail "%s: its file holds one form, (agent-ui-dashboard :ui ... :fetch ...), not %s"
                      what (if (= (length forms) 1)
                               (truncate-string-to-width (format "%S" form) 50 nil nil "…")
                             (format "%d forms" (length forms)))))
    (unless (and (listp props) (cl-evenp (length props)))
      (agent-ui--fail "%s: agent-ui-dashboard takes keys and their values (:ui ..., :fetch ...)" what))
    (cl-loop for (key _) on props by #'cddr
             unless (memq key agent-ui-dashboards--keys)
             do (agent-ui--fail "%s has %s: a dashboard has %s" what (agent-ui--show-value key)
                                (mapconcat (lambda (k) (substring (symbol-name k) 1)) agent-ui-dashboards--keys ", ")))
    (let ((version (plist-get props :version)))
      (unless (memql version (list nil agent-ui-dashboard-version))
        (agent-ui--fail "%s is version %s: this Agent UI reads version %d"
                        what (agent-ui--show-value version) agent-ui-dashboard-version)))
    (let ((every (plist-get props :every)))
      (unless (or (null every) (and (numberp every) (> every 0)))
        (agent-ui--fail "%s: every is how many seconds between fetches, a number above 0, not %s"
                        what (agent-ui--show-value every))))
    (let ((ui (plist-get props :ui)))
      (unless (agent-ui--plist-p ui)
        (agent-ui--fail "%s: its :ui is what it shows, a component: (:type \"panel\" :id ... :children (...))" what))
      (condition-case err
          (agent-ui--checked ui)
        (agent-ui-error (agent-ui--fail "%s: its :ui: %s" what (agent-ui-error-message err))))
      (list :name name :file file :ui ui :every (plist-get props :every) :form form
            :hash (secure-hash 'sha256 bytes)))))

;; ====== CHECKING ONE ======

(defun agent-ui-dashboards--blocking (file)
  "The calls in FILE's code that wait, outside its comments and strings.
They are `agent-ui-dashboard-blocking', and `accept-process-output' with no
timeout: \"line N: NAME ...\" each."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (with-syntax-table emacs-lisp-mode-syntax-table
      (let ((re (concat "\\(?:(\\|#'\\)\\("
                        (regexp-opt (mapcar #'symbol-name (cons 'accept-process-output agent-ui-dashboard-blocking)))
                        "\\)\\_>"))
            (found nil))
        (goto-char (point-min))
        (while (re-search-forward re nil t)
          (let ((start (match-beginning 0))
                (call (match-string 1)))
            (unless (or (nth 8 (save-excursion (syntax-ppss start)))
                        ;; With a timeout, it returns.
                        (and (equal call "accept-process-output")
                             (eq (char-after start) ?\()
                             (>= (length (ignore-error (end-of-file invalid-read-syntax)
                                           (save-excursion (goto-char start)
                                                           (read (current-buffer)))))
                                 3)))
              (push (format "line %d: %s waits, Emacs frozen meanwhile: use agent-ui-dashboard-run"
                            (line-number-at-pos start) call)
                    found))))
        (nreverse found)))))

(defun agent-ui-dashboards--compile (file name)
  "FILE's code (dashboard NAME's) compiled, with its warnings.
An error if it doesn't compile; their lines FILE's.  In a function: at top
level, a lambda's body isn't looked at (its warnings unsaid)."
  (let ((temp (make-temp-file "agent-ui-dashboard-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp
            (setq-local coding-system-for-write 'utf-8)
            (insert ";;; -*- lexical-binding: t; -*-\n(defun agent-ui-dashboards--checking ()\n")
            (let ((coding-system-for-read 'utf-8))
              (insert-file-contents file))
            (goto-char (point-max))
            (insert "\n)\n"))
          ;; The types the agent makes' compiler (loaded when first used).
          (agent-ui--require 'agent-ui-staging)
          (agent-ui--byte-compile temp 2 (format "dashboard %s" name)))
      (delete-file temp))))

(defun agent-ui-dashboard-check (file)
  "FILE, a dashboard's, checked as the agent writes it, nothing run.
It is read (its :ui as show checks it), compiled if its code may run (an
error refuses it; its warnings said), its waiting calls found.  Compiling
runs its macros \(`eval-when-compile' too): one not trusted
\(`agent-ui-dashboard-trusted-p') is not compiled, :not-compiled saying why.
Returns (:ok t :dashboard NAME :file FILE :type TYPE :every N :warnings [...]
:blocking [...] :not-compiled WHY); an error saying what's wrong."
  (let* ((dashboard (agent-ui-dashboard-read file))
         (name (plist-get dashboard :name))
         (trusted (agent-ui-dashboard-trusted-p file))
         (cookie (with-temp-buffer
                   (insert-file-contents file nil 0 300)
                   (string-match-p "lexical-binding: *t" (buffer-substring (point-min) (line-end-position)))))
         (warnings (append (unless cookie
                             (list "line 1: no -*- lexical-binding: t; -*- there (its code is read so anyway)"))
                           (when trusted (agent-ui-dashboards--compile file name)))))
    (append (list :ok t :dashboard name :file file
                  :type (format "%s" (plist-get (plist-get dashboard :ui) :type)))
            (when (plist-get dashboard :every) (list :every (plist-get dashboard :every)))
            (list :warnings (vconcat warnings)
                  :blocking (vconcat (agent-ui-dashboards--blocking file)))
            (unless trusted
              (list :not-compiled
                    "compiling runs its macros, and its code isn't trusted yet: compiled once the user lets it run")))))

(declare-function agent-ui--byte-compile "agent-ui-staging")
(declare-function agent-ui-pdf-unique-file "agent-ui-snapshot")

;; ====== OPENING ONE ======
;; On demand: a canvas of its own (no session's), named after the dashboard and
;; its project, in its own pane (`display-buffer' places it), selected; its
;; directory the project's root (its commands run there, its files are
;; there).  Its :ui drawn as it is, empty; its script fills it.  Opened again
;; while it's open: its pane shown.  q kills it; opened later (after a
;; restart too), it's read again and fetched anew: nothing of it is kept.

(cl-defstruct (agent-ui-dashboards--state (:constructor agent-ui-dashboards--make)
                                     (:conc-name agent-ui-dashboards--))
  "An open project dashboard, in its canvas (`agent-ui-dashboards--state'): what its
script is given as DASHBOARD.  Its :ui (read), its script (its form evaluated),
its fetches' timer, its commands running, its last error."
  name file root canvas ui script timer processes error
  ;; A fetch missed while it was hidden; what's wrong now, by key ((KEY TEXT
  ;; . COMPONENT) ...: said on COMPONENT's title, else on its line); the queries
  ;; running, by key (:process :start :component); the titles of its components
  ;; marked (loading, failed), as they were ((ID . TITLE) ...); the timer
  ;; saying how long they've been loading; the queries that ended once, by
  ;; key (their component shows something: a refresh is said loading late).
  stale errors (running (make-hash-table :test #'equal)) titles ticker
  (loaded (make-hash-table :test #'equal))
  ;; When its :fetch last ran (`float-time'), nil before; when its queries
  ;; last all ended, its data in (a query can take longer than its :every).
  fetched settled
  ;; The sha256 of its file as read: the code it runs, the one let run.
  sha256
  ;; Its file's form, while its code waits to be asked about (opened by an
  ;; agent): asked once the user selects it.
  waiting)

(defvar-local agent-ui-dashboards--state nil
  "In a project dashboard's canvas: its `agent-ui-dashboards--state'.")

(defvar agent-ui-dashboard-open-hook nil
  "Run in a project dashboard's canvas once it has opened.
Not when it's only shown again: a notice offering its PDF, say.")

(defun agent-ui-dashboard-canvas-name (name root)
  "The name of dashboard NAME's canvas, of the project at ROOT.
See `agent-ui-dashboard-name-function'."
  (funcall agent-ui-dashboard-name-function name root))

(defun agent-ui-dashboard-default-canvas-name (name root)
  "\"NAME (PROJECT)\", PROJECT ROOT's folder (no session's: tied to none)."
  (format "%s (%s)" name (file-name-nondirectory (directory-file-name root))))

;; ====== PICKING ONE ======
;; `agent-ui-open-dashboard''s list: a row each, in columns lined up, fitted
;; to the minibuffer's width: its icon, its name, its title (what it shows,
;; cut with …, left out when there's no room), how often it's fetched, open
;; or not; under the project's name and its dashboards' folder.  One whose file
;; can't be read: its error instead, dimmed (opening it says it too).

(defconst agent-ui-dashboards--gap 2
  "The columns between two of the dashboard picker's.")

(defun agent-ui-dashboards--every-text (seconds)
  "How often a dashboard fetched every SECONDS is: \"every 2 min\"; \"\" for nil."
  (cond ((null seconds) "")
        ((< seconds 60) (format "every %g s" seconds))
        ((< seconds 3600) (format "every %g min" (/ (round seconds 6) 10.0)))
        (t (format "every %g h" (/ (round seconds 360) 10.0)))))

(defun agent-ui-dashboards--picker-facts (root names)
  "What the dashboard picker shows of ROOT's dashboards NAMES.
Read, never evaluated.  The value is ((NAME :title TITLE :every TEXT :open
BOOL) or (NAME :error TEXT)...)."
  (mapcar (lambda (name)
            (condition-case err
                (let ((read (agent-ui-dashboard-read
                             (expand-file-name (concat name ".el") (expand-file-name agent-ui-dashboard-directory root))))
                      (open (get-buffer (agent-ui-canvas-buffer-name (agent-ui-dashboard-canvas-name name root)))))
                  (list name
                        :title (let ((title (plist-get (plist-get read :ui) :title)))
                                 (if (stringp title) (string-trim (replace-regexp-in-string "[\n\r]+" " " title)) ""))
                        :every (agent-ui-dashboards--every-text (plist-get read :every))
                        :open (and open (buffer-local-value 'agent-ui-dashboards--state open) t)))
              (agent-ui-error (list name :error (agent-ui-error-message err)))
              (error (list name :error (error-message-string err)))))
          names))

(defun agent-ui-dashboards--icon (dim)
  "A dashboard's icon in the picker, two columns wide.
It is nerd-icons' dashboard where it and its font are there (in the GUI),
else ▦; DIM, dimmed."
  (let* ((nerd (and (display-graphic-p)
                    (require 'nerd-icons nil t)
                    (find-font (font-spec :family (or (bound-and-true-p nerd-icons-font-family)
                                                      "Symbols Nerd Font Mono")))
                    ;; Its icon there (an older nerd-icons: an error).
                    (fboundp 'nerd-icons-mdicon-data)
                    (assoc "nf-md-view_dashboard" (nerd-icons-mdicon-data))
                    (nerd-icons-mdicon "nf-md-view_dashboard")))
         (icon (copy-sequence (or nerd "▦"))))
    (add-face-text-property 0 (length icon) (if dim 'agent-ui-muted 'agent-ui-accent) t icon)
    (let ((icon (concat icon (make-string (max 0 (- 2 (string-width icon))) ?\s))))
      (if (fboundp 'agent-ui-even-glyphs) (agent-ui-even-glyphs icon) icon))))

(defun agent-ui-dashboards--picker-rows (facts width)
  "The dashboard picker's rows for FACTS, WIDTH columns at most.
FACTS is from `agent-ui-dashboards--picker-facts'.  The rows are ((NAME
CANDIDATE PREFIX SUFFIX)...), as an `:affixation-function' gives them (see
above)."
  (let* ((gap agent-ui-dashboards--gap)
         (pad (lambda (text w) (concat text (make-string (max 0 (- w (string-width text))) ?\s))))
         (widest (lambda (key) (apply #'max 0 (mapcar (lambda (fact)
                                                       (let ((value (plist-get (cdr fact) key)))
                                                         (if (stringp value) (string-width value) 0)))
                                                     facts))))
         (names (apply #'max 0 (mapcar (lambda (fact) (string-width (car fact))) facts)))
         (every (funcall widest :every))
         (open (if (seq-some (lambda (fact) (plist-get (cdr fact) :open)) facts) (string-width "open") 0))
         ;; The icon, its name, then what's after the title.
         (start (+ 2 names))
         (tail (+ (if (> every 0) (+ gap every) 0) (if (> open 0) (+ gap open) 0)))
         (titled (let ((w (min (funcall widest :title) (- width start gap tail))))
                   (if (< w 4) 0 w))))
    (mapcar
     (lambda (fact)
       (let* ((name (car fact))
              (wrong (plist-get (cdr fact) :error))
              (parts (if wrong
                         (let ((room (- width start gap)))
                           (and (>= room 4) (list (agent-ui-truncate wrong room))))
                       (append
                        (and (> titled 0)
                             (list (funcall pad (agent-ui-truncate (plist-get (cdr fact) :title) titled) titled)))
                        (and (> every 0)
                             (list (funcall pad (propertize (plist-get (cdr fact) :every) 'face 'agent-ui-muted) every)))
                        (and (plist-get (cdr fact) :open)
                             (list (propertize "open" 'face 'agent-ui-success))))))
              (suffix (string-trim-right
                       (concat (make-string (- names (string-width name)) ?\s)
                               (mapconcat (lambda (part) (concat (make-string gap ?\s) part)) parts ""))))
              (candidate (if wrong (propertize name 'face 'agent-ui-muted) name)))
         (when wrong
           (add-face-text-property 0 (length suffix) 'agent-ui-muted t suffix))
         (list name candidate (agent-ui-dashboards--icon wrong) suffix)))
     facts)))

(defun agent-ui-dashboards--read-name ()
  "A dashboard of the current project, picked from its rows (see above)."
  (let* ((root (agent-ui-dashboard-root))
         (dashboards (agent-ui-dashboards)))
    (unless dashboards
      (user-error (if root
                      (format "This project has no dashboards (%s)" agent-ui-dashboard-directory)
                    "No project here")))
    (let* ((facts (agent-ui-dashboards--picker-facts root dashboards))
           (group (concat (file-name-nondirectory (directory-file-name root)) " · "
                          (directory-file-name agent-ui-dashboard-directory)))
           (rows nil)
           (completion-extra-properties
            (list :affixation-function
                  (lambda (names)
                    (let ((width (1- (window-body-width (or (active-minibuffer-window) (minibuffer-window))))))
                      (unless (eq (car rows) width)
                        (setq rows (cons width (agent-ui-dashboards--picker-rows facts width)))))
                    (mapcar (lambda (name)
                              (pcase (assoc name (cdr rows))
                                (`(,_ ,candidate ,prefix ,suffix) (list candidate prefix suffix))
                                (_ (list name "" ""))))
                            names))
                  :group-function (lambda (name transform) (if transform name group))
                  ;; By name, as they're listed.
                  :display-sort-function #'identity
                  :cycle-sort-function #'identity)))
      (completing-read "Dashboard: " dashboards nil t))))

(defun agent-ui-open-dashboard (name &optional dir noselect here)
  "Open dashboard NAME of DIR's project.
DIR defaults to the current buffer's; NAME ending .el: a file.  Its :ui is
drawn in a canvas of its own, in its pane, selected (NOSELECT: shown only,
its code started a moment later, after the agent's request is answered; to
be asked about, it waits, said on it, until the user selects it; HERE: in
the selected window instead, `agent-ui-open-dashboard-here').  Open already:
its pane shown (HERE: shown here).  Interactively, the project's dashboards to
pick from.  Returns its canvas."
  (interactive (list (agent-ui-dashboards--read-name)))
  (let* ((file (agent-ui-dashboard-file name dir))
         (root (or (agent-ui-dashboard-root (file-name-directory file))
                   (file-name-directory file)))
         (canvas-name (agent-ui-dashboard-canvas-name (file-name-base file) root))
         (open (get-buffer (agent-ui-canvas-buffer-name canvas-name))))
    (if (and open (buffer-local-value 'agent-ui-dashboards--state open))
        (progn (cond (noselect (funcall agent-ui-dashboard-display-function open))
                     (here (switch-to-buffer open))
                     (t (pop-to-buffer open)))
               open)
      ;; Read first: a wrong one leaves no canvas behind.
      (let* ((read (agent-ui-dashboard-read file))
             (canvas (let ((default-directory root))
                       (agent-ui-canvas canvas-name)))
             (dashboard (agent-ui-dashboards--make :name (plist-get read :name) :file file :root root
                                          :canvas canvas :ui (plist-get read :ui)
                                          :sha256 (plist-get read :hash))))
        (with-current-buffer canvas
          (setq default-directory root
                agent-ui-dashboards--state dashboard
                ;; Its buttons a repository's: their prompts never sent at
                ;; once until it's trusted (see its start).
                agent-ui-actions-held t
                ;; Its tab says its name, its title in its border
                ;; (agent-ui-canvas.el, A LONE PANEL'S TITLE).
                agent-ui-canvas-name (plist-get read :name))
          (add-hook 'kill-buffer-hook #'agent-ui-dashboards--closed nil t)
          (add-hook 'window-buffer-change-functions #'agent-ui-dashboards--shown nil t)
          (add-hook 'window-selection-change-functions #'agent-ui-dashboards--selected nil t))
        (condition-case err
            ;; Its components' sources (commands) not started yet: they're
            ;; its code too, run once it's allowed to.
            (agent-ui-dashboards--draw dashboard (agent-ui-persist--without-sources (plist-get read :ui)))
          (error (kill-buffer canvas)
                 (signal (car err) (cdr err))))
        (if noselect
            (progn (funcall agent-ui-dashboard-display-function canvas)
                   (run-with-timer 0 nil #'agent-ui-dashboards--start dashboard (plist-get read :form) t))
          (if here (switch-to-buffer canvas) (pop-to-buffer canvas))
          (agent-ui-dashboards--start dashboard (plist-get read :form)))
        (with-current-buffer canvas
          (run-hooks 'agent-ui-dashboard-open-hook))
        canvas))))

(defun agent-ui-open-dashboard-here (name &optional dir)
  "Open dashboard NAME of DIR's project in the selected window.
It is as `agent-ui-open-dashboard' does, but not in a pane of its own."
  (interactive (list (agent-ui-dashboards--read-name)))
  (agent-ui-open-dashboard name dir nil t))

(defun agent-ui-dashboard-canvas (name &optional dir)
  "The canvas of dashboard NAME of DIR's project, open; an error if it isn't."
  (let* ((root (or (agent-ui-dashboard-root dir) (agent-ui--fail "dashboard %s: no project here" name)))
         (buffer (get-buffer (agent-ui-canvas-buffer-name (agent-ui-dashboard-canvas-name name root)))))
    (unless (and buffer (buffer-local-value 'agent-ui-dashboards--state buffer))
      (agent-ui--fail "dashboard %s isn't open: agent-ui open %s" name name))
    buffer))

(defun agent-ui-dashboards--draw (dashboard ui)
  "UI, DASHBOARD's components, shown in its canvas (its files its root's)."
  (let ((agent-ui-display-function #'ignore)
        (agent-ui-file-directory (agent-ui-dashboards--root dashboard)))
    (agent-ui-show ui :canvas (agent-ui-dashboards--canvas dashboard))))

;; ====== ITS SCRIPT ======
;; Its code runs as Emacs itself: allowed first (`agent-ui-dashboard-allow-
;; function'), then its form evaluated (lexical, nothing global defined), its
;; :ui drawn again with its sources, :start called, :fetch at once and every
;; :every seconds; :stop when its canvas closes, its timer stopped, its
;; commands killed.  Each called with DASHBOARD, in its root (`default-
;; directory'); an error of one kept in DASHBOARD and said, the others go on.

(defvar agent-ui-dashboard-allow-function #'agent-ui-dashboards--allowed-p
  "Function that says whether a dashboard's code may run.
Called with a dashboard (an `agent-ui-dashboards--state') whose code (its
script, its components' sources) is to run: non-nil lets it.  With
`agent-ui-dashboard-may-ask' nil, it asks nothing: nil, the dashboard waits.")

(defvar agent-ui-dashboard-may-ask t
  "Non-nil if the user may be asked now to let a dashboard's code run.
Nil while it starts from a timer, opened by an agent: a question then would
take the keys the user is typing elsewhere.")

;; ====== TRUSTING ONE ======
;; A dashboard's file comes from a repository and runs as Emacs itself: before
;; its code first runs, the user is asked (run it, trust its project, view its
;; file first, or not now); run, it's remembered by its file's content
;; (sha256), in `agent-ui-trust-file': asked again once it changes.
;; Not now: drawn, nothing run, said on it; r asks again.
;; Opened by an agent (not selected), it isn't asked from a timer (the keys
;; the user types elsewhere would answer): it waits, said on it, asked once
;; the user selects it (or r).
;; Its project trusted (p, confirmed with a yes typed; agent-ui-trust.el):
;; all of the project's code runs without asking, every dashboard whatever
;; its file becomes (a dashboard being built, an agent editing it, asked about
;; after each change), the scripts its dashboards run too (which a
;; dashboard's content never covered).  M-x agent-ui-forget-project lists the
;; projects trusted and forgets one: its dashboards asked about again.

(defun agent-ui-dashboards--hash (file)
  "FILE's content's sha256."
  (secure-hash 'sha256 (agent-ui-dashboards--bytes file)))

(defun agent-ui-dashboard-trusted-p (file &optional hash)
  "Whether dashboard FILE's code may run unasked.
Its project trusted, or the file, as it is now (HASH: as it was read, its
content's sha256), let run in its project (its own, or one sharing its
trust: an agent's worktree its project's).  The same in another
repository isn't: its scripts aren't the ones you let run."
  (let* ((file (expand-file-name file))
         (project (lambda (file) (when-let* ((root (agent-ui-dashboard-root (file-name-directory file))))
                                   (agent-ui-trust--root root))))
         (here (funcall project file)))
    (and (or (agent-ui-project-trusted-p (agent-ui-dashboard-root (file-name-directory file)))
             (let ((hash (or hash (agent-ui-dashboards--hash file))))
               (seq-some (lambda (entry)
                           (and (equal (car-safe entry) hash)
                                (stringp (nth 1 entry))
                                (or (equal (nth 1 entry) file)
                                    ;; A file kept trusted may be gone, or remote:
                                    ;; no project there to look for.
                                    (and here
                                         (not (file-remote-p (nth 1 entry)))
                                         (file-directory-p (file-name-directory (nth 1 entry)))
                                         (equal (funcall project (nth 1 entry)) here)))))
                         (agent-ui-trust--entries))))
         t)))

(defun agent-ui-dashboard-trust (file &optional hash)
  "Remember dashboard FILE's code, as it is now, as let run.
HASH: as it was read, its content's sha256.  Its older contents are
forgotten."
  (let ((file (expand-file-name file)))
    (agent-ui-trust--write
     (cons (list (or hash (agent-ui-dashboards--hash file)) file (format-time-string "%FT%T%z"))
           (seq-remove (lambda (e) (and (stringp (car-safe e)) (equal (nth 1 e) file)))
                       (agent-ui-trust--entries))))))

(defun agent-ui-dashboards--allowed-p (dashboard)
  "Whether DASHBOARD's code may run: its project trusted, or its file as read;
else the user asked, if they may be (`agent-ui-dashboard-may-ask'; it view-ed
first if they say), a yes remembered: for the file, or for its whole
project (confirmed: a yes typed, a stray key can't give it).  Its code is
the file as it was read: changed since (an agent editing it while it's
asked), a yes for the file lets nothing run, remembers nothing."
  (let ((file (agent-ui-dashboards--file dashboard))
        (root (agent-ui-dashboards--root dashboard))
        (hash (agent-ui-dashboards--sha256 dashboard)))
    (or (agent-ui-dashboards--trusted-p dashboard)
        (and agent-ui-dashboard-may-ask
             (let ((answer nil))
               (while (not answer)
                 (pcase (car (read-multiple-choice
                              (format "Dashboard %s runs code from %s, as Emacs itself (its commands too). Run it?"
                                      (agent-ui-dashboards--name dashboard) (abbreviate-file-name file))
                              `((?y "run it" "Let its code run, remembered until its file changes")
                                (?p "trust the project"
                                    ,(format "Let all of %s's code run, its dashboards whatever they become (M-x agent-ui-forget-project undoes it)"
                                             (abbreviate-file-name root)))
                                (?v "view it" "Its file first, read-only; asked again after")
                                (?n "not now" "Drawn, nothing run (r asks again)"))))
                   (?y (setq answer (if (agent-ui-dashboards--changed-p dashboard)
                                        'no
                                      (agent-ui-dashboard-trust file hash)
                                      'yes)))
                   (?p (when (let ((use-short-answers nil))
                               (yes-or-no-p (format "Trust %s: let all of its code run as you, whatever its files become? "
                                                    (abbreviate-file-name root))))
                         (agent-ui-trust-project root)
                         (setq answer 'yes)))
                   (?v (view-file-other-window file))
                   (_ (setq answer 'no))))
               (eq answer 'yes))))))

(defun agent-ui-dashboards--trusted-p (dashboard)
  "Whether DASHBOARD is trusted: its project, or its file as read."
  (or (agent-ui-project-trusted-p (agent-ui-dashboards--root dashboard))
      (agent-ui-dashboard-trusted-p (agent-ui-dashboards--file dashboard)
                                    (agent-ui-dashboards--sha256 dashboard))))

(defun agent-ui-dashboards--changed-p (dashboard)
  "Whether DASHBOARD's file changed since it was read (or is gone)."
  (not (equal (ignore-error file-error (agent-ui-dashboards--hash (agent-ui-dashboards--file dashboard)))
              (agent-ui-dashboards--sha256 dashboard))))

(defun agent-ui-dashboards--code-p (form ui)
  "Whether a dashboard has code to run.
The dashboard's FORM and UI: a script, or a source in its components."
  (or (cl-some (lambda (key) (plist-get (cdr form) key)) '(:fetch :start :stop))
      (let ((found nil))
        (cl-labels ((walk (e)
                      (when (agent-ui--plist-p e)
                        (when (plist-get e :source) (setq found t))
                        (mapc #'walk (plist-get e :children)))))
          (walk ui))
        found)))

(defun agent-ui-dashboards--failed (dashboard what err &optional key component)
  "DASHBOARD's WHAT failed with ERR, said.
WHAT is \"fetch\", a command...; ERR an error, or a message: kept by KEY
\(default WHAT) until it goes well, said: on COMPONENT's title if given, else
on the dashboard's line."
  (let ((text (format "%s: %s" what (if (stringp err) err (agent-ui-error-message err))))
        (key (or key what)))
    (setf (agent-ui-dashboards--error dashboard) text
          (alist-get key (agent-ui-dashboards--errors dashboard) nil nil #'equal) (cons text component))
    (message "Agent UI: dashboard %s: %s" (agent-ui-dashboards--name dashboard) text)
    (agent-ui-dashboards--said dashboard)
    nil))

(defun agent-ui-dashboards--well (dashboard key)
  "DASHBOARD's KEY (a query, \"fetch\") went well: its error gone."
  (when (assoc key (agent-ui-dashboards--errors dashboard))
    (setf (agent-ui-dashboards--errors dashboard)
          (cl-remove key (agent-ui-dashboards--errors dashboard) :key #'car :test #'equal))
    (unless (agent-ui-dashboards--errors dashboard)
      (setf (agent-ui-dashboards--error dashboard) nil))
    (agent-ui-dashboards--said dashboard)))

(defun agent-ui-dashboards--said (dashboard)
  "What's wrong with DASHBOARD, and what's loading, said.
Its line (errors of no component, one line each), its components' titles
\(loading, how long; failed)."
  (when (agent-ui-dashboards--live-p dashboard)
    (let ((lines (delq nil (mapcar (lambda (e) (unless (cddr e) (concat "⚠ " (cadr e))))
                                   (reverse (agent-ui-dashboards--errors dashboard))))))
      (agent-ui-dashboards--status dashboard (and lines (string-join lines "\n"))))
    (agent-ui-dashboards--mark dashboard)))

(defcustom agent-ui-dashboard-loading-delay 0.5
  "Seconds a query refreshing its component runs before it's said loading.
The component shows its last data, or its error, and its title says it's
loading after this: a quick refresh doesn't flicker it.  Its first one,
nothing shown yet: at once."
  :type 'number :group 'agent-ui)

(defun agent-ui-dashboards--mark (dashboard)
  "DASHBOARD's components' titles, updated for loading or failure.
One loading, \"⟳ loading, 1m 12s\" after it (a refresh: once it's taken
`agent-ui-dashboard-loading-delay'); one failed, its error; the others as they
were."
  (let ((canvas (agent-ui-dashboards--canvas dashboard))
        (now (float-time))
        (marks nil))
    (maphash (lambda (key run)
               (when-let* ((id (plist-get run :component)))
                 (let ((took (- now (plist-get run :start))))
                   (when (or (>= took agent-ui-dashboard-loading-delay)
                             (not (gethash key (agent-ui-dashboards--loaded dashboard))))
                     (unless (and (assoc id marks) (< took (cdr (assoc id marks))))
                       (setf (alist-get id marks nil nil #'equal) took))))))
             (agent-ui-dashboards--running dashboard))
    (setq marks (mapcar (lambda (m) (cons (car m) (concat "⟳ loading, " (agent-ui-format-duration (cdr m)))))
                        marks))
    (dolist (e (agent-ui-dashboards--errors dashboard))
      (when-let* ((id (cddr e)))
        (unless (assoc id marks)
          (push (cons id (concat "⚠ " (cadr e))) marks))))
    (let ((agent-ui-display-function #'ignore))
      (pcase-dolist (`(,id . ,mark) marks)
        (unless (assoc id (agent-ui-dashboards--titles dashboard))
          (when-let* ((component (ignore-error agent-ui-error (agent-ui-get id :canvas canvas))))
            (push (cons id (plist-get component :title)) (agent-ui-dashboards--titles dashboard))))
        (when-let* ((entry (assoc id (agent-ui-dashboards--titles dashboard))))
          (ignore-error agent-ui-error
            (agent-ui-update id (list :title (if (cdr entry) (concat (cdr entry) "  " mark) mark))
                             :canvas canvas))))
      ;; Marked no more: as it was.
      (dolist (entry (agent-ui-dashboards--titles dashboard))
        (unless (assoc (car entry) marks)
          (ignore-error agent-ui-error (agent-ui-update (car entry) (list :title (cdr entry)) :canvas canvas))
          (setf (agent-ui-dashboards--titles dashboard) (delq entry (agent-ui-dashboards--titles dashboard))))))))

(defun agent-ui-dashboards--tick (dashboard)
  "DASHBOARD's loading components' times, said; none loading: the ticker stops."
  (let ((loading nil))
    (maphash (lambda (_key run) (when (plist-get run :component) (setq loading t)))
             (agent-ui-dashboards--running dashboard))
    (if (and loading (agent-ui-dashboards--live-p dashboard))
        (agent-ui-dashboards--mark dashboard)
      (when (timerp (agent-ui-dashboards--ticker dashboard))
        (cancel-timer (agent-ui-dashboards--ticker dashboard)))
      (setf (agent-ui-dashboards--ticker dashboard) nil))))

(defconst agent-ui-dashboards--status-id "dashboard.status"
  "The id of the line under a dashboard saying what went wrong.")

(defun agent-ui-dashboards--status (dashboard text)
  "DASHBOARD's lines under it saying TEXT, or gone (TEXT nil).
TEXT is what went wrong, a line each, \"⚠\" before."
  (when (agent-ui-dashboards--live-p dashboard)
    (let ((canvas (agent-ui-dashboards--canvas dashboard))
          (agent-ui-display-function #'ignore))
      (if text
          (agent-ui-show (list :type "text" :id agent-ui-dashboards--status-id :face "error"
                               :text text)
                         :canvas canvas)
        (when (member agent-ui-dashboards--status-id (buffer-local-value 'agent-ui--order canvas))
          (agent-ui-remove agent-ui-dashboards--status-id :canvas canvas))))))

(defun agent-ui-dashboards--call (dashboard key)
  "DASHBOARD's script's KEY (:fetch, :start, :stop) called with it, in its root;
an error of it kept and said.  Non-nil if it went well."
  (if-let* ((fn (plist-get (agent-ui-dashboards--script dashboard) key)))
      (let ((default-directory (agent-ui-dashboards--root dashboard)))
        (condition-case err
            (progn (funcall fn dashboard) t)
          (error (agent-ui-dashboards--failed dashboard (substring (symbol-name key) 1) err))))
    t))

(defun agent-ui-dashboards--live-p (dashboard)
  "Non-nil if DASHBOARD's canvas buffer is live."
  (buffer-live-p (agent-ui-dashboards--canvas dashboard)))

(defun agent-ui-dashboards--start (dashboard form &optional unasked)
  "DASHBOARD's code started, if it has some and it's allowed.
FORM (its file's) evaluated, its :ui drawn again with its sources, :start,
:fetch now and every :every seconds.  Closed before (opened without being
selected: started a moment later), nothing asked: a dashboard closed at once
was asked about, its question come out of nowhere.  Closed while it asks,
nothing run.  UNASKED (opened by an agent, from a timer): the user not
asked; to be, it waits, said on it, until they select it."
  (setf (agent-ui-dashboards--waiting dashboard) nil)
  ;; No code to let run: its buttons send their prompts if its file or its
  ;; project is trusted (else only put them into the prompt).
  (when (and (agent-ui-dashboards--live-p dashboard)
             (not (agent-ui-dashboards--code-p form (agent-ui-dashboards--ui dashboard))))
    (with-current-buffer (agent-ui-dashboards--canvas dashboard)
      (let ((held (not (agent-ui-dashboards--trusted-p dashboard))))
        (unless (eq held agent-ui-actions-held)
          (setq agent-ui-actions-held held)
          (agent-ui--dirty-all)))))
  (when (and (agent-ui-dashboards--live-p dashboard)
             (agent-ui-dashboards--code-p form (agent-ui-dashboards--ui dashboard))
             (or (let ((agent-ui-dashboard-may-ask (and agent-ui-dashboard-may-ask (not unasked))))
                   (funcall agent-ui-dashboard-allow-function dashboard))
                 (if unasked
                     (progn (setf (agent-ui-dashboards--waiting dashboard) form)
                            (agent-ui-dashboards--failed dashboard "its code"
                                                     "waiting for permission: select it (or r) to be asked"))
                   (agent-ui-dashboards--failed dashboard "its code"
                                            (if (agent-ui-dashboards--changed-p dashboard)
                                                "not run, its file changed since it was read: r reads it again"
                                              "not run, not let: r asks again"))))
             (agent-ui-dashboards--live-p dashboard))
    (agent-ui-dashboards--well dashboard "its code")
    ;; Let run: trusted, its buttons as they say.
    (with-current-buffer (agent-ui-dashboards--canvas dashboard)
      (setq agent-ui-actions-held nil))
    (let ((script (condition-case err
                      (let ((default-directory (agent-ui-dashboards--root dashboard)))
                        (eval form t))
                    (error (agent-ui-dashboards--failed dashboard "its code" err)))))
      (setf (agent-ui-dashboards--script dashboard) script)
      (condition-case err
          (agent-ui-dashboards--draw dashboard (agent-ui-dashboards--ui dashboard))
        (error (agent-ui-dashboards--failed dashboard "its :ui" err)))
      (when script
        (agent-ui-dashboards--call dashboard :start)
        (agent-ui-dashboards--fetch dashboard)
        (when-let* ((every (plist-get script :every)))
          (setf (agent-ui-dashboards--timer dashboard)
                (run-with-timer every every #'agent-ui-dashboards--fetch dashboard)))))))

(defcustom agent-ui-dashboard-slow 0.1
  "Seconds a dashboard's fetch may take itself before it's said.
Its commands apart, Emacs frozen meanwhile."
  :type 'number :group 'agent-ui)

(defun agent-ui-dashboards--visible-p (dashboard)
  "Non-nil if DASHBOARD's canvas is shown in a window."
  (get-buffer-window (agent-ui-dashboards--canvas dashboard) t))

(defun agent-ui-dashboards--fetch (dashboard)
  "DASHBOARD's :fetch, once, if it's shown.
Not while it's hidden (fetched when it's shown again); its canvas gone,
stopped.  Its queries each their own: one still running isn't started
again, the others are (`agent-ui-dashboard-run').  Taking long itself (Emacs
frozen), said."
  (cond
   ((not (agent-ui-dashboards--live-p dashboard)) (agent-ui-dashboards--stop dashboard))
   ((not (agent-ui-dashboards--visible-p dashboard)) (setf (agent-ui-dashboards--stale dashboard) t))
   (t (agent-ui-dashboards--fetch-now dashboard))))

(defun agent-ui-dashboards--fetch-now (dashboard)
  "DASHBOARD's :fetch, now, shown or not."
  (setf (agent-ui-dashboards--stale dashboard) nil
        (agent-ui-dashboards--fetched dashboard) (float-time))
  (let* ((start (float-time))
         (well (agent-ui-dashboards--call dashboard :fetch))
         (took (- (float-time) start)))
    (cond
     ((> took agent-ui-dashboard-slow)
      (agent-ui-dashboards--failed
       dashboard "fetch" (format "took %.2f s itself, Emacs frozen meanwhile: run commands with agent-ui-dashboard-run"
                             took)))
     (well (agent-ui-dashboards--well dashboard "fetch")))))

;; READ BY AN AGENT, HIDDEN
;; A dashboard hidden fetches nothing; read by an agent (agent-ui get), it's
;; fetched then if its data is older than its :every (or it was never
;; fetched, or a fetch was missed): the agent reads it again once its queries
;; end (bin/agent-ui does).  Its data's age counts from when its queries
;; ended, not from the fetch: a query taking longer than its :every had its
;; data old as it came, each read fetching again, the agent never answered.
;; Never fetched more often than its :every so.
(defun agent-ui-dashboard-read-fetch (dashboard)
  "DASHBOARD read by an agent, fetched now if its data is old.
It is fetched if it's hidden and its data is old (see above).  Non-nil
while its queries run."
  (let ((every (plist-get (agent-ui-dashboards--script dashboard) :every))
        (fetched (when-let* ((fetched (agent-ui-dashboards--fetched dashboard)))
                   (max fetched (or (agent-ui-dashboards--settled dashboard) 0)))))
    (when (and (agent-ui-dashboards--script dashboard)
               (agent-ui-dashboards--live-p dashboard)
               (not (agent-ui-dashboards--visible-p dashboard))
               (zerop (hash-table-count (agent-ui-dashboards--running dashboard)))
               (or (null fetched)
                   (agent-ui-dashboards--stale dashboard)
                   (and every (> (- (float-time) fetched) every))))
      (agent-ui-dashboards--fetch-now dashboard))
    (> (hash-table-count (agent-ui-dashboards--running dashboard)) 0)))

(defun agent-ui-dashboard-fetched (dashboard)
  "Seconds since DASHBOARD last fetched, or nil if it never has."
  (when-let* ((fetched (agent-ui-dashboards--fetched dashboard)))
    (- (float-time) fetched)))

(defun agent-ui-dashboards--shown (window)
  "WINDOW shows a dashboard's canvas now (its `window-buffer-change-functions'):
a fetch missed while it was hidden, done."
  (when-let* ((buffer (window-buffer window))
              (dashboard (buffer-local-value 'agent-ui-dashboards--state buffer))
              ((agent-ui-dashboards--stale dashboard))
              ((agent-ui-dashboards--script dashboard)))
    (run-with-timer 0 nil #'agent-ui-dashboards--fetch dashboard)))

(defun agent-ui-dashboards--selected (window)
  "A dashboard's code waiting, asked about once WINDOW, showing it, is selected.
Its canvas's `window-selection-change-functions': WINDOW selected or left."
  (when-let* ((buffer (window-buffer window))
              (dashboard (buffer-local-value 'agent-ui-dashboards--state buffer))
              ((agent-ui-dashboards--waiting dashboard))
              ((eq window (selected-window))))
    (run-with-timer 0 nil #'agent-ui-dashboards--ask dashboard)))

(defun agent-ui-dashboards--ask (dashboard)
  "DASHBOARD's code, waiting, asked about, if its canvas is still selected."
  (when (and (agent-ui-dashboards--waiting dashboard)
             (agent-ui-dashboards--live-p dashboard)
             (eq (window-buffer (selected-window)) (agent-ui-dashboards--canvas dashboard)))
    (agent-ui-dashboards--start dashboard (agent-ui-dashboards--waiting dashboard))))

(defun agent-ui-dashboards--stop (dashboard)
  "DASHBOARD's timer stopped, its commands killed, its :stop called."
  (when (timerp (agent-ui-dashboards--timer dashboard))
    (cancel-timer (agent-ui-dashboards--timer dashboard)))
  (setf (agent-ui-dashboards--timer dashboard) nil)
  (when (timerp (agent-ui-dashboards--ticker dashboard))
    (cancel-timer (agent-ui-dashboards--ticker dashboard)))
  (setf (agent-ui-dashboards--ticker dashboard) nil)
  (dolist (process (agent-ui-dashboards--processes dashboard))
    (when (process-live-p process) (delete-process process)))
  (setf (agent-ui-dashboards--processes dashboard) nil)
  (clrhash (agent-ui-dashboards--running dashboard))
  ;; Its components drawn anew next (read again, opened again): empty.
  (clrhash (agent-ui-dashboards--loaded dashboard))
  (when (agent-ui-dashboards--script dashboard)
    (agent-ui-dashboards--call dashboard :stop)
    (setf (agent-ui-dashboards--script dashboard) nil)))

(defun agent-ui-dashboards--closed ()
  "A dashboard's canvas closes (`kill-buffer-hook'): its script stopped."
  (when agent-ui-dashboards--state
    (agent-ui-dashboards--stop agent-ui-dashboards--state)))

(defun agent-ui-dashboard-reload ()
  "The project dashboard here read again from its file (edited).
It is drawn anew, its code run again (r).  Its file wrong now: said on
it, it goes on as it was."
  (interactive)
  (let ((dashboard agent-ui-dashboards--state))
    (unless dashboard
      (user-error "Not a project dashboard (M-x agent-ui-open-dashboard opens one)"))
    (condition-case err
        (let* ((read (agent-ui-dashboard-read (agent-ui-dashboards--file dashboard)))
               (ui (plist-get read :ui))
               (canvas (agent-ui-dashboards--canvas dashboard)))
          (agent-ui-dashboards--stop dashboard)
          (setf (agent-ui-dashboards--ui dashboard) ui
                (agent-ui-dashboards--sha256 dashboard) (plist-get read :hash)
                (agent-ui-dashboards--error dashboard) nil
                (agent-ui-dashboards--errors dashboard) nil
                (agent-ui-dashboards--titles dashboard) nil
                (agent-ui-dashboards--stale dashboard) nil)
          ;; Drawn first, the others removed after: never empty (an empty
          ;; canvas closes its pane).
          (agent-ui-dashboards--draw dashboard (agent-ui-persist--without-sources ui))
          (let ((id (plist-get ui :id)))
            (dolist (old (buffer-local-value 'agent-ui--order canvas))
              (unless (equal old id)
                (agent-ui-remove old :canvas canvas))))
          (agent-ui-dashboards--start dashboard (plist-get read :form))
          (message "Dashboard %s: read again" (agent-ui-dashboards--name dashboard)))
      (agent-ui-error (agent-ui-dashboards--failed dashboard "its file" err)))))

;; ====== AS A PDF ======
;; `agent-ui-export-pdf' saves a canvas as a PDF (agent-ui-snapshot.el);
;; a dashboard's goes beside its file: NAME-DATE-TIME.pdf.

(defun agent-ui-dashboard-pdf-file (dashboard)
  "Where DASHBOARD's PDF goes now, beside its file.
It is NAME-YYYYMMDD-HHMMSS.pdf (another in the same second:
NAME-...-2.pdf)."
  (agent-ui--require 'agent-ui-snapshot)
  (let ((file (agent-ui-dashboards--file dashboard)))
    (agent-ui-pdf-unique-file (file-name-base file) (file-name-directory file))))

;; ====== WHAT ITS SCRIPT CALLS ======

(defun agent-ui-dashboards--change (dashboard id props change)
  "Component ID of DASHBOARD changed by PROPS (a plist) with CHANGE.
CHANGE is `agent-ui-update' or `agent-ui-append'; a closed dashboard: nothing."
  (when (agent-ui-dashboards--live-p dashboard)
    (funcall change id props :canvas (agent-ui-dashboards--canvas dashboard))))

(defun agent-ui-dashboard-update (dashboard id &rest props)
  "Change DASHBOARD's component ID by PROPS, as agent-ui update does:
\(agent-ui-dashboard-update dashboard \"ci\" :rows rows).  A property nil:
back to its default.  An error if DASHBOARD has no component ID or the
change makes it wrong."
  (agent-ui-dashboards--change dashboard id props #'agent-ui-update))

(defun agent-ui-dashboard-append (dashboard id &rest props)
  "Add PROPS' lists to DASHBOARD's component ID, as agent-ui append does.
A table's rows (replaced by its key), a chart's values:
\(agent-ui-dashboard-append dashboard \"errors\" :values (list 3))."
  (agent-ui-dashboards--change dashboard id props #'agent-ui-append))

(defun agent-ui-dashboard-get (dashboard id)
  "DASHBOARD's component ID, its properties as they are now (a plist)."
  (agent-ui-get id :canvas (agent-ui-dashboards--canvas dashboard)))

(defun agent-ui-dashboards--output (text)
  "A command's output TEXT, parsed as JSON when it reads so.
Objects become alists, arrays lists, null and false nil; else TEXT."
  (or (and (string-match-p "\\`[ \t\n]*[[{]" text)
           (condition-case nil
               (json-parse-string text :object-type 'alist :array-type 'list
                                  :null-object nil :false-object nil)
             (error nil)))
      text))

(cl-defun agent-ui-dashboard-run (dashboard command callback &key component timeout)
  "Run COMMAND (a list: a program and its arguments; a string: by the shell)
in DASHBOARD's root, without waiting, however long it takes: CALLBACK then
called with its output (see `agent-ui-dashboards--output'), if it ends well
\(exit 0); else its error is said.  COMPONENT: the id of the component it fills,
its title saying it's loading (and how long) meanwhile (refreshing it: once
it's taken `agent-ui-dashboard-loading-delay'), its data kept, its error said
on it.  A query (its COMPONENT, else its COMMAND) still running isn't started
again: nil then; the others are, each on its own.  TIMEOUT: seconds, it
killed after them (an error).  Killed when DASHBOARD closes.  Returns its
process."
  (let ((key (or component (if (stringp command) command (string-join command " "))))
        (running (agent-ui-dashboards--running dashboard)))
    (unless (gethash key running)
      (let* ((default-directory (agent-ui-dashboards--root dashboard))
             (name (format "agent-ui-dashboard-%s" (agent-ui-dashboards--name dashboard)))
             (out (generate-new-buffer (format " *%s*" name) t))
             (err (generate-new-buffer (format " *%s stderr*" name) t))
             (program (if (stringp command) command (car command)))
             (timed-out nil)
             (process
              (make-process
               :name name :buffer out :stderr err :noquery t :connection-type 'pipe
               :command (if (stringp command) (list shell-file-name shell-command-switch command) command)
               :sentinel
               (lambda (process _event)
                 (unless (process-live-p process)
                   (setf (agent-ui-dashboards--processes dashboard) (delq process (agent-ui-dashboards--processes dashboard)))
                   (when (eq (plist-get (gethash key running) :process) process)
                     (remhash key running)
                     (puthash key t (agent-ui-dashboards--loaded dashboard))
                     (when (zerop (hash-table-count running))
                       (setf (agent-ui-dashboards--settled dashboard) (float-time))))
                   (let ((text (with-current-buffer out (buffer-string)))
                         (errors (string-trim (with-current-buffer err (buffer-string))))
                         (code (process-exit-status process)))
                     (kill-buffer out)
                     (when (buffer-live-p err) (kill-buffer err))
                     (when (agent-ui-dashboards--live-p dashboard)
                       (cond
                        (timed-out
                         (agent-ui-dashboards--failed dashboard program (format "timed out after %s s" timeout) key component))
                        ((and (eq (process-status process) 'exit) (= code 0))
                         (when (let ((default-directory (agent-ui-dashboards--root dashboard)))
                                 (condition-case e
                                     (progn (funcall callback (agent-ui-dashboards--output text)) t)
                                   (error (agent-ui-dashboards--failed dashboard program e key component))))
                           (agent-ui-dashboards--well dashboard key)))
                        (t
                         (agent-ui-dashboards--failed
                          dashboard program
                          (format "exit %s%s" code
                                  (let ((last (car (last (split-string (if (string-empty-p errors) text errors)
                                                                       "\n" t)))))
                                    (if last (concat ": " last) "")))
                          key component)))
                       ;; Its component loading no more.
                       (agent-ui-dashboards--mark dashboard))))))))
        ;; Its stderr's pipe: no query, no "finished" line in what it said.
        (when-let* ((stderr (get-buffer-process err)))
          (set-process-query-on-exit-flag stderr nil)
          (set-process-sentinel stderr #'ignore))
        (push process (agent-ui-dashboards--processes dashboard))
        (puthash key (list :process process :start (float-time) :component component) running)
        (when timeout
          (run-with-timer timeout nil (lambda ()
                                        (when (process-live-p process)
                                          (setq timed-out t)
                                          (delete-process process)))))
        (when component
          (if (gethash key (agent-ui-dashboards--loaded dashboard))
              ;; A refresh: said once it's taken a moment.
              (run-with-timer agent-ui-dashboard-loading-delay nil
                              (lambda ()
                                (when (eq (plist-get (gethash key running) :process) process)
                                  (agent-ui-dashboards--tick dashboard))))
            (agent-ui-dashboards--mark dashboard))
          (unless (timerp (agent-ui-dashboards--ticker dashboard))
            (setf (agent-ui-dashboards--ticker dashboard)
                  (run-with-timer 1 1 #'agent-ui-dashboards--tick dashboard))))
        process))))

(declare-function agent-ui-persist--without-sources "agent-ui-persist")

;; ====== SAVING ONE ======
;; S on a canvas: the component at point (a top-level one; a child: its panel)
;; saved as one of the project's dashboards, as it was shown (its data, the
;; updates and its sources' changes, left out), with a :fetch to write;
;; the user made it: trusted as it's written.

(defun agent-ui-dashboards--file-text (name ui)
  "A dashboard file's text: dashboard NAME showing UI, its code to write."
  (concat
   (format ";;; %s.el --- Agent UI dashboard%s -*- lexical-binding: t; -*-\n" name
           ;; On one line: a comment's (what follows a new line is code).
           (if-let* ((title (plist-get ui :title)))
               (concat ": " (replace-regexp-in-string "[\n\r]+" " " title))
             ""))
   ";; Saved from a canvas (S): what it shows, its data left out. Its code fills it:\n"
   ";; see the agent-ui skill's references/dashboards.md (agent-ui check NAME checks it).\n"
   "(agent-ui-dashboard\n :version 1\n :ui "
   (string-trim (replace-regexp-in-string "\n" "\n     " (pp-to-string ui)))
   "\n :every 30\n :fetch (lambda (dashboard)\n          ;; (agent-ui-dashboard-update dashboard \"ID\" :prop value)\n"
   "          (ignore dashboard)))\n"))

(defun agent-ui-save-dashboard (name)
  "Save the component at point, as it was shown, as the project's dashboard NAME.
\(S): its file, .agent-ui/dashboards/NAME.el, written (asked before replacing
one), trusted (the user made it)."
  (interactive
   (progn
     (unless (derived-mode-p 'agent-ui-canvas-mode) (user-error "Not a canvas"))
     (list (read-string "Save as the project's dashboard: "
                        (agent-ui--entry-id (car (agent-ui--resolve (agent-ui--component-at-point))))))))
  (unless (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]*\\'" name)
    (user-error "A dashboard's name: letters, digits, _ . -"))
  (let* ((root (or (agent-ui-dashboard-root)
                   (user-error "No project here (this canvas's folder: %s)" default-directory)))
         (id (agent-ui--entry-id (car (agent-ui--resolve (agent-ui--component-at-point)))))
         (ui (agent-ui-shown-component id :canvas (current-buffer)))
         (folder (expand-file-name agent-ui-dashboard-directory root))
         (file (expand-file-name (concat name ".el") folder)))
    (when (and (file-exists-p file)
               (not (y-or-n-p (format "Dashboard %s is there already: replace it? " name))))
      (user-error "Not saved"))
    (make-directory folder t)
    (with-temp-file file
      (setq-local coding-system-for-write 'utf-8)
      (insert (agent-ui-dashboards--file-text name ui)))
    (agent-ui-dashboard-trust file)
    (message "Saved as dashboard %s (%s): M-x agent-ui-open-dashboard opens it; its :fetch is to write"
             name (abbreviate-file-name file))
    file))



(provide 'agent-ui-dashboards)

;;; agent-ui-dashboards.el ends here
