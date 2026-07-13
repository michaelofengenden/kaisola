import { useCallback, useEffect, useRef, useState } from 'react'
import { useKaisola } from '../../store/store'
import { bridge, type LedgerTask } from '../../lib/bridge'
import { Icon } from '../Icon'
import { useClickAway } from '../../lib/useClickAway'

/**
 * The cross-project inbox: one bell in the tab strip rolling up everything
 * that waits on the human — sessions marked needs-you and pending permission
 * asks in THIS project, parked permission asks and needs-you/failed badges on
 * every BACKGROUND project tab, plus ledger tasks sitting in review/blocked
 * (fetched when the menu opens). Clicking a row jumps there. The button hides
 * stays anchored at zero so navigation never jumps. Settings → Interface toggle.
 */

interface Row {
  key: string
  pid?: string // switch to this project (absent = active project)
  sessionId?: string // reveal this session (active project only)
  ledger?: boolean
  icon: string
  label: string
  detail?: string
}

export function InboxButton() {
  const enabled = useKaisola((s) => s.inbox)
  const needsYou = useKaisola((s) => s.needsYou)
  const pendingPermissions = useKaisola((s) => s.pendingPermissions)
  const projectSlices = useKaisola((s) => s.projectSlices)
  const projectTabs = useKaisola((s) => s.projectTabs)
  const activeProjectId = useKaisola((s) => s.activeProjectId)
  const [open, setOpen] = useState(false)
  const [ledgerRows, setLedgerRows] = useState<LedgerTask[]>([])
  const buttonRef = useRef<HTMLButtonElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const close = useCallback(() => setOpen(false), [])
  useClickAway(open, close, buttonRef, panelRef)

  const rows: Row[] = []
  if (enabled) {
    const st = useKaisola.getState()
    const terminalById = new Map<string, (typeof st.terminals)[number]>()
    const threadById = new Map<string, (typeof st.assistantThreads)[number]>()
    for (const terminal of st.terminals) terminalById.set(terminal.id, terminal)
    for (const thread of st.assistantThreads) threadById.set(thread.id, thread)
    for (const id of Object.keys(needsYou)) {
      const term = terminalById.get(id)
      const thread = threadById.get(id)
      rows.push({
        key: `ny:${id}`,
        sessionId: id,
        icon: term ? 'SquareTerminal' : 'Bot',
        label: term ? (term.name ?? term.autoName ?? 'Terminal') : (thread?.agentKey ?? 'Session'),
        detail: 'needs you',
      })
    }
    for (const p of pendingPermissions) {
      // Mesh workers are private tabs; their permission UI is aggregated on the
      // visible parent, so Inbox must never jump to the clipped child surface.
      const childId = p.key.split('::')[1]
      const child = threadById.get(childId)
      rows.push({ key: `perm:${p.permId}`, sessionId: child?.groupParentId ?? childId, icon: 'ShieldQuestion', label: p.title, detail: `${p.agent} · permission` })
    }
    for (const tab of projectTabs) {
      if (tab.id === activeProjectId) continue
      const slice = projectSlices[tab.id]
      const tabName = tab.title ?? tab.workspacePath?.split('/').filter(Boolean).pop() ?? 'New Project'
      for (const p of slice?.pendingPermissions ?? []) {
        rows.push({ key: `bperm:${tab.id}:${p.permId}`, pid: tab.id, icon: 'ShieldQuestion', label: p.title, detail: `${tabName} · permission` })
      }
      if (tab.activity === 'needs-you' || tab.activity === 'failed') {
        rows.push({
          key: `act:${tab.id}`,
          pid: tab.id,
          icon: tab.activity === 'failed' ? 'TriangleAlert' : 'Hand',
          label: tabName,
          detail: tab.activity === 'failed' ? 'a session failed' : 'needs you',
        })
      }
    }
  }
  const count = rows.length

  useEffect(() => {
    if (!open) return
    let dead = false
    void bridge.ledger
      ?.list()
      .then((r) => {
        if (dead) return
        const tasks = (Array.isArray(r) ? r : (r as { tasks?: LedgerTask[] })?.tasks) ?? []
        setLedgerRows(tasks.filter((t) => t.status === 'review' || t.status === 'blocked'))
      })
      .catch(() => setLedgerRows([]))
    return () => {
      dead = true
    }
  }, [open])

  if (!enabled) return null

  const jump = (row: Row) => {
    const st = useKaisola.getState()
    if (row.ledger) st.openLedgerPanel()
    else if (row.pid) st.switchProject(row.pid)
    else if (row.sessionId) st.switchSession(row.sessionId)
    setOpen(false)
  }

  return (
    <div className="inbox-wrap">
      <button
        type="button"
        ref={buttonRef}
        className="inbox-btn"
        onClick={() => setOpen((o) => !o)}
        title="Everything that needs you, across every project tab"
        aria-label={`Inbox — ${count} waiting`}
      >
        <Icon name={count > 0 ? 'BellDot' : 'Bell'} size={14} />
        {count > 0 && <span className="inbox-count">{count}</span>}
      </button>
      {open && (
          <div ref={panelRef} className="inbox-menu">
            {rows.length === 0 && ledgerRows.length === 0 && <div className="inbox-empty">Nothing needs you.</div>}
            {rows.map((row) => (
              <button type="button" key={row.key} className="inbox-row" onClick={() => jump(row)}>
                <Icon name={row.icon} size={13} />
                <span className="inbox-row-label truncate">{row.label}</span>
                {row.detail && <span className="inbox-row-detail truncate">{row.detail}</span>}
              </button>
            ))}
            {ledgerRows.map((t) => (
              <button type="button" key={`lg:${t.id}`} className="inbox-row" onClick={() => jump({ key: '', ledger: true, icon: '', label: '' })}>
                <Icon name="ClipboardList" size={13} />
                <span className="inbox-row-label truncate">{t.title}</span>
                <span className="inbox-row-detail truncate">ledger · {t.status}</span>
              </button>
            ))}
            {rows.length > 0 && (
              <button
                type="button"
                className="inbox-row inbox-clear"
                onClick={() => { useKaisola.getState().clearInbox(); setOpen(false) }}
                title="Dismiss the waiting badges (permission asks stay until answered)"
              >
                <Icon name="CheckCheck" size={13} />
                <span className="inbox-row-label">Clear all</span>
              </button>
            )}
          </div>
      )}
    </div>
  )
}
