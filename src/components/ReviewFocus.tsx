import { useEffect } from 'react'
import { useKaisola } from '../store/store'
import { ProposalCard } from './ProposalCard'
import { Icon } from './Icon'
import type { Proposal } from '../domain/types'

function scoreProposal(p: Proposal) {
  const typedChanges = p.changes.filter((c) => c.payload != null).length
  const evidence = p.evidence.length
  const riskCount = p.risks?.length ?? 0
  return [
    { label: 'Typed changes', value: typedChanges, tone: typedChanges ? 'good' : 'warn' },
    { label: 'Evidence links', value: evidence, tone: evidence ? 'good' : 'warn' },
    { label: 'Risk notes', value: riskCount, tone: riskCount ? 'warn' : 'neutral' },
    { label: 'Total diffs', value: p.changes.length, tone: p.changes.length ? 'neutral' : 'warn' },
  ] as const
}

/**
 * The focused review surface. Opening a pending decision from the sidebar shows
 * the actual research diff + its evidence + approve/reject here — never a
 * generic confirmation modal. Approving/rejecting closes it (the store clears
 * the focus). Esc or a click on the scrim dismisses without deciding.
 */
export function ReviewFocus() {
  const id = useKaisola((s) => s.focusedProposalId)
  const proposals = useKaisola((s) => s.project.proposals)
  const close = useKaisola((s) => s.focusProposal)
  const pickWinner = useKaisola((s) => s.pickWinner)
  const synthesizeProposals = useKaisola((s) => s.synthesizeProposals)

  useEffect(() => {
    if (!id) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close(null)
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [id, close])

  const proposal = proposals.find((p) => p.id === id)
  if (!id || !proposal) return null

  // best-of-N: if this proposal belongs to a group with >1 pending sibling,
  // show a side-by-side compare and let the human pick the winner (the gate).
  const competing =
    proposal.groupId != null
      ? proposals.filter((p) => p.groupId === proposal.groupId && p.status === 'pending')
      : []
  const isCompare = competing.length > 1
  const canSynthesize = isCompare && !competing.some((p) => p.agentId === 'human')

  return (
    <div className="focus-scrim" onMouseDown={() => close(null)}>
      <div className={`focus-panel${isCompare ? ' focus-panel-wide' : ''}`} onMouseDown={(e) => e.stopPropagation()}>
        <header className="focus-head">
          <Icon name={isCompare ? 'Columns3' : 'GitPullRequestArrow'} size={14} className="muted" />
          <span className="grow">{isCompare ? `Best-of-${competing.length}: pick the winner — the rest are rejected` : 'Review decision'}</span>
          {canSynthesize && (
            <button className="btn btn-sm" onClick={() => synthesizeProposals(competing.map((p) => p.id))}>
              <Icon name="GitMerge" size={13} /> Synthesize
            </button>
          )}
          <button className="btn-icon btn-sm" onClick={() => close(null)} aria-label="Close">
            <Icon name="X" size={14} />
          </button>
        </header>
        <div className="focus-body">
          {isCompare ? (
            <div className="compare-grid" data-n={competing.length}>
              {competing.map((p, i) => (
                <div key={p.id} className="compare-col">
                  <div className="compare-col-head">
                    <span className="compare-seed">Option {i + 1}</span>
                    <button className="btn btn-primary btn-sm" onClick={() => pickWinner(p.id)}>
                      <Icon name="Crown" size={13} /> Pick this
                    </button>
                  </div>
                  <div className="compare-rubric">
                    {scoreProposal(p).map((item) => (
                      <div key={item.label} className="compare-score" data-tone={item.tone}>
                        <span>{item.label}</span>
                        <b>{item.value}</b>
                      </div>
                    ))}
                  </div>
                  <ProposalCard proposal={p} hideActions />
                </div>
              ))}
            </div>
          ) : (
            <ProposalCard proposal={proposal} />
          )}
        </div>
      </div>
    </div>
  )
}
