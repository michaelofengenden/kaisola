# Kaisola Companion

This is the native, iPhone-first Kaisola Companion. It signs in with the same
Firebase/Google account as the desktop, pairs to a specific Mac with a signed
short-lived offer and four-word verification, and mirrors the live board,
agent transcripts, and read-only terminal streams over an encrypted LAN link.

The current release is deliberately observe-only with respect to the Mac.
Terminal viewing remains live, but prompt, permission, and terminal-control
commands stay disabled until the desktop capability and lease gates ship.

Pairing has three coordinated paths:

- “Find my Mac” retrieves the Mac's short-lived signed offer through the same
  authenticated account. The actual data connection remains local and
  end-to-end encrypted; Firebase never receives terminal content or keys.
- QR embeds the current direct LAN address and port for immediate connection.
- Bonjour remains active as discovery and reconnect fallback when an address
  changes. Transient reconnects replay from the in-memory acknowledged cursor
  and restore active terminal subscriptions; a cold launch requests a coherent
  fresh snapshot.

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
