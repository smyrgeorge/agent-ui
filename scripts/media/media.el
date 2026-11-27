;;; media.el --- The README's screenshots and GIFs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run by scripts/media.sh, in a GUI `emacs -Q' of its own (its own temp
;; folders: your Emacs and its settings aren't touched).  Each scene is
;; played in one frame, with a dark theme (doom-one if it's on the
;; load-path, `make media-deps' clones it; else modus-vivendi), then
;; captured with macOS's screencapture: a still into OUT/NAME.png, or, for
;; a GIF, a frame every `media-frame-interval' seconds into
;; OUT/NAME-frames/ (scripts/media.sh makes the GIF with ffmpeg).
;;
;; Scenes (MEDIA_SCENES picks some, space-separated; default all):
;;   release   an agent-shell session with a stand-in agent releasing a
;;             project, its canvases filling in under the conversation:
;;             release.gif, and its last frame session.png
;;   figures   a canvas of figures: stats, gauge, charts, heatmap, timeline
;;   content   a canvas of changes: files, graph, diff, code, log, mermaid
;;   asking    a choice answered, a ranking reordered: asking.gif
;;   dashboard a project's dashboard, opened from its repository: dashboard.png
;;
;; Its progress, lines starting with "media:", go to stderr.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar media-root (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name)))
  "The repository's folder.")

(defvar media-out (or (getenv "MEDIA_OUT") (expand-file-name "docs/images/" media-root))
  "Where the screenshots and GIF frames go.")

(defvar media-tmp (file-name-as-directory (or (getenv "MEDIA_TMP") (make-temp-file "agent-ui-media-" t)))
  "This run's temp folder: the user's Emacs directory, the scenes' projects.")

(defvar media-size '(1200 . 860)
  "The frame's text area in pixels: narrow, so GitHub shrinks the text little.")

(defvar media-frame-interval 0.25
  "Seconds between a GIF's frames (scripts/media.sh plays them at 4 a second).")

;; ====== TOOLS ======

(defun media--say (format-string &rest args)
  "A progress line on stderr: FORMAT-STRING with ARGS."
  (princ (concat "media: " (apply #'format format-string args) "\n") #'external-debugging-output))

(defun media--sleep (seconds)
  "Let SECONDS pass, redisplaying, timers and processes running."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (redisplay t)
      (accept-process-output nil (min 0.05 (max 0.001 (- end (float-time))))))))

(defun media--wait (predicate timeout)
  "Wait until PREDICATE returns non-nil, TIMEOUT seconds at most."
  (let ((end (+ (float-time) timeout)))
    (while (and (not (funcall predicate)) (< (float-time) end))
      (media--sleep 0.1))
    (funcall predicate)))

(defun media--reset ()
  "One window on *scratch*, the scenes' buffers killed, the echo area empty."
  (let ((ignore-window-parameters t))
    (delete-other-windows))
  (switch-to-buffer (get-buffer-create "*scratch*"))
  (dolist (buffer (buffer-list))
    (unless (or (not (buffer-live-p buffer))
                (eq buffer (current-buffer))
                (string-prefix-p " " (buffer-name buffer))
                (member (buffer-name buffer) '("*Messages*" "*scratch*")))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))))
  (message nil)
  (redisplay t))

;; ====== THE LOOK ======

(defun media--setup ()
  "A dark theme, a coding font, a plain frame."
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (menu-bar-mode -1)
  (blink-cursor-mode -1)
  (setq-default cursor-in-non-selected-windows nil)
  (setq inhibit-startup-screen t
        ring-bell-function #'ignore)
  (if (require 'doom-themes nil t)
      (load-theme 'doom-one t)
    (load-theme 'modus-vivendi t))
  (when (find-font (font-spec :family "JetBrains Mono"))
    (set-frame-font (font-spec :family "JetBrains Mono" :size 13) nil t))
  (require 'agent-ui)
  (server-start)
  (agent-ui-mode 1)
  ;; A question doesn't take the focus, nor leaves once answered: the
  ;; scenes show it answered.
  (setq agent-ui-focus-questions nil))

(defun media--place (frame &optional size)
  "FRAME at SIZE (default `media-size'), near its screen's top left, on top."
  (let ((size (or size media-size)))
    (pcase-let ((`(,x ,y ,width ,height) (frame-monitor-workarea frame)))
      (set-frame-parameter frame 'fullscreen nil)
      (set-frame-parameter frame 'z-group 'above)
      (set-frame-size frame (min (car size) (- width 80)) (min (cdr size) (- height 120)) t)
      (set-frame-position frame (+ x 40) (+ y 40))
      (select-frame-set-input-focus frame)
      (media--sleep 0.5))))

;; ====== CAPTURING ======
;; The frame's window captured (screencapture -l: its title bar too, no
;; shadow), by its macOS window number, asked of the window list (JavaScript
;; for Automation): Emacs's own `window-id' isn't it.

(defconst media--windows-script
  "ObjC.import('CoreGraphics');
function run(argv) {
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0));
  const lines = [];
  for (let i = 0; i < list.count; i++) {
    const w = ObjC.deepUnwrap(list.objectAtIndex(i));
    if (w.kCGWindowOwnerPID == argv[0]) {
      const b = w.kCGWindowBounds;
      lines.push([w.kCGWindowNumber, b.X, b.Y, b.Width, b.Height].join(' '));
    }
  }
  return lines.join('\\n');
}"
  "Prints this Emacs's windows: \"NUMBER X Y WIDTH HEIGHT\" a line each.")

(defun media--window-number (frame)
  "FRAME's macOS window number, or nil."
  (pcase-let* ((`(,left ,top ,right ,bottom) (frame-edges frame 'outer-edges))
               (windows
                (with-temp-buffer
                  (and (eql 0 (call-process "osascript" nil '(t nil) nil "-l" "JavaScript"
                                            "-e" media--windows-script (number-to-string (emacs-pid))))
                       (mapcar (lambda (line) (mapcar #'string-to-number (split-string line)))
                               (split-string (buffer-string) "\n" t))))))
    (car (or (seq-find (lambda (w) (equal (cdr w) (list left top (- right left) (- bottom top)))) windows)
             (and (= (length windows) 1) (car windows))))))

(defun media--capture (frame file &optional number)
  "Capture FRAME's window (its macOS window NUMBER, if known) into FILE."
  (let ((number (or number (media--window-number frame))))
    (pcase-let ((`(,left ,top ,right ,bottom) (frame-edges frame 'outer-edges)))
      (redisplay t)
      (apply #'call-process "screencapture" nil nil nil
             (append '("-x" "-t" "png")
                     (if number
                         (list "-o" "-l" (number-to-string number))
                       (list "-R" (format "%d,%d,%d,%d" left top (- right left) (- bottom top))))
                     (list file)))
      (file-exists-p file))))

(defun media-still (name scene &optional size)
  "Play SCENE (it returns a predicate: ready), capture it into NAME.png."
  (media--reset)
  (media--place (selected-frame) size)
  (let ((ready (funcall scene)))
    (unless (media--wait ready 40)
      (media--say "%s: not ready after 40 s, captured as it is" name))
    (media--sleep 1.0)
    (message nil)
    (let ((file (expand-file-name (concat name ".png") media-out)))
      (if (media--capture (selected-frame) file)
          (media--say "%s" file)
        (media--say "%s: not captured (the terminal needs the Screen Recording permission)" name))))
  (media--reset))

(defun media-gif (name scene &optional size tail still)
  "Record SCENE as NAME-frames/ until TAIL seconds after it's ready.
STILL: its last frame also saved as STILL.png."
  (media--reset)
  (media--place (selected-frame) size)
  (let* ((dir (file-name-as-directory (expand-file-name (concat name "-frames") media-out)))
         (number (media--window-number (selected-frame)))
         (start (float-time))
         (n 0)
         end ready)
    (when (file-directory-p dir) (delete-directory dir t))
    (make-directory dir t)
    (setq ready (funcall scene))
    (message nil)
    (while (and (< (- (float-time) start) 90)
                (or (not end) (< (float-time) end)))
      (let ((t0 (float-time)))
        (setq n (1+ n))
        (media--capture (selected-frame) (expand-file-name (format "%04d.png" n) dir) number)
        (when (and (not end) (funcall ready))
          (message nil)
          (setq end (+ (float-time) (or tail 2.0))))
        (media--sleep (max 0.02 (- media-frame-interval (- (float-time) t0))))))
    (when still
      (copy-file (expand-file-name (format "%04d.png" n) dir)
                 (expand-file-name (concat still ".png") media-out) t)
      (media--say "%s" (expand-file-name (concat still ".png") media-out)))
    (media--say "%s %d" dir n))
  (media--reset))

;; ====== CANVASES ======

(defun media--canvas (name &rest components)
  "Canvas NAME with COMPONENTS, alone in the frame, the cursor at its top."
  (let ((canvas (agent-ui-canvas name)))
    (dolist (component components)
      (agent-ui-show component :canvas canvas))
    (with-current-buffer canvas (agent-ui--flush))
    (let ((ignore-window-parameters t))
      (delete-other-windows))
    (switch-to-buffer canvas)
    (goto-char (point-min))
    canvas))

(defun media--press (canvas text)
  "Press the button on TEXT in CANVAS, the cursor going there."
  (with-current-buffer canvas
    (agent-ui--flush)
    (goto-char (point-min))
    (when (search-forward text nil t)
      (goto-char (match-beginning 0))
      (set-window-point (get-buffer-window canvas) (point))
      (agent-ui-button-press)
      (agent-ui--flush))))

(defun media--move-up (canvas text)
  "Move the item on TEXT up in CANVAS's rank, the cursor on it."
  (with-current-buffer canvas
    (goto-char (point-min))
    (search-forward text)
    (set-window-point (get-buffer-window canvas) (point))
    (agent-ui-move-item-up)
    (agent-ui--flush)))

(defun media--play (steps)
  "Run STEPS, ((SECONDS . FUNCTION)...), each SECONDS from now."
  (dolist (step steps)
    (run-at-time (car step) nil (cdr step))))

;; ====== THE SCENES ======

(defun media-figures ()
  "A canvas of figures."
  (media--canvas
   "Figures"
   '(:id "top" :type "panel" :layout "row"
     :children ((:type "stats" :id "s" :title "This release"
                 :figures ((:label "Coverage" :value 87.1 :unit "%" :change 2.3)
                           (:label "Tests" :value 412 :change "all pass")
                           (:label "Build" :value 29 :unit "s" :change -12 :good "down")))
                (:type "gauge" :id "g" :title "Coverage" :value 78 :unit "%" :target 80 :label "lines covered"
                 :thresholds ((:at 0 :face "error") (:at 70 :face "warning") (:at 80 :face "success")))))
   '(:id "mid" :type "panel" :layout "row"
     :children ((:type "chart" :id "lat" :title "p95 latency" :unit "ms" :height 6
                 :labels ("mon" "tue" "wed" "thu" "fri" "sat" "sun")
                 :series ((:name "api" :values (120 95 180 60 75 70 64))
                          (:name "web" :values (80 85 90 110 70 66 62))))
                (:type "heatmap" :id "h" :title "Test runs by OS"
                 :rows ("lexer" "parser" "checker" "codegen")
                 :columns ("linux" "macos" "windows")
                 :values (("passed" "passed" "passed") ("passed" "flaky" "passed")
                          ("failed" "passed" "skipped") ("passed" "passed" "flaky")))))
   '(:id "ci" :type "timeline" :title "CI"
     :tasks ((:name "build" :start 0 :duration 8) (:name "test-1" :start 8 :duration 14)
             (:name "test-2" :start 8 :duration 11 :status "failed") (:name "lint" :start 8 :duration 5)
             (:name "deploy" :start 22 :duration 4 :status "queued")))
   '(:id "bottom" :type "panel" :layout "row"
     :children ((:type "chart" :id "bars" :title "Bundle size" :kind "bar" :unit "kB"
                 :labels ("v2.1" "v2.2" "v2.3" "v2.4") :values (412 398 455 389) :height 5)
                (:type "tags" :id "t" :title "Open issues"
                 :tags ((:label "bug" :face "error" :count 12) (:label "feature" :face "success" :count 4)
                        (:label "docs" :count 7) (:label "P1" :face "warning" :count 2))))))
  (lambda () t))

(defun media-content ()
  "A canvas of changes: its Mermaid diagram drawn when ready."
  (let ((canvas
         (media--canvas
          "Changes"
          '(:id "row1" :type "panel" :layout "row"
            :children ((:type "files" :id "f" :title "What I changed" :tree t
                        :files ((:path "src/parser.c" :status "changed" :added 12 :removed 3)
                                (:path "src/lexer.h" :status "added" :added 40)
                                (:path "src/checker.c" :status "changed" :added 5 :removed 9)
                                (:path "tests/parser_test.c" :status "failing" :errors 2 :line 88)))
                       (:type "graph" :id "g" :title "Modules"
                        :nodes ("lexer" "parser" (:id "checker" :status "error") "codegen")
                        :edges (("lexer" "parser") ("parser" "checker") ("parser" "codegen")
                                ("checker" "codegen")))))
          '(:id "d" :type "diff" :title "src/parser.c"
            :diff "diff --git a/src/parser.c b/src/parser.c
--- a/src/parser.c
+++ b/src/parser.c
@@ -40,6 +40,7 @@ parse_expr
   int depth = 0;
-  return NULL;
+  if (p->pos >= p->len)
+    return error(p, \"unexpected end\");
+  return parse_term(p);
 }
")
          '(:id "row2" :type "panel" :layout "row"
            :children ((:type "code" :id "code" :title "Where it fails" :language "c" :from 40
                        :code "int parse_expr(Parser *p) {\n  int depth = 0;\n  return NULL;\n}"
                        :marks ((:line 42 :kind "error" :note "never NULL here")))
                       (:type "log" :id "log" :title "server.log"
                        :lines "12:01:03 INFO  listening on :8080\n12:01:07 WARN  slow query: 1.2s\n12:01:09 ERROR db: connection refused\n12:01:12 INFO  retrying in 5s")))
          '(:id "m" :type "mermaid" :title "Release"
            :diagram "flowchart LR\n    test[Run the tests] --> build[Build] --> publish[Publish]\n    test -. fails .-> fix[Fix the test] --> test"))))
    (lambda ()
      (with-current-buffer canvas
        (agent-ui--flush)
        (not (save-excursion (goto-char (point-min)) (search-forward "drawing…" nil t)))))))

(defun media-asking ()
  "A choice answered, then a ranking reordered and sent."
  (let ((canvas (media--canvas
                 "ask"
                 '(:id "next" :type "choice" :title "Before I publish"
                   :question "checker's test expects the old error message. How do I go on?"
                   :options ((:label "Fix the test" :detail "then publish v2.4")
                             (:label "Publish anyway" :detail "the test fixed after")
                             (:label "Stop here" :detail "you look into it")))
                 '(:id "order" :type "rank" :title "Priorities" :question "What should I do first?"
                   :items ((:label "Fix the parser" :detail "the root cause") "Update the docs" "Release"))))
        (done nil))
    ;; No session: the answers go nowhere but the echo area.
    (with-current-buffer canvas
      (setq-local agent-ui-answer-function
                  (lambda (prompt _submit _key) (message "→ %s" prompt))))
    (setq agent-ui-close-answered nil)
    (media--play
     `((1.2 . ,(lambda () (media--press canvas "Fix the test")))
       (2.4 . ,(lambda () (media--press canvas "⏵ Answer")))
       (3.6 . ,(lambda () (media--move-up canvas "Release")))
       (4.6 . ,(lambda () (media--move-up canvas "Release")))
       (5.8 . ,(lambda () (media--press canvas "⏵ Answer")))
       (7.0 . ,(lambda () (setq done t)))))
    (lambda () done)))

;; The dashboard: a project's, kept in its repository
;; (.agent-ui/dashboards/service.el), opened as you open one: its file read, its
;; :ui drawn, its :fetch filling it (with a stand-in's data here: no
;; network).  Its file is trusted first, as you would when asked.

(defun media--dashboard-form ()
  "The dashboard file's form: a service's traffic, latency, CI and errors."
  `(agent-ui-dashboard
    :version 1
    :ui (:type "panel" :id "service" :title "checkout-service"
         :children ((:type "panel" :id "top" :layout "row" :border :false :weights (3 2)
                     :children ((:type "stats" :id "traffic" :title "Last hour")
                                (:type "gauge" :id "budget" :title "Error budget" :value 0 :max 100 :unit "%"
                                 :label "used this month"
                                 :thresholds ((:at 0 :face "success") (:at 60 :face "warning")
                                              (:at 85 :face "error")))))
                    (:type "panel" :id "mid" :layout "row" :border :false :weights (2 3)
                     :children ((:type "chart" :id "latency" :title "p95 latency, last 12h" :unit "ms"
                                 :height 6)
                                (:type "table" :id "ci" :title "CI on main"
                                 :columns ("Run" "Commit" "Status" "Took"))))
                    (:type "log" :id "errors" :title "Errors")))
    :every 30
    :fetch (lambda (dashboard)
             (agent-ui-dashboard-update
              dashboard "traffic"
              :figures '((:label "Requests" :value 1240 :unit "/min" :change "+8%")
                         (:label "Errors" :value 0.4 :unit "%" :change -0.2 :good "down")
                         (:label "p95" :value 182 :unit "ms" :change -14 :good "down")))
             (agent-ui-dashboard-update dashboard "budget" :value 37)
             (agent-ui-dashboard-update
              dashboard "latency"
              :labels '("08" "09" "10" "11" "12" "13" "14" "15" "16" "17" "18" "19")
              :values '(170 165 190 240 310 220 196 188 175 184 179 182))
             (agent-ui-dashboard-update
              dashboard "ci"
              :rows '(("#1432" "fix: retry payments" "running" "2m 10s")
                      ("#1431" "feat: gift cards" "passed" "4m 12s")
                      ("#1430" "chore: bump deps" "failed" "3m 48s")
                      ("#1429" "fix: tax rounding" "passed" "4m 05s")))
             (agent-ui-dashboard-update
              dashboard "errors"
              :lines "11:58:12 ERROR payments: gateway timeout after 30s (order 88213)
12:03:40 WARN  cart: slow query, 1.4s
12:07:05 ERROR payments: gateway timeout after 30s (order 88297)
12:11:31 INFO  payments: retry policy deployed (#1432)"))))

(defun media-dashboard ()
  "A project's dashboard, opened from its repository."
  (let* ((root (file-name-as-directory (expand-file-name "shop" media-tmp)))
         (file (expand-file-name ".agent-ui/dashboards/service.el" root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";;; service.el --- Agent UI dashboard: the service  -*- lexical-binding: t; -*-\n")
      (pp (media--dashboard-form) (current-buffer)))
    (agent-ui-dashboard-trust file)
    (let ((canvas (agent-ui-open-dashboard-here "service" root)))
      ;; Filled: its CI table has rows (its row is an image in the GUI).
      (lambda () (plist-get (agent-ui-get "ci" :canvas canvas) :rows)))))

;; The release: an agent-shell session with the stand-in agent, asked to
;; release a project; as it runs the tests and the build, its canvases fill
;; in (as the agent would show them, through Lisp here), a tick apart.

(defvar media--release-done nil "Non-nil once the canvases are played out.")
(defvar media--release-answered nil "Non-nil once the agent's turn is over.")

(defun media--release-config ()
  "An agent-shell config whose agent is the stand-in."
  (agent-shell-make-agent-config
   :identifier 'stand-in
   :mode-line-name "Agent"
   :buffer-name "Agent"
   :shell-prompt "Agent> "
   :shell-prompt-regexp "Agent> "
   :welcome-function (lambda (_config) "\n  A stand-in agent (scripts/media/stand-in.el), offline.\n")
   :client-maker (lambda (buffer)
                   (agent-shell--make-acp-client
                    :command (expand-file-name invocation-name invocation-directory)
                    :command-params (list "--batch" "-Q" "-l"
                                          (expand-file-name "scripts/media/stand-in.el" media-root)
                                          "-f" "stand-in-main")
                    :context-buffer buffer))))

(defun media--release-summary (canvas passed failed)
  "The tests' figures on CANVAS: PASSED and FAILED so far."
  (agent-ui-show `(:id "summary" :type "stats"
                   :figures ((:label "Passed" :value ,passed :face "success")
                             (:label "Failed" :value ,failed :good "down" :face ,(if (> failed 0) "error" "muted"))
                             (:label "Coverage" :value 87.1 :unit "%" :change 2.3)))
                 :canvas canvas))

(defun media--release-steps (session)
  "What the agent shows as it works, a function per tick; SESSION its canvas."
  (let ((tests-canvas (agent-ui-sub-canvas session "tests"))
        (ask (agent-ui-sub-canvas session "ask"))
        (tests '(("lexer" "passed" "0.4s") ("parser" "passed" "1.1s") ("checker" "failed" "0.7s")
                 ("codegen" "passed" "2.3s") ("linker" "passed" "0.9s") ("repl" "passed" "1.6s")))
        (passed 0) (failed 0))
    (append
     (list
      (lambda ()
        (agent-ui-show '(:id "plan" :type "steps" :title "Release v2.4" :close :false
                         :steps ((:name "Run the tests" :status "running") "Build" "Publish"))
                       :canvas session)
        (media--release-summary tests-canvas 0 0)
        (agent-ui-show '(:id "tests" :type "table" :title "Tests" :columns ("Test" "Result" "Time") :key "Test")
                       :canvas tests-canvas)))
     (mapcan (lambda (test)
               (list (lambda ()
                       (agent-ui-append "tests" `(:rows ((,(car test) "running" nil))) :canvas tests-canvas))
                     (lambda ()
                       (if (equal (nth 1 test) "failed") (cl-incf failed) (cl-incf passed))
                       (media--release-summary tests-canvas passed failed)
                       (agent-ui-append "tests" `(:rows (,test)) :canvas tests-canvas))))
             tests)
     (list
      (lambda ()
        (agent-ui-append "plan" '(:steps ((:name "Run the tests" :status "failed" :detail "5 passed, 1 failed")
                                          (:name "Build" :status "running")))
                         :canvas session)
        (agent-ui-show '(:id "build" :type "progress" :title "Build" :max 12 :label "configuring" :close :false)
                       :canvas session)))
     (mapcar (lambda (n)
               (lambda ()
                 (agent-ui-update "build" (list :value n :label (format "compiling unit %d of 12" n))
                                  :canvas session)))
             (number-sequence 1 12))
     (list
      (lambda ()
        (agent-ui-update "build" '(:status "done" :label "built in 29s") :canvas session)
        (agent-ui-show '(:id "times" :type "chart" :title "Build time" :unit "s" :height 5
                         :labels ("v2.0" "v2.1" "v2.2" "v2.3" "v2.4")
                         :series ((:name "this machine" :values (42 40 45 38 29))
                                  (:name "CI" :values (61 63 58 60 52))))
                       :canvas session))
      (lambda ()
        (agent-ui-append "plan" '(:steps ((:name "Build" :status "done" :seconds 29)
                                          (:name "Publish" :status "waiting" :detail "asks you")))
                         :canvas session)
        (agent-ui-show '(:id "next" :type "choice"
                         :question "checker's test expects the old error message. How do I go on?"
                         :options ((:label "Fix the test" :detail "then publish v2.4")
                                   (:label "Publish anyway" :detail "the test fixed after")
                                   (:label "Stop here" :detail "you look into it")))
                       :canvas ask)
        (setq media--release-done t))))))

(defun media--release-tick (buffer steps)
  "Do the first of STEPS, the others after, a tick apart, while BUFFER lives."
  (when (and steps (buffer-live-p buffer))
    (funcall (car steps))
    (run-with-timer 0.25 nil #'media--release-tick buffer (cdr steps))))

(defun media-release ()
  "An agent's session, its canvases filling in under the conversation."
  (require 'agent-shell)
  (setq media--release-done nil
        media--release-answered nil)
  (let* ((dir (file-name-as-directory (make-temp-file (expand-file-name "release-" media-tmp) t)))
         (buffer (agent-shell--start :config (media--release-config) :no-focus t :new-session t
                                     :session-strategy 'new :cwd dir)))
    (switch-to-buffer buffer)
    (let ((ignore-window-parameters t))
      (delete-other-windows))
    (with-current-buffer buffer
      (remove-hook 'kill-buffer-query-functions #'agent-shell--prompt-queue-confirm-kill-buffer t)
      (setq-local shell-maker-prompt-before-killing-buffer nil))
    (agent-shell-subscribe-to
     :shell-buffer buffer :event 'init-finished
     :on-event (lambda (_event)
                 (run-at-time
                  0 nil
                  (lambda ()
                    (agent-shell-insert :text "Release v2.4: run the tests, build it, and publish it if all's well."
                                        :submit t :no-focus t :shell-buffer buffer)
                    (media--release-tick buffer (media--release-steps (agent-ui--session-name buffer)))))))
    (agent-shell-subscribe-to
     :shell-buffer buffer :event 'turn-complete
     :on-event (lambda (_event)
                 (run-at-time 0 nil
                              (lambda ()
                                (when-let* ((window (get-buffer-window buffer)))
                                  (with-selected-window window
                                    (goto-char (point-max))
                                    (recenter -1)))
                                (setq media--release-answered t)))))
    (lambda () (and media--release-done media--release-answered))))

;; ====== RUNNING ======

(defun media-run ()
  "Play the scenes MEDIA_SCENES names (default all), then exit: 0 if done."
  (run-at-time 900 nil #'kill-emacs 3)
  (run-at-time
   0.5 nil
   (lambda ()
     (condition-case err
         (progn
           (make-directory media-out t)
           (media--setup)
           (dolist (scene (or (split-string (or (getenv "MEDIA_SCENES") "") " " t)
                              '("release" "figures" "content" "asking" "dashboard")))
             (pcase scene
               ("release" (media-gif "release" #'media-release nil 2.5 "session"))
               ("figures" (media-still "figures" #'media-figures))
               ("content" (media-still "content" #'media-content))
               ("asking" (media-gif "asking" #'media-asking '(1200 . 340) 1.5))
               ("dashboard" (media-still "dashboard" #'media-dashboard '(1200 . 620)))
               (_ (media--say "no scene %s" scene))))
           (kill-emacs 0))
       (error (media--say "error: %s" (error-message-string err))
              (kill-emacs 1))))))

;;; media.el ends here
