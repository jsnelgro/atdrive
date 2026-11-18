#!/bin/bash
# Gets a Swift toolchain on Linux (for agent sandboxes and fresh machines). Prints the line to
# source afterwards. Run `scripts/setup-swift.sh --undo` to drop the fallback's local changes.
#
# 1. A Swift that's new enough (6.2+, which swift-crypto 5 needs) on PATH: nothing to do.
# 2. The official toolchain from download.swift.org (the series CI uses), into ~/.swift.
# 3. Fallback, when download.swift.org isn't reachable (e.g. a sandbox's network allowlist):
#    Swift 6.0.3 from Ubuntu's package archive, unpacked into ~/.swift (no root), with
#    swift-crypto held at 4.x in a local-only change to Package.swift and Package.resolved.
#    Git is told to ignore that change (skip-worktree), so it never gets committed. Everything
#    builds and the tests pass this way, but CI (Swift 6.4, swift-crypto 5) is the real check.
set -euo pipefail
cd "$(dirname "$0")/.."

# The series CI uses (the swift:6.4 image); the newest patch release of it is installed.
SWIFT_SERIES=6.4
PREFIX="$HOME/.swift"
ENV_FILE="$PREFIX/env.sh"

undo() {
    git update-index --no-skip-worktree Package.swift Package.resolved
    git checkout -- Package.swift Package.resolved
    echo "Restored Package.swift and Package.resolved."
}
if [ "${1:-}" = "--undo" ]; then undo; exit; fi

new_enough() {
    command -v swift >/dev/null || return 1
    local v
    v=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)
    [ -n "$v" ] || return 1
    set -- $v
    [ "$1" -gt 6 ] || { [ "$1" -eq 6 ] && [ "$2" -ge 2 ]; }
}

if new_enough; then
    echo "$(swift --version 2>&1 | head -1): nothing to do."
    exit
fi
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
if new_enough; then
    echo "Already installed. Run: . $ENV_FILE"
    exit
fi

mkdir -p "$PREFIX"
. /etc/os-release
platform="ubuntu${VERSION_ID//./}"
arch_suffix=""
[ "$(uname -m)" = "aarch64" ] && arch_suffix="-aarch64"

# download.swift.org answers a missing file with a redirect, so a 206 means it's there.
for patch in 9 8 7 6 5 4 3 2 1 ""; do
    version="$SWIFT_SERIES${patch:+.$patch}"
    name="swift-${version}-RELEASE-ubuntu${VERSION_ID}${arch_suffix}"
    url="https://download.swift.org/swift-${version}-release/${platform}${arch_suffix}/swift-${version}-RELEASE/${name}.tar.gz"
    status=$(curl -s --max-time 20 -o /dev/null -r 0-0 -w '%{http_code}' "$url" || true)
    if [ "$status" = "206" ]; then
        echo "Downloading $name from download.swift.org..."
        curl -fsSL "$url" | tar xz -C "$PREFIX"
        echo "export PATH=\"$PREFIX/$name/usr/bin:\$PATH\"" > "$ENV_FILE"
        echo "Installed Swift $version. Run: . $ENV_FILE"
        exit
    fi
done

echo "download.swift.org isn't reachable. Falling back to Swift 6.0.3 from Ubuntu's archive."
echo "(To get the official toolchain, allow download.swift.org in the sandbox's network settings.)"
archive=http://archive.ubuntu.com/ubuntu
work="$PREFIX/debs"
mkdir -p "$work"
for f in \
    pool/universe/s/swiftlang/swiftlang_6.0.3-2build1_amd64.deb \
    pool/universe/s/swiftlang/libswiftlang_6.0.3-2build1_amd64.deb \
    pool/main/libx/libxml2/libxml2-16_2.14.5+dfsg-0.2_amd64.deb; do
    [ -f "$work/$(basename "$f")" ] || curl -fsSL -o "$work/$(basename "$f")" "$archive/$f"
    dpkg -x "$work/$(basename "$f")" "$PREFIX/ubuntu-6.0.3"
done
root="$PREFIX/ubuntu-6.0.3/usr"
cat > "$ENV_FILE" <<EOF
export PATH="$root/libexec/swift/bin:\$PATH"
export LD_LIBRARY_PATH="$root/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
. "$ENV_FILE"

# swift-crypto 4.4 and later declare tools version 6.2; 4.3 has every API ATDrive uses.
sed -i 's|swift-crypto", from: "[0-9.]*"|swift-crypto", "3.0.0"..<"4.4.0"|' Package.swift
rm -f Package.resolved
swift package resolve
git update-index --skip-worktree Package.swift Package.resolved
echo "Installed Swift 6.0.3 with swift-crypto 4.x (local only, hidden from git)."
echo "Run: . $ENV_FILE"
echo "Before changing Package.swift for real: scripts/setup-swift.sh --undo"
