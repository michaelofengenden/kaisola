import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { ShellTools } from './AgentSidebar'
import { AppAccountButton } from './AppAccountButton'
import { InboxButton } from './InboxButton'

/**
 * One quiet utility row at the bottom of whichever left sidebar is active.
 * The avatar is identity enough here; the full account lives in its popover.
 */
export function ShellSidebarFooter({ floating = false }: { floating?: boolean }) {
  const openSettings = useKaisola((s) => s.setSettingsOpen)

  return (
    <div className="shell-sidebar-footer" data-floating={floating || undefined} aria-label="Workspace controls">
      <div className="shell-sidebar-footer-tools">
        <AppAccountButton />
        <button type="button" className="btn-icon shell-settings-trigger" onClick={() => openSettings(true)} title="Settings  ⌘," aria-label="Open settings">
          <Icon name="Settings" size={15} />
        </button>
        <ShellTools includeSettings={false} />
        <InboxButton />
      </div>
    </div>
  )
}
