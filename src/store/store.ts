import { create } from 'zustand'
import { persist, type PersistStorage } from 'zustand/middleware'
import type {
  Project,
  TrajectoryStage,
  EntityType,
  ProvenanceLink,
  Proposal,
  AgentId,
  AutonomyLevel,
  Paper,
  Manuscript,
  GraphNode,
  GraphEdge,
  Hypothesis,
  ResearchQuestion,
  ExperimentPlan,
  Run,
  ResultRecord,
  Figure,
  Review,
  ResearchCampaign,
  ExperimentAttempt,
  Source,
  NotebookLevel,
  ID,
} from '../domain/types'
import { seedProject } from '../data/seed'
import { nowISO, uid } from '../domain/ids'
import { observe } from '../lib/observe'
import { agentById } from '../agents/registry'
import { runAgent as runAgentLogic } from '../agents/run'
import { agentsForStage } from '../agents/supervisor'
import type { AgentContext } from '../agents/types'
import { buildAgentContext } from '../lib/relevance'
import { verifyCitation } from '../lib/verify'
import { recomputeProvenanced, sectionTrust } from '../domain/trust'
import { extractDoi, lookupOpenAlex, lookupOpenAlexByArxiv, resolveReferences } from '../lib/openalex'
import { parseTei, locateQuote } from '../lib/grobid'
import { bridge, isDesktop, acpScope, type AcpPermissionRequest, type McpProposalEvent } from '../lib/bridge'
import { folderHue } from '../lib/sessionHue'
import { lineHunks, applyHunks } from '../lib/wordDiff'
import { forgetMountedTerminal } from '../components/Terminal'
import {
  allowOnceAnswer,
  rejectOnceAnswer,
  requestIsSensitive,
  requestMatchesRules,
  ruleForRequest,
  ruleLabel,
  type PermissionRule,
} from '../lib/permissionRules'

export type { PermissionRule }

export type Theme = 'dark' | 'light'
/** 'system' follows macOS appearance live (incl. scheduled/sunset switches). */
export type ThemeMode = Theme | 'system'
export type LayoutMode = 'focus' | 'studio'
/** Appearance energy: native live glass or the opaque, still Eco shell. */
export type PerfMode = 'glass' | 'eco'
/** Project/session hierarchy treatment. Applied live per app window. */
export type TabLayout = 'shelf' | 'bare' | 'runway' | 'flat' | 'compact'
export type PaletteMode = 'commands' | 'files'

/** A working-tree checkpoint — a real (hidden-ref) git commit of everything. */
export interface RepoCheckpoint {
  id: string
  sha: string
  label: string
  at: string
}

/** One line of the live agent feed (Claude hook events + ACP tool calls). */
export interface AgentFeedItem {
  id: string
  at: number
  kind: 'prompt' | 'tool' | 'stop' | 'permission' | 'task'
  text: string
  path?: string
  tool?: string
}

/** Live identity of a terminal session — merged from the main-process poller
 * (fg process / cwd / repo / branch) and the renderer (OSC title, exit code). */
export interface TerminalMeta {
  fgProcess?: string | null
  running?: boolean
  /** A CLI agent has an unanswered prompt. Unlike `running` this settles when
   * output goes quiet, so Codex/Claude tabs do not pulse forever while idle. */
  agentBusy?: boolean
  /** Broker timestamp for deduplicating completion receipts across reconnects. */
  agentCompletedAt?: number | null
  cwd?: string | null
  root?: string | null
  repo?: string | null
  branch?: string | null
  oscTitle?: string | null
  lastExit?: number | null
  /** Dev-server ports spotted in this terminal's output (newest first). */
  ports?: number[]
}

export interface Selection {
  type: EntityType
  id: string
}

/** What the provenance popover is currently explaining. */
export interface ProvenanceTarget {
  title: string
  links: ProvenanceLink[]
  anchor?: { x: number; y: number }
}

/**
 * An assistant chat thread. The session metadata lives here (so the sidebar can
 * list it next to the terminals); the turn runtime is stored separately by id.
 */
export type ClaudeEffort = 'default' | 'low' | 'medium' | 'high' | 'xhigh' | 'max'
export type CodexEffort = 'low' | 'medium' | 'high' | 'xhigh' | 'max' | 'ultra'
export interface AssistantThread {
  id: string
  agentKey: string
  /** Manual rename — always wins over the derived autoName. */
  name?: string
  /** Derived from the first message's topic; display fallback. */
  autoName?: string
  busy: boolean
  /** Session cwd override (worktree sessions) — falls back to the workspace. */
  cwd?: string
  /** The agent-side ACP session id — reconnects after a restart try
   * session/load with it so the agent resumes where the transcript left off. */
  acpSessionId?: string
  /** Claude SDK effort is a session-creation option. Changing it reconnects
   * this resumable ACP session with the new value. */
  claudeEffort?: ClaudeEffort
  /** Native Codex app-server reasoning effort, restored on reconnect. */
  codexEffort?: CodexEffort
}

/** Diff/terminal artifacts a tool-call frame carries (ACP ToolCallContent). */
export interface ToolArtifact {
  type: 'diff' | 'terminal' | 'content'
  path?: string
  oldText?: string
  newText?: string
  terminalId?: string
  text?: string
}

export interface AssistantTurn {
  kind: 'user' | 'assistant' | 'thought' | 'tool'
  text: string
  toolId?: string
  status?: string
  at?: number
  thinkMs?: number
  /** Tool-call artifacts (diffs, embedded terminals) for the disclosure card. */
  artifacts?: ToolArtifact[]
  /** User turns: the pre-turn working-tree checkpoint (turn-rail Restore). */
  checkpointId?: string
}

/** One ACP plan entry — the agent's own todo list (whole-array replace). */
export interface PlanEntry {
  content: string
  priority?: string
  status: 'pending' | 'in_progress' | 'completed' | string
}

export interface AssistantRuntime {
  turns: AssistantTurn[]
  first: boolean
  /** Turns evicted from the live window and preserved in the append-only
   * per-thread disk archive. Only explicit history paging hydrates them. */
  archivedTurns?: number
  /** Reset/provider changes mint a new epoch so a failed unlink can never make
   * old history reappear in the replacement conversation. */
  archiveEpoch?: string
  /** Durable idempotency token for a batch that has not been acknowledged.
   * While present, persistence keeps the entire live prefix. */
  archiveBatch?: { id: string; count: number }
  /** Main-process append currently in flight; deliberately not persisted. */
  archivePending?: boolean
  /** Streaming-only; stripped from durable persistence. */
  thinkStart?: number
  /** The agent's live plan (sessionUpdate:'plan'), replaced wholesale per frame. */
  plan?: PlanEntry[]
  /** The agent's REAL context window (ACP usage_update), when it reports one. */
  usage?: { used: number; size: number }
}

export type AssistantSpeed = 'default' | 'fast'

export interface AssistantMention {
  id: string
  kind: 'paper' | 'claim' | 'hypothesis' | 'run' | 'figure'
  label: string
  text: string
}

export interface AssistantDraft {
  text: string
  attachments: string[]
  mentions: AssistantMention[]
  speed: AssistantSpeed
}

export interface QueuedAssistantPrompt extends AssistantDraft {
  id: string
  queuedAt: number
}

export interface FileSessionTab {
  path: string
  mode: 'preview' | 'edit' | 'split'
  /** Zed-style preview tabs: an unpinned tab is transient — the next unpinned
   * open replaces it. Editing / double-click / save pins it. */
  pinned?: boolean
  /** 1-based cursor line, restored on relaunch (continue where you left off). */
  cursor?: number
}

/** One heading of the active file — the sidebar outline's rows. */
export interface OutlineItem {
  level: number
  text: string
  line: number
}

/** A captured quote: selection-first annotation with a round-trip anchor. */
export interface QuoteAnnotation {
  id: string
  workspace: string
  path: string
  quote: string
  color: string
  line: number
  at: string
}

/** A user terminal pane in the dock; `boot` runs once when the pty is ready. */
export interface TerminalSession {
  id: string
  boot?: string
  /** `boot` was (re)assigned while the pty may already be live (e.g. the default
   * terminal adopted as the Claude terminal). The Terminal component writes the
   * command once and clears this; never persisted. */
  bootPending?: boolean
  /** Persist `boot` and run it again when the app relaunches. */
  restart?: boolean
  /** Reopen one logical terminal instead of creating duplicates. */
  singletonKey?: string
  /** Start directory for this pty; defaults to the user's home folder. */
  cwd?: string
  /** Manual rename — always wins over the derived autoName. */
  name?: string
  /** Derived from the command being run; display fallback. */
  autoName?: string
  /** One-shot receipt that the detached broker handed this exact live PTY to
   * a new app instance. Persisted until the user has actually seen it. */
  continued?: TerminalContinuationStatus
}

export interface TerminalContinuationStatus {
  sameProcess: true
  at: number
  terminalPid?: number
  outputBytes?: number
}

/** A live terminal an ACP agent spawned — listed so you can watch/take over. */
export interface AgentTerminalSession {
  terminalId: string
  label?: string
  command?: string
  cwd?: string
  agentKey?: string
  agentName?: string
  scope?: string
}

/**
 * A non-terminal session card: the git commit panel or an embedded browser.
 * Panels live in the same dockGrid as threads/terminals — same drag, split,
 * close, pop story. `seq` bumps when something outside the card (a terminal
 * link) re-points its URL, so the webview navigates without a remount.
 */
export interface DockPanel {
  id: string
  kind: 'git' | 'browser' | 'ledger'
  url?: string
  /** Live page title (browser) — display only, refreshed on navigation. */
  title?: string
  seq?: number
}

/**
 * A user-added agent (Zed's agent_servers pattern): any CLI, either speaking
 * ACP over stdio (chat thread) or launched in a real terminal.
 */
export interface CustomAgent {
  id: string
  name: string
  kind: 'acp' | 'terminal'
  command: string
  args: string[]
}

/**
 * A Chrome-style tab group over sessions: a named, hue-tinted, collapsible
 * cluster in the rail. Members are session ids (threads/terminals/panels);
 * stale ids are pruned when persisted.
 */
export interface SessionGroup {
  id: string
  name: string
  collapsed?: boolean
  members: string[]
  /** One of GROUP_COLORS; unset = a stable hue derived from the name. */
  color?: string
}

/** Chrome's tab-group palette, muted for the glass shell. */
export const GROUP_COLORS = ['#8a8f98', '#4a7dbd', '#c25e5e', '#c2a24e', '#5f9e6e', '#b96a9c', '#8b6fc0', '#4e9ba8']

/** A recently closed session (⌘⇧T brings it back, Chrome-style). */
export interface ClosedSession {
  kind: 'term' | 'thread' | 'panel'
  at: number
  term?: TerminalSession
  thread?: AssistantThread
  runtime?: AssistantRuntime
  panel?: DockPanel
}

/**
 * A saved session profile (Warp's Tab Configs): one click reopens the same
 * agent/command in the same folder, optionally into a named group.
 */
export interface SessionTemplate {
  id: string
  name: string
  kind: 'terminal' | 'acp'
  agentKey?: string
  command?: string
  cwd?: string
  group?: string
}

/** A session living in its own git worktree (isolated from the main tree). */
export interface WorktreeSession {
  taskId: string
  path: string
  branch: string
  repo: string
}

/**
 * A point on the undo timeline. We snapshot the whole `Project` BEFORE a
 * trajectory-mutating action (approve a proposal, load/clear) so the human can
 * time-travel back. Session-scoped and capped — NOT persisted, so it adds zero
 * weight to the durable store and costs nothing (pure local, no model calls).
 */
export interface Checkpoint {
  id: string
  at: string
  label: string
  kind: 'approve' | 'project'
  snapshot: Project
}

export type AgentTaskStatus = 'queued' | 'running' | 'blocked' | 'ready' | 'applied' | 'rejected' | 'failed'

/**
 * A background agent run. The queue drains SEQUENTIALLY (one model call at a
 * time) so "run several agents" / best-of-N never fans out into parallel API
 * spend — cost stays bounded and predictable. Session-scoped, not persisted.
 */
export interface AgentTask {
  id: string
  agentId: AgentId
  label: string
  status: AgentTaskStatus
  at: string
  startedAt?: string
  completedAt?: string
  stage: TrajectoryStage
  provider?: string
  environment?: string
  blocker?: string
  /** Number of proposals this run produced. */
  resultCount?: number
  proposalIds?: ID[]
  /** Best-of-N grouping id — the same task attempted N times. */
  groupId?: string
}

/**
 * One step of a saved workflow: run a single agent, or all of a stage's agents,
 * optionally best-of-N (count>1). Steps enqueue onto the SAME sequential, cost-
 * bounded queue — a workflow never fans out into parallel API spend.
 */
export interface WorkflowStep {
  id: string
  kind: 'agent' | 'stage'
  ref: string // AgentId (kind:'agent') or TrajectoryStage (kind:'stage')
  count: number // best-of-N; 1 = a single run
}

/** A named, ordered automation. Runs manually, or auto-runs when you enter a stage. */
export interface Workflow {
  id: string
  name: string
  steps: WorkflowStep[]
  trigger: 'manual' | 'on-stage'
  /** For trigger:'on-stage' — which stage entry fires it. */
  stage?: TrajectoryStage
}

export type ToastKind = 'info' | 'success' | 'warn' | 'error'

/** Keeps drafts/user turns comfortably below the archive's byte-bounded
 * record size even for worst-case JSON escaping. Longer material belongs in
 * an attached file, which preserves it without pinning Chromium memory. */
export const ASSISTANT_DRAFT_TEXT_LIMIT = 1_000_000
const ASSISTANT_DRAFT_ATTACHMENT_LIMIT = 64
const ASSISTANT_DRAFT_MENTION_LIMIT = 64

const emptyAssistantDraft = (speed: AssistantSpeed = 'default'): AssistantDraft => ({
  text: '',
  attachments: [],
  mentions: [],
  speed,
})

const normalizeAssistantDraft = (draft?: Partial<AssistantDraft> | null): AssistantDraft => ({
  text: typeof draft?.text === 'string' ? draft.text.slice(0, ASSISTANT_DRAFT_TEXT_LIMIT) : '',
  attachments: Array.isArray(draft?.attachments)
    ? draft.attachments.filter((x): x is string => typeof x === 'string').slice(0, ASSISTANT_DRAFT_ATTACHMENT_LIMIT).map((path) => path.slice(0, 4096))
    : [],
  mentions: Array.isArray(draft?.mentions)
    ? draft.mentions.filter((m): m is AssistantMention =>
        !!m &&
        typeof m.id === 'string' &&
        ['paper', 'claim', 'hypothesis', 'run', 'figure'].includes((m as AssistantMention).kind) &&
        typeof m.label === 'string' &&
        typeof m.text === 'string',
      )
      .slice(0, ASSISTANT_DRAFT_MENTION_LIMIT)
      .map((mention) => ({ ...mention, id: mention.id.slice(0, 4000), label: mention.label.slice(0, 2000), text: mention.text.slice(0, 16_000) }))
    : [],
  // Legacy Balanced/Deep drafts migrate to the provider's normal speed. The
  // product surface intentionally exposes only Default and Fast.
  speed: draft?.speed === 'fast' ? 'fast' : 'default',
})

const assistantDraftIsEmpty = (draft: AssistantDraft) =>
  !draft.text && draft.attachments.length === 0 && draft.mentions.length === 0 && draft.speed === 'default'
/** An ephemeral notification — EVENTS (done/failed/ready), never ongoing work.
 *  Session-scoped (not persisted); the Activity feed is the persistent record. */
export interface Toast {
  id: string
  kind: ToastKind
  text: string
  at: string
}

function emptyManuscript(): Manuscript {
  return { id: uid('ms'), title: 'Untitled draft', sections: [], updatedAt: nowISO() }
}

export function emptyProject(): Project {
  const at = nowISO()
  return {
    id: uid('proj'),
    name: '',
    question: '',
    createdAt: at,
    updatedAt: at,
    corpus: [],
    claimGraph: { nodes: [], edges: [] },
    questions: [],
    campaign: null,
    hypotheses: [],
    experiments: [],
    attempts: [],
    runs: [],
    results: [],
    figures: [],
    manuscript: emptyManuscript(),
    reviews: [],
    proposals: [],
    activity: [],
  }
}

function defaultCampaign(project: Project): ResearchCampaign {
  const at = nowISO()
  return {
    id: uid('campaign'),
    title: `${project.name || 'Research'} campaign`,
    objective: project.question || 'Define the research objective.',
    evaluator: {
      metric: 'success_rate',
      direction: 'maximize',
      unit: '%',
    },
    budget: {
      maxAttempts: 8,
      maxMinutesPerAttempt: 10,
      compute: 'local',
    },
    runCommand: 'python experiment.py',
    editablePaths: ['src/**', 'experiments/**'],
    allowedCommands: ['python', 'python3', 'pytest'],
    requiredEvidence: ['Metric output', 'Run log', 'Reproducible command'],
    stopConditions: ['Budget exhausted', 'Target reached', 'No improvement after 3 attempts'],
    status: 'draft',
    createdAt: at,
    updatedAt: at,
  }
}

function commandAllowed(command: string, allowedCommands: string[]): boolean {
  const executable = command.trim().split(/\s+/)[0] ?? ''
  return allowedCommands.some((allowed) => executable === allowed || executable.startsWith(`${allowed}/`))
}

function parseMetric(text: string, metric: string, unit?: string): number | undefined {
  const escaped = metric.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = text.match(new RegExp(`${escaped}\\s*[:=]\\s*(-?\\d+(?:\\.\\d+)?)`, 'i'))
  if (!match) return undefined
  const raw = Number(match[1])
  if (!Number.isFinite(raw)) return undefined
  return unit === '%' && raw <= 1 ? raw * 100 : raw
}

function updateTaskForProposal(tasks: AgentTask[], proposal: Proposal, status: AgentTaskStatus): AgentTask[] {
  if (!proposal.taskId) return tasks
  return tasks.map((task) => (task.id === proposal.taskId ? { ...task, status, completedAt: nowISO() } : task))
}

function provenanceKey(link: ProvenanceLink): string {
  if (link.kind === 'citation') return `citation:${link.sourceId}:${link.locator ?? ''}:${link.quote ?? ''}`
  if (link.kind === 'result') return `result:${link.resultId}:${link.runId}:${link.summary ?? ''}`
  if (link.kind === 'dataset') return `dataset:${link.sourceId}:${link.license ?? ''}`
  if (link.kind === 'note') return `note:${link.sourceId ?? ''}:${link.text ?? ''}`
  return `derivation:${link.text}`
}

/**
 * PROJECT TABS — each open tab is its own workspace + session set. The ACTIVE
 * tab's slice IS the live flat fields; every OTHER tab is parked in
 * `projectSlices`. The three key-buckets below drive persistence and switching:
 *  - PERSIST  = per-project fields written to disk (bucket A).
 *  - MEMORY   = PERSIST + per-project in-memory-only fields swapped on switch
 *               (bucket A + D); seeded empty on a cold restore.
 *  - GLOBAL   = shared by all tabs, persisted once (bucket B + C).
 * Anything NOT in these lists is GLOBAL-transient (bucket E, never swapped) or a
 * reset-on-switch ephemeral cursor (bucket F, rebuilt) — see `resetEphemeralCursors`.
 */
export const PROJECT_SLICE_PERSIST_KEYS = [
  'project', 'stage', 'layoutMode', 'workspacePath', 'autonomy', 'agentPreset', 'claudeAccountId', 'fileTabs', 'openFilePath',
  'repoCheckpoints', 'followAgent', 'annotations', 'assistantThreads', 'assistantRuntimes',
  'assistantDrafts', 'assistantPromptQueues',
  'activeThreadId', 'terminals', 'panels', 'sessionGroups', 'pinnedSessions', 'worktreeSessions',
  'latexMode', 'dockGrid', 'dockViews', 'dockColWeights', 'canvasWidth', 'canvasOpen', 'dockOpen',
] as const

export const PROJECT_SLICE_MEMORY_KEYS = [
  ...PROJECT_SLICE_PERSIST_KEYS,
  'agentFeed', 'needsYou', 'closedStack', 'pendingPermissions', 'agentTerminals', 'agentRunning',
  'agentQueueRunning', 'agentTasks', 'latexDismissed', 'checkpoints',
] as const

/** Terminal surface tone — 'paper' is the light "more white" look, independent
 * of the app theme. Keep the color math in Terminal.tsx + tokens.css in sync. */
export type TermBackground = 'ink' | 'slate' | 'paper'

/** A named Claude subscription: an isolated CLAUDE_CONFIG_DIR the Claude CLI
 * runs under. Projects bind to one by id (''= the default ~/.claude), so two
 * project tabs can run two different subscriptions side by side. */
export interface ClaudeAccount {
  id: string
  label: string
  /** Absolute (or ~-prefixed) CLAUDE_CONFIG_DIR for this subscription. */
  configDir: string
  /** Signed-in email, refreshed from <configDir>/.claude.json when shown. */
  email?: string
}

/** Render a config dir for a shell line: `~/x` becomes "$HOME/x" (the CLI does
 * NOT expand a literal ~ arriving via an env var), anything else is
 * single-quoted verbatim. */
export const shellConfigDir = (dir: string): string =>
  dir.startsWith('~/')
    ? `"$HOME/${dir.slice(2).replace(/(["\\$`])/g, '\\$1')}"`
    : `'${dir.replace(/'/g, `'\\''`)}'`

const GLOBAL_KEYS = [
  'theme', 'themeMode', 'agentModels', 'fileTextZoom', 'termFontSize', 'termFontFamily',
  'termFontWeight', 'termCursorColor', 'termBackground', 'customAgents', 'enabledAgents', 'sessionTemplates', 'claudeModel', 'reasoningProvider',
  'localBaseUrl', 'localModel', 'openaiBaseUrl', 'openaiModel', 'openAlexMailto', 'grobidEndpoint',
  'sandboxMode', 'workflows', 'automationsEnabled', 'perfMode', 'tabLayout', 'railWidth', 'railOpen', 'claudeSessions',
  'wordDiffs', 'showCosts', 'inbox', 'draftRestore', 'wallpaperTint', 'claudeAccounts',
  'claudeTerminalModel', 'claudeFastMode',
  'permissionRules', 'sensitiveGlobs', 'latexMain', 'unsavedBuffers', 'termDrafts', 'onboardingVersion',
] as const

type ProjectSlicePersist = Pick<KaisolaState, (typeof PROJECT_SLICE_PERSIST_KEYS)[number]>
export type ProjectSliceMemory = Pick<KaisolaState, (typeof PROJECT_SLICE_MEMORY_KEYS)[number]>

/** One project tab in the strip — a lightweight label over its (parked or live) slice. */
export interface ProjectTab {
  id: string                    // uid('proj') — globally unique; also the pty-id namespace seed
  workspacePath: string | null  // mirror of the slice's workspacePath (label a tab WITHOUT hydrating it)
  title?: string                // manual rename; else folder basename
  hue: string                   // folderHue(workspacePath ?? id) — identity accent
  color?: string                // optional manual accent (GROUP_COLORS)
  createdAt: number
  /** Rolled-up background badge; cleared when the tab becomes active. */
  activity?: 'running' | 'completed' | 'needs-you' | 'failed'
}
/** A closed project on the undo stack (⌘⌥T reopens); in-memory, cap 8. */
export interface ClosedProject {
  at: number
  tab: ProjectTab
  slice: ProjectSlicePersist
}
/** The renderer-to-renderer payload for moving one project between OS windows.
 * `globals` is a sanitized persisted projection: a pristine tear-off needs the
 * same appearance/settings, while an existing receiver keeps its own shell. */
export interface ProjectTransferPayload {
  tab: ProjectTab
  slice: ClosedProject['slice']
  globals?: Record<string, unknown>
  popped?: string[]
  transferId?: string
  beforeId?: string
  dropX?: number
}
/** A recently opened folder (the + menu); persisted, cap 12. */
export interface RecentProject {
  path: string
  name: string
  at: number
}

interface KaisolaState {
  project: Project

  // ── navigation / ui ──
  stage: TrajectoryStage
  theme: Theme
  /** What the user CHOSE — 'system' resolves `theme` from the OS appearance. */
  themeMode: ThemeMode
  /** Focus = research-first canvas; Studio preserves the original multi-card IDE. */
  layoutMode: LayoutMode
  autonomy: AutonomyLevel
  /** Width of the agent sidebar, in px (drag-resizable). */
  /** Which edge the agent sidebar (nav + sessions + review) hangs on. */
  paletteOpen: boolean
  /** Which surface the palette shows: commands (⌘K) or the file finder (⌘P). */
  paletteMode: PaletteMode
  selection: Selection | null
  provenance: ProvenanceTarget | null
  /** The proposal currently open in the centered review surface, if any. */
  focusedProposalId: string | null
  /** Undo timeline — pre-mutation project snapshots (session-scoped, capped). */
  checkpoints: Checkpoint[]
  /** Background agent task queue (the inbox). Session-scoped, not persisted. */
  agentTasks: AgentTask[]
  /** Whether the sequential queue worker is currently draining. */
  agentQueueRunning: boolean
  /** Saved automations — configured in Settings, run from the palette. Persisted. */
  workflows: Workflow[]

  // ── session cards (chat threads + terminals); the list lives in the rail ──
  /** Whether any session cards are shown (⌘J hides them, full-width canvas). */
  dockOpen: boolean
  /**
   * The open session cards as COLUMNS (left → right), each a top → bottom
   * stack of thread/terminal ids — drag a card's head onto another card's
   * edge to re-place it anywhere in the work area.
   */
  dockGrid: string[][]
  /** Flat mirror of dockGrid — derived, never set directly. */
  dockViews: string[]
  /** Width of the files/canvas card in px; null = share space automatically. */
  canvasWidth: number | null
  /** Relative widths of the session-grid columns (fr units); null = equal.
   * Self-heals: ignored whenever its length no longer matches the grid. */
  dockColWeights: number[] | null
  /** Whether the main view (files/canvas) shows; false = only session cards. */
  canvasOpen: boolean
  /** User terminals (each may boot a command, e.g. `codex login`). */
  terminals: TerminalSession[]
  /** Live terminals an ACP agent spawned while working. */
  agentTerminals: AgentTerminalSession[]
  /** Non-terminal session cards: the git commit panel, embedded browsers. */
  panels: DockPanel[]
  /** User-added agents (ACP or terminal) — merged into every agent menu. */
  customAgents: CustomAgent[]
  /** Which BUILT-IN presets show in the + menu (the registry's "added" set). */
  enabledAgents: string[]
  /** Chrome-style tab groups over sessions (rail clusters). */
  sessionGroups: SessionGroup[]
  /** Pinned session ids — top of the rail, close hidden (Chrome pinned tabs). */
  pinnedSessions: string[]
  /** Recently closed sessions, newest first (⌘⇧T reopens; term ptys get a 60s grace). */
  closedStack: ClosedSession[]
  /** Sessions waiting on the human: permission pending or turn finished unseen. */
  needsYou: Record<string, true>
  /** keymap.json overrides: chord → action id (null disables a default). */
  keymapOverrides: Record<string, string | null>
  /** The ⌘L bar (explicit actions — no shell-vs-prompt auto-detection). */
  omniOpen: boolean
  /** A prompt injected into a thread from outside the composer (the ⌘L bar). */
  omniPrompt: { seq: number; threadId: string; text: string } | null
  /** Saved session profiles (Warp Tab Configs) — the + menu lists them. */
  sessionTemplates: SessionTemplate[]
  /** session id → its git worktree (isolated checkout under the repo). */
  worktreeSessions: Record<string, WorktreeSession>
  /** LaTeX mode: the shell leans into paper-writing (build bar, PDF inspection). */
  latexMode: boolean
  /** User closed the bar this session — auto-detect stays quiet until the
   * workspace changes or they re-enter manually. Never persisted. */
  latexDismissed: boolean
  /** Per-workspace main .tex file (what latexmk builds). */
  latexMain: Record<string, string>
  /** Unsent composer text per AGENT terminal id — reconstructed from
   *  keystrokes (the real text lives inside the CLI process), persisted so a
   *  restart can retype it into the resumed agent. */
  termDrafts: Record<string, string>
  /** Live identity per terminal id (session-scoped, never persisted). */
  terminalMeta: Record<string, TerminalMeta>
  /** Bumped when a pop-out window returns a terminal — forces the xterm to
   * remount so it re-attaches (re-points the pty stream) and replays output. */
  termRemounts: Record<string, number>
  settingsOpen: boolean
  /** A section the opener wants focused ('agents' from the rail's Add agents…). */
  settingsPane: string | null
  /** The in-app device-code sign-in card, if open. */
  signIn: { key: string; name: string; command: string; args: string[] } | null
  /** Assistant chat threads — listed as sessions in the sidebar. */
  assistantThreads: AssistantThread[]
  /** Durable per-thread chat turns. */
  assistantRuntimes: Record<string, AssistantRuntime>
  /** Durable composer state per assistant thread. */
  assistantDrafts: Record<string, AssistantDraft>
  /** Prompts accepted while a thread is busy; coalesced into the next turn. */
  assistantPromptQueues: Record<string, QueuedAssistantPrompt[]>
  /** Which assistant thread is currently shown. */
  activeThreadId: string
  /** Which ACP agent preset to connect (the registry choice). */
  agentPreset: string
  /** Which domain agents are currently running (transient, for spinners). */
  agentRunning: Partial<Record<AgentId, boolean>>
  /** Per-agent model override (role → model id). Empty = use the default. */
  agentModels: Partial<Record<AgentId, string>>
  /** The folder agents work in (their session cwd). */
  workspacePath: string | null
  /** Ask the Files editor to open a file (set by the workspace tree in the rail). */
  fileRequest: { path: string; mode?: 'preview' | 'edit'; pinned?: boolean; seq: number } | null
  /** The file the editor actually has open (drives the tree highlight). */
  openFilePath: string | null
  /** Whether the open file has unsaved edits (the rail asks before discarding). */
  fileDirty: boolean
  /** Open file tabs restored on launch; file contents are read from disk. */
  fileTabs: FileSessionTab[]
  /** Text zoom inside the Files viewer, driven by pinch gestures. */
  fileTextZoom: number
  /** Terminal font size (⌘+/⌘−/⌘0, persisted; applies to every terminal). */
  /** Appearance energy: 'glass' live translucency · 'eco' solid and still. */
  perfMode: PerfMode
  /** Visual relationship between project tabs and their child sessions. */
  tabLayout: TabLayout
  setTabLayout: (layout: TabLayout) => void
  /** Zero only for a genuinely fresh install; migrations mark existing users done. */
  onboardingVersion: number
  /** Width of the left workspace rail in px (null = the CSS default). */
  railWidth: number | null
  /** Left workspace rail visibility — the strip button / ⌘B (persisted). */
  railOpen: boolean
  /** Last Claude Code session id per workspace (from the hooks tap) — the
   * auto-launch resumes it (`claude --resume`) so a restart lands you back
   * in the same conversation. Persisted; capped. */
  claudeSessions: Record<string, string>
  /** Named Claude subscriptions — each an isolated CLAUDE_CONFIG_DIR. The
   * implicit default account (~/.claude) is NOT listed here. Persisted. */
  claudeAccounts: ClaudeAccount[]
  /** This project's Claude account id ('' = default ~/.claude). Project-scoped
   * + persisted: the Claude session in one project tab never runs under
   * another tab's subscription. */
  claudeAccountId: string
  termFontSize: number
  /** Terminal typeface — a curated mono list in Settings (persisted). */
  termFontFamily: string
  /** Terminal text weight: 400 / 500 / 700 (persisted). */
  termFontWeight: number
  /** Terminal cursor color: 'auto' follows the terminal text color, otherwise
   * a hex value ('#95a456' restores the accent look). Persisted. */
  termCursorColor: string
  /** Terminal surface tone: ink (near-black) / slate / paper (white). Persisted. */
  termBackground: TermBackground
  /** Working-tree checkpoints (newest first) — hidden-ref git commits taken
   * before each Claude turn and on demand. Scoped to workspacePath. */
  repoCheckpoints: RepoCheckpoint[]
  /** Live agent activity (hook events + tool calls), newest first, capped. */
  agentFeed: AgentFeedItem[]
  /** Follow the agent: auto-open files it touches as transient previews. */
  followAgent: boolean
  /** Agent permission requests awaiting the human (inline cards). */
  pendingPermissions: AcpPermissionRequest[]
  /** Persisted allow-rules (per workspace) — auto-answer matching asks. */
  permissionRules: PermissionRule[]
  /** Sensitive-file globs (Zed's guardrail pattern): agents can't read/write
   * matches, permission rules never auto-allow them. Persisted, editable. */
  sensitiveGlobs: string[]
  /** Unsaved buffer text per path — survives quit (session continuity). */
  unsavedBuffers: Record<string, string>
  /** Headings of the active file (drives the sidebar outline). */
  outline: OutlineItem[]
  /** 1-based cursor line in the active editor (outline follow, blame). */
  editorCursorLine: number | null
  /** Ask the active editor to scroll to a line (outline/quote jumps).
   * `heading` = index into the outline, for the rendered-preview surface. */
  scrollRequest: { path: string; line: number; heading?: number; seq: number } | null
  /** Captured quotes (per workspace, persisted). */
  annotations: QuoteAnnotation[]
  /** Selected Claude model for direct API calls. */
  claudeModel: string
  /**
   * Where domain-agent reasoning runs. 'codex' = `codex exec` on your ChatGPT/
   * Codex subscription (no per-token key); 'openai' = the OpenAI API (cheap mini
   * models, key in the keychain); 'local' = a free local OpenAI-compatible model;
   * 'agent' = a connected ACP terminal agent; 'anthropic' = the paid Claude API.
   */
  reasoningProvider: 'codex' | 'openai' | 'local' | 'agent' | 'anthropic'
  /** OpenAI-compatible base URL for the local model. */
  localBaseUrl: string
  /** Local model name (e.g. 'llama3.1', 'qwen2.5'). */
  localModel: string
  /** Base URL for the hosted OpenAI API (overridable for Azure/proxies). */
  openaiBaseUrl: string
  /** OpenAI model for the agents (a cheap one, e.g. 'gpt-4o-mini'). */
  openaiModel: string
  /** Optional email for OpenAlex's free "polite pool" (higher rate limit). */
  openAlexMailto: string
  /** GROBID REST endpoint (e.g. http://localhost:8070). Empty = PDF ingestion off. */
  grobidEndpoint: string
  /** Where agent experiments execute: a dry-run mock, local Docker, or E2B cloud. */
  sandboxMode: 'mock' | 'docker' | 'e2b'

  // ── project tabs (Chrome-style: each tab is its own workspace + session set) ──
  /** Open project tabs, left→right (drives the strip). */
  projectTabs: ProjectTab[]
  /** The tab whose slice IS the live flat fields (single source of truth). */
  activeProjectId: string
  /** Parked slices for every tab EXCEPT the active one. */
  projectSlices: Record<string, ProjectSliceMemory>
  /** Recently closed projects, newest first (⌘⌥T reopens); in-memory, cap 8. */
  closedProjectStack: ClosedProject[]
  /** Recently opened folders (the + menu); persisted, cap 12. */
  recentProjects: RecentProject[]
  /** ACP agentKey → owning projectId, so a background agent's events route home. */
  agentProjectMap: Record<string, string>

  setStage: (s: TrajectoryStage) => void
  toggleTheme: () => void
  setTheme: (t: Theme) => void
  /** Apply a theme broadcast from another window (no re-broadcast). */
  followTheme: (t: ThemeMode) => void
  /** Pick light / dark / follow-the-OS. Explicit picks override system mode. */
  setThemeMode: (m: ThemeMode) => void
  /** Re-resolve the effective theme from the OS (system mode only). */
  applySystemTheme: () => void
  setLayoutMode: (mode: LayoutMode) => void
  toggleLayoutMode: () => void
  setAutonomy: (a: AutonomyLevel) => void
  completeOnboarding: () => void
  openPalette: (mode?: PaletteMode) => void
  closePalette: () => void
  togglePalette: (mode?: PaletteMode) => void
  select: (sel: Selection | null) => void
  showProvenance: (t: ProvenanceTarget) => void
  hideProvenance: () => void
  focusProposal: (id: string | null) => void
  toggleDock: () => void
  setDock: (open: boolean, tab?: 'terminal' | 'assistant') => void
  /** Show a session's card — opens it beside the current ones if not already up. */
  setDockView: (id: string) => void
  /** Open a session as a new card beside the current ones. */
  addDockSplit: (id: string) => void
  removeDockView: (id: string) => void
  /** Re-place a card relative to another card's edge (drag-and-drop). */
  placeDockView: (id: string, targetId: string, edge: 'left' | 'right' | 'top' | 'bottom') => void
  setCanvasWidth: (w: number | null) => void
  setRailWidth: (w: number | null) => void
  setClaudeSession: (workspace: string, sessionId: string) => void
  setClaudeAccountId: (id: string) => void
  addClaudeAccount: (label: string, configDir: string) => void
  removeClaudeAccount: (id: string) => void
  setClaudeAccountEmail: (id: string, email: string | undefined) => void
  /** (Re)launch the Claude terminal for the ACTIVE project under its bound
   * account — the auto-launch and Settings' "apply account now" both use it.
   * `expect` aborts if the active project/workspace moved during the probes. */
  launchClaude: (opts?: { reveal?: boolean; expect?: { pid: string; ws: string } }) => Promise<boolean>
  setDockColWeights: (weights: number[] | null) => void
  /** Minimize/restore the main view — when minimized the work row is all cards. */
  toggleCanvas: () => void
  requestTerminal: (command?: string, opts?: { cwd?: string; name?: string; singletonKey?: string; restart?: boolean; reveal?: boolean; rerun?: boolean }) => void
  clearBootPending: (id: string) => void
  /** Persist/clear the one-shot same-process continuation receipt. */
  setTerminalContinuation: (id: string, status?: TerminalContinuationStatus, projectId?: string) => void
  closeTerminal: (id: string) => void
  renameTerminal: (id: string, name?: string) => void
  /** Auto-title a terminal from the command it's running (manual name wins). */
  addAgentTerminal: (t: AgentTerminalSession) => void
  closeAgentTerminal: (terminalId: string) => void
  setTerminalMeta: (id: string, patch: TerminalMeta) => void
  /** Persist the exact CLI-agent resume command used after restarts/updates. */
  setTerminalResume: (id: string, boot: string) => void
  setTermDraft: (id: string, text: string) => void
  popOutTerminal: (id: string, title?: string, hue?: string) => void
  restorePoppedTerminal: (id: string) => void
  /** Open (or focus) the git commit panel card — one per window. */
  openGitPanel: () => void
  openLedgerPanel: () => void
  /** Open a browser card; same-origin URLs re-point the existing card. */
  openBrowserPanel: (url?: string) => void
  closePanel: (id: string) => void
  setPanelState: (id: string, patch: Partial<Pick<DockPanel, 'url' | 'title'>>) => void
  addCustomAgent: (agent: CustomAgent) => void
  removeCustomAgent: (id: string) => void
  /** Add/remove a built-in preset from the + menu (the registry toggle). */
  toggleAgentEnabled: (id: string) => void
  /** Chrome-style tab groups over sessions. */
  createSessionGroup: (name: string, members: string[]) => void
  renameSessionGroup: (id: string, name: string) => void
  toggleSessionGroupCollapsed: (id: string) => void
  /** Move a session into a group (null = ungroup). A session lives in ≤1 group. */
  assignToGroup: (sessionId: string, groupId: string | null) => void
  /** Dissolve a group — its sessions stay. */
  removeSessionGroup: (id: string) => void
  /** Chrome-style tab switch: show `id` where the first card is (splits kept). */
  switchSession: (id: string) => void
  /** Ctrl+Tab / Ctrl+Shift+Tab — cycle the focused card through sessions. */
  cycleSession: (dir: 1 | -1) => void
  togglePinSession: (id: string) => void
  setSessionGroupColor: (id: string, color?: string) => void
  /** Flag a session as waiting on the human (amber dot; cleared on view). */
  markNeedsYou: (id: string, projectId?: string) => void
  /** ⌘⇧T — restore the most recently closed session. */
  reopenClosedSession: () => void
  setOmniOpen: (open: boolean) => void
  setKeymapOverrides: (map: Record<string, string | null>) => void
  /** Send `text` to a thread as if typed in its composer (Assistant delivers). */
  sendOmniPrompt: (threadId: string, text: string) => void
  clearOmniPrompt: () => void
  saveSessionTemplate: (sessionId: string) => void
  removeSessionTemplate: (id: string) => void
  openSessionTemplate: (id: string) => void
  /** Open an agent in a FRESH git worktree of the workspace repo. */
  newWorktreeSession: (agentId?: string) => Promise<void>
  /** Commit the worktree's changes and merge its branch back into the repo. */
  mergeWorktreeSession: (sessionId: string) => Promise<void>
  /** Delete the worktree + branch and close its session. */
  removeWorktreeSession: (sessionId: string) => Promise<void>
  setLatexMode: (on: boolean) => void
  setLatexMain: (workspace: string, path: string | null) => void
  openSignIn: (payload: { key: string; name: string; command: string; args: string[] }) => void
  closeSignIn: () => void
  requestNewThread: (agentKey?: string) => void
  setActiveThread: (id: string) => void
  closeAssistantThread: (id: string) => void
  renameAssistantThread: (id: string, name?: string) => void
  /** Auto-title a thread from its first message's topic (manual name wins). */
  autoNameThread: (id: string, text: string, projectId?: string) => void
  setAssistantThreadAgent: (id: string, agentKey: string) => void
  setThreadAcpSession: (id: string, sessionId: string | undefined, projectId?: string) => void
  setThreadClaudeEffort: (id: string, effort: ClaudeEffort, projectId?: string) => void
  setThreadCodexEffort: (id: string, effort: CodexEffort, projectId?: string) => void
  updateAssistantRuntime: (id: string, fn: (runtime: AssistantRuntime) => AssistantRuntime, projectId?: string) => void
  resetAssistantRuntime: (id: string, projectId?: string) => void
  setAssistantDraft: (id: string, patch: Partial<AssistantDraft>, projectId?: string) => void
  clearAssistantDraft: (id: string, opts?: { keepSpeed?: boolean }, projectId?: string) => void
  enqueueAssistantPrompt: (id: string, prompt: AssistantDraft, opts?: { front?: boolean }, projectId?: string) => string
  dequeueAssistantPrompt: (id: string, projectId?: string) => QueuedAssistantPrompt | undefined
  /** Atomically remove every prompt waiting for a thread. The renderer merges
   * the returned batch into one ordered next turn. */
  takeAssistantPromptQueue: (id: string, projectId?: string) => QueuedAssistantPrompt[]
  removeQueuedAssistantPrompt: (id: string, promptId: string) => void
  reorderAssistantThreads: (srcId: string, destId: string) => void
  setThreadBusy: (id: string, busy: boolean, projectId?: string) => void
  /** `pane` deep-links a Settings section (e.g. 'agents') — cleared on close. */
  setSettingsOpen: (open: boolean, pane?: string) => void
  setAgentPreset: (id: string) => void
  setWorkspace: (path: string | null) => void
  requestFile: (path: string, mode?: 'preview' | 'edit', opts?: { pinned?: boolean }) => void
  setOpenFile: (path: string | null) => void
  setFileDirty: (dirty: boolean) => void
  setFileSession: (tabs: FileSessionTab[], activePath: string | null) => void
  setFileTextZoom: (zoom: number) => void
  setPerfMode: (mode: PerfMode) => void
  setTermFontSize: (size: number | null) => void
  setTermFontFamily: (family: string) => void
  setTermFontWeight: (weight: number) => void
  setTermCursorColor: (color: string) => void
  setTermBackground: (bg: TermBackground) => void
  toggleRail: () => void
  snapshotWorkspace: (label: string, projectId?: string) => Promise<RepoCheckpoint | null>
  restoreRepoCheckpoint: (id: string) => Promise<void>
  pushAgentFeed: (item: Omit<AgentFeedItem, 'id'>) => void
  toggleFollowAgent: () => void
  receivePermission: (req: AcpPermissionRequest) => void
  pushPermission: (req: AcpPermissionRequest) => void
  answerPermission: (permId: string, answer: { optionId?: string; decision?: 'allow' | 'reject' }, opts?: { cascadeReject?: boolean }) => void
  /** UI-only: drop a card main already resolved itself (timeout / agent death). */
  dismissPermission: (permId: string) => void
  alwaysAllowPermission: (permId: string) => void
  removePermissionRule: (id: string) => void
  setSensitiveGlobs: (globs: string[]) => void
  setUnsavedBuffer: (path: string, value: string | null) => void
  setOutline: (items: OutlineItem[]) => void
  setEditorCursorLine: (line: number | null) => void
  requestScroll: (path: string, line: number, heading?: number) => void
  addAnnotation: (a: Omit<QuoteAnnotation, 'id' | 'at' | 'workspace'>) => void
  removeAnnotation: (id: string) => void
  setClaudeModel: (id: string) => void

  // ── corpus ingest (post a link → an agent observes it) ──
  addPaperByUrl: (url: string) => Promise<void>

  // ── proposal lifecycle (the gate) ──
  approveProposal: (id: string) => void
  /** Approve keeping only some hunks (changeId → kept hunk indexes); status 'edited'. */
  approveProposalPartial: (id: string, keep: Record<string, number[]>) => void
  rejectProposal: (id: string) => void
  /** Best-of-N: approve one competing proposal and reject its siblings. */
  pickWinner: (winnerId: string) => void
  /** Deterministically merge competing research diffs into another review option. */
  synthesizeProposals: (proposalIds: string[]) => void
  /** Build a file-patch Proposal from a coding agent's isolated worktree diff. */
  createWorktreeProposal: (args: {
    taskId: string
    branch: string
    repo: string
    agentId: AgentId
    patch: string
    files: { path: string; additions: number; deletions: number }[]
  }) => void
  /** Approve a coding patch: merge its worktree branch back, then clean up. */
  mergeWorktreeProposal: (id: string) => Promise<void>
  /** The REVIEWED path for a worktree session: commit its work, turn the diff
   * into a file-patch Proposal, and open it in the review overlay — approve
   * there to merge. (The context menu's direct merge stays for trusted work.) */
  proposeWorktreeSession: (sessionId: string) => Promise<void>
  /** An agent used a human-gated MCP write tool → a pending Proposal here. */
  receiveMcpProposal: (ev: McpProposalEvent) => void

  // ── undo timeline (the checkpoint over the gate) ──
  /** Revert the project to a checkpoint, dropping it and everything newer. */
  restoreCheckpoint: (id: string) => void
  /** Revert to the most recent checkpoint. */
  undoLast: () => void

  // ── agent activity / decision receipts ──
  pushActivity: (agentId: AgentId, text: string, proposalId?: string) => void
  /** Run a domain agent; resolves with the ids of the proposals it produced.
   * `pid` pins every write to its origin project (default: the active one). */
  runAgent: (agentId: AgentId, instruction?: string, pid?: string) => Promise<string[]>
  /** Supervisor: run the right agents for a stage, in order (defaults to current). */
  runStageAgents: (stage?: TrajectoryStage) => Promise<void>
  /** Enqueue background run(s) of an agent. count>1 = best-of-N (N× cost, opt-in). */
  enqueueAgent: (agentId: AgentId, opts?: { count?: number; instruction?: string }) => void
  /** Enqueue the supervisor's agents for a stage as background tasks. */
  enqueueStageAgents: (stage?: TrajectoryStage, opts?: { count?: number }) => void
  /** Internal: drain the queue one task at a time (sequential → bounded cost). */
  drainAgentQueue: () => Promise<void>
  /** Remove resolved lifecycle tasks from the inbox. */
  clearAgentTasks: () => void
  /** Force-clear the queue + worker — the escape hatch for a wedged drain. */
  resetQueue: () => void

  // ── toasts (ephemeral event notifications, session-scoped) ──
  toasts: Toast[]
  pushToast: (kind: ToastKind, text: string) => void
  dismissToast: (id: string) => void

  // ── workflows / automation ──
  /** Master switch for on-stage auto-run. OFF by default (no surprise spend). */
  automationsEnabled: boolean
  setAutomationsEnabled: (on: boolean) => void

  // ── Interface switches (Settings → Interface; all persisted, default ON) ──
  /** Word-level highlights inside ResearchDiff rows. */
  wordDiffs: boolean
  setWordDiffs: (on: boolean) => void
  /** $-cost chips on Claude session tabs. */
  showCosts: boolean
  setShowCosts: (on: boolean) => void
  /** The cross-project needs-you inbox in the tab strip. */
  inbox: boolean
  setInbox: (on: boolean) => void
  /** Auto-retype saved CLI drafts after a resumed restart. */
  draftRestore: boolean
  setDraftRestore: (on: boolean) => void
  /** Wallpaper-sampled retinting of the chrome veils. */
  wallpaperTint: boolean
  setWallpaperTint: (on: boolean) => void
  /** Model alias the prepared Claude terminal boots with ('default' = CLI's own). */
  claudeTerminalModel: string
  setClaudeTerminalModel: (m: string) => void
  /** Fast mode (Opus ↯, premium pricing) for the prepared Claude terminal. */
  claudeFastMode: boolean
  setClaudeFastMode: (on: boolean) => void
  addWorkflow: (name?: string) => void
  deleteWorkflow: (id: string) => void
  setWorkflowTrigger: (id: string, trigger: 'manual' | 'on-stage', stage?: TrajectoryStage) => void
  addWorkflowStep: (id: string) => void
  updateWorkflowStep: (wfId: string, stepId: string, patch: Partial<WorkflowStep>) => void
  /** Enqueue every step of a workflow onto the (sequential, cost-bounded) queue. */
  runWorkflow: (id: string) => void
  /** Set / clear a per-agent model override (empty string clears). */
  setAgentModel: (agentId: AgentId, model: string) => void
  setReasoningProvider: (p: 'codex' | 'openai' | 'local' | 'agent' | 'anthropic') => void
  setLocalBaseUrl: (url: string) => void
  setLocalModel: (model: string) => void
  setOpenaiBaseUrl: (url: string) => void
  setOpenaiModel: (model: string) => void
  /** Verify every cited quote against its source; flips `verified` + recomputes trust. */
  verifyCitations: () => Promise<void>
  /** Resolve corpus papers in OpenAlex and populate the in-corpus citation graph. */
  buildCitationGraph: () => Promise<void>
  setOpenAlexMailto: (email: string) => void
  setGrobidEndpoint: (url: string) => void
  /** Ingest a paper's PDF via GROBID → full text + pin citations to PDF rectangles.
   * `pid` pins the write to its origin project (default: the active one). */
  ingestPaperPdf: (paperId: string, pid?: string) => Promise<void>
  /** Ingest every corpus paper that has a PDF. */
  ingestAllPdfs: () => Promise<void>
  setSandboxMode: (mode: 'mock' | 'docker' | 'e2b') => void
  /** Update the program.md-style campaign contract. */
  updateCampaign: (patch: Partial<ResearchCampaign>) => void
  /** Promote/reject a completed attempt at the human gate. */
  promoteAttempt: (attemptId: string) => void
  rejectAttempt: (attemptId: string) => void
  /** Approve compute for an experiment plan (the compute gate). */
  approveCompute: (planId: string) => void
  /** Run an experiment in the sandbox (gated by autonomy + computeApproved). */
  runExperiment: (planId: string) => Promise<void>

  // ── project lifecycle ──
  loadDemo: () => void
  clearProject: () => void

  // ── project tabs ──
  /** Park the active tab, append a fresh tab, push its folder to recents, switch. */
  newProject: (opts?: { path?: string | null; focus?: boolean }) => string
  /** Dedupe to an existing same-path tab (Chrome focus-existing), else a new tab. */
  openProjectFolder: (path: string) => void
  /** Park the outgoing slice, hoist the incoming one — one set(), one commit (§6.1). */
  switchProject: (id: string) => void
  /** Cycle the active tab within `projectTabs` order (wraps). */
  cycleProject: (dir: 1 | -1) => void
  reorderProjects: (srcId: string, destId: string) => void
  renameProjectTab: (id: string, title?: string) => void
  setProjectColor: (id: string, color?: string) => void
  /** Set a tab's background badge — no-op if it is the active tab. */
  setProjectActivity: (id: string, badge?: ProjectTab['activity']) => void
  /** Close a tab (running-work confirm, 60s pty grace, last-tab → fresh empty). */
  closeProject: (id: string, opts?: { force?: boolean }) => void
  /** ⌘⌥T — reopen the most recently closed project (cancels its pending pty kills). */
  /** No arg = most recent; a tab id targets that specific closed entry. */
  reopenClosedProject: (tabId?: string) => void
  /** Move a tab to the window under the drop point, or tear it into a new one. */
  detachProjectToWindow: (id: string, at?: { x: number; y: number }) => Promise<void>
  /** The receiving side of a window transfer. True acknowledges safe adoption. */
  adoptProject: (payload: ProjectTransferPayload) => boolean
  /** Rebind a missing folder onto a tab, keeping its sessions/layout. */
  locateProject: (id: string, newPath: string) => void
  pushRecentProject: (path: string) => void
  /** Record which project owns an ACP agentKey (default: the active project). */
  setAgentProject: (agentKey: string, pid?: string) => void
  /** The single background-write primitive: active tab → live flat fields; a
   * background tab → its parked slice + the tab's activity badge (§4). */
  patchProject: (
    pid: string,
    updater: (slice: ProjectSliceMemory) => Partial<ProjectSliceMemory>,
    badge?: ProjectTab['activity'],
  ) => void
}

/** A `ProposalChange.payload` for create = the full entity; for update = {id,patch}; for delete = {id}. */
interface Identified { id?: ID }
type UpdatePayload = { id: ID; patch: Record<string, unknown> }

/** Read/write the flat collection an entity type lives in, for generic apply. */
function listAccessor(
  entityType: Proposal['changes'][number]['entityType'],
): { read: (p: Project) => unknown[]; write: (p: Project, arr: unknown[]) => Project } | null {
  switch (entityType) {
    case 'hypothesis': return { read: (p) => p.hypotheses, write: (p, a) => ({ ...p, hypotheses: a as Hypothesis[] }) }
    case 'question': return { read: (p) => p.questions, write: (p, a) => ({ ...p, questions: a as ResearchQuestion[] }) }
    case 'experiment': return { read: (p) => p.experiments, write: (p, a) => ({ ...p, experiments: a as ExperimentPlan[] }) }
    case 'run': return { read: (p) => p.runs, write: (p, a) => ({ ...p, runs: a as Run[] }) }
    case 'result': return { read: (p) => p.results, write: (p, a) => ({ ...p, results: a as ResultRecord[] }) }
    case 'figure': return { read: (p) => p.figures, write: (p, a) => ({ ...p, figures: a as Figure[] }) }
    case 'review': return { read: (p) => p.reviews, write: (p, a) => ({ ...p, reviews: a as Review[] }) }
    case 'source': return { read: (p) => p.corpus, write: (p, a) => ({ ...p, corpus: a as Source[] }) }
    case 'graph-node': return { read: (p) => p.claimGraph.nodes, write: (p, a) => ({ ...p, claimGraph: { ...p.claimGraph, nodes: a as GraphNode[] } }) }
    case 'graph-edge': return { read: (p) => p.claimGraph.edges, write: (p, a) => ({ ...p, claimGraph: { ...p.claimGraph, edges: a as GraphEdge[] } }) }
    default: return null
  }
}

/** Apply an inline-claim text diff to the manuscript (the original behavior). */
function applyInlineClaim(project: Project, change: Proposal['changes'][number]): Project {
  if (change.kind !== 'update' || !change.before) return project
  // no-op if nothing matches, so the identity check in applyProposal holds
  const hasMatch = project.manuscript.sections.some((sec) => sec.claims.some((c) => c.text === change.before))
  if (!hasMatch) return project
  return {
    ...project,
    manuscript: {
      ...project.manuscript,
      sections: project.manuscript.sections.map((sec) =>
        sec.claims.some((c) => c.text === change.before)
          ? { ...sec, claims: sec.claims.map((c) => (c.text === change.before ? { ...c, text: change.after ?? c.text } : c)) }
          : sec,
      ),
      updatedAt: nowISO(),
    },
  }
}

/**
 * Apply one approved change to the project. Inline-claim is a text diff;
 * structured entities apply via `change.payload` (create = the entity,
 * update = {id, patch}, delete = {id}). A structured change without a payload
 * (e.g. a model text-only change) is intentionally NOT auto-applied — it stays
 * recorded in the approved proposal for the human to formalize, never silently
 * mutating typed state with half-built objects.
 */
function applyChange(project: Project, change: Proposal['changes'][number]): Project {
  if (change.entityType === 'inline-claim') return applyInlineClaim(project, change)
  const acc = listAccessor(change.entityType)
  if (!acc || change.payload == null) return project
  const list = acc.read(project)
  if (change.kind === 'create') return acc.write(project, [...list, change.payload])
  if (change.kind === 'update') {
    const { id, patch } = change.payload as UpdatePayload
    if (!id) return project
    return acc.write(project, list.map((e) => ((e as Identified).id === id ? { ...(e as object), ...(patch ?? {}) } : e)))
  }
  if (change.kind === 'delete') {
    const { id } = change.payload as Identified
    if (!id) return project
    return acc.write(project, list.filter((e) => (e as Identified).id !== id))
  }
  return project
}

function applyProposal(project: Project, proposal: Proposal): Project {
  let next = project
  for (const change of proposal.changes) next = applyChange(next, change)
  return next === project ? project : { ...next, updatedAt: nowISO() }
}

const CHECKPOINT_CAP = 25
/** Deep-clone for a checkpoint snapshot so the undo timeline can't be poisoned by
 * later in-place nested mutation (makes the immutability invariant real, not a
 * convention). structuredClone is available in Electron/modern browsers. */
const cloneProject = (p: Project): Project =>
  typeof structuredClone === 'function' ? structuredClone(p) : (JSON.parse(JSON.stringify(p)) as Project)
/** Prepend a pre-mutation snapshot to the undo timeline, capped to the last N. */
function pushCheckpoint(state: KaisolaState, label: string, kind: Checkpoint['kind']): Checkpoint[] {
  const entry: Checkpoint = { id: uid('ckpt'), at: nowISO(), label, kind, snapshot: cloneProject(state.project) }
  return [entry, ...state.checkpoints].slice(0, CHECKPOINT_CAP)
}

/** Split a unified git diff into per-file patches, keyed by the file path. */
function splitPatch(patch: string): Record<string, string> {
  const out: Record<string, string> = {}
  if (!patch) return out
  for (const part of patch.split(/^diff --git /m)) {
    if (!part.trim()) continue
    const m = part.match(/ b\/(\S+)/) ?? part.match(/a\/(\S+)/)
    out[m ? m[1] : 'file'] = `diff --git ${part}`
  }
  return out
}

// Persisted-storage backend: the durable main-process DB on desktop, localStorage
// on the web. `getItem` stays SYNC (no rehydration flash) and falls back to any
// existing localStorage blob (one-time migration). The last written value is
// flushed synchronously on quit so we keep localStorage's no-lost-write guarantee.
// ── multi-window state routing ───────────────────────────────────────────────
// Full windows are numbered slots: window 2 persists under `kaisola-store-w2`,
// so each window is its own workspace that survives relaunch. Pop-out windows
// (one terminal card) rehydrate the DEFAULT store read-only — they must never
// write, or a stale pop would clobber the main window's newer state.
const WIN_PARAMS = typeof location !== 'undefined' ? new URLSearchParams(location.search) : null
const WIN_SLOT = WIN_PARAMS?.get('win') ?? null
export const POP_TERMINAL_ID = WIN_PARAMS?.get('pop') ?? null
export const POP_WINDOW_TITLE = WIN_PARAMS?.get('title') ?? null
export const POP_WINDOW_HUE = WIN_PARAMS?.get('hue') ?? null
// a tear-off adoption window boots PRISTINE on purpose: its (possibly stale)
// slot state must not rehydrate under the adopted project — the first persist
// then overwrites the slot key with the adopted state.
const ADOPT_BOOT = WIN_PARAMS?.get('adopt') === '1'
// Only the FIRST project delivered to a pristine tear-off may replace its
// global shell preferences. Later recombinations into that same live window
// keep the receiver's current appearance, just like Chrome.
let adoptBootGlobalsPending = ADOPT_BOOT
const STORE_KEY = WIN_SLOT ? `kaisola-store-w${WIN_SLOT}` : 'kaisola-store'
// keys this store persisted under before the renames (pasola → kiasola-typo →
// kaisola) — read-only fallbacks so existing sessions survive; writes go to the
// current key only
const LEGACY_STORE_KEYS = (name: string) => [
  name.replace(/^kaisola-store/, 'kiasola-store'),
  name.replace(/^kaisola-store/, 'pasola-store'),
]
// ptys live in ONE main-process manager keyed by id — every window's seeded
// default terminal must therefore carry a slot-unique id, or a second window
// would silently adopt (and steal the stream of) the first window's shell.
// (Kept for the v5→v6 migration fallback; new tabs use seedTermId(pid).)
const DEFAULT_TERM_ID = WIN_SLOT ? `term-w${WIN_SLOT}` : 'term-1'

// PROJECT TABS: the cold-boot tab's id, and the per-project seed-terminal id.
// A tab id is a globally-unique uid, so `term-${pid}` is unique across tabs AND
// across windows (each renderer mints its own BOOT_PID) — the invariant that
// keeps two tabs from ever adopting the same pty (risk #2).
const BOOT_PID = uid('proj')
const seedTermId = (pid: string) => `term-${pid}`
/** Project a state onto a subset of its keys (the slice pick primitive). */
const pick = <K extends keyof KaisolaState>(s: KaisolaState, keys: readonly K[]): Pick<KaisolaState, K> =>
  Object.fromEntries(keys.map((k) => [k, s[k]] as const)) as Pick<KaisolaState, K>

/** The OS appearance, resolved in the renderer (live via prefers-color-scheme). */
const systemTheme = (): Theme =>
  typeof window !== 'undefined' && window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'

// Persistence is THROTTLED at the shaping + serialization step: zustand calls
// setItem on EVERY set(), and both the slice walk (partialize) and the
// JSON.stringify of the whole store were a per-update main-thread tax — at
// stream time that's per token. partialize is now IDENTITY (free); setItem
// parks the latest raw-state REFERENCE (free — state objects are immutable)
// and the slice walk + stringify + write run at most once per PERSIST_MS;
// pagehide flushes synchronously so quitting never loses state. The blob
// format on disk is unchanged ({ state, version }).
const PERSIST_MS = 800
let lastPersist: { name: string; value: string } | null = null
let pendingPersist: { name: string; value: unknown } | null = null
let persistTimer: number | null = null
/** Shape the parked { state, version } envelope for disk: the raw live state
 * becomes the pruned/capped persist blob. Runs once per flush, not per set. */
const shapePersist = (value: unknown) => {
  const v = value as { state: KaisolaState; version?: number }
  return { ...v, state: persistSnapshot(v.state) }
}
const flushPersist = () => {
  if (persistTimer != null) {
    window.clearTimeout(persistTimer)
    persistTimer = null
  }
  if (!pendingPersist) return
  const { name, value } = pendingPersist
  pendingPersist = null
  const json = JSON.stringify(shapePersist(value))
  lastPersist = { name, value: json }
  if (isDesktop) void bridge.db.set(name, json).catch(() => {})
  else localStorage.setItem(name, json)
}
/** Durability barrier for ownership transfers and pagehide. The destination
 * must have the project on disk before it ACKs and lets the source delete it. */
const flushPersistSync = () => {
  if (persistTimer != null) {
    window.clearTimeout(persistTimer)
    persistTimer = null
  }
  if (!pendingPersist) return
  const { name, value } = pendingPersist
  pendingPersist = null
  const json = JSON.stringify(shapePersist(value))
  lastPersist = { name, value: json }
  if (isDesktop) bridge.db.setSync(name, json)
  else localStorage.setItem(name, json)
}
const kaisolaStorage = {
  getItem: (name: string) => {
    if (ADOPT_BOOT) return null // fresh boot for adoption — never rehydrate
    const legacies = LEGACY_STORE_KEYS(name)
    const raw = isDesktop
      ? bridge.db.getSync(name)
        ?? legacies.reduce<string | null>((hit, k) => hit ?? bridge.db.getSync(k), null)
        ?? localStorage.getItem(name)
        ?? legacies.reduce<string | null>((hit, k) => hit ?? localStorage.getItem(k), null)
      : localStorage.getItem(name) ?? legacies.reduce<string | null>((hit, k) => hit ?? localStorage.getItem(k), null)
    if (!raw) return null
    try {
      return JSON.parse(raw) as { state: unknown; version?: number }
    } catch {
      return null
    }
  },
  setItem: (name: string, value: unknown): void => {
    if (POP_TERMINAL_ID) return // pop windows are read-only viewers of the store
    pendingPersist = { name, value }
    if (persistTimer == null) persistTimer = window.setTimeout(flushPersist, PERSIST_MS)
  },
  removeItem: (name: string): void => {
    if (POP_TERMINAL_ID) return
    lastPersist = null
    pendingPersist = null
    if (isDesktop) void bridge.db.del(name).catch(() => {})
    else localStorage.removeItem(name)
  },
}
/** A one-project tear-off that was recombined is about to close. Remove its
 * now-empty slot without pagehide resurrecting the stale adopted project. */
const discardCurrentWindowStore = async () => {
  if (persistTimer != null) {
    window.clearTimeout(persistTimer)
    persistTimer = null
  }
  pendingPersist = null
  lastPersist = null
  const keys = [STORE_KEY, ...LEGACY_STORE_KEYS(STORE_KEY)]
  for (const key of keys) localStorage.removeItem(key)
  if (isDesktop) await Promise.all(keys.map((key) => bridge.db.del(key).catch(() => ({ ok: false }))))
}
if (typeof window !== 'undefined' && !POP_TERMINAL_ID) {
  window.addEventListener('pagehide', () => {
    if (pendingPersist) flushPersistSync()
    else if (isDesktop && lastPersist) {
      bridge.db.setSync(lastPersist.name, lastPersist.value)
    }
  })
}

/**
 * A short display title derived from what the user typed — the first words of
 * a message (threads) or the command line (terminals), cut at a word boundary.
 */
function titleFrom(text: string, max = 34): string | undefined {
  const t = text.replace(/\s+/g, ' ').trim()
  if (!t) return undefined
  const cut = t.length <= max ? t : `${t.slice(0, max).replace(/\s+\S*$/, '')}…`
  return cut.charAt(0).toUpperCase() + cut.slice(1)
}

/**
 * The rail's session order — the ONE ordering ⌘1..9, Ctrl+Tab, the palette
 * and the rail itself all share: pinned first, then grouped (group by
 * group), then everything else in natural order.
 */
export function sessionOrderIds(s: Pick<KaisolaState, 'assistantThreads' | 'terminals' | 'agentTerminals' | 'panels' | 'sessionGroups' | 'pinnedSessions'>): string[] {
  const natural = [
    ...s.assistantThreads.map((t) => t.id),
    ...s.terminals.map((t) => t.id),
    ...s.agentTerminals.map((t) => t.terminalId),
    ...s.panels.map((p) => p.id),
  ]
  const alive = new Set(natural)
  const pinned = s.pinnedSessions.filter((id) => alive.has(id))
  const grouped = s.sessionGroups.flatMap((g) => g.members).filter((id) => alive.has(id) && !pinned.includes(id))
  const rest = natural.filter((id) => !pinned.includes(id) && !grouped.includes(id))
  return [...pinned, ...grouped, ...rest]
}

// omni prompts need a NEVER-RESETTING sequence — deriving it from the last
// prompt (nulled after delivery) made every other ask replay a stale seq and
// get dropped by the consumer's guard
let omniSeqCounter = 0
// close→reopen→close: each close gets a token so a STALE 60s grace timer
// can't kill the pty (or eat the stack entry) of a newer close
const termCloseTokens = new Map<string, number>()

/** Normalize a card grid (drop empty columns) and mirror it to the flat list. */
function gridState(grid: string[][], extra: object = {}) {
  const g = grid.filter((col) => col.length)
  return { dockGrid: g, dockViews: g.flat(), ...extra }
}
/** A grid with every occurrence of `id` removed (empty columns dropped). */
const gridWithout = (grid: string[][], id: string) =>
  grid.map((col) => col.filter((v) => v !== id)).filter((col) => col.length)

/** Make the sessions area visibly useful. A boolean dockOpen with an empty
 * grid was the source of "Show sessions" doing nothing. */
function visibleDockState(
  s: Pick<KaisolaState, 'dockViews' | 'dockGrid' | 'activeThreadId' | 'assistantThreads' | 'terminals'>,
  extra: Record<string, unknown> = {},
) {
  if (s.dockViews.length) return { dockOpen: true, ...extra }
  const thread = s.assistantThreads.find((entry) => entry.id === s.activeThreadId) ?? s.assistantThreads[0]
  const id = thread?.id ?? s.terminals[0]?.id
  return id ? gridState([[id]], { dockOpen: true, ...extra }) : { dockOpen: true, ...extra }
}

// ── PROJECT TABS: slice helpers ───────────────────────────────────────────────
// terminals popped into their own window — the pop OWNS the pty, so closeProject
// must NOT schedule its grace-kill (risk #4). Renderer-scoped, not persisted.
const poppedTerms = new Set<string>()

/** Bucket D — per-project in-memory-only fields, seeded empty. */
const freshMemory = () => ({
  agentFeed: [] as AgentFeedItem[],
  needsYou: {} as Record<string, true>,
  closedStack: [] as ClosedSession[],
  pendingPermissions: [] as AcpPermissionRequest[],
  agentTerminals: [] as AgentTerminalSession[],
  agentRunning: {} as Partial<Record<AgentId, boolean>>,
  agentQueueRunning: false,
  agentTasks: [] as AgentTask[],
  latexDismissed: false,
  checkpoints: [] as Checkpoint[],
})

/** Bucket F — reset-on-switch ephemeral cursors (defaulted, never swapped). */
const resetEphemeralCursors = () => ({
  fileRequest: null,
  scrollRequest: null,
  selection: null,
  provenance: null,
  focusedProposalId: null,
  omniPrompt: null,
  outline: [] as OutlineItem[],
  editorCursorLine: null,
  fileDirty: false,
})

/** A brand-new project slice: one seeded terminal + one codex thread, empty rest.
 * The seed ids namespace off `pid` so they never collide across tabs (risk #2).
 * With a `path`, the seed terminal spawns IN the project folder — the default
 * card is a shell already sitting at the project root, not $HOME. */
const freshSlice = (pid: string, path: string | null = null): ProjectSliceMemory => {
  const term = seedTermId(pid)
  const threadId = `a-${pid}`
  return {
    project: emptyProject(),
    stage: 'files',
    layoutMode: 'studio',
    workspacePath: path,
    autonomy: 'propose',
    agentPreset: 'codex',
    claudeAccountId: '',
    fileTabs: [],
    openFilePath: null,
    repoCheckpoints: [],
    followAgent: false,
    annotations: [],
    assistantThreads: [{ id: threadId, agentKey: 'codex', busy: false }],
    assistantRuntimes: {},
    assistantDrafts: {},
    assistantPromptQueues: {},
    activeThreadId: threadId,
    terminals: [{ id: term, cwd: path ?? undefined }],
    panels: [],
    sessionGroups: [],
    pinnedSessions: [],
    worktreeSessions: {},
    latexMode: false,
    // a NEW empty tab is a clean homescreen — just the launcher, no cards; a
    // tab born onto a folder still docks its terminal like before
    dockGrid: path ? [[term]] : [],
    dockViews: path ? [term] : [],
    dockColWeights: null,
    canvasWidth: null,
    canvasOpen: true,
    dockOpen: !!path,
    ...freshMemory(),
  }
}

/** Read a project's slice: the live flat fields when active, else its parked slice. */
const projectFields = (s: KaisolaState, pid: string): ProjectSliceMemory =>
  pid === s.activeProjectId ? pick(s, PROJECT_SLICE_MEMORY_KEYS) : (s.projectSlices[pid] ?? freshSlice(pid))

// The provider owns its complete conversational context. Kaisola keeps a
// smooth recent renderer window and fsyncs everything older to its pageable
// JSONL archive. This deliberately spends disk instead of Chromium heap.
const ASSISTANT_LIVE_TURNS = 40
const ASSISTANT_ARCHIVE_TRIGGER_TURNS = 48
const ASSISTANT_ARCHIVE_BATCH_TURNS = 40
const ASSISTANT_ARCHIVE_BATCH_BYTES = 8 * 1024 * 1024
const utf8 = new TextEncoder()
/** Select a count-bounded and byte-bounded prefix while retaining the latest
 * compact live window. One oversize record is still attempted; if main rejects it,
 * the durable retry marker preserves it rather than dropping data. */
const assistantArchiveBatchCount = (turns: AssistantTurn[]): number => {
  const available = Math.min(ASSISTANT_ARCHIVE_BATCH_TURNS, Math.max(0, turns.length - ASSISTANT_LIVE_TURNS))
  let count = 0
  let bytes = 0
  for (let i = 0; i < available; i++) {
    let size = 0
    try { size = utf8.encode(JSON.stringify(turns[i])).byteLength + 80 } catch { return Math.max(1, count) }
    if (count > 0 && bytes + size > ASSISTANT_ARCHIVE_BATCH_BYTES) break
    bytes += size
    count++
  }
  return count
}

/** Stable 128-bit content/sequence fingerprint. If main fsyncs a batch and the
 * process dies before Zustand's throttled snapshot records archiveBatch, the
 * same persisted prefix regenerates the same id and main returns a duplicate
 * ACK instead of appending the turns twice. */
const assistantArchiveBatchId = (
  scope: { projectId: string; threadId: string; epoch?: string },
  baseCount: number,
  turns: AssistantTurn[],
): string => {
  let h1 = 0x811c9dc5
  let h2 = 0x9e3779b9
  let h3 = 0x243f6a88
  let h4 = 0xb7e15162
  let length = 0
  const feed = (value: string) => {
    length += value.length
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i)
      h1 = Math.imul(h1 ^ code, 0x01000193)
      h2 = Math.imul(h2 ^ code, 0x85ebca6b)
      h3 = Math.imul(h3 ^ code, 0xc2b2ae35)
      h4 = Math.imul(h4 ^ code, 0x27d4eb2f)
    }
    h1 = Math.imul(h1 ^ 0xff, 0x01000193)
    h2 = Math.imul(h2 ^ 0xff, 0x85ebca6b)
    h3 = Math.imul(h3 ^ 0xff, 0xc2b2ae35)
    h4 = Math.imul(h4 ^ 0xff, 0x27d4eb2f)
  }
  feed(JSON.stringify([scope.projectId, scope.threadId, scope.epoch ?? '0', baseCount, turns.length]))
  for (const turn of turns) feed(JSON.stringify(turn))
  const hash = [h1, h2, h3, h4].map((value) => (value >>> 0).toString(16).padStart(8, '0')).join('')
  return `v1-${baseCount}-${turns.length}-${length}-${hash}`
}

/** Today's per-slice pruning (extracted from `partialize`): projects a live slice
 * onto the durable persist keys, dropping transient bucket-D fields and capping
 * the heavy arrays / healing the grid. Pure — safe for any slice, active or not. */
function sanitizeSliceForPersist(slice: ProjectSliceMemory): ProjectSlicePersist {
  const assistantThreads = slice.assistantThreads.map((t) => ({ ...t, busy: false }))
  const terminals = slice.terminals.map((t) => ({
    id: t.id,
    name: t.name,
    autoName: t.autoName,
    cwd: t.cwd,
    singletonKey: t.singletonKey,
    restart: t.restart,
    boot: t.restart ? t.boot : undefined,
    continued: t.continued?.sameProcess && Number.isFinite(t.continued.at)
      ? {
          sameProcess: true as const,
          at: t.continued.at,
          ...(Number.isFinite(t.continued.terminalPid) ? { terminalPid: t.continued.terminalPid } : {}),
          ...(Number.isFinite(t.continued.outputBytes) ? { outputBytes: t.continued.outputBytes } : {}),
        }
      : undefined,
  }))
  const panels = slice.panels.map((p) => ({ id: p.id, kind: p.kind, url: p.url, title: p.title }))
  const validIds = new Set([
    ...assistantThreads.map((t) => t.id),
    ...terminals.map((t) => t.id),
    ...panels.map((p) => p.id),
  ])
  const dockGrid = slice.dockGrid.map((col) => col.filter((id) => validIds.has(id))).filter((col) => col.length)
  const activeThreadId = assistantThreads.some((t) => t.id === slice.activeThreadId)
    ? slice.activeThreadId
    : assistantThreads[0]?.id ?? ''
  const fallbackCard = assistantThreads[0]?.id ?? terminals[0]?.id
  const sessionGrid = gridState(dockGrid.length ? dockGrid : slice.dockOpen && fallbackCard ? [[fallbackCard]] : [])
  const assistantRuntimes = Object.fromEntries(
    Object.entries(slice.assistantRuntimes)
      .filter(([id]) => assistantThreads.some((t) => t.id === id))
      .map(([id, runtime]) => [id, {
        // Match the live headroom: a quit just before a spill must not prune a
        // turn that has not crossed the archive spill threshold yet. A batch
        // awaiting fsync/ACK keeps its whole prefix so quit/ENOSPC cannot lose
        // data; it retries idempotently after rehydration.
        turns: runtime.archiveBatch ? runtime.turns : runtime.turns.slice(-ASSISTANT_ARCHIVE_TRIGGER_TURNS),
        first: runtime.first,
        ...(runtime.archivedTurns ? { archivedTurns: runtime.archivedTurns } : {}),
        ...(runtime.archiveEpoch ? { archiveEpoch: runtime.archiveEpoch } : {}),
        ...(runtime.archiveBatch ? { archiveBatch: runtime.archiveBatch } : {}),
      }]),
  )
  const liveThreadIds = new Set(assistantThreads.map((t) => t.id))
  const assistantDrafts = Object.fromEntries(
    Object.entries(slice.assistantDrafts ?? {})
      .filter(([id]) => liveThreadIds.has(id))
      .map(([id, draft]) => [id, normalizeAssistantDraft(draft)])
      .filter(([, draft]) => !assistantDraftIsEmpty(draft as AssistantDraft)),
  )
  const assistantPromptQueues = Object.fromEntries(
    Object.entries(slice.assistantPromptQueues ?? {})
      .filter(([id]) => liveThreadIds.has(id))
      .map(([id, queue]) => [
        id,
        (Array.isArray(queue) ? queue : [])
          .map((q) => ({ ...normalizeAssistantDraft(q), id: q.id || uid('qp'), queuedAt: Number(q.queuedAt) || Date.now() }))
          .filter((q) => q.text.trim())
          .slice(0, 20),
      ])
      .filter(([, queue]) => (queue as QueuedAssistantPrompt[]).length),
  )
  return {
    project: slice.project,
    stage: slice.stage,
    workspacePath: slice.workspacePath,
    autonomy: slice.autonomy,
    agentPreset: slice.agentPreset,
    claudeAccountId: slice.claudeAccountId,
    fileTabs: slice.fileTabs,
    openFilePath: slice.openFilePath,
    repoCheckpoints: slice.repoCheckpoints.slice(0, 40),
    followAgent: slice.followAgent,
    annotations: slice.annotations.slice(-500),
    assistantThreads,
    assistantRuntimes,
    assistantDrafts,
    assistantPromptQueues,
    activeThreadId,
    terminals,
    panels,
    sessionGroups: slice.sessionGroups
      .map((g) => ({ ...g, members: g.members.filter((m) => validIds.has(m)) }))
      .filter((g) => g.members.length),
    pinnedSessions: slice.pinnedSessions.filter((id) => validIds.has(id)),
    // worktrees are DISK state that outlives their session — keep orphaned
    // entries (session closed, dir still there), cap only the orphans.
    worktreeSessions: Object.fromEntries([
      ...Object.entries(slice.worktreeSessions).filter(([id]) => validIds.has(id)),
      ...Object.entries(slice.worktreeSessions).filter(([id]) => !validIds.has(id)).slice(-20),
    ]),
    layoutMode: slice.layoutMode,
    latexMode: slice.latexMode,
    dockGrid: sessionGrid.dockGrid,
    dockViews: sessionGrid.dockViews,
    dockColWeights: slice.dockColWeights,
    canvasWidth: slice.canvasWidth,
    canvasOpen: slice.canvasOpen,
    dockOpen: slice.dockOpen,
  }
}

/** The durable blob: every slice (background + the active one, taken from the
 * live flat fields) folded into a uniform map, alongside the GLOBAL keys and
 * the tabs meta. Extracted from partialize — runs once per persist flush. */
function persistSnapshot(s: KaisolaState) {
  const slices: Record<string, ProjectSlicePersist> = {}
  for (const [id, sl] of Object.entries(s.projectSlices)) slices[id] = sanitizeSliceForPersist(sl)
  slices[s.activeProjectId] = sanitizeSliceForPersist(pick(s, PROJECT_SLICE_MEMORY_KEYS))
  return {
    // GLOBAL (bucket B + C) with the same caps as before
    theme: s.theme,
    themeMode: s.themeMode,
    agentModels: s.agentModels,
    fileTextZoom: s.fileTextZoom,
    termFontSize: s.termFontSize,
    termFontFamily: s.termFontFamily,
    termFontWeight: s.termFontWeight,
    termCursorColor: s.termCursorColor,
    termBackground: s.termBackground,
    permissionRules: s.permissionRules.slice(-200),
    sensitiveGlobs: s.sensitiveGlobs,
    customAgents: s.customAgents,
    enabledAgents: s.enabledAgents,
    sessionTemplates: s.sessionTemplates.slice(0, 40),
    latexMain: s.latexMain,
    unsavedBuffers: s.unsavedBuffers,
    claudeModel: s.claudeModel,
    reasoningProvider: s.reasoningProvider,
    localBaseUrl: s.localBaseUrl,
    localModel: s.localModel,
    openaiBaseUrl: s.openaiBaseUrl,
    openaiModel: s.openaiModel,
    openAlexMailto: s.openAlexMailto,
    grobidEndpoint: s.grobidEndpoint,
    sandboxMode: s.sandboxMode,
    workflows: s.workflows,
    automationsEnabled: s.automationsEnabled,
    wordDiffs: s.wordDiffs,
    showCosts: s.showCosts,
    inbox: s.inbox,
    draftRestore: s.draftRestore,
    wallpaperTint: s.wallpaperTint,
    onboardingVersion: s.onboardingVersion,
    perfMode: s.perfMode,
    tabLayout: s.tabLayout,
    railWidth: s.railWidth,
    railOpen: s.railOpen,
    claudeSessions: s.claudeSessions,
    claudeAccounts: s.claudeAccounts,
    claudeTerminalModel: s.claudeTerminalModel,
    claudeFastMode: s.claudeFastMode,
    // drafts survive only as long as a terminal that could replay them exists
    // somewhere (any slice, the live list, or the undo-close stack)
    termDrafts: (() => {
      const live = new Set<string>([
        ...s.terminals.map((t) => t.id),
        ...Object.values(s.projectSlices).flatMap((sl) => (sl.terminals ?? []).map((t) => t.id)),
        ...s.closedStack.filter((c) => c.kind === 'term').map((c) => (c as { term: { id: string } }).term.id),
      ])
      return Object.fromEntries(Object.entries(s.termDrafts).filter(([id]) => live.has(id)))
    })(),
    // TABS
    projectTabs: s.projectTabs,
    activeProjectId: s.activeProjectId,
    projectSlices: slices,
    recentProjects: s.recentProjects.slice(0, 12),
  }
}

/** Pick the persisted GLOBAL keys off a raw blob, skipping absent ones so a
 * default is never clobbered with `undefined` on merge. */
const pickGlobals = (p: Record<string, unknown>): Partial<KaisolaState> => {
  const out: Record<string, unknown> = {}
  for (const k of GLOBAL_KEYS) if (p[k] !== undefined) out[k] = p[k]
  return out as Partial<KaisolaState>
}

/** Existing windows retain their visual shell, but project-adjacent global
 * maps must come along so an unsent terminal draft or dirty file is not lost
 * when a tab joins a different window. A pristine tear-off takes everything. */
const globalsForAdoption = (
  current: KaisolaState,
  incoming: Record<string, unknown> | undefined,
  pristineBoot: boolean,
): Partial<KaisolaState> => {
  const picked = incoming ? pickGlobals(incoming) : {}
  if (pristineBoot) {
    if (picked.themeMode === 'system') picked.theme = systemTheme()
    return picked
  }
  return {
    ...(picked.termDrafts ? { termDrafts: { ...current.termDrafts, ...picked.termDrafts } } : {}),
    ...(picked.unsavedBuffers ? { unsavedBuffers: { ...current.unsavedBuffers, ...picked.unsavedBuffers } } : {}),
    ...(picked.claudeSessions ? { claudeSessions: { ...current.claudeSessions, ...picked.claudeSessions } } : {}),
    ...(picked.latexMain ? { latexMain: { ...current.latexMain, ...picked.latexMain } } : {}),
  }
}

/** terminalId → owning projectId across EVERY tab (active flat + all parked
 * slices). Used to route terminal events and to guard the close grace-kill. */
export function terminalOwnerMap(
  s: Pick<KaisolaState, 'activeProjectId' | 'terminals' | 'agentTerminals' | 'projectSlices'>,
): Record<string, string> {
  const map: Record<string, string> = {}
  const add = (pid: string, terms: TerminalSession[], agentTerms: AgentTerminalSession[]) => {
    for (const t of terms) map[t.id] = pid
    for (const t of agentTerms) map[t.terminalId] = pid
  }
  add(s.activeProjectId, s.terminals, s.agentTerminals)
  for (const [pid, sl] of Object.entries(s.projectSlices)) add(pid, sl.terminals, sl.agentTerminals)
  return map
}

/** Resolve the project that owns an incoming agent/terminal event, in order:
 * (a) explicit agentKey map, (b) sessionId → owning terminal, (c) longest
 * workspacePath prefix of cwd (active tab wins ties), else the active tab. */
export function projectIdForEvent(
  s: Pick<KaisolaState, 'agentProjectMap' | 'projectTabs' | 'activeProjectId' | 'terminals' | 'agentTerminals' | 'projectSlices'>,
  ev: { cwd?: string | null; sessionId?: string | null; agentKey?: string | null },
): string {
  if (ev.agentKey) {
    const mapped = s.agentProjectMap[ev.agentKey]
    if (mapped && s.projectTabs.some((t) => t.id === mapped)) return mapped
  }
  if (ev.sessionId) {
    const owner = terminalOwnerMap(s)[ev.sessionId]
    if (owner) return owner
  }
  if (ev.cwd) {
    const cwd = ev.cwd
    let best: { id: string; len: number } | null = null
    for (const t of s.projectTabs) {
      const ws = t.workspacePath
      if (!ws) continue
      const prefix = ws.endsWith('/') ? ws : `${ws}/`
      if (cwd === ws || cwd.startsWith(prefix)) {
        const better = !best || ws.length > best.len || (ws.length === best.len && t.id === s.activeProjectId)
        if (better) best = { id: t.id, len: ws.length }
      }
    }
    if (best) return best.id
  }
  return s.activeProjectId
}

/** The v5→(flat) migration body, verbatim — v6 wraps its result into tab #1. */
function migrateFlatV5(persisted: unknown): Partial<KaisolaState> {
  const state = persisted as Partial<KaisolaState>
  const project = state.project
  const chatAgent = (key?: string) => (key === 'claude-code' ? 'codex' : (key ?? 'codex'))
  // seed a thread only for stores that PREDATE thread persistence —
  // an explicitly empty list means the user closed their last chat
  const assistantThreads = (state.assistantThreads ?? [{ id: 'a1', agentKey: chatAgent(state.agentPreset), busy: false }])
    .map((t) => ({ ...t, agentKey: chatAgent(t.agentKey), busy: false }))
  const terminals = state.terminals?.length
    ? state.terminals.map((t) => ({
        id: t.id,
        name: t.name,
        autoName: t.autoName,
        cwd: t.cwd,
        singletonKey: t.singletonKey,
        restart: t.restart,
        boot: t.restart ? t.boot : undefined,
        continued: t.continued?.sameProcess && Number.isFinite(t.continued.at)
          ? {
              sameProcess: true as const,
              at: t.continued.at,
              ...(Number.isFinite(t.continued.terminalPid) ? { terminalPid: t.continued.terminalPid } : {}),
              ...(Number.isFinite(t.continued.outputBytes) ? { outputBytes: t.continued.outputBytes } : {}),
            }
          : undefined,
      }))
    : [{ id: DEFAULT_TERM_ID }]
  const panels = (state.panels ?? []).map((p) => ({ id: p.id, kind: p.kind, url: p.url, title: p.title }))
  const validIds = new Set([
    ...assistantThreads.map((t) => t.id),
    ...terminals.map((t) => t.id),
    ...panels.map((p) => p.id),
  ])
  const dockGrid = (state.dockGrid ?? [[assistantThreads[0]?.id ?? terminals[0].id]])
    .map((col) => col.filter((id) => validIds.has(id)))
    .filter((col) => col.length)
  const activeThreadId = assistantThreads.some((t) => t.id === state.activeThreadId)
    ? state.activeThreadId!
    : assistantThreads[0]?.id ?? ''
  // an all-invalid grid falls back to any surviving session (terminal-first)
  const fallbackCard = assistantThreads[0]?.id ?? terminals[0].id
  return {
    ...state,
    layoutMode: state.layoutMode ?? 'focus',
    agentPreset: chatAgent(state.agentPreset),
    assistantThreads,
    assistantRuntimes: state.assistantRuntimes ?? {},
    assistantDrafts: state.assistantDrafts ?? {},
    assistantPromptQueues: state.assistantPromptQueues ?? {},
    activeThreadId,
    terminals,
    agentTerminals: [],
    panels,
    customAgents: state.customAgents ?? [],
    enabledAgents: state.enabledAgents ?? ['claude-code', 'codex', 'opencode'],
    sessionGroups: (state.sessionGroups ?? [])
      .map((g) => ({ ...g, members: g.members.filter((m) => validIds.has(m)) }))
      .filter((g) => g.members.length),
    pinnedSessions: (state.pinnedSessions ?? []).filter((id) => validIds.has(id)),
    sessionTemplates: state.sessionTemplates ?? [],
    worktreeSessions: state.worktreeSessions ?? {},
    latexMode: state.latexMode ?? false,
    latexMain: state.latexMain ?? {},
    ...gridState(dockGrid.length ? dockGrid : [[fallbackCard]]),
    fileTabs: state.fileTabs ?? [],
    openFilePath: state.openFilePath ?? null,
    fileDirty: false,
    fileTextZoom: typeof state.fileTextZoom === 'number' ? Math.min(2.4, Math.max(0.72, state.fileTextZoom)) : 1,
    project: project
      ? {
          ...project,
          campaign: project.campaign ?? null,
          attempts: project.attempts ?? [],
        }
      : project,
  } as Partial<KaisolaState>
}

export const useKaisola = create<KaisolaState>()(
  persist(
    (set, get) => ({
  project: emptyProject(),

  stage: 'files',
  theme: 'light',
  themeMode: 'system',
  layoutMode: 'studio',
  autonomy: 'propose',
  paletteOpen: false,
  paletteMode: 'commands',
  selection: null,
  provenance: null,
  focusedProposalId: null,
  checkpoints: [],
  dockOpen: true,
  // agents-first shell: the fresh-boot card is a plain shell only until a
  // workspace exists — App's auto-launch then adopts it as the Claude agent
  // terminal (never in $HOME, so the agent can't work the wrong tree)
  dockGrid: [[seedTermId(BOOT_PID)]],
  dockViews: [seedTermId(BOOT_PID)],
  canvasWidth: null,
  dockColWeights: null,
  canvasOpen: true,
  terminals: [{ id: seedTermId(BOOT_PID) }],
  agentTerminals: [],
  panels: [],
  customAgents: [],
  // the registry's default "added" set — the rest are one click away in Settings
  enabledAgents: ['claude-code', 'codex', 'opencode'],
  sessionGroups: [],
  pinnedSessions: [],
  closedStack: [],
  needsYou: {},
  keymapOverrides: {},
  omniOpen: false,
  omniPrompt: null,
  sessionTemplates: [],
  worktreeSessions: {},
  latexMode: false,
  latexDismissed: false,
  latexMain: {},
  termDrafts: {},
  terminalMeta: {},
  termRemounts: {},
  settingsOpen: false,
  settingsPane: null,
  signIn: null,
  assistantThreads: [{ id: 'a1', agentKey: 'codex', busy: false }],
  assistantRuntimes: {},
  assistantDrafts: {},
  assistantPromptQueues: {},
  activeThreadId: 'a1',
  agentPreset: 'codex',
  agentRunning: {},
  agentTasks: [],
  agentQueueRunning: false,
  toasts: [],
  workflows: [
    { id: 'wf_lit', name: 'Literature pass', trigger: 'manual', steps: [
      { id: 'wfs_l1', kind: 'agent', ref: 'literature', count: 1 },
      { id: 'wfs_l2', kind: 'agent', ref: 'novelty', count: 1 },
    ] },
    { id: 'wf_ideas', name: 'Generate 3 ideas', trigger: 'manual', steps: [
      { id: 'wfs_i1', kind: 'agent', ref: 'hypothesis', count: 3 },
    ] },
  ],
  automationsEnabled: false,
  wordDiffs: true,
  showCosts: true,
  inbox: true,
  draftRestore: true,
  wallpaperTint: true,
  claudeTerminalModel: 'default',
  claudeFastMode: false,
  agentModels: {},
  workspacePath: null,
  fileRequest: null,
  openFilePath: null,
  fileDirty: false,
  fileTabs: [],
  fileTextZoom: 1,
  // Fresh installs start in the lowest-memory shell. Live Glass remains one
  // click away; removed painted-glass installs migrate to Eco losslessly.
  perfMode: 'eco' as PerfMode,
  // Hierarchy by scale and spacing only: no arrow, shelf, or colored underline.
  tabLayout: 'bare' as TabLayout,
  onboardingVersion: 0,
  railWidth: null,
  // Traycer-style quiet start: fresh installs open on the canvas alone; ⌘B
  // (or the strip's panel button) summons the rail. Existing installs keep
  // their persisted choice.
  railOpen: false,
  claudeSessions: {},
  claudeAccounts: [],
  claudeAccountId: '',
  termFontSize: 12,
  termFontFamily: 'JetBrains Mono',
  termFontWeight: 500,
  termCursorColor: 'auto',
  // ink follows the app theme: dark app → dark terminal with light text.
  // paper (light-in-dark) is an explicit Settings choice, never the default.
  termBackground: 'ink' as TermBackground,
  repoCheckpoints: [],
  agentFeed: [],
  followAgent: false,
  pendingPermissions: [],
  permissionRules: [],
  // Zed's shipped guardrail defaults — the files no agent should touch
  sensitiveGlobs: ['**/.env*', '**/*.pem', '**/*.key', '**/*.cert', '**/*.crt', '**/.dev.vars', '**/secrets.yml'],
  unsavedBuffers: {},
  outline: [],
  editorCursorLine: null,
  scrollRequest: null,
  annotations: [],
  claudeModel: 'claude-opus-4-8',
  reasoningProvider: 'openai',
  localBaseUrl: 'http://localhost:11434/v1',
  localModel: 'llama3.1',
  openaiBaseUrl: 'https://api.openai.com/v1',
  openaiModel: 'gpt-4o-mini',
  openAlexMailto: '',
  grobidEndpoint: '',
  sandboxMode: 'mock',

  // PROJECT TABS: cold boot seeds exactly one tab — identical to today for a
  // fresh user. A persisted store replaces this whole block via merge().
  projectTabs: [{ id: BOOT_PID, workspacePath: null, hue: folderHue(BOOT_PID), createdAt: Date.now() }],
  activeProjectId: BOOT_PID,
  projectSlices: {},
  closedProjectStack: [],
  recentProjects: [],
  agentProjectMap: {},

  setStage: (s) => {
    const prev = get().stage
    // navigating to a view always brings the main card back into view
    set({ stage: s, selection: null, canvasOpen: true })
    // automation: entering a NEW stage fires any on-stage workflows — but only
    // when automations are explicitly enabled, never in Observe mode, and never
    // while a run is still draining. Steps only ENQUEUE, so this can't cascade.
    if (s === prev || !get().automationsEnabled || get().autonomy === 'observe') return
    const armed = get().workflows.filter((w) => w.trigger === 'on-stage' && w.stage === s && w.steps.length)
    if (!armed.length) return
    if (get().agentTasks.some((t) => t.status === 'queued' || t.status === 'running')) {
      // honest about the skip rather than silently dropping it
      get().pushActivity('human', `Auto-run for ${s} skipped — the queue is busy.`)
      return
    }
    for (const w of armed) get().runWorkflow(w.id)
  },
  completeOnboarding: () => set({ onboardingVersion: 1 }),
  toggleTheme: () => {
    // a manual toggle is an EXPLICIT choice — it leaves system mode
    const next = get().theme === 'dark' ? 'light' : 'dark'
    get().setThemeMode(next)
  },
  setTheme: (t) => get().setThemeMode(t),
  setThemeMode: (m) => {
    const eff = m === 'system' ? systemTheme() : m
    document.documentElement.dataset.theme = eff
    bridge.setAppTheme?.(m) // native material: 'system' re-arms OS following
    set({ themeMode: m, theme: eff })
  },
  applySystemTheme: () => {
    const s = get()
    if (s.themeMode !== 'system') return
    const eff = systemTheme()
    if (eff === s.theme) return
    document.documentElement.dataset.theme = eff
    set({ theme: eff })
  },
  // a theme change arriving FROM another window — apply without re-sending, or
  // two open windows would ping-pong the broadcast forever
  followTheme: (t) => {
    const eff = t === 'system' ? systemTheme() : t
    document.documentElement.dataset.theme = eff
    set({ themeMode: t, theme: eff })
  },
  setLayoutMode: (mode) => set((s) => mode === 'focus'
    ? { layoutMode: 'focus', canvasOpen: true }
    : visibleDockState(s, { layoutMode: 'studio', canvasOpen: true })),
  toggleLayoutMode: () => set((s) => s.layoutMode === 'focus'
    ? visibleDockState(s, { layoutMode: 'studio', canvasOpen: true })
    : { layoutMode: 'focus', canvasOpen: true }),
  setAutonomy: (a) => {
    set({ autonomy: a })
    // tell main NOW — main gates each connection's permissions on its per-entry
    // autonomy, so lowering the dial mid-session must reach it to stop a running
    // agent (fire-and-forget; the web mock no-ops)
    void bridge.acp.setAutonomy(a)
  },
  openPalette: (mode) => set((s) => ({ paletteOpen: true, paletteMode: mode ?? s.paletteMode })),
  closePalette: () => set({ paletteOpen: false }),
  // toggling into an ALREADY-OPEN palette with a different mode switches modes
  // instead of closing — ⌘K→⌘P flows the way VS Code users expect
  togglePalette: (mode) =>
    set((s) => {
      if (!s.paletteOpen) return { paletteOpen: true, paletteMode: mode ?? 'commands' }
      if (mode && mode !== s.paletteMode) return { paletteMode: mode }
      return { paletteOpen: false }
    }),
  select: (sel) => set({ selection: sel }),
  showProvenance: (t) => set({ provenance: t }),
  hideProvenance: () => set({ provenance: null }),
  focusProposal: (id) => set({ focusedProposalId: id }),
  toggleDock: () => set((s) => s.layoutMode === 'studio' && s.dockOpen
    ? { dockOpen: false }
    : visibleDockState(s, { layoutMode: 'studio' })),
  // kept for callers/harnesses that think in panes: 'assistant' focuses the
  // active thread, 'terminal' the current/first terminal.
  setDock: (open, tab) =>
    set((s) => {
      const focus =
        tab === 'assistant' && !s.dockViews.includes(s.activeThreadId)
          ? s.activeThreadId
          : tab === 'terminal' && s.terminals.length && !s.terminals.some((t) => s.dockViews.includes(t.id))
            ? s.terminals[0].id
            : null
      if (!open) return { dockOpen: false }
      if (focus) return gridState([[focus]], { dockOpen: true, layoutMode: 'studio' })
      return visibleDockState(s, { layoutMode: 'studio' })
    }),
  // showing a session never tears down the layout you built — an unopened
  // session joins as a new card on the right. Viewing clears its amber dot.
  setDockView: (id) =>
    set((s) => {
      const needsYou = { ...s.needsYou }
      delete needsYou[id]
      return s.dockViews.includes(id)
        ? { dockOpen: true, needsYou }
        : gridState([...s.dockGrid, [id]], { dockOpen: true, needsYou })
    }),
  addDockSplit: (id) =>
    set((s) => {
      const needsYou = { ...s.needsYou }
      delete needsYou[id]
      return s.dockViews.includes(id)
        ? { dockOpen: true, needsYou }
        : gridState([...s.dockGrid, [id]], { dockOpen: true, needsYou })
    }),
  removeDockView: (id) =>
    set((s) => {
      const grid = gridWithout(s.dockGrid, id)
      // putting away the LAST card hides the work area (full-width canvas);
      // park a valid session behind the curtain for the next ⌘J
      if (!grid.length) {
        const fallback =
          (s.assistantThreads.some((t) => t.id === s.activeThreadId) ? s.activeThreadId : undefined) ??
          s.assistantThreads[0]?.id ??
          s.terminals[0]?.id
        return fallback ? gridState([[fallback]], { dockOpen: false }) : gridState([], { dockOpen: false })
      }
      return gridState(grid)
    }),
  placeDockView: (id, targetId, edge) =>
    set((s) => {
      if (id === targetId) return s
      const grid = gridWithout(s.dockGrid, id)
      const ci = grid.findIndex((col) => col.includes(targetId))
      if (ci < 0) return gridState([...grid, [id]], { dockOpen: true })
      const next = grid.map((col) => [...col])
      if (edge === 'left' || edge === 'right') next.splice(ci + (edge === 'right' ? 1 : 0), 0, [id])
      else next[ci].splice(next[ci].indexOf(targetId) + (edge === 'bottom' ? 1 : 0), 0, id)
      return gridState(next, { dockOpen: true })
    }),
  setCanvasWidth: (w) =>
    set({ canvasWidth: w == null ? null : Math.min(1600, Math.max(340, Math.round(w))) }),
  setRailWidth: (w) =>
    set({ railWidth: w == null ? null : Math.min(480, Math.max(176, Math.round(w))) }),
  setClaudeSession: (workspace, sessionId) =>
    set((s) => {
      if (s.claudeSessions[workspace] === sessionId) return s
      // cap the map: drop the oldest entries past 40 workspaces (insertion order)
      const entries = Object.entries(s.claudeSessions).filter(([ws]) => ws !== workspace)
      while (entries.length >= 40) entries.shift()
      return { claudeSessions: Object.fromEntries([...entries, [workspace, sessionId]]) }
    }),
  setClaudeAccountId: (id) => set({ claudeAccountId: id || '' }),
  addClaudeAccount: (label, configDir) =>
    set((s) => {
      const lbl = label.trim() || 'Account'
      const dir = configDir.trim()
      if (!dir || s.claudeAccounts.some((a) => a.configDir === dir)) return s
      const id = `ca-${Date.now().toString(36)}`
      return { claudeAccounts: [...s.claudeAccounts, { id, label: lbl, configDir: dir }] }
    }),
  removeClaudeAccount: (id) =>
    set((s) => ({
      claudeAccounts: s.claudeAccounts.filter((a) => a.id !== id),
      // a project bound to the removed account falls back to the default (~/.claude)
      claudeAccountId: s.claudeAccountId === id ? '' : s.claudeAccountId,
    })),
  setClaudeAccountEmail: (id, email) =>
    set((s) => ({ claudeAccounts: s.claudeAccounts.map((a) => (a.id === id ? { ...a, email } : a)) })),
  launchClaude: async (opts) => {
    const st = get()
    const ws = st.workspacePath
    const pid = st.activeProjectId
    if (!ws || !isDesktop) return false
    if (opts?.expect && (opts.expect.pid !== pid || opts.expect.ws !== ws)) return false
    // risk #5: never arm the agent in a folder that no longer exists (a moved
    // or deleted workspace would spawn the agent in the wrong tree / $HOME)
    const exists = await bridge.fs.list(ws)
    if (!exists.ok) return false
    const acct = st.claudeAccounts.find((a) => a.id === st.claudeAccountId)
    // resume the workspace's last conversation: the tracked session id when
    // its transcript still exists (exact chat), else --continue when the
    // account's config dir has ANY transcript for this folder
    const sid = get().claudeSessions[ws]
    const sessions = await bridge.claude.sessionExists?.(ws, sid ?? '', acct?.configDir)
    // the Kaisola MCP server (project state + agent-task ledger) rides along
    const mcpPath = (await bridge.mcp?.info().catch(() => null))?.configPath
    const q = (v: string) => `'${v.replace(/'/g, `'\\''`)}'`
    const resumeArg = sid && sessions?.exists ? `--resume ${q(sid)}` : sessions?.any ? '--continue' : ''
    // a fast tab switch may have moved on while we probed the folder
    const now = get()
    if (opts?.expect && (now.activeProjectId !== opts.expect.pid || now.workspacePath !== opts.expect.ws)) return false
    if (!opts?.expect && (now.activeProjectId !== pid || now.workspacePath !== ws)) return false
    // the hooks tap is armed at app startup (main) and its settings path is a
    // constant on the bridge — the boot line is built synchronously
    const hooksPath = bridge.claude.settingsPath
    // fast mode rides the same settings file; sync it in case this launch is
    // the first since the preference was restored from disk
    await bridge.claude.setSettingsFlags?.(get().claudeFastMode ? { fastMode: true } : {}, acct?.configDir, ws)
    const model = get().claudeTerminalModel
    const boot = [
      acct?.configDir ? `CLAUDE_CONFIG_DIR=${shellConfigDir(acct.configDir)}` : '',
      hooksPath ? `claude --settings ${q(hooksPath)}` : 'claude',
      model && model !== 'default' ? `--model ${q(model)}` : '',
      mcpPath ? `--mcp-config ${q(mcpPath)}` : '',
      resumeArg,
    ].filter(Boolean).join(' ')
    get().requestTerminal(boot, {
      cwd: ws,
      name: acct ? `Claude · ${acct.label}` : 'Claude',
      singletonKey: 'agent:claude-code',
      restart: true,
      // never clobber a layout the user arranged — only App's one-time
      // fresh-shell migration places the card
      reveal: opts?.reveal ?? false,
    })
    return true
  },
  setDockColWeights: (weights) =>
    set({ dockColWeights: weights && weights.length ? weights.map((w) => Math.max(0.15, w)) : null }),
  // minimizing the main view leaves only the session cards — so keep them shown
  toggleCanvas: () => set((s) => {
    // Focus always renders the canvas, so "Hide files" must first return to
    // Studio and reveal a real session. Otherwise the button changes state
    // while the screen visibly does nothing.
    if (s.layoutMode === 'focus' || s.canvasOpen) {
      return visibleDockState(s, { layoutMode: 'studio', canvasOpen: false })
    }
    return { canvasOpen: true }
  }),
  requestTerminal: (command, opts) =>
    set((s) => {
      // reveal: false ensures the terminal exists without touching the layout —
      // startup auto-launch must not re-dock a card the user put away
      const reveal = opts?.reveal !== false
      const autoName = command ? titleFrom(command, 26) : undefined
      const defaultTerminal = opts?.singletonKey && command && s.terminals.length === 1
        ? s.terminals.find((t) => !s.dockViews.includes(t.id) && !t.boot && !t.restart && !t.singletonKey && !t.cwd && !t.name && !t.autoName)
        : undefined
      const existing = opts?.singletonKey
        ? s.terminals.find((t) =>
            t.singletonKey === opts.singletonKey ||
            (!t.singletonKey && !!command && t.name === opts.name && t.autoName === autoName),
          ) ?? defaultTerminal
        : undefined
      if (existing) {
        const adopted = existing === defaultTerminal
        const boot = opts?.restart && command ? command : existing.boot
        const grid = s.dockViews.includes(existing.id) ? s.dockGrid : [...s.dockGrid, [existing.id]]
        return {
          terminals: s.terminals.map((t) =>
            t.id === existing.id
              ? {
                  ...t,
                  // an adopted pristine terminal takes the requested cwd (its
                  // shell gets a `cd` alongside the boot command); a matched
                  // singleton keeps the directory its pty actually runs in
                  cwd: adopted ? opts?.cwd ?? t.cwd : t.cwd,
                  name: opts?.name ?? t.name,
                  autoName: autoName ?? t.autoName,
                  boot,
                  // the pty may already be live, where create skips boot — flag
                  // a NEW boot so the Terminal component writes it once.
                  // rerun: same command again on purpose (LaTeX rebuilds).
                  bootPending: boot && (boot !== t.boot || opts?.rerun) ? true : t.bootPending,
                  restart: opts?.restart ?? t.restart,
                  singletonKey: opts?.singletonKey ?? t.singletonKey,
                }
              : t,
          ),
          ...(reveal ? gridState(grid, { dockOpen: true }) : {}),
        }
      }
      const id = uid('term')
      return {
        terminals: [...s.terminals, {
          id,
          boot: command,
          restart: opts?.restart,
          singletonKey: opts?.singletonKey,
          cwd: opts?.cwd,
          name: opts?.name,
          autoName,
        }],
        ...(reveal ? gridState([...s.dockGrid, [id]], { dockOpen: true }) : {}),
      }
    }),
  clearBootPending: (id) =>
    set((s) =>
      s.terminals.some((t) => t.id === id && t.bootPending)
        ? { terminals: s.terminals.map((t) => (t.id === id ? { ...t, bootPending: undefined } : t)) }
        : s,
    ),
  setTerminalContinuation: (id, status, projectId) => {
    const state = get()
    const owner = projectId ?? terminalOwnerMap(state)[id] ?? state.activeProjectId
    state.patchProject(owner, (slice) => {
      const current = slice.terminals.find((terminal) => terminal.id === id)?.continued
      if (!status && !current) return {}
      if (status && current?.at === status.at && current.terminalPid === status.terminalPid && current.outputBytes === status.outputBytes) return {}
      return {
        terminals: slice.terminals.map((terminal) =>
          terminal.id === id ? { ...terminal, continued: status } : terminal,
        ),
      }
    })
  },
  closeTerminal: (id) => {
    set((s) => {
      const closing = s.terminals.find((t) => t.id === id)
      const rest = s.terminals.filter((t) => t.id !== id)
      const terminals = rest.length ? rest : [{ id: uid('term') }]
      const grid = gridWithout(s.dockGrid, id)
      const needsYou = { ...s.needsYou }
      delete needsYou[id]
      return {
        terminals,
        needsYou,
        // Chrome's undo-close: the record goes on the stack and the pty gets
        // a 60s grace before the deferred kill below reaps it
        closedStack: closing ? [{ kind: 'term' as const, at: Date.now(), term: closing }, ...s.closedStack].slice(0, 8) : s.closedStack,
        ...gridState(grid.length ? grid : [[terminals[terminals.length - 1].id]]),
      }
    })
    const token = (termCloseTokens.get(id) ?? 0) + 1
    termCloseTokens.set(id, token)
    window.setTimeout(() => {
      if (termCloseTokens.get(id) !== token) return // a NEWER close owns the grace now
      termCloseTokens.delete(id) // grace resolved — don't let the Map grow per-close forever
      const now = get()
      if (now.terminals.some((t) => t.id === id)) return // reopened — keep the pty
      // REAL close (survived the grace, not reopened): drop it from the
      // ever-mounted Set too — the sibling termCloseTokens reap left it growing
      // forever. Placed after the reopened guard so a kept terminal isn't forgotten.
      forgetMountedTerminal(id)
      void bridge.terminal.kill(id)
      set((s) => ({ closedStack: s.closedStack.filter((c) => c.term?.id !== id) }))
    }, 60_000)
  },
  renameTerminal: (id, name) =>
    set((s) => ({ terminals: s.terminals.map((t) => (t.id === id ? { ...t, name: name || undefined } : t)) })),
  // an agent-spawned terminal opens BESIDE what you're doing — its own card,
  // never stealing the one you're in
  addAgentTerminal: (t) =>
    set((s) => {
      if (s.agentTerminals.some((x) => x.terminalId === t.terminalId)) return s
      const grid = s.dockViews.includes(t.terminalId) ? s.dockGrid : [...s.dockGrid, [t.terminalId]]
      return { agentTerminals: [...s.agentTerminals, t], ...gridState(grid, { dockOpen: true }) }
    }),
  closeAgentTerminal: (terminalId) =>
    set((s) => {
      const agentTerminals = s.agentTerminals.filter((t) => t.terminalId !== terminalId)
      const grid = gridWithout(s.dockGrid, terminalId)
      const fallback = s.terminals[0]?.id ?? s.assistantThreads[0]?.id
      return {
        agentTerminals,
        ...gridState(grid.length ? grid : fallback ? [[fallback]] : []),
      }
    }),
  setTermDraft: (id, text) =>
    set((s) => {
      if (!text) {
        if (!(id in s.termDrafts)) return {}
        const { [id]: _dropped, ...rest } = s.termDrafts
        return { termDrafts: rest }
      }
      if (s.termDrafts[id] === text) return {}
      return { termDrafts: { ...s.termDrafts, [id]: text } }
    }),
  setTerminalResume: (id, boot) =>
    set((s) => ({
      terminals: s.terminals.map((terminal) =>
        terminal.id === id ? { ...terminal, restart: true, boot } : terminal,
      ),
    })),
  setTerminalMeta: (id, patch) =>
    set((s) => {
      // bail on no-ops: this fires on every OSC title / meta tick, and a
      // pointless set() re-renders every session surface (rail, tabs, cards)
      const cur = s.terminalMeta[id] as Record<string, unknown> | undefined
      const same =
        cur &&
        Object.entries(patch).every(([k, v]) => {
          const c = cur[k]
          return Array.isArray(v) ? Array.isArray(c) && v.join() === c.join() : c === v
        })
      if (same) return s
      // A MANUALLY-started CLI agent (plain terminal, user typed `claude` or
      // `codex`) used to vanish on restart: only `restart: true` rows persist their boot, and
      // only `agent:`/`wt:` singletons track drafts. The fg-process signal
      // already tells us claude is running here — upgrade the row on the spot
      // (persisted `--continue` boot + an agent: key, so the existing restart
      // re-boot AND draft retype machinery take over with zero extra wiring).
      // When claude exits back to the shell the upgrade is undone, so a
      // terminal that merely visited claude doesn't resurrect it at next boot.
      // Claude hooks later upgrade --continue to an exact --resume. Codex's
      // terminal-session probe does the same; --last is the safe fallback.
      let terminals = s.terminals
      if ('fgProcess' in patch) {
        const t = s.terminals.find((x) => x.id === id)
        const fg = String(patch.fgProcess || '')
        // NEVER adopt a login terminal (`claude /login`): stamping it with
        // restart:true + `claude --continue` made the transient sign-in pane
        // immortal — it re-persisted, re-booted, and refused to close.
        const isLogin = /\/login\b/.test(t?.boot ?? '')
        if (t && !t.singletonKey && !isLogin && /^claude\b/.test(fg)) {
          terminals = s.terminals.map((x) =>
            x.id === id
              ? { ...x, singletonKey: `agent:claude-cli-${id}`, restart: true, boot: 'claude --continue', name: x.name ?? 'Claude' }
              : x,
          )
        } else if (t && t.singletonKey?.startsWith('agent:claude-cli-') && /^-?(zsh|bash|fish|sh)$/.test(fg)) {
          terminals = s.terminals.map((x) =>
            x.id === id ? { ...x, singletonKey: undefined, restart: undefined, boot: undefined } : x,
          )
        } else if (t && !t.singletonKey && !isLogin && /^codex\b/.test(fg)) {
          terminals = s.terminals.map((x) =>
            x.id === id
              ? { ...x, singletonKey: `agent:codex-cli-${id}`, restart: true, boot: 'codex resume --last', name: x.name ?? 'Codex' }
              : x,
          )
        } else if (t && t.singletonKey?.startsWith('agent:codex') && /^codex\b/.test(fg) && (!t.restart || !/^codex resume\b/.test(t.boot ?? ''))) {
          terminals = s.terminals.map((x) =>
            x.id === id ? { ...x, restart: true, boot: 'codex resume --last' } : x,
          )
        } else if (t && t.singletonKey?.startsWith('agent:codex-cli-') && /^-?(zsh|bash|fish|sh)$/.test(fg)) {
          terminals = s.terminals.map((x) =>
            x.id === id ? { ...x, singletonKey: undefined, restart: undefined, boot: undefined } : x,
          )
        }
      }
      return {
        terminalMeta: { ...s.terminalMeta, [id]: { ...s.terminalMeta[id], ...patch } },
        ...(terminals !== s.terminals ? { terminals } : {}),
      }
    }),
  // send a terminal card to its own window; the card leaves this window's grid
  // (one pty stream has ONE renderer at a time) and returns on pop close
  popOutTerminal: (id, title, hue) => {
    poppedTerms.add(id) // the pop now owns the pty (closeProject must not reap it)
    get().removeDockView(id)
    void bridge.windows?.pop?.(id, title, hue)
  },
  restorePoppedTerminal: (id) => {
    poppedTerms.delete(id)
    set((s) => {
      // pop:closed broadcasts to EVERY window — only the window/tab that actually
      // owns this terminal re-adopts it (a ghost id would render an empty column).
      const activeKnown = s.terminals.some((t) => t.id === id) || s.agentTerminals.some((t) => t.terminalId === id)
      if (activeKnown) {
        const grid = s.dockViews.includes(id) ? s.dockGrid : [...s.dockGrid, [id]]
        return {
          termRemounts: { ...s.termRemounts, [id]: (s.termRemounts[id] ?? 0) + 1 },
          ...gridState(grid, { dockOpen: true }),
        }
      }
      // a background tab may own it — scan ALL parked slices (risk #4), re-dock
      // it there, bump the (GLOBAL) remount counter, and flag the tab.
      for (const [pid, sl] of Object.entries(s.projectSlices)) {
        const owns = sl.terminals.some((t) => t.id === id) || sl.agentTerminals.some((t) => t.terminalId === id)
        if (!owns) continue
        const grid = sl.dockViews.includes(id) ? sl.dockGrid : [...sl.dockGrid, [id]]
        const g = gridState(grid, { dockOpen: true })
        return {
          termRemounts: { ...s.termRemounts, [id]: (s.termRemounts[id] ?? 0) + 1 },
          projectSlices: { ...s.projectSlices, [pid]: { ...sl, dockGrid: g.dockGrid, dockViews: g.dockViews, dockOpen: true } },
          projectTabs: s.projectTabs.map((t) => (t.id === pid ? { ...t, activity: t.activity ?? 'running' } : t)),
        }
      }
      return s
    })
  },
  // ── panel cards (git commit panel, embedded browsers) ──
  openGitPanel: () =>
    set((s) => {
      const id = 'panel-git'
      const grid = s.dockViews.includes(id) ? s.dockGrid : [...s.dockGrid, [id]]
      return {
        panels: s.panels.some((p) => p.id === id) ? s.panels : [...s.panels, { id, kind: 'git' as const }],
        ...gridState(grid, { dockOpen: true }),
      }
    }),
  openLedgerPanel: () =>
    set((s) => {
      const id = 'panel-ledger'
      const grid = s.dockViews.includes(id) ? s.dockGrid : [...s.dockGrid, [id]]
      return {
        panels: s.panels.some((p) => p.id === id) ? s.panels : [...s.panels, { id, kind: 'ledger' as const }],
        ...gridState(grid, { dockOpen: true }),
      }
    }),
  openBrowserPanel: (url) =>
    set((s) => {
      const origin = (u?: string) => { try { return u ? new URL(u).origin : null } catch { return null } }
      const target = origin(url)
      // a second link to the same server re-points the existing card (dev-server
      // preview refreshes in place) instead of stacking near-identical browsers
      const existing = target ? s.panels.find((p) => p.kind === 'browser' && origin(p.url) === target) : undefined
      if (existing) {
        const grid = s.dockViews.includes(existing.id) ? s.dockGrid : [...s.dockGrid, [existing.id]]
        return {
          panels: s.panels.map((p) => (p.id === existing.id ? { ...p, url: url ?? p.url, seq: (p.seq ?? 0) + 1 } : p)),
          ...gridState(grid, { dockOpen: true }),
        }
      }
      const id = uid('web')
      return {
        panels: [...s.panels, { id, kind: 'browser' as const, url }],
        ...gridState([...s.dockGrid, [id]], { dockOpen: true }),
      }
    }),
  closePanel: (id) =>
    set((s) => {
      const closing = s.panels.find((p) => p.id === id)
      const panels = s.panels.filter((p) => p.id !== id)
      const grid = gridWithout(s.dockGrid, id)
      const fallback = s.terminals[0]?.id ?? s.assistantThreads[0]?.id
      return {
        panels,
        closedStack: closing ? [{ kind: 'panel' as const, at: Date.now(), panel: closing }, ...s.closedStack].slice(0, 8) : s.closedStack,
        ...gridState(grid.length ? grid : fallback ? [[fallback]] : [], grid.length || fallback ? {} : { dockOpen: false }),
      }
    }),
  setPanelState: (id, patch) =>
    set((s) => ({ panels: s.panels.map((p) => (p.id === id ? { ...p, ...patch } : p)) })),
  // ── the agent registry (Zed's agent_servers pattern) ──
  addCustomAgent: (agent) =>
    set((s) => ({ customAgents: [...s.customAgents.filter((a) => a.id !== agent.id), agent] })),
  removeCustomAgent: (id) =>
    set((s) => ({ customAgents: s.customAgents.filter((a) => a.id !== id) })),
  toggleAgentEnabled: (id) =>
    set((s) => ({
      enabledAgents: s.enabledAgents.includes(id)
        ? s.enabledAgents.filter((a) => a !== id)
        : [...s.enabledAgents, id],
    })),
  // ── Chrome-style session groups ──
  createSessionGroup: (name, members) =>
    set((s) => ({
      sessionGroups: [
        // a session lives in at most one group — pull members out of others
        ...s.sessionGroups.map((g) => ({ ...g, members: g.members.filter((m) => !members.includes(m)) })),
        { id: uid('grp'), name: name.trim() || 'Group', members },
      ].filter((g) => g.members.length),
    })),
  renameSessionGroup: (id, name) =>
    set((s) => ({ sessionGroups: s.sessionGroups.map((g) => (g.id === id ? { ...g, name: name.trim() || g.name } : g)) })),
  toggleSessionGroupCollapsed: (id) =>
    set((s) => ({ sessionGroups: s.sessionGroups.map((g) => (g.id === id ? { ...g, collapsed: !g.collapsed } : g)) })),
  assignToGroup: (sessionId, groupId) =>
    set((s) => ({
      sessionGroups: s.sessionGroups
        .map((g) => ({
          ...g,
          members: g.id === groupId
            ? [...g.members.filter((m) => m !== sessionId), sessionId]
            : g.members.filter((m) => m !== sessionId),
        }))
        .filter((g) => g.members.length),
    })),
  removeSessionGroup: (id) =>
    set((s) => ({ sessionGroups: s.sessionGroups.filter((g) => g.id !== id) })),
  // Rail order = grouped sessions (group by group), then ungrouped — the same
  // order the rail draws, so ⌘1..9 match what the user sees
  switchSession: (id) =>
    set((s) => {
      const needsYou = { ...s.needsYou }
      delete needsYou[id]
      const active = {
        needsYou,
        activeThreadId: s.assistantThreads.some((t) => t.id === id) ? id : s.activeThreadId,
      }
      if (s.dockViews.includes(id)) return { dockOpen: true, ...active }
      const anchor = s.dockViews[0]
      if (!anchor) return { ...gridState([[id]], { dockOpen: true }), ...active }
      // swap the anchor card for the target — the rest of the layout stays
      return {
        ...gridState(s.dockGrid.map((col) => col.map((v) => (v === anchor ? id : v))), { dockOpen: true }),
        ...active,
      }
    }),
  cycleSession: (dir) => {
    const s = get()
    const order = sessionOrderIds(s)
    if (order.length < 2) return
    const anchor = s.dockViews[0] ?? order[0]
    const at = Math.max(0, order.indexOf(anchor))
    // the next session that isn't already showing (skips no-op hops)
    for (let step = 1; step < order.length; step++) {
      const next = order[(at + dir * step + order.length * step) % order.length]
      if (!s.dockViews.includes(next)) { s.switchSession(next); return }
    }
  },
  togglePinSession: (id) =>
    set((s) => ({
      pinnedSessions: s.pinnedSessions.includes(id)
        ? s.pinnedSessions.filter((p) => p !== id)
        : [...s.pinnedSessions, id],
    })),
  setSessionGroupColor: (id, color) =>
    set((s) => ({ sessionGroups: s.sessionGroups.map((g) => (g.id === id ? { ...g, color } : g)) })),
  markNeedsYou: (id, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => (sl.needsYou[id] ? {} : { needsYou: { ...sl.needsYou, [id]: true } }))
  },
  reopenClosedSession: () =>
    set((s) => {
      const [top, ...rest] = s.closedStack
      if (!top) return s
      if (top.kind === 'term' && top.term) {
        // a singleton (the claude terminal) may have been auto-recreated since
        // the close — never resurrect a SECOND copy, focus the live one
        const dupe = top.term.singletonKey
          ? s.terminals.find((t) => t.singletonKey === top.term!.singletonKey)
          : undefined
        if (dupe || s.terminals.some((t) => t.id === top.term!.id)) {
          const focus = dupe?.id ?? top.term.id
          return {
            closedStack: rest,
            ...gridState(s.dockViews.includes(focus) ? s.dockGrid : [...s.dockGrid, [focus]], { dockOpen: true }),
          }
        }
        // within the grace window the pty is still alive — the remounting
        // Terminal re-attaches and replays; after it, a fresh shell boots
        return {
          closedStack: rest,
          terminals: [...s.terminals, top.term],
          ...gridState([...s.dockGrid, [top.term.id]], { dockOpen: true }),
        }
      }
      if (top.kind === 'thread' && top.thread) {
        return {
          closedStack: rest,
          assistantThreads: [...s.assistantThreads, top.thread],
          assistantRuntimes: top.runtime
            ? { ...s.assistantRuntimes, [top.thread.id]: top.runtime }
            : s.assistantRuntimes,
          activeThreadId: top.thread.id,
          ...gridState([...s.dockGrid, [top.thread.id]], { dockOpen: true }),
        }
      }
      if (top.kind === 'panel' && top.panel) {
        // the git panel has a FIXED id — reopening over a live one would
        // render the same card twice; focus the existing panel instead
        if (s.panels.some((p) => p.id === top.panel!.id)) {
          return {
            closedStack: rest,
            ...gridState(s.dockViews.includes(top.panel.id) ? s.dockGrid : [...s.dockGrid, [top.panel.id]], { dockOpen: true }),
          }
        }
        return {
          closedStack: rest,
          panels: [...s.panels, top.panel],
          ...gridState([...s.dockGrid, [top.panel.id]], { dockOpen: true }),
        }
      }
      return { closedStack: rest }
    }),
  setOmniOpen: (open) => set({ omniOpen: open }),
  setKeymapOverrides: (map) => set({ keymapOverrides: map }),
  sendOmniPrompt: (threadId, text) =>
    set((s) => ({
      omniPrompt: { seq: ++omniSeqCounter, threadId, text },
      activeThreadId: s.assistantThreads.some((t) => t.id === threadId) ? threadId : s.activeThreadId,
      // a prompt needs a mounted Assistant — focus layout renders no cards
      ...(s.layoutMode === 'focus' ? { layoutMode: 'studio' as const } : {}),
    })),
  clearOmniPrompt: () => set({ omniPrompt: null }),
  saveSessionTemplate: (sessionId) =>
    set((s) => {
      const group = s.sessionGroups.find((g) => g.members.includes(sessionId))?.name
      const thread = s.assistantThreads.find((t) => t.id === sessionId)
      const term = s.terminals.find((t) => t.id === sessionId)
      const tpl: SessionTemplate | null = thread
        ? { id: uid('tpl'), name: thread.name ?? thread.autoName ?? thread.agentKey, kind: 'acp', agentKey: thread.agentKey, cwd: thread.cwd, group }
        : term
          ? {
              id: uid('tpl'),
              name: term.name ?? term.autoName ?? 'Terminal',
              kind: 'terminal',
              agentKey: term.singletonKey?.startsWith('agent:') ? term.singletonKey.slice(6) : undefined,
              command: term.boot,
              cwd: term.cwd,
              group,
            }
          : null
      if (!tpl) return s
      return { sessionTemplates: [...s.sessionTemplates.filter((t) => t.name !== tpl.name), tpl] }
    }),
  removeSessionTemplate: (id) =>
    set((s) => ({ sessionTemplates: s.sessionTemplates.filter((t) => t.id !== id) })),
  openSessionTemplate: (id) => {
    const s = get()
    const tpl = s.sessionTemplates.find((t) => t.id === id)
    if (!tpl) return
    if (tpl.kind === 'acp' && tpl.agentKey) {
      s.requestNewThread(tpl.agentKey)
    } else {
      s.requestTerminal(tpl.command, {
        cwd: tpl.cwd ?? s.workspacePath ?? undefined,
        name: tpl.name,
        singletonKey: tpl.agentKey ? `agent:${tpl.agentKey}` : undefined,
        restart: !!tpl.command,
        rerun: true,
      })
    }
    if (tpl.group) {
      // the freshly opened session lands in the template's group
      queueMicrotask(() => {
        const now = get()
        const opened = now.dockViews[now.dockViews.length - 1]
        if (!opened) return
        const g = now.sessionGroups.find((x) => x.name === tpl.group)
        if (g) now.assignToGroup(opened, g.id)
        else now.createSessionGroup(tpl.group!, [opened])
      })
    }
  },
  // ── worktree sessions: spatial isolation beside the temporal checkpoints ──
  newWorktreeSession: async (agentId) => {
    const s = get()
    if (!s.workspacePath) {
      s.pushToast('info', 'Open a folder first — worktree sessions branch off the workspace repo.')
      return
    }
    const taskId = uid('wt')
    const r = await bridge.worktree.create({ repo: s.workspacePath, taskId })
    if (!r.ok || !r.path) {
      s.pushToast('error', r.message ?? 'Could not create a worktree.')
      return
    }
    const agent = agentId ?? 'claude-code'
    const custom = s.customAgents.find((a) => a.id === agent)
    // claude in a worktree keeps the hooks tap — same checkpoints/feed as the
    // main claude terminal (the settings path is a sync bridge constant)
    const hooksPath = bridge.claude.settingsPath
    const wtModel = s.claudeTerminalModel !== 'default' ? ` --model '${s.claudeTerminalModel.replace(/'/g, `'\\''`)}'` : ''
    const claudeBoot = (hooksPath ? `claude --settings '${hooksPath.replace(/'/g, `'\\''`)}'` : 'claude') + wtModel
    const terminalCommand =
      custom?.kind === 'terminal'
        ? [custom.command, ...custom.args].join(' ')
        : agent === 'claude-code' ? claudeBoot
        : agent === 'amp' ? 'amp'
        : agent === 'aider' ? 'aider'
        : agent === 'goose' ? 'goose'
        : agent === 'crush' ? 'crush'
        : null
    if (terminalCommand) {
      s.requestTerminal(terminalCommand, {
        cwd: r.path,
        name: `${agent === 'claude-code' ? 'Claude' : agent} ⎇`,
        singletonKey: `wt:${taskId}`,
        restart: true,
      })
    } else {
      // ACP agents get a thread whose session cwd IS the worktree
      const id = uid('thr')
      set((st) => ({
        assistantThreads: [...st.assistantThreads, { id, agentKey: agent, busy: false, cwd: r.path }],
        activeThreadId: id,
        ...gridState([...st.dockGrid, [id]], { dockOpen: true }),
      }))
    }
    queueMicrotask(() => {
      const now = get()
      // find OUR session deterministically: the wt singleton key, or the
      // thread whose cwd IS this worktree (never "the last thread" — two
      // concurrent creations would cross-attach)
      const opened = now.terminals.find((t) => t.singletonKey === `wt:${taskId}`)?.id
        ?? now.assistantThreads.find((t) => t.cwd === r.path)?.id
      if (opened) {
        set((st) => ({
          worktreeSessions: { ...st.worktreeSessions, [opened]: { taskId, path: r.path!, branch: r.branch ?? `pz/${taskId}`, repo: s.workspacePath! } },
        }))
      }
    })
    s.pushToast('success', `Worktree ready — ${r.branch}. The agent works isolated; merge back when it's good.`)
  },
  mergeWorktreeSession: async (sessionId) => {
    const s = get()
    const wt = s.worktreeSessions[sessionId]
    if (!wt) return
    // repo rides along so main can rehydrate the worktree after a relaunch
    const fin = await bridge.worktree.finalize({ taskId: wt.taskId, message: `kaisola: merge ${wt.branch}`, repo: wt.repo })
    if (!fin.ok) {
      // a failed COMMIT must stop the merge — merging the stale branch would
      // silently drop the newest edits and still toast success
      s.pushToast('error', fin.message ?? `Could not commit the ${wt.branch} changes.`)
      return
    }
    const m = await bridge.worktree.merge({ taskId: wt.taskId, repo: wt.repo })
    if (m.ok) s.pushToast('success', `Merged ${wt.branch} back into the repo. The worktree stays until you remove it.`)
    else s.pushToast('error', m.conflicted ? `Merge conflict — resolve in the main tree, or keep working in ${wt.branch}.` : m.message ?? 'Merge failed.')
  },
  removeWorktreeSession: async (sessionId) => {
    const s = get()
    const wt = s.worktreeSessions[sessionId]
    if (!wt) return
    const r = await bridge.worktree.remove({ taskId: wt.taskId, repo: wt.repo })
    // git cleanup can fail (worktree locked, branch checked out elsewhere). Keep
    // the session AND its terminal so the user can retry, and say why — never toast
    // success while .pasola-worktrees/<taskId> + pz/<taskId> linger orphaned.
    if (!r.ok) {
      s.pushToast('error', `Couldn’t remove the ${wt.branch} worktree${r.message ? ` — ${r.message}` : ''}. Try again once nothing else is using it.`)
      return
    }
    set((st) => {
      const worktreeSessions = { ...st.worktreeSessions }
      delete worktreeSessions[sessionId]
      return { worktreeSessions }
    })
    if (s.terminals.some((t) => t.id === sessionId)) {
      s.closeTerminal(sessionId)
      void bridge.terminal.kill(sessionId)
    } else if (s.assistantThreads.some((t) => t.id === sessionId)) {
      s.closeAssistantThread(sessionId)
    }
    // the close pushed an undo entry, but its cwd was just DELETED — reopening
    // would spawn a shell into a nonexistent directory
    set((st) => ({
      closedStack: st.closedStack.filter((c) => (c.term?.id ?? c.thread?.id) !== sessionId),
    }))
    s.pushToast('success', `Removed the ${wt.branch} worktree.`)
  },
  // ── LaTeX mode ──
  // turning it off marks it dismissed so auto-detect doesn't immediately
  // reopen the bar; turning it on re-arms auto-detection
  setLatexMode: (on) => set({ latexMode: on, latexDismissed: !on }),
  setLatexMain: (workspace, path) =>
    set((s) => {
      const latexMain = { ...s.latexMain }
      if (path) latexMain[workspace] = path
      else delete latexMain[workspace]
      return { latexMain }
    }),
  openSignIn: (payload) => set({ signIn: payload }),
  closeSignIn: () => set({ signIn: null }),
  // every new agent gets its OWN card beside the current ones — add as many
  // as you want from the rail's +
  requestNewThread: (agentKey) =>
    set((s) => {
      const id = uid('thr')
      return {
        assistantThreads: [...s.assistantThreads, { id, agentKey: agentKey ?? s.agentPreset, busy: false }],
        activeThreadId: id,
        ...gridState([...s.dockGrid, [id]], { dockOpen: true }),
      }
    }),
  setActiveThread: (id) =>
    set((s) => {
      const needsYou = { ...s.needsYou }
      delete needsYou[id]
      return {
        activeThreadId: id,
        needsYou,
        ...(s.dockViews.includes(id) ? { dockOpen: true } : gridState([...s.dockGrid, [id]], { dockOpen: true })),
      }
    }),
  // closing the LAST chat thread is allowed — this is a terminal-first shell,
  // and the + menu recreates a thread in one click
  closeAssistantThread: (id) =>
    set((s) => {
      const closing = s.assistantThreads.find((t) => t.id === id)
      const next = s.assistantThreads.filter((t) => t.id !== id)
      const assistantRuntimes = { ...s.assistantRuntimes }
      const rawRuntime = assistantRuntimes[id]
      const runtime = rawRuntime ? { ...rawRuntime, archivePending: undefined } : undefined
      delete assistantRuntimes[id]
      const assistantDrafts = { ...s.assistantDrafts }
      delete assistantDrafts[id]
      const assistantPromptQueues = { ...s.assistantPromptQueues }
      delete assistantPromptQueues[id]
      const activeThreadId = s.activeThreadId === id ? next[next.length - 1]?.id ?? '' : s.activeThreadId
      const grid = gridWithout(s.dockGrid, id)
      const fallback = next[next.length - 1]?.id ?? s.terminals[0]?.id
      const needsYou = { ...s.needsYou }
      delete needsYou[id]
      return {
        assistantThreads: next,
        assistantRuntimes,
        assistantDrafts,
        assistantPromptQueues,
        activeThreadId,
        needsYou,
        closedStack: closing
          ? [{ kind: 'thread' as const, at: Date.now(), thread: { ...closing, busy: false }, runtime }, ...s.closedStack].slice(0, 8)
          : s.closedStack,
        ...(grid.length
          ? gridState(grid)
          : fallback
            ? gridState([[fallback]])
            : gridState([], { dockOpen: false })),
      }
    }),
  renameAssistantThread: (id, name) =>
    set((s) => ({ assistantThreads: s.assistantThreads.map((t) => (t.id === id ? { ...t, name: name || undefined } : t)) })),
  // the FIRST message names the thread (its topic); later messages don't churn it
  autoNameThread: (id, text, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => ({
      assistantThreads: sl.assistantThreads.map((t) =>
        t.id === id && !t.name && !t.autoName ? { ...t, autoName: titleFrom(text) } : t,
      ),
    }))
  },
  setAssistantThreadAgent: (id, agentKey) =>
    set((s) => ({ assistantThreads: s.assistantThreads.map((t) => (t.id === id ? { ...t, agentKey, acpSessionId: undefined } : t)) })),
  setThreadAcpSession: (id, sessionId, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => ({ assistantThreads: sl.assistantThreads.map((t) => (t.id === id ? { ...t, acpSessionId: sessionId } : t)) }))
  },
  setThreadClaudeEffort: (id, claudeEffort, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => ({ assistantThreads: sl.assistantThreads.map((t) => (t.id === id ? { ...t, claudeEffort } : t)) }))
  },
  setThreadCodexEffort: (id, codexEffort, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => ({ assistantThreads: sl.assistantThreads.map((t) => (t.id === id ? { ...t, codexEffort } : t)) }))
  },
  updateAssistantRuntime: (id, fn, projectId) => {
    const pid = projectId ?? get().activeProjectId
    const slice = projectFields(get(), pid)
    // A late ACP frame after its project/thread closed is ignored instead of
    // resurrecting that runtime inside whichever tab happens to be active.
    if (!slice.assistantThreads.some((thread) => thread.id === id)) return
    const current = slice.assistantRuntimes[id] ?? { turns: [], first: true }
    let next = fn(current)
    let job: { scope: { projectId: string; threadId: string; epoch?: string }; batchId: string; count: number; turns: AssistantTurn[] } | null = null
    if (next.turns.length > ASSISTANT_ARCHIVE_TRIGGER_TURNS && !next.archivePending && bridge.assistantArchive) {
      const available = Math.max(0, next.turns.length - ASSISTANT_LIVE_TURNS)
      const retryCount = next.archiveBatch?.count
      const count = retryCount && retryCount <= available ? retryCount : assistantArchiveBatchCount(next.turns)
      if (count > 0) {
        const scope = { projectId: pid, threadId: id, ...(next.archiveEpoch ? { epoch: next.archiveEpoch } : {}) }
        const turns = next.turns.slice(0, count)
        const batchId = next.archiveBatch?.id ?? assistantArchiveBatchId(scope, next.archivedTurns ?? 0, turns)
        const archiveBatch = { id: batchId, count }
        next = { ...next, archiveBatch, archivePending: true }
        job = {
          scope,
          batchId,
          count,
          turns,
        }
      }
    }
    get().patchProject(pid, (sl) => ({ assistantRuntimes: { ...sl.assistantRuntimes, [id]: next } }))
    if (!job || !bridge.assistantArchive) return
    const pending = job
    const fail = () => {
      get().patchProject(pid, (sl) => {
        const runtime = sl.assistantRuntimes[id]
        if (!runtime || runtime.archiveBatch?.id !== pending.batchId) return {}
        return { assistantRuntimes: { ...sl.assistantRuntimes, [id]: { ...runtime, archivePending: undefined } } }
      })
    }
    const submit = (attempt = 0) => {
      void bridge.assistantArchive!.append(pending.scope, pending.batchId, pending.turns).then((result) => {
        if (!result.ok || !Number.isInteger(result.count)) {
          if (result.retryable && attempt < 10) {
            const delay = Math.min(2000, 100 * (2 ** attempt))
            window.setTimeout(() => {
              const runtime = projectFields(get(), pid).assistantRuntimes[id]
              if (runtime?.archiveBatch?.id === pending.batchId && runtime.archivePending) submit(attempt + 1)
            }, delay)
          } else fail()
          return
        }
        let shouldContinue = false
        get().patchProject(pid, (sl) => {
          const runtime = sl.assistantRuntimes[id]
          if (!runtime || runtime.archiveBatch?.id !== pending.batchId) return {}
          const { archiveBatch: _batch, archivePending: _pending, ...rest } = runtime
          const next: AssistantRuntime = {
            ...rest,
            turns: runtime.turns.slice(pending.count),
            archivedTurns: result.count,
          }
          shouldContinue = next.turns.length > ASSISTANT_ARCHIVE_TRIGGER_TURNS
          return { assistantRuntimes: { ...sl.assistantRuntimes, [id]: next } }
        })
        // A burst may have grown while fsync was in flight. Drain another bounded
        // batch only after the prior ACK, keeping ordering and memory bounded.
        if (shouldContinue) queueMicrotask(() => get().updateAssistantRuntime(id, (runtime) => runtime, pid))
      }, fail)
    }
    submit()
  },
  resetAssistantRuntime: (id, projectId) => {
    const pid = projectId ?? get().activeProjectId
    const previous = projectFields(get(), pid).assistantRuntimes[id]
    const oldScope = { projectId: pid, threadId: id, ...(previous?.archiveEpoch ? { epoch: previous.archiveEpoch } : {}) }
    const clear = bridge.assistantArchive?.clear(oldScope)
    if (clear) void clear.catch(() => {})
    const archiveEpoch = uid('archive-epoch')
    get().patchProject(pid, (sl) => ({ assistantRuntimes: { ...sl.assistantRuntimes, [id]: { turns: [], first: true, archiveEpoch } } }))
  },
  setAssistantDraft: (id, patch, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => {
      const draft = normalizeAssistantDraft({ ...(sl.assistantDrafts[id] ?? emptyAssistantDraft()), ...patch })
      const assistantDrafts = { ...sl.assistantDrafts }
      if (assistantDraftIsEmpty(draft)) delete assistantDrafts[id]
      else assistantDrafts[id] = draft
      return { assistantDrafts }
    })
  },
  clearAssistantDraft: (id, opts, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => {
      const prev = normalizeAssistantDraft(sl.assistantDrafts[id])
      const next = opts?.keepSpeed ? emptyAssistantDraft(prev.speed) : emptyAssistantDraft()
      const assistantDrafts = { ...sl.assistantDrafts }
      if (assistantDraftIsEmpty(next)) delete assistantDrafts[id]
      else assistantDrafts[id] = next
      return { assistantDrafts }
    })
  },
  enqueueAssistantPrompt: (id, prompt, opts, projectId) => {
    const queued: QueuedAssistantPrompt = { ...normalizeAssistantDraft(prompt), id: uid('qp'), queuedAt: Date.now() }
    if (!queued.text.trim()) return queued.id
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => {
      const current = sl.assistantPromptQueues[id] ?? []
      const next = opts?.front ? [queued, ...current].slice(0, 20) : [...current, queued].slice(-20)
      return { assistantPromptQueues: { ...sl.assistantPromptQueues, [id]: next } }
    })
    return queued.id
  },
  dequeueAssistantPrompt: (id, projectId) => {
    const pid = projectId ?? get().activeProjectId
    const queue = projectFields(get(), pid).assistantPromptQueues[id] ?? []
    const [next, ...rest] = queue
    if (!next) return undefined
    get().patchProject(pid, (sl) => {
      const assistantPromptQueues = { ...sl.assistantPromptQueues }
      if (rest.length) assistantPromptQueues[id] = rest
      else delete assistantPromptQueues[id]
      return { assistantPromptQueues }
    })
    return next
  },
  takeAssistantPromptQueue: (id, projectId) => {
    const pid = projectId ?? get().activeProjectId
    const queue = [...(projectFields(get(), pid).assistantPromptQueues[id] ?? [])]
    if (!queue.length) return queue
    // Reading then clearing is atomic here: Zustand mutations are synchronous,
    // so an enqueue cannot interleave between this snapshot and patchProject.
    get().patchProject(pid, (sl) => {
      const assistantPromptQueues = { ...sl.assistantPromptQueues }
      delete assistantPromptQueues[id]
      return { assistantPromptQueues }
    })
    return queue
  },
  removeQueuedAssistantPrompt: (id, promptId) =>
    set((s) => {
      const rest = (s.assistantPromptQueues[id] ?? []).filter((p) => p.id !== promptId)
      const assistantPromptQueues = { ...s.assistantPromptQueues }
      if (rest.length) assistantPromptQueues[id] = rest
      else delete assistantPromptQueues[id]
      return { assistantPromptQueues }
    }),
  reorderAssistantThreads: (srcId, destId) =>
    set((s) => {
      if (srcId === destId) return s
      const arr = [...s.assistantThreads]
      const from = arr.findIndex((t) => t.id === srcId)
      const to = arr.findIndex((t) => t.id === destId)
      if (from < 0 || to < 0) return s
      const [moved] = arr.splice(from, 1)
      arr.splice(to, 0, moved)
      return { assistantThreads: arr }
    }),
  setThreadBusy: (id, busy, projectId) => {
    const pid = projectId ?? get().activeProjectId
    get().patchProject(pid, (sl) => ({ assistantThreads: sl.assistantThreads.map((t) => (t.id === id ? { ...t, busy } : t)) }))
  },
  setSettingsOpen: (open, pane) => set({ settingsOpen: open, settingsPane: open ? pane ?? null : null }),
  setAgentPreset: (id) => set({ agentPreset: id }),
  setWorkspace: (path) => {
    // a new folder gets a fresh LaTeX read: mode off, auto-detect re-armed;
    // the active tab's label + accent follow the folder, and it joins recents.
    set((s) => ({
      workspacePath: path,
      fileRequest: null,
      openFilePath: null,
      fileTabs: [],
      repoCheckpoints: [],
      agentFeed: [],
      latexMode: false,
      latexDismissed: false,
      // the default shell follows the project: a pristine idle terminal (never
      // placed anywhere, running nothing) adopts the folder — bootPending makes
      // the live pty `cd` there, so the default card sits at the project root
      terminals: path
        ? s.terminals.map((t) =>
            !t.cwd && !t.boot && !t.singletonKey && !s.terminalMeta[t.id]?.running
              ? { ...t, cwd: path, bootPending: true }
              : t,
          )
        : s.terminals,
      projectTabs: s.projectTabs.map((t) =>
        t.id === s.activeProjectId ? { ...t, workspacePath: path, hue: folderHue(path ?? t.id) } : t,
      ),
    }))
    if (path) get().pushRecentProject(path)
  },
  // the rail's tree asks; the Files editor answers (it owns the dirty-confirm)
  requestFile: (path, mode, opts) =>
    set((s) => ({
      stage: 'files',
      canvasOpen: true,
      fileRequest: { path, mode, pinned: opts?.pinned, seq: (s.fileRequest?.seq ?? 0) + 1 },
    })),
  setOpenFile: (path) => set({ openFilePath: path }),
  setFileDirty: (dirty) => set({ fileDirty: dirty }),
  setFileSession: (tabs, activePath) => set({ fileTabs: tabs, openFilePath: activePath }),
  setFileTextZoom: (zoom) => set({ fileTextZoom: Math.min(2.4, Math.max(0.72, Number(zoom.toFixed(3)))) }),
  // null = reset to the default (⌘0)
  setPerfMode: (mode) => {
    document.documentElement.dataset.perf = mode
    set({ perfMode: mode })
    // persist what the NEXT window should be (transparency is creation-time;
    // Settings shows a restart chip on mismatch). solidBg = the current theme
    // bg, so an opaque window paints the right color before first render.
    const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg-0').trim()
    void bridge.windowMode({ solidWindow: mode !== 'glass', ...(/^#[0-9a-fA-F]{6}$/.test(bg) ? { solidBg: bg } : {}) }).catch(() => {})
  },
  setTabLayout: (layout) => {
    const value: TabLayout = ['shelf', 'bare', 'runway', 'flat', 'compact'].includes(layout) ? layout : 'bare'
    document.documentElement.dataset.tabLayout = value
    set({ tabLayout: value })
  },
  setTermFontSize: (size) => set({ termFontSize: size == null ? 12 : Math.min(18, Math.max(9, Math.round(size))) }),
  setTermFontFamily: (family) => set({ termFontFamily: family || 'JetBrains Mono' }),
  setTermFontWeight: (weight) => set({ termFontWeight: [400, 500, 700].includes(weight) ? weight : 500 }),
  setTermCursorColor: (color) =>
    set({ termCursorColor: color === 'auto' || /^#[0-9a-fA-F]{6}$/.test(color) ? color : 'auto' }),
  setTermBackground: (bg) => {
    const v: TermBackground = bg === 'ink' || bg === 'slate' ? bg : 'paper'
    document.documentElement.dataset.termbg = v // tokens.css keys --term-bg off this
    set({ termBackground: v })
  },
  toggleRail: () => set((s) => ({ railOpen: !s.railOpen })),

  // ── working-tree checkpoints (Zed-style restore points, via hidden git refs) ──
  snapshotWorkspace: async (label, projectId) => {
    const pid = projectId ?? get().activeProjectId
    const ws = projectFields(get(), pid).workspacePath
    if (!ws || !isDesktop) return null
    const r = await bridge.git.snapshot(ws, label)
    if (!r.ok || !r.sha) return null
    // an unchanged tree re-snapshots to the same sha — don't stack duplicates
    const head = projectFields(get(), pid).repoCheckpoints[0]
    if (head?.sha === r.sha) return head
    const ckpt: RepoCheckpoint = { id: uid('ckpt'), sha: r.sha, label, at: nowISO() }
    get().patchProject(pid, (sl) => ({ repoCheckpoints: [ckpt, ...sl.repoCheckpoints].slice(0, 40) }))
    return ckpt
  },
  restoreRepoCheckpoint: async (id) => {
    const s = get()
    const ckpt = s.repoCheckpoints.find((c) => c.id === id)
    if (!ckpt || !s.workspacePath) return
    // dry-run preview first (OpenCode's preview() pattern): say exactly what a
    // restore would do before touching a single file
    const preview = await bridge.git.changes(s.workspacePath, ckpt.sha)
    const files = preview.ok ? preview.files ?? [] : []
    if (preview.ok && files.length === 0) {
      s.pushToast('info', `Nothing to restore — the working tree already matches “${ckpt.label}”.`)
      return
    }
    if (preview.ok) {
      const n = (c: string) => files.filter((f) => f.status === c).length
      const parts = [
        n('M') && `${n('M')} modified rewound`,
        n('A') && `${n('A')} new file${n('A') === 1 ? '' : 's'} → Trash`,
        n('D') && `${n('D')} deleted brought back`,
      ].filter(Boolean)
      if (!window.confirm(`Restore “${ckpt.label}”?\n\n${files.length} file${files.length === 1 ? '' : 's'}: ${parts.join(', ')}.`)) return
    }
    // safety net: snapshot "now" first, so a restore is itself restorable
    await s.snapshotWorkspace('Before restore')
    const r = await bridge.git.restore(s.workspacePath, ckpt.sha)
    if (r.ok) {
      const total = (r.restored ?? 0) + (r.trashed ?? 0)
      s.pushToast('success', `Restored “${ckpt.label}” — ${total} file${total === 1 ? '' : 's'} rewound${r.trashed ? ` (${r.trashed} to Trash)` : ''}`)
    } else {
      s.pushToast('error', r.message ?? 'Could not restore this checkpoint.')
    }
  },
  pushAgentFeed: (item) =>
    set((s) => ({ agentFeed: [{ ...item, id: uid('feed') }, ...s.agentFeed].slice(0, 60) })),
  toggleFollowAgent: () => {
    const on = !get().followAgent
    set({ followAgent: on })
    // immediate feedback — the effect itself only shows when the agent next touches a file
    get().pushToast(
      'info',
      on
        ? 'Following the agent — files it touches open as previews'
        : 'Stopped following the agent',
    )
  },
  // every ask flows through here: sensitive files ALWAYS surface a card (rules
  // never auto-allow them); a matching allow-rule answers the rest silently
  receivePermission: (req) => {
    const s = get()
    // presence: a BLOCKED agent must surface wherever the user is looking.
    // Background-project asks badge their tab immediately (the inbox rolls
    // them up); an active-project ask on a put-away thread gets the amber
    // dot on ONE thread (the agent's active/first, not every hidden sibling).
    const surface = () => {
      const st = get()
      if (req.scope && req.scope !== st.activeProjectId) {
        st.setProjectActivity(req.scope, 'needs-you')
        return
      }
      const threadSep = req.key.lastIndexOf('::')
      const routedThreadId = threadSep >= 0 ? req.key.slice(threadSep + 2) : ''
      const exact = routedThreadId ? st.assistantThreads.find((t) => t.id === routedThreadId) : undefined
      const providerKey = threadSep >= 0 ? req.key.slice(0, threadSep) : req.key
      const mine = st.assistantThreads.filter((t) => t.agentKey === providerKey)
      const target = exact ?? mine.find((t) => t.id === st.activeThreadId) ?? mine[0]
      if (target && !st.dockViews.includes(target.id)) st.markNeedsYou(target.id)
    }
    if (requestIsSensitive(s.sensitiveGlobs, req)) {
      s.pushPermission({ ...req, sensitive: true })
      s.pushAgentFeed({ at: Date.now(), kind: 'permission', text: `⚠ ${req.agent} asks (sensitive file): ${req.title}` })
      surface() // a sensitive ask used to stall silently on hidden surfaces
      return
    }
    const rule = requestMatchesRules(s.permissionRules, s.workspacePath, req)
    if (rule) {
      void bridge.acp.respondPermission(req.permId, allowOnceAnswer(req))
      s.pushAgentFeed({ at: Date.now(), kind: 'permission', text: `Auto-allowed by rule (${ruleLabel(rule)}): ${req.title}` })
      return
    }
    s.pushPermission(req)
    s.pushAgentFeed({ at: Date.now(), kind: 'permission', text: `${req.agent} asks: ${req.title}` })
    surface()
  },
  pushPermission: (req) =>
    set((s) =>
      s.pendingPermissions.some((p) => p.permId === req.permId)
        ? s
        : { pendingPermissions: [...s.pendingPermissions, req] },
    ),
  answerPermission: (permId, answer, opts) => {
    const s = get()
    const req = s.pendingPermissions.find((p) => p.permId === permId)
    void bridge.acp.respondPermission(permId, answer)
    let remaining = s.pendingPermissions.filter((p) => p.permId !== permId)
    // a rejection stops the whole turn — cascade to the agent's other pending
    // asks instead of leaving the turn half-approved (OpenCode semantics)
    if (opts?.cascadeReject && req) {
      const siblings = remaining.filter((p) => p.key === req.key)
      for (const sib of siblings) void bridge.acp.respondPermission(sib.permId, rejectOnceAnswer(sib))
      remaining = remaining.filter((p) => p.key !== req.key)
      if (siblings.length) s.pushToast('info', `Denied — also stopped ${siblings.length} pending ask${siblings.length === 1 ? '' : 's'} from ${req.agent}.`)
    }
    set({ pendingPermissions: remaining })
  },
  // main already resolved this ask itself (5-min timeout, or the connection died
  // while it was pending) — just remove the card. Mirrors answerPermission's card
  // removal but sends NO response to main (it already has one); the needs-you dot
  // clears on view exactly as after an answer.
  dismissPermission: (permId) =>
    set((s) => ({
      pendingPermissions: s.pendingPermissions.filter((p) => p.permId !== permId),
      // the resolved event carries no project id, and App.tsx parks a NON-active
      // project's ask into its slice (projectSlices[pid].pendingPermissions), so
      // the card can live off the active flat list — clear it from every slice
      // that holds it too, or a background project's timed-out card stays stuck.
      projectSlices: Object.fromEntries(
        Object.entries(s.projectSlices).map(([id, sl]) => [
          id,
          sl.pendingPermissions?.some((p) => p.permId === permId)
            ? { ...sl, pendingPermissions: sl.pendingPermissions.filter((p) => p.permId !== permId) }
            : sl,
        ]),
      ),
    })),
  // "Always allow" = save a client-side rule, answer this ask, and
  // RETROACTIVELY resolve every other pending ask the new rule now covers
  alwaysAllowPermission: (permId) => {
    const s = get()
    const req = s.pendingPermissions.find((p) => p.permId === permId)
    if (!req || !s.workspacePath) return
    // guardrail: sensitive files can never be covered by a standing rule
    if (requestIsSensitive(s.sensitiveGlobs, req)) {
      s.pushToast('warn', 'Sensitive file — rules can’t cover it. Allow once or adjust the globs in Settings.')
      return
    }
    const derived = ruleForRequest(req)
    const exists = s.permissionRules.some(
      (r) => r.workspace === s.workspacePath && r.action === derived.action && r.resource === derived.resource,
    )
    const rule: PermissionRule = { id: uid('rule'), workspace: s.workspacePath, ...derived, at: nowISO() }
    const rules = exists ? s.permissionRules : [...s.permissionRules, rule]
    void bridge.acp.respondPermission(permId, allowOnceAnswer(req))
    const covered = s.pendingPermissions.filter(
      (p) => p.permId !== permId && requestMatchesRules(rules, s.workspacePath, p),
    )
    for (const p of covered) void bridge.acp.respondPermission(p.permId, allowOnceAnswer(p))
    set({
      permissionRules: rules,
      pendingPermissions: s.pendingPermissions.filter(
        (p) => p.permId !== permId && !covered.some((c) => c.permId === p.permId),
      ),
    })
    s.pushToast(
      'success',
      `Rule saved — always allow ${ruleLabel(derived)}${covered.length ? ` (resolved ${covered.length} pending)` : ''}`,
    )
  },
  removePermissionRule: (id) =>
    set((s) => ({ permissionRules: s.permissionRules.filter((r) => r.id !== id) })),
  setSensitiveGlobs: (globs) => {
    const clean = globs.map((g) => g.trim()).filter(Boolean)
    set({ sensitiveGlobs: clean })
    bridge.acp.setGuardrails?.(clean) // main enforces on the agents' fs channel
  },
  setUnsavedBuffer: (path, value) =>
    set((s) => {
      const next = { ...s.unsavedBuffers }
      // cap: this persists — keep it to real work, not accidental megabytes
      if (value == null || value.length > 512_000) delete next[path]
      else next[path] = value
      const keys = Object.keys(next)
      if (keys.length > 12) delete next[keys[0]]
      return { unsavedBuffers: next }
    }),
  setOutline: (items) => set({ outline: items }),
  setEditorCursorLine: (line) => set({ editorCursorLine: line }),
  requestScroll: (path, line, heading) =>
    set((s) => ({ scrollRequest: { path, line, heading, seq: (s.scrollRequest?.seq ?? 0) + 1 } })),
  addAnnotation: (a) => {
    const s = get()
    if (!s.workspacePath) return
    set({
      annotations: [
        ...s.annotations,
        { ...a, id: uid('quote'), workspace: s.workspacePath, at: nowISO() },
      ].slice(-500),
    })
    s.pushToast('success', 'Quote saved — see the rail’s Quotes section')
  },
  removeAnnotation: (id) =>
    set((s) => ({ annotations: s.annotations.filter((a) => a.id !== id) })),
  setClaudeModel: (id) => set({ claudeModel: id }),

  addPaperByUrl: async (rawUrl) => {
    const pid = get().activeProjectId // pin every write to this project, even across a mid-run switch
    const url = rawUrl.trim()
    if (!url) return
    const id = uid('pap')
    const placeholder: Paper = {
      id,
      kind: 'paper',
      title: url.replace(/^https?:\/\//, ''),
      authors: [],
      org: 'other',
      date: nowISO().slice(0, 10),
      url: url.startsWith('http') ? url : `https://${url}`,
      topics: [],
      addedAt: nowISO(),
      tags: [],
      ingestState: 'observing',
    }
    get().patchProject(pid, (sl) => ({
      project: {
        ...sl.project,
        corpus: [placeholder, ...sl.project.corpus],
        activity: [
          { id: uid('act'), agentId: 'literature', state: 'thinking', text: `Observing ${placeholder.title}…`, at: nowISO() },
          ...sl.project.activity,
        ],
      },
    }))

    const o = await observe(url)
    get().patchProject(pid, (sl) => ({
      project: {
        ...sl.project,
        corpus: sl.project.corpus.map((src) =>
          src.id === id
            ? {
                ...(src as Paper),
                title: o.title,
                authors: o.authors,
                org: o.org,
                date: o.date,
                url: o.url,
                pdfUrl: o.pdfUrl,
                arxivId: o.arxivId,
                abstract: o.abstract,
                venue: o.venue,
                citedBy: o.citedBy,
                topics: o.topics,
                ingestState: 'ready' as const,
              }
            : src,
        ),
        activity: [
          {
            id: uid('act'),
            agentId: 'literature',
            state: 'done',
            text: o.ok ? `Added “${trim(o.title)}”` : `Added link (metadata pending) “${trim(o.title)}”`,
            at: nowISO(),
          },
          ...sl.project.activity,
        ],
      },
    }))
  },

  approveProposal: (id) =>
    set((state) => {
      const proposal = state.project.proposals.find((p) => p.id === id)
      if (!proposal || proposal.status !== 'pending') return {}
      const applied = applyProposal(state.project, proposal)
      return {
        focusedProposalId: null,
        agentTasks: updateTaskForProposal(state.agentTasks, proposal, 'applied'),
        checkpoints: pushCheckpoint(state, `Before approving “${trim(proposal.title)}”`, 'approve'),
        project: {
          ...applied,
          proposals: applied.proposals.map((p) =>
            p.id === id ? { ...p, status: 'approved', resolvedAt: nowISO() } : p,
          ),
          activity: [
            { id: uid('act'), agentId: 'human', state: 'done', text: `Approved “${trim(proposal.title)}”`, at: nowISO(), proposalId: id },
            ...applied.activity,
          ],
        },
      }
    }),

  // Partial accept: the human keeps only some hunks of a text change. The
  // derived (smaller) proposal flows through the SAME applyProposal gate —
  // 'edited' is just 'approved' with a trimmed diff, never a second mutation
  // path. `keep` maps changeId → kept hunk indexes (changes not listed apply
  // whole). Only changes whose payload.patch has a field strictly equal to
  // `after` are eligible (ProposalCard enforces the same check) — otherwise
  // the applied patch and the displayed text could silently diverge.
  approveProposalPartial: (id, keep) =>
    set((state) => {
      const proposal = state.project.proposals.find((p) => p.id === id)
      if (!proposal || proposal.status !== 'pending') return {}
      const derived: Proposal = {
        ...proposal,
        changes: proposal.changes.map((c) => {
          const keptIdx = keep[c.id]
          if (!keptIdx || c.before == null || c.after == null) return c
          const after = applyHunks(c.before, lineHunks(c.before, c.after), new Set(keptIdx))
          if (after === c.after) return c
          const payload = c.payload as { id?: string; patch?: Record<string, unknown> } | undefined
          const patch = payload?.patch
          const key = patch ? Object.keys(patch).find((k) => patch[k] === c.after) : undefined
          if (!key || !payload) return c // no safe mapping — apply whole (card never offers hunks here)
          return { ...c, after, payload: { ...payload, patch: { ...patch, [key]: after } } }
        }),
      }
      const applied = applyProposal(state.project, derived)
      return {
        focusedProposalId: null,
        agentTasks: updateTaskForProposal(state.agentTasks, proposal, 'applied'),
        checkpoints: pushCheckpoint(state, `Before applying (edited) “${trim(proposal.title)}”`, 'approve'),
        project: {
          ...applied,
          proposals: applied.proposals.map((p) =>
            p.id === id ? { ...derived, status: 'edited' as const, resolvedAt: nowISO() } : p,
          ),
          activity: [
            { id: uid('act'), agentId: 'human', state: 'done', text: `Approved with edits “${trim(proposal.title)}”`, at: nowISO(), proposalId: id },
            ...applied.activity,
          ],
        },
      }
    }),

  rejectProposal: (id) => {
    const proposal = get().project.proposals.find((p) => p.id === id)
    if (!proposal || proposal.status !== 'pending') return
    // a rejected coding patch's worktree would otherwise leak forever — clean it up
    const fc = proposal.changes.find((c) => c.entityType === 'file')
    const wtp = fc?.payload as { taskId?: string; repo?: string } | undefined
    // repo rides along so main can rehydrate + clean up after a relaunch (its
    // in-memory worktrees Map is empty then) — else the worktree + branch leak
    if (wtp?.taskId) void bridge.worktree.remove({ taskId: wtp.taskId, repo: wtp.repo }).catch(() => {})
    set((state) => ({
      focusedProposalId: null,
      agentTasks: updateTaskForProposal(state.agentTasks, proposal, 'rejected'),
      project: {
        ...state.project,
        proposals: state.project.proposals.map((p) =>
          p.id === id ? { ...p, status: 'rejected', resolvedAt: nowISO() } : p,
        ),
        activity: [
          { id: uid('act'), agentId: 'human', state: 'done', text: `Rejected “${trim(proposal.title)}”`, at: nowISO(), proposalId: id },
          ...state.project.activity,
        ],
      },
    }))
  },

  restoreCheckpoint: (id) =>
    set((state) => {
      const idx = state.checkpoints.findIndex((c) => c.id === id)
      if (idx < 0) return {}
      const ckpt = state.checkpoints[idx]
      return {
        focusedProposalId: null,
        // dropping the restored checkpoint AND everything newer keeps the
        // timeline consistent — those later snapshots no longer apply.
        checkpoints: state.checkpoints.slice(idx + 1),
        project: {
          ...ckpt.snapshot,
          activity: [
            { id: uid('act'), agentId: 'human', state: 'done', text: `Restored to “${ckpt.label}”`, at: nowISO() },
            ...ckpt.snapshot.activity,
          ],
        },
      }
    }),
  undoLast: () => {
    const last = get().checkpoints[0]
    if (last) get().restoreCheckpoint(last.id)
  },

  pickWinner: (winnerId) =>
    set((state) => {
      const winner = state.project.proposals.find((p) => p.id === winnerId)
      if (!winner || winner.status !== 'pending') return {}
      const siblingIds = new Set(
        winner.groupId
          ? state.project.proposals
              .filter((p) => p.groupId === winner.groupId && p.id !== winnerId && p.status === 'pending')
              .map((p) => p.id)
          : [],
      )
      const siblingTaskIds = new Set(
        state.project.proposals
          .filter((p) => siblingIds.has(p.id) && p.taskId)
          .map((p) => p.taskId as string),
      )
      const applied = applyProposal(state.project, winner)
      const at = nowISO()
      return {
        focusedProposalId: null,
        agentTasks: state.agentTasks.map((task) =>
          task.id === winner.taskId
            ? { ...task, status: 'applied' as const, completedAt: at }
            : siblingTaskIds.has(task.id)
              ? { ...task, status: 'rejected' as const, completedAt: at }
              : task,
        ),
        // ONE checkpoint capturing the TRUE pre-decision state (so undo restores
        // the rejected alternatives), and one atomic flip of every status.
        checkpoints: pushCheckpoint(state, `Before picking “${trim(winner.title)}”`, 'approve'),
        project: {
          ...applied,
          proposals: applied.proposals.map((p) =>
            p.id === winnerId
              ? { ...p, status: 'approved' as const, resolvedAt: at }
              : siblingIds.has(p.id)
                ? { ...p, status: 'rejected' as const, resolvedAt: at }
                : p,
          ),
          activity: [
            { id: uid('act'), agentId: 'human', state: 'done', text: `Picked “${trim(winner.title)}” (rejected ${siblingIds.size} alternative${siblingIds.size === 1 ? '' : 's'})`, at, proposalId: winnerId },
            ...applied.activity,
          ],
        },
      }
    }),

  synthesizeProposals: (proposalIds) =>
    set((state) => {
      const selected = state.project.proposals.filter((p) => proposalIds.includes(p.id) && p.status === 'pending')
      if (selected.length < 2) return {}
      const groupId = selected[0].groupId
      const alreadySynthesized = groupId
        ? state.project.proposals.some((p) => p.groupId === groupId && p.agentId === 'human' && p.status === 'pending')
        : false
      if (alreadySynthesized) return {}

      const seenChanges = new Set<string>()
      const changes: Proposal['changes'] = []
      for (const proposal of selected) {
        for (const change of proposal.changes) {
          const key = `${change.kind}:${change.entityType}:${change.label}:${change.after ?? ''}:${JSON.stringify(change.payload ?? null)}`
          if (seenChanges.has(key)) continue
          seenChanges.add(key)
          changes.push({
            ...change,
            id: uid('ch'),
            reason: change.reason ?? `Merged from “${trim(proposal.title)}”.`,
          })
        }
      }

      const seenEvidence = new Set<string>()
      const evidence: Proposal['evidence'] = []
      for (const proposal of selected) {
        for (const link of proposal.evidence) {
          const key = provenanceKey(link)
          if (seenEvidence.has(key)) continue
          seenEvidence.add(key)
          evidence.push(link)
        }
      }

      const risks = Array.from(new Set(selected.flatMap((proposal) => proposal.risks ?? [])))
      const synthesis: Proposal = {
        id: uid('prop'),
        agentId: 'human',
        stage: selected[0].stage,
        groupId,
        title: `Synthesis: ${trim(selected[0].title)}`,
        summary: `Merged ${selected.length} alternatives into one reviewable option. It keeps non-duplicate changes, evidence links, and reviewer risks so you can approve a single consolidated path.`,
        changes,
        evidence,
        risks,
        status: 'pending',
        createdAt: nowISO(),
      }
      return {
        focusedProposalId: synthesis.id,
        project: {
          ...state.project,
          proposals: [...state.project.proposals, synthesis],
          activity: [
            { id: uid('act'), agentId: 'human', state: 'done', text: `Synthesized ${selected.length} proposal alternatives.`, at: nowISO(), proposalId: synthesis.id },
            ...state.project.activity,
          ],
        },
      }
    }),

  createWorktreeProposal: ({ taskId, branch, repo, agentId, patch, files }) => {
    if (!files.length) return
    const byPath = splitPatch(patch)
    const changes: Proposal['changes'] = files.map((f) => ({
      id: uid('ch'),
      kind: f.additions > 0 && f.deletions === 0 ? 'create' : f.deletions > 0 && f.additions === 0 ? 'delete' : 'update',
      entityType: 'file',
      label: f.path,
      after: byPath[f.path] ?? '',
      reason: `+${f.additions} −${f.deletions}`,
      payload: { taskId, branch, repo, path: f.path, patch: byPath[f.path] ?? '', additions: f.additions, deletions: f.deletions },
    }))
    const proposal: Proposal = {
      id: uid('prop'),
      agentId,
      stage: 'runs',
      taskId,
      title: `Coding patch: ${branch}`,
      summary: `${files.length} file${files.length > 1 ? 's' : ''} changed in an isolated worktree (${branch}). Approve to merge into your branch.`,
      changes,
      evidence: [],
      status: 'pending',
      createdAt: nowISO(),
    }
    set((s) => ({ project: { ...s.project, proposals: [...s.project.proposals, proposal] } }))
    get().pushActivity(agentId, `Coding agent proposed a ${files.length}-file patch from worktree ${branch}.`, proposal.id)
  },

  receiveMcpProposal: (ev) => {
    const a = ev.args ?? {}
    const str = (v: unknown, cap = 4000) => (typeof v === 'string' ? v.slice(0, cap) : '')
    const from = str(a.from, 60)
    let proposal: Proposal | null = null
    if (ev.kind === 'hypothesis') {
      const title = str(a.title, 200)
      const claim = str(a.claim)
      if (!title || !claim) return
      const entity: Hypothesis = {
        id: uid('hyp'), title, claim,
        why: str(a.why), mvp: str(a.mvp),
        noveltyRisk: 3, feasibility: 3, computeEstimate: '', dataNeeds: '',
        failureModes: [], closestRelatedWork: [], expectedContribution: str(a.why),
        status: 'proposed', provenance: [], trust: 'unsupported',
      }
      proposal = {
        id: uid('prop'), agentId: 'hypothesis', stage: 'ideas',
        title: `Hypothesis: ${title}`,
        summary: `${from || 'An agent'} proposed this over MCP. ${claim}`,
        changes: [{ id: uid('ch'), kind: 'create', entityType: 'hypothesis', label: title, after: claim, reason: str(a.why, 400) || 'Proposed by an agent over MCP', payload: entity }],
        evidence: [], status: 'pending', createdAt: nowISO(),
      }
    } else if (ev.kind === 'claim') {
      const label = str(a.label, 300)
      if (!label) return
      const nodeTypes = ['claim', 'method', 'dataset', 'metric', 'result', 'limitation', 'assumption', 'question', 'contradiction']
      const type = nodeTypes.includes(str(a.type, 30)) ? (str(a.type, 30) as GraphNode['type']) : 'claim'
      const entity: GraphNode = {
        id: uid('node'), type, label, detail: str(a.detail) || undefined,
        sourceIds: [], provenance: [], trust: 'unsupported',
      }
      proposal = {
        id: uid('prop'), agentId: 'literature', stage: 'claims',
        title: `Claim: ${label.slice(0, 80)}`,
        summary: `${from || 'An agent'} asserted this into the claim graph over MCP.${str(a.detail, 300) ? ` ${str(a.detail, 300)}` : ''}`,
        changes: [{ id: uid('ch'), kind: 'create', entityType: 'graph-node', label, after: str(a.detail, 400), reason: 'Asserted by an agent over MCP', payload: entity }],
        evidence: [], status: 'pending', createdAt: nowISO(),
      }
    }
    if (!proposal) return
    const p = proposal
    set((s) => ({ project: { ...s.project, proposals: [...s.project.proposals, p] } }))
    get().pushActivity(p.agentId, `${from || 'An agent'} submitted “${trim(p.title)}” for review (MCP).`, p.id)
    get().pushToast('info', `${from || 'An agent'} proposed: ${trim(p.title)} — review to apply.`)
  },

  proposeWorktreeSession: async (sessionId) => {
    const s = get()
    const wt = s.worktreeSessions[sessionId]
    if (!wt) return
    // commit whatever the agent left uncommitted, then read the branch diff
    const fin = await bridge.worktree.finalize({ taskId: wt.taskId, message: `kaisola: changes on ${wt.branch}`, repo: wt.repo })
    if (!fin.ok) {
      s.pushToast('error', fin.message ?? `Could not commit the ${wt.branch} changes.`)
      return
    }
    const df = await bridge.worktree.diff({ taskId: wt.taskId })
    if (!df.ok) { s.pushToast('error', df.message ?? 'Could not read the worktree diff.'); return }
    if (!(df.files ?? []).length) { s.pushToast('info', `No changes in ${wt.branch} yet.`); return }
    get().createWorktreeProposal({
      taskId: wt.taskId,
      branch: wt.branch,
      repo: wt.repo,
      agentId: 'coding',
      patch: df.patch ?? '',
      files: df.files ?? [],
    })
    // open the freshly created proposal in the review overlay
    const latest = get().project.proposals
    const prop = latest[latest.length - 1]
    if (prop) get().focusProposal(prop.id)
  },

  mergeWorktreeProposal: async (id) => {
    const proposal = get().project.proposals.find((p) => p.id === id)
    if (!proposal) return
    const fileChange = proposal.changes.find((c) => c.entityType === 'file')
    const wtp = fileChange?.payload as { taskId?: string; repo?: string } | undefined
    const taskId = wtp?.taskId
    if (!taskId) { get().pushActivity('coding', 'This proposal has no worktree to merge.'); return }
    // repo lets main rehydrate the worktree after a relaunch (persisted proposal,
    // empty in-memory Map) — without it merge/remove return "unknown worktree"
    const m = await bridge.worktree.merge({ taskId, repo: wtp?.repo })
    if (!m.ok) {
      get().pushActivity('coding', m.conflicted
        ? `Merge conflict on ${taskId} — resolve it in the worktree, then re-approve.`
        : `Merge failed: ${m.message ?? 'unknown error'}.`)
      get().pushToast('error', m.conflicted ? 'Merge conflict — resolve in the worktree' : 'Merge failed')
      return // leave the proposal pending
    }
    await bridge.worktree.remove({ taskId, repo: wtp?.repo })
    get().pushToast('success', `Merged “${trim(proposal.title)}”`)
    set((s) => ({
      focusedProposalId: null,
      agentTasks: updateTaskForProposal(s.agentTasks, proposal, 'applied'),
      checkpoints: pushCheckpoint(s, `Before merging “${trim(proposal.title)}”`, 'approve'),
      project: {
        ...s.project,
        proposals: s.project.proposals.map((p) => (p.id === id ? { ...p, status: 'approved', resolvedAt: nowISO() } : p)),
        activity: [
          { id: uid('act'), agentId: 'human', state: 'done', text: `Merged “${trim(proposal.title)}”`, at: nowISO(), proposalId: id },
          ...s.project.activity,
        ],
      },
    }))
  },

  pushActivity: (agentId, text, proposalId) =>
    set((state) => ({
      project: {
        ...state.project,
        activity: [{ id: uid('act'), agentId, state: 'done', text, at: nowISO(), proposalId }, ...state.project.activity],
      },
    })),

  setAgentModel: (agentId, model) =>
    set((s) => {
      const next = { ...s.agentModels }
      if (model) next[agentId] = model
      else delete next[agentId]
      return { agentModels: next }
    }),

  setReasoningProvider: (p) => set({ reasoningProvider: p }),
  setLocalBaseUrl: (url) => set({ localBaseUrl: url.trim() }),
  setLocalModel: (model) => set({ localModel: model.trim() }),
  setOpenaiBaseUrl: (url) => set({ openaiBaseUrl: url.trim() }),
  setOpenaiModel: (model) => set({ openaiModel: model.trim() }),

  runAgent: async (agentId, instruction, pid) => {
    const agent = agentById(agentId)
    if (!agent) return []
    const s = get()
    pid = pid ?? s.activeProjectId // pin writes to the origin project (default: active)
    const pf = projectFields(s, pid)
    const { project, agentRunning } = pf
    const { agentModels, reasoningProvider } = s // provider config is GLOBAL
    if (agentRunning[agentId]) return [] // already running
    let produced: string[] = []
    get().patchProject(pid, (sl) => ({ agentRunning: { ...sl.agentRunning, [agentId]: true } }))
    get().pushActivity(agentId, `${agent.meta.name} agent is thinking…`)
    try {
      const ctx: AgentContext = {
        project,
        instruction,
        contextText: buildAgentContext(project, agent.meta.stage),
      }
      // cheap OpenAI mini by default; or Codex subscription / free local / terminal agent / paid API
      const opts =
        reasoningProvider === 'anthropic'
          ? { provider: 'anthropic' as const, model: agentModels[agentId] || s.claudeModel }
          : reasoningProvider === 'codex'
            ? { provider: 'codex' as const, cwd: pf.workspacePath ?? undefined }
            : reasoningProvider === 'agent'
              ? { provider: 'agent' as const, agentKey: pf.agentPreset, cwd: pf.workspacePath ?? undefined, scope: pid }
              : reasoningProvider === 'openai'
                ? { provider: 'openai' as const, baseUrl: s.openaiBaseUrl, model: agentModels[agentId] || s.openaiModel, useStoredKey: true }
                : { provider: 'openai' as const, baseUrl: s.localBaseUrl, model: agentModels[agentId] || s.localModel }
      const { proposals, source } = await runAgentLogic(agent, ctx, opts)
      const reach =
        reasoningProvider === 'codex'
          ? 'install Codex and run `codex login` (ChatGPT) — or pick a provider in Settings'
          : reasoningProvider === 'openai'
            ? 'add your OpenAI API key in Settings → Models & API keys'
            : reasoningProvider === 'local'
              ? `start a local model (${s.localModel} at ${s.localBaseUrl}) or pick a provider in Settings`
              : reasoningProvider === 'agent'
                ? 'connect a terminal agent or pick a provider in Settings'
                : 'check your API key in Settings'
      if (proposals.length) {
        produced = proposals.map((p) => p.id)
        get().patchProject(pid, (sl) => ({ project: { ...sl.project, proposals: [...sl.project.proposals, ...proposals] } }))
        const tag = source === 'model' ? '' : ` (offline draft — ${reach})`
        get().pushActivity(agentId, `${agent.meta.name} proposed ${proposals.length} change${proposals.length > 1 ? 's' : ''}${tag}.`, proposals[0].id)
        get().pushToast('success', `${agent.meta.name} proposed ${proposals.length} change${proposals.length > 1 ? 's' : ''}`)
      } else {
        get().pushActivity(agentId, `${agent.meta.name}: nothing to propose — ${reach}.`)
      }
    } catch (err) {
      get().pushActivity(agentId, `${agent.meta.name} failed: ${String((err as Error)?.message ?? err)}`)
      get().pushToast('error', `${agent.meta.name} failed`)
    } finally {
      get().patchProject(pid, (sl) => ({ agentRunning: { ...sl.agentRunning, [agentId]: false } }))
    }
    return produced
  },

  runStageAgents: async (stage) => {
    const s = stage ?? get().stage
    const ids = agentsForStage(s)
    if (!ids.length) {
      get().pushActivity('human', `No agents are assigned to the ${s} stage.`)
      return
    }
    for (const id of ids) {
      await get().runAgent(id)
    }
  },

  enqueueAgent: (agentId, opts) => {
    const count = Math.max(1, Math.min(opts?.count ?? 1, 5)) // cap N — keep cost bounded
    const agent = agentById(agentId)
    const name = agent?.meta.name ?? agentId
    const groupId = count > 1 ? uid('grp') : undefined
    const state = get()
    const tasks: AgentTask[] = Array.from({ length: count }, (_, i) => ({
      id: uid('task'),
      agentId,
      label: count > 1 ? `${name} · alt ${i + 1}/${count}` : name,
      status: 'queued' as const,
      at: nowISO(),
      stage: agent?.meta.stage ?? state.stage,
      provider: state.reasoningProvider,
      environment: state.workspacePath ?? state.sandboxMode,
      groupId,
    }))
    // cap ONLY the resolved tail — never drop queued/running/blocked work
    set((s) => {
      const merged = [...tasks, ...s.agentTasks]
      let finished = 0
      return { agentTasks: merged.filter((t) => (t.status === 'queued' || t.status === 'running' || t.status === 'blocked' ? true : ++finished <= 40)) }
    })
    if (count > 1) get().pushActivity(agentId, `Queued best-of-${count} for ${name} — ${count} runs (drains one at a time).`)
    void get().drainAgentQueue()
  },

  enqueueStageAgents: (stage, opts) => {
    const st = stage ?? get().stage
    const ids = agentsForStage(st)
    if (!ids.length) {
      get().pushActivity('human', `No agents are assigned to the ${st} stage.`)
      return
    }
    for (const id of ids) get().enqueueAgent(id, { count: opts?.count })
  },

  drainAgentQueue: async () => {
    // pin the whole drain to the project that owns this queue — a mid-drain
    // switch must not read/write the newly-active project's tasks (risk #5).
    const pid = get().activeProjectId
    const read = () => projectFields(get(), pid)
    if (read().agentQueueRunning) return // a single worker per project — never parallel
    get().patchProject(pid, () => ({ agentQueueRunning: true }))
    try {
      for (;;) {
        // oldest queued task first (we prepend, so scan from the end)
        const list = read().agentTasks
        let task: AgentTask | undefined
        for (let i = list.length - 1; i >= 0; i--) {
          if (list[i].status === 'queued') { task = list[i]; break }
        }
        if (!task) break
        const id = task.id
        const groupId = task.groupId
        get().patchProject(pid, (sl) => ({ agentTasks: sl.agentTasks.map((t) => (t.id === id ? { ...t, status: 'running', startedAt: nowISO() } : t)) }), 'running')
        try {
          // a foreground run of the same agent may be mid-flight — runAgent's
          // busy-guard would return [] and this task would be recorded as
          // "ran, produced nothing" without ever running. Wait out the lock
          // (resetQueue stays the escape hatch for a wedged run).
          while (read().agentRunning[task.agentId]) {
            await new Promise((r) => setTimeout(r, 250))
          }
          // tag/count the EXACT proposals this run produced (by id, not by index)
          // — immune to concurrent appends (worktree patches, foreground runs).
          const producedIds = await get().runAgent(task.agentId, undefined, pid)
          get().patchProject(pid, (sl) => ({
            project: producedIds.length
              ? {
                  ...sl.project,
                  proposals: sl.project.proposals.map((p) =>
                    producedIds.includes(p.id) ? { ...p, groupId: p.groupId ?? groupId, taskId: p.taskId ?? id } : p,
                  ),
                }
              : sl.project,
            agentTasks: sl.agentTasks.map((t) =>
              t.id === id
                ? { ...t, status: producedIds.length ? 'ready' : 'applied', completedAt: nowISO(), resultCount: producedIds.length, proposalIds: producedIds }
                : t,
            ),
          }), producedIds.length ? 'needs-you' : undefined)
          // toast once, when the LAST task of a best-of-N group finishes
          if (groupId) {
            const siblings = read().agentTasks.filter((t) => t.groupId === groupId)
            const terminal = new Set<AgentTaskStatus>(['ready', 'applied', 'rejected', 'failed'])
            if (siblings.length > 1 && siblings.every((t) => terminal.has(t.status))) {
              get().pushToast('success', `Best-of-${siblings.length} ready — ${agentById(task.agentId)?.meta.name ?? task.agentId}`)
            }
          }
        } catch {
          get().patchProject(pid, (sl) => ({ agentTasks: sl.agentTasks.map((t) => (t.id === id ? { ...t, status: 'failed', completedAt: nowISO() } : t)) }), 'failed')
        }
      }
    } finally {
      get().patchProject(pid, () => ({ agentQueueRunning: false }))
    }
  },

  clearAgentTasks: () =>
    set((s) => ({ agentTasks: s.agentTasks.filter((t) => t.status === 'queued' || t.status === 'running' || t.status === 'blocked') })),
  resetQueue: () =>
    set(() => ({
      // force-clear the worker + drop every task — the escape hatch if a model
      // call hangs and wedges the single sequential drain.
      agentQueueRunning: false,
      agentTasks: [],
    })),

  pushToast: (kind, text) =>
    set((s) => {
      if (s.toasts.some((t) => t.text === text)) return {} // dedupe visible duplicates
      return { toasts: [{ id: uid('toast'), kind, text, at: nowISO() }, ...s.toasts].slice(0, 3) }
    }),
  dismissToast: (id) => set((s) => ({ toasts: s.toasts.filter((t) => t.id !== id) })),

  setAutomationsEnabled: (on) => set({ automationsEnabled: on }),
  setWordDiffs: (on) => set({ wordDiffs: on }),
  setShowCosts: (on) => set({ showCosts: on }),
  setInbox: (on) => set({ inbox: on }),
  setDraftRestore: (on) => set({ draftRestore: on }),
  setClaudeTerminalModel: (m) => set({ claudeTerminalModel: m || 'default' }),
  setClaudeFastMode: (on) => {
    set({ claudeFastMode: on })
    // rewrite the armed --settings file now — the next `claude` boot carries it
    void bridge.claude.setSettingsFlags?.(on ? { fastMode: true } : {})
  },
  setWallpaperTint: (on) => set({ wallpaperTint: on }),

  addWorkflow: (name) =>
    set((s) => ({
      workflows: [
        ...s.workflows,
        { id: uid('wf'), name: name || `Workflow ${s.workflows.length + 1}`, trigger: 'manual', steps: [{ id: uid('wfs'), kind: 'agent', ref: 'literature', count: 1 }] },
      ],
    })),
  deleteWorkflow: (id) => set((s) => ({ workflows: s.workflows.filter((w) => w.id !== id) })),
  setWorkflowTrigger: (id, trigger, stage) =>
    set((s) => ({
      workflows: s.workflows.map((w) => {
        if (w.id !== id) return w
        if (trigger !== 'on-stage') return { ...w, trigger, stage: undefined }
        // default the trigger stage to the FIRST agent step's home stage (not a
        // blanket 'corpus'), so an Ideas workflow doesn't silently arm on Corpus.
        const firstAgent = w.steps.find((st) => st.kind === 'agent')
        const guess = firstAgent ? agentById(firstAgent.ref)?.meta.stage : undefined
        return { ...w, trigger, stage: stage ?? w.stage ?? guess ?? 'corpus' }
      }),
    })),
  addWorkflowStep: (id) =>
    set((s) => ({
      workflows: s.workflows.map((w) =>
        w.id === id ? { ...w, steps: [...w.steps, { id: uid('wfs'), kind: 'agent', ref: 'novelty', count: 1 }] } : w,
      ),
    })),
  updateWorkflowStep: (wfId, stepId, patch) =>
    set((s) => ({
      workflows: s.workflows.map((w) =>
        w.id === wfId ? { ...w, steps: w.steps.map((st) => (st.id === stepId ? { ...st, ...patch } : st)) } : w,
      ),
    })),
  runWorkflow: (id) => {
    const wf = get().workflows.find((w) => w.id === id)
    if (!wf || !wf.steps.length) return
    let queued = 0
    let skipped = 0
    for (const step of wf.steps) {
      const count = Math.max(1, Math.min(step.count || 1, 5))
      if (step.kind === 'stage') { get().enqueueStageAgents(step.ref as TrajectoryStage, { count }); queued++ }
      else if (agentById(step.ref)) { get().enqueueAgent(step.ref as AgentId, { count }); queued++ }
      else skipped++ // a step whose agent was renamed/removed — skip, don't phantom-run
    }
    get().pushActivity('human',
      `Running workflow “${wf.name}” — ${queued} step${queued === 1 ? '' : 's'} queued${skipped ? `, ${skipped} skipped (unknown target)` : ''}.`)
    get().pushToast('info', `Workflow “${wf.name}” — ${queued} step${queued === 1 ? '' : 's'} queued`)
  },

  verifyCitations: async () => {
    const pid = get().activeProjectId // pin the write to the origin project
    const { project } = get()
    const papers = new Map(project.corpus.filter((s): s is Paper => s.kind === 'paper').map((p) => [p.id, p]))
    const sourceText = (id?: string) => {
      const p = id ? papers.get(id) : undefined
      // grobidText (full text via GROBID) is richest; falls back to abstract + summary
      return p ? `${p.title} ${p.abstract ?? ''} ${p.summary ?? ''} ${p.grobidText ?? ''}` : ''
    }
    let checked = 0
    let verified = 0
    // Only UPGRADE: corroborate currently-unverified citations against the source
    // we have (abstract + summary). A human/agent-verified citation was checked
    // against full text, which we cannot reproduce from an abstract — so we never
    // downgrade it here.
    const verifyLinks = async (links: ProvenanceLink[], claim: string): Promise<{ next: ProvenanceLink[]; changed: boolean }> => {
      let changed = false
      const next: ProvenanceLink[] = []
      for (const link of links) {
        if (link.kind === 'citation' && link.quote) {
          const r = await verifyCitation({ quote: link.quote, claim, sourceText: sourceText(link.sourceId) })
          const wasUnverified = !link.verified
          if (wasUnverified) checked++
          const becameVerified = wasUnverified && r.verified
          if (becameVerified) verified++
          // attach stance on every quoted citation; only UPGRADE verified. Don't
          // downgrade an already-verified citation's stance just because its full-
          // text quote isn't in the abstract we have — only (re)label when found.
          const stance = link.verified && !r.quoteFound ? link.stance : r.stance
          if (becameVerified || link.stance !== stance) changed = true
          next.push({ ...link, stance, ...(becameVerified ? { verified: true } : {}) })
        } else {
          next.push(link)
        }
      }
      return { next, changed }
    }
    let anyChanged = false
    const nodes: GraphNode[] = []
    for (const node of project.claimGraph.nodes) {
      const { next, changed } = await verifyLinks(node.provenance, `${node.label} ${node.detail ?? ''}`)
      if (changed) anyChanged = true
      nodes.push(changed ? recomputeProvenanced({ ...node, provenance: next }) : node)
    }
    const hyps: Hypothesis[] = []
    for (const h of project.hypotheses) {
      const { next, changed } = await verifyLinks(h.provenance, `${h.title}. ${h.claim}`)
      if (changed) anyChanged = true
      hyps.push(changed ? recomputeProvenanced({ ...h, provenance: next }) : h)
    }
    // also verify the manuscript's inline claims — the Manuscript "Verify" button
    // lives there, so it must actually re-check those citations.
    let msChanged = false
    const sections: typeof project.manuscript.sections = []
    for (const sec of project.manuscript.sections) {
      const claims: typeof sec.claims = []
      let secChanged = false
      for (const c of sec.claims) {
        const { next, changed } = await verifyLinks(c.provenance, c.text)
        if (changed) { secChanged = true; claims.push(recomputeProvenanced({ ...c, provenance: next })) }
        else claims.push(c)
      }
      if (secChanged) {
        msChanged = true
        anyChanged = true
        const updated = { ...sec, claims }
        sections.push({ ...updated, trust: sectionTrust(updated) })
      } else sections.push(sec)
    }
    const manuscript = msChanged ? { ...project.manuscript, sections } : project.manuscript
    get().patchProject(pid, (sl) => ({ project: { ...sl.project, claimGraph: { ...sl.project.claimGraph, nodes }, hypotheses: hyps, manuscript } }))
    const verifyMsg = checked
      ? `Corroborated ${verified}/${checked} unverified citation${checked === 1 ? '' : 's'} — quote located in the source.`
      : anyChanged
        ? 'Re-checked citations — updated stance & trust labels.'
        : 'No quoted citations to (re)check.'
    get().pushActivity('citation', verifyMsg)
    get().pushToast(checked ? 'success' : 'info', verifyMsg)
  },

  setOpenAlexMailto: (email) => set({ openAlexMailto: email.trim() }),
  setGrobidEndpoint: (url) => set({ grobidEndpoint: url.trim().replace(/\/$/, '') }),

  ingestPaperPdf: async (paperId, pid) => {
    pid = pid ?? get().activeProjectId // pin the write to the origin project
    const project = projectFields(get(), pid).project
    const grobidEndpoint = get().grobidEndpoint // GLOBAL
    const paper = project.corpus.find((s): s is Paper => s.kind === 'paper' && s.id === paperId)
    if (!paper) return
    if (!grobidEndpoint) {
      get().pushActivity('citation', 'Set a GROBID endpoint in Settings → Literature to extract PDF provenance.')
      return
    }
    if (!paper.pdfUrl) {
      get().pushActivity('citation', `${paper.title}: no PDF URL to ingest.`)
      return
    }
    get().pushActivity('citation', `Ingesting “${paper.title}” via GROBID…`)
    const r = await bridge.grobid.process({ pdfUrl: paper.pdfUrl, endpoint: grobidEndpoint })
    if (!r.ok || !r.tei) {
      get().pushActivity('citation', `GROBID: ${r.message ?? 'failed'}.`)
      return
    }
    let doc
    try {
      doc = parseTei(r.tei)
    } catch {
      get().pushActivity('citation', 'GROBID: could not parse the returned document.')
      return
    }
    let boxed = 0
    // pin any citation pointing at this paper to the PDF rectangle its quote came from
    const attachBbox = (links: ProvenanceLink[]): ProvenanceLink[] =>
      links.map((l) => {
        if (l.kind === 'citation' && l.sourceId === paperId && l.quote) {
          const s = locateQuote(doc, l.quote)
          if (s?.bbox) {
            boxed++
            return { ...l, bbox: s.bbox, locator: l.locator ?? `p.${s.bbox.page}` }
          }
        }
        return l
      })
    get().patchProject(pid, (sl) => ({
      project: {
        ...sl.project,
        corpus: sl.project.corpus.map((s) => (s.id === paperId && s.kind === 'paper' ? { ...s, grobidText: doc.fullText } : s)),
        claimGraph: { ...sl.project.claimGraph, nodes: sl.project.claimGraph.nodes.map((n) => ({ ...n, provenance: attachBbox(n.provenance) })) },
        hypotheses: sl.project.hypotheses.map((h) => ({ ...h, provenance: attachBbox(h.provenance) })),
        updatedAt: nowISO(),
      },
    }))
    get().pushActivity('citation', `Ingested “${paper.title}” — ${doc.sentences.length} sentences, ${boxed} citation${boxed === 1 ? '' : 's'} pinned to a PDF rectangle.`)
  },
  ingestAllPdfs: async () => {
    const pid = get().activeProjectId // pin every per-paper ingest to this project
    if (!get().grobidEndpoint) {
      get().pushActivity('citation', 'Set a GROBID endpoint in Settings → Literature to extract PDF provenance.')
      return
    }
    const papers = projectFields(get(), pid).project.corpus.filter((s): s is Paper => s.kind === 'paper' && !!s.pdfUrl)
    if (!papers.length) {
      get().pushActivity('citation', 'No corpus papers with a PDF to ingest.')
      return
    }
    get().pushActivity('citation', `Ingesting ${papers.length} PDF${papers.length === 1 ? '' : 's'} via GROBID…`)
    for (const p of papers) await get().ingestPaperPdf(p.id, pid)
    const ingested = projectFields(get(), pid).project.corpus.filter((s): s is Paper => s.kind === 'paper' && !!s.grobidText).length
    get().pushActivity('citation', `PDF ingestion complete — ${ingested}/${papers.length} paper${papers.length === 1 ? '' : 's'} have full text.`)
  },

  setSandboxMode: (mode) => set({ sandboxMode: mode }),

  updateCampaign: (patch) =>
    set((s) => {
      const campaign = s.project.campaign ?? defaultCampaign(s.project)
      return {
        project: {
          ...s.project,
          campaign: {
            ...campaign,
            ...patch,
            evaluator: patch.evaluator ? { ...campaign.evaluator, ...patch.evaluator } : campaign.evaluator,
            budget: patch.budget ? { ...campaign.budget, ...patch.budget } : campaign.budget,
            updatedAt: nowISO(),
          },
          updatedAt: nowISO(),
        },
      }
    }),

  promoteAttempt: (attemptId) =>
    set((s) => {
      const attempt = s.project.attempts.find((a) => a.id === attemptId)
      if (!attempt || attempt.status !== 'ready') return {}
      const at = nowISO()
      return {
        checkpoints: pushCheckpoint(s, `Before promoting attempt ${attemptId}`, 'approve'),
        project: {
          ...s.project,
          campaign: s.project.campaign
            ? { ...s.project.campaign, championAttemptId: attemptId, status: 'active', updatedAt: at }
            : s.project.campaign,
          attempts: s.project.attempts.map((a) =>
            a.id === attemptId
              ? { ...a, status: 'accepted' as const, completedAt: a.completedAt ?? at }
              : a.status === 'accepted'
                ? { ...a, status: 'rejected' as const }
                : a,
          ),
          activity: [
            { id: uid('act'), agentId: 'human', state: 'done', text: `Promoted attempt ${attemptId} as the campaign champion.`, at },
            ...s.project.activity,
          ],
          updatedAt: at,
        },
      }
    }),

  rejectAttempt: (attemptId) =>
    set((s) => {
      const attempt = s.project.attempts.find((a) => a.id === attemptId)
      if (!attempt || attempt.status !== 'ready') return {}
      const at = nowISO()
      return {
        project: {
          ...s.project,
          attempts: s.project.attempts.map((a) => (a.id === attemptId ? { ...a, status: 'rejected' as const, completedAt: a.completedAt ?? at } : a)),
          activity: [
            { id: uid('act'), agentId: 'human', state: 'done', text: `Rejected attempt ${attemptId}.`, at },
            ...s.project.activity,
          ],
          updatedAt: at,
        },
      }
    }),

  approveCompute: (planId) =>
    set((s) => ({
      project: {
        ...s.project,
        experiments: s.project.experiments.map((e) =>
          e.id === planId ? { ...e, computeApproved: true, status: e.status === 'draft' ? 'approved' : e.status } : e,
        ),
      },
    })),
  runExperiment: async (planId) => {
    const pid = get().activeProjectId // pin every write to this project, even across a mid-run switch
    const { project, autonomy, sandboxMode, workspacePath } = get()
    const plan = project.experiments.find((e) => e.id === planId)
    if (!plan) return
    // gate: real execution needs Execute/Sprint autonomy AND approved compute
    if (autonomy !== 'execute' && autonomy !== 'sprint') {
      get().pushActivity('execution', `Raise autonomy to Execute or Sprint to run “${plan.title}”.`)
      return
    }
    if (!plan.computeApproved) {
      get().pushActivity('execution', `Approve compute for “${plan.title}” before running.`)
      return
    }
    const campaign = project.campaign
    const campaignAttempts = campaign ? project.attempts.filter((a) => a.campaignId === campaign.id) : []
    if (campaign && campaignAttempts.length >= campaign.budget.maxAttempts) {
      get().pushActivity('execution', `Campaign budget exhausted — ${campaignAttempts.length}/${campaign.budget.maxAttempts} attempts are already recorded.`)
      set((s) => ({
        project: {
          ...s.project,
          campaign: s.project.campaign ? { ...s.project.campaign, status: 'paused', updatedAt: nowISO() } : s.project.campaign,
        },
      }))
      return
    }
    const runId = uid('run')
    const attemptId = campaign ? uid('attempt') : undefined
    const runNo = project.runs.filter((r) => r.experimentId === planId).length + 1
    const safeTitle = plan.title.replace(/[^\w .,:-]/g, '')
    const startedAt = nowISO()
    const placeholderCommand = `echo "Kaisola experiment: ${safeTitle}"; echo "No approved campaign command configured yet."; echo "success_rate=0.49"`
    const command =
      campaign && commandAllowed(campaign.runCommand, campaign.allowedCommands)
        ? campaign.runCommand
        : placeholderCommand
    const run: Run = {
      id: runId,
      experimentId: planId,
      label: `Run ${String(runNo).padStart(3, '0')}: ${plan.title}`,
      status: 'running',
      startedAt,
      notebook: [
        { id: uid('nb'), at: nowISO(), level: 'action', text: `Starting ${sandboxMode} sandbox for “${plan.title}”` },
        { id: uid('nb'), at: nowISO(), level: 'action', text: `$ ${command}` },
      ],
      artifacts: [],
    }
    const attempt: ExperimentAttempt | undefined = campaign && attemptId
      ? {
          id: attemptId,
          campaignId: campaign.id,
          experimentId: planId,
          runId,
          parentAttemptId: campaign.championAttemptId,
          hypothesis: project.hypotheses[0]?.claim ?? plan.title,
          command,
          patchSummary: 'Sandbox run from the campaign contract.',
          cost: campaign.budget.compute,
          confidence: 'unreplicated',
          artifactIds: [],
          status: 'running',
          createdAt: startedAt,
        }
      : undefined
    get().patchProject(pid, (sl) => ({
      project: {
        ...sl.project,
        runs: [...sl.project.runs, run],
        attempts: attempt ? [...sl.project.attempts, attempt] : sl.project.attempts,
        campaign: campaign ? { ...campaign, status: 'active', updatedAt: nowISO() } : sl.project.campaign,
        experiments: sl.project.experiments.map((e) => (e.id === planId ? { ...e, status: 'running' } : e)),
      },
    }))
    if (campaign && command === placeholderCommand) {
      get().pushActivity('execution', `Campaign command was not in the allowlist, so Kaisola used a safe placeholder for “${plan.title}”.`)
    }
    get().pushActivity('execution', `Running “${plan.title}” in the ${sandboxMode} sandbox…`)
    const appendNb = (level: NotebookLevel, text: string) =>
      get().patchProject(pid, (sl) => ({
        project: {
          ...sl.project,
          runs: sl.project.runs.map((r) =>
            r.id === runId ? { ...r, notebook: [...r.notebook, { id: uid('nb'), at: nowISO(), level, text }] } : r,
          ),
        },
      }))
    let stdout = ''
    const res = await bridge.sandbox.run(
      { mode: sandboxMode, command, cwd: workspacePath ?? undefined },
      (ev) => {
        if (ev.type === 'stdout') {
          stdout += ev.data ?? ''
          ev.data?.split('\n').filter(Boolean).forEach((l) => appendNb('observation', l))
        }
        else if (ev.type === 'stderr') ev.data?.split('\n').filter(Boolean).forEach((l) => appendNb('error', l))
      },
    )
    const metricValue = campaign ? parseMetric(stdout, campaign.evaluator.metric, campaign.evaluator.unit) : undefined
    get().patchProject(pid, (sl) => ({
      project: {
        ...sl.project,
        runs: sl.project.runs.map((r) =>
          r.id === runId
            ? { ...r, status: res.ok ? 'done' : 'failed', endedAt: nowISO(), summary: res.ok ? 'Completed in the sandbox.' : res.message ?? `Exited ${res.code}` }
            : r,
        ),
        attempts: attemptId
          ? sl.project.attempts.map((a) =>
              a.id === attemptId
                ? {
                    ...a,
                    status: res.ok ? 'ready' : 'failed',
                    completedAt: nowISO(),
                    artifactIds: sl.project.runs.find((r) => r.id === runId)?.artifacts.map((artifact) => artifact.id) ?? [],
                    metric: metricValue != null && campaign
                      ? { name: campaign.evaluator.metric, value: metricValue, unit: campaign.evaluator.unit }
                      : a.metric,
                  }
                : a,
            )
          : sl.project.attempts,
        // the plan transitions running → done once execution completes; the Run
        // record (above) holds the actual pass/fail, so it never sticks on 'running'
        experiments: sl.project.experiments.map((e) => (e.id === planId ? { ...e, status: 'done' } : e)),
      },
    }))
    get().pushActivity('execution', res.ok
      ? `“${plan.title}” finished in the ${sandboxMode} sandbox.`
      : `“${plan.title}” failed: ${res.message ?? `exit ${res.code}`}.`)
  },
  buildCitationGraph: async () => {
    const pid = get().activeProjectId // pin the write to the origin project
    const project = projectFields(get(), pid).project
    const mailto = get().openAlexMailto || undefined // GLOBAL
    const papers = project.corpus.filter((s): s is Paper => s.kind === 'paper')
    if (!papers.length) {
      get().pushActivity('literature', 'No papers in the corpus to map.')
      return
    }
    get().pushActivity('literature', `Resolving ${papers.length} papers in OpenAlex…`)
    // 1) resolve each paper's OpenAlex work (by DOI, else arXiv)
    const resolved = await Promise.all(papers.map(async (p) => {
      const doi = extractDoi(p.url ?? '') ?? extractDoi(p.pdfUrl ?? '')
      const r = doi
        ? await lookupOpenAlex(doi, mailto)
        : p.arxivId
          ? await lookupOpenAlexByArxiv(p.arxivId, mailto)
          : null
      return { id: p.id, r }
    }))
    // 2) index OpenAlex id → corpus paper id
    const oaIndex: Record<string, string> = {}
    for (const { id, r } of resolved) if (r?.openAlexId) oaIndex[r.openAlexId] = id
    // 3) write openAlexId + in-corpus references onto each paper
    const patch = new Map<string, Partial<Paper>>()
    let edges = 0
    let withRefs = 0
    for (const { id, r } of resolved) {
      if (!r) continue
      const refs = resolveReferences(r.referencedWorks ?? [], oaIndex).filter((x) => x !== id)
      patch.set(id, { openAlexId: r.openAlexId, citedBy: r.citedBy, ...(refs.length ? { references: refs } : {}) })
      if (refs.length) { withRefs++; edges += refs.length }
    }
    get().patchProject(pid, (sl) => ({
      project: {
        ...sl.project,
        corpus: sl.project.corpus.map((src) => (src.kind === 'paper' && patch.has(src.id) ? { ...src, ...patch.get(src.id) } : src)),
        updatedAt: nowISO(),
      },
    }))
    get().pushActivity('literature', `Citation graph: ${edges} in-corpus citation${edges === 1 ? '' : 's'} across ${withRefs} paper${withRefs === 1 ? '' : 's'} (via OpenAlex).`)
  },

  loadDemo: () => set((s) => ({ checkpoints: pushCheckpoint(s, 'Loaded the demo project', 'project'), project: seedProject, stage: 'files' })),
  clearProject: () => set((s) => ({ checkpoints: pushCheckpoint(s, 'Cleared the project', 'project'), project: emptyProject(), stage: 'files' })),

  // ── project tabs ─────────────────────────────────────────────────────────
  newProject: (opts) => {
    const pid = uid('proj')
    const path = opts?.path ?? null
    const focus = opts?.focus !== false
    set((s) => {
      const slice = freshSlice(pid, path)
      // blank tabs learn to count: a second concurrent workspace-less tab gets
      // "New Project 2" (persisted like any title; rename wins) — several
      // identical "New Project" labels were indistinguishable
      const blanks = s.projectTabs.filter((t) => !t.workspacePath).length
      const tab: ProjectTab = {
        id: pid,
        workspacePath: path,
        ...(path == null && blanks > 0 ? { title: `New Project ${blanks + 1}` } : {}),
        hue: folderHue(path ?? pid),
        createdAt: Date.now(),
      }
      // focus:false creates the tab in the background (its slice is parked).
      if (!focus) return { projectTabs: [...s.projectTabs, tab], projectSlices: { ...s.projectSlices, [pid]: slice } }
      // park the outgoing slice; hoist the fresh one → live flat fields.
      const outgoing = pick(s, PROJECT_SLICE_MEMORY_KEYS)
      return {
        projectTabs: [...s.projectTabs, tab],
        activeProjectId: pid,
        projectSlices: { ...s.projectSlices, [s.activeProjectId]: outgoing },
        ...slice,
        ...resetEphemeralCursors(),
        // terminalMeta / termRemounts UNTOUCHED (bucket E)
      }
    })
    if (path) get().pushRecentProject(path)
    return pid
  },
  openProjectFolder: (path) => {
    const s = get()
    const existing = s.projectTabs.find((t) => t.workspacePath === path)
    if (existing) s.switchProject(existing.id) // Chrome focus-existing
    else s.newProject({ path })
  },
  switchProject: (targetId) =>
    set((s) => {
      if (targetId === s.activeProjectId || !s.projectTabs.some((t) => t.id === targetId)) return s
      const outgoing = pick(s, PROJECT_SLICE_MEMORY_KEYS)
      const { [targetId]: incoming, ...restBg } = s.projectSlices
      const target = incoming ? { ...freshSlice(targetId), ...incoming } : freshSlice(targetId)
      return {
        activeProjectId: targetId,
        projectSlices: { ...restBg, [s.activeProjectId]: outgoing },
        projectTabs: s.projectTabs.map((t) => (t.id === targetId ? { ...t, activity: undefined } : t)),
        ...target, // hoist the target's memory slice → live flat fields
        ...resetEphemeralCursors(), // bucket F defaults; bucket E left alone
      }
    }),
  cycleProject: (dir) => {
    const s = get()
    const ids = s.projectTabs.map((t) => t.id)
    if (ids.length < 2) return
    const at = Math.max(0, ids.indexOf(s.activeProjectId))
    s.switchProject(ids[(at + dir + ids.length) % ids.length])
  },
  reorderProjects: (srcId, destId) =>
    set((s) => {
      if (srcId === destId) return s
      const arr = [...s.projectTabs]
      const from = arr.findIndex((t) => t.id === srcId)
      const to = arr.findIndex((t) => t.id === destId)
      if (from < 0 || to < 0) return s
      const [moved] = arr.splice(from, 1)
      arr.splice(to, 0, moved)
      return { projectTabs: arr }
    }),
  renameProjectTab: (id, title) =>
    set((s) => ({ projectTabs: s.projectTabs.map((t) => (t.id === id ? { ...t, title: title?.trim() || undefined } : t)) })),
  setProjectColor: (id, color) =>
    set((s) => ({ projectTabs: s.projectTabs.map((t) => (t.id === id ? { ...t, color } : t)) })),
  setProjectActivity: (id, badge) =>
    set((s) => (id === s.activeProjectId ? s : { projectTabs: s.projectTabs.map((t) => (t.id === id ? { ...t, activity: badge } : t)) })),
  closeProject: (id, opts) => {
    const s = get()
    const tab = s.projectTabs.find((t) => t.id === id)
    if (!tab) return
    const isActive = id === s.activeProjectId
    const slice = isActive ? pick(s, PROJECT_SLICE_MEMORY_KEYS) : s.projectSlices[id]
    if (!slice) return
    const ws = slice.workspacePath
    // 1) running-work confirm (skipped on force)
    if (!opts?.force) {
      const running = slice.terminals.some((t) => s.terminalMeta[t.id]?.running)
      const dirty = isActive ? s.fileDirty : false // background fileDirty was reset on switch
      const unsaved = !!ws && Object.keys(s.unsavedBuffers).some((p) => p === ws || p.startsWith(`${ws}/`))
      const busy = running || slice.agentTerminals.length > 0 || slice.agentQueueRunning || dirty || unsaved
      if (busy && !window.confirm('This project has running agents or unsaved files. Close anyway?')) return
    }
    // 2/3) grace-kill its ptys with the same 60s token guard as closeTerminal —
    // skip any that a pop-out window currently owns (risk #4).
    for (const t of slice.terminals) {
      if (poppedTerms.has(t.id)) continue
      const tid = t.id
      const token = (termCloseTokens.get(tid) ?? 0) + 1
      termCloseTokens.set(tid, token)
      window.setTimeout(() => {
        if (termCloseTokens.get(tid) !== token) return // a newer close/reopen owns it now
        termCloseTokens.delete(tid)
        if (terminalOwnerMap(get())[tid]) return // re-adopted by some tab (reopened)
        void bridge.terminal.kill(tid)
      }, 60_000)
    }
    // 4/5) drop the tab + slice; push undo; re-home if it was active.
    set((st) => {
      const projectTabs = st.projectTabs.filter((t) => t.id !== id)
      const closedProjectStack = [{ at: Date.now(), tab, slice: sanitizeSliceForPersist(slice) }, ...st.closedProjectStack].slice(0, 8)
      const projectSlices = { ...st.projectSlices }
      delete projectSlices[id]
      if (!isActive) return { projectTabs, projectSlices, closedProjectStack }
      if (projectTabs.length) {
        const idx = st.projectTabs.findIndex((t) => t.id === id)
        const neighbor = projectTabs[Math.min(idx, projectTabs.length - 1)] // right neighbor, else left
        const { [neighbor.id]: incoming, ...restBg } = projectSlices
        const target = incoming ?? freshSlice(neighbor.id)
        return {
          projectTabs: projectTabs.map((t) => (t.id === neighbor.id ? { ...t, activity: undefined } : t)),
          activeProjectId: neighbor.id,
          projectSlices: restBg,
          closedProjectStack,
          ...target,
          ...resetEphemeralCursors(),
        }
      }
      // last tab: never zero — replace with a fresh empty tab (renders the launcher)
      const pid = uid('proj')
      return {
        projectTabs: [{ id: pid, workspacePath: null, hue: folderHue(pid), createdAt: Date.now() }],
        activeProjectId: pid,
        projectSlices: {},
        closedProjectStack,
        ...freshSlice(pid),
        ...resetEphemeralCursors(),
      }
    })
  },
  reopenClosedProject: (tabId) =>
    set((s) => {
      const top = tabId ? s.closedProjectStack.find((c) => c.tab.id === tabId) : s.closedProjectStack[0]
      if (!top) return s
      const rest = s.closedProjectStack.filter((c) => c !== top)
      // cancel the pending grace-kills so live ptys re-attach (bump token → the
      // stale timer no-ops); restart-flagged terminals reboot after the grace.
      for (const t of top.slice.terminals) termCloseTokens.set(t.id, (termCloseTokens.get(t.id) ?? 0) + 1)
      const outgoing = pick(s, PROJECT_SLICE_MEMORY_KEYS)
      const tab = { ...top.tab, activity: undefined }
      const target: ProjectSliceMemory = { ...freshSlice(tab.id), ...top.slice } // persist slice + memory defaults
      return {
        closedProjectStack: rest,
        projectTabs: [...s.projectTabs.filter((t) => t.id !== tab.id), tab],
        activeProjectId: tab.id,
        projectSlices: { ...s.projectSlices, [s.activeProjectId]: outgoing },
        ...target,
        ...resetEphemeralCursors(),
      }
    }),
  // Tear a tab off into a new OS window. The ptys are main-process global, so
  // the new window re-attaches to the SAME terminals — nothing is killed here;
  // the project just changes homes (main spawns the window, which adopts).
  detachProjectToWindow: async (id, at) => {
    const s = get()
    const tab = s.projectTabs.find((t) => t.id === id)
    if (!tab || !bridge.windows?.detachProject) return
    const isActive = id === s.activeProjectId
    const slice = isActive ? pick(s, PROJECT_SLICE_MEMORY_KEYS) : s.projectSlices[id]
    if (!slice) return
    // pop-out immunity must TRAVEL with the project (the new window's
    // closeProject would otherwise reap a pop-out it doesn't know about)
    const popped = slice.terminals.filter((t) => poppedTerms.has(t.id)).map((t) => t.id)
    // ADOPT_BOOT deliberately skips rehydrating a possibly stale slot. Carry a
    // capped/sanitized copy of the real global preferences so its first frame
    // does not fall back to the default theme, glass mode, or terminal styling.
    const globals = pickGlobals(persistSnapshot(s) as unknown as Record<string, unknown>) as Record<string, unknown>
    const r = await bridge.windows.detachProject({
      tab: { ...tab, activity: undefined },
      slice: sanitizeSliceForPersist(slice),
      globals,
      at,
      popped,
      sourceTabCount: s.projectTabs.length,
    }).catch(() => null)
    if (!r?.ok) {
      if (r?.message) get().pushToast('warn', r.message)
      return
    }
    // Dragging the only tab onto empty desktop moves the existing OS window —
    // no second renderer, no state handoff, and no extra memory.
    if (r.target === 'same') return
    // remove locally WITHOUT closeProject's grace-kills and WITHOUT the undo
    // stack — the project moved, it didn't close
    let removed = false
    let sourceBecameEmpty = false
    set((st) => {
      // the tab may have been switched/closed while the invoke was in flight —
      // recompute everything from CURRENT state, never the pre-await snapshot
      if (!st.projectTabs.some((t) => t.id === id)) return st
      removed = true
      const nowActive = st.activeProjectId === id
      const projectTabs = st.projectTabs.filter((t) => t.id !== id)
      sourceBecameEmpty = projectTabs.length === 0
      const projectSlices = { ...st.projectSlices }
      delete projectSlices[id]
      if (!nowActive) return { projectTabs, projectSlices }
      if (projectTabs.length) {
        const idx = st.projectTabs.findIndex((t) => t.id === id)
        const neighbor = projectTabs[Math.min(idx, projectTabs.length - 1)]
        const { [neighbor.id]: incoming, ...restBg } = projectSlices
        const target = incoming ?? freshSlice(neighbor.id)
        return {
          projectTabs: projectTabs.map((t) => (t.id === neighbor.id ? { ...t, activity: undefined } : t)),
          activeProjectId: neighbor.id,
          projectSlices: restBg,
          ...target,
          ...resetEphemeralCursors(),
        }
      }
      // the lone tab tore off — this window keeps a fresh empty launcher tab
      const pid = uid('proj')
      return {
        projectTabs: [{ id: pid, workspacePath: null, hue: folderHue(pid), createdAt: Date.now() }],
        activeProjectId: pid,
        projectSlices: {},
        ...freshSlice(pid),
        ...resetEphemeralCursors(),
      }
    })
    // Chrome closes a detached one-tab window once that tab lands back in an
    // existing window. Clear the throwaway slot first so restart cannot revive
    // a ghost copy; main closes only after this explicit source-side commit.
    if (removed && sourceBecameEmpty && r.closeSource && ADOPT_BOOT && r.transferId) {
      await discardCurrentWindowStore()
      await bridge.windows.finishTransfer(r.transferId).catch(() => {})
    }
  },
  adoptProject: (payload) => {
    const rawTab = payload?.tab
    const slice = payload?.slice
    if (!rawTab?.id || !slice) return false
    // pop-out immunity carried over from the origin window
    for (const tid of payload.popped ?? []) poppedTerms.add(tid)
    const takeBootGlobals = adoptBootGlobalsPending
    if (takeBootGlobals) adoptBootGlobalsPending = false
    const pre = get()
    // a pristine boot (this window's lone empty launcher tab) is REPLACED,
    // Chrome-style — but its seeded terminal already spawned a real pty, and
    // dropping the tab without killing it would leak one shell per tear-off
    const preLone = pre.projectTabs.length === 1 ? pre.projectTabs[0] : null
    const prePristine = !!preLone && !preLone.workspacePath && !pre.workspacePath && pre.assistantThreads.length <= 1 && pre.terminals.length <= 1
    const doomed = prePristine ? pre.terminals.filter((t) => !poppedTerms.has(t.id)).map((t) => t.id) : []
    let adopted = false
    set((s) => {
      if (s.projectTabs.some((t) => t.id === rawTab.id)) { adopted = true; return s } // idempotent ACK
      // parity with reopen: cancel any pending grace-kills on these ptys
      for (const t of slice.terminals ?? []) termCloseTokens.set(t.id, (termCloseTokens.get(t.id) ?? 0) + 1)
      const tab = { ...rawTab, activity: undefined }
      const target: ProjectSliceMemory = { ...freshSlice(tab.id), ...slice }
      const globalPatch = globalsForAdoption(s, payload.globals, takeBootGlobals)
      const lone = s.projectTabs.length === 1 ? s.projectTabs[0] : null
      const pristine = !!lone && !lone.workspacePath && !s.workspacePath && s.assistantThreads.length <= 1 && s.terminals.length <= 1
      adopted = true
      if (pristine) {
        return {
          ...globalPatch,
          projectTabs: [tab],
          activeProjectId: tab.id,
          projectSlices: {},
          ...target,
          ...resetEphemeralCursors(),
        }
      }
      const outgoing = pick(s, PROJECT_SLICE_MEMORY_KEYS)
      const projectTabs = [...s.projectTabs]
      const before = payload.beforeId ? projectTabs.findIndex((t) => t.id === payload.beforeId) : -1
      projectTabs.splice(before >= 0 ? before : projectTabs.length, 0, tab)
      return {
        ...globalPatch,
        projectTabs,
        activeProjectId: tab.id,
        projectSlices: { ...s.projectSlices, [s.activeProjectId]: outgoing },
        ...target,
        ...resetEphemeralCursors(),
      }
    })
    for (const tid of doomed) void bridge.terminal.kill(tid)
    if (takeBootGlobals && adopted) {
      const after = get()
      document.documentElement.dataset.theme = after.theme
      document.documentElement.dataset.perf = after.perfMode
      document.documentElement.dataset.tabLayout = after.tabLayout
      document.documentElement.dataset.termbg = after.termBackground
      bridge.setAppTheme?.(after.themeMode === 'system' ? 'system' : after.theme)
    }
    if (adopted && !POP_TERMINAL_ID) flushPersistSync()
    return adopted
  },
  locateProject: (id, newPath) => {
    set((s) => {
      const projectTabs = s.projectTabs.map((t) => (t.id === id ? { ...t, workspacePath: newPath, hue: folderHue(newPath) } : t))
      if (id === s.activeProjectId) return { projectTabs, workspacePath: newPath } // keep sessions/layout
      const slice = s.projectSlices[id]
      if (!slice) return { projectTabs }
      return { projectTabs, projectSlices: { ...s.projectSlices, [id]: { ...slice, workspacePath: newPath } } }
    })
    get().pushRecentProject(newPath)
  },
  pushRecentProject: (path) =>
    set((s) => {
      if (!path) return s
      const name = path.split('/').filter(Boolean).pop() ?? path
      return { recentProjects: [{ path, name, at: Date.now() }, ...s.recentProjects.filter((r) => r.path !== path)].slice(0, 12) }
    }),
  setAgentProject: (agentKey, pid) =>
    set((s) => ({ agentProjectMap: { ...s.agentProjectMap, [agentKey]: pid ?? s.activeProjectId } })),
  patchProject: (pid, updater, badge) =>
    set((s) => {
      // active tab: its slice IS the live flat fields → write straight through.
      if (pid === s.activeProjectId) return updater(pick(s, PROJECT_SLICE_MEMORY_KEYS)) as Partial<KaisolaState>
      const slice = s.projectSlices[pid]
      if (!slice) return s // unknown/closed project — drop the write
      return {
        projectSlices: { ...s.projectSlices, [pid]: { ...slice, ...updater(slice) } },
        projectTabs: badge ? s.projectTabs.map((t) => (t.id === pid ? { ...t, activity: badge } : t)) : s.projectTabs,
      }
    }),
  }),
    {
      name: STORE_KEY,
      // v4 (2026-06-16): preserve session state across launches: chat turns,
      // file tabs, terminal/chat cards, dock layout, and file text zoom.
      // v5 (2026-07-02): 'claude-code' became a terminal-only preset — chat
      // threads still keyed to it could never connect again, so they move to
      // codex (history intact); Claude itself lives on as the terminal session.
      // v6 (2026-07-05): PROJECT TABS. The flat store became tab #1; per-project
      // state now lives in `projectSlices` (the active tab's slice IS the live
      // flat fields). migrate wraps the v5 flat state losslessly into one tab.
      // v7 (2026-07-08): ecoMode boolean → perfMode ('glass'|'painted'|'eco').
      // v8 (2026-07-08): termBackground 'paper' was the accidental DEFAULT for
      // one release (light terminal inside the dark app) — reset it to 'ink'
      // (theme-following); paper stays available as an explicit choice.
      // v9 (2026-07-10): painted glass was removed. Existing users must not be
      // shown first-run onboarding after an upgrade, so migration also marks
      // them complete; only a store that never existed starts at zero.
      // v10: layout is project-scoped, so Studio/Focus never leaks to every
      // project tab and session/canvas visibility stays internally coherent.
      version: 10,
      migrate: (persisted, version) => {
        const toV7 = (p: unknown) => {
          const rec = p as Record<string, unknown>
          if (rec && typeof rec === 'object' && !('perfMode' in rec)) {
            rec.perfMode = rec.ecoMode ? 'eco' : 'glass'
            delete rec.ecoMode
          }
          return p
        }
        const toV8 = (p: unknown) => {
          const rec = p as Record<string, unknown>
          if (rec && typeof rec === 'object' && rec.termBackground === 'paper') rec.termBackground = 'ink'
          return p
        }
        const toV9 = (p: unknown) => {
          const rec = p as Record<string, unknown>
          if (rec && typeof rec === 'object') {
            if (rec.perfMode === 'painted') rec.perfMode = 'eco'
            rec.onboardingVersion = 1
          }
          return p
        }
        const toV10 = (p: unknown) => {
          const rec = p as Record<string, any>
          if (!rec || typeof rec !== 'object') return p
          const mode = rec.layoutMode === 'focus' ? 'focus' : 'studio'
          if (rec.projectSlices && typeof rec.projectSlices === 'object') {
            for (const slice of Object.values(rec.projectSlices) as Array<Record<string, unknown>>) {
              if (slice && typeof slice === 'object' && slice.layoutMode !== 'focus' && slice.layoutMode !== 'studio') slice.layoutMode = mode
            }
          }
          delete rec.layoutMode
          return p
        }
        if (version >= 10) return persisted
        if (version === 9) return toV10(persisted)
        if (version === 8) return toV10(toV9(persisted))
        if (version === 7) return toV10(toV9(toV8(persisted)))
        if (version === 6) return toV10(toV9(toV8(toV7(persisted))))
        const flat = migrateFlatV5(persisted)
        const pid = uid('proj')
        const ws = flat.workspacePath ?? null
        const name = ws ? ws.split('/').filter(Boolean).pop() ?? 'New Project' : 'New Project'
        // fold every persisted per-project field of the old flat state onto a
        // fresh slice (fills any gaps), then prune — lossless: tab #1 keeps its
        // exact terminals (ids preserved → ptys re-attach), threads, layout.
        const base = freshSlice(pid)
        for (const k of PROJECT_SLICE_PERSIST_KEYS) {
          const v = (flat as Record<string, unknown>)[k]
          if (v !== undefined) (base as Record<string, unknown>)[k] = v
        }
        return toV10(toV9(toV8(toV7({
          ...pickGlobals(flat as Record<string, unknown>),
          // pickGlobals no longer knows ecoMode — hand it to toV7 explicitly
          ecoMode: (flat as Record<string, unknown>).ecoMode,
          projectTabs: [{ id: pid, workspacePath: ws, title: undefined, hue: folderHue(ws ?? pid), createdAt: Date.now() }],
          activeProjectId: pid,
          projectSlices: { [pid]: sanitizeSliceForPersist(base) },
          recentProjects: ws ? [{ path: ws, name, at: Date.now() }] : [],
        }))))
      },
      // split the persisted blob back apart SYNCHRONOUSLY (getItem is sync → no
      // rehydration flash). Spread `current` FIRST so action fns are never
      // clobbered (risk #1), then globals, then hoist the active slice to flat.
      merge: (persisted, current) => {
        const p = persisted as Record<string, any>
        const cur = current as KaisolaState
        // pre-tab / defensive: an old flat blob, or an empty/corrupt one.
        if (!p?.projectTabs?.length) return { ...cur, ...p }
        const active: string = p.activeProjectId
        const allSlices: Record<string, ProjectSlicePersist> = p.projectSlices ?? {}
        const { [active]: activeSlice, ...bg } = allSlices
        // background slices persist only bucket A — re-seed their in-memory
        // bucket D empty so a later switch hoists a complete slice.
        const bgHydrated: Record<string, ProjectSliceMemory> = {}
        for (const [id, sl] of Object.entries(bg)) bgHydrated[id] = { ...freshSlice(id), ...freshMemory(), ...sl }
        return {
          ...cur, // defaults + ACTION FUNCTIONS (must be first)
          ...pickGlobals(p), // bucket B + C
          perfMode: p.perfMode === 'glass' ? 'glass' : 'eco',
          tabLayout: ['shelf', 'bare', 'runway', 'flat', 'compact'].includes(p.tabLayout) ? p.tabLayout : 'bare',
          // pre-themeMode blobs carried only an explicit theme — honor it rather
          // than silently flipping existing users to system-following
          themeMode: (p as { themeMode?: ThemeMode }).themeMode ?? (p as { theme?: Theme }).theme ?? 'system',
          projectTabs: p.projectTabs,
          activeProjectId: active,
          recentProjects: p.recentProjects ?? [],
          closedProjectStack: [],
          agentProjectMap: {},
          projectSlices: bgHydrated, // background tabs only
          ...freshMemory(), // bucket D seeded empty
          ...resetEphemeralCursors(), // bucket F defaults
          ...(activeSlice ?? sanitizeSliceForPersist(freshSlice(active))), // hoist active slice → flat
          terminalMeta: {},
          termRemounts: {}, // bucket E rebuilds from the poller
        }
      },
      // durable main-process store (SQLite, JSON-file fallback) on desktop;
      // localStorage on the web. getItem stays SYNC so rehydration has no flash,
      // and falls back to any existing localStorage blob (one-time migration).
      // RAW PersistStorage (no createJSONStorage): serialization is throttled
      // inside kaisolaStorage — see the PERSIST_MS note above it.
      storage: kaisolaStorage as PersistStorage<unknown>,
      // IDENTITY on purpose: zustand runs partialize on every set(), and the
      // slice walk here was a per-token tax during agent streams. The real
      // shaping (persistSnapshot) runs inside the throttled flush instead —
      // see shapePersist above kaisolaStorage.
      partialize: (s) => s,
    },
  ),
)

// Keep the bridge-level ACP scope pinned to the ACTIVE project: every acp call
// composes its wire key from this, so a Codex/Gemini session in one project
// tab can never answer (or be prompted from) another tab. Pop-out terminal
// windows have a read-only store and make no acp calls — the stale scope there
// is inert.
acpScope.current = useKaisola.getState().activeProjectId
useKaisola.subscribe((s) => {
  if (acpScope.current !== s.activeProjectId) acpScope.current = s.activeProjectId
})

const trim = (s: string) => (s.length > 48 ? `${s.slice(0, 48)}…` : s)
