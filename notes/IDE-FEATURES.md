# Kaisola — IDE Feature Backlog

What modern agentic IDEs (Cursor, Zed) and OSS tools (Cline, aider, Continue) do
that Kaisola could adopt — grounded in two adversarially-verified deep-research
passes (2026-06-11) and mapped to Kaisola's actual seams. Every item carries an
explicit **API-cost profile** because keeping runtime model/subscription spend
low is a hard constraint:

- 🟢 **Free** — pure local, no model calls ever.
- 🟡 **Cheap** — uses the existing default cheap reasoning path (gpt-4o-mini /
  local / deterministic judges); one call per action.
- 🔴 **Cost-multiplying** — fans out N model calls per action; gate behind an
  explicit opt-in + small N.

> Difficulty + every "maps to Kaisola" is our inference from the codebase; the
> sources confirm only that the feature exists in the named tool. Vendor metrics
> (e.g. Bugbot "~90s") are self-reported, not independently benchmarked.

---

## What's new in Cursor 3.x (asked 2026-06-11)

Cursor 3.0 shipped **2026-04-02** and the line is at **3.7** as of June 2026. The
whole 3.x bet is *managing parallel agents, not editing files*
([Meet the new Cursor](https://cursor.com/blog/cursor-3),
[3.0 notes](https://cursor.com/changelog/3-0),
[changelog](https://cursor.com/changelog)):

- **Agents Window** (`⌘⇧P → Agents Window`) — an agent-first surface you can run
  alongside or instead of the classic IDE.
- **Agent Tabs** — view multiple agent chats at once, side-by-side or in a grid.
- **`/worktree`** — a command that creates a separate git worktree so an agent's
  changes happen in isolation (the parallel-agent primitive).
- **Design Mode** — annotate/target UI elements directly in a browser to point an
  agent at exactly the thing you mean; later gained multi-select + **voice input**.
- **SDK (3.5+):** **custom tools**, **auto-review** (gate tool execution by rules),
  and **nested subagents** — agents spawn child agents to any depth, each with its
  own prompt/model.
- **Bugbot on Composer 2.5** — `/review` before push; ~90s, "22% cheaper", "10%
  more bugs" (vendor-reported).

Takeaway for Kaisola: this *validates* the dock/thread/agent-centric direction and
makes **parallel/background agents** the headline feature to pursue — but on
Kaisola's terms (the Proposal gate as the merge/selection point; see below).

---

## The big idea for parallel agents

Cursor isolates parallel agents with **git worktrees + best-of-N + pick-the-winner**.
Kaisola needs worktrees for only *one* of its two agent types:

- **Research/domain agents** (`literature`/`novelty`/`hypothesis`/…) don't touch
  files — they emit `Proposal[]` through the gate. So "best-of-N" is nearly free
  to wire: fan out N agents/models on the same stage task, collect N competing
  research-diffs, human picks in `ReviewFocus`. **Kaisola's Proposal gate + Review
  inbox already ARE the merge/selection surface Cursor built worktrees to get.**
- **Coding/experiment agents** (operate in `workspacePath`) *do* need worktree
  isolation — two ACP threads sharing one `cwd` collide. ACP `session/new` already
  takes a `cwd`; `acpHandler`'s connections Map can key per-thread/worktree.

`spawn_agent` (Zed's built-in subagent tool — "its own context window… parallel
investigations… where only the outcome matters",
[Zed tools](https://zed.dev/docs/ai/tools)) is your `supervisor` pattern made
agent-initiated.

---

## Tier 1 — Parallel & background agents (headline)

| Feature | Source | Maps to | Difficulty | Cost |
|---|---|---|---|---|
| **Best-of-N research Proposals** — same stage task across N agents/models, pick winner in a Compare surface | Cursor multi-model | `runStageAgents` fan-out → "Compare" mode in `ReviewFocus`; gate is the selector | Easy–Med | 🔴 (opt-in, small N) |
| **Worktree isolation for coding/experiment agents** | Cursor `/worktree`, [Claude Code worktrees](https://code.claude.com/docs/en/worktrees) | per-thread `cwd` in `acpHandler`; reuse live agent terminals | Hard | 🟡 (runtime = agent itself) |
| **Background/async agent queue + inbox** — fire-and-forget tasks land in an inbox | Cursor background/cloud agents | extend the **Review inbox** (`AgentSidebar`) into a task queue; `agentRunning` is the substrate | Med–Hard | 🟡 |
| **`spawn_agent` subagent tool** — agent-initiated parallel sub-investigations | Zed `spawn_agent`, [Cursor subagents](https://cursor.com/docs/subagents) | generalize `supervisor`/`agentsForStage` so an agent spawns a thread + collects its Proposal | Med | 🟡 |

## Tier 2 — Finish what's already half-built (highest ROI, mostly 🟢)

The research surfaced four patterns Kaisola already scaffolded — net-new work is UI/polish only:

- **Idea-tournament bracket UI** — generalizes Cursor's "N attempts, pick best".
  **`src/lib/tournament.ts` already does Elo pairwise** (deterministic judge =
  free); "Rank ideas" exists in `IdeasView`. Net-new = bracket visualization.
  **Easy · 🟢**
- **Claim/citation linter (inline squiggles)** — the Bugbot/diagnostics pattern on
  claims. **`verifyCitations()` (NLI entailment) + GROBID bbox pins already exist.**
  Net-new = render entailment failures as inline warnings in `ManuscriptView`/
  `ClaimGraphView`. **Easy–Med · 🟢** (deterministic judge default).
- **Research-context "repo map"** — aider's personalized-PageRank context
  compression ([repomap](https://aider.chat/docs/repomap.html)). **`src/lib/
  relevance.ts` already does PageRank over the claim graph + budgeted
  `buildAgentContext`.** Net-new = personalize to `@`-mentions + stage. **Med · 🟢**
  (it *reduces* token cost by sending less).
- **Plan / read-only mode** — Cline's read-only thinking phase
  ([Plan/Act](https://docs.cline.bot/core-workflows/plan-and-act)). **`autonomy:
  'observe'` already gates mutation off.** Net-new = a discuss-don't-propose
  Assistant mode. **Easy · 🟢**

## Tier 3 — New surfaces

- **✅ Checkpoint / undo timeline** — *shipped this session (see below)*.
  Pattern: Cline's shadow-git, one snapshot per mutation, multi-mode restore
  ([Cline checkpoints](https://docs.cline.bot/core-workflows/checkpoints)). **🟢**
- **`@`-mention context pills + inline ⌘K** — Zed builds both as one shared
  context mechanism ([Inline Assistant](https://zed.dev/docs/ai/inline-assistant)).
  Extend the namespace to **`@paper`/`@claim`/`@citation`** (a research-native
  superset); `@`-pills hook into `buildContext()`. ⌘K needs an editor surface.
  **Med (pills) / Med–Hard (⌘K) · 🟡** (pills 🟢 — they only shape the prompt).
- **Agent profiles + two-layer tool gating** — Zed's availability-gate (profile)
  vs approval-gate (permission) ([agent profiles](https://zed.dev/docs/ai/agent-profiles)).
  Generalize your per-agent models + compute gate into named profiles; keep the
  Proposal gate as the approval layer. **Med · 🟢**
- **MCP-server management UI + in-app agent registry** — you install agents via
  `npx` already. **Easy (registry) / Med–Hard (MCP UI) · 🟢** (config only).
- **Pre-Proposal `/review` agent** — Cursor Bugbot as a research-diff linter that
  runs `reviewer` + `verifyCitations` before a Proposal finalizes. **Easy–Med · 🟡**.

## Tier 4 — Creative differentiators (extrapolation — not evidenced as shipping)

The research flags these as reasoned compositions of verified blocks, not products:

- **Ambient arXiv/OpenAlex watcher** — a true background agent polling for papers
  relevant to the live claim graph, dropping them into the inbox. **Med–Hard · 🟡**
  (cron-paced; rate-limit polling).
- **Trajectory branching & merge** — worktrees+checkpoints applied to the research
  trajectory itself: branch a hypothesis, explore both, merge. **Med–Hard · 🟢**.
- **Simulated-reviewer live panel** — `reviewer` agent as always-on manuscript
  critique. **Med · 🔴** (always-on = recurring calls; debounce hard).
- **Advisor "follow mode" / co-review** (CRDT multiplayer,
  [Zed channels](https://zed.dev/blog/channels)) — verified but **Hard**, unclear
  fit for a single-user desktop app. Defer. **🟢**.

---

## Shipped this session — Checkpoint / undo timeline (🟢 zero API cost)

A Cline-style time-travel layer over the Proposal gate, implemented entirely local:

- **`store.ts`** — `Checkpoint {id, at, label, kind, snapshot: Project}` +
  `checkpoints: Checkpoint[]` (session-scoped, **not persisted** → zero SQLite
  bloat, capped at 25 via `pushCheckpoint`). A snapshot is captured *before* each
  trajectory-mutating action: `approveProposal`, `loadDemo`, `clearProject`.
- **`restoreCheckpoint(id)`** reverts `project` to a snapshot and drops that
  checkpoint + everything newer (keeps the timeline consistent); **`undoLast()`**
  reverts the most recent. Each writes a `human` activity receipt.
- **Surfaces:** a **History** section in `AgentSidebar` (click a row to restore;
  reuses existing `review-row` styles — no new CSS) and **Undo last change** /
  **Restore: …** entries in the command palette (`History` group).
- **Verified:** `tsc` + `vite build` clean; new smoke check
  `CHECKPOINT={madeCheckpoint, grew, reverted, consumed}` all true; full
  `npm run smoke` PASS (29 checks, no regressions).

Why this first: highest-value gap that is *pure local* (respects the cost
constraint), exploits the single-mutation-path design, and composes under every
Tier-1/4 feature (branching, best-of-N, background agents all want restore).

Possible follow-ups: persist checkpoints (durable undo across launches — costs
SQLite weight); add the three-mode restore (files / thread / both); a global
`⌘Z` (careful not to hijack input-field undo); checkpoint on `verifyCitations`/
`buildCitationGraph`/`runExperiment` too.

---

## Recommended cheap-first build order

1. **✅ Checkpoint timeline** — done. 🟢
2. **Tournament bracket + claim linter** — engines exist (`tournament.ts`,
   `verify.ts`); UI only; deterministic judges = 🟢.
3. **`@`-mention pills** (`@paper`/`@claim`) — 🟢, and improves later best-of-N.
4. **Background-agent inbox** + **worktree isolation** — the full parallel story;
   gate best-of-N behind an explicit opt-in with small N to cap 🔴 cost.
