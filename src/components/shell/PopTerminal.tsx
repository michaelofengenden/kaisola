import { useEffect } from 'react'
import { POP_WINDOW_HUE, POP_WINDOW_TITLE, useKaisola } from '../../store/store'
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
          <button className="pop-light" onClick={() => bridge.winCtl('close')} title="Close — the card returns to its window" />
          <Icon name="SquareTerminal" size={12} className="pane-head-icon" />
          <span className="pane-head-title truncate">{title}</span>
          {sub && <span className="pane-head-sub truncate">{sub}</span>}
          <span className="grow" />
        </div>
        <div className="dock-pane-term">
          <Terminal id={termId} attach />
        </div>
      </div>
    </div>
  )
}
