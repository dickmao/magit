;;; magit2-apply.el --- apply Git diffs  -*- lexical-binding: t -*-

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

;; This library implements commands for applying Git diffs or parts
;; of such a diff.  The supported "apply variants" are apply, stage,
;; unstage, discard, and reverse - more than Git itself knows about,
;; at least at the porcelain level.

;;; Code:

(require 'magit2-core)
(require 'magit2-diff)
(require 'magit2-wip)
(require 'transient) ; See #3732.

;; For `magit2-apply'
(declare-function magit2-am "magit2-sequence" () t)
(declare-function magit2-patch-apply "magit2-patch" () t)
;; For `magit2-discard-files'
(declare-function magit2-checkout-stage "magit2-merge" (file arg))
(declare-function magit2-checkout-read-stage "magit2-merge" (file))
(defvar auto-revert-verbose)
;; For `magit2-stage-untracked'
(declare-function magit2-submodule-add-1 "magit2-submodule"
                  (url &optional path name args))
(declare-function magit2-submodule-read-name-for-path "magit2-submodule"
                  (path &optional prefer-short))
(declare-function borg--maybe-absorb-gitdir "borg" (pkg))
(declare-function borg--sort-submodule-sections "borg" (file))
(declare-function borg-assimilate "borg" (package url &optional partially))
(defvar borg-user-emacs-directory)

(cl-eval-when (compile load)
  (when (< emacs-major-version 26)
    (defalias 'smerge-keep-upper 'smerge-keep-mine)
    (defalias 'smerge-keep-lower 'smerge-keep-other)))

;;; Options

(defcustom magit2-delete-by-moving-to-trash t
  "Whether Magit uses the system's trash can.

You should absolutely not disable this and also remove `discard'
from `magit2-no-confirm'.  You shouldn't do that even if you have
all of the Magit-Wip modes enabled, because those modes do not
track any files that are not tracked in the proper branch."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-essentials
  :type 'boolean)

(defcustom magit2-unstage-committed t
  "Whether unstaging a committed change reverts it instead.

A committed change cannot be unstaged, because staging and
unstaging are actions that are concerned with the differences
between the index and the working tree, not with committed
changes.

If this option is non-nil (the default), then typing \"u\"
\(`magit2-unstage') on a committed change, causes it to be
reversed in the index but not the working tree.  For more
information see command `magit2-reverse-in-index'."
  :package-version '(magit2 . "2.4.1")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-reverse-atomically nil
  "Whether to reverse changes atomically.

If some changes can be reversed while others cannot, then nothing
is reversed if the value of this option is non-nil.  But when it
is nil, then the changes that can be reversed are reversed and
for the other changes diff files are created that contain the
rejected reversals."
  :package-version '(magit2 . "2.7.0")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-post-stage-hook nil
  "Hook run after staging changes.
This hook is run by `magit2-refresh' if `this-command'
is a member of `magit2-post-stage-hook-commands'."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-commands
  :type 'hook)

(defvar magit2-post-stage-hook-commands
  '(magit2-stage magit2-stage-file magit2-stage-modified))

(defcustom magit2-post-unstage-hook nil
  "Hook run after unstaging changes.
This hook is run by `magit2-refresh' if `this-command'
is a member of `magit2-post-unstage-hook-commands'."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-commands
  :type 'hook)

(defvar magit2-post-unstage-hook-commands
  '(magit2-unstage magit2-unstage-file magit2-unstage-all))

;;; Commands
;;;; Apply

(defun magit2-apply (&rest args)
  "Apply the change at point to the working tree.
With a prefix argument fallback to a 3-way merge.  Doing
so causes the change to be applied to the index as well."
  (interactive (and current-prefix-arg (list "--3way")))
  (--when-let (magit2-apply--get-selection)
    (pcase (list (magit2-diff-type) (magit2-diff-scope))
      (`(,(or `unstaged `staged) ,_)
       (user-error "Change is already in the working tree"))
      (`(untracked ,(or `file `files))
       (call-interactively 'magit2-am))
      (`(,_ region) (magit2-apply-region it args))
      (`(,_   hunk) (magit2-apply-hunk   it args))
      (`(,_  hunks) (magit2-apply-hunks  it args))
      (`(rebase-sequence file)
       (call-interactively 'magit2-patch-apply))
      (`(,_   file) (magit2-apply-diff   it args))
      (`(,_  files) (magit2-apply-diffs  it args)))))

(defun magit2-apply--section-content (section)
  (buffer-substring-no-properties (if (magit2-hunk-section-p section)
                                      (oref section start)
                                    (oref section content))
                                  (oref section end)))

(defun magit2-apply-diffs (sections &rest args)
  (setq sections (magit2-apply--get-diffs sections))
  (magit2-apply-patch sections args
                     (mapconcat
                      (lambda (s)
                        (concat (magit2-diff-file-header s)
                                (magit2-apply--section-content s)))
                      sections "")))

(defun magit2-apply-diff (section &rest args)
  (setq section (car (magit2-apply--get-diffs (list section))))
  (magit2-apply-patch section args
                     (concat (magit2-diff-file-header section)
                             (magit2-apply--section-content section))))

(defun magit2-apply--adjust-hunk-new-starts (hunks)
  "Adjust new line numbers in headers of HUNKS for partial application.
HUNKS should be a list of ordered, contiguous hunks to be applied
from a file.  For example, if there is a sequence of hunks with
the headers

  @@ -2,6 +2,7 @@
  @@ -10,6 +11,7 @@
  @@ -18,6 +20,7 @@

and only the second and third are to be applied, they would be
adjusted as \"@@ -10,6 +10,7 @@\" and \"@@ -18,6 +19,7 @@\"."
  (let* ((first-hunk (car hunks))
         (offset (if (string-match diff-hunk-header-re-unified first-hunk)
                     (- (string-to-number (match-string 3 first-hunk))
                        (string-to-number (match-string 1 first-hunk)))
                   (error "Header hunks have to be applied individually"))))
    (if (= offset 0)
        hunks
      (mapcar (lambda (hunk)
                (if (string-match diff-hunk-header-re-unified hunk)
                    (replace-match (number-to-string
                                    (- (string-to-number (match-string 3 hunk))
                                       offset))
                                   t t hunk 3)
                  (error "Hunk does not have expected header")))
              hunks))))

(defun magit2-apply--adjust-hunk-new-start (hunk)
  (car (magit2-apply--adjust-hunk-new-starts (list hunk))))

(defun magit2-apply-hunks (sections &rest args)
  (let ((section (oref (car sections) parent)))
    (when (string-match "^diff --cc" (oref section value))
      (user-error "Cannot un-/stage resolution hunks.  Stage the whole file"))
    (magit2-apply-patch
     section args
     (concat (oref section header)
             (mapconcat #'identity
                        (magit2-apply--adjust-hunk-new-starts
                         (mapcar #'magit2-apply--section-content sections))
                        "")))))

(defun magit2-apply-hunk (section &rest args)
  (when (string-match "^diff --cc" (magit2-section-parent-value section))
    (user-error "Cannot un-/stage resolution hunks.  Stage the whole file"))
  (let* ((header (car (oref section value)))
         (header (and (symbolp header) header))
         (content (magit2-apply--section-content section)))
    (magit2-apply-patch
     (oref section parent) args
     (concat (magit2-diff-file-header section (not (eq header 'rename)))
             (if header
                 content
               (magit2-apply--adjust-hunk-new-start content))))))

(defun magit2-apply-region (section &rest args)
  (when (string-match "^diff --cc" (magit2-section-parent-value section))
    (user-error "Cannot un-/stage resolution hunks.  Stage the whole file"))
  (magit2-apply-patch (oref section parent) args
                     (concat (magit2-diff-file-header section)
                             (magit2-apply--adjust-hunk-new-start
                              (magit2-diff-hunk-region-patch section args)))))

(defun magit2-apply-patch (section:s args patch)
  (let* ((files (if (atom section:s)
                    (list (oref section:s value))
                  (--map (oref it value) section:s)))
         (command (symbol-name this-command))
         (command (if (and command (string-match "^magit2-\\([^-]+\\)" command))
                      (match-string 1 command)
                    "apply"))
         (ignore-context (magit2-diff-ignore-any-space-p)))
    (unless (magit2-diff-context-p)
      (user-error "Not enough context to apply patch.  Increase the context"))
    (when (and magit2-wip-before-change-mode (not magit2-inhibit-refresh))
      (magit2-wip-commit-before-change files (concat " before " command)))
    (with-temp-buffer
      (insert patch)
      (magit2-run-git-with-input
       "apply" args "-p0"
       (and ignore-context "-C0")
       "--ignore-space-change" "-"))
    (unless magit2-inhibit-refresh
      (when magit2-wip-after-apply-mode
        (magit2-wip-commit-after-apply files (concat " after " command)))
      (magit2-refresh))))

(defun magit2-apply--get-selection ()
  (or (magit2-region-sections '(hunk file module) t)
      (let ((section (magit2-current-section)))
        (pcase (oref section type)
          ((or `hunk `file `module) section)
          ((or `staged `unstaged `untracked
               `stashed-index `stashed-worktree `stashed-untracked)
           (oref section children))
          (_ (user-error "Cannot apply this, it's not a change"))))))

(defun magit2-apply--get-diffs (sections)
  (magit2-section-case
    ([file diffstat]
     (--map (or (magit2-get-section
                 (append `((file . ,(oref it value)))
                         (magit2-section-ident magit2-root-section)))
                (error "Cannot get required diff headers"))
            sections))
    (t sections)))

(defun magit2-apply--diff-ignores-whitespace-p ()
  (and (cl-intersection magit2-buffer-diff-args
                        '("--ignore-space-at-eol"
                          "--ignore-space-change"
                          "--ignore-all-space"
                          "--ignore-blank-lines")
                        :test #'equal)
       t))

;;;; Stage

(defun magit2-stage (&optional intent)
  "Add the change at point to the staging area.
With a prefix argument, INTENT, and an untracked file (or files)
at point, stage the file but not its content."
  (interactive "P")
  (--if-let (and (derived-mode-p 'magit2-mode) (magit2-apply--get-selection))
      (pcase (list (magit2-diff-type)
                   (magit2-diff-scope)
                   (magit2-apply--diff-ignores-whitespace-p))
        (`(untracked     ,_  ,_) (magit2-stage-untracked intent))
        (`(unstaged  region  ,_) (magit2-apply-region it "--cached"))
        (`(unstaged    hunk  ,_) (magit2-apply-hunk   it "--cached"))
        (`(unstaged   hunks  ,_) (magit2-apply-hunks  it "--cached"))
        (`(unstaged    file   t) (magit2-apply-diff   it "--cached"))
        (`(unstaged   files   t) (magit2-apply-diffs  it "--cached"))
        (`(unstaged    list   t) (magit2-apply-diffs  it "--cached"))
        (`(unstaged    file nil) (magit2-stage-1 "-u" (list (oref it value))))
        (`(unstaged   files nil) (magit2-stage-1 "-u" (magit2-region-values nil t)))
        (`(unstaged    list nil) (magit2-stage-modified))
        (`(staged        ,_  ,_) (user-error "Already staged"))
        (`(committed     ,_  ,_) (user-error "Cannot stage committed changes"))
        (`(undefined     ,_  ,_) (user-error "Cannot stage this change")))
    (call-interactively 'magit2-stage-file)))

;;;###autoload
(defun magit2-stage-file (file)
  "Stage all changes to FILE.
With a prefix argument or when there is no file at point ask for
the file to be staged.  Otherwise stage the file at point without
requiring confirmation."
  (interactive
   (let* ((atpoint (magit2-section-value-if 'file))
          (current (magit2-file-relative-name))
          (choices (nconc (magit2-unstaged-files)
                          (magit2-untracked-files)))
          (default (car (member (or atpoint current) choices))))
     (list (if (or current-prefix-arg (not default))
               (magit2-completing-read "Stage file" choices
                                      nil t nil nil default)
             default))))
  (magit2-with-toplevel
    (magit2-stage-1 nil (list file))))

;;;###autoload
(defun magit2-stage-modified (&optional all)
  "Stage all changes to files modified in the worktree.
Stage all new content of tracked files and remove tracked files
that no longer exist in the working tree from the index also.
With a prefix argument also stage previously untracked (but not
ignored) files."
  (interactive "P")
  (when (magit2-anything-staged-p)
    (magit2-confirm 'stage-all-changes))
  (magit2-with-toplevel
    (magit2-stage-1 (if all "--all" "-u") magit2-buffer-diff-files)))

(defun magit2-stage-1 (arg &optional files)
  (magit2-wip-commit-before-change files " before stage")
  (magit2-run-git "add" arg (if files (cons "--" files) "."))
  (when magit2-auto-revert-mode
    (mapc #'magit2-turn-on-auto-revert-mode-if-desired files))
  (magit2-wip-commit-after-apply files " after stage"))

(defun magit2-stage-untracked (&optional intent)
  (let* ((section (magit2-current-section))
         (files (pcase (magit2-diff-scope)
                  (`file  (list (oref section value)))
                  (`files (magit2-region-values nil t))
                  (`list  (magit2-untracked-files))))
         plain repos)
    (dolist (file files)
      (if (and (not (file-symlink-p file))
               (magit2-git-repo-p file t))
          (push file repos)
        (push file plain)))
    (magit2-wip-commit-before-change files " before stage")
    (when plain
      (magit2-run-git "add" (and intent "--intent-to-add")
                     "--" plain)
      (when magit2-auto-revert-mode
        (mapc #'magit2-turn-on-auto-revert-mode-if-desired plain)))
    (dolist (repo repos)
      (save-excursion
        (goto-char (oref (magit2-get-section
                          `((file . ,repo) (untracked) (status)))
                         start))
        (let* ((topdir (magit2-toplevel))
               (url (let ((default-directory
                            (file-name-as-directory (expand-file-name repo))))
                      (or (magit2-get "remote" (magit2-get-some-remote) "url")
                          (concat (file-name-as-directory ".") repo))))
               (package
                (and (equal (bound-and-true-p borg-user-emacs-directory)
                            topdir)
                     (file-name-nondirectory (directory-file-name repo)))))
          (if (and package
                   (y-or-n-p (format "Also assimilate `%s' drone?" package)))
              (borg-assimilate package url)
            (magit2-submodule-add-1
             url repo (magit2-submodule-read-name-for-path repo package))
            (when package
              (borg--sort-submodule-sections
               (expand-file-name ".gitmodules" topdir))
              (let ((default-directory borg-user-emacs-directory))
                (borg--maybe-absorb-gitdir package)))))))
    (magit2-wip-commit-after-apply files " after stage")))

;;;; Unstage

(defun magit2-unstage ()
  "Remove the change at point from the staging area."
  (interactive)
  (--when-let (magit2-apply--get-selection)
    (pcase (list (magit2-diff-type)
                 (magit2-diff-scope)
                 (magit2-apply--diff-ignores-whitespace-p))
      (`(untracked     ,_  ,_) (user-error "Cannot unstage untracked changes"))
      (`(unstaged    file  ,_) (magit2-unstage-intent (list (oref it value))))
      (`(unstaged   files  ,_) (magit2-unstage-intent (magit2-region-values nil t)))
      (`(unstaged      ,_  ,_) (user-error "Already unstaged"))
      (`(staged    region  ,_) (magit2-apply-region it "--reverse" "--cached"))
      (`(staged      hunk  ,_) (magit2-apply-hunk   it "--reverse" "--cached"))
      (`(staged     hunks  ,_) (magit2-apply-hunks  it "--reverse" "--cached"))
      (`(staged      file   t) (magit2-apply-diff   it "--reverse" "--cached"))
      (`(staged     files   t) (magit2-apply-diffs  it "--reverse" "--cached"))
      (`(staged      list   t) (magit2-apply-diffs  it "--reverse" "--cached"))
      (`(staged      file nil) (magit2-unstage-1 (list (oref it value))))
      (`(staged     files nil) (magit2-unstage-1 (magit2-region-values nil t)))
      (`(staged      list nil) (magit2-unstage-all))
      (`(committed     ,_  ,_) (if magit2-unstage-committed
                                   (magit2-reverse-in-index)
                                 (user-error "Cannot unstage committed changes")))
      (`(undefined     ,_  ,_) (user-error "Cannot unstage this change")))))

;;;###autoload
(defun magit2-unstage-file (file)
  "Unstage all changes to FILE.
With a prefix argument or when there is no file at point ask for
the file to be unstaged.  Otherwise unstage the file at point
without requiring confirmation."
  (interactive
   (let* ((atpoint (magit2-section-value-if 'file))
          (current (magit2-file-relative-name))
          (choices (magit2-staged-files))
          (default (car (member (or atpoint current) choices))))
     (list (if (or current-prefix-arg (not default))
               (magit2-completing-read "Unstage file" choices
                                      nil t nil nil default)
             default))))
  (magit2-with-toplevel
    (magit2-unstage-1 (list file))))

(defun magit2-unstage-1 (files)
  (magit2-wip-commit-before-change files " before unstage")
  (if (magit2-no-commit-p)
      (magit2-run-git "rm" "--cached" "--" files)
    (magit2-run-git "reset" "HEAD" "--" files))
  (magit2-wip-commit-after-apply files " after unstage"))

(defun magit2-unstage-intent (files)
  (if-let ((staged (magit2-staged-files))
           (intent (--filter (member it staged) files)))
      (magit2-unstage-1 intent)
    (user-error "Already unstaged")))

;;;###autoload
(defun magit2-unstage-all ()
  "Remove all changes from the staging area."
  (interactive)
  (unless (magit2-anything-staged-p)
    (user-error "Nothing to unstage"))
  (when (or (magit2-anything-unstaged-p)
            (magit2-untracked-files))
    (magit2-confirm 'unstage-all-changes))
  (magit2-wip-commit-before-change nil " before unstage")
  (magit2-run-git "reset" "HEAD" "--" magit2-buffer-diff-files)
  (magit2-wip-commit-after-apply nil " after unstage"))

;;;; Discard

(defun magit2-discard ()
  "Remove the change at point.

On a hunk or file with unresolved conflicts prompt which side to
keep (while discarding the other).  If point is within the text
of a side, then keep that side without prompting."
  (interactive)
  (--when-let (magit2-apply--get-selection)
    (pcase (list (magit2-diff-type) (magit2-diff-scope))
      (`(committed ,_) (user-error "Cannot discard committed changes"))
      (`(undefined ,_) (user-error "Cannot discard this change"))
      (`(,_    region) (magit2-discard-region it))
      (`(,_      hunk) (magit2-discard-hunk   it))
      (`(,_     hunks) (magit2-discard-hunks  it))
      (`(,_      file) (magit2-discard-file   it))
      (`(,_     files) (magit2-discard-files  it))
      (`(,_      list) (magit2-discard-files  it)))))

(defun magit2-discard-region (section)
  (magit2-confirm 'discard "Discard region")
  (magit2-discard-apply section 'magit2-apply-region))

(defun magit2-discard-hunk (section)
  (magit2-confirm 'discard "Discard hunk")
  (let ((file (magit2-section-parent-value section)))
    (pcase (cddr (car (magit2-file-status file)))
      (`(?U ?U) (magit2-smerge-keep-current))
      (_ (magit2-discard-apply section 'magit2-apply-hunk)))))

(defun magit2-discard-apply (section apply)
  (if (eq (magit2-diff-type section) 'unstaged)
      (funcall apply section "--reverse")
    (if (magit2-anything-unstaged-p
         nil (if (magit2-file-section-p section)
                 (oref section value)
               (magit2-section-parent-value section)))
        (progn (let ((magit2-inhibit-refresh t))
                 (funcall apply section "--reverse" "--cached")
                 (funcall apply section "--reverse" "--reject"))
               (magit2-refresh))
      (funcall apply section "--reverse" "--index"))))

(defun magit2-discard-hunks (sections)
  (magit2-confirm 'discard (format "Discard %s hunks from %s"
                                  (length sections)
                                  (magit2-section-parent-value (car sections))))
  (magit2-discard-apply-n sections 'magit2-apply-hunks))

(defun magit2-discard-apply-n (sections apply)
  (let ((section (car sections)))
    (if (eq (magit2-diff-type section) 'unstaged)
        (funcall apply sections "--reverse")
      (if (magit2-anything-unstaged-p
           nil (if (magit2-file-section-p section)
                   (oref section value)
                 (magit2-section-parent-value section)))
          (progn (let ((magit2-inhibit-refresh t))
                   (funcall apply sections "--reverse" "--cached")
                   (funcall apply sections "--reverse" "--reject"))
                 (magit2-refresh))
        (funcall apply sections "--reverse" "--index")))))

(defun magit2-discard-file (section)
  (magit2-discard-files (list section)))

(defun magit2-discard-files (sections)
  (let ((auto-revert-verbose nil)
        (type (magit2-diff-type (car sections)))
        (status (magit2-file-status))
        files delete resurrect rename discard discard-new resolve)
    (dolist (section sections)
      (let ((file (oref section value)))
        (push file files)
        (pcase (cons (pcase type
                       (`staged ?X)
                       (`unstaged ?Y)
                       (`untracked ?Z))
                     (cddr (assoc file status)))
          (`(?Z) (dolist (f (magit2-untracked-files nil file))
                   (push f delete)))
          ((or `(?Z ?? ??) `(?Z ?! ?!)) (push file delete))
          (`(?Z ?D ? )                  (push file delete))
          (`(,_ ?D ?D)                  (push file resolve))
          ((or `(,_ ?U ,_) `(,_ ,_ ?U)) (push file resolve))
          (`(,_ ?A ?A)                  (push file resolve))
          (`(?X ?M ,(or ?  ?M ?D)) (push section discard))
          (`(?Y ,_         ?M    ) (push section discard))
          (`(?X ?A         ?M    ) (push file discard-new))
          (`(?X ?C         ?M    ) (push file discard-new))
          (`(?X ?A ,(or ?     ?D)) (push file delete))
          (`(?X ?C ,(or ?     ?D)) (push file delete))
          (`(?X ?D ,(or ?  ?M   )) (push file resurrect))
          (`(?Y ,_            ?D ) (push file resurrect))
          (`(?X ?R ,(or ?  ?M ?D)) (push file rename)))))
    (unwind-protect
        (let ((magit2-inhibit-refresh t))
          (magit2-wip-commit-before-change files " before discard")
          (when resolve
            (magit2-discard-files--resolve (nreverse resolve)))
          (when resurrect
            (magit2-discard-files--resurrect (nreverse resurrect)))
          (when delete
            (magit2-discard-files--delete (nreverse delete) status))
          (when rename
            (magit2-discard-files--rename (nreverse rename) status))
          (when (or discard discard-new)
            (magit2-discard-files--discard (nreverse discard)
                                          (nreverse discard-new)))
          (magit2-wip-commit-after-apply files " after discard"))
      (magit2-refresh))))

(defun magit2-discard-files--resolve (files)
  (if-let ((arg (and (cdr files)
                     (magit2-read-char-case
                         (format "For these %i files\n%s\ncheckout:\n"
                                 (length files)
                                 (mapconcat (lambda (file)
                                              (concat "  " file))
                                            files "\n"))
                         t
                       (?o "[o]ur stage"   "--ours")
                       (?t "[t]heir stage" "--theirs")
                       (?c "[c]onflict"    "--merge")
                       (?i "decide [i]ndividually" nil)))))
      (dolist (file files)
        (magit2-checkout-stage file arg))
    (dolist (file files)
      (magit2-checkout-stage file (magit2-checkout-read-stage file)))))

(defun magit2-discard-files--resurrect (files)
  (magit2-confirm-files 'resurrect files)
  (if (eq (magit2-diff-type) 'staged)
      (magit2-call-git "reset"  "--" files)
    (magit2-call-git "checkout" "--" files)))

(defun magit2-discard-files--delete (files status)
  (magit2-confirm-files (if magit2-delete-by-moving-to-trash 'trash 'delete)
                       files)
  (let ((delete-by-moving-to-trash magit2-delete-by-moving-to-trash))
    (dolist (file files)
      (when (string-match-p "\\`\\\\?~" file)
        (error "Refusing to delete %S, too dangerous" file))
      (pcase (nth 3 (assoc file status))
        ((guard (memq (magit2-diff-type) '(unstaged untracked)))
         (dired-delete-file file dired-recursive-deletes
                            magit2-delete-by-moving-to-trash)
         (dired-clean-up-after-deletion file))
        (?\s (delete-file file t)
             (magit2-call-git "rm" "--cached" "--" file))
        (?M  (let ((temp (magit2-git-string "checkout-index" "--temp" file)))
               (string-match
                (format "\\(.+?\\)\t%s" (regexp-quote file)) temp)
               (rename-file (match-string 1 temp)
                            (setq temp (concat file ".~{index}~")))
               (delete-file temp t))
             (magit2-call-git "rm" "--cached" "--force" "--" file))
        (?D  (magit2-call-git "checkout" "--" file)
             (delete-file file t)
             (magit2-call-git "rm" "--cached" "--force" "--" file))))))

(defun magit2-discard-files--rename (files status)
  (magit2-confirm 'rename "Undo rename %s" "Undo %i renames" nil
    (mapcar (lambda (file)
              (setq file (assoc file status))
              (format "%s -> %s" (cadr file) (car file)))
            files))
  (dolist (file files)
    (let ((orig (cadr (assoc file status))))
      (if (file-exists-p file)
          (progn
            (--when-let (file-name-directory orig)
              (make-directory it t))
            (magit2-call-git "mv" file orig))
        (magit2-call-git "rm" "--cached" "--" file)
        (magit2-call-git "reset" "--" orig)))))

(defun magit2-discard-files--discard (sections new-files)
  (let ((files (--map (oref it value) sections)))
    (magit2-confirm-files 'discard (append files new-files)
                         (format "Discard %s changes in" (magit2-diff-type)))
    (if (eq (magit2-diff-type (car sections)) 'unstaged)
        (magit2-call-git "checkout" "--" files)
      (when new-files
        (magit2-call-git "add"   "--" new-files)
        (magit2-call-git "reset" "--" new-files))
      (let ((binaries (magit2-binary-files "--cached")))
        (when binaries
          (setq sections
                (--remove (member (oref it value) binaries)
                          sections)))
        (cond ((= (length sections) 1)
               (magit2-discard-apply (car sections) 'magit2-apply-diff))
              (sections
               (magit2-discard-apply-n sections 'magit2-apply-diffs)))
        (when binaries
          (let ((modified (magit2-unstaged-files t)))
            (setq binaries (--separate (member it modified) binaries)))
          (when (cadr binaries)
            (magit2-call-git "reset" "--" (cadr binaries)))
          (when (car binaries)
            (user-error
             (concat
              "Cannot discard staged changes to binary files, "
              "which also have unstaged changes.  Unstage instead."))))))))

;;;; Reverse

(defun magit2-reverse (&rest args)
  "Reverse the change at point in the working tree.
With a prefix argument fallback to a 3-way merge.  Doing
so causes the change to be applied to the index as well."
  (interactive (and current-prefix-arg (list "--3way")))
  (--when-let (magit2-apply--get-selection)
    (pcase (list (magit2-diff-type) (magit2-diff-scope))
      (`(untracked ,_) (user-error "Cannot reverse untracked changes"))
      (`(unstaged  ,_) (user-error "Cannot reverse unstaged changes"))
      (`(,_    region) (magit2-reverse-region it args))
      (`(,_      hunk) (magit2-reverse-hunk   it args))
      (`(,_     hunks) (magit2-reverse-hunks  it args))
      (`(,_      file) (magit2-reverse-file   it args))
      (`(,_     files) (magit2-reverse-files  it args))
      (`(,_      list) (magit2-reverse-files  it args)))))

(defun magit2-reverse-region (section args)
  (magit2-confirm 'reverse "Reverse region")
  (magit2-reverse-apply section 'magit2-apply-region args))

(defun magit2-reverse-hunk (section args)
  (magit2-confirm 'reverse "Reverse hunk")
  (magit2-reverse-apply section 'magit2-apply-hunk args))

(defun magit2-reverse-hunks (sections args)
  (magit2-confirm 'reverse
    (format "Reverse %s hunks from %s"
            (length sections)
            (magit2-section-parent-value (car sections))))
  (magit2-reverse-apply sections 'magit2-apply-hunks args))

(defun magit2-reverse-file (section args)
  (magit2-reverse-files (list section) args))

(defun magit2-reverse-files (sections args)
  (pcase-let ((`(,binaries ,sections)
               (let ((bs (magit2-binary-files
                          (cond ((derived-mode-p 'magit2-revision-mode)
                                 magit2-buffer-range)
                                ((derived-mode-p 'magit2-diff-mode)
                                 magit2-buffer-range)
                                (t
                                 "--cached")))))
                 (--separate (member (oref it value) bs)
                             sections))))
    (magit2-confirm-files 'reverse (--map (oref it value) sections))
    (cond ((= (length sections) 1)
           (magit2-reverse-apply (car sections) 'magit2-apply-diff args))
          (sections
           (magit2-reverse-apply sections 'magit2-apply-diffs args)))
    (when binaries
      (user-error "Cannot reverse binary files"))))

(defun magit2-reverse-apply (section:s apply args)
  (funcall apply section:s "--reverse" args
           (and (not magit2-reverse-atomically)
                (not (member "--3way" args))
                "--reject")))

(defun magit2-reverse-in-index (&rest args)
  "Reverse the change at point in the index but not the working tree.

Use this command to extract a change from `HEAD', while leaving
it in the working tree, so that it can later be committed using
a separate commit.  A typical workflow would be:

0. Optionally make sure that there are no uncommitted changes.
1. Visit the `HEAD' commit and navigate to the change that should
   not have been included in that commit.
2. Type \"u\" (`magit2-unstage') to reverse it in the index.
   This assumes that `magit2-unstage-committed-changes' is non-nil.
3. Type \"c e\" to extend `HEAD' with the staged changes,
   including those that were already staged before.
4. Optionally stage the remaining changes using \"s\" or \"S\"
   and then type \"c c\" to create a new commit."
  (interactive)
  (magit2-reverse (cons "--cached" args)))

;;; Smerge Support

(defun magit2-smerge-keep-current ()
  "Keep the current version of the conflict at point."
  (interactive)
  (magit2-call-smerge #'smerge-keep-current))

(defun magit2-smerge-keep-upper ()
  "Keep the upper/our version of the conflict at point."
  (interactive)
  (magit2-call-smerge #'smerge-keep-upper))

(defun magit2-smerge-keep-base ()
  "Keep the base version of the conflict at point."
  (interactive)
  (magit2-call-smerge #'smerge-keep-base))

(defun magit2-smerge-keep-lower ()
  "Keep the lower/their version of the conflict at point."
  (interactive)
  (magit2-call-smerge #'smerge-keep-lower))

(defun magit2-call-smerge (fn)
  (pcase-let* ((file (magit2-file-at-point t t))
               (keep (get-file-buffer file))
               (`(,buf ,pos)
                (let ((magit2-diff-visit-jump-to-change nil))
                  (magit2-diff-visit-file--noselect file))))
    (with-current-buffer buf
      (save-excursion
        (save-restriction
          (unless (<= (point-min) pos (point-max))
            (widen))
          (goto-char pos)
          (condition-case nil
              (smerge-match-conflict)
            (error
             (if (eq fn 'smerge-keep-current)
                 (when (eq this-command 'magit2-discard)
                   (re-search-forward smerge-begin-re nil t)
                   (setq fn
                         (magit2-read-char-case "Keep side: " t
                           (?o "[o]urs/upper"   #'smerge-keep-upper)
                           (?b "[b]ase"         #'smerge-keep-base)
                           (?t "[t]heirs/lower" #'smerge-keep-lower))))
               (re-search-forward smerge-begin-re nil t))))
          (funcall fn)))
      (when (and keep (magit2-anything-unmerged-p file))
        (smerge-start-session))
      (save-buffer))
    (unless keep
      (kill-buffer buf))
    (magit2-refresh)))

;;; _
(provide 'magit2-apply)
;;; magit2-apply.el ends here
