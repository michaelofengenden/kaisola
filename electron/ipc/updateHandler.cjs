// In-app software updates — electron-updater against the public GitHub
// releases feed (build.publish in package.json). CI uploads latest-mac.yml
// next to the dmg/zip on every v* tag; the app checks that file, downloads
// the zip in the background, and installs on restart.
//
// macOS requirement: the downloaded build's code signature must validate, so
// updates only work between Developer-ID-signed releases (the CI secrets
// path). Ad-hoc-signed local builds can check but will fail to install.
const { app, BrowserWindow } = require('electron')

const CHECK_EVERY_MS = 60 * 60 * 1000 // startup + hourly (a tiny yml GET)
const FIRST_CHECK_DELAY_MS = 15 * 1000 // let the shell boot first
// re-focusing the app also checks (releases ship many times a day; a user
// coming back should find the pill waiting, never need the Settings button) —
// rate-limited so cmd-tabbing around doesn't hammer the feed
const FOCUS_CHECK_MIN_MS = 15 * 60 * 1000

/** The single source of truth the renderer mirrors (late subscribers pull it). */
let state = { type: 'idle', version: null, percent: 0, message: null, appVersion: app.getVersion() }

function broadcast() {
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.webContents.isDestroyed()) w.webContents.send('update:event', state)
  }
}
function setState(patch) {
  state = { ...state, ...patch }
  broadcast()
}

function registerUpdateHandlers(ipcMain) {
  ipcMain.handle('update:state', () => state)

  // dev / smoke runs aren't packaged — expose inert handlers so the renderer
  // UI can render its "updates apply to installed builds" state without special-casing
  if (!app.isPackaged) {
    ipcMain.handle('update:check', () => ({ ok: false, message: 'Updates apply to the installed app, not dev builds.' }))
    ipcMain.handle('update:install', () => ({ ok: false }))
    return
  }

  const { autoUpdater } = require('electron-updater')
  autoUpdater.autoDownload = true
  // even if the user never clicks "Restart to update", the next quit applies it
  autoUpdater.autoInstallOnAppQuit = true

  // while probe() quietly re-reads the feed behind a ready build, the
  // checking/available events must not flicker the renderer's "Restart" pill
  let probing = false
  autoUpdater.on('checking-for-update', () => { if (!probing) setState({ type: 'checking', message: null }) })
  autoUpdater.on('update-available', (info) => { if (!probing) setState({ type: 'downloading', version: info.version, percent: 0 }) })
  autoUpdater.on('update-not-available', () => { if (!probing) setState({ type: 'idle', version: null, percent: 0 }) })
  autoUpdater.on('download-progress', (p) => { if (!probing) setState({ type: 'downloading', percent: Math.round(p.percent) }) })
  autoUpdater.on('update-downloaded', (info) => setState({ type: 'ready', version: info.version, percent: 100 }))
  autoUpdater.on('error', (err) => { if (!probing) setState({ type: 'error', message: err?.message ?? String(err) }) })

  let lastCheckAt = 0
  const check = async () => {
    lastCheckAt = Date.now()
    try {
      await autoUpdater.checkForUpdates()
      return { ok: true }
    } catch (err) {
      // offline is the common case — record it quietly, never a dialog
      setState({ type: 'error', message: err?.message ?? String(err) })
      return { ok: false, message: err?.message ?? String(err) }
    }
  }
  // a check already in flight or downloading needs no re-check. 'ready' is NOT
  // busy anymore: a downloaded build waiting for a restart used to block all
  // further checks, so a user who didn't restart for a few releases installed
  // a stale build and had to download+restart AGAIN for each hop. While ready,
  // probe() keeps watching the feed and swaps the pending download for the
  // newest release, so one restart always lands on latest.
  const busy = () => state.type === 'checking' || state.type === 'downloading'

  const newer = (a, b) => {
    // semver-ish compare, enough for x.y.z tags
    const pa = String(a).split('.').map((n) => parseInt(n, 10) || 0)
    const pb = String(b).split('.').map((n) => parseInt(n, 10) || 0)
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) > (pb[i] ?? 0)
    }
    return false
  }
  const probe = async () => {
    // feed-only look while a build sits ready: autoDownload off so the same
    // pending version isn't re-fetched every hour; state is restored unless a
    // strictly newer release shows up (then the normal download path runs and
    // 'ready' re-broadcasts with the new version).
    lastCheckAt = Date.now()
    const pendingVersion = state.version ?? state.appVersion
    probing = true
    autoUpdater.autoDownload = false
    try {
      const r = await autoUpdater.checkForUpdates()
      const v = r?.updateInfo?.version
      if (v && newer(v, pendingVersion)) {
        probing = false
        autoUpdater.autoDownload = true
        setState({ type: 'downloading', version: v, percent: 0 })
        await autoUpdater.downloadUpdate() // replaces the pending build; 'update-downloaded' re-arms 'ready'
      }
    } catch { /* offline etc. — the pending build is still fine */ }
    finally {
      probing = false
      autoUpdater.autoDownload = true
    }
    return { ok: true }
  }
  const recheck = () => (state.type === 'ready' ? probe() : busy() ? Promise.resolve({ ok: true }) : check())

  ipcMain.handle('update:check', () => recheck())
  ipcMain.handle('update:install', async () => {
    // rapid-release guard: releases ship minutes apart some days, and
    // quitAndInstall applies the last COMPLETED download — a pill clicked
    // late used to land one release behind and immediately grow a new pill
    // (update → restart → update again, one hop per release). Give the feed
    // one last look and swap in anything newer BEFORE restarting; the state
    // broadcasts keep the pill honest ("Downloading…") while it swaps.
    try {
      if (state.type === 'ready') await probe()
      const started = Date.now()
      while (state.type === 'downloading' && Date.now() - started < 180_000) {
        await new Promise((r) => setTimeout(r, 250))
      }
    } catch { /* offline etc. — the already-downloaded build is still fine */ }
    // before-quit (pty teardown etc.) still runs — quitAndInstall goes
    // through the normal quit path, then relaunches into the new build
    setImmediate(() => autoUpdater.quitAndInstall())
    return { ok: true }
  })

  setTimeout(() => void check(), FIRST_CHECK_DELAY_MS)
  setInterval(() => { if (!busy()) void recheck() }, CHECK_EVERY_MS)
  app.on('browser-window-focus', () => {
    if (busy() || Date.now() - lastCheckAt < FOCUS_CHECK_MIN_MS) return
    void recheck()
  })
}

module.exports = { registerUpdateHandlers }
