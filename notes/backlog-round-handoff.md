# Backlog round (BACKLOG.md) — handoff

## ROUND 2 (after Michael reviewed the merged build)

All three round-1 tracks are merged into branch **`backlog-integration`** (worktree `.claude/worktrees/backlog-integration`), which builds clean and passes the changed lane. Michael reviewed that build and said: blue selected row ✅ good ("make it easier to open new sessions"); dark glass ✗ "still reads flat and a little [cast]" + "push everything to its fullest extent so it fills the empty space"; tables ✗ wants them rendered AND editable in place.

| Round-2 track | Worktree / branch | Head | State |
|---|---|---|---|
| Tables | `agent-ac106ec8ad43471c7` | `27bd5bc` | ✅ **COMPLETE** |
| Shell (glass depth + space + new-session affordance) | `agent-a69134e1c285395a0` | — | in flight at last save |

**Tables (`c800e36`, `b7ef9fb`, `9b8e27d`, `27bd5bc`)** — rendered via pure text attributes, no widget: `.kern` on the padding runs between pipes pushes columns onto shared x positions (per-column alignment for `:---`/`---:`/`:---:`), pipes dim into vertical rules, the `|---|` row collapses to a 6pt strip with a hairline drawn behind it, header band tinted; `---` gets the same at pane width. Measurement is Core Text over the storage after the inline pass. Over-wide tables scale fonts then fall back to wrapped source. Evidence: col-0 origins identical across 4 rows (892.65), typing widened col 0 by 90.77pt and moved every row's later columns identically; disk grew exactly the 6 bytes typed.
- 🔴 **Latent bug found & fixed:** round one's viewport anchor NEVER RAN — it gated on `contentView.bounds.origin.y > 0`, but this clip holds the text view at frame origin −121883, so external reconciliation jumped 15,109pt (47733→33081). Fixed with `documentVisibleRect` + a post-styling anchor. **Touches the shared scroll helper — wants a second reviewer.**
- Known gaps: characters typed inside a table stay unkerned for ~70ms; very wide tables still fall back to raw wrapped source.

---

## ROUND 1 — original handoff, saved 2026-08-01 at usage limit

Base for all three: `main` @ `216196b` (v1.1.9). Each track has its own **locked** worktree
under `.claude/worktrees/`. Nothing merged to main yet; nothing released.

| Track | Worktree / branch | Head | State |
|---|---|---|---|
| Sidebar | `agent-a97c96ad7474af98d` / `worktree-agent-a97c96ad7474af98d` | `01c9c95` | **COMPLETE & verified** — ready to merge |
| Icons + glass | `agent-a9cdc1cf5cf8c1b40` / `worktree-agent-a9cdc1cf5cf8c1b40` | `9a75abc` | **COMPLETE & verified** — ready to merge |
| Markdown | `agent-ad53c236d51188251` / `worktree-agent-ad53c236d51188251` | `f2ea9df` | **COMPLETE & verified** — ready to merge |

## What each track was doing

**Sidebar** (`8f57f45`, `f4630bf`, `01c9c95`) — ✅ **COMPLETE, verified, ready to merge**

1. ✅ Active project = bold primary (`QuietActiveGlass`/`QuietActiveProjectGlass` deleted); project tint kept only on the 11.5pt identity glyph — one-line revert if Michael wants it monochrome.
2. ✅ Selected row = `Color.accentColor` label on a neutral pill (6% light / 10% dark). A new pure `QuietRowSelection` guarantees exactly one selected row — the old `isSurfaceVisible` rule broke for splits and stale pane layouts. **No live evidence** (the dev broker never connected, so no session row existed) — unit-tested only; worth a human look.
3. ✅ Scroll bug root cause — **not** insets or safe area (both measured zero). It is AppKit's `-[NSTableRowData _keepTopRowStableAtLeastOnce:]` firing inside the `endUpdates` that `SwiftUI.OutlineListCoordinator.diffRows` runs on every row diff; it compensates for rows changing above the top row, which at launch preserves an artefact. Fix: `SidebarScrollTopPin` (3s launch pin, released by any real scroll) + a permanent in-range clamp, both pure with tests. AX: first row was clipped 8pt above the clip view (`-1004.0` vs `-996.0`); now both `-996.0`.
4. ✅ Top band deleted; both toggles hover-reveal at the pane's top-right; top inset 46→28pt (pane 415→427, Files rail 404→416). Chose hover over the footer because `FooterAccountBudget.nameWidth` would charge the account name 36pt for two more slots and drop it under the character floor. ⌘B/⇧⌘B, View menu, tooltips and AX ids intact. Reclaim is 12pt not 40 — the Files rail's own header controls collide with the toggles if the card runs to the window top (caught by AX mid-implementation).

## ⚠️ Known merge conflict
The sidebar track edited one test in `NativePreviewSettingsTests.swift` (it asserted the now-deleted 40pt band) and the icons+glass track rewrote wash/tint constants in the same file. Expect a conflict there and resolve by keeping BOTH: the sidebar's band-assertion removal and the glass track's new constants. `RootShellView.swift` is sidebar-only; `NativePreviewSettings.swift` is glass-only — no conflict expected in either.

**(older paused-state notes below)**
1. ✅ Active project = **bold**, tinted capsule deleted.
2. ✅ Displayed session row = accent-blue label on a soft neutral pill (Safari reference).
3. ✅ Scroll bug fixed — "hold the project rail at its top through launch" (first project no longer scrolls out of view).
4. ⏳ WIP: relocate the two content-top toggles (Files ◫ + document preview) out of the wasted top band into the sidebar footer cluster; keep ⌘B / ⇧⌘B + View menu + tooltips. `RootShellView.swift` + `NativePreviewSettingsTests.swift` are mid-edit — REVIEW THE WIP DIFF before continuing; it may not compile.

**Icons + glass** (`6b54732`, `8103ab2`, `42aade7`, `16af008`, `9a75abc`) — ✅ **COMPLETE, verified, ready to merge**

1. Detection fixed and **live-verified**: `foregroundName` scans the whole chain, shallowest agent wins; marker matching narrowed to argv[0] (+ a script behind a runtime) so `zsh -c source ~/.claude/…` no longer false-positives. Real captured chains — claude: `zsh -i` → `claude` → `zsh -c source …/shell-snapshots/…` → `sleep 10`; codex: `-zsh` → `node …/bin/codex` → `…/vendor/…/bin/codex` → `node ./mcp/server.cjs`. Live collector run against a real pty returned `"claude"` and `"codex"`; a negative control failed first, proving the harness reached the app.
2. Real knot: official outline transcribed (arcs→cubics, 8 subpaths / 36 cubics / 32 lines, non-zero fill), **IoU 0.333 → 0.983** vs `assets/backlog/pasted-image.png`, ink matched to the starburst (0.308 vs 0.314). Starburst geometry deliberately left alone (a re-trace scored only 0.44); coral `#D97757` confirmed exact.
3. Tinted canvas now visibly distinct: was 0.016 off-neutral vs Solid's 0.000 (invisible). Light Solid 1.000/1.000/1.000 → Tinted 0.816/0.941/1.000 (off-neutral 0.113); dark Solid 0.118 flat → Tinted 0.163/0.216/0.240 (0.209). "System" renamed **Solid**.
4. Dark glass: composite `0.055/0.114/0.143` → `0.078/0.106/0.119`; off-neutral **0.473 → 0.229** (it used to out-saturate the wallpaper 1.27×, now 0.57×); luminance spread 0.060 → 0.072; contrast 12.8:1 primary / 6.0:1 secondary.

⚠️ Open taste question: dark is still 0.229 off-neutral vs light's 0.059 — exact parity needs saturation ≈0.08, which greys the wallpaper out entirely. Michael should judge the new dark on screen before anyone chases parity. Also: the knot's IoU is recorded in comments, not enforced in CI.

**(superseded notes from the paused state below — the pre-diagnosis that led to the fix)**
1. Claude/Codex CLI detection. **Root cause (confirmed, pre-diagnosed):** `TerminalMetaService.processChains` descends to the deepest child and `collect` names the terminal from `chain.last` (~:106-117); a running `claude` spawns helpers (`rg`, `bash`, `sleep`) so the leaf is never `claude`. `processName(fromCommand:)` (~:228) already matches the markers correctly — it is applied to the wrong process. Fix = scan the whole chain, shallowest agent match wins, fall back to leaf. This is also why the mark "isn't orange": it never resolved to `.claude`, the coral (#D97757, QuietIdentityMark.swift:96) was always right.
2. Real OpenAI/ChatGPT knot to replace the six-stadium approximation (reference: `assets/backlog/pasted-image.png`; transcribing the official SVG or embedding a vector asset was authorized).
3. Tinted vs solid/white canvas options must render visibly differently.
4. Dark-mode glass: currently reads purple/blue and flat; retune for a translucent glassy read, text contrast ≥7:1 primary / ≥4.5:1 secondary.

**Markdown** (`d1fbe9d`, `1b64764`, `f2ea9df`) — ✅ **COMPLETE, verified, ready to merge**

Architecture chosen: **(A) one continuous TextKit 2 NSTextView** over the whole source. Byte fidelity became *stronger*, not weaker — the exact-range write path is gone entirely, so there is no write to get wrong.

Both jump causes were real and independent:
1. `MarkdownSourceBlock.id` was the block's *source location* (`MarkdownPreview.swift:564`) while `updateActiveText` shifted every later block's location on each keystroke (`:1264-1278`) → SwiftUI re-identified and rebuilt the whole `LazyVStack` below the caret, and that `ScrollView` (`:980`) had no position retention at all.
2. `imageRevision` was the watcher's monotonic token (`FilePreviewView.swift:794`), which the document's own 700 ms autosave advanced → `MarkdownAssets.swift:334-337` blanked every image to a 64 pt placeholder → height collapsed → offset clamped upward.

Evidence: two edits at char 52000 grew a 105 KB file by exactly +18 and +12 bytes with one line changed in `git diff`; a new test round-trips a doc with relative images, `<img>`, a table, a fence and a CR ending unchanged. AX on `notes/native-audit-2026-07-30.md` held visible range 51146 and offset −22489.0 across typing, autosave, explicit ⌘S, and an external revert.

⚠️ **Decision needed before/at merge:** tables and `---` thematic breaks now render as **source text**, and table-cell editing is gone — a real regression traded for the continuous editor. `MarkdownTableSource` / `MarkdownTableNavigation` / `MarkdownSourceBlockCache` were kept (with tests) as the basis for a follow-up that restores table rendering. Also expect CI `preview*` visual baselines to move.

## Resuming
1. Per track: `cd` into its worktree, read `.superpowers/sdd/backlog-*-report.md` if written, inspect the wip diff, finish the remaining item, then verify: `npm run native:fast:build` (warning-clean) + `npm run native:test:focus -- <suites>` + `npm run native:test:changed -- --include-working-tree`.
2. Review each track (diff vs `216196b`) before merging.
3. Merge tracks into `main` one at a time (sidebar → icons/glass → markdown), rebuilding + running the changed lane after each; resolve overlaps in `NativePreviewSettingsTests.swift` (touched by two tracks) and `RootShellView.swift`.
4. Release: `npm run release:fast -- 1.2.0 "<summary>"` from `main`, then rerun the failed `release` promote workflow once the candidate finishes (`gh run rerun <id>` — the tag lane always fails first by design).
5. Add a CHANGELOG.md entry FIRST, in the house style: `## 1.2.0 — <date>` + 3-5 one-line plain-language bullets.

## Repo rules that bit us before
- Never touch `/Applications/Kaisola.app` or shared defaults (`defaults delete com.kaisola.mac` disrupted Michael's settings once — dev and production share that domain).
- Dev launches only: `KAISOLA_NATIVE_BROKER_PROFILE=development npm run native:fast -- --refresh-helper`, then `kill -TERM <pid>`.
- AX via pid-exact `AXUIElementCreateApplication`; System Events whose-clauses silently hit the production app.
- `scripts/native-test-fast.sh --verbose` is broken (unbound `LOG_ARGS`).
- Screenshots are TCC-blocked for agents — verify geometry via AX frames, appearance by arithmetic.
- No `Co-Authored-By` / AI-attribution trailers in commits, ever.

## Also stale
`.claude/worktrees/quiet-fleet-sidebar` holds an older dead agent's abandoned edits (pre-v1.1.8). Do not merge from it; it can be removed once nothing references it.

## QUEUED NEXT — steering (Michael's spec, 2026-08-02)

Both adapters advertise `_meta.steering.supported: true` and expose `_session/steering` (inject into a RUNNING turn); Kaisola currently only queues (`AcpClient.swift:963` reads `promptQueueing` only).

**Michael's design (binding):**
- **Default stays queue-between-tool-calls** — sending mid-turn still queues, nothing becomes riskier by default.
- **Each queued message gets a button that injects it as a steering prompt** — an explicit per-message escalation from "wait your turn" to "interrupt now".
- So the queued-message strip needs a per-row action (alongside the existing remove), enabled only when the adapter advertises steering and a turn is actually running.

Also queued from the ACP/MCP audit (2026-08-02), in priority order:
1. `user_message_chunk` is dropped in `handleSessionUpdate` (`AcpClient.swift:762` falls to `default: break`) → **resumed chats show the assistant's replies but not the user's own prompts**. One `case`. Real bug.
2. MCP probe exact-match fix — in flight (agent `ad613bd7bbd816dad`).
3. Steering (above).
4. `session/list` + `session/fork` are advertised but unused → past-session browser / branch-a-conversation. New features, not bugs.
5. Delete the dead `session/set_model` path (`AcpClient.swift:316`, `AcpConversation.swift:602`) — ACP dropped the method; model switching already works via `session/set_config_option`.

ACP is CURRENT (wire v1; v2 is an un-negotiated draft). MCP spec revision is 2 behind but Kaisola is not the MCP client — only the Settings badge is affected.
