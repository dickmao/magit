;;; magit2-worktree.el --- worktree support  -*- lexical-binding: t -*-

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

;; This library implements support for `git-worktree'.

;;; Code:

(require 'magit2)

;;; Options

(defcustom magit2-worktree-read-directory-name-function 'read-directory-name
  "Function used to read a directory for worktree commands.
This is called with one argument, the prompt, and can be used
to e.g. use a base directory other than `default-directory'.
Used by `magit2-worktree-checkout' and `magit2-worktree-branch'."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-commands
  :type 'function)

;;; Commands

;;;###autoload (autoload 'magit2-worktree "magit2-worktree" nil t)
(transient-define-prefix magit2-worktree ()
  "Act on a worktree."
  :man-page "git-worktree"
  [["Create new"
    ("b" "worktree"              magit2-worktree-checkout)
    ("c" "branch and worktree"   magit2-worktree-branch)]
   ["Commands"
    ("m" "Move worktree"         magit2-worktree-move)
    ("k" "Delete worktree"       magit2-worktree-delete)
    ("g" "Visit worktree"        magit2-worktree-status)]])

;;;###autoload
(defun magit2-worktree-checkout (path branch)
  "Checkout BRANCH in a new worktree at PATH."
  (interactive
   (let ((branch (magit2-read-branch-or-commit "Checkout")))
     (list (funcall magit2-worktree-read-directory-name-function
                    (format "Checkout %s in new worktree: " branch))
           branch)))
  (magit2-run-git "worktree" "add" (magit2--expand-worktree path) branch)
  (magit2-diff-visit-directory path))

;;;###autoload
(defun magit2-worktree-branch (path branch start-point &optional force)
  "Create a new BRANCH and check it out in a new worktree at PATH."
  (interactive
   `(,(funcall magit2-worktree-read-directory-name-function
               "Create worktree: ")
     ,@(magit2-branch-read-args "Create and checkout branch")
     ,current-prefix-arg))
  (magit2-run-git "worktree" "add" (if force "-B" "-b")
                 branch (magit2--expand-worktree path) start-point)
  (magit2-diff-visit-directory path))

;;;###autoload
(defun magit2-worktree-move (worktree path)
  "Move WORKTREE to PATH."
  (interactive
   (list (magit2-completing-read "Move worktree"
                                (cdr (magit2-list-worktrees))
                                nil t nil nil
                                (magit2-section-value-if 'worktree))
         (funcall magit2-worktree-read-directory-name-function
                  "Move worktree to: ")))
  (if (file-directory-p (expand-file-name ".git" worktree))
      (user-error "You may not move the main working tree")
    (let ((preexisting-directory (file-directory-p path)))
      (when (and (zerop (magit2-call-git "worktree" "move" worktree
                                        (magit2--expand-worktree path)))
                 (not (file-exists-p default-directory))
                 (derived-mode-p 'magit2-status-mode))
        (kill-buffer)
        (magit2-diff-visit-directory
         (if preexisting-directory
             (concat (file-name-as-directory path)
                     (file-name-nondirectory worktree))
           path)))
      (magit2-refresh))))

(defun magit2-worktree-delete (worktree)
  "Delete a worktree, defaulting to the worktree at point.
The primary worktree cannot be deleted."
  (interactive
   (list (magit2-completing-read "Delete worktree"
                                (cdr (magit2-list-worktrees))
                                nil t nil nil
                                (magit2-section-value-if 'worktree))))
  (if (file-directory-p (expand-file-name ".git" worktree))
      (user-error "Deleting %s would delete the shared .git directory" worktree)
    (let ((primary (file-name-as-directory (caar (magit2-list-worktrees)))))
      (magit2-confirm-files (if magit2-delete-by-moving-to-trash 'trash 'delete)
                           (list "worktree"))
      (when (file-exists-p worktree)
        (let ((delete-by-moving-to-trash magit2-delete-by-moving-to-trash))
          (delete-directory worktree t magit2-delete-by-moving-to-trash)))
      (if (file-exists-p default-directory)
          (magit2-run-git "worktree" "prune")
        (let ((default-directory primary))
          (magit2-run-git "worktree" "prune"))
        (when (derived-mode-p 'magit2-status-mode)
          (kill-buffer)
          (magit2-status-setup-buffer primary))))))

(defun magit2-worktree-status (worktree)
  "Show the status for the worktree at point.
If there is no worktree at point, then read one in the
minibuffer.  If the worktree at point is the one whose
status is already being displayed in the current buffer,
then show it in Dired instead."
  (interactive
   (list (or (magit2-section-value-if 'worktree)
             (magit2-completing-read
              "Show status for worktree"
              (cl-delete (directory-file-name (magit2-toplevel))
                         (magit2-list-worktrees)
                         :test #'equal :key #'car)))))
  (magit2-diff-visit-directory worktree))

(defun magit2--expand-worktree (path)
  (magit2-convert-filename-for-git (expand-file-name path)))

;;; Sections

(defvar magit2-worktree-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing]  'magit2-worktree-status)
    (define-key map [remap magit2-delete-thing] 'magit2-worktree-delete)
    map)
  "Keymap for `worktree' sections.")

(defun magit2-insert-worktrees ()
  "Insert sections for all worktrees.
If there is only one worktree, then insert nothing."
  (let ((worktrees (magit2-list-worktrees)))
    (when (> (length worktrees) 1)
      (magit2-insert-section (worktrees)
        (magit2-insert-heading "Worktrees:")
        (let* ((cols
                (mapcar
                 (pcase-lambda (`(,path ,barep ,commit ,branch))
                   (cons (cond
                          (branch (propertize
                                   branch 'font-lock-face
                                   (if (equal branch (magit2-get-current-branch))
                                       'magit2-branch-current
                                     'magit2-branch-local)))
                          (commit (propertize (magit2-rev-abbrev commit)
                                              'font-lock-face 'magit2-hash))
                          (barep  "(bare)"))
                         path))
                 worktrees))
               (align (1+ (-max (--map (string-width (car it)) cols)))))
          (pcase-dolist (`(,head . ,path) cols)
            (magit2-insert-section (worktree path)
              (insert head)
              (insert (make-string (- align (length head)) ?\s))
              (insert (let ((r (file-relative-name path))
                            (a (abbreviate-file-name path)))
                        (if (< (string-width r) (string-width a)) r a)))
              (insert ?\n))))
        (insert ?\n)))))

;;; _
(provide 'magit2-worktree)
;;; magit2-worktree.el ends here
