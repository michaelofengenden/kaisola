/**
 * Kaisola domain model — the typed research trajectory. SINGLE SOURCE OF TRUTH.
 *
 * The primitive of Kaisola is NOT the paper. It is the research trajectory:
 *
 *   corpus → claim graph → questions → hypotheses → experiments
 *          → runs → results → manuscript → review → revisions
 *
 * Two ideas are first-class here and define the product:
 *
 *  1. PROVENANCE (the moat). Every scientific artifact carries `provenance`
 *     links back to one of: a citation, an experiment result, a derivation,
 *     a dataset, or a human note — plus a computed `trust` level. An
 *     `unsupported` claim is a MODELED STATE, not an oversight.
 *
 *  2. HUMAN-IN-THE-LOOP (the safety layer). Every transition in the trajectory
 *     is proposed by an agent as an inspectable, approvable `Proposal` carrying
 *     `changes` (rendered as research diffs), `evidence`, `rationale`, and
 *     `risks`. Nothing mutates the trajectory until a human approves.
 *
 * Naming conventions are STABLE — `trust.ts`, `ids.ts`, the Zustand store, the
 * agent layer, and the signature components all code against these exact names.
 * Discriminated unions tag on `kind` (provenance, source, diff) or `type`
 * (graph node), `relation` (graph edge) — never both for one union.
 */

// ─────────────────────────────────────────────────────────────────────────────
// Primitives
// ─────────────────────────────────────────────────────────────────────────────

/** All ids are prefixed strings (e.g. "paper_a1b2", "claim_7"). See domain/ids.ts. */
export type ID = string
/** ISO-8601 timestamp string, e.g. "2026-06-10T12:50:00Z". Dates are ALWAYS strings. */
export type ISODate = string

/** The nine trajectory stages. Drives the trajectory rail + per-stage gates. */
export type TrajectoryStage =
  | 'corpus'
  | 'claims'
  | 'questions'
  | 'ideas'
  | 'experiments'
  | 'runs'
  | 'analysis'
  | 'manuscript'
  | 'review'

/** The agents that can author proposals. Mock now; claude-opus-4-8 later. */
export type AgentId =
  | 'literature'
  | 'novelty'
  | 'hypothesis'
  | 'planning'
  | 'coding'
  | 'execution'
  | 'analysis'
  | 'writing'
  | 'reviewer'
  | 'citation'
  | 'human'

/** Who produced or decided something. Provenance-of-edits survives after the fact. */
export type Actor =
  | { kind: 'human'; name?: string }
  | { kind: 'agent'; agentId: AgentId; model?: string } // model e.g. 'claude-opus-4-8'
  | { kind: 'import'; source: string } // e.g. 'arxiv-sweep'
  | { kind: 'system' }

/** 1 = trivially novel / cheap / easy, 5 = extremely risky / expensive / hard. */
export type RiskScore = 1 | 2 | 3 | 4 | 5

// ─────────────────────────────────────────────────────────────────────────────
// Provenance & trust — the moat
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Trust is COMPUTED, not asserted (see domain/trust.ts → computeTrust).
 * Ordered worst→best so it can be min-reduced across a section's claims.
 * `unsupported` = a claim with zero provenance; the editor flags it inline.
 */
export type TrustLevel = 'unsupported' | 'low' | 'medium' | 'high'

/** The five — and only five — admissible kinds of evidence. */
export type ProvenanceKind = 'citation' | 'result' | 'derivation' | 'dataset' | 'note'

interface ProvenanceBase {
  id: ID
  kind: ProvenanceKind
  /** Optional free-text annotation on the link itself. */
  note?: string
  /** Verifier verdict, recomputed by the relevant checker agent (drives trust). */
  verification?: VerificationState
}

/**
 * Output of a verifier agent for one provenance link, kept separate from the
 * assertion. A `failed` verification (e.g. a hallucinated citation, which arXiv
 * now bans) caps the link's trust at 'low' in computeTrust.
 */
export interface VerificationState {
  status: 'unverified' | 'verifying' | 'verified' | 'failed' | 'stale'
  /** Which checker produced this verdict. */
  checkedBy?: AgentId
  checkedAt?: ISODate
  /** "DOI resolves; quote found verbatim" / "quote not present in PDF". */
  message?: string
}

/** Claim is supported by a paper. `verified` = the quote actually backs the claim. */
export interface CitationProvenance extends ProvenanceBase {
  kind: 'citation'
  sourceId: ID // → Paper.id
  /** The exact sentence(s) that support the claim (anti-hallucination: must exist). */
  quote?: string
  /** Where in the source, e.g. "§4.2" or "Fig. 3". */
  locator?: string
  /** Convenience flag mirrored from verification.status === 'verified'. */
  verified: boolean
}

/** Claim is supported by an experiment result produced inside Kaisola. */
export interface ResultProvenance extends ProvenanceBase {
  kind: 'result'
  resultId: ID // → ResultRecord.id
  runId: ID // → Run.id
  /** e.g. "success_rate 34% → 49%". */
  summary?: string
}

/** Claim follows from a stated mathematical / logical argument. */
export interface DerivationProvenance extends ProvenanceBase {
  kind: 'derivation'
  text: string
  /** A derivation may rest on other evidence links. */
  dependsOn?: ID[]
}

/** Claim is grounded in a dataset (and its license matters). */
export interface DatasetProvenance extends ProvenanceBase {
  kind: 'dataset'
  sourceId: ID // → Dataset.id
  license?: string
}

/** Claim is grounded in a human-authored note (lowest autonomy, highest agency). */
export interface NoteProvenance extends ProvenanceBase {
  kind: 'note'
  sourceId?: ID // → Note.id, if it lives in the corpus
  text?: string
  author?: string
  /** When true, anything backed only by this note is capped at 'low' (speculative). */
  speculative?: boolean
}

export type ProvenanceLink =
  | CitationProvenance
  | ResultProvenance
  | DerivationProvenance
  | DatasetProvenance
  | NoteProvenance

/** Mixin for anything that must justify its existence. */
export interface Provenanced {
  provenance: ProvenanceLink[]
  /** Cached/derived from `provenance` (see computeTrust in domain/trust.ts). */
  trust: TrustLevel
}

// ─────────────────────────────────────────────────────────────────────────────
// Corpus — sources (Zotero-like, but typed). Mirrors the 2898-paper seed JSON.
// ─────────────────────────────────────────────────────────────────────────────

export type SourceKind = 'paper' | 'repo' | 'dataset' | 'note'

interface SourceBase {
  id: ID
  kind: SourceKind
  title: string
  addedAt: ISODate
  tags: string[]
}

/**
 * Mirrors the seed JSON. Raw field set: id,title,authors[],org,date,url,pdf_url,
 * arxiv_id,abstract,summary,topics[],venue,cited_by,sources. On import the
 * numeric `id` is normalized to `paper_<n>`; snake_case → camelCase.
 */
export interface Paper extends SourceBase {
  kind: 'paper'
  authors: string[]
  org: string // 'anthropic' | 'openai' | 'deepmind' | 'other'
  date: ISODate // seed stores YYYY-MM-DD, a valid ISODate
  url?: string
  pdfUrl?: string // ← pdf_url (nullable in seed)
  arxivId?: string // ← arxiv_id (nullable in seed)
  doi?: string // resolved by the citation verifier when available
  abstract?: string
  /** One-paragraph auto summary; verify against the paper. */
  summary?: string
  topics: string[] // TOPIC_VOCAB ∪ 'Other' ∪ open strings
  venue?: string
  citedBy?: number // ← cited_by (often null in seed)
  /** Ingestion provenance, e.g. ['arxiv-sweep'] | ['openalex']. */
  ingestSources?: string[] // ← sources (renamed to avoid clash with Source)
  /** Whether claim extraction has run for this paper. */
  extracted?: boolean
}

export interface Repo extends SourceBase {
  kind: 'repo'
  url: string
  owner?: string
  stars?: number
  /** Pinned for reproducibility. */
  commit?: string
  language?: string
  license?: string
  /** Local checkout path when wired into the Execution module. */
  localPath?: string
  /** Paper(s) this repo implements. */
  paperIds?: ID[]
  reproducible?: boolean | 'unknown'
}

export interface Dataset extends SourceBase {
  kind: 'dataset'
  url?: string
  license?: string
  /** dataset-license-checker verdict for research use. */
  licenseStatus?: 'permissive' | 'restricted' | 'unknown' | 'incompatible'
  size?: string
  modality?: string
  splits?: string[]
}

/** Human-authored note — also the 5th provenance kind (see NoteProvenance). */
export interface Note extends SourceBase {
  kind: 'note'
  body: string
  author?: string
  /** When true, claims backed only by this note are capped at 'low' (speculative). */
  speculative?: boolean
}

export type Source = Paper | Repo | Dataset | Note

/** Known topic vocabulary from the seed corpus (open via the trailing string). */
export type TopicTag =
  | 'Training & Scaling'
  | 'Reinforcement Learning'
  | 'Evaluations'
  | 'Agents'
  | 'Alignment'
  | 'Reasoning'
  | 'Multimodal'
  | 'Safety'
  | 'Robustness & Security'
  | 'Science Applications'
  | 'Interpretability'
  | 'Policy & Society'
  | 'Other'
  | (string & {})

// ─────────────────────────────────────────────────────────────────────────────
// Claim graph — the research-understanding layer (rendered with @xyflow/react)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The 10 node types from the brief. `paper` nodes mirror a corpus Source; all
 * other nodes assert something and are therefore Provenanced. `openQuestion`
 * and `contradiction` surface the seams worth attacking.
 */
export type GraphNodeType =
  | 'paper'
  | 'claim'
  | 'method'
  | 'dataset'
  | 'metric'
  | 'result'
  | 'limitation'
  | 'assumption'
  | 'contradiction'
  | 'openQuestion'

export interface GraphNode extends Provenanced {
  id: ID
  type: GraphNodeType
  label: string // short display text
  detail?: string // longer body / the full claim text
  /** Corpus sources this node was extracted from. */
  sourceIds: ID[]
  /** Free layout position for the canvas (react-flow). */
  position?: { x: number; y: number }
}

/** Edge SEMANTICS from the brief, plus two convenience relations. */
export type GraphRelation =
  | 'supports'
  | 'contradicts'
  | 'uses'
  | 'measures'
  | 'motivates'
  | 'extends'
  | 'addresses'

export interface GraphEdge {
  id: ID
  source: ID // GraphNode.id
  target: ID // GraphNode.id
  relation: GraphRelation
  /** Optional strength 0..1 for visual weight. */
  weight?: number
  rationale?: string
}

export interface ClaimGraph {
  nodes: GraphNode[]
  edges: GraphEdge[]
}

// ─────────────────────────────────────────────────────────────────────────────
// Questions & hypotheses — idea generation
// ─────────────────────────────────────────────────────────────────────────────

export interface ResearchQuestion extends Provenanced {
  id: ID
  label: string // "Q1: Do agents track wall-clock time?"
  detail?: string
  /** Claim-graph nodes (open questions / contradictions) that motivate this RQ. */
  motivatedBy?: ID[]
  status: 'open' | 'in-progress' | 'answered' | 'parked'
  /** Hypotheses that address this question. */
  hypothesisIds: ID[]
}

export interface RelatedWork {
  sourceId: ID // a Paper in the corpus
  relation: 'closest' | 'same-motivation' | 'contradicts' | 'baseline'
  /** How this hypothesis differs / advances vs the related work. */
  note?: string
}

/**
 * Structured compute envelope. Used by Hypothesis, ExperimentPlan, and Run
 * configs so an estimate flows unchanged from idea → plan → gate.
 */
export interface ComputeEstimate {
  backend?: ExecutionBackend
  gpuType?: string // 'A100-80GB' | 'H100' | 'cpu'
  gpuCount?: number
  estHours?: number
  estCostUsd?: number
  /** Human-readable fallback, e.g. "3 models × 2 scaffolds × 50 tasks ≈ 12 GPU-h". */
  summary?: string
}

export interface Hypothesis extends Provenanced {
  id: ID
  questionId?: ID
  title: string // "Time-to-completion awareness in LLM agents"
  claim: string // the falsifiable statement
  why: string // why it matters
  /** High novelty == high risk: a single axis where 5 = novel-but-risky. */
  noveltyRisk: RiskScore
  feasibility: RiskScore // lower = more feasible
  computeEstimate: ComputeEstimate
  dataNeeds: string
  failureModes: string[]
  /** The minimum experiment that yields signal. */
  mvp: string
  closestRelatedWork: RelatedWork[]
  expectedContribution: string
  status: 'proposed' | 'selected' | 'rejected' | 'shipped'
}

// ─────────────────────────────────────────────────────────────────────────────
// Experiment planning
// ─────────────────────────────────────────────────────────────────────────────

export interface ExperimentVariable {
  name: string // "model" | "scaffold" | "timer"
  levels: string[] // ["Qwen3-8B", "Llama-3-8B", "GPT-4o-mini"]
}

export interface Metric {
  name: string // "success_rate"
  description?: string
  direction: 'maximize' | 'minimize'
  unit?: string
  /** How "is this result real or noise?" will be judged. */
  significanceTest?: 'bootstrap' | 'permutation' | 't-test' | 'mcnemar' | 'none'
}

/**
 * A pre-registered prediction of what a reviewer will attack. Once a Review
 * exists, `addressed` and ReviewerComment.predictedByRisk close the loop.
 */
export interface ReviewerRisk {
  id: ID
  concern: string // "only 2 seeds" | "confound: model speed vs time-awareness"
  severity: RiskScore
  mitigation?: string
  addressed?: boolean
}

export interface SuccessCriterion {
  metric: string // → Metric.name
  comparator: '>' | '>=' | '<' | '<=' | '=='
  threshold: number
  /** Compared against which baseline, if relative. */
  relativeTo?: string
}

export interface ExperimentPlan extends Provenanced {
  id: ID
  hypothesisId: ID
  title: string
  spec: string // the executable plan, prose — the "design doc" the human steers
  variables: ExperimentVariable[] // factors × levels (the design matrix)
  seeds: number[] // central to "is this real or noise?"
  baselines: string[]
  ablations: string[]
  metrics: Metric[]
  dataPlan: string
  datasetIds?: ID[]
  computeEstimate: ComputeEstimate
  successCriteria: SuccessCriterion[]
  reviewerRisks: ReviewerRisk[]
  status: 'draft' | 'approved' | 'running' | 'done'
  /** Approval gate: compute must be human-approved before runs start. */
  computeApproved?: boolean
}

// ─────────────────────────────────────────────────────────────────────────────
// Execution — runs, the auto lab notebook, artifacts
// ─────────────────────────────────────────────────────────────────────────────

export type ExecutionBackend = 'local' | 'docker' | 'modal' | 'runpod' | 'slurm' | 'cloud-gpu'

export type RunStatus =
  | 'queued'
  | 'setup'
  | 'running'
  | 'failed'
  | 'partial'
  | 'done'
  | 'cancelled'

/** Exact reproducibility envelope for a run. */
export interface RunConfig {
  backend: ExecutionBackend
  repoId?: ID
  commit?: string // pinned code state
  entrypoint?: string // command / script
  params?: Record<string, string | number | boolean>
  seeds: number[]
  env?: Record<string, string>
  gpu?: { type: string; count: number }
}

export type NotebookLevel = 'info' | 'action' | 'observation' | 'error' | 'fix' | 'result'

/** A single timestamped lab-notebook line ("12:50 reran 34% → 49%"). */
export interface NotebookEntry {
  id: ID
  at: ISODate
  by?: Actor
  level: NotebookLevel
  text: string
  /** Structured metric delta when applicable. */
  delta?: { metric: string; from?: number; to?: number }
  /** Optional artifact / run this line refers to. */
  artifactId?: ID
  runId?: ID
}

export type ArtifactType = 'figure' | 'table' | 'log' | 'checkpoint' | 'config' | 'file'

export interface Artifact {
  id: ID
  type: ArtifactType
  name: string
  /** Path or URL inside the run's workspace. */
  path?: string
  contentHash?: string // for provenance & change detection
  /** For figures/tables: the script + data that produced it (figure→code link). */
  producedBy?: { scriptPath?: string; dataPath?: string; commit?: string; cell?: string }
  createdAt: ISODate
}

export interface Run {
  id: ID
  experimentId: ID
  label: string // "Run 003: final results with ablation"
  status: RunStatus
  config?: RunConfig
  startedAt?: ISODate
  endedAt?: ISODate
  seed?: number // convenience for single-seed runs; full set in config.seeds
  env?: Record<string, string>
  notebook: NotebookEntry[]
  artifacts: Artifact[]
  exitCode?: number
  /** Short human/agent summary of what this run established. */
  summary?: string
}

// ─────────────────────────────────────────────────────────────────────────────
// Analysis — results, figures, tables
// ─────────────────────────────────────────────────────────────────────────────

export interface ResultRecord extends Provenanced {
  id: ID
  runId: ID
  experimentId?: ID
  metric: string // → Metric.name
  value: number
  unit?: string
  /** Condition this value was measured under, e.g. {model:"Qwen3-8B", timer:"on"}. */
  conditions: Record<string, string>
  seeds?: number
  stddev?: number
  ci?: [number, number]
  /** "is this real or noise?" verdict. */
  signal?: 'real' | 'likely-noise' | 'inconclusive'
  significance?: { test?: Metric['significanceTest']; pValue?: number; effectSize?: number }
  /** "what changed vs last run?" */
  comparedTo?: { runId: ID; deltaValue: number }
}

export interface Figure extends Provenanced {
  id: ID
  title: string
  artifactId: ID // → Artifact (figure); carries the figure→code link
  caption?: string
  resultIds?: ID[]
}

export interface ResultTable extends Provenanced {
  id: ID
  title: string
  columns: string[]
  rows: Array<Array<string | number>>
  caption?: string
  /** Each cell may map back to a Result for cell-level provenance: key "r{row}c{col}". */
  cellResults?: Record<string, ID>
}

// ─────────────────────────────────────────────────────────────────────────────
// Manuscript — artifact-grounded writing with per-section trust
// ─────────────────────────────────────────────────────────────────────────────

export type SectionKind =
  | 'abstract'
  | 'introduction'
  | 'related-work'
  | 'method'
  | 'experiments'
  | 'results'
  | 'limitations'
  | 'conclusion'
  | 'references'
  | 'appendix'

/**
 * A claim inside prose. The editor highlights claims whose trust is 'unsupported'
 * or 'low' and offers to attach a citation / result / note, or mark speculative.
 */
export interface InlineClaim extends Provenanced {
  id: ID
  text: string
  /** Char offsets within the owning section's body, if anchored. */
  range?: [number, number]
  speculative?: boolean // human marked it explicitly speculative
}

export interface Section {
  id: ID
  kind: SectionKind
  heading: string
  body: string // markdown
  claims: InlineClaim[]
  figureIds: ID[]
  /** Min-trust over the section's claims (cached; see sectionTrust). */
  trust: TrustLevel
}

export interface Manuscript {
  id: ID
  title: string
  sections: Section[]
  /** Auto-generated, evidence-grounded. */
  aiDisclosure?: string
  status?: 'draft' | 'in-review' | 'revising' | 'final'
  updatedAt: ISODate
}

// ─────────────────────────────────────────────────────────────────────────────
// Review — simulated peer review tied to evidence
// ─────────────────────────────────────────────────────────────────────────────

export type ReviewerPersona = 'reviewer-1' | 'reviewer-2' | 'reviewer-3' | 'area-chair'

export interface ReviewerComment {
  id: ID
  kind: 'strength' | 'weakness' | 'question'
  text: string
  /** Which section/claim/result the comment targets. */
  targetId?: ID
  /** Evidence the reviewer cites for the comment. */
  evidence: ProvenanceLink[]
  severity?: RiskScore
  /** True when the underlying claim is itself unsupported (sharpest critique). */
  flagsUnsupported?: boolean
  /** Links a weakness to a pre-registered ReviewerRisk.id when applicable. */
  predictedByRisk?: ID
}

export interface Review {
  id: ID
  manuscriptId?: ID
  persona: ReviewerPersona
  venue?: string
  /** e.g. ICLR 1–10. */
  score?: number
  recommendation: 'accept' | 'weak-accept' | 'borderline' | 'weak-reject' | 'reject'
  summary: string
  comments: ReviewerComment[]
  createdAt: ISODate
}

// ─────────────────────────────────────────────────────────────────────────────
// Proposals & research diffs — the human-in-the-loop primitive
// ─────────────────────────────────────────────────────────────────────────────

export type ProposalStatus = 'pending' | 'approved' | 'edited' | 'rejected'

/** The trajectory entity a change creates/updates/deletes. */
export type EntityType =
  | 'source'
  | 'graph-node'
  | 'graph-edge'
  | 'question'
  | 'hypothesis'
  | 'experiment'
  | 'run'
  | 'result'
  | 'figure'
  | 'table'
  | 'section'
  | 'inline-claim'
  | 'review'

export type ChangeKind = 'create' | 'update' | 'delete'

/**
 * The typed payload applied when a change is approved. Discriminated on `op`,
 * mirroring the brief's research-diff vocabulary. `applyProposal` switches on
 * this to mutate the trajectory. Each carries old/new (where applicable) so the
 * UI can render a real diff; `reason` lives on the enclosing ProposalChange.
 */
export type DiffPayload =
  | { op: 'claim.change'; nodeId: ID; old: { label: string; detail?: string }; new: { label: string; detail?: string }; evidence?: ProvenanceLink[] }
  | { op: 'node.add'; node: Omit<GraphNode, 'id' | 'trust'> }
  | { op: 'edge.add'; edge: Omit<GraphEdge, 'id'> }
  | { op: 'limitation.add'; targetNodeId?: ID; text: string; evidence?: ProvenanceLink[] }
  | { op: 'citation.add'; targetId: ID; targetType: EntityType; citation: Omit<CitationProvenance, 'id'> }
  | { op: 'citation.remove'; targetId: ID; linkId: ID }
  | { op: 'question.add'; question: Omit<ResearchQuestion, 'id' | 'trust' | 'hypothesisIds'> }
  | { op: 'hypothesis.add'; hypothesis: Omit<Hypothesis, 'id' | 'trust'> }
  | { op: 'experiment.add'; plan: Omit<ExperimentPlan, 'id' | 'trust' | 'runIds' | 'status'> }
  | { op: 'experiment.edit'; planId: ID; field: string; old: unknown; new: unknown }
  | { op: 'run.queue'; config: RunConfig; experimentId: ID }
  | { op: 'result.record'; result: Omit<ResultRecord, 'id' | 'trust'> }
  | { op: 'figure.add'; figure: Omit<Figure, 'id' | 'trust'> }
  | { op: 'section.write'; sectionId: ID; old: string; new: string }
  | { op: 'review.add'; review: Omit<Review, 'id'> }

/**
 * A single atomic change inside a proposal — rendered as one research diff row.
 * `before`/`after` drive the textual diff view; `payload` carries the structured
 * mutation applied on approval. `entityType`/`kind` summarize it for the inbox.
 */
export interface ProposalChange {
  id: ID
  kind: ChangeKind
  entityType: EntityType
  /** Human label, e.g. "Change main claim" or "Add limitation". */
  label: string
  /** For the textual diff view. */
  before?: string
  after?: string
  /** Per-change reason ("the first claim is too broad; runs 003–005 show…"). */
  reason?: string
  /** The structured, typed mutation to apply on approval. */
  payload: DiffPayload
}

/**
 * The fixed rationale schema every Proposal must answer (the cockpit framing).
 * Renders consistently so an agent can't skip a steering question.
 */
export interface ProposalRationale {
  why: string
  motivatingPapers?: ID[] // → Paper.id
  failureConditions?: string
  minimalVersion?: string
  reviewerComplaint?: string
  // For experiment-shaped proposals:
  whatIsMeasured?: string
  whatCode?: string
  whatCompute?: ComputeEstimate
}

export interface Proposal {
  id: ID
  agentId: AgentId
  author: Actor
  stage: TrajectoryStage
  title: string
  summary: string
  changes: ProposalChange[]
  /** The why — papers/results/notes motivating this proposal (the moat on diffs). */
  evidence: ProvenanceLink[]
  /** The cockpit framing: why / papers / fail / MVP / reviewer / measured / code / compute. */
  rationale: ProposalRationale
  /** "What a reviewer would complain about" — surfaced before approval. */
  risks?: string[]
  status: ProposalStatus
  createdAt: ISODate
  resolvedAt?: ISODate
  resolvedBy?: Actor
  /** When status === 'rejected'. */
  rejectionReason?: string
}

// ─────────────────────────────────────────────────────────────────────────────
// Stage gates — the human checkpoint at every transition
// ─────────────────────────────────────────────────────────────────────────────

export interface GateCriterion {
  id: ID
  label: string // "At least one hypothesis selected"
  status: 'met' | 'unmet' | 'warn' | 'ack-required'
  detail?: string // "H-04" | "3 open proposals not yet resolved"
}

export interface StageGate {
  from: TrajectoryStage
  to: TrajectoryStage
  criteria: GateCriterion[]
  /** True only when every criterion is met/acked → primary advance button enabled. */
  ready: boolean
}

// ─────────────────────────────────────────────────────────────────────────────
// Agent activity feed
// ─────────────────────────────────────────────────────────────────────────────

export type AgentActivityState = 'thinking' | 'proposed' | 'done' | 'error'

export interface AgentActivity {
  id: ID
  agentId: AgentId
  state: AgentActivityState
  text: string
  at: ISODate
  /** 0..1 progress for `thinking` agents. */
  progress?: number
  /** Proposal this activity produced, if any. */
  proposalId?: ID
}

// ─────────────────────────────────────────────────────────────────────────────
// Project — the workspace root (one research trajectory)
// ─────────────────────────────────────────────────────────────────────────────

export interface Project {
  id: ID
  name: string
  question: string // the headline research direction
  /** Where the human currently is in the trajectory (UI focus only). */
  stage: TrajectoryStage
  createdAt: ISODate
  updatedAt: ISODate

  corpus: Source[]
  claimGraph: ClaimGraph
  questions: ResearchQuestion[]
  hypotheses: Hypothesis[]
  experiments: ExperimentPlan[]
  runs: Run[]
  results: ResultRecord[]
  figures: Figure[]
  tables: ResultTable[]
  manuscript: Manuscript
  reviews: Review[]

  proposals: Proposal[]
  /** Project-wide auto lab notebook (run-scoped entries also live on Run.notebook). */
  notebook: NotebookEntry[]
  activity: AgentActivity[]
}

// ─────────────────────────────────────────────────────────────────────────────
// Agent layer — typed interfaces; mock now, claude-opus-4-8 later
// ─────────────────────────────────────────────────────────────────────────────

/** Read-only trajectory view + the ONLY path to the model (IPC → main). */
export interface AgentContext {
  state: Readonly<Project>
  /** THE LLM SEAM. Scaffold → mock; later → window.kaisola.model.complete. */
  callModel: (req: ModelRequest) => Promise<ModelResponse>
  /** Writes an Auto Lab Notebook line. */
  log: (text: string, level?: NotebookLevel) => void
  now: ISODate
}

export interface Agent<Input = unknown> {
  id: AgentId
  title: string
  description: string
  /** Pure-ish: produces Proposals for human review. NEVER mutates the store. */
  run(input: Input, ctx: AgentContext): Promise<Proposal[]>
}

/** IPC contract for the model call. Model id is pinned in MAIN, never here. */
export interface ModelRequest {
  system?: string
  messages: { role: 'user' | 'assistant'; content: string }[]
  responseFormat?: 'text' | 'json'
  maxTokens?: number
}
export interface ModelResponse {
  text: string
  stopReason: string
  usage?: { in: number; out: number }
}