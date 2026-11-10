# UCAC5 online search
#
#   make               build bin/search_ucac5
#   make test          offline tests with a tiny synthetic catalog (no UCAC5 needed)
#   make test-catalog  search the real catalog behind the "catalog" symlink
#   make check         both of the above
#   make verify-catalog  compare all 900 zone files with their known checksums
#   make clean
#
# The version reported by the service is the git commit of this checkout.
# Run make as the owner of the checkout: git refuses to describe a repository
# owned by somebody else, and the version then reads "unknown".

CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
VERSION := $(shell git describe --always --dirty 2>/dev/null || echo unknown)

all: bin/search_ucac5

# Always rebuilt, so that the compiled-in version follows the checkout.
# Built under a temporary name and renamed: the service never sees a missing
# or half-written binary, and a failed build leaves the old one in place.
bin/search_ucac5: src/search_ucac5.c FORCE
	mkdir -p bin
	$(CC) $(CFLAGS) -DUCAC5_SEARCH_VERSION='"$(VERSION)"' -o bin/search_ucac5.new src/search_ucac5.c -lm
	mv -f bin/search_ucac5.new bin/search_ucac5

test: all
	tests/test_offline.sh

test-catalog: all
	tests/test_real_catalog.sh

check: test test-catalog

# Reads all 5.6 GB of the catalog
verify-catalog:
	cd catalog/ && md5sum -c --quiet "$(CURDIR)/tests/data/ucac5_zones.md5"
	@echo "All 900 zone files are intact"

clean:
	rm -rf bin

FORCE:

.PHONY: all test test-catalog check verify-catalog clean FORCE
