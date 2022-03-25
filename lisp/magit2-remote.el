;;; magit2-remote.el --- transfer Git commits  -*- lexical-binding: t -*-

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

;; This library implements remote commands.

;;; Code:

(require 'magit2)

;;; Options

(defcustom magit2-remote-add-set-remote.pushDefault 'ask-if-unset
  "Whether to set the value of `remote.pushDefault' after adding a remote.

If `ask', then always ask.  If `ask-if-unset', then ask, but only
if the variable isn't set already.  If nil, then don't ever set.
If the value is a string, then set without asking, provided that
the name of the added remote is equal to that string and the
variable isn't already set."
  :package-version '(magit2 . "2.4.0")
  :group 'magit2-commands
  :type '(choice (const  :tag "ask if unset" ask-if-unset)
                 (const  :tag "always ask" ask)
                 (string :tag "set if named")
                 (const  :tag "don't set")))

(defcustom magit2-remote-direct-configure t
  "Whether the command `magit2-remote' shows Git variables.
When set to nil, no variables are displayed by this transient
command, instead the sub-transient `magit2-remote-configure'
has to be used to view and change remote related variables."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-prefer-push-default nil
  "Whether to prefer `remote.pushDefault' over per-branch variables."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-commands
  :type 'boolean)

;;; Commands

;;;###autoload (autoload 'magit2-remote "magit2-remote" nil t)
(transient-define-prefix magit2-remote (remote)
  "Add, configure or remove a remote."
  :man-page "git-remote"
  :value '("-f")
  ["Variables"
   :if (lambda ()
         (and magit2-remote-direct-configure
              (oref transient--prefix scope)))
   ("u" magit2-remote.<remote>.url)
   ("U" magit2-remote.<remote>.fetch)
   ("s" magit2-remote.<remote>.pushurl)
   ("S" magit2-remote.<remote>.push)
   ("O" magit2-remote.<remote>.tagopt)]
  ["Arguments for add"
   ("-f" "Fetch after add" "-f")]
  ["Actions"
   [("a" "Add"                  magit2-remote-add)
    ("r" "Rename"               magit2-remote-rename)
    ("k" "Remove"               magit2-remote-remove)]
   [("C" "Configure..."         magit2-remote-configure)
    ("p" "Prune stale branches" magit2-remote-prune)
    ("P" "Prune stale refspecs" magit2-remote-prune-refspecs)
    (7 "z" "Unshallow remote"   magit2-remote-unshallow)]]
  (interactive (list (magit2-get-current-remote)))
  (transient-setup 'magit2-remote nil nil :scope remote))

(defun magit2-read-url (prompt &optional initial-input)
  (let ((url (magit2-read-string-ns prompt initial-input)))
    (if (string-prefix-p "~" url)
        (expand-file-name url)
      url)))

;;;###autoload
(defun magit2-remote-add (remote url &optional args)
  "Add a remote named REMOTE and fetch it."
  (interactive
   (let ((origin (magit2-get "remote.origin.url"))
         (remote (magit2-read-string-ns "Remote name")))
     (list remote
           (magit2-read-url
            "Remote url"
            (and origin
                 (string-match "\\([^:/]+\\)/[^/]+\\(\\.git\\)?\\'" origin)
                 (replace-match remote t t origin 1)))
           (transient-args 'magit2-remote))))
  (if (pcase (list magit2-remote-add-set-remote.pushDefault
                   (magit2-get "remote.pushDefault"))
        (`(,(pred stringp) ,_) t)
        ((or `(ask ,_) `(ask-if-unset nil))
         (y-or-n-p (format "Set `remote.pushDefault' to \"%s\"? " remote))))
      (progn (magit2-call-git "remote" "add" args remote url)
             (setf (magit2-get "remote.pushDefault") remote)
             (magit2-refresh))
    (magit2-run-git-async "remote" "add" args remote url)))

;;;###autoload
(defun magit2-remote-rename (old new)
  "Rename the remote named OLD to NEW."
  (interactive
   (let  ((remote (magit2-read-remote "Rename remote")))
     (list remote (magit2-read-string-ns (format "Rename %s to" remote)))))
  (unless (string= old new)
    (magit2-call-git "remote" "rename" old new)
    (magit2-remote--cleanup-push-variables old new)
    (magit2-refresh)))

;;;###autoload
(defun magit2-remote-remove (remote)
  "Delete the remote named REMOTE."
  (interactive (list (magit2-read-remote "Delete remote")))
  (magit2-call-git "remote" "rm" remote)
  (magit2-remote--cleanup-push-variables remote)
  (magit2-refresh))

(defun magit2-remote--cleanup-push-variables (remote &optional new-name)
  (magit2-with-toplevel
    (when (equal (magit2-get "remote.pushDefault") remote)
      (magit2-set new-name "remote.pushDefault"))
    (dolist (var (magit2-git-lines "config" "--name-only"
                                  "--get-regexp" "^branch\.[^.]*\.pushRemote"
                                  (format "^%s$" remote)))
      (magit2-call-git "config" (and (not new-name) "--unset") var new-name))))

(defconst magit2--refspec-re "\\`\\(\\+\\)?\\([^:]+\\):\\(.*\\)\\'")

;;;###autoload
(defun magit2-remote-prune (remote)
  "Remove stale remote-tracking branches for REMOTE."
  (interactive (list (magit2-read-remote "Prune stale branches of remote")))
  (magit2-run-git-async "remote" "prune" remote))

;;;###autoload
(defun magit2-remote-prune-refspecs (remote)
  "Remove stale refspecs for REMOTE.

A refspec is stale if there no longer exists at least one branch
on the remote that would be fetched due to that refspec.  A stale
refspec is problematic because its existence causes Git to refuse
to fetch according to the remaining non-stale refspecs.

If only stale refspecs remain, then offer to either delete the
remote or to replace the stale refspecs with the default refspec.

Also remove the remote-tracking branches that were created due to
the now stale refspecs.  Other stale branches are not removed."
  (interactive (list (magit2-read-remote "Prune refspecs of remote")))
  (let* ((tracking-refs (magit2-list-remote-branches remote))
         (remote-refs (magit2-remote-list-refs remote))
         (variable (format "remote.%s.fetch" remote))
         (refspecs (magit2-get-all variable))
         stale)
    (dolist (refspec refspecs)
      (when (string-match magit2--refspec-re refspec)
        (let ((theirs (match-string 2 refspec))
              (ours   (match-string 3 refspec)))
          (unless (if (string-match "\\*" theirs)
                      (let ((re (replace-match ".*" t t theirs)))
                        (--some (string-match-p re it) remote-refs))
                    (member theirs remote-refs))
            (push (cons refspec
                        (if (string-match "\\*" ours)
                            (let ((re (replace-match ".*" t t ours)))
                              (--filter (string-match-p re it) tracking-refs))
                          (list (car (member ours tracking-refs)))))
                  stale)))))
    (if (not stale)
        (message "No stale refspecs for remote %S" remote)
      (if (= (length stale)
             (length refspecs))
          (magit2-read-char-case
              (format "All of %s's refspecs are stale.  " remote) nil
            (?s "replace with [d]efault refspec"
                (magit2-set-all
                 (list (format "+refs/heads/*:refs/remotes/%s/*" remote))
                 variable))
            (?r "[r]emove remote"
                (magit2-call-git "remote" "rm" remote))
            (?a "or [a]abort"
                (user-error "Abort")))
        (if (if (= (length stale) 1)
                (pcase-let ((`(,refspec . ,refs) (car stale)))
                  (magit2-confirm 'prune-stale-refspecs
                    (format "Prune stale refspec %s and branch %%s" refspec)
                    (format "Prune stale refspec %s and %%i branches" refspec)
                    nil refs))
              (magit2-confirm 'prune-stale-refspecs nil
                (format "Prune %%i stale refspecs and %i branches"
                        (length (cl-mapcan (lambda (s) (copy-sequence (cdr s)))
                                           stale)))
                nil
                (mapcar (pcase-lambda (`(,refspec . ,refs))
                          (concat refspec "\n"
                                  (mapconcat (lambda (b) (concat "  " b))
                                             refs "\n")))
                        stale)))
            (pcase-dolist (`(,refspec . ,refs) stale)
              (magit2-call-git "config" "--unset" variable
                              (regexp-quote refspec))
              (magit2--log-action
               (lambda (refs)
                 (format "Deleting %i branches" (length refs)))
               (lambda (ref)
                 (format "Deleting branch %s (was %s)" ref
                         (magit2-rev-parse "--short" ref)))
               refs)
              (dolist (ref refs)
                (magit2-call-git "update-ref" "-d" ref)))
          (user-error "Abort")))
      (magit2-refresh))))

;;;###autoload
(defun magit2-remote-set-head (remote &optional branch)
  "Set the local representation of REMOTE's default branch.
Query REMOTE and set the symbolic-ref refs/remotes/<remote>/HEAD
accordingly.  With a prefix argument query for the branch to be
used, which allows you to select an incorrect value if you fancy
doing that."
  (interactive
   (let  ((remote (magit2-read-remote "Set HEAD for remote")))
     (list remote
           (and current-prefix-arg
                (magit2-read-remote-branch (format "Set %s/HEAD to" remote)
                                          remote nil nil t)))))
  (magit2-run-git "remote" "set-head" remote (or branch "--auto")))

;;;###autoload
(defun magit2-remote-unset-head (remote)
  "Unset the local representation of REMOTE's default branch.
Delete the symbolic-ref \"refs/remotes/<remote>/HEAD\"."
  (interactive (list (magit2-read-remote "Unset HEAD for remote")))
  (magit2-run-git "remote" "set-head" remote "--delete"))

;;;###autoload
(defun magit2-remote-unshallow (remote)
  "Convert a shallow remote into a full one.
If only a single refspec is set and it does not contain a
wildcard, then also offer to replace it with the standard
refspec."
  (interactive (list (or (magit2-get-current-remote)
                         (magit2-read-remote "Delete remote"))))
  (let ((refspecs (magit2-get-all "remote" remote "fetch"))
        (standard (format "+refs/heads/*:refs/remotes/%s/*" remote)))
    (when (and (= (length refspecs) 1)
               (not (string-match-p "\\*" (car refspecs)))
               (yes-or-no-p (format "Also replace refspec %s with %s? "
                                    (car refspecs)
                                    standard)))
      (magit2-set standard "remote" remote "fetch"))
    (magit2-git-fetch "--unshallow" remote)))

;;; Configure

;;;###autoload (autoload 'magit2-remote-configure "magit2-remote" nil t)
(transient-define-prefix magit2-remote-configure (remote)
  "Configure a remote."
  :man-page "git-remote"
  [:description
   (lambda ()
     (concat
      (propertize "Configure " 'face 'transient-heading)
      (propertize (oref transient--prefix scope) 'face 'magit2-branch-remote)))
   ("u" magit2-remote.<remote>.url)
   ("U" magit2-remote.<remote>.fetch)
   ("s" magit2-remote.<remote>.pushurl)
   ("S" magit2-remote.<remote>.push)
   ("O" magit2-remote.<remote>.tagopt)]
  (interactive
   (list (or (and (not current-prefix-arg)
                  (not (and magit2-remote-direct-configure
                            (eq transient-current-command 'magit2-remote)))
                  (magit2-get-current-remote))
             (magit2--read-remote-scope))))
  (transient-setup 'magit2-remote-configure nil nil :scope remote))

(defun magit2--read-remote-scope (&optional obj)
  (magit2-read-remote
   (if obj
       (format "Set %s for remote"
               (format (oref obj variable) "<name>"))
     "Configure remote")))

(transient-define-infix magit2-remote.<remote>.url ()
  :class 'magit2--git-variable:urls
  :scope 'magit2--read-remote-scope
  :variable "remote.%s.url"
  :multi-value t
  :history-key 'magit2-remote.<remote>.*url)

(transient-define-infix magit2-remote.<remote>.fetch ()
  :class 'magit2--git-variable
  :scope 'magit2--read-remote-scope
  :variable "remote.%s.fetch"
  :multi-value t)

(transient-define-infix magit2-remote.<remote>.pushurl ()
  :class 'magit2--git-variable:urls
  :scope 'magit2--read-remote-scope
  :variable "remote.%s.pushurl"
  :multi-value t
  :history-key 'magit2-remote.<remote>.*url
  :seturl-arg "--push")

(transient-define-infix magit2-remote.<remote>.push ()
  :class 'magit2--git-variable
  :scope 'magit2--read-remote-scope
  :variable "remote.%s.push")

(transient-define-infix magit2-remote.<remote>.tagopt ()
  :class 'magit2--git-variable:choices
  :scope 'magit2--read-remote-scope
  :variable "remote.%s.tagOpt"
  :choices '("--no-tags" "--tags"))

;;; Transfer Utilities

(defun magit2--push-remote-variable (&optional branch short)
  (unless branch
    (setq branch (magit2-get-current-branch)))
  (magit2--propertize-face
   (if (or (not branch) magit2-prefer-push-default)
       (if short "pushDefault" "remote.pushDefault")
     (if short "pushRemote" (format "branch.%s.pushRemote" branch)))
   'bold))

(defun magit2--select-push-remote (prompt-suffix)
  (let* ((branch (or (magit2-get-current-branch)
                     (user-error "No branch is checked out")))
         (remote (magit2-get-push-remote branch))
         (changed nil))
    (when (or current-prefix-arg
              (not remote)
              (not (member remote (magit2-list-remotes))))
      (setq changed t)
      (setq remote
            (magit2-read-remote (format "Set %s and %s"
                                       (magit2--push-remote-variable)
                                       prompt-suffix)))
      (setf (magit2-get (magit2--push-remote-variable branch)) remote))
    (list branch remote changed)))

;;; _
(provide 'magit2-remote)
;;; magit2-remote.el ends here
