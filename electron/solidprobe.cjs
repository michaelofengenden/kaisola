// Solid-window + painted-mode probe. Boots dist with ISOLATED userData whose
// shell-prefs ask for an opaque window (as main.cjs would create after a
// perfMode switch + relaunch), then asserts the whole chain:
//   prefs → opaque window + ?solidwin → data-solidwin + squared corners →
//   setPerfMode writes prefs back → painted mode mounts .app-wallpaper →
//   eco unmounts it.
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
const { registerGlassHandlers } = require('./ipc/glassHandler.cjs')
const worktree = require('./ipc/worktreeHandler.cjs')

process.env.KAISOLA_SMOKE = '1'
const USER_DATA = path.join(os.tmpdir(), 'kaisola-solidprobe')
try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch { /* fresh */ }
fsx.mkdirSync(USER_DATA, { recursive: true })
app.setPath('userData', USER_DATA)
const PREFS = path.join(USER_DATA, 'shell-prefs.json')
fsx.writeFileSync(PREFS, JSON.stringify({ solidWindow: true, solidBg: '#0b0d11' }))

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerGlassHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  // the real shell:window-mode handler lives in main.cjs — replicate its
  // contract against THIS probe's prefs file so setPerfMode's write-through
  // and the mismatch read are exercised end to end
  const readPrefs = () => { try { return JSON.parse(fsx.readFileSync(PREFS, 'utf8')) } catch { return {} } }
  ipcMain.handle('shell:window-mode', (e, patch) => {
    const cur = readPrefs()
    if (patch && typeof patch.solidWindow === 'boolean') cur.solidWindow = patch.solidWindow
    if (patch && typeof patch.solidBg === 'string' && /^#[0-9a-fA-F]{6}$/.test(patch.solidBg)) cur.solidBg = patch.solidBg
    fsx.writeFileSync(PREFS, JSON.stringify(cur))
    return { wantSolid: cur.solidWindow === true, liveSolid: true }
  })

  // mirror main.cjs's creation-time branch for a solid window
  const win = new BrowserWindow({
    show: true, width: 1280, height: 800, frame: false,
    transparent: false, backgroundColor: '#0b0d11',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, nodeIntegration: false, sandbox: false, webviewTag: true, plugins: true,
      backgroundThrottling: false,
    },
  })
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1' } })
  await wait(1800)

  const boot = await js(`(() => ({
    solidwin: document.documentElement.dataset.solidwin,
    radius: getComputedStyle(document.querySelector('.app')).borderTopLeftRadius,
  }))()`)
  const img = await win.webContents.capturePage()
  const corner = img.toBitmap().slice(0, 4) // BGRA of pixel (0,0)
  const opaque = corner[3] === 255

  await js(`window.__kaisola.getState().setPerfMode('painted')`)
  await wait(900)
  win.webContents.invalidate()
  await wait(600)
  const paintedShot = await win.webContents.capturePage()
  const painted = await js(`(() => {
    const el = document.querySelector('.app-wallpaper')
    return {
      perf: document.documentElement.dataset.perf,
      mounted: !!el,
      bg: el ? getComputedStyle(el).backgroundImage.slice(0, 40) : '',
    }
  })()`)

  await js(`window.__kaisola.getState().setPerfMode('eco')`)
  await wait(400)
  const eco = await js(`(() => ({
    perf: document.documentElement.dataset.perf,
    mounted: !!document.querySelector('.app-wallpaper'),
  }))()`)

  await js(`window.__kaisola.getState().setPerfMode('glass')`)
  await wait(400)
  const prefsAfter = readPrefs()

  const checks = {
    bootSolidwin: boot.solidwin === 'true',
    bootRadius: boot.radius === '10px',
    windowOpaque: opaque,
    paintedMounts: painted.perf === 'painted' && painted.mounted,
    paintedHasImage: /data:image\/jpeg|gradient/.test(painted.bg),
    ecoUnmounts: eco.perf === 'eco' && !eco.mounted,
    writeThrough: prefsAfter.solidWindow === false, // glass wants transparent again
  }
  const pass = Object.values(checks).every(Boolean)
  console.log('SOLID=' + (pass ? 'PASS' : 'FAIL') + ' ' + JSON.stringify({ ...checks, painted }))
  if (process.env.SOLIDPROBE_OUT) {
    fsx.writeFileSync(path.join(process.env.SOLIDPROBE_OUT, 'painted.png'), paintedShot.toPNG())
  }
  app.exit(pass ? 0 : 1)
})
