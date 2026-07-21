import { useEffect, useMemo, useRef, useState } from 'react'
import { bridge } from '../../lib/bridge'
import { createPairingQrGraphic } from '../../lib/pairingQr'
import type {
  CompanionState,
  CompanionPairingEvent,
  CompanionPairingStart,
} from '../../lib/bridge'
import { Icon } from '../Icon'

function QrCode({ text }: { text: string }) {
  const graphic = useMemo(() => {
    try { return createPairingQrGraphic(text) } catch { return null }
  }, [text])
  if (!graphic) return <code className="companion-qr-fallback">{text}</code>
  return (
    <svg className="companion-qr" viewBox={`0 0 ${graphic.size} ${graphic.size}`} role="img" aria-label="Pairing QR code" shapeRendering="crispEdges">
      <rect width={graphic.size} height={graphic.size} fill="#fff" />
      <path d={graphic.path} fill="#000" />
    </svg>
  )
}

const relSeen = (at?: number): string => {
  if (!at) return 'never'
  const s = Math.max(0, Math.round((Date.now() - at) / 1000))
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.round(s / 60)}m ago`
  if (s < 86_400) return `${Math.round(s / 3600)}h ago`
  return `${Math.round(s / 86_400)}d ago`
}

export function CompanionSettings() {
  const [state, setState] = useState<CompanionState | null>(null)
  const [busy, setBusy] = useState(false)
  const [pairing, setPairing] = useState<(CompanionPairingStart & { event?: CompanionPairingEvent }) | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [renaming, setRenaming] = useState<{ id: string; value: string } | null>(null)
  const [updatingDevice, setUpdatingDevice] = useState<string | null>(null)
  const [pairingCodeCopied, setPairingCodeCopied] = useState(false)
  const pairingRef = useRef<string | null>(null)

  useEffect(() => {
    let alive = true
    // Never hang on "Loading…": if main is unreachable, fall back to the safe
    // off state so the pane still renders its explanation and toggle.
    const fallback: CompanionState = { enabled: false, listening: false, status: '', devices: [] }
    bridge.companion.getState().then((s) => { if (alive) setState(s) }).catch(() => { if (alive) setState(fallback) })
    const offState = bridge.companion.onState((s) => setState(s))
    const offPair = bridge.companion.onPairingEvent((event) => {
      if (event.pairingId !== pairingRef.current) return
      setPairing((prev) => (prev ? { ...prev, event } : prev))
      if (event.phase === 'paired' || event.phase === 'expired' || event.phase === 'failed') {
        if (event.phase !== 'paired') setError(event.message ?? `Pairing ${event.phase}.`)
        window.setTimeout(() => { pairingRef.current = null; setPairing(null) }, event.phase === 'paired' ? 900 : 0)
      }
    })
    return () => { alive = false; offState(); offPair() }
  }, [])

  const toggle = async (next: boolean) => {
    setBusy(true); setError(null)
    try { setState(await bridge.companion.setEnabled(next)) }
    catch (e) { setError(e instanceof Error ? e.message : 'Could not change the Companion service.') }
    finally { setBusy(false) }
  }

  const startPairing = async () => {
    setError(null)
    setPairingCodeCopied(false)
    try {
      const started = await bridge.companion.startPairing({ capabilities: ['observe', 'agent-control', 'terminal-control'] })
      pairingRef.current = started.pairingId
      setPairing(started)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not start pairing.')
    }
  }
  const cancelPairing = () => {
    if (pairing) void bridge.companion.cancelPairing(pairing.pairingId).catch(() => {})
    pairingRef.current = null
    setPairing(null)
    setPairingCodeCopied(false)
  }
  const confirmPairing = () => {
    if (pairing) void bridge.companion.confirmPairing(pairing.pairingId).catch(() => {})
  }
  const copyPairingCode = async () => {
    if (!pairing) return
    try {
      await navigator.clipboard.writeText(pairing.qrPayload)
      setPairingCodeCopied(true)
    } catch {
      setError('Could not copy the pairing code. Try scanning it instead.')
    }
  }

  const commitRename = async () => {
    if (!renaming) return
    const { id, value } = renaming
    setRenaming(null)
    try { setState(await bridge.companion.renameDevice(id, value.trim())) } catch { /* keep prior name */ }
  }

  const toggleCapability = async (deviceId: string, capability: 'agent-control' | 'terminal-control', enabled: boolean) => {
    const device = state?.devices.find((candidate) => candidate.deviceId === deviceId)
    if (!device || updatingDevice) return
    if (enabled && capability === 'terminal-control' && !window.confirm(
      'Allow this iPhone to type into existing terminals on this Mac? Every control session still requires device authentication and an expiring lease.',
    )) return
    const capabilities: CompanionState['devices'][number]['capabilities'] = ['observe']
    for (const candidate of ['agent-control', 'terminal-control'] as const) {
      if (candidate === capability ? enabled : device.capabilities.includes(candidate)) capabilities.push(candidate)
    }
    setUpdatingDevice(deviceId)
    setError(null)
    try { setState(await bridge.companion.setDeviceCapabilities(deviceId, capabilities)) }
    catch (e) { setError(e instanceof Error ? e.message : 'Could not update device access.') }
    finally { setUpdatingDevice(null) }
  }

  if (!state) return <p className="settings-note">Loading…</p>

  const devices = state.devices
  const phase = pairing?.event?.phase

  return (
    <>
      <div className="settings-row">
        <span className="settings-row-label">Kaisola Companion</span>
        <div className="settings-row-control">
          <button
            type="button"
            className="settings-toggle"
            role="switch"
            aria-checked={state.enabled}
            aria-label="Kaisola Companion"
            disabled={busy}
            onClick={() => toggle(!state.enabled)}
          >
            <span aria-hidden="true" />
          </button>
        </div>
      </div>
      <p className="settings-note">
        {state.enabled
          ? state.status
          : 'When on, this Mac advertises a private, encrypted service on your local network so a paired iPhone can watch these sessions. Nothing is exposed until a device is paired.'}
      </p>

      {state.enabled && (
        <div className="settings-row companion-remote-row">
          <span className="settings-row-label">Away from this network</span>
          <div className="settings-row-control">
            {state.remote?.available ? (
              <span className="companion-route-ready"><span aria-hidden /> Tailscale ready</span>
            ) : (
              <button type="button" className="btn btn-sm" onClick={() => void bridge.openExternal('https://tailscale.com/download/mac')}>
                Add Tailscale
              </button>
            )}
          </div>
        </div>
      )}
      {state.enabled && !state.remote?.available && (
        <p className="settings-note">Optional and free for personal use. Install Tailscale on this Mac and your iPhone, then open Kaisola once nearby so the phone learns its private route.</p>
      )}

      {error && <p className="settings-note companion-error" role="alert">{error}</p>}

      {state.enabled && (
        <>
          <div className="settings-row">
            <span className="settings-row-label">Paired devices</span>
            <div className="settings-row-control">
              <button type="button" className="btn btn-sm" onClick={startPairing} disabled={!!pairing}>
                <Icon name="Plus" size={13} /> Pair a device
              </button>
            </div>
          </div>

          {devices.length === 0 && !pairing && (
            <p className="settings-note">No devices yet. “Pair a device” shows a QR code to scan with the Kaisola Companion app.</p>
          )}

          <div className="companion-devices">
            {devices.map((d) => (
              <div className="companion-device" key={d.deviceId}>
                <span className="companion-device-dot" data-connected={d.connected || undefined} aria-hidden />
                <div className="companion-device-main">
                  {renaming?.id === d.deviceId ? (
                    <input
                      className="input settings-input-md"
                      autoFocus
                      value={renaming.value}
                      onChange={(e) => setRenaming({ id: d.deviceId, value: e.target.value })}
                      onBlur={commitRename}
                      onKeyDown={(e) => { if (e.key === 'Enter') commitRename(); if (e.key === 'Escape') setRenaming(null) }}
                      aria-label="Device name"
                    />
                  ) : (
                    <button type="button" className="companion-device-name" onClick={() => setRenaming({ id: d.deviceId, value: d.name })}>
                      {d.name}
                    </button>
                  )}
                  <span className="companion-device-meta">
                    {d.connected ? 'Connected' : `Last seen ${relSeen(d.lastSeenAt)}`}
                    {' · '}Encrypted
                  </span>
                  <div className="companion-device-grants" aria-label={`Access for ${d.name}`}>
                    {(['agent-control', 'terminal-control'] as const).map((capability) => {
                      const enabled = d.capabilities.includes(capability)
                      return (
                        <label className="companion-device-grant" key={capability}>
                          <span>{capability === 'agent-control' ? 'Agent control' : 'Terminal control'}</span>
                          <button
                            type="button"
                            className="settings-toggle"
                            role="switch"
                            aria-checked={enabled}
                            aria-label={`${capability === 'agent-control' ? 'Agent control' : 'Terminal control'} for ${d.name}`}
                            disabled={updatingDevice === d.deviceId}
                            onClick={() => void toggleCapability(d.deviceId, capability, !enabled)}
                          >
                            <span aria-hidden="true" />
                          </button>
                        </label>
                      )
                    })}
                  </div>
                </div>
                <button type="button" className="btn btn-sm btn-danger" onClick={() => bridge.companion.revokeDevice(d.deviceId).then(setState).catch(() => {})}>
                  Revoke
                </button>
              </div>
            ))}
          </div>

          <p className="settings-note companion-warning">
            <Icon name="ShieldAlert" size={13} />
            Paired devices can message agents and request short terminal-control leases by default. Terminal typing still requires device authentication; access can be narrowed here at any time.
          </p>
        </>
      )}

      {pairing && (
        <div className="companion-pair-sheet" role="dialog" aria-label="Pair a device">
          <div className="companion-pair-card">
            {phase === 'confirm' ? (
              <>
                <h3 className="companion-pair-title">Confirm the phrase</h3>
                <p className="settings-note">Both screens should show the same four words. Confirm only if they match.</p>
                <div className="companion-sas">{pairing.event?.sas}</div>
                <div className="companion-pair-actions">
                  <button type="button" className="btn" onClick={cancelPairing}>They differ — cancel</button>
                  <button type="button" className="btn btn-primary" onClick={confirmPairing}>They match</button>
                </div>
              </>
            ) : phase === 'paired' ? (
              <>
                <h3 className="companion-pair-title">Paired</h3>
                <p className="settings-note">{pairing.event?.deviceName ?? 'Your iPhone'} can now watch these sessions.</p>
              </>
            ) : (
              <>
                <h3 className="companion-pair-title">Pair with Kaisola Companion</h3>
                <p className="settings-note">Scan this code, or tap “Find my Mac” on an iPhone signed in to the same account. It expires shortly{state.remote?.available ? ' and includes your private Tailscale route' : ''}.</p>
                <QrCode text={pairing.qrPayload} />
                <div className="companion-pair-actions">
                  <button type="button" className="btn" onClick={copyPairingCode}>
                    {pairingCodeCopied ? 'Copied' : 'Copy code'}
                  </button>
                  <button type="button" className="btn" onClick={cancelPairing}>Cancel</button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </>
  )
}
