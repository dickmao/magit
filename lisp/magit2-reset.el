;;; magit2-reset.el --- reset fuctionality  -*- lexical-binding: t -*-

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

;; This library implements reset commands.

;;; Code:

(require 'magit2)

;;;###autoload (autoload 'magit2-reset "magit2" nil t)
(transient-define-prefix magit2-reset ()
  "Reset the `HEAD', index and/or worktree to a previous state."
  :man-page "git-reset"
  ["Reset"
   ("m" "mixed    (HEAD and index)"        magit2-reset-mixed)
   ("s" "soft     (HEAD only)"             magit2-reset-soft)
   ("h" "hard     (HEAD, index and files)" magit2-reset-hard)
   ("k" "keep     (HEAD and index, keeping uncommitted)" magit2-reset-keep)
   ("i" "index    (only)"                  magit2-reset-index)
   ("w" "worktree (only)"                  magit2-reset-worktree)
   ""
   ("f" "a file"                           magit2-file-checkout)])

;;;###autoload
(defun magit2-reset-mixed (commit)
  "Reset the `HEAD' and index to COMMIT, but not the working tree.
\n(git reset --mixed COMMIT)"
  (interactive (list (magit2-reset-read-branch-or-commit "Reset %s to")))
  (magit2-reset-internal "--mixed" commit))

;;;###autoload
(defun magit2-reset-soft (commit)
  "Reset the `HEAD' to COMMIT, but not the index and working tree.
\n(git reset --soft REVISION)"
  (interactive (list (magit2-reset-read-branch-or-commit "Soft reset %s to")))
  (magit2-reset-internal "--soft" commit))

;;;###autoload
(defun magit2-reset-hard (commit)
  "Reset the `HEAD', index, and working tree to COMMIT.
\n(git reset --hard REVISION)"
  (interactive (list (magit2-reset-read-branch-or-commit
                      (concat (magit2--propertize-face "Hard" 'bold)
                              " reset %s to"))))
  (magit2-reset-internal "--hard" commit))

;;;###autoload
(defun magit2-reset-keep (commit)
  "Reset the `HEAD' and index to COMMIT, while keeping uncommitted changes.
\n(git reset --keep REVISION)"
  (interactive (list (magit2-reset-read-branch-or-commit "Reset %s to")))
  (magit2-reset-internal "--keep" commit))

;;;###autoload
(defun magit2-reset-index (commit)
  "Reset the index to COMMIT.
Keep the `HEAD' and working tree as-is, so if COMMIT refers to the
head this effectively unstages all changes.
\n(git reset COMMIT .)"
  (interactive (list (magit2-read-branch-or-commit "Reset index to")))
  (magit2-reset-internal nil commit "."))

;;;###autoload
(defun magit2-reset-worktree (commit)
  "Reset the worktree to COMMIT.
Keep the `HEAD' and index as-is."
  (interactive (list (magit2-read-branch-or-commit "Reset worktree to")))
  (magit2-wip-commit-before-change nil " before reset")
  (magit2-with-temp-index commit nil
    (magit2-call-git "checkout-index" "--all" "--force"))
  (magit2-wip-commit-after-apply nil " after reset")
  (magit2-refresh))

;;;###autoload
(defun magit2-reset-quickly (commit &optional hard)
  "Reset the `HEAD' and index to COMMIT, and possibly the working tree.
With a prefix argument reset the working tree otherwise don't.
\n(git reset --mixed|--hard COMMIT)"
  (interactive (list (magit2-reset-read-branch-or-commit
                      (if current-prefix-arg
                          (concat (magit2--propertize-face "Hard" 'bold)
                                  " reset %s to")
                        "Reset %s to"))
                     current-prefix-arg))
  (magit2-reset-internal (if hard "--hard" "--mixed") commit))

(defun magit2-reset-read-branch-or-commit (prompt)
  "Prompt for and return a ref to reset HEAD to.

PROMPT is a format string, where either the current branch name
or \"detached head\" will be substituted for %s."
  (magit2-read-branch-or-commit
   (format prompt (or (magit2-get-current-branch) "detached head"))))

(defun magit2-reset-internal (arg commit &optional path)
  (when (and (not (member arg '("--hard" nil)))
             (equal (magit2-rev-parse commit)
                    (magit2-rev-parse "HEAD~")))
    (with-temp-buffer
      (magit2-git-insert "show" "-s" "--format=%B" "HEAD")
      (when git-commit-major-mode
        (funcall git-commit-major-mode))
      (git-commit-setup-font-lock)
      (git-commit-save-message)))
  (let ((cmd (if (and (equal commit "HEAD") (not arg)) "unstage" "reset")))
    (magit2-wip-commit-before-change nil (concat " before " cmd))
    (magit2-run-git "reset" arg commit "--" path)
    (when (equal cmd "unstage")
      (magit2-wip-commit-after-apply nil " after unstage"))))

;;; _
(provide 'magit2-reset)
;;; magit2-reset.el ends here
