// Glass parity probe — captures the renderer's own output (capturePage: the
// pre-OS-composite pixels, exactly what backdrop-filter/wash changes touch)
// and prints per-channel means for the chrome regions (tab strip + rail).
// Used to gate the blur→painted-wash swap: means must match within ≤2/255.
//
//   npx electron electron/glassprobe.cjs before   → writes glass-before.png + means
//   npx electron electron/glassprobe.cjs after    → writes glass-after.png + means
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
const tag = process.argv.find((a) => /^(before|after)$/.test(a)) || 'before'
const OUT_DIR = process.env.GLASSPROBE_OUT || os.tmpdir()
app.setPath('userData', path.join(os.tmpdir(), 'kaisola-glassprobe'))
try { fsx.rmSync(app.getPath('userData'), { recursive: true, force: true }) } catch { /* fresh */ }

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

function meanOf(img, rect, scale) {
  const crop = img.crop({
    x: Math.round(rect.x * scale), y: Math.round(rect.y * scale),
    width: Math.max(1, Math.round(rect.w * scale)), height: Math.max(1, Math.round(rect.h * scale)),
  })
  const buf = crop.toBitmap() // BGRA
  let b = 0, g = 0, r = 0, a = 0
  const n = buf.length / 4
  for (let i = 0; i < buf.length; i += 4) { b += buf[i]; g += buf[i + 1]; r += buf[i + 2]; a += buf[i + 3] }
  return [r / n, g / n, b / n, a / n].map((v) => Math.round(v * 10) / 10)
}

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))

  const win = new BrowserWindow({
    show: true, width: 1280, height: 800, frame: false,
    transparent: true, backgroundColor: '#00000000',
    vibrancy: 'under-window', visualEffectState: 'active',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, nodeIntegration: false, sandbox: false, webviewTag: true, plugins: true,
      // capture probe: keep producing frames even when occluded — otherwise
      // capturePage returns stale pre-theme-switch pixels (and rAF waits hang)
      backgroundThrottling: false,
    },
  })
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  await wait(1600)
  await js(`window.__kaisola.getState().setLayoutMode('studio')`)
  await wait(500)
  const rects = await js(`(() => {
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height } }
    return { tabstrip: r(document.querySelector('.tabstrip')), rail: r(document.querySelector('.wsrail')) }
  })()`)
  if (!rects.tabstrip || !rects.rail) { console.log('GLASSPROBE=FAIL missing chrome elements ' + JSON.stringify(rects)); app.exit(1); return }
  // clean patches: chrome regions with no foreground ink, so the means read
  // the wash itself (tab strip right of the tabs; rail's empty bottom)
  const ts = rects.tabstrip, rl = rects.rail
  const patches = {
    tabstrip: ts,
    rail: rl,
    tabstripClean: { x: ts.x + ts.w * 0.62, y: ts.y + 8, w: ts.w * 0.3, h: ts.h - 16 },
    railClean: { x: rl.x + 8, y: rl.y + rl.h * 0.78, w: rl.w - 16, h: rl.h * 0.18 },
  }
  const out = {}
  for (const theme of ['light', 'dark']) {
    const applied = await js(`(() => { window.__kaisola.getState().setThemeMode('${theme}'); return document.documentElement.dataset.theme })()`)
    // an occluded window throttles rAF forever (a rAF-wait here HANGS) and
    // capturePage happily returns a stale frame — invalidate() forces real
    // repaints, and the giant-kernel blur build needs a beat to re-raster
    win.webContents.invalidate()
    await wait(900)
    win.webContents.invalidate()
    await wait(900)
    console.log(`THEME_APPLIED=${theme}->${applied}`)
    const img = await win.webContents.capturePage()
    const scale = img.getSize().width / 1280
    out[theme] = Object.fromEntries(Object.entries(patches).map(([k, r]) => [k, meanOf(img, r, scale)]))
    fsx.writeFileSync(path.join(OUT_DIR, `glass-${tag}-${theme}.png`), img.toPNG())
  }
  console.log(`CHROME_MEAN_${tag.toUpperCase()}=` + JSON.stringify(out))
  app.exit(0)
})
