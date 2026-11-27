;;; agent-ui-doctor-tests.el --- Tests for Agent UI: doctor  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-doctor.el: each check passing and failing (a package missing,
;; too old, not loading; the package's files; no server; a program not on
;; PATH; a tool missing), the report, the reply bin/agent-ui gets.  The
;; script's own side: in agent-ui-request-tests.el.

;;; Code:

(require 'agent-ui-test-helper)
(require 'server)

;; ====== HELPERS ======

(defun agent-ui-test-doctor-find (name checks)
  "The check NAME among CHECKS."
  (seq-find (lambda (check) (equal (plist-get check :name) name)) checks))

(defun agent-ui-test-doctor-status (check)
  "CHECK's status."
  (plist-get check :status))

;; ====== REQUIRED ======

(ert-deftest agent-ui-doctor/everything-required-here ()
  "This test Emacs has what Agent UI needs: each Required check passes,
agent-shell's own requirements listed for it; each check's shape."
  (let* ((checks (agent-ui-doctor-checks))
         (required (seq-filter (lambda (c) (equal (plist-get c :group) "Required")) checks)))
    (dolist (check required)
      (should (eq (agent-ui-test-doctor-status check) 'ok)))
    (let ((names (mapcar (lambda (c) (plist-get c :name)) required)))
      (should (equal (seq-take names 3) '("Emacs" "agent-shell" "vui")))
      (should (member "shell-maker" names))
      (should (member "acp" names))
      (should (equal (last names 3) '("JSON" "Package files" "Command"))))
    (should (string-match-p ", for agent-shell), in " (plist-get (agent-ui-test-doctor-find "acp" checks) :detail)))
    ;; A fix only when it isn't ok; a warning, never a failure, for what's optional.
    (dolist (check checks)
      (should (member (plist-get check :group) '("Required" "Setup" "Optional")))
      (should (memq (agent-ui-test-doctor-status check) '(ok warn fail)))
      (should (stringp (plist-get check :detail)))
      (should (eq (null (plist-get check :fix)) (eq (agent-ui-test-doctor-status check) 'ok)))
      (when (equal (plist-get check :group) "Optional")
        (should-not (eq (agent-ui-test-doctor-status check) 'fail))))))

(ert-deftest agent-ui-doctor/requirements-walked ()
  "Agent UI's requirements, then theirs: each once, at the later minimum."
  (cl-letf (((symbol-function 'agent-ui-doctor--source) (lambda (library) (concat "/pkgs/" library ".el")))
            ((symbol-function 'agent-ui-doctor--headers)
             (lambda (file)
               (pcase (file-name-nondirectory file)
                 ("agent-ui.el" '(nil (emacs "29.1") (a "1.0") (b "2.0")))
                 ("a.el" '("1.0" (emacs "30.1") (b "2.5") (c "0.1")))
                 ("b.el" '("2.5" (a "0.5")))
                 (_ '("1"))))))
    (should (equal (agent-ui-doctor--requirements)
                   '((emacs "30.1" a) (a "1.0" nil) (b "2.5" a) (c "0.1" a))))))

(ert-deftest agent-ui-doctor/a-package-missing ()
  (cl-letf* ((locate (symbol-function 'locate-library))
             ((symbol-function 'locate-library)
              (lambda (library &rest args) (unless (equal library "vui") (apply locate library args)))))
    (let ((check (agent-ui-test-doctor-find "vui" (agent-ui-doctor--packages))))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (equal (plist-get check :detail) "not installed (1.4.0 or later needed)"))
      (should (string-match-p "package-install RET vui" (plist-get check :fix))))))

(ert-deftest agent-ui-doctor/a-package-too-old-or-unknown ()
  (cl-letf* ((headers (symbol-function 'agent-ui-doctor--headers))
             (vui-version "1.2.0")
             ((symbol-function 'agent-ui-doctor--headers)
              (lambda (file)
                (if (string-match-p "/vui\\.el\\'" file) (list vui-version) (funcall headers file)))))
    (let ((check (agent-ui-test-doctor-find "vui" (agent-ui-doctor--packages))))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (string-match-p "\\`1\\.2\\.0, older than needed (1\\.4\\.0 or later), in " (plist-get check :detail)))
      (should (string-match-p "package-upgrade RET vui" (plist-get check :fix))))
    ;; Later: fine.
    (setq vui-version "1.10.0")
    (should (eq (agent-ui-test-doctor-status (agent-ui-test-doctor-find "vui" (agent-ui-doctor--packages))) 'ok))
    ;; No version to read: a warning.
    (setq vui-version nil)
    (let ((check (agent-ui-test-doctor-find "vui" (agent-ui-doctor--packages))))
      (should (eq (agent-ui-test-doctor-status check) 'warn))
      (should (string-match-p "\\`its version unknown (1\\.4\\.0 or later needed)" (plist-get check :detail))))))

(ert-deftest agent-ui-doctor/a-package-not-loading ()
  (should-not (agent-ui-doctor--load-error 'cl-lib))
  (should (string-match-p "agent-ui-no-such-feature" (agent-ui-doctor--load-error 'agent-ui-no-such-feature)))
  (cl-letf* ((load-error (symbol-function 'agent-ui-doctor--load-error))
             ((symbol-function 'agent-ui-doctor--load-error)
              (lambda (feature)
                (if (eq feature 'vui) "Symbol's value as variable is void: x" (funcall load-error feature)))))
    (let ((check (agent-ui-test-doctor-find "vui" (agent-ui-doctor--packages))))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (equal (plist-get check :detail) "doesn't load: Symbol's value as variable is void: x"))
      (should (string-match-p "\\`Reinstall vui" (plist-get check :fix))))))

(ert-deftest agent-ui-doctor/emacs-too-old ()
  (let ((emacs-version "28.2"))
    (let ((check (agent-ui-doctor--emacs)))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (equal (plist-get check :detail) "28.2, older than needed (29.1 or later)")))))

(ert-deftest agent-ui-doctor/the-package-files ()
  "bin/, skills/ and assets/ beside the Lisp: those missing named, and the
recipe's :files to fix it."
  (let ((agent-ui-doctor--directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "pkg-") t))))
    (let ((check (agent-ui-doctor--files)))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (string-match-p ": bin/agent-ui, skills/agent-ui/SKILL.md, assets/tex2svg.js\\'" (plist-get check :detail)))
      (should (string-search ":files (:defaults \"bin\" \"skills\" \"assets\")" (plist-get check :fix))))
    (make-directory (expand-file-name "bin" agent-ui-doctor--directory))
    (write-region "" nil (expand-file-name "bin/agent-ui" agent-ui-doctor--directory))
    (should (string-match-p ": skills/agent-ui/SKILL.md, assets/tex2svg.js\\'"
                            (plist-get (agent-ui-doctor--files) :detail)))))

(ert-deftest agent-ui-doctor/the-command ()
  (let ((agent-ui-command (make-temp-file (agent-ui-test-tmp-file "cmd-"))))
    (set-file-modes agent-ui-command #o644)
    (let ((check (agent-ui-doctor--command)))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (string-match-p "isn't executable\\'" (plist-get check :detail)))
      (should (string-prefix-p "chmod +x " (plist-get check :fix))))
    (set-file-modes agent-ui-command #o755)
    (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--command)) 'ok)))
  (let ((agent-ui-command "/no/such/agent-ui"))
    (should (equal (plist-get (agent-ui-doctor--command) :detail) "/no/such/agent-ui isn't there"))))

;; ====== SETUP ======

(ert-deftest agent-ui-doctor/the-server ()
  (let ((server-process nil))
    (let ((check (agent-ui-doctor--server)))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (string-match-p "server-start" (plist-get check :fix)))))
  (let ((server-socket-dir (make-temp-file "/tmp/aui-" t))
        (server-name "doctor"))
    (unwind-protect
        (progn (server-start nil t)
               (should (equal (agent-ui-doctor--server)
                              '(:group "Setup" :name "Emacs server" :status ok :detail "running, named doctor"))))
      (server-force-delete)
      (delete-directory server-socket-dir t))))

(ert-deftest agent-ui-doctor/programs-on-path ()
  "Emacsclient and bash looked for on PATH, as agents' shells find them."
  (let ((process-environment (append '("PATH=/no/such/dir" "EMACSCLIENT") process-environment)))
    (let ((check (agent-ui-doctor--bash)))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (string-match-p "not on PATH" (plist-get check :detail))))
    (let ((check (agent-ui-doctor--emacsclient)))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (equal (plist-get check :detail) "emacsclient isn't on PATH"))))
  (let* ((dir (make-temp-file (agent-ui-test-tmp-file "path-") t))
         (bash (expand-file-name "bash" dir)))
    (write-region "" nil bash)
    (set-file-modes bash #o755)
    (let ((process-environment (cons (concat "PATH=" dir) process-environment)))
      (should (equal (plist-get (agent-ui-doctor--bash) :detail) (abbreviate-file-name bash))))
    ;; EMACSCLIENT: its file.
    (let ((process-environment (cons (concat "EMACSCLIENT=" bash) process-environment)))
      (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--emacsclient)) 'ok)))))

(ert-deftest agent-ui-doctor/the-mode-and-mcp ()
  (let ((agent-shell-mcp-servers (list (agent-ui-mcp-server)))
        (agent-ui-mcp t))
    (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--mode)) 'ok))
    (should (string-match-p "\\`registered, run by " (plist-get (agent-ui-doctor--mcp) :detail)))
    ;; Something set agent-shell-mcp-servers after the mode.
    (let ((agent-shell-mcp-servers nil))
      (let ((check (agent-ui-doctor--mcp)))
        (should (eq (agent-ui-test-doctor-status check) 'fail))
        (should (string-match-p "not in agent-shell-mcp-servers" (plist-get check :detail)))))
    ;; The mode off.
    (let ((agent-ui-mode nil))
      (let ((check (agent-ui-doctor--mode)))
        (should (eq (agent-ui-test-doctor-status check) 'fail))
        (should (string-match-p "(agent-ui-mode 1)" (plist-get check :fix))))
      (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--mcp)) 'warn)))
    ;; Its MCP off: fine.
    (let ((agent-ui-mcp nil))
      (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--mcp)) 'ok)))))

(ert-deftest agent-ui-doctor/agent-shell-changed ()
  "Agent-shell without a function Agent UI ties into: a failure naming it."
  (require 'agent-shell)
  (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--agent-shell)) 'ok))
  (cl-letf (((symbol-function 'agent-shell--system-prompt) nil))
    (let ((check (agent-ui-doctor--agent-shell)))
      (should (eq (agent-ui-test-doctor-status check) 'fail))
      (should (string-match-p "has no agent-shell--system-prompt" (plist-get check :detail))))))

;; ====== OPTIONAL ======

(ert-deftest agent-ui-doctor/a-tool-missing ()
  "A tool some components use, missing: a warning saying what it's for, and
how to install it."
  (cl-letf (((symbol-function 'executable-find) #'ignore)
            ((symbol-function 'agent-ui-math--tool) #'ignore))
    (let ((check (agent-ui-doctor--mermaid)))
      (should (eq (agent-ui-test-doctor-status check) 'warn))
      (should (string-match-p "\\`mmdc isn't installed: mermaid" (plist-get check :detail)))
      (should (equal (plist-get check :fix) "npm install -g @mermaid-js/mermaid-cli")))
    (dolist (check (list (agent-ui-doctor--curl) (agent-ui-doctor--pdf) (agent-ui-doctor--math) (agent-ui-doctor--git)))
      (should (eq (agent-ui-test-doctor-status check) 'warn))
      (should (plist-get check :fix)))
    (should (string-match-p "librsvg" (plist-get (agent-ui-doctor--pdf) :fix)))
    ;; Math off: nothing to install.
    (let ((agent-ui-math-tool 'none))
      (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--math)) 'ok))))
  (cl-letf (((symbol-function 'executable-find) (lambda (program &rest _) (concat "/opt/bin/" program))))
    (should (equal (agent-ui-doctor--mermaid)
                   '(:group "Optional" :name "Mermaid diagrams" :status ok :detail "/opt/bin/mmdc"))))
  (cl-letf (((symbol-function 'image-type-available-p) #'ignore))
    (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--svg)) 'warn)))
  ;; In batch: no graphical frame.
  (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--graphics)) 'warn)))

(ert-deftest agent-ui-doctor/a-check-failing ()
  "A check that signals is a failure said, the others made all the same."
  (cl-letf (((symbol-function 'agent-ui-doctor--bash) (lambda () (error "Boom"))))
    (let* ((agent-ui-doctor-functions '(agent-ui-doctor--bash agent-ui-doctor--json-support))
           (checks (agent-ui-doctor-checks)))
      (should (equal (mapcar (lambda (c) (plist-get c :name)) checks) '("agent-ui-doctor--bash" "JSON")))
      (should (equal (plist-get (car checks) :detail) "the check itself failed: Boom")))))

;; ====== THE REPORT ======

(ert-deftest agent-ui-doctor/the-report ()
  (let ((agent-ui-doctor-functions '(agent-ui-doctor--json-support agent-ui-doctor--server))
        (server-process nil))
    (should (equal (mapcar #'agent-ui-test-doctor-status (agent-ui-doctor)) '(ok fail)))
    ;; Not shown from Lisp.
    (should-not (get-buffer agent-ui-doctor-buffer))
    (save-window-excursion
      (call-interactively #'agent-ui-doctor))
    (with-current-buffer agent-ui-doctor-buffer
      (unwind-protect
          (progn
            (should (derived-mode-p 'agent-ui-doctor-mode))
            (should buffer-read-only)
            (let ((text (buffer-string)))
              (should (string-prefix-p "Agent UI doctor  1 failed, 1 passed\n" text))
              (should (string-match-p "^Required\n  ✓  JSON +built in$" text))
              (should (string-match-p "^Setup\n  ✗  Emacs server  not running" text))
              (should (string-match-p "^ +Fix: M-x server-start, or (server-start) in your init$" text)))
            ;; Its marks coloured; a long line wrapped under its text.
            (goto-char (point-min))
            (search-forward "✗")
            (should (eq (get-text-property (1- (point)) 'face) 'error))
            (should (get-text-property (point) 'wrap-prefix))
            ;; g: checked again.
            (let ((agent-ui-doctor-functions '(agent-ui-doctor--json-support)))
              (revert-buffer)
              (should (string-prefix-p "Agent UI doctor  1 passed\n" (buffer-string)))))
        (kill-buffer)))))

;; ====== FOR THE COMMAND ======

(ert-deftest agent-ui-doctor/the-reply ()
  (let ((agent-ui-doctor-functions '(agent-ui-doctor--json-support)))
    (let ((reply (agent-ui-doctor-reply
                  :command agent-ui-command
                  :given (list (agent-ui-doctor--given "warn\tSession\tnot run by a session\tRun it from an agent's shell")))))
      (should (eq (plist-get reply :ok) t))
      (should (equal (plist-get reply :summary) "1 warning, 2 passed"))
      (should (equal (append (plist-get reply :checks) nil)
                     '((:group "Command" :name "Session" :status warn :detail "not run by a session"
                        :fix "Run it from an agent's shell")
                       (:group "Command" :name "Its copy" :status ok :detail "the one Emacs gives agents")
                       (:group "Required" :name "JSON" :status ok :detail "built in")))))
    ;; Another copy of the command: said.
    (let ((copy (aref (plist-get (agent-ui-doctor-reply :command "/tmp/an/old/agent-ui") :checks) 0)))
      (should (eq (agent-ui-test-doctor-status copy) 'warn))
      (should (string-match-p "\\`this is /tmp/an/old/agent-ui, but Emacs gives agents " (plist-get copy :detail))))
    ;; One failing: not ok.
    (let ((reply (agent-ui-doctor-reply :given (list (agent-ui-doctor--given "fail\temacsclient\tnone\tInstall it")))))
      (should (eq (plist-get reply :ok) :false))
      (should (equal (plist-get reply :summary) "1 failed, 1 passed")))
    ;; A line it can't read: a failure, not an error.
    (should (eq (agent-ui-test-doctor-status (agent-ui-doctor--given "what")) 'fail))))

(ert-deftest agent-ui-doctor/its-json ()
  "Written without Emacs's JSON (it may be what's missing), read back by it."
  (let ((value '(:ok :false :a "q\"b\\s\nn\tt\ec ü" :n 3 :list [t :false nil] :s warn)))
    (should (equal (agent-ui-doctor--json value)
                   "{\"ok\":false,\"a\":\"q\\\"b\\\\s\\nn\\tt\\u001bc ü\",\"n\":3,\"list\":[true,false,null],\"s\":\"warn\"}"))
    (should (equal (json-parse-string (agent-ui-doctor--json value) :object-type 'plist
                                      :null-object nil :false-object :false)
                   '(:ok :false :a "q\"b\\s\nn\tt\ec ü" :n 3 :list [t :false nil] :s "warn")))))

(ert-deftest agent-ui-doctor/the-request ()
  "bin/agent-ui's request: its file and its checks in, the reply written."
  (let ((dir (make-temp-file (agent-ui-test-tmp-file "doctor-") t))
        (agent-ui-doctor-functions '(agent-ui-doctor--json-support)))
    (with-temp-file (expand-file-name "payload" dir)
      (insert agent-ui-command "\n"
              "ok\temacsclient\t/usr/bin/emacsclient\t\n"
              "fail\tA \"name\"\twith \\ and ü\tFix it\n"))
    (should (eq (agent-ui-doctor-request dir) t))
    (let* ((text (with-temp-buffer
                   (let ((coding-system-for-read 'utf-8))
                     (insert-file-contents (expand-file-name "reply" dir)))
                   (buffer-string)))
           (reply (json-parse-string text :object-type 'plist :array-type 'list))
           (checks (plist-get reply :checks)))
      (should (string-prefix-p "{\"ok\":false," text))
      (should (equal (plist-get reply :summary) "1 failed, 3 passed"))
      (should (equal (mapcar (lambda (c) (plist-get c :name)) checks) '("emacsclient" "A \"name\"" "Its copy" "JSON")))
      (should (equal (plist-get (nth 1 checks) :detail) "with \\ and ü"))
      (should (equal (plist-get (nth 1 checks) :group) "Command"))
      (should-not (plist-member (car checks) :fix)))))

(ert-deftest agent-ui-doctor/an-operation ()
  "Doctor, an operation: answered by `agent-ui-do', never in a batch."
  (should (member "doctor" agent-ui-operations))
  (let* ((agent-ui-doctor-functions '(agent-ui-doctor--json-support))
         (reply (agent-ui-do "doctor" nil nil "x")))
    (should (eq (plist-get reply :ok) t))
    (should (equal (plist-get (aref (plist-get reply :checks) 0) :name) "JSON")))
  (should (string-match-p "doctor isn't done in a batch"
                          (plist-get (agent-ui--batch-item '(:op "doctor") "x") :error))))

;;; agent-ui-doctor-tests.el ends here
