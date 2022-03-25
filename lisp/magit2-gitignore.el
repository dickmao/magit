;;; magit2-gitignore.el --- intentionally untracked files  -*- lexical-binding: t -*-

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

;; This library implements gitignore commands.

;;; Code:

(require 'magit2)

;;; Transient

;;;###autoload (autoload 'magit2-gitignore "magit2-gitignore" nil t)
(transient-define-prefix magit2-gitignore ()
  "Instruct Git to ignore a file or pattern."
  :man-page "gitignore"
  ["Gitignore"
   ("t" "shared at toplevel (.gitignore)"
    magit2-gitignore-in-topdir)
   ("s" "shared in subdirectory (path/to/.gitignore)"
    magit2-gitignore-in-subdir)
   ("p" "privately (.git/info/exclude)"
    magit2-gitignore-in-gitdir)
   ("g" magit2-gitignore-on-system
    :if (lambda () (magit2-get "core.excludesfile"))
    :description (lambda ()
                   (format "privately for all repositories (%s)"
                           (magit2-get "core.excludesfile"))))]
  ["Skip worktree"
   (7 "w" "do skip worktree"     magit2-skip-worktree)
   (7 "W" "do not skip worktree" magit2-no-skip-worktree)]
  ["Assume unchanged"
   (7 "u" "do assume unchanged"     magit2-assume-unchanged)
   (7 "U" "do not assume unchanged" magit2-no-assume-unchanged)])

;;; Gitignore Commands

;;;###autoload
(defun magit2-gitignore-in-topdir (rule)
  "Add the Git ignore RULE to the top-level \".gitignore\" file.
Since this file is tracked, it is shared with other clones of the
repository.  Also stage the file."
  (interactive (list (magit2-gitignore-read-pattern)))
  (magit2-with-toplevel
    (magit2--gitignore rule ".gitignore")
    (magit2-run-git "add" ".gitignore")))

;;;###autoload
(defun magit2-gitignore-in-subdir (rule directory)
  "Add the Git ignore RULE to a \".gitignore\" file in DIRECTORY.
Prompt the user for a directory and add the rule to the
\".gitignore\" file in that directory.  Since such files are
tracked, they are shared with other clones of the repository.
Also stage the file."
  (interactive (list (magit2-gitignore-read-pattern)
                     (read-directory-name "Limit rule to files in: ")))
  (magit2-with-toplevel
    (let ((file (expand-file-name ".gitignore" directory)))
      (magit2--gitignore rule file)
      (magit2-run-git "add" (magit2-convert-filename-for-git file)))))

;;;###autoload
(defun magit2-gitignore-in-gitdir (rule)
  "Add the Git ignore RULE to \"$GIT_DIR/info/exclude\".
Rules in that file only affects this clone of the repository."
  (interactive (list (magit2-gitignore-read-pattern)))
  (magit2--gitignore rule (magit2-git-dir "info/exclude"))
  (magit2-refresh))

;;;###autoload
(defun magit2-gitignore-on-system (rule)
  "Add the Git ignore RULE to the file specified by `core.excludesFile'.
Rules that are defined in that file affect all local repositories."
  (interactive (list (magit2-gitignore-read-pattern)))
  (magit2--gitignore rule
                    (or (magit2-get "core.excludesFile")
                        (error "Variable `core.excludesFile' isn't set")))
  (magit2-refresh))

(defun magit2--gitignore (rule file)
  (when-let ((directory (file-name-directory file)))
    (make-directory directory t))
  (with-temp-buffer
    (when (file-exists-p file)
      (insert-file-contents file))
    (goto-char (point-max))
    (unless (bolp)
      (insert "\n"))
    (insert (replace-regexp-in-string "\\(\\\\*\\)" "\\1\\1" rule))
    (insert "\n")
    (write-region nil nil file)))

(defun magit2-gitignore-read-pattern ()
  (let* ((default (magit2-current-file))
         (base (car magit2-buffer-diff-files))
         (base (and base (file-directory-p base) base))
         (choices
          (delete-dups
           (--mapcat
            (cons (concat "/" it)
                  (when-let ((ext (file-name-extension it)))
                    (list (concat "/" (file-name-directory it) "*." ext)
                          (concat "*." ext))))
            (sort (nconc
                   (magit2-untracked-files nil base)
                   ;; The untracked section of the status buffer lists
                   ;; directories containing only untracked files.
                   ;; Add those as candidates.
                   (-filter #'directory-name-p
                            (magit2-list-files
                             "--other" "--exclude-standard" "--directory"
                             "--no-empty-directory" "--" base)))
                  #'string-lessp)))))
    (when default
      (setq default (concat "/" default))
      (unless (member default choices)
        (setq default (concat "*." (file-name-extension default)))
        (unless (member default choices)
          (setq default nil))))
    (magit2-completing-read "File or pattern to ignore"
                           choices nil nil nil nil default)))

;;; Skip Worktree Commands

;;;###autoload
(defun magit2-skip-worktree (file)
  "Call \"git update-index --skip-worktree -- FILE\"."
  (interactive
   (list (magit2-read-file-choice "Skip worktree for"
                                 (magit2-with-toplevel
                                   (cl-set-difference
                                    (magit2-list-files)
                                    (magit2-skip-worktree-files)
                                    :test #'equal)))))
  (magit2-with-toplevel
    (magit2-run-git "update-index" "--skip-worktree" "--" file)))

;;;###autoload
(defun magit2-no-skip-worktree (file)
  "Call \"git update-index --no-skip-worktree -- FILE\"."
  (interactive
   (list (magit2-read-file-choice "Do not skip worktree for"
                                 (magit2-with-toplevel
                                   (magit2-skip-worktree-files)))))
  (magit2-with-toplevel
    (magit2-run-git "update-index" "--no-skip-worktree" "--" file)))

;;; Assume Unchanged Commands

;;;###autoload
(defun magit2-assume-unchanged (file)
  "Call \"git update-index --assume-unchanged -- FILE\"."
  (interactive
   (list (magit2-read-file-choice "Assume file to be unchanged"
                                 (magit2-with-toplevel
                                   (cl-set-difference
                                    (magit2-list-files)
                                    (magit2-assume-unchanged-files)
                                    :test #'equal)))))
  (magit2-with-toplevel
    (magit2-run-git "update-index" "--assume-unchanged" "--" file)))

;;;###autoload
(defun magit2-no-assume-unchanged (file)
  "Call \"git update-index --no-assume-unchanged -- FILE\"."
  (interactive
   (list (magit2-read-file-choice "Do not assume file to be unchanged"
                                 (magit2-with-toplevel
                                   (magit2-assume-unchanged-files)))))
  (magit2-with-toplevel
    (magit2-run-git "update-index" "--no-assume-unchanged" "--" file)))

;;; _
(provide 'magit2-gitignore)
;;; magit2-gitignore.el ends here
