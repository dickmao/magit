;;; magit2-commit.el --- create Git commits  -*- lexical-binding: t -*-

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

;; This library implements commands for creating Git commits.  These
;; commands just initiate the commit, support for writing the commit
;; messages is implemented in `git-commit.el'.

;;; Code:

(require 'magit2)
(require 'magit2-sequence)

(eval-when-compile (require 'epa)) ; for `epa-protocol'
(eval-when-compile (require 'epg))

;;; Options

(defcustom magit2-commit-ask-to-stage 'verbose
  "Whether to ask to stage everything when committing and nothing is staged."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-commands
  :type '(choice (const :tag "Ask" t)
                 (const :tag "Ask showing diff" verbose)
                 (const :tag "Stage without confirmation" stage)
                 (const :tag "Don't ask" nil)))

(defcustom magit2-commit-show-diff t
  "Whether the relevant diff is automatically shown when committing."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-commit-extend-override-date t
  "Whether using `magit2-commit-extend' changes the committer date."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-commit-reword-override-date t
  "Whether using `magit2-commit-reword' changes the committer date."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-commit-squash-confirm t
  "Whether the commit targeted by squash and fixup has to be confirmed.
When non-nil then the commit at point (if any) is used as default
choice, otherwise it has to be confirmed.  This option only
affects `magit2-commit-squash' and `magit2-commit-fixup'.  The
\"instant\" variants always require confirmation because making
an error while using those is harder to recover from."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-post-commit-hook nil
  "Hook run after creating a commit without the user editing a message.

This hook is run by `magit2-refresh' if `this-command' is a member
of `magit2-post-stage-hook-commands'.  This only includes commands
named `magit2-commit-*' that do *not* require that the user edits
the commit message in a buffer and then finishes by pressing
\\<with-editor-mode-map>\\[with-editor-finish].

Also see `git-commit-post-finish-hook'."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-commands
  :type 'hook)

(defcustom magit2-commit-diff-inhibit-same-window nil
  "Whether to inhibit use of same window when showing diff while committing.

When writing a commit, then a diff of the changes to be committed
is automatically shown.  The idea is that the diff is shown in a
different window of the same frame and for most users that just
works.  In other words most users can completely ignore this
option because its value doesn't make a difference for them.

However for users who configured Emacs to never create a new
window even when the package explicitly tries to do so, then
displaying two new buffers necessarily means that the first is
immediately replaced by the second.  In our case the message
buffer is immediately replaced by the diff buffer, which is of
course highly undesirable.

A workaround is to suppress this user configuration in this
particular case.  Users have to explicitly opt-in by toggling
this option.  We cannot enable the workaround unconditionally
because that again causes issues for other users: if the frame
is too tiny or the relevant settings too aggressive, then the
diff buffer would end up being displayed in a new frame.

Also see https://github.com/magit2/magit2/issues/4132."
  :package-version '(magit2 . "3.3.0")
  :group 'magit2-commands
  :type 'boolean)

(defvar magit2-post-commit-hook-commands
  '(magit2-commit-extend
    magit2-commit-fixup
    magit2-commit-augment
    magit2-commit-instant-fixup
    magit2-commit-instant-squash))

;;; Popup

;;;###autoload (autoload 'magit2-commit "magit2-commit" nil t)
(transient-define-prefix magit2-commit ()
  "Create a new commit or replace an existing commit."
  :info-manual "(magit2)Initiating a Commit"
  :man-page "git-commit"
  ["Arguments"
   ("-a" "Stage all modified and deleted files"   ("-a" "--all"))
   ("-e" "Allow empty commit"                     "--allow-empty")
   ("-v" "Show diff of changes to be committed"   ("-v" "--verbose"))
   ("-n" "Disable hooks"                          ("-n" "--no-verify"))
   ("-R" "Claim authorship and reset author date" "--reset-author")
   (magit2:--author :description "Override the author")
   (7 "-D" "Override the author date" "--date=" transient-read-date)
   ("-s" "Add Signed-off-by line"                 ("-s" "--signoff"))
   (5 magit2:--gpg-sign)
   (magit2-commit:--reuse-message)]
  [["Create"
    ("c" "Commit"         magit2-commit-create)]
   ["Edit HEAD"
    ("e" "Extend"         magit2-commit-extend)
    ("w" "Reword"         magit2-commit-reword)
    ("a" "Amend"          magit2-commit-amend)
    (6 "n" "Reshelve"     magit2-commit-reshelve)]
   ["Edit"
    ("f" "Fixup"          magit2-commit-fixup)
    ("s" "Squash"         magit2-commit-squash)
    ("A" "Augment"        magit2-commit-augment)
    (6 "x" "Absorb changes" magit2-commit-autofixup)
    (6 "X" "Absorb modules" magit2-commit-absorb-modules)]
   [""
    ("F" "Instant fixup"  magit2-commit-instant-fixup)
    ("S" "Instant squash" magit2-commit-instant-squash)]]
  (interactive)
  (if-let ((buffer (magit2-commit-message-buffer)))
      (switch-to-buffer buffer)
    (transient-setup 'magit2-commit)))

(defun magit2-commit-arguments nil
  (transient-args 'magit2-commit))

(transient-define-argument magit2:--gpg-sign ()
  :description "Sign using gpg"
  :class 'transient-option
  :shortarg "-S"
  :argument "--gpg-sign="
  :allow-empty t
  :reader 'magit2-read-gpg-signing-key)

(defvar magit2-gpg-secret-key-hist nil)

(defun magit2-read-gpg-secret-key
    (prompt &optional initial-input history predicate)
  (require 'epa)
  (let* ((keys (cl-mapcan
                (lambda (cert)
                  (and (or (not predicate)
                           (funcall predicate cert))
                       (let* ((key (car (epg-key-sub-key-list cert)))
                              (fpr (epg-sub-key-fingerprint key))
                              (id  (epg-sub-key-id key))
                              (author
                               (when-let ((id-obj
                                           (car (epg-key-user-id-list cert))))
                                 (let ((id-str (epg-user-id-string id-obj)))
                                   (if (stringp id-str)
                                       id-str
                                     (epg-decode-dn id-obj))))))
                         (list
                          (propertize fpr 'display
                                      (concat (substring fpr 0 (- (length id)))
                                              (propertize id 'face 'highlight)
                                              " " author))))))
                (epg-list-keys (epg-make-context epa-protocol) nil t)))
         (choice (completing-read prompt keys nil nil nil
                                  history nil initial-input)))
    (set-text-properties 0 (length choice) nil choice)
    choice))

(defun magit2-read-gpg-signing-key (prompt &optional initial-input history)
  (magit2-read-gpg-secret-key
   prompt initial-input history
   (lambda (cert)
     (cl-some (lambda (key)
                (memq 'sign (epg-sub-key-capability key)))
              (epg-key-sub-key-list cert)))))

(transient-define-argument magit2-commit:--reuse-message ()
  :description "Reuse commit message"
  :class 'transient-option
  :shortarg "-C"
  :argument "--reuse-message="
  :reader 'magit2-read-reuse-message
  :history-key 'magit2-revision-history)

(defun magit2-read-reuse-message (prompt &optional default history)
  (magit2-completing-read prompt (magit2-list-refnames)
                         nil nil nil history
                         (or default
                             (and (magit2-rev-parse "ORIG_HEAD")
                                  "ORIG_HEAD"))))

;;; Commands

;;;###autoload
(defun magit2-commit-create (&optional args)
  "Create a new commit on `HEAD'.
With a prefix argument, amend to the commit at `HEAD' instead.
\n(git commit [--amend] ARGS)"
  (interactive (if current-prefix-arg
                   (list (cons "--amend" (magit2-commit-arguments)))
                 (list (magit2-commit-arguments))))
  (when (member "--all" args)
    (setq this-command 'magit2-commit-all))
  (when (setq args (magit2-commit-assert args))
    (let ((default-directory (magit2-toplevel)))
      (magit2-run-git-with-editor "commit" args))))

;;;###autoload
(defun magit2-commit-amend (&optional args)
  "Amend the last commit.
\n(git commit --amend ARGS)"
  (interactive (list (magit2-commit-arguments)))
  (magit2-commit-amend-assert)
  (magit2-run-git-with-editor "commit" "--amend" args))

;;;###autoload
(defun magit2-commit-extend (&optional args override-date)
  "Amend the last commit, without editing the message.

With a prefix argument keep the committer date, otherwise change
it.  The option `magit2-commit-extend-override-date' can be used
to inverse the meaning of the prefix argument.  \n(git commit
--amend --no-edit)"
  (interactive (list (magit2-commit-arguments)
                     (if current-prefix-arg
                         (not magit2-commit-extend-override-date)
                       magit2-commit-extend-override-date)))
  (when (setq args (magit2-commit-assert args))
    (magit2-commit-amend-assert)
    (let ((process-environment process-environment))
      (unless override-date
        (push (magit2-rev-format "GIT_COMMITTER_DATE=%cD") process-environment))
      (magit2-run-git-with-editor "commit" "--amend" "--no-edit" args))))

;;;###autoload
(defun magit2-commit-reword (&optional args override-date)
  "Reword the last commit, ignoring staged changes.

With a prefix argument keep the committer date, otherwise change
it.  The option `magit2-commit-reword-override-date' can be used
to inverse the meaning of the prefix argument.

Non-interactively respect the optional OVERRIDE-DATE argument
and ignore the option.
\n(git commit --amend --only)"
  (interactive (list (magit2-commit-arguments)
                     (if current-prefix-arg
                         (not magit2-commit-reword-override-date)
                       magit2-commit-reword-override-date)))
  (magit2-commit-amend-assert)
  (let ((process-environment process-environment))
    (unless override-date
      (push (magit2-rev-format "GIT_COMMITTER_DATE=%cD") process-environment))
    (cl-pushnew "--allow-empty" args :test #'equal)
    (magit2-run-git-with-editor "commit" "--amend" "--only" args)))

;;;###autoload
(defun magit2-commit-fixup (&optional commit args)
  "Create a fixup commit.

With a prefix argument the target COMMIT has to be confirmed.
Otherwise the commit at point may be used without confirmation
depending on the value of option `magit2-commit-squash-confirm'."
  (interactive (list (magit2-commit-at-point)
                     (magit2-commit-arguments)))
  (magit2-commit-squash-internal "--fixup" commit args))

;;;###autoload
(defun magit2-commit-squash (&optional commit args)
  "Create a squash commit, without editing the squash message.

With a prefix argument the target COMMIT has to be confirmed.
Otherwise the commit at point may be used without confirmation
depending on the value of option `magit2-commit-squash-confirm'.

If you want to immediately add a message to the squash commit,
then use `magit2-commit-augment' instead of this command."
  (interactive (list (magit2-commit-at-point)
                     (magit2-commit-arguments)))
  (magit2-commit-squash-internal "--squash" commit args))

;;;###autoload
(defun magit2-commit-augment (&optional commit args)
  "Create a squash commit, editing the squash message.

With a prefix argument the target COMMIT has to be confirmed.
Otherwise the commit at point may be used without confirmation
depending on the value of option `magit2-commit-squash-confirm'."
  (interactive (list (magit2-commit-at-point)
                     (magit2-commit-arguments)))
  (magit2-commit-squash-internal "--squash" commit args nil t))

;;;###autoload
(defun magit2-commit-instant-fixup (&optional commit args)
  "Create a fixup commit targeting COMMIT and instantly rebase."
  (interactive (list (magit2-commit-at-point)
                     (magit2-commit-arguments)))
  (magit2-commit-squash-internal "--fixup" commit args t))

;;;###autoload
(defun magit2-commit-instant-squash (&optional commit args)
  "Create a squash commit targeting COMMIT and instantly rebase."
  (interactive (list (magit2-commit-at-point)
                     (magit2-commit-arguments)))
  (magit2-commit-squash-internal "--squash" commit args t))

(defun magit2-commit-squash-internal
    (option commit &optional args rebase edit confirmed)
  (when-let ((args (magit2-commit-assert args (not edit))))
    (when commit
      (when (and rebase (not (magit2-rev-ancestor-p commit "HEAD")))
        (magit2-read-char-case
            (format "%s isn't an ancestor of HEAD.  " commit) nil
          (?c "[c]reate without rebasing" (setq rebase nil))
          (?s "[s]elect other"            (setq commit nil))
          (?a "[a]bort"                   (user-error "Quit")))))
    (when commit
      (setq commit (magit2-rebase-interactive-assert commit t)))
    (if (and commit
             (or confirmed
                 (not (or rebase
                          current-prefix-arg
                          magit2-commit-squash-confirm))))
        (let ((magit2-commit-show-diff nil))
          (push (concat option "=" commit) args)
          (unless edit
            (push "--no-edit" args))
          (if rebase
              (magit2-with-editor
                (magit2-call-git
                 "commit" "--no-gpg-sign"
                 (-remove-first
                  (apply-partially #'string-match-p "\\`--gpg-sign=")
                  args)))
            (magit2-run-git-with-editor "commit" args))
          t) ; The commit was created; used by below lambda.
      (magit2-log-select
        (lambda (commit)
          (when (and (magit2-commit-squash-internal option commit args
                                                   rebase edit t)
                     rebase)
            (magit2-commit-amend-assert commit)
            (magit2-rebase-interactive-1 commit
                (list "--autosquash" "--autostash" "--keep-empty")
              "" "true" nil t)))
        (format "Type %%p on a commit to %s into it,"
                (substring option 2))
        nil nil nil commit)
      (when magit2-commit-show-diff
        (let ((magit2-display-buffer-noselect t))
          (apply #'magit2-diff-staged nil (magit2-diff-arguments)))))))

(defun magit2-commit-amend-assert (&optional commit)
  (--when-let (magit2-list-publishing-branches commit)
    (let ((m1 "This commit has already been published to ")
          (m2 ".\nDo you really want to modify it"))
      (magit2-confirm 'amend-published
        (concat m1 "%s" m2)
        (concat m1 "%i public branches" m2)
        nil it))))

(defun magit2-commit-assert (args &optional strict)
  (cond
   ((or (magit2-anything-staged-p)
        (and (magit2-anything-unstaged-p)
             ;; ^ Everything of nothing is still nothing.
             (member "--all" args))
        (and (not strict)
             ;; ^ For amend variants that don't make sense otherwise.
             (or (member "--amend" args)
                 (member "--allow-empty" args)
                 (member "--reset-author" args)
                 (member "--signoff" args)
                 (transient-arg-value "--author=" args)
                 (transient-arg-value "--date=" args))))
    (or args (list "--")))
   ((and (magit2-rebase-in-progress-p)
         (not (magit2-anything-unstaged-p))
         (y-or-n-p "Nothing staged.  Continue in-progress rebase? "))
    (setq this-command 'magit2-rebase-continue)
    (magit2-run-git-sequencer "rebase" "--continue")
    nil)
   ((and (file-exists-p (magit2-git-dir "MERGE_MSG"))
         (not (magit2-anything-unstaged-p)))
    (or args (list "--")))
   ((not (magit2-anything-unstaged-p))
    (user-error "Nothing staged (or unstaged)"))
   (magit2-commit-ask-to-stage
    (when (eq magit2-commit-ask-to-stage 'verbose)
      (magit2-diff-unstaged))
    (prog1 (when (or (eq magit2-commit-ask-to-stage 'stage)
                     (y-or-n-p "Nothing staged.  Stage and commit all unstaged changes? "))
             (magit2-run-git "add" "-u" ".")
             (or args (list "--")))
      (when (and (eq magit2-commit-ask-to-stage 'verbose)
                 (derived-mode-p 'magit2-diff-mode))
        (magit2-mode-bury-buffer))))
   (t
    (user-error "Nothing staged"))))

(defvar magit2--reshelve-history nil)

;;;###autoload
(defun magit2-commit-reshelve (date update-author &optional args)
  "Change the committer date and possibly the author date of `HEAD'.

The current time is used as the initial minibuffer input and the
original author or committer date is available as the previous
history element.

Both the author and the committer dates are changes, unless one
of the following is true, in which case only the committer date
is updated:
- You are not the author of the commit that is being reshelved.
- The command was invoked with a prefix argument.
- Non-interactively if UPDATE-AUTHOR is nil."
  (interactive
   (let ((update-author (and (magit2-rev-author-p "HEAD")
                             (not current-prefix-arg))))
     (push (magit2-rev-format (if update-author "%ad" "%cd") "HEAD"
                             (concat "--date=format:%F %T %z"))
           magit2--reshelve-history)
     (list (read-string (if update-author
                            "Change author and committer dates to: "
                          "Change committer date to: ")
                        (cons (format-time-string "%F %T %z") 17)
                        'magit2--reshelve-history)
           update-author
           (magit2-commit-arguments))))
  (let ((process-environment process-environment))
    (push (concat "GIT_COMMITTER_DATE=" date) process-environment)
    (magit2-run-git "commit" "--amend" "--no-edit"
                   (and update-author (concat "--date=" date))
                   args)))

;;;###autoload
(defun magit2-commit-absorb-modules (phase commit)
  "Spread modified modules across recent commits."
  (interactive (list 'select (magit2-get-upstream-branch)))
  (let ((modules (magit2-list-modified-modules)))
    (unless modules
      (user-error "There are no modified modules that could be absorbed"))
    (when commit
      (setq commit (magit2-rebase-interactive-assert commit t)))
    (if (and commit (eq phase 'run))
        (progn
          (dolist (module modules)
            (when-let ((msg (magit2-git-string
                             "log" "-1" "--format=%s"
                             (concat commit "..") "--" module)))
              (magit2-git "commit" "-m" (concat "fixup! " msg)
                         "--only" "--" module)))
          (magit2-refresh)
          t)
      (magit2-log-select
        (lambda (commit)
          (magit2-commit-absorb-modules 'run commit))
        nil nil nil nil commit))))

;;;###autoload (autoload 'magit2-commit-absorb "magit2-commit" nil t)
(transient-define-prefix magit2-commit-absorb (phase commit args)
  "Spread staged changes across recent commits.
With a prefix argument use a transient command to select infix
arguments.  This command requires git-absorb executable, which
is available from https://github.com/tummychow/git-absorb.
See `magit2-commit-autofixup' for an alternative implementation."
  ["Arguments"
   ("-f" "Skip safety checks"       ("-f" "--force"))
   ("-v" "Display more output"      ("-v" "--verbose"))]
  ["Actions"
   ("x"  "Absorb" magit2-commit-absorb)]
  (interactive (if current-prefix-arg
                   (list 'transient nil nil)
                 (list 'select
                       (magit2-get-upstream-branch)
                       (transient-args 'magit2-commit-absorb))))
  (if (eq phase 'transient)
      (transient-setup 'magit2-commit-absorb)
    (unless (executable-find "git-absorb")
      (user-error "This command requires the git-absorb executable, which %s"
                  "is available from https://github.com/tummychow/git-absorb"))
    (unless (magit2-anything-staged-p)
      (if (magit2-anything-unstaged-p)
          (if (y-or-n-p "Nothing staged.  Absorb all unstaged changes? ")
              (magit2-with-toplevel
                (magit2-run-git "add" "-u" "."))
            (user-error "Abort"))
        (user-error "There are no changes that could be absorbed")))
    (when commit
      (setq commit (magit2-rebase-interactive-assert commit t)))
    (if (and commit (eq phase 'run))
        (progn (magit2-run-git-async "absorb" "-v" args "-b" commit) t)
      (magit2-log-select
        (lambda (commit)
          (with-no-warnings ; about non-interactive use
            (magit2-commit-absorb 'run commit args)))
        nil nil nil nil commit))))

;;;###autoload (autoload 'magit2-commit-autofixup "magit2-commit" nil t)
(transient-define-prefix magit2-commit-autofixup (phase commit args)
  "Spread staged or unstaged changes across recent commits.

If there are any staged then spread only those, otherwise
spread all unstaged changes. With a prefix argument use a
transient command to select infix arguments.

This command requires the git-autofixup script, which is
available from https://github.com/torbiak/git-autofixup.
See `magit2-commit-absorb' for an alternative implementation."
  ["Arguments"
   (magit2-autofixup:--context)
   (magit2-autofixup:--strict)]
  ["Actions"
   ("x"  "Absorb" magit2-commit-autofixup)]
  (interactive (if current-prefix-arg
                   (list 'transient nil nil)
                 (list 'select
                       (magit2-get-upstream-branch)
                       (transient-args 'magit2-commit-autofixup))))
  (if (eq phase 'transient)
      (transient-setup 'magit2-commit-autofixup)
    (unless (executable-find "git-autofixup")
      (user-error "This command requires the git-autofixup script, which %s"
                  "is available from https://github.com/torbiak/git-autofixup"))
    (unless (magit2-anything-modified-p)
      (user-error "There are no changes that could be absorbed"))
    (when commit
      (setq commit (magit2-rebase-interactive-assert commit t)))
    (if (and commit (eq phase 'run))
        (progn (magit2-run-git-async "autofixup" "-vv" args commit) t)
      (magit2-log-select
        (lambda (commit)
          (with-no-warnings ; about non-interactive use
            (magit2-commit-autofixup 'run commit args)))
        nil nil nil nil commit))))

(transient-define-argument magit2-autofixup:--context ()
  :description "Diff context lines"
  :class 'transient-option
  :shortarg "-c"
  :argument "--context="
  :reader 'transient-read-number-N0)

(transient-define-argument magit2-autofixup:--strict ()
  :description "Strictness"
  :class 'transient-option
  :shortarg "-s"
  :argument "--strict="
  :reader 'transient-read-number-N0)

;;; Pending Diff

(defun magit2-commit-diff ()
  (when (and git-commit-mode magit2-commit-show-diff)
    (when-let ((diff-buffer (magit2-get-mode-buffer 'magit2-diff-mode)))
      ;; This window just started displaying the commit message
      ;; buffer.  Without this that buffer would immediately be
      ;; replaced with the diff buffer.  See #2632.
      (unrecord-window-buffer nil diff-buffer))
    (condition-case nil
        (let ((args (car (magit2-diff-arguments)))
              (magit2-inhibit-save-previous-winconf 'unset)
              (magit2-display-buffer-noselect t)
              (inhibit-quit nil)
              (display-buffer-overriding-action
               display-buffer-overriding-action))
          (when magit2-commit-diff-inhibit-same-window
            (setq display-buffer-overriding-action
                  '(nil (inhibit-same-window t))))
          (message "Diffing changes to be committed (C-g to abort diffing)")
          (cl-case last-command
            (magit2-commit
             (magit2-diff-staged nil args))
            (magit2-commit-all
             (magit2-diff-working-tree nil args))
            ((magit2-commit-amend
              magit2-commit-reword
              magit2-rebase-reword-commit)
             (magit2-diff-while-amending args))
            (t (if (magit2-anything-staged-p)
                   (magit2-diff-staged nil args)
                 (magit2-diff-while-amending args)))))
      (quit))))

;; Mention `magit2-diff-while-committing' because that's
;; always what I search for when I try to find this line.
(add-hook 'server-switch-hook 'magit2-commit-diff)
(add-hook 'with-editor-filter-visit-hook 'magit2-commit-diff)

(add-to-list 'with-editor-server-window-alist
             (cons git-commit-filename-regexp 'switch-to-buffer))

;;; Message Utilities

(defun magit2-commit-message-buffer ()
  (let* ((find-file-visit-truename t) ; git uses truename of COMMIT_EDITMSG
         (topdir (magit2-toplevel)))
    (--first (equal topdir (with-current-buffer it
                             (and git-commit-mode (magit2-toplevel))))
             (append (buffer-list (selected-frame))
                     (buffer-list)))))

(defvar magit2-commit-add-log-insert-function 'magit2-commit-add-log-insert
  "Used by `magit2-commit-add-log' to insert a single entry.")

(defun magit2-commit-add-log ()
  "Add a stub for the current change into the commit message buffer.
If no commit is in progress, then initiate it.  Use the function
specified by variable `magit2-commit-add-log-insert-function' to
actually insert the entry."
  (interactive)
  (pcase-let* ((hunk (and (magit2-section-match 'hunk)
                          (magit2-current-section)))
               (log  (magit2-commit-message-buffer))
               (`(,buf ,pos) (magit2-diff-visit-file--noselect)))
    (unless log
      (unless (magit2-commit-assert nil)
        (user-error "Abort"))
      (magit2-commit-create)
      (while (not (setq log (magit2-commit-message-buffer)))
        (sit-for 0.01)))
    (magit2--with-temp-position buf pos
      (funcall magit2-commit-add-log-insert-function log
               (magit2-file-relative-name)
               (and hunk (add-log-current-defun))))))

(defun magit2-commit-add-log-insert (buffer file defun)
  (with-current-buffer buffer
    (undo-boundary)
    (goto-char (point-max))
    (while (re-search-backward (concat "^" comment-start) nil t))
    (save-restriction
      (narrow-to-region (point-min) (point))
      (cond ((re-search-backward (format "* %s\\(?: (\\([^)]+\\))\\)?: " file)
                                 nil t)
             (when (equal (match-string 1) defun)
               (setq defun nil))
             (re-search-forward ": "))
            (t
             (when (re-search-backward "^[\\*(].+\n" nil t)
               (goto-char (match-end 0)))
             (while (re-search-forward "^[^\\*\n].*\n" nil t))
             (if defun
                 (progn (insert (format "* %s (%s): \n" file defun))
                        (setq defun nil))
               (insert (format "* %s: \n" file)))
             (backward-char)
             (unless (looking-at "\n[\n\\']")
               (insert ?\n)
               (backward-char))))
      (when defun
        (forward-line)
        (let ((limit (save-excursion
                       (and (re-search-forward "^\\*" nil t)
                            (point)))))
          (unless (or (looking-back (format "(%s): " defun)
                                    (line-beginning-position))
                      (re-search-forward (format "^(%s): " defun) limit t))
            (while (re-search-forward "^[^\\*\n].*\n" limit t))
            (insert (format "(%s): \n" defun))
            (backward-char)))))))

;;; _
(provide 'magit2-commit)
;;; magit2-commit.el ends here
