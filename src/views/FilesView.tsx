import { Suspense, lazy, useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type MouseEvent as ReactMouseEvent } from 'react'
import { useKaisola, type QuoteAnnotation } from '../store/store'
import { bridge, isDesktop, type FsEntry, type FsReadMediaKind, type FsReadResult, type GitChange } from '../lib/bridge'
import { extractOutline } from '../lib/outline'
import { changedNewLines } from '../lib/lineDiff'
import { computeTurnBlame, type BlameLine } from '../lib/turnBlame'
import { relTime, countMatches } from '../lib/format'
import type { AnnotationRange, QuoteAction, ScrollMark } from '../components/CodeEditor'
import { EmptyState } from '../components/EmptyState'
import type { DocumentPreviewKind } from '../components/DocumentPreview'
import { Icon } from '../components/Icon'
import { LatexBar } from '../components/shell/LatexBar'
import { fileIcon } from '../lib/fileIcon'
import { isExtensionInstalled, previewContributionFor, useExtensionRevision } from '../lib/extensions'

// The editor (CodeMirror) is only pulled in when a file is actually opened —
// the preview path stays light, and the web build never loads it.
const CodeEditor = lazy(() =>
  import('../components/CodeEditor').then((m) => ({ default: m.CodeEditor })),
)
// The rendered-document preview carries the react-markdown stack — same deal.
const DocumentPreview = lazy(() =>
  import('../components/DocumentPreview').then((m) => ({ default: m.DocumentPreview })),
)

type Mode = 'preview' | 'edit' | 'split'

const MIN_FILE_ZOOM = 0.72
const MAX_FILE_ZOOM = 2.4
const ZOOM_COMMIT_DELAY = 180

const clampFileZoom = (zoom: number) =>
  Math.min(MAX_FILE_ZOOM, Math.max(MIN_FILE_ZOOM, Number(zoom.toFixed(3))))

interface FileTab {
  path: string
  value: string
  baseline: string
  mode: Mode
  /** Zed-style preview tabs: an unpinned tab is transient — the next transient
   * open replaces it in place. Editing, saving, or double-clicking pins. */
  pinned: boolean
  /** 1-based cursor line — restored across relaunches. */
  cursor?: number
  loading: boolean
  saving: boolean
  readError: string | null
  mediaKind: FsReadMediaKind | null
  mime: string | null
  dataUrl: string | null
  previewUrl: string | null
  /** File version for media previews (PDF rebuilds re-rasterize on change). */
  mtimeMs: number | null
  size: number | null
  unsupported: boolean
}

// Same-process project switching should paint the editor immediately. Persisted
// file sessions intentionally store metadata only, but rereading every tab and
// rebuilding every preview on each click made warm tab changes feel like cold
// launches. Keep a small LRU of full in-memory sessions; disk reads still run in
// the background after the cached frame is shown, so agent edits are refreshed.
const FILE_SESSION_CACHE_CAP = 4
const fileSessionCache = new Map<string, { tabs: FileTab[]; activePath: string | null }>()
const rememberFileSession = (workspace: string, tabs: FileTab[], activePath: string | null) => {
  fileSessionCache.delete(workspace)
  fileSessionCache.set(workspace, { tabs, activePath })
  while (fileSessionCache.size > FILE_SESSION_CACHE_CAP) {
    const oldest = fileSessionCache.keys().next().value
    if (oldest == null) break
    fileSessionCache.delete(oldest)
  }
}

interface PdfInfoState {
  pages: number
  width: number
  height: number
}

interface PdfPageImage {
  url: string
  width: number
  height: number
  /** dpi/72 the page was rasterized at — px / scale = PDF points. */
  scale: number
  /** The zoom bucket this render belongs to; zooming re-renders at the new dpi. */
  renderedFor: number
}

const fileName = (path: string) => path.split('/').pop() || path
const fileExt = (path?: string) => path?.split('.').pop()?.toLowerCase()
const isMarkdown = (path?: string) => {
  const ext = fileExt(path)
  return ext === 'md' || ext === 'markdown' || ext === 'mdx'
}
const isHtml = (path?: string) => {
  const ext = fileExt(path)
  return ext === 'html' || ext === 'htm'
}
const isLatex = (path?: string) => {
  const ext = fileExt(path)
  return ext === 'tex' || ext === 'latex'
}
const defaultModeForPath = (path: string, mode?: Mode): Mode => isLatex(path) ? 'edit' : mode ?? 'preview'
const isSvg = (path?: string) => fileExt(path) === 'svg'
const isTextTab = (tab: FileTab | null | undefined) => !tab?.mediaKind || tab.mediaKind === 'text'
const isMediaTab = (tab: FileTab | null | undefined) => !!tab?.mediaKind && tab.mediaKind !== 'text'
const mediaLabel = (kind?: FsReadMediaKind | null) =>
  kind === 'pdf' ? 'PDF' : kind === 'image' ? 'image' : kind === 'binary' ? 'binary file' : 'file'
const formatBytes = (bytes?: number | null) => {
  if (typeof bytes !== 'number' || !Number.isFinite(bytes)) return ''
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB']
  let value = bytes / 1024
  let unit = units[0]
  for (let i = 1; i < units.length && value >= 1024; i += 1) {
    value /= 1024
    unit = units[i]
  }
  return `${value >= 10 ? value.toFixed(0) : value.toFixed(1)} ${unit}`
}
const emptyFileTab = (path: string, mode: Mode, pinned = true): FileTab => ({
  path,
  value: '',
  baseline: '',
  mode,
  pinned,
  loading: true,
  saving: false,
  readError: null,
  mediaKind: null,
  mime: null,
  dataUrl: null,
  previewUrl: null,
  mtimeMs: null,
  size: null,
  unsupported: false,
})
const tabWithReadResult = (current: FileTab, r: FsReadResult): FileTab => {
  if (!r.ok) return { ...current, loading: false, readError: r.message ?? 'Could not read this file.' }
  if (r.tooLarge) {
    return {
      ...current,
      loading: false,
      value: '',
      baseline: '',
      readError: `This ${mediaLabel(r.mediaKind)} is too large to display in Kaisola.`,
      mediaKind: r.mediaKind ?? current.mediaKind ?? 'text',
      mime: r.mime ?? current.mime,
      dataUrl: null,
      previewUrl: null,
      size: typeof r.size === 'number' ? r.size : current.size,
      unsupported: false,
      mode: r.mediaKind && r.mediaKind !== 'text' ? 'preview' : current.mode,
    }
  }
  const mediaKind = r.mediaKind ?? 'text'
  const text = mediaKind === 'text' ? r.content ?? '' : ''
  const next: FileTab = {
    ...current,
    loading: false,
    value: text,
    baseline: text,
    readError: null,
    mediaKind,
    mime: r.mime ?? null,
    dataUrl: r.dataUrl ?? null,
    previewUrl: r.previewUrl ?? null,
    mtimeMs: r.mtimeMs ?? null,
    size: typeof r.size === 'number' ? r.size : null,
    unsupported: !!r.unsupported,
    mode: mediaKind === 'text' ? current.mode : 'preview',
  }
  // unchanged content keeps the SAME tab object, so a watch-triggered re-read
  // of a clean tab doesn't churn effects/renders downstream
  const keys: (keyof FileTab)[] = ['loading', 'value', 'baseline', 'readError', 'mediaKind', 'mime', 'dataUrl', 'previewUrl', 'mtimeMs', 'size', 'unsupported', 'mode']
  return keys.every((k) => next[k] === current[k]) ? current : next
}

/**
 * The file editor pane. Files can be opened from the workspace rail or the
 * quick-open search here. Each open file gets a tab with its own dirty state,
 * mode, and content buffer.
 */
export function FilesView() {
  const extensionRevision = useExtensionRevision()
  const workspacePath = useKaisola((s) => s.workspacePath)
  const setWorkspace = useKaisola((s) => s.setWorkspace)
  const fileRequest = useKaisola((s) => s.fileRequest)
  const fileTextZoom = useKaisola((s) => s.fileTextZoom)
  const setOpenFile = useKaisola((s) => s.setOpenFile)
  const setFileDirty = useKaisola((s) => s.setFileDirty)
  const setFileSession = useKaisola((s) => s.setFileSession)
  const setFileTextZoom = useKaisola((s) => s.setFileTextZoom)
  const pushToast = useKaisola((s) => s.pushToast)

  const latexMode = useKaisola((s) => s.latexMode)
  const latexMain = useKaisola((s) => s.latexMain)
  const setLatexMode = useKaisola((s) => s.setLatexMode)
  const repoCheckpoints = useKaisola((s) => s.repoCheckpoints)
  const snapshotWorkspace = useKaisola((s) => s.snapshotWorkspace)
  const restoreRepoCheckpoint = useKaisola((s) => s.restoreRepoCheckpoint)
  const setUnsavedBuffer = useKaisola((s) => s.setUnsavedBuffer)
  const setOutline = useKaisola((s) => s.setOutline)
  const setEditorCursorLine = useKaisola((s) => s.setEditorCursorLine)
  const storeScrollRequest = useKaisola((s) => s.scrollRequest)
  const requestScroll = useKaisola((s) => s.requestScroll)
  const allAnnotations = useKaisola((s) => s.annotations)
  const addAnnotation = useKaisola((s) => s.addAnnotation)

  const [tabs, setTabs] = useState<FileTab[]>([])
  const [activePath, setActivePath] = useState<string | null>(null)
  const [pdfSourcePath, setPdfSourcePath] = useState<string | null>(null)
  const [pdfSourceScroll, setPdfSourceScroll] = useState<{ path: string; line: number; seq: number } | null>(null)
  const [pdfSourceBuilding, setPdfSourceBuilding] = useState(false)
  // checkpoint review: which tabs are in diff mode, and each one's base text
  const [diffPaths, setDiffPaths] = useState<Set<string>>(new Set())
  const [diffBases, setDiffBases] = useState<Record<string, string>>({})
  const [changes, setChanges] = useState<GitChange[] | null>(null)
  const [changesOpen, setChangesOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [searchResults, setSearchResults] = useState<FsEntry[]>([])
  const [searching, setSearching] = useState(false)
  const [searchTruncated, setSearchTruncated] = useState(false)
  const [searchOpen, setSearchOpen] = useState(false)
  const [findText, setFindText] = useState('')
  const [watchSeq, setWatchSeq] = useState(0)
  // paths the watcher reported since the last refresh pass (drained per batch)
  const watchChangedRef = useRef<Set<string>>(new Set())
  const [liveZoom, setLiveZoom] = useState(fileTextZoom)
  const [pdfSourceZoom, setPdfSourceZoom] = useState(1)
  const tabsRef = useRef<FileTab[]>([])
  const activePathRef = useRef<string | null>(null)
  const sessionWorkspaceRef = useRef<string | null>(workspacePath)
  const externalDirtyRef = useRef(new Set<string>())
  const paneRef = useRef<HTMLDivElement>(null)
  const zoomRef = useRef(fileTextZoom)
  const pendingZoomRef = useRef(fileTextZoom)
  const zoomFrameRef = useRef<number | null>(null)
  const zoomCommitTimerRef = useRef<number | null>(null)
  const pdfSourceZoomRef = useRef(1)
  const pendingPdfSourceZoomRef = useRef(1)
  const pdfSourceZoomFrameRef = useRef<number | null>(null)
  const gestureBaseRef = useRef(fileTextZoom)
  const gestureTargetRef = useRef<'main' | 'pdf-source' | null>(null)
  const pointerInPaneRef = useRef(false)
  const suppressSessionSyncRef = useRef(true)

  const active = tabs.find((t) => t.path === activePath) ?? null
  const activeIsText = isTextTab(active)
  const activeIsMedia = isMediaTab(active)
  const anyDirty = tabs.some((t) => isTextTab(t) && t.value !== t.baseline)
  const dirty = !!active && activeIsText && active.value !== active.baseline
  const ext = fileExt(active?.path)
  const activeIsMd = activeIsText && isMarkdown(active?.path)
  const activeIsHtml = activeIsText && isHtml(active?.path)
  const activeIsLatex = activeIsText && isLatex(active?.path)
  // svg arrives as TEXT (editable source); its preview renders from the buffer
  const activeIsSvg = activeIsText && isSvg(active?.path)
  const contributedPreview = previewContributionFor(ext)
  const previewKind: DocumentPreviewKind | null = contributedPreview?.renderer
    ?? (activeIsMd && isExtensionInstalled('kaisola.markdown') ? 'markdown'
      : activeIsHtml && isExtensionInstalled('kaisola.html') ? 'html'
        : null)
  const canPreview = !!previewKind || activeIsSvg
  const findMatches = useMemo(
    () => (active && previewKind && findText.trim() ? countMatches(active.value, findText) : 0),
    [active, previewKind, findText, extensionRevision],
  )

  useEffect(() => { setFileDirty(anyDirty) }, [anyDirty, setFileDirty])
  useEffect(() => { setOpenFile(activePath) }, [activePath, setOpenFile])
  useEffect(() => { setFindText('') }, [activePath])
  // LaTeX auto-detect: opening a .tex flips the shell into LaTeX mode (unless
  // the user dismissed the bar), and a \documentclass file becomes the build
  // target when none is chosen for this workspace yet
  useEffect(() => {
    if (!isDesktop || !workspacePath || !activeIsLatex || !active || active.loading) return
    const st = useKaisola.getState()
    if (!st.latexMode && !st.latexDismissed) st.setLatexMode(true)
    if (!st.latexMain[workspacePath] && active.value.slice(0, 4000).includes('\\documentclass')) {
      st.setLatexMain(workspacePath, active.path)
    }
  }, [active, activeIsLatex, workspacePath])
  useEffect(() => {
    tabsRef.current = tabs
    activePathRef.current = activePath
    const workspace = sessionWorkspaceRef.current
    if (workspace) rememberFileSession(workspace, tabs, activePath)
  }, [activePath, tabs])
  useEffect(() => {
    const next = clampFileZoom(fileTextZoom)
    // an EXTERNAL zoom change (⌘0 reset, another surface) wins over any
    // still-pending gesture commit — otherwise that commit fires up to 800ms
    // later and silently clobbers the reset back to the pre-reset zoom
    if (zoomCommitTimerRef.current !== null && pendingZoomRef.current !== next) {
      window.clearTimeout(zoomCommitTimerRef.current)
      zoomCommitTimerRef.current = null
    }
    zoomRef.current = next
    pendingZoomRef.current = next
    setLiveZoom(next)
  }, [fileTextZoom])
  useEffect(() => {
    const open = new Set(tabs.map((tab) => tab.path))
    for (const tab of tabs) {
      if (tab.value === tab.baseline) externalDirtyRef.current.delete(tab.path)
    }
    for (const path of Array.from(externalDirtyRef.current)) {
      if (!open.has(path)) externalDirtyRef.current.delete(path)
    }
  }, [tabs])

  useEffect(() => {
    if (suppressSessionSyncRef.current) return
    setFileSession(
      tabs.map((tab) => ({ path: tab.path, mode: tab.mode, pinned: tab.pinned, cursor: tab.cursor })),
      activePath,
    )
  }, [activePath, setFileSession, tabs])

  useEffect(() => {
    let cancelled = false
    suppressSessionSyncRef.current = true
    setQuery('')
    setSearchResults([])
    externalDirtyRef.current.clear()

    const previousWorkspace = sessionWorkspaceRef.current
    if (previousWorkspace && previousWorkspace !== workspacePath) {
      rememberFileSession(previousWorkspace, tabsRef.current, activePathRef.current)
    }
    sessionWorkspaceRef.current = workspacePath

    const savedTabs = useKaisola.getState().fileTabs
    const savedActive = useKaisola.getState().openFilePath
    const restored = workspacePath
      ? savedTabs.filter((tab) => tab.path === workspacePath || tab.path.startsWith(`${workspacePath}/`))
      : []

    if (!workspacePath || !restored.length) {
      setTabs([])
      setActivePath(null)
      queueMicrotask(() => { if (!cancelled) suppressSessionSyncRef.current = false })
      return () => { cancelled = true }
    }

    const cached = fileSessionCache.get(workspacePath)
    const cachedTabs = cached?.tabs.filter((tab) => restored.some((saved) => saved.path === tab.path)) ?? []
    const nextTabs = cachedTabs.length === restored.length
      ? cachedTabs
      : restored.map((tab) => ({ ...emptyFileTab(tab.path, isLatex(tab.path) ? 'edit' : tab.mode, tab.pinned ?? true), cursor: tab.cursor }))
    const requestedActive = savedActive && restored.some((tab) => tab.path === savedActive) ? savedActive : restored[0].path
    const nextActive = cached?.activePath && restored.some((tab) => tab.path === cached.activePath) ? cached.activePath : requestedActive
    setTabs(nextTabs)
    setActivePath(nextActive)
    queueMicrotask(() => { if (!cancelled) suppressSessionSyncRef.current = false })

    restored.forEach((tab) => {
      void bridge.fs.read(tab.path).then((r) => {
        if (cancelled) return
        setTabs((prev) => prev.map((current) => {
          if (current.path !== tab.path) return current
          return withUnsaved(tabWithReadResult(current, r))
        }))
      })
    })

    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspacePath])

  // continue where you left off: a persisted unsaved buffer overlays the disk
  // content (and pins the tab) — quitting mid-edit no longer loses work
  const withUnsaved = (tab: FileTab): FileTab => {
    if (!isTextTab(tab) || tab.loading || tab.readError) return tab
    const stored = useKaisola.getState().unsavedBuffers[tab.path]
    if (stored != null && stored !== tab.baseline && tab.value === tab.baseline) {
      return { ...tab, value: stored, pinned: true }
    }
    return tab
  }

  const applyZoomVars = useCallback((zoom: number) => {
    const pane = paneRef.current
    if (!pane) return
    pane.style.setProperty('--fx-file-font', `${15 * zoom}px`)
    pane.style.setProperty('--fx-code-font', `${13 * zoom}px`)
  }, [])

  const scheduleZoomCommit = useCallback((zoom: number, delay = ZOOM_COMMIT_DELAY) => {
    if (zoomCommitTimerRef.current !== null) window.clearTimeout(zoomCommitTimerRef.current)
    zoomCommitTimerRef.current = window.setTimeout(() => {
      zoomCommitTimerRef.current = null
      setFileTextZoom(zoom)
    }, delay)
  }, [setFileTextZoom])

  const setLiveFileZoom = useCallback((zoom: number, commitDelay = ZOOM_COMMIT_DELAY) => {
    const next = clampFileZoom(zoom)
    zoomRef.current = next
    pendingZoomRef.current = next
    if (zoomFrameRef.current === null) {
      zoomFrameRef.current = window.requestAnimationFrame(() => {
        zoomFrameRef.current = null
        const pending = pendingZoomRef.current
        applyZoomVars(pending)
        setLiveZoom((current) => (current === pending ? current : pending))
      })
    }
    scheduleZoomCommit(next, commitDelay)
  }, [applyZoomVars, scheduleZoomCommit])

  const setLiveFileZoomAt = useCallback((zoom: number, anchor?: { scroller: HTMLElement; x: number; y: number }, commitDelay = ZOOM_COMMIT_DELAY) => {
    const before = zoomRef.current
    const next = clampFileZoom(zoom)
    if (!anchor || before === next) {
      setLiveFileZoom(next, commitDelay)
      return
    }
    const { scroller, x, y } = anchor
    const rect = scroller.getBoundingClientRect()
    const localX = x - rect.left
    const localY = y - rect.top
    const scrollX = scroller.scrollLeft
    const scrollY = scroller.scrollTop
    setLiveFileZoom(next, commitDelay)
    window.requestAnimationFrame(() => {
      const ratio = next / before
      scroller.scrollLeft = (scrollX + localX) * ratio - localX
      scroller.scrollTop = (scrollY + localY) * ratio - localY
    })
  }, [setLiveFileZoom])

  const setLivePdfSourceZoom = useCallback((zoom: number) => {
    const next = clampFileZoom(zoom)
    pdfSourceZoomRef.current = next
    pendingPdfSourceZoomRef.current = next
    if (pdfSourceZoomFrameRef.current === null) {
      pdfSourceZoomFrameRef.current = window.requestAnimationFrame(() => {
        pdfSourceZoomFrameRef.current = null
        const pending = pendingPdfSourceZoomRef.current
        setPdfSourceZoom((current) => (current === pending ? current : pending))
      })
    }
  }, [])

  const setLivePdfSourceZoomAt = useCallback((zoom: number, anchor?: { scroller: HTMLElement; x: number; y: number }) => {
    const before = pdfSourceZoomRef.current
    const next = clampFileZoom(zoom)
    if (!anchor || before === next) {
      setLivePdfSourceZoom(next)
      return
    }
    const { scroller, x, y } = anchor
    const rect = scroller.getBoundingClientRect()
    const localX = x - rect.left
    const localY = y - rect.top
    const scrollX = scroller.scrollLeft
    const scrollY = scroller.scrollTop
    setLivePdfSourceZoom(next)
    window.requestAnimationFrame(() => {
      const ratio = next / before
      scroller.scrollLeft = (scrollX + localX) * ratio - localX
      scroller.scrollTop = (scrollY + localY) * ratio - localY
    })
  }, [setLivePdfSourceZoom])

  useEffect(() => {
    applyZoomVars(liveZoom)
  }, [applyZoomVars, liveZoom])

  useEffect(() => () => {
    if (zoomFrameRef.current !== null) window.cancelAnimationFrame(zoomFrameRef.current)
    if (pdfSourceZoomFrameRef.current !== null) window.cancelAnimationFrame(pdfSourceZoomFrameRef.current)
    if (zoomCommitTimerRef.current !== null) {
      window.clearTimeout(zoomCommitTimerRef.current)
      setFileTextZoom(zoomRef.current)
    }
  }, [setFileTextZoom])

  useEffect(() => {
    const isInPane = (target: EventTarget | null) => {
      const pane = paneRef.current
      return !!pane && target instanceof Node && pane.contains(target)
    }
    const zoomByWheel = (e: WheelEvent) => {
      const normalizedDelta = e.deltaMode === 1 ? e.deltaY * 16 : e.deltaMode === 2 ? e.deltaY * 240 : e.deltaY
      const target = e.target instanceof Element ? e.target : null
      if (target?.closest('.fx-pdf-source-pane')) {
        const scroller = target.closest<HTMLElement>('.cm-scroller')
        setLivePdfSourceZoomAt(
          pdfSourceZoomRef.current * Math.exp(-normalizedDelta * 0.0035),
          scroller ? { scroller, x: e.clientX, y: e.clientY } : undefined,
        )
        return
      }
      const scroller = target?.closest<HTMLElement>('.fx-pdf-raster, .fx-media-stage')
      setLiveFileZoomAt(
        zoomRef.current * Math.exp(-normalizedDelta * 0.0035),
        scroller ? { scroller, x: e.clientX, y: e.clientY } : undefined,
      )
    }
    const onWheel = (e: WheelEvent) => {
      if (!e.ctrlKey || !isInPane(e.target)) return
      e.preventDefault()
      zoomByWheel(e)
    }
    const onGestureStart = (e: Event) => {
      const target = e.target instanceof Element ? e.target : null
      if (target?.closest('.fx-pdf-source-pane')) {
        gestureTargetRef.current = 'pdf-source'
        gestureBaseRef.current = pdfSourceZoomRef.current
        e.preventDefault()
        return
      }
      if (!isInPane(e.target)) {
        gestureTargetRef.current = null
        return
      }
      e.preventDefault()
      gestureTargetRef.current = 'main'
      gestureBaseRef.current = zoomRef.current
    }
    const onGestureChange = (e: Event) => {
      const target = gestureTargetRef.current
      if (!target) return
      const scale = (e as Event & { scale?: number }).scale
      if (!scale) return
      e.preventDefault()
      if (target === 'pdf-source') setLivePdfSourceZoom(gestureBaseRef.current * scale)
      else setLiveFileZoom(gestureBaseRef.current * scale)
    }
    const onGestureEnd = () => {
      const target = gestureTargetRef.current
      gestureTargetRef.current = null
      if (target === 'main') scheduleZoomCommit(zoomRef.current, 20)
    }
    const options = { passive: false, capture: true } as AddEventListenerOptions
    window.addEventListener('wheel', onWheel, options)
    window.addEventListener('gesturestart', onGestureStart, options)
    window.addEventListener('gesturechange', onGestureChange, options)
    window.addEventListener('gestureend', onGestureEnd, true)
    return () => {
      window.removeEventListener('wheel', onWheel, true)
      window.removeEventListener('gesturestart', onGestureStart, true)
      window.removeEventListener('gesturechange', onGestureChange, true)
      window.removeEventListener('gestureend', onGestureEnd, true)
    }
  }, [scheduleZoomCommit, setLiveFileZoom, setLiveFileZoomAt, setLivePdfSourceZoom, setLivePdfSourceZoomAt])

  useEffect(() => {
    if (!bridge.onFileTextZoomGesture) return
    return bridge.onFileTextZoomGesture(({ direction }) => {
      if (!pointerInPaneRef.current && !paneRef.current?.matches(':hover')) return
      const factor = direction === 'in' ? 1.12 : 1 / 1.12
      setLiveFileZoom(zoomRef.current * factor)
    })
  }, [setLiveFileZoom])

  useEffect(() => {
    if (!workspacePath || !isDesktop) return
    return bridge.fs.watch(workspacePath, (ev) => {
      if (ev.error) return
      for (const event of ev.events ?? []) {
        if (event.path) watchChangedRef.current.add(event.path)
      }
      setWatchSeq((n) => n + 1)
    })
  }, [workspacePath])

  // "Changes · N" — what moved since the last checkpoint (or HEAD when none)
  const lastCkpt = repoCheckpoints[0]
  useEffect(() => {
    if (!workspacePath || !isDesktop) {
      setChanges(null)
      return
    }
    let cancelled = false
    const timer = window.setTimeout(async () => {
      const r = await bridge.git.changes(workspacePath, lastCkpt?.sha)
      if (cancelled) return
      setChanges(r.ok ? r.files ?? [] : null)
    }, 450)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [workspacePath, watchSeq, lastCkpt?.sha])

  // Toggle the checkpoint-review diff for a tab: fetch the base text (the
  // file at the last checkpoint, else HEAD) and hand it to the merge view.
  const toggleDiff = useCallback(async (path: string) => {
    if (diffPaths.has(path)) {
      setDiffPaths((prev) => {
        const next = new Set(prev)
        next.delete(path)
        return next
      })
      return
    }
    if (!workspacePath) return
    const r = await bridge.git.show(workspacePath, lastCkpt?.sha ?? 'HEAD', path)
    if (!r.ok) return
    setDiffBases((prev) => ({ ...prev, [path]: r.content ?? '' }))
    // the diff lives on the source buffer — flip rendered previews to it
    setTabs((prev) => prev.map((t) => (t.path === path && isTextTab(t) ? { ...t, mode: 'edit', pinned: true } : t)))
    setDiffPaths((prev) => new Set(prev).add(path))
  }, [diffPaths, workspacePath, lastCkpt?.sha])

  useEffect(() => {
    if (!workspacePath || !query.trim()) {
      setSearchResults([])
      setSearching(false)
      setSearchTruncated(false)
      return
    }
    let cancelled = false
    setSearching(true)
    const timer = window.setTimeout(async () => {
      const r = await bridge.fs.search(workspacePath, query)
      if (cancelled) return
      setSearching(false)
      setSearchResults(r.ok ? r.entries ?? [] : [])
      setSearchTruncated(!!r.truncated)
    }, 180)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [query, watchSeq, workspacePath])

  useEffect(() => {
    if (watchSeq === 0) return
    const snapshot = tabsRef.current
    const changed = new Set(watchChangedRef.current)
    watchChangedRef.current.clear()
    if (!snapshot.length) return
    // only tabs the batch actually touched re-read — never re-fetch a 40MB PDF
    // because some other file changed. A non-recursive watcher (fallback on
    // platforms without recursive fs.watch) reports the containing dir, so a
    // prefix match keeps nested tab paths covered.
    const touched = (tabPath: string) =>
      changed.size === 0 ||
      changed.has(tabPath) ||
      [...changed].some((p) => tabPath.startsWith(`${p}/`))
    snapshot.forEach((tab) => {
      if (!touched(tab.path)) return
      if (isTextTab(tab) && tab.value !== tab.baseline) {
        if (!externalDirtyRef.current.has(tab.path)) {
          externalDirtyRef.current.add(tab.path)
          pushToast('warn', `External change detected; keeping local edits in ${fileName(tab.path)}`)
        }
        return
      }
      externalDirtyRef.current.delete(tab.path)
      void bridge.fs.read(tab.path).then((r) => {
        setTabs((prev) => prev.map((current) => {
          if (current.path !== tab.path) return current
          if (isTextTab(current) && current.value !== current.baseline) return current
          return tabWithReadResult(current, r)
        }))
      })
    })
  }, [pushToast, watchSeq])

  const open = useCallback(async (path: string, startMode?: Mode, opts?: { pinned?: boolean }) => {
    const nextMode = defaultModeForPath(path, startMode)
    const pinned = opts?.pinned ?? false
    setSearchOpen(false)
    setQuery('')
    setActivePath(path)

    const exists = tabs.some((t) => t.path === path)
    if (exists) {
      setTabs((prev) => prev.map((t) => (t.path === path
        ? { ...t, mode: isLatex(path) ? 'edit' : startMode ?? t.mode, pinned: t.pinned || pinned }
        : t)))
      return
    }
    setTabs((prev) => {
      // a transient open REPLACES the current transient tab (in place) instead
      // of stacking — skimming ten PDFs leaves one tab, not ten
      const previewIdx = pinned ? -1 : prev.findIndex((t) => !t.pinned && !(isTextTab(t) && t.value !== t.baseline))
      if (previewIdx >= 0) {
        const next = [...prev]
        next[previewIdx] = emptyFileTab(path, nextMode, false)
        return next
      }
      return [...prev, emptyFileTab(path, nextMode, pinned)]
    })

    const r = await bridge.fs.read(path)
    setTabs((prev) =>
      prev.map((t) => {
        if (t.path !== path) return t
        return withUnsaved(tabWithReadResult(t, r))
      }),
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tabs])

  const ensureTextTab = useCallback(async (path: string, line?: number) => {
    setTabs((prev) => {
      if (prev.some((t) => t.path === path)) {
        return prev.map((t) => (t.path === path ? { ...t, mode: 'edit', pinned: true } : t))
      }
      return [...prev, emptyFileTab(path, 'edit', true)]
    })
    const r = await bridge.fs.read(path)
    setTabs((prev) =>
      prev.map((t) => {
        if (t.path !== path) return t
        // an EDITED buffer must never be clobbered by the disk copy (same dirty
        // guard as the watcher path) — the jump still applies mode/pin/cursor
        if (isTextTab(t) && t.value !== t.baseline) return { ...t, mode: 'edit', pinned: true, cursor: line ?? t.cursor }
        return withUnsaved(tabWithReadResult({ ...t, mode: 'edit', pinned: true, cursor: line ?? t.cursor }, r))
      }),
    )
  }, [])

  const refreshFileTab = useCallback(async (path: string) => {
    const r = await bridge.fs.read(path)
    setTabs((prev) => prev.map((t) => (t.path === path ? tabWithReadResult(t, r) : t)))
  }, [])

  const syncFromPdf = useCallback(async (req: { pdfPath: string; page: number; x: number; y: number }) => {
    let r = await bridge.latex.syncFromPdf(req)
    if (!r.ok && /No SyncTeX data/i.test(r.message ?? '')) {
      const siblingTex = req.pdfPath.replace(/\.pdf$/i, '.tex')
      const sibling = await bridge.fs.read(siblingTex)
      const st = useKaisola.getState()
      const fallbackMain = workspacePath ? st.latexMain[workspacePath] : undefined
      const buildSource = sibling.ok && sibling.mediaKind === 'text' ? siblingTex : fallbackMain
      if (buildSource) {
        if (workspacePath && buildSource === siblingTex) st.setLatexMain(workspacePath, siblingTex)
        pushToast('info', `Building ${fileName(buildSource)} for SyncTeX…`)
        const built = await bridge.latex.build(buildSource)
        if (built.ok && built.pdf) {
          await refreshFileTab(built.pdf)
          r = await bridge.latex.syncFromPdf({ ...req, pdfPath: built.pdf })
        } else {
          pushToast('error', built.message ?? 'LaTeX build failed.')
        }
      }
    }
    if (!r.ok || !r.file || !r.line) {
      pushToast('warn', r.message ?? 'Could not map that PDF position back to source.')
      return
    }
    if (active?.mediaKind === 'pdf') {
      setPdfSourcePath(r.file)
      setPdfSourceScroll({ path: r.file, line: r.line, seq: Date.now() })
      await ensureTextTab(r.file, r.line)
      return
    }
    await open(r.file, 'edit', { pinned: true })
    window.setTimeout(() => requestScroll(r.file!, r.line!), 180)
  }, [active?.mediaKind, ensureTextTab, open, pushToast, refreshFileTab, requestScroll, workspacePath])

  const pinTab = useCallback((path: string) => {
    setTabs((prev) => prev.map((t) => (t.path === path && !t.pinned ? { ...t, pinned: true } : t)))
  }, [])

  // the workspace tree (left rail) asks for files through the store
  const openRef = useRef(open)
  openRef.current = open
  useEffect(() => {
    if (fileRequest) void openRef.current(fileRequest.path, fileRequest.mode, { pinned: fileRequest.pinned ?? fileRequest.mode === 'edit' })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fileRequest?.seq])

  const setActiveMode = useCallback((mode: Mode) => {
    if (!activePath) return
    setTabs((prev) => prev.map((t) => {
      if (t.path !== activePath) return t
      if (isMediaTab(t) && mode !== 'preview') return t
      // switching into an editing mode is intent to keep the file around
      return { ...t, mode, pinned: t.pinned || mode !== 'preview' }
    }))
  }, [activePath])
  const editActivePreview = useCallback(() => setActiveMode('edit'), [setActiveMode])

  const setActiveValue = (value: string) => {
    if (!activePath) return
    // typing pins — an edited buffer must never be swept away by the next preview
    setTabs((prev) => prev.map((t) => (t.path === activePath && isTextTab(t) ? { ...t, value, pinned: true } : t)))
  }
  const setTabValue = useCallback((path: string, value: string) => {
    setTabs((prev) => prev.map((t) => (t.path === path && isTextTab(t) ? { ...t, value, pinned: true } : t)))
  }, [])

  const closeTab = (path: string) => {
    const idx = tabs.findIndex((t) => t.path === path)
    if (idx < 0) return
    const tab = tabs[idx]
    if (isTextTab(tab) && tab.value !== tab.baseline && !window.confirm(`Discard unsaved changes to ${fileName(path)}?`)) return
    const next = tabs.filter((t) => t.path !== path)
    const nextActive = activePath === path ? next[idx]?.path ?? next[idx - 1]?.path ?? null : activePath
    setTabs(next)
    setActivePath(nextActive)
    // diff mode is per-OPEN-tab state — a later reopen must start clean, not in
    // checkpoint-diff mode against a stale base
    setDiffPaths((prev) => {
      if (!prev.has(path)) return prev
      const n = new Set(prev)
      n.delete(path)
      return n
    })
    setDiffBases((prev) => {
      if (!(path in prev)) return prev
      const { [path]: _dropped, ...rest } = prev
      return rest
    })
  }

  // Cmd+S can arrive from both the editor keymap and the window listener at once;
  // a synchronous set dedupes so we never write or toast twice for one press.
  const inFlight = useRef(new Set<string>())
  const savePath = useCallback(async (path: string, opts?: { toast?: boolean }) => {
    const tab = tabsRef.current.find((t) => t.path === path)
    if (!tab || !isTextTab(tab) || tab.value === tab.baseline || inFlight.current.has(path)) return false
    const content = tab.value
    inFlight.current.add(path)
    setTabs((prev) => prev.map((t) => (t.path === path ? { ...t, saving: true } : t)))
    const r = await bridge.fs.write(path, content)
    inFlight.current.delete(path)
    setTabs((prev) =>
      prev.map((t) =>
        t.path === path
          ? { ...t, saving: false, pinned: true, baseline: r.ok ? content : t.baseline }
          : t,
      ),
    )
    if (r.ok) {
      if (opts?.toast !== false) pushToast('success', `Saved ${fileName(path)}`)
    } else {
      pushToast('error', r.message ?? 'Could not save file.')
    }
    return r.ok
  }, [pushToast])
  const save = useCallback(async () => {
    if (!active || !activeIsText || !dirty) return
    await savePath(active.path)
  }, [active, activeIsText, dirty, savePath])

  // Cmd/Ctrl+S saves even when focus is outside the editor.
  const saveRef = useRef(save)
  saveRef.current = save
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
        e.preventDefault()
        saveRef.current()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  const openFolder = async () => {
    if (anyDirty && !window.confirm('Discard unsaved file changes before switching folders?')) return
    const r = await bridge.pickFolder()
    if (r.ok && r.path) setWorkspace(r.path)
  }

  const relativePath = (path: string) =>
    workspacePath && path.startsWith(`${workspacePath}/`) ? path.slice(workspacePath.length + 1) : path

  // ── session continuity: persist unsaved buffers (debounced, quit-safe) ──
  useEffect(() => {
    const timer = window.setTimeout(() => {
      const stored = useKaisola.getState().unsavedBuffers
      for (const t of tabs) {
        if (!isTextTab(t) || t.loading) continue
        const dirty = t.value !== t.baseline
        if (dirty && stored[t.path] !== t.value) setUnsavedBuffer(t.path, t.value)
        else if (!dirty && stored[t.path] != null) setUnsavedBuffer(t.path, null)
      }
    }, 800)
    return () => window.clearTimeout(timer)
  }, [tabs, setUnsavedBuffer])

  // ── outline of the active text file (the rail's Outline section) ──
  useEffect(() => {
    if (!active || !activeIsText || active.loading) {
      setOutline([])
      return
    }
    const value = active.value
    const e = fileExt(active.path)
    const timer = window.setTimeout(() => setOutline(extractOutline(value, e)), 250)
    return () => window.clearTimeout(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active?.value, active?.path, activeIsText, setOutline])

  // ── cursor: feed the outline follow + flush into the session (slowly) ──
  const cursorsRef = useRef<Record<string, number>>({})
  const cursorFlushRef = useRef<number | null>(null)
  const onCursorLine = useCallback(
    (line: number) => {
      setEditorCursorLine(line)
      if (!activePath) return
      cursorsRef.current[activePath] = line
      if (cursorFlushRef.current === null) {
        cursorFlushRef.current = window.setTimeout(() => {
          cursorFlushRef.current = null
          setTabs((prev) =>
            prev.map((t) =>
              cursorsRef.current[t.path] != null && t.cursor !== cursorsRef.current[t.path]
                ? { ...t, cursor: cursorsRef.current[t.path] }
                : t,
            ),
          )
        }, 2000)
      }
    },
    [activePath, setEditorCursorLine],
  )

  // ── agent-turn blame for the active file (checkpoint attribution) ──
  const [blame, setBlame] = useState<{ path: string; lines: (BlameLine | null)[] } | null>(null)
  useEffect(() => {
    if (!workspacePath || !active || !activeIsText || active.loading || !repoCheckpoints.length) {
      setBlame(null)
      return
    }
    let cancelled = false
    const path = active.path
    const rel = relativePath(path)
    const value = active.value
    const timer = window.setTimeout(() => {
      void computeTurnBlame(workspacePath, rel, value, repoCheckpoints).then((lines) => {
        if (!cancelled) setBlame(lines ? { path, lines } : null)
      })
    }, 900)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspacePath, active?.path, active?.value, activeIsText, repoCheckpoints])

  const editorCursorLine = useKaisola((s) => s.editorCursorLine)
  const [noteLine, setNoteLine] = useState<number | null>(null)
  useEffect(() => {
    setNoteLine(null)
    if (editorCursorLine == null) return
    const t = window.setTimeout(() => setNoteLine(editorCursorLine), 550) // Zed's delay pattern
    return () => window.clearTimeout(t)
  }, [editorCursorLine, activePath])
  const inlineNote = useMemo(() => {
    if (!blame || blame.path !== activePath || noteLine == null) return null
    const b = blame.lines[noteLine - 1]
    if (!b) return null
    return { line: noteLine, text: `⟡ ${b.label}${b.at ? ` · ${relTime(b.at)}` : ''}` }
  }, [blame, activePath, noteLine])

  const paneStyle = {
    '--fx-file-font': `${15 * liveZoom}px`,
    '--fx-code-font': `${13 * liveZoom}px`,
    '--fx-media-zoom': liveZoom,
  } as CSSProperties

  const activeDiff = !!active && diffPaths.has(active.path)

  // ── scrollbar change marks: unsaved-vs-disk (amber) or diff chunks (±) ──
  const marks = useMemo<ScrollMark[]>(() => {
    if (!active || !activeIsText || active.loading || active.value.length > 200_000) return []
    if (activeDiff) {
      const base = diffBases[active.path]
      if (base == null) return []
      return changedNewLines(base, active.value).map((c) => ({
        line: c.line,
        color: c.kind === 'add' ? 'var(--success)' : 'var(--danger)',
      }))
    }
    if (active.value === active.baseline) return []
    return changedNewLines(active.baseline, active.value).map((c) => ({ line: c.line, color: 'var(--warn)' }))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active?.value, active?.baseline, active?.path, activeIsText, activeDiff, diffBases])

  // ── the annotation layer: resolve stored quotes to offsets in this buffer ──
  const annotationRanges = useMemo<AnnotationRange[]>(() => {
    if (!active || !activeIsText) return []
    const mine = allAnnotations.filter((a) => a.workspace === workspacePath && a.path === active.path)
    const out: AnnotationRange[] = []
    for (const a of mine) {
      const from = active.value.indexOf(a.quote)
      if (from >= 0) out.push({ id: a.id, from, to: from + a.quote.length, color: a.color })
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active?.value, active?.path, activeIsText, allAnnotations, workspacePath])

  const onQuote = useCallback(
    (action: QuoteAction, sel: { from: number; to: number; text: string }) => {
      if (!active) return
      const line = active.value.slice(0, sel.from).split('\n').length
      if (action.kind === 'annotate') {
        addAnnotation({ path: active.path, quote: sel.text.slice(0, 800), color: action.color, line })
      } else {
        const cite = `> ${sel.text.trim().replace(/\n/g, '\n> ')}\n> — ${relativePath(active.path)}:${line}`
        void navigator.clipboard.writeText(cite)
        pushToast('success', 'Quote copied with source')
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [active?.path, active?.value, addAnnotation, pushToast],
  )

  const editorScroll =
    storeScrollRequest && active && storeScrollRequest.path === active.path
      ? { line: storeScrollRequest.line, seq: storeScrollRequest.seq }
      : null

  const editor = active && activeIsText && (
    <Suspense fallback={<div className="fx-loading aurora"><span className="shimmer-text">Loading editor…</span></div>}>
      <CodeEditor
        value={active.value}
        ext={ext}
        readOnly={active.mode === 'preview'}
        textZoom={liveZoom}
        mergeBase={activeDiff ? diffBases[active.path] ?? '' : null}
        marks={marks}
        inlineNote={inlineNote}
        annotations={annotationRanges}
        scrollRequest={editorScroll}
        initialLine={active.cursor}
        onChange={setActiveValue}
        onSave={save}
        onCursorLine={onCursorLine}
        onQuote={onQuote}
      />
    </Suspense>
  )
  const previewScroll =
    storeScrollRequest && active && storeScrollRequest.path === active.path && storeScrollRequest.heading != null
      ? { index: storeScrollRequest.heading, seq: storeScrollRequest.seq }
      : null
  const documentPreview = active && previewKind ? (
    <Suspense fallback={<div className="fx-loading aurora"><span className="shimmer-text">Loading preview…</span></div>}>
      <DocumentPreview
        key={`${active.path}:${previewKind}`}
        text={active.value}
        kind={previewKind}
        sourcePath={active.path}
        highlight={findText}
        onEdit={editActivePreview}
        scrollHeading={previewScroll}
      />
    </Suspense>
  ) : null
  const activeLatexMain = workspacePath ? latexMain[workspacePath] : undefined
  const activeLatexPdf = activeLatexMain?.replace(/\.tex$/i, '.pdf')
  const pdfSourceTab = pdfSourcePath ? tabs.find((t) => t.path === pdfSourcePath) ?? null : null

  useEffect(() => {
    if (active?.mediaKind !== 'pdf') setPdfSourcePath(null)
  }, [active?.mediaKind, active?.path])

  // one build at a time; a save landing mid-build queues exactly one trailing
  // rebuild so the LAST save always ends up on screen
  const buildInFlight = useRef(false)
  const buildPending = useRef(false)
  const buildMain = useCallback(async () => {
    const main = workspacePath ? latexMain[workspacePath] : undefined
    if (!main) return
    if (buildInFlight.current) {
      buildPending.current = true
      return
    }
    buildInFlight.current = true
    setPdfSourceBuilding(true)
    try {
      do {
        buildPending.current = false
        const built = await bridge.latex.build(main)
        if (built.ok && built.pdf) {
          await refreshFileTab(built.pdf)
        } else if (!built.ok && !built.missing) {
          pushToast('error', built.message ?? 'LaTeX build failed.')
        }
      } while (buildPending.current)
    } finally {
      buildInFlight.current = false
      setPdfSourceBuilding(false)
    }
  }, [latexMain, pushToast, refreshFileTab, workspacePath])

  // idle-debounced AUTO-save of the source pane (the build is triggered by the
  // baseline watcher below, so a manual ⌘S rebuilds exactly the same way)
  useEffect(() => {
    if (!pdfSourceTab || !isTextTab(pdfSourceTab) || pdfSourceTab.loading || pdfSourceTab.value === pdfSourceTab.baseline || !isLatex(pdfSourceTab.path)) return
    const timer = window.setTimeout(() => { void savePath(pdfSourceTab.path, { toast: false }) }, 1200)
    return () => window.clearTimeout(timer)
  }, [pdfSourceTab?.baseline, pdfSourceTab?.loading, pdfSourceTab?.path, pdfSourceTab?.value, savePath])

  // every committed save (auto, ⌘S, the pane's Save button) — and a watcher
  // re-read after an external edit — moves the baseline; each move rebuilds
  const lastBuiltBaseline = useRef<{ path: string; baseline: string } | null>(null)
  useEffect(() => {
    if (!pdfSourceTab || !isTextTab(pdfSourceTab) || pdfSourceTab.loading || !isLatex(pdfSourceTab.path)) return
    const prev = lastBuiltBaseline.current
    lastBuiltBaseline.current = { path: pdfSourceTab.path, baseline: pdfSourceTab.baseline }
    // first sight of this pane (fresh open) is not a save — don't build for it
    if (!prev || prev.path !== pdfSourceTab.path || prev.baseline === pdfSourceTab.baseline) return
    void buildMain()
  }, [buildMain, pdfSourceTab?.baseline, pdfSourceTab?.loading, pdfSourceTab?.path])

  // latexSyncEnabled covers ANY pdf in the workspace: syncFromPdf handles
  // every miss itself — no SyncTeX data builds the SIBLING .tex and retries,
  // and a pdf with no source at all gets one quiet "could not map" toast.
  // The old gate (this pdf must be latexMain's own pdf) made double-click
  // silently dead until the user had explicitly picked/built a main.
  const mediaPreview = active && activeIsMedia ? (
    <MediaPreview
      tab={active}
      zoom={liveZoom}
      latexSyncEnabled={isDesktop && !!workspacePath}
      onPdfSync={syncFromPdf}
    />
  ) : null
  // svg previews straight from the edit buffer, so Split shows changes live
  const svgPreview = active && activeIsSvg ? (
    <div className="fx-media fx-media-image">
      <div className="fx-media-stage">
        <img
          src={`data:image/svg+xml;utf8,${encodeURIComponent(active.value)}`}
          alt={fileName(active.path)}
          draggable={false}
        />
      </div>
    </div>
  ) : null
  const inlinePreview = documentPreview ?? svgPreview
  const pdfSourceDirty = !!pdfSourceTab && isTextTab(pdfSourceTab) && pdfSourceTab.value !== pdfSourceTab.baseline
  const pdfSourceStyle = {
    '--fx-file-font': `${15 * pdfSourceZoom}px`,
    '--fx-code-font': `${13 * pdfSourceZoom}px`,
  } as CSSProperties
  const pdfSourcePane = active?.mediaKind === 'pdf' && pdfSourceTab ? (
    <div className="fx-pdf-source-pane" style={pdfSourceStyle}>
      <div className="fx-pdf-source-head">
        <Icon name={fileIcon(fileName(pdfSourceTab.path))} size={13} />
        <span className="truncate" title={pdfSourceTab.path}>{fileName(pdfSourceTab.path)}</span>
        {pdfSourceScroll?.path === pdfSourceTab.path && <span className="faint">:{pdfSourceScroll.line}</span>}
        {pdfSourceDirty && <span className="fx-dirty" title="Unsaved changes" />}
        {pdfSourceBuilding && <Icon name="LoaderCircle" size={12} className="spin muted" />}
        <span className="grow" />
        <button
          className="fx-zoom-pill"
          onClick={() => setLivePdfSourceZoom(1)}
          title="Pinch over this source pane to zoom it independently. Click to reset."
        >
          {Math.round(pdfSourceZoom * 100)}%
        </button>
        <button className="btn-icon btn-sm" onClick={() => void savePath(pdfSourceTab.path)} disabled={!pdfSourceDirty || pdfSourceTab.saving} title="Save source">
          <Icon name={pdfSourceTab.saving ? 'LoaderCircle' : 'Check'} size={12} className={pdfSourceTab.saving ? 'spin' : undefined} />
        </button>
        <button className="btn-icon btn-sm" onClick={() => setPdfSourcePath(null)} title="Close source pane">
          <Icon name="X" size={12} />
        </button>
      </div>
      {pdfSourceTab.loading ? (
        <div className="fx-loading aurora"><span className="shimmer-text">Loading source…</span></div>
      ) : pdfSourceTab.readError ? (
        <div className="fx-error"><Icon name="FileWarning" size={15} /> {pdfSourceTab.readError}</div>
      ) : (
        <Suspense fallback={<div className="fx-loading aurora"><span className="shimmer-text">Loading editor…</span></div>}>
          <CodeEditor
            value={pdfSourceTab.value}
            ext={fileExt(pdfSourceTab.path)}
            readOnly={false}
            textZoom={pdfSourceZoom}
            mergeBase={null}
            marks={pdfSourceDirty ? changedNewLines(pdfSourceTab.baseline, pdfSourceTab.value).map((c) => ({ line: c.line, color: 'var(--warn)' })) : []}
            inlineNote={null}
            annotations={[]}
            scrollRequest={pdfSourceScroll && pdfSourceScroll.path === pdfSourceTab.path ? { line: pdfSourceScroll.line, seq: pdfSourceScroll.seq } : null}
            initialLine={pdfSourceTab.cursor}
            onChange={(value) => setTabValue(pdfSourceTab.path, value)}
            onSave={() => void savePath(pdfSourceTab.path)}
            onCursorLine={(line) => {
              setTabs((prev) => prev.map((t) => (t.path === pdfSourceTab.path && t.cursor !== line ? { ...t, cursor: line } : t)))
            }}
          />
        </Suspense>
      )}
    </div>
  ) : null

  const searchBox = workspacePath && (
    <div className="fx-search-wrap">
      <Icon name="Search" size={13} className="muted" />
      <input
        value={query}
        onFocus={() => setSearchOpen(true)}
        onChange={(e) => { setQuery(e.target.value); setSearchOpen(true) }}
        placeholder="Search files..."
        spellCheck={false}
      />
      {query && (
        <button className="fx-search-clear" onClick={() => { setQuery(''); setSearchResults([]) }} title="Clear search">
          <Icon name="X" size={12} />
        </button>
      )}
      {searchOpen && query.trim() && (
        <div className="fx-search-menu">
          {searching ? (
            <div className="fx-search-empty">Searching...</div>
          ) : searchResults.length ? (
            <>
              {searchResults.map((result) => (
                <button
                  key={result.path}
                  className="fx-search-result"
                  onMouseDown={(e) => { e.preventDefault(); void open(result.path) }}
                  title={relativePath(result.path)}
                >
                  <Icon name={fileIcon(result.name)} size={13} className="fx-icon" />
                  <span className="grow truncate">{result.name}</span>
                  <span className="faint truncate">{relativePath(result.path)}</span>
                </button>
              ))}
              {searchTruncated && <div className="fx-search-empty">Showing first {searchResults.length} matches.</div>}
            </>
          ) : (
            <div className="fx-search-empty">No file matches.</div>
          )}
        </div>
      )}
    </div>
  )

  const tabStrip = tabs.length > 0 && (
    <div className="fx-tabs fx-tabs-inline">
      {tabs.map((tab) => {
        const tabDirty = isTextTab(tab) && tab.value !== tab.baseline
        return (
          <button
            key={tab.path}
            className="fx-tab"
            data-active={tab.path === activePath}
            data-preview={!tab.pinned || undefined}
            onClick={() => setActivePath(tab.path)}
            onDoubleClick={() => pinTab(tab.path)}
            title={tab.pinned ? tab.path : `${tab.path} — preview · double-click to pin`}
          >
            <Icon name={fileIcon(fileName(tab.path))} size={13} />
            <span className="truncate">{fileName(tab.path)}</span>
            {tabDirty && <span className="fx-dirty" title="Unsaved changes" />}
            <span
              className="fx-tab-close"
              onClick={(e) => { e.stopPropagation(); closeTab(tab.path) }}
              title="Close tab"
            >
              <Icon name="X" size={11} />
            </span>
          </button>
        )
      })}
    </div>
  )

  const activeActions = active && (
    <div className="fx-inline-actions">
      <button
        className="fx-zoom-pill"
        onClick={() => setLiveFileZoom(1, 20)}
        title={activeIsMedia ? 'Pinch on the trackpad to zoom the media. Click to reset.' : 'Pinch on the trackpad to zoom file text. Click to reset.'}
      >
        {Math.round(liveZoom * 100)}%
      </button>
      {previewKind && active.mode !== 'edit' && !active.readError && (
        <div className="fx-doc-find">
          <Icon name="Search" size={12} className="muted" />
          <input
            value={findText}
            onChange={(e) => setFindText(e.target.value)}
            placeholder="Find in document"
            spellCheck={false}
          />
          {findText && <span className="fx-find-count">{findMatches}</span>}
          {findText && (
            <button onClick={() => setFindText('')} title="Clear find">
              <Icon name="X" size={11} />
            </button>
          )}
        </div>
      )}
      {!active.readError && !activeIsMedia && (!activeIsLatex || changes !== null) && (
        <div className="fx-modes">
          {activeIsLatex ? (
            <>
              {changes !== null && (
                <ModeBtn
                  icon="GitCompare"
                  label="Diff"
                  active={activeDiff}
                  onClick={() => void toggleDiff(active.path)}
                />
              )}
            </>
          ) : (
            <>
              {canPreview && <ModeBtn icon="Eye" label="Preview" active={active.mode === 'preview'} onClick={() => setActiveMode('preview')} />}
              {!canPreview && <ModeBtn icon="Eye" label="View" active={active.mode === 'preview'} onClick={() => setActiveMode('preview')} />}
              <ModeBtn icon="Pencil" label={canPreview ? 'Source' : 'Edit'} active={active.mode === 'edit'} onClick={() => setActiveMode('edit')} />
              {canPreview && <ModeBtn icon="Columns2" label="Split" active={active.mode === 'split'} onClick={() => setActiveMode('split')} />}
              {changes !== null && (
                <ModeBtn
                  icon="GitCompare"
                  label="Diff"
                  active={activeDiff}
                  onClick={() => void toggleDiff(active.path)}
                />
              )}
            </>
          )}
        </div>
      )}
      {activeIsText && (
        <button className="btn btn-sm fx-save" disabled={!dirty || active.saving} onClick={save} title="Save  ⌘S">
          <Icon name={active.saving ? 'LoaderCircle' : 'Check'} size={13} className={active.saving ? 'spin' : ''} />
          {active.saving ? 'Saving' : 'Save'}
        </button>
      )}
    </div>
  )

  if (!isDesktop) {
    return (
      <div className="view files-view">
        <EmptyState icon="FolderTree" title="The file explorer runs in the desktop app" hint="npm run electron:dev" />
      </div>
    )
  }
  if (!workspacePath) {
    return (
      <div className="view files-view">
        <div className="fx-blank">
          <button className="btn btn-sm" onClick={openFolder}><Icon name="FolderOpen" size={13} /> Open folder</button>
        </div>
      </div>
    )
  }

  return (
    <div className="view files-view">
      <div
        ref={paneRef}
        className="fx-pane"
        style={paneStyle}
        onPointerEnter={() => { pointerInPaneRef.current = true }}
        onPointerLeave={() => { pointerInPaneRef.current = false }}
      >
        <div className="fx-file-chrome">
          <div className="fx-toolbar fx-toolbar-main">
            {searchBox}
            {tabStrip}
          </div>
          <div className="fx-toolbar fx-toolbar-sub">
            {latexMode && isDesktop && workspacePath ? (
              <LatexBar inline />
            ) : isDesktop && workspacePath ? (
              <button
                className="btn btn-sm fx-changes-chip"
                data-active={latexMode}
                onClick={() => setLatexMode(!latexMode)}
                title={latexMode ? 'Leave LaTeX mode' : 'LaTeX mode — build the paper, inspect PDFs'}
              >
                <Icon name="Sigma" size={13} />
                LaTeX
              </button>
            ) : null}
            <span className="grow" />
            {activeActions}
            {changes !== null && (
              <div className="fx-changes-wrap">
                <button
                  className="btn btn-sm fx-changes-chip fx-toolbar-icon"
                  data-active={changesOpen}
                  onClick={() => setChangesOpen((o) => !o)}
                  title={lastCkpt ? `Changes since “${lastCkpt.label}”` : 'Uncommitted changes (vs HEAD)'}
                >
                  <Icon name="GitCompare" size={13} />
                  {changes.length > 0 && <span className="fx-chip-count">{changes.length}</span>}
                </button>
                {changesOpen && (
                  <div className="fx-changes-menu" onMouseLeave={() => setChangesOpen(false)}>
                    <div className="fx-changes-head">
                      <span className="grow truncate">
                        {lastCkpt ? `Since checkpoint · ${lastCkpt.label}` : 'Vs HEAD — no checkpoint yet'}
                      </span>
                      <button
                        className="btn btn-ghost btn-sm"
                        onClick={() => { void snapshotWorkspace('Manual checkpoint'); setChangesOpen(false) }}
                        title="Snapshot the whole working tree now"
                      >
                        <Icon name="Camera" size={12} /> Checkpoint
                      </button>
                      {lastCkpt && (
                        <button
                          className="btn btn-ghost btn-sm"
                          onClick={() => { void restoreRepoCheckpoint(lastCkpt.id); setChangesOpen(false) }}
                          title={`Rewind every file to “${lastCkpt.label}”`}
                        >
                          <Icon name="History" size={12} /> Restore
                        </button>
                      )}
                      <button
                        className="btn btn-ghost btn-sm"
                        onClick={() => { useKaisola.getState().openGitPanel(); setChangesOpen(false) }}
                        title="Stage & commit these changes — the commit panel opens as a card"
                      >
                        <Icon name="GitCommitHorizontal" size={12} /> Commit…
                      </button>
                    </div>
                    {changes.length === 0 && <div className="fx-search-empty">No changes.</div>}
                    {changes.slice(0, 40).map((c) => (
                      <button
                        key={c.path}
                        className="fx-search-result"
                        onMouseDown={(e) => {
                          e.preventDefault()
                          const abs = workspacePath ? `${workspacePath}/${c.path}` : c.path
                          setChangesOpen(false)
                          void open(abs, 'edit', { pinned: true }).then(() => {
                            if (!diffPaths.has(abs)) void toggleDiff(abs)
                          })
                        }}
                        title={`${c.path} — open with diff`}
                      >
                        <span className="fx-change-code" data-code={c.status}>{c.status}</span>
                        <span className="grow truncate">{c.path}</span>
                      </button>
                    ))}
                    {changes.length > 40 && <div className="fx-search-empty">…and {changes.length - 40} more.</div>}
                  </div>
                )}
              </div>
            )}
            <button className="btn btn-sm fx-toolbar-icon" onClick={openFolder} title={workspacePath}>
              <Icon name="FolderOpen" size={13} />
            </button>
          </div>
        </div>

        {active ? (
          <>
            <div className={`fx-viewer${pdfSourcePane ? ' fx-viewer-pdf-split' : ''}`}>
              <div className={pdfSourcePane ? 'fx-pdf-main-pane' : 'fx-viewer-main'}>
                {active.loading ? (
                  <div className="fx-loading aurora"><span className="shimmer-text">Loading…</span></div>
                ) : active.readError ? (
                  <div className="fx-error"><Icon name="FileWarning" size={15} /> {active.readError}</div>
                ) : mediaPreview ? (
                  mediaPreview
                ) : active.mode === 'preview' && inlinePreview ? (
                  inlinePreview
                ) : active.mode === 'split' && inlinePreview ? (
                  <div className="fx-split">
                    <div className="fx-split-src">{editor}</div>
                    <div className="fx-split-prev">{inlinePreview}</div>
                  </div>
                ) : (
                  editor
                )}
              </div>
              {pdfSourcePane}
            </div>
          </>
        ) : (
          <div className="fx-blank">
            <Icon name="FileText" size={22} />
            <p>Search or select a file to read it.</p>
            <p className="faint">Open multiple files to keep them in tabs.</p>
          </div>
        )}
      </div>
    </div>
  )
}

function MediaPreview({
  tab,
  zoom,
  latexSyncEnabled,
  onPdfSync,
}: {
  tab: FileTab
  zoom: number
  latexSyncEnabled?: boolean
  onPdfSync?: (req: { pdfPath: string; page: number; x: number; y: number }) => void
}) {
  const meta = [tab.mime, formatBytes(tab.size)].filter(Boolean).join(' · ')
  if (tab.mediaKind === 'image' && tab.dataUrl) {
    return (
      <div className="fx-media fx-media-image">
        <div className="fx-media-stage">
          <img src={tab.dataUrl} alt={fileName(tab.path)} draggable={false} />
        </div>
        {meta && <div className="fx-media-meta">{meta}</div>}
      </div>
    )
  }
  const pdfSrc = tab.mediaKind === 'pdf' ? tab.previewUrl ?? tab.dataUrl : null
  if (pdfSrc) {
    return (
      <PdfRasterPreview
        tab={tab}
        zoom={zoom}
        latexSyncEnabled={latexSyncEnabled}
        onPdfSync={onPdfSync}
      />
    )
  }
  return (
    <div className="fx-media fx-media-empty">
      <Icon name="FileQuestion" size={22} />
      <p>Preview unavailable</p>
      {meta && <p className="faint">{meta}</p>}
    </div>
  )
}

function PdfRasterPreview({
  tab,
  zoom,
  latexSyncEnabled,
  onPdfSync,
}: {
  tab: FileTab
  zoom: number
  latexSyncEnabled?: boolean
  onPdfSync?: (req: { pdfPath: string; page: number; x: number; y: number }) => void
}) {
  const [info, setInfo] = useState<PdfInfoState | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [nativeFallback, setNativeFallback] = useState(false)
  const [activePage, setActivePage] = useState(1)
  const [pages, setPages] = useState<Record<number, PdfPageImage>>({})
  const loadingRef = useRef<Set<string>>(new Set())
  const scrollerRef = useRef<HTMLDivElement>(null)
  // a hard failure (no poppler, render error) latches the native fallback;
  // the slow-first-page timer latch must UN-latch when the render lands
  const errorLatchedRef = useRef(false)
  const renderScale = Math.min(2.5, Math.max(1, zoom * (window.devicePixelRatio || 1)))
  // quarter-step buckets — mirrors fs:pdfPage's dpi quantization, so zoom only
  // re-renders when it actually crosses into a new dpi
  const scaleBucket = Math.round(renderScale * 4) / 4
  // the file VERSION: previewUrl is a stable per-path token, so mtimeMs is the
  // only signal a rebuild changed the bytes — it must reset the page cache
  const version = tab.mtimeMs ?? 0
  const identityRef = useRef({ path: tab.path, version })

  useEffect(() => {
    let cancelled = false
    const prevPath = identityRef.current.path
    identityRef.current = { path: tab.path, version }
    setInfo(null)
    setMessage(null)
    setNativeFallback(false)
    errorLatchedRef.current = false
    // a rebuild of the SAME file keeps the reading position; a new file starts at 1
    setActivePage((p) => (prevPath === tab.path ? p : 1))
    setPages({})
    loadingRef.current.clear()
    void bridge.fs.pdfInfo(tab.path).then((r) => {
      if (cancelled) return
      if (r.ok && r.pages && r.width && r.height) setInfo({ pages: r.pages, width: r.width, height: r.height })
      else {
        setMessage(r.message ?? 'Could not inspect this PDF.')
        errorLatchedRef.current = true
        setNativeFallback(true)
      }
    })
    return () => { cancelled = true }
  }, [tab.path, version])

  const ensurePage = useCallback((page: number) => {
    if (!info || page < 1 || page > info.pages) return
    const cached = pages[page]
    if (cached && cached.renderedFor === scaleBucket) return
    const loadKey = `${page}@${scaleBucket}`
    if (loadingRef.current.has(loadKey)) return
    loadingRef.current.add(loadKey)
    const requestedFor = { path: tab.path, version }
    void bridge.fs.pdfPage(tab.path, page, renderScale).then((r) => {
      loadingRef.current.delete(loadKey)
      // a render resolving after the tab/version moved on must not leak the
      // previous PDF's pixels (or its error) into the new state
      if (identityRef.current.path !== requestedFor.path || identityRef.current.version !== requestedFor.version) return
      if (!r.ok || !r.url) {
        setMessage(r.message ?? 'Could not render this PDF page.')
        errorLatchedRef.current = true
        setNativeFallback(true)
        return
      }
      setPages((current) => ({ ...current, [page]: { url: r.url!, width: r.width ?? 0, height: r.height ?? 0, scale: r.scale ?? renderScale * 2, renderedFor: scaleBucket } }))
      // the raster arrived — leave the slow-page fallback if no hard error hit
      if (page === 1 && !errorLatchedRef.current) setNativeFallback(false)
    })
  }, [info, pages, renderScale, scaleBucket, tab.path, version])

  useEffect(() => {
    if (!info) return
    for (let page = Math.max(1, activePage - 2); page <= Math.min(info.pages, activePage + 3); page += 1) ensurePage(page)
  }, [activePage, ensurePage, info])

  useEffect(() => {
    if (!info || pages[1] || nativeFallback) return
    const timer = window.setTimeout(() => {
      if (!pages[1]) setNativeFallback(true)
    }, 3200)
    return () => window.clearTimeout(timer)
  }, [info, nativeFallback, pages])

  const onScroll = useCallback(() => {
    const scroller = scrollerRef.current
    if (!scroller) return
    const mid = scroller.getBoundingClientRect().top + scroller.clientHeight * 0.38
    let next = activePage
    let best = Infinity
    for (const node of Array.from(scroller.querySelectorAll<HTMLElement>('.fx-pdf-page'))) {
      const rect = node.getBoundingClientRect()
      const distance = Math.abs(rect.top + rect.height * 0.15 - mid)
      if (distance < best) {
        best = distance
        next = Number(node.dataset.page || activePage)
      }
    }
    if (Number.isFinite(next) && next !== activePage) setActivePage(next)
  }, [activePage])

  const onDoubleClick = useCallback((e: ReactMouseEvent<HTMLDivElement>) => {
    if (!info || !latexSyncEnabled || !onPdfSync) return
    const pageEl = (e.target as Element).closest<HTMLElement>('.fx-pdf-page')
    const sheet = pageEl?.querySelector<HTMLElement>('.fx-pdf-sheet')
    if (!pageEl || !sheet) return
    const rect = sheet.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return
    const page = Number(pageEl.dataset.page || 1)
    // per-PAGE point size (px ÷ dpi-scale) — pdfinfo only reports page 1, and a
    // landscape figure page mapped through page 1's box gets wrong synctex x/y
    const image = pages[page]
    const pointsW = image && image.scale > 0 ? image.width / image.scale : info.width
    const pointsH = image && image.scale > 0 ? image.height / image.scale : info.height
    onPdfSync({
      pdfPath: tab.path,
      page,
      x: ((e.clientX - rect.left) / rect.width) * pointsW,
      y: ((e.clientY - rect.top) / rect.height) * pointsH,
    })
  }, [info, latexSyncEnabled, onPdfSync, pages, tab.path])

  // previewUrl is a stable per-path token — the ?v= buster makes the iframe
  // actually reload after a rebuild (a data: url must never be suffixed)
  const nativeSrc = tab.previewUrl ? `${tab.previewUrl}?v=${version}` : tab.dataUrl
  if (nativeFallback && nativeSrc) {
    return (
      <div className="fx-media fx-media-pdf">
        <iframe
          className="fx-pdf-frame"
          src={`${nativeSrc}#view=FitH&navpanes=0&pagemode=none`}
          title={message ? `${fileName(tab.path)} — native fallback: ${message}` : fileName(tab.path)}
        />
      </div>
    )
  }
  if (message) {
    return (
      <div className="fx-media fx-media-empty">
        <Icon name="FileWarning" size={22} />
        <p>{message}</p>
      </div>
    )
  }
  if (!info) {
    return <div className="fx-loading aurora"><span className="shimmer-text">Loading PDF…</span></div>
  }

  const pageWidth = Math.round(Math.max(360, info.width) * zoom)
  return (
    <div
      ref={scrollerRef}
      className="fx-media fx-media-pdf fx-pdf-raster"
      onScroll={onScroll}
      onDoubleClick={onDoubleClick}
      title={latexSyncEnabled ? 'Double-click the PDF page to jump to the source line' : undefined}
    >
      <div className="fx-pdf-pages">
        {Array.from({ length: info.pages }, (_, i) => {
          const page = i + 1
          const image = pages[page]
          // rendered pages know their true size — mixed-size documents (a
          // landscape figure page) must not be squashed to page 1's box
          const ratio = image && image.width > 0 && image.height > 0
            ? `${image.width} / ${image.height}`
            : `${info.width} / ${info.height}`
          return (
            <div
              key={page}
              className="fx-pdf-page"
              data-page={page}
              style={{ width: pageWidth, aspectRatio: ratio }}
            >
              <div className="fx-pdf-sheet">
                {image ? (
                  <img src={image.url} alt={`${fileName(tab.path)} page ${page}`} draggable={false} />
                ) : (
                  <div className="fx-pdf-page-loading">Page {page}</div>
                )}
              </div>
              <span className="fx-pdf-page-num">{page} / {info.pages}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function ModeBtn({ icon, label, active, onClick }: { icon: string; label: string; active: boolean; onClick: () => void }) {
  return (
    <button className="fx-mode" data-active={active} onClick={onClick} title={label}>
      <Icon name={icon} size={12} />
      <span>{label}</span>
    </button>
  )
}
