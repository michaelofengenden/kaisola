// GPU-cost probe — boots the REAL renderer (hardware acceleration ON,
// transparent window + vibrancy like main.cjs), docks one terminal running a
// claude-style spinner, and holds still so `top` can sample the GPU helper.
//
//   npx electron electron/perfprobe.cjs A   → current full glass (baseline)
//   npx electron electron/perfprobe.cjs B   → opaque cards/canvas, window blur kept
//   npx electron electron/perfprobe.cjs C   → B + full-window blur dropped
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
const mgr = require('./ipc/terminalManager.cjs')

process.env.KAISOLA_SMOKE = '1' // no external side effects; meta poller off
const variant = (process.argv.find((a) => /^[ABC]$/.test(a)) || 'A').toUpperCase()
app.setPath('userData', path.join(os.tmpdir(), `kaisola-perfprobe-${variant}`))
try { fsx.rmSync(app.getPath('userData'), { recursive: true, force: true }) } catch { /* fresh */ }

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

const VARIANT_CSS = {
  A: '',
  B: `.session-card, .canvas-wrap > .canvas {
        background: var(--bg-1) !important;
        backdrop-filter: none !important;
        -webkit-backdrop-filter: none !important;
      }`,
  C: `.session-card, .canvas-wrap > .canvas {
        background: var(--bg-1) !important;
        backdrop-filter: none !important;
        -webkit-backdrop-filter: none !important;
      }
      .app::before {
        backdrop-filter: none !important;
        -webkit-backdrop-filter: none !important;
      }`,
}

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))

  const win = new BrowserWindow({
    show: true,
    width: 1280,
    height: 800,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    vibrancy: 'under-window',
    visualEffectState: 'active',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: true,
      plugins: true,
    },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  await wait(1200)
  const css = VARIANT_CSS[variant]
  if (css) await win.webContents.insertCSS(css)
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await js(`window.__kaisola.getState().requestTerminal()`)
  await wait(4500) // pty spawn + shell prompt (login shells take a beat)
  const termId = await js(`window.__kaisola.getState().terminals[0]?.id ?? ''`)
  if (termId) {
    // claude-shaped load: a ~10-line block redraw at ~12fps, not a one-cell
    // spinner — the TUI repaints its whole status/composer area per frame
    mgr.write(termId, `while :; do printf '\\033[H'; for i in 1 2 3 4 5 6 7 8 9 10; do printf '── streaming line %s %s ──────────────────────\\033[K\\n' "$i" "$RANDOM"; done; sleep 0.08; done\n`)
  }
  await wait(1500)
  const len1 = mgr.snapshot(termId).output.length
  await wait(1000)
  const len2 = mgr.snapshot(termId).output.length
  console.log(`PROBE_READY variant=${variant} term=${termId || 'NONE'} spinner=${len2 > len1 ? 'FLOWING' : 'STALLED'} (+${len2 - len1}b/s)`)
  setTimeout(() => app.exit(0), 60_000) // backstop — the driver usually kills us
})
