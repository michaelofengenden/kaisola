import { memo, useEffect, useMemo, useRef, useState } from 'react'
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
import { stageMeta } from '../lib/stages'
import { clockTime } from '../lib/format'
import type { Paper } from '../domain/types'

type Turn = AssistantTurn
/** An @-mention of a project entity, attached to the next message as context. */
type Mention = AssistantMention
type Runtime = AssistantRuntime
type ControlKind = 'mode' | 'model' | 'config'
interface UiControl { id: string; name: string; category: string; value: string; options: { value: string; name: string; description?: string }[]; kind: ControlKind }

const ARCHIVED_TURN_KINDS = new Set<Turn['kind']>(['user', 'assistant', 'thought', 'tool'])
// History is durable in main's append-only archive. Keep only a compact page in
// Chromium: users can page through every turn, but old prose/diffs no longer
// sit duplicated in both the renderer heap and the disk archive.
const MAX_ARCHIVE_VIEW_TURNS = 48
const MAX_ARCHIVE_VIEW_BYTES = 3 * 1024 * 1024
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

const boundArchivedView = (turns: Turn[]): { turns: Turn[]; truncated: boolean } => {
  const kept: Turn[] = []
  let bytes = 0
  for (const turn of turns) {
    let size = 0
    try { size = new TextEncoder().encode(JSON.stringify(turn)).byteLength } catch { continue }
    if (kept.length >= MAX_ARCHIVE_VIEW_TURNS || (kept.length > 0 && bytes + size > MAX_ARCHIVE_VIEW_BYTES)) return { turns: kept, truncated: true }
    kept.push(turn)
    bytes += size
  }
  return { turns: kept, truncated: false }
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
  return {
    text: queue.map((prompt) => prompt.text.trim()).filter(Boolean).join('\n\n'),
    attachments: [...new Set(queue.flatMap((prompt) => prompt.attachments))].slice(0, 64),
    mentions: mergedMentions,
    speed: queue[queue.length - 1]?.speed ?? 'default',
  }
}
const SPEED_OPTIONS = [
  { value: 'default', name: 'Default' },
  { value: 'fast', name: 'Fast' },
]
const CLAUDE_EFFORT_OPTIONS = [
  { value: 'default', name: 'Default', description: 'Use this Claude model’s default effort' },
  { value: 'low', name: 'Light', description: 'Fastest · minimal thinking' },
  { value: 'medium', name: 'Medium', description: 'Moderate reasoning' },
  { value: 'high', name: 'High', description: 'Deep reasoning' },
  { value: 'xhigh', name: 'Extra High', description: 'More time for difficult work' },
  { value: 'max', name: 'Max', description: 'Maximum available effort · higher usage' },
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

function useProviderPopover(open: boolean, setOpen: (open: boolean) => void, button: React.RefObject<HTMLButtonElement>, panel: React.RefObject<HTMLDivElement>) {
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
  return above >= below
    ? { right: Math.max(8, window.innerWidth - rect.right), bottom: Math.max(8, window.innerHeight - rect.top + 7), maxHeight: above }
    : { right: Math.max(8, window.innerWidth - rect.right), top: rect.bottom + 7, maxHeight: below }
}

/** Claude's own Faster → Smarter effort treatment, backed by a real reconnect. */
function ClaudeEffortPicker({ value, options = CLAUDE_EFFORT_OPTIONS, busy, onSelect }: { value: ClaudeEffort; options?: typeof CLAUDE_EFFORT_OPTIONS; busy?: boolean; onSelect: (value: string) => void }) {
  const [open, setOpen] = useState(false)
  const button = useRef<HTMLButtonElement>(null)
  const panel = useRef<HTMLDivElement>(null)
  useProviderPopover(open, setOpen, button, panel)
  const index = Math.max(0, options.findIndex((option) => option.value === value))
  const current = options[index]
  return (
    <>
      <button ref={button} className="provider-summary-btn" data-open={open} disabled={busy} onClick={() => setOpen((state) => !state)} title="Claude effort" aria-haspopup="dialog" aria-expanded={open}>
        <span>{current?.name ?? value}</span><Icon name="ChevronDown" size={12} />
      </button>
      {open && createPortal(
        <div ref={panel} className="provider-pop claude-effort-pop" role="dialog" aria-label="Claude effort" style={{ position: 'fixed', ...popoverPosition(button.current) }}>
          <div className="provider-pop-head">
            <span className="faint">Effort</span>
            <strong>{current?.name ?? value}</strong>
            <span className="grow" />
            <Icon name="CircleHelp" size={14} className="faint" />
          </div>
          <div className="effort-axis"><span>Faster</span><span>Smarter</span></div>
          <div className="effort-track" style={{ gridTemplateColumns: `repeat(${Math.max(1, options.length)}, 1fr)` }}>
            <span className="effort-track-fill" style={{ width: `${options.length > 1 ? (index / (options.length - 1)) * 100 : 0}%` }} />
            {options.map((option, optionIndex) => (
              <button
                key={option.value}
                data-active={optionIndex === index}
                data-past={optionIndex <= index || undefined}
                onClick={() => { onSelect(option.value); setOpen(false) }}
                title={option.name}
                aria-label={`Set Claude effort to ${option.name}`}
                aria-pressed={optionIndex === index}
              ><span /></button>
            ))}
          </div>
        </div>,
        document.body,
      )}
    </>
  )
}

/** One compact Codex menu: a single surface, three name-only lists. */
function CodexAdvancedPicker({
  model,
  effort,
  effortValue,
  speed,
  onModel,
  onEffort,
  onSpeed,
}: {
  model: UiControl
  effort?: UiControl
  effortValue: CodexEffort
  speed: AssistantSpeed
  onModel: (value: string) => void
  onEffort: (value: string) => void
  onSpeed: (value: string) => void
}) {
  const [open, setOpen] = useState(false)
  const [section, setSection] = useState<'model' | 'effort' | 'speed'>('effort')
  const button = useRef<HTMLButtonElement>(null)
  const panel = useRef<HTMLDivElement>(null)
  useProviderPopover(open, setOpen, button, panel)
  const currentModel = model.options.find((option) => option.value === model.value)
  const speedName = SPEED_OPTIONS.find((option) => option.value === speed)?.name ?? speed
  const effortOptions = effort?.options.filter((option) => isCodexEffort(option.value)) ?? []
  const currentEffort = effortOptions.find((option) => option.value === effortValue)
    ?? CODEX_EFFORT_OPTIONS.find((option) => option.value === effortValue)
  const compactModel = (currentModel?.name ?? model.value).replace(/^GPT-/i, '').replaceAll('-', ' ')
  const chooseModel = (value: string) => { onModel(value); setOpen(false) }
  const chooseEffort = (value: string) => { onEffort(value); setOpen(false) }
  const chooseSpeed = (value: string) => { onSpeed(value); setOpen(false) }
  return (
    <>
      <button ref={button} className="provider-summary-btn codex-summary" data-open={open} onClick={() => { setSection('effort'); setOpen((state) => !state) }} title="Codex model, effort, and speed" aria-haspopup="menu" aria-expanded={open}>
        <Icon name="Zap" size={13} />
        <span>{compactModel}</span>
        <b>{currentEffort?.name ?? effortValue}</b>
        <Icon name="ChevronDown" size={12} />
      </button>
      {open && createPortal(
        <div ref={panel} className="provider-pop codex-minimal-pop" role="menu" aria-label="Codex controls" style={{ position: 'fixed', ...popoverPosition(button.current) }}>
          <div className="provider-section-tabs" role="tablist">
            {([
              ['model', 'Model'],
              ['effort', 'Effort'],
              ['speed', 'Speed'],
            ] as const).map(([id, label]) => (
              <button key={id} role="tab" aria-selected={section === id} data-active={section === id} onClick={() => setSection(id)}>
                {label}
              </button>
            ))}
          </div>
          <div className="provider-choice-list" role="menu" aria-label={`Codex ${section}`}>
            {section === 'model' && model.options.map((option) => (
              <button key={option.value} className="provider-choice-row" role="menuitemradio" aria-checked={option.value === model.value} onClick={() => chooseModel(option.value)}>
                <span>{option.name}</span><Icon name="Check" size={14} />
              </button>
            ))}
            {section === 'effort' && effort && effortOptions.length > 0 && effortOptions.map((option) => (
              <button key={option.value} className="provider-choice-row" role="menuitemradio" aria-checked={option.value === effortValue} onClick={() => chooseEffort(option.value)}>
                <span>{option.name}</span><Icon name="Check" size={14} />
              </button>
            ))}
            {section === 'effort' && (!effort || !effortOptions.length) && <span className="provider-empty">Default</span>}
            {section === 'speed' && SPEED_OPTIONS.map((option) => (
              <button key={option.value} className="provider-choice-row" role="menuitemradio" aria-checked={option.value === speed} onClick={() => chooseSpeed(option.value)}>
                <span>{option.name}</span><Icon name="Check" size={14} />
              </button>
            ))}
          </div>
        </div>,
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
const TurnRow = memo(function TurnRow({ t, i, agentName, showCaret, liveThinkStart }: {
  t: Turn; i: number; agentName: string; showCaret: boolean; liveThinkStart?: number
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
        <div data-turn={i} className={`assistant-tool tool-${t.status}`}>
          {head}
        </div>
      )
    }
    // a tool call carrying artifacts becomes a disclosure card: the one-line
    // row is the collapsed state; failures auto-expand (VS Code's ergonomic)
    return (
      <details data-turn={i} className={`assistant-tool tool-${t.status} tool-artifacts`} open={t.status === 'failed'}>
        <summary>{head}</summary>
        <div className="tool-artifact-body">
          {arts.map((a, ai) =>
            a.type === 'diff' && a.path ? (
              <FileDiffDisclosure key={ai} path={a.path} oldText={a.oldText ?? ''} newText={a.newText ?? ''} open={arts.length === 1} />
            ) : a.type === 'terminal' && a.terminalId ? (
              <button
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
      <details data-turn={i} key={live ? 'think-live' : 'think-done'} className="assistant-thought" {...(live ? { open: true } : {})}>
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
  return (
    <div data-turn={i} className={`assistant-turn turn-${t.kind}`}>
      <span className="turn-tag">
        {t.kind === 'user' ? 'You' : agentName}
        {t.at != null && <span className="turn-time">{clockTime(new Date(t.at).toISOString())}</span>}
      </span>
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
        {plan.map((e, i) => (
          <div key={i} className={`plan-entry plan-${e.status}`}>
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

function PermissionCard({
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
        <button className="btn btn-primary btn-sm" onClick={onAllow}>Allow once</button>
        {!perm.sensitive && (
          <button className="btn btn-sm" onClick={onAlways} title="Saves a rule for this workspace — future matching asks are answered automatically. Manage rules in Settings → Guardrails.">
            Always allow {alwaysPattern}
          </button>
        )}
        <button className="btn btn-ghost btn-sm" onClick={onDeny} title="Also stops this agent's other pending asks">
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

// memo'd: every thread's card stays mounted side by side, and SessionCards
// re-renders often — a card whose threadId hasn't changed must not re-render
// (its own runtime subscription below wakes it when ITS content changes)
export const Assistant = memo(function Assistant({ threadId }: { threadId: string }) {
  const autonomy = useKaisola((s) => s.autonomy)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const projectId = useKaisola((s) => s.activeProjectId)
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
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const terminalMeta = useKaisola((s) => s.terminalMeta)
  const setDockView = useKaisola((s) => s.setDockView)

  const [presets, setPresets] = useState<AcpPreset[]>([])
  const [agents, setAgents] = useState<AcpAgent[]>([])
  const [statusReadyKey, setStatusReadyKey] = useState('')
  const autoConnectAttemptRef = useRef<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [authUrl, setAuthUrl] = useState<string | null>(null)
  // an OS file drag hovering the chat — the drop lands as attachment chips
  const [fileDropHover, setFileDropHover] = useState(false)
  const scrollRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const [queueOpen, setQueueOpen] = useState(false)
  const queueButton = useRef<HTMLButtonElement>(null)
  const queuePanel = useRef<HTMLDivElement>(null)
  useProviderPopover(queueOpen, setQueueOpen, queueButton, queuePanel)
  // grow the composer to fit what's typed (capped); reset to one line when empty
  const autoGrow = (el: HTMLTextAreaElement) => { el.style.height = 'auto'; el.style.height = `${Math.min(el.scrollHeight, 160)}px` }

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
  const draft = useKaisola((s) => s.assistantDrafts[active.id] ?? EMPTY_DRAFT)
  const queuedPrompts = useKaisola((s) => s.assistantPromptQueues[active.id] ?? EMPTY_QUEUE)
  const setAssistantDraft = useKaisola((s) => s.setAssistantDraft)
  const clearAssistantDraft = useKaisola((s) => s.clearAssistantDraft)
  const enqueueAssistantPrompt = useKaisola((s) => s.enqueueAssistantPrompt)
  const takeAssistantPromptQueue = useKaisola((s) => s.takeAssistantPromptQueue)
  const removeQueuedAssistantPrompt = useKaisola((s) => s.removeQueuedAssistantPrompt)
  const agentKey = active.agentKey
  // Provider sessions are per assistant thread, not merely per provider. Two
  // Codex cards in one project therefore retain independent contexts and
  // resume ids when hidden adapters park to disk.
  const connectionKey = `${agentKey}::${active.id}`
  const busy = active.busy
  const input = draft.text
  const attachments = draft.attachments
  const mentions = draft.mentions
  const speed = draft.speed
  useEffect(() => { if (inputRef.current && !input) inputRef.current.style.height = '' }, [input])
  useEffect(() => { if (!queuedPrompts.length) setQueueOpen(false) }, [queuedPrompts.length])
  const permsForAgent = pendingPermissions.filter((p) => p.key === connectionKey)
  const arun: Runtime = liveRuntime ?? { turns: [], first: true }
  const [archivedPage, setArchivedPage] = useState<Turn[]>([])
  const [archiveBefore, setArchiveBefore] = useState<number | undefined>()
  const [archiveTotal, setArchiveTotal] = useState<number | undefined>()
  const [archiveHasMore, setArchiveHasMore] = useState(false)
  const [archiveLoading, setArchiveLoading] = useState(false)
  const [archiveGap, setArchiveGap] = useState(false)
  const archiveRequestRef = useRef(0)
  const archiveRetryAttemptRef = useRef('')
  const archiveScope = useMemo(() => ({
    projectId,
    threadId: active.id,
    ...(arun.archiveEpoch ? { epoch: arun.archiveEpoch } : {}),
  }), [active.id, arun.archiveEpoch, projectId])
  const archiveScopeKey = `${archiveScope.projectId}\u0000${archiveScope.threadId}\u0000${archiveScope.epoch ?? '0'}`
  // Main owns the authoritative end. Probe metadata without hydrating turns;
  // a recovered post-crash tail therefore becomes discoverable immediately.
  useEffect(() => {
    const request = ++archiveRequestRef.current
    setArchivedPage([])
    setArchiveBefore(undefined)
    setArchiveTotal(undefined)
    setArchiveHasMore(false)
    setArchiveLoading(false)
    setArchiveGap(false)
    if (!bridge.assistantArchive) return
    void bridge.assistantArchive.info(archiveScope).then((result) => {
      if (archiveRequestRef.current !== request || !result.ok) return
      setArchiveTotal(result.total)
      setArchiveHasMore(result.total > 0)
    }).catch(() => {})
  }, [archiveScopeKey, arun.archivedTurns])
  // A quit or disk error retains the unacknowledged prefix and its idempotency
  // token. Retry once this owning card is mounted again.
  useEffect(() => {
    if (!arun.archiveBatch || arun.archivePending) return
    const attempt = `${archiveScopeKey}\u0000${arun.archiveBatch.id}`
    if (archiveRetryAttemptRef.current === attempt) return
    archiveRetryAttemptRef.current = attempt
    updateAssistantRuntime(active.id, (runtime) => runtime, projectId)
  }, [active.id, archiveScopeKey, arun.archiveBatch?.id, arun.archivePending, projectId, updateAssistantRuntime])
  const archivedCount = archiveTotal ?? arun.archivedTurns ?? 0
  const canLoadArchive = archiveBefore === undefined ? archivedCount > 0 : archiveHasMore
  const loadOlderTurns = async (fromLatest = false) => {
    if (archiveLoading || !bridge.assistantArchive) return
    const request = archiveRequestRef.current
    const cursor = fromLatest ? undefined : archiveBefore
    setArchiveLoading(true)
    try {
      // `undefined` deliberately lets main choose its reconciled end; never
      // seed first paging from a possibly stale renderer count.
      const result = await bridge.assistantArchive.page(archiveScope, cursor, 60)
      if (archiveRequestRef.current !== request || !result.ok) return
      const turns = result.turns.map(archivedTurn).filter((turn): turn is Turn => !!turn)
      const replace = fromLatest || archiveBefore === undefined
      const bounded = boundArchivedView(replace ? turns : [...turns, ...archivedPage])
      setArchivedPage(bounded.turns)
      setArchiveGap(bounded.truncated)
      setArchiveBefore(result.before ?? Math.max(0, (cursor ?? result.total ?? archivedCount) - turns.length))
      setArchiveTotal(result.total ?? archivedCount)
      setArchiveHasMore(!!result.hasMore)
    } catch {
      // The live window stays intact; archive IPC failures are retryable and
      // never justify dropping conversation state.
    } finally {
      if (archiveRequestRef.current === request) setArchiveLoading(false)
    }
  }
  const agentPreset = presets.find((p) => p.id === agentKey)
  const agentName = agentPreset?.name ?? agentKey
  const aState = agents.find((a) => a.key === connectionKey)
  const connected = !!aState?.connected
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
  const providerClaudeEfforts = providerEffortControl?.options.map((option) => option.value).filter(isClaudeEffort) ?? []
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
  }, [active.claudeEffort, active.id, claudeAgent, claudeEffort, providerEffortControl, setThreadClaudeEffort])
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
  }, [active.codexEffort, active.id, codexAgent, codexEffort, providerEffortControl, setThreadCodexEffort])
  const activityTools = arun.turns.filter((t) => t.kind === 'tool').slice(-8)
  const activeTools = activityTools.filter((t) => !doneStatuses.has((t.status || '').toLowerCase()))
  const latestActivity = activeTools[activeTools.length - 1]
  const latestActivityKind = latestActivity ? activityKind(latestActivity.text) : null
  const subagentCount = activeTools.filter((call) => activityKind(call.text).label === 'Subagent').length
  const liveAgentTerminals = agentTerminals
    .filter((t) => t.agentKey === connectionKey || t.agentKey === agentKey || (!t.agentKey && t.agentName === agentName))
    .filter((t) => terminalMeta[t.terminalId]?.running)
    .slice(-3)
    .reverse()
  const showLiveActivity = busy || activeTools.length > 0 || liveAgentTerminals.length > 0

  const updateRuntime = (id: string, fn: (r: Runtime) => Runtime) =>
    updateAssistantRuntime(id, fn, projectId)
  const owningSlice = () => {
    const state = useKaisola.getState()
    return state.activeProjectId === projectId ? state : state.projectSlices[projectId]
  }
  const openTerminalPreset = (preset: AcpPreset) => {
    if (!preset.terminalCommand) return
    requestTerminal(preset.terminalCommand, {
      cwd: workspacePath ?? undefined,
      name: preset.name,
      singletonKey: `agent:${preset.id}`,
      restart: true,
    })
    setNotice(`${preset.name} opened as a terminal session.`)
  }

  const refresh = () => bridge.acp.status([connectionKey]).then((s) => setAgents(s.agents))
  useEffect(() => {
    let live = true
    void Promise.allSettled([bridge.acp.status([connectionKey]), bridge.acp.presets()]).then(([statusResult, presetResult]) => {
      if (!live) return
      if (statusResult.status === 'fulfilled') setAgents(statusResult.value.agents)
      if (presetResult.status === 'fulfilled') setPresets(presetResult.value)
      // Autoconnect must not race status: an idle connection may already be
      // alive in main after a renderer remount/window swap.
      setStatusReadyKey(connectionKey)
    })
    return () => { live = false }
  }, [connectionKey])
  const keepAgentHot = busy || permsForAgent.length > 0
  useEffect(() => {
    // A visible but idle transcript does not need a live Node/CLI adapter. The
    // resumable provider session is the durable state, so main parks it after
    // a short grace and reconnects on the next send. Active turns and approval
    // prompts always hold the lease and therefore cannot be parked.
    void bridge.acp.lease(connectionKey, threadId, keepAgentHot, 90_000, projectId)
    return () => {
      void bridge.acp.lease(connectionKey, threadId, false, 90_000, projectId)
    }
  }, [connectionKey, keepAgentHot, projectId, threadId])
  useEffect(() => { const off = bridge.acp.onControls(() => refresh()); return off }, [connectionKey])
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
  }, [connectionKey])
  // ── turn timeline (Codex-style): one tick per prompt, hover = card, click = jump ──
  const prompts = useMemo(
    () => arun.turns.map((t, i) => ({ turn: t, idx: i })).filter((x) => x.turn.kind === 'user'),
    [arun.turns],
  )
  const [railHover, setRailHover] = useState<{ n: number; y: number } | null>(null)
  const [activePrompt, setActivePrompt] = useState(0)
  const jumpToTurn = (idx: number) => {
    scrollRef.current
      ?.querySelector(`[data-turn="${idx}"]`)
      ?.scrollIntoView({ block: 'start', behavior: 'smooth' })
  }
  /** The reply that followed a prompt — the hover card's preview. */
  const replyPreview = (promptIdx: number): { text: string; tools: number } => {
    let tools = 0
    for (let i = promptIdx + 1; i < arun.turns.length; i++) {
      const t = arun.turns[i]
      if (t.kind === 'user') break
      if (t.kind === 'tool') tools++
      if (t.kind === 'assistant' && t.text) return { text: t.text.slice(0, 180), tools }
    }
    return { text: '', tools }
  }

  // stick to the bottom only if the user is already near it — don't yank them
  // down while they're scrolling up to read.
  const stickRef = useRef(true)
  const onStreamScroll = () => {
    const el = scrollRef.current
    if (el) {
      stickRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 90
      // which prompt is above the fold — the rail's darkened tick
      let active = 0
      prompts.forEach((p, n) => {
        const node = el.querySelector(`[data-turn="${p.idx}"]`) as HTMLElement | null
        if (node && node.offsetTop <= el.scrollTop + 60) active = n
      })
      setActivePrompt(active)
    }
  }
  useEffect(() => {
    if (stickRef.current) scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight })
  }, [arun, threadId])
  useEffect(() => { stickRef.current = true }, [threadId])
  // clear the auth prompt once we're connected
  useEffect(() => { if (connected) { setNotice(null); setAuthUrl(null) } }, [connected])
  // live tick so the "thinking…" timer updates while a response streams
  const [, setTick] = useState(0)
  useEffect(() => {
    if (!busy) return
    const iv = setInterval(() => setTick((n) => n + 1), 500)
    return () => clearInterval(iv)
  }, [busy])

  const pickWorkspace = async (): Promise<string | null> => {
    const r = await bridge.pickFolder()
    if (r.ok && r.path) { setWorkspace(r.path); return r.path }
    if (r.message) setNotice(r.message)
    return null
  }
  const connect = async (key: string, opts: { claudeEffort?: ClaudeEffort; forceReconnect?: boolean } = {}): Promise<boolean> => {
    setNotice(null)
    const preset = presets.find((p) => p.id === key)
    if (preset?.terminalOnly) {
      openTerminalPreset(preset)
      return false
    }
    // the agent MUST work inside a real folder you choose — never Kaisola's own dir
    let cwd = workspacePath
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
        : { presetId: key, clientKey: `${key}::${active.id}`, autonomy, cwd, resumeSessionId, claudeEffort: effort, forceReconnect: opts.forceReconnect },
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
          const applied = await bridge.acp.setConfigOption(`${key}::${active.id}`, effortControl.id, active.codexEffort)
          if (!applied.ok) setNotice(applied.message ?? 'Codex effort could not be restored.')
        }
      }
      if (res.resumed) setNotice('Resumed the previous session.')
    }
    else setNotice(res.message ?? 'Could not connect.')
    return res.ok
  }
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
    return agentReady || connect(agentKey)
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
  // A fresh thread just TRIES to connect: the CLIs cache their logins on disk
  // (claude/codex), so most threads should come up Connected without anyone
  // touching "Sign in" — clicking it used to be the only visible path, and for
  // Claude that path is a `claude /login` terminal, which read as broken when
  // the user was already signed in. Never auto-runs when no workspace is set
  // (connect() would pop the folder picker); failures land in the notice line
  // and the explicit Sign in button remains.
  useEffect(() => {
    if (statusReadyKey !== connectionKey || connected || busy || !workspacePath) return
    const preset = presets.find((p) => p.id === agentKey)
    const custom = useKaisola.getState().customAgents.find((a) => a.id === agentKey && a.kind === 'acp')
    if ((!preset || preset.terminalOnly) && !custom) return
    const attempt = `${threadId}|${agentKey}|${workspacePath}`
    if (autoConnectAttemptRef.current === attempt) return
    autoConnectAttemptRef.current = attempt
    void connect(agentKey)
  }, [agentKey, connected, busy, connectionKey, presets, statusReadyKey, threadId, workspacePath])
  const onControlChange = async (c: UiControl, value: string) => {
    if (!(await ensureAgentConnected())) return
    const result = c.kind === 'mode'
      ? await bridge.acp.setMode(connectionKey, value)
      : c.kind === 'model'
        ? await bridge.acp.setModel(connectionKey, value)
        : await bridge.acp.setConfigOption(connectionKey, c.id, value)
    if (!result.ok) setNotice(result.message ?? `${c.name} could not be changed.`)
    else setNotice(null)
    refresh()
  }
  const applySpeed = async (nextSpeed: AssistantSpeed): Promise<boolean> => {
    if (!speedControl) return false
    const value = speedOptionValue(speedControl, nextSpeed)
    if (!value) return false
    if (value === speedControl.value) return true
    const res = await bridge.acp.setConfigOption(connectionKey, speedControl.id, value)
    if (!res.ok && res.message) setNotice(res.message)
    refresh()
    return res.ok
  }
  const setSpeed = (value: string) => {
    if (!isAssistantSpeed(value)) return
    setAssistantDraft(active.id, { speed: value }, projectId)
    void applySpeed(value)
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
      const res = await bridge.acp.setConfigOption(connectionKey, providerEffortControl.id, value)
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
    const res = await bridge.acp.setConfigOption(connectionKey, providerEffortControl.id, value)
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
        if (Array.isArray(entries)) updateRuntime(threadId, (r) => ({ ...r, plan: entries.slice(0, 100).map((entry) => ({ ...entry, content: String(entry.content ?? '').slice(0, 4000) })) }))
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
  const queuePausedRef = useRef(false)
  const queuePrompt = (prompt: AssistantDraft) => {
    if (!prompt.text.trim()) return
    // A fresh user enqueue is an explicit resume after Stop/a delivery error.
    queuePausedRef.current = false
    enqueueAssistantPrompt(active.id, prompt, undefined, projectId)
    clearAssistantDraft(active.id, { keepSpeed: true }, projectId)
    resetComposerHeight()
    useKaisola.getState().pushToast('info', `Queued prompt for ${agentName}`)
  }
  const send = async () => {
    const prompt = currentPrompt()
    if (!prompt.text) return
    if (busy) { queuePrompt(prompt); return }
    queuePausedRef.current = false
    void sendText(prompt, { clearDraft: true, restoreOnFailure: true })
  }
  /** The composer's send, callable with explicit text (the ⌘L bar uses it). */
  const sendText = async (
    promptOrText: string | AssistantDraft,
    opts: { clearDraft?: boolean; restoreOnFailure?: boolean } = {},
  ): Promise<boolean> => {
    const rawPrompt: AssistantDraft =
      typeof promptOrText === 'string'
        ? { ...EMPTY_DRAFT, text: promptOrText.trim(), speed }
        : { ...promptOrText, text: promptOrText.text.trim(), speed: promptOrText.speed ?? speed }
    const wasTrimmed = rawPrompt.text.length > ASSISTANT_DRAFT_TEXT_LIMIT
    const prompt: AssistantDraft = { ...rawPrompt, text: rawPrompt.text.slice(0, ASSISTANT_DRAFT_TEXT_LIMIT) }
    if (!prompt.text) return false
    if (owningSlice()?.assistantThreads.find((t) => t.id === active.id)?.busy) return false
    if (!(await ensureAgentConnected())) return false
    if (wasTrimmed) setNotice(`Message limited to ${ASSISTANT_DRAFT_TEXT_LIMIT.toLocaleString()} characters to keep the IDE responsive. Attach long material as a file to preserve it in full.`)
    const threadId = active.id
    if (owningSlice()?.assistantThreads.find((t) => t.id === threadId)?.busy) return false
    const first = (owningSlice()?.assistantRuntimes[threadId] ?? arun).first
    const files = prompt.attachments
    const mns = prompt.mentions
    const refLine = [...mns.map((m) => `@${m.label}`), ...files.map((f) => `📎 ${f.split('/').pop() ?? ''}`)].join('  ·  ')
    const shownText = refLine ? `${prompt.text}\n\n${refLine}` : prompt.text
    autoNameThread(threadId, prompt.text, projectId) // first message → the session's topic title
    const userTurn: Turn = { kind: 'user', text: shownText, at: Date.now() }
    updateRuntime(threadId, (r) => ({ ...r, turns: [...r.turns, userTurn], first: false }))
    setThreadBusy(threadId, true, projectId)
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
          turns: r.turns.map((x) => (x.kind === 'user' && x.at === turnAt ? { ...x, checkpointId: ckpt.id } : x)),
        }))
      })
    }
    if (opts.clearDraft) {
      clearAssistantDraft(threadId, { keepSpeed: true }, projectId)
      resetComposerHeight()
    }
    const mentionPrefix = mns.length ? `Referenced from the research project (use if relevant):\n${mns.map((m) => `- ${m.text}`).join('\n')}\n\n` : ''
    const filePrefix = files.length ? `Attached files (read them if relevant):\n${files.join('\n')}\n\n` : ''
    const nativeSpeedApplied = await applySpeed(prompt.speed)
    const payload = `${speedGuidance(prompt.speed, nativeSpeedApplied)}${first ? `${buildContext()}\n\n` : ''}${mentionPrefix}${filePrefix}${prompt.text}`
    // image attachments ALSO ride as real ACP image blocks (pixels, not a
    // path) for agents that take them; the path stays in filePrefix above as
    // the text-only fallback. Unreadable/oversized images just stay paths.
    const images = (
      await Promise.all(
        files
          .filter((f) => /\.(png|jpe?g|gif|webp)$/i.test(f))
          .map(async (f) => {
            const r = await bridge.fs.readImage(f)
            return r.ok && r.data && r.mimeType ? { mimeType: r.mimeType, data: r.data } : null
          }),
      )
    ).filter((i): i is { mimeType: string; data: string } => i !== null)
    const stream = makeOnUpdate(threadId)
    let res: { ok: boolean; stopReason?: string; message?: string }
    try {
      res = await bridge.acp.prompt(connectionKey, payload, stream.onUpdate, images.length ? images : undefined, projectId)
    } catch (err) {
      res = { ok: false, message: String((err as Error)?.message ?? err) }
    }
    stream.flush() // drain any buffered tail before settling the turn
    updateRuntime(threadId, (r) => {
      let turns = r.turns
      if (r.thinkStart != null) {
        const ms = Date.now() - r.thinkStart
        turns = [...turns]
        for (let i = turns.length - 1; i >= 0; i--) {
          if (turns[i].kind === 'thought') { turns[i] = { ...turns[i], thinkMs: turns[i].thinkMs ?? ms }; break }
        }
      }
      return { ...r, thinkStart: undefined, turns }
    })
    setThreadBusy(threadId, false, projectId)
    // Working dots pulse; a finished unseen turn becomes a still dot until the
    // owning tab/card is actually viewed and focused.
    {
      const state = useKaisola.getState()
      const owner = owningSlice()
      const seen = state.activeProjectId === projectId && !!owner?.dockOpen && !!owner?.dockViews.includes(threadId) && !document.hidden && document.hasFocus()
      if (!seen) state.markNeedsYou(threadId, projectId)
      if (state.activeProjectId !== projectId) state.setProjectActivity(projectId, res.ok ? 'completed' : 'failed')
    }
    if (!res.ok) {
      // the prompt was rejected — roll back the optimistic user turn so the
      // transcript doesn't strand an undelivered message. ONLY when nothing
      // streamed after it (the mid-turn / not-connected rejections reply nothing):
      // if the agent crashed mid-reply, keep the [user, partial-reply] pair coherent.
      updateRuntime(threadId, (r) =>
        r.turns[r.turns.length - 1] === userTurn ? { ...r, turns: r.turns.slice(0, -1), first } : r,
      )
      if (res.message) { setNotice(res.message); refresh() }
      if (opts.restoreOnFailure) {
        const cur = owningSlice()?.assistantDrafts[threadId] ?? EMPTY_DRAFT
        if (!cur.text && cur.attachments.length === 0 && cur.mentions.length === 0) setAssistantDraft(threadId, prompt, projectId)
      }
      return false
    }
    return true
  }
  // Queue pause semantics: reconnecting, a new enqueue, or a manual send
  // resumes; Stop pauses so cancelling never auto-fires the next instruction.
  useEffect(() => { if (connected) queuePausedRef.current = false }, [connected])
  const drainQueuedPrompts = async () => {
    if (!connected || queuePausedRef.current || drainingQueueRef.current) return
    drainingQueueRef.current = true
    try {
      // Keep ownership in one async loop. A ref alone cannot wake React after
      // finally; the old one-shot effect therefore stranded item 2 forever.
      while (!queuePausedRef.current) {
        const owner = owningSlice()
        const thread = owner?.assistantThreads.find((candidate) => candidate.id === active.id)
        const waiting = owner?.assistantPromptQueues[active.id] ?? EMPTY_QUEUE
        if (!thread || thread.busy || waiting.length === 0) return
        const batch = takeAssistantPromptQueue(active.id, projectId)
        if (!batch.length) return
        const combined = mergeQueuedPrompts(batch)
        const sent = await sendText(combined)
        if (!sent) {
          // Pause BEFORE restoring so the queue-length render cannot race an
          // immediate retry. A new user enqueue or reconnect resumes it.
          queuePausedRef.current = true
          enqueueAssistantPrompt(active.id, combined, { front: true }, projectId)
          useKaisola.getState().pushToast('warn', `${agentName} queue paused — send or queue a prompt to resume`)
          return
        }
        // Anything typed while that combined prompt ran is now waiting in the
        // store and is picked up by this same loop without needing a re-render.
      }
    } finally {
      drainingQueueRef.current = false
    }
  }
  useEffect(() => {
    if (!connected || busy || queuePausedRef.current || drainingQueueRef.current || queuedPrompts.length === 0) return
    void drainQueuedPrompts()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [connected, busy, queuedPrompts.length, active.id])
  // the ⌘L bar hands prompts to threads through the store — deliver ours once
  const omniPrompt = useKaisola((s) => s.omniPrompt)
  const omniSeqRef = useRef(0)
  useEffect(() => {
    if (!omniPrompt || omniPrompt.threadId !== threadId || omniPrompt.seq === omniSeqRef.current) return
    omniSeqRef.current = omniPrompt.seq
    useKaisola.getState().clearOmniPrompt()
    const text = omniPrompt.text
    if (busy) {
      queuePausedRef.current = false
      enqueueAssistantPrompt(active.id, { ...EMPTY_DRAFT, text: text.trim(), speed }, undefined, projectId)
      useKaisola.getState().pushToast('info', `Queued prompt for ${agentName}`)
      return
    }
    void sendText(text).then((sent) => {
      // never swallow a ⌘L prompt: a race-y busy flip QUEUES it (review
      // finding #4 — it used to be dropped with a misleading toast)
      if (!sent) {
        queuePausedRef.current = false
        enqueueAssistantPrompt(active.id, { ...EMPTY_DRAFT, text: text.trim(), speed }, undefined, projectId)
        useKaisola.getState().pushToast('info', `Queued prompt for ${agentName}`)
      }
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [omniPrompt, threadId])
  const cancelActive = () => {
    // Stop means STOP: pause the queue too, or flipping busy would auto-fire
    // the next queued prompt the instant the user aborts (review finding #2)
    if (queuedPrompts.length > 0) {
      queuePausedRef.current = true
      useKaisola.getState().pushToast('info', 'Queue paused — send or queue a prompt to resume')
    }
    bridge.acp.cancel(connectionKey)
    setThreadBusy(active.id, false, projectId)
    updateRuntime(active.id, (r) => ({ ...r, thinkStart: undefined }))
  }
  const attach = async () => {
    const r = await bridge.pickFiles()
    if (r.ok && r.paths) setAssistantDraft(active.id, { attachments: [...new Set([...attachments, ...r.paths])] }, projectId)
  }
  // the foot's agent picker re-points the active thread to a different agent
  const setThreadAgent = (key: string) => {
    const preset = presets.find((p) => p.id === key)
    if (preset?.terminalOnly) { openTerminalPreset(preset); return }
    setStoreThreadAgent(active.id, key); resetAssistantRuntime(active.id, projectId); refresh()
  }

  return (
    <div
      className="assistant"
      data-thread-id={active.id}
      data-rail={prompts.length > 1 || undefined}
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
        const paths = files.map((f) => bridge.pathForFile?.(f)).filter(Boolean) as string[]
        if (!paths.length) return
        setAssistantDraft(active.id, { attachments: [...new Set([...attachments, ...paths])] }, projectId)
        inputRef.current?.focus()
      }}
    >
      {/* the prompt timeline — every turn you instigated, one tick each */}
      {prompts.length > 1 && (
        <div className="turn-rail" onMouseLeave={() => setRailHover(null)}>
          {prompts.slice(-24).map((p, n) => (
            <button
              key={p.idx}
              className="turn-tick"
              data-active={Math.max(0, prompts.length - 24) + n === activePrompt}
              onMouseEnter={(e) => setRailHover({ n, y: (e.currentTarget as HTMLElement).offsetTop })}
              onClick={() => jumpToTurn(p.idx)}
              aria-label={p.turn.text.slice(0, 60)}
            />
          ))}
          {railHover && (() => {
            const p = prompts.slice(-24)[railHover.n]
            if (!p) return null
            const reply = replyPreview(p.idx)
            return (
              <div className="turn-pop" style={{ top: Math.max(0, railHover.y - 12) }}>
                <div className="turn-pop-title">{p.turn.text}</div>
                {reply.text && <div className="turn-pop-preview">{reply.text}</div>}
                <div className="turn-pop-meta">
                  {reply.tools > 0 && <span>{reply.tools} tool call{reply.tools === 1 ? '' : 's'}</span>}
                  {p.turn.at != null && <span>{clockTime(new Date(p.turn.at).toISOString())}</span>}
                </div>
                {p.turn.checkpointId && (
                  <button
                    className="turn-pop-restore"
                    onClick={() => {
                      const st = useKaisola.getState()
                      void st.restoreRepoCheckpoint(p.turn.checkpointId!).then(() => {
                        st.pushToast('success', 'Files restored to before this prompt. The agent doesn’t know — mention it in your next message.')
                      })
                      setRailHover(null)
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
      <div className="assistant-stream" ref={scrollRef} onScroll={onStreamScroll}>
        {notice && (
          <div className="assistant-nokey">
            <Icon name={authUrl ? 'KeyRound' : 'Info'} size={15} />
            <div className="grow">{notice}</div>
            {authUrl ? (
              <button className="btn btn-primary btn-sm" onClick={() => { bridge.openExternal(authUrl); }}>
                <Icon name="ExternalLink" size={13} /> Authorize
              </button>
            ) : (
              <button className="btn btn-ghost btn-sm" onClick={() => openSettings(true)}><Icon name="Settings" size={13} /> Settings</button>
            )}
            <button className="btn-icon btn-sm" onClick={() => { setNotice(null); setAuthUrl(null) }}><Icon name="X" size={13} /></button>
          </div>
        )}
        {showLiveActivity && (
          <div className="agent-livebar" aria-live="polite">
            <span className="agent-live-dot" aria-hidden />
            <Icon name={latestActivityKind?.icon ?? 'Sparkles'} size={12} />
            <span className="grow truncate">
              {latestActivity?.text || (liveAgentTerminals.length ? 'Running a terminal task' : `${agentName} is working`)}
            </span>
            {subagentCount > 0 && <span className="agent-live-pill"><Icon name="Bot" size={10} /> {subagentCount}</span>}
            {liveAgentTerminals.map((term) => (
              <button key={term.terminalId} className="agent-live-pill" onClick={() => setDockView(term.terminalId)} title={term.command || term.label || 'Open terminal'}>
                <Icon name="TerminalSquare" size={10} /> {term.label || 'Terminal'}
              </button>
            ))}
          </div>
        )}
        {(arun.plan?.length ?? 0) > 0 && <PlanStrip plan={arun.plan!} />}
        {canLoadArchive && (
          <button
            className="assistant-load-history"
            disabled={archiveLoading}
            onClick={() => { void loadOlderTurns() }}
          >
            <Icon name="History" size={12} />
            {archiveLoading ? 'Loading history…' : `Load older history · ${Math.max(0, archivedCount - archivedPage.length)} on disk`}
          </button>
        )}
        {archivedPage.map((t, i) => (
          <TurnRow
            key={`archived-${t.at ?? 'turn'}-${i}`}
            t={t}
            i={i - archivedPage.length}
            agentName={agentName}
            showCaret={false}
          />
        ))}
        {archiveGap && (
          <button className="assistant-load-history" disabled={archiveLoading} onClick={() => { void loadOlderTurns(true) }}>
            <Icon name="RotateCcw" size={12} />
            Return to recent archived history
          </button>
        )}
        {arun.turns.map((t, i) => (
          <TurnRow
            key={i}
            t={t}
            i={i}
            agentName={agentName}
            showCaret={busy && i === arun.turns.length - 1}
            liveThinkStart={t.kind === 'thought' && t.thinkMs == null ? arun.thinkStart : undefined}
          />
        ))}
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

      <div className="composer">
        {attachments.length > 0 && (
          <div className="composer-attach">
            {attachments.map((f) => (
              <span key={f} className="attach-chip" title={f}>
                <Icon name="Paperclip" size={11} /> {f.split('/').pop()}
                <button onClick={() => setAssistantDraft(active.id, { attachments: attachments.filter((x) => x !== f) }, projectId)}><Icon name="X" size={10} /></button>
              </span>
            ))}
          </div>
        )}
        {mentions.length > 0 && (
          <div className="composer-attach">
            {mentions.map((mn) => (
              <span key={mn.id} className="attach-chip" title={mn.text}>
                <Icon name={mentionIcon(mn.kind)} size={11} /> {mn.label.length > 30 ? `${mn.label.slice(0, 30)}…` : mn.label}
                <button onClick={() => setAssistantDraft(active.id, { mentions: mentions.filter((x) => x.id !== mn.id) }, projectId)}><Icon name="X" size={10} /></button>
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
          <button className="composer-tool" onClick={attach} title="Attach files"><Icon name="Paperclip" size={14} /></button>
          {queuedPrompts.length > 0 && (
            <>
              <button
                ref={queueButton}
                className="composer-queue-capsule"
                data-open={queueOpen || undefined}
                onClick={() => setQueueOpen((value) => !value)}
                title={`${queuedPrompts.length} queued prompt${queuedPrompts.length === 1 ? '' : 's'}${queuedPrompts.length > 1 ? ' · sends together' : ''}`}
                aria-haspopup="dialog"
                aria-expanded={queueOpen}
              >
                <Icon name="ListChecks" size={12} />
                <span>{queuedPrompts.length} queued</span>
                <Icon name="ChevronUp" size={10} />
              </button>
              {queueOpen && createPortal(
                <div
                  ref={queuePanel}
                  className="provider-pop queue-pop"
                  role="dialog"
                  aria-label="Queued prompts"
                  style={{ position: 'fixed', ...popoverPosition(queueButton.current) }}
                >
                  <div className="provider-pop-head">
                    <strong>Queued prompts</strong>
                    <span className="grow" />
                    <span className="faint">{queuedPrompts.length > 1 ? 'Sends together' : 'Sends next'}</span>
                  </div>
                  <div className="queue-pop-list">
                    {queuedPrompts.map((q, index) => (
                      <div key={q.id} className="queue-pop-row">
                        <span className="queue-pop-index">{index + 1}</span>
                        <span className="queue-pop-text" title={q.text}>{q.text}</span>
                        {q.speed === 'fast' && <Icon name="Gauge" size={11} />}
                        <button onClick={() => removeQueuedAssistantPrompt(active.id, q.id)} title="Remove queued prompt" aria-label="Remove queued prompt">
                          <Icon name="X" size={11} />
                        </button>
                      </div>
                    ))}
                  </div>
                </div>,
                document.body,
              )}
            </>
          )}
          {composerControls.map((c) => (
            <Dropdown key={c.id} icon={CATEGORY_ICON[c.category]} value={c.value} options={c.options.map(({ value, name }) => ({ value, name }))} onSelect={(v) => onControlChange(c, v)} title={c.name} />
          ))}
          {!claudeAgent && !codexAgent && <Dropdown icon="Gauge" value={speed} options={SPEED_OPTIONS} onSelect={setSpeed} title="Response speed" />}
          <span className="grow" />
          {claudeAgent && providerModelControl && (
            <Dropdown icon="Sparkles" value={providerModelControl.value} options={providerModelControl.options.map(({ value, name }) => ({ value, name }))} onSelect={(value) => void onControlChange(providerModelControl, value)} title="Claude model" align="right" />
          )}
          {claudeAgent && <ClaudeEffortPicker value={claudeEffort} options={claudeEffortOptions} busy={busy} onSelect={(value) => void changeClaudeEffort(value)} />}
          {codexAgent && providerModelControl && (
            <CodexAdvancedPicker
              model={providerModelControl}
              effort={providerEffortControl}
              effortValue={codexEffort}
              speed={liveSpeed}
              onModel={(value) => void onControlChange(providerModelControl, value)}
              onEffort={(value) => void changeCodexEffort(value)}
              onSpeed={setSpeed}
            />
          )}
          {busy ? (
            <>
              {input.trim() && (
                <button className="composer-send composer-queue-send" onClick={send} title="Queue prompt  ⏎">
                  <Icon name="ListPlus" size={13} />
                </button>
              )}
              <button className="composer-send composer-stop" onClick={cancelActive} title="Stop output">
                <Icon name="Square" size={11} />
              </button>
            </>
          ) : (
            <button className="composer-send" onClick={send} disabled={!input.trim()} title="Send  ⏎">
              <Icon name="ArrowUp" size={14} />
            </button>
          )}
        </div>
      </div>

      {/* session identity — which agent, which folder, connection — sits quietly at the bottom */}
      <div className="assistant-foot">
        <Dropdown
          icon="Bot"
          value={agentKey}
          options={presets.filter((p) => !p.terminalOnly && !p.hidden).map((p) => ({ value: p.id, name: p.name }))}
          onSelect={setThreadAgent}
          title="Agent for this thread"
          align="left"
        />
        <button className="foot-ws drop-btn" onClick={pickWorkspace} title={workspacePath ?? 'Choose a workspace folder for the agent'}>
          <Icon name="Folder" size={12} className="drop-btn-icon" />
          <span className="drop-btn-label">{workspacePath ? workspacePath.split('/').filter(Boolean).pop() : 'Workspace'}</span>
        </button>
        <span className="grow" />
        <span className="foot-conn" data-on={connected}>
          <span className={`acp-dot ${connected ? 'on' : 'off'}`} />
          {connected ? (
            'Connected'
          ) : (() => { const p = presets.find((x) => x.id === agentKey); return p?.login || p?.deviceLogin })() ? (
            <button className="foot-link" onClick={signIn}>Offline · Sign in</button>
          ) : (
            'Offline'
          )}
        </span>
      </div>
    </div>
  )
})
