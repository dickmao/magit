;;; magit2-stash.el --- stash support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2008-2022  The Magit Project Contributors
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

;; Support for Git stashes.

;;; Code:

(require 'magit2)
(require 'magit2-reflog)
(require 'magit2-sequence)

;;; Options

(defgroup magit2-stash nil
  "List stashes and show stash diffs."
  :group 'magit2-modes)

;;;; Diff options

(defcustom magit2-stash-sections-hook
  '(magit2-insert-stash-notes
    magit2-insert-stash-worktree
    magit2-insert-stash-index
    magit2-insert-stash-untracked)
  "Hook run to insert sections into stash diff buffers."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-stash
  :type 'hook)

;;;; Log options

(defcustom magit2-stashes-margin
  (list (nth 0 magit2-log-margin)
        (nth 1 magit2-log-margin)
        'magit2-log-margin-width nil
        (nth 4 magit2-log-margin))
  "Format of the margin in `magit2-stashes-mode' buffers.

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
  :group 'magit2-stash
  :group 'magit2-margin
  :type magit2-log-margin--custom-type
  :initialize 'magit2-custom-initialize-reset
  :set-after '(magit2-log-margin)
  :set (apply-partially #'magit2-margin-set-variable 'magit2-stashes-mode))

;;; Commands

;;;###autoload (autoload 'magit2-stash "magit2-stash" nil t)
(transient-define-prefix magit2-stash ()
  "Stash uncommitted changes."
  :man-page "git-stash"
  ["Arguments"
   ("-u" "Also save untracked files" ("-u" "--include-untracked"))
   ("-a" "Also save untracked and ignored files" ("-a" "--all"))]
  [["Stash"
    ("z" "both"          magit2-stash-both)
    ("i" "index"         magit2-stash-index)
    ("w" "worktree"      magit2-stash-worktree)
    ("x" "keeping index" magit2-stash-keep-index)
    ("P" "push"          magit2-stash-push :level 5)]
   ["Snapshot"
    ("Z" "both"          magit2-snapshot-both)
    ("I" "index"         magit2-snapshot-index)
    ("W" "worktree"      magit2-snapshot-worktree)
    ("r" "to wip ref"    magit2-wip-commit)]
   ["Use"
    ("a" "Apply"         magit2-stash-apply)
    ("p" "Pop"           magit2-stash-pop)
    ("k" "Drop"          magit2-stash-drop)]
   ["Inspect"
    ("l" "List"          magit2-stash-list)
    ("v" "Show"          magit2-stash-show)]
   ["Transform"
    ("b" "Branch"        magit2-stash-branch)
    ("B" "Branch here"   magit2-stash-branch-here)
    ("f" "Format patch"  magit2-stash-format-patch)]])

(defun magit2-stash-arguments ()
  (transient-args 'magit2-stash))

;;;###autoload
(defun magit2-stash-both (message &optional include-untracked)
  "Create a stash of the index and working tree.
Untracked files are included according to infix arguments.
One prefix argument is equivalent to `--include-untracked'
while two prefix arguments are equivalent to `--all'."
  (interactive
   (progn (when (and (magit2-merge-in-progress-p)
                     (not (magit2-y-or-n-p "\
Stashing and resetting during a merge conflict. \
Applying the resulting stash won't restore the merge state. \
Proceed anyway? ")))
            (user-error "Abort"))
          (magit2-stash-read-args)))
  (magit2-stash-save message t t include-untracked t))

;;;###autoload
(defun magit2-stash-index (message)
  "Create a stash of the index only.
Unstaged and untracked changes are not stashed.  The stashed
changes are applied in reverse to both the index and the
worktree.  This command can fail when the worktree is not clean.
Applying the resulting stash has the inverse effect."
  (interactive (list (magit2-stash-read-message)))
  (magit2-stash-save message t nil nil t 'worktree))

;;;###autoload
(defun magit2-stash-worktree (message &optional include-untracked)
  "Create a stash of unstaged changes in the working tree.
Untracked files are included according to infix arguments.
One prefix argument is equivalent to `--include-untracked'
while two prefix arguments are equivalent to `--all'."
  (interactive (magit2-stash-read-args))
  (magit2-stash-save message nil t include-untracked t 'index))

;;;###autoload
(defun magit2-stash-keep-index (message &optional include-untracked)
  "Create a stash of the index and working tree, keeping index intact.
Untracked files are included according to infix arguments.
One prefix argument is equivalent to `--include-untracked'
while two prefix arguments are equivalent to `--all'."
  (interactive (magit2-stash-read-args))
  (magit2-stash-save message t t include-untracked t 'index))

(defun magit2-stash-read-args ()
  (list (magit2-stash-read-message)
        (magit2-stash-read-untracked)))

(defun magit2-stash-read-untracked ()
  (let ((prefix (prefix-numeric-value current-prefix-arg))
        (args   (magit2-stash-arguments)))
    (cond ((or (= prefix 16) (member "--all" args)) 'all)
          ((or (= prefix  4) (member "--include-untracked" args)) t))))

(defun magit2-stash-read-message ()
  (let* ((default (format "On %s: "
                          (or (magit2-get-current-branch) "(no branch)")))
         (input (magit2-read-string "Stash message" default)))
    (if (equal input default)
        (concat default (magit2-rev-format "%h %s"))
      input)))

;;;###autoload
(defun magit2-snapshot-both (&optional include-untracked)
  "Create a snapshot of the index and working tree.
Untracked files are included according to infix arguments.
One prefix argument is equivalent to `--include-untracked'
while two prefix arguments are equivalent to `--all'."
  (interactive (magit2-snapshot-read-args))
  (magit2-snapshot-save t t include-untracked t))

;;;###autoload
(defun magit2-snapshot-index ()
  "Create a snapshot of the index only.
Unstaged and untracked changes are not stashed."
  (interactive)
  (magit2-snapshot-save t nil nil t))

;;;###autoload
(defun magit2-snapshot-worktree (&optional include-untracked)
  "Create a snapshot of unstaged changes in the working tree.
Untracked files are included according to infix arguments.
One prefix argument is equivalent to `--include-untracked'
while two prefix arguments are equivalent to `--all'."
  (interactive (magit2-snapshot-read-args))
  (magit2-snapshot-save nil t include-untracked t))

(defun magit2-snapshot-read-args ()
  (list (magit2-stash-read-untracked)))

(defun magit2-snapshot-save (index worktree untracked &optional refresh)
  (magit2-stash-save (concat "WIP on " (magit2-stash-summary))
                    index worktree untracked refresh t))

;;;###autoload (autoload 'magit2-stash-push "magit2-stash" nil t)
(transient-define-prefix magit2-stash-push (&optional transient args)
  "Create stash using \"git stash push\".

This differs from Magit's other stashing commands, which don't
use \"git stash\" and are generally more flexible but don't allow
specifying a list of files to be stashed."
  :man-page "git-stash"
  ["Arguments"
   (magit2:-- :reader ,(-rpartial #'magit2-read-files
                                 #'magit2-modified-files))
   ("-u" "Also save untracked files" ("-u" "--include-untracked"))
   ("-a" "Also save untracked and ignored files" ("-a" "--all"))
   ("-k" "Keep index" ("-k" "--keep-index"))
   ("-K" "Don't keep index" "--no-keep-index")]
  ["Actions"
   ("P" "push" magit2-stash-push)]
  (interactive (if (eq transient-current-command 'magit2-stash-push)
                   (list nil (transient-args 'magit2-stash-push))
                 (list t)))
  (if transient
      (transient-setup 'magit2-stash-push)
    (magit2-run-git "stash" "push" args)))

;;;###autoload
(defun magit2-stash-apply (stash)
  "Apply a stash to the working tree.
Try to preserve the stash index.  If that fails because there
are staged changes, apply without preserving the stash index."
  (interactive (list (magit2-read-stash "Apply stash")))
  (if (= (magit2-call-git "stash" "apply" "--index" stash) 0)
      (magit2-refresh)
    (magit2-run-git "stash" "apply" stash)))

;;;###autoload
(defun magit2-stash-pop (stash)
  "Apply a stash to the working tree and remove it from stash list.
Try to preserve the stash index.  If that fails because there
are staged changes, apply without preserving the stash index
and forgo removing the stash."
  (interactive (list (magit2-read-stash "Pop stash")))
  (if (= (magit2-call-git "stash" "apply" "--index" stash) 0)
      (magit2-stash-drop stash)
    (magit2-run-git "stash" "apply" stash)))

;;;###autoload
(defun magit2-stash-drop (stash)
  "Remove a stash from the stash list.
When the region is active offer to drop all contained stashes."
  (interactive
   (list (--if-let (magit2-region-values 'stash)
             (magit2-confirm 'drop-stashes nil "Drop %i stashes" nil it)
           (magit2-read-stash "Drop stash"))))
  (dolist (stash (if (listp stash)
                     (nreverse (prog1 stash (setq stash (car stash))))
                   (list stash)))
    (message "Deleted refs/%s (was %s)" stash
             (magit2-rev-parse "--short" stash))
    (magit2-call-git "rev-parse" stash)
    (magit2-call-git "stash" "drop" stash))
  (magit2-refresh))

;;;###autoload
(defun magit2-stash-clear (ref)
  "Remove all stashes saved in REF's reflog by deleting REF."
  (interactive (let ((ref (or (magit2-section-value-if 'stashes) "refs/stash")))
                 (magit2-confirm t (format "Drop all stashes in %s" ref))
                 (list ref)))
  (magit2-run-git "update-ref" "-d" ref))

;;;###autoload
(defun magit2-stash-branch (stash branch)
  "Create and checkout a new BRANCH from STASH."
  (interactive (list (magit2-read-stash "Branch stash")
                     (magit2-read-string-ns "Branch name")))
  (magit2-run-git "stash" "branch" branch stash))

;;;###autoload
(defun magit2-stash-branch-here (stash branch)
  "Create and checkout a new BRANCH and apply STASH.
The branch is created using `magit2-branch-and-checkout', using the
current branch or `HEAD' as the start-point."
  (interactive (list (magit2-read-stash "Branch stash")
                     (magit2-read-string-ns "Branch name")))
  (let ((magit2-inhibit-refresh t))
    (magit2-branch-and-checkout branch (or (magit2-get-current-branch) "HEAD")))
  (magit2-stash-apply stash))

;;;###autoload
(defun magit2-stash-format-patch (stash)
  "Create a patch from STASH"
  (interactive (list (magit2-read-stash "Create patch from stash")))
  (with-temp-file (magit2-rev-format "0001-%f.patch" stash)
    (magit2-git-insert "stash" "show" "-p" stash))
  (magit2-refresh))

;;; Plumbing

(defun magit2-stash-save (message index worktree untracked
                                 &optional refresh keep noerror ref)
  (if (or (and index     (magit2-staged-files t))
          (and worktree  (magit2-unstaged-files t))
          (and untracked (magit2-untracked-files (eq untracked 'all))))
      (magit2-with-toplevel
        (magit2-stash-store message (or ref "refs/stash")
                           (magit2-stash-create message index worktree untracked))
        (if (eq keep 'worktree)
            (with-temp-buffer
              (magit2-git-insert "diff" "--cached")
              (magit2-run-git-with-input
               "apply" "--reverse" "--cached" "--ignore-space-change" "-")
              (magit2-run-git-with-input
               "apply" "--reverse" "--ignore-space-change" "-"))
          (unless (eq keep t)
            (if (eq keep 'index)
                (magit2-call-git "checkout" "--" ".")
              (magit2-call-git "reset" "--hard" "HEAD" "--"))
            (when untracked
              (magit2-call-git "clean" "--force" "-d"
                              (and (eq untracked 'all) "-x")))))
        (when refresh
          (magit2-refresh)))
    (unless noerror
      (user-error "No %s changes to save" (cond ((not index)  "unstaged")
                                                ((not worktree) "staged")
                                                (t "local"))))))

(defun magit2-stash-store (message ref commit)
  (magit2-update-ref ref message commit t))

(defun magit2-stash-create (message index worktree untracked)
  (unless (magit2-rev-parse "--verify" "HEAD")
    (error "You do not have the initial commit yet"))
  (let ((magit2-git-global-arguments (nconc (list "-c" "commit.gpgsign=false")
                                           magit2-git-global-arguments))
        (default-directory (magit2-toplevel))
        (summary (magit2-stash-summary))
        (head "HEAD"))
    (when (and worktree (not index))
      (setq head (or (magit2-commit-tree "pre-stash index" nil "HEAD")
                     (error "Cannot save the current index state"))))
    (or (setq index (magit2-commit-tree (concat "index on " summary) nil head))
        (error "Cannot save the current index state"))
    (and untracked
         (setq untracked (magit2-untracked-files (eq untracked 'all)))
         (setq untracked (magit2-with-temp-index nil nil
                           (or (and (magit2-update-files untracked)
                                    (magit2-commit-tree
                                     (concat "untracked files on " summary)))
                               (error "Cannot save the untracked files")))))
    (magit2-with-temp-index index "-m"
      (when worktree
        (or (magit2-update-files (magit2-git-items "diff" "-z" "--name-only" head))
            (error "Cannot save the current worktree state")))
      (or (magit2-commit-tree message nil head index untracked)
          (error "Cannot save the current worktree state")))))

(defun magit2-stash-summary ()
  (concat (or (magit2-get-current-branch) "(no branch)")
          ": " (magit2-rev-format "%h %s")))

;;; Sections

(defvar magit2-stashes-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing]  'magit2-stash-list)
    (define-key map [remap magit2-delete-thing] 'magit2-stash-clear)
    map)
  "Keymap for `stashes' section.")

(defvar magit2-stash-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing]  'magit2-stash-show)
    (define-key map [remap magit2-delete-thing] 'magit2-stash-drop)
    (define-key map "a"  'magit2-stash-apply)
    (define-key map "A"  'magit2-stash-pop)
    map)
  "Keymap for `stash' sections.")

(magit2-define-section-jumper magit2-jump-to-stashes
  "Stashes" stashes "refs/stash")

(cl-defun magit2-insert-stashes (&optional (ref   "refs/stash")
                                          (heading "Stashes:"))
  "Insert `stashes' section showing reflog for \"refs/stash\".
If optional REF is non-nil, show reflog for that instead.
If optional HEADING is non-nil, use that as section heading
instead of \"Stashes:\"."
  (let ((verified (magit2-rev-parse ref))
        (autostash (magit2-rebase--get-state-lines "autostash")))
    (when (or autostash verified)
      (magit2-insert-section (stashes ref)
        (magit2-insert-heading heading)
        (when autostash
          (pcase-let ((`(,author ,date ,msg)
                       (split-string
                        (car (magit2-git-lines
                              "show" "-q" "--format=%aN%x00%at%x00%s"
                              autostash))
                        "\0")))
            (magit2-insert-section (stash autostash)
              (insert (propertize "AUTOSTASH" 'font-lock-face 'magit2-hash))
              (insert " " msg "\n")
              (save-excursion
                (backward-char)
                (magit2-log-format-margin autostash author date)))))
        (if verified
            (magit2-git-wash (apply-partially 'magit2-log-wash-log 'stash)
              "reflog" "--format=%gd%x00%aN%x00%at%x00%gs" ref)
          (insert ?\n)
          (save-excursion
            (backward-char)
            (magit2-make-margin-overlay)))))))

;;; List Stashes

;;;###autoload
(defun magit2-stash-list ()
  "List all stashes in a buffer."
  (interactive)
  (magit2-stashes-setup-buffer))

(define-derived-mode magit2-stashes-mode magit2-reflog-mode "Magit Stashes"
  "Mode for looking at lists of stashes."
  :group 'magit2-log
  (hack-dir-local-variables-non-file-buffer))

(defun magit2-stashes-setup-buffer ()
  (magit2-setup-buffer #'magit2-stashes-mode nil
    (magit2-buffer-refname "refs/stash")))

(defun magit2-stashes-refresh-buffer ()
  (magit2-insert-section (stashesbuf)
    (magit2-insert-heading (if (equal magit2-buffer-refname "refs/stash")
                              "Stashes:"
                            (format "Stashes [%s]:" magit2-buffer-refname)))
    (magit2-git-wash (apply-partially 'magit2-log-wash-log 'stash)
      "reflog" "--format=%gd%x00%aN%x00%at%x00%gs" magit2-buffer-refname)))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-stashes-mode))
  magit2-buffer-refname)

(defvar magit2--update-stash-buffer nil)

(defun magit2-stashes-maybe-update-stash-buffer (&optional _)
  "When moving in the stashes buffer, update the stash buffer.
If there is no stash buffer in the same frame, then do nothing."
  (when (derived-mode-p 'magit2-stashes-mode)
    (magit2--maybe-update-stash-buffer)))

(defun magit2--maybe-update-stash-buffer ()
  (when-let ((stash  (magit2-section-value-if 'stash))
             (buffer (magit2-get-mode-buffer 'magit2-stash-mode nil t)))
    (if magit2--update-stash-buffer
        (setq magit2--update-stash-buffer (list stash buffer))
      (setq magit2--update-stash-buffer (list stash buffer))
      (run-with-idle-timer
       magit2-update-other-window-delay nil
       (let ((args (with-current-buffer buffer
                     (let ((magit2-direct-use-buffer-arguments 'selected))
                       (magit2-show-commit--arguments)))))
         (lambda ()
           (pcase-let ((`(,stash ,buf) magit2--update-stash-buffer))
             (setq magit2--update-stash-buffer nil)
             (when (buffer-live-p buf)
               (let ((magit2-display-buffer-noselect t))
                 (apply #'magit2-stash-show stash args))))
           (setq magit2--update-stash-buffer nil)))))))

;;; Show Stash

;;;###autoload
(defun magit2-stash-show (stash &optional args files)
  "Show all diffs of a stash in a buffer."
  (interactive (cons (or (and (not current-prefix-arg)
                              (magit2-stash-at-point))
                         (magit2-read-stash "Show stash"))
                     (pcase-let ((`(,args ,files)
                                  (magit2-diff-arguments 'magit2-stash-mode)))
                       (list (delete "--stat" args) files))))
  (magit2-stash-setup-buffer stash args files))

(define-derived-mode magit2-stash-mode magit2-diff-mode "Magit Stash"
  "Mode for looking at individual stashes."
  :group 'magit2-diff
  (hack-dir-local-variables-non-file-buffer)
  (setq magit2--imenu-group-types '(commit)))

(defun magit2-stash-setup-buffer (stash args files)
  (magit2-setup-buffer #'magit2-stash-mode nil
    (magit2-buffer-revision stash)
    (magit2-buffer-range (format "%s^..%s" stash stash))
    (magit2-buffer-diff-args args)
    (magit2-buffer-diff-files files)))

(defun magit2-stash-refresh-buffer ()
  (magit2-set-header-line-format
   (concat (capitalize magit2-buffer-revision) " "
           (propertize (magit2-rev-format "%s" magit2-buffer-revision)
                       'font-lock-face
                       (list :weight 'normal :foreground
                             (face-attribute 'default :foreground)))))
  (setq magit2-buffer-revision-hash (magit2-rev-parse magit2-buffer-revision))
  (magit2-insert-section (stash)
    (magit2-run-section-hook 'magit2-stash-sections-hook)))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-stash-mode))
  magit2-buffer-revision)

(defun magit2-stash-insert-section (commit range message &optional files)
  (magit2-insert-section (commit commit)
    (magit2-insert-heading message)
    (magit2--insert-diff "diff" range "-p" "--no-prefix" magit2-buffer-diff-args
                        "--" (or files magit2-buffer-diff-files))))

(defun magit2-insert-stash-notes ()
  "Insert section showing notes for a stash.
This shows the notes for stash@{N} but not for the other commits
that make up the stash."
  (magit2-insert-section section (note)
    (magit2-insert-heading "Notes")
    (magit2-git-insert "notes" "show" magit2-buffer-revision)
    (if (= (point)
           (oref section content))
        (magit2-cancel-section)
      (insert "\n"))))

(defun magit2-insert-stash-index ()
  "Insert section showing staged changes of the stash."
  (magit2-stash-insert-section
   (format "%s^2" magit2-buffer-revision)
   (format "%s^..%s^2" magit2-buffer-revision magit2-buffer-revision)
   "Staged"))

(defun magit2-insert-stash-worktree ()
  "Insert section showing unstaged changes of the stash."
  (magit2-stash-insert-section
   magit2-buffer-revision
   (format "%s^2..%s" magit2-buffer-revision magit2-buffer-revision)
   "Unstaged"))

(defun magit2-insert-stash-untracked ()
  "Insert section showing the untracked files commit of the stash."
  (let ((stash magit2-buffer-revision)
        (rev (concat magit2-buffer-revision "^3")))
    (when (magit2-rev-parse rev)
      (magit2-stash-insert-section (format "%s^3" stash)
                                  (format "%s^..%s^3" stash stash)
                                  "Untracked files"
                                  (magit2-git-items "ls-tree" "-z" "--name-only"
                                                   "-r" "--full-tree" rev)))))

;;; _
(provide 'magit2-stash)
;;; magit2-stash.el ends here
