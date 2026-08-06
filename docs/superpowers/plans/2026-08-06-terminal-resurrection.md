# Terminal Resurrection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terminals survive app quit, broker death, and machine reboot: panes are never erased, shells respawn automatically at their tracked cwd with recovered scrollback shown above a divider, and agent terminals offer a one-click resume chip.

**Architecture:** Broker side (Node, `runtime/node-broker/`) makes spools durable and replayable and tracks live cwd; app side (Swift) keeps dormant panes through restore/normalize, respawns through the new broker contract, and renders the recovery UI. The broker tasks (1–4) are dispatched to Codex; the Swift tasks (5–8) run in the main session. The two halves meet at the Task 3 wire contract — neither side may change it unilaterally.

**Tech Stack:** Node (CommonJS) broker, Swift/SwiftUI app, XCTest + the repo's node test harness (`tests/`).

## Global Constraints

- Fully automatic restore; the only gate is the agent resume chip (never auto-run an agent CLI; suppress the chip when the account binding does not normalize — mirror `AppModel.swift:3062`).
- Never block launch: respawns and spool reads happen after the UI is up, concurrently.
- Disk is unlimited: retention favors keeping data; caps exist only to bound single read time.
- Spec: `docs/superpowers/specs/2026-08-06-obsidian-md-filetree-session-restore-design.md` §3.
- Wire contract (Task 3) is the single source of truth for field names.
- Commits: conventional prefixes, no AI co-author trailers.

---

## Broker side (Codex dispatch, Tasks 1–4)

### Task 1: Eager durable spool appends (spec 3c durability)

**Files:**
- Modify: `runtime/node-broker/ipc/terminalSpool.cjs` (`push` ~line 250, `_queue`, `setVisible`, constructor)
- Test: the spool's existing test file in `tests/` (find via `grep -rl terminalSpool tests/`)

**Interfaces:**
- Produces: while a terminal is visible, every `push(data)` also enqueues to the disk queue; a debounce timer (`SPOOL_APPEND_DEBOUNCE_MS = 750`) or the existing `queueCap` byte threshold — whichever fires first — flushes to disk. The RAM `chunks` hot tail becomes purely a read cache; the eviction path must NOT re-queue evicted chunks (they are already on disk) — this is the behavioral flip that prevents double-writes.

Steps: write a failing test proving bytes pushed while `visible === true` reach the spool file within the debounce window without `setVisible(false)`/`snapshot()`; implement; prove no byte is written twice (push data, flush, compare file content to exactly the pushed sequence); run the broker suite; commit (`feat(broker): spool appends reach disk eagerly while visible`).

### Task 2: Spool retention + cold replay (spec 3c)

**Files:**
- Modify: `runtime/node-broker/ipc/terminalManager.cjs` (`spawn` ~line 265: `TerminalSpool({ fresh: true })`), `runtime/node-broker/ipc/terminalSpool.cjs` (add cold-read)
- Test: same harness.

**Interfaces:**
- Produces: `TerminalSpool.coldTail(id, dir, maxBytes = 512 * 1024) -> { text, truncated } | null` static read of a retained spool (current + prev segment, tail-bounded) without opening it for append. `spawn` stops passing `fresh: true` when the request carries `restore: true` AND a spool for that id exists: it first captures `coldTail`, then reopens the spool for append WITHOUT unlinking (recovered bytes stay; new output appends after). A plain spawn (no `restore`) keeps today's `fresh: true` wipe so brand-new terminals never inherit stale bytes.

Steps: failing test (write spool, simulate broker restart by constructing a new manager, spawn with `restore: true`, assert `recovered.text` contains the old bytes and the file still grows with new output); implement; run suite; commit (`feat(broker): cold scrollback survives a broker restart`).

### Task 3: Wire contract — respawn + recovered scrollback + cwd

**Files:**
- Modify: `runtime/node-broker/session-broker.cjs` (terminal.spawn route, ~line 445 attach continuation), `runtime/node-broker/ipc/terminalManager.cjs`
- Test: same harness (route-level test).

**Interfaces (THE CONTRACT — Swift Task 6 consumes exactly this):**
- `terminal.spawn` request gains optional fields: `restore: boolean`, and honors caller-supplied `id` reuse when that id is not live.
- `terminal.spawn` response gains: `recovered: { text: string, truncated: boolean } | null` (null when no retained spool or `restore` absent).
- Terminal inventory records (already returned by the control lane) gain `cwd: string` kept fresh by Task 4.

Steps: failing route test; implement; run suite; commit (`feat(broker): respawn contract with recovered scrollback`).

### Task 4: Live cwd tracking (spec 3d)

**Files:**
- Modify: `runtime/node-broker/ipc/terminalManager.cjs` (or the state-snapshot writer in `session-broker.cjs` — wherever the periodic persist runs)
- Test: same harness.

**Interfaces:**
- Produces: whenever the broker writes its periodic state snapshot (and once in the shutdown flush), it refreshes each live terminal record's `cwd` via one batched `lsof -a -p <pid1>,<pid2> -d cwd -Fn` call (macOS; guard failures — lsof missing or erroring leaves the last known cwd). Records persist the refreshed value so a dead-broker restart still knows the last tracked cwd.

Steps: failing test (fake lsof output parser is a pure function — `parseLsofCwd(output) -> Map<pid, cwd>`; test that); implement parser + refresh hook; run suite; commit (`feat(broker): terminal records track the shell's live cwd`).

---

## App side (main session, Tasks 5–8)

### Task 5: Dormant panes survive restore and normalize (spec 3a)

**Files:**
- Modify: `native/KaisolaMac/Kaisola/App/AppModel.swift` — `restoreOwnedSessions()` (~5680–5734: stop skipping absent records), `restoreWorkspaceStateIfNeeded()` (~2624–2796: `layout.normalize(availableSessionIDs:)` call ~2763–2772 gains the dormant set)
- Modify: `native/KaisolaMac/Kaisola/Broker/NativeSessionStore.swift` if `SessionPaneLayout.normalize` lives there
- Test: `native/KaisolaMac/KaisolaTests/TerminalResurrectionTests.swift` (new)

**Interfaces:**
- Produces: `AppModel.dormantTerminalIDs: Set<String>` — persisted terminal records absent from broker inventory at restore. `normalize(availableSessionIDs:)` is called with `available ∪ dormant` so dormant panes stay in the layout and in every subsequent state save. A dormant pane renders a placeholder surface until Task 6 revives it.

Steps: failing test — build a `SessionPaneLayout` with a terminal pane, normalize against `available = []`, `dormant = [id]`, assert the pane survives; then a save/load round-trip of the restoration state keeps the record. Implement. Run `AppModelBookkeepingTests` + new tests. Commit (`feat(app): dormant terminal panes survive restore`).

### Task 6: Respawn through the contract (spec 3b)

**Files:**
- Modify: `native/KaisolaMac/Kaisola/App/AppModel.swift` (post-restore hook after `restoreWorkspaceStateIfNeeded`), `native/KaisolaMac/Kaisola/Broker/BrokerControlClient.swift` + `BrokerModels.swift` (spawn request/response fields per Task 3 contract)
- Test: extend `TerminalResurrectionTests.swift`; model-level decode test for `recovered`.

**Interfaces:**
- Consumes: Task 3 contract verbatim (`restore`, `recovered {text, truncated}`, record `cwd`).
- Produces: `AppModel.resurrectDormantTerminals() async` — runs after the UI is up (`Task` off the restore path): for each dormant record, if `agentID == nil` spawn `{id: old, cwd: record.cwd, restore: true}` and hand `recovered` to the surface; if `agentID != nil` spawn a plain shell the same way and set `pendingAgentResume[id] = agentID` for Task 7's chip. Spawn failures leave the pane dormant with its error shown; the record is never deleted.

Steps: failing decode test for the new response field; failing bookkeeping test (dormant plain shell → resurrect spawns with `restore: true`; dormant agent terminal → chip pending, no auto resume command). Implement. Run tests. Commit (`feat(app): dormant terminals respawn at their tracked cwd`).

### Task 7: Recovery UI — divider + resume chip (spec 3b/3c)

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/NativeTerminalSurface.swift` / `TerminalTranscriptView.swift` (recovered scrollback injection: dimmed block above a divider line reading "restored from before restart"), plus the pane chrome for the chip
- Modify: `native/KaisolaMac/Kaisola/Broker/AgentRegistry.swift` consumers — chip runs `resumeCommand` (exists, `AgentRegistry.swift:45-58`) through the existing send path
- Test: pure-helper test for chip eligibility: `ResumeChipEligibility.shouldShow(agentID:accountBindingNormalizes:) -> Bool`

**Interfaces:**
- Consumes: `recovered` text (Task 6), `pendingAgentResume`, `AgentRegistry.resumeCommand`.
- Produces: user-visible recovery. Chip click sends `resumeCommand + "\n"` to the live shell and clears the pending flag. Account-binding mismatch (per the existing normalization guard) hides the chip entirely.

Steps: failing eligibility test (agent + normalizing binding → true; nil agent → false; non-normalizing → false). Implement UI + wiring. Manual check with a killed broker. Commit (`feat(app): recovered scrollback divider and agent resume chip`).

### Task 8: Retention loosened + end-to-end verification (spec 3e)

**Files:**
- Modify: `native/KaisolaMac/Kaisola/Acp/AcpTranscriptStore.swift` (~line 87: chat cap 40 → 1000)
- Test: adjust `AcpTranscriptStoreTests` retention test to the new cap.

Steps: update cap + its test; run the FULL app suite and the broker suite; end-to-end manual pass — open terminals (one plain, one running `claude`), `kill` the broker process, relaunch the app: both panes return, plain shell live at its cwd with dimmed scrollback above the divider, agent pane shows the chip and does not auto-run. Commit (`feat(app): raise chat retention; terminal resurrection verified end-to-end`).
