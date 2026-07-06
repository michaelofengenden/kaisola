import { useMemo } from 'react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { ProvenanceChip } from '../components/Provenance'
import { EmptyState } from '../components/EmptyState'

/**
 * The analysis stage — interpret results and ask the only question that
 * matters before writing a paper: is this real, or noise? The figure makes
 * the headline effect legible; the table forces every number to disclose its
 * seeds, confidence interval, signal call, and evidence.
 */
export function AnalysisView() {
  const results = useKaisola((s) => s.project.results)
  const figures = useKaisola((s) => s.project.figures)

  const figure = figures[0]

  const timerBars = useMemo(
    () =>
      results.filter(
        (r) =>
          r.metric === 'success_rate' &&
          (r.conditions.timer === 'on' || r.conditions.timer === 'off'),
      ),
    [results],
  )

  const realCount = results.filter((r) => r.signal === 'real').length
  const noiseCount = results.filter((r) => r.signal === 'likely-noise').length
  const suspect = results.filter((r) => r.signal === 'likely-noise')

  if (results.length === 0) {
    return (
      <div className="view">
        <ViewHeader icon="BarChart3" title="Analysis" sub="Results, figures — real or noise?" />
        <EmptyState
          icon="BarChart3"
          title="No results yet"
          hint="Results appear here once a run completes. The analysis agent then flags what's real vs. noise."
        />
      </div>
    )
  }

  return (
    <div className="view">
      <ViewHeader
        icon="BarChart3"
        title="Analysis"
        sub="Results, figures, and whether they're real or noise"
      >
        <button className="btn btn-sm">
          <Icon name="RefreshCw" size={13} /> Re-run noise check
        </button>
      </ViewHeader>

      <div className="view-pad">
        <div
          className="col gap-6"
          style={{ maxWidth: 900, margin: '0 auto', width: '100%' }}
        >
          <div className="metabar">
            <span className="stat">
              <Icon name="CircleCheck" size={13} className="muted" />
              <b>{realCount}</b> real
            </span>
            <span className="stat">
              <Icon name="TriangleAlert" size={13} className="muted" />
              <b>{noiseCount}</b> likely noise
            </span>
            <span className="stat">
              <Icon name="Database" size={13} className="muted" />
              <b>{results.length}</b> results total
            </span>
          </div>

          {figure && timerBars.length > 0 && (
            <div className="card figure-card">
              <div className="row gap-4" style={{ marginBottom: 'var(--sp-2)' }}>
                <Icon name="BarChart3" size={14} className="muted" />
                <span className="section-title grow">{figure.title}</span>
                <ProvenanceChip links={figure.provenance} title={figure.title} />
              </div>

              <div className="bar-chart">
                {timerBars.map((r) => {
                  const on = r.conditions.timer === 'on'
                  return (
                    <div key={r.id} className="bar-col">
                      <div
                        className={on ? 'bar' : 'bar muted-bar'}
                        style={{ height: `${r.value}%` }}
                      >
                        <span className="bar-val">
                          {r.value}
                          {r.unit}
                        </span>
                      </div>
                      <span className="bar-label">{on ? 'Timer on' : 'Timer off'}</span>
                    </div>
                  )
                })}
              </div>

              {figure.caption && (
                <div
                  className="faint serif"
                  style={{
                    marginTop: 'var(--sp-5)',
                    fontSize: 'var(--fs-12)',
                    textAlign: 'center',
                  }}
                >
                  {figure.caption}
                </div>
              )}
            </div>
          )}

          <div className="col gap-3">
            <div className="section-title">All results</div>
            <table className="result-table">
              <thead>
                <tr>
                  <th>Metric</th>
                  <th>Conditions</th>
                  <th>Value</th>
                  <th>Seeds</th>
                  <th>Signal</th>
                  <th>Evidence</th>
                </tr>
              </thead>
              <tbody>
                {results.map((r) => (
                  <tr key={r.id}>
                    <td className="mono" style={{ fontSize: 'var(--fs-12)' }}>
                      {r.metric}
                    </td>
                    <td>
                      <span className="row wrap gap-1">
                        {Object.entries(r.conditions).map(([k, v]) => (
                          <span key={k} className="badge">
                            {k}={v}
                          </span>
                        ))}
                      </span>
                    </td>
                    <td>
                      <span className="val">
                        {r.value}
                        {r.unit}
                      </span>
                      {r.ci && (
                        <span
                          className="muted mono"
                          style={{ marginLeft: 'var(--sp-2)', fontSize: 'var(--fs-11)' }}
                        >
                          [{r.ci[0]}, {r.ci[1]}]
                        </span>
                      )}
                    </td>
                    <td className="mono">{r.seeds ?? '—'}</td>
                    <td>
                      {r.signal ? (
                        <span className={`signal-chip signal-${r.signal}`}>{r.signal}</span>
                      ) : (
                        <span className="faint">—</span>
                      )}
                    </td>
                    <td>
                      <ProvenanceChip links={r.provenance} title={r.metric} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {suspect.length > 0 && (
            <div className="card card-pad col gap-3">
              <div className="row gap-3">
                <Icon name="TriangleAlert" size={14} style={{ color: 'var(--warn)' }} />
                <span className="section-title grow">What changed vs last run</span>
              </div>
              {suspect.map((r) => (
                <div key={r.id} className="row gap-3 wrap">
                  <span className="mono" style={{ fontSize: 'var(--fs-12)' }}>
                    {r.metric}
                  </span>
                  <span className="muted" style={{ fontSize: 'var(--fs-13)' }}>
                    {r.value}
                    {r.unit} on {r.conditions.model ?? 'this condition'} moved, but with{' '}
                    {r.seeds ?? 1} seed{(r.seeds ?? 1) === 1 ? '' : 's'} the delta sits
                    inside the noise band — rerun before claiming it.
                  </span>
                  <ProvenanceChip links={r.provenance} title={r.metric} />
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
