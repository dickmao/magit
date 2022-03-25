;;; magit2-clone.el --- clone a repository  -*- lexical-binding: t -*-

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

;; This library implements clone commands.

;;; Code:

(require 'magit2)

;;; Options

(defcustom magit2-clone-set-remote-head nil
  "Whether cloning creates the symbolic-ref `<remote>/HEAD'."
  :package-version '(magit2 . "2.4.2")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-clone-set-remote.pushDefault 'ask
  "Whether to set the value of `remote.pushDefault' after cloning.

If t, then set without asking.  If nil, then don't set.  If
`ask', then ask."
  :package-version '(magit2 . "2.4.0")
  :group 'magit2-commands
  :type '(choice (const :tag "set" t)
                 (const :tag "ask" ask)
                 (const :tag "don't set" nil)))

(defcustom magit2-clone-default-directory nil
  "Default directory to use when `magit2-clone' reads destination.
If nil (the default), then use the value of `default-directory'.
If a directory, then use that.  If a function, then call that
with the remote url as only argument and use the returned value."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-commands
  :type '(choice (const     :tag "value of default-directory")
                 (directory :tag "constant directory")
                 (function  :tag "function's value")))

(defcustom magit2-clone-always-transient nil
  "Whether `magit2-clone' always acts as a transient prefix command.
If nil, then a prefix argument has to be used to show the transient
popup instead of invoking the default suffix `magit2-clone-regular'
directly."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-clone-name-alist
  '(("\\`\\(?:github:\\|gh:\\)?\\([^:]+\\)\\'" "github.com" "github.user")
    ("\\`\\(?:gitlab:\\|gl:\\)\\([^:]+\\)\\'"  "gitlab.com" "gitlab.user"))
  "Alist mapping repository names to repository urls.

Each element has the form (REGEXP HOSTNAME USER).  When the user
enters a name when a cloning command asks for a name or url, then
that is looked up in this list.  The first element whose REGEXP
matches is used.

The format specified by option `magit2-clone-url-format' is used
to turn the name into an url, using HOSTNAME and the repository
name.  If the provided name contains a slash, then that is used.
Otherwise if the name omits the owner of the repository, then the
default user specified in the matched entry is used.

If USER contains a dot, then it is treated as a Git variable and
the value of that is used as the username.  Otherwise it is used
as the username itself."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-commands
  :type '(repeat (list regexp
                       (string :tag "hostname")
                       (string :tag "user name or git variable"))))

(defcustom magit2-clone-url-format "git@%h:%n.git"
  "Format used when turning repository names into urls.
%h is the hostname and %n is the repository name, including
the name of the owner.  Also see `magit2-clone-name-alist'."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-commands
  :type 'regexp)

;;; Commands

;;;###autoload (autoload 'magit2-clone "magit2-clone" nil t)
(transient-define-prefix magit2-clone (&optional transient)
  "Clone a repository."
  :man-page "git-clone"
  ["Fetch arguments"
   ("-B" "Clone a single branch"  "--single-branch")
   ("-n" "Do not clone tags"      "--no-tags")
   ("-S" "Clones submodules"      "--recurse-submodules" :level 6)
   ("-l" "Do not optimize"        "--no-local" :level 7)]
  ["Setup arguments"
   ("-o" "Set name of remote"     ("-o" "--origin="))
   ("-b" "Set HEAD branch"        ("-b" "--branch="))
   (magit2-clone:--filter
    :if (lambda () (magit2-git-version>= "2.17.0"))
    :level 7)
   ("-g" "Separate git directory" "--separate-git-dir="
    transient-read-directory :level 7)
   ("-t" "Use template directory" "--template="
    transient-read-existing-directory :level 6)]
  ["Local sharing arguments"
   ("-s" "Share objects"          ("-s" "--shared" :level 7))
   ("-h" "Do not use hardlinks"   "--no-hardlinks")]
  ["Clone"
   ("C" "regular"            magit2-clone-regular)
   ("s" "shallow"            magit2-clone-shallow)
   ("d" "shallow since date" magit2-clone-shallow-since :level 7)
   ("e" "shallow excluding"  magit2-clone-shallow-exclude :level 7)
   (">" "sparse checkout"    magit2-clone-sparse
    :if (lambda () (magit2-git-version>= "2.25.0"))
    :level 6)
   ("b" "bare"               magit2-clone-bare)
   ("m" "mirror"             magit2-clone-mirror)]
  (interactive (list (or magit2-clone-always-transient current-prefix-arg)))
  (if transient
      (transient-setup #'magit2-clone)
    (call-interactively #'magit2-clone-regular)))

(transient-define-argument magit2-clone:--filter ()
  :description "Filter some objects"
  :class 'transient-option
  :key "-f"
  :argument "--filter="
  :reader 'magit2-clone-read-filter)

(defun magit2-clone-read-filter (prompt initial-input history)
  (magit2-completing-read prompt
                         (list "blob:none" "tree:0")
                         nil nil initial-input history))

;;;###autoload
(defun magit2-clone-regular (repository directory args)
  "Create a clone of REPOSITORY in DIRECTORY.
Then show the status buffer for the new repository."
  (interactive (magit2-clone-read-args))
  (magit2-clone-internal repository directory args))

;;;###autoload
(defun magit2-clone-shallow (repository directory args depth)
  "Create a shallow clone of REPOSITORY in DIRECTORY.
Then show the status buffer for the new repository.
With a prefix argument read the DEPTH of the clone;
otherwise use 1."
  (interactive (append (magit2-clone-read-args)
                       (list (if current-prefix-arg
                                 (read-number "Depth: " 1)
                               1))))
  (magit2-clone-internal repository directory
                        (cons (format "--depth=%s" depth) args)))

;;;###autoload
(defun magit2-clone-shallow-since (repository directory args date)
  "Create a shallow clone of REPOSITORY in DIRECTORY.
Then show the status buffer for the new repository.
Exclude commits before DATE, which is read from the
user."
  (interactive (append (magit2-clone-read-args)
                       (list (transient-read-date "Exclude commits before: "
                                                  nil nil))))
  (magit2-clone-internal repository directory
                        (cons (format "--shallow-since=%s" date) args)))

;;;###autoload
(defun magit2-clone-shallow-exclude (repository directory args exclude)
  "Create a shallow clone of REPOSITORY in DIRECTORY.
Then show the status buffer for the new repository.
Exclude commits reachable from EXCLUDE, which is a
branch or tag read from the user."
  (interactive (append (magit2-clone-read-args)
                       (list (read-string "Exclude commits reachable from: "))))
  (magit2-clone-internal repository directory
                        (cons (format "--shallow-exclude=%s" exclude) args)))

;;;###autoload
(defun magit2-clone-bare (repository directory args)
  "Create a bare clone of REPOSITORY in DIRECTORY.
Then show the status buffer for the new repository."
  (interactive (magit2-clone-read-args))
  (magit2-clone-internal repository directory (cons "--bare" args)))

;;;###autoload
(defun magit2-clone-mirror (repository directory args)
  "Create a mirror of REPOSITORY in DIRECTORY.
Then show the status buffer for the new repository."
  (interactive (magit2-clone-read-args))
  (magit2-clone-internal repository directory (cons "--mirror" args)))

;;;###autoload
(defun magit2-clone-sparse (repository directory args)
  "Clone REPOSITORY into DIRECTORY and create a sparse checkout."
  (interactive (magit2-clone-read-args))
  (magit2-clone-internal repository directory (cons "--no-checkout" args)
                        'sparse))

(defun magit2-clone-internal (repository directory args &optional sparse)
  (let* ((checkout (not (memq (car args) '("--bare" "--mirror"))))
         (remote (or (transient-arg-value "--origin" args)
                     (magit2-get "clone.defaultRemote")
                     "origin"))
         (set-push-default
          (and checkout
               (or (eq  magit2-clone-set-remote.pushDefault t)
                   (and magit2-clone-set-remote.pushDefault
                        (y-or-n-p (format "Set `remote.pushDefault' to %S? "
                                          remote)))))))
    (run-hooks 'magit2-credential-hook)
    (setq directory (file-name-as-directory (expand-file-name directory)))
    (when (file-exists-p directory)
      (if (file-directory-p directory)
          (when (> (length (directory-files directory)) 2)
            (let ((name (magit2-clone--url-to-name repository)))
              (unless (and name
                           (setq directory (file-name-as-directory
                                            (expand-file-name name directory)))
                           (not (file-exists-p directory)))
                (user-error "%s already exists" directory))))
        (user-error "%s already exists and is not a directory" directory)))
    (magit2-run-git-async "clone" args "--" repository
                         (magit2-convert-filename-for-git directory))
    ;; Don't refresh the buffer we're calling from.
    (process-put magit2-this-process 'inhibit-refresh t)
    (set-process-sentinel
     magit2-this-process
     (lambda (process event)
       (when (memq (process-status process) '(exit signal))
         (let ((magit2-process-raise-error t))
           (magit2-process-sentinel process event)))
       (when (and (eq (process-status process) 'exit)
                  (= (process-exit-status process) 0))
         (when checkout
           (let ((default-directory directory))
             (when set-push-default
               (setf (magit2-get "remote.pushDefault") remote))
             (unless magit2-clone-set-remote-head
               (magit2-remote-unset-head remote))))
         (when (and sparse checkout)
           (when (magit2-git-version< "2.25.0")
             (user-error
              "`git sparse-checkout' not available until Git v2.25"))
           (let ((default-directory directory))
             (magit2-call-git "sparse-checkout" "init" "--cone")
             (magit2-call-git "checkout" (magit2-get-current-branch))))
         (with-current-buffer (process-get process 'command-buf)
           (magit2-status-setup-buffer directory)))))))

(defun magit2-clone-read-args ()
  (let ((repo (magit2-clone-read-repository)))
    (list repo
          (read-directory-name
           "Clone to: "
           (if (functionp magit2-clone-default-directory)
               (funcall magit2-clone-default-directory repo)
             magit2-clone-default-directory)
           nil nil
           (magit2-clone--url-to-name repo))
          (transient-args 'magit2-clone))))

(defun magit2-clone-read-repository ()
  (magit2-read-char-case "Clone from " nil
    (?u "[u]rl or name"
        (let ((str (magit2-read-string-ns "Clone from url or name")))
          (if (string-match-p "\\(://\\|@\\)" str)
              str
            (magit2-clone--name-to-url str))))
    (?p "[p]ath"
        (magit2-convert-filename-for-git
         (read-directory-name "Clone repository: ")))
    (?l "[l]ocal url"
        (concat "file://"
                (magit2-convert-filename-for-git
                 (read-directory-name "Clone repository: file://"))))
    (?b "or [b]undle"
        (magit2-convert-filename-for-git
         (read-file-name "Clone from bundle: ")))))

(defun magit2-clone--url-to-name (url)
  (and (string-match "\\([^/:]+?\\)\\(/?\\.git\\)?$" url)
       (match-string 1 url)))

(defun magit2-clone--name-to-url (name)
  (or (seq-some
       (pcase-lambda (`(,re ,host ,user))
         (and (string-match re name)
              (let ((repo (match-string 1 name)))
                (magit2-clone--format-url host user repo))))
       magit2-clone-name-alist)
      (user-error "Not an url and no matching entry in `%s'"
                  'magit2-clone-name-alist)))

(defun magit2-clone--format-url (host user repo)
  (format-spec
   magit2-clone-url-format
   `((?h . ,host)
     (?n . ,(if (string-match-p "/" repo)
                repo
              (if (string-match-p "\\." user)
                  (if-let ((user (magit2-get user)))
                      (concat user "/" repo)
                    (user-error "Set %S or specify owner explicitly" user))
                (concat user "/" repo)))))))

;;; _
(provide 'magit2-clone)
;;; magit2-clone.el ends here
