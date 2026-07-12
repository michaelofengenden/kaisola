import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { ShellTools } from './AgentSidebar'
import { AppAccountButton } from './AppAccountButton'
import { InboxButton } from './InboxButton'

/**
 * Cursor/ChatGPT-style global controls: utilities above, identity and Settings
 * at the very bottom. The active left sidebar owns this footer; when neither
 * sidebar exists, App renders the same component as a compact recovery dock.
 */
export function ShellSidebarFooter({ floating = false }: { floating?: boolean }) {
  const railOpen = useKaisola((s) => s.railOpen)
  const toggleRail = useKaisola((s) => s.toggleRail)
  const openSettings = useKaisola((s) => s.setSettingsOpen)

  return (
    <div className="shell-sidebar-footer" data-floating={floating || undefined} aria-label="Workspace controls">
      <div className="shell-sidebar-footer-tools">
        {!railOpen && (
          <button className="btn-icon" onClick={toggleRail} title="Show file tree  ⌘B" aria-label="Show file tree">
            <Icon name="FolderTree" size={15} />
          </button>
        )}
        <ShellTools includeSettings={false} />
        <InboxButton />
      </div>
      <div className="shell-sidebar-footer-account">
        <AppAccountButton showLabel />
        <span className="grow" />
        <button className="btn-icon shell-settings-trigger" onClick={() => openSettings(true, 'interface')} title="Settings  ⌘," aria-label="Open settings">
          <Icon name="Settings" size={15} />
        </button>
      </div>
    </div>
  )
}
