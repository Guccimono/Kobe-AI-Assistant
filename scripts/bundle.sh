#!/bin/zsh
# Builds Kobe in release mode and wraps it into build/Kobe.app (menu bar app, no Dock icon).
# Usage: scripts/bundle.sh [--open]
#
# Signing: uses the "Kobe Local Code Signing" certificate from your login keychain. When it is missing, this script
# runs scripts/make-signing-cert.sh once to create it (so macOS keeps permissions across rebuilds); if that fails,
# it signs ad hoc.
# CFBundleVersion is set here to the commit count (git rev-list --count HEAD); Resources/Info.plist keeps "1".
set -euo pipefail
cd "${0:A:h}/.."
# A failed build stops here: never wrap an old binary.
swift build -c release --product Kobe > build-release.log 2>&1 || { grep -E 'error' build-release.log; echo "build failed"; exit 1; }
swift build -c release --product kobe-hook >> build-release.log 2>&1 || { grep -E 'error' build-release.log; echo "build failed"; exit 1; }
rm -f build-release.log
BIN_DIR="$(swift build -c release --show-bin-path)"
[[ -x $BIN_DIR/Kobe ]] || { echo "build failed"; exit 1; }
APP=build/Kobe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Kobe" "$APP/Contents/MacOS/Kobe"
cp "$BIN_DIR/kobe-hook" "$APP/Contents/MacOS/kobe-hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
# The app icon (scripts/make-icon.swift): shown in the Dock and ⌘Tab while Settings is open.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resources (Phosphor icons) live in KobeKit's resource bundle.
cp -R "$BIN_DIR/KobeAssistant_KobeKit.bundle" "$APP/Contents/Resources/"
# Kobe Agent (Python connectors + skill): the onboarding installer copies it from Resources/agent. No tests, no caches.
rsync -a --exclude tests --exclude scripts --exclude __pycache__ --exclude '*.pyc' agent/ "$APP/Contents/Resources/agent/"
IDENTITY="${KOBE_SIGN_IDENTITY:-Kobe Local Code Signing}"
if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "No \"$IDENTITY\" certificate yet: creating it in your login keychain (once)."
  ./scripts/make-signing-cert.sh || echo "note: no usable signing certificate; signing ad hoc."
fi
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime --sign "$IDENTITY" -i com.kobe-assistant.app.hook "$APP/Contents/MacOS/kobe-hook"
  codesign --force --options runtime --entitlements Resources/Kobe.entitlements --sign "$IDENTITY" "$APP"
else
  echo "note: no \"$IDENTITY\" certificate; signing ad hoc (macOS may ask for permissions again after rebuilds)."
  codesign --force --sign - -i com.kobe-assistant.app.hook "$APP/Contents/MacOS/kobe-hook"
  codesign --force --entitlements Resources/Kobe.entitlements --sign - "$APP"
fi
echo "Built $PWD/$APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
