# Native Companion host — restoration plan

Supersedes `superpowers/plans/2026-07-17-mobile-companion.md`, which is written
against the archived Electron shell and should be treated as history. The
[design spec](superpowers/specs/2026-07-17-mobile-companion-design.md) remains
the requirements document; only its "Gateway lives in Electron main" and
"renderer projection" sections are invalidated.

## Why this is a port, not a rewrite

The scary half is already written. `native/KaisolaCore` contains 2,402 lines of
production Swift that **both** apps already consume, including the desktop side
of the handshake:

- `Security/NoiseXX.swift` — `NoiseXXResponder` hard-requires
  `identity.role == .desktop`, and `SecureFrameChannel` handles the desktop key
  directions. Verified against the same Node golden vectors the shipped iPhone
  was built against (`CompanionCryptoContractTests`, driven from
  `electron/companion/fixtures/crypto-noise-xx-v1.json`).
- `CompanionProtocol.swift` — the envelope, event/command tables, and the
  terminal output/cursor bodies.
- `LengthFraming.swift` — pinned to the Node framing cap.
- `PairingModels.swift`, `CompanionModels.swift` — including
  `CompanionProjection`, which is exactly the sanitized shape the phone renders.

`native/KaisolaMac/project.yml` **already links** KaisolaCore into the shipping
Mac app. Grepping the app target for any `Companion*` / `NoiseXX` /
`SecureFrameChannel` symbol returns zero hits: the wiring exists, the code is
dormant.

The iOS client is purely protocol-driven — it has no private copy of the
protocol and no Electron dependency. A Swift responder that speaks the same
bytes is indistinguishable to the phone.

Net new Swift for a working MVP: roughly **2,200–2,600 lines** of orchestration
and state. The Electron host is 6,422 lines, but a large share of it is crypto,
wire format, and mDNS that Swift either already has or gets from `Network`.

## Why in the app, not in the broker helper

Running the existing Node host inside the packaged broker helper is genuinely
cheaper on paper — every one of those 6,422 lines uses only Node stdlib, and the
helper already ships a signed Node 22 with the companion protocol files. It was
evaluated seriously and rejected:

1. Its main attraction — avoiding a Noise port — is moot, because that port is
   done and golden-vector tested.
2. The helper package is a hash-sealed closed inventory that **deliberately
   outlives the app across updates**. Adding a network listener and long-term
   pairing keys there puts new attack surface on the far side of a version-skew
   boundary.
3. It changes the security posture: a helper-hosted companion can serve a phone
   while Kaisola is quit. The spec's model is "Mac awake, Kaisola open".
4. It does not avoid the real work. The projection producer must be Swift either
   way, and ACP sessions run in the app process, unreachable from the helper.

So: a Swift `CompanionHost` in the app, with `electron/companion/*.cjs` kept
in-tree as the reference implementation.

## Phase 0 — Prove the phone still works (S, do first)

No new code. `npm run companion:pair-harness` builds the whole companion stack
standalone with a fixture projection and a synthetic terminal, and pairs a real
iPhone over LAN. Delivers: proof the shipped iOS app still pairs and streams,
plus a live reference to diff the Swift host against.

**2026-07-28 status:** the noninteractive `--print-qr-only` probe binds and
advertises the exact offer successfully. It does not constitute the real-iPhone
pair/stream proof, which remains a hardware gate.

## Phase 1 — Identity, pairing, LAN listener (M–L)

New, under `Kaisola/Companion/`:

- `CompanionIdentityStore.swift` — Ed25519 + X25519 via `CompanionIdentity`,
  private keys in the Keychain following `ApiKeyStore`'s accessibility pattern,
  device roster at `…/companion/devices.json` mode 0600.
- `CompanionListener.swift` — `NWListener` on 49321 with ephemeral fallback and
  `NWListener.Service(type: "_kaisola._tcp")`. **The instance name must be
  `Kaisola-<last 16 of desktopId>`** or the phone will never match its paired
  Mac. TXT record `v=1`, `id=<desktopId>`. Exclude Tailscale addresses from
  advertised A records.
- `CompanionPairingCoordinator.swift` — offer/nonce/expiry driving
  `NoiseXXResponder`, SAS via `CompanionSAS.derive`, dual confirmation.
- `CompanionConnection.swift` — length framing, the 4-phase pre-auth state
  machine, then `SecureFrameChannel(role: .desktop)`.

Modify `Kaisola/App/Info.plist`: add `NSLocalNetworkUsageDescription` and
`NSBonjourServices` (`_kaisola._tcp`). Both are absent today, and macOS 15+
silently denies the mDNS responder without them. No new entitlements.

**2026-07-28 status:** identity storage, the validated 0600 public roster,
bounded listener with 49321-to-ephemeral fallback, exact Bonjour name/TXT,
Info.plist declarations, length-framed connection deadline, and the strict
pair/resume coordinator are implemented in the working tree. A deterministic
phone/desktop transcript proves Noise XX, key confirmation, matching SAS,
encrypted paired receipt, roster persistence, and secure resume. Chunked socket
tests additionally prove the capability-bound hello transition, the 64 KiB
pre-auth cap, and rejection of commands outside the persisted grant. Settings now
owns explicit opt-in, QR generation, view/control capability selection, SAS,
and revoke. Ten focused checks complete with zero failures and one explicit
unsigned-host Keychain skip at that checkpoint; the Mac target builds and the
disabled Settings state passes visual inspection. The real-iPhone run remains
mandatory, and the listener never starts before user opt-in. The larger Phase
1+2 suite status is recorded below.

Frame contract the responder must honor: `pair.start`/`resume.start` →
`*.message2` → `*.message3` → `*.confirmation` → encrypted `sas-confirm` both
ways → encrypted `paired`. The desktop **must** then send its own `hello` with
`role: .desktop` and `observe` in capabilities, or the phone never subscribes.

Delivers: phone pairs with the shipping app and shows Live.

## Phase 2 — Projection + terminal streaming (M)

- `CompanionProjectionBuilder.swift` — `AppModel.projects/sessions` +
  `AttentionCenter` → `CompanionProjection`. Building the typed shape directly
  makes most of `redaction.cjs` (816 lines) structurally unnecessary: the type
  system is the allowlist. Keep the byte cap and a forbidden-key test.
- `CompanionEventLog.swift` — bounded `{epoch, seq}` log with replay/snapshot
  fallback.
- `CompanionTerminalStreamHub.swift` — its own `ObserveOnlyBrokerClient`.
  Broker subscriber identity is `client.instanceId + ownerId + projectId`, so
  the separate observer connection creates an independent subscription even
  while retaining the stable native owner for exact project authorization. The
  phone therefore cannot fight a desktop pane's subscribe/unsubscribe cycle.

**2026-07-28 status:** the multi-window projection producer, revision gate,
authenticated snapshot sender, bounded at-most-once command router, and
multiplexed terminal stream hub are implemented. The projection type cannot
represent cwd, prompts, environment, terminal bytes, or credentials; an
additional display scrubber rejects path/credential-shaped labels. Terminal
snapshots are capped to a UTF-8-safe 256 KiB tail without paging the Mac's
larger transcript, while deltas require exact epoch and contiguous byte
offsets. Receipt-before-snapshot ordering, two-phone fan-out over one broker
subscription, exact-project rejection, last-member cleanup, and broker-gap
reset are covered. The bounded 2 MiB/2,048-frame desktop epoch is now wired end
to end: the device hello carries its resume cursor, safe suffixes replay with
their original global sequences, ACKs are monotonic and cannot run ahead, and
epoch/pruning/audience gaps receive a coherent projection snapshot before a
fresh bounded terminal subscription. Terminal snapshots are sent as events to
match the shipped iPhone; the phone source also accepts the protocol-legal
snapshot-envelope spelling. After bounded-byte/load coverage and the
inventory/activity completion-race regression, the combined suite contains 36
tests: **35 passed, 1 explicit unsigned-Keychain skip, 0 failed**
(`.derived-companion/phase2-20260728-0212.xcresult`). The iPhone fixture suite
cannot currently execute because the installed Xcode 26.6 reports no eligible
iOS 26.5 platform destination (the changed mobile sources parse cleanly).
Remaining Phase 2 work is the real-iPhone pair/list/stream gate.

The desktop needs-you inbox is now a durable local counterpart to the remote
`attention.ack` path. It persists at most 50 validated entries in a 256 KiB
store, restores only the newest target/kind event, and durably clears when the
user visits a surface. This preserves an orange completed-project badge across
GUI restarts and signed-app replacement while leaving broker-owned
Working/Responded text unchanged. The hosted `attention-completed` fixture
visually proves the orange project count, Responded row, and global bell.

Delivers: phone lists real sessions and renders live terminal output — remote
monitoring works.

## Phase 3 — Control lease + input (M)

- `CompanionTerminalControl.swift` — 30s TTL, `leaseId` on every op, geometry
  capture/restore, 16 KiB input cap.
- A **narrowed** control façade exposing only `write`/`resize`/`interrupt`. Do
  not widen `ControlBrokerMethod` or hand it to the router: the broker token is
  full controller authority, including `terminal.kill` and `broker.shutdown`.
- `CompanionCommandRouter.swift` — capability gate plus a bounded idempotency
  cache keyed on device + `commandId`. The cache and observe-safe
  `attention.ack`/stream routes are already implemented in Phase 2; Phase 3
  extends the same router only through the narrowed lease façade.

**2026-07-28 status:** implemented. One lease is exclusive per PTY and bound to
device + authenticated connection + exact terminal + generation. Acquire,
renew, write, bounded resize, Ctrl-C, and release are routed through a four-op
adapter into the AppModel controller socket that the broker identifies as the
current exact owner; the phone cannot attach/adopt a PTY or represent create,
kill, terminal release, detach, or broker shutdown. Ctrl-C is the existing
sealed write path with byte `0x03`, so `ControlBrokerMethod` remains unchanged.
Broker inventory now carries authoritative rows/columns. Geometry restores on
explicit release, TTL expiry, disconnect, same-device connection replacement,
revoke, owner loss, terminal disappearance, and host shutdown, with a restore
barrier before reacquisition. AppKit resize callbacks are suppressed while the
lease is active. Fast host off/on turnover also waits for the old manager's
geometry restoration before installing new lease authority, and generation
fencing ignores late indicator callbacks. The expanded Phase 1–3 plus AppModel
reconnect and broker-ownership boundary suite is **68 passed, 1 explicit
unsigned-Keychain skip, 0 failed** across 69 tests
(`native/KaisolaMac/.derived-companion/phase3-combined-20260728-0227/Logs/Test/Test-Kaisola-2026.07.28_02-27-23--0700.xcresult`). Real-phone input and
lifecycle proof remains a shipping gate.

## Phase 4 — Settings, indicator, revoke (S–M)

`CompanionSettingsTab.swift` plus a QR sheet; add a `.companion` case to
`SettingsSection`. Build the **live-control indicator** — a quiet "controlled
from <device>" chip on the terminal surface. It was never built on either
platform and is a shipping requirement, not polish.

**2026-07-28 status:** the Settings opt-in, capability choice, QR/SAS flow,
device roster, and one-tap revoke are implemented. Active terminal cards and
sidebar rows expose **Controlled from <paired device>** and retain their safety
state through the geometry-restore barrier. Real leases resolve the
authenticated device ID against the paired roster and display its safe device
name; the isolated visual fixture intentionally falls back to iPhone. A dedicated
broker-free real-window fixture now covers the active state in the native visual
workflow; its 2720×1720 local capture shows the full device chip and sidebar
status without overflow. Manual VoiceOver confirmation and real-device
lifecycle QA still need a paired phone.

## Phase 5 — Authenticated relay (desktop live proof complete; device matrix pending)

`CompanionLinkClient.swift` is now the native desktop side of the deployed
Cloudflare Worker. It requests a short-lived desktop ticket with a fresh
Firebase ID token, accepts only a same-origin `wss:` response, and multiplexes
opaque virtual byte streams under the same 2 MiB message / 4 MiB buffered caps
as the Worker, Electron reference, and iPhone. The bearer token is used only on
the ticket POST and never appears in the WebSocket URL.

The host stores LAN and relay adapters behind `CompanionHostConnection`; both
terminate in `CompanionConnectionSession`. There is still only one Noise XX
handshake, account-partitioned device roster, capability gate, event log,
command router, terminal stream hub, and control-lease manager. The active
immutable account scope is authenticated in pairing and resume transcripts;
sign-out or account change rotates every authority surface before a replacement
host starts. A virtual socket bounds bytes that race ahead of host installation
and closes on overflow. The Settings surface reports nearby and Link state
separately.

The combined authority suite is **75 passed, 1 explicit unsigned-Keychain skip,
0 failed** across 76 tests
(`native/KaisolaMac/.derived-companion/phase4-link-combined-20260728-0319.xcresult`). It
includes ticket/body/TLS-origin contracts, mux boundaries, auth refresh,
sign-out channel teardown, and a real Noise resume + desktop hello across the
relay virtual stream. A subsequent signed browser end-to-end probe exposed a
real delivery-order race: adjacent key-confirmation and device-hello frames
were handed to separate unstructured tasks. Mux OPEN/DATA/CLOSE delivery is now
awaited in WebSocket order, with a deliberately delayed adjacent-frame
regression (**7/7 Link-client tests green**). Still required: a live same-account Mac/iPhone connection
through the production Worker, wrong-account denial, device revocation while
connected, Worker restart, sleep/wake, LAN-to-relay election, and network-switch
soak.

The Worker contract is 5/5 green, Wrangler's production dry-run passes, the
authenticated Electron reference round-trips 60 opaque bytes through the live
Worker, and the Firebase Function contract is 6/6 green. The native app also
carries an isolated production-route smoke mode: it creates no window, listener,
broker client, or PTY; uses a unique desktop ID; requires a real Team ID; and has
stage-specific process alarms that remain effective even if Security or another
framework blocks the main actor. An arm64 Release artifact signed with Developer
ID, hardened runtime, and deep signature verification reaches
`relay.desktop-ready` through its own native URLSession WebSocket. For this
proof, the existing desktop account supplies one fresh Firebase ID token only
in memory over an anonymous stdin pipe; the token never appears in argv,
environment, logs, disk, or the WebSocket URL. The exact universal artifact is
now installed as `/Applications/Kaisola.app`, version **0.1.132**, build
**15110**, with a timestamped Developer ID signature for team `KBD9RS8425`,
hardened runtime, passing release preflight, deep verification, launch probe,
and the browser-to-native production relay proof. The replacement adopted the
detached broker that had been running since 2026-07-27 23:23 and preserved its
two live PTYs (PIDs 40700 and 42996) plus the resumed Claude child. The full
native suite is **789 passed, 7 explicit unsigned-host Keychain skips, 0
failed** across 796 tests in the final build-15110 source gate.

Account startup no longer queries the historical ad-hoc Keychain item or waits
for its obsolete ACL. Developer-ID builds use the stable production service
`com.kaisola.mac.firebase-auth`; a one-time versioned migration marker shows a
clean re-login card and clears permanently after the next successful sign-in.
The signed artifact and installed app both return
`KAISOLA_NATIVE_LINK_SMOKE=AUTH_REQUIRED` immediately when that new namespace is
empty, rather than `STORAGE_TIMEOUT`/exit 124. Restore remains serialized off the
SwiftUI main actor, and the notice persists through an empty restore without
pretending the user is authenticated; **7/7 focused auth tests pass**. The live
installed Settings surface and broker-free 1620×1144
`settings-account-recovery` fixture show the expected recovery card without a
spinner, clipping, or stale prompt. One clean Google sign-in remains the human
gate, while the inaccessible historical item is deliberately left untouched.
The separate `settings-companion` fixture proves the final Nearby-ready,
Link-ready/active, pairing, and roster presentation and remains in the native
visual workflow.

Still deferred: Tailscale hint completion, ACP agent control and permissions,
browser command/control UI, and APNs push. The observe-only browser Noise client
is implemented, and its exact relay module round-trips 76 opaque bytes through
a same-account ticket from the production Worker. A broker-free Developer-ID
Swift artifact now also pairs that exact browser module through the production
Worker, completes Noise XX and mutual key/SAS confirmation, negotiates only
`observe`, sends a projection, and receives encrypted ACK sequence 1. It then
disconnects, resumes the pinned desktop without repeating SAS, negotiates a
replacement channel, receives projection revision/sequence 2, and returns
encrypted ACK sequence 2. The Mac then revokes the live browser from its 0600
roster, closes that channel, and requires a third pinned resume to fail pairing
authentication before the signed proof reports `revoke=denied`. The browser
contract independently reproduces the resume transcript and renewed
observe-only hello (**18/18 site tests green**). Human SAS comparison,
clean-browser deployment, user-driven Settings revocation, actual page-reload,
and network-loss recovery remain behind the live production matrix.

## MVP scope and what is deliberately cut

Ship: pair one iPhone over LAN by QR + SAS, see the real session list, stream
one session's live output, type into it under an explicit lease.

Cut, safely: Tailscale hint completion, ACP agent chat, APNs, and Board/ledger
fan-out. The relay source path is implemented but remains non-shipping until the
live production-Worker matrix above passes. Capability tiers remain reduced to
one explicit "Allow terminal control" switch.

Do **not** cut: the epoch/seq ACK cursor, terminal `streamEpoch` + byte offsets,
or the lease. All three are load-bearing on the shipped phone.

## Risks

- **Foreground-only.** iOS cannot hold the socket in the background until APNs
  lands. Streaming stops on background and reconciles on foreground. Say so in
  the product copy or it reads as broken.
- **A phone with terminal control has an unrestricted shell** with the user's
  full environment. The lease is not mutual exclusion by design — desktop and
  phone interleave like two people on one `screen`. Face ID gates acquire, not
  each write, and caches for 5 minutes. Mitigations that must ship: observe-only
  default, explicit per-device grant with a plain-language warning, the
  live-control indicator, and one-tap revoke that force-drops live connections.
- **Local-network TCC.** Deployment target is macOS 14 but 15+ enforces it, and
  a denied grant is not re-promptable in-session. Budget a "local network
  blocked" diagnostic state.
- **Application envelopes remain frozen at v1.** `CompanionEnvelope` rejects
  unknown fields. The pairing bootstrap now deliberately requires an opaque
  account scope in QR offers, resume starts, and Noise prologues; unscoped legacy
  rosters and phone tickets are not migrated and require a fresh pairing after
  both apps upgrade.
- **App Store.** Both LAN and Link pairing require the same restored
  Firebase/Google account so local transport cannot outlive the app's account
  authority. The complete platform-login and account-deletion review path is
  therefore required before App Store submission. Expect review friction on
  "remote terminal control"—have the capability model, live indicator, sign-out
  teardown, account-switch isolation, and one-tap revoke flow demoable.

## Parallel account continuity, then Kaisola on the web

The account-scoped remembered-session catalog can land before live control
because it contains only portable metadata. Its Firestore documents and the
`kaisola.com/app/` reader are discovery/index surfaces; neither gets terminal
bytes, filesystem access, provider continuation tokens, or command authority.
They must not grow into a second synchronization/control plane.

The browser is now another encrypted v1 protocol client over the deployed
Cloudflare WebSocket relay while the Mac host stays the sole projection producer
and command router. It carries the same signed pairing payload, Noise XX
initiator, key confirmation, SAS confirmation, length framing, device hello,
secure envelope counters, and ACK cursor as the iPhone. Firebase authentication
only mints the role-scoped relay ticket; the Noise-pinned per-connection identity
still supplies authorization. Per-account IndexedDB state stores non-extractable
Ed25519/X25519 keys and pinned Mac records without putting the raw Firebase UID
in the key. The browser intersects every Mac pairing grant down to `observe`
before persistence and sends only `observe` in its device hello, so a native
phone control grant cannot silently widen a browser resume. The first surface
is observe-only live projection: browser command
and terminal-control UX stays cut until the production pair/revoke/reconnect
matrix proves the transport and capability boundary end to end.
