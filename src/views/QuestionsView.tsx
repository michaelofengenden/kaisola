import { useMemo } from 'react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { ProvenanceChip } from '../components/Provenance'
import { EmptyState } from '../components/EmptyState'
import type { ResearchQuestion } from '../domain/types'

const STATUS_LABEL: Record<ResearchQuestion['status'], string> = {
  open: 'Open',
  'in-progress': 'In progress',
  answered: 'Answered',
  parked: 'Parked',
}

/**
 * The questions stage. Open research questions the field map surfaces, each
 * tied to the hypotheses that aim to answer it and one click from its evidence.
 */
export function QuestionsView() {
  const questions = useKaisola((s) => s.project.questions)
  const setStage = useKaisola((s) => s.setStage)

  const counts = useMemo(() => {
    return {
      open: questions.filter((q) => q.status === 'open').length,
      'in-progress': questions.filter((q) => q.status === 'in-progress').length,
      answered: questions.filter((q) => q.status === 'answered').length,
    }
  }, [questions])

  if (questions.length === 0) {
    return (
      <div className="view">
        <ViewHeader icon="HelpCircle" title="Questions" sub="Open research questions" />
        <EmptyState
          icon="HelpCircle"
          title="No questions yet"
          hint="Questions surface from the claim graph as you build it — or post one yourself."
        />
      </div>
    )
  }

  return (
    <div className="view">
      <ViewHeader
        icon="HelpCircle"
        title="Questions"
        sub="Open research questions the field map surfaces"
      >
        <button className="btn btn-primary btn-sm">
          <Icon name="Plus" size={13} /> New question
        </button>
      </ViewHeader>

      <div className="view-pad">
        <div className="metabar" style={{ marginBottom: 'var(--sp-6)' }}>
          <span className="stat">
            <span className="q-status open" />
            <b>{counts.open}</b> open
          </span>
          <span className="stat">
            <span className="q-status in-progress" />
            <b>{counts['in-progress']}</b> in progress
          </span>
          <span className="stat">
            <span className="q-status answered" />
            <b>{counts.answered}</b> answered
          </span>
        </div>

        {questions.length === 0 ? (
          <div className="empty">
            <Icon name="HelpCircle" /> No questions yet.
          </div>
        ) : (
          <div className="cards">
            {questions.map((q) => {
              const n = q.hypothesisIds.length
              return (
                <div key={q.id} className="card q-row">
                  <span className={`q-status ${q.status}`} />
                  <div className="grow" style={{ minWidth: 0 }}>
                    <div className="q-label">{q.label}</div>
                    {q.detail && <div className="q-detail">{q.detail}</div>}
                    <div className="row gap-4 wrap" style={{ marginTop: 'var(--sp-4)' }}>
                      <span className="badge">{STATUS_LABEL[q.status]}</span>
                      <button
                        className="btn btn-ghost btn-sm"
                        onClick={() => setStage('ideas')}
                        title="Open hypotheses"
                      >
                        <Icon name="Lightbulb" size={12} /> {n} hypothes{n === 1 ? 'is' : 'es'}
                      </button>
                      <span className="grow" />
                      <ProvenanceChip links={q.provenance} title={q.label} />
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}
