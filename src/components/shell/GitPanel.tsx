import { useCallback, useEffect, useRef, useState } from 'react'
import { EditorView } from '@codemirror/view'
import { EditorState } from '@codemirror/state'
import { lineNumbers, highlightSpecialChars } from '@codemirror/view'
import { syntaxHighlighting } from '@codemirror/language'
import { MergeView } from '@codemirror/merge'
import { useKaisola } from '../../store/store'
import { bridge, isDesktop, type GitStageEntry, type GitLogEntry } from '../../lib/bridge'
import { Icon } from '../Icon'
import { languageFor, highlightStyle, baseTheme } from '../codeEditorConfig'

const fileExt = (p: string) => (p.includes('.') ? p.split('.').pop() : undefined)

/**
 * Side-by-side diff (Kairn/Zed-style): HEAD on the left, the working tree on
 * the right. Read-only — edits belong to the Files editor; this is the review
 * surface for what a commit will contain.
 */
function SideBySideDiff({ base, current, ext }: { base: string; current: string; ext?: string }) {
  const hostRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const shared = [
      baseTheme,
      syntaxHighlighting(highlightStyle, { fallback: true }),
      languageFor(ext),
      lineNumbers(),
      highlightSpecialChars(),
      EditorView.editable.of(false),
      EditorState.readOnly.of(true),
      EditorView.lineWrapping,
    ]
    const view = new MergeView({
      a: { doc: base, extensions: shared },
      b: { doc: current, extensions: shared },
      parent: host,
      highlightChanges: true,
      gutter: true,
    })
    return () => view.destroy()
  }, [base, current, ext])
  return <div ref={hostRef} className="git-diff-host" />
}

/**
 * The commit panel card — browse, stage, and commit without leaving the
 * window (Kairn's git loop). This is the ONLY surface that touches the real
 * index; checkpoints stay in their shadow repo. Click a file for the
 * side-by-side diff; +/− stage and unstage; the message box commits.
 */
export function GitPanel() {
  const workspacePath = useKaisola((s) => s.workspacePath)
  const pushToast = useKaisola((s) => s.pushToast)
  const [branch, setBranch] = useState<string | null>(null)
  const rootRef = useRef<string | null>(null)
  const [notRepo, setNotRepo] = useState(false)
  const [staged, setStaged] = useState<GitStageEntry[]>([])
  const [unstaged, setUnstaged] = useState<GitStageEntry[]>([])
  const [log, setLog] = useState<GitLogEntry[]>([])
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  const [diff, setDiff] = useState<{ path: string; base: string; current: string } | null>(null)
  // last-fired wins: a slow watcher-triggered status must never overwrite the
  // result of a later post-stage/post-commit refresh
  const refreshSeq = useRef(0)
  // last-clicked wins: a slow diff read for one file must never overwrite the
  // diff of a later-clicked file
  const openSeq = useRef(0)

  const refresh = useCallback(async () => {
    if (!workspacePath || !isDesktop) return
    const seq = ++refreshSeq.current
    const r = await bridge.git.stageStatus(workspacePath)
    if (seq !== refreshSeq.current) return
    if (!r.ok) {
      setNotRepo(!!r.notRepo)
      setStaged([])
      setUnstaged([])
      return
    }
    setNotRepo(false)
    rootRef.current = r.root ?? null
    setBranch(r.branch ?? null)
    setStaged(r.staged ?? [])
    setUnstaged(r.unstaged ?? [])
    const lg = await bridge.git.log(workspacePath, 5)
    if (seq !== refreshSeq.current) return
    setLog(lg.ok ? lg.commits ?? [] : [])
  }, [workspacePath])

  // live: refresh on workspace file changes (debounced), and on mount
  useEffect(() => {
    void refresh()
    if (!workspacePath || !isDesktop) return
    let timer: number | null = null
    const stop = bridge.fs.watch(workspacePath, () => {
      if (timer) window.clearTimeout(timer)
      timer = window.setTimeout(() => void refresh(), 400)
    })
    return () => {
      if (timer) window.clearTimeout(timer)
      stop()
    }
  }, [refresh, workspacePath])

  const act = async (fn: () => Promise<{ ok: boolean; message?: string }>) => {
    setBusy(true)
    const r = await fn()
    setBusy(false)
    if (!r.ok && r.message) pushToast('error', r.message)
    void refresh()
  }

  const openDiff = async (entry: GitStageEntry, stagedSide: boolean) => {
    const root = rootRef.current
    if (!root) return
    const seq = ++openSeq.current
    const abs = `${root}/${entry.path}`
    // a STAGED row previews what the commit will actually contain: HEAD vs the
    // INDEX (:0:path). An unstaged row previews the worktree edits.
    const [baseR, curR] = await Promise.all([
      entry.untracked ? Promise.resolve({ ok: true as const, content: '' }) : bridge.git.show(root, 'HEAD', abs),
      entry.status === 'D'
        ? Promise.resolve({ ok: true as const, content: '' })
        : stagedSide
          ? bridge.git.show(root, ':0', abs)
          : bridge.fs.read(abs),
    ])
    if (seq !== openSeq.current) return
    setDiff({
      path: entry.path,
      base: 'content' in baseR && typeof baseR.content === 'string' ? baseR.content : '',
      current: 'content' in curR && typeof curR.content === 'string' ? curR.content : '',
    })
  }

  const commit = async () => {
    if (!workspacePath || !message.trim() || !staged.length) return
    setBusy(true)
    const r = await bridge.git.commit(workspacePath, message.trim())
    setBusy(false)
    if (r.ok) {
      pushToast('success', `Committed ${r.sha ?? ''} — ${message.trim().split('\n')[0]}`)
      setMessage('')
      setDiff(null)
    } else pushToast('error', r.message ?? 'Commit failed.')
    void refresh()
  }

  if (!isDesktop) return <div className="git-panel git-panel-empty">Git runs in the desktop app.</div>
  if (!workspacePath) return <div className="git-panel git-panel-empty">Open a folder to use git.</div>
  if (notRepo) return <div className="git-panel git-panel-empty">Not a git repository.</div>

  const fileRow = (entry: GitStageEntry, stagedSide: boolean) => (
    <div key={`${stagedSide ? 's' : 'u'}:${entry.path}`} className="git-file-row" data-active={diff?.path === entry.path}>
      <button type="button" className="git-file-main" onClick={() => void openDiff(entry, stagedSide)} title={entry.conflicted ? `${entry.path} — merge conflict: resolve in the file, then stage` : `${entry.path} — view diff`}>
        <span className="fx-change-code" data-code={entry.conflicted ? 'D' : entry.status}>{entry.status}</span>
        <span className="truncate">{entry.path}</span>
        {entry.conflicted && <span className="git-conflict-tag">conflict</span>}
      </button>
      {!entry.conflicted && (
        <button type="button"
          className="git-file-act"
          disabled={busy}
          onClick={() => void act(() => (stagedSide ? bridge.git.unstage(workspacePath, [entry.path]) : bridge.git.stage(workspacePath, [entry.path])))}
          title={stagedSide ? 'Unstage' : 'Stage'}
          aria-label={`${stagedSide ? 'Unstage' : 'Stage'} ${entry.path}`}
        >
          <Icon name={stagedSide ? 'Minus' : 'Plus'} size={12} />
        </button>
      )}
    </div>
  )

  return (
    <div className="git-panel">
      <div className="git-head">
        <Icon name="GitBranch" size={12} className="muted" />
        <span className="git-branch truncate">{branch ?? '(no branch)'}</span>
        <span className="grow" />
        {diff && (
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDiff(null)}>
            <Icon name="ArrowLeft" size={12} /> Files
          </button>
        )}
      </div>

      {diff ? (
        <div className="git-diff">
          <div className="git-diff-path truncate" title={diff.path}>{diff.path}</div>
          <SideBySideDiff base={diff.base} current={diff.current} ext={fileExt(diff.path)} />
        </div>
      ) : (
        <>
          <div className="git-files">
            {unstaged.length > 0 && (
              <div className="git-group">
                <div className="git-group-head">
                  <span className="grow">Changes · {unstaged.length}</span>
                  <button type="button"
                    className="git-group-act"
                    disabled={busy || unstaged.every((f) => f.conflicted)}
                    onClick={() => void act(() => bridge.git.stage(workspacePath, unstaged.flatMap((file) => file.conflicted ? [] : [file.path])))}
                  >
                    Stage all
                  </button>
                </div>
                {unstaged.map((f) => fileRow(f, false))}
              </div>
            )}
            {staged.length > 0 && (
              <div className="git-group">
                <div className="git-group-head">
                  <span className="grow">Staged · {staged.length}</span>
                  <button type="button"
                    className="git-group-act"
                    disabled={busy}
                    onClick={() => void act(() => bridge.git.unstage(workspacePath, staged.map((f) => f.path)))}
                  >
                    Unstage all
                  </button>
                </div>
                {staged.map((f) => fileRow(f, true))}
              </div>
            )}
            {!staged.length && !unstaged.length && <div className="git-panel-empty">Working tree clean.</div>}
          </div>

          <div className="git-commit">
            <textarea
              className="git-commit-msg"
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="Commit message"
              rows={2}
              spellCheck={false}
              onKeyDown={(e) => {
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') void commit()
              }}
            />
            <button type="button"
              className="btn btn-primary btn-sm git-commit-btn"
              disabled={busy || !message.trim() || !staged.length}
              onClick={() => void commit()}
              title={staged.length ? '⌘↩ commits' : 'Stage files first'}
            >
              <Icon name="Check" size={12} /> Commit{staged.length ? ` · ${staged.length}` : ''}
            </button>
          </div>

          {log.length > 0 && (
            <div className="git-log">
              {log.map((c) => (
                <div key={c.sha} className="git-log-row" title={`${c.sha} · ${c.author} · ${c.when}`}>
                  <span className="git-log-sha">{c.sha}</span>
                  <span className="truncate">{c.subject}</span>
                  <span className="git-log-when">{c.when}</span>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  )
}
