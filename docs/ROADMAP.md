# Kaisola — Phased Roadmap

Five phases. Each ships a coherent slice of the trajectory. We build **within the chosen stack** — Electron (main+preload) + Vite + React 18 + TypeScript renderer, Zustand state, lucide-react icons, @xyflow/react for the claim graph, hand-authored CSS with design tokens (no Tailwind), aesthetic target Cursor / Linear / Raycast. Agents are typed interfaces with a single Claude-API seam.

The guiding sequence: **make the trajectory real before making the agents real, and make the agents real before making execution real.** Provenance is load-bearing in every phase, not a final polish step.

> Repo reality (2026-06-10): the scaffold is partially started — `package.json`, `tsconfig.json`, `vite.config.ts`, `index.html`, and `src/{domain/types.ts, domain/ids.ts, domain/trust.ts, styles/tokens.css}` already exist and are the reconciled source of truth. Phase 0 builds the store, agents, views, components, Electron wrapper (`electron/main.cjs`), and seed scripts ON TOP of that foundation. `nanoid@3` is present; the Electron toolchain (`electron`, `concurrently`, `wait-on`, `cross-env`) is referenced in scripts but not yet installed.

## Phase 0 — The Scaffold (this build)

**Goal:** Ship the full skeleton of the Research IDE — all 9 stage views navigable, the design system in place, the research-diff primitive working end-to-end with mock data, and a clear seam where the Claude API plugs in.

**What ships REAL (functional with seed/mock data):**
- App shell: Electron window (`electron/main.cjs` + `preload.cjs`), dark-first design-token theme (`src/styles/tokens.css`, already authored), command palette (⌘K), keyboard navigation, the 9-stage trajectory rail. Also runs as a plain web app via `npm run dev` (webMock bridge).
- **Corpus view** — loads the real 2898-paper seed JSON (`id, title, authors[], org, date, url, pdf_url, arxiv_id, abstract, summary, topics[], venue, cited_by, sources`); filter by topic vocab (Agents, Reasoning, Evaluations, …); select a ~20-paper cluster.
- **Claim Graph view** — @xyflow/react canvas rendering typed nodes (`GraphNodeType`: paper/claim/method/dataset/metric/result/limitation/assumption/contradiction/openQuestion) and typed edges (`GraphRelation`: supports/contradicts/uses/measures/motivates) from seed fixtures. Pan/zoom/select.
- **Research-diff primitive** — the `ProposalCard` + `ResearchDiff` components: old/new, reason, evidence links, approve/edit/reject, wired into Zustand so `approve()` → `applyProposal` mutates `Project` state. This is the keystone; it must feel slick.
- **Auto Lab Notebook** — timestamped, append-only `NotebookEntry[]` stream (status strip + drawer).
- **Trust Score** chip + inline **Unsupported** flag rendering (visual + state, `computeTrust` already implemented in `domain/trust.ts`).
- **Stage gates** — the `StageGate` checkpoint UI between stages (criteria mocked).

**What ships STUBBED (typed interfaces, mock Proposals, no real LLM):**
- All 10 agents — typed `Agent` interfaces (defined in `domain/types.ts`) returning hand-authored mock Proposals via `proposalFactory`.
- **Idea Generation, Experiment Planning, Execution, Analysis, Writing+Review** views — present and navigable, populated by the time-awareness demo fixtures, but agent outputs are mock and execution does not actually run code.
- Trust/citation verifiers — interfaces only (`src/trust/*`).

**Success criteria:**
- A user can walk the entire time-awareness demo trajectory across all 9 views using mock Proposals, approving each transition via the research-diff.
- The aesthetic reads Cursor/Linear caliber (dark, one olive accent `#8a9658`, Inter/Source Serif 4/JetBrains Mono).
- Swapping a mock agent for a real one requires touching only the agent adapter + `modelHandler.cjs` — no view changes.

## Phase 1 — Real Corpus + Claim Extraction + Provenance Editor

**Goal:** Make the *literature → claim graph → provenance* spine real. Before any agent autonomy, the evidence substrate must be trustworthy.

**Key features:**
- Real corpus import beyond the seed: arXiv ID / DOI / PDF / BibTeX → typed `Paper` nodes; dedupe; persistence (Zustand persist → local store; the trajectory survives restart).
- Deterministic / rules-based **claim extraction** from abstracts + summaries into typed nodes and edges (still pre-LLM-agent; heuristics + the seam).
- **Provenance editor** enforcing the philosophy rule: every claim node carries ≥1 `ProvenanceLink`; the editor blocks/flags claims with empty `provenance` (trust `unsupported`).
- Evidence-link UI: claim → paper quote, with the quote span captured (`CitationProvenance.quote` + `locator`).

**Success criteria:**
- Import a real 20-paper cluster (not just the seed) and get a navigable, persisted claim graph.
- Every claim resolves to ≥1 evidence link; unsupported claims are visibly flagged and cannot be silently exported.

## Phase 2 — Agent Layer (Claude API) + Live Research Diffs

**Goal:** Replace mock Proposals with real ones from `claude-opus-4-8` behind the existing agent seam — Literature, Novelty, Hypothesis, ExperimentPlanning, Writing, Reviewer agents go live as Proposal generators.

**Key features:**
- Claude-API adapter in `electron/ipc/modelHandler.cjs` (model id pinned in MAIN, key never in renderer); structured Proposal output with the fixed `ProposalRationale` schema.
- `literature` proposes the field map as a diff; `hypothesis` emits real idea cards; `novelty` returns closest-related-work with real quotes; `planning` drafts real specs; `writing` produces artifact-grounded prose; `reviewer` emits evidence-tied weaknesses.
- Every agent output flows through the **same research-diff UI** from Phase 0 — approve/edit/reject, no new surface.
- Caching + cost controls; agent calls are explicit, never silent background runs.

**Success criteria:**
- A real agent-generated idea card and experiment spec are produced for the time-awareness project and accepted through the research-diff with edits.
- No agent mutates the trajectory without passing the human gate (the `approve()` chokepoint holds).
- Provenance from Phase 1 holds: every agent claim arrives with evidence links.

## Phase 3 — Execution Sandbox + Lab Notebook + Figures

**Goal:** Make *experiment plans → runs → results → figures* real. Connect to compute, run code, capture artifacts, and link figures to their source.

**Key features:**
- Execution view as a real IDE surface: repo, code editor, `RunConfig` (seeds, env), logs, artifacts.
- Compute backends (`ExecutionBackend`): local / Docker / Modal / RunPod / Slurm connectors via `electron/ipc/toolHandler.cjs`, with the **compute-approval gate** (`computeApproved`) before any run.
- `coding` + `execution` agents propose code and fixes as diffs; failures surface as Proposals, not silent retries.
- **Auto Lab Notebook** captures real timestamped run events (tried→failed→fixed→reran, with `NotebookEntry.delta` metric deltas).
- Analysis view: real `ResultTable`/`Figure` from run artifacts; significance tests (`ResultRecord.significance` / `signal`); "what changed vs last run?" (`comparedTo`); **figure→script+data** links recorded automatically (`Artifact.producedBy`).

**Success criteria:**
- The time-awareness experiment (or a reduced 1 model × 1 scaffold × N tasks slice) actually runs end-to-end on a real backend with seeds.
- Every figure produced carries a working figure→code+data provenance link.
- The notebook reconstructs the run history with metric deltas.

## Phase 4 — Trust / Citation Verification + Reviewer Simulation

**Goal:** Harden the trust layer into first-class, shippable safety — the feature that lets a researcher actually trust the output.

**Key features:**
- **Citation verifier** (resolves DOIs/arXiv IDs, checks the quote actually supports the sentence — counters hallucinated refs; sets `VerificationState`).
- **Result provenance checker** and **figure-to-code linker** hardened.
- **Dataset license checker**, **reproducibility checklist**, **AI-disclosure generator** (`Manuscript.aiDisclosure`), **claim-support checker**.
- Per-section **Trust Score** computed from real verifier signals (e.g. *Results: medium, only 2 seeds · References: high, DOIs verified*).
- Full **Reviewer simulation**: scores + weaknesses tied to concrete evidence (or its absence; `ReviewerComment.flagsUnsupported` / `predictedByRisk`), feeding the revise loop.

**Success criteria:**
- A draft of the time-awareness experiment exports with a per-section Trust Score backed by real verification, zero unresolved Unsupported flags, and zero hallucinated citations.
- The reviewer sim produces actionable, evidence-grounded weaknesses that round-trip back into the loop as new Proposals.
- The end-to-end MVP promise holds: 20-paper cluster → reproducible experiment draft with full provenance in one focused sprint.
