;;; magit2-reflog.el --- inspect ref history  -*- lexical-binding: t -*-

;; Copyright (C) 2010-2022  The Magit Project Contributors
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

;; This library implements support for looking at Git reflogs.

;;; Code:

(require 'magit2-core)
(require 'magit2-log)

;;; Options

(defcustom magit2-reflog-limit 256
  "Maximal number of entries initially shown in reflog buffers.
The limit in the current buffer can be changed using \"+\"
and \"-\"."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-commands
  :type 'number)

(defcustom magit2-reflog-margin
  (list (nth 0 magit2-log-margin)
        (nth 1 magit2-log-margin)
        'magit2-log-margin-width nil
        (nth 4 magit2-log-margin))
  "Format of the margin in `magit2-reflog-mode' buffers.

The value has the form (INIT STYLE WIDTH AUTHOR AUTHOR-WIDTH).

If INIT is non-nil, then the margin is shown initially.
STYLE controls how to format the author or committer date.
  It can be one of `age' (to show the age of the commit),
  `age-abbreviated' (to abbreviate the time unit to a character),
  or a string (suitable for `format-time-string') to show the
  actual date.  Option `magit2-log-margin-show-committer-date'
  controls which date is being displayed.
WIDTH controls the width of the margin.  This exists for forward
  compatibility and currently the value should not be changed.
AUTHOR controls whether the name of the author is also shown by
  default.
AUTHOR-WIDTH has to be an integer.  When the name of the author
  is shown, then this specifies how much space is used to do so."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-log
  :group 'magit2-margin
  :type magit2-log-margin--custom-type
  :initialize 'magit2-custom-initialize-reset
  :set-after '(magit2-log-margin)
  :set (apply-partially #'magit2-margin-set-variable 'magit2-reflog-mode))

;;; Faces

(defface magit2-reflog-commit '((t :foreground "green"))
  "Face for commit commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-amend '((t :foreground "magenta"))
  "Face for amend commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-merge '((t :foreground "green"))
  "Face for merge, checkout and branch commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-checkout '((t :foreground "blue"))
  "Face for checkout commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-reset '((t :foreground "red"))
  "Face for reset commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-rebase '((t :foreground "magenta"))
  "Face for rebase commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-cherry-pick '((t :foreground "green"))
  "Face for cherry-pick commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-remote '((t :foreground "cyan"))
  "Face for pull and clone commands in reflogs."
  :group 'magit2-faces)

(defface magit2-reflog-other '((t :foreground "cyan"))
  "Face for other commands in reflogs."
  :group 'magit2-faces)

;;; Commands

;;;###autoload
(defun magit2-reflog-current ()
  "Display the reflog of the current branch.
If `HEAD' is detached, then show the reflog for that instead."
  (interactive)
  (magit2-reflog-setup-buffer (or (magit2-get-current-branch) "HEAD")))

;;;###autoload
(defun magit2-reflog-other (ref)
  "Display the reflog of a branch or another ref."
  (interactive (list (magit2-read-local-branch-or-ref "Show reflog for")))
  (magit2-reflog-setup-buffer ref))

;;;###autoload
(defun magit2-reflog-head ()
  "Display the `HEAD' reflog."
  (interactive)
  (magit2-reflog-setup-buffer "HEAD"))

;;; Mode

(defvar magit2-reflog-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-log-mode-map)
    (define-key map (kbd "C-c C-n") 'undefined)
    (define-key map (kbd "L")       'magit2-margin-settings)
    map)
  "Keymap for `magit2-reflog-mode'.")

(define-derived-mode magit2-reflog-mode magit2-mode "Magit Reflog"
  "Mode for looking at Git reflog.

This mode is documented in info node `(magit2)Reflog'.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-visit-thing] or \\[magit2-diff-show-or-scroll-up] \
to visit the commit at point.

Type \\[magit2-cherry-pick] to apply the commit at point.
Type \\[magit2-reset] to reset `HEAD' to the commit at point.

\\{magit2-reflog-mode-map}"
  :group 'magit2-log
  (hack-dir-local-variables-non-file-buffer)
  (setq magit2--imenu-item-types 'commit))

(defun magit2-reflog-setup-buffer (ref)
  (require 'magit2)
  (magit2-setup-buffer #'magit2-reflog-mode nil
    (magit2-buffer-refname ref)
    (magit2-buffer-log-args (list (format "-n%s" magit2-reflog-limit)))))

(defun magit2-reflog-refresh-buffer ()
  (magit2-set-header-line-format (concat "Reflog for " magit2-buffer-refname))
  (magit2-insert-section (reflogbuf)
    (magit2-git-wash (apply-partially 'magit2-log-wash-log 'reflog)
      "reflog" "show" "--format=%h%x00%aN%x00%gd%x00%gs" "--date=raw"
      magit2-buffer-log-args magit2-buffer-refname "--")))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-reflog-mode))
  magit2-buffer-refname)

(defvar magit2-reflog-labels
  '(("commit"      . magit2-reflog-commit)
    ("amend"       . magit2-reflog-amend)
    ("merge"       . magit2-reflog-merge)
    ("checkout"    . magit2-reflog-checkout)
    ("branch"      . magit2-reflog-checkout)
    ("reset"       . magit2-reflog-reset)
    ("rebase"      . magit2-reflog-rebase)
    ("cherry-pick" . magit2-reflog-cherry-pick)
    ("initial"     . magit2-reflog-commit)
    ("pull"        . magit2-reflog-remote)
    ("clone"       . magit2-reflog-remote)
    ("autosave"    . magit2-reflog-commit)
    ("restart"     . magit2-reflog-reset)))

(defun magit2-reflog-format-subject (subject)
  (let* ((match (string-match magit2-reflog-subject-re subject))
         (command (and match (match-string 1 subject)))
         (option  (and match (match-string 2 subject)))
         (type    (and match (match-string 3 subject)))
         (label (if (string= command "commit")
                    (or type command)
                  command))
         (text (if (string= command "commit")
                   label
                 (mapconcat #'identity
                            (delq nil (list command option type))
                            " "))))
    (format "%-16s "
            (magit2--propertize-face
             text (or (cdr (assoc label magit2-reflog-labels))
                      'magit2-reflog-other)))))

;;; _
(provide 'magit2-reflog)
;;; magit2-reflog.el ends here
