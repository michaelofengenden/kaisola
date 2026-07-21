# Kaisola Companion

This is the native, iPhone-first Kaisola Companion. It signs in with the same
Firebase/Google account as the desktop, pairs to a specific Mac with a signed
short-lived offer and four-word verification, and mirrors live activity,
agent transcripts, and terminal streams over an encrypted LAN link. When both
devices use the same Tailscale network, that exact paired connection also works
away from the LAN without Cloud Run, router port forwarding, or a public
Kaisola endpoint. LAN remains the first choice.

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

Pairing and reconnect have four coordinated paths:

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

Home and Sessions use the timestamp of the latest agent or CLI response—not
session creation—and only label a session Running while it is actively
responding. Terminal cards also carry a separate exact last-finished clock, so
new output never masquerades as a completed CLI turn. Activity is grouped by
desktop window and project. Agent transcripts and terminal streams follow new
output to the bottom while preserving manual scrollback.

## Free away-from-office access

Tailscale Personal is sufficient for a single user and does not add a Kaisola
cloud bill:

1. Install Tailscale on the Mac and iPhone, then sign into the same Tailscale
   account on both.
2. Keep **Kaisola → Settings → Companion** enabled. Open the paired iPhone app
   once while it can still reach the Mac locally so it securely learns the new
   private route.
3. Keep the Mac awake, Tailscale connected, and Kaisola open. The phone can then
   view and control the same granted sessions over Wi-Fi or cellular from away.

No inbound router rule or public port is needed. If the Mac sleeps, shuts down,
quits Kaisola, signs out of Tailscale, or loses the internet, it is unreachable
until that condition clears. A closed MacBook lid normally sleeps unless macOS
is deliberately running it in a supported awake/clamshell setup.

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
