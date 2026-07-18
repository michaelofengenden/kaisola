import { useEffect, useRef, type CSSProperties, type MouseEvent as ReactMouseEvent } from 'react'
import { useKaisola, sessionOrderIds, projectIdForEvent, terminalOwnerMap, POP_TERMINAL_ID, type AgentFeedItem, type ProjectTab, type ProjectTransferPayload } from './store/store'
import { bridge, isDesktop, type PopClosedTerminalState, type TerminalMirrorState } from './lib/bridge'
import { uid, nowISO } from './domain/ids'
import { requestIsSensitive, requestMatchesRules, allowOnceAnswer } from './lib/permissionRules'
import { OmniBar } from './components/shell/OmniBar'
import { loadUserConfig, watchUserConfig } from './lib/userConfig'
import { initGlassWash } from './lib/glassWash'
import { CompanionProjectionRevisions } from './lib/companionProjection'
import { ShellTools } from './components/shell/AgentSidebar'
import { WorkspaceRail } from './components/shell/WorkspaceRail'
import { ProjectTabs } from './components/shell/ProjectTabs'
import { SavedWindows } from './components/shell/SavedWindows'
import { ProjectLauncher } from './components/shell/ProjectLauncher'
import { CommandPalette } from './components/shell/CommandPalette'
import { SessionCards } from './components/shell/SessionCards'
import { shellDrag } from './components/shell/shellDrag'
import { SessionSidebar } from './components/shell/SessionTabs'
import { ProvenancePopover } from './components/Provenance'
import { ReviewFocus } from './components/ReviewFocus'
import { McpInstallModal } from './components/shell/McpInstallModal'
import { Settings } from './components/Settings'
import { SignInCard } from './components/SignInCard'
import { Toaster } from './components/Toaster'
import { ExtensionsCenter } from './components/ExtensionsCenter'
import { Onboarding } from './components/Onboarding'
import { Icon } from './components/Icon'
import { ShellSidebarFooter } from './components/shell/ShellSidebarFooter'

import { FilesView } from './views/FilesView'

function StageView() {
  const workspacePath = useKaisola((s) => s.workspacePath)
  // no folder bound to this tab yet → the launcher (recents · open · drop hint)
  if (!workspacePath) return <ProjectLauncher />
  return <FilesView />
}

/** A 2px accent beam under the top bar whenever any agent work is in flight. */
function TopProgress() {
  const queueRunning = useKaisola((s) => s.agentQueueRunning)
  const agentRunning = useKaisola((s) => s.agentRunning)
  const active = queueRunning || Object.values(agentRunning).some(Boolean)
  if (!active) return null
  return <div className="top-progress" aria-hidden="true" />
}

// ── keybindings: one table, rebindable from keymap.json ─────────────────────
// Actions are stable ids the user can reference; DEFAULTS are the shipped
// chords. keymap.json entries override (or `null`-disable) chords at load.
const KEY_ACTIONS: Record<string, () => void> = {
  'dock.toggle': () => useKaisola.getState().toggleDock(),
  'canvas.toggle': () => useKaisola.getState().toggleCanvas(),
  'layout.toggle': () => useKaisola.getState().toggleLayoutMode(),
  'settings.open': () => useKaisola.getState().setSettingsOpen(true),
  'window.new': () => { void bridge.windows?.newWindow() },
  'omni.toggle': () => useKaisola.getState().setOmniOpen(!useKaisola.getState().omniOpen),
  'session.next': () => useKaisola.getState().cycleSession(1),
  'session.prev': () => useKaisola.getState().cycleSession(-1),
  'session.reopen': () => useKaisola.getState().reopenClosedSession(),
  'terminal.new': () => useKaisola.getState().requestTerminal(undefined, { cwd: useKaisola.getState().workspacePath ?? undefined }),
  'git.panel': () => useKaisola.getState().openGitPanel(),
  'browser.new': () => useKaisola.getState().openBrowserPanel(),
  'latex.toggle': () => useKaisola.getState().setLatexMode(!useKaisola.getState().latexMode),
  'rail.toggle': () => useKaisola.getState().toggleRail(),
  // project tabs (mirrors the native File/Window menu, which owns these chords
  // as accelerators on desktop; this keymap is the path on web / rebinds)
  'project.new': () => { useKaisola.getState().newProject({ path: null, focus: true }) },
  'project.next': () => useKaisola.getState().cycleProject(1),
  'project.prev': () => useKaisola.getState().cycleProject(-1),
  'project.reopen': () => useKaisola.getState().reopenClosedProject(),
}
for (let n = 1; n <= 9; n++) {
  KEY_ACTIONS[`session.${n}`] = () => {
    const s = useKaisola.getState()
    const target = sessionOrderIds(s)[n - 1]
    if (target) s.switchSession(target)
  }
  KEY_ACTIONS[`project.${n}`] = () => {
    const s = useKaisola.getState()
    const tab = s.projectTabs[n - 1]
    if (tab) s.switchProject(tab.id)
  }
}
const DEFAULT_KEYMAP: Record<string, string> = {
  'cmd-j': 'dock.toggle',
  'cmd-.': 'canvas.toggle',
  'cmd-shift-f': 'layout.toggle',
  'cmd-,': 'settings.open',
  'cmd-shift-n': 'window.new',
  'cmd-l': 'omni.toggle',
  'cmd-b': 'rail.toggle',
  'ctrl-tab': 'session.next',
  'ctrl-shift-tab': 'session.prev',
  'cmd-shift-t': 'session.reopen',
  'cmd-t': 'project.new',
  // Shift maps ] → } and [ → { in KeyboardEvent.key on most layouts, so bind
  // both glyphs (the physical bracket key is what the user presses either way)
  'cmd-shift-]': 'project.next',
  'cmd-shift-}': 'project.next',
  'cmd-shift-[': 'project.prev',
  'cmd-shift-{': 'project.prev',
  'cmd-alt-t': 'project.reopen',
}
for (let n = 1; n <= 9; n++) {
  DEFAULT_KEYMAP[`cmd-${n}`] = `session.${n}`
  DEFAULT_KEYMAP[`cmd-alt-${n}`] = `project.${n}`
}

/** Normalize a KeyboardEvent to the chord grammar keymap.json uses. */
function chordOf(e: KeyboardEvent): string {
  const parts: string[] = []
  if (e.metaKey) parts.push('cmd')
  if (e.ctrlKey) parts.push('ctrl')
  if (e.altKey) parts.push('alt')
  if (e.shiftKey) parts.push('shift')
  parts.push(e.key.toLowerCase())
  return parts.join('-')
}

function useKeybindings() {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!e.metaKey && !e.ctrlKey) return
      const chord = chordOf(e)
      const overrides = useKaisola.getState().keymapOverrides
      const actionId = chord in overrides ? overrides[chord] : DEFAULT_KEYMAP[chord]
      if (!actionId) return // unbound, or disabled via null in keymap.json
      const action = KEY_ACTIONS[actionId]
      if (!action) return
      e.preventDefault()
      action()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])
}

/** POSIX single-quote escaping for the auto-launch boot line. */
const shq = (s: string) => `'${s.replace(/'/g, "'\\''")}'`

// ── project-aware event routing helpers ─────────────────────────────────────
// Background agents (a run started in tab A while you're looking at tab B) must
// write to their OWNING project's slice — never the active one (spec risk #3).
type Badge = ProjectTab['activity']

/** The label the native title/menu shows for a tab (folder basename, or a
 * manual rename, else "New Project"). */
const projectLabel = (t: { title?: string; workspacePath: string | null }) =>
  t.title ?? (t.workspacePath ? t.workspacePath.split('/').filter(Boolean).pop() ?? 'New Project' : 'New Project')

/** Append an activity-feed line to a project: straight to the live fields when
 * it's active, else into its parked slice (optionally raising a tab badge). */
function pushProjectFeed(pid: string, isActive: boolean, item: Omit<AgentFeedItem, 'id'>, badge?: Badge) {
  const st = useKaisola.getState()
  if (isActive) st.pushAgentFeed(item)
  else st.patchProject(pid, (sl) => ({ agentFeed: [{ ...item, id: uid('feed') }, ...sl.agentFeed].slice(0, 60) }), badge)
}

// ── native agent notifications ───────────────────────────────────────────────
// Fired only when the user is NOT looking (background tab, or the window is
// unfocused/hidden). Click focuses the window and switches to the owning tab.
// Deduped per project within a short window so a chatty turn doesn't stack
// notification banners.
const lastNotifyAt = new Map<string, number>()
function notifyAgent(
  title: string,
  body: string,
  pid: string,
  sessionId?: string,
  event?: { sourceId?: string; kind?: 'permission' | 'question' | 'review' | 'blocked' | 'failed' | 'completed'; createdAt?: number },
) {
  if (bridge.smoke) return
  const now = Date.now()
  const key = `${pid}\0${sessionId ?? ''}`
  if (now - (lastNotifyAt.get(key) ?? 0) < 15_000) return
  lastNotifyAt.set(key, now)
  if (bridge.attention) {
    bridge.attention.notify({ title, body, projectId: pid, sessionId, ...event })
    return
  }
  if (typeof Notification === 'undefined') return
  try {
    const n = new Notification(title, { body, silent: true })
    n.onclick = () => {
      window.focus()
      const st = useKaisola.getState()
      if (st.projectTabs.some((t) => t.id === pid)) st.switchProject(pid)
    }
  } catch { /* notifications denied/unavailable — the tab badge still shows */ }
}

/** Keep the native dock badge equal to unread session/permission work across
 * every project in this window. Regaining focus acknowledges only sessions
 * that are actually visible; hidden tabs keep their still completion dot. */
function AttentionSync() {
  const unreadCount = useKaisola((state) => {
    const count = (slice: Pick<typeof state, 'needsYou' | 'pendingPermissions'> | undefined) =>
      slice ? Object.keys(slice.needsYou).length + slice.pendingPermissions.length : 0
    return count(state) + Object.values(state.projectSlices).reduce((sum, slice) => sum + count(slice), 0)
  })
  const visibleUnread = useKaisola((state) => state.dockViews.filter((id) => state.needsYou[id]).join('\0'))
  const surface = useKaisola((state) => JSON.stringify({
    projectId: state.activeProjectId,
    visibleSessionIds: state.dockOpen ? state.dockViews : [],
    projects: state.projectTabs.map((tab) => ({
      projectId: tab.id,
      alias: (tab.id === state.activeProjectId ? state.workspacePath : state.projectSlices[tab.id]?.workspacePath) ?? undefined,
    })),
  }))

  useEffect(() => {
    bridge.attention?.setCount(unreadCount)
  }, [unreadCount])

  useEffect(() => {
    const clearSessionAttention = (projectId: string, sessionId: string) => {
      const state = useKaisola.getState()
      const owner = projectId === state.activeProjectId ? state : state.projectSlices[projectId]
      if (!owner?.needsYou[sessionId]) return
      const remaining = Object.keys(owner.needsYou).filter((id) => id !== sessionId)
      state.patchProject(projectId, (slice) => {
        const needsYou = { ...slice.needsYou }
        delete needsYou[sessionId]
        return { needsYou }
      })
      if (remaining.length === 0) state.setProjectActivity(projectId, undefined)
    }
    const acknowledgeVisible = () => {
      if (document.hidden || !document.hasFocus()) return
      const state = useKaisola.getState()
      for (const id of state.dockViews) {
        if (state.needsYou[id]) state.setDockView(id)
      }
    }
    const off = bridge.attention?.onOpen(({ eventId, projectId, sessionId }) => {
      const state = useKaisola.getState()
      if (eventId && projectId) void bridge.attention?.acknowledge({ projectId, eventId })
      if (projectId && state.projectTabs.some((tab) => tab.id === projectId)) state.switchProject(projectId)
      if (sessionId) useKaisola.getState().switchSession(sessionId)
      acknowledgeVisible()
    })
    const offRaised = bridge.attention?.onRaised(({ projectId, sessionId, kind }) => {
      if (!sessionId) return
      const state = useKaisola.getState()
      if (!state.projectTabs.some((tab) => tab.id === projectId)) return
      state.markNeedsYou(sessionId, projectId)
      if (projectId !== state.activeProjectId) state.setProjectActivity(projectId, kind === 'failed' ? 'failed' : 'needs-you')
    })
    const offCleared = bridge.attention?.onCleared(({ projectId, sessionId }) => {
      if (sessionId) clearSessionAttention(projectId, sessionId)
    })
    window.addEventListener('focus', acknowledgeVisible)
    document.addEventListener('visibilitychange', acknowledgeVisible)
    acknowledgeVisible()
    return () => {
      off?.()
      offRaised?.()
      offCleared?.()
      window.removeEventListener('focus', acknowledgeVisible)
      document.removeEventListener('visibilitychange', acknowledgeVisible)
      bridge.attention?.setCount(0)
    }
  }, [])

  useEffect(() => {
    const base = JSON.parse(surface) as {
      projectId: string
      visibleSessionIds: string[]
      projects: Array<{ projectId: string; alias?: string }>
    }
    const sync = () => bridge.attention?.syncSurface({
      ...base,
      documentVisible: !document.hidden,
      documentFocused: document.hasFocus(),
    })
    window.addEventListener('focus', sync)
    window.addEventListener('blur', sync)
    document.addEventListener('visibilitychange', sync)
    sync()
    return () => {
      window.removeEventListener('focus', sync)
      window.removeEventListener('blur', sync)
      document.removeEventListener('visibilitychange', sync)
    }
  }, [surface])

  useEffect(() => {
    if (!visibleUnread || document.hidden || !document.hasFocus()) return
    const state = useKaisola.getState()
    for (const id of visibleUnread.split('\0')) state.setDockView(id)
  }, [visibleUnread])
  return null
}

/** Publish only meaningful, normalized display changes. Main validates and
 * persists again; pagehide synchronously flushes a pending final revision. */
function CompanionProjectionSync() {
  useEffect(() => {
    const revisions = new CompanionProjectionRevisions()
    let timer: number | null = null

    const changedProjection = () => revisions.next(useKaisola.getState(), Date.now())
    const publishChanged = () => {
      timer = null
      try {
        const projection = changedProjection()
        if (projection) bridge.companion.publishProjection(projection)
      } catch { /* malformed legacy state stays local and cannot break the UI */ }
    }
    const schedule = () => {
      if (timer != null) return
      timer = window.setTimeout(publishChanged, 120)
    }
    const flushForPagehide = () => {
      if (timer != null) window.clearTimeout(timer)
      timer = null
      try {
        const projection = changedProjection() ?? revisions.current()
        if (projection) bridge.companion.publishProjection(projection, true)
      } catch { /* fail closed; the prior persisted projection remains stale-safe */ }
    }

    const unsubscribe = useKaisola.subscribe(schedule)
    window.addEventListener('pagehide', flushForPagehide)
    publishChanged()
    return () => {
      flushForPagehide()
      unsubscribe()
      window.removeEventListener('pagehide', flushForPagehide)
    }
  }, [])
  return null
}

/** A turn-start checkpoint for a BACKGROUND project (the active project uses the
 * store's `snapshotWorkspace`, which is pinned to `activeProjectId`). */
async function snapshotBackground(pid: string, ws: string | null, label: string) {
  if (!ws || !isDesktop) return
  const r = await bridge.git.snapshot(ws, label)
  if (!r.ok || !r.sha) return
  const sha = r.sha // capture: property narrowing doesn't survive the closure below
  const head = useKaisola.getState().projectSlices[pid]?.repoCheckpoints[0]
  if (head?.sha === sha) return // an unchanged tree re-snapshots to the same sha
  useKaisola.getState().patchProject(pid, (sl) => ({
    repoCheckpoints: [{ id: uid('ckpt'), sha, label, at: nowISO() }, ...sl.repoCheckpoints].slice(0, 40),
  }))
}

/** Mirror the tab strip into the native window title + Window-menu tab list on
 * any change. Isolated so it subscribes ONLY to the tab meta (storm-safe). */
function TabMenuSync() {
  const tabs = useKaisola((s) => s.projectTabs)
  const activeId = useKaisola((s) => s.activeProjectId)
  useEffect(() => {
    if (!isDesktop) return
    bridge.windows?.tabsChanged?.(tabs.map((t) => ({ id: t.id, title: projectLabel(t), active: t.id === activeId })))
    const active = tabs.find((t) => t.id === activeId)
    // a lone unnamed launcher tab → empty title so main shows just the app name
    bridge.windows?.setTitle?.(active && (active.title || active.workspacePath) ? projectLabel(active) : '')
  }, [tabs, activeId])
  return null
}

const WINDOW_DELETE_GROUP_PHASES = new Set(['answering', 'negotiating', 'assigning', 'executing', 'reviewing', 'integrating', 'critiquing', 'synthesizing'])

const windowStoreKeys = () => {
  const slot = new URLSearchParams(location.search).get('win')
  const suffix = slot ? `-w${slot}` : ''
  return [`kaisola-store${suffix}`, `kiasola-store${suffix}`, `pasola-store${suffix}`]
}

function windowDeletionBlocker() {
  const state = useKaisola.getState()
  for (const tab of state.projectTabs) {
    const slice = tab.id === state.activeProjectId ? state : state.projectSlices[tab.id]
    if (!slice) continue
    if (slice.pendingPermissions.length > 0) return 'Resolve pending agent approvals before deleting this window.'
    if (slice.assistantThreads.some((thread) => thread.busy || !!thread.group?.operation || (!!thread.group && !thread.group.paused && WINDOW_DELETE_GROUP_PHASES.has(thread.group.phase)))) {
      return 'Stop active agent turns before deleting this window.'
    }
    if (Object.values(slice.assistantPromptQueues).some((queue) => queue.length > 0) || slice.agentQueueRunning || Object.values(slice.agentRunning).some(Boolean)) {
      return 'Finish or clear queued agent work before deleting this window.'
    }
    const terminalIds = [
      ...slice.terminals.map((terminal) => terminal.id),
      ...slice.agentTerminals.map((terminal) => terminal.terminalId),
    ]
    if (terminalIds.some((id) => state.terminalMeta[id]?.agentBusy) || slice.agentTerminals.some((terminal) => state.terminalMeta[terminal.terminalId]?.running)) {
      return 'Stop active terminal agents before deleting this window.'
    }
  }
  if (state.fileDirty || Object.keys(state.unsavedBuffers).length > 0) return 'Save or discard unsaved file edits before deleting this window.'
  return null
}

async function prepareWindowDeletion() {
  const blocker = windowDeletionBlocker()
  if (blocker) return { ok: false, message: blocker }
  const before = useKaisola.getState()
  const projectIds = before.projectTabs.map((tab) => tab.id)
  const terminals = projectIds.flatMap((projectId) => {
    const slice = projectId === before.activeProjectId ? before : before.projectSlices[projectId]
    if (!slice) return []
    return [
      ...slice.terminals.map((terminal) => ({ id: terminal.id, projectId })),
      ...slice.agentTerminals.map((terminal) => ({ id: terminal.terminalId, projectId })),
    ]
  })
  const connections = projectIds.flatMap((projectId) => {
    const slice = projectId === before.activeProjectId ? before : before.projectSlices[projectId]
    return (slice?.assistantThreads ?? []).map((thread) => ({ key: `${thread.agentKey}::${thread.id}`, projectId }))
  })
  document.body.inert = true
  const disconnected = await Promise.all(connections.map(({ key, projectId }) =>
    bridge.acp.disconnect(key, projectId).catch(() => ({ ok: false }))))
  if (disconnected.some((result) => !result.ok)) {
    document.body.inert = false
    return { ok: false, message: 'An agent session could not be disconnected safely.' }
  }
  try {
    for (const projectId of projectIds) {
      const current = useKaisola.getState()
      const slice = projectId === current.activeProjectId ? current : current.projectSlices[projectId]
      if (!slice) continue
      const roots = slice.assistantThreads.filter((thread) => !thread.groupParentId)
      for (const thread of roots) useKaisola.getState().closeAssistantThread(thread.id, projectId)
      // Malformed legacy state can contain an orphaned group child. Close any
      // residue through the same action rather than leaving it mounted.
      const remaining = projectId === useKaisola.getState().activeProjectId
        ? useKaisola.getState().assistantThreads
        : useKaisola.getState().projectSlices[projectId]?.assistantThreads ?? []
      for (const thread of remaining) useKaisola.getState().closeAssistantThread(thread.id, projectId)
      useKaisola.getState().closeProject(projectId, { force: true })
    }
    try { window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: false })) } catch { window.dispatchEvent(new Event('pagehide')) }
    for (const key of windowStoreKeys()) localStorage.removeItem(key)
    return { ok: true, projectIds }
  } catch {
    useKaisola.setState(before, true)
    for (const terminal of terminals) void bridge.terminal.cancelRelease(terminal.id, terminal.projectId).catch(() => {})
    try { window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: false })) } catch { window.dispatchEvent(new Event('pagehide')) }
    document.body.inert = false
    return { ok: false, message: 'Kaisola restored the window because renderer teardown did not complete.' }
  }
}

function registerWindowDeletionHandler() {
  if (!bridge.windows?.onPrepareDelete) return undefined
  let migrationFailed = false
  // Old installs can still have their only session blob in localStorage. Main
  // cannot read renderer storage, so migrate that exact blob synchronously
  // before the readiness signal; main then backs it up before teardown.
  for (const key of windowStoreKeys()) {
    try {
      const fallback = localStorage.getItem(key)
      if (fallback == null || bridge.db.getSync(key) != null) continue
      if (!bridge.db.setSync(key, fallback)) migrationFailed = true
    } catch {
      migrationFailed = true
    }
  }
  return bridge.windows.onPrepareDelete(migrationFailed
    ? async () => ({ ok: false, message: 'Kaisola could not secure the legacy saved session, so deletion was cancelled.' })
    : prepareWindowDeletion)
}

function KaisolaApp() {
  const layoutMode = useKaisola((s) => s.layoutMode)
  const stage = useKaisola((s) => s.stage)
  const setStage = useKaisola((s) => s.setStage)
  const dockOpen = useKaisola((s) => s.dockOpen)
  const canvasOpen = useKaisola((s) => s.canvasOpen)
  const canvasWidth = useKaisola((s) => s.canvasWidth)
  const setCanvasWidth = useKaisola((s) => s.setCanvasWidth)
  const railWidth = useKaisola((s) => s.railWidth)
  const sessionRailWidth = useKaisola((s) => s.sessionRailWidth)
  const railOpen = useKaisola((s) => s.railOpen)
  const tabLayout = useKaisola((s) => s.tabLayout)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const activeProjectId = useKaisola((s) => s.activeProjectId)
  // per-project arming (spec risk #5): a single boolean would arm Claude once
  // for the whole app and never in the second project — key by tab+workspace
  useKeybindings()

  // Explicit window deletion is a two-process transaction. Main performs the
  // authoritative ACP safety check; the renderer repeats the project-level
  // checks, disconnects idle sessions, uses the existing close actions to
  // release project resources, and forces the normal pagehide durability
  // barrier before ACKing. Main destroys this renderer before deleting DB rows.
  useEffect(() => {
    if (!isDesktop || POP_TERMINAL_ID) return
    return registerWindowDeletionHandler()
  }, [])

  // when the ACP agent runs a command it spawns a real pty — list it as a
  // session in the OWNING project's rail (a background run docks in its slice,
  // never the active tab), focused live so you can watch and take over.
  useEffect(
    () =>
      bridge.acp.onTerminal((info) => {
        const st = useKaisola.getState()
        const pid = info.scope || projectIdForEvent(st, { agentKey: info.agentKey, cwd: info.cwd })
        if (pid === st.activeProjectId) { st.addAgentTerminal(info); return }
        st.patchProject(
          pid,
          (sl) => {
            if (sl.agentTerminals.some((x) => x.terminalId === info.terminalId)) return {}
            const grid = sl.dockViews.includes(info.terminalId) ? sl.dockGrid : [...sl.dockGrid, [info.terminalId]]
            return { agentTerminals: [...sl.agentTerminals, info], dockGrid: grid, dockViews: grid.flat(), dockOpen: true }
          },
          'running',
        )
      }),
    [],
  )

  // a pop-out window closed — its terminal card comes home (remount re-attaches
  // the pty stream and replays the scrollback snapshot)
  useEffect(() => {
    let alive = true
    const closedDuringSync = new Set<string>()
    const handledClosedRevisions = new Map<string, number>()
    const applyTerminalMirror = (mirror: TerminalMirrorState) => {
      const state = useKaisola.getState()
      if (terminalOwnerMap(state)[mirror.termId] !== mirror.projectId) return
      if (mirror.meta) state.setTerminalMeta(mirror.termId, mirror.meta)
      if (Object.prototype.hasOwnProperty.call(mirror, 'draft')) state.setTermDraft(mirror.termId, mirror.draft ?? '')
      if (typeof mirror.resume === 'string') state.setTerminalResume(mirror.termId, mirror.resume)
      if (typeof mirror.promptTitle === 'string') state.autoNameTerminal(mirror.termId, mirror.promptTitle, mirror.projectId)
    }
    const acceptClosedPop = (closed: PopClosedTerminalState) => {
      if (!closed || typeof closed.termId !== 'string' || typeof closed.projectId !== 'string' || !Number.isSafeInteger(closed.revision)) return
      closedDuringSync.add(closed.termId)
      const revisionKey = `${closed.projectId}\0${closed.termId}`
      const owner = terminalOwnerMap(useKaisola.getState())[closed.termId]
      // A tab registration can precede rehydration of its terminal row. Do not
      // ACK away the only retained draft/resume snapshot until the exact terminal
      // capability is present; tabs:changed/reopen will replay it later.
      if (owner !== closed.projectId) return
      if (handledClosedRevisions.get(revisionKey) !== closed.revision) {
        handledClosedRevisions.set(revisionKey, closed.revision)
        applyTerminalMirror(closed)
        useKaisola.getState().restorePoppedTerminal(closed.termId)
      }
      // Main validates the live sender's tab capability plus this exact project
      // and revision before dropping its retained handoff. Repeated delivery is
      // intentional when a tabs registration races the first ACK.
      void bridge.windows?.ackPopClosed?.(closed.termId, closed.projectId, closed.revision).catch(() => {})
    }
    const off = bridge.windows?.onPopClosed?.(acceptClosedPop)
    void bridge.windows?.popped?.().then((result) => {
      if (!alive || !result.ok) return
      useKaisola.getState().syncPoppedTerminals((result.termIds ?? []).filter((id) => !closedDuringSync.has(id)))
      for (const state of result.states ?? []) applyTerminalMirror(state)
      for (const closed of result.closed ?? []) acceptClosedPop(closed)
    }).catch(() => {})
    const offState = bridge.windows?.onTerminalState?.(applyTerminalMirror)
    return () => { alive = false; off?.(); offState?.() }
  }, [])

  // native File/Window menu → store actions (⌘T new tab, ⌘W close active tab,
  // ⌘⌥T reopen, Window-menu tab click → activate). Menu accelerators fire
  // before the page, so ⌘W closes the active TAB, never the window.
  useEffect(() => {
    if (!isDesktop) return
    const w = bridge.windows
    const offs = [
      w?.onNewTab?.(() => { useKaisola.getState().newProject({ path: null, focus: true }) }),
      w?.onCloseTab?.(() => { const s = useKaisola.getState(); s.closeProject(s.activeProjectId) }),
      w?.onReopenTab?.(() => useKaisola.getState().reopenClosedProject()),
      w?.onActivateTab?.((id) => useKaisola.getState().switchProject(id)),
      // Chrome-style transfer: insert at the cursor's tab-strip position, apply
      // atomically, then ACK. The source keeps its copy until this succeeds.
      w?.onAdoptProject?.((raw) => {
        const payload = raw as ProjectTransferPayload
        let beforeId: string | undefined
        if (Number.isFinite(payload.dropX)) {
          const x = Number(payload.dropX)
          const before = [...document.querySelectorAll<HTMLElement>('.ptab[data-project-id]')]
            .find((el) => x < el.getBoundingClientRect().left + el.getBoundingClientRect().width / 2)
          beforeId = before?.dataset.projectId
        }
        let ok = false
        try { ok = useKaisola.getState().adoptProject({ ...payload, beforeId }) } catch { ok = false }
        if (payload.transferId) w.adoptionComplete(payload.transferId, ok)
      }),
    ]
    w?.adoptionReady?.()
    return () => { for (const off of offs) off?.() }
  }, [])

  // live session identity (fg process / cwd / repo / branch) from the poller.
  // terminalMeta stays a GLOBAL map keyed by unique terminal id (never swapped),
  // so a background pty's identity survives; we only mirror a live pty onto its
  // tab as a 'running' badge (once, without clobbering a needs-you/failed dot).
  useEffect(() => {
      const applyAgentActivity = (activity: { id: string; busy: boolean; completedAt?: number | null }) => {
        const st = useKaisola.getState()
        const previousCompletedAt = st.terminalMeta[activity.id]?.agentCompletedAt
        st.setTerminalMeta(activity.id, {
          agentBusy: activity.busy,
          ...(activity.completedAt != null ? { agentCompletedAt: activity.completedAt } : {}),
        })
        const pid = terminalOwnerMap(st)[activity.id]
        if (!pid) return
        if (activity.busy) {
          if (pid !== st.activeProjectId) st.setProjectActivity(pid, 'running')
          return
        }
        if (activity.completedAt == null || activity.completedAt === previousCompletedAt) return
        const owner = pid === st.activeProjectId ? st : st.projectSlices[pid]
        const seen = pid === st.activeProjectId && !!owner?.dockOpen && !!owner?.dockViews.includes(activity.id) && !document.hidden && document.hasFocus()
        if (seen) return
        st.markNeedsYou(activity.id, pid)
        st.setProjectActivity(pid, 'completed')
        const terminal = owner?.terminals.find((record) => record.id === activity.id)
        const provider = /claude/i.test(terminal?.singletonKey ?? '')
          ? 'Claude'
          : /codex/i.test(terminal?.singletonKey ?? '')
            ? 'Codex'
            : terminal?.name ?? 'Agent'
        const tab = st.projectTabs.find((project) => project.id === pid)
        notifyAgent(`${provider} finished`, tab ? projectLabel(tab) : 'Kaisola', pid, activity.id, {
          sourceId: `terminal:${activity.id}:${activity.completedAt}`,
          kind: 'completed',
          createdAt: activity.completedAt ?? undefined,
        })
      }
      const offMeta = bridge.terminal.onMeta((m) => {
        const st = useKaisola.getState()
        st.setTerminalMeta(m.id, {
          fgProcess: m.fgProcess,
          running: m.running,
          cwd: m.cwd,
          root: m.root,
          repo: m.repo,
          branch: m.branch,
        })
        if (typeof m.agentBusy === 'boolean') {
          applyAgentActivity({ id: m.id, busy: m.agentBusy, completedAt: m.agentCompletedAt })
        }
        if (m.running) {
          const pid = terminalOwnerMap(st)[m.id]
          const owner = pid === st.activeProjectId ? st : pid ? st.projectSlices[pid] : undefined
          const terminal = owner?.terminals.find((entry) => entry.id === m.id)
          // A CLI agent holding the foreground is often merely waiting at its
          // composer. Terminal.tsx emits the truthful prompt lifecycle instead.
          if (terminal?.singletonKey?.startsWith('agent:')) return
          if (pid && pid !== st.activeProjectId) {
            const tab = st.projectTabs.find((t) => t.id === pid)
            if (tab && !tab.activity) st.setProjectActivity(pid, 'running')
          }
        }
      })
      const offActivity = bridge.terminal.onAgentActivity(applyAgentActivity)
      return () => { offMeta(); offActivity() }
    }, [])

  // an ACP agent is blocked on a permission — resolve the OWNING project first
  // (agentKey map). Active → the live path (reads assistantThreads by req.key).
  // Background → the auto-answer is global (sensitiveGlobs + permissionRules),
  // so honor it here too, but park the human-facing card in the owner's slice
  // with a needs-you badge (never the active project — spec risk #3).
  useEffect(() => {
    const offs = [
      bridge.acp.onPermission((req) => {
        const st = useKaisola.getState()
        // scoped connections name their owner exactly; legacy/unscoped asks
        // fall back to the agentKey→project heuristic
        const pid = req.scope || projectIdForEvent(st, { agentKey: req.key })
        const slice = st.projectSlices[pid]
        const announce = () => {
          if (pid === st.activeProjectId && !document.hidden && document.hasFocus()) return
          const tab = st.projectTabs.find((project) => project.id === pid)
          notifyAgent(`${req.agent} needs you`, tab ? projectLabel(tab) : req.title, pid, req.key.split('::')[1], {
            sourceId: req.permId,
            kind: 'permission',
          })
        }
        if (pid === st.activeProjectId || !slice) { st.receivePermission(req); announce(); return }
        if (requestIsSensitive(st.sensitiveGlobs, req)) {
          st.patchProject(
            pid,
            (sl) => ({
              pendingPermissions: sl.pendingPermissions.some((p) => p.permId === req.permId) ? sl.pendingPermissions : [...sl.pendingPermissions, { ...req, sensitive: true }],
              agentFeed: [{ id: uid('feed'), at: Date.now(), kind: 'permission' as const, text: `⚠ ${req.agent} asks (sensitive file): ${req.title}` }, ...sl.agentFeed].slice(0, 60),
            }),
            'needs-you',
          )
          announce()
          return
        }
        if (requestMatchesRules(st.permissionRules, slice.workspacePath, req)) {
          void bridge.acp.respondPermission(req.permId, allowOnceAnswer(req))
          return
        }
        st.patchProject(
          pid,
          (sl) => ({
            pendingPermissions: sl.pendingPermissions.some((p) => p.permId === req.permId) ? sl.pendingPermissions : [...sl.pendingPermissions, req],
            agentFeed: [{ id: uid('feed'), at: Date.now(), kind: 'permission' as const, text: `${req.agent} asks: ${req.title}` }, ...sl.agentFeed].slice(0, 60),
          }),
          'needs-you',
        )
        announce()
      }),
      // main resolved a pending ask itself (5-min timeout, or the agent died
      // while it was pending) — drop the inline card the composer is still showing
      bridge.acp.onPermissionResolved((permId) => useKaisola.getState().dismissPermission(permId)),
      // a human-gated MCP write tool fired → a pending Proposal in the gate
      bridge.mcp?.onProposal?.((ev) => useKaisola.getState().receiveMcpProposal(ev)),
      // agent-task ledger traffic (agents coordinating over the Kaisola MCP
      // server) lands in the OWNING project's activity feed — agent↔agent
      // messages stay in the human's line of sight
      bridge.ledger?.onEvent(({ type, task }) => {
        const st = useKaisola.getState()
        const pid = projectIdForEvent(st, { cwd: task.project ?? undefined })
        const who = task.createdBy || task.owner || 'agent'
        const text = type === 'posted'
          ? `${who} posted: ${task.title}${task.owner ? ` → ${task.owner}` : ''}`
          : `${task.title} → ${task.status}${task.result ? ` · ${task.result.slice(0, 80)}` : ''}`
        pushProjectFeed(pid, pid === st.activeProjectId, { at: task.updatedAt, kind: 'task', text })
      }),
    ]
    return () => { for (const off of offs) off?.() }
  }, [])

  // push the rehydrated sensitive-file globs to main (agents' fs enforcement)
  useEffect(() => {
    if (isDesktop) bridge.acp.setGuardrails?.(useKaisola.getState().sensitiveGlobs)
  }, [])

  // settings.json / keymap.json: apply at launch, re-apply on save (the files
  // always win over the persisted GUI state at load time)
  useEffect(() => {
    void loadUserConfig({ quiet: true })
    return watchUserConfig()
  }, [])

  // A tiny disk-cached wallpaper thumbnail can tint the live chrome. The
  // renderer retains only three average-color bytes, never a desktop raster.
  useEffect(() => initGlassWash(), [])

  // the native under-window material (vibrancy/glass) must follow the APP
  // theme — push the persisted theme once on boot (store actions push changes)
  useEffect(() => {
    const s = useKaisola.getState()
    if (isDesktop) bridge.setAppTheme?.(s.themeMode === 'system' ? 'system' : s.theme)
    if (s.themeMode === 'system') s.applySystemTheme() // persisted theme may be stale vs the OS
    return bridge.onThemeChanged?.((t) => useKaisola.getState().followTheme(t))
  }, [])

  // system mode follows the OS live — scheduled/sunset switches land instantly
  useEffect(() => {
    const mq = window.matchMedia?.('(prefers-color-scheme: dark)')
    if (!mq) return
    const on = () => useKaisola.getState().applySystemTheme()
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [])

  // Claude Code hook events (the terminal session's tap): activity feed,
  // follow-the-agent, and an automatic checkpoint at each turn start.
  useEffect(() => {
    if (!isDesktop) return
    void bridge.claude.rebind()
    return bridge.claude.onEvent((ev) => {
      const st = useKaisola.getState()
      // resolve the OWNING project FIRST (session_id → terminal owner, else the
      // longest workspacePath prefix of cwd, active tab wins ties) so a
      // background Claude's turns never leak into the active project (risk #3)
      const pid = projectIdForEvent(st, { cwd: ev.cwd, sessionId: ev.sessionId })
      const isActive = pid === st.activeProjectId
      const ws = isActive ? st.workspacePath : st.projectSlices[pid]?.workspacePath ?? null
      const owner = isActive ? st : st.projectSlices[pid]
      const claudeTerminal = owner?.terminals.find((terminal) => terminal.singletonKey === 'agent:claude-code')
      // ignore sessions running outside the owner's workspace (a no-prefix event
      // falls back to the active tab; drop it if its cwd isn't under that tree)
      if (ws && ev.cwd && ev.cwd !== ws && !ev.cwd.startsWith(`${ws}/`)) return
      // remember the conversation: the next launch boots `claude --resume` into
      // this session, so a restart lands you back in the same chat
      if (ev.sessionId && ws) st.setClaudeSession(ws, ev.sessionId)
      if (ev.event === 'UserPromptSubmit') {
        if (claudeTerminal) st.setTerminalMeta(claudeTerminal.id, { agentBusy: true, lastExit: null })
        if (!isActive) st.setProjectActivity(pid, 'running')
        const label = ev.prompt ? `Claude: ${ev.prompt.slice(0, 42)}` : 'Claude turn'
        pushProjectFeed(pid, isActive, { at: ev.at, kind: 'prompt', text: ev.prompt || 'Prompt sent' })
        if (isActive) void st.snapshotWorkspace(label)
        else void snapshotBackground(pid, ws, label)
      } else if (ev.event === 'PostToolUse') {
        const rel = ev.filePath && ws && ev.filePath.startsWith(`${ws}/`) ? ev.filePath.slice(ws.length + 1) : ev.filePath
        pushProjectFeed(pid, isActive, {
          at: ev.at,
          kind: 'tool',
          tool: ev.tool,
          path: ev.filePath,
          text: `${ev.tool ?? 'Tool'}${rel ? ` · ${rel}` : ev.command ? ` · ${ev.command}` : ''}`,
        })
        // follow the agent: touched files open as TRANSIENT previews — ONLY for
        // the active project (requestFile writes the active editor; a background
        // PostToolUse must never open a file in the wrong tab — risk #3)
        if (isActive && st.followAgent && ev.filePath && ws && ev.filePath.startsWith(`${ws}/`)) {
          st.requestFile(ev.filePath)
        }
      } else if (ev.event === 'Stop' || ev.event === 'Notification') {
        // Stop logs the finished turn; Notification is a mid-turn nudge. Either
        // way, if you're not looking, raise the "needs you" signal on the owner.
        if (ev.event === 'Stop') {
          pushProjectFeed(pid, isActive, { at: ev.at, kind: 'stop', text: 'Claude finished the turn' })
          if (claudeTerminal) st.setTerminalMeta(claudeTerminal.id, { agentBusy: false })
        }
        const seen = isActive && claudeTerminal && st.dockViews.includes(claudeTerminal.id) && !document.hidden && document.hasFocus()
        if (!seen && claudeTerminal) st.markNeedsYou(claudeTerminal.id, pid)
        if (!isActive) st.setProjectActivity(pid, ev.event === 'Stop' ? 'completed' : 'needs-you')
        // native notification when you're NOT looking (window unfocused/hidden,
        // or the owning tab is in the background) — click brings the tab up
        if (!isActive || document.hidden || !document.hasFocus()) {
          const tab = st.projectTabs.find((t) => t.id === pid)
          notifyAgent(
            ev.event === 'Stop' ? 'Claude finished' : 'Claude needs you',
            tab ? projectLabel(tab) : 'Kaisola',
            pid,
            claudeTerminal?.id,
            {
              sourceId: `claude:${ev.sessionId ?? claudeTerminal?.id ?? 'session'}:${ev.at}:${ev.event}`,
              kind: ev.event === 'Stop' ? 'completed' : 'question',
              createdAt: ev.at,
            },
          )
        }
      }
    })
  }, [])

  // files arriving from the OS (Finder "Open With", dock drops) or dragged into
  // the window: folders become the workspace; files open as tabs, adopting the
  // file's folder as workspace only when none is set yet
  useEffect(() => {
    if (!isDesktop) return
    const openExternalPath = async (p: string) => {
      const st = useKaisola.getState()
      const asFolder = await bridge.fs.list(p)
      if (asFolder.ok) {
        // focus its tab if already open; fill the CURRENT empty tab in place
        // (the launcher's "open here"); else open it in a new project tab
        if (!st.workspacePath && !st.projectTabs.some((t) => t.workspacePath === p)) st.setWorkspace(p)
        else st.openProjectFolder(p)
        return
      }
      // a file: hand it to the tab whose workspace owns it (longest prefix),
      // then open it there; with no owner, adopt its folder into the active tab
      const owner = projectIdForEvent(st, { cwd: p })
      const ownerWs = st.projectTabs.find((t) => t.id === owner)?.workspacePath
      const owned = !!ownerWs && (p === ownerWs || p.startsWith(ownerWs.endsWith('/') ? ownerWs : `${ownerWs}/`))
      if (owned && owner !== st.activeProjectId) st.switchProject(owner)
      const now = useKaisola.getState()
      if (!now.workspacePath) now.setWorkspace(p.split('/').slice(0, -1).join('/') || '/')
      now.requestFile(p)
    }
    const offOpen = bridge.onOpenExternalFile?.(({ path }) => void openExternalPath(path))
    // only claim drags that carry OS files — card rearranging stays untouched
    const onDragOver = (e: DragEvent) => {
      if (e.dataTransfer?.types.includes('Files')) e.preventDefault()
    }
    const onDrop = (e: DragEvent) => {
      const files = Array.from(e.dataTransfer?.files ?? [])
      if (!files.length) return
      e.preventDefault()
      for (const file of files) {
        const p = bridge.pathForFile?.(file)
        if (p) void openExternalPath(p)
      }
    }
    window.addEventListener('dragover', onDragOver)
    window.addEventListener('drop', onDrop)
    return () => {
      offOpen?.()
      window.removeEventListener('dragover', onDragOver)
      window.removeEventListener('drop', onDrop)
    }
  }, [])

  // The old research-workflow views are still in the codebase, but this shell
  // is intentionally an IDE-first surface for now: files, agents, terminals.
  useEffect(() => {
    if (stage !== 'files') setStage('files')
  }, [setStage, stage])

  // the files/canvas card resizes from its left edge (its right edge is the
  // window) — drag left to widen; double-click resets to automatic sharing
  const startCanvasResize = (e: ReactMouseEvent) => {
    e.preventDefault()
    // a PDF iframe / browser webview under the cursor would swallow mousemove
    // and freeze the drag — dead to pointer events while the drag runs
    shellDrag.start()
    const wrap = (e.currentTarget as HTMLElement).parentElement
    const startX = e.clientX
    const startW = canvasWidth ?? wrap?.getBoundingClientRect().width ?? 600
    const onMove = (ev: MouseEvent) => setCanvasWidth(startW - (ev.clientX - startX))
    const onUp = () => {
      shellDrag.end()
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
  }

  const studio = layoutMode === 'studio'
  const showCanvas = !studio || canvasOpen
  const sidebarSessions = studio && tabLayout === 'sidebar'

  return (
    <div className="app" data-sidebar={false} data-layout={layoutMode}>
      {/* grid row 1: the project strip (desktop main window only; on web/pop it
          isn't rendered and --tabstrip-h collapses the row to 0) */}
      {isDesktop && !POP_TERMINAL_ID && <ProjectTabs />}
      {isDesktop && !POP_TERMINAL_ID && <SavedWindows />}
      {isDesktop && <TabMenuSync />}
      {isDesktop && !POP_TERMINAL_ID && <AttentionSync />}
      {isDesktop && !POP_TERMINAL_ID && <CompanionProjectionSync />}
      <TopProgress />
      <div
        className="app-body"
        data-layout={layoutMode}
        data-session-nav={sidebarSessions ? 'sidebar' : 'top'}
        data-rail={studio && !railOpen ? 'closed' : undefined}
        style={(railWidth || sessionRailWidth) ? ({
          ...(railWidth ? { '--wsrail-w': `${railWidth}px` } : {}),
          ...(sessionRailWidth ? { '--sessionrail-w': `${sessionRailWidth}px` } : {}),
        } as CSSProperties) : undefined}
      >
        {sidebarSessions && <SessionSidebar />}
        {studio && railOpen && !sidebarSessions && <WorkspaceRail />}
        {/* session cards on the left, the files/canvas card on the right
            (minimizable — when hidden the cards take the whole work row) */}
        <div className="work-row">
          {studio && <SessionCards />}
          {showCanvas && (
            <div className="canvas-wrap" style={studio && dockOpen && canvasWidth ? { flex: `0 0 ${canvasWidth}px` } : undefined}>
              {studio && dockOpen && (
                <div
                  className="canvas-resize"
                  onMouseDown={startCanvasResize}
                  onDoubleClick={() => setCanvasWidth(null)}
                  onKeyDown={(event) => {
                    if (event.key === 'Home') { event.preventDefault(); setCanvasWidth(null); return }
                    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
                    event.preventDefault()
                    const next = (canvasWidth ?? 600) + (event.key === 'ArrowLeft' ? -20 : 20)
                    setCanvasWidth(Math.max(320, Math.min(window.innerWidth - 360, next)))
                  }}
                  role="separator"
                  aria-label="Resize document canvas"
                  aria-orientation="vertical"
                  tabIndex={0}
                  title="Drag to resize · double-click to reset"
                />
              )}
              <main className="canvas">
                <StageView />
              </main>
            </div>
          )}
        </div>
        {sidebarSessions && railOpen && <WorkspaceRail side="right" />}
        {(!studio || (!sidebarSessions && !railOpen)) && <ShellSidebarFooter floating />}
      </div>
      {/* Desktop main windows keep their permanent panel switches in the
          project strip. This utility fallback covers web + pop windows only. AFTER
          .app-body on purpose: the body is a drag surface, and Chromium
          builds the window's draggable region in order — a drag rect that comes
          later paves over an earlier no-drag island. Rendering the tools last
          keeps their no-drag hole final, so these buttons take real clicks
          instead of dragging the window. */}
      {!(isDesktop && !POP_TERMINAL_ID) && (
        <div className="float-tools">
          <ShellTools />
        </div>
      )}
      <CommandPalette />
      <OmniBar />
      <ProvenancePopover />
      <ReviewFocus />
      <McpInstallModal />
      <ExtensionsCenter />
      <Settings />
      <SignInCard />
      <Toaster />
      <Onboarding />
    </div>
  )
}

function WindowDeletionBoot() {
  useEffect(registerWindowDeletionHandler, [])
  return null
}

export default function App() {
  const deleteBoot = new URLSearchParams(location.search).get('deleteWindow') === '1'
  return deleteBoot ? <WindowDeletionBoot /> : <KaisolaApp />
}
