import { useEffect, useMemo, useState } from 'react'
import { bridge, type AppAuthStatus } from '../lib/bridge'
import { useKaisola } from '../store/store'
import { GoogleIcon } from './ProviderIcon'
import { Icon } from './Icon'

const firstName = (status: AppAuthStatus | null) =>
  status?.profile?.name?.trim().split(/\s+/)[0] || status?.profile?.email?.split('@')[0] || ''

/** A first-run gate only. Store migration marks every existing installation as
 * complete, so upgrades never interrupt restored terminals or projects. */
export function Onboarding() {
  const version = useKaisola((s) => s.onboardingVersion)
  const complete = useKaisola((s) => s.completeOnboarding)
  const setWorkspace = useKaisola((s) => s.setWorkspace)
  const [step, setStep] = useState<'welcome' | 'workspace'>('welcome')
  const [status, setStatus] = useState<AppAuthStatus | null>(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  useEffect(() => {
    if (version > 0 || bridge.smoke) return
    let alive = true
    void bridge.appAuth.status().then((next) => { if (alive) setStatus(next) })
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
    const next = await bridge.appAuth.signInGoogle()
    setStatus((current) => ({ ...(current ?? { configured: next.configured }), ...next }))
    if (!next.ok) { setBusy(false); setMessage(next.message ?? 'Google sign-in could not start.') }
  }
  const openFolder = async () => {
    setBusy(true)
    const result = await bridge.pickFolder()
    setBusy(false)
    if (!result.ok || !result.path) return
    setWorkspace(result.path)
    complete()
  }

  return (
    <div className="onboarding" role="dialog" aria-modal="true" aria-label="Welcome to Kaisola">
      <div className="onboarding-card">
        <div className="onboarding-mark"><Icon name="Layers3" size={18} /></div>
        {step === 'welcome' ? (
          <>
            <div className="onboarding-kicker">Kaisola</div>
            <h1>Your work stays yours.</h1>
            <p className="onboarding-copy">Files, agents, and terminals in one fast workspace. Sessions and drafts recover from disk after every restart.</p>
            <div className="onboarding-actions">
              <button className="onboarding-google" disabled={busy || status?.configured === false} onClick={() => { void signIn() }}>
                {busy ? <Icon name="LoaderCircle" className="spin" size={17} /> : <GoogleIcon size={17} />}
                Continue with Google
              </button>
              <button className="onboarding-local" disabled={busy} onClick={() => setStep('workspace')}>Continue locally</button>
            </div>
            {status?.configured === false && <p className="onboarding-note">{status.message || 'Google sign-in is ready in the app and will unlock when this build is linked to Kaisola’s Desktop OAuth client.'}</p>}
            {message && <p className="onboarding-error">{message}</p>}
          </>
        ) : (
          <>
            <div className="onboarding-kicker">{greeting ? `Welcome, ${greeting}` : 'One last step'}</div>
            <h1>Open where you work.</h1>
            <p className="onboarding-copy">Choose a project folder now, or start empty and add one whenever you are ready.</p>
            <div className="onboarding-actions">
              <button className="onboarding-google" disabled={busy} onClick={() => { void openFolder() }}>
                {busy ? <Icon name="LoaderCircle" className="spin" size={17} /> : <Icon name="FolderOpen" size={17} />}
                Open a project
              </button>
              <button className="onboarding-local" disabled={busy} onClick={complete}>Start empty</button>
            </div>
            {status?.profile?.email && <div className="onboarding-account"><GoogleIcon size={13} /> {status.profile.email}</div>}
          </>
        )}
      </div>
    </div>
  )
}
