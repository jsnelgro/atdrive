#!/bin/bash
# Builds the signed Mac app and adds it to the GitHub release for this version (macOS only).
# Run it on your Mac, after pushing the tag and after the Release workflow has created the release:
#
#   git checkout v0.2.0 && scripts/release-app.sh
#
# Adds ATDrive-<version>-macos-arm64.zip to release v<version> and its line to SHA256SUMS.
#
# The app is signed with your Apple Development certificate (build-app.sh finds it; its options
# work here too), not Developer ID, and it isn't notarized: testers remove the quarantine flag or
# click Open Anyway (the release notes say how). It's built for Apple silicon only.
#
# Needs gh (https://cli.github.com), signed in with access to the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "the Mac app is built on a Mac."
[[ "$(uname -m)" == "arm64" ]] || fail "release builds are for Apple silicon; run this on an Apple silicon Mac."
[[ "${ALLOW_ADHOC:-}" != 1 ]] || fail "unset ALLOW_ADHOC: an ad hoc app can't add the drive to Finder."
command -v gh >/dev/null || fail "needs gh (https://cli.github.com)."

VERSION=$(scripts/version.sh)
TAG="v$VERSION"

# What's released must be what was tagged: no local changes, and HEAD is the tag.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "there are uncommitted changes."
git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
tagged=$(git rev-list -n 1 "$TAG" 2>/dev/null) || fail "there's no tag $TAG. Push it first: git tag $TAG && git push origin $TAG"
[[ "$(git rev-parse HEAD)" == "$tagged" ]] || fail "HEAD isn't $TAG. Run: git checkout $TAG"
gh release view "$TAG" >/dev/null 2>&1 \
  || fail "release $TAG doesn't exist yet. Wait for the Release workflow (gh run watch), then run this again."

CONFIG=release scripts/build-app.sh

ZIP="ATDrive-$VERSION-macos-arm64.zip"
rm -f "build/$ZIP"
# ditto keeps the bundle's signatures, symlinks and extended attributes, which zip doesn't.
ditto -c -k --keepParent build/ATDrive.app "build/$ZIP"

# SHA256SUMS: the release's, with this zip's line replaced.
rm -rf build/release-sums && mkdir -p build/release-sums
gh release download "$TAG" --pattern SHA256SUMS --dir build/release-sums 2>/dev/null || touch build/release-sums/SHA256SUMS
grep -v "  $ZIP\$" build/release-sums/SHA256SUMS > build/release-sums/SHA256SUMS.new || true
(cd build && shasum -a 256 "$ZIP") >> build/release-sums/SHA256SUMS.new
mv build/release-sums/SHA256SUMS.new build/release-sums/SHA256SUMS

gh release upload "$TAG" "build/$ZIP" build/release-sums/SHA256SUMS --clobber
echo "Added $ZIP to $(gh release view "$TAG" --json url --jq .url)"
