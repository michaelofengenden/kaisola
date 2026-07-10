import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'
import { AgentStatusButton } from './AgentStatusButton'
import { openExtensionsCenter } from '../../lib/extensions'

/**
 * The permanent chrome stays deliberately small: find, usage, live agents,
 * and one overflow. Workspace-shaping actions live in the overflow; agent
 * follow lives with agent status where its meaning is visible.
 */
export function ShellTools() {
  const layoutMode = useKaisola((s) => s.layoutMode)
  const toggleLayoutMode = useKaisola((s) => s.toggleLayoutMode)
  const setLayoutMode = useKaisola((s) => s.setLayoutMode)
  const openPalette = useKaisola((s) => s.openPalette)
  const dockOpen = useKaisola((s) => s.dockOpen)
  const toggleDock = useKaisola((s) => s.toggleDock)
  const setDock = useKaisola((s) => s.setDock)
  const canvasOpen = useKaisola((s) => s.canvasOpen)
  const toggleCanvas = useKaisola((s) => s.toggleCanvas)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState({ right: 8, top: 42 })
  const button = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])

  const toggle = () => {
    if (!open) {
      const rect = button.current?.getBoundingClientRect()
      if (rect) setPos({ right: Math.max(8, window.innerWidth - rect.right), top: rect.bottom + 6 })
    }
    setOpen((value) => !value)
  }
  const act = (fn: () => void) => { setOpen(false); fn() }

  return (
    <>
      <button className="btn-icon" onClick={() => openPalette()} title="Command palette  ⌘K">
        <Icon name="Search" size={15} />
      </button>
      <LimitsButton />
      <AgentStatusButton />
      <button ref={button} className="btn-icon" data-active={open} onClick={toggle} title="More">
        <Icon name="Ellipsis" size={16} />
      </button>
      {open && createPortal(
        <div className="tree-menu-overlay" onMouseDown={() => setOpen(false)}>
          <div className="tree-menu shell-more-menu" style={{ position: 'fixed', right: pos.right, top: pos.top }} onMouseDown={(event) => event.stopPropagation()}>
            <button className="tree-menu-item" onClick={() => act(toggleLayoutMode)}>
              <Icon name={layoutMode === 'focus' ? 'PanelsTopLeft' : 'Focus'} size={13} />
              {layoutMode === 'focus' ? 'Studio layout' : 'Focus layout'}
              <kbd>⌘⇧F</kbd>
            </button>
            <button className="tree-menu-item" onClick={() => act(() => {
              if (layoutMode === 'focus') { setLayoutMode('studio'); setDock(true) }
              else toggleDock()
            })}>
              <Icon name="SquareTerminal" size={13} /> {dockOpen && layoutMode === 'studio' ? 'Hide sessions' : 'Show sessions'}
              <kbd>⌘J</kbd>
            </button>
            <button className="tree-menu-item" onClick={() => act(toggleCanvas)}>
              <Icon name={canvasOpen ? 'PanelRightClose' : 'PanelRightOpen'} size={13} /> {canvasOpen ? 'Hide files' : 'Show files'}
              <kbd>⌘.</kbd>
            </button>
            <div className="tree-menu-sep" />
            <button className="tree-menu-item" onClick={() => act(openExtensionsCenter)}>
              <Icon name="Blocks" size={13} /> Extensions
            </button>
            <button className="tree-menu-item" onClick={() => act(() => openSettings(true))}>
              <Icon name="Settings" size={13} /> Settings
              <kbd>⌘,</kbd>
            </button>
          </div>
        </div>,
        document.body,
      )}
    </>
  )
}
