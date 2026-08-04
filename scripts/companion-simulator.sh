#!/usr/bin/env bash
# Build, install and launch the iPhone Companion on a simulator.
#
# PR 5's matrix was treated as blocked on physical hardware. Most of it is not:
# the Simulator shares the Mac's network stack, so it sees the Mac's
# `_kaisola._tcp` advertisement and can pair over it. Pairing, resume, revoke,
# account isolation, capability grants and lease expiry are all reachable here.
#
# Two things genuinely are not, and neither is a matter of effort:
#
#   * Nearby-to-Link switching, which needs a device that can actually leave the
#     LAN — a simulator never does.
#   * Face ID, which the Simulator can only enrol synthetically.
#
# Two traps this exists to encode, both found the hard way:
#
#   * `CODE_SIGNING_ALLOWED=NO` builds an app with **no entitlements**, and the
#     Companion then fails at launch with "could not access the saved sign-in:
#     A required entitlement isn't present". That is not a product bug — it is
#     the missing `application-identifier`. This script signs.
#   * The project must declare `SUPPORTED_PLATFORMS` explicitly. Deriving it
#     from `SDKROOT = iphoneos` yields device-only, and the scheme then reports
#     *zero* eligible destinations, which reads as "the Simulator is broken".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT/mobile/KaisolaCompanion/KaisolaCompanion.xcodeproj"
BUNDLE_ID="com.kaisola.companion"
DERIVED="${KAISOLA_COMPANION_DERIVED_DATA:-$ROOT/.build/KaisolaCompanion.noindex}"
DEVICE="${KAISOLA_COMPANION_SIMULATOR:-iPhone 17 Pro}"

/bin/echo "Resolving simulator: $DEVICE"
UDID="$(xcrun simctl list devices available \
  | grep -F "$DEVICE (" \
  | head -1 \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [ -z "${UDID:-}" ]; then
  /bin/echo "No available simulator named '$DEVICE'." >&2
  /bin/echo "List them with: xcrun simctl list devices available" >&2
  exit 1
fi

# Booting an already-booted device is not an error worth stopping for.
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

/bin/echo "Building for $DEVICE ($UDID)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme KaisolaCompanion \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  build >/dev/null

APP="$DERIVED/Build/Products/Debug-iphonesimulator/KaisolaCompanion.app"
[ -d "$APP" ] || { /bin/echo "Build produced no app at $APP" >&2; exit 1; }

# Reinstalling over a running app leaves the old process attached to the old
# binary, which then "fixes itself" on the next launch and hides real failures.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

/bin/echo ""
/bin/echo "Companion running on $DEVICE."
/bin/echo "Screenshot it with:"
/bin/echo "  xcrun simctl io $UDID screenshot /tmp/companion.png"
/bin/echo ""
/bin/echo "For pairing, the Mac side must be advertising: open Kaisola,"
/bin/echo "Settings > Companion, turn the host on, then create a pairing code."
/bin/echo "Confirm it is up with:  dns-sd -B _kaisola._tcp local"
