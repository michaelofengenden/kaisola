// Capture probe for the 4-complaint UI critique pass (top-bar density,
// light vs dark project tabs, Eco chrome, Agents & MCP popover).
// Pattern copied from solidprobe.cjs (isolated userData, full handler set,
// invalidate()+600ms before every capturePage()).
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
const USER_DATA = path.join(os.tmpdir(), 'kaisola-critiqueprobe')
try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch {}
fsx.mkdirSync(USER_DATA, { recursive: true })
app.setPath('userData', USER_DATA)

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const SHOTS = process.argv[2]

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerGlassHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: false, liveSolid: false }))

  const win = new BrowserWindow({
    show: true, width: 1600, height: 1000, frame: false,
    transparent: true, backgroundColor: '#00000000',
    vibrancy: 'under-window', visualEffectState: 'active',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, nodeIntegration: false, sandbox: false, webviewTag: true, plugins: true,
      backgroundThrottling: false,
    },
  })
  const js = (code) => win.webContents.executeJavaScript(code, true)
  const shoot = async (name) => {
    win.webContents.invalidate()
    await wait(600)
    const img = await win.webContents.capturePage()
    fsx.writeFileSync(path.join(SHOTS, `${name}.png`), img.toPNG())
    console.log('shot', name, img.getSize())
  }

  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  await wait(1800)

  await js(`window.__kaisola.getState().setPerfMode('eco')`)
  await wait(500)

  // 4 project tabs total (1 default empty + 3 more) for the tab-strip comparison
  await js(`window.__kaisola.getState().newProject({ path: null, focus: true })`)
  await wait(200)
  await js(`window.__kaisola.getState().newProject({ path: null, focus: true })`)
  await wait(200)
  await js(`window.__kaisola.getState().newProject({ path: null, focus: true })`)
  await wait(300)

  await js(`window.__kaisola.getState().setThemeMode('dark')`)
  await wait(500)
  await shoot('01_topbar_dark_4tabs')

  await js(`window.__kaisola.getState().setThemeMode('light')`)
  await wait(500)
  await shoot('02_topbar_light_4tabs')

  // tools-cluster geometry (for precise crops) in light mode
  const geomLight = await js(`(() => {
    const rect = (sel) => { const el = document.querySelector(sel); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height } }
    return { tabstrip: rect('.tabstrip'), tools: rect('.tabstrip-tools'), track: rect('.tabstrip-track'), activeTab: rect('.ptab[data-active="true"]') }
  })()`)
  fsx.writeFileSync(path.join(SHOTS, 'geom_light.json'), JSON.stringify(geomLight, null, 2))

  await js(`window.__kaisola.getState().setThemeMode('dark')`)
  await wait(400)
  const geomDark = await js(`(() => {
    const rect = (sel) => { const el = document.querySelector(sel); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height } }
    return { tabstrip: rect('.tabstrip'), tools: rect('.tabstrip-tools'), track: rect('.tabstrip-track'), activeTab: rect('.ptab[data-active="true"]') }
  })()`)
  fsx.writeFileSync(path.join(SHOTS, 'geom_dark.json'), JSON.stringify(geomDark, null, 2))

  // Agents & MCP popover — dark
  await js(`(() => {
    const btn = Array.from(document.querySelectorAll('button')).find(b => (b.title||'').startsWith('Agents & MCP'))
    btn && btn.click()
  })()`)
  await wait(700)
  await shoot('03_agents_mcp_popover_dark')

  await js(`(() => {
    const btn = Array.from(document.querySelectorAll('button')).find(b => (b.title||'').startsWith('Agents & MCP'))
    btn && btn.click()
  })()`)
  await wait(200)

  await js(`window.__kaisola.getState().setThemeMode('light')`)
  await wait(400)
  await js(`(() => {
    const btn = Array.from(document.querySelectorAll('button')).find(b => (b.title||'').startsWith('Agents & MCP'))
    btn && btn.click()
  })()`)
  await wait(700)
  await shoot('04_agents_mcp_popover_light')

  console.log('DONE')
  app.exit(0)
})
