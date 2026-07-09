<title>Traycer → Kaisola: Deep Dive & Adoption Plan</title>

# Traycer → Kaisola: deep dive & adoption plan

*2026-07-08 · synthesized from a 10-agent research workflow (Opus 4.8, xhigh): 5 agents on Traycer's site/docs/GitHub/UX/handoff-protocol, 3 on the Kaisola codebase (read-only), 2 on the agent-communication ecosystem and desktop-app smoothness. Raw reports cited at the end.*

---

## TL;DR

1. **Traycer pivoted three weeks ago.** The VS Code "spec-first" extension is legacy. Traycer is now an **open-source (Apache-2.0) Electron desktop app** — "the Nerve Center for Agentic Coding" — whose closed-source **Host** daemon runs coding agents (Claude Code, Codex, OpenCode, Cursor + 10 more) in PTYs it owns, with a **CLI message bus** (`traycer agent send --to <id>`) so any agent can talk to any other. Its clients/CLI/wire-protocol source is readable at `github.com/traycerai/traycer`.
2. **Kaisola already has most of the hard parts** — and some of them are literally built but unwired: the proposal gate, per-window ACP multi-agent sessions, a complete worktree→proposal→merge pipeline with **zero callers**, a `Workflow` plan object with no agent author, and `planning`/`coding` agent slots that exist in metadata but aren't registered.
3. **The winning architecture is not Traycer's mesh.** For a human-gated research IDE: **supervisor-as-ACP-hub + a SQLite task ledger (single writer) + one Kaisola MCP server attached to every agent at `session/new`**. Traycer's any-agent-to-any-agent walkie-talkie moves transitions *out of* the human's line of sight — the opposite of Kaisola's thesis.
4. **The elegance problem is dead weight, not messy styling.** Kaisola's token/component discipline is genuinely good; ~1,900 LOC of unreachable views and a phantom 10-stage IA are what's costing clarity.
5. **The feel gap was the streaming path** — the transcript re-rendered and re-parsed its full markdown on every token. Fixed today (batched flushes + memoized turn rows), typecheck + full smoke suite pass.

---

## 1. What Traycer actually is (mid-2026)

Two products under one name:

| | Legacy extension (2024–25) | **Desktop "Nerve Center" (June 2026)** |
|---|---|---|
| Form | VS Code/Cursor side panel | Electron app + closed **Host** daemon + `@traycerai/cli` |
| Handoff | Clipboard / markdown / env-var (`TRAYCER_PROMPT`) into a spawned CLI | Agents launched **inside Host-owned PTYs**, pre-injected with task context, artifact instructions, and A2A instructions |
| Plans | Plan/Phases/Epic modes, file-level plans | **Artifacts**: Spec / Ticket / Story / Review — markdown on disk, Yjs CRDT-synced |
| Agent comms | none | `traycer agent create/send/inbox/transcript`, `TRAYCER_AGENT_ID`/`TRAYCER_EPIC_ID` env; **mesh topology** ("any agent can talk to any other") |
| Completion detection | drives the loop itself | **injects provider hooks** — e.g. Claude Code's Stop hook calls `traycer agent turn-ended-from-hook` |
| Open source | closed | **clients + CLI + protocol Apache-2.0**; Host + cloud closed |

Other load-bearing facts:

- **Verification is the moat.** After an agent implements, Traycer diffs the result *against the plan* and emits severity-tagged comments (**Critical / Major / Minor / Outdated**) with per-comment / batch / fix-all remediation routed back to an agent, plus **Re-verify** (only prior issues) vs **Fresh** (full re-analysis). Multi-model: Sonnet plans, GPT-5.1 verifies.
- **Permission ladder**: Supervised (default) → Auto-accept edits → Full access; YOLO/Smart-YOLO at the far end, which analyzes ticket dependencies and **runs independent executions in parallel in git worktrees**.
- **MCP: consume-only, remote-only.** Traycer exposes **no MCP server** — its A2A bus is proprietary Host RPC.
- **Issue-tracker signal** (their users, verbatim themes): the #1 requested-and-shipped feature was **per-agent token/cost/context-left telemetry**; worktree/multi-folder UX is their current rough edge; the legacy extension died of **CPU blowups during plan generation** (a 4×-recurring regression); a 2★ review: routing *small* edits through plan ceremony "burns artifacts and tokens like crazy."

## 2. What Kaisola already has (the overlap audit)

The architecture agent's one-paragraph spine: every agent is a pure function `Project → Proposal[]`; the **only mutation path is human approval** (`approveProposal → applyProposal`, `store.ts:2699/:1025`); reasoning routes through one `emit_proposal` contract with machine-stamped provenance; a deliberately sequential queue drains background runs.

Built and live: ACP client to 7+ agents with per-window sessions (`acpHandler.cjs:75`), inline permission cards that fail closed, Claude-hooks activity tap (`claudeHooksHandler.cjs` — same trick Traycer uses), best-of-N with Elo tournament + `pickWinner`/`synthesizeProposals`, campaign budgets and autonomy ladder (`observe|propose|execute|sprint`).

**Built but orphaned (the free wins):**

- `createWorktreeProposal`/`mergeWorktreeProposal` + full `worktreeHandler.cjs` — **no caller except smoke.cjs**. This *is* Traycer's isolation model, already merge-safe.
- `Workflow`/`WorkflowStep` + `runWorkflow` (`store.ts:319/:3184`) — a ready-made plan object, currently user-authored only.
- `planning` and `coding` agents exist in `AGENT_META` but are excluded from `SIDEBAR_AGENT_IDS` (`registry.ts:137`).
- `ExperimentAttempt.parentAttemptId` already models a parallel attempt DAG.
- Proposal inline editing is stubbed ("Phase 2", `ProposalCard.tsx:72`).

**The genuine gap:** `AgentContext` has no field for another agent's output (`agents/types.ts:14`) — agents can only communicate indirectly through approved-proposal → project-state. There is no task ledger, no plan-authoring agent, no cross-agent messaging.

## 3. Features to bring over (ranked)

1. **Wire the coding→worktree→proposal path** (S–M effort, mostly built). Register the `coding` agent; each coding task gets its own worktree; the diff comes back as a file-patch Proposal through the existing gate; merge on approve. This unlocks parallel file-mutating agents with zero new safety machinery.
2. **Plan-before-execute, Traycer-style but gated** (M). Register the `planning` agent and have it **emit a `Workflow` as a Proposal**: the plan itself goes through the ProposalCard gate (Traycer has no hard plan-approval state — Kaisola's gate is *stronger*), then `runWorkflow` executes step by step. Render it as Traycer does: a numbered vertical stepper with per-step approval, drag-to-reorder, insert-between.
3. **Verification loop** (M). After a coding/experiment proposal executes, run a verifier agent that diffs outcome-vs-plan and emits severity-tagged comments (Critical/Major/Minor/Outdated) with "fix in agent" routing. Kaisola already has `verify.ts` (citation entailment) and `ReviewFocus` — this generalizes them. Adopt the **Re-verify vs Fresh** distinction; it's what keeps the loop cheap.
4. **Per-agent token/cost/context-left telemetry** (S–M). The single loudest user demand in Traycer's tracker; surfaces in session cards and the composer. ACP `session/update` frames and Claude hooks both carry usage data today.
5. **Explicit empty/loading/error states + skeletons** (S). Traycer's Git-Diff panel documents *nine* edge states; that's what "finished" feels like. Kaisola has `.skeleton` CSS, barely adopted — wire it into file-tree hydrate and editor mount; design "no sources / retrieving / rate-limited / conflicting evidence" states for research panes.
6. **Durable artifacts as markdown on disk** (M, later). Plans/reports/reviews as versioned markdown outside the chat scrollback (Traycer's Spec/Ticket/Story/Review). Kaisola's proposals are close; the delta is *persistence as user-ownable files*.
7. **Anchored, resolvable comments on artifacts** (L, later). Select text in a proposal/manuscript → comment → resolve. Natural fit for reviewer-gated manuscripts.

**What NOT to take:** the credit economy and context-overflow 2× billing (top complaint source); **mesh A2A** (see §4); remote-only MCP (Kaisola should do the opposite and *expose* a local server); plan ceremony for small edits — keep a fast lane (their 2★ lesson); Claude-only A2A asymmetry (design vendor-neutral from day one); and their legacy CPU-blowup pattern — plan generation must never run unbounded on the UI thread.

## 4. Agent↔agent + Claude/MCP: the architecture

Consensus of both ecosystem agents, grounded in the spec state as of today (MCP 2026-07-28 is in RC; ACP registry launched Jan 2026; Claude agent-teams still experimental and Claude-only):

**Supervisor-as-ACP-hub + SQLite task ledger + one Kaisola MCP server.**

- **One ACP session per worker agent** (not opaque internal fan-out) so every worker is independently visible, cancellable, mode-switchable, and gatable. Workers never message each other directly — the supervisor routes, the human sees every transition. This is where we deliberately diverge from Traycer's walkie-talkie mesh: their own docs admit the hierarchy tree is display-only.
- **Task ledger in better-sqlite3, Kaisola as the only writer**: `tasks(id, title, status, owner_agent, depends_on[], gate_state, result_ref)` with `gate_state ∈ none|pending_human|approved|rejected`. The ledger doubles as the audit surface; pipelines are `depends_on` edges. Agents "message" each other by posting tasks/results through IDE-validated tools.
- **One MCP server exposes IDE state to every agent uniformly** — ACP forwards `mcpServers` at `session/new`, so Claude Code, Codex, Gemini, etc. all get the same tools: `corpus.search`, `hypothesis.list`, `claim.assert`, `task.claim/post_result`, `gate.request_review`. Run it in Electron main over loopback Streamable HTTP + bearer token + DNS-rebind guard. Mark every mutating tool `requiresUserInteraction` so it can never be auto-approved.
- **Two lanes for Claude specifically**: keep ACP for the Claude Code *product* (user's subscription, current path), and optionally embed the **Claude Agent SDK** (`query()` API — the V2 session API was removed in 0.3.142) in main for Kaisola's *own* supervisor agents: `canUseTool` + a matcher-less `PreToolUse` hook funnel into the same review queue; `forkSession` gives cheap hypothesis-branch exploration; structured `outputFormat` writes typed claims straight into SQLite.
- **Three gating layers**: ACP `session/request_permission` (never auto-`allow_always`), ledger `gate_state`, and deterministic hooks (exit-2 blocks). All three surfaces normalize into **one review queue** — SDK, ACP, and MCP-elicitation requests in a single list.
- **Skip Google A2A** (cross-org remote agents — wrong layer for local subprocesses) and **don't build on Claude agent teams** as the bus (experimental, file-based, one-team-per-session, Claude-only, and its peer messaging bypasses the human gate).
- **Anti-context-poisoning discipline** (research: steering accuracy collapses 60%→21% from N=3→N=10 agents on shared context): share artifacts **by reference** (claim IDs, corpus URIs), never transcripts; per-stage evaluator agents before the human sees anything.

Build order: (1) ledger + review-queue unification on the existing ACP lane → (2) read-only Kaisola MCP server → (3) write tools behind `requiresUserInteraction` → (4) planning agent + workflow execution → (5) parallel coding agents in worktrees.

## 5. Look & feel

**Kaisola audit verdict:** the token layer and primitives are already clean (100% of 256 icon usages route through `Icon.tsx`; buttons are one system; spacing/radii/motion scales are coherent). The problems:

- **11 of 12 views are unreachable** — `App.tsx:483` force-sets `stage='files'`; ~1,891 LOC of dormant views carry ~all of the hardcoded-hex debt and two duplicate CSS systems. *Decision needed: delete the dormant trajectory or re-commit to it — keeping it half-wired is the real tax.*
- Small hygiene: 15 raw z-index literals bypass the `--z-*` scale; two competing empty-state systems; `--fs-24` unused and 8 font sizes packed into 9–16px; comments still say "Pasola"; a few live-shell hex literals that equal existing tokens.
- Glass is a signature feature, not debt — treat as *contain*.

**Traycer patterns worth stealing** (from the UX teardown): radical color restraint — near-mono canvas, one accent, color only where it means something (severity, status, agent identity); plans as numbered steppers, not prose; status pills + per-agent brand marks everywhere so you always know *which* agent owns *what*; an agent-lineage tree in the session list; composer settings that apply to the *next* turn and never rewrite in-flight work (Kaisola already does this — keep it sacred); every panel with named empty/loading/error states. Their criticized weaknesses — session loss on reload, verify-fix treadmill, breadcrumb confusion — are the traps to design against.

## 6. Smoothness

Already best-in-class in Kaisola (verified in code): painted constant veils instead of per-frame 1600px backdrop blur; frost grain rasterized once; opaque xterm surfaces with WebGL attach-on-show and buffer-replay-on-hide; throttled persistence; fine-grained zustand selectors; transform/opacity-only animations.

The punch list (ranked feel-per-effort):

1. ~~**Token-batch the agent stream** — `makeOnUpdate` called `updateRuntime` synchronously per chunk; the memo'd Assistant re-rendered per token.~~ **Done today.**
2. ~~**Full-markdown re-parse per token** — remark AST rebuilt from scratch on each chunk.~~ **Done today** (batching caps parses at ~12Hz).
3. ~~**Whole-transcript reconciliation per token** — `arun.turns.map` re-rendered every turn.~~ **Done today** (memoized `TurnRow`).
4. Skeletons on file-tree hydrate + editor mount (S).
5. `ClaimGraphView`: add `onlyRenderVisibleElements`, memoize per-node lint (S — only matters if the view returns).
6. Session-card live 200px blur in glass mode — the natural "cheap glass" candidate, needs design sign-off (ties to the existing deferred plan).
7. Virtualize long lists if transcripts/trees grow (no virtualization lib in the project today).

## 7. Decisions needed

1. **Dormant views**: delete the 11 unreachable views + phantom stage IA (recoverable from git), or re-commit and wire a real switcher? Deleting is the single biggest simplification available.
2. **Green-light the agent-comm build** (§4 build order)? Phase 1–2 are additive and low-risk.
3. **Plan-first UX**: agent-authored `Workflow` proposals as the default entry for multi-step work, with a fast lane for small asks?
4. **Cheap glass** for session cards (existing deferred decision, unchanged).

---

*Raw reports (10 files): `/private/tmp/claude-501/-Users-michaelofengenden-Documents-Kaisola/2123390d-7739-4762-adaa-1ec8b6fdc3ef/scratchpad/reports/` — traycer-website, traycer-docs, traycer-github, traycer-ux, traycer-handoff, agent-comm-standards, kaisola-architecture, kaisola-ui-audit, claude-mcp-integration, smoothness-perf. Traycer's client/CLI/protocol source clone: `…/scratchpad/traycer-clone`. Key confidence caveats: Traycer's Host internals are closed (mechanism detail comes from their docs/CLI); the desktop generation is ~2 weeks old and moving fast (5 patch releases in the first two weeks); MCP 2026-07-28 spec is still RC.*
