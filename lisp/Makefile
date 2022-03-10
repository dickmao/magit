-include ../config.mk
include ../default.mk
include ../cask.mk

## ###################################################################

.DEFAULT_GOAL := all
all: lisp

.PHONY: compile
compile: cask
	! ($(CASK) eval "(let ((byte-compile-error-on-warn t)) (cask-cli/build))" 2>&1 \
	   | egrep -a "(Warning|Error):") ; \
	(ret=$$? ; $(CASK) clean-elc && exit $$ret)

.PHONY: lisp
lisp: compile autoloads $(LISP_EXTRA_TARGETS)

.PHONY: versionlib
versionlib: $(PKG)-version.el

.PHONY: autoloads
autoloads:
	@printf "Generating $(PKG)-autoloads.el\n"
	@printf "%s" "$$LOADDEFS_TMPL" > $(PKG)-autoloads.el
	@$(BATCH) --eval "(progn\
	(fset 'message (lambda (&rest _)))\
	(setq make-backup-files nil)\
	(setq vc-handled-backends nil)\
	(setq default-directory (file-truename default-directory))\
	(setq generated-autoload-file (expand-file-name \"$(PKG)-autoloads.el\"))\
	(setq find-file-visit-truename t)\
	(update-directory-autoloads default-directory))"

.PHONY: $(PKG)-version.el
$(PKG)-version.el:
	@printf "Generating $@\n"
	@printf "%s" "$$VERSIONLIB_TMPL" > $@

.PHONY: check-declare
check-declare:
	@printf "Checking function declarations\n"
	@$(BATCH) -L $(TOP)../borg -L $(TOP)../forge/lisp \
	--eval "(check-declare-directory default-directory)"

## Install ###########################################################

.PHONY: dist
dist: lisp versionlib
	$(CASK) package

.PHONY: install
install: dist
	$(EMACS) -Q --batch --eval "(package-initialize)" \
	  --eval "(package-install-file \"dist/$(PKG)-$(shell $(CASK) version).tar\")"

## Clean #############################################################

clean:
	@printf "Cleaning lisp/*...\n"
	@$(RM) *.elc $(ELGS)

## Templates #########################################################

define LOADDEFS_TMPL
;;; $(PKG)-autoloads.el --- automatically extracted autoloads
;;
;;; Code:
(add-to-list 'load-path (directory-file-name \
(or (file-name-directory #$$) (car load-path))))

;; Local Variables:
;; version-control: never
;; no-byte-compile: t
;; no-update-autoloads: t
;; End:
;;; $(PKG)-autoloads.el ends here

endef
export LOADDEFS_TMPL
#'

define VERSIONLIB_TMPL
;;; $(PKG)-version.el --- the Magit version you are using

(setq $(PKG)-version "$(VERSION)")

(provide '$(PKG)-version)

;; Local Variables:
;; version-control: never
;; no-byte-compile: t
;; no-update-autoloads: t
;; coding: utf-8
;; End:
;;; $(PKG)-version.el ends here

endef
export VERSIONLIB_TMPL
#'

define suppress_warnings
(fset 'original-message (symbol-function 'message))
(fset 'message ;'
      (lambda (f &rest a)
        (unless (or (equal f "Wrote %s")
                    (equal f "pcase-memoize: equal first branch, yet different")
                    (and (equal f "Warning: Unknown defun property `%S' in %S")
                         (memq (car a) '(pure side-effect-free interactive-only))))
          (apply 'original-message f a))))
endef
export suppress_warnings
