# Kaisola — Upgrade Plan (research-grounded)

> Written 2026-06-11. This document records the "level up Kaisola" plan, its
> research grounding, and — crucially — an honest split between **what is
> implemented and verified** versus **what is wired as a seam** that activates
> when an API key / network / external service is present.
>
> Guiding principle (unchanged from [ROADMAP.md](./ROADMAP.md)): *make the
> trajectory real before the agents, and the agents real before execution.*
> Two product constraints from the author override everything: **minimalism**
> (the surface stays bare; nothing new adds visible clutter) and
> **configurability** (knobs live in Settings / the command palette, never in
> your face).

## The headline finding

The hardest architectural bets are already made correctly:

- **ACP** as the agent transport (`electron/ipc/acp.cjs`) — already advertises
  `terminal: true` and `fs` client capabilities in `initialize`, so external
  agents (Codex / Gemini / Claude Code) can already drive the node-pty dock.
- **A provenance / trust moat** (`src/domain/types.ts` `Provenanced`,
  `src/domain/trust.ts`) — every scientific entity justifies its existence.
- **A human-gated Proposal as the only mutation path** (`approveProposal()` in
  `src/store/store.ts`) — agents never touch state directly.

So "leveling up" is mostly **wiring real reasoning into seams that already
exist**, plus borrowing a few specific orchestration patterns. Not a redesign.

The single biggest gap, discovered while reading the code: the domain agents in
`src/agents/registry.ts` were **never invoked anywhere** — dead code returning
canned `Proposal[]`. Closing that — giving agents a real invocation path and a
real reasoning seam — is the highest-leverage move and is the centerpiece of
this upgrade.

---

## What shipped in this pass (implemented + verified offline)

Everything below is **fully functional with deterministic logic and verified by
the headless smoke test** (`electron/smoke.cjs`). Where a model would make a
result better, the model path is wired behind the same function and activates
when an Anthropic key is present in the OS keychain — but the **offline
deterministic path is the default and is what's verified**, so the app is never
dependent on a key or the network to work.

1. **Structured-output model seam.** `electron/ipc/modelHandler.cjs` now accepts
   Anthropic **tool-use** (`tools`, `tool_choice`) and returns the tool-call
   inputs (`toolCalls`). This is the channel for `emit_proposal` — a tool whose
   JSON schema *is* the `Proposal` type. The renderer bridge
   (`src/lib/bridge.ts`) and preload expose it. Graceful no-key passthrough kept.

2. **A real agent runner + invocation path.** `src/agents/run.ts` runs an agent
   by calling the model with an `emit_proposal` tool, deserializing the tool-call
   straight into `Proposal[]`. If there's no key / no desktop / a failure, it
   falls back to the agent's deterministic generator so the flow never
   dead-ends. `store.runAgent()` is the single action that invokes an agent and
   appends the resulting proposals + an activity entry — `approveProposal()`
   stays the only mutation path. Agents are now invokable from the command
   palette, the Ideas view header, and the sidebar agent rows.

3. **Relevance-ranked context** (`src/lib/relevance.ts`). PageRank over the
   claim graph + a token-budgeted selector that feeds agents only the most
   relevant slice of claims/papers (the Aider repo-map idea), instead of dumping
   the whole project. Deterministic, invisible, improves grounding and cost.

4. **Idea tournament ranking** (`src/lib/tournament.ts`). Pairwise Elo over
   hypotheses with a pluggable comparator (deterministic composite of
   novelty / feasibility / evidence / trust offline; a model judge when a key is
   present). Surfaced as a subtle rank in the Ideas view behind a "Rank ideas"
   action — replaces a single flat score with a defensible ordering.

5. **Citation verification made real** (`src/lib/verify.ts`). The
   decompose → retrieve → quote-match → entailment pipeline with a pluggable
   judge: deterministic offline (does the quote actually appear in the source,
   and does it lexically support the claim?) upgradable to NLI-style model
   entailment. Flips `CitationProvenance.verified`, which flows straight into
   `computeTrust` — so a verified citation legitimately becomes `high` trust.

6. **Per-task model configuration** (`Settings`). Each agent role can carry its
   own model (cheap for citation/literature, strong for hypothesis/analysis/
   writing — the AI-Scientist-v2 pattern). Persisted, collapsible, optional.

7. **A thin supervisor** (`src/agents/supervisor.ts`). Sequences the right
   agents per stage (e.g. *ideas*: hypothesis → novelty → tournament) behind one
   "Run stage agents" action — the co-scientist supervisor pattern, scoped to
   the stage you're on.

---

## Shipped in the second pass (the four deferred items)

All four are now implemented, integrated, and headlessly verified through their
deterministic/graceful paths. The live paths activate when you supply the
endpoint/Docker/network — turning them on never breaks the offline default.

- **SQLite persistence** — `electron/ipc/dbHandler.cjs` opens
  `userData/kaisola.db` via **`better-sqlite3`** (rebuilt for Electron in
  `npm run rebuild`, now `-w node-pty -w better-sqlite3`), with a **JSON-file
  fallback** if the native module fails to load (so a bad rebuild degrades, not
  bricks). The zustand `persist` storage swapped from `localStorage` to
  `bridge.db`, with a **synchronous** `db:get-sync` read so rehydration has no
  flash, and a one-time fall-through to any existing `localStorage` blob. Web
  stays on `localStorage`. Smoke: `PERSIST backend:sqlite`, `DB roundTrip`.
- **GROBID PDF → coordinate-level provenance** — `electron/ipc/grobidHandler.cjs`
  (main: downloads the PDF, POSTs to your GROBID REST endpoint with
  `teiCoordinates=s`) + `src/lib/grobid.ts` (pure TEI parser, verified). Set the
  endpoint in **Settings → Literature sources**, run **⌘K → Ingest PDFs**: each
  paper gets `grobidText` (full text → richer citation verification) and every
  citation whose quote is found is pinned to a **PDF rectangle**
  (`CitationProvenance.bbox`), shown as "PDF p.N · pinned rectangle" in the
  provenance popover. Run GROBID with `docker run --rm -p 8070:8070
  grobid/grobid:0.8.1`.
- **OpenAlex citation graph** — `src/lib/openalex.ts` (DOI/arXiv lookup +
  `referenced_works`) + `store.buildCitationGraph()` (**⌘K → Build citation
  graph**) populates `Paper.references` (the in-corpus citation graph) and
  `Paper.openAlexId`; `relevance.rankPapers` now blends in-corpus centrality.
  Set an email in Settings for OpenAlex's free polite pool. ⚠️ confirm OpenAlex's
  current key/credit terms before heavy use.
- **Experiment sandbox (Docker / E2B)** — `electron/ipc/sandboxHandler.cjs` runs
  experiment code in an **isolated runner distinct from the dock pty terminals**:
  `mock` (default dry-run, always works), `docker` (`docker run --rm`), or `e2b`
  (drop-in when `@e2b/code-interpreter` + key are present). `store.runExperiment`
  is **gated** — it needs Execute/Sprint autonomy AND `computeApproved` — and
  streams a live notebook into a new `Run`. Wired into the Experiments view
  (Approve compute → Run) and Settings → Execution. Smoke: gate blocks, then a
  mock run produces a `done` Run with a notebook.

## Agent reasoning is cheap-by-default, never the expensive API

Domain-agent reasoning runs through a **configurable provider** (Settings → Agent
reasoning):

- **`codex`** — `codex exec` on your **ChatGPT/Codex subscription** (no per-token
  cost). Uses the cached "Sign in with ChatGPT" login; read-only sandbox so it
  never edits files. `electron/ipc/codexHandler.cjs`.
- **`openai`** (default) — the **OpenAI API** with a cheap mini model
  (`gpt-4o-mini`; also `gpt-4.1-mini`/`-nano`) via the **official `openai` SDK**
  with **strict `response_format: json_schema`** — the model is *guaranteed* to
  return schema-perfect `emit_proposal` JSON (no tool-calling guesswork). Key
  encrypted in the OS keychain (env `OPENAI_API_KEY` honored); never reaches the
  renderer.
- **`local`** — a free local OpenAI-compatible model: Ollama (`ollama serve`),
  LM Studio, llama.cpp (tool-calling + JSON-content fallback). Nothing leaves the box.
- **`agent`** — route through a connected ACP terminal agent (Codex/Gemini/Claude
  Code), reusing your CLI subscription. Best-effort structured output.
- **`anthropic`** — the paid Claude API, opt-in only.

> **Can the OpenAI SDK run on a ChatGPT/Codex subscription?** No — the SDK is
> API-key (or cloud workload-identity) only; a ChatGPT subscription is **not** API
> access. The *only* sanctioned way to use the subscription programmatically is
> Codex's own tooling (`codex exec`) — which is exactly the `codex` provider.
> (Pointing the SDK at the ChatGPT backend with subscription tokens is an
> unofficial, ToS-risky hack and is not done here.)

The deterministic offline generators remain the fallback, so the loop never
requires *any* model. The tournament + citation-verification judges are
deterministic (free) by default too.

## What remains a seam (genuinely not done yet)

- **Live model quality.** Exercising a real local/hosted model's output quality
  isn't something this headless environment can do; the wiring + graceful
  fallbacks are verified.
- **PaperQA2 RAG-over-papers** (Python, cross-process) — best surfaced via an MCP
  server (below).
- **Central MCP server forwarding.** ACP `session/new` takes `mcpServers`
  (currently `[]` in `acp.cjs`). Host one paper-search MCP server and forward it
  to every connected agent. Seam identified; server is a follow-up.
- **CRDT collaboration** (Yjs/Automerge) — only when real-time multi-user editing
  becomes a feature. SQLite is the right substrate until then.

---

## Orchestration patterns borrowed (sources)

| Pattern | Source (verified) | Where it lands |
|---|---|---|
| Supervisor over role-specialized agents, sequenced per stage | Google AI co-scientist | `src/agents/supervisor.ts` |
| Spend compute on **verifying** hypotheses, not just generating | co-scientist (design inspiration, single-vendor) | the provenance moat → `verify.ts` |
| Idea **tournament** (pairwise/Elo), not a flat score | co-scientist | `src/lib/tournament.ts`, Ideas view |
| Per-stage model assignment (cheap vs strong) | AI Scientist-v2 | per-task models in Settings |
| Tree-search + bounded **debug budget** (no infinite retries) | AI Scientist-v2 | experiments/runs (follow-up) |
| Citation-first generation (research → outline → write w/ cites) | Stanford STORM | manuscript/questions (follow-up) |
| Token-budgeted relevance ranking (repo-map) | Aider | `src/lib/relevance.ts` |
| Plan↔Act separation, context carried Plan→Act | Cline | the Proposal gate (validated) |

**Anti-pattern explicitly avoided:** AI-Scientist-v2's *fully autonomous, no
in-execution human review*. That's the opposite of the moat. We borrow its
tree-search and Docker boundary, **not** its autonomy. The Proposal gate stays.

**Claims that failed adversarial verification (do not rely on):** co-scientist's
"majority of compute on verification" is a single vendor blog (design
inspiration, not a guarantee); the claim that copilot/HITL mode measurably
raises paper scores was refuted — adopt the HITL *pattern*, ignore the figure.
ACP does **not** provide diff/edit-review UX — the research-diff surface
(`ResearchDiff.tsx` / `ProposalCard.tsx`) is ours to own; don't wait for the
protocol.

---

## Suggested continued sequencing (what's actually left)

GROBID, OpenAlex, SQLite and the Docker/E2B sandbox all shipped (see above).
What remains:

1. **Bring your key** → the model paths light up (emit_proposal, the model
   tournament judge, NLI entailment) — no code changes needed.
2. **NLI citation verifier** upgrade (VeriCite-style decompose → retrieve →
   entailment) replacing the offline lexical judge — swap `verify.ts`'s pluggable
   judge for a model call.
3. **Bounded debug budget** on sandbox failures (AI-Scientist-v2's tree-search):
   on a non-zero exit, let the agent propose a fix up to `max_debug_depth` times.
4. **Central MCP paper-search server** forwarded over ACP (`session/new`
   `mcpServers`) to every connected agent.
5. **PDF.js highlight viewer** — render the `CitationProvenance.bbox` rectangle
   on the actual PDF page (the data is already captured by GROBID ingest).

---

## Verification note

Everything marked "shipped" is covered by `npm run build` + the headless
`electron/smoke.cjs` (which exercises the new libs deterministically). The
model-dependent and network-dependent paths are wired and compile but are
**not** exercised live here — that's stated plainly rather than implied.
