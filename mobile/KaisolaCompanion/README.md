# Kaisola Companion

This is the native, iPhone-first Kaisola Companion. It signs in with the same
Firebase/Google account as the desktop, pairs to a specific Mac with a signed
short-lived offer and four-word verification, and mirrors live activity,
agent transcripts, and terminal streams over an encrypted LAN link.

Every newly paired phone remains observe-only by default. In desktop Settings →
Companion, the user can independently grant agent control and terminal control
to that exact device. Agent control can send or steer a turn, stop an active
agent, and answer a complete permission request using its exact option and
revision. Terminal control unlocks locally with Face ID or the device passcode,
then uses one 30-second, connection-bound lease per terminal. The lease renews
only while the terminal is open, ends on disconnect/background/revoke, rejects
stale writes, and restores the desktop's terminal geometry when it ends.

Terminal viewing uses SwiftTerm as a real VT emulator. Links, mouse reports,
clipboard callbacks, and terminal extension callbacks are disabled. Input is
bounded to 16 KB, multiline or large pastes require confirmation, and the app
does not expose terminal creation, kill, or release. A durable broker from an
older desktop build remains viewable through bounded snapshot polling; input
still works, but phone resize stays disabled until that broker naturally exits
so Kaisola never leaves the desktop at an unknown geometry.

Pairing has three coordinated paths:

- “Find my Mac” retrieves the Mac's short-lived signed offer through the same
  authenticated account. The actual data connection remains local and
  end-to-end encrypted; Firebase never receives terminal content or keys.
- QR embeds the current direct LAN address and port for immediate connection.
- Bonjour remains active as discovery and reconnect fallback when an address
  changes. Discovery prefers the stable identity of the paired Mac instead of
  trusting a stale QR address. Foregrounding and cold relaunches reconnect
  automatically, while the visible reload action forces an immediate retry.
  Transient reconnects replay from the acknowledged cursor and restore active
  terminal subscriptions with receipt-aware retries; a cold launch requests a
  coherent fresh snapshot.

Home and Sessions use the timestamp of the latest agent or CLI response—not
session creation—and only label a session Running while it is actively
responding. Activity is grouped by desktop window and project. Agent transcripts
and terminal streams follow new output to the bottom while preserving manual
scrollback.

## Open in Xcode

```sh
cd mobile/KaisolaCompanion
xcodegen generate
open KaisolaCompanion.xcodeproj
```

Choose an iPhone simulator and run the `KaisolaCompanion` scheme.

For a fixture-backed visual preview, set `KAISOLA_UI_PREVIEW=1` in the scheme's
launch environment. The normal run path uses the real sign-in, pairing,
transport, and projection store.

## Command-line build

```sh
xcodebuild \
  -project mobile/KaisolaCompanion/KaisolaCompanion.xcodeproj \
  -scheme KaisolaCompanion \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/kaisola-companion-derived \
  CODE_SIGNING_ALLOWED=NO build
```
