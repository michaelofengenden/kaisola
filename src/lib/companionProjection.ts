import type {
  AgentTask,
  AssistantRuntime,
  AssistantThread,
  KaisolaState,
  ProjectSliceMemory,
  ProjectTab,
  TerminalSession,
} from '../store/store'
import type { AcpPermissionRequest } from './bridge'

export const COMPANION_PROJECTION_KIND = 'kaisola.companion.projection' as const

type CompanionStatus = 'idle' | 'running' | 'waiting' | 'done' | 'failed'
type ProjectSlice = KaisolaState | ProjectSliceMemory

export interface CompanionProjection {
  projectionKind: typeof COMPANION_PROJECTION_KIND
  revision: number
  generatedAt: number
  freshness: 'live'
  projects: Array<{
    id: string
    name: string
    repo?: string
    branch?: string
    connection: 'live'
    lastContactAt: number
  }>
  sessions: Array<{
    id: string
    projectId: string
    kind: 'agent' | 'terminal' | 'panel'
    title: string
    status: CompanionStatus
    needsYou: boolean
    unread: boolean
    updatedAt: number
    provider?: string
    model?: string
    mode?: string
    branch?: string
    summary?: string
    startedAt?: number
    turns?: Array<{ kind: 'user' | 'assistant' | 'thought' | 'tool'; text: string; status?: string; at?: number }>
  }>
  attention: Array<{
    id: string
    projectId: string
    kind: 'review' | 'blocked' | 'failed'
    title: string
    detail?: string
    createdAt: number
    severity: 'info' | 'warning' | 'critical'
  }>
  permissions: Array<{
    permId: string
    projectId: string
    sessionId?: string
    agent: string
    title: string
    kind?: string
    requestedAt: number
    options: Array<{ id: string; label: string }>
    diffs: Array<{ relativePath: string; oldText: string; newText: string }>
  }>
}

const display = (value: unknown, fallback: string, max = 240): string => {
  if (typeof value !== 'string') return fallback
  const clean = value.replace(/[\0\x08\x0b\x0c\x0e-\x1f\x7f]/g, '').trim()
  return clean ? clean.slice(0, max) : fallback
}

const projectLabel = (tab: ProjectTab): string => {
  if (tab.title?.trim()) return display(tab.title, 'New Project')
  const parts = String(tab.workspacePath ?? '').split(/[\\/]/).filter(Boolean)
  return display(parts.at(-1), 'New Project')
}

const projectSlice = (state: KaisolaState, projectId: string): ProjectSlice | undefined =>
  projectId === state.activeProjectId ? state : state.projectSlices[projectId]

const timestamp = (...values: unknown[]): number => {
  for (const value of values) {
    if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) return value
    if (typeof value === 'string') {
      const parsed = Date.parse(value)
      if (Number.isSafeInteger(parsed) && parsed >= 0) return parsed
    }
  }
  return 0
}

const assistantStatus = (thread: AssistantThread, runtime: AssistantRuntime | undefined, needsYou: boolean): CompanionStatus => {
  if (needsYou) return 'waiting'
  if (thread.busy) return 'running'
  if (runtime?.lastRun?.ok === false) return 'failed'
  if (runtime?.lastRun) return 'done'
  return 'idle'
}

const terminalStatus = (
  meta: KaisolaState['terminalMeta'][string] | undefined,
  needsYou: boolean,
  activitySource: 'shell' | 'cli-agent' | 'managed-agent' = 'shell',
): CompanionStatus => {
  if (needsYou) return 'waiting'
  // Modern brokers publish agentBusy for completion notifications, but Codex
  // can pause longer than the quiet-time threshold between tool calls. A
  // recognized CLI that still owns the foreground PTY remains a live board
  // session even when that finer-grained signal has settled to false.
  const active = activitySource === 'managed-agent'
    ? meta?.running
    : activitySource === 'cli-agent'
      ? (meta?.agentBusy === true || meta?.running === true)
      : meta?.agentBusy
  if (active) return 'running'
  if (typeof meta?.lastExit === 'number') return meta.lastExit === 0 ? 'done' : 'failed'
  return 'idle'
}

const terminalProvider = (terminal: TerminalSession): string | undefined => {
  const identity = `${terminal.singletonKey ?? ''} ${terminal.name ?? ''} ${terminal.autoName ?? ''}`
  if (/claude/i.test(identity)) return 'Claude'
  if (/codex|openai/i.test(identity)) return 'Codex'
  return terminal.name ? display(terminal.name, 'Terminal', 120) : undefined
}

const terminalActivitySource = (terminal: TerminalSession): 'shell' | 'cli-agent' => {
  if (terminal.singletonKey?.startsWith('agent:')) return 'cli-agent'
  // Some package-installed CLIs own the PTY through a `node` wrapper, so the
  // broker cannot promote them from fgProcess alone. Preserve an explicit
  // Codex/Claude terminal identity as the compatibility signal; this matches
  // the terminal card's provider label and the real manually-launched shape.
  const provider = terminalProvider(terminal)
  return provider === 'Codex' || provider === 'Claude' ? 'cli-agent' : 'shell'
}

const turnProjection = (runtime: AssistantRuntime | undefined) => (runtime?.turns ?? [])
  .filter((turn) => typeof turn.text === 'string' && !!turn.text.trim())
  .slice(-40)
  .map((turn) => ({
    kind: turn.kind,
    text: display(turn.text, '', 16 * 1024),
    ...(turn.status ? { status: display(turn.status, '', 80) } : {}),
    ...(Number.isSafeInteger(turn.at) && Number(turn.at) >= 0 ? { at: Number(turn.at) } : {}),
  }))

const relativeDiffPath = (rawPath: unknown, workspacePath: string | null): string | null => {
  if (typeof rawPath !== 'string' || !rawPath.trim()) return null
  const normalized = rawPath.replace(/\\/g, '/')
  const root = String(workspacePath ?? '').replace(/\\/g, '/').replace(/\/+$/, '')
  let relative = normalized
  if (normalized.startsWith('/')) {
    if (!root || (normalized !== root && !normalized.startsWith(`${root}/`))) return null
    relative = normalized.slice(root.length).replace(/^\/+/, '')
  }
  relative = relative.replace(/^\.\//, '')
  if (!relative || relative.startsWith('/') || relative.split('/').includes('..')) return null
  return relative.slice(0, 1024)
}

const permissionProjection = (
  permission: AcpPermissionRequest,
  projectId: string,
  slice: ProjectSlice,
  tab: ProjectTab,
) => {
  const session = slice.assistantThreads.find((thread) => thread.agentKey === permission.key)
  const requestedAt = timestamp(session?.lastActivityAt, tab.createdAt)
  return {
    permId: permission.permId,
    projectId,
    ...(session ? { sessionId: session.id } : {}),
    agent: display(permission.agent, 'Agent', 120),
    title: display(permission.title, 'Permission requested'),
    ...(permission.kind ? { kind: display(permission.kind, '', 80) } : {}),
    requestedAt,
    options: (permission.options ?? []).slice(0, 12).map((option) => ({
      id: option.optionId,
      label: display(option.name, 'Option', 160),
    })),
    // Sensitive-glob content stays on the desktop even though the eventual
    // transport is encrypted. The phone may reject, but must not become a
    // second copy of credentials or private-key material.
    diffs: (permission.sensitive ? [] : permission.diffs ?? []).flatMap((diff) => {
      const relativePath = relativeDiffPath(diff.path, slice.workspacePath)
      return relativePath ? [{
        relativePath,
        oldText: display(diff.oldText, '', 16 * 1024),
        newText: display(diff.newText, '', 16 * 1024),
      }] : []
    }).slice(0, 8),
  }
}

const taskAttention = (task: AgentTask, projectId: string, fallbackAt: number): CompanionProjection['attention'][number] | null => {
  if (task.status !== 'blocked' && task.status !== 'failed' && task.status !== 'ready') return null
  return {
    id: `attention-${task.id}`,
    projectId,
    kind: task.status === 'ready' ? 'review' : task.status,
    title: display(task.label, task.status === 'ready' ? 'Review agent result' : 'Agent needs attention'),
    ...(task.blocker ? { detail: display(task.blocker, '', 240) } : {}),
    createdAt: timestamp(task.completedAt, task.startedAt, task.at, fallbackAt),
    severity: task.status === 'failed' ? 'critical' : task.status === 'blocked' ? 'warning' : 'info',
  }
}

export function buildCompanionProjection(
  state: KaisolaState,
  { revision, generatedAt }: { revision: number; generatedAt: number },
): CompanionProjection {
  const sessions: CompanionProjection['sessions'] = []
  const attention: CompanionProjection['attention'] = []
  const permissions: CompanionProjection['permissions'] = []
  const projects: CompanionProjection['projects'] = []

  for (const tab of state.projectTabs.slice(0, 64)) {
    const slice = projectSlice(state, tab.id)
    if (!slice) continue
    const terminalIds = [
      ...slice.terminals.map((terminal) => terminal.id),
      ...slice.agentTerminals.map((terminal) => terminal.terminalId),
    ]
    const projectMeta = terminalIds.map((id) => state.terminalMeta[id]).find((meta) => meta?.repo || meta?.branch)
    projects.push({
      id: tab.id,
      name: projectLabel(tab),
      ...(projectMeta?.repo ? { repo: display(projectMeta.repo, '', 240) } : {}),
      ...(projectMeta?.branch ? { branch: display(projectMeta.branch, '', 240) } : {}),
      connection: 'live',
      lastContactAt: generatedAt,
    })

    for (const thread of slice.assistantThreads) {
      if (sessions.length >= 500) break
      const runtime = slice.assistantRuntimes[thread.id]
      const needsYou = !!slice.needsYou[thread.id]
      const turns = turnProjection(runtime)
      const summary = [...turns].reverse().find((turn) => turn.kind === 'assistant' || turn.kind === 'tool')?.text
      sessions.push({
        id: thread.id,
        projectId: tab.id,
        kind: 'agent',
        title: display(thread.name ?? thread.autoName, display(thread.agentKey, 'Agent', 120)),
        status: assistantStatus(thread, runtime, needsYou),
        needsYou,
        unread: needsYou,
        updatedAt: timestamp(thread.lastActivityAt, runtime?.lastRun?.finishedAt, runtime?.lastRun?.startedAt, tab.createdAt),
        provider: display(thread.agentKey, 'Agent', 120),
        ...(thread.preferredModel ? { model: display(thread.preferredModel, '', 120) } : {}),
        ...(thread.permissionMode ? { mode: display(thread.permissionMode, '', 80) } : {}),
        ...(projectMeta?.branch ? { branch: display(projectMeta.branch, '', 240) } : {}),
        ...(summary ? { summary: display(summary, '', 240) } : {}),
        ...(runtime?.lastRun?.startedAt ? { startedAt: runtime.lastRun.startedAt } : {}),
        ...(turns.length ? { turns } : {}),
      })
    }

    const seenTerminals = new Set<string>()
    for (const terminal of slice.terminals) {
      if (sessions.length >= 500 || seenTerminals.has(terminal.id)) continue
      seenTerminals.add(terminal.id)
      const meta = state.terminalMeta[terminal.id]
      const needsYou = !!slice.needsYou[terminal.id]
      sessions.push({
        id: terminal.id,
        projectId: tab.id,
        kind: 'terminal',
        title: display(terminal.name ?? terminal.promptTitle ?? terminal.autoName, terminalProvider(terminal) ?? 'Terminal'),
        status: terminalStatus(meta, needsYou, terminalActivitySource(terminal)),
        needsYou,
        unread: needsYou,
        updatedAt: timestamp(meta?.agentCompletedAt, tab.createdAt),
        ...(terminalProvider(terminal) ? { provider: terminalProvider(terminal) } : {}),
        ...(meta?.branch ? { branch: display(meta.branch, '', 240) } : {}),
        ...(meta?.fgProcess ? { summary: display(meta.fgProcess, '', 240) } : {}),
      })
    }
    for (const terminal of slice.agentTerminals) {
      if (sessions.length >= 500 || seenTerminals.has(terminal.terminalId)) continue
      seenTerminals.add(terminal.terminalId)
      const meta = state.terminalMeta[terminal.terminalId]
      const needsYou = !!slice.needsYou[terminal.terminalId]
      sessions.push({
        id: terminal.terminalId,
        projectId: tab.id,
        kind: 'terminal',
        title: display(terminal.label, display(terminal.agentName, 'Agent terminal')),
        status: terminalStatus(meta, needsYou, 'managed-agent'),
        needsYou,
        unread: needsYou,
        updatedAt: timestamp(meta?.agentCompletedAt, tab.createdAt),
        provider: display(terminal.agentName ?? terminal.agentKey, 'Agent', 120),
        ...(meta?.branch ? { branch: display(meta.branch, '', 240) } : {}),
        ...(meta?.fgProcess ? { summary: display(meta.fgProcess, '', 240) } : {}),
      })
    }
    for (const panel of slice.panels) {
      if (sessions.length >= 500) break
      sessions.push({
        id: panel.id,
        projectId: tab.id,
        kind: 'panel',
        title: display(panel.title, panel.kind === 'ledger' ? 'Agent ledger' : panel.kind === 'git' ? 'Git changes' : 'Browser'),
        status: 'idle',
        needsYou: false,
        unread: false,
        updatedAt: tab.createdAt,
      })
    }

    for (const permission of slice.pendingPermissions.slice(0, 50)) {
      permissions.push(permissionProjection(permission, tab.id, slice, tab))
    }
    for (const task of slice.agentTasks) {
      const item = taskAttention(task, tab.id, tab.createdAt)
      if (item && attention.length < 200) attention.push(item)
    }
  }

  return {
    projectionKind: COMPANION_PROJECTION_KIND,
    revision,
    generatedAt,
    freshness: 'live',
    projects,
    sessions,
    attention,
    permissions,
  }
}

function meaningfulProjection(projection: CompanionProjection): string {
  const { revision: _revision, generatedAt: _generatedAt, freshness: _freshness, ...content } = projection
  return JSON.stringify({
    ...content,
    projects: content.projects.map(({ lastContactAt: _lastContactAt, ...project }) => project),
  })
}

export class CompanionProjectionRevisions {
  private revision = 0
  private fingerprint = ''
  private latest: CompanionProjection | null = null

  next(state: KaisolaState, generatedAt: number): CompanionProjection | null {
    const candidate = buildCompanionProjection(state, { revision: this.revision + 1, generatedAt })
    const fingerprint = meaningfulProjection(candidate)
    if (fingerprint === this.fingerprint) return null
    this.revision++
    candidate.revision = this.revision
    this.fingerprint = fingerprint
    this.latest = candidate
    return candidate
  }

  current(): CompanionProjection | null {
    return this.latest
  }
}
