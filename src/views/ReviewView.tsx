import { useMemo } from 'react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { RiskMeter } from '../components/RiskMeter'
import { ProvenanceChip } from '../components/Provenance'
import { EmptyState } from '../components/EmptyState'
import type { Review, ReviewerComment } from '../domain/types'

/** 'reviewer-1' → 'Reviewer 1', 'area-chair' → 'Area Chair'. */
function humanizePersona(persona: Review['persona']): string {
  if (persona === 'area-chair') return 'Area Chair'
  const n = persona.split('-')[1]
  return `Reviewer ${n}`
}

/** Short avatar initials: reviewer-1 → R1, area-chair → AC. */
function personaInitials(persona: Review['persona']): string {
  if (persona === 'area-chair') return 'AC'
  return `R${persona.split('-')[1]}`
}

/** 'weak-accept' → 'weak accept'. */
function humanizeRecommendation(rec: Review['recommendation']): string {
  return rec.replace(/-/g, ' ')
}

const COMMENT_ICON: Record<ReviewerComment['kind'], string> = {
  strength: 'ThumbsUp',
  weakness: 'AlertTriangle',
  question: 'HelpCircle',
}

/**
 * The simulated-review stage. A panel of reviewer personas critiques the work —
 * but unlike a black-box LLM rubric, every critique is tied to its evidence via
 * a provenance chip, so a "this is noise" weakness is one click from the run
 * that produced the suspect number.
 */
export function ReviewView() {
  const reviews = useKaisola((s) => s.project.reviews)

  const summary = useMemo(() => {
    const scores = reviews.map((r) => r.score).filter((s): s is number => s != null)
    const mean = scores.length ? scores.reduce((a, b) => a + b, 0) / scores.length : null
    const lo = scores.length ? Math.min(...scores) : null
    const hi = scores.length ? Math.max(...scores) : null
    let strengths = 0
    let weaknesses = 0
    let questions = 0
    for (const r of reviews) {
      for (const c of r.comments) {
        if (c.kind === 'strength') strengths++
        else if (c.kind === 'weakness') weaknesses++
        else questions++
      }
    }
    return { mean, lo, hi, count: scores.length, strengths, weaknesses, questions }
  }, [reviews])

  if (reviews.length === 0) {
    return (
      <div className="view">
        <ViewHeader icon="Gavel" title="Review" sub="Simulated peer review" />
        <EmptyState
          icon="Gavel"
          title="No reviews yet"
          hint="Once there's a draft, the reviewer panel critiques it — every weakness tied to its evidence."
        />
      </div>
    )
  }

  return (
    <div className="view">
      <ViewHeader
        icon="Gavel"
        title="Review"
        sub="Simulated peer review — every critique tied to its evidence"
      >
        <button className="btn btn-primary btn-sm">
          <Icon name="RefreshCw" size={13} /> Re-run review panel
        </button>
      </ViewHeader>

      <div className="view-pad">
        <div className="col gap-6" style={{ maxWidth: 880, margin: '0 auto' }}>
          {reviews.length === 0 ? (
            <div className="empty">
              <Icon name="Gavel" /> No reviews yet — run the review panel.
            </div>
          ) : (
            <>
              <div className="card card-pad">
                <div className="row gap-6 wrap">
                  <div className="col" style={{ gap: 'var(--sp-1)' }}>
                    <span className="caps faint">Mean score</span>
                    <div className="row gap-2" style={{ alignItems: 'baseline' }}>
                      <span className="review-score" style={{ fontSize: 'var(--fs-32, 2rem)' }}>
                        {summary.mean != null ? summary.mean.toFixed(1) : '—'}
                      </span>
                      <span className="muted">/10</span>
                    </div>
                    {summary.lo != null && summary.hi != null && (
                      <span className="faint mono" style={{ fontSize: 'var(--fs-11)' }}>
                        spread {summary.lo}–{summary.hi} · {summary.count} score
                        {summary.count === 1 ? '' : 's'}
                      </span>
                    )}
                  </div>

                  <span className="grow" />

                  <div className="col" style={{ gap: 'var(--sp-2)', alignItems: 'flex-end' }}>
                    <span className="caps faint">Recommendations</span>
                    <div className="row gap-2 wrap" style={{ justifyContent: 'flex-end' }}>
                      {reviews.map((r) => (
                        <span
                          key={r.id}
                          className={`rec-chip rec-${r.recommendation}`}
                          title={humanizePersona(r.persona)}
                        >
                          {personaInitials(r.persona)} · {humanizeRecommendation(r.recommendation)}
                        </span>
                      ))}
                    </div>
                  </div>
                </div>

                <div className="metabar" style={{ marginTop: 'var(--sp-5)' }}>
                  <span className="stat">
                    <Icon name="ThumbsUp" size={12} className="muted" /> strengths{' '}
                    <b>{summary.strengths}</b>
                  </span>
                  <span className="stat">
                    <Icon name="AlertTriangle" size={12} className="muted" /> weaknesses{' '}
                    <b>{summary.weaknesses}</b>
                  </span>
                  <span className="stat">
                    <Icon name="HelpCircle" size={12} className="muted" /> questions{' '}
                    <b>{summary.questions}</b>
                  </span>
                </div>
              </div>

              {reviews.map((review) => (
                <article key={review.id} className="card review-card">
                  <div className="review-head">
                    <span className="persona-avatar">{personaInitials(review.persona)}</span>
                    <span className="grow" style={{ fontWeight: 'var(--fw-bold)' }}>
                      {humanizePersona(review.persona)}
                    </span>
                    {review.score != null && (
                      <span className="row gap-1" style={{ alignItems: 'baseline' }}>
                        <span className="review-score">{review.score}</span>
                        <span className="muted">/10</span>
                      </span>
                    )}
                    <span className={`rec-chip rec-${review.recommendation}`}>
                      {humanizeRecommendation(review.recommendation)}
                    </span>
                  </div>

                  <p className="muted serif" style={{ margin: 0 }}>
                    {review.summary}
                  </p>

                  <div className="col">
                    {review.comments.map((c) => (
                      <div key={c.id} className="review-comment">
                        <span className={`comment-kind ck-${c.kind}`} title={c.kind}>
                          <Icon name={COMMENT_ICON[c.kind]} size={11} />
                        </span>
                        <div className="grow" style={{ minWidth: 0 }}>
                          <div className="comment-text">{c.text}</div>
                          <div
                            className="row gap-3 wrap"
                            style={{ marginTop: 'var(--sp-2)', alignItems: 'center' }}
                          >
                            {c.severity != null && (
                              <RiskMeter value={c.severity} label="severity" tone="risk" />
                            )}
                            {c.evidence.length > 0 && (
                              <ProvenanceChip links={c.evidence} title={`${humanizePersona(review.persona)} · ${c.kind}`} />
                            )}
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                </article>
              ))}
            </>
          )}
        </div>
      </div>
    </div>
  )
}
