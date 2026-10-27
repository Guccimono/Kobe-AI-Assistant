#!/bin/zsh
# Fallback for the WhatsApp gateway. Kobe installs GOWA (go-whatsapp-web-multidevice, MIT) itself from
# Settings › Connections › WhatsApp › Install WhatsApp, which fetches its latest macOS build from GitHub, checks it
# and puts it in ~/Library/Application Support/Kobe/GOWA/gowa; the app then reads chats and sends your replies.
# Use this script only when that installer cannot run: pass a GOWA binary you already have and it is copied into
# place (nothing is downloaded). Without an argument it just reports whether a binary is there.
# Usage: scripts/setup-gowa.sh [path/to/gowa]
set -euo pipefail
DEST=~/Library/Application\ Support/Kobe\ Notch/GOWA
mkdir -p "$DEST"
if [[ -n "${1:-}" ]]; then
  [[ -f "$1" ]] || { echo "not a file: $1"; exit 1; }
  cp "$1" "$DEST/gowa"
  chmod 755 "$DEST/gowa"
  xattr -d com.apple.quarantine "$DEST/gowa" 2>/dev/null || true
fi
if [[ -x "$DEST/gowa" ]]; then
  echo "GOWA ready: $DEST/gowa (turn WhatsApp on in Settings › Connections › WhatsApp)"
else
  echo "GOWA missing: $DEST/gowa. Use Settings › Connections › WhatsApp › Install WhatsApp, or pass a binary."
  exit 1
fi
