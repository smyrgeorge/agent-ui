;;; agent-ui-staging.el --- Component types the agent makes, staged for review  -*- lexical-binding: t; -*-

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

;; Agent UI's component types made by the agent: staged, then kept or
;; discarded by the user.
;;
;; The agent sends a type's code (bin/agent-ui define FILE): one
;; `agent-ui-define' and the definitions it uses, named after it.  It's
;; checked (its forms, its name: read, never evaluated) and written to
;; `agent-ui-staging-directory', where it waits for the user's review
;; (`agent-ui-review'): nothing of it is compiled, loaded or run before then,
;; as all of it is the agent's code (a defvar's value, eval-when-compile run
;; by the compiler, its drawing).  Keeping it is the user's yes: it's
;; compiled (errors refuse it), loaded, its example drawn, and its file moved
;; to `agent-ui-kept-directory', loaded at each start.  Discarding it deletes
;; it.  Either way the agent that made it is told
;; (`agent-ui-type-reviewed-functions'): kept, its example's drawing and its
;; warnings; else why.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-ui-core)
(require 'agent-ui-canvas)
(require 'bytecomp)

;; ====== VARIABLES ======

(defcustom agent-ui-staging-directory (locate-user-emacs-file "agent-ui/staged/")
  "Where the types the agent made wait for the user's review."
  :type 'directory :group 'agent-ui)

(defcustom agent-ui-kept-directory (locate-user-emacs-file "agent-ui/kept/")
  "Where the types the user kept are.
Loaded at each start (`agent-ui-load-kept')."
  :type 'directory :group 'agent-ui)

(defcustom agent-ui-staging-requires '(cl-lib subr-x seq map pcase rx svg)
  "What a type the agent made may `require'."
  :type '(repeat symbol) :group 'agent-ui)

(defvar agent-ui-staged-functions nil
  "Called with a type's name (a symbol) once the agent staged it.")

(defvar agent-ui-kept-functions nil
  "Called with a type's name and its file once the user kept it.")

(defvar agent-ui-type-reviewed-functions nil
  "Called once the user reviewed a type the agent made, to tell the agent.
Called with the type's NAME (a symbol), what to tell the agent that made
it (TEXT: kept, its example drawn and its warnings; discarded; or why it
couldn't be kept) and the canvas of the session that made it (a name, or
nil).  agent-ui-agent.el puts TEXT into that session's prompt.")

(defvar agent-ui--staged-by (make-hash-table :test #'eq)
  "The staged types' sessions: each name's, its session's canvas (a name).")

(defconst agent-ui--definers
  '(defun defsubst cl-defun defmacro defconst defvar defvar-local defface defcustom
    declare-function)
  "What a type's other forms may be: definitions, named after it.")

;; ====== WHERE TYPES ARE ======

(defun agent-ui-staged-p (name)
  "Whether the type NAME is one the agent made, waiting for the user's review."
  (file-exists-p (expand-file-name (format "%s.el" name) agent-ui-staging-directory)))

(defun agent-ui-staged-files ()
  "The staged types' files, newest first: none is loaded before it's kept."
  (when (file-directory-p agent-ui-staging-directory)
    (sort (directory-files agent-ui-staging-directory t "\\`[a-z][a-z0-9-]*\\.el\\'")
          (lambda (a b) (time-less-p (file-attribute-modification-time (file-attributes b))
                                     (file-attribute-modification-time (file-attributes a)))))))

(defun agent-ui-load-kept ()
  "Load the types the user kept (`agent-ui-kept-directory').
One that fails to load is said, the others go on."
  (when (file-directory-p agent-ui-kept-directory)
    (dolist (file (directory-files agent-ui-kept-directory t "\\`[a-z][a-z0-9-]*\\.el\\'"))
      (condition-case err
          (load file nil t)
        (error (message "Agent UI: the kept type %s doesn't load: %s"
                        (file-name-base file) (error-message-string err)))))))

;; ====== CHECKING THE CODE ======

(defun agent-ui--read-forms (code)
  "CODE's top-level forms; an error saying where it doesn't read."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (let ((read-circle nil)
          (forms nil))
      (condition-case err
          ;; Lisp's comments skipped (a plain buffer has none: a comment
          ;; after the last form was read as one, cut short).
          (with-syntax-table emacs-lisp-mode-syntax-table
            (while (progn (forward-comment (buffer-size)) (not (eobp)))
              (push (read (current-buffer)) forms)))
        (end-of-file
         (agent-ui--fail "define: the code ends inside a form (a parenthesis or quote missing?)"))
        (error (agent-ui--fail "define: the code doesn't read, at line %d: %s"
                               (line-number-at-pos) (cadr err))))
      (nreverse forms))))

(defun agent-ui--check-forms (forms)
  "The type FORMS define, its name.
An error for a form a type's code mustn't have (see `agent-ui-stage')."
  (let* ((defines (seq-filter (lambda (f) (eq (car-safe f) 'agent-ui-define)) forms))
         (name (cadr (car defines))))
    (unless (= (length defines) 1)
      (agent-ui--fail "define: the code must define one type (one agent-ui-define), not %d"
                      (length defines)))
    (unless (and (symbolp name) (string-match-p "\\`[a-z][a-z0-9-]*\\'" (symbol-name name)))
      (agent-ui--fail "define: a type's name is a symbol of a-z, 0-9 and -, not %S" name))
    (let ((prefix (format "agent-ui-%s-" name)))
      (dolist (form forms)
        (pcase form
          (`(agent-ui-define . ,_))
          (`(require ',(and feature (pred symbolp)) . ,_)
           (unless (memq feature agent-ui-staging-requires)
             (agent-ui--fail "define: a type may require only %s, not %s"
                             (mapconcat #'symbol-name agent-ui-staging-requires ", ") feature)))
          (`(,(and definer (pred (lambda (d) (memq d agent-ui--definers))))
             ,(and def (pred symbolp)) . ,_)
           (unless (or (eq definer 'declare-function)
                       (string-prefix-p prefix (symbol-name def)))
             (agent-ui--fail "define: %s is named %s: a type's definitions are named %s..., after it"
                             definer def prefix)))
          (_ (agent-ui--fail "define: only definitions belong in a type's code, not %s"
                             (truncate-string-to-width (format "%S" form) 60 nil nil "…"))))))
    name))

;; ====== COMPILING ======

(defun agent-ui--byte-compile (file &optional offset what)
  "Byte-compile FILE (nothing written, no log shown).
Its warnings, as strings, their lines OFFSET less (lines added before
the agent's code).
Signals `agent-ui-error' with its errors if it doesn't compile, led by WHAT
\(default \"define\")."
  (let* ((messages nil)
         (dest (make-temp-file "agent-ui-" nil ".elc"))
         (ok (let ((byte-compile-dest-file-function (lambda (_) dest))
                   (byte-compile-log-warning-function
                    (lambda (string position &optional _fill level)
                      (push (list (or level :warning)
                                  (format "%s%s"
                                          (if position
                                              (with-temp-buffer
                                                (insert-file-contents file)
                                                (format "line %d: " (- (line-number-at-pos
                                                                        (min (point-max) (max 1 position)))
                                                                       (or offset 0))))
                                            "")
                                          string))
                            messages)))
                   (inhibit-message t))
               (unwind-protect
                   (condition-case err
                       (byte-compile-file file)
                     (error (push (list :error (error-message-string err)) messages) nil))
                 (delete-file dest))))
         (messages (nreverse messages)))
    (unless (and ok (not (assq :error messages)))
      (agent-ui--fail "%s: it doesn't compile: %s" (or what "define")
                      (string-join (or (mapcar #'cadr (seq-filter (lambda (m) (eq (car m) :error)) messages))
                                       '("(no message)"))
                                   "; ")))
    (mapcar #'cadr messages)))

;; ====== STAGING ======

(defun agent-ui--staged-text (name code)
  "CODE, the agent's type NAME, as its file holds it: lexical binding."
  (if (string-match-p "lexical-binding: *t" (car (split-string code "\n")))
      code
    (format ";;; %s.el --- Agent UI type %s, made by the agent -*- lexical-binding: t; -*-\n%s"
            name name code)))

(defun agent-ui-stage (code &optional canvas)
  "Stage the component type CODE defines, for the user's review.
CODE is read and checked (its forms, its name), never evaluated, and
written to `agent-ui-staging-directory': nothing of it is compiled, loaded
or run until the user keeps it (`agent-ui-keep').  One staged before under
the same name is replaced.  CANVAS: the canvas of the agent's session (a
name), told once it's reviewed.  Returns (:type NAME :file FILE :status
\"waiting\" :note TEXT).  Signals `agent-ui-error' if it's refused;
then nothing of it stays."
  (let ((name (agent-ui--check-forms (agent-ui--read-forms code))))
    (when (gethash name agent-ui--types)
      (agent-ui--fail "define: %s is a type already (built in or kept): name yours otherwise" name))
    (make-directory agent-ui-staging-directory t)
    (let ((file (expand-file-name (format "%s.el" name) agent-ui-staging-directory)))
      (let ((coding-system-for-write 'utf-8))
        (write-region (agent-ui--staged-text name code) nil file nil 'silent))
      (puthash name canvas agent-ui--staged-by)
      (run-hook-with-args 'agent-ui-staged-functions name)
      (list :type (symbol-name name) :file file :status "waiting"
            :note (concat "Waiting for the user's review: nothing of it runs before they keep it. "
                          "Kept, it's compiled, loaded and its example drawn, and you're told in your prompt "
                          "(its drawing, its warnings), or why it couldn't be; discarded, you're told too. "
                          "Don't show it until then.")))))

;; ====== KEEPING, DISCARDING ======

(defun agent-ui--staged-file (name)
  "The file of the staged type NAME; an error if there is none."
  (let ((file (expand-file-name (format "%s.el" name) agent-ui-staging-directory)))
    (unless (file-exists-p file)
      (agent-ui--fail "no staged type %s" name))
    file))

(defun agent-ui--tell-reviewed (name text)
  "Tell the agent that made the type NAME what became of it: TEXT."
  (run-hook-with-args 'agent-ui-type-reviewed-functions name text (gethash name agent-ui--staged-by)))

(defun agent-ui--load-staged (name file)
  "Compile and load the staged type NAME from FILE, its example drawn.
Its code runs: the user kept it.  Returns (:warnings LIST :preview TEXT).
Signals `agent-ui-error' if it doesn't compile, defines no type NAME, has
no example or one that doesn't draw; then the type is undefined."
  (let* ((header (string-prefix-p (format ";;; %s.el --- Agent UI type %s, made by the agent" name name)
                                  (with-temp-buffer
                                    (insert-file-contents file nil 0 200)
                                    (buffer-string))))
         (warnings (agent-ui--byte-compile file (if header 1 0) "keep")))
    (condition-case err
        (progn
          (agent-ui-undefine name)
          (load file nil t t)
          (let ((type (gethash name agent-ui--types)))
            (unless type
              (agent-ui--fail "keep: loaded, it defined no type %s" name))
            (unless (agent-ui-type-example type)
              (agent-ui--fail "keep: %s has no :example (the user's preview, the agent's catalog)" name))
            (let ((preview (agent-ui-render (append (list :type (symbol-name name))
                                                    (agent-ui-type-example type))
                                            (agent-ui-context :width 80))))
              (when (eq (get-text-property (max 0 (1- (length preview))) 'face preview) 'agent-ui-error)
                (agent-ui--fail "keep: its example doesn't draw: %s" (substring-no-properties preview)))
              (list :warnings warnings :preview (substring-no-properties preview)))))
      (error (agent-ui-undefine name)
             (signal (car err) (cdr err))))))

(defun agent-ui-keep (name)
  "Keep the staged type NAME: the user's yes, its code run for the first time.
Compiled, loaded, its example drawn (`agent-ui--load-staged'), its file
moved to `agent-ui-kept-directory', loaded from there at each start.  The
agent that made it told: its example's drawing and its warnings; if it
can't be kept, why (its file left for the review, an error signalled).
Returns (:file KEPT :warnings LIST :preview TEXT)."
  (let* ((file (agent-ui--staged-file name))
         (kept (expand-file-name (format "%s.el" name) agent-ui-kept-directory))
         (loaded (condition-case err
                     (agent-ui--load-staged name file)
                   (error
                    (agent-ui--tell-reviewed
                     name (format "Agent UI: the user tried to keep your type %s, but %s. Fix it and define it again."
                                  name (agent-ui-error-message err)))
                    (signal (car err) (cdr err))))))
    (make-directory agent-ui-kept-directory t)
    (rename-file file kept t)
    (setf (agent-ui-type-file (agent-ui-type name)) kept)
    (run-hook-with-args 'agent-ui-kept-functions name kept)
    (agent-ui--tell-reviewed
     name (format "Agent UI: the user kept your type %s: it's loaded, you can show it now. Its example drawn:\n%s%s"
                  name (plist-get loaded :preview)
                  (if (plist-get loaded :warnings)
                      (concat "\nIts warnings:\n" (string-join (plist-get loaded :warnings) "\n"))
                    "")))
    (remhash name agent-ui--staged-by)
    (append (list :file kept) loaded)))

(defun agent-ui-discard (name)
  "Discard the staged type NAME: its file deleted, the agent that made it told."
  (delete-file (agent-ui--staged-file name))
  (agent-ui--tell-reviewed name (format "Agent UI: the user discarded your type %s." name))
  (remhash name agent-ui--staged-by)
  name)

(provide 'agent-ui-staging)

;;; agent-ui-staging.el ends here
