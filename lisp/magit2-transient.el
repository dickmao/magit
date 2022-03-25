;;; magit2-transient.el --- support for transients  -*- lexical-binding: t -*-

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

;; This library implements Magit-specific prefix and suffix classes,
;; and their methods.

;;; Code:

(require 'magit2-git)
(require 'magit2-mode)
(require 'magit2-process)

(require 'transient)

;;; Classes

(defclass magit2--git-variable (transient-variable)
  ((scope       :initarg :scope)
   (global      :initarg :global      :initform nil)))

(defclass magit2--git-variable:choices (magit2--git-variable)
  ((choices     :initarg :choices)
   (fallback    :initarg :fallback    :initform nil)
   (default     :initarg :default     :initform nil)))

(defclass magit2--git-variable:boolean (magit2--git-variable:choices)
  ((choices     :initarg :choices     :initform '("true" "false"))))

(defclass magit2--git-variable:urls (magit2--git-variable)
  ((seturl-arg  :initarg :seturl-arg  :initform nil)))

;;; Methods
;;;; Init

(cl-defmethod transient-init-scope ((obj magit2--git-variable))
  (oset obj scope
        (cond (transient--prefix
               (oref transient--prefix scope))
              ((slot-boundp obj 'scope)
               (funcall (oref obj scope) obj)))))

(cl-defmethod transient-init-value ((obj magit2--git-variable))
  (let ((variable (format (oref obj variable)
                          (oref obj scope)))
        (arg (if (oref obj global) "--global" "--local")))
    (oset obj variable variable)
    (oset obj value
          (cond ((oref obj multi-value)
                 (magit2-get-all arg variable))
                (t
                 (magit2-get arg variable))))))

(cl-defmethod transient-init-value ((obj magit2--git-variable:boolean))
  (let ((variable (format (oref obj variable)
                          (oref obj scope)))
        (arg (if (oref obj global) "--global" "--local")))
    (oset obj variable variable)
    (oset obj value (if (magit2-get-boolean arg variable) "true" "false"))))

;;;; Read

(cl-defmethod transient-infix-read :around ((obj magit2--git-variable:urls))
  (transient--with-emergency-exit
    (transient--with-suspended-override
     (mapcar (lambda (url)
               (if (string-prefix-p "~" url)
                   (expand-file-name url)
                 url))
             (cl-call-next-method obj)))))

(cl-defmethod transient-infix-read ((obj magit2--git-variable:choices))
  (let ((choices (oref obj choices)))
    (when (functionp choices)
      (setq choices (funcall choices)))
    (if-let ((value (oref obj value)))
        (cadr (member value choices))
      (car choices))))

;;;; Readers

(defun magit2-transient-read-person (prompt initial-input history)
  (magit2-completing-read
   prompt
   (mapcar (lambda (line)
             (save-excursion
               (and (string-match "\\`[\s\t]+[0-9]+\t" line)
                    (list (substring line (match-end 0))))))
           (magit2-git-lines "shortlog" "-n" "-s" "-e" "HEAD"))
   nil nil initial-input history))

(defun magit2-transient-read-revision (prompt initial-input history)
  (or (magit2-completing-read prompt (cons "HEAD" (magit2-list-refnames))
                             nil nil initial-input history
                             (or (magit2-branch-or-commit-at-point)
                                 (magit2-get-current-branch)))
      (user-error "Nothing selected")))

;;;; Set

(cl-defmethod transient-infix-set ((obj magit2--git-variable) value)
  (let ((variable (oref obj variable))
        (arg (if (oref obj global) "--global" "--local")))
    (oset obj value value)
    (if (oref obj multi-value)
        (magit2-set-all value arg variable)
      (magit2-set value arg variable))
    (magit2-refresh)
    (unless (or value transient--prefix)
      (message "Unset %s" variable))))

(cl-defmethod transient-infix-set ((obj magit2--git-variable:urls) values)
  (let ((previous (oref obj value))
        (seturl   (oref obj seturl-arg))
        (remote   (oref transient--prefix scope)))
    (oset obj value values)
    (dolist (v (-difference values previous))
      (magit2-call-git "remote" "set-url" seturl "--add" remote v))
    (dolist (v (-difference previous values))
      (magit2-call-git "remote" "set-url" seturl "--delete" remote
                      (concat "^" (regexp-quote v) "$")))
    (magit2-refresh)))

;;;; Draw

(cl-defmethod transient-format-description ((obj magit2--git-variable))
  (or (oref obj description)
      (oref obj variable)))

(cl-defmethod transient-format-value ((obj magit2--git-variable))
  (if-let ((value (oref obj value)))
      (if (oref obj multi-value)
          (if (cdr value)
              (mapconcat (lambda (v)
                           (concat "\n     "
                                   (propertize v 'face 'transient-value)))
                         value "")
            (propertize (car value) 'face 'transient-value))
        (propertize (car (split-string value "\n"))
                    'face 'transient-value))
    (propertize "unset" 'face 'transient-inactive-value)))

(cl-defmethod transient-format-value ((obj magit2--git-variable:choices))
  (let* ((variable (oref obj variable))
         (choices  (oref obj choices))
         (globalp  (oref obj global))
         (value    nil)
         (global   (magit2-git-string "config" "--global" variable))
         (default  (oref obj default))
         (fallback (oref obj fallback))
         (fallback (and fallback
                        (when-let ((val (magit2-get fallback)))
                          (concat fallback ":" val)))))
    (if (not globalp)
        (setq value (magit2-git-string "config" "--local"  variable))
      (setq value global)
      (setq global nil))
    (when (functionp choices)
      (setq choices (funcall choices)))
    (concat
     (propertize "[" 'face 'transient-inactive-value)
     (mapconcat (lambda (choice)
                  (propertize choice 'face (if (equal choice value)
                                               (if (member choice choices)
                                                   'transient-value
                                                 'font-lock-warning-face)
                                             'transient-inactive-value)))
                (if (and value (not (member value choices)))
                    (cons value choices)
                  choices)
                (propertize "|" 'face 'transient-inactive-value))
     (and (or global fallback default)
          (concat
           (propertize "|" 'face 'transient-inactive-value)
           (cond (global
                  (propertize (concat "global:" global)
                              'face (cond (value
                                           'transient-inactive-value)
                                          ((member global choices)
                                           'transient-value)
                                          (t
                                           'font-lock-warning-face))))
                 (fallback
                  (propertize fallback
                              'face (if value
                                        'transient-inactive-value
                                      'transient-value)))
                 (default
                   (propertize (concat "default:" default)
                               'face (if value
                                         'transient-inactive-value
                                       'transient-value))))))
     (propertize "]" 'face 'transient-inactive-value))))

;;; _
(provide 'magit2-transient)
;;; magit2-transient.el ends here
