;;; magit2-log.el --- inspect Git history  -*- lexical-binding: t -*-

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

;; This library implements support for looking at Git logs, including
;; special logs like cherry-logs, as well as for selecting a commit
;; from a log.

;;; Code:

(require 'magit2-core)
(require 'magit2-diff)

(declare-function magit2-blob-visit "magit2-files" (blob-or-file))
(declare-function magit2-insert-head-branch-header "magit2-status"
                  (&optional branch))
(declare-function magit2-insert-upstream-branch-header "magit2-status"
                  (&optional branch pull keyword))
(declare-function magit2-read-file-from-rev "magit2-files"
                  (rev prompt &optional default))
(declare-function magit2-rebase--get-state-lines "magit2-sequence"
                  (file))
(declare-function magit2-show-commit "magit2-diff"
                  (arg1 &optional arg2 arg3 arg4))
(declare-function magit2-reflog-format-subject "magit2-reflog" (subject))
(defvar magit2-refs-focus-column-width)
(defvar magit2-refs-margin)
(defvar magit2-refs-show-commit-count)
(defvar magit2-buffer-margin)
(defvar magit2-status-margin)
(defvar magit2-status-sections-hook)

(require 'ansi-color)
(require 'crm)
(require 'which-func)

;;; Options
;;;; Log Mode

(defgroup magit2-log nil
  "Inspect and manipulate Git history."
  :link '(info-link "(magit2)Logging")
  :group 'magit2-commands
  :group 'magit2-modes)

(defcustom magit2-log-mode-hook nil
  "Hook run after entering Magit-Log mode."
  :group 'magit2-log
  :type 'hook)

(defcustom magit2-log-remove-graph-args '("--follow" "--grep" "-G" "-S" "-L")
  "The log arguments that cause the `--graph' argument to be dropped."
  :package-version '(magit2 . "2.3.0")
  :group 'magit2-log
  :type '(repeat (string :tag "Argument"))
  :options '("--follow" "--grep" "-G" "-S" "-L"))

(defcustom magit2-log-revision-headers-format "\
%+b%+N
Author:    %aN <%aE>
Committer: %cN <%cE>"
  "Additional format string used with the `++header' argument."
  :package-version '(magit2 . "3.2.0")
  :group 'magit2-log
  :type 'string)

(defcustom magit2-log-auto-more nil
  "Insert more log entries automatically when moving past the last entry.
Only considered when moving past the last entry with
`magit2-goto-*-section' commands."
  :group 'magit2-log
  :type 'boolean)

(defcustom magit2-log-margin '(t age magit2-log-margin-width t 18)
  "Format of the margin in `magit2-log-mode' buffers.

The value has the form (INIT STYLE WIDTH AUTHOR AUTHOR-WIDTH).

If INIT is non-nil, then the margin is shown initially.
STYLE controls how to format the author or committer date.
  It can be one of `age' (to show the age of the commit),
  `age-abbreviated' (to abbreviate the time unit to a character),
  or a string (suitable for `format-time-string') to show the
  actual date.  Option `magit2-log-margin-show-committer-date'
  controls which date is being displayed.
WIDTH controls the width of the margin.  This exists for forward
  compatibility and currently the value should not be changed.
AUTHOR controls whether the name of the author is also shown by
  default.
AUTHOR-WIDTH has to be an integer.  When the name of the author
  is shown, then this specifies how much space is used to do so."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-log
  :group 'magit2-margin
  :type magit2-log-margin--custom-type
  :initialize 'magit2-custom-initialize-reset
  :set (apply-partially #'magit2-margin-set-variable 'magit2-log-mode))

(defcustom magit2-log-margin-show-committer-date nil
  "Whether to show the committer date in the margin.

This option only controls whether the committer date is displayed
instead of the author date.  Whether some date is displayed in
the margin and whether the margin is displayed at all is
controlled by other options."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-log
  :group 'magit2-margin
  :type 'boolean)

(defcustom magit2-log-show-refname-after-summary nil
  "Whether to show refnames after commit summaries.
This is useful if you use really long branch names."
  :package-version '(magit2 . "2.2.0")
  :group 'magit2-log
  :type 'boolean)

(defcustom magit2-log-highlight-keywords t
  "Whether to highlight bracketed keywords in commit summaries."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-log
  :type 'boolean)

(defcustom magit2-log-header-line-function 'magit2-log-header-line-sentence
  "Function used to generate text shown in header line of log buffers."
  :package-version '(magit2 . "2.12.0")
  :group 'magit2-log
  :type '(choice (function-item magit2-log-header-line-arguments)
                 (function-item magit2-log-header-line-sentence)
                 function))

(defcustom magit2-log-trace-definition-function 'magit2-which-function
  "Function used to determine the function at point.
This is used by the command `magit2-log-trace-definition'.
You should prefer `magit2-which-function' over `which-function'
because the latter may make use of Imenu's outdated cache."
  :package-version '(magit2 . "3.0.0")
  :group 'magit2-log
  :type '(choice (function-item magit2-which-function)
                 (function-item which-function)
                 (function-item add-log-current-defun)
                 function))

(defface magit2-log-graph
  '((((class color) (background light)) :foreground "grey30")
    (((class color) (background  dark)) :foreground "grey80"))
  "Face for the graph part of the log output."
  :group 'magit2-faces)

(defface magit2-log-author
  '((((class color) (background light))
     :foreground "firebrick"
     :slant normal
     :weight normal)
    (((class color) (background  dark))
     :foreground "tomato"
     :slant normal
     :weight normal))
  "Face for the author part of the log output."
  :group 'magit2-faces)

(defface magit2-log-date
  '((((class color) (background light))
     :foreground "grey30"
     :slant normal
     :weight normal)
    (((class color) (background  dark))
     :foreground "grey80"
     :slant normal
     :weight normal))
  "Face for the date part of the log output."
  :group 'magit2-faces)

(defface magit2-header-line-log-select
  '((t :inherit bold))
  "Face for the `header-line' in `magit2-log-select-mode'."
  :group 'magit2-faces)

;;;; File Log

(defcustom magit2-log-buffer-file-locked t
  "Whether `magit2-log-buffer-file-quick' uses a dedicated buffer."
  :package-version '(magit2 . "2.7.0")
  :group 'magit2-commands
  :group 'magit2-log
  :type 'boolean)

;;;; Select Mode

(defcustom magit2-log-select-show-usage 'both
  "Whether to show usage information when selecting a commit from a log.
The message can be shown in the `echo-area' or the `header-line', or in
`both' places.  If the value isn't one of these symbols, then it should
be nil, in which case no usage information is shown."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-log
  :type '(choice (const :tag "in echo-area" echo-area)
                 (const :tag "in header-line" header-line)
                 (const :tag "in both places" both)
                 (const :tag "nowhere")))

(defcustom magit2-log-select-margin
  (list (nth 0 magit2-log-margin)
        (nth 1 magit2-log-margin)
        'magit2-log-margin-width t
        (nth 4 magit2-log-margin))
  "Format of the margin in `magit2-log-select-mode' buffers.

The value has the form (INIT STYLE WIDTH AUTHOR AUTHOR-WIDTH).

If INIT is non-nil, then the margin is shown initially.
STYLE controls how to format the author or committer date.
  It can be one of `age' (to show the age of the commit),
  `age-abbreviated' (to abbreviate the time unit to a character),
  or a string (suitable for `format-time-string') to show the
  actual date.  Option `magit2-log-margin-show-committer-date'
  controls which date is being displayed.
WIDTH controls the width of the margin.  This exists for forward
  compatibility and currently the value should not be changed.
AUTHOR controls whether the name of the author is also shown by
  default.
AUTHOR-WIDTH has to be an integer.  When the name of the author
  is shown, then this specifies how much space is used to do so."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-log
  :group 'magit2-margin
  :type magit2-log-margin--custom-type
  :initialize 'magit2-custom-initialize-reset
  :set-after '(magit2-log-margin)
  :set (apply-partially #'magit2-margin-set-variable 'magit2-log-select-mode))

;;;; Cherry Mode

(defcustom magit2-cherry-sections-hook
  '(magit2-insert-cherry-headers
    magit2-insert-cherry-commits)
  "Hook run to insert sections into the cherry buffer."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-log
  :type 'hook)

(defcustom magit2-cherry-margin
  (list (nth 0 magit2-log-margin)
        (nth 1 magit2-log-margin)
        'magit2-log-margin-width t
        (nth 4 magit2-log-margin))
  "Format of the margin in `magit2-cherry-mode' buffers.

The value has the form (INIT STYLE WIDTH AUTHOR AUTHOR-WIDTH).

If INIT is non-nil, then the margin is shown initially.
STYLE controls how to format the author or committer date.
  It can be one of `age' (to show the age of the commit),
  `age-abbreviated' (to abbreviate the time unit to a character),
  or a string (suitable for `format-time-string') to show the
  actual date.  Option `magit2-log-margin-show-committer-date'
  controls which date is being displayed.
WIDTH controls the width of the margin.  This exists for forward
  compatibility and currently the value should not be changed.
AUTHOR controls whether the name of the author is also shown by
  default.
AUTHOR-WIDTH has to be an integer.  When the name of the author
  is shown, then this specifies how much space is used to do so."
  :package-version '(magit2 . "2.9.0")
  :group 'magit2-log
  :group 'magit2-margin
  :type magit2-log-margin--custom-type
  :initialize 'magit2-custom-initialize-reset
  :set-after '(magit2-log-margin)
  :set (apply-partially #'magit2-margin-set-variable 'magit2-cherry-mode))

;;;; Log Sections

(defcustom magit2-log-section-commit-count 10
  "How many recent commits to show in certain log sections.
How many recent commits `magit2-insert-recent-commits' and
`magit2-insert-unpulled-from-upstream-or-recent' (provided
the upstream isn't ahead of the current branch) show."
  :package-version '(magit2 . "2.1.0")
  :group 'magit2-status
  :type 'number)

;;; Arguments
;;;; Prefix Classes

(defclass magit2-log-prefix (transient-prefix)
  ((history-key :initform 'magit2-log)
   (major-mode  :initform 'magit2-log-mode)))

(defclass magit2-log-refresh-prefix (magit2-log-prefix)
  ((history-key :initform 'magit2-log)
   (major-mode  :initform nil)))

;;;; Prefix Methods

(cl-defmethod transient-init-value ((obj magit2-log-prefix))
  (pcase-let ((`(,args ,files)
               (magit2-log--get-value 'magit2-log-mode
                                     magit2-prefix-use-buffer-arguments)))
    (unless (eq transient-current-command 'magit2-dispatch)
      (when-let ((file (magit2-file-relative-name)))
        (setq files (list file))))
    (oset obj value (if files `(("--" ,@files) ,args) args))))

(cl-defmethod transient-init-value ((obj magit2-log-refresh-prefix))
  (oset obj value (if magit2-buffer-log-files
                      `(("--" ,@magit2-buffer-log-files)
                        ,magit2-buffer-log-args)
                    magit2-buffer-log-args)))

(cl-defmethod transient-set-value ((obj magit2-log-prefix))
  (magit2-log--set-value obj))

(cl-defmethod transient-save-value ((obj magit2-log-prefix))
  (magit2-log--set-value obj 'save))

;;;; Argument Access

(defun magit2-log-arguments (&optional mode)
  "Return the current log arguments."
  (if (memq transient-current-command '(magit2-log magit2-log-refresh))
      (pcase-let ((`(,args ,alist)
                   (-separate #'atom (transient-get-value))))
        (list args (cdr (assoc "--" alist))))
    (magit2-log--get-value (or mode 'magit2-log-mode))))

(defun magit2-log--get-value (mode &optional use-buffer-args)
  (unless use-buffer-args
    (setq use-buffer-args magit2-direct-use-buffer-arguments))
  (let (args files)
    (cond
     ((and (memq use-buffer-args '(always selected current))
           (eq major-mode mode))
      (setq args  magit2-buffer-log-args)
      (setq files magit2-buffer-log-files))
     ((and (memq use-buffer-args '(always selected))
           (when-let ((buffer (magit2-get-mode-buffer
                               mode nil
                               (eq use-buffer-args 'selected))))
             (setq args  (buffer-local-value 'magit2-buffer-log-args buffer))
             (setq files (buffer-local-value 'magit2-buffer-log-files buffer))
             t)))
     ((plist-member (symbol-plist mode) 'magit2-log-current-arguments)
      (setq args (get mode 'magit2-log-current-arguments)))
     ((when-let ((elt (assq (intern (format "magit2-log:%s" mode))
                            transient-values)))
        (setq args (cdr elt))
        t))
     (t
      (setq args (get mode 'magit2-log-default-arguments))))
    (list args files)))

(defun magit2-log--set-value (obj &optional save)
  (pcase-let* ((obj  (oref obj prototype))
               (mode (or (oref obj major-mode) major-mode))
               (key  (intern (format "magit2-log:%s" mode)))
               (`(,args ,alist)
                (-separate #'atom (transient-get-value)))
               (files (cdr (assoc "--" alist))))
    (put mode 'magit2-log-current-arguments args)
    (when save
      (setf (alist-get key transient-values) args)
      (transient-save-values))
    (transient--history-push obj)
    (setq magit2-buffer-log-args args)
    (unless (derived-mode-p 'magit2-log-select-mode)
      (setq magit2-buffer-log-files files))
    (magit2-refresh)))

;;; Commands
;;;; Prefix Commands

;;;###autoload (autoload 'magit2-log "magit2-log" nil t)
(transient-define-prefix magit2-log ()
  "Show a commit or reference log."
  :man-page "git-log"
  :class 'magit2-log-prefix
  ;; The grouping in git-log(1) appears to be guided by implementation
  ;; details, so our logical grouping only follows it to an extend.
  ;; Arguments that are "misplaced" here:
  ;;   1. From "Commit Formatting".
  ;;   2. From "Common Diff Options".
  ;;   3. From unnamed first group.
  ;;   4. Implemented by Magit.
  ["Commit limiting"
   (magit2-log:-n)
   (magit2:--author)
   (7 magit2-log:--since)
   (7 magit2-log:--until)
   (magit2-log:--grep)
   (7 "-i" "Search case-insensitive" ("-i" "--regexp-ignore-case"))
   (7 "-I" "Invert search pattern"   "--invert-grep")
   (magit2-log:-G)     ;2
   (magit2-log:-S)     ;2
   (magit2-log:-L)     ;2
   (7 "=m" "Omit merges"            "--no-merges")
   (7 "=p" "First parent"           "--first-parent")]
  ["History simplification"
   (  "-D" "Simplify by decoration"                  "--simplify-by-decoration")
   (magit2:--)
   (  "-f" "Follow renames when showing single-file log"     "--follow") ;3
   (6 "/s" "Only commits changing given paths"               "--sparse")
   (7 "/d" "Only selected commits plus meaningful history"   "--dense")
   (7 "/a" "Only commits existing directly on ancestry path" "--ancestry-path")
   (6 "/f" "Do not prune history"                            "--full-history")
   (7 "/m" "Prune some history"                              "--simplify-merges")]
  ["Commit ordering"
   (magit2-log:--*-order)
   ("-r" "Reverse order" "--reverse")]
  ["Formatting"
   ("-g" "Show graph"          "--graph")          ;1
   ("-c" "Show graph in color" "--color")          ;2
   ("-d" "Show refnames"       "--decorate")       ;3
   ("=S" "Show signatures"     "--show-signature") ;1
   ("-h" "Show header"         "++header")         ;4
   ("-p" "Show diffs"          ("-p" "--patch"))   ;2
   ("-s" "Show diffstats"      "--stat")]          ;2
  [["Log"
    ("l" "current"             magit2-log-current)
    ("h" "HEAD"                magit2-log-head)
    ("u" "related"             magit2-log-related)
    ("o" "other"               magit2-log-other)]
   [""
    ("L" "local branches"      magit2-log-branches)
    ("b" "all branches"        magit2-log-all-branches)
    ("a" "all references"      magit2-log-all)
    (7 "B" "matching branches" magit2-log-matching-branches)
    (7 "T" "matching tags"     magit2-log-matching-tags)
    (7 "m" "merged"            magit2-log-merged)]
   ["Reflog"
    ("r" "current"             magit2-reflog-current)
    ("H" "HEAD"                magit2-reflog-head)
    ("O" "other"               magit2-reflog-other)]
   [:if (lambda ()
          (require 'magit2-wip)
          (magit2--any-wip-mode-enabled-p))
    :description "Wiplog"
    ("i" "index"          magit2-wip-log-index)
    ("w" "worktree"       magit2-wip-log-worktree)]
   ["Other"
    (5 "s" "shortlog"    magit2-shortlog)]])

;;;###autoload (autoload 'magit2-log-refresh "magit2-log" nil t)
(transient-define-prefix magit2-log-refresh ()
  "Change the arguments used for the log(s) in the current buffer."
  :man-page "git-log"
  :class 'magit2-log-refresh-prefix
  [:if-mode magit2-log-mode
   :class transient-subgroups
   ["Commit limiting"
    (magit2-log:-n)
    (magit2:--author)
    (magit2-log:--grep)
    (7 "-i" "Search case-insensitive" ("-i" "--regexp-ignore-case"))
    (7 "-I" "Invert search pattern"   "--invert-grep")
    (magit2-log:-G)
    (magit2-log:-S)
    (magit2-log:-L)]
   ["History simplification"
    (  "-D" "Simplify by decoration"                  "--simplify-by-decoration")
    (magit2:--)
    (  "-f" "Follow renames when showing single-file log"     "--follow") ;3
    (6 "/s" "Only commits changing given paths"               "--sparse")
    (7 "/d" "Only selected commits plus meaningful history"   "--dense")
    (7 "/a" "Only commits existing directly on ancestry path" "--ancestry-path")
    (6 "/f" "Do not prune history"                            "--full-history")
    (7 "/m" "Prune some history"                              "--simplify-merges")]
   ["Commit ordering"
    (magit2-log:--*-order)
    ("-r" "Reverse order" "--reverse")]
   ["Formatting"
    ("-g" "Show graph"              "--graph")
    ("-c" "Show graph in color"     "--color")
    ("-d" "Show refnames"           "--decorate")
    ("=S" "Show signatures"         "--show-signature")
    ("-h" "Show header"             "++header")
    ("-p" "Show diffs"              ("-p" "--patch"))
    ("-s" "Show diffstats"          "--stat")]]
  [:if-not-mode magit2-log-mode
   :description "Arguments"
   (magit2-log:-n)
   (magit2-log:--*-order)
   ("-g" "Show graph"               "--graph")
   ("-c" "Show graph in color"      "--color")
   ("-d" "Show refnames"            "--decorate")]
  [["Refresh"
    ("g" "buffer"                   magit2-log-refresh)
    ("s" "buffer and set defaults"  transient-set  :transient nil)
    ("w" "buffer and save defaults" transient-save :transient nil)]
   ["Margin"
    ("L" "toggle visibility"        magit2-toggle-margin)
    ("l" "cycle style"              magit2-cycle-margin-style)
    ("d" "toggle details"           magit2-toggle-margin-details)
    ("x" "toggle shortstat"         magit2-toggle-log-margin-style)]
   [:if-mode magit2-log-mode
    :description "Toggle"
    ("b" "buffer lock"              magit2-toggle-buffer-lock)]]
  (interactive)
  (cond
   ((not (eq transient-current-command 'magit2-log-refresh))
    (pcase major-mode
      (`magit2-reflog-mode
       (user-error "Cannot change log arguments in reflog buffers"))
      (`magit2-cherry-mode
       (user-error "Cannot change log arguments in cherry buffers")))
    (transient-setup 'magit2-log-refresh))
   (t
    (pcase-let ((`(,args ,files) (magit2-log-arguments)))
      (setq magit2-buffer-log-args args)
      (unless (derived-mode-p 'magit2-log-select-mode)
        (setq magit2-buffer-log-files files)))
    (magit2-refresh))))

;;;; Infix Commands

(transient-define-argument magit2-log:-n ()
  :description "Limit number of commits"
  :class 'transient-option
  ;; For historic reasons (and because it easy to guess what "-n"
  ;; stands for) this is the only argument where we do not use the
  ;; long argument ("--max-count").
  :shortarg "-n"
  :argument "-n"
  :reader 'transient-read-number-N+)

(transient-define-argument magit2:--author ()
  :description "Limit to author"
  :class 'transient-option
  :key "-A"
  :argument "--author="
  :reader 'magit2-transient-read-person)

(transient-define-argument magit2-log:--since ()
  :description "Limit to commits since"
  :class 'transient-option
  :key "=s"
  :argument "--since="
  :reader 'transient-read-date)

(transient-define-argument magit2-log:--until ()
  :description "Limit to commits until"
  :class 'transient-option
  :key "=u"
  :argument "--until="
  :reader 'transient-read-date)

(transient-define-argument magit2-log:--*-order ()
  :description "Order commits by"
  :class 'transient-switches
  :key "-o"
  :argument-format "--%s-order"
  :argument-regexp "\\(--\\(topo\\|author-date\\|date\\)-order\\)"
  :choices '("topo" "author-date" "date"))

(transient-define-argument magit2-log:--grep ()
  :description "Search messages"
  :class 'transient-option
  :key "-F"
  :argument "--grep=")

(transient-define-argument magit2-log:-G ()
  :description "Search changes"
  :class 'transient-option
  :argument "-G")

(transient-define-argument magit2-log:-S ()
  :description "Search occurrences"
  :class 'transient-option
  :argument "-S")

(transient-define-argument magit2-log:-L ()
  :description "Trace line evolution"
  :class 'transient-option
  :argument "-L"
  :reader 'magit2-read-file-trace)

(defun magit2-read-file-trace (&rest _ignored)
  (let ((file  (magit2-read-file-from-rev "HEAD" "File"))
        (trace (magit2-read-string "Trace")))
    (concat trace ":" file)))

;;;; Setup Commands

(defvar magit2-log-read-revs-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map crm-local-completion-map)
    (define-key map "\s" 'self-insert-command)
    map))

(defun magit2-log-read-revs (&optional use-current)
  (or (and use-current (--when-let (magit2-get-current-branch) (list it)))
      (let ((crm-separator "\\(\\.\\.\\.?\\|[, ]\\)")
            (crm-local-completion-map magit2-log-read-revs-map))
        (split-string (magit2-completing-read-multiple*
                       "Log rev,s: "
                       (magit2-list-refnames nil t)
                       nil nil nil 'magit2-revision-history
                       (or (magit2-branch-or-commit-at-point)
                           (unless use-current
                             (magit2-get-previous-branch)))
                       nil t)
                      "[, ]" t))))

(defun magit2-log-read-pattern (option)
  "Read a string from the user to pass as parameter to OPTION."
  (magit2-read-string (format "Type a pattern to pass to %s" option)))

;;;###autoload
(defun magit2-log-current (revs &optional args files)
  "Show log for the current branch.
When `HEAD' is detached or with a prefix argument show log for
one or more revs read from the minibuffer."
  (interactive (cons (magit2-log-read-revs t)
                     (magit2-log-arguments)))
  (magit2-log-setup-buffer revs args files))

;;;###autoload
(defun magit2-log-head (&optional args files)
  "Show log for `HEAD'."
  (interactive (magit2-log-arguments))
  (magit2-log-setup-buffer (list "HEAD") args files))

;;;###autoload
(defun magit2-log-related (revs &optional args files)
  "Show log for the current branch, its upstream and its push target.
When the upstream is a local branch, then also show its own
upstream.  When `HEAD' is detached, then show log for that, the
previously checked out branch and its upstream and push-target."
  (interactive
   (cons (let ((current (magit2-get-current-branch))
               head rebase target upstream upup)
           (unless current
             (setq rebase (magit2-rebase--get-state-lines "head-name"))
             (cond (rebase
                    (setq rebase (magit2-ref-abbrev rebase))
                    (setq current rebase)
                    (setq head "HEAD"))
                   (t (setq current (magit2-get-previous-branch)))))
           (cond (current
                  (setq current
                        (magit2--propertize-face current'magit2-branch-local))
                  (setq target (magit2-get-push-branch current t))
                  (setq upstream (magit2-get-upstream-branch current))
                  (when upstream
                    (setq upup (and (magit2-local-branch-p upstream)
                                    (magit2-get-upstream-branch upstream)))))
                 (t (setq head "HEAD")))
           (delq nil (list current head target upstream upup)))
         (magit2-log-arguments)))
  (magit2-log-setup-buffer revs args files))

;;;###autoload
(defun magit2-log-other (revs &optional args files)
  "Show log for one or more revs read from the minibuffer.
The user can input any revision or revisions separated by a
space, or even ranges, but only branches and tags, and a
representation of the commit at point, are available as
completion candidates."
  (interactive (cons (magit2-log-read-revs)
                     (magit2-log-arguments)))
  (magit2-log-setup-buffer revs args files))

;;;###autoload
(defun magit2-log-branches (&optional args files)
  "Show log for all local branches and `HEAD'."
  (interactive (magit2-log-arguments))
  (magit2-log-setup-buffer (if (magit2-get-current-branch)
                              (list "--branches")
                            (list "HEAD" "--branches"))
                          args files))

;;;###autoload
(defun magit2-log-matching-branches (pattern &optional args files)
  "Show log for all branches matching PATTERN and `HEAD'."
  (interactive (cons (magit2-log-read-pattern "--branches") (magit2-log-arguments)))
  (magit2-log-setup-buffer
   (list "HEAD" (format "--branches=%s" pattern))
   args files))

;;;###autoload
(defun magit2-log-matching-tags (pattern &optional args files)
  "Show log for all tags matching PATTERN and `HEAD'."
  (interactive (cons (magit2-log-read-pattern "--tags") (magit2-log-arguments)))
  (magit2-log-setup-buffer
   (list "HEAD" (format "--tags=%s" pattern))
   args files))

;;;###autoload
(defun magit2-log-all-branches (&optional args files)
  "Show log for all local and remote branches and `HEAD'."
  (interactive (magit2-log-arguments))
  (magit2-log-setup-buffer (if (magit2-get-current-branch)
                              (list "--branches" "--remotes")
                            (list "HEAD" "--branches" "--remotes"))
                          args files))

;;;###autoload
(defun magit2-log-all (&optional args files)
  "Show log for all references and `HEAD'."
  (interactive (magit2-log-arguments))
  (magit2-log-setup-buffer (if (magit2-get-current-branch)
                              (list "--all")
                            (list "HEAD" "--all"))
                          args files))

;;;###autoload
(defun magit2-log-buffer-file (&optional follow beg end)
  "Show log for the blob or file visited in the current buffer.
With a prefix argument or when `--follow' is an active log
argument, then follow renames.  When the region is active,
restrict the log to the lines that the region touches."
  (interactive
   (cons current-prefix-arg
         (and (region-active-p)
              (magit2-file-relative-name)
              (save-restriction
                (widen)
                (list (line-number-at-pos (region-beginning))
                      (line-number-at-pos
                       (let ((end (region-end)))
                         (if (char-after end)
                             end
                           ;; Ensure that we don't get the line number
                           ;; of a trailing newline.
                           (1- end)))))))))
  (require 'magit2)
  (if-let ((file (magit2-file-relative-name)))
      (magit2-log-setup-buffer
       (list (or magit2-buffer-refname
                 (magit2-get-current-branch)
                 "HEAD"))
       (let ((args (car (magit2-log-arguments))))
         (when (and follow (not (member "--follow" args)))
           (push "--follow" args))
         (when (and (file-regular-p
                     (expand-file-name file (magit2-toplevel)))
                    beg end)
           (setq args (cons (format "-L%s,%s:%s" beg end file)
                            (cl-delete "-L" args :test
                                       'string-prefix-p)))
           (setq file nil))
         args)
       (and file (list file))
       magit2-log-buffer-file-locked)
    (user-error "Buffer isn't visiting a file")))

;;;###autoload
(defun magit2-log-trace-definition (file fn rev)
  "Show log for the definition at point."
  (interactive (list (or (magit2-file-relative-name)
                         (user-error "Buffer isn't visiting a file"))
                     (or (funcall magit2-log-trace-definition-function)
                         (user-error "No function at point found"))
                     (or magit2-buffer-refname
                         (magit2-get-current-branch)
                         "HEAD")))
  (require 'magit2)
  (magit2-log-setup-buffer
   (list rev)
   (cons (format "-L:%s%s:%s"
                 (replace-regexp-in-string ":" "\\:" (regexp-quote fn) nil t)
                 (if (derived-mode-p 'lisp-mode 'emacs-lisp-mode)
                     ;; Git doesn't treat "-" the same way as
                     ;; "_", leading to false-positives such as
                     ;; "foo-suffix" being considered a match
                     ;; for "foo".  Wing it.
                     "\\( \\|$\\)"
                   ;; We could use "\\b" here, but since Git
                   ;; already does something equivalent, that
                   ;; isn't necessary.
                   "")
                 file)
         (cl-delete "-L" (car (magit2-log-arguments))
                    :test 'string-prefix-p))
   nil magit2-log-buffer-file-locked))

(defun magit2-diff-trace-definition ()
  "Show log for the definition at point in a diff."
  (interactive)
  (pcase-let ((`(,buf ,pos) (magit2-diff-visit-file--noselect)))
    (magit2--with-temp-position buf pos
      (call-interactively #'magit2-log-trace-definition))))

;;;###autoload
(defun magit2-log-merged (commit branch &optional args files)
  "Show log for the merge of COMMIT into BRANCH.

More precisely, find merge commit M that brought COMMIT into
BRANCH, and show the log of the range \"M^1..M\".  If COMMIT is
directly on BRANCH, then show approximately twenty surrounding
commits instead.

This command requires git-when-merged, which is available from
https://github.com/mhagger/git-when-merged."
  (interactive
   (append (let ((commit (magit2-read-branch-or-commit "Log merge of commit")))
             (list commit
                   (magit2-read-other-branch "Merged into" commit)))
           (magit2-log-arguments)))
  (unless (executable-find "git-when-merged")
    (user-error "This command requires git-when-merged (%s)"
                "https://github.com/mhagger/git-when-merged"))
  (let (exit m)
    (with-temp-buffer
      (save-excursion
        (setq exit (magit2-process-git t "when-merged" "-c"
                                      (magit2-abbrev-arg)
                                      commit branch)))
      (setq m (buffer-substring-no-properties (point) (line-end-position))))
    (if (zerop exit)
        (magit2-log-setup-buffer (list (format "%s^1..%s" m m))
                                args files nil commit)
      (setq m (string-trim-left (substring m (string-match " " m))))
      (if (equal m "Commit is directly on this branch.")
          (let* ((from (concat commit "~10"))
                 (to (- (car (magit2-rev-diff-count branch commit)) 10))
                 (to (if (<= to 0)
                         branch
                       (format "%s~%s" branch to))))
            (unless (magit2-rev-parse from)
              (setq from (magit2-git-string "rev-list" "--max-parents=0"
                                           commit)))
            (magit2-log-setup-buffer (list (concat from ".." to))
                                    (cons "--first-parent" args)
                                    files nil commit))
        (user-error "Could not find when %s was merged into %s: %s"
                    commit branch m)))))

;;;; Limit Commands

(defun magit2-log-toggle-commit-limit ()
  "Toggle the number of commits the current log buffer is limited to.
If the number of commits is currently limited, then remove that
limit.  Otherwise set it to 256."
  (interactive)
  (magit2-log-set-commit-limit (lambda (&rest _) nil)))

(defun magit2-log-double-commit-limit ()
  "Double the number of commits the current log buffer is limited to."
  (interactive)
  (magit2-log-set-commit-limit '*))

(defun magit2-log-half-commit-limit ()
  "Half the number of commits the current log buffer is limited to."
  (interactive)
  (magit2-log-set-commit-limit '/))

(defun magit2-log-set-commit-limit (fn)
  (let* ((val magit2-buffer-log-args)
         (arg (--first (string-match "^-n\\([0-9]+\\)?$" it) val))
         (num (and arg (string-to-number (match-string 1 arg))))
         (num (if num (funcall fn num 2) 256)))
    (setq val (delete arg val))
    (setq magit2-buffer-log-args
          (if (and num (> num 0))
              (cons (format "-n%i" num) val)
            val)))
  (magit2-refresh))

(defun magit2-log-get-commit-limit ()
  (--when-let (--first (string-match "^-n\\([0-9]+\\)?$" it)
                       magit2-buffer-log-args)
    (string-to-number (match-string 1 it))))

;;;; Mode Commands

(defun magit2-log-bury-buffer (&optional arg)
  "Bury the current buffer or the revision buffer in the same frame.
Like `magit2-mode-bury-buffer' (which see) but with a negative
prefix argument instead bury the revision buffer, provided it
is displayed in the current frame."
  (interactive "p")
  (if (< arg 0)
      (let* ((buf (magit2-get-mode-buffer 'magit2-revision-mode))
             (win (and buf (get-buffer-window buf (selected-frame)))))
        (if win
            (with-selected-window win
              (with-current-buffer buf
                (magit2-mode-bury-buffer (> (abs arg) 1))))
          (user-error "No revision buffer in this frame")))
    (magit2-mode-bury-buffer (> arg 1))))

;;;###autoload
(defun magit2-log-move-to-parent (&optional n)
  "Move to the Nth parent of the current commit."
  (interactive "p")
  (when (derived-mode-p 'magit2-log-mode)
    (when (magit2-section-match 'commit)
      (let* ((section (magit2-current-section))
             (parent-rev (format "%s^%s" (oref section value) (or n 1))))
        (if-let ((parent-hash (magit2-rev-parse "--short" parent-rev)))
            (if-let ((parent (--first (equal (oref it value)
                                             parent-hash)
                                      (magit2-section-siblings section 'next))))
                (magit2-section-goto parent)
              (user-error
               (substitute-command-keys
                (concat "Parent " parent-hash " not found.  Try typing "
                        "\\[magit2-log-double-commit-limit] first"))))
          (user-error "Parent %s does not exist" parent-rev))))))

(defun magit2-log-move-to-revision (rev)
  "Read a revision and move to it in current log buffer.

If the chosen reference or revision isn't being displayed in
the current log buffer, then inform the user about that and do
nothing else.

If invoked outside any log buffer, then display the log buffer
of the current repository first; creating it if necessary."
  (interactive (list (magit2-read-branch-or-commit "In log, jump to")))
  (with-current-buffer
      (cond ((derived-mode-p 'magit2-log-mode)
             (current-buffer))
            ((when-let ((buf (magit2-get-mode-buffer 'magit2-log-mode)))
               (pop-to-buffer-same-window buf)))
            (t
             (apply #'magit2-log-all-branches (magit2-log-arguments))))
    (unless (magit2-log-goto-commit-section (magit2-rev-abbrev rev))
      (user-error "%s isn't visible in the current log buffer" rev))))

;;;; Shortlog Commands

;;;###autoload (autoload 'magit2-shortlog "magit2-log" nil t)
(transient-define-prefix magit2-shortlog ()
  "Show a history summary."
  :man-page "git-shortlog"
  :value '("--numbered" "--summary")
  ["Arguments"
   ("-n" "Sort by number of commits"      ("-n" "--numbered"))
   ("-s" "Show commit count summary only" ("-s" "--summary"))
   ("-e" "Show email addresses"           ("-e" "--email"))
   ("-g" "Group commits by" "--group="
    :choices ("author" "committer" "trailer:"))
   (7 "-f" "Format string" "--format=")
   (7 "-w" "Linewrap" "-w" :class transient-option)]
  ["Shortlog"
   ("s" "since" magit2-shortlog-since)
   ("r" "range" magit2-shortlog-range)])

(defun magit2-git-shortlog (rev args)
  (let ((dir default-directory))
    (with-current-buffer (get-buffer-create "*magit2-shortlog*")
      (setq default-directory dir)
      (setq buffer-read-only t)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (save-excursion
          (magit2-git-insert "shortlog" args rev))
        (switch-to-buffer-other-window (current-buffer))))))

;;;###autoload
(defun magit2-shortlog-since (rev args)
  "Show a history summary for commits since REV."
  (interactive
   (list (magit2-read-branch-or-commit "Shortlog since" (magit2-get-current-tag))
         (transient-args 'magit2-shortlog)))
  (magit2-git-shortlog (concat rev "..") args))

;;;###autoload
(defun magit2-shortlog-range (rev-or-range args)
  "Show a history summary for commit or range REV-OR-RANGE."
  (interactive
   (list (magit2-read-range-or-commit "Shortlog for revision or range")
         (transient-args 'magit2-shortlog)))
  (magit2-git-shortlog rev-or-range args))

;;; Log Mode

(defvar magit2-log-disable-graph-hack-args
  '("-G" "--grep" "--author")
  "Arguments which disable the graph speedup hack.")

(defvar magit2-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-mode-map)
    (define-key map (kbd "C-c C-b") 'magit2-go-backward)
    (define-key map (kbd "C-c C-f") 'magit2-go-forward)
    (define-key map (kbd "C-c C-n") 'magit2-log-move-to-parent)
    (define-key map "j" 'magit2-log-move-to-revision)
    (define-key map "=" 'magit2-log-toggle-commit-limit)
    (define-key map "+" 'magit2-log-double-commit-limit)
    (define-key map "-" 'magit2-log-half-commit-limit)
    (define-key map "q" 'magit2-log-bury-buffer)
    map)
  "Keymap for `magit2-log-mode'.")

(define-derived-mode magit2-log-mode magit2-mode "Magit Log"
  "Mode for looking at Git log.

This mode is documented in info node `(magit2)Log Buffer'.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-visit-thing] or \\[magit2-diff-show-or-scroll-up] \
to visit the commit at point.

Type \\[magit2-branch] to see available branch commands.
Type \\[magit2-merge] to merge the branch or commit at point.
Type \\[magit2-cherry-pick] to apply the commit at point.
Type \\[magit2-reset] to reset `HEAD' to the commit at point.

\\{magit2-log-mode-map}"
  :group 'magit2-log
  (hack-dir-local-variables-non-file-buffer)
  (setq magit2--imenu-item-types 'commit))

(put 'magit2-log-mode 'magit2-log-default-arguments
     '("--graph" "-n256" "--decorate"))

(defun magit2-log-setup-buffer (revs args files &optional locked focus)
  (require 'magit2)
  (with-current-buffer
      (magit2-setup-buffer #'magit2-log-mode locked
        (magit2-buffer-revisions revs)
        (magit2-buffer-log-args args)
        (magit2-buffer-log-files files))
    (when (if focus
              (magit2-log-goto-commit-section focus)
            (magit2-log-goto-same-commit))
      (magit2-section-update-highlight))
    (current-buffer)))

(defun magit2-log-refresh-buffer ()
  (let ((revs  magit2-buffer-revisions)
        (args  magit2-buffer-log-args)
        (files magit2-buffer-log-files))
    (magit2-set-header-line-format
     (funcall magit2-log-header-line-function revs args files))
    (unless (= (length files) 1)
      (setq args (remove "--follow" args)))
    (when (and (car magit2-log-remove-graph-args)
               (--any-p (string-match-p
                         (concat "^" (regexp-opt magit2-log-remove-graph-args)) it)
                        args))
      (setq args (remove "--graph" args)))
    (unless (member "--graph" args)
      (setq args (remove "--color" args)))
    (when-let ((limit (magit2-log-get-commit-limit))
               (limit (* 2 limit)) ; increase odds for complete graph
               (count (and (= (length revs) 1)
                           (> limit 1024) ; otherwise it's fast enough
                           (setq revs (car revs))
                           (not (string-match-p "\\.\\." revs))
                           (not (member revs '("--all" "--branches")))
                           (-none-p (lambda (arg)
                                      (--any-p (string-prefix-p it arg)
                                               magit2-log-disable-graph-hack-args))
                                    args)
                           (magit2-git-string "rev-list" "--count"
                                             "--first-parent" args revs))))
      (setq revs (if (< (string-to-number count) limit)
                     revs
                   (format "%s~%s..%s" revs limit revs))))
    (magit2-insert-section (logbuf)
      (magit2-insert-log revs args files))))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-log-mode))
  (append magit2-buffer-revisions
          (if (and magit2-buffer-revisions magit2-buffer-log-files)
              (cons "--" magit2-buffer-log-files)
            magit2-buffer-log-files)))

(defun magit2-log-header-line-arguments (revs args files)
  "Return string describing some of the used arguments."
  (mapconcat (lambda (arg)
               (if (string-match-p " " arg)
                   (prin1 arg)
                 arg))
             `("git" "log" ,@args ,@revs "--" ,@files)
             " "))

(defun magit2-log-header-line-sentence (revs args files)
  "Return string containing all arguments."
  (concat "Commits in "
          (mapconcat #'identity revs " ")
          (and (member "--reverse" args)
               " in reverse")
          (and files (concat " touching "
                             (mapconcat 'identity files " ")))
          (--some (and (string-prefix-p "-L" it)
                       (concat " " it))
                  args)))

(defun magit2-insert-log (revs &optional args files)
  "Insert a log section.
Do not add this to a hook variable."
  (let ((magit2-git-global-arguments
         (remove "--literal-pathspecs" magit2-git-global-arguments))
        (method
         (lambda ()
           (when revs
             (let* ((repo (libgit2-repository-open default-directory))
                    (walk (libgit2-revwalk-new repo))
                    (refs-alist
                     (let (result)
                       (libgit2-reference-foreach
                        repo
                        (lambda (ref)
                          (when-let ((short (libgit2-reference-shorthand ref))
                                     (branch-p (libgit2-reference-branch-p ref))
                                     (commit-id (magit2-rev-parse :repo repo
                                                                  short)))
                            (push short
                                  (alist-get commit-id
                                             result nil nil #'equal)))))
                       result)))
               (if (consp revs)
                   (libgit2-revwalk-push
                    walk
                    (libgit2-object-id (libgit2-revparse-single repo (car revs))))
                 (libgit2-revwalk-push-range walk revs))
               (libgit2-revwalk-foreach
                walk
                (lambda (id)
                  (let ((commit (libgit2-commit-lookup repo id)))
                    (insert (libgit2-object-short-id commit)
                            #x0c
                            (mapconcat
                             #'identity
                             (alist-get id refs-alist nil nil #'equal)
                             ", ")
                            #x0c
                            #x0c
                            (libgit2-signature-name (libgit2-commit-author commit))
                            #x0c
                            (number-to-string
                             (truncate
                              (float-time
                               (encode-time (libgit2-commit-time commit)))))
                            #x0c
                            (libgit2-commit-summary commit)
                            "\n")))))))))
    (magit2-git-wash (apply-partially #'magit2-log-wash-log 'log)
      :method method
      "log"
      (format "--format=%s%%h%%x0c%s%%x0c%s%%x0c%%aN%%x0c%s%%x0c%%s%s"
              (if (and (member "--left-right" args)
                       (not (member "--graph" args)))
                  "%m "
                "")
              (if (member "--decorate" args) "%D" "")
              (if (member "--show-signature" args)
                  (progn (setq args (remove "--show-signature" args)) "%G?")
                "")
              (if magit2-log-margin-show-committer-date "%ct" "%at")
              (if (member "++header" args)
                  (if (member "--graph" (setq args (remove "++header" args)))
                      (concat "\n" magit2-log-revision-headers-format "\n")
                    (concat "\n" magit2-log-revision-headers-format "\n"))
                ""))
      (progn
        (--when-let (--first (string-match "^\\+\\+order=\\(.+\\)$" it) args)
          (setq args (cons (format "--%s-order" (match-string 1 it))
                           (remove it args))))
        (when (member "--decorate" args)
          (setq args (cons "--decorate=full" (remove "--decorate" args))))
        (when (member "--reverse" args)
          (setq args (remove "--graph" args)))
        (setq args (magit2-diff--maybe-add-stat-arguments args))
        args)
      "--use-mailmap" "--no-prefix" revs "--" files)))

(defvar magit2-commit-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-show-commit)
    (define-key map "a" 'magit2-cherry-apply)
    map)
  "Keymap for `commit' sections.")

(defvar magit2-module-commit-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-show-commit)
    map)
  "Keymap for `module-commit' sections.")

(defconst magit2-log-heading-re
  ;; Note: A form feed instead of a null byte is used as the delimiter
  ;; because using the latter interferes with the graph prefix when
  ;; ++header is used.
  (concat "^"
          "\\(?4:[-_/|\\*o<>. ]*\\)"               ; graph
          "\\(?1:[0-9a-fA-F]+\\)?"               ; hash
          "\\(?3:[^\n]+\\)?"                   ; refs
          "\\(?7:[BGUXYREN]\\)?"                 ; gpg
          "\\(?5:[^\n]*\\)"                    ; author
          ;; Note: Date is optional because, prior to Git v2.19.0,
          ;; `git rebase -i --root` corrupts the root's author date.
          "\\(?6:[^\n]*\\)"                    ; date
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit2-log-cherry-re
  (concat "^"
          "\\(?8:[-+]\\) "                         ; cherry
          "\\(?1:[0-9a-fA-F]+\\) "                 ; hash
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit2-log-module-re
  (concat "^"
          "\\(?:\\(?11:[<>]\\) \\)?"               ; side
          "\\(?1:[0-9a-fA-F]+\\) "                 ; hash
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit2-log-bisect-vis-re
  (concat "^"
          "\\(?4:[-_/|\\*o<>. ]*\\)"               ; graph
          "\\(?1:[0-9a-fA-F]+\\)?\0"               ; hash
          "\\(?3:[^\0\n]+\\)?\0"                   ; refs
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit2-log-bisect-log-re
  (concat "^# "
          "\\(?3:[^: \n]+:\\) "                    ; "refs"
          "\\[\\(?1:[^]\n]+\\)\\] "                ; hash
          "\\(?2:.*\\)$"))                         ; msg

(defconst magit2-log-reflog-re
  (concat "^"
          "\\(?1:[^\0\n]+\\)\0"                    ; hash
          "\\(?5:[^\0\n]*\\)\0"                    ; author
          "\\(?:\\(?:[^@\n]+@{\\(?6:[^}\n]+\\)}\0" ; date
          "\\(?10:merge \\|autosave \\|restart \\|[^:\n]+: \\)?" ; refsub
          "\\(?2:.*\\)?\\)\\|\0\\)$"))             ; msg

(defconst magit2-reflog-subject-re
  (concat "\\(?1:[^ ]+\\) ?"                       ; command
          "\\(?2:\\(?: ?-[^ ]+\\)+\\)?"            ; option
          "\\(?: ?(\\(?3:[^)]+\\))\\)?"))          ; type

(defconst magit2-log-stash-re
  (concat "^"
          "\\(?1:[^\0\n]+\\)\0"                    ; "hash"
          "\\(?5:[^\0\n]*\\)\0"                    ; author
          "\\(?6:[^\0\n]+\\)\0"                    ; date
          "\\(?2:.*\\)$"))                         ; msg

(defvar magit2-log-count nil)

(defvar magit2-log-format-message-function 'magit2-log-propertize-keywords)

(defun magit2-log-wash-log (style args)
  (setq args (-flatten args))
  (when (and (member "--graph" args)
             (member "--color" args))
    (let ((ansi-color-apply-face-function
           (lambda (beg end face)
             (put-text-property beg end 'font-lock-face
                                (or face 'magit2-log-graph)))))
      (ansi-color-apply-on-region (point-min) (point-max))))
  (when (eq style 'cherry)
    (reverse-region (point-min) (point-max)))
  (let ((magit2-log-count 0))
    (when (looking-at "^\\.\\.\\.")
      (magit2-delete-line))
    (magit2-wash-sequence (apply-partially #'magit2-log-wash-rev style
                                          (magit2-abbrev-length)))
    (if (derived-mode-p 'magit2-log-mode 'magit2-reflog-mode)
        (when (eq magit2-log-count (magit2-log-get-commit-limit))
          (magit2-insert-section (longer)
            (insert-text-button
             (substitute-command-keys
              (format "Type \\<%s>\\[%s] to show more history"
                      'magit2-log-mode-map
                      'magit2-log-double-commit-limit))
             'action (lambda (_button)
                       (magit2-log-double-commit-limit))
             'follow-link t
             'mouse-face 'magit2-section-highlight)))
      (insert ?\n))))

(cl-defun magit2-log-wash-rev (style abbrev)
  (when (derived-mode-p 'magit2-log-mode 'magit2-reflog-mode)
    (cl-incf magit2-log-count))
  (looking-at (pcase style
                (`log        magit2-log-heading-re)
                (`cherry     magit2-log-cherry-re)
                (`module     magit2-log-module-re)
                (`reflog     magit2-log-reflog-re)
                (`stash      magit2-log-stash-re)
                (`bisect-vis magit2-log-bisect-vis-re)
                (`bisect-log magit2-log-bisect-log-re)))
  (magit2-bind-match-strings
      (hash msg refs graph author date gpg cherry _ refsub side) nil
    (setq msg (substring-no-properties msg))
    (when refs
      (setq refs (substring-no-properties refs)))
    (let ((align (or (eq style 'cherry)
                     (not (member "--stat" magit2-buffer-log-args))))
          (non-graph-re (if (eq style 'bisect-vis)
                            magit2-log-bisect-vis-re
                          magit2-log-heading-re)))
      (magit2-delete-line)
      ;; If the reflog entries have been pruned, the output of `git
      ;; reflog show' includes a partial line that refers to the hash
      ;; of the youngest expired reflog entry.
      (when (and (eq style 'reflog) (not date))
        (cl-return-from magit2-log-wash-rev t))
      (magit2-insert-section section (commit hash)
        (pcase style
          (`stash      (oset section type 'stash))
          (`module     (oset section type 'module-commit))
          (`bisect-log (setq hash (magit2-rev-parse "--short" hash))))
        (setq hash (propertize hash 'font-lock-face
                               (pcase (and gpg (aref gpg 0))
                                 (?G 'magit2-signature-good)
                                 (?B 'magit2-signature-bad)
                                 (?U 'magit2-signature-untrusted)
                                 (?X 'magit2-signature-expired)
                                 (?Y 'magit2-signature-expired-key)
                                 (?R 'magit2-signature-revoked)
                                 (?E 'magit2-signature-error)
                                 (?N 'magit2-hash)
                                 (_  'magit2-hash))))
        (when cherry
          (when (and (derived-mode-p 'magit2-refs-mode)
                     magit2-refs-show-commit-count)
            (insert (make-string (1- magit2-refs-focus-column-width) ?\s)))
          (insert (propertize cherry 'font-lock-face
                              (if (string= cherry "-")
                                  'magit2-cherry-equivalent
                                'magit2-cherry-unmatched)))
          (insert ?\s))
        (when side
          (insert (propertize side 'font-lock-face
                              (if (string= side "<")
                                  'magit2-cherry-equivalent
                                'magit2-cherry-unmatched)))
          (insert ?\s))
        (when align
          (insert hash ?\s))
        (when graph
          (insert graph))
        (unless align
          (insert hash ?\s))
        (when (and refs (not magit2-log-show-refname-after-summary))
          (insert (magit2-format-ref-labels refs) ?\s))
        (when (eq style 'reflog)
          (insert (format "%-2s " (1- magit2-log-count)))
          (when refsub
            (insert (magit2-reflog-format-subject
                     (substring refsub 0 (if (string-match-p ":" refsub) -2 -1))))))
        (when msg
          (insert (funcall magit2-log-format-message-function hash msg)))
        (when (and refs magit2-log-show-refname-after-summary)
          (insert ?\s)
          (insert (magit2-format-ref-labels refs)))
        (insert ?\n)
        (when (memq style '(log reflog stash))
          (goto-char (line-beginning-position))
          (when (and refsub
                     (string-match "\\`\\([^ ]\\) \\+\\(..\\)\\(..\\)" date))
            (setq date (+ (string-to-number (match-string 1 date))
                          (* (string-to-number (match-string 2 date)) 60 60)
                          (* (string-to-number (match-string 3 date)) 60))))
          (save-excursion
            (backward-char)
            (magit2-log-format-margin hash author date)))
        (when (and (eq style 'cherry)
                   (magit2-buffer-margin-p))
          (save-excursion
            (backward-char)
            (apply #'magit2-log-format-margin hash
                   (split-string (magit2-rev-format "%aN%x00%ct" hash) "\0"))))
        (when (and graph
                   (not (eobp))
                   (not (looking-at non-graph-re)))
          (when (looking-at "")
            (magit2-insert-heading)
            (delete-char 1)
            (magit2-insert-section (commit-header)
              (forward-line)
              (magit2-insert-heading)
              (re-search-forward "")
              (backward-delete-char 1)
              (forward-char)
              (insert ?\n))
            (delete-char 1))
          (if (looking-at "^\\(---\\|\n\s\\|\ndiff\\)")
              (let ((limit (save-excursion
                             (and (re-search-forward non-graph-re nil t)
                                  (match-beginning 0)))))
                (unless (oref magit2-insert-section--current content)
                  (magit2-insert-heading))
                (delete-char (if (looking-at "\n") 1 4))
                (magit2-diff-wash-diffs (list "--stat") limit))
            (when align
              (setq align (make-string (1+ abbrev) ? )))
            (when (and (not (eobp)) (not (looking-at non-graph-re)))
              (when align
                (setq align (make-string (1+ abbrev) ? )))
              (while (and (not (eobp)) (not (looking-at non-graph-re)))
                (when align
                  (save-excursion (insert align)))
                (magit2-make-margin-overlay)
                (forward-line))
              ;; When `--format' is used and its value isn't one of the
              ;; predefined formats, then `git-log' does not insert a
              ;; separator line.
              (save-excursion
                (forward-line -1)
                (looking-at "[-_/|\\*o<>. ]*"))
              (setq graph (match-string 0))
              (unless (string-match-p "[/\\.]" graph)
                (insert graph ?\n))))))))
  t)

(defun magit2-log-propertize-keywords (_rev msg)
  (let ((boundary 0))
    (when (string-match "^\\(?:squash\\|fixup\\)! " msg boundary)
      (setq boundary (match-end 0))
      (magit2--put-face (match-beginning 0) (1- boundary)
                       'magit2-keyword-squash msg))
    (when magit2-log-highlight-keywords
      (while (string-match "\\[[^[]*?]" msg boundary)
        (setq boundary (match-end 0))
        (magit2--put-face (match-beginning 0) boundary
                         'magit2-keyword msg))))
  msg)

(defun magit2-log-maybe-show-more-commits (section)
  "When point is at the end of a log buffer, insert more commits.

Log buffers end with a button \"Type + to show more history\".
When the use of a section movement command puts point on that
button, then automatically show more commits, without the user
having to press \"+\".

This function is called by `magit2-section-movement-hook' and
exists mostly for backward compatibility reasons."
  (when (and (eq (oref section type) 'longer)
             magit2-log-auto-more)
    (magit2-log-double-commit-limit)
    (forward-line -1)
    (magit2-section-forward)))

(add-hook 'magit2-section-movement-hook #'magit2-log-maybe-show-more-commits)

(defvar magit2--update-revision-buffer nil)

(defun magit2-log-maybe-update-revision-buffer (&optional _)
  "When moving in a log or cherry buffer, update the revision buffer.
If there is no revision buffer in the same frame, then do nothing."
  (when (derived-mode-p 'magit2-log-mode 'magit2-cherry-mode 'magit2-reflog-mode)
    (magit2--maybe-update-revision-buffer)))

(add-hook 'magit2-section-movement-hook #'magit2-log-maybe-update-revision-buffer)

(defun magit2--maybe-update-revision-buffer ()
  (when-let ((commit (magit2-section-value-if 'commit))
             (buffer (magit2-get-mode-buffer 'magit2-revision-mode nil t)))
    (if magit2--update-revision-buffer
        (setq magit2--update-revision-buffer (list commit buffer))
      (setq magit2--update-revision-buffer (list commit buffer))
      (run-with-idle-timer
       magit2-update-other-window-delay nil
       (let ((args (let ((magit2-direct-use-buffer-arguments 'selected))
                     (magit2-show-commit--arguments))))
         (lambda ()
           (pcase-let ((`(,rev ,buf) magit2--update-revision-buffer))
             (setq magit2--update-revision-buffer nil)
             (when (buffer-live-p buf)
               (let ((magit2-display-buffer-noselect t))
                 (apply #'magit2-show-commit rev args))))
           (setq magit2--update-revision-buffer nil)))))))

(defvar magit2--update-blob-buffer nil)

(defun magit2-log-maybe-update-blob-buffer (&optional _)
  "When moving in a log or cherry buffer, update the blob buffer.
If there is no blob buffer in the same frame, then do nothing."
  (when (derived-mode-p 'magit2-log-mode 'magit2-cherry-mode 'magit2-reflog-mode)
    (magit2--maybe-update-blob-buffer)))

(defun magit2--maybe-update-blob-buffer ()
  (when-let ((commit (magit2-section-value-if 'commit))
             (buffer (--first (with-current-buffer it
                                (eq revert-buffer-function
                                    'magit2-revert-rev-file-buffer))
                              (mapcar #'window-buffer (window-list)))))
    (if magit2--update-blob-buffer
        (setq magit2--update-blob-buffer (list commit buffer))
      (setq magit2--update-blob-buffer (list commit buffer))
      (run-with-idle-timer
       magit2-update-other-window-delay nil
       (lambda ()
         (pcase-let ((`(,rev ,buf) magit2--update-blob-buffer))
           (setq magit2--update-blob-buffer nil)
           (when (buffer-live-p buf)
             (with-selected-window (get-buffer-window buf)
               (with-current-buffer buf
                 (save-excursion
                   (magit2-blob-visit (list (magit2-rev-parse rev)
                                           (magit2-file-relative-name
                                            magit2-buffer-file-name)))))))))))))

(defun magit2-log-goto-commit-section (rev)
  (let ((abbrev (magit2-rev-format "%h" rev)))
    (when-let ((section (--first (equal (oref it value) abbrev)
                                 (oref magit2-root-section children))))
      (goto-char (oref section start)))))

(defun magit2-log-goto-same-commit ()
  (when (and magit2-previous-section
             (magit2-section-match '(commit branch)
                                  magit2-previous-section))
    (magit2-log-goto-commit-section (oref magit2-previous-section value))))

;;; Log Margin

(defvar-local magit2-log-margin-show-shortstat nil)

(defun magit2-toggle-log-margin-style ()
  "Toggle between the regular and the shortstat margin style.
The shortstat style is experimental and rather slow."
  (interactive)
  (setq magit2-log-margin-show-shortstat
        (not magit2-log-margin-show-shortstat))
  (magit2-set-buffer-margin nil t))

(defun magit2-log-format-margin (rev author date)
  (when (magit2-margin-option)
    (if magit2-log-margin-show-shortstat
        (magit2-log-format-shortstat-margin rev)
      (magit2-log-format-author-margin author date))))

(defun magit2-log-format-author-margin (author date &optional previous-line)
  (pcase-let ((`(,_ ,style ,width ,details ,details-width)
               (or magit2-buffer-margin
                   (symbol-value (magit2-margin-option)))))
    (magit2-make-margin-overlay
     (concat (and details
                  (concat (magit2--propertize-face
                           (truncate-string-to-width
                            (or author "")
                            details-width
                            nil ?\s
                            (if (char-displayable-p ?…) "…" ">"))
                           'magit2-log-author)
                          " "))
             (magit2--propertize-face
              (if (stringp style)
                  (format-time-string
                   style
                   (seconds-to-time (string-to-number date)))
                (pcase-let* ((abbr (eq style 'age-abbreviated))
                             (`(,cnt ,unit) (magit2--age date abbr)))
                  (format (format (if abbr "%%2i%%-%ic" "%%2i %%-%is")
                                  (- width (if details (1+ details-width) 0)))
                          cnt unit)))
              'magit2-log-date))
     previous-line)))

(defun magit2-log-format-shortstat-margin (rev)
  (magit2-make-margin-overlay
   (if-let ((line (and rev (magit2-git-string
                            "show" "--format=" "--shortstat" rev))))
       (if (string-match "\
\\([0-9]+\\) files? changed, \
\\(?:\\([0-9]+\\) insertions?(\\+)\\)?\
\\(?:\\(?:, \\)?\\([0-9]+\\) deletions?(-)\\)?\\'" line)
           (magit2-bind-match-strings (files add del) line
             (format
              "%5s %5s%4s"
              (if add
                  (magit2--propertize-face (format "%s+" add)
                                          'magit2-diffstat-added)
                "")
              (if del
                  (magit2--propertize-face (format "%s-" del)
                                          'magit2-diffstat-removed)
                "")
              files))
         "")
     "")))

(defun magit2-log-margin-width (style details details-width)
  (if magit2-log-margin-show-shortstat
      16
    (+ (if details (1+ details-width) 0)
       (if (stringp style)
           (length (format-time-string style))
         (+ 2 ; two digits
            1 ; trailing space
            (if (eq style 'age-abbreviated)
                1  ; single character
              (+ 1 ; gap after digits
                 (apply #'max (--map (max (length (nth 1 it))
                                          (length (nth 2 it)))
                                     magit2--age-spec)))))))))

;;; Select Mode

(defvar magit2-log-select-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-log-mode-map)
    (define-key map (kbd "C-c C-b") 'undefined)
    (define-key map (kbd "C-c C-f") 'undefined)
    (define-key map (kbd ".")       'magit2-log-select-pick)
    (define-key map (kbd "e")       'magit2-log-select-pick)
    (define-key map (kbd "C-c C-c") 'magit2-log-select-pick)
    (define-key map (kbd "q")       'magit2-log-select-quit)
    (define-key map (kbd "C-c C-k") 'magit2-log-select-quit)
    map)
  "Keymap for `magit2-log-select-mode'.")

(put 'magit2-log-select-pick :advertised-binding [?\C-c ?\C-c])
(put 'magit2-log-select-quit :advertised-binding [?\C-c ?\C-k])

(define-derived-mode magit2-log-select-mode magit2-log-mode "Magit Select"
  "Mode for selecting a commit from history.

This mode is documented in info node `(magit2)Select from Log'.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-visit-thing] or \\[magit2-diff-show-or-scroll-up] \
to visit the commit at point.

\\<magit2-log-select-mode-map>\
Type \\[magit2-log-select-pick] to select the commit at point.
Type \\[magit2-log-select-quit] to abort without selecting a commit."
  :group 'magit2-log
  (hack-dir-local-variables-non-file-buffer))

(put 'magit2-log-select-mode 'magit2-log-default-arguments
     '("--graph" "-n256" "--decorate"))

(defun magit2-log-select-setup-buffer (revs args)
  (magit2-setup-buffer #'magit2-log-select-mode nil
    (magit2-buffer-revisions revs)
    (magit2-buffer-log-args args)))

(defun magit2-log-select-refresh-buffer ()
  (magit2-insert-section (logbuf)
    (magit2-insert-log magit2-buffer-revisions
                       magit2-buffer-log-args)))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-log-select-mode))
  magit2-buffer-revisions)

(defvar-local magit2-log-select-pick-function nil)
(defvar-local magit2-log-select-quit-function nil)

(defun magit2-log-select (pick &optional msg quit branch args initial)
  (declare (indent defun))
  (unless initial
    (setq initial (magit2-commit-at-point)))
  (magit2-log-select-setup-buffer
   (or branch (magit2-get-current-branch) "HEAD")
   (append args
           (car (magit2-log--get-value 'magit2-log-select-mode
                                      magit2-direct-use-buffer-arguments))))
  (when initial
    (magit2-log-goto-commit-section initial))
  (setq magit2-log-select-pick-function pick)
  (setq magit2-log-select-quit-function quit)
  (when magit2-log-select-show-usage
    (let ((pick (propertize (substitute-command-keys
                             "\\[magit2-log-select-pick]")
                            'font-lock-face
                            'magit2-header-line-key))
          (quit (propertize (substitute-command-keys
                             "\\[magit2-log-select-quit]")
                            'font-lock-face
                            'magit2-header-line-key)))
      (setq msg (format-spec
                 (if msg
                     (if (string-suffix-p "," msg)
                         (concat msg " or %q to abort")
                       msg)
                   "Type %p to select commit at point, or %q to abort")
                 `((?p . ,pick)
                   (?q . ,quit)))))
    (magit2--add-face-text-property
     0 (length msg) 'magit2-header-line-log-select t msg)
    (when (memq magit2-log-select-show-usage '(both header-line))
      (magit2-set-header-line-format msg))
    (when (memq magit2-log-select-show-usage '(both echo-area))
      (message "%s" (substring-no-properties msg)))))

(defun magit2-log-select-pick ()
  "Select the commit at point and act on it.
Call `magit2-log-select-pick-function' with the selected
commit as argument."
  (interactive)
  (let ((fun magit2-log-select-pick-function)
        (rev (magit2-commit-at-point)))
    (magit2-mode-bury-buffer 'kill)
    (funcall fun rev)))

(defun magit2-log-select-quit ()
  "Abort selecting a commit, don't act on any commit.
Call `magit2-log-select-quit-function' if set."
  (interactive)
  (let ((fun magit2-log-select-quit-function))
    (magit2-mode-bury-buffer 'kill)
    (when fun (funcall fun))))

;;; Cherry Mode

(defvar magit2-cherry-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit2-mode-map)
    (define-key map "q" 'magit2-log-bury-buffer)
    (define-key map "L" 'magit2-margin-settings)
    map)
  "Keymap for `magit2-cherry-mode'.")

(define-derived-mode magit2-cherry-mode magit2-mode "Magit Cherry"
  "Mode for looking at commits not merged upstream.

\\<magit2-mode-map>\
Type \\[magit2-refresh] to refresh the current buffer.
Type \\[magit2-visit-thing] or \\[magit2-diff-show-or-scroll-up] \
to visit the commit at point.

Type \\[magit2-cherry-pick] to apply the commit at point.

\\{magit2-cherry-mode-map}"
  :group 'magit2-log
  (hack-dir-local-variables-non-file-buffer)
  (setq magit2--imenu-group-types 'cherries))

(defun magit2-cherry-setup-buffer (head upstream)
  (magit2-setup-buffer #'magit2-cherry-mode nil
    (magit2-buffer-refname head)
    (magit2-buffer-upstream upstream)
    (magit2-buffer-range (concat upstream ".." head))))

(defun magit2-cherry-refresh-buffer ()
  (magit2-insert-section (cherry)
    (magit2-run-section-hook 'magit2-cherry-sections-hook)))

(cl-defmethod magit2-buffer-value (&context (major-mode magit2-cherry-mode))
  magit2-buffer-range)

;;;###autoload
(defun magit2-cherry (head upstream)
  "Show commits in a branch that are not merged in the upstream branch."
  (interactive
   (let  ((head (magit2-read-branch "Cherry head")))
     (list head (magit2-read-other-branch "Cherry upstream" head
                                         (magit2-get-upstream-branch head)))))
  (require 'magit2)
  (magit2-cherry-setup-buffer head upstream))

(defun magit2-insert-cherry-headers ()
  "Insert headers appropriate for `magit2-cherry-mode' buffers."
  (let ((branch (propertize magit2-buffer-refname
                            'font-lock-face 'magit2-branch-local))
        (upstream (propertize magit2-buffer-upstream 'font-lock-face
                              (if (magit2-local-branch-p magit2-buffer-upstream)
                                  'magit2-branch-local
                                'magit2-branch-remote))))
    (magit2-insert-head-branch-header branch)
    (magit2-insert-upstream-branch-header branch upstream "Upstream: ")
    (insert ?\n)))

(defun magit2-insert-cherry-commits ()
  "Insert commit sections into a `magit2-cherry-mode' buffer."
  (magit2-insert-section (cherries)
    (magit2-insert-heading "Cherry commits:")
    (magit2-git-wash (apply-partially 'magit2-log-wash-log 'cherry)
      "cherry" "-v" "--abbrev"
      magit2-buffer-upstream
      magit2-buffer-refname)))

;;; Log Sections
;;;; Standard Log Sections

(defvar magit2-unpulled-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-diff-dwim)
    map)
  "Keymap for `unpulled' sections.")

(magit2-define-section-jumper magit2-jump-to-unpulled-from-upstream
  "Unpulled from @{upstream}" unpulled "..@{upstream}")

(defun magit2-insert-unpulled-from-upstream ()
  "Insert commits that haven't been pulled from the upstream yet."
  (when-let ((upstream (magit2-get-upstream-branch)))
    (magit2-insert-section (unpulled "..@{upstream}" t)
      (magit2-insert-heading
        (format (propertize "Unpulled from %s."
                            'font-lock-face 'magit2-section-heading)
                upstream))
      (magit2-insert-log "..@{upstream}" magit2-buffer-log-args)
      (magit2-log-insert-child-count))))

(magit2-define-section-jumper magit2-jump-to-unpulled-from-pushremote
  "Unpulled from <push-remote>" unpulled
  (concat ".." (magit2-get-push-branch)))

(defun magit2-insert-unpulled-from-pushremote ()
  "Insert commits that haven't been pulled from the push-remote yet."
  (--when-let (magit2-get-push-branch)
    (when (magit2--insert-pushremote-log-p)
      (magit2-insert-section (unpulled (concat ".." it) t)
        (magit2-insert-heading
          (format (propertize "Unpulled from %s."
                              'font-lock-face 'magit2-section-heading)
                  (propertize it 'font-lock-face 'magit2-branch-remote)))
        (magit2-insert-log (concat ".." it) magit2-buffer-log-args)
        (magit2-log-insert-child-count)))))

(defvar magit2-unpushed-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap magit2-visit-thing] 'magit2-diff-dwim)
    map)
  "Keymap for `unpushed' sections.")

(magit2-define-section-jumper magit2-jump-to-unpushed-to-upstream
  "Unpushed to @{upstream}" unpushed "@{upstream}..")

(defun magit2-insert-unpushed-to-upstream-or-recent ()
  "Insert section showing unpushed or other recent commits.
If an upstream is configured for the current branch and it is
behind of the current branch, then show the commits that have
not yet been pushed into the upstream branch.  If no upstream is
configured or if the upstream is not behind of the current branch,
then show the last `magit2-log-section-commit-count' commits."
  (let ((upstream (magit2-get-upstream-branch)))
    (if (or (not upstream)
            (magit2-rev-ancestor-p "HEAD" upstream))
        (magit2-insert-recent-commits 'unpushed "@{upstream}..")
      (magit2-insert-unpushed-to-upstream))))

(defun magit2-insert-unpushed-to-upstream ()
  "Insert commits that haven't been pushed to the upstream yet."
  (when (magit2-rev-parse "@{upstream}")
    (magit2-insert-section (unpushed "@{upstream}..")
      (magit2-insert-heading
        (format (propertize "Unmerged into %s."
                            'font-lock-face 'magit2-section-heading)
                (magit2-get-upstream-branch)))
      (magit2-insert-log "@{upstream}.." magit2-buffer-log-args)
      (magit2-log-insert-child-count))))

(defun magit2-insert-recent-commits (&optional type value)
  "Insert section showing recent commits.
Show the last `magit2-log-section-commit-count' commits."
  (let* ((start (format "HEAD~%s" magit2-log-section-commit-count))
         (range (when (magit2-rev-parse start)
                  (concat start "..HEAD"))))
    (magit2-insert-section ((eval (or type 'recent))
                           (or value range)
                           t)
      (magit2-insert-heading "Recent commits")
      (magit2-insert-log range (cons (format "-n%d" magit2-log-section-commit-count)
                                     (--remove (string-prefix-p "-n" it)
                                               magit2-buffer-log-args))))))

(magit2-define-section-jumper magit2-jump-to-unpushed-to-pushremote
  "Unpushed to <push-remote>" unpushed
  (concat (magit2-get-push-branch) ".."))

(defun magit2-insert-unpushed-to-pushremote ()
  "Insert commits that haven't been pushed to the push-remote yet."
  (--when-let (magit2-get-push-branch)
    (when (magit2--insert-pushremote-log-p)
      (magit2-insert-section (unpushed (concat it "..") t)
        (magit2-insert-heading
          (format (propertize "Unpushed to %s."
                              'font-lock-face 'magit2-section-heading)
                  (propertize it 'font-lock-face 'magit2-branch-remote)))
        (magit2-insert-log (concat it "..") magit2-buffer-log-args)
        (magit2-log-insert-child-count)))))

(defun magit2--insert-pushremote-log-p ()
  (magit2--with-refresh-cache
      (cons default-directory 'magit2--insert-pushremote-log-p)
    (not (and (equal (magit2-get-push-branch)
                     (magit2-get-upstream-branch))
              (or (memq 'magit2-insert-unpulled-from-upstream
                        magit2-status-sections-hook)
                  (memq 'magit2-insert-unpulled-from-upstream-or-recent
                        magit2-status-sections-hook))))))

(defun magit2-log-insert-child-count ()
  (when magit2-section-show-child-count
    (let ((count (length (oref magit2-insert-section--current children))))
      (when (> count 0)
        (when (eq count (magit2-log-get-commit-limit))
          (setq count (format "%s+" count)))
        (save-excursion
          (goto-char (- (oref magit2-insert-section--current content) 2))
          (insert (format " (%s)" count))
          (delete-char 1))))))

;;;; Auxiliary Log Sections

(defun magit2-insert-unpulled-cherries ()
  "Insert section showing unpulled commits.
Like `magit2-insert-unpulled-from-upstream' but prefix each commit
which has not been applied yet (i.e. a commit with a patch-id
not shared with any local commit) with \"+\", and all others with
\"-\"."
  (when (magit2-git-success "rev-parse" "@{upstream}")
    (magit2-insert-section (unpulled "..@{upstream}")
      (magit2-insert-heading "Unpulled commits:")
      (magit2-git-wash (apply-partially 'magit2-log-wash-log 'cherry)
        "cherry" "-v" (magit2-abbrev-arg)
        (magit2-get-current-branch) "@{upstream}"))))

(defun magit2-insert-unpushed-cherries ()
  "Insert section showing unpushed commits.
Like `magit2-insert-unpushed-to-upstream' but prefix each commit
which has not been applied to upstream yet (i.e. a commit with
a patch-id not shared with any upstream commit) with \"+\", and
all others with \"-\"."
  (when (magit2-git-success "rev-parse" "@{upstream}")
    (magit2-insert-section (unpushed "@{upstream}..")
      (magit2-insert-heading "Unpushed commits:")
      (magit2-git-wash (apply-partially 'magit2-log-wash-log 'cherry)
        "cherry" "-v" (magit2-abbrev-arg) "@{upstream}"))))

;;; _
(provide 'magit2-log)
;;; magit2-log.el ends here
