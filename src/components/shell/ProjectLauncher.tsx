import { useKaisola } from '../../store/store'
import { bridge } from '../../lib/bridge'
import { folderHue } from '../../lib/sessionHue'
import { Icon } from '../Icon'

/**
 * The empty-state canvas for a tab with no workspace yet — recents grid, an
 * "Open folder" picker, and a drop hint. Picking a folder calls `setWorkspace`,
 * which rebinds THIS empty tab in place (no extra tab). OS folder drops are
 * caught by the window-level handler in App.
 */
export function ProjectLauncher() {
  const recentProjects = useKaisola((s) => s.recentProjects)
  const setWorkspace = useKaisola((s) => s.setWorkspace)
  const pushToast = useKaisola((s) => s.pushToast)

  // a folder that's already open in another tab focuses THAT tab (Chrome's
  // dedupe, same as the + menu) — the now-redundant empty tab closes itself
  const openPath = (path: string) => {
    const s = useKaisola.getState()
    const existing = s.projectTabs.find((t) => t.workspacePath === path && t.id !== s.activeProjectId)
    if (existing) {
      const emptyTab = s.activeProjectId
      s.switchProject(existing.id)
      s.closeProject(emptyTab, { force: true })
      return
    }
    setWorkspace(path) // rebinds THIS empty tab in place
  }
  const open = async () => {
    const r = await bridge.pickFolder()
    if (r.ok && r.path) openPath(r.path)
    else if (r.message) pushToast('warn', r.message)
  }

  return (
    <div className="plaunch">
      <div className="plaunch-panel">
        <h1 className="plaunch-title">Open a project</h1>
        <p className="plaunch-sub">Pick a folder to start a workspace in this tab.</p>
        <button type="button" className="plaunch-open" onClick={() => void open()}>
          <Icon name="FolderOpen" size={14} /> Open folder…
        </button>
        {recentProjects.length > 0 && (
          <div className="plaunch-recents">
            {recentProjects.map((r) => (
              <button type="button" key={r.path} className="plaunch-recent" onClick={() => openPath(r.path)} title={r.path}>
                <Icon name="Folder" size={16} className="plaunch-recent-icon" style={{ color: folderHue(r.path) }} />
                <span className="plaunch-recent-body">
                  <span className="plaunch-recent-name">{r.name}</span>
                  <span className="plaunch-recent-path">{r.path}</span>
                </span>
              </button>
            ))}
          </div>
        )}
        <div className="plaunch-drop">Drop a folder anywhere to open it here</div>
      </div>
    </div>
  )
}
