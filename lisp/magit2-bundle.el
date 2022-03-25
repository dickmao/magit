;;; magit2-bundle.el --- bundle support for Magit   -*- lexical-binding: t -*-

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

;;;###autoload (autoload 'magit2-bundle "magit2-bundle" nil t)
(transient-define-prefix magit2-bundle ()
  "Create or verify Git bundles."
  :man-page "git-bundle"
  ["Actions"
   ("c" "create"     magit2-bundle-create)
   ("v" "verify"     magit2-bundle-verify)
   ("l" "list-heads" magit2-bundle-list-heads)])

;;;###autoload (autoload 'magit2-bundle-import "magit2-bundle" nil t)
(transient-define-prefix magit2-bundle-create (&optional file refs args)
  "Create a bundle."
  :man-page "git-bundle"
  ["Arguments"
   ("-a" "Include all refs" "--all")
   ("-b" "Include branches" "--branches=" :allow-empty t)
   ("-t" "Include tags"     "--tags="     :allow-empty t)
   ("-r" "Include remotes"  "--remotes="  :allow-empty t)
   ("-g" "Include refs"     "--glob=")
   ("-e" "Exclude refs"     "--exclude=")
   (magit2-log:-n)
   (magit2-log:--since)
   (magit2-log:--until)]
  ["Actions"
   ("c" "create regular bundle" magit2-bundle-create)
   ("t" "create tracked bundle" magit2-bundle-create-tracked)
   ("u" "update tracked bundle" magit2-bundle-update-tracked)]
  (interactive
   (and (eq transient-current-command 'magit2-bundle-create)
        (list (read-file-name "Create bundle: " nil nil nil
                              (concat (file-name-nondirectory
                                       (directory-file-name (magit2-toplevel)))
                                      ".bundle"))
              (magit2-completing-read-multiple* "Refnames (zero or more): "
                                               (magit2-list-refnames))
              (transient-args 'magit2-bundle-create))))
  (if file
      (magit2-git-bundle "create" file refs args)
    (transient-setup 'magit2-bundle-create)))

;;;###autoload
(defun magit2-bundle-create-tracked (file tag branch refs args)
  "Create and track a new bundle."
  (interactive
   (let ((tag    (magit2-read-tag "Track bundle using tag"))
         (branch (magit2-read-branch "Bundle branch"))
         (refs   (magit2-completing-read-multiple*
                  "Additional refnames (zero or more): "
                  (magit2-list-refnames))))
     (list (read-file-name "File: " nil nil nil (concat tag ".bundle"))
           tag branch
           (if (equal branch (magit2-get-current-branch))
               (cons "HEAD" refs)
             refs)
           (transient-args 'magit2-bundle-create))))
  (magit2-git-bundle "create" file (cons branch refs) args)
  (magit2-git "tag" "--force" tag branch
             "-m" (concat ";; git-bundle tracking\n"
                          (pp-to-string `((file   . ,file)
                                          (branch . ,branch)
                                          (refs   . ,refs)
                                          (args   . ,args))))))

;;;###autoload
(defun magit2-bundle-update-tracked (tag)
  "Update a bundle that is being tracked using TAG."
  (interactive (list (magit2-read-tag "Update bundle tracked by tag" t)))
  (let (msg)
    (let-alist (magit2--with-temp-process-buffer
                 (save-excursion
                   (magit2-git-insert "for-each-ref" "--format=%(contents)"
                                     (concat "refs/tags/" tag)))
                 (setq msg (buffer-string))
                 (ignore-errors (read (current-buffer))))
      (unless (and .file .branch)
        (error "Tag %s does not appear to track a bundle" tag))
      (magit2-git-bundle "create" .file
                        (cons (concat tag ".." .branch) .refs)
                        .args)
      (magit2-git "tag" "--force" tag .branch "-m" msg))))

;;;###autoload
(defun magit2-bundle-verify (file)
  "Check whether FILE is valid and applies to the current repository."
  (interactive (list (magit2-bundle--read-file-name "Verify bundle: ")))
  (magit2-process-buffer)
  (magit2-git-bundle "verify" file))

;;;###autoload
(defun magit2-bundle-list-heads (file)
  "List the refs in FILE."
  (interactive (list (magit2-bundle--read-file-name "List heads of bundle: ")))
  (magit2-process-buffer)
  (magit2-git-bundle "list-heads" file))

(defun magit2-bundle--read-file-name (prompt)
  (read-file-name prompt nil nil t (magit2-file-at-point) #'file-regular-p))

(defun magit2-git-bundle (command file &optional refs args)
  (magit2-git "bundle" command (magit2-convert-filename-for-git file) refs args))

;;; _
(provide 'magit2-bundle)
;;; magit2-bundle.el ends here
