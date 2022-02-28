define SET_EMACSLOADPATH =
EMACSLOADPATH := $(shell cd $(TOP) ; $(CASK) load-path)
endef

ifneq ($(CASK),)
CASK_DIR  = $(shell cd $(TOP) ; EMACS=$(EMACS) $(CASK) package-directory)
$(CASK_DIR): $(TOP)Cask
	cd $(TOP) ; $(CASK) install
	touch $(CASK_DIR)
endif

.PHONY: cask
cask: $(CASK_DIR)
ifneq ($(CASK),)
	$(eval $(call SET_EMACSLOADPATH))
endif
