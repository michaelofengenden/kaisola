import { ShellTools } from './AgentSidebar'
import { AppAccountButton } from './AppAccountButton'
import { InboxButton } from './InboxButton'
import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'

/**
 * One quiet utility row at the bottom of whichever left sidebar is active.
 * The avatar is identity enough here; the full account — including Settings
 * and Usage — lives in its popover, so the row carries no standalone gear.
 */
export function ShellSidebarFooter({ floating = false }: { floating?: boolean }) {
  const theme = useKaisola((state) => state.theme)
  const toggleTheme = useKaisola((state) => state.toggleTheme)
  return (
    <div className="shell-sidebar-footer" data-floating={floating || undefined} aria-label="Workspace controls">
      <div className="shell-sidebar-footer-tools">
        <ShellTools includeSettings={false} />
        <InboxButton />
        <button type="button" className="btn-icon" onClick={toggleTheme} title={`Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`} aria-label="Toggle color theme">
          <Icon name="SunMoon" size={15} />
        </button>
        <span className="shell-sidebar-footer-spacer" />
        <AppAccountButton />
      </div>
    </div>
  )
}
