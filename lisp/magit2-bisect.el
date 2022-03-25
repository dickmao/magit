;;; magit2-bisect.el --- bisect support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2011-2022  The Magit Project Contributors
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

;; Use a binary search to find the commit that introduced a bug.

;;; Code:

(require 'magit2)

;;; Options

(defcustom magit2-bisect-show-graph t
  "Whether to use `--graph' in the log showing commits yet to be bisected."
  :package-version '(magit2 . "2.8.0")
  :group 'magit2-status
  :type 'boolean)

(defface magit2-bisect-good
  '((t :foreground "DarkOliveGreen"))
  "Face for good bisect revisions."
  :group 'magit2-faces)

(defface magit2-bisect-skip
  '((t :foreground "DarkGoldenrod"))
  "Face for skipped bisect revisions."
  :group 'magit2-faces)

(defface magit2-bisect-bad
  '((t :foreground "IndianRed4"))
  "Face for bad bisect revisions."
  :group 'magit2-faces)

;;; Commands

;;;###autoload (autoload 'magit2-bisect "magit2-bisect" nil t)
(transient-define-prefix magit2-bisect ()
  "Narrow in on the commit that introduced a bug."
  :man-page "git-bisect"
  [:class transient-subgroups
   :if-not magit2-bisect-in-progress-p
   ["Arguments"
    ("-n" "Don't checkout commits"              "--no-checkout")
    ("-p" "Follow only first parent of a merge" "--first-parent"
     :if (lambda () (magit2-git-version>= "2.29")))
    (6 magit2-bisect:--term-old
       :if (lambda () (magit2-git-version>= "2.7")))
    (6 magit2-bisect:--term-new
       :if (lambda () (magit2-git-version>= "2.7")))]
   ["Actions"
    ("B" "Start"        magit2-bisect-start)
    ("s" "Start script" magit2-bisect-run)]]
  ["Actions"
   :if magit2-bisect-in-progress-p
   ("B" "Bad"          magit2-bisect-bad)
   ("g" "Good"         magit2-bisect-good)
   (6 "m" "Mark"       magit2-bisect-mark
      :if (lambda () (magit2-git-version>= "2.7")))
   ("k" "Skip"         magit2-bisect-skip)
   ("r" "Reset"        magit2-bisect-reset)
   ("s" "Run script"   magit2-bisect-run)])

(transient-define-argument magit2-bisect:--term-old ()
  :description "Old/good term"
  :class 'transient-option
  :key "=o"
  :argument "--term-old=")

(transient-define-argument magit2-bisect:--term-new ()
  :description "New/bad term"
  :class 'transient-option
  :key "=n"
  :argument "--term-new=")

;;;###autoload
(defun magit2-bisect-start (bad good args)
  "Start a bisect session.

Bisecting a bug means to find the commit that introduced it.
This command starts such a bisect session by asking for a known
good and a known bad commit.  To move the session forward use the
other actions from the bisect transient command (\
\\<magit2-status-mode-map>\\[magit2-bisect])."
  (interactive (if (magit2-bisect-in-progress-p)
                   (user-error "Already bisecting")
                 (magit2-bisect-start-read-args)))
  (unless (magit2-rev-ancestor-p good bad)
    (user-error
     "The %s revision (%s) has to be an ancestor of the %s one (%s)"
     (or (transient-arg-value "--term-old=" args) "good")
     good
     (or (transient-arg-value "--term-new=" args) "bad")
     bad))
  (when (magit2-anything-modified-p)
    (user-error "Cannot bisect with uncommitted changes"))
  (magit2-git-bisect "start" (list args bad good) t))

(defun magit2-bisect-start-read-args ()
  (let* ((args (transient-args 'magit2-bisect))
         (bad (magit2-read-branch-or-commit
               (format "Start bisect with %s revision"
                       (or (transient-arg-value "--term-new=" args)
                           "bad")))))
    (list bad
          (magit2-read-other-branch-or-commit
           (format "%s revision" (or (transient-arg-value "--term-old=" args)
                                     "Good"))
           bad)
          args)))

;;;###autoload
(defun magit2-bisect-reset ()
  "After bisecting, cleanup bisection state and return to original `HEAD'."
  (interactive)
  (magit2-confirm 'reset-bisect)
  (magit2-run-git "bisect" "reset")
  (ignore-errors (delete-file (magit2-git-dir "BISECT_CMD_OUTPUT"))))

;;;###autoload
(defun magit2-bisect-good ()
  "While bisecting, mark the current commit as good.
Use this after you have asserted that the commit does not contain
the bug in question."
  (interactive)
  (magit2-git-bisect (or (cadr (magit2-bisect-terms))
                        (user-error "Not bisecting"))))

;;;###autoload
(defun magit2-bisect-bad ()
  "While bisecting, mark the current commit as bad.
Use this after you have asserted that the commit does contain the
bug in question."
  (interactive)
  (magit2-git-bisect (or (car (magit2-bisect-terms))
                        (user-error "Not bisecting"))))

;;;###autoload
(defun magit2-bisect-mark ()
  "While bisecting, mark the current commit with a bisect term.
During a bisect using alternate terms, commits can still be
marked with `magit2-bisect-good' and `magit2-bisect-bad', as those
commands map to the correct term (\"good\" to --term-old's value
and \"bad\" to --term-new's).  However, in some cases, it can be
difficult to keep that mapping straight in your head; this
command provides an interface that exposes the underlying terms."
  (interactive)
  (magit2-git-bisect
   (pcase-let ((`(,term-new ,term-old) (or (magit2-bisect-terms)
                                           (user-error "Not bisecting"))))
     (pcase (read-char-choice
             (format "Mark HEAD as %s ([n]ew) or %s ([o]ld)"
                     term-new term-old)
             (list ?n ?o))
       (?n term-new)
       (?o term-old)))))

;;;###autoload
(defun magit2-bisect-skip ()
  "While bisecting, skip the current commit.
Use this if for some reason the current commit is not a good one
to test.  This command lets Git choose a different one."
  (interactive)
  (magit2-git-bisect "skip"))

;;;###autoload
(defun magit2-bisect-run (cmdline &optional bad good args)
  "Bisect automatically by running commands after each step.

Unlike `git bisect run' this can be used before bisecting has
begun.  In that case it behaves like `git bisect start; git
bisect run'."
  (interactive (let ((args (and (not (magit2-bisect-in-progress-p))
                                (magit2-bisect-start-read-args))))
                 (cons (read-shell-command "Bisect shell command: ") args)))
  (when (and bad good)
    ;; Avoid `magit2-git-bisect' because it's asynchronous, but the
    ;; next `git bisect run' call requires the bisect to be started.
    (magit2-with-toplevel
      (magit2-process-git
       (list :file (magit2-git-dir "BISECT_CMD_OUTPUT"))
       (magit2-process-git-arguments
        (list "bisect" "start" bad good args)))
      (magit2-refresh)))
  (magit2--with-connection-local-variables
   (magit2-git-bisect "run" (list shell-file-name
                                 shell-command-switch cmdline))))

(defun magit2-git-bisect (subcommand &optional args no-assert)
  (unless (or no-assert (magit2-bisect-in-progress-p))
    (user-error "Not bisecting"))
  (message "Bisecting...")
  (magit2-with-toplevel
    (magit2-run-git-async "bisect" subcommand args))
  (set-process-sentinel
   magit2-this-process
   (lambda (process event)
     (when (memq (process-status process) '(exit signal))
       (if (> (process-exit-status process) 0)
           (magit2-process-sentinel process event)
         (process-put process 'inhibit-refresh t)
         (magit2-process-sentinel process event)
         (when (buffer-live-p (process-buffer process))
           (with-current-buffer (process-buffer process)
             (when-let ((section (get-text-property (point) 'magit2-section))
                        (output (buffer-substring-no-properties
                                 (oref section content)
                                 (oref section end))))
               (with-temp-file (magit2-git-dir "BISECT_CMD_OUTPUT")
                 (insert output)))))
         (magit2-refresh))
       (message "Bisecting...done")))))

;;; Sections

(defun magit2-bisect-in-progress-p ()
  (file-exists-p (magit2-git-dir "BISECT_LOG")))

(defun magit2-bisect-terms ()
  (magit2-file-lines (magit2-git-dir "BISECT_TERMS")))

(defun magit2-insert-bisect-output ()
  "While bisecting, insert section with output from `git bisect'."
  (when (magit2-bisect-in-progress-p)
    (let* ((lines
            (or (magit2-file-lines (magit2-git-dir "BISECT_CMD_OUTPUT"))
                (list "Bisecting: (no saved bisect output)"
                      "It appears you have invoked `git bisect' from a shell."
                      "There is nothing wrong with that, we just cannot display"
                      "anything useful here.  Consult the shell output instead.")))
           (done-re "^\\([a-z0-9]\\{40,\\}\\) is the first bad commit$")
           (bad-line (or (and (string-match done-re (car lines))
                              (pop lines))
                         (--first (string-match done-re it) lines))))
      (magit2-insert-section ((eval (if bad-line 'commit 'bisect-output))
                             (and bad-line (match-string 1 bad-line)))
        (magit2-insert-heading
          (propertize (or bad-line (pop lines))
                      'font-lock-face 'magit2-section-heading))
        (dolist (line lines)
          (insert line "\n"))))
    (insert "\n")))

(defun magit2-insert-bisect-rest ()
  "While bisecting, insert section visualizing the bisect state."
  (when (magit2-bisect-in-progress-p)
    (magit2-insert-section (bisect-view)
      (magit2-insert-heading "Bisect Rest:")
      (magit2-git-wash (apply-partially 'magit2-log-wash-log 'bisect-vis)
        "bisect" "visualize" "git" "log"
        "--format=%h%x00%D%x00%s" "--decorate=full"
        (and magit2-bisect-show-graph "--graph")))))

(defun magit2-insert-bisect-log ()
  "While bisecting, insert section logging bisect progress."
  (when (magit2-bisect-in-progress-p)
    (magit2-insert-section (bisect-log)
      (magit2-insert-heading "Bisect Log:")
      (magit2-git-wash #'magit2-wash-bisect-log "bisect" "log")
      (insert ?\n))))

(defun magit2-wash-bisect-log (_args)
  (let (beg)
    (while (progn (setq beg (point-marker))
                  (re-search-forward "^\\(git bisect [^\n]+\n\\)" nil t))
      (magit2-bind-match-strings (heading) nil
        (magit2-delete-match)
        (save-restriction
          (narrow-to-region beg (point))
          (goto-char (point-min))
          (magit2-insert-section (bisect-item heading t)
            (insert (propertize heading 'font-lock-face
                                'magit2-section-secondary-heading))
            (magit2-insert-heading)
            (magit2-wash-sequence
             (apply-partially 'magit2-log-wash-rev 'bisect-log
                              (magit2-abbrev-length)))
            (insert ?\n)))))
    (when (re-search-forward
           "# first bad commit: \\[\\([a-z0-9]\\{40,\\}\\)\\] [^\n]+\n" nil t)
      (magit2-bind-match-strings (hash) nil
        (magit2-delete-match)
        (magit2-insert-section (bisect-item)
          (insert hash " is the first bad commit\n"))))))

;;; _
(provide 'magit2-bisect)
;;; magit2-bisect.el ends here
