import { ShellTools } from './AgentSidebar'
import { AppAccountButton } from './AppAccountButton'
import { InboxButton } from './InboxButton'

/**
 * One quiet utility row at the bottom of whichever left sidebar is active.
 * The avatar is identity enough here; the full account — including Settings
 * and Usage — lives in its popover, so the row carries no standalone gear.
 */
export function ShellSidebarFooter({ floating = false }: { floating?: boolean }) {
  return (
    <div className="shell-sidebar-footer" data-floating={floating || undefined} aria-label="Workspace controls">
      <div className="shell-sidebar-footer-tools">
        <ShellTools includeSettings={false} />
        <InboxButton />
        <span className="shell-sidebar-footer-spacer" />
        <AppAccountButton />
      </div>
    </div>
  )
}
