import { useEffect, useState } from 'react'
import { bridge, type LedgerTask } from '../../lib/bridge'
import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'

/** The agent-task ledger as a browsable dock card. Agents post/claim/finish
 * tasks over the Kaisola MCP server; this is the human's window into that
 * traffic — and the composer at the top is the human POSTING work to agents
 * through the same ledger (direct interface, no middleman). */

const STATUS_TONE: Record<string, string> = {
  open: 'var(--info)',
  claimed: 'var(--accent)',
  in_progress: 'var(--accent)',
  blocked: 'var(--warn)',
  review: 'var(--warn)',
  done: 'var(--success)',
  rejected: 'var(--danger)',
}

const age = (at: number): string => {
  const m = Math.max(0, Math.round((Date.now() - at) / 60_000))
  return m < 1 ? 'now' : m < 60 ? `${m}m` : m < 60 * 24 ? `${Math.round(m / 60)}h` : `${Math.round(m / 1440)}d`
}

const resolveTask = (id: string, projectId: string, status: 'done' | 'rejected') => {
  void bridge.ledger?.update({ id, projectId, status })
}

export function LedgerCard() {
  const workspacePath = useKaisola((s) => s.workspacePath)
  const projectId = useKaisola((s) => s.activeProjectId)
  const [tasks, setTasks] = useState<LedgerTask[]>([])
  const [title, setTitle] = useState('')
  const [owner, setOwner] = useState('')

  const refresh = () => {
    void bridge.ledger?.list({ project: workspacePath ?? undefined }).then((r) => {
      if (r.ok) setTasks(r.tasks)
    })
  }
  useEffect(() => {
    refresh()
    return bridge.ledger?.onEvent(() => refresh())
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [workspacePath])

  const post = () => {
    const t = title.trim()
    if (!t) return
    void bridge.ledger?.post({
      project: workspacePath ?? undefined,
      projectId,
      title: t,
      owner: owner.trim() || undefined,
      createdBy: 'human',
    }).then(() => { setTitle(''); setOwner('') })
  }
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8, height: '100%', padding: '10px 12px', overflow: 'hidden', fontSize: 'var(--fs-12)' }}>
      <div style={{ display: 'flex', gap: 6 }}>
        <input
          className="input"
          style={{ flex: 1, minWidth: 0 }}
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') post() }}
          placeholder="Post a task to your agents…"
          spellCheck={false}
        />
        <input
          className="input"
          style={{ width: 92 }}
          value={owner}
          onChange={(e) => setOwner(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') post() }}
          placeholder="To (agent)"
          spellCheck={false}
          title="Address a specific agent, e.g. claude / codex (optional)"
        />
        <button type="button" className="btn btn-primary btn-sm" disabled={!title.trim()} onClick={post} title="Post to the shared ledger — agents see it via agent_tasks_list" aria-label="Post task to shared ledger">
          <Icon name="Send" size={12} />
        </button>
      </div>

      <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 6 }}>
        {tasks.length === 0 && (
          <div className="faint" style={{ padding: '18px 4px', textAlign: 'center' }}>
            No agent tasks yet. Agents post work and results here (over the Kaisola MCP tools),
            and anything you post above shows up in their <code>agent_tasks_list</code>.
          </div>
        )}
        {tasks.map((t) => (
          <div key={t.id} style={{ display: 'flex', flexDirection: 'column', gap: 3, padding: '7px 9px', borderRadius: 'var(--r-2)', background: 'var(--bg-3)', border: '1px solid var(--border-faint)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7, minWidth: 0 }}>
              <span title={t.status} style={{ width: 7, height: 7, borderRadius: '50%', flexShrink: 0, background: STATUS_TONE[t.status] ?? 'var(--text-3)' }} />
              <span className="truncate" style={{ fontWeight: 500 }}>{t.title}</span>
              <span className="grow" />
              <span className="faint" style={{ whiteSpace: 'nowrap' }}>{age(t.updatedAt)}</span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7, minWidth: 0 }}>
              <span className="faint truncate">
                {t.status}
                {t.owner ? ` · ${t.owner}` : ''}
                {t.createdBy ? ` · from ${t.createdBy}` : ''}
              </span>
              <span className="grow" />
              {t.status !== 'done' && t.status !== 'rejected' && (
                <>
                  <button type="button" className="btn-icon btn-sm" onClick={() => resolveTask(t.id, projectId, 'done')} title="Mark done" aria-label={`Mark ${t.title} done`}>
                    <Icon name="Check" size={12} />
                  </button>
                  <button type="button" className="btn-icon btn-sm" onClick={() => resolveTask(t.id, projectId, 'rejected')} title="Reject" aria-label={`Reject ${t.title}`}>
                    <Icon name="X" size={12} />
                  </button>
                </>
              )}
            </div>
            {(t.detail || t.result) && (
              <div className="faint" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', maxHeight: 96, overflowY: 'auto' }}>
                {t.result ?? t.detail}
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
