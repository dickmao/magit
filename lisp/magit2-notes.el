;;; magit2-notes.el --- notes support  -*- lexical-binding: t -*-

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

;; This library implements support for `git-notes'.

;;; Code:

(require 'magit2)

;;; Commands

;;;###autoload (autoload 'magit2-notes "magit2" nil t)
(transient-define-prefix magit2-notes ()
  "Edit notes attached to commits."
  :man-page "git-notes"
  ["Configure local settings"
   ("c" magit2-core.notesRef)
   ("d" magit2-notes.displayRef)]
  ["Configure global settings"
   ("C" magit2-global-core.notesRef)
   ("D" magit2-global-notes.displayRef)]
  ["Arguments for prune"
   :if-not magit2-notes-merging-p
   ("-n" "Dry run" ("-n" "--dry-run"))]
  ["Arguments for edit and remove"
   :if-not magit2-notes-merging-p
   (magit2-notes:--ref)]
  ["Arguments for merge"
   :if-not magit2-notes-merging-p
   (magit2-notes:--strategy)]
  ["Actions"
   :if-not magit2-notes-merging-p
   ("T" "Edit"         magit2-notes-edit)
   ("r" "Remove"       magit2-notes-remove)
   ("m" "Merge"        magit2-notes-merge)
   ("p" "Prune"        magit2-notes-prune)]
  ["Actions"
   :if magit2-notes-merging-p
   ("c" "Commit merge" magit2-notes-merge-commit)
   ("a" "Abort merge"  magit2-notes-merge-abort)])

(defun magit2-notes-merging-p ()
  (let ((dir (magit2-git-dir "NOTES_MERGE_WORKTREE")))
    (and (file-directory-p dir)
         (directory-files dir nil "^[^.]"))))

(transient-define-infix magit2-core.notesRef ()
  :class 'magit2--git-variable
  :variable "core.notesRef"
  :reader 'magit2-notes-read-ref
  :prompt "Set local core.notesRef")

(transient-define-infix magit2-notes.displayRef ()
  :class 'magit2--git-variable
  :variable "notes.displayRef"
  :multi-value t
  :reader 'magit2-notes-read-refs
  :prompt "Set local notes.displayRef")

(transient-define-infix magit2-global-core.notesRef ()
  :class 'magit2--git-variable
  :variable "core.notesRef"
  :global t
  :reader 'magit2-notes-read-ref
  :prompt "Set global core.notesRef")

(transient-define-infix magit2-global-notes.displayRef ()
  :class 'magit2--git-variable
  :variable "notes.displayRef"
  :global t
  :multi-value t
  :reader 'magit2-notes-read-refs
  :prompt "Set global notes.displayRef")

(transient-define-argument magit2-notes:--ref ()
  :description "Manipulate ref"
  :class 'transient-option
  :key "-r"
  :argument "--ref="
  :reader 'magit2-notes-read-ref)

(transient-define-argument magit2-notes:--strategy ()
  :description "Merge strategy"
  :class 'transient-option
  :shortarg "-s"
  :argument "--strategy="
  :choices '("manual" "ours" "theirs" "union" "cat_sort_uniq"))

(defun magit2-notes-edit (commit &optional ref)
  "Edit the note attached to COMMIT.
REF is the notes ref used to store the notes.

Interactively or when optional REF is nil use the value of Git
variable `core.notesRef' or \"refs/notes/commits\" if that is
undefined."
  (interactive (magit2-notes-read-args "Edit notes"))
  (magit2-run-git-with-editor "notes" (and ref (concat "--ref=" ref))
                             "edit" commit))

(defun magit2-notes-remove (commit &optional ref)
  "Remove the note attached to COMMIT.
REF is the notes ref from which the note is removed.

Interactively or when optional REF is nil use the value of Git
variable `core.notesRef' or \"refs/notes/commits\" if that is
undefined."
  (interactive (magit2-notes-read-args "Remove notes"))
  (magit2-run-git-with-editor "notes" (and ref (concat "--ref=" ref))
                             "remove" commit))

(defun magit2-notes-merge (ref)
  "Merge the notes ref REF into the current notes ref.

The current notes ref is the value of Git variable
`core.notesRef' or \"refs/notes/commits\" if that is undefined.

When there are conflicts, then they have to be resolved in the
temporary worktree \".git/NOTES_MERGE_WORKTREE\".  When
done use `magit2-notes-merge-commit' to finish.  To abort
use `magit2-notes-merge-abort'."
  (interactive (list (magit2-read-string-ns "Merge reference")))
  (magit2-run-git-with-editor "notes" "merge" ref))

(defun magit2-notes-merge-commit ()
  "Commit the current notes ref merge.
Also see `magit2-notes-merge'."
  (interactive)
  (magit2-run-git-with-editor "notes" "merge" "--commit"))

(defun magit2-notes-merge-abort ()
  "Abort the current notes ref merge.
Also see `magit2-notes-merge'."
  (interactive)
  (magit2-run-git-with-editor "notes" "merge" "--abort"))

(defun magit2-notes-prune (&optional dry-run)
  "Remove notes about unreachable commits."
  (interactive (list (and (member "--dry-run" (transient-args 'magit2-notes)) t)))
  (when dry-run
    (magit2-process-buffer))
  (magit2-run-git-with-editor "notes" "prune" (and dry-run "--dry-run")))

;;; Readers

(defun magit2-notes-read-ref (prompt _initial-input history)
  (--when-let (magit2-completing-read
               prompt (magit2-list-notes-refnames) nil nil
               (--when-let (magit2-get "core.notesRef")
                 (if (string-prefix-p "refs/notes/" it)
                     (substring it 11)
                   it))
               history)
    (if (string-prefix-p "refs/" it)
        it
      (concat "refs/notes/" it))))

(defun magit2-notes-read-refs (prompt &optional _initial-input _history)
  (mapcar (lambda (ref)
            (if (string-prefix-p "refs/" ref)
                ref
              (concat "refs/notes/" ref)))
          (completing-read-multiple
           (concat prompt ": ")
           (magit2-list-notes-refnames) nil nil
           (mapconcat (lambda (ref)
                        (if (string-prefix-p "refs/notes/" ref)
                            (substring ref 11)
                          ref))
                      (magit2-get-all "notes.displayRef")
                      ","))))

(defun magit2-notes-read-args (prompt)
  (list (magit2-read-branch-or-commit prompt (magit2-stash-at-point))
        (--when-let (--first (string-match "^--ref=\\(.+\\)" it)
                             (transient-args 'magit2-notes))
          (match-string 1 it))))

;;; _
(provide 'magit2-notes)
;;; magit2-notes.el ends here
