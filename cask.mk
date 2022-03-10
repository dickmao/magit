define SET_EMACSLOADPATH =
EMACSLOADPATH := $(shell $(CASK) load-path)
endef

CASK_DIR := $(shell $(CASK) package-directory)
$(CASK_DIR): $(TOP)Cask $(TOP)lisp/magit-pkg.el
	$(CASK) install
	touch $(CASK_DIR)

.PHONY: cask
cask: $(CASK_DIR)
	$(eval $(call SET_EMACSLOADPATH))
