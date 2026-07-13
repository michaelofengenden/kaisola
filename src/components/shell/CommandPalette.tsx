import { useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import { useKaisola, sessionOrderIds, type PaletteMode } from '../../store/store'
import { bridge, isDesktop } from '../../lib/bridge'
import { AGENTS } from '../../agents/registry'
import { fuzzyRank, highlightRuns } from '../../lib/fuzzy'
import { openConfigFile } from '../../lib/userConfig'
import { fileIcon } from '../../lib/fileIcon'
import { Icon } from '../Icon'
import { relTime } from '../../lib/format'
import { terminalLabel } from '@/lib/sessionLabel'
import { openExtensionsCenter } from '../../lib/extensions'

interface Command {
  id: string
  group: string
  label: string
  hint?: string
  icon: string
  run: () => void
}

const PALETTE_DIALOG_STYLE = {
  width: '100vw',
  maxWidth: 'none',
  height: '100vh',
  maxHeight: 'none',
  margin: 0,
  border: 'none',
  padding: '14vh 0 0',
} satisfies CSSProperties

/** Matched-character emphasis for fuzzy results. */
function Runs({ text, indices }: { text: string; indices: number[] }) {
  return (
    <>
      {highlightRuns(text, indices).map((r, i) =>
        r.hit ? <b key={i} className="palette-match">{r.text}</b> : <span key={i}>{r.text}</span>,
      )}
    </>
  )
}

/**
 * The palette: one surface, two modes. ⌘K = commands, ⌘P = the fuzzy file
 * finder (the primary way to open files — the tree is for orientation).
 * Enter opens a transient preview tab; ⌘Enter opens pinned, in edit mode.
 */
export function CommandPalette() {
  const open = useKaisola((s) => s.paletteOpen)
  const mode = useKaisola((s) => s.paletteMode)
  const close = useKaisola((s) => s.closePalette)
  const togglePalette = useKaisola((s) => s.togglePalette)
  const toggleTheme = useKaisola((s) => s.toggleTheme)
  const setLayoutMode = useKaisola((s) => s.setLayoutMode)
  const layoutMode = useKaisola((s) => s.layoutMode)
  const canvasOpen = useKaisola((s) => s.canvasOpen)
  const setDock = useKaisola((s) => s.setDock)
  const toggleCanvas = useKaisola((s) => s.toggleCanvas)
  const railOpen = useKaisola((s) => s.railOpen)
  const toggleRail = useKaisola((s) => s.toggleRail)
  const setTabLayout = useKaisola((s) => s.setTabLayout)
  const runAgent = useKaisola((s) => s.runAgent)
  const runStageAgents = useKaisola((s) => s.runStageAgents)
  const enqueueStageAgents = useKaisola((s) => s.enqueueStageAgents)
  const workflows = useKaisola((s) => s.workflows)
  const runWorkflow = useKaisola((s) => s.runWorkflow)
  const verifyCitations = useKaisola((s) => s.verifyCitations)
  const buildCitationGraph = useKaisola((s) => s.buildCitationGraph)
  const ingestAllPdfs = useKaisola((s) => s.ingestAllPdfs)
  const setAutonomy = useKaisola((s) => s.setAutonomy)
  const loadDemo = useKaisola((s) => s.loadDemo)
  const clearProject = useKaisola((s) => s.clearProject)
  const checkpoints = useKaisola((s) => s.checkpoints)
  const undoLast = useKaisola((s) => s.undoLast)
  const restoreCheckpoint = useKaisola((s) => s.restoreCheckpoint)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const requestFile = useKaisola((s) => s.requestFile)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const fileTabs = useKaisola((s) => s.fileTabs)
  const openFilePath = useKaisola((s) => s.openFilePath)
  const repoCheckpoints = useKaisola((s) => s.repoCheckpoints)
  const snapshotWorkspace = useKaisola((s) => s.snapshotWorkspace)
  const restoreRepoCheckpoint = useKaisola((s) => s.restoreRepoCheckpoint)
  const followAgent = useKaisola((s) => s.followAgent)
  const toggleFollowAgent = useKaisola((s) => s.toggleFollowAgent)
  const pushToast = useKaisola((s) => s.pushToast)
  const proposals = useKaisola((s) => s.project.proposals)
  const focusProposal = useKaisola((s) => s.focusProposal)

  const [q, setQ] = useState('')
  const [active, setActive] = useState(0)
  const [files, setFiles] = useState<string[]>([])
  const [filesTruncated, setFilesTruncated] = useState(false)
  const [backlogPath, setBacklogPath] = useState<string | null>(null)
  const dialogRef = useRef<HTMLDialogElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  // ⌘K commands · ⌘P files — anywhere in the app
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return
      const k = e.key.toLowerCase()
      if (k === 'k') { e.preventDefault(); togglePalette('commands') }
      else if (k === 'p' && !e.shiftKey) { e.preventDefault(); togglePalette('files') }
      else if (k === 'p' && e.shiftKey) { e.preventDefault(); togglePalette('commands') }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [togglePalette])

  useEffect(() => {
    if (open) {
      const dialog = dialogRef.current
      const onBackdropMouseDown = (event: MouseEvent) => {
        if (event.target === dialog) close()
      }
      dialog?.addEventListener('mousedown', onBackdropMouseDown)
      if (dialog && !dialog.open) dialog.showModal()
      setQ('')
      setActive(0)
      const focusTimer = setTimeout(() => inputRef.current?.focus(), 0)
      return () => {
        clearTimeout(focusTimer)
        dialog?.removeEventListener('mousedown', onBackdropMouseDown)
        if (dialog?.open) dialog.close()
      }
    }
  }, [open, mode, close])

  // the file finder's candidate set: one walk per palette-open, matched locally
  useEffect(() => {
    if (!open || mode !== 'files' || !workspacePath || !isDesktop) return
    let cancelled = false
    bridge.fs.index(workspacePath).then((r) => {
      if (cancelled || !r.ok) return
      setFiles(r.files ?? [])
      setFilesTruncated(!!r.truncated)
    })
    return () => { cancelled = true }
  }, [open, mode, workspacePath])

  // the backlog is a per-project convention — only offer the command where
  // docs/BACKLOG.md actually exists
  useEffect(() => {
    if (!open || mode !== 'commands' || !workspacePath || !isDesktop) return
    let cancelled = false
    const p = `${workspacePath}/docs/BACKLOG.md`
    bridge.fs.read(p)
      .then((r) => { if (!cancelled) setBacklogPath(r.ok ? p : null) })
      .catch(() => { if (!cancelled) setBacklogPath(null) })
    return () => { cancelled = true }
  }, [open, mode, workspacePath])

  const commands = useMemo<Command[]>(() => {
    // sessions in RAIL order (pinned → grouped → rest) — mirrors ⌘1..9
    const st = useKaisola.getState()
    const naturalSessions: { id: string; label: string; icon: string }[] = [
      ...st.assistantThreads.map((t) => ({ id: t.id, label: t.name ?? t.autoName ?? 'Agent', icon: 'Sparkles' })),
      ...st.terminals.map((t, i) => ({
        id: t.id,
        label: terminalLabel(t, { meta: st.terminalMeta[t.id], index: i, count: st.terminals.length }),
        icon: 'SquareTerminal',
      })),
      ...st.agentTerminals.map((t) => ({ id: t.terminalId, label: t.label || 'agent', icon: 'SquareTerminal' })),
      ...st.panels.map((p) => ({
        id: p.id,
        label: p.kind === 'git' ? 'Commit' : p.title ?? p.url ?? 'Browser',
        icon: p.kind === 'git' ? 'GitCommitHorizontal' : 'Globe',
      })),
    ]
    const byId = new Map(naturalSessions.map((x) => [x.id, x]))
    const sessionEntries = sessionOrderIds(st).flatMap((id) => {
      const session = byId.get(id)
      return session ? [session] : []
    })
    const supervise: Command = {
      id: 'run-stage',
      group: 'Run agent',
      label: 'Run agents for this stage',
      hint: 'Sequence the right agents for the current stage',
      icon: 'Workflow',
      run: () => { void runStageAgents().catch(() => {}); close() },
    }
    const queueStage: Command = {
      id: 'queue-stage',
      group: 'Run agent',
      label: 'Queue stage agents (background)',
      hint: 'Run them in the inbox without blocking',
      icon: 'ListPlus',
      run: () => { enqueueStageAgents(); close() },
    }
    const bestOf: Command = {
      id: 'queue-bestof',
      group: 'Run agent',
      label: 'Best-of-3 for this stage (3× cost)',
      hint: 'Three competing attempts — pick the winner in Review',
      icon: 'Copy',
      run: () => { enqueueStageAgents(undefined, { count: 3 }); close() },
    }
    const agents: Command[] = [supervise, queueStage, bestOf, ...AGENTS.map((a) => ({
      id: `agent-${a.meta.id}`,
      group: 'Run agent',
      label: `Run ${a.meta.name} agent`,
      hint: a.meta.role,
      icon: a.meta.icon,
      run: () => {
        void runAgent(a.meta.id).catch(() => {})
        close()
      },
    }))]
    const nav: Command[] = [
      { id: 'go-file', group: 'Navigate', label: 'Go to file…', hint: '⌘P', icon: 'FileSearch', run: () => togglePalette('files') },
      ...(backlogPath ? [{
        id: 'backlog',
        group: 'Navigate',
        label: 'Backlog',
        hint: 'docs/BACKLOG.md — drop screenshots/videos while editing',
        icon: 'ListChecks',
        run: () => { requestFile(backlogPath); close() },
      } satisfies Command] : []),
      { id: 'extensions', group: 'Navigate', label: 'Extensions', hint: 'Languages, previews, and MCP servers', icon: 'Blocks', run: () => { close(); openExtensionsCenter() } },
      { id: 'new-terminal', group: 'Navigate', label: 'New terminal', icon: 'SquareTerminal', run: () => { requestTerminal(undefined, { cwd: workspacePath ?? undefined }); close() } },
      { id: 'git-panel', group: 'Navigate', label: 'Git: stage & commit', hint: 'Side-by-side diffs, without leaving the window', icon: 'GitCommitHorizontal', run: () => { useKaisola.getState().openGitPanel(); close() } },
      { id: 'ledger-panel', group: 'Navigate', label: 'Agent tasks', hint: 'The shared ledger — what agents posted, claimed, finished', icon: 'ListTodo', run: () => { useKaisola.getState().openLedgerPanel(); close() } },
      { id: 'new-browser', group: 'Navigate', label: 'New browser card', hint: 'Preview a dev server beside its terminal', icon: 'Globe', run: () => { useKaisola.getState().openBrowserPanel(); close() } },
      {
        id: 'latex-mode',
        group: 'Navigate',
        label: useKaisola.getState().latexMode ? 'Leave LaTeX mode' : 'Enter LaTeX mode',
        hint: 'Build the paper · inspect PDFs',
        icon: 'Sigma',
        run: () => { const s = useKaisola.getState(); s.setLatexMode(!s.latexMode); close() },
      },
      { id: 'wt-session', group: 'Navigate', label: 'New agent in a fresh worktree', hint: 'Isolated checkout — merge back when it’s good', icon: 'GitBranchPlus', run: () => { void useKaisola.getState().newWorktreeSession(); close() } },
      // worktrees whose session was closed still exist on disk — offer cleanup
      ...Object.entries(st.worktreeSessions).flatMap(([sid, wt]) => {
        if (st.terminals.some((t) => t.id === sid) || st.assistantThreads.some((t) => t.id === sid)) return []
        return [{
          id: `wt-orphan-${sid}`,
          group: 'Navigate',
          label: `Remove leftover worktree ⎇ ${wt.branch}`,
          hint: wt.path,
          icon: 'Trash2',
          run: () => {
            void bridge.worktree.remove({ taskId: wt.taskId, repo: wt.repo }).then((result) => {
              if (!result.ok) {
                useKaisola.getState().pushToast('error', result.message ?? `Could not remove the ${wt.branch} worktree.`)
                return
              }
              useKaisola.setState((s) => {
                const worktreeSessions = { ...s.worktreeSessions }
                delete worktreeSessions[sid]
                return { worktreeSessions }
              })
              useKaisola.getState().pushToast('success', `Removed the ${wt.branch} worktree.`)
            })
            close()
          },
        }]
      }),
      ...(st.closedStack.length
        ? [{ id: 'reopen', group: 'Navigate', label: 'Reopen closed session', hint: '⌘⇧T', icon: 'Undo2', run: () => { useKaisola.getState().reopenClosedSession(); close() } }]
        : []),
      ...(isDesktop
        ? [
            { id: 'cfg-settings', group: 'Navigate', label: 'Open settings file (JSON)', hint: 'settings.json — applied on save', icon: 'Braces', run: () => { void openConfigFile('settings'); close() } },
            { id: 'cfg-keymap', group: 'Navigate', label: 'Open keymap file (JSON)', hint: 'keymap.json — rebind or disable chords', icon: 'Keyboard', run: () => { void openConfigFile('keymap'); close() } },
          ]
        : []),
      // Chrome's tab search (⌘⇧A): every session, jumpable — ⌘1..9 & Ctrl+Tab work too
      ...sessionEntries.map((sess, i) => ({
        id: `session-${sess.id}`,
        group: 'Sessions',
        label: `Go to session: ${sess.label}`,
        hint: i < 9 ? `⌘${i + 1}` : undefined,
        icon: sess.icon,
        run: () => { useKaisola.getState().switchSession(sess.id); close() },
      })),
      ...(isDesktop && bridge.windows
        ? [{ id: 'new-window', group: 'Navigate', label: 'New window', hint: '⌘⇧N · its own workspace & layout', icon: 'AppWindow', run: () => { void bridge.windows?.newWindow(); close() } }]
        : []),
      ...(workspacePath && isDesktop
        ? [{ id: 'reveal-ws', group: 'Navigate', label: 'Reveal workspace in Finder', hint: workspacePath, icon: 'FolderOpen', run: () => { void bridge.fs.reveal(workspacePath); close() } }]
        : []),
    ]
    const workspace: Command[] = workspacePath && isDesktop
      ? [
          {
            id: 'ckpt-now',
            group: 'Workspace checkpoints',
            label: 'Checkpoint workspace now',
            hint: 'Snapshot every file (incl. untracked) to a hidden git ref',
            icon: 'Camera',
            run: () => {
              void snapshotWorkspace('Manual checkpoint').then((c) =>
                pushToast(c ? 'success' : 'error', c ? 'Workspace checkpointed.' : 'Checkpoint failed — is this a git repo?'),
              )
              close()
            },
          },
          {
            id: 'follow-agent',
            group: 'Workspace checkpoints',
            label: followAgent ? 'Stop following the agent' : 'Follow the agent',
            hint: 'Auto-open files Claude touches as transient previews',
            icon: 'Crosshair',
            run: () => { toggleFollowAgent(); close() },
          },
          ...repoCheckpoints.slice(0, 6).map((c) => ({
            id: `rckpt-${c.id}`,
            group: 'Workspace checkpoints',
            label: `Restore workspace: ${c.label}`,
            hint: relTime(c.at),
            icon: 'History',
            run: () => { void restoreRepoCheckpoint(c.id); close() },
          })),
        ]
      : []
    const actions: Command[] = [
      { id: 'verify', group: 'Actions', label: 'Verify citations', hint: 'Check every quote actually supports its claim', icon: 'BadgeCheck', run: () => { void verifyCitations().catch(() => {}); close() } },
      { id: 'citegraph', group: 'Actions', label: 'Build citation graph', hint: 'Map in-corpus citations via OpenAlex', icon: 'Network', run: () => { void buildCitationGraph().catch(() => {}); close() } },
      { id: 'grobid', group: 'Actions', label: 'Ingest PDFs (GROBID)', hint: 'Full text + pin citations to PDF rectangles', icon: 'FileText', run: () => { void ingestAllPdfs().catch(() => {}); close() } },
      { id: 'demo', group: 'Project', label: 'Load demo project', hint: 'Time-awareness in LLM agents', icon: 'Sparkles', run: () => { loadDemo(); close() } },
      { id: 'clear', group: 'Project', label: 'Clear project', hint: 'Start empty', icon: 'Eraser', run: () => { clearProject(); close() } },
      // the proposal gate's only entry point in the IDE-first shell (the old
      // sidebar review inbox is parked) — without this, pending research diffs
      // could never be approved or rejected
      ...(proposals.some((p) => p.status === 'pending')
        ? [{
            id: 'review-pending',
            group: 'Project',
            label: 'Review pending decisions',
            hint: `${proposals.filter((p) => p.status === 'pending').length} proposal${proposals.filter((p) => p.status === 'pending').length === 1 ? '' : 's'} awaiting your call`,
            icon: 'Inbox',
            run: () => { focusProposal(proposals.find((p) => p.status === 'pending')!.id); close() },
          } satisfies Command]
        : []),
      { id: 'theme', group: 'Actions', label: 'Toggle theme', icon: 'SunMoon', run: () => { toggleTheme(); close() } },
      { id: 'layout-focus', group: 'Actions', label: 'Switch to Focus layout', hint: 'Hide the workspace rail and session cards', icon: 'Focus', run: () => { setLayoutMode('focus'); close() } },
      { id: 'layout-studio', group: 'Actions', label: 'Switch to Studio layout', hint: 'Show the existing rail, file tree, sessions, and canvas structure', icon: 'PanelsTopLeft', run: () => { setLayoutMode('studio'); close() } },
      { id: 'sessions-show', group: 'Actions', label: 'Show sessions', hint: 'Reveal a live agent or terminal in Studio', icon: 'PanelLeftOpen', run: () => { setDock(true); close() } },
      { id: 'sessions-hide', group: 'Actions', label: 'Hide sessions', hint: 'Keep sessions running in the background', icon: 'PanelLeftClose', run: () => { setDock(false); close() } },
      { id: 'files-show', group: 'Actions', label: 'Show files', hint: 'Reveal the project canvas', icon: 'PanelRightOpen', run: () => { if (layoutMode === 'studio' && !canvasOpen) toggleCanvas(); close() } },
      { id: 'files-hide', group: 'Actions', label: 'Hide files', hint: 'Give the whole work row to sessions', icon: 'PanelRightClose', run: () => { if (layoutMode === 'focus' || canvasOpen) toggleCanvas(); close() } },
      { id: 'file-tree-toggle', group: 'Layout', label: railOpen ? 'Hide file tree' : 'Show file tree', hint: 'Also available in the top-right panel controls', icon: 'FolderTree', run: () => { toggleRail(); close() } },
      { id: 'sessions-left', group: 'Layout', label: 'Place sessions on the left', icon: 'PanelsTopLeft', run: () => { setTabLayout('sidebar'); close() } },
      { id: 'sessions-top', group: 'Layout', label: 'Place sessions across the top', icon: 'PanelTop', run: () => { setTabLayout('bare'); close() } },
      { id: 'sessions-shelf', group: 'Layout', label: 'Use nested session shelf', icon: 'PanelTop', run: () => { setTabLayout('shelf'); close() } },
      { id: 'sessions-runway', group: 'Layout', label: 'Use session runway', icon: 'PanelTop', run: () => { setTabLayout('runway'); close() } },
      { id: 'sessions-flat', group: 'Layout', label: 'Use flat session labels', icon: 'PanelTop', run: () => { setTabLayout('flat'); close() } },
      { id: 'sessions-compact', group: 'Layout', label: 'Use compact session row', icon: 'PanelTop', run: () => { setTabLayout('compact'); close() } },
    ]
    const autonomy: Command[] = (['observe', 'propose', 'execute', 'sprint'] as const).map((a) => ({
      id: `auto-${a}`,
      group: 'Autonomy',
      label: `Set autonomy: ${a}`,
      icon: 'SlidersHorizontal',
      run: () => { setAutonomy(a); close() },
    }))
    const history: Command[] = checkpoints.length
      ? [
          { id: 'undo', group: 'History', label: 'Undo last change', hint: checkpoints[0].label, icon: 'Undo2', run: () => { undoLast(); close() } },
          ...checkpoints.slice(0, 8).map((c) => ({
            id: `restore-${c.id}`,
            group: 'History',
            label: `Restore: ${c.label}`,
            hint: 'Revert the trajectory to this point',
            icon: 'History',
            run: () => { restoreCheckpoint(c.id); close() },
          })),
        ]
      : []
    const wfCmds: Command[] = workflows.map((w) => ({
      id: `wf-${w.id}`,
      group: 'Workflows',
      label: `Run workflow: ${w.name}`,
      hint: `${w.steps.length} step${w.steps.length > 1 ? 's' : ''}${w.steps.some((s) => s.count > 1) ? ' · best-of-N' : ''}`,
      icon: 'Workflow',
      run: () => { runWorkflow(w.id); close() },
    }))
    return [...nav, ...workspace, ...agents, ...wfCmds, ...actions, ...history, ...autonomy]
  // `open` is a dep so each palette-open rebuilds the session-jump entries
  }, [open, close, togglePalette, requestTerminal, workspacePath, backlogPath, requestFile, followAgent, toggleFollowAgent, repoCheckpoints, snapshotWorkspace, restoreRepoCheckpoint, pushToast, runAgent, runStageAgents, enqueueStageAgents, workflows, runWorkflow, verifyCitations, buildCitationGraph, ingestAllPdfs, toggleTheme, setLayoutMode, setDock, toggleCanvas, toggleRail, setTabLayout, layoutMode, canvasOpen, railOpen, setAutonomy, loadDemo, clearProject, checkpoints, undoLast, restoreCheckpoint, proposals, focusProposal])

  // ── ranked rows for the current mode ──
  const commandRows = useMemo(() => {
    if (mode !== 'commands') return []
    const t = q.trim()
    if (!t) return commands.map((c) => ({ item: c, hit: { score: 0, indices: [] as number[] } }))
    return fuzzyRank(t, commands, (c) => c.label, 40)
  }, [mode, q, commands])

  const recents = useMemo(() => {
    const seen = new Set<string>()
    const out: string[] = []
    for (const p of [openFilePath, ...fileTabs.map((t) => t.path)]) {
      if (p && !seen.has(p) && workspacePath && p.startsWith(`${workspacePath}/`)) {
        seen.add(p)
        out.push(p.slice(workspacePath.length + 1))
      }
    }
    return out
  }, [openFilePath, fileTabs, workspacePath])

  const fileRows = useMemo(() => {
    if (mode !== 'files') return []
    const t = q.trim()
    const recentSet = new Set(recents)
    if (!t) {
      const rest = files.filter((f) => !recentSet.has(f))
      return [...recents, ...rest].slice(0, 30).map((f) => ({ item: f, hit: { score: 0, indices: [] as number[] }, recent: recentSet.has(f) }))
    }
    return fuzzyRank(t, files, (f) => f, 50).map((r) => ({ ...r, recent: false }))
  }, [mode, q, files, recents])

  const rowCount = mode === 'files' ? fileRows.length : commandRows.length
  const activeIndex = active >= 0 && active < rowCount ? active : 0

  useEffect(() => {
    listRef.current?.querySelector('[data-active="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [activeIndex])

  const openFile = (rel: string, pinned: boolean) => {
    if (!workspacePath) return
    requestFile(`${workspacePath}/${rel}`, pinned ? 'edit' : undefined, { pinned })
    close()
  }

  // group commands for browsing when the query is empty; ranked flat when not.
  // visualRows mirrors the RENDERED order exactly — activeIndex points at the
  // drawn row, so Enter never runs the unordered commandRows array.
  // (the group buckets are a permutation of the flat array).
  const grouped = mode === 'commands' && !q.trim()
  const groups = grouped
    ? commandRows.reduce<Record<string, typeof commandRows>>((acc, r) => {
        ;(acc[r.item.group] ??= []).push(r)
        return acc
      }, {})
    : {}
  const visualRows = grouped ? Object.values(groups).flat() : commandRows

  const runActive = (e?: { metaKey?: boolean }) => {
    if (mode === 'files') {
      const row = fileRows[activeIndex]
      if (row) openFile(row.item, !!e?.metaKey)
    } else {
      visualRows[activeIndex]?.item.run()
    }
  }

  if (!open) return null

  let flatIndex = -1

  const commandRow = (r: (typeof commandRows)[number], idx: number) => (
    <button type="button"
      key={r.item.id}
      className="palette-item"
      data-active={idx === activeIndex}
      onMouseEnter={() => setActive(idx)}
      onClick={() => r.item.run()}
    >
      <Icon name={r.item.icon} size={15} className="palette-item-icon" />
      <span className="palette-item-label">
        <Runs text={r.item.label} indices={r.hit.indices} />
      </span>
      {r.item.hint && <span className="palette-item-hint truncate faint">{r.item.hint}</span>}
    </button>
  )

  return (
    <dialog
      ref={dialogRef}
      className="palette-overlay"
      style={PALETTE_DIALOG_STYLE}
      aria-label={mode === 'files' ? 'Go to file' : 'Command palette'}
      onCancel={(event) => { event.preventDefault(); close() }}
    >
      <div className="palette">
        <div className="palette-search">
          <Icon name={mode === 'files' ? 'FileSearch' : 'Search'} size={16} className="muted" />
          <input
            ref={inputRef}
            className="palette-input"
            placeholder={mode === 'files' ? 'Go to file — type parts of the name or path…' : 'Search commands, open agents, or run tools...'}
            value={q}
            onChange={(e) => {
              const v = e.target.value
              setActive(0)
              // VS Code muscle memory: '>' at the start of ⌘P = command mode
              if (mode === 'files' && v.startsWith('>')) {
                togglePalette('commands')
                setQ(v.slice(1))
                return
              }
              setQ(v)
            }}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') { e.preventDefault(); setActive((a) => Math.min(a + 1, rowCount - 1)) }
              else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)) }
              else if (e.key === 'Enter') { e.preventDefault(); runActive(e) }
              else if (e.key === 'Escape') close()
            }}
          />
          <span className="kbd">esc</span>
        </div>
        <div className="palette-list" ref={listRef}>
          {rowCount === 0 && (
            <div className="palette-empty faint">
              {mode === 'files'
                ? workspacePath ? 'No file matches.' : 'Open a folder first.'
                : 'No matches.'}
            </div>
          )}

          {mode === 'files' &&
            fileRows.map((r, idx) => {
              const name = r.item.split('/').pop() ?? r.item
              const dir = r.item.slice(0, r.item.length - name.length).replace(/\/$/, '')
              const nameStart = r.item.length - name.length
              const nameIdx: number[] = []
              const dirIdx: number[] = []
              for (const index of r.hit.indices) {
                if (index >= nameStart) nameIdx.push(index - nameStart)
                else dirIdx.push(index)
              }
              return (
                <button type="button"
                  key={r.item}
                  className="palette-item"
                  data-active={idx === activeIndex}
                  onMouseEnter={() => setActive(idx)}
                  onClick={(e) => openFile(r.item, e.metaKey)}
                  title={`${r.item} — Enter previews · ⌘Enter pins & edits`}
                >
                  <Icon name={fileIcon(name)} size={15} className="palette-item-icon" />
                  <span className="palette-item-label">
                    <Runs text={name} indices={nameIdx} />
                  </span>
                  {r.recent && <span className="palette-recent">recent</span>}
                  {dir && (
                    <span className="palette-item-hint truncate faint">
                      <Runs text={dir} indices={dirIdx} />
                    </span>
                  )}
                </button>
              )
            })}

          {mode === 'commands' && !grouped && commandRows.map((r, idx) => commandRow(r, idx))}
          {mode === 'commands' && grouped &&
            Object.entries(groups).map(([group, rows]) => (
              <div key={group} className="palette-group">
                <div className="palette-group-label caps">{group}</div>
                {rows.map((r) => {
                  flatIndex += 1
                  return commandRow(r, flatIndex)
                })}
              </div>
            ))}
        </div>
        <div className="palette-foot">
          {mode === 'files' ? (
            <>
              <span><span className="kbd">↩</span> preview</span>
              <span><span className="kbd">⌘↩</span> pin &amp; edit</span>
              <span><span className="kbd">&gt;</span> commands</span>
              {filesTruncated && <span className="faint">index capped — narrow with a path</span>}
            </>
          ) : (
            <>
              <span><span className="kbd">↩</span> run</span>
              <span><span className="kbd">⌘P</span> files</span>
            </>
          )}
        </div>
      </div>
    </dialog>
  )
}
