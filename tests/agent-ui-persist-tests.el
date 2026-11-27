;;; agent-ui-persist-tests.el --- Tests for Agent UI: persist  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-persist.el: a session's canvas kept with it. Saved as it
;; changes (a moment later, together), by its session id, in its directory;
;; closing it changes nothing saved, clearing it saves it empty; back when the
;; session starts with that id, its sources not started again. Sessions are
;; buffers the tests make, their ids stubbed; no agent runs.

;;; Code:

(require 'agent-ui-test-helper)

;; ====== HELPERS ======

(defvar agent-ui-test-aups-ids nil "Session buffers' ids: (BUFFER . ID).")
(defvar agent-ui-test-aups-dir nil "The test session's directory.")

(defmacro agent-ui-test-aups (&rest body)
  "BODY with a session `session' (its id \"sess-1\", working in `dir'), no
window shown, saves at once; what it makes, killed after."
  (declare (indent 0))
  `(let* ((agent-ui-test-aups-dir (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "persist-") t)))
          (dir agent-ui-test-aups-dir)
          (agent-ui-display-function #'ignore)
          (agent-ui-persist-delay 0.01)
          (session (generate-new-buffer "Claude Agent @ persist"))
          (agent-ui-test-aups-ids (list (cons session "sess-1")))
          (before (buffer-list)))
     (with-current-buffer session (setq default-directory dir))
     (cl-letf (((symbol-function 'agent-ui--sessions) (lambda () (list session)))
               ((symbol-function 'agent-shell-cwd) (lambda () default-directory))
               ((symbol-function 'agent-shell-session-id)
                (lambda (&key shell-buffer) (cdr (assq shell-buffer agent-ui-test-aups-ids)))))
       (unwind-protect (let ((name (agent-ui--session-name session))) (ignore name) ,@body)
         (dolist (b (buffer-list))
           (unless (memq b before) (kill-buffer b)))
         (kill-buffer session)))))

(defun agent-ui-test-aups-file () (expand-file-name ".agent-shell/agent-ui/sess-1.json" agent-ui-test-aups-dir))

(defun agent-ui-test-aups-saved ()
  "What's saved, parsed (nil if nothing)."
  (with-timeout (2 nil)
    (while (not (file-exists-p (agent-ui-test-aups-file)))
      (accept-process-output nil 0.01)))
  (when (file-exists-p (agent-ui-test-aups-file))
    (agent-ui-parse-json (with-temp-buffer (insert-file-contents (agent-ui-test-aups-file)) (buffer-string)))))

(defun agent-ui-test-aups-settle ()
  "Wait past the save's delay."
  (let ((end (+ (float-time) 0.1)))
    (while (< (float-time) end) (accept-process-output nil 0.01))))

;; ====== SAVING ======

(ert-deftest agent-ui-persist/saved-as-it-changes ()
  (agent-ui-test-aups
    (should (equal (agent-ui-persist-file session) (agent-ui-test-aups-file)))
    (agent-ui-show '(:id "b" :type "progress" :max 4 :title "Build") :canvas name)
    (agent-ui-update "b" '(:value 3) :canvas name)
    ;; As given, with the times its values came (doom-ht6.31).
    (let ((saved (agent-ui-test-aups-saved)))
      (should (equal (mapcar (lambda (e) (agent-ui--plist-delete e :times)) saved)
                     '((:id "b" :type "progress" :max 4 :title "Build" :value 3))))
      (should (equal (mapcar #'cadr (plist-get (plist-get (car saved) :times) :values)) '(3 0))))
    (agent-ui-show '(:id "t" :type "text" :text "ü ✓") :canvas name)
    (agent-ui-remove "b" :canvas name)
    (agent-ui-test-aups-settle)
    (should (equal (agent-ui-test-aups-saved) '((:id "t" :type "text" :text "ü ✓"))))))

(ert-deftest agent-ui-persist/closing-keeps-it ()
  (agent-ui-test-aups
    (agent-ui-show '(:id "t" :type "text" :text "kept") :canvas name)
    (agent-ui-test-aups-saved)
    ;; A change waiting when it closes: saved then; nothing emptied.
    (agent-ui-update "t" '(:text "last") :canvas name)
    (kill-buffer (agent-ui-canvas-buffer-name name))
    (should (equal (agent-ui-test-aups-saved) '((:id "t" :type "text" :text "last"))))
    ;; Cleared: empty, saved.
    (agent-ui-show '(:id "x" :type "text" :text "x") :canvas name)
    (agent-ui-clear :canvas name)
    (agent-ui-test-aups-settle)
    (should (equal (agent-ui-test-aups-saved) nil))
    (should (file-exists-p (agent-ui-test-aups-file)))))

;; Raw bytes saved as U+FFFD; a save failing never keeps the canvas open
;; (doom-ht6.45).
(ert-deftest agent-ui-persist/raw-bytes-and-a-failing-save ()
  (agent-ui-test-aups
    (agent-ui-show (list :id "r" :type "text" :text (string-to-multibyte "a\377b")) :canvas name)
    (should (equal (agent-ui-test-aups-saved) '((:id "r" :type "text" :text "a\uFFFDb"))))
    (agent-ui-update "r" '(:text "later") :canvas name)
    (cl-letf (((symbol-function 'agent-ui-persist-save) (lambda (&rest _) (error "Disk full"))))
      (kill-buffer (agent-ui-canvas-buffer-name name)))
    (should-not (get-buffer (agent-ui-canvas-buffer-name name)))))

(ert-deftest agent-ui-persist/a-failing-save-said-once ()
  "A save failing (its folder can't be made): said once, no timer's error
at each change; a component that can't be written as JSON: left out, said,
the others saved (doom-ht6.135)."
  (agent-ui-test-aups
    (let ((said nil))
      (cl-letf* ((message-fn (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format &rest args)
                    (when format (push (apply #'format-message format args) said))
                    (apply message-fn format args))))
        ;; Its folder can't be made: a file there.
        (with-temp-file (expand-file-name ".agent-shell" dir) (insert "a file"))
        (agent-ui-show '(:id "a" :type "text" :text "one") :canvas name)
        (agent-ui-test-aups-settle)
        (agent-ui-update "a" '(:text "two") :canvas name)
        (agent-ui-test-aups-settle)
        (should-not (seq-some (lambda (m) (string-match-p "Error running timer" m)) said))
        (should (= (seq-count (lambda (m) (string-match-p "couldn't be saved" m)) said) 1))
        ;; Its folder fine again: a component that can't be written, left out.
        (delete-file (expand-file-name ".agent-shell" dir))
        (setq said nil)
        (with-current-buffer (agent-ui-canvas-buffer-name name)
          (setf (agent-ui--entry-component (gethash "a" agent-ui--entries))
                (list :id "a" :type "text" :text "one" :odd (make-marker))))
        (agent-ui-show '(:id "b" :type "text" :text "saved") :canvas name)
        (should (equal (agent-ui-test-aups-saved) '((:id "b" :type "text" :text "saved"))))
        (should-not (seq-some (lambda (m) (string-match-p "Error running timer" m)) said))
        (should (seq-some (lambda (m) (string-match-p "a left out" m)) said))))))

(ert-deftest agent-ui-persist/not-without-a-session-id ()
  (agent-ui-test-aups
    (setq agent-ui-test-aups-ids nil)
    (agent-ui-show '(:id "t" :type "text" :text "x") :canvas name)
    (agent-ui-test-aups-settle)
    (should-not (file-exists-p (agent-ui-test-aups-file)))
    ;; A canvas of no session: neither.
    (let ((agent-ui-default-canvas (make-temp-name "nobody-")))
      (agent-ui-show '(:id "t" :type "text" :text "x"))
      (agent-ui-test-aups-settle)
      (should-not (file-exists-p (expand-file-name ".agent-shell/agent-ui/" dir))))))

(ert-deftest agent-ui-persist/closed-then-made-again-keeps-what-was-saved ()
  "Closed (q), then the agent's next component: the canvas shows only it, its
saves keep what was saved before, before it (they replaced it: a and b lost
for good); resumed, all of them back. Its removals and clearing count."
  (agent-ui-test-aups
    (let ((canvas-name (agent-ui-canvas-buffer-name name)))
      (agent-ui-show '(:id "a" :type "text" :text "a") :canvas name)
      (agent-ui-show '(:id "b" :type "text" :text "b") :canvas name)
      (agent-ui-test-aups-settle)
      (kill-buffer canvas-name)
      (agent-ui-show '(:id "c" :type "text" :text "c") :canvas name)
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components :canvas name)) '("c")))
      (agent-ui-test-aups-settle)
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-test-aups-saved)) '("a" "b" "c")))
      ;; Shown again on it: its own, once.
      (agent-ui-show '(:id "a" :type "text" :text "a again") :canvas name)
      (agent-ui-test-aups-settle)
      (should (equal (agent-ui-test-aups-saved) '((:id "b" :type "text" :text "b") (:id "c" :type "text" :text "c")
                                         (:id "a" :type "text" :text "a again"))))
      (agent-ui-remove "a" :canvas name)
      (agent-ui-test-aups-settle)
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-test-aups-saved)) '("b" "c")))
      ;; Resumed: all back.
      (kill-buffer canvas-name)
      (should (= (agent-ui-persist-restore session) 2))
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components :canvas name)) '("b" "c")))
      ;; Back with its session: nothing kept twice.
      (agent-ui-test-aups-settle)
      (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-test-aups-saved)) '("b" "c")))
      ;; Closed, made again, cleared: nothing kept.
      (kill-buffer canvas-name)
      (agent-ui-show '(:id "d" :type "text" :text "d") :canvas name)
      (agent-ui-clear :canvas name)
      (agent-ui-test-aups-settle)
      (should (equal (agent-ui-test-aups-saved) nil)))))

(ert-deftest agent-ui-persist/saved-when-emacs-exits ()
  "A save waiting when Emacs exits: done (the last second's changes were
lost)."
  (should (memq #'agent-ui--persist-all-now kill-emacs-hook))
  (agent-ui-test-aups
    (agent-ui-show '(:id "t" :type "text" :text "first") :canvas name)
    (agent-ui-test-aups-settle)
    (let ((agent-ui-persist-delay 60))
      (agent-ui-update "t" '(:text "last") :canvas name)
      (agent-ui-test-aups-settle)
      (should (equal (agent-ui-test-aups-saved) '((:id "t" :type "text" :text "first"))))
      (agent-ui--persist-all-now)
      (should (equal (agent-ui-test-aups-saved) '((:id "t" :type "text" :text "last")))))))

;; ====== RESTORING ======

(ert-deftest agent-ui-persist/back-when-resumed ()
  (agent-ui-test-aups
    (make-directory (file-name-directory (agent-ui-test-aups-file)) t)
    (with-temp-file (agent-ui-test-aups-file)
      (insert "[{\"id\":\"b\",\"type\":\"progress\",\"max\":4,\"value\":4,\"status\":\"done\"},"
              "{\"id\":\"s\",\"type\":\"text\",\"text\":\"tail\",\"source\":{\"command\":\"echo again\",\"tail\":1}},"
              "{\"id\":\"g\",\"type\":\"gone-type\"}]"))
    (should (= (agent-ui-persist-restore session) 2))
    ;; As they were; the one of a type gone, left out; no source started.
    (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components :canvas name)) '("b" "s")))
    (should (equal (plist-get (agent-ui-get "b" :canvas name) :status) "done"))
    ;; Finished, it stays: no countdown closing it again (doom-ht6.60).
    (with-current-buffer (get-buffer (agent-ui-canvas-buffer-name name))
      (should-not (and agent-ui--closing (gethash "b" agent-ui--closing)))
      (should (gethash "b" agent-ui--kept)))
    (should-not (plist-get (agent-ui-get "s" :canvas name) :source))
    (should-not (agent-ui-source-status "s" :canvas name))
    ;; Tied to its session, as any.
    (should (eq (buffer-local-value 'agent-ui--session-buffer (get-buffer (agent-ui-canvas-buffer-name name)))
                session))
    ;; A canvas with components already: left as it is.
    (should-not (agent-ui-persist-restore session))))

;; doom-ht6.31
(ert-deftest agent-ui-persist/a-progress-bars-times ()
  "A progress bar's times are kept with it: back after a restart, the time
elapsed and an item takes, the time left, the same; its next value goes
on from them."
  (agent-ui-test-aups
    (let* ((now 1794335400.0)
           (agent-ui-clock (lambda () now)))
      (cl-flet ((draw () (substring-no-properties
                          (agent-ui-render (agent-ui-get "bugs" :canvas name)
                                           (agent-ui-context :width 100 :id "bugs")))))
        (agent-ui-show '(:id "bugs" :type "progress" :max 20 :unit "bugs") :canvas name)
        (dolist (value '(1 2 3 4))
          (setq now (+ now (* (+ 8 value) 60)))
          (agent-ui-update "bugs" (list :value value) :canvas name))
        (let ((before (draw)))
          (should (string-search "\n42m 00s elapsed · ~10 min a bug (last 4) · ~2h 50m left" before))
          (agent-ui-persist-save (get-buffer (agent-ui-canvas-buffer-name name)))
          (kill-buffer (agent-ui-canvas-buffer-name name))
          (should (= (agent-ui-persist-restore session) 1))
          (should (equal (draw) before)))
        (setq now (+ now (* 13 60)))
        (agent-ui-update "bugs" '(:value 5) :canvas name)
        (should (string-search "\n55m 00s elapsed · ~11 min a bug (last 5) · ~2h 45m left" (draw)))))))

;; doom-ht6.29
(ert-deftest agent-ui-persist/a-type-dropped-since ()
  "A canvas saved with an issues board (a type dropped since): back
without an error, the board left out; in a panel, the panel back with its
other children, their weights kept."
  (agent-ui-test-aups
    (make-directory (file-name-directory (agent-ui-test-aups-file)) t)
    (with-temp-file (agent-ui-test-aups-file)
      (insert "[{\"id\":\"board\",\"type\":\"issues\",\"parent\":\"doom-ht6\"},"
              "{\"id\":\"t\",\"type\":\"text\",\"text\":\"kept\"},"
              "{\"id\":\"p\",\"type\":\"panel\",\"weights\":[1,2,3],\"children\":["
              "{\"id\":\"a\",\"type\":\"text\",\"text\":\"a\"},"
              "{\"id\":\"b2\",\"type\":\"issues\"},"
              "{\"id\":\"c\",\"type\":\"panel\",\"children\":[{\"id\":\"b3\",\"type\":\"issues\"},"
              "{\"id\":\"d\",\"type\":\"text\",\"text\":\"d\"}]}]}]"))
    (should (= (agent-ui-persist-restore session) 2))
    ;; The canvas's components, its panels' children after them.
    (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components :canvas name)) '("t" "p" "a" "c" "d")))
    (let ((panel (agent-ui-get "p" :canvas name)))
      (should (equal (mapcar (lambda (c) (plist-get c :id)) (plist-get panel :children)) '("a" "c")))
      (should (equal (plist-get panel :weights) '(1 3)))
      (should (equal (mapcar (lambda (c) (plist-get c :id)) (plist-get (cadr (plist-get panel :children)) :children))
                     '("d"))))
    (with-current-buffer (agent-ui-canvas-buffer-name name)
      (agent-ui--flush)
      (should-not (string-search "⚠" (buffer-string))))))

(ert-deftest agent-ui-persist/nothing-kept-nothing-back ()
  (agent-ui-test-aups
    (should-not (agent-ui-persist-restore session))
    (should-not (get-buffer (agent-ui-canvas-buffer-name name)))
    ;; Unreadable: nothing, no error.
    (make-directory (file-name-directory (agent-ui-test-aups-file)) t)
    (with-temp-file (agent-ui-test-aups-file) (insert "{not json"))
    (should (equal (agent-ui-persist-restore session) 0))))

(ert-deftest agent-ui-persist/when-a-session-starts ()
  (agent-ui-test-aups
    (should (memq #'agent-ui--persist-watch agent-shell-mode-hook))
    (let (subscribed)
      (cl-letf (((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest args) (setq subscribed args))))
        (with-current-buffer session (agent-ui--persist-watch)))
      (should (eq (plist-get subscribed :shell-buffer) session))
      (should (eq (plist-get subscribed :event) 'init-session))
      ;; Its session known: its canvas back.
      (make-directory (file-name-directory (agent-ui-test-aups-file)) t)
      (with-temp-file (agent-ui-test-aups-file) (insert "[{\"id\":\"t\",\"type\":\"text\",\"text\":\"back\"}]"))
      (funcall (plist-get subscribed :on-event) '((:event . init-session)))
      (should (equal (plist-get (agent-ui-get "t" :canvas name) :text) "back")))))

(ert-deftest agent-ui-persist/a-childs-source-not-started-again ()
  (agent-ui-test-aups
    (make-directory (file-name-directory (agent-ui-test-aups-file)) t)
    (with-temp-file (agent-ui-test-aups-file)
      (insert "[{\"id\":\"p\",\"type\":\"panel\",\"children\":[{\"id\":\"c\",\"type\":\"text\",\"text\":\"t\",\"source\":{\"command\":\"echo x\",\"tail\":1}}]}]"))
    (should (= (agent-ui-persist-restore session) 1))
    (should-not (plist-get (agent-ui-get "c" :canvas name) :source))
    (should-not (agent-ui-source-status "c" :canvas name))))

(ert-deftest agent-ui-persist/the-sessions-other-canvases ()
  (agent-ui-test-aups
    (let ((tests (concat name " / my tests"))
          (file (expand-file-name ".agent-shell/agent-ui/sess-1@my%20tests.json" agent-ui-test-aups-dir)))
      (agent-ui-show '(:id "m" :type "text" :text "main") :canvas name)
      (agent-ui-show '(:id "t" :type "text" :text "ü") :canvas tests)
      ;; Beside the session's, its name escaped.
      (should (equal (agent-ui-test-aups-saved) '((:id "m" :type "text" :text "main"))))
      (with-timeout (2 nil) (while (not (file-exists-p file)) (accept-process-output nil 0.01)))
      (should (file-exists-p file))
      (should (equal (agent-ui-persist--parts session) '("my tests")))
      ;; Back with the session: both.
      (kill-buffer (agent-ui-canvas-buffer-name name))
      (kill-buffer (agent-ui-canvas-buffer-name tests))
      (should (= (agent-ui-persist-restore session) 2))
      (should (equal (plist-get (agent-ui-get "t" :canvas tests) :text) "ü"))
      (should (equal (buffer-local-value 'agent-ui--canvas-part (get-buffer (agent-ui-canvas-buffer-name tests)))
                     "my tests")))))

(ert-deftest agent-ui-persist/a-todo-the-user-ticked ()
  "A todo's items and the user's changes not sent: kept, and back when the
session is resumed."
  (agent-ui-test-aups
    (agent-ui-show '(:id "plan" :type "todo" :items ("Reproduce" "Fix it")) :canvas name)
    (with-current-buffer (agent-ui-canvas-buffer-name name)
      (agent-ui--flush)
      (goto-char (point-min))
      (search-forward "Fix it")
      (goto-char (match-beginning 0))
      (agent-ui-button-press))
    (kill-buffer (agent-ui-canvas-buffer-name name))
    (should (equal (agent-ui-test-aups-saved)
                   '((:id "plan" :type "todo"
                      :items ((:label "Reproduce" :done nil) (:label "Fix it" :done t :by "user"))
                      :changes ((:label "Fix it" :change "done"))))))
    (should (= (agent-ui-persist-restore session) 1))
    (with-current-buffer (agent-ui-canvas-buffer-name name)
      (agent-ui--flush)
      (should (string-search " [x] Fix it     you" (buffer-string)))
      (should (string-search "⏵ Send your changes (1)" (buffer-string))))))

(ert-deftest agent-ui-persist/a-rank-the-user-ordered ()
  "A rank's order, the user's: kept, and back when the session is resumed."
  (agent-ui-test-aups
    (agent-ui-show '(:id "prio" :type "rank" :question "First?" :items ("Fix" "Docs" "Release")) :canvas name)
    (with-current-buffer (agent-ui-canvas-buffer-name name)
      (agent-ui--flush)
      (goto-char (point-min))
      (search-forward "Release")
      (agent-ui-move-item-up))
    (kill-buffer (agent-ui-canvas-buffer-name name))
    (should (equal (plist-get (car (agent-ui-test-aups-saved)) :order) '("Fix" "Release" "Docs")))
    (should (= (agent-ui-persist-restore session) 1))
    (with-current-buffer (agent-ui-canvas-buffer-name name)
      (agent-ui--flush)
      (should (string-search " 1. Fix\n 2. Release\n 3. Docs" (buffer-string))))))

(ert-deftest agent-ui-persist/a-slider-the-user-moved ()
  "A slider's value, the user's: kept, and back when the session is resumed."
  (agent-ui-test-aups
    (agent-ui-show '(:id "t" :type "slider" :min 0 :max 1 :step 0.1 :value 0.5) :canvas name)
    (with-current-buffer (agent-ui-canvas-buffer-name name)
      (agent-ui--flush)
      (goto-char (point-min))
      (search-forward "●")
      (agent-ui-slider-right))
    (kill-buffer (agent-ui-canvas-buffer-name name))
    (should (equal (plist-get (car (agent-ui-test-aups-saved)) :value) 0.6))
    (should (= (agent-ui-persist-restore session) 1))
    (with-current-buffer (agent-ui-canvas-buffer-name name)
      (agent-ui--flush)
      (should (string-search "   0.6" (buffer-string))))))

;;; agent-ui-persist-tests.el ends here
