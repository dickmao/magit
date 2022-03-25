;;; magit2-status.el --- the grand overview  -*- lexical-binding: t -*-

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

;; This library implements the status buffer.

;;; Code:

(require 'magit2)

;;; Options

(defgroup magit2-status nil
  "Inspect and manipulate Git repositories."
  :link '(info-link "(magit2)Status Buffer")
  :group 'magit2-modes)

(defcustom magit2-status-mode-hook nil
  "Hook run after entering Magit-Status mode."
  :group 'magit2-status
  :type 'hook)

(defcustom magit2-status-headers-hook
  '(magit2-insert-error-header
    magit2-insert-diff-filter-header
    magit2-insert-head-branch-header
    magit2-insert-upstream-branch-header
    magit2-insert-push-branch-header
    magit2-insert-tags-header)
  "Hook run to insert headers into the status buffer.

This hook is run by `magit2-insert-status-headers', which in turn
has to be a member of `magit2-status-sections-hook' to be used at
all."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-status
  :type 'hook
  :options '(magit2-insert-error-header
             magit2-insert-diff-filter-header
             magit2-insert-repo-header
             magit2-insert-remote-header
             magit2-insert-head-branch-header
             magit2-insert-upstream-branch-header
             magit2-insert-push-branch-header
             magit2-insert-tags-header))

(defcustom magit2-status-sections-hook
  '(magit2-insert-status-headers
    magit2-insert-merge-log
    magit2-insert-rebase-sequence
    magit2-insert-am-sequence
    magit2-insert-sequencer-sequence
    magit2-insert-bisect-output
    magit2-insert-bisect-rest
    magit2-insert-bisect-log
    magit2-insert-untracked-files
    magit2-insert-unstaged-changes
    magit2-insert-staged-changes
    magit2-insert-stashes
    magit2-insert-unpushed-to-pushremote
    magit2-insert-unpushed-to-upstream-or-recent
    magit2-insert-unpulled-from-pushremote
    magit2-insert-unpulled-from-upstream)
  "Hook run to insert sections into a status buffer."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-status
  :type 'hook)

(defcustom magit2-status-initial-section '(1)
  "The section point is placed on when a status buffer is created.

When such a buffer is merely being refreshed or being shown again
after it was merely buried, then this option has no effect.

If this is nil, then point remains on the very first section as
usual.  Otherwise it has to be a list of integers and section
identity lists.  The members of that list are tried in order
until a matching section is found.

An integer means to jump to the nth section, 1 for example
jumps over the headings.  To get a section's \"identity list\"
use \\[universal-argument] \\[magit2-describe-section-briefly].

If, for example, you want to jump to the commits that haven't
been pulled from the upstream, or else the second section, then
use: (((unpulled . \"..@{upstream}\") (status)) 1).

See option `magit2-section-initial-visibility-alist' for how to
control the initial visibility of the jumped to section."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-status
  :type '(choice (const :tag "as usual" nil)
                 (repeat (choice (number :tag "nth top-level section")
                                 (sexp   :tag "section identity")))))

(defcustom magit2-status-goto-file-position nil
  "Whether to go to position corresponding to file position.

If this is non-nil and the current buffer is visiting a file,
then `magit2-status' tries to go to the position in the status
buffer that corresponds to the position in the file-visiting
buffer.  This jumps into either the diff of unstaged changes
or the diff of staged changes.

If the previously current buffer does not visit a file, or if
the file has neither unstaged nor staged changes then this has
no effect.

The command `magit2-status-here' tries to go to that position,
regardless of the value of this option."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-status
  :type 'boolean)

(defcustom magit2-status-show-hashes-in-headers nil
  "Whether headers in the status buffer show hashes.
The functions which respect this option are
`magit2-insert-head-branch-header',
`magit2-insert-upstream-branch-header', and
`magit2-insert-push-branch-header'."
  :package-version '(magit2 . "2.4.0")
  :group 'magit2-status
  :type 'boolean)

(defcustom magit2-status-margin
  (list nil
        (nth 1 magit2-log-margin)
        'magit2-log-margin-width nil
        (nth 4 magit2-log-margin))
  "Format of the margin in `magit2-status-mode' buffers.

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
  :group 'magit2-status
  :group 'magit2-margin
  :type magit2-log-margin--custom-type
  :initialize 'magit2-custom-initialize-reset
  :set-after '(magit2-log-margin)
  :set (apply-partially #'magit2-margin-set-variable 'magit2-status-mode))

(defcustom magit2-status-use-buffer-arguments 'selected
  "Whether `magit2-status' reuses arguments when the buffer already exists.

This option has no effect when merely refreshing the status
buffer using `magit2-refresh'.

Valid values are:

`always': Always use the set of arguments that is currently
  active in the status buffer, provided that buffer exists
  of course.
`selected': Use the set of arguments from the status
  buffer, but only if it is displayed in a window of the
  current frame.  This is the default.
`current': Use the set of arguments from the status buffer,
  but only if it is the current buffer.
`never': Never use the set of arguments from the status
  buffer."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-buffers
  :group 'magit2-commands
  :type '(choice
          (const :tag "always use args from buffer" always)
          (const :tag "use args from buffer if displayed in frame" selected)
          (const :tag "use args from buffer if it is current" current)
          (const :tag "never use args from buffer" never)))

;;; Commands

;;;###autoload
(defun magit2-init (directory)
  "Initialize a Git repository, then show its status.

If the directory is below an existing repository, then the user
has to confirm that a new one should be created inside.  If the
directory is the root of the existing repository, then the user
has to confirm that it should be reinitialized.

Non-interactively DIRECTORY is (re-)initialized unconditionally."
  (interactive
   (let ((directory (file-name-as-directory
                     (expand-file-name
                      (read-directory-name "Create repository in: ")))))
     (when-let ((toplevel (magit2-toplevel directory)))
       (setq toplevel (expand-file-name toplevel))
       (unless (y-or-n-p (if (file-equal-p toplevel directory)
                             (format "Reinitialize existing repository %s? "
                                     directory)
                           (format "%s is a repository.  Create another in %s? "
                                   toplevel directory)))
         (user-error "Abort")))
     (list directory)))
  ;; `git init' does not understand the meaning of "~"!
  (magit2-call-git "init" (magit2-convert-filename-for-git
                          (expand-file-name directory)))
  (magit2-status-setup-buffer directory))

;;;###autoload
(defun magit2-status (&optional directory cache)
  "Show the status of the current Git repository in a buffer.

If the current directory isn't located within a Git repository,
then prompt for an existing repository or an arbitrary directory,
depending on option `magit2-repository-directories', and show the
status of the selected repository instead.

* If that option specifies any existing repositories, then offer
  those for completion and show the status buffer for the
  selected one.

* Otherwise read an arbitrary directory using regular file-name
  completion.  If the selected directory is the top-level of an
  existing working tree, then show the status buffer for that.

* Otherwise offer to initialize the selected directory as a new
  repository.  After creating the repository show its status
  buffer.

These fallback behaviors can also be forced using one or more
prefix arguments:

* With two prefix arguments (or more precisely a numeric prefix
  value of 16 or greater) read an arbitrary directory and act on
  it as described above.  The same could be accomplished using
  the command `magit2-init'.

* With a single prefix argument read an existing repository, or
  if none can be found based on `magit2-repository-directories',
  then fall back to the same behavior as with two prefix
  arguments."
  (interactive
   (let ((magit2--refresh-cache (list (cons 0 0))))
     (list (and (or current-prefix-arg (not (magit2-toplevel)))
                (progn (magit2--assert-usable-git)
                       (magit2-read-repository
                        (>= (prefix-numeric-value current-prefix-arg) 16))))
           magit2--refresh-cache)))
  (let ((magit2--refresh-cache (or cache (list (cons 0 0)))))
    (if directory
        (let ((toplevel (magit2-toplevel directory)))
          (setq directory (file-name-as-directory
                           (expand-file-name directory)))
          (if (and toplevel (file-equal-p directory toplevel))
              (magit2-status-setup-buffer directory)
            (when (y-or-n-p
                   (if toplevel
                       (format "%s is a repository.  Create another in %s? "
                               toplevel directory)
                     (format "Create repository in %s? " directory)))
              ;; Creating a new repository invalidates cached values.
              (setq magit2--refresh-cache nil)
              (magit2-init directory))))
      (magit2-status-setup-buffer default-directory))))

(put 'magit2-status 'interactive-only 'magit2-status-setup-buffer)

;;;###autoload
(defalias 'magit2 'magit2-status
  "An alias for `magit2-status' for better discoverability.

Instead of invoking this alias for `magit2-status' using
\"M-x magit2 RET\", you should bind a key to `magit2-status'
and read the info node `(magit2)Getting Started', which
also contains other useful hints.")

;;;###autoload
(defun magit2-status-here ()
  "Like `magit2-status' but with non-nil `magit2-status-goto-file-position'."
  (interactive)
  (let ((magit2-status-goto-file-position t))
    (call-interactively #'magit2-status)))

(put 'magit2-status-here 'interactive-only 'magit2-status-setup-buffer)

;;;###autoload
(defun magit2-status-quick ()
  "Show the status of the current Git repository, maybe without refreshing.

If the status buffer of the current Git repository exists but
isn't being displayed in the selected frame, then display it
without refreshing it.

If the status buffer is being displayed in the selected frame,
then also refresh it.

Prefix arguments have the same meaning as for `magit2-status',
and additionally cause the buffer to be refresh.

To use this function instead of `magit2-status', add this to your
init file: (global-set-key (kbd \"C-x g\") 'magit2-status-quick)."
  (interactive)
  (if-let ((buffer
            (and (not current-prefix-arg)
                 (not (magit2-get-mode-buffer 'magit2-status-mode nil 'selected))
                 (magit2-get-mode-buffer 'magit2-status-mode))))
      (magit2-display-buffer buffer)
    (call-interactively #'magit2-status)))

;;; Mode

(defvar magit2-status-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-mode-map)
    (define-key map "j" 'magit2-status-jump)
    (define-key map [remap dired-jump] 'magit2-dired-jump)
    map)
  "Keymap for `magit2-status-mode'.")

(transient-define-prefix magit2-status-jump ()
  "In a Magit-Status buffer, jump to a section."
  ["Jump to"
   [("z " "Stashes" magit2-jump-to-stashes
     :if (lambda () (memq 'magit2-insert-stashes magit2-status-sections-hook)))
    ("t " "Tracked" magit2-jump-to-tracked
     :if (lambda () (memq 'magit2-insert-tracked-files magit2-status-sections-hook)))
    ("n " "Untracked" magit2-jump-to-untracked
     :if (lambda () (memq 'magit2-insert-untracked-files magit2-status-sections-hook)))
    ("u " "Unstaged" magit2-jump-to-unstaged
     :if (lambda () (memq 'magit2-insert-unstaged-changes magit2-status-sections-hook)))
    ("s " "Staged" magit2-jump-to-staged
     :if (lambda () (memq 'magit2-insert-staged-changes magit2-status-sections-hook)))]
   [("fu" "Unpulled from upstream" magit2-jump-to-unpulled-from-upstream
     :if (lambda () (memq 'magit2-insert-unpulled-from-upstream magit2-status-sections-hook)))
    ("fp" "Unpulled from pushremote" magit2-jump-to-unpulled-from-pushremote
     :if (lambda () (memq 'magit2-insert-unpulled-from-pushremote magit2-status-sections-hook)))
    ("pu" magit2-jump-to-unpushed-to-upstream
     :if (lambda ()
           (or (memq 'magit2-insert-unpushed-to-upstream-or-recent magit2-status-sections-hook)
               (memq 'magit2-insert-unpushed-to-upstream magit2-status-sections-hook)))
     :description (lambda ()
                    (let ((upstream (magit2-get-upstream-branch)))
                      (if (or (not upstream)
                              (magit2-rev-ancestor-p "HEAD" upstream))
                          "Recent commits"
                        "Unmerged into upstream"))))
    ("pp" "Unpushed to pushremote" magit2-jump-to-unpushed-to-pushremote
     :if (lambda () (memq 'magit2-insert-unpushed-to-pushremote magit2-status-sections-hook)))
    ("a " "Assumed unstaged" magit2-jump-to-assume-unchanged
     :if (lambda () (memq 'magit2-insert-assume-unchanged-files magit2-status-sections-hook)))
    ("w " "Skip worktree" magit2-jump-to-skip-worktree
     :if (lambda () (memq 'magit2-insert-skip-worktree-files magit2-status-sections-hook)))]
   [("i" "Using Imenu" imenu)]])

(define-derived-mode magit2-status-mode magit2-mode "Magit"
  "Mode for looking at Git status.

This mode is documented in info node `(magit2)Status Buffer'.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-section-toggle] to expand or hide the section at point.
Type \\[magit2-visit-thing] to visit the change or commit at point.

Type \\[magit2-dispatch] to invoke major commands.

Staging and applying changes is documented in info node
`(magit2)Staging and Unstaging' and info node `(magit2)Applying'.

\\<magit2-hunk-section-map>Type \
\\[magit2-apply] to apply the change at point, \
\\[magit2-stage] to stage,
\\[magit2-unstage] to unstage, \
\\[magit2-discard] to discard, or \
\\[magit2-reverse] to reverse it.

\\<magit2-status-mode-map>\
Type \\[magit2-commit] to create a commit.

\\{magit2-status-mode-map}"
  :group 'magit2-status
  (hack-dir-local-variables-non-file-buffer)
  (setq magit2--imenu-group-types '(not branch commit)))

(put 'magit2-status-mode 'magit2-diff-default-arguments
     '("--no-ext-diff"))
(put 'magit2-status-mode 'magit2-log-default-arguments
     '("-n256" "--decorate"))

;;;###autoload
(defun magit2-status-setup-buffer (&optional directory)
  (unless directory
    (setq directory default-directory))
  (when (file-remote-p directory)
    (magit2-git-version-assert))
  (let* ((default-directory directory)
         (d (magit2-diff--get-value 'magit2-status-mode
                                   magit2-status-use-buffer-arguments))
         (l (magit2-log--get-value 'magit2-status-mode
                                  magit2-status-use-buffer-arguments))
         (file (and magit2-status-goto-file-position
                    (magit2-file-relative-name)))
         (line (and file (line-number-at-pos)))
         (col  (and file (current-column)))
         (buf  (magit2-setup-buffer #'magit2-status-mode nil
                 (magit2-buffer-diff-args  (nth 0 d))
                 (magit2-buffer-diff-files (nth 1 d))
                 (magit2-buffer-log-args   (nth 0 l))
                 (magit2-buffer-log-files  (nth 1 l)))))
    (when file
      (with-current-buffer buf
        (let ((staged (magit2-get-section '((staged) (status)))))
          (if (and staged
                   (cadr (magit2-diff--locate-hunk file line staged)))
              (magit2-diff--goto-position file line col staged)
            (let ((unstaged (magit2-get-section '((unstaged) (status)))))
              (unless (and unstaged
                           (magit2-diff--goto-position file line col unstaged))
                (when staged
                  (magit2-diff--goto-position file line col staged))))))))
    buf))

(defun magit2-status-refresh-buffer ()
  (magit2-git-exit-code "update-index" "--refresh")
  (magit2-insert-section (status)
    (magit2-run-section-hook 'magit2-status-sections-hook)))

(defun magit2-status-goto-initial-section ()
  "In a `magit2-status-mode' buffer, jump `magit2-status-initial-section'.
Actually doing so is deferred until `magit2-refresh-buffer-hook'
runs `magit2-status-goto-initial-section-1'.  That function then
removes itself from the hook, so that this only happens when the
status buffer is first created."
  (when (and magit2-status-initial-section
             (derived-mode-p 'magit2-status-mode))
    (add-hook 'magit2-refresh-buffer-hook
              'magit2-status-goto-initial-section-1 nil t)))

(defun magit2-status-goto-initial-section-1 ()
  "In a `magit2-status-mode' buffer, jump `magit2-status-initial-section'.
This function removes itself from `magit2-refresh-buffer-hook'."
  (when-let ((section
              (--some (if (integerp it)
                          (nth (1- it)
                               (magit2-section-siblings (magit2-current-section)
                                                       'next))
                        (magit2-get-section it))
                      magit2-status-initial-section)))
    (goto-char (oref section start))
    (when-let ((vis (cdr (assq 'magit2-status-initial-section
                               magit2-section-initial-visibility-alist))))
      (if (eq vis 'hide)
          (magit2-section-hide section)
        (magit2-section-show section))))
  (remove-hook 'magit2-refresh-buffer-hook
               'magit2-status-goto-initial-section-1 t))

(defun magit2-status-maybe-update-revision-buffer (&optional _)
  "When moving in the status buffer, update the revision buffer.
If there is no revision buffer in the same frame, then do nothing."
  (when (derived-mode-p 'magit2-status-mode)
    (magit2--maybe-update-revision-buffer)))

(defun magit2-status-maybe-update-stash-buffer (&optional _)
  "When moving in the status buffer, update the stash buffer.
If there is no stash buffer in the same frame, then do nothing."
  (when (derived-mode-p 'magit2-status-mode)
    (magit2--maybe-update-stash-buffer)))

(defun magit2-status-maybe-update-blob-buffer (&optional _)
  "When moving in the status buffer, update the blob buffer.
If there is no blob buffer in the same frame, then do nothing."
  (when (derived-mode-p 'magit2-status-mode)
    (magit2--maybe-update-blob-buffer)))

;;; Sections
;;;; Special Headers

(defun magit2-insert-status-headers ()
  "Insert header sections appropriate for `magit2-status-mode' buffers.
The sections are inserted by running the functions on the hook
`magit2-status-headers-hook'."
  (if (magit2-rev-parse "HEAD")
      (magit2-insert-headers 'magit2-status-headers-hook)
    (insert "In the beginning there was darkness\n\n")))

(defvar magit2-error-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-process-buffer)
    map)
  "Keymap for `error' sections.")

(defun magit2-insert-error-header ()
  "Insert the message about the Git error that just occurred.

This function is only aware of the last error that occur when Git
was run for side-effects.  If, for example, an error occurs while
generating a diff, then that error won't be inserted.  Refreshing
the status buffer causes this section to disappear again."
  (when magit2-this-error
    (magit2-insert-section (error 'git)
      (insert (propertize (format "%-10s" "GitError! ")
                          'font-lock-face 'magit2-section-heading))
      (insert (propertize magit2-this-error 'font-lock-face 'error))
      (when-let ((key (car (where-is-internal 'magit2-process-buffer))))
        (insert (format "  [Type `%s' for details]" (key-description key))))
      (insert ?\n))
    (setq magit2-this-error nil)))

(defun magit2-insert-diff-filter-header ()
  "Insert a header line showing the effective diff filters."
  (let ((ignore-modules (magit2-ignore-submodules-p)))
    (when (or ignore-modules
              magit2-buffer-diff-files)
      (insert (propertize (format "%-10s" "Filter! ")
                          'font-lock-face 'magit2-section-heading))
      (when ignore-modules
        (insert ignore-modules)
        (when magit2-buffer-diff-files
          (insert " -- ")))
      (when magit2-buffer-diff-files
        (insert (mapconcat #'identity magit2-buffer-diff-files " ")))
      (insert ?\n))))

;;;; Reference Headers

(defun magit2-insert-head-branch-header (&optional branch)
  "Insert a header line about the current branch.
If `HEAD' is detached, then insert information about that commit
instead.  The optional BRANCH argument is for internal use only."
  (let ((branch (or branch (magit2-get-current-branch)))
        (output (magit2-rev-format "%h %s" (or branch "HEAD"))))
    (string-match "^\\([^ ]+\\) \\(.*\\)" output)
    (magit2-bind-match-strings (commit summary) output
      (when (equal summary "")
        (setq summary "(no commit message)"))
      (if branch
          (magit2-insert-section (branch branch)
            (insert (format "%-10s" "Head: "))
            (when magit2-status-show-hashes-in-headers
              (insert (propertize commit 'font-lock-face 'magit2-hash) ?\s))
            (insert (propertize branch 'font-lock-face 'magit2-branch-local))
            (insert ?\s)
            (insert (funcall magit2-log-format-message-function branch summary))
            (insert ?\n))
        (magit2-insert-section (commit commit)
          (insert (format "%-10s" "Head: "))
          (insert (propertize commit 'font-lock-face 'magit2-hash))
          (insert ?\s)
          (insert (funcall magit2-log-format-message-function nil summary))
          (insert ?\n))))))

(defun magit2-insert-upstream-branch-header (&optional branch upstream keyword)
  "Insert a header line about the upstream of the current branch.
If no branch is checked out, then insert nothing.  The optional
arguments are for internal use only."
  (when-let ((branch (or branch (magit2-get-current-branch))))
    (let ((remote (magit2-get "branch" branch "remote"))
          (merge  (magit2-get "branch" branch "merge"))
          (rebase (magit2-get "branch" branch "rebase")))
      (when (or remote merge)
        (unless upstream
          (setq upstream (magit2-get-upstream-branch branch)))
        (magit2-insert-section (branch upstream)
          (pcase rebase
            ("true")
            ("false" (setq rebase nil))
            (_       (setq rebase (magit2-get-boolean "pull.rebase"))))
          (insert (format "%-10s" (or keyword (if rebase "Rebase: " "Merge: "))))
          (insert
           (if upstream
               (concat (and magit2-status-show-hashes-in-headers
                            (concat (propertize (magit2-rev-format "%h" upstream)
                                                'font-lock-face 'magit2-hash)
                                    " "))
                       upstream " "
                       (funcall magit2-log-format-message-function upstream
                                (funcall magit2-log-format-message-function nil
                                         (or (magit2-rev-format "%s" upstream)
                                             "(no commit message)"))))
             (cond
              ((magit2--unnamed-upstream-p remote merge)
               (concat (propertize merge  'font-lock-face 'magit2-branch-remote)
                       " from "
                       (propertize remote 'font-lock-face 'bold)))
              ((magit2--valid-upstream-p remote merge)
               (if (equal remote ".")
                   (concat
                    (propertize merge 'font-lock-face 'magit2-branch-local) " "
                    (propertize "does not exist"
                                'font-lock-face 'magit2-branch-warning))
                 (format
                  "%s %s %s"
                  (propertize merge 'font-lock-face 'magit2-branch-remote)
                  (propertize "does not exist on"
                              'font-lock-face 'magit2-branch-warning)
                  (propertize remote 'font-lock-face 'magit2-branch-remote))))
              (t
               (propertize "invalid upstream configuration"
                           'font-lock-face 'magit2-branch-warning)))))
          (insert ?\n))))))

(defun magit2-insert-push-branch-header ()
  "Insert a header line about the branch the current branch is pushed to."
  (when-let ((branch (magit2-get-current-branch))
             (target (magit2-get-push-branch branch)))
    (magit2-insert-section (branch target)
      (insert (format "%-10s" "Push: "))
      (insert
       (if (magit2-rev-parse target)
           (concat (and magit2-status-show-hashes-in-headers
                        (concat (propertize (magit2-rev-format "%h" target)
                                            'font-lock-face 'magit2-hash)
                                " "))
                   target " "
                   (funcall magit2-log-format-message-function target
                            (funcall magit2-log-format-message-function nil
                                     (or (magit2-rev-format "%s" target)
                                         "(no commit message)"))))
         (let ((remote (magit2-get-push-remote branch)))
           (if (magit2-remote-p remote)
               (concat target " "
                       (propertize "does not exist"
                                   'font-lock-face 'magit2-branch-warning))
             (concat remote " "
                     (propertize "remote does not exist"
                                 'font-lock-face 'magit2-branch-warning))))))
      (insert ?\n))))

(defun magit2-insert-tags-header ()
  "Insert a header line about the current and/or next tag."
  (let* ((this-tag (magit2-get-current-tag nil t))
         (next-tag (magit2-get-next-tag nil t))
         (this-cnt (cadr this-tag))
         (next-cnt (cadr next-tag))
         (this-tag (car this-tag))
         (next-tag (car next-tag))
         (both-tags (and this-tag next-tag t)))
    (when (or this-tag next-tag)
      (magit2-insert-section (tag (or this-tag next-tag))
        (insert (format "%-10s" (if both-tags "Tags: " "Tag: ")))
        (cl-flet ((insert-count
                   (tag count face)
                   (insert (concat (propertize tag 'font-lock-face 'magit2-tag)
                                   (and (> count 0)
                                        (format " (%s)"
                                                (propertize
                                                 (format "%s" count)
                                                 'font-lock-face face)))))))
          (when this-tag  (insert-count this-tag this-cnt 'magit2-branch-local))
          (when both-tags (insert ", "))
          (when next-tag  (insert-count next-tag next-cnt 'magit2-tag)))
        (insert ?\n)))))

;;;; Auxiliary Headers

(defun magit2-insert-user-header ()
  "Insert a header line about the current user."
  (let ((name  (magit2-get "user.name"))
        (email (magit2-get "user.email")))
    (when (and name email)
      (magit2-insert-section (user name)
        (insert (format "%-10s" "User: "))
        (insert (propertize name 'font-lock-face 'magit2-log-author))
        (insert " <" email ">\n")))))

(defun magit2-insert-repo-header ()
  "Insert a header line showing the path to the repository top-level."
  (let ((topdir (magit2-toplevel)))
    (magit2-insert-section (repo topdir)
      (insert (format "%-10s%s\n" "Repo: " (abbreviate-file-name topdir))))))

(defun magit2-insert-remote-header ()
  "Insert a header line about the remote of the current branch.

If no remote is configured for the current branch, then fall back
showing the \"origin\" remote, or if that does not exist the first
remote in alphabetic order."
  (when-let ((name (magit2-get-some-remote))
             ;; Under certain configurations it's possible for url
             ;; to be nil, when name is not, see #2858.
             (url (magit2-get "remote" name "url")))
    (magit2-insert-section (remote name)
      (insert (format "%-10s" "Remote: "))
      (insert (propertize name 'font-lock-face 'magit2-branch-remote) ?\s)
      (insert url ?\n))))

;;;; File Sections

(defvar magit2-untracked-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-delete-thing] 'magit2-discard)
    (define-key map "s" 'magit2-stage)
    map)
  "Keymap for the `untracked' section.")

(magit2-define-section-jumper magit2-jump-to-untracked "Untracked files" untracked)

(defun magit2-insert-untracked-files ()
  "Maybe insert a list or tree of untracked files.

Do so depending on the value of `status.showUntrackedFiles'.
Note that even if the value is `all', Magit still initially
only shows directories.  But the directory sections can then
be expanded using \"TAB\".

If the first element of `magit2-buffer-diff-files' is a
directory, then limit the list to files below that.  The value
value of that variable can be set using \"D -- DIRECTORY RET g\"."
  (let* ((show (or (magit2-get "status.showUntrackedFiles") "normal"))
         (base (car magit2-buffer-diff-files))
         (base (and base (file-directory-p base) base)))
    (unless (equal show "no")
      (if (equal show "all")
          (when-let ((files (magit2-untracked-files nil base)))
            (magit2-insert-section (untracked)
              (magit2-insert-heading "Untracked files:")
              (magit2-insert-files files base)
              (insert ?\n)))
        (when-let ((files
                    (--mapcat (and (eq (aref it 0) ??)
                                   (list (substring it 3)))
                              (magit2-git-items "status" "-z" "--porcelain"
                                               (magit2-ignore-submodules-p t)
                                               "--" base))))
          (magit2-insert-section (untracked)
            (magit2-insert-heading "Untracked files:")
            (dolist (file files)
              (magit2-insert-section (file file)
                (insert (propertize file 'font-lock-face 'magit2-filename) ?\n)))
            (insert ?\n)))))))

(magit2-define-section-jumper magit2-jump-to-tracked "Tracked files" tracked)

(defun magit2-insert-tracked-files ()
  "Insert a tree of tracked files.

If the first element of `magit2-buffer-diff-files' is a
directory, then limit the list to files below that.  The value
value of that variable can be set using \"D -- DIRECTORY RET g\"."
  (when-let ((files (magit2-list-files)))
    (let* ((base (car magit2-buffer-diff-files))
           (base (and base (file-directory-p base) base)))
      (magit2-insert-section (tracked nil t)
        (magit2-insert-heading "Tracked files:")
        (magit2-insert-files files base)
        (insert ?\n)))))

(defun magit2-insert-ignored-files ()
  "Insert a tree of ignored files.

If the first element of `magit2-buffer-diff-files' is a
directory, then limit the list to files below that.  The value
of that variable can be set using \"D -- DIRECTORY RET g\"."
  (when-let ((files (magit2-ignored-files)))
    (let* ((base (car magit2-buffer-diff-files))
           (base (and base (file-directory-p base) base)))
      (magit2-insert-section (tracked nil t)
        (magit2-insert-heading "Ignored files:")
        (magit2-insert-files files base)
        (insert ?\n)))))

(magit2-define-section-jumper magit2-jump-to-skip-worktree "Skip-worktree files" skip-worktree)

(defun magit2-insert-skip-worktree-files ()
  "Insert a tree of skip-worktree files.

If the first element of `magit2-buffer-diff-files' is a
directory, then limit the list to files below that.  The value
of that variable can be set using \"D -- DIRECTORY RET g\"."
  (when-let ((files (magit2-skip-worktree-files)))
    (let* ((base (car magit2-buffer-diff-files))
           (base (and base (file-directory-p base) base)))
      (magit2-insert-section (skip-worktree nil t)
        (magit2-insert-heading "Skip-worktree files:")
        (magit2-insert-files files base)
        (insert ?\n)))))

(magit2-define-section-jumper magit2-jump-to-assume-unchanged "Assume-unchanged files" assume-unchanged)

(defun magit2-insert-assume-unchanged-files ()
  "Insert a tree of files that are assumed to be unchanged.

If the first element of `magit2-buffer-diff-files' is a
directory, then limit the list to files below that.  The value
of that variable can be set using \"D -- DIRECTORY RET g\"."
  (when-let ((files (magit2-assume-unchanged-files)))
    (let* ((base (car magit2-buffer-diff-files))
           (base (and base (file-directory-p base) base)))
      (magit2-insert-section (assume-unchanged nil t)
        (magit2-insert-heading "Assume-unchanged files:")
        (magit2-insert-files files base)
        (insert ?\n)))))

(defun magit2-insert-files (files directory)
  (while (and files (string-prefix-p (or directory "") (car files)))
    (let ((dir (file-name-directory (car files))))
      (if (equal dir directory)
          (let ((file (pop files)))
            (magit2-insert-section (file file)
              (insert (propertize file 'font-lock-face 'magit2-filename) ?\n)))
        (magit2-insert-section (file dir t)
          (insert (propertize dir 'file 'magit2-filename) ?\n)
          (magit2-insert-heading)
          (setq files (magit2-insert-files files dir))))))
  files)

;;; _
(provide 'magit2-status)
;;; magit2-status.el ends here
