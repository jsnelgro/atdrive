#!/bin/bash
# Builds build/ATDrive.app (macOS only): the menu-bar app with the File Provider extension inside
# it at Contents/PlugIns/ATDriveFileProvider.appex, both signed.
#
# A macOS app is just a folder. SwiftPM builds the two executables; this script assembles the
# folders around them, fills in Info.plists and entitlements, and signs the extension, then the app.
#
# Signing: Finder integration needs an App Group, which needs a Team ID, so it needs a real
# certificate ("Apple Development" or "Developer ID Application"). Free Apple Developer accounts
# work for Apple Development. The first matching certificate in your keychain is used; override:
#   CODESIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)"   which certificate
#   TEAM_ID=ABCDE12345           if it can't be read from the certificate
#   BUNDLE_ID=me.jsnelgro.atdrive
#   APP_PROFILE=… EXTENSION_PROFILE=…   .provisionprofile files to embed, if macOS insists
#   ALLOW_ADHOC=1                build without a certificate (for CI; Finder integration won't work)
#   CONFIG=debug                 faster builds while developing
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUNDLE_ID="${BUNDLE_ID:-me.jsnelgro.atdrive}"
APP=build/ATDrive.app
EXT="$APP/Contents/PlugIns/ATDriveFileProvider.appex"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application):' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  if [[ "${ALLOW_ADHOC:-}" == 1 ]]; then
    CODESIGN_IDENTITY=-
  else
    echo "error: no Apple Development or Developer ID certificate found in your keychain." >&2
    echo "  Finder integration needs one (a free Apple Developer account is enough):" >&2
    echo "  Xcode > Settings > Accounts > Manage Certificates > + > Apple Development." >&2
    echo "  Set ALLOW_ADHOC=1 to build anyway (the app runs, but can't add the drive to Finder)." >&2
    exit 1
  fi
fi
if [[ -z "${TEAM_ID:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
  # The Team ID is the certificate's Organizational Unit.
  TEAM_ID=$(security find-certificate -c "$CODESIGN_IDENTITY" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' || true)
  [[ -n "$TEAM_ID" ]] || { echo "error: couldn't read the Team ID from \"$CODESIGN_IDENTITY\"; set TEAM_ID." >&2; exit 1; }
fi
APP_GROUP="${TEAM_ID:-ADHOC}.$BUNDLE_ID"

swift build -c "$CONFIG" --product ATDriveApp
swift build -c "$CONFIG" --product ATDriveFileProvider
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Frameworks"
cp "$BIN/ATDriveApp" "$APP/Contents/MacOS/ATDrive"

# The extension: its code is libATDriveFileProvider.dylib. Its executable has no code and no
# `main`; the entry point is Foundation's NSExtensionMain (what Xcode does for app extensions),
# and loading the library at launch registers the principal class from Info.plist.
cp "$BIN/libATDriveFileProvider.dylib" "$EXT/Contents/Frameworks/"
printf '// Intentionally empty: see build-app.sh.\n' > build/extension-stub.c
xcrun clang -arch "$(uname -m)" -mmacosx-version-min=14.0 build/extension-stub.c \
  -o "$EXT/Contents/MacOS/ATDriveFileProvider" \
  -Wl,-e,_NSExtensionMain -framework Foundation \
  -Wl,-needed_library,"$EXT/Contents/Frameworks/libATDriveFileProvider.dylib" \
  -Wl,-rpath,@executable_path/../Frameworks

render() { sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_GROUP__/$APP_GROUP/g" "$1" > "$2"; }
render Resources/App/Info.plist "$APP/Contents/Info.plist"
render Resources/FileProvider/Info.plist "$EXT/Contents/Info.plist"
render Resources/App/ATDrive.entitlements build/ATDrive.entitlements
render Resources/FileProvider/ATDriveFileProvider.entitlements build/ATDriveFileProvider.entitlements
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[[ -n "${APP_PROFILE:-}" ]] && cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
[[ -n "${EXTENSION_PROFILE:-}" ]] && cp "$EXTENSION_PROFILE" "$EXT/Contents/embedded.provisionprofile"

# The extension must start in Foundation's NSExtensionMain and must not define `main` (the
# extension runtime would call it again, recursing until it crashes).
for binary in "$EXT/Contents/MacOS/ATDriveFileProvider" "$EXT/Contents/Frameworks/libATDriveFileProvider.dylib"; do
  if nm -g "$binary" | grep -qE ' T _main$'; then
    echo "error: $binary defines main; the extension must use NSExtensionMain as its entry point." >&2
    exit 1
  fi
done
nm -u "$EXT/Contents/MacOS/ATDriveFileProvider" | grep -q '_NSExtensionMain' \
  || { echo "error: the extension binary doesn't use NSExtensionMain." >&2; exit 1; }

# Inside out: the extension's library, the extension, then the app that contains them.
SIGN=(codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp=none)
"${SIGN[@]}" "$EXT/Contents/Frameworks/libATDriveFileProvider.dylib"
"${SIGN[@]}" --entitlements build/ATDriveFileProvider.entitlements "$EXT"
"${SIGN[@]}" --entitlements build/ATDrive.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"
echo "  signed with: $CODESIGN_IDENTITY"
echo "  app group:   $APP_GROUP"
