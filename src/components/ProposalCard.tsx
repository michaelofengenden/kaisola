import type { Proposal } from '../domain/types'
import { useKaisola } from '../store/store'
import { AGENT_META } from '../agents/types'
import { ResearchDiff } from './ResearchDiff'
import { ProvenanceChip } from './Provenance'
import { Icon } from './Icon'
import { relTime } from '../lib/format'

/**
 * A pending proposal, presented as a reviewable gate: what the agent wants to
 * change (research diffs), why (evidence), what a reviewer would complain about
 * (risks), and the approve / reject controls. Nothing mutates the trajectory
 * until the human acts.
 */
export function ProposalCard({ proposal, hideActions }: { proposal: Proposal; hideActions?: boolean }) {
  const approve = useKaisola((s) => s.approveProposal)
  const reject = useKaisola((s) => s.rejectProposal)
  const mergeWorktree = useKaisola((s) => s.mergeWorktreeProposal)
  const agent = AGENT_META[proposal.agentId]
  const resolved = proposal.status !== 'pending'
  // a file-patch proposal is merged (git) on approve, not applied to entities
  const isFilePatch = proposal.changes.some((c) => c.entityType === 'file')

  return (
    <article className={`proposal proposal-${proposal.status}`}>
      <header className="proposal-head">
        <span className={`agent-tag agent-${proposal.agentId}`}>
          <Icon name={agent.icon} size={12} />
          {agent.name}
        </span>
        <span className="grow truncate proposal-title">{proposal.title}</span>
        <span className="faint" style={{ fontSize: 'var(--fs-11)' }}>{relTime(proposal.createdAt)}</span>
      </header>

      <p className="proposal-summary">{proposal.summary}</p>

      <div className="proposal-diffs">
        {proposal.changes.map((c) => (
          <ResearchDiff key={c.id} change={c} />
        ))}
      </div>

      <div className="proposal-meta">
        {proposal.evidence.length > 0 && (
          <div className="row gap-3 wrap">
            <span className="caps">Evidence</span>
            <ProvenanceChip links={proposal.evidence} title={`Why: ${proposal.title}`} />
          </div>
        )}
        {proposal.risks && proposal.risks.length > 0 && (
          <div className="proposal-risks">
            {proposal.risks.map((r, i) => (
              <span key={i} className="risk-flag">
                <Icon name="TriangleAlert" size={11} />
                {r}
              </span>
            ))}
          </div>
        )}
      </div>

      {resolved ? (
        <div className={`proposal-resolved proposal-resolved-${proposal.status}`}>
          <Icon name={proposal.status === 'approved' ? 'Check' : 'X'} size={13} />
          {proposal.status === 'approved' ? 'Approved & applied' : 'Rejected'}
        </div>
      ) : hideActions ? null : (
        <div className="proposal-actions">
          <button className="btn btn-primary btn-sm" onClick={() => (isFilePatch ? void mergeWorktree(proposal.id) : approve(proposal.id))}>
            <Icon name={isFilePatch ? 'GitMerge' : 'Check'} size={13} /> {isFilePatch ? 'Merge' : 'Approve'}
          </button>
          <button className="btn btn-sm" disabled title="Inline editing lands in Phase 2">
            <Icon name="Pencil" size={13} /> Edit
          </button>
          <button className="btn btn-danger btn-sm" onClick={() => reject(proposal.id)}>
            <Icon name="X" size={13} /> Reject
          </button>
        </div>
      )}
    </article>
  )
}
