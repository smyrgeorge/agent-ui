;;; agent-ui-image-tests.el --- Tests for Agent UI: the image component  -*- lexical-binding: t; -*-

;;; Commentary:

;; agent-ui-image.el: the image component, drawn as text at a width and in the
;; GUI, checked (what's wrong said), changed; its example right.

;;; Code:

(require 'agent-ui-components-test-helper)

(defconst agent-ui-test-aue-image (expand-file-name "images/splash.svg" data-directory)
  "An image every Emacs has.")

(ert-deftest agent-ui-components/image ()
  ;; In a terminal: a line naming it, a button opening it.
  (let* ((opened nil)
         (agent-ui-open-file-function (lambda (f) (setq opened f)))
         (component (list :type "image" :file agent-ui-test-aue-image :alt "Emacs's splash"))
         (text (agent-ui-render component (agent-ui-context :width 200))))
    (should (equal (substring-no-properties text)
                   (format "▣ %s  Emacs's splash" (abbreviate-file-name agent-ui-test-aue-image))))
    (funcall (get-text-property 3 'agent-ui-action text))
    (should (equal opened agent-ui-test-aue-image)))
  ;; Not there: said.
  (should (string-suffix-p "(not found)" (agent-ui-test-aue-draw '(:type "image" :file "/no/such.png"))))
  ;; In the GUI: the image, at most WIDTH percent of the pane, the alt under it.
  (let* ((text (agent-ui-render (list :type "image" :file agent-ui-test-aue-image :width 50 :alt "splash")
                                (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
         (image (get-text-property 0 'display text)))
    (should (eq (car image) 'image))
    (should (equal (plist-get (cdr image) :file) agent-ui-test-aue-image))
    (should (= (plist-get (cdr image) :max-width) 240))
    (should (= (plist-get (cdr image) :max-height) (* 20 16)))
    (should (equal (substring-no-properties text 1) "\nsplash"))
    (should (functionp (get-text-property 0 'agent-ui-action text))))
  (should (string-match-p "width is a percentage" (agent-ui-test-aue-error '(:type "image" :file "a.png" :width 0)))))

;; doom-nwj.34
(ert-deftest agent-ui-components/image-keeps-its-reason ()
  "Why an image isn't shown (not found, downloading, failed) is kept whole at
widths 30 to 80: the alt goes first, then the path or URL is cut in its
middle (cut from the right, the reason went first: \"(not fou…\")."
  (let* ((agent-ui-image-cache-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "images-") t)))
         (agent-ui-image--fetches (make-hash-table :test #'equal))
         (agent-ui-image-fetch-function #'ignore)
         (missing '(:type "image" :file "/tmp/aui-verify/some/deeper/folder/missing.png"
                    :alt "the login page after the fix"))
         (url "https://img.shields.io/badge/build-passing-green.svg")
         (failed (list :type "image" :url url :alt "the build's badge"))
         (downloading '(:type "image" :url "https://example.com/a/rather/long/path/to/the/chart.png"
                        :alt "Sales")))
    (unwind-protect
        (progn
          (puthash url (list :error "404" :time (float-time)) agent-ui-image--fetches)
          ;; In the GUI, where a URL's is downloaded (text only names it).
          (dolist (width (number-sequence 30 80))
            (dolist (case (list (cons missing "(not found)")
                                (cons failed "(couldn't download it: 404)")
                                (cons downloading "(downloading…)")))
              (let* ((text (agent-ui-test-aue-draw (car case) :width width :graphic t :char-width 8 :line-height 16))
                     (line (car (split-string text "\n"))))
                (dolist (l (split-string text "\n")) (should (<= (string-width l) width)))
                (should (string-prefix-p "▣ " line))
                ;; Whole, beside a name of 8 columns at least; else its end
                ;; (the error's words) cut, that name kept.
                (if (>= width (+ 2 8 2 (string-width (cdr case))))
                    (should (string-suffix-p (concat "  " (cdr case)) line))
                  (should (string-match-p "\\`▣ .\\{8\\}  (couldn't d[^)]*…\\'" line)))))
            ;; In text too.
            (should (string-suffix-p "  (not found)" (car (split-string (agent-ui-test-aue-draw missing :width width) "\n")))))
          ;; The path: its start and its file's name kept.
          (should (equal (agent-ui-test-aue-draw missing :width 40)
                         "▣ /tmp/aui-ver…/missing.png  (not found)\n  the login page after the fix"))
          ;; Room for all: as it was.
          (should (equal (agent-ui-test-aue-draw missing :width 120)
                         "▣ /tmp/aui-verify/some/deeper/folder/missing.png  the login page after the fix  (not found)"))
          ;; Not room for the alt beside it: under it, whole (it was cut:
          ;; "the login page a…"; doom-0ej).
          (should (equal (agent-ui-test-aue-draw missing :width 80)
                         "▣ /tmp/aui-verify/some/deeper/folder/missing.png  (not found)\n  the login page after the fix")))
      (delete-directory agent-ui-image-cache-directory t))))

;; doom-nwj.35
(ert-deftest agent-ui-components/image-alt-fits-in-the-gui ()
  "The alt under a shown image is wrapped to the width (it was one line of
78 columns at 30)."
  (let* ((alt "After the fix: the login page shows the error under the password field, in red")
         (text (agent-ui-render (list :type "image" :file agent-ui-test-aue-image :alt alt)
                                (agent-ui-context :width 30 :graphic t :char-width 8 :line-height 16)))
         (lines (cdr (split-string (substring-no-properties text) "\n"))))
    (should (eq (car (get-text-property 0 'display text)) 'image))
    (should (> (length lines) 1))
    (dolist (line lines) (should (<= (string-width line) 30)))
    ;; All its words, in their order.
    (should (equal (string-join lines " ") alt))
    (should (eq (get-text-property (1+ (string-search "\n" text)) 'face text) 'agent-ui-muted))))

;; doom-nwj.36
(ert-deftest agent-ui-components/image-known-by-its-bytes ()
  "In the GUI an image's type is known by its first bytes: a PNG without an
extension is shown (it was refused, by its name); a text file named .png
isn't an image."
  (let* ((dir (make-temp-file (agent-ui-test-tmp-file "images-") t))
         (png (expand-file-name "shot" dir))
         (fake (expand-file-name "fake.png" dir))
         (ctx (agent-ui-context :width 60 :graphic t :char-width 8 :line-height 16)))
    (unwind-protect
        (progn
          (copy-file (expand-file-name "images/splash.png" data-directory) png)
          (with-temp-file fake (insert "hello, not a picture\n"))
          (let ((image (get-text-property 0 'display (agent-ui-render (list :type "image" :file png) ctx))))
            (should (eq (car image) 'image))
            (should (eq (plist-get (cdr image) :type) 'png))
            (should (equal (plist-get (cdr image) :file) png)))
          (should (string-suffix-p "(not an image Emacs shows)"
                                   (substring-no-properties (agent-ui-render (list :type "image" :file fake) ctx))))
          ;; An SVG by its name too (its <svg can come late), and as before.
          (let ((image (get-text-property 0 'display (agent-ui-render (list :type "image" :file agent-ui-test-aue-image) ctx))))
            (should (eq (plist-get (cdr image) :type) 'svg))))
      (delete-directory dir t))))

;; doom-nwj.37
(ert-deftest agent-ui-components/image-as-text-downloads-nothing ()
  "Drawn as text (a terminal, `agent-ui render'), an image from a URL is
named, not downloaded: text never shows it (it was fetched, and said
\"(downloading…)\")."
  (let* ((agent-ui-image-cache-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "images-") t)))
         (agent-ui-image--fetches (make-hash-table :test #'equal))
         (fetches nil)
         (agent-ui-image-fetch-function (lambda (url _file _callback) (push url fetches)))
         (component '(:type "image" :url "https://example.com/a.png" :alt "a chart")))
    (unwind-protect
        (progn
          (should (equal (agent-ui-test-aue-draw component) "▣ https://example.com/a.png  a chart"))
          (should (equal (agent-ui-test-aue-draw component :width 20) "▣ https://e…om/a.png\n  a chart"))
          (should-not fetches)
          (should (= (hash-table-count agent-ui-image--fetches) 0))
          ;; Its button opens the URL.
          (let ((opened nil))
            (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
              (funcall (get-text-property 3 'agent-ui-action
                                          (agent-ui-render component (agent-ui-context :width 60)))))
            (should (equal opened "https://example.com/a.png")))
          ;; In the GUI: downloaded.
          (agent-ui-test-aue-draw component :graphic t :char-width 8 :line-height 16)
          (should (equal fetches '("https://example.com/a.png"))))
      (delete-directory agent-ui-image-cache-directory t))))

(ert-deftest agent-ui-components/image-its-url-as-it-is ()
  "curl takes an image's URL as it is: its [] and {} no ranges, nothing in
it an option (doom-ht6.71)."
  (let ((command nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/curl"))
              ((symbol-function 'make-process) (lambda (&rest args) (setq command (plist-get args :command)) nil)))
      (agent-ui-image-curl "https://example.com/a[1-3].png?f{x,y}" "/tmp/out.part" #'ignore))
    (should (member "--globoff" command))
    (should (equal (last command 2) '("--" "https://example.com/a[1-3].png?f{x,y}")))))

(ert-deftest agent-ui-components/image-from-a-url ()
  (let* ((agent-ui-image-cache-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "images-") t)))
         (agent-ui-image--fetches (make-hash-table :test #'equal))
         (fetches nil) (done nil)
         (agent-ui-image-fetch-function (lambda (url file callback) (push url fetches) (setq done (list file callback))))
         (component '(:type "image" :url "https://example.com/chart?x=1" :alt "Sales"))
         ;; Downloaded to be shown: in the GUI (text only names it).
         (gui '(:graphic t :char-width 8 :line-height 16)))
    (unwind-protect
        (progn
          ;; Not there yet: downloading, said; started once.
          (should (string-match-p "▣ https://example.com/chart\\?x=1  Sales  (downloading…)"
                                  (apply #'agent-ui-test-aue-draw component gui)))
          (apply #'agent-ui-test-aue-draw component gui)
          (should (equal fetches '("https://example.com/chart?x=1")))
          ;; Its download still going (its .part there): not the image
          ;; (doom-ht6.55).
          (with-temp-file (car done) (set-buffer-multibyte nil) (insert "\211PNG"))
          (should-not (agent-ui-image--cached "https://example.com/chart?x=1"))
          ;; Done: kept by its hash, its extension its type's; shown as a file.
          ;; (A PNG's signature: its type known by it.)
          (with-temp-file (car done) (set-buffer-multibyte nil) (insert "\211PNG\r\n\032\n"))
          (funcall (cadr done) nil)
          (should (equal (agent-ui-image--cached "https://example.com/chart?x=1")
                         (concat agent-ui-image-cache-directory (sha1 "https://example.com/chart?x=1") ".png")))
          (should (equal (agent-ui-test-aue-draw component) "▣ https://example.com/chart?x=1  Sales"))
          (should (eq (car (get-text-property
                            0 'display (agent-ui-render component (apply #'agent-ui-context :width 60 gui))))
                      'image))
          ;; Not downloaded again.
          (apply #'agent-ui-test-aue-draw component gui)
          (should (= (length fetches) 1))
          ;; Failed: said in its place; not an image, too.
          (let ((bad '(:type "image" :url "https://example.com/404.png")))
            (apply #'agent-ui-test-aue-draw bad gui)
            (funcall (cadr done) "The requested URL returned error: 404")
            (should (string-match-p "(couldn't download it: The requested URL returned error: 404)"
                                    (apply #'agent-ui-test-aue-draw bad :width 120 gui)))
            (should (eq (apply #'agent-ui-test-aue-face-at bad "(couldn't" gui) 'agent-ui-error))
            ;; Shown again, within 30 seconds: not tried again; later: tried.
            (agent-ui--prepared bad)
            (apply #'agent-ui-test-aue-draw bad gui)
            (should (= (length fetches) 2))
            (puthash "https://example.com/404.png" (list :error "x" :time 0) agent-ui-image--fetches)
            (agent-ui--prepared bad)
            (apply #'agent-ui-test-aue-draw bad gui)
            (should (= (length fetches) 3)))
          (let ((page '(:type "image" :url "https://example.com/page")))
            (apply #'agent-ui-test-aue-draw page gui)
            (with-temp-file (car done) (insert "<html>nope</html>"))
            (funcall (cadr done) nil)
            (should (string-match-p "(couldn't download it: not an image)" (apply #'agent-ui-test-aue-draw page :width 120 gui)))
            (should-not (file-exists-p (car done)))))
      (delete-directory agent-ui-image-cache-directory t)))
  ;; File or url, one; an http(s) url.
  (should (string-match-p "give file or url, one of them" (agent-ui-test-aue-error '(:type "image"))))
  (should (string-match-p "give file or url" (agent-ui-test-aue-error '(:type "image" :file "a.png" :url "https://x/a.png"))))
  (should (string-match-p "url is an http(s) address, not \"file:///a.png\""
                          (agent-ui-test-aue-error '(:type "image" :url "file:///a.png")))))

;; doom-ht6.115
(ert-deftest agent-ui-components/image-downloaded-redraws-its-own ()
  "A download done: only the components showing its URL (a panel's child,
a compare's option too) marked to be drawn again, through the redraw timer; not every
component of every canvas, at once."
  (let* ((agent-ui-image-cache-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "images-") t)))
         (agent-ui-image--fetches (make-hash-table :test #'equal))
         (done nil) (redraws 0)
         (agent-ui-image-fetch-function (lambda (_url file callback) (setq done (list file callback))))
         (url "https://example.com/a.png")
         (other (make-temp-name "image-other-")))
    (agent-ui-test-aue-canvas
      (unwind-protect
          (progn
            (agent-ui-show (list :id "img" :type "image" :url url))
            (agent-ui-show (list :id "p" :type "panel" :children (list (list :id "c" :type "image" :url url))))
            (agent-ui-show (list :id "q" :type "compare" :question "Which?"
                                 :options (list (list :label "A" :component (list :type "image" :url url))
                                                '(:label "B" :component (:type "text" :text "b")))))
            (agent-ui-show '(:id "else" :type "image" :url "https://example.com/b.png"))
            (agent-ui-show '(:id "t" :type "text" :text "y") :canvas other)
            (dolist (buffer (agent-ui-canvases))
              (with-current-buffer buffer (agent-ui--flush)))
            (agent-ui-image--fetch url)
            (with-temp-file (car done) (set-buffer-multibyte nil) (insert "\211PNG\r\n\032\n"))
            (cl-letf (((symbol-function 'agent-ui-canvas-redraw) (lambda (&rest _) (cl-incf redraws))))
              (funcall (cadr done) nil))
            (should (= redraws 0))
            (with-current-buffer canvas
              (should (equal (sort (copy-sequence agent-ui--dirty) #'string<) '("img" "p" "q"))))
            (with-current-buffer (agent-ui--buffer other)
              (should-not agent-ui--dirty)))
        (kill-buffer (agent-ui--buffer other))
        (delete-directory agent-ui-image-cache-directory t)))))

(ert-deftest agent-ui-components/image-no-curl-no-orphan ()
  "Without curl, an image from a URL drawn in a canvas: its text there once.
Its download's end handled after the drawing, not inside it (the canvas
redrawn inside it, a drawing inside a drawing, could leave a copy of it
behind)."
  (let* ((agent-ui-image-cache-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "images-") t)))
         (agent-ui-image--fetches (make-hash-table :test #'equal))
         (agent-ui-image-fetch-function #'agent-ui-image-curl)
         (executable-find (symbol-function 'executable-find))
         (depth 0) (deepest 0)
         (nest (lambda (draw &rest args)
                 (setq deepest (max deepest (cl-incf depth)))
                 (unwind-protect (apply draw args) (cl-decf depth)))))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (command &rest args) (unless (equal command "curl") (apply executable-find command args))))
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (agent-ui-test-aue-canvas
        (unwind-protect
            (progn
              (advice-add 'agent-ui--draw-here :around nest)
              (agent-ui-show '(:id "img" :type "image" :url "https://example.com/c.png" :alt "the chart"))
              (with-current-buffer canvas
                (agent-ui--flush)
                (agent-ui-test-timers-run)
                (agent-ui--flush)
                (should (= deepest 1))
                (should (= (how-many "the chart" (point-min) (point-max)) 1))
                (should (string-match-p "curl isn't installed" (buffer-string)))))
          (advice-remove 'agent-ui--draw-here nest)
          (delete-directory agent-ui-image-cache-directory t))))))

(ert-deftest agent-ui-components/image-cached-remembered ()
  "A URL's image file looked for in the cache directory once, then
remembered; looked for again once it's gone."
  (let* ((agent-ui-image-cache-directory (file-name-as-directory (make-temp-file (agent-ui-test-tmp-file "images-") t)))
         (url "https://example.com/d.png")
         (file (concat agent-ui-image-cache-directory (sha1 url) ".png"))
         (listed 0))
    (unwind-protect
        (progn
          (with-temp-file file (insert "x"))
          (advice-add 'directory-files :before (lambda (&rest _) (cl-incf listed)) '((name . count)))
          (dotimes (_ 3)
            (should (equal (agent-ui-image--cached url) file)))
          (should (= listed 1))
          (delete-file file)
          (should-not (agent-ui-image--cached url)))
      (advice-remove 'directory-files 'count)
      (delete-directory agent-ui-image-cache-directory t))))

;;; agent-ui-image-tests.el ends here
