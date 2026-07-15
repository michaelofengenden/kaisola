import { Fragment, memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type PointerEvent as ReactPointerEvent, type TouchEvent as ReactTouchEvent, type WheelEvent as ReactWheelEvent } from 'react'
import { createPortal } from 'react-dom'
import {
  useKaisola,
  type AssistantDraft,
  type ClaudeEffort,
  type CodexEffort,
  type AssistantMention,
  type AssistantRuntime,
  type PlanEntry,
  type ToolArtifact,
  type AssistantSpeed,
  type AssistantThread,
  type AssistantTurn,
  type QueuedAssistantPrompt,
  ASSISTANT_DRAFT_TEXT_LIMIT,
} from '../store/store'
import { bridge, type AcpUpdate, type AcpControls, type AcpPreset, type AcpAgent, type AcpPermissionRequest } from '../lib/bridge'
import { diffHunks, diffStat } from '../lib/lineDiff'
import { ruleForRequest, ruleLabel } from '../lib/permissionRules'
import { Icon } from './Icon'
import { Dropdown } from './Dropdown'
import { Markdown } from './Markdown'
import { ProviderIcon } from './ProviderIcon'
import { stageMeta } from '../lib/stages'
import { clockTime, workedTime } from '../lib/format'
import { isCurrentMeshOrchestration } from '../lib/meshPolicy'
import type { Paper } from '../domain/types'

type Turn = AssistantTurn
/** An @-mention of a project entity, attached to the next message as context. */
type Mention = AssistantMention
type Runtime = AssistantRuntime
type ControlKind = 'mode' | 'model' | 'config'
interface UiControl { id: string; name: string; category: string; value: string; options: { value: string; name: string; description?: string }[]; kind: ControlKind }

const ARCHIVED_TURN_KINDS = new Set<Turn['kind']>(['user', 'assistant', 'thought', 'tool'])

interface AssistantViewport { top: number; fromBottom: number; atBottom: boolean }
const ASSISTANT_VIEWPORTS_KEY = 'kaisola:assistant-viewports:v1'
const AGENT_USAGE_WARNING_KEY = 'kaisola:agent-usage-warning:v1'
const assistantViewports = new Map<string, AssistantViewport>()
let assistantViewportsLoaded = false
let assistantViewportTimer: number | null = null

const loadAssistantViewports = () => {
  if (assistantViewportsLoaded) return
  assistantViewportsLoaded = true
  try {
    const rows = JSON.parse(localStorage.getItem(ASSISTANT_VIEWPORTS_KEY) || '[]') as Array<[string, AssistantViewport]>
    for (const [key, value] of rows.slice(-120)) {
      if (key && Number.isFinite(value?.top) && Number.isFinite(value?.fromBottom)) assistantViewports.set(key, value)
    }
  } catch { /* a corrupt cosmetic cache must never block a transcript */ }
}

const rememberAssistantViewport = (key: string, value: AssistantViewport, flush = false) => {
  loadAssistantViewports()
  assistantViewports.delete(key)
  assistantViewports.set(key, value)
  while (assistantViewports.size > 120) assistantViewports.delete(assistantViewports.keys().next().value!)
  const persist = () => {
    assistantViewportTimer = null
    try { localStorage.setItem(ASSISTANT_VIEWPORTS_KEY, JSON.stringify([...assistantViewports])) } catch { /* storage unavailable */ }
  }
  if (assistantViewportTimer != null) window.clearTimeout(assistantViewportTimer)
  if (flush) persist()
  else assistantViewportTimer = window.setTimeout(persist, 240)
}

const assistantViewport = (key: string) => {
  loadAssistantViewports()
  return assistantViewports.get(key)
}
const autoGrow = (el: HTMLTextAreaElement) => {
  el.style.height = 'auto'
  el.style.height = `${Math.min(el.scrollHeight, 160)}px`
}
const stableTextKey = (text: string) => {
  let hash = 2166136261
  for (let index = 0; index < text.length; index++) {
    hash ^= text.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0).toString(36)
}
const turnKey = (turn: Turn) =>
  `${turn.kind}:${turn.dispatchId ?? turn.toolId ?? turn.checkpointId ?? turn.at ?? 'undated'}:${stableTextKey(turn.text)}`
// History is durable in main's append-only archive. Keep only a compact page in
// Chromium: users can page through every turn, but old prose/diffs no longer
// sit duplicated in both the renderer heap and the disk archive.
const ARCHIVE_PAGE_TURNS = 24
const MAX_ARCHIVE_VIEW_TURNS = 48
const MAX_ARCHIVE_VIEW_BYTES = 3 * 1024 * 1024
const ARCHIVE_NEAR_TOP_PX = 96
interface ArchivedRow { turn: Turn; index: number }
interface TranscriptAnchor { key: string; offset: number }
/** IPC archives are private app data, but still cross a process boundary. Keep
 * malformed/corrupt JSONL records away from render-time string operations. */
const archivedTurn = (value: unknown): Turn | null => {
  if (!value || typeof value !== 'object') return null
  const raw = value as Record<string, unknown>
  if (!ARCHIVED_TURN_KINDS.has(raw.kind as Turn['kind']) || typeof raw.text !== 'string') return null
  const kind = raw.kind as Turn['kind']
  const turn: Turn = { kind, text: raw.text.slice(0, kind === 'tool' ? 4000 : kind === 'thought' ? 160_000 : 320_000) }
  if (typeof raw.toolId === 'string') turn.toolId = raw.toolId.slice(0, 4000)
  if (typeof raw.status === 'string') turn.status = raw.status.slice(0, 200)
  if (typeof raw.at === 'number' && Number.isFinite(raw.at)) turn.at = raw.at
  if (typeof raw.thinkMs === 'number' && Number.isFinite(raw.thinkMs)) turn.thinkMs = raw.thinkMs
  if (typeof raw.checkpointId === 'string') turn.checkpointId = raw.checkpointId
  if (Array.isArray(raw.artifacts)) {
    const artifacts: ToolArtifact[] = []
    for (const item of raw.artifacts.slice(0, 8)) {
      if (!item || typeof item !== 'object') continue
      const artifact = item as Record<string, unknown>
      if (artifact.type === 'diff' && typeof artifact.path === 'string' && typeof artifact.oldText === 'string' && typeof artifact.newText === 'string') {
        artifacts.push({ type: 'diff', path: artifact.path.slice(0, 2000), oldText: artifact.oldText.slice(-200_000), newText: artifact.newText.slice(-200_000) })
      } else if (artifact.type === 'terminal' && typeof artifact.terminalId === 'string') {
        artifacts.push({ type: 'terminal', terminalId: artifact.terminalId.slice(0, 4000) })
      } else if (artifact.type === 'content' && typeof artifact.text === 'string') {
        artifacts.push({ type: 'content', text: artifact.text.slice(0, 320_000) })
      }
    }
    if (artifacts.length) turn.artifacts = artifacts
  }
  return turn
}

const boundArchivedView = (rows: ArchivedRow[]): { rows: ArchivedRow[]; truncated: boolean } => {
  const kept: ArchivedRow[] = []
  let bytes = 0
  for (const row of rows) {
    let size = 0
    try { size = new TextEncoder().encode(JSON.stringify(row.turn)).byteLength } catch { continue }
    // Rows arrive oldest → newest. Keeping the prefix deliberately evicts the
    // newest archived rows when a prepend exceeds either view cap; the live
    // transcript remains untouched and archiveGap exposes the discontinuity.
    if (kept.length >= MAX_ARCHIVE_VIEW_TURNS || bytes + size > MAX_ARCHIVE_VIEW_BYTES) return { rows: kept, truncated: true }
    kept.push(row)
    bytes += size
  }
  return { rows: kept, truncated: false }
}

const mergeArchivedRows = (older: ArchivedRow[], current: ArchivedRow[]) => {
  const byIndex = new Map<number, ArchivedRow>()
  for (const row of [...older, ...current]) if (!byIndex.has(row.index)) byIndex.set(row.index, row)
  return [...byIndex.values()].sort((a, b) => a.index - b.index)
}

const CATEGORY_ORDER: Record<string, number> = { mode: 0, model: 1, thought_level: 2, speed: 3 }
const CATEGORY_ICON: Record<string, string> = { mode: 'ShieldCheck', model: 'Box', thought_level: 'Brain', speed: 'Gauge' }
const mentionIcon = (kind: Mention['kind']): string =>
  kind === 'paper' ? 'FileText'
    : kind === 'claim' ? 'Network'
      : kind === 'hypothesis' ? 'Lightbulb'
        : kind === 'run' ? 'Terminal'
          : 'Image'
const doneStatuses = new Set(['completed', 'failed', 'cancelled', 'canceled'])
/** Streaming transcript flush cadence — ~12 renders/sec regardless of token rate. */
const STREAM_FLUSH_MS = 80
const EMPTY_DRAFT: AssistantDraft = { text: '', attachments: [], mentions: [], speed: 'default' }
const EMPTY_QUEUE: QueuedAssistantPrompt[] = []
/** Messages typed during one active turn are one piece of steering. Preserve
 * their order, de-duplicate shared context, and use the newest speed choice. */
const mergeQueuedPrompts = (queue: QueuedAssistantPrompt[]): AssistantDraft => {
  const mentionKeys = new Set<string>()
  const mergedMentions: AssistantMention[] = []
  for (const prompt of queue) {
    for (const mention of prompt.mentions) {
      const key = `${mention.kind}\u0000${mention.id}`
      if (mentionKeys.has(key)) continue
      mentionKeys.add(key)
      mergedMentions.push(mention)
      if (mergedMentions.length >= 64) break
    }
    if (mergedMentions.length >= 64) break
  }
  const orchestration = queue[queue.length - 1]?.orchestration
  const oneAttempt = orchestration && queue.every((prompt) =>
    prompt.orchestration?.groupId === orchestration.groupId &&
    prompt.orchestration?.attemptId === orchestration.attemptId,
  )
  return {
    text: queue.flatMap((prompt) => {
      const text = prompt.text.trim()
      return text ? [text] : []
    }).join('\n\n'),
    attachments: [...new Set(queue.flatMap((prompt) => prompt.attachments))].slice(0, 64),
    mentions: mergedMentions,
    speed: queue[queue.length - 1]?.speed ?? 'default',
    ...(oneAttempt ? { orchestration } : {}),
  }
}

/** Merge only one queue provenance at a time. In particular, a retry attempt
 * must never coalesce with the stopped Mesh attempt immediately ahead of it. */
const nextQueuedDispatchBatch = (queue: QueuedAssistantPrompt[]): QueuedAssistantPrompt[] => {
  const first = queue[0]
  if (!first) return []
  const marker = first.orchestration
  const compatible = (prompt: QueuedAssistantPrompt) => marker
    ? prompt.orchestration?.groupId === marker.groupId && prompt.orchestration?.attemptId === marker.attemptId && prompt.orchestration?.phase === marker.phase
    : !prompt.orchestration
  const end = queue.findIndex((prompt) => !compatible(prompt))
  return end < 0 ? queue : queue.slice(0, end)
}
const SPEED_OPTIONS = [
  { value: 'default', name: 'Default' },
  { value: 'fast', name: 'Fast' },
]
// Claude's own effort vocabulary (low/medium/high/xhigh/max), labelled the way
// the Claude app labels it — not Kaisola-invented names like "Light".
const CLAUDE_EFFORT_OPTIONS = [
  { value: 'default', name: 'Default', description: 'Use this Claude model’s default effort' },
  { value: 'low', name: 'Low', description: 'Fastest · minimal thinking' },
  { value: 'medium', name: 'Medium', description: 'Balanced thinking for routine work' },
  { value: 'high', name: 'High', description: 'Deep thinking' },
  { value: 'xhigh', name: 'Extra High', description: 'Best for coding and agentic work' },
  { value: 'max', name: 'Max', description: 'Maximum thinking · highest usage' },
]
const CODEX_EFFORT_OPTIONS = [
  { value: 'low', name: 'Light', description: 'Fastest · minimal reasoning' },
  { value: 'medium', name: 'Medium', description: 'Balanced reasoning' },
  { value: 'high', name: 'High', description: 'Deep reasoning' },
  { value: 'xhigh', name: 'Extra High', description: 'More time for difficult work' },
  { value: 'max', name: 'Ultra', description: 'Maximum reasoning available for this model' },
  { value: 'ultra', name: 'Ultra', description: 'Maximum Codex reasoning · higher usage' },
]
const isAssistantSpeed = (v: string): v is AssistantSpeed => v === 'default' || v === 'fast'
const isClaudeEffort = (v: string): v is ClaudeEffort => ['default', 'low', 'medium', 'high', 'xhigh', 'max'].includes(v)
const isCodexEffort = (v: string): v is CodexEffort => ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].includes(v)
const MAX_VISIBLE_TURN_TEXT = 320_000
const MAX_DIFF_TEXT = 200_000
const MAX_TOOL_ARTIFACTS = 8
const MAX_TOOL_ARTIFACT_CHARS = 1_500_000
const appendBounded = (current: string, chunk: string, cap = MAX_VISIBLE_TURN_TEXT) => {
  const combined = current + chunk
  if (combined.length <= cap) return combined
  const marker = '\n\n… earlier output compacted to keep this session responsive …\n\n'
  const head = Math.floor(cap * 0.58)
  return combined.slice(0, head) + marker + combined.slice(-(cap - head - marker.length))
}
const artifactChars = (artifact: ToolArtifact) =>
  (artifact.path?.length ?? 0) + (artifact.oldText?.length ?? 0) + (artifact.newText?.length ?? 0) +
  (artifact.terminalId?.length ?? 0) + (artifact.text?.length ?? 0)
const boundArtifacts = (artifacts: ToolArtifact[], preferNewest = false): ToolArtifact[] => {
  const source = preferNewest ? [...artifacts].reverse() : artifacts
  const out: ToolArtifact[] = []
  let chars = 0
  for (const artifact of source) {
    const size = artifactChars(artifact)
    if (out.length >= MAX_TOOL_ARTIFACTS || (out.length > 0 && chars + size > MAX_TOOL_ARTIFACT_CHARS)) break
    out.push(artifact)
    chars += size
  }
  return preferNewest ? out.reverse() : out
}
const speedGuidance = (speed: AssistantSpeed, nativeApplied: boolean): string => {
  if (nativeApplied) return ''
  if (speed === 'fast') return 'Kaisola speed: Fast. Prioritize a quick, concise answer and avoid broad exploration unless it is necessary.\n\n'
  return ''
}

function useProviderPopover(open: boolean, setOpen: (open: boolean) => void, button: React.RefObject<HTMLButtonElement>, panel: React.RefObject<HTMLElement>) {
  useEffect(() => {
    if (!open) return
    const onPointer = (event: MouseEvent) => {
      const target = event.target as Node
      if (!button.current?.contains(target) && !panel.current?.contains(target)) setOpen(false)
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.stopPropagation()
      setOpen(false)
      button.current?.focus()
    }
    document.addEventListener('mousedown', onPointer)
    window.addEventListener('keydown', onKey, true)
    const raf = requestAnimationFrame(() => panel.current?.querySelector<HTMLElement>('button,[tabindex="0"]')?.focus())
    return () => {
      cancelAnimationFrame(raf)
      document.removeEventListener('mousedown', onPointer)
      window.removeEventListener('keydown', onKey, true)
    }
  }, [open, setOpen, button, panel])
}

function popoverPosition(button: HTMLButtonElement | null) {
  const rect = button?.getBoundingClientRect()
  if (!rect) return { right: 12, bottom: 56 }
  const above = Math.max(120, rect.top - 14)
  const below = Math.max(120, window.innerHeight - rect.bottom - 14)
  // right-anchored to the trigger, but never pushed past the LEFT window edge
  // (the widest provider popover is 400px — clamp against it plus margins)
  const right = Math.min(Math.max(8, window.innerWidth - rect.right), Math.max(8, window.innerWidth - 416))
  return above >= below
    ? { right, bottom: Math.max(8, window.innerHeight - rect.top + 7), maxHeight: above }
    : { right, top: rect.bottom + 7, maxHeight: below }
}

function composerAddPosition(button: HTMLButtonElement | null) {
  const rect = button?.getBoundingClientRect()
  if (!rect) return { left: 12, bottom: 56, maxHeight: 420 }
  return {
    left: Math.max(8, Math.min(rect.left, window.innerWidth - 348)),
    bottom: Math.max(8, window.innerHeight - rect.top + 7),
    maxHeight: Math.max(180, rect.top - 20),
  }
}

function ComposerAddMenu({
  papers,
  sessions,
  onFiles,
  onPaper,
  onSession,
  onPlugins,
}: {
  papers: Paper[]
  sessions: AssistantThread[]
  onFiles: () => void
  onPaper: (paper: Paper) => void
  onSession: (thread: AssistantThread) => void
  onPlugins: () => void
}) {
  const [open, setOpen] = useState(false)
  const button = useRef<HTMLButtonElement>(null)
  const panel = useRef<HTMLDivElement>(null)
  useProviderPopover(open, setOpen, button, panel)
  const choose = (action: () => void) => { action(); setOpen(false) }
  return (
    <>
      <button type="button" ref={button} className="composer-tool composer-add" data-open={open || undefined} onClick={() => setOpen((value) => !value)} title="Add context" aria-label="Add files, plugins, papers, or prior sessions" aria-haspopup="menu" aria-expanded={open}>
        <Icon name="Plus" size={16} />
      </button>
      {open && createPortal(
        <div ref={panel} className="provider-pop composer-add-pop" role="menu" aria-label="Add context" style={{ position: 'fixed', ...composerAddPosition(button.current) }}>
          <div className="composer-add-label">Add</div>
          <button type="button" className="composer-add-row" role="menuitem" onClick={() => choose(onFiles)}><Icon name="Paperclip" size={15} /><span>Files</span></button>
          <button type="button" className="composer-add-row" role="menuitem" onClick={() => choose(onPlugins)}><Icon name="Blocks" size={15} /><span>Plugins and integrations</span></button>
          {papers.length > 0 && <div className="composer-add-label">Research papers</div>}
          {papers.slice(0, 6).map((paper) => (
            <button type="button" key={paper.id} className="composer-add-row" role="menuitem" onClick={() => choose(() => onPaper(paper))}><Icon name="FileText" size={15} /><span className="truncate">{paper.title}</span></button>
          ))}
          {sessions.length > 0 && <div className="composer-add-label">Prior sessions</div>}
          {sessions.slice(0, 12).map((thread) => (
            <button type="button" key={thread.id} className="composer-add-row" role="menuitem" onClick={() => choose(() => onSession(thread))}><Icon name="History" size={15} /><span className="truncate">{thread.name ?? thread.autoName ?? thread.agentKey}</span></button>
          ))}
        </div>,
        document.body,
      )}
    </>
  )
}

/**
 * One matrix for both axes of an agent: model rows × effort columns. The
 * active model's row carries a filled track to its effort — every other row
 * waits as quiet dots. Clicking a cell sets model AND effort in one gesture;
 * clicking a model name switches models and keeps the popover open. Speed
 * (codex) rides as a small segmented footer — no tabs, no lever, one surface.
 */
function ModelEffortMatrix({
  provider,
  icon,
  codexChrome,
  models,
  modelValue,
  efforts,
  effortValue,
  speed,
  onModel,
  onEffort,
  onSpeed,
}: {
  provider: string
  icon: string
  /** Keep the codex probe/test chrome classnames on the codex instance. */
  codexChrome?: boolean
  models: Array<{ value: string; name: string; description?: string }>
  modelValue: string
  efforts: Array<{ value: string; name: string; description?: string }>
  effortValue: string
  speed?: AssistantSpeed
  onModel: (value: string) => void
  onEffort: (value: string) => void
  onSpeed?: (value: string) => void
}) {
  const [open, setOpen] = useState(false)
  const button = useRef<HTMLButtonElement>(null)
  const panel = useRef<HTMLDialogElement>(null)
  useProviderPopover(open, setOpen, button, panel)
  const rows = models.length ? models : [{ value: modelValue || '__current', name: provider }]
  const effortIndex = Math.max(0, efforts.findIndex((option) => option.value === effortValue))
  const currentModel = rows.find((option) => option.value === modelValue) ?? rows[0]
  const currentEffort = efforts[effortIndex]
  const chipModel = (currentModel?.name ?? modelValue).replace(/^GPT-/i, '').replaceAll('-', ' ')
  const chooseCell = (model: string, effort: string) => {
    if (models.length && model !== modelValue) onModel(model)
    onEffort(effort)
    setOpen(false)
  }
  return (
    <>
      <button type="button" ref={button} className={`provider-summary-btn matrix-summary${codexChrome ? ' codex-summary' : ''}`} data-open={open} onClick={() => setOpen((state) => !state)} title={`${provider} model and effort`} aria-haspopup="dialog" aria-expanded={open}>
        <Icon name={icon} size={13} />
        <span>{chipModel}</span>
        <b>{currentEffort?.name ?? effortValue}</b>
        <Icon name="ChevronDown" size={12} />
      </button>
      {open && createPortal(
        <dialog open ref={panel} className={`provider-pop matrix-pop${codexChrome ? ' codex-minimal-pop' : ''}`} aria-label={`${provider} model and effort`} style={{ position: 'fixed', margin: 0, ...popoverPosition(button.current) }}>
          <div className="matrix-grid" role="grid" aria-label={`${provider} model by effort`}>
            <span className="matrix-corner" aria-hidden="true" />
            <div className="matrix-header" style={{ gridTemplateColumns: `repeat(${Math.max(1, efforts.length)}, 1fr)` }} role="row">
              {efforts.map((effort) => (
                <span key={effort.value} className="matrix-col-label" data-active={effort.value === effortValue || undefined} title={effort.description}>{effort.name}</span>
              ))}
            </div>
            {rows.map((model) => {
              const activeRow = model.value === (models.length ? modelValue : model.value)
              return (
                <Fragment key={model.value}>
                  <button
                    type="button"
                    className="matrix-model"
                    data-active={activeRow || undefined}
                    disabled={!models.length}
                    onClick={() => { if (model.value !== modelValue) onModel(model.value) }}
                    title={model.description ?? model.name}
                    aria-label={`Switch to ${model.name}`}
                  >{model.name}</button>
                  <div className="matrix-track" data-active={activeRow || undefined} style={{ gridTemplateColumns: `repeat(${Math.max(1, efforts.length)}, 1fr)` }} role="row">
                    {activeRow && efforts.length > 1 && (
                      <span className="matrix-fill" style={{ width: `${(effortIndex / (efforts.length - 1)) * 100}%` }} aria-hidden="true" />
                    )}
                    {efforts.map((effort, index) => {
                      const selected = activeRow && index === effortIndex
                      return (
                        <button
                          type="button"
                          key={effort.value}
                          className="matrix-cell"
                          data-active={selected || undefined}
                          data-past={(activeRow && index <= effortIndex) || undefined}
                          onClick={() => chooseCell(model.value, effort.value)}
                          title={`${model.name} · ${effort.name}`}
                          aria-label={`${model.name} at ${effort.name} effort`}
                          aria-checked={selected}
                          role="radio"
                        ><span /></button>
                      )
                    })}
                  </div>
                </Fragment>
              )
            })}
          </div>
          {speed !== undefined && onSpeed && (
            <div className="matrix-speed" role="radiogroup" aria-label="Response speed">
              <span className="matrix-speed-label">Speed</span>
              {SPEED_OPTIONS.map((option) => (
                <button type="button" key={option.value} role="radio" aria-checked={speed === option.value} data-active={speed === option.value || undefined} onClick={() => onSpeed(option.value)}>{option.name}</button>
              ))}
            </div>
          )}
        </dialog>,
        document.body,
      )}
    </>
  )
}

const activityKind = (text: string): { label: string; icon: string } => {
  if (/sub[-\s]?agent|delegate|task/i.test(text)) return { label: 'Subagent', icon: 'Bot' }
  if (/terminal|shell|command|exec|\bnpm\b|\bpnpm\b|\byarn\b|\bpython\b|\bnode\b|\bgit\b|\becho\b/i.test(text)) return { label: 'Command', icon: 'TerminalSquare' }
  return { label: 'Tool', icon: 'Wrench' }
}
const shortPath = (path?: string): string => {
  if (!path) return ''
  const parts = path.split('/').filter(Boolean)
  return parts[parts.length - 1] ?? path
}
/**
 * A blocked permission ask. When the tool call carries diff content, the card
 * shows the ACTUAL change (per-file hunks, +/− counts) — review the edit, not
 * a tool name. Buttons: Allow once · Always allow <pattern> (saves a client
 * rule + resolves matching pending asks) · Deny (stops the whole turn).
 */
/** One transcript row, memoized: a streaming flush re-renders only the turn
 *  that actually changed (the growing tail), not the whole transcript. */
const TurnRow = memo(function TurnRow({ t, i, agentName, showCaret, liveThinkStart, rowKey }: {
  t: Turn; i: number; agentName: string; showCaret: boolean; liveThinkStart?: number; rowKey?: string
}) {
  if (t.kind === 'tool') {
    const arts = t.artifacts ?? []
    const head = (
      <>
        <Icon name={t.status === 'completed' ? 'CheckCircle2' : t.status === 'failed' ? 'XCircle' : 'Wrench'} size={11} />
        {t.text}{t.status && t.status !== 'completed' && <span className="tool-status">{t.status}</span>}
      </>
    )
    if (!arts.length) {
      return (
        <div data-turn={i} data-transcript-row={rowKey} className={`assistant-tool tool-${t.status}`}>
          {head}
        </div>
      )
    }
    // a tool call carrying artifacts becomes a disclosure card: the one-line
    // row is the collapsed state; failures auto-expand (VS Code's ergonomic)
    return (
      <details data-turn={i} data-transcript-row={rowKey} className={`assistant-tool tool-${t.status} tool-artifacts`} open={t.status === 'failed'}>
        <summary>{head}</summary>
        <div className="tool-artifact-body">
          {arts.map((a, ai) =>
            a.type === 'diff' && a.path ? (
              <FileDiffDisclosure key={ai} path={a.path} oldText={a.oldText ?? ''} newText={a.newText ?? ''} open={arts.length === 1} />
            ) : a.type === 'terminal' && a.terminalId ? (
              <button
                type="button"
                key={ai}
                className="tool-terminal-row"
                onClick={() => {
                  const st = useKaisola.getState()
                  const known = st.agentTerminals.find((at) => at.terminalId === a.terminalId)
                  if (known) st.switchSession(known.terminalId)
                }}
                title="Open the terminal card this command ran in"
              >
                <Icon name="SquareTerminal" size={11} /> ran in a terminal
                {useKaisola.getState().agentTerminals.some((at) => at.terminalId === a.terminalId) && <span className="tool-terminal-open">open</span>}
              </button>
            ) : null,
          )}
        </div>
      </details>
    )
  }
  if (t.kind === 'thought') {
    const live = t.thinkMs == null
    return (
      // auto-expand WHILE streaming, collapse once settled; the key remount on
      // the transition hands the toggle back to the user afterwards (Zed's
      // ThinkingBlockDisplay::Auto)
      <details data-turn={i} data-transcript-row={rowKey} key={live ? 'think-live' : 'think-done'} className="assistant-thought" {...(live ? { open: true } : {})}>
        <summary>
          <Icon name="Brain" size={12} />
          {t.thinkMs != null
            ? `Thought for ${Math.max(1, Math.round(t.thinkMs / 1000))}s`
            : liveThinkStart != null
              ? `Thinking… ${Math.round((Date.now() - liveThinkStart) / 1000)}s`
              : 'Thinking'}
        </summary>
        <div className="thought-text"><Markdown text={t.text} /></div>
      </details>
    )
  }
  const userTurn = t.kind === 'user'
  return (
    <div data-turn={i} data-transcript-row={rowKey} className={`assistant-turn turn-${t.kind}`}>
      <div className="turn-head">
        <span className="turn-avatar" aria-hidden>
          {userTurn
            ? <Icon name="UserRound" size={11} />
            : <ProviderIcon provider={agentName} name={agentName} size={11} />}
        </span>
        <span className="turn-tag">
          {userTurn ? 'You' : agentName}
          {t.at != null && <span className="turn-time">{clockTime(new Date(t.at).toISOString())}</span>}
        </span>
      </div>
      <div className="turn-text">
        {t.kind === 'assistant'
          ? (t.text ? <Markdown text={t.text} /> : (showCaret ? '▌' : ''))
          : t.text}
      </div>
    </div>
  )
})

/** One file's diff as a collapsible row — shared by permission cards and
 *  tool-call artifact disclosures (same classes, one look). */
function FileDiffDisclosure({ path, oldText, newText, open }: { path: string; oldText: string; newText: string; open?: boolean }) {
  const stat = diffStat(oldText, newText)
  const hunks = diffHunks(oldText, newText)
  return (
    <details className="perm-diff" open={open}>
      <summary>
        <Icon name="FileDiff" size={12} />
        <span className="grow truncate">{shortPath(path)}</span>
        <span className="perm-diff-stat">
          {stat.add > 0 && <em className="add">+{stat.add}</em>}
          {stat.del > 0 && <em className="del">−{stat.del}</em>}
        </span>
      </summary>
      <div className="perm-diff-body">
        {hunks.map((h, hi) => (
          <div key={hi} className="perm-diff-hunk">
            {h.lines.map((l, li) => (
              <div key={li} className={`perm-diff-line ${l.kind}`}>
                <span className="perm-diff-sign">{l.kind === 'add' ? '+' : l.kind === 'del' ? '−' : ' '}</span>
                {l.text || ' '}
              </div>
            ))}
          </div>
        ))}
        {!hunks.length && <div className="perm-diff-line ctx">(no textual change)</div>}
      </div>
    </details>
  )
}

/** The agent's live plan (ACP `plan` frames) — a pinned strip above the
 *  transcript: count + current step collapsed, full checklist expanded. */
function PlanStrip({ plan }: { plan: PlanEntry[] }) {
  const done = plan.filter((e) => e.status === 'completed').length
  const current = plan.find((e) => e.status === 'in_progress') ?? plan.find((e) => e.status === 'pending')
  return (
    <details className="plan-strip">
      <summary>
        <Icon name="ListChecks" size={12} />
        <span className="plan-count">Plan · {done}/{plan.length}</span>
        {current && <span className="plan-current truncate">{current.content}</span>}
      </summary>
      <div className="plan-entries">
        {plan.map((e) => (
          <div key={`${e.priority ?? 'normal'}:${stableTextKey(e.content)}`} className={`plan-entry plan-${e.status}`}>
            <span className="plan-mark">
              {e.status === 'completed' ? <Icon name="Check" size={11} /> : e.status === 'in_progress' ? <span className="session-busy" /> : <span className="plan-dot" />}
            </span>
            <span className="truncate">{e.content}</span>
          </div>
        ))}
      </div>
    </details>
  )
}

export function PermissionCard({
  perm,
  onAllow,
  onAlways,
  onDeny,
}: {
  perm: AcpPermissionRequest
  onAllow: () => void
  onAlways: () => void
  onDeny: () => void
}) {
  const diffs = perm.diffs ?? []
  const alwaysPattern = ruleLabel(ruleForRequest(perm))
  return (
    <div className="perm-card" data-sensitive={perm.sensitive || undefined}>
      <div className="perm-card-head">
        <Icon name={perm.sensitive ? 'ShieldAlert' : 'ShieldQuestion'} size={14} />
        <span className="grow truncate">{perm.title}</span>
        {perm.sensitive && <span className="perm-card-sensitive">sensitive file</span>}
        {diffs.length > 1 && <span className="perm-card-agent">{diffs.length} files</span>}
        <span className="perm-card-agent">{perm.agent}</span>
      </div>
      {diffs.map((d) => (
        <FileDiffDisclosure key={d.path} path={d.path} oldText={d.oldText} newText={d.newText} open={diffs.length === 1} />
      ))}
      <div className="perm-card-actions">
        <button type="button" className="btn btn-primary btn-sm" onClick={onAllow}>Allow once</button>
        {!perm.sensitive && (
          <button type="button" className="btn btn-sm" onClick={onAlways} title="Saves a rule for this workspace — future matching asks are answered automatically. Manage rules in Settings → Guardrails.">
            Always allow {alwaysPattern}
          </button>
        )}
        <button type="button" className="btn btn-ghost btn-sm" onClick={onDeny} title="Also stops this agent's other pending asks">
          Deny
        </button>
      </div>
    </div>
  )
}

/** Unify the agent's declared controls (codex configOptions + standard modes/models) into dropdowns. */
function controlList(controls: AcpControls | null): UiControl[] {
  if (!controls) return []
  const list: UiControl[] = []
  for (const o of controls.configOptions) {
    const isMode = o.category === 'mode' || o.id === 'mode'
    list.push({ id: o.id, name: o.name, category: o.category ?? 'other', value: o.currentValue, options: o.options, kind: isMode ? 'mode' : 'config' })
  }
  if (controls.modes && !list.some((c) => c.kind === 'mode')) {
    list.push({ id: '__mode', name: 'Mode', category: 'mode', value: controls.modes.currentModeId, options: controls.modes.availableModes.map((m) => ({ value: m.id, name: m.name, description: m.description })), kind: 'mode' })
  }
  if (controls.models && !list.some((c) => c.category === 'model')) {
    list.push({ id: '__model', name: 'Model', category: 'model', value: controls.models.currentModelId, options: controls.models.availableModels.map((m) => ({ value: m.modelId, name: m.name, description: m.description })), kind: 'model' })
  }
  return list.sort((a, b) => (CATEGORY_ORDER[a.category] ?? 9) - (CATEGORY_ORDER[b.category] ?? 9))
}

/** A real provider speed/latency switch, not reasoning effort. Older code
 * matched effort/thought controls here too, hid them, and silently translated
 * Fast/Balanced/Deep into the provider's reasoning level. That made Codex's
 * model effort impossible to inspect independently from response speed. */
function nativeSpeedControl(controls: UiControl[]): UiControl | null {
  return controls.find((c) => {
    if (c.kind !== 'config' || c.options.length < 2) return false
    const haystack = `${c.id} ${c.name} ${c.category}`.toLowerCase()
    return /speed|latency|pace|fast.mode/.test(haystack) && !/effort|reasoning|thought|think/.test(haystack)
  }) ?? null
}

function speedOptionValue(c: UiControl, speed: AssistantSpeed): string | null {
  if (/fast[-_ ]?mode/i.test(`${c.id} ${c.name}`)) return speed === 'fast' ? 'on' : 'off'
  const want =
    speed === 'fast'
      ? /fast|quick|low|minimal|light|none|short/
      : /balanced|medium|auto|normal|standard|default|off|false/
  const hit = c.options.find((o) => want.test(`${o.value} ${o.name}`.toLowerCase()))
  if (hit) return hit.value
  if (speed === 'fast') return c.options[c.options.length - 1]?.value ?? null
  return c.options[0]?.value ?? null
}

function displayedSpeed(c: UiControl | null, draft: AssistantSpeed): AssistantSpeed {
  if (!c) return draft
  const selected = c.options.find((option) => option.value === c.value)
  const value = `${c.value} ${selected?.name ?? ''}`.toLowerCase()
  if (/fast[-_ ]?mode/i.test(`${c.id} ${c.name}`)) {
    if (/\b(on|true|enabled|fast)\b/.test(value)) return 'fast'
    return draft === 'fast' ? 'default' : draft
  }
  if (/fast|quick|low|minimal|light/.test(value)) return 'fast'
  return 'default'
}

function buildContext(): string {
  const { project, stage, autonomy } = useKaisola.getState()
  const papers = project.corpus.filter((s): s is Paper => s.kind === 'paper')
  return [
    `[Kaisola research IDE · stage: ${stageMeta(stage).label} · autonomy: ${autonomy}]`,
    project.name && project.name !== 'Untitled research' ? `Project: ${project.name}.` : '',
    project.question ? `Question: ${project.question}.` : '',
    papers.length ? `Corpus (${papers.length}): ${papers.slice(0, 12).map((p) => p.title).join('; ')}.` : '',
  ].filter(Boolean).join('\n')
}

function usageWarningContext(): string {
  try {
    const cached = JSON.parse(localStorage.getItem(AGENT_USAGE_WARNING_KEY) || 'null') as {
      at?: number
      rows?: Array<{ label?: string; usedPercent?: number; resetsAt?: number }>
    } | null
    if (!cached?.at || Date.now() - cached.at > 15 * 60_000 || !cached.rows?.length) return ''
    const limits = cached.rows.flatMap((row) =>
      typeof row.label === 'string' && typeof row.usedPercent === 'number'
        ? [`${row.label}: ${Math.max(0, Math.round(100 - row.usedPercent))}% remaining${row.resetsAt ? `, resets ${new Date(row.resetsAt * 1000).toLocaleString()}` : ''}`]
        : [],
    )
    return limits.length ? `Kaisola usage warning (budget your work accordingly):\n${limits.join('\n')}\n\n` : ''
  } catch { return '' }
}

// memo'd: every thread's card stays mounted side by side, and SessionCards
// re-renders often — a card whose threadId hasn't changed must not re-render
// (its own runtime subscription below wakes it when ITS content changes)
export const Assistant = memo(function Assistant({ threadId }: { threadId: string }) {
  const autonomy = useKaisola((s) => s.autonomy)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const claudeAccounts = useKaisola((s) => s.claudeAccounts)
  const claudeAccountId = useKaisola((s) => s.claudeAccountId)
  const project = useKaisola((s) => s.project)
  const projectId = useKaisola((s) => s.activeProjectId)
  const focusedThreadId = useKaisola((s) => s.activeThreadId)
  const setWorkspace = useKaisola((s) => s.setWorkspace)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const openSignIn = useKaisola((s) => s.openSignIn)
  // one Assistant instance per thread (so threads can sit side by side); the
  // store owns session metadata and durable turns.
  const threads = useKaisola((s) => s.assistantThreads)
  // THIS thread's runtime only: another thread's stream token replaces the
  // runtimes map, but this card re-renders only when its own entry changes
  const liveRuntime = useKaisola((s) => {
    const t = s.assistantThreads.find((x) => x.id === threadId) ?? s.assistantThreads[0]
    return t ? s.assistantRuntimes[t.id] : undefined
  })
  const updateAssistantRuntime = useKaisola((s) => s.updateAssistantRuntime)
  const resetAssistantRuntime = useKaisola((s) => s.resetAssistantRuntime)
  const setThreadBusy = useKaisola((s) => s.setThreadBusy)
  const autoNameThread = useKaisola((s) => s.autoNameThread)
  const setStoreThreadAgent = useKaisola((s) => s.setAssistantThreadAgent)
  const setThreadClaudeEffort = useKaisola((s) => s.setThreadClaudeEffort)
  const setThreadCodexEffort = useKaisola((s) => s.setThreadCodexEffort)
  const setThreadPreferredModel = useKaisola((s) => s.setThreadPreferredModel)
  const setThreadPermissionMode = useKaisola((s) => s.setThreadPermissionMode)
  const setThreadQueuePaused = useKaisola((s) => s.setThreadQueuePaused)
  const beginAssistantDispatch = useKaisola((s) => s.beginAssistantDispatch)
  const commitAssistantDispatch = useKaisola((s) => s.commitAssistantDispatch)
  const rollbackAssistantDispatch = useKaisola((s) => s.rollbackAssistantDispatch)
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const terminalMeta = useKaisola((s) => s.terminalMeta)
  const setDockView = useKaisola((s) => s.setDockView)

  const [presets, setPresets] = useState<AcpPreset[]>([])
  const [agents, setAgents] = useState<AcpAgent[]>([])
  const [statusReadyKey, setStatusReadyKey] = useState('')
  const autoConnectAttemptRef = useRef<string | null>(null)
  // A renderer-local dispatch generation closes the gap between the visible
  // Stop button and the main process receiving session/prompt. Any awaited
  // preprocessing must still own this generation immediately before dispatch.
  const dispatchEpochRef = useRef(0)
  const providerSwitchRef = useRef(false)
  const modelApplyAttemptRef = useRef<string | null>(null)
  const modelApplyRetriesRef = useRef<{ key: string; count: number }>({ key: '', count: 0 })
  // mirrors awaitingAuth so the window-focus reconnect listener (a stable
  // closure) reads the live value without re-subscribing on every toggle
  const awaitingAuthRef = useRef(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [authUrl, setAuthUrl] = useState<string | null>(null)
  // an OS file drag hovering the chat — the drop lands as attachment chips
  const [fileDropHover, setFileDropHover] = useState(false)
  const scrollRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const pendingPermissions = useKaisola((s) => s.pendingPermissions)
  const answerPermission = useKaisola((s) => s.answerPermission)
  const alwaysAllowPermission = useKaisola((s) => s.alwaysAllowPermission)

  // zero threads is a legal state now (terminal-first shell). When the last
  // thread closes, this instance renders ONE dead frame before unmounting —
  // a phantom record keeps every hook below unconditional (Rules of Hooks).
  const active =
    threads.find((t) => t.id === threadId) ??
    threads[0] ??
    ({ id: threadId, agentKey: 'codex', busy: false } as AssistantThread)
  const parentGroup = active.groupParentId
    ? threads.find((thread) => thread.id === active.groupParentId)?.group
    : undefined
  const parentGroupPhase = parentGroup?.phase
  const parentGroupPaused = !!parentGroup?.paused
  const sessionCwd = active.cwd ?? workspacePath
  const draft = useKaisola((s) => s.assistantDrafts[active.id] ?? EMPTY_DRAFT)
  const queuedPrompts = useKaisola((s) => s.assistantPromptQueues[active.id] ?? EMPTY_QUEUE)
  const setAssistantDraft = useKaisola((s) => s.setAssistantDraft)
  const clearAssistantDraft = useKaisola((s) => s.clearAssistantDraft)
  const enqueueAssistantPrompt = useKaisola((s) => s.enqueueAssistantPrompt)
  const removeQueuedAssistantPrompt = useKaisola((s) => s.removeQueuedAssistantPrompt)
  const agentKey = active.agentKey
  const claudeConfigDir = claudeAccounts.find((account) => account.id === claudeAccountId)?.configDir ?? null
  // Provider sessions are per assistant thread, not merely per provider. Two
  // Codex cards in one project therefore retain independent contexts and
  // resume ids when hidden adapters park to disk.
  const connectionKey = `${agentKey}::${active.id}`
  const busy = active.busy
  const queuePaused = !!active.queuePaused
  const input = draft.text
  const attachments = draft.attachments
  const mentions = draft.mentions
  const speed = draft.speed
  useEffect(() => { if (inputRef.current && !input) inputRef.current.style.height = '' }, [input])
  const permsForAgent = pendingPermissions.filter((p) => p.key === connectionKey)
  const holdAdapterLease = !active.groupParentId || parentGroupPhase === 'idle' || (
    !!parentGroupPhase && !parentGroupPaused && ['answering', 'negotiating', 'assigning', 'executing', 'reviewing', 'integrating', 'critiquing', 'synthesizing'].includes(parentGroupPhase)
  ) || permsForAgent.length > 0
  const arun: Runtime = liveRuntime ?? { turns: [], first: true }
  const [archivedPage, setArchivedPage] = useState<ArchivedRow[]>([])
  const [archiveBefore, setArchiveBefore] = useState<number | undefined>()
  const [archiveTotal, setArchiveTotal] = useState<number | undefined>()
  const [archiveHasMore, setArchiveHasMore] = useState(false)
  const [archiveLoading, setArchiveLoading] = useState(false)
  const [archiveGap, setArchiveGap] = useState(false)
  const [archiveError, setArchiveError] = useState<string | null>(null)
  const archiveRequestRef = useRef(0)
  const archiveInFlightRef = useRef<{ generation: number; cursor: number | 'latest' } | null>(null)
  const archiveBeforeRef = useRef<number | undefined>()
  const archiveTotalRef = useRef<number | undefined>()
  const archiveHasMoreRef = useRef(false)
  const archivedPageRef = useRef<ArchivedRow[]>([])
  const archiveGapRef = useRef(false)
  const archiveAnchorRef = useRef<TranscriptAnchor | null>(null)
  const archiveReplaceRef = useRef(false)
  const archiveBoundaryCursorRef = useRef<number | 'latest' | null>(null)
  const archiveRetryAttemptRef = useRef('')
  const recentArchiveHydratedRef = useRef('')
  const archiveScope = useMemo(() => ({
    projectId,
    threadId: active.id,
    ...(arun.archiveEpoch ? { epoch: arun.archiveEpoch } : {}),
  }), [active.id, arun.archiveEpoch, projectId])
  const archiveScopeKey = `${archiveScope.projectId}\u0000${archiveScope.threadId}\u0000${archiveScope.epoch ?? '0'}`
  // Scope changes invalidate rows and requests. A growing archive count does
  // not: live spill metadata may advance while someone is reading older rows,
  // and resetting here would snap that reader back to the recent transcript.
  useEffect(() => {
    ++archiveRequestRef.current
    archiveInFlightRef.current = null
    archiveBeforeRef.current = undefined
    archiveTotalRef.current = undefined
    archiveHasMoreRef.current = false
    archivedPageRef.current = []
    archiveGapRef.current = false
    archiveAnchorRef.current = null
    archiveReplaceRef.current = false
    archiveBoundaryCursorRef.current = null
    setArchivedPage([])
    setArchiveBefore(undefined)
    setArchiveTotal(undefined)
    setArchiveHasMore(false)
    setArchiveLoading(false)
    setArchiveGap(false)
    setArchiveError(null)
  }, [archiveScopeKey])
  // Main owns the authoritative end. Probe metadata without hydrating turns;
  // a recovered post-crash tail therefore becomes discoverable immediately.
  useEffect(() => {
    const request = archiveRequestRef.current
    if (!bridge.assistantArchive) return
    void bridge.assistantArchive.info(archiveScope).then((result) => {
      if (archiveRequestRef.current !== request || !result.ok) return
      archiveTotalRef.current = result.total
      setArchiveTotal(result.total)
      const hasMore = archiveBeforeRef.current === undefined ? result.total > 0 : archiveHasMoreRef.current
      archiveHasMoreRef.current = hasMore
      setArchiveHasMore(hasMore)
    }).catch(() => {})
  }, [archiveScope, archiveScopeKey, arun.archivedTurns])
  // A quit or disk error retains the unacknowledged prefix and its idempotency
  // token. Retry once this owning card is mounted again.
  useEffect(() => {
    if (!arun.archiveBatch || arun.archivePending) return
    const attempt = `${archiveScopeKey}\u0000${arun.archiveBatch.id}`
    if (archiveRetryAttemptRef.current === attempt) return
    archiveRetryAttemptRef.current = attempt
    updateAssistantRuntime(active.id, (runtime) => runtime, projectId)
  }, [active.id, archiveScopeKey, arun.archiveBatch, arun.archivePending, projectId, updateAssistantRuntime])
  const archivedCount = archiveTotal ?? arun.archivedTurns ?? 0
  const canLoadArchive = archiveBefore === undefined ? archivedCount > 0 : archiveHasMore
  const captureTranscriptAnchor = (): TranscriptAnchor | null => {
    const el = scrollRef.current
    if (!el) return null
    const top = el.getBoundingClientRect().top
    for (const node of el.querySelectorAll<HTMLElement>('[data-transcript-row]')) {
      const rect = node.getBoundingClientRect()
      if (rect.bottom > top + 1) {
        const key = node.dataset.transcriptRow
        if (key) return { key, offset: rect.top - top }
      }
    }
    return null
  }
  const loadOlderTurns = async (fromLatest = false) => {
    if (!bridge.assistantArchive) return false
    const generation = archiveRequestRef.current
    const cursor = fromLatest ? undefined : archiveBeforeRef.current
    const cursorKey = cursor ?? 'latest'
    if ((!fromLatest && cursor === 0) || archiveInFlightRef.current) return false
    archiveInFlightRef.current = { generation, cursor: cursorKey }
    setArchiveLoading(true)
    setArchiveError(null)
    try {
      // `undefined` deliberately lets main choose its reconciled end; never
      // seed first paging from a possibly stale renderer count.
      const result = await bridge.assistantArchive.page(archiveScope, cursor, ARCHIVE_PAGE_TURNS)
      if (archiveRequestRef.current !== generation) return false
      if (!result.ok) throw new Error(result.message || 'Kaisola could not read older history.')
      const total = Number.isSafeInteger(result.total) ? Math.max(0, result.total!) : (archiveTotalRef.current ?? archivedCount)
      const fallbackStart = Math.max(0, (cursor ?? total) - result.turns.length)
      const start = Number.isSafeInteger(result.before) ? Math.max(0, result.before!) : fallbackStart
      // Preserve main's absolute offsets even if a malformed record is rejected:
      // filtering first and then numbering would silently shift every later row.
      const incoming = result.turns.flatMap((value, offset) => {
        const turn = archivedTurn(value)
        return turn ? [{ turn, index: start + offset }] : []
      })
      const replace = fromLatest || cursor === undefined
      archiveAnchorRef.current = fromLatest ? null : captureTranscriptAnchor()
      archiveReplaceRef.current = fromLatest
      const bounded = boundArchivedView(replace ? incoming : mergeArchivedRows(incoming, archivedPageRef.current))
      archivedPageRef.current = bounded.rows
      setArchivedPage(bounded.rows)
      const gap = replace ? bounded.truncated : archiveGapRef.current || bounded.truncated
      archiveGapRef.current = gap
      setArchiveGap(gap)
      archiveBeforeRef.current = start
      setArchiveBefore(start)
      archiveTotalRef.current = total
      setArchiveTotal(total)
      archiveHasMoreRef.current = !!result.hasMore
      setArchiveHasMore(!!result.hasMore)
      return true
    } catch (error) {
      // The live window stays intact; archive IPC failures are retryable and
      // never justify dropping conversation state.
      archiveBoundaryCursorRef.current = null
      setArchiveError(error instanceof Error ? error.message : 'Kaisola could not read older history.')
      return false
    } finally {
      const inFlight = archiveInFlightRef.current
      if (inFlight?.generation === generation && inFlight.cursor === cursorKey) {
        archiveInFlightRef.current = null
        setArchiveLoading(false)
      }
    }
  }
  useEffect(() => {
    const recentAt = Math.max(active.lastActivityAt ?? 0, active.lastViewedAt ?? 0)
    if (active.groupParentId || focusedThreadId !== active.id || !archiveTotal || !recentAt || Date.now() - recentAt > 24 * 60 * 60_000) return
    if (recentArchiveHydratedRef.current === archiveScopeKey) return
    recentArchiveHydratedRef.current = archiveScopeKey
    void loadOlderTurns(true)
    // Hydrate one bounded recent page only when archive metadata arrives.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active.groupParentId, active.id, active.lastActivityAt, active.lastViewedAt, archiveScopeKey, archiveTotal, focusedThreadId])
  const agentPreset = presets.find((p) => p.id === agentKey)
  const agentName = agentPreset?.name ?? agentKey
  const aState = agents.find((a) => a.key === connectionKey)
  const connected = !!aState?.connected
  const availableCommands = aState?.availableCommands ?? []
  const commandToken = input.match(/^([/$])([^\s]*)$/)
  const commandChoices = commandToken
    ? availableCommands.filter((command) => {
      const prefix = command.name.startsWith('$') ? '$' : '/'
      return prefix === commandToken[1] && command.name.replace(/^\$/, '').toLowerCase().includes(commandToken[2].toLowerCase())
    }).slice(0, 12)
    : []
  // Native prompt queueing (claude-code-acp) → a follow-up sent mid-turn is
  // STEERED into the running turn at the next tool boundary, instead of waiting
  // out the whole turn. Agents without it keep the queue-until-idle behavior.
  const canSteer = !!aState?.promptQueue
  const controls = controlList(aState?.controls ?? null)
  const speedControl = nativeSpeedControl(controls)
  const liveSpeed = displayedSpeed(speedControl, speed)
  const visibleControls = speedControl ? controls.filter((c) => c.id !== speedControl.id) : controls
  const claudeAgent = /claude/i.test(`${agentKey} ${agentName}`)
  const codexAgent = /codex/i.test(`${agentKey} ${agentName}`)
  const providerModelControl = visibleControls.find((control) => control.kind === 'model' || control.category === 'model')
  const providerEffortControl = visibleControls.find((control) => /reasoning.*effort|effort/i.test(`${control.id} ${control.name} ${control.category}`))
  const composerControls = providerModelControl && (claudeAgent || codexAgent)
    ? visibleControls.filter((control) => control !== providerModelControl && control !== providerEffortControl)
    : visibleControls
  const providerClaudeEfforts = providerEffortControl?.options.flatMap((option) =>
    isClaudeEffort(option.value) ? [option.value] : [],
  ) ?? []
  const savedClaudeEffort = active.claudeEffort && providerClaudeEfforts.includes(active.claudeEffort) ? active.claudeEffort : null
  const currentClaudeEffort = providerEffortControl && isClaudeEffort(providerEffortControl.value) && providerClaudeEfforts.includes(providerEffortControl.value)
    ? providerEffortControl.value
    : null
  const claudeEffort: ClaudeEffort = providerEffortControl
    ? currentClaudeEffort ?? savedClaudeEffort ?? (providerClaudeEfforts.includes('high') ? 'high' : providerClaudeEfforts[0] ?? 'high')
    : active.claudeEffort ?? 'high'
  const claudeEffortOptions = providerEffortControl
    ? CLAUDE_EFFORT_OPTIONS.filter((option) => providerClaudeEfforts.includes(option.value as ClaudeEffort))
    : CLAUDE_EFFORT_OPTIONS.filter((option) => option.value !== 'default')
  useEffect(() => {
    if (!claudeAgent || !providerEffortControl || !active.claudeEffort || active.claudeEffort === claudeEffort) return
    setThreadClaudeEffort(active.id, claudeEffort, projectId)
  }, [active.claudeEffort, active.id, claudeAgent, claudeEffort, projectId, providerEffortControl, setThreadClaudeEffort])
  const providerEfforts = providerEffortControl?.options.map((option) => option.value) ?? []
  const savedCodexEffort = active.codexEffort && providerEfforts.includes(active.codexEffort) ? active.codexEffort : null
  const currentCodexEffort = providerEffortControl && isCodexEffort(providerEffortControl.value) && providerEfforts.includes(providerEffortControl.value)
    ? providerEffortControl.value
    : null
  // The live model catalog wins: changing Sol Ultra → Luna must immediately
  // show/persist Luna's actual max/xhigh wire value, never stale "Ultra".
  const codexEffort: CodexEffort = currentCodexEffort ?? savedCodexEffort ?? 'high'
  useEffect(() => {
    if (!codexAgent || !providerEffortControl || !active.codexEffort || active.codexEffort === codexEffort) return
    setThreadCodexEffort(active.id, codexEffort, projectId)
  }, [active.codexEffort, active.id, codexAgent, codexEffort, projectId, providerEffortControl, setThreadCodexEffort])
  const activityTools = arun.turns.filter((t) => t.kind === 'tool').slice(-8)
  const activeTools = activityTools.filter((t) => !doneStatuses.has((t.status || '').toLowerCase()))
  const latestActivity = activeTools[activeTools.length - 1]
  const latestActivityKind = latestActivity ? activityKind(latestActivity.text) : null
  const subagentCount = activeTools.filter((call) => activityKind(call.text).label === 'Subagent').length
  const liveAgentTerminals = agentTerminals
    .filter((t) =>
      terminalMeta[t.terminalId]?.running &&
      (t.agentKey === connectionKey || t.agentKey === agentKey || (!t.agentKey && t.agentName === agentName)),
    )
    .slice(-3)
    .reverse()
  const showLiveActivity = busy || activeTools.length > 0 || liveAgentTerminals.length > 0

  const updateRuntime = (id: string, fn: (r: Runtime) => Runtime) =>
    updateAssistantRuntime(id, fn, projectId)
  const owningSlice = useCallback(() => {
    const state = useKaisola.getState()
    return state.activeProjectId === projectId ? state : state.projectSlices[projectId]
  }, [projectId])
  const openTerminalPreset = useCallback((preset: AcpPreset) => {
    if (!preset.terminalCommand) return
    requestTerminal(preset.terminalCommand, {
      cwd: workspacePath ?? undefined,
      name: preset.name,
      singletonKey: `agent:${preset.id}`,
      restart: true,
    })
    setNotice(`${preset.name} opened as a terminal session.`)
  }, [requestTerminal, workspacePath])

  const refresh = useCallback(
    () => bridge.acp.status([connectionKey], projectId).then((s) => setAgents(s.agents)),
    [connectionKey, projectId],
  )
  useEffect(() => {
    const desired = active.preferredModel
    if (!connected) { modelApplyAttemptRef.current = null; return }
    if (!desired || !providerModelControl || providerModelControl.value === desired) {
      modelApplyAttemptRef.current = null
      modelApplyRetriesRef.current = { key: '', count: 0 }
      return
    }
    if (!providerModelControl.options.some((option) => option.value === desired)) return
    const attempt = `${connectionKey}:${desired}`
    if (modelApplyRetriesRef.current.key !== attempt) modelApplyRetriesRef.current = { key: attempt, count: 0 }
    if (modelApplyRetriesRef.current.count >= 3) return
    if (modelApplyAttemptRef.current === attempt) return
    modelApplyAttemptRef.current = attempt
    void bridge.acp.setModel(connectionKey, desired, projectId).then((result) => {
      modelApplyAttemptRef.current = null
      if (result.ok) {
        modelApplyRetriesRef.current = { key: attempt, count: 0 }
        void refresh()
        return
      }
      modelApplyRetriesRef.current = { key: attempt, count: modelApplyRetriesRef.current.count + 1 }
      setNotice(result.message ?? `Could not restore ${active.preferredModelLabel ?? desired}; retrying.`)
      window.setTimeout(() => setAgents((current) => [...current]), 1_500 * modelApplyRetriesRef.current.count)
    }).catch(() => {
      modelApplyAttemptRef.current = null
      modelApplyRetriesRef.current = { key: attempt, count: modelApplyRetriesRef.current.count + 1 }
      window.setTimeout(() => setAgents((current) => [...current]), 1_500 * modelApplyRetriesRef.current.count)
    })
  }, [active.preferredModel, active.preferredModelLabel, connected, connectionKey, projectId, providerModelControl, refresh])
  useEffect(() => {
    let live = true
    void Promise.allSettled([bridge.acp.status([connectionKey], projectId), bridge.acp.presets()]).then(([statusResult, presetResult]) => {
      if (!live) return
      if (statusResult.status === 'fulfilled') {
        setAgents(statusResult.value.agents)
        const adopted = statusResult.value.agents.find((agent) => agent.key === connectionKey)
        const persistedBusy = owningSlice()?.assistantThreads.find((candidate) => candidate.id === active.id)?.busy
        // After a renderer relaunch the request-specific stream listener no
        // longer exists. Do not leave an invisible provider turn or permission
        // gate alive: fail closed, pause delivery, and reconnect the resumable
        // provider session on the user's next send.
        if (adopted?.busy && !persistedBusy) {
          dispatchEpochRef.current++
          setThreadQueuePaused(active.id, true, projectId)
          setNotice('A turn was interrupted by the app restart and was safely stopped. Send again to resume this session.')
          void (async () => {
            await bridge.acp.cancel(connectionKey, projectId).catch(() => ({ ok: false }))
            await bridge.acp.disconnect(connectionKey, projectId).catch(() => ({ ok: false }))
            if (live) setAgents((current) => current.filter((agent) => agent.key !== connectionKey))
          })()
        }
      }
      if (presetResult.status === 'fulfilled') setPresets(presetResult.value)
      // Autoconnect must not race status: an idle connection may already be
      // alive in main after a renderer remount/window swap.
      setStatusReadyKey(connectionKey)
    })
    return () => { live = false }
  }, [active.id, connectionKey, owningSlice, projectId, setThreadQueuePaused])
  useEffect(() => {
    // Visible transcripts stay warm. Private Mesh workers stay warm only while
    // setup, work, or a permission ask is active; approval gates, Pause, and
    // Complete release their lease and become parkable after a short linger.
    void bridge.acp.lease(connectionKey, threadId, holdAdapterLease, 30_000, projectId)
    return () => {
      void bridge.acp.lease(connectionKey, threadId, false, 30_000, projectId)
    }
  }, [connectionKey, holdAdapterLease, projectId, threadId])
  useEffect(() => { const off = bridge.acp.onControls(() => refresh()); return off }, [connectionKey, refresh])
  useEffect(() => {
    const off = bridge.acp.onCommands((info) => {
      if (info.key !== connectionKey) return
      setAgents((current) => current.map((agent) => agent.key === connectionKey ? { ...agent, availableCommands: info.commands } : agent))
    })
    return off
  }, [connectionKey])
  // many agents print an OAuth URL to authorize — surface it as an openable link
  useEffect(() => {
    const off = bridge.acp.onNotice((n) => {
      if (n.key && n.key !== connectionKey) return
      if (n.url) { setAuthUrl(n.url); setNotice(`${n.agent ?? 'The agent'} needs browser authorization.`) }
      if (n.kind === 'cancel-timeout' || n.kind === 'exit') {
        if (n.text) setNotice(n.text)
        autoConnectAttemptRef.current = null
        refresh()
      }
    })
    return off
  }, [connectionKey, refresh])
  // ── turn timeline (Codex-style): one tick per prompt, hover = card, click = jump ──
  const liveIndexBase = archiveTotal ?? archivedCount
  const displayedTurns = useMemo(
    () => [
      ...archivedPage.map((row) => ({ turn: row.turn, idx: row.index })),
      ...arun.turns.map((turn, idx) => ({ turn, idx: liveIndexBase + idx })),
    ],
    [archivedPage, arun.turns, liveIndexBase],
  )
  const prompts = useMemo(() => displayedTurns.filter((x) => x.turn.kind === 'user'), [displayedTurns])
  const promptRailRef = useRef<HTMLDivElement>(null)
  const [promptHover, setPromptHover] = useState<{ idx: number; top: number } | null>(null)
  const [activePrompt, setActivePrompt] = useState<number | null>(null)
  const jumpToTurn = (idx: number) => {
    setActivePrompt(() => idx)
    scrollRef.current
      ?.querySelector(`[data-turn="${idx}"]`)
      ?.scrollIntoView({ block: 'start', behavior: 'smooth' })
  }
  /** The reply that followed a prompt — the hover card's preview. */
  const replyPreview = (promptIdx: number): { text: string; tools: number } => {
    let tools = 0
    const start = displayedTurns.findIndex((row) => row.idx === promptIdx)
    for (let i = start + 1; i < displayedTurns.length; i++) {
      const t = displayedTurns[i].turn
      if (t.kind === 'user') break
      if (t.kind === 'tool') tools++
      if (t.kind === 'assistant' && t.text) return { text: t.text.slice(0, 180), tools }
    }
    return { text: '', tools }
  }

  // stick to the bottom only if the user is already near it — don't yank them
  // down while they're scrolling up to read.
  const viewportKey = `${projectId}\u0000${threadId}`
  // A running turn or a non-empty composer always belongs at the live prompt.
  // Idle/read-only transcripts still restore the exact saved reading offset.
  const openAtLivePrompt = busy || !!input.trim() || attachments.length > 0 || mentions.length > 0
  const stickRef = useRef(openAtLivePrompt || (assistantViewport(viewportKey)?.atBottom ?? true))
  useEffect(() => {
    const last = prompts[prompts.length - 1]?.idx ?? null
    setActivePrompt((current) => {
      if (last == null) return null
      if (stickRef.current || current == null || !prompts.some((prompt) => prompt.idx === current)) return last
      return current
    })
  }, [prompts])
  const restoringViewportRef = useRef(false)
  const archiveRestoringRef = useRef(false)
  const lastStreamTopRef = useRef(0)
  const archiveTouchYRef = useRef<number | null>(null)
  const archiveGestureRef = useRef({ lastAt: 0, upward: false, consumed: false, pointer: false })
  const saveViewport = (flush = false) => {
    const el = scrollRef.current
    if (!el) return
    const fromBottom = Math.max(0, el.scrollHeight - el.scrollTop - el.clientHeight)
    rememberAssistantViewport(viewportKey, { top: el.scrollTop, fromBottom, atBottom: fromBottom < 90 }, flush)
  }
  const noteArchiveGesture = (upward: boolean, forceNew = false) => {
    const now = performance.now()
    const gesture = archiveGestureRef.current
    const fresh = forceNew || now - gesture.lastAt > 260 || gesture.upward !== upward
    if (fresh) gesture.consumed = false
    gesture.lastAt = now
    gesture.upward = upward
  }
  const maybeLoadAtTop = () => {
    const el = scrollRef.current
    const gesture = archiveGestureRef.current
    if (!el || !gesture.upward || gesture.consumed || el.scrollTop > ARCHIVE_NEAR_TOP_PX || !canLoadArchive || archiveInFlightRef.current) return
    const cursor = archiveBeforeRef.current ?? 'latest'
    if (archiveBoundaryCursorRef.current === cursor) return
    gesture.consumed = true
    archiveBoundaryCursorRef.current = cursor
    void loadOlderTurns()
  }
  const onStreamWheel = (event: ReactWheelEvent<HTMLDivElement>) => {
    noteArchiveGesture(event.deltaY < 0)
    if (event.deltaY < 0) queueMicrotask(maybeLoadAtTop)
  }
  const onStreamTouchStart = (event: ReactTouchEvent<HTMLDivElement>) => {
    archiveTouchYRef.current = event.touches[0]?.clientY ?? null
    noteArchiveGesture(false, true)
  }
  const onStreamTouchMove = (event: ReactTouchEvent<HTMLDivElement>) => {
    const next = event.touches[0]?.clientY
    const previous = archiveTouchYRef.current
    if (next == null || previous == null) return
    const upward = next > previous
    archiveTouchYRef.current = next
    noteArchiveGesture(upward)
    if (upward) queueMicrotask(maybeLoadAtTop)
  }
  const onStreamPointerDown = (_event: ReactPointerEvent<HTMLDivElement>) => {
    archiveGestureRef.current.pointer = true
    noteArchiveGesture(false, true)
  }
  const onStreamPointerUp = () => { archiveGestureRef.current.pointer = false }
  const onStreamKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (!['ArrowUp', 'PageUp', 'Home'].includes(event.key)) return
    noteArchiveGesture(true, !event.repeat)
    queueMicrotask(maybeLoadAtTop)
  }
  const onStreamScroll = () => {
    const el = scrollRef.current
    if (el) {
      const previousTop = lastStreamTopRef.current
      lastStreamTopRef.current = el.scrollTop
      if (restoringViewportRef.current || archiveRestoringRef.current) return
      if (el.scrollTop < previousTop - 0.5) {
        const gesture = archiveGestureRef.current
        if (gesture.pointer && performance.now() - gesture.lastAt > 260) noteArchiveGesture(true, true)
        if (gesture.pointer || performance.now() - gesture.lastAt < 360) {
          noteArchiveGesture(true)
          maybeLoadAtTop()
        }
      }
      stickRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 90
      saveViewport()
      // which prompt is above the fold — the rail's darkened tick
      let visiblePrompt = prompts[0]?.idx ?? null
      prompts.forEach((p) => {
        const node = el.querySelector(`[data-turn="${p.idx}"]`) as HTMLElement | null
        if (node && node.offsetTop <= el.scrollTop + 60) visiblePrompt = p.idx
      })
      setActivePrompt(visiblePrompt)
    }
  }
  // A prepend is committed before paint, then corrected by the exact previous
  // first-visible row. Absolute row keys survive both prepends and bottom
  // eviction, so concurrent live output cannot turn this into a height guess.
  useLayoutEffect(() => {
    const el = scrollRef.current
    if (!el) return
    if (archiveReplaceRef.current) {
      archiveReplaceRef.current = false
      archiveRestoringRef.current = true
      if (stickRef.current) el.scrollTop = el.scrollHeight
      else el.scrollTop = 0
      lastStreamTopRef.current = el.scrollTop
      archiveRestoringRef.current = false
      saveViewport()
      return
    }
    const anchor = archiveAnchorRef.current
    archiveAnchorRef.current = null
    if (!anchor) return
    const restore = () => {
      const top = el.getBoundingClientRect().top
      const node = [...el.querySelectorAll<HTMLElement>('[data-transcript-row]')]
        .find((candidate) => candidate.dataset.transcriptRow === anchor.key)
      if (!node) return
      el.scrollTop += node.getBoundingClientRect().top - top - anchor.offset
      lastStreamTopRef.current = el.scrollTop
    }
    archiveRestoringRef.current = true
    stickRef.current = false
    restore()
    const frame = requestAnimationFrame(() => {
      restore()
      archiveRestoringRef.current = false
      saveViewport()
    })
    return () => {
      cancelAnimationFrame(frame)
      archiveRestoringRef.current = false
    }
    // archivedPage is the commit boundary this anchor belongs to.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [archivedPage])
  useEffect(() => {
    if (stickRef.current) scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight })
  }, [arun, threadId])
  // Theme/energy/rail changes can resize or briefly remount a transcript even
  // though its session did not change. Restore the disk-backed viewport and
  // keep bottom-pinned composers bottom-pinned through the reflow.
  useLayoutEffect(() => {
    const el = scrollRef.current
    if (!el) return
    restoringViewportRef.current = true
    const persistElement = (flush = false) => {
      const fromBottom = Math.max(0, el.scrollHeight - el.scrollTop - el.clientHeight)
      rememberAssistantViewport(viewportKey, { top: el.scrollTop, fromBottom, atBottom: fromBottom < 90 }, flush)
    }
    const restore = () => {
      const saved = assistantViewport(viewportKey)
      const atLivePrompt = openAtLivePrompt || !saved || saved.atBottom
      if (!saved || atLivePrompt) {
        stickRef.current = true
        el.scrollTop = el.scrollHeight
        return
      }
      stickRef.current = false
      el.scrollTop = Math.max(0, el.scrollHeight - el.clientHeight - saved.fromBottom)
    }
    restore()
    const frame = requestAnimationFrame(restore)
    const settleA = window.setTimeout(restore, 60)
    const settleB = window.setTimeout(() => {
      restore()
      restoringViewportRef.current = false
      persistElement()
    }, 160)
    const observer = new ResizeObserver(() => {
      const saved = assistantViewport(viewportKey)
      if (stickRef.current) el.scrollTop = el.scrollHeight
      else if (saved) el.scrollTop = Math.max(0, el.scrollHeight - el.clientHeight - saved.fromBottom)
    })
    observer.observe(el)
    // A narrow split can rewrap a long draft and grow the composer without
    // changing the transcript's own box immediately. Observe the textarea too
    // so a bottom-pinned conversation stays at the live prompt during reflow.
    if (inputRef.current) observer.observe(inputRef.current)
    return () => {
      cancelAnimationFrame(frame)
      window.clearTimeout(settleA)
      window.clearTimeout(settleB)
      restoringViewportRef.current = false
      // React may clear scrollRef before a deletion cleanup. The captured DOM
      // node still owns the final geometry, so persist from it directly.
      persistElement(true)
      observer.disconnect()
    }
    // The element belongs to this thread for the lifetime of this effect.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewportKey])
  // clear the auth prompt once we're connected
  useEffect(() => { if (connected) { setNotice(null); setAuthUrl(null) } }, [connected])
  // live tick so the "thinking…" timer updates while a response streams
  const [, setTick] = useState(0)
  useEffect(() => {
    if (!busy) return
    const iv = setInterval(() => setTick((n) => n + 1), 500)
    return () => clearInterval(iv)
  }, [busy])

  const pickWorkspace = useCallback(async (): Promise<string | null> => {
    const r = await bridge.pickFolder()
    if (r.ok && r.path) { setWorkspace(r.path); return r.path }
    if (r.message) setNotice(r.message)
    return null
  }, [setWorkspace])
  const connect = useCallback(async (key: string, opts: { claudeEffort?: ClaudeEffort; forceReconnect?: boolean } = {}): Promise<boolean> => {
    setNotice(null)
    const preset = presets.find((p) => p.id === key)
    if (preset?.terminalOnly) {
      openTerminalPreset(preset)
      return false
    }
    // the agent MUST work inside a real folder you choose — never Kaisola's own dir
    let cwd = sessionCwd
    if (!cwd) {
      setNotice('Pick a folder for the agent to work in…')
      cwd = await pickWorkspace()
      if (!cwd) { setNotice('Pick a workspace folder to begin.'); return false }
    }
    // user-added ACP agents carry their own server command (Zed's agent_servers)
    const custom = useKaisola.getState().customAgents.find((a) => a.id === key && a.kind === 'acp')
    // restart continuity: this thread's last agent-side session resumes via
    // session/load when the agent supports it (stale ids fall back fresh)
    const resumeSessionId = key === active.agentKey ? active.acpSessionId : undefined
    const effort = key === 'claude-code' ? (opts.claudeEffort ?? active.claudeEffort ?? 'high') : undefined
    const res = await bridge.acp.connect(
      custom
        ? { presetId: key, clientKey: `${key}::${active.id}`, name: custom.name, command: custom.command, args: custom.args, autonomy, cwd, resumeSessionId, claudeEffort: effort, forceReconnect: opts.forceReconnect }
        : { presetId: key, clientKey: `${key}::${active.id}`, autonomy, cwd, resumeSessionId, claudeEffort: effort, forceReconnect: opts.forceReconnect, ...(key === 'claude-code' ? { claudeConfigDir } : {}) },
    )
    if (res.ok) {
      setNotice(null); refresh()
      // this agentKey now belongs to the active project — so its background
      // permission asks / terminals route home after a mid-run tab switch
      useKaisola.getState().setAgentProject(`${key}::${active.id}`, projectId)
      // remember the agent-side session so the NEXT connect can resume it
      if (res.agent?.sessionId) useKaisola.getState().setThreadAcpSession(active.id, res.agent.sessionId, projectId)
      // Reasoning effort is a native app-server config option. Reapply the
      // thread's durable choice after a parked/restarted adapter resumes.
      if (key === 'codex' && active.codexEffort) {
        const effortControl = controlList(res.controls ?? null).find((control) => /reasoning.*effort|effort/i.test(`${control.id} ${control.name} ${control.category}`))
        if (effortControl?.options.some((option) => option.value === active.codexEffort)) {
          const applied = await bridge.acp.setConfigOption(`${key}::${active.id}`, effortControl.id, active.codexEffort, projectId)
          if (!applied.ok) setNotice(applied.message ?? 'Codex effort could not be restored.')
        }
      }
      // Permission mode is agent-side session state: a new or resumed session
      // comes back in the agent's default mode. Reapply the thread's saved one.
      if (active.permissionMode) {
        const modeControl = controlList(res.controls ?? null).find((control) => control.kind === 'mode')
        if (modeControl && modeControl.value !== active.permissionMode && modeControl.options.some((option) => option.value === active.permissionMode)) {
          const applied = await bridge.acp.setMode(`${key}::${active.id}`, active.permissionMode, projectId)
          if (!applied.ok) setNotice(applied.message ?? 'The saved permission mode could not be restored.')
          else refresh()
        }
      }
      if (res.resumed) setNotice('Resumed the previous session.')
    }
    else setNotice(res.message ?? 'Could not connect.')
    return res.ok
  }, [active.acpSessionId, active.agentKey, active.claudeEffort, active.codexEffort, active.id, active.permissionMode, autonomy, claudeConfigDir, openTerminalPreset, pickWorkspace, presets, projectId, refresh, sessionCwd])
  const ensureAgentConnected = async (): Promise<boolean> => {
    // Main may have parked this idle adapter to reclaim its CLI/Node memory
    // while the transcript stayed mounted. A cheap status probe distinguishes
    // that from the optimistic renderer badge and resumes the durable provider
    // session before the next prompt or control mutation.
    let agentReady = connected
    try {
      const status = await bridge.acp.status([connectionKey], projectId)
      setAgents(status.agents)
      agentReady = status.agents.some((agent) => agent.key === connectionKey && agent.connected)
    } catch { /* fall back to the last renderer-known state */ }
    if (agentReady) return true
    try {
      const result = await connect(agentKey)
      return result
    } catch (error) {
      setNotice(`Could not connect: ${String((error as Error)?.message ?? error)}`)
      return false
    }
  }
  // Sign in: a clean in-app device-code card where available (codex), else fall
  // back to running the CLI's login in a terminal.
  const signIn = () => {
    const preset = presets.find((p) => p.id === agentKey)
    if (!preset) return
    if (preset.deviceLogin) {
      openSignIn({ key: agentKey, name: preset.name, command: preset.deviceLogin.command, args: preset.deviceLogin.args })
    } else if (preset.login) {
      requestTerminal(preset.login, { cwd: workspacePath ?? undefined, name: `${preset.name} Login` })
      setNotice(`Running “${preset.login}” in the terminal — complete the login there, then Connect.`)
    } else {
      setNotice('This agent has no CLI login.')
    }
  }
  // The "needs browser authorization" URL is scraped from the adapter's stderr,
  // but that localhost-redirect OAuth doesn't complete over ACP (claude-code-acp
  // says so in its own source) and nothing here ever retried the session. So
  // Authorize runs the agent's REAL login — the device-code card (codex) or its
  // `/login` pty (claude), both of which have a working browser flow — clears
  // the wedged turn, and arms a one-shot reconnect. Returning to the window (or
  // the manual Reconnect button) then reconnects the thread and drains its queue.
  const [awaitingAuth, setAwaitingAuth] = useState(false)
  const reconnectAfterAuth = useCallback(async () => {
    if (!awaitingAuthRef.current) return
    if (useKaisola.getState().signIn) return // the device-code card is still open
    const ok = await connect(agentKey, { forceReconnect: true })
    if (ok) { awaitingAuthRef.current = false; setAwaitingAuth(false); setAuthUrl(null); setNotice(null) }
  }, [agentKey, connect])
  const authorize = () => {
    setAuthUrl(null)
    if (busy) { void bridge.acp.cancel(connectionKey, projectId); setThreadBusy(active.id, false, projectId) }
    awaitingAuthRef.current = true
    setAwaitingAuth(true)
    setNotice('Finish signing in — this thread reconnects when you return, or press Reconnect.')
    signIn()
  }
  // External login (browser/terminal) → the window regains focus; the in-app
  // codex device card → it closes (signInOpen falls). Either return triggers
  // the one-shot reconnect.
  useEffect(() => {
    const onFocus = () => { void reconnectAfterAuth() }
    window.addEventListener('focus', onFocus)
    return () => window.removeEventListener('focus', onFocus)
  }, [reconnectAfterAuth])
  const signInOpen = useKaisola((s) => !!s.signIn)
  useEffect(() => {
    if (!signInOpen) void reconnectAfterAuth()
  }, [signInOpen, reconnectAfterAuth])
  // Ordinary transcripts connect lazily on Send/control interaction. Mesh
  // workers connect while its setup surface is open so their live model
  // catalogs can be configured; safe idle adapters are still parked by main.
  useEffect(() => {
    if (!active.groupParentId || parentGroupPhase !== 'idle') return
    if (statusReadyKey !== connectionKey || connected || busy || !sessionCwd) return
    const preset = presets.find((p) => p.id === agentKey)
    const custom = useKaisola.getState().customAgents.find((a) => a.id === agentKey && a.kind === 'acp')
    if ((!preset || preset.terminalOnly) && !custom) return
    const attempt = `${threadId}|${agentKey}|${sessionCwd}|${agentKey === 'claude-code' ? `${claudeConfigDir ?? 'default'}|${active.claudeEffort ?? 'high'}` : ''}`
    if (autoConnectAttemptRef.current === attempt) return
    autoConnectAttemptRef.current = attempt
    void connect(agentKey)
  }, [active.claudeEffort, active.groupParentId, agentKey, connected, busy, claudeConfigDir, connect, connectionKey, parentGroupPhase, presets, statusReadyKey, threadId, sessionCwd])
  const onControlChange = async (c: UiControl, value: string) => {
    if (!(await ensureAgentConnected())) return
    const result = c.kind === 'mode'
      ? await bridge.acp.setMode(connectionKey, value, projectId)
      : c.kind === 'model'
        ? await bridge.acp.setModel(connectionKey, value, projectId)
        : await bridge.acp.setConfigOption(connectionKey, c.id, value, projectId)
    if (!result.ok) setNotice(result.message ?? `${c.name} could not be changed.`)
    else {
      setNotice(null)
      if (c.kind === 'model') {
        const label = c.options.find((option) => option.value === value)?.name
        setThreadPreferredModel(active.id, value, label, projectId)
      }
      // mode lives on the agent side of the session — persist the choice so
      // reconnects/restarts reapply it instead of the agent's default
      if (c.kind === 'mode') setThreadPermissionMode(active.id, value, projectId)
    }
    refresh()
  }
  const applySpeed = async ({ speed: nextSpeed }: { speed: AssistantSpeed }): Promise<boolean> => {
    if (!speedControl) return false
    const value = speedOptionValue(speedControl, nextSpeed)
    if (!value) return false
    if (value === speedControl.value) return true
    const res = await bridge.acp.setConfigOption(connectionKey, speedControl.id, value, projectId)
    if (!res.ok && res.message) setNotice(res.message)
    refresh()
    return res.ok
  }
  const setSpeed = (value: string) => {
    if (!isAssistantSpeed(value)) return
    setAssistantDraft(active.id, { speed: value }, projectId)
    void applySpeed({ speed: value })
  }
  const changeClaudeEffort = async (value: string) => {
    if (!isClaudeEffort(value)) return
    if (busy) {
      setNotice('Wait for this turn to finish before changing Claude effort.')
      return
    }
    if (providerEffortControl) {
      if (!providerEffortControl.options.some((option) => option.value === value)) {
        setNotice('The selected Claude model does not support that effort level.')
        return
      }
      const res = await bridge.acp.setConfigOption(connectionKey, providerEffortControl.id, value, projectId)
      if (!res.ok) { setNotice(res.message ?? `Claude rejected ${value} effort.`); return }
      setThreadClaudeEffort(active.id, value, projectId)
      setNotice(`Claude effort: ${CLAUDE_EFFORT_OPTIONS.find((o) => o.value === value)?.name ?? value}.`)
      refresh()
      return
    }
    setThreadClaudeEffort(active.id, value, projectId)
    setNotice('Applying Claude effort…')
    const ok = await connect(agentKey, { claudeEffort: value, forceReconnect: true })
    if (ok) setNotice(`Claude effort: ${CLAUDE_EFFORT_OPTIONS.find((o) => o.value === value)?.name ?? value}. Session resumed.`)
  }
  const changeCodexEffort = async (value: string) => {
    if (!isCodexEffort(value)) return
    if (busy) {
      setNotice('Wait for this turn to finish before changing Codex effort.')
      return
    }
    if (!providerEffortControl || !providerEffortControl.options.some((option) => option.value === value)) {
      setNotice('The installed Codex ACP adapter does not support that effort level.')
      return
    }
    const res = await bridge.acp.setConfigOption(connectionKey, providerEffortControl.id, value, projectId)
    if (!res.ok) {
      setNotice(res.message ?? `Codex rejected ${value} effort.`)
      return
    }
    setThreadCodexEffort(active.id, value, projectId)
    setNotice(`Codex effort: ${CODEX_EFFORT_OPTIONS.find((option) => option.value === value)?.name ?? value}.`)
    refresh()
  }

  // Chunks arrive far faster than frames paint, and every runtime update
  // re-parses the growing turn's markdown from scratch. Buffer text chunks and
  // flush on a ~80ms cadence so the transcript renders per flush, not per
  // token. Tool calls flush the buffer first so turn order is preserved.
  const makeOnUpdate = (threadId: string) => {
    let pending: { kind: 'assistant' | 'thought'; text: string; at: number } | null = null
    let timer: ReturnType<typeof setTimeout> | null = null
    let lastFlush = 0
    const append = (k: 'assistant' | 'thought', text: string, at: number) =>
      updateRuntime(threadId, (r) => {
        const turns = [...r.turns]
        let thinkStart = r.thinkStart
        // start the thinking clock on the first thought; stop it (record duration
        // on the thought turn) when the model's visible output begins
        if (k === 'thought' && thinkStart == null) thinkStart = at
        if (k === 'assistant' && thinkStart != null) {
          const ms = at - thinkStart
          thinkStart = undefined
          for (let i = turns.length - 1; i >= 0; i--) {
            if (turns[i].kind === 'thought') { turns[i] = { ...turns[i], thinkMs: ms }; break }
          }
        }
        const last = turns[turns.length - 1]
        if (last && last.kind === k) turns[turns.length - 1] = { ...last, text: appendBounded(last.text, text, k === 'thought' ? 160_000 : MAX_VISIBLE_TURN_TEXT) }
        else turns.push({ kind: k, text: text.slice(0, k === 'thought' ? 160_000 : MAX_VISIBLE_TURN_TEXT), at })
        return { ...r, turns, thinkStart }
      })
    const flush = () => {
      if (timer) { clearTimeout(timer); timer = null }
      if (!pending) return
      const p = pending
      pending = null
      lastFlush = performance.now()
      append(p.kind, p.text, p.at)
    }
    const buffer = (k: 'assistant' | 'thought', text: string) => {
      if (pending && pending.kind !== k) flush()
      if (pending) pending.text += text
      else pending = { kind: k, text, at: Date.now() }
      if (!timer) timer = setTimeout(flush, Math.max(0, STREAM_FLUSH_MS - (performance.now() - lastFlush)))
    }
    // follow the agent (Zed's crosshair): tool calls that carry file locations
    // open those files as transient previews while the agent works
    const followLocations = (u2: AcpUpdate) => {
      const st = useKaisola.getState()
      if (st.activeProjectId !== projectId) return
      if (!st.followAgent) return
      const locs = (u2 as { locations?: Array<{ path?: string }> }).locations
      const p = locs?.find((l) => typeof l.path === 'string')?.path
      if (p && st.workspacePath && p.startsWith(st.workspacePath)) st.requestFile(p)
    }
    // ACP ToolCallContent → renderable artifacts (diff / embedded terminal).
    // Everything else in content[] is noise for the card — drop it quietly.
    const artifactsOf = (u2: AcpUpdate): ToolArtifact[] | undefined => {
      const raw = (u2 as { content?: unknown }).content
      if (!Array.isArray(raw)) return undefined
      const out: ToolArtifact[] = []
      for (const c of raw as Array<Record<string, unknown>>) {
        if (!c || typeof c !== 'object') continue
        if (c.type === 'diff' && typeof c.path === 'string') {
          out.push({ type: 'diff', path: c.path.slice(0, 2000), oldText: String(c.oldText ?? '').slice(-MAX_DIFF_TEXT), newText: String(c.newText ?? '').slice(-MAX_DIFF_TEXT) })
        } else if (c.type === 'terminal' && typeof c.terminalId === 'string') {
          out.push({ type: 'terminal', terminalId: c.terminalId.slice(0, 4000) })
        }
      }
      return out.length ? boundArtifacts(out) : undefined
    }
    const mergeArtifacts = (prev?: ToolArtifact[], next?: ToolArtifact[]) => {
      if (!next) return prev
      if (!prev) return next
      // updates re-send content — replace same-path diffs, append new ones
      const merged = [...prev]
      for (const a of next) {
        const i = merged.findIndex((m) => m.type === a.type && m.path === a.path && m.terminalId === a.terminalId)
        if (i >= 0) merged[i] = a
        else merged.push(a)
      }
      return boundArtifacts(merged, true)
    }
    const onUpdate = (u: AcpUpdate) => {
      const kind = u.sessionUpdate
      if (kind === 'agent_message_chunk') buffer('assistant', u.content?.text ?? u.text ?? '')
      else if (kind === 'agent_thought_chunk') buffer('thought', u.content?.text ?? u.text ?? '')
      else if (kind === 'usage_update') {
        // the agent's own context-window numbers — trust them over any estimate
        const uu = u as { usedTokens?: number; used?: number; maxTokens?: number; size?: number; contextWindow?: { used?: number; size?: number } }
        const used = uu.usedTokens ?? uu.used ?? uu.contextWindow?.used
        const size = uu.maxTokens ?? uu.size ?? uu.contextWindow?.size
        if (typeof used === 'number' && typeof size === 'number' && size > 0) {
          updateRuntime(threadId, (r) => ({ ...r, usage: { used, size } }))
        }
      } else if (kind === 'plan') {
        // the agent's own todo list — whole-array replace per frame (Zed's
        // update_plan semantics), rendered as the pinned strip, never a turn
        const entries = (u as { entries?: PlanEntry[] }).entries
        if (Array.isArray(entries)) updateRuntime(threadId, (r) => ({ ...r, plan: entries.slice(0, 100).map((entry) => ({ ...entry, content: String(entry.content ?? '').slice(0, 4000) })), planUpdatedAt: Date.now() }))
      } else if (kind === 'tool_call') {
        const tc = u as { toolCallId?: string; title?: string; kind?: string; status?: string }
        const toolId = typeof tc.toolCallId === 'string' ? tc.toolCallId.slice(0, 4000) : undefined
        const status = typeof tc.status === 'string' ? tc.status.slice(0, 200) : 'pending'
        flush()
        followLocations(u)
        updateRuntime(threadId, (r) => ({ ...r, turns: [...r.turns, { kind: 'tool', toolId, text: String(tc.title ?? tc.kind ?? 'tool').slice(0, 4000), status, at: Date.now(), artifacts: artifactsOf(u) }] }))
      } else if (kind === 'tool_call_update') {
        const tc = u as { toolCallId?: string; title?: string; status?: string }
        const toolId = typeof tc.toolCallId === 'string' ? tc.toolCallId.slice(0, 4000) : undefined
        const status = typeof tc.status === 'string' ? tc.status.slice(0, 200) : undefined
        flush()
        followLocations(u)
        updateRuntime(threadId, (r) => ({
          ...r,
          turns: r.turns.map((x) =>
            x.kind === 'tool' && x.toolId === toolId
              ? { ...x, status: status ?? x.status, text: String(tc.title ?? x.text).slice(0, 4000), artifacts: mergeArtifacts(x.artifacts, artifactsOf(u)) }
              : x,
          ),
        }))
      }
    }
    return { onUpdate, flush }
  }

  const resetComposerHeight = () => { if (inputRef.current) inputRef.current.style.height = '' }
  const currentPrompt = (): AssistantDraft => ({
    text: input.trim(),
    attachments,
    mentions,
    speed,
  })
  const drainingQueueRef = useRef(false)
  const queuePausedRef = useRef(queuePaused)
  // If this card mounts with an uncommitted transaction, the prior renderer
  // disappeared during preflight. Recover once; transactions started by this
  // mounted instance have no boot marker and are left alone.
  const bootPendingDispatchRef = useRef(arun.pendingDispatch?.id)
  const setQueuePaused = (paused: boolean) => {
    queuePausedRef.current = paused
    setThreadQueuePaused(active.id, paused, projectId)
  }
  useEffect(() => { queuePausedRef.current = queuePaused }, [queuePaused])
  useEffect(() => {
    const dispatchId = bootPendingDispatchRef.current
    if (!dispatchId) return
    bootPendingDispatchRef.current = undefined
    const recovery = rollbackAssistantDispatch(active.id, dispatchId, {
      message: 'Recovered a prompt that stopped before it was sent.',
      pauseQueue: true,
    }, projectId)
    if (recovery !== 'none') {
      queuePausedRef.current = true
      setNotice(recovery === 'draft'
        ? 'Your unsent prompt was restored after the interrupted preflight.'
        : 'Your unsent prompt was restored to the paused queue.')
    }
  }, [active.id, projectId, rollbackAssistantDispatch])
  const queuePrompt = (prompt: AssistantDraft) => {
    if (!prompt.text.trim()) return
    const queuedId = enqueueAssistantPrompt(active.id, prompt, undefined, projectId)
    if (!queuedId) {
      setNotice('The queue is full. Let one prompt run or delete one before adding another.')
      return
    }
    // A successfully accepted user enqueue is an explicit resume after Stop.
    setQueuePaused(false)
    clearAssistantDraft(active.id, { keepSpeed: true }, projectId)
    resetComposerHeight()
  }
  const send = async () => {
    const prompt = currentPrompt()
    if (!prompt.text) return
    // A turn in flight → the message QUEUES (the button says so). Each queued
    // row carries an explicit Steer action for injecting it mid-turn; sending
    // must never steer on its own — that made "queue" silently mean "send now".
    if (busy || queuedPrompts.length > 0) {
      queuePrompt(prompt); return
    }
    setQueuePaused(false)
    void sendText(prompt, { clearDraft: true, restoreOnFailure: true, expectedDraft: prompt })
  }
  /** Deliver a follow-up into the running turn (mid-turn steer). The user turn
   * is appended optimistically and the agent's steered reply streams after it on
   * the active turn's channel. On refusal (turn ended, or the agent can't queue
   * after all) it rolls back and falls back to the normal queue. */
  const steeringIdsRef = useRef(new Set<string>())
  const steerText = async (prompt: QueuedAssistantPrompt) => {
    if (steeringIdsRef.current.has(prompt.id)) return
    steeringIdsRef.current.add(prompt.id)
    const text = prompt.text.trim().slice(0, ASSISTANT_DRAFT_TEXT_LIMIT)
    if (!text) { steeringIdsRef.current.delete(prompt.id); return }
    const threadId = active.id
    const files = prompt.attachments
    const mns = prompt.mentions
    const refLine = [...mns.map((m) => `@${m.label}`), ...files.map((f) => `📎 ${f.split('/').pop() ?? ''}`)].join('  ·  ')
    const shownText = refLine ? `${text}\n\n${refLine}` : text
    const mentionPrefix = mns.length ? `Referenced from the research project (use if relevant):\n${mns.map((m) => `- ${m.text}`).join('\n')}\n\n` : ''
    const filePrefix = files.length ? `Attached files (read them if relevant):\n${files.join('\n')}\n\n` : ''
    const steerEpoch = dispatchEpochRef.current
    const steerStillCurrent = () => {
      const owner = owningSlice()
      const current = owner?.assistantThreads.find((candidate) => candidate.id === threadId)
      const queued = owner?.assistantPromptQueues[threadId]?.some((candidate) => candidate.id === prompt.id)
      return dispatchEpochRef.current === steerEpoch && !!current?.busy && !current.queuePaused && current.agentKey === agentKey && !!queued
    }
    try {
      const images = (
        await Promise.all(
          files.flatMap((f) => /\.(png|jpe?g|gif|webp)$/i.test(f)
            ? [bridge.fs.readImage(f).then((r) =>
              r.ok && r.data && r.mimeType ? { mimeType: r.mimeType, data: r.data } : null,
            )]
            : []),
        )
      ).filter((i): i is { mimeType: string; data: string } => i !== null)
      // The durable queue row is still present. Stop can therefore win this
      // preflight without any local-only prompt state to lose.
      if (!steerStillCurrent()) return
      const dispatchId = `steer-${globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`}`
      const userTurn: Turn = { kind: 'user', text: shownText, at: Date.now(), dispatchId }
      updateRuntime(threadId, (runtime) => ({ ...runtime, turns: [...runtime.turns, userTurn] }))
      let res: { ok: boolean; message?: string }
      try {
        res = await bridge.acp.steer(connectionKey, `${mentionPrefix}${filePrefix}${text}`, images.length ? images : undefined, projectId)
      } catch (error) {
        res = { ok: false, message: String((error as Error)?.message ?? error) }
      }
      if (res.ok) {
        removeQueuedAssistantPrompt(threadId, prompt.id, projectId)
        updateRuntime(threadId, (runtime) => ({
          ...runtime,
          turns: runtime.turns.map((turn) => {
            if (turn.dispatchId !== dispatchId) return turn
            const { dispatchId: _dispatch, ...committed } = turn
            return committed
          }),
        }))
      } else {
        updateRuntime(threadId, (runtime) => ({ ...runtime, turns: runtime.turns.filter((turn) => turn.dispatchId !== dispatchId) }))
        if (res.message && steerStillCurrent()) setNotice(res.message)
      }
    } catch (error) {
      // Image preparation failed before provider delivery. Keep the original
      // row exactly where it is; Stop may already have paused that queue.
      if (steerStillCurrent()) setNotice(String((error as Error)?.message ?? 'The queued attachment could not be prepared.'))
    } finally {
      steeringIdsRef.current.delete(prompt.id)
    }
  }
  /** The composer's send, callable with explicit text (the ⌘L bar uses it). */
  const sendText = async (
    promptOrText: string | AssistantDraft,
    opts: { clearDraft?: boolean; restoreOnFailure?: boolean; expectedDraft?: AssistantDraft; claimQueueIds?: string[] } = {},
  ): Promise<boolean> => {
    const rawPrompt: AssistantDraft =
      typeof promptOrText === 'string'
        ? { ...EMPTY_DRAFT, text: promptOrText.trim(), speed }
        : { ...promptOrText, text: promptOrText.text.trim(), speed: promptOrText.speed ?? speed }
    const wasTrimmed = rawPrompt.text.length > ASSISTANT_DRAFT_TEXT_LIMIT
    const prompt: AssistantDraft = { ...rawPrompt, text: rawPrompt.text.slice(0, ASSISTANT_DRAFT_TEXT_LIMIT) }
    if (!prompt.text) return false
    // Queued Mesh work is scoped to one durable stage attempt. Treat an old
    // attempt as already handled so the queue drain never restores it after a
    // Stop -> Continue retry minted a replacement.
    const meshAttemptIsCurrent = () => isCurrentMeshOrchestration(prompt.orchestration, owningSlice()?.assistantThreads ?? [])
    const discardClaimedStaleAttempt = () => {
      for (const promptId of opts.claimQueueIds ?? []) removeQueuedAssistantPrompt(active.id, promptId, projectId)
    }
    if (!meshAttemptIsCurrent()) { discardClaimedStaleAttempt(); return true }
    if (providerSwitchRef.current) return false
    if (owningSlice()?.assistantThreads.find((t) => t.id === active.id)?.busy) return false
    if (!(await ensureAgentConnected())) return false
    if (!meshAttemptIsCurrent()) { discardClaimedStaleAttempt(); return true }
    if (owningSlice()?.assistantThreads.find((t) => t.id === active.id)?.queuePaused) return false
    if (wasTrimmed) setNotice(`Message limited to ${ASSISTANT_DRAFT_TEXT_LIMIT.toLocaleString()} characters to keep the IDE responsive. Attach long material as a file to preserve it in full.`)
    const threadId = active.id
    // Snapshot the live permission mode with every send — the agent itself can
    // flip modes mid-session (e.g. leaving plan mode), and only what's saved
    // here survives a reconnect.
    {
      const liveMode = controls.find((c) => c.kind === 'mode')?.value
      if (liveMode) setThreadPermissionMode(threadId, liveMode, projectId)
    }
    if (owningSlice()?.assistantThreads.find((t) => t.id === threadId)?.busy) return false
    if (providerSwitchRef.current) return false
    const files = prompt.attachments
    const mns = prompt.mentions
    const refLine = [...mns.map((m) => `@${m.label}`), ...files.map((f) => `📎 ${f.split('/').pop() ?? ''}`)].join('  ·  ')
    const shownText = refLine ? `${prompt.text}\n\n${refLine}` : prompt.text
    const dispatchEpoch = ++dispatchEpochRef.current
    // This single store transaction is the durable preflight boundary: Stop,
    // Close, persistence, and the transcript can never observe a cleared draft
    // without also knowing exactly how to restore its optimistic user row.
    const pendingDispatch = beginAssistantDispatch(threadId, prompt, shownText, {
      clearDraft: opts.clearDraft,
      restoreToDraft: opts.restoreOnFailure,
      expectedDraft: opts.expectedDraft,
      claimQueueIds: opts.claimQueueIds,
    }, projectId)
    // A queue claim can lose only to another synchronous queue/store action.
    // The authoritative rows therefore remain durable and need no local retry.
    if (!pendingDispatch) return !!opts.claimQueueIds?.length
    const first = pendingDispatch.first
    const userTurn: Turn = {
      kind: 'user',
      text: pendingDispatch.turnText,
      at: pendingDispatch.turnAt,
      dispatchId: pendingDispatch.id,
    }
    // per-prompt checkpoint (Claude Code's /rewind grammar): snap the working
    // tree BEFORE the agent acts, attach the id to this turn — the turn rail
    // grows a "Restore files" affordance. Non-blocking: the snapshot races the
    // prompt harmlessly (it captures pre-turn state either way, git is fast).
    {
      const turnAt = userTurn.at
      void useKaisola.getState().snapshotWorkspace(`Before “${prompt.text.slice(0, 40)}”`, projectId).then((ckpt) => {
        if (!ckpt) return
        updateRuntime(threadId, (r) => ({
          ...r,
          turns: r.turns.map((x) => (x.kind === 'user' && x.at === turnAt && (!x.dispatchId || x.dispatchId === pendingDispatch.id) ? { ...x, checkpointId: ckpt.id } : x)),
        }))
      })
    }
    if (opts.clearDraft) {
      resetComposerHeight()
    }
    const mentionPrefix = mns.length ? `Referenced from the research project (use if relevant):\n${mns.map((m) => `- ${m.text}`).join('\n')}\n\n` : ''
    const filePrefix = files.length ? `Attached files (read them if relevant):\n${files.join('\n')}\n\n` : ''
    const dispatchInvalid = () => {
      const owner = owningSlice()
      const current = owner?.assistantThreads.find((candidate) => candidate.id === threadId)
      return dispatchEpochRef.current !== dispatchEpoch || providerSwitchRef.current || !current?.busy || !!current.queuePaused || current.agentKey !== agentKey
    }
    const settleBeforeDispatch = (message: string, stopReason = 'cancelled') => {
      const recovery = rollbackAssistantDispatch(threadId, pendingDispatch.id, { message, stopReason }, projectId)
      if (recovery !== 'none') setNotice(() => message)
      if (recovery === 'queue') {
        queuePausedRef.current = true
        useKaisola.getState().pushToast('info', 'Stopped prompt kept in the paused queue')
      }
      // Preflight rollback now preserves the prompt itself. Report it handled so
      // queue/Omni callers do not enqueue a duplicate after Stop already won.
      return true
    }
    let nativeSpeedApplied = false
    try {
      nativeSpeedApplied = await applySpeed({ speed: prompt.speed })
    } catch (error) {
      return settleBeforeDispatch(String((error as Error)?.message ?? 'The provider setting could not be applied.'), 'preflight_failed')
    }
    if (dispatchInvalid()) return settleBeforeDispatch('Stopped before the prompt was sent.')
    const payload = `${speedGuidance(prompt.speed, nativeSpeedApplied)}${usageWarningContext()}${first ? `${buildContext()}\n\n` : ''}${mentionPrefix}${filePrefix}${prompt.text}`
    // image attachments ALSO ride as real ACP image blocks (pixels, not a
    // path) for agents that take them; the path stays in filePrefix above as
    // the text-only fallback. Unreadable/oversized images just stay paths.
    let images: Array<{ mimeType: string; data: string }> = []
    try {
      images = (
        await Promise.all(
          files.flatMap((f) => /\.(png|jpe?g|gif|webp)$/i.test(f)
            ? [bridge.fs.readImage(f).then((r) =>
              r.ok && r.data && r.mimeType ? { mimeType: r.mimeType, data: r.data } : null,
            )]
            : []),
        )
      ).filter((i): i is { mimeType: string; data: string } => i !== null)
    } catch (error) {
      return settleBeforeDispatch(String((error as Error)?.message ?? 'An image attachment could not be prepared.'), 'preflight_failed')
    }
    if (dispatchInvalid()) return settleBeforeDispatch('Stopped before the prompt was sent.')
    // Every preflight completed and this generation still owns the thread.
    // From this point onward the prompt may reach the provider.
    if (!commitAssistantDispatch(threadId, pendingDispatch.id, projectId)) return true
    autoNameThread(threadId, prompt.text, projectId) // first delivered attempt → topic title
    const stream = makeOnUpdate(threadId)
    let res: { ok: boolean; stopReason?: string; message?: string }
    try {
      res = await bridge.acp.prompt(connectionKey, payload, stream.onUpdate, images.length ? images : undefined, projectId)
    } catch (err) {
      res = { ok: false, message: String((err as Error)?.message ?? err) }
    }
    stream.flush() // drain any buffered tail before settling the turn
    // Stop/provider changes can invalidate this closure while main settles a
    // cooperative cancellation. A stale completion must never clear or write
    // into a newer provider turn for the same thread.
    if (dispatchEpochRef.current !== dispatchEpoch) return false
    updateRuntime(threadId, (r) => {
      let turns = r.turns
      if (r.thinkStart != null) {
        const ms = Date.now() - r.thinkStart
        turns = [...turns]
        for (let i = turns.length - 1; i >= 0; i--) {
          if (turns[i].kind === 'thought') { turns[i] = { ...turns[i], thinkMs: turns[i].thinkMs ?? ms }; break }
        }
      }
      // stamp how long the agent worked on this prompt (rendered as a quiet
      // "Worked for X" row when the exchange settles; steered follow-ups fold
      // into the original exchange's span, which is what a reader expects).
      // Only on success: a rejected prompt is removed below when no response
      // followed it, even if checkpoint metadata replaced the turn object.
      const completed = res.ok && (!res.stopReason || res.stopReason === 'end_turn')
      if (completed && userTurn.at != null) {
        const startedAt = userTurn.at
        turns = turns.map((x) => (x.kind === 'user' && x.at === startedAt && x.workedMs == null ? { ...x, workedMs: Date.now() - startedAt } : x))
      }
      const responseText = turns
        .flatMap((turn) => {
          const text = turn.text.trim()
          return turn.kind === 'assistant' && (turn.at ?? 0) >= (userTurn.at ?? 0) && text ? [text] : []
        })
        .join('\n\n')
        .slice(-28_000)
      return {
        ...r,
        thinkStart: undefined,
        turns,
        lastRun: {
          ...(prompt.orchestration ? {
            attemptId: prompt.orchestration.attemptId,
            groupId: prompt.orchestration.groupId,
            phase: prompt.orchestration.phase,
          } : {}),
          startedAt: userTurn.at ?? Date.now(),
          finishedAt: Date.now(),
          ok: completed,
          ...(responseText ? { text: responseText } : {}),
          ...(res.stopReason ? { stopReason: res.stopReason } : {}),
          ...(res.message ? { message: res.message } : {}),
        },
      }
    })
    setThreadBusy(threadId, false, projectId)
    // Working dots pulse; a finished unseen turn becomes a still dot until the
    // owning tab/card is actually viewed and focused.
    {
      const state = useKaisola.getState()
      const owner = owningSlice()
      // Private group workers report completion through their visible parent;
      // otherwise the inbox would point at an intentionally hidden child tab.
      const attentionId = active.groupParentId ?? threadId
      const seen = state.activeProjectId === projectId && !!owner?.dockOpen && !!owner?.dockViews.includes(attentionId) && !document.hidden && document.hasFocus()
      if (!seen) {
        state.markNeedsYou(attentionId, projectId)
        const tab = state.projectTabs.find((project) => project.id === projectId)
        const projectName = tab?.title ?? tab?.workspacePath?.split('/').filter(Boolean).pop() ?? 'Kaisola'
        bridge.attention?.notify({
          title: res.ok && (!res.stopReason || res.stopReason === 'end_turn') ? `${agentName} finished` : `${agentName} stopped`,
          body: projectName,
          projectId,
          sessionId: attentionId,
        })
      }
      if (state.activeProjectId !== projectId) state.setProjectActivity(projectId, res.ok && (!res.stopReason || res.stopReason === 'end_turn') ? 'completed' : 'failed')
    }
    if (!res.ok) {
      // the prompt was rejected — roll back the optimistic user turn so the
      // transcript doesn't strand an undelivered message. ONLY when nothing
      // streamed after it (the mid-turn / not-connected rejections reply nothing):
      // if the agent crashed mid-reply, keep the [user, partial-reply] pair coherent.
      updateRuntime(threadId, (r) => {
        let index = -1
        for (let i = r.turns.length - 1; i >= 0; i--) {
          const turn = r.turns[i]
          if (turn.kind === 'user' && turn.at === userTurn.at && turn.text === userTurn.text) { index = i; break }
        }
        // If anything streamed after the user row, keep the partial exchange.
        // Otherwise remove it even when the async checkpoint replaced identity.
        return index >= 0 && index === r.turns.length - 1
          ? { ...r, turns: r.turns.slice(0, index), first }
          : r
      })
      if (res.message) { setNotice(res.message); refresh() }
      if (opts.restoreOnFailure) {
        const cur = owningSlice()?.assistantDrafts[threadId] ?? EMPTY_DRAFT
        if (!cur.text && cur.attachments.length === 0 && cur.mentions.length === 0) setAssistantDraft(threadId, prompt, projectId)
      }
      return false
    }
    if (res.stopReason && res.stopReason !== 'end_turn') {
      setQueuePaused(true)
      setNotice(res.message ?? `The agent stopped with ${res.stopReason.replaceAll('_', ' ')}. Review the partial response, then resume or retry.`)
      return false
    }
    // Wake the queue in the same microtask as turn settlement. Waiting for the
    // busy=false React render made follow-ups feel noticeably sticky on fast
    // Codex/Claude turns even though the queue was already ready in the store.
    queueMicrotask(() => { void drainQueuedPrompts() })
    return true
  }
  const drainQueuedPrompts = async () => {
    if (queuePausedRef.current || drainingQueueRef.current) return
    drainingQueueRef.current = true
    try {
      // Queue producers such as Mesh and the command palette live outside this
      // component. Always probe/reconnect before draining: renderer connection
      // state can be stale after an idle park, restart, or explicit stage
      // transition disconnect. The queued prompt remains durable on failure.
      if (!(await ensureAgentConnected())) return
      // Keep ownership in one async loop. A ref alone cannot wake React after
      // finally; the old one-shot effect therefore stranded item 2 forever.
      while (!queuePausedRef.current) {
        const owner = owningSlice()
        const thread = owner?.assistantThreads.find((candidate) => candidate.id === active.id)
        const waiting = owner?.assistantPromptQueues[active.id] ?? EMPTY_QUEUE
        if (!thread || thread.busy || thread.queuePaused || waiting.length === 0) return
        const batch = nextQueuedDispatchBatch(waiting)
        if (!batch.length) return
        const combined = mergeQueuedPrompts(batch)
        const sent = await sendText(combined, { claimQueueIds: batch.map((prompt) => prompt.id) })
        if (!sent) {
          // Pause BEFORE restoring so the queue-length render cannot race an
          // immediate retry. A new user enqueue or reconnect resumes it.
          setQueuePaused(true)
          const latestQueue = owningSlice()?.assistantPromptQueues[active.id] ?? []
          const originalsRemain = batch.every((prompt) => latestQueue.some((queued) => queued.id === prompt.id))
          if (!originalsRemain) {
            enqueueAssistantPrompt(active.id, combined, { front: true, resume: false, preserveAccepted: true }, projectId)
          }
          useKaisola.getState().pushToast('warn', `${agentName} queue paused — send or queue a prompt to resume`)
          return
        }
        const remaining = owningSlice()?.assistantPromptQueues[active.id] ?? []
        if (batch.every((prompt) => remaining.some((queued) => queued.id === prompt.id))) return
        // Anything typed while that combined prompt ran is now waiting in the
        // store and is picked up by this same loop without needing a re-render.
      }
    } finally {
      drainingQueueRef.current = false
    }
  }
  useEffect(() => {
    if (busy || queuePaused || queuePausedRef.current || drainingQueueRef.current || queuedPrompts.length === 0) return
    void drainQueuedPrompts()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [connected, busy, queuePaused, queuedPrompts.length, active.id])
  // the ⌘L bar hands prompts to threads through the store — deliver ours once
  const omniPrompt = useKaisola((s) => s.omniPrompt)
  const omniSeqRef = useRef(0)
  useEffect(() => {
    if (!omniPrompt || omniPrompt.threadId !== threadId || omniPrompt.seq === omniSeqRef.current) return
    const text = omniPrompt.text
    if (busy || queuedPrompts.length > 0) {
      // same rule as the composer: busy → queue; steering is only ever the
      // explicit per-row action on a queued prompt
      const queuedId = enqueueAssistantPrompt(active.id, { ...EMPTY_DRAFT, text: text.trim(), speed }, undefined, projectId)
      if (!queuedId) {
        setNotice('The queue is full. Your command-bar prompt is still waiting and will retry when space opens.')
        return
      }
      omniSeqRef.current = omniPrompt.seq
      useKaisola.getState().clearOmniPrompt()
      setQueuePaused(false)
      return
    }
    omniSeqRef.current = omniPrompt.seq
    void sendText(text).then((sent) => {
      // never swallow a ⌘L prompt: a race-y busy flip QUEUES it (review
      // finding #4 — it used to be dropped with a misleading toast)
      if (sent) {
        useKaisola.getState().clearOmniPrompt()
        return
      }
      const queuedId = enqueueAssistantPrompt(active.id, { ...EMPTY_DRAFT, text: text.trim(), speed }, undefined, projectId)
      if (queuedId) {
        useKaisola.getState().clearOmniPrompt()
        setQueuePaused(false)
      } else {
        omniSeqRef.current = 0
        setNotice('The queue is full. Your command-bar prompt is still waiting and will retry when space opens.')
      }
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [omniPrompt, threadId, busy, queuedPrompts.length])
  const cancelActive = () => {
    // Stop means STOP: pause the queue too, or flipping busy would auto-fire
    // the next queued prompt the instant the user aborts (review finding #2)
    dispatchEpochRef.current++
    queuePausedRef.current = true
    const recovery = rollbackAssistantDispatch(active.id, undefined, {
      message: 'Stopped before the prompt was sent.',
      pauseQueue: true,
    }, projectId)
    if (recovery === 'none') setThreadQueuePaused(active.id, true, projectId)
    if (queuedPrompts.length > 0) {
      useKaisola.getState().pushToast('info', 'Queue paused — send or queue a prompt to resume')
    } else if (recovery === 'queue') {
      useKaisola.getState().pushToast('info', 'Stopped prompt kept in the paused queue')
    }
    void bridge.acp.cancel(connectionKey, projectId)
    if (recovery === 'none') {
      setThreadBusy(active.id, false, projectId)
      updateRuntime(active.id, (r) => ({ ...r, thinkStart: undefined }))
    } else {
      setNotice('Stopped before the prompt was sent.')
    }
  }
  const attach = async () => {
    const r = await bridge.pickFiles()
    if (r.ok && r.paths) setAssistantDraft(active.id, { attachments: [...new Set([...attachments, ...r.paths])] }, projectId)
  }
  const attachPaper = (paper: Paper) => setAssistantDraft(active.id, {
    mentions: [...mentions.filter((mention) => !(mention.kind === 'paper' && mention.id === paper.id)), {
      id: paper.id,
      kind: 'paper',
      label: paper.title,
      text: `${paper.title}${paper.authors.length ? ` — ${paper.authors.join(', ')}` : ''}${paper.summary || paper.abstract ? `: ${paper.summary ?? paper.abstract}` : ''}`,
    }],
  }, projectId)
  // How much of a prior session rides along as context. Turns are capped
  // individually so one giant paste can't crowd out the rest, and trimming
  // keeps the TAIL — the most recent exchanges are the ones that matter.
  const ATTACH_SESSION_TURNS = 60
  const ATTACH_SESSION_CHARS = 80_000
  const ATTACH_SESSION_TURN_CHARS = 6_000
  const attachSession = async (thread: AssistantThread) => {
    const runtime = useKaisola.getState().assistantRuntimes[thread.id]
    const usable = (turn: Turn) => (turn.kind === 'user' || turn.kind === 'assistant') && !!turn.text
    let turns = (runtime?.turns ?? []).filter(usable)
    // Older turns live in main's append-only archive, not the renderer page —
    // pull the newest archived window so attaching a long/closed session
    // carries real content instead of "(transcript currently stored on disk)".
    if (turns.length < ATTACH_SESSION_TURNS && bridge.assistantArchive) {
      try {
        const scope = { projectId, threadId: thread.id, ...(runtime?.archiveEpoch ? { epoch: runtime.archiveEpoch } : {}) }
        const page = await bridge.assistantArchive.page(scope, undefined, ATTACH_SESSION_TURNS)
        if (page.ok) {
          const archived = page.turns.map(archivedTurn).filter((turn): turn is Turn => !!turn && usable(turn))
          turns = [...archived, ...turns]
        }
      } catch { /* live turns only */ }
    }
    const transcript = turns
      .slice(-ATTACH_SESSION_TURNS)
      .map((turn) => `${turn.kind === 'user' ? 'User' : 'Agent'}: ${turn.text.length > ATTACH_SESSION_TURN_CHARS ? `${turn.text.slice(0, ATTACH_SESSION_TURN_CHARS)} …` : turn.text}`)
      .join('\n')
      .slice(-ATTACH_SESSION_CHARS)
    const label = thread.name ?? thread.autoName ?? thread.agentKey
    setAssistantDraft(active.id, {
      mentions: [...mentions.filter((mention) => !(mention.kind === 'run' && mention.id === thread.id)), {
        id: thread.id,
        kind: 'run',
        label,
        text: `Prior Kaisola session “${label}”${transcript ? `:\n${transcript}` : ' (no transcript recorded yet)'}`,
      }],
    }, projectId)
  }
  // the foot's agent picker re-points the active thread to a different agent
  const setThreadAgent = async (key: string) => {
    const preset = presets.find((p) => p.id === key)
    if (preset?.terminalOnly) { openTerminalPreset(preset); return }
    if (key === agentKey || providerSwitchRef.current) return
    const owner = owningSlice()
    const current = owner?.assistantThreads.find((candidate) => candidate.id === active.id)
    if (current?.busy || (owner?.assistantPromptQueues[active.id]?.length ?? 0) > 0 || permsForAgent.length > 0) {
      useKaisola.getState().pushToast('warn', 'Stop this agent and clear its queued prompts before changing providers.')
      return
    }
    providerSwitchRef.current = true
    try {
      const status = await bridge.acp.status([connectionKey], projectId).catch(() => ({ ok: false, agents: [] }))
      if (status.agents.some((agent) => agent.key === connectionKey && agent.busy)) {
        useKaisola.getState().pushToast('warn', 'The provider is still finishing a turn. Stop it before switching.')
        return
      }
      dispatchEpochRef.current++
      const disconnected = await bridge.acp.disconnect(connectionKey, projectId).catch(() => ({ ok: false }))
      if (!disconnected.ok) {
        useKaisola.getState().pushToast('warn', 'The current provider could not be disconnected safely.')
        return
      }
      const latest = owningSlice()?.assistantThreads.find((candidate) => candidate.id === active.id)
      if (!latest || latest.busy || latest.agentKey !== agentKey) return
      setStoreThreadAgent(active.id, key)
      resetAssistantRuntime(active.id, projectId)
      setAgents([])
    } finally {
      providerSwitchRef.current = false
    }
  }

  return (
    <div
      className="assistant"
      data-thread-id={active.id}
      data-prompt-tabs={prompts.length > 0 || undefined}
      data-file-drop={fileDropHover || undefined}
      onDragOver={(e) => {
        if (!e.dataTransfer?.types.includes('Files')) return
        e.preventDefault()
        e.stopPropagation()
        if (!fileDropHover) setFileDropHover(true)
      }}
      onDragLeave={(e) => {
        if (fileDropHover && !e.currentTarget.contains(e.relatedTarget as Node)) setFileDropHover(false)
      }}
      onDrop={(e) => {
        setFileDropHover(false)
        const files = Array.from(e.dataTransfer?.files ?? [])
        if (!files.length) return
        e.preventDefault()
        e.stopPropagation() // the window-level handler would open it as a file tab
        const paths = files.flatMap((file) => {
          const path = bridge.pathForFile?.(file)
          return path ? [path] : []
        })
        if (!paths.length) return
        setAssistantDraft(active.id, { attachments: [...new Set([...attachments, ...paths])] }, projectId)
        inputRef.current?.focus()
      }}
    >
      {/* Prompt history stays out of the chrome: a quiet top-right rail reveals
          previews on hover and still supports click-to-jump for every agent. */}
      {(prompts.length > 0 || canLoadArchive) && (
        <div className="turn-rail" ref={promptRailRef} onMouseLeave={() => setPromptHover(null)} aria-label="Prompt history">
          <div className="turn-rail-markers">
            {canLoadArchive && (
              <button
                type="button"
                className="turn-rail-history"
                disabled={archiveLoading}
                onClick={() => { void loadOlderTurns() }}
                title="Load older prompts from Kaisola's disk archive"
                aria-label="Load older prompts"
              >
                <Icon name="History" size={11} />
              </button>
            )}
            {prompts.map((p, n) => (
              <button
                type="button"
                key={`${p.idx}-${p.turn.at ?? n}`}
                className="turn-rail-marker turn-tab-prompt"
                data-active={p.idx === activePrompt}
                aria-current={p.idx === activePrompt ? 'step' : undefined}
                onMouseEnter={(e) => {
                  const railHeight = promptRailRef.current?.clientHeight ?? 260
                  setPromptHover({ idx: p.idx, top: Math.max(0, Math.min(e.currentTarget.offsetTop - 12, railHeight - 150)) })
                }}
                onClick={() => jumpToTurn(p.idx)}
                title={p.turn.text}
                aria-label={`Prompt ${n + 1}: ${p.turn.text}`}
              >
                <span />
              </button>
            ))}
          </div>
          {promptHover && (() => {
            const p = prompts.find((candidate) => candidate.idx === promptHover.idx)
            if (!p) return null
            const reply = replyPreview(p.idx)
            return (
              <div className="turn-pop" style={{ top: promptHover.top }}>
                <div className="turn-pop-title">{p.turn.text}</div>
                {reply.text && <div className="turn-pop-preview">{reply.text}</div>}
                <div className="turn-pop-meta">
                  {reply.tools > 0 && <span>{reply.tools} tool call{reply.tools === 1 ? '' : 's'}</span>}
                  {p.turn.at != null && <span>{clockTime(new Date(p.turn.at).toISOString())}</span>}
                </div>
                {p.turn.checkpointId && (
                  <button
                    type="button"
                    className="turn-pop-restore"
                    onClick={() => {
                      const st = useKaisola.getState()
                      void st.restoreRepoCheckpoint(p.turn.checkpointId!).then(() => {
                        st.pushToast('success', 'Files restored to before this prompt. The agent doesn’t know — mention it in your next message.')
                      })
                      setPromptHover(null)
                    }}
                    title="Reset the working tree to how it was before this prompt ran (conversation stays)"
                  >
                    <Icon name="History" size={11} /> Restore files to here
                  </button>
                )}
              </div>
            )
          })()}
        </div>
      )}
      {(arun.plan?.length ?? 0) > 0 && <div className="plan-shelf"><PlanStrip plan={arun.plan!} /></div>}
      <div
        className="assistant-stream"
        ref={scrollRef}
        onScroll={onStreamScroll}
        onWheel={onStreamWheel}
        onTouchStart={onStreamTouchStart}
        onTouchMove={onStreamTouchMove}
        onTouchEnd={() => { archiveTouchYRef.current = null }}
        onPointerDown={onStreamPointerDown}
        onPointerUp={onStreamPointerUp}
        onPointerCancel={onStreamPointerUp}
        onKeyDown={onStreamKeyDown}
        tabIndex={0}
        aria-label="Assistant transcript"
      >
        {notice && (
          <div className="assistant-nokey">
            <Icon name={awaitingAuth || authUrl ? 'KeyRound' : 'Info'} size={15} />
            <div className="grow">{notice}</div>
            {awaitingAuth ? (
              <button type="button" className="btn btn-primary btn-sm" onClick={() => { void reconnectAfterAuth() }}>
                <Icon name="RefreshCw" size={13} /> Reconnect
              </button>
            ) : authUrl ? (
              <button type="button" className="btn btn-primary btn-sm" onClick={authorize}>
                <Icon name="KeyRound" size={13} /> Authorize
              </button>
            ) : (
              <button type="button" className="btn btn-ghost btn-sm" onClick={() => openSettings(true)}><Icon name="Settings" size={13} /> Settings</button>
            )}
            <button type="button" className="btn-icon btn-sm" aria-label="Dismiss notice" onClick={() => { setNotice(null); setAuthUrl(null); awaitingAuthRef.current = false; setAwaitingAuth(false) }}><Icon name="X" size={13} /></button>
          </div>
        )}
        {showLiveActivity && (
          <div className="agent-livebar" aria-live="polite">
            <span className="agent-live-dot" aria-hidden />
            <Icon name={latestActivityKind?.icon ?? 'Sparkles'} size={12} />
            <span className="grow truncate">
              {latestActivity?.text || (liveAgentTerminals.length ? 'Running a terminal task' : `${agentName} is working`)}
            </span>
            {busy && prompts.length > 0 && prompts[prompts.length - 1].turn.at != null && (
              // ticks on the existing 500ms busy re-render
              <span className="agent-live-elapsed mono">{workedTime(Date.now() - prompts[prompts.length - 1].turn.at!)}</span>
            )}
            {subagentCount > 0 && <span className="agent-live-pill"><Icon name="Bot" size={10} /> {subagentCount}</span>}
            {liveAgentTerminals.map((term) => (
              <button type="button" key={term.terminalId} className="agent-live-pill" onClick={() => setDockView(term.terminalId)} title={term.command || term.label || 'Open terminal'}>
                <Icon name="TerminalSquare" size={10} /> {term.label || 'Terminal'}
              </button>
            ))}
          </div>
        )}
        {canLoadArchive && (
          <button
            type="button"
            className="assistant-load-history"
            disabled={archiveLoading}
            onClick={() => { void loadOlderTurns() }}
            title={archiveError ?? 'Scroll upward to load one older page'}
          >
            <Icon name="History" size={12} />
            {archiveLoading
              ? 'Loading history…'
              : archiveError
                ? 'Retry older history'
                : `Older history loads as you scroll · ${Math.max(0, archiveBefore ?? archivedCount)} earlier`}
          </button>
        )}
        {archivedPage.map((row) => (
          <TurnRow
            key={`${row.index}:${turnKey(row.turn)}`}
            t={row.turn}
            i={row.index}
            agentName={agentName}
            showCaret={false}
            rowKey={`archive-${row.index}`}
          />
        ))}
        {archiveGap && (
          <button type="button" className="assistant-load-history" disabled={archiveLoading} onClick={() => { void loadOlderTurns(true) }}>
            <Icon name="RotateCcw" size={12} />
            Return to recent archived history
          </button>
        )}
        {arun.turns.map((t, i) => {
          // "Worked for X" closes each settled exchange: at the last turn before
          // the next user prompt (or transcript end), surface the owning user
          // turn's workedMs. The live exchange has no stamp yet, so nothing
          // renders under a running turn.
          const next = arun.turns[i + 1]
          let worked: number | undefined
          if (!next || next.kind === 'user') {
            for (let j = i; j >= 0; j--) {
              const u = arun.turns[j]
              if (u.kind === 'user') { worked = u.workedMs; break }
            }
          }
          return (
            <Fragment key={turnKey(t)}>
              <TurnRow
                t={t}
                i={liveIndexBase + i}
                agentName={agentName}
                showCaret={busy && i === arun.turns.length - 1}
                liveThinkStart={t.kind === 'thought' && t.thinkMs == null ? arun.thinkStart : undefined}
                rowKey={`live-${turnKey(t)}`}
              />
              {worked != null && t.kind !== 'user' && (
                <div className="turn-worked"><Icon name="Timer" size={11} /> Worked for {workedTime(worked)}</div>
              )}
            </Fragment>
          )
        })}
        {/* the agent is BLOCKED on these — inline, non-modal, option-per-button */}
        {permsForAgent.map((perm) => (
          <PermissionCard
            key={perm.permId}
            perm={perm}
            onAllow={() => {
              const opt = perm.options.find((o) => o.kind === 'allow_once') ?? perm.options[0]
              answerPermission(perm.permId, opt ? { optionId: opt.optionId } : { decision: 'allow' })
            }}
            onAlways={() => alwaysAllowPermission(perm.permId)}
            onDeny={() => {
              const opt = perm.options.find((o) => o.kind === 'reject_once')
              answerPermission(perm.permId, opt ? { optionId: opt.optionId } : { decision: 'reject' }, { cascadeReject: true })
            }}
          />
        ))}
      </div>

      <div className="composer-stack">
        {queuedPrompts.length > 0 && (
          <div className="composer-queue-preview" aria-label="Queued prompts">
            {queuedPrompts.map((q) => (
              <div key={q.id} className="composer-queue-preview-row" title={q.text}>
                <Icon className="composer-queue-mark" name="CornerDownRight" size={15} aria-hidden="true" />
                <span className="composer-queue-text">{q.text}</span>
                <span className="composer-queue-actions">
                  {busy && (
                    <button
                      type="button"
                      className="composer-queue-action composer-queue-steer"
                      onClick={() => {
                        if (!canSteer) {
                          setNotice(`${agentName} will receive this next; mid-turn steering is not available for this connection.`)
                          return
                        }
                        void steerText(q)
                      }}
                      title={canSteer ? `Steer ${agentName} now` : `${agentName} will receive this next; mid-turn steering is unavailable`}
                      aria-label={canSteer ? `Steer ${agentName} with queued prompt now` : `Steering ${agentName} is unavailable`}
                      aria-disabled={!canSteer}
                    >
                      <Icon name="CornerDownRight" size={14} />
                      <span>Steer</span>
                    </button>
                  )}
                  <button
                    type="button"
                    className="composer-queue-action"
                    onClick={() => removeQueuedAssistantPrompt(active.id, q.id, projectId)}
                    title="Delete queued prompt"
                    aria-label="Delete queued prompt"
                  >
                    <Icon name="Trash2" size={14} />
                  </button>
                  <button
                    type="button"
                    className="composer-queue-action"
                    onClick={() => {
                      if (input.trim() || attachments.length || mentions.length) {
                        setNotice('Finish or clear the current draft before editing a queued prompt.')
                        inputRef.current?.focus()
                        return
                      }
                      removeQueuedAssistantPrompt(active.id, q.id, projectId)
                      setAssistantDraft(active.id, {
                        text: q.text,
                        attachments: q.attachments,
                        mentions: q.mentions,
                        speed: q.speed,
                      }, projectId)
                      requestAnimationFrame(() => {
                        if (!inputRef.current) return
                        autoGrow(inputRef.current)
                        inputRef.current.focus()
                      })
                    }}
                    title="Edit queued prompt"
                    aria-label="Edit queued prompt"
                  >
                    <Icon name="Ellipsis" size={15} />
                  </button>
                </span>
              </div>
            ))}
          </div>
        )}
        {commandChoices.length > 0 && (
          <div className="composer-command-palette" role="group" aria-label={`${agentName} commands`}>
            {commandChoices.map((command) => {
              const token = command.name.startsWith('$') ? command.name : `/${command.name}`
              return <button
                type="button"
                key={command.name}
                onClick={() => {
                  setAssistantDraft(active.id, { text: `${token}${command.inputHint ? ' ' : ''}` }, projectId)
                  requestAnimationFrame(() => inputRef.current?.focus())
                }}
              >
                <code>{token}</code>
                <span className="truncate">{command.description}</span>
                {command.inputHint && <small className="truncate">{command.inputHint}</small>}
              </button>
            })}
          </div>
        )}
        <div className="composer">
        {attachments.length > 0 && (
          <div className="composer-attach">
            {attachments.map((f) => (
              <span key={f} className="attach-chip" title={f}>
                <Icon name="Paperclip" size={11} /> {f.split('/').pop()}
                <button type="button" aria-label={`Remove attachment ${f.split('/').pop() ?? f}`} onClick={() => setAssistantDraft(active.id, { attachments: attachments.filter((x) => x !== f) }, projectId)}><Icon name="X" size={10} /></button>
              </span>
            ))}
          </div>
        )}
        {mentions.length > 0 && (
          <div className="composer-attach">
            {mentions.map((mn) => (
              <span key={mn.id} className="attach-chip" title={mn.text}>
                <Icon name={mentionIcon(mn.kind)} size={11} /> {mn.label.length > 30 ? `${mn.label.slice(0, 30)}…` : mn.label}
                <button type="button" aria-label={`Remove mention ${mn.label}`} onClick={() => setAssistantDraft(active.id, { mentions: mentions.filter((x) => x.id !== mn.id) }, projectId)}><Icon name="X" size={10} /></button>
              </span>
            ))}
          </div>
        )}
        <textarea
          ref={inputRef}
          className="composer-input"
          value={input}
          onChange={(e) => {
            const raw = e.target.value
            const v = raw.slice(0, ASSISTANT_DRAFT_TEXT_LIMIT)
            if (raw.length > ASSISTANT_DRAFT_TEXT_LIMIT) setNotice(`Message limited to ${ASSISTANT_DRAFT_TEXT_LIMIT.toLocaleString()} characters. Attach long material as a file to preserve it in full.`)
            setAssistantDraft(active.id, { text: v }, projectId)
            autoGrow(e.currentTarget)
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
          }}
          placeholder={`Message ${agentName}…`}
          rows={1}
          spellCheck={false}
        />
        <div className="composer-bar">
          <ComposerAddMenu
            papers={project.corpus.filter((source): source is Paper => source.kind === 'paper')}
            sessions={threads.filter((thread) => thread.id !== active.id)}
            onFiles={() => { void attach() }}
            onPaper={attachPaper}
            onSession={attachSession}
            onPlugins={() => openSettings(true, 'extensions')}
          />
          {composerControls.map((c) => (
            <Dropdown key={c.id} icon={CATEGORY_ICON[c.category]} value={c.value} options={c.options.map(({ value, name }) => ({ value, name }))} onSelect={(v) => onControlChange(c, v)} title={c.name} />
          ))}
          {!claudeAgent && !codexAgent && <Dropdown icon="Gauge" value={speed} options={SPEED_OPTIONS} onSelect={setSpeed} title="Response speed" />}
          <span className="grow" />
          {claudeAgent && (
            <ModelEffortMatrix
              provider="Claude"
              icon="Sparkles"
              models={providerModelControl?.options ?? []}
              modelValue={providerModelControl?.value ?? ''}
              efforts={claudeEffortOptions}
              effortValue={claudeEffort}
              onModel={(value) => { if (providerModelControl) void onControlChange(providerModelControl, value) }}
              onEffort={changeClaudeEffort}
            />
          )}
          {codexAgent && providerModelControl && (
            <ModelEffortMatrix
              provider="Codex"
              icon="Zap"
              codexChrome
              models={providerModelControl.options}
              modelValue={providerModelControl.value}
              efforts={providerEffortControl?.options.filter((option) => isCodexEffort(option.value)) ?? CODEX_EFFORT_OPTIONS.filter((option) => option.value !== 'max')}
              effortValue={codexEffort}
              speed={liveSpeed}
              onModel={(value) => void onControlChange(providerModelControl, value)}
              onEffort={changeCodexEffort}
              onSpeed={setSpeed}
            />
          )}
          {busy ? (
            <>
              {input.trim() && (
                <button type="button" className="composer-send composer-queue-send" onClick={send} title="Queue prompt  ⏎" aria-label="Queue prompt">
                  <Icon name="ListPlus" size={13} />
                </button>
              )}
              <button type="button" className="composer-send composer-stop" onClick={cancelActive} title="Stop output" aria-label="Stop output">
                <Icon name="Square" size={11} />
              </button>
            </>
          ) : (
            <button type="button" className="composer-send" onClick={send} disabled={!input.trim()} title="Send  ⏎" aria-label="Send message">
              <Icon name="ArrowUp" size={14} />
            </button>
          )}
        </div>
      </div>
      </div>

      {/* session identity — which agent, which folder, connection — sits quietly at the bottom */}
      <div className="assistant-foot">
        <Dropdown
          icon="Bot"
          value={agentKey}
          options={presets.flatMap((p) => !p.terminalOnly && !p.hidden ? [{ value: p.id, name: p.name }] : [])}
          onSelect={setThreadAgent}
          title="Agent for this thread"
          align="left"
          disabled={busy || queuedPrompts.length > 0 || permsForAgent.length > 0}
        />
        <button type="button" className="foot-ws drop-btn" onClick={pickWorkspace} disabled={busy} title={sessionCwd ?? 'Choose a workspace folder for the agent'}>
          <Icon name="Folder" size={12} className="drop-btn-icon" />
          <span className="drop-btn-label">{sessionCwd ? sessionCwd.split('/').filter(Boolean).pop() : 'Workspace'}</span>
        </button>
        <span className="grow" />
        <span className="foot-conn" data-on={connected}>
          <span className={`acp-dot ${connected ? 'on' : 'off'}`} />
          {connected ? (
            'Connected'
          ) : <button type="button" className="foot-link" onClick={() => { void connect(agentKey) }}>{active.acpSessionId ? 'Parked · Resume' : 'Offline · Connect'}</button>}
        </span>
      </div>
    </div>
  )
})
