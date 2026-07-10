import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { useKaisola, GROUP_COLORS } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { useUpdateState } from '../../lib/updates'
import { Icon } from '../Icon'
import { Dropdown, type DropOption } from '../Dropdown'
import { WindowLights } from './WindowLights'
import { InboxButton } from './InboxButton'
import { ShellTools } from './AgentSidebar'
import { terminalAgentKey } from '../../lib/sessionHue'
import { SessionTabs } from './SessionTabs'

const basename = (p: string | null | undefined) => (p ? p.split('/').filter(Boolean).pop() : undefined)
const tabLabel = (t: { title?: string; workspacePath: string | null }) => t.title ?? basename(t.workspacePath) ?? 'New Project'

/**
 * The project strip (Chrome's tab bar). Its own grid row, drawn to the true
 * window top: traffic lights, a scrolling tablist of project tabs (each its
 * own workspace + session set), the "+" launcher menu, and a drag spacer.
 * Subscribes ONLY to `projectTabs` + `activeProjectId` (+ its actions) so a
 * background agent's writes re-render nothing but a badge here.
 */
export function ProjectTabs() {
  const tabs = useKaisola((s) => s.projectTabs)
  const activeId = useKaisola((s) => s.activeProjectId)
  const tabLayout = useKaisola((s) => s.tabLayout)
  // Derive activity for EVERY project, including parked slices. Previously a
  // tab only received `running` after it was already in the background, so the
  // common flow (start agent → switch tab) lost its dot entirely.
  const projectSlices = useKaisola((s) => s.projectSlices)
  const terminalMeta = useKaisola((s) => s.terminalMeta)
  const activeTerminals = useKaisola((s) => s.terminals)
  const activeAgentTerminals = useKaisola((s) => s.agentTerminals)
  const activeThreads = useKaisola((s) => s.assistantThreads)
  const activeNeedsYou = useKaisola((s) => s.needsYou)
  const activePermissions = useKaisola((s) => s.pendingPermissions)
  const switchProject = useKaisola((s) => s.switchProject)
  const closeProject = useKaisola((s) => s.closeProject)
  const reorderProjects = useKaisola((s) => s.reorderProjects)
  const renameProjectTab = useKaisola((s) => s.renameProjectTab)
  const setProjectColor = useKaisola((s) => s.setProjectColor)
  const detachProjectToWindow = useKaisola((s) => s.detachProjectToWindow)

  const [editing, setEditing] = useState<string | null>(null)
  const [editValue, setEditValue] = useState('')
  const [menu, setMenu] = useState<{ x: number; y: number; id: string } | null>(null)
  const dragRef = useRef<string | null>(null)
  const activeRef = useRef<HTMLDivElement>(null)
  const trackRef = useRef<HTMLDivElement>(null)

  // the edge fades are SCROLL CUES: only fade a side that actually hides tabs —
  // an always-on mask dissolves the outermost tab's border (it sits in the fade)
  const syncFade = () => {
    const el = trackRef.current
    if (!el) return
    el.dataset.fadeL = String(el.scrollLeft > 2)
    el.dataset.fadeR = String(el.scrollLeft + el.clientWidth < el.scrollWidth - 2)
  }

  // keep the current tab in view as you cycle / open (Chrome scrolls the strip)
  useEffect(() => {
    activeRef.current?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
    syncFade()
  }, [activeId, tabs])
  useEffect(() => {
    window.addEventListener('resize', syncFade)
    return () => window.removeEventListener('resize', syncFade)
  }, [])

  const beginRename = (id: string, label: string) => { setEditing(id); setEditValue(label) }
  const commitRename = () => {
    if (editing) renameProjectTab(editing, editValue.trim() || undefined)
    setEditing(null)
  }
  const closeOthers = (id: string) => {
    // snapshot first — closeProject mutates projectTabs as it re-homes
    for (const t of tabs.filter((t) => t.id !== id)) closeProject(t.id)
  }

  return (
    <div className="tabstrip" data-single={tabs.length === 1 || undefined}>
      <WindowLights />
      <RailToggle />
      <div className="tabstrip-track" role="tablist" ref={trackRef} onScroll={syncFade}>
        {tabs.map((tab) => {
          const active = tab.id === activeId
          const label = tabLabel(tab)
          const loneEmpty = tabs.length === 1 && !tab.workspacePath
          const slice = active
            ? {
                terminals: activeTerminals,
                agentTerminals: activeAgentTerminals,
                assistantThreads: activeThreads,
                needsYou: activeNeedsYou,
                pendingPermissions: activePermissions,
              }
            : projectSlices[tab.id]
          const running = !!slice && (
            slice.terminals.some((terminal) => terminalAgentKey(terminal.singletonKey)
              ? (terminalMeta[terminal.id]?.agentBusy ?? terminalMeta[terminal.id]?.running)
              : terminalMeta[terminal.id]?.running) ||
            slice.agentTerminals.some((terminal) => terminalMeta[terminal.terminalId]?.running) ||
            slice.assistantThreads.some((thread) => thread.busy)
          )
          const needsAttention = !!slice?.pendingPermissions.length
          const unread = !!slice && Object.keys(slice.needsYou).length > 0
          const state = needsAttention || tab.activity === 'needs-you'
            ? 'needs-you'
            : tab.activity === 'failed'
              ? 'failed'
              : running
                ? 'running'
                : unread
                  ? 'completed'
                  : tab.activity
          return (
            <div
              key={tab.id}
              ref={active ? activeRef : undefined}
              className="ptab"
              role="tab"
              aria-selected={active}
              data-project-id={tab.id}
              data-active={active}
              data-state={state}
              style={{ '--ptab-hue': tab.color ?? tab.hue } as CSSProperties}
              draggable={editing !== tab.id}
              onDragStart={() => (dragRef.current = tab.id)}
              onDragOver={(e) => e.preventDefault()}
              onDrop={() => { if (dragRef.current) reorderProjects(dragRef.current, tab.id); dragRef.current = null }}
              onDragEnd={(e) => {
                // Dropped outside THIS window: main hit-tests other Kaisola tab
                // strips first (recombine), otherwise creates a tear-off there.
                const out = e.clientX < -8 || e.clientY < -8 || e.clientX > window.innerWidth + 8 || e.clientY > window.innerHeight + 8
                if (out && dragRef.current === tab.id) void detachProjectToWindow(tab.id, { x: e.screenX, y: e.screenY })
                dragRef.current = null
              }}
              onClick={() => { if (editing !== tab.id) switchProject(tab.id) }}
              onDoubleClick={() => beginRename(tab.id, label)}
              onMouseDown={(e) => { if (e.button === 1) e.preventDefault() }}
              onAuxClick={(e) => { if (e.button === 1) { e.preventDefault(); closeProject(tab.id) } }}
              onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); setMenu({ x: e.clientX, y: e.clientY, id: tab.id }) }}
              title={tab.workspacePath ?? label}
            >
              <span className="ptab-badge" />
              {editing === tab.id ? (
                <input
                  className="ptab-label"
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
                <>
                  <Icon name="Folder" size={13} className="ptab-icon" />
                  <span className="ptab-label truncate">{label}</span>
                </>
              )}
              {!loneEmpty && (
                <button className="ptab-close" onClick={(e) => { e.stopPropagation(); closeProject(tab.id) }} title="Close tab">
                  <Icon name="X" size={11} />
                </button>
              )}
            </div>
          )
        })}
      </div>
      <NewProjectButton />
      {tabLayout === 'compact' && (
        <div className="compact-session-slot">
          <SessionTabs />
        </div>
      )}
      <div className="tabstrip-fill" onDoubleClick={() => bridge.winCtl('zoom')} />
      <UpdatePill />
      {/* the tool cluster rides the strip's right end — in the chrome row,
          never overlapping the session tabs below (App renders the floating
          fallback only where this strip doesn't exist: web + pop windows) */}
      <div className="tabstrip-tools">
        <InboxButton />
        <ShellTools />
      </div>

      {/* portalled to <body> — rendered in-strip it inherits a stacking context
          that loses to the session cards' glass layers and slides behind them */}
      {menu && createPortal(
        <div className="tree-menu-overlay" onMouseDown={() => setMenu(null)} onContextMenu={(e) => { e.preventDefault(); setMenu(null) }}>
          <div
            className="tree-menu"
            style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 200) }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            <button
              className="tree-menu-item"
              onClick={() => { const t = tabs.find((t) => t.id === menu.id); if (t) beginRename(t.id, tabLabel(t)); setMenu(null) }}
            >
              <Icon name="PenLine" size={13} /> Rename…
            </button>
            <div className="tree-menu-sep" />
            {/* Chrome-style color chips (GROUP_COLORS) + a reset-to-auto swatch */}
            <div style={{ display: 'flex', gap: 6, padding: '4px 10px', alignItems: 'center' }}>
              {GROUP_COLORS.map((c) => (
                <button
                  key={c}
                  title="Set tab color"
                  onClick={() => { setProjectColor(menu.id, c); setMenu(null) }}
                  style={{ width: 14, height: 14, borderRadius: '50%', background: c, border: 'none', cursor: 'pointer', padding: 0 }}
                />
              ))}
              <button
                title="Auto color"
                onClick={() => { setProjectColor(menu.id, undefined); setMenu(null) }}
                style={{ width: 14, height: 14, borderRadius: '50%', background: 'transparent', border: '1px solid var(--border-strong)', cursor: 'pointer', padding: 0 }}
              />
            </div>
            <div className="tree-menu-sep" />
            <button className="tree-menu-item" onClick={() => { void detachProjectToWindow(menu.id); setMenu(null) }}>
              <Icon name="AppWindow" size={13} /> Move to new window
            </button>
            <button className="tree-menu-item" onClick={() => { closeProject(menu.id); setMenu(null) }}>
              <Icon name="X" size={13} /> Close tab
            </button>
            {tabs.length > 1 && (
              <button className="tree-menu-item" onClick={() => { closeOthers(menu.id); setMenu(null) }}>
                <Icon name="X" size={13} /> Close other tabs
              </button>
            )}
          </div>
        </div>,
        document.body,
      )}
    </div>
  )
}

/**
 * Sidebar toggle in the Claude-app spot — right of the traffic lights.
 * Hides/shows the left workspace rail (files + outline); ⌘B does the same.
 */
function RailToggle() {
  const railOpen = useKaisola((s) => s.railOpen)
  const toggleRail = useKaisola((s) => s.toggleRail)
  return (
    <button
      className="rail-toggle"
      onClick={toggleRail}
      aria-label={railOpen ? 'Hide sidebar' : 'Show sidebar'}
      title={railOpen ? 'Hide sidebar  ⌘B' : 'Show sidebar  ⌘B'}
    >
      <Icon name={railOpen ? 'PanelLeftClose' : 'PanelLeftOpen'} size={14} />
    </button>
  )
}

/**
 * Chrome's update pill, in Chrome's spot (strip far-right). A found release
 * shows up here immediately — first as quiet download progress, then as the
 * one-click "Restart to update". Checking stays silent; Settings → General
 * shows the full live status.
 */
function UpdatePill() {
  const u = useUpdateState()
  if (u.type === 'downloading') {
    const preparing = (u.percent ?? 0) >= 100
    return (
      <span className="update-pill" data-busy title={preparing ? `Preparing Kaisola ${u.version ?? ''} for a reliable restart` : `Downloading Kaisola ${u.version ?? ''} — restart button appears when it's ready`}>
        <Icon name="ArrowDownToLine" size={12} />
        {preparing ? 'Preparing…' : `${u.percent ?? 0}%`}
      </span>
    )
  }
  if (u.type === 'installing') {
    return (
      <span className="update-pill" data-busy title={u.message ?? 'Restarting Kaisola to apply the downloaded update'}>
        <Icon name="RefreshCw" size={12} />
        {u.message?.startsWith('Waiting') ? 'Waiting for agents…' : 'Restarting…'}
      </span>
    )
  }
  if (u.type !== 'ready') return null
  return (
    <button
      className="update-pill"
      disabled={!!u.checkingForLatest}
      onClick={() => void bridge.update?.install()}
      title={u.checkingForLatest
        ? `Checking whether Kaisola ${u.version} is still latest`
        : u.checkError ?? `Kaisola ${u.version} is downloaded — restart the app to apply`}
    >
      <Icon name={u.checkingForLatest ? 'RefreshCw' : 'ArrowDownToLine'} size={12} />
      {u.checkingForLatest ? 'Checking latest…' : 'Restart to update'}
    </button>
  )
}

/**
 * The "+" launcher menu — a Dropdown of recently opened folders, an "Open
 * folder…" picker, and the recently-closed undo list. Kept in its own
 * component so its recents/closed subscriptions don't storm the strip.
 */
function NewProjectButton() {
  const recentProjects = useKaisola((s) => s.recentProjects)
  const closedProjectStack = useKaisola((s) => s.closedProjectStack)
  const newProject = useKaisola((s) => s.newProject)
  const openProjectFolder = useKaisola((s) => s.openProjectFolder)
  const reopenClosedProject = useKaisola((s) => s.reopenClosedProject)

  const pickFolder = async () => {
    const r = await bridge.pickFolder()
    if (r.ok && r.path) openProjectFolder(r.path)
  }

  const options: DropOption[] = [
    { value: 'open', name: 'Open folder…' },
    ...recentProjects.map((r) => ({ value: `recent:${r.path}`, name: r.name, description: r.path })),
    ...closedProjectStack.map((c) => ({
      value: `reopen:${c.tab.id}`,
      name: `Reopen ${tabLabel(c.tab)}`,
      description: c.tab.workspacePath ?? undefined,
    })),
  ]

  const onSelect = (value: string) => {
    if (value === 'open') void pickFolder()
    else if (value.startsWith('recent:')) openProjectFolder(value.slice('recent:'.length))
    else if (value.startsWith('reopen:')) reopenClosedProject(value.slice('reopen:'.length))
  }

  // Chrome's split control: + opens a fresh tab immediately; the chevron holds
  // the project menu (open folder / recents / reopen closed)
  return (
    <div className="tabstrip-new">
      <button className="tabstrip-new-btn" onClick={() => newProject({ path: null, focus: true })} title="New tab  ⌘T">
        <Icon name="Plus" size={14} />
      </button>
      <Dropdown value="" placeholder="" options={options} onSelect={onSelect} title="Open a project…" align="left" />
    </div>
  )
}
