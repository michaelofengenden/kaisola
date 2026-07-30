# Kaisola Companion

This is the native, iPhone-first Kaisola Companion. It signs in with the same
Firebase/Google account as the desktop, pairs to a specific Mac with a signed
short-lived offer and four-word verification, and mirrors live activity,
agent transcripts, and terminal streams over one end-to-end encrypted channel.
It chooses Bonjour/LAN first, an optional Tailscale or Headscale private route
second, and automatic Kaisola Link third. No router port or public Mac listener
is required.

The app now consumes the local `native/KaisolaCore` Swift package for its
domain, protocol, crypto, pairing, and framing contracts. The native macOS
migration uses the same compiled definitions and the same checked-in Node wire
fixtures rather than maintaining a second Swift copy.

Newly paired phones request viewing, agent control, and terminal control in one
confirmed pairing, while desktop Settings → Companion can independently narrow
either control grant for that exact device at any time. Agent control can send
or steer a turn, stop an active agent, and answer a complete permission request
using its exact option and revision. Terminal control still unlocks locally with
Face ID or the device passcode, then uses one 30-second, connection-bound lease
per terminal. The lease renews only while the terminal is open, ends on
disconnect/background/revoke, rejects stale writes, and restores the desktop's
terminal geometry when it ends.

Terminal viewing uses SwiftTerm as a real VT emulator. Links, mouse reports,
clipboard callbacks, and terminal extension callbacks are disabled. Input is
bounded to 16 KB, multiline or large pastes require confirmation, and the app
does not expose terminal creation, kill, or release. A durable broker from an
older desktop build remains viewable through bounded snapshot polling; input
still works, but phone resize stays disabled until that broker naturally exits
so Kaisola never leaves the desktop at an unknown geometry.

Pairing and reconnect have coordinated paths:

- “Find my Mac” retrieves the Mac's short-lived signed offer through the same
  authenticated account. The actual data connection remains local and
  end-to-end encrypted; Firebase never receives terminal content or keys.
- QR embeds the current direct LAN address and port for immediate connection.
- Bonjour remains active as discovery and reconnect fallback when an address
  changes. Discovery prefers the stable identity of the paired Mac instead of
  trusting a stale QR address, and discovery changes cannot interrupt a TCP or
  Noise resume already in flight. Foregrounding and cold relaunches reconnect
  automatically, while the visible reload action forces an immediate retry.
  Transient reconnects replay from the acknowledged cursor and restore active
  terminal subscriptions with receipt-aware retries; a cold launch requests a
  coherent fresh snapshot. Desktop socket backpressure retains accepted
  snapshots instead of treating a queued write as a disconnect.
- Tailscale is an optional off-network fallback. The Mac publishes its private
  Tailscale address only inside the signed pairing offer and encrypted desktop
  hello. An existing paired phone therefore learns the route after connecting
  nearby once; it does not need to be re-paired. The phone tries Bonjour/LAN
  first, switches immediately on cellular or after a bounded direct-connection
  timeout, and prefers Bonjour again on the next reconnect once the paired Mac
  is visible. The
  existing Noise channel still authenticates and encrypts every Kaisola frame
  over the Tailscale connection.
- Kaisola Link is the automatic off-network fallback. Each signed-in app gets a
  separate one-use ticket, then a hibernating relay forwards only bounded opaque
  encrypted bytes. It cannot read terminal output, prompts, commands, or keys,
  and it stores no transcript. The same paired identity, grants, replay cursor,
  command receipts, and terminal leases remain authoritative.

Home and Sessions use the timestamp of the latest agent or CLI response—not
session creation—and only label a session Running while it is actively
responding. Terminal cards also carry a separate exact last-finished clock, so
new output never masquerades as a completed CLI turn. Activity is grouped by
desktop window and project. Agent transcripts and terminal streams follow new
output to the bottom while preserving manual scrollback.

## Away-from-office access

Kaisola Link works automatically when both apps are signed into the same
Kaisola account:

1. Keep **Kaisola → Settings → Companion** enabled and both apps signed in.
2. Keep the Mac awake, online, and Kaisola running. The paired phone reconnects
   over Wi-Fi or cellular and can use only its existing grants.

For a private route, install Tailscale on the Mac and iPhone and connect both to
the same tailnet. A self-hosted Headscale server works through the same Tailscale
clients by changing their control server. Once connected, Kaisola detects that
route automatically and still prefers local LAN first.

No inbound router rule or public port is needed. If the Mac sleeps, shuts down,
quits Kaisola, or loses the internet, it is unreachable until that condition
clears. A closed MacBook lid normally sleeps unless macOS is deliberately
running it in a supported awake/clamshell setup.

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

## TestFlight release

Archive with automatic signing, then export with `ExportOptions.plist`. Its
upload destination sends the validated archive directly to App Store Connect;
the plist intentionally contains no credentials.
