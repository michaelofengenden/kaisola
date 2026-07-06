import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react'
import { useKaisola, GROUP_COLORS } from '../../store/store'
import { bridge, isDesktop, type FsEntry } from '../../lib/bridge'
import { sessionHue, terminalAgentKey } from '../../lib/sessionHue'
import { useAgentRegistry, agentName, openAgentSession, type RegistryAgent } from '../../lib/registry'
import { Icon } from '../Icon'
import { Dropdown } from '../Dropdown'
import { fileIcon } from '../../lib/fileIcon'

const urlHost = (u?: string) => {
  try {
    return u ? new URL(u).host : undefined
  } catch {
    return undefined
  }
}

/**
 * The left rail card — what you're working WITH. Its top strip hosts the
 * native traffic lights (drag region) and the "+" session menu; then the
 * session tabs (agent threads + terminals + panels), then the workspace tree.
 */
export function WorkspaceRail() {
  const { all, menu } = useAgentRegistry()

  return (
    <aside className="wsrail">
      <RailHead menu={menu} />
      <SessionsSection agents={all} />
      <AgentPulse />
      <OutlineSection />
      <QuotesSection />
      <FilesTree />
    </aside>
  )
}

/**
 * Headings of the active file (VS Code's Explorer-outline placement — inside
 * an existing surface, not a new panel). Follows the cursor; click to jump —
 * scrolls the editor OR the rendered preview, whichever is showing.
 */
function OutlineSection() {
  const outline = useKaisola((s) => s.outline)
  const cursorLine = useKaisola((s) => s.editorCursorLine)
  const openFilePath = useKaisola((s) => s.openFilePath)
  const requestScroll = useKaisola((s) => s.requestScroll)
  const activeRef = useRef<HTMLButtonElement>(null)
  // follow the cursor: the heading whose section contains it
  let activeIdx = -1
  if (cursorLine != null) {
    for (let i = 0; i < outline.length; i++) {
      if (outline[i].line <= cursorLine) activeIdx = i
      else break
    }
  }
  useEffect(() => {
    activeRef.current?.scrollIntoView({ block: 'nearest' })
  }, [activeIdx])
  if (!outline.length || !openFilePath) return null
  return (
    <details className="rail-sec" open>
      <summary className="rail-sec-head">
        <Icon name="ChevronRight" size={11} className="rail-sec-caret" />
        <span className="grow">Outline</span>
        <span className="rail-sec-count">{outline.length}</span>
      </summary>
      <div className="rail-sec-body rail-outline">
        {outline.map((h, i) => (
          <button
            key={`${h.line}-${i}`}
            ref={i === activeIdx ? activeRef : undefined}
            className="rail-outline-item"
            data-active={i === activeIdx}
            style={{ paddingLeft: 8 + (h.level - 1) * 11 }}
            onClick={() => requestScroll(openFilePath, h.line, i)}
            title={h.text}
          >
            <span className="truncate">{h.text}</span>
          </button>
        ))}
      </div>
    </details>
  )
}

/**
 * Captured quotes (the annotation layer) — Zotero's extracted-annotations
 * pattern: every quote links back to its exact spot; click round-trips.
 */
function QuotesSection() {
  const annotations = useKaisola((s) => s.annotations)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const requestFile = useKaisola((s) => s.requestFile)
  const requestScroll = useKaisola((s) => s.requestScroll)
  const removeAnnotation = useKaisola((s) => s.removeAnnotation)
  const mine = annotations.filter((a) => a.workspace === workspacePath)
  if (!mine.length) return null
  const jump = (a: (typeof mine)[number]) => {
    requestFile(a.path, undefined, { pinned: false })
    // let the tab mount before asking it to scroll
    window.setTimeout(() => requestScroll(a.path, a.line), 180)
  }
  return (
    <details className="rail-sec" open>
      <summary className="rail-sec-head">
        <Icon name="ChevronRight" size={11} className="rail-sec-caret" />
        <span className="grow">Quotes</span>
        <span className="rail-sec-count">{mine.length}</span>
      </summary>
      <div className="rail-sec-body rail-quotes">
        {mine.slice(-40).reverse().map((a) => (
          <div key={a.id} className="rail-quote" style={{ '--annot-color': a.color } as React.CSSProperties}>
            <button className="rail-quote-main" onClick={() => jump(a)} title={`${a.quote}\n— ${a.path.split('/').pop()}:${a.line}`}>
              <span className="rail-quote-text">{a.quote}</span>
              <span className="rail-quote-src truncate">{a.path.split('/').pop()} · {a.line}</span>
            </button>
            <button className="rail-quote-x" onClick={() => removeAnnotation(a.id)} title="Remove quote">
              <Icon name="X" size={10} />
            </button>
          </div>
        ))}
      </div>
    </details>
  )
}

/**
 * One quiet line of agent activity (the newest hook/tool event) between the
 * sessions and the tree — legibility without a dashboard. Click to jump to
 * the file the agent touched; the dot pulses while a turn is running.
 */
function AgentPulse() {
  const feed = useKaisola((s) => s.agentFeed)
  const requestFile = useKaisola((s) => s.requestFile)
  const latest = feed[0]
  if (!latest) return null
  const running = latest.kind !== 'stop'
  return (
    <button
      className="agent-pulse"
      data-running={running}
      onClick={() => { if (latest.path) requestFile(latest.path) }}
      title={latest.path ? `${latest.text} — click to open` : latest.text}
    >
      <span className="agent-pulse-dot" data-running={running} />
      <span className="grow truncate">{latest.text}</span>
    </button>
  )
}

/** The card's top strip: the window-drag space + "new session". */
function RailHead({ menu }: { menu: RegistryAgent[] }) {
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
    <div
      className="rail-head"
      // native titlebar parity: double-clicking the drag strip zooms the window
      onDoubleClick={(e) => {
        if ((e.target as HTMLElement).closest('button')) return
        bridge.winCtl('zoom')
      }}
    >
      <span className="grow" />
      <Dropdown
        icon="Plus"
        value=""
        placeholder=""
        options={[
          // agents first (the user picks WHICH one — no silent default), then
          // saved templates, the other session kinds, and the registry
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
    </div>
  )
}

/**
 * Sessions — the open cards read as raised tabs on a segmented track. Click
 * to open a session as its own card (never disturbing the cards already
 * placed), double-click to rename (threads and terminals alike).
 */
function SessionsSection({ agents }: { agents: RegistryAgent[] }) {
  const threads = useKaisola((s) => s.assistantThreads)
  const terminals = useKaisola((s) => s.terminals)
  const agentTerminals = useKaisola((s) => s.agentTerminals)
  const panels = useKaisola((s) => s.panels)
  const closePanel = useKaisola((s) => s.closePanel)
  const terminalMeta = useKaisola((s) => s.terminalMeta)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const dockViews = useKaisola((s) => s.dockViews)
  const dockOpen = useKaisola((s) => s.dockOpen)
  const setActiveThread = useKaisola((s) => s.setActiveThread)
  const setDockView = useKaisola((s) => s.setDockView)
  const addDockSplit = useKaisola((s) => s.addDockSplit)
  const removeDockView = useKaisola((s) => s.removeDockView)
  const closeThread = useKaisola((s) => s.closeAssistantThread)
  const closeTerminal = useKaisola((s) => s.closeTerminal)
  const closeAgentTerminal = useKaisola((s) => s.closeAgentTerminal)
  const renameThread = useKaisola((s) => s.renameAssistantThread)
  const renameTerminal = useKaisola((s) => s.renameTerminal)
  const reorderThreads = useKaisola((s) => s.reorderAssistantThreads)

  const sessionGroups = useKaisola((s) => s.sessionGroups)
  const createSessionGroup = useKaisola((s) => s.createSessionGroup)
  const renameSessionGroup = useKaisola((s) => s.renameSessionGroup)
  const toggleSessionGroupCollapsed = useKaisola((s) => s.toggleSessionGroupCollapsed)
  const assignToGroup = useKaisola((s) => s.assignToGroup)
  const removeSessionGroup = useKaisola((s) => s.removeSessionGroup)
  const setSessionGroupColor = useKaisola((s) => s.setSessionGroupColor)
  const pinnedSessions = useKaisola((s) => s.pinnedSessions)
  const togglePinSession = useKaisola((s) => s.togglePinSession)
  const needsYou = useKaisola((s) => s.needsYou)
  const worktreeSessions = useKaisola((s) => s.worktreeSessions)
  const saveSessionTemplate = useKaisola((s) => s.saveSessionTemplate)
  const mergeWorktreeSession = useKaisola((s) => s.mergeWorktreeSession)
  const removeWorktreeSession = useKaisola((s) => s.removeWorktreeSession)

  const [editing, setEditing] = useState<{ id: string; kind: 'thread' | 'term' | 'group' } | null>(null)
  const [editValue, setEditValue] = useState('')
  const dragRef = useRef<string | null>(null)
  // Chrome-style grouping: right-click a session row → move between groups
  const [sessionMenu, setSessionMenu] = useState<{ x: number; y: number; id: string } | null>(null)

  const commitRename = () => {
    if (editing) {
      const name = editValue.trim() || undefined
      if (editing.kind === 'thread') renameThread(editing.id, name)
      else if (editing.kind === 'group') renameSessionGroup(editing.id, name ?? '')
      else renameTerminal(editing.id, name)
    }
    setEditing(null)
  }
  const isActive = (id: string) => dockOpen && dockViews.includes(id)

  // ambiguity rule: repo suffixes appear only when sessions span >1 root
  const rootOf = (id: string, fallback?: string) => {
    const m = terminalMeta[id]
    return m?.root ?? m?.cwd ?? fallback ?? workspacePath ?? undefined
  }
  const allRoots = new Set(
    [
      ...terminals.map((t) => rootOf(t.id, t.cwd)),
      ...agentTerminals.map((t) => rootOf(t.terminalId, t.cwd)),
    ].filter(Boolean) as string[],
  )
  const ambiguous = allRoots.size > 1
  const hueStyle = (hue: string) => ({ '--sid': hue } as CSSProperties)

  const renameInput = (
    <input
      className="thread-rename"
      value={editValue}
      autoFocus
      onChange={(e) => setEditValue(e.target.value)}
      onBlur={commitRename}
      onKeyDown={(e) => { if (e.key === 'Enter') commitRename(); if (e.key === 'Escape') setEditing(null) }}
    />
  )
  // the little window figure toggles the session's CARD — open it beside the
  // others, or put it away (the session itself stays alive)
  const cardToggle = (id: string) => (
    <button
      className="session-split"
      data-on={isActive(id)}
      onClick={() => (isActive(id) ? removeDockView(id) : addDockSplit(id))}
      title={isActive(id) ? 'Close this card' : 'Open as a card'}
    >
      <Icon name="Columns2" size={11} />
    </button>
  )
  return (
    <div className="side-sessions">
      <div className="session-list">
        {(() => {
          const onSessionMenu = (e: React.MouseEvent, id: string) => {
            e.preventDefault()
            e.stopPropagation()
            setSessionMenu({ x: e.clientX, y: e.clientY, id })
          }
          const threadRows = threads.map((t, i) => {
            const nm = agentName(agents, t.agentKey) ?? 'Agent'
            const label = t.name ?? t.autoName ?? `${nm}${threads.filter((x) => x.agentKey === t.agentKey).length > 1 ? ` ${i + 1}` : ''}`
            return {
              id: t.id,
              node: (
                <div
                  key={t.id}
                  className="session-row"
                  data-active={isActive(t.id)}
                  style={hueStyle(sessionHue({ agentKey: t.agentKey }))}
                  draggable={editing?.id !== t.id}
                  onDragStart={() => (dragRef.current = t.id)}
                  onDragOver={(e) => e.preventDefault()}
                  onDrop={() => { if (dragRef.current) reorderThreads(dragRef.current, t.id); dragRef.current = null }}
                  onContextMenu={(e) => onSessionMenu(e, t.id)}
                >
                  {editing?.id === t.id ? renameInput : (
                    <button
                      className="session-main"
                      onClick={() => setActiveThread(t.id)}
                      onDoubleClick={() => { setEditing({ id: t.id, kind: 'thread' }); setEditValue(label) }}
                      title="Double-click to rename · drag to reorder · right-click to group"
                    >
                      <Icon name="Sparkles" size={13} className="session-icon" />
                      <span className="grow truncate">{label}</span>
                      {needsYou[t.id] && <span className="session-needs" title="Waiting on you" />}
                      {t.busy && <span className="session-busy" aria-label="working" />}
                    </button>
                  )}
                  {cardToggle(t.id)}
                  {!pinnedSessions.includes(t.id) && (
                    <button className="session-close" onClick={() => closeThread(t.id)} title="Close">
                      <Icon name="X" size={11} />
                    </button>
                  )}
                </div>
              ),
            }
          })
          const termRows = terminals.map((t, i) => {
            const meta = terminalMeta[t.id]
            const agentKey = terminalAgentKey(t.singletonKey)
            // stable identity, never keystrokes: manual name → agent → repo → folder
            const folder = meta?.repo ?? (meta?.cwd ?? t.cwd)?.split('/').filter(Boolean).pop()
            const label =
              t.name ??
              (agentKey ? agentName(agents, agentKey) ?? agentKey : undefined) ??
              folder ??
              (terminals.length > 1 ? `Terminal ${i + 1}` : 'Terminal')
            const hue = sessionHue({ agentKey, folder: meta?.root ?? meta?.cwd ?? t.cwd })
            const failed = !meta?.running && (meta?.lastExit ?? 0) > 0
            const title = [
              meta?.running && meta.fgProcess ? `running ${meta.fgProcess}` : null,
              meta?.repo && `${meta.repo}${meta.branch ? ` ⎇ ${meta.branch}` : ''}`,
              meta?.cwd,
              'Double-click to rename',
            ]
              .filter(Boolean)
              .join(' · ')
            return {
              id: t.id,
              node: (
                <div key={t.id} className="session-row" data-active={isActive(t.id)} style={hueStyle(hue)} onContextMenu={(e) => onSessionMenu(e, t.id)}>
                  {editing?.id === t.id ? renameInput : (
                    <button
                      className="session-main"
                      onClick={() => setDockView(t.id)}
                      onDoubleClick={() => { setEditing({ id: t.id, kind: 'term' }); setEditValue(label) }}
                      title={title}
                    >
                      <Icon name="SquareTerminal" size={13} className="session-icon" />
                      <span className="grow truncate">
                        {label}
                        {worktreeSessions[t.id] && <span className="session-repo"> ⎇ {worktreeSessions[t.id].branch}</span>}
                        {ambiguous && meta?.repo && meta.repo !== label && <span className="session-repo"> · {meta.repo}</span>}
                      </span>
                      {needsYou[t.id] && <span className="session-needs" title="Waiting on you" />}
                      {meta?.running && <span className="session-busy" aria-label="running" />}
                      {failed && <span className="session-fail" aria-label="last command failed" />}
                    </button>
                  )}
                  {cardToggle(t.id)}
                  {terminals.length > 1 && !pinnedSessions.includes(t.id) && (
                    <button
                      className="session-close"
                      // no immediate kill: the store gives the pty a 60s grace
                      // so ⌘⇧T can bring the whole session back
                      onClick={() => closeTerminal(t.id)}
                      title="Close · ⌘⇧T reopens"
                    >
                      <Icon name="X" size={11} />
                    </button>
                  )}
                </div>
              ),
            }
          })
          const agentTermRows = agentTerminals.map((t) => ({
            id: t.terminalId,
            node: (
              <div
                key={t.terminalId}
                className="session-row"
                data-active={isActive(t.terminalId)}
                style={hueStyle(sessionHue({ agentKey: t.agentKey, folder: terminalMeta[t.terminalId]?.root ?? t.cwd }))}
                onContextMenu={(e) => onSessionMenu(e, t.terminalId)}
              >
                <button className="session-main" onClick={() => setDockView(t.terminalId)} title={`${t.agentName ?? 'agent'}: ${t.command ?? ''}`}>
                  <span className="agent-run-dot" />
                  <span className="grow truncate">
                    {t.label || 'agent'}
                    {ambiguous && terminalMeta[t.terminalId]?.repo && <span className="session-repo"> · {terminalMeta[t.terminalId]?.repo}</span>}
                  </span>
                </button>
                {cardToggle(t.terminalId)}
                <button
                  className="session-close"
                  onClick={() => { closeAgentTerminal(t.terminalId); bridge.terminal.kill(t.terminalId) }}
                  title="Close"
                >
                  <Icon name="X" size={11} />
                </button>
              </div>
            ),
          }))
          const panelRows = panels.map((p) => {
            const label = p.kind === 'git' ? 'Commit' : p.title ?? urlHost(p.url) ?? 'Browser'
            const hue = p.kind === 'git'
              ? sessionHue({ agentKey: 'git', folder: workspacePath })
              : sessionHue({ agentKey: urlHost(p.url) ?? 'browser' })
            return {
              id: p.id,
              node: (
                <div key={p.id} className="session-row" data-active={isActive(p.id)} style={hueStyle(hue)} onContextMenu={(e) => onSessionMenu(e, p.id)}>
                  <button className="session-main" onClick={() => setDockView(p.id)} title={p.kind === 'git' ? 'Stage & commit' : p.url ?? 'Browser'}>
                    <Icon name={p.kind === 'git' ? 'GitCommitHorizontal' : 'Globe'} size={13} className="session-icon" />
                    <span className="grow truncate">{label}</span>
                    {needsYou[p.id] && <span className="session-needs" title="Waiting on you" />}
                  </button>
                  {cardToggle(p.id)}
                  {!pinnedSessions.includes(p.id) && (
                    <button className="session-close" onClick={() => closePanel(p.id)} title="Close">
                      <Icon name="X" size={11} />
                    </button>
                  )}
                </div>
              ),
            }
          })

          // Chrome-style order: pinned first, then colored collapsible groups,
          // then the rest. NO attention-reordering — the amber dot is the
          // signal (reordering would break the rail = ⌘1-9 = Ctrl+Tab
          // invariant, and Chrome badges tabs without moving them)
          const allRows = [...threadRows, ...termRows, ...agentTermRows, ...panelRows]
          const rowMap = new Map(allRows.map((r) => [r.id, r.node]))
          const pinned = pinnedSessions.filter((id) => rowMap.has(id))
          const grouped = new Set(sessionGroups.flatMap((g) => g.members).filter((id) => !pinned.includes(id)))
          const restSorted = allRows.filter((r) => !grouped.has(r.id) && !pinned.includes(r.id))
          return (
            <>
              {pinned.length > 0 && (
                <div className="session-pinned">
                  {pinned.map((id) => rowMap.get(id))}
                </div>
              )}
              {sessionGroups.map((g) => {
                const members = g.members.filter((id) => rowMap.has(id) && !pinned.includes(id))
                if (!members.length) return null
                const color = g.color ?? sessionHue({ folder: g.name })
                return (
                  <div key={g.id} className="session-group" style={hueStyle(color)}>
                    <div
                      className="session-group-head"
                      onClick={() => toggleSessionGroupCollapsed(g.id)}
                      onDoubleClick={() => { setEditing({ id: g.id, kind: 'group' }); setEditValue(g.name) }}
                      title="Click to collapse · double-click to rename"
                    >
                      <Icon name={g.collapsed ? 'ChevronRight' : 'ChevronDown'} size={10} className="session-group-caret" />
                      <button
                        className="session-group-dot"
                        onClick={(e) => {
                          // the dot cycles the Chrome-style palette (then back to auto)
                          e.stopPropagation()
                          const at = g.color ? GROUP_COLORS.indexOf(g.color) : -1
                          setSessionGroupColor(g.id, at + 1 >= GROUP_COLORS.length ? undefined : GROUP_COLORS[at + 1])
                        }}
                        title="Change group color"
                      />
                      {editing?.id === g.id ? renameInput : <span className="truncate">{g.name}</span>}
                      <span className="session-group-count">{members.length}</span>
                      <button
                        className="session-close session-group-x"
                        onClick={(e) => { e.stopPropagation(); removeSessionGroup(g.id) }}
                        title="Ungroup (sessions stay)"
                      >
                        <Icon name="X" size={10} />
                      </button>
                    </div>
                    {!g.collapsed && members.map((id) => rowMap.get(id))}
                  </div>
                )
              })}
              {restSorted.map((r) => r.node)}
            </>
          )
        })()}
      </div>
      {sessionMenu && (
        <div className="tree-menu-overlay" onMouseDown={() => setSessionMenu(null)} onContextMenu={(e) => { e.preventDefault(); setSessionMenu(null) }}>
          <div
            className="tree-menu"
            style={{ left: Math.min(sessionMenu.x, window.innerWidth - 220), top: Math.min(sessionMenu.y, window.innerHeight - 200) }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            <button className="tree-menu-item" onClick={() => { togglePinSession(sessionMenu.id); setSessionMenu(null) }}>
              <Icon name={pinnedSessions.includes(sessionMenu.id) ? 'PinOff' : 'Pin'} size={13} />
              {pinnedSessions.includes(sessionMenu.id) ? 'Unpin' : 'Pin'}
            </button>
            <button className="tree-menu-item" onClick={() => { saveSessionTemplate(sessionMenu.id); setSessionMenu(null) }}>
              <Icon name="BookmarkPlus" size={13} /> Save as template
            </button>
            <div className="tree-menu-sep" />
            {sessionGroups
              .filter((g) => !g.members.includes(sessionMenu.id))
              .map((g) => (
                <button key={g.id} className="tree-menu-item" onClick={() => { assignToGroup(sessionMenu.id, g.id); setSessionMenu(null) }}>
                  <Icon name="FolderInput" size={13} /> Move to “{g.name}”
                </button>
              ))}
            <button
              className="tree-menu-item"
              onClick={() => { createSessionGroup(`Group ${sessionGroups.length + 1}`, [sessionMenu.id]); setSessionMenu(null) }}
            >
              <Icon name="FolderPlus" size={13} /> New group
            </button>
            {sessionGroups.some((g) => g.members.includes(sessionMenu.id)) && (
              <button className="tree-menu-item" onClick={() => { assignToGroup(sessionMenu.id, null); setSessionMenu(null) }}>
                <Icon name="FolderMinus" size={13} /> Remove from group
              </button>
            )}
            {worktreeSessions[sessionMenu.id] && (
              <>
                <div className="tree-menu-sep" />
                <button className="tree-menu-item" onClick={() => { void mergeWorktreeSession(sessionMenu.id); setSessionMenu(null) }}>
                  <Icon name="GitMerge" size={13} /> Merge worktree back
                </button>
                <button className="tree-menu-item tree-menu-danger" onClick={() => { void removeWorktreeSession(sessionMenu.id); setSessionMenu(null) }}>
                  <Icon name="Trash2" size={13} /> Remove worktree
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

/** One right-click menu invocation: what it targets and where it floats. */
interface TreeMenuState {
  x: number
  y: number
  path: string
  isDir: boolean
  isRoot: boolean
}

/**
 * The workspace tree. Click a file to preview it (transient tab), double-click
 * to pin & edit; the root row switches folders. Inline git status tints names
 * (Zed-style), chains of single-child folders fold into one row, and the
 * right-click menu covers file management without leaving the rail.
 */
function FilesTree() {
  const workspacePath = useKaisola((s) => s.workspacePath)
  const setWorkspace = useKaisola((s) => s.setWorkspace)
  const requestFile = useKaisola((s) => s.requestFile)
  const openFilePath = useKaisola((s) => s.openFilePath)
  const pushToast = useKaisola((s) => s.pushToast)

  const [children, setChildren] = useState<Record<string, FsEntry[]>>({})
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<FsEntry[]>([])
  const [searching, setSearching] = useState(false)
  const [truncated, setTruncated] = useState(false)
  const [watchSeq, setWatchSeq] = useState(0)
  const [gitBranch, setGitBranch] = useState<string | null>(null)
  const [gitCodes, setGitCodes] = useState<Map<string, string>>(new Map())
  const [gitDirs, setGitDirs] = useState<Set<string>>(new Set())
  const [menu, setMenu] = useState<TreeMenuState | null>(null)
  const [naming, setNaming] = useState<{ mode: 'newfile' | 'newfolder' | 'rename'; target: string; isDir: boolean } | null>(null)
  const [nameValue, setNameValue] = useState('')
  const expandedRef = useRef(expanded)
  const childrenRef = useRef(children)

  const loadDir = useCallback(async (dir: string) => {
    const r = await bridge.fs.list(dir)
    if (r.ok && r.entries) {
      setChildren((c) => ({ ...c, [dir]: r.entries! }))
      // single-child chains prefetch one level so folded rows resolve eagerly
      if (r.entries.length === 1 && r.entries[0].dir && !childrenRef.current[r.entries[0].path]) {
        void loadDir(r.entries[0].path)
      }
    } else setChildren((c) => {
      const next = { ...c }
      delete next[dir]
      return next
    })
  }, [])

  // git status → per-path codes + per-dir "contains changes" markers
  useEffect(() => {
    if (!workspacePath || !isDesktop) {
      setGitBranch(null)
      setGitCodes(new Map())
      setGitDirs(new Set())
      return
    }
    let cancelled = false
    const timer = window.setTimeout(async () => {
      const r = await bridge.git.status(workspacePath)
      if (cancelled) return
      if (!r.ok || !r.entries) {
        setGitBranch(null)
        setGitCodes(new Map())
        setGitDirs(new Set())
        return
      }
      setGitBranch(r.branch ?? null)
      const codes = new Map<string, string>()
      const dirs = new Set<string>()
      for (const e of r.entries) {
        codes.set(e.path, e.code)
        // mark every ancestor dir so collapsed folders still show the signal
        let parent = e.path
        while (parent.includes('/') && parent.length > workspacePath.length) {
          parent = parent.slice(0, parent.lastIndexOf('/'))
          if (parent.length >= workspacePath.length) dirs.add(parent)
        }
      }
      setGitCodes(codes)
      setGitDirs(dirs)
    }, 350)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [workspacePath, watchSeq])

  useEffect(() => { expandedRef.current = expanded }, [expanded])
  useEffect(() => { childrenRef.current = children }, [children])

  useEffect(() => {
    if (!workspacePath || !isDesktop) return
    return bridge.fs.watch(workspacePath, () => setWatchSeq((n) => n + 1))
  }, [workspacePath])

  useEffect(() => {
    setChildren({})
    setExpanded(new Set())
    setQuery('')
    setResults([])
    if (workspacePath) loadDir(workspacePath)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loadDir, workspacePath])

  useEffect(() => {
    if (!workspacePath || watchSeq === 0) return
    const dirs = new Set<string>([workspacePath])
    for (const dir of expandedRef.current) {
      if (childrenRef.current[dir]) dirs.add(dir)
    }
    dirs.forEach((dir) => { void loadDir(dir) })
  }, [loadDir, watchSeq, workspacePath])

  useEffect(() => {
    if (!workspacePath || !query.trim()) {
      setResults([])
      setSearching(false)
      setTruncated(false)
      return
    }
    let cancelled = false
    setSearching(true)
    const timer = window.setTimeout(async () => {
      const r = await bridge.fs.search(workspacePath, query)
      if (cancelled) return
      setSearching(false)
      setResults(r.ok ? r.entries ?? [] : [])
      setTruncated(!!r.truncated)
    }, 180)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [query, watchSeq, workspacePath])

  const toggle = (dir: string) =>
    setExpanded((e) => {
      const n = new Set(e)
      if (n.has(dir)) n.delete(dir)
      else { n.add(dir); if (!children[dir]) loadDir(dir) }
      return n
    })

  const changeFolder = async () => {
    if (useKaisola.getState().fileDirty && !window.confirm('Discard unsaved changes to the open file?')) return
    const r = await bridge.pickFolder()
    if (r.ok && r.path) setWorkspace(r.path)
  }

  const relativePath = (p: string) =>
    workspacePath && p.startsWith(`${workspacePath}/`) ? p.slice(workspacePath.length + 1) : p

  /** M = modified (amber) · A/? = new (green) — Zed-style name tinting. */
  const gitTint = (e: FsEntry): string | undefined => {
    if (e.dir) return gitDirs.has(e.path) ? 'dir' : undefined
    const code = gitCodes.get(e.path)
    if (!code) return undefined
    return code === '?' || code === 'A' ? 'added' : 'modified'
  }

  // ── context-menu file operations ──
  const parentOf = (p: string) => p.slice(0, p.lastIndexOf('/')) || '/'
  const closeMenu = () => { setMenu(null); setNaming(null); setNameValue('') }
  const refreshAround = (p: string) => {
    void loadDir(parentOf(p))
    if (childrenRef.current[p]) void loadDir(p)
  }
  const submitName = async () => {
    if (!naming) return
    const name = nameValue.trim()
    if (!name || name.includes('/')) { closeMenu(); return }
    if (naming.mode === 'rename') {
      const to = `${parentOf(naming.target)}/${name}`
      const r = await bridge.fs.rename(naming.target, to)
      if (!r.ok) pushToast('error', r.message ?? 'Rename failed.')
      refreshAround(naming.target)
    } else {
      const base = naming.isDir ? naming.target : parentOf(naming.target)
      const r = await bridge.fs.create(`${base}/${name}`, naming.mode === 'newfolder')
      if (!r.ok) pushToast('error', r.message ?? 'Could not create.')
      else if (naming.mode === 'newfile') requestFile(`${base}/${name}`, 'edit', { pinned: true })
      void loadDir(base)
      setExpanded((ex) => new Set(ex).add(base))
    }
    closeMenu()
  }
  const trashEntry = async (p: string) => {
    const r = await bridge.fs.trash(p)
    if (r.ok) pushToast('success', `Moved ${p.split('/').pop()} to Trash`)
    else pushToast('error', r.message ?? 'Could not delete.')
    refreshAround(p)
    closeMenu()
  }

  const onRowMenu = (e: React.MouseEvent, entry: { path: string; dir: boolean; root?: boolean }) => {
    e.preventDefault()
    e.stopPropagation()
    setNaming(null)
    setMenu({ x: e.clientX, y: e.clientY, path: entry.path, isDir: entry.dir, isRoot: !!entry.root })
  }

  /** Fold chains of single-child directories into one row (Zed's auto_fold_dirs). */
  const foldChain = (e: FsEntry): { label: string; tail: FsEntry } => {
    let label = e.name
    let tail = e
    while (true) {
      const kids = children[tail.path]
      if (!kids || kids.length !== 1 || !kids[0].dir) break
      tail = kids[0]
      label += `/${tail.name}`
      if (!children[tail.path]) void loadDir(tail.path)
    }
    return { label, tail }
  }

  const renderDir = (dir: string, depth: number): React.ReactNode =>
    (children[dir] ?? []).map((e) => {
      const fold = e.dir ? foldChain(e) : null
      const rowEntry = fold ? fold.tail : e
      const tint = gitTint(e.dir ? rowEntry : e)
      return (
        <div key={e.path}>
          <button
            className="fx-row"
            style={{ paddingLeft: depth * 13 + 8 }}
            data-active={openFilePath === e.path}
            data-git={tint}
            onClick={() => (e.dir ? toggle(rowEntry.path) : requestFile(e.path))}
            onDoubleClick={() => { if (!e.dir) requestFile(e.path, 'edit', { pinned: true }) }}
            onContextMenu={(ev) => onRowMenu(ev, { path: rowEntry.path, dir: e.dir })}
            title={e.dir ? fold!.label : `${e.name} — click previews · double-click pins & edits`}
          >
            {e.dir
              ? <Icon name={expanded.has(rowEntry.path) ? 'ChevronDown' : 'ChevronRight'} size={12} className="fx-caret" />
              : <span className="fx-caret" />}
            <Icon name={e.dir ? (expanded.has(rowEntry.path) ? 'FolderOpen' : 'Folder') : fileIcon(e.name)} size={13} className="fx-icon" />
            <span className="truncate">{fold ? fold.label : e.name}</span>
            {tint === 'dir' && <span className="fx-git-dot" aria-label="contains changes" />}
          </button>
          {e.dir && expanded.has(rowEntry.path) && renderDir(rowEntry.path, depth + 1)}
        </div>
      )
    })

  if (!isDesktop) return null

  return (
    <div className="wsrail-files">
      {workspacePath ? (
        <>
          <button
            className="fx-root"
            onClick={changeFolder}
            onContextMenu={(ev) => onRowMenu(ev, { path: workspacePath, dir: true, root: true })}
            title={`${workspacePath}${gitBranch ? ` · ${gitBranch}` : ''} — click to change folder`}
          >
            <Icon name="Folder" size={13} className="fx-icon" />
            <span className="truncate">{workspacePath.split('/').filter(Boolean).pop()}</span>
            {gitBranch && (
              <span className="fx-branch">
                <Icon name="GitBranch" size={10} />
                {gitBranch}
              </span>
            )}
            <Icon name="ChevronsUpDown" size={11} className="fx-root-switch" />
          </button>
          <label className="fx-rail-search">
            <Icon name="Search" size={12} />
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search files" spellCheck={false} />
            {query && <button onClick={() => setQuery('')} title="Clear"><Icon name="X" size={11} /></button>}
          </label>
          {query.trim() ? (
            <div className="fx-rail-results">
              {searching ? (
                <div className="fx-rail-empty">Searching...</div>
              ) : results.length ? (
                <>
                  {results.map((e) => (
                    <button
                      key={e.path}
                      className="fx-row"
                      data-active={openFilePath === e.path}
                      onClick={() => requestFile(e.path)}
                      onDoubleClick={() => requestFile(e.path, 'edit')}
                      title={`${relativePath(e.path)} — double-click to edit`}
                    >
                      <span className="fx-caret" />
                      <Icon name={fileIcon(e.name)} size={13} className="fx-icon" />
                      <span className="truncate">{e.name}</span>
                    </button>
                  ))}
                  {truncated && <div className="fx-rail-empty">Showing first {results.length} matches.</div>}
                </>
              ) : (
                <div className="fx-rail-empty">No matches.</div>
              )}
            </div>
          ) : renderDir(workspacePath, 0)}
        </>
      ) : (
        <button className="btn btn-sm wsrail-open" onClick={changeFolder}>
          <Icon name="FolderOpen" size={13} /> Open folder
        </button>
      )}

      {menu && (
        <div className="tree-menu-overlay" onMouseDown={closeMenu} onContextMenu={(e) => { e.preventDefault(); closeMenu() }}>
          <div
            className="tree-menu"
            style={{ left: Math.min(menu.x, window.innerWidth - 230), top: Math.min(menu.y, window.innerHeight - 260) }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            {naming ? (
              <div className="tree-menu-name">
                <input
                  autoFocus
                  value={nameValue}
                  placeholder={naming.mode === 'rename' ? 'New name' : naming.mode === 'newfolder' ? 'Folder name' : 'File name'}
                  onChange={(e) => setNameValue(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') void submitName()
                    if (e.key === 'Escape') closeMenu()
                  }}
                  spellCheck={false}
                />
                <button onClick={() => void submitName()} title="Confirm"><Icon name="Check" size={12} /></button>
              </div>
            ) : (
              <>
                <button className="tree-menu-item" onClick={() => { setNaming({ mode: 'newfile', target: menu.path, isDir: menu.isDir }); setNameValue('') }}>
                  <Icon name="FilePlus2" size={13} /> New file…
                </button>
                <button className="tree-menu-item" onClick={() => { setNaming({ mode: 'newfolder', target: menu.path, isDir: menu.isDir }); setNameValue('') }}>
                  <Icon name="FolderPlus" size={13} /> New folder…
                </button>
                {!menu.isRoot && (
                  <>
                    <div className="tree-menu-sep" />
                    <button className="tree-menu-item" onClick={() => { setNaming({ mode: 'rename', target: menu.path, isDir: menu.isDir }); setNameValue(menu.path.split('/').pop() ?? '') }}>
                      <Icon name="PenLine" size={13} /> Rename…
                    </button>
                    <button className="tree-menu-item tree-menu-danger" onClick={() => void trashEntry(menu.path)}>
                      <Icon name="Trash2" size={13} /> Move to Trash
                    </button>
                  </>
                )}
                <div className="tree-menu-sep" />
                <button className="tree-menu-item" onClick={() => { void navigator.clipboard.writeText(menu.path); closeMenu() }}>
                  <Icon name="Copy" size={13} /> Copy path
                </button>
                {!menu.isRoot && (
                  <button className="tree-menu-item" onClick={() => { void navigator.clipboard.writeText(relativePath(menu.path)); closeMenu() }}>
                    <Icon name="Copy" size={13} /> Copy relative path
                  </button>
                )}
                <button className="tree-menu-item" onClick={() => { void bridge.fs.reveal(menu.path); closeMenu() }}>
                  <Icon name="Eye" size={13} /> Reveal in Finder
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
