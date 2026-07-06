## Kaisola Architecture (final) — Electron + Vite + React 18 + TS + Zustand

Verified against the live repo: the scaffold ALREADY exists at `/Users/michaelofengenden/Documents/Kaisola`. `package.json` declares `"main": "electron/main.cjs"`, `type: "module"`, deps `@xyflow/react ^12.3`, `lucide-react ^0.456`, `react ^18.3`, `zustand ^4.5`, and `nanoid@3.3.12` is installed (transitively). `src/domain/{types.ts,ids.ts,trust.ts}` and `src/styles/tokens.css` are in place and are the source of truth. `electron/`, `scripts/`, the Zustand store, agents, views, and components do NOT yet exist — this doc specifies them. Seed corpus: `/Users/michaelofengenden/Documents/Kaisola/ResearchPubs/data/papers.json` = `{updated, count: 2898, papers[]}`, fields `id,title,authors[],org,date,url,pdf_url,arxiv_id,abstract,summary,topics[],venue,cited_by,sources` (orgs: deepmind 1775 / openai 503 / other 332 / anthropic 288; topics incl. Agents 418, Reasoning 358, Evaluations 459, plus 'Other'/'Policy & Society').

### 1. File / folder tree

```
kaisola/
├── package.json                  # EXISTS. scripts: dev / build / preview / typecheck / seed / electron:dev / electron
├── tsconfig.json                 # EXISTS. strict, bundler resolution, paths { "@/*": ["src/*"] }
├── tsconfig.node.json            # ADD: Node target for electron/ + scripts/ + vite.config
├── vite.config.ts                # EXISTS. base:'./', @ alias, port 5173
├── index.html                    # EXISTS. loads Inter/Source Serif 4/JetBrains Mono; mounts /src/main.tsx
├── electron-builder.yml          # ADD: packaging (mac/win/linux)
├── .env.example                  # ADD: ANTHROPIC_API_KEY (read in MAIN only)
│
├── electron/                     # ── ELECTRON (Node, trusted). main is electron/main.cjs ──
│   ├── main.cjs                  # ADD: BrowserWindow, lifecycle; loads PASOLA_DEV_URL in dev else dist/index.html
│   ├── preload.cjs               # ADD: contextBridge → window.kaisola (typed via shared/ipc-contract)
│   ├── secrets.cjs               # ADD: reads ANTHROPIC_API_KEY from env/keychain in MAIN only
│   └── ipc/
│       ├── channels.cjs          # ADD: channel-name constants
│       ├── registerHandlers.cjs  # ADD: wires all ipcMain.handle()
│       ├── modelHandler.cjs      # ADD: 'model:complete' → Anthropic SDK (claude-opus-4-8). THE LLM SEAM.
│       ├── fsHandler.cjs         # ADD: 'fs:read'/'fs:write'/'fs:pickDir' (sandboxed to project dir)
│       ├── corpusHandler.cjs     # ADD: 'corpus:load' → reads papers.json subset from disk
│       └── toolHandler.cjs       # ADD: 'tool:runExperiment' → spawn/Docker/Modal adapter (stub)
│
├── shared/                       # ── TYPES shared main↔renderer (no runtime deps) ──
│   └── ipc-contract.ts           # ADD: KaisolaBridge (window.kaisola shape). Re-uses ModelRequest/ModelResponse from src/domain/types.ts
│
├── src/                          # ── RENDERER (React) ──
│   ├── main.tsx                  # ADD: React root; imports styles/index.css; mounts <App/>
│   ├── App.tsx                   # ADD: shell — TopBar + TrajectoryRail + active <View/> + Inspector + StatusBar + CommandPalette
│   ├── env.d.ts                  # ADD: declare global Window.kaisola (from shared/ipc-contract)
│   │
│   ├── domain/                   # ── PURE DOMAIN (no React/Zustand) — EXISTS ──
│   │   ├── types.ts              # EXISTS (the reconciled model). Project, Source, ClaimGraph, GraphNode,
│   │   │                         #   Hypothesis, ExperimentPlan, Run, ResultRecord, Manuscript, Review,
│   │   │                         #   Proposal, ProposalChange, DiffPayload, StageGate, Agent, ModelRequest…
│   │   ├── ids.ts                # EXISTS. uid(prefix), nowISO()
│   │   └── trust.ts              # EXISTS. computeTrust(ProvenanceLink[]) → TrustLevel, sectionTrust, TRUST_LABEL
│   │
│   ├── store/                    # ── ZUSTAND ── (ADD)
│   │   ├── index.ts              # createStore(): slices + immer + persist + devtools
│   │   ├── types.ts              # RootState = all slices; SliceCreator<T>
│   │   ├── slices/
│   │   │   ├── projectSlice.ts   # active Project, stage, loadSeed()
│   │   │   ├── corpusSlice.ts    # Source[] CRUD, topic filter, cluster selection
│   │   │   ├── claimGraphSlice.ts# nodes/edges + setNodePosition (drives @xyflow/react)
│   │   │   ├── ideasSlice.ts     # ResearchQuestion[] + Hypothesis[]
│   │   │   ├── experimentsSlice.ts# ExperimentPlan[] + computeApproved gate
│   │   │   ├── runsSlice.ts       # Run[] + live notebook streaming
│   │   │   ├── manuscriptSlice.ts # Manuscript sections + trust recompute
│   │   │   ├── reviewsSlice.ts    # Review[]
│   │   │   ├── proposalsSlice.ts  # ★ PROPOSAL LIFECYCLE: propose/edit/reject/approve
│   │   │   ├── agentActivitySlice.ts # AgentActivity[] + notebook append
│   │   │   └── uiSlice.ts         # activeStage, selection, paletteOpen, theme, inspectorTab
│   │   ├── apply/applyProposal.ts # ★ pure reducer: approved Proposal → trajectory mutation (switch on DiffPayload.op)
│   │   └── selectors.ts          # memoized cross-slice: unsupportedClaims, trustByStage, pendingProposals, gateFor(stage)
│   │
│   ├── agents/                   # ── AGENT LAYER (mock now, Claude later) ── (ADD)
│   │   ├── AgentRegistry.ts      # Record<AgentId, Agent>; run(id,input,ctx) → Proposal[]
│   │   ├── modelClient.ts        # callModel() → bridge.model.complete (IPC)
│   │   ├── proposalFactory.ts    # buildProposal(): well-formed Proposal w/ rationale + evidence + ProposalChange[]
│   │   └── impl/                  # LiteratureAgent, NoveltyAgent, HypothesisAgent, PlanningAgent,
│   │       └── …                  #   CodingAgent, ExecutionAgent, AnalysisAgent, WritingAgent,
│   │                              #   ReviewerAgent, CitationAgent (10 files; AgentId 'human' has no impl)
│   │
│   ├── trust/                    # ── TRUST/SAFETY checkers (interfaces now) ── (ADD)
│   │   ├── citationVerifier.ts   # claim↔paper quote match → VerificationState
│   │   ├── resultProvenance.ts   # result↔run log linkage
│   │   ├── figureLinker.ts       # figure↔script+data linkage
│   │   ├── licenseChecker.ts     # dataset license
│   │   ├── claimSupportChecker.ts# every claim has evidence? → unsupported flags
│   │   ├── reproChecklist.ts     # reproducibility checklist
│   │   └── aiDisclosure.ts       # AI-disclosure generator
│   │
│   ├── views/                    # ── 9 STAGE VIEWS (keyed by TrajectoryStage) ── (ADD)
│   │   ├── CorpusView.tsx        # 'corpus' — papers/repos/datasets/notes; topic filter; cluster select
│   │   ├── ClaimGraphView.tsx    # 'claims' — @xyflow/react canvas (GraphNodeType nodes, GraphRelation edges)
│   │   ├── QuestionsView.tsx     # 'questions' — research questions from open-question nodes
│   │   ├── IdeasView.tsx         # 'ideas' — Hypothesis cards (the three meters)
│   │   ├── ExperimentPlanView.tsx# 'experiments' — spec editor + reviewer-risk checklist + compute gate
│   │   ├── ExecutionView.tsx     # 'runs' — repo/code/runs/logs IDE + Auto Lab Notebook
│   │   ├── AnalysisView.tsx      # 'analysis' — ResultTable/Figure, significance, "what changed vs last run?"
│   │   ├── WritingView.tsx       # 'manuscript' — editor w/ inline trust + Unsupported flags (reading-surface)
│   │   └── ReviewView.tsx        # 'review' — reviewer sim scores + evidence-tied weaknesses
│   │
│   ├── components/               # ── REUSABLE UI ── (ADD)
│   │   ├── signature/            # ★ the differentiators
│   │   │   ├── ResearchDiff.tsx  #   old/new diff blocks (ProposalChange.before/after)
│   │   │   ├── ProposalCard.tsx  #   wraps ResearchDiff + ProposalRationale + approve/edit/reject
│   │   │   ├── ProposalInbox.tsx #   pending-proposal queue (Inspector "Proposals" tab)
│   │   │   ├── ProvenanceChip.tsx#   evidence chip + provenance popover
│   │   │   ├── TrustScoreBadge.tsx#  TrustLevel badge + coverage bar
│   │   │   ├── UnsupportedFlag.tsx#  inline "Unsupported. Add citation…" marker
│   │   │   ├── HypothesisCard.tsx#   the three-meter idea card
│   │   │   ├── NotebookStream.tsx#   Auto Lab Notebook stream
│   │   │   └── StageGate.tsx     #   between-stage approval gate
│   │   ├── layout/
│   │   │   ├── TopBar.tsx · TrajectoryRail.tsx · Inspector.tsx · StatusBar.tsx
│   │   │   ├── CommandPalette.tsx · AgentActivityRail.tsx
│   │   └── primitives/           # Button, Card, Panel, Tabs, Tooltip, Kbd, Badge, Spinner, EmptyState
│   │
│   ├── hooks/                    # useStore selectors, useHotkeys (⌘K, A/E/R), useAgent, useProposals (ADD)
│   ├── lib/bridge.ts             # window.kaisola ?? webMock (so `npm run dev` works in a plain browser) (ADD)
│   ├── lib/webMock.ts            # browser-only KaisolaBridge impl (mirrors IPC seam) (ADD)
│   ├── data/                     # ── SEED DATA (renderer-bundled) ── (ADD, generated)
│   │   ├── corpus.seed.json      # ~40-paper subset (from scripts/build-seed.mjs)
│   │   └── timeAwareness.trajectory.json # hand-authored demo Project
│   └── styles/
│       ├── tokens.css            # EXISTS (the full :root token block)
│       ├── global.css            # ADD: reset, font-faces, base layout
│       └── index.css             # ADD: @import tokens.css + global.css (imported by main.tsx)
│
└── scripts/
    ├── build-seed.mjs            # ADD (package.json "seed" already points here): papers.json → corpus.seed.json
    └── build-demo-trajectory.mjs # ADD: assembles timeAwareness.trajectory.json
```

The 9 views are keyed by `TrajectoryStage` and routed by `uiSlice.activeStage` in `App.tsx`. Signature components live in `src/components/signature/`.

### 2. Zustand store (single store, slice pattern, immer)

`RootState` intersects all slices. The keystone is `proposalsSlice` + `apply/applyProposal.ts`: **`approve()` is the ONLY path from a Proposal to a trajectory mutation**, funneled through one pure reducer that switches on `DiffPayload.op` (from `src/domain/types.ts`). This makes the whole process auditable and gives free history/undo.

```ts
// src/store/types.ts
import type { StateCreator } from 'zustand'
export type RootState =
  ProjectSlice & CorpusSlice & ClaimGraphSlice & IdeasSlice & ExperimentsSlice &
  RunsSlice & ManuscriptSlice & ReviewsSlice & ProposalsSlice &
  AgentActivitySlice & UiSlice
export type SliceCreator<T> = StateCreator<RootState, [['zustand/immer', never]], [], T>

// src/store/index.ts
import { create } from 'zustand'
import { immer } from 'zustand/middleware/immer'
import { devtools, persist } from 'zustand/middleware'
export const useStore = create<RootState>()(
  devtools(persist(immer((...a) => ({
    ...createProjectSlice(...a), ...createCorpusSlice(...a), ...createClaimGraphSlice(...a),
    ...createIdeasSlice(...a), ...createExperimentsSlice(...a), ...createRunsSlice(...a),
    ...createManuscriptSlice(...a), ...createReviewsSlice(...a), ...createProposalsSlice(...a),
    ...createAgentActivitySlice(...a), ...createUiSlice(...a),
  })), {
    name: 'kaisola-trajectory', version: 1,
    // persist durable trajectory only; transient agent/ui state excluded
    partialize: (s) => ({ project: s.project }),
  }), { name: 'Kaisola' }),
)
```

```ts
// src/store/slices/proposalsSlice.ts — the heart (lifecycle). Names match domain/types.ts exactly.
import type { SliceCreator } from '../types'
import type { Proposal } from '@/domain/types'
import { applyProposal } from '../apply/applyProposal'
import { nowISO } from '@/domain/ids'

export interface ProposalsSlice {
  pendingQueue: string[]   // Proposal.id, ordered → drives <ProposalInbox/>
  propose: (p: Proposal) => void                       // agent or human emits
  edit:    (id: string, patch: Partial<Proposal>) => void
  reject:  (id: string, reason: string) => void
  approve: (id: string) => void                        // ★ approve → applyProposal mutates trajectory
}

export const createProposalsSlice: SliceCreator<ProposalsSlice> = (set, get) => ({
  pendingQueue: [],
  propose: (p) => set((s) => {
    s.project.proposals.push(p)
    s.pendingQueue.push(p.id)
    s.project.notebook.unshift({ id: 'nb_' + p.id, at: nowISO(), level: 'action',
      text: `${p.agentId} proposed ${p.changes[0]?.payload.op ?? p.title}` })
  }),
  edit: (id, patch) => set((s) => {
    const p = s.project.proposals.find((x) => x.id === id); if (p) Object.assign(p, patch, { status: 'edited' })
  }),
  reject: (id, reason) => set((s) => {
    const p = s.project.proposals.find((x) => x.id === id); if (!p) return
    p.status = 'rejected'; p.rejectionReason = reason; p.resolvedAt = nowISO()
    s.pendingQueue = s.pendingQueue.filter((q) => q !== id)
  }),
  approve: (id) => set((s) => {
    const p = s.project.proposals.find((x) => x.id === id); if (!p) return
    for (const change of p.changes) applyProposal(s, change, p)   // ★ single mutation chokepoint
    p.status = 'approved'; p.resolvedAt = nowISO()
    s.pendingQueue = s.pendingQueue.filter((q) => q !== id)
  }),
})
```

```ts
// src/store/apply/applyProposal.ts — approved change → concrete mutation. Switches on DiffPayload.op.
import type { RootState } from '../types'
import type { ProposalChange, Proposal } from '@/domain/types'
import { uid } from '@/domain/ids'
import { computeTrust } from '@/domain/trust'

export function applyProposal(s: RootState, change: ProposalChange, p: Proposal): void {
  const d = change.payload
  switch (d.op) {
    case 'claim.change': {
      const n = s.project.claimGraph.nodes.find((x) => x.id === d.nodeId)
      if (n) { n.label = d.new.label; n.detail = d.new.detail
        if (d.evidence) { n.provenance = d.evidence; n.trust = computeTrust(d.evidence) } }
      break
    }
    case 'node.add': {
      const prov = (d.node as any).provenance ?? []
      s.project.claimGraph.nodes.push({ ...d.node, id: uid(d.node.type), trust: computeTrust(prov) } as any)
      break
    }
    case 'edge.add': s.project.claimGraph.edges.push({ ...d.edge, id: uid('edge') }); break
    case 'limitation.add': {
      const id = uid('limitation')
      s.project.claimGraph.nodes.push({ id, type: 'limitation', label: d.text, sourceIds: [],
        provenance: d.evidence ?? [], trust: computeTrust(d.evidence ?? []) })
      if (d.targetNodeId) s.project.claimGraph.edges.push({ id: uid('edge'), source: id, target: d.targetNodeId, relation: 'motivates' })
      break
    }
    case 'hypothesis.add': s.project.hypotheses.push({ ...d.hypothesis, id: uid('hyp'), trust: computeTrust(d.hypothesis.provenance) }); break
    case 'experiment.add': s.project.experiments.push({ ...d.plan, id: uid('exp'), status: 'draft', trust: computeTrust(d.plan.provenance) } as any); break
    case 'run.queue': s.project.runs.push({ id: uid('run'), experimentId: d.experimentId, label: 'queued', status: 'queued', config: d.config, notebook: [], artifacts: [] }); break
    case 'result.record': s.project.results.push({ ...d.result, id: uid('result'), trust: computeTrust(d.result.provenance) }); break
    case 'figure.add': s.project.figures.push({ ...d.figure, id: uid('fig'), trust: computeTrust(d.figure.provenance) }); break
    case 'section.write': {
      const sec = s.project.manuscript.sections.find((x) => x.id === d.sectionId); if (sec) sec.body = d.new; break
    }
    case 'review.add': s.project.reviews.push({ ...d.review, id: uid('review') }); break
    case 'citation.add': case 'citation.remove': case 'question.add': case 'experiment.edit':
      /* analogous mutations — attach/detach ProvenanceLink, recompute trust */ break
  }
}
```

### 3. Agent layer (the Claude seam)

`Agent`, `AgentContext`, `ModelRequest`, `ModelResponse` are defined in `src/domain/types.ts`. Agents are pure-ish: `run(input, ctx) → Promise<Proposal[]>` — they NEVER touch the store. Their only outside capability is `ctx.callModel`, a thin IPC wrapper. The entire mock→Claude switch lives in `electron/ipc/modelHandler.cjs` (model id `claude-opus-4-8` pinned in MAIN, key never in renderer).

```ts
// src/agents/AgentRegistry.ts
import type { Agent, AgentId, AgentContext, Proposal } from '@/domain/types'
import { HypothesisAgent } from './impl/HypothesisAgent' // …+9 more
const agents: Partial<Record<AgentId, Agent<any>>> = {
  literature: LiteratureAgent, novelty: NoveltyAgent, hypothesis: HypothesisAgent,
  planning: PlanningAgent, coding: CodingAgent, execution: ExecutionAgent,
  analysis: AnalysisAgent, writing: WritingAgent, reviewer: ReviewerAgent, citation: CitationAgent,
}
export const AgentRegistry = {
  get: (id: AgentId) => agents[id],
  async run(id: AgentId, input: unknown, ctx: AgentContext): Promise<Proposal[]> {
    const a = agents[id]; if (!a) throw new Error(`No agent: ${id}`)
    ctx.log(`${id} started`, 'action')
    const out = await a.run(input, ctx)
    ctx.log(`${id} produced ${out.length} proposal(s)`, 'observation')
    return out
  },
}
```

```ts
// src/agents/impl/HypothesisAgent.ts — MOCK now, real seam visible (Time-awareness dogfood)
import type { Agent } from '@/domain/types'
import { buildProposal } from '../proposalFactory'
export const HypothesisAgent: Agent<{ fromNodeIds: string[] }> = {
  id: 'hypothesis', title: 'Hypothesis Agent', description: 'Generates candidate hypotheses from the claim graph.',
  async run(input, ctx) {
    const USE_REAL = false
    if (USE_REAL) {
      const res = await ctx.callModel({ system: '…', messages: [{ role: 'user', content: '…' }], responseFormat: 'json' })
      return parseProposals(res)
    }
    return [buildProposal({
      agentId: 'hypothesis', stage: 'ideas',
      change: { kind: 'create', entityType: 'hypothesis', label: 'Add hypothesis: latency-as-clock prompting',
        payload: { op: 'hypothesis.add', hypothesis: {
          title: 'Latency-as-clock prompting', claim: 'Time-aware prompts improve budgeted-task success.',
          why: 'Claim graph shows agents rarely track wall-clock time.',
          noveltyRisk: 3, feasibility: 2,
          computeEstimate: { summary: '3 models × 2 scaffolds × 50 tasks ≈ 12 GPU-h', estHours: 12 },
          dataNeeds: 'deadline-task suite; slow-accurate vs fast-approximate tools',
          failureModes: ['models ignore timer tool', 'latency too noisy'],
          mvp: '1 model, timer on/off, 20 tasks', closestRelatedWork: [], expectedContribution: 'first budget-aware timing eval',
          provenance: [/* CitationProvenance from the corpus subset */], status: 'proposed' } } },
      rationale: { why: 'Budget-awareness is untested in the cluster.', failureConditions: 'No effect if tasks are not latency-sensitive.',
        minimalVersion: '1 model, timer on/off, 20 tasks', reviewerComplaint: 'Only one task family; generalization unclear.',
        whatIsMeasured: 'task success under fixed deadline, with/without timer tool.' },
      evidence: [/* the same ProvenanceLink(s) */],
    })]
  },
}
```

### 4. Electron / preload / IPC

Security: `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`. Renderer reaches Node ONLY through `window.kaisola`. API key lives in MAIN (`electron/secrets.cjs`), never shipped to renderer; the model call crosses IPC. (`.cjs` extensions because `package.json` has `type:"module"` but Electron main/preload run as CommonJS — matching the declared `"main": "electron/main.cjs"`.)

```ts
// shared/ipc-contract.ts — single typed bridge shape
import type { ModelRequest, ModelResponse, RunConfig } from '@/domain/types'
export interface KaisolaBridge {
  model: { complete: (req: ModelRequest) => Promise<ModelResponse> }
  fs: { read: (p: string) => Promise<string>; write: (p: string, c: string) => Promise<void>; pickProjectDir: () => Promise<string | null> }
  corpus: { load: () => Promise<unknown> }            // returns curated subset
  tool: { runExperiment: (cfg: RunConfig) => Promise<{ runId: string }>; onLog: (runId: string, cb: (line: string) => void) => () => void }
}
declare global { interface Window { kaisola: KaisolaBridge } }
```

```js
// electron/ipc/modelHandler.cjs — THE LLM SEAM (mock now, Anthropic later)
const { ipcMain } = require('electron')
const { CH } = require('./channels.cjs')
const { getApiKey } = require('../secrets.cjs')
const MODEL_ID = 'claude-opus-4-8' // pinned in main, never in renderer
function registerModelHandler() {
  ipcMain.handle(CH.MODEL_COMPLETE, async (_e, req) => {
    const key = getApiKey()
    if (!key) return { text: '{"mock":true}', stopReason: 'mock' }  // scaffold mode
    // LATER (one place): const { Anthropic } = require('@anthropic-ai/sdk')
    //   const r = await new Anthropic({ apiKey: key }).messages.create({ model: MODEL_ID, max_tokens: req.maxTokens ?? 4096, system: req.system, messages: req.messages })
    //   return { text: r.content[0].text, stopReason: r.stop_reason, usage: { in: r.usage.input_tokens, out: r.usage.output_tokens } }
    return { text: '', stopReason: 'unimplemented' }
  })
}
module.exports = { registerModelHandler }
```
> Confirm `claude-opus-4-8` / `@anthropic-ai/sdk` / `messages.create` against the current API reference (run the `claude-api` skill) before wiring the real call. The architecture isolates this to `modelHandler.cjs` alone.

```ts
// src/lib/bridge.ts — web fallback so `npm run dev` runs the full UI in a browser
import type { KaisolaBridge } from '../../shared/ipc-contract'
import { webMock } from './webMock'
export const bridge: KaisolaBridge =
  typeof window !== 'undefined' && (window as any).kaisola ? (window as any).kaisola : webMock
```

### Build scripts (package.json — ALREADY DECLARED; add tsconfig.node.json + electron toolchain)
- `dev` → `vite` (browser, uses `webMock`).
- `electron:dev` → `concurrently -k "vite" "wait-on tcp:5173 && cross-env PASOLA_DEV_URL=http://localhost:5173 electron ."` (needs `concurrently`, `wait-on`, `cross-env`, `electron` as devDeps — not yet installed).
- `build` → `tsc --noEmit && vite build` (renderer → `dist/`).
- `typecheck` → `tsc --noEmit`. `seed` → `node scripts/build-seed.mjs`. Add `package` → `electron-builder`.

### 5. Seed-data plan
**(a) Corpus subset** `scripts/build-seed.mjs` (package.json already maps `"seed"` here): reads `ResearchPubs/data/papers.json`, scores each paper for the Time-awareness demo (keywords time-aware/latency/deadline/budget/timer/tool-use + topic bonuses Agents/Reasoning/Evaluations + small cited_by tiebreak), takes top ~40, maps raw → `Paper` (numeric `id` → `paper_<id>`, `pdf_url`→`pdfUrl`, `arxiv_id`→`arxivId`, `cited_by`→`citedBy`, `sources`→`ingestSources`, add `kind:'paper'`, `addedAt`, `tags:[]`). Writes `src/data/corpus.seed.json`. Handle nullable fields (pdf_url ~57%, arxiv_id ~37%, cited_by ~63% present).

**(b) Demo trajectory** `scripts/build-demo-trajectory.mjs`: assembles a full pre-populated `Project` for "Time-awareness in LLM agents" pulling real `paper_<id>`s so evidence links resolve — ~6 claim-graph nodes (Claim/OpenQuestion/Metric/Method/Limitation) each with a `CitationProvenance` to a real corpus paper; the flagship Hypothesis (matching the mock above); one ExperimentPlan with reviewerRisks; 2 seeded mock Runs with metrics `0.34 → 0.49` (so Analysis + "real or noise?" and the notebook are populated); a Manuscript with per-section `trust` (`intro: medium`, `related-work: high`, `results: medium · only 2 seeds`); and a couple of `status:'pending'` Proposals (one Reviewer, one Citation) so the inbox is non-empty on first open. Both files bundle into the renderer (`src/data/`), loaded by `projectSlice.loadSeed()` on boot; `corpus:load` over IPC serves the same subset from disk in Electron.

### Why it holds together
- ONE core object (`Project` in `src/domain/types.ts`) flows through 9 views; every transition is a `Proposal` carrying typed `ProposalChange[]` (each with a `DiffPayload`), a fixed `ProposalRationale`, and non-empty `evidence`.
- `approve()` is the only path to a trajectory mutation, funneled through the single `applyProposal` reducer keyed on `DiffPayload.op` — auditable, with free history.
- Provenance is a TYPE not a convention: scientific entities mix in `Provenanced` (`provenance: ProvenanceLink[]` + computed `trust: TrustLevel`); `trust/` checkers set `VerificationState`; signature components render it.
- Agents never touch the store; the only seam to the model is `ctx.callModel` → `electron/ipc/modelHandler.cjs` (`claude-opus-4-8` pinned in main).
- Web and Electron share `shared/ipc-contract.ts`, so `npm run dev` runs the full UI against `webMock`.