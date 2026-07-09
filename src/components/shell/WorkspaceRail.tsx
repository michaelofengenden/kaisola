import { useCallback, useEffect, useRef, useState } from 'react'
import { useKaisola } from '../../store/store'
import { bridge, isDesktop, type FsEntry } from '../../lib/bridge'
import { Icon } from '../Icon'
import { fileIcon } from '../../lib/fileIcon'
import { AGENTS_TEMPLATE } from '../../lib/agentsTemplate'
import { shellDrag } from './SessionCards'

/**
 * The left rail card — the PROJECT: its file tree (plus the open file's
 * outline and captured quotes). Sessions live only in the tab strip above the
 * cards — the strip is the one session list; no duplicate rail list here.
 */
export function WorkspaceRail() {
  return (
    <aside className="wsrail">
      <AgentPulse />
      <OutlineSection />
      <QuotesSection />
      <FilesTree />
      <RailResize />
    </aside>
  )
}

/** Drag handle on the rail's right edge — stretch the files sidebar. */
function RailResize() {
  const setRailWidth = useKaisola((s) => s.setRailWidth)
  const start = (e: React.MouseEvent) => {
    e.preventDefault()
    // iframes/webviews must not eat mousemove mid-drag (same rule as the
    // canvas edge and the card grips)
    shellDrag.start()
    const rail = (e.currentTarget as HTMLElement).parentElement
    const startX = e.clientX
    const startW = rail?.getBoundingClientRect().width ?? 232
    const onMove = (ev: MouseEvent) => setRailWidth(startW + (ev.clientX - startX))
    const onUp = () => {
      shellDrag.end()
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
  }
  return (
    <div
      className="wsrail-resize"
      onMouseDown={start}
      onDoubleClick={() => setRailWidth(null)}
      title="Drag to resize · double-click to reset"
    />
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
 * the file the agent touched. No pulse dot here: the running indicator
 * lives on the session's tab badge, once, not in two places.
 */
function AgentPulse() {
  const feed = useKaisola((s) => s.agentFeed)
  const requestFile = useKaisola((s) => s.requestFile)
  const latest = feed[0]
  if (!latest) return null
  const running = latest.kind !== 'stop'
  // speak in sentences, not raw feed fragments: name the speaker, then the
  // event — an unattributed echo of your own prompt read as debris up here
  const speaker = latest.kind === 'prompt' ? 'You' : latest.kind === 'tool' || latest.kind === 'stop' ? 'Claude' : null
  const line = latest.kind === 'stop' ? 'finished the turn' : latest.text
  return (
    <button
      className="agent-pulse"
      data-running={running}
      onClick={() => { if (latest.path) requestFile(latest.path) }}
      title={latest.path ? `${line} — click to open` : line}
    >
      {speaker && <span className="agent-pulse-k">{speaker}</span>}
      <span className="grow truncate">{line}</span>
    </button>
  )
}

/** Per-workspace tree memory: switching project tabs restores the tree (and
 * its expanded folders) instantly instead of repainting from an empty rail;
 * a background refresh then reconciles anything that changed while away. */
const treeCache = new Map<string, { children: Record<string, FsEntry[]>; expanded: Set<string> }>()

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
    // restore this workspace's cached tree so a project switch paints
    // instantly; the loadDir calls below refresh it in the background
    const cached = workspacePath ? treeCache.get(workspacePath) : undefined
    setChildren(cached?.children ?? {})
    setExpanded(cached ? new Set(cached.expanded) : new Set())
    setQuery('')
    setResults([])
    if (workspacePath) {
      void loadDir(workspacePath)
      if (cached) for (const dir of cached.expanded) if (cached.children[dir]) void loadDir(dir)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loadDir, workspacePath])

  // keep the cache current — only once THIS workspace's root has loaded, so a
  // just-switched render can't file the old project's tree under the new key
  useEffect(() => {
    if (workspacePath && children[workspacePath]) treeCache.set(workspacePath, { children, expanded })
  }, [children, expanded, workspacePath])

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
  // AGENTS.md scaffold: the cross-tool context file every hosted agent reads.
  // Existing file opens (never clobbered); missing file gets the human-edited
  // template (deliberately never auto-generated — see agentsTemplate.ts).
  const scaffoldAgentsMd = async (dir: string) => {
    const target = `${dir}/AGENTS.md`
    const existing = await bridge.fs.read(target)
    if (!existing.ok || !String(existing.content ?? '').trim()) {
      const w = await bridge.fs.write(target, AGENTS_TEMPLATE)
      if (!w.ok) { pushToast('error', w.message ?? 'Could not create AGENTS.md.'); closeMenu(); return }
      void loadDir(dir)
      setExpanded((ex) => new Set(ex).add(dir))
    }
    requestFile(target, 'edit', { pinned: true })
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
                {menu.isDir && (
                  <button className="tree-menu-item" onClick={() => void scaffoldAgentsMd(menu.path)}>
                    <Icon name="Bot" size={13} /> AGENTS.md
                  </button>
                )}
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
