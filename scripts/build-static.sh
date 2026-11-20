#!/bin/bash
# Builds fully static `atdrive` binaries for Linux, x86_64 and aarch64, packed for a release:
#   dist/atdrive-<version>-linux-x86_64.tar.gz    and its checksum, ….tar.gz.sha256
#   dist/atdrive-<version>-linux-aarch64.tar.gz
# They're linked against musl with Swift's Static Linux SDK, so they have no dependencies at all
# and run on any Linux distribution. (`scripts/build.sh` links glibc, so its binary needs a
# glibc at least as new as the one it was built with.)
#
# Needs a Swift toolchain listed below: the Static Linux SDK only works with the toolchain of the
# same version, so this installs the SDK that matches `swift --version` (the first time). Works
# with swift.org's toolchains on Linux or macOS (not Xcode's) and the swift:6.4.x containers.
# nixpkgs' swift (6.4.0 in unstable) may work too: untested. The release workflow and CI run it;
# you can too, to check a static build.
#
# Usage: scripts/build-static.sh [x86_64|aarch64 ...]    (default: both)
set -euo pipefail
cd "$(dirname "$0")/.."

# Static Linux SDKs, from https://www.swift.org/install/ (Static Linux SDK): toolchain version,
# SDK version, checksum. Add a line for a new toolchain.
SDKS="
6.4.0 0.1.0 47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
6.4.1 0.1.0 cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c
6.4.2 0.1.0 3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a
"

ARCHS=("$@")
[[ ${#ARCHS[@]} -gt 0 ]] || ARCHS=(x86_64 aarch64)

have=$(swift --version 2>&1 | sed -n -E 's/.*Swift version ([0-9.]+).*/\1/p' | head -1)
[[ "$have" =~ ^[0-9]+\.[0-9]+$ ]] && have="$have.0" # "6.4" is 6.4.0
read -r _ sdk_version checksum < <(echo "$SDKS" | awk -v v="$have" '$1 == v') || true
if [[ -z "${checksum:-}" ]]; then
  echo "error: no Static Linux SDK listed for Swift ${have:-(none found)}. Install one of:" >&2
  echo "$SDKS" | awk 'NF { print "  Swift " $1 }' >&2
  echo "  or add its SDK to the list at the top of $0." >&2
  exit 1
fi
SDK_NAME="swift-$have-RELEASE_static-linux-$sdk_version"
SDK_URL="https://download.swift.org/swift-$have-release/static-sdk/swift-$have-RELEASE/$SDK_NAME.artifactbundle.tar.gz"
if ! swift sdk list 2>/dev/null | grep -qx "$SDK_NAME"; then
  swift sdk install "$SDK_URL" --checksum "$checksum"
fi

# Strips debug info: about 180 MB down to about 60 MB.
STRIP=$(command -v llvm-objcopy || true)
[[ -n "$STRIP" ]] || STRIP="$(dirname "$(command -v swift)")/llvm-objcopy"

VERSION=$(scripts/version.sh)
mkdir -p dist build/static
for arch in "${ARCHS[@]}"; do
  # Name the SDK as well as the triple: with several SDKs installed, the triple alone is ambiguous.
  flags=(-c release --product atdrive --swift-sdk "$SDK_NAME" --triple "$arch-swift-linux-musl")
  swift build "${flags[@]}"
  "$STRIP" --strip-all "$(swift build "${flags[@]}" --show-bin-path)/atdrive" build/static/atdrive
  file="atdrive-$VERSION-linux-$arch.tar.gz"
  tar -C build/static -czf "dist/$file" atdrive
  rm build/static/atdrive
  (cd dist && { sha256sum "$file" 2>/dev/null || shasum -a 256 "$file"; } > "$file.sha256")
  echo "Built dist/$file (and $file.sha256)"
done
