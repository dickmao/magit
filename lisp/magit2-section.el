;;; magit2-section.el --- Sections for read-only buffers  -*- lexical-binding: t -*-

;; Copyright (C) 2010-2022  The Magit Project Contributors
;;
;; You should have received a copy of the AUTHORS.md file which
;; lists all contributors.  If not, see http://magit2.vc/authors.

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>

;; Keywords: tools
;; Homepage: https://github.com/magit2/magit2
;; Package-Requires: ((emacs "25.1") (dash "2.19.1"))
;; Package-Version: 3.3.0-git
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Magit-Section is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; Magit-Section is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Magit.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; This package implements the main user interface of Magit — the
;; collapsible sections that make up its buffers.  This package used
;; to be distributed as part of Magit but now it can also be used by
;; other packages that have nothing to do with Magit or Git.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'eieio)
(require 'seq)
(require 'subr-x)

(eval-when-compile (require 'benchmark))

(defvar magit2-section-highlight-force-update)

;;; Hooks

(defvar magit2-section-movement-hook nil
  "Hook run by `magit2-section-goto'.
That function in turn is used by all section movement commands.")

(defvar magit2-section-highlight-hook
  '(magit2-section-highlight
    magit2-section-highlight-selection)
  "Functions used to highlight the current section.
Each function is run with the current section as only argument
until one of them returns non-nil.")

(defvar magit2-section-unhighlight-hook nil
  "Functions used to unhighlight the previously current section.
Each function is run with the current section as only argument
until one of them returns non-nil.  Most sections are properly
unhighlighted without requiring a specialized unhighlighter,
diff-related sections being the only exception.")

(defvar magit2-section-set-visibility-hook
  '(magit2-section-cached-visibility)
  "Hook used to set the initial visibility of a section.
Stop at the first function that returns non-nil.  The returned
value should be `show', `hide' or nil.  If no function returns
non-nil, determine the visibility as usual, i.e. use the
hardcoded section specific default (see `magit2-insert-section').")

(defvar magit2-section-goto-successor-hook nil
  "Hook used to go to the same section as was current before a refresh.
This is only used if the standard mechanism for doing so did not
succeed.")

;;; Options

(defgroup magit2-section nil
  "Expandable sections."
  :link '(info-link "(magit2)Sections")
  :group 'extensions)

(defcustom magit2-section-show-child-count t
  "Whether to append the number of children to section headings.
This only applies to sections for which doing so makes sense."
  :package-version '(magit2-section . "2.1.0")
  :group 'magit2-section
  :type 'boolean)

(defcustom magit2-section-cache-visibility t
  "Whether to cache visibility of sections.

Sections always retain their visibility state when they are being
recreated during a refresh.  But if a section disappears and then
later reappears again, then this option controls whether this is
the case.

If t, then cache the visibility of all sections.  If a list of
section types, then only do so for matching sections.  If nil,
then don't do so for any sections."
  :package-version '(magit2-section . "2.12.0")
  :group 'magit2-section
  :type '(choice (const  :tag "Don't cache visibility" nil)
                 (const  :tag "Cache visibility of all sections" t)
                 (repeat :tag "Cache visibility for section types" symbol)))

(defcustom magit2-section-initial-visibility-alist
  '((stashes . hide))
  "Alist controlling the initial visibility of sections.

Each element maps a section type or lineage to the initial
visibility state for such sections.  The state has to be one of
`show' or `hide', or a function that returns one of these symbols.
A function is called with the section as the only argument.

Use the command `magit2-describe-section' to determine a section's
lineage or type.  The vector in the output is the section lineage
and the type is the first element of that vector.  Wildcards can
be used, see `magit2-section-match'.

Currently this option is only used to override hardcoded defaults,
but in the future it will also be used set the defaults.

An entry whose key is `magit2-status-initial-section' specifies
the visibility of the section `magit2-status-goto-initial-section'
jumps to.  This does not only override defaults, but also other
entries of this alist."
  :package-version '(magit2-section . "2.12.0")
  :group 'magit2-section
  :type '(alist :key-type (sexp :tag "Section type/lineage")
                :value-type (choice (const hide)
                                    (const show)
                                    function)))

(defcustom magit2-section-visibility-indicator
  (if (window-system)
      '(magit2-fringe-bitmap> . magit2-fringe-bitmapv)
    (cons (if (char-displayable-p ?…) "…" "...")
          t))
  "Whether and how to indicate that a section can be expanded/collapsed.

If nil, then don't show any indicators.
Otherwise the value has to have one of these two forms:

\(EXPANDABLE-BITMAP . COLLAPSIBLE-BITMAP)

  Both values have to be variables whose values are fringe
  bitmaps.  In this case every section that can be expanded or
  collapsed gets an indicator in the left fringe.

  To provide extra padding around the indicator, set
  `left-fringe-width' in `magit2-mode-hook'.

\(STRING . BOOLEAN)

  In this case STRING (usually an ellipsis) is shown at the end
  of the heading of every collapsed section.  Expanded sections
  get no indicator.  The cdr controls whether the appearance of
  these ellipsis take section highlighting into account.  Doing
  so might potentially have an impact on performance, while not
  doing so is kinda ugly."
  :package-version '(magit2-section . "3.0.0")
  :group 'magit2-section
  :type '(choice (const :tag "No indicators" nil)
                 (cons  :tag "Use +- fringe indicators"
                        (const magit2-fringe-bitmap+)
                        (const magit2-fringe-bitmap-))
                 (cons  :tag "Use >v fringe indicators"
                        (const magit2-fringe-bitmap>)
                        (const magit2-fringe-bitmapv))
                 (cons  :tag "Use bold >v fringe indicators)"
                        (const magit2-fringe-bitmap-bold>)
                        (const magit2-fringe-bitmap-boldv))
                 (cons  :tag "Use custom fringe indicators"
                        (variable :tag "Expandable bitmap variable")
                        (variable :tag "Collapsible bitmap variable"))
                 (cons  :tag "Use ellipses at end of headings"
                        (string :tag "Ellipsis" "…")
                        (choice :tag "Use face kludge"
                                (const :tag "Yes (potentially slow)" t)
                                (const :tag "No (kinda ugly)" nil)))))

(define-obsolete-variable-alias 'magit2-keep-region-overlay
  'magit2-section-keep-region-overlay "Magit-Section 3.4.0")
(defcustom magit2-section-keep-region-overlay nil
  "Whether to keep the region overlay when there is a valid selection.

By default Magit removes the regular region overlay if, and only
if, that region constitutes a valid selection as understood by
Magit commands.  Otherwise it does not remove that overlay, and
the region looks like it would in other buffers.

There are two types of such valid selections: hunk-internal
regions and regions that select two or more sibling sections.
In such cases Magit removes the region overlay and instead
highlights a slightly larger range.  All text (for hunk-internal
regions) or the headings of all sections (for sibling selections)
that are inside that range (not just inside the region) are acted
on by commands such as the staging command.  This buffer range
begins at the beginning of the line on which the region begins
and ends at the end of the line on which the region ends.

Because Magit acts on this larger range and not the region, it is
actually quite important to visualize that larger range.  If we
don't do that, then one might think that these commands act on
the region instead.  If you want to *also* visualize the region,
then set this option to t.  But please note that when the region
does *not* constitute a valid selection, then the region is
*always* visualized as usual, and that it is usually under such
circumstances that you want to use a non-magit2 command to act on
the region.

Besides keeping the region overlay, setting this option to t also
causes all face properties, except for `:foreground', to be
ignored for the faces used to highlight headings of selected
sections.  This avoids the worst conflicts that result from
displaying the region and the selection overlays at the same
time.  We are not interested in dealing with other conflicts.
In fact we *already* provide a way to avoid all of these
conflicts: *not* changing the value of this option.

It should be clear by now that we consider it a mistake to set
this to display the region when the Magit selection is also
visualized, but since it has been requested a few times and
because it doesn't cost much to offer this option we do so.
However that might change.  If the existence of this option
starts complicating other things, then it will be removed."
  :package-version '(magit2-section . "2.3.0")
  :group 'magit2-section
  :type 'boolean)

(defcustom magit2-section-disable-line-numbers t
  "In Magit buffers, whether to disable modes that display line numbers.

Some users who turn on `global-display-line-numbers-mode' (or
`global-nlinum-mode' or `global-linum-mode') expect line numbers
to be displayed everywhere except in Magit buffers.  Other users
do not expect Magit buffers to be treated differently.  At least
in theory users in the first group should not use the global mode,
but that ship has sailed, thus this option."
  :package-version '(magit2-section . "3.0.0")
  :group 'magit2-section
  :type 'boolean)

;;; Faces

(defgroup magit2-section-faces nil
  "Faces used by Magit-Section."
  :group 'magit2-section
  :group 'faces)

(defface magit2-section-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey95")
    (((class color) (background  dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey20"))
  "Face for highlighting the current section."
  :group 'magit2-section-faces)

(defface magit2-section-heading
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "DarkGoldenrod4"
     :weight bold)
    (((class color) (background  dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "LightGoldenrod2"
     :weight bold))
  "Face for section headings."
  :group 'magit2-section-faces)

(defface magit2-section-secondary-heading
  `((t ,@(and (>= emacs-major-version 27) '(:extend t))
       :weight bold))
  "Face for section headings of some secondary headings."
  :group 'magit2-section-faces)

(defface magit2-section-heading-selection
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "salmon4")
    (((class color) (background  dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "LightSalmon3"))
  "Face for selected section headings."
  :group 'magit2-section-faces)

(defface magit2-section-child-count '((t nil))
  "Face used for child counts at the end of some section headings."
  :group 'magit2-section-faces)

;;; Classes

(defvar magit2--current-section-hook nil
  "Internal variable used for `magit2-describe-section'.")

(defvar magit2--section-type-alist nil)

(defclass magit2-section ()
  ((keymap   :initform nil :allocation :class)
   (type     :initform nil :initarg :type)
   (value    :initform nil :initarg :value)
   (start    :initform nil :initarg :start)
   (content  :initform nil)
   (end      :initform nil)
   (hidden   :initform nil)
   (washer   :initform nil)
   (process  :initform nil)
   (heading-highlight-face :initform nil)
   (inserter :initform (symbol-value 'magit2--current-section-hook))
   (parent   :initform nil :initarg :parent)
   (children :initform nil)))

;;; Mode

(defvar symbol-overlay-inhibit-map)

(defvar magit2-section-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "TAB") 'magit2-section-toggle)
    (define-key map [C-tab]     'magit2-section-cycle)
    (define-key map [M-tab]     'magit2-section-cycle)
    ;; [backtab] is the most portable binding for Shift+Tab.
    (define-key map [backtab]   'magit2-section-cycle-global)
    (define-key map (kbd   "^") 'magit2-section-up)
    (define-key map (kbd   "p") 'magit2-section-backward)
    (define-key map (kbd   "n") 'magit2-section-forward)
    (define-key map (kbd "M-p") 'magit2-section-backward-sibling)
    (define-key map (kbd "M-n") 'magit2-section-forward-sibling)
    (define-key map (kbd   "1") 'magit2-section-show-level-1)
    (define-key map (kbd   "2") 'magit2-section-show-level-2)
    (define-key map (kbd   "3") 'magit2-section-show-level-3)
    (define-key map (kbd   "4") 'magit2-section-show-level-4)
    (define-key map (kbd "M-1") 'magit2-section-show-level-1-all)
    (define-key map (kbd "M-2") 'magit2-section-show-level-2-all)
    (define-key map (kbd "M-3") 'magit2-section-show-level-3-all)
    (define-key map (kbd "M-4") 'magit2-section-show-level-4-all)
    map))

(define-derived-mode magit2-section-mode special-mode "Magit-Sections"
  "Parent major mode from which major modes with Magit-like sections inherit.

Magit-Section is documented in info node `(magit2-section)'."
  :group 'magit2-section
  (buffer-disable-undo)
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (setq-local line-move-visual t) ; see #1771
  ;; Turn off syntactic font locking, but not by setting
  ;; `font-lock-defaults' because that would enable font locking, and
  ;; not all magit2 plugins may be ready for that (see #3950).
  (setq-local font-lock-syntactic-face-function #'ignore)
  (setq show-trailing-whitespace nil)
  (setq-local symbol-overlay-inhibit-map t)
  (setq list-buffers-directory (abbreviate-file-name default-directory))
  ;; (hack-dir-local-variables-non-file-buffer)
  (make-local-variable 'text-property-default-nonsticky)
  (push (cons 'keymap t) text-property-default-nonsticky)
  (add-hook 'pre-command-hook #'magit2-section-pre-command-hook nil t)
  (add-hook 'post-command-hook #'magit2-section-post-command-hook t t)
  (add-hook 'deactivate-mark-hook #'magit2-section-deactivate-mark t t)
  (setq-local redisplay-highlight-region-function
              'magit2-section--highlight-region)
  (setq-local redisplay-unhighlight-region-function
              'magit2-section--unhighlight-region)
  (when magit2-section-disable-line-numbers
    (when (bound-and-true-p global-linum-mode)
      (linum-mode -1))
    (when (and (fboundp 'nlinum-mode)
               (bound-and-true-p global-nlinum-mode))
      (nlinum-mode -1))
    (when (and (fboundp 'display-line-numbers-mode)
               (bound-and-true-p global-display-line-numbers-mode))
      (display-line-numbers-mode -1)))
  (when (fboundp 'magit2-preserve-section-visibility-cache)
    (add-hook 'kill-buffer-hook #'magit2-preserve-section-visibility-cache)))

;;; Core

(defvar-local magit2-root-section nil
  "The root section in the current buffer.
All other sections are descendants of this section.  The value
of this variable is set by `magit2-insert-section' and you should
never modify it.")
(put 'magit2-root-section 'permanent-local t)

(defun magit2-current-section ()
  "Return the section at point."
  (or (get-text-property (point) 'magit2-section) magit2-root-section))

(defun magit2-section-ident (section)
  "Return an unique identifier for SECTION.
The return value has the form ((TYPE . VALUE)...)."
  (with-slots (type value parent) section
    (cons (cons type
                (cond ((eieio-object-p value)
                       (magit2-section-ident-value value))
                      ((not (memq type '(unpulled unpushed))) value)
                      ((string-match-p "@{upstream}" value) value)
                      ;; Unfortunately Git chokes on "@{push}" when
                      ;; the value of `push.default' does not allow a
                      ;; 1:1 mapping.  Arbitrary commands may consult
                      ;; the section value so we cannot use "@{push}".
                      ;; But `unpushed' and `unpulled' sections should
                      ;; keep their identity when switching branches
                      ;; so we have to use another value here.
                      ((string-match-p "\\`\\.\\." value) "..@{push}")
                      (t "@{push}..")))
          (and parent
               (magit2-section-ident parent)))))

(cl-defgeneric magit2-section-ident-value (value)
  "Return a constant representation of VALUE.
VALUE is the value of a `magit2-section' object.  If that is an
object itself, then that is not suitable to be used to identify
the section because two objects may represent the same thing but
not be equal.  If possible a method should be added for such
objects, which returns a value that is equal.  Otherwise the
catch-all method is used, which just returns the argument
itself.")

(cl-defmethod magit2-section-ident-value (arg) arg)

(defun magit2-get-section (ident &optional root)
  "Return the section identified by IDENT.
IDENT has to be a list as returned by `magit2-section-ident'.
If optional ROOT is non-nil, then search in that section tree
instead of in the one whose root `magit2-root-section' is."
  (setq ident (reverse ident))
  (let ((section (or root magit2-root-section)))
    (when (eq (car (pop ident))
              (oref section type))
      (while (and ident
                  (pcase-let* ((`(,type . ,value) (car ident))
                               (value (magit2-section-ident-value value)))
                    (setq section
                          (cl-find-if (lambda (section)
                                        (and (eq (oref section type) type)
                                             (equal (magit2-section-ident-value
                                                     (oref section value))
                                                    value)))
                                      (oref section children)))))
        (pop ident))
      section)))

(defun magit2-section-lineage (section)
  "Return the lineage of SECTION.
The return value has the form (TYPE...)."
  (cons (oref section type)
        (when-let ((parent (oref section parent)))
          (magit2-section-lineage parent))))

(defvar magit2-insert-section--current nil "For internal use only.")
(defvar magit2-insert-section--parent  nil "For internal use only.")
(defvar magit2-insert-section--oldroot nil "For internal use only.")

;;; Commands
;;;; Movement

(defun magit2-section-forward ()
  "Move to the beginning of the next visible section."
  (interactive)
  (if (eobp)
      (user-error "No next section")
    (let ((section (magit2-current-section)))
      (if (oref section parent)
          (let ((next (and (not (oref section hidden))
                           (not (= (oref section end)
                                   (1+ (point))))
                           (car (oref section children)))))
            (while (and section (not next))
              (unless (setq next (car (magit2-section-siblings section 'next)))
                (setq section (oref section parent))))
            (if next
                (magit2-section-goto next)
              (user-error "No next section")))
        (magit2-section-goto 1)))))

(defun magit2-section-backward ()
  "Move to the beginning of the current or the previous visible section.
When point is at the beginning of a section then move to the
beginning of the previous visible section.  Otherwise move to
the beginning of the current section."
  (interactive)
  (if (bobp)
      (user-error "No previous section")
    (let ((section (magit2-current-section)) children)
      (cond
       ((and (= (point)
                (1- (oref section end)))
             (setq children (oref section children)))
        (magit2-section-goto (car (last children))))
       ((and (oref section parent)
             (not (= (point)
                     (oref section start))))
        (magit2-section-goto section))
       (t
        (let ((prev (car (magit2-section-siblings section 'prev))))
          (if prev
              (while (and (not (oref prev hidden))
                          (setq children (oref prev children)))
                (setq prev (car (last children))))
            (setq prev (oref section parent)))
          (cond (prev
                 (magit2-section-goto prev))
                ((oref section parent)
                 (user-error "No previous section"))
                ;; Eob special cases.
                ((not (get-text-property (1- (point)) 'invisible))
                 (magit2-section-goto -1))
                (t
                 (goto-char (previous-single-property-change
                             (1- (point)) 'invisible))
                 (forward-line -1)
                 (magit2-section-goto (magit2-current-section))))))))))

(defun magit2-section-up ()
  "Move to the beginning of the parent section."
  (interactive)
  (--if-let (oref (magit2-current-section) parent)
      (magit2-section-goto it)
    (user-error "No parent section")))

(defun magit2-section-forward-sibling ()
  "Move to the beginning of the next sibling section.
If there is no next sibling section, then move to the parent."
  (interactive)
  (let ((current (magit2-current-section)))
    (if (oref current parent)
        (--if-let (car (magit2-section-siblings current 'next))
            (magit2-section-goto it)
          (magit2-section-forward))
      (magit2-section-goto 1))))

(defun magit2-section-backward-sibling ()
  "Move to the beginning of the previous sibling section.
If there is no previous sibling section, then move to the parent."
  (interactive)
  (let ((current (magit2-current-section)))
    (if (oref current parent)
        (--if-let (car (magit2-section-siblings current 'prev))
            (magit2-section-goto it)
          (magit2-section-backward))
      (magit2-section-goto -1))))

(defun magit2-section-goto (arg)
  (if (integerp arg)
      (progn (forward-line arg)
             (setq arg (magit2-current-section)))
    (goto-char (oref arg start)))
  (run-hook-with-args 'magit2-section-movement-hook arg))

(defun magit2-section-set-window-start (section)
  "Ensure the beginning of SECTION is visible."
  (unless (pos-visible-in-window-p (oref section end))
    (set-window-start (selected-window) (oref section start))))

(defmacro magit2-define-section-jumper (name heading type &optional value)
  "Define an interactive function to go some section.
Together TYPE and VALUE identify the section.
HEADING is the displayed heading of the section."
  (declare (indent defun))
  `(defun ,name (&optional expand) ,(format "\
Jump to the section \"%s\".
With a prefix argument also expand it." heading)
          (interactive "P")
          (--if-let (magit2-get-section
                     (cons (cons ',type ,value)
                           (magit2-section-ident magit2-root-section)))
              (progn (goto-char (oref it start))
                     (when expand
                       (with-local-quit (magit2-section-show it))
                       (recenter 0)))
            (message ,(format "Section \"%s\" wasn't found" heading)))))

;;;; Visibility

(defun magit2-section-show (section)
  "Show the body of the current section."
  (interactive (list (magit2-current-section)))
  (oset section hidden nil)
  (magit2-section--maybe-wash section)
  (when-let ((beg (oref section content)))
    (remove-overlays beg (oref section end) 'invisible t))
  (magit2-section-maybe-update-visibility-indicator section)
  (magit2-section-maybe-cache-visibility section)
  (dolist (child (oref section children))
    (if (oref child hidden)
        (magit2-section-hide child)
      (magit2-section-show child))))

(defun magit2-section--maybe-wash (section)
  (when-let ((washer (oref section washer)))
    (oset section washer nil)
    (let ((inhibit-read-only t)
          (magit2-insert-section--parent section)
          (content (oref section content)))
      (save-excursion
        (if (and content (< content (oref section end)))
            (funcall washer section) ; already partially washed (hunk)
          (goto-char (oref section end))
          (oset section content (point-marker))
          (funcall washer)
          (oset section end (point-marker)))))
    (setq magit2-section-highlight-force-update t)))

(defun magit2-section-hide (section)
  "Hide the body of the current section."
  (interactive (list (magit2-current-section)))
  (if (eq section magit2-root-section)
      (user-error "Cannot hide root section")
    (oset section hidden t)
    (when-let ((beg (oref section content)))
      (let ((end (oref section end)))
        (when (< beg (point) end)
          (goto-char (oref section start)))
        (remove-overlays beg end 'invisible t)
        (let ((o (make-overlay beg end)))
          (overlay-put o 'evaporate t)
          (overlay-put o 'invisible t))))
    (magit2-section-maybe-update-visibility-indicator section)
    (magit2-section-maybe-cache-visibility section)))

(defun magit2-section-toggle (section)
  "Toggle visibility of the body of the current section."
  (interactive (list (magit2-current-section)))
  (cond ((eq section magit2-root-section)
         (user-error "Cannot hide root section"))
        ((oref section hidden)
         (magit2-section-show section))
        (t (magit2-section-hide section))))

(defun magit2-section-toggle-children (section)
  "Toggle visibility of bodies of children of the current section."
  (interactive (list (magit2-current-section)))
  (let* ((children (oref section children))
         (show (--any-p (oref it hidden) children)))
    (dolist (c children)
      (oset c hidden show)))
  (magit2-section-show section))

(defun magit2-section-show-children (section &optional depth)
  "Recursively show the bodies of children of the current section.
With a prefix argument show children that deep and hide deeper
children."
  (interactive (list (magit2-current-section)))
  (magit2-section-show-children-1 section depth)
  (magit2-section-show section))

(defun magit2-section-show-children-1 (section &optional depth)
  (dolist (child (oref section children))
    (oset child hidden nil)
    (if depth
        (if (> depth 0)
            (magit2-section-show-children-1 child (1- depth))
          (magit2-section-hide child))
      (magit2-section-show-children-1 child))))

(defun magit2-section-hide-children (section)
  "Recursively hide the bodies of children of the current section."
  (interactive (list (magit2-current-section)))
  (mapc 'magit2-section-hide (oref section children)))

(defun magit2-section-show-headings (section)
  "Recursively show headings of children of the current section.
Only show the headings, previously shown text-only bodies are
hidden."
  (interactive (list (magit2-current-section)))
  (magit2-section-show-headings-1 section)
  (magit2-section-show section))

(defun magit2-section-show-headings-1 (section)
  (dolist (child (oref section children))
    (oset child hidden nil)
    (when (or (oref child children)
              (not (oref child content)))
      (magit2-section-show-headings-1 child))))

(defun magit2-section-cycle (section)
  "Cycle visibility of current section and its children."
  (interactive (list (magit2-current-section)))
  (if (oref section hidden)
      (progn (magit2-section-show section)
             (magit2-section-hide-children section))
    (let ((children (oref section children)))
      (cond ((and (--any-p (oref it hidden)   children)
                  (--any-p (oref it children) children))
             (magit2-section-show-headings section))
            ((seq-some 'magit2-section-hidden-body children)
             (magit2-section-show-children section))
            (t
             (magit2-section-hide section))))))

(defun magit2-section-cycle-global ()
  "Cycle visibility of all sections in the current buffer."
  (interactive)
  (let ((children (oref magit2-root-section children)))
    (cond ((and (--any-p (oref it hidden)   children)
                (--any-p (oref it children) children))
           (magit2-section-show-headings magit2-root-section))
          ((seq-some 'magit2-section-hidden-body children)
           (magit2-section-show-children magit2-root-section))
          (t
           (mapc 'magit2-section-hide children)))))

(defun magit2-section-hidden-body (section &optional pred)
  (--if-let (oref section children)
      (funcall (or pred '-any-p) 'magit2-section-hidden-body it)
    (and (oref section content)
         (oref section hidden))))

(defun magit2-section-invisible-p (section)
  "Return t if the SECTION's body is invisible.
When the body of an ancestor of SECTION is collapsed then
SECTION's body (and heading) obviously cannot be visible."
  (or (oref section hidden)
      (--when-let (oref section parent)
        (magit2-section-invisible-p it))))

(defun magit2-section-show-level (level)
  "Show surrounding sections up to LEVEL.
If LEVEL is negative, show up to the absolute value.
Sections at higher levels are hidden."
  (if (< level 0)
      (let ((s (magit2-current-section)))
        (setq level (- level))
        (while (> (1- (length (magit2-section-ident s))) level)
          (setq s (oref s parent))
          (goto-char (oref s start)))
        (magit2-section-show-children magit2-root-section (1- level)))
    (cl-do* ((s (magit2-current-section)
                (oref s parent))
             (i (1- (length (magit2-section-ident s)))
                (cl-decf i)))
        ((cond ((< i level) (magit2-section-show-children s (- level i 1)) t)
               ((= i level) (magit2-section-hide s) t))
         (magit2-section-goto s)))))

(defun magit2-section-show-level-1 ()
  "Show surrounding sections on first level."
  (interactive)
  (magit2-section-show-level 1))

(defun magit2-section-show-level-1-all ()
  "Show all sections on first level."
  (interactive)
  (magit2-section-show-level -1))

(defun magit2-section-show-level-2 ()
  "Show surrounding sections up to second level."
  (interactive)
  (magit2-section-show-level 2))

(defun magit2-section-show-level-2-all ()
  "Show all sections up to second level."
  (interactive)
  (magit2-section-show-level -2))

(defun magit2-section-show-level-3 ()
  "Show surrounding sections up to third level."
  (interactive)
  (magit2-section-show-level 3))

(defun magit2-section-show-level-3-all ()
  "Show all sections up to third level."
  (interactive)
  (magit2-section-show-level -3))

(defun magit2-section-show-level-4 ()
  "Show surrounding sections up to fourth level."
  (interactive)
  (magit2-section-show-level 4))

(defun magit2-section-show-level-4-all ()
  "Show all sections up to fourth level."
  (interactive)
  (magit2-section-show-level -4))

;;;; Auxiliary

(defun magit2-describe-section-briefly (section &optional ident)
  "Show information about the section at point.
With a prefix argument show the section identity instead of the
section lineage.  This command is intended for debugging purposes."
  (interactive (list (magit2-current-section) current-prefix-arg))
  (let ((str (format "#<%s %S %S %s-%s%s>"
                     (eieio-object-class section)
                     (let ((val (oref section value)))
                       (cond ((stringp val)
                              (substring-no-properties val))
                             ((and (eieio-object-p val)
                                   (fboundp 'cl-prin1-to-string))
                              (cl-prin1-to-string val))
                             (t
                              val)))
                     (if ident
                         (magit2-section-ident section)
                       (apply #'vector (magit2-section-lineage section)))
                     (when-let ((m (oref section start)))
                       (marker-position m))
                     (if-let ((m (oref section content)))
                         (format "[%s-]" (marker-position m))
                       "")
                     (when-let ((m (oref section end)))
                       (marker-position m)))))
    (if (called-interactively-p 'any)
        (message "%s" str)
      str)))

(cl-defmethod cl-print-object ((section magit2-section) stream)
  "Print `magit2-describe-section' result of SECTION."
  ;; Used by debug and edebug as of Emacs 26.
  (princ (magit2-describe-section-briefly section) stream))

(defun magit2-describe-section (section &optional interactive-p)
  "Show information about the section at point."
  (interactive (list (magit2-current-section) t))
  (let ((inserter-section section))
    (while (and inserter-section (not (oref inserter-section inserter)))
      (setq inserter-section (oref inserter-section parent)))
    (when (and inserter-section (oref inserter-section inserter))
      (setq section inserter-section)))
  (pcase (oref section inserter)
    (`((,hook ,fun) . ,src-src)
     (help-setup-xref `(magit2-describe-section ,section) interactive-p)
     (with-help-window (help-buffer)
       (with-current-buffer standard-output
         (insert (format-message
                  "%s\n  is inserted by `%s'\n  from `%s'"
                  (magit2-describe-section-briefly section)
                  (make-text-button (symbol-name fun) nil
                                    :type 'help-function
                                    'help-args (list fun))
                  (make-text-button (symbol-name hook) nil
                                    :type 'help-variable
                                    'help-args (list hook))))
         (pcase-dolist (`(,hook ,fun) src-src)
           (insert (format-message
                    ",\n  called by `%s'\n  from `%s'"
                    (make-text-button (symbol-name fun) nil
                                      :type 'help-function
                                      'help-args (list fun))
                    (make-text-button (symbol-name hook) nil
                                      :type 'help-variable
                                      'help-args (list hook)))))
         (insert ".\n\n")
         (insert
          (format-message
           "`%s' is "
           (make-text-button (symbol-name fun) nil
                             :type 'help-function 'help-args (list fun))))
         (describe-function-1 fun))))
    (_ (message "%s, inserter unknown"
                (magit2-describe-section-briefly section)))))

;;; Match

(cl-defun magit2-section-match
    (condition &optional (section (magit2-current-section)))
  "Return t if SECTION matches CONDITION.

SECTION defaults to the section at point.  If SECTION is not
specified and there also is no section at point, then return
nil.

CONDITION can take the following forms:
  (CONDITION...)  matches if any of the CONDITIONs matches.
  [CLASS...]      matches if the section's class is the same
                  as the first CLASS or a subclass of that;
                  the section's parent class matches the
                  second CLASS; and so on.
  [* CLASS...]    matches sections that match [CLASS...] and
                  also recursively all their child sections.
  CLASS           matches if the section's class is the same
                  as CLASS or a subclass of that; regardless
                  of the classes of the parent sections.

Each CLASS should be a class symbol, identifying a class that
derives from `magit2-section'.  For backward compatibility CLASS
can also be a \"type symbol\".  A section matches such a symbol
if the value of its `type' slot is `eq'.  If a type symbol has
an entry in `magit2--section-type-alist', then a section also
matches that type if its class is a subclass of the class that
corresponds to the type as per that alist.

Note that it is not necessary to specify the complete section
lineage as printed by `magit2-describe-section-briefly', unless
of course you want to be that precise."
  (and section (magit2-section-match-1 condition section)))

(defun magit2-section-match-1 (condition section)
  (cl-assert condition)
  (and section
       (if (listp condition)
           (--first (magit2-section-match-1 it section) condition)
         (magit2-section-match-2 (if (symbolp condition)
                                    (list condition)
                                  (cl-coerce condition 'list))
                                section))))

(defun magit2-section-match-2 (condition section)
  (if (eq (car condition) '*)
      (or (magit2-section-match-2 (cdr condition) section)
          (when-let ((parent (oref section parent)))
            (magit2-section-match-2 condition parent)))
    (and (let ((c (car condition)))
           (if (class-p c)
               (cl-typep section c)
             (if-let ((class (cdr (assq c magit2--section-type-alist))))
                 (cl-typep section class)
               (eq (oref section type) c))))
         (or (not (setq condition (cdr condition)))
             (when-let ((parent (oref section parent)))
               (magit2-section-match-2 condition parent))))))

(defun magit2-section-value-if (condition &optional section)
  "If the section at point matches CONDITION, then return its value.

If optional SECTION is non-nil then test whether that matches
instead.  If there is no section at point and SECTION is nil,
then return nil.  If the section does not match, then return
nil.

See `magit2-section-match' for the forms CONDITION can take."
  (when-let ((section (or section (magit2-current-section))))
    (and (magit2-section-match condition section)
         (oref section value))))

(defmacro magit2-section-when (condition &rest body)
  "If the section at point matches CONDITION, evaluate BODY.

If the section matches, then evaluate BODY forms sequentially
with `it' bound to the section and return the value of the last
form.  If there are no BODY forms, then return the value of the
section.  If the section does not match or if there is no section
at point, then return nil.

See `magit2-section-match' for the forms CONDITION can take."
  (declare (obsolete
            "instead use `magit2-section-match' or `magit2-section-value-if'."
            "Magit 2.90.0")
           (indent 1)
           (debug (sexp body)))
  `(--when-let (magit2-current-section)
     ;; Quoting CONDITION here often leads to double-quotes, which
     ;; isn't an issue because `magit2-section-match-1' implicitly
     ;; deals with that.  We shouldn't force users of this function
     ;; to not quote CONDITION because that would needlessly break
     ;; backward compatibility.
     (when (magit2-section-match ',condition it)
       ,@(or body '((oref it value))))))

(defmacro magit2-section-case (&rest clauses)
  "Choose among clauses on the type of the section at point.

Each clause looks like (CONDITION BODY...).  The type of the
section is compared against each CONDITION; the BODY forms of the
first match are evaluated sequentially and the value of the last
form is returned.  Inside BODY the symbol `it' is bound to the
section at point.  If no clause succeeds or if there is no
section at point, return nil.

See `magit2-section-match' for the forms CONDITION can take.
Additionally a CONDITION of t is allowed in the final clause, and
matches if no other CONDITION match, even if there is no section
at point."
  (declare (indent 0)
           (debug (&rest (sexp body))))
  `(let* ((it (magit2-current-section)))
     (cond ,@(mapcar (lambda (clause)
                       `(,(or (eq (car clause) t)
                              `(and it
                                    (magit2-section-match-1 ',(car clause) it)))
                         ,@(cdr clause)))
                     clauses))))

(defun magit2-section-match-assoc (section alist)
  "Return the value associated with SECTION's type or lineage in ALIST."
  (seq-some (pcase-lambda (`(,key . ,val))
              (and (magit2-section-match-1 key section) val))
            alist))

;;; Create

(defvar magit2-insert-section-hook nil
  "Hook run after `magit2-insert-section's BODY.
Avoid using this hook and only ever do so if you know
what you are doing and are sure there is no other way.")

(defmacro magit2-insert-section (&rest args)
  "Insert a section at point.

Create a section object of type CLASS, storing VALUE in its
`value' slot, and insert the section at point.  CLASS is a
subclass of `magit2-section' or has the form `(eval FORM)', in
which case FORM is evaluated at runtime and should return a
subclass.  In other places a sections class is oftern referred
to as its \"type\".

Many commands behave differently depending on the class of the
current section and sections of a certain class can have their
own keymap, which is specified using the `keymap' class slot.
The value of that slot should be a variable whose value is a
keymap.

For historic reasons Magit and Forge in most cases use symbols
as CLASS that don't actually identify a class and that lack the
appropriate package prefix.  This works due to some undocumented
kludges, which are not available to other packages.

When optional HIDE is non-nil collapse the section body by
default, i.e. when first creating the section, but not when
refreshing the buffer.  Else expand it by default.  This can be
overwritten using `magit2-section-set-visibility-hook'.  When a
section is recreated during a refresh, then the visibility of
predecessor is inherited and HIDE is ignored (but the hook is
still honored).

BODY is any number of forms that actually insert the section's
heading and body.  Optional NAME, if specified, has to be a
symbol, which is then bound to the object of the section being
inserted.

Before BODY is evaluated the `start' of the section object is set
to the value of `point' and after BODY was evaluated its `end' is
set to the new value of `point'; BODY is responsible for moving
`point' forward.

If it turns out inside BODY that the section is empty, then
`magit2-cancel-section' can be used to abort and remove all traces
of the partially inserted section.  This can happen when creating
a section by washing Git's output and Git didn't actually output
anything this time around.

\(fn [NAME] (CLASS &optional VALUE HIDE) &rest BODY)"
  (declare (indent defun)
           (debug ([&optional symbolp]
                   (&or [("eval" form) &optional form form]
                        [symbolp &optional form form])
                   body)))
  (let ((tp (cl-gensym "type"))
        (s* (and (symbolp (car args))
                 (pop args)))
        (s  (cl-gensym "section")))
    `(let* ((,tp ,(let ((type (nth 0 (car args))))
                    (if (eq (car-safe type) 'eval)
                        (cadr type)
                      `',type)))
            (,s (funcall (if (class-p ,tp)
                             ,tp
                           (or (cdr (assq ,tp magit2--section-type-alist))
                               'magit2-section))
                         :type
                         (or (and (class-p ,tp)
                                  (car (rassq ,tp magit2--section-type-alist)))
                             ,tp)
                         :value ,(nth 1 (car args))
                         :start (point-marker)
                         :parent magit2-insert-section--parent)))
       (oset ,s hidden
             (let ((value (run-hook-with-args-until-success
                           'magit2-section-set-visibility-hook ,s)))
               (if value
                   (eq value 'hide)
                 (let ((incarnation (and magit2-insert-section--oldroot
                                         (magit2-get-section
                                          (magit2-section-ident ,s)
                                          magit2-insert-section--oldroot))))
                   (if incarnation
                       (oref incarnation hidden)
                     (let ((value (magit2-section-match-assoc
                                   ,s magit2-section-initial-visibility-alist)))
                       (if value
                           (progn
                             (when (functionp value)
                               (setq value (funcall value ,s)))
                             (eq value 'hide))
                         ,(nth 2 (car args)))))))))
       (let ((magit2-insert-section--current ,s)
             (magit2-insert-section--parent  ,s)
             (magit2-insert-section--oldroot
              (or magit2-insert-section--oldroot
                  (unless magit2-insert-section--parent
                    (prog1 magit2-root-section
                      (setq magit2-root-section ,s))))))
         (catch 'cancel-section
           ,@(if s*
                 `((let ((,s* ,s))
                     ,@(cdr args)))
               (cdr args))
           ;; `magit2-insert-section-hook' should *not* be run with
           ;; `magit2-run-section-hook' because it's a hook that runs
           ;; on section insertion, not a section inserting hook.
           (run-hooks 'magit2-insert-section-hook)
           (magit2-insert-child-count ,s)
           (set-marker-insertion-type (oref ,s start) t)
           (let* ((end (oset ,s end (point-marker)))
                  (class-map (oref-default ,s keymap))
                  (magit2-map (intern (format "magit2-%s-section-map"
                                             (oref ,s type))))
                  (forge-map (intern (format "forge-%s-section-map"
                                             (oref ,s type))))
                  (map (or (and         class-map  (symbol-value class-map))
                           (and (boundp magit2-map) (symbol-value magit2-map))
                           (and (boundp forge-map) (symbol-value forge-map)))))
             (save-excursion
               (goto-char (oref ,s start))
               (while (< (point) end)
                 (let ((next (or (next-single-property-change
                                  (point) 'magit2-section)
                                 end)))
                   (unless (get-text-property (point) 'magit2-section)
                     (put-text-property (point) next 'magit2-section ,s)
                     (when map
                       (put-text-property (point) next 'keymap map)))
                   (goto-char next)))))
           (if (eq ,s magit2-root-section)
               (let ((magit2-section-cache-visibility nil))
                 (magit2-section-show ,s))
             (oset (oref ,s parent) children
                   (nconc (oref (oref ,s parent) children)
                          (list ,s)))))
         ,s))))

(defun magit2-cancel-section ()
  "Cancel inserting the section that is currently being inserted.
Remove all traces of that section."
  (when magit2-insert-section--current
    (if (not (oref magit2-insert-section--current parent))
        (insert "(empty)\n")
      (delete-region (oref magit2-insert-section--current start)
                     (point))
      (setq magit2-insert-section--current nil)
      (throw 'cancel-section nil))))

(defun magit2-insert-heading (&rest args)
  "Insert the heading for the section currently being inserted.

This function should only be used inside `magit2-insert-section'.

When called without any arguments, then just set the `content'
slot of the object representing the section being inserted to
a marker at `point'.  The section should only contain a single
line when this function is used like this.

When called with arguments ARGS, which have to be strings, or
nil, then insert those strings at point.  The section should not
contain any text before this happens and afterwards it should
again only contain a single line.  If the `face' property is set
anywhere inside any of these strings, then insert all of them
unchanged.  Otherwise use the `magit2-section-heading' face for
all inserted text.

The `content' property of the section object is the end of the
heading (which lasts from `start' to `content') and the beginning
of the the body (which lasts from `content' to `end').  If the
value of `content' is nil, then the section has no heading and
its body cannot be collapsed.  If a section does have a heading,
then its height must be exactly one line, including a trailing
newline character.  This isn't enforced, you are responsible for
getting it right.  The only exception is that this function does
insert a newline character if necessary."
  (declare (indent defun))
  (when args
    (let ((heading (apply #'concat args)))
      (insert (if (or (text-property-not-all 0 (length heading)
                                             'font-lock-face nil heading)
                      (text-property-not-all 0 (length heading)
                                             'face nil heading))
                  heading
                (propertize heading 'font-lock-face 'magit2-section-heading)))))
  (unless (bolp)
    (insert ?\n))
  (when (fboundp 'magit2-maybe-make-margin-overlay)
    (magit2-maybe-make-margin-overlay))
  (oset magit2-insert-section--current content (point-marker)))

(defmacro magit2-insert-section-body (&rest body)
  "Use BODY to insert the section body, once the section is expanded.
If the section is expanded when it is created, then this is
like `progn'.  Otherwise BODY isn't evaluated until the section
is explicitly expanded."
  (declare (indent 0))
  (let ((f (cl-gensym))
        (s (cl-gensym)))
    `(let ((,f (lambda () ,@body))
           (,s magit2-insert-section--current))
       (if (oref ,s hidden)
           (oset ,s washer
                 (lambda ()
                   (funcall ,f)
                   (magit2-section-maybe-remove-visibility-indicator ,s)))
         (funcall ,f)))))

(defun magit2-insert-headers (hook)
  (let* ((header-sections nil)
         (magit2-insert-section-hook
          (cons (lambda ()
                  (push magit2-insert-section--current
                        header-sections))
                (if (listp magit2-insert-section-hook)
                    magit2-insert-section-hook
                  (list magit2-insert-section-hook)))))
    (magit2-run-section-hook hook)
    (when header-sections
      (insert "\n")
      ;; Make the first header into the parent of the rest.
      (when (cdr header-sections)
        (cl-callf nreverse header-sections)
        (let* ((1st-header (pop header-sections))
               (header-parent (oref 1st-header parent)))
          (oset header-parent children (list 1st-header))
          (oset 1st-header children header-sections)
          (oset 1st-header content (oref (car header-sections) start))
          (oset 1st-header end (oref (car (last header-sections)) end))
          (dolist (sub-header header-sections)
            (oset sub-header parent 1st-header)))))))

(defun magit2-insert-child-count (section)
  "Modify SECTION's heading to contain number of child sections.

If `magit2-section-show-child-count' is non-nil and the SECTION
has children and its heading ends with \":\", then replace that
with \" (N)\", where N is the number of child sections.

This function is called by `magit2-insert-section' after that has
evaluated its BODY.  Admittedly that's a bit of a hack."
  ;; This has to be fast, not pretty!
  (let (content count)
    (when (and magit2-section-show-child-count
               (setq count (length (oref section children)))
               (> count 0)
               (setq content (oref section content))
               (eq (char-before (1- content)) ?:))
      (save-excursion
        (goto-char (- content 2))
        (insert (concat (magit2--propertize-face " " 'magit2-section-heading)
                        (magit2--propertize-face (format "(%s)" count)
                                                'magit2-section-child-count)))
        (delete-char 1)))))

;;; Highlight

(defvar-local magit2-section-pre-command-region-p nil)
(defvar-local magit2-section-pre-command-section nil)
(defvar-local magit2-section-highlight-force-update nil)
(defvar-local magit2-section-highlight-overlays nil)
(defvar-local magit2-section-highlighted-sections nil)
(defvar-local magit2-section-unhighlight-sections nil)

(defun magit2-section-pre-command-hook ()
  (setq magit2-section-pre-command-region-p (region-active-p))
  (setq magit2-section-pre-command-section (magit2-current-section)))

(defun magit2-section-post-command-hook ()
  (unless (memq this-command '(magit2-refresh magit2-refresh-all))
    (magit2-section-update-highlight)))

(defun magit2-section-deactivate-mark ()
  (setq magit2-section-highlight-force-update t))

(defun magit2-section-update-highlight (&optional force)
  (let ((section (magit2-current-section)))
    (when (or force
              magit2-section-highlight-force-update
              (cond ; `xor' wasn't added until 27.1.
               ((not magit2-section-pre-command-region-p) (region-active-p))
               ((not (region-active-p)) magit2-section-pre-command-region-p))
              (not (eq magit2-section-pre-command-section section)))
      (let ((inhibit-read-only t)
            (deactivate-mark nil)
            (selection (magit2-region-sections)))
        (mapc #'delete-overlay magit2-section-highlight-overlays)
        (setq magit2-section-highlight-overlays nil)
        (setq magit2-section-unhighlight-sections
              magit2-section-highlighted-sections)
        (setq magit2-section-highlighted-sections nil)
        (unless (eq section magit2-root-section)
          (run-hook-with-args-until-success
           'magit2-section-highlight-hook section selection))
        (dolist (s magit2-section-unhighlight-sections)
          (run-hook-with-args-until-success
           'magit2-section-unhighlight-hook s selection))
        (restore-buffer-modified-p nil)))
    (setq magit2-section-highlight-force-update nil)
    (magit2-section-maybe-paint-visibility-ellipses)))

(defun magit2-section-highlight (section selection)
  "Highlight SECTION and if non-nil all sections in SELECTION.
This function works for any section but produces undesirable
effects for diff related sections, which by default are
highlighted using `magit2-diff-highlight'.  Return t."
  (when-let ((face (oref section heading-highlight-face)))
    (dolist (section (or selection (list section)))
      (magit2-section-make-overlay
       (oref section start)
       (or (oref section content)
           (oref section end))
       face)))
  (cond (selection
         (magit2-section-make-overlay (oref (car selection) start)
                                     (oref (car (last selection)) end)
                                     'magit2-section-highlight)
         (magit2-section-highlight-selection nil selection))
        (t
         (magit2-section-make-overlay (oref section start)
                                     (oref section end)
                                     'magit2-section-highlight)))
  t)

(defun magit2-section-highlight-selection (_ selection)
  "Highlight the section-selection region.
If SELECTION is non-nil, then it is a list of sections selected by
the region.  The headings of these sections are then highlighted.

This is a fallback for people who don't want to highlight the
current section and therefore removed `magit2-section-highlight'
from `magit2-section-highlight-hook'.

This function is necessary to ensure that a representation of
such a region is visible.  If neither of these functions were
part of the hook variable, then such a region would be
invisible."
  (when (and selection
             (not (and (eq this-command 'mouse-drag-region))))
    (dolist (section selection)
      (magit2-section-make-overlay (oref section start)
                                  (or (oref section content)
                                      (oref section end))
                                  'magit2-section-heading-selection))
    t))

(defun magit2-section-make-overlay (start end face)
  ;; Yes, this doesn't belong here.  But the alternative of
  ;; spreading this hack across the code base is even worse.
  (when (and magit2-section-keep-region-overlay
             (memq face '(magit2-section-heading-selection
                          magit2-diff-file-heading-selection
                          magit2-diff-hunk-heading-selection)))
    (setq face (list :foreground (face-foreground face))))
  (let ((ov (make-overlay start end nil t)))
    (overlay-put ov 'font-lock-face face)
    (overlay-put ov 'evaporate t)
    (push ov magit2-section-highlight-overlays)
    ov))

(defun magit2-section-goto-successor (section line char arg)
  (let ((ident (magit2-section-ident section)))
    (--if-let (magit2-get-section ident)
        (let ((start (oref it start)))
          (goto-char start)
          (unless (eq it magit2-root-section)
            (ignore-errors
              (forward-line line)
              (forward-char char))
            (unless (eq (magit2-current-section) it)
              (goto-char start))))
      (or (run-hook-with-args-until-success
           'magit2-section-goto-successor-hook section arg)
          (goto-char (--if-let (magit2-section-goto-successor-1 section)
                         (if (eq (oref it type) 'button)
                             (point-min)
                           (oref it start))
                       (point-min)))))))

(defun magit2-section-goto-successor-1 (section)
  (or (--when-let (pcase (oref section type)
                    (`staged 'unstaged)
                    (`unstaged 'staged)
                    (`unpushed 'unpulled)
                    (`unpulled 'unpushed))
        (magit2-get-section `((,it) (status))))
      (--when-let (car (magit2-section-siblings section 'next))
        (magit2-get-section (magit2-section-ident it)))
      (--when-let (car (magit2-section-siblings section 'prev))
        (magit2-get-section (magit2-section-ident it)))
      (--when-let (oref section parent)
        (or (magit2-get-section (magit2-section-ident it))
            (magit2-section-goto-successor-1 it)))))

;;; Region

(defvar-local magit2-section--region-overlays nil)

(defun magit2-section--delete-region-overlays ()
  (mapc #'delete-overlay magit2-section--region-overlays)
  (setq magit2-section--region-overlays nil))

(defun magit2-section--highlight-region (start end window rol)
  (magit2-section--delete-region-overlays)
  (if (and (not magit2-section-keep-region-overlay)
           (or (magit2-region-sections)
               (run-hook-with-args-until-success 'magit2-region-highlight-hook
                                                 (magit2-current-section)))
           (not (= (line-number-at-pos start)
                   (line-number-at-pos end)))
           ;; (not (eq (car-safe last-command-event) 'mouse-movement))
           )
      (funcall (default-value 'redisplay-unhighlight-region-function) rol)
    (funcall (default-value 'redisplay-highlight-region-function)
             start end window rol)))

(defun magit2-section--unhighlight-region (rol)
  (magit2-section--delete-region-overlays)
  (funcall (default-value 'redisplay-unhighlight-region-function) rol))

;;; Visibility

(defvar-local magit2-section-visibility-cache nil)
(put 'magit2-section-visibility-cache 'permanent-local t)

(defun magit2-section-cached-visibility (section)
  "Set SECTION's visibility to the cached value."
  (cdr (assoc (magit2-section-ident section)
              magit2-section-visibility-cache)))

(cl-defun magit2-section-cache-visibility
    (&optional (section magit2-insert-section--current))
  ;; Emacs 25's `alist-get' lacks TESTFN.
  (let* ((id  (magit2-section-ident section))
         (elt (assoc id magit2-section-visibility-cache))
         (val (if (oref section hidden) 'hide 'show)))
    (if elt
        (setcdr elt val)
      (push (cons id val) magit2-section-visibility-cache))))

(cl-defun magit2-section-maybe-cache-visibility
    (&optional (section magit2-insert-section--current))
  (when (or (eq magit2-section-cache-visibility t)
            (memq (oref section type)
                  magit2-section-cache-visibility))
    (magit2-section-cache-visibility section)))

(defun magit2-section-maybe-update-visibility-indicator (section)
  (when magit2-section-visibility-indicator
    (let ((beg (oref section start))
          (cnt (oref section content))
          (end (oref section end)))
      (when (and cnt (or (not (= cnt end)) (oref section washer)))
        (let ((eoh (save-excursion
                     (goto-char beg)
                     (line-end-position))))
          (cond
           ((symbolp (car-safe magit2-section-visibility-indicator))
            ;; It would make more sense to put the overlay only on the
            ;; location we actually don't put it on, but then inserting
            ;; before that location (while taking care not to mess with
            ;; the overlay) would cause the fringe bitmap to disappear
            ;; (but not other effects of the overlay).
            (let ((ov (magit2--overlay-at (1+ beg) 'magit2-vis-indicator 'fringe)))
              (unless ov
                (setq ov (make-overlay (1+ beg) eoh))
                (overlay-put ov 'evaporate t)
                (overlay-put ov 'magit2-vis-indicator 'fringe))
              (overlay-put
               ov 'before-string
               (propertize "fringe" 'display
                           (list 'left-fringe
                                 (if (oref section hidden)
                                     (car magit2-section-visibility-indicator)
                                   (cdr magit2-section-visibility-indicator))
                                 'fringe)))))
           ((stringp (car-safe magit2-section-visibility-indicator))
            (let ((ov (magit2--overlay-at (1- eoh) 'magit2-vis-indicator 'eoh)))
              (cond ((oref section hidden)
                     (unless ov
                       (setq ov (make-overlay (1- eoh) eoh))
                       (overlay-put ov 'evaporate t)
                       (overlay-put ov 'magit2-vis-indicator 'eoh))
                     (overlay-put ov 'after-string
                                  (car magit2-section-visibility-indicator)))
                    (ov
                     (delete-overlay ov)))))))))))

(defvar-local magit2--ellipses-sections nil)

(defun magit2-section-maybe-paint-visibility-ellipses ()
  ;; This is needed because we hide the body instead of "the body
  ;; except the final newline and additionally the newline before
  ;; the body"; otherwise we could use `buffer-invisibility-spec'.
  (when (stringp (car-safe magit2-section-visibility-indicator))
    (let* ((sections (append magit2--ellipses-sections
                             (setq magit2--ellipses-sections
                                   (or (magit2-region-sections)
                                       (list (magit2-current-section))))))
           (beg (--map (oref it start) sections))
           (end (--map (oref it end)   sections)))
      (when (region-active-p)
        ;; This ensures that the region face is removed from ellipses
        ;; when the region becomes inactive, but fails to ensure that
        ;; all ellipses within the active region use the region face,
        ;; because the respective overlay has not yet been updated at
        ;; this time.  The magit2-selection face is always applied.
        (push (region-beginning) beg)
        (push (region-end)       end))
      (setq beg (apply #'min beg))
      (setq end (apply #'max end))
      (dolist (ov (overlays-in beg end))
        (when (eq (overlay-get ov 'magit2-vis-indicator) 'eoh)
          (overlay-put
           ov 'after-string
           (propertize
            (car magit2-section-visibility-indicator) 'font-lock-face
            (let ((pos (overlay-start ov)))
              (delq nil (nconc (--map (overlay-get it 'font-lock-face)
                                      (overlays-at pos))
                               (list (get-char-property
                                      pos 'font-lock-face))))))))))))

(defun magit2-section-maybe-remove-visibility-indicator (section)
  (when (and magit2-section-visibility-indicator
             (= (oref section content)
                (oref section end)))
    (dolist (o (overlays-in (oref section start)
                            (save-excursion
                              (goto-char (oref section start))
                              (1+ (line-end-position)))))
      (when (overlay-get o 'magit2-vis-indicator)
        (delete-overlay o)))))

(defvar-local magit2-section--opened-sections nil)

(defun magit2-section--open-temporarily (beg end)
  (save-excursion
    (goto-char beg)
    (let ((section (magit2-current-section)))
      (while section
        (let ((content (oref section content)))
          (if (and (magit2-section-invisible-p section)
                   (<= (or content (oref section start))
                       beg
                       (oref section end)))
              (progn
                (when content
                  (magit2-section-show section)
                  (push section magit2-section--opened-sections))
                (setq section (oref section parent)))
            (setq section nil))))))
  (or (eq search-invisible t)
      (not (isearch-range-invisible beg end))))

(defun isearch-clean-overlays@magit2-mode (fn)
  (if (derived-mode-p 'magit2-mode)
      (let ((pos (point)))
        (dolist (section magit2-section--opened-sections)
          (unless (<= (oref section content) pos (oref section end))
            (magit2-section-hide section)))
        (setq magit2-section--opened-sections nil))
    (funcall fn)))

(advice-add 'isearch-clean-overlays :around
            'isearch-clean-overlays@magit2-mode)

;;; Utilities

(cl-defun magit2-section-selected-p (section &optional (selection nil sselection))
  (and (not (eq section magit2-root-section))
       (or  (eq section (magit2-current-section))
            (memq section (if sselection
                              selection
                            (setq selection (magit2-region-sections))))
            (--when-let (oref section parent)
              (magit2-section-selected-p it selection)))))

(defun magit2-section-parent-value (section)
  (when-let ((parent (oref section parent)))
    (oref parent value)))

(defun magit2-section-siblings (section &optional direction)
  "Return a list of the sibling sections of SECTION.

If optional DIRECTION is `prev', then return siblings that come
before SECTION.  If it is `next', then return siblings that come
after SECTION.  For all other values, return all siblings
excluding SECTION itself."
  (when-let ((parent (oref section parent)))
    (let ((siblings (oref parent children)))
      (pcase direction
        (`prev  (cdr (member section (reverse siblings))))
        (`next  (cdr (member section siblings)))
        (_      (remq section siblings))))))

(defun magit2-region-values (&optional condition multiple)
  "Return a list of the values of the selected sections.

Return the values that themselves would be returned by
`magit2-region-sections' (which see)."
  (--map (oref it value)
         (magit2-region-sections condition multiple)))

(defun magit2-region-sections (&optional condition multiple)
  "Return a list of the selected sections.

When the region is active and constitutes a valid section
selection, then return a list of all selected sections.  This is
the case when the region begins in the heading of a section and
ends in the heading of the same section or in that of a sibling
section.  If optional MULTIPLE is non-nil, then the region cannot
begin and end in the same section.

When the selection is not valid, then return nil.  In this case,
most commands that can act on the selected sections will instead
act on the section at point.

When the region looks like it would in any other buffer then
the selection is invalid.  When the selection is valid then the
region uses the `magit2-section-highlight' face.  This does not
apply to diffs where things get a bit more complicated, but even
here if the region looks like it usually does, then that's not
a valid selection as far as this function is concerned.

If optional CONDITION is non-nil, then the selection not only
has to be valid; all selected sections additionally have to match
CONDITION, or nil is returned.  See `magit2-section-match' for the
forms CONDITION can take."
  (when (region-active-p)
    (let* ((rbeg (region-beginning))
           (rend (region-end))
           (sbeg (get-text-property rbeg 'magit2-section))
           (send (get-text-property rend 'magit2-section)))
      (when (and send
                 (not (eq send magit2-root-section))
                 (not (and multiple (eq send sbeg))))
        (let ((siblings (cons sbeg (magit2-section-siblings sbeg 'next)))
              sections)
          (when (and (memq send siblings)
                     (magit2-section-position-in-heading-p sbeg rbeg)
                     (magit2-section-position-in-heading-p send rend))
            (while siblings
              (push (car siblings) sections)
              (when (eq (pop siblings) send)
                (setq siblings nil)))
            (setq sections (nreverse sections))
            (when (or (not condition)
                      (--all-p (magit2-section-match condition it) sections))
              sections)))))))

(defun magit2-section-position-in-heading-p (&optional section pos)
  "Return t if POSITION is inside the heading of SECTION.
POSITION defaults to point and SECTION defaults to the
current section."
  (unless section
    (setq section (magit2-current-section)))
  (unless pos
    (setq pos (point)))
  (and section
       (>= pos (oref section start))
       (<  pos (or (oref section content)
                   (oref section end)))
       t))

(defun magit2-section-internal-region-p (&optional section)
  "Return t if the region is active and inside SECTION's body.
If optional SECTION is nil, use the current section."
  (and (region-active-p)
       (or section (setq section (magit2-current-section)))
       (let ((beg (get-text-property (region-beginning) 'magit2-section)))
         (and (eq beg (get-text-property   (region-end) 'magit2-section))
              (eq beg section)))
       (not (or (magit2-section-position-in-heading-p section (region-beginning))
                (magit2-section-position-in-heading-p section (region-end))))
       t))

(defun magit2-wash-sequence (function)
  "Repeatedly call FUNCTION until it returns nil or eob is reached.
FUNCTION has to move point forward or return nil."
  (while (and (not (eobp)) (funcall function))))

(defun magit2-add-section-hook (hook function &optional at append local)
  "Add to the value of section hook HOOK the function FUNCTION.

Add FUNCTION at the beginning of the hook list unless optional
APPEND is non-nil, in which case FUNCTION is added at the end.
If FUNCTION already is a member, then move it to the new location.

If optional AT is non-nil and a member of the hook list, then
add FUNCTION next to that instead.  Add before or after AT, or
replace AT with FUNCTION depending on APPEND.  If APPEND is the
symbol `replace', then replace AT with FUNCTION.  For any other
non-nil value place FUNCTION right after AT.  If nil, then place
FUNCTION right before AT.  If FUNCTION already is a member of the
list but AT is not, then leave FUNCTION where ever it already is.

If optional LOCAL is non-nil, then modify the hook's buffer-local
value rather than its global value.  This makes the hook local by
copying the default value.  That copy is then modified.

HOOK should be a symbol.  If HOOK is void, it is first set to nil.
HOOK's value must not be a single hook function.  FUNCTION should
be a function that takes no arguments and inserts one or multiple
sections at point, moving point forward.  FUNCTION may choose not
to insert its section(s), when doing so would not make sense.  It
should not be abused for other side-effects.  To remove FUNCTION
again use `remove-hook'."
  (unless (boundp hook)
    (error "Cannot add function to undefined hook variable %s" hook))
  (unless (default-boundp hook)
    (set-default hook nil))
  (let ((value (if local
                   (if (local-variable-p hook)
                       (symbol-value hook)
                     (unless (local-variable-if-set-p hook)
                       (make-local-variable hook))
                     (copy-sequence (default-value hook)))
                 (default-value hook))))
    (if at
        (when (setq at (member at value))
          (setq value (delq function value))
          (cond ((eq append 'replace)
                 (setcar at function))
                (append
                 (push function (cdr at)))
                (t
                 (push (car at) (cdr at))
                 (setcar at function))))
      (setq value (delq function value)))
    (unless (member function value)
      (setq value (if append
                      (append value (list function))
                    (cons function value))))
    (when (eq append 'replace)
      (setq value (delq at value)))
    (if local
        (set hook value)
      (set-default hook value))))

(defvar-local magit2-disabled-section-inserters nil)

(defun magit2-disable-section-inserter (fn)
  "Disable the section inserter FN in the current repository.
It is only intended for use in \".dir-locals.el\" and
\".dir-locals-2.el\".  Also see info node `(magit2)Per-Repository
Configuration'."
  (cl-pushnew fn magit2-disabled-section-inserters))

(put 'magit2-disable-section-inserter 'safe-local-eval-function t)

(defun magit2-run-section-hook (hook &rest args)
  "Run HOOK with ARGS, warning about invalid entries."
  (let ((entries (symbol-value hook)))
    (unless (listp entries)
      (setq entries (list entries)))
    (--when-let (-remove #'functionp entries)
      (message "`%s' contains entries that are no longer valid.
%s\nUsing standard value instead.  Please re-configure hook variable."
               hook
               (mapconcat (lambda (sym) (format "  `%s'" sym)) it "\n"))
      (sit-for 5)
      (setq entries (eval (car (get hook 'standard-value)))))
    (dolist (entry entries)
      (let ((magit2--current-section-hook (cons (list hook entry)
                                               magit2--current-section-hook)))
        (unless (memq entry magit2-disabled-section-inserters)
          (if (bound-and-true-p magit2-refresh-verbose)
              (let ((time (benchmark-elapse (apply entry args))))
                (message "  %-50s %s %s" entry time
                         (cond ((> time 0.03) "!!")
                               ((> time 0.01) "!")
                               (t ""))))
            (apply entry args)))))))

(cl-defun magit2--overlay-at (pos prop &optional (val nil sval) testfn)
  (cl-find-if (lambda (o)
                (let ((p (overlay-properties o)))
                  (and (plist-member p prop)
                       (or (not sval)
                           (funcall (or testfn #'eql)
                                    (plist-get p prop)
                                    val)))))
              (overlays-at pos t)))

(defun magit2-face-property-all (face string)
  "Return non-nil if FACE is present in all of STRING."
  (catch 'missing
    (let ((pos 0))
      (while (setq pos (next-single-property-change pos 'font-lock-face string))
        (let ((val (get-text-property pos 'font-lock-face string)))
          (unless (if (consp val)
                      (memq face val)
                    (eq face val))
            (throw 'missing nil))))
      (not pos))))

(defun magit2--add-face-text-property (beg end face &optional append object)
  "Like `add-face-text-property' but for `font-lock-face'."
  (while (< beg end)
    (let* ((pos (next-single-property-change beg 'font-lock-face object end))
           (val (get-text-property beg 'font-lock-face object))
           (val (if (listp val) val (list val))))
      (put-text-property beg pos 'font-lock-face
                         (if append
                             (append val (list face))
                           (cons face val))
                         object)
      (setq beg pos))))

(defun magit2--propertize-face (string face)
  (propertize string 'face face 'font-lock-face face))

(defun magit2--put-face (beg end face string)
  (put-text-property beg end 'face face string)
  (put-text-property beg end 'font-lock-face face string))

;;; Bitmaps

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'magit2-fringe-bitmap+
    [#b00000000
     #b00011000
     #b00011000
     #b01111110
     #b01111110
     #b00011000
     #b00011000
     #b00000000])
  (define-fringe-bitmap 'magit2-fringe-bitmap-
    [#b00000000
     #b00000000
     #b00000000
     #b01111110
     #b01111110
     #b00000000
     #b00000000
     #b00000000])

  (define-fringe-bitmap 'magit2-fringe-bitmap>
    [#b01100000
     #b00110000
     #b00011000
     #b00001100
     #b00011000
     #b00110000
     #b01100000
     #b00000000])
  (define-fringe-bitmap 'magit2-fringe-bitmapv
    [#b00000000
     #b10000010
     #b11000110
     #b01101100
     #b00111000
     #b00010000
     #b00000000
     #b00000000])

  (define-fringe-bitmap 'magit2-fringe-bitmap-bold>
    [#b11100000
     #b01110000
     #b00111000
     #b00011100
     #b00011100
     #b00111000
     #b01110000
     #b11100000])
  (define-fringe-bitmap 'magit2-fringe-bitmap-boldv
    [#b10000001
     #b11000011
     #b11100111
     #b01111110
     #b00111100
     #b00011000
     #b00000000
     #b00000000])
  )

;;; _
(provide 'magit2-section)
;;; magit2-section.el ends here
