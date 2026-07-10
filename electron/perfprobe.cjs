// GPU/memory-cost probe — boots the REAL renderer (hardware acceleration ON),
// docks one terminal running a claude-style spinner, and holds still so
// `footprint`, `vmmap`, or `top` can sample the complete Electron process tree.
//
//   npx electron electron/perfprobe.cjs A   → current full glass (baseline)
//   npx electron electron/perfprobe.cjs B   → opaque cards/canvas, window blur kept
//   npx electron electron/perfprobe.cjs C   → B + full-window blur dropped
//   npx electron electron/perfprobe.cjs G   → shipped live-glass mode
//   npx electron electron/perfprobe.cjs P   → shipped painted/solid-window mode
const { app, BrowserWindow, ipcMain } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fsx = require('node:fs')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers, killAllSessions } = require('./ipc/terminalHandler.cjs')
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

process.env.KAISOLA_SMOKE = '1' // no external side effects; meta poller off
const variant = (process.argv.find((a) => /^[ABCGP]$/i.test(a)) || 'A').toUpperCase()
const solidWindow = variant === 'P'
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
    transparent: !solidWindow,
    backgroundColor: solidWindow ? '#f2f1ee' : '#00000000',
    ...(solidWindow ? {} : { vibrancy: 'under-window', visualEffectState: 'active' }),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: true,
      plugins: true,
    },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), solidWindow ? { query: { solidwin: '1' } } : undefined)
  await wait(1200)
  if (variant === 'P' || variant === 'G') {
    await win.webContents.executeJavaScript(`window.__kaisola.setState({ perfMode: ${JSON.stringify(variant === 'P' ? 'painted' : 'glass')} })`, true)
    await wait(600)
  }
  const css = VARIANT_CSS[variant]
  if (css) await win.webContents.insertCSS(css)
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await js(`window.__kaisola.getState().requestTerminal()`)
  await wait(4500) // pty spawn + shell prompt (login shells take a beat)
  const termId = await js(`window.__kaisola.getState().terminals[0]?.id ?? ''`)
  if (termId) {
    // claude-shaped load: a ~10-line block redraw at ~12fps, not a one-cell
    // spinner — the TUI repaints its whole status/composer area per frame
    const spinner = `while :; do printf '\\033[H'; for i in 1 2 3 4 5 6 7 8 9 10; do printf '── streaming line %s %s ──────────────────────\\033[K\\n' "$i" "$RANDOM"; done; sleep 0.08; done\n`
    await js(`window.kaisola.terminal.write(${JSON.stringify(termId)}, ${JSON.stringify(spinner)})`)
  }
  await wait(1500)
  const len1 = termId ? await js(`window.kaisola.terminal.snapshot(${JSON.stringify(termId)}).then((snapshot) => snapshot.output.length)`) : 0
  await wait(1000)
  const len2 = termId ? await js(`window.kaisola.terminal.snapshot(${JSON.stringify(termId)}).then((snapshot) => snapshot.output.length)`) : 0
  console.log(`PROBE_READY variant=${variant} pid=${process.pid} solid=${solidWindow} term=${termId || 'NONE'} spinner=${len2 > len1 ? 'FLOWING' : 'STALLED'} (+${len2 - len1}b/s)`)
  setTimeout(() => {
    killAllSessions() // probes must not leave their broker-owned spinner behind
    setTimeout(() => app.exit(0), 200)
  }, 60_000) // backstop — the driver usually kills us
})
