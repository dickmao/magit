;;; magit2-sequence.el --- history manipulation in Magit  -*- lexical-binding: t -*-

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

;; Support for Git commands that replay commits and help the user make
;; changes along the way.  Supports `cherry-pick', `revert', `rebase',
;; `rebase--interactive' and `am'.

;;; Code:

(require 'magit2)

;; For `magit2-rebase--todo'.
(declare-function git-rebase-current-line "git-rebase" ())
(eval-when-compile
  (cl-pushnew 'action-type eieio--known-slot-names)
  (cl-pushnew 'action eieio--known-slot-names)
  (cl-pushnew 'action-options eieio--known-slot-names)
  (cl-pushnew 'target eieio--known-slot-names))

;;; Options
;;;; Faces

(defface magit2-sequence-pick
  '((t :inherit default))
  "Face used in sequence sections."
  :group 'magit2-faces)

(defface magit2-sequence-stop
  '((((class color) (background light)) :foreground "DarkOliveGreen4")
    (((class color) (background dark))  :foreground "DarkSeaGreen2"))
  "Face used in sequence sections."
  :group 'magit2-faces)

(defface magit2-sequence-part
  '((((class color) (background light)) :foreground "Goldenrod4")
    (((class color) (background dark))  :foreground "LightGoldenrod2"))
  "Face used in sequence sections."
  :group 'magit2-faces)

(defface magit2-sequence-head
  '((((class color) (background light)) :foreground "SkyBlue4")
    (((class color) (background dark))  :foreground "LightSkyBlue1"))
  "Face used in sequence sections."
  :group 'magit2-faces)

(defface magit2-sequence-drop
  '((((class color) (background light)) :foreground "IndianRed")
    (((class color) (background dark))  :foreground "IndianRed"))
  "Face used in sequence sections."
  :group 'magit2-faces)

(defface magit2-sequence-done
  '((t :inherit magit2-hash))
  "Face used in sequence sections."
  :group 'magit2-faces)

(defface magit2-sequence-onto
  '((t :inherit magit2-sequence-done))
  "Face used in sequence sections."
  :group 'magit2-faces)

(defface magit2-sequence-exec
  '((t :inherit magit2-hash))
  "Face used in sequence sections."
  :group 'magit2-faces)

;;; Common

;;;###autoload
(defun magit2-sequencer-continue ()
  "Resume the current cherry-pick or revert sequence."
  (interactive)
  (if (magit2-sequencer-in-progress-p)
      (if (magit2-anything-unmerged-p)
          (user-error "Cannot continue due to unresolved conflicts")
        (magit2-run-git-sequencer
         (if (magit2-revert-in-progress-p) "revert" "cherry-pick") "--continue"))
    (user-error "No cherry-pick or revert in progress")))

;;;###autoload
(defun magit2-sequencer-skip ()
  "Skip the stopped at commit during a cherry-pick or revert sequence."
  (interactive)
  (if (magit2-sequencer-in-progress-p)
      (progn (magit2-call-git "reset" "--hard")
             (magit2-sequencer-continue))
    (user-error "No cherry-pick or revert in progress")))

;;;###autoload
(defun magit2-sequencer-abort ()
  "Abort the current cherry-pick or revert sequence.
This discards all changes made since the sequence started."
  (interactive)
  (if (magit2-sequencer-in-progress-p)
      (magit2-run-git-sequencer
       (if (magit2-revert-in-progress-p) "revert" "cherry-pick") "--abort")
    (user-error "No cherry-pick or revert in progress")))

(defun magit2-sequencer-in-progress-p ()
  (or (magit2-cherry-pick-in-progress-p)
      (magit2-revert-in-progress-p)))

;;; Cherry-Pick

(defvar magit2-perl-executable "perl"
  "The Perl executable.")

;;;###autoload (autoload 'magit2-cherry-pick "magit2-sequence" nil t)
(transient-define-prefix magit2-cherry-pick ()
  "Apply or transplant commits."
  :man-page "git-cherry-pick"
  :value '("--ff")
  :incompatible '(("--ff" "-x"))
  ["Arguments"
   :if-not magit2-sequencer-in-progress-p
   (magit2-cherry-pick:--mainline)
   ("=s" magit2-merge:--strategy)
   ("-F" "Attempt fast-forward"               "--ff")
   ("-x" "Reference cherry in commit message" "-x")
   ("-e" "Edit commit messages"               ("-e" "--edit"))
   ("-s" "Add Signed-off-by lines"            ("-s" "--signoff"))
   (5 magit2:--gpg-sign)]
  [:if-not magit2-sequencer-in-progress-p
   ["Apply here"
    ("A" "Pick"    magit2-cherry-copy)
    ("a" "Apply"   magit2-cherry-apply)
    ("h" "Harvest" magit2-cherry-harvest)
    ("m" "Squash"  magit2-merge-squash)]
   ["Apply elsewhere"
    ("d" "Donate"  magit2-cherry-donate)
    ("n" "Spinout" magit2-cherry-spinout)
    ("s" "Spinoff" magit2-cherry-spinoff)]]
  ["Actions"
   :if magit2-sequencer-in-progress-p
   ("A" "Continue" magit2-sequencer-continue)
   ("s" "Skip"     magit2-sequencer-skip)
   ("a" "Abort"    magit2-sequencer-abort)])

(transient-define-argument magit2-cherry-pick:--mainline ()
  :description "Replay merge relative to parent"
  :class 'transient-option
  :shortarg "-m"
  :argument "--mainline="
  :reader 'transient-read-number-N+)

(defun magit2-cherry-pick-read-args (prompt)
  (list (or (nreverse (magit2-region-values 'commit))
            (magit2-read-other-branch-or-commit prompt))
        (transient-args 'magit2-cherry-pick)))

(defun magit2--cherry-move-read-args (verb away fn &optional allow-detached)
  (declare (indent defun))
  (let ((commits (or (nreverse (magit2-region-values 'commit))
                     (list (funcall (if away
                                        'magit2-read-branch-or-commit
                                      'magit2-read-other-branch-or-commit)
                                    (format "%s cherry" (capitalize verb))))))
        (current (or (magit2-get-current-branch)
                     (and allow-detached (magit2-rev-parse "HEAD")))))
    (unless current
      (user-error "Cannot %s cherries while HEAD is detached" verb))
    (let ((reachable (magit2-rev-ancestor-p (car commits) current))
          (msg "Cannot %s cherries that %s reachable from HEAD"))
      (pcase (list away reachable)
        (`(nil t) (user-error msg verb "are"))
        (`(t nil) (user-error msg verb "are not"))))
    `(,commits
      ,@(funcall fn commits)
      ,(transient-args 'magit2-cherry-pick))))

(defun magit2--cherry-spinoff-read-args (verb)
  (magit2--cherry-move-read-args verb t
    (lambda (commits)
      (magit2-branch-read-args
       (format "Create branch from %s cherries" (length commits))
       (magit2-get-upstream-branch)))))

;;;###autoload
(defun magit2-cherry-copy (commits &optional args)
  "Copy COMMITS from another branch onto the current branch.
Prompt for a commit, defaulting to the commit at point.  If
the region selects multiple commits, then pick all of them,
without prompting."
  (interactive (magit2-cherry-pick-read-args "Cherry-pick"))
  (magit2--cherry-pick commits args))

;;;###autoload
(defun magit2-cherry-apply (commits &optional args)
  "Apply the changes in COMMITS but do not commit them.
Prompt for a commit, defaulting to the commit at point.  If
the region selects multiple commits, then apply all of them,
without prompting."
  (interactive (magit2-cherry-pick-read-args "Apply changes from commit"))
  (magit2--cherry-pick commits (cons "--no-commit" (remove "--ff" args))))

;;;###autoload
(defun magit2-cherry-harvest (commits branch &optional args)
  "Move COMMITS from another BRANCH onto the current branch.
Remove the COMMITS from BRANCH and stay on the current branch.
If a conflict occurs, then you have to fix that and finish the
process manually."
  (interactive
   (magit2--cherry-move-read-args "harvest" nil
     (lambda (commits)
       (list (let ((branches (magit2-list-containing-branches (car commits))))
               (pcase (length branches)
                 (0 nil)
                 (1 (car branches))
                 (_ (magit2-completing-read
                     (let ((len (length commits)))
                       (if (= len 1)
                           "Remove 1 cherry from branch"
                         (format "Remove %s cherries from branch" len)))
                     branches nil t))))))))
  (magit2--cherry-move commits branch (magit2-get-current-branch) args nil t))

;;;###autoload
(defun magit2-cherry-donate (commits branch &optional args)
  "Move COMMITS from the current branch onto another existing BRANCH.
Remove COMMITS from the current branch and stay on that branch.
If a conflict occurs, then you have to fix that and finish the
process manually.  `HEAD' is allowed to be detached initially."
  (interactive
   (magit2--cherry-move-read-args "donate" t
     (lambda (commits)
       (list (magit2-read-other-branch
              (let ((len (length commits)))
                (if (= len 1)
                    "Move 1 cherry to branch"
                  (format "Move %s cherries to branch" len))))))
     'allow-detached))
  (magit2--cherry-move commits
                      (or (magit2-get-current-branch)
                          (magit2-rev-parse "HEAD"))
                      branch args))

;;;###autoload
(defun magit2-cherry-spinout (commits branch start-point &optional args)
  "Move COMMITS from the current branch onto a new BRANCH.
Remove COMMITS from the current branch and stay on that branch.
If a conflict occurs, then you have to fix that and finish the
process manually."
  (interactive (magit2--cherry-spinoff-read-args "spinout"))
  (magit2--cherry-move commits (magit2-get-current-branch) branch args
                      start-point))

;;;###autoload
(defun magit2-cherry-spinoff (commits branch start-point &optional args)
  "Move COMMITS from the current branch onto a new BRANCH.
Remove COMMITS from the current branch and checkout BRANCH.
If a conflict occurs, then you have to fix that and finish
the process manually."
  (interactive (magit2--cherry-spinoff-read-args "spinoff"))
  (magit2--cherry-move commits (magit2-get-current-branch) branch args
                      start-point t))

(defun magit2--cherry-move (commits src dst args
                                   &optional start-point checkout-dst)
  (let ((current (magit2-get-current-branch)))
    (unless (magit2-branch-p dst)
      (let ((magit2-process-raise-error t))
        (magit2-call-git "branch" dst start-point))
      (--when-let (magit2-get-indirect-upstream-branch start-point)
        (magit2-call-git "branch" "--set-upstream-to" it dst)))
    (unless (equal dst current)
      (let ((magit2-process-raise-error t))
        (magit2-call-git "checkout" dst)))
    (if (not src) ; harvest only
        (magit2--cherry-pick commits args)
      (let ((tip (car (last commits)))
            (keep (concat (car commits) "^")))
        (magit2--cherry-pick commits args)
        (set-process-sentinel
         magit2-this-process
         (lambda (process event)
           (when (memq (process-status process) '(exit signal))
             (if (> (process-exit-status process) 0)
                 (magit2-process-sentinel process event)
               (process-put process 'inhibit-refresh t)
               (magit2-process-sentinel process event)
               (cond
                ((magit2-rev-equal tip src)
                 (magit2-call-git "update-ref"
                                 "-m" (format "reset: moving to %s" keep)
                                 (magit2-ref-fullname src)
                                 keep tip)
                 (if (not checkout-dst)
                     (magit2-run-git "checkout" src)
                   (magit2-refresh)))
                (t
                 (magit2-git "checkout" src)
                 (let ((process-environment process-environment))
                   (push (format "%s=%s -i -ne '/^pick (%s)/ or print'"
                                 "GIT_SEQUENCE_EDITOR"
                                 magit2-perl-executable
                                 (mapconcat #'magit2-rev-abbrev commits "|"))
                         process-environment)
                   (magit2-run-git-sequencer "rebase" "-i" keep))
                 (when checkout-dst
                   (set-process-sentinel
                    magit2-this-process
                    (lambda (process event)
                      (when (memq (process-status process) '(exit signal))
                        (if (> (process-exit-status process) 0)
                            (magit2-process-sentinel process event)
                          (process-put process 'inhibit-refresh t)
                          (magit2-process-sentinel process event)
                          (magit2-run-git "checkout" dst))))))))))))))))

(defun magit2--cherry-pick (commits args &optional revert)
  (let ((command (if revert "revert" "cherry-pick")))
    (when (stringp commits)
      (setq commits (if (string-match-p "\\.\\." commits)
                        (split-string commits "\\.\\.")
                      (list commits))))
    (magit2-run-git-sequencer
     (if revert "revert" "cherry-pick")
     (pcase-let ((`(,merge ,non-merge)
                  (-separate 'magit2-merge-commit-p commits)))
       (cond
        ((not merge)
         (--remove (string-prefix-p "--mainline=" it) args))
        (non-merge
         (user-error "Cannot %s merge and non-merge commits at once"
                     command))
        ((--first (string-prefix-p "--mainline=" it) args)
         args)
        (t
         (cons (format "--mainline=%s"
                       (read-number "Replay merges relative to parent: "))
               args))))
     commits)))

(defun magit2-cherry-pick-in-progress-p ()
  ;; .git/sequencer/todo does not exist when there is only one commit left.
  (file-exists-p (magit2-git-dir "CHERRY_PICK_HEAD")))

;;; Revert

;;;###autoload (autoload 'magit2-revert "magit2-sequence" nil t)
(transient-define-prefix magit2-revert ()
  "Revert existing commits, with or without creating new commits."
  :man-page "git-revert"
  :value '("--edit")
  ["Arguments"
   :if-not magit2-sequencer-in-progress-p
   (magit2-cherry-pick:--mainline)
   ("-e" "Edit commit message"       ("-e" "--edit"))
   ("-E" "Don't edit commit message" "--no-edit")
   ("=s" magit2-merge:--strategy)
   ("-s" "Add Signed-off-by lines"   ("-s" "--signoff"))
   (5 magit2:--gpg-sign)]
  ["Actions"
   :if-not magit2-sequencer-in-progress-p
   ("V" "Revert commit(s)" magit2-revert-and-commit)
   ("v" "Revert changes"   magit2-revert-no-commit)]
  ["Actions"
   :if magit2-sequencer-in-progress-p
   ("V" "Continue" magit2-sequencer-continue)
   ("s" "Skip"     magit2-sequencer-skip)
   ("a" "Abort"    magit2-sequencer-abort)])

(defun magit2-revert-read-args (prompt)
  (list (or (magit2-region-values 'commit)
            (magit2-read-branch-or-commit prompt))
        (transient-args 'magit2-revert)))

;;;###autoload
(defun magit2-revert-and-commit (commit &optional args)
  "Revert COMMIT by creating a new commit.
Prompt for a commit, defaulting to the commit at point.  If
the region selects multiple commits, then revert all of them,
without prompting."
  (interactive (magit2-revert-read-args "Revert commit"))
  (magit2--cherry-pick commit args t))

;;;###autoload
(defun magit2-revert-no-commit (commit &optional args)
  "Revert COMMIT by applying it in reverse to the worktree.
Prompt for a commit, defaulting to the commit at point.  If
the region selects multiple commits, then revert all of them,
without prompting."
  (interactive (magit2-revert-read-args "Revert changes"))
  (magit2--cherry-pick commit (cons "--no-commit" args) t))

(defun magit2-revert-in-progress-p ()
  ;; .git/sequencer/todo does not exist when there is only one commit left.
  (file-exists-p (magit2-git-dir "REVERT_HEAD")))

;;; Patch

;;;###autoload (autoload 'magit2-am "magit2-sequence" nil t)
(transient-define-prefix magit2-am ()
  "Apply patches received by email."
  :man-page "git-am"
  :value '("--3way")
  ["Arguments"
   :if-not magit2-am-in-progress-p
   ("-3" "Fall back on 3way merge"           ("-3" "--3way"))
   (magit2-apply:-p)
   ("-c" "Remove text before scissors line"  ("-c" "--scissors"))
   ("-k" "Inhibit removal of email cruft"    ("-k" "--keep"))
   ("-b" "Limit removal of email cruft"      "--keep-non-patch")
   ("-d" "Use author date as committer date" "--committer-date-is-author-date")
   ("-t" "Use current time as author date"   "--ignore-date")
   ("-s" "Add Signed-off-by lines"           ("-s" "--signoff"))
   (5 magit2:--gpg-sign)]
  ["Apply"
   :if-not magit2-am-in-progress-p
   ("m" "maildir"     magit2-am-apply-maildir)
   ("w" "patches"     magit2-am-apply-patches)
   ("a" "plain patch" magit2-patch-apply)]
  ["Actions"
   :if magit2-am-in-progress-p
   ("w" "Continue" magit2-am-continue)
   ("s" "Skip"     magit2-am-skip)
   ("a" "Abort"    magit2-am-abort)])

(defun magit2-am-arguments ()
  (transient-args 'magit2-am))

(transient-define-argument magit2-apply:-p ()
  :description "Remove leading slashes from paths"
  :class 'transient-option
  :argument "-p"
  :allow-empty t
  :reader 'transient-read-number-N+)

;;;###autoload
(defun magit2-am-apply-patches (&optional files args)
  "Apply the patches FILES."
  (interactive (list (or (magit2-region-values 'file)
                         (list (let ((default (magit2-file-at-point)))
                                 (read-file-name
                                  (if default
                                      (format "Apply patch (%s): " default)
                                    "Apply patch: ")
                                  nil default))))
                     (magit2-am-arguments)))
  (magit2-run-git-sequencer "am" args "--"
                           (--map (magit2-convert-filename-for-git
                                   (expand-file-name it))
                                  files)))

;;;###autoload
(defun magit2-am-apply-maildir (&optional maildir args)
  "Apply the patches from MAILDIR."
  (interactive (list (read-file-name "Apply mbox or Maildir: ")
                     (magit2-am-arguments)))
  (magit2-run-git-sequencer "am" args (magit2-convert-filename-for-git
                                      (expand-file-name maildir))))

;;;###autoload
(defun magit2-am-continue ()
  "Resume the current patch applying sequence."
  (interactive)
  (if (magit2-am-in-progress-p)
      (if (magit2-anything-unstaged-p t)
          (error "Cannot continue due to unstaged changes")
        (magit2-run-git-sequencer "am" "--continue"))
    (user-error "Not applying any patches")))

;;;###autoload
(defun magit2-am-skip ()
  "Skip the stopped at patch during a patch applying sequence."
  (interactive)
  (if (magit2-am-in-progress-p)
      (magit2-run-git-sequencer "am" "--skip")
    (user-error "Not applying any patches")))

;;;###autoload
(defun magit2-am-abort ()
  "Abort the current patch applying sequence.
This discards all changes made since the sequence started."
  (interactive)
  (if (magit2-am-in-progress-p)
      (magit2-run-git "am" "--abort")
    (user-error "Not applying any patches")))

(defun magit2-am-in-progress-p ()
  (file-exists-p (magit2-git-dir "rebase-apply/applying")))

;;; Rebase

;;;###autoload (autoload 'magit2-rebase "magit2-sequence" nil t)
(transient-define-prefix magit2-rebase ()
  "Transplant commits and/or modify existing commits."
  :man-page "git-rebase"
  :value '("--autostash")
  ["Arguments"
   :if-not magit2-rebase-in-progress-p
   ("-k" "Keep empty commits"       "--keep-empty")
   ("-p" "Preserve merges"          ("-p" "--preserve-merges")
    :if (lambda () (magit2-git-version< "2.33.0")))
   ("-r" "Rebase merges"            ("-r" "--rebase-merges=")
    magit2-rebase-merges-select-mode
    :if (lambda () (magit2-git-version>= "2.18.0")))
   (7 magit2-merge:--strategy)
   (7 magit2-merge:--strategy-option)
   (7 "=X" magit2-diff:--diff-algorithm :argument "-Xdiff-algorithm=")
   (7 "-f" "Forge rebase"           ("-f" "--force-rebase"))
   ("-d" "Use author date as committer date" "--committer-date-is-author-date")
   ("-t" "Use current time as author date"   "--ignore-date")
   ("-a" "Autosquash"               "--autosquash")
   ("-A" "Autostash"                "--autostash")
   ("-i" "Interactive"              ("-i" "--interactive"))
   ("-h" "Disable hooks"            "--no-verify")
   (7 magit2-rebase:--exec)
   (5 magit2:--gpg-sign)]
  [:if-not magit2-rebase-in-progress-p
   :description (lambda ()
                  (format (propertize "Rebase %s onto" 'face 'transient-heading)
                          (propertize (or (magit2-get-current-branch) "HEAD")
                                      'face 'magit2-branch-local)))
   ("p" magit2-rebase-onto-pushremote)
   ("u" magit2-rebase-onto-upstream)
   ("e" "elsewhere" magit2-rebase-branch)]
  ["Rebase"
   :if-not magit2-rebase-in-progress-p
   [("i" "interactively"      magit2-rebase-interactive)
    ("s" "a subset"           magit2-rebase-subset)]
   [("m" "to modify a commit" magit2-rebase-edit-commit)
    ("w" "to reword a commit" magit2-rebase-reword-commit)
    ("k" "to remove a commit" magit2-rebase-remove-commit)
    ("f" "to autosquash"      magit2-rebase-autosquash)
    (6 "t" "to change dates"  magit2-reshelve-since)]]
  ["Actions"
   :if magit2-rebase-in-progress-p
   ("r" "Continue" magit2-rebase-continue)
   ("s" "Skip"     magit2-rebase-skip)
   ("e" "Edit"     magit2-rebase-edit)
   ("a" "Abort"    magit2-rebase-abort)])

(transient-define-argument magit2-rebase:--exec ()
  :description "Run command after commits"
  :class 'transient-option
  :shortarg "-x"
  :argument "--exec="
  :reader #'read-shell-command)

(defun magit2-rebase-merges-select-mode (&rest _ignore)
  (magit2-read-char-case nil t
    (?n "[n]o-rebase-cousins" "no-rebase-cousins")
    (?r "[r]ebase-cousins" "rebase-cousins")))

(defun magit2-rebase-arguments ()
  (transient-args 'magit2-rebase))

(defun magit2-git-rebase (target args)
  (magit2-run-git-sequencer "rebase" args target))

;;;###autoload (autoload 'magit2-rebase-onto-pushremote "magit2-sequence" nil t)
(transient-define-suffix magit2-rebase-onto-pushremote (args)
  "Rebase the current branch onto its push-remote branch.

With a prefix argument or when the push-remote is either not
configured or unusable, then let the user first configure the
push-remote."
  :if 'magit2-get-current-branch
  :description 'magit2-pull--pushbranch-description
  (interactive (list (magit2-rebase-arguments)))
  (pcase-let ((`(,branch ,remote)
               (magit2--select-push-remote "rebase onto that")))
    (magit2-git-rebase (concat remote "/" branch) args)))

;;;###autoload (autoload 'magit2-rebase-onto-upstream "magit2-sequence" nil t)
(transient-define-suffix magit2-rebase-onto-upstream (args)
  "Rebase the current branch onto its upstream branch.

With a prefix argument or when the upstream is either not
configured or unusable, then let the user first configure
the upstream."
  :if 'magit2-get-current-branch
  :description 'magit2-rebase--upstream-description
  (interactive (list (magit2-rebase-arguments)))
  (let* ((branch (or (magit2-get-current-branch)
                     (user-error "No branch is checked out")))
         (upstream (magit2-get-upstream-branch branch)))
    (when (or current-prefix-arg (not upstream))
      (setq upstream
            (magit2-read-upstream-branch
             branch (format "Set upstream of %s and rebase onto that" branch)))
      (magit2-set-upstream-branch branch upstream))
    (magit2-git-rebase upstream args)))

(defun magit2-rebase--upstream-description ()
  (when-let ((branch (magit2-get-current-branch)))
    (or (magit2-get-upstream-branch branch)
        (let ((remote (magit2-get "branch" branch "remote"))
              (merge  (magit2-get "branch" branch "merge"))
              (u (magit2--propertize-face "@{upstream}" 'bold)))
          (cond
           ((magit2--unnamed-upstream-p remote merge)
            (concat u ", replacing unnamed"))
           ((magit2--valid-upstream-p remote merge)
            (concat u ", replacing non-existent"))
           ((or remote merge)
            (concat u ", replacing invalid"))
           (t
            (concat u ", setting that")))))))

;;;###autoload
(defun magit2-rebase-branch (target args)
  "Rebase the current branch onto a branch read in the minibuffer.
All commits that are reachable from `HEAD' but not from the
selected branch TARGET are being rebased."
  (interactive (list (magit2-read-other-branch-or-commit "Rebase onto")
                     (magit2-rebase-arguments)))
  (message "Rebasing...")
  (magit2-git-rebase target args)
  (message "Rebasing...done"))

;;;###autoload
(defun magit2-rebase-subset (newbase start args)
  "Rebase a subset of the current branch's history onto a new base.
Rebase commits from START to `HEAD' onto NEWBASE.
START has to be selected from a list of recent commits."
  (interactive (list (magit2-read-other-branch-or-commit
                      "Rebase subset onto" nil
                      (magit2-get-upstream-branch))
                     nil
                     (magit2-rebase-arguments)))
  (if start
      (progn (message "Rebasing...")
             (magit2-run-git-sequencer "rebase" "--onto" newbase start args)
             (message "Rebasing...done"))
    (magit2-log-select
      `(lambda (commit)
         (magit2-rebase-subset ,newbase (concat commit "^") (list ,@args)))
      (concat "Type %p on a commit to rebase it "
              "and commits above it onto " newbase ","))))

(defvar magit2-rebase-interactive-include-selected t)

(defun magit2-rebase-interactive-1
    (commit args message &optional editor delay-edit-confirm noassert confirm)
  (declare (indent 2))
  (when commit
    (if (eq commit :merge-base)
        (setq commit (--if-let (magit2-get-upstream-branch)
                         (magit2-git-string "merge-base" it "HEAD")
                       nil))
      (unless (magit2-rev-ancestor-p commit "HEAD")
        (user-error "%s isn't an ancestor of HEAD" commit))
      (if (magit2-commit-parents commit)
          (when (or (not (eq this-command 'magit2-rebase-interactive))
                    magit2-rebase-interactive-include-selected)
            (setq commit (concat commit "^")))
        (setq args (cons "--root" args)))))
  (when (and commit (not noassert))
    (setq commit (magit2-rebase-interactive-assert
                  commit delay-edit-confirm
                  (--some (string-prefix-p "--rebase-merges" it) args))))
  (if (and commit (not confirm))
      (let ((process-environment process-environment))
        (when editor
          (push (concat "GIT_SEQUENCE_EDITOR="
                        (if (functionp editor)
                            (funcall editor commit)
                          editor))
                process-environment))
        (magit2-run-git-sequencer "rebase" "-i" args
                                 (unless (member "--root" args) commit)))
    (magit2-log-select
      `(lambda (commit)
         ;; In some cases (currently just magit2-rebase-remove-commit), "-c
         ;; commentChar=#" is added to the global arguments for git.  Ensure
         ;; that the same happens when we chose the commit via
         ;; magit2-log-select, below.
         (let ((magit2-git-global-arguments (list ,@magit2-git-global-arguments)))
           (magit2-rebase-interactive-1 commit (list ,@args)
             ,message ,editor ,delay-edit-confirm ,noassert)))
      message)))

(defvar magit2--rebase-published-symbol nil)
(defvar magit2--rebase-public-edit-confirmed nil)

(defun magit2-rebase-interactive-assert
    (since &optional delay-edit-confirm rebase-merges)
  (let* ((commit (magit2-rebase--target-commit since))
         (branches (magit2-list-publishing-branches commit)))
    (setq magit2--rebase-public-edit-confirmed
          (delete (magit2-toplevel) magit2--rebase-public-edit-confirmed))
    (when (and branches
               (or (not delay-edit-confirm)
                   ;; The user might have stopped at a published commit
                   ;; merely to add new commits *after* it.  Try not to
                   ;; ask users whether they really want to edit public
                   ;; commits, when they don't actually intend to do so.
                   (not (--all-p (magit2-rev-equal it commit) branches))))
      (let ((m1 "Some of these commits have already been published to ")
            (m2 ".\nDo you really want to modify them"))
        (magit2-confirm (or magit2--rebase-published-symbol 'rebase-published)
          (concat m1 "%s" m2)
          (concat m1 "%i public branches" m2)
          nil branches))
      (push (magit2-toplevel) magit2--rebase-public-edit-confirmed)))
  (if (and (magit2-git-lines "rev-list" "--merges" (concat since "..HEAD"))
           (not rebase-merges))
      (magit2-read-char-case "Proceed despite merge in rebase range?  " nil
        (?c "[c]ontinue" since)
        (?s "[s]elect other" nil)
        (?a "[a]bort" (user-error "Quit")))
    since))

(defun magit2-rebase--target-commit (since)
  (if (string-suffix-p "^" since)
      ;; If SINCE is "REV^", then the user selected
      ;; "REV", which is the first commit that will
      ;; be replaced.  (from^..to] <=> [from..to]
      (substring since 0 -1)
    ;; The "--root" argument is being used.
    since))

;;;###autoload
(defun magit2-rebase-interactive (commit args)
  "Start an interactive rebase sequence."
  (interactive (list (magit2-commit-at-point)
                     (magit2-rebase-arguments)))
  (magit2-rebase-interactive-1 commit args
    "Type %p on a commit to rebase it and all commits above it,"
    nil t))

;;;###autoload
(defun magit2-rebase-autosquash (args)
  "Combine squash and fixup commits with their intended targets."
  (interactive (list (magit2-rebase-arguments)))
  (magit2-rebase-interactive-1 :merge-base
      (nconc (list "--autosquash" "--keep-empty") args)
    "Type %p on a commit to squash into it and then rebase as necessary,"
    "true" nil t))

;;;###autoload
(defun magit2-rebase-edit-commit (commit args)
  "Edit a single older commit using rebase."
  (interactive (list (magit2-commit-at-point)
                     (magit2-rebase-arguments)))
  (magit2-rebase-interactive-1 commit args
    "Type %p on a commit to edit it,"
    (apply-partially #'magit2-rebase--perl-editor 'edit)
    t))

;;;###autoload
(defun magit2-rebase-reword-commit (commit args)
  "Reword a single older commit using rebase."
  (interactive (list (magit2-commit-at-point)
                     (magit2-rebase-arguments)))
  (magit2-rebase-interactive-1 commit args
    "Type %p on a commit to reword its message,"
    (apply-partially #'magit2-rebase--perl-editor 'reword)))

;;;###autoload
(defun magit2-rebase-remove-commit (commit args)
  "Remove a single older commit using rebase."
  (interactive (list (magit2-commit-at-point)
                     (magit2-rebase-arguments)))
  ;; magit2-rebase--perl-editor assumes that the comment character is "#".
  (let ((magit2-git-global-arguments
         (nconc (list "-c" "core.commentChar=#")
                magit2-git-global-arguments)))
    (magit2-rebase-interactive-1 commit args
      "Type %p on a commit to remove it,"
      (apply-partially #'magit2-rebase--perl-editor 'remove)
      nil nil t)))

(defun magit2-rebase--perl-editor (action since)
  (let ((commit (magit2-rev-abbrev (magit2-rebase--target-commit since))))
    (format "%s -i -p -e '++$x if not $x and s/^pick %s/%s %s/'"
            magit2-perl-executable
            commit
            (cl-case action
              (edit   "edit")
              (remove "noop\n# pick")
              (reword "reword")
              (t      (error "unknown action: %s" action)))
            commit)))

;;;###autoload
(defun magit2-rebase-continue (&optional noedit)
  "Restart the current rebasing operation.
In some cases this pops up a commit message buffer for you do
edit.  With a prefix argument the old message is reused as-is."
  (interactive "P")
  (if (magit2-rebase-in-progress-p)
      (if (magit2-anything-unstaged-p t)
          (user-error "Cannot continue rebase with unstaged changes")
        (when (and (magit2-anything-staged-p)
                   (file-exists-p (magit2-git-dir "rebase-merge"))
                   (not (member (magit2-toplevel)
                                magit2--rebase-public-edit-confirmed)))
          (magit2-commit-amend-assert
           (magit2-file-line (magit2-git-dir "rebase-merge/orig-head"))))
        (if noedit
            (let ((process-environment process-environment))
              (push "GIT_EDITOR=true" process-environment)
              (magit2-run-git-async (magit2--rebase-resume-command) "--continue")
              (set-process-sentinel magit2-this-process
                                    #'magit2-sequencer-process-sentinel)
              magit2-this-process)
          (magit2-run-git-sequencer (magit2--rebase-resume-command) "--continue")))
    (user-error "No rebase in progress")))

;;;###autoload
(defun magit2-rebase-skip ()
  "Skip the current commit and restart the current rebase operation."
  (interactive)
  (unless (magit2-rebase-in-progress-p)
    (user-error "No rebase in progress"))
  (magit2-run-git-sequencer (magit2--rebase-resume-command) "--skip"))

;;;###autoload
(defun magit2-rebase-edit ()
  "Edit the todo list of the current rebase operation."
  (interactive)
  (unless (magit2-rebase-in-progress-p)
    (user-error "No rebase in progress"))
  (magit2-run-git-sequencer "rebase" "--edit-todo"))

;;;###autoload
(defun magit2-rebase-abort ()
  "Abort the current rebase operation, restoring the original branch."
  (interactive)
  (unless (magit2-rebase-in-progress-p)
    (user-error "No rebase in progress"))
  (magit2-confirm 'abort-rebase "Abort this rebase")
  (magit2-run-git (magit2--rebase-resume-command) "--abort"))

(defun magit2-rebase-in-progress-p ()
  "Return t if a rebase is in progress."
  (or (file-exists-p (magit2-git-dir "rebase-merge"))
      (file-exists-p (magit2-git-dir "rebase-apply/onto"))))

(defun magit2--rebase-resume-command ()
  (if (file-exists-p (magit2-git-dir "rebase-recursive")) "rbr" "rebase"))

(defun magit2-rebase--get-state-lines (file)
  (and (magit2-rebase-in-progress-p)
       (magit2-file-line
        (magit2-git-dir
         (concat (if (file-directory-p (magit2-git-dir "rebase-merge"))
                     "rebase-merge/"
                   "rebase-apply/")
                 file)))))

;;; Sections

(defun magit2-insert-sequencer-sequence ()
  "Insert section for the on-going cherry-pick or revert sequence.
If no such sequence is in progress, do nothing."
  (let ((picking (magit2-cherry-pick-in-progress-p)))
    (when (or picking (magit2-revert-in-progress-p))
      (magit2-insert-section (sequence)
        (magit2-insert-heading (if picking "Cherry Picking" "Reverting"))
        (when-let ((lines
                    (cdr (magit2-file-lines (magit2-git-dir "sequencer/todo")))))
          (dolist (line (nreverse lines))
            (when (string-match
                   "^\\(pick\\|revert\\) \\([^ ]+\\) \\(.*\\)$" line)
              (magit2-bind-match-strings (cmd hash msg) line
                (magit2-insert-section (commit hash)
                  (insert (propertize cmd 'font-lock-face 'magit2-sequence-pick)
                          " " (propertize hash 'font-lock-face 'magit2-hash)
                          " " msg "\n"))))))
        (magit2-sequence-insert-sequence
         (magit2-file-line (magit2-git-dir (if picking
                                             "CHERRY_PICK_HEAD"
                                           "REVERT_HEAD")))
         (magit2-file-line (magit2-git-dir "sequencer/head")))
        (insert "\n")))))

(defun magit2-insert-am-sequence ()
  "Insert section for the on-going patch applying sequence.
If no such sequence is in progress, do nothing."
  (when (magit2-am-in-progress-p)
    (magit2-insert-section (rebase-sequence)
      (magit2-insert-heading "Applying patches")
      (let ((patches (nreverse (magit2-rebase-patches)))
            patch commit)
        (while patches
          (setq patch (pop patches))
          (setq commit (magit2-rev-hash
                        (cadr (split-string (magit2-file-line patch)))))
          (cond ((and commit patches)
                 (magit2-sequence-insert-commit
                  "pick" commit 'magit2-sequence-pick))
                (patches
                 (magit2-sequence-insert-am-patch
                  "pick" patch 'magit2-sequence-pick))
                (commit
                 (magit2-sequence-insert-sequence commit "ORIG_HEAD"))
                (t
                 (magit2-sequence-insert-am-patch
                  "stop" patch 'magit2-sequence-stop)
                 (magit2-sequence-insert-sequence nil "ORIG_HEAD")))))
      (insert ?\n))))

(defun magit2-sequence-insert-am-patch (type patch face)
  (magit2-insert-section (file patch)
    (let ((title
           (with-temp-buffer
             (insert-file-contents patch nil nil 4096)
             (unless (re-search-forward "^Subject: " nil t)
               (goto-char (point-min)))
             (buffer-substring (point) (line-end-position)))))
      (insert (propertize type 'font-lock-face face)
              ?\s (propertize (file-name-nondirectory patch)
                              'font-lock-face 'magit2-hash)
              ?\s title
              ?\n))))

(defun magit2-insert-rebase-sequence ()
  "Insert section for the on-going rebase sequence.
If no such sequence is in progress, do nothing."
  (when (magit2-rebase-in-progress-p)
    (let* ((interactive (file-directory-p (magit2-git-dir "rebase-merge")))
           (dir  (if interactive "rebase-merge/" "rebase-apply/"))
           (name (thread-first (concat dir "head-name")
                   magit2-git-dir
                   magit2-file-line))
           (onto (thread-first (concat dir "onto")
                   magit2-git-dir
                   magit2-file-line))
           (onto (or (magit2-rev-name onto name)
                     (magit2-rev-name onto "refs/heads/*") onto))
           (name (or (magit2-rev-name name "refs/heads/*") name)))
      (magit2-insert-section (rebase-sequence)
        (magit2-insert-heading (format "Rebasing %s onto %s" name onto))
        (if interactive
            (magit2-rebase-insert-merge-sequence onto)
          (magit2-rebase-insert-apply-sequence onto))
        (insert ?\n)))))

(defun magit2-rebase--todo ()
  "Return `git-rebase-action' instances for remaining rebase actions.
These are ordered in that the same way they'll be sorted in the
status buffer (i.e. the reverse of how they will be applied)."
  (let ((comment-start (or (magit2-get "core.commentChar") "#"))
        lines)
    (with-temp-buffer
      (insert-file-contents (magit2-git-dir "rebase-merge/git-rebase-todo"))
      (while (not (eobp))
        (let ((ln (git-rebase-current-line)))
          (when (oref ln action-type)
            (push ln lines)))
        (forward-line)))
    lines))

(defun magit2-rebase-insert-merge-sequence (onto)
  (dolist (line (magit2-rebase--todo))
    (with-slots (action-type action action-options target) line
      (pcase action-type
        (`commit
         (magit2-sequence-insert-commit action target 'magit2-sequence-pick))
        ((or (or `exec `label)
             (and `merge (guard (not action-options))))
         (insert (propertize action 'font-lock-face 'magit2-sequence-onto) "\s"
                 (propertize target 'font-lock-face 'git-rebase-label) "\n"))
        (`merge
         (if-let ((hash (and (string-match "-[cC] \\([^ ]+\\)" action-options)
                             (match-string 1 action-options))))
             (magit2-insert-section (commit hash)
               (magit2-insert-heading
                 (propertize "merge" 'font-lock-face 'magit2-sequence-pick)
                 "\s"
                 (magit2-format-rev-summary hash) "\n"))
           (error "failed to parse merge message hash"))))))
  (magit2-sequence-insert-sequence
   (magit2-file-line (magit2-git-dir "rebase-merge/stopped-sha"))
   onto
   (--when-let (magit2-file-lines (magit2-git-dir "rebase-merge/done"))
     (cadr (split-string (car (last it)))))))

(defun magit2-rebase-insert-apply-sequence (onto)
  (let ((rewritten
         (--map (car (split-string it))
                (magit2-file-lines (magit2-git-dir "rebase-apply/rewritten"))))
        (stop (magit2-file-line (magit2-git-dir "rebase-apply/original-commit"))))
    (dolist (patch (nreverse (cdr (magit2-rebase-patches))))
      (let ((hash (cadr (split-string (magit2-file-line patch)))))
        (unless (or (member hash rewritten)
                    (equal hash stop))
          (magit2-sequence-insert-commit "pick" hash 'magit2-sequence-pick)))))
  (magit2-sequence-insert-sequence
   (magit2-file-line (magit2-git-dir "rebase-apply/original-commit"))
   onto))

(defun magit2-rebase-patches ()
  (directory-files (magit2-git-dir "rebase-apply") t "^[0-9]\\{4\\}$"))

(defun magit2-sequence-insert-sequence (stop onto &optional orig)
  (let ((head (magit2-rev-parse "HEAD")) done)
    (setq onto (if onto (magit2-rev-parse onto) head))
    (setq done (magit2-git-lines "log" "--format=%H" (concat onto "..HEAD")))
    (when (and stop (not (member (magit2-rev-parse stop) done)))
      (let ((id (magit2-patch-id stop)))
        (--if-let (--first (equal (magit2-patch-id it) id) done)
            (setq stop it)
          (cond
           ((--first (magit2-rev-equal it stop) done)
            ;; The commit's testament has been executed.
            (magit2-sequence-insert-commit "void" stop 'magit2-sequence-drop))
           ;; The faith of the commit is still undecided...
           ((magit2-anything-unmerged-p)
            ;; ...and time travel isn't for the faint of heart.
            (magit2-sequence-insert-commit "join" stop 'magit2-sequence-part))
           ((magit2-anything-modified-p t)
            ;; ...and the dust hasn't settled yet...
            (magit2-sequence-insert-commit
             (let* ((magit2--refresh-cache nil)
                    (staged   (magit2-commit-tree "oO" nil "HEAD"))
                    (unstaged (magit2-commit-worktree "oO" "--reset")))
               (cond
                ;; ...but we could end up at the same tree just by committing.
                ((or (magit2-rev-equal staged   stop)
                     (magit2-rev-equal unstaged stop)) "goal")
                ;; ...but the changes are still there, untainted.
                ((or (equal (magit2-patch-id staged)   id)
                     (equal (magit2-patch-id unstaged) id)) "same")
                ;; ...and some changes are gone and/or others were added.
                (t "work")))
             stop 'magit2-sequence-part))
           ;; The commit is definitely gone...
           ((--first (magit2-rev-equal it stop) done)
            ;; ...but all of its changes are still in effect.
            (magit2-sequence-insert-commit "poof" stop 'magit2-sequence-drop))
           (t
            ;; ...and some changes are gone and/or other changes were added.
            (magit2-sequence-insert-commit "gone" stop 'magit2-sequence-drop)))
          (setq stop nil))))
    (dolist (rev done)
      (apply 'magit2-sequence-insert-commit
             (cond ((equal rev stop)
                    ;; ...but its reincarnation lives on.
                    ;; Or it didn't die in the first place.
                    (list (if (and (equal rev head)
                                   (equal (magit2-patch-id rev)
                                          (magit2-patch-id orig)))
                              "stop" ; We haven't done anything yet.
                            "like")  ; There are new commits.
                          rev (if (equal rev head)
                                  'magit2-sequence-head
                                'magit2-sequence-stop)))
                   ((equal rev head)
                    (list "done" rev 'magit2-sequence-head))
                   (t
                    (list "done" rev 'magit2-sequence-done)))))
    (magit2-sequence-insert-commit "onto" onto
                                  (if (equal onto head)
                                      'magit2-sequence-head
                                    'magit2-sequence-onto))))

(defun magit2-sequence-insert-commit (type hash face)
  (magit2-insert-section (commit hash)
    (magit2-insert-heading
      (propertize type 'font-lock-face face)    "\s"
      (magit2-format-rev-summary hash) "\n")))

;;; _
(provide 'magit2-sequence)
;;; magit2-sequence.el ends here
