#!/bin/bash
# Builds a release `atdrive` binary into ./build.
# On Linux the Swift runtime is linked in statically, so the binary runs without Swift installed.
#
# Usage: scripts/build.sh
#        scripts/build.sh && cp build/atdrive ~/.local/bin/   # install
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=(-c release --product atdrive)
[[ "$(uname)" == "Linux" ]] && FLAGS+=(--static-swift-stdlib)

swift build "${FLAGS[@]}"
mkdir -p build
cp "$(swift build "${FLAGS[@]}" --show-bin-path)/atdrive" build/atdrive
echo "Built build/atdrive"
