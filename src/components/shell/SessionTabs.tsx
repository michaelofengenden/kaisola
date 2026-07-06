import { useState, type CSSProperties } from 'react'
import { useKaisola, sessionOrderIds } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { sessionHue, terminalAgentKey } from '../../lib/sessionHue'
import { useAgentRegistry, agentName, openAgentSession } from '../../lib/registry'
import { Icon } from '../Icon'
import { Dropdown } from '../Dropdown'

const urlHost = (u?: string) => {
  try {
    return u ? new URL(u).host : undefined
  } catch {
    return undefined
  }
}

interface STab {
  id: string
  icon: string
  label: string
  hue: string
  /** Badge precedence mirrors the project tabs: needs-you > failed > running. */
  state?: 'needs-you' | 'failed' | 'running'
  kind: 'thread' | 'term' | 'agentTerm' | 'panel'
  closable: boolean
  title?: string
}

/**
 * The session strip — the project tab bar's idea, one level down. A tab per
 * live session (agent threads, terminals, panels) in the SAME order the rail,
 * ⌘1..9 and Ctrl+Tab use; click to bring that session into view, double-click
 * to rename, × (or middle-click) to close. The "+" session menu lives at the
 * end of the strip, Chrome's new-tab position.
 */
export function SessionTabs() {
  const threads = useKaisola((s) => s.assistantThreads)
  const terminals = useKaisola((s) => s.terminals)
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const panels = useKaisola((s) => s.panels)
  const terminalMeta = useKaisola((s) => s.terminalMeta)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const sessionGroups = useKaisola((s) => s.sessionGroups)
  const pinnedSessions = useKaisola((s) => s.pinnedSessions)
  const needsYou = useKaisola((s) => s.needsYou)
  const dockViews = useKaisola((s) => s.dockViews)
  const switchSession = useKaisola((s) => s.switchSession)
  const closeThread = useKaisola((s) => s.closeAssistantThread)
  const closeTerminal = useKaisola((s) => s.closeTerminal)
  const closeAgentTerminal = useKaisola((s) => s.closeAgentTerminal)
  const closePanel = useKaisola((s) => s.closePanel)
  const renameThread = useKaisola((s) => s.renameAssistantThread)
  const renameTerminal = useKaisola((s) => s.renameTerminal)
  const { all: agents } = useAgentRegistry()

  const [editing, setEditing] = useState<string | null>(null)
  const [editValue, setEditValue] = useState('')

  const tabs = new Map<string, STab>()
  threads.forEach((t, i) => {
    const nm = agentName(agents, t.agentKey) ?? 'Agent'
    const label = t.name ?? t.autoName ?? `${nm}${threads.filter((x) => x.agentKey === t.agentKey).length > 1 ? ` ${i + 1}` : ''}`
    tabs.set(t.id, {
      id: t.id,
      icon: 'Sparkles',
      label,
      hue: sessionHue({ agentKey: t.agentKey }),
      state: needsYou[t.id] ? 'needs-you' : t.busy ? 'running' : undefined,
      kind: 'thread',
      closable: !pinnedSessions.includes(t.id),
      title: 'Double-click to rename',
    })
  })
  terminals.forEach((t, i) => {
    const meta = terminalMeta[t.id]
    const agentKey = terminalAgentKey(t.singletonKey)
    // stable identity, never keystrokes: manual name → agent → repo → folder
    const folder = meta?.repo ?? (meta?.cwd ?? t.cwd)?.split('/').filter(Boolean).pop()
    const label =
      t.name ??
      (agentKey ? agentName(agents, agentKey) ?? agentKey : undefined) ??
      folder ??
      (terminals.length > 1 ? `Terminal ${i + 1}` : 'Terminal')
    const failed = !meta?.running && (meta?.lastExit ?? 0) > 0
    tabs.set(t.id, {
      id: t.id,
      icon: 'SquareTerminal',
      label,
      hue: sessionHue({ agentKey, folder: meta?.root ?? meta?.cwd ?? t.cwd }),
      state: needsYou[t.id] ? 'needs-you' : failed ? 'failed' : meta?.running ? 'running' : undefined,
      kind: 'term',
      closable: terminals.length > 1 && !pinnedSessions.includes(t.id),
      title: [
        meta?.running && meta.fgProcess ? `running ${meta.fgProcess}` : null,
        meta?.repo && `${meta.repo}${meta.branch ? ` ⎇ ${meta.branch}` : ''}`,
        meta?.cwd,
        'Double-click to rename',
      ]
        .filter(Boolean)
        .join(' · '),
    })
  })
  agentTerminals.forEach((t) => {
    const meta = terminalMeta[t.terminalId]
    tabs.set(t.terminalId, {
      id: t.terminalId,
      icon: 'SquareTerminal',
      label: t.label || 'agent',
      hue: sessionHue({ agentKey: t.agentKey, folder: meta?.root ?? t.cwd }),
      state: needsYou[t.terminalId] ? 'needs-you' : meta?.running ? 'running' : undefined,
      kind: 'agentTerm',
      closable: true,
      title: `${t.agentName ?? 'agent'}: ${t.command ?? ''}`,
    })
  })
  panels.forEach((p) => {
    tabs.set(p.id, {
      id: p.id,
      icon: p.kind === 'git' ? 'GitCommitHorizontal' : 'Globe',
      label: p.kind === 'git' ? 'Commit' : p.title ?? urlHost(p.url) ?? 'Browser',
      hue:
        p.kind === 'git'
          ? sessionHue({ agentKey: 'git', folder: workspacePath })
          : sessionHue({ agentKey: urlHost(p.url) ?? 'browser' }),
      state: needsYou[p.id] ? 'needs-you' : undefined,
      kind: 'panel',
      closable: !pinnedSessions.includes(p.id),
      title: p.kind === 'git' ? 'Stage & commit' : p.url,
    })
  })

  const order = sessionOrderIds({
    assistantThreads: threads,
    terminals,
    agentTerminals,
    panels,
    sessionGroups,
    pinnedSessions,
  })

  const closeTab = (t: STab) => {
    if (t.kind === 'thread') closeThread(t.id)
    else if (t.kind === 'term') closeTerminal(t.id)
    else if (t.kind === 'agentTerm') {
      closeAgentTerminal(t.id)
      bridge.terminal.kill(t.id)
    } else closePanel(t.id)
  }
  const commitRename = () => {
    if (editing) {
      const name = editValue.trim() || undefined
      const t = tabs.get(editing)
      if (t?.kind === 'thread') renameThread(editing, name)
      else if (t?.kind === 'term') renameTerminal(editing, name)
    }
    setEditing(null)
  }

  return (
    <div className="stabs" role="tablist">
      <div className="stabs-track">
        {order
          .map((id) => tabs.get(id))
          .filter((t): t is STab => !!t)
          .map((t) => {
            const active = dockViews.includes(t.id)
            return (
              <div
                key={t.id}
                className="stab"
                role="tab"
                aria-selected={active}
                data-active={active}
                data-state={t.state}
                style={{ '--sid': t.hue } as CSSProperties}
                onClick={() => { if (editing !== t.id) switchSession(t.id) }}
                onDoubleClick={() => {
                  if (t.kind !== 'thread' && t.kind !== 'term') return
                  setEditing(t.id)
                  setEditValue(t.label)
                }}
                onMouseDown={(e) => { if (e.button === 1) e.preventDefault() }}
                onAuxClick={(e) => { if (e.button === 1 && t.closable) { e.preventDefault(); closeTab(t) } }}
                title={t.title}
              >
                <Icon name={t.icon} size={12} className="stab-icon" />
                {editing === t.id ? (
                  <input
                    className="stab-label"
                    value={editValue}
                    autoFocus
                    onChange={(e) => setEditValue(e.target.value)}
                    onBlur={commitRename}
                    onClick={(e) => e.stopPropagation()}
                    onDoubleClick={(e) => e.stopPropagation()}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') commitRename()
                      if (e.key === 'Escape') setEditing(null)
                    }}
                    style={{ background: 'transparent', border: 'none', outline: 'none', color: 'inherit', font: 'inherit', width: '100%', minWidth: 0 }}
                  />
                ) : (
                  <span className="stab-label truncate">{t.label}</span>
                )}
                <span className="stab-badge" />
                {t.closable && (
                  <button className="stab-close" onClick={(e) => { e.stopPropagation(); closeTab(t) }} title="Close session">
                    <Icon name="X" size={10} />
                  </button>
                )}
              </div>
            )
          })}
      </div>
      <NewSessionButton />
    </div>
  )
}

/**
 * The "+" session menu — agents first (the user picks WHICH one — no silent
 * default), then saved templates, the other session kinds, and the registry.
 * Its own component so the recents/template subscriptions don't storm the strip.
 */
function NewSessionButton() {
  const { menu } = useAgentRegistry()
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const openGitPanel = useKaisola((s) => s.openGitPanel)
  const openBrowserPanel = useKaisola((s) => s.openBrowserPanel)
  const setSettingsOpen = useKaisola((s) => s.setSettingsOpen)
  const sessionTemplates = useKaisola((s) => s.sessionTemplates)
  const openSessionTemplate = useKaisola((s) => s.openSessionTemplate)
  const newWorktreeSession = useKaisola((s) => s.newWorktreeSession)
  const openSession = (value: string) => {
    if (value === 'terminal') { requestTerminal(); return }
    if (value === 'git') { openGitPanel(); return }
    if (value === 'browser') { openBrowserPanel(); return }
    if (value === 'worktree') { void newWorktreeSession(); return }
    if (value === 'registry') { setSettingsOpen(true, 'agents'); return }
    if (value.startsWith('tpl:')) { openSessionTemplate(value.slice(4)); return }
    const agent = menu.find((a) => a.id === value.slice('agent:'.length))
    if (agent) openAgentSession(agent)
  }
  return (
    <Dropdown
      icon="Plus"
      value=""
      placeholder=""
      options={[
        ...menu.map((a) => ({ value: `agent:${a.id}`, name: a.name })),
        ...sessionTemplates.map((t) => ({ value: `tpl:${t.id}`, name: `▸ ${t.name}` })),
        { value: 'worktree', name: 'Agent in a worktree' },
        { value: 'terminal', name: 'New terminal' },
        { value: 'git', name: 'Git commit' },
        { value: 'browser', name: 'Browser' },
        { value: 'registry', name: 'Add agents…' },
      ]}
      onSelect={openSession}
      title="New session"
      align="left"
    />
  )
}
