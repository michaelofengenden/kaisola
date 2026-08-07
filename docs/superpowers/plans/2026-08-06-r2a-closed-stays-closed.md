# R2-A: Broker Foundation + Closed-Stays-Closed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nothing the user closed is ever resurrected, and terminal history spans restarts back to the session's first byte.

**Architecture:** One broker-spool migration (exit-reason meta, cold records, continuous offsets with a live/history boundary split, feature flag) lands first — Tasks 1–5, Codex track. The Swift side (Tasks 6–13, main session) adds durable tombstones and a synchronous close commit to `NativeSessionStore`, routes every close/restore/resurrection path through them, and fixes the chat/mesh/project deletion paths. Spec: `docs/superpowers/specs/2026-08-06-round2-reading-memory-settings-closed-design.md` §4 + §2h.

**Tech Stack:** Node CJS broker (`runtime/node-broker/`), Swift/SwiftUI app (`native/KaisolaMac/Kaisola/`), node:test harness (`tests/node/`), XCTest (scheme `Kaisola`; run `xcodegen generate` in `native/KaisolaMac` after adding files).

## Global Constraints

- Closing is user intent: in-memory commit happens synchronously in the UI handler before any await/Task spawn.
- Store-write cost must not exceed today's (every upsert already writes synchronously; reuse that path — the spec's ordered-async variant is an optimization, adopted only if profiling demands).
- Old ANSI never replays into a fresh SwiftTerm parser: `snapshot()` respects `epochStartOffset`; only `terminal.history` crosses epochs.
- New history semantics ride the `terminal-history-continuous-v1` feature flag; Swift falls back cleanly against older brokers.
- Tombstones are permanent closed-state markers; the 10/50-deep undo stacks are UI conveniences only.
- Commits: conventional prefixes, no AI co-author trailers. Broker commits stage explicit paths only (parallel Swift work in the same tree).

---

## Broker track (Codex, Tasks 1–5)

### Task 1: Spool meta schema — `exitedAt` + `epochStartOffset`

**Files:** Modify `runtime/node-broker/ipc/terminalSpool.cjs` (persistMeta ~line 360, constructor meta read); Test `tests/node/terminalSpool.test.cjs`.

**Interfaces (produces):** `spool.markExited(status)` → stamps `{ exitedAt: now, exitStatus }` into the meta file immediately; `spool.exitEvidence()` → `{ exitedAt, exitStatus } | null` (readable statically before opening for append via new static `TerminalSpool.readMeta(id, dir)`); `spool.epochStartOffset` — persisted in meta, set by Task 2.

Steps: failing test (push output → `markExited(0)` → new-process `TerminalSpool.readMeta` returns evidence; a spool without the stamp returns null); implement; suite; commit `feat(broker): spool meta carries exit evidence`.

### Task 2: Continuous offsets with split boundaries

**Files:** Modify `runtime/node-broker/ipc/terminalSpool.cjs` (`_diskSegments`, `snapshot`, `historyPage`, constructor), `runtime/node-broker/ipc/terminalManager.cjs` (restore spawn path ~line 300, cursor init).

**Interfaces (produces):** On restore-spawn: `cursor.nextOffset` initializes to the retained spool's total byte count; spool records `epochStartOffset = <that count>` in meta. `snapshot()` serves only bytes at/after `epochStartOffset` (fresh parser sees only the new epoch). `historyPage()` serves the WHOLE spool (pre-restart included), offsets absolute over the full transcript. `readStartBytes` is deleted; the `recovered` field in the create response is always `null`.

Steps: failing tests — (a) restore-spawn then `snapshot().output` excludes pre-restart bytes; (b) `history` pages from the live cursor back to absolute offset 0 including pre-restart bytes; (c) plain (non-restore) spawn behavior unchanged. Implement; suite; commit `feat(broker): transcript offsets continue across restarts; live snapshots stay epoch-scoped`.

### Task 3: Natural-exit stamping with shutdown suppression

**Files:** Modify `runtime/node-broker/ipc/terminalManager.cjs` (`p.onExit` handler ~line 488, `killAll` ~line 799).

**Interfaces (produces):** `p.onExit` calls `rec.spool.markExited(status)` ONLY when `!shuttingDown`; `killAll()` sets a module-level `shuttingDown = true` before killing (never reset — the process is exiting). `release()` behavior unchanged (spool deleted, no evidence needed).

Steps: failing tests — natural exit leaves evidence readable by a fresh process; `killAll` leaves none. Implement; suite; commit `feat(broker): exit evidence only for natural exits, never managed shutdown`.

### Task 4: Cold records for ended restores

**Files:** Modify `runtime/node-broker/ipc/terminalManager.cjs` (`spawn` restore branch), `runtime/node-broker/ipc/terminalCreateRoute.cjs`.

**Interfaces (produces):** `spawn({restore: true, ...})` for an id whose `TerminalSpool.readMeta` shows `exitedAt`: registers a record with `pty: null, exited: true, exitStatus` and a spool opened WITHOUT truncation, cursor at spool size with matching `epochStartOffset`; no process spawns. `terminalCreateRoute` returns `{ ok: true, existed: false, pid: null, exited: true, exitStatus, ...snapshot }`. `terminal.history` works against cold records (they are in `terms`). `terminal.write`/`resize` against a cold record returns `{ ok: false, message: 'terminal already ended' }`.

Steps: failing route test (restore of exited spool → `pid: null, exited: true`, history reaches old bytes, write refused); implement; suite; commit `feat(broker): ended terminals restore as history-serving cold records`.

### Task 5: Feature flag

**Files:** Modify `runtime/node-broker/ipc/brokerWire.cjs` (features list ~line 14).

**Interfaces (produces):** hello/features includes `terminal-history-continuous-v1`. Steps: failing test asserting the flag in the features array; implement; full `npm run test:node`; commit `feat(broker): advertise terminal-history-continuous-v1`.

---

## Swift track (main session, Tasks 6–13)

### Task 6: Store schema — tombstones, pending releases, endedAt, closed-project markers

**Files:** Modify `native/KaisolaMac/Kaisola/Broker/NativeSessionStore.swift` (Payload, `NativeOwnedSession` ~line 8, `upsert`, `recoverOwnedSessions` ~line 226, `openProject` ~line 260, `closeProject` ~line 382); Test `native/KaisolaMac/KaisolaTests/ClosedLifecycleStoreTests.swift` (new).

**Interfaces (produces):**
```swift
// NativeOwnedSession gains:
var endedAt: Int64?           // stamped when exit observed; nil = presumed alive
// Payload gains (all Codable-optional for migration):
var closedTerminals: [String: Int64]?      // id -> closedAt; permanent tombstones
var pendingReleases: [PendingRelease]?     // struct PendingRelease: Codable { let id: String; let projectID: String }
var closedProjectIDs: [String]?            // permanent closed markers (undo stack stays separate)
// NativeSessionStore gains:
func commitCloseTerminal(_ id: String)     // one mutation: remove record, tombstone, push ClosedSession undo, queue pending release. Synchronous write (today's path).
func isTerminalTombstoned(_ id: String) -> Bool
func acknowledgeRelease(id: String)        // drops pending release; drops tombstone only when no record/archive references remain
func pendingReleaseList() -> [PendingRelease]
func stampEnded(_ id: String, at: Int64)   // sets endedAt on the record if present
func isProjectClosed(_ id: String) -> Bool // closedProjectIDs membership
```
Behavior: `upsert` REFUSES ids in `closedTerminals` (silent no-op + debug assert); `recoverOwnedSessions` skips tombstoned ids and exited rows; `closeProject` adds the marker + pushes undo; `openProject` removes the marker (and retires the undo entry as today); `closedProjects` undo cap 10 → 50.

Steps: failing tests for each behavior above (commit-close removes+tombstones+queues; upsert refuses; recover skips; marker add/remove round-trips through encode/decode; legacy payload without new fields decodes). Implement; run `ClosedLifecycleStoreTests`; commit `feat(app): durable closed-lifecycle schema in the session store`.

### Task 7: Close commits synchronously; every close path routes through it

**Files:** Modify `native/KaisolaMac/Kaisola/App/AppModel.swift` (`endSession` ~5408, `endDormantSession`, new `commitClose`), `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift` (End Session call sites ~910, ~4431; unavailable-tile Close button ~2253; End Session menu gating).

**Interfaces (produces):**
```swift
@MainActor func commitClose(_ terminalID: String)  // SYNCHRONOUS: sessionStore.commitCloseTerminal, pane removal from all layouts, dormant/pendingAgentResume/session caches cleanup, selection fixup. No awaits.
func drainPendingReleases() async                  // for each pendingReleaseList entry: controlClient.release; on success or terminal-absent ack -> acknowledgeRelease. Called after connect and after commitClose.
```
UI: button handlers call `model.commitClose(id)` directly, then `Task { await model.drainPendingReleases() }`. "End Session" menu appears for exited AND dormant/unavailable terminals (gate becomes: record exists in store OR live). The "Session unavailable" tile gains a Close button calling the same path. `endSession`/`endDormantSession` collapse into `commitClose` + drain.

Steps: failing tests — close-while-disconnected leaves no record and survives store reload; close then immediate `persistWorkspaceStateNow` snapshot excludes the pane (the ⌘Q race, no Task turn needed); drain acknowledges and clears. Implement; run close-related suites (`AppModelBookkeeping`, new tests); commit `fix(app): closes commit synchronously and drain broker releases from a durable queue`.

### Task 8: Ended is remembered; resurrection is polite

**Files:** Modify `native/KaisolaMac/Kaisola/App/AppModel.swift` (inventory reconciliation in `refreshInventory` ~5560, exit event ~6240, `resurrectDormantTerminals` ~5866, `createOwnedSession` ~4868, `syncTrackedWorkingDirectories`, `reopenEndedSession` ~5538), `native/KaisolaMac/Kaisola/Broker/BrokerControlClient.swift` (TerminalCreation optional pid + exited).

**Interfaces (produces):** inventory refresh stamps `sessionStore.stampEnded(id, at:)` for every exited row; exit events stamp too. `TerminalCreation.pid` becomes `Int32?` and gains `exited: Bool` (decoding tolerates `pid: null` per broker Task 4). Resurrection: skips records with `endedAt != nil`, skips tombstoned, skips `isProjectClosed(record.projectID)`, and after EVERY await re-checks tombstone + record existence; a create that lands for a tombstoned id issues an immediate compensating `release`. `createOwnedSession(restore: true)` no longer calls `sessionStore.openProject`. A restore answered with `exited: true` (cold record) marks the pane ended instead of live. `reopenEndedSession` removes the old record (`sessionStore.remove`) when creating the replacement. `syncTrackedWorkingDirectories` skips tombstoned/absent ids. Cross-project dormant filter: normalization unions only dormant ids whose stored `projectID` matches.

Steps: failing tests — exited row in inventory ⇒ endedAt stamped ⇒ resurrection skips; resurrection with closed project skips; simulated interleaved close (tombstone appears between dormant scan and create return) triggers compensating release and no upsert; reopen removes old record; restore-create decodes `pid: null`. Implement; run reconnect/resurrection suites; commit `fix(app): resurrection respects ended, tombstoned, and closed-project state`.

### Task 9: Closed projects disappear (with eyes open)

**Files:** Modify `native/KaisolaMac/Kaisola/App/AppModel.swift` (`projects` derivation ~498, `restoreWorkspaceStateIfNeeded` ~2653, `closeProject` ~2036), `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift` (close-project confirm), Test update `native/KaisolaMac/KaisolaTests/AppModelProjectContextTests.swift` (~704: invert the Recently-Closed-keeps-project-visible assertion).

**Interfaces (produces):** `projects` excludes any group whose id is in `closedProjectIDs` (live-session/chat/mesh/recently-closed derivation no longer forces the tab back). `restoreWorkspaceStateIfNeeded` skips archive projects that are closed (state stays on disk; `reopenLastClosedProject` restores fully). Closing a project with live terminals/chats/meshes presents a confirmation naming counts ("3 sessions keep running in the background — reopen with ⌘⇧T"); attention-inbox events for closed projects still surface (verify `AttentionCenter` doesn't filter by open projects — if it does, exempt).

Steps: update the inverted test first (fails against HEAD); add restore-skip and derivation tests; implement; commit `fix(app): closed projects stay closed; running work confirmed and still surfaced`.

### Task 10: Chat deletion tombstones in the transcript store

**Files:** Modify `native/KaisolaMac/Kaisola/Acp/AcpTranscriptStore.swift` (schema migration: `deleted_chats(chat_id TEXT PRIMARY KEY, deleted_at INTEGER)`; `remove` surfaces errors; writes/restores consult), `native/KaisolaMac/Kaisola/App/AppModel.swift` (`deleteChat` ~3296 ordering); Test `AcpTranscriptStoreTests` + phase-injection tests.

**Interfaces (produces):** `AcpTranscriptStore.tombstone(chatID:) throws` (insert first), `isTombstoned(chatID:) -> Bool`, row/draft/descriptor writes and `restoration` reads skip tombstoned ids; tombstone drains when no rows/descriptors remain (`vacuumTombstones()` on open). `deleteChat` order: tombstone (throws → toast, abort) → memory removal → idempotent GC (transcript, draft, usage) → immediate workspace persist (not debounced).

Steps: failing tests — write-after-tombstone is refused; restore skips tombstoned; injected failure between each phase leaves a state that converges on relaunch (tombstone present ⇒ chat gone). Implement; commit `fix(app): chat deletion is tombstone-first and phase-durable`.

### Task 11: Mesh pendingDeletion resumes destruction

**Files:** Modify `native/KaisolaMac/Kaisola/Mesh/MeshSession.swift` (`restore` ~637: remove the `.suspended` flip; branch at entry), `native/KaisolaMac/Kaisola/App/AppModel.swift` (restore call site ~2707).

**Interfaces (produces):** a restored descriptor with `lifecycle == .pendingDeletion` never starts adapters; it resumes `destroy()` from the manifest; failure leaves `.recoveryRequired` with a retry card (existing surface), success completes the tombstone removal (existing `removeMeshState` path at ~2772).

Steps: failing test — pendingDeletion descriptor restores to destruction-resumed, not `.suspended`; implement; commit `fix(mesh): deletion resumes across relaunch instead of reviving`.

### Task 12: Quit-path verification

**Files:** Test `native/KaisolaMac/KaisolaTests/ClosedLifecycleQuitTests.swift` (new; no production changes expected — Task 7 made commits synchronous).

Steps: test that `commitClose` followed IMMEDIATELY by `workspaceSnapshotForTesting` (same turn, no yields) excludes the pane and the store record; test teardown path persists the absence within the existing flow. Run; commit `test(app): close-then-quit persists absence with no task turn`.

### Task 13: End-to-end + full verification

Steps: full `KaisolaTests` suite; full `npm run test:node`; manual end-to-end — close a session and a project, `kill` the broker, relaunch: nothing returns; a claude session's transcript pages to its first byte after the broker restart. Update `docs/superpowers/specs/...` §4 status note. Commit `test: closed-stays-closed end-to-end verified`.
