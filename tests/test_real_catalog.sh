#!/usr/bin/env bash
#
# Test an installation against the real UCAC5 catalog: 635 positions of a field
# in Taurus are sent through the CGI script (without a web server) and the
# reply is compared with the known answer of 607 matches. Takes about a second.
#
# Usage: tests/test_real_catalog.sh [ROOT_DIR]
#
# ROOT_DIR is the installed directory tree to test (the one holding bin/,
# cgi-bin/ and the "catalog" symlink); the default is the tree this script is in.
# The updater uses the argument to test a new version before switching to it.

# Refuse to run if invoked as CGI
if [ -n "${GATEWAY_INTERFACE:-}" ] || [ -n "${REQUEST_METHOD:-}" ]; then
 printf 'Content-Type: text/plain\n\nERROR: this script must not be run as CGI\n'
 exit 1
fi

LC_ALL=C
LANGUAGE=C
export LANGUAGE LC_ALL

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
ROOT_DIR="${1:-$(dirname "$TESTS_DIR")}"
DATA="$TESTS_DIR/data"

if [ ! -d "$ROOT_DIR/catalog/" ]; then
 echo "ERROR: $ROOT_DIR/catalog is not found. Make it a symlink to the directory with the UCAC5 zone files:
 ln -s /path/to/UCAC5 $ROOT_DIR/catalog" >&2
 exit 1
fi
if [ ! -x "$ROOT_DIR/bin/search_ucac5" ]; then
 echo "ERROR: $ROOT_DIR/bin/search_ucac5 is not found - run make first" >&2
 exit 1
fi

# The catalog is 900 zone files, 107758513 records of 52 bytes
# (the names of interest are z001 ... z900, nothing exotic for ls)
# shellcheck disable=SC2012
CATALOG_SUMMARY="$(ls -lnL "$ROOT_DIR/catalog/" | awk '$NF ~ /^z[0-9][0-9][0-9]$/ { n++; bytes += $5 } END { printf "%d files, %.0f bytes", n, bytes }')"
if [ "$CATALOG_SUMMARY" != "900 files, 5603442676 bytes" ]; then
 echo "ERROR: $ROOT_DIR/catalog holds $CATALOG_SUMMARY in zone files; the complete catalog is 900 files (z001 ... z900), 5603442676 bytes.
\"make verify-catalog\" tells which files are missing or damaged." >&2
 exit 1
fi

REPLY="$(mktemp "${TMPDIR:-/tmp}/ucac5_reply_XXXXXX")" || exit 1
trap 'rm -f "$REPLY"' EXIT

if ! python3 "$TESTS_DIR/cgi_request.py" "$ROOT_DIR/cgi-bin/ucac5/search_ucac5.py" \
 --file "$DATA/taurus_positions.txt" --field 'submit=Upload Image' \
 --field brightmag=2.000000 --field faintmag=13.500000 --field searcharcsec=23.350000 > "$REPLY"; then
 echo "ERROR: the CGI script failed" >&2
 exit 1
fi

if ! tr -d '\r' < "$REPLY" | grep -q '^Status: 200'; then
 echo "ERROR: the search was refused:" >&2
 head -n 5 "$REPLY" >&2
 exit 1
fi

# The comparison ignores the response header: its lines are not nine columns of numbers
if ! tr -d '\r' < "$REPLY" | grep '^[0-9]' | python3 "$TESTS_DIR/compare_matches.py" "$DATA/taurus_expected.txt" -; then
 echo "ERROR: the reply differs from the expected one" >&2
 exit 1
fi

echo "The search of the real catalog works ($(tr -d '\r' < "$REPLY" | grep '^# UCAC5 online search' | cut -c3-))"
