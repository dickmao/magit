;;; magit2-wip.el --- commit snapshots to work-in-progress refs  -*- lexical-binding: t -*-

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

;; This library defines tree global modes which automatically commit
;; snapshots to branch-specific work-in-progress refs before and after
;; making changes, and two commands which can be used to do so on
;; demand.

;;; Code:

(require 'magit2-core)
(require 'magit2-log)

;;; Options

(defgroup magit2-wip nil
  "Automatically commit to work-in-progress refs."
  :link '(info-link "(magit2)Wip Modes")
  :group 'magit2-modes
  :group 'magit2-essentials)

(defgroup magit2-wip-legacy nil
  "It is better to not use these modes individually."
  :link '(info-link "(magit2)Legacy Wip Modes")
  :group 'magit2-wip)

(defcustom magit2-wip-mode-lighter " Wip"
  "Lighter for Magit-Wip mode."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-wip
  :type 'string)

(defcustom magit2-wip-after-save-local-mode-lighter ""
  "Lighter for Magit-Wip-After-Save-Local mode."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip-legacy
  :type 'string)

(defcustom magit2-wip-after-apply-mode-lighter ""
  "Lighter for Magit-Wip-After-Apply mode."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip-legacy
  :type 'string)

(defcustom magit2-wip-before-change-mode-lighter ""
  "Lighter for Magit-Wip-Before-Change mode."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip-legacy
  :type 'string)

(defcustom magit2-wip-initial-backup-mode-lighter ""
  "Lighter for Magit-Wip-Initial Backup mode."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip-legacy
  :type 'string)

(defcustom magit2-wip-merge-branch nil
  "Whether to merge the current branch into its wip ref.

If non-nil and the current branch has new commits, then it is
merged into the wip ref before creating a new wip commit.  This
makes it easier to inspect wip history and the wip commits are
never garbage collected.

If nil and the current branch has new commits, then the wip ref
is reset to the tip of the branch before creating a new wip
commit.  With this setting wip commits are eventually garbage
collected.  This is currently the default."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-wip
  :type 'boolean)

(defcustom magit2-wip-namespace "refs/wip/"
  "Namespace used for work-in-progress refs.
The wip refs are named \"<namespace/>index/<branchref>\"
and \"<namespace/>wtree/<branchref>\".  When snapshots
are created while the `HEAD' is detached then \"HEAD\"
is used as `branch-ref'."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip
  :type 'string)

;;; Modes

;;;###autoload
(define-minor-mode magit2-wip-mode
  "Save uncommitted changes to work-in-progress refs.

Whenever appropriate (i.e. when dataloss would be a possibility
otherwise) this mode causes uncommitted changes to be committed
to dedicated work-in-progress refs.

For historic reasons this mode is implemented on top of four
other `magit2-wip-*' modes, which can also be used individually,
if you want finer control over when the wip refs are updated;
but that is discouraged."
  :package-version '(magit2 . "2.90.0")
  :lighter magit2-wip-mode-lighter
  :global t
  (let ((arg (if magit2-wip-mode 1 -1)))
    (magit2-wip-after-save-mode arg)
    (magit2-wip-after-apply-mode arg)
    (magit2-wip-before-change-mode arg)
    (magit2-wip-initial-backup-mode arg)))

(define-minor-mode magit2-wip-after-save-local-mode
  "After saving, also commit to a worktree work-in-progress ref.

After saving the current file-visiting buffer this mode also
commits the changes to the worktree work-in-progress ref for
the current branch.

This mode should be enabled globally by turning on the globalized
variant `magit2-wip-after-save-mode'."
  :package-version '(magit2 . "2.1.0")
  :lighter magit2-wip-after-save-local-mode-lighter
  (if magit2-wip-after-save-local-mode
      (if (and buffer-file-name (magit2-inside-worktree-p t))
          (add-hook 'after-save-hook 'magit2-wip-commit-buffer-file t t)
        (setq magit2-wip-after-save-local-mode nil)
        (user-error "Need a worktree and a file"))
    (remove-hook 'after-save-hook 'magit2-wip-commit-buffer-file t)))

(defun magit2-wip-after-save-local-mode-turn-on ()
  (and buffer-file-name
       (magit2-inside-worktree-p t)
       (magit2-file-tracked-p buffer-file-name)
       (magit2-wip-after-save-local-mode)))

;;;###autoload
(define-globalized-minor-mode magit2-wip-after-save-mode
  magit2-wip-after-save-local-mode magit2-wip-after-save-local-mode-turn-on
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip)

(defun magit2-wip-commit-buffer-file (&optional msg)
  "Commit visited file to a worktree work-in-progress ref.

Also see `magit2-wip-after-save-mode' which calls this function
automatically whenever a buffer visiting a tracked file is saved."
  (interactive)
  (--when-let (magit2-wip-get-ref)
    (magit2-with-toplevel
      (let ((file (file-relative-name buffer-file-name)))
        (magit2-wip-commit-worktree
         it (list file)
         (format (cond (msg)
                       ((called-interactively-p 'any)
                        "wip-save %s after save")
                       (t
                        "autosave %s after save"))
                 file))))))

;;;###autoload
(define-minor-mode magit2-wip-after-apply-mode
  "Commit to work-in-progress refs.

After applying a change using any \"apply variant\"
command (apply, stage, unstage, discard, and reverse) commit the
affected files to the current wip refs.  For each branch there
may be two wip refs; one contains snapshots of the files as found
in the worktree and the other contains snapshots of the entries
in the index."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip
  :lighter magit2-wip-after-apply-mode-lighter
  :global t)

(defun magit2-wip-commit-after-apply (&optional files msg)
  (when magit2-wip-after-apply-mode
    (magit2-wip-commit files msg)))

;;;###autoload
(define-minor-mode magit2-wip-before-change-mode
  "Commit to work-in-progress refs before certain destructive changes.

Before invoking a revert command or an \"apply variant\"
command (apply, stage, unstage, discard, and reverse) commit the
affected tracked files to the current wip refs.  For each branch
there may be two wip refs; one contains snapshots of the files
as found in the worktree and the other contains snapshots of the
entries in the index.

Only changes to files which could potentially be affected by the
command which is about to be called are committed."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-wip
  :lighter magit2-wip-before-change-mode-lighter
  :global t)

(defun magit2-wip-commit-before-change (&optional files msg)
  (when magit2-wip-before-change-mode
    (magit2-with-toplevel
      (magit2-wip-commit files msg))))

(define-minor-mode magit2-wip-initial-backup-mode
  "Before saving a buffer for the first time, commit to a wip ref."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-wip
  :lighter magit2-wip-initial-backup-mode-lighter
  :global t
  (if magit2-wip-initial-backup-mode
      (add-hook  'before-save-hook 'magit2-wip-commit-initial-backup)
    (remove-hook 'before-save-hook 'magit2-wip-commit-initial-backup)))

(defun magit2--any-wip-mode-enabled-p ()
  "Return non-nil if any global wip mode is enabled."
  (or magit2-wip-mode
      magit2-wip-after-save-mode
      magit2-wip-after-apply-mode
      magit2-wip-before-change-mode
      magit2-wip-initial-backup-mode))

(defvar-local magit2-wip-buffer-backed-up nil)
(put 'magit2-wip-buffer-backed-up 'permanent-local t)

;;;###autoload
(defun magit2-wip-commit-initial-backup ()
  "Before saving, commit current file to a worktree wip ref.

The user has to add this function to `before-save-hook'.

Commit the current state of the visited file before saving the
current buffer to that file.  This backs up the same version of
the file as `backup-buffer' would, but stores the backup in the
worktree wip ref, which is also used by the various Magit Wip
modes, instead of in a backup file as `backup-buffer' would.

This function ignores the variables that affect `backup-buffer'
and can be used along-side that function, which is recommended
because this function only backs up files that are tracked in
a Git repository."
  (when (and (not magit2-wip-buffer-backed-up)
             buffer-file-name
             (magit2-inside-worktree-p t)
             (magit2-file-tracked-p buffer-file-name))
    (let ((magit2-save-repository-buffers nil))
      (magit2-wip-commit-buffer-file "autosave %s before save"))
    (setq magit2-wip-buffer-backed-up t)))

;;; Core

(defun magit2-wip-commit (&optional files msg)
  "Commit all tracked files to the work-in-progress refs.

Interactively, commit all changes to all tracked files using
a generic commit message.  With a prefix-argument the commit
message is read in the minibuffer.

Non-interactively, only commit changes to FILES using MSG as
commit message."
  (interactive (list nil (if current-prefix-arg
                             (magit2-read-string "Wip commit message")
                           "wip-save tracked files")))
  (--when-let (magit2-wip-get-ref)
    (magit2-wip-commit-index it files msg)
    (magit2-wip-commit-worktree it files msg)))

(defun magit2-wip-commit-index (ref files msg)
  (let* ((wipref (magit2--wip-index-ref ref))
         (parent (magit2-wip-get-parent ref wipref))
         (tree   (magit2-git-string "write-tree")))
    (magit2-wip-update-wipref ref wipref tree parent files msg "index")))

(defun magit2-wip-commit-worktree (ref files msg)
  (when (or (not files)
            ;; `update-index' will either ignore (before Git v2.32.0)
            ;; or fail when passed directories (relevant for the
            ;; untracked files code paths).
            (setq files (seq-remove #'file-directory-p files)))
    (let* ((wipref (magit2--wip-wtree-ref ref))
           (parent (magit2-wip-get-parent ref wipref))
           (tree (magit2-with-temp-index parent (list "--reset" "-i")
                   (if files
                       ;; Note: `update-index' is used instead of `add'
                       ;; because `add' will fail if a file is already
                       ;; deleted in the temporary index.
                       (magit2-call-git
                        "update-index" "--add" "--remove"
                        (and (magit2-git-version>= "2.25.0")
                             "--ignore-skip-worktree-entries")
                        "--" files)
                     (magit2-with-toplevel
                       (magit2-call-git "add" "-u" ".")))
                   (magit2-git-string "write-tree"))))
      (magit2-wip-update-wipref ref wipref tree parent files msg "worktree"))))

(defun magit2-wip-update-wipref (ref wipref tree parent files msg start-msg)
  (cond
   ((and (not (equal parent wipref))
         (or (not magit2-wip-merge-branch)
             (not (magit2-rev-parse wipref))))
    (setq start-msg (concat "start autosaving " start-msg))
    (magit2-update-ref wipref start-msg
                      (magit2-git-string "commit-tree" "--no-gpg-sign"
                                        "-p" parent "-m" start-msg
                                        (concat parent "^{tree}")))
    (setq parent wipref))
   ((and magit2-wip-merge-branch
         (or (not (magit2-rev-ancestor-p ref wipref))
             (not (magit2-rev-ancestor-p
                   (concat (magit2-git-string "log" "--format=%H"
                                             "-1" "--merges" wipref)
                           "^2")
                   ref))))
    (setq start-msg (format "merge %s into %s" ref start-msg))
    (magit2-update-ref wipref start-msg
                      (magit2-git-string "commit-tree" "--no-gpg-sign"
                                        "-p" wipref "-p" ref
                                        "-m" start-msg
                                        (concat ref "^{tree}")))
    (setq parent wipref)))
  (when (magit2-git-failure "diff-tree" "--quiet" parent tree "--" files)
    (unless (and msg (not (= (aref msg 0) ?\s)))
      (let ((len (length files)))
        (setq msg (concat
                   (cond ((= len 0) "autosave tracked files")
                         ((> len 1) (format "autosave %s files" len))
                         (t (concat "autosave "
                                    (file-relative-name (car files)
                                                        (magit2-toplevel)))))
                   msg))))
    (magit2-update-ref wipref msg
                      (magit2-git-string "commit-tree" "--no-gpg-sign"
                                        "-p" parent "-m" msg tree))))

(defun magit2-wip-get-ref ()
  (let ((ref (or (magit2-git-string "symbolic-ref" "HEAD") "HEAD")))
    (and (magit2-rev-parse ref)
         ref)))

(defun magit2-wip-get-parent (ref wipref)
  (if (and (magit2-rev-parse wipref)
           (equal (magit2-git-string "merge-base" wipref ref)
                  (magit2-rev-parse ref)))
      wipref
    ref))

(defun magit2--wip-index-ref (&optional ref)
  (magit2--wip-ref "index/" ref))

(defun magit2--wip-wtree-ref (&optional ref)
  (magit2--wip-ref "wtree/" ref))

(defun magit2--wip-ref (namespace &optional ref)
  (concat magit2-wip-namespace namespace
          (or (and ref (string-prefix-p "refs/" ref) ref)
              (when-let ((branch (and (not (equal ref "HEAD"))
                                      (or ref (magit2-get-current-branch)))))
                (concat "refs/heads/" branch))
              "HEAD")))

(defun magit2-wip-maybe-add-commit-hook ()
  (when (and magit2-wip-merge-branch
             (magit2-wip-any-enabled-p))
    (add-hook 'git-commit-post-finish-hook 'magit2-wip-commit nil t)))

(defun magit2-wip-any-enabled-p ()
  (or magit2-wip-mode
      magit2-wip-after-save-local-mode
      magit2-wip-after-save-mode
      magit2-wip-after-apply-mode
      magit2-wip-before-change-mode
      magit2-wip-initial-backup-mode))

;;; Log

(defun magit2-wip-log-index (args files)
  "Show log for the index wip ref of the current branch."
  (interactive (magit2-log-arguments))
  (magit2-log-setup-buffer (list (magit2--wip-index-ref)) args files))

(defun magit2-wip-log-worktree (args files)
  "Show log for the worktree wip ref of the current branch."
  (interactive (magit2-log-arguments))
  (magit2-log-setup-buffer (list (magit2--wip-wtree-ref)) args files))

(defun magit2-wip-log-current (branch args files count)
  "Show log for the current branch and its wip refs.
With a negative prefix argument only show the worktree wip ref.
The absolute numeric value of the prefix argument controls how
many \"branches\" of each wip ref are shown."
  (interactive
   (nconc (list (or (magit2-get-current-branch) "HEAD"))
          (magit2-log-arguments)
          (list (prefix-numeric-value current-prefix-arg))))
  (magit2-wip-log branch args files count))

(defun magit2-wip-log (branch args files count)
  "Show log for a branch and its wip refs.
With a negative prefix argument only show the worktree wip ref.
The absolute numeric value of the prefix argument controls how
many \"branches\" of each wip ref are shown."
  (interactive
   (nconc (list (magit2-completing-read
                 "Log branch and its wip refs"
                 (-snoc (magit2-list-local-branch-names) "HEAD")
                 nil t nil 'magit2-revision-history
                 (or (magit2-branch-at-point)
                     (magit2-get-current-branch)
                     "HEAD")))
          (magit2-log-arguments)
          (list (prefix-numeric-value current-prefix-arg))))
  (magit2-log-setup-buffer (nconc (list branch)
                                 (magit2-wip-log-get-tips
                                  (magit2--wip-wtree-ref branch)
                                  (abs count))
                                 (and (>= count 0)
                                      (magit2-wip-log-get-tips
                                       (magit2--wip-index-ref branch)
                                       (abs count))))
                          args files))

(defun magit2-wip-log-get-tips (wipref count)
  (when-let ((reflog (magit2-git-lines "reflog" wipref)))
    (let (tips)
      (while (and reflog (> count 1))
        ;; "start autosaving ..." is the current message, but it used
        ;; to be "restart autosaving ...", and those messages may
        ;; still be around (e.g., if gc.reflogExpire is to "never").
        (setq reflog (cl-member "^[^ ]+ [^:]+: \\(?:re\\)?start autosaving"
                                reflog :test #'string-match-p))
        (when (and (cadr reflog)
                   (string-match "^[^ ]+ \\([^:]+\\)" (cadr reflog)))
          (push (match-string 1 (cadr reflog)) tips))
        (setq reflog (cddr reflog))
        (cl-decf count))
      (cons wipref (nreverse tips)))))

;;; _
(provide 'magit2-wip)
;;; magit2-wip.el ends here
