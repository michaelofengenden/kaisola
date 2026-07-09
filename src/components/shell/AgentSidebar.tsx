import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'
import { AgentStatusButton } from './AgentStatusButton'

/**
 * The shell tool cluster — palette, dock toggle, settings, theme, sidebar.
 * Lives in the sidebar card's top strip; floats top-right when it's hidden.
 */
export function ShellTools() {
  const theme = useKaisola((s) => s.theme)
  const toggleTheme = useKaisola((s) => s.toggleTheme)
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
      <LimitsButton />
      <AgentStatusButton />
      <button className="btn-icon" onClick={() => openSettings(true)} title="Settings  ⌘,">
        <Icon name="Settings" size={15} />
      </button>
      <button className="btn-icon" onClick={toggleTheme} title="Toggle theme">
        <Icon name={theme === 'dark' ? 'Sun' : 'Moon'} size={15} />
      </button>
    </>
  )
}
