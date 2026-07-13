import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { useKaisola } from '../../store/store'
import { bridge, isDesktop, type FsEntry, type LatexBuildResult } from '../../lib/bridge'
import { summarizeWithModel } from '../../lib/summarize'
import { Icon } from '../Icon'
import { Dropdown } from '../Dropdown'

const relTo = (root: string, p: string) => (p.startsWith(`${root}/`) ? p.slice(root.length + 1) : p)

/**
 * The LaTeX-mode strip. Build runs HEADLESSLY in main (latexmk → tectonic →
 * pdflatex, whichever exists) — no terminal card, no log spew. Success leaves
 * the PDF closed by default; the PDF button opens it on demand.
 * failure renders parsed file:line errors you can click, with a short model
 * explanation when a reasoning provider is configured. Git/Overleaf setup
 * stays in the agent/git workflow instead of this compact toolbar.
 */
export function LatexBar({ inline = false }: { inline?: boolean } = {}) {
  const workspacePath = useKaisola((s) => s.workspacePath)
  const latexMain = useKaisola((s) => s.latexMain)
  const setLatexMain = useKaisola((s) => s.setLatexMain)
  const openFilePath = useKaisola((s) => s.openFilePath)
  const setLatexMode = useKaisola((s) => s.setLatexMode)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const requestFile = useKaisola((s) => s.requestFile)
  const requestScroll = useKaisola((s) => s.requestScroll)
  const pushToast = useKaisola((s) => s.pushToast)

  const [texFiles, setTexFiles] = useState<string[]>([])
  const [building, setBuilding] = useState(false)
  const [result, setResult] = useState<LatexBuildResult | null>(null)
  const [summary, setSummary] = useState<string | null>(null)
  const [summarizing, setSummarizing] = useState(false)
  const buildSeq = useRef(0)
  const inlineWrapRef = useRef<HTMLDivElement>(null)
  const [issueFrame, setIssueFrame] = useState<CSSProperties | undefined>()

  useEffect(() => {
    if (!workspacePath || !isDesktop) return
    let cancelled = false
    void bridge.fs.search(workspacePath, '.tex').then(async (r) => {
      if (cancelled) return
      const found = (r.entries ?? []).flatMap((entry: FsEntry) => !entry.dir && entry.path.endsWith('.tex') ? [entry.path] : [])
      setTexFiles(found)
      // a persisted main that no longer exists (renamed/moved since) must not
      // shadow the real files — Build against it fails with "Pick a .tex"
      const stored = useKaisola.getState().latexMain[workspacePath]
      if (stored && !found.includes(stored)) useKaisola.getState().setLatexMain(workspacePath, null)
      // no main chosen yet → find the real document (shallowest \documentclass,
      // main.tex first) instead of whichever file sorted first
      if (!useKaisola.getState().latexMain[workspacePath] && found.length) {
        const byDepth = [...found].sort(
          (a, b) =>
            Number(!/\/main\.tex$/.test(a)) - Number(!/\/main\.tex$/.test(b)) ||
            a.split('/').length - b.split('/').length,
        )
        for (const p of byDepth.slice(0, 8)) {
          const read = await bridge.fs.read(p)
          if (cancelled) return
          if (read.ok && typeof read.content === 'string' && read.content.includes('\\documentclass')) {
            useKaisola.getState().setLatexMain(workspacePath, p)
            break
          }
        }
      }
    })
    return () => { cancelled = true }
  }, [workspacePath])

  const showIssues = !!result && !result.ok
  useEffect(() => {
    if (!inline || !showIssues) {
      setIssueFrame(undefined)
      return
    }
    let raf = 0
    const update = () => {
      if (raf) window.cancelAnimationFrame(raf)
      raf = window.requestAnimationFrame(() => {
        raf = 0
        const rect = inlineWrapRef.current?.getBoundingClientRect()
        if (!rect) return
        const margin = 12
        const viewportWidth = window.innerWidth
        const viewportHeight = window.innerHeight
        const width = Math.max(240, Math.min(760, viewportWidth - margin * 2))
        const left = Math.max(margin, Math.min(rect.left, viewportWidth - width - margin))
        let top = rect.bottom + 8
        let maxHeight = viewportHeight - top - margin
        if (maxHeight < 140) {
          maxHeight = Math.max(120, rect.top - margin - 8)
          top = Math.max(margin, rect.top - maxHeight - 8)
        }
        setIssueFrame({
          position: 'fixed',
          top,
          left,
          width,
          maxHeight,
          minWidth: 0,
          maxWidth: 'none',
        })
      })
    }
    update()
    window.addEventListener('resize', update)
    window.addEventListener('scroll', update, true)
    return () => {
      if (raf) window.cancelAnimationFrame(raf)
      window.removeEventListener('resize', update)
      window.removeEventListener('scroll', update, true)
    }
  }, [inline, showIssues, result?.errors?.length, result?.message, result?.missing, summary, summarizing])

  if (!workspacePath) return null

  const main = latexMain[workspacePath] ?? texFiles.find((p) => p.endsWith('/main.tex')) ?? texFiles[0]
  const activePdfTex = openFilePath?.endsWith('.pdf') ? openFilePath.replace(/\.pdf$/i, '.tex') : undefined
  const activePdfMain = activePdfTex && texFiles.includes(activePdfTex) ? activePdfTex : undefined
  // the OPEN .tex is a target too — the workspace scan runs once, so a file
  // created after it (an agent writing paper.tex) is invisible to texFiles
  // and Build said "no .tex here" while the file sat in the active tab. The
  // resolved main still wins when one exists (multi-file \include projects
  // must build their root, not the open chapter).
  const activeTex = openFilePath?.endsWith('.tex') ? openFilePath : undefined
  const buildTarget = activePdfMain ?? main ?? activeTex
  // the picker shows the open .tex even when the stale scan missed it
  const texChoices = activeTex && !texFiles.includes(activeTex) ? [...texFiles, activeTex] : texFiles

  const build = async () => {
    if (!buildTarget) { pushToast('info', 'No .tex file in this folder yet.'); return }
    if (activePdfMain && activePdfMain !== latexMain[workspacePath]) setLatexMain(workspacePath, activePdfMain)
    // first build via the open-file fallback adopts it as the main
    else if (buildTarget === activeTex && activeTex !== latexMain[workspacePath]) setLatexMain(workspacePath, activeTex)
    const seq = ++buildSeq.current
    setBuilding(true)
    setResult(null)
    setSummary(null)
    let r = await bridge.latex.build(buildTarget)
    // the main went stale mid-session (agent renamed the file): fall back to
    // the OPEN .tex once instead of failing at the user with "Pick a .tex"
    if (!r.ok && /Pick a \.tex/i.test(r.message ?? '') && activeTex && buildTarget !== activeTex && seq === buildSeq.current) {
      setLatexMain(workspacePath, activeTex)
      r = await bridge.latex.build(activeTex)
    }
    if (seq !== buildSeq.current) return
    setBuilding(false)
    setResult(r)
    if (r.ok && r.pdf) {
      pushToast('success', `Built ${relTo(workspacePath, r.pdf)}`)
    } else if (!r.ok && !r.missing && (r.errors?.length || r.logTail)) {
      // model explanation of the failure, via the configured (usually free)
      // reasoning provider — quietly skipped when none can answer
      setSummarizing(true)
      const errText = (r.errors ?? []).map((e) => `${e.file ? `${relTo(workspacePath, e.file)}:${e.line ?? '?'}: ` : ''}${e.message}`).join('\n')
      void summarizeWithModel(
        `This LaTeX build failed. In 2-3 short sentences: what is wrong and what is the most likely fix? No preamble.\n\nErrors:\n${errText || '(none parsed)'}\n\nLog tail:\n${(r.logTail ?? '').slice(-2000)}`,
      ).then((text) => {
        if (seq !== buildSeq.current) return
        setSummarizing(false)
        setSummary(text)
      })
    }
  }

  const openPdf = async () => {
    if (!buildTarget) return
    // derive from the CURRENT target — result?.pdf can be a PREVIOUS target's
    // build, and the button's own tooltip names the current target's pdf
    const pdf = buildTarget.replace(/\.tex$/, '.pdf')
    const dir = pdf.slice(0, pdf.lastIndexOf('/'))
    const ls = await bridge.fs.list(dir)
    if (ls.ok && ls.entries?.some((e) => e.path === pdf)) requestFile(pdf, undefined, { pinned: false })
    else pushToast('info', 'No PDF yet — Build first.')
  }

  const jumpTo = (file?: string, line?: number) => {
    if (!file) return
    requestFile(file, 'edit', { pinned: true })
    if (line) window.setTimeout(() => requestScroll(file, line), 200)
  }

  const issues = result && !result.ok ? result.errors ?? [] : []
  const issueStyle = inline ? issueFrame ?? { visibility: 'hidden' } : undefined
  const issueKeyCounts = new Map<string, number>()

  const issuesView = result && !result.ok && (
    <div className={`fx-latex-issues${inline ? ' fx-latex-issues-popover' : ''}`} style={issueStyle}>
      {result.missing ? (
        <div className="fx-latex-issue fx-latex-missing">
          <Icon name="PackageX" size={13} />
          <span className="grow">{result.message} {result.hint}</span>
          <button type="button"
            className="btn btn-sm"
            onClick={() => requestTerminal('brew install tectonic', { cwd: workspacePath, name: 'Install TeX' })}
            title="Installs tectonic — a small self-contained engine that fetches packages on demand"
          >
            <Icon name="Download" size={12} /> Install tectonic
          </button>
        </div>
      ) : (
        <>
          {issues.map((issue) => {
            const identity = JSON.stringify([issue.file ?? '', issue.line ?? '', issue.message, issue.hint ?? ''])
            const occurrence = issueKeyCounts.get(identity) ?? 0
            issueKeyCounts.set(identity, occurrence + 1)
            return (
              <button type="button" key={`${identity}:${occurrence}`} className="fx-latex-issue" onClick={() => jumpTo(issue.file, issue.line)} disabled={!issue.file} title={issue.file ? 'Jump to the line' : undefined}>
                <Icon name="CircleAlert" size={12} className="fx-latex-issue-icon" />
                {issue.file && <span className="fx-latex-loc">{relTo(workspacePath, issue.file)}{issue.line ? `:${issue.line}` : ''}</span>}
                <span className="truncate">{issue.message}</span>
                {issue.hint && <span className="fx-latex-hint">{issue.hint}</span>}
              </button>
            )
          })}
          {!issues.length && <div className="fx-latex-issue"><Icon name="CircleAlert" size={12} className="fx-latex-issue-icon" /><span className="truncate">{result.message}</span></div>}
          {(summarizing || summary) && (
            <div className="fx-latex-summary">
              <Icon name={summarizing ? 'LoaderCircle' : 'Sparkles'} size={12} className={summarizing ? 'spin' : undefined} />
              <span>{summarizing ? 'Explaining the failure…' : summary}</span>
            </div>
          )}
        </>
      )}
    </div>
  )

  const bar = (
      <div className={`fx-latexbar${inline ? ' fx-latexbar-inline' : ''}`}>
        <Icon name="Sigma" size={13} className="muted" />
        {/* the main-file picker must exist in BOTH variants — the inline bar is
            the only one ever mounted, and Build retargets latexMain (line below)
            so the user needs a way to point it back */}
        {texChoices.length > 0 ? (
          <Dropdown
            value={buildTarget ?? ''}
            options={texChoices.map((p) => ({ value: p, name: relTo(workspacePath, p) }))}
            onSelect={(v) => setLatexMain(workspacePath, v)}
            title="Main .tex file (what Build compiles)"
          />
        ) : !inline ? (
          <span className="faint">No .tex files here yet</span>
        ) : null}
        <button type="button" className="btn btn-sm" onClick={() => void build()} disabled={!buildTarget || building} title={buildTarget ? `Compile ${relTo(workspacePath, buildTarget)} with SyncTeX` : 'Compile headlessly — errors come back parsed'}>
          {building ? <Icon name="LoaderCircle" size={12} className="spin" /> : <Icon name="Play" size={12} />}
          {!inline && ' Build'}
        </button>
        <button type="button" className="btn btn-sm" onClick={() => void openPdf()} disabled={!buildTarget} title={buildTarget ? `Open ${relTo(workspacePath, buildTarget.replace(/\.tex$/, '.pdf'))}` : 'Open the built PDF'}>
          <Icon name="FileText" size={12} />
          {!inline && ' PDF'}
        </button>
        {result?.ok && <span className="fx-latex-ok" title={`Built with ${result.engine}`}><Icon name="Check" size={11} /> {!inline && result.engine}</span>}
        {!inline && <span className="grow" />}
        {/* the ONLY mouse path out of LaTeX mode — latexMode persists across
            relaunches, so without this the mode is a one-way door */}
        <button type="button" className="btn-icon btn-sm" onClick={() => setLatexMode(false)} title="Leave LaTeX mode" aria-label="Leave LaTeX mode">
          <Icon name="X" size={13} />
        </button>
      </div>
  )

  if (inline) {
    const portalledIssues = issuesView && typeof document !== 'undefined' ? createPortal(issuesView, document.body) : issuesView
    return <div ref={inlineWrapRef} className="fx-latex-inline-wrap">{bar}{portalledIssues}</div>
  }
  return <div className="fx-latexwrap">{bar}{issuesView}</div>
}
