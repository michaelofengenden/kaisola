# Round 2: serif reading, memory efficiency, settings overhaul, closed-stays-closed (2026-08-06, rev 2)

Four workstreams approved by Michael on 2026-08-06 (evening); revised after Codex plan-review (same night). Section 4 is a bug-fix track and ships first as its own release. The round-1 performance principle carries over: nothing blocks the main thread or launch; disk is free to spend; RAM is the scarce resource this round.

---

## 1. Serif reading typography in the Live Preview

### Current state

The markdown editor (`FilePreviewEditors.swift`) renders the file's exact bytes with real text-storage attributes: system sans body, heading sizes `[30, 25, 21, 18, 16, 15]`, full-width text container, quotes as gray oblique text, code as monospaced runs with a background color. Edit-time styling is a debounced (70 ms) whole-document scan + apply on the main actor; only cursor-line reveal uses the range-scoped pass.

### Changes

**1a. Reading face with trait composition.** Body text becomes the system serif (New York) at 16 pt with ~1.5 leading; headings stay sans with a retuned scale. Emphasis attributes stop being static fonts: `attributes(for:)` composes traits onto the *resolved base face at that range* — bold inside body composes onto the serif, bold inside a table cell composes onto the table's sans, bold+italic nest correctly. Body italics use the serif's true italic (replacing the `obliqueness` skew). Inline code and code blocks stay monospaced; tables stay sans.

**1b. Reading measure.** The text column caps at ~70 characters of the body face (≈ 620 unmagnified document points) and centers when the pane is wider, via the text container inset. The measure is defined in document space, so magnification scales it naturally — no double-scaling. Tests cover viewport-anchor continuity and table/image alignment across pane resize and zoom steps.

**1c. Block styling via range-backed decorations.** The layout-manager decoration model (today: one character index + width resolving to a single line fragment) gains *range-backed* kinds: `.quoteBar` and `.codeBlockBackground` carry a character range, and drawing enumerates every visual line fragment intersecting the range (soft-wrapped lines included). Corner rounding keys off the first and last *visual fragments* of the range, not source lines. Quote text sets in full-size serif italic behind its accent bar; code blocks get a quiet background card. A bounded extension of existing machinery — nothing enters text storage — but explicitly range-plus-fragment-enumeration, not single-anchor. Thematic breaks and tables keep their current drawing, restyled to the new palette.

**1d. Honest performance boundary.** Edit-time styling remains today's debounced whole-document pass; this section adds no per-edit cost beyond it (same span count, decorations computed in the same pass). A true edit-delta/dirty-range styling pipeline stays future work, tracked separately — this spec does not claim bounded edit-time styling, only bounded *cursor-move* styling (which already ships).

**1e. Explicitly unchanged.** Byte fidelity, cursor-line reveal, checkboxes, wikilinks, lists, image painting, autosave. Syntax highlighting inside code blocks is out of scope this round.

### Testing

Attribute-level tests: trait composition (serif bold in body, sans bold in table cell, nested bold-italic), measure computation (pure function of pane width and zoom; clamps and centers), decoration emission for quote/code blocks. Byte-fidelity and bounded-restyle regressions stay green. Visual check on a long real document at several zoom levels.

---

## 2. Memory efficiency + history-to-the-start guarantee

### Current state (measured)

Checked-in `footprint` receipts: 84–168 MiB across gate workloads — but gates run at 5,000 scrollback lines while the shipping default is 20,000. Top consumers: SwiftTerm cell buffers (24 B/cell × scrollback × columns × parked + mounted surfaces), retained `TerminalDocument` strings (16 MiB cap each; bytes past ~4 MiB unreachable by the renderer per the code's own comments), per-window WebKit processes (fresh configuration per webview), the broker's per-terminal 1 MiB hot cache that never releases, and a markdown image cache charging decoded bitmaps at file-size cost while the layout manager holds every image strongly.

### The history guarantee (Michael's ask)

Terminal lines must be recoverable to the very start of a session — especially claude/codex sessions — across reboots. Append-only spools and history paging already exist, but review confirmed a real gap: **after a resurrection, `readStartBytes` hides all pre-restart bytes from `terminal.history`, and the app discards the `recovered` payload — pre-reboot scrollback is currently unreachable.** The fix makes the spool the single continuous transcript:

- **2h-1. Cross-epoch continuous offsets, with split boundaries.** A restore-spawn initializes the new stream's offset at the retained spool's byte count, so transcript offsets are monotonic across restarts, and `terminal.history` pages the whole spool — pre-restart bytes included — back to offset zero. Critically, the *live* boundary stays separate: the spool records an `epochStartOffset` at each restore, and `snapshot()` (what feeds a fresh SwiftTerm parser on create/subscribe) never serves bytes before it — old ANSI must not replay into a new parser (the existing surface invariant). Only the transcript pager crosses epochs. `readStartBytes` and the `recovered` payload are retired (`recovered` stays `null` on the wire until the Swift decoder drops it). The changed history semantics ship behind a new `terminal-history-continuous-v1` broker feature flag; the Swift side falls back to current behavior against older live brokers.
- **2h-1b. Ended terminals still serve history.** A restore for a terminal whose spool meta says it ended (see 4b) does not spawn a shell; the broker registers a *cold record* — no PTY, `exited: true`, no pid — that serves `terminal.history` and snapshots from the retained spool. `TerminalCreation` decoding tolerates the missing pid; the pane renders the ended state with its transcript reachable.
- **2h-2. Retention pinned by tests.** An interactive terminal's spool never rotates or truncates (`retentionCap == null` path), and history pages reach offset zero after a restart with pre-restart content intact.
- **2h-3. The view is a window.** Live-view scrollback defaults to 5,000 lines. Scrolling past its top opens the transcript viewer *pre-positioned at the boundary* with matching monospace styling — a deliberate, one-gesture handoff with position continuity, not a promise of seamless inline scrolling (an inline hybrid scroller is explicitly deferred). `release()` (explicit close) still deletes the spool — closed means closed (section 4).

### Changes (in descending yield)

- **2a.** `TerminalSurfaceCache.store` trims a parked view's scrollback **only when the view is pinned to the live bottom**; a parked view scrolled into history keeps its buffer (and its scroll position). Parked cap drops 6 → 3.
- **2b.** `terminalScrollbackLines` default 20,000 → 5,000 (range unchanged; customized values respected), paired with 2h-3.
- **2c.** `TerminalDocument.maximumRetainedBytes` 16 MiB → 5 MiB, trim target 4 MiB; protected surfaces clamp to the cap so the 96 MiB budget is real. (A process-wide budget across windows is deferred; the acceptance workload is per-window.)
- **2d.** Broker derives spool hot-cache visibility from its observer count — cache fills only while at least one subscriber is attached, drops on last unsubscribe. No new RPC; one window can't clear another's state because the rule is count-based.
- **2e.** All webviews share one `WKProcessPool` only — each surface keeps its own hardened configuration and its own non-persistent data store (the CodeMirror scheme handler and script bridges must not leak to preview/browser surfaces). Acceptance is measured: WebContent process count and RSS before/after.
- **2f.** Markdown images: cache cost = decoded pixel bytes; images downsample to display size on load with **size-bucketed cache keys** (a 1x narrow decode never serves a 2x wide view); the layout manager bounds strong placements to a window around the viewport (not deferred — the strong retention is source-confirmed).
- **2g.** A process-wide memory-pressure source purges parked surfaces, the image cache, backdrop bakes, the project file index, and payload caches on warning/critical.
- **2i.** Small bounds: `ProjectFileIndex` evicts closed-project roots; `PayloadCache` capped; `BrokerLineFrameDecoder` releases high-water capacity above 64 KiB.
- **2j.** Resource gates re-run at shipping scrollback; a new gate workload covers three saturated terminals. The *enforced* acceptance is per-window (the caps in 2a–2c are per-window mechanisms); the three-window restored workload under 150 MiB app+broker is the tracked measurement target, not a hard gate, until the deferred process-wide budget lands. No streaming-latency regression either way.

Deferred (structural): process-wide terminal byte budget; ACP attachments as file references.

### Testing

Unit tests per cap/eviction; broker tests for observer-count-driven cache release and cross-epoch history continuity (spawn → output → simulated restart → restore → history reaches pre-restart bytes and offset zero); gate receipts as the acceptance measure.

---

## 3. Settings overhaul: layout, updater honesty, live usage

### Current state

`SettingsView.swift` (1,193 lines) hand-rolls a sidebar with 11 flat sections; the General pane is a 212-line builder; the Agents *and* Guardrails panes use `Form` against the `SettingsCard` idiom; backgrounds are inconsistent; the window's `minSize` (760×500) is below the view's `minWidth` (820); the in-app sheet drops `updateDetail` and `interruptibleTurnCount`. The update row never shows the installed version, gives no feedback while checking, models only pending/not-pending, and never clears stale pending state. Usage stats fetch only on window appear, project switch, pane open, or manual refresh; each cold fetch spawns one Node subprocess per account and busy-waits in a 50 ms `Thread.sleep` loop.

### Changes

**3a. Grouped navigation.** Sidebar groups under quiet headers: **App** (General, Software Updates), **Workspace** (Terminal, Guardrails, Shortcuts), **Agents** (Agents, Models, Accounts, MCP, Usage), **Device** (Companion). The section enum becomes internal so selection stops round-tripping through strings. Window `contentRect`/`minSize` match the view minimum; uniform `.scrollContentBackground(.hidden)`; Agents and Guardrails panes convert to the card idiom.

**3b. File split.** `SettingsView.swift` shrinks to shell (navigation + routing); General, Updates, Terminal, Guardrails panes and the glob types move to their own files per the `*SettingsTab.swift` pattern.

**3c. One settings surface.** The sheet passes the full argument set; `Check Now` respects `availability.canCheck` in both entry points.

**3d. Honest update row — two independent axes.** `UpdateCenter` publishes `checkStatus: idle(lastChecked:) | checking | upToDate(at:) | failed(reason:)` *separately from* `pendingUpdate` (which keeps holding Sparkle's live install closure — clearing check state must never discard a handed-over install block). Every Sparkle delegate callback maps to an explicit transition; late results are generation-fenced so an abandoned check can't overwrite a newer one. The row always shows the installed version and last-checked time, a spinner during checks, inline failure reasons, and "Restart and Update" only while Sparkle actually holds an install. `sparkleIsPresentingUpdate` gates Kaisola's affordance so the two UIs never fight.

**3e. Live usage.** `UsageCenter` owns a background refresh loop: every 5 minutes while the app is active, refreshing **the frontmost window's workspace only** (the existing active-model resolver), non-forced so the 180 s TTL coalesces; suspended while inactive; re-armed on `didBecomeActive`/`didWake`. Published state becomes **keyed by context** (the existing context key): each window's footer chip and Usage pane read their own workspace's entry, so a focus change never shows another workspace's numbers while waiting for the next tick. The busy-wait becomes a cancellation-aware `terminationHandler` continuation that drains stdout/stderr (no pipe deadlock). Snapshot writes debounce. The Sparkle transition table in 3d and this loop's state chart are enumerated fully in the implementation plan.

### Testing

Grouping/routing tests; update-axes tests (every Sparkle transition, including session-ended with a pending install — closure must survive; generation fencing); usage loop with injected clock (active-only ticks, TTL coalescing, cancellation mid-fetch); sheet/window capability parity test.

---

## 4. Closed things stay closed

### Current state (bug map, ranked)

v0.1.107's resurrection turned a pre-existing leak into self-reinstating state: (1) ended/exited terminals are never pruned from `native-sessions.json`, so after a broker restart they respawn; (2) respawn re-opens closed project tabs and deletes ⌘⇧T undo entries; (3) `closeProject` leaves records/panes everywhere and the tab re-derives from live sessions; (4) workspace restore has no open-project gate; (5) `endSession` silently no-ops while disconnected; (6) failed release abandons the close; (7) dormant panes have no close affordance; (8) reconnect re-adopts closed records; (9) chat deletion persists via a 220 ms debounce; (10) mesh `pendingDeletion` flips back to `.suspended` on restore; (13) dormant ids leak across projects; (quit) `endSession` is unawaited at teardown.

### Principle

Closing is user intent. The close commits **locally and durably first** — one synchronous store transaction before any await — and broker cleanup is best-effort behind it. Nothing the user closed may be resurrected by restore, reconnect, respawn, or another window.

### Changes

- **4a. Close commits in-memory first, durably in order.** `NativeSessionStore` gains a lifecycle mutation that, in one operation: removes the session record, adds a **tombstone**, pushes the undo entry, and queues a **pending release** (`projectID`+`id`). The close entry points call this **synchronously in the button handler, before spawning any Task** — so a ⌘Q in the same runloop turn (or a teardown snapshot) already sees the truth, even if the broker-cleanup Task never got its first turn. The in-memory payload mutates synchronously; the disk write is ordered-async, and teardown/quit flushes pending store writes before its workspace snapshot (a hard crash in that sub-second window is the accepted residual risk — quit is fully covered). Write failure surfaces to the user (toast) rather than reporting success. The broker release drains from the pending-release queue, retried each connect until acknowledged, idempotent; because an "already absent" acknowledgment cannot fence a concurrently in-flight create from another connection, any create that completes for an id found tombstoned afterward triggers a **compensating release** immediately. The disconnected, dormant, and exited cases all route through the same mutation; "End Session" appears for exited and dormant panes, and the "Session unavailable" tile gets a Close button.
- **4a-1. Tombstones are permanent; undo stacks stay bounded.** `closedTerminals` tombstones and closed-project markers are small, unbounded closed-state sets — a tombstone is dropped only when its pending release is acknowledged AND no record or archived pane for the id exists anywhere. The 10/50-deep undo *stacks* remain bounded UI conveniences; eviction from an undo stack never weakens the closed-state guarantee.
- **4b. Ended is remembered, with durable evidence — and exit-reason semantics.** `NativeOwnedSession` gains `endedAt: Int64?`, stamped from exit events AND from inventory reconciliation. The broker persists `exitedAt` into the spool's meta file **only on natural PTY exit** — never during `killAll`/managed shutdown, where the broker itself kills PTYs it fully intends to restore (a shutdown flag suppresses the stamp). A restore that finds `exitedAt` registers the cold record from 2h-1b (history reachable, no shell). Resurrection skips any record with `endedAt`; `reopenEndedSession` removes the old record when creating its replacement.
- **4c. Resurrection is polite and tombstone-aware.** `createOwnedSession(restore: true)` never calls `sessionStore.openProject` and never touches the closed-projects stack; `resurrectDormantTerminals` processes only records whose project is open, and **re-checks the tombstone set and record existence after every await** (each spawn is a suspension point during which another actor may close the id); `syncTrackedWorkingDirectories` and `recoverOwnedSessions` refuse tombstoned ids; store upserts refuse tombstoned ids at the store layer, so no caller can resurrect one by accident. Dormant sets filter by project (fixes 13). A full multi-window lifecycle coordinator is deferred; these conditional store-layer guards are the enforced invariant in the meantime.
- **4d. Closed projects disappear, with eyes open.** The `projects` derivation excludes closed projects; workspace restore skips closed projects' chats/meshes/layouts (state stays on disk; ⌘⇧T reopen restores everything). Closing a project that still has running work shows a confirmation naming what keeps running in the background; the attention inbox continues to surface those sessions' events so running work is never invisible. `closedProjects` cap rises to 50 and entries survive until reopened. The `AppModelProjectContextTests` assertion that Recently-Closed work forces a project visible is deliberately inverted.
- **4e. Deletion is durable and phase-tested.** Chat deletion tombstones live in the transcript store itself (a `deleted_chats` table in the SQLite database — process-wide, so every window's write and restore paths consult it), written first, then memory removal, then idempotent garbage collection of transcript, draft, and usage; tombstones drain once no references remain. `AcpTranscriptStore.remove` failures surface. Tests inject failures between each phase. A mesh restored with `lifecycle == .pendingDeletion` branches *before* ordinary restore: no adapters start, the destroy manifest resumes, and failure leaves a retryable recovery card — never a live mesh.
- **4f. Quit needs no joins.** Because 4a commits close transactions synchronously before any await, `persistWorkspaceStateNow` at teardown always sees the truth; teardown does NOT await broker releases (they retry from the pending queue next launch), preserving the bounded 12 s shutdown budget.

### Testing

One failing-first test per numbered path, plus: close-while-disconnected commits and survives relaunch; tombstoned id refused by upsert/re-adoption/cwd-sync; resurrection re-check after suspension (simulated interleaved close); pending release retries then acknowledges; exited-at evidence via inventory with events suppressed; restore-spawn honors spool-meta `exitedAt`; chat-deletion phase injection; mesh destroy-resume; quit-after-close persists absence within the shutdown budget. End-to-end: close a session and a project, kill the broker, relaunch — nothing returns.

### Ship order

The broker-spool foundation ships first as one migration — exit-reason meta, cold records, continuous offsets with the `epochStartOffset` live/history split, and the `terminal-history-continuous-v1` feature flag — because sections 4b and 2h depend on the same schema and shipping section 4 without it would emit restore results the Swift client can't represent. Then section 4's native changes (store schema + transactions + guards → route all paths → tests → UI derivation/restore filtering), then the rest of 2 (history handoff before the scrollback default drops), then 3 and 1 in either order.
