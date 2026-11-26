;;; agent-ui-source-tests.el --- Tests for Agent UI: source  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-source.el: components following a command Emacs runs, a file
;; as it grows, a polled command; rules turning lines into updates; stopped
;; with their component or canvas. Real processes (sh), files in the test's
;; temp folder.

;;; Code:

(require 'agent-ui-test-helper)

;; ====== HELPERS ======

(defmacro agent-ui-test-ausrc (&rest body)
  "BODY with a canvas of its own (killed after), no window shown."
  (declare (indent 0))
  `(let* ((agent-ui-default-canvas (make-temp-name "source-"))
          (agent-ui-display-function #'ignore)
          (agent-ui-source-file-interval 0.05)
          (agent-ui-source-log-directory (file-name-as-directory (agent-ui-test-tmp-file "source-logs/")))
          (canvas (agent-ui-canvas)))
     (unwind-protect (progn ,@body)
       (when (buffer-live-p canvas) (kill-buffer canvas)))))

(defun agent-ui-test-ausrc-wait (predicate &optional timeout)
  (with-timeout ((or timeout 5) (ert-fail "Waited too long"))
    (while (not (funcall predicate))
      (accept-process-output nil 0.02))))

(defun agent-ui-test-ausrc-ended (id)
  (agent-ui-test-ausrc-wait (lambda () (eq (plist-get (agent-ui-source-status id) :running) :false))))

(defun agent-ui-test-ausrc-text ()
  "The canvas's text under its top line (an empty line of its own: checked)."
  (with-current-buffer (agent-ui-canvas)
    (agent-ui--flush)
    (should (eql (char-after (point-min)) ?\n))
    (buffer-substring-no-properties (1+ (point-min)) (point-max))))

(defun agent-ui-test-ausrc-error (source)
  (agent-ui-error-message (should-error (agent-ui-source-check source) :type 'agent-ui-error)))

;; ====== REGULAR EXPRESSIONS ======

(ert-deftest agent-ui-source/pcre-as-emacs-regexps ()
  (dolist (case '(("(\\d+)/(\\d+)" "\\([0-9]+\\)/\\([0-9]+\\)")
                  ("a|b" "a\\|b")
                  ("(?:x)" "\\(?:x\\)")
                  ("x{2,3}" "x\\{2,3\\}")
                  ("\\s+\\S\\w\\W" "[[:space:]]+[^[:space:]][[:alnum:]_][^[:alnum:]_]")
                  ("[\\d.]+" "[0-9.]+")
                  ("[^]x]" "[^]x]")
                  ("\\[\\(\\.\\)" "\\[(\\.)")
                  ("^a$" "^a$")
                  ;; In a class: an escaped ] first, ^ and - last (doom-ht6.59).
                  ("[\\[\\]]" "[][]")
                  ("[a\\-z]" "[az-]")
                  ("[\\^a]" "[a^]")
                  ("[[:alpha:]_]" "[[:alpha:]_]")))
    (should (equal (agent-ui-source-regexp (car case)) (cadr case))))
  (should (string-match-p (agent-ui-source-regexp "^[\\[\\]]$") "]"))
  (should-not (string-match-p (agent-ui-source-regexp "^[a\\-z]$") "q"))
  (should (string-match-p (agent-ui-source-regexp "^[a\\-z]$") "-"))
  ;; As grep -E would match.
  (let ((re (agent-ui-source-regexp "^\\[(\\d+)/(\\d+)\\] (CC|LD) (\\S+)$")))
    (should (string-match re "[3/12] CC lexer.c"))
    (should (equal (match-string 4 "[3/12] CC lexer.c") "lexer.c"))
    (should-not (string-match re "[3/12] AS lexer.s"))))

;; ====== CHECKING ======

(ert-deftest agent-ui-source/a-wrong-source-explained ()
  (should (string-match-p "give one of command, file, poll" (agent-ui-test-ausrc-error '(:match "x" :set (:a 1)))))
  (should (string-match-p "give one of" (agent-ui-test-ausrc-error '(:command "a" :file "b" :tail 1))))
  (should (string-match-p "unknown key \"cmd\"" (agent-ui-test-ausrc-error '(:cmd "make"))))
  (should (string-match-p "give rules (or tail, into)" (agent-ui-test-ausrc-error '(:file "x.log"))))
  (should (string-match-p "rule 1 has no match" (agent-ui-test-ausrc-error '(:command "a" :rules ((:set (:a 1)))))))
  (should (string-match-p "rule 1 changes nothing" (agent-ui-test-ausrc-error '(:command "a" :match "x"))))
  (should (string-match-p "isn't a regular expression" (agent-ui-test-ausrc-error '(:command "a" :match "(" :set (:a 1)))))
  (should (string-match-p "tail is how many lines" (agent-ui-test-ausrc-error '(:command "a" :tail 0))))
  (should (string-match-p "every is a poll's" (agent-ui-test-ausrc-error '(:command "a" :every 5))))
  (should (string-match-p "every is seconds, 1 or more" (agent-ui-test-ausrc-error '(:poll "a" :every 0.1 :tail 1))))
  (should (string-match-p "done and failed are a command's" (agent-ui-test-ausrc-error '(:file "a" :tail 1 :done (:a 1)))))
  (should (string-match-p "not both" (agent-ui-test-ausrc-error '(:command "a" :match "x" :set (:a 1) :rules ((:match "y" :set (:b 1)))))))
  ;; In a component: refused with it.
  (agent-ui-test-ausrc
    (should (string-match-p "unknown key"
                            (agent-ui-error-message
                             (should-error (agent-ui-show '(:id "a" :type "text" :text "" :source (:cmd "x")))
                                           :type 'agent-ui-error))))
    (should-not (agent-ui-components))
    ;; An update can't change it.
    (agent-ui-show '(:id "a" :type "text" :text "" :source (:command "true" :tail 1)))
    (should (string-match-p "can't change a source"
                            (agent-ui-error-message
                             (should-error (agent-ui-update "a" '(:source (:command "false" :tail 1)))
                                           :type 'agent-ui-error))))))

;; ====== A COMMAND ======

(ert-deftest agent-ui-source/a-command-drives-a-bar ()
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "b" :type "progress" :max 1
                     :source (:command "for i in 1 2 3; do echo \"[$i/3] CC f$i.c\"; done; echo linking"
                              :match "^\\[(\\d+)/(\\d+)\\] CC (\\S+)$"
                              :set (:value "$1" :max "$2" :label "compiling $3"))))
    (agent-ui-test-ausrc-ended "b")
    ;; Its last line's values; done by itself (exit 0).
    (should (equal (agent-ui-get "b") (agent-ui-get "b")))
    (let ((component (agent-ui-get "b")))
      (should (equal (plist-get component :value) 3))
      (should (equal (plist-get component :max) 3))
      (should (equal (plist-get component :label) "compiling f3.c"))
      (should (equal (plist-get component :status) "done")))
    (let ((status (agent-ui-source-status "b")))
      (should (equal (plist-get status :kind) "command"))
      (should (equal (plist-get status :exit) 0))
      (should (equal (plist-get status :lines) 4))
      ;; Its output, all of it, for the agent to read.
      (should (equal (with-temp-buffer (insert-file-contents (plist-get status :log)) (buffer-string))
                     "[1/3] CC f1.c\n[2/3] CC f2.c\n[3/3] CC f3.c\nlinking\n")))))

(ert-deftest agent-ui-source/its-rules-match-case ()
  "Its rules match as grep -E does: case counts (doom-ht6.47)."
  (agent-ui-test-ausrc
    (let ((case-fold-search t))
      (agent-ui-show '(:id "t" :type "table" :columns ("Test" "Result") :key 0
                       :source (:command "echo 'test a ... FAILED'; echo 'test b ... failed (a warning)'"
                                :match "^test (\\S+) \\.\\.\\. (FAILED)" :append (:rows (("$1" "$2"))))))
      (agent-ui-test-ausrc-ended "t")
      (should (equal (plist-get (agent-ui-get "t") :rows) '(("a" "FAILED")))))))

(ert-deftest agent-ui-source/a-command-failing ()
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "b" :type "progress" :max 4 :source (:command "echo 1; exit 3" :match "^(\\d)$" :set (:value "$1"))))
    (agent-ui-test-ausrc-ended "b")
    (should (equal (plist-get (agent-ui-get "b") :status) "failed"))
    (should (equal (plist-get (agent-ui-get "b") :label) "exited with 3"))
    ;; Its own done and failed, with $code.
    (agent-ui-show '(:id "t" :type "table" :columns ("Test" "Result") :key 0
                     :source (:command "printf 'a ... ok\\nb ... FAILED\\nb ... ok\\n'; exit 1"
                              :rules ((:match "^(\\w+) \\.\\.\\. (ok|FAILED)$" :append (:rows (("$1" "$2")))))
                              :failed (:title "Tests: exit $code"))))
    (agent-ui-test-ausrc-ended "t")
    (should (equal (plist-get (agent-ui-get "t") :rows) '(("a" "ok") ("b" "ok"))))
    (should (equal (plist-get (agent-ui-get "t") :title) "Tests: exit 1"))))

(ert-deftest agent-ui-source/running-until-its-end-is-handled ()
  "A command dead, its sentinel not run yet (Emacs runs it a moment after):
still running, its exit and patch not there; once run, done."
  (agent-ui-test-ausrc
    (let (held)
      (cl-letf* ((exited (symbol-function 'agent-ui-source--exited))
                 ((symbol-function 'agent-ui-source--exited)
                  (lambda (&rest args) (push (lambda () (apply exited args)) held))))
        (agent-ui-show '(:id "b" :type "progress" :max 4 :source (:command "exit 3")))
        (agent-ui-test-ausrc-wait (lambda () held))
        (let ((status (agent-ui-source-status "b")))
          (should (eq (plist-get status :running) t))
          (should-not (plist-get status :exit)))
        (should-not (plist-get (agent-ui-get "b") :status))
        (funcall (car held))
        (let ((status (agent-ui-source-status "b")))
          (should (eq (plist-get status :running) :false))
          (should (equal (plist-get status :exit) 3)))
        (should (equal (plist-get (agent-ui-get "b") :status) "failed"))))))

(ert-deftest agent-ui-source/a-tail ()
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "log" :type "text" :text "" :source (:command "seq 1 50" :tail 3)))
    (agent-ui-test-ausrc-ended "log")
    (should (equal (plist-get (agent-ui-get "log") :text) "48\n49\n50"))))

(ert-deftest agent-ui-source/a-tail-of-quick-output-applied-at-most-every-redraw ()
  "A command's output in many chunks quickly: its tail applied once, a moment
after (`agent-ui-redraw-delay'), not one update per chunk (each joined its
lines again and updated the component); its last lines applied at once when
it ends; none left pending once it stops or its canvas closes
\(doom-ht6.109)."
  (agent-ui-test-ausrc
    (cl-flet ((pending () (cl-count-if (lambda (timer) (eq (timer--function timer) #'agent-ui-source--flush))
                                       timer-list)))
      (agent-ui-show '(:id "log" :type "text" :text "" :source (:command "cat" :tail 3)))
      (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "log")))
            (updates 0))
        (cl-letf* ((update (symbol-function 'agent-ui-update))
                   ((symbol-function 'agent-ui-update)
                    (lambda (id &rest args)
                      (when (equal id "log") (cl-incf updates))
                      (apply update id args))))
          ;; Each line in two chunks.
          (dotimes (i 200)
            (funcall (process-filter process) process (format "line %d" (1+ i)))
            (funcall (process-filter process) process "\n"))
          (should (= updates 0))
          (should (= (pending) 1))
          (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "log") :text)
                                                      "line 198\nline 199\nline 200")))
          (should (= updates 1))
          ;; Its end: its last lines (one without a newline) at once.
          (funcall (process-filter process) process "line 201\nline 202")
          (process-send-eof process)
          (agent-ui-test-ausrc-ended "log")
          (should (equal (plist-get (agent-ui-get "log") :text) "line 200\nline 201\nline 202"))
          (should (= (pending) 0))
          (should (equal (plist-get (agent-ui-source-status "log") :exit) 0))
          (should (equal (plist-get (agent-ui-source-status "log") :lines) 202))))
      ;; Stopped, or its canvas closed: its update dropped.
      (agent-ui-show '(:id "a" :type "text" :text "" :source (:command "cat" :tail 3)))
      (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "a"))))
        (funcall (process-filter process) process "x\n")
        (should (= (pending) 1))
        (agent-ui-remove "a")
        (should (= (pending) 0)))
      (agent-ui-show '(:id "b" :type "text" :text "" :source (:command "cat" :into "text")))
      (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "b"))))
        (funcall (process-filter process) process "x\n")
        (should (= (pending) 1))
        (kill-buffer canvas)
        (should (= (pending) 0))))))

(ert-deftest agent-ui-source/a-long-line-not-searched-again-at-each-chunk ()
  "A command writing a long line without a newline, in many chunks: each
chunk's work bounded (its line ends searched for in it alone, the line so far
cut into lines of `agent-ui-source-line-max' characters), not all of the line
again at each (quadratic: Emacs stalled); all of it there in the end
\(doom-ht6.109)."
  (agent-ui-test-ausrc
    (let ((agent-ui-source-line-max 1000)
          (longest 0)
          (all (mapconcat (lambda (i) (make-string 100 (+ ?a (% i 26)))) (number-sequence 0 299) "")))
      (agent-ui-show '(:id "j" :type "text" :text "" :source (:command "cat" :into "text")))
      (let* ((state (agent-ui-source--state canvas "j"))
             (process (agent-ui-source--state-process state)))
        (cl-letf* ((split (symbol-function 'split-string))
                   ((symbol-function 'split-string)
                    (lambda (string &rest args)
                      (setq longest (max longest (length string)))
                      (apply split string args))))
          (dotimes (i 300)
            (funcall (process-filter process) process (substring all (* i 100) (* (1+ i) 100)))
            (should (<= (length (agent-ui-source--state-partial state)) 1000))))
        (should (<= longest 1100))
        (process-send-eof process)
        (agent-ui-test-ausrc-ended "j")
        (let ((lines (split-string (plist-get (agent-ui-get "j") :text) "\n")))
          (should (equal (apply #'concat lines) all))
          (should (cl-every (lambda (line) (<= (length line) 1000)) lines)))
        (should (equal (plist-get (agent-ui-source-status "j") :exit) 0))
        (should (equal (plist-get (agent-ui-source-status "j") :lines) 30))))))

(ert-deftest agent-ui-source/carriage-returns-are-lines ()
  ;; A progress meter rewriting its line.
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "d" :type "progress" :max 100
                     :source (:command "printf ' 10%%\\r 55%%\\r 90%%\\r'" :match "(\\d+)%" :set (:value "$1"))))
    (agent-ui-test-ausrc-ended "d")
    (should (equal (plist-get (agent-ui-get "d") :value) 90))))

(ert-deftest agent-ui-source/in-its-directory ()
  (agent-ui-test-ausrc
    (let ((dir (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "src-dir-") t))))
      (agent-ui-show (list :id "p" :type "text" :text "" :source (list :command "pwd" :tail 1 :dir dir)))
      (agent-ui-test-ausrc-ended "p")
      (should (equal (file-truename (file-name-as-directory (plist-get (agent-ui-get "p") :text)))
                     (file-truename dir))))))

(ert-deftest agent-ui-source/a-bad-change-said-not-raised ()
  (agent-ui-test-ausrc
    ;; "x" isn't a number: the bar's update is refused, its source says why.
    (agent-ui-show '(:id "b" :type "progress" :max 4 :source (:command "echo v=x" :match "v=(\\w)" :set (:value "$1"))))
    (agent-ui-test-ausrc-ended "b")
    (should (string-match-p "value must be a number" (plist-get (agent-ui-source-status "b") :error)))))

;; ====== STOPPING ======

(ert-deftest agent-ui-source/stopped-with-its-component ()
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "s" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
    (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "s"))))
      (should (process-live-p process))
      (agent-ui-remove "s")
      (should-not (process-live-p process))
      (should-not (agent-ui-source-status "s")))
    ;; Shown again without a source: the old one stopped.
    (agent-ui-show '(:id "s" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
    (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "s"))))
      (agent-ui-show '(:id "s" :type "text" :text "plain"))
      (should-not (process-live-p process)))
    ;; Its canvas closed: all of them.
    (agent-ui-show '(:id "k" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
    (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "k"))))
      (kill-buffer canvas)
      (should-not (process-live-p process)))))

;; ====== A FILE, A POLL ======

(ert-deftest agent-ui-source/a-file-followed ()
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "follow-%d.log" (random 100000)))))
      (with-temp-file file (insert "old 1\n"))
      ;; From its end: what's there already doesn't count.
      (agent-ui-show (list :id "f" :type "chart" :kind "sparkline"
                           :source (list :file file :from "end" :match "^v (\\d+)$" :append '(:values ("$1")))))
      (accept-process-output nil 0.1)
      (write-region "v 3\nv 5\nv" nil file t 'silent)
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "f") :values) '(3 5))))
      ;; The rest of a line once it's written.
      (write-region " 8\n" nil file t 'silent)
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "f") :values) '(3 5 8))))
      ;; Written again from its start.
      (write-region "v 1\n" nil file nil 'silent)
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "f") :values) '(3 5 8 1))))
      (should (eq (plist-get (agent-ui-source-status "f") :running) t)))))

;; A character written in two goes: read whole, not as raw bytes
;; (doom-ht6.44).
(ert-deftest agent-ui-source/a-character-written-in-two-goes ()
  (should (= (agent-ui-source--utf-8-whole "") 0))
  (should (= (agent-ui-source--utf-8-whole "ok") 2))
  (should (= (agent-ui-source--utf-8-whole (unibyte-string ?o ?k #xe2)) 2))
  (should (= (agent-ui-source--utf-8-whole (unibyte-string ?o ?k #xe2 #x9c)) 2))
  (should (= (agent-ui-source--utf-8-whole (unibyte-string ?o ?k #xe2 #x9c #x93)) 5))
  (should (= (agent-ui-source--utf-8-whole (unibyte-string #xf0 #x9f #x98)) 0))
  ;; Not UTF-8 at all: read as it is.
  (should (= (agent-ui-source--utf-8-whole (unibyte-string ?a #x9c #x9c #x9c #x9c)) 5))
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "split-%d.log" (random 100000))))
          (coding-system-for-write 'no-conversion))
      (write-region "" nil file nil 'silent)
      (agent-ui-show (list :id "f" :type "text" :text "" :source (list :file file :tail 1)))
      (accept-process-output nil 0.1)
      (write-region (unibyte-string ?o ?k ?\s #xe2) nil file t 'silent)
      (accept-process-output nil 0.2)
      (write-region (unibyte-string #x9c #x93 ?\s ?d ?o ?n ?e ?\n) nil file t 'silent)
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "f") :text) "ok ✓ done"))))))

(ert-deftest agent-ui-source/a-big-file-read-a-slice-at-a-time ()
  "A file bigger than a slice: each look reads at most a slice, the rest
the next looks; its lines all arrive once, in order, a character split at
a slice's end read whole (it was read in one look, however big: a big log
froze Emacs) (doom-ht6.108)."
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "big-%d.log" (random 100000))))
          (agent-ui-source-file-chunk 50)
          (coding-system-for-write 'utf-8))
      (with-temp-file file
        (dotimes (i 60) (insert (format "é %d\n" (1+ i)))))
      (agent-ui-show (list :id "t" :type "table" :columns '("N")
                           :source (list :file file :match "^é (\\d+)$" :append '(:rows (("$1"))))))
      (let ((state (agent-ui-source--state canvas "t"))
            (size (file-attribute-size (file-attributes file)))
            (looks 0))
        ;; Its timer's looks taken by hand.
        (cancel-timer (agent-ui-source--state-timer state))
        (agent-ui-source--look canvas "t")
        (should (<= 46 (agent-ui-source--state-offset state) 50))
        (should (< 0 (length (plist-get (agent-ui-get "t") :rows)) 60))
        (while (< (agent-ui-source--state-offset state) size)
          (let ((before (agent-ui-source--state-offset state)))
            (agent-ui-source--look canvas "t")
            (should (< before (agent-ui-source--state-offset state) (+ before 51))))
          (should (< (cl-incf looks) 100)))
        (should-not (agent-ui-source--state-error state))
        (should (equal (plist-get (agent-ui-get "t") :rows)
                       (cl-loop for i from 1 to 60 collect (list i))))))))

(ert-deftest agent-ui-source/a-big-files-tail-from-near-its-end ()
  "A tail of a big file (no rules): its first look reads a slice from near
its end, its last lines there at once (doom-ht6.108)."
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "big-tail-%d.log" (random 100000))))
          (agent-ui-source-file-chunk 64)
          (read nil))
      (with-temp-file file
        (dotimes (i 1000) (insert (format "line %d\n" (1+ i)))))
      (agent-ui-show (list :id "f" :type "text" :text "" :source (list :file file :tail 2)))
      (cancel-timer (agent-ui-source--state-timer (agent-ui-source--state canvas "f")))
      (cl-letf* ((insert-literally (symbol-function 'insert-file-contents-literally))
                 ((symbol-function 'insert-file-contents-literally)
                  (lambda (file visit beg end &rest rest)
                    (push (- end beg) read)
                    (apply insert-literally file visit beg end rest))))
        (agent-ui-source--look canvas "f"))
      (should (equal read '(64)))
      (should (equal (plist-get (agent-ui-get "f") :text) "line 999\nline 1000"))
      ;; Its lines from there on as usual.
      (write-region "line 1001\n" nil file t 'silent)
      (agent-ui-source--look canvas "f")
      (should (equal (plist-get (agent-ui-get "f") :text) "line 1000\nline 1001")))))

(ert-deftest agent-ui-source/an-append-rule-over-many-lines-linear ()
  "An append rule over many matching lines: their values in order, gathered
in linear work (each match copied all before it again: quadratic)
\(doom-ht6.108)."
  (let ((state (agent-ui-source-check '(:file "x.log" :match "^v (\\d+)$" :append (:values ("$1") :labels "l$1")))))
    (cl-flet ((lines (n) (cl-loop for i from 1 to n collect (format "v %d" i)))
              (consed (lines)
                (let ((before (car (memory-use-counts))))
                  (agent-ui-source--apply state lines)
                  (- (car (memory-use-counts)) before))))
      (should (equal (agent-ui-source--apply state (append (lines 3) '("x")))
                     '(nil :values (1 2 3) :labels ("l1" "l2" "l3"))))
      (let ((applied (agent-ui-source--apply state (lines 2000))))
        (should (equal (plist-get (cdr applied) :values) (number-sequence 1 2000))))
      ;; Four times the lines: about four times the conses, not sixteen.
      (let ((few (consed (lines 1000)))
            (many (consed (lines 4000))))
        (should (< many (* 6 few)))))))

(ert-deftest agent-ui-source/a-file-not-there-yet ()
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "later-%d.log" (random 100000)))))
      (agent-ui-show (list :id "f" :type "text" :text "" :source (list :file file :tail 2)))
      (accept-process-output nil 0.1)
      (write-region "a\nb\nc\n" nil file nil 'silent)
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "f") :text) "b\nc"))))))

(ert-deftest agent-ui-source/from-the-end-of-a-file-not-there-yet ()
  "from: end on a file not there yet: its first output, once it is, counts
\(it's all new) (doom-ht6.61)."
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "end-later-%d.log" (random 100000)))))
      (agent-ui-show (list :id "f" :type "text" :text "" :source (list :file file :from "end" :tail 2)))
      (accept-process-output nil 0.1)
      (write-region "first\nsecond\n" nil file nil 'silent)
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "f") :text) "first\nsecond"))))))

(ert-deftest agent-ui-source/a-poll ()
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "count-%d" (random 100000)))))
      (with-temp-file file (insert "1"))
      (agent-ui-show (list :id "p" :type "chart" :kind "sparkline"
                           :source (list :poll (format "cat %s" (shell-quote-argument file)) :every 1
                                         :match "^(\\d+)$" :append '(:values ("$1")))))
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "p") :values) '(1))))
      (with-temp-file file (insert "7"))
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "p") :values) '(1 7))) 4))))

(ert-deftest agent-ui-source/one-that-cant-run-said ()
  "A command or a poll in a directory that isn't there: the component shown,
its source stopped, its error said (the show was an error out of it, the
component in all the same; a poll said running forever, its timer failing at
each run). A wrong source among a panel's children: the show refused, nothing
added."
  (agent-ui-test-ausrc
    (let* ((gone (expand-file-name "not-there/" (agent-ui-test-tmp-file "")))
           (timer-errors 0))
      (cl-letf* ((message-fn (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (when (and format-string (string-match-p "Error running timer" format-string))
                      (cl-incf timer-errors))
                    (apply message-fn format-string args))))
        (dolist (source (list (list :command "pwd" :tail 1 :dir gone)
                              (list :poll "pwd" :every 1 :tail 1 :dir gone)))
          (should (equal (agent-ui-show (list :id "p" :type "text" :text "" :source source)) "p"))
          (should (equal (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components)) '("p")))
          (let ((status (agent-ui-source-status "p")))
            (should (eq (plist-get status :running) :false))
            (should (string-match-p "no directory .*not-there" (plist-get status :error))))
          (agent-ui-remove "p"))
        ;; Its dir gone after it started: stopped at its next run, said.
        (let ((dir (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "polled-") t))))
          (agent-ui-show (list :id "q" :type "text" :text "" :source (list :poll "pwd" :every 1 :tail 1 :dir dir)))
          (agent-ui-test-ausrc-wait (lambda () (plist-get (agent-ui-get "q") :text)))
          (delete-directory dir t)
          (agent-ui-test-ausrc-wait (lambda () (eq (plist-get (agent-ui-source-status "q") :running) :false)) 3)
          (should (string-match-p "no directory" (plist-get (agent-ui-source-status "q") :error))))
        (should (= timer-errors 0)))
      ;; Through a request: ok, the reply says why.
      (let ((reply (agent-ui-do "show" nil (list :id "r" :type "text" :text ""
                                                 :source (list :command "pwd" :dir gone))
                                canvas)))
        (should (eq (plist-get reply :ok) t))
        (should (string-match-p "no directory" (plist-get (plist-get reply :source) :error))))
      ;; A panel's child's source wrong: refused, nothing added.
      (should (string-match-p "panel: child c: source: give one of command, file, poll"
                              (agent-ui-error-message
                               (should-error (agent-ui-show '(:id "panel" :type "panel"
                                                              :children ((:id "c" :type "text" :text "" :source (:tail 3)))))
                                             :type 'agent-ui-error))))
      (should-not (member "panel" (mapcar (lambda (e) (plist-get e :id)) (agent-ui-components)))))))

(ert-deftest agent-ui-source/its-log-deleted-when-it-stops ()
  "A command's log: kept while its component is shown (for the agent to read),
and once it's removed if its command ended; one still running killed, its
log deleted, when it's removed or shown again; all deleted with its canvas
\(they stayed in the temporary folder)."
  (agent-ui-test-ausrc
    (cl-flet ((log-of (id) (plist-get (agent-ui-source-status id) :log)))
      (agent-ui-show '(:id "a" :type "text" :text "" :source (:command "echo a" :tail 1)))
      (agent-ui-test-ausrc-ended "a")
      (let ((ended (log-of "a")))
        (should (file-exists-p ended))
        (agent-ui-remove "a")
        (should (file-exists-p ended))
        (agent-ui-show '(:id "r" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
        (let ((log (log-of "r")))
          (agent-ui-remove "r")
          (should-not (file-exists-p log)))
        (agent-ui-show '(:id "b" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
        (let ((log (log-of "b")))
          (agent-ui-show '(:id "b" :type "text" :text "" :source (:command "echo again" :tail 1)))
          (should-not (file-exists-p log))
          (should (file-exists-p (log-of "b"))))
        ;; A panel's child's too, with its canvas; the ended one's kept till then.
        (agent-ui-show '(:id "p" :type "panel" :children ((:id "c" :type "text" :text "" :source (:command "echo c" :tail 1)))))
        (let ((logs (list ended (log-of "b") (log-of "c"))))
          (should (cl-every #'file-exists-p logs))
          (kill-buffer canvas)
          (should-not (cl-some #'file-exists-p logs)))))))

(ert-deftest agent-ui-source/a-finished-commands-log-kept-until-its-canvas-closes ()
  "A progress bar's command that went well: its bar closes itself (its
countdown over), its log kept (the agent was told to read it), deleted
once its canvas is killed (doom-ht6.106)."
  (let ((agent-ui-default-canvas (make-temp-name "source-"))
        (agent-ui-display-function #'switch-to-buffer)
        (agent-ui-close-finished 10)
        (agent-ui-source-log-directory (file-name-as-directory (agent-ui-test-tmp-file "source-logs/"))))
    (save-window-excursion
      (delete-other-windows)
      (let ((canvas (agent-ui-canvas)))
        (switch-to-buffer canvas)
        (unwind-protect
            (progn
              (agent-ui-show '(:id "keep" :type "text" :text "")) ; the canvas stays
              (agent-ui-show '(:id "build" :type "progress" :source (:command "echo warning: x")))
              (let ((log (plist-get (agent-ui-source-status "build") :log)))
                (agent-ui-test-ausrc-ended "build")
                (should (equal (plist-get (agent-ui-get "build") :status) "done"))
                (dotimes (_ 10)
                  (agent-ui--closing-tick canvas (buffer-local-value 'agent-ui--closing-timer canvas)))
                (should-not (member "build" (buffer-local-value 'agent-ui--order canvas)))
                (should (file-exists-p log))
                (should (equal (with-temp-buffer (insert-file-contents log) (buffer-string))
                               "warning: x\n"))
                (kill-buffer canvas)
                (should-not (file-exists-p log))))
          (when (buffer-live-p canvas) (kill-buffer canvas)))))))

(ert-deftest agent-ui-source/late-output-of-a-stopped-source-ignored ()
  "A command's output and end read after its source stopped (deleting
another process reads what an exited one left: its log was written again,
on Linux, once its canvas was killed): its log not written again, the
component's next source neither fed nor told it ended."
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "b" :type "text" :text "" :source (:command "echo first" :tail 1)))
    (let* ((first (with-current-buffer canvas (gethash "b" agent-ui-source--states)))
           (process (agent-ui-source--state-process first))
           (log (agent-ui-source--state-log first)))
      (agent-ui-test-ausrc-ended "b")
      ;; Shown again: its first source stopped, its log (it ended) kept.
      (agent-ui-show '(:id "b" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
      (should (file-exists-p log))
      ;; The first command's output and end, read late.
      (funcall (process-filter process) process "late\n")
      (funcall (process-sentinel process) process "finished\n")
      (should (equal (with-temp-buffer (insert-file-contents log) (buffer-string)) "first\n"))
      (should-not (string-match-p "late" (agent-ui-test-ausrc-text)))
      (should (eq (plist-get (agent-ui-source-status "b") :running) t))
      (should-not (plist-get (agent-ui-source-status "b") :exit))
      ;; Its canvas killed: deleted, not made again.
      (kill-buffer canvas)
      (should-not (file-exists-p log))
      (funcall (process-filter process) process "later\n")
      (should-not (file-exists-p log)))))

(defvar agent-ui-source--private-log-directory)

(ert-deftest agent-ui-source/its-logs-in-a-folder-of-the-users-own ()
  "Commands' logs: in `agent-ui-source-log-directory', made with mode 700;
not in it if it's there already but a link, open to others or someone
else's, in a folder of their own made once instead (doom-ht6.110: another
user could make /tmp/agent-ui/ first and put links in place of logs)."
  (let* ((root (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "log-dirs-") t)))
         (agent-ui-source--private-log-directory nil))
    (cl-flet ((log-dir (dir)
                (agent-ui-test-ausrc
                  (let ((agent-ui-source-log-directory dir))
                    (agent-ui-show '(:id "c" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
                    (let ((log (plist-get (agent-ui-source-status "c") :log)))
                      (should (file-exists-p log))
                      (file-name-directory log)))))
              (private-p (dir)
                (and (eq (file-attribute-type (file-attributes (directory-file-name dir))) t)
                     (eql (file-modes dir) #o700))))
      ;; Not there: made, private.
      (let ((new (expand-file-name "new/" root)))
        (should (equal (log-dir new) new))
        (should (private-p new))
        ;; Open to others: not used; one of its own instead, private, the same each time.
        (let ((open (expand-file-name "open/" root)))
          (make-directory open)
          (set-file-modes open #o777)
          (let ((instead (log-dir open)))
            (should-not (equal instead open))
            (should (private-p instead))
            (should (equal (log-dir open) instead))
            (should-not (directory-files open nil directory-files-no-dot-files-regexp))))
        ;; A link to a private folder: not followed.
        (let ((link (expand-file-name "link" root)))
          (make-symbolic-link (directory-file-name new) link)
          (should-not (equal (file-truename (log-dir (file-name-as-directory link)))
                             (file-truename new))))
        ;; Someone else's (its owner as `file-attributes' says).
        (let* ((theirs (expand-file-name "theirs/" root))
               (attributes (symbol-function 'file-attributes)))
          (make-directory theirs)
          (set-file-modes theirs #o700)
          (cl-letf (((symbol-function 'file-attributes)
                     (lambda (file &optional format)
                       (let ((a (funcall attributes file format)))
                         (if (equal (directory-file-name file) (directory-file-name theirs))
                             (append (list (nth 0 a) (nth 1 a) (1+ (user-uid))) (nthcdr 3 a))
                           a)))))
            (should-not (equal (log-dir theirs) theirs))))))))

(ert-deftest agent-ui-source/a-log-replaced-by-a-link-not-written-through ()
  "A command's log replaced by a link to another file: its output isn't
appended to that file (doom-ht6.110)."
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "c" :type "text" :text "" :source (:command "sleep 30" :tail 1)))
    (let* ((state (with-current-buffer canvas (gethash "c" agent-ui-source--states)))
           (process (agent-ui-source--state-process state))
           (log (agent-ui-source--state-log state))
           (other (agent-ui-test-tmp-file "someone-elses-file")))
      (with-temp-file other (insert "mine\n"))
      (delete-file log)
      (make-symbolic-link other log)
      (funcall (process-filter process) process "chunk\n")
      (should (equal (with-temp-buffer (insert-file-contents other) (buffer-string)) "mine\n"))
      ;; The component fed all the same.
      (should (eql (agent-ui-source--state-count state) 1)))))

;; ====== THROUGH THE COMMAND LINE ======

(ert-deftest agent-ui-source/in-a-request ()
  (agent-ui-test-ausrc
    (let* ((dir (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "req-dir-") t)))
           ;; As `agent-ui-request' has them.
           (agent-ui--request-cwd dir)
           (agent-ui-file-directory dir)
           (reply (agent-ui-do "show" nil
                               '(:id "p" :type "text" :text "" :source (:command "pwd" :tail 1))
                               canvas)))
      ;; Its log named; run in the agent's directory.
      (should (string-match-p "\\.log\\'" (plist-get reply :log)))
      (agent-ui-test-ausrc-ended "p")
      (should (equal (file-truename (file-name-as-directory (plist-get (agent-ui-get "p") :text)))
                     (file-truename dir)))
      (let ((listed (aref (plist-get (agent-ui-do "list" nil nil canvas) :components) 0)))
        (should (equal (plist-get (plist-get listed :source) :exit) 0))))))

(ert-deftest agent-ui-source/a-panels-children-in-the-agents-directory ()
  "Through a request from the agent's directory: a panel's child's source
runs there, a relative dir under it, an absolute one as it is (they ran in
the canvas's directory, whatever buffer's it was when it was made: /usr/,
/usr/sub/)."
  (agent-ui-test-ausrc
    (let* ((cwd (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "agent-cwd-") t)))
           (other (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "elsewhere-") t)))
           (folder (make-temp-file (agent-ui-test-tmp-file "req-") t)))
      (make-directory (expand-file-name "sub" cwd))
      (with-current-buffer canvas (setq default-directory other))
      (with-temp-file (expand-file-name "request" folder)
        (insert (format "show\n\n\n%s\n" cwd)))
      (with-temp-file (expand-file-name "payload" folder)
        (insert (json-serialize
                 (agent-ui-to-json
                  `(:id "p" :type "panel"
                   :children ((:id "here" :type "text" :text "" :source (:command "pwd" :tail 1))
                              (:id "sub" :type "text" :text "" :source (:command "pwd" :tail 1 :dir "sub"))
                              (:id "abs" :type "text" :text "" :source (:command "pwd" :tail 1 :dir ,other))))))))
      (let ((agent-ui-canvas-function (lambda (_session _cwd) canvas)))
        (agent-ui-request folder))
      (dolist (id '("here" "sub" "abs")) (agent-ui-test-ausrc-ended id))
      (cl-flet ((ran-in (id) (file-truename (file-name-as-directory (plist-get (agent-ui-get id) :text)))))
        (should (equal (ran-in "here") (file-truename cwd)))
        (should (equal (ran-in "sub") (file-truename (expand-file-name "sub/" cwd))))
        (should (equal (ran-in "abs") (file-truename other)))))))

;; ====== THE SKILL ======

(ert-deftest agent-ui-source/the-skills-sources-right ()
  "Each component the skill shows (a heredoc) right; those with a source,
their source checked (not run), its rules matching a line as they should
(a log's lines in columns, no source: not counted among them)."
  (let* ((skill (agent-ui-test-agent-ui-skill))
         (pos 0)
         (components nil))
    (while (string-match "^agent-ui show <<'EOF'\n\\(\\(?:.\\|\n\\)*?\\)\nEOF$" skill pos)
      (push (agent-ui-parse-json (match-string 1 skill)) components)
      (setq pos (match-end 0)))
    (dolist (component components)
      (should (agent-ui-check (plist-get component :type) component)))
    (setq components (seq-filter (lambda (component) (plist-get component :source)) (nreverse components)))
    (should (= (length components) 6))
    (dolist (component components)
      (should (agent-ui-source-check (plist-get component :source))))
    ;; The rules read what they're for.
    (cl-flet ((applied (component line)
                (agent-ui-source--apply (agent-ui-source-check (plist-get component :source)) (list line))))
      (should (equal (applied (nth 2 components) "[3/120] Building CXX object a.o")
                     '((:value 3 :max 120 :label "Building CXX object a.o"))))
      (should (equal (applied (nth 3 components) "test parser::empty ... FAILED")
                     '(nil :rows (("parser::empty" "FAILED")))))
      (should (equal (applied (nth 5 components) " 51234")
                     '(nil :values (51234)))))))

(ert-deftest agent-ui-source/all-of-it-into-a-property ()
  (agent-ui-test-ausrc
    ;; A diff following a command: its whole output, its diff.
    (agent-ui-show '(:id "d" :type "diff" :source (:command "printf -- '--- a/x\\n+++ b/x\\n@@ -1 +1 @@\\n-a\\n+b\\n'" :into "diff")))
    (agent-ui-test-ausrc-ended "d")
    (should (equal (plist-get (agent-ui-get "d") :diff) "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b"))
    (should (string-match-p "into names a property" (agent-ui-test-ausrc-error '(:command "a" :into "Bad Name"))))))

(ert-deftest agent-ui-source/a-log-following-a-file ()
  (agent-ui-test-ausrc
    (let ((file (agent-ui-test-tmp-file (format "app-%d.log" (random 100000)))))
      (with-temp-file file (insert "old\n"))
      (agent-ui-show (list :id "l" :type "log" :source (list :file file :from "end" :into "lines")))
      (accept-process-output nil 0.1)
      (write-region "12:00 INFO up\n12:01 ERROR down\n" nil file t 'silent)
      (agent-ui-test-ausrc-wait (lambda () (equal (plist-get (agent-ui-get "l") :lines) "12:00 INFO up\n12:01 ERROR down")))
      (should (string-prefix-p "1 error · 2 lines" (agent-ui-test-ausrc-text))))))


;; Shown again while its command runs: the old one's end doesn't mark the
;; new one failed, nor its output fill it (doom-ht6.43).
(ert-deftest agent-ui-source/shown-again-while-it-runs ()
  (agent-ui-test-ausrc
    (agent-ui-show '(:id "b" :type "progress" :max 2 :source (:command "sleep 30" :failed (:title "FAILED $code"))))
    (accept-process-output nil 0.1)
    (agent-ui-show '(:id "b" :type "progress" :max 2 :title "Build"))
    (accept-process-output nil 0.2)
    (let ((b (agent-ui-get "b")))
      (should (equal (plist-get b :title) "Build"))
      (should-not (plist-get b :status))
      (should-not (plist-get b :label)))
    ;; A panel's child replaced, the same.
    (agent-ui-show '(:id "p" :type "panel" :children ((:id "c" :type "text" :text "" :source (:command "sleep 30" :tail 1)))))
    (accept-process-output nil 0.1)
    (agent-ui-show '(:id "p" :type "panel" :children ((:id "c" :type "text" :text "new"))))
    (accept-process-output nil 0.2)
    (should (equal (plist-get (agent-ui-get "c") :text) "new"))))

(ert-deftest agent-ui-source/a-childs-source ()
  (agent-ui-test-ausrc
    ;; A child's source: started with its panel, updating the child.
    (agent-ui-show '(:id "p" :type "panel"
                     :children ((:id "c" :type "progress" :max 1
                                 :source (:command "echo 3/4" :match "(\\d)/(\\d)" :set (:value "$1" :max "$2"))))))
    (agent-ui-test-ausrc-ended "c")
    (should (equal (plist-get (agent-ui-get "c") :value) 3))
    (should (string-match-p "3/4  75%" (agent-ui-test-ausrc-text)))
    ;; Its panel removed: its source stopped.
    (agent-ui-show '(:id "q" :type "panel" :children ((:id "s" :type "text" :text "" :source (:command "sleep 30" :tail 1)))))
    (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "s"))))
      (should (process-live-p process))
      (agent-ui-remove "q")
      (should-not (process-live-p process)))
    ;; Updating a panel keeps its children's sources running; one gone, stopped.
    (agent-ui-show '(:id "r" :type "panel" :children ((:id "t" :type "text" :text "" :source (:command "sleep 30" :tail 1)))))
    (let ((process (agent-ui-source--state-process (agent-ui-source--state canvas "t"))))
      (agent-ui-update "r" '(:title "renamed"))
      (should (process-live-p process))
      (agent-ui-update "r" '(:children ((:id "u" :type "text" :text "x"))))
      (should-not (process-live-p process)))))

;;; agent-ui-source-tests.el ends here
