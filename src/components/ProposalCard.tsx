import { useMemo, useState } from 'react'
import type { Proposal, ProposalChange } from '../domain/types'
import { useKaisola } from '../store/store'
import { AGENT_META } from '../agents/types'
import { ResearchDiff } from './ResearchDiff'
import { ProvenanceChip } from './Provenance'
import { Icon } from './Icon'
import { relTime } from '../lib/format'
import { lineHunks, type Hunk } from '../lib/wordDiff'

/**
 * A pending proposal, presented as a reviewable gate: what the agent wants to
 * change (research diffs), why (evidence), what a reviewer would complain about
 * (risks), and the approve / reject controls. Nothing mutates the trajectory
 * until the human acts. Edit opens per-hunk checkboxes — a partial accept is
 * just a smaller proposal through the same gate (status 'edited').
 */

// Hunk editing is offered ONLY where the applied patch provably tracks the
// displayed text: an update whose payload.patch has a field strictly equal to
// `after`. Anything else applies whole — never risk display/apply divergence.
const canEditChange = (c: ProposalChange): boolean => {
  if (c.entityType === 'file' || c.kind !== 'update' || c.before == null || c.after == null) return false
  const patch = (c.payload as { patch?: Record<string, unknown> } | undefined)?.patch
  return !!patch && Object.values(patch).some((v) => v === c.after)
}

const hunkPreview = (h: Hunk): string => {
  const del = h.del[0] ? `− ${h.del[0]}` : ''
  const add = h.add[0] ? `+ ${h.add[0]}` : ''
  const more = h.del.length + h.add.length > 2 ? ` … (${h.del.length}−/${h.add.length}+)` : ''
  return [del, add].filter(Boolean).join('   ') + more
}

export function ProposalCard({ proposal, hideActions }: { proposal: Proposal; hideActions?: boolean }) {
  const approve = useKaisola((s) => s.approveProposal)
  const approvePartial = useKaisola((s) => s.approveProposalPartial)
  const reject = useKaisola((s) => s.rejectProposal)
  const mergeWorktree = useKaisola((s) => s.mergeWorktreeProposal)
  // proposals can arrive from outside the research roster (a CLI agent via the
  // ledger, a probe) — an unknown id must degrade to a generic tag, never
  // crash the tree (there's no error boundary above this card)
  const agent = AGENT_META[proposal.agentId] ?? { name: proposal.agentId, icon: 'Bot' }
  const resolved = proposal.status !== 'pending'
  // a file-patch proposal is merged (git) on approve, not applied to entities
  const isFilePatch = proposal.changes.some((c) => c.entityType === 'file')

  const [editing, setEditing] = useState(false)
  // changeId → hunk indexes the human UNCHECKED (default: everything kept)
  const [dropped, setDropped] = useState<Record<string, Set<number>>>({})
  const editable = useMemo(
    () => proposal.changes.flatMap((change) => (
      canEditChange(change) ? [{ change, hunks: lineHunks(change.before!, change.after!) }] : []
    )),
    [proposal.changes],
  )
  const anyDropped = Object.values(dropped).some((s) => s.size > 0)
  const toggleHunk = (changeId: string, idx: number) =>
    setDropped((d) => {
      const cur = new Set(d[changeId] ?? [])
      if (cur.has(idx)) cur.delete(idx)
      else cur.add(idx)
      return { ...d, [changeId]: cur }
    })
  const approveNow = () => {
    if (isFilePatch) { void mergeWorktree(proposal.id); return }
    if (!anyDropped) { approve(proposal.id); return }
    const keep: Record<string, number[]> = {}
    for (const { change, hunks } of editable) {
      const drop = dropped[change.id]
      if (!drop || drop.size === 0) continue
      const keptIndexes: number[] = []
      for (let index = 0; index < hunks.length; index++) {
        if (!drop.has(index)) keptIndexes.push(index)
      }
      keep[change.id] = keptIndexes
    }
    approvePartial(proposal.id, keep)
  }

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

      {editing && !resolved && (
        <div className="proposal-hunks">
          {editable.map(({ change, hunks }) => (
            <div key={change.id} className="proposal-hunks-change">
              <span className="caps">{change.label} · keep which parts?</span>
              {hunks.map((h, i) => (
                <label key={`${change.id}:${h.aStart}`} className="proposal-hunk">
                  <input
                    type="checkbox"
                    checked={!dropped[change.id]?.has(i)}
                    onChange={() => toggleHunk(change.id, i)}
                  />
                  <span className="proposal-hunk-preview truncate">{hunkPreview(h)}</span>
                </label>
              ))}
            </div>
          ))}
        </div>
      )}

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
          <Icon name={proposal.status === 'rejected' ? 'X' : 'Check'} size={13} />
          {proposal.status === 'approved' ? 'Approved & applied'
            : proposal.status === 'edited' ? 'Approved with edits'
              : 'Rejected'}
        </div>
      ) : hideActions ? null : (
        <div className="proposal-actions">
          <button type="button" className="btn btn-primary btn-sm" onClick={approveNow}>
            <Icon name={isFilePatch ? 'GitMerge' : 'Check'} size={13} />{' '}
            {isFilePatch ? 'Merge' : anyDropped ? 'Approve kept hunks' : 'Approve'}
          </button>
          {editable.length > 0 && (
            <button
              type="button"
              className={`btn btn-sm${editing ? ' btn-active' : ''}`}
              onClick={() => setEditing((e) => !e)}
              title="Choose which hunks of this change to accept"
            >
              <Icon name="Pencil" size={13} /> Edit
            </button>
          )}
          <button type="button" className="btn btn-danger btn-sm" onClick={() => reject(proposal.id)}>
            <Icon name="X" size={13} /> Reject
          </button>
        </div>
      )}
    </article>
  )
}
