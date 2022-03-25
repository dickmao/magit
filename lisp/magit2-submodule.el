;;; magit2-submodule.el --- submodule support for Magit  -*- lexical-binding: t -*-

;; Copyright (C) 2011-2022  The Magit Project Contributors
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

;;; Code:

(require 'magit2)

(defvar x-stretch-cursor)

;;; Options

(defcustom magit2-module-sections-hook
  '(magit2-insert-modules-overview
    magit2-insert-modules-unpulled-from-upstream
    magit2-insert-modules-unpulled-from-pushremote
    magit2-insert-modules-unpushed-to-upstream
    magit2-insert-modules-unpushed-to-pushremote)
  "Hook run by `magit2-insert-modules'.

That function isn't part of `magit2-status-sections-hook's default
value, so you have to add it yourself for this hook to have any
effect."
  :package-version '(magit2 . "2.11.0")
  :group 'magit2-status
  :type 'hook)

(defcustom magit2-module-sections-nested t
  "Whether `magit2-insert-modules' wraps inserted sections.

If this is non-nil, then only a single top-level section
is inserted.  If it is nil, then all sections listed in
`magit2-module-sections-hook' become top-level sections."
  :package-version '(magit2 . "2.11.0")
  :group 'magit2-status
  :type 'boolean)

(defcustom magit2-submodule-list-mode-hook '(hl-line-mode)
  "Hook run after entering Magit-Submodule-List mode."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-repolist
  :type 'hook
  :get 'magit2-hook-custom-get
  :options '(hl-line-mode))

(defcustom magit2-submodule-list-columns
  '(("Path"     25 magit2-modulelist-column-path   nil)
    ("Version"  25 magit2-repolist-column-version
     ((:sort magit2-repolist-version<)))
    ("Branch"   20 magit2-repolist-column-branch   nil)
    ("B<U" 3 magit2-repolist-column-unpulled-from-upstream
     ((:right-align t)
      (:sort <)))
    ("B>U" 3 magit2-repolist-column-unpushed-to-upstream
     ((:right-align t)
      (:sort <)))
    ("B<P" 3 magit2-repolist-column-unpulled-from-pushremote
     ((:right-align t)
      (:sort <)))
    ("B>P" 3 magit2-repolist-column-unpushed-to-pushremote
     ((:right-align t)
      (:sort <)))
    ("B"   3 magit2-repolist-column-branches
     ((:right-align t)
      (:sort <)))
    ("S"   3 magit2-repolist-column-stashes
     ((:right-align t)
      (:sort <))))
  "List of columns displayed by `magit2-list-submodules'.

Each element has the form (HEADER WIDTH FORMAT PROPS).

HEADER is the string displayed in the header.  WIDTH is the width
of the column.  FORMAT is a function that is called with one
argument, the repository identification (usually its basename),
and with `default-directory' bound to the toplevel of its working
tree.  It has to return a string to be inserted or nil.  PROPS is
an alist that supports the keys `:right-align', `:pad-right' and
`:sort'.

The `:sort' function has a weird interface described in the
docstring of `tabulated-list--get-sort'.  Alternatively `<' and
`magit2-repolist-version<' can be used as those functions are
automatically replaced with functions that satisfy the interface.
Set `:sort' to nil to inhibit sorting; if unspecifed, then the
column is sortable using the default sorter.

You may wish to display a range of numeric columns using just one
character per column and without any padding between columns, in
which case you should use an appropriat HEADER, set WIDTH to 1,
and set `:pad-right' to 0.  \"+\" is substituted for numbers higher
than 9."
  :package-version '(magit2 . "2.8.0")
  :group 'magit2-repolist
  :type `(repeat (list :tag "Column"
                       (string   :tag "Header Label")
                       (integer  :tag "Column Width")
                       (function :tag "Inserter Function")
                       (repeat   :tag "Properties"
                                 (list (choice :tag "Property"
                                               (const :right-align)
                                               (const :pad-right)
                                               (const :sort)
                                               (symbol))
                                       (sexp   :tag "Value"))))))

(defcustom magit2-submodule-list-sort-key '("Path" . nil)
  "Initial sort key for buffer created by `magit2-list-submodules'.
If nil, no additional sorting is performed.  Otherwise, this
should be a cons cell (NAME . FLIP).  NAME is a string matching
one of the column names in `magit2-submodule-list-columns'.  FLIP,
if non-nil, means to invert the resulting sort."
  :package-version '(magit2 . "3.2.0")
  :group 'magit2-repolist
  :type '(choice (const nil)
                 (cons (string :tag "Column name")
                       (boolean :tag "Flip order"))))

(defcustom magit2-submodule-remove-trash-gitdirs nil
  "Whether `magit2-submodule-remove' offers to trash module gitdirs.

If this is nil, then that command does not offer to do so unless
a prefix argument is used.  When this is t, then it does offer to
do so even without a prefix argument.

In both cases the action still has to be confirmed unless that is
disabled using the option `magit2-no-confirm'.  Doing the latter
and also setting this variable to t will lead to tears."
  :package-version '(magit2 . "2.90.0")
  :group 'magit2-commands
  :type 'boolean)

;;; Popup

;;;###autoload (autoload 'magit2-submodule "magit2-submodule" nil t)
(transient-define-prefix magit2-submodule ()
  "Act on a submodule."
  :man-page "git-submodule"
  ["Arguments"
   ("-f" "Force"            ("-f" "--force"))
   ("-r" "Recursive"        "--recursive")
   ("-N" "Do not fetch"     ("-N" "--no-fetch"))
   ("-C" "Checkout tip"     "--checkout")
   ("-R" "Rebase onto tip"  "--rebase")
   ("-M" "Merge tip"        "--merge")
   ("-U" "Use upstream tip" "--remote")]
  ["One module actions"
   ("a" magit2-submodule-add)
   ("r" magit2-submodule-register)
   ("p" magit2-submodule-populate)
   ("u" magit2-submodule-update)
   ("s" magit2-submodule-synchronize)
   ("d" magit2-submodule-unpopulate)
   ("k" "Remove" magit2-submodule-remove)]
  ["All modules actions"
   ("l" "List all modules"  magit2-list-submodules)
   ("f" "Fetch all modules" magit2-fetch-modules)])

(defun magit2-submodule-arguments (&rest filters)
  (--filter (and (member it filters) it)
            (transient-args 'magit2-submodule)))

(defclass magit2--git-submodule-suffix (transient-suffix)
  ())

(cl-defmethod transient-format-description ((obj magit2--git-submodule-suffix))
  (let ((value (delq nil (mapcar 'transient-infix-value transient--suffixes))))
    (replace-regexp-in-string
     "\\[--[^]]+\\]"
     (lambda (match)
       (format (propertize "[%s]" 'face 'transient-inactive-argument)
               (mapconcat (lambda (arg)
                            (propertize arg 'face
                                        (if (member arg value)
                                            'transient-argument
                                          'transient-inactive-argument)))
                          (save-match-data
                            (split-string (substring match 1 -1) "|"))
                          (propertize "|" 'face 'transient-inactive-argument))))
     (cl-call-next-method obj))))

;;;###autoload (autoload 'magit2-submodule-add "magit2-submodule" nil t)
(transient-define-suffix magit2-submodule-add (url &optional path name args)
  "Add the repository at URL as a module.

Optional PATH is the path to the module relative to the root of
the superproject.  If it is nil, then the path is determined
based on the URL.  Optional NAME is the name of the module.  If
it is nil, then PATH also becomes the name."
  :class 'magit2--git-submodule-suffix
  :description "Add            git submodule add [--force]"
  (interactive
   (magit2-with-toplevel
     (let* ((url (magit2-read-string-ns "Add submodule (remote url)"))
            (path (let ((read-file-name-function
                         (if (or (eq read-file-name-function 'ido-read-file-name)
                                 (advice-function-member-p
                                  'ido-read-file-name
                                  read-file-name-function))
                             ;; The Ido variant doesn't work properly here.
                             #'read-file-name-default
                           read-file-name-function)))
                    (directory-file-name
                     (file-relative-name
                      (read-directory-name
                       "Add submodules at path: " nil nil nil
                       (and (string-match "\\([^./]+\\)\\(\\.git\\)?$" url)
                            (match-string 1 url))))))))
       (list url
             (directory-file-name path)
             (magit2-submodule-read-name-for-path path)
             (magit2-submodule-arguments "--force")))))
  (magit2-submodule-add-1 url path name args))

(defun magit2-submodule-add-1 (url &optional path name args)
  (magit2-with-toplevel
    (magit2-submodule--maybe-reuse-gitdir name path)
    (magit2-run-git-async "submodule" "add"
                         (and name (list "--name" name))
                         args "--" url path)
    (set-process-sentinel
     magit2-this-process
     (lambda (process event)
       (when (memq (process-status process) '(exit signal))
         (if (> (process-exit-status process) 0)
             (magit2-process-sentinel process event)
           (process-put process 'inhibit-refresh t)
           (magit2-process-sentinel process event)
           (when (magit2-git-version>= "2.12.0")
             (magit2-call-git "submodule" "absorbgitdirs" path))
           (magit2-refresh)))))))

;;;###autoload
(defun magit2-submodule-read-name-for-path (path &optional prefer-short)
  (let* ((path (directory-file-name (file-relative-name path)))
         (name (file-name-nondirectory path)))
    (push (if prefer-short path name) minibuffer-history)
    (magit2-read-string-ns
     "Submodule name" nil (cons 'minibuffer-history 2)
     (or (--keep (pcase-let ((`(,var ,val) (split-string it "=")))
                   (and (equal val path)
                        (cadr (split-string var "\\."))))
                 (magit2-git-lines "config" "--list" "-f" ".gitmodules"))
         (if prefer-short name path)))))

;;;###autoload (autoload 'magit2-submodule-register "magit2-submodule" nil t)
(transient-define-suffix magit2-submodule-register (modules)
  "Register MODULES.

With a prefix argument act on all suitable modules.  Otherwise,
if the region selects modules, then act on those.  Otherwise, if
there is a module at point, then act on that.  Otherwise read a
single module from the user."
  ;; This command and the underlying "git submodule init" do NOT
  ;; "initialize" modules.  They merely "register" modules in the
  ;; super-projects $GIT_DIR/config file, the purpose of which is to
  ;; allow users to change such values before actually initializing
  ;; the modules.
  :description "Register       git submodule init"
  (interactive
   (list (magit2-module-confirm "Register" 'magit2-module-no-worktree-p)))
  (magit2-with-toplevel
    (magit2-run-git-async "submodule" "init" "--" modules)))

;;;###autoload (autoload 'magit2-submodule-populate "magit2-submodule" nil t)
(transient-define-suffix magit2-submodule-populate (modules)
  "Create MODULES working directories, checking out the recorded commits.

With a prefix argument act on all suitable modules.  Otherwise,
if the region selects modules, then act on those.  Otherwise, if
there is a module at point, then act on that.  Otherwise read a
single module from the user."
  ;; This is the command that actually "initializes" modules.
  ;; A module is initialized when it has a working directory,
  ;; a gitlink, and a .gitmodules entry.
  :description "Populate       git submodule update --init"
  (interactive
   (list (magit2-module-confirm "Populate" 'magit2-module-no-worktree-p)))
  (magit2-with-toplevel
    (magit2-run-git-async "submodule" "update" "--init" "--" modules)))

;;;###autoload (autoload 'magit2-submodule-update "magit2-submodule" nil t)
(transient-define-suffix magit2-submodule-update (modules args)
  "Update MODULES by checking out the recorded commits.

With a prefix argument act on all suitable modules.  Otherwise,
if the region selects modules, then act on those.  Otherwise, if
there is a module at point, then act on that.  Otherwise read a
single module from the user."
  ;; Unlike `git-submodule's `update' command ours can only update
  ;; "initialized" modules by checking out other commits but not
  ;; "initialize" modules by creating the working directories.
  ;; To do the latter we provide the "setup" command.
  :class 'magit2--git-submodule-suffix
  :description "Update         git submodule update [--force] [--no-fetch]
                     [--remote] [--recursive] [--checkout|--rebase|--merge]"
  (interactive
   (list (magit2-module-confirm "Update" 'magit2-module-worktree-p)
         (magit2-submodule-arguments
          "--force" "--remote" "--recursive" "--checkout" "--rebase" "--merge"
          "--no-fetch")))
  (magit2-with-toplevel
    (magit2-run-git-async "submodule" "update" args "--" modules)))

;;;###autoload (autoload 'magit2-submodule-synchronize "magit2-submodule" nil t)
(transient-define-suffix magit2-submodule-synchronize (modules args)
  "Synchronize url configuration of MODULES.

With a prefix argument act on all suitable modules.  Otherwise,
if the region selects modules, then act on those.  Otherwise, if
there is a module at point, then act on that.  Otherwise read a
single module from the user."
  :class 'magit2--git-submodule-suffix
  :description "Synchronize    git submodule sync [--recursive]"
  (interactive
   (list (magit2-module-confirm "Synchronize" 'magit2-module-worktree-p)
         (magit2-submodule-arguments "--recursive")))
  (magit2-with-toplevel
    (magit2-run-git-async "submodule" "sync" args "--" modules)))

;;;###autoload (autoload 'magit2-submodule-unpopulate "magit2-submodule" nil t)
(transient-define-suffix magit2-submodule-unpopulate (modules args)
  "Remove working directories of MODULES.

With a prefix argument act on all suitable modules.  Otherwise,
if the region selects modules, then act on those.  Otherwise, if
there is a module at point, then act on that.  Otherwise read a
single module from the user."
  ;; Even though a package is "uninitialized" (it has no worktree)
  ;; the super-projects $GIT_DIR/config may never-the-less set the
  ;; module's url.  This may happen if you `deinit' and then `init'
  ;; to register (NOT initialize).  Because the purpose of `deinit'
  ;; is to remove the working directory AND to remove the url, this
  ;; command does not limit itself to modules that have no working
  ;; directory.
  :class 'magit2--git-submodule-suffix
  :description "Unpopulate     git submodule deinit [--force]"
  (interactive
   (list (magit2-module-confirm "Unpopulate")
         (magit2-submodule-arguments "--force")))
  (magit2-with-toplevel
    (magit2-run-git-async "submodule" "deinit" args "--" modules)))

;;;###autoload
(defun magit2-submodule-remove (modules args trash-gitdirs)
  "Unregister MODULES and remove their working directories.

For safety reasons, do not remove the gitdirs and if a module has
uncommitted changes, then do not remove it at all.  If a module's
gitdir is located inside the working directory, then move it into
the gitdir of the superproject first.

With the \"--force\" argument offer to remove dirty working
directories and with a prefix argument offer to delete gitdirs.
Both actions are very dangerous and have to be confirmed.  There
are additional safety precautions in place, so you might be able
to recover from making a mistake here, but don't count on it."
  (interactive
   (list (if-let ((modules (magit2-region-values 'magit2-module-section t)))
             (magit2-confirm 'remove-modules nil "Remove %i modules" nil modules)
           (list (magit2-read-module-path "Remove module")))
         (magit2-submodule-arguments "--force")
         current-prefix-arg))
  (when (magit2-git-version< "2.12.0")
    (error "This command requires Git v2.12.0"))
  (when magit2-submodule-remove-trash-gitdirs
    (setq trash-gitdirs t))
  (magit2-with-toplevel
    (when-let
        ((modified
          (-filter (lambda (module)
                     (let ((default-directory (file-name-as-directory
                                               (expand-file-name module))))
                       (and (cddr (directory-files default-directory))
                            (magit2-anything-modified-p))))
                   modules)))
      (if (member "--force" args)
          (if (magit2-confirm 'remove-dirty-modules
                "Remove dirty module %s"
                "Remove %i dirty modules"
                t modified)
              (dolist (module modified)
                (let ((default-directory (file-name-as-directory
                                          (expand-file-name module))))
                  (magit2-git "stash" "push"
                             "-m" "backup before removal of this module")))
            (setq modules (cl-set-difference modules modified :test #'equal)))
        (if (cdr modified)
            (message "Omitting %s modules with uncommitted changes: %s"
                     (length modified)
                     (mapconcat #'identity modified ", "))
          (message "Omitting module %s, it has uncommitted changes"
                   (car modified)))
        (setq modules (cl-set-difference modules modified :test #'equal))))
    (when modules
      (let ((alist
             (and trash-gitdirs
                  (--map (split-string it "\0")
                         (magit2-git-lines "submodule" "foreach" "-q"
                                          "printf \"$sm_path\\0$name\n\"")))))
        (magit2-git "submodule" "absorbgitdirs" "--" modules)
        (magit2-git "submodule" "deinit" args "--" modules)
        (magit2-git "rm" args "--" modules)
        (when (and trash-gitdirs
                   (magit2-confirm 'trash-module-gitdirs
                     "Trash gitdir of module %s"
                     "Trash gitdirs of %i modules"
                     t modules))
          (dolist (module modules)
            (if-let ((name (cadr (assoc module alist))))
                ;; Disregard if `magit2-delete-by-moving-to-trash'
                ;; is nil.  Not doing so would be too dangerous.
                (delete-directory (magit2-git-dir
                                   (convert-standard-filename
                                    (concat "modules/" name)))
                                  t t)
              (error "BUG: Weird module name and/or path for %s" module)))))
      (magit2-refresh))))

;;; Sections

;;;###autoload
(defun magit2-insert-modules ()
  "Insert submodule sections.
Hook `magit2-module-sections-hook' controls which module sections
are inserted, and option `magit2-module-sections-nested' controls
whether they are wrapped in an additional section."
  (when-let ((modules (magit2-list-module-paths)))
    (if magit2-module-sections-nested
        (magit2-insert-section (modules nil t)
          (magit2-insert-heading
            (format "%s (%s)"
                    (propertize "Modules"
                                'font-lock-face 'magit2-section-heading)
                    (length modules)))
          (magit2-insert-section-body
            (magit2--insert-modules)))
      (magit2--insert-modules))))

(defun magit2--insert-modules (&optional _section)
  (magit2-run-section-hook 'magit2-module-sections-hook))

;;;###autoload
(defun magit2-insert-modules-overview ()
  "Insert sections for all modules.
For each section insert the path and the output of `git describe --tags',
or, failing that, the abbreviated HEAD commit hash."
  (when-let ((modules (magit2-list-module-paths)))
    (magit2-insert-section (modules nil t)
      (magit2-insert-heading
        (format "%s (%s)"
                (propertize "Modules overview"
                            'font-lock-face 'magit2-section-heading)
                (length modules)))
      (magit2-insert-section-body
        (magit2--insert-modules-overview)))))

(defvar magit2-modules-overview-align-numbers t)

(defun magit2--insert-modules-overview (&optional _section)
  (magit2-with-toplevel
    (let* ((modules (magit2-list-module-paths))
           (path-format (format "%%-%is "
                                (min (apply 'max (mapcar 'length modules))
                                     (/ (window-width) 2))))
           (branch-format (format "%%-%is " (min 25 (/ (window-width) 3)))))
      (dolist (module modules)
        (let ((default-directory
                (expand-file-name (file-name-as-directory module))))
          (magit2-insert-section (magit2-module-section module t)
            (insert (propertize (format path-format module)
                                'font-lock-face 'magit2-diff-file-heading))
            (if (not (file-exists-p ".git"))
                (insert "(unpopulated)")
              (insert (format
                       branch-format
                       (--if-let (magit2-get-current-branch)
                           (propertize it 'font-lock-face 'magit2-branch-local)
                         (propertize "(detached)" 'font-lock-face 'warning))))
              (--if-let (magit2-git-string "describe" "--tags")
                  (progn (when (and magit2-modules-overview-align-numbers
                                    (string-match-p "\\`[0-9]" it))
                           (insert ?\s))
                         (insert (propertize it 'font-lock-face 'magit2-tag)))
                (--when-let (magit2-rev-format "%h")
                  (insert (propertize it 'font-lock-face 'magit2-hash)))))
            (insert ?\n))))))
  (insert ?\n))

(defvar magit2-modules-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-list-submodules)
    map)
  "Keymap for `modules' sections.")

(defvar magit2-module-section-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-file-section-map)
    (define-key map (kbd "C-j") 'magit2-submodule-visit)
    (define-key map [C-return]  'magit2-submodule-visit)
    (define-key map [remap magit2-visit-thing]  'magit2-submodule-visit)
    (define-key map [remap magit2-delete-thing] 'magit2-submodule-unpopulate)
    (define-key map "K" 'magit2-file-untrack)
    (define-key map "R" 'magit2-file-rename)
    map)
  "Keymap for `module' sections.")

(defun magit2-submodule-visit (module &optional other-window)
  "Visit MODULE by calling `magit2-status' on it.
Offer to initialize MODULE if it's not checked out yet.
With a prefix argument, visit in another window."
  (interactive (list (or (magit2-section-value-if 'module)
                         (magit2-read-module-path "Visit module"))
                     current-prefix-arg))
  (magit2-with-toplevel
    (let ((path (expand-file-name module)))
      (cond
       ((file-exists-p (expand-file-name ".git" module))
        (magit2-diff-visit-directory path other-window))
       ((y-or-n-p (format "Initialize submodule '%s' first?" module))
        (magit2-run-git-async "submodule" "update" "--init" "--" module)
        (set-process-sentinel
         magit2-this-process
         (lambda (process event)
           (let ((magit2-process-raise-error t))
             (magit2-process-sentinel process event))
           (when (and (eq (process-status      process) 'exit)
                      (=  (process-exit-status process) 0))
             (magit2-diff-visit-directory path other-window)))))
       ((file-exists-p path)
        (dired-jump other-window (concat path "/.")))))))

;;;###autoload
(defun magit2-insert-modules-unpulled-from-upstream ()
  "Insert sections for modules that haven't been pulled from the upstream.
These sections can be expanded to show the respective commits."
  (magit2--insert-modules-logs "Modules unpulled from @{upstream}"
                              'modules-unpulled-from-upstream
                              "HEAD..@{upstream}"))

;;;###autoload
(defun magit2-insert-modules-unpulled-from-pushremote ()
  "Insert sections for modules that haven't been pulled from the push-remote.
These sections can be expanded to show the respective commits."
  (magit2--insert-modules-logs "Modules unpulled from @{push}"
                              'modules-unpulled-from-pushremote
                              "HEAD..@{push}"))

;;;###autoload
(defun magit2-insert-modules-unpushed-to-upstream ()
  "Insert sections for modules that haven't been pushed to the upstream.
These sections can be expanded to show the respective commits."
  (magit2--insert-modules-logs "Modules unmerged into @{upstream}"
                              'modules-unpushed-to-upstream
                              "@{upstream}..HEAD"))

;;;###autoload
(defun magit2-insert-modules-unpushed-to-pushremote ()
  "Insert sections for modules that haven't been pushed to the push-remote.
These sections can be expanded to show the respective commits."
  (magit2--insert-modules-logs "Modules unpushed to @{push}"
                              'modules-unpushed-to-pushremote
                              "@{push}..HEAD"))

(defun magit2--insert-modules-logs (heading type range)
  "For internal use, don't add to a hook."
  (unless (magit2-ignore-submodules-p)
    (when-let ((modules (magit2-list-module-paths)))
      (magit2-insert-section section ((eval type) nil t)
        (string-match "\\`\\(.+\\) \\([^ ]+\\)\\'" heading)
        (magit2-insert-heading
          (propertize (match-string 1 heading)
                      'font-lock-face 'magit2-section-heading)
          " "
          (propertize (match-string 2 heading)
                      'font-lock-face 'magit2-branch-remote)
          ":")
        (magit2-with-toplevel
          (dolist (module modules)
            (when (magit2-module-worktree-p module)
              (let ((default-directory
                      (expand-file-name (file-name-as-directory module))))
                (when (magit2-file-accessible-directory-p default-directory)
                  (magit2-insert-section sec (magit2-module-section module t)
                    (magit2-insert-heading
                      (propertize module
                                  'font-lock-face 'magit2-diff-file-heading)
                      ":")
                    (oset sec range range)
                    (magit2-git-wash
                        (apply-partially 'magit2-log-wash-log 'module)
                      "-c" "push.default=current" "log" "--oneline" range)
                    (when (> (point)
                             (oref sec content))
                      (delete-char -1))))))))
        (if (> (point)
               (oref section content))
            (insert ?\n)
          (magit2-cancel-section))))))

;;; List

;;;###autoload
(defun magit2-list-submodules ()
  "Display a list of the current repository's submodules."
  (interactive)
  (magit2-submodule-list-setup magit2-submodule-list-columns))

(defvar magit2-submodule-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-repolist-mode-map)
    map)
  "Local keymap for Magit-Submodule-List mode buffers.")

(define-derived-mode magit2-submodule-list-mode tabulated-list-mode "Modules"
  "Major mode for browsing a list of Git submodules."
  :group 'magit2-repolist-mode
  (setq-local x-stretch-cursor nil)
  (setq tabulated-list-padding 0)
  (add-hook 'tabulated-list-revert-hook 'magit2-submodule-list-refresh nil t)
  (setq imenu-prev-index-position-function
        #'magit2-imenu--submodule-prev-index-position-function)
  (setq imenu-extract-index-name-function
        #'magit2-imenu--submodule-extract-index-name-function))

(defvar-local magit2-submodule-list-predicate nil)

(defun magit2-submodule-list-setup (columns &optional predicate)
  (magit2-display-buffer
   (or (magit2-get-mode-buffer 'magit2-submodule-list-mode)
       (magit2-with-toplevel
         (magit2-generate-new-buffer 'magit2-submodule-list-mode))))
  (magit2-submodule-list-mode)
  (setq-local magit2-repolist-columns columns)
  (setq-local magit2-repolist-sort-key magit2-submodule-list-sort-key)
  (setq-local magit2-submodule-list-predicate predicate)
  (magit2-repolist-setup-1)
  (magit2-submodule-list-refresh))

(defun magit2-submodule-list-refresh ()
  (setq tabulated-list-entries
        (-keep (lambda (module)
                 (let ((default-directory
                         (expand-file-name (file-name-as-directory module))))
                   (and (file-exists-p ".git")
                        (or (not magit2-submodule-list-predicate)
                            (funcall magit2-submodule-list-predicate module))
                        (list module
                              (vconcat
                               (mapcar (pcase-lambda (`(,title ,width ,fn ,props))
                                         (or (funcall fn `((:path  ,module)
                                                           (:title ,title)
                                                           (:width ,width)
                                                           ,@props))
                                             ""))
                                       magit2-repolist-columns))))))
               (magit2-list-module-paths)))
  (message "Listing submodules...")
  (tabulated-list-init-header)
  (tabulated-list-print t)
  (message "Listing submodules...done"))

(defun magit2-modulelist-column-path (spec)
  "Insert the relative path of the submodule."
  (cadr (assq :path spec)))

;;;; Imenu Support

(defun magit2-imenu--submodule-prev-index-position-function ()
  "Move point to previous line in magit2-submodule-list buffer.
Used as a value for `imenu-prev-index-position-function'."
  (unless (bobp)
    (forward-line -1)))

(defun magit2-imenu--submodule-extract-index-name-function ()
  "Return imenu name for line at point.
Point should be at the beginning of the line.  This function
is used as a value for `imenu-extract-index-name-function'."
  (car (tabulated-list-get-entry)))

;;; Utilities

(defun magit2-submodule--maybe-reuse-gitdir (name path)
  (let ((gitdir
         (magit2-git-dir (convert-standard-filename (concat "modules/" name)))))
    (when (and (file-exists-p gitdir)
               (not (file-exists-p path)))
      (pcase (read-char-choice
              (concat
               gitdir " already exists.\n"
               "Type [u] to use the existing gitdir and create the working tree\n"
               "     [r] to rename the existing gitdir and clone again\n"
               "     [t] to trash the existing gitdir and clone again\n"
               "   [C-g] to abort ")
              '(?u ?r ?t))
        (?u (magit2-submodule--restore-worktree (expand-file-name path) gitdir))
        (?r (rename-file gitdir (concat gitdir "-"
                                        (format-time-string "%F-%T"))))
        (?t (delete-directory gitdir t t))))))

(defun magit2-submodule--restore-worktree (worktree gitdir)
  (make-directory worktree t)
  (with-temp-file (expand-file-name ".git" worktree)
    (insert "gitdir: " (file-relative-name gitdir worktree) "\n"))
  (let ((default-directory worktree))
    (magit2-call-git "reset" "--hard" "HEAD" "--")))

;;; _
(provide 'magit2-submodule)
;;; magit2-submodule.el ends here
