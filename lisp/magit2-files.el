;;; magit2-files.el --- finding files  -*- lexical-binding: t -*-

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

;; This library implements support for finding blobs, staged files,
;; and Git configuration files.  It also implements modes useful in
;; buffers visiting files and blobs, and the commands used by those
;; modes.

;;; Code:

(require 'magit2)

;;; Find Blob

(defvar magit2-find-file-hook nil)
(add-hook 'magit2-find-file-hook #'magit2-blob-mode)

;;;###autoload
(defun magit2-find-file (rev file)
  "View FILE from REV.
Switch to a buffer visiting blob REV:FILE, creating one if none
already exists.  If prior to calling this command the current
buffer and/or cursor position is about the same file, then go
to the line and column corresponding to that location."
  (interactive (magit2-find-file-read-args "Find file"))
  (magit2-find-file--internal rev file #'pop-to-buffer-same-window))

;;;###autoload
(defun magit2-find-file-other-window (rev file)
  "View FILE from REV, in another window.
Switch to a buffer visiting blob REV:FILE, creating one if none
already exists.  If prior to calling this command the current
buffer and/or cursor position is about the same file, then go to
the line and column corresponding to that location."
  (interactive (magit2-find-file-read-args "Find file in other window"))
  (magit2-find-file--internal rev file #'switch-to-buffer-other-window))

;;;###autoload
(defun magit2-find-file-other-frame (rev file)
  "View FILE from REV, in another frame.
Switch to a buffer visiting blob REV:FILE, creating one if none
already exists.  If prior to calling this command the current
buffer and/or cursor position is about the same file, then go to
the line and column corresponding to that location."
  (interactive (magit2-find-file-read-args "Find file in other frame"))
  (magit2-find-file--internal rev file #'switch-to-buffer-other-frame))

(defun magit2-find-file-read-args (prompt)
  (let ((pseudo-revs '("{worktree}" "{index}")))
    (if-let ((rev (magit2-completing-read "Find file from revision"
                                         (append pseudo-revs
                                                 (magit2-list-refnames nil t))
                                         nil nil nil 'magit2-revision-history
                                         (or (magit2-branch-or-commit-at-point)
                                             (magit2-get-current-branch)))))
        (list rev (magit2-read-file-from-rev (if (member rev pseudo-revs)
                                                "HEAD"
                                              rev)
                                            prompt))
      (user-error "Nothing selected"))))

(defun magit2-find-file--internal (rev file fn)
  (let ((buf (magit2-find-file-noselect rev file))
        line col)
    (when-let ((visited-file (magit2-file-relative-name)))
      (setq line (line-number-at-pos))
      (setq col (current-column))
      (cond
       ((not (equal visited-file file)))
       ((equal magit2-buffer-revision rev))
       ((equal rev "{worktree}")
        (setq line (magit2-diff-visit--offset file magit2-buffer-revision line)))
       ((equal rev "{index}")
        (setq line (magit2-diff-visit--offset file nil line)))
       (magit2-buffer-revision
        (setq line (magit2-diff-visit--offset
                    file (concat magit2-buffer-revision ".." rev) line)))
       (t
        (setq line (magit2-diff-visit--offset file (list "-R" rev) line)))))
    (funcall fn buf)
    (when line
      (with-current-buffer buf
        (widen)
        (goto-char (point-min))
        (forward-line (1- line))
        (move-to-column col)))
    buf))

(defun magit2-find-file-noselect (rev file)
  "Read FILE from REV into a buffer and return the buffer.
REV is a revision or one of \"{worktree}\" or \"{index}\".
FILE must be relative to the top directory of the repository."
  (magit2-find-file-noselect-1 rev file))

(defun magit2-find-file-noselect-1 (rev file &optional revert)
  "Read FILE from REV into a buffer and return the buffer.
REV is a revision or one of \"{worktree}\" or \"{index}\".
FILE must be relative to the top directory of the repository.
Non-nil REVERT means to revert the buffer.  If `ask-revert',
then only after asking.  A non-nil value for REVERT is ignored if REV is
\"{worktree}\"."
  (if (equal rev "{worktree}")
      (find-file-noselect (expand-file-name file (magit2-toplevel)))
    (let ((topdir (magit2-toplevel)))
      (when (file-name-absolute-p file)
        (setq file (file-relative-name file topdir)))
      (with-current-buffer (magit2-get-revision-buffer-create rev file)
        (when (or (not magit2-buffer-file-name)
                  (if (eq revert 'ask-revert)
                      (y-or-n-p (format "%s already exists; revert it? "
                                        (buffer-name))))
                  revert)
          (setq magit2-buffer-revision
                (if (equal rev "{index}")
                    "{index}"
                  (magit2-rev-format "%H" rev)))
          (setq magit2-buffer-refname rev)
          (setq magit2-buffer-file-name (expand-file-name file topdir))
          (setq default-directory
                (let ((dir (file-name-directory magit2-buffer-file-name)))
                  (if (file-exists-p dir) dir topdir)))
          (setq-local revert-buffer-function #'magit2-revert-rev-file-buffer)
          (revert-buffer t t)
          (run-hooks (if (equal rev "{index}")
                         'magit2-find-index-hook
                       'magit2-find-file-hook)))
        (current-buffer)))))

(defun magit2-get-revision-buffer-create (rev file)
  (magit2-get-revision-buffer rev file t))

(defun magit2-get-revision-buffer (rev file &optional create)
  (funcall (if create 'get-buffer-create 'get-buffer)
           (format "%s.~%s~" file (subst-char-in-string ?/ ?_ rev))))

(defun magit2-revert-rev-file-buffer (_ignore-auto noconfirm)
  (when (or noconfirm
            (and (not (buffer-modified-p))
                 (catch 'found
                   (dolist (regexp revert-without-query)
                     (when (string-match regexp magit2-buffer-file-name)
                       (throw 'found t)))))
            (yes-or-no-p (format "Revert buffer from Git %s? "
                                 (if (equal magit2-buffer-refname "{index}")
                                     "index"
                                   (concat "revision " magit2-buffer-refname)))))
    (let* ((inhibit-read-only t)
           (default-directory (magit2-toplevel))
           (file (file-relative-name magit2-buffer-file-name))
           (coding-system-for-read (or coding-system-for-read 'undecided)))
      (erase-buffer)
      (magit2-git-insert "cat-file" "-p"
                        (if (equal magit2-buffer-refname "{index}")
                            (concat ":" file)
                          (concat magit2-buffer-refname ":" file)))
      (setq buffer-file-coding-system last-coding-system-used))
    (let ((buffer-file-name magit2-buffer-file-name)
          (after-change-major-mode-hook
           (remq 'global-diff-hl-mode-enable-in-buffers
                 after-change-major-mode-hook)))
      (normal-mode t))
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)
    (goto-char (point-min))))

;;; Find Index

(defvar magit2-find-index-hook nil)

(defun magit2-find-file-index-noselect (file &optional revert)
  "Read FILE from the index into a buffer and return the buffer.
FILE must to be relative to the top directory of the repository."
  (magit2-find-file-noselect-1 "{index}" file (or revert 'ask-revert)))

(defun magit2-update-index ()
  "Update the index with the contents of the current buffer.
The current buffer has to be visiting a file in the index, which
is done using `magit2-find-index-noselect'."
  (interactive)
  (let ((file (magit2-file-relative-name)))
    (unless (equal magit2-buffer-refname "{index}")
      (user-error "%s isn't visiting the index" file))
    (if (y-or-n-p (format "Update index with contents of %s" (buffer-name)))
        (let ((index (make-temp-name (magit2-git-dir "magit2-update-index-")))
              (buffer (current-buffer)))
          (when magit2-wip-before-change-mode
            (magit2-wip-commit-before-change (list file) " before un-/stage"))
          (unwind-protect
              (progn
                (let ((coding-system-for-write buffer-file-coding-system))
                  (with-temp-file index
                    (insert-buffer-substring buffer)))
                (magit2-with-toplevel
                  (magit2-call-git
                   "update-index" "--cacheinfo"
                   (substring (magit2-git-string "ls-files" "-s" file)
                              0 6)
                   (magit2-git-string "hash-object" "-t" "blob" "-w"
                                     (concat "--path=" file)
                                     "--" (magit2-convert-filename-for-git index))
                   file)))
            (ignore-errors (delete-file index)))
          (set-buffer-modified-p nil)
          (when magit2-wip-after-apply-mode
            (magit2-wip-commit-after-apply (list file) " after un-/stage")))
      (message "Abort")))
  (--when-let (magit2-get-mode-buffer 'magit2-status-mode)
    (with-current-buffer it (magit2-refresh)))
  t)

;;; Find Config File

(defun magit2-find-git-config-file (filename &optional wildcards)
  "Edit a file located in the current repository's git directory.

When \".git\", located at the root of the working tree, is a
regular file, then that makes it cumbersome to open a file
located in the actual git directory.

This command is like `find-file', except that it temporarily
binds `default-directory' to the actual git directory, while
reading the FILENAME."
  (interactive
   (let ((default-directory (magit2-git-dir)))
     (find-file-read-args "Find file: "
                          (confirm-nonexistent-file-or-buffer))))
  (find-file filename wildcards))

(defun magit2-find-git-config-file-other-window (filename &optional wildcards)
  "Edit a file located in the current repo's git directory, in another window.

When \".git\", located at the root of the working tree, is a
regular file, then that makes it cumbersome to open a file
located in the actual git directory.

This command is like `find-file-other-window', except that it
temporarily binds `default-directory' to the actual git
directory, while reading the FILENAME."
  (interactive
   (let ((default-directory (magit2-git-dir)))
     (find-file-read-args "Find file in other window: "
                          (confirm-nonexistent-file-or-buffer))))
  (find-file-other-window filename wildcards))

(defun magit2-find-git-config-file-other-frame (filename &optional wildcards)
  "Edit a file located in the current repo's git directory, in another frame.

When \".git\", located at the root of the working tree, is a
regular file, then that makes it cumbersome to open a file
located in the actual git directory.

This command is like `find-file-other-frame', except that it
temporarily binds `default-directory' to the actual git
directory, while reading the FILENAME."
  (interactive
   (let ((default-directory (magit2-git-dir)))
     (find-file-read-args "Find file in other frame: "
                          (confirm-nonexistent-file-or-buffer))))
  (find-file-other-frame filename wildcards))

;;; File Dispatch

;;;###autoload (autoload 'magit2-file-dispatch "magit2" nil t)
(transient-define-prefix magit2-file-dispatch ()
  "Invoke a Magit command that acts on the visited file.
When invoked outside a file-visiting buffer, then fall back
to `magit2-dispatch'."
  :info-manual "(magit2) Minor Mode for Buffers Visiting Files"
  ["Actions"
   [("s" "Stage"      magit2-stage-file)
    ("u" "Unstage"    magit2-unstage-file)
    ("c" "Commit"     magit2-commit)
    ("e" "Edit line"  magit2-edit-line-commit)]
   [("D" "Diff..."    magit2-diff)
    ("d" "Diff"       magit2-diff-buffer-file)
    ("g" "Status"     magit2-status-here)]
   [("L" "Log..."     magit2-log)
    ("l" "Log"        magit2-log-buffer-file)
    ("t" "Trace"      magit2-log-trace-definition)
    (7 "M" "Merged"   magit2-log-merged)]
   [("B" "Blame..."   magit2-blame)
    ("b" "Blame"      magit2-blame-addition)
    ("r" "...removal" magit2-blame-removal)
    ("f" "...reverse" magit2-blame-reverse)
    ("m" "Blame echo" magit2-blame-echo)
    ("q" "Quit blame" magit2-blame-quit)]
   [("p" "Prev blob"  magit2-blob-previous)
    ("n" "Next blob"  magit2-blob-next)
    ("v" "Goto blob"  magit2-find-file)
    ("V" "Goto file"  magit2-blob-visit-file)]
   [(5 "C-c r" "Rename file"   magit2-file-rename)
    (5 "C-c d" "Delete file"   magit2-file-delete)
    (5 "C-c u" "Untrack file"  magit2-file-untrack)
    (5 "C-c c" "Checkout file" magit2-file-checkout)]]
  (interactive)
  (transient-setup
   (if (magit2-file-relative-name)
       'magit2-file-dispatch
     'magit2-dispatch)))

;;; Blob Mode

(defvar magit2-blob-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "p" 'magit2-blob-previous)
    (define-key map "n" 'magit2-blob-next)
    (define-key map "b" 'magit2-blame-addition)
    (define-key map "r" 'magit2-blame-removal)
    (define-key map "f" 'magit2-blame-reverse)
    (define-key map "q" 'magit2-kill-this-buffer)
    map)
  "Keymap for `magit2-blob-mode'.")

(define-minor-mode magit2-blob-mode
  "Enable some Magit features in blob-visiting buffers.

Currently this only adds the following key bindings.
\n\\{magit2-blob-mode-map}"
  :package-version '(magit2 . "2.3.0"))

(defun magit2-blob-next ()
  "Visit the next blob which modified the current file."
  (interactive)
  (if magit2-buffer-file-name
      (magit2-blob-visit (or (magit2-blob-successor magit2-buffer-revision
                                                  magit2-buffer-file-name)
                            magit2-buffer-file-name))
    (if (buffer-file-name (buffer-base-buffer))
        (user-error "You have reached the end of time")
      (user-error "Buffer isn't visiting a file or blob"))))

(defun magit2-blob-previous ()
  "Visit the previous blob which modified the current file."
  (interactive)
  (if-let ((file (or magit2-buffer-file-name
                     (buffer-file-name (buffer-base-buffer)))))
      (--if-let (magit2-blob-ancestor magit2-buffer-revision file)
          (magit2-blob-visit it)
        (user-error "You have reached the beginning of time"))
    (user-error "Buffer isn't visiting a file or blob")))

;;;###autoload
(defun magit2-blob-visit-file ()
  "View the file from the worktree corresponding to the current blob.
When visiting a blob or the version from the index, then go to
the same location in the respective file in the working tree."
  (interactive)
  (if-let ((file (magit2-file-relative-name)))
      (magit2-find-file--internal "{worktree}" file #'pop-to-buffer-same-window)
    (user-error "Not visiting a blob")))

(defun magit2-blob-visit (blob-or-file)
  (if (stringp blob-or-file)
      (find-file blob-or-file)
    (pcase-let ((`(,rev ,file) blob-or-file))
      (magit2-find-file rev file)
      (apply #'message "%s (%s %s ago)"
             (magit2-rev-format "%s" rev)
             (magit2--age (magit2-rev-format "%ct" rev))))))

(defun magit2-blob-ancestor (rev file)
  (let ((lines (magit2-with-toplevel
                 (magit2-git-lines "log" "-2" "--format=%H" "--name-only"
                                  "--follow" (or rev "HEAD") "--" file))))
    (if rev (cddr lines) (butlast lines 2))))

(defun magit2-blob-successor (rev file)
  (let ((lines (magit2-with-toplevel
                 (magit2-git-lines "log" "--format=%H" "--name-only" "--follow"
                                  "HEAD" "--" file))))
    (catch 'found
      (while lines
        (if (equal (nth 2 lines) rev)
            (throw 'found (list (nth 0 lines) (nth 1 lines)))
          (setq lines (nthcdr 2 lines)))))))

;;; File Commands

(defun magit2-file-rename (file newname)
  "Rename or move FILE to NEWNAME.
NEWNAME may be a file or directory name.  If FILE isn't tracked in
Git, fallback to using `rename-file'."
  (interactive
   (let* ((file (magit2-read-file "Rename file"))
          (dir (file-name-directory file))
          (newname (read-file-name (format "Move %s to destination: " file)
                                   (and dir (expand-file-name dir)))))
     (list (expand-file-name file (magit2-toplevel))
           (expand-file-name newname))))
  (let ((oldbuf (get-file-buffer file))
        (dstdir (file-name-directory newname))
        (dstfile (if (directory-name-p newname)
                     (concat newname (file-name-nondirectory file))
                   newname)))
    (when (and oldbuf (buffer-modified-p oldbuf))
      (user-error "Save %s before moving it" file))
    (when (file-exists-p dstfile)
      (user-error "%s already exists" dstfile))
    (unless (file-exists-p dstdir)
      (user-error "Destination directory %s does not exist" dstdir))
    (if (magit2-file-tracked-p (magit2-convert-filename-for-git file))
        (magit2-call-git "mv"
                        (magit2-convert-filename-for-git file)
                        (magit2-convert-filename-for-git newname))
      (rename-file file newname current-prefix-arg))
    (when oldbuf
      (with-current-buffer oldbuf
        (let ((buffer-read-only buffer-read-only))
          (set-visited-file-name dstfile nil t))
        (if (fboundp 'vc-refresh-state)
            (vc-refresh-state)
          (with-no-warnings
            (vc-find-file-hook))))))
  (magit2-refresh))

(defun magit2-file-untrack (files &optional force)
  "Untrack the selected FILES or one file read in the minibuffer.

With a prefix argument FORCE do so even when the files have
staged as well as unstaged changes."
  (interactive (list (or (--if-let (magit2-region-values 'file t)
                             (progn
                               (unless (magit2-file-tracked-p (car it))
                                 (user-error "Already untracked"))
                               (magit2-confirm-files 'untrack it "Untrack"))
                           (list (magit2-read-tracked-file "Untrack file"))))
                     current-prefix-arg))
  (magit2-with-toplevel
    (magit2-run-git "rm" "--cached" (and force "--force") "--" files)))

(defun magit2-file-delete (files &optional force)
  "Delete the selected FILES or one file read in the minibuffer.

With a prefix argument FORCE do so even when the files have
uncommitted changes.  When the files aren't being tracked in
Git, then fallback to using `delete-file'."
  (interactive (list (--if-let (magit2-region-values 'file t)
                         (magit2-confirm-files 'delete it "Delete")
                       (list (magit2-read-file "Delete file")))
                     current-prefix-arg))
  (if (magit2-file-tracked-p (car files))
      (magit2-call-git "rm" (and force "--force") "--" files)
    (let ((topdir (magit2-toplevel)))
      (dolist (file files)
        (delete-file (expand-file-name file topdir) t))))
  (magit2-refresh))

;;;###autoload
(defun magit2-file-checkout (rev file)
  "Checkout FILE from REV."
  (interactive
   (let ((rev (magit2-read-branch-or-commit
               "Checkout from revision" magit2-buffer-revision)))
     (list rev (magit2-read-file-from-rev rev "Checkout file"))))
  (magit2-with-toplevel
    (magit2-run-git "checkout" rev "--" file)))

;;; Read File

(defvar magit2-read-file-hist nil)

(defun magit2-read-file-from-rev (rev prompt &optional default)
  (let ((files (magit2-revision-files rev)))
    (magit2-completing-read
     prompt files nil t nil 'magit2-read-file-hist
     (car (member (or default (magit2-current-file)) files)))))

(defun magit2-read-file (prompt &optional tracked-only)
  (let ((choices (nconc (magit2-list-files)
                        (unless tracked-only (magit2-untracked-files)))))
    (magit2-completing-read
     prompt choices nil t nil nil
     (car (member (or (magit2-section-value-if '(file submodule))
                      (magit2-file-relative-name nil tracked-only))
                  choices)))))

(defun magit2-read-tracked-file (prompt)
  (magit2-read-file prompt t))

(defun magit2-read-unmerged-file (&optional prompt)
  (let ((current  (magit2-current-file))
        (unmerged (magit2-unmerged-files)))
    (unless unmerged
      (user-error "There are no unresolved conflicts"))
    (magit2-completing-read (or prompt "Resolve file")
                           unmerged nil t nil nil
                           (car (member current unmerged)))))

(defun magit2-read-file-choice (prompt files &optional error default)
  "Read file from FILES.

If FILES has only one member, return that instead of prompting.
If FILES has no members, give a user error.  ERROR can be given
to provide a more informative error.

If DEFAULT is non-nil, use this as the default value instead of
`magit2-current-file'."
  (pcase (length files)
    (0 (user-error (or error "No file choices")))
    (1 (car files))
    (_ (magit2-completing-read
        prompt files nil t nil 'magit2-read-file-hist
        (car (member (or default (magit2-current-file)) files))))))

(defun magit2-read-changed-file (rev-or-range prompt &optional default)
  (magit2-read-file-choice
   prompt
   (magit2-changed-files rev-or-range)
   default
   (concat "No file changed in " rev-or-range)))

;;; _
(provide 'magit2-files)
;;; magit2-files.el ends here
