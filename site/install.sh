#!/bin/sh
# Kaisola installer — curl -fsSL https://kaisola.com/install.sh | sh
# Downloads the latest release (signed & notarized) and installs it
# to /Applications.
set -e

[ "$(uname -s)" = "Darwin" ] || { echo "Kaisola runs on macOS only (for now)."; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Kaisola currently ships for Apple Silicon (arm64) only."; exit 1; }

tmp=$(mktemp -d)
mnt=""
cleanup() {
  [ -n "$mnt" ] && hdiutil detach "$mnt" -quiet 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "Downloading Kaisola…"
curl -fL --progress-bar -o "$tmp/Kaisola.dmg" \
  "https://github.com/michaelofengenden/kaisola/releases/latest/download/Kaisola.dmg"

echo "Installing to /Applications…"
mnt=$(hdiutil attach "$tmp/Kaisola.dmg" -nobrowse -noautoopen -readonly | grep -o '/Volumes/.*' | tail -1)
rm -rf /Applications/Kaisola.app
ditto "$mnt/Kaisola.app" /Applications/Kaisola.app
hdiutil detach "$mnt" -quiet
mnt=""

echo "Done — launching Kaisola."
open /Applications/Kaisola.app
