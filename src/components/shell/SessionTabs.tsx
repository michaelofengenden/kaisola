import { useCallback, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from 'react'
import { useKaisola, sessionOrderIds } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { sessionHue, terminalAgentKey } from '../../lib/sessionHue'
import { useAgentRegistry, openAgentSession } from '../../lib/registry'
import { urlHost, terminalLabel, threadLabel } from '@/lib/sessionLabel'
import { Icon } from '../Icon'
import { ProviderIcon } from '../ProviderIcon'
import { Dropdown } from '../Dropdown'
import { CostChip } from './CostChip'
import { ShellSidebarFooter } from './ShellSidebarFooter'
import { isRunningMeshPhase } from '../../lib/meshPolicy'
import { useClickAway } from '../../lib/useClickAway'

interface STab {
  id: string
  icon: string
  agentKey?: string
  label: string
  hue: string
  /** Pulse while working; completed stays still until the session is viewed. */
  state?: 'needs-you' | 'failed' | 'running' | 'completed'
  kind: 'thread' | 'term' | 'agentTerm' | 'panel'
  closable: boolean
  continued?: boolean
  title?: string
}

/**
 * The session strip — the project tab bar's idea, one level down. A tab per
 * live session (agent threads, terminals, panels) in the SAME order the rail,
 * ⌘1..9 and Ctrl+Tab use; click to bring that session into view, double-click
 * to rename, × (or middle-click) to close. The "+" session menu lives at the
 * end of the strip, Chrome's new-tab position.
 */
export function SessionTabs({ orientation = 'horizontal', filter = '' }: { orientation?: 'horizontal' | 'vertical'; filter?: string }) {
  const threads = useKaisola((s) => s.assistantThreads)
  const terminals = useKaisola((s) => s.terminals)
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const panels = useKaisola((s) => s.panels)
  const terminalMeta = useKaisola((s) => s.terminalMeta)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const activeProjectId = useKaisola((s) => s.activeProjectId)
  // Select the active object by reference rather than the whole project array:
  // background project activity dots can update without repainting this shelf.
  const activeProject = useKaisola((s) => s.projectTabs.find((project) => project.id === s.activeProjectId))
  const sessionGroups = useKaisola((s) => s.sessionGroups)
  const pinnedSessions = useKaisola((s) => s.pinnedSessions)
  const sessionOrder = useKaisola((s) => s.sessionOrder)
  const needsYou = useKaisola((s) => s.needsYou)
  const pendingPermissions = useKaisola((s) => s.pendingPermissions)
  const dockViews = useKaisola((s) => s.dockViews)
  const dockOpen = useKaisola((s) => s.dockOpen)
  const setTabLayout = useKaisola((s) => s.setTabLayout)
  const switchSession = useKaisola((s) => s.switchSession)
  const reorderSessions = useKaisola((s) => s.reorderSessions)
  const addDockSplit = useKaisola((s) => s.addDockSplit)
  const removeDockView = useKaisola((s) => s.removeDockView)
  const popOutTerminal = useKaisola((s) => s.popOutTerminal)
  const openBrowserPanel = useKaisola((s) => s.openBrowserPanel)
  const closeThread = useKaisola((s) => s.closeAssistantThread)
  const closeTerminal = useKaisola((s) => s.closeTerminal)
  const closeAgentTerminal = useKaisola((s) => s.closeAgentTerminal)
  const closePanel = useKaisola((s) => s.closePanel)
  const forgetClosedSession = useKaisola((s) => s.forgetClosedSession)
  const pushToast = useKaisola((s) => s.pushToast)
  const renameThread = useKaisola((s) => s.renameAssistantThread)
  const renameTerminal = useKaisola((s) => s.renameTerminal)
  const togglePinSession = useKaisola((s) => s.togglePinSession)
  const saveSessionTemplate = useKaisola((s) => s.saveSessionTemplate)
  const createSessionGroup = useKaisola((s) => s.createSessionGroup)
  const assignToGroup = useKaisola((s) => s.assignToGroup)
  const worktreeSessions = useKaisola((s) => s.worktreeSessions)
  const mergeWorktreeSession = useKaisola((s) => s.mergeWorktreeSession)
  const removeWorktreeSession = useKaisola((s) => s.removeWorktreeSession)
  const proposeWorktreeSession = useKaisola((s) => s.proposeWorktreeSession)
  const { all: agents } = useAgentRegistry()

  // Repeat the active project's identity on the session shelf. Project tabs
  // and session tabs remain separate controls, but now read as a clear parent
  // and child instead of two unrelated rows of pills.
  const projectLabel = activeProject?.title
    ?? activeProject?.workspacePath?.split('/').filter(Boolean).pop()
    ?? 'New Project'
  const projectHue = activeProject?.color ?? activeProject?.hue ?? 'var(--accent)'

  const [editing, setEditing] = useState<string | null>(null)
  const [editValue, setEditValue] = useState('')
  // right-click a tab → the session menu (pin, template, groups, worktree) —
  // this strip is the ONLY session list now, so it owns what the rail used to
  const [menu, setMenu] = useState<{ x: number; y: number; id: string } | null>(null)
  const menuTriggerRef = useRef<HTMLElement | null>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  const dragRef = useRef<string | null>(null)
  const closeMenu = useCallback(() => setMenu(null), [])
  useClickAway(!!menu, closeMenu, menuTriggerRef, menuRef)

  const tabs = new Map<string, STab>()
  const pinnedSessionIds = new Set(pinnedSessions)
  const dockViewIds = new Set(dockViews)
  for (let i = 0; i < threads.length; i += 1) {
    const t = threads[i]
    if (t.groupParentId) continue
    const label = threadLabel(t, agents, threads, i)
    const permissionKeys = t.group
      ? new Set(t.group.members.map((member) => `${member.agentKey}::${member.threadId}`))
      : new Set([`${t.agentKey}::${t.id}`])
    tabs.set(t.id, {
      id: t.id,
      icon: t.group ? 'Network' : 'Sparkles',
      agentKey: t.group ? undefined : t.agentKey,
      label,
      hue: sessionHue({ agentKey: t.agentKey }),
      state: pendingPermissions.some((permission) => permissionKeys.has(permission.key))
        ? 'needs-you'
        : t.busy ? 'running' : needsYou[t.id] ? 'completed' : undefined,
      kind: 'thread',
      closable: !pinnedSessionIds.has(t.id),
      title: 'Double-click to rename',
    })
  }
  terminals.forEach((t, i) => {
    const meta = terminalMeta[t.id]
    const agentKey = terminalAgentKey(t.singletonKey)
    // A broker kept alive by v0.1.39 does not expose the new precise activity
    // bit yet; foreground-process state is the safe compatibility fallback.
    const working = agentKey ? !!(meta?.agentBusy ?? meta?.running) : !!meta?.running
    const label = terminalLabel(t, { meta, agents, index: i, count: terminals.length })
    const failed = !working && (meta?.lastExit ?? 0) > 0
    tabs.set(t.id, {
      id: t.id,
      icon: 'SquareTerminal',
      label,
      hue: sessionHue({ agentKey, folder: meta?.root ?? meta?.cwd ?? t.cwd }),
      state: failed ? 'failed' : working ? 'running' : needsYou[t.id] ? 'completed' : undefined,
      kind: 'term',
      closable: !pinnedSessionIds.has(t.id),
      continued: !!t.continued?.sameProcess,
      title: [
        t.continued?.sameProcess ? 'Continued — same process across the update' : null,
        working && meta?.fgProcess ? `running ${meta.fgProcess}` : null,
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
      state: meta?.running ? 'running' : needsYou[t.terminalId] ? 'completed' : undefined,
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
      state: needsYou[p.id] ? 'completed' : undefined,
      kind: 'panel',
      closable: !pinnedSessionIds.has(p.id),
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
    sessionOrder,
  })

  const closeTab = (t: STab) => {
    if (t.kind === 'thread') {
      const thread = threads.find((candidate) => candidate.id === t.id)
      const ownedThreads = thread?.group
        ? threads.filter((candidate) => candidate.id === thread.id || candidate.groupParentId === thread.id)
        : thread ? [thread] : []
      const ownedKeys = new Set(ownedThreads.map((candidate) => `${candidate.agentKey}::${candidate.id}`))
      const activeWork = ownedThreads.some((candidate) => candidate.busy)
        || !!thread?.group?.operation
        || (!!thread?.group && isRunningMeshPhase(thread.group.phase) && !thread.group.paused)
        || pendingPermissions.some((permission) => ownedKeys.has(permission.key))
      if (activeWork) {
        pushToast('warn', thread?.group ? 'Stop or pause this Mesh before closing it.' : 'Stop this agent and resolve its approval before closing the session.')
        return
      }
      const owned = thread?.group
        ? thread.group.members
        : thread ? [{ threadId: thread.id, agentKey: thread.agentKey }] : []
      for (const member of owned) void (async () => {
        await bridge.acp.cancel(`${member.agentKey}::${member.threadId}`, activeProjectId).catch(() => ({ ok: false }))
        await bridge.acp.disconnect(`${member.agentKey}::${member.threadId}`, activeProjectId).catch(() => ({ ok: false }))
      })()
      closeThread(t.id)
    }
    else if (t.kind === 'term') closeTerminal(t.id)
    else if (t.kind === 'agentTerm') closeAgentTerminal(t.id)
    else closePanel(t.id)
  }
  const deleteTab = async (t: STab) => {
    const thread = t.kind === 'thread' ? threads.find((candidate) => candidate.id === t.id) : undefined
    const label = thread?.group ? 'Mesh session' : t.kind === 'term' || t.kind === 'agentTerm' ? 'terminal session' : t.kind === 'panel' ? 'panel' : 'agent session'
    if (thread?.group?.operation) {
      pushToast('warn', 'Wait for the current Mesh transition to finish or recover before deleting this session.')
      return
    }
    if (!window.confirm(`Permanently delete this ${label}? This removes its saved conversation/session state. Workspace files and git worktrees are never deleted.`)) return
    setMenu(null)
    const owned = thread?.group
      ? threads.filter((candidate) => candidate.groupParentId === thread.id)
      : thread ? [thread] : []
    // Capture archive epochs before the first await. The user can switch tabs
    // while a provider's session/close is pending; afterward the store's flat
    // runtime map belongs to a different project.
    const archiveScopes = owned.map((candidate) => {
      const runtime = useKaisola.getState().assistantRuntimes[candidate.id]
      return {
        projectId: activeProjectId,
        threadId: candidate.id,
        ...(runtime?.archiveEpoch ? { epoch: runtime.archiveEpoch } : {}),
      }
    })
    // Resolve renderer cards first, then perform exactly one ordered provider
    // teardown per owned thread. Calling closeTab here used to launch a second
    // cancel→disconnect path that could win the race and prevent session/close.
    for (const permission of pendingPermissions.filter((candidate) => owned.some((owner) => candidate.key === `${owner.agentKey}::${owner.id}`))) {
      useKaisola.getState().answerPermission(permission.permId, { decision: 'reject' }, { cascadeReject: true })
    }
    const teardown = await Promise.all(owned.map(async (candidate) => {
      const key = `${candidate.agentKey}::${candidate.id}`
      const cancelled = await bridge.acp.cancel(key, activeProjectId).catch(() => ({ ok: false }))
      const closed = await bridge.acp.closeSession(key, activeProjectId).catch(() => ({ ok: false, closed: false }))
      const disconnected = await bridge.acp.disconnect(key, activeProjectId).catch(() => ({ ok: false }))
      return { cancelled, closed, disconnected }
    }))
    const archives = await Promise.all(archiveScopes.map((scope) =>
      bridge.assistantArchive?.clear(scope).catch(() => ({ ok: false })) ?? Promise.resolve({ ok: true }),
    ))
    if (t.kind === 'thread') {
      for (const candidate of owned) useKaisola.getState().setThreadBusy(candidate.id, false, activeProjectId)
      if (thread?.group) useKaisola.getState().setGroupSession(thread.id, { paused: true, pausedAt: Date.now() }, activeProjectId)
      closeThread(t.id, activeProjectId)
    }
    else if (t.kind === 'term') closeTerminal(t.id, activeProjectId)
    else if (t.kind === 'agentTerm') closeAgentTerminal(t.id, activeProjectId)
    else closePanel(t.id, activeProjectId)
    forgetClosedSession(t.id, activeProjectId)
    if (t.kind === 'term' || t.kind === 'agentTerm') void bridge.terminal.kill(t.id, activeProjectId).catch(() => {})
    const teardownFailed = teardown.some((result) => !result.cancelled.ok || !result.closed.ok || result.closed.closed !== true || !result.disconnected.ok)
    const archiveFailed = archives.some((result) => !result.ok)
    pushToast(teardownFailed || archiveFailed ? 'warn' : 'info', `${t.label} deleted. Workspace files were left untouched.${teardownFailed || archiveFailed ? ' Some provider history could not be confirmed removed.' : ''}`)
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

  const menuTab = menu ? tabs.get(menu.id) : undefined
  const menuPorts = menu ? terminalMeta[menu.id]?.ports ?? [] : []
  const normalizedFilter = filter.trim().toLocaleLowerCase()
  const orderedTabs = order.flatMap((id) => {
    const tab = tabs.get(id)
    if (!tab) return []
    if (normalizedFilter && !`${tab.label} ${tab.title ?? ''} ${tab.kind}`.toLocaleLowerCase().includes(normalizedFilter)) return []
    return [tab]
  })
  const activeVisible = orderedTabs.some((tab) => dockViewIds.has(tab.id))

  return (
    <div
      className="stabs"
      role="toolbar"
      aria-orientation={orientation}
      aria-label={`${projectLabel} sessions`}
      data-orientation={orientation}
      data-project-id={activeProjectId}
      data-single={orderedTabs.length === 1 || undefined}
      style={{ '--project-hue': projectHue } as CSSProperties}
    >
      <span className="stabs-project-anchor" aria-hidden="true" title={`${projectLabel} sessions`}>
        <Icon name="CornerDownRight" size={11} />
      </span>
      <div className="stabs-track">
        {orderedTabs.map((t, index) => {
            const active = dockOpen && dockViewIds.has(t.id)
            const focusable = dockViews[dockViews.length - 1] === t.id || (!activeVisible && index === 0)
            return (
              <div
                key={t.id}
                data-sid={t.id}
                className="stab"
                data-active={active}
                data-state={t.state}
                style={{ '--sid': t.hue } as CSSProperties}
                title={t.title}
                draggable={editing !== t.id}
                onDragStart={(event) => {
                  dragRef.current = t.id
                  event.dataTransfer.effectAllowed = 'move'
                  event.dataTransfer.setData('text/plain', t.id)
                  event.currentTarget.setAttribute('data-dragging', 'true')
                }}
                onDragOver={(event) => {
                  if (!dragRef.current || dragRef.current === t.id) return
                  event.preventDefault()
                  event.dataTransfer.dropEffect = 'move'
                }}
                onDrop={(event) => {
                  event.preventDefault()
                  if (dragRef.current && dragRef.current !== t.id) reorderSessions(dragRef.current, t.id)
                  dragRef.current = null
                }}
                onDragEnd={(event) => {
                  event.currentTarget.removeAttribute('data-dragging')
                  dragRef.current = null
                }}
              >
                {editing === t.id ? (
                  <input
                    className="stab-label"
                    value={editValue}
                    autoFocus
                    onChange={(e) => setEditValue(e.target.value)}
                    onBlur={commitRename}
                    onClick={(e) => e.stopPropagation()}
                    onDoubleClick={(e) => e.stopPropagation()}
                    aria-label={`Rename ${t.label}`}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') commitRename()
                      if (e.key === 'Escape') setEditing(null)
                    }}
                    style={{ background: 'transparent', border: 'none', color: 'inherit', font: 'inherit', width: '100%', minWidth: 0 }}
                  />
                ) : (
                  <>
                    <button
                      type="button"
                      className="stab-select"
                      aria-label={`Open session ${t.label}`}
                      aria-current={active ? 'true' : undefined}
                      tabIndex={focusable ? 0 : -1}
                      onClick={() => switchSession(t.id)}
                      onMouseDown={(e) => { if (e.button === 1) e.preventDefault() }}
                      onAuxClick={(e) => { if (e.button === 1 && t.closable) { e.preventDefault(); closeTab(t) } }}
                      onContextMenu={(e) => {
                        e.preventDefault()
                        e.stopPropagation()
                        menuTriggerRef.current = e.currentTarget
                        setMenu({ x: e.clientX, y: e.clientY, id: t.id })
                      }}
                      onKeyDown={(e) => {
                        const backward = orientation === 'vertical' ? 'ArrowUp' : 'ArrowLeft'
                        const forward = orientation === 'vertical' ? 'ArrowDown' : 'ArrowRight'
                        if (![backward, forward, 'Home', 'End'].includes(e.key)) return
                        e.preventDefault()
                        const nextIndex = e.key === 'Home' ? 0
                          : e.key === 'End' ? orderedTabs.length - 1
                            : (index + (e.key === forward ? 1 : -1) + orderedTabs.length) % orderedTabs.length
                        const next = orderedTabs[nextIndex]
                        if (!next) return
                        document.querySelector<HTMLButtonElement>(`.stab[data-sid="${CSS.escape(next.id)}"] > .stab-select`)?.focus()
                      }}
                      onDoubleClick={() => {
                        if (t.kind !== 'thread' && t.kind !== 'term') return
                        setEditing(t.id)
                        setEditValue(t.label)
                      }}
                    />
                    <span className="stab-content" aria-hidden="true">
                      <span className="stab-badge" />
                      {t.kind === 'thread' && t.agentKey
                        ? <ProviderIcon provider={t.agentKey} name={t.label} size={12} className="stab-icon" />
                        : <Icon name={t.icon} size={12} className="stab-icon" />}
                      <span className="stab-label truncate">{t.label}</span>
                      {t.continued && <span className="stab-continuity">Continued</span>}
                      {t.kind === 'term' && <CostChip termId={t.id} />}
                    </span>
                  </>
                )}
                {/* the two-pane button: open this session BESIDE what's showing
                    (a click on the tab itself swaps it into the current pane) */}
                <button
                  type="button"
                  className="stab-split"
                  data-on={active}
                  onClick={(e) => {
                    e.stopPropagation()
                    if (active) removeDockView(t.id)
                    else addDockSplit(t.id)
                  }}
                  title={active ? 'Put this pane away' : 'Open beside — view side by side'}
                  aria-label={active ? `Put ${t.label} away` : `Open ${t.label} beside the current pane`}
                >
                  <Icon name="Columns2" size={11} />
                </button>
                {t.closable && (
                  <button
                    type="button"
                    className="stab-close"
                    onClick={(e) => { e.stopPropagation(); closeTab(t) }}
                    title={t.kind === 'agentTerm' ? 'Hide command output — agent keeps running' : 'Close session — reopen from + or ⇧⌘T'}
                    aria-label={t.kind === 'agentTerm' ? `Hide command output for ${t.label}; agent keeps running` : `Close session ${t.label}`}
                  >
                    <Icon name="X" size={10} />
                  </button>
                )}
              </div>
            )
          })}
        {orientation === 'vertical' && normalizedFilter && orderedTabs.length === 0 && (
          <div className="session-filter-empty" role="status">No matching sessions</div>
        )}
      </div>
      <NewSessionButton orientation={orientation} />
      {orientation === 'horizontal' && (
        <button
          type="button"
          className="stabs-sidebar-toggle"
          onClick={() => setTabLayout('sidebar')}
          title="Move sessions to the left sidebar"
          aria-label="Move sessions to the left sidebar"
        >
          <Icon name="PanelLeftOpen" size={12} />
        </button>
      )}
      {menu && (
        <div className="tree-menu-overlay" onContextMenu={(e) => e.preventDefault()}>
          <div
            ref={menuRef}
            className="tree-menu"
            style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 220) }}
          >
            <button
              type="button"
              className="tree-menu-item"
              onClick={() => {
                if (dockOpen && dockViewIds.has(menu.id)) removeDockView(menu.id)
                else addDockSplit(menu.id)
                setMenu(null)
              }}
            >
              <Icon name="Columns2" size={13} /> {dockOpen && dockViewIds.has(menu.id) ? 'Put pane away' : 'Open beside'}
            </button>
            <button type="button" className="tree-menu-item" onClick={() => { togglePinSession(menu.id); setMenu(null) }}>
              <Icon name={pinnedSessionIds.has(menu.id) ? 'PinOff' : 'Pin'} size={13} />
              {pinnedSessionIds.has(menu.id) ? 'Unpin' : 'Pin'}
            </button>
            <button type="button" className="tree-menu-item" onClick={() => { saveSessionTemplate(menu.id); setMenu(null) }}>
              <Icon name="BookmarkPlus" size={13} /> Save as template
            </button>
            <div className="tree-menu-sep" />
            {sessionGroups.flatMap((group) => (
              group.members.includes(menu.id) ? [] : [
                <button type="button" key={group.id} className="tree-menu-item" onClick={() => { assignToGroup(menu.id, group.id); setMenu(null) }}>
                  <Icon name="FolderInput" size={13} /> Move to “{group.name}”
                </button>,
              ]
            ))}
            <button
              type="button"
              className="tree-menu-item"
              onClick={() => { createSessionGroup(`Group ${sessionGroups.length + 1}`, [menu.id]); setMenu(null) }}
            >
              <Icon name="FolderPlus" size={13} /> New group
            </button>
            {sessionGroups.some((g) => g.members.includes(menu.id)) && (
              <button type="button" className="tree-menu-item" onClick={() => { assignToGroup(menu.id, null); setMenu(null) }}>
                <Icon name="FolderMinus" size={13} /> Remove from group
              </button>
            )}
            {worktreeSessions[menu.id] && (
              <>
                <div className="tree-menu-sep" />
                <button type="button" className="tree-menu-item" onClick={() => { void proposeWorktreeSession(menu.id); setMenu(null) }}>
                  <Icon name="FileDiff" size={13} /> Review changes as proposal
                </button>
                <button type="button" className="tree-menu-item" onClick={() => { void mergeWorktreeSession(menu.id); setMenu(null) }}>
                  <Icon name="GitMerge" size={13} /> Merge worktree back
                </button>
                <button type="button" className="tree-menu-item tree-menu-danger" onClick={() => { void removeWorktreeSession(menu.id); setMenu(null) }}>
                  <Icon name="Trash2" size={13} /> Remove worktree
                </button>
              </>
            )}
            {(menuTab?.kind === 'term' || menuTab?.kind === 'agentTerm') && (
              <>
                <div className="tree-menu-sep" />
                {menuPorts.map((port) => (
                  <button type="button" key={port} className="tree-menu-item" onClick={() => { openBrowserPanel(`http://localhost:${port}`); setMenu(null) }}>
                    <Icon name="Globe" size={13} /> Open localhost:{port}
                  </button>
                ))}
                {menuTab.kind === 'term' && (
                  <button
                    type="button"
                    className="tree-menu-item"
                    onClick={() => { popOutTerminal(menuTab.id, menuTab.label, menuTab.hue); setMenu(null) }}
                  >
                    <Icon name="PictureInPicture2" size={13} /> Open in its own window
                  </button>
                )}
              </>
            )}
            {menuTab && <>
              <div className="tree-menu-sep" />
              <button type="button" className="tree-menu-item tree-menu-danger" onClick={() => { void deleteTab(menuTab) }}>
                <Icon name="Trash2" size={13} /> Delete permanently…
              </button>
            </>}
          </div>
        </div>
      )}
    </div>
  )
}

/** The default session navigator: one slim, persistent rail on the left. */
export function SessionSidebar() {
  const setTabLayout = useKaisola((s) => s.setTabLayout)
  const setSessionRailWidth = useKaisola((s) => s.setSessionRailWidth)
  const [filter, setFilter] = useState('')
  const startResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    event.preventDefault()
    const handle = event.currentTarget
    handle.setPointerCapture(event.pointerId)
    document.body.setAttribute('data-shell-drag', '1')
    const sidebar = handle.parentElement
    const startX = event.clientX
    const startWidth = sidebar?.getBoundingClientRect().width ?? 188
    const onMove = (move: PointerEvent) => setSessionRailWidth(startWidth + move.clientX - startX)
    const onUp = () => {
      document.body.removeAttribute('data-shell-drag')
      handle.removeEventListener('pointermove', onMove)
      handle.removeEventListener('pointerup', onUp)
      handle.removeEventListener('pointercancel', onUp)
    }
    handle.addEventListener('pointermove', onMove)
    handle.addEventListener('pointerup', onUp)
    handle.addEventListener('pointercancel', onUp)
  }
  return (
    <aside className="session-sidebar" aria-label="Session sidebar">
      <div className="session-sidebar-head">
        <span>Sessions</span>
        <button type="button" onClick={() => setTabLayout('bare')} title="Move sessions across the top" aria-label="Move sessions across the top">
          <Icon name="PanelTop" size={13} />
        </button>
      </div>
      <label className="session-filter">
        <Icon name="Search" size={12} />
        <input
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
          onKeyDown={(event) => { if (event.key === 'Escape') { event.preventDefault(); setFilter('') } }}
          placeholder="Filter sessions"
          aria-label="Filter sessions"
          spellCheck={false}
        />
        {filter && <button type="button" onClick={() => setFilter('')} aria-label="Clear session filter" title="Clear"><Icon name="X" size={11} /></button>}
      </label>
      <SessionTabs orientation="vertical" filter={filter} />
      <ShellSidebarFooter />
      <div
        className="session-sidebar-resize"
        onPointerDown={startResize}
        onDoubleClick={() => setSessionRailWidth(null)}
        onKeyDown={(event) => {
          if (event.key === 'Home') { event.preventDefault(); setSessionRailWidth(null); return }
          if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
          event.preventDefault()
          const current = event.currentTarget.parentElement?.getBoundingClientRect().width ?? 188
          setSessionRailWidth(current + (event.key === 'ArrowLeft' ? -20 : 20))
        }}
        role="separator"
        aria-label="Resize session sidebar"
        aria-orientation="vertical"
        tabIndex={0}
        title="Drag to resize sessions · double-click to reset"
      />
    </aside>
  )
}

/**
 * The "+" session menu — agents first (the user picks WHICH one — no silent
 * default), then saved templates, the other session kinds, and the registry.
 * Its own component so the recents/template subscriptions don't storm the strip.
 */
function NewSessionButton({ orientation }: { orientation: 'horizontal' | 'vertical' }) {
  const { menu } = useAgentRegistry()
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const openGitPanel = useKaisola((s) => s.openGitPanel)
  const openLedgerPanel = useKaisola((s) => s.openLedgerPanel)
  const openBrowserPanel = useKaisola((s) => s.openBrowserPanel)
  const setSettingsOpen = useKaisola((s) => s.setSettingsOpen)
  const sessionTemplates = useKaisola((s) => s.sessionTemplates)
  const openSessionTemplate = useKaisola((s) => s.openSessionTemplate)
  const newWorktreeSession = useKaisola((s) => s.newWorktreeSession)
  const closedStack = useKaisola((s) => s.closedStack)
  const reopenClosedSession = useKaisola((s) => s.reopenClosedSession)
  const openSession = (value: string) => {
    if (value === 'group') { useKaisola.getState().requestNewGroup(); return }
    if (value === 'terminal') { requestTerminal(); return }
    if (value === 'git') { openGitPanel(); return }
    if (value === 'ledger') { openLedgerPanel(); return }
    if (value === 'browser') { openBrowserPanel(); return }
    if (value === 'worktree') { void newWorktreeSession(); return }
    if (value === 'registry') { setSettingsOpen(true, 'agents'); return }
    if (value.startsWith('tpl:')) { openSessionTemplate(value.slice(4)); return }
    if (value.startsWith('closed:')) { reopenClosedSession(value.slice('closed:'.length)); return }
    const agent = menu.find((a) => a.id === value.slice('agent:'.length))
    if (agent) openAgentSession(agent)
  }
  // recently-closed sessions reopen from here (⌘⇧T restores the newest);
  // closed agent threads carry their acpSessionId, so a reopen also resumes
  // the agent-side conversation
  const recentlyClosed = closedStack.slice(0, 6).flatMap((c) => {
    const id = c.term?.id ?? c.thread?.id ?? c.panel?.id ?? ''
    const label = c.thread
      ? c.thread.name ?? c.thread.autoName ?? c.thread.agentKey
      : c.term
        ? c.term.name ?? c.term.autoName ?? 'Terminal'
        : c.panel?.title ?? c.panel?.kind ?? 'Panel'
    return id ? [{ value: `closed:${id}`, name: `↩ ${label}` }] : []
  })
  const codex = menu.find((agent) => agent.id === 'codex')
  const claude = menu.find((agent) => agent.id === 'claude-code')
  const otherAgents = menu.filter((agent) => agent.id !== 'codex' && agent.id !== 'claude-code')
  return (
    <Dropdown
      icon="Plus"
      value=""
      placeholder=""
      options={[
        { value: 'terminal', name: 'New terminal' },
        ...(codex ? [{ value: `agent:${codex.id}`, name: codex.name }] : []),
        ...(claude ? [{ value: `agent:${claude.id}`, name: claude.name }] : []),
        { value: 'group', name: 'Mesh', description: 'A coordinated agent group with explicit write gates' },
        ...otherAgents.map((a) => ({ value: `agent:${a.id}`, name: a.name })),
        ...sessionTemplates.map((t) => ({ value: `tpl:${t.id}`, name: `▸ ${t.name}` })),
        { value: 'worktree', name: 'Agent in a worktree' },
        { value: 'git', name: 'Git commit' },
        { value: 'ledger', name: 'Agent tasks' },
        { value: 'browser', name: 'Browser' },
        ...recentlyClosed,
        { value: 'registry', name: 'Add agents…' },
      ]}
      onSelect={openSession}
      title="New session"
      align="left"
      placement={orientation === 'vertical' ? 'bottom' : 'auto'}
    />
  )
}
