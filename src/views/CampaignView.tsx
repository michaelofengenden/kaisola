import { useMemo } from 'react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { shortDate } from '../lib/format'
import type { CampaignStatus, ExperimentAttempt } from '../domain/types'

const CAMPAIGN_STATUS: CampaignStatus[] = ['draft', 'active', 'paused', 'complete']

const ATTEMPT_ICON: Record<ExperimentAttempt['status'], string> = {
  queued: 'Clock',
  running: 'LoaderCircle',
  failed: 'XCircle',
  ready: 'CircleDot',
  accepted: 'CheckCircle2',
  rejected: 'Ban',
}

const lines = (value: string) => value.split('\n').map((x) => x.trim()).filter(Boolean)

function Field({
  label,
  value,
  onChange,
  placeholder,
}: {
  label: string
  value: string
  onChange: (value: string) => void
  placeholder?: string
}) {
  return (
    <label className="campaign-field">
      <span>{label}</span>
      <input value={value} placeholder={placeholder} onChange={(e) => onChange(e.target.value)} />
    </label>
  )
}

function ListField({
  label,
  value,
  onChange,
}: {
  label: string
  value: string[]
  onChange: (value: string[]) => void
}) {
  return (
    <label className="campaign-field">
      <span>{label}</span>
      <textarea value={value.join('\n')} rows={4} onChange={(e) => onChange(lines(e.target.value))} />
    </label>
  )
}

export function CampaignView() {
  const campaign = useKaisola((s) => s.project.campaign)
  const attempts = useKaisola((s) => s.project.attempts)
  const experiments = useKaisola((s) => s.project.experiments)
  const runs = useKaisola((s) => s.project.runs)
  const corpus = useKaisola((s) => s.project.corpus)
  const results = useKaisola((s) => s.project.results)
  const proposals = useKaisola((s) => s.project.proposals)
  const agentTasks = useKaisola((s) => s.agentTasks)
  const updateCampaign = useKaisola((s) => s.updateCampaign)
  const promoteAttempt = useKaisola((s) => s.promoteAttempt)
  const rejectAttempt = useKaisola((s) => s.rejectAttempt)
  const setStage = useKaisola((s) => s.setStage)

  const campaignAttempts = useMemo(
    () => (campaign ? attempts.filter((a) => a.campaignId === campaign.id) : []),
    [attempts, campaign],
  )
  const champion = campaign?.championAttemptId ? attempts.find((a) => a.id === campaign.championAttemptId) : undefined
  const pendingAttempts = campaignAttempts.filter((a) => a.status === 'ready')
  const pendingProposals = proposals.filter((p) => p.status === 'pending')
  const artifactCount = runs.reduce((total, run) => total + run.artifacts.length, 0)
  const latestTasks = agentTasks.slice(0, 5)

  if (!campaign) {
    return (
      <div className="view">
        <ViewHeader icon="Target" title="Research Campaign" sub="Objective, evaluator, budget & attempts" />
        <div className="view-pad">
          <div className="empty campaign-empty">
            <Icon name="Target" />
            <div>
              <h3>No campaign contract yet</h3>
              <p className="muted">Create a bounded program-style contract before asking agents to iterate.</p>
              <button className="btn btn-primary btn-sm" onClick={() => updateCampaign({ status: 'draft' })}>
                <Icon name="Plus" size={13} /> Create campaign
              </button>
            </div>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="view">
      <ViewHeader icon="Target" title="Research Campaign" sub={campaign.title}>
        <span className={`status-chip status-${campaign.status}`}>{campaign.status}</span>
        <button className="btn btn-sm" onClick={() => setStage('experiments')}>
          <Icon name="ListChecks" size={13} /> Experiment plan
        </button>
        <button className="btn btn-primary btn-sm" onClick={() => setStage('runs')}>
          <Icon name="Terminal" size={13} /> Runs
        </button>
      </ViewHeader>

      <div className="view-pad">
        <div className="campaign-grid">
          <section className="card card-pad campaign-contract">
            <div className="section-title">
              <Icon name="FileText" size={14} />
              <span>program.md contract</span>
            </div>

            <Field label="Title" value={campaign.title} onChange={(title) => updateCampaign({ title })} />

            <label className="campaign-field">
              <span>Objective</span>
              <textarea
                value={campaign.objective}
                rows={4}
                onChange={(e) => updateCampaign({ objective: e.target.value })}
              />
            </label>

            <div className="campaign-form-grid">
              <Field
                label="Evaluator metric"
                value={campaign.evaluator.metric}
                onChange={(metric) => updateCampaign({ evaluator: { ...campaign.evaluator, metric } })}
              />
              <label className="campaign-field">
                <span>Direction</span>
                <select
                  value={campaign.evaluator.direction}
                  onChange={(e) => updateCampaign({ evaluator: { ...campaign.evaluator, direction: e.target.value as 'maximize' | 'minimize' } })}
                >
                  <option value="maximize">maximize</option>
                  <option value="minimize">minimize</option>
                </select>
              </label>
              <Field
                label="Target"
                value={campaign.evaluator.target == null ? '' : String(campaign.evaluator.target)}
                placeholder="optional"
                onChange={(value) => updateCampaign({ evaluator: { ...campaign.evaluator, target: value === '' ? undefined : Number(value) } })}
              />
              <Field
                label="Unit"
                value={campaign.evaluator.unit ?? ''}
                placeholder="%"
                onChange={(unit) => updateCampaign({ evaluator: { ...campaign.evaluator, unit: unit || undefined } })}
              />
            </div>

            <div className="campaign-form-grid">
              <label className="campaign-field">
                <span>Max attempts</span>
                <input
                  type="number"
                  min={1}
                  value={campaign.budget.maxAttempts}
                  onChange={(e) => updateCampaign({ budget: { ...campaign.budget, maxAttempts: Math.max(1, Number(e.target.value) || 1) } })}
                />
              </label>
              <label className="campaign-field">
                <span>Minutes / attempt</span>
                <input
                  type="number"
                  min={1}
                  value={campaign.budget.maxMinutesPerAttempt}
                  onChange={(e) => updateCampaign({ budget: { ...campaign.budget, maxMinutesPerAttempt: Math.max(1, Number(e.target.value) || 1) } })}
                />
              </label>
              <Field
                label="Compute envelope"
                value={campaign.budget.compute}
                onChange={(compute) => updateCampaign({ budget: { ...campaign.budget, compute } })}
              />
              <label className="campaign-field">
                <span>Status</span>
                <select value={campaign.status} onChange={(e) => updateCampaign({ status: e.target.value as CampaignStatus })}>
                  {CAMPAIGN_STATUS.map((status) => <option key={status} value={status}>{status}</option>)}
                </select>
              </label>
            </div>

            <Field label="Run command" value={campaign.runCommand} onChange={(runCommand) => updateCampaign({ runCommand })} />

            <div className="campaign-form-grid campaign-list-grid">
              <ListField label="Editable paths" value={campaign.editablePaths} onChange={(editablePaths) => updateCampaign({ editablePaths })} />
              <ListField label="Allowed commands" value={campaign.allowedCommands} onChange={(allowedCommands) => updateCampaign({ allowedCommands })} />
              <ListField label="Required evidence" value={campaign.requiredEvidence} onChange={(requiredEvidence) => updateCampaign({ requiredEvidence })} />
              <ListField label="Stop conditions" value={campaign.stopConditions} onChange={(stopConditions) => updateCampaign({ stopConditions })} />
            </div>
          </section>

          <aside className="campaign-side">
            <section className="card card-pad">
              <div className="section-title">
                <Icon name="LayoutDashboard" size={14} />
                <span>Lifecycle</span>
              </div>
              <div className="campaign-stats">
                <div className="campaign-stat">
                  <span>Attempts</span>
                  <b>{campaignAttempts.length}/{campaign.budget.maxAttempts}</b>
                </div>
                <div className="campaign-stat">
                  <span>Champion</span>
                  <b>{champion?.metric ? `${champion.metric.value.toFixed(1)}${champion.metric.unit ?? ''}` : 'none'}</b>
                </div>
                <div className="campaign-stat">
                  <span>Decisions</span>
                  <b>{pendingAttempts.length + pendingProposals.length}</b>
                </div>
                <div className="campaign-stat">
                  <span>Artifacts</span>
                  <b>{artifactCount}</b>
                </div>
              </div>
              <div className="campaign-mini">
                <span className="caps">Evaluator</span>
                <code>{campaign.evaluator.metric}</code>
                <span>{campaign.evaluator.direction === 'maximize' ? 'higher is better' : 'lower is better'}</span>
              </div>
            </section>

            <section className="card card-pad">
              <div className="section-title">
                <Icon name="Database" size={14} />
                <span>Context Ledger</span>
              </div>
              <div className="context-list">
                <div><b>{corpus.length}</b><span>sources in corpus</span></div>
                <div><b>{experiments.length}</b><span>experiment plans</span></div>
                <div><b>{runs.length}</b><span>runs in notebook</span></div>
                <div><b>{results.length}</b><span>result records</span></div>
              </div>
            </section>
          </aside>
        </div>

        <section className="card campaign-attempts">
          <div className="section-title">
            <Icon name="GitBranch" size={14} />
            <span>Attempt Graph</span>
            <span className="grow" />
            <span className="faint">{campaignAttempts.length} immutable attempt{campaignAttempts.length === 1 ? '' : 's'}</span>
          </div>

          {campaignAttempts.length === 0 ? (
            <div className="empty"><Icon name="CircleDot" /> No attempts yet. Approve compute, then run an experiment.</div>
          ) : (
            <div className="attempt-list">
              {[...campaignAttempts].reverse().map((attempt) => {
                const run = runs.find((r) => r.id === attempt.runId)
                return (
                  <article key={attempt.id} className="attempt-row" data-status={attempt.status}>
                    <div className="attempt-rail">
                      <Icon name={ATTEMPT_ICON[attempt.status]} size={15} className={attempt.status === 'running' ? 'spin' : undefined} />
                    </div>
                    <div className="grow">
                      <div className="row gap-3 wrap">
                        <b className="mono">{attempt.id}</b>
                        <span className={`status-chip status-${attempt.status}`}>{attempt.status}</span>
                        {attempt.parentAttemptId && <span className="badge">parent {attempt.parentAttemptId}</span>}
                        <span className="grow" />
                        <span className="faint">{shortDate(attempt.createdAt)}</span>
                      </div>
                      <p className="muted" style={{ margin: 'var(--sp-2) 0' }}>{attempt.hypothesis}</p>
                      <code className="attempt-command">{attempt.command}</code>
                      <div className="row gap-3 wrap" style={{ marginTop: 'var(--sp-3)' }}>
                        {attempt.metric && (
                          <span className="stat">
                            <span className="caps">{attempt.metric.name}</span>
                            <b>{attempt.metric.value.toFixed(1)}{attempt.metric.unit ?? ''}</b>
                          </span>
                        )}
                        {attempt.cost && <span className="stat"><span className="caps">budget</span><b>{attempt.cost}</b></span>}
                        {run && <span className="stat"><span className="caps">run</span><b>{run.status}</b></span>}
                        {attempt.confidence && <span className="badge">{attempt.confidence}</span>}
                      </div>
                    </div>
                    {attempt.status === 'ready' && (
                      <div className="attempt-actions">
                        <button className="btn btn-primary btn-sm" onClick={() => promoteAttempt(attempt.id)}>
                          <Icon name="Check" size={13} /> Promote
                        </button>
                        <button className="btn btn-sm" onClick={() => rejectAttempt(attempt.id)}>
                          <Icon name="X" size={13} /> Reject
                        </button>
                      </div>
                    )}
                  </article>
                )
              })}
            </div>
          )}
        </section>

        {latestTasks.length > 0 && (
          <section className="card campaign-attempts">
            <div className="section-title">
              <Icon name="Workflow" size={14} />
              <span>Agent Lifecycle</span>
            </div>
            <div className="attempt-list compact">
              {latestTasks.map((task) => (
                <div key={task.id} className="task-line">
                  <span className={`status-chip status-${task.status}`}>{task.status}</span>
                  <b>{task.label}</b>
                  <span className="muted">{task.stage}</span>
                  <span className="grow" />
                  {task.resultCount != null && <span className="badge">{task.resultCount} proposal{task.resultCount === 1 ? '' : 's'}</span>}
                </div>
              ))}
            </div>
          </section>
        )}
      </div>
    </div>
  )
}
