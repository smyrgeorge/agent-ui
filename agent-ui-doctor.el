;;; agent-ui-doctor.el --- Is everything Agent UI needs here?  -*- lexical-binding: t; -*-

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

;; M-x agent-ui-doctor checks what Agent UI needs in this Emacs and shows
;; what's missing, each problem with its fix.  bin/agent-ui doctor (and the
;; MCP tool doctor) asks the same of the user's Emacs, the command's own
;; side first: an emacsclient, a server answering, its session.
;;
;; Its checks, in three groups:
;;
;; - Required: Emacs's version; the packages Agent UI needs (its
;;   Package-Requires, and theirs), each installed, at its version, and
;;   loading; JSON; the package's own files (bin/, skills/ and assets/, a
;;   recipe's :files); its command, executable.
;; - Setup: Emacs's server; emacsclient and bash where agents' shells look;
;;   `agent-ui-mode'; agent-shell's functions it ties into; its MCP server.
;; - Optional: what some components use (SVG images, a graphical frame,
;;   mmdc, MathJax or LaTeX, curl, rsvg-convert, git, nerd-icons): one
;;   missing is a warning, never a failure.
;;
;; It loads nothing of Agent UI's own, so it runs when the rest can't (a
;; package missing, a file broken): it reads what's loaded, and loads the
;; packages Agent UI needs, if they aren't yet, to see that they load.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'lisp-mnt)

(defvar agent-ui-mode)
(defvar agent-ui-mcp)
(defvar agent-ui-command)
(defvar agent-ui-mmdc)
(defvar agent-ui-math-tool)
(defvar agent-ui-pdf-program)
(defvar agent-shell-mcp-servers)
(defvar server-process)
(defvar server-name)
(defvar package-alist)
(declare-function agent-ui-math--tool "agent-ui-math")
(declare-function package-desc-version "package" (cl-x) t)
(declare-function package-version-join "package" (vlist) t)

;; ====== VARIABLES ======

(defconst agent-ui-doctor--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Where Agent UI is installed (`agent-ui-directory', without loading it).")

(defconst agent-ui-doctor--requires
  '((emacs "29.1") (agent-shell "0.99.0") (vui "1.4.0"))
  "Agent UI's Package-Requires, if agent-ui.el's header can't be read.")

(defconst agent-ui-doctor-buffer "*Agent UI doctor*"
  "The buffer `agent-ui-doctor' shows its report in.")

(defconst agent-ui-doctor--marks
  '((ok "✓" success) (warn "!" warning) (fail "✗" error))
  "Each status's mark in the report, and its face.")

(defvar agent-ui-doctor-functions
  '(agent-ui-doctor--emacs agent-ui-doctor--packages agent-ui-doctor--json-support
    agent-ui-doctor--files agent-ui-doctor--command
    agent-ui-doctor--server agent-ui-doctor--emacsclient agent-ui-doctor--bash
    agent-ui-doctor--mode agent-ui-doctor--agent-shell agent-ui-doctor--mcp
    agent-ui-doctor--svg agent-ui-doctor--graphics agent-ui-doctor--mermaid
    agent-ui-doctor--math agent-ui-doctor--curl agent-ui-doctor--pdf
    agent-ui-doctor--markdown agent-ui-doctor--git agent-ui-doctor--icons)
  "The checks `agent-ui-doctor' makes, in order.
Functions of no arguments, each returning a check or a list of them (see
`agent-ui-doctor-checks').")

;; ====== A CHECK ======

(defun agent-ui-doctor--check (group name status detail &optional fix)
  "Return a check: in GROUP, NAME's STATUS, what it found (DETAIL), its FIX.
STATUS is `ok', `warn' or `fail'; FIX is kept only when it isn't ok."
  (append (list :group group :name name :status status :detail detail)
          (when (and fix (not (eq status 'ok)))
            (list :fix fix))))

(defun agent-ui-doctor--on-path (program)
  "Return PROGRAM's file where agents' shells find it, on PATH; else nil.
They get Emacs's environment, so its PATH (not the variable `exec-path')."
  (if (file-name-absolute-p program)
      (and (file-executable-p program) program)
    (locate-file program (parse-colon-path (getenv "PATH")) exec-suffixes #'file-executable-p)))

;; ====== PACKAGES ======

(defun agent-ui-doctor--source (library)
  "Return LIBRARY's source file (its .el, maybe compressed), or nil."
  (when-let* ((file (locate-library library)))
    (let ((base (file-name-sans-extension (string-remove-suffix ".gz" file))))
      (seq-find #'file-readable-p (list (concat base ".el") (concat base ".el.gz"))))))

(defun agent-ui-doctor--headers (file)
  "Return FILE's Version and Package-Requires headers: (VERSION . REQUIRES).
Each nil when it has none, or the file can't be read."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file nil 0 32768)
        (let ((requires (lm-header-multiline "package-requires")))
          (cons (lm-header "version")
                (when requires
                  (car (read-from-string (string-join requires " ")))))))
    (error nil)))

(defun agent-ui-doctor--package-version (package)
  "Return PACKAGE's version as package.el installed it, or nil."
  (when-let* ((desc (and (featurep 'package) (cadr (assq package package-alist)))))
    (package-version-join (package-desc-version desc))))

(defun agent-ui-doctor--at-least (version minimum)
  "Return t if VERSION is MINIMUM or later, nil if older, `unknown' if unsure."
  (condition-case nil
      (if (version-list-<= (version-to-list minimum) (version-to-list version)) t nil)
    (error 'unknown)))

(defun agent-ui-doctor--requirements ()
  "Return Agent UI's requirements and theirs: a list of (PACKAGE MINIMUM BY).
BY is the package needing it (nil: Agent UI itself).  One needed by two
is listed once, with the later of their minimums."
  (let ((queue (mapcar (lambda (r) (list (car r) (cadr r) nil))
                       (or (cdr (agent-ui-doctor--headers
                                 (expand-file-name "agent-ui.el" agent-ui-doctor--directory)))
                           agent-ui-doctor--requires)))
        (result nil))
    (while queue
      (pcase-let* ((`(,package ,minimum ,by) (pop queue))
                   (entry (assq package result)))
        (cond
         (entry
          (when (and minimum (or (null (nth 1 entry))
                                 (eq (agent-ui-doctor--at-least (nth 1 entry) minimum) nil)))
            (setf (nth 1 entry) minimum (nth 2 entry) by)))
         (t
          (push (list package minimum by) result)
          (unless (eq package 'emacs)
            (when-let* ((file (agent-ui-doctor--source (symbol-name package))))
              (dolist (r (cdr (agent-ui-doctor--headers file)))
                (setq queue (append queue (list (list (car r) (cadr r) package)))))))))))
    (nreverse result)))

(defun agent-ui-doctor--load-error (feature)
  "Return nil if FEATURE loads (or is loaded); else its error's message."
  (condition-case err
      (progn (require feature) nil)
    (error (error-message-string err))))

(defun agent-ui-doctor--package (package minimum by)
  "Return the check of PACKAGE, needed at MINIMUM or later by BY.
Installed, at its version, and loading."
  (let* ((name (symbol-name package))
         (found (locate-library name))
         (needed (concat (if minimum (format "%s or later" minimum) "any version")
                         (when by (format ", for %s" by)))))
    (if (not found)
        (agent-ui-doctor--check "Required" name 'fail (format "not installed (%s needed)" needed)
                                (format "Install %s: M-x package-install RET %s, or your package manager's recipe"
                                        name name))
      (let* ((source (agent-ui-doctor--source name))
             (version (or (car (and source (agent-ui-doctor--headers source)))
                          (agent-ui-doctor--package-version package)))
             (recent (if (and minimum version) (agent-ui-doctor--at-least version minimum) t))
             (broken (agent-ui-doctor--load-error package))
             (where (abbreviate-file-name (file-name-directory found))))
        (cond
         (broken
          (agent-ui-doctor--check "Required" name 'fail (format "doesn't load: %s" broken)
                                  (format "Reinstall %s (its files broken, or compiled by another Emacs)" name)))
         ((null recent)
          (agent-ui-doctor--check "Required" name 'fail
                                  (format "%s, older than needed (%s), in %s" version needed where)
                                  (format "Update %s: M-x package-upgrade RET %s, or your package manager's update"
                                          name name)))
         ((or (eq recent 'unknown) (and minimum (null version)))
          (agent-ui-doctor--check "Required" name 'warn
                                  (format "its version unknown (%s needed), in %s" needed where)
                                  (format "Check that %s is %s or later" name minimum)))
         (t
          (agent-ui-doctor--check "Required" name 'ok
                                  (format "%s (%s), in %s" (or version "installed") needed where))))))))

;; ====== REQUIRED ======

(defun agent-ui-doctor--emacs ()
  "Emacs's version: at least what Agent UI's Package-Requires says."
  (let ((minimum (or (nth 1 (assq 'emacs (agent-ui-doctor--requirements))) "29.1")))
    (if (eq (agent-ui-doctor--at-least emacs-version minimum) nil)
        (agent-ui-doctor--check "Required" "Emacs" 'fail
                                (format "%s, older than needed (%s or later)" emacs-version minimum)
                                (format "Upgrade Emacs: Agent UI runs on %s or later" minimum))
      (agent-ui-doctor--check "Required" "Emacs" 'ok (format "%s (%s or later)" emacs-version minimum)))))

(defun agent-ui-doctor--packages ()
  "The packages Agent UI needs, and theirs: a check each."
  (mapcar (lambda (r) (apply #'agent-ui-doctor--package r))
          (seq-remove (lambda (r) (eq (car r) 'emacs)) (agent-ui-doctor--requirements))))

(defun agent-ui-doctor--json-support ()
  "JSON, built into Emacs: every request and reply is JSON."
  (if (condition-case nil (equal (json-parse-string "[1]") [1]) (error nil))
      (agent-ui-doctor--check "Required" "JSON" 'ok "built in")
    (agent-ui-doctor--check "Required" "JSON" 'fail "this Emacs was built without JSON support"
                            "An Emacs built with libjansson (from Emacs 30, JSON is always built in)")))

(defun agent-ui-doctor--files ()
  "The package's own files, beside its Lisp: a recipe's :files keeps them."
  (let ((missing (seq-remove (lambda (file) (file-exists-p (expand-file-name file agent-ui-doctor--directory)))
                             '("bin/agent-ui" "skills/agent-ui/SKILL.md" "assets/tex2svg.js")))
        (where (abbreviate-file-name agent-ui-doctor--directory)))
    (if missing
        (agent-ui-doctor--check "Required" "Package files" 'fail
                                (format "missing from %s: %s" where (string-join missing ", "))
                                "Install it with its bin, skills and assets folders: :files (:defaults \"bin\" \"skills\" \"assets\") in its recipe (see the README's Install)")
      (agent-ui-doctor--check "Required" "Package files" 'ok (format "bin/, skills/ and assets/ in %s" where)))))

(defun agent-ui-doctor--command ()
  "The command agents are given, `agent-ui-command': there, executable."
  (let ((command (if (boundp 'agent-ui-command)
                     agent-ui-command
                   (expand-file-name "bin/agent-ui" agent-ui-doctor--directory))))
    (cond
     ((not (file-exists-p command))
      (agent-ui-doctor--check "Required" "Command" 'fail (format "%s isn't there" (abbreviate-file-name command))
                              "Set agent-ui-command to the package's bin/agent-ui, or reinstall it with its bin folder"))
     ((not (file-executable-p command))
      (agent-ui-doctor--check "Required" "Command" 'fail (format "%s isn't executable" (abbreviate-file-name command))
                              (format "chmod +x %s (agent-ui-mode does it, when it can)" command)))
     (t (agent-ui-doctor--check "Required" "Command" 'ok (abbreviate-file-name command))))))

;; ====== SETUP ======

(defun agent-ui-doctor--server ()
  "Emacs's server: the command reaches Emacs through it."
  (if (and (boundp 'server-process) (processp server-process) (process-live-p server-process))
      (agent-ui-doctor--check "Setup" "Emacs server" 'ok (format "running, named %s" server-name))
    (agent-ui-doctor--check "Setup" "Emacs server" 'fail
                            "not running: the command can't reach Emacs, and agents aren't told of their canvas"
                            "M-x server-start, or (server-start) in your init")))

(defun agent-ui-doctor--emacsclient ()
  "Emacsclient, where agents' shells find it: the command runs it."
  (let* ((client (or (getenv "EMACSCLIENT") "emacsclient"))
         (found (agent-ui-doctor--on-path client))
         (beside (seq-find #'file-executable-p
                           (list (expand-file-name "emacsclient" invocation-directory)
                                 (expand-file-name "bin/emacsclient" invocation-directory)))))
    (cond
     (found (agent-ui-doctor--check "Setup" "emacsclient" 'ok (abbreviate-file-name found)))
     (beside (agent-ui-doctor--check "Setup" "emacsclient" 'fail (format "%s isn't on PATH" client)
                                     (format "(setenv \"EMACSCLIENT\" %S) in your init, or put its folder on PATH"
                                             beside)))
     (t (agent-ui-doctor--check "Setup" "emacsclient" 'fail (format "%s isn't on PATH" client)
                                "Install emacsclient (it comes with Emacs) on PATH, or set EMACSCLIENT to it")))))

(defun agent-ui-doctor--bash ()
  "Bash, where agents' shells find it: the command is a bash script."
  (if-let* ((bash (agent-ui-doctor--on-path "bash")))
      (agent-ui-doctor--check "Setup" "bash" 'ok (abbreviate-file-name bash))
    (agent-ui-doctor--check "Setup" "bash" 'fail "not on PATH: the command is a bash script" "Install bash")))

(defun agent-ui-doctor--mode ()
  "`agent-ui-mode': it ties Agent UI to agent-shell."
  (cond
   ((bound-and-true-p agent-ui-mode)
    (agent-ui-doctor--check "Setup" "agent-ui-mode" 'ok "on"))
   ((featurep 'agent-ui)
    (agent-ui-doctor--check "Setup" "agent-ui-mode" 'fail
                            "off: agents aren't told of their canvas, nor get its MCP tools"
                            "M-x agent-ui-mode, or (agent-ui-mode 1) in your init"))
   (t
    (agent-ui-doctor--check "Setup" "agent-ui-mode" 'fail "Agent UI isn't loaded"
                            "(require 'agent-ui) and (agent-ui-mode 1) in your init"))))

(defun agent-ui-doctor--agent-shell ()
  "Agent-shell's functions Agent UI ties into: still there."
  (let ((missing (seq-remove #'fboundp '(agent-shell--make-acp-client agent-shell--system-prompt))))
    (cond
     ((not (featurep 'agent-shell))
      (agent-ui-doctor--check "Setup" "agent-shell hooks" 'warn "not checked: agent-shell isn't loaded"
                              "Install agent-shell (see Required)"))
     (missing
      (agent-ui-doctor--check "Setup" "agent-shell hooks" 'fail
                              (format "this agent-shell has no %s: sessions won't find their canvas"
                                      (string-join (mapcar #'symbol-name missing) ", "))
                              "Use an agent-shell version Agent UI supports, and report it: M-x agent-ui-report-bug"))
     (t (agent-ui-doctor--check "Setup" "agent-shell hooks" 'ok "the functions Agent UI ties into are there")))))

(defun agent-ui-doctor--mcp ()
  "Agent UI's MCP server, for sessions: registered, and what it runs there."
  (let ((emacs (expand-file-name invocation-name invocation-directory))
        (server (expand-file-name "agent-ui-mcp.el" agent-ui-doctor--directory)))
    (cond
     ((and (boundp 'agent-ui-mcp) (not agent-ui-mcp))
      (agent-ui-doctor--check "Setup" "MCP tools" 'ok "off (agent-ui-mcp is nil): agents use the command"))
     ((not (bound-and-true-p agent-ui-mode))
      (agent-ui-doctor--check "Setup" "MCP tools" 'warn "not registered: agent-ui-mode is off"
                              "(agent-ui-mode 1) in your init"))
     ((not (boundp 'agent-shell-mcp-servers))
      (agent-ui-doctor--check "Setup" "MCP tools" 'fail "this agent-shell has no agent-shell-mcp-servers"
                              "Update agent-shell, or (setq agent-ui-mcp nil): agents use the command"))
     ((not (seq-find (lambda (s) (equal (alist-get 'name s) "agent-ui")) agent-shell-mcp-servers))
      (agent-ui-doctor--check "Setup" "MCP tools" 'fail
                              "not in agent-shell-mcp-servers: something set it after agent-ui-mode"
                              "Turn on agent-ui-mode after your init sets agent-shell-mcp-servers (or M-x agent-ui-mode twice)"))
     ((not (file-executable-p emacs))
      (agent-ui-doctor--check "Setup" "MCP tools" 'fail (format "its Emacs, %s, isn't there" emacs)
                              "Restart Emacs (it moved since it started)"))
     ((not (file-readable-p server))
      (agent-ui-doctor--check "Setup" "MCP tools" 'fail
                              (format "agent-ui-mcp.el is missing from %s" (abbreviate-file-name agent-ui-doctor--directory))
                              "Reinstall Agent UI"))
     (t (agent-ui-doctor--check "Setup" "MCP tools" 'ok
                                (format "registered, run by %s (sessions started since)"
                                        (abbreviate-file-name emacs)))))))

;; ====== OPTIONAL ======

(defun agent-ui-doctor--program (name program uses fix)
  "Return the check of NAME, done with PROGRAM, as Emacs runs it.
Looked for on the variable `exec-path'.  USES says what needs it; FIX,
how to install it."
  (if-let* ((file (executable-find program)))
      (agent-ui-doctor--check "Optional" name 'ok (abbreviate-file-name file))
    (agent-ui-doctor--check "Optional" name 'warn (format "%s isn't installed: %s" program uses) fix)))

(defun agent-ui-doctor--svg ()
  "SVG images: charts, gauges, graphs and the like are drawn as SVG."
  (if (image-type-available-p 'svg)
      (agent-ui-doctor--check "Optional" "SVG images" 'ok "supported")
    (agent-ui-doctor--check "Optional" "SVG images" 'warn
                            "this Emacs has none: charts, gauges and graphs drawn as text, diagrams and formulas not shown"
                            "An Emacs built with librsvg")))

(defun agent-ui-doctor--graphics ()
  "A graphical frame: drawings are images only there."
  (if (seq-some #'display-graphic-p (frame-list))
      (agent-ui-doctor--check "Optional" "Graphical frame" 'ok "drawings shown as images")
    (agent-ui-doctor--check "Optional" "Graphical frame" 'warn
                            "terminal frames only: components drawn as text, diagrams and formulas not shown"
                            "A graphical frame (emacsclient -c), for images")))

(defun agent-ui-doctor--mermaid ()
  "Mermaid's CLI, mmdc: mermaid diagrams."
  (agent-ui-doctor--program "Mermaid diagrams" (if (boundp 'agent-ui-mmdc) agent-ui-mmdc "mmdc")
                            "mermaid components and diagrams in markdown not drawn"
                            "npm install -g @mermaid-js/mermaid-cli"))

(defun agent-ui-doctor--math ()
  "A tool typesetting formulas: MathJax (Node's mathjax-full), else LaTeX."
  (let ((tool (cond ((fboundp 'agent-ui-math--tool) (agent-ui-math--tool))
                    ((and (executable-find "latex") (executable-find "dvisvgm")) 'latex))))
    (cond
     ((and (boundp 'agent-ui-math-tool) (eq agent-ui-math-tool 'none))
      (agent-ui-doctor--check "Optional" "Math" 'ok "off (agent-ui-math-tool is none)"))
     ((eq tool 'mathjax) (agent-ui-doctor--check "Optional" "Math" 'ok "MathJax, with Node"))
     ((eq tool 'latex) (agent-ui-doctor--check "Optional" "Math" 'ok "LaTeX and dvisvgm"))
     (t (agent-ui-doctor--check "Optional" "Math" 'warn
                                "no MathJax nor LaTeX: math components shown as their TeX"
                                "npm install -g mathjax-full (with Node), or install LaTeX and dvisvgm")))))

(defun agent-ui-doctor--curl ()
  "Curl: images from URLs."
  (agent-ui-doctor--program "Images from URLs" "curl" "image components from URLs not shown"
                            "Install curl"))

(defun agent-ui-doctor--pdf ()
  "Rsvg-convert: a canvas exported as a PDF."
  (agent-ui-doctor--program "PDF export" (if (boundp 'agent-ui-pdf-program) agent-ui-pdf-program "rsvg-convert")
                            "canvases not exported as PDFs"
                            "Install librsvg: brew install librsvg, apt install librsvg2-bin"))

(defun agent-ui-doctor--markdown ()
  "Agent-shell's Markdown renderer: markdown components."
  (if (locate-library "agent-shell-markdown")
      (agent-ui-doctor--check "Optional" "Markdown" 'ok "agent-shell's renderer")
    (agent-ui-doctor--check "Optional" "Markdown" 'warn
                            "agent-shell-markdown isn't there: markdown components shown as plain text"
                            "Update agent-shell (its renderer comes with it)")))

(defun agent-ui-doctor--git ()
  "Git: a bug report names the library's commit."
  (agent-ui-doctor--program "Bug reports" "git" "bug reports without the library's commit" "Install git"))

(defun agent-ui-doctor--icons ()
  "Nerd-icons: the dashboards' icons."
  (if (locate-library "nerd-icons")
      (agent-ui-doctor--check "Optional" "Dashboard icons" 'ok "nerd-icons")
    (agent-ui-doctor--check "Optional" "Dashboard icons" 'warn "nerd-icons isn't installed: dashboards' icons as plain text"
                            "Install nerd-icons, and its fonts (M-x nerd-icons-install-fonts)")))

;; ====== ALL OF THEM ======

(defun agent-ui-doctor-checks ()
  "Check what Agent UI needs here; return the checks.
Each is a plist: :group (\"Required\", \"Setup\" or \"Optional\"), :name,
:status (`ok', `warn' or `fail'), :detail (what it found), and :fix (what
to do) when it isn't ok.  The packages Agent UI needs are loaded, if they
aren't yet, to see that they load.  See `agent-ui-doctor-functions'."
  (mapcan (lambda (fn)
            (let ((result (condition-case err
                              (funcall fn)
                            (error (agent-ui-doctor--check
                                    "Setup" (if (symbolp fn) (symbol-name fn) "A check") 'fail
                                    (format "the check itself failed: %s" (error-message-string err))
                                    "Report it: M-x agent-ui-report-bug")))))
              (if (keywordp (car result)) (list result) result)))
          agent-ui-doctor-functions))

(defun agent-ui-doctor--count (checks status)
  "Return how many of CHECKS have STATUS."
  (cl-count status checks :key (lambda (check) (plist-get check :status))))

(defun agent-ui-doctor--summary (checks)
  "Return CHECKS' summary: how many failed, warned and passed."
  (let ((fail (agent-ui-doctor--count checks 'fail))
        (warn (agent-ui-doctor--count checks 'warn))
        (ok (agent-ui-doctor--count checks 'ok)))
    (string-join (delq nil (list (unless (zerop fail) (format "%d failed" fail))
                                 (unless (zerop warn) (format "%d warning%s" warn (if (= warn 1) "" "s")))
                                 (format "%d passed" ok)))
                 ", ")))

;; ====== THE REPORT ======

(define-derived-mode agent-ui-doctor-mode special-mode "Agent UI doctor"
  "The report of `agent-ui-doctor'.
\\<agent-ui-doctor-mode-map>\\[revert-buffer] checks again."
  (setq-local revert-buffer-function
              (lambda (&rest _) (agent-ui-doctor--insert (agent-ui-doctor-checks))))
  (setq-local truncate-lines nil
              word-wrap t))

(defun agent-ui-doctor--insert (checks)
  "Write the report of CHECKS in this buffer, in place of its text."
  (let* ((inhibit-read-only t)
         (width (apply #'max 0 (mapcar (lambda (check) (string-width (plist-get check :name))) checks)))
         (indent (make-string (+ width 6) ?\s)))
    (erase-buffer)
    (insert (propertize "Agent UI doctor" 'face 'bold) "  " (agent-ui-doctor--summary checks) "\n"
            (propertize (format "Agent UI in %s, Emacs %s.  g: check again"
                                (abbreviate-file-name agent-ui-doctor--directory) emacs-version)
                        'face 'shadow)
            "\n")
    (dolist (group (seq-uniq (mapcar (lambda (check) (plist-get check :group)) checks)))
      (insert "\n" (propertize group 'face 'bold) "\n")
      (dolist (check (seq-filter (lambda (check) (equal (plist-get check :group) group)) checks))
        (pcase-let ((`(,mark ,face) (alist-get (plist-get check :status) agent-ui-doctor--marks)))
          (insert (propertize (concat "  " (propertize mark 'face face) "  "
                                      (string-pad (plist-get check :name) width) "  "
                                      (plist-get check :detail) "\n")
                              'wrap-prefix indent))
          (when-let* ((fix (plist-get check :fix)))
            (insert (propertize (concat indent (propertize "Fix: " 'face face) fix "\n")
                                'wrap-prefix indent))))))
    (goto-char (point-min))))

;;;###autoload
(defun agent-ui-doctor ()
  "Check what Agent UI needs in this Emacs, and show what's missing.
Called interactively, the report shows in `agent-ui-doctor-buffer': each
check, and each problem's fix (g there checks again).  Returns the checks
\(see `agent-ui-doctor-checks')."
  (interactive)
  (let ((checks (agent-ui-doctor-checks)))
    (when (called-interactively-p 'any)
      (with-current-buffer (get-buffer-create agent-ui-doctor-buffer)
        (agent-ui-doctor-mode)
        (agent-ui-doctor--insert checks)
        (pop-to-buffer (current-buffer))))
    checks))

;; ====== FOR THE COMMAND ======
;; bin/agent-ui doctor makes its own checks (an emacsclient, its session),
;; then asks Emacs for its: its request folder's payload is the command's
;; file, then its checks, a line each (STATUS, NAME, DETAIL, FIX, separated
;; by tabs).  The reply is written without Emacs's JSON (it may be what's
;; missing).

(defun agent-ui-doctor--copy (command)
  "Return the check of COMMAND, the command asking: the one agents are given?"
  (let ((own (if (boundp 'agent-ui-command)
                 agent-ui-command
               (expand-file-name "bin/agent-ui" agent-ui-doctor--directory))))
    (if (file-equal-p command own)
        (agent-ui-doctor--check "Command" "Its copy" 'ok "the one Emacs gives agents")
      (agent-ui-doctor--check "Command" "Its copy" 'warn
                              (format "this is %s, but Emacs gives agents %s"
                                      (abbreviate-file-name command) (abbreviate-file-name own))
                              "Run Emacs's (an older copy of the package may be on PATH)"))))

(cl-defun agent-ui-doctor-reply (&key command given)
  "Return the doctor's reply, a plist written as JSON.
GIVEN: the command's own checks, first; COMMAND: its file, compared with
`agent-ui-command'.  :ok is :false when a check fails."
  (let ((checks (append given
                        (when (and command (not (string-empty-p command)))
                          (list (agent-ui-doctor--copy command)))
                        (agent-ui-doctor-checks))))
    (list :ok (if (zerop (agent-ui-doctor--count checks 'fail)) t :false)
          :summary (agent-ui-doctor--summary checks)
          :checks (vconcat checks))))

(defun agent-ui-doctor--json-string (string)
  "Return STRING as a JSON string."
  (concat "\""
          (replace-regexp-in-string
           "[\"\\[:cntrl:]]"
           (lambda (c)
             (pcase c
               ("\"" "\\\"") ("\\" "\\\\") ("\n" "\\n") ("\t" "\\t")
               (_ (format "\\u%04x" (aref c 0)))))
           string t t)
          "\""))

(defun agent-ui-doctor--json (value)
  "Return VALUE as JSON: plists as objects, vectors as arrays.
t and :false are true and false, nil null, other symbols strings."
  (cond
   ((eq value t) "true")
   ((eq value :false) "false")
   ((null value) "null")
   ((numberp value) (number-to-string value))
   ((stringp value) (agent-ui-doctor--json-string value))
   ((symbolp value) (agent-ui-doctor--json-string (symbol-name value)))
   ((vectorp value) (concat "[" (mapconcat #'agent-ui-doctor--json value ",") "]"))
   (t (concat "{"
              (mapconcat #'identity
                         (cl-loop for (key val) on value by #'cddr
                                  collect (concat (agent-ui-doctor--json-string (substring (symbol-name key) 1))
                                                  ":" (agent-ui-doctor--json val)))
                         ",")
              "}"))))

(defun agent-ui-doctor--given (line)
  "Return the command's check LINE (STATUS, NAME, DETAIL, FIX) as a check."
  (pcase-let ((`(,status ,name ,detail ,fix) (split-string line "\t")))
    (agent-ui-doctor--check "Command" (or name "?")
                            (if (member status '("ok" "warn" "fail")) (intern status) 'fail)
                            (or detail "")
                            (and fix (not (string-empty-p fix)) fix))))

;;;###autoload
(defun agent-ui-doctor-request (folder)
  "Answer bin/agent-ui doctor's request in FOLDER: its reply written there.
See above for its payload.  Never signals: an error is the reply."
  (let* ((payload (expand-file-name "payload" folder))
         (reply (condition-case err
                    (let ((lines (when (file-readable-p payload)
                                   (with-temp-buffer
                                     (let ((coding-system-for-read 'utf-8))
                                       (insert-file-contents payload))
                                     (split-string (buffer-string) "\n" t)))))
                      (agent-ui-doctor-reply :command (car lines)
                                             :given (mapcar #'agent-ui-doctor--given (cdr lines))))
                  (error (list :ok :false :error (error-message-string err))))))
    (let ((coding-system-for-write 'utf-8))
      (write-region (concat (agent-ui-doctor--json reply) "\n") nil
                    (expand-file-name "reply" folder) nil 'silent))
    t))

(provide 'agent-ui-doctor)

;;; agent-ui-doctor.el ends here
