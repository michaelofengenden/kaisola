#!/usr/bin/env bash
# Build, install, and optionally archive a canary Kaisola: current source at
# LocalRelease optimization, signed locally with the Developer ID certificate,
# never notarized, never touching CI or the appcast.
#
#   ./scripts/native-canary.sh                 build, install, launch
#   ./scripts/native-canary.sh --install-only  build and install only
#   ./scripts/native-canary.sh --archive       also zip release/canary/…
#
# The canary is its own bundle (`com.kaisola.mac.canary`, "Kaisola Canary") so
# the notarized daily driver stays untouched; broker-owned PTYs survive either
# app replacing its GUI. First launch will prompt once for permissions
# (Screen Recording for the glass backdrop, notifications) and Keychain-backed
# accounts sign in fresh, because permissions and Keychain scope follow the
# bundle identity.
#
# Sharing the zip: transfers that never set the quarantine attribute (scp,
# rsync, a USB drive) launch as-is on another Mac. Browser downloads and
# AirDrop set quarantine, and without notarization Gatekeeper will refuse the
# first open until the receiver uses System Settings > Privacy & Security >
# Open Anyway. For anything user-facing, cut a real release instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCHIVE=0
PASS_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --archive) ARCHIVE=1 ;;
    *) PASS_ARGS+=("$arg") ;;
  esac
done

export KAISOLA_NATIVE_CONFIGURATION="${KAISOLA_NATIVE_CONFIGURATION:-LocalRelease}"
export KAISOLA_NATIVE_APP="${KAISOLA_NATIVE_APP:-$HOME/Applications/Kaisola Canary.app}"
export KAISOLA_NATIVE_BUNDLE_ID="${KAISOLA_NATIVE_BUNDLE_ID:-com.kaisola.mac.canary}"
export KAISOLA_NATIVE_DISPLAY_NAME="${KAISOLA_NATIVE_DISPLAY_NAME:-Kaisola Canary}"
# Stable identity so TCC grants and Keychain access survive rebuilds; signing
# is local and instant, notarization never happens in this lane. Set both
# envs to empty to fall back to ad-hoc when no certificate is available.
export KAISOLA_NATIVE_SIGN_IDENTITY="${KAISOLA_NATIVE_SIGN_IDENTITY-Developer ID Application}"
export KAISOLA_NATIVE_TEAM="${KAISOLA_NATIVE_TEAM-KBD9RS8425}"

"$ROOT/scripts/native-dev.sh" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}

if [[ "$ARCHIVE" -eq 1 ]]; then
  APP="$KAISOLA_NATIVE_APP"
  if [[ ! -x "$APP/Contents/MacOS/Kaisola" ]]; then
    /bin/echo "No installed canary to archive: $APP" >&2
    exit 1
  fi
  VERSION="$(/usr/bin/env node -p "require(process.argv[1]).version" "$ROOT/package.json")"
  SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
  OUT_DIR="$ROOT/release/canary"
  OUT="$OUT_DIR/Kaisola-Canary-$VERSION-$SHA.zip"
  /bin/mkdir -p "$OUT_DIR"
  /bin/rm -f "$OUT"
  /usr/bin/ditto -c -k --keepParent "$APP" "$OUT"
  /bin/echo "Canary archive: $OUT"
  /bin/echo "Share via scp/rsync to launch untouched; quarantined copies need Open Anyway."
fi
