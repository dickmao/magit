;;; magit2-ediff.el --- Ediff extension for Magit  -*- lexical-binding: t -*-

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

;; This library provides basic support for Ediff.

;;; Code:

(require 'magit2)

(require 'ediff)
(require 'smerge-mode)

(defvar smerge-ediff-buf)
(defvar smerge-ediff-windows)

;;; Options

(defgroup magit2-ediff nil
  "Ediff support for Magit."
  :link '(info-link "(magit2)Ediffing")
  :group 'magit2-extensions)

(defcustom magit2-ediff-quit-hook
  '(magit2-ediff-cleanup-auxiliary-buffers
    magit2-ediff-restore-previous-winconf)
  "Hooks to run after finishing Ediff, when that was invoked using Magit.
The hooks are run in the Ediff control buffer.  This is similar
to `ediff-quit-hook' but takes the needs of Magit into account.
The `ediff-quit-hook' is ignored by Ediff sessions which were
invoked using Magit."
  :package-version '(magit2 . "2.2.0")
  :group 'magit2-ediff
  :type 'hook
  :get 'magit2-hook-custom-get
  :options '(magit2-ediff-cleanup-auxiliary-buffers
             magit2-ediff-restore-previous-winconf))

(defcustom magit2-ediff-dwim-show-on-hunks nil
  "Whether `magit2-ediff-dwim' runs show variants on hunks.
If non-nil, `magit2-ediff-show-staged' or
`magit2-ediff-show-unstaged' are called based on what section the
hunk is in.  Otherwise, `magit2-ediff-dwim' runs
`magit2-ediff-stage' when point is on an uncommitted hunk."
  :package-version '(magit2 . "2.2.0")
  :group 'magit2-ediff
  :type 'boolean)

(defcustom magit2-ediff-show-stash-with-index t
  "Whether `magit2-ediff-show-stash' shows the state of the index.

If non-nil, use a third Ediff buffer to distinguish which changes
in the stash were staged.  In cases where the stash contains no
staged changes, fall back to a two-buffer Ediff.

More specifically, a stash is a merge commit, stash@{N}, with
potentially three parents.

* stash@{N}^1 represents the `HEAD' commit at the time the stash
  was created.

* stash@{N}^2 records any changes that were staged when the stash
  was made.

* stash@{N}^3, if it exists, contains files that were untracked
  when stashing.

If this option is non-nil, `magit2-ediff-show-stash' will run
Ediff on a file using three buffers: one for stash@{N}, another
for stash@{N}^1, and a third for stash@{N}^2.

Otherwise, Ediff uses two buffers, comparing
stash@{N}^1..stash@{N}.  Along with any unstaged changes, changes
in the index commit, stash@{N}^2, will be shown in this
comparison unless they conflicted with changes in the working
tree at the time of stashing."
  :package-version '(magit2 . "2.6.0")
  :group 'magit2-ediff
  :type 'boolean)

(defcustom magit2-ediff-use-indirect-buffers nil
  "Whether to use indirect buffers."
  :package-version '(magit2 . "3.1.0")
  :group 'magit2-ediff
  :type 'boolean)

;;; Commands

(defvar magit2-ediff-previous-winconf nil)

;;;###autoload (autoload 'magit2-ediff "magit2-ediff" nil)
(transient-define-prefix magit2-ediff ()
  "Show differences using the Ediff package."
  :info-manual "(ediff)"
  ["Ediff"
   [("E" "Dwim"          magit2-ediff-dwim)
    ("s" "Stage"         magit2-ediff-stage)
    ("m" "Resolve"       magit2-ediff-resolve)
    ("t" "Resolve using mergetool" magit2-git-mergetool)]
   [("u" "Show unstaged" magit2-ediff-show-unstaged)
    ("i" "Show staged"   magit2-ediff-show-staged)
    ("w" "Show worktree" magit2-ediff-show-working-tree)]
   [("c" "Show commit"   magit2-ediff-show-commit)
    ("r" "Show range"    magit2-ediff-compare)
    ("z" "Show stash"    magit2-ediff-show-stash)]])

;;;###autoload
(defun magit2-ediff-resolve (file)
  "Resolve outstanding conflicts in FILE using Ediff.
FILE has to be relative to the top directory of the repository.

In the rare event that you want to manually resolve all
conflicts, including those already resolved by Git, use
`ediff-merge-revisions-with-ancestor'."
  (interactive (list (magit2-read-unmerged-file)))
  (magit2-with-toplevel
    (with-current-buffer (find-file-noselect file)
      (smerge-ediff)
      (setq-local
       ediff-quit-hook
       (lambda ()
         (let ((bufC ediff-buffer-C)
               (bufS smerge-ediff-buf))
           (with-current-buffer bufS
             (when (yes-or-no-p (format "Conflict resolution finished; save %s? "
                                        buffer-file-name))
               (erase-buffer)
               (insert-buffer-substring bufC)
               (save-buffer))))
         (when (buffer-live-p ediff-buffer-A) (kill-buffer ediff-buffer-A))
         (when (buffer-live-p ediff-buffer-B) (kill-buffer ediff-buffer-B))
         (when (buffer-live-p ediff-buffer-C) (kill-buffer ediff-buffer-C))
         (when (buffer-live-p ediff-ancestor-buffer)
           (kill-buffer ediff-ancestor-buffer))
         (let ((magit2-ediff-previous-winconf smerge-ediff-windows))
           (run-hooks 'magit2-ediff-quit-hook)))))))

(defmacro magit2-ediff-buffers (quit &rest spec)
  (declare (indent 1))
  (let ((fn (if (= (length spec) 3) 'ediff-buffers3 'ediff-buffers))
        (char ?@)
        get make kill)
    (pcase-dolist (`(,g ,m) spec)
      (let ((b (intern (format "buf%c" (cl-incf char)))))
        (push `(,b ,g) get)
        (push `(if ,b
                   (if magit2-ediff-use-indirect-buffers
                       (prog1
                           (make-indirect-buffer
                            ,b (generate-new-buffer-name (buffer-name ,b)) t)
                         (setq ,b nil))
                     ,b)
                 ,m)
              make)
        (push `(unless ,b
                 (ediff-kill-buffer-carefully
                  ,(intern (format "ediff-buffer-%c" char))))
              kill)))
    (setq get  (nreverse get))
    (setq make (nreverse make))
    (setq kill (nreverse kill))
    `(magit2-with-toplevel
       (let ((conf (current-window-configuration))
             ,@get)
         (,fn
          ,@make
          (list (lambda ()
                  (setq-local
                   ediff-quit-hook
                   (list ,@(and quit (list quit))
                         (lambda ()
                           ,@kill
                           (let ((magit2-ediff-previous-winconf conf))
                             (run-hooks 'magit2-ediff-quit-hook)))))))
          ',fn)))))

;;;###autoload
(defun magit2-ediff-stage (file)
  "Stage and unstage changes to FILE using Ediff.
FILE has to be relative to the top directory of the repository."
  (interactive
   (let ((files (magit2-tracked-files)))
     (list (magit2-completing-read "Selectively stage file" files nil t nil nil
                                  (car (member (magit2-current-file) files))))))
  (magit2-with-toplevel
    (let* ((bufA  (magit2-get-revision-buffer "HEAD" file))
           (bufB  (magit2-get-revision-buffer "{index}" file))
           (lockB (and bufB (buffer-local-value 'buffer-read-only bufB)))
           (bufC  (get-file-buffer file))
           ;; Use the same encoding for all three buffers or we
           ;; may end up changing the file in an unintended way.
           (bufC* (or bufC (find-file-noselect file)))
           (coding-system-for-read
            (buffer-local-value 'buffer-file-coding-system bufC*))
           (bufA* (magit2-find-file-noselect-1 "HEAD" file t))
           (bufB* (magit2-find-file-index-noselect file t)))
      (setf (buffer-local-value 'buffer-read-only bufB*) nil)
      (magit2-ediff-buffers
          (lambda ()
            (when (buffer-live-p ediff-buffer-B)
              (when lockB
                (setf (buffer-local-value 'buffer-read-only bufB) t))
              (when (buffer-modified-p ediff-buffer-B)
                (with-current-buffer ediff-buffer-B
                  (magit2-update-index))))
            (when (and (buffer-live-p ediff-buffer-C)
                       (buffer-modified-p ediff-buffer-C))
              (with-current-buffer ediff-buffer-C
                (when (y-or-n-p (format "Save file %s? " buffer-file-name))
                  (save-buffer)))))
        (bufA bufA*)
        (bufB bufB*)
        (bufC bufC*)))))

;;;###autoload
(defun magit2-ediff-compare (revA revB fileA fileB)
  "Compare REVA:FILEA with REVB:FILEB using Ediff.

FILEA and FILEB have to be relative to the top directory of the
repository.  If REVA or REVB is nil, then this stands for the
working tree state.

If the region is active, use the revisions on the first and last
line of the region.  With a prefix argument, instead of diffing
the revisions, choose a revision to view changes along, starting
at the common ancestor of both revisions (i.e., use a \"...\"
range)."
  (interactive
   (pcase-let ((`(,revA ,revB) (magit2-ediff-compare--read-revisions
                                nil current-prefix-arg)))
     (nconc (list revA revB)
            (magit2-ediff-read-files revA revB))))
  (magit2-ediff-buffers nil
    ((if revA (magit2-get-revision-buffer revA fileA) (get-file-buffer    fileA))
     (if revA (magit2-find-file-noselect  revA fileA) (find-file-noselect fileA)))
    ((if revB (magit2-get-revision-buffer revB fileB) (get-file-buffer    fileB))
     (if revB (magit2-find-file-noselect  revB fileB) (find-file-noselect fileB)))))

(defun magit2-ediff-compare--read-revisions (&optional arg mbase)
  (let ((input (or arg (magit2-diff-read-range-or-commit
                        "Compare range or commit"
                        nil mbase))))
    (--if-let (magit2-split-range input)
        (-cons-to-list it)
      (list input nil))))

(defun magit2-ediff-read-files (revA revB &optional fileB)
  "Read file in REVB, return it and the corresponding file in REVA.
When FILEB is non-nil, use this as REVB's file instead of
prompting for it."
  (unless fileB
    (setq fileB (magit2-read-file-choice
                 (format "File to compare between %s and %s"
                         revA (or revB "the working tree"))
                 (magit2-changed-files revA revB)
                 (format "No changed files between %s and %s"
                         revA (or revB "the working tree")))))
  (list (or (car (member fileB (magit2-revision-files revA)))
            (cdr (assoc fileB (magit2-renamed-files revB revA)))
            (magit2-read-file-choice
             (format "File in %s to compare with %s in %s"
                     revA fileB (or revB "the working tree"))
             (magit2-changed-files revB revA)
             (format "No files have changed between %s and %s"
                     revA revB)))
        fileB))

;;;###autoload
(defun magit2-ediff-dwim ()
  "Compare, stage, or resolve using Ediff.
This command tries to guess what file, and what commit or range
the user wants to compare, stage, or resolve using Ediff.  It
might only be able to guess either the file, or range or commit,
in which case the user is asked about the other.  It might not
always guess right, in which case the appropriate `magit2-ediff-*'
command has to be used explicitly.  If it cannot read the user's
mind at all, then it asks the user for a command to run."
  (interactive)
  (magit2-section-case
    (hunk (save-excursion
            (goto-char (oref (oref it parent) start))
            (magit2-ediff-dwim)))
    (t
     (let ((range (magit2-diff--dwim))
           (file (magit2-current-file))
           command revA revB)
       (pcase range
         ((and (guard (not magit2-ediff-dwim-show-on-hunks))
               (or `unstaged `staged))
          (setq command (if (magit2-anything-unmerged-p)
                            #'magit2-ediff-resolve
                          #'magit2-ediff-stage)))
         (`unstaged (setq command #'magit2-ediff-show-unstaged))
         (`staged (setq command #'magit2-ediff-show-staged))
         (`(commit . ,value)
          (setq command #'magit2-ediff-show-commit)
          (setq revB value))
         (`(stash . ,value)
          (setq command #'magit2-ediff-show-stash)
          (setq revB value))
         ((pred stringp)
          (pcase-let ((`(,a ,b) (magit2-ediff-compare--read-revisions range)))
            (setq command #'magit2-ediff-compare)
            (setq revA a)
            (setq revB b)))
         (_
          (when (derived-mode-p 'magit2-diff-mode)
            (pcase (magit2-diff-type)
              (`committed (pcase-let ((`(,a ,b)
                                       (magit2-ediff-compare--read-revisions
                                        magit2-buffer-range)))
                            (setq revA a)
                            (setq revB b)))
              ((guard (not magit2-ediff-dwim-show-on-hunks))
               (setq command #'magit2-ediff-stage))
              (`unstaged  (setq command #'magit2-ediff-show-unstaged))
              (`staged    (setq command #'magit2-ediff-show-staged))
              (`undefined (setq command nil))
              (_          (setq command nil))))))
       (cond ((not command)
              (call-interactively
               (magit2-read-char-case
                   "Failed to read your mind; do you want to " t
                 (?c "[c]ommit"  'magit2-ediff-show-commit)
                 (?r "[r]ange"   'magit2-ediff-compare)
                 (?s "[s]tage"   'magit2-ediff-stage)
                 (?v "resol[v]e" 'magit2-ediff-resolve))))
             ((eq command 'magit2-ediff-compare)
              (apply 'magit2-ediff-compare revA revB
                     (magit2-ediff-read-files revA revB file)))
             ((eq command 'magit2-ediff-show-commit)
              (magit2-ediff-show-commit revB))
             ((eq command 'magit2-ediff-show-stash)
              (magit2-ediff-show-stash revB))
             (file
              (funcall command file))
             (t
              (call-interactively command)))))))

;;;###autoload
(defun magit2-ediff-show-staged (file)
  "Show staged changes using Ediff.

This only allows looking at the changes; to stage, unstage,
and discard changes using Ediff, use `magit2-ediff-stage'.

FILE must be relative to the top directory of the repository."
  (interactive
   (list (magit2-read-file-choice "Show staged changes for file"
                                 (magit2-staged-files)
                                 "No staged files")))
  (magit2-ediff-buffers nil
    ((magit2-get-revision-buffer "HEAD" file)
     (magit2-find-file-noselect "HEAD" file))
    ((get-buffer (concat file ".~{index}~"))
     (magit2-find-file-index-noselect file t))))

;;;###autoload
(defun magit2-ediff-show-unstaged (file)
  "Show unstaged changes using Ediff.

This only allows looking at the changes; to stage, unstage,
and discard changes using Ediff, use `magit2-ediff-stage'.

FILE must be relative to the top directory of the repository."
  (interactive
   (list (magit2-read-file-choice "Show unstaged changes for file"
                                 (magit2-unstaged-files)
                                 "No unstaged files")))
  (magit2-ediff-buffers nil
    ((get-buffer (concat file ".~{index}~"))
     (magit2-find-file-index-noselect file t))
    ((get-file-buffer file)
     (find-file-noselect file))))

;;;###autoload
(defun magit2-ediff-show-working-tree (file)
  "Show changes between `HEAD' and working tree using Ediff.
FILE must be relative to the top directory of the repository."
  (interactive
   (list (magit2-read-file-choice "Show changes in file"
                                 (magit2-changed-files "HEAD")
                                 "No changed files")))
  (magit2-ediff-buffers nil
    ((magit2-get-revision-buffer "HEAD" file)
     (magit2-find-file-noselect  "HEAD" file))
    ((get-file-buffer file)
     (find-file-noselect file))))

;;;###autoload
(defun magit2-ediff-show-commit (commit)
  "Show changes introduced by COMMIT using Ediff."
  (interactive (list (magit2-read-branch-or-commit "Revision")))
  (let ((revA (concat commit "^"))
        (revB commit))
    (apply #'magit2-ediff-compare
           revA revB
           (magit2-ediff-read-files revA revB (magit2-current-file)))))

;;;###autoload
(defun magit2-ediff-show-stash (stash)
  "Show changes introduced by STASH using Ediff.
`magit2-ediff-show-stash-with-index' controls whether a
three-buffer Ediff is used in order to distinguish changes in the
stash that were staged."
  (interactive (list (magit2-read-stash "Stash")))
  (pcase-let* ((revA (concat stash "^1"))
               (revB (concat stash "^2"))
               (revC stash)
               (`(,fileA ,fileC) (magit2-ediff-read-files revA revC))
               (fileB fileC))
    (if (and magit2-ediff-show-stash-with-index
             (member fileA (magit2-changed-files revB revA)))
        (magit2-ediff-buffers nil
          ((magit2-get-revision-buffer revA fileA)
           (magit2-find-file-noselect  revA fileA))
          ((magit2-get-revision-buffer revB fileB)
           (magit2-find-file-noselect  revB fileB))
          ((magit2-get-revision-buffer revC fileC)
           (magit2-find-file-noselect  revC fileC)))
      (magit2-ediff-compare revA revC fileA fileC))))

(defun magit2-ediff-cleanup-auxiliary-buffers ()
  (let* ((ctl-buf ediff-control-buffer)
         (ctl-win (ediff-get-visible-buffer-window ctl-buf))
         (ctl-frm ediff-control-frame)
         (main-frame (cond ((window-live-p ediff-window-A)
                            (window-frame ediff-window-A))
                           ((window-live-p ediff-window-B)
                            (window-frame ediff-window-B)))))
    (ediff-kill-buffer-carefully ediff-diff-buffer)
    (ediff-kill-buffer-carefully ediff-custom-diff-buffer)
    (ediff-kill-buffer-carefully ediff-fine-diff-buffer)
    (ediff-kill-buffer-carefully ediff-tmp-buffer)
    (ediff-kill-buffer-carefully ediff-error-buffer)
    (ediff-kill-buffer-carefully ediff-msg-buffer)
    (ediff-kill-buffer-carefully ediff-debug-buffer)
    (when (boundp 'ediff-patch-diagnostics)
      (ediff-kill-buffer-carefully ediff-patch-diagnostics))
    (cond ((and (ediff-window-display-p)
                (frame-live-p ctl-frm))
           (delete-frame ctl-frm))
          ((window-live-p ctl-win)
           (delete-window ctl-win)))
    (ediff-kill-buffer-carefully ctl-buf)
    (when (frame-live-p main-frame)
      (select-frame main-frame))))

(defun magit2-ediff-restore-previous-winconf ()
  (set-window-configuration magit2-ediff-previous-winconf))

;;; _
(provide 'magit2-ediff)
;;; magit2-ediff.el ends here
