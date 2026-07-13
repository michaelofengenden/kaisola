import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { bridge, type AppAuthStatus } from '../../lib/bridge'
import { useKaisola } from '../../store/store'
import { useClickAway } from '../../lib/useClickAway'
import { Icon } from '../Icon'

export function AppAccountButton({ showLabel = false }: { showLabel?: boolean }) {
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  const [status, setStatus] = useState<AppAuthStatus | null>(null)
  const [open, setOpen] = useState(false)
  const [failedAvatarUrl, setFailedAvatarUrl] = useState<string | null>(null)
  const [pos, setPos] = useState<{ left?: number; right?: number; top?: number; bottom?: number }>({ right: 8, top: 42 })
  const button = useRef<HTMLButtonElement>(null)
  const panel = useRef<HTMLDivElement>(null)
  const close = useCallback(() => setOpen(false), [])
  useClickAway(open, close, button, panel)

  useEffect(() => {
    let alive = true
    void bridge.appAuth.status().then((next) => { if (alive) setStatus(next) })
    const off = bridge.appAuth.onChanged((next) => { if (alive) setStatus(next) })
    return () => { alive = false; off() }
  }, [])
  const profile = status?.profile
  if (!profile) return null
  const imageBroken = failedAvatarUrl === profile.avatarUrl
  const initial = (profile.name || profile.email).trim().charAt(0).toUpperCase() || 'U'
  const toggle = () => {
    if (!open) {
      const rect = button.current?.getBoundingClientRect()
      if (rect) {
        const horizontal = rect.left < 280
          ? { left: Math.max(8, rect.left) }
          : { right: Math.max(8, window.innerWidth - rect.right) }
        setPos(rect.bottom > window.innerHeight * 0.62
          ? { ...horizontal, bottom: window.innerHeight - rect.top + 6 }
          : { ...horizontal, top: rect.bottom + 6 })
      }
    }
    setOpen((value) => !value)
  }
  const signOut = async () => {
    setOpen(false)
    setStatus(await bridge.appAuth.signOut())
  }

  return (
    <>
      <button type="button"
        ref={button}
        className="app-account-avatar"
        data-label={showLabel || undefined}
        data-open={open || undefined}
        onClick={toggle}
        title={`${profile.name || profile.email} · Kaisola account`}
        aria-label="Kaisola account"
      >
        {profile.avatarUrl && !imageBroken
          ? <img src={profile.avatarUrl} alt="" referrerPolicy="no-referrer" onError={() => setFailedAvatarUrl(profile.avatarUrl ?? null)} />
          : <span className="app-account-initial">{initial}</span>}
        {showLabel && <span className="app-account-name truncate">{profile.name || profile.email}</span>}
      </button>
      {open && createPortal(
        <>
        {/* Frameless-window drag regions do not always emit document pointer
            events. This no-drag dismiss layer makes click-away deterministic. */}
        <div className="app-account-dismiss" onPointerDown={close} aria-hidden="true" />
        <div ref={panel} className="app-account-menu" style={{ position: 'fixed', ...pos }}>
          <div className="app-account-card">
            <div className="app-account-avatar app-account-avatar-large" aria-hidden>
              {profile.avatarUrl && !imageBroken
                ? <img src={profile.avatarUrl} alt="" referrerPolicy="no-referrer" onError={() => setFailedAvatarUrl(profile.avatarUrl ?? null)} />
                : <span className="app-account-initial">{initial}</span>}
            </div>
            <div className="app-account-copy">
              <strong className="truncate">{profile.name || 'Kaisola account'}</strong>
              <span className="truncate">{profile.email}</span>
              <small data-verified={status?.serverVerified || undefined}>
                {status?.serverVerified ? 'Server verified' : 'Verification pending'}
              </small>
            </div>
          </div>
          <div className="tree-menu-sep" />
          <button type="button" onClick={() => { setOpen(false); openSettings(true, 'usage') }}>
            <Icon name="Gauge" size={13} /> Usage
          </button>
          <button type="button" onClick={() => { setOpen(false); openSettings(true, 'general') }}>
            <Icon name="Settings" size={13} /> Account settings
          </button>
          <button type="button" onClick={() => { void signOut() }}>
            <Icon name="LogOut" size={13} /> Sign out
          </button>
        </div>
        </>,
        document.body,
      )}
    </>
  )
}
