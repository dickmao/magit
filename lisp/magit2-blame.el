;;; magit2-blame.el --- blame support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2012-2022  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit2.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Magit is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; Annotates each line in file-visiting buffer with information from
;; the revision which last modified the line.

;;; Code:

(require 'magit2)

;;; Options

(defgroup magit2-blame nil
  "Blame support for Magit."
  :link '(info-link "(magit2)Blaming")
  :group 'magit2-modes)

(defcustom magit2-blame-styles
  '((headings
     (heading-format   . "%-20a %C %s\n"))
    (highlight
     (highlight-face   . magit2-blame-highlight))
    (lines
     (show-lines       . t)
     (show-message     . t)))
  "List of styles used to visualize blame information.

The style used in the current buffer can be cycled from the blame
popup.  Blame commands (except `magit2-blame-echo') use the first
style as the initial style when beginning to blame in a buffer.

Each entry has the form (IDENT (KEY . VALUE)...).  IDENT has
to be a symbol uniquely identifying the style.  The following
KEYs are recognized:

 `show-lines'
    Whether to prefix each chunk of lines with a thin line.
    This has no effect if `heading-format' is non-nil.
 `show-message'
    Whether to display a commit's summary line in the echo area
    when crossing chunks.
 `highlight-face'
    Face used to highlight the first line of each chunk.
    If this is nil, then those lines are not highlighted.
 `heading-format'
    String specifying the information to be shown above each
    chunk of lines.  It must end with a newline character.
 `margin-format'
    String specifying the information to be shown in the left
    buffer margin.  It must NOT end with a newline character.
    This can also be a list of formats used for the lines at
    the same positions within the chunk.  If the chunk has
    more lines than formats are specified, then the last is
    repeated.  WARNING: Adding this key affects performance;
    see the note at the end of this docstring.
 `margin-width'
    Width of the margin, provided `margin-format' is non-nil.
 `margin-face'
    Face used in the margin, provided `margin-format' is
    non-nil.  This face is used in combination with the faces
    that are specific to the used %-specs.  If this is nil,
    then `magit2-blame-margin' is used.
 `margin-body-face'
    Face used in the margin for all but first line of a chunk.
    This face is used in combination with the faces that are
    specific to the used %-specs.  This can also be a list of
    faces (usually one face), in which case only these faces
    are used and the %-spec faces are ignored.  A good value
    might be `(magit2-blame-dimmed)'.  If this is nil, then
    the same face as for the first line is used.

The following %-specs can be used in `heading-format' and
`margin-format':

  %H    hash              using face `magit2-blame-hash'
  %s    summary           using face `magit2-blame-summary'
  %a    author            using face `magit2-blame-name'
  %A    author time       using face `magit2-blame-date'
  %c    committer         using face `magit2-blame-name'
  %C    committer time    using face `magit2-blame-date'

Additionally if `margin-format' ends with %f, then the string
that is displayed in the margin is made at least `margin-width'
characters wide, which may be desirable if the used face sets
the background color.

Blame information is displayed using overlays.  Such extensive
use of overlays is known to slow down even basic operations, such
as moving the cursor. To reduce the number of overlays the margin
style had to be removed from the default value of this option.

Note that the margin overlays are created even if another style
is currently active.  This can only be prevented by not even
defining a style that uses the margin.  If you want to use this
style anyway, you can restore this definition, which used to be
part of the default value:

  (margin
   (margin-format    . (\" %s%f\" \" %C %a\" \" %H\"))
   (margin-width     . 42)
   (margin-face      . magit2-blame-margin)
   (margin-body-face . (magit2-blame-dimmed)))"
  :package-version '(magit2 . "2.13.0")
  :group 'magit2-blame
  :type 'string)

(defcustom magit2-blame-echo-style 'lines
  "The blame visualization style used by `magit2-blame-echo'.
A symbol that has to be used as the identifier for one of the
styles defined in `magit2-blame-styles'."
  :package-version '(magit2 . "2.13.0")
  :group 'magit2-blame
  :type 'symbol)

(defcustom magit2-blame-time-format "%F %H:%M"
  "Format for time strings in blame headings."
  :group 'magit2-blame
  :type 'string)

(defcustom magit2-blame-read-only t
  "Whether to initially make the blamed buffer read-only."
  :package-version '(magit2 . "2.13.0")
  :group 'magit2-blame
  :type 'boolean)

(defcustom magit2-blame-disable-modes '(fci-mode yascroll-bar-mode)
  "List of modes not compatible with Magit-Blame mode.
This modes are turned off when Magit-Blame mode is turned on,
and then turned on again when turning off the latter."
  :group 'magit2-blame
  :type '(repeat (symbol :tag "Mode")))

(defcustom magit2-blame-mode-lighter " Blame"
  "The mode-line lighter of the Magit-Blame mode."
  :group 'magit2-blame
  :type '(choice (const :tag "No lighter" "") string))

(defcustom magit2-blame-goto-chunk-hook
  '(magit2-blame-maybe-update-revision-buffer
    magit2-blame-maybe-show-message)
  "Hook run after point entered another chunk."
  :package-version '(magit2 . "2.13.0")
  :group 'magit2-blame
  :type 'hook
  :get 'magit2-hook-custom-get
  :options '(magit2-blame-maybe-update-revision-buffer
             magit2-blame-maybe-show-message))

;;; Faces

(defface magit2-blame-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey80"
     :foreground "black")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey25"
     :foreground "white"))
  "Face used for highlighting when blaming.
Also see option `magit2-blame-styles'."
  :group 'magit2-faces)

(defface magit2-blame-margin
  '((t :inherit magit2-blame-highlight
       :weight normal
       :slant normal))
  "Face used for the blame margin by default when blaming.
Also see option `magit2-blame-styles'."
  :group 'magit2-faces)

(defface magit2-blame-dimmed
  '((t :inherit magit2-dimmed
       :weight normal
       :slant normal))
  "Face used for the blame margin in some cases when blaming.
Also see option `magit2-blame-styles'."
  :group 'magit2-faces)

(defface magit2-blame-heading
  `((t ,@(and (>= emacs-major-version 27) '(:extend t))
       :inherit magit2-blame-highlight
       :weight normal
       :slant normal))
  "Face used for blame headings by default when blaming.
Also see option `magit2-blame-styles'."
  :group 'magit2-faces)

(defface magit2-blame-summary '((t nil))
  "Face used for commit summaries when blaming."
  :group 'magit2-faces)

(defface magit2-blame-hash '((t nil))
  "Face used for commit hashes when blaming."
  :group 'magit2-faces)

(defface magit2-blame-name '((t nil))
  "Face used for author and committer names when blaming."
  :group 'magit2-faces)

(defface magit2-blame-date '((t nil))
  "Face used for dates when blaming."
  :group 'magit2-faces)

;;; Chunks

(defclass magit2-blame-chunk ()
  (;; <orig-rev> <orig-line> <final-line> <num-lines>
   (orig-rev   :initarg :orig-rev)
   (orig-line  :initarg :orig-line)
   (final-line :initarg :final-line)
   (num-lines  :initarg :num-lines)
   ;; previous <prev-rev> <prev-file>
   (prev-rev   :initform nil)
   (prev-file  :initform nil)
   ;; filename <orig-file>
   (orig-file)))

(defun magit2-current-blame-chunk (&optional type noerror)
  (or (and (not (and type (not (eq type magit2-blame-type))))
           (magit2-blame-chunk-at (point)))
      (and type
           (let ((rev  (or magit2-buffer-refname magit2-buffer-revision))
                 (file (and (not (derived-mode-p 'dired-mode))
                            (magit2-file-relative-name
                             nil (not magit2-buffer-file-name))))
                 (line (format "%i,+1" (line-number-at-pos))))
             (cond (file (with-temp-buffer
                           (magit2-with-toplevel
                             (magit2-git-insert
                              "blame" "--porcelain"
                              (if (memq magit2-blame-type '(final removal))
                                  (cons "--reverse" (magit2-blame-arguments))
                                (magit2-blame-arguments))
                              "-L" line rev "--" file)
                             (goto-char (point-min))
                             (car (magit2-blame--parse-chunk type)))))
                   (noerror nil)
                   (t (error "Buffer does not visit a tracked file")))))))

(defun magit2-blame-chunk-at (pos)
  (--some (overlay-get it 'magit2-blame-chunk)
          (overlays-at pos)))

(defun magit2-blame--overlay-at (&optional pos key)
  (unless pos
    (setq pos (point)))
  (--first (overlay-get it (or key 'magit2-blame-chunk))
           (nconc (overlays-at pos)
                  (overlays-in pos pos))))

;;; Keymaps

(defvar magit2-blame-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-q") 'magit2-blame-quit)
    map)
  "Keymap for `magit2-blame-mode'.
Note that most blaming key bindings are defined
in `magit2-blame-read-only-mode-map' instead.")

(defvar magit2-blame-read-only-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-m") 'magit2-show-commit)
    (define-key map (kbd   "p") 'magit2-blame-previous-chunk)
    (define-key map (kbd   "P") 'magit2-blame-previous-chunk-same-commit)
    (define-key map (kbd   "n") 'magit2-blame-next-chunk)
    (define-key map (kbd   "N") 'magit2-blame-next-chunk-same-commit)
    (define-key map (kbd   "b") 'magit2-blame-addition)
    (define-key map (kbd   "r") 'magit2-blame-removal)
    (define-key map (kbd   "f") 'magit2-blame-reverse)
    (define-key map (kbd   "B") 'magit2-blame)
    (define-key map (kbd   "c") 'magit2-blame-cycle-style)
    (define-key map (kbd   "q") 'magit2-blame-quit)
    (define-key map (kbd "M-w") 'magit2-blame-copy-hash)
    (define-key map (kbd "SPC") 'magit2-diff-show-or-scroll-up)
    (define-key map (kbd "S-SPC") 'magit2-diff-show-or-scroll-down)
    (define-key map (kbd "DEL") 'magit2-diff-show-or-scroll-down)
    map)
  "Keymap for `magit2-blame-read-only-mode'.")

;;; Modes
;;;; Variables

(defvar-local magit2-blame-buffer-read-only nil)
(defvar-local magit2-blame-cache nil)
(defvar-local magit2-blame-disabled-modes nil)
(defvar-local magit2-blame-process nil)
(defvar-local magit2-blame-recursive-p nil)
(defvar-local magit2-blame-type nil)
(defvar-local magit2-blame-separator nil)
(defvar-local magit2-blame-previous-chunk nil)

(defvar-local magit2-blame--make-margin-overlays nil)
(defvar-local magit2-blame--style nil)

(defsubst magit2-blame--style-get (key)
  (cdr (assoc key (cdr magit2-blame--style))))

;;;; Base Mode

(define-minor-mode magit2-blame-mode
  "Display blame information inline."
  :lighter magit2-blame-mode-lighter
  (cond (magit2-blame-mode
         (when (called-interactively-p 'any)
           (setq magit2-blame-mode nil)
           (user-error
            (concat "Don't call `magit2-blame-mode' directly; "
                    "instead use `magit2-blame'")))
         (add-hook 'after-save-hook     'magit2-blame--refresh t t)
         (add-hook 'post-command-hook   'magit2-blame-goto-chunk-hook t t)
         (add-hook 'before-revert-hook  'magit2-blame--remove-overlays t t)
         (add-hook 'after-revert-hook   'magit2-blame--refresh t t)
         (add-hook 'read-only-mode-hook 'magit2-blame-toggle-read-only t t)
         (setq magit2-blame-buffer-read-only buffer-read-only)
         (when (or magit2-blame-read-only magit2-buffer-file-name)
           (read-only-mode 1))
         (dolist (mode magit2-blame-disable-modes)
           (when (and (boundp mode) (symbol-value mode))
             (funcall mode -1)
             (push mode magit2-blame-disabled-modes)))
         (setq magit2-blame-separator (magit2-blame--format-separator))
         (unless magit2-blame--style
           (setq magit2-blame--style (car magit2-blame-styles)))
         (setq magit2-blame--make-margin-overlays
               (and (cl-find-if (lambda (style)
                                  (assq 'margin-format (cdr style)))
                                magit2-blame-styles)))
         (magit2-blame--update-margin))
        (t
         (when (process-live-p magit2-blame-process)
           (kill-process magit2-blame-process)
           (while magit2-blame-process
             (sit-for 0.01))) ; avoid racing the sentinel
         (remove-hook 'after-save-hook     'magit2-blame--refresh t)
         (remove-hook 'post-command-hook   'magit2-blame-goto-chunk-hook t)
         (remove-hook 'before-revert-hook  'magit2-blame--remove-overlays t)
         (remove-hook 'after-revert-hook   'magit2-blame--refresh t)
         (remove-hook 'read-only-mode-hook 'magit2-blame-toggle-read-only t)
         (unless magit2-blame-buffer-read-only
           (read-only-mode -1))
         (magit2-blame-read-only-mode -1)
         (dolist (mode magit2-blame-disabled-modes)
           (funcall mode 1))
         (kill-local-variable 'magit2-blame-disabled-modes)
         (kill-local-variable 'magit2-blame-type)
         (kill-local-variable 'magit2-blame--style)
         (magit2-blame--update-margin)
         (magit2-blame--remove-overlays))))

(defun magit2-blame--refresh ()
  (magit2-blame--run (magit2-blame-arguments)))

(defun magit2-blame-goto-chunk-hook ()
  (let ((chunk (magit2-blame-chunk-at (point))))
    (when (cl-typep chunk 'magit2-blame-chunk)
      (unless (eq chunk magit2-blame-previous-chunk)
        (run-hooks 'magit2-blame-goto-chunk-hook))
      (setq magit2-blame-previous-chunk chunk))))

(defun magit2-blame-toggle-read-only ()
  (magit2-blame-read-only-mode (if buffer-read-only 1 -1)))

;;;; Read-Only Mode

(define-minor-mode magit2-blame-read-only-mode
  "Provide keybindings for Magit-Blame mode.

This minor-mode provides the key bindings for Magit-Blame mode,
but only when Read-Only mode is also enabled because these key
bindings would otherwise conflict badly with regular bindings.

When both Magit-Blame mode and Read-Only mode are enabled, then
this mode gets automatically enabled too and when one of these
modes is toggled, then this mode also gets toggled automatically.

\\{magit2-blame-read-only-mode-map}")

;;;; Kludges

(defun magit2-blame-put-keymap-before-view-mode ()
  "Put `magit2-blame-read-only-mode' ahead of `view-mode' in `minor-mode-map-alist'."
  (--when-let (assq 'magit2-blame-read-only-mode
                    (cl-member 'view-mode minor-mode-map-alist :key #'car))
    (setq minor-mode-map-alist
          (cons it (delq it minor-mode-map-alist))))
  (remove-hook 'view-mode-hook #'magit2-blame-put-keymap-before-view-mode))

(add-hook 'view-mode-hook #'magit2-blame-put-keymap-before-view-mode)

;;; Process

(defun magit2-blame--run (args)
  (magit2-with-toplevel
    (unless magit2-blame-mode
      (magit2-blame-mode 1))
    (message "Blaming...")
    (magit2-blame-run-process
     (or magit2-buffer-refname magit2-buffer-revision)
     (magit2-file-relative-name nil (not magit2-buffer-file-name))
     (if (memq magit2-blame-type '(final removal))
         (cons "--reverse" args)
       args)
     (list (line-number-at-pos (window-start))
           (line-number-at-pos (1- (window-end nil t)))))
    (set-process-sentinel magit2-this-process
                          'magit2-blame-process-quickstart-sentinel)))

(defun magit2-blame-run-process (revision file args &optional lines)
  (let ((process (magit2-parse-git-async
                  "blame" "--incremental" args
                  (and lines (list "-L" (apply #'format "%s,%s" lines)))
                  revision "--" file)))
    (set-process-filter   process 'magit2-blame-process-filter)
    (set-process-sentinel process 'magit2-blame-process-sentinel)
    (process-put process 'arguments (list revision file args))
    (setq magit2-blame-cache (make-hash-table :test 'equal))
    (setq magit2-blame-process process)))

(defun magit2-blame-process-quickstart-sentinel (process event)
  (when (memq (process-status process) '(exit signal))
    (magit2-blame-process-sentinel process event t)
    (magit2-blame-assert-buffer process)
    (with-current-buffer (process-get process 'command-buf)
      (when magit2-blame-mode
        (let ((default-directory (magit2-toplevel)))
          (apply #'magit2-blame-run-process
                 (process-get process 'arguments)))))))

(defun magit2-blame-process-sentinel (process _event &optional quiet)
  (let ((status (process-status process)))
    (when (memq status '(exit signal))
      (kill-buffer (process-buffer process))
      (if (and (eq status 'exit)
               (zerop (process-exit-status process)))
          (unless quiet
            (message "Blaming...done"))
        (magit2-blame-assert-buffer process)
        (with-current-buffer (process-get process 'command-buf)
          (if magit2-blame-mode
              (progn (magit2-blame-mode -1)
                     (message "Blaming...failed"))
            (message "Blaming...aborted"))))
      (kill-local-variable 'magit2-blame-process))))

(defun magit2-blame-process-filter (process string)
  (internal-default-process-filter process string)
  (let ((buf  (process-get process 'command-buf))
        (pos  (process-get process 'parsed))
        (mark (process-mark process))
        type cache)
    (with-current-buffer buf
      (setq type  magit2-blame-type)
      (setq cache magit2-blame-cache))
    (with-current-buffer (process-buffer process)
      (goto-char pos)
      (while (and (< (point) mark)
                  (save-excursion (re-search-forward "^filename .+\n" nil t)))
        (pcase-let* ((`(,chunk ,revinfo)
                      (magit2-blame--parse-chunk type))
                     (rev (oref chunk orig-rev)))
          (if revinfo
              (puthash rev revinfo cache)
            (setq revinfo
                  (or (gethash rev cache)
                      (puthash rev (magit2-blame--commit-alist rev) cache))))
          (magit2-blame--make-overlays buf chunk revinfo))
        (process-put process 'parsed (point))))))

(defun magit2-blame--parse-chunk (type)
  (let (chunk revinfo)
    (unless (looking-at "^\\(.\\{40,\\}\\) \\([0-9]+\\) \\([0-9]+\\) \\([0-9]+\\)")
      (error "Blaming failed due to unexpected output: %s"
             (buffer-substring-no-properties (point) (line-end-position))))
    (with-slots (orig-rev orig-file prev-rev prev-file)
        (setq chunk (magit2-blame-chunk
                     :orig-rev                     (match-string 1)
                     :orig-line  (string-to-number (match-string 2))
                     :final-line (string-to-number (match-string 3))
                     :num-lines  (string-to-number (match-string 4))))
      (forward-line)
      (let (done)
        (while (not done)
          (cond ((looking-at "^filename \\(.+\\)")
                 (setq done t)
                 (setf orig-file (magit2-decode-git-path (match-string 1))))
                ((looking-at "^previous \\(.\\{40,\\}\\) \\(.+\\)")
                 (setf prev-rev  (match-string 1))
                 (setf prev-file (magit2-decode-git-path (match-string 2))))
                ((looking-at "^\\([^ ]+\\) \\(.+\\)")
                 (push (cons (match-string 1)
                             (match-string 2)) revinfo)))
          (forward-line)))
      (when (and (eq type 'removal) prev-rev)
        (cl-rotatef orig-rev  prev-rev)
        (cl-rotatef orig-file prev-file)
        (setq revinfo nil)))
    (list chunk revinfo)))

(defun magit2-blame--commit-alist (rev)
  (cl-mapcar 'cons
             '("summary"
               "author" "author-time" "author-tz"
               "committer" "committer-time" "committer-tz")
             (split-string (magit2-rev-format "%s\v%an\v%ad\v%cn\v%cd" rev
                                             "--date=format:%s\v%z")
                           "\v")))

(defun magit2-blame-assert-buffer (process)
  (unless (buffer-live-p (process-get process 'command-buf))
    (kill-process process)
    (user-error "Buffer being blamed has been killed")))

;;; Display

(defun magit2-blame--make-overlays (buf chunk revinfo)
  (with-current-buffer buf
    (save-excursion
      (save-restriction
        (widen)
        (let* ((line (oref chunk final-line))
               (beg (magit2-blame--line-beginning-position line))
               (end (magit2-blame--line-beginning-position
                     (+ line (oref chunk num-lines))))
               (before (magit2-blame-chunk-at (1- beg))))
          (when (and before
                     (equal (oref before orig-rev)
                            (oref chunk orig-rev)))
            (setq beg (magit2-blame--line-beginning-position
                       (oset chunk final-line (oref before final-line))))
            (cl-incf (oref chunk num-lines)
                     (oref before num-lines)))
          (magit2-blame--remove-overlays beg end)
          (when magit2-blame--make-margin-overlays
            (magit2-blame--make-margin-overlays chunk revinfo beg end))
          (magit2-blame--make-heading-overlay chunk revinfo beg end)
          (magit2-blame--make-highlight-overlay chunk beg))))))

(defun magit2-blame--line-beginning-position (line)
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))

(defun magit2-blame--make-margin-overlays (chunk revinfo _beg end)
  (save-excursion
    (let ((line 0))
      (while (< (point) end)
        (magit2-blame--make-margin-overlay chunk revinfo line)
        (forward-line)
        (cl-incf line)))))

(defun magit2-blame--make-margin-overlay (chunk revinfo line)
  (let* ((end (line-end-position))
         ;; If possible avoid putting this on the first character
         ;; of the line to avoid a conflict with the line overlay.
         (beg (min (1+ (line-beginning-position)) end))
         (ov  (make-overlay beg end)))
    (overlay-put ov 'magit2-blame-chunk chunk)
    (overlay-put ov 'magit2-blame-revinfo revinfo)
    (overlay-put ov 'magit2-blame-margin line)
    (magit2-blame--update-margin-overlay ov)))

(defun magit2-blame--make-heading-overlay (chunk revinfo beg end)
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'magit2-blame-chunk chunk)
    (overlay-put ov 'magit2-blame-revinfo revinfo)
    (overlay-put ov 'magit2-blame-heading t)
    (magit2-blame--update-heading-overlay ov)))

(defun magit2-blame--make-highlight-overlay (chunk beg)
  (let ((ov (make-overlay beg (save-excursion
                                (goto-char beg)
                                (1+ (line-end-position))))))
    (overlay-put ov 'magit2-blame-chunk chunk)
    (overlay-put ov 'magit2-blame-highlight t)
    (magit2-blame--update-highlight-overlay ov)))

(defun magit2-blame--update-margin ()
  (setq left-margin-width (or (magit2-blame--style-get 'margin-width) 0))
  (set-window-buffer (selected-window) (current-buffer)))

(defun magit2-blame--update-overlays ()
  (save-restriction
    (widen)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (cond ((overlay-get ov 'magit2-blame-heading)
             (magit2-blame--update-heading-overlay ov))
            ((overlay-get ov 'magit2-blame-margin)
             (magit2-blame--update-margin-overlay ov))
            ((overlay-get ov 'magit2-blame-highlight)
             (magit2-blame--update-highlight-overlay ov))))))

(defun magit2-blame--update-margin-overlay (ov)
  (overlay-put
   ov 'before-string
   (and (magit2-blame--style-get 'margin-width)
        (propertize
         "o" 'display
         (list (list 'margin 'left-margin)
               (let ((line   (overlay-get ov 'magit2-blame-margin))
                     (format (magit2-blame--style-get 'margin-format))
                     (face   (magit2-blame--style-get 'margin-face)))
                 (magit2-blame--format-string
                  ov
                  (or (and (atom format)
                           format)
                      (nth line format)
                      (car (last format)))
                  (or (and (not (zerop line))
                           (magit2-blame--style-get 'margin-body-face))
                      face
                      'magit2-blame-margin))))))))

(defun magit2-blame--update-heading-overlay (ov)
  (overlay-put
   ov 'before-string
   (--if-let (magit2-blame--style-get 'heading-format)
       (magit2-blame--format-string ov it 'magit2-blame-heading)
     (and (magit2-blame--style-get 'show-lines)
          (or (not (magit2-blame--style-get 'margin-format))
              (save-excursion
                (goto-char (overlay-start ov))
                ;; Special case of the special case described in
                ;; `magit2-blame--make-margin-overlay'.  For empty
                ;; lines it is not possible to show both overlays
                ;; without the line being to high.
                (not (= (point) (line-end-position)))))
          magit2-blame-separator))))

(defun magit2-blame--update-highlight-overlay (ov)
  (overlay-put ov 'font-lock-face (magit2-blame--style-get 'highlight-face)))

(defun magit2-blame--format-string (ov format face)
  (let* ((chunk   (overlay-get ov 'magit2-blame-chunk))
         (revinfo (overlay-get ov 'magit2-blame-revinfo))
         (key     (list format face))
         (string  (cdr (assoc key revinfo))))
    (unless string
      (setq string
            (and format
                 (magit2-blame--format-string-1 (oref chunk orig-rev)
                                               revinfo format face)))
      (nconc revinfo (list (cons key string))))
    string))

(defun magit2-blame--format-string-1 (rev revinfo format face)
  (let ((str
         (if (string-match-p "\\`0\\{40,\\}\\'" rev)
             (propertize (concat (if (string-prefix-p "\s" format) "\s" "")
                                 "Not Yet Committed"
                                 (if (string-suffix-p "\n" format) "\n" ""))
                         'font-lock-face face)
           (magit2--format-spec
            (propertize format 'font-lock-face face)
            (cl-flet* ((p0 (s f)
                           (propertize s 'font-lock-face
                                       (if face
                                           (if (listp face)
                                               face
                                             (list f face))
                                         f)))
                       (p1 (k f)
                           (p0 (cdr (assoc k revinfo)) f))
                       (p2 (k1 k2 f)
                           (p0 (magit2-blame--format-time-string
                                (cdr (assoc k1 revinfo))
                                (cdr (assoc k2 revinfo)))
                               f)))
              `((?H . ,(p0 rev         'magit2-blame-hash))
                (?s . ,(p1 "summary"   'magit2-blame-summary))
                (?a . ,(p1 "author"    'magit2-blame-name))
                (?c . ,(p1 "committer" 'magit2-blame-name))
                (?A . ,(p2 "author-time"    "author-tz"    'magit2-blame-date))
                (?C . ,(p2 "committer-time" "committer-tz" 'magit2-blame-date))
                (?f . "")))))))
    (if-let ((width (and (string-suffix-p "%f" format)
                         (magit2-blame--style-get 'margin-width))))
        (concat str
                (propertize (make-string (max 0 (- width (length str))) ?\s)
                            'font-lock-face face))
      str)))

(defun magit2-blame--format-separator ()
  (propertize
   (concat (propertize "\s" 'display '(space :height (2)))
           (propertize "\n" 'line-height t))
   'font-lock-face `(:background
                     ,(face-attribute 'magit2-blame-heading
                                      :background nil t)
                     ,@(and (>= emacs-major-version 27) '(:extend t)))))

(defun magit2-blame--format-time-string (time tz)
  (let* ((time-format (or (magit2-blame--style-get 'time-format)
                          magit2-blame-time-format))
         (tz-in-second (and (string-match "%z" time-format)
                            (car (last (parse-time-string tz))))))
    (format-time-string time-format
                        (seconds-to-time (string-to-number time))
                        tz-in-second)))

(defun magit2-blame--remove-overlays (&optional beg end)
  (save-restriction
    (widen)
    (dolist (ov (overlays-in (or beg (point-min))
                             (or end (point-max))))
      (when (overlay-get ov 'magit2-blame-chunk)
        (delete-overlay ov)))))

(defun magit2-blame-maybe-show-message ()
  (when (magit2-blame--style-get 'show-message)
    (let ((message-log-max 0))
      (if-let ((msg (cdr (assoc "summary"
                                (gethash (oref (magit2-current-blame-chunk)
                                               orig-rev)
                                         magit2-blame-cache)))))
          (progn (set-text-properties 0 (length msg) nil msg)
                 (message msg))
        (message "Commit data not available yet.  Still blaming.")))))

;;; Commands

;;;###autoload (autoload 'magit2-blame-echo "magit2-blame" nil t)
(transient-define-suffix magit2-blame-echo (args)
  "For each line show the revision in which it was added.
Show the information about the chunk at point in the echo area
when moving between chunks.  Unlike other blaming commands, do
not turn on `read-only-mode'."
  :if (lambda ()
        (and buffer-file-name
             (or (not magit2-blame-mode)
                 buffer-read-only)))
  (interactive (list (magit2-blame-arguments)))
  (when magit2-buffer-file-name
    (user-error "Blob buffers aren't supported"))
  (setq-local magit2-blame--style
              (assq magit2-blame-echo-style magit2-blame-styles))
  (setq-local magit2-blame-disable-modes
              (cons 'eldoc-mode magit2-blame-disable-modes))
  (if (not magit2-blame-mode)
      (let ((magit2-blame-read-only nil))
        (magit2-blame--pre-blame-assert 'addition)
        (magit2-blame--pre-blame-setup  'addition)
        (magit2-blame--run args))
    (read-only-mode -1)
    (magit2-blame--update-overlays)))

;;;###autoload (autoload 'magit2-blame-addition "magit2-blame" nil t)
(transient-define-suffix magit2-blame-addition (args)
  "For each line show the revision in which it was added."
  (interactive (list (magit2-blame-arguments)))
  (magit2-blame--pre-blame-assert 'addition)
  (magit2-blame--pre-blame-setup  'addition)
  (magit2-blame--run args))

;;;###autoload (autoload 'magit2-blame-removal "magit2-blame" nil t)
(transient-define-suffix magit2-blame-removal (args)
  "For each line show the revision in which it was removed."
  :if-nil 'buffer-file-name
  (interactive (list (magit2-blame-arguments)))
  (unless magit2-buffer-file-name
    (user-error "Only blob buffers can be blamed in reverse"))
  (magit2-blame--pre-blame-assert 'removal)
  (magit2-blame--pre-blame-setup  'removal)
  (magit2-blame--run args))

;;;###autoload (autoload 'magit2-blame-reverse "magit2-blame" nil t)
(transient-define-suffix magit2-blame-reverse (args)
  "For each line show the last revision in which it still exists."
  :if-nil 'buffer-file-name
  (interactive (list (magit2-blame-arguments)))
  (unless magit2-buffer-file-name
    (user-error "Only blob buffers can be blamed in reverse"))
  (magit2-blame--pre-blame-assert 'final)
  (magit2-blame--pre-blame-setup  'final)
  (magit2-blame--run args))

(defun magit2-blame--pre-blame-assert (type)
  (unless (magit2-toplevel)
    (magit2--not-inside-repository-error))
  (if (and magit2-blame-mode
           (eq type magit2-blame-type))
      (if-let ((chunk (magit2-current-blame-chunk)))
          (unless (oref chunk prev-rev)
            (user-error "Chunk has no further history"))
        (user-error "Commit data not available yet.  Still blaming."))
    (unless (magit2-file-relative-name nil (not magit2-buffer-file-name))
      (if buffer-file-name
          (user-error "Buffer isn't visiting a tracked file")
        (user-error "Buffer isn't visiting a file")))))

(defun magit2-blame--pre-blame-setup (type)
  (when magit2-blame-mode
    (if (eq type magit2-blame-type)
        (let ((style magit2-blame--style))
          (magit2-blame-visit-other-file)
          (setq-local magit2-blame--style style)
          (setq-local magit2-blame-recursive-p t)
          ;; Set window-start for the benefit of quickstart.
          (redisplay))
      (magit2-blame--remove-overlays)))
  (setq magit2-blame-type type))

(defun magit2-blame-visit-other-file ()
  "Visit another blob related to the current chunk."
  (interactive)
  (with-slots (prev-rev prev-file orig-line)
      (magit2-current-blame-chunk)
    (unless prev-rev
      (user-error "Chunk has no further history"))
    (magit2-with-toplevel
      (magit2-find-file prev-rev prev-file))
    ;; TODO Adjust line like magit2-diff-visit-file.
    (goto-char (point-min))
    (forward-line (1- orig-line))))

(defun magit2-blame-visit-file ()
  "Visit the blob related to the current chunk."
  (interactive)
  (with-slots (orig-rev orig-file orig-line)
      (magit2-current-blame-chunk)
    (magit2-with-toplevel
      (magit2-find-file orig-rev orig-file))
    (goto-char (point-min))
    (forward-line (1- orig-line))))

(transient-define-suffix magit2-blame-quit ()
  "Turn off Magit-Blame mode.
If the buffer was created during a recursive blame,
then also kill the buffer."
  :if-non-nil 'magit2-blame-mode
  (interactive)
  (magit2-blame-mode -1)
  (when magit2-blame-recursive-p
    (kill-buffer)))

(defun magit2-blame-next-chunk ()
  "Move to the next chunk."
  (interactive)
  (--if-let (next-single-char-property-change (point) 'magit2-blame-chunk)
      (goto-char it)
    (user-error "No more chunks")))

(defun magit2-blame-previous-chunk ()
  "Move to the previous chunk."
  (interactive)
  (--if-let (previous-single-char-property-change (point) 'magit2-blame-chunk)
      (goto-char it)
    (user-error "No more chunks")))

(defun magit2-blame-next-chunk-same-commit (&optional previous)
  "Move to the next chunk from the same commit.\n\n(fn)"
  (interactive)
  (if-let ((rev (oref (magit2-current-blame-chunk) orig-rev)))
      (let ((pos (point)) ov)
        (save-excursion
          (while (and (not ov)
                      (not (= pos (if previous (point-min) (point-max))))
                      (setq pos (funcall
                                 (if previous
                                     'previous-single-char-property-change
                                   'next-single-char-property-change)
                                 pos 'magit2-blame-chunk)))
            (--when-let (magit2-blame--overlay-at pos)
              (when (equal (oref (magit2-blame-chunk-at pos) orig-rev) rev)
                (setq ov it)))))
        (if ov
            (goto-char (overlay-start ov))
          (user-error "No more chunks from same commit")))
    (user-error "This chunk hasn't been blamed yet")))

(defun magit2-blame-previous-chunk-same-commit ()
  "Move to the previous chunk from the same commit."
  (interactive)
  (magit2-blame-next-chunk-same-commit 'previous-single-char-property-change))

(defun magit2-blame-cycle-style ()
  "Change how blame information is visualized.
Cycle through the elements of option `magit2-blame-styles'."
  (interactive)
  (setq magit2-blame--style
        (or (cadr (cl-member (car magit2-blame--style)
                             magit2-blame-styles :key #'car))
            (car magit2-blame-styles)))
  (magit2-blame--update-margin)
  (magit2-blame--update-overlays))

(defun magit2-blame-copy-hash ()
  "Save hash of the current chunk's commit to the kill ring.

When the region is active, then save the region's content
instead of the hash, like `kill-ring-save' would."
  (interactive)
  (if (use-region-p)
      (call-interactively #'copy-region-as-kill)
    (kill-new (message "%s" (oref (magit2-current-blame-chunk) orig-rev)))))

;;; Popup

;;;###autoload (autoload 'magit2-blame "magit2-blame" nil t)
(transient-define-prefix magit2-blame ()
  "Show the commits that added or removed lines in the visited file."
  :man-page "git-blame"
  :value '("-w")
  ["Arguments"
   ("-w" "Ignore whitespace" "-w")
   ("-r" "Do not treat root commits as boundaries" "--root")
   ("-P" "Follow only first parent" "--first-parent")
   (magit2-blame:-M)
   (magit2-blame:-C)]
  ["Actions"
   ("b" "Show commits adding lines" magit2-blame-addition)
   ("r" "Show commits removing lines" magit2-blame-removal)
   ("f" "Show last commits that still have lines" magit2-blame-reverse)
   ("m" "Blame echo" magit2-blame-echo)
   ("q" "Quit blaming" magit2-blame-quit)]
  ["Refresh"
   :if-non-nil magit2-blame-mode
   ("c" "Cycle style" magit2-blame-cycle-style :transient t)])

(defun magit2-blame-arguments ()
  (transient-args 'magit2-blame))

(transient-define-argument magit2-blame:-M ()
  :description "Detect lines moved or copied within a file"
  :class 'transient-option
  :argument "-M"
  :allow-empty t
  :reader 'transient-read-number-N+)

(transient-define-argument magit2-blame:-C ()
  :description "Detect lines moved or copied between files"
  :class 'transient-option
  :argument "-C"
  :allow-empty t
  :reader 'transient-read-number-N+)

;;; Utilities

(defun magit2-blame-maybe-update-revision-buffer ()
  (when-let ((chunk  (magit2-current-blame-chunk))
             (commit (oref chunk orig-rev))
             (buffer (magit2-get-mode-buffer 'magit2-revision-mode nil t)))
    (if magit2--update-revision-buffer
        (setq magit2--update-revision-buffer (list commit buffer))
      (setq magit2--update-revision-buffer (list commit buffer))
      (run-with-idle-timer
       magit2-update-other-window-delay nil
       (lambda ()
         (pcase-let ((`(,rev ,buf) magit2--update-revision-buffer))
           (setq magit2--update-revision-buffer nil)
           (when (buffer-live-p buf)
             (let ((magit2-display-buffer-noselect t))
               (apply #'magit2-show-commit rev
                      (magit2-diff-arguments 'magit2-revision-mode))))))))))

;;; _
(provide 'magit2-blame)
;;; magit2-blame.el ends here
