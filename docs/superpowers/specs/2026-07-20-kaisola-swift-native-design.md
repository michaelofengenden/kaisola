# Kaisola → Swift-native — migration design

**Date:** 2026-07-20
**Status:** design (strategy), rev 2 (incorporates a repo-grounded plan-review).
Each phase below gets its own spec + implementation plan before it is built.

## Why

Two goals, chosen together:

1. **Native feel + kill Electron memory.** Measured today (installed
   `Kaisola.app`, one window): **~880 MB** RSS — a 375 MB Chromium renderer
   hosting the whole React UI + WebGL glass + xterm + CodeMirror, a 252 MB
   Electron main, a 128 MB GPU helper, a 49 MB utility helper, and the 77 MB
   Node session-broker. Electron pays a **fresh ~350 MB Chromium renderer per
   window**; three project windows is ~1.6 GB.
2. **One shared Swift core across Mac + iPhone.** The companion already holds
   ~2k lines of protocol, crypto, and domain models in Swift. Promoting that to
   a shared package means a feature is written once and ships to both.

**Targets — treated as measured gates, not asserted facts (see Verification):**

| | One window | Each extra window | Cold launch |
|---|---|---|---|
| Today (Electron) | ~880 MB | +~350 MB | ~1–3 s |
| Hybrid native (goal) | ≤ 450 MB *(only if Electron-main is NOT the host — see Decision A)* | +~60 MB | ≤ 0.6 s |
| Fully native (goal) | ≤ 250 MB *(incl. the PTY daemon + any offscreen WebKit)* | +~40 MB | ≤ 0.4 s |

## Strategy: hybrid strangler → fully native

**Never a big-bang rewrite.** The Electron app is the daily driver and keeps
shipping until the native app is demonstrably better. The native app grows by
*strangling* — it drives existing, battle-tested backends first, then ports each
to Swift one at a time. Every phase ships something usable.

### Current-architecture reality (corrected)

The one accelerant that is genuinely a detached, socket-speaking, durable
service today is the **session-broker** (`session-broker.cjs`, spawned
`detached:true` via `ELECTRON_RUN_AS_NODE`). The others are **not** detached and
cannot simply be "pointed at" from Swift:

- **ACP** is an in-memory service (`AcpSessionService`) owned by `acpHandler` in
  Electron **main**; the adapter subprocess uses stdio pipes tied to main and is
  **disposed on app shutdown** (`acpHandler.cjs`, `acp.cjs`).
- **MCP** is a loopback HTTP server running inside Electron **main** that routes
  human-gated proposals through `BrowserWindow`, **destroyed at shutdown**
  (`mcpServer.cjs`).
- **Companion host** depends on Electron `BrowserWindow`, `safeStorage`, and IPC
  (`companionHandler.cjs`).

This changes the plan materially and drives **Decision A** below.

## Key open decisions (resolve before the dependent phase)

- **Decision A — the control-plane host.** For the hybrid to reuse ACP/MCP/
  companion, we must pick one: **(A1)** extract a standalone, authenticated Node
  *control-plane host* (broker + ACP + MCP + companion) that both Electron and
  native drive over sockets; **(A2)** pull the full ACP/MCP/companion Swift ports
  forward into the hybrid; or **(A3)** run Electron-main headless as the host —
  which largely defeats the hybrid memory target and is therefore only a
  throwaway bootstrap. Leaning A1. **Blocks Phase 2 and Phase 4.**
- **Decision B — distribution & sandbox.** Developer ID / non-sandboxed vs App
  Sandbox. Kaisola needs arbitrary user-selected repo access and launches shells,
  git, adapters, compilers, and CLIs. Sandbox ⇒ persistent security-scoped
  bookmarks + helper-inheritance design; non-sandbox ⇒ the durable PTY daemon is
  a broad same-user execution capability to be secured deliberately. A per-user
  **LaunchAgent** (not a system LaunchDaemon) fits; `SMAppService` has its own
  registration/authorization + bundle-replacement caveats. **Blocks the daemon.**
- **Decision C — data coexistence.** Electron and native must not corrupt shared
  state while both ship (see State workstream). Choose separate stores +
  one-way import, or a single store with a documented write-arbitration owner.
- **Decision D — broker → daemon cutover.** How live PTYs migrate from the Node
  broker to a Swift daemon (see invariant #1). PTY master FDs belong to the
  owning process and cannot be handed over; options are dual-broker drain, a
  zero-live-session cutover gate, or keeping the Node broker indefinitely.

## Non-negotiable invariants — *maintain functionality*

Acceptance criteria on every phase and the cutover gate.

### 1. Durable terminal & agent CLI runs survive app update/restart (headline)

**Today (precisely):** `session-broker.cjs` runs as a detached process, owns the
`node-pty` PTYs and a disk-backed scrollback spool, and lets a client re-own a
terminal after the window or whole app restarts. So an in-flight `claude`/`codex`
run keeps running while you update Kaisola and the relaunched app re-attaches.

**Scope of the guarantee (must be stated, not implied):**

- **Survives:** app-window close/reopen, full app quit/relaunch, and app *update*
  — because the broker process outlives them.
- **Does NOT survive:** a broker/daemon crash, `SIGTERM`/`SIGINT` to the broker,
  user logout, or reboot — those kill every PTY today. Neither Node detachment
  nor launchd restart changes that. The invariant is *"survives app lifecycle
  events,"* not *"survives host death."*
- **History is bounded, not infinite.** Default disk spool ≈16 MiB; the reattach
  snapshot tail ≈1 MiB. The guarantee is *continuous retained history with an
  explicit truncation/gap marker* — not complete history.

**Byte-perfect reattach is new work, not free.** The desktop primary path
`terminal.attach` returns a **snapshot without a cursor**; only the read-only
observer path `terminal.subscribe` accepts `{streamEpoch, afterOffset}`. Output
emitted between the snapshot boundary and the live-listener install has no
offset reconciliation in the desktop protocol today. The Swift client must
therefore implement **atomic snapshot-plus-subscribe** (or offset every live
frame and resume from an acknowledged cursor). "Same broker" preserves the PTY
*process*; it does not by itself prove no-loss/no-duplication.

**How native preserves it:**

- **Phases 1–4 reuse the *same* Node broker** (the client is reimplemented in
  Swift; the broker process is unchanged), *plus* the atomic snapshot+subscribe
  fix above so reattach is byte-safe on desktop too.
- **Full-native (Phase 5)** introduces a Swift durable PTY daemon. It **cannot
  hot-swap** a live Node broker (FDs are non-transferable), so cutover follows
  **Decision D** — dual-broker drain (old sessions stay on Node until empty; new
  sessions start on Swift) or a zero-live-session gate. Note the existing v1→v2
  broker migration deliberately kills live PTYs because ownership metadata can't
  be migrated — the Swift daemon must instead offer N/N+1 protocol compatibility
  and rollback.

**Explicit test (every phase):** start a real `claude`/`codex` CLI, trigger an
actual **Sparkle-style app update** (not just a shell relaunch), confirm the run
continued and the reattached view is byte-continuous up to the retention marker.

### 2. The rest of the parity list

Behavioral parity required before cutover. This is enforced by conformance
tests, not just a checklist (see Verification):

- **Multi-project windows** with tear-off/recombine; per-project workspace +
  session sets; **saved-window restore** (transactional manifest today).
- **Agent lifecycle:** ACP Claude/Codex connect, prompt, mid-turn steer, cancel,
  **adoption/resume**, one-turn serialization, provider queue, read-only mode,
  sensitive-file handling, cancel watchdog.
- **Permissions & autonomy:** pending-permission model, allow-once/reject, saved
  rules, protected globs, autonomy levels.
- **Board + attention authority** and native notifications.
- **Companion gateway** (phone pairing + live stream: Noise XX, pairing).
- **MCP loopback server** serving project bearer capabilities.
- **Visual parity:** glass/painted/eco (native `NSVisualEffectView`), light/dark/
  solid, accents.
- **Keybindings** (`keymap.json`), **Firebase Google auth**, **git**, and
  **document/editor fidelity**.
- **Auto-update** with the durable broker/daemon surviving the swap.
- **The long tail** (must each get an owner/phase/test entry, not be dropped):
  browser / dev-server session cards, assistant archives + unsaved buffers,
  extensions / custom languages / previews / external MCP config, worktrees,
  sandboxed execution, Claude hooks, usage meters, GROBID, LaTeX + SyncTeX, deep
  links, file associations, asset import, native menus, and safe **secrets
  migration** (API keys, Firebase refresh token, companion identity/device
  secrets, pairing state) out of Electron `safeStorage`.

## State & storage workstream (pulled early — not "Phase 5, mechanical")

State is authoritative and cross-cutting, not a late detail: Zustand hydrates
**synchronously** through Electron-main SQLite (`dbHandler`), saved-window
restore/delete uses a transactional manifest, and legacy localStorage-only state
still has migration handling. Because Phase 2 (board/windows) and Phase 3 (the
React island still expecting the ~1,600-line renderer bridge) both depend on it,
the storage design — **GRDB schema + version ownership, legacy import, rollback,
and Electron/native coexistence (Decision C)** — must be specified **before**
daily-driver parity, or two apps will write the same data under incompatible
assumptions.

## Architecture

```
KaisolaCore  (one Swift package — shared, macOS + iOS targets)
  ├─ Protocol · Crypto · Domain models      ← promote from the companion (~2k lines)
  ├─ Session / agent / projection / board model
  ├─ Backend clients: BrokerClient · (AcpClient · McpClient via the control-plane host, Decision A)
  └─ Wire codecs, cursors (atomic snapshot+subscribe), reconciliation

Kaisola (macOS)  — new AppKit/SwiftUI target on KaisolaCore
  ├─ Shell · Terminal (SwiftTerm) · Agents/ACP · Auth/model · Editor+Docs (WKWebView first)
Kaisola Companion (iOS)  — existing app, re-based onto KaisolaCore

Backends:
  session-broker (Node/node-pty, detached, durable)  → Swift PTY daemon (Decision D)
  ACP + MCP + companion host                         → control-plane host (Decision A)
```

## Fully-native component map (corrected)

| Piece today | Native replacement | Reality check |
|---|---|---|
| Terminal / node-pty | **SwiftTerm** (1.15.0, pinned) + Swift PTY daemon | iOS use ≠ macOS proof: keyboard/IME, a11y, mouse/focus modes, SIGWINCH, big scrollback, paste, streaming perf need macOS validation |
| Code editor (CodeMirror) | **CodeEditSourceEditor** (TextKit 2 + tree-sitter) | ⚠️ upstream says *not production-ready* — needs a parity spike + a WKWebView/CodeMirror-island fallback |
| ACP agents (stdio) | Swift `Process` + JSON-RPC | Underestimated: framing, backpressure, adapter discovery/versioning, process groups + watchdogs, permission settlement, terminal callbacks, MCP capability injection, adoption/resume, read-only, multi-window ownership |
| Documents | swift-markdown + PDFKit + native views | swift-markdown = *parsing only*. Parity also needs editable markdown, HTML sanitization, asset import/reorder/resize, file watching, LaTeX+SyncTeX, raster-PDF fallback, split PDF/source, git merge views, media/browser sessions |
| Math (KaTeX) | **SwiftMath** | Medium |
| Mermaid | offscreen WebKit → SVG | **Not a current dependency** — net-new/optional, not a parity item. If added: pinned JS, CSP/no-network, SVG sanitization, CPU/input limits |
| Storage (better-sqlite3) | **GRDB.swift** | See State workstream — not mechanical; coexistence + migration |
| MCP server | Swift, or kept as a small subprocess | Via Decision A |
| Model APIs | URLSession REST | Easy |
| Firebase auth | `FirebaseAuthBackend` | ⚠️ **iOS-only today** (UIKit/`UIApplication`); needs a macOS adaptation + migration from Electron `safeStorage` |

## Will it be faster/smoother?

Yes on launch, new-window speed, streaming/scroll smoothness, glass at low GPU
cost, and battery/thermals (the transparent WebGL surface is *"the app's dominant
cost while an agent streams"* per `Terminal.tsx`). It will **not** change agent/
model latency or make editor typing meaningfully faster than CodeMirror (the
editor win is memory, not speed).

## Migration phases (re-scoped; several were too large as one phase)

Electron stays the daily driver until parity. Each phase gets its own spec.

0. **Extract KaisolaCore**; re-base the iOS companion on it. *(Sound, isolated.)*
1. **Terminal spike** — native SwiftTerm driven by the existing Node broker.
   *Explicitly a spike/sidecar* until we solve broker packaging (a standalone
   signed Node runtime + `node-pty`/native-module closure, since the broker is
   Electron-in-node-mode today) and reproduce the user-data-path discovery. Land
   the atomic snapshot+subscribe reattach here and run the update test.
2. **Control-plane host (Decision A) + native ACP/Board/windows.** "Native ACP"
   = native session UI over the host; the full Swift ACP port is Phase 5. Needs
   the State workstream (board/windows depend on authoritative state).
3. **Editor + docs via WKWebView bridge** — prerequisite work first: native
   files/git plumbing (or the control-plane host) and a **versioned** native↔web
   messaging bridge; this reuses the ~1,600-line renderer bridge, not an
   isolated editor.
4. **Daily-driver parity** — auth (macOS Firebase + secrets migration), settings,
   provider, MCP, companion, updates, notifications. Treated as *several*
   strangler slices, each individually gated, not one step.
5. **Full native** — independently gated ports: broker→Swift daemon (Decision D),
   ACP→Swift, MCP→Swift, editor, markdown, math, PDF, (optional) mermaid; drop
   Electron; hit full-native memory gates.

## Risks & mitigations (expanded)

- **Editor** — CodeEditSourceEditor isn't production-ready → parity spike +
  WKWebView/CodeMirror fallback; don't name it *the* path until proven.
- **Document parity** is much larger than one table row → its own spec.
- **Broker packaging** (Phase 1) → standalone signed Node runtime + native-module
  closure, or accept a dev sidecar until solved.
- **Broker→daemon cutover** (Decision D) → drain, not hot-swap; N/N+1 compat +
  rollback; real update test.
- **Data coexistence** (Decision C) → write-arbitration owner or separate stores.
- **Security** (Decision B) → sandbox choice, LaunchAgent, client auth, code-sign
  validation, env inheritance, socket/XPC perms, spool cleanup, companion-issued
  terminal-control policy.
- **Parity drift** → conformance tests + fixtures, not a prose checklist.

## Verification (targets are gates, with a defined methodology)

- **Memory** — a native analog of `memorycompare.cjs` that sums the Swift app +
  WebKit content/GPU/network processes + Node broker/control-plane + native
  daemon, handles model processes consistently, and records **physical
  footprint** (not just summed RSS, which counts shared pages differently across
  Electron/WebKit/native). Report median/p95 across cold/warm caches, fresh vs.
  already-running broker, and restored-windows workloads.
- **Perf** — cold-launch milestone defined explicitly; plus CPU, frame pacing,
  energy impact, terminal throughput, and a **sustained-stream battery** test
  (the whole motivation).
- **Parity** — shared protocol fixtures, record/replay traces, golden state
  migrations, and dual-client conformance tests; **every** capability in the
  invariant list gets an owner / phase / test entry.

## Out of scope here

Windows/Linux native (Electron keeps cross-platform; native is macOS-first). Any
single mega-implementation. **Next step:** detailed specs + plans for **Phase 0
(KaisolaCore)** and **the Phase 1 terminal spike** — including a concrete
resolution of Decision A's bootstrap and the broker-packaging question — since
together they prove the architecture, the code-share, the memory win, and the
durable-run invariant with the least risk.
