;;; magit2-margin.el --- margins in Magit buffers  -*- lexical-binding: t -*-

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

;; This library implements support for showing additional information
;; in the margins of Magit buffers.  Currently this is only used for
;; commits, for which the committer date or age, and optionally the
;; author name are shown.

;;; Code:

(require 'magit2-base)
(require 'magit2-transient)
(require 'magit2-mode)

(defgroup magit2-margin nil
  "Information Magit displays in the margin.

You can change the STYLE and AUTHOR-WIDTH of all `magit2-*-margin'
options to the same values by customizing `magit2-log-margin'
*before* `magit2' is loaded.  If you do that, then the respective
values for the other options will default to what you have set
for that variable.  Likewise if you set `magit2-log-margin's INIT
to nil, then that is used in the default of all other options.  But
setting it to t, i.e. re-enforcing the default for that option,
does not carry to other options."
  :link '(info-link "(magit2)Log Margin")
  :group 'magit2-log)

(defvar-local magit2-buffer-margin nil)
(put 'magit2-buffer-margin 'permanent-local t)

(defvar-local magit2-set-buffer-margin-refresh nil)

(defvar magit2--age-spec)

;;; Commands

(transient-define-prefix magit2-margin-settings ()
  "Change what information is displayed in the margin."
  :info-manual "(magit2) Log Margin"
  ["Margin"
   ("L" "Toggle visibility" magit2-toggle-margin)
   ("l" "Cycle style"       magit2-cycle-margin-style)
   ("d" "Toggle details"    magit2-toggle-margin-details)
   ("v" "Change verbosity"  magit2-refs-set-show-commit-count
    :if-derived magit2-refs-mode)])

(defun magit2-toggle-margin ()
  "Show or hide the Magit margin."
  (interactive)
  (unless (magit2-margin-option)
    (user-error "Magit margin isn't supported in this buffer"))
  (setcar magit2-buffer-margin (not (magit2-buffer-margin-p)))
  (magit2-set-buffer-margin))

(defvar magit2-margin-default-time-format nil
  "See https://github.com/magit2/magit2/pull/4605.")

(defun magit2-cycle-margin-style ()
  "Cycle style used for the Magit margin."
  (interactive)
  (unless (magit2-margin-option)
    (user-error "Magit margin isn't supported in this buffer"))
  ;; This is only suitable for commit margins (there are not others).
  (setf (cadr magit2-buffer-margin)
        (pcase (cadr magit2-buffer-margin)
          (`age 'age-abbreviated)
          (`age-abbreviated
           (let ((default (or magit2-margin-default-time-format
                              (cadr (symbol-value (magit2-margin-option))))))
             (if (stringp default) default "%Y-%m-%d %H:%M ")))
          (_ 'age)))
  (magit2-set-buffer-margin nil t))

(defun magit2-toggle-margin-details ()
  "Show or hide details in the Magit margin."
  (interactive)
  (unless (magit2-margin-option)
    (user-error "Magit margin isn't supported in this buffer"))
  (setf (nth 3 magit2-buffer-margin)
        (not (nth 3 magit2-buffer-margin)))
  (magit2-set-buffer-margin nil t))

;;; Core

(defun magit2-buffer-margin-p ()
  (car magit2-buffer-margin))

(defun magit2-margin-option ()
  (pcase major-mode
    (`magit2-cherry-mode     'magit2-cherry-margin)
    (`magit2-log-mode        'magit2-log-margin)
    (`magit2-log-select-mode 'magit2-log-select-margin)
    (`magit2-reflog-mode     'magit2-reflog-margin)
    (`magit2-refs-mode       'magit2-refs-margin)
    (`magit2-stashes-mode    'magit2-stashes-margin)
    (`magit2-status-mode     'magit2-status-margin)
    (`forge-notifications-mode 'magit2-status-margin)))

(defun magit2-set-buffer-margin (&optional reset refresh)
  (when-let ((option (magit2-margin-option)))
    (let* ((default (symbol-value option))
           (default-width (nth 2 default)))
      (when (or reset (not magit2-buffer-margin))
        (setq magit2-buffer-margin (copy-sequence default)))
      (pcase-let ((`(,enable ,style ,_width ,details ,details-width)
                   magit2-buffer-margin))
        (when (functionp default-width)
          (setf (nth 2 magit2-buffer-margin)
                (funcall default-width style details details-width)))
        (dolist (window (get-buffer-window-list nil nil 0))
          (with-selected-window window
            (magit2-set-window-margin window)
            (if enable
                (add-hook  'window-configuration-change-hook
                           'magit2-set-window-margin nil t)
              (remove-hook 'window-configuration-change-hook
                           'magit2-set-window-margin t))))
        (when (and enable (or refresh magit2-set-buffer-margin-refresh))
          (magit2-refresh-buffer))))))

(defun magit2-set-window-margin (&optional window)
  (when (or window (setq window (get-buffer-window)))
    (with-selected-window window
      (set-window-margins
       nil (car (window-margins))
       (and (magit2-buffer-margin-p)
            (nth 2 magit2-buffer-margin))))))

(defun magit2-make-margin-overlay (&optional string previous-line)
  (if previous-line
      (save-excursion
        (forward-line -1)
        (magit2-make-margin-overlay string))
    ;; Don't put the overlay on the complete line to work around #1880.
    (let ((o (make-overlay (1+ (line-beginning-position))
                           (line-end-position)
                           nil t)))
      (overlay-put o 'evaporate t)
      (overlay-put o 'before-string
                   (propertize "o" 'display
                               (list (list 'margin 'right-margin)
                                     (or string " ")))))))

(defun magit2-maybe-make-margin-overlay ()
  (when (or (magit2-section-match
             '(unpulled unpushed recent stashes local cherries)
             magit2-insert-section--current)
            (and (eq major-mode 'magit2-refs-mode)
                 (magit2-section-match
                  '(remote commit tags)
                  magit2-insert-section--current)))
    (magit2-make-margin-overlay nil t)))

;;; Custom Support

(defun magit2-margin-set-variable (mode symbol value)
  (set-default symbol value)
  (message "Updating margins in %s buffers..." mode)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (eq major-mode mode)
        (magit2-set-buffer-margin t)
        (magit2-refresh))))
  (message "Updating margins in %s buffers...done" mode))

(defconst magit2-log-margin--custom-type
  '(list (boolean :tag "Show margin initially")
         (choice  :tag "Show committer"
                  (string :tag "date using time-format" "%Y-%m-%d %H:%M ")
                  (const  :tag "date's age" age)
                  (const  :tag "date's age (abbreviated)" age-abbreviated))
         (const   :tag "Calculate width using magit2-log-margin-width"
                  magit2-log-margin-width)
         (boolean :tag "Show author name by default")
         (integer :tag "Show author name using width")))

;;; Time Utilities

(defvar magit2--age-spec
  `((?Y "year"   "years"   ,(round (* 60 60 24 365.2425)))
    (?M "month"  "months"  ,(round (* 60 60 24 30.436875)))
    (?w "week"   "weeks"   ,(* 60 60 24 7))
    (?d "day"    "days"    ,(* 60 60 24))
    (?h "hour"   "hours"   ,(* 60 60))
    (?m "minute" "minutes" 60)
    (?s "second" "seconds" 1))
  "Time units used when formatting relative commit ages.

The value is a list of time units, beginning with the longest.
Each element has the form (CHAR UNIT UNITS SECONDS).  UNIT is the
time unit, UNITS is the plural of that unit.  CHAR is a character
abbreviation.  And SECONDS is the number of seconds in one UNIT.

This is defined as a variable to make it possible to use time
units for a language other than English.  It is not defined
as an option, because most other parts of Magit are always in
English.")

(defun magit2--age (date &optional abbreviate)
  (cl-labels ((fn (age spec)
                  (pcase-let ((`(,char ,unit ,units ,weight) (car spec)))
                    (let ((cnt (round (/ age weight 1.0))))
                      (if (or (not (cdr spec))
                              (>= (/ age weight) 1))
                          (list cnt (cond (abbreviate char)
                                          ((= cnt 1) unit)
                                          (t units)))
                        (fn age (cdr spec)))))))
    (fn (abs (- (float-time)
                (if (stringp date)
                    (string-to-number date)
                  date)))
        magit2--age-spec)))

;;; _
(provide 'magit2-margin)
;;; magit2-margin.el ends here
