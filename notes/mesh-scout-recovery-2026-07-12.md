# Kaisola Mesh scout recovery — 2026-07-12

This snapshot preserves the completed independent-scout stage from Mesh session `group_013gnpa` before repairing the parked-agent negotiation bug.

## Mission

I just added new things to work on in the backlog.md file, let's all try to fix them and ulpoad it as a new commit!

## Recovery state

- Last completed phase: independent scouting
- Interrupted phase: role negotiation
- Participants: Claude; Codex — GPT-5.6-Sol (xhigh)
- Safe retry point: reuse these scout reports as the peer packet, then rerun the single negotiation round

## Claude scout report

Scout report complete. I read `docs/backlog.md` (8 items) and mapped each to code with a read-only pass; no files were edited. Note: Bash and the kaisola ledger MCP were permission-denied in this session, so I could not check what other agents have claimed — coordination state is a blind spot in this report.

## Model of the problem

The backlog mixes four fundamentally different kinds of work, and "let's all fix them and upload as a new commit" flattens that distinction. Sorting them:

**Small, well-scoped code fixes (safe to just do):**
1. **Sidebar footer reorder** (`docs/backlog.md:3`) — profile avatar should be absolute bottom-left, then settings, then the rest, all on one horizontal baseline. Lives in `src/components/shell/ShellSidebarFooter.tsx` (renders `ShellTools`, `InboxButton`, `AppAccountButton`, settings gear) and `src/components/shell/AppAccountButton.tsx`.
2. **Mesh label overlap** (`docs/backlog.md:15`) — Claude/Codex provider labels overwrite section text in `src/components/GroupAssistant.tsx` (member cards with `ProviderIcon provider={member.agentKey}`). Pure CSS/layout bug.

**A real feature:**
3. **Claude effort models in the mesh** (`docs/backlog.md:5`) — expose effort tiers (low/medium/high/xhigh/max) as selectable model variants for Claude mesh members. Touches `src/store/store.ts` (`setGroupMemberModel`, ~line 3227+), `electron/ipc/acpHandler.cjs` (agent presets + `controls.models.availableModels` wiring, ~line 592), and the mesh member UI. Ambiguity: whether the ACP claude-code adapter actually accepts an effort parameter needs verification before UI work — this is the item most likely to hit a protocol wall.

**Proposal-only items (the backlog's own wording asks for options, not code):**
4. **Hardware-memory review** (`docs/backlog.md:7`) — "propose some options." Deliverable is a measured baseline + options doc. Context from memory: npx elision (directSpawnRewrite) already shipped; native sequentialthinking in the kaisola MCP server is the agreed next step, so that should anchor the proposal.
5. **Close-vs-delete session semantics** (`docs/backlog.md:9`) — "how would we make it…?" is a design question. The code already has the split: `closeTerminal` pushes to `closedStack` with a 60s pty grace period, `reopenClosedSession` restores, and the right-click context menu (Pin / Open beside / Save as template) is exactly where a "Delete" item would go (`src/components/shell/SessionTabs.tsx:297-372`). Notable wrinkle: mesh/group threads are *intentionally never* added to `closedStack` (store.ts ~3364) — closing one is already a hard delete, which any close-vs-delete redesign must reconcile.

**Big-scope / externally-visible items (should not ride along in a batch commit):**
6. **Website update** (`docs/backlog.md:10`) — user explicitly wants Fable on this. Site is `site/index.html` + `site/assets/*.jpg` (GitHub Pages via CNAME). Requirements: un-distorted screenshots, reprioritize content to agents + CLI terminals + orchestration + group agents over files. New screenshots likely need to be captured, not just re-CSS'd.
7. **Delete the `wip-safety-snapshot` tag** (`docs/backlog.md:13`) — a *remote, destructive* GitHub operation (public tag holding 32 commits with Claude co-author trailers). One command, but it must be human-confirmed and is not a file edit at all.
8. **"Do a code review"** (`docs/backlog.md:12`) — not a fix; it's a gate. Should run over the combined diff *after* the other items land on the branch, via `/code-review`.

## Proposed approach

Work on a **feature branch, not main** — this repo auto-releases on every push to main (version bump + tag → installed apps update), so "upload as a new commit" is really "ship v0.1.57." Sequence: (a) land the two small UI fixes and the effort-models feature as separate commits on the branch; (b) write the two proposal docs into `notes/` and post them for human gating rather than acting on them; (c) treat website + tag deletion as separately-approved follow-ups; (d) run the code review over the branch diff as the final gate, then `npm run smoke` (and `group:probe`/`layout:probe` for the mesh/sidebar changes — note `defaultsprobe` exists at `electron/defaultsprobe.cjs` but is *not* wired into package.json scripts) before any push to main.

## Risks

- **Push-to-main = instant release** to installed apps. The single biggest risk of "let's all commit." Mitigate with the branch + smoke-gate sequence above.
- **Merge collisions between agents**: items 1, 5's context-menu, and the tab UI all touch `SessionTabs.tsx`/`store.ts`; items 2 and 3 both touch `GroupAssistant.tsx`/`store.ts`. If two agents take adjacent items, they must not split these files.
- **Tag deletion is irreversible and public**; also GitHub's contributor cache refresh is eventually-consistent — deletion may not immediately clear the attribution, so acceptance should measure the tag's absence, not the cache.
- **Effort-models feature may be blocked by ACP protocol support**; verify the adapter accepts effort before building UI, else the item degrades to "propose."
- **Website screenshots** can't be fixed by CSS alone if the source JPGs are wrong aspect — needs fresh captures at native ratios.
- Per global prefs: **no AI co-authorship trailers** on any of these commits.

## Likely ownership boundaries

- **Owner A (tab/shell surface):** items 1 + 5-proposal — sole writer of `SessionTabs.tsx`, `ShellSidebarFooter.tsx`, `AppAccountButton.tsx`.
- **Owner B (mesh surface):** items 2 + 3 — sole writer of `GroupAssistant.tsx`, `acpHandler.cjs`, and the group-member slice of `store.ts`. (A and B must negotiate any shared `store.ts` edits.)
- **Owner C (docs/proposals):** items 4 + 5's options doc in `notes/` — no product-code writes.
- **Website (item 6):** separate branch/PR, explicitly Fable-driven per the backlog note.
- **Human-gated (items 7, 8):** tag deletion executed only on explicit confirmation; code review run as the integration gate by whoever integrates.

## Observable acceptance criteria

1. Screenshot shows avatar at the extreme bottom-left, settings adjacent, remaining buttons following; all icons share one vertical center-line (no baseline stagger).
2. Mesh member cards render Claude/Codex labels with zero text overlap at default and narrow panel widths; `group:probe` passes.
3. Mesh member model picker lists Claude effort variants; selecting one demonstrably spawns a session at that effort (verified in the agent's own session info), and the choice survives app restart.
4. A `notes/` doc with a measured per-process RSS baseline and ≥3 costed options, posted for sign-off — no runtime changes.
5. A design proposal where "X" = close (re-openable from `closedStack`) and "Delete" is an explicit context-menu action; the group-thread hard-delete inconsistency is addressed.
6. Site images at native aspect ratio (no squeeze/stretch), section order leads with agents/terminals/orchestration/group agents; files demoted.
7. `git ls-remote --tags origin` no longer lists `wip-safety-snapshot` (contributor-cache refresh acknowledged as delayed).
8. `/code-review` at high effort over the branch diff with zero unresolved confirmed findings, plus `npm run smoke` green, before any push to main.

## Codex scout report

The public assets confirm the website problem is structural: the hero screenshot is dominated by the file editor and even shows a “Mock agent (test wiring)” empty state, while the page title, metadata, hero, first feature section, README tagline, and footer all lead with “Files first.” The site refresh therefore needs a new capture scenario and information hierarchy, not just new copy. I’ll finish by checking the current type/memory baselines without modifying the checkout.

The safe baselines are clean: TypeScript passes, all 12 memory-lifecycle tests pass, and the detached-terminal probe shows 16 hidden terminals retaining 0 output bytes in RAM while moving 64 MiB to bounded disk storage. The full Electron process-tree comparison could not launch in this restricted scout shell (the second attempt exited before reporting metrics), so I’ll treat that as a missing measurement—not a product failure—and make a real multi-session benchmark part of acceptance.

Scout conclusion: this is six new backlog items best handled as four isolated implementation lanes plus a final review/integration pass. I made no edits or commits.

## Model of the problem

The current [backlog](/Users/michaelofengenden/Documents/Kaisola/docs/BACKLOG.md:1) has two formatting issues:

- The 13 previously completed items lost their `[x]` markers and now look unfinished.
- The six new items use escaped `\-` paragraphs rather than checklist entries and include trailing whitespace.

The substantive work is:

1. Reorder the bottom-left utility row.
2. Add Claude effort selection to each Mesh participant.
3. Reduce memory use without weakening running agents or terminals.
4. Distinguish reversible session closing from permanent deletion.
5. Reposition the website and README around agents, terminals, and orchestration.
6. Perform a focused code review before integration.

Existing code provides useful foundations, but also exposes several gaps:

- [ShellSidebarFooter.tsx](/Users/michaelofengenden/Documents/Kaisola/src/components/shell/ShellSidebarFooter.tsx:18) currently places the avatar/settings after a flex spacer instead of at the far left.
- [GroupAssistant.tsx](/Users/michaelofengenden/Documents/Kaisola/src/components/GroupAssistant.tsx:370) exposes live participant models but not effort. Its direct model change can also race the 30-second ACP idle park.
- The tab × is already an undoable close, and recently closed sessions can reopen. However, terminal records disappear after the 60-second live-process grace, Mesh closes are final, and the context menu has no general permanent-delete action.
- A closed agent record can theoretically retain up to 6 MiB of recent runtime data; with a 20-entry closed stack, that is roughly 120 MiB before object overhead.
- Hidden terminal output is already well optimized. The current synthetic probe moved 64 MiB of output from 16 terminals to disk while retaining zero output bytes in RAM.
- The public website is structurally files-first. Its hero screenshot visibly contains “Mock agent (test wiring),” so replacing copy alone would not solve the positioning problem.

## Proposed approach

1. Normalize the backlog during integration.

   Restore the original 13 `[x]` entries, convert the six additions to `- [ ]`, and only check them after their acceptance tests pass.

2. Implement the footer as one left-packed row.

   Use this order: profile photo → settings → file-tree recovery when needed → search → usage → notifications. Remove the spacer that splits the row and extend the existing smoke assertion to verify DOM order, size, alignment, and narrow-sidebar behavior.

3. Make Mesh effort capability-driven.

   Reuse the child thread’s existing `claudeEffort` state rather than creating a second group-owned source of truth. Extract or share the model/effort normalization currently embedded in `Assistant.tsx`, then let the hidden participant Assistant safely apply the request:

   - Use live advertised effort options when available.
   - Reject unsupported model/effort combinations.
   - Prevent changes during a running turn.
   - For legacy Claude adapters, reconnect the resumable session with the selected effort.
   - Ensure model/effort changes reconnect first if the setup connection has already parked.

4. Build an explicit close/restore/delete lifecycle.

   - × and middle-click remain reversible “Close session.”
   - Add “Close session” and destructive “Delete session…” to the two-finger/right-click menu.
   - Keep closed-session metadata durably and byte-bounded after the process grace expires.
   - Reopening should honestly distinguish:
     - `Continued`: same PTY remained alive.
     - `Resumed`: provider session was restored.
     - `Restarted`: a fresh shell was opened at the saved folder.
   - Permanent deletion purges Kaisola session metadata, drafts, runtimes, archives, adapters, and PTYs—but never repository files.
   - Worktree removal remains its separate explicit destructive action.

5. Treat memory work as measurement-led lifecycle work.

| Option | Likely value | Risk | Recommendation |
| --- | --- | --- | --- |
| Disk-back closed agent runtimes | High with many closed sessions | Low–medium | Ship first |
| Evict completed/hidden Mesh worker runtime copies after durable snapshots | Moderate | Medium; preserve audit history | Ship with archive tests |
| Park resumable ACP adapters sooner than 30 seconds | High per idle adapter | Reconnect latency | Offer 10s/30s policy |
| Park known resumable Claude/Codex terminal CLIs | Very high | High; shell/TUI state loss | Opt-in only |
| Reduce terminal spool disk capacity | Negligible RAM benefit | Less history | Do not prioritize |

   Add a repeatable scenario benchmark covering empty app, one active terminal, eight hidden terminals, two idle agents, an idle two-participant Mesh, active streaming, and a minimized window. Report renderer, GPU, Electron main, broker, and each adapter/CLI separately.

6. Give the website/Fable lane a full isolated redesign.

   Rework [site/index.html](/Users/michaelofengenden/Documents/Kaisola/site/index.html:6), [README.md](/Users/michaelofengenden/Documents/Kaisola/README.md:5), and the screenshot harness around this order:

   - Agent and CLI sessions
   - Kaisola Mesh orchestration
   - Live model/effort/permission controls
   - Terminal continuity and local execution
   - Files and documents as supporting workspace context

   The capture harness should produce intentional Codex, Claude, terminal, and Mesh scenes—never public test wiring. Preserve screenshot aspect ratios with matching intrinsic dimensions and `height: auto`/contained presentation.

## Likely ownership boundaries

- Shell owner: `ShellSidebarFooter.tsx`, footer CSS, layout probe.
- Mesh owner: `GroupAssistant.tsx`, shared Assistant control logic, `group-ui-probe.cjs`.
- Session/memory owner: `SessionTabs.tsx`, `store.ts`, assistant archives, terminal lifecycle, memory tests and probes.
- Website/Fable owner: `site/**`, `README.md`, `electron/shoot.cjs`; no product-state ownership.
- Integration owner: shared smoke assertions, backlog normalization, final diff review, commit and push.
- Independent reviewer: hardcoded assumptions, busy-session races, archive failure handling, process cleanup, and destructive-action boundaries.

The untracked `source_keystone_arch*.png` files appear to be icon-source variants and should remain outside this commit unless explicitly assigned to the website/icon work.

## Observable acceptance criteria

- Footer: avatar is the first visible control, settings second, all controls are 28px and share the same vertical center in either left-sidebar host.
- Mesh: every Claude participant can choose only advertised model/effort combinations; choices persist across reload and adapter parking; unsupported/busy changes fail visibly without losing the session.
- Sessions: close is reversible across app restart; delete requires confirmation and cannot delete workspace files; terminal reopen status accurately says continued, resumed, or restarted.
- Memory:
  - Hidden-terminal output RAM remains zero in disk-only mode.
  - Idle resumable ACP processes disappear within the configured deadline.
  - Twenty settled closed sessions retain at most a small metadata-only in-memory budget.
  - Delete leaves no owned ACP, PTY, broker record, spool, or archive behind.
  - Before/after totals use at least three median runs per scenario.
- Website: no mock/test wording, agent/CLI/Mesh content precedes files, screenshots retain their natural aspect ratio at desktop/tablet/mobile widths, and download links work.
- Review: `git diff --check` passes; no hardcoded unsupported provider choices are introduced.
- Verification: `npm run typecheck`, the memory lifecycle tests, `npm run group:probe`, `npm run layout:probe`, and the full `npm run smoke` pass.
- Delivery: only intended files are staged; the two user-owned PNGs are excluded unless approved; one reviewed commit is pushed. A push touching `site/**` publishes the live Pages site, so integration approval is also publication approval.

Current read-only baseline: TypeScript passes, all 12 memory-lifecycle tests pass, and the synthetic detached-terminal memory probe passes. The full Electron RSS comparison could not launch inside this restricted scout shell, so it remains required implementation evidence rather than a reported failure.
