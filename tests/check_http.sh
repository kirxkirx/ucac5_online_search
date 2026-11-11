#!/usr/bin/env bash
#
# Check a running UCAC5 online search service over HTTP, the way VaST uses it.
#
# Usage: tests/check_http.sh [URL]
#        tests/check_http.sh --fixture [URL]
#
# URL defaults to http://localhost/cgi-bin/ucac5/search_ucac5.py
# Any server can be checked, for example
#   tests/check_http.sh http://scan.sai.msu.ru/cgi-bin/ucac5/search_ucac5.py
#
# The same 635 positions as in tests/test_real_catalog.sh are uploaded with the
# curl options VaST uses, and the reply is compared with the known answer.
# With --fixture the service is expected to run on the synthetic catalog of
# tests/make_test_catalog.py instead of the real one (this is what the CI does).
#
# Besides the comparison, the script prints what the service says about its
# version, so running it against several servers shows whether they are in sync.

# Refuse to run if invoked as CGI
if [ -n "${GATEWAY_INTERFACE:-}" ] || [ -n "${REQUEST_METHOD:-}" ]; then
 printf 'Content-Type: text/plain\n\nERROR: this script must not be run as CGI\n'
 exit 1
fi

LC_ALL=C
LANGUAGE=C
export LANGUAGE LC_ALL

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
DATA="$TESTS_DIR/data"

POSITIONS="$DATA/taurus_positions.txt"
EXPECTED="$DATA/taurus_expected.txt"
BRIGHT_MAG=2.000000
FAINT_MAG=13.500000
SEARCH_RADIUS_ARCSEC=23.350000
if [ "${1:-}" = "--fixture" ]; then
 shift
 POSITIONS="$DATA/fixture_main_positions.txt"
 EXPECTED="$DATA/fixture_main_expected.txt"
 BRIGHT_MAG=0.000000
 FAINT_MAG=14.000000
 SEARCH_RADIUS_ARCSEC=5.000000
fi
case "${1:-}" in
-*)
 echo "Usage: $0 [--fixture] [URL]" >&2
 exit 1
 ;;
esac
URL="${1:-http://localhost/cgi-bin/ucac5/search_ucac5.py}"

REPLY="$(mktemp "${TMPDIR:-/tmp}/ucac5_reply_XXXXXX")" || exit 1
CURL_ERRORS="$(mktemp "${TMPDIR:-/tmp}/ucac5_curl_XXXXXX")" || exit 1
trap 'rm -f "$REPLY" "$CURL_ERRORS"' EXIT

echo "Checking $URL"

# 1. A plain GET: a current server answers with its version. The servers that
# predate this repository answer a GET with an error page or a broken response,
# which is not a failure of this check: the search below decides.
HTTP_CODE="$(curl --silent --show-error --insecure --connect-timeout 10 --max-time 60 --output "$REPLY" --write-out '%{http_code}' "$URL" 2> "$CURL_ERRORS")"
if [ "$HTTP_CODE" = "000" ]; then
 echo "ERROR: cannot connect: $(cat "$CURL_ERRORS")" >&2
 exit 1
fi
if [ "$HTTP_CODE" = "200" ] && head -n 1 "$REPLY" | grep -q '^# UCAC5 online search '; then
 echo "Version reported: $(head -n 1 "$REPLY" | cut -c3-)"
elif head -n 1 "$REPLY" | grep -q '^# ERROR: '; then
 echo "The service answers, but reports an error (HTTP $HTTP_CODE): $(head -n 1 "$REPLY" | cut -c3-)"
 echo "The reason is in the web server's error log."
else
 case "$HTTP_CODE" in
 403 | 404)
  echo "HTTP $HTTP_CODE on GET: the request does not reach search_ucac5.py."
  echo "A freshly installed service: see \"If the web server answers 403 or 404\" in README.md"
  ;;
 *)
  echo "No version reported (HTTP $HTTP_CODE on GET): the server runs the code that predates this"
  echo "repository, or search_ucac5.py cannot start (the reason is in the web server's error log)"
  ;;
 esac
fi

# 2. A search, with the options VaST gives to curl
if ! HTTP_CODE="$(curl --silent --show-error --insecure --connect-timeout 10 --retry 1 --max-time 600 \
 -F file=@"$POSITIONS" -F submit="Upload Image" \
 -F brightmag="$BRIGHT_MAG" -F faintmag="$FAINT_MAG" -F searcharcsec="$SEARCH_RADIUS_ARCSEC" \
 --output "$REPLY" --write-out '%{http_code}' "$URL")"; then
 echo "ERROR: the search request failed" >&2
 exit 1
fi
N_LINES="$(wc -l < "$REPLY")"
echo "Search reply: HTTP $HTTP_CODE, $N_LINES lines"
if [ "$HTTP_CODE" != "200" ]; then
 echo "ERROR: the search was refused:" >&2
 head -n 5 "$REPLY" >&2
 exit 1
fi

# Servers that predate this repository glue "Starting program ... <br>" to the first match
if grep -q '^Starting program .* <br>' "$REPLY"; then
 echo "The reply has the old \"Starting program ... <br>\" prefix (VaST loses the first match because of it)"
 sed -i.bak 's/^Starting program .* <br>//' "$REPLY" && rm -f "$REPLY.bak"
fi

if ! python3 "$TESTS_DIR/compare_matches.py" "$EXPECTED" "$REPLY"; then
 echo "ERROR: the reply differs from the expected one" >&2
 exit 1
fi
echo "OK"
