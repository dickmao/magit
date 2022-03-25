;;; magit2-obsolete.el --- obsolete definitions  -*- lexical-binding: t -*-

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

;; This library defines aliases for obsolete variables and functions.

;;; Code:

(require 'magit2)

;;; Obsolete since v3.0.0

(define-obsolete-function-alias 'magit2-diff-visit-file-worktree
  'magit2-diff-visit-worktree-file "Magit 3.0.0")

(define-obsolete-function-alias 'magit2-status-internal
  'magit2-status-setup-buffer "Magit 3.0.0")

(define-obsolete-variable-alias 'magit2-mode-setup-hook
  'magit2-setup-buffer-hook "Magit 3.0.0")

(define-obsolete-variable-alias 'magit2-branch-popup-show-variables
  'magit2-branch-direct-configure "Magit 3.0.0")

(define-obsolete-function-alias 'magit2-dispatch-popup
  'magit2-dispatch "Magit 3.0.0")

(define-obsolete-function-alias 'magit2-repolist-column-dirty
  'magit2-repolist-column-flag "Magit 3.0.0")

(define-obsolete-variable-alias 'magit2-disable-line-numbers
  'magit2-section-disable-line-numbers "Magit 3.0.0")

(define-obsolete-variable-alias 'inhibit-magit2-refresh
  'magit2-inhibit-refresh "Magit 3.0.0")

(defun magit2--magit2-popup-warning ()
  (display-warning 'magit2 "\
Magit no longer uses Magit-Popup.
It now uses Transient.
See https://emacsair.me/2019/02/14/transient-0.1.

However your configuration and/or some third-party package that
you use still depends on the `magit2-popup' package.  But because
`magit2' no longer depends on that, `package' has removed it from
your system.

If some package that you use still depends on `magit2-popup' but
does not declare it as a dependency, then please contact its
maintainer about that and install `magit2-popup' explicitly.

If you yourself use functions that are defined in `magit2-popup'
in your configuration, then the next step depends on what you use
that for.

* If you use `magit2-popup' to define your own popups but do not
  modify any of Magit's old popups, then you have to install
  `magit2-popup' explicitly.  (You can also migrate to Transient,
  but there is no need to rush that.)

* If you add additional arguments and/or actions to Magit's popups,
  then you have to port that to modify the new \"transients\" instead.
  See https://github.com/magit2/magit2/wiki/\
Converting-popup-modifications-to-transient-modifications

To find installed packages that still use `magit2-popup' you can
use e.g. \"M-x rgrep RET magit2-popup RET RET ~/.emacs.d/ RET\"."))
(cl-eval-when (eval load)
  (unless (require (quote magit2-popup) nil t)
    (defun magit2-define-popup-switch (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-define-popup-option (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-define-popup-variable (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-define-popup-action (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-define-popup-sequence-action (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-define-popup-key (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-define-popup-keys-deferred (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-change-popup-key (&rest _)
      (magit2--magit2-popup-warning))
    (defun magit2-remove-popup-key (&rest _)
      (magit2--magit2-popup-warning))))

;;; _
(provide 'magit2-obsolete)
;;; magit2-obsolete.el ends here
