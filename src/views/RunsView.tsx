import { useState } from 'react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { EmptyState } from '../components/EmptyState'
import { clockTime, shortDate } from '../lib/format'
import type { RunStatus } from '../domain/types'

const STATUS_ICON: Record<RunStatus, string> = {
  done: 'CheckCircle2', partial: 'CircleDashed', failed: 'XCircle',
  running: 'LoaderCircle', queued: 'Clock', setup: 'Settings', cancelled: 'Ban',
}

/**
 * The execution stage. The left column lists runs; the right column is the
 * AUTO LAB NOTEBOOK — the timestamped trace the agent keeps as it works
 * (tried X, failed Y, fixed Z, reran → result). This is what makes a run
 * auditable instead of a black box.
 */
export function RunsView() {
  const runs = useKaisola((s) => s.project.runs)
  const experiments = useKaisola((s) => s.project.experiments)
  const [activeId, setActiveId] = useState(runs[runs.length - 1]?.id ?? null)
  const run = runs.find((r) => r.id === activeId) ?? runs[runs.length - 1]
  const exp = experiments.find((e) => e.id === run?.experimentId)

  if (runs.length === 0) {
    return (
      <div className="view">
        <ViewHeader icon="Terminal" title="Runs" sub="Execution & the auto lab notebook" />
        <EmptyState
          icon="Terminal"
          title="No runs yet"
          hint="Approve an experiment's compute, then queue a run. The agent keeps a live lab notebook here."
        />
      </div>
    )
  }

  return (
    <div className="view">
      <ViewHeader icon="Terminal" title="Runs" sub={exp ? exp.title : 'Execution & the auto lab notebook'}>
        <button className="btn btn-sm"><Icon name="GitBranch" size={13} /> Compare</button>
        <button className="btn btn-primary btn-sm"><Icon name="Play" size={13} /> New run</button>
      </ViewHeader>

      <div className="runs">
        <div className="runs-list">
          {runs.map((r) => (
            <div key={r.id} className="run-item" data-active={r.id === run?.id} onClick={() => setActiveId(r.id)}>
              <div className="row gap-3">
                <span className={`run-status rs-${r.status}`}>
                  <Icon name={STATUS_ICON[r.status]} size={12} /> {r.status}
                </span>
                <span className="grow" />
                {r.seed != null && <span className="faint mono" style={{ fontSize: 'var(--fs-10)' }}>seed {r.seed}</span>}
              </div>
              <div className="run-label" style={{ marginTop: 'var(--sp-2)' }}>{r.label}</div>
              {r.summary && <div className="run-sum">{r.summary}</div>}
              <div className="row gap-3" style={{ marginTop: 'var(--sp-3)' }}>
                <span className="faint" style={{ fontSize: 'var(--fs-10)' }}>
                  <Icon name="ListTree" size={11} /> {r.notebook.length} entries
                </span>
                <span className="faint" style={{ fontSize: 'var(--fs-10)' }}>
                  <Icon name="Paperclip" size={11} /> {r.artifacts.length} artifacts
                </span>
              </div>
            </div>
          ))}
        </div>

        <div className="notebook-pane">
          {run ? (
            <>
              <div className="row gap-4" style={{ marginBottom: 'var(--sp-6)' }}>
                <h3 className="grow">{run.label}</h3>
                {run.startedAt && <span className="faint" style={{ fontSize: 'var(--fs-12)' }}>{shortDate(run.startedAt)}</span>}
              </div>

              {run.env && (
                <div className="metabar" style={{ marginBottom: 'var(--sp-6)' }}>
                  {Object.entries(run.env).map(([k, v]) => (
                    <span key={k} className="stat"><span className="caps" style={{ fontSize: 'var(--fs-10)' }}>{k}</span> <b className="mono">{v}</b></span>
                  ))}
                </div>
              )}

              <div className="caps" style={{ marginBottom: 'var(--sp-4)' }}>Lab notebook</div>
              <div className="notebook">
                {run.notebook.map((e) => (
                  <div key={e.id} className={`nb-entry nb-level-${e.level}`}>
                    <span className="nb-time">{clockTime(e.at)}</span>
                    <span className="nb-rail"><span className="nb-dot" /></span>
                    <div className="grow">
                      <div className="nb-text">{e.text}</div>
                      {e.artifactId && (
                        <span className="nb-artifact">
                          <Icon name="Image" size={11} /> {run.artifacts.find((a) => a.id === e.artifactId)?.name ?? e.artifactId}
                        </span>
                      )}
                    </div>
                  </div>
                ))}
              </div>

              {run.artifacts.length > 0 && (
                <>
                  <div className="caps" style={{ margin: 'var(--sp-7) 0 var(--sp-4)' }}>Artifacts</div>
                  <div className="col gap-2">
                    {run.artifacts.map((a) => (
                      <div key={a.id} className="row gap-4 card" style={{ padding: 'var(--sp-3) var(--sp-4)' }}>
                        <Icon name={a.type === 'figure' ? 'Image' : a.type === 'log' ? 'ScrollText' : 'File'} size={14} className="muted" />
                        <span className="mono grow" style={{ fontSize: 'var(--fs-12)' }}>{a.name}</span>
                        {a.producedBy?.scriptPath && (
                          <span className="faint mono" style={{ fontSize: 'var(--fs-10)' }} title="figure → code link">
                            ← {a.producedBy.scriptPath}
                          </span>
                        )}
                        <span className="badge">{a.type}</span>
                      </div>
                    ))}
                  </div>
                </>
              )}
            </>
          ) : (
            <div className="empty"><Icon name="Terminal" /> No runs yet.</div>
          )}
        </div>
      </div>
    </div>
  )
}
