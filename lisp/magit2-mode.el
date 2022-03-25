;;; magit2-mode.el --- create and refresh Magit buffers  -*- lexical-binding: t -*-

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

;; This library implements the abstract major-mode `magit2-mode' from
;; which almost all other Magit major-modes derive.  The code in here
;; is mostly concerned with creating and refreshing Magit buffers.

;;; Code:

(require 'magit2-base)
(require 'magit2-git)

(require 'format-spec)
(require 'help-mode)
(require 'transient)

;; For `magit2-display-buffer-fullcolumn-most-v1' from `git-commit'
(defvar git-commit-mode)
;; For `magit2-refresh'
(defvar magit2-post-commit-hook-commands)
(defvar magit2-post-stage-hook-commands)
(defvar magit2-post-unstage-hook-commands)
;; For `magit2-refresh' and `magit2-refresh-all'
(declare-function magit2-auto-revert-buffers "magit2-autorevert" ())
;; For `magit2-refresh-buffer'
(declare-function magit2-process-unset-mode-line-error-status "magit2-process" ())
;; For `magit2-refresh-get-relative-position'
(declare-function magit2-hunk-section-p "magit2-diff" (section) t)
;; For `magit2-mode-setup-internal'
(declare-function magit2-status-goto-initial-section "magit2-status" ())
;; For `magit2-mode' from `bookmark'
(defvar bookmark-make-record-function)

;;; Options

(defcustom magit2-mode-hook
  '(magit2-load-config-extensions)
  "Hook run when entering a mode derived from Magit mode."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-modes
  :type 'hook
  :options '(magit2-load-config-extensions
             bug-reference-mode))

(defcustom magit2-setup-buffer-hook
  '(magit2-maybe-save-repository-buffers
    magit2-set-buffer-margin)
  "Hook run by `magit2-setup-buffer'.

This is run right after displaying the buffer and right before
generating or updating its content.  `magit2-mode-hook' and other,
more specific, `magit2-mode-*-hook's on the other hand are run
right before displaying the buffer.  Usually one of these hooks
should be used instead of this one."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-modes
  :type 'hook
  :options '(magit2-maybe-save-repository-buffers
             magit2-set-buffer-margin))

(defcustom magit2-pre-refresh-hook '(magit2-maybe-save-repository-buffers)
  "Hook run before refreshing in `magit2-refresh'.

This hook, or `magit2-post-refresh-hook', should be used
for functions that are not tied to a particular buffer.

To run a function with a particular buffer current, use
`magit2-refresh-buffer-hook' and use `derived-mode-p'
inside your function."
  :package-version '(magit2 . "2.4.0")
  :group 'magit2-refresh
  :type 'hook
  :options '(magit2-maybe-save-repository-buffers))

(defcustom magit2-post-refresh-hook nil
  "Hook run after refreshing in `magit2-refresh'.

This hook, or `magit2-pre-refresh-hook', should be used
for functions that are not tied to a particular buffer.

To run a function with a particular buffer current, use
`magit2-refresh-buffer-hook' and use `derived-mode-p'
inside your function."
  :package-version '(magit2 . "2.4.0")
  :group 'magit2-refresh
  :type 'hook)

(defcustom magit2-display-buffer-function 'magit2-display-buffer-traditional
  "The function used to display a Magit buffer.

All Magit buffers (buffers whose major-modes derive from
`magit2-mode') are displayed using `magit2-display-buffer',
which in turn uses the function specified here."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-buffers
  :type '(radio (function-item magit2-display-buffer-traditional)
                (function-item magit2-display-buffer-same-window-except-diff-v1)
                (function-item magit2-display-buffer-fullframe-status-v1)
                (function-item magit2-display-buffer-fullframe-status-topleft-v1)
                (function-item magit2-display-buffer-fullcolumn-most-v1)
                (function-item display-buffer)
                (function :tag "Function")))

(defcustom magit2-pre-display-buffer-hook '(magit2-save-window-configuration)
  "Hook run by `magit2-display-buffer' before displaying the buffer."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-buffers
  :type 'hook
  :get 'magit2-hook-custom-get
  :options '(magit2-save-window-configuration))

(defcustom magit2-post-display-buffer-hook '(magit2-maybe-set-dedicated)
  "Hook run by `magit2-display-buffer' after displaying the buffer."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-buffers
  :type 'hook
  :get 'magit2-hook-custom-get
  :options '(magit2-maybe-set-dedicated))

(defcustom magit2-generate-buffer-name-function
  'magit2-generate-buffer-name-default-function
  "The function used to generate the name for a Magit buffer."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-buffers
  :type '(radio (function-item magit2-generate-buffer-name-default-function)
                (function :tag "Function")))

(defcustom magit2-buffer-name-format "%x%M%v: %t%x"
  "The format string used to name Magit buffers.

The following %-sequences are supported:

`%m' The name of the major-mode, but with the `-mode' suffix
     removed.

`%M' Like \"%m\" but abbreviate `magit2-status-mode' as `magit2'.

`%v' The value the buffer is locked to, in parentheses, or an
     empty string if the buffer is not locked to a value.

`%V' Like \"%v\", but the string is prefixed with a space, unless
     it is an empty string.

`%t' The top-level directory of the working tree of the
     repository, or if `magit2-uniquify-buffer-names' is non-nil
     an abbreviation of that.

`%x' If `magit2-uniquify-buffer-names' is nil \"*\", otherwise the
     empty string.  Due to limitations of the `uniquify' package,
     buffer names must end with the path.

`%T' Obsolete, use \"%t%x\" instead.  Like \"%t\", but append an
     asterisk if and only if `magit2-uniquify-buffer-names' is nil.

The value should always contain \"%m\" or \"%M\", \"%v\" or
\"%V\", and \"%t\" (or the obsolete \"%T\").

If `magit2-uniquify-buffer-names' is non-nil, then the value must
end with \"%t\" or \"%t%x\" (or the obsolete \"%T\").  See issue
#2841.

This is used by `magit2-generate-buffer-name-default-function'.
If another `magit2-generate-buffer-name-function' is used, then
it may not respect this option, or on the contrary it may
support additional %-sequences."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-buffers
  :type 'string)

(defcustom magit2-uniquify-buffer-names t
  "Whether to uniquify the names of Magit buffers."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-buffers
  :type 'boolean)

(defcustom magit2-bury-buffer-function 'magit2-mode-quit-window
  "The function used to bury or kill the current Magit buffer."
  :package-version '(magit2 . "3.2.0")
  :group 'magit2-buffers
  :type '(radio (function-item quit-window)
                (function-item magit2-mode-quit-window)
                (function-item magit2-restore-window-configuration)
                (function :tag "Function")))

(defcustom magit2-prefix-use-buffer-arguments 'selected
  "Whether certain prefix commands reuse arguments active in relevant buffer.

This affects the transient prefix commands `magit2-diff',
`magit2-log' and `magit2-show-refs'.

Valid values are:

`always': Always use the set of arguments that is currently
  active in the respective buffer, provided that buffer exists
  of course.
`selected': Use the set of arguments from the respective
  buffer, but only if it is displayed in a window of the current
  frame.  This is the default.
`current': Use the set of arguments from the respective buffer,
  but only if it is the current buffer.
`never': Never use the set of arguments from the respective
  buffer.

For more information see info node `(magit2)Transient Arguments
and Buffer Variables'."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-buffers
  :group 'magit2-commands
  :group 'magit2-diff
  :group 'magit2-log
  :type '(choice
          (const :tag "always use args from buffer" always)
          (const :tag "use args from buffer if displayed in frame" selected)
          (const :tag "use args from buffer if it is current" current)
          (const :tag "never use args from buffer" never)))

(defcustom magit2-direct-use-buffer-arguments 'selected
  "Whether certain commands reuse arguments active in relevant buffer.

This affects certain commands such as `magit2-show-commit' that
are suffixes of the diff or log transient prefix commands, but
only if they are invoked directly, i.e. *not* as a suffix.

Valid values are:

`always': Always use the set of arguments that is currently
  active in the respective buffer, provided that buffer exists
  of course.
`selected': Use the set of arguments from the respective
  buffer, but only if it is displayed in a window of the current
  frame.  This is the default.
`current': Use the set of arguments from the respective buffer,
  but only if it is the current buffer.
`never': Never use the set of arguments from the respective
  buffer.

For more information see info node `(magit2)Transient Arguments
and Buffer Variables'."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-buffers
  :group 'magit2-commands
  :group 'magit2-diff
  :group 'magit2-log
  :type '(choice
          (const :tag "always use args from buffer" always)
          (const :tag "use args from buffer if displayed in frame" selected)
          (const :tag "use args from buffer if it is current" current)
          (const :tag "never use args from buffer" never)))

(defcustom magit2-region-highlight-hook '(magit2-diff-update-hunk-region)
  "Functions used to highlight the region.

Each function is run with the current section as only argument
until one of them returns non-nil.  If all functions return nil,
then fall back to regular region highlighting."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-refresh
  :type 'hook
  :options '(magit2-diff-update-hunk-region))

(defcustom magit2-create-buffer-hook nil
  "Normal hook run after creating a new `magit2-mode' buffer."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-refresh
  :type 'hook)

(defcustom magit2-refresh-buffer-hook nil
  "Normal hook for `magit2-refresh-buffer' to run after refreshing."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-refresh
  :type 'hook)

(defcustom magit2-refresh-status-buffer t
  "Whether the status buffer is refreshed after running git.

When this is non-nil, then the status buffer is automatically
refreshed after running git for side-effects, in addition to the
current Magit buffer, which is always refreshed automatically.

Only set this to nil after exhausting all other options to
improve performance."
  :package-version '(magit2 . "2.4.0")
  :group 'magit2-refresh
  :group 'magit2-status
  :type 'boolean)

(defcustom magit2-refresh-verbose nil
  "Whether to revert Magit buffers verbosely."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-refresh
  :type 'boolean)

(defcustom magit2-save-repository-buffers t
  "Whether to save file-visiting buffers when appropriate.

If non-nil, then all modified file-visiting buffers belonging
to the current repository may be saved before running Magit
commands and before creating or refreshing Magit buffers.
If `dontask', then this is done without user intervention, for
any other non-nil value the user has to confirm each save.

The default is t to avoid surprises, but `dontask' is the
recommended value."
  :group 'magit2-essentials
  :group 'magit2-buffers
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Ask" t)
                 (const :tag "Save without asking" dontask)))

;;; Key Bindings

(defvar magit2-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-section-mode-map)
    (define-key map [C-return]    'magit2-visit-thing)
    (define-key map (kbd   "RET") 'magit2-visit-thing)
    (define-key map (kbd "M-TAB") 'magit2-dired-jump)
    (define-key map [M-tab]       'magit2-section-cycle-diffs)
    (define-key map (kbd   "SPC") 'magit2-diff-show-or-scroll-up)
    (define-key map (kbd "S-SPC") 'magit2-diff-show-or-scroll-down)
    (define-key map (kbd   "DEL") 'magit2-diff-show-or-scroll-down)
    (define-key map "+"           'magit2-diff-more-context)
    (define-key map "-"           'magit2-diff-less-context)
    (define-key map "0"           'magit2-diff-default-context)
    (define-key map "a" 'magit2-cherry-apply)
    (define-key map "A" 'magit2-cherry-pick)
    (define-key map "b" 'magit2-branch)
    (define-key map "B" 'magit2-bisect)
    (define-key map "c" 'magit2-commit)
    (define-key map "C" 'magit2-clone)
    (define-key map "d" 'magit2-diff)
    (define-key map "D" 'magit2-diff-refresh)
    (define-key map "e" 'magit2-ediff-dwim)
    (define-key map "E" 'magit2-ediff)
    (define-key map "f" 'magit2-fetch)
    (define-key map "F" 'magit2-pull)
    (define-key map "g" 'magit2-refresh)
    (define-key map "G" 'magit2-refresh-all)
    (define-key map "h" 'magit2-dispatch)
    (define-key map "?" 'magit2-dispatch)
    (define-key map "H" 'magit2-describe-section)
    (define-key map "i" 'magit2-gitignore)
    (define-key map "I" 'magit2-init)
    (define-key map "j" 'magit2-status-quick)
    (define-key map "J" 'magit2-display-repository-buffer)
    (define-key map "k" 'magit2-delete-thing)
    (define-key map "K" 'magit2-file-untrack)
    (define-key map "l" 'magit2-log)
    (define-key map "L" 'magit2-log-refresh)
    (define-key map "m" 'magit2-merge)
    (define-key map "M" 'magit2-remote)
    ;;  section-map "n"  magit2-section-forward
    ;;     reserved "N"  forge-dispatch
    (define-key map "o" 'magit2-submodule)
    (define-key map "O" 'magit2-subtree)
    ;;  section-map "p"  magit2-section-backward
    (define-key map "P" 'magit2-push)
    (define-key map "q" 'magit2-mode-bury-buffer)
    (define-key map "Q" 'magit2-git-command)
    (define-key map ":" 'magit2-git-command)
    (define-key map "r" 'magit2-rebase)
    (define-key map "R" 'magit2-file-rename)
    (define-key map "s" 'magit2-stage-file)
    (define-key map "S" 'magit2-stage-modified)
    (define-key map "t" 'magit2-tag)
    (define-key map "T" 'magit2-notes)
    (define-key map "u" 'magit2-unstage-file)
    (define-key map "U" 'magit2-unstage-all)
    (define-key map "v" 'magit2-revert-no-commit)
    (define-key map "V" 'magit2-revert)
    (define-key map "w" 'magit2-am)
    (define-key map "W" 'magit2-patch)
    (define-key map "x" 'magit2-reset-quickly)
    (define-key map "X" 'magit2-reset)
    (define-key map "y" 'magit2-show-refs)
    (define-key map "Y" 'magit2-cherry)
    (define-key map "z" 'magit2-stash)
    (define-key map "Z" 'magit2-worktree)
    (define-key map "%" 'magit2-worktree)
    (define-key map "$" 'magit2-process-buffer)
    (define-key map "!" 'magit2-run)
    (define-key map ">" 'magit2-sparse-checkout)
    (define-key map (kbd "C-c C-c") 'magit2-dispatch)
    (define-key map (kbd "C-c C-e") 'magit2-edit-thing)
    (define-key map (kbd "C-c C-o") 'magit2-browse-thing)
    (define-key map (kbd "C-c C-w") 'magit2-browse-thing)
    (define-key map (kbd "C-w")     'magit2-copy-section-value)
    (define-key map (kbd "M-w")     'magit2-copy-buffer-revision)
    (define-key map [remap previous-line]      'magit2-previous-line)
    (define-key map [remap next-line]          'magit2-next-line)
    (define-key map [remap evil-previous-line] 'evil-previous-visual-line)
    (define-key map [remap evil-next-line]     'evil-next-visual-line)
    map)
  "Parent keymap for all keymaps of modes derived from `magit2-mode'.")

(defun magit2-delete-thing ()
  "This is a placeholder command.
Where applicable, section-specific keymaps bind another command
which deletes the thing at point."
  (interactive)
  (user-error "There is no thing at point that could be deleted"))

(defun magit2-visit-thing ()
  "This is a placeholder command.
Where applicable, section-specific keymaps bind another command
which visits the thing at point."
  (interactive)
  (if (eq transient-current-command 'magit2-dispatch)
      (call-interactively (key-binding (this-command-keys)))
    (user-error "There is no thing at point that could be visited")))

(defun magit2-edit-thing ()
  "This is a placeholder command.
Where applicable, section-specific keymaps bind another command
which lets you edit the thing at point, likely in another buffer."
  (interactive)
  (if (eq transient-current-command 'magit2-dispatch)
      (call-interactively (key-binding (this-command-keys)))
    (user-error "There is no thing at point that could be edited")))

(defun magit2-browse-thing ()
  "This is a placeholder command.
Where applicable, section-specific keymaps bind another command
which visits the thing at point using `browse-url'."
  (interactive)
  (user-error "There is no thing at point that could be browsed"))

(defun magit2-help ()
  "Visit the Magit manual."
  (interactive)
  (info "magit2"))

(defvar bug-reference-map)
(with-eval-after-load 'bug-reference
  (define-key bug-reference-map [remap magit2-visit-thing]
    'bug-reference-push-button))

(easy-menu-define magit2-mode-menu magit2-mode-map
  "Magit menu"
  '("Magit"
    ["Refresh" magit2-refresh t]
    ["Refresh all" magit2-refresh-all t]
    "---"
    ["Stage" magit2-stage t]
    ["Stage modified" magit2-stage-modified t]
    ["Unstage" magit2-unstage t]
    ["Reset index" magit2-reset-index t]
    ["Commit" magit2-commit t]
    ["Add log entry" magit2-commit-add-log t]
    ["Tag" magit2-tag-create t]
    "---"
    ["Diff working tree" magit2-diff-working-tree t]
    ["Diff" magit2-diff t]
    ("Log"
     ["Log" magit2-log-other t]
     ["Reflog" magit2-reflog-other t]
     ["Extended..." magit2-log t])
    "---"
    ["Cherry pick" magit2-cherry-pick t]
    ["Revert commit" magit2-revert t]
    "---"
    ["Ignore at toplevel" magit2-gitignore-in-topdir t]
    ["Ignore in subdirectory" magit2-gitignore-in-subdir t]
    ["Discard" magit2-discard t]
    ["Reset head and index" magit2-reset-mixed t]
    ["Stash" magit2-stash-both t]
    ["Snapshot" magit2-snapshot-both t]
    "---"
    ["Branch..." magit2-checkout t]
    ["Merge" magit2-merge t]
    ["Ediff resolve" magit2-ediff-resolve t]
    ["Rebase..." magit2-rebase t]
    "---"
    ["Push" magit2-push t]
    ["Pull" magit2-pull-branch t]
    ["Remote update" magit2-fetch-all t]
    ("Submodule"
     ["Submodule update" magit2-submodule-update t]
     ["Submodule update and init" magit2-submodule-setup t]
     ["Submodule init" magit2-submodule-init t]
     ["Submodule sync" magit2-submodule-sync t])
    "---"
    ("Extensions")
    "---"
    ["Display Git output" magit2-process-buffer t]
    ["Quit Magit" magit2-mode-bury-buffer t]))

;;; Mode

(defun magit2-load-config-extensions ()
  "Load Magit extensions that are defined at the Git config layer."
  (dolist (ext (magit2-get-all "magit2.extension"))
    (let ((sym (intern (format "magit2-%s-mode" ext))))
      (when (fboundp sym)
        (funcall sym 1)))))

(define-derived-mode magit2-mode magit2-section-mode "Magit"
  "Parent major mode from which Magit major modes inherit.

Magit is documented in info node `(magit2)'."
  :group 'magit2
  (hack-dir-local-variables-non-file-buffer)
  (face-remap-add-relative 'header-line 'magit2-header-line)
  (setq mode-line-process (magit2-repository-local-get 'mode-line-process))
  (setq-local revert-buffer-function 'magit2-refresh-buffer)
  (setq-local bookmark-make-record-function 'magit2--make-bookmark)
  (setq-local imenu-create-index-function 'magit2--imenu-create-index)
  (setq-local isearch-filter-predicate 'magit2-section--open-temporarily))

;;; Local Variables

(defvar-local magit2-buffer-arguments nil)
(defvar-local magit2-buffer-diff-args nil)
(defvar-local magit2-buffer-diff-files nil)
(defvar-local magit2-buffer-diff-files-suspended nil)
(defvar-local magit2-buffer-file-name nil)
(defvar-local magit2-buffer-files nil)
(defvar-local magit2-buffer-log-args nil)
(defvar-local magit2-buffer-log-files nil)
(defvar-local magit2-buffer-range nil)
(defvar-local magit2-buffer-range-hashed nil)
(defvar-local magit2-buffer-refname nil)
(defvar-local magit2-buffer-revision nil)
(defvar-local magit2-buffer-revision-hash nil)
(defvar-local magit2-buffer-revisions nil)
(defvar-local magit2-buffer-typearg nil)
(defvar-local magit2-buffer-upstream nil)

;; These variables are also used in file-visiting buffers.
;; Because the user may change the major-mode, they have
;; to be permanent buffer-local.
(put 'magit2-buffer-file-name 'permanent-local t)
(put 'magit2-buffer-refname 'permanent-local t)
(put 'magit2-buffer-revision 'permanent-local t)
(put 'magit2-buffer-revision-hash 'permanent-local t)

;; `magit2-status' re-enables mode function but its refresher
;; function does not reinstate this.
(put 'magit2-buffer-diff-files-suspended 'permanent-local t)

(defvar-local magit2-refresh-args nil
  "Obsolete.  Possibly the arguments used to refresh the current buffer.
Some third-party packages might still use this, but Magit does not.")
(put 'magit2-refresh-args 'permanent-local t)
(make-obsolete-variable 'magit2-refresh-args nil "Magit 3.0.0")

(defvar magit2-buffer-lock-functions nil
  "Obsolete buffer-locking support for third-party modes.
Implement the generic function `magit2-buffer-value' for
your mode instead of adding an entry to this variable.")
(make-obsolete-variable 'magit2-buffer-lock-functions nil "Magit 3.0.0")

(cl-defgeneric magit2-buffer-value ()
  (when-let ((fn (cdr (assq major-mode magit2-buffer-lock-functions))))
    (funcall fn (with-no-warnings magit2-refresh-args))))

(defvar-local magit2-previous-section nil)
(put 'magit2-previous-section 'permanent-local t)

(defvar-local magit2--imenu-group-types nil)
(defvar-local magit2--imenu-item-types nil)

;;; Setup Buffer

(defmacro magit2-setup-buffer (mode &optional locked &rest bindings)
  (declare (indent 2))
  `(magit2-setup-buffer-internal
    ,mode ,locked
    ,(cons 'list (mapcar (pcase-lambda (`(,var ,form))
                           `(list ',var ,form))
                         bindings))))

(defun magit2-setup-buffer-internal (mode locked bindings)
  (let* ((value   (and locked
                       (with-temp-buffer
                         (pcase-dolist (`(,var ,val) bindings)
                           (set (make-local-variable var) val))
                         (let ((major-mode mode))
                           (magit2-buffer-value)))))
         (buffer  (magit2-get-mode-buffer mode value))
         (section (and buffer (magit2-current-section)))
         (created (not buffer)))
    (unless buffer
      (setq buffer (magit2-with-toplevel
                     (magit2-generate-new-buffer mode value))))
    (with-current-buffer buffer
      (setq magit2-previous-section section)
      (funcall mode)
      (magit2-xref-setup 'magit2-setup-buffer-internal bindings)
      (pcase-dolist (`(,var ,val) bindings)
        (set (make-local-variable var) val))
      (when created
        (magit2-status-goto-initial-section)
        (run-hooks 'magit2-create-buffer-hook)))
    (magit2-display-buffer buffer)
    (with-current-buffer buffer
      (run-hooks 'magit2-setup-buffer-hook)
      (magit2-refresh-buffer))
    buffer))

(defun magit2-mode-setup (mode &rest args)
  "Setup up a MODE buffer using ARGS to generate its content."
  (declare (obsolete magit2-setup-buffer "Magit 3.0.0"))
  (with-no-warnings
    (magit2-mode-setup-internal mode args)))

(defun magit2-mode-setup-internal (mode args &optional locked)
  "Setup up a MODE buffer using ARGS to generate its content.
When optional LOCKED is non-nil, then create a buffer that is
locked to its value, which is derived from MODE and ARGS."
  (declare (obsolete magit2-setup-buffer "Magit 3.0.0"))
  (let* ((value   (and locked
                       (with-temp-buffer
                         (with-no-warnings
                           (setq magit2-refresh-args args))
                         (let ((major-mode mode))
                           (magit2-buffer-value)))))
         (buffer  (magit2-get-mode-buffer mode value))
         (section (and buffer (magit2-current-section)))
         (created (not buffer)))
    (unless buffer
      (setq buffer (magit2-with-toplevel
                     (magit2-generate-new-buffer mode value))))
    (with-current-buffer buffer
      (setq magit2-previous-section section)
      (with-no-warnings
        (setq magit2-refresh-args args))
      (funcall mode)
      (magit2-xref-setup 'magit2-mode-setup-internal args)
      (when created
        (magit2-status-goto-initial-section)
        (run-hooks 'magit2-create-buffer-hook)))
    (magit2-display-buffer buffer)
    (with-current-buffer buffer
      (run-hooks 'magit2-mode-setup-hook)
      (magit2-refresh-buffer))))

;;; Display Buffer

(defvar magit2-display-buffer-noselect nil
  "If non-nil, then `magit2-display-buffer' doesn't call `select-window'.")

(defun magit2-display-buffer (buffer &optional display-function)
  "Display BUFFER in some window and maybe select it.

If optional DISPLAY-FUNCTION is non-nil, then use that to display
the buffer.  Otherwise use `magit2-display-buffer-function', which
is the normal case.

Then, unless `magit2-display-buffer-noselect' is non-nil, select
the window which was used to display the buffer.

Also run the hooks `magit2-pre-display-buffer-hook'
and `magit2-post-display-buffer-hook'."
  (with-current-buffer buffer
    (run-hooks 'magit2-pre-display-buffer-hook))
  (let ((window (funcall (or display-function magit2-display-buffer-function)
                         buffer)))
    (unless magit2-display-buffer-noselect
      (let* ((old-frame (selected-frame))
             (new-frame (window-frame window)))
        (select-window window)
        (unless (eq old-frame new-frame)
          (select-frame-set-input-focus new-frame)))))
  (with-current-buffer buffer
    (run-hooks 'magit2-post-display-buffer-hook)))

(defun magit2-display-buffer-traditional (buffer)
  "Display BUFFER the way this has traditionally been done."
  (display-buffer
   buffer (if (and (derived-mode-p 'magit2-mode)
                   (not (memq (with-current-buffer buffer major-mode)
                              '(magit2-process-mode
                                magit2-revision-mode
                                magit2-diff-mode
                                magit2-stash-mode
                                magit2-status-mode))))
              '(display-buffer-same-window)
            nil))) ; display in another window

(defun magit2-display-buffer-same-window-except-diff-v1 (buffer)
  "Display BUFFER in the selected window except for some modes.
If a buffer's `major-mode' derives from `magit2-diff-mode' or
`magit2-process-mode', display it in another window.  Display all
other buffers in the selected window."
  (display-buffer
   buffer (if (with-current-buffer buffer
                (derived-mode-p 'magit2-diff-mode 'magit2-process-mode))
              '(nil (inhibit-same-window . t))
            '(display-buffer-same-window))))

(defun magit2--display-buffer-fullframe (buffer alist)
  (when-let ((window (or (display-buffer-reuse-window buffer alist)
                         (display-buffer-same-window buffer alist)
                         (display-buffer-pop-up-window buffer alist)
                         (display-buffer-use-some-window buffer alist))))
    (delete-other-windows window)
    window))

(defun magit2-display-buffer-fullframe-status-v1 (buffer)
  "Display BUFFER, filling entire frame if BUFFER is a status buffer.
Otherwise, behave like `magit2-display-buffer-traditional'."
  (if (eq (with-current-buffer buffer major-mode)
          'magit2-status-mode)
      (display-buffer buffer '(magit2--display-buffer-fullframe))
    (magit2-display-buffer-traditional buffer)))

(defun magit2--display-buffer-topleft (buffer alist)
  (or (display-buffer-reuse-window buffer alist)
      (when-let ((window2 (display-buffer-pop-up-window buffer alist)))
        (let ((window1 (get-buffer-window))
              (buffer1 (current-buffer))
              (buffer2 (window-buffer window2))
              (w2-quit-restore (window-parameter window2 'quit-restore)))
          (set-window-buffer window1 buffer2)
          (set-window-buffer window2 buffer1)
          (select-window window2)
          ;; Swap some window state that `magit2-mode-quit-window' and
          ;; `quit-restore-window' inspect.
          (set-window-prev-buffers window2 (cdr (window-prev-buffers window1)))
          (set-window-prev-buffers window1 nil)
          (set-window-parameter window2 'magit2-dedicated
                                (window-parameter window1 'magit2-dedicated))
          (set-window-parameter window1 'magit2-dedicated t)
          (set-window-parameter window1 'quit-restore
                                (list 'window 'window
                                      (nth 2 w2-quit-restore)
                                      (nth 3 w2-quit-restore)))
          (set-window-parameter window2 'quit-restore nil)
          window1))))

(defun magit2-display-buffer-fullframe-status-topleft-v1 (buffer)
  "Display BUFFER, filling entire frame if BUFFER is a status buffer.
When BUFFER derives from `magit2-diff-mode' or
`magit2-process-mode', try to display BUFFER to the top or left of
the current buffer rather than to the bottom or right, as
`magit2-display-buffer-fullframe-status-v1' would.  Whether the
split is made vertically or horizontally is determined by
`split-window-preferred-function'."
  (display-buffer
   buffer
   (cond ((eq (with-current-buffer buffer major-mode)
              'magit2-status-mode)
          '(magit2--display-buffer-fullframe))
         ((with-current-buffer buffer
            (derived-mode-p 'magit2-diff-mode 'magit2-process-mode))
          '(magit2--display-buffer-topleft))
         (t
          '(display-buffer-same-window)))))

(defun magit2--display-buffer-fullcolumn (buffer alist)
  (when-let ((window (or (display-buffer-reuse-window buffer alist)
                         (display-buffer-same-window buffer alist)
                         (display-buffer-below-selected buffer alist))))
    (delete-other-windows-vertically window)
    window))

(defun magit2-display-buffer-fullcolumn-most-v1 (buffer)
  "Display BUFFER using the full column except in some cases.
For most cases where BUFFER's `major-mode' derives from
`magit2-mode', display it in the selected window and grow that
window to the full height of the frame, deleting other windows in
that column as necessary.  However, display BUFFER in another
window if 1) BUFFER's mode derives from `magit2-process-mode', or
2) BUFFER's mode derives from `magit2-diff-mode', provided that
the mode of the current buffer derives from `magit2-log-mode' or
`magit2-cherry-mode'."
  (display-buffer
   buffer
   (cond ((and (or git-commit-mode
                   (derived-mode-p 'magit2-log-mode
                                   'magit2-cherry-mode
                                   'magit2-reflog-mode))
               (with-current-buffer buffer
                 (derived-mode-p 'magit2-diff-mode)))
          nil)
         ((with-current-buffer buffer
            (derived-mode-p 'magit2-process-mode))
          nil)
         (t
          '(magit2--display-buffer-fullcolumn)))))

(defun magit2-maybe-set-dedicated ()
  "Mark the selected window as dedicated if appropriate.

If a new window was created to display the buffer, then remember
that fact.  That information is used by `magit2-mode-quit-window',
to determine whether the window should be deleted when its last
Magit buffer is buried."
  (let ((window (get-buffer-window (current-buffer))))
    (when (and (window-live-p window)
               (not (window-prev-buffers window)))
      (set-window-parameter window 'magit2-dedicated t))))

;;; Get Buffer

(defvar-local magit2--default-directory nil
  "Value of `default-directory' when buffer is generated.
This exists to prevent a let-bound `default-directory' from
tricking `magit2-get-mode-buffer' or `magit2-mode-get-buffers'
into thinking a buffer belongs to a repo that it doesn't.")
(put 'magit2--default-directory 'permanent-local t)

(defun magit2-mode-get-buffers ()
  (let ((topdir (magit2-toplevel)))
    (--filter (with-current-buffer it
                (and (derived-mode-p 'magit2-mode)
                     (equal magit2--default-directory topdir)))
              (buffer-list))))

(defvar-local magit2-buffer-locked-p nil)
(put 'magit2-buffer-locked-p 'permanent-local t)

(defun magit2-get-mode-buffer (mode &optional value frame)
  "Return buffer belonging to the current repository whose major-mode is MODE.

If no such buffer exists then return nil.  Multiple buffers with
the same major-mode may exist for a repository but only one can
exist that hasn't been locked to its value.  Return that buffer
\(or nil if there is no such buffer) unless VALUE is non-nil, in
which case return the buffer that has been locked to that value.

If FRAME is nil or omitted, then consider all buffers.  Otherwise
  only consider buffers that are displayed in some live window
  on some frame.
If `all', then consider all buffers on all frames.
If `visible', then only consider buffers on all visible frames.
If `selected' or t, then only consider buffers on the selected
  frame.
If a frame, then only consider buffers on that frame."
  (if-let ((topdir (magit2-toplevel)))
      (cl-flet* ((b (buffer)
                    (with-current-buffer buffer
                      (and (eq major-mode mode)
                           (equal magit2--default-directory topdir)
                           (if value
                               (and magit2-buffer-locked-p
                                    (equal (magit2-buffer-value) value))
                             (not magit2-buffer-locked-p))
                           buffer)))
                 (w (window)
                    (b (window-buffer window)))
                 (f (frame)
                    (seq-some #'w (window-list frame 'no-minibuf))))
        (pcase-exhaustive frame
          (`nil                   (seq-some #'b (buffer-list)))
          (`all                   (seq-some #'f (frame-list)))
          (`visible               (seq-some #'f (visible-frame-list)))
          ((or `selected `t)      (seq-some #'w (window-list (selected-frame))))
          ((guard (framep frame)) (seq-some #'w (window-list frame)))))
    (magit2--not-inside-repository-error)))

(defun magit2-mode-get-buffer (mode &optional create frame value)
  (declare (obsolete magit2-get-mode-buffer "Magit 3.0.0"))
  (when create
    (error "`magit2-mode-get-buffer's CREATE argument is obsolete"))
  (if-let ((topdir (magit2-toplevel)))
      (--first (with-current-buffer it
                 (and (eq major-mode mode)
                      (equal magit2--default-directory topdir)
                      (if value
                          (and magit2-buffer-locked-p
                               (equal (magit2-buffer-value) value))
                        (not magit2-buffer-locked-p))))
               (if frame
                   (mapcar #'window-buffer
                           (window-list (unless (eq frame t) frame)))
                 (buffer-list)))
    (magit2--not-inside-repository-error)))

(defun magit2-generate-new-buffer (mode &optional value)
  (let* ((name (funcall magit2-generate-buffer-name-function mode value))
         (buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (setq magit2--default-directory default-directory)
      (setq magit2-buffer-locked-p (and value t))
      (magit2-restore-section-visibility-cache mode))
    (when magit2-uniquify-buffer-names
      (add-to-list 'uniquify-list-buffers-directory-modes mode)
      (with-current-buffer buffer
        (setq list-buffers-directory (abbreviate-file-name default-directory)))
      (let ((uniquify-buffer-name-style
             (if (memq uniquify-buffer-name-style '(nil forward))
                 'post-forward-angle-brackets
               uniquify-buffer-name-style)))
        (uniquify-rationalize-file-buffer-names
         name (file-name-directory (directory-file-name default-directory))
         buffer)))
    buffer))

(defun magit2-generate-buffer-name-default-function (mode &optional value)
  "Generate buffer name for a MODE buffer in the current repository.
The returned name is based on `magit2-buffer-name-format' and
takes `magit2-uniquify-buffer-names' and VALUE, if non-nil, into
account."
  (let ((m (substring (symbol-name mode) 0 -5))
        (v (and value (format "%s" (if (listp value) value (list value)))))
        (n (if magit2-uniquify-buffer-names
               (file-name-nondirectory
                (directory-file-name default-directory))
             (abbreviate-file-name default-directory))))
    (format-spec
     magit2-buffer-name-format
     `((?m . ,m)
       (?M . ,(if (eq mode 'magit2-status-mode) "magit2" m))
       (?v . ,(or v ""))
       (?V . ,(if v (concat " " v) ""))
       (?t . ,n)
       (?x . ,(if magit2-uniquify-buffer-names "" "*"))
       (?T . ,(if magit2-uniquify-buffer-names n (concat n "*")))))))

;;; Buffer Lock

(defun magit2-toggle-buffer-lock ()
  "Lock the current buffer to its value or unlock it.

Locking a buffer to its value prevents it from being reused to
display another value.  The name of a locked buffer contains its
value, which allows telling it apart from other locked buffers
and the unlocked buffer.

Not all Magit buffers can be locked to their values, for example
it wouldn't make sense to lock a status buffer.

There can only be a single unlocked buffer using a certain
major-mode per repository.  So when a buffer is being unlocked
and another unlocked buffer already exists for that mode and
repository, then the former buffer is instead deleted and the
latter is displayed in its place."
  (interactive)
  (if magit2-buffer-locked-p
      (if-let ((unlocked (magit2-get-mode-buffer major-mode)))
          (let ((locked (current-buffer)))
            (switch-to-buffer unlocked nil t)
            (kill-buffer locked))
        (setq magit2-buffer-locked-p nil)
        (rename-buffer (funcall magit2-generate-buffer-name-function
                                major-mode)))
    (if-let ((value (magit2-buffer-value)))
        (if-let ((locked (magit2-get-mode-buffer major-mode value)))
            (let ((unlocked (current-buffer)))
              (switch-to-buffer locked nil t)
              (kill-buffer unlocked))
          (setq magit2-buffer-locked-p t)
          (rename-buffer (funcall magit2-generate-buffer-name-function
                                  major-mode value)))
      (user-error "Buffer has no value it could be locked to"))))

;;; Bury Buffer

(defun magit2-mode-bury-buffer (&optional kill-buffer)
  "Bury the current buffer.
With a prefix argument, kill the buffer instead.
With two prefix arguments, also kill all Magit buffers associated
with this repository.
This is done using `magit2-bury-buffer-function'."
  (interactive "P")
  ;; Kill all associated Magit buffers when a double prefix arg is given.
  (when (>= (prefix-numeric-value kill-buffer) 16)
    (let ((current (current-buffer)))
      (dolist (buf (magit2-mode-get-buffers))
        (unless (eq buf current)
          (kill-buffer buf)))))
  (funcall magit2-bury-buffer-function kill-buffer))

(defun magit2-mode-quit-window (kill-buffer)
  "Quit the selected window and bury its buffer.

This behaves similar to `quit-window', but when the window
was originally created to display a Magit buffer and the
current buffer is the last remaining Magit buffer that was
ever displayed in the selected window, then delete that
window."
  (if (or (one-window-p)
          (--first (let ((buffer (car it)))
                     (and (not (eq buffer (current-buffer)))
                          (buffer-live-p buffer)
                          (or (not (window-parameter nil 'magit2-dedicated))
                              (with-current-buffer buffer
                                (derived-mode-p 'magit2-mode
                                                'magit2-process-mode)))))
                   (window-prev-buffers)))
      (quit-window kill-buffer)
    (let ((window (selected-window)))
      (quit-window kill-buffer)
      (when (window-live-p window)
        (delete-window window)))))

;;; Refresh Buffers

(defvar magit2-inhibit-refresh nil)

(defun magit2-refresh ()
  "Refresh some buffers belonging to the current repository.

Refresh the current buffer if its major mode derives from
`magit2-mode', and refresh the corresponding status buffer.

Run hooks `magit2-pre-refresh-hook' and `magit2-post-refresh-hook'."
  (interactive)
  (unless magit2-inhibit-refresh
    (unwind-protect
        (let ((start (current-time))
              (magit2--refresh-cache (or magit2--refresh-cache
                                        (list (cons 0 0)))))
          (when magit2-refresh-verbose
            (message "Refreshing magit2..."))
          (magit2-run-hook-with-benchmark 'magit2-pre-refresh-hook)
          (cond ((derived-mode-p 'magit2-mode)
                 (magit2-refresh-buffer))
                ((derived-mode-p 'tabulated-list-mode)
                 (revert-buffer)))
          (--when-let (and magit2-refresh-status-buffer
                           (not (derived-mode-p 'magit2-status-mode))
                           (magit2-get-mode-buffer 'magit2-status-mode))
            (with-current-buffer it
              (magit2-refresh-buffer)))
          (magit2-auto-revert-buffers)
          (cond
           ((and (not this-command)
                 (memq last-command magit2-post-commit-hook-commands))
            (magit2-run-hook-with-benchmark 'magit2-post-commit-hook))
           ((memq this-command magit2-post-stage-hook-commands)
            (magit2-run-hook-with-benchmark 'magit2-post-stage-hook))
           ((memq this-command magit2-post-unstage-hook-commands)
            (magit2-run-hook-with-benchmark 'magit2-post-unstage-hook)))
          (magit2-run-hook-with-benchmark 'magit2-post-refresh-hook)
          (when magit2-refresh-verbose
            (let* ((c (caar magit2--refresh-cache))
                   (a (+ c (cdar magit2--refresh-cache))))
              (message "Refreshing magit2...done (%.3fs, cached %s/%s (%.0f%%))"
                       (float-time (time-subtract (current-time) start))
                       c a (* (/ c (* a 1.0)) 100)))))
      (run-hooks 'magit2-unwind-refresh-hook))))

(defun magit2-refresh-all ()
  "Refresh all buffers belonging to the current repository.

Refresh all Magit buffers belonging to the current repository,
and revert buffers that visit files located inside the current
repository.

Run hooks `magit2-pre-refresh-hook' and `magit2-post-refresh-hook'."
  (interactive)
  (magit2-run-hook-with-benchmark 'magit2-pre-refresh-hook)
  (dolist (buffer (magit2-mode-get-buffers))
    (with-current-buffer buffer (magit2-refresh-buffer)))
  (magit2-auto-revert-buffers)
  (magit2-run-hook-with-benchmark 'magit2-post-refresh-hook))

(defvar-local magit2-refresh-start-time nil)

(defun magit2-refresh-buffer (&rest _ignore)
  "Refresh the current Magit buffer."
  (setq magit2-refresh-start-time (current-time))
  (let ((refresh (intern (format "%s-refresh-buffer"
                                 (substring (symbol-name major-mode) 0 -5))))
        (magit2--refresh-cache (or magit2--refresh-cache (list (cons 0 0)))))
    (when (functionp refresh)
      (when magit2-refresh-verbose
        (message "Refreshing buffer `%s'..." (buffer-name)))
      (let* ((buffer (current-buffer))
             (windows (cl-mapcan
                       (lambda (window)
                         (with-selected-window window
                           (with-current-buffer buffer
                             (when-let ((section (magit2-current-section)))
                               `(( ,window
                                   ,section
                                   ,@(magit2-refresh-get-relative-position)))))))
                       ;; If it qualifies, then the selected window
                       ;; comes first, but we want to handle it last
                       ;; so that its `magit2-section-movement-hook'
                       ;; run can override the effects of other runs.
                       (or (nreverse (get-buffer-window-list buffer nil t))
                           (list (selected-window))))))
        (deactivate-mark)
        (setq magit2-section-pre-command-section nil)
        (setq magit2-section-highlight-overlays nil)
        (setq magit2-section-highlighted-sections nil)
        (setq magit2-section-unhighlight-sections nil)
        (magit2-process-unset-mode-line-error-status)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (save-excursion
            (apply refresh (with-no-warnings magit2-refresh-args))))
        (pcase-dolist (`(,window . ,args) windows)
          (if (eq buffer (window-buffer window))
              (with-selected-window window
                (apply #'magit2-section-goto-successor args))
            (with-current-buffer buffer
              (let ((magit2-section-movement-hook nil))
                (apply #'magit2-section-goto-successor args)))))
        (run-hooks 'magit2-refresh-buffer-hook)
        (magit2-section-update-highlight)
        (set-buffer-modified-p nil))
      (when magit2-refresh-verbose
        (message "Refreshing buffer `%s'...done (%.3fs)" (buffer-name)
                 (float-time (time-subtract (current-time)
                                            magit2-refresh-start-time)))))))

(defun magit2-refresh-get-relative-position ()
  (when-let ((section (magit2-current-section)))
    (let ((start (oref section start)))
      (list (- (line-number-at-pos (point))
               (line-number-at-pos start))
            (- (point) (line-beginning-position))
            (and (magit2-hunk-section-p section)
                 (region-active-p)
                 (progn (goto-char (line-beginning-position))
                        (when  (looking-at "^[-+]") (forward-line))
                        (while (looking-at "^[ @]") (forward-line))
                        (let ((beg (point)))
                          (cond ((looking-at "^[-+]")
                                 (forward-line)
                                 (while (looking-at "^[-+]") (forward-line))
                                 (while (looking-at "^ ")    (forward-line))
                                 (forward-line -1)
                                 (regexp-quote (buffer-substring-no-properties
                                                beg (line-end-position))))
                                (t t)))))))))

;;; Save File-Visiting Buffers

(defvar disable-magit2-save-buffers nil)

(defun magit2-pre-command-hook ()
  (setq disable-magit2-save-buffers nil))
(add-hook 'pre-command-hook #'magit2-pre-command-hook)

(defvar magit2-after-save-refresh-buffers nil)

(defun magit2-after-save-refresh-buffers ()
  (dolist (buffer magit2-after-save-refresh-buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (magit2-refresh-buffer))))
  (setq magit2-after-save-refresh-buffers nil)
  (remove-hook 'post-command-hook 'magit2-after-save-refresh-buffers))

(defun magit2-after-save-refresh-status ()
  "Refresh the status buffer of the current repository.

This function is intended to be added to `after-save-hook'.

If the status buffer does not exist or the file being visited in
the current buffer isn't inside the working tree of a repository,
then do nothing.

Note that refreshing a Magit buffer is done by re-creating its
contents from scratch, which can be slow in large repositories.
If you are not satisfied with Magit's performance, then you
should obviously not add this function to that hook."
  (when (and (not disable-magit2-save-buffers)
             (magit2-inside-worktree-p t))
    (--when-let (ignore-errors (magit2-get-mode-buffer 'magit2-status-mode))
      (add-to-list 'magit2-after-save-refresh-buffers it)
      (add-hook 'post-command-hook 'magit2-after-save-refresh-buffers))))

(defun magit2-maybe-save-repository-buffers ()
  "Maybe save file-visiting buffers belonging to the current repository.
Do so if `magit2-save-repository-buffers' is non-nil.  You should
not remove this from any hooks, instead set that variable to nil
if you so desire."
  (when (and magit2-save-repository-buffers
             (not disable-magit2-save-buffers))
    (setq disable-magit2-save-buffers t)
    (let ((msg (current-message)))
      (magit2-save-repository-buffers
       (eq magit2-save-repository-buffers 'dontask))
      (when (and msg
                 (current-message)
                 (not (equal msg (current-message))))
        (message "%s" msg)))))

(add-hook 'magit2-pre-refresh-hook #'magit2-maybe-save-repository-buffers)
(add-hook 'magit2-pre-call-git-hook #'magit2-maybe-save-repository-buffers)
(add-hook 'magit2-pre-start-git-hook #'magit2-maybe-save-repository-buffers)

(defvar-local magit2-inhibit-refresh-save nil)

(defun magit2-save-repository-buffers (&optional arg)
  "Save file-visiting buffers belonging to the current repository.
After any buffer where `buffer-save-without-query' is non-nil
is saved without asking, the user is asked about each modified
buffer which visits a file in the current repository.  Optional
argument (the prefix) non-nil means save all with no questions."
  (interactive "P")
  (when-let ((topdir (magit2-rev-parse-safe "--show-toplevel")))
    (let ((remote (file-remote-p default-directory))
          (save-some-buffers-action-alist
           `((?Y (lambda (buffer)
                   (with-current-buffer buffer
                     (setq buffer-save-without-query t)
                     (save-buffer)))
                 "to save the current buffer and remember choice")
             (?N (lambda (buffer)
                   (with-current-buffer buffer
                     (setq magit2-inhibit-refresh-save t)))
                 "to skip the current buffer and remember choice")
             ,@save-some-buffers-action-alist)))
      (save-some-buffers
       arg (lambda ()
             (and buffer-file-name
                  ;; - Check whether refreshing is disabled.
                  (not magit2-inhibit-refresh-save)
                  ;; - Check whether the visited file is either on the
                  ;;   same remote as the repository, or both are on
                  ;;   the local system.
                  (equal (file-remote-p buffer-file-name) remote)
                  ;; Delayed checks that are more expensive for remote
                  ;; repositories, due to the required network access.
                  ;; - Check whether the file is inside the repository.
                  (equal (magit2-rev-parse-safe "--show-toplevel") topdir)
                  ;; - Check whether the file is actually writable.
                  (file-writable-p buffer-file-name)))))))

;;; Restore Window Configuration

(defvar magit2-inhibit-save-previous-winconf nil)

(defvar-local magit2-previous-window-configuration nil)
(put 'magit2-previous-window-configuration 'permanent-local t)

(defun magit2-save-window-configuration ()
  "Save the current window configuration.

Later, when the buffer is buried, it may be restored by
`magit2-restore-window-configuration'."
  (if magit2-inhibit-save-previous-winconf
      (when (eq magit2-inhibit-save-previous-winconf 'unset)
        (setq magit2-previous-window-configuration nil))
    (unless (get-buffer-window (current-buffer) (selected-frame))
      (setq magit2-previous-window-configuration
            (current-window-configuration)))))

(defun magit2-restore-window-configuration (&optional kill-buffer)
  "Bury or kill the current buffer and restore previous window configuration."
  (let ((winconf magit2-previous-window-configuration)
        (buffer (current-buffer))
        (frame (selected-frame)))
    (quit-window kill-buffer (selected-window))
    (when (and winconf (equal frame (window-configuration-frame winconf)))
      (set-window-configuration winconf)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq magit2-previous-window-configuration nil))))))

;;; Buffer History

(defun magit2-go-backward ()
  "Move backward in current buffer's history."
  (interactive)
  (if help-xref-stack
      (help-xref-go-back (current-buffer))
    (user-error "No previous entry in buffer's history")))

(defun magit2-go-forward ()
  "Move forward in current buffer's history."
  (interactive)
  (if help-xref-forward-stack
      (help-xref-go-forward (current-buffer))
    (user-error "No next entry in buffer's history")))

(defun magit2-insert-xref-buttons ()
  "Insert xref buttons."
  (when (and (not magit2-buffer-locked-p)
             (or help-xref-stack help-xref-forward-stack))
    (when help-xref-stack
      (magit2-xref-insert-button help-back-label 'magit2-xref-backward))
    (when help-xref-forward-stack
      (when help-xref-stack
        (insert " "))
      (magit2-xref-insert-button help-forward-label 'magit2-xref-forward))))

(defun magit2-xref-insert-button (label type)
  (magit2-insert-section (button label)
    (insert-text-button label 'type type
                        'help-args (list (current-buffer)))))

(define-button-type 'magit2-xref-backward
  :supertype 'help-back
  'mouse-face 'magit2-section-highlight
  'help-echo (purecopy "mouse-2, RET: go back to previous history entry"))

(define-button-type 'magit2-xref-forward
  :supertype 'help-forward
  'mouse-face 'magit2-section-highlight
  'help-echo (purecopy "mouse-2, RET: go back to next history entry"))

(defvar magit2-xref-modes
  '(magit2-log-mode
    magit2-reflog-mode
    magit2-diff-mode
    magit2-revision-mode)
  "List of modes for which to insert navigation buttons.")

(defun magit2-xref-setup (fn args)
  (when (memq major-mode magit2-xref-modes)
    (when help-xref-stack-item
      (push (cons (point) help-xref-stack-item) help-xref-stack)
      (setq help-xref-forward-stack nil))
    (when (called-interactively-p 'interactive)
      (--when-let (nthcdr 10 help-xref-stack)
        (setcdr it nil)))
    (setq help-xref-stack-item
          (list 'magit2-xref-restore fn default-directory args))))

(defun magit2-xref-restore (fn dir args)
  (setq default-directory dir)
  (funcall fn major-mode nil args)
  (magit2-refresh-buffer))

;;; Repository-Local Cache

(defvar magit2-repository-local-cache nil
  "Alist mapping `magit2-toplevel' paths to alists of key/value pairs.")

(defun magit2-repository-local-repository ()
  "Return the key for the current repository."
  (or (bound-and-true-p magit2--default-directory)
      (magit2-toplevel)))

(defun magit2-repository-local-set (key value &optional repository)
  "Set the repository-local VALUE for KEY.

Unless specified, REPOSITORY is the current buffer's repository.

If REPOSITORY is nil (meaning there is no current repository),
then the value is not cached, and we return nil."
  (let* ((repokey (or repository (magit2-repository-local-repository)))
         (cache (assoc repokey magit2-repository-local-cache)))
    ;; Don't cache values for a nil REPOSITORY, as the 'set' and 'get'
    ;; calls for some KEY may happen in unrelated contexts.
    (when repokey
      (if cache
          (let ((keyvalue (assoc key (cdr cache))))
            (if keyvalue
                ;; Update pre-existing value for key.
                (setcdr keyvalue value)
              ;; No such key in repository-local cache.
              (push (cons key value) (cdr cache))))
        ;; No cache for this repository.
        (push (cons repokey (list (cons key value)))
              magit2-repository-local-cache)))))

(defun magit2-repository-local-exists-p (key &optional repository)
  "Non-nil when a repository-local value exists for KEY.

Return a (KEY . VALUE) cons cell.

The KEY is matched using `equal'.

Unless specified, REPOSITORY is the current buffer's repository."
  (when-let ((cache (assoc (or repository
                               (magit2-repository-local-repository))
                           magit2-repository-local-cache)))
    (assoc key (cdr cache))))

(defun magit2-repository-local-get (key &optional default repository)
  "Return the repository-local value for KEY.

Return DEFAULT if no value for KEY exists.

The KEY is matched using `equal'.

Unless specified, REPOSITORY is the current buffer's repository."
  (if-let ((keyvalue (magit2-repository-local-exists-p key repository)))
      (cdr keyvalue)
    default))

(defun magit2-repository-local-delete (key &optional repository)
  "Delete the repository-local value for KEY.

Unless specified, REPOSITORY is the current buffer's repository."
  (when-let ((cache (assoc (or repository
                               (magit2-repository-local-repository))
                           magit2-repository-local-cache)))
    ;; There is no `assoc-delete-all'.
    (setf (cdr cache)
          (cl-delete key (cdr cache) :key #'car :test #'equal))))

(defmacro magit2--with-repository-local-cache (key &rest body)
  (declare (indent 1) (debug (form body)))
  (let ((k (cl-gensym)))
    `(let ((,k ,key))
       (if-let ((kv (magit2-repository-local-exists-p ,k)))
           (cdr kv)
         (let ((v ,(macroexp-progn body)))
           (magit2-repository-local-set ,k v)
           v)))))

(defun magit2-preserve-section-visibility-cache ()
  (when (derived-mode-p 'magit2-status-mode 'magit2-refs-mode)
    (magit2-repository-local-set
     (cons major-mode 'magit2-section-visibility-cache)
     magit2-section-visibility-cache)))

(defun magit2-restore-section-visibility-cache (mode)
  (setq magit2-section-visibility-cache
        (magit2-repository-local-get
         (cons mode 'magit2-section-visibility-cache))))

(defun magit2-zap-caches (&optional all)
  "Zap caches for the current repository.

Remove the repository's entry from `magit2-repository-local-cache',
remove the host's entry from `magit2--host-git-version-cache', set
`magit2-section-visibility-cache' to nil for all Magit buffers of
the repository.

With a prefix argument or if optional ALL is non-nil, discard the
mentioned caches completely."
  (interactive)
  (cond (all
         (setq magit2-repository-local-cache nil)
         (setq magit2--host-git-version-cache nil)
         (dolist (buffer (buffer-list))
           (with-current-buffer buffer
             (when (derived-mode-p 'magit2-mode)
               (setq magit2-section-visibility-cache nil)))))
        (t
         (magit2-with-toplevel
           (setq magit2-repository-local-cache
                 (cl-delete default-directory
                            magit2-repository-local-cache
                            :key #'car :test #'equal))
           (setq magit2--host-git-version-cache
                 (cl-delete (file-remote-p default-directory)
                            magit2--host-git-version-cache
                            :key #'car :test #'equal)))
         (dolist (buffer (magit2-mode-get-buffers))
           (with-current-buffer buffer
             (setq magit2-section-visibility-cache nil))))))

;;; Imenu Support

(defun magit2--imenu-create-index ()
  ;; If `which-function-mode' is active, then the create-index
  ;; function is called at the time the major-mode is being enabled.
  ;; Modes that derive from `magit2-mode' have not populated the buffer
  ;; at that time yet, so we have to abort.
  (and magit2-root-section
       (or magit2--imenu-group-types
           magit2--imenu-item-types)
       (let ((index
              (mapcan
               (lambda (section)
                 (cond
                  (magit2--imenu-group-types
                   (and (if (eq (car-safe magit2--imenu-group-types) 'not)
                            (not (magit2-section-match
                                  (cdr magit2--imenu-group-types)
                                  section))
                          (magit2-section-match magit2--imenu-group-types section))
                        (when-let ((children (oref section children)))
                          `((,(magit2--imenu-index-name section)
                             ,@(mapcar (lambda (s)
                                         (cons (magit2--imenu-index-name s)
                                               (oref s start)))
                                       children))))))
                  (magit2--imenu-item-types
                   (and (magit2-section-match magit2--imenu-item-types section)
                        `((,(magit2--imenu-index-name section)
                           . ,(oref section start)))))))
               (oref magit2-root-section children))))
         (if (and magit2--imenu-group-types (symbolp magit2--imenu-group-types))
             (cdar index)
           index))))

(defun magit2--imenu-index-name (section)
  (let ((heading (buffer-substring-no-properties
                  (oref section start)
                  (1- (or (oref section content)
                          (oref section end))))))
    (save-match-data
      (cond
       ((and (magit2-section-match [commit logbuf] section)
             (string-match "[^ ]+\\([ *|]*\\).+" heading))
        (replace-match " " t t heading 1))
       ((magit2-section-match
         '([branch local branchbuf] [tag tags branchbuf]) section)
        (oref section value))
       ((magit2-section-match [branch remote branchbuf] section)
        (concat (oref (oref section parent) value) "/"
                (oref section value)))
       ((string-match " ([0-9]+)\\'" heading)
        (substring heading 0 (match-beginning 0)))
       (t heading)))))

;;; Utilities

(defun magit2-toggle-verbose-refresh ()
  "Toggle whether Magit refreshes buffers verbosely.
Enabling this helps figuring out which sections are bottlenecks.
The additional output can be found in the *Messages* buffer."
  (interactive)
  (setq magit2-refresh-verbose (not magit2-refresh-verbose))
  (message "%s verbose refreshing"
           (if magit2-refresh-verbose "Enabled" "Disabled")))

(defun magit2-run-hook-with-benchmark (hook)
  (when hook
    (if magit2-refresh-verbose
        (let ((start (current-time)))
          (message "Running %s..." hook)
          (run-hooks hook)
          (message "Running %s...done (%.3fs)" hook
                   (float-time (time-subtract (current-time) start))))
      (run-hooks hook))))

;;; _
(provide 'magit2-mode)
;;; magit2-mode.el ends here
