;;; agent-ui-staging-tests.el --- Tests for Agent UI: staging  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-staging.el and review.el: types the agent makes. Staged (checked,
;; written, nothing of it run), refused when wrong (nothing left of it);
;; reviewed: listed, previewed (read, not run), kept (compiled, loaded, its
;; example drawn: refused when wrong; loaded from its new folder at the next
;; start), discarded; the agent told what became of it. Staging and kept
;; folders of the tests' own.

;;; Code:

(require 'agent-ui-test-helper)

;; ====== HELPERS ======

(defconst agent-ui-test-aust-dial
  "(defun agent-ui-dial--text (props _ctx)
  (format \"[%s%s] %d%%\"
          (make-string (/ (plist-get props :value) 10) ?#)
          (make-string (- 10 (/ (plist-get props :value) 10)) ?.)
          (plist-get props :value)))

(agent-ui-define dial
  \"A dial: VALUE percent.\"
  :props ((value integer \"Percent\" :default 0))
  :example (:value 42)
  :text #'agent-ui-dial--text)
"
  "A right type's code.")

(defvar agent-ui-test-aust-kept nil "What `agent-ui-kept-functions' was called with.")

(defvar agent-ui-test-aust-told nil
  "What `agent-ui-type-reviewed-functions' was called with, the latest first.")

(defmacro agent-ui-test-aust (&rest body)
  "BODY with staging and kept folders of its own, the types as they were
after (the tests' forgotten), no window shown, a canvas of its own."
  (declare (indent 0))
  `(let* ((agent-ui-staging-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "staged-") t)))
          (agent-ui-kept-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "kept-") t)))
          (agent-ui--types (copy-hash-table agent-ui--types))
          (agent-ui-default-canvas (make-temp-name "staging-"))
          (agent-ui-display-function #'ignore)
          (agent-ui-kept-functions (list (lambda (&rest args) (push args agent-ui-test-aust-kept))))
          (agent-ui-test-aust-kept nil)
          (agent-ui-type-reviewed-functions (list (lambda (&rest args) (push args agent-ui-test-aust-told))))
          (agent-ui-test-aust-told nil)
          (agent-ui--staged-by (make-hash-table :test #'eq))
          (before (buffer-list)))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (unless (memq b before) (kill-buffer b))))))

(defun agent-ui-test-aust-refused (code)
  "Why CODE is refused; nothing of it left."
  (let ((types (agent-ui-types)))
    (prog1 (agent-ui-error-message (should-error (agent-ui-stage code) :type 'agent-ui-error))
      (should (equal (agent-ui-types) types))
      (should-not (agent-ui-staged-files)))))

(defun agent-ui-test-aust-not-kept (code)
  "Why CODE, staged, can't be kept: no type of it, its file left for the
review, the agent told why."
  (let ((types (agent-ui-types))
        (name (intern (file-name-base (plist-get (agent-ui-stage code "S") :file)))))
    (prog1 (agent-ui-error-message (should-error (agent-ui-keep name) :type 'agent-ui-error))
      (should (equal (agent-ui-types) types))
      (should (agent-ui-staged-p name))
      (should (string-match-p (format "\\`Agent UI: the user tried to keep your type %s, but .*Fix it" name)
                              (nth 1 (car agent-ui-test-aust-told))))
      (agent-ui-discard name))))

;; ====== STAGING ======

(ert-deftest agent-ui-staging/a-type-staged ()
  (agent-ui-test-aust
    (let ((reply (agent-ui-stage agent-ui-test-aust-dial)))
      (should (equal (plist-get reply :type) "dial"))
      (should (equal (plist-get reply :file) (expand-file-name "dial.el" agent-ui-staging-directory)))
      ;; Waiting for the user's review: not a type yet.
      (should (equal (plist-get reply :status) "waiting"))
      (should-not (plist-member reply :preview)))
    ;; In the folder, with lexical binding.
    (should (equal (agent-ui-staged-files) (list (expand-file-name "dial.el" agent-ui-staging-directory))))
    (should (string-prefix-p ";;; dial.el --- Agent UI type dial, made by the agent -*- lexical-binding: t; -*-"
                             (with-temp-buffer (insert-file-contents (car (agent-ui-staged-files)))
                                               (buffer-string))))
    (should (agent-ui-staged-p 'dial))
    (should-not (agent-ui-staged-p 'progress))
    (should-not (memq 'dial (agent-ui-types)))
    (should (string-match-p "unknown type\\|isn't a type\\|no type"
                            (agent-ui-error-message (should-error (agent-ui-show '(:id "g" :type "dial"))
                                                                  :type 'agent-ui-error))))
    ;; Again, changed: replaces the one waiting.
    (agent-ui-stage (replace-regexp-in-string "%d%%" "%d percent" agent-ui-test-aust-dial))
    (should (= (length (agent-ui-staged-files)) 1))
    (should (string-search "%d percent" (with-temp-buffer (insert-file-contents (car (agent-ui-staged-files)))
                                                           (buffer-string))))))

(ert-deftest agent-ui-staging/its-warnings-said ()
  "Kept: its warnings, by line, to the agent with its example drawn."
  (agent-ui-test-aust
    (agent-ui-stage "(defun agent-ui-odd--text (props ctx) (format \"%s\" (plist-get props :v)))
(agent-ui-define odd \"Odd.\" :props ((v integer \"V\" :default 1)) :example (:v 2)
  :text #'agent-ui-odd--text)" "S")
    (let ((kept (agent-ui-keep 'odd)))
      (should (equal (plist-get kept :preview) "2"))
      (should (seq-some (lambda (w) (string-match-p "\\`line 1: Unused lexical argument .ctx." w))
                        (plist-get kept :warnings)))
      (should (string-match-p "Its warnings:\nline 1: Unused lexical argument"
                              (nth 1 (car agent-ui-test-aust-told)))))))

(ert-deftest agent-ui-staging/wrong-code-refused ()
  (agent-ui-test-aust
    (should (string-match-p "ends inside a form" (agent-ui-test-aust-refused "(agent-ui-define x \"X.\"")))
    (should (string-match-p "one type (one agent-ui-define), not 0"
                            (agent-ui-test-aust-refused "(defun agent-ui-x--a () 1)")))
    (should (string-match-p "one type (one agent-ui-define), not 2"
                            (agent-ui-test-aust-refused "(agent-ui-define a \"A.\" :text #'ignore) (agent-ui-define b \"B.\" :text #'ignore)")))
    (should (string-match-p "only definitions belong in a type's code, not (setq foo 1)"
                            (agent-ui-test-aust-refused "(setq foo 1) (agent-ui-define x \"X.\" :text #'ignore)")))
    (should (string-match-p "defun is named my-helper: a type's definitions are named agent-ui-x-"
                            (agent-ui-test-aust-refused "(defun my-helper () 1) (agent-ui-define x \"X.\" :text #'ignore)")))
    (should (string-match-p "require only cl-lib.*, not url"
                            (agent-ui-test-aust-refused "(require 'url) (agent-ui-define x \"X.\" :text #'ignore)")))
    (should (string-match-p "a type's name is a symbol"
                            (agent-ui-test-aust-refused "(agent-ui-define \"x\" \"X.\" :text #'ignore)")))
    ;; One there already, not the agent's.
    (should (string-match-p "progress is a type already"
                            (agent-ui-test-aust-refused "(agent-ui-define progress \"P.\" :text #'ignore :example ())")))
    ;; Kept, it must compile, load, have an example that draws.
    (should (string-match-p "keep: it doesn't compile"
                            (agent-ui-test-aust-not-kept "(agent-ui-define x \"X.\" :text (lambda (p c) (let ((a)) . 1)) :example ())")))
    (should (string-match-p "has no :example"
                            (agent-ui-test-aust-not-kept "(agent-ui-define x \"X.\" :text (lambda (_p _c) \"\"))")))
    (should (string-match-p "its example doesn't draw: ⚠ Boom"
                            (agent-ui-test-aust-not-kept "(agent-ui-define x \"X.\" :text (lambda (_p _c) (error \"Boom\")) :example (:title nil))")))
    (should (string-match-p "kind numbr"
                            (agent-ui-test-aust-not-kept "(agent-ui-define x \"X.\" :props ((a numbr \"A\")) :text (lambda (_p _c) \"\") :example ())")))))

(ert-deftest agent-ui-staging/a-wrong-one-not-kept-leaves-nothing ()
  "A type that can't be kept: no type of it left, the types as they were."
  (agent-ui-test-aust
    (agent-ui-stage "(agent-ui-define dial \"G.\" :text (lambda (_p _c) (error \"no\")) :example (:title \"t\"))")
    (should-error (agent-ui-keep 'dial) :type 'agent-ui-error)
    (should-not (memq 'dial (agent-ui-types)))
    ;; Fixed, staged again: kept.
    (agent-ui-stage agent-ui-test-aust-dial)
    (agent-ui-keep 'dial)
    (should (equal (agent-ui-render '(:type "dial" :value 10) (agent-ui-context)) "[#.........] 10%"))))

;; The agent's code runs only once the user keeps it: a defvar's value,
;; eval-when-compile (run by the compiler), the example's drawing are all
;; its code.
(ert-deftest agent-ui-staging/nothing-run-before-the-review ()
  "Staged: its code checked, written, nothing of it compiled, loaded or run;
the agent told it waits for the review.  Kept: compiled, loaded, its
example drawn (doom-ht6.127)."
  (agent-ui-test-aust
    (let* ((dir (make-temp-file (agent-ui-test-tmp-file "ran-") t))
           (loaded (expand-file-name "loaded" dir))
           (compiled (expand-file-name "compiled" dir))
           (code (format "(defvar agent-ui-ran-x (with-temp-file %S (insert \"x\")))
(defun agent-ui-ran--text (_props _ctx)
  (eval-when-compile (with-temp-file %S (insert \"x\")))
  \"ran\")
(agent-ui-define ran \"Ran.\" :example (:title nil) :text #'agent-ui-ran--text)
" loaded compiled))
           (reply (agent-ui-stage code)))
      (should-not (file-exists-p compiled))
      (should-not (file-exists-p loaded))
      (should (equal (plist-get reply :type) "ran"))
      (should (equal (plist-get reply :status) "waiting"))
      (should (string-match-p "review" (plist-get reply :note)))
      (should-not (plist-member reply :preview))
      (should-not (memq 'ran (agent-ui-types)))
      (should (equal (agent-ui-staged-files) (list (expand-file-name "ran.el" agent-ui-staging-directory))))
      ;; Its preview in the review runs nothing either.
      (save-window-excursion (agent-ui-review-preview 'ran))
      (should-not (file-exists-p loaded))
      (should-not (file-exists-p compiled))
      ;; Kept: the user's yes, its code runs.
      (should (equal (plist-get (agent-ui-keep 'ran) :preview) "ran"))
      (should (file-exists-p loaded))
      (should (file-exists-p compiled))
      (should (memq 'ran (agent-ui-types))))))

;; ====== KEEPING, DISCARDING ======

(ert-deftest agent-ui-staging/kept ()
  (agent-ui-test-aust
    (agent-ui-stage agent-ui-test-aust-dial)
    (let* ((reply (agent-ui-keep 'dial))
           (kept (plist-get reply :file)))
      (should (equal kept (expand-file-name "dial.el" agent-ui-kept-directory)))
      (should (equal (plist-get reply :preview) "[####......] 42%"))
      (should (equal (plist-get reply :warnings) nil))
      (should (file-exists-p kept))
      (should-not (agent-ui-staged-files))
      (should-not (agent-ui-staged-p 'dial))
      (should (equal (agent-ui-type-file (agent-ui-type 'dial)) kept))
      (should (equal agent-ui-test-aust-kept (list (list 'dial kept))))
      ;; At the next start: loaded from there.
      (agent-ui-undefine 'dial)
      (agent-ui-load-kept)
      (should (equal (agent-ui-render '(:type "dial" :value 50) (agent-ui-context)) "[#####.....] 50%"))
      ;; Now it's a kept type: the agent can't stage another so named.
      (should (string-match-p "dial is a type already" (agent-ui-test-aust-refused agent-ui-test-aust-dial))))))

(ert-deftest agent-ui-staging/a-kept-type-failing-to-load-said ()
  (agent-ui-test-aust
    (with-temp-file (expand-file-name "broken.el" agent-ui-kept-directory)
      (insert "(error \"Broken\")"))
    (let (said)
      (cl-letf (((symbol-function 'message) (lambda (&rest args) (push (apply #'format args) said))))
        (agent-ui-load-kept))
      (should (string-match-p "the kept type broken doesn't load: Broken" (car said))))))

(ert-deftest agent-ui-staging/discarded ()
  (agent-ui-test-aust
    (agent-ui-stage agent-ui-test-aust-dial)
    (should (eq (agent-ui-discard 'dial) 'dial))
    (should-not (agent-ui-staged-files))
    (should-not (memq 'dial (agent-ui-types)))
    (should (string-match-p "no staged type dial"
                            (agent-ui-error-message (should-error (agent-ui-discard 'dial)
                                                                  :type 'agent-ui-error))))))

(ert-deftest agent-ui-staging/after-a-restart ()
  (agent-ui-test-aust
    (agent-ui-stage agent-ui-test-aust-dial "S")
    ;; A restart: the file waits; who made it, forgotten.
    (clrhash agent-ui--staged-by)
    (should (agent-ui-staged-files))
    (should (agent-ui-staged-p 'dial))
    ;; Kept: loaded then; no session to tell.
    (agent-ui-keep 'dial)
    (should (agent-ui-type 'dial))
    (should (equal (nth 2 (car agent-ui-test-aust-told)) nil))))

(ert-deftest agent-ui-staging/the-agent-told-what-became-of-it ()
  "Kept: the agent that made it told (its session's canvas), its example drawn;
discarded: told too (doom-ht6.127)."
  (agent-ui-test-aust
    (agent-ui-stage agent-ui-test-aust-dial "Claude Agent @ proj")
    (agent-ui-stage (replace-regexp-in-string "dial" "meter" agent-ui-test-aust-dial) "Other")
    (agent-ui-keep 'dial)
    (pcase-let ((`(,name ,text ,canvas) (car agent-ui-test-aust-told)))
      (should (eq name 'dial))
      (should (equal canvas "Claude Agent @ proj"))
      (should (string-match-p "\\`Agent UI: the user kept your type dial: it's loaded, you can show it now. Its example drawn:\n\\[####......\\] 42%\\'"
                              text)))
    (agent-ui-discard 'meter)
    (should (equal (car agent-ui-test-aust-told)
                   '(meter "Agent UI: the user discarded your type meter." "Other")))))

;; ====== THE REVIEW ======


(ert-deftest agent-ui-staging/a-preview ()
  "Its preview: what it is, its properties, its example and its code, as its
file says; nothing of it run, it isn't loaded."
  (agent-ui-test-aust
    (agent-ui-stage agent-ui-test-aust-dial)
    (let ((buffer (save-window-excursion (agent-ui-review-preview 'dial))))
      (with-current-buffer buffer
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-prefix-p "dial, made by the agent\nA dial: VALUE percent.\n" text))
          (should (string-match-p "  value +integer +Percent (default 0)" text))
          (should (string-match-p "Its example\n{\"value\":42}\nDrawn once you keep it" text))
          (should (string-match-p "(agent-ui-define dial" text)))
        (should (eq agent-ui-review--type 'dial))))
    (should-not (memq 'dial (agent-ui-types)))))

(ert-deftest agent-ui-staging/kept-and-discarded-from-the-review ()
  (agent-ui-test-aust
    (agent-ui-stage agent-ui-test-aust-dial)
    (agent-ui-stage (replace-regexp-in-string "dial" "meter" agent-ui-test-aust-dial))
    (save-window-excursion
      (agent-ui-review)
      (agent-ui-review-keep 'dial)
      (agent-ui-review-discard 'meter)
      (with-current-buffer agent-ui-review-buffer
        (should-not tabulated-list-entries)))
    (should (file-exists-p (expand-file-name "dial.el" agent-ui-kept-directory)))
    (should-not (memq 'meter (agent-ui-types)))))

(defun agent-ui-test-aust-header ()
  "The current canvas's header as its window (the selected one) draws it:
`format-mode-line' gives nothing in batch."
  (pcase header-line-format
    (`(:eval ,form) (eval form t))
    (_ (format "%s" header-line-format))))

(ert-deftest agent-ui-staging/the-canvas-says-so ()
  (agent-ui-test-aust
    (agent-ui-show '(:id "t" :type "text" :text "x"))
    (with-current-buffer (agent-ui-canvas)
      ;; None waiting: no header line (not an empty one).
      (should-not header-line-format)
      (agent-ui-stage agent-ui-test-aust-dial)
      (should (string-match-p "1 type made by the agent to review: dial" (agent-ui-test-aust-header)))
      (should (eq (lookup-key agent-ui-canvas-mode-map "R") #'agent-ui-review))
      (agent-ui-discard 'dial)
      (agent-ui-review--refresh)
      (should-not header-line-format))))

(ert-deftest agent-ui-staging/the-canvas-header-fits-its-window ()
  "The header saying types wait for review, in a narrow pane: shortened, the
names cut, its key (R) kept, never wider than the window (74 columns in a
40-column pane: R review cut off)."
  (let ((names '("sparkline" "timeline-heat" "ownership-graph")))
    (dolist (width '(25 40 60 100))
      (let ((line (agent-ui-review--header-line names width)))
        (should (<= (string-width line) width))
        (should (string-match-p " R\\( review\\)?\\'" line))
        (should (string-match-p "\\b3\\b" line))))
    (should (equal (agent-ui-review--header-line names 100)
                   " 3 types made by the agent to review: sparkline, timeline-heat, ownership-graph   R review"))
    (should (string-prefix-p " 3 types to review: sparkl" (agent-ui-review--header-line names 40)))
    (should (string-suffix-p "…   R review" (agent-ui-review--header-line names 40)))
    (should (equal (agent-ui-review--header-line names 25) " 3 types to review  R"))
    (should (equal (agent-ui-review--header-line '("dial") 14) " 1 to review R")))
  ;; As its window shows it: that window's width.
  (agent-ui-test-aust
    (agent-ui-show '(:id "t" :type "text" :text "x"))
    (agent-ui-stage agent-ui-test-aust-dial)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((canvas (agent-ui-canvas))
                (window (split-window-right (- (window-total-width) 26))))
            (set-window-buffer window canvas)
            (with-selected-window window
              (let ((line (agent-ui-test-aust-header)))
                (should (< (window-max-chars-per-line window) 30))
                (should (<= (string-width line) (window-max-chars-per-line window)))
                (should (string-match-p " R\\'" line))))))
      (agent-ui-discard 'dial))))

;; The skill's example of a type: staged as the agent would.
(ert-deftest agent-ui-staging/the-skills-type-right ()
  (agent-ui-test-aust
    (let* ((skill (agent-ui-test-agent-ui-skill "references/custom-types.md"))
           (code (and (string-match "```elisp\n\\(\\(?:.\\|\n\\)*?\\)```" skill)
                      (match-string 1 skill)))
           (reply (progn (agent-ui-stage code) (agent-ui-keep 'dial))))
      (should (equal (plist-get reply :warnings) nil))
      (should (string-match-p "\\`\\[#+\\.+\\] 42%  disk\\'" (plist-get reply :preview)))
      (should (string-match-p "value must be from 0 to 100"
                              (agent-ui-error-message
                               (should-error (agent-ui-check "dial" '(:value 140)) :type 'agent-ui-error)))))))

;; ====== THE CONFIG ======


(ert-deftest agent-ui-staging/a-comment-after-the-last-form ()
  "A comment after a type's last form is a comment (it was read as one more
form, cut short: \"the code ends inside a form\")."
  (should (equal (agent-ui--read-forms "(defun agent-ui-x--a ())\n;; the end\n")
                 '((defun agent-ui-x--a ())))))

;; Where: in the user's Emacs directory.
(ert-deftest agent-ui-staging/where ()
  (should (equal agent-ui-staging-directory (locate-user-emacs-file "agent-ui/staged/")))
  (should (equal agent-ui-kept-directory (locate-user-emacs-file "agent-ui/kept/"))))

;;; agent-ui-staging-tests.el ends here
