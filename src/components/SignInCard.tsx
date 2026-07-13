import { useEffect, useRef, useState } from 'react'
import { useKaisola } from '../store/store'
import { bridge, type AuthEvent } from '../lib/bridge'
import { Icon } from './Icon'
import { useModalFocus } from '../lib/useModalFocus'

/**
 * In-app device-code sign-in. Runs the CLI's device-auth headlessly and shows
 * the URL + one-time code as an interactive card (no terminal): open the page,
 * sign in, enter the code, done.
 */
export function SignInCard() {
  const signIn = useKaisola((s) => s.signIn)
  const close = useKaisola((s) => s.closeSignIn)
  const [ev, setEv] = useState<AuthEvent | null>(null)
  const [copied, setCopied] = useState(false)
  const idRef = useRef<string | null>(null)
  const dialogRef = useRef<HTMLDivElement>(null)
  useModalFocus(!!signIn, dialogRef)

  useEffect(() => {
    if (!signIn) return
    setEv({ phase: 'progress' })
    setCopied(false)
    idRef.current = bridge.auth.start(signIn.command, signIn.args, (e) => setEv(e))
    return () => {
      if (idRef.current) bridge.auth.cancel(idRef.current)
      idRef.current = null
    }
  }, [signIn])

  useEffect(() => {
    if (!signIn) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close()
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [signIn, close])

  // auto-close shortly after a successful sign-in
  useEffect(() => {
    if (ev?.phase !== 'done') return
    const t = setTimeout(close, 1300)
    return () => clearTimeout(t)
  }, [ev?.phase, close])

  if (!signIn) return null
  const phase = ev?.phase ?? 'progress'

  return (
    <div className="focus-scrim" onMouseDown={close}>
      <div ref={dialogRef} className="signin-card" role="dialog" aria-modal="true" aria-labelledby="signin-title" tabIndex={-1} onMouseDown={(e) => e.stopPropagation()}>
        <header className="focus-head">
          <Icon name="KeyRound" size={14} className="muted" />
          <span className="grow" id="signin-title">Sign in to {signIn.name}</span>
          <button className="btn-icon btn-sm" onClick={close} aria-label="Close sign in"><Icon name="X" size={14} /></button>
        </header>

        <div className="signin-body">
          {phase === 'done' ? (
            <div className="signin-done">
              <Icon name="CircleCheck" size={28} />
              <div className="signin-state">Signed in.</div>
              <div className="faint">You can Connect now.</div>
              <button className="btn btn-primary btn-sm" onClick={close}>Done</button>
            </div>
          ) : phase === 'failed' ? (
            <div className="signin-done">
              <Icon name="CircleX" size={28} style={{ color: 'var(--danger)' }} />
              <div className="signin-state">Couldn’t sign in.</div>
              {(ev?.error || ev?.tail) && <div className="faint signin-tail">{ev?.error || ev?.tail}</div>}
              <button className="btn btn-sm" onClick={close}>Close</button>
            </div>
          ) : (
            <>
              <p className="signin-instr">
                {ev?.code
                  ? 'Open the authorization page, sign in, and enter the one-time code.'
                  : 'Open the authorization page and sign in — this card completes on its own.'}
              </p>

              <button
                className="btn btn-primary signin-open"
                disabled={!ev?.url}
                onClick={() => ev?.url && bridge.openExternal(ev.url)}
              >
                {ev?.url ? <><Icon name="ExternalLink" size={14} /> Open authorization page</> : <><Icon name="LoaderCircle" size={14} className="spin" /> Starting…</>}
              </button>

              {ev?.code && (
                <div className="signin-code-row">
                  <span className="caps">One-time code</span>
                  <button
                    className="signin-code mono"
                    title="Copy"
                    onClick={() => { navigator.clipboard?.writeText(ev.code!); setCopied(true) }}
                  >
                    {ev.code} <Icon name={copied ? 'Check' : 'Copy'} size={13} />
                  </button>
                </div>
              )}

              <div className="signin-waiting faint">
                <Icon name="LoaderCircle" size={13} className="spin" /> Waiting for you to authorize…
              </div>
              {ev?.url && <button className="signin-link mono faint" onClick={() => bridge.openExternal(ev.url!)}>{ev.url}</button>}

              <button className="btn btn-ghost btn-sm signin-cancel" onClick={close}>Cancel</button>
            </>
          )}
        </div>
      </div>
    </div>
  )
}
