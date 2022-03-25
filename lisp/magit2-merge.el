;;; magit2-merge.el --- merge functionality  -*- lexical-binding: t -*-

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

;; This library implements merge commands.

;;; Code:

(require 'magit2)
(require 'magit2-diff)

(declare-function magit2-git-push "magit2-push" (branch target args))

;;; Commands

;;;###autoload (autoload 'magit2-merge "magit2" nil t)
(transient-define-prefix magit2-merge ()
  "Merge branches."
  :man-page "git-merge"
  :incompatible '(("--ff-only" "--no-ff"))
  ["Arguments"
   :if-not magit2-merge-in-progress-p
   ("-f" "Fast-forward only" "--ff-only")
   ("-n" "No fast-forward"   "--no-ff")
   (magit2-merge:--strategy)
   (5 magit2-merge:--strategy-option)
   (5 "-b" "Ignore changes in amount of whitespace" "-Xignore-space-change")
   (5 "-w" "Ignore whitespace when comparing lines" "-Xignore-all-space")
   (5 magit2-diff:--diff-algorithm :argument "-Xdiff-algorithm=")
   (5 magit2:--gpg-sign)]
  ["Actions"
   :if-not magit2-merge-in-progress-p
   [("m" "Merge"                  magit2-merge-plain)
    ("e" "Merge and edit message" magit2-merge-editmsg)
    ("n" "Merge but don't commit" magit2-merge-nocommit)
    ("a" "Absorb"                 magit2-merge-absorb)]
   [("p" "Preview merge"          magit2-merge-preview)
    ""
    ("s" "Squash merge"           magit2-merge-squash)
    ("i" "Dissolve"               magit2-merge-into)]]
  ["Actions"
   :if magit2-merge-in-progress-p
   ("m" "Commit merge" magit2-commit-create)
   ("a" "Abort merge"  magit2-merge-abort)])

(defun magit2-merge-arguments ()
  (transient-args 'magit2-merge))

(transient-define-argument magit2-merge:--strategy ()
  :description "Strategy"
  :class 'transient-option
  ;; key for merge and rebase: "-s"
  ;; key for cherry-pick and revert: "=s"
  ;; shortarg for merge and rebase: "-s"
  ;; shortarg for cherry-pick and revert: none
  :key "-s"
  :argument "--strategy="
  :choices '("resolve" "recursive" "octopus" "ours" "subtree"))

(transient-define-argument magit2-merge:--strategy-option ()
  :description "Strategy Option"
  :class 'transient-option
  :key "-X"
  :argument "--strategy-option="
  :choices '("ours" "theirs" "patience"))

;;;###autoload
(defun magit2-merge-plain (rev &optional args nocommit)
  "Merge commit REV into the current branch; using default message.

Unless there are conflicts or a prefix argument is used create a
merge commit using a generic commit message and without letting
the user inspect the result.  With a prefix argument pretend the
merge failed to give the user the opportunity to inspect the
merge.

\(git merge --no-edit|--no-commit [ARGS] REV)"
  (interactive (list (magit2-read-other-branch-or-commit "Merge")
                     (magit2-merge-arguments)
                     current-prefix-arg))
  (magit2-merge-assert)
  (magit2-run-git-async "merge" (if nocommit "--no-commit" "--no-edit") args rev))

;;;###autoload
(defun magit2-merge-editmsg (rev &optional args)
  "Merge commit REV into the current branch; and edit message.
Perform the merge and prepare a commit message but let the user
edit it.
\n(git merge --edit --no-ff [ARGS] REV)"
  (interactive (list (magit2-read-other-branch-or-commit "Merge")
                     (magit2-merge-arguments)))
  (magit2-merge-assert)
  (cl-pushnew "--no-ff" args :test #'equal)
  (apply #'magit2-run-git-with-editor "merge" "--edit"
         (append (delete "--ff-only" args)
                 (list rev))))

;;;###autoload
(defun magit2-merge-nocommit (rev &optional args)
  "Merge commit REV into the current branch; pretending it failed.
Pretend the merge failed to give the user the opportunity to
inspect the merge and change the commit message.
\n(git merge --no-commit --no-ff [ARGS] REV)"
  (interactive (list (magit2-read-other-branch-or-commit "Merge")
                     (magit2-merge-arguments)))
  (magit2-merge-assert)
  (cl-pushnew "--no-ff" args :test #'equal)
  (magit2-run-git-async "merge" "--no-commit" args rev))

;;;###autoload
(defun magit2-merge-into (branch &optional args)
  "Merge the current branch into BRANCH and remove the former.

Before merging, force push the source branch to its push-remote,
provided the respective remote branch already exists, ensuring
that the respective pull-request (if any) won't get stuck on some
obsolete version of the commits that are being merged.  Finally
if `forge-branch-pullreq' was used to create the merged branch,
then also remove the respective remote branch."
  (interactive
   (list (magit2-read-other-local-branch
          (format "Merge `%s' into"
                  (or (magit2-get-current-branch)
                      (magit2-rev-parse "HEAD")))
          nil
          (when-let ((upstream (magit2-get-upstream-branch))
                     (upstream (cdr (magit2-split-branch-name upstream))))
            (and (magit2-branch-p upstream) upstream)))
         (magit2-merge-arguments)))
  (let ((current (magit2-get-current-branch))
        (head (magit2-rev-parse "HEAD")))
    (when (zerop (magit2-call-git "checkout" branch))
      (if current
          (magit2--merge-absorb current args)
        (magit2-run-git-with-editor "merge" args head)))))

;;;###autoload
(defun magit2-merge-absorb (branch &optional args)
  "Merge BRANCH into the current branch and remove the former.

Before merging, force push the source branch to its push-remote,
provided the respective remote branch already exists, ensuring
that the respective pull-request (if any) won't get stuck on some
obsolete version of the commits that are being merged.  Finally
if `forge-branch-pullreq' was used to create the merged branch,
then also remove the respective remote branch."
  (interactive (list (magit2-read-other-local-branch "Absorb branch")
                     (magit2-merge-arguments)))
  (magit2--merge-absorb branch args))

(defun magit2--merge-absorb (branch args)
  (when (equal branch (magit2-main-branch))
    (unless (yes-or-no-p
             (format "Do you really want to merge `%s' into another branch? "
                     branch))
      (user-error "Abort")))
  (if-let ((target (magit2-get-push-branch branch t)))
      (progn
        (magit2-git-push branch target (list "--force-with-lease"))
        (set-process-sentinel
         magit2-this-process
         (lambda (process event)
           (when (memq (process-status process) '(exit signal))
             (if (not (zerop (process-exit-status process)))
                 (magit2-process-sentinel process event)
               (process-put process 'inhibit-refresh t)
               (magit2-process-sentinel process event)
               (magit2--merge-absorb-1 branch args))))))
    (magit2--merge-absorb-1 branch args)))

(defun magit2--merge-absorb-1 (branch args)
  (if-let ((pr (magit2-get "branch" branch "pullRequest")))
      (magit2-run-git-async
       "merge" args "-m"
       (format "Merge branch '%s'%s [#%s]"
               branch
               (let ((current (magit2-get-current-branch)))
                 (if (equal current (magit2-main-branch))
                     ""
                   (format " into %s" current)))
               pr)
       branch)
    (magit2-run-git-async "merge" args "--no-edit" branch))
  (set-process-sentinel
   magit2-this-process
   (lambda (process event)
     (when (memq (process-status process) '(exit signal))
       (if (> (process-exit-status process) 0)
           (magit2-process-sentinel process event)
         (process-put process 'inhibit-refresh t)
         (magit2-process-sentinel process event)
         (magit2-branch-maybe-delete-pr-remote branch)
         (magit2-branch-unset-pushRemote branch)
         (magit2-run-git "branch" "-D" branch))))))

;;;###autoload
(defun magit2-merge-squash (rev)
  "Squash commit REV into the current branch; don't create a commit.
\n(git merge --squash REV)"
  (interactive (list (magit2-read-other-branch-or-commit "Squash")))
  (magit2-merge-assert)
  (magit2-run-git-async "merge" "--squash" rev))

;;;###autoload
(defun magit2-merge-preview (rev)
  "Preview result of merging REV into the current branch."
  (interactive (list (magit2-read-other-branch-or-commit "Preview merge")))
  (magit2-merge-preview-setup-buffer rev))

;;;###autoload
(defun magit2-merge-abort ()
  "Abort the current merge operation.
\n(git merge --abort)"
  (interactive)
  (unless (file-exists-p (magit2-git-dir "MERGE_HEAD"))
    (user-error "No merge in progress"))
  (magit2-confirm 'abort-merge)
  (magit2-run-git-async "merge" "--abort"))

(defun magit2-checkout-stage (file arg)
  "During a conflict checkout and stage side, or restore conflict."
  (interactive
   (let ((file (magit2-completing-read "Checkout file"
                                      (magit2-tracked-files) nil nil nil
                                      'magit2-read-file-hist
                                      (magit2-current-file))))
     (cond ((member file (magit2-unmerged-files))
            (list file (magit2-checkout-read-stage file)))
           ((yes-or-no-p (format "Restore conflicts in %s? " file))
            (list file "--merge"))
           (t
            (user-error "Quit")))))
  (pcase (cons arg (cddr (car (magit2-file-status file))))
    ((or `("--ours"   ?D ,_)
         `("--ours"   ?U ?A)
         `("--theirs" ,_ ?D)
         `("--theirs" ?A ?U))
     (magit2-run-git "rm" "--" file))
    (_ (if (equal arg "--merge")
           ;; This fails if the file was deleted on one
           ;; side.  And we cannot do anything about it.
           (magit2-run-git "checkout" "--merge" "--" file)
         (magit2-call-git "checkout" arg "--" file)
         (magit2-run-git "add" "-u" "--" file)))))

;;; Utilities

(defun magit2-merge-in-progress-p ()
  (file-exists-p (magit2-git-dir "MERGE_HEAD")))

(defun magit2--merge-range (&optional head)
  (unless head
    (setq head (magit2-get-shortname
                (car (magit2-file-lines (magit2-git-dir "MERGE_HEAD"))))))
  (and head
       (concat (magit2-git-string "merge-base" "--octopus" "HEAD" head)
               ".." head)))

(defun magit2-merge-assert ()
  (or (not (magit2-anything-modified-p t))
      (magit2-confirm 'merge-dirty
        "Merging with dirty worktree is risky.  Continue")))

(defun magit2-checkout-read-stage (file)
  (magit2-read-char-case (format "For %s checkout: " file) t
    (?o "[o]ur stage"   "--ours")
    (?t "[t]heir stage" "--theirs")
    (?c "[c]onflict"    "--merge")))

;;; Sections

(defvar magit2-unmerged-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-diff-dwim)
    map)
  "Keymap for `unmerged' sections.")

(defun magit2-insert-merge-log ()
  "Insert section for the on-going merge.
Display the heads that are being merged.
If no merge is in progress, do nothing."
  (when (magit2-merge-in-progress-p)
    (let* ((heads (mapcar #'magit2-get-shortname
                          (magit2-file-lines (magit2-git-dir "MERGE_HEAD"))))
           (range (magit2--merge-range (car heads))))
      (magit2-insert-section (unmerged range)
        (magit2-insert-heading
          (format "Merging %s:" (mapconcat #'identity heads ", ")))
        (magit2-insert-log
         range
         (let ((args magit2-buffer-log-args))
           (unless (member "--decorate=full" magit2-buffer-log-args)
             (push "--decorate=full" args))
           args))))))

;;; _
(provide 'magit2-merge)
;;; magit2-merge.el ends here
