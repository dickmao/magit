;;; magit2-refs.el --- listing references  -*- lexical-binding: t -*-

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

;; This library implements support for listing references in a buffer.

;;; Code:

(require 'magit2)

;;; Options

(defgroup magit2-refs nil
  "Inspect and manipulate Git branches and tags."
  :link '(info-link "(magit2)References Buffer")
  :group 'magit2-modes)

(defcustom magit2-refs-mode-hook nil
  "Hook run after entering Magit-Refs mode."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-refs
  :type 'hook)

(defcustom magit2-refs-sections-hook
  '(magit2-insert-error-header
    magit2-insert-branch-description
    magit2-insert-local-branches
    magit2-insert-remote-branches
    magit2-insert-tags)
  "Hook run to insert sections into a references buffer."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-refs
  :type 'hook)

(defcustom magit2-refs-show-commit-count nil
  "Whether to show commit counts in Magit-Refs mode buffers.

all    Show counts for branches and tags.
branch Show counts for branches only.
nil    Never show counts.

To change the value in an existing buffer use the command
`magit2-refs-set-show-commit-count'."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-refs
  :safe (lambda (val) (memq val '(all branch nil)))
  :type '(choice (const all    :tag "For branches and tags")
                 (const branch :tag "For branches only")
                 (const nil    :tag "Never")))
(put 'magit2-refs-show-commit-count 'safe-local-variable 'symbolp)
(put 'magit2-refs-show-commit-count 'permanent-local t)

(defcustom magit2-refs-pad-commit-counts nil
  "Whether to pad all counts on all sides in `magit2-refs-mode' buffers.

If this is nil, then some commit counts are displayed right next
to one of the branches that appear next to the count, without any
space in between.  This might look bad if the branch name faces
look too similar to `magit2-dimmed'.

If this is non-nil, then spaces are placed on both sides of all
commit counts."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-refs
  :type 'boolean)

(defvar magit2-refs-show-push-remote nil
  "Whether to show the push-remotes of local branches.
Also show the commits that the local branch is ahead and behind
the push-target.  Unfortunately there is a bug in Git that makes
this useless (the commits ahead and behind the upstream are
shown), so this isn't enabled yet.")

(defcustom magit2-refs-show-remote-prefix nil
  "Whether to show the remote prefix in lists of remote branches.

This is redundant because the name of the remote is already shown
in the heading preceding the list of its branches."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-refs
  :type 'boolean)

(defcustom magit2-refs-margin
  (list nil
        (nth 1 magit2-log-margin)
        'magit2-log-margin-width nil
        (nth 4 magit2-log-margin))
  "Format of the margin in `magit2-refs-mode' buffers.

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
  :group 'magit2-refs
  :group 'magit2-margin
  :safe (lambda (val) (memq val '(all branch nil)))
  :type magit2-log-margin--custom-type
  :initialize 'magit2-custom-initialize-reset
  :set-after '(magit2-log-margin)
  :set (apply-partially #'magit2-margin-set-variable 'magit2-refs-mode))

(defcustom magit2-refs-margin-for-tags nil
  "Whether to show information about tags in the margin.

This is disabled by default because it is slow if there are many
tags."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-refs
  :group 'magit2-margin
  :type 'boolean)

(defcustom magit2-refs-primary-column-width (cons 16 32)
  "Width of the focus column in `magit2-refs-mode' buffers.

The primary column is the column that contains the name of the
branch that the current row is about.

If this is an integer, then the column is that many columns wide.
Otherwise it has to be a cons-cell of two integers.  The first
specifies the minimal width, the second the maximal width.  In that
case the actual width is determined using the length of the names
of the shown local branches.  (Remote branches and tags are not
taken into account when calculating to optimal width.)"
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-refs
  :type '(choice (integer :tag "Constant wide")
                 (cons    :tag "Wide constrains"
                          (integer :tag "Minimum")
                          (integer :tag "Maximum"))))

(defcustom magit2-refs-focus-column-width 5
  "Width of the focus column in `magit2-refs-mode' buffers.

The focus column is the first column, which marks one
branch (usually the current branch) as the focused branch using
\"*\" or \"@\".  For each other reference, this column optionally
shows how many commits it is ahead of the focused branch and \"<\", or
if it isn't ahead then the commits it is behind and \">\", or if it
isn't behind either, then a \"=\".

This column may also display only \"*\" or \"@\" for the focused
branch, in which case this option is ignored.  Use \"L v\" to
change the verbosity of this column."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-refs
  :type 'integer)

(defcustom magit2-refs-filter-alist nil
  "Alist controlling which refs are omitted from `magit2-refs-mode' buffers.

The purpose of this option is to forgo displaying certain refs
based on their name.  If you want to not display any refs of a
certain type, then you should remove the appropriate function
from `magit2-refs-sections-hook' instead.

All keys are tried in order until one matches.  Then its value
is used and subsequent elements are ignored.  If the value is
non-nil, then the reference is displayed, otherwise it is not.
If no element matches, then the reference is displayed.

A key can either be a regular expression that the refname has to
match, or a function that takes the refname as only argument and
returns a boolean.  A remote branch such as \"origin/master\" is
displayed as just \"master\", however for this comparison the
former is used."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-refs
  :type '(alist :key-type   (choice  :tag "Key" regexp function)
                :value-type (boolean :tag "Value"
                                     :on  "show (non-nil)"
                                     :off "omit (nil)")))

(defcustom magit2-visit-ref-behavior nil
  "Control how `magit2-visit-ref' behaves in `magit2-refs-mode' buffers.

By default `magit2-visit-ref' behaves like `magit2-show-commit',
in all buffers, including `magit2-refs-mode' buffers.  When the
type of the section at point is `commit' then \"RET\" is bound to
`magit2-show-commit', and when the type is either `branch' or
`tag' then it is bound to `magit2-visit-ref'.

\"RET\" is one of Magit's most essential keys and at least by
default it should behave consistently across all of Magit,
especially because users quickly learn that it does something
very harmless; it shows more information about the thing at point
in another buffer.

However \"RET\" used to behave differently in `magit2-refs-mode'
buffers, doing surprising things, some of which cannot really be
described as \"visit this thing\".  If you have grown accustomed
to such inconsistent, but to you useful, behavior, then you can
restore that by adding one or more of the below symbols to the
value of this option.  But keep in mind that by doing so you
don't only introduce inconsistencies, you also lose some
functionality and might have to resort to `M-x magit2-show-commit'
to get it back.

`magit2-visit-ref' looks for these symbols in the order in which
they are described here.  If the presence of a symbol applies to
the current situation, then the symbols that follow do not affect
the outcome.

`focus-on-ref'

  With a prefix argument update the buffer to show commit counts
  and lists of cherry commits relative to the reference at point
  instead of relative to the current buffer or `HEAD'.

  Instead of adding this symbol, consider pressing \"C-u y o RET\".

`create-branch'

  If point is on a remote branch, then create a new local branch
  with the same name, use the remote branch as its upstream, and
  then check out the local branch.

  Instead of adding this symbol, consider pressing \"b c RET RET\",
  like you would do in other buffers.

`checkout-any'

  Check out the reference at point.  If that reference is a tag
  or a remote branch, then this results in a detached `HEAD'.

  Instead of adding this symbol, consider pressing \"b b RET\",
  like you would do in other buffers.

`checkout-branch'

  Check out the local branch at point.

  Instead of adding this symbol, consider pressing \"b b RET\",
  like you would do in other buffers."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-refs
  :group 'magit2-commands
  :options '(focus-on-ref create-branch checkout-any checkout-branch)
  :type '(list :convert-widget custom-hook-convert-widget))

;;; Mode

(defvar magit2-refs-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-mode-map)
    (define-key map (kbd "C-y") 'magit2-refs-set-show-commit-count)
    (define-key map (kbd "L")   'magit2-margin-settings)
    map)
  "Keymap for `magit2-refs-mode'.")

(define-derived-mode magit2-refs-mode magit2-mode "Magit Refs"
  "Mode which lists and compares references.

This mode is documented in info node `(magit2)References Buffer'.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-section-toggle] to expand or hide the section at point.
Type \\[magit2-visit-thing] or \\[magit2-diff-show-or-scroll-up] \
to visit the commit or branch at point.

Type \\[magit2-branch] to see available branch commands.
Type \\[magit2-merge] to merge the branch or commit at point.
Type \\[magit2-cherry-pick] to apply the commit at point.
Type \\[magit2-reset] to reset `HEAD' to the commit at point.

\\{magit2-refs-mode-map}"
  :group 'magit2-refs
  (hack-dir-local-variables-non-file-buffer)
  (setq magit2--imenu-group-types '(local remote tags)))

(defun magit2-refs-setup-buffer (ref args)
  (magit2-setup-buffer #'magit2-refs-mode nil
    (magit2-buffer-upstream ref)
    (magit2-buffer-arguments args)))

(defun magit2-refs-refresh-buffer ()
  (setq magit2-set-buffer-margin-refresh (not (magit2-buffer-margin-p)))
  (unless (magit2-rev-parse magit2-buffer-upstream)
    (setq magit2-refs-show-commit-count nil))
  (magit2-set-header-line-format
   (format "%s %s" magit2-buffer-upstream
           (mapconcat #'identity magit2-buffer-arguments " ")))
  (magit2-insert-section (branchbuf)
    (magit2-run-section-hook 'magit2-refs-sections-hook))
  (add-hook 'kill-buffer-hook 'magit2-preserve-section-visibility-cache))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-refs-mode))
  (cons magit2-buffer-upstream magit2-buffer-arguments))

;;; Commands

;;;###autoload (autoload 'magit2-show-refs "magit2-refs" nil t)
(transient-define-prefix magit2-show-refs (&optional transient)
  "List and compare references in a dedicated buffer."
  :man-page "git-branch"
  :value (lambda ()
           (magit2-show-refs-arguments magit2-prefix-use-buffer-arguments))
  ["Arguments"
   (magit2-for-each-ref:--contains)
   ("-M" "Merged"               "--merged=" magit2-transient-read-revision)
   ("-m" "Merged to HEAD"       "--merged")
   ("-N" "Not merged"           "--no-merged=" magit2-transient-read-revision)
   ("-n" "Not merged to HEAD"   "--no-merged")
   (magit2-for-each-ref:--sort)]
  ["Actions"
   ("y" "Show refs, comparing them with HEAD"           magit2-show-refs-head)
   ("c" "Show refs, comparing them with current branch" magit2-show-refs-current)
   ("o" "Show refs, comparing them with other branch"   magit2-show-refs-other)
   ("r" "Show refs, changing commit count display"
    magit2-refs-set-show-commit-count)]
  (interactive (list (or (derived-mode-p 'magit2-refs-mode)
                         current-prefix-arg)))
  (if transient
      (transient-setup 'magit2-show-refs)
    (magit2-refs-setup-buffer "HEAD" (magit2-show-refs-arguments))))

(defun magit2-show-refs-arguments (&optional use-buffer-args)
  (unless use-buffer-args
    (setq use-buffer-args magit2-direct-use-buffer-arguments))
  (let (args)
    (cond
     ((eq transient-current-command 'magit2-show-refs)
      (setq args (transient-args 'magit2-show-refs)))
     ((eq major-mode 'magit2-refs-mode)
      (setq args magit2-buffer-arguments))
     ((and (memq use-buffer-args '(always selected))
           (when-let ((buffer (magit2-get-mode-buffer
                               'magit2-refs-mode nil
                               (eq use-buffer-args 'selected))))
             (setq args (buffer-local-value 'magit2-buffer-arguments buffer))
             t)))
     (t
      (setq args (alist-get 'magit2-show-refs transient-values))))
    args))

(transient-define-argument magit2-for-each-ref:--contains ()
  :description "Contains"
  :class 'transient-option
  :key "-c"
  :argument "--contains="
  :reader 'magit2-transient-read-revision)

(transient-define-argument magit2-for-each-ref:--sort ()
  :description "Sort"
  :class 'transient-option
  :key "-s"
  :argument "--sort="
  :reader 'magit2-read-ref-sort)

(defun magit2-read-ref-sort (prompt initial-input _history)
  (magit2-completing-read prompt
                         '("-committerdate" "-authordate"
                           "committerdate" "authordate")
                         nil nil initial-input))

;;;###autoload
(defun magit2-show-refs-head (&optional args)
  "List and compare references in a dedicated buffer.
Compared with `HEAD'."
  (interactive (list (magit2-show-refs-arguments)))
  (magit2-refs-setup-buffer "HEAD" args))

;;;###autoload
(defun magit2-show-refs-current (&optional args)
  "List and compare references in a dedicated buffer.
Compare with the current branch or `HEAD' if it is detached."
  (interactive (list (magit2-show-refs-arguments)))
  (magit2-refs-setup-buffer (magit2-get-current-branch) args))

;;;###autoload
(defun magit2-show-refs-other (&optional ref args)
  "List and compare references in a dedicated buffer.
Compared with a branch read from the user."
  (interactive (list (magit2-read-other-branch "Compare with")
                     (magit2-show-refs-arguments)))
  (magit2-refs-setup-buffer ref args))

(defun magit2-refs-set-show-commit-count ()
  "Change for which refs the commit count is shown."
  (interactive)
  (setq-local magit2-refs-show-commit-count
              (magit2-read-char-case "Show commit counts for " nil
                (?a "[a]ll refs" 'all)
                (?b "[b]ranches only" t)
                (?n "[n]othing" nil)))
  (magit2-refresh))

(defun magit2-visit-ref ()
  "Visit the reference or revision at point in another buffer.
If there is no revision at point or with a prefix argument prompt
for a revision.

This command behaves just like `magit2-show-commit', except if
point is on a reference in a `magit2-refs-mode' buffer (a buffer
listing branches and tags), in which case the behavior may be
different, but only if you have customized the option
`magit2-visit-ref-behavior' (which see)."
  (interactive)
  (if (and (derived-mode-p 'magit2-refs-mode)
           (magit2-section-match '(branch tag)))
      (let ((ref (oref (magit2-current-section) value)))
        (cond (current-prefix-arg
               (cond ((memq 'focus-on-ref magit2-visit-ref-behavior)
                      (magit2-refs-setup-buffer ref (magit2-show-refs-arguments)))
                     (magit2-visit-ref-behavior
                      ;; Don't prompt for commit to visit.
                      (let ((current-prefix-arg nil))
                        (call-interactively #'magit2-show-commit)))))
              ((and (memq 'create-branch magit2-visit-ref-behavior)
                    (magit2-section-match [branch remote]))
               (let ((branch (cdr (magit2-split-branch-name ref))))
                 (if (magit2-branch-p branch)
                     (if (magit2-rev-eq branch ref)
                         (magit2-call-git "checkout" branch)
                       (setq branch (propertize branch 'face 'magit2-branch-local))
                       (setq ref (propertize ref 'face 'magit2-branch-remote))
                       (pcase (prog1 (read-char-choice (format (propertize "\
Branch %s already exists.
  [c]heckout %s as-is
  [r]reset %s to %s and checkout %s
  [a]bort " 'face 'minibuffer-prompt) branch branch branch ref branch)
                                                       '(?c ?r ?a))
                                (message "")) ; otherwise prompt sticks
                         (?c (magit2-call-git "checkout" branch))
                         (?r (magit2-call-git "checkout" "-B" branch ref))
                         (?a (user-error "Abort"))))
                   (magit2-call-git "checkout" "-b" branch ref))
                 (setq magit2-buffer-upstream branch)
                 (magit2-refresh)))
              ((or (memq 'checkout-any magit2-visit-ref-behavior)
                   (and (memq 'checkout-branch magit2-visit-ref-behavior)
                        (magit2-section-match [branch local])))
               (magit2-call-git "checkout" ref)
               (setq magit2-buffer-upstream ref)
               (magit2-refresh))
              (t
               (call-interactively #'magit2-show-commit))))
    (call-interactively #'magit2-show-commit)))

;;; Sections

(defvar magit2-remote-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-delete-thing] 'magit2-remote-remove)
    (define-key map "R"                        'magit2-remote-rename)
    map)
  "Keymap for `remote' sections.")

(defvar magit2-branch-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing]  'magit2-visit-ref)
    (define-key map [remap magit2-delete-thing] 'magit2-branch-delete)
    (define-key map "R"                        'magit2-branch-rename)
    map)
  "Keymap for `branch' sections.")

(defvar magit2-tag-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing]  'magit2-visit-ref)
    (define-key map [remap magit2-delete-thing] 'magit2-tag-delete)
    map)
  "Keymap for `tag' sections.")

(defun magit2-insert-branch-description ()
  "Insert header containing the description of the current branch.
Insert a header line with the name and description of the
current branch.  The description is taken from the Git variable
`branch.<NAME>.description'; if that is undefined then no header
line is inserted at all."
  (when-let ((branch (magit2-get-current-branch))
             (desc (magit2-get "branch" branch "description"))
             (desc (split-string desc "\n")))
    (when (equal (car (last desc)) "")
      (setq desc (butlast desc)))
    (magit2-insert-section (branchdesc branch t)
      (magit2-insert-heading branch ": " (car desc))
      (when (cdr desc)
        (insert (mapconcat 'identity (cdr desc) "\n"))
        (insert "\n\n")))))

(defun magit2-insert-tags ()
  "Insert sections showing all tags."
  (when-let ((tags (magit2-git-lines "tag" "--list" "-n" magit2-buffer-arguments)))
    (let ((_head (magit2-rev-parse "HEAD")))
      (magit2-insert-section (tags)
        (magit2-insert-heading "Tags:")
        (dolist (tag tags)
          (string-match "^\\([^ \t]+\\)[ \t]+\\([^ \t\n].*\\)?" tag)
          (let ((tag (match-string 1 tag))
                (msg (match-string 2 tag)))
            (when (magit2-refs--insert-refname-p tag)
              (magit2-insert-section (tag tag t)
                (magit2-insert-heading
                  (magit2-refs--format-focus-column tag 'tag)
                  (propertize tag 'font-lock-face 'magit2-tag)
                  (make-string
                   (max 1 (- (if (consp magit2-refs-primary-column-width)
                                 (car magit2-refs-primary-column-width)
                               magit2-refs-primary-column-width)
                             (length tag)))
                   ?\s)
                  (and msg (magit2-log-propertize-keywords nil msg)))
                (when (and magit2-refs-margin-for-tags (magit2-buffer-margin-p))
                  (magit2-refs--format-margin tag))
                (magit2-refs--insert-cherry-commits tag)))))
        (insert ?\n)
        (magit2-make-margin-overlay nil t)))))

(defun magit2-insert-remote-branches ()
  "Insert sections showing all remote-tracking branches."
  (dolist (remote (magit2-list-remotes))
    (magit2-insert-section (remote remote)
      (magit2-insert-heading
        (let ((pull (magit2-get "remote" remote "url"))
              (push (magit2-get "remote" remote "pushurl")))
          (format (propertize "Remote %s (%s):"
                              'font-lock-face 'magit2-section-heading)
                  (propertize remote 'font-lock-face 'magit2-branch-remote)
                  (concat pull (and pull push ", ") push))))
      (let (head)
        (dolist (line (magit2-git-lines "for-each-ref" "--format=\
%(symref:short)%00%(refname:short)%00%(refname)%00%(subject)"
                                       (concat "refs/remotes/" remote)
                                       magit2-buffer-arguments))
          (pcase-let ((`(,head-branch ,branch ,ref ,msg)
                       (-replace "" nil (split-string line "\0"))))
            (if head-branch
                (progn (cl-assert (equal branch (concat remote "/HEAD")))
                       (setq head head-branch))
              (when (magit2-refs--insert-refname-p branch)
                (magit2-insert-section (branch branch t)
                  (let ((headp (equal branch head))
                        (abbrev (if magit2-refs-show-remote-prefix
                                    branch
                                  (substring branch (1+ (length remote))))))
                    (magit2-insert-heading
                      (magit2-refs--format-focus-column branch)
                      (magit2-refs--propertize-branch
                       abbrev ref (and headp 'magit2-branch-remote-head))
                      (make-string
                       (max 1 (- (if (consp magit2-refs-primary-column-width)
                                     (car magit2-refs-primary-column-width)
                                   magit2-refs-primary-column-width)
                                 (length abbrev)))
                       ?\s)
                      (and msg (magit2-log-propertize-keywords nil msg))))
                  (when (magit2-buffer-margin-p)
                    (magit2-refs--format-margin branch))
                  (magit2-refs--insert-cherry-commits branch)))))))
      (insert ?\n)
      (magit2-make-margin-overlay nil t))))

(defun magit2-insert-local-branches ()
  "Insert sections showing all local branches."
  (magit2-insert-section (local nil)
    (magit2-insert-heading "Branches:")
    (dolist (line (magit2-refs--format-local-branches))
      (pcase-let ((`(,branch . ,strings) line))
        (magit2-insert-section
          ((eval (if branch 'branch 'commit))
           (or branch (magit2-rev-parse "HEAD"))
           t)
          (apply #'magit2-insert-heading strings)
          (when (magit2-buffer-margin-p)
            (magit2-refs--format-margin branch))
          (magit2-refs--insert-cherry-commits branch))))
    (insert ?\n)
    (magit2-make-margin-overlay nil t)))

(defun magit2-refs--format-local-branches ()
  (let ((lines (-keep 'magit2-refs--format-local-branch
                      (magit2-git-lines
                       "for-each-ref"
                       (concat "--format=\
%(HEAD)%00%(refname:short)%00%(refname)%00\
%(upstream:short)%00%(upstream)%00%(upstream:track)%00"
                               (if magit2-refs-show-push-remote "\
%(push:remotename)%00%(push)%00%(push:track)%00%(subject)"
                                 "%00%00%00%(subject)"))
                       "refs/heads"
                       magit2-buffer-arguments))))
    (unless (magit2-get-current-branch)
      (push (magit2-refs--format-local-branch
             (concat "*\0\0\0\0\0\0\0\0" (magit2-rev-format "%s")))
            lines))
    (setq-local magit2-refs-primary-column-width
                (let ((def (default-value 'magit2-refs-primary-column-width)))
                  (if (atom def)
                      def
                    (pcase-let ((`(,min . ,max) def))
                      (min max (apply #'max min (mapcar #'car lines)))))))
    (mapcar (pcase-lambda (`(,_ ,branch ,focus ,branch-desc ,u:ahead ,p:ahead
                                ,u:behind ,upstream ,p:behind ,push ,msg))
              (list branch focus branch-desc u:ahead p:ahead
                    (make-string (max 1 (- magit2-refs-primary-column-width
                                           (length (concat branch-desc
                                                           u:ahead
                                                           p:ahead
                                                           u:behind))))
                                 ?\s)
                    u:behind upstream p:behind push
                    msg))
            lines)))

(defun magit2-refs--format-local-branch (line)
  (pcase-let ((`(,head ,branch ,ref ,upstream ,u:ref ,u:track
                       ,push ,p:ref ,p:track ,msg)
               (-replace "" nil (split-string line "\0"))))
    (when (or (not branch)
              (magit2-refs--insert-refname-p branch))
      (let* ((headp (equal head "*"))
             (pushp (and push
                         magit2-refs-show-push-remote
                         (magit2-rev-parse p:ref)
                         (not (equal p:ref u:ref))))
             (branch-desc
              (if branch
                  (magit2-refs--propertize-branch
                   branch ref (and headp 'magit2-branch-current))
                (magit2--propertize-face "(detached)" 'magit2-branch-warning)))
             (u:ahead  (and u:track
                            (string-match "ahead \\([0-9]+\\)" u:track)
                            (magit2--propertize-face
                             (concat (and magit2-refs-pad-commit-counts " ")
                                     (match-string 1 u:track)
                                     ">")
                             'magit2-dimmed)))
             (u:behind (and u:track
                            (string-match "behind \\([0-9]+\\)" u:track)
                            (magit2--propertize-face
                             (concat "<"
                                     (match-string 1 u:track)
                                     (and magit2-refs-pad-commit-counts " "))
                             'magit2-dimmed)))
             (p:ahead  (and pushp p:track
                            (string-match "ahead \\([0-9]+\\)" p:track)
                            (magit2--propertize-face
                             (concat (match-string 1 p:track)
                                     ">"
                                     (and magit2-refs-pad-commit-counts " "))
                             'magit2-branch-remote)))
             (p:behind (and pushp p:track
                            (string-match "behind \\([0-9]+\\)" p:track)
                            (magit2--propertize-face
                             (concat "<"
                                     (match-string 1 p:track)
                                     (and magit2-refs-pad-commit-counts " "))
                             'magit2-dimmed))))
        (list (1+ (length (concat branch-desc u:ahead p:ahead u:behind)))
              branch
              (magit2-refs--format-focus-column branch headp)
              branch-desc u:ahead p:ahead u:behind
              (and upstream
                   (concat (if (equal u:track "[gone]")
                               (magit2--propertize-face upstream 'error)
                             (magit2-refs--propertize-branch upstream u:ref))
                           " "))
              (and pushp
                   (concat p:behind
                           (magit2--propertize-face
                            push 'magit2-branch-remote)
                           " "))
              (and msg (magit2-log-propertize-keywords nil msg)))))))

(defun magit2-refs--format-focus-column (ref &optional type)
  (let ((focus magit2-buffer-upstream)
        (width (if magit2-refs-show-commit-count
                   magit2-refs-focus-column-width
                 1)))
    (format
     (format "%%%ss " width)
     (cond ((or (equal ref focus)
                (and (eq type t)
                     (equal focus "HEAD")))
            (magit2--propertize-face (concat (if (equal focus "HEAD") "@" "*")
                                            (make-string (1- width) ?\s))
                                    'magit2-section-heading))
           ((if (eq type 'tag)
                (eq magit2-refs-show-commit-count 'all)
              magit2-refs-show-commit-count)
            (pcase-let ((`(,behind ,ahead)
                         (magit2-rev-diff-count magit2-buffer-upstream ref)))
              (magit2--propertize-face
               (cond ((> ahead  0) (concat "<" (number-to-string ahead)))
                     ((> behind 0) (concat (number-to-string behind) ">"))
                     (t "="))
               'magit2-dimmed)))
           (t "")))))

(defun magit2-refs--propertize-branch (branch ref &optional head-face)
  (let ((face (cdr (cl-find-if (pcase-lambda (`(,re . ,_))
                                 (string-match-p re ref))
                               magit2-ref-namespaces))))
    (magit2--propertize-face
     branch (if head-face (list face head-face) face))))

(defun magit2-refs--insert-refname-p (refname)
  (--if-let (-first (pcase-lambda (`(,key . ,_))
                      (if (functionp key)
                          (funcall key refname)
                        (string-match-p key refname)))
                    magit2-refs-filter-alist)
      (cdr it)
    t))

(defun magit2-refs--insert-cherry-commits (ref)
  (magit2-insert-section-body
    (let ((start (point))
          (magit2-insert-section--current nil))
      (magit2-git-wash (apply-partially 'magit2-log-wash-log 'cherry)
        "cherry" "-v" (magit2-abbrev-arg) magit2-buffer-upstream ref)
      (if (= (point) start)
          (message "No cherries for %s" ref)
        (magit2-make-margin-overlay nil t)))))

(defun magit2-refs--format-margin (commit)
  (save-excursion
    (goto-char (line-beginning-position 0))
    (let ((line (magit2-rev-format "%ct%cN" commit)))
      (magit2-log-format-margin commit
                               (substring line 10)
                               (substring line 0 10)))))

;;; _
(provide 'magit2-refs)
;;; magit2-refs.el ends here
