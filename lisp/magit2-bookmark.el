;;; magit2-bookmark.el --- bookmark support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2010-2022  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit2.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Inspired by an earlier implementation by Yuri Khan.

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

;; Support for bookmarks for most Magit buffers.

;;; Code:

(require 'magit2)
(require 'bookmark)

;;; Core

(defun magit2--make-bookmark ()
  "Create a bookmark for the current Magit buffer.
Input values are the major-mode's `magit2-bookmark-name' method,
and the buffer-local values of the variables referenced in its
`magit2-bookmark-variables' property."
  (if (plist-member (symbol-plist major-mode) 'magit2-bookmark-variables)
      ;; `bookmark-make-record-default's return value does not match
      ;; (NAME . ALIST), even though it is used as the default value
      ;; of `bookmark-make-record-function', which states that such
      ;; functions must do that.  See #4356.
      (let ((bookmark (cons nil (bookmark-make-record-default 'no-file))))
        (bookmark-prop-set bookmark 'handler  'magit2--handle-bookmark)
        (bookmark-prop-set bookmark 'mode     major-mode)
        (bookmark-prop-set bookmark 'filename (magit2-toplevel))
        (bookmark-prop-set bookmark 'defaults (list (magit2-bookmark-name)))
        (dolist (var (get major-mode 'magit2-bookmark-variables))
          (bookmark-prop-set bookmark var (symbol-value var)))
        (bookmark-prop-set
         bookmark 'magit2-hidden-sections
         (--keep (and (oref it hidden)
                      (cons (oref it type)
                            (if (derived-mode-p 'magit2-stash-mode)
                                (replace-regexp-in-string
                                 (regexp-quote magit2-buffer-revision)
                                 magit2-buffer-revision-hash
                                 (oref it value))
                              (oref it value))))
                 (oref magit2-root-section children)))
        bookmark)
    (user-error "Bookmarking is not implemented for %s buffers" major-mode)))

;;;###autoload
(defun magit2--handle-bookmark (bookmark)
  "Open a bookmark created by `magit2--make-bookmark'.
Call the `magit2-*-setup-buffer' function of the the major-mode
with the variables' values as arguments, which were recorded by
`magit2--make-bookmark'.  Ignore `magit2-display-buffer-function'."
  (let ((buffer (let ((default-directory (bookmark-get-filename bookmark))
                      (mode (bookmark-prop-get bookmark 'mode))
                      (magit2-display-buffer-function #'identity)
                      (magit2-display-buffer-noselect t))
                  (apply (intern (format "%s-setup-buffer"
                                         (substring (symbol-name mode) 0 -5)))
                         (--map (bookmark-prop-get bookmark it)
                                (get mode 'magit2-bookmark-variables))))))
    (set-buffer buffer) ; That is the interface we have to adhere to.
    (when-let ((hidden (bookmark-prop-get bookmark 'magit2-hidden-sections)))
      (with-current-buffer buffer
        (dolist (child (oref magit2-root-section children))
          (if (member (cons (oref child type)
                            (oref child value))
                      hidden)
              (magit2-section-hide child)
            (magit2-section-show child)))))
    ;; Compatibility with `bookmark+' package.  See #4356.
    (when (bound-and-true-p bmkp-jump-display-function)
      (funcall bmkp-jump-display-function (current-buffer)))
    nil))

(cl-defgeneric magit2-bookmark-name ()
  "Return name for bookmark to current buffer."
  (format "%s%s"
          (substring (symbol-name major-mode) 0 -5)
          (if-let ((vars (get major-mode 'magit2-bookmark-variables)))
              (cl-mapcan (lambda (var)
                           (let ((val (symbol-value var)))
                             (if (and val (atom val))
                                 (list val)
                               val)))
                         vars)
            "")))

;;; Diff
;;;; Diff

(put 'magit2-diff-mode 'magit2-bookmark-variables
     '(magit2-buffer-range-hashed
       magit2-buffer-typearg
       magit2-buffer-diff-args
       magit2-buffer-diff-files))

(cl-defmethod magit2-bookmark-name (&context (major-mode magit2-diff-mode))
  (format "magit2-diff(%s%s)"
          (pcase (magit2-diff-type)
            (`staged "staged")
            (`unstaged "unstaged")
            (`committed magit2-buffer-range)
            (`undefined
             (delq nil (list magit2-buffer-typearg magit2-buffer-range-hashed))))
          (if magit2-buffer-diff-files
              (concat " -- " (mapconcat #'identity magit2-buffer-diff-files " "))
            "")))

;;;; Revision

(put 'magit2-revision-mode 'magit2-bookmark-variables
     '(magit2-buffer-revision-hash
       magit2-buffer-diff-args
       magit2-buffer-diff-files))

(cl-defmethod magit2-bookmark-name (&context (major-mode magit2-revision-mode))
  (format "magit2-revision(%s %s)"
          (magit2-rev-abbrev magit2-buffer-revision)
          (if magit2-buffer-diff-files
              (mapconcat #'identity magit2-buffer-diff-files " ")
            (magit2-rev-format "%s" magit2-buffer-revision))))

;;;; Stash

(put 'magit2-stash-mode 'magit2-bookmark-variables
     '(magit2-buffer-revision-hash
       magit2-buffer-diff-args
       magit2-buffer-diff-files))

(cl-defmethod magit2-bookmark-name (&context (major-mode magit2-stash-mode))
  (format "magit2-stash(%s %s)"
          (magit2-rev-abbrev magit2-buffer-revision)
          (if magit2-buffer-diff-files
              (mapconcat #'identity magit2-buffer-diff-files " ")
            (magit2-rev-format "%s" magit2-buffer-revision))))

;;; Log
;;;; Log

(put 'magit2-log-mode 'magit2-bookmark-variables
     '(magit2-buffer-revisions
       magit2-buffer-log-args
       magit2-buffer-log-files))

(cl-defmethod magit2-bookmark-name (&context (major-mode magit2-log-mode))
  (format "magit2-log(%s%s)"
          (mapconcat #'identity magit2-buffer-revisions " ")
          (if magit2-buffer-log-files
              (concat " -- " (mapconcat #'identity magit2-buffer-log-files " "))
            "")))

;;;; Cherry

(put 'magit2-cherry-mode 'magit2-bookmark-variables
     '(magit2-buffer-refname
       magit2-buffer-upstream))

(cl-defmethod magit2-bookmark-name (&context (major-mode magit2-cherry-mode))
  (format "magit2-cherry(%s > %s)"
          magit2-buffer-refname
          magit2-buffer-upstream))

;;;; Reflog

(put 'magit2-reflog-mode 'magit2-bookmark-variables
     '(magit2-buffer-refname))

(cl-defmethod magit2-bookmark-name (&context (major-mode magit2-reflog-mode))
  (format "magit2-reflog(%s)" magit2-buffer-refname))

;;; Misc

(put 'magit2-status-mode 'magit2-bookmark-variables nil)

(put 'magit2-refs-mode 'magit2-bookmark-variables
     '(magit2-buffer-upstream
       magit2-buffer-arguments))

(put 'magit2-stashes-mode 'magit2-bookmark-variables nil)

(cl-defmethod magit2-bookmark-name (&context (major-mode magit2-stashes-mode))
  (format "magit2-states(%s)" magit2-buffer-refname))

;;; _
(provide 'magit2-bookmark)
;;; magit2-bookmark.el ends here
