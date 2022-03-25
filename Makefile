-include config.mk
include default.mk

## ###################################################################

.PHONY: lisp docs \
	install install-lisp install-docs install-info \
	test test-interactive magit2 \
	clean clean-lisp clean-docs clean-archives \
	stats \
	dist versionlib $(PKG)-$(VERSION).tar.gz

all: lisp docs

help:
	$(info )
	$(info See default.mk for variables you might want to set.)
	$(info )
	$(info Build)
	$(info =====)
	$(info )
	$(info make [all]            - compile elisp and documentation)
	$(info make lisp             - compile elisp)
	$(info make docs             - generate info manuals)
	$(info make info             - generate info manuals)
	$(info make html             - generate html manual files)
	$(info make html-dir         - generate html manual directories)
	$(info make pdf              - generate pdf manuals)
	$(info make epub             - generate epub manuals)
	$(info )
	$(info Install)
	$(info =======)
	$(info )
	$(info make install          - install elisp and documentation)
	$(info make install-lisp     - install elisp)
	$(info make install-docs     - install all documentation)
	$(info make install-info     - install info manuals only)
	$(info )
	$(info Clean)
	$(info ====)
	$(info )
	$(info make clean            - clean elisp, documentation and tarball)
	$(info make clean-lisp       - clean elisp)
	$(info make clean-docs       - clean docs)
	$(info make clean-archives   - clean release tarball)
	$(info make clean-all        - clean everything except tracked texi)
	$(info make clean-stats      - clean stats)
	$(info )
	$(info Test)
	$(info ====)
	$(info )
	$(info make test             - run tests)
	$(info make test-interactive - run tests interactively)
	$(info make emacs-Q          - run emacs -Q plus Magit)
	$(info )
	$(info Release Management)
	$(info ==================)
	$(info )
	$(info make texi             - regenerate texi from org)
	$(info make authors          - regenerate AUTHORS.md)
	$(info make publish          - publish snapshot manuals)
	$(info make release          - publish release manuals)
	$(info make dist             - create tarballs)
	@printf "\n"

## Build #############################################################

lisp:
	@$(MAKE) -C lisp lisp

docs:
	@$(MAKE) -C docs all

info:
	@$(MAKE) -C docs info

html:
	@$(MAKE) -C docs html

html-dir:
	@$(MAKE) -C docs html-dir

pdf:
	@$(MAKE) -C docs pdf

epub:
	@$(MAKE) -C docs epub

## Install ###########################################################

install: install-lisp install-docs

install-lisp: lisp
	@$(MAKE) -C lisp install

install-docs: docs
	@$(MAKE) -C docs install-docs

install-info: info
	@$(MAKE) -C docs install-info

## Test ##############################################################

test:
	@$(MAKE) -C test test

test-interactive:
	@$(MAKE) -C test test-interactive

## Clean #############################################################

clean: clean-lisp clean-docs clean-archives
	@printf "Cleaning...\n"
	@$(RM) *.elc $(ELGS) # temporary cleanup kludge
	@$(RM) docs/*.texi~ docs/*.info-1 docs/*.info-2
	@$(RM) magit2-pkg.el t/magit2-tests.elc

clean-lisp:
	@$(MAKE) -C lisp clean

clean-docs:
	@$(MAKE) -C docs clean

clean-archives:
	@$(RM) *.tar.gz *.tar lisp/magit2-version.el
	@$(RMDIR) $(PKG)-$(VERSION)

clean-all: clean clean-stats

clean-stats:
	@$(MAKE) -C docs clean-stats

## Release management ################################################

texi:
	@$(MAKE) -C docs texi

authors:
	@$(MAKE) -C docs authors
	@git commit --gpg-sign -m "AUTHORS.md: Update list of contributors" \
	-o -- docs/AUTHORS.md
	@git show --pretty= -p HEAD

publish:
	@$(MAKE) -C docs publish

release:
	@$(MAKE) -C docs release

versionlib:
	@$(MAKE) -C lisp versionlib
