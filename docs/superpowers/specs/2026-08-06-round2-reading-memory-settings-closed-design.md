# Round 2: serif reading, memory efficiency, settings overhaul, closed-stays-closed (2026-08-06)

Four workstreams approved by Michael on 2026-08-06 (evening). Section 4 is a bug-fix track and ships first as its own release. The round-1 performance principle carries over: nothing blocks the main thread or launch; disk is free to spend; RAM is the scarce resource this round.

---

## 1. Serif reading typography in the Live Preview

### Current state

The markdown editor (`FilePreviewEditors.swift`) renders the file's exact bytes with real text-storage attributes: system sans body (`MarkdownEditingStyle.baseAttributes`), heading sizes `[30, 25, 21, 18, 16, 15]`, full-width text container, quotes as gray oblique text, code as monospaced runs with a background color.

### Changes

**1a. Reading face.** Body text becomes the system serif (New York: `NSFont` with `.serif` design) at 16 pt with line spacing tuned to ~1.5 leading. Headings stay sans (SF Pro) for contrast, retuned scale with tightened tracking on H1/H2. Bold/italic map to the serif's own weights and true italics (replacing the `obliqueness` skew for body italics). Inline code and code blocks stay monospaced; tables stay sans (grid legibility beats warmth there).

**1b. Reading measure.** The text column caps at a comfortable measure (about 70 characters of the body face, ≈ 620 pt) and centers when the pane is wider, via the text container inset — the pane keeps its width, the text gets margins, LessWrong-style. Below the cap, behavior is unchanged. Zoom scales the measure with the type.

**1c. Block styling.** Blockquotes: serif italic at full size (not gray), with a soft accent bar drawn by the existing layout-manager decoration path (same machinery as table decorations — nothing enters storage). Code blocks: a quiet rounded card behind the run (decoration-drawn), monospaced at a size that harmonizes with the serif body. Thematic breaks and tables keep their current drawing, restyled to the new palette.

**1d. Explicitly unchanged.** Byte fidelity, the incremental restyle pass, cursor-line reveal, checkboxes, wikilinks, lists, image painting, autosave. Syntax highlighting inside code blocks is out of scope this round.

### Testing

Attribute-level unit tests: base/heading/quote attributes report the intended fonts and spacing; measure computation (pure function of pane width and zoom) clamps and centers correctly. Byte-fidelity and bounded-restyle regression tests already exist and must stay green. Visual check on a long real document.

---

## 2. Memory efficiency + history-to-the-start guarantee

### Current state (measured)

Checked-in `footprint` receipts: 84–168 MiB across gate workloads — but the gates run at 5,000 scrollback lines while the shipping default is 20,000, so production is understated on the single largest consumer. Top consumers from the audit: SwiftTerm cell buffers (24 B/cell × scrollback × columns, × up to 6 parked + 8 mounted surfaces), retained `TerminalDocument` strings (16 MiB cap each, bytes past ~4 MiB unreachable by the renderer per the code's own comments), per-window WebKit processes (fresh configuration per webview, no shared pool), the broker's per-terminal 1 MiB hot cache that never releases (nothing ever calls `detachRenderer`), and a markdown image cache that charges decoded bitmaps at file-on-disk cost (10–20x undercount) while the layout manager holds every image strongly.

### The history guarantee (Michael's ask)

Terminal lines must be recoverable to the very start of a session — especially claude/codex sessions. This is already the disk-side design: user terminals get append-only spools (`retentionCap == null` skips the two-segment rotation entirely), `terminal.history` pages back to the first byte, and round 1's durable appends made it reboot-proof. This round pins it:

- Tests assert an interactive terminal's spool never rotates or truncates and history pages reach offset zero after gigabytes of output.
- The live-view scrollback buffer becomes a *window* (default 5,000 lines), and scrolling past its top hands off to the transcript viewer (the `onHistoryBoundary` path that already exists) which pages the full spool. The handoff must feel like continuous scrolling, not a mode switch: same font, position continuity.
- `release()` (explicit close) still deletes the spool — closed means closed (section 4). Everything else keeps its spool forever.

### Changes (in descending yield)

- **2a.** `TerminalSurfaceCache.store` trims a parked view's scrollback to a small depth and `claim` restores the setting; parked views are by definition not being scrolled. Cap parked surfaces at 3 (from 6).
- **2b.** `terminalScrollbackLines` default 20,000 → 5,000 (range unchanged; users who customized keep their value). Paired with the history handoff above so nothing is lost.
- **2c.** `TerminalDocument.maximumRetainedBytes` 16 MiB → 5 MiB, trim target 4 MiB; clamp protected surfaces to the cap so the 96 MiB budget is real.
- **2d.** Broker: spool RAM cache visibility follows attached renderers/observers — the Swift side sends `detachRenderer` when a surface unmounts, or the broker derives visibility from subscription count. Frees ~1–1.5 MiB × every terminal ever attached.
- **2e.** One shared `WKProcessPool`/configuration for the CodeMirror editor, HTML preview, and browser card, so all webviews share one WebContent process.
- **2f.** Markdown image cache: cost = decoded pixel bytes (`pixelsWide × pixelsHigh × 4`), and images downsample to display size on load. Layout manager keeps only placements for a bounded window around the viewport if the strong-hold proves hot after the cost fix.
- **2g.** A process-wide memory-pressure source (`DispatchSource.makeMemoryPressureSource`) that on warning/critical purges: parked surfaces, the image cache, backdrop bakes, the project file index, and payload caches.
- **2h.** Small bounds: `ProjectFileIndex` evicts closed-project roots; `PayloadCache` capped; `BrokerLineFrameDecoder` releases high-water capacity above 64 KiB after large frames.
- **2i.** Resource gates re-run at shipping scrollback; receipts updated; a new gate workload covers "three saturated terminals" so the dominant consumer is measured.

Deferred (structural, noted for a later round): per-process rather than per-window terminal byte budget; ACP attachments as file references instead of in-memory `Data`.

### Testing

Unit tests per cap/eviction; broker test for visibility-driven cache release; gate receipts as the acceptance measure (target: three-window restored workload under 150 MiB app + broker at shipping settings, and no regression in streaming latency).

---

## 3. Settings overhaul: layout, updater honesty, live usage

### Current state

`SettingsView.swift` (1,193 lines) hand-rolls a sidebar with 11 flat sections; the General pane is a 212-line builder; one pane still uses `Form`; backgrounds are applied inconsistently; the window's `minSize` (760×500) is smaller than the view's `minWidth` (820) so first layout fights; the in-app sheet path drops `updateDetail` and `interruptibleTurnCount`. The update row never shows the installed version, gives zero feedback while checking (`lastUpdateCheckDate` exists and is never read), models only pending/not-pending (no checking/failed/up-to-date), and never clears a stale pending state. Usage stats fetch only on window appear, project switch, pane open, or manual refresh — a 180 s TTL in-memory cache with disk snapshots, one Node subprocess per account per cold fetch, and a blocking 50 ms `Thread.sleep` poll loop per fetch.

### Changes

**3a. Grouped navigation.** Sidebar sections group under quiet headers: **App** (General, Software Updates), **Workspace** (Terminal, Guardrails, Shortcuts), **Agents** (Agents, Models, Accounts, MCP, Usage), **Device** (Companion). Selection model becomes the enum (no `String` round-trip). The window `contentRect`/`minSize` match the view's minimum; every pane gets the same `.scrollContentBackground(.hidden)` treatment; the Agents pane converts from `Form` to the `SettingsCard`/`SettingsRow` idiom.

**3b. File split.** `SettingsView.swift` shrinks to the shell (navigation + routing): General, Updates, Terminal panes and the guardrails/glob types move to their own files, following the existing `*SettingsTab.swift` pattern.

**3c. One settings surface.** The in-app sheet passes the full argument set (updateDetail, interruptibleTurnCount) so both entry points are equally capable; `Check Now` respects `availability.canCheck` in both.

**3d. Honest update row.** An `UpdateCenter`-owned state machine: `idle(lastChecked:) → checking → upToDate | ready(version:) | failed(reason:)`. The row shows the installed version always ("Kaisola 0.1.108 — last checked 12 min ago"), a spinner during checks, the failure reason inline on failure, and "Restart and Update" only while Sparkle actually holds a pending install (pending state clears when Sparkle's session ends). `sparkleIsPresentingUpdate` finally gates Kaisola's own affordance so the two UIs never fight.

**3e. Live usage.** `UsageCenter` owns a background refresh loop: every 5 minutes while the app is active (non-forced, so the 180 s TTL keeps coalescing), suspended while inactive/hidden, re-armed on `didBecomeActive` and `didWake` (matching the remembered-sessions loop pattern at `KaisolaMacAppDelegate.swift:2221`). The per-fetch busy-wait converts to a `terminationHandler` continuation. The footer chip, onboarding readiness, and headroom advice all consume the same published state and get fresher for free. Snapshot writes debounce.

### Testing

Section-grouping and routing unit tests; update state machine tests (every transition, including Sparkle-session-ended clearing pending); usage loop tests via injected clock (ticks only while active, coalesces under TTL, force paths unchanged); a test that the sheet and window construct settings with identical capability.

---

## 4. Closed things stay closed

### Current state (bug map, ranked)

v0.1.107's resurrection turned a pre-existing leak into visible self-reinstating state. The full map: (1) ended/exited terminals are never pruned from `native-sessions.json` (End Session is hidden for exited terminals; `sessionStore.remove` has two callers), so after any broker restart they respawn; (2) respawn calls `sessionStore.openProject`, which re-opens a closed project's tab AND deletes its ⌘⇧T undo entry; (3) `closeProject` leaves records/panes everywhere and the project tab re-derives from live sessions, test-enforced; (4) workspace restore iterates every archived project with no open-project gate; (5) `endSession` silently no-ops when the broker is down; (6) a failed release abandons the close; (7) dormant panes have no reachable close affordance; (8) broker reconnect can re-adopt a record the user's close removed (signature: title == project name); (9) chat deletion persists only via a 220 ms debounce; (10) a mesh marked `pendingDeletion` flips back to `.suspended` on restore; (13) dormant ids leak across projects in normalization; (quit) `endSession` is unawaited by `teardown`, so close-then-⌘Q re-saves the pane.

### Principle

Closing is user intent. The record dies first, synchronously, unconditionally; broker cleanup is best-effort. Nothing the user closed may ever be resurrected by restore, reconnect, or respawn.

### Changes

- **4a. Close always lands.** `endSession` removes the store record and the pane immediately — before and regardless of the broker release. When connected, release proceeds; on failure it retries once on the next connect (a small persisted pending-release list) instead of resurrecting the record. The disconnected/dormant/exited cases all route through the same removal. "End Session" becomes available for exited and dormant/unavailable panes (routing to the appropriate cleanup), and the "Session unavailable" tile gets a Close button.
- **4b. Ended is remembered.** `NativeOwnedSession` gains `endedAt: Int64?`. The broker exit event stamps it. Resurrection skips any record with `endedAt != nil`; `reopenEndedSession` removes the old record when it creates the replacement.
- **4c. Resurrection is polite.** `createOwnedSession(restore: true)` never calls `sessionStore.openProject` and never touches the closed-projects stack; `resurrectDormantTerminals` processes only records whose project is currently open; dormant sets filter by project in normalization (fixes 13).
- **4d. Tombstones beat re-adoption.** `recoverOwnedSessions` skips any broker record whose id appears in the closed-sessions stack (the stack entry already exists — it becomes the tombstone). Stack cap rises from 10 to 50 so tombstones survive long enough to matter.
- **4e. Closed projects disappear.** The `projects` derivation excludes projects present in the closed stack (a closed project with live sessions/chats/Recently Closed no longer forces its tab back); `restoreWorkspaceStateIfNeeded` skips restoring chats/meshes/layouts for closed projects (their state stays on disk for ⌘⇧T reopen, which restores everything). The `AppModelProjectContextTests` assertion that a Recently-Closed project must stay visible is deliberately inverted — reopen is the recovery path now.
- **4f. Deletion is durable.** `deleteChat` persists the removal immediately (same ordering as `deleteRecentlyClosedSurface`: durable store first, then memory). A mesh restored with `lifecycle == .pendingDeletion` stays `pendingDeletion` (no flip to `.suspended`) and completes its tombstone instead of coming back to life.
- **4g. Quit joins closes.** In-flight `endSession`/`endDormantSession` tasks register in a drain set that `teardown` awaits before its first `persistWorkspaceStateNow`, closing the close-then-⌘Q window.

### Testing

One test per numbered path in the bug map, each written to fail against HEAD first: end-while-disconnected removes the record; exited terminals never resurrect; resurrection doesn't reopen closed projects or eat undo entries; tombstoned ids aren't re-adopted; closed projects stay out of the rail and out of restore; chat delete survives a simulated crash after the call returns; pendingDeletion survives restore; quit-after-close persists the pane's absence. Plus one end-to-end: close a session and a project, kill the broker, relaunch — nothing returns.

### Ship order

Section 4 ships first (bug-fix release), then 2, then 3 and 1 in either order.
