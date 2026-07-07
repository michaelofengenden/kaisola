import { memo, useEffect, useMemo, useRef, useState } from 'react'
import { useKaisola, type AssistantRuntime, type AssistantThread, type AssistantTurn } from '../store/store'
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
interface Mention { id: string; kind: 'paper' | 'claim' | 'hypothesis' | 'run' | 'figure'; label: string; text: string }
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
      {diffs.map((d) => {
        const stat = diffStat(d.oldText, d.newText)
        const hunks = diffHunks(d.oldText, d.newText)
        return (
          <details key={d.path} className="perm-diff" open={diffs.length === 1}>
            <summary>
              <Icon name="FileDiff" size={12} />
              <span className="grow truncate">{shortPath(d.path)}</span>
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
      })}
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
  const [input, setInput] = useState('')
  const [notice, setNotice] = useState<string | null>(null)
  const [authUrl, setAuthUrl] = useState<string | null>(null)
  const [attachments, setAttachments] = useState<string[]>([])
  // an OS file drag hovering the chat — the drop lands as attachment chips
  const [fileDropHover, setFileDropHover] = useState(false)
  const [mentions, setMentions] = useState<Mention[]>([])
  // the active "@query" being typed (null = the mention typeahead is closed)
  const [mentionQuery, setMentionQuery] = useState<string | null>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  // grow the composer to fit what's typed (capped); reset to one line when empty
  const autoGrow = (el: HTMLTextAreaElement) => { el.style.height = 'auto'; el.style.height = `${Math.min(el.scrollHeight, 160)}px` }
  useEffect(() => { if (inputRef.current && !input) inputRef.current.style.height = '' }, [input])

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
  const agentKey = active.agentKey
  const busy = active.busy
  const permsForAgent = pendingPermissions.filter((p) => p.key === agentKey)
  const arun: Runtime = liveRuntime ?? { turns: [], first: true }
  const agentPreset = presets.find((p) => p.id === agentKey)
  const agentName = agentPreset?.name ?? agentKey
  const aState = agents.find((a) => a.key === agentKey)
  const connected = !!aState?.connected
  const controls = controlList(aState?.controls ?? null)
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
    setInput(input.slice(0, caret).replace(/@([\w-]*)$/, '') + input.slice(caret))
    setMentions((m) => (m.some((x) => x.id === c.id) ? m : [...m, c]))
    setMentionQuery(null)
    setTimeout(() => inputRef.current?.focus(), 0)
  }
  // the composer's @ button — types an @ at the caret and opens the typeahead
  const insertMention = () => {
    const caret = inputRef.current?.selectionStart ?? input.length
    const before = input.slice(0, caret)
    const pad = before && !/\s$/.test(before) ? ' ' : ''
    setInput(`${before}${pad}@${input.slice(caret)}`)
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
    const res = await bridge.acp.connect(
      custom
        ? { presetId: key, name: custom.name, command: custom.command, args: custom.args, autonomy, cwd }
        : { presetId: key, autonomy, cwd },
    )
    if (res.ok) {
      setNotice(null); refresh()
      // this agentKey now belongs to the active project — so its background
      // permission asks / terminals route home after a mid-run tab switch
      useKaisola.getState().setAgentProject(key)
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
  const onControlChange = async (c: UiControl, value: string) => {
    if (c.kind === 'mode') await bridge.acp.setMode(agentKey, value)
    else if (c.kind === 'model') await bridge.acp.setModel(agentKey, value)
    else await bridge.acp.setConfigOption(agentKey, c.id, value)
    refresh()
  }

  const makeOnUpdate = (threadId: string) => (u: AcpUpdate) => {
    const kind = u.sessionUpdate
    const now = Date.now()
    const append = (k: Turn['kind'], text: string) =>
      updateRuntime(threadId, (r) => {
        const turns = [...r.turns]
        let thinkStart = r.thinkStart
        // start the thinking clock on the first thought; stop it (record duration
        // on the thought turn) when the model's visible output begins
        if (k === 'thought' && thinkStart == null) thinkStart = now
        if (k === 'assistant' && thinkStart != null) {
          const ms = now - thinkStart
          thinkStart = undefined
          for (let i = turns.length - 1; i >= 0; i--) {
            if (turns[i].kind === 'thought') { turns[i] = { ...turns[i], thinkMs: ms }; break }
          }
        }
        const last = turns[turns.length - 1]
        if (last && last.kind === k && k !== 'tool') turns[turns.length - 1] = { ...last, text: last.text + text }
        else turns.push({ kind: k, text, at: now })
        return { ...r, turns, thinkStart }
      })
    // follow the agent (Zed's crosshair): tool calls that carry file locations
    // open those files as transient previews while the agent works
    const followLocations = (u2: AcpUpdate) => {
      const st = useKaisola.getState()
      if (!st.followAgent) return
      const locs = (u2 as { locations?: Array<{ path?: string }> }).locations
      const p = locs?.find((l) => typeof l.path === 'string')?.path
      if (p && st.workspacePath && p.startsWith(st.workspacePath)) st.requestFile(p)
    }
    if (kind === 'agent_message_chunk') append('assistant', u.content?.text ?? u.text ?? '')
    else if (kind === 'agent_thought_chunk') append('thought', u.content?.text ?? u.text ?? '')
    else if (kind === 'tool_call') {
      const tc = u as { toolCallId?: string; title?: string; kind?: string; status?: string }
      followLocations(u)
      updateRuntime(threadId, (r) => ({ ...r, turns: [...r.turns, { kind: 'tool', toolId: tc.toolCallId, text: tc.title ?? tc.kind ?? 'tool', status: tc.status ?? 'pending', at: now }] }))
    } else if (kind === 'tool_call_update') {
      const tc = u as { toolCallId?: string; title?: string; status?: string }
      followLocations(u)
      updateRuntime(threadId, (r) => ({ ...r, turns: r.turns.map((x) => (x.kind === 'tool' && x.toolId === tc.toolCallId ? { ...x, status: tc.status ?? x.status, text: tc.title ?? x.text } : x)) }))
    }
  }

  const send = async () => {
    const text = input.trim()
    if (!text || busy) return
    // clear only once the prompt is actually on its way — a failed connect
    // must not eat what the user typed
    const sent = await sendText(text)
    if (sent) setInput('')
  }
  /** The composer's send, callable with explicit text (the ⌘L bar uses it). */
  const sendText = async (text: string): Promise<boolean> => {
    if (!text || busy) return false
    if (!connected) { const ok = await connect(agentKey); if (!ok) return false }
    const threadId = active.id
    const first = arun.first
    const files = attachments
    const mns = mentions
    setAttachments([])
    setMentions([])
    const refLine = [...mns.map((m) => `@${m.label}`), ...files.map((f) => `📎 ${f.split('/').pop() ?? ''}`)].join('  ·  ')
    const shownText = refLine ? `${text}\n\n${refLine}` : text
    autoNameThread(threadId, text) // first message → the session's topic title
    const userTurn: Turn = { kind: 'user', text: shownText, at: Date.now() }
    updateRuntime(threadId, (r) => ({ ...r, turns: [...r.turns, userTurn], first: false }))
    setThreadBusy(threadId, true)
    const mentionPrefix = mns.length ? `Referenced from the research project (use if relevant):\n${mns.map((m) => `- ${m.text}`).join('\n')}\n\n` : ''
    const filePrefix = files.length ? `Attached files (read them if relevant):\n${files.join('\n')}\n\n` : ''
    const payload = `${first ? `${buildContext()}\n\n` : ''}${mentionPrefix}${filePrefix}${text}`
    const res = await bridge.acp.prompt(agentKey, payload, makeOnUpdate(threadId))
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
      return false
    }
    return true
  }
  // the ⌘L bar hands prompts to threads through the store — deliver ours once
  const omniPrompt = useKaisola((s) => s.omniPrompt)
  const omniSeqRef = useRef(0)
  useEffect(() => {
    if (!omniPrompt || omniPrompt.threadId !== threadId || omniPrompt.seq === omniSeqRef.current) return
    omniSeqRef.current = omniPrompt.seq
    useKaisola.getState().clearOmniPrompt()
    const text = omniPrompt.text
    void sendText(text).then((sent) => {
      // never swallow a ⌘L prompt silently — busy/unconnected must SAY so
      if (!sent) useKaisola.getState().pushToast('info', busy ? 'Agent is mid-turn — send it again when it finishes.' : 'Prompt not sent — the agent could not connect.')
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [omniPrompt, threadId])
  const cancelActive = () => {
    bridge.acp.cancel(agentKey)
    setThreadBusy(active.id, false)
    updateRuntime(active.id, (r) => ({ ...r, thinkStart: undefined }))
  }
  const attach = async () => {
    const r = await bridge.pickFiles()
    if (r.ok && r.paths) setAttachments((a) => [...new Set([...a, ...r.paths!])])
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
        setAttachments((a) => [...new Set([...a, ...paths])])
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
        {arun.turns.map((t, i) =>
          t.kind === 'tool' ? (
            <div key={i} data-turn={i} className={`assistant-tool tool-${t.status}`}>
              <Icon name={t.status === 'completed' ? 'CheckCircle2' : t.status === 'failed' ? 'XCircle' : 'Wrench'} size={11} />
              {t.text}{t.status && t.status !== 'completed' && <span className="tool-status">{t.status}</span>}
            </div>
          ) : t.kind === 'thought' ? (
            <details key={i} data-turn={i} className="assistant-thought" open>
              <summary>
                <Icon name="Brain" size={12} />
                {t.thinkMs != null
                  ? `Thought for ${Math.max(1, Math.round(t.thinkMs / 1000))}s`
                  : arun.thinkStart != null
                    ? `Thinking… ${Math.round((Date.now() - arun.thinkStart) / 1000)}s`
                    : 'Thinking'}
              </summary>
              <div className="thought-text"><Markdown text={t.text} /></div>
            </details>
          ) : (
            <div key={i} data-turn={i} className={`assistant-turn turn-${t.kind}`}>
              <span className="turn-tag">
                {t.kind === 'user' ? 'You' : agentName}
                {t.at != null && <span className="turn-time">{clockTime(new Date(t.at).toISOString())}</span>}
              </span>
              <div className="turn-text">
                {t.kind === 'assistant'
                  ? (t.text ? <Markdown text={t.text} /> : (busy && i === arun.turns.length - 1 ? '▌' : ''))
                  : t.text}
              </div>
            </div>
          ),
        )}
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
                <button onClick={() => setAttachments((a) => a.filter((x) => x !== f))}><Icon name="X" size={10} /></button>
              </span>
            ))}
          </div>
        )}
        {mentions.length > 0 && (
          <div className="composer-attach">
            {mentions.map((mn) => (
              <span key={mn.id} className="attach-chip" title={mn.text}>
                <Icon name={mentionIcon(mn.kind)} size={11} /> {mn.label.length > 30 ? `${mn.label.slice(0, 30)}…` : mn.label}
                <button onClick={() => setMentions((a) => a.filter((x) => x.id !== mn.id))}><Icon name="X" size={10} /></button>
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
            Context · {contextLedger.length} item{contextLedger.length === 1 ? '' : 's'} · ~{contextTokenEstimate} tokens
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
          onChange={(e) => { const v = e.target.value; setInput(v); autoGrow(e.currentTarget); detectMention(v, e.target.selectionStart ?? v.length) }}
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
          {controls.map((c) => (
            <Dropdown key={c.id} icon={CATEGORY_ICON[c.category]} value={c.value} options={c.options} onSelect={(v) => onControlChange(c, v)} title={c.name} />
          ))}
          <span className="grow" />
          {busy ? (
            <button className="composer-send composer-stop" onClick={cancelActive} title="Stop output">
              <Icon name="Square" size={11} />
            </button>
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
