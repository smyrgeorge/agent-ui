;;; agent-ui-trust-tests.el --- Tests for Agent UI: trust  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-trust.el: a project trusted (its code runs unasked: its
;; dashboards', a package's built on Agent UI), by its root's true name, an
;; agent's worktree its project's; the projects listed, one forgotten;
;; trusted interactively only with a yes typed.

;;; Code:

(require 'agent-ui-test-helper)

(defmacro agent-ui-test-trust (&rest body)
  "BODY with a trust file of its own (`file') and a project `root'."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "trust-" t)))
          (agent-ui-trust-file (expand-file-name "trusted.eld" dir))
          (root (file-name-as-directory (file-truename (make-temp-file "trust-project-" t)))))
     (unwind-protect (progn ,@body)
       (delete-directory dir t)
       (delete-directory root t))))

(ert-deftest agent-ui-trust/a-project-trusted-then-forgotten ()
  "Trusted: its code runs unasked, by its root's true name, written to the
trust file; listed, the latest first; forgotten: no longer, said."
  (agent-ui-test-trust
    (should-not (agent-ui-project-trusted-p root))
    (should-not (agent-ui-project-trusted-p nil))
    (should (equal (agent-ui-trust-project (directory-file-name root)) root))
    (should (agent-ui-project-trusted-p root))
    (should (file-exists-p agent-ui-trust-file))
    (should (equal (mapcar #'car (agent-ui-trusted-projects)) (list root)))
    ;; Trusted again: once, not twice.
    (agent-ui-trust-project root)
    (should (= (length (agent-ui-trusted-projects)) 1))
    (agent-ui-forget-project root)
    (should-not (agent-ui-project-trusted-p root))
    (should-not (agent-ui-trusted-projects))
    (should-error (agent-ui-forget-project root) :type 'user-error)))

(ert-deftest agent-ui-trust/a-worktree-shares-its-project-s ()
  "`agent-ui-trust-root-function' gives the root whose trust a root shares:
its project trusted, a worktree of it is."
  (agent-ui-test-trust
    (let* ((worktree (file-name-as-directory (make-temp-file "trust-worktree-" t)))
           (agent-ui-trust-root-function (lambda (dir) (if (equal dir worktree) root dir))))
      (unwind-protect
          (progn
            (agent-ui-trust-project root)
            (should (agent-ui-project-trusted-p worktree)))
        (delete-directory worktree t)))))

(ert-deftest agent-ui-trust/interactively-with-a-yes-typed ()
  "M-x agent-ui-trust-project: the current project's, confirmed with a yes
typed (`use-short-answers' aside); a no trusts nothing.  M-x
agent-ui-forget-project: the trusted ones to pick from; none: said."
  (agent-ui-test-trust
    (let ((default-directory root) (asked nil))
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                ((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (push (cons prompt use-short-answers) asked) nil)))
        (let ((use-short-answers t))
          (should-error (call-interactively #'agent-ui-trust-project) :type 'user-error))
        (should (string-prefix-p "Trust " (caar asked)))
        (should-not (cdar asked))
        (should-not (agent-ui-project-trusted-p root)))
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                ((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (call-interactively #'agent-ui-trust-project))
      (should (agent-ui-project-trusted-p root))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (should (equal collection (list (abbreviate-file-name root))))
                   (car collection))))
        (call-interactively #'agent-ui-forget-project))
      (should-not (agent-ui-project-trusted-p root))
      (should-error (call-interactively #'agent-ui-forget-project) :type 'user-error))))

(ert-deftest agent-ui-trust/loaded-when-first-used ()
  "Not with Emacs: its functions autoloaded, its commands too."
  (should (equal (agent-ui-test-fresh '(list (featurep 'agent-ui-trust)
                                             (and (fboundp 'agent-ui-project-trusted-p) t)
                                             (and (commandp 'agent-ui-trust-project) t)
                                             (and (commandp 'agent-ui-forget-project) t)))
                 '(nil t t t))))

;;; agent-ui-trust-tests.el ends here
