-include ../config.mk
include ../default.mk
include ../cask.mk

.DEFAULT_GOAL := test
test: cask
	@printf "Testing...\n"
	@$(BATCH) --eval "(progn\
	$$suppress_warnings\
	(load-file \"$(TOP)test/magit-tests.el\")\
	(ert-run-tests-batch-and-exit))"

test-interactive: cask
	@EMACSLOADPATH=$(EMACSLOADPATH) $(EMACSBIN) -Q $(LOAD_PATH)\
	--eval "(progn\
	(load-file \"$(TOP)test/magit-tests.el\")\
	(ert t))"
