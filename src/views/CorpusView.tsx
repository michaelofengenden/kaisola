import { useMemo, useState } from 'react'
import { useKaisola } from '../store/store'
import { Icon } from '../components/Icon'
import type { Paper } from '../domain/types'
import { authorList, shortDate, compactNumber } from '../lib/format'

/**
 * The corpus — the entry point. You post a bare link; the Literature agent
 * observes it and adds the paper. Empty by default; the list stays quiet and
 * reading-forward (no faceted dashboard).
 */
export function CorpusView() {
  const corpus = useKaisola((s) => s.project.corpus)
  const addPaperByUrl = useKaisola((s) => s.addPaperByUrl)
  const papers = useMemo(() => corpus.filter((s): s is Paper => s.kind === 'paper'), [corpus])

  const [url, setUrl] = useState('')
  const [q, setQ] = useState('')
  const [openId, setOpenId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    const v = url.trim()
    if (!v || busy) return
    setUrl('')
    setBusy(true)
    try {
      await addPaperByUrl(v)
    } finally {
      setBusy(false)
    }
  }

  const filtered = useMemo(() => {
    const t = q.trim().toLowerCase()
    if (!t) return papers
    return papers.filter((p) => `${p.title} ${p.authors.join(' ')} ${p.abstract ?? ''}`.toLowerCase().includes(t))
  }, [papers, q])

  const empty = papers.length === 0

  return (
    <div className="view corpus-view">
      <div className={empty ? 'corpus-hero' : 'corpus-bar'}>
        {empty && (
          <div className="corpus-hero-copy">
            <h1 className="corpus-hero-title">Post a link.</h1>
            <p className="corpus-hero-sub">
              Paste a paper URL — arXiv, DOI, or any link. An agent observes it and adds it to your corpus.
            </p>
          </div>
        )}
        <div className="addlink">
          <Icon name="Link" size={15} className="addlink-icon" />
          <input
            className="addlink-input"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && submit()}
            placeholder="https://arxiv.org/abs/…"
            autoFocus={empty}
            spellCheck={false}
          />
          <button className="btn btn-primary btn-sm" onClick={submit} disabled={!url.trim() || busy}>
            {busy ? <Icon name="LoaderCircle" size={13} className="spin" /> : <Icon name="ArrowRight" size={13} />}
            Observe
          </button>
        </div>
        {empty && (
          <p className="corpus-hero-hint faint">
            Nothing here yet · <kbd>⌘K</kbd> → “Load demo project” to explore with sample data
          </p>
        )}
      </div>

      {!empty && (
        <>
          <div className="corpus-search">
            <Icon name="Search" size={13} className="muted" />
            <input
              className="corpus-search-input"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Filter corpus…"
              spellCheck={false}
            />
            <span className="faint" style={{ fontSize: 'var(--fs-12)' }}>{filtered.length}</span>
          </div>

          <div className="corpus-list">
            {filtered.map((p) => {
              const observing = p.ingestState === 'observing'
              const isOpen = openId === p.id
              return (
                <div
                  key={p.id}
                  className="src-row"
                  data-observing={observing}
                  onClick={() => !observing && setOpenId(isOpen ? null : p.id)}
                >
                  <span className="src-mark">
                    {observing ? <Icon name="LoaderCircle" size={14} className="spin" /> : <Icon name="FileText" size={14} />}
                  </span>
                  <div className="grow" style={{ minWidth: 0 }}>
                    <div className="src-title">{p.title}</div>
                    <div className="src-meta">
                      {observing ? (
                        <span className="observing-tag">observing…</span>
                      ) : (
                        <>
                          {p.authors.length > 0 && <span>{authorList(p.authors)}</span>}
                          {p.date && <span>·</span>}
                          {p.date && <span>{shortDate(p.date)}</span>}
                          {p.venue && (<><span>·</span><span>{p.venue}</span></>)}
                          {p.citedBy != null && (<><span>·</span><span>{compactNumber(p.citedBy)} cited</span></>)}
                        </>
                      )}
                    </div>
                    {isOpen && p.abstract && <p className="src-abstract serif">{p.abstract}</p>}
                    {isOpen && (
                      <div className="src-tags">
                        {p.topics.map((t) => (<span key={t} className="tag-quiet">{t}</span>))}
                        {p.url && (
                          <a className="tag-quiet" href={p.url} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>
                            <Icon name="ExternalLink" size={11} /> open
                          </a>
                        )}
                      </div>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </>
      )}
    </div>
  )
}
