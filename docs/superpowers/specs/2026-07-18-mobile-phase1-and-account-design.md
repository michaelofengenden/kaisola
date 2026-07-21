# Kaisola Companion — Phase 1 completion, account sign-in, and ChatGPT-class UX

**Date:** 2026-07-18
**Builds on:** `2026-07-17-mobile-companion-design.md` (system design) and Tasks
8–9 (desktop pairing spine + settings, both shipped). Turns the fixture-only
iOS preview into a real, signed-in, LAN-paired read-only companion that feels
like the ChatGPT/Codex iPhone apps.

## Goals

1. **Task 10** — real iOS security, transport, and protocol layers replacing the
   fixture store: Keychain identity, the Noise XX handshake (consuming the
   published Node vectors), Bonjour discovery, framed `NWConnection` transport,
   and snapshot/delta reconciliation.
2. **Task 11** — a polished read-only mobile experience: pairing, a signed-in
   home, agent transcript, terminal view, and correct foreground/background
   lifecycle.
3. **Account sign-in / sign-out** — Google account login tying the phone to the
   same Kaisola/Firebase identity as the desktop, so "your agents" are yours.

## Account architecture (no new config)

The desktop already authenticates with **Firebase Identity Toolkit REST**
(`accounts:createAuthUri` → Google OAuth in the system browser →
`accounts:signInWithIdp` → `{idToken, refreshToken, localId}`), then mints a
Kaisola session at the `session` Cloud Function. Project `kaisola-a9ab7`; the
Auth-only API key is already public in `electron/firebase-config.json`.

iOS mirrors this exactly — **no Firebase or GoogleSignIn SDK, no
GoogleService-Info.plist**:

- `ASWebAuthenticationSession` drives the Google OAuth redirect to a custom
  scheme (`kaisola://auth`), registered as a URL type.
- `URLSession` calls the same Identity Toolkit REST endpoints with the bundled
  Auth config (mirrored into the iOS bundle from the desktop config).
- The **refresh token lives in the Keychain** behind device authentication;
  the short-lived idToken is exchanged for a Kaisola session and refreshed on
  demand. Sign-out clears the Keychain, the session, and the local cache.
- Account identity does **not** authorize the device channel. It can now act as
  a rendezvous: while the desktop pairing sheet is open, the Mac publishes its
  signed, short-lived LAN offer under the authenticated Firebase UID and the
  iPhone can retrieve it with “Find my Mac.” QR remains available. In both
  cases the same Noise XX handshake, pinned desktop identity, and four-word SAS
  authorize the Mac; Firebase never relays terminal data, private keys, or a
  durable control credential.

## UX direction — ChatGPT/Codex-class, native, thumb-first

The current app is a functional preview. The redesign makes it read like a
first-party Apple app the way ChatGPT/Codex mobile do.

**Signed-out:** a single calm sign-in screen — Kaisola mark, one line of
promise ("Your agents, from anywhere"), one primary "Continue with Google"
button. No chrome.

**Signed-in shell:** a bottom structure, not a desktop clone:
- **Home** — the operational answer first: a compact "Needs you" band, then
  running sessions, then recent. One column, large tap targets, generous
  spacing, SF Pro, subtle depth. Pull-to-refresh; live connection pill.
- **Sessions** — every agent/terminal session across projects, grouped by
  project, searchable.
- **Agent transcript** — message-bubble layout like ChatGPT: user right,
  assistant left, collapsed reasoning/tool rows, streaming assistant deltas,
  a sticky composer that is **view-only in this phase** (no send until control
  ships) with a clear "Controlling from your Mac" affordance.
- **Terminal** — SwiftTerm read-only, monospace, fit to width.
- **Settings** — signed-in identity row (avatar/email), the paired Mac with
  connection state, per-device capabilities, "Unpair", and **Sign out**.

**Motion & feel:** restrained. A soft connection-state transition, streaming
text that types in, haptic on a "needs you" arrival, respects Reduce Motion.
Native large-title nav, `.searchable`, SF Symbols, Dynamic Type from day one.

**Pairing:** a camera QR scan (VisionKit `DataScannerViewController`), then the
four-word SAS confirmation matching the desktop, then a success state. Denied
local-network / camera permissions get an explicit recovery path.

## Delivery split

- **Codex (write):** Task 10 Security/Transport/Protocol Swift + tests; then the
  Firebase-REST `AuthService` + Keychain session store. Load-bearing, spec-tight
  engineering.
- **Claude (design + build):** the SwiftUI experience (sign-in, home, transcript,
  terminal, settings, pairing), the visual system, and integration — the
  "looks and feels good" surface. A GPT-5.6 sol design-collab pass informs it.
- **Both, then review:** dual review (Codex adversarial + a Claude pass on an
  `opus` fan-out, per the >10-agent model policy) before the milestone lands.

## Verification

- Swift unit tests: crypto vectors decrypt/verify identically to Node; every
  protocol fixture decodes; replay/tamper rejected.
- `xcodebuild build` and `test` on an iOS simulator, both themes, Dynamic Type.
- A loopback integration where feasible (simulator client ↔ a real Mac
  `enable()` listener) to prove snapshot + live delta + reconnect.
- Security review (tracked, blocking) gates any future control capability.

## Out of scope here

Control (prompt/steer/terminal input — Phase 2), LAN-first/Tailscale remote
access + APNs (Phase 3), Android. This milestone is the signed-in, LAN,
read-only alpha.
