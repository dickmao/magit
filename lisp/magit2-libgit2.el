;;; magit2-libgit2.el --- Libgit2 functionality       -*- lexical-binding: t -*-

;; Copyright (C) 2010-2022  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit2.vc/authors.

;; Author: dick <dickie.smalls@commandlinesystems.com>

;; Keywords: git tools vc
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

;; Use libgit2_el.so dynamic module instead of spawning a git process.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'eieio)
(require 'seq)
(require 'subr-x)

(require 'magit2-git)
(require 'libgit2)

(defun magit2-libgit2-repo (&optional directory)
  "Return an object for the repository in DIRECTORY.
If optional DIRECTORY is nil, then use `default-directory'."
  (when-let ((default-directory (magit2-gitdir directory)))
    (magit2--with-refresh-cache
        (cons default-directory 'magit2-libgit2-repo)
      (libgit2-repository-open default-directory))))

(cl-defmethod magit2-bare-repo-p
  (&optional noerror)
  (when (magit2--assert-default-directory noerror)
    (if-let ((repo (magit2-libgit2-repo)))
        (libgit2-repository-bare-p repo)
      (unless noerror
        (signal 'magit2-outside-git-repo default-directory)))))

(provide 'magit2-libgit2)
;;; magit2-libgit2.el ends here
