;;; magit2-sparse-checkout.el --- sparse checkout support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2022  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit2.vc/authors.

;; Author: Kyle Meyer <kyle@kyleam.com>
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

;; This library provides an interface to the `git sparse-checkout'
;; command.  It's been possible to define sparse checkouts since Git
;; v1.7.0 by adding patterns to $GIT_DIR/info/sparse-checkout and
;; calling `git read-tree -mu HEAD' to update the index and working
;; tree.  However, Git v2.25 introduced the `git sparse-checkout'
;; command along with "cone mode", which restricts the possible
;; patterns to directories to provide better performance.
;;
;; The goal of this library is to support the `git sparse-checkout'
;; command operating in cone mode.

;;; Code:

(require 'magit2)

;;; Utilities

(defun magit2-sparse-checkout-enabled-p ()
  "Return non-nil if working tree is a sparse checkout."
  (magit2-get-boolean "core.sparsecheckout"))

(defun magit2-sparse-checkout--assert-version ()
  ;; Older versions of Git have the ability to define sparse checkout
  ;; patterns in .git/info/sparse-checkout, but the sparse-checkout
  ;; command isn't available until 2.25.0.
  (when (magit2-git-version< "2.25.0")
    (user-error "`git sparse-checkout' not available until Git v2.25")))

(defun magit2-sparse-checkout--auto-enable ()
  (if (magit2-sparse-checkout-enabled-p)
      (unless (magit2-get-boolean "core.sparsecheckoutcone")
        (user-error
         "Magit's sparse checkout functionality requires cone mode"))
    ;; Note: Don't use `magit2-sparse-checkout-enable' because it's
    ;; asynchronous.
    (magit2-run-git "sparse-checkout" "init" "--cone")))

(defun magit2-sparse-checkout-directories ()
  "Return directories that are recursively included in the sparse checkout.
See the `git sparse-checkout' manpage for details about
\"recursive\" versus \"parent\" directories in cone mode."
  (and (magit2-get-boolean "core.sparsecheckoutcone")
       (mapcar #'file-name-as-directory
               (magit2-git-lines "sparse-checkout" "list"))))

;;; Commands

;;;###autoload (autoload 'magit2-sparse-checkout "magit2-sparse-checkout" nil t)
(transient-define-prefix magit2-sparse-checkout ()
  "Create and manage sparse checkouts."
  :man-page "git-sparse-checkout"
  ["Arguments for enabling"
   :if-not magit2-sparse-checkout-enabled-p
   ("-i" "Use sparse index" "--sparse-index")]
  ["Actions"
   [:if-not magit2-sparse-checkout-enabled-p
    ("e" "Enable sparse checkout" magit2-sparse-checkout-enable)]
   [:if magit2-sparse-checkout-enabled-p
    ("d" "Disable sparse checkout" magit2-sparse-checkout-disable)
    ("r" "Reapply rules" magit2-sparse-checkout-reapply)]
   [("s" "Set directories" magit2-sparse-checkout-set)
    ("a" "Add directories" magit2-sparse-checkout-add)]])

;;;###autoload
(defun magit2-sparse-checkout-enable (&optional args)
  "Convert the working tree to a sparse checkout."
  (interactive (list (transient-args 'magit2-sparse-checkout)))
  (magit2-sparse-checkout--assert-version)
  (magit2-run-git-async "sparse-checkout" "init" "--cone" args))

;;;###autoload
(defun magit2-sparse-checkout-set (directories)
  "Restrict working tree to DIRECTORIES.
To extend rather than override the currently configured
directories, call `magit2-sparse-checkout-add' instead."
  (interactive
   (list (magit2-completing-read-multiple*
          "Include these directories: "
          ;; Note: Given that the appeal of sparse checkouts is
          ;; dealing with very large trees, listing all subdirectories
          ;; may need to be reconsidered.
          (magit2-revision-directories "HEAD"))))
  (magit2-sparse-checkout--assert-version)
  (magit2-sparse-checkout--auto-enable)
  (magit2-run-git-async "sparse-checkout" "set" directories))

;;;###autoload
(defun magit2-sparse-checkout-add (directories)
  "Add DIRECTORIES to the working tree.
To override rather than extend the currently configured
directories, call `magit2-sparse-checkout-set' instead."
  (interactive
   (list (magit2-completing-read-multiple*
          "Add these directories: "
          ;; Same performance note as in `magit2-sparse-checkout-set',
          ;; but even more so given the additional processing.
          (seq-remove
           (let ((re (concat
                      "\\`"
                      (regexp-opt (magit2-sparse-checkout-directories)))))
             (lambda (d) (string-match-p re d)))
           (magit2-revision-directories "HEAD")))))
  (magit2-sparse-checkout--assert-version)
  (magit2-sparse-checkout--auto-enable)
  (magit2-run-git-async "sparse-checkout" "add" directories))

;;;###autoload
(defun magit2-sparse-checkout-reapply ()
  "Reapply the sparse checkout rules to the working tree.
Some operations such as merging or rebasing may need to check out
files that aren't included in the sparse checkout.  Call this
command to reset to the sparse checkout state."
  (interactive)
  (magit2-sparse-checkout--assert-version)
  (magit2-run-git-async "sparse-checkout" "reapply"))

;;;###autoload
(defun magit2-sparse-checkout-disable ()
  "Convert sparse checkout to full checkout.
Note that disabling the sparse checkout does not clear the
configured directories.  Call `magit2-sparse-checkout-enable' to
restore the previous sparse checkout."
  (interactive)
  (magit2-sparse-checkout--assert-version)
  (magit2-run-git-async "sparse-checkout" "disable"))

;;; Miscellaneous

(defun magit2-sparse-checkout-insert-header ()
  "Insert header line with sparse checkout information.
This header is not inserted by default.  To enable it, add it to
`magit2-status-headers-hook'."
  (when (magit2-sparse-checkout-enabled-p)
    (insert (propertize (format "%-10s" "Sparse! ")
                        'font-lock-face 'magit2-section-heading))
    (insert
     (let ((dirs (magit2-sparse-checkout-directories)))
       (pcase (length dirs)
         (0 "top-level directory")
         (1 (car dirs))
         (n (format "%d directories" n)))))
    (insert ?\n)))

;;; _
(provide 'magit2-sparse-checkout)
;;; magit2-sparse-checkout.el ends here
