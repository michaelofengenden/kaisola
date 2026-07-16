import { useEffect, useRef, useState } from 'react'
import { useKaisola } from '../../store/store'
import { bridge, isDesktop } from '../../lib/bridge'
import { Icon } from '../Icon'

// Electron's <webview> tag (enabled via webviewTag in main). Guest pages run
// in their own renderer — no node, no preload, real Chromium session.
declare module 'react' {
  namespace JSX {
    interface IntrinsicElements {
      webview: React.DetailedHTMLProps<React.HTMLAttributes<HTMLElement>, HTMLElement> & {
        src?: string
        partition?: string
      }
    }
  }
}

interface WebviewEl extends HTMLElement {
  loadURL(url: string): Promise<void>
  getURL(): string
  goBack(): void
  goForward(): void
  canGoBack(): boolean
  canGoForward(): boolean
  reload(): void
  stop(): void
  openDevTools(): void
  isDevToolsOpened(): boolean
  closeDevTools(): void
  getWebContentsId(): number
}

/** "localhost:3000" → http://…; bare domains → https://…; URLs pass through. */
function normalizeUrl(input: string): string | null {
  const t = input.trim()
  if (!t) return null
  if (/^https?:\/\//i.test(t)) return t
  if (/^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?(\/|$)/i.test(t)) return `http://${t}`
  if (/^[\w.-]+\.[a-z]{2,}(:\d+)?(\/|$)/i.test(t)) return `https://${t}`
  return `http://${t}`
}

/**
 * A real browser as a session card (Kairn's WKWebView-session idea): the
 * dev-server preview lives BESIDE the terminal that runs it. URL bar,
 * back/forward, and the Web Inspector — nothing more.
 */
export function BrowserCard({ id }: { id: string }) {
  const panel = useKaisola((s) => s.panels.find((p) => p.id === id))
  const setPanelState = useKaisola((s) => s.setPanelState)
  const viewRef = useRef<WebviewEl | null>(null)
  const [input, setInput] = useState(panel?.url ?? '')
  const [nav, setNav] = useState({ back: false, fwd: false, loading: false })
  const lastSeq = useRef(panel?.seq ?? 0)
  // the webview's src is set ONCE (first url) — every later load goes through
  // loadURL so navigation history survives re-renders
  const [bootUrl, setBootUrl] = useState(panel?.url)

  // wire webview lifecycle → URL bar, nav state, persisted url/title
  useEffect(() => {
    const view = viewRef.current
    if (!view) return
    const syncNav = () => setNav((n) => ({ ...n, back: view.canGoBack(), fwd: view.canGoForward() }))
    const onNavigate = (e: Event & { url?: string }) => {
      if (e.url) {
        setInput(e.url)
        setPanelState(id, { url: e.url })
      }
      syncNav()
    }
    const onTitle = (e: Event & { title?: string }) => {
      if (e.title) setPanelState(id, { title: e.title })
    }
    const onStart = () => setNav((n) => ({ ...n, loading: true }))
    const onStop = () => {
      setNav((n) => ({ ...n, loading: false }))
      syncNav()
    }
    view.addEventListener('did-navigate', onNavigate as EventListener)
    view.addEventListener('did-navigate-in-page', onNavigate as EventListener)
    view.addEventListener('page-title-updated', onTitle as EventListener)
    view.addEventListener('did-start-loading', onStart)
    view.addEventListener('did-stop-loading', onStop)
    return () => {
      view.removeEventListener('did-navigate', onNavigate as EventListener)
      view.removeEventListener('did-navigate-in-page', onNavigate as EventListener)
      view.removeEventListener('page-title-updated', onTitle as EventListener)
      view.removeEventListener('did-start-loading', onStart)
      view.removeEventListener('did-stop-loading', onStop)
      try {
        const guestId = view.getWebContentsId()
        if (Number.isInteger(guestId)) void bridge.browser?.releaseGuest(guestId).catch(() => {})
      } catch { /* guest may already be gone during window teardown */ }
    }
    // bootUrl: the webview mounts only once a url exists — re-wire then
  }, [id, setPanelState, bootUrl])

  // a terminal link re-pointed this card (seq bump) → navigate in place
  useEffect(() => {
    if (panel?.seq === undefined || panel.seq === lastSeq.current) return
    lastSeq.current = panel.seq
    if (!panel.url) return
    setInput(panel.url)
    const view = viewRef.current
    if (view) void view.loadURL(panel.url).catch(() => {})
    else setBootUrl(panel.url)
  }, [panel?.seq, panel?.url])

  if (!isDesktop) return <div className="git-panel git-panel-empty">The browser card runs in the desktop app.</div>

  const go = () => {
    const url = normalizeUrl(input)
    if (!url) return
    setInput(url)
    setPanelState(id, { url })
    const view = viewRef.current
    if (view) void view.loadURL(url).catch(() => {})
    else setBootUrl(url)
  }

  return (
    <div className="web-panel">
      <div className="web-bar">
        <button type="button" className="btn-icon btn-sm" disabled={!nav.back} onClick={() => viewRef.current?.goBack()} title="Back" aria-label="Go back">
          <Icon name="ArrowLeft" size={13} />
        </button>
        <button type="button" className="btn-icon btn-sm" disabled={!nav.fwd} onClick={() => viewRef.current?.goForward()} title="Forward" aria-label="Go forward">
          <Icon name="ArrowRight" size={13} />
        </button>
        <button
          type="button"
          className="btn-icon btn-sm"
          onClick={() => (nav.loading ? viewRef.current?.stop() : viewRef.current?.reload())}
          title={nav.loading ? 'Stop' : 'Reload'}
          aria-label={nav.loading ? 'Stop loading' : 'Reload page'}
        >
          <Icon name={nav.loading ? 'X' : 'RotateCw'} size={12} />
        </button>
        <input
          className="web-url"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') go() }}
          onFocus={(e) => e.currentTarget.select()}
          placeholder="localhost:3000 — or any URL"
          spellCheck={false}
        />
        <button
          type="button"
          className="btn-icon btn-sm"
          onClick={() => viewRef.current?.openDevTools()}
          title="Web Inspector"
          aria-label="Open Web Inspector"
        >
          <Icon name="Code" size={13} />
        </button>
        <button
          type="button"
          className="btn-icon btn-sm"
          onClick={() => { if (panel?.url) void bridge.openExternal(panel.url) }}
          title="Open in your browser"
          aria-label="Open in your browser"
        >
          <Icon name="ExternalLink" size={13} />
        </button>
      </div>
      {bootUrl ? (
        <webview
          ref={(el: HTMLElement | null) => { viewRef.current = el as WebviewEl | null }}
          className="web-view"
          src={bootUrl}
          partition="persist:browser"
        />
      ) : (
        <div className="web-empty">
          <Icon name="Compass" size={20} className="muted" />
          <span>Enter a URL above — dev servers live here, beside their terminal.</span>
        </div>
      )}
    </div>
  )
}
