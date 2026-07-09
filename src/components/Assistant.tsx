import { memo, useEffect, useMemo, useRef, useState } from 'react'
import {
  useKaisola,
  type AssistantDraft,
  type AssistantMention,
  type AssistantRuntime,
  type PlanEntry,
  type ToolArtifact,
  type AssistantSpeed,
  type AssistantThread,
  type AssistantTurn,
  type QueuedAssistantPrompt,
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

const CATEGORY_ORDER: Record<string, number> = { mode: 0, model: 1, thought_level: 2 }
const CATEGORY_ICON: Record<string, string> = { mode: 'ShieldCheck', model: 'Box', thought_level: 'Brain' }
const mentionIcon = (kind: Mention['kind']): string =>
  kind === 'paper' ? 'FileText'
    : kind === 'claim' ? 'Network'
      : kind === 'hypothesis' ? 'Lightbulb'
        : kind === 'run' ? 'Terminal'
          : 'Image'
const doneStatuses = new Set(['completed', 'failed', 'cancelled', 'canceled'])
/** Streaming transcript flush cadence — ~12 renders/sec regardless of token rate. */
const STREAM_FLUSH_MS = 80
const EMPTY_DRAFT: AssistantDraft = { text: '', attachments: [], mentions: [], speed: 'balanced' }
const EMPTY_QUEUE: QueuedAssistantPrompt[] = []
const SPEED_OPTIONS = [
  { value: 'fast', name: 'Fast', description: 'Lower effort, quicker turns' },
  { value: 'balanced', name: 'Balanced', description: 'Default agent effort' },
  { value: 'deep', name: 'Deep', description: 'More checking before answering' },
]
const isAssistantSpeed = (v: string): v is AssistantSpeed => v === 'fast' || v === 'balanced' || v === 'deep'
const speedGuidance = (speed: AssistantSpeed, nativeApplied: boolean): string => {
  if (nativeApplied) return ''
  if (speed === 'fast') return 'Kaisola speed: Fast. Prioritize a quick, concise answer and avoid broad exploration unless it is necessary.\n\n'
  if (speed === 'deep') return 'Kaisola speed: Deep. Spend extra effort checking edge cases, tradeoffs, and likely failure modes before answering.\n\n'
  return ''
}
// one quiet auto-connect attempt per agent+workspace per app run — module
// scope so two side-by-side threads on the same agent can't race a double
// connect (the second would dispose the first's fresh session)
const acpAutoConnectTried = new Set<string>()
const statusTone = (status?: string): string => {
  const s = (status || 'pending').toLowerCase()
  return s === 'completed' ? 'completed' : s === 'failed' ? 'failed' : s === 'cancelled' || s === 'canceled' ? 'cancelled' : 'running'
}
const activityKind = (text: string): { label: string; icon: string } => {
  if (/sub[-\s]?agent|delegate|task/i.test(text)) return { label: 'Subagent', icon: 'Bot' }
  if (/terminal|shell|command|exec|\bnpm\b|\bpnpm\b|\byarn\b|\bpython\b|\bnode\b|\bgit\b|\becho\b/i.test(text)) return { label: 'Command', icon: 'TerminalSquare' }
  return { label: 'Tool', icon: 'Wrench' }
}
const shortPath = (path?: string): string => {
  if (!path) return ''
  const parts = path.split('/').filter(Boolean)
  return parts.length ? parts[parts.length - 1] : path
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

function nativeSpeedControl(controls: UiControl[]): UiControl | null {
  return controls.find((c) => {
    if (c.kind !== 'config' || c.options.length < 2) return false
    const haystack = `${c.id} ${c.name} ${c.category}`.toLowerCase()
    return /speed|effort|reasoning|thought|think/.test(haystack)
  }) ?? null
}

function speedOptionValue(c: UiControl, speed: AssistantSpeed): string | null {
  const want =
    speed === 'fast'
      ? /fast|quick|low|minimal|light|none|short/
      : speed === 'deep'
        ? /deep|high|max|extended|thorough/
        : /balanced|medium|auto|normal|standard|default/
  const hit = c.options.find((o) => want.test(`${o.value} ${o.name}`.toLowerCase()))
  if (hit) return hit.value
  if (speed === 'fast') return c.options[0]?.value ?? null
  if (speed === 'deep') return c.options[c.options.length - 1]?.value ?? null
  return c.options[Math.floor((c.options.length - 1) / 2)]?.value ?? null
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
  const project = useKaisola((s) => s.project)
  const stage = useKaisola((s) => s.stage)
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const setDockView = useKaisola((s) => s.setDockView)

  const [presets, setPresets] = useState<AcpPreset[]>([])
  const [agents, setAgents] = useState<AcpAgent[]>([])
  const [notice, setNotice] = useState<string | null>(null)
  const [authUrl, setAuthUrl] = useState<string | null>(null)
  // an OS file drag hovering the chat — the drop lands as attachment chips
  const [fileDropHover, setFileDropHover] = useState(false)
  // the active "@query" being typed (null = the mention typeahead is closed)
  const [mentionQuery, setMentionQuery] = useState<string | null>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
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
  const dequeueAssistantPrompt = useKaisola((s) => s.dequeueAssistantPrompt)
  const removeQueuedAssistantPrompt = useKaisola((s) => s.removeQueuedAssistantPrompt)
  const agentKey = active.agentKey
  const busy = active.busy
  const input = draft.text
  const attachments = draft.attachments
  const mentions = draft.mentions
  const speed = draft.speed
  useEffect(() => { if (inputRef.current && !input) inputRef.current.style.height = '' }, [input])
  const permsForAgent = pendingPermissions.filter((p) => p.key === agentKey)
  const arun: Runtime = liveRuntime ?? { turns: [], first: true }
  const agentPreset = presets.find((p) => p.id === agentKey)
  const agentName = agentPreset?.name ?? agentKey
  const aState = agents.find((a) => a.key === agentKey)
  const connected = !!aState?.connected
  const controls = controlList(aState?.controls ?? null)
  const speedControl = nativeSpeedControl(controls)
  const visibleControls = speedControl ? controls.filter((c) => c.id !== speedControl.id) : controls
  const codeAgent = /codex|claude/i.test(`${agentKey} ${agentName}`)
  const activityTools = arun.turns.filter((t) => t.kind === 'tool').slice(-8)
  const activeToolCount = activityTools.filter((t) => !doneStatuses.has((t.status || '').toLowerCase())).length
  const visibleToolCalls = activityTools.slice(-5).reverse()
  const liveAgentTerminals = agentTerminals
    .filter((t) => t.agentKey === agentKey || (!t.agentKey && t.agentName === agentName))
    .slice(-4)
    .reverse()
  const showAgentActivity = codeAgent || busy || activityTools.length > 0 || liveAgentTerminals.length > 0
  const activitySubhead = activeToolCount || liveAgentTerminals.length
    ? `${activeToolCount} active call${activeToolCount === 1 ? '' : 's'} · ${liveAgentTerminals.length} terminal task${liveAgentTerminals.length === 1 ? '' : 's'}`
    : 'No subagents or background tasks yet'

  const updateRuntime = (id: string, fn: (r: Runtime) => Runtime) =>
    updateAssistantRuntime(id, fn)
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

  // @-mention context: type @ then filter papers / claims / hypotheses to attach
  // their text to the next message (pure local — it only shapes the prompt).
  const mentionCandidates = useMemo<Mention[]>(() => {
    if (mentionQuery == null) return []
    const q = mentionQuery.toLowerCase()
    const papers = project.corpus
      .filter((s): s is Paper => s.kind === 'paper')
      .map((p) => ({ id: p.id, kind: 'paper' as const, label: p.title, text: `Paper “${p.title}”${p.abstract ? `: ${p.abstract.slice(0, 240)}` : ''}` }))
    const claims = project.claimGraph.nodes.map((n) => ({ id: n.id, kind: 'claim' as const, label: n.label, text: `Claim “${n.label}”${n.detail ? `: ${n.detail}` : ''}` }))
    const hyps = project.hypotheses.map((h) => ({ id: h.id, kind: 'hypothesis' as const, label: h.title, text: `Hypothesis “${h.title}”: ${h.claim}` }))
    const runs = project.runs.map((r) => ({ id: r.id, kind: 'run' as const, label: r.label, text: `Run “${r.label}” status=${r.status}${r.summary ? `: ${r.summary}` : ''}` }))
    const figures = project.figures.map((f) => ({ id: f.id, kind: 'figure' as const, label: f.title, text: `Figure “${f.title}”${f.caption ? `: ${f.caption}` : ''}` }))
    return [...papers, ...claims, ...hyps, ...runs, ...figures].filter((c) => !q || c.label.toLowerCase().includes(q)).slice(0, 8)
  }, [project, mentionQuery])

  const contextLedger = useMemo(() => {
    const rows = [
      { id: 'stage', icon: 'Map', label: `Stage: ${stageMeta(stage).label}`, detail: 'Automatic first-message context' },
      { id: 'autonomy', icon: 'ShieldCheck', label: `Autonomy: ${autonomy}`, detail: 'Controls what agents may do without approval' },
    ]
    if (project.name) rows.push({ id: 'project', icon: 'FolderOpen', label: project.name, detail: 'Project name' })
    if (project.question) rows.push({ id: 'question', icon: 'HelpCircle', label: project.question, detail: 'Research question' })
    if (project.campaign) rows.push({ id: 'campaign', icon: 'Target', label: project.campaign.title, detail: `${project.campaign.evaluator.metric} · ${project.campaign.status}` })
    if (project.corpus.length) rows.push({ id: 'corpus', icon: 'Library', label: `${project.corpus.length} corpus source${project.corpus.length === 1 ? '' : 's'}`, detail: 'First 12 titles included on a new thread' })
    for (const mention of mentions) rows.push({ id: `mention-${mention.id}`, icon: mentionIcon(mention.kind), label: mention.label, detail: `Pinned @${mention.kind}` })
    for (const file of attachments) rows.push({ id: `file-${file}`, icon: 'Paperclip', label: file.split('/').pop() ?? file, detail: file })
    return rows
  }, [attachments, autonomy, mentions, project, stage])
  const contextTokenEstimate = useMemo(
    () => Math.ceil((buildContext().length + mentions.reduce((n, m) => n + m.text.length, 0) + attachments.join('\n').length) / 4),
    [attachments, autonomy, mentions, project, stage],
  )

  const detectMention = (value: string, caret: number) => {
    const m = value.slice(0, caret).match(/@([\w-]*)$/)
    setMentionQuery(m ? m[1] : null)
  }
  const pickMention = (c: Mention) => {
    const el = inputRef.current
    const caret = el?.selectionStart ?? input.length
    // drop the trailing "@query" the user typed, then attach the entity as a chip
    setAssistantDraft(active.id, {
      text: input.slice(0, caret).replace(/@([\w-]*)$/, '') + input.slice(caret),
      mentions: mentions.some((x) => x.id === c.id) ? mentions : [...mentions, c],
    })
    setMentionQuery(null)
    setTimeout(() => inputRef.current?.focus(), 0)
  }
  // the composer's @ button — types an @ at the caret and opens the typeahead
  const insertMention = () => {
    const caret = inputRef.current?.selectionStart ?? input.length
    const before = input.slice(0, caret)
    const pad = before && !/\s$/.test(before) ? ' ' : ''
    setAssistantDraft(active.id, { text: `${before}${pad}@${input.slice(caret)}` })
    setMentionQuery('')
    const pos = before.length + pad.length + 1
    setTimeout(() => { inputRef.current?.focus(); inputRef.current?.setSelectionRange(pos, pos) }, 0)
  }

  const refresh = () => bridge.acp.status().then((s) => setAgents(s.agents))
  useEffect(() => { bridge.acp.presets().then(setPresets); refresh() }, [])
  useEffect(() => { const off = bridge.acp.onControls(() => refresh()); return off }, [])
  // many agents print an OAuth URL to authorize — surface it as an openable link
  useEffect(() => {
    const off = bridge.acp.onNotice((n) => {
      if (n.url) { setAuthUrl(n.url); setNotice(`${n.agent ?? 'The agent'} needs browser authorization.`) }
    })
    return off
  }, [])
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
  const connect = async (key: string): Promise<boolean> => {
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
    const res = await bridge.acp.connect(
      custom
        ? { presetId: key, name: custom.name, command: custom.command, args: custom.args, autonomy, cwd, resumeSessionId }
        : { presetId: key, autonomy, cwd, resumeSessionId },
    )
    if (res.ok) {
      setNotice(null); refresh()
      // this agentKey now belongs to the active project — so its background
      // permission asks / terminals route home after a mid-run tab switch
      useKaisola.getState().setAgentProject(key)
      // remember the agent-side session so the NEXT connect can resume it
      if (res.agent?.sessionId) useKaisola.getState().setThreadAcpSession(active.id, res.agent.sessionId)
      if (res.resumed) setNotice('Resumed the previous session.')
    }
    else setNotice(res.message ?? 'Could not connect.')
    return res.ok
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
    if (connected || busy || !workspacePath) return
    const preset = presets.find((p) => p.id === agentKey)
    const custom = useKaisola.getState().customAgents.find((a) => a.id === agentKey && a.kind === 'acp')
    if ((!preset || preset.terminalOnly) && !custom) return
    const attempt = `${agentKey}|${workspacePath}`
    if (acpAutoConnectTried.has(attempt)) return
    acpAutoConnectTried.add(attempt)
    void connect(agentKey)
  }, [agentKey, connected, busy, presets, workspacePath])
  const onControlChange = async (c: UiControl, value: string) => {
    if (c.kind === 'mode') await bridge.acp.setMode(agentKey, value)
    else if (c.kind === 'model') await bridge.acp.setModel(agentKey, value)
    else await bridge.acp.setConfigOption(agentKey, c.id, value)
    refresh()
  }
  const applySpeed = async (nextSpeed: AssistantSpeed): Promise<boolean> => {
    if (!speedControl) return false
    const value = speedOptionValue(speedControl, nextSpeed)
    if (!value) return false
    if (value === speedControl.value) return true
    const res = await bridge.acp.setConfigOption(agentKey, speedControl.id, value)
    if (!res.ok && res.message) setNotice(res.message)
    refresh()
    return res.ok
  }
  const setSpeed = (value: string) => {
    if (!isAssistantSpeed(value)) return
    setAssistantDraft(active.id, { speed: value })
    void applySpeed(value)
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
        if (last && last.kind === k) turns[turns.length - 1] = { ...last, text: last.text + text }
        else turns.push({ kind: k, text, at })
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
          out.push({ type: 'diff', path: c.path, oldText: String(c.oldText ?? ''), newText: String(c.newText ?? '') })
        } else if (c.type === 'terminal' && typeof c.terminalId === 'string') {
          out.push({ type: 'terminal', terminalId: c.terminalId })
        }
      }
      return out.length ? out : undefined
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
      return merged
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
        if (Array.isArray(entries)) updateRuntime(threadId, (r) => ({ ...r, plan: entries }))
      } else if (kind === 'tool_call') {
        const tc = u as { toolCallId?: string; title?: string; kind?: string; status?: string }
        flush()
        followLocations(u)
        updateRuntime(threadId, (r) => ({ ...r, turns: [...r.turns, { kind: 'tool', toolId: tc.toolCallId, text: tc.title ?? tc.kind ?? 'tool', status: tc.status ?? 'pending', at: Date.now(), artifacts: artifactsOf(u) }] }))
      } else if (kind === 'tool_call_update') {
        const tc = u as { toolCallId?: string; title?: string; status?: string }
        flush()
        followLocations(u)
        updateRuntime(threadId, (r) => ({
          ...r,
          turns: r.turns.map((x) =>
            x.kind === 'tool' && x.toolId === tc.toolCallId
              ? { ...x, status: tc.status ?? x.status, text: tc.title ?? x.text, artifacts: mergeArtifacts(x.artifacts, artifactsOf(u)) }
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
  const queuePrompt = (prompt: AssistantDraft) => {
    if (!prompt.text.trim()) return
    enqueueAssistantPrompt(active.id, prompt)
    clearAssistantDraft(active.id, { keepSpeed: true })
    resetComposerHeight()
    useKaisola.getState().pushToast('info', `Queued prompt for ${agentName}`)
  }
  const send = async () => {
    const prompt = currentPrompt()
    if (!prompt.text) return
    if (busy) { queuePrompt(prompt); return }
    void sendText(prompt, { clearDraft: true, restoreOnFailure: true })
  }
  /** The composer's send, callable with explicit text (the ⌘L bar uses it). */
  const sendText = async (
    promptOrText: string | AssistantDraft,
    opts: { clearDraft?: boolean; restoreOnFailure?: boolean } = {},
  ): Promise<boolean> => {
    const prompt: AssistantDraft =
      typeof promptOrText === 'string'
        ? { ...EMPTY_DRAFT, text: promptOrText.trim(), speed }
        : { ...promptOrText, text: promptOrText.text.trim(), speed: promptOrText.speed ?? speed }
    if (!prompt.text) return false
    if (useKaisola.getState().assistantThreads.find((t) => t.id === active.id)?.busy) return false
    if (!connected) { const ok = await connect(agentKey); if (!ok) return false }
    const threadId = active.id
    if (useKaisola.getState().assistantThreads.find((t) => t.id === threadId)?.busy) return false
    const first = (useKaisola.getState().assistantRuntimes[threadId] ?? arun).first
    const files = prompt.attachments
    const mns = prompt.mentions
    const refLine = [...mns.map((m) => `@${m.label}`), ...files.map((f) => `📎 ${f.split('/').pop() ?? ''}`)].join('  ·  ')
    const shownText = refLine ? `${prompt.text}\n\n${refLine}` : prompt.text
    autoNameThread(threadId, prompt.text) // first message → the session's topic title
    const userTurn: Turn = { kind: 'user', text: shownText, at: Date.now() }
    updateRuntime(threadId, (r) => ({ ...r, turns: [...r.turns, userTurn], first: false }))
    setThreadBusy(threadId, true)
    if (opts.clearDraft) {
      clearAssistantDraft(threadId, { keepSpeed: true })
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
      res = await bridge.acp.prompt(agentKey, payload, stream.onUpdate, images.length ? images : undefined)
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
    setThreadBusy(threadId, false)
    // finished while the card is put away → amber "needs you" dot in the rail
    if (!useKaisola.getState().dockViews.includes(threadId)) useKaisola.getState().markNeedsYou(threadId)
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
        const cur = useKaisola.getState().assistantDrafts[threadId] ?? EMPTY_DRAFT
        if (!cur.text && cur.attachments.length === 0 && cur.mentions.length === 0) setAssistantDraft(threadId, prompt)
      }
      return false
    }
    return true
  }
  const drainingQueueRef = useRef(false)
  // Queue pause semantics (review findings, 2026-07-09): a pause must always
  // have a matching resume. Resumes: reconnect, a NEW enqueue (the user
  // clearly wants the queue live), or a successful manual send. Stop PAUSES
  // the queue (aborting a turn must not auto-fire the next prompt).
  const queuePausedRef = useRef(false)
  const queueLenRef = useRef(queuedPrompts.length)
  useEffect(() => { if (connected) queuePausedRef.current = false }, [connected])
  useEffect(() => {
    if (queuedPrompts.length > queueLenRef.current) queuePausedRef.current = false // new enqueue resumes
    queueLenRef.current = queuedPrompts.length
  }, [queuedPrompts.length])
  useEffect(() => {
    if (!connected || busy || queuePausedRef.current || drainingQueueRef.current || queuedPrompts.length === 0) return
    const next = dequeueAssistantPrompt(active.id)
    if (!next) return
    drainingQueueRef.current = true
    void sendText(next).then((sent) => {
      if (!sent) {
        enqueueAssistantPrompt(active.id, next, { front: true })
        queuePausedRef.current = true
        useKaisola.getState().pushToast('warn', `${agentName} queue paused — send or queue a prompt to resume`)
      }
    }).finally(() => {
      drainingQueueRef.current = false
    })
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
      enqueueAssistantPrompt(active.id, { ...EMPTY_DRAFT, text: text.trim(), speed })
      useKaisola.getState().pushToast('info', `Queued prompt for ${agentName}`)
      return
    }
    void sendText(text).then((sent) => {
      // never swallow a ⌘L prompt: a race-y busy flip QUEUES it (review
      // finding #4 — it used to be dropped with a misleading toast)
      if (!sent) {
        enqueueAssistantPrompt(active.id, { ...EMPTY_DRAFT, text: text.trim(), speed })
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
    bridge.acp.cancel(agentKey)
    setThreadBusy(active.id, false)
    updateRuntime(active.id, (r) => ({ ...r, thinkStart: undefined }))
  }
  const attach = async () => {
    const r = await bridge.pickFiles()
    if (r.ok && r.paths) setAssistantDraft(active.id, { attachments: [...new Set([...attachments, ...r.paths])] })
  }
  // the foot's agent picker re-points the active thread to a different agent
  const setThreadAgent = (key: string) => {
    const preset = presets.find((p) => p.id === key)
    if (preset?.terminalOnly) { openTerminalPreset(preset); return }
    setStoreThreadAgent(active.id, key); resetAssistantRuntime(active.id); refresh()
  }

  return (
    <div
      className="assistant"
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
        setAssistantDraft(active.id, { attachments: [...new Set([...attachments, ...paths])] })
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
        {showAgentActivity && (
          <div className="agent-activity">
            <div className="agent-activity-head">
              <Icon name="Activity" size={14} />
              <div className="grow">
                <div className="agent-activity-title">{agentName} activity</div>
                <div className="agent-activity-sub">{activitySubhead}</div>
              </div>
              <span className="agent-activity-pill" data-on={busy || activeToolCount > 0}>{busy || activeToolCount > 0 ? 'Running' : 'Idle'}</span>
            </div>
            {liveAgentTerminals.length > 0 && (
              <div className="agent-activity-block">
                <div className="agent-activity-label">Background terminals</div>
                {liveAgentTerminals.map((term) => (
                  <div key={term.terminalId} className="agent-activity-row agent-activity-terminal">
                    <Icon name="TerminalSquare" size={12} />
                    <div className="grow min0">
                      <div className="truncate">{term.label || term.command || term.terminalId}</div>
                      {(term.cwd || term.command) && <div className="agent-activity-meta truncate">{shortPath(term.cwd)}{term.cwd && term.command ? ' · ' : ''}{term.command}</div>}
                    </div>
                    <button className="btn btn-ghost btn-sm" onClick={() => setDockView(term.terminalId)}>Open</button>
                  </div>
                ))}
              </div>
            )}
            {visibleToolCalls.length > 0 && (
              <div className="agent-activity-block">
                <div className="agent-activity-label">Subagents &amp; tool calls</div>
                {visibleToolCalls.map((call, idx) => {
                  const kind = activityKind(call.text)
                  const tone = statusTone(call.status)
                  return (
                    <div key={`${call.toolId ?? call.text}-${idx}`} className="agent-activity-row agent-activity-call" data-status={tone}>
                      <Icon name={kind.icon} size={12} />
                      <span className="agent-activity-kind">{kind.label}</span>
                      <span className="grow truncate">{call.text}</span>
                      <span className="agent-activity-status">{call.status || 'pending'}</span>
                    </div>
                  )
                })}
              </div>
            )}
            {!liveAgentTerminals.length && !visibleToolCalls.length && (
              <div className="agent-activity-empty">
                Tool calls, delegated subagents, and background terminal commands will appear here as the agent works.
              </div>
            )}
          </div>
        )}
        {arun.turns.length === 0 && !notice && (
          <div className="assistant-empty">
            <Icon name="Sparkles" size={18} />
            <p>
              {connected
                ? `Message ${agentName} — it reads files and runs commands here.`
                : presets.find((p) => p.id === agentKey)?.login
                  ? `Pick a workspace, then send — ${agentName} connects on send.`
                  : `Connect ${agentName} in Settings to start.`}
            </p>
          </div>
        )}
        {(arun.plan?.length ?? 0) > 0 && <PlanStrip plan={arun.plan!} />}
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
                <button onClick={() => setAssistantDraft(active.id, { attachments: attachments.filter((x) => x !== f) })}><Icon name="X" size={10} /></button>
              </span>
            ))}
          </div>
        )}
        {mentions.length > 0 && (
          <div className="composer-attach">
            {mentions.map((mn) => (
              <span key={mn.id} className="attach-chip" title={mn.text}>
                <Icon name={mentionIcon(mn.kind)} size={11} /> {mn.label.length > 30 ? `${mn.label.slice(0, 30)}…` : mn.label}
                <button onClick={() => setAssistantDraft(active.id, { mentions: mentions.filter((x) => x.id !== mn.id) })}><Icon name="X" size={10} /></button>
              </span>
            ))}
          </div>
        )}
        {queuedPrompts.length > 0 && (
          <div className="composer-queue">
            <span className="composer-queue-label">
              <Icon name="ListChecks" size={11} /> {queuedPrompts.length} queued
            </span>
            {queuedPrompts.slice(0, 4).map((q) => (
              <span key={q.id} className="queue-chip" title={q.text}>
                <Icon name={q.speed === 'fast' ? 'Gauge' : q.speed === 'deep' ? 'Brain' : 'Circle'} size={10} />
                {q.text.length > 34 ? `${q.text.slice(0, 34)}…` : q.text}
                <button onClick={() => removeQueuedAssistantPrompt(active.id, q.id)}><Icon name="X" size={9} /></button>
              </span>
            ))}
          </div>
        )}
        {mentionQuery != null && mentionCandidates.length > 0 && (
          <div className="mention-menu">
            {mentionCandidates.map((c) => (
              <button key={c.id} className="mention-item" onMouseDown={(e) => { e.preventDefault(); pickMention(c) }}>
                <Icon name={mentionIcon(c.kind)} size={13} />
                <span className="grow truncate">{c.label}</span>
                <span className="faint mention-kind">{c.kind}</span>
              </button>
            ))}
          </div>
        )}
        <details className="context-ledger">
          <summary>
            <Icon name="Database" size={12} />
            {arun.usage
              ? <>Context · {Math.round((arun.usage.used / arun.usage.size) * 100)}% of {Math.round(arun.usage.size / 1000)}k
                  <span className="ctx-meter" data-hot={arun.usage.used / arun.usage.size > 0.7 || undefined}>
                    <span className="ctx-meter-fill" style={{ width: `${Math.min(100, Math.round((arun.usage.used / arun.usage.size) * 100))}%` }} />
                  </span>
                  · {contextLedger.length} item{contextLedger.length === 1 ? '' : 's'}</>
              : <>Context · {contextLedger.length} item{contextLedger.length === 1 ? '' : 's'} · ~{contextTokenEstimate} tokens</>}
          </summary>
          <div className="context-ledger-list">
            {contextLedger.map((row) => (
              <div key={row.id} className="context-ledger-row">
                <Icon name={row.icon} size={12} className="muted" />
                <span className="grow truncate">{row.label}</span>
                <span className="faint truncate">{row.detail}</span>
              </div>
            ))}
          </div>
        </details>
        <textarea
          ref={inputRef}
          className="composer-input"
          value={input}
          onChange={(e) => { const v = e.target.value; setAssistantDraft(active.id, { text: v }); autoGrow(e.currentTarget); detectMention(v, e.target.selectionStart ?? v.length) }}
          onKeyDown={(e) => {
            if (mentionQuery != null && mentionCandidates.length > 0) {
              if (e.key === 'Enter') { e.preventDefault(); pickMention(mentionCandidates[0]); return }
              if (e.key === 'Escape') { e.preventDefault(); setMentionQuery(null); return }
            }
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
          }}
          placeholder={`Message ${agentName}…`}
          rows={1}
          spellCheck={false}
        />
        <div className="composer-bar">
          <button className="composer-tool" onClick={attach} title="Attach files"><Icon name="Paperclip" size={14} /></button>
          <button className="composer-tool" onClick={insertMention} title="Reference a paper, claim, hypothesis, run or figure"><Icon name="AtSign" size={14} /></button>
          <Dropdown icon="Gauge" value={speed} options={SPEED_OPTIONS} onSelect={setSpeed} title="Speed" />
          {visibleControls.map((c) => (
            <Dropdown key={c.id} icon={CATEGORY_ICON[c.category]} value={c.value} options={c.options} onSelect={(v) => onControlChange(c, v)} title={c.name} />
          ))}
          <span className="grow" />
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
