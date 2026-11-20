#!/bin/bash
# Prints ATDrive's version (ATDriveVersion.current in Sources/ATDriveCore/Version.swift).
#
# Usage: scripts/version.sh
#        scripts/version.sh --check v0.2.0   # fails unless the tag is v<version>
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n -E 's/^ *public static let current = "([^"]+)".*/\1/p' Sources/ATDriveCore/Version.swift)
[[ -n "$version" ]] || { echo "error: couldn't read the version from Sources/ATDriveCore/Version.swift" >&2; exit 1; }

if [[ "${1:-}" == "--check" ]]; then
  tag="${2:?usage: scripts/version.sh --check <tag>}"
  if [[ "$tag" != "v$version" ]]; then
    echo "error: tag $tag doesn't match the version in Sources/ATDriveCore/Version.swift ($version)." >&2
    echo "  Change the version there first, or tag v$version." >&2
    exit 1
  fi
fi
echo "$version"
