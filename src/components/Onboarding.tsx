import { useEffect, useMemo, useRef, useState } from 'react'
import { bridge, type AppAuthStatus } from '../lib/bridge'
import { useKaisola } from '../store/store'
import { GoogleIcon } from './ProviderIcon'
import { Icon } from './Icon'
import { useModalFocus } from '../lib/useModalFocus'

const firstName = (status: AppAuthStatus | null) =>
  status?.profile?.name?.trim().split(/\s+/)[0] || status?.profile?.email?.split('@')[0] || ''

/** A first-run gate only. Store migration marks every existing installation as
 * complete, so an update never reopens onboarding over restored projects. */
export function Onboarding() {
  const version = useKaisola((s) => s.onboardingVersion)
  const complete = useKaisola((s) => s.completeOnboarding)
  const setWorkspace = useKaisola((s) => s.setWorkspace)
  const [step, setStep] = useState<'welcome' | 'workspace'>('welcome')
  const [status, setStatus] = useState<AppAuthStatus | null>(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const dialogRef = useRef<HTMLDivElement>(null)
  useModalFocus(version <= 0 && !bridge.smoke, dialogRef)

  useEffect(() => {
    if (version > 0 || bridge.smoke) return
    let alive = true
    void bridge.appAuth.status()
      .then((next) => { if (alive) setStatus(next) })
      .catch(() => { if (alive) setMessage('Account status is unavailable. You can continue locally.') })
    const off = bridge.appAuth.onChanged((next) => {
      if (!alive) return
      setStatus(next)
      setBusy(false)
      if (next.ok && next.profile) { setMessage(''); setStep('workspace') }
      else if (next.message) setMessage(next.message)
    })
    return () => { alive = false; off() }
  }, [version])

  const greeting = useMemo(() => firstName(status), [status])
  if (version > 0 || bridge.smoke) return null

  const signIn = async () => {
    setBusy(true); setMessage('')
    try {
      const next = await bridge.appAuth.signInGoogle()
      setStatus((current) => ({ ...(current ?? { configured: next.configured }), ...next }))
      if (!next.ok) { setBusy(false); setMessage(next.message ?? 'Google sign-in could not start.') }
    } catch (error) {
      setBusy(false)
      setMessage(String((error as Error)?.message ?? 'Google sign-in could not start.'))
    }
  }
  const cancelSignIn = async (announce = true) => {
    setBusy(false)
    try { await bridge.appAuth.cancelGoogle() } catch { /* the local path stays available */ }
    if (announce) setMessage('Google sign-in cancelled. You can continue locally.')
  }
  const continueLocally = () => {
    if (busy) void cancelSignIn(false)
    setBusy(false)
    setMessage('')
    setStep('workspace')
  }
  const openFolder = async () => {
    setBusy(true); setMessage('')
    try {
      const result = await bridge.pickFolder()
      if (!result.ok || !result.path) {
        if (result.message) setMessage(result.message)
        return
      }
      setWorkspace(result.path)
      complete()
    } catch (error) {
      setMessage(String((error as Error)?.message ?? 'The folder picker could not open.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div ref={dialogRef} className="onboarding" role="dialog" aria-modal="true" aria-labelledby="onboarding-title" tabIndex={-1}>
      <div className="onboarding-card">
        <div className="onboarding-mark"><Icon name="Layers3" size={18} /></div>
        {step === 'welcome' ? (
          <>
            <div className="onboarding-kicker">Kaisola</div>
            <h1 id="onboarding-title">Your work stays yours.</h1>
            <p className="onboarding-copy">Files, agents, and terminals in one fast workspace. Sessions and drafts recover from disk after every restart.</p>
            <div className="onboarding-actions">
              {status?.configured !== false && <button className="onboarding-google" onClick={() => { void (busy ? cancelSignIn() : signIn()) }}>
                {busy ? <Icon name="LoaderCircle" className="spin" size={17} /> : <GoogleIcon size={17} />}
                {busy ? 'Cancel Google sign-in' : 'Continue with Google'}
              </button>}
              <button className={status?.configured === false ? 'onboarding-google' : 'onboarding-local'} onClick={continueLocally}>Continue locally</button>
            </div>
            {status?.configured === false && <p className="onboarding-note">Google sign-in is unavailable in this build. Local mode keeps your projects and sessions on this Mac.</p>}
            {message && <p className="onboarding-error" role="status" aria-live="polite">{message}</p>}
          </>
        ) : (
          <>
            <div className="onboarding-kicker">{greeting ? `Welcome, ${greeting}` : 'One last step'}</div>
            <h1 id="onboarding-title">Open where you work.</h1>
            <p className="onboarding-copy">Choose a project folder now, or start empty and add one whenever you are ready.</p>
            <div className="onboarding-actions">
              <button className="onboarding-google" disabled={busy} onClick={() => { void openFolder() }}>
                {busy ? <Icon name="LoaderCircle" className="spin" size={17} /> : <Icon name="FolderOpen" size={17} />}
                Open a project
              </button>
              <button className="onboarding-local" disabled={busy} onClick={complete}>Start empty</button>
            </div>
            {message && <p className="onboarding-error" role="status" aria-live="polite">{message}</p>}
            {status?.profile?.email && <div className="onboarding-account"><GoogleIcon size={13} /> {status.profile.email}</div>}
          </>
        )}
      </div>
    </div>
  )
}
