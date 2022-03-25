;;; magit2.el --- A Git porcelain inside Emacs  -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (C) 2008-2022  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit2.vc/authors.

;; Author: Marius Vollmer <marius.vollmer@gmail.com>
;;      Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>
;;      Kyle Meyer <kyle@kyleam.com>
;;      Noam Postavsky <npostavs@users.sourceforge.net>
;; Former-Maintainers:
;;      Nicolas Dudebout <nicolas.dudebout@gatech.edu>
;;      Peter J. Weisberg <pj@irregularexpressions.net>
;;      Phil Jackson <phil@shellarchive.co.uk>
;;      Rémi Vanicat <vanicat@debian.org>
;;      Yann Hodique <yann.hodique@gmail.com>

;; Keywords: git tools vc
;; Homepage: https://github.com/magit2/magit2
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

;; Magit requires at least GNU Emacs 25.1 and Git 2.2.0.

;;; Commentary:

;; Magit is a text-based Git user interface that puts an unmatched focus
;; on streamlining workflows.  Commands are invoked using short mnemonic
;; key sequences that take the cursor’s position in the highly actionable
;; interface into account to provide context-sensitive behavior.

;; With Magit you can do nearly everything that you can do when using Git
;; on the command-line, but at greater speed and while taking advantage
;; of advanced features that previously seemed too daunting to use on a
;; daily basis.  Many users will find that by using Magit they can become
;; more effective Git user.

;;; Code:

(require 'magit2-core)
(require 'magit2-diff)
(require 'magit2-log)
(require 'magit2-wip)
(require 'magit2-apply)
(require 'magit2-repos)
(require 'git-commit)

(require 'format-spec)
(require 'package nil t) ; used in `magit2-version'
(require 'with-editor)

;;; Faces

(defface magit2-header-line
  '((t :inherit magit2-section-heading))
  "Face for the `header-line' in some Magit modes.
Note that some modes, such as `magit2-log-select-mode', have their
own faces for the `header-line', or for parts of the
`header-line'."
  :group 'magit2-faces)

(defface magit2-header-line-key
  '((t :inherit font-lock-builtin-face))
  "Face for keys in the `header-line'."
  :group 'magit2-faces)

(defface magit2-dimmed
  '((((class color) (background light)) :foreground "grey50")
    (((class color) (background  dark)) :foreground "grey50"))
  "Face for text that shouldn't stand out."
  :group 'magit2-faces)

(defface magit2-hash
  '((((class color) (background light)) :foreground "grey60")
    (((class color) (background  dark)) :foreground "grey40"))
  "Face for the commit object name in the log output."
  :group 'magit2-faces)

(defface magit2-tag
  '((((class color) (background light)) :foreground "Goldenrod4")
    (((class color) (background  dark)) :foreground "LightGoldenrod2"))
  "Face for tag labels shown in log buffer."
  :group 'magit2-faces)

(defface magit2-branch-remote
  '((((class color) (background light)) :foreground "DarkOliveGreen4")
    (((class color) (background  dark)) :foreground "DarkSeaGreen2"))
  "Face for remote branch head labels shown in log buffer."
  :group 'magit2-faces)

(defface magit2-branch-remote-head
  '((((supports (:box t))) :inherit magit2-branch-remote :box t)
    (t                     :inherit magit2-branch-remote :inverse-video t))
  "Face for current branch."
  :group 'magit2-faces)

(defface magit2-branch-local
  '((((class color) (background light)) :foreground "SkyBlue4")
    (((class color) (background  dark)) :foreground "LightSkyBlue1"))
  "Face for local branches."
  :group 'magit2-faces)

(defface magit2-branch-current
  '((((supports (:box t))) :inherit magit2-branch-local :box t)
    (t                     :inherit magit2-branch-local :inverse-video t))
  "Face for current branch."
  :group 'magit2-faces)

(defface magit2-branch-upstream
  '((t :slant italic))
  "Face for upstream branch.
This face is only used in logs and it gets combined
 with `magit2-branch-local', `magit2-branch-remote'
and/or `magit2-branch-remote-head'."
  :group 'magit2-faces)

(defface magit2-branch-warning
  '((t :inherit warning))
  "Face for warning about (missing) branch."
  :group 'magit2-faces)

(defface magit2-head
  '((((class color) (background light)) :inherit magit2-branch-local)
    (((class color) (background  dark)) :inherit magit2-branch-local))
  "Face for the symbolic ref `HEAD'."
  :group 'magit2-faces)

(defface magit2-refname
  '((((class color) (background light)) :foreground "grey30")
    (((class color) (background  dark)) :foreground "grey80"))
  "Face for refnames without a dedicated face."
  :group 'magit2-faces)

(defface magit2-refname-stash
  '((t :inherit magit2-refname))
  "Face for stash refnames."
  :group 'magit2-faces)

(defface magit2-refname-wip
  '((t :inherit magit2-refname))
  "Face for wip refnames."
  :group 'magit2-faces)

(defface magit2-refname-pullreq
  '((t :inherit magit2-refname))
  "Face for pullreq refnames."
  :group 'magit2-faces)

(defface magit2-keyword
  '((t :inherit font-lock-string-face))
  "Face for parts of commit messages inside brackets."
  :group 'magit2-faces)

(defface magit2-keyword-squash
  '((t :inherit font-lock-warning-face))
  "Face for squash! and fixup! keywords in commit messages."
  :group 'magit2-faces)

(defface magit2-signature-good
  '((t :foreground "green"))
  "Face for good signatures."
  :group 'magit2-faces)

(defface magit2-signature-bad
  '((t :foreground "red" :weight bold))
  "Face for bad signatures."
  :group 'magit2-faces)

(defface magit2-signature-untrusted
  '((t :foreground "medium aquamarine"))
  "Face for good untrusted signatures."
  :group 'magit2-faces)

(defface magit2-signature-expired
  '((t :foreground "orange"))
  "Face for signatures that have expired."
  :group 'magit2-faces)

(defface magit2-signature-expired-key
  '((t :inherit magit2-signature-expired))
  "Face for signatures made by an expired key."
  :group 'magit2-faces)

(defface magit2-signature-revoked
  '((t :foreground "violet red"))
  "Face for signatures made by a revoked key."
  :group 'magit2-faces)

(defface magit2-signature-error
  '((t :foreground "light blue"))
  "Face for signatures that cannot be checked (e.g. missing key)."
  :group 'magit2-faces)

(defface magit2-cherry-unmatched
  '((t :foreground "cyan"))
  "Face for unmatched cherry commits."
  :group 'magit2-faces)

(defface magit2-cherry-equivalent
  '((t :foreground "magenta"))
  "Face for equivalent cherry commits."
  :group 'magit2-faces)

(defface magit2-filename
  '((t :weight normal))
  "Face for filenames."
  :group 'magit2-faces)

;;; Global Bindings

;;;###autoload
(define-obsolete-variable-alias 'global-magit2-file-mode
  'magit2-define-global-key-bindings "Magit 3.0.0")

;;;###autoload
(defcustom magit2-define-global-key-bindings t
  "Whether to bind some Magit commands in the global keymap.

If this variable is non-nil, then the following bindings may
be added to the global keymap.  The default is t.

key             binding
---             -------
C-x g           magit2-status
C-x M-g         magit2-dispatch
C-c M-g         magit2-file-dispatch

These bindings may be added when `after-init-hook' is run.
Each binding is added if and only if at that time no other key
is bound to the same command and no other command is bound to
the same key.  In other words we try to avoid adding bindings
that are unnecessary, as well as bindings that conflict with
other bindings.

Adding the above bindings is delayed until `after-init-hook'
is called to allow users to set the variable anywhere in their
init file (without having to make sure to do so before `magit2'
is loaded or autoloaded) and to increase the likelihood that
all the potentially conflicting user bindings have already
been added.

To set this variable use either `setq' or the Custom interface.
Do not use the function `customize-set-variable' because doing
that would cause Magit to be loaded immediately when that form
is evaluated (this differs from `custom-set-variables', which
doesn't load the libraries that define the customized variables).

Setting this variable to nil has no effect if that is done after
the key bindings have already been added.

We recommend that you bind \"C-c g\" instead of \"C-c M-g\" to
`magit2-file-dispatch'.  The former is a much better binding
but the \"C-c <letter>\" namespace is strictly reserved for
users; preventing Magit from using it by default.

Also see info node `(magit2)Commands for Buffers Visiting Files'."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-essentials
  :type 'boolean)

;;;###autoload
(progn
  (defun magit2-maybe-define-global-key-bindings ()
    (when magit2-define-global-key-bindings
      (let ((map (current-global-map)))
        (dolist (elt '(("C-x g"   . magit2-status)
                       ("C-x M-g" . magit2-dispatch)
                       ("C-c M-g" . magit2-file-dispatch)))
          (let ((key (kbd (car elt)))
                (def (cdr elt)))
            (unless (or (lookup-key map key)
                        (where-is-internal def (make-sparse-keymap) t))
              (define-key map key def)))))))
  (if after-init-time
      (magit2-maybe-define-global-key-bindings)
    (add-hook 'after-init-hook 'magit2-maybe-define-global-key-bindings t)))

;;; Dispatch Popup

;;;###autoload (autoload 'magit2-dispatch "magit2" nil t)
(transient-define-prefix magit2-dispatch ()
  "Invoke a Magit command from a list of available commands."
  :info-manual "(magit2)Top"
  ["Transient and dwim commands"
   ;; → bound in magit2-mode-map or magit2-section-mode-map
   ;; ↓ bound below
   [("A" "Apply"          magit2-cherry-pick)
    ;; a                  ↓
    ("b" "Branch"         magit2-branch)
    ("B" "Bisect"         magit2-bisect)
    ("c" "Commit"         magit2-commit)
    ("C" "Clone"          magit2-clone)
    ("d" "Diff"           magit2-diff)
    ("D" "Diff (change)"  magit2-diff-refresh)
    ("e" "Ediff (dwim)"   magit2-ediff-dwim)
    ("E" "Ediff"          magit2-ediff)
    ("f" "Fetch"          magit2-fetch)
    ("F" "Pull"           magit2-pull)
    ;; g                  ↓
    ;; G                → magit2-refresh-all
    ("h" "Help"           magit2-help)
    ("H" "Section info"   magit2-describe-section :if-derived magit2-mode)]
   [("i" "Ignore"         magit2-gitignore)
    ("I" "Init"           magit2-init)
    ("j" "Jump to section"magit2-status-jump  :if-mode     magit2-status-mode)
    ("j" "Display status" magit2-status-quick :if-not-mode magit2-status-mode)
    ("J" "Display buffer" magit2-display-repository-buffer)
    ;; k                  ↓
    ;; K                → magit2-file-untrack
    ("l" "Log"            magit2-log)
    ("L" "Log (change)"   magit2-log-refresh)
    ("m" "Merge"          magit2-merge)
    ("M" "Remote"         magit2-remote)
    ;; n                → magit2-section-forward
    ;; N       reserved → forge-dispatch
    ("o" "Submodule"      magit2-submodule)
    ("O" "Subtree"        magit2-subtree)
    ;; p                → magit2-section-backward
    ("P" "Push"           magit2-push)
    ;; q                → magit2-mode-bury-buffer
    ("Q" "Command"        magit2-git-command)]
   [("r" "Rebase"         magit2-rebase)
    ;; R                → magit2-file-rename
    ;; s                  ↓
    ;; S                  ↓
    ("t" "Tag"            magit2-tag)
    ("T" "Note"           magit2-notes)
    ;; u                  ↓
    ;; U                  ↓
    ;; v                  ↓
    ("V" "Revert"         magit2-revert)
    ("w" "Apply patches"  magit2-am)
    ("W" "Format patches" magit2-patch)
    ;; x                → magit2-reset-quickly
    ("X" "Reset"          magit2-reset)
    ("y" "Show Refs"      magit2-show-refs)
    ("Y" "Cherries"       magit2-cherry)
    ("z" "Stash"          magit2-stash)
    ("Z" "Worktree"       magit2-worktree)
    ("!" "Run"            magit2-run)]]
  ["Applying changes"
   :if-derived magit2-mode
   [("a" "Apply"          magit2-apply)
    ("v" "Reverse"        magit2-reverse)
    ("k" "Discard"        magit2-discard)]
   [("s" "Stage"          magit2-stage)
    ("u" "Unstage"        magit2-unstage)]
   [("S" "Stage all"      magit2-stage-modified)
    ("U" "Unstage all"    magit2-unstage-all)]]
  ["Essential commands"
   :if-derived magit2-mode
   [("g" "       refresh current buffer"   magit2-refresh)
    ("q" "       bury current buffer"      magit2-mode-bury-buffer)
    ("<tab>" "   toggle section at point"  magit2-section-toggle)
    ("<return>" "visit thing at point"     magit2-visit-thing)]
   [("C-x m"    "show all key bindings"    describe-mode)
    ("C-x i"    "show Info manual"         magit2-info)]])

;;;###autoload
(defun magit2-info ()
  "Show Magit's Info manual."
  (interactive)
  (info "magit2"))

;;; Git Popup

(defcustom magit2-shell-command-verbose-prompt t
  "Whether to show the working directory when reading a command.
This affects `magit2-git-command', `magit2-git-command-topdir',
`magit2-shell-command', and `magit2-shell-command-topdir'."
  :package-version '(magit2 . "2.11.0")
  :group 'magit2-commands
  :type 'boolean)

(defvar magit2-git-command-history nil)

;;;###autoload (autoload 'magit2-run "magit2" nil t)
(transient-define-prefix magit2-run ()
  "Run git or another command, or launch a graphical utility."
  [["Run git subcommand"
    ("!" "in repository root"   magit2-git-command-topdir)
    ("p" "in working directory" magit2-git-command)]
   ["Run shell command"
    ("s" "in repository root"   magit2-shell-command-topdir)
    ("S" "in working directory" magit2-shell-command)]
   ["Launch"
    ("k" "gitk"                 magit2-run-gitk)
    ("a" "gitk --all"           magit2-run-gitk-all)
    ("b" "gitk --branches"      magit2-run-gitk-branches)
    ("g" "git gui"              magit2-run-git-gui)
    ("m" "git mergetool --gui"  magit2-git-mergetool)]])

;;;###autoload
(defun magit2-git-command (command)
  "Execute COMMAND asynchronously; display output.

Interactively, prompt for COMMAND in the minibuffer. \"git \" is
used as initial input, but can be deleted to run another command.

With a prefix argument COMMAND is run in the top-level directory
of the current working tree, otherwise in `default-directory'."
  (interactive (list (magit2-read-shell-command nil "git ")))
  (magit2--shell-command command))

;;;###autoload
(defun magit2-git-command-topdir (command)
  "Execute COMMAND asynchronously; display output.

Interactively, prompt for COMMAND in the minibuffer. \"git \" is
used as initial input, but can be deleted to run another command.

COMMAND is run in the top-level directory of the current
working tree."
  (interactive (list (magit2-read-shell-command t "git ")))
  (magit2--shell-command command (magit2-toplevel)))

;;;###autoload
(defun magit2-shell-command (command)
  "Execute COMMAND asynchronously; display output.

Interactively, prompt for COMMAND in the minibuffer.  With a
prefix argument COMMAND is run in the top-level directory of
the current working tree, otherwise in `default-directory'."
  (interactive (list (magit2-read-shell-command)))
  (magit2--shell-command command))

;;;###autoload
(defun magit2-shell-command-topdir (command)
  "Execute COMMAND asynchronously; display output.

Interactively, prompt for COMMAND in the minibuffer.  COMMAND
is run in the top-level directory of the current working tree."
  (interactive (list (magit2-read-shell-command t)))
  (magit2--shell-command command (magit2-toplevel)))

(defun magit2--shell-command (command &optional directory)
  (let ((default-directory (or directory default-directory))
        (process-environment process-environment))
    (push "GIT_PAGER=cat" process-environment)
    (magit2--with-connection-local-variables
     (magit2-start-process shell-file-name nil
                          shell-command-switch command)))
  (magit2-process-buffer))

(defun magit2-read-shell-command (&optional toplevel initial-input)
  (let ((default-directory
          (if (or toplevel current-prefix-arg)
              (or (magit2-toplevel)
                  (magit2--not-inside-repository-error))
            default-directory)))
    (read-shell-command (if magit2-shell-command-verbose-prompt
                            (format "Async shell command in %s: "
                                    (abbreviate-file-name default-directory))
                          "Async shell command: ")
                        initial-input 'magit2-git-command-history)))

;;; Font-Lock Keywords

(defconst magit2-font-lock-keywords
  (eval-when-compile
    `((,(concat "(\\(magit2-define-section-jumper\\)\\_>"
                "[ \t'\(]*"
                "\\(\\(?:\\sw\\|\\s_\\)+\\)?")
       (1 'font-lock-keyword-face)
       (2 'font-lock-function-name-face nil t))
      (,(concat "(" (regexp-opt '("magit2-insert-section"
                                  "magit2-section-case"
                                  "magit2-bind-match-strings"
                                  "magit2-with-temp-index"
                                  "magit2-with-blob"
                                  "magit2-with-toplevel") t)
                "\\_>")
       . 1))))

(font-lock-add-keywords 'emacs-lisp-mode magit2-font-lock-keywords)

;;; Version

(defvar magit2-version 'undefined
  "The version of Magit that you're using.
Use the function by the same name instead of this variable.")

;;;###autoload
(defun magit2-version (&optional print-dest)
  "Return the version of Magit currently in use.
If optional argument PRINT-DEST is non-nil, output
stream (interactively, the echo area, or the current buffer with
a prefix argument), also print the used versions of Magit, Git,
and Emacs to it."
  (interactive (list (if current-prefix-arg (current-buffer) t)))
  (let ((magit2-git-global-arguments nil)
        (toplib (or load-file-name buffer-file-name))
        debug)
    (unless (and toplib
                 (member (file-name-nondirectory toplib)
                         '("magit2.el" "magit2.el.gz")))
      (let ((load-suffixes (reverse load-suffixes))) ; prefer .el than .elc
        (setq toplib (locate-library "magit2"))))
    (setq toplib (and toplib (magit2--straight-chase-links toplib)))
    (push toplib debug)
    (when toplib
      (let* ((topdir (file-name-directory toplib))
             (gitdir (expand-file-name
                      ".git" (file-name-directory
                              (directory-file-name topdir))))
             (static (locate-library "magit2-version.el" nil (list topdir)))
             (static (and static (magit2--straight-chase-links static))))
        (or (progn
              (push 'repo debug)
              (when (and (file-exists-p gitdir)
                         ;; It is a repo, but is it the Magit repo?
                         (file-exists-p
                          (expand-file-name "../lisp/magit2.el" gitdir)))
                (push t debug)
                ;; Inside the repo the version file should only exist
                ;; while running make.
                (when (and static (not noninteractive))
                  (ignore-errors (delete-file static)))
                (setq magit2-version
                      (let ((default-directory topdir))
                        (magit2-git-string "describe"
                                          "--tags" "--dirty" "--always")))))
            (progn
              (push 'static debug)
              (when (and static (file-exists-p static))
                (push t debug)
                (load-file static)
                magit2-version))
            (when (featurep 'package)
              (push 'elpa debug)
              (ignore-errors
                (--when-let (assq 'magit2 package-alist)
                  (push t debug)
                  (setq magit2-version
                        (and (fboundp 'package-desc-version)
                             (package-version-join
                              (package-desc-version (cadr it))))))))
            (progn
              (push 'dirname debug)
              (let ((dirname (file-name-nondirectory
                              (directory-file-name topdir))))
                (when (string-match "\\`magit2-\\([0-9].*\\)" dirname)
                  (setq magit2-version (match-string 1 dirname)))))
            ;; If all else fails, just report the commit hash. It's
            ;; better than nothing and we cannot do better in the case
            ;; of e.g. a shallow clone.
            (progn
              (push 'hash debug)
              ;; Same check as above to see if it's really the Magit repo.
              (when (and (file-exists-p gitdir)
                         (file-exists-p
                          (expand-file-name "../lisp/magit2.el" gitdir)))
                (setq magit2-version
                      (let ((default-directory topdir))
                        (magit2-git-string "rev-parse" "HEAD"))))))))
    (if (stringp magit2-version)
        (when print-dest
          (princ (format "Magit %s%s, Git %s, Emacs %s, %s"
                         (or magit2-version "(unknown)")
                         (or (and (ignore-errors
                                    (magit2--version>= magit2-version "2008"))
                                  (ignore-errors
                                    (require 'lisp-mnt)
                                    (and (fboundp 'lm-header)
                                         (format
                                          " [>= %s]"
                                          (with-temp-buffer
                                            (insert-file-contents
                                             (locate-library "magit2.el" t))
                                            (lm-header "Package-Version"))))))
                             "")
                         (magit2--safe-git-version)
                         emacs-version
                         system-type)
                 print-dest))
      (setq debug (reverse debug))
      (setq magit2-version 'error)
      (when magit2-version
        (push magit2-version debug))
      (unless (equal (getenv "CI") "true")
        ;; The repository is a sparse clone.
        (message "Cannot determine Magit's version %S" debug)))
    magit2-version))

;;; Startup Asserts

(defun magit2-startup-asserts ()
  (when-let ((val (getenv "GIT_DIR")))
    (setenv "GIT_DIR")
    (message
     "Magit unset $GIT_DIR (was %S).  See %s" val
     ;; Note: Pass URL as argument rather than embedding in the format
     ;; string to prevent the single quote from being rendered
     ;; according to `text-quoting-style'.
     "https://github.com/magit2/magit2/wiki/Don't-set-$GIT_DIR-and-alike"))
  (when-let ((val (getenv "GIT_WORK_TREE")))
    (setenv "GIT_WORK_TREE")
    (message
     "Magit unset $GIT_WORK_TREE (was %S).  See %s" val
     ;; See comment above.
     "https://github.com/magit2/magit2/wiki/Don't-set-$GIT_DIR-and-alike"))
  ;; Git isn't required while building Magit.
  (cl-eval-when (load eval)
    (magit2-git-version-assert))
  (when (version< emacs-version magit2--minimal-emacs)
    (display-warning 'magit2 (format "\
Magit requires Emacs >= %s, you are using %s.

If this comes as a surprise to you, because you do actually have
a newer version installed, then that probably means that the
older version happens to appear earlier on the `$PATH'.  If you
always start Emacs from a shell, then that can be fixed in the
shell's init file.  If you start Emacs by clicking on an icon,
or using some sort of application launcher, then you probably
have to adjust the environment as seen by graphical interface.
For X11 something like ~/.xinitrc should work.\n"
                                    magit2--minimal-emacs emacs-version)
                     :error)))

;;; Loading Libraries

(provide 'magit2)

(cl-eval-when (load eval)
  (require 'magit2-status)
  (require 'magit2-refs)
  (require 'magit2-files)
  (require 'magit2-reset)
  (require 'magit2-branch)
  (require 'magit2-merge)
  (require 'magit2-tag)
  (require 'magit2-worktree)
  (require 'magit2-notes)
  (require 'magit2-sequence)
  (require 'magit2-commit)
  (require 'magit2-remote)
  (require 'magit2-clone)
  (require 'magit2-fetch)
  (require 'magit2-pull)
  (require 'magit2-push)
  (require 'magit2-bisect)
  (require 'magit2-stash)
  (require 'magit2-blame)
  (require 'magit2-obsolete)
  (require 'magit2-submodule)
  (unless (load "magit2-autoloads" t t)
    (require 'magit2-patch)
    (require 'magit2-subtree)
    (require 'magit2-ediff)
    (require 'magit2-gitignore)
    (require 'magit2-sparse-checkout)
    (require 'magit2-extras)
    (require 'git-rebase)
    (require 'magit2-bookmark)))

(with-eval-after-load 'bookmark
  (require 'magit2-bookmark))

(if after-init-time
    (progn (magit2-startup-asserts)
           (magit2-version))
  (add-hook 'after-init-hook #'magit2-startup-asserts t)
  (add-hook 'after-init-hook #'magit2-version t))

;;; magit2.el ends here
