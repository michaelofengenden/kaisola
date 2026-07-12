import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'

/**
 * The permanent chrome stays deliberately small: find, usage, file preview,
 * and settings. Layout and agent configuration live in Settings instead of
 * spending permanent top-bar slots.
 */
export function ShellTools({ includeSettings = true }: { includeSettings?: boolean }) {
  const layoutMode = useKaisola((s) => s.layoutMode)
  const openPalette = useKaisola((s) => s.openPalette)
  const canvasOpen = useKaisola((s) => s.canvasOpen)
  const toggleCanvas = useKaisola((s) => s.toggleCanvas)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  return (
    <>
      <button className="btn-icon" onClick={() => openPalette()} title="Command palette  ⌘K">
        <Icon name="Search" size={15} />
      </button>
      <LimitsButton />
      {layoutMode === 'studio' && !canvasOpen && (
        <button
          className="btn-icon file-preview-toggle"
          onClick={toggleCanvas}
          title="Show file preview  ⌘."
          aria-label="Show file preview"
        >
          <Icon name="PanelRightOpen" size={15} />
        </button>
      )}
      {includeSettings && (
        <button className="btn-icon shell-settings-trigger" onClick={() => openSettings(true, 'interface')} title="Settings  ⌘," aria-label="Open settings">
          <Icon name="Settings" size={15} />
        </button>
      )}
    </>
  )
}
