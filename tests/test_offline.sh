#!/usr/bin/env bash
#
# Offline tests of the UCAC5 online search: the search program and the CGI
# script are run against a tiny synthetic catalog (tests/make_test_catalog.py),
# so neither the real catalog nor a web server is needed.
#
# Usage: tests/test_offline.sh        (after "make"; "make test" does both)
#
# The CGI script locates the search program and the catalog relative to its
# own place in the directory tree, so the tests assemble a private copy of
# that tree in a temporary directory with the synthetic catalog in it.

# Refuse to run if invoked as CGI
if [ -n "${GATEWAY_INTERFACE:-}" ] || [ -n "${REQUEST_METHOD:-}" ]; then
 printf 'Content-Type: text/plain\n\nERROR: this script must not be run as CGI\n'
 exit 1
fi

LC_ALL=C
LANGUAGE=C
export LANGUAGE LC_ALL

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
ROOT_DIR="$(dirname "$TESTS_DIR")"
DATA="$TESTS_DIR/data"

if [ ! -x "$ROOT_DIR/bin/search_ucac5" ]; then
 echo "ERROR: $ROOT_DIR/bin/search_ucac5 is not found - run make first" >&2
 exit 1
fi

# The scratch directory is made next to the search program when possible: the
# tests run programs from it, which a separately mounted /tmp may not allow.
if [ -w "$ROOT_DIR/bin" ]; then
 WORK="$(mktemp -d "$ROOT_DIR/bin/test_XXXXXX")" || exit 1
else
 WORK="$(mktemp -d "${TMPDIR:-/tmp}/ucac5_test_XXXXXX")" || exit 1
fi
trap 'rm -rf "$WORK"' EXIT

TREE="$WORK/tree"
mkdir -p "$TREE/cgi-bin/ucac5" "$TREE/bin" "$WORK/catalog" || exit 1
cp "$ROOT_DIR/cgi-bin/ucac5/search_ucac5.py" "$TREE/cgi-bin/ucac5/" || exit 1
cp "$ROOT_DIR/bin/search_ucac5" "$TREE/bin/" || exit 1
python3 "$TESTS_DIR/make_test_catalog.py" "$WORK/catalog" || exit 1
ln -s "$WORK/catalog" "$TREE/catalog" || exit 1

PROGRAM="$TREE/bin/search_ucac5"
CGI="$TREE/cgi-bin/ucac5/search_ucac5.py"

N_PASSED=0
N_FAILED=0

pass() {
 N_PASSED=$((N_PASSED + 1))
 echo "ok      $1"
}

fail() {
 N_FAILED=$((N_FAILED + 1))
 echo "FAILED  $1"
}

# check NAME COMMAND... : the test passes if the command succeeds
check() {
 local name="$1"
 shift
 if "$@" > "$WORK/check.log" 2>&1; then
  pass "$name"
 else
  fail "$name"
  sed 's/^/        /' "$WORK/check.log"
 fi
}

# cgi OUTPUT_PREFIX ARGUMENTS... : one simulated request; the response goes to
# OUTPUT_PREFIX.head (the header) and OUTPUT_PREFIX.body, the exit code to OUTPUT_PREFIX.rc
cgi() {
 local prefix="$1"
 shift
 python3 "$TESTS_DIR/cgi_request.py" "$CGI" "$@" > "$prefix.raw" 2> "$prefix.err"
 echo $? > "$prefix.rc"
 tr -d '\r' < "$prefix.raw" | awk -v head="$prefix.head" -v body="$prefix.body" '
  BEGIN { in_body = 0; printf "" > head; printf "" > body }
  in_body { print > body; next }
  /^$/ { in_body = 1; next }
  { print > head }'
}

# The reply to a request that cannot be served: the given status, a text/plain
# body of exactly one line that starts with "# ERROR", and a clean exit.
is_error_reply() {
 local prefix="$1" status="$2"
 grep -q "^Status: $status" "$prefix.head" || { echo "expected status $status, got: $(head -n 1 "$prefix.head")"; return 1; }
 grep -q '^Content-Type: text/plain' "$prefix.head" || { echo "no text/plain content type"; return 1; }
 [ "$(wc -l < "$prefix.body")" -eq 1 ] || { echo "the body should be one line:"; cat "$prefix.body"; return 1; }
 grep -q '^# ERROR: ' "$prefix.body" || { echo "the body should start with '# ERROR: ':"; cat "$prefix.body"; return 1; }
 [ "$(cat "$prefix.rc")" -eq 0 ] || { echo "exit code $(cat "$prefix.rc")"; cat "$prefix.err"; return 1; }
}

is_search_reply() {
 local prefix="$1" expected="$2"
 grep -q '^Status: 200' "$prefix.head" || { echo "expected status 200, got: $(head -n 1 "$prefix.head")"; cat "$prefix.body" "$prefix.err"; return 1; }
 grep -q '^Content-Type: text/plain' "$prefix.head" || { echo "no text/plain content type"; return 1; }
 [ "$(head -n 1 "$prefix.body" | cut -c1-22)" = "# UCAC5 online search " ] || { echo "the first line should carry the version:"; head -n 1 "$prefix.body"; return 1; }
 [ "$(grep -c '^#' "$prefix.body")" -eq 1 ] || { echo "exactly one comment line expected"; return 1; }
 # every data line starts with a digit: the oldest VaST clients skip anything else
 if grep -v '^#' "$prefix.body" | grep -q -v '^[0-9]'; then echo "a data line does not start with a digit"; return 1; fi
 python3 "$TESTS_DIR/compare_matches.py" "$expected" "$prefix.body"
}

echo "=== the search program ==="

version_is_one_comment_line() {
 "$PROGRAM" --version > "$WORK/version.out" || return 1
 [ "$(wc -l < "$WORK/version.out")" -eq 1 ] && grep -q '^# UCAC5 online search [^ ]' "$WORK/version.out"
}
check "--version prints one comment line" version_is_one_comment_line

program_matches() {
 local positions="$1" expected="$2"
 shift 2
 "$PROGRAM" "$WORK/catalog" "$@" < "$DATA/$positions" > "$WORK/program.out" 2> "$WORK/program.err" || { cat "$WORK/program.err"; return 1; }
 python3 "$TESTS_DIR/compare_matches.py" "$DATA/$expected" "$WORK/program.out"
}
check "brightest star within the radius, magnitude limit, two zones" program_matches fixture_main_positions.txt fixture_main_expected.txt 0 14 5
check "wider search radius" program_matches fixture_main_positions.txt fixture_wide_expected.txt 0 14 60
check "field across RA = 0/360" program_matches fixture_wrap_positions.txt fixture_wrap_expected.txt 0 16 5

garbage_input_gives_no_matches() {
 printf 'this is not\na list of positions\n1e999 nan\n500 500\n' | "$PROGRAM" "$WORK/catalog" 0 16 5 > "$WORK/garbage.out" 2> /dev/null || return 1
 [ "$(wc -l < "$WORK/garbage.out")" -eq 1 ] && grep -q '^#' "$WORK/garbage.out"
}
check "garbage input: no matches, no failure" garbage_input_gives_no_matches

missing_catalog_is_an_error() {
 "$PROGRAM" "$WORK/no_such_catalog" 0 16 5 < "$DATA/fixture_main_positions.txt" > "$WORK/nocat.out" 2> /dev/null
 [ $? -eq 1 ] && [ ! -s "$WORK/nocat.out" ]
}
check "missing catalog: exit code 1 and no output" missing_catalog_is_an_error

bad_arguments_are_an_error() {
 "$PROGRAM" "$WORK/catalog" 0 sixteen 5 < "$DATA/fixture_main_positions.txt" > "$WORK/badarg.out" 2> /dev/null
 [ $? -eq 1 ] && [ ! -s "$WORK/badarg.out" ]
}
check "non-numeric argument: exit code 1 and no output" bad_arguments_are_an_error

unreadable_zone_is_an_error() {
 # a directory in place of a zone file can be opened but not read, like a file on a failing disk
 mkdir -p "$WORK/broken_catalog/z501" || return 1
 : > "$WORK/broken_catalog/z001"
 "$PROGRAM" "$WORK/broken_catalog" 0 16 5 < "$DATA/fixture_main_positions.txt" > "$WORK/broken.out" 2> /dev/null
 [ $? -eq 2 ] && [ ! -s "$WORK/broken.out" ]
}
check "read error on a zone file: exit code 2 and no output" unreadable_zone_is_an_error

echo "=== the CGI script ==="

# The web server reaches this directory: anything else in it could be started by its URL
served_directory_holds_only_the_cgi_script() {
 local entries
 entries="$(find "$ROOT_DIR/cgi-bin/ucac5" -mindepth 1 -maxdepth 1 | sed 's#.*/##' | sort | tr '\n' ' ')"
 [ "$entries" = "search_ucac5.py " ] || { echo "cgi-bin/ucac5 holds: $entries"; return 1; }
}
check "cgi-bin/ucac5 holds nothing but search_ucac5.py" served_directory_holds_only_the_cgi_script


cgi "$WORK/post" --file "$DATA/fixture_main_positions.txt" --field 'submit=Upload Image' --field brightmag=0.000000 --field faintmag=14.000000 --field searcharcsec=5.000000
check "search request as VaST sends it" is_search_reply "$WORK/post" "$DATA/fixture_main_expected.txt"

cgi "$WORK/wrap" --file "$DATA/fixture_wrap_positions.txt" --field brightmag=0 --field faintmag=16 --field searcharcsec=5
check "search request, field across RA = 0/360" is_search_reply "$WORK/wrap" "$DATA/fixture_wrap_expected.txt"

cgi "$WORK/clamp" --file "$DATA/fixture_main_positions.txt" --field brightmag=-5 --field faintmag=14 --field searcharcsec=1000
check "search radius is limited to 60 arcsec" is_search_reply "$WORK/clamp" "$DATA/fixture_wide_expected.txt"

printf '150.000000 10.050000\r\n150.500000 10.100000\r\n151.000000 10.250000\r\n151.500000 10.350000\r\n' > "$WORK/crlf_positions.txt"
cgi "$WORK/crlf" --file "$WORK/crlf_positions.txt" --field brightmag=0 --field faintmag=14 --field searcharcsec=5
check "upload with DOS line endings" is_search_reply "$WORK/crlf" "$DATA/fixture_main_expected.txt"

defaults_are_applied() {
 # without the three numbers the search runs with 0, 16 and 10 arcsec: the 15 mag star near input 3 is found
 grep -q '^Status: 200' "$WORK/defaults.head" && [ "$(grep -c '^[0-9]' "$WORK/defaults.body")" -eq 4 ] && grep -q '^151.000000 10.250000 [0-9.]* 151.000100 10.250100 15.000000 ' "$WORK/defaults.body"
}
cgi "$WORK/defaults" --file "$DATA/fixture_main_positions.txt"
check "default search parameters" defaults_are_applied

get_reports_the_version() {
 grep -q '^Status: 200' "$WORK/get.head" && [ "$(wc -l < "$WORK/get.body")" -lt 5 ] && [ "$(head -n 1 "$WORK/get.body")" = "$("$PROGRAM" --version)" ] && [ "$(grep -c -v '^#' "$WORK/get.body")" -eq 0 ]
}
cgi "$WORK/get"
check "GET reports the installed version in fewer than 5 lines" get_reports_the_version

cgi "$WORK/nofile" --field brightmag=0 --field faintmag=14 --field searcharcsec=5
check "no file in the form: 400" is_error_reply "$WORK/nofile" 400

cgi "$WORK/badnumber" --file "$DATA/fixture_main_positions.txt" --field brightmag=bright --field faintmag=14 --field searcharcsec=5
check "non-numeric parameter: 400" is_error_reply "$WORK/badnumber" 400

cgi "$WORK/nan" --file "$DATA/fixture_main_positions.txt" --field brightmag=0 --field faintmag=nan --field searcharcsec=5
check "not-a-number parameter: 400" is_error_reply "$WORK/nan" 400

printf '150.000000 10.050000\n\000\001\002\n' > "$WORK/binary_positions.txt"
cgi "$WORK/binary" --file "$WORK/binary_positions.txt" --field brightmag=0 --field faintmag=14 --field searcharcsec=5
check "binary upload: 400" is_error_reply "$WORK/binary" 400

cgi "$WORK/toolarge" --file "$DATA/fixture_main_positions.txt" --content-length 99999999
check "oversized request: 413" is_error_reply "$WORK/toolarge" 413

cgi "$WORK/nolength" --file "$DATA/fixture_main_positions.txt" --content-length ''
check "no Content-Length: 411" is_error_reply "$WORK/nolength" 411

cgi "$WORK/notmultipart" --file "$DATA/fixture_main_positions.txt" --content-type 'application/x-www-form-urlencoded'
check "not a multipart form: 400" is_error_reply "$WORK/notmultipart" 400

cgi "$WORK/put" --method PUT
check "unsupported method: 405" is_error_reply "$WORK/put" 405

rm "$TREE/catalog"
cgi "$WORK/nocatalog" --file "$DATA/fixture_main_positions.txt" --field brightmag=0 --field faintmag=14 --field searcharcsec=5
check "catalog symlink missing: 500 in one line" is_error_reply "$WORK/nocatalog" 500

mkdir "$WORK/empty_catalog"
ln -s "$WORK/empty_catalog" "$TREE/catalog"
cgi "$WORK/emptycatalog" --file "$DATA/fixture_main_positions.txt" --field brightmag=0 --field faintmag=14 --field searcharcsec=5
check "catalog directory without zone files: 500 in one line" is_error_reply "$WORK/emptycatalog" 500

rm "$TREE/bin/search_ucac5"
cgi "$WORK/noprogram" --file "$DATA/fixture_main_positions.txt" --field brightmag=0 --field faintmag=14 --field searcharcsec=5
check "search program missing: 500 in one line" is_error_reply "$WORK/noprogram" 500
cgi "$WORK/noprogramget"
check "search program missing, GET: 500 in one line" is_error_reply "$WORK/noprogramget" 500

echo "=== $N_PASSED passed, $N_FAILED failed ==="
[ "$N_FAILED" -eq 0 ]
