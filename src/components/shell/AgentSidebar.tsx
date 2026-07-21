import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'

/**
 * The global utility cluster stays deliberately small: find, usage, and
 * settings. Both navigation modes keep only frequent actions here; Usage and
 * Settings live in the adjacent account menu so the chrome stays one line.
 */
export function ShellTools({
  includeSettings = true,
  includeUsage = true,
}: {
  includeSettings?: boolean
  includeUsage?: boolean
}) {
  const openPalette = useKaisola((s) => s.openPalette)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  return (
    <>
      <button type="button" className="btn-icon" onClick={() => openPalette()} title="Command palette  ⌘K" aria-label="Open command palette">
        <Icon name="Search" size={15} />
      </button>
      {includeUsage && <LimitsButton />}
      {includeSettings && (
        <button type="button" className="btn-icon shell-settings-trigger" onClick={() => openSettings(true)} title="Settings  ⌘," aria-label="Open settings">
          <Icon name="Settings" size={15} />
        </button>
      )}
    </>
  )
}
