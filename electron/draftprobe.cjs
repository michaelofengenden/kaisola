// Draft-survival probe, two launches over one userData:
//   phase 1 — create an agent-singleton terminal (boot contains --resume so
//             the retype arms on relaunch), persist a draft for it, quit.
//   phase 2 — the rehydrated terminal boots; after the pty goes quiet the
//             saved draft must be retyped (cat echoes it into the snapshot).
//   npx electron electron/draftprobe.cjs 1 && npx electron electron/draftprobe.cjs 2
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
const mgr = require('./ipc/terminalManager.cjs')

process.env.KAISOLA_SMOKE = '1'
const phase = process.argv.find((a) => /^[12]$/.test(a)) || '1'
const USER_DATA = path.join(os.tmpdir(), 'kaisola-draftprobe')
if (phase === '1') { try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch { /* fresh */ } }
app.setPath('userData', USER_DATA)

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const DRAFT = 'hello saved draft'

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
    show: true, width: 1100, height: 700, frame: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, nodeIntegration: false, sandbox: false, webviewTag: true, plugins: true,
      backgroundThrottling: false,
    },
  })
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  await wait(1800)

  if (phase === '1') {
    const termId = await js(`(() => {
      const st = window.__kaisola.getState()
      st.requestTerminal('echo --resume marker && cat', { singletonKey: 'agent:probe', restart: true, name: 'Probe' })
      const t = window.__kaisola.getState().terminals.find((x) => x.singletonKey === 'agent:probe')
      return t ? t.id : ''
    })()`)
    if (!termId) { console.log('DRAFT=FAIL no terminal'); app.exit(1); return }
    await wait(4000) // pty spawn + boot typed
    await js(`window.__kaisola.getState().setTermDraft(${JSON.stringify(termId)}, ${JSON.stringify(DRAFT)})`)
    await wait(1600) // persist flush (PERSIST_MS=800)
    console.log('DRAFT_PHASE1=OK term=' + termId)
    app.exit(0)
    return
  }

  // phase 2: rehydrated agent terminal reboots with --resume in its boot line;
  // the retype waits for ≥2s quiescence starting 3s after boot
  await wait(14_000)
  const out = await js(`(() => {
    const st = window.__kaisola.getState()
    const t = st.terminals.find((x) => x.singletonKey === 'agent:probe')
    return { id: t ? t.id : '', draftLeft: t ? st.termDrafts[t.id] ?? null : null }
  })()`)
  if (!out.id) { console.log('DRAFT=FAIL terminal not rehydrated'); app.exit(1); return }
  const snap = mgr.snapshot(out.id)
  const typed = snap.output.includes(DRAFT)
  console.log('DRAFT=' + (typed ? 'PASS' : 'FAIL') + ' ' + JSON.stringify({ typed, draftLeft: out.draftLeft, tail: snap.output.slice(-200).replace(/\s+/g, ' ') }))
  app.exit(typed ? 0 : 1)
})
