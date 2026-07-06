import { useMemo } from 'react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { RiskMeter } from '../components/RiskMeter'
import { ProvenanceChip } from '../components/Provenance'

const STATUS_CLASS: Record<string, string> = {
  draft: 'status-proposed',
  approved: 'status-selected',
  running: 'status-selected',
  done: 'status-done',
}

/**
 * The experiment-plan view. Everything the agent proposes to run lives here —
 * the design matrix, baselines, ablations, metrics and reviewer risks — but the
 * load-bearing element is the COMPUTE-APPROVAL GATE at the bottom: a human must
 * sign off on the estimated spend before any run is queued.
 */
export function ExperimentsView() {
  const exp = useKaisola((s) => s.project.experiments[0])
  const approveCompute = useKaisola((s) => s.approveCompute)
  const runExperiment = useKaisola((s) => s.runExperiment)
  const sandboxMode = useKaisola((s) => s.sandboxMode)
  const autonomy = useKaisola((s) => s.autonomy)

  const cellCount = useMemo(
    () => (exp ? exp.variables.reduce((acc, v) => acc * Math.max(1, v.levels.length), 1) : 0),
    [exp],
  )

  if (!exp) {
    return (
      <div className="view">
        <ViewHeader icon="ListChecks" title="Experiment Plan" sub="No experiment yet" />
        <div className="view-pad">
          <div className="empty">
            <Icon name="ListChecks" /> No experiment has been planned. Select a hypothesis to draft one.
          </div>
        </div>
      </div>
    )
  }

  const approved = exp.computeApproved === true
  const statusCls = STATUS_CLASS[exp.status] ?? 'status-proposed'

  return (
    <div className="view">
      <ViewHeader icon="ListChecks" title="Experiment Plan" sub={exp.title}>
        <span className={`status-chip ${statusCls}`}>{exp.status}</span>
        <button
          className="btn btn-primary btn-sm"
          disabled={!approved || exp.status === 'running'}
          onClick={() => runExperiment(exp.id)}
          title={approved ? `Run in the ${sandboxMode} sandbox` : 'Compute must be approved first'}
        >
          <Icon name={exp.status === 'running' ? 'LoaderCircle' : 'Play'} size={13} className={exp.status === 'running' ? 'spin' : undefined} />
          {exp.status === 'running' ? 'Running…' : `Run in ${sandboxMode}`}
        </button>
      </ViewHeader>

      <div className="view-pad">
        <div style={{ maxWidth: 820, margin: '0 auto' }}>
          {/* Spec */}
          <section className="exp-section">
            <div className="row gap-3" style={{ marginBottom: 'var(--sp-3)' }}>
              <h4 className="grow" style={{ marginBottom: 0 }}>Spec</h4>
              <ProvenanceChip links={exp.provenance} title={`Evidence · ${exp.title}`} />
            </div>
            <p className="muted serif" style={{ lineHeight: 1.55 }}>{exp.spec}</p>
          </section>

          {/* Design matrix */}
          <section className="exp-section">
            <h4>Design matrix</h4>
            <div className="matrix">
              {exp.variables.map((v) => (
                <div key={v.name} className="matrix-factor">
                  <div className="head">{v.name}</div>
                  {v.levels.map((lv) => (
                    <div key={lv} className="level">{lv}</div>
                  ))}
                </div>
              ))}
            </div>
            <div className="faint" style={{ marginTop: 'var(--sp-3)', fontSize: 'var(--fs-12)' }}>
              {exp.variables.map((v) => v.levels.length).join(' × ')} = <b className="mono">{cellCount}</b> cells
              {exp.metrics.length > 0 && <> across {exp.metrics.length} metric{exp.metrics.length > 1 ? 's' : ''}</>}
            </div>
          </section>

          {/* Baselines & Ablations */}
          <div className="row gap-6 wrap" style={{ alignItems: 'flex-start' }}>
            <section className="exp-section grow" style={{ minWidth: 240 }}>
              <h4>Baselines</h4>
              <div className="chk-list">
                {exp.baselines.map((b) => (
                  <div key={b} className="chk"><Icon name="Check" size={14} /> {b}</div>
                ))}
              </div>
            </section>
            <section className="exp-section grow" style={{ minWidth: 240 }}>
              <h4>Ablations</h4>
              <div className="chk-list">
                {exp.ablations.map((a) => (
                  <div key={a} className="chk"><Icon name="Check" size={14} /> {a}</div>
                ))}
              </div>
            </section>
          </div>

          {/* Metrics */}
          <section className="exp-section">
            <h4>Metrics</h4>
            <table className="result-table">
              <thead>
                <tr>
                  <th>Metric</th>
                  <th>Goal</th>
                  <th>Unit</th>
                  <th>Description</th>
                </tr>
              </thead>
              <tbody>
                {exp.metrics.map((m) => (
                  <tr key={m.name}>
                    <td><span className="mono">{m.name}</span></td>
                    <td>
                      <span className="val" title={m.direction}>
                        {m.direction === 'maximize' ? '↑' : '↓'} {m.direction}
                      </span>
                    </td>
                    <td className="muted">{m.unit ?? '—'}</td>
                    <td className="muted">{m.description ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>

          {/* Success criteria */}
          <section className="exp-section">
            <h4>Success criteria</h4>
            <div className="chk-list">
              {exp.successCriteria.map((c) => (
                <div key={c} className="chk"><Icon name="Target" size={14} /> {c}</div>
              ))}
            </div>
          </section>

          {/* Reviewer risk checklist */}
          <section className="exp-section">
            <h4>Reviewer risk checklist</h4>
            <div className="col">
              {exp.reviewerRisks.map((r) => (
                <div key={r.concern} className="reviewer-risk" style={{ flexWrap: 'wrap' }}>
                  <div className="grow" style={{ minWidth: 220 }}>
                    <div className="row gap-3">
                      <Icon name="AlertTriangle" size={13} className="muted" />
                      <span className="grow">{r.concern}</span>
                    </div>
                    {r.mitigation && (
                      <div className="muted" style={{ fontSize: 'var(--fs-11)', marginTop: 'var(--sp-2)', paddingLeft: 'var(--sp-6)' }}>
                        <Icon name="ShieldCheck" size={11} className="muted" /> {r.mitigation}
                      </div>
                    )}
                  </div>
                  <RiskMeter value={r.severity} tone="risk" label="severity" />
                </div>
              ))}
            </div>
          </section>

          {/* Compute-approval gate */}
          <section className="exp-section">
            <h4>Compute approval</h4>
            <div
              className="card card-pad"
              style={{ boxShadow: '0 0 0 1px var(--accent-line)', marginTop: 'var(--sp-2)' }}
            >
              <div className="row gap-4 wrap" style={{ alignItems: 'flex-end' }}>
                <div className="grow" style={{ minWidth: 220 }}>
                  <div className="caps faint" style={{ marginBottom: 'var(--sp-2)' }}>Estimated spend</div>
                  <div className="mono" style={{ fontSize: 'var(--fs-22)', fontWeight: 'var(--fw-semibold)', color: 'var(--text-0)' }}>
                    {exp.computeEstimate}
                  </div>
                  <div className="faint" style={{ fontSize: 'var(--fs-12)', marginTop: 'var(--sp-3)' }}>
                    <Icon name="ShieldAlert" size={12} className="muted" /> Human sign-off required before any run is queued.
                  </div>
                </div>

                {approved ? (
                  <div style={{ textAlign: 'right' }}>
                    <div
                      className="row gap-3"
                      style={{ color: 'var(--success)', fontSize: 'var(--fs-13)', fontWeight: 'var(--fw-semibold)', justifyContent: 'flex-end' }}
                    >
                      <Icon name="CheckCircle2" size={16} /> Approved
                    </div>
                    {autonomy !== 'execute' && autonomy !== 'sprint' && (
                      <div className="faint" style={{ fontSize: 'var(--fs-11)', marginTop: 'var(--sp-2)' }}>
                        Set autonomy to Execute or Sprint to run.
                      </div>
                    )}
                  </div>
                ) : (
                  <div className="row gap-3">
                    <button className="btn btn-primary btn-sm" onClick={() => approveCompute(exp.id)}>
                      <Icon name="Check" size={13} /> Approve compute
                    </button>
                  </div>
                )}
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
  )
}