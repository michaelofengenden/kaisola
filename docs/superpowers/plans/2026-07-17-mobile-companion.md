# Kaisola Mobile Companion — implementation plan

**Goal:** deliver a native iPhone companion that observes and safely controls
the exact agent and terminal sessions running in Kaisola on the Mac.

**Design:** `docs/superpowers/specs/2026-07-17-mobile-companion-design.md`

**Sequence:** protocol spine → same-network read-only iPhone alpha → guarded
control → LAN-first multipath remote access and push → release hardening. Do not start with a broad
mobile UI clone or expose an existing local port.

## Global invariants

- The Mac is authoritative for projects, ACP sessions, permissions, PTYs, and
  policy. The phone never talks directly to provider CLIs or MCP.
- Existing desktop behavior remains green after every task.
- No mobile observer may adopt/steal the renderer's terminal owner.
- Every service lookup includes the immutable project id and target id.
- Permission response is exactly-once and fail-closed.
- No terminal/agent plaintext enters network diagnostics, analytics, crash metadata, or
  push payloads.
- No unbounded replay/event/output queue.
- All code-facing protocol additions include Node fixtures; cross-language
  additions also include Swift fixture tests before control ships.
- Release only after live Electron smoke plus real-device/TestFlight journeys.

## Phase 0 — contract and desktop spine

### Task 1: Canonical protocol, redaction, and deterministic fixtures

**Add:**

- `electron/companion/protocol.cjs`
- `electron/companion/protocol.test.cjs`
- `electron/companion/fixtures/*.json`
- `electron/companion/redaction.cjs`
- `electron/companion/redaction.test.cjs`

Implement:

- protocol version/capability negotiation;
- validated event/command/receipt envelopes;
- explicit event and command allowlists from the design;
- command-id and sequence validation;
- redaction helpers that accept only a normalized projection, never a raw store;
- golden fixtures for hello, snapshot, terminal output, agent delta, permission,
  command receipt, stale revision, and protocol mismatch.

Reject unknown command kinds, missing project scope, oversized fields, control
characters in ids, payloads over the declared cap, and major-version mismatch.

**Verify:** focused Node tests; fuzz-shaped invalid envelopes; `npm run build`.

### Task 2: Main-owned companion event log and idempotent command receipts

**Add:**

- `electron/companion/eventLog.cjs`
- `electron/companion/eventLog.test.cjs`
- `electron/companion/commandCache.cjs`
- `electron/companion/commandCache.test.cjs`

Implement a byte-and-count-bounded monotonic event log per desktop epoch. A
reconnect supplies its last ACK and receives either the available suffix or a
snapshot-required result. Implement a time/count-bounded command receipt cache.

Tests must cover slow clients, ACK pruning, event-gap snapshot fallback,
duplicate command replay, stale epochs, and wrap/restart behavior.

**Verify:** focused tests; heap remains bounded under a synthetic million-event
run; `git diff --check`.

### Task 3: Safe `CompanionProjection` from renderer to main

**Touch:**

- `src/store/store.ts`
- `src/App.tsx`
- `src/lib/bridge.ts`
- `electron/preload.cjs`
- `electron/main.cjs`

**Add:**

- `src/lib/companionProjection.ts`
- `src/lib/companionProjection.test.ts` or an Electron probe-shaped test
- `electron/companion/projectionStore.cjs`
- `electron/companion/projectionStore.test.cjs`

Define a small projection containing project/session/attention/turn display
state. Publish only on meaningful revision changes and pagehide. Main validates,
bounds, and persists the last projection under a dedicated DB key per window.

Do not include raw settings, provider homes, env, auth, MCP config, API keys,
arbitrary file buffers, or full Zustand state. Main labels persisted-only data
`stale` until a renderer confirms the current epoch.

Merge terminal/ACP facts later from their authorities; do not let renderer
claims overwrite a known main-side live/exit state.

**Verify:** projection snapshots for active/background projects; forbidden-key
test; byte-cap test; multi-window store-key isolation; `npm run build`; smoke.

### Task 4: Non-owning terminal subscriptions with byte cursors

**Touch:**

- `electron/ipc/terminalSpool.cjs`
- `electron/ipc/terminalManager.cjs`
- `electron/session-broker.cjs`
- `electron/ipc/sessionBrokerClient.cjs`
- `electron/ipc/terminalHandler.cjs`

**Add/extend tests:**

- `electron/terminalSpool.test.cjs`
- `electron/terminalManager.test.cjs`
- `electron/sessionBrokerClient.test.cjs`
- `electron/session-broker.probe.cjs`

Add `streamEpoch`, total UTF-8 byte count, and snapshot start/end offsets. Add
broker `terminal.subscribe` / `terminal.unsubscribe` requests that require an
exact project capability but never call `setSender`, toggle renderer visibility,
or affect release ownership. Fan out structured data/exit/activity events to
subscribers with bounded per-subscriber backpressure.

Keep the current renderer raw-string channels compatible. Companion subscribers
receive offset-aware events. On a gap or slow consumer, emit snapshot-required
and discard queued deltas.

Tests must prove:

- phone observer does not change `owner`, `lastOwner`, visibility, or release;
- desktop and observer see the same ordered output;
- UTF-8 offsets never split a code point;
- detached/spooled output reconnects from a cursor or bounded snapshot;
- another project cannot subscribe, write, resize, signal, or inspect;
- broker restart/reattach retains the declared continuity semantics.

**Verify:** focused tests; `npm run broker:probe`; `npm run build`; Electron smoke.

### Task 5: Renderer-neutral ACP session and permission service

**Refactor:** `electron/ipc/acpHandler.cjs` without changing provider behavior.

**Add:**

- `electron/ipc/acpSessionService.cjs`
- `electron/acpSessionService.test.cjs`

Move connection lookup, normalized subscriber events, prompt/steer/cancel, and
permission response into methods that take an explicit actor capability. Keep
IPC registration as an adapter.

Store the sanitized permission display payload with its resolver in main.
Desktop and companion subscribers receive the same requested/resolved events.
The first valid response atomically removes it; late/replayed responses get a
stable resolved/stale receipt. Sensitive-path and autonomy behavior stays
exactly as today.

Do not widen the exported test-only maps into production API. Do not construct a
fake `WebContents` for the mobile actor.

**Verify:** existing ACP tests; two-subscriber streaming; exactly-once response;
agent death/timeout/cancel clears both surfaces; project mismatch fails;
renderer transfer/restart safety tests; build; group probe; smoke.

### Task 6: Shared attention authority

**Add:**

- `electron/ipc/attentionService.cjs`
- focused tests

Move durable attention events—not visual layout—into main: permission requested,
agent/terminal completed, agent failed, ledger review/blocked. Keep renderer
`needsYou` as a projection/acknowledgment surface during migration. Event ids
must dedupe desktop notification, phone state, and future APNs requests.

Acknowledging a visible session clears the exact event across surfaces without
clearing unrelated projects. Attention survives a renderer swap and remains
bounded.

**Verify:** active/background project cases, two windows, duplicate completion,
ack by phone then desktop, restart from persisted projection, current attention
handler tests, smoke.

### Task 7: Companion Gateway core and loopback harness

**Add:**

- `electron/companion/gateway.cjs`
- `electron/companion/stateHub.cjs`
- `electron/companion/commandRouter.cjs`
- `electron/companion/loopbackTransport.cjs`
- focused tests and `electron/companion-probe.cjs`

Wire projection, terminal, ACP, attention, and ledger adapters into one gateway.
Implement observe-only sessions first. Then wire command routing behind device
capabilities, leaving `terminal-control` and `agent-control` disabled in the
loopback device record until their later phase.

The harness must open a real Electron window and PTY, connect a loopback client,
receive a coherent snapshot and live output, disconnect, produce more output,
reconnect by cursor, and verify desktop ownership never changed.

**Exit gate for Phase 0:** focused tests, typecheck/build, broker probe, companion
probe, group probe, and full Electron smoke all pass.

## Phase 1 — same-network read-only iPhone alpha

### Task 8: Pairing identity and direct encrypted transport

**Desktop add:**

- `electron/companion/deviceStore.cjs`
- `electron/companion/pairing.cjs`
- `electron/companion/crypto.cjs`
- `electron/companion/bonjourTransport.cjs`
- tests with golden crypto vectors

Implement separate desktop/device identity keys, single-use expiring QR payload,
short authentication phrase, HKDF-derived directional keys, ChaCha20-Poly1305
frames, sequence replay protection, capability records, and revocation. Protect
desktop private material with `safeStorage`; never persist a pairing secret.

Advertise `_kaisola._tcp` only while Companion is enabled. Bind the service to
local interfaces, but rely on protocol authentication rather than IP trust.
Malformed/unauthenticated clients get bounded work and no state oracle.

### Task 9: Desktop Companion settings

**Touch:** Settings/store/preload/bridge/main and shell CSS.

Add a Companion pane with:

- disabled-by-default service toggle;
- connection/diagnostic state;
- pair-device action and QR sheet with expiry;
- requested capabilities with `observe` default;
- paired device rows, last seen, granted capabilities, and revoke;
- explicit warning that terminal control can execute commands on the Mac.

No raw keys, tokens, ports, or internal paths appear in diagnostics/copy.

**Verify:** settings persistence, expiry, revoke-live-device, accessibility,
light/dark/solid/live-glass layouts, build, layout probe, smoke.

### Task 10: Native iOS project and shared fixture tests

**Add:** `mobile/KaisolaCompanion/` as an Xcode project/workspace with SwiftPM.

Initial modules:

- `App`: SwiftUI lifecycle and dependency assembly;
- `Protocol`: Codable envelopes, validation, golden fixtures;
- `Security`: Keychain identity, pairing, crypto, replay counters;
- `Transport`: Bonjour discovery, `NWConnection`, reconnect state machine;
- `Store`: projects/sessions/attention/snapshot reconciliation;
- `Features`: Pairing, Now, NeedsYou, AgentSession, TerminalSession, Devices;
- `UI`: shared tokens/components matching Kaisola without desktop glass effects.

Add SwiftTerm via a pinned SwiftPM revision after license and maintenance review.
Wrap its UIKit view in `UIViewRepresentable`; do not build a homegrown terminal
emulator.

Golden Node/Swift tests must encrypt/decrypt the same frames, reject tampering,
reject a repeated counter, and decode every protocol fixture identically.

### Task 11: Read-only mobile UI and lifecycle

Implement pairing, Now, Needs You, agent transcript, and terminal view. The app
streams only in foreground, disconnects cleanly on background, reconnects with
the last ACK, and shows cached state as stale/offline.

Terminal attach replays one bounded snapshot into a reset SwiftTerm instance,
then applies ordered deltas. A cursor gap resets from a replacement snapshot.
Do not persist more than the stated cache budget; apply complete file protection
to any durable cache.

**Real-device journeys:**

- pair/revoke/re-pair;
- watch Codex and Claude terminal sessions;
- watch an ACP structured turn and permission appear;
- background for 2 minutes while output continues, then recover;
- turn Wi-Fi off/on;
- lock/unlock device;
- desktop renderer swap/restart while PTY continues;
- VoiceOver navigation, Dynamic Type, light/dark, 390×844 and larger iPhones.

**Exit gate for Phase 1:** TestFlight/internal device build plus desktop full
suite; read-only companion works for a day of real sessions without stealing,
forking, leaking, or growing unbounded memory.

## Phase 2 — guarded control

### Task 12: Device capabilities, Face ID, and control receipts

Implement desktop-side grants for `agent-control` and `terminal-control`. iOS
requires LocalAuthentication before entering control mode after inactivity.
Every command is optimistic only after an accepted receipt and reconciles on
applied/rejected result.

Revocation, backgrounding, desktop lock preference, or lease expiry immediately
disables input. Observe remains available only if still granted.

### Task 13: ACP prompt, steer, cancel, and permission decisions

Wire mobile actions only through `AcpSessionService`. Preserve one-turn
serialization, provider queue capability checks, read-only mode constraints,
sensitive-file handling, and cancel watchdog behavior.

Permission UI shows actual options/diffs and sends the exact permission revision.
Only allow-once/reject. Resolution fans out to desktop and phone.

**Verify:** real Codex ACP and Claude ACP; phone/desktop simultaneous response;
stale/replayed response; timeout; agent death; cancel during ask; background
project; multi-window transfer; no cross-project action.

### Task 14: Terminal control lease and mobile keyboard

Add an expiring per-terminal companion control lease. Desktop remains owner and
continues to render. Only the lease holder can send input/resize/interrupt.
Desktop shows a quiet “controlled from Michael's iPhone” indicator and can revoke
immediately.

Use SwiftTerm input callbacks, an explicit mobile control toggle, accessory
keys, bracketed-paste-aware multiline preview, and a size cap. V1 does not expose
kill, release, or arbitrary terminal creation.

**Verify:** shell, Codex TUI, Claude TUI, full-screen TUI, Unicode/emoji, resize,
Ctrl-C, large paste refusal, lease race/expiry, disconnect mid-input, phone and
desktop typing, cross-project denial, and output order.

**Exit gate for Phase 2:** a real agent can be prompted, steered, stopped, and
permissioned; a real terminal can be controlled; every race has a deterministic
receipt and no duplicated command.

## Phase 3 — automatic remote access and APNs

### Task 15: Stable LAN-first listener and signed private route — implemented

Keep Bonjour and the signed LAN endpoint as the primary path. Listen on a stable
port when available, detect a local Tailscale interface without shelling out,
and include that private address only in signed/authenticated transport hints.
If the stable port is unavailable, preserve LAN on an ephemeral port and fail
closed by omitting the remote hint.

The authenticated desktop hello refreshes the hint for an existing paired
phone. Renderer state may expose only route availability—not the address or
listener port.

**Verify:** fixed-port success and collision fallback; LAN address excludes the
tailnet interface; signed hint validation; existing-pair hello refresh; no raw
private address in renderer state.

### Task 16: iOS LAN-first multipath route election — implemented

Use the same `NWConnection` framing and Noise channel on both endpoints. Keep
Bonjour active, prefer the paired Mac on the LAN, fall back to the signed
Tailscale endpoint after a bounded failure or immediately on cellular, remember
that route through reconnects, and prefer Bonjour again once the Mac is visible.

Kaisola Link is the automatic third path when LAN and the optional private route
are unavailable. The phone and Mac authenticate separately with the existing
Firebase session, exchange one-use tickets, then run the unchanged framed Noise
channel through an opaque WebSocket multiplexer. No router forwarding or public
Mac listener is involved. Remote reachability requires the Mac awake and online
with Kaisola open and Companion enabled.

**Verify:** direct, tailnet, and Link endpoint fixtures; Wi-Fi/cellular path
changes; stale office address; app kill/foreground; Mac sleep/wake; Tailscale
direct and DERP connection types; relay reconnect/replacement; revoke while
remote; bounded replay continuity.

### Task 17: Kaisola Link blind relay — implemented

Deploy one hibernating Durable Object per pseudonymous account key. Verify each
ticket request with the existing Firebase session service, issue random one-use
60-second tickets, and cap tickets, peers, message size, and buffered bytes. The
relay sees routing metadata and ciphertext sizes/timing only; it never receives
Noise keys, terminates the companion protocol, stores transcripts, or retries
commands. Desktop and iPhone reconnect clients retain the same grants, replay
cursors, command receipts, and terminal leases used on direct TCP.

**Verify:** ticket replay rejection; cross-account isolation; role and identifier
validation; binary framing and slow-consumer bounds; desktop replacement; relay
restart; encrypted end-to-end session through a deployed room.

### Task 18: APNs attention hints — pending

Add APNs registration, privacy-safe notification categories, and deep links to
current session state. Push is a wake-up/attention hint only: it carries no
terminal output, prompts, diffs, paths, secrets, or authoritative completion
state, and opening/foreground reconciliation remains mandatory.

**Chaos matrix:** Wi-Fi↔cellular, Tailscale direct↔DERP, VPN on/off, Mac
sleep/wake, Electron restart, phone kill/relaunch, delayed/missing/duplicate
push, revoked device, expired Firebase token, version skew.

**Exit gate for Phase 3:** remote anywhere works across the chaos matrix;
diagnostics and push logs contain no session plaintext; battery and bandwidth stay within
the recorded budget.

## Phase 4 — release hardening

### Task 18: Security and privacy review

- Threat-model review against the design table.
- Cross-language crypto test vectors and dependency audit.
- Lost-phone/revoke drill and account-revocation drill.
- Terminal escape/OSC/link fuzzing.
- Connection log/crash/analytics redaction audit.
- iOS Data Protection, Keychain accessibility, backup exclusion, screenshot/app
  switcher privacy choice, and Face ID fallback review.
- External review before enabling terminal control beyond a small alpha.

### Task 19: Performance, accessibility, and product polish

Measure—not infer—local/remote latency, reconnect loss, desktop idle CPU/memory,
phone energy, cache sizes, and direct/tailnet/Link bandwidth. Add support diagnostics that are
useful without exposing secrets.

Complete one-handed ergonomics, Dynamic Type, VoiceOver, Reduce Motion, color
contrast, hardware keyboard, iPad layout, notification privacy, and clear
offline/stale language.

### Task 20: Staged distribution and release

1. Internal signed iPhone build and local alpha.
2. TestFlight read-only alpha.
3. TestFlight guarded-control alpha for explicitly granted devices.
4. Multipath remote-access beta, followed by privacy-safe push.
5. App Store/privacy disclosures and desktop release only after compatibility
   gates are automated.

Desktop compatibility tests must keep at least the current and previous mobile
protocol minor versions usable during staged rollout. A breaking major version
shows an update-required state and grants no control.

## First implementation checkpoint

The next coding pass should stop after **Tasks 1–2 plus the terminal-cursor
design test fixtures for Task 4**. That is the smallest slice that validates the
protocol, bounded replay, and idempotency before a network listener or Xcode UI
creates momentum around an unsafe contract.

Checkpoint deliverables:

- reviewed protocol fixtures;
- bounded event log and command cache tests;
- explicit redaction allowlist;
- terminal cursor/snapshot fixtures covering UTF-8 and truncation;
- no externally reachable listener and no release yet.

### Checkpoint status — 2026-07-17

Complete. The repository now has the versioned envelope contract, normalized
and allowlisted board projection, golden frames, bounded monotonic replay log,
TTL/LRU idempotent receipt cache, and UTF-8 byte cursor/snapshot primitives.
Focused tests cover malformed frames, redaction and byte caps, slow-client gaps,
ACK pruning, stale epochs, sequential and concurrent command duplication,
million-event retention bounds, emoji offsets, truncation, and resume resets.

The implementation intentionally has no network listener, pairing endpoint,
live terminal ownership changes, or iOS target yet.

## Second implementation checkpoint

### Checkpoint status — 2026-07-17

Complete. Task 3 now publishes only meaningful, normalized renderer revisions
to a main-owned per-window store. Main revalidates every payload, fences old
renderers during reload/window swaps, marks closed or prior-epoch projections
stale, merges moved projects without duplicates, and deletes the projection in
the saved-window transaction. Sensitive permission diffs, absolute paths,
terminal commands, raw settings, credentials, environments, and file buffers
do not enter this projection.

Task 4 now gives each PTY a stream epoch and monotonic UTF-8 byte offsets.
Same-project observers receive bounded output/activity/exit events, reconnect
from a cursor or snapshot, and pause behind a single snapshot-required marker
when their socket queue is full. Subscribe/unsubscribe never calls `setSender`,
changes renderer visibility, cancels release, or mutates `owner`/`lastOwner`.
The broker probe verifies desktop/observer output agreement, cursor resume,
cross-project denial, and unchanged ownership.

The main process also has a listener-free observation hub that folds published
window projections and terminal observer events into the bounded replay log.
No socket is opened and no renderer IPC exposes observer subscription.

The next checkpoint is Tasks 5–7: make ACP sessions and permissions
renderer-neutral, consolidate the main-owned attention authority, and put the
gateway behind a loopback-only harness. A disconnected, fixture-only SwiftUI
shell may iterate the product experience in parallel, but it must not grow a
transport, pairing identity, or live-control path until those authorities land.

## Third implementation checkpoint

### Checkpoint status — 2026-07-17

The observe-only gateway contract now exists behind a deterministic in-memory
transport. A first connection receives a coherent normalized snapshot; a
reconnect receives the ordered suffix from its acknowledged event cursor or a
fresh snapshot after a gap. The loopback queue is byte-bounded, closes a slow
consumer, and never opens a socket. Every agent/terminal command is rejected
because the preview device has only `observe` capability.

The native preview now lives at `mobile/KaisolaCompanion/`. It is a real
SwiftUI/Xcode target with Now, Needs You, Sessions, agent transcript, read-only
terminal, Devices, and pairing-preview screens. Its one-column Running / Needs
You / Done hierarchy is derived from the backlog reference. It decodes the
canonical Node snapshot fixture in Swift tests and uses richer in-memory demo
data for visual iteration.

This does **not** complete Tasks 5–11. Preview decisions and prompts mutate only
local demo state; there is no Bonjour service, network listener, pairing key,
credential, Keychain identity, terminal emulator dependency, or Mac command
path. The next production checkpoint remains Tasks 5–6 plus the full Task 7
Electron/PTy probe, followed by Task 8 encrypted pairing. The SwiftUI shell can
then switch from fixture data to the same validated state store without a UI
rewrite.
