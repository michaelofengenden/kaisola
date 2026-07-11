import { useCallback, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useKaisola, dockShowsLiveCard } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'
import { useClickAway } from '../../lib/useClickAway'

/**
 * The permanent chrome stays deliberately small: find, usage, file preview,
 * and one clearly named layout menu. Agent/MCP configuration lives in
 * Settings instead of spending a permanent top-bar slot.
 */
export function ShellTools() {
  const layoutMode = useKaisola((s) => s.layoutMode)
  const toggleLayoutMode = useKaisola((s) => s.toggleLayoutMode)
  const openPalette = useKaisola((s) => s.openPalette)
  // label from the same predicate toggleDock decides with — dockOpen alone
  // lies over a stale/empty grid ("Hide sessions" on an invisible dock)
  const dockVisible = useKaisola((s) => s.dockOpen && dockShowsLiveCard(s))
  const toggleDock = useKaisola((s) => s.toggleDock)
  const canvasOpen = useKaisola((s) => s.canvasOpen)
  const toggleCanvas = useKaisola((s) => s.toggleCanvas)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  const tabLayout = useKaisola((s) => s.tabLayout)
  const setTabLayout = useKaisola((s) => s.setTabLayout)
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState({ right: 8, top: 42 })
  const button = useRef<HTMLButtonElement>(null)
  const panel = useRef<HTMLDivElement>(null)
  const close = useCallback(() => setOpen(false), [])

  useClickAway(open, close, button, panel)

  const toggle = () => {
    if (!open) {
      const rect = button.current?.getBoundingClientRect()
      if (rect) setPos({ right: Math.max(8, window.innerWidth - rect.right), top: rect.bottom + 6 })
    }
    setOpen((value) => !value)
  }
  return (
    <>
      <button className="btn-icon" onClick={() => openPalette()} title="Command palette  ⌘K">
        <Icon name="Search" size={15} />
      </button>
      <LimitsButton />
      <button
        className="btn-icon file-preview-toggle"
        data-active={layoutMode === 'studio' && canvasOpen}
        onClick={toggleCanvas}
        title={canvasOpen && layoutMode === 'studio' ? 'Hide file preview  ⌘.' : 'Show file preview  ⌘.'}
        aria-label={canvasOpen && layoutMode === 'studio' ? 'Hide file preview' : 'Show file preview'}
      >
        <Icon name={canvasOpen && layoutMode === 'studio' ? 'PanelRightClose' : 'PanelRightOpen'} size={15} />
      </button>
      <button ref={button} className="shell-layout-trigger" data-active={open} onClick={toggle} title="Layout controls" aria-label="Layout controls" aria-expanded={open}>
        <Icon name="PanelsTopLeft" size={14} />
        <span>Layout</span>
      </button>
      {open && createPortal(
          <div ref={panel} className="tree-menu shell-more-menu" style={{ position: 'fixed', right: pos.right, top: pos.top }} aria-label="Layout controls">
            <button className="tree-menu-item" onClick={() => setTabLayout(tabLayout === 'sidebar' ? 'bare' : 'sidebar')}>
              <Icon name={tabLayout === 'sidebar' ? 'PanelTop' : 'PanelsTopLeft'} size={13} />
              {tabLayout === 'sidebar' ? 'Move sessions to top' : 'Move sessions to left'}
            </button>
            <button className="tree-menu-item" onClick={toggleLayoutMode}>
              <Icon name={layoutMode === 'focus' ? 'PanelsTopLeft' : 'Focus'} size={13} />
              {layoutMode === 'focus' ? 'Show files and sessions' : 'Show files only'}
              <kbd>⌘⇧F</kbd>
            </button>
            <button className="tree-menu-item" onClick={toggleDock}>
              <Icon name="SquareTerminal" size={13} /> {dockVisible && layoutMode === 'studio' ? 'Hide session panels' : 'Show session panels'}
              <kbd>⌘J</kbd>
            </button>
          </div>,
        document.body,
      )}
      <button className="btn-icon shell-settings-trigger" onClick={() => openSettings(true)} title="Settings  ⌘," aria-label="Open settings">
        <Icon name="Settings" size={15} />
      </button>
    </>
  )
}
