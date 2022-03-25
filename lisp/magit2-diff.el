;;; magit2-diff.el --- inspect Git diffs  -*- lexical-binding: t -*-

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

;; This library implements support for looking at Git diffs and
;; commits.

;;; Code:

(require 'magit2-core)
(require 'git-commit)

(eval-when-compile (require 'ansi-color))
(require 'diff-mode)
(require 'image)
(require 'smerge-mode)

;; For `magit2-diff-popup'
(declare-function magit2-stash-show "magit2-stash" (stash &optional args files))
;; For `magit2-diff-visit-file'
(declare-function dired-jump "dired" ; dired-x before 27.1
                  (&optional other-window file-name))
(declare-function magit2-find-file-noselect "magit2-files" (rev file))
(declare-function magit2-status-setup-buffer "magit2-status" (&optional directory))
;; For `magit2-diff-while-committing'
(declare-function magit2-commit-message-buffer "magit2-commit" ())
;; For `magit2-insert-revision-gravatar'
(defvar gravatar-size)
;; For `magit2-show-commit' and `magit2-diff-show-or-scroll'
(declare-function magit2-current-blame-chunk "magit2-blame" (&optional type noerror))
(declare-function magit2-blame-mode "magit2-blame" (&optional arg))
(defvar magit2-blame-mode)
;; For `magit2-diff-show-or-scroll'
(declare-function git-rebase-current-line "git-rebase" ())
;; For `magit2-diff-unmerged'
(declare-function magit2-merge-in-progress-p "magit2-merge" ())
(declare-function magit2--merge-range "magit2-merge" (&optional head))
;; For `magit2-diff--dwim'
(declare-function forge--pullreq-range "forge-pullreq"
                  (pullreq &optional endpoints))
(declare-function forge--pullreq-ref "forge-pullreq" (pullreq))
;; For `magit2-diff-wash-diff'
(declare-function ansi-color-apply-on-region "ansi-color")

(eval-when-compile
  (cl-pushnew 'orig-rev eieio--known-slot-names)
  (cl-pushnew 'action-type eieio--known-slot-names)
  (cl-pushnew 'target eieio--known-slot-names))

;;; Options
;;;; Diff Mode

(defgroup magit2-diff nil
  "Inspect and manipulate Git diffs."
  :link '(info-link "(magit2)Diffing")
  :group 'magit2-commands
  :group 'magit2-modes)

(defcustom magit2-diff-mode-hook nil
  "Hook run after entering Magit-Diff mode."
  :group 'magit2-diff
  :type 'hook)

(defcustom magit2-diff-sections-hook
  '(magit2-insert-diff
    magit2-insert-xref-buttons)
  "Hook run to insert sections into a `magit2-diff-mode' buffer."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-diff
  :type 'hook)

(defcustom magit2-diff-expansion-threshold 60
  "After how many seconds not to expand anymore diffs.

Except in status buffers, diffs usually start out fully expanded.
Because that can take a long time, all diffs that haven't been
fontified during a refresh before the threshold defined here are
instead displayed with their bodies collapsed.

Note that this can cause sections that were previously expanded
to be collapsed.  So you should not pick a very low value here.

The hook function `magit2-diff-expansion-threshold' has to be a
member of `magit2-section-set-visibility-hook' for this option
to have any effect."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-diff
  :type 'float)

(defcustom magit2-diff-highlight-hunk-body t
  "Whether to highlight bodies of selected hunk sections.
This only has an effect if `magit2-diff-highlight' is a
member of `magit2-section-highlight-hook', which see."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-diff
  :type 'boolean)

(defcustom magit2-diff-highlight-hunk-region-functions
  '(magit2-diff-highlight-hunk-region-dim-outside
    magit2-diff-highlight-hunk-region-using-overlays)
  "The functions used to highlight the hunk-internal region.

`magit2-diff-highlight-hunk-region-dim-outside' overlays the outside
of the hunk internal selection with a face that causes the added and
removed lines to have the same background color as context lines.
This function should not be removed from the value of this option.

`magit2-diff-highlight-hunk-region-using-overlays' and
`magit2-diff-highlight-hunk-region-using-underline' emphasize the
region by placing delimiting horizontal lines before and after it.
The underline variant was implemented because Eli said that is
how we should do it.  However the overlay variant actually works
better.  Also see https://github.com/magit2/magit2/issues/2758.

Instead of, or in addition to, using delimiting horizontal lines,
to emphasize the boundaries, you may which to emphasize the text
itself, using `magit2-diff-highlight-hunk-region-using-face'.

In terminal frames it's not possible to draw lines as the overlay
and underline variants normally do, so there they fall back to
calling the face function instead."
  :package-version '(magit2 . "2.9.0")
  :set-after '(magit2-diff-show-lines-boundaries)
  :group 'magit2-diff
  :type 'hook
  :options '(magit2-diff-highlight-hunk-region-dim-outside
             magit2-diff-highlight-hunk-region-using-underline
             magit2-diff-highlight-hunk-region-using-overlays
             magit2-diff-highlight-hunk-region-using-face))

(defcustom magit2-diff-unmarked-lines-keep-foreground t
  "Whether `magit2-diff-highlight-hunk-region-dim-outside' preserves foreground.
When this is set to nil, then that function only adjusts the
foreground color but added and removed lines outside the region
keep their distinct foreground colors."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-diff
  :type 'boolean)

(defcustom magit2-diff-refine-hunk nil
  "Whether to show word-granularity differences within diff hunks.

nil    Never show fine differences.
t      Show fine differences for the current diff hunk only.
`all'  Show fine differences for all displayed diff hunks."
  :group 'magit2-diff
  :safe (lambda (val) (memq val '(nil t all)))
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Current" t)
                 (const :tag "All" all)))

(defcustom magit2-diff-refine-ignore-whitespace smerge-refine-ignore-whitespace
  "Whether to ignore whitespace changes in word-granularity differences."
  :package-version '(magit2 . "3.0.0")
  :set-after '(smerge-refine-ignore-whitespace)
  :group 'magit2-diff
  :safe 'booleanp
  :type 'boolean)

(put 'magit2-diff-refine-hunk 'permanent-local t)

(defcustom magit2-diff-adjust-tab-width nil
  "Whether to adjust the width of tabs in diffs.

Determining the correct width can be expensive if it requires
opening large and/or many files, so the widths are cached in
the variable `magit2-diff--tab-width-cache'.  Set that to nil
to invalidate the cache.

nil       Never adjust tab width.  Use `tab-width's value from
          the Magit buffer itself instead.

t         If the corresponding file-visiting buffer exits, then
          use `tab-width's value from that buffer.  Doing this is
          cheap, so this value is used even if a corresponding
          cache entry exists.

`always'  If there is no such buffer, then temporarily visit the
          file to determine the value.

NUMBER    Like `always', but don't visit files larger than NUMBER
          bytes."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-diff
  :type '(choice (const   :tag "Never" nil)
                 (const   :tag "If file-visiting buffer exists" t)
                 (integer :tag "If file isn't larger than N bytes")
                 (const   :tag "Always" always)))

(defcustom magit2-diff-paint-whitespace t
  "Specify where to highlight whitespace errors.

nil            Never highlight whitespace errors.
t              Highlight whitespace errors everywhere.
`uncommitted'  Only highlight whitespace errors in diffs
               showing uncommitted changes.

For backward compatibility `status' is treated as a synonym
for `uncommitted'.

The option `magit2-diff-paint-whitespace-lines' controls for
what lines (added/remove/context) errors are highlighted.

The options `magit2-diff-highlight-trailing' and
`magit2-diff-highlight-indentation' control what kind of
whitespace errors are highlighted."
  :group 'magit2-diff
  :safe (lambda (val) (memq val '(t nil uncommitted status)))
  :type '(choice (const :tag "In all diffs" t)
                 (const :tag "Only in uncommitted changes" uncommitted)
                 (const :tag "Never" nil)))

(defcustom magit2-diff-paint-whitespace-lines t
  "Specify in what kind of lines to highlight whitespace errors.

t         Highlight only in added lines.
`both'    Highlight in added and removed lines.
`all'     Highlight in added, removed and context lines."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-diff
  :safe (lambda (val) (memq val '(t both all)))
  :type '(choice (const :tag "in added lines" t)
                 (const :tag "in added and removed lines" both)
                 (const :tag "in added, removed and context lines" all)))

(defcustom magit2-diff-highlight-trailing t
  "Whether to highlight whitespace at the end of a line in diffs.
Used only when `magit2-diff-paint-whitespace' is non-nil."
  :group 'magit2-diff
  :safe 'booleanp
  :type 'boolean)

(defcustom magit2-diff-highlight-indentation nil
  "Highlight the \"wrong\" indentation style.
Used only when `magit2-diff-paint-whitespace' is non-nil.

The value is an alist of the form ((REGEXP . INDENT)...).  The
path to the current repository is matched against each element
in reverse order.  Therefore if a REGEXP matches, then earlier
elements are not tried.

If the used INDENT is `tabs', highlight indentation with tabs.
If INDENT is an integer, highlight indentation with at least
that many spaces.  Otherwise, highlight neither."
  :group 'magit2-diff
  :type `(repeat (cons (string :tag "Directory regexp")
                       (choice (const :tag "Tabs" tabs)
                               (integer :tag "Spaces" :value ,tab-width)
                               (const :tag "Neither" nil)))))

(defcustom magit2-diff-hide-trailing-cr-characters
  (and (memq system-type '(ms-dos windows-nt)) t)
  "Whether to hide ^M characters at the end of a line in diffs."
  :package-version '(magit2 . "2.6.0")
  :group 'magit2-diff
  :type 'boolean)

(defcustom magit2-diff-highlight-keywords t
  "Whether to highlight bracketed keywords in commit messages."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-diff
  :type 'boolean)

(defcustom magit2-diff-extra-stat-arguments nil
  "Additional arguments to be used alongside `--stat'.

A list of zero or more arguments or a function that takes no
argument and returns such a list.  These arguments are allowed
here: `--stat-width', `--stat-name-width', `--stat-graph-width'
and `--compact-summary'.  See the git-diff(1) manpage."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-diff
  :type '(radio (function-item magit2-diff-use-window-width-as-stat-width)
                function
                (list string)
                (const :tag "None" nil)))

;;;; File Diff

(defcustom magit2-diff-buffer-file-locked t
  "Whether `magit2-diff-buffer-file' uses a dedicated buffer."
  :package-version '(magit2 . "2.7.0")
  :group 'magit2-commands
  :group 'magit2-diff
  :type 'boolean)

;;;; Revision Mode

(defgroup magit2-revision nil
  "Inspect and manipulate Git commits."
  :link '(info-link "(magit2)Revision Buffer")
  :group 'magit2-modes)

(defcustom magit2-revision-mode-hook
  '(bug-reference-mode
    goto-address-mode)
  "Hook run after entering Magit-Revision mode."
  :group 'magit2-revision
  :type 'hook
  :options '(bug-reference-mode
             goto-address-mode))

(defcustom magit2-revision-sections-hook
  '(magit2-insert-revision-tag
    magit2-insert-revision-headers
    magit2-insert-revision-message
    magit2-insert-revision-notes
    magit2-insert-revision-diff
    magit2-insert-xref-buttons)
  "Hook run to insert sections into a `magit2-revision-mode' buffer."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-revision
  :type 'hook)

(defcustom magit2-revision-headers-format "\
Author:     %aN <%aE>
AuthorDate: %ad
Commit:     %cN <%cE>
CommitDate: %cd
"
  "Format string used to insert headers in revision buffers.

All headers in revision buffers are inserted by the section
inserter `magit2-insert-revision-headers'.  Some of the headers
are created by calling `git show --format=FORMAT' where FORMAT
is the format specified here.  Other headers are hard coded or
subject to option `magit2-revision-insert-related-refs'."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-revision
  :type 'string)

(defcustom magit2-revision-insert-related-refs t
  "Whether to show related branches in revision buffers

`nil'   Don't show any related branches.
`t'     Show related local branches.
`all'   Show related local and remote branches.
`mixed' Show all containing branches and local merged branches."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-revision
  :type '(choice (const :tag "don't" nil)
                 (const :tag "local only" t)
                 (const :tag "all related" all)
                 (const :tag "all containing, local merged" mixed)))

(defcustom magit2-revision-use-hash-sections 'quicker
  "Whether to turn hashes inside the commit message into sections.

If non-nil, then hashes inside the commit message are turned into
`commit' sections.  There is a trade off to be made between
performance and reliability:

- `slow' calls git for every word to be absolutely sure.
- `quick' skips words less than seven characters long.
- `quicker' additionally skips words that don't contain a number.
- `quickest' uses all words that are at least seven characters
  long and which contain at least one number as well as at least
  one letter.

If nil, then no hashes are turned into sections, but you can
still visit the commit at point using \"RET\"."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-revision
  :type '(choice (const :tag "Use sections, quickest" quickest)
                 (const :tag "Use sections, quicker" quicker)
                 (const :tag "Use sections, quick" quick)
                 (const :tag "Use sections, slow" slow)
                 (const :tag "Don't use sections" nil)))

(defcustom magit2-revision-show-gravatars nil
  "Whether to show gravatar images in revision buffers.

If nil, then don't insert any gravatar images.  If t, then insert
both images.  If `author' or `committer', then insert only the
respective image.

If you have customized the option `magit2-revision-header-format'
and want to insert the images then you might also have to specify
where to do so.  In that case the value has to be a cons-cell of
two regular expressions.  The car specifies where to insert the
author's image.  The top half of the image is inserted right
after the matched text, the bottom half on the next line in the
same column.  The cdr specifies where to insert the committer's
image, accordingly.  Either the car or the cdr may be nil."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-revision
  :type '(choice (const :tag "Don't show gravatars" nil)
                 (const :tag "Show gravatars" t)
                 (const :tag "Show author gravatar" author)
                 (const :tag "Show committer gravatar" committer)
                 (cons  :tag "Show gravatars using custom pattern."
                        (regexp :tag "Author regexp"    "^Author:     ")
                        (regexp :tag "Committer regexp" "^Commit:     "))))

(defcustom magit2-revision-use-gravatar-kludge nil
  "Whether to work around a bug which affects display of gravatars.

Gravatar images are spliced into two halves which are then
displayed on separate lines.  On OS X the splicing has a bug in
some Emacs builds, which causes the top and bottom halves to be
interchanged.  Enabling this option works around this issue by
interchanging the halves once more, which cancels out the effect
of the bug.

See https://github.com/magit2/magit2/issues/2265
and https://debbugs.gnu.org/cgi/bugreport.cgi?bug=7847.

Starting with Emacs 26.1 this kludge should not be required for
any build."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-revision
  :type 'boolean)

(defcustom magit2-revision-fill-summary-line nil
  "Whether to fill excessively long summary lines.

If this is an integer, then the summary line is filled if it is
longer than either the limit specified here or `window-width'.

You may want to only set this locally in \".dir-locals-2.el\" for
repositories known to contain bad commit messages.

The body of the message is left alone because (a) most people who
write excessively long summary lines usually don't add a body and
(b) even people who have the decency to wrap their lines may have
a good reason to include a long line in the body sometimes."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-revision
  :type '(choice (const   :tag "Don't fill" nil)
                 (integer :tag "Fill if longer than")))

(defcustom magit2-revision-filter-files-on-follow nil
  "Whether to honor file filter if log arguments include --follow.

When a commit is displayed from a log buffer, the resulting
revision buffer usually shares the log's file arguments,
restricting the diff to those files.  However, there's a
complication when the log arguments include --follow: if the log
follows a file across a rename event, keeping the file
restriction would mean showing an empty diff in revision buffers
for commits before the rename event.

When this option is nil, the revision buffer ignores the log's
filter if the log arguments include --follow.  If non-nil, the
log's file filter is always honored."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-revision
  :type 'boolean)

;;;; Visit Commands

(defcustom magit2-diff-visit-previous-blob t
  "Whether `magit2-diff-visit-file' may visit the previous blob.

When this is t and point is on a removed line in a diff for a
committed change, then `magit2-diff-visit-file' visits the blob
from the last revision which still had that line.

Currently this is only supported for committed changes, for
staged and unstaged changes `magit2-diff-visit-file' always
visits the file in the working tree."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-diff
  :type 'boolean)

(defcustom magit2-diff-visit-avoid-head-blob nil
  "Whether `magit2-diff-visit-file' avoids visiting a blob from `HEAD'.

By default `magit2-diff-visit-file' always visits the blob that
added the current line, while `magit2-diff-visit-worktree-file'
visits the respective file in the working tree.  For the `HEAD'
commit, the former command used to visit the worktree file too,
but that made it impossible to visit a blob from `HEAD'.

When point is on a removed line and that change has not been
committed yet, then `magit2-diff-visit-file' now visits the last
blob that still had that line, which is a blob from `HEAD'.
Previously this function used to visit the worktree file not
only for added lines but also for such removed lines.

If you prefer the old behaviors, then set this to t."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-diff
  :type 'boolean)

;;; Faces

(defface magit2-diff-file-heading
  `((t ,@(and (>= emacs-major-version 27) '(:extend t))
       :weight bold))
  "Face for diff file headings."
  :group 'magit2-faces)

(defface magit2-diff-file-heading-highlight
  `((t ,@(and (>= emacs-major-version 27) '(:extend t))
       :inherit magit2-section-highlight))
  "Face for current diff file headings."
  :group 'magit2-faces)

(defface magit2-diff-file-heading-selection
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit magit2-diff-file-heading-highlight
     :foreground "salmon4")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit magit2-diff-file-heading-highlight
     :foreground "LightSalmon3"))
  "Face for selected diff file headings."
  :group 'magit2-faces)

(defface magit2-diff-hunk-heading
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey90"
     :foreground "grey20")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey25"
     :foreground "grey95"))
  "Face for diff hunk headings."
  :group 'magit2-faces)

(defface magit2-diff-hunk-heading-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey80"
     :foreground "grey20")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey35"
     :foreground "grey95"))
  "Face for current diff hunk headings."
  :group 'magit2-faces)

(defface magit2-diff-hunk-heading-selection
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit magit2-diff-hunk-heading-highlight
     :foreground "salmon4")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit magit2-diff-hunk-heading-highlight
     :foreground "LightSalmon3"))
  "Face for selected diff hunk headings."
  :group 'magit2-faces)

(defface magit2-diff-hunk-region
  `((t :inherit bold
       ,@(and (>= emacs-major-version 27)
              (list :extend (ignore-errors (face-attribute 'region :extend))))))
  "Face used by `magit2-diff-highlight-hunk-region-using-face'.

This face is overlaid over text that uses other hunk faces,
and those normally set the foreground and background colors.
The `:foreground' and especially the `:background' properties
should be avoided here.  Setting the latter would cause the
loss of information.  Good properties to set here are `:weight'
and `:slant'."
  :group 'magit2-faces)

(defface magit2-diff-revision-summary
  '((t :inherit magit2-diff-hunk-heading))
  "Face for commit message summaries."
  :group 'magit2-faces)

(defface magit2-diff-revision-summary-highlight
  '((t :inherit magit2-diff-hunk-heading-highlight))
  "Face for highlighted commit message summaries."
  :group 'magit2-faces)

(defface magit2-diff-lines-heading
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit magit2-diff-hunk-heading-highlight
     :background "LightSalmon3")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit magit2-diff-hunk-heading-highlight
     :foreground "grey80"
     :background "salmon4"))
  "Face for diff hunk heading when lines are marked."
  :group 'magit2-faces)

(defface magit2-diff-lines-boundary
  `((t ,@(and (>= emacs-major-version 27) '(:extend t)) ; !important
       :inherit magit2-diff-lines-heading))
  "Face for boundary of marked lines in diff hunk."
  :group 'magit2-faces)

(defface magit2-diff-conflict-heading
  '((t :inherit magit2-diff-hunk-heading))
  "Face for conflict markers."
  :group 'magit2-faces)

(defface magit2-diff-added
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#ddffdd"
     :foreground "#22aa22")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#335533"
     :foreground "#ddffdd"))
  "Face for lines in a diff that have been added."
  :group 'magit2-faces)

(defface magit2-diff-removed
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#ffdddd"
     :foreground "#aa2222")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#553333"
     :foreground "#ffdddd"))
  "Face for lines in a diff that have been removed."
  :group 'magit2-faces)

(defface magit2-diff-our
  '((t :inherit magit2-diff-removed))
  "Face for lines in a diff for our side in a conflict."
  :group 'magit2-faces)

(defface magit2-diff-base
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#ffffcc"
     :foreground "#aaaa11")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#555522"
     :foreground "#ffffcc"))
  "Face for lines in a diff for the base side in a conflict."
  :group 'magit2-faces)

(defface magit2-diff-their
  '((t :inherit magit2-diff-added))
  "Face for lines in a diff for their side in a conflict."
  :group 'magit2-faces)

(defface magit2-diff-context
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "grey50")
    (((class color) (background  dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "grey70"))
  "Face for lines in a diff that are unchanged."
  :group 'magit2-faces)

(defface magit2-diff-added-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#cceecc"
     :foreground "#22aa22")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#336633"
     :foreground "#cceecc"))
  "Face for lines in a diff that have been added."
  :group 'magit2-faces)

(defface magit2-diff-removed-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#eecccc"
     :foreground "#aa2222")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#663333"
     :foreground "#eecccc"))
  "Face for lines in a diff that have been removed."
  :group 'magit2-faces)

(defface magit2-diff-our-highlight
  '((t :inherit magit2-diff-removed-highlight))
  "Face for lines in a diff for our side in a conflict."
  :group 'magit2-faces)

(defface magit2-diff-base-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#eeeebb"
     :foreground "#aaaa11")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "#666622"
     :foreground "#eeeebb"))
  "Face for lines in a diff for the base side in a conflict."
  :group 'magit2-faces)

(defface magit2-diff-their-highlight
  '((t :inherit magit2-diff-added-highlight))
  "Face for lines in a diff for their side in a conflict."
  :group 'magit2-faces)

(defface magit2-diff-context-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey95"
     :foreground "grey50")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey20"
     :foreground "grey70"))
  "Face for lines in the current context in a diff."
  :group 'magit2-faces)

(defface magit2-diff-whitespace-warning
  '((t :inherit trailing-whitespace))
  "Face for highlighting whitespace errors added lines."
  :group 'magit2-faces)

(defface magit2-diffstat-added
  '((((class color) (background light)) :foreground "#22aa22")
    (((class color) (background  dark)) :foreground "#448844"))
  "Face for plus sign in diffstat."
  :group 'magit2-faces)

(defface magit2-diffstat-removed
  '((((class color) (background light)) :foreground "#aa2222")
    (((class color) (background  dark)) :foreground "#aa4444"))
  "Face for minus sign in diffstat."
  :group 'magit2-faces)

;;; Arguments
;;;; Prefix Classes

(defclass magit2-diff-prefix (transient-prefix)
  ((history-key :initform 'magit2-diff)
   (major-mode  :initform 'magit2-diff-mode)))

(defclass magit2-diff-refresh-prefix (magit2-diff-prefix)
  ((history-key :initform 'magit2-diff)
   (major-mode  :initform nil)))

;;;; Prefix Methods

(cl-defmethod transient-init-value ((obj magit2-diff-prefix))
  (pcase-let ((`(,args ,files)
               (magit2-diff--get-value 'magit2-diff-mode
                                      magit2-prefix-use-buffer-arguments)))
    (unless (eq transient-current-command 'magit2-dispatch)
      (when-let ((file (magit2-file-relative-name)))
        (setq files (list file))))
    (oset obj value (if files `(("--" ,@files) ,args) args))))

(cl-defmethod transient-init-value ((obj magit2-diff-refresh-prefix))
  (oset obj value (if magit2-buffer-diff-files
                      `(("--" ,@magit2-buffer-diff-files)
                        ,magit2-buffer-diff-args)
                    magit2-buffer-diff-args)))

(cl-defmethod transient-set-value ((obj magit2-diff-prefix))
  (magit2-diff--set-value obj))

(cl-defmethod transient-save-value ((obj magit2-diff-prefix))
  (magit2-diff--set-value obj 'save))

;;;; Argument Access

(defun magit2-diff-arguments (&optional mode)
  "Return the current diff arguments."
  (if (memq transient-current-command '(magit2-diff magit2-diff-refresh))
      (pcase-let ((`(,args ,alist)
                   (-separate #'atom (transient-get-value))))
        (list args (cdr (assoc "--" alist))))
    (magit2-diff--get-value (or mode 'magit2-diff-mode))))

(defun magit2-diff--get-value (mode &optional use-buffer-args)
  (unless use-buffer-args
    (setq use-buffer-args magit2-direct-use-buffer-arguments))
  (let (args files)
    (cond
     ((and (memq use-buffer-args '(always selected current))
           (eq major-mode mode))
      (setq args  magit2-buffer-diff-args)
      (setq files magit2-buffer-diff-files))
     ((and (memq use-buffer-args '(always selected))
           (when-let ((buffer (magit2-get-mode-buffer
                               mode nil
                               (eq use-buffer-args 'selected))))
             (setq args  (buffer-local-value 'magit2-buffer-diff-args buffer))
             (setq files (buffer-local-value 'magit2-buffer-diff-files buffer))
             t)))
     ((plist-member (symbol-plist mode) 'magit2-diff-current-arguments)
      (setq args (get mode 'magit2-diff-current-arguments)))
     ((when-let ((elt (assq (intern (format "magit2-diff:%s" mode))
                            transient-values)))
        (setq args (cdr elt))
        t))
     (t
      (setq args (get mode 'magit2-diff-default-arguments))))
    (list args files)))

(defun magit2-diff--set-value (obj &optional save)
  (pcase-let* ((obj  (oref obj prototype))
               (mode (or (oref obj major-mode) major-mode))
               (key  (intern (format "magit2-diff:%s" mode)))
               (`(,args ,alist)
                (-separate #'atom (transient-get-value)))
               (files (cdr (assoc "--" alist))))
    (put mode 'magit2-diff-current-arguments args)
    (when save
      (setf (alist-get key transient-values) args)
      (transient-save-values))
    (transient--history-push obj)
    (setq magit2-buffer-diff-args args)
    (setq magit2-buffer-diff-files files)
    (magit2-refresh)))

;;; Commands
;;;; Prefix Commands

;;;###autoload (autoload 'magit2-diff "magit2-diff" nil t)
(transient-define-prefix magit2-diff ()
  "Show changes between different versions."
  :man-page "git-diff"
  :class 'magit2-diff-prefix
  ["Limit arguments"
   (magit2:--)
   (magit2-diff:--ignore-submodules)
   ("-b" "Ignore whitespace changes"      ("-b" "--ignore-space-change"))
   ("-w" "Ignore all whitespace"          ("-w" "--ignore-all-space"))
   (5 "-D" "Omit preimage for deletes"    ("-D" "--irreversible-delete"))]
  ["Context arguments"
   (magit2-diff:-U)
   ("-W" "Show surrounding functions"     ("-W" "--function-context"))]
  ["Tune arguments"
   (magit2-diff:--diff-algorithm)
   (magit2-diff:-M)
   (magit2-diff:-C)
   ("-x" "Disallow external diff drivers" "--no-ext-diff")
   ("-s" "Show stats"                     "--stat")
   ("=g" "Show signature"                 "--show-signature")
   (5 "-R" "Reverse sides"                "-R")
   (5 magit2-diff:--color-moved)
   (5 magit2-diff:--color-moved-ws)]
  ["Actions"
   [("d" "Dwim"          magit2-diff-dwim)
    ("r" "Diff range"    magit2-diff-range)
    ("p" "Diff paths"    magit2-diff-paths)]
   [("u" "Diff unstaged" magit2-diff-unstaged)
    ("s" "Diff staged"   magit2-diff-staged)
    ("w" "Diff worktree" magit2-diff-working-tree)]
   [("c" "Show commit"   magit2-show-commit)
    ("t" "Show stash"    magit2-stash-show)]])

;;;###autoload (autoload 'magit2-diff-refresh "magit2-diff" nil t)
(transient-define-prefix magit2-diff-refresh ()
  "Change the arguments used for the diff(s) in the current buffer."
  :man-page "git-diff"
  :class 'magit2-diff-refresh-prefix
  ["Limit arguments"
   (magit2:--)
   (magit2-diff:--ignore-submodules)
   ("-b" "Ignore whitespace changes"      ("-b" "--ignore-space-change"))
   ("-w" "Ignore all whitespace"          ("-w" "--ignore-all-space"))
   (5 "-D" "Omit preimage for deletes"    ("-D" "--irreversible-delete"))]
  ["Context arguments"
   (magit2-diff:-U)
   ("-W" "Show surrounding functions"     ("-W" "--function-context"))]
  ["Tune arguments"
   (magit2-diff:--diff-algorithm)
   (magit2-diff:-M)
   (magit2-diff:-C)
   ("-x" "Disallow external diff drivers" "--no-ext-diff")
   ("-s" "Show stats"                     "--stat"
    :if-derived magit2-diff-mode)
   ("=g" "Show signature"                 "--show-signature"
    :if-derived magit2-diff-mode)
   (5 "-R" "Reverse sides"                "-R"
    :if-derived magit2-diff-mode)
   (5 magit2-diff:--color-moved)
   (5 magit2-diff:--color-moved-ws)]
  [["Refresh"
    ("g" "buffer"                   magit2-diff-refresh)
    ("s" "buffer and set defaults"  transient-set  :transient nil)
    ("w" "buffer and save defaults" transient-save :transient nil)]
   ["Toggle"
    ("t" "hunk refinement"          magit2-diff-toggle-refine-hunk)
    ("F" "file filter"              magit2-diff-toggle-file-filter)
    ("b" "buffer lock"              magit2-toggle-buffer-lock
     :if-mode (magit2-diff-mode magit2-revision-mode magit2-stash-mode))]
   [:if-mode magit2-diff-mode
    :description "Do"
    ("r" "switch range type"        magit2-diff-switch-range-type)
    ("f" "flip revisions"           magit2-diff-flip-revs)]]
  (interactive)
  (if (not (eq transient-current-command 'magit2-diff-refresh))
      (transient-setup 'magit2-diff-refresh)
    (pcase-let ((`(,args ,files) (magit2-diff-arguments)))
      (setq magit2-buffer-diff-args args)
      (setq magit2-buffer-diff-files files))
    (magit2-refresh)))

;;;; Infix Commands

(transient-define-argument magit2:-- ()
  :description "Limit to files"
  :class 'transient-files
  :key "--"
  :argument "--"
  :prompt "Limit to file(s): "
  :reader 'magit2-read-files
  :multi-value t)

(defun magit2-read-files (prompt initial-input history &optional list-fn)
  (magit2-completing-read-multiple* prompt
                                   (funcall (or list-fn #'magit2-list-files))
                                   nil nil
                                   (or initial-input (magit2-file-at-point))
                                   history))

(transient-define-argument magit2-diff:-U ()
  :description "Context lines"
  :class 'transient-option
  :argument "-U"
  :reader 'transient-read-number-N0)

(transient-define-argument magit2-diff:-M ()
  :description "Detect renames"
  :class 'transient-option
  :argument "-M"
  :allow-empty t
  :reader 'transient-read-number-N+)

(transient-define-argument magit2-diff:-C ()
  :description "Detect copies"
  :class 'transient-option
  :argument "-C"
  :allow-empty t
  :reader 'transient-read-number-N+)

(transient-define-argument magit2-diff:--diff-algorithm ()
  :description "Diff algorithm"
  :class 'transient-option
  :key "-A"
  :argument "--diff-algorithm="
  :reader 'magit2-diff-select-algorithm)

(defun magit2-diff-select-algorithm (&rest _ignore)
  (magit2-read-char-case nil t
    (?d "[d]efault"   "default")
    (?m "[m]inimal"   "minimal")
    (?p "[p]atience"  "patience")
    (?h "[h]istogram" "histogram")))

(transient-define-argument magit2-diff:--ignore-submodules ()
  :description "Ignore submodules"
  :class 'transient-option
  :key "-i"
  :argument "--ignore-submodules="
  :reader 'magit2-diff-select-ignore-submodules)

(defun magit2-diff-select-ignore-submodules (&rest _ignored)
  (magit2-read-char-case "Ignore submodules " t
    (?u "[u]ntracked" "untracked")
    (?d "[d]irty"     "dirty")
    (?a "[a]ll"       "all")))

(transient-define-argument magit2-diff:--color-moved ()
  :description "Color moved lines"
  :class 'transient-option
  :key "-m"
  :argument "--color-moved="
  :reader 'magit2-diff-select-color-moved-mode)

(defun magit2-diff-select-color-moved-mode (&rest _ignore)
  (magit2-read-char-case "Color moved " t
    (?d "[d]efault" "default")
    (?p "[p]lain"   "plain")
    (?b "[b]locks"  "blocks")
    (?z "[z]ebra"   "zebra")
    (?Z "[Z] dimmed-zebra" "dimmed-zebra")))

(transient-define-argument magit2-diff:--color-moved-ws ()
  :description "Whitespace treatment for --color-moved"
  :class 'transient-option
  :key "=w"
  :argument "--color-moved-ws="
  :reader 'magit2-diff-select-color-moved-ws-mode)

(defun magit2-diff-select-color-moved-ws-mode (&rest _ignore)
  (magit2-read-char-case "Ignore whitespace " t
    (?i "[i]ndentation"  "allow-indentation-change")
    (?e "[e]nd of line"  "ignore-space-at-eol")
    (?s "[s]pace change" "ignore-space-change")
    (?a "[a]ll space"    "ignore-all-space")
    (?n "[n]o"           "no")))

;;;; Setup Commands

;;;###autoload
(defun magit2-diff-dwim (&optional args files)
  "Show changes for the thing at point."
  (interactive (magit2-diff-arguments))
  (let ((default-directory default-directory)
        (section (magit2-current-section)))
    (cond
     ((magit2-section-match 'module section)
      (setq default-directory
            (expand-file-name
             (file-name-as-directory (oref section value))))
      (magit2-diff-range (oref section range)))
     (t
      (when (magit2-section-match 'module-commit section)
        (setq args nil)
        (setq files nil)
        (setq default-directory
              (expand-file-name
               (file-name-as-directory (magit2-section-parent-value section)))))
      (pcase (magit2-diff--dwim)
        (`unmerged (magit2-diff-unmerged args files))
        (`unstaged (magit2-diff-unstaged args files))
        (`staged
         (let ((file (magit2-file-at-point)))
           (if (and file (equal (cddr (car (magit2-file-status file))) '(?D ?U)))
               ;; File was deleted by us and modified by them.  Show the latter.
               (magit2-diff-unmerged args (list file))
             (magit2-diff-staged nil args files))))
        (`(stash . ,value) (magit2-stash-show value args))
        (`(commit . ,value)
         (magit2-diff-range (format "%s^..%s" value value) args files))
        ((and range (pred stringp))
         (magit2-diff-range range args files))
        (_ (call-interactively #'magit2-diff-range)))))))

(defun magit2-diff--dwim ()
  "Return information for performing DWIM diff.

The information can be in three forms:
1. TYPE
   A symbol describing a type of diff where no additional information
   is needed to generate the diff.  Currently, this includes `staged',
   `unstaged' and `unmerged'.
2. (TYPE . VALUE)
   Like #1 but the diff requires additional information, which is
   given by VALUE.  Currently, this includes `commit' and `stash',
   where VALUE is the given commit or stash, respectively.
3. RANGE
   A string indicating a diff range.

If no DWIM context is found, nil is returned."
  (cond
   ((--when-let (magit2-region-values '(commit branch) t)
      (deactivate-mark)
      (concat (car (last it)) ".." (car it))))
   (magit2-buffer-refname
    (cons 'commit magit2-buffer-refname))
   ((derived-mode-p 'magit2-stash-mode)
    (cons 'commit
          (magit2-section-case
            (commit (oref it value))
            (file (thread-first it
                    (oref parent)
                    (oref value)))
            (hunk (thread-first it
                    (oref parent)
                    (oref parent)
                    (oref value))))))
   ((derived-mode-p 'magit2-revision-mode)
    (cons 'commit magit2-buffer-revision))
   ((derived-mode-p 'magit2-diff-mode)
    magit2-buffer-range)
   (t
    (magit2-section-case
      ([* unstaged] 'unstaged)
      ([* staged] 'staged)
      (unmerged 'unmerged)
      (unpushed (magit2-diff--range-to-endpoints (oref it value)))
      (unpulled (magit2-diff--range-to-endpoints (oref it value)))
      (branch (let ((current (magit2-get-current-branch))
                    (atpoint (oref it value)))
                (if (equal atpoint current)
                    (--if-let (magit2-get-upstream-branch)
                        (format "%s...%s" it current)
                      (if (magit2-anything-modified-p)
                          current
                        (cons 'commit current)))
                  (format "%s...%s"
                          (or current "HEAD")
                          atpoint))))
      (commit (cons 'commit (oref it value)))
      ([file commit] (cons 'commit (oref (oref it parent) value)))
      ([hunk file commit]
       (cons 'commit (oref (oref (oref it parent) parent) value)))
      (stash (cons 'stash (oref it value)))
      (pullreq (forge--pullreq-range (oref it value) t))))))

(defun magit2-diff--range-to-endpoints (range)
  (cond ((string-match "\\.\\.\\." range) (replace-match ".."  nil nil range))
        ((string-match "\\.\\."    range) (replace-match "..." nil nil range))
        (t range)))

(defun magit2-diff-read-range-or-commit (prompt &optional secondary-default mbase)
  "Read range or revision with special diff range treatment.
If MBASE is non-nil, prompt for which rev to place at the end of
a \"revA...revB\" range.  Otherwise, always construct
\"revA..revB\" range."
  (--if-let (magit2-region-values '(commit branch) t)
      (let ((revA (car (last it)))
            (revB (car it)))
        (deactivate-mark)
        (if mbase
            (let ((base (magit2-git-string "merge-base" revA revB)))
              (cond
               ((string= (magit2-rev-parse revA) base)
                (format "%s..%s" revA revB))
               ((string= (magit2-rev-parse revB) base)
                (format "%s..%s" revB revA))
               (t
                (let ((main (magit2-completing-read "View changes along"
                                                   (list revA revB)
                                                   nil t nil nil revB)))
                  (format "%s...%s"
                          (if (string= main revB) revA revB) main)))))
          (format "%s..%s" revA revB)))
    (magit2-read-range prompt
                      (or (pcase (magit2-diff--dwim)
                            (`(commit . ,value)
                             (format "%s^..%s" value value))
                            ((and range (pred stringp))
                             range))
                          secondary-default
                          (magit2-get-current-branch)))))

;;;###autoload
(defun magit2-diff-range (rev-or-range &optional args files)
  "Show differences between two commits.

REV-OR-RANGE should be a range or a single revision.  If it is a
revision, then show changes in the working tree relative to that
revision.  If it is a range, but one side is omitted, then show
changes relative to `HEAD'.

If the region is active, use the revisions on the first and last
line of the region as the two sides of the range.  With a prefix
argument, instead of diffing the revisions, choose a revision to
view changes along, starting at the common ancestor of both
revisions (i.e., use a \"...\" range)."
  (interactive (cons (magit2-diff-read-range-or-commit "Diff for range"
                                                      nil current-prefix-arg)
                     (magit2-diff-arguments)))
  (magit2-diff-setup-buffer rev-or-range nil args files))

;;;###autoload
(defun magit2-diff-working-tree (&optional rev args files)
  "Show changes between the current working tree and the `HEAD' commit.
With a prefix argument show changes between the working tree and
a commit read from the minibuffer."
  (interactive
   (cons (and current-prefix-arg
              (magit2-read-branch-or-commit "Diff working tree and commit"))
         (magit2-diff-arguments)))
  (magit2-diff-setup-buffer (or rev "HEAD") nil args files))

;;;###autoload
(defun magit2-diff-staged (&optional rev args files)
  "Show changes between the index and the `HEAD' commit.
With a prefix argument show changes between the index and
a commit read from the minibuffer."
  (interactive
   (cons (and current-prefix-arg
              (magit2-read-branch-or-commit "Diff index and commit"))
         (magit2-diff-arguments)))
  (magit2-diff-setup-buffer rev "--cached" args files))

;;;###autoload
(defun magit2-diff-unstaged (&optional args files)
  "Show changes between the working tree and the index."
  (interactive (magit2-diff-arguments))
  (magit2-diff-setup-buffer nil nil args files))

;;;###autoload
(defun magit2-diff-unmerged (&optional args files)
  "Show changes that are being merged."
  (interactive (magit2-diff-arguments))
  (unless (magit2-merge-in-progress-p)
    (user-error "No merge is in progress"))
  (magit2-diff-setup-buffer (magit2--merge-range) nil args files))

;;;###autoload
(defun magit2-diff-while-committing (&optional args)
  "While committing, show the changes that are about to be committed.
While amending, invoking the command again toggles between
showing just the new changes or all the changes that will
be committed."
  (interactive (list (car (magit2-diff-arguments))))
  (unless (magit2-commit-message-buffer)
    (user-error "No commit in progress"))
  (let ((magit2-display-buffer-noselect t))
    (if-let ((diff-buf (magit2-get-mode-buffer 'magit2-diff-mode 'selected)))
        (with-current-buffer diff-buf
          (cond ((and (equal magit2-buffer-range "HEAD^")
                      (equal magit2-buffer-typearg "--cached"))
                 (magit2-diff-staged nil args))
                ((and (equal magit2-buffer-range nil)
                      (equal magit2-buffer-typearg "--cached"))
                 (magit2-diff-while-amending args))
                ((magit2-anything-staged-p)
                 (magit2-diff-staged nil args))
                (t
                 (magit2-diff-while-amending args))))
      (if (magit2-anything-staged-p)
          (magit2-diff-staged nil args)
        (magit2-diff-while-amending args)))))

(define-key git-commit-mode-map
  (kbd "C-c C-d") 'magit2-diff-while-committing)

(defun magit2-diff-while-amending (&optional args)
  (magit2-diff-setup-buffer "HEAD^" "--cached" args nil))

;;;###autoload
(defun magit2-diff-buffer-file ()
  "Show diff for the blob or file visited in the current buffer.

When the buffer visits a blob, then show the respective commit.
When the buffer visits a file, then show the differenced between
`HEAD' and the working tree.  In both cases limit the diff to
the file or blob."
  (interactive)
  (require 'magit2)
  (if-let ((file (magit2-file-relative-name)))
      (if magit2-buffer-refname
          (magit2-show-commit magit2-buffer-refname
                             (car (magit2-show-commit--arguments))
                             (list file))
        (save-buffer)
        (let ((line (line-number-at-pos))
              (col (current-column)))
          (with-current-buffer
              (magit2-diff-setup-buffer (or (magit2-get-current-branch) "HEAD")
                                       nil
                                       (car (magit2-diff-arguments))
                                       (list file)
                                       magit2-diff-buffer-file-locked)
            (magit2-diff--goto-position file line col))))
    (user-error "Buffer isn't visiting a file")))

;;;###autoload
(defun magit2-diff-paths (a b)
  "Show changes between any two files on disk."
  (interactive (list (read-file-name "First file: " nil nil t)
                     (read-file-name "Second file: " nil nil t)))
  (magit2-diff-setup-buffer nil "--no-index"
                           nil (list (magit2-convert-filename-for-git
                                      (expand-file-name a))
                                     (magit2-convert-filename-for-git
                                      (expand-file-name b)))))

(defun magit2-show-commit--arguments ()
  (pcase-let ((`(,args ,diff-files)
               (magit2-diff-arguments 'magit2-revision-mode)))
    (list args (if (derived-mode-p 'magit2-log-mode)
                   (and (or magit2-revision-filter-files-on-follow
                            (not (member "--follow" magit2-buffer-log-args)))
                        magit2-buffer-log-files)
                 diff-files))))

;;;###autoload
(defun magit2-show-commit (rev &optional args files module)
  "Visit the revision at point in another buffer.
If there is no revision at point or with a prefix argument prompt
for a revision."
  (interactive
   (pcase-let* ((mcommit (magit2-section-value-if 'module-commit))
                (atpoint (or mcommit
                             (thing-at-point 'git-revision t)
                             (magit2-branch-or-commit-at-point)))
                (`(,args ,files) (magit2-show-commit--arguments)))
     (list (or (and (not current-prefix-arg) atpoint)
               (magit2-read-branch-or-commit "Show commit" atpoint))
           args
           files
           (and mcommit
                (magit2-section-parent-value (magit2-current-section))))))
  (require 'magit2)
  (let ((file (magit2-file-relative-name)))
    (magit2-with-toplevel
      (when module
        (setq default-directory
              (expand-file-name (file-name-as-directory module))))
      (unless (magit2-rev-hash rev)
        (user-error "%s is not a commit" rev))
      (let ((buf (magit2-revision-setup-buffer rev args files)))
        (when file
          (save-buffer)
          (let ((line (magit2-diff-visit--offset file (list "-R" rev)
                                                (line-number-at-pos)))
                (col (current-column)))
            (with-current-buffer buf
              (magit2-diff--goto-position file line col))))))))

(defun magit2-diff--locate-hunk (file line &optional parent)
  (when-let ((diff (cl-find-if (lambda (section)
                                 (and (cl-typep section 'magit2-file-section)
                                      (equal (oref section value) file)))
                               (oref (or parent magit2-root-section) children))))
    (let (hunk (hunks (oref diff children)))
      (cl-block nil
        (while (setq hunk (pop hunks))
          (when-let ((range (oref hunk to-range)))
            (pcase-let* ((`(,beg ,len) range)
                         (end (+ beg len)))
              (cond ((>  beg line)     (cl-return (list diff nil)))
                    ((<= beg line end) (cl-return (list hunk t)))
                    ((null hunks)      (cl-return (list hunk nil)))))))))))

(defun magit2-diff--goto-position (file line column &optional parent)
  (when-let ((pos (magit2-diff--locate-hunk file line parent)))
    (pcase-let ((`(,section ,exact) pos))
      (cond ((cl-typep section 'magit2-file-section)
             (goto-char (oref section start)))
            (exact
             (goto-char (oref section content))
             (let ((pos (car (oref section to-range))))
               (while (or (< pos line)
                          (= (char-after) ?-))
                 (unless (= (char-after) ?-)
                   (cl-incf pos))
                 (forward-line)))
             (forward-char (1+ column)))
            (t
             (goto-char (oref section start))
             (setq section (oref section parent))))
      (while section
        (when (oref section hidden)
          (magit2-section-show section))
        (setq section (oref section parent))))
    (magit2-section-update-highlight)
    t))

;;;; Setting Commands

(defun magit2-diff-switch-range-type ()
  "Convert diff range type.
Change \"revA..revB\" to \"revA...revB\", or vice versa."
  (interactive)
  (if (and magit2-buffer-range
           (derived-mode-p 'magit2-diff-mode)
           (string-match magit2-range-re magit2-buffer-range))
      (setq magit2-buffer-range
            (replace-match (if (string= (match-string 2 magit2-buffer-range) "..")
                               "..."
                             "..")
                           t t magit2-buffer-range 2))
    (user-error "No range to change"))
  (magit2-refresh))

(defun magit2-diff-flip-revs ()
  "Swap revisions in diff range.
Change \"revA..revB\" to \"revB..revA\"."
  (interactive)
  (if (and magit2-buffer-range
           (derived-mode-p 'magit2-diff-mode)
           (string-match magit2-range-re magit2-buffer-range))
      (progn
        (setq magit2-buffer-range
              (concat (match-string 3 magit2-buffer-range)
                      (match-string 2 magit2-buffer-range)
                      (match-string 1 magit2-buffer-range)))
        (magit2-refresh))
    (user-error "No range to swap")))

(defun magit2-diff-toggle-file-filter ()
  "Toggle the file restriction of the current buffer's diffs.
If the current buffer's mode is derived from `magit2-log-mode',
toggle the file restriction in the repository's revision buffer
instead."
  (interactive)
  (cl-flet ((toggle ()
                    (if (or magit2-buffer-diff-files
                            magit2-buffer-diff-files-suspended)
                        (cl-rotatef magit2-buffer-diff-files
                                    magit2-buffer-diff-files-suspended)
                      (setq magit2-buffer-diff-files
                            (transient-infix-read 'magit2:--)))
                    (magit2-refresh)))
    (cond
     ((derived-mode-p 'magit2-log-mode
                      'magit2-cherry-mode
                      'magit2-reflog-mode)
      (if-let ((buffer (magit2-get-mode-buffer 'magit2-revision-mode)))
          (with-current-buffer buffer (toggle))
        (message "No revision buffer")))
     ((local-variable-p 'magit2-buffer-diff-files)
      (toggle))
     (t
      (user-error "Cannot toggle file filter in this buffer")))))

(defun magit2-diff-less-context (&optional count)
  "Decrease the context for diff hunks by COUNT lines."
  (interactive "p")
  (magit2-diff-set-context (lambda (cur) (max 0 (- (or cur 0) count)))))

(defun magit2-diff-more-context (&optional count)
  "Increase the context for diff hunks by COUNT lines."
  (interactive "p")
  (magit2-diff-set-context (lambda (cur) (+ (or cur 0) count))))

(defun magit2-diff-default-context ()
  "Reset context for diff hunks to the default height."
  (interactive)
  (magit2-diff-set-context #'ignore))

(defun magit2-diff-set-context (fn)
  (let* ((def (--if-let (magit2-get "diff.context") (string-to-number it) 3))
         (val magit2-buffer-diff-args)
         (arg (--first (string-match "^-U\\([0-9]+\\)?$" it) val))
         (num (--if-let (and arg (match-string 1 arg)) (string-to-number it) def))
         (val (delete arg val))
         (num (funcall fn num))
         (arg (and num (not (= num def)) (format "-U%i" num)))
         (val (if arg (cons arg val) val)))
    (setq magit2-buffer-diff-args val))
  (magit2-refresh))

(defun magit2-diff-context-p ()
  (if-let ((arg (--first (string-match "^-U\\([0-9]+\\)$" it)
                         magit2-buffer-diff-args)))
      (not (equal arg "-U0"))
    t))

(defun magit2-diff-ignore-any-space-p ()
  (--any-p (member it magit2-buffer-diff-args)
           '("--ignore-cr-at-eol"
             "--ignore-space-at-eol"
             "--ignore-space-change" "-b"
             "--ignore-all-space" "-w"
             "--ignore-blank-space")))

(defun magit2-diff-toggle-refine-hunk (&optional style)
  "Turn diff-hunk refining on or off.

If hunk refining is currently on, then hunk refining is turned off.
If hunk refining is off, then hunk refining is turned on, in
`selected' mode (only the currently selected hunk is refined).

With a prefix argument, the \"third choice\" is used instead:
If hunk refining is currently on, then refining is kept on, but
the refining mode (`selected' or `all') is switched.
If hunk refining is off, then hunk refining is turned on, in
`all' mode (all hunks refined).

Customize variable `magit2-diff-refine-hunk' to change the default mode."
  (interactive "P")
  (setq-local magit2-diff-refine-hunk
              (if style
                  (if (eq magit2-diff-refine-hunk 'all) t 'all)
                (not magit2-diff-refine-hunk)))
  (magit2-diff-update-hunk-refinement))

;;;; Visit Commands
;;;;; Dwim Variants

(defun magit2-diff-visit-file (file &optional other-window)
  "From a diff visit the appropriate version of FILE.

Display the buffer in the selected window.  With a prefix
argument OTHER-WINDOW display the buffer in another window
instead.

Visit the worktree version of the appropriate file.  The location
of point inside the diff determines which file is being visited.
The visited version depends on what changes the diff is about.

1. If the diff shows uncommitted changes (i.e. stage or unstaged
   changes), then visit the file in the working tree (i.e. the
   same \"real\" file that `find-file' would visit.  In all other
   cases visit a \"blob\" (i.e. the version of a file as stored
   in some commit).

2. If point is on a removed line, then visit the blob for the
   first parent of the commit that removed that line, i.e. the
   last commit where that line still exists.

3. If point is on an added or context line, then visit the blob
   that adds that line, or if the diff shows from more than a
   single commit, then visit the blob from the last of these
   commits.

In the file-visiting buffer also go to the line that corresponds
to the line that point is on in the diff.

Note that this command only works if point is inside a diff.
In other cases `magit2-find-file' (which see) has to be used."
  (interactive (list (magit2-file-at-point t t) current-prefix-arg))
  (magit2-diff-visit-file--internal file nil
                                   (if other-window
                                       #'switch-to-buffer-other-window
                                     #'pop-to-buffer-same-window)))

(defun magit2-diff-visit-file-other-window (file)
  "From a diff visit the appropriate version of FILE in another window.
Like `magit2-diff-visit-file' but use
`switch-to-buffer-other-window'."
  (interactive (list (magit2-file-at-point t t)))
  (magit2-diff-visit-file--internal file nil #'switch-to-buffer-other-window))

(defun magit2-diff-visit-file-other-frame (file)
  "From a diff visit the appropriate version of FILE in another frame.
Like `magit2-diff-visit-file' but use
`switch-to-buffer-other-frame'."
  (interactive (list (magit2-file-at-point t t)))
  (magit2-diff-visit-file--internal file nil #'switch-to-buffer-other-frame))

;;;;; Worktree Variants

(defun magit2-diff-visit-worktree-file (file &optional other-window)
  "From a diff visit the worktree version of FILE.

Display the buffer in the selected window.  With a prefix
argument OTHER-WINDOW display the buffer in another window
instead.

Visit the worktree version of the appropriate file.  The location
of point inside the diff determines which file is being visited.

Unlike `magit2-diff-visit-file' always visits the \"real\" file in
the working tree, i.e the \"current version\" of the file.

In the file-visiting buffer also go to the line that corresponds
to the line that point is on in the diff.  Lines that were added
or removed in the working tree, the index and other commits in
between are automatically accounted for."
  (interactive (list (magit2-file-at-point t t) current-prefix-arg))
  (magit2-diff-visit-file--internal file t
                                   (if other-window
                                       #'switch-to-buffer-other-window
                                     #'pop-to-buffer-same-window)))

(defun magit2-diff-visit-worktree-file-other-window (file)
  "From a diff visit the worktree version of FILE in another window.
Like `magit2-diff-visit-worktree-file' but use
`switch-to-buffer-other-window'."
  (interactive (list (magit2-file-at-point t t)))
  (magit2-diff-visit-file--internal file t #'switch-to-buffer-other-window))

(defun magit2-diff-visit-worktree-file-other-frame (file)
  "From a diff visit the worktree version of FILE in another frame.
Like `magit2-diff-visit-worktree-file' but use
`switch-to-buffer-other-frame'."
  (interactive (list (magit2-file-at-point t t)))
  (magit2-diff-visit-file--internal file t #'switch-to-buffer-other-frame))

;;;;; Internal

(defun magit2-diff-visit-file--internal (file force-worktree fn)
  "From a diff visit the appropriate version of FILE.
If FORCE-WORKTREE is non-nil, then visit the worktree version of
the file, even if the diff is about a committed change.  Use FN
to display the buffer in some window."
  (if (magit2-file-accessible-directory-p file)
      (magit2-diff-visit-directory file force-worktree)
    (pcase-let ((`(,buf ,pos)
                 (magit2-diff-visit-file--noselect file force-worktree)))
      (funcall fn buf)
      (magit2-diff-visit-file--setup buf pos)
      buf)))

(defun magit2-diff-visit-directory (directory &optional other-window)
  "Visit DIRECTORY in some window.
Display the buffer in the selected window unless OTHER-WINDOW is
non-nil.  If DIRECTORY is the top-level directory of the current
repository, then visit the containing directory using Dired and
in the Dired buffer put point on DIRECTORY.  Otherwise display
the Magit-Status buffer for DIRECTORY."
  (if (equal (magit2-toplevel directory)
             (magit2-toplevel))
      (dired-jump other-window (concat directory "/."))
    (let ((display-buffer-overriding-action
           (if other-window
               '(nil (inhibit-same-window t))
             '(display-buffer-same-window))))
      (magit2-status-setup-buffer directory))))

(defun magit2-diff-visit-file--setup (buf pos)
  (if-let ((win (get-buffer-window buf 'visible)))
      (with-selected-window win
        (when pos
          (unless (<= (point-min) pos (point-max))
            (widen))
          (goto-char pos))
        (when (and buffer-file-name
                   (magit2-anything-unmerged-p buffer-file-name))
          (smerge-start-session))
        (run-hooks 'magit2-diff-visit-file-hook))
    (error "File buffer is not visible")))

(defun magit2-diff-visit-file--noselect (&optional file goto-worktree)
  (unless file
    (setq file (magit2-file-at-point t t)))
  (let* ((hunk (magit2-diff-visit--hunk))
         (goto-from (and hunk
                         (magit2-diff-visit--goto-from-p hunk goto-worktree)))
         (line (and hunk (magit2-diff-hunk-line   hunk goto-from)))
         (col  (and hunk (magit2-diff-hunk-column hunk goto-from)))
         (spec (magit2-diff--dwim))
         (rev  (if goto-from
                   (magit2-diff-visit--range-from spec)
                 (magit2-diff-visit--range-to spec)))
         (buf  (if (or goto-worktree
                       (and (not (stringp rev))
                            (or magit2-diff-visit-avoid-head-blob
                                (not goto-from))))
                   (or (get-file-buffer file)
                       (find-file-noselect file))
                 (magit2-find-file-noselect (if (stringp rev) rev "HEAD")
                                           file))))
    (if line
        (with-current-buffer buf
          (cond ((eq rev 'staged)
                 (setq line (magit2-diff-visit--offset file nil line)))
                ((and goto-worktree
                      (stringp rev))
                 (setq line (magit2-diff-visit--offset file rev line))))
          (list buf (save-restriction
                      (widen)
                      (goto-char (point-min))
                      (forward-line (1- line))
                      (move-to-column col)
                      (point))))
      (list buf nil))))

(defun magit2-diff-visit--hunk ()
  (when-let ((scope (magit2-diff-scope)))
    (let ((section (magit2-current-section)))
      (cl-case scope
        ((file files)
         (setq section (car (oref section children))))
        (list
         (setq section (car (oref section children)))
         (when section
           (setq section (car (oref section children))))))
      (and
       ;; Unmerged files appear in the list of staged changes
       ;; but unlike in the list of unstaged changes no diffs
       ;; are shown here.  In that case `section' is nil.
       section
       ;; Currently the `hunk' type is also abused for file
       ;; mode changes, which we are not interested in here.
       (not (equal (oref section value) '(chmod)))
       section))))

(defun magit2-diff-visit--goto-from-p (section in-worktree)
  (and magit2-diff-visit-previous-blob
       (not in-worktree)
       (not (oref section combined))
       (not (< (point) (oref section content)))
       (= (char-after (line-beginning-position)) ?-)))

(defvar magit2-diff-visit-jump-to-change t)

(defun magit2-diff-hunk-line (section goto-from)
  (save-excursion
    (goto-char (line-beginning-position))
    (with-slots (content combined from-ranges from-range to-range) section
      (when (and magit2-diff-visit-jump-to-change (< (point) content))
        (goto-char content)
        (re-search-forward "^[-+]"))
      (+ (car (if goto-from from-range to-range))
         (let ((prefix (if combined (length from-ranges) 1))
               (target (point))
               (offset 0))
           (goto-char content)
           (while (< (point) target)
             (unless (string-match-p
                      (if goto-from "\\+" "-")
                      (buffer-substring (point) (+ (point) prefix)))
               (cl-incf offset))
             (forward-line))
           offset)))))

(defun magit2-diff-hunk-column (section goto-from)
  (if (or (< (point)
             (oref section content))
          (and (not goto-from)
               (= (char-after (line-beginning-position)) ?-)))
      0
    (max 0 (- (+ (current-column) 2)
              (length (oref section value))))))

(defun magit2-diff-visit--range-from (spec)
  (cond ((consp spec)
         (concat (cdr spec) "^"))
        ((stringp spec)
         (car (magit2-split-range spec)))
        (t
         spec)))

(defun magit2-diff-visit--range-to (spec)
  (if (symbolp spec)
      spec
    (let ((rev (if (consp spec)
                   (cdr spec)
                 (cdr (magit2-split-range spec)))))
      (if (and magit2-diff-visit-avoid-head-blob
               (magit2-rev-head-p rev))
          'unstaged
        rev))))

(defun magit2-diff-visit--offset (file rev line)
  (let ((offset 0))
    (with-temp-buffer
      (save-excursion
        (magit2-with-toplevel
          (magit2-git-insert "diff" rev "--" file)))
      (catch 'found
        (while (re-search-forward
                "^@@ -\\([0-9]+\\),\\([0-9]+\\) \\+\\([0-9]+\\),\\([0-9]+\\) @@.*\n"
                nil t)
          (let ((from-beg (string-to-number (match-string 1)))
                (from-len (string-to-number (match-string 2)))
                (  to-len (string-to-number (match-string 4))))
            (if (<= from-beg line)
                (if (< (+ from-beg from-len) line)
                    (cl-incf offset (- to-len from-len))
                  (let ((rest (- line from-beg)))
                    (while (> rest 0)
                      (pcase (char-after)
                        (?\s                  (cl-decf rest))
                        (?-  (cl-decf offset) (cl-decf rest))
                        (?+  (cl-incf offset)))
                      (forward-line))))
              (throw 'found nil))))))
    (+ line offset)))

;;;; Scroll Commands

(defun magit2-diff-show-or-scroll-up ()
  "Update the commit or diff buffer for the thing at point.

Either show the commit or stash at point in the appropriate
buffer, or if that buffer is already being displayed in the
current frame and contains information about that commit or
stash, then instead scroll the buffer up.  If there is no
commit or stash at point, then prompt for a commit."
  (interactive)
  (magit2-diff-show-or-scroll 'scroll-up))

(defun magit2-diff-show-or-scroll-down ()
  "Update the commit or diff buffer for the thing at point.

Either show the commit or stash at point in the appropriate
buffer, or if that buffer is already being displayed in the
current frame and contains information about that commit or
stash, then instead scroll the buffer down.  If there is no
commit or stash at point, then prompt for a commit."
  (interactive)
  (magit2-diff-show-or-scroll 'scroll-down))

(defun magit2-diff-show-or-scroll (fn)
  (let (rev cmd buf win)
    (cond
     (magit2-blame-mode
      (setq rev (oref (magit2-current-blame-chunk) orig-rev))
      (setq cmd 'magit2-show-commit)
      (setq buf (magit2-get-mode-buffer 'magit2-revision-mode)))
     ((derived-mode-p 'git-rebase-mode)
      (with-slots (action-type target)
          (git-rebase-current-line)
        (if (not (eq action-type 'commit))
            (user-error "No commit on this line")
          (setq rev target)
          (setq cmd 'magit2-show-commit)
          (setq buf (magit2-get-mode-buffer 'magit2-revision-mode)))))
     (t
      (magit2-section-case
        (branch
         (setq rev (magit2-ref-maybe-qualify (oref it value)))
         (setq cmd 'magit2-show-commit)
         (setq buf (magit2-get-mode-buffer 'magit2-revision-mode)))
        (commit
         (setq rev (oref it value))
         (setq cmd 'magit2-show-commit)
         (setq buf (magit2-get-mode-buffer 'magit2-revision-mode)))
        (stash
         (setq rev (oref it value))
         (setq cmd 'magit2-stash-show)
         (setq buf (magit2-get-mode-buffer 'magit2-stash-mode))))))
    (if rev
        (if (and buf
                 (setq win (get-buffer-window buf))
                 (with-current-buffer buf
                   (and (equal rev magit2-buffer-revision)
                        (equal (magit2-rev-parse rev)
                               magit2-buffer-revision-hash))))
            (with-selected-window win
              (condition-case nil
                  (funcall fn)
                (error
                 (goto-char (pcase fn
                              (`scroll-up   (point-min))
                              (`scroll-down (point-max)))))))
          (let ((magit2-display-buffer-noselect t))
            (if (eq cmd 'magit2-show-commit)
                (apply #'magit2-show-commit rev (magit2-show-commit--arguments))
              (funcall cmd rev))))
      (call-interactively #'magit2-show-commit))))

;;;; Section Commands

(defun magit2-section-cycle-diffs ()
  "Cycle visibility of diff-related sections in the current buffer."
  (interactive)
  (when-let ((sections
              (cond ((derived-mode-p 'magit2-status-mode)
                     (--mapcat
                      (when it
                        (when (oref it hidden)
                          (magit2-section-show it))
                        (oref it children))
                      (list (magit2-get-section '((staged)   (status)))
                            (magit2-get-section '((unstaged) (status))))))
                    ((derived-mode-p 'magit2-diff-mode)
                     (-filter #'magit2-file-section-p
                              (oref magit2-root-section children))))))
    (if (--any-p (oref it hidden) sections)
        (dolist (s sections)
          (magit2-section-show s)
          (magit2-section-hide-children s))
      (let ((children (--mapcat (oref it children) sections)))
        (cond ((and (--any-p (oref it hidden)   children)
                    (--any-p (oref it children) children))
               (mapc 'magit2-section-show-headings sections))
              ((seq-some 'magit2-section-hidden-body children)
               (mapc 'magit2-section-show-children sections))
              (t
               (mapc 'magit2-section-hide sections)))))))

;;; Diff Mode

(defvar magit2-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-mode-map)
    (define-key map (kbd "C-c C-d") 'magit2-diff-while-committing)
    (define-key map (kbd "C-c C-b") 'magit2-go-backward)
    (define-key map (kbd "C-c C-f") 'magit2-go-forward)
    (define-key map (kbd "SPC") 'scroll-up)
    (define-key map (kbd "DEL") 'scroll-down)
    (define-key map (kbd "j")   'magit2-jump-to-diffstat-or-diff)
    (define-key map [remap write-file] 'magit2-patch-save)
    map)
  "Keymap for `magit2-diff-mode'.")

(define-derived-mode magit2-diff-mode magit2-mode "Magit Diff"
  "Mode for looking at a Git diff.

This mode is documented in info node `(magit2)Diff Buffer'.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-section-toggle] to expand or hide the section at point.
Type \\[magit2-visit-thing] to visit the hunk or file at point.

Staging and applying changes is documented in info node
`(magit2)Staging and Unstaging' and info node `(magit2)Applying'.

\\<magit2-hunk-section-map>Type \
\\[magit2-apply] to apply the change at point, \
\\[magit2-stage] to stage,
\\[magit2-unstage] to unstage, \
\\[magit2-discard] to discard, or \
\\[magit2-reverse] to reverse it.

\\{magit2-diff-mode-map}"
  :group 'magit2-diff
  (hack-dir-local-variables-non-file-buffer)
  (setq magit2--imenu-item-types 'file))

(put 'magit2-diff-mode 'magit2-diff-default-arguments
     '("--stat" "--no-ext-diff"))

(defun magit2-diff-setup-buffer (range typearg args files &optional locked)
  (require 'magit2)
  (magit2-setup-buffer #'magit2-diff-mode locked
    (magit2-buffer-range range)
    (magit2-buffer-typearg typearg)
    (magit2-buffer-diff-args args)
    (magit2-buffer-diff-files files)
    (magit2-buffer-diff-files-suspended nil)))

(defun magit2-diff-refresh-buffer ()
  "Refresh the current `magit2-diff-mode' buffer."
  (magit2-set-header-line-format
   (if (equal magit2-buffer-typearg "--no-index")
       (apply #'format "Differences between %s and %s" magit2-buffer-diff-files)
     (concat (if magit2-buffer-range
                 (cond
                  ((string-match-p "\\(\\.\\.\\|\\^-\\)"
                                   magit2-buffer-range)
                   (format "Changes in %s" magit2-buffer-range))
                  ((member "-R" magit2-buffer-diff-args)
                   (format "Changes from working tree to %s" magit2-buffer-range))
                  (t
                   (format "Changes from %s to working tree" magit2-buffer-range)))
               (if (equal magit2-buffer-typearg "--cached")
                   "Staged changes"
                 "Unstaged changes"))
             (pcase (length magit2-buffer-diff-files)
               (0)
               (1 (concat " in file " (car magit2-buffer-diff-files)))
               (_ (concat " in files "
                          (mapconcat #'identity magit2-buffer-diff-files ", ")))))))
  (setq magit2-buffer-range-hashed
        (and magit2-buffer-range (magit2-hash-range magit2-buffer-range)))
  (magit2-insert-section (diffbuf)
    (magit2-run-section-hook 'magit2-diff-sections-hook)))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-diff-mode))
  (nconc (cond (magit2-buffer-range
                (delq nil (list magit2-buffer-range magit2-buffer-typearg)))
               ((equal magit2-buffer-typearg "--cached")
                (list 'staged))
               (t
                (list 'unstaged magit2-buffer-typearg)))
         (and magit2-buffer-diff-files (cons "--" magit2-buffer-diff-files))))

(defvar magit2-diff-section-base-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-j")            'magit2-diff-visit-worktree-file)
    (define-key map (kbd "C-<return>")     'magit2-diff-visit-worktree-file)
    (define-key map (kbd "C-x 4 <return>") 'magit2-diff-visit-file-other-window)
    (define-key map (kbd "C-x 5 <return>") 'magit2-diff-visit-file-other-frame)
    (define-key map [remap magit2-visit-thing]      'magit2-diff-visit-file)
    (define-key map [remap magit2-delete-thing]     'magit2-discard)
    (define-key map [remap magit2-revert-no-commit] 'magit2-reverse)
    (define-key map "a" 'magit2-apply)
    (define-key map "s" 'magit2-stage)
    (define-key map "u" 'magit2-unstage)
    (define-key map "&" 'magit2-do-async-shell-command)
    (define-key map "C"             'magit2-commit-add-log)
    (define-key map (kbd "C-x a")   'magit2-add-change-log-entry)
    (define-key map (kbd "C-x 4 a") 'magit2-add-change-log-entry-other-window)
    (define-key map (kbd "C-c C-t") 'magit2-diff-trace-definition)
    (define-key map (kbd "C-c C-e") 'magit2-diff-edit-hunk-commit)
    map)
  "Parent of `magit2-{hunk,file}-section-map'.")

(defvar magit2-file-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-diff-section-base-map)
    map)
  "Keymap for `file' sections.")

(defvar magit2-hunk-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-diff-section-base-map)
    (let ((m (make-sparse-keymap)))
      (define-key m (kbd "RET") 'magit2-smerge-keep-current)
      (define-key m (kbd "u")   'magit2-smerge-keep-upper)
      (define-key m (kbd "b")   'magit2-smerge-keep-base)
      (define-key m (kbd "l")   'magit2-smerge-keep-lower)
      (define-key map smerge-command-prefix m))
    map)
  "Keymap for `hunk' sections.")

(defconst magit2-diff-conflict-headline-re
  (concat "^" (regexp-opt
               ;; Defined in merge-tree.c in this order.
               '("merged"
                 "added in remote"
                 "added in both"
                 "added in local"
                 "removed in both"
                 "changed in both"
                 "removed in local"
                 "removed in remote"))))

(defconst magit2-diff-headline-re
  (concat "^\\(@@@?\\|diff\\|Submodule\\|"
          "\\* Unmerged path\\|"
          (substring magit2-diff-conflict-headline-re 1)
          "\\)"))

(defconst magit2-diff-statline-re
  (concat "^ ?"
          "\\(.*\\)"     ; file
          "\\( +| +\\)"  ; separator
          "\\([0-9]+\\|Bin\\(?: +[0-9]+ -> [0-9]+ bytes\\)?$\\) ?"
          "\\(\\+*\\)"   ; add
          "\\(-*\\)$"))  ; del

(defvar magit2-diff--reset-non-color-moved
  (list
   "-c" "color.diff.context=normal"
   "-c" "color.diff.plain=normal" ; historical synonym for context
   "-c" "color.diff.meta=normal"
   "-c" "color.diff.frag=normal"
   "-c" "color.diff.func=normal"
   "-c" "color.diff.old=normal"
   "-c" "color.diff.new=normal"
   "-c" "color.diff.commit=normal"
   "-c" "color.diff.whitespace=normal"
   ;; "git-range-diff" does not support "--color-moved", so we don't
   ;; need to reset contextDimmed, oldDimmed, newDimmed, contextBold,
   ;; oldBold, and newBold.
   ))

(defun magit2-insert-diff ()
  "Insert the diff into this `magit2-diff-mode' buffer."
  (magit2--insert-diff
    "diff" magit2-buffer-range "-p" "--no-prefix"
    (and (member "--stat" magit2-buffer-diff-args) "--numstat")
    magit2-buffer-typearg
    magit2-buffer-diff-args "--"
    magit2-buffer-diff-files))

(defun magit2--insert-diff (&rest args)
  (declare (indent 0))
  (pcase-let ((`(,cmd . ,args)
               (-flatten args))
              (magit2-git-global-arguments
               (remove "--literal-pathspecs" magit2-git-global-arguments)))
    ;; As of Git 2.19.0, we need to generate diffs with
    ;; --ita-visible-in-index so that `magit2-stage' can work with
    ;; intent-to-add files (see #4026).
    (when (and (not (equal cmd "merge-tree"))
               (magit2-git-version>= "2.19.0"))
      (push "--ita-visible-in-index" args))
    (setq args (magit2-diff--maybe-add-stat-arguments args))
    (when (cl-member-if (lambda (arg) (string-prefix-p "--color-moved" arg)) args)
      (push "--color=always" args)
      (setq magit2-git-global-arguments
            (append magit2-diff--reset-non-color-moved
                    magit2-git-global-arguments)))
    (magit2-git-wash #'magit2-diff-wash-diffs cmd args)))

(defun magit2-diff--maybe-add-stat-arguments (args)
  (if (member "--stat" args)
      (append (if (functionp magit2-diff-extra-stat-arguments)
                  (funcall magit2-diff-extra-stat-arguments)
                magit2-diff-extra-stat-arguments)
              args)
    args))

(defun magit2-diff-use-window-width-as-stat-width ()
  "Use the `window-width' as the value of `--stat-width'."
  (when-let ((window (get-buffer-window (current-buffer) 'visible)))
    (list (format "--stat-width=%d" (window-width window)))))

(defun magit2-diff-wash-diffs (args &optional limit)
  (run-hooks 'magit2-diff-wash-diffs-hook)
  (when (member "--show-signature" args)
    (magit2-diff-wash-signature))
  (when (member "--stat" args)
    (magit2-diff-wash-diffstat))
  (when (re-search-forward magit2-diff-headline-re limit t)
    (goto-char (line-beginning-position))
    (magit2-wash-sequence (apply-partially 'magit2-diff-wash-diff args))
    (insert ?\n)))

(defun magit2-jump-to-diffstat-or-diff ()
  "Jump to the diffstat or diff.
When point is on a file inside the diffstat section, then jump
to the respective diff section, otherwise jump to the diffstat
section or a child thereof."
  (interactive)
  (--if-let (magit2-get-section
             (append (magit2-section-case
                       ([file diffstat] `((file . ,(oref it value))))
                       (file `((file . ,(oref it value)) (diffstat)))
                       (t '((diffstat))))
                     (magit2-section-ident magit2-root-section)))
      (magit2-section-goto it)
    (user-error "No diffstat in this buffer")))

(defun magit2-diff-wash-signature ()
  (when (looking-at "^gpg: ")
    (let (title end)
      (save-excursion
        (while (looking-at "^gpg: ")
          (cond
           ((looking-at "^gpg: Good signature from")
            (setq title (propertize
                         (buffer-substring (point) (line-end-position))
                         'face 'magit2-signature-good)))
           ((looking-at "^gpg: Can't check signature")
            (setq title (propertize
                         (buffer-substring (point) (line-end-position))
                         'face '(italic bold)))))
          (forward-line))
        (setq end (point-marker)))
        (magit2-insert-section (signature magit2-buffer-revision title)
          (when title
            (magit2-insert-heading title))
          (goto-char end)
          (insert "\n")))))

(defun magit2-diff-wash-diffstat ()
  (let (heading (beg (point)))
    (when (re-search-forward "^ ?\\([0-9]+ +files? change[^\n]*\n\\)" nil t)
      (setq heading (match-string 1))
      (magit2-delete-match)
      (goto-char beg)
      (magit2-insert-section (diffstat)
        (insert (propertize heading 'font-lock-face 'magit2-diff-file-heading))
        (magit2-insert-heading)
        (let (files)
          (while (looking-at "^[-0-9]+\t[-0-9]+\t\\(.+\\)$")
            (push (magit2-decode-git-path
                   (let ((f (match-string 1)))
                     (cond
                      ((string-match "\\`\\([^{]+\\){\\(.+\\) => \\(.+\\)}\\'" f)
                       (concat (match-string 1 f)
                               (match-string 3 f)))
                      ((string-match " => " f)
                       (substring f (match-end 0)))
                      (t f))))
                  files)
            (magit2-delete-line))
          (setq files (nreverse files))
          (while (looking-at magit2-diff-statline-re)
            (magit2-bind-match-strings (file sep cnt add del) nil
              (magit2-delete-line)
              (when (string-match " +$" file)
                (setq sep (concat (match-string 0 file) sep))
                (setq file (substring file 0 (match-beginning 0))))
              (let ((le (length file)) ld)
                (setq file (magit2-decode-git-path file))
                (setq ld (length file))
                (when (> le ld)
                  (setq sep (concat (make-string (- le ld) ?\s) sep))))
              (magit2-insert-section (file (pop files))
                (insert (propertize file 'font-lock-face 'magit2-filename)
                        sep cnt " ")
                (when add
                  (insert (propertize add 'font-lock-face
                                      'magit2-diffstat-added)))
                (when del
                  (insert (propertize del 'font-lock-face
                                      'magit2-diffstat-removed)))
                (insert "\n")))))
        (if (looking-at "^$") (forward-line) (insert "\n"))))))

(defun magit2-diff-wash-diff (args)
  (when (cl-member-if (lambda (arg) (string-prefix-p "--color-moved" arg)) args)
    (require 'ansi-color)
    (ansi-color-apply-on-region (point-min) (point-max)))
  (cond
   ((looking-at "^Submodule")
    (magit2-diff-wash-submodule))
   ((looking-at "^\\* Unmerged path \\(.*\\)")
    (let ((file (magit2-decode-git-path (match-string 1))))
      (magit2-delete-line)
      (unless (and (derived-mode-p 'magit2-status-mode)
                   (not (member "--cached" args)))
        (magit2-insert-section (file file)
          (insert (propertize
                   (format "unmerged   %s%s" file
                           (pcase (cddr (car (magit2-file-status file)))
                             (`(?D ?D) " (both deleted)")
                             (`(?D ?U) " (deleted by us)")
                             (`(?U ?D) " (deleted by them)")
                             (`(?A ?A) " (both added)")
                             (`(?A ?U) " (added by us)")
                             (`(?U ?A) " (added by them)")
                             (`(?U ?U) "")))
                   'font-lock-face 'magit2-diff-file-heading))
          (insert ?\n))))
    t)
   ((looking-at magit2-diff-conflict-headline-re)
    (let ((long-status (match-string 0))
          (status "BUG")
          file orig base)
      (if (equal long-status "merged")
          (progn (setq status long-status)
                 (setq long-status nil))
        (setq status (pcase-exhaustive long-status
                       ("added in remote"   "new file")
                       ("added in both"     "new file")
                       ("added in local"    "new file")
                       ("removed in both"   "removed")
                       ("changed in both"   "changed")
                       ("removed in local"  "removed")
                       ("removed in remote" "removed"))))
      (magit2-delete-line)
      (while (looking-at
              "^  \\([^ ]+\\) +[0-9]\\{6\\} \\([a-z0-9]\\{40,\\}\\) \\(.+\\)$")
        (magit2-bind-match-strings (side _blob name) nil
          (pcase side
            ("result" (setq file name))
            ("our"    (setq orig name))
            ("their"  (setq file name))
            ("base"   (setq base name))))
        (magit2-delete-line))
      (when orig (setq orig (magit2-decode-git-path orig)))
      (when file (setq file (magit2-decode-git-path file)))
      (magit2-diff-insert-file-section
       (or file base) orig status nil nil nil long-status)))
   ;; The files on this line may be ambiguous due to whitespace.
   ;; That's okay. We can get their names from subsequent headers.
   ((looking-at "^diff --\
\\(?:\\(?1:git\\) \\(?:\\(?2:.+?\\) \\2\\)?\
\\|\\(?:cc\\|combined\\) \\(?3:.+\\)\\)")
    (let ((status (cond ((equal (match-string 1) "git")        "modified")
                        ((derived-mode-p 'magit2-revision-mode) "resolved")
                        (t                                     "unmerged")))
          (orig nil)
          (file (or (match-string 2) (match-string 3)))
          (header (list (buffer-substring-no-properties
                         (line-beginning-position) (1+ (line-end-position)))))
          (modes nil)
          (rename nil))
      (magit2-delete-line)
      (while (not (or (eobp) (looking-at magit2-diff-headline-re)))
        (cond
         ((looking-at "old mode \\(?:[^\n]+\\)\nnew mode \\(?:[^\n]+\\)\n")
          (setq modes (match-string 0)))
         ((looking-at "deleted file .+\n")
          (setq status "deleted"))
         ((looking-at "new file .+\n")
          (setq status "new file"))
         ((looking-at "rename from \\(.+\\)\nrename to \\(.+\\)\n")
          (setq rename (match-string 0))
          (setq orig (match-string 1))
          (setq file (match-string 2))
          (setq status "renamed"))
         ((looking-at "copy from \\(.+\\)\ncopy to \\(.+\\)\n")
          (setq orig (match-string 1))
          (setq file (match-string 2))
          (setq status "new file"))
         ((looking-at "similarity index .+\n"))
         ((looking-at "dissimilarity index .+\n"))
         ((looking-at "index .+\n"))
         ((looking-at "--- \\(.+?\\)\t?\n")
          (unless (equal (match-string 1) "/dev/null")
            (setq orig (match-string 1))))
         ((looking-at "\\+\\+\\+ \\(.+?\\)\t?\n")
          (unless (equal (match-string 1) "/dev/null")
            (setq file (match-string 1))))
         ((looking-at "Binary files .+ and .+ differ\n"))
         ((looking-at "Binary files differ\n"))
         ;; TODO Use all combined diff extended headers.
         ((looking-at "mode .+\n"))
         (t
          (error "BUG: Unknown extended header: %S"
                 (buffer-substring (point) (line-end-position)))))
        ;; These headers are treated as some sort of special hunk.
        (unless (or (string-prefix-p "old mode" (match-string 0))
                    (string-prefix-p "rename"   (match-string 0)))
          (push (match-string 0) header))
        (magit2-delete-match))
      (setq header (mapconcat #'identity (nreverse header) ""))
      (when orig
        (setq orig (magit2-decode-git-path orig)))
      (setq file (magit2-decode-git-path file))
      ;; KLUDGE `git-diff' ignores `--no-prefix' for new files and renames at
      ;; least.  And `git-log' ignores `--no-prefix' when `-L' is used.
      (when (or (and file orig
                     (string-prefix-p "a/" orig)
                     (string-prefix-p "b/" file))
                (and (derived-mode-p 'magit2-log-mode)
                     (--first (string-match-p "\\`-L" it)
                              magit2-buffer-log-args)))
        (setq file (substring file 2))
        (when orig
          (setq orig (substring orig 2))))
      (magit2-diff-insert-file-section file orig status modes rename header)))))

(defun magit2-diff-insert-file-section
    (file orig status modes rename header &optional long-status)
  (magit2-insert-section section
    (file file (or (equal status "deleted")
                   (derived-mode-p 'magit2-status-mode)))
    (insert (propertize (format "%-10s %s" status
                                (if (or (not orig) (equal orig file))
                                    file
                                  (format "%s -> %s" orig file)))
                        'font-lock-face 'magit2-diff-file-heading))
    (when long-status
      (insert (format " (%s)" long-status)))
    (magit2-insert-heading)
    (unless (equal orig file)
      (oset section source orig))
    (oset section header header)
    (when modes
      (magit2-insert-section (hunk '(chmod))
        (insert modes)
        (magit2-insert-heading)))
    (when rename
      (magit2-insert-section (hunk '(rename))
        (insert rename)
        (magit2-insert-heading)))
    (magit2-wash-sequence #'magit2-diff-wash-hunk)))

(defun magit2-diff-wash-submodule ()
  ;; See `show_submodule_summary' in submodule.c and "this" commit.
  (when (looking-at "^Submodule \\([^ ]+\\)")
    (let ((module (match-string 1))
          untracked modified)
      (when (looking-at "^Submodule [^ ]+ contains untracked content$")
        (magit2-delete-line)
        (setq untracked t))
      (when (looking-at "^Submodule [^ ]+ contains modified content$")
        (magit2-delete-line)
        (setq modified t))
      (cond
       ((and (looking-at "^Submodule \\([^ ]+\\) \\([^ :]+\\)\\( (rewind)\\)?:$")
             (equal (match-string 1) module))
        (magit2-bind-match-strings (_module range rewind) nil
          (magit2-delete-line)
          (while (looking-at "^  \\([<>]\\) \\(.*\\)$")
            (magit2-delete-line))
          (when rewind
            (setq range (replace-regexp-in-string "[^.]\\(\\.\\.\\)[^.]"
                                                  "..." range t t 1)))
          (magit2-insert-section (magit2-module-section module t)
            (magit2-insert-heading
              (propertize (concat "modified   " module)
                          'font-lock-face 'magit2-diff-file-heading)
              " ("
              (cond (rewind "rewind")
                    ((string-match-p "\\.\\.\\." range) "non-ff")
                    (t "new commits"))
              (and (or modified untracked)
                   (concat ", "
                           (and modified "modified")
                           (and modified untracked " and ")
                           (and untracked "untracked")
                           " content"))
              ")")
            (let ((default-directory
                    (file-name-as-directory
                     (expand-file-name module (magit2-toplevel)))))
              (magit2-git-wash (apply-partially 'magit2-log-wash-log 'module)
                "log" "--oneline" "--left-right" range)
              (delete-char -1)))))
       ((and (looking-at "^Submodule \\([^ ]+\\) \\([^ ]+\\) (\\([^)]+\\))$")
             (equal (match-string 1) module))
        (magit2-bind-match-strings (_module _range msg) nil
          (magit2-delete-line)
          (magit2-insert-section (magit2-module-section module)
            (magit2-insert-heading
              (propertize (concat "submodule  " module)
                          'font-lock-face 'magit2-diff-file-heading)
              " (" msg ")"))))
       (t
        (magit2-insert-section (magit2-module-section module)
          (magit2-insert-heading
            (propertize (concat "modified   " module)
                        'font-lock-face 'magit2-diff-file-heading)
            " ("
            (and modified "modified")
            (and modified untracked " and ")
            (and untracked "untracked")
            " content)")))))))

(defun magit2-diff-wash-hunk ()
  (when (looking-at "^@\\{2,\\} \\(.+?\\) @\\{2,\\}\\(?: \\(.*\\)\\)?")
    (let* ((heading  (match-string 0))
           (ranges   (mapcar (lambda (str)
                               (mapcar #'string-to-number
                                       (split-string (substring str 1) ",")))
                             (split-string (match-string 1))))
           (about    (match-string 2))
           (combined (= (length ranges) 3))
           (value    (cons about ranges)))
      (magit2-delete-line)
      (magit2-insert-section section (hunk value)
        (insert (propertize (concat heading "\n")
                            'font-lock-face 'magit2-diff-hunk-heading))
        (magit2-insert-heading)
        (while (not (or (eobp) (looking-at "^[^-+\s\\]")))
          (forward-line))
        (oset section end (point))
        (oset section washer 'magit2-diff-paint-hunk)
        (oset section combined combined)
        (if combined
            (oset section from-ranges (butlast ranges))
          (oset section from-range (car ranges)))
        (oset section to-range (car (last ranges)))
        (oset section about about)))
    t))

(defun magit2-diff-expansion-threshold (section)
  "Keep new diff sections collapsed if washing takes too long."
  (and (magit2-file-section-p section)
       (> (float-time (time-subtract (current-time) magit2-refresh-start-time))
          magit2-diff-expansion-threshold)
       'hide))

(add-hook 'magit2-section-set-visibility-hook #'magit2-diff-expansion-threshold)

;;; Revision Mode

(define-derived-mode magit2-revision-mode magit2-diff-mode "Magit Rev"
  "Mode for looking at a Git commit.

This mode is documented in info node `(magit2)Revision Buffer'.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-section-toggle] to expand or hide the section at point.
Type \\[magit2-visit-thing] to visit the hunk or file at point.

Staging and applying changes is documented in info node
`(magit2)Staging and Unstaging' and info node `(magit2)Applying'.

\\<magit2-hunk-section-map>Type \
\\[magit2-apply] to apply the change at point, \
\\[magit2-stage] to stage,
\\[magit2-unstage] to unstage, \
\\[magit2-discard] to discard, or \
\\[magit2-reverse] to reverse it.

\\{magit2-revision-mode-map}"
  :group 'magit2-revision
  (hack-dir-local-variables-non-file-buffer))

(put 'magit2-revision-mode 'magit2-diff-default-arguments
     '("--stat" "--no-ext-diff"))

(defun magit2-revision-setup-buffer (rev args files)
  (magit2-setup-buffer #'magit2-revision-mode nil
    (magit2-buffer-revision rev)
    (magit2-buffer-range (format "%s^..%s" rev rev))
    (magit2-buffer-diff-args args)
    (magit2-buffer-diff-files files)
    (magit2-buffer-diff-files-suspended nil)))

(defun magit2-revision-refresh-buffer ()
  (setq magit2-buffer-revision-hash (magit2-rev-parse magit2-buffer-revision))
  (magit2-set-header-line-format
   (concat (magit2-object-type magit2-buffer-revision-hash)
           " "  magit2-buffer-revision
           (pcase (length magit2-buffer-diff-files)
             (0)
             (1 (concat " limited to file " (car magit2-buffer-diff-files)))
             (_ (concat " limited to files "
                        (mapconcat #'identity magit2-buffer-diff-files ", "))))))
  (magit2-insert-section (commitbuf)
    (magit2-run-section-hook 'magit2-revision-sections-hook)))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-revision-mode))
  (cons magit2-buffer-revision magit2-buffer-diff-files))

(defun magit2-insert-revision-diff ()
  "Insert the diff into this `magit2-revision-mode' buffer."
  (magit2--insert-diff
    "show" "-p" "--cc" "--format=" "--no-prefix"
    (and (member "--stat" magit2-buffer-diff-args) "--numstat")
    magit2-buffer-diff-args
    (concat magit2-buffer-revision "^{commit}")
    "--" magit2-buffer-diff-files))

(defun magit2-insert-revision-tag ()
  "Insert tag message and headers into a revision buffer.
This function only inserts anything when `magit2-show-commit' is
called with a tag as argument, when that is called with a commit
or a ref which is not a branch, then it inserts nothing."
  (when (equal (magit2-object-type magit2-buffer-revision) "tag")
    (magit2-insert-section (taginfo)
      (let ((beg (point)))
        ;; "git verify-tag -v" would output what we need, but the gpg
        ;; output is send to stderr and we have no control over the
        ;; order in which stdout and stderr are inserted, which would
        ;; make parsing hard.  We are forced to use "git cat-file tag"
        ;; instead, which inserts the signature instead of verifying
        ;; it.  We remove that later and then insert the verification
        ;; output using "git verify-tag" (without the "-v").
        (magit2-git-insert "cat-file" "tag" magit2-buffer-revision)
        (goto-char beg)
        (forward-line 3)
        (delete-region beg (point)))
      (looking-at "^tagger \\([^<]+\\) <\\([^>]+\\)")
      (let ((heading (format "Tagger: %s <%s>"
                             (match-string 1)
                             (match-string 2))))
        (magit2-delete-line)
        (insert (propertize heading 'font-lock-face
                            'magit2-section-secondary-heading)))
      (magit2-insert-heading)
      (if (re-search-forward "-----BEGIN PGP SIGNATURE-----" nil t)
          (progn
            (let ((beg (match-beginning 0)))
              (re-search-forward "-----END PGP SIGNATURE-----")
              (delete-region beg (point)))
            (insert ?\n)
            (magit2-process-git t "verify-tag" magit2-buffer-revision))
        (goto-char (point-max)))
      (insert ?\n))))

(defvar magit2-commit-message-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-show-commit)
    map)
  "Keymap for `commit-message' sections.")

(defun magit2-insert-revision-message ()
  "Insert the commit message into a revision buffer."
  (magit2-insert-section section (commit-message)
    (oset section heading-highlight-face 'magit2-diff-revision-summary-highlight)
    (let ((beg (point))
          (rev magit2-buffer-revision))
      (insert (with-temp-buffer
                (magit2-rev-insert-format "%B" rev)
                (magit2-revision--wash-message)))
      (if (= (point) (+ beg 2))
          (progn (backward-delete-char 2)
                 (insert "(no message)\n"))
        (goto-char beg)
        (save-excursion
          (while (search-forward "\r\n" nil t) ; Remove trailing CRs.
            (delete-region (match-beginning 0) (1+ (match-beginning 0)))))
        (when magit2-revision-fill-summary-line
          (let ((fill-column (min magit2-revision-fill-summary-line
                                  (window-width))))
            (fill-region (point) (line-end-position))))
        (when magit2-revision-use-hash-sections
          (save-excursion
            ;; Start after beg to prevent a (commit text) section from
            ;; starting at the same point as the (commit-message)
            ;; section.
            (goto-char (1+ beg))
            (while (not (eobp))
              (re-search-forward "\\_<" nil 'move)
              (let ((beg (point)))
                (re-search-forward "\\_>" nil t)
                (when (> (point) beg)
                  (let ((text (buffer-substring-no-properties beg (point))))
                    (when (pcase magit2-revision-use-hash-sections
                            (`quickest ; false negatives and positives
                             (and (>= (length text) 7)
                                  (string-match-p "[0-9]" text)
                                  (string-match-p "[a-z]" text)))
                            (`quicker  ; false negatives (number-less hashes)
                             (and (>= (length text) 7)
                                  (string-match-p "[0-9]" text)
                                  (magit2-rev-hash text)))
                            (`quick    ; false negatives (short hashes)
                             (and (>= (length text) 7)
                                  (magit2-rev-hash text)))
                            (`slow
                             (magit2-rev-hash text)))
                      (put-text-property beg (point)
                                         'font-lock-face 'magit2-hash)
                      (let ((end (point)))
                        (goto-char beg)
                        (magit2-insert-section (commit text)
                          (goto-char end))))))))))
        (save-excursion
          (forward-line)
          (magit2--add-face-text-property
           beg (point) 'magit2-diff-revision-summary)
          (magit2-insert-heading))
        (when magit2-diff-highlight-keywords
          (save-excursion
            (while (re-search-forward "\\[[^[]*\\]" nil t)
              (let ((beg (match-beginning 0))
                    (end (match-end 0)))
                (put-text-property
                 beg end 'font-lock-face
                 (if-let ((face (get-text-property beg 'font-lock-face)))
                     (list face 'magit2-keyword)
                   'magit2-keyword))))))
        (goto-char (point-max))))))

(defun magit2-insert-revision-notes ()
  "Insert commit notes into a revision buffer."
  (let* ((var "core.notesRef")
         (def (or (magit2-get var) "refs/notes/commits")))
    (dolist (ref (or (magit2-list-active-notes-refs)))
      (magit2-insert-section section (notes ref (not (equal ref def)))
        (oset section heading-highlight-face 'magit2-diff-hunk-heading-highlight)
        (let ((beg (point))
              (rev magit2-buffer-revision))
          (insert (with-temp-buffer
                    (magit2-git-insert "-c" (concat "core.notesRef=" ref)
                                      "notes" "show" rev)
                    (magit2-revision--wash-message)))
          (if (= (point) beg)
              (magit2-cancel-section)
            (goto-char beg)
            (end-of-line)
            (insert (format " (%s)"
                            (propertize (if (string-prefix-p "refs/notes/" ref)
                                            (substring ref 11)
                                          ref)
                                        'font-lock-face 'magit2-refname)))
            (forward-char)
            (magit2--add-face-text-property beg (point) 'magit2-diff-hunk-heading)
            (magit2-insert-heading)
            (goto-char (point-max))
            (insert ?\n)))))))

(defun magit2-revision--wash-message ()
  (let ((major-mode 'git-commit-mode))
    (hack-dir-local-variables)
    (hack-local-variables-apply))
  (unless (memq git-commit-major-mode '(nil text-mode))
    (funcall git-commit-major-mode)
    (font-lock-ensure))
  (buffer-string))

(defun magit2-insert-revision-headers ()
  "Insert headers about the commit into a revision buffer."
  (magit2-insert-section (headers)
    (--when-let (magit2-rev-format "%D" magit2-buffer-revision "--decorate=full")
      (insert (magit2-format-ref-labels it) ?\s))
    (insert (propertize
             (magit2-rev-parse (concat magit2-buffer-revision "^{commit}"))
             'font-lock-face 'magit2-hash))
    (magit2-insert-heading)
    (let ((beg (point)))
      (magit2-rev-insert-format magit2-revision-headers-format
                               magit2-buffer-revision)
      (magit2-insert-revision-gravatars magit2-buffer-revision beg))
    (when magit2-revision-insert-related-refs
      (dolist (parent (magit2-commit-parents magit2-buffer-revision))
        (magit2-insert-section (commit parent)
          (let ((line (magit2-rev-format "%h %s" parent)))
            (string-match "^\\([^ ]+\\) \\(.*\\)" line)
            (magit2-bind-match-strings (hash msg) line
              (insert "Parent:     ")
              (insert (propertize hash 'font-lock-face 'magit2-hash))
              (insert " " msg "\n")))))
      (magit2--insert-related-refs
       magit2-buffer-revision "--merged" "Merged"
       (eq magit2-revision-insert-related-refs 'all))
      (magit2--insert-related-refs
       magit2-buffer-revision "--contains" "Contained"
       (memq magit2-revision-insert-related-refs '(all mixed)))
      (when-let ((follows (magit2-get-current-tag magit2-buffer-revision t)))
        (let ((tag (car  follows))
              (cnt (cadr follows)))
          (magit2-insert-section (tag tag)
            (insert
             (format "Follows:    %s (%s)\n"
                     (propertize tag 'font-lock-face 'magit2-tag)
                     (propertize (number-to-string cnt)
                                 'font-lock-face 'magit2-branch-local))))))
      (when-let ((precedes (magit2-get-next-tag magit2-buffer-revision t)))
        (let ((tag (car  precedes))
              (cnt (cadr precedes)))
          (magit2-insert-section (tag tag)
            (insert (format "Precedes:   %s (%s)\n"
                            (propertize tag 'font-lock-face 'magit2-tag)
                            (propertize (number-to-string cnt)
                                        'font-lock-face 'magit2-tag))))))
      (insert ?\n))))

(defun magit2--insert-related-refs (rev arg title remote)
  (when-let ((refs (magit2-list-related-branches arg rev (and remote "-a"))))
    (insert title ":" (make-string (- 10 (length title)) ?\s))
    (dolist (branch refs)
      (if (<= (+ (current-column) 1 (length branch))
              (window-width))
          (insert ?\s)
        (insert ?\n (make-string 12 ?\s)))
      (magit2-insert-section (branch branch)
        (insert (propertize branch 'font-lock-face
                            (if (string-prefix-p "remotes/" branch)
                                'magit2-branch-remote
                              'magit2-branch-local)))))
    (insert ?\n)))

(defun magit2-insert-revision-gravatars (rev beg)
  (when (and magit2-revision-show-gravatars
             (window-system))
    (require 'gravatar)
    (pcase-let ((`(,author . ,committer)
                 (pcase magit2-revision-show-gravatars
                   (`t '("^Author:     " . "^Commit:     "))
                   (`author '("^Author:     " . nil))
                   (`committer '(nil . "^Commit:     "))
                   (_ magit2-revision-show-gravatars))))
      (--when-let (and author (magit2-rev-format "%aE" rev))
        (magit2-insert-revision-gravatar beg rev it author))
      (--when-let (and committer (magit2-rev-format "%cE" rev))
        (magit2-insert-revision-gravatar beg rev it committer)))))

(defun magit2-insert-revision-gravatar (beg rev email regexp)
  (save-excursion
    (goto-char beg)
    (when (re-search-forward regexp nil t)
      (when-let ((window (get-buffer-window)))
        (let* ((column   (length (match-string 0)))
               (font-obj (query-font (font-at (point) window)))
               (size     (* 2 (+ (aref font-obj 4)
                                 (aref font-obj 5))))
               (align-to (+ column
                            (ceiling (/ size (aref font-obj 7) 1.0))
                            1))
               (gravatar-size (- size 2)))
          (ignore-errors ; service may be unreachable
            (gravatar-retrieve email 'magit2-insert-revision-gravatar-cb
                               (list gravatar-size rev
                                     (point-marker)
                                     align-to column))))))))

(defun magit2-insert-revision-gravatar-cb (image size rev marker align-to column)
  (unless (eq image 'error)
    (when-let ((buffer (marker-buffer marker)))
      (with-current-buffer buffer
        (save-excursion
          (goto-char marker)
          ;; The buffer might display another revision by now or
          ;; it might have been refreshed, in which case another
          ;; process might already have inserted the image.
          (when (and (equal rev magit2-buffer-revision)
                     (not (eq (car-safe
                               (car-safe
                                (get-text-property (point) 'display)))
                              'image)))
            ;; `image-property' wasn't added until 26.1.
            (setcdr image (plist-put (cdr image) :ascent 'center))
            (setcdr image (plist-put (cdr image) :relief 1))
            (setcdr image (plist-put (cdr image) :scale  1))
            (setcdr image (plist-put (cdr image) :height size))
            (let ((top (list image '(slice 0.0 0.0 1.0 0.5)))
                  (bot (list image '(slice 0.0 0.5 1.0 1.0)))
                  (align `((space :align-to ,align-to))))
              (when magit2-revision-use-gravatar-kludge
                (cl-rotatef top bot))
              (let ((inhibit-read-only t))
                (insert (propertize " " 'display top))
                (insert (propertize " " 'display align))
                (forward-line)
                (forward-char column)
                (insert (propertize " " 'display bot))
                (insert (propertize " " 'display align))))))))))

;;; Merge-Preview Mode

(define-derived-mode magit2-merge-preview-mode magit2-diff-mode "Magit Merge"
  "Mode for previewing a merge."
  :group 'magit2-diff
  (hack-dir-local-variables-non-file-buffer))

(put 'magit2-merge-preview-mode 'magit2-diff-default-arguments
     '("--no-ext-diff"))

(defun magit2-merge-preview-setup-buffer (rev)
  (magit2-setup-buffer #'magit2-merge-preview-mode nil
    (magit2-buffer-revision rev)
    (magit2-buffer-range (format "%s^..%s" rev rev))))

(defun magit2-merge-preview-refresh-buffer ()
  (let* ((branch (magit2-get-current-branch))
         (head (or branch (magit2-rev-parse "HEAD"))))
    (magit2-set-header-line-format (format "Preview merge of %s into %s"
                                          magit2-buffer-revision
                                          (or branch "HEAD")))
    (magit2-insert-section (diffbuf)
      (magit2--insert-diff
        "merge-tree" (magit2-git-string "merge-base" head magit2-buffer-revision)
        head magit2-buffer-revision))))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-merge-preview-mode))
  magit2-buffer-revision)

;;; Diff Sections

(defun magit2-hunk-set-window-start (section)
  "When SECTION is a `hunk', ensure that its beginning is visible.
It the SECTION has a different type, then do nothing."
  (when (magit2-hunk-section-p section)
    (magit2-section-set-window-start section)))

(add-hook 'magit2-section-movement-hook #'magit2-hunk-set-window-start)

(defun magit2-hunk-goto-successor (section arg)
  (and (magit2-hunk-section-p section)
       (when-let ((parent (magit2-get-section
                           (magit2-section-ident
                            (oref section parent)))))
         (let* ((children (oref parent children))
                (siblings (magit2-section-siblings section 'prev))
                (previous (nth (length siblings) children)))
           (if (not arg)
               (--when-let (or previous (car (last children)))
                 (magit2-section-goto it)
                 t)
             (when previous
               (magit2-section-goto previous))
             (if (and (stringp arg)
                      (re-search-forward arg (oref parent end) t))
                 (goto-char (match-beginning 0))
               (goto-char (oref (car (last children)) end))
               (forward-line -1)
               (while (looking-at "^ ")    (forward-line -1))
               (while (looking-at "^[-+]") (forward-line -1))
               (forward-line)))))))

(add-hook 'magit2-section-goto-successor-hook #'magit2-hunk-goto-successor)

(defvar magit2-unstaged-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing]  'magit2-diff-unstaged)
    (define-key map [remap magit2-delete-thing] 'magit2-discard)
    (define-key map "s" 'magit2-stage)
    (define-key map "u" 'magit2-unstage)
    map)
  "Keymap for the `unstaged' section.")

(magit2-define-section-jumper magit2-jump-to-unstaged "Unstaged changes" unstaged)

(defun magit2-insert-unstaged-changes ()
  "Insert section showing unstaged changes."
  (magit2-insert-section (unstaged)
    (magit2-insert-heading "Unstaged changes:")
    (magit2--insert-diff
      "diff" magit2-buffer-diff-args "--no-prefix"
      "--" magit2-buffer-diff-files)))

(defvar magit2-staged-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing]      'magit2-diff-staged)
    (define-key map [remap magit2-delete-thing]     'magit2-discard)
    (define-key map [remap magit2-revert-no-commit] 'magit2-reverse)
    (define-key map "s" 'magit2-stage)
    (define-key map "u" 'magit2-unstage)
    map)
  "Keymap for the `staged' section.")

(magit2-define-section-jumper magit2-jump-to-staged "Staged changes" staged)

(defun magit2-insert-staged-changes ()
  "Insert section showing staged changes."
  ;; Avoid listing all files as deleted when visiting a bare repo.
  (unless (magit2-bare-repo-p)
    (magit2-insert-section (staged)
      (magit2-insert-heading "Staged changes:")
      (magit2--insert-diff
        "diff" "--cached" magit2-buffer-diff-args "--no-prefix"
        "--" magit2-buffer-diff-files))))

;;; Diff Type

(defun magit2-diff-type (&optional section)
  "Return the diff type of SECTION.

The returned type is one of the symbols `staged', `unstaged',
`committed', or `undefined'.  This type serves a similar purpose
as the general type common to all sections (which is stored in
the `type' slot of the corresponding `magit2-section' struct) but
takes additional information into account.  When the SECTION
isn't related to diffs and the buffer containing it also isn't
a diff-only buffer, then return nil.

Currently the type can also be one of `tracked' and `untracked'
but these values are not handled explicitly everywhere they
should be and a possible fix could be to just return nil here.

The section has to be a `diff' or `hunk' section, or a section
whose children are of type `diff'.  If optional SECTION is nil,
return the diff type for the current section.  In buffers whose
major mode is `magit2-diff-mode' SECTION is ignored and the type
is determined using other means.  In `magit2-revision-mode'
buffers the type is always `committed'.

Do not confuse this with `magit2-diff-scope' (which see)."
  (--when-let (or section (magit2-current-section))
    (cond ((derived-mode-p 'magit2-revision-mode 'magit2-stash-mode) 'committed)
          ((derived-mode-p 'magit2-diff-mode)
           (let ((range magit2-buffer-range)
                 (const magit2-buffer-typearg))
             (cond ((equal const "--no-index") 'undefined)
                   ((or (not range)
                        (magit2-rev-eq range "HEAD"))
                    (if (equal const "--cached")
                        'staged
                      'unstaged))
                   ((equal const "--cached")
                    (if (magit2-rev-head-p range)
                        'staged
                      'undefined)) ; i.e. committed and staged
                   (t 'committed))))
          ((derived-mode-p 'magit2-status-mode)
           (let ((stype (oref it type)))
             (if (memq stype '(staged unstaged tracked untracked))
                 stype
               (pcase stype
                 ((or `file `module)
                  (let* ((parent (oref it parent))
                         (type   (oref parent type)))
                    (if (memq type '(file module))
                        (magit2-diff-type parent)
                      type)))
                 (`hunk (thread-first it
                          (oref parent)
                          (oref parent)
                          (oref type)))))))
          ((derived-mode-p 'magit2-log-mode)
           (if (or (and (magit2-section-match 'commit section)
                        (oref section children))
                   (magit2-section-match [* file commit] section))
               'committed
             'undefined))
          (t 'undefined))))

(cl-defun magit2-diff-scope (&optional (section nil ssection) strict)
  "Return the diff scope of SECTION or the selected section(s).

A diff's \"scope\" describes what part of a diff is selected, it is
a symbol, one of `region', `hunk', `hunks', `file', `files', or
`list'.  Do not confuse this with the diff \"type\", as returned by
`magit2-diff-type'.

If optional SECTION is non-nil, then return the scope of that,
ignoring the sections selected by the region.  Otherwise return
the scope of the current section, or if the region is active and
selects a valid group of diff related sections, the type of these
sections, i.e. `hunks' or `files'.  If SECTION, or if that is nil
the current section, is a `hunk' section; and the region region
starts and ends inside the body of a that section, then the type
is `region'.  If the region is empty after a mouse click, then
`hunk' is returned instead of `region'.

If optional STRICT is non-nil, then return nil if the diff type of
the section at point is `untracked' or the section at point is not
actually a `diff' but a `diffstat' section."
  (let ((siblings (and (not ssection) (magit2-region-sections nil t))))
    (setq section (or section (car siblings) (magit2-current-section)))
    (when (and section
               (or (not strict)
                   (and (not (eq (magit2-diff-type section) 'untracked))
                        (not (eq (--when-let (oref section parent)
                                   (oref it type))
                                 'diffstat)))))
      (pcase (list (oref section type)
                   (and siblings t)
                   (magit2-diff-use-hunk-region-p)
                   ssection)
        (`(hunk nil   t  ,_)
         (if (magit2-section-internal-region-p section) 'region 'hunk))
        (`(hunk   t   t nil) 'hunks)
        (`(hunk  ,_  ,_  ,_) 'hunk)
        (`(file   t   t nil) 'files)
        (`(file  ,_  ,_  ,_) 'file)
        (`(module   t   t nil) 'files)
        (`(module  ,_  ,_  ,_) 'file)
        (`(,(or `staged `unstaged `untracked) nil ,_ ,_) 'list)))))

(defun magit2-diff-use-hunk-region-p ()
  (and (region-active-p)
       ;; TODO implement this from first principals
       ;; currently it's trial-and-error
       (not (and (or (eq this-command 'mouse-drag-region)
                     (eq last-command 'mouse-drag-region)
                     ;; When another window was previously
                     ;; selected then the last-command is
                     ;; some byte-code function.
                     (byte-code-function-p last-command))
                 (eq (region-end) (region-beginning))))))

;;; Diff Highlight

(add-hook 'magit2-section-unhighlight-hook #'magit2-diff-unhighlight)
(add-hook 'magit2-section-highlight-hook #'magit2-diff-highlight)

(defun magit2-diff-unhighlight (section selection)
  "Remove the highlighting of the diff-related SECTION."
  (when (magit2-hunk-section-p section)
    (magit2-diff-paint-hunk section selection nil)
    t))

(defun magit2-diff-highlight (section selection)
  "Highlight the diff-related SECTION.
If SECTION is not a diff-related section, then do nothing and
return nil.  If SELECTION is non-nil, then it is a list of sections
selected by the region, including SECTION.  All of these sections
are highlighted."
  (if (and (magit2-section-match 'commit section)
           (oref section children))
      (progn (if selection
                 (dolist (section selection)
                   (magit2-diff-highlight-list section selection))
               (magit2-diff-highlight-list section))
             t)
    (when-let ((scope (magit2-diff-scope section t)))
      (cond ((eq scope 'region)
             (magit2-diff-paint-hunk section selection t))
            (selection
             (dolist (section selection)
               (magit2-diff-highlight-recursive section selection)))
            (t
             (magit2-diff-highlight-recursive section)))
      t)))

(defun magit2-diff-highlight-recursive (section &optional selection)
  (pcase (magit2-diff-scope section)
    (`list (magit2-diff-highlight-list section selection))
    (`file (magit2-diff-highlight-file section selection))
    (`hunk (magit2-diff-highlight-heading section selection)
           (magit2-diff-paint-hunk section selection t))
    (_     (magit2-section-highlight section nil))))

(defun magit2-diff-highlight-list (section &optional selection)
  (let ((beg (oref section start))
        (cnt (oref section content))
        (end (oref section end)))
    (when (or (eq this-command 'mouse-drag-region)
              (not selection))
      (unless (and (region-active-p)
                   (<= (region-beginning) beg))
        (magit2-section-make-overlay beg cnt 'magit2-section-highlight))
      (if (oref section hidden)
          (oset section washer #'ignore)
        (dolist (child (oref section children))
          (when (or (eq this-command 'mouse-drag-region)
                    (not (and (region-active-p)
                              (<= (region-beginning)
                                  (oref child start)))))
            (magit2-diff-highlight-recursive child selection)))))
    (when magit2-diff-highlight-hunk-body
      (magit2-section-make-overlay (1- end) end 'magit2-section-highlight))))

(defun magit2-diff-highlight-file (section &optional selection)
  (magit2-diff-highlight-heading section selection)
  (when (or (not (oref section hidden))
            (cl-typep section 'magit2-module-section))
    (dolist (child (oref section children))
      (magit2-diff-highlight-recursive child selection))))

(defun magit2-diff-highlight-heading (section &optional selection)
  (magit2-section-make-overlay
   (oref section start)
   (or (oref section content)
       (oref section end))
   (pcase (list (oref section type)
                (and (member section selection)
                     (not (eq this-command 'mouse-drag-region))))
     (`(file   t) 'magit2-diff-file-heading-selection)
     (`(file nil) 'magit2-diff-file-heading-highlight)
     (`(module   t) 'magit2-diff-file-heading-selection)
     (`(module nil) 'magit2-diff-file-heading-highlight)
     (`(hunk   t) 'magit2-diff-hunk-heading-selection)
     (`(hunk nil) 'magit2-diff-hunk-heading-highlight))))

;;; Hunk Paint

(cl-defun magit2-diff-paint-hunk
    (section &optional selection
             (highlight (magit2-section-selected-p section selection)))
  (let (paint)
    (unless magit2-diff-highlight-hunk-body
      (setq highlight nil))
    (cond (highlight
           (unless (oref section hidden)
             (add-to-list 'magit2-section-highlighted-sections section)
             (cond ((memq section magit2-section-unhighlight-sections)
                    (setq magit2-section-unhighlight-sections
                          (delq section magit2-section-unhighlight-sections)))
                   (magit2-diff-highlight-hunk-body
                    (setq paint t)))))
          (t
           (cond ((and (oref section hidden)
                       (memq section magit2-section-unhighlight-sections))
                  (add-to-list 'magit2-section-highlighted-sections section)
                  (setq magit2-section-unhighlight-sections
                        (delq section magit2-section-unhighlight-sections)))
                 (t
                  (setq paint t)))))
    (when paint
      (save-excursion
        (goto-char (oref section start))
        (let ((end (oref section end))
              (merging (looking-at "@@@"))
              (diff-type (magit2-diff-type))
              (stage nil)
              (tab-width (magit2-diff-tab-width
                          (magit2-section-parent-value section))))
          (forward-line)
          (while (< (point) end)
            (when (and magit2-diff-hide-trailing-cr-characters
                       (char-equal ?\r (char-before (line-end-position))))
              (put-text-property (1- (line-end-position)) (line-end-position)
                                 'invisible t))
            (put-text-property
             (point) (1+ (line-end-position)) 'font-lock-face
             (cond
              ((looking-at "^\\+\\+?\\([<=|>]\\)\\{7\\}")
               (setq stage (pcase (list (match-string 1) highlight)
                             (`("<" nil) 'magit2-diff-our)
                             (`("<"   t) 'magit2-diff-our-highlight)
                             (`("|" nil) 'magit2-diff-base)
                             (`("|"   t) 'magit2-diff-base-highlight)
                             (`("=" nil) 'magit2-diff-their)
                             (`("="   t) 'magit2-diff-their-highlight)
                             (`(">" nil) nil)))
               'magit2-diff-conflict-heading)
              ((looking-at (if merging "^\\(\\+\\| \\+\\)" "^\\+"))
               (magit2-diff-paint-tab merging tab-width)
               (magit2-diff-paint-whitespace merging 'added diff-type)
               (or stage
                   (if highlight 'magit2-diff-added-highlight 'magit2-diff-added)))
              ((looking-at (if merging "^\\(-\\| -\\)" "^-"))
               (magit2-diff-paint-tab merging tab-width)
               (magit2-diff-paint-whitespace merging 'removed diff-type)
               (if highlight 'magit2-diff-removed-highlight 'magit2-diff-removed))
              (t
               (magit2-diff-paint-tab merging tab-width)
               (magit2-diff-paint-whitespace merging 'context diff-type)
               (if highlight 'magit2-diff-context-highlight 'magit2-diff-context))))
            (forward-line))))))
  (magit2-diff-update-hunk-refinement section))

(defvar magit2-diff--tab-width-cache nil)

(defun magit2-diff-tab-width (file)
  (setq file (expand-file-name file))
  (cl-flet ((cache (value)
                   (let ((elt (assoc file magit2-diff--tab-width-cache)))
                     (if elt
                         (setcdr elt value)
                       (setq magit2-diff--tab-width-cache
                             (cons (cons file value)
                                   magit2-diff--tab-width-cache))))
                   value))
    (cond
     ((not magit2-diff-adjust-tab-width)
      tab-width)
     ((--when-let (find-buffer-visiting file)
        (cache (buffer-local-value 'tab-width it))))
     ((--when-let (assoc file magit2-diff--tab-width-cache)
        (or (cdr it)
            tab-width)))
     ((or (eq magit2-diff-adjust-tab-width 'always)
          (and (numberp magit2-diff-adjust-tab-width)
               (>= magit2-diff-adjust-tab-width
                   (nth 7 (file-attributes file)))))
      (cache (buffer-local-value 'tab-width (find-file-noselect file))))
     (t
      (cache nil)
      tab-width))))

(defun magit2-diff-paint-tab (merging width)
  (save-excursion
    (forward-char (if merging 2 1))
    (while (= (char-after) ?\t)
      (put-text-property (point) (1+ (point))
                         'display (list (list 'space :width width)))
      (forward-char))))

(defun magit2-diff-paint-whitespace (merging line-type diff-type)
  (when (and magit2-diff-paint-whitespace
             (or (not (memq magit2-diff-paint-whitespace '(uncommitted status)))
                 (memq diff-type '(staged unstaged)))
             (cl-case line-type
               (added   t)
               (removed (memq magit2-diff-paint-whitespace-lines '(all both)))
               (context (memq magit2-diff-paint-whitespace-lines '(all)))))
    (let ((prefix (if merging "^[-\\+\s]\\{2\\}" "^[-\\+\s]"))
          (indent
           (if (local-variable-p 'magit2-diff-highlight-indentation)
               magit2-diff-highlight-indentation
             (setq-local
              magit2-diff-highlight-indentation
              (cdr (--first (string-match-p (car it) default-directory)
                            (nreverse
                             (default-value
                               'magit2-diff-highlight-indentation))))))))
      (when (and magit2-diff-highlight-trailing
                 (looking-at (concat prefix ".*?\\([ \t]+\\)$")))
        (let ((ov (make-overlay (match-beginning 1) (match-end 1) nil t)))
          (overlay-put ov 'font-lock-face 'magit2-diff-whitespace-warning)
          (overlay-put ov 'priority 2)
          (overlay-put ov 'evaporate t)))
      (when (or (and (eq indent 'tabs)
                     (looking-at (concat prefix "\\( *\t[ \t]*\\)")))
                (and (integerp indent)
                     (looking-at (format "%s\\([ \t]* \\{%s,\\}[ \t]*\\)"
                                         prefix indent))))
        (let ((ov (make-overlay (match-beginning 1) (match-end 1) nil t)))
          (overlay-put ov 'font-lock-face 'magit2-diff-whitespace-warning)
          (overlay-put ov 'priority 2)
          (overlay-put ov 'evaporate t))))))

(defun magit2-diff-update-hunk-refinement (&optional section)
  (if section
      (unless (oref section hidden)
        (pcase (list magit2-diff-refine-hunk
                     (oref section refined)
                     (eq section (magit2-current-section)))
          ((or `(all nil ,_) `(t nil t))
           (oset section refined t)
           (save-excursion
             (goto-char (oref section start))
             ;; `diff-refine-hunk' does not handle combined diffs.
             (unless (looking-at "@@@")
               (let ((smerge-refine-ignore-whitespace
                      magit2-diff-refine-ignore-whitespace)
                     ;; Avoid fsyncing many small temp files
                     (write-region-inhibit-fsync t))
                 (diff-refine-hunk)))))
          ((or `(nil t ,_) `(t t nil))
           (oset section refined nil)
           (remove-overlays (oref section start)
                            (oref section end)
                            'diff-mode 'fine))))
    (cl-labels ((recurse (section)
                         (if (magit2-section-match 'hunk section)
                             (magit2-diff-update-hunk-refinement section)
                           (dolist (child (oref section children))
                             (recurse child)))))
      (recurse magit2-root-section))))


;;; Hunk Region

(defun magit2-diff-hunk-region-beginning ()
  (save-excursion (goto-char (region-beginning))
                  (line-beginning-position)))

(defun magit2-diff-hunk-region-end ()
  (save-excursion (goto-char (region-end))
                  (line-end-position)))

(defun magit2-diff-update-hunk-region (section)
  "Highlight the hunk-internal region if any."
  (when (and (eq (oref section type) 'hunk)
             (eq (magit2-diff-scope section t) 'region))
    (magit2-diff--make-hunk-overlay
     (oref section start)
     (1- (oref section content))
     'font-lock-face 'magit2-diff-lines-heading
     'display (magit2-diff-hunk-region-header section)
     'after-string (magit2-diff--hunk-after-string 'magit2-diff-lines-heading))
    (run-hook-with-args 'magit2-diff-highlight-hunk-region-functions section)
    t))

(defun magit2-diff-highlight-hunk-region-dim-outside (section)
  "Dim the parts of the hunk that are outside the hunk-internal region.
This is done by using the same foreground and background color
for added and removed lines as for context lines."
  (let ((face (if magit2-diff-highlight-hunk-body
                  'magit2-diff-context-highlight
                'magit2-diff-context)))
    (when magit2-diff-unmarked-lines-keep-foreground
      (setq face `(,@(and (>= emacs-major-version 27) '(:extend t))
                   :background ,(face-attribute face :background))))
    (magit2-diff--make-hunk-overlay (oref section content)
                                   (magit2-diff-hunk-region-beginning)
                                   'font-lock-face face
                                   'priority 2)
    (magit2-diff--make-hunk-overlay (1+ (magit2-diff-hunk-region-end))
                                   (oref section end)
                                   'font-lock-face face
                                   'priority 2)))

(defun magit2-diff-highlight-hunk-region-using-face (_section)
  "Highlight the hunk-internal region by making it bold.
Or rather highlight using the face `magit2-diff-hunk-region', though
changing only the `:weight' and/or `:slant' is recommended for that
face."
  (magit2-diff--make-hunk-overlay (magit2-diff-hunk-region-beginning)
                                 (1+ (magit2-diff-hunk-region-end))
                                 'font-lock-face 'magit2-diff-hunk-region))

(defun magit2-diff-highlight-hunk-region-using-overlays (section)
  "Emphasize the hunk-internal region using delimiting horizontal lines.
This is implemented as single-pixel newlines places inside overlays."
  (if (window-system)
      (let ((beg (magit2-diff-hunk-region-beginning))
            (end (magit2-diff-hunk-region-end))
            (str (propertize
                  (concat (propertize "\s" 'display '(space :height (1)))
                          (propertize "\n" 'line-height t))
                  'font-lock-face 'magit2-diff-lines-boundary)))
        (magit2-diff--make-hunk-overlay beg (1+ beg) 'before-string str)
        (magit2-diff--make-hunk-overlay end (1+ end) 'after-string  str))
    (magit2-diff-highlight-hunk-region-using-face section)))

(defun magit2-diff-highlight-hunk-region-using-underline (section)
  "Emphasize the hunk-internal region using delimiting horizontal lines.
This is implemented by overlining and underlining the first and
last (visual) lines of the region."
  (if (window-system)
      (let* ((beg (magit2-diff-hunk-region-beginning))
             (end (magit2-diff-hunk-region-end))
             (beg-eol (save-excursion (goto-char beg)
                                      (end-of-visual-line)
                                      (point)))
             (end-bol (save-excursion (goto-char end)
                                      (beginning-of-visual-line)
                                      (point)))
             (color (face-background 'magit2-diff-lines-boundary nil t)))
        (cl-flet ((ln (b e &rest face)
                      (magit2-diff--make-hunk-overlay
                       b e 'font-lock-face face 'after-string
                       (magit2-diff--hunk-after-string face))))
          (if (= beg end-bol)
              (ln beg beg-eol :overline color :underline color)
            (ln beg beg-eol :overline color)
            (ln end-bol end :underline color))))
    (magit2-diff-highlight-hunk-region-using-face section)))

(defun magit2-diff--make-hunk-overlay (start end &rest args)
  (let ((ov (make-overlay start end nil t)))
    (overlay-put ov 'evaporate t)
    (while args (overlay-put ov (pop args) (pop args)))
    (push ov magit2-section--region-overlays)
    ov))

(defun magit2-diff--hunk-after-string (face)
  (propertize "\s"
              'font-lock-face face
              'display (list 'space :align-to
                             `(+ (0 . right)
                                 ,(min (window-hscroll)
                                       (- (line-end-position)
                                          (line-beginning-position)))))
              ;; This prevents the cursor from being rendered at the
              ;; edge of the window.
              'cursor t))

;;; Hunk Utilities

(defun magit2-diff-inside-hunk-body-p ()
  "Return non-nil if point is inside the body of a hunk."
  (and (magit2-section-match 'hunk)
       (when-let ((content (oref (magit2-current-section) content)))
         (> (point) content))))

;;; Diff Extract

(defun magit2-diff-file-header (section &optional no-rename)
  (when (magit2-hunk-section-p section)
    (setq section (oref section parent)))
  (and (magit2-file-section-p section)
       (let ((header (oref section header)))
         (if no-rename
             (replace-regexp-in-string
              "^--- \\(.+\\)" (oref section value) header t t 1)
           header))))

(defun magit2-diff-hunk-region-header (section)
  (let ((patch (magit2-diff-hunk-region-patch section)))
    (string-match "\n" patch)
    (substring patch 0 (1- (match-end 0)))))

(defun magit2-diff-hunk-region-patch (section &optional args)
  (let ((op (if (member "--reverse" args) "+" "-"))
        (sbeg (oref section start))
        (rbeg (magit2-diff-hunk-region-beginning))
        (rend (region-end))
        (send (oref section end))
        (patch nil))
    (save-excursion
      (goto-char sbeg)
      (while (< (point) send)
        (looking-at "\\(.\\)\\([^\n]*\n\\)")
        (cond ((or (string-match-p "[@ ]" (match-string-no-properties 1))
                   (and (>= (point) rbeg)
                        (<= (point) rend)))
               (push (match-string-no-properties 0) patch))
              ((equal op (match-string-no-properties 1))
               (push (concat " " (match-string-no-properties 2)) patch)))
        (forward-line)))
    (let ((buffer-list-update-hook nil)) ; #3759
      (with-temp-buffer
        (insert (mapconcat #'identity (reverse patch) ""))
        (diff-fixup-modifs (point-min) (point-max))
        (setq patch (buffer-string))))
    patch))

;;; _
(provide 'magit2-diff)
;;; magit2-diff.el ends here
