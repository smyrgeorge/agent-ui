;;; agent-ui-trust.el --- A project's code run as you once you trust it  -*- lexical-binding: t; -*-

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

;; Trust: code from a repository runs as you, with all you may do.  A
;; project's dashboards (agent-ui-dashboards.el) are such code, and so are
;; the workflows of a package built on Agent UI (agent-workflow: their
;; scripts, their Lisp): before a project's code first runs, you're asked.
;; Trusting the project (`agent-ui-trust-project') lets all of its code
;; run from then on, unasked, whatever its files become; remembered by its
;; root, its true name, in `agent-ui-trust-file'.  An agent's worktree
;; shares its project's trust (`agent-ui-trust-root-function').
;; `agent-ui-forget-project' lists the projects trusted and forgets one:
;; its code asked about again.
;;
;; The same file keeps what a dashboard was let run as by its content
;; (agent-ui-dashboards.el): every entry, a project's or a file's, is
;; read and written here.  Loaded when first used, not with Emacs.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defcustom agent-ui-trust-file (locate-user-emacs-file "agent-ui/trusted.eld")
  "Where the projects whose code you trust are remembered.
And the dashboards let run by their content (their files' sha256)."
  :type 'file :group 'agent-ui)

(defvar agent-ui-trust-root-function #'identity
  "Function giving the root whose trust a project's root shares.
Called with a project's root (a folder): the root whose trust it shares
\(an agent's worktree shares its project's).")

;; ====== THE FILE ======

(defun agent-ui-trust--entries ()
  "What's trusted, as `agent-ui-trust-file' keeps it.
The projects (:project ROOT TIME); dashboards let run by their content
\(HASH FILE TIME)."
  (when (file-readable-p agent-ui-trust-file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents agent-ui-trust-file)
          (let ((data (read (current-buffer))))
            (and (listp data) data)))
      (error nil))))

(defun agent-ui-trust--write (entries)
  "Make ENTRIES (see `agent-ui-trust--entries') what's trusted."
  (make-directory (file-name-directory agent-ui-trust-file) t)
  (with-temp-file agent-ui-trust-file
    (let ((print-length nil) (print-level nil))
      (insert ";; Agent UI: the projects whose code runs unasked, by root, and the project\n"
              ";; dashboards whose code was let run, by content (sha256).\n")
      (prin1 entries (current-buffer))
      (insert "\n"))))

(defun agent-ui-trust--root (root)
  "ROOT, a project's, as its trust is remembered.
It is the root whose trust it shares (`agent-ui-trust-root-function'),
its true name, a folder."
  (file-name-as-directory
   (file-truename (expand-file-name (funcall agent-ui-trust-root-function
                                             (file-name-as-directory (expand-file-name root)))))))

;; ====== PROJECTS ======

(defun agent-ui-trusted-projects ()
  "The projects whose code runs unasked: ((ROOT . TIME) ...), the latest first."
  (cl-loop for entry in (agent-ui-trust--entries)
           when (eq (car-safe entry) :project)
           collect (cons (nth 1 entry) (nth 2 entry))))

(defun agent-ui-project-trusted-p (root)
  "Whether the project at ROOT is trusted: all of its code runs, unasked."
  (and root (assoc (agent-ui-trust--root root) (agent-ui-trusted-projects)) t))

(defun agent-ui-trust--default-root ()
  "The current project's root: `project-current''s, else the folder you're in."
  (or (when-let* ((project (and (fboundp 'project-current) (project-current))))
        (if (fboundp 'project-root) (project-root project) (car (last project))))
      default-directory))

(defun agent-ui-trust-project (root)
  "Trust the project at ROOT: all of its code runs, unasked.
Its dashboards, the workflows of a package built on Agent UI: whatever
their files become.  Interactively, the current project's (another
picked with a prefix argument), confirmed with a yes typed: a stray key
can't give it."
  (interactive
   (let ((root (if current-prefix-arg
                   (read-directory-name "Trust the project at: " nil nil t)
                 (agent-ui-trust--default-root))))
     (unless (let ((use-short-answers nil))
               (yes-or-no-p (format "Trust %s: let all of its code run as you, whatever its files become? "
                                    (abbreviate-file-name (agent-ui-trust--root root)))))
       (user-error "Not trusted"))
     (list root)))
  (let ((root (agent-ui-trust--root root)))
    (agent-ui-trust--write
     (cons (list :project root (format-time-string "%FT%T%z"))
           (seq-remove (lambda (e) (and (eq (car-safe e) :project) (equal (nth 1 e) root)))
                       (agent-ui-trust--entries))))
    (when (called-interactively-p 'any)
      (message "Agent UI: %s trusted, its code runs unasked" (abbreviate-file-name root)))
    root))

(defun agent-ui-forget-project (root)
  "Stop trusting the project at ROOT: its code asked about again.
Dashboards let run as they are now, by their content, still run.
Interactively, the projects trusted to pick from."
  (interactive
   (let* ((projects (or (agent-ui-trusted-projects)
                        (user-error "No project is trusted: its code is asked about")))
          (names (mapcar (lambda (p) (abbreviate-file-name (car p))) projects))
          (completion-extra-properties
           (list :annotation-function
                 (lambda (name)
                   (concat "  trusted " (cdr (nth (seq-position names name) projects)))))))
     (list (completing-read "Stop trusting the code of: " names nil t))))
  (let ((root (agent-ui-trust--root root)))
    (unless (agent-ui-project-trusted-p root)
      (user-error "%s isn't trusted" (abbreviate-file-name root)))
    (agent-ui-trust--write
     (seq-remove (lambda (e) (and (eq (car-safe e) :project) (equal (nth 1 e) root)))
                 (agent-ui-trust--entries)))
    (message "Agent UI: %s's code asked about again" (abbreviate-file-name root))))

(provide 'agent-ui-trust)

;;; agent-ui-trust.el ends here
