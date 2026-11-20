#!/usr/bin/env bash
# Runs the tests, twice: once with the drive-logic suites on a plain drive, and once with them on
# an encrypted one (ATDRIVE_TEST_MODE, see TestMode in FakePDS.swift). Extra arguments go to
# swift test, e.g.
#   scripts/test.sh --filter DriveTreeTests
# To run one mode only: ATDRIVE_TEST_MODE=plain scripts/test.sh (or =encrypted).
# The live tests run only when ATDRIVE_LIVE_STATE names a folder `atdrive login` saved a session
# to (sign in with ATDRIVE_STATE_DIR=<folder> atdrive login <handle>), or, for the OAuth one,
# ATDRIVE_LIVE_HANDLE is set.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${ATDRIVE_TEST_MODE:-}" ]; then
    swift test "$@"
    exit
fi
echo "== Tests on a plain drive =="
ATDRIVE_TEST_MODE=plain swift test "$@"
echo "== Tests on an encrypted drive =="
ATDRIVE_TEST_MODE=encrypted swift test "$@"
