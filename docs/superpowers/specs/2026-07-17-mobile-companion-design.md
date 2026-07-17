# Kaisola Mobile Companion — product and system design

**Date:** 2026-07-17

**Status:** desktop observation spine and fixture-only native preview complete;
live pairing and transport not started

**Working assumption:** iPhone first; the wire protocol remains platform-neutral

## Outcome

Kaisola Companion is a native phone surface for the sessions already running
on the user's Mac. It does not run agents or shells on the phone. The Mac stays
the execution and policy authority; the phone can securely observe and, when
explicitly authorized, control that existing state.

The useful promise is:

> Leave the desk without losing the thread. See what every agent and terminal
> is doing, get called back only when something needs you, respond with full
> context, and safely take over an existing session from your phone.

The first production-quality path is an iPhone app built with SwiftUI. A native
app gives Kaisola the right primitives for push notifications, protected key
storage, Face ID, background/foreground lifecycle, local-network discovery, and
a real terminal emulator. Android and web clients can later implement the same
companion protocol.

## Product principles

1. **One session, two surfaces.** Desktop and phone never fork an agent context
   or create competing terminal ownership. They are views/controllers over the
   same Mac-owned session.
2. **Attention before remote desktop.** The home screen answers “what is
   running, what finished, and what needs me?” before showing a wall of terminal
   text.
3. **Honest connection state.** Offline, reconnecting, sleeping Mac, stale
   snapshot, and live are distinct states. Cached data is never painted as live.
4. **Fail closed.** A missing desktop, expired pairing, replayed command,
   unknown project, stale permission, or protocol mismatch cannot widen access.
5. **No secret tunnel disguised as convenience.** Electron IPC, the private
   session-broker token, provider credentials, MCP bearer tokens, and raw store
   blobs never cross the companion boundary.
6. **Mobile actions are receipts.** Every action has an idempotency key, target,
   scope, result, and visible audit receipt.
7. **Bounded by design.** Terminal history, replay buffers, mobile cache, relay
   queues, and notification frequency all have explicit caps.

## V1 experience

### 1. Now

The default screen is a compact operational dashboard:

- Mac connection state and last contact time.
- Projects with counts for running, needs-you, completed, and failed sessions.
- A prioritized **Needs You** section for ACP permissions, agent questions,
  failures, and review/blocked ledger tasks.
- Running session cards showing provider, project, branch, elapsed time, and a
  quiet last-activity preview.
- Recently completed sessions, with unread state shared with the desktop.

The phone is not a miniature copy of the desktop shell. It is a deliberate
one-column control surface.

### 2. Agent session

- Structured user, assistant, thought, and tool turns.
- Streaming assistant deltas while the app is foregrounded.
- Collapsed reasoning/tool detail by default; diffs and permission context can
  be expanded before a decision.
- Composer supports a normal prompt and mid-turn steer where the provider does.
- Stop is always visible while a turn is active.
- Context usage, working time, model, mode, and connection status are secondary
  metadata rather than chat noise.

### 3. Terminal session

- Native xterm/VT rendering through SwiftTerm, fed by the existing Mac PTY.
- Full-screen read mode first; tap to enter an explicit control mode.
- Mobile accessory row: Escape, Control, Tab, arrows, slash, and interrupt.
- Paste preview for multiline input, with a second confirmation for unusually
  large pastes.
- Resize follows the phone terminal viewport without changing the desktop
  viewport unless the phone holds the control lease.
- Exit, reconnect, truncated-history, and stale-snapshot states are visible.

### 4. Permission decision

- Agent, project, tool title, affected paths, options, and actual diff content.
- Allow-once or reject only in V1. The phone cannot create persistent permission
  rules or silently promote autonomy.
- The first valid response wins atomically; every other surface immediately
  receives a resolved event.
- Notifications open this screen. V1 does not put an **Allow** action directly
  on the lock screen, where the user lacks enough context.

### 5. Pairing and devices

- Desktop Settings → Companion shows an enable toggle, QR code, short expiry,
  and the requested capability set.
- The phone signs into the same Kaisola account for remote mode, scans the QR,
  then both surfaces confirm the same short authentication phrase.
- Each phone is a separately named and revocable device.
- Capabilities are independent: `observe`, `agent-control`, and
  `terminal-control`. Pairing defaults to `observe`; widening is a desktop-side
  choice.
- Face ID/app passcode protects re-entry to a paired control surface.

## Explicit non-goals for the first release

- Running provider models, shells, builds, or git directly on iOS.
- A general remote filesystem editor or unrestricted project download.
- Exposing the built-in MCP server, Electron preload bridge, Firebase refresh
  token, session-broker socket, or broker bearer to the phone.
- Starting arbitrary new shells remotely. V1 controls already-open sessions;
  remote creation comes only after the audit and capability model is proven.
- Background terminal streaming. The foreground app streams; APNs carries
  bounded attention events while the app is backgrounded.
- Multi-user/team sharing. The first trust model is one account with paired
  personal devices.

## Existing Kaisola seams

Kaisola already owns most of the hard local runtime pieces:

| Concern | Current authority | Companion work |
|---|---|---|
| Durable PTYs | `electron/session-broker.cjs` + `terminalManager.cjs` | Add non-owning subscriptions and byte cursors; never expose its token |
| Scrollback | `terminalSpool.cjs` | Return offset-aware bounded snapshots and gap state |
| Terminal metadata | `terminalHandler.cjs` poller | Publish normalized project/session metadata through a service |
| ACP sessions | `acpHandler.cjs` | Extract renderer-neutral session commands and event fan-out |
| ACP permissions | Main-process pending map + renderer cards | Make sanitized pending detail main-authoritative and multi-surface |
| Structured turns | Renderer store + `assistantArchive.cjs` | Publish a mobile projection and reuse archive paging |
| Attention | Renderer `needsYou` + native Mac notifications | Move the event authority into a shared attention service |
| Agent ledger | `ledgerHandler.cjs` | Reuse exported functions and existing project scope |
| Account identity | Firebase Auth + verified `session` Cloud Function | Register mobile/desktop devices under the verified UID |

The built-in MCP server is deliberately not the mobile API. It is loopback-only,
agent-shaped, and carries project bearer capabilities intended for local agent
tools. The companion surface gets its own smaller protocol and threat model.

## Architecture

```text
┌──────────────────────── iPhone ────────────────────────┐
│ SwiftUI                                                │
│ Now · Needs You · Agent Chat · SwiftTerm · Devices     │
│ Keychain identity · Face ID · bounded local cache      │
└───────────────────────┬────────────────────────────────┘
                        │ companion protocol
                 E2EE frames + receipts
              ┌─────────┴──────────┐
              │                    │
       direct LAN transport   opaque relay transport
       Bonjour + NWConnection  WSS + Firebase identity
              │                    │
              └─────────┬──────────┘
                        │
┌───────────────────────┴────── Mac ─────────────────────┐
│ Companion Gateway (Electron main)                      │
│ pairing · capabilities · state projection · audit log  │
│                                                        │
│ Terminal service ─── durable session broker / spool    │
│ ACP service ───────── provider sessions / permissions  │
│ Attention service ─── needs-you / completion events    │
│ Project projection ── renderer store / assistant archive │
│ Ledger adapter ─────── shared task ledger              │
└────────────────────────────────────────────────────────┘
```

### Mac authority

The Companion Gateway lives in Electron main for the first release. It is the
only component allowed to translate a paired device command into terminal, ACP,
or ledger actions. Renderer IPC handlers become thin adapters over the same
service methods, so mobile control never fakes a `WebContents` or bypasses a
desktop safety check.

The detached PTY broker continues to survive renderer/app-window restarts. A
gateway restart causes the phone to reconnect and resynchronize; it does not
restart or duplicate the PTY. ACP turns still live in Electron main, so a full
app quit remains guarded until ACP reaches its existing safe boundary.

### Renderer projection

The renderer currently owns project tabs, assistant thread presentation,
`needsYou`, and some live metadata. The first slice adds a deliberately small
`CompanionProjection` rather than exporting the Zustand store:

- project id, display name, repo/branch, connection freshness;
- session id, kind, label, provider, status, timestamps, unread/needs-you;
- sanitized structured turns and paged archive cursors;
- pending permission display payloads;
- no settings secrets, absolute credential roots, raw environment variables,
  OAuth data, MCP headers, or unrelated file contents.

The renderer publishes this projection to main on meaningful changes, with a
revision and project epoch. Main persists the last bounded projection for a
cold reconnect, labels it stale until a live renderer confirms it, and merges
broker/ACP facts from their actual authorities.

### Terminal fan-out

The current PTY record has one renderer owner. Reusing `terminal.attach` for a
phone would steal the stream from desktop, so mobile requires a new observer
path:

- primary owner remains the desktop renderer/project capability;
- zero or more non-owning subscribers receive output, exit, and activity;
- control is a separate, expiring lease and never changes ownership;
- each output event has `{ streamEpoch, startOffset, endOffset, data }`;
- snapshots have `{ startOffset, endOffset, output, truncated, exitStatus }`;
- a cursor gap triggers one bounded snapshot, not an unbounded replay queue.

Terminal text remains an opaque VT stream. It is never rendered as HTML, and
OSC links use the same explicit URL safety policy as desktop.

### ACP fan-out

`acpHandler.cjs` currently binds a live prompt stream to one renderer channel.
It should be split into an `AcpSessionService` plus IPC adapters:

- normalized session summaries and subscriber events;
- `prompt`, `steer`, `cancel`, `setMode`, and permission response methods that
  all take an explicit actor and project capability;
- one active turn per session, as today;
- sanitized pending-permission payload retained in main with its resolver;
- exactly-once permission response and a resolved broadcast to every surface;
- no mobile persistent-rule or global-autonomy mutation in V1.

## Companion protocol

The protocol is versioned independently of the desktop app. Canonical JSON
fixtures are consumed by Node and Swift tests; unknown required fields or a
major-version mismatch fail closed.

### Envelope

Every decrypted frame contains:

```json
{
  "v": 1,
  "kind": "hello|event|command|receipt|snapshot|ack|error",
  "desktopId": "...",
  "deviceId": "...",
  "connectionId": "...",
  "seq": 42,
  "id": "uuid",
  "sentAt": 1784250000000,
  "body": {}
}
```

- Event sequence is monotonic per desktop epoch.
- Commands carry `commandId`, `projectId`, `targetId`, required capability,
  and optional expected revision.
- Desktop keeps a bounded idempotency cache. A repeated command returns the
  prior receipt; it does not execute twice.
- Receipts distinguish accepted, applied, rejected, stale, unavailable, and
  timed out.
- Reconnect sends the last acknowledged sequence. A bounded replay succeeds or
  the desktop sends a fresh snapshot.

### Initial event set

- `desktop.status`
- `snapshot.projects`
- `project.updated`
- `session.updated`
- `attention.raised` / `attention.cleared`
- `agent.turn.delta` / `agent.turn.completed`
- `agent.permission.requested` / `agent.permission.resolved`
- `terminal.snapshot` / `terminal.output` / `terminal.exit`
- `ledger.task.updated`

### Initial command set

| Command | Capability | Guard |
|---|---|---|
| `agent.prompt` | `agent-control` | connected, idle session, exact project |
| `agent.steer` | `agent-control` | provider supports queue, active turn |
| `agent.cancel` | `agent-control` | exact live session |
| `permission.respond` | `agent-control` | current unresolved permission id/revision |
| `terminal.write` | `terminal-control` | live session + active control lease |
| `terminal.resize` | `terminal-control` | active control lease |
| `terminal.interrupt` | `terminal-control` | live session; visible confirmation |
| `terminal.release-control` | `terminal-control` | caller owns lease |

`terminal.kill`, new shell, file writes, git actions, autonomy widening, and
persistent permission rules are deliberately absent from V1.

## Connectivity and lifecycle

### Direct mode — first phone vertical slice

- Desktop advertises `_kaisola._tcp` through Bonjour only while Companion is
  enabled.
- iOS asks for local-network access in context, discovers with Network
  framework, and connects with a length-framed TCP transport.
- Application-layer encryption and pairing authenticate every frame; LAN trust
  is never assumed.
- This proves real phone rendering and control without first deploying relay
  infrastructure.

### Remote mode — production default after the direct slice

- Desktop and phone each make outbound `wss:` connections to a small Cloud Run
  relay authenticated by Firebase ID tokens and registered device ids.
- The relay routes opaque encrypted envelopes. It cannot decrypt terminal or
  agent content and does not persist session transcripts.
- Clients proactively rotate/reconnect before Cloud Run's request timeout and
  resume from acknowledged sequence numbers.
- Initial rollout can run one bounded instance. A multi-instance release adds
  a real synchronization layer; best-effort session affinity is not correctness.

### Background

When iOS backgrounds:

- live terminal/agent streaming disconnects cleanly;
- the desktop continues running and spooling exactly as it does today;
- completion/needs-you state produces a debounced server notification request;
- APNs payload contains an opaque event id and privacy-safe label, never terminal
  output, diffs, prompts, workspace paths, or credentials;
- opening the notification reconnects and retrieves current encrypted state.

Push is an attention hint, not a durable event bus. Delivery is not guaranteed,
so reconnect always performs state reconciliation.

## Pairing and cryptography

1. Desktop and phone each create a Curve25519 identity key. Desktop protects
   its private material with Electron `safeStorage`; iOS stores its key in the
   Keychain.
2. A single-use QR payload contains protocol version, desktop id/public key,
   pairing nonce, requested capabilities, transport hint, and a short expiry.
3. Phone contributes its public key and proves possession. Both sides derive a
   short authentication phrase from the transcript and require confirmation.
4. Each connection uses fresh ephemeral key agreement plus HKDF-SHA256 to derive
   directional keys. ChaCha20-Poly1305 authenticates the encrypted frame and
   bound metadata.
5. Directional monotonic counters reject replays and nonce reuse. New connection
   ids derive new keys and reset counters safely.
6. Remote relay access also requires a current Firebase identity for the same
   account and an unrevoked paired-device record. Account login alone cannot
   pair or control a Mac.

The relay still observes connection timing, approximate ciphertext sizes, and
device routing ids. The privacy copy should say this plainly.

## Threat model and required controls

| Threat | Required control |
|---|---|
| Lost/unlocked phone | Face ID on re-entry, Keychain keys, per-device revoke, short inactivity lock |
| Malicious LAN peer | Single-use pairing, mutual key proof, E2EE, replay counters, no trust-by-IP |
| Compromised relay | End-to-end encryption; relay never receives session keys or plaintext |
| Cross-project action | Immutable project capability on every command and service lookup |
| Replayed approval/input | Command idempotency + encrypted sequence + current permission revision |
| Phone steals desktop PTY | Non-owning observer plus explicit expiring control lease |
| Terminal escape abuse | Feed bytes only to a terminal emulator; gated safe URL opening; no HTML |
| Notification leakage | Privacy-safe metadata only; configurable preview text |
| Unbounded output/slow phone | Byte cursors, bounded queues, gap-to-snapshot backpressure |
| Desktop/phone version skew | Independent protocol version and fail-closed capability negotiation |

Device revocation closes live relay/direct connections, invalidates future
commands, and removes the device public key. It does not delete project data.

## Performance and storage budgets

- Direct foreground output target: p95 under 250 ms from PTY event to phone
  render on a healthy LAN.
- Remote foreground output target: p95 under 800 ms on a healthy cellular path.
- Desktop gateway idle target: under 1% CPU and under 25 MiB incremental memory.
- Max terminal event payload: 64 KiB; preserve existing coalescing instead of
  waking either UI per byte.
- Replay buffer: bounded by both count and bytes; a slow consumer gets a snapshot.
- Phone cache: at most 512 KiB terminal tail per open session and a bounded set
  of structured turns, protected by iOS Data Protection. No provider token or
  desktop secret is cached.
- Notifications: completion/needs-you only, deduplicated by project/session and
  quieted during an active foreground connection.

## Delivery slices

### Slice A — protocol spine and loopback harness

- Extract renderer-neutral companion adapters.
- Add a redacted project/session projection and main-owned event log.
- Add offset-aware non-owning terminal subscriptions.
- Add deterministic crypto/protocol fixtures and a loopback client.
- No LAN listener, relay, or phone app yet.

**Exit:** the loopback client can reconnect, obtain one coherent snapshot,
follow real terminal output without stealing desktop ownership, and prove all
cross-project/replay tests fail closed.

### Slice B — read-only iPhone alpha on the same network

- SwiftUI shell, QR pairing, Bonjour discovery, Keychain identity.
- Now dashboard, Needs You list, structured agent transcript, SwiftTerm view.
- Foreground reconnect and stale/offline behavior.
- Desktop Companion settings and per-device revoke.

**Exit:** walk away from the Mac, watch a real Codex/Claude session and terminal,
background/foreground the phone, and recover without duplicated or missing tail
output beyond the declared bounded snapshot.

### Slice C — guarded control

- Prompt, steer, cancel, permission response.
- Terminal control lease, input, resize, interrupt, paste confirmation.
- Face ID gate, action receipts, and desktop/mobile resolution fan-out.

**Exit:** one real permission can be reviewed and resolved from either surface
exactly once; phone terminal input never changes project/owner identity; a lost
connection cannot replay input after reconnect.

### Slice D — remote-anywhere and push

- Cloud Run opaque relay, Firebase device registration, WebSocket reconnection.
- APNs completion/needs-you notifications.
- Network-switch and desktop-restart chaos tests.

**Exit:** the same live session survives Wi-Fi → cellular → Wi-Fi and desktop
renderer restart; the relay cannot decrypt recorded test envelopes; push opens
the exact current session without carrying sensitive content.

### Slice E — polish and release

- TestFlight, accessibility, Dynamic Type, VoiceOver labels, terminal keyboard
  ergonomics, privacy settings, device management, audit export.
- Battery/CPU/memory measurements and security review.
- Product docs, support diagnostics, staged rollout, crash/relay observability
  with plaintext redaction.

## Definition of “highly well”

The feature is not done because a phone displayed a terminal. It is done when:

- desktop and phone demonstrably control one session rather than forks;
- every sensitive action is scoped, authenticated, idempotent, and receipted;
- a compromised relay cannot read session content;
- backgrounding and reconnect are normal tested flows;
- permission decisions remain exactly-once and fail closed;
- terminal history and all queues remain bounded under a slow/disconnected phone;
- offline/stale/live state is visually unambiguous;
- the UI is useful one-handed and accessible, not a shrunk desktop;
- real Codex, Claude, ACP permission, TUI, restart, and network-switch journeys
  pass in addition to unit tests.

## Platform references

- Apple: [`URLSessionWebSocketTask`](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask),
  [User Notifications](https://developer.apple.com/documentation/usernotifications/),
  [local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy),
  [Bonjour/Network framework](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api),
  [CryptoKit ChaChaPoly](https://developer.apple.com/documentation/cryptokit/chachapoly),
  and [Keychain key storage](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain).
- Google Cloud: [Cloud Run WebSockets](https://docs.cloud.google.com/run/docs/triggering/websockets)
  and [request timeouts](https://docs.cloud.google.com/run/docs/configuring/request-timeout),
  including mandatory reconnect behavior and non-authoritative session affinity.
- Firebase: [Google sign-in on Apple platforms](https://firebase.google.com/docs/auth/ios/google-signin).
- Node: [`node:crypto`](https://nodejs.org/api/crypto.html) support for X25519
  and ChaCha20-Poly1305.
- SwiftTerm: [native iOS xterm/VT terminal view and emulator engine](https://github.com/migueldeicaza/SwiftTerm).
