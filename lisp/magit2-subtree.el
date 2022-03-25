;;; magit2-subtree.el --- subtree support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2011-2022  The Magit Project Contributors
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

;;; Code:

(require 'magit2)

;;; Commands

;;;###autoload (autoload 'magit2-subtree "magit2-subtree" nil t)
(transient-define-prefix magit2-subtree ()
  "Import or export subtrees."
  :man-page "git-subtree"
  ["Actions"
   ("i" "Import" magit2-subtree-import)
   ("e" "Export" magit2-subtree-export)])

;;;###autoload (autoload 'magit2-subtree-import "magit2-subtree" nil t)
(transient-define-prefix magit2-subtree-import ()
  "Import subtrees."
  :man-page "git-subtree"
  ["Arguments"
   (magit2-subtree:--prefix)
   (magit2-subtree:--message)
   ("-s" "Squash" "--squash")]
  ["Actions"
   [("a" "Add"        magit2-subtree-add)
    ("c" "Add commit" magit2-subtree-add-commit)]
   [("m" "Merge"      magit2-subtree-merge)
    ("f" "Pull"       magit2-subtree-pull)]])

;;;###autoload (autoload 'magit2-subtree-export "magit2-subtree" nil t)
(transient-define-prefix magit2-subtree-export ()
  "Export subtrees."
  :man-page "git-subtree"
  ["Arguments"
   (magit2-subtree:--prefix)
   (magit2-subtree:--annotate)
   (magit2-subtree:--branch)
   (magit2-subtree:--onto)
   ("-i" "Ignore joins" "--ignore-joins")
   ("-j" "Rejoin"       "--rejoin")]
  ["Actions"
   ("p" "Push"          magit2-subtree-push)
   ("s" "Split"         magit2-subtree-split)])

(transient-define-argument magit2-subtree:--prefix ()
  :description "Prefix"
  :class 'transient-option
  :shortarg "-P"
  :argument "--prefix="
  :reader 'magit2-subtree-read-prefix)

(defun magit2-subtree-read-prefix (prompt &optional default _history)
  (let* ((insert-default-directory nil)
         (topdir (magit2-toplevel))
         (prefix (read-directory-name (concat prompt ": ") topdir default)))
    (if (file-name-absolute-p prefix)
        ;; At least `ido-mode's variant is not compatible.
        (if (string-prefix-p topdir prefix)
            (file-relative-name prefix topdir)
          (user-error "%s isn't inside the repository at %s" prefix topdir))
      prefix)))

(transient-define-argument magit2-subtree:--message ()
  :description "Message"
  :class 'transient-option
  :shortarg "-m"
  :argument "--message=")

(transient-define-argument magit2-subtree:--annotate ()
  :description "Annotate"
  :class 'transient-option
  :key "-a"
  :argument "--annotate=")

(transient-define-argument magit2-subtree:--branch ()
  :description "Branch"
  :class 'transient-option
  :shortarg "-b"
  :argument "--branch=")

(transient-define-argument magit2-subtree:--onto ()
  :description "Onto"
  :class 'transient-option
  :key "-o"
  :argument "--onto="
  :reader 'magit2-transient-read-revision)

(defun magit2-subtree-prefix (transient prompt)
  (--if-let (--first (string-prefix-p "--prefix=" it)
                     (transient-args transient))
      (substring it 9)
    (magit2-subtree-read-prefix prompt)))

(defun magit2-subtree-arguments (transient)
  (--remove (string-prefix-p "--prefix=" it)
            (transient-args transient)))

(defun magit2-git-subtree (subcmd prefix &rest args)
  (magit2-run-git-async "subtree" subcmd (concat "--prefix=" prefix) args))

;;;###autoload
(defun magit2-subtree-add (prefix repository ref args)
  "Add REF from REPOSITORY as a new subtree at PREFIX."
  (interactive
   (cons (magit2-subtree-prefix 'magit2-subtree-import "Add subtree")
         (let ((remote (magit2-read-remote-or-url "From repository")))
           (list remote
                 (magit2-read-refspec "Ref" remote)
                 (magit2-subtree-arguments 'magit2-subtree-import)))))
  (magit2-git-subtree "add" prefix args repository ref))

;;;###autoload
(defun magit2-subtree-add-commit (prefix commit args)
  "Add COMMIT as a new subtree at PREFIX."
  (interactive
   (list (magit2-subtree-prefix 'magit2-subtree-import "Add subtree")
         (magit2-read-string-ns "Commit")
         (magit2-subtree-arguments 'magit2-subtree-import)))
  (magit2-git-subtree "add" prefix args commit))

;;;###autoload
(defun magit2-subtree-merge (prefix commit args)
  "Merge COMMIT into the PREFIX subtree."
  (interactive
   (list (magit2-subtree-prefix 'magit2-subtree-import "Merge into subtree")
         (magit2-read-string-ns "Commit")
         (magit2-subtree-arguments 'magit2-subtree-import)))
  (magit2-git-subtree "merge" prefix args commit))

;;;###autoload
(defun magit2-subtree-pull (prefix repository ref args)
  "Pull REF from REPOSITORY into the PREFIX subtree."
  (interactive
   (cons (magit2-subtree-prefix 'magit2-subtree-import "Pull into subtree")
         (let ((remote (magit2-read-remote-or-url "From repository")))
           (list remote
                 (magit2-read-refspec "Ref" remote)
                 (magit2-subtree-arguments 'magit2-subtree-import)))))
  (magit2-git-subtree "pull" prefix args repository ref))

;;;###autoload
(defun magit2-subtree-push (prefix repository ref args)
  "Extract the history of the subtree PREFIX and push it to REF on REPOSITORY."
  (interactive (list (magit2-subtree-prefix 'magit2-subtree-export "Push subtree")
                     (magit2-read-remote-or-url "To repository")
                     (magit2-read-string-ns "To reference")
                     (magit2-subtree-arguments 'magit2-subtree-export)))
  (magit2-git-subtree "push" prefix args repository ref))

;;;###autoload
(defun magit2-subtree-split (prefix commit args)
  "Extract the history of the subtree PREFIX."
  (interactive (list (magit2-subtree-prefix 'magit2-subtree-export "Split subtree")
                     (magit2-read-string-ns "Commit")
                     (magit2-subtree-arguments 'magit2-subtree-export)))
  (magit2-git-subtree "split" prefix args commit))

;;; _
(provide 'magit2-subtree)
;;; magit2-subtree.el ends here
