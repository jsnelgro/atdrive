#!/bin/bash
# Runs the tests. Extra arguments go to swift test, e.g.
#   scripts/test.sh --filter DriveTreeTests
# The live end-to-end test runs only when ATDRIVE_LIVE_HANDLE and ATDRIVE_LIVE_PASSWORD are set.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
