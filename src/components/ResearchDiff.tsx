import type { ProposalChange } from '../domain/types'
import { Icon } from './Icon'

/**
 * The signature primitive — a research diff. The analogue of Cursor's code diff,
 * but for scientific objects: a changed claim, an added limitation, a removed
 * citation. before → after, with the agent's reason.
 */
export function ResearchDiff({ change }: { change: ProposalChange }) {
  const verb =
    change.kind === 'create' ? 'add' : change.kind === 'delete' ? 'remove' : 'change'

  // a file-patch change (from a coding agent's worktree) renders as a code diff
  if (change.entityType === 'file') {
    const patch = (change.payload as { patch?: string } | undefined)?.patch ?? change.after ?? ''
    return (
      <div className="rdiff rdiff-file">
        <div className="rdiff-head">
          <span className={`rdiff-kind rdiff-${change.kind}`}>{verb}</span>
          <span className="rdiff-entity">file</span>
          <span className="rdiff-label grow truncate">{change.label}</span>
          {change.reason && <span className="rdiff-stat faint">{change.reason}</span>}
        </div>
        <pre className="rdiff-patch">
          {patch.split('\n').map((line, i) => {
            const cls =
              line.startsWith('@@') ? 'pl-hunk'
                : line.startsWith('+') && !line.startsWith('+++') ? 'pl-add'
                  : line.startsWith('-') && !line.startsWith('---') ? 'pl-del'
                    : ''
            return <div key={i} className={cls}>{line || ' '}</div>
          })}
        </pre>
      </div>
    )
  }

  return (
    <div className="rdiff">
      <div className="rdiff-head">
        <span className={`rdiff-kind rdiff-${change.kind}`}>{verb}</span>
        <span className="rdiff-entity">{change.entityType.replace('-', ' ')}</span>
        <span className="rdiff-label grow truncate">{change.label}</span>
      </div>

      <div className="rdiff-body">
        {change.before != null && (
          <div className="rdiff-line rdiff-line-del">
            <span className="rdiff-gutter">−</span>
            <span className="rdiff-text serif">{change.before}</span>
          </div>
        )}
        {change.after != null && (
          <div className="rdiff-line rdiff-line-add">
            <span className="rdiff-gutter">+</span>
            <span className="rdiff-text serif">{change.after}</span>
          </div>
        )}
      </div>

      {change.reason && (
        <div className="rdiff-reason">
          <Icon name="CornerDownRight" size={12} />
          <span className="grow">{change.reason}</span>
        </div>
      )}
    </div>
  )
}
