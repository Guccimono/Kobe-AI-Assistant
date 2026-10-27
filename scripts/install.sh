#!/bin/zsh
# Installs Kobe (the notch app, com.kobe-assistant.app) into /Applications and starts it.
# Usage: scripts/install.sh
#
# It only ever replaces its own app: if another app sits at /Applications/Kobe.app, it stops and changes nothing.
set -euo pipefail
cd "${0:A:h}/.."
DEST=/Applications/Kobe.app
# Same value as Brand.bundleID in Sources/KobeKit/Brand.swift.
NEW_ID=com.kobe-assistant.app

./scripts/bundle.sh
if [[ -d $DEST ]]; then
  EXISTING=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || true)
  if [[ $EXISTING != $NEW_ID ]]; then
    echo "Another app is installed at $DEST ($EXISTING). Nothing was changed: move it away first."
    exit 2
  fi
  osascript -e "tell application id \"$NEW_ID\" to quit" 2>/dev/null || true
  sleep 1
  pkill -f "$DEST/Contents/MacOS/Kobe" 2>/dev/null || true
fi
rm -rf "$DEST"
ditto build/Kobe.app "$DEST"
codesign --verify --deep --strict "$DEST" && echo "signature ok"
open "$DEST"
# Unregister the build copy from Launch Services before deleting it, so only /Applications/Kobe.app stays known.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/build/Kobe.app" 2>/dev/null || true
rm -rf build/Kobe.app
echo "Installed and started $DEST"
