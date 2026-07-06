import { useMemo, useState } from 'react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { RiskMeter } from '../components/RiskMeter'
import { ProvenanceChip } from '../components/Provenance'
import { tournament } from '../lib/tournament'
import type { Hypothesis, RelatedWork } from '../domain/types'

const RELATION_LABEL: Record<RelatedWork['relation'], string> = {
  closest: 'closest',
  'same-motivation': 'same motivation',
  contradicts: 'contradicts',
  baseline: 'baseline',
}

const STATUS_ORDER: Record<Hypothesis['status'], number> = {
  selected: 0,
  proposed: 1,
  shipped: 2,
  rejected: 3,
}

/**
 * The Ideas stage — candidate hypotheses rendered as evidence-grounded idea
 * cards. Each card pairs the claim with novelty/feasibility scoring, the MVP
 * that would test it cheaply, its known failure modes, and a one-click link to
 * the evidence that supports it. The selected hypothesis floats to the top and
 * offers a jump into its experiment plan.
 */
export function IdeasView() {
  const hypotheses = useKaisola((s) => s.project.hypotheses)
  const setStage = useKaisola((s) => s.setStage)
  const runAgent = useKaisola((s) => s.runAgent)
  const agentRunning = useKaisola((s) => s.agentRunning)
  // tournament ranking (id → {rank, elo}). Empty until the user runs "Rank ideas".
  const [ranking, setRanking] = useState<Record<string, { rank: number; elo: number }>>({})
  const ranked = Object.keys(ranking).length > 0

  const rankIdeas = async () => {
    const result = await tournament(hypotheses)
    setRanking(Object.fromEntries(result.map((r) => [r.hyp.id, { rank: r.rank, elo: r.elo }])))
  }

  const sorted = useMemo(
    () =>
      [...hypotheses].sort((a, b) =>
        ranked
          ? (ranking[a.id]?.rank ?? 99) - (ranking[b.id]?.rank ?? 99)
          : STATUS_ORDER[a.status] - STATUS_ORDER[b.status],
      ),
    [hypotheses, ranked, ranking],
  )

  // standings leaderboard (by rank, with Elo-relative bar widths) for the panel
  const standings = useMemo(() => {
    if (!ranked) return [] as { id: string; title: string; rank: number; elo: number; pct: number }[]
    const rows = hypotheses
      .map((h) => ({ id: h.id, title: h.title, rank: ranking[h.id]?.rank ?? 99, elo: ranking[h.id]?.elo ?? 1000 }))
      .sort((a, b) => a.rank - b.rank)
    const elos = rows.map((r) => r.elo)
    const min = Math.min(...elos)
    const span = Math.max(...elos) - min || 1
    return rows.map((r) => ({ ...r, pct: Math.round(30 + 70 * ((r.elo - min) / span)) }))
  }, [hypotheses, ranked, ranking])

  return (
    <div className="view">
      <ViewHeader
        icon="Lightbulb"
        title="Ideas"
        sub="Candidate hypotheses — each grounded in evidence, scored for novelty & feasibility"
      >
        {hypotheses.length > 1 && (
          <button className="btn btn-sm" onClick={rankIdeas} title="Rank ideas by a pairwise tournament">
            <Icon name="Trophy" size={13} /> {ranked ? 'Re-rank' : 'Rank ideas'}
          </button>
        )}
        <button className="btn btn-sm" disabled={!!agentRunning.novelty} onClick={() => runAgent('novelty')}>
          <Icon name={agentRunning.novelty ? 'LoaderCircle' : 'Sparkles'} size={13} className={agentRunning.novelty ? 'spin' : undefined} /> Run novelty check
        </button>
        <button className="btn btn-primary btn-sm" disabled={!!agentRunning.hypothesis} onClick={() => runAgent('hypothesis')}>
          <Icon name={agentRunning.hypothesis ? 'LoaderCircle' : 'Plus'} size={13} className={agentRunning.hypothesis ? 'spin' : undefined} /> New hypothesis
        </button>
      </ViewHeader>

      <div className="view-pad">
        {ranked && standings.length > 1 && (
          <div className="card tournament">
            <div className="tourney-head">
              <Icon name="Trophy" size={13} />
              <span className="caps">Tournament standings</span>
              <span className="grow" />
              <span className="faint" style={{ fontSize: 'var(--fs-11)' }}>pairwise Elo · {standings.length} ideas</span>
            </div>
            <ol className="tourney-list">
              {standings.map((s) => (
                <li key={s.id} className="tourney-row" title={`Elo ${s.elo}`}>
                  <span className="tourney-rank">#{s.rank}</span>
                  <span className="tourney-name grow truncate">{s.title}</span>
                  <span className="tourney-bar"><span className="tourney-fill" style={{ width: `${s.pct}%` }} /></span>
                  <span className="tourney-elo">{s.elo}</span>
                </li>
              ))}
            </ol>
          </div>
        )}
        {sorted.length === 0 ? (
          <div className="empty">
            <Icon name="Lightbulb" /> No hypotheses yet.
          </div>
        ) : (
          <div className="cards">
            {sorted.map((h) => (
              <article key={h.id} className="card idea-card">
                <div className="idea-top">
                  {ranked && ranking[h.id] != null && (
                    <span className="rank-chip" title={`Tournament rank · Elo ${ranking[h.id].elo}`}>#{ranking[h.id].rank}</span>
                  )}
                  <h3 className="idea-title grow">{h.title}</h3>
                  <span className={`status-chip status-${h.status}`}>{h.status}</span>
                </div>

                <div className="idea-claim">{h.claim}</div>
                <div className="idea-why muted">{h.why}</div>

                <div className="idea-grid">
                  <div className="idea-fact">
                    <span className="k">Novelty risk</span>
                    <span className="v">
                      <RiskMeter value={h.noveltyRisk} tone="risk" />
                    </span>
                  </div>
                  <div className="idea-fact">
                    <span className="k">Feasibility</span>
                    <span className="v">
                      <RiskMeter value={h.feasibility} tone="neutral" />
                    </span>
                  </div>
                  <div className="idea-fact">
                    <span className="k">Compute</span>
                    <span className="v">{h.computeEstimate}</span>
                  </div>
                  <div className="idea-fact">
                    <span className="k">Data</span>
                    <span className="v">{h.dataNeeds}</span>
                  </div>
                  <div className="idea-fact">
                    <span className="k">MVP</span>
                    <span className="v">{h.mvp}</span>
                  </div>
                </div>

                {h.failureModes.length > 0 && (
                  <div className="idea-failures">
                    {h.failureModes.map((f, i) => (
                      <div key={i} className="idea-failure">
                        <Icon name="TriangleAlert" size={11} />
                        <span>{f}</span>
                      </div>
                    ))}
                  </div>
                )}

                <div className="hr" />

                <div className="row wrap gap-3">
                  <span className="caps" style={{ fontSize: 'var(--fs-10)' }}>
                    Closest related work
                  </span>
                  {h.closestRelatedWork.map((rw, i) => (
                    <span
                      key={i}
                      className="badge"
                      title={rw.note ?? RELATION_LABEL[rw.relation]}
                    >
                      {RELATION_LABEL[rw.relation]}
                    </span>
                  ))}
                  <span className="grow" />
                  <ProvenanceChip links={h.provenance} title={h.title} />
                  {h.status === 'selected' && (
                    <button
                      className="btn btn-primary btn-sm"
                      onClick={() => setStage('experiments')}
                    >
                      <Icon name="FlaskConical" size={13} /> Open experiment plan
                    </button>
                  )}
                </div>
              </article>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
