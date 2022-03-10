TOP := $(dir $(lastword $(MAKEFILE_LIST)))

## User options ######################################################
#
# You can override these settings in "config.mk" or on the command
# line.
#
# You might also want to set LOAD_PATH.  If you do, then it must
# contain "-L .".
#
# If you don't do so, then the default is set in the "Load-Path"
# section below.  The default assumes that all dependencies are
# installed either at "../<DEPENDENCY>", or when using package.el
# at "ELPA_DIR/<DEPENDENCY>-<HIGHEST-VERSION>".

PREFIX   ?= /usr/local
sharedir ?= $(PREFIX)/share
lispdir  ?= $(sharedir)/emacs/site-lisp/magit
infodir  ?= $(sharedir)/info
docdir   ?= $(sharedir)/doc/magit

CP       ?= install -p -m 644
MKDIR    ?= install -p -m 755 -d
RMDIR    ?= rm -rf
TAR      ?= tar
SED      ?= sed

CASK     ?= $(shell which cask)
CASK     := cd $(TOP) ; EMACS=$(EMACS) $(CASK)
EMACS    ?= emacs
EMACSBIN := $(EMACS)
LOAD_PATH = -L $(TOP)
BATCH     = EMACSLOADPATH=$(EMACSLOADPATH) $(EMACS) -Q --batch $(LOAD_PATH)

INSTALL_INFO     ?= $(shell command -v ginstall-info || printf install-info)
MAKEINFO         ?= makeinfo
MANUAL_HTML_ARGS ?= --css-ref /assets/page.css

GITSTATS      ?= gitstats
GITSTATS_DIR  ?= $(TOP)docs/stats
GITSTATS_ARGS ?= -c style=https://magit.vc/assets/stats.css -c max_authors=999

## Files #############################################################

PKG       = magit

TEXIPAGES = $(addsuffix .texi,$(PKG))
INFOPAGES = $(addsuffix .info,$(PKG))
HTMLFILES = $(addsuffix .html,$(PKG))
HTMLDIRS  = $(PKG)
PDFFILES  = $(addsuffix .pdf,$(PKG))
EPUBFILES = $(addsuffix .epub,$(PKG))

ELGS = magit-autoloads.el magit-version.el

## Versions ##########################################################

VERSION ?= $(shell \
  test -e $(TOP).git && \
  git describe --tags --abbrev=0 --always | cut -c2-)
TIMESTAMP = 20211004

DASH_VERSION          = 2.19.1
GIT_COMMIT_VERSION    = $(VERSION)
LIBGIT2_VERSION       = 0
MAGIT_VERSION         = $(VERSION)
MAGIT_SECTION_VERSION = $(VERSION)
TRANSIENT_VERSION     = 0.3.6
WITH_EDITOR_VERSION   = 3.0.5
EMACS_VERSION	      = 25.1

EMACSOLD := $(shell $(BATCH) --eval \
  "(and (version< emacs-version \"$(EMACS_VERSION)\") (princ \"true\"))")
ifeq "$(EMACSOLD)" "true"
  $(error At least version $(EMACS_VERSION) of Emacs is required)
endif

## Publish ###########################################################

DOMAIN      ?= magit.vc
CFRONT_DIST ?= E2LUHBKU1FBV02

PUBLISH_TARGETS ?= html html-dir pdf

DOCBOOK_XSL ?= /usr/share/xml/docbook/stylesheet/docbook-xsl/epub/docbook.xsl

EPUBTRASH = epub.xml META-INF OEBPS
