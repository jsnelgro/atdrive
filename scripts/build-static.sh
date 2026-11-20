#!/bin/bash
# Builds fully static `atdrive` binaries for Linux, x86_64 and aarch64, packed for a release:
#   dist/atdrive-<version>-linux-x86_64.tar.gz
#   dist/atdrive-<version>-linux-aarch64.tar.gz
# They're linked against musl with Swift's Static Linux SDK, so they have no dependencies at all
# and run on any Linux distribution. (`scripts/build.sh` links glibc, so its binary needs a
# glibc at least as new as the one it was built with.)
#
# Needs Swift $SWIFT_VERSION exactly: the SDK only works with the toolchain of the same version.
# The SDK is installed the first time. Runs on Linux or macOS (with a swift.org toolchain, not
# Xcode's). The release workflow runs it; you can too, to check a static build.
#
# Usage: scripts/build-static.sh [x86_64|aarch64 ...]    (default: both)
set -euo pipefail
cd "$(dirname "$0")/.."

# From https://www.swift.org/install/ (Static Linux SDK). Change all three together, with the
# container in .github/workflows/release.yml.
SWIFT_VERSION=6.4.2
SDK_URL=https://download.swift.org/swift-6.4.2-release/static-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SDK_CHECKSUM=3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a

ARCHS=("$@")
[[ ${#ARCHS[@]} -gt 0 ]] || ARCHS=(x86_64 aarch64)

have=$(swift --version 2>&1 | sed -n -E 's/.*Swift version ([0-9.]+).*/\1/p' | head -1)
if [[ "$have" != "$SWIFT_VERSION" ]]; then
  echo "error: this needs Swift $SWIFT_VERSION (the Static Linux SDK's version); found ${have:-none}." >&2
  exit 1
fi
SDK_NAME=$(basename "$SDK_URL" .artifactbundle.tar.gz)
if ! swift sdk list 2>/dev/null | grep -qx "$SDK_NAME"; then
  swift sdk install "$SDK_URL" --checksum "$SDK_CHECKSUM"
fi

# Strips debug info: about 180 MB down to about 60 MB.
STRIP=$(command -v llvm-objcopy || true)
[[ -n "$STRIP" ]] || STRIP="$(dirname "$(command -v swift)")/llvm-objcopy"

VERSION=$(scripts/version.sh)
mkdir -p dist build/static
for arch in "${ARCHS[@]}"; do
  flags=(-c release --product atdrive --swift-sdk "$arch-swift-linux-musl")
  swift build "${flags[@]}"
  "$STRIP" --strip-all "$(swift build "${flags[@]}" --show-bin-path)/atdrive" build/static/atdrive
  tar -C build/static -czf "dist/atdrive-$VERSION-linux-$arch.tar.gz" atdrive
  rm build/static/atdrive
  echo "Built dist/atdrive-$VERSION-linux-$arch.tar.gz"
done
