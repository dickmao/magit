;;; magit2-git.el --- Git functionality  -*- lexical-binding: t -*-

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

;; This library implements wrappers for various Git plumbing commands.

;;; Code:

(require 'magit2-base)
(require 'libgit2)
(require 'format-spec)

;; From `magit2-branch'.
(defvar magit2-branch-prefer-remote-upstream)
(defvar magit2-published-branches)

;; From `magit2-margin'.
(declare-function magit2-maybe-make-margin-overlay "magit2-margin" ())

;; From `magit2-mode'.
(declare-function magit2-get-mode-buffer "magit2-mode"
                  (mode &optional value frame))
(declare-function magit2-refresh "magit2-mode" ())
(defvar magit2-buffer-diff-args)
(defvar magit2-buffer-file-name)
(defvar magit2-buffer-log-args)
(defvar magit2-buffer-log-files)
(defvar magit2-buffer-refname)
(defvar magit2-buffer-revision)

;; From `magit2-process'.
(declare-function magit2-call-git "magit2-process" (&rest args))
(declare-function magit2-process-buffer "magit2-process" (&optional nodisplay))
(declare-function magit2-process-file "magit2-process"
                  (process &optional infile buffer display &rest args))
(declare-function magit2-process-git "magit2-process" (destination &rest args))
(declare-function magit2-process-insert-section "magit2-process"
                  (pwd program args &optional errcode errlog))
(defvar magit2-this-error)
(defvar magit2-process-error-message-regexps)

;; From later in `magit2-git'.
(defvar magit2-tramp-process-environment nil)

;; From `magit2-blame'.
(declare-function magit2-current-blame-chunk "magit2-blame"
                  (&optional type noerror))

(eval-when-compile
  (cl-pushnew 'orig-rev eieio--known-slot-names)
  (cl-pushnew 'number eieio--known-slot-names))

;;; Options

;; For now this is shared between `magit2-process' and `magit2-git'.
(defgroup magit2-process nil
  "Git and other external processes used by Magit."
  :group 'magit2)

(defvar magit2-git-environment
  (list (format "INSIDE_EMACS=%s,magit2" emacs-version))
  "Prepended to `process-environment' while running git.")

(defcustom magit2-git-output-coding-system
  (and (eq system-type 'windows-nt) 'utf-8)
  "Coding system for receiving output from Git.

If non-nil, the Git config value `i18n.logOutputEncoding' should
be set via `magit2-git-global-arguments' to value consistent with
this."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-process
  :type '(choice (coding-system :tag "Coding system to decode Git output")
                 (const :tag "Use system default" nil)))

(defvar magit2-git-w32-path-hack nil
  "Alist of (EXE . (PATHENTRY)).
This specifies what additional PATH setting needs to be added to
the environment in order to run the non-wrapper git executables
successfully.")

(defcustom magit2-git-executable
  (or (and (eq system-type 'windows-nt)
           ;; Avoid the wrappers "cmd/git.exe" and "cmd/git.cmd",
           ;; which are much slower than using "bin/git.exe" directly.
           (--when-let (executable-find "git")
             (ignore-errors
               ;; Git for Windows 2.x provides cygpath so we can
               ;; ask it for native paths.
               (let* ((core-exe
                       (car
                        (process-lines
                         it "-c"
                         "alias.X=!x() { which \"$1\" | cygpath -mf -; }; x"
                         "X" "git")))
                      (hack-entry (assoc core-exe magit2-git-w32-path-hack))
                      ;; Running the libexec/git-core executable
                      ;; requires some extra PATH entries.
                      (path-hack
                       (list (concat "PATH="
                                     (car (process-lines
                                           it "-c"
                                           "alias.P=!cygpath -wp \"$PATH\""
                                           "P"))))))
                 ;; The defcustom STANDARD expression can be
                 ;; evaluated many times, so make sure it is
                 ;; idempotent.
                 (if hack-entry
                     (setcdr hack-entry path-hack)
                   (push (cons core-exe path-hack) magit2-git-w32-path-hack))
                 core-exe))))
      (and (eq system-type 'darwin)
           (executable-find "git"))
      "git")
  "The Git executable used by Magit on the local host.
On remote machines `magit2-remote-git-executable' is used instead."
  :package-version '(magit2 . "3.2.0")
  :group 'magit2-process
  :type 'string)

(defcustom magit2-remote-git-executable "git"
  "The Git executable used by Magit on remote machines.
On the local host `magit2-git-executable' is used instead.
Consider customizing `tramp-remote-path' instead of this
option."
  :package-version '(magit2 . "3.2.0")
  :group 'magit2-process
  :type 'string)

(defcustom magit2-git-global-arguments
  `("--no-pager" "--literal-pathspecs"
    "-c" "core.preloadindex=true"
    "-c" "log.showSignature=false"
    "-c" "color.ui=false"
    "-c" "color.diff=false"
    ,@(and (eq system-type 'windows-nt)
           (list "-c" "i18n.logOutputEncoding=UTF-8")))
  "Global Git arguments.

The arguments set here are used every time the git executable is
run as a subprocess.  They are placed right after the executable
itself and before the git command - as in `git HERE... COMMAND
REST'.  See the manpage `git(1)' for valid arguments.

Be careful what you add here, especially if you are using Tramp
to connect to servers with ancient Git versions.  Never remove
anything that is part of the default value, unless you really
know what you are doing.  And think very hard before adding
something; it will be used every time Magit runs Git for any
purpose."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-commands
  :group 'magit2-process
  :type '(repeat string))

(defvar magit2-git-debug nil
  "Whether to enable additional reporting of git errors.

Magit basically calls git for one of these two reasons: for
side-effects or to do something with its standard output.

When git is run for side-effects then its output, including error
messages, go into the process buffer which is shown when using \
\\<magit2-status-mode-map>\\[magit2-process].

When git's output is consumed in some way, then it would be too
expensive to also insert it into this buffer, but when this
option is non-nil and git returns with a non-zero exit status,
then at least its standard error is inserted into this buffer.

This is only intended for debugging purposes.  Do not enable this
permanently, that would negatively affect performance.

Also see `magit2-process-extreme-logging'.")

(defcustom magit2-prefer-remote-upstream nil
  "Whether to favor remote branches when reading the upstream branch.

This controls whether commands that read a branch from the user
and then set it as the upstream branch, offer a local or a remote
branch as default completion candidate, when they have the choice.

This affects all commands that use `magit2-read-upstream-branch'
or `magit2-read-starting-point', which includes most commands
that change the upstream and many that create new branches."
  :package-version '(magit2 . "2.4.2")
  :group 'magit2-commands
  :type 'boolean)

(defcustom magit2-list-refs-namespaces
  '("refs/heads"
    "refs/remotes"
    "refs/tags"
    "refs/pullreqs")
  "List of ref namespaces considered when reading a ref.

This controls the order of refs returned by `magit2-list-refs',
which is called by functions like `magit2-list-branch-names' to
generate the collection of refs."
  :package-version '(magit2 . "3.1.0")
  :group 'magit2-commands
  :type '(repeat string))

(defcustom magit2-list-refs-sortby nil
  "How to sort the ref collection in the prompt.

This affects commands that read a ref.  More specifically, it
controls the order of refs returned by `magit2-list-refs', which
is called by functions like `magit2-list-branch-names' to generate
the collection of refs.  By default, refs are sorted according to
their full refname (i.e., 'refs/...').

Any value accepted by the `--sort' flag of `git for-each-ref' can
be used.  For example, \"-creatordate\" places refs with more
recent committer or tagger dates earlier in the list.  A list of
strings can also be given in order to pass multiple sort keys to
`git for-each-ref'.

Note that, depending on the completion framework you use, this
may not be sufficient to change the order in which the refs are
displayed.  It only controls the order of the collection passed
to `magit2-completing-read' or, for commands that support reading
multiple strings, `read-from-minibuffer'.  The completion
framework ultimately determines how the collection is displayed."
  :package-version '(magit2 . "2.11.0")
  :group 'magit2-miscellaneous
  :type '(choice string (repeat string)))

;;; Git

(defvar magit2--refresh-cache nil)

(defmacro magit2--with-refresh-cache (key &rest body)
  (declare (indent 1) (debug (form body)))
  (let ((k (cl-gensym)))
    `(if magit2--refresh-cache
         (let ((,k ,key))
           (--if-let (assoc ,k (cdr magit2--refresh-cache))
               (progn (cl-incf (caar magit2--refresh-cache))
                      (cdr it))
             (cl-incf (cdar magit2--refresh-cache))
             (let ((value ,(macroexp-progn body)))
               (push (cons ,k value)
                     (cdr magit2--refresh-cache))
               value)))
       ,@body)))

(defvar magit2-with-editor-envvar "GIT_EDITOR"
  "The environment variable exported by `magit2-with-editor'.
Set this to \"GIT_SEQUENCE_EDITOR\" if you do not want to use
Emacs to edit commit messages but would like to do so to edit
rebase sequences.")

(defmacro magit2-with-editor (&rest body)
  "Like `with-editor' but let-bind some more variables.
Also respect the value of `magit2-with-editor-envvar'."
  (declare (indent 0) (debug (body)))
  `(let ((magit2-process-popup-time -1)
         ;; The user may have customized `shell-file-name' to
         ;; something which results in `w32-shell-dos-semantics' nil
         ;; (which changes the quoting style used by
         ;; `shell-quote-argument'), but Git for Windows expects shell
         ;; quoting in the dos style.
         (shell-file-name (if (and (eq system-type 'windows-nt)
                                   ;; If we have Cygwin mount points,
                                   ;; the git flavor is cygwin, so dos
                                   ;; shell quoting is probably wrong.
                                   (not magit2-cygwin-mount-points))
                              "cmdproxy"
                            shell-file-name)))
     (with-editor* magit2-with-editor-envvar
       ,@body)))

(defmacro magit2--with-temp-process-buffer (&rest body)
  "Like `with-temp-buffer', but always propagate `process-environment'.
When that var is buffer-local in the calling buffer, it is not
propagated by `with-temp-buffer', so we explicitly ensure that
happens, so that processes will be invoked consistently.  BODY is
as for that macro."
  (declare (indent 0) (debug (body)))
  (let ((p (cl-gensym)))
    `(let ((,p process-environment))
       (with-temp-buffer
         (setq-local process-environment ,p)
         ,@body))))

(defsubst magit2-git-executable ()
  "Return value of `magit2-git-executable' or `magit2-remote-git-executable'.
The variable is chosen depending on whether `default-directory'
is remote."
  (if (file-remote-p default-directory)
      magit2-remote-git-executable
    magit2-git-executable))

(defun magit2-process-git-arguments (args)
  "Prepare ARGS for a function that invokes Git.

Magit has many specialized functions for running Git; they all
pass arguments through this function before handing them to Git,
to do the following.

* Flatten ARGS, removing nil arguments.
* Prepend `magit2-git-global-arguments' to ARGS.
* On w32 systems, encode to `w32-ansi-code-page'."
  (setq args (append magit2-git-global-arguments (-flatten args)))
  (if (and (eq system-type 'windows-nt) (boundp 'w32-ansi-code-page))
      ;; On w32, the process arguments *must* be encoded in the
      ;; current code-page (see #3250).
      (mapcar (lambda (arg)
                (encode-coding-string
                 arg (intern (format "cp%d" w32-ansi-code-page))))
              args)
    args))

(defun magit2-git-exit-code (&rest args)
  "Execute Git with ARGS, returning its exit code."
  (magit2-process-git nil args))

(defun magit2-git-success (&rest args)
  "Execute Git with ARGS, returning t if its exit code is 0."
  (= (magit2-git-exit-code args) 0))

(defun magit2-git-failure (&rest args)
  "Execute Git with ARGS, returning t if its exit code is 1."
  (= (magit2-git-exit-code args) 1))

(defun magit2-git-output (&rest args)
  "Execute Git with ARGS, returning its output."
  (setq args (-flatten args))
  (magit2--with-refresh-cache (cons default-directory args)
    (magit2--with-temp-process-buffer
      (magit2-process-git (list t nil) args)
      (buffer-substring-no-properties (point-min) (point-max)))))

(define-error 'magit2-invalid-git-boolean "Not a Git boolean")

(defun magit2-git-true (&rest args)
  "Execute Git with ARGS, returning t if it prints \"true\".
If it prints \"false\", then return nil.  For any other output
signal `magit2-invalid-git-boolean'."
  (pcase (magit2-git-output args)
    ((or "true"  "true\n")  t)
    ((or "false" "false\n") nil)
    (output (signal 'magit2-invalid-git-boolean (list output)))))

(defun magit2-git-false (&rest args)
  "Execute Git with ARGS, returning t if it prints \"false\".
If it prints \"true\", then return nil.  For any other output
signal `magit2-invalid-git-boolean'."
  (pcase (magit2-git-output args)
    ((or "true"  "true\n")  nil)
    ((or "false" "false\n") t)
    (output (signal 'magit2-invalid-git-boolean (list output)))))

(defun magit2-git-config-p (variable &optional default)
  "Return the boolean value of the Git variable VARIABLE.
VARIABLE has to be specified as a string.  Return DEFAULT (which
defaults to nil) if VARIABLE is unset.  If VARIABLE's value isn't
a boolean, then raise an error."
  (let ((args (list "config" "--bool" "--default" (if default "true" "false")
                    variable)))
    (magit2--with-refresh-cache (cons default-directory args)
      (magit2--with-temp-process-buffer
        (let ((status (magit2-process-git t args))
              (output (buffer-substring (point-min) (1- (point-max)))))
          (if (zerop status)
              (equal output "true")
            (signal 'magit2-invalid-git-boolean (list output))))))))

(defun magit2-git-insert (&rest args)
  "Execute Git with ARGS, inserting its output at point.
If Git exits with a non-zero exit status, then show a message and
add a section in the respective process buffer."
  (setq args (magit2-process-git-arguments args))
  (if magit2-git-debug
      (let (log)
        (unwind-protect
            (progn
              (setq log (make-temp-file "magit2-stderr"))
              (delete-file log)
              (let ((exit (magit2-process-git (list t log) args)))
                (when (> exit 0)
                  (let ((msg "Git failed"))
                    (when (file-exists-p log)
                      (setq msg (with-temp-buffer
                                  (insert-file-contents log)
                                  (goto-char (point-max))
                                  (if (functionp magit2-git-debug)
                                      (funcall magit2-git-debug (buffer-string))
                                    (magit2--locate-error-message))))
                      (let ((magit2-git-debug nil))
                        (with-current-buffer (magit2-process-buffer t)
                          (magit2-process-insert-section default-directory
                                                        magit2-git-executable
                                                        args exit log))))
                    (message "%s" msg)))
                exit))
          (ignore-errors (delete-file log))))
    (magit2-process-git (list t nil) args)))

(defun magit2--locate-error-message ()
  (goto-char (point-max))
  (and (run-hook-wrapped 'magit2-process-error-message-regexps
                         (lambda (re) (re-search-backward re nil t)))
       (match-string-no-properties 1)))

(defsubst magit2-git--normalize-args (args)
  "Make post-libgit2 ARGS look like pre-libgit2 args.
This just removes :method from ARGS."
  (let (new-args
        (i 0))
    (while (< i (length args))
      (let ((arg (nth i args)))
        (if (keywordp arg)
            (setq i (+ 2 i))
          (setq i (+ 1 i))
          (push arg new-args))))
    (-flatten (reverse new-args))))

(cl-defun magit2-git-string (&rest args &key method &allow-other-keys)
  "Execute Git with ARGS, returning the first line of its output.
If there is no output, return nil.  If the output begins with a
newline, return an empty string."
  (setq args (magit2-git--normalize-args args))
  (if method
      (funcall method)
    (magit2--with-refresh-cache (cons default-directory args)
      (magit2--with-temp-process-buffer
       (magit2-git-insert args)
       (unless (bobp)
         (goto-char (point-min))
         (buffer-substring-no-properties (point) (line-end-position)))))))

(cl-defun magit2-git-lines (&rest args &key method &allow-other-keys)
  "Execute Git with ARGS, returning its output as a list of lines.
Empty lines anywhere in the output are omitted.

If Git exits with a non-zero exit status, then report show a
message and add a section in the respective process buffer."
  (setq args (magit2-git--normalize-args args))
  (magit2--with-temp-process-buffer
    (if method
        (funcall method)
      (magit2-git-insert args))
    (split-string (buffer-string) "\n" t)))

(cl-defun magit2-git-items (&rest args &key method &allow-other-keys)
  "Execute Git with ARGS, returning its null-separated output as a list.
Empty items anywhere in the output are omitted.

If Git exits with a non-zero exit status, then report show a
message and add a section in the respective process buffer."
  (setq args (magit2-git--normalize-args args))
  (magit2--with-temp-process-buffer
    (if method
        (funcall method)
      (magit2-git-insert args))
    (split-string (buffer-string) "\0" t)))

(cl-defun magit2-git-wash (washer &rest args &key method &allow-other-keys)
  "Execute Git with ARGS, inserting washed output at point.
Actually first insert the raw output at point.  If there is no
output, call `magit2-cancel-section'.  Otherwise temporarily narrow
the buffer to the inserted text, move to its beginning, and then
call function WASHER with ARGS as its sole argument."
  (declare (indent 1))
  (setq args (magit2-git--normalize-args args))
  (let ((beg (point)))
    (if method
        (funcall method)
      (magit2-git-insert args))
    (if (= (point) beg)
        (magit2-cancel-section)
      (unless (bolp)
        (insert "\n"))
      (save-restriction
        (narrow-to-region beg (point))
        (goto-char beg)
        (funcall washer args))
      (when (or (= (point) beg)
                (= (point) (1+ beg)))
        (magit2-cancel-section))
      (magit2-maybe-make-margin-overlay))))

;;; Git Version

(defconst magit2--git-version-regexp
  "\\`git version \\([0-9]+\\(\\.[0-9]+\\)\\{1,2\\}\\)")

(defvar magit2--host-git-version-cache nil)

(defun magit2-git-version>= (n)
  "Return t if `magit2-git-version's value is greater than or equal to N."
  (magit2--version>= (magit2-git-version) n))

(defun magit2-git-version< (n)
  "Return t if `magit2-git-version's value is smaller than N."
  (version< (magit2-git-version) n))

(defun magit2-git-version ()
  "Return the Git version used for `default-directory'.
Raise an error if Git cannot be found, if it exits with a
non-zero status, or the output does not have the expected
format."
  (magit2--with-refresh-cache default-directory
    (let ((host (file-remote-p default-directory)))
      (or (cdr (assoc host magit2--host-git-version-cache))
          (magit2--with-temp-process-buffer
            ;; Unset global arguments for ancient Git versions.
            (let* ((magit2-git-global-arguments nil)
                   (status (magit2-process-git t "version"))
                   (output (buffer-string)))
              (cond
               ((not (zerop status))
                (display-warning
                 'magit2
                 (format "%S\n\nRunning \"%s --version\" failed with output:\n\n%s"
                         (if host
                             (format "Magit cannot find Git on host %S.\n
Check the value of `magit2-remote-git-executable' using
`magit2-debug-git-executable' and consult the info node
`(tramp)Remote programs'." host)
                           "Magit cannot find Git.\n
Check the values of `magit2-git-executable' and `exec-path'
using `magit2-debug-git-executable'.")
                         (magit2-git-executable)
                         output)))
               ((save-match-data
                  (and (string-match magit2--git-version-regexp output)
                       (let ((version (match-string 1 output)))
                         (push (cons host version)
                               magit2--host-git-version-cache)
                         version))))
               (t (error "Unexpected \"%s --version\" output: %S"
                         (magit2-git-executable)
                         output)))))))))

(defun magit2-git-version-assert (&optional minimal who)
  "Assert that the used Git version is greater than or equal to MINIMAL.
If optional MINIMAL is nil, compare with `magit2--minimal-git'
instead.  Optional WHO if non-nil specifies what functionality
needs at least MINIMAL, otherwise it defaults to \"Magit\"."
  (when (magit2-git-version< (or minimal magit2--minimal-git))
    (let* ((host (file-remote-p default-directory))
           (msg (format-spec
                 (cond (host "\
%w requires Git %m or greater, but on %h the version is %m.

If multiple Git versions are installed on the host, then the
problem might be that TRAMP uses the wrong executable.

Check the value of `magit2-remote-git-executable' and consult
the info node `(tramp)Remote programs'.\n")
                       (t "\
%w requires Git %m or greater, but you are using %v.

If you have multiple Git versions installed, then check the
values of `magit2-remote-git-executable' and `exec-path'.\n"))
                 `((?w . ,(or who "Magit"))
                   (?m . ,(or minimal magit2--minimal-git))
                   (?v . ,(magit2-git-version))
                   (?h . ,host)))))
      (display-warning 'magit2 msg :error))))

(defun magit2--safe-git-version ()
  "Return the Git version used for `default-directory' or an error message."
  (magit2--with-temp-process-buffer
    (let* ((magit2-git-global-arguments nil)
           (status (magit2-process-git t "version"))
           (output (buffer-string)))
      (cond ((not (zerop status)) output)
            ((save-match-data
               (and (string-match magit2--git-version-regexp output)
                    (match-string 1 output))))
            (t output)))))

(defun magit2-debug-git-executable ()
  "Display a buffer with information about `magit2-git-executable'.
Also include information about `magit2-remote-git-executable'.
See info node `(magit2)Debugging Tools' for more information."
  (interactive)
  (with-current-buffer (get-buffer-create "*magit2-git-debug*")
    (pop-to-buffer (current-buffer))
    (erase-buffer)
    (insert (format "magit2-remote-git-executable: %S\n"
                    magit2-remote-git-executable))
    (insert (concat
             (format "magit2-git-executable: %S" magit2-git-executable)
             (and (not (file-name-absolute-p magit2-git-executable))
                  (format " [%S]" (executable-find magit2-git-executable)))
             (format " (%s)\n" (magit2--safe-git-version))))
    (insert (format "exec-path: %S\n" exec-path))
    (--when-let (cl-set-difference
                 (-filter #'file-exists-p (remq nil (parse-colon-path
                                                     (getenv "PATH"))))
                 (-filter #'file-exists-p (remq nil exec-path))
                 :test #'file-equal-p)
      (insert (format "  entries in PATH, but not in exec-path: %S\n" it)))
    (dolist (execdir exec-path)
      (insert (format "  %s (%s)\n" execdir (car (file-attributes execdir))))
      (when (file-directory-p execdir)
        (dolist (exec (directory-files
                       execdir t (concat
                                  "\\`git" (regexp-opt exec-suffixes) "\\'")))
          (insert (format "    %s (%s)\n" exec
                          (magit2--safe-git-version))))))))

;;; Variables

(defun magit2-config-get-from-cached-list (key)
  (gethash
   ;; `git config --list' downcases first and last components of the key.
   (--> key
     (replace-regexp-in-string "\\`[^.]+" #'downcase it t t)
     (replace-regexp-in-string "[^.]+\\'" #'downcase it t t))
   (magit2--with-refresh-cache (cons (magit2-toplevel) 'config)
     (let ((configs (make-hash-table :test 'equal)))
       (dolist (conf (magit2-git-items "config" "--list" "-z"))
         (let* ((nl-pos (cl-position ?\n conf))
                (key (substring conf 0 nl-pos))
                (val (if nl-pos (substring conf (1+ nl-pos)) "")))
           (puthash key (nconc (gethash key configs) (list val)) configs)))
       configs))))

(defun magit2-get (&rest keys)
  "Return the value of the Git variable specified by KEYS."
  (car (last (apply 'magit2-get-all keys))))

(defun magit2-get-all (&rest keys)
  "Return all values of the Git variable specified by KEYS."
  (let ((magit2-git-debug nil)
        (arg (and (or (null (car keys))
                      (string-prefix-p "--" (car keys)))
                  (pop keys)))
        (key (mapconcat 'identity keys ".")))
    (if (and magit2--refresh-cache (not arg))
        (magit2-config-get-from-cached-list key)
      (magit2-git-items "config" arg "-z" "--get-all" key))))

(defun magit2-get-boolean (&rest keys)
  "Return the boolean value of the Git variable specified by KEYS.
Also see `magit2-git-config-p'."
  (let ((arg (and (or (null (car keys))
                      (string-prefix-p "--" (car keys)))
                  (pop keys)))
        (key (mapconcat 'identity keys ".")))
    (equal (if magit2--refresh-cache
               (car (last (magit2-config-get-from-cached-list key)))
             (let (magit2-git-debug)
               (magit2-git-string "config" arg "--bool" key)))
           "true")))

(defun magit2-set (value &rest keys)
  "Set the value of the Git variable specified by KEYS to VALUE."
  (let ((arg (and (or (null (car keys))
                      (string-prefix-p "--" (car keys)))
                  (pop keys)))
        (key (mapconcat 'identity keys ".")))
    (if value
        (magit2-git-success "config" arg key value)
      (magit2-git-success "config" arg "--unset" key))
    value))

(gv-define-setter magit2-get (val &rest keys)
  `(magit2-set ,val ,@keys))

(defun magit2-set-all (values &rest keys)
  "Set all values of the Git variable specified by KEYS to VALUES."
  (let ((arg (and (or (null (car keys))
                      (string-prefix-p "--" (car keys)))
                  (pop keys)))
        (var (mapconcat 'identity keys ".")))
    (when (magit2-get var)
      (magit2-call-git "config" arg "--unset-all" var))
    (dolist (v values)
      (magit2-call-git "config" arg "--add" var v))))

;;; Files

(defun magit2--safe-default-directory (&optional file)
  (catch 'unsafe-default-dir
    (let ((dir (file-name-as-directory
                (expand-file-name (or file default-directory))))
          (previous nil))
      (while (not (magit2-file-accessible-directory-p dir))
        (setq dir (file-name-directory (directory-file-name dir)))
        (when (equal dir previous)
          (throw 'unsafe-default-dir nil))
        (setq previous dir))
      dir)))

(defmacro magit2--with-safe-default-directory (file &rest body)
  (declare (indent 1) (debug (form body)))
  `(when-let ((default-directory (magit2--safe-default-directory ,file)))
     ,@body))

(defun magit2-gitdir (&optional directory)
  "Return the absolute and resolved path of the .git directory.

If the `GIT_DIR' environment variable is define then return that.
Otherwise return the .git directory for DIRECTORY, or if that is
nil, then for `default-directory' instead.  If the directory is
not located inside a Git repository, then return nil."
  (let ((default-directory (or directory default-directory)))
    (magit2-git-dir)))

(defun magit2-git-dir (&optional path)
  "Return the absolute and resolved path of the .git directory.

If the `GIT_DIR' environment variable is define then return that.
Otherwise return the .git directory for `default-directory'.  If
the directory is not located inside a Git repository, then return
nil."
  (magit2--with-refresh-cache (list default-directory 'magit2-git-dir path)
    (magit2--with-safe-default-directory nil
      (when-let ((dir (magit2-rev-parse-safe "--git-dir")))
        (setq dir (file-name-as-directory (magit2-expand-git-file-name dir)))
        (unless (file-remote-p dir)
          (setq dir (concat (file-remote-p default-directory) dir)))
        (if path (expand-file-name (convert-standard-filename path) dir) dir)))))

(defvar magit2--separated-gitdirs nil)

(defun magit2--record-separated-gitdir ()
  (let ((topdir (magit2-toplevel))
        (gitdir (magit2-git-dir)))
    ;; Kludge: git-annex converts submodule gitdirs to symlinks. See #3599.
    (when (file-symlink-p (directory-file-name gitdir))
      (setq gitdir (file-truename gitdir)))
    ;; We want to delete the entry for `topdir' here, rather than within
    ;; (unless ...), in case a `--separate-git-dir' repository was switched to
    ;; the standard structure (i.e., "topdir/.git/").
    (setq magit2--separated-gitdirs (cl-delete topdir
                                              magit2--separated-gitdirs
                                              :key #'car :test #'equal))
    (unless (equal (file-name-as-directory (expand-file-name ".git" topdir))
                   gitdir)
      (push (cons topdir gitdir) magit2--separated-gitdirs))))

(defun magit2-toplevel (&optional directory)
  "Return the absolute path to the toplevel of the current repository.

From within the working tree or control directory of a repository
return the absolute path to the toplevel directory of the working
tree.  As a special case, from within a bare repository return
the control directory instead.  When called outside a repository
then return nil.

When optional DIRECTORY is non-nil then return the toplevel for
that directory instead of the one for `default-directory'.

Try to respect the option `find-file-visit-truename', i.e.  when
the value of that option is nil, then avoid needlessly returning
the truename.  When a symlink to a sub-directory of the working
tree is involved, or when called from within a sub-directory of
the gitdir or from the toplevel of a gitdir, which itself is not
located within the working tree, then it is not possible to avoid
returning the truename."
  (magit2--with-refresh-cache
      (cons (or directory default-directory) 'magit2-toplevel)
    (magit2--with-safe-default-directory directory
      (if-let ((topdir (magit2-rev-parse-safe "--show-toplevel")))
          (let (updir)
            (setq topdir (magit2-expand-git-file-name topdir))
            (if (and
                 ;; Always honor these settings.
                 (not find-file-visit-truename)
                 (not (getenv "GIT_WORK_TREE"))
                 ;; `--show-cdup' is the relative path to the toplevel
                 ;; from `(file-truename default-directory)'.  Here we
                 ;; pretend it is relative to `default-directory', and
                 ;; go to that directory.  Then we check whether
                 ;; `--show-toplevel' still returns the same value and
                 ;; whether `--show-cdup' now is the empty string.  If
                 ;; both is the case, then we are at the toplevel of
                 ;; the same working tree, but also avoided needlessly
                 ;; following any symlinks.
                 (progn
                   (setq updir (file-name-as-directory
                                (magit2-rev-parse-safe "--show-cdup")))
                   (setq updir (if (file-name-absolute-p updir)
                                   (concat (file-remote-p default-directory) updir)
                                 (expand-file-name updir)))
                   (let ((default-directory updir))
                     (and (string-equal (magit2-rev-parse-safe "--show-cdup") "")
                          (--when-let (magit2-rev-parse-safe "--show-toplevel")
                            (string-equal (magit2-expand-git-file-name it)
                                          topdir))))))
                updir
              (concat (file-remote-p default-directory)
                      (file-name-as-directory topdir))))
        (when-let ((gitdir (magit2-rev-parse-safe "--git-dir")))
          (setq gitdir (file-name-as-directory
                        (if (file-name-absolute-p gitdir)
                            ;; We might have followed a symlink.
                            (concat (file-remote-p default-directory)
                                    (magit2-expand-git-file-name gitdir))
                          (expand-file-name gitdir))))
          (if (magit2-bare-repo-p)
              gitdir
            (let* ((link (expand-file-name "gitdir" gitdir))
                   (wtree (and (file-exists-p link)
                               (magit2-file-line link))))
              (cond
               ((and wtree
                     ;; Ignore .git/gitdir files that result from a
                     ;; Git bug.  See #2364.
                     (not (equal wtree ".git")))
                ;; Return the linked working tree.
                (concat (file-remote-p default-directory)
                        (file-name-directory wtree)))
               ;; The working directory may not be the parent directory of
               ;; .git if it was set up with `git init --separate-git-dir'.
               ;; See #2955.
               ((car (rassoc gitdir magit2--separated-gitdirs)))
               (t
                ;; Step outside the control directory to enter the working tree.
                (file-name-directory (directory-file-name gitdir)))))))))))

(defmacro magit2-with-toplevel (&rest body)
  (declare (indent defun) (debug (body)))
  (let ((toplevel (cl-gensym "toplevel")))
    `(let ((,toplevel (magit2-toplevel)))
       (if ,toplevel
           (let ((default-directory ,toplevel))
             ,@body)
         (magit2--not-inside-repository-error)))))

(define-error 'magit2-outside-git-repo "Not inside Git repository")
(define-error 'magit2-corrupt-git-config "Corrupt Git configuration")
(define-error 'magit2-git-executable-not-found
  "Git executable cannot be found (see https://magit2.vc/goto/e6a78ed2)")

(defun magit2--assert-usable-git ()
  (if (not (executable-find (magit2-git-executable)))
      (signal 'magit2-git-executable-not-found (magit2-git-executable))
    (let ((magit2-git-debug
           (lambda (err)
             (signal 'magit2-corrupt-git-config
                     (format "%s: %s" default-directory err)))))
      ;; This should always succeed unless there's a corrupt config
      ;; (or at least a similarly severe failing state).  Note that
      ;; git-config's --default is avoided because it's not available
      ;; until Git 2.18.
      (magit2-git-string "config" "--get-color" "" "reset"))
    nil))

(defun magit2--not-inside-repository-error ()
  (magit2--assert-usable-git)
  (signal 'magit2-outside-git-repo default-directory))

(defun magit2-inside-gitdir-p (&optional noerror)
  "Return t if `default-directory' is below the repository directory.
If it is below the working directory, then return nil.
If it isn't below either, then signal an error unless NOERROR
is non-nil, in which case return nil."
  (and (magit2--assert-default-directory noerror)
       ;; Below a repository directory that is not located below the
       ;; working directory "git rev-parse --is-inside-git-dir" prints
       ;; "false", which is wrong.
       (let ((gitdir (magit2-git-dir)))
         (cond (gitdir (file-in-directory-p default-directory gitdir))
               (noerror nil)
               (t (signal 'magit2-outside-git-repo default-directory))))))

(defun magit2-inside-worktree-p (&optional noerror)
  "Return t if `default-directory' is below the working directory.
If it is below the repository directory, then return nil.
If it isn't below either, then signal an error unless NOERROR
is non-nil, in which case return nil."
  (and (magit2--assert-default-directory noerror)
       (condition-case nil
           (magit2-rev-parse-true "--is-inside-work-tree")
         (magit2-invalid-git-boolean
          (and (not noerror)
               (signal 'magit2-outside-git-repo default-directory))))))

(cl-defgeneric magit2-bare-repo-p (&optional noerror)
  "Return t if the current repository is bare.
If it is non-bare, then return nil.  If `default-directory'
isn't below a Git repository, then signal an error unless
NOERROR is non-nil, in which case return nil."
  (and (magit2--assert-default-directory noerror)
       (condition-case nil
           (magit2-rev-parse-true "--is-bare-repository")
         (magit2-invalid-git-boolean
          (and (not noerror)
               (signal 'magit2-outside-git-repo default-directory))))))

(defun magit2--assert-default-directory (&optional noerror)
  (or (file-directory-p default-directory)
      (and (not noerror)
           (let ((exists (file-exists-p default-directory)))
             (signal (if exists 'file-error 'file-missing)
                     (list "Running git in directory"
                           (if exists
                               "Not a directory"
                             "No such file or directory")
                           default-directory))))))

(defun magit2-git-repo-p (directory &optional non-bare)
  "Return t if DIRECTORY is a Git repository.
When optional NON-BARE is non-nil also return nil if DIRECTORY is
a bare repository."
  (and (file-directory-p directory) ; Avoid archives, see #3397.
       (or (file-regular-p (expand-file-name ".git" directory))
           (file-directory-p (expand-file-name ".git" directory))
           (and (not non-bare)
                (file-regular-p (expand-file-name "HEAD" directory))
                (file-directory-p (expand-file-name "refs" directory))
                (file-directory-p (expand-file-name "objects" directory))))))

(defun magit2-file-relative-name (&optional file tracked)
  "Return the path of FILE relative to the repository root.

If optional FILE is nil or omitted, return the relative path of
the file being visited in the current buffer, if any, else nil.
If the file is not inside a Git repository, then return nil.

If TRACKED is non-nil, return the path only if it matches a
tracked file."
  (unless file
    (with-current-buffer (or (buffer-base-buffer)
                             (current-buffer))
      (setq file (or magit2-buffer-file-name buffer-file-name
                     (and (derived-mode-p 'dired-mode) default-directory)))))
  (when (and file (or (not tracked)
                      (magit2-file-tracked-p (file-relative-name file))))
    (--when-let (magit2-toplevel
                 (magit2--safe-default-directory
                  (directory-file-name (file-name-directory file))))
      (file-relative-name file it))))

(defun magit2-file-tracked-p (file)
  (magit2-git-success "ls-files" "--error-unmatch" file))

(defun magit2-list-files (&rest args)
  (magit2-git-items "ls-files" "-z" "--full-name" args))

(defun magit2-tracked-files ()
  (magit2-list-files "--cached"))

(defun magit2-untracked-files (&optional all files)
  (magit2-list-files "--other" (unless all "--exclude-standard") "--" files))

(defun magit2-modified-files (&optional nomodules files)
  (magit2-git-items "diff-index" "-z" "--name-only"
                   (and nomodules "--ignore-submodules")
                   (magit2-headish) "--" files))

(defun magit2-unstaged-files (&optional nomodules files)
  (magit2-git-items "diff-files" "-z" "--name-only"
                   (and nomodules "--ignore-submodules")
                   "--" files))

(defun magit2-staged-files (&optional nomodules files)
  (magit2-git-items "diff-index" "-z" "--name-only" "--cached"
                   (and nomodules "--ignore-submodules")
                   (magit2-headish) "--" files))

(defun magit2-binary-files (&rest args)
  (--mapcat (and (string-match "^-\t-\t\\(.+\\)" it)
                 (list (match-string 1 it)))
            (magit2-git-items
             "diff" "-z" "--numstat" "--ignore-submodules"
             args)))

(defun magit2-unmerged-files ()
  (magit2-git-items "diff-files" "-z" "--name-only" "--diff-filter=U"))

(defun magit2-ignored-files ()
  (magit2-git-items "ls-files" "-z" "--others" "--ignored"
                   "--exclude-standard" "--directory"))

(defun magit2-skip-worktree-files ()
  (--keep (and (and (= (aref it 0) ?S)
                    (substring it 2)))
          (magit2-list-files "-t")))

(defun magit2-assume-unchanged-files ()
  (--keep (and (and (memq (aref it 0) '(?h ?s ?m ?r ?c ?k))
                    (substring it 2)))
          (magit2-list-files "-v")))

(defun magit2-revision-files (rev)
  (magit2-with-toplevel
    (magit2-git-items "ls-tree" "-z" "-r" "--name-only" rev)))

(defun magit2-revision-directories (rev)
  "List directories that contain a tracked file in revision REV."
  (magit2-with-toplevel
    (mapcar #'file-name-as-directory
            (magit2-git-items "ls-tree" "-z" "-r" "-d" "--name-only" rev))))

(defun magit2-changed-files (rev-or-range &optional other-rev)
  "Return list of files the have changed between two revisions.
If OTHER-REV is non-nil, REV-OR-RANGE should be a revision, not a
range.  Otherwise, it can be any revision or range accepted by
\"git diff\" (i.e., <rev>, <revA>..<revB>, or <revA>...<revB>)."
  (magit2-with-toplevel
    (magit2-git-items "diff" "-z" "--name-only" rev-or-range other-rev)))

(defun magit2-renamed-files (revA revB)
  (--map (cons (nth 1 it) (nth 2 it))
         (-partition 3 (magit2-git-items
                        "diff-tree" "-r" "--diff-filter=R" "-z" "-M"
                        revA revB))))

(defun magit2-file-status (&optional path)
  (let ((repo (libgit2-repository-open default-directory))
        result)
    (cl-flet ((process (path status)
                (let* ((space ? )
                       (x ??)
                       (y ??)
                       (unmerged-p (memq 'conflicted status)))
                  (push (apply #'list path nil
                               (dolist (val status (list x y))
                                 (pcase val
                                   ('index-new (setq x ?A))
                                   ('index-modified (setq x ?M))
                                   ('index-deleted (setq x ?D))
                                   ('index-renamed (setq x ?R))
                                   ('index-typechange (setq x ?M))
                                   ('wt-new (when (eq x ?A)
                                              (setq x space y ?A)))
                                   ('wt-modified (if unmerged-p
                                                     (setq x ?U y ?U)
                                                   (setq x space y ?M)))
                                   ('wt-deleted (setq y ?D))
                                   ('wt-typechange (setq y ?M))
                                   ('wt-renamed (setq y ?R))
                                   ('wt-unreadable (setq y space)))))
                        result))))
     (if path
         (process path (libgit2-status-file repo path))
       (libgit2-status-foreach-ext
        repo
        (lambda (path status)
          (process path (libgit2-status-decode status)))
        nil '(include-untracked))))
    result))

(defcustom magit2-cygwin-mount-points
  (when (eq system-type 'windows-nt)
    (cl-sort (--map (if (string-match "^\\(.*\\) on \\(.*\\) type" it)
                        (cons (file-name-as-directory (match-string 2 it))
                              (file-name-as-directory (match-string 1 it)))
                      (lwarn '(magit2) :error
                             "Failed to parse Cygwin mount: %S" it))
                    ;; If --exec-path is not a native Windows path,
                    ;; then we probably have a cygwin git.
                    (let ((process-environment
                           (append magit2-git-environment process-environment)))
                      (and (not (string-match-p
                                 "\\`[a-zA-Z]:"
                                 (car (process-lines
                                       magit2-git-executable "--exec-path"))))
                           (ignore-errors (process-lines "mount")))))
             #'> :key (pcase-lambda (`(,cyg . ,_win)) (length cyg))))
  "Alist of (CYGWIN . WIN32) directory names.
Sorted from longest to shortest CYGWIN name."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-process
  :type '(alist :key-type string :value-type directory))

(defun magit2-expand-git-file-name (filename)
  (unless (file-name-absolute-p filename)
    (setq filename (expand-file-name filename)))
  (-if-let ((cyg . win)
            (cl-assoc filename magit2-cygwin-mount-points
                      :test (lambda (f cyg) (string-prefix-p cyg f))))
      (concat win (substring filename (length cyg)))
    filename))

(defun magit2-convert-filename-for-git (filename)
  "Convert FILENAME so that it can be passed to git.
1. If it's a absolute filename, then pass through `expand-file-name'
   to replace things such as \"~/\" that Git does not understand.
2. If it's a remote filename, then remove the remote part.
3. Deal with an `windows-nt' Emacs vs. Cygwin Git incompatibility."
  (if (file-name-absolute-p filename)
      (-if-let ((cyg . win)
                (cl-rassoc filename magit2-cygwin-mount-points
                           :test (lambda (f win) (string-prefix-p win f))))
          (concat cyg (substring filename (length win)))
        (let ((expanded (expand-file-name filename)))
          (or (file-remote-p expanded 'localname)
              expanded)))
    filename))

(defun magit2-decode-git-path (path)
  (if (eq (aref path 0) ?\")
      (decode-coding-string (read path)
                            (or magit2-git-output-coding-system
                                (car default-process-coding-system))
                            t)
    path))

(defun magit2-file-at-point (&optional expand assert)
  (if-let ((file (magit2-section-case
                   (file (oref it value))
                   (hunk (magit2-section-parent-value it)))))
      (if expand
          (expand-file-name file (magit2-toplevel))
        file)
    (when assert
      (user-error "No file at point"))))

(defun magit2-current-file ()
  (or (magit2-file-relative-name)
      (magit2-file-at-point)
      (and (derived-mode-p 'magit2-log-mode)
           (car magit2-buffer-log-files))))

;;; Predicates

(defun magit2-no-commit-p ()
  "Return t if there is no commit in the current Git repository."
  (not (magit2-rev-parse "HEAD")))

(defun magit2-merge-commit-p (commit)
  "Return t if COMMIT is a merge commit."
  (> (length (magit2-commit-parents commit)) 1))

(defun magit2-anything-staged-p (&optional ignore-submodules &rest files)
  "Return t if there are any staged changes.
If optional FILES is non-nil, then only changes to those files
are considered."
  (magit2-git-failure "diff" "--quiet" "--cached"
                     (and ignore-submodules "--ignore-submodules")
                     "--" files))

(defun magit2-anything-unstaged-p (&optional ignore-submodules &rest files)
  "Return t if there are any unstaged changes.
If optional FILES is non-nil, then only changes to those files
are considered."
  (magit2-git-failure "diff" "--quiet"
                     (and ignore-submodules "--ignore-submodules")
                     "--" files))

(defun magit2-anything-modified-p (&optional ignore-submodules &rest files)
  "Return t if there are any staged or unstaged changes.
If optional FILES is non-nil, then only changes to those files
are considered."
  (or (apply 'magit2-anything-staged-p   ignore-submodules files)
      (apply 'magit2-anything-unstaged-p ignore-submodules files)))

(defun magit2-anything-unmerged-p (&rest files)
  "Return t if there are any merge conflicts.
If optional FILES is non-nil, then only conflicts in those files
are considered."
  (and (magit2-git-string "ls-files" "--unmerged" files) t))

(defun magit2-module-worktree-p (module)
  (magit2-with-toplevel
    (file-exists-p (expand-file-name (expand-file-name ".git" module)))))

(defun magit2-module-no-worktree-p (module)
  (not (magit2-module-worktree-p module)))

(defun magit2-ignore-submodules-p (&optional return-argument)
  (or (cl-find-if (lambda (arg)
                    (string-prefix-p "--ignore-submodules" arg))
                  magit2-buffer-diff-args)
      (when-let ((value (magit2-get "diff.ignoreSubmodules")))
        (if return-argument
            (concat "--ignore-submodules=" value)
          (concat "diff.ignoreSubmodules=" value)))))

;;; Revisions and References

(cl-defun magit2-rev-parse (&rest args &key repo &allow-other-keys)
  "Execute `git rev-parse ARGS', returning first line of output.
If there is no output, return nil."
  (apply #'magit2-git-string "rev-parse"
         `,@(append
             args
             (when (and (= 1 (length args))
                        (not (equal "-" (substring (car args) 0 1))))
               `(:method (lambda ()
                           (ignore-errors
                             (libgit2-commit-id
                              (libgit2-revparse-single
                               (or ,repo (libgit2-repository-open default-directory))
                               ,(car args))))))))))

(defun magit2-rev-parse-safe (&rest args)
  "Execute `git rev-parse ARGS', returning first line of output.
If there is no output, return nil.  Like `magit2-rev-parse' but
ignore `magit2-git-debug'."
  (let (magit2-git-debug)
    (magit2-git-string "rev-parse" args)))

(defun magit2-rev-parse-true (&rest args)
  "Execute `git rev-parse ARGS', returning t if it prints \"true\".
If it prints \"false\", then return nil.  For any other output
signal an error."
  (magit2-git-true "rev-parse" args))

(defun magit2-rev-parse-false (&rest args)
  "Execute `git rev-parse ARGS', returning t if it prints \"false\".
If it prints \"true\", then return nil.  For any other output
signal an error."
  (magit2-git-false "rev-parse" args))

(defun magit2-rev-parse-p (&rest args)
  "Execute `git rev-parse ARGS', returning t if it prints \"true\".
Return t if the first (and usually only) output line is the
string \"true\", otherwise return nil."
  (equal (let (magit2-git-debug) (magit2-git-string "rev-parse" args)) "true"))

(defalias 'magit2-rev-commit-id #'magit2-rev-parse)

(defun magit2-rev-hash (rev)
  "Return full hash for REV if it names an existing commit."
  (magit2-rev-parse (concat rev "^{commit}")))

(defun magit2-rev-equal (a b)
  "Return t if there are no differences between the commits A and B."
  (magit2-git-success "diff" "--quiet" a b))

(defun magit2-rev-eq (a b)
  "Return t if A and B refer to the same commit."
  (let ((a (magit2-rev-hash a))
        (b (magit2-rev-hash b)))
    (and a b (equal a b))))

(defun magit2-rev-ancestor-p (a b)
  "Return non-nil if commit A is an ancestor of commit B."
  (let* ((repo (libgit2-repository-open default-directory))
         (commit-a (libgit2-revparse-single repo a))
         (commit-b (libgit2-revparse-single repo b)))
    (libgit2-graph-descendant-p
     repo
     (libgit2-commit-id commit-a)
     (libgit2-commit-id commit-b))))

(defun magit2-rev-head-p (rev)
  (or (equal rev "HEAD")
      (and rev
           (not (string-match-p "\\.\\." rev))
           (equal (magit2-rev-parse rev)
                  (magit2-rev-parse "HEAD")))))

(defun magit2-rev-author-p (rev)
  "Return t if the user is the author of REV.
More precisely return t if `user.name' is equal to the author
name of REV and/or `user.email' is equal to the author email
of REV."
  (or (equal (magit2-get "user.name")  (magit2-rev-format "%an" rev))
      (equal (magit2-get "user.email") (magit2-rev-format "%ae" rev))))

(defun magit2-rev-name (rev &optional pattern not-anchored)
  "Return a symbolic name for REV using `git-name-rev'.

PATTERN can be used to limit the result to a matching ref.
Unless NOT-ANCHORED is non-nil, the beginning of the ref must
match PATTERN.

An anchored lookup is done using the arguments
\"--exclude=*/<PATTERN> --exclude=*/HEAD\" in addition to
\"--refs=<PATTERN>\", provided at least version v2.13 of Git is
used.  Older versions did not support the \"--exclude\" argument.
When \"--exclude\" cannot be used and `git-name-rev' returns a
ref that should have been excluded, then that is discarded and
this function returns nil instead.  This is unfortunate because
there might be other refs that do match.  To fix that, update
Git."
  (if (magit2-git-version< "2.13")
      (when-let
          ((ref (magit2-git-string "name-rev" "--name-only" "--no-undefined"
                                  (and pattern (concat "--refs=" pattern))
                                  rev)))
        (if (and pattern
                 (string-match-p "\\`refs/[^/]+/\\*\\'" pattern))
            (let ((namespace (substring pattern 0 -1)))
              (and (not (or (string-suffix-p "HEAD" ref)
                            (and (string-match-p namespace ref)
                                 (not (magit2-rev-parse
                                       (concat namespace ref))))))
                   ref))
          ref))
    (magit2-git-string "name-rev" "--name-only" "--no-undefined"
                      (and pattern (concat "--refs=" pattern))
                      (and pattern
                           (not not-anchored)
                           (list "--exclude=*/HEAD"
                                 (concat "--exclude=*/" pattern)))
                      rev)))

(defun magit2-rev-branch (rev)
  (--when-let (magit2-rev-name rev "refs/heads/*")
    (unless (string-match-p "[~^]" it) it)))

(defun magit2-get-shortname (rev)
  (let* ((fn (apply-partially 'magit2-rev-name rev))
         (name (or (funcall fn "refs/tags/*")
                   (funcall fn "refs/heads/*")
                   (funcall fn "refs/remotes/*"))))
    (cond ((not name)
           (magit2-rev-parse "--short" rev))
          ((string-match "^\\(?:tags\\|remotes\\)/\\(.+\\)" name)
           (if (magit2-ref-ambiguous-p (match-string 1 name))
               name
             (match-string 1 name)))
          (t (magit2-ref-maybe-qualify name)))))

(defun magit2-name-branch (rev &optional lax)
  (or (magit2-name-local-branch rev)
      (magit2-name-remote-branch rev)
      (and lax (or (magit2-name-local-branch rev t)
                   (magit2-name-remote-branch rev t)))))

(defun magit2-name-local-branch (rev &optional lax)
  (--when-let (magit2-rev-name rev "refs/heads/*")
    (and (or lax (not (string-match-p "[~^]" it))) it)))

(defun magit2-name-remote-branch (rev &optional lax)
  (--when-let (magit2-rev-name rev "refs/remotes/*")
    (and (or lax (not (string-match-p "[~^]" it)))
         (substring it 8))))

(defun magit2-name-tag (rev &optional lax)
  (when-let ((name (magit2-rev-name rev "refs/tags/*")))
    (when (string-suffix-p "^0" name)
      (setq name (substring name 0 -2)))
    (and (or lax (not (string-match-p "[~^]" name)))
         (substring name 5))))

(defun magit2-ref-abbrev (refname)
  "Return an unambiguous abbreviation of REFNAME."
  (condition-case nil
      (libgit2-reference-shorthand
       (cdr (libgit2-revparse-ext
             (libgit2-repository-open default-directory) refname)))
    (giterr-config)))

(defun magit2-ref-fullname (refname)
  "Return fully qualified refname for REFNAME.
If REFNAME is ambiguous, return nil."
  (magit2-rev-parse "--verify" "--symbolic-full-name" refname))

(defun magit2-ref-ambiguous-p (refname)
  (save-match-data
    (if (string-match "\\`\\([^^~]+\\)\\(.*\\)" refname)
        (not (magit2-ref-fullname (match-string 1 refname)))
      (error "%S has an unrecognized format" refname))))

(defun magit2-ref-maybe-qualify (refname &optional prefix)
  "If REFNAME is ambiguous, try to disambiguate it by prepend PREFIX to it.
Return an unambiguous refname, either REFNAME or that prefixed
with PREFIX, nil otherwise.  If REFNAME has an offset suffix
such as \"~1\", then that is preserved.  If optional PREFIX is
nil, then use \"heads/\".  "
  (if (magit2-ref-ambiguous-p refname)
      (let ((refname (concat (or prefix "heads/") refname)))
        (and (not (magit2-ref-ambiguous-p refname)) refname))
    refname))

(defun magit2-ref-exists-p (ref)
  (magit2-git-success "show-ref" "--verify" ref))

(defun magit2-ref-equal (a b)
  "Return t if the refnames A and B are `equal'.
A symbolic-ref pointing to some ref, is `equal' to that ref,
as are two symbolic-refs pointing to the same ref.  Refnames
may be abbreviated."
  (let ((a (magit2-ref-fullname a))
        (b (magit2-ref-fullname b)))
    (and a b (equal a b))))

(defun magit2-ref-eq (a b)
  "Return t if the refnames A and B are `eq'.
A symbolic-ref is `eq' to itself, but not to the ref it points
to, or to some other symbolic-ref that points to the same ref."
  (let ((symbolic-a (magit2-symbolic-ref-p a))
        (symbolic-b (magit2-symbolic-ref-p b)))
    (or (and symbolic-a
             symbolic-b
             (equal a b))
        (and (not symbolic-a)
             (not symbolic-b)
             (magit2-ref-equal a b)))))

(defun magit2-headish ()
  "Return the `HEAD' or if that doesn't exist the hash of the empty tree."
  (if (magit2-no-commit-p)
      (magit2-git-string "mktree")
    "HEAD"))

(defun magit2-branch-at-point ()
  (magit2-section-case
    (branch (oref it value))
    (commit (or (magit2--painted-branch-at-point)
                (magit2-name-branch (oref it value))))))

(defun magit2--painted-branch-at-point (&optional type)
  (or (and (not (eq type 'remote))
           (memq (get-text-property (point) 'font-lock-face)
                 (list 'magit2-branch-local
                       'magit2-branch-current))
           (when-let ((branch (thing-at-point 'git-revision t)))
             (cdr (magit2-split-branch-name branch))))
      (and (not (eq type 'local))
           (memq (get-text-property (point) 'font-lock-face)
                 (list 'magit2-branch-remote
                       'magit2-branch-remote-head))
           (thing-at-point 'git-revision t))))

(defun magit2-local-branch-at-point ()
  (magit2-section-case
    (branch (let ((branch (magit2-ref-maybe-qualify (oref it value))))
              (when (member branch (magit2-list-local-branch-names))
                branch)))
    (commit (or (magit2--painted-branch-at-point 'local)
                (magit2-name-local-branch (oref it value))))))

(defun magit2-remote-branch-at-point ()
  (magit2-section-case
    (branch (let ((branch (oref it value)))
              (when (member branch (magit2-list-remote-branch-names))
                branch)))
    (commit (or (magit2--painted-branch-at-point 'remote)
                (magit2-name-remote-branch (oref it value))))))

(defun magit2-commit-at-point ()
  (or (magit2-section-value-if 'commit)
      (thing-at-point 'git-revision t)
      (when-let ((chunk (magit2-current-blame-chunk 'addition t)))
        (oref chunk orig-rev))
      (and (derived-mode-p 'magit2-stash-mode
                           'magit2-merge-preview-mode
                           'magit2-revision-mode)
           magit2-buffer-revision)))

(defun magit2-branch-or-commit-at-point ()
  (or (magit2-section-case
        (branch (magit2-ref-maybe-qualify (oref it value)))
        (commit (or (magit2--painted-branch-at-point)
                    (let ((rev (oref it value)))
                      (or (magit2-name-branch rev) rev))))
        (tag (magit2-ref-maybe-qualify (oref it value) "tags/"))
        (pullreq (or (and (fboundp 'forge--pullreq-branch)
                          (magit2-branch-p
                           (forge--pullreq-branch (oref it value))))
                     (magit2-ref-p (format "refs/pullreqs/%s"
                                          (oref (oref it value) number))))))
      (thing-at-point 'git-revision t)
      (when-let ((chunk (magit2-current-blame-chunk 'addition t)))
        (oref chunk orig-rev))
      (and magit2-buffer-file-name
           magit2-buffer-refname)
      (and (derived-mode-p 'magit2-stash-mode
                           'magit2-merge-preview-mode
                           'magit2-revision-mode)
           magit2-buffer-revision)))

(defun magit2-tag-at-point ()
  (magit2-section-case
    (tag    (oref it value))
    (commit (magit2-name-tag (oref it value)))))

(defun magit2-stash-at-point ()
  (magit2-section-value-if 'stash))

(defun magit2-remote-at-point ()
  (magit2-section-case
    (remote (oref it value))
    ([branch remote] (magit2-section-parent-value it))))

(defun magit2-module-at-point (&optional predicate)
  (when (magit2-section-match 'magit2-module-section)
    (let ((module (oref (magit2-current-section) value)))
      (and (or (not predicate)
               (funcall predicate module))
           module))))

(defun magit2-get-current-branch ()
  "Return the refname of the currently checked out branch.
Return nil if no branch is currently checked out."
  (file-name-nondirectory
   (libgit2-reference-symbolic-target
    (libgit2-reference-lookup
     (libgit2-repository-open default-directory)
     "HEAD"))))

(defvar magit2-get-previous-branch-timeout 0.5
  "Maximum time to spend in `magit2-get-previous-branch'.
Given as a number of seconds.")

(defun magit2-get-previous-branch ()
  "Return the refname of the previously checked out branch.
Return nil if no branch can be found in the `HEAD' reflog
which is different from the current branch and still exists.
The amount of time spent searching is limited by
`magit2-get-previous-branch-timeout'."
  (let ((t0 (float-time))
        (current (magit2-get-current-branch))
        (i 1) prev)
    (while (if (> (- (float-time) t0) magit2-get-previous-branch-timeout)
               (setq prev nil) ;; Timed out.
             (and (setq prev (magit2-rev-parse (format "@{-%i}" i)))
                  (or (not (setq prev (magit2-rev-branch prev)))
                      (equal prev current))))
      (cl-incf i))
    prev))

(defun magit2-set-upstream-branch (branch upstream)
  "Set UPSTREAM as the upstream of BRANCH.
If UPSTREAM is nil, then unset BRANCH's upstream.
Otherwise UPSTREAM has to be an existing branch."
  (if upstream
      (magit2-call-git "branch" "--set-upstream-to" upstream branch)
    (magit2-call-git "branch" "--unset-upstream" branch)))

(defun magit2-get-upstream-ref (&optional branch)
  "Return the upstream branch of BRANCH as a fully qualified ref.
It BRANCH is nil, then return the upstream of the current branch,
if any, nil otherwise.  If the upstream is not configured, the
configured remote is an url, or the named branch does not exist,
then return nil.  I.e.  return an existing local or
remote-tracking branch ref."
  (when-let ((branch (or branch (magit2-get-current-branch))))
    (magit2-ref-fullname (concat branch "@{upstream}"))))

(defun magit2-get-upstream-branch (&optional branch)
  "Return the name of the upstream branch of BRANCH.
It BRANCH is nil, then return the upstream of the current branch
if any, nil otherwise.  If the upstream is not configured, the
configured remote is an url, or the named branch does not exist,
then return nil.  I.e. return the name of an existing local or
remote-tracking branch.  The returned string is colorized
according to the branch type."
  (magit2--with-refresh-cache
      (list default-directory 'magit2-get-upstream-branch branch)
    (when-let ((branch (or branch (magit2-get-current-branch)))
               (upstream (magit2-ref-abbrev (concat branch "@{upstream}"))))
      (magit2--propertize-face
       upstream (if (equal (magit2-get "branch" branch "remote") ".")
                    'magit2-branch-local
                  'magit2-branch-remote)))))

(defun magit2-get-indirect-upstream-branch (branch &optional force)
  (let ((remote (magit2-get "branch" branch "remote")))
    (and remote (not (equal remote "."))
         ;; The user has opted in...
         (or force
             (--some (if (magit2-git-success "check-ref-format" "--branch" it)
                         (equal it branch)
                       (string-match-p it branch))
                     magit2-branch-prefer-remote-upstream))
         ;; and local BRANCH tracks a remote branch...
         (let ((upstream (magit2-get-upstream-branch branch)))
           ;; whose upstream...
           (and upstream
                ;; has the same name as BRANCH...
                (equal (substring upstream (1+ (length remote))) branch)
                ;; and can be fast-forwarded to BRANCH.
                (magit2-rev-ancestor-p upstream branch)
                upstream)))))

(defun magit2-get-upstream-remote (&optional branch allow-unnamed)
  (when-let ((branch (or branch (magit2-get-current-branch)))
             (remote (magit2-get "branch" branch "remote")))
    (and (not (equal remote "."))
         (cond ((member remote (magit2-list-remotes))
                (magit2--propertize-face remote 'magit2-branch-remote))
               ((and allow-unnamed
                     (string-match-p "\\(\\`.\\{0,2\\}/\\|[:@]\\)" remote))
                (magit2--propertize-face remote 'bold))))))

(defun magit2-get-unnamed-upstream (&optional branch)
  (when-let ((branch (or branch (magit2-get-current-branch)))
             (remote (magit2-get "branch" branch "remote"))
             (merge  (magit2-get "branch" branch "merge")))
    (and (magit2--unnamed-upstream-p remote merge)
         (list (magit2--propertize-face remote 'bold)
               (magit2--propertize-face merge 'magit2-branch-remote)))))

(defun magit2--unnamed-upstream-p (remote merge)
  (and remote (string-match-p "\\(\\`\\.\\{0,2\\}/\\|[:@]\\)" remote)
       merge  (string-prefix-p "refs/" merge)))

(defun magit2--valid-upstream-p (remote merge)
  (and (or (equal remote ".")
           (member remote (magit2-list-remotes)))
       (string-prefix-p "refs/" merge)))

(defun magit2-get-current-remote (&optional allow-unnamed)
  (or (magit2-get-upstream-remote nil allow-unnamed)
      (when-let ((remotes (magit2-list-remotes))
                 (remote (if (= (length remotes) 1)
                             (car remotes)
                           (magit2-primary-remote))))
        (magit2--propertize-face remote 'magit2-branch-remote))))

(defun magit2-get-push-remote (&optional branch)
  (when-let ((remote
              (or (and (or branch (setq branch (magit2-get-current-branch)))
                       (magit2-get "branch" branch "pushRemote"))
                  (magit2-get "remote.pushDefault"))))
    (magit2--propertize-face remote 'magit2-branch-remote)))

(defun magit2-get-push-branch (&optional branch verify)
  (magit2--with-refresh-cache
      (list default-directory 'magit2-get-push-branch branch verify)
    (when-let ((branch (or branch (setq branch (magit2-get-current-branch))))
               (remote (magit2-get-push-remote branch))
               (target (concat remote "/" branch)))
      (and (or (not verify)
               (magit2-rev-parse target))
           (magit2--propertize-face target 'magit2-branch-remote)))))

(defun magit2-get-@{push}-branch (&optional branch)
  (let ((ref (magit2-rev-parse "--symbolic-full-name"
                              (concat branch "@{push}"))))
    (when (and ref (string-prefix-p "refs/remotes/" ref))
      (substring ref 13))))

(defun magit2-get-remote (&optional branch)
  (when (or branch (setq branch (magit2-get-current-branch)))
    (let ((remote (magit2-get "branch" branch "remote")))
      (unless (equal remote ".")
        remote))))

(defun magit2-get-some-remote (&optional branch)
  (or (magit2-get-remote branch)
      (when-let ((main (magit2-main-branch)))
        (magit2-get-remote main))
      (magit2-primary-remote)
      (car (magit2-list-remotes))))

(defvar magit2-primary-remote-names
  '("upstream" "origin"))

(defun magit2-primary-remote ()
  "Return the primary remote.

The primary remote is the remote that tracks the repository that
other repositories are forked from.  It often is called \"origin\"
but because many people name their own fork \"origin\", using that
term would be ambiguous.  Likewise we avoid the term \"upstream\"
because a branch's @{upstream} branch may be a local branch or a
branch from a remote other than the primary remote.

If a remote exists whose name matches `magit2.primaryRemote', then
that is considered the primary remote.  If no remote by that name
exists, then remotes in `magit2-primary-remote-names' are tried in
order and the first remote from that list that actually exists in
the current repository is considered its primary remote."
  (let ((remotes (magit2-list-remotes)))
    (seq-find (lambda (name)
                (member name remotes))
              (delete-dups
               (delq nil
                     (cons (magit2-get "magit2.primaryRemote")
                           magit2-primary-remote-names))))))

(defun magit2-branch-merged-p (branch &optional target)
  "Return non-nil if BRANCH is merged into its upstream and TARGET.

TARGET defaults to the current branch.  If `HEAD' is detached and
TARGET is nil, then always return nil.  As a special case, if
TARGET is t, then return non-nil if BRANCH is merged into any one
of the other local branches.

If, and only if, BRANCH has an upstream, then only return non-nil
if BRANCH is merged into both TARGET (as described above) as well
as into its upstream."
  (and (--if-let (and (magit2-branch-p branch)
                      (magit2-get-upstream-branch branch))
           (magit2-git-success "merge-base" "--is-ancestor" branch it)
         t)
       (if (eq target t)
           (delete (magit2-name-local-branch branch)
                   (magit2-list-containing-branches branch))
         (--when-let (or target (magit2-get-current-branch))
           (magit2-git-success "merge-base" "--is-ancestor" branch it)))))

(defun magit2-get-tracked (refname)
  "Return the remote branch tracked by the remote-tracking branch REFNAME.
The returned value has the form (REMOTE . REF), where REMOTE is
the name of a remote and REF is the ref local to the remote."
  (when-let ((ref (magit2-ref-fullname refname)))
    (save-match-data
      (seq-some (lambda (line)
                  (and (string-match "\
\\`remote\\.\\([^.]+\\)\\.fetch=\\+?\\([^:]+\\):\\(.+\\)" line)
                       (let ((rmt (match-string 1 line))
                             (src (match-string 2 line))
                             (dst (match-string 3 line)))
                         (and (string-match (format "\\`%s\\'"
                                                    (replace-regexp-in-string
                                                     "*" "\\(.+\\)" dst t t))
                                            ref)
                              (cons rmt (replace-regexp-in-string
                                         "*" (match-string 1 ref) src))))))
                (magit2-git-lines "config" "--local" "--list")))))

(defun magit2-split-branch-name (branch)
  (cond ((member branch (magit2-list-local-branch-names))
         (cons "." branch))
        ((string-match "/" branch)
         (or (seq-some (lambda (remote)
                         (and (string-match
                               (format "\\`\\(%s\\)/\\(.+\\)\\'" remote)
                               branch)
                              (cons (match-string 1 branch)
                                    (match-string 2 branch))))
                       (magit2-list-remotes))
             (error "Invalid branch name %s" branch)))))

(defun magit2-get-current-tag (&optional rev with-distance)
  "Return the closest tag reachable from REV.

If optional REV is nil, then default to `HEAD'.
If optional WITH-DISTANCE is non-nil then return (TAG COMMITS),
if it is `dirty' return (TAG COMMIT DIRTY). COMMITS is the number
of commits in `HEAD' but not in TAG and DIRTY is t if there are
uncommitted changes, nil otherwise."
  (--when-let (let (magit2-git-debug)
                (magit2-git-string "describe" "--long" "--tags"
                                  (and (eq with-distance 'dirty) "--dirty") rev))
    (save-match-data
      (string-match
       "\\(.+\\)-\\(?:0[0-9]*\\|\\([0-9]+\\)\\)-g[0-9a-z]+\\(-dirty\\)?$" it)
      (if with-distance
          `(,(match-string 1 it)
            ,(string-to-number (or (match-string 2 it) "0"))
            ,@(and (match-string 3 it) (list t)))
        (match-string 1 it)))))

(defun magit2-get-next-tag (&optional rev with-distance)
  "Return the closest tag from which REV is reachable.

If optional REV is nil, then default to `HEAD'.
If no such tag can be found or if the distance is 0 (in which
case it is the current tag, not the next), return nil instead.
If optional WITH-DISTANCE is non-nil, then return (TAG COMMITS)
where COMMITS is the number of commits in TAG but not in REV."
  (--when-let (let (magit2-git-debug)
                (magit2-git-string "describe" "--contains" (or rev "HEAD")))
    (save-match-data
      (when (string-match "^[^^~]+" it)
        (setq it (match-string 0 it))
        (unless (equal it (magit2-get-current-tag rev))
          (if with-distance
              (list it (car (magit2-rev-diff-count it rev)))
            it))))))

(defun magit2-list-refs (&optional namespaces format sortby)
  "Return list of references.

When NAMESPACES is non-nil, list refs from these namespaces
rather than those from `magit2-list-refs-namespaces'.

FORMAT is passed to the `--format' flag of `git for-each-ref'
and defaults to \"%(refname)\".  If the format is \"%(refname)\"
or \"%(refname:short)\", then drop the symbolic-ref `HEAD'.

SORTBY is a key or list of keys to pass to the `--sort' flag of
`git for-each-ref'.  When nil, use `magit2-list-refs-sortby'"
  (unless format
    (setq format "%(refname)"))
  (let ((refs (magit2-git-lines "for-each-ref"
                               (concat "--format=" format)
                               (--map (concat "--sort=" it)
                                      (pcase (or sortby magit2-list-refs-sortby)
                                        ((and val (pred stringp)) (list val))
                                        ((and val (pred listp)) val)))
                               (or namespaces magit2-list-refs-namespaces))))
    (if (member format '("%(refname)" "%(refname:short)"))
        (let ((case-fold-search nil))
          (--remove (string-match-p "\\(\\`\\|/\\)HEAD\\'" it)
                    refs))
      refs)))

(defun magit2-list-branches ()
  (magit2-list-refs (list "refs/heads" "refs/remotes")))

(defun magit2-list-local-branches ()
  (magit2-list-refs "refs/heads"))

(defun magit2-list-remote-branches (&optional remote)
  (magit2-list-refs (concat "refs/remotes/" remote)))

(defun magit2-list-related-branches (relation &optional commit &rest args)
  (--remove (string-match-p "\\(\\`(HEAD\\|HEAD -> \\)" it)
            (--map (substring it 2)
                   (magit2-git-lines "branch" args relation commit))))

(defun magit2-list-containing-branches (&optional commit &rest args)
  (magit2-list-related-branches "--contains" commit args))

(defun magit2-list-publishing-branches (&optional commit)
  (--filter (magit2-rev-ancestor-p (or commit "HEAD") it)
            magit2-published-branches))

(defun magit2-list-merged-branches (&optional commit &rest args)
  (magit2-list-related-branches "--merged" commit args))

(defun magit2-list-unmerged-branches (&optional commit &rest args)
  (magit2-list-related-branches "--no-merged" commit args))

(defun magit2-list-unmerged-to-upstream-branches ()
  (--filter (when-let ((upstream (magit2-get-upstream-branch it)))
              (member it (magit2-list-unmerged-branches upstream)))
            (magit2-list-local-branch-names)))

(defun magit2-list-branches-pointing-at (commit)
  (let ((re (format "\\`%s refs/\\(heads\\|remotes\\)/\\(.*\\)\\'"
                    (magit2-rev-parse commit))))
    (--keep (and (string-match re it)
                 (let ((name (match-string 2 it)))
                   (and (not (string-suffix-p "HEAD" name))
                        name)))
            (magit2-git-lines "show-ref"))))

(defun magit2-list-refnames (&optional namespaces include-special)
  (nconc (magit2-list-refs namespaces "%(refname:short)")
         (and include-special
              (magit2-list-special-refnames))))

(defvar magit2-special-refnames
  '("HEAD" "ORIG_HEAD" "FETCH_HEAD" "MERGE_HEAD" "CHERRY_PICK_HEAD"))

(defun magit2-list-special-refnames ()
  (let ((gitdir (magit2-gitdir)))
    (cl-mapcan (lambda (name)
                 (and (file-exists-p (expand-file-name name gitdir))
                      (list name)))
               magit2-special-refnames)))

(defun magit2-list-branch-names ()
  (magit2-list-refnames (list "refs/heads" "refs/remotes")))

(defun magit2-list-local-branch-names ()
  (magit2-list-refnames "refs/heads"))

(defun magit2-list-remote-branch-names (&optional remote relative)
  (if (and remote relative)
      (let ((regexp (format "^refs/remotes/%s/\\(.+\\)" remote)))
        (--mapcat (when (string-match regexp it)
                    (list (match-string 1 it)))
                  (magit2-list-remote-branches remote)))
    (magit2-list-refnames (concat "refs/remotes/" remote))))

(defun magit2-format-refs (format &rest args)
  (let ((lines (magit2-git-lines
                "for-each-ref" (concat "--format=" format)
                (or args (list "refs/heads" "refs/remotes" "refs/tags")))))
    (if (string-match-p "\f" format)
        (--map (split-string it "\f") lines)
      lines)))

(defun magit2-list-remotes ()
  (magit2-git-lines "remote"))

(defun magit2-list-tags ()
  (magit2-git-lines "tag"))

(defun magit2-list-stashes (&optional format)
  (magit2-git-lines "stash" "list" (concat "--format=" (or format "%gd"))))

(defun magit2-list-active-notes-refs ()
  "Return notes refs according to `core.notesRef' and `notes.displayRef'."
  (magit2-git-lines "for-each-ref" "--format=%(refname)"
                   (or (magit2-get "core.notesRef") "refs/notes/commits")
                   (magit2-get-all "notes.displayRef")))

(defun magit2-list-notes-refnames ()
  (--map (substring it 6) (magit2-list-refnames "refs/notes")))

(defun magit2-remote-list-tags (remote)
  (--keep (and (not (string-match-p "\\^{}$" it))
               (substring it 51))
          (magit2-git-lines "ls-remote" "--tags" remote)))

(defun magit2-remote-list-branches (remote)
  (--keep (and (not (string-match-p "\\^{}$" it))
               (substring it 52))
          (magit2-git-lines "ls-remote" "--heads" remote)))

(defun magit2-remote-list-refs (remote)
  (--keep (and (not (string-match-p "\\^{}$" it))
               (substring it 41))
          (magit2-git-lines "ls-remote" remote)))

(defun magit2-list-modified-modules ()
  (--keep (and (string-match "\\`\\+\\([^ ]+\\) \\(.+\\) (.+)\\'" it)
               (match-string 2 it))
          (magit2-git-lines "submodule" "status")))

(defun magit2-list-module-paths ()
  (--mapcat (and (string-match "^160000 [0-9a-z]\\{40,\\} 0\t\\(.+\\)$" it)
                 (list (match-string 1 it)))
            (magit2-git-items "ls-files" "-z" "--stage")))

(defun magit2-list-module-names ()
  (mapcar #'magit2-get-submodule-name (magit2-list-module-paths)))

(defun magit2-get-submodule-name (path)
  "Return the name of the submodule at PATH.
PATH has to be relative to the super-repository."
  (magit2-git-string "submodule--helper" "name" path))

(defun magit2-list-worktrees ()
  (let ((remote (file-remote-p default-directory))
        worktrees worktree)
    (dolist (line (let ((magit2-git-global-arguments
                         ;; KLUDGE At least in v2.8.3 this triggers a segfault.
                         (remove "--no-pager" magit2-git-global-arguments)))
                    (magit2-git-lines "worktree" "list" "--porcelain")))
      (cond ((string-prefix-p "worktree" line)
             (let ((path (substring line 9)))
               (when remote
                 (setq path (concat remote path)))
               ;; If the git directory is separate from the main
               ;; worktree, then "git worktree" returns the git
               ;; directory instead of the worktree, which isn't
               ;; what it is supposed to do and not what we want.
               (setq path (magit2-toplevel path))
               (setq worktree (list path nil nil nil))
               (push worktree worktrees)))
            ((string-equal line "bare")
             (let* ((default-directory (car worktree))
                    (wt (and (not (magit2-get-boolean "core.bare"))
                             (magit2-get "core.worktree"))))
               (if (and wt (file-exists-p (expand-file-name wt)))
                   (progn (setf (nth 0 worktree) (expand-file-name wt))
                          (setf (nth 2 worktree) (magit2-rev-parse "HEAD"))
                          (setf (nth 3 worktree) (magit2-get-current-branch)))
                 (setf (nth 1 worktree) t))))
            ((string-prefix-p "HEAD" line)
             (setf (nth 2 worktree) (substring line 5)))
            ((string-prefix-p "branch" line)
             (setf (nth 3 worktree) (substring line 18)))
            ((string-equal line "detached"))))
    (nreverse worktrees)))

(defun magit2-symbolic-ref-p (name)
  (magit2-git-success "symbolic-ref" "--quiet" name))

(defun magit2-ref-p (rev)
  (or (car (member rev (magit2-list-refs "refs/")))
      (car (member rev (magit2-list-refnames "refs/")))))

(defun magit2-branch-p (rev)
  (or (car (member rev (magit2-list-branches)))
      (car (member rev (magit2-list-branch-names)))))

(defun magit2-local-branch-p (rev)
  (or (car (member rev (magit2-list-local-branches)))
      (car (member rev (magit2-list-local-branch-names)))))

(defun magit2-remote-branch-p (rev)
  (or (car (member rev (magit2-list-remote-branches)))
      (car (member rev (magit2-list-remote-branch-names)))))

(defun magit2-branch-set-face (branch)
  (magit2--propertize-face branch (if (magit2-local-branch-p branch)
                                     'magit2-branch-local
                                   'magit2-branch-remote)))

(defun magit2-tag-p (rev)
  (car (member rev (magit2-list-tags))))

(defun magit2-remote-p (string)
  (car (member string (magit2-list-remotes))))

(defvar magit2-main-branch-names
  ;; These are the names that Git suggests
  ;; if `init.defaultBranch' is undefined.
  '("main" "master" "trunk" "development"))

(defun magit2-main-branch ()
  "Return the main branch.

If a branch exists whose name matches `init.defaultBranch', then
that is considered the main branch.  If no branch by that name
exists, then the branch names in `magit2-main-branch-names' are
tried in order.  The first branch from that list that actually
exists in the current repository is considered its main branch."
  (let ((branches (magit2-list-local-branch-names)))
    (seq-find (lambda (name)
                (member name branches))
              (delete-dups
               (delq nil
                     (cons (magit2-get "init.defaultBranch")
                           magit2-main-branch-names))))))

(defun magit2-rev-diff-count (a b)
  "Return the commits in A but not B and vice versa.
Return a list of two integers: (A>B B>A)."
  (mapcar 'string-to-number
          (split-string (magit2-git-string "rev-list"
                                          "--count" "--left-right"
                                          (concat a "..." b))
                        "\t")))

(defun magit2-abbrev-length ()
  (let ((abbrev (magit2-get "core.abbrev")))
    (if (and abbrev (not (equal abbrev "auto")))
        (string-to-number abbrev)
      ;; Guess the length git will be using based on an example
      ;; abbreviation.  Actually HEAD's abbreviation might be an
      ;; outlier, so use the shorter of the abbreviations for two
      ;; commits.  See #3034.
      (if-let ((head (magit2-rev-parse "--short" "HEAD"))
               (head-len (length head)))
          (min head-len
               (--if-let (magit2-rev-parse "--short" "HEAD~")
                   (length it)
                 head-len))
        ;; We're on an unborn branch, but perhaps the repository has
        ;; other commits.  See #4123.
        (if-let ((commits (magit2-git-lines "rev-list" "-n2" "--all"
                                           "--abbrev-commit")))
            (apply #'min (mapcar #'length commits))
          ;; A commit does not exist.  Fall back to the default of 7.
          7)))))

(defun magit2-abbrev-arg (&optional arg)
  (format "--%s=%d" (or arg "abbrev") (magit2-abbrev-length)))

(defun magit2-rev-abbrev (rev)
  (magit2-rev-parse (magit2-abbrev-arg "short") rev))

(defun magit2-commit-children (commit &optional args)
  (mapcar #'car
          (--filter (member commit (cdr it))
                    (--map (split-string it " ")
                           (magit2-git-lines
                            "log" "--format=%H %P"
                            (or args (list "--branches" "--tags" "--remotes"))
                            "--not" commit)))))

(defun magit2-commit-parents (commit)
  (--when-let (magit2-git-string "rev-list" "-1" "--parents" commit)
    (cdr (split-string it))))

(defun magit2-patch-id (rev)
  (magit2--with-connection-local-variables
   (magit2--with-temp-process-buffer
     (magit2-process-file
      shell-file-name nil '(t nil) nil shell-command-switch
      (let ((exec (shell-quote-argument (magit2-git-executable))))
        (format "%s diff-tree -u %s | %s patch-id" exec rev exec)))
     (car (split-string (buffer-string))))))

(defun magit2-rev-format (format &optional rev args)
  (let ((str (magit2-git-string "show" "--no-patch"
                               (concat "--format=" format) args
                               (if rev (concat rev "^{commit}") "HEAD") "--")))
    (unless (string-equal str "")
      str)))

(defun magit2-rev-insert-format (format &optional rev args)
  (magit2-git-insert "show" "--no-patch"
                    (concat "--format=" format) args
                    (if rev (concat rev "^{commit}") "HEAD") "--"))

(defun magit2-format-rev-summary (rev)
  (--when-let (magit2-rev-format "%h %s" rev)
    (string-match " " it)
    (magit2--put-face 0 (match-beginning 0) 'magit2-hash it)
    it))

(defvar magit2-ref-namespaces
  '(("\\`HEAD\\'"                  . magit2-head)
    ("\\`refs/tags/\\(.+\\)"       . magit2-tag)
    ("\\`refs/heads/\\(.+\\)"      . magit2-branch-local)
    ("\\`refs/remotes/\\(.+\\)"    . magit2-branch-remote)
    ("\\`refs/bisect/\\(bad\\)"    . magit2-bisect-bad)
    ("\\`refs/bisect/\\(skip.*\\)" . magit2-bisect-skip)
    ("\\`refs/bisect/\\(good.*\\)" . magit2-bisect-good)
    ("\\`refs/stash$"              . magit2-refname-stash)
    ("\\`refs/wip/\\(.+\\)"        . magit2-refname-wip)
    ("\\`refs/pullreqs/\\(.+\\)"   . magit2-refname-pullreq)
    ("\\`\\(bad\\):"               . magit2-bisect-bad)
    ("\\`\\(skip\\):"              . magit2-bisect-skip)
    ("\\`\\(good\\):"              . magit2-bisect-good)
    ("\\`\\(.+\\)"                 . magit2-refname))
  "How refs are formatted for display.

Each entry controls how a certain type of ref is displayed, and
has the form (REGEXP . FACE).  REGEXP is a regular expression
used to match full refs.  The first entry whose REGEXP matches
the reference is used.

In log and revision buffers the first regexp submatch becomes the
\"label\" that represents the ref and is propertized with FONT.
In refs buffers the displayed text is controlled by other means
and this option only controls what face is used.")

(defun magit2-format-ref-labels (string)
  (save-match-data
    (let ((regexp "\\(, \\|tag: \\|HEAD -> \\)")
          names)
      (if (and (derived-mode-p 'magit2-log-mode)
               (member "--simplify-by-decoration" magit2-buffer-log-args))
          (let ((branches (magit2-list-local-branch-names))
                (re (format "^%s/.+" (regexp-opt (magit2-list-remotes)))))
            (setq names
                  (--map (cond ((string-equal it "HEAD")     it)
                               ((string-prefix-p "refs/" it) it)
                               ((member it branches) (concat "refs/heads/" it))
                               ((string-match re it) (concat "refs/remotes/" it))
                               (t                    (concat "refs/" it)))
                         (split-string
                          (replace-regexp-in-string "tag: " "refs/tags/" string)
                          regexp t))))
        (setq names (split-string string regexp t)))
      (let (state head upstream tags branches remotes other combined)
        (dolist (ref names)
          (let* ((face (cdr (--first (string-match (car it) ref)
                                     magit2-ref-namespaces)))
                 (name (magit2--propertize-face
                        (or (match-string 1 ref) ref) face)))
            (cl-case face
              ((magit2-bisect-bad magit2-bisect-skip magit2-bisect-good)
               (setq state name))
              (magit2-head
               (setq head (magit2--propertize-face "@" 'magit2-head)))
              (magit2-tag            (push name tags))
              (magit2-branch-local   (push name branches))
              (magit2-branch-remote  (push name remotes))
              (t                    (push name other)))))
        (setq remotes
              (-keep
               (lambda (name)
                 (if (string-match "\\`\\([^/]*\\)/\\(.*\\)\\'" name)
                     (let ((r (match-string 1 name))
                           (b (match-string 2 name)))
                       (and (not (equal b "HEAD"))
                            (if (equal (concat "refs/remotes/" name)
                                       (magit2-git-string
                                        "symbolic-ref"
                                        (format "refs/remotes/%s/HEAD" r)))
                                (magit2--propertize-face
                                 name 'magit2-branch-remote-head)
                              name)))
                   name))
               remotes))
        (let* ((current (magit2-get-current-branch))
               (target  (magit2-get-upstream-branch current)))
          (dolist (name branches)
            (let ((push (car (member (magit2-get-push-branch name) remotes))))
              (when push
                (setq remotes (delete push remotes))
                (string-match "^[^/]*/" push)
                (setq push (substring push 0 (match-end 0))))
              (cond
               ((equal name current)
                (setq head
                      (concat push
                              (magit2--propertize-face
                               name 'magit2-branch-current))))
               ((equal name target)
                (setq upstream
                      (concat push
                              (magit2--propertize-face
                               name '(magit2-branch-upstream
                                      magit2-branch-local)))))
               (t
                (push (concat push name) combined)))))
          (when (and target (not upstream))
            (if (member target remotes)
                (progn
                  (magit2--add-face-text-property
                   0 (length target) 'magit2-branch-upstream nil target)
                  (setq upstream target)
                  (setq remotes  (delete target remotes)))
              (when-let ((target (car (member target combined))))
                (magit2--add-face-text-property
                 0 (length target) 'magit2-branch-upstream nil target)
                (setq upstream target)
                (setq combined (delete target combined))))))
        (mapconcat #'identity
                   (-flatten `(,state
                               ,head
                               ,upstream
                               ,@(nreverse tags)
                               ,@(nreverse combined)
                               ,@(nreverse remotes)
                               ,@other))
                   " ")))))

(defun magit2-object-type (object)
  (magit2-git-string "cat-file" "-t" object))

(defmacro magit2-with-blob (commit file &rest body)
  (declare (indent 2)
           (debug (form form body)))
  `(magit2--with-temp-process-buffer
     (let ((buffer-file-name ,file))
       (save-excursion
         (magit2-git-insert "cat-file" "-p"
                           (concat ,commit ":" buffer-file-name)))
       (decode-coding-inserted-region
        (point-min) (point-max) buffer-file-name t nil nil t)
       ,@body)))

(defmacro magit2-with-temp-index (tree arg &rest body)
  (declare (indent 2) (debug (form form body)))
  (let ((file (cl-gensym "file")))
    `(let ((magit2--refresh-cache nil)
           (,file (magit2-convert-filename-for-git
                   (make-temp-name (magit2-git-dir "index.magit2.")))))
       (unwind-protect
           (magit2-with-toplevel
             (--when-let ,tree
               (or (magit2-git-success "read-tree" ,arg it
                                      (concat "--index-output=" ,file))
                   (error "Cannot read tree %s" it)))
             (if (file-remote-p default-directory)
                 (let ((magit2-tramp-process-environment
                        (cons (concat "GIT_INDEX_FILE=" ,file)
                              magit2-tramp-process-environment)))
                   ,@body)
               (let ((process-environment
                      (cons (concat "GIT_INDEX_FILE=" ,file)
                            process-environment)))
                 ,@body)))
         (ignore-errors
           (delete-file (concat (file-remote-p default-directory) ,file)))))))

(defun magit2-commit-tree (message &optional tree &rest parents)
  (magit2-git-string "commit-tree" "--no-gpg-sign" "-m" message
                    (--mapcat (list "-p" it) (delq nil parents))
                    (or tree
                        (magit2-git-string "write-tree")
                        (error "Cannot write tree"))))

(defun magit2-commit-worktree (message &optional arg &rest other-parents)
  (magit2-with-temp-index "HEAD" arg
    (and (magit2-update-files (magit2-unstaged-files))
         (apply #'magit2-commit-tree message nil "HEAD" other-parents))))

(defun magit2-update-files (files)
  (magit2-git-success "update-index" "--add" "--remove" "--" files))

(defun magit2-update-ref (ref message rev &optional stashish)
  (let ((magit2--refresh-cache nil))
    (or (if (magit2-git-version>= "2.6.0")
            (zerop (magit2-call-git "update-ref" "--create-reflog"
                                   "-m" message ref rev
                                   (or (magit2-rev-parse ref) "")))
          ;; `--create-reflog' didn't exist before v2.6.0
          (let ((oldrev  (magit2-rev-parse ref))
                (logfile (magit2-git-dir (concat "logs/" ref))))
            (unless (file-exists-p logfile)
              (when oldrev
                (magit2-git-success "update-ref" "-d" ref oldrev))
              (make-directory (file-name-directory logfile) t)
              (with-temp-file logfile)
              (when (and oldrev (not stashish))
                (magit2-git-success "update-ref" "-m" "enable reflog"
                                   ref oldrev ""))))
          (magit2-git-success "update-ref" "-m" message ref rev
                             (or (magit2-rev-parse ref) "")))
        (error "Cannot update %s with %s" ref rev))))

(defconst magit2-range-re
  (concat "\\`\\([^ \t]*[^.]\\)?"       ; revA
          "\\(\\.\\.\\.?\\)"            ; range marker
          "\\([^.][^ \t]*\\)?\\'"))     ; revB

(defun magit2-split-range (range)
  (and (string-match magit2-range-re range)
       (let ((beg (or (match-string 1 range) "HEAD"))
             (end (or (match-string 3 range) "HEAD")))
         (cons (if (string-equal (match-string 2 range) "...")
                   (magit2-git-string "merge-base" beg end)
                 beg)
               end))))

(defun magit2-hash-range (range)
  (if (string-match magit2-range-re range)
      (concat (magit2-rev-hash (match-string 1 range))
              (match-string 2 range)
              (magit2-rev-hash (match-string 3 range)))
    (magit2-rev-hash range)))

(put 'git-revision 'thing-at-point 'magit2-thingatpt--git-revision)
(defun magit2-thingatpt--git-revision ()
  (--when-let
      (let ((c "\s\n\t~^:?*[\\"))
        (cl-letf (((get 'git-revision 'beginning-op)
                   (lambda ()
                     (if (re-search-backward (format "[%s]" c) nil t)
                         (forward-char)
                       (goto-char (point-min)))))
                  ((get 'git-revision 'end-op)
                   (lambda ()
                     (re-search-forward (format "\\=[^%s]*" c) nil t))))
          (bounds-of-thing-at-point 'git-revision)))
    (let ((text (buffer-substring-no-properties (car it) (cdr it))))
      (and (>= (length text) 7)
           (string-match-p "[a-z]" text)
           (magit2-rev-hash text)
           text))))

;;; Completion

(defvar magit2-revision-history nil)

(defun magit2--minibuf-default-add-commit ()
  (let ((fn minibuffer-default-add-function))
    (lambda ()
      (if-let ((commit (with-selected-window (minibuffer-selected-window)
                         (magit2-commit-at-point))))
          (cons commit (delete commit (funcall fn)))
        (funcall fn)))))

(defun magit2-read-branch (prompt &optional secondary-default)
  (magit2-completing-read prompt (magit2-list-branch-names)
                         nil t nil 'magit2-revision-history
                         (or (magit2-branch-at-point)
                             secondary-default
                             (magit2-get-current-branch))))

(defun magit2-read-branch-or-commit (prompt &optional secondary-default)
  (let ((minibuffer-default-add-function (magit2--minibuf-default-add-commit)))
    (or (magit2-completing-read prompt (magit2-list-refnames nil t)
                               nil nil nil 'magit2-revision-history
                               (or (magit2-branch-or-commit-at-point)
                                   secondary-default
                                   (magit2-get-current-branch)))
        (user-error "Nothing selected"))))

(defun magit2-read-range-or-commit (prompt &optional secondary-default)
  (magit2-read-range
   prompt
   (or (--when-let (magit2-region-values '(commit branch) t)
         (deactivate-mark)
         (concat (car (last it)) ".." (car it)))
       (magit2-branch-or-commit-at-point)
       secondary-default
       (magit2-get-current-branch))))

(defun magit2-read-range (prompt &optional default)
  (let ((minibuffer-default-add-function (magit2--minibuf-default-add-commit))
        (crm-separator "\\.\\.\\.?"))
    (magit2-completing-read-multiple*
     (concat prompt ": ")
     (magit2-list-refnames)
     nil nil nil 'magit2-revision-history default nil t)))

(defun magit2-read-remote-branch
    (prompt &optional remote default local-branch require-match)
  (let ((choice (magit2-completing-read
                 prompt
                 (-union (and local-branch
                              (if remote
                                  (concat remote "/" local-branch)
                                (--map (concat it "/" local-branch)
                                       (magit2-list-remotes))))
                         (magit2-list-remote-branch-names remote t))
                 nil require-match nil 'magit2-revision-history default)))
    (if (or remote (string-match "\\`\\([^/]+\\)/\\(.+\\)" choice))
        choice
      (user-error "`%s' doesn't have the form REMOTE/BRANCH" choice))))

(defun magit2-read-refspec (prompt remote)
  (magit2-completing-read prompt
                         (prog2 (message "Determining available refs...")
                             (magit2-remote-list-refs remote)
                           (message "Determining available refs...done"))))

(defun magit2-read-local-branch (prompt &optional secondary-default)
  (magit2-completing-read prompt (magit2-list-local-branch-names)
                         nil t nil 'magit2-revision-history
                         (or (magit2-local-branch-at-point)
                             secondary-default
                             (magit2-get-current-branch))))

(defun magit2-read-local-branch-or-commit (prompt)
  (let ((minibuffer-default-add-function (magit2--minibuf-default-add-commit))
        (choices (nconc (magit2-list-local-branch-names)
                        (magit2-list-special-refnames)))
        (commit (magit2-commit-at-point)))
    (when commit
      (push commit choices))
    (or (magit2-completing-read prompt choices
                               nil nil nil 'magit2-revision-history
                               (or (magit2-local-branch-at-point) commit))
        (user-error "Nothing selected"))))

(defun magit2-read-local-branch-or-ref (prompt &optional secondary-default)
  (magit2-completing-read prompt (nconc (magit2-list-local-branch-names)
                                       (magit2-list-refs "refs/"))
                         nil t nil 'magit2-revision-history
                         (or (magit2-local-branch-at-point)
                             secondary-default
                             (magit2-get-current-branch))))

(defun magit2-read-other-branch
    (prompt &optional exclude secondary-default no-require-match)
  (let* ((current (magit2-get-current-branch))
         (atpoint (magit2-branch-at-point))
         (exclude (or exclude current))
         (default (or (and (not (equal atpoint exclude)) atpoint)
                      (and (not (equal current exclude)) current)
                      secondary-default
                      (magit2-get-previous-branch))))
    (magit2-completing-read prompt (delete exclude (magit2-list-branch-names))
                           nil (not no-require-match)
                           nil 'magit2-revision-history default)))

(defun magit2-read-other-branch-or-commit
    (prompt &optional exclude secondary-default)
  (let* ((minibuffer-default-add-function (magit2--minibuf-default-add-commit))
         (current (magit2-get-current-branch))
         (atpoint (magit2-branch-or-commit-at-point))
         (exclude (or exclude current))
         (default (or (and (not (equal atpoint exclude))
                           (not (and (not current)
                                     (magit2-rev-equal atpoint "HEAD")))
                           atpoint)
                      (and (not (equal current exclude)) current)
                      secondary-default
                      (magit2-get-previous-branch))))
    (or (magit2-completing-read prompt (delete exclude (magit2-list-refnames))
                               nil nil nil 'magit2-revision-history default)
        (user-error "Nothing selected"))))

(defun magit2-read-other-local-branch
    (prompt &optional exclude secondary-default no-require-match)
  (let* ((current (magit2-get-current-branch))
         (atpoint (magit2-local-branch-at-point))
         (exclude (or exclude current))
         (default (or (and (not (equal atpoint exclude)) atpoint)
                      (and (not (equal current exclude)) current)
                      secondary-default
                      (magit2-get-previous-branch))))
    (magit2-completing-read prompt
                           (delete exclude (magit2-list-local-branch-names))
                           nil (not no-require-match)
                           nil 'magit2-revision-history default)))

(defun magit2-read-branch-prefer-other (prompt)
  (let* ((current (magit2-get-current-branch))
         (commit  (magit2-commit-at-point))
         (atrev   (and commit (magit2-list-branches-pointing-at commit)))
         (atpoint (magit2--painted-branch-at-point)))
    (magit2-completing-read prompt (magit2-list-branch-names)
                           nil t nil 'magit2-revision-history
                           (or (magit2-section-value-if 'branch)
                               atpoint
                               (and (not (cdr atrev)) (car atrev))
                               (--first (not (equal it current)) atrev)
                               (magit2-get-previous-branch)
                               (car atrev)))))

(defun magit2-read-upstream-branch (&optional branch prompt)
  "Read the upstream for BRANCH using PROMPT.
If optional BRANCH is nil, then read the upstream for the
current branch, or raise an error if no branch is checked
out.  Only existing branches can be selected."
  (unless branch
    (setq branch (or (magit2-get-current-branch)
                     (error "Need a branch to set its upstream"))))
  (let ((branches (delete branch (magit2-list-branch-names))))
    (magit2-completing-read
     (or prompt (format "Change upstream of %s to" branch))
     branches nil t nil 'magit2-revision-history
     (or (let ((r (car (member (magit2-remote-branch-at-point) branches)))
               (l (car (member (magit2-local-branch-at-point) branches))))
           (if magit2-prefer-remote-upstream (or r l) (or l r)))
         (when-let ((main (magit2-main-branch)))
           (let ((r (car (member (concat "origin/" main) branches)))
                 (l (car (member main branches))))
             (if magit2-prefer-remote-upstream (or r l) (or l r))))
         (car (member (magit2-get-previous-branch) branches))))))

(defun magit2-read-starting-point (prompt &optional branch default)
  (or (magit2-completing-read
       (concat prompt
               (and branch
                    (if (bound-and-true-p ivy-mode)
                        ;; Ivy-mode strips faces from prompt.
                        (format  " `%s'" branch)
                      (concat " " (magit2--propertize-face
                                   branch 'magit2-branch-local))))
               " starting at")
       (nconc (list "HEAD")
              (magit2-list-refnames)
              (directory-files (magit2-git-dir) nil "_HEAD\\'"))
       nil nil nil 'magit2-revision-history
       (or default (magit2--default-starting-point)))
      (user-error "Nothing selected")))

(defun magit2--default-starting-point ()
  (or (let ((r (magit2-remote-branch-at-point))
            (l (magit2-local-branch-at-point)))
        (if magit2-prefer-remote-upstream (or r l) (or l r)))
      (magit2-commit-at-point)
      (magit2-stash-at-point)
      (magit2-get-current-branch)))

(defun magit2-read-tag (prompt &optional require-match)
  (magit2-completing-read prompt (magit2-list-tags) nil
                         require-match nil 'magit2-revision-history
                         (magit2-tag-at-point)))

(defun magit2-read-stash (prompt)
  (let* ((atpoint (magit2-stash-at-point))
         (default (and atpoint
                       (concat atpoint (magit2-rev-format " %s" atpoint))))
         (choices (mapcar (lambda (c)
                            (pcase-let ((`(,rev ,msg) (split-string c "\0")))
                              (concat (propertize rev 'face 'magit2-hash)
                                      " " msg)))
                          (magit2-list-stashes "%gd%x00%s")))
         (choice  (magit2-completing-read prompt choices
                                         nil t nil nil
                                         default
                                         (car choices))))
    (and choice
         (string-match "^\\([^ ]+\\) \\(.+\\)" choice)
         (substring-no-properties (match-string 1 choice)))))

(defun magit2-read-remote (prompt &optional default use-only)
  (let ((remotes (magit2-list-remotes)))
    (if (and use-only (= (length remotes) 1))
        (car remotes)
      (magit2-completing-read prompt remotes
                             nil t nil nil
                             (or default
                                 (magit2-remote-at-point)
                                 (magit2-get-remote))))))

(defun magit2-read-remote-or-url (prompt &optional default)
  (magit2-completing-read prompt
                         (nconc (magit2-list-remotes)
                                (list "https://" "git://" "git@"))
                         nil nil nil nil
                         (or default
                             (magit2-remote-at-point)
                             (magit2-get-remote))))

(defun magit2-read-module-path (prompt &optional predicate)
  (magit2-completing-read prompt (magit2-list-module-paths)
                         predicate t nil nil
                         (magit2-module-at-point predicate)))

(defun magit2-module-confirm (verb &optional predicate)
  (let (modules)
    (if current-prefix-arg
        (progn
          (setq modules (magit2-list-module-paths))
          (when predicate
            (setq modules (-filter predicate modules)))
          (unless modules
            (if predicate
                (user-error "No modules satisfying %s available" predicate)
              (user-error "No modules available"))))
      (setq modules (magit2-region-values 'magit2-module-section))
      (when modules
        (when predicate
          (setq modules (-filter predicate modules)))
        (unless modules
          (user-error "No modules satisfying %s selected" predicate))))
    (if (> (length modules) 1)
        (magit2-confirm t nil (format "%s %%i modules" verb) nil modules)
      (list (magit2-read-module-path (format "%s module" verb) predicate)))))

;;; _
(provide 'magit2-git)
;;; magit2-git.el ends here
