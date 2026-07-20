import { useEffect } from 'react'
import { POP_PROJECT_ID, POP_WINDOW_HUE, POP_WINDOW_TITLE, useKaisola } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { Terminal } from '../Terminal'
import { Icon } from '../Icon'

/**
 * A popped-out terminal: one glass card filling its own window. The pty lives
 * in the main process — this window just attaches to its stream (and owns it
 * while open; the origin window re-adopts the card when this one closes).
 * The store here is a READ-ONLY rehydration of the main window's state.
 */
export function PopTerminal({ termId }: { termId: string }) {
  const theme = useKaisola((s) => s.theme)
  const meta = useKaisola((s) => s.terminalMeta[termId])
  useEffect(() => {
    document.documentElement.dataset.theme = theme
  }, [theme])
  useEffect(() => {
    const offMeta = bridge.terminal.onMeta((meta) => {
      if (meta.id !== termId) return
      useKaisola.getState().setTerminalMeta(termId, {
        fgProcess: meta.fgProcess,
        running: meta.running,
        cwd: meta.cwd,
        root: meta.root,
        repo: meta.repo,
        branch: meta.branch,
        ...(typeof meta.agentBusy === 'boolean' ? { agentBusy: meta.agentBusy } : {}),
        ...(meta.agentCompletedAt != null ? { agentCompletedAt: meta.agentCompletedAt } : {}),
        ...(meta.agentRespondedAt != null ? { agentRespondedAt: meta.agentRespondedAt } : {}),
      })
    })
    const offActivity = bridge.terminal.onAgentActivity((activity) => {
      if (activity.id !== termId) return
      useKaisola.getState().setTerminalMeta(termId, {
        agentBusy: activity.busy,
        ...(activity.completedAt != null ? { agentCompletedAt: activity.completedAt } : {}),
      })
    })
    return () => { offMeta(); offActivity() }
  }, [termId])
  const title = POP_WINDOW_TITLE || meta?.repo || 'Terminal'
  const sub = meta?.branch ? `${meta.repo ?? ''} ⎇ ${meta.branch}` : meta?.cwd
  return (
    <div className="app pop-app" data-pop>
      <div
        className="session-card pop-card"
        data-show="true"
        style={POP_WINDOW_HUE ? ({ '--sid': POP_WINDOW_HUE } as React.CSSProperties) : undefined}
      >
        <div className="pane-head pop-head">
          <button type="button" className="pop-light" onClick={() => bridge.winCtl('close')} title="Close — the card returns to its window" aria-label="Close popped-out terminal" />
          <Icon name="SquareTerminal" size={12} className="pane-head-icon" />
          <span className="pane-head-title truncate">{title}</span>
          {sub && <span className="pane-head-sub truncate">{sub}</span>}
          <span className="grow" />
        </div>
        <div className="dock-pane-term">
          <Terminal id={termId} attach projectId={POP_PROJECT_ID ?? undefined} />
        </div>
      </div>
    </div>
  )
}
