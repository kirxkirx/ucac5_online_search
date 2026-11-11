#!/usr/bin/env bash
#
# Update this installation of the UCAC5 online search to the latest version
# published on GitHub - but only to a version that passed its tests there and
# passes them again on this host. For cron and for manual use; this script is
# the one way to update an installation (a bare "git pull" skips every check
# and does not rebuild the search program).
#
# Usage: ./git_ucac5_automated_update.sh [--force] [--verbose]
#
#   --force    do not ask GitHub whether the tests of the new version passed.
#              The version is still built and tested on this host first.
#   --verbose  also report when there is nothing to do (the default when the
#              script is run from a terminal).
#
# The steps:
#   1. fetch the default branch from origin; stop if nothing is new;
#   2. ask GitHub whether all the check runs (GitHub Actions) of the new commit
#      have finished successfully;
#   3. export the new commit into a scratch directory, build it there and run
#      the offline tests and, if this host has the catalog, the search of the
#      real catalog. The running service is not touched until all of it passes;
#   4. fast-forward the checkout to that commit, rebuild, test once more;
#      on any failure return to the previous commit and rebuild it.
#
# VaST takes any reply of five or more lines for search results and then does
# not try another server, so a broken installation is worse than a stopped
# one: hence the tests before the switch.
#
# Local changes to tracked files are discarded when an update is applied
# (they are listed first): an installation tracks the repository only, and
# everything host-specific lives in the untracked "catalog" symlink.
#
# Exit code 0: updated, or nothing to do (also: tests on GitHub still running,
# or the new version has already failed here - wait for the next one).
# Exit code 1: an error worth looking at.

# Refuse to run if invoked as CGI
if [ -n "${GATEWAY_INTERFACE:-}" ] || [ -n "${REQUEST_METHOD:-}" ]; then
 printf 'Content-Type: text/plain\n\nERROR: this script must not be run as CGI\n'
 exit 1
fi

# Everything is inside main() so that bash reads the whole file before running
# any of it: the update replaces this very file.
main() {

 LC_ALL=C
 LANGUAGE=C
 export LANGUAGE LC_ALL

 # The web server may run as another user: everything written here must stay readable
 umask 022

 local FORCE=0
 local VERBOSE=0
 if [ -t 1 ]; then
  VERBOSE=1
 fi
 local ARGUMENT
 for ARGUMENT in "$@"; do
  case "$ARGUMENT" in
  --force) FORCE=1 ;;
  --verbose) VERBOSE=1 ;;
  *)
   echo "Usage: $0 [--force] [--verbose]" >&2
   return 1
   ;;
  esac
 done

 local COMMAND
 for COMMAND in git make tar python3; do
  if ! command -v "$COMMAND" > /dev/null 2>&1; then
   echo "ERROR: required command '$COMMAND' is not found" >&2
   return 1
  fi
 done
 if ! command -v curl > /dev/null 2>&1 && ! command -v wget > /dev/null 2>&1; then
  echo "ERROR: neither curl nor wget is found" >&2
  return 1
 fi

 ROOT_DIR="$(cd "$(dirname "$0")" && pwd)" || return 1
 cd "$ROOT_DIR" || return 1
 if [ ! -d .git ]; then
  echo "ERROR: $ROOT_DIR is not a git checkout" >&2
  return 1
 fi
 # git refuses to work in a checkout that belongs to somebody else ("dubious
 # ownership"). Checked before anything is written, so that a run by the wrong
 # user (root, say) leaves no file behind that the owner cannot replace.
 if ! git rev-parse --verify --quiet HEAD > /dev/null 2>&1; then
  echo "ERROR: git cannot use the checkout $ROOT_DIR - run this script as its owner ($(stat -c %U "$ROOT_DIR/.git" 2> /dev/null)), not as $(id -un)" >&2
  return 1
 fi

 # One update at a time. The lock lives in the checkout, not in a shared
 # temporary directory, and is released when this process ends.
 exec 9>> "$ROOT_DIR/.git/ucac5_automated_update.lock" || return 1
 if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2> /dev/null; then
  note "Another update is running"
  return 0
 fi

 local BRANCH
 BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null | sed 's@^origin/@@')"
 if [ -z "$BRANCH" ]; then
  if git show-ref --verify --quiet refs/remotes/origin/main; then
   BRANCH="main"
  elif git show-ref --verify --quiet refs/remotes/origin/master; then
   BRANCH="master"
  else
   echo "ERROR: cannot determine the default branch of origin" >&2
   return 1
  fi
 fi

 local OLD_COMMIT NEW_COMMIT
 OLD_COMMIT="$(git rev-parse --verify --quiet HEAD)"
 if [ -z "$OLD_COMMIT" ]; then
  echo "ERROR: cannot determine the current commit (run this script as the owner of $ROOT_DIR)" >&2
  return 1
 fi

 if ! with_timeout 600 git fetch --quiet origin "$BRANCH"; then
  echo "ERROR: git fetch failed" >&2
  return 1
 fi
 NEW_COMMIT="$(git rev-parse --verify --quiet "refs/remotes/origin/$BRANCH")"
 if [ -z "$NEW_COMMIT" ]; then
  echo "ERROR: cannot determine the latest commit of origin/$BRANCH" >&2
  return 1
 fi

 if [ "$OLD_COMMIT" = "$NEW_COMMIT" ]; then
  note "Already up to date ($(git describe --always "$OLD_COMMIT"))"
  return 0
 fi
 if ! git merge-base --is-ancestor "$OLD_COMMIT" "$NEW_COMMIT"; then
  echo "ERROR: origin/$BRANCH ($NEW_COMMIT) does not descend from the installed commit ($OLD_COMMIT): not updating" >&2
  return 1
 fi

 local OLD_VERSION NEW_VERSION
 OLD_VERSION="$(git describe --always "$OLD_COMMIT")"
 NEW_VERSION="$(git describe --always "$NEW_COMMIT")"

 # A version that failed its tests on this host is not tried again every day
 local FAILED_COMMIT_FILE="$ROOT_DIR/.git/ucac5_automated_update.failed"
 if [ "$FORCE" -eq 0 ] && [ -f "$FAILED_COMMIT_FILE" ] && [ "$(cat "$FAILED_COMMIT_FILE")" = "$NEW_COMMIT" ]; then
  note "Version $NEW_VERSION has failed its tests on this host before - waiting for a newer one (--force to retry)"
  return 0
 fi

 echo "New version available: $NEW_VERSION (installed: $OLD_VERSION)"

 if [ "$FORCE" -eq 1 ]; then
  echo "WARNING: --force given, not asking GitHub whether the tests of $NEW_VERSION passed"
 else
  local CI_STATE
  CI_STATE="$(github_tests_state "$NEW_COMMIT")"
  case "$CI_STATE" in
  passed*)
   echo "GitHub: $CI_STATE"
   ;;
  pending*)
   echo "GitHub: $CI_STATE - will look again at the next run"
   return 0
   ;;
  *)
   echo "ERROR: not updating to $NEW_VERSION - GitHub: $CI_STATE" >&2
   return 1
   ;;
  esac
 fi

 # Build and test the new version next to the running one. The scratch
 # directory is inside .git: on the same filesystem as the checkout (a
 # separate /tmp may not allow running programs) and invisible to git.
 STAGE_DIR="$ROOT_DIR/.git/ucac5_automated_update.stage"
 local LOG_FILE="$ROOT_DIR/.git/ucac5_automated_update.log"
 rm -rf "$STAGE_DIR"
 trap 'rm -rf "$STAGE_DIR"' EXIT
 mkdir "$STAGE_DIR" || return 1
 if ! git archive "$NEW_COMMIT" | tar -x -C "$STAGE_DIR"; then
  echo "ERROR: cannot export $NEW_VERSION" >&2
  return 1
 fi
 local HAVE_CATALOG=0
 if [ -d "$ROOT_DIR/catalog/" ]; then
  HAVE_CATALOG=1
  ln -s "$(cd "$ROOT_DIR/catalog/" && pwd -P)" "$STAGE_DIR/catalog" || return 1
 else
  echo "WARNING: $ROOT_DIR/catalog is not found - the new version is tested without the real catalog"
 fi

 if ! build_and_test "$STAGE_DIR" "$HAVE_CATALOG" "VERSION=$NEW_VERSION" > "$LOG_FILE" 2>&1; then
  echo "ERROR: version $NEW_VERSION does not pass the tests on this host; the installed version $OLD_VERSION is untouched. The log:" >&2
  cat "$LOG_FILE" >&2
  echo "$NEW_COMMIT" > "$FAILED_COMMIT_FILE"
  return 1
 fi
 rm -rf "$STAGE_DIR"

 # Switch. Production tracks the repository only: local changes to tracked
 # files are listed, then discarded. Untracked files (the catalog symlink,
 # the built program) are not affected.
 local LOCAL_CHANGES
 LOCAL_CHANGES="$(git status --porcelain --untracked-files=no)"
 if [ -n "$LOCAL_CHANGES" ]; then
  echo "WARNING: discarding local changes to tracked files (an installation tracks the repository only - put fixes upstream):"
  echo "$LOCAL_CHANGES"
  git reset --hard --quiet || return 1
 fi
 if ! git merge --ff-only --quiet "$NEW_COMMIT"; then
  echo "ERROR: cannot fast-forward to $NEW_VERSION" >&2
  return 1
 fi
 if ! build_and_test "$ROOT_DIR" "$HAVE_CATALOG" > "$LOG_FILE" 2>&1; then
  echo "ERROR: version $NEW_VERSION failed after the switch, returning to $OLD_VERSION. The log:" >&2
  cat "$LOG_FILE" >&2
  echo "$NEW_COMMIT" > "$FAILED_COMMIT_FILE"
  # If the rebuild fails (bin/ not writable, say), the program built earlier
  # for the old version may still be in place: then the old version is back.
  if git reset --hard --quiet "$OLD_COMMIT" &&
   { make > "$LOG_FILE" 2>&1 || [ "$(bin/search_ucac5 --version 2> /dev/null)" = "# UCAC5 online search $OLD_VERSION" ]; } &&
   tests/test_offline.sh >> "$LOG_FILE" 2>&1; then
   echo "Version $OLD_VERSION is restored" >&2
  else
   cat "$LOG_FILE" >&2
   echo "ERROR: CANNOT RESTORE VERSION $OLD_VERSION - THE SERVICE NEEDS ATTENTION" >&2
  fi
  return 1
 fi

 rm -f "$FAILED_COMMIT_FILE"
 echo "UCAC5 online search updated from $OLD_VERSION to $NEW_VERSION"
 return 0
}

# Messages for the case when there is nothing to do
note() {
 if [ "$VERBOSE" -eq 1 ]; then
  echo "$1"
 fi
}

# with_timeout SECONDS COMMAND... : run the command, with a time limit if this system has timeout(1)
with_timeout() {
 local seconds="$1"
 shift
 if command -v timeout > /dev/null 2>&1; then
  timeout "$seconds" "$@"
 else
  "$@"
 fi
}

# build_and_test TREE HAVE_CATALOG [MAKE_ARGUMENT]: build the search program in
# the directory tree TREE and run its tests there
build_and_test() {
 local tree="$1" have_catalog="$2" make_argument="${3:-}"
 if [ -n "$make_argument" ]; then
  make -C "$tree" "$make_argument" || return 1
 else
  make -C "$tree" || return 1
 fi
 "$tree/tests/test_offline.sh" || return 1
 if [ "$have_catalog" -eq 1 ]; then
  "$tree/tests/test_real_catalog.sh" "$tree" || return 1
 fi
 return 0
}

# github_tests_state COMMIT: print "passed (N check runs)", "pending (...)" or
# a description of the problem. The GitHub repository is taken from the URL of
# origin; the question needs no authentication for a public repository.
github_tests_state() {
 local commit="$1" origin_url repository url response
 origin_url="$(git config --get remote.origin.url)"
 repository="$(printf '%s\n' "$origin_url" | sed -E 's#/+$##; s#\.git$##' | sed -n -E 's#^(https://([^/@]*@)?|ssh://git@|git@|git://)github\.com[:/]+([^/]+/[^/]+)$#\3#p')"
 if [ -z "$repository" ]; then
  # (the URL itself is not printed: it may carry credentials)
  echo "cannot tell the GitHub repository from the URL of origin"
  return
 fi
 # The Check Runs API is where GitHub Actions report; the older commit status
 # API stays empty ("pending" forever) for a repository tested by Actions only.
 url="https://api.github.com/repos/$repository/commits/$commit/check-runs?per_page=100"
 if command -v curl > /dev/null 2>&1; then
  response="$(curl --silent --show-error --fail --location --max-time 120 "$url" 2> /dev/null)"
 else
  response="$(wget -q -T 120 -O - "$url" 2> /dev/null)"
 fi
 if [ -z "$response" ]; then
  echo "cannot get the check runs of $commit from the GitHub API ($url)"
  return
 fi
 # An incomplete list proves nothing: with more than 100 check runs the
 # remaining ones would be on the next page.
 printf '%s\n' "$response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    runs = data["check_runs"]
    if not isinstance(runs, list) or data["total_count"] != len(runs):
        print("incomplete list of check runs")
    elif not runs:
        print("pending (no check runs yet)")
    elif not all(run["status"] == "completed" for run in runs):
        print("pending (%d of %d check runs still running)" % (sum(1 for run in runs if run["status"] != "completed"), len(runs)))
    elif all(run["conclusion"] in ("success", "skipped", "neutral") for run in runs):
        print("passed (%d check runs)" % len(runs))
    else:
        print("the tests failed: " + ", ".join("%s=%s" % (run["name"], run["conclusion"]) for run in runs if run["conclusion"] not in ("success", "skipped", "neutral")))
except (ValueError, KeyError, TypeError):
    print("cannot understand the reply of the GitHub API")
'
}

main "$@"
exit $?
