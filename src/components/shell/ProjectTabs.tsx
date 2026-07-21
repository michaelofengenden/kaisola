import { Fragment, useEffect, useRef, useState, type CSSProperties, type DragEvent as ReactDragEvent, type PointerEvent as ReactPointerEvent } from 'react'
import { createPortal } from 'react-dom'
import { useShallow } from 'zustand/react/shallow'
import { useKaisola, GROUP_COLORS } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { Icon } from '../Icon'
import { Dropdown, type DropOption } from '../Dropdown'
import { WindowLights } from './WindowLights'
import { terminalAgentKey } from '../../lib/sessionHue'
import { SessionTabs } from './SessionTabs'
import { ShellSidebarFooter } from './ShellSidebarFooter'
import { SavedWindows } from './SavedWindows'

const dragEndedOutsideWindow = (event: ReactDragEvent<HTMLElement>) => {
  const clientOutside = event.clientX < -8 || event.clientY < -8
    || event.clientX > window.innerWidth + 8 || event.clientY > window.innerHeight + 8
  const screenOutside = event.screenX < window.screenX - 8 || event.screenY < window.screenY - 8
    || event.screenX > window.screenX + window.outerWidth + 8
    || event.screenY > window.screenY + window.outerHeight + 8
  return clientOutside || screenOutside
}

const basename = (p: string | null | undefined) => (p ? p.split('/').filter(Boolean).pop() : undefined)
const tabLabel = (t: { title?: string; workspacePath: string | null }) => t.title ?? basename(t.workspacePath) ?? 'New Project'

/** Project drag-reorder / tear-off, inline rename, and close-others — shared by
 * both navigation layouts (Top strip and Left tree) so their identical project
 * management logic lives once. Returns the rename edit state plus a
 * `dragHandlers(id)` factory for the draggable node. */
function useProjectNav() {
  const tabs = useKaisola((s) => s.projectTabs)
  const reorderProjects = useKaisola((s) => s.reorderProjects)
  const detachProjectToWindow = useKaisola((s) => s.detachProjectToWindow)
  const renameProjectTab = useKaisola((s) => s.renameProjectTab)
  const closeProject = useKaisola((s) => s.closeProject)
  const [editing, setEditing] = useState<string | null>(null)
  const [editValue, setEditValue] = useState('')
  const dragRef = useRef<string | null>(null)

  const beginRename = (id: string, label: string) => { setEditing(id); setEditValue(label) }
  const commitRename = () => {
    if (editing) renameProjectTab(editing, editValue.trim() || undefined)
    setEditing(null)
  }
  const closeOthers = (id: string) => {
    // snapshot first — closeProject mutates projectTabs as it re-homes
    for (const tab of tabs.filter((candidate) => candidate.id !== id)) closeProject(tab.id)
  }
  const dragHandlers = (id: string) => ({
    onDragStart: (event: ReactDragEvent<HTMLElement>) => {
      dragRef.current = id
      event.dataTransfer.effectAllowed = 'move'
      event.dataTransfer.setData('text/plain', id)
    },
    onDragOver: (event: ReactDragEvent<HTMLElement>) => {
      event.preventDefault()
      event.dataTransfer.dropEffect = 'move'
    },
    onDrop: () => { if (dragRef.current) reorderProjects(dragRef.current, id); dragRef.current = null },
    onDragEnd: (event: ReactDragEvent<HTMLElement>) => {
      // Dropped outside THIS window: main hit-tests other Kaisola tab strips
      // first (recombine), otherwise creates a tear-off there.
      const out = dragEndedOutsideWindow(event)
      if (out && dragRef.current === id) void detachProjectToWindow(id, { x: event.screenX, y: event.screenY })
      dragRef.current = null
    },
  })

  return { editing, editValue, setEditValue, beginRename, commitRename, closeOthers, dragHandlers }
}

/** One low-churn project activity selector shared by both navigation modes. */
function useProjectTabStates() {
  return useKaisola(
    useShallow((s) =>
      s.projectTabs.map((tab) => {
        const slice = tab.id === s.activeProjectId
          ? {
              terminals: s.terminals,
              agentTerminals: s.agentTerminals,
              assistantThreads: s.assistantThreads,
              needsYou: s.needsYou,
              pendingPermissions: s.pendingPermissions,
            }
          : s.projectSlices[tab.id]
        const running = !!slice && (
          slice.terminals.some((terminal) => terminalAgentKey(terminal.singletonKey)
            ? (s.terminalMeta[terminal.id]?.agentBusy ?? s.terminalMeta[terminal.id]?.running)
            : s.terminalMeta[terminal.id]?.running) ||
          slice.agentTerminals.some((terminal) => s.terminalMeta[terminal.terminalId]?.running) ||
          slice.assistantThreads.some((thread) => thread.busy)
        )
        const needsAttention = !!slice?.pendingPermissions.length
        const unread = !!slice && Object.keys(slice.needsYou).length > 0
        return needsAttention || tab.activity === 'needs-you'
          ? 'needs-you'
          : tab.activity === 'failed'
            ? 'failed'
            : running
              ? 'running'
              : unread
                ? 'completed'
                : tab.activity ?? ''
      }),
    ),
  )
}

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
  // Derive activity for EVERY project, including parked slices. Previously a
  // tab only received `running` after it was already in the background, so the
  // common flow (start agent → switch tab) lost its dot entirely.
  // ONE shallow-compared array of derived states, not raw slice/meta
  // subscriptions: projectSlices and terminalMeta change identity on every
  // feed line and pty tick, which re-rendered the whole strip during streams.
  const tabStates = useProjectTabStates()
  const switchProject = useKaisola((s) => s.switchProject)
  const setProjectColor = useKaisola((s) => s.setProjectColor)
  const detachProjectToWindow = useKaisola((s) => s.detachProjectToWindow)
  const { editing, editValue, setEditValue, beginRename, commitRename, closeOthers, dragHandlers } = useProjectNav()

  const [menu, setMenu] = useState<{ x: number; y: number; id: string } | null>(null)
  const [expandedProjectId, setExpandedProjectId] = useState<string | null>(null)
  const activeRef = useRef<HTMLDivElement>(null)
  const trackRef = useRef<HTMLDivElement>(null)
  const previousActiveId = useRef(activeId)

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
  // Top navigation behaves like a Chrome tab group: selecting a different
  // project reveals its member sessions inline, while clicking the active
  // project collapses or reopens that group without changing the workspace.
  useEffect(() => {
    if (previousActiveId.current === activeId) return
    previousActiveId.current = activeId
    setExpandedProjectId(activeId)
  }, [activeId])
  useEffect(() => {
    window.addEventListener('resize', syncFade)
    return () => window.removeEventListener('resize', syncFade)
  }, [])

  return (
    <div className="tabstrip" data-single={tabs.length === 1 || undefined}>
      <WindowLights />
      <div className="tabstrip-track" role="tablist" ref={trackRef} onScroll={syncFade}>
        {tabs.map((tab, i) => {
          const active = tab.id === activeId
          const label = tabLabel(tab)
          const loneEmpty = tabs.length === 1 && !tab.workspacePath
          const state = tabStates[i] || undefined
          const expanded = active && expandedProjectId === tab.id
          return (
            <Fragment key={tab.id}>
            <div
              ref={active ? activeRef : undefined}
              className="ptab"
              data-project-id={tab.id}
              data-active={active}
              data-state={state}
              style={{ '--ptab-hue': tab.color ?? tab.hue } as CSSProperties}
              draggable={editing !== tab.id}
              {...dragHandlers(tab.id)}
              title={tab.workspacePath ?? label}
            >
              {editing === tab.id ? (
                <input
                  className="ptab-label"
                  aria-label="Project name"
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
                  style={{ background: 'transparent', border: 'none', color: 'inherit', font: 'inherit', width: '100%', minWidth: 0 }}
                />
              ) : (
                <>
                  <button type="button"
                    className="ptab-select"
                    role="tab"
                    aria-label={`Project ${label}`}
                    aria-selected={active}
                    tabIndex={active ? 0 : -1}
                    aria-expanded={active ? expanded : undefined}
                    aria-controls={active ? `project-session-group-${tab.id}` : undefined}
                    onClick={() => {
                      if (active) setExpandedProjectId((current) => current === tab.id ? null : tab.id)
                      else {
                        setExpandedProjectId(tab.id)
                        switchProject(tab.id)
                      }
                    }}
                    onMouseDown={(e) => { if (e.button === 1) e.preventDefault() }}
                    onAuxClick={(e) => { if (e.button === 1) { e.preventDefault(); closeProject(tab.id) } }}
                    onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); setMenu({ x: e.clientX, y: e.clientY, id: tab.id }) }}
                    onKeyDown={(e) => {
                      const keys = ['ArrowLeft', 'ArrowRight', 'Home', 'End']
                      if (!keys.includes(e.key)) return
                      e.preventDefault()
                      const nextIndex = e.key === 'Home' ? 0
                        : e.key === 'End' ? tabs.length - 1
                          : (i + (e.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length
                      const next = tabs[nextIndex]
                      if (!next) return
                      switchProject(next.id)
                      queueMicrotask(() => document.querySelector<HTMLButtonElement>(`.ptab[data-project-id="${CSS.escape(next.id)}"] > .ptab-select`)?.focus())
                    }}
                  />
                  <span className="ptab-content" aria-hidden="true">
                    <span className="ptab-badge" />
                    <Icon name="Folder" size={13} className="ptab-icon" />
                    <span className="ptab-label truncate">{label}</span>
                    {active && <Icon name="ChevronDown" size={10} className="ptab-group-chevron" data-open={expanded || undefined} />}
                  </span>
                </>
              )}
              {!loneEmpty && (
                <button type="button" className="ptab-close" onClick={(e) => { e.stopPropagation(); closeProject(tab.id) }} title="Close tab" aria-label={`Close project ${label}`}>
                  <Icon name="X" size={11} />
                </button>
              )}
            </div>
            {expanded && (
              <div
                id={`project-session-group-${tab.id}`}
                className="top-project-session-group"
                role="group"
                aria-label={`${label} sessions`}
                style={{ '--ptab-hue': tab.color ?? tab.hue } as CSSProperties}
              >
                <SessionTabs />
              </div>
            )}
            </Fragment>
          )
        })}
      </div>
      <NewProjectButton />
      <div className="tabstrip-fill" onDoubleClick={() => bridge.winCtl('zoom')} />
      <ViewControls />
      <ShellSidebarFooter topbar />
      {/* portalled to <body> — rendered in-strip it inherits a stacking context
          that loses to the session cards' glass layers and slides behind them */}
      {menu && createPortal(
        <>
          <button
            type="button"
            className="tree-menu-overlay"
            aria-label="Close project menu"
            onMouseDown={() => setMenu(null)}
            onContextMenu={(e) => { e.preventDefault(); setMenu(null) }}
            style={{ background: 'transparent', border: 'none', padding: 0 }}
          />
          <div
            className="tree-menu"
            style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 200), zIndex: 'calc(var(--z-palette) + 1)' }}
          >
            <button type="button"
              className="tree-menu-item"
              onClick={() => { const t = tabs.find((t) => t.id === menu.id); if (t) beginRename(t.id, tabLabel(t)); setMenu(null) }}
            >
              <Icon name="PenLine" size={13} /> Rename…
            </button>
            <div className="tree-menu-sep" />
            {/* Chrome-style color chips (GROUP_COLORS) + a reset-to-auto swatch */}
            <div style={{ display: 'flex', gap: 6, padding: '4px 10px', alignItems: 'center' }}>
              {GROUP_COLORS.map((c) => (
                <button type="button"
                  key={c}
                  title="Set tab color"
                  aria-label={`Set tab color to ${c}`}
                  onClick={() => { setProjectColor(menu.id, c); setMenu(null) }}
                  style={{ width: 14, height: 14, borderRadius: '50%', background: c, border: 'none', cursor: 'pointer', padding: 0 }}
                />
              ))}
              <button type="button"
                title="Auto color"
                aria-label="Use automatic tab color"
                onClick={() => { setProjectColor(menu.id, undefined); setMenu(null) }}
                style={{ width: 14, height: 14, borderRadius: '50%', background: 'transparent', border: '1px solid var(--border-strong)', cursor: 'pointer', padding: 0 }}
              />
            </div>
            <div className="tree-menu-sep" />
            <button type="button" className="tree-menu-item" onClick={() => { void detachProjectToWindow(menu.id); setMenu(null) }}>
              <Icon name="AppWindow" size={13} /> Move to new window
            </button>
            <button type="button" className="tree-menu-item" onClick={() => { closeProject(menu.id); setMenu(null) }}>
              <Icon name="X" size={13} /> Close tab
            </button>
            {tabs.length > 1 && (
              <button type="button" className="tree-menu-item" onClick={() => { closeOthers(menu.id); setMenu(null) }}>
                <Icon name="X" size={13} /> Close other tabs
              </button>
            )}
          </div>
        </>,
        document.body,
      )}
    </div>
  )
}

/**
 * Left navigation is a real two-level tree: projects are the stable parents;
 * the active project's sessions are their children. Selecting another parent
 * switches projects and expands it in one click, while its processes keep
 * running exactly as they do in Top mode.
 */
export function ProjectSessionSidebar() {
  const tabs = useKaisola((s) => s.projectTabs)
  const activeId = useKaisola((s) => s.activeProjectId)
  const tabStates = useProjectTabStates()
  const switchProject = useKaisola((s) => s.switchProject)
  const setProjectColor = useKaisola((s) => s.setProjectColor)
  const detachProjectToWindow = useKaisola((s) => s.detachProjectToWindow)
  const setTabLayout = useKaisola((s) => s.setTabLayout)
  const setSessionRailWidth = useKaisola((s) => s.setSessionRailWidth)
  const { editing, editValue, setEditValue, beginRename, commitRename, closeOthers, dragHandlers } = useProjectNav()
  const sessionCount = useKaisola((s) =>
    s.assistantThreads.reduce((count, thread) => count + (thread.groupParentId ? 0 : 1), 0)
      + s.terminals.length
      + s.agentTerminals.length
      + s.panels.length,
  )
  const [collapsed, setCollapsed] = useState(false)
  const [filter, setFilter] = useState('')
  const [menu, setMenu] = useState<{ x: number; y: number; id: string } | null>(null)

  useEffect(() => { setCollapsed(false); setFilter('') }, [activeId])
  useEffect(() => { if (sessionCount <= 20 && filter) setFilter('') }, [filter, sessionCount])

  const selectProject = (id: string) => {
    if (id === activeId) setCollapsed((value) => !value)
    else {
      setCollapsed(false)
      switchProject(id)
    }
  }
  const startResize = (event: ReactPointerEvent<HTMLDivElement>) => {
    event.preventDefault()
    const handle = event.currentTarget
    handle.setPointerCapture(event.pointerId)
    document.body.setAttribute('data-shell-drag', '1')
    const sidebar = handle.parentElement
    const startX = event.clientX
    const startWidth = sidebar?.getBoundingClientRect().width ?? 208
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
    <aside className="session-sidebar project-session-sidebar" aria-label="Projects and sessions">
      <div className="project-sidebar-titlebar">
        <WindowLights />
        <div className="project-sidebar-drag" onDoubleClick={() => bridge.winCtl('zoom')} />
        <button type="button" className="project-sidebar-layout" onClick={() => setTabLayout('bare')} title="Use Top layout" aria-label="Use Top navigation layout">
          <Icon name="PanelTop" size={13} />
        </button>
      </div>
      <div className="project-tree-head">
        <span>Projects</span>
        <NewProjectButton />
      </div>
      <div className="project-tree" role="tree" aria-label="Project and session tree">
        {tabs.map((tab, index) => {
          const active = tab.id === activeId
          const expanded = active && !collapsed
          const label = tabLabel(tab)
          const state = tabStates[index] || undefined
          return (
            <div
              key={tab.id}
              className="project-tree-node"
              data-project-id={tab.id}
              data-active={active || undefined}
              data-state={state}
              style={{ '--ptab-hue': tab.color ?? tab.hue } as CSSProperties}
              role="treeitem"
              aria-expanded={expanded}
              draggable={editing !== tab.id}
              {...dragHandlers(tab.id)}
            >
              <div className="project-tree-row" data-active={active || undefined}>
                <button type="button" className="project-tree-disclosure" onClick={() => selectProject(tab.id)} aria-label={`${expanded ? 'Collapse' : 'Expand'} ${label}`}>
                  <Icon name="ChevronRight" size={11} />
                </button>
                {editing === tab.id ? (
                  <input
                    className="project-tree-rename"
                    value={editValue}
                    autoFocus
                    aria-label="Project name"
                    onChange={(event) => setEditValue(event.target.value)}
                    onBlur={commitRename}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter') commitRename()
                      if (event.key === 'Escape') setEditing(null)
                    }}
                  />
                ) : (
                  <button
                    type="button"
                    className="project-tree-select"
                    aria-current={active ? 'page' : undefined}
                    onClick={() => selectProject(tab.id)}
                    onContextMenu={(event) => { event.preventDefault(); setMenu({ x: event.clientX, y: event.clientY, id: tab.id }) }}
                    title={tab.workspacePath ?? label}
                  >
                    <span className="project-tree-badge" />
                    <Icon name="Folder" size={13} />
                    <span className="truncate">{label}</span>
                  </button>
                )}
                <button type="button" className="project-tree-more" onClick={(event) => setMenu({ x: event.clientX, y: event.clientY, id: tab.id })} aria-label={`More actions for ${label}`} title="Project actions">
                  <Icon name="Ellipsis" size={13} />
                </button>
              </div>
              {expanded && (
                <div className="project-tree-children" role="group" aria-label={`${label} sessions`}>
                  {sessionCount > 20 && (
                    <label className="session-filter">
                      <Icon name="Search" size={12} />
                      <input value={filter} onChange={(event) => setFilter(event.target.value)} placeholder="Filter sessions" aria-label="Filter sessions" spellCheck={false} />
                      {filter && <button type="button" onClick={() => setFilter('')} aria-label="Clear session filter" title="Clear"><Icon name="X" size={11} /></button>}
                    </label>
                  )}
                  <SessionTabs orientation="vertical" filter={filter} />
                </div>
              )}
            </div>
          )
        })}
      </div>
      <div className="project-sidebar-bottom">
        <ViewControls />
        <ShellSidebarFooter />
      </div>
      <div
        className="session-sidebar-resize"
        onPointerDown={startResize}
        onDoubleClick={() => setSessionRailWidth(null)}
        onKeyDown={(event) => {
          if (event.key === 'Home') { event.preventDefault(); setSessionRailWidth(null); return }
          if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
          event.preventDefault()
          const current = event.currentTarget.parentElement?.getBoundingClientRect().width ?? 208
          setSessionRailWidth(current + (event.key === 'ArrowLeft' ? -20 : 20))
        }}
        role="separator"
        aria-label="Resize navigation sidebar"
        aria-orientation="vertical"
        tabIndex={0}
        title="Drag to resize navigation · double-click to reset"
      />
      {menu && createPortal(
        <>
          <button type="button" className="tree-menu-overlay" aria-label="Close project menu" onMouseDown={() => setMenu(null)} style={{ background: 'transparent', border: 'none', padding: 0 }} />
          <div className="tree-menu" style={{ left: Math.min(menu.x, window.innerWidth - 220), top: Math.min(menu.y, window.innerHeight - 240), zIndex: 'calc(var(--z-palette) + 1)' }}>
            <button type="button" className="tree-menu-item" onClick={() => { const tab = tabs.find((candidate) => candidate.id === menu.id); if (tab) beginRename(tab.id, tabLabel(tab)); setMenu(null) }}>
              <Icon name="PenLine" size={13} /> Rename…
            </button>
            <div className="tree-menu-sep" />
            <div className="project-color-menu">
              {GROUP_COLORS.map((color) => <button type="button" key={color} title="Set project color" aria-label={`Set project color to ${color}`} onClick={() => { setProjectColor(menu.id, color); setMenu(null) }} style={{ background: color }} />)}
              <button type="button" className="project-color-auto" title="Automatic project color" aria-label="Use automatic project color" onClick={() => { setProjectColor(menu.id, undefined); setMenu(null) }} />
            </div>
            <div className="tree-menu-sep" />
            <button type="button" className="tree-menu-item" onClick={() => { void detachProjectToWindow(menu.id); setMenu(null) }}><Icon name="AppWindow" size={13} /> Move to new window</button>
            <button type="button" className="tree-menu-item" onClick={() => { closeProject(menu.id); setMenu(null) }}><Icon name="X" size={13} /> Close project</button>
            {tabs.length > 1 && <button type="button" className="tree-menu-item" onClick={() => { closeOthers(menu.id); setMenu(null) }}><Icon name="X" size={13} /> Close other projects</button>}
          </div>
        </>,
        document.body,
      )}
    </aside>
  )
}

type PanelViewTransition = {
  finished: Promise<unknown>
  skipTransition?: () => void
}
type ViewTransitionDocument = Document & {
  startViewTransition?: (update: () => void) => PanelViewTransition
}
let activePanelTransition: PanelViewTransition | null = null

const runViewTransition = (kind: string, update: () => void) => {
  const doc = document as ViewTransitionDocument
  const reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
  if (!doc.startViewTransition || reduced) {
    update()
    return
  }
  // Panel buttons are intentionally fast to click. Chromium can still be
  // animating the previous tree/preview transition when the inverse action
  // arrives; finish that paint immediately so the newer state change is never
  // dropped behind an in-flight snapshot.
  if (activePanelTransition) {
    activePanelTransition.skipTransition?.()
    activePanelTransition = null
    delete document.documentElement.dataset.panelTransition
    update()
    return
  }
  document.documentElement.dataset.panelTransition = kind
  let updated = false
  const applyOnce = () => {
    if (updated) return
    updated = true
    update()
  }
  let view: PanelViewTransition
  try {
    view = doc.startViewTransition(applyOnce)
    activePanelTransition = view
  } catch {
    applyOnce()
    delete document.documentElement.dataset.panelTransition
    return
  }
  const clearTransition = () => {
    if (activePanelTransition === view) activePanelTransition = null
    if (document.documentElement.dataset.panelTransition === kind) delete document.documentElement.dataset.panelTransition
  }
  // A superseding navigation can reject `finished`; cleanup should be the
  // same in either case and must not leave an unhandled promise behind.
  void view.finished.then(clearTransition, clearTransition)
}

const togglePreview = () => runViewTransition('preview-right', () => useKaisola.getState().toggleCanvas())

/**
 * The project tree and document canvas stay addressable in one stable place.
 * View Transitions animate entry and exit without keeping a hidden editor or
 * terminal subtree mounted just for an exit animation.
 */
export function ViewControls() {
  const layoutMode = useKaisola((s) => s.layoutMode)
  const tabLayout = useKaisola((s) => s.tabLayout)
  const railOpen = useKaisola((s) => s.railOpen)
  const canvasOpen = useKaisola((s) => s.canvasOpen)
  const treeVisible = layoutMode === 'studio' && railOpen
  const previewVisible = layoutMode === 'focus' || canvasOpen

  const toggleTree = () => runViewTransition(tabLayout === 'sidebar' ? 'tree-right' : 'tree-left', () => {
    const state = useKaisola.getState()
    if (state.layoutMode !== 'studio') {
      state.setLayoutMode('studio')
      if (!state.railOpen) state.toggleRail()
      return
    }
    state.toggleRail()
  })
  return (
    <div className="tabstrip-view-controls" role="group" aria-label="Workspace panels">
      <button type="button"
        data-active={previewVisible || undefined}
        aria-pressed={previewVisible}
        aria-label={previewVisible ? 'Hide file preview' : 'Show file preview'}
        title={`${previewVisible ? 'Hide' : 'Show'} file preview  ⌘.`}
        onClick={togglePreview}
      >
        <Icon name="FileText" size={15} />
      </button>
      <button type="button"
        data-active={treeVisible || undefined}
        aria-pressed={treeVisible}
        aria-label={treeVisible ? 'Hide file tree' : 'Show file tree'}
        title={`${treeVisible ? 'Hide' : 'Show'} file tree  ⌘B`}
        onClick={toggleTree}
      >
        <Icon name="FolderTree" size={15} />
      </button>
    </div>
  )
}

/**
 * The "+" launcher menu — a Dropdown of recently opened folders, an "Open
 * folder…" picker, and the recently-closed undo list. Kept in its own
 * component so its recents/closed subscriptions don't storm the strip.
 */
export function NewProjectButton() {
  const recentProjects = useKaisola((s) => s.recentProjects)
  const closedProjectStack = useKaisola((s) => s.closedProjectStack)
  const newProject = useKaisola((s) => s.newProject)
  const openProjectFolder = useKaisola((s) => s.openProjectFolder)
  const reopenClosedProject = useKaisola((s) => s.reopenClosedProject)
  const pushToast = useKaisola((s) => s.pushToast)

  const pickFolder = async () => {
    const r = await bridge.pickFolder()
    if (r.ok && r.path) openProjectFolder(r.path)
    else if (r.message) pushToast('warn', r.message)
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
      <button type="button" className="tabstrip-new-btn" onClick={() => newProject({ path: null, focus: true })} title="New tab  ⌘T" aria-label="New project tab">
        <Icon name="Plus" size={14} />
      </button>
      <Dropdown value="" placeholder="" options={options} onSelect={onSelect} title="Open a project…" align="left" />
      <span className="new-project-saved-slot" data-saved-windows-host="active" />
      <SavedWindows hostSelector="[data-saved-windows-host='active']" />
    </div>
  )
}
