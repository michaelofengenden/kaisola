import { ShellTools } from './AgentSidebar'
import { AppAccountButton } from './AppAccountButton'
import { InboxButton } from './InboxButton'
import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'

/**
 * One compact global-control cluster. Top mode owns it at the upper right;
 * Left mode keeps the same controls at the bottom of the navigation tree.
 */
export function ShellSidebarFooter({ floating = false, topbar = false }: { floating?: boolean; topbar?: boolean }) {
  const theme = useKaisola((state) => state.theme)
  const toggleTheme = useKaisola((state) => state.toggleTheme)
  return (
    <div className="shell-sidebar-footer" data-floating={floating || undefined} data-topbar={topbar || undefined} aria-label="Workspace controls">
      <div className="shell-sidebar-footer-tools">
        <ShellTools includeSettings={false} includeUsage={false} />
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
