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

  autoUpdater.on('checking-for-update', () => setState({ type: 'checking', message: null }))
  autoUpdater.on('update-available', (info) => setState({ type: 'downloading', version: info.version, percent: 0 }))
  autoUpdater.on('update-not-available', () => setState({ type: 'idle', version: null, percent: 0 }))
  autoUpdater.on('download-progress', (p) => setState({ type: 'downloading', percent: Math.round(p.percent) }))
  autoUpdater.on('update-downloaded', (info) => setState({ type: 'ready', version: info.version, percent: 100 }))
  autoUpdater.on('error', (err) => setState({ type: 'error', message: err?.message ?? String(err) }))

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
  // a check already in flight, downloading, or sitting ready needs no re-check
  const busy = () => state.type === 'checking' || state.type === 'downloading' || state.type === 'ready'

  ipcMain.handle('update:check', () => (busy() ? { ok: true } : check()))
  ipcMain.handle('update:install', () => {
    // before-quit (pty teardown etc.) still runs — quitAndInstall goes
    // through the normal quit path, then relaunches into the new build
    setImmediate(() => autoUpdater.quitAndInstall())
    return { ok: true }
  })

  setTimeout(() => void check(), FIRST_CHECK_DELAY_MS)
  setInterval(() => { if (!busy()) void check() }, CHECK_EVERY_MS)
  app.on('browser-window-focus', () => {
    if (busy() || Date.now() - lastCheckAt < FOCUS_CHECK_MIN_MS) return
    void check()
  })
}

module.exports = { registerUpdateHandlers }
