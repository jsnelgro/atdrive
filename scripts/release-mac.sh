#!/usr/bin/env bash
# Builds a release's Mac files on your Mac, ready to upload by hand. Run it with the release's tag
# checked out:
#
#   git checkout v0.2.0 && scripts/release-mac.sh
#
# Writes to dist/, each with its checksum (<file>.sha256):
#   ATDrive-<version>-macos-arm64.zip       the app, signed with your Apple Development certificate
#   atdrive-<version>-macos-arm64.tar.gz    the command-line tool on its own, unsigned
# then shows them in Finder and opens the release page (on GitHub, Tangled or both, from the
# remotes): drag them onto it. Nothing here is tied to a forge. (The Linux files come from
# scripts/build-static.sh, which the GitHub release workflow runs.)
#
# The app isn't Developer ID signed or notarized (that needs the paid Apple Developer Program):
# testers remove the quarantine flag or click Open Anyway (the release notes say how).
# build-app.sh's signing options work here too. Apple silicon only.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "the Mac files are built on a Mac."
[[ "$(uname -m)" == "arm64" ]] || fail "release builds are for Apple silicon; run this on an Apple silicon Mac."
[[ "${ALLOW_ADHOC:-}" != 1 ]] || fail "unset ALLOW_ADHOC: an ad hoc app can't add the drive to Finder."

VERSION=$(scripts/version.sh)
TAG="v$VERSION"

# What's released must be what was tagged: no local changes, and HEAD is the tag.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "there are uncommitted changes."
git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
tagged=$(git rev-list -n 1 "$TAG" 2>/dev/null) \
  || fail "there's no tag $TAG. Tag and push it first: git tag -a $TAG -m \"ATDrive $VERSION\" && git push origin $TAG"
[[ "$(git rev-parse HEAD)" == "$tagged" ]] || fail "HEAD isn't $TAG. Run: git checkout $TAG"

APP_ZIP="ATDrive-$VERSION-macos-arm64.zip"
CLI_TAR="atdrive-$VERSION-macos-arm64.tar.gz"
mkdir -p dist
rm -f "dist/$APP_ZIP"* "dist/$CLI_TAR"*

CONFIG=release scripts/build-app.sh
# ditto keeps the bundle's signatures, symlinks and extended attributes, which zip doesn't.
ditto -c -k --keepParent build/ATDrive.app "dist/$APP_ZIP"

scripts/build.sh
tar -C build -czf "dist/$CLI_TAR" atdrive

for file in "$APP_ZIP" "$CLI_TAR"; do
  (cd dist && shasum -a 256 "$file" > "$file.sha256")
done

# The release pages, from the remotes: github.com/<owner>/<repo> and tangled.org/<handle>/<repo>
# (push to both, and both get one).
pages=()
for remote in $(git remote); do
  path=$(git remote get-url "$remote" | sed -E -e 's#^(git@|ssh://git@|https://)##' \
    -e 's#^([^/:]+)[:/]#\1/#' -e 's#\.git$##' -e 's#/@#/#')
  case "$path" in
    github.com/*) pages+=("https://$path/releases/edit/$TAG") ;;
    tangled.org/* | tangled.sh/*) pages+=("https://$path/tags/$TAG") ;;
  esac
done

echo
echo "Built, in dist/:"
for file in "$APP_ZIP" "$CLI_TAR"; do echo "  $file  $file.sha256"; done
echo "Upload all four to the $TAG release:"
for page in "${pages[@]}"; do echo "  $page"; done
[[ ${#pages[@]} -gt 0 ]] || echo "  (no GitHub or Tangled remote found: upload them wherever the release is)"
open -R "dist/$APP_ZIP"
for page in "${pages[@]}"; do open "$page"; done
exit 0
