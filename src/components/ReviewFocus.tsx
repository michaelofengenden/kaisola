import { useCallback, useEffect, useRef } from 'react'
import { useKaisola } from '../store/store'
import { useClickAway } from '../lib/useClickAway'
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
  const panelRef = useRef<HTMLDivElement>(null)
  const dismissTriggerRef = useRef<HTMLElement>(null)
  // j/k hunk cursor — DOM-walked ([data-hunknav]) so it needs no state coupling
  const navRef = useRef(-1)

  const proposal = proposals.find((p) => p.id === id)
  // best-of-N: if this proposal belongs to a group with >1 pending sibling,
  // show a side-by-side compare and let the human pick the winner (the gate).
  const competing =
    proposal?.groupId != null
      ? proposals.filter((p) => p.groupId === proposal.groupId && p.status === 'pending')
      : []
  const isCompare = competing.length > 1
  const canSynthesize = isCompare && !competing.some((p) => p.agentId === 'human')
  const pending = proposal?.status === 'pending'
  const isFilePatch = !!proposal?.changes.some((c) => c.entityType === 'file')
  const dismiss = useCallback(() => close(null), [close])
  useClickAway(!!id, dismiss, dismissTriggerRef, panelRef)

  useEffect(() => { navRef.current = -1 }, [id])
  useEffect(() => {
    if (!id) return
    // Hunk-style single-keystroke review: j/k walk the hunks, a approves
    // (merge for file patches), r rejects, Esc dismisses without deciding.
    // Compare mode keeps a/r off — picking a winner must stay deliberate.
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return
      const t = e.target as HTMLElement | null
      if (t?.closest('input, textarea, select, [contenteditable="true"]')) return
      if (e.key === 'j' || e.key === 'k') {
        const nodes = [...(panelRef.current?.querySelectorAll('[data-hunknav]') ?? [])] as HTMLElement[]
        if (!nodes.length) return
        e.preventDefault()
        navRef.current = Math.min(nodes.length - 1, Math.max(0, navRef.current + (e.key === 'j' ? 1 : -1)))
        nodes.forEach((n, i) => n.toggleAttribute('data-navactive', i === navRef.current))
        const active = nodes[navRef.current]
        // a hunk inside a collapsed file must open before it can be seen
        active.closest('details')?.setAttribute('open', '')
        active.scrollIntoView({ block: 'center', behavior: 'smooth' })
        return
      }
      if (isCompare || !pending || !proposal) return
      const st = useKaisola.getState()
      if (e.key === 'a') {
        e.preventDefault()
        if (isFilePatch) void st.mergeWorktreeProposal(proposal.id)
        else st.approveProposal(proposal.id)
      } else if (e.key === 'r') {
        e.preventDefault()
        st.rejectProposal(proposal.id)
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [id, isCompare, pending, isFilePatch, proposal])

  if (!id || !proposal) return null

  return (
    <div className="focus-scrim">
      <div ref={panelRef} className={`focus-panel${isCompare ? ' focus-panel-wide' : ''}`}>
        <header className="focus-head">
          <Icon name={isCompare ? 'Columns3' : 'GitPullRequestArrow'} size={14} className="muted" />
          <span className="grow">{isCompare ? `Best-of-${competing.length}: pick the winner — the rest are rejected` : 'Review decision'}</span>
          {canSynthesize && (
            <button type="button" className="btn btn-sm" onClick={() => synthesizeProposals(competing.map((p) => p.id))}>
              <Icon name="GitMerge" size={13} /> Synthesize
            </button>
          )}
          <button type="button" className="btn-icon btn-sm" onClick={() => close(null)} aria-label="Close review">
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
                    <button type="button" className="btn btn-primary btn-sm" onClick={() => pickWinner(p.id)}>
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
        {!isCompare && pending && (
          <footer className="focus-keys">
            <span><kbd>j</kbd><kbd>k</kbd> hunks</span>
            <span><kbd>a</kbd> {isFilePatch ? 'merge' : 'approve'}</span>
            <span><kbd>r</kbd> reject</span>
            <span><kbd>esc</kbd> close</span>
          </footer>
        )}
      </div>
    </div>
  )
}
