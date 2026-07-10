// Solid-window Eco probe. Boots dist with isolated opaque-window prefs, then
// verifies pure-white Eco surfaces, no wallpaper raster/backdrop compositor,
// native clipping, and write-through when switching back to Live Glass.
const { app, BrowserWindow, ipcMain } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fsx = require('node:fs')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers } = require('./ipc/terminalHandler.cjs')
const { registerAcpHandlers } = require('./ipc/acpHandler.cjs')
const { registerAuthHandlers } = require('./ipc/authHandler.cjs')
const { registerFsHandlers } = require('./ipc/fsHandler.cjs')
const { registerGrobidHandlers } = require('./ipc/grobidHandler.cjs')
const { registerSandboxHandlers } = require('./ipc/sandboxHandler.cjs')
const { registerDbHandlers } = require('./ipc/dbHandler.cjs')
const { registerCodexHandlers } = require('./ipc/codexHandler.cjs')
const { registerGitHandlers } = require('./ipc/gitHandler.cjs')
const { registerClaudeHooksHandlers } = require('./ipc/claudeHooksHandler.cjs')
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const worktree = require('./ipc/worktreeHandler.cjs')

process.env.KAISOLA_SMOKE = '1'
const USER_DATA = path.join(os.tmpdir(), 'kaisola-solidprobe')
try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch { /* fresh */ }
fsx.mkdirSync(USER_DATA, { recursive: true })
app.setPath('userData', USER_DATA)
const PREFS = path.join(USER_DATA, 'shell-prefs.json')
fsx.writeFileSync(PREFS, JSON.stringify({ solidWindow: true, solidBg: '#ffffff' }))
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('glass:sample', () => ({ ok: false }))
  ipcMain.handle('mcp:info', () => ({ ok: false }))
  ipcMain.handle('mcp:servers', () => [])
  ipcMain.handle('mcp:discover', () => [])
  ipcMain.handle('extensions:state', () => ({ installed: [], available: [] }))
  const readPrefs = () => { try { return JSON.parse(fsx.readFileSync(PREFS, 'utf8')) } catch { return {} } }
  ipcMain.handle('shell:window-mode', (_event, patch) => {
    const current = readPrefs()
    if (typeof patch?.solidWindow === 'boolean') current.solidWindow = patch.solidWindow
    if (typeof patch?.solidBg === 'string' && /^#[0-9a-fA-F]{6}$/.test(patch.solidBg)) current.solidBg = patch.solidBg
    fsx.writeFileSync(PREFS, JSON.stringify(current))
    return { wantSolid: current.solidWindow === true, liveSolid: true }
  })

  const win = new BrowserWindow({
    show: true, width: 1280, height: 800, frame: false,
    transparent: false, backgroundColor: '#ffffff',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true,
      nodeIntegration: false, sandbox: false, webviewTag: true, plugins: true,
      backgroundThrottling: false,
    },
  })
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1' } })
  await wait(1600)
  const boot = await js(`(() => ({ solidwin: document.documentElement.dataset.solidwin, radius: getComputedStyle(document.querySelector('.app')).borderTopLeftRadius }))()`)
  const corner = (await win.webContents.capturePage()).toBitmap().slice(0, 4)
  await js(`window.__kaisola.getState().setThemeMode('light'); window.__kaisola.getState().setPerfMode('eco')`)
  await wait(500)
  const eco = await js(`(() => {
    const app = document.querySelector('.app')
    const canvas = document.querySelector('.canvas-wrap > .canvas')
    const card = document.querySelector('.session-card')
    const rail = document.querySelector('.wsrail')
    const styles = [...document.querySelectorAll('.app *')].map((node) => getComputedStyle(node))
    return {
      perf: document.documentElement.dataset.perf,
      bg0: getComputedStyle(document.documentElement).getPropertyValue('--bg-0').trim(),
      appBg: getComputedStyle(app, '::before').backgroundColor,
      canvasBg: canvas ? getComputedStyle(canvas).backgroundColor : '',
      cardBg: card ? getComputedStyle(card).backgroundColor : '',
      railVeil: rail ? getComputedStyle(rail, '::before').display : '',
      wallpaper: !!document.querySelector('.app-wallpaper'),
      hasBackdropBlur: styles.some((style) => /blur/.test([style.backdropFilter, style.getPropertyValue('-webkit-backdrop-filter')].join(' '))),
    }
  })()`)
  const ecoShot = await win.webContents.capturePage()
  await js(`window.__kaisola.getState().setPerfMode('glass')`)
  await wait(150)
  const prefsAfter = readPrefs()
  const checks = {
    bootSolidwin: boot.solidwin === 'true',
    bootRadius: boot.radius === '10px',
    windowOpaque: corner[3] === 255,
    ecoSelected: eco.perf === 'eco',
    pureWhiteBase: eco.bg0 === '#ffffff' && eco.appBg === 'rgb(255, 255, 255)',
    pureWhiteSurfaces: eco.canvasBg === 'rgb(255, 255, 255)' && (!eco.cardBg || eco.cardBg === 'rgb(255, 255, 255)'),
    noWallpaperRaster: !eco.wallpaper,
    noBackdropBlur: !eco.hasBackdropBlur && (!eco.railVeil || eco.railVeil === 'none'),
    writeThrough: prefsAfter.solidWindow === false,
  }
  const pass = Object.values(checks).every(Boolean)
  console.log('SOLID=' + (pass ? 'PASS' : 'FAIL') + ' ' + JSON.stringify({ ...checks, eco }))
  if (process.env.SOLIDPROBE_OUT) fsx.writeFileSync(path.join(process.env.SOLIDPROBE_OUT, 'eco.png'), ecoShot.toPNG())
  app.exit(pass ? 0 : 1)
})
