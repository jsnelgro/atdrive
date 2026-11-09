#!/bin/bash
# Builds ATDrive.app (debug), installs it to ~/Applications, and launches it, replacing any
# running copy. Look for the drive icon in the menu bar, sign in, and the drive appears in
# Finder's sidebar under Locations.
#
# Debugging:
#   /usr/bin/log stream --level debug --predicate 'subsystem == "me.jsnelgro.atdrive"'   app + extension logs
#     (/usr/bin/log, not log: zsh has a built-in `log` command that shadows it)
#   ls -t ~/Library/Logs/DiagnosticReports/ | grep ATDrive                    crash reports
#   pluginkit -m -v -i me.jsnelgro.atdrive.fileprovider                        is the extension registered?
#   fileproviderctl dump                                                         what macOS thinks is synced
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}" scripts/build-app.sh
pkill -x ATDrive 2>/dev/null || true
pkill -x ATDriveFileProvider 2>/dev/null || true

# One installed copy, so macOS doesn't find two versions of the extension.
mkdir -p ~/Applications
rm -rf ~/Applications/ATDrive.app
cp -R build/ATDrive.app ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/ATDrive.app
open ~/Applications/ATDrive.app
echo "ATDrive is running: look for its icon in the menu bar."
