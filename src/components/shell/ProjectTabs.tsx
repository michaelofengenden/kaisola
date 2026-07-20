import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { useShallow } from 'zustand/react/shallow'
import { useKaisola, GROUP_COLORS } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { useUpdateState } from '../../lib/updates'
import { Icon } from '../Icon'
import { Dropdown, type DropOption } from '../Dropdown'
import { WindowLights } from './WindowLights'
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
  // ONE shallow-compared array of derived states, not raw slice/meta
  // subscriptions: projectSlices and terminalMeta change identity on every
  // feed line and pty tick, which re-rendered the whole strip during streams.
  const tabStates = useKaisola(
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
      <div className="tabstrip-track" role="tablist" ref={trackRef} onScroll={syncFade}>
        {tabs.map((tab, i) => {
          const active = tab.id === activeId
          const label = tabLabel(tab)
          const loneEmpty = tabs.length === 1 && !tab.workspacePath
          const state = tabStates[i] || undefined
          return (
            <div
              key={tab.id}
              ref={active ? activeRef : undefined}
              className="ptab"
              data-project-id={tab.id}
              data-active={active}
              data-state={state}
              style={{ '--ptab-hue': tab.color ?? tab.hue } as CSSProperties}
              draggable={editing !== tab.id}
              onDragStart={(event) => {
                dragRef.current = tab.id
                event.dataTransfer.effectAllowed = 'move'
                event.dataTransfer.setData('text/plain', tab.id)
              }}
              onDragOver={(event) => {
                event.preventDefault()
                event.dataTransfer.dropEffect = 'move'
              }}
              onDrop={() => { if (dragRef.current) reorderProjects(dragRef.current, tab.id); dragRef.current = null }}
              onDragEnd={(e) => {
                // Dropped outside THIS window: main hit-tests other Kaisola tab
                // strips first (recombine), otherwise creates a tear-off there.
                const out = e.clientX < -8 || e.clientY < -8 || e.clientX > window.innerWidth + 8 || e.clientY > window.innerHeight + 8
                if (out && dragRef.current === tab.id) void detachProjectToWindow(tab.id, { x: e.screenX, y: e.screenY })
                dragRef.current = null
              }}
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
                    onClick={() => switchProject(tab.id)}
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
                    onDoubleClick={() => beginRename(tab.id, label)}
                  />
                  <span className="ptab-content" aria-hidden="true">
                    <span className="ptab-badge" />
                    <Icon name="Folder" size={13} className="ptab-icon" />
                    <span className="ptab-label truncate">{label}</span>
                  </span>
                </>
              )}
              {!loneEmpty && (
                <button type="button" className="ptab-close" onClick={(e) => { e.stopPropagation(); closeProject(tab.id) }} title="Close tab" aria-label={`Close project ${label}`}>
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
      <ViewControls />
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
function ViewControls() {
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
    <button type="button"
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
    </div>
  )
}
