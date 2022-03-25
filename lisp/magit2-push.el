;;; magit2-push.el --- update remote objects and refs  -*- lexical-binding: t -*-

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

;; This library implements push commands.

;;; Code:

(require 'magit2)

;;; Commands

;;;###autoload (autoload 'magit2-push "magit2-push" nil t)
(transient-define-prefix magit2-push ()
  "Push to another repository."
  :man-page "git-push"
  ["Arguments"
   ("-f" "Force with lease" (nil "--force-with-lease"))
   ("-F" "Force"            ("-f" "--force"))
   ("-h" "Disable hooks"    "--no-verify")
   ("-n" "Dry run"          ("-n" "--dry-run"))
   (5 "-u" "Set upstream"   "--set-upstream")
   (7 "-t" "Follow tags"    "--follow-tags")]
  [:if magit2-get-current-branch
   :description (lambda ()
                  (format (propertize "Push %s to" 'face 'transient-heading)
                          (propertize (magit2-get-current-branch)
                                      'face 'magit2-branch-local)))
   ("p" magit2-push-current-to-pushremote)
   ("u" magit2-push-current-to-upstream)
   ("e" "elsewhere" magit2-push-current)]
  ["Push"
   [("o" "another branch"    magit2-push-other)
    ("r" "explicit refspecs" magit2-push-refspecs)
    ("m" "matching branches" magit2-push-matching)]
   [("T" "a tag"             magit2-push-tag)
    ("t" "all tags"          magit2-push-tags)
    (6 "n" "a note ref"      magit2-push-notes-ref)]]
  ["Configure"
   ("C" "Set variables..."  magit2-branch-configure)])

(defun magit2-push-arguments ()
  (transient-args 'magit2-push))

(defun magit2-git-push (branch target args)
  (run-hooks 'magit2-credential-hook)
  ;; If the remote branch already exists, then we do not have to
  ;; qualify the target, which we prefer to avoid doing because
  ;; using the default namespace is wrong in obscure cases.
  (pcase-let ((namespace (if (magit2-get-tracked target) "" "refs/heads/"))
              (`(,remote . ,target)
               (magit2-split-branch-name target)))
    (magit2-run-git-async "push" "-v" args remote
                         (format "%s:%s%s" branch namespace target))))

;;;###autoload (autoload 'magit2-push-current-to-pushremote "magit2-push" nil t)
(transient-define-suffix magit2-push-current-to-pushremote (args)
  "Push the current branch to its push-remote.

When the push-remote is not configured, then read the push-remote
from the user, set it, and then push to it.  With a prefix
argument the push-remote can be changed before pushed to it."
  :if 'magit2-get-current-branch
  :description 'magit2-push--pushbranch-description
  (interactive (list (magit2-push-arguments)))
  (pcase-let ((`(,branch ,remote ,changed)
               (magit2--select-push-remote "push there")))
    (when changed
      (magit2-confirm 'set-and-push
        (replace-regexp-in-string
         "%" "%%"
         (format "Really use \"%s\" as push-remote and push \"%s\" there"
                 remote branch))))
    (run-hooks 'magit2-credential-hook)
    (magit2-run-git-async "push" "-v" args remote
                         (format "refs/heads/%s:refs/heads/%s"
                                 branch branch)))) ; see #3847 and #3872

(defun magit2-push--pushbranch-description ()
  (let* ((branch (magit2-get-current-branch))
         (target (magit2-get-push-branch branch t))
         (remote (magit2-get-push-remote branch))
         (v (magit2--push-remote-variable branch t)))
    (cond
     (target)
     ((member remote (magit2-list-remotes))
      (format "%s, creating it"
              (magit2--propertize-face (concat remote "/" branch)
                                      'magit2-branch-remote)))
     (remote
      (format "%s, replacing invalid" v))
     (t
      (format "%s, setting that" v)))))

;;;###autoload (autoload 'magit2-push-current-to-upstream "magit2-push" nil t)
(transient-define-suffix magit2-push-current-to-upstream (args)
  "Push the current branch to its upstream branch.

With a prefix argument or when the upstream is either not
configured or unusable, then let the user first configure
the upstream."
  :if 'magit2-get-current-branch
  :description 'magit2-push--upstream-description
  (interactive (list (magit2-push-arguments)))
  (let* ((branch (or (magit2-get-current-branch)
                     (user-error "No branch is checked out")))
         (remote (magit2-get "branch" branch "remote"))
         (merge  (magit2-get "branch" branch "merge")))
    (when (or current-prefix-arg
              (not (or (magit2-get-upstream-branch branch)
                       (magit2--unnamed-upstream-p remote merge)
                       (magit2--valid-upstream-p remote merge))))
      (let* ((branches (-union (--map (concat it "/" branch)
                                      (magit2-list-remotes))
                               (magit2-list-remote-branch-names)))
             (upstream (magit2-completing-read
                        (format "Set upstream of %s and push there" branch)
                        branches nil nil nil 'magit2-revision-history
                        (or (car (member (magit2-remote-branch-at-point) branches))
                            (car (member "origin/master" branches)))))
             (upstream* (or (magit2-get-tracked upstream)
                            (magit2-split-branch-name upstream))))
        (setq remote (car upstream*))
        (setq merge  (cdr upstream*))
        (unless (string-prefix-p "refs/" merge)
          ;; User selected a non-existent remote-tracking branch.
          ;; It is very likely, but not certain, that this is the
          ;; correct thing to do.  It is even more likely that it
          ;; is what the user wants to happen.
          (setq merge (concat "refs/heads/" merge)))
        (magit2-confirm 'set-and-push
          (replace-regexp-in-string
           "%" "%%"
           (format "Really use \"%s\" as upstream and push \"%s\" there"
                   upstream branch))))
      (cl-pushnew "--set-upstream" args :test #'equal))
    (run-hooks 'magit2-credential-hook)
    (magit2-run-git-async "push" "-v" args remote (concat branch ":" merge))))

(defun magit2-push--upstream-description ()
  (when-let ((branch (magit2-get-current-branch)))
    (or (magit2-get-upstream-branch branch)
        (let ((remote (magit2-get "branch" branch "remote"))
              (merge  (magit2-get "branch" branch "merge"))
              (u (magit2--propertize-face "@{upstream}" 'bold)))
          (cond
           ((magit2--unnamed-upstream-p remote merge)
            (format "%s as %s"
                    (magit2--propertize-face remote 'bold)
                    (magit2--propertize-face merge 'magit2-branch-remote)))
           ((magit2--valid-upstream-p remote merge)
            (format "%s creating %s"
                    (magit2--propertize-face remote 'magit2-branch-remote)
                    (magit2--propertize-face merge 'magit2-branch-remote)))
           ((or remote merge)
            (concat u ", creating it and replacing invalid"))
           (t
            (concat u ", creating it")))))))

;;;###autoload
(defun magit2-push-current (target args)
  "Push the current branch to a branch read in the minibuffer."
  (interactive
   (--if-let (magit2-get-current-branch)
       (list (magit2-read-remote-branch (format "Push %s to" it)
                                       nil nil it 'confirm)
             (magit2-push-arguments))
     (user-error "No branch is checked out")))
  (magit2-git-push (magit2-get-current-branch) target args))

;;;###autoload
(defun magit2-push-other (source target args)
  "Push an arbitrary branch or commit somewhere.
Both the source and the target are read in the minibuffer."
  (interactive
   (let ((source (magit2-read-local-branch-or-commit "Push")))
     (list source
           (magit2-read-remote-branch
            (format "Push %s to" source) nil
            (if (magit2-local-branch-p source)
                (or (magit2-get-push-branch source)
                    (magit2-get-upstream-branch source))
              (and (magit2-rev-ancestor-p source "HEAD")
                   (or (magit2-get-push-branch)
                       (magit2-get-upstream-branch))))
            source 'confirm)
           (magit2-push-arguments))))
  (magit2-git-push source target args))

(defvar magit2-push-refspecs-history nil)

;;;###autoload
(defun magit2-push-refspecs (remote refspecs args)
  "Push one or multiple REFSPECS to a REMOTE.
Both the REMOTE and the REFSPECS are read in the minibuffer.  To
use multiple REFSPECS, separate them with commas.  Completion is
only available for the part before the colon, or when no colon
is used."
  (interactive
   (list (magit2-read-remote "Push to remote")
         (magit2-completing-read-multiple*
          "Push refspec,s: "
          (cons "HEAD" (magit2-list-local-branch-names))
          nil nil nil 'magit2-push-refspecs-history)
         (magit2-push-arguments)))
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "push" "-v" args remote refspecs))

;;;###autoload
(defun magit2-push-matching (remote &optional args)
  "Push all matching branches to another repository.
If multiple remotes exist, then read one from the user.
If just one exists, use that without requiring confirmation."
  (interactive (list (magit2-read-remote "Push matching branches to" nil t)
                     (magit2-push-arguments)))
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "push" "-v" args remote ":"))

;;;###autoload
(defun magit2-push-tags (remote &optional args)
  "Push all tags to another repository.
If only one remote exists, then push to that.  Otherwise prompt
for a remote, offering the remote configured for the current
branch as default."
  (interactive (list (magit2-read-remote "Push tags to remote" nil t)
                     (magit2-push-arguments)))
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "push" remote "--tags" args))

;;;###autoload
(defun magit2-push-tag (tag remote &optional args)
  "Push a tag to another repository."
  (interactive
   (let  ((tag (magit2-read-tag "Push tag")))
     (list tag (magit2-read-remote (format "Push %s to remote" tag) nil t)
           (magit2-push-arguments))))
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "push" remote tag args))

;;;###autoload
(defun magit2-push-notes-ref (ref remote &optional args)
  "Push a notes ref to another repository."
  (interactive
   (let ((note (magit2-notes-read-ref "Push notes" nil nil)))
     (list note
           (magit2-read-remote (format "Push %s to remote" note) nil t)
           (magit2-push-arguments))))
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "push" remote ref args))

;;;###autoload (autoload 'magit2-push-implicitly "magit2-push" nil t)
(transient-define-suffix magit2-push-implicitly (args)
  "Push somewhere without using an explicit refspec.

This command simply runs \"git push -v [ARGS]\".  ARGS are the
arguments specified in the popup buffer.  No explicit refspec
arguments are used.  Instead the behavior depends on at least
these Git variables: `push.default', `remote.pushDefault',
`branch.<branch>.pushRemote', `branch.<branch>.remote',
`branch.<branch>.merge', and `remote.<remote>.push'.

If you add this suffix to a transient prefix without explicitly
specifying the description, then an attempt is made to predict
what this command will do.  For example:

  (transient-insert-suffix \\='magit2-push \"p\"
    \\='(\"i\" magit2-push-implicitly))"
  :description 'magit2-push-implicitly--desc
  (interactive (list (magit2-push-arguments)))
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "push" "-v" args))

(defun magit2-push-implicitly--desc ()
  (let ((default (magit2-get "push.default")))
    (unless (equal default "nothing")
      (or (when-let ((remote (or (magit2-get-remote)
                                 (magit2-primary-remote)))
                     (refspec (magit2-get "remote" remote "push")))
            (format "%s using %s"
                    (magit2--propertize-face remote 'magit2-branch-remote)
                    (magit2--propertize-face refspec 'bold)))
          (--when-let (and (not (magit2-get-push-branch))
                           (magit2-get-upstream-branch))
            (format "%s aka %s\n"
                    (magit2-branch-set-face it)
                    (magit2--propertize-face "@{upstream}" 'bold)))
          (--when-let (magit2-get-push-branch)
            (format "%s aka %s\n"
                    (magit2-branch-set-face it)
                    (magit2--propertize-face "pushRemote" 'bold)))
          (--when-let (magit2-get-@{push}-branch)
            (format "%s aka %s\n"
                    (magit2-branch-set-face it)
                    (magit2--propertize-face "@{push}" 'bold)))
          (format "using %s (%s is %s)\n"
                  (magit2--propertize-face "git push"     'bold)
                  (magit2--propertize-face "push.default" 'bold)
                  (magit2--propertize-face default        'bold))))))

;;;###autoload
(defun magit2-push-to-remote (remote args)
  "Push to REMOTE without using an explicit refspec.
The REMOTE is read in the minibuffer.

This command simply runs \"git push -v [ARGS] REMOTE\".  ARGS
are the arguments specified in the popup buffer.  No refspec
arguments are used.  Instead the behavior depends on at least
these Git variables: `push.default', `remote.pushDefault',
`branch.<branch>.pushRemote', `branch.<branch>.remote',
`branch.<branch>.merge', and `remote.<remote>.push'."
  (interactive (list (magit2-read-remote "Push to remote")
                     (magit2-push-arguments)))
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "push" "-v" args remote))

(defun magit2-push-to-remote--desc ()
  (format "using %s\n" (magit2--propertize-face "git push <remote>" 'bold)))

;;; _
(provide 'magit2-push)
;;; magit2-push.el ends here
