/**
 * Kaisola domain model — the typed research trajectory.
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
 *     a dataset, or a human note — plus a computed `trust` level. Unsupported
 *     claims are a modeled state, not an oversight.
 *
 *  2. HUMAN-IN-THE-LOOP (the safety layer). Every transition in the trajectory
 *     is proposed by an agent as an inspectable, approvable `Proposal` carrying
 *     `changes` (rendered as research diffs), `evidence`, and `risks`. Nothing
 *     mutates the trajectory until a human approves.
 */

// ─────────────────────────────────────────────────────────────────────────────
// Primitives
// ─────────────────────────────────────────────────────────────────────────────

export type ID = string
/** ISO-8601 timestamp string, e.g. "2026-06-10T12:50:00Z". */
export type ISODate = string

export type TrajectoryStage =
  | 'corpus'
  | 'claims'
  | 'questions'
  | 'campaign'
  | 'ideas'
  | 'experiments'
  | 'runs'
  | 'analysis'
  | 'manuscript'
  | 'review'
  | 'files'

/**
 * Autonomy ladder (default 'propose'). Observe = read/answer only. Propose =
 * generate reviewable changesets. Execute = run only already-approved steps.
 * Sprint = continue autonomously within an approved budget. Gates what agents
 * may do without a human.
 */
export type AutonomyLevel = 'observe' | 'propose' | 'execute' | 'sprint'

/** The agents that can author proposals. Mock now; Claude-backed later. */
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

// ─────────────────────────────────────────────────────────────────────────────
// Provenance & trust — the moat
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Trust is computed, not asserted. Ordered worst→best so it can be min-reduced
 * across a section's claims.
 */
export type TrustLevel = 'unsupported' | 'low' | 'medium' | 'high'

export type ProvenanceKind = 'citation' | 'result' | 'derivation' | 'dataset' | 'note'

/** How a cited source stands toward the claim (scite.ai-style). Computed locally. */
export type CitationStance = 'supporting' | 'contrasting' | 'mentioning'

interface ProvenanceBase {
  id: ID
  kind: ProvenanceKind
  /** Optional free-text annotation on the link itself. */
  note?: string
}

/** A rectangle on a PDF page (GROBID coordinate span), in PDF points. */
export interface PdfBox {
  page: number
  x: number
  y: number
  w: number
  h: number
}

/** Claim is supported by a paper. Verified = the quote actually backs the claim. */
export interface CitationProvenance extends ProvenanceBase {
  kind: 'citation'
  sourceId: ID // → Paper.id
  /** The exact sentence(s) that support the claim. */
  quote?: string
  /** Where in the source, e.g. "§4.2" or "Fig. 3". */
  locator?: string
  /** The exact rectangle of the quote in the source PDF, from GROBID. */
  bbox?: PdfBox
  /** Set by the citation agent / human; false until checked. */
  verified: boolean
  /** Supporting / contrasting / mentioning — set by the citation verifier. */
  stance?: CitationStance
}

/** Claim is supported by an experiment result produced inside Kaisola. */
export interface ResultProvenance extends ProvenanceBase {
  kind: 'result'
  resultId: ID // → ResultRecord.id
  runId: ID // → Run.id
  /** e.g. "success_rate 34% → 49%". */
  summary?: string
}

/** Claim follows from a stated argument / derivation. */
export interface DerivationProvenance extends ProvenanceBase {
  kind: 'derivation'
  text: string
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
  /** Cached/derived from provenance (see computeTrust in domain/trust.ts). */
  trust: TrustLevel
}

// ─────────────────────────────────────────────────────────────────────────────
// Corpus — sources (Zotero-like, but typed)
// ─────────────────────────────────────────────────────────────────────────────

export type SourceKind = 'paper' | 'repo' | 'dataset' | 'note'

interface SourceBase {
  id: ID
  kind: SourceKind
  title: string
  addedAt: ISODate
  tags: string[]
}

export interface Paper extends SourceBase {
  kind: 'paper'
  authors: string[]
  org: string // 'anthropic' | 'openai' | 'deepmind' | 'other' | …
  date: ISODate
  url?: string
  pdfUrl?: string
  arxivId?: string
  abstract?: string
  /** One-paragraph auto summary; verify against the paper. */
  summary?: string
  topics: string[]
  venue?: string
  citedBy?: number
  /** Whether claim extraction has run for this paper. */
  extracted?: boolean
  /** Ingestion lifecycle when a paper is posted as a bare link. */
  ingestState?: 'observing' | 'ready' | 'failed'
  /** OpenAlex work id (e.g. "W2741809807"), once resolved. */
  openAlexId?: string
  /** Corpus paper ids this paper cites (the in-corpus citation graph, via OpenAlex). */
  references?: ID[]
  /** Full text parsed from the PDF by GROBID (for citation verification). */
  grobidText?: string
}

export interface Repo extends SourceBase {
  kind: 'repo'
  url: string
  owner?: string
  stars?: number
  /** Paper(s) this repo implements. */
  paperIds?: ID[]
  reproducible?: boolean | 'unknown'
}

export interface Dataset extends SourceBase {
  kind: 'dataset'
  url?: string
  license?: string
  size?: string
  modality?: string
}

export interface Note extends SourceBase {
  kind: 'note'
  body: string
  author?: string
}

export type Source = Paper | Repo | Dataset | Note

// ─────────────────────────────────────────────────────────────────────────────
// Claim graph — the research-understanding layer
// ─────────────────────────────────────────────────────────────────────────────

export type GraphNodeType =
  | 'claim'
  | 'method'
  | 'dataset'
  | 'metric'
  | 'result'
  | 'limitation'
  | 'assumption'
  | 'question'
  | 'contradiction'

export interface GraphNode extends Provenanced {
  id: ID
  type: GraphNodeType
  label: string
  detail?: string
  /** Sources this node was extracted from. */
  sourceIds: ID[]
  /** Free layout position for the canvas (react-flow). */
  position?: { x: number; y: number }
}

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
  status: 'open' | 'in-progress' | 'answered' | 'parked'
  /** Hypotheses that address this question. */
  hypothesisIds: ID[]
}

/** 1 = trivially novel / cheap / easy, 5 = extremely risky / expensive / hard. */
export type RiskScore = 1 | 2 | 3 | 4 | 5

export interface RelatedWork {
  sourceId: ID
  relation: 'closest' | 'same-motivation' | 'contradicts' | 'baseline'
  note?: string
}

export interface Hypothesis extends Provenanced {
  id: ID
  questionId?: ID
  title: string // "Time-to-completion awareness in LLM agents"
  claim: string // the falsifiable statement
  why: string // why it matters
  noveltyRisk: RiskScore
  feasibility: RiskScore // lower = more feasible
  computeEstimate: string // "≈18 GPU-hours"
  dataNeeds: string
  failureModes: string[]
  /** The minimum publishable experiment. */
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
}

export interface ReviewerRisk {
  concern: string // "novelty weak"
  severity: RiskScore
  mitigation?: string
}

export interface ExperimentPlan extends Provenanced {
  id: ID
  hypothesisId: ID
  title: string
  spec: string // the executable plan, prose
  variables: ExperimentVariable[] // factors × levels (the design matrix)
  baselines: string[]
  ablations: string[]
  metrics: Metric[]
  dataPlan: string
  computeEstimate: string
  successCriteria: string[]
  reviewerRisks: ReviewerRisk[]
  status: 'draft' | 'approved' | 'running' | 'done'
  /** Approval gate: compute must be human-approved before runs start. */
  computeApproved?: boolean
}

// ─────────────────────────────────────────────────────────────────────────────
// Research campaign — the bounded autonomy contract
// ─────────────────────────────────────────────────────────────────────────────

export type CampaignStatus = 'draft' | 'active' | 'paused' | 'complete'

export interface CampaignEvaluator {
  metric: string
  direction: 'maximize' | 'minimize'
  /** Optional threshold that is meaningful enough to promote a candidate. */
  target?: number
  unit?: string
}

export interface CampaignBudget {
  /** Total autonomous attempts permitted before the campaign pauses. */
  maxAttempts: number
  /** Wall-clock envelope for an individual attempt. */
  maxMinutesPerAttempt: number
  /** Human-readable compute/cost envelope, e.g. "24 GPU-hours" or "$50". */
  compute: string
}

/**
 * The program.md-style research contract: what may change, how progress is
 * measured, what evidence is required, and when autonomous work must stop.
 */
export interface ResearchCampaign {
  id: ID
  title: string
  objective: string
  evaluator: CampaignEvaluator
  budget: CampaignBudget
  runCommand: string
  editablePaths: string[]
  allowedCommands: string[]
  requiredEvidence: string[]
  stopConditions: string[]
  status: CampaignStatus
  championAttemptId?: ID
  createdAt: ISODate
  updatedAt: ISODate
}

export type AttemptStatus =
  | 'queued'
  | 'running'
  | 'failed'
  | 'ready'
  | 'accepted'
  | 'rejected'

/** One immutable, reproducible attempt in a campaign's experiment graph. */
export interface ExperimentAttempt {
  id: ID
  campaignId: ID
  experimentId: ID
  runId?: ID
  parentAttemptId?: ID
  hypothesis: string
  command: string
  patchSummary?: string
  commit?: string
  metric?: { name: string; value: number; unit?: string }
  cost?: string
  confidence?: 'unreplicated' | 'provisional' | 'replicated'
  artifactIds: ID[]
  status: AttemptStatus
  createdAt: ISODate
  completedAt?: ISODate
}

// ─────────────────────────────────────────────────────────────────────────────
// Execution — runs, the auto lab notebook, artifacts
// ─────────────────────────────────────────────────────────────────────────────

export type RunStatus =
  | 'queued'
  | 'setup'
  | 'running'
  | 'failed'
  | 'partial'
  | 'done'
  | 'cancelled'

export type NotebookLevel = 'info' | 'action' | 'observation' | 'error' | 'fix' | 'result'

/** A single timestamped lab-notebook line, written automatically by the agent. */
export interface NotebookEntry {
  id: ID
  at: ISODate
  level: NotebookLevel
  text: string
  /** Optional artifact this line produced/refers to. */
  artifactId?: ID
}

export type ArtifactType = 'figure' | 'table' | 'log' | 'checkpoint' | 'config' | 'file'

export interface Artifact {
  id: ID
  type: ArtifactType
  name: string
  /** Path or URL inside the run's workspace. */
  path?: string
  /** For figures/tables: the script + data that produced it (figure→code link). */
  producedBy?: { scriptPath?: string; dataPath?: string; cell?: string }
  createdAt: ISODate
}

export interface Run {
  id: ID
  experimentId: ID
  label: string // "Run 003: final results with ablation"
  status: RunStatus
  startedAt?: ISODate
  endedAt?: ISODate
  seed?: number
  env?: Record<string, string>
  notebook: NotebookEntry[]
  artifacts: Artifact[]
  /** Short human/agent summary of what this run established. */
  summary?: string
}

// ─────────────────────────────────────────────────────────────────────────────
// Analysis — results, figures, tables
// ─────────────────────────────────────────────────────────────────────────────

export interface ResultRecord extends Provenanced {
  id: ID
  runId: ID
  metric: string // → Metric.name
  value: number
  unit?: string
  /** Condition this value was measured under, e.g. {model: "Qwen3-8B", timer: "on"}. */
  conditions: Record<string, string>
  seeds?: number
  /** Agent/human judgement on whether this is real or likely noise. */
  signal?: 'real' | 'likely-noise' | 'inconclusive'
  ci?: [number, number]
}

export interface Figure extends Provenanced {
  id: ID
  title: string
  artifactId: ID // → Artifact (figure)
  caption?: string
}

// ─────────────────────────────────────────────────────────────────────────────
// Manuscript — artifact-grounded writing
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
  | 'appendix'

/**
 * A claim inside prose. The editor highlights claims whose trust is 'unsupported'
 * or 'low' and offers to attach a citation / result / note.
 */
export interface InlineClaim extends Provenanced {
  id: ID
  text: string
  /** Char offsets within the owning section's body, if anchored. */
  range?: [number, number]
  speculative?: boolean // human marked it as explicitly speculative
}

export interface Section {
  id: ID
  kind: SectionKind
  heading: string
  body: string // markdown
  claims: InlineClaim[]
  figureIds: ID[]
  /** Min-trust over the section's claims (cached). */
  trust: TrustLevel
}

export interface Manuscript {
  id: ID
  title: string
  sections: Section[]
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
}

export interface Review {
  id: ID
  persona: ReviewerPersona
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
  | 'section'
  | 'inline-claim'
  | 'review'
  | 'file'

export type ChangeKind = 'create' | 'update' | 'delete'

/**
 * A single atomic change inside a proposal — rendered as a research diff.
 * `before`/`after` drive the textual diff view; `payload` carries the
 * structured entity to create/update when the change is approved.
 */
export interface ProposalChange {
  id: ID
  kind: ChangeKind
  entityType: EntityType
  /** Human label, e.g. "Change main claim" or "Add limitation". */
  label: string
  /** For diffs: the textual before/after the agent proposes. */
  before?: string
  after?: string
  /** Per-change reason ("the first claim is too broad; runs 003–005 show…"). */
  reason?: string
  /** The structured value to apply on approval (typed at the call site). */
  payload?: unknown
}

export interface Proposal {
  id: ID
  agentId: AgentId
  stage: TrajectoryStage
  title: string
  summary: string
  changes: ProposalChange[]
  /** Why — the papers/results/notes motivating this proposal. */
  evidence: ProvenanceLink[]
  /** "What a reviewer would complain about" — surfaced before approval. */
  risks?: string[]
  status: ProposalStatus
  createdAt: ISODate
  resolvedAt?: ISODate
  /** Best-of-N grouping — competing proposals from the same task share this id. */
  groupId?: ID
  /** Background lifecycle task that produced this proposal. */
  taskId?: ID
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
  /** Proposal this activity produced, if any. */
  proposalId?: ID
}

// ─────────────────────────────────────────────────────────────────────────────
// Project — the workspace root
// ─────────────────────────────────────────────────────────────────────────────

export interface Project {
  id: ID
  name: string
  question: string // the headline research direction
  createdAt: ISODate
  updatedAt: ISODate

  corpus: Source[]
  claimGraph: ClaimGraph
  questions: ResearchQuestion[]
  campaign: ResearchCampaign | null
  hypotheses: Hypothesis[]
  experiments: ExperimentPlan[]
  attempts: ExperimentAttempt[]
  runs: Run[]
  results: ResultRecord[]
  figures: Figure[]
  manuscript: Manuscript
  reviews: Review[]

  proposals: Proposal[]
  activity: AgentActivity[]
}
