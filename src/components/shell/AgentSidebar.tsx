import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'
import { AgentStatusButton } from './AgentStatusButton'
import { openExtensionsCenter } from '../../lib/extensions'

/**
 * The shell tool cluster — palette, dock toggle, settings, theme, sidebar.
 * Lives in the sidebar card's top strip; floats top-right when it's hidden.
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
  const followAgent = useKaisola((s) => s.followAgent)
  const toggleFollowAgent = useKaisola((s) => s.toggleFollowAgent)
  // Three quiet clusters instead of nine equal-weight icons (the measured
  // crowding): find things · shape the stage · watch the agents. The theme
  // toggle retired — it duplicated Settings → General → Theme and charged a
  // permanent icon for a twice-a-day action.
  return (
    <>
      <button className="btn-icon" onClick={() => openPalette()} title="Command palette  ⌘K">
        <Icon name="Search" size={15} />
      </button>
      <button
        className="btn-icon"
        data-active={followAgent}
        onClick={toggleFollowAgent}
        title={followAgent ? 'Following the agent — files it touches open as previews' : 'Follow the agent (Zed-style crosshair)'}
      >
        <Icon name="Crosshair" size={15} />
      </button>
      <span className="tools-sep" aria-hidden />
      <button className="btn-icon" data-active={layoutMode === 'studio'} onClick={toggleLayoutMode} title={layoutMode === 'focus' ? 'Show Studio layout  ⌘⇧F' : 'Show Focus layout  ⌘⇧F'}>
        <Icon name={layoutMode === 'focus' ? 'PanelsTopLeft' : 'Focus'} size={15} />
      </button>
      <button
        className="btn-icon"
        data-active={layoutMode === 'studio' && dockOpen}
        onClick={() => {
          if (layoutMode === 'focus') { setLayoutMode('studio'); setDock(true) }
          else toggleDock()
        }}
        title="Toggle terminal  ⌘J"
      >
        <Icon name="SquareTerminal" size={15} />
      </button>
      <button className="btn-icon" data-active={canvasOpen} onClick={toggleCanvas} title="Toggle main view  ⌘.">
        <Icon name={canvasOpen ? 'PanelRightClose' : 'PanelRightOpen'} size={15} />
      </button>
      <span className="tools-sep" aria-hidden />
      <LimitsButton />
      <AgentStatusButton />
      <button className="btn-icon" onClick={openExtensionsCenter} title="Extensions">
        <Icon name="Blocks" size={15} />
      </button>
      <button className="btn-icon" onClick={() => openSettings(true)} title="Settings  ⌘,">
        <Icon name="Settings" size={15} />
      </button>
    </>
  )
}
