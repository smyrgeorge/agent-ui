;;; agent-ui-test-helper.el --- What Agent UI's tests share  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded first by `make test', in `emacs -Q --batch': Agent UI loaded,
;; `agent-ui-mode' on, every folder it writes to in a temp folder of the
;; run's own (nothing written to the user's Emacs directory), and the
;; tools the tests share.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; ====== FOLDERS ======

(defconst agent-ui-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "The tests' folder.")

(defconst agent-ui-test-root (expand-file-name "../" agent-ui-test-dir)
  "The package's folder.")

(defconst agent-ui-test-tmp
  (file-name-as-directory
   (file-truename (or (getenv "TEST_TMP") (make-temp-file "agent-ui-tests-" t))))
  "This run's temp folder (its true name: buffers visit files by theirs).")

(defun agent-ui-test-tmp-file (name)
  "NAME in the run's temp folder, its folders made."
  (let ((file (expand-file-name name agent-ui-test-tmp)))
    (make-directory (file-name-directory file) t)
    file))

;; Agent UI's folders (`locate-user-emacs-file') in the temp folder.
(setq user-emacs-directory (agent-ui-test-tmp-file "emacs.d/")
      temporary-file-directory (agent-ui-test-tmp-file "tmp/")
      find-file-visit-truename t
      vc-follow-symlinks t)

;; Nothing compiled to native code as it loads (processes of their own).
(setq native-comp-jit-compilation nil
      native-comp-enable-subr-trampolines nil)

;; An Emacs built without SVG (or PNG, ...) images, as CI's is, refuses to
;; make one ("Invalid image type"); in batch an image is only made, never
;; shown: let the GUI's drawings be made, so their tests run there too.
;; `image-type' asks `image-types' (the ones built in), the code
;; `image-type-available-p'.
(require 'image)
(defconst agent-ui-test-image-types '(svg png jpeg gif webp)
  "The image types the tests make, whether Emacs has them or not.")
;; Unbound where Emacs has no image support at all.
(defvar image-types nil)
(dolist (type agent-ui-test-image-types)
  (add-to-list 'image-types type t))
(advice-add 'image-type-available-p :around
            (lambda (available type)
              (or (funcall available type) (and (memq type agent-ui-test-image-types) t)))
            '((name . agent-ui-test-images)))

;; Emacs 29's `svg-print' puts a space before each child, a text's words
;; too ("<text ...> 5</text>"; shown the same, SVG drops it): the tests,
;; reading the words, get Emacs 30's, without it.
(require 'svg)
(when (equal (with-temp-buffer (svg-print '(text nil "x")) (buffer-string)) "<text> x</text>")
  (advice-add 'svg-print :override
              (lambda (dom)
                (if (stringp dom)
                    (insert dom)
                  (insert (format "<%s" (car dom)))
                  (dolist (attr (nth 1 dom))
                    (unless (= (aref (format "%s" (car attr)) 0) ?:)
                      (insert (format " %s=\"%s\"" (car attr) (cdr attr)))))
                  (insert ">")
                  (mapc #'svg-print (nthcdr 2 dom))
                  (insert (format "</%s>" (car dom)))))
              '((name . agent-ui-test-svg-print))))

;; No test sees the user's Agent UI session.
(setenv "AGENT_UI_SESSION" nil)

(add-to-list 'load-path agent-ui-test-root)
(require 'agent-ui)
(agent-ui-mode 1)

;; ====== TOOLS ======

(defun agent-ui-test-load (&rest _files)
  "Nothing: Agent UI is loaded already (kept for the tests' first lines)."
  nil)

(defun agent-ui-test-reset ()
  "One window, on *scratch*; the buffers tests made killed."
  (dolist (window (window-list nil 'nomini))
    (when (window-parameter window 'window-side)
      (let ((ignore-window-parameters t))
        (ignore-errors (delete-window window)))))
  (select-window (frame-first-window))
  (let ((ignore-window-parameters t))
    (delete-other-windows))
  (set-window-dedicated-p nil nil)
  (switch-to-buffer (get-buffer-create "*scratch*"))
  (dolist (buffer (buffer-list))
    (unless (or (not (buffer-live-p buffer))
                (eq buffer (current-buffer))
                (string-prefix-p " " (buffer-name buffer))
                (member (buffer-name buffer) '("*Messages*" "*scratch*")))
      (let ((kill-buffer-query-functions nil))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(defmacro agent-ui-test-with-reset (&rest body)
  "BODY from one window on *scratch*, and again after."
  (declare (indent 0))
  `(progn (agent-ui-test-reset)
          (unwind-protect (progn ,@body)
            (agent-ui-test-reset))))

(defun agent-ui-test-buffer (name &optional content mode)
  "A buffer NAME (made anew) with CONTENT, in MODE."
  (when (get-buffer name)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer name)))
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (when content (insert content))
      (goto-char (point-min))
      (when mode (funcall mode)))
    buffer))

(defun agent-ui-test-messages (regexp)
  "How many lines of *Messages* match REGEXP."
  (with-current-buffer (messages-buffer)
    (count-matches regexp (point-min) (point-max))))

(defun agent-ui-test-clear-messages ()
  "Empty *Messages*."
  (with-current-buffer (messages-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))))

(defun agent-ui-test--pump (seconds)
  "Up to SECONDS of Emacs at work: a redisplay, timers, processes' output."
  (redisplay t)
  (accept-process-output nil seconds))

(defun agent-ui-test-sleep (seconds)
  "Let SECONDS pass, timers and processes running."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)
      (agent-ui-test--pump (min 0.05 (max 0.001 (- end (float-time))))))))

(defun agent-ui-test-timers-run (&optional seconds)
  "Run the timers due now, and those they make due at once.
Until no timer that runs once is due; SECONDS at least (default 0.1),
processes' output read meanwhile; 20 s at most."
  (let* ((start (float-time))
         (end (+ start (or seconds 0.1)))
         (limit (+ start 20)))
    (while (and (< (float-time) limit)
                (or (< (float-time) end)
                    (seq-some (lambda (timer) (and (not (timer--repeat-delay timer))
                                                   (time-less-p (timer--time timer) nil)))
                              timer-list)))
      (accept-process-output nil 0.02))))

(defun agent-ui-test-wait-for (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil, TIMEOUT seconds at most (10).
Timers and processes run meanwhile.  Its value, or nil if it never did."
  (let ((end (+ (float-time) (or timeout 10)))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) end))
      (agent-ui-test--pump 0.05))
    value))

(defun agent-ui-test-process-sentinel (process _event)
  "A test's PROCESS's sentinel: it ended, all its output read."
  (unless (process-live-p process)
    (process-put process 'agent-ui-test-ended t)))

(defun agent-ui-test-process-ended-p (process)
  "Whether PROCESS, made with `agent-ui-test-process-sentinel', ended."
  (process-get process 'agent-ui-test-ended))

(defun agent-ui-test-agent-ui-skill (&optional file)
  "The agent-ui skill's text: FILE's (relative to skills/agent-ui/).
Else all of it as one, its SKILL.md then its references (by name)."
  (let ((dir (expand-file-name "skills/agent-ui/" agent-ui-test-root)))
    (with-temp-buffer
      (dolist (f (if file
                     (list (expand-file-name file dir))
                   (cons (expand-file-name "SKILL.md" dir)
                         (directory-files (expand-file-name "references/" dir) t "\\.md\\'"))))
        (goto-char (point-max))
        (insert-file-contents f))
      (buffer-string))))

(provide 'agent-ui-test-helper)

;;; agent-ui-test-helper.el ends here
