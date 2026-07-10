import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { bridge, isDesktop, type AcpAgent, type McpProbeResult, type McpServerRow } from '../../lib/bridge'
import { useKaisola } from '../../store/store'
import { useAgentRegistry, agentName } from '../../lib/registry'
import { Icon } from '../Icon'

/**
 * Top-bar agent & MCP health — the pattern no surveyed IDE ships cleanly:
 * ONE glanceable trigger (a tiny status dot on a circuit icon; it pulses while
 * any agent works), and on click a compact popover unifying ACP agents, the
 * Claude Code terminal, the in-app Kaisola MCP server, AND the workspace's
 * external MCP servers (.mcp.json + the user catalog) — each a dot + name +
 * state row. Project servers arrive untrusted and show an Approve action
 * (MCP consent guidance); remote servers get a live initialize/tools probe.
 * Never stale: everything re-fetches on open and on ACP/catalog events.
 * Complements InboxButton (needs-you) — this answers "what is running?".
 */

interface McpInfo {
  ok: boolean
  url?: string | null
  configPath?: string | null
  toolCount?: number
}

const DOT = {
  on: 'var(--success)',
  warn: 'var(--warn)',
  err: 'var(--danger)',
  off: 'var(--text-3)',
} as const

function StatusDot({ tone, pulse }: { tone: string; pulse?: boolean }) {
  return (
    <span
      aria-hidden
      style={{
        width: 7,
        height: 7,
        borderRadius: 'var(--r-full)',
        background: tone,
        flexShrink: 0,
        animation: pulse ? 'queue-pulse 1.4s var(--ease-in-out) infinite' : undefined,
      }}
    />
  )
}

function Row({ tone, pulse, name, sub, state, title, action }: {
  tone: string; pulse?: boolean; name: string; sub?: string; state: string; title?: string
  action?: { label: string; onClick: () => void }
}) {
  // state reads inline after the name — the old right-aligned grow-spacer
  // left half of every row as dead gutter (measured)
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0 }} title={title}>
      <StatusDot tone={tone} pulse={pulse} />
      <span style={{ fontWeight: 500, whiteSpace: 'nowrap' }}>{name}</span>
      <span className="faint truncate" style={{ minWidth: 0 }}>
        {[sub, state].filter(Boolean).join(' · ')}
      </span>
      {action && (
        <>
          <span className="grow" />
          <button className="btn btn-ghost btn-sm" style={{ height: 20, padding: '0 6px', flexShrink: 0 }} onClick={action.onClick}>
            {action.label}
          </button>
        </>
      )}
    </div>
  )
}

export function AgentStatusButton() {
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState<{ right: number; top: number }>({ right: 12, top: 44 })
  const [agents, setAgents] = useState<AcpAgent[]>([])
  const [mcp, setMcp] = useState<McpInfo | null>(null)
  const [servers, setServers] = useState<McpServerRow[]>([])
  const [configError, setConfigError] = useState<string | null>(null)
  const [probes, setProbes] = useState<Record<string, McpProbeResult>>({})
  const [discovered, setDiscovered] = useState<Array<{ name: string; origin: string }>>([])
  const btnRef = useRef<HTMLButtonElement | null>(null)
  const { all, menu } = useAgentRegistry()
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const requestFile = useKaisola((s) => s.requestFile)
  const followAgent = useKaisola((s) => s.followAgent)
  const toggleFollowAgent = useKaisola((s) => s.toggleFollowAgent)
  // primitive selectors (string/boolean) so the strip never re-renders on noise
  const busyKeys = useKaisola((s) => s.assistantThreads.filter((t) => t.busy).map((t) => t.agentKey).join(','))
  const anyBusy = useKaisola(
    (s) => s.assistantThreads.some((t) => t.busy) || Object.values(s.agentRunning).some(Boolean) || s.terminals.some((t) => !!s.terminalMeta[t.id]?.agentBusy),
  )
  // the Claude Code terminal: undefined = none, else "is claude in the fg?"
  const claudeRunning = useKaisola((s) => {
    const t = s.terminals.find((x) => x.singletonKey === 'agent:claude-code')
    return t ? /^claude\b/.test(s.terminalMeta[t.id]?.fgProcess ?? '') : undefined
  })
  const claudeBusy = useKaisola((s) => {
    const t = s.terminals.find((x) => x.singletonKey === 'agent:claude-code')
    return t ? !!s.terminalMeta[t.id]?.agentBusy : false
  })
  const codexRunning = useKaisola((s) => {
    const t = s.terminals.find((x) => x.singletonKey?.startsWith('agent:codex'))
    return t ? /^codex\b/.test(s.terminalMeta[t.id]?.fgProcess ?? '') : undefined
  })
  const codexBusy = useKaisola((s) => {
    const t = s.terminals.find((x) => x.singletonKey?.startsWith('agent:codex'))
    return t ? !!s.terminalMeta[t.id]?.agentBusy : false
  })

  const probeRemotes = (rows: McpServerRow[]) => {
    for (const r of rows.filter((x) => x.enabled && x.kind !== 'stdio').slice(0, 6)) {
      void bridge.mcp?.serverProbe?.({ workspace: workspacePath, name: r.name })
        .then((res) => setProbes((p) => ({ ...p, [r.name]: res })))
        .catch(() => {})
    }
  }
  const load = async () => {
    const [st, info, srv, disc] = await Promise.all([
      bridge.acp.status().catch(() => ({ ok: false, agents: [] as AcpAgent[] })),
      bridge.mcp?.info().catch(() => null) ?? Promise.resolve(null),
      bridge.mcp?.servers?.(workspacePath).catch(() => null) ?? Promise.resolve(null),
      bridge.mcp?.discover?.().catch(() => null) ?? Promise.resolve(null),
    ])
    setAgents(st.agents ?? [])
    setMcp(info)
    if (srv?.ok) {
      setServers(srv.servers)
      setConfigError(srv.projectError ?? srv.userError ?? null)
      probeRemotes(srv.servers)
    }
    setDiscovered(disc?.ok ? disc.found : [])
  }

  // live trigger dot: fetch on mount/workspace switch, refresh (debounced) on
  // ACP traffic and catalog changes — never cached across a connection change
  useEffect(() => {
    if (!isDesktop) return
    setProbes({})
    void load()
    let timer: number | undefined
    const bump = () => {
      window.clearTimeout(timer)
      timer = window.setTimeout(() => void load(), 400)
    }
    const offs = [bridge.acp.onNotice(bump), bridge.mcp?.onServersChanged?.(bump)]
    return () => {
      for (const off of offs) off?.()
      window.clearTimeout(timer)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspacePath])

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', onKey)
    // while open, the panel is LIVE — a steady poll under the event triggers,
    // so busy/connected states never read stale ("the activity doesn't stay")
    const iv = window.setInterval(() => void load(), 2500)
    return () => {
      window.removeEventListener('keydown', onKey)
      window.clearInterval(iv)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  if (!isDesktop) return null

  const busy = new Set(busyKeys.split(',').filter(Boolean))
  const connectedCount = agents.filter((a) => a.connected).length + (claudeRunning ? 1 : 0) + (codexRunning ? 1 : 0)
  // quiet = nothing running, nothing asking for sign-in — the itemized rows
  // would all read the same, so a summary line carries them instead
  const anyWorking = agents.some((a) => busy.has(a.key) || a.busy) || claudeBusy || codexBusy
  const anyAttention = anyWorking || agents.some((a) => !a.connected && a.authMethods?.length)
  const allQuiet = !anyAttention
  const offMenu = menu.filter((m) => m.kind === 'acp' && !agents.some((a) => (a.presetId ?? a.key) === m.id))
  const quietConnected = agents.filter((a) => a.connected).length
  const quietOff = agents.length - quietConnected + offMenu.length
  // hover keeps the full roster reachable while the panel stays one line
  const quietTitle = [
    ...(claudeRunning !== undefined ? ['Claude Code (terminal)'] : []),
    ...(codexRunning !== undefined ? ['Codex CLI (terminal)'] : []),
    ...agents.map((a) => `${a.name ?? agentName(all, a.presetId ?? a.key) ?? a.key} (${a.connected ? 'connected' : 'off'})`),
    ...offMenu.map((m) => `${m.name} (off)`),
  ].join('\n')
  const anyPresent = agents.length > 0 || claudeRunning !== undefined || codexRunning !== undefined
  const needsApproval = servers.some((r) => r.scope === 'project' && !r.approved)
  const probeFailed = servers.some((r) => r.enabled && r.kind !== 'stdio' && probes[r.name] && !probes[r.name].ok)
  const dotTone = probeFailed ? DOT.err
    : needsApproval ? DOT.warn
      : connectedCount > 0 ? DOT.on
        : anyPresent ? DOT.warn : undefined
  const mcpOn = !!mcp?.ok && !!(mcp.url || mcp.configPath)

  const rowState = (r: McpServerRow): { tone: string; state: string; title?: string } => {
    if (r.scope === 'project' && !r.approved) return { tone: DOT.warn, state: 'needs approval', title: 'This server came with the repo — approve it once to arm it' }
    if (!r.enabled) return { tone: DOT.off, state: 'off' }
    if (r.kind === 'stdio') return { tone: DOT.on, state: 'with session', title: 'stdio servers start inside each agent session' }
    const p = probes[r.name]
    if (!p) return { tone: DOT.off, state: 'checking…' }
    if (!p.ok) return { tone: DOT.err, state: 'unreachable', title: p.message }
    return { tone: DOT.on, state: p.toolCount != null ? `${p.toolCount} tools` : 'reachable', title: p.serverName }
  }
  const setEnabled = async (r: McpServerRow, enabled: boolean) => {
    await bridge.mcp?.serverSet?.({ workspace: workspacePath, scope: r.scope, name: r.name, enabled })
    void load()
  }
  const addServer = async () => {
    const res = await bridge.mcp?.userConfig?.()
    if (res?.ok && res.path) {
      setOpen(false)
      requestFile(res.path, 'edit', { pinned: true })
    }
  }

  const toggle = () => {
    if (!open) {
      const r = btnRef.current?.getBoundingClientRect()
      if (r) setPos({ right: Math.max(8, window.innerWidth - r.right), top: r.bottom + 6 })
      void load()
    }
    setOpen(!open)
  }

  return (
    <>
      <button
        ref={btnRef}
        className="btn-icon"
        data-active={open}
        onClick={toggle}
        style={{ position: 'relative' }}
        title={`Agents & MCP — ${connectedCount ? `${connectedCount} connected` : anyPresent ? 'nothing connected' : 'no agents yet'}${needsApproval ? ' · a project MCP server needs approval' : ''}`}
      >
        <Icon name="CircuitBoard" size={15} />
        {dotTone && (
          <span
            aria-hidden
            style={{
              position: 'absolute',
              right: 5,
              bottom: 5,
              width: 6,
              height: 6,
              borderRadius: 'var(--r-full)',
              background: dotTone,
              boxShadow: '0 0 0 2px var(--bg-1)',
              animation: anyBusy || claudeBusy || codexBusy ? 'queue-pulse 1.4s var(--ease-in-out) infinite' : undefined,
            }}
          />
        )}
      </button>
      {open && createPortal(
        <div className="tree-menu-overlay" onMouseDown={() => setOpen(false)}>
          <div
            style={{
              position: 'fixed', right: pos.right, top: pos.top, width: 252, zIndex: 'var(--z-menu, 900)' as never,
              background: 'var(--bg-3)', border: '1px solid var(--border)', borderRadius: 'var(--r-3, 10px)',
              boxShadow: 'var(--shadow-3, 0 12px 40px rgba(0,0,0,.4))', padding: '10px 12px',
              display: 'flex', flexDirection: 'column', gap: 8, fontSize: 'var(--fs-12)',
              maxHeight: '70vh', overflowY: 'auto',
            }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <Icon name="CircuitBoard" size={13} />
              <span style={{ fontWeight: 600 }}>Agents</span>
              <span className="grow" />
              <button
                className="btn-icon btn-sm"
                data-active={followAgent}
                onClick={toggleFollowAgent}
                title={followAgent ? 'Following files agents touch' : 'Follow files agents touch'}
              >
                <Icon name="Crosshair" size={12} />
              </button>
              <button className="btn-icon btn-sm" onClick={() => void load()} title="Refresh">
                <Icon name="RefreshCw" size={12} />
              </button>
            </div>

            {/* everything quiet → one summary line (roster rides the tooltip);
                itemize only when a row differentiates (working / sign-in / running) */}
            {allQuiet && (anyPresent || offMenu.length > 0) && (
              <span className="faint" title={quietTitle || undefined}>
                {[
                  quietConnected ? `${quietConnected} connected` : null,
                  claudeRunning !== undefined || codexRunning !== undefined ? 'terminal ready' : null,
                  quietOff ? `${quietOff} off` : null,
                ].filter(Boolean).join(' · ')} — all idle
              </span>
            )}
            {!allQuiet && claudeRunning !== undefined && (
              <Row
                tone={claudeRunning ? DOT.on : DOT.off}
                pulse={claudeBusy}
                name="Claude Code"
                sub="terminal"
                state={claudeBusy ? 'working…' : claudeRunning ? 'ready' : 'idle'}
              />
            )}
            {!allQuiet && codexRunning !== undefined && (
              <Row
                tone={codexRunning ? DOT.on : DOT.off}
                pulse={codexBusy}
                name="Codex CLI"
                sub="terminal"
                state={codexBusy ? 'working…' : codexRunning ? 'ready' : 'idle'}
              />
            )}
            {!allQuiet && agents.map((a) => {
              // busy: renderer thread state OR main's per-connection truth
              const working = busy.has(a.key) || !!a.busy
              const tone = a.connected ? DOT.on : a.authMethods?.length ? DOT.warn : DOT.off
              const state = working ? 'working…' : a.connected ? 'connected' : a.authMethods?.length ? 'sign-in needed' : 'disconnected'
              const cwdName = a.cwd?.split('/').filter(Boolean).pop()
              // the connection's full identity rides the tooltip (main reports
              // session id, autonomy, MCP handoff, resume/image capabilities)
              const detail = [
                a.autonomy && `autonomy: ${a.autonomy}`,
                a.mcpHttp != null && `kaisola tools: ${a.mcpHttp ? 'on' : 'off'}`,
                a.canLoadSession && 'resumes sessions',
                a.promptImages && 'takes images',
                a.sessionId && `session ${a.sessionId.slice(0, 8)}`,
              ].filter(Boolean).join(' · ')
              return (
                <Row
                  key={a.key}
                  tone={tone}
                  pulse={working}
                  name={a.name ?? agentName(all, a.presetId ?? a.key) ?? a.key}
                  sub={cwdName ? `acp · ${cwdName}` : 'acp'}
                  state={state}
                  title={detail || undefined}
                />
              )
            })}
            {/* enabled agents that AREN'T connected still get a quiet row —
                rows must never vanish between sessions ("doesn't stay") */}
            {!allQuiet && offMenu.map((m) => (
              <Row key={`off:${m.id}`} tone={DOT.off} name={m.name} sub="acp" state="off" title="Not connected — open a session from the + menu" />
            ))}
            {claudeRunning === undefined && codexRunning === undefined && agents.length === 0 && menu.filter((m) => m.kind === 'acp').length === 0 && (
              <span className="faint">No agents connected — open a session from the + menu.</span>
            )}

            <div className="hr" />
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontWeight: 600 }}>MCP servers</span>
              <span className="grow" />
              <button className="btn btn-ghost btn-sm" style={{ height: 20, padding: '0 6px' }} onClick={() => void addServer()} title="Edit the user server catalog (JSON) — servers here follow you across projects">
                <Icon name="Plus" size={11} /> Add
              </button>
            </div>
            <Row
              tone={mcpOn ? DOT.on : DOT.off}
              name="kaisola"
              sub="built-in"
              state={mcpOn ? (mcp?.toolCount != null ? `${mcp.toolCount} tools` : 'running') : 'off'}
              title="Project state + the agent-task ledger, shared with every agent"
            />
            {servers.map((r) => {
              const st = rowState(r)
              const unapproved = r.scope === 'project' && !r.approved
              return (
                <Row
                  key={`${r.scope}:${r.name}`}
                  tone={st.tone}
                  name={r.name}
                  sub={r.scope === 'project' ? '.mcp.json' : r.kind}
                  state={st.state}
                  title={st.title ?? r.detail}
                  action={
                    unapproved
                      ? { label: 'Approve', onClick: () => void setEnabled(r, true) }
                      : { label: r.enabled ? 'On' : 'Off', onClick: () => void setEnabled(r, !r.enabled) }
                  }
                />
              )
            })}
            {configError && (
              <span className="faint" style={{ color: 'var(--warn)' }}>{configError}</span>
            )}
            {!servers.length && (
              <span className="faint">Add servers here (user-wide) or ship a .mcp.json with the repo.</span>
            )}
            {discovered.length > 0 && (
              <button
                className="btn btn-ghost btn-sm"
                style={{ justifyContent: 'flex-start', gap: 6 }}
                onClick={async () => { await bridge.mcp?.importDiscovered?.(); void load() }}
                title={`Found in ${[...new Set(discovered.map((d) => d.origin))].join(' / ')}: ${discovered.map((d) => d.name).join(', ')} — imported servers arrive OFF; arm each one yourself`}
              >
                <Icon name="Import" size={11} /> Import {discovered.length} from {[...new Set(discovered.map((d) => d.origin))].join(' / ')}
              </button>
            )}

            <button
              className="btn btn-ghost btn-sm"
              style={{ justifyContent: 'flex-start', gap: 6, marginTop: 2 }}
              onClick={() => { setOpen(false); openSettings(true, 'agents') }}
            >
              <Icon name="Settings" size={12} /> Manage agents…
            </button>
          </div>
        </div>,
        document.body,
      )}
    </>
  )
}
