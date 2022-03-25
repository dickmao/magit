;;; magit2-repos.el --- listing repositories  -*- lexical-binding: t -*-

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

;; This library implements support for listing repositories.  This
;; includes getting a Lisp list of known repositories as well as a
;; mode for listing repositories in a buffer.

;;; Code:

(require 'magit2-core)

(declare-function magit2-status-setup-buffer "magit2-status" (&optional directory))

(defvar x-stretch-cursor)

;;; Options

(defcustom magit2-repository-directories nil
  "List of directories that are or contain Git repositories.

Each element has the form (DIRECTORY . DEPTH).  DIRECTORY has
to be a directory or a directory file-name, a string.  DEPTH,
an integer, specifies the maximum depth to look for Git
repositories.  If it is 0, then only add DIRECTORY itself.

This option controls which repositories are being listed by
`magit2-list-repositories'.  It also affects `magit2-status'
\(which see) in potentially surprising ways."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-essentials
  :type '(repeat (cons directory (integer :tag "Depth"))))

(defgroup magit2-repolist nil
  "List repositories in a buffer."
  :link '(info-link "(magit2)Repository List")
  :group 'magit2-modes)

(defcustom magit2-repolist-mode-hook '(hl-line-mode)
  "Hook run after entering Magit-Repolist mode."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-repolist
  :type 'hook
  :get 'magit2-hook-custom-get
  :options '(hl-line-mode))

(defcustom magit2-repolist-columns
  '(("Name"    25 magit2-repolist-column-ident nil)
    ("Version" 25 magit2-repolist-column-version
     ((:sort magit2-repolist-version<)))
    ("B<U"      3 magit2-repolist-column-unpulled-from-upstream
     (;; (:help-echo "Upstream changes not in branch")
      (:right-align t)
      (:sort <)))
    ("B>U"      3 magit2-repolist-column-unpushed-to-upstream
     (;; (:help-echo "Local changes not in upstream")
      (:right-align t)
      (:sort <)))
    ("Path"    99 magit2-repolist-column-path nil))
  "List of columns displayed by `magit2-list-repositories'.

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
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-repolist
  :type '(repeat (list :tag "Column"
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

(defcustom magit2-repolist-column-flag-alist
  '((magit2-untracked-files . "N")
    (magit2-unstaged-files . "U")
    (magit2-staged-files . "S"))
  "Association list of predicates and flags for `magit2-repolist-column-flag'.

Each element is of the form (FUNCTION . FLAG).  Each FUNCTION is
called with no arguments, with `default-directory' bound to the
top level of a repository working tree, until one of them returns
a non-nil value.  FLAG corresponding to that function is returned
as the value of `magit2-repolist-column-flag'."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-repolist
  :type '(alist :key-type (function :tag "Predicate Function")
                :value-type (string :tag "Flag")))

(defcustom magit2-repolist-sort-key '("Path" . nil)
  "Initial sort key for buffer created by `magit2-list-repositories'.
If nil, no additional sorting is performed.  Otherwise, this
should be a cons cell (NAME . FLIP).  NAME is a string matching
one of the column names in `magit2-repolist-columns'.  FLIP, if
non-nil, means to invert the resulting sort."
  :package-version '(magit2 . "3.2.0")
  :group 'magit2-repolist
  :type '(choice (const nil)
                 (cons (string :tag "Column name")
                       (boolean :tag "Flip order"))))

;;; List Repositories
;;;; List Commands
;;;###autoload
(defun magit2-list-repositories ()
  "Display a list of repositories.

Use the options `magit2-repository-directories' to control which
repositories are displayed."
  (interactive)
  (magit2-repolist-setup (default-value 'magit2-repolist-columns)))

;;;; Mode Commands

(defun magit2-repolist-status (&optional _button)
  "Show the status for the repository at point."
  (interactive)
  (--if-let (tabulated-list-get-id)
      (magit2-status-setup-buffer (expand-file-name it))
    (user-error "There is no repository at point")))

(defun magit2-repolist-mark ()
  "Mark a repository and move to the next line."
  (interactive)
  (magit2-repolist--ensure-padding)
  (tabulated-list-put-tag "*" t))

(defun magit2-repolist-unmark ()
  "Unmark a repository and move to the next line."
  (interactive)
  (tabulated-list-put-tag " " t))

(defun magit2-repolist-fetch (repos)
  "Fetch all marked or listed repositories."
  (interactive (list (magit2-repolist--get-repos ?*)))
  (run-hooks 'magit2-credential-hook)
  (magit2-repolist--mapc (apply-partially #'magit2-run-git "remote" "update")
                        repos "Fetching in %s..."))

(defun magit2-repolist-find-file-other-frame (repos file)
  "Find a file in all marked or listed repositories."
  (interactive (list (magit2-repolist--get-repos ?*)
                     (read-string "Find file in repositories: ")))
  (magit2-repolist--mapc (apply-partially #'find-file-other-frame file) repos))

(defun magit2-repolist--ensure-padding ()
  "Set `tabulated-list-padding' to 2, unless that is already non-zero."
  (when (zerop tabulated-list-padding)
    (setq tabulated-list-padding 2)
    (tabulated-list-init-header)
    (tabulated-list-print t)))

(defun magit2-repolist--get-repos (&optional char)
  "Return marked repositories or `all' if none are marked.
If optional CHAR is non-nil, then only return repositories
marked with that character.  If no repositories are marked
then ask whether to act on all repositories instead."
  (or (magit2-repolist--marked-repos char)
      (if (magit2-confirm 'repolist-all
            "Nothing selected.  Act on ALL displayed repositories")
          'all
        (user-error "Abort"))))

(defun magit2-repolist--marked-repos (&optional char)
  "Return marked repositories.
If optional CHAR is non-nil, then only return repositories
marked with that character."
  (let (c list)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (setq c (char-after))
        (unless (eq c ?\s)
          (if char
              (when (eq c char)
                (push (tabulated-list-get-id) list))
            (push (cons c (tabulated-list-get-id)) list)))
        (forward-line)))
    list))

(defun magit2-repolist--mapc (fn repos &optional msg)
  "Apply FN to each directory in REPOS for side effects only.
If REPOS is the symbol `all', then call FN for all displayed
repositories.  When FN is called, `default-directory' is bound to
the top-level directory of the current repository.  If optional
MSG is non-nil then that is displayed around each call to FN.
If it contains \"%s\" then the directory is substituted for that."
  (when (eq repos 'all)
    (setq repos nil)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (push (tabulated-list-get-id) repos)
        (forward-line)))
    (setq repos (nreverse repos)))
  (let ((base default-directory)
        (len (length repos))
        (i 0))
    (mapc (lambda (repo)
            (let ((default-directory
                   (file-name-as-directory (expand-file-name repo base))))
              (if msg
                  (let ((msg (concat (format "(%s/%s) " (cl-incf i) len)
                                     (format msg default-directory))))
                    (message msg)
                    (funcall fn)
                    (message (concat msg "done")))
                (funcall fn))))
          repos)))

;;;; Mode

(defvar magit2-repolist-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "C-m") 'magit2-repolist-status)
    (define-key map (kbd "m")   'magit2-repolist-mark)
    (define-key map (kbd "u")   'magit2-repolist-unmark)
    (define-key map (kbd "f")   'magit2-repolist-fetch)
    (define-key map (kbd "5")   'magit2-repolist-find-file-other-frame)
    map)
  "Local keymap for Magit-Repolist mode buffers.")

(define-derived-mode magit2-repolist-mode tabulated-list-mode "Repos"
  "Major mode for browsing a list of Git repositories."
  (setq-local x-stretch-cursor  nil)
  (setq tabulated-list-padding  0)
  (add-hook 'tabulated-list-revert-hook 'magit2-repolist-refresh nil t)
  (setq imenu-prev-index-position-function
        'magit2-imenu--repolist-prev-index-position-function)
  (setq imenu-extract-index-name-function
        'magit2-imenu--repolist-extract-index-name-function))

(defun magit2-repolist-setup (columns)
  (unless magit2-repository-directories
    (user-error "You need to customize `magit2-repository-directories' %s"
                "before you can list repositories"))
  (with-current-buffer (get-buffer-create "*Magit Repositories*")
    (magit2-repolist-mode)
    (setq-local magit2-repolist-columns columns)
    (magit2-repolist-setup-1)
    (magit2-repolist-refresh)
    (switch-to-buffer (current-buffer))))

(defun magit2-repolist-setup-1 ()
  (unless tabulated-list-sort-key
    (setq tabulated-list-sort-key
          (pcase-let ((`(,column . ,flip) magit2-repolist-sort-key))
            (cons (or (car (assoc column magit2-repolist-columns))
                      (caar magit2-repolist-columns))
                  flip))))
  (setq tabulated-list-format
        (vconcat (-map-indexed
                  (lambda (idx column)
                    (pcase-let* ((`(,title ,width ,_fn ,props) column)
                                 (sort-set (assoc :sort props))
                                 (sort-fn (cadr sort-set)))
                      (nconc (list title width
                                   (cond ((eq sort-fn '<)
                                          (magit2-repolist-make-sorter
                                           sort-fn #'string-to-number idx))
                                         ((eq sort-fn 'magit2-repolist-version<)
                                          (magit2-repolist-make-sorter
                                           sort-fn #'identity idx))
                                         (sort-fn sort-fn)
                                         (sort-set nil)
                                         (t t)))
                             (-flatten props))))
                  magit2-repolist-columns))))

(defun magit2-repolist-refresh ()
  (setq tabulated-list-entries
        (mapcar (pcase-lambda (`(,id . ,path))
                  (let ((default-directory path))
                    (list path
                          (vconcat
                           (mapcar (pcase-lambda (`(,title ,width ,fn ,props))
                                     (or (funcall fn `((:id ,id)
                                                       (:title ,title)
                                                       (:width ,width)
                                                       ,@props))
                                         ""))
                                   magit2-repolist-columns)))))
                (magit2-list-repos-uniquify
                 (--map (cons (file-name-nondirectory (directory-file-name it))
                              it)
                        (magit2-list-repos)))))
  (message "Listing repositories...")
  (tabulated-list-init-header)
  (tabulated-list-print t)
  (message "Listing repositories...done"))

;;;; Columns

(defun magit2-repolist-make-sorter (sort-predicate convert-cell column-idx)
  "Return a function suitable as a sorter for tabulated lists.
See `tabulated-list--get-sorter'.  Given a more reasonable API
this would not be necessary and one could just use SORT-PREDICATE
directly.  CONVERT-CELL can be used to turn the cell value, which
is always a string back into e.g. a number.  COLUMN-IDX has to be
the index of the column that uses the returned sorter function."
  (lambda (a b)
    (funcall sort-predicate
             (funcall convert-cell (aref (cadr a) column-idx))
             (funcall convert-cell (aref (cadr b) column-idx)))))

(defun magit2-repolist-column-ident (spec)
  "Insert the identification of the repository.
Usually this is just its basename."
  (cadr (assq :id spec)))

(defun magit2-repolist-column-path (_)
  "Insert the absolute path of the repository."
  (abbreviate-file-name default-directory))

(defvar magit2-repolist-column-version-regexp "\
\\(?1:-\\(?2:[0-9]*\\)\
\\(?3:-g[a-z0-9]*\\)\\)?\
\\(?:-\\(?4:dirty\\)\\)\
?\\'")

(defvar magit2-repolist-column-version-resume-regexp
   "\\`Resume development\\'")

(defun magit2-repolist-column-version (_)
  "Insert a description of the repository's `HEAD' revision."
  (when-let ((v (or (magit2-git-string "describe" "--tags" "--dirty")
                    ;; If there are no tags, use the date in MELPA format.
                    (magit2-git-string "show" "--no-patch" "--format=%cd-g%h"
                                      "--date=format:%Y%m%d.%H%M"))))
    (save-match-data
      (when (string-match magit2-repolist-column-version-regexp v)
        (magit2--put-face (match-beginning 0) (match-end 0) 'shadow v)
        (when (match-end 2)
          (magit2--put-face (match-beginning 2) (match-end 2) 'bold v))
        (when (match-end 4)
          (magit2--put-face (match-beginning 4) (match-end 4) 'error v))
        (when (and (equal (match-string 2 v) "1")
                   (string-match-p magit2-repolist-column-version-resume-regexp
                                   (magit2-rev-format "%s")))
          (setq v (replace-match (propertize "+" 'face 'shadow) t t v 1))))
      (if (and v (string-match "\\`[0-9]" v))
          (concat " " v)
        (when (and v (string-match "\\`[^0-9]+" v))
          (magit2--put-face 0 (match-end 0) 'shadow v))
        v))))

(defun magit2-repolist-version< (a b)
  (save-match-data
    (let ((re "[0-9]+\\(\\.[0-9]*\\)*"))
      (setq a (and (string-match re a) (match-string 0 a)))
      (setq b (and (string-match re b) (match-string 0 b)))
      (cond ((and a b) (version< a b))
            (b nil)
            (t t)))))

(defun magit2-repolist-column-branch (_)
  "Insert the current branch."
  (let ((branch (magit2-get-current-branch)))
    (if (member branch magit2-main-branch-names)
        (magit2--propertize-face branch 'shadow)
      branch)))

(defun magit2-repolist-column-upstream (_)
  "Insert the upstream branch of the current branch."
  (magit2-get-upstream-branch))

(defun magit2-repolist-column-flag (_)
  "Insert a flag as specified by `magit2-repolist-column-flag-alist'.

By default this indicates whether there are uncommitted changes.
- N if there is at least one untracked file.
- U if there is at least one unstaged file.
- S if there is at least one staged file.
Only one letter is shown, the first that applies."
  (seq-some (pcase-lambda (`(,fun . ,flag))
              (and (funcall fun) flag))
            magit2-repolist-column-flag-alist))

(defun magit2-repolist-column-flags (_)
  "Insert all flags as specified by `magit2-repolist-column-flag-alist'.
This is an alternative to function `magit2-repolist-column-flag',
which only lists the first one found."
  (mapconcat (pcase-lambda (`(,fun . ,flag))
               (if (funcall fun) flag " "))
             magit2-repolist-column-flag-alist
             ""))

(defun magit2-repolist-column-unpulled-from-upstream (spec)
  "Insert number of upstream commits not in the current branch."
  (--when-let (magit2-get-upstream-branch)
    (magit2-repolist-insert-count (cadr (magit2-rev-diff-count "HEAD" it)) spec)))

(defun magit2-repolist-column-unpulled-from-pushremote (spec)
  "Insert number of commits in the push branch but not the current branch."
  (--when-let (magit2-get-push-branch nil t)
    (magit2-repolist-insert-count (cadr (magit2-rev-diff-count "HEAD" it)) spec)))

(defun magit2-repolist-column-unpushed-to-upstream (spec)
  "Insert number of commits in the current branch but not its upstream."
  (--when-let (magit2-get-upstream-branch)
    (magit2-repolist-insert-count (car (magit2-rev-diff-count "HEAD" it)) spec)))

(defun magit2-repolist-column-unpushed-to-pushremote (spec)
  "Insert number of commits in the current branch but not its push branch."
  (--when-let (magit2-get-push-branch nil t)
    (magit2-repolist-insert-count (car (magit2-rev-diff-count "HEAD" it)) spec)))

(defun magit2-repolist-column-branches (spec)
  "Insert number of branches."
  (magit2-repolist-insert-count (length (magit2-list-local-branches))
                               `((:normal-count 1) ,@spec)))

(defun magit2-repolist-column-stashes (spec)
  "Insert number of stashes."
  (magit2-repolist-insert-count (length (magit2-list-stashes)) spec))

(defun magit2-repolist-insert-count (n spec)
  (magit2--propertize-face
   (if (and  (> n 9) (= (cadr (assq :width spec)) 1))
       "+"
     (number-to-string n))
   (if (> n (or (cadr (assq :normal-count spec)) 0)) 'bold 'shadow)))

;;;; Imenu Support

(defun magit2-imenu--repolist-prev-index-position-function ()
  "Move point to previous line in magit2-repolist buffer.
Used as a value for `imenu-prev-index-position-function'."
  (unless (bobp)
    (forward-line -1)))

(defun magit2-imenu--repolist-extract-index-name-function ()
  "Return imenu name for line at point.
Point should be at the beginning of the line.  This function
is used as a value for `imenu-extract-index-name-function'."
  (let ((entry (tabulated-list-get-entry)))
    (format "%s (%s)"
            (car entry)
            (car (last entry)))))

;;; Read Repository

(defun magit2-read-repository (&optional read-directory-name)
  "Read a Git repository in the minibuffer, with completion.

The completion choices are the basenames of top-levels of
repositories found in the directories specified by option
`magit2-repository-directories'.  In case of name conflicts
the basenames are prefixed with the name of the respective
parent directories.  The returned value is the actual path
to the selected repository.

If READ-DIRECTORY-NAME is non-nil or no repositories can be
found based on the value of `magit2-repository-directories',
then read an arbitrary directory using `read-directory-name'
instead."
  (if-let ((repos (and (not read-directory-name)
                       magit2-repository-directories
                       (magit2-repos-alist))))
      (let ((reply (magit2-completing-read "Git repository" repos)))
        (file-name-as-directory
         (or (cdr (assoc reply repos))
             (if (file-directory-p reply)
                 (expand-file-name reply)
               (user-error "Not a repository or a directory: %s" reply)))))
    (file-name-as-directory
     (read-directory-name "Git repository: "
                          (or (magit2-toplevel) default-directory)))))

(defun magit2-list-repos ()
  (cl-mapcan (pcase-lambda (`(,dir . ,depth))
               (magit2-list-repos-1 dir depth))
             magit2-repository-directories))

(defun magit2-list-repos-1 (directory depth)
  (cond ((file-readable-p (expand-file-name ".git" directory))
         (list (file-name-as-directory directory)))
        ((and (> depth 0) (magit2-file-accessible-directory-p directory))
         (--mapcat (and (file-directory-p it)
                        (magit2-list-repos-1 it (1- depth)))
                   (directory-files directory t
                                    directory-files-no-dot-files-regexp t)))))

(defun magit2-list-repos-uniquify (alist)
  (let (result (dict (make-hash-table :test 'equal)))
    (dolist (a (delete-dups alist))
      (puthash (car a) (cons (cdr a) (gethash (car a) dict)) dict))
    (maphash
     (lambda (key value)
       (if (= (length value) 1)
           (push (cons key (car value)) result)
         (setq result
               (append result
                       (magit2-list-repos-uniquify
                        (--map (cons (concat
                                      key "\\"
                                      (file-name-nondirectory
                                       (directory-file-name
                                        (substring it 0 (- (1+ (length key)))))))
                                     it)
                               value))))))
     dict)
    result))

(defun magit2-repos-alist ()
  (magit2-list-repos-uniquify
   (--map (cons (file-name-nondirectory (directory-file-name it)) it)
          (magit2-list-repos))))

;;; _
(provide 'magit2-repos)
;;; magit2-repos.el ends here
