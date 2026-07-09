import { useEffect, useState } from 'react'
import { useKaisola } from '../../store/store'
import { bridge, isDesktop } from '../../lib/bridge'
import { Icon } from '../Icon'

/**
 * The trust gate for kaisola://mcp/install deeplinks (Cursor's install-link
 * shape). Main validates the URL and hands over {name, config}; NOTHING is
 * written until Install is clicked here — the modal shows exactly what will
 * run (command/url, args, env NAMES — values masked) so the consent is real.
 * MCP 2025-06-18 consent guidance; the server lands in the user catalog and
 * rides new agent sessions like any other.
 */
export function McpInstallModal() {
  const [req, setReq] = useState<{ name: string; config: Record<string, unknown> } | null>(null)
  const [busyMsg, setBusyMsg] = useState<string | null>(null)

  useEffect(() => {
    const sub = bridge.mcp?.onInstallRequest
    if (!isDesktop || !sub) return
    return sub((r) => setReq(r))
  }, [])

  if (!req) return null
  const cfg = req.config
  const isRemote = typeof cfg.url === 'string'
  const envNames = cfg.env && typeof cfg.env === 'object' ? Object.keys(cfg.env as object) : []
  const close = () => { setReq(null); setBusyMsg(null) }
  const install = async () => {
    setBusyMsg('Installing…')
    const r = await bridge.mcp?.serverAdd?.(req.name, cfg)
    if (r?.ok) {
      useKaisola.getState().pushToast('success', `MCP server “${req.name}” added — new agent sessions can use it.`)
      close()
    } else {
      setBusyMsg(r?.message ?? 'Could not add the server.')
    }
  }

  return (
    <div className="focus-scrim" onMouseDown={close}>
      <div className="focus-panel mcp-install" onMouseDown={(e) => e.stopPropagation()}>
        <header className="focus-head">
          <Icon name="PackagePlus" size={14} className="muted" />
          <span className="grow">Add MCP server “{req.name}”?</span>
          <button className="btn-icon btn-sm" onClick={close} aria-label="Close">
            <Icon name="X" size={14} />
          </button>
        </header>
        <div className="mcp-install-body">
          <p className="mcp-install-warning">
            <Icon name="ShieldAlert" size={13} />
            A link wants to add a tool server that agents in Kaisola will be able to call.
            Only install servers from sources you trust.
          </p>
          <div className="mcp-install-spec">
            <div className="mcp-install-row">
              <span className="caps">{isRemote ? 'URL' : 'Command'}</span>
              <code className="truncate">{isRemote ? String(cfg.url) : [cfg.command, ...(Array.isArray(cfg.args) ? cfg.args : [])].join(' ')}</code>
            </div>
            {envNames.length > 0 && (
              <div className="mcp-install-row">
                <span className="caps">Env</span>
                <code className="truncate">{envNames.join(', ')} (values hidden)</code>
              </div>
            )}
          </div>
          {busyMsg && <p className="mcp-install-msg">{busyMsg}</p>}
        </div>
        <div className="mcp-install-actions">
          <button className="btn btn-primary btn-sm" onClick={() => void install()}>
            <Icon name="Check" size={13} /> Install
          </button>
          <button className="btn btn-sm" onClick={close}>Cancel</button>
        </div>
      </div>
    </div>
  )
}
