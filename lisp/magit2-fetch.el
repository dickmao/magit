;;; magit2-fetch.el --- download objects and refs  -*- lexical-binding: t -*-

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

;; This library implements fetch commands.

;;; Code:

(require 'magit2)

(defvar magit2-fetch-modules-jobs nil)
(make-obsolete-variable
 'magit2-fetch-modules-jobs
 "invoke `magit2-fetch-modules' with a prefix argument instead."
 "Magit 3.0.0")

;;; Commands

;;;###autoload (autoload 'magit2-fetch "magit2-fetch" nil t)
(transient-define-prefix magit2-fetch ()
  "Fetch from another repository."
  :man-page "git-fetch"
  ["Arguments"
   ("-p" "Prune deleted branches" ("-p" "--prune"))
   ("-t" "Fetch all tags" ("-t" "--tags"))
   (7 "-u" "Fetch full history" "--unshallow")]
  ["Fetch from"
   ("p" magit2-fetch-from-pushremote)
   ("u" magit2-fetch-from-upstream)
   ("e" "elsewhere"        magit2-fetch-other)
   ("a" "all remotes"      magit2-fetch-all)]
  ["Fetch"
   ("o" "another branch"   magit2-fetch-branch)
   ("r" "explicit refspec" magit2-fetch-refspec)
   ("m" "submodules"       magit2-fetch-modules)]
  ["Configure"
   ("C" "variables..." magit2-branch-configure)])

(defun magit2-fetch-arguments ()
  (transient-args 'magit2-fetch))

(defun magit2-git-fetch (remote args)
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "fetch" remote args))

;;;###autoload (autoload 'magit2-fetch-from-pushremote "magit2-fetch" nil t)
(transient-define-suffix magit2-fetch-from-pushremote (args)
  "Fetch from the current push-remote.

With a prefix argument or when the push-remote is either not
configured or unusable, then let the user first configure the
push-remote."
  :description 'magit2-fetch--pushremote-description
  (interactive (list (magit2-fetch-arguments)))
  (let ((remote (magit2-get-push-remote)))
    (when (or current-prefix-arg
              (not (member remote (magit2-list-remotes))))
      (let ((var (magit2--push-remote-variable)))
        (setq remote
              (magit2-read-remote (format "Set %s and fetch from there" var)))
        (magit2-set remote var)))
    (magit2-git-fetch remote args)))

(defun magit2-fetch--pushremote-description ()
  (let* ((branch (magit2-get-current-branch))
         (remote (magit2-get-push-remote branch))
         (v (magit2--push-remote-variable branch t)))
    (cond
     ((member remote (magit2-list-remotes)) remote)
     (remote
      (format "%s, replacing invalid" v))
     (t
      (format "%s, setting that" v)))))

;;;###autoload (autoload 'magit2-fetch-from-upstream "magit2-fetch" nil t)
(transient-define-suffix magit2-fetch-from-upstream (remote args)
  "Fetch from the \"current\" remote, usually the upstream.

If the upstream is configured for the current branch and names
an existing remote, then use that.  Otherwise try to use another
remote: If only a single remote is configured, then use that.
Otherwise if a remote named \"origin\" exists, then use that.

If no remote can be determined, then this command is not available
from the `magit2-fetch' transient prefix and invoking it directly
results in an error."
  :if          (lambda () (magit2-get-current-remote t))
  :description (lambda () (magit2-get-current-remote t))
  (interactive (list (magit2-get-current-remote t)
                     (magit2-fetch-arguments)))
  (unless remote
    (error "The \"current\" remote could not be determined"))
  (magit2-git-fetch remote args))

;;;###autoload
(defun magit2-fetch-other (remote args)
  "Fetch from another repository."
  (interactive (list (magit2-read-remote "Fetch remote")
                     (magit2-fetch-arguments)))
  (magit2-git-fetch remote args))

;;;###autoload
(defun magit2-fetch-branch (remote branch args)
  "Fetch a BRANCH from a REMOTE."
  (interactive
   (let ((remote (magit2-read-remote-or-url "Fetch from remote or url")))
     (list remote
           (magit2-read-remote-branch "Fetch branch" remote)
           (magit2-fetch-arguments))))
  (magit2-git-fetch remote (cons branch args)))

;;;###autoload
(defun magit2-fetch-refspec (remote refspec args)
  "Fetch a REFSPEC from a REMOTE."
  (interactive
   (let ((remote (magit2-read-remote-or-url "Fetch from remote or url")))
     (list remote
           (magit2-read-refspec "Fetch using refspec" remote)
           (magit2-fetch-arguments))))
  (magit2-git-fetch remote (cons refspec args)))

;;;###autoload
(defun magit2-fetch-all (args)
  "Fetch from all remotes."
  (interactive (list (magit2-fetch-arguments)))
  (magit2-git-fetch nil (cons "--all" args)))

;;;###autoload
(defun magit2-fetch-all-prune ()
  "Fetch from all remotes, and prune.
Prune remote tracking branches for branches that have been
removed on the respective remote."
  (interactive)
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "remote" "update" "--prune"))

;;;###autoload
(defun magit2-fetch-all-no-prune ()
  "Fetch from all remotes."
  (interactive)
  (run-hooks 'magit2-credential-hook)
  (magit2-run-git-async "remote" "update"))

;;;###autoload (autoload 'magit2-fetch-modules "magit2-fetch" nil t)
(transient-define-prefix magit2-fetch-modules (&optional transient args)
  "Fetch all submodules.

Fetching is done using \"git fetch --recurse-submodules\", which
means that the super-repository and recursively all submodules
are also fetched.

To set and potentially save other arguments invoke this command
with a prefix argument."
  :man-page "git-fetch"
  :value (list "--verbose"
               (cond (magit2-fetch-modules-jobs
                      (format "--jobs=%s" magit2-fetch-modules-jobs))
                     (t "--jobs=4")))
  ["Arguments"
   ("-v" "verbose"        "--verbose")
   ("-j" "number of jobs" "--jobs=" :reader transient-read-number-N+)]
  ["Action"
   ("m" "fetch modules" magit2-fetch-modules)]
  (interactive (if current-prefix-arg
                   (list t)
                 (list nil (transient-args 'magit2-fetch-modules))))
  (if transient
      (transient-setup 'magit2-fetch-modules)
    (when (magit2-git-version< "2.8.0")
      (when-let ((value (transient-arg-value "--jobs=" args)))
        (message "Dropping --jobs; not supported by Git v%s"
                 (magit2-git-version))
        (setq args (remove (format "--jobs=%s" value) args))))
    (magit2-with-toplevel
      (magit2-run-git-async "fetch" "--recurse-submodules" args))))

;;; _
(provide 'magit2-fetch)
;;; magit2-fetch.el ends here
