import { useEffect, useRef, type CSSProperties, type MouseEvent as ReactMouseEvent } from 'react'
import { useKaisola, sessionOrderIds, projectIdForEvent, terminalOwnerMap, POP_TERMINAL_ID, type AgentFeedItem, type ProjectTab, type ClosedProject } from './store/store'
import { bridge, isDesktop } from './lib/bridge'
import { uid, nowISO } from './domain/ids'
import { requestIsSensitive, requestMatchesRules, allowOnceAnswer } from './lib/permissionRules'
import { OmniBar } from './components/shell/OmniBar'
import { loadUserConfig, watchUserConfig } from './lib/userConfig'
import { initGlassWash } from './lib/glassWash'
import { ShellTools } from './components/shell/AgentSidebar'
import { WorkspaceRail } from './components/shell/WorkspaceRail'
import { ProjectTabs } from './components/shell/ProjectTabs'
import { ProjectLauncher } from './components/shell/ProjectLauncher'
import { CommandPalette } from './components/shell/CommandPalette'
import { SessionCards, shellDrag } from './components/shell/SessionCards'
import { ProvenancePopover } from './components/Provenance'
import { ReviewFocus } from './components/ReviewFocus'
import { McpInstallModal } from './components/shell/McpInstallModal'
import { Settings } from './components/Settings'
import { SignInCard } from './components/SignInCard'
import { Toaster } from './components/Toaster'

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
function notifyAgent(title: string, body: string, pid: string) {
  if (typeof Notification === 'undefined' || bridge.smoke) return
  const now = Date.now()
  if (now - (lastNotifyAt.get(pid) ?? 0) < 15_000) return
  lastNotifyAt.set(pid, now)
  try {
    const n = new Notification(title, { body, silent: true })
    n.onclick = () => {
      window.focus()
      const st = useKaisola.getState()
      if (st.projectTabs.some((t) => t.id === pid)) st.switchProject(pid)
    }
  } catch { /* notifications denied/unavailable — the tab badge still shows */ }
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

export default function App() {
  const layoutMode = useKaisola((s) => s.layoutMode)
  const perfMode = useKaisola((s) => s.perfMode)
  const stage = useKaisola((s) => s.stage)
  const setStage = useKaisola((s) => s.setStage)
  const dockOpen = useKaisola((s) => s.dockOpen)
  const canvasOpen = useKaisola((s) => s.canvasOpen)
  const canvasWidth = useKaisola((s) => s.canvasWidth)
  const setCanvasWidth = useKaisola((s) => s.setCanvasWidth)
  const railWidth = useKaisola((s) => s.railWidth)
  const railOpen = useKaisola((s) => s.railOpen)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const activeProjectId = useKaisola((s) => s.activeProjectId)
  // per-project arming (spec risk #5): a single boolean would arm Claude once
  // for the whole app and never in the second project — key by tab+workspace
  const autoClaudeRef = useRef<Set<string>>(new Set())
  useKeybindings()

  // when the ACP agent runs a command it spawns a real pty — list it as a
  // session in the OWNING project's rail (a background run docks in its slice,
  // never the active tab), focused live so you can watch and take over.
  useEffect(
    () =>
      bridge.acp.onTerminal((info) => {
        const st = useKaisola.getState()
        const pid = projectIdForEvent(st, { agentKey: info.agentKey, cwd: info.cwd })
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
  useEffect(
    () => bridge.windows?.onPopClosed?.(({ termId }) => useKaisola.getState().restorePoppedTerminal(termId)),
    [],
  )

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
      // Chrome-style tear-off: a project shipped from another window lands here
      w?.onAdoptProject?.((payload) => useKaisola.getState().adoptProject(payload as { tab: ProjectTab; slice: ClosedProject['slice'] })),
    ]
    return () => { for (const off of offs) off?.() }
  }, [])

  // live session identity (fg process / cwd / repo / branch) from the poller.
  // terminalMeta stays a GLOBAL map keyed by unique terminal id (never swapped),
  // so a background pty's identity survives; we only mirror a live pty onto its
  // tab as a 'running' badge (once, without clobbering a needs-you/failed dot).
  useEffect(
    () =>
      bridge.terminal.onMeta((m) => {
        const st = useKaisola.getState()
        st.setTerminalMeta(m.id, {
          fgProcess: m.fgProcess,
          running: m.running,
          cwd: m.cwd,
          root: m.root,
          repo: m.repo,
          branch: m.branch,
        })
        if (m.running) {
          const pid = terminalOwnerMap(st)[m.id]
          if (pid && pid !== st.activeProjectId) {
            const tab = st.projectTabs.find((t) => t.id === pid)
            if (tab && !tab.activity) st.setProjectActivity(pid, 'running')
          }
        }
      }),
    [],
  )

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
        if (pid === st.activeProjectId || !slice) { st.receivePermission(req); return }
        if (requestIsSensitive(st.sensitiveGlobs, req)) {
          st.patchProject(
            pid,
            (sl) => ({
              pendingPermissions: sl.pendingPermissions.some((p) => p.permId === req.permId) ? sl.pendingPermissions : [...sl.pendingPermissions, { ...req, sensitive: true }],
              agentFeed: [{ id: uid('feed'), at: Date.now(), kind: 'permission' as const, text: `⚠ ${req.agent} asks (sensitive file): ${req.title}` }, ...sl.agentFeed].slice(0, 60),
            }),
            'needs-you',
          )
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

  // wallpaper-sampled chrome wash + painted-mode background (macOS only;
  // failures silently keep the theme-tint defaults)
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
      // ignore sessions running outside the owner's workspace (a no-prefix event
      // falls back to the active tab; drop it if its cwd isn't under that tree)
      if (ws && ev.cwd && ev.cwd !== ws && !ev.cwd.startsWith(`${ws}/`)) return
      // remember the conversation: the next launch boots `claude --resume` into
      // this session, so a restart lands you back in the same chat
      if (ev.sessionId && ws) st.setClaudeSession(ws, ev.sessionId)
      if (ev.event === 'UserPromptSubmit') {
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
        if (ev.event === 'Stop') pushProjectFeed(pid, isActive, { at: ev.at, kind: 'stop', text: 'Claude finished the turn' })
        if (isActive) {
          const claude = st.terminals.find((t) => t.singletonKey === 'agent:claude-code')
          if (claude && !st.dockViews.includes(claude.id)) st.markNeedsYou(claude.id)
        } else {
          st.setProjectActivity(pid, 'needs-you')
        }
        // native notification when you're NOT looking (window unfocused/hidden,
        // or the owning tab is in the background) — click brings the tab up
        if (!isActive || document.hidden || !document.hasFocus()) {
          const tab = st.projectTabs.find((t) => t.id === pid)
          notifyAgent(
            ev.event === 'Stop' ? 'Claude finished' : 'Claude needs you',
            tab ? projectLabel(tab) : 'Kaisola',
            pid,
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

  useEffect(() => {
    // wait for a workspace before auto-launching claude — spawning it in $HOME
    // would let the agent read/edit the wrong tree for the whole session. Arm
    // ONCE per project+workspace (a switch to a new tab arms it there too).
    if (!isDesktop || !workspacePath) return
    const key = `${activeProjectId}\0${workspacePath}`
    if (autoClaudeRef.current.has(key)) return
    autoClaudeRef.current.add(key)
    void (async () => {
      const before = useKaisola.getState()
      const freshShell =
        // 'focus' was the pre-rename default; 'studio' is the current one — a
        // pristine store can carry either depending on when it was created.
        (before.layoutMode === 'focus' || before.layoutMode === 'studio') &&
        before.assistantThreads.length <= 1 &&
        before.terminals.length === 1 &&
        // the lone default card may be the thread (old stores), the terminal
        // (terminal-first default), or NO card at all (the clean homescreen
        // default) — all count as an untouched shell
        (before.dockGrid.length === 0 ||
          (before.dockGrid.length === 1 &&
            before.dockGrid[0]?.length === 1 &&
            (before.dockGrid[0]?.[0] === before.activeThreadId || before.dockGrid[0]?.[0] === before.terminals[0]?.id))) &&
        !before.terminals.some((term) => term.singletonKey === 'agent:claude-code')

      // the boot line (account env, --resume/--continue probing, hooks tap) is
      // owned by the store so Settings' "apply account now" reuses it verbatim
      const launched = await useKaisola.getState().launchClaude({ expect: { pid: activeProjectId, ws: workspacePath } })
      if (!launched || !freshShell || bridge.smoke) return
      queueMicrotask(() => {
        const latest = useKaisola.getState()
        const claude = latest.terminals.find((term) => term.singletonKey === 'agent:claude-code')
        if (!claude) return
        latest.setLayoutMode('studio')
        latest.setDockView(claude.id)
        for (const thread of latest.assistantThreads) {
          useKaisola.getState().removeDockView(thread.id)
        }
      })
    })()
  }, [requestTerminal, workspacePath, activeProjectId])

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

  return (
    <div className="app" data-sidebar={false} data-layout={layoutMode}>
      {/* painted glass: an opaque window that draws its own see-through — the
          pre-blurred wallpaper (glassWash.ts) pinned to the desktop position */}
      {isDesktop && perfMode === 'painted' && <div className="app-wallpaper" aria-hidden />}
      {/* grid row 1: the project strip (desktop main window only; on web/pop it
          isn't rendered and --tabstrip-h collapses the row to 0) */}
      {isDesktop && !POP_TERMINAL_ID && <ProjectTabs />}
      {isDesktop && <TabMenuSync />}
      <TopProgress />
      <div
        className="app-body"
        data-layout={layoutMode}
        data-rail={studio && !railOpen ? 'closed' : undefined}
        style={railWidth ? ({ '--wsrail-w': `${railWidth}px` } as CSSProperties) : undefined}
      >
        {studio && railOpen && <WorkspaceRail />}
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
                  title="Drag to resize · double-click to reset"
                />
              )}
              <main className="canvas">
                <StageView />
              </main>
            </div>
          )}
        </div>
      </div>
      {/* On desktop main windows the tool cluster lives IN the project tab
          strip (ProjectTabs) — same chrome row, no overlap with the session
          tabs. This floating fallback covers web + pop windows only. AFTER
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
      <Settings />
      <SignInCard />
      <Toaster />
    </div>
  )
}
