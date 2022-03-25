;;; magit2-core.el --- core functionality  -*- lexical-binding: t -*-

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

;; This library requires several other libraries, so that yet other
;; libraries can just require this one, instead of having to require
;; all the other ones.  In other words this separates the low-level
;; stuff from the rest.  It also defines some Custom groups.

;;; Code:

(require 'magit2-base)
(require 'magit2-git)
(require 'magit2-mode)
(require 'magit2-margin)
(require 'magit2-process)
(require 'magit2-transient)
(require 'magit2-autorevert)

(defgroup magit2 nil
  "Controlling Git from Emacs."
  :link '(url-link "https://magit2.vc")
  :link '(info-link "(magit2)FAQ")
  :link '(info-link "(magit2)")
  :group 'tools)

(defgroup magit2-essentials nil
  "Options that every Magit user should briefly think about.

Each of these options falls into one or more of these categories:

* Options that affect Magit's behavior in fundamental ways.
* Options that affect safety.
* Options that affect performance.
* Options that are of a personal nature."
  :link '(info-link "(magit2)Essential Settings")
  :group 'magit2)

(defgroup magit2-miscellaneous nil
  "Miscellaneous Magit options."
  :group 'magit2)

(defgroup magit2-commands nil
  "Options controlling behavior of certain commands."
  :group 'magit2)

(defgroup magit2-modes nil
  "Modes used or provided by Magit."
  :group 'magit2)

(defgroup magit2-buffers nil
  "Options concerning Magit buffers."
  :link '(info-link "(magit2)Modes and Buffers")
  :group 'magit2)

(defgroup magit2-refresh nil
  "Options controlling how Magit buffers are refreshed."
  :link '(info-link "(magit2)Automatic Refreshing of Magit Buffers")
  :group 'magit2
  :group 'magit2-buffers)

(defgroup magit2-faces nil
  "Faces used by Magit."
  :group 'magit2
  :group 'faces)

(custom-add-to-group 'magit2-faces 'diff-refine-added   'custom-face)
(custom-add-to-group 'magit2-faces 'diff-refine-removed 'custom-face)

(defgroup magit2-extensions nil
  "Extensions to Magit."
  :group 'magit2)

(custom-add-to-group 'magit2-modes   'git-commit        'custom-group)
(custom-add-to-group 'magit2-faces   'git-commit-faces  'custom-group)
(custom-add-to-group 'magit2-modes   'git-rebase        'custom-group)
(custom-add-to-group 'magit2-faces   'git-rebase-faces  'custom-group)
(custom-add-to-group 'magit2         'magit2-section     'custom-group)
(custom-add-to-group 'magit2-faces   'magit2-section-faces 'custom-group)
(custom-add-to-group 'magit2-process 'with-editor       'custom-group)

(defgroup magit2-related nil
  "Options that are relevant to Magit but that are defined elsewhere."
  :link '(custom-group-link vc)
  :link '(custom-group-link smerge)
  :link '(custom-group-link ediff)
  :link '(custom-group-link auto-revert)
  :group 'magit2
  :group 'magit2-extensions
  :group 'magit2-essentials)

(custom-add-to-group 'magit2-related     'auto-revert-check-vc-info 'custom-variable)
(custom-add-to-group 'magit2-auto-revert 'auto-revert-check-vc-info 'custom-variable)

(custom-add-to-group 'magit2-related 'ediff-window-setup-function 'custom-variable)
(custom-add-to-group 'magit2-related 'smerge-refine-ignore-whitespace 'custom-variable)
(custom-add-to-group 'magit2-related 'vc-follow-symlinks 'custom-variable)

;;; _
(provide 'magit2-core)
;;; magit2-core.el ends here
