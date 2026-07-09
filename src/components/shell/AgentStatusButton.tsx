import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { bridge, isDesktop, type AcpAgent } from '../../lib/bridge'
import { useKaisola } from '../../store/store'
import { useAgentRegistry, agentName } from '../../lib/registry'
import { Icon } from '../Icon'

/**
 * Top-bar agent & MCP health — the pattern no surveyed IDE ships cleanly:
 * ONE glanceable trigger (a tiny status dot on a circuit icon; it pulses while
 * any agent works), and on click a compact popover unifying ACP agents, the
 * Claude Code terminal, and the in-app Kaisola MCP server — each a dot + name
 * + state row. Progressive disclosure, no number-badge noise, never stale:
 * status is re-fetched on every open and on every ACP notice.
 * Complements InboxButton (needs-you) — this answers "what is running?".
 */

interface McpInfo {
  ok: boolean
  url?: string | null
  configPath?: string | null
}

const DOT = {
  on: 'var(--success)',
  warn: 'var(--warn)',
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

function Row({ tone, pulse, name, sub, state }: { tone: string; pulse?: boolean; name: string; sub?: string; state: string }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0 }}>
      <StatusDot tone={tone} pulse={pulse} />
      <span style={{ fontWeight: 500, whiteSpace: 'nowrap' }}>{name}</span>
      {sub && <span className="faint truncate">{sub}</span>}
      <span className="grow" />
      <span className="faint" style={{ whiteSpace: 'nowrap' }}>{state}</span>
    </div>
  )
}

export function AgentStatusButton() {
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState<{ right: number; top: number }>({ right: 12, top: 44 })
  const [agents, setAgents] = useState<AcpAgent[]>([])
  const [mcp, setMcp] = useState<McpInfo | null>(null)
  const btnRef = useRef<HTMLButtonElement | null>(null)
  const { all } = useAgentRegistry()
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  // primitive selectors (string/boolean) so the strip never re-renders on noise
  const busyKeys = useKaisola((s) => s.assistantThreads.filter((t) => t.busy).map((t) => t.agentKey).join(','))
  const anyBusy = useKaisola(
    (s) => s.assistantThreads.some((t) => t.busy) || Object.values(s.agentRunning).some(Boolean),
  )
  // the Claude Code terminal: undefined = none, else "is claude in the fg?"
  const claudeRunning = useKaisola((s) => {
    const t = s.terminals.find((x) => x.singletonKey === 'agent:claude-code')
    return t ? /^claude\b/.test(s.terminalMeta[t.id]?.fgProcess ?? '') : undefined
  })

  const load = async () => {
    const [st, info] = await Promise.all([
      bridge.acp.status().catch(() => ({ ok: false, agents: [] as AcpAgent[] })),
      bridge.mcp?.info().catch(() => null) ?? Promise.resolve(null),
    ])
    setAgents(st.agents ?? [])
    setMcp(info)
  }

  // live trigger dot: fetch once on mount, refresh (debounced) on ACP traffic —
  // status is never cached across a connection change, so the dot can't stick
  useEffect(() => {
    if (!isDesktop) return
    void load()
    let timer: number | undefined
    const off = bridge.acp.onNotice(() => {
      window.clearTimeout(timer)
      timer = window.setTimeout(() => void load(), 400)
    })
    return () => {
      off()
      window.clearTimeout(timer)
    }
  }, [])

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])

  if (!isDesktop) return null

  const busy = new Set(busyKeys.split(',').filter(Boolean))
  const connectedCount = agents.filter((a) => a.connected).length + (claudeRunning ? 1 : 0)
  const anyPresent = agents.length > 0 || claudeRunning !== undefined
  const dotTone = connectedCount > 0 ? DOT.on : anyPresent ? DOT.warn : undefined
  const mcpOn = !!mcp?.ok && !!(mcp.url || mcp.configPath)

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
        title={`Agents & MCP — ${connectedCount ? `${connectedCount} connected` : anyPresent ? 'nothing connected' : 'no agents yet'}`}
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
              animation: anyBusy || claudeRunning ? 'queue-pulse 1.4s var(--ease-in-out) infinite' : undefined,
            }}
          />
        )}
      </button>
      {open && createPortal(
        <div className="tree-menu-overlay" onMouseDown={() => setOpen(false)}>
          <div
            style={{
              position: 'fixed', right: pos.right, top: pos.top, width: 280, zIndex: 'var(--z-menu, 900)' as never,
              background: 'var(--bg-3)', border: '1px solid var(--border)', borderRadius: 'var(--r-3, 10px)',
              boxShadow: 'var(--shadow-3, 0 12px 40px rgba(0,0,0,.4))', padding: '10px 12px',
              display: 'flex', flexDirection: 'column', gap: 8, fontSize: 'var(--fs-12)',
            }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <Icon name="CircuitBoard" size={13} />
              <span style={{ fontWeight: 600 }}>Agents</span>
              <span className="grow" />
              <button className="btn-icon btn-sm" onClick={() => void load()} title="Refresh">
                <Icon name="RefreshCw" size={12} />
              </button>
            </div>

            {claudeRunning !== undefined && (
              <Row
                tone={claudeRunning ? DOT.on : DOT.off}
                pulse={claudeRunning}
                name="Claude Code"
                sub="terminal"
                state={claudeRunning ? 'running' : 'idle'}
              />
            )}
            {agents.map((a) => {
              const working = busy.has(a.key)
              const tone = a.connected ? DOT.on : a.authMethods?.length ? DOT.warn : DOT.off
              const state = working ? 'working…' : a.connected ? 'connected' : a.authMethods?.length ? 'sign-in needed' : 'disconnected'
              return (
                <Row
                  key={a.key}
                  tone={tone}
                  pulse={working}
                  name={a.name ?? agentName(all, a.presetId ?? a.key) ?? a.key}
                  sub="acp"
                  state={state}
                />
              )
            })}
            {claudeRunning === undefined && agents.length === 0 && (
              <span className="faint">No agents connected — open a session from the + menu.</span>
            )}

            <div className="hr" />
            <Row
              tone={mcpOn ? DOT.on : DOT.off}
              name="Kaisola MCP"
              sub="project state · ledger"
              state={mcpOn ? 'running' : 'off'}
            />

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
