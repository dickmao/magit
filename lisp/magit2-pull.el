;;; magit2-pull.el --- update local objects and refs  -*- lexical-binding: t -*-

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

;; This library implements pull commands.

;;; Code:

(require 'magit2)

;;; Options

(defcustom magit2-pull-or-fetch nil
  "Whether `magit2-pull' also offers some fetch suffixes."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-commands
  :type 'boolean)

;;; Commands

;;;###autoload (autoload 'magit2-pull "magit2-pull" nil t)
(transient-define-prefix magit2-pull ()
  "Pull from another repository."
  :man-page "git-pull"
  :incompatible '(("--ff-only" "--rebase"))
  [:description
   (lambda () (if magit2-pull-or-fetch "Pull arguments" "Arguments"))
   ("-f" "Fast-forward only" "--ff-only")
   ("-r" "Rebase local commits" ("-r" "--rebase"))
   ("-A" "Autostash" "--autostash" :level 7)]
  [:description
   (lambda ()
     (if-let ((branch (magit2-get-current-branch)))
         (concat
          (propertize "Pull into " 'face 'transient-heading)
          (propertize branch       'face 'magit2-branch-local)
          (propertize " from"      'face 'transient-heading))
       (propertize "Pull from" 'face 'transient-heading)))
   ("p" magit2-pull-from-pushremote)
   ("u" magit2-pull-from-upstream)
   ("e" "elsewhere"         magit2-pull-branch)]
  ["Fetch from"
   :if-non-nil magit2-pull-or-fetch
   ("f" "remotes"           magit2-fetch-all-no-prune)
   ("F" "remotes and prune" magit2-fetch-all-prune)]
  ["Fetch"
   :if-non-nil magit2-pull-or-fetch
   ("o" "another branch"    magit2-fetch-branch)
   ("s" "explicit refspec"  magit2-fetch-refspec)
   ("m" "submodules"        magit2-fetch-modules)]
  ["Configure"
   ("r" magit2-branch.<branch>.rebase :if magit2-get-current-branch)
   ("C" "variables..." magit2-branch-configure)]
  (interactive)
  (transient-setup 'magit2-pull nil nil :scope (magit2-get-current-branch)))

(defun magit2-pull-arguments ()
  (transient-args 'magit2-pull))

;;;###autoload (autoload 'magit2-pull-from-pushremote "magit2-pull" nil t)
(transient-define-suffix magit2-pull-from-pushremote (args)
  "Pull from the push-remote of the current branch.

With a prefix argument or when the push-remote is either not
configured or unusable, then let the user first configure the
push-remote."
  :if 'magit2-get-current-branch
  :description 'magit2-pull--pushbranch-description
  (interactive (list (magit2-pull-arguments)))
  (pcase-let ((`(,branch ,remote)
               (magit2--select-push-remote "pull from there")))
    (run-hooks 'magit2-credential-hook)
    (magit2-run-git-with-editor "pull" args remote branch)))

(defun magit2-pull--pushbranch-description ()
  ;; Also used by `magit2-rebase-onto-pushremote'.
  (let* ((branch (magit2-get-current-branch))
         (target (magit2-get-push-branch branch t))
         (remote (magit2-get-push-remote branch))
         (v (magit2--push-remote-variable branch t)))
    (cond
     (target)
     ((member remote (magit2-list-remotes))
      (format "%s, replacing non-existent" v))
     (remote
      (format "%s, replacing invalid" v))
     (t
      (format "%s, setting that" v)))))

;;;###autoload (autoload 'magit2-pull-from-upstream "magit2-pull" nil t)
(transient-define-suffix magit2-pull-from-upstream (args)
  "Pull from the upstream of the current branch.

With a prefix argument or when the upstream is either not
configured or unusable, then let the user first configure
the upstream."
  :if 'magit2-get-current-branch
  :description 'magit2-pull--upstream-description
  (interactive (list (magit2-pull-arguments)))
  (let* ((branch (or (magit2-get-current-branch)
                     (user-error "No branch is checked out")))
         (remote (magit2-get "branch" branch "remote"))
         (merge  (magit2-get "branch" branch "merge")))
    (when (or current-prefix-arg
              (not (or (magit2-get-upstream-branch branch)
                       (magit2--unnamed-upstream-p remote merge))))
      (magit2-set-upstream-branch
       branch (magit2-read-upstream-branch
               branch (format "Set upstream of %s and pull from there" branch)))
      (setq remote (magit2-get "branch" branch "remote"))
      (setq merge  (magit2-get "branch" branch "merge")))
    (run-hooks 'magit2-credential-hook)
    (magit2-run-git-with-editor "pull" args remote merge)))

(defun magit2-pull--upstream-description ()
  (when-let ((branch (magit2-get-current-branch)))
    (or (magit2-get-upstream-branch branch)
        (let ((remote (magit2-get "branch" branch "remote"))
              (merge  (magit2-get "branch" branch "merge"))
              (u (magit2--propertize-face "@{upstream}" 'bold)))
          (cond
           ((magit2--unnamed-upstream-p remote merge)
            (format "%s of %s"
                    (magit2--propertize-face merge 'magit2-branch-remote)
                    (magit2--propertize-face remote 'bold)))
           ((magit2--valid-upstream-p remote merge)
            (concat u ", replacing non-existent"))
           ((or remote merge)
            (concat u ", replacing invalid"))
           (t
            (concat u ", setting that")))))))

;;;###autoload
(defun magit2-pull-branch (source args)
  "Pull from a branch read in the minibuffer."
  (interactive (list (magit2-read-remote-branch "Pull" nil nil nil t)
                     (magit2-pull-arguments)))
  (run-hooks 'magit2-credential-hook)
  (pcase-let ((`(,remote . ,branch)
               (magit2-get-tracked source)))
    (magit2-run-git-with-editor "pull" args remote branch)))

;;; _
(provide 'magit2-pull)
;;; magit2-pull.el ends here
