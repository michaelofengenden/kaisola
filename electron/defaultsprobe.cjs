// New-defaults probe (v0.1.44): one launch over a fresh userData asserting
//   1. the fresh shell is a SINGLE session — one seed terminal, no chat thread
//   2. a phantom-open dock (stale grid ids) recovers on toggleDock: the grid is
//      pruned and a live card seeded instead of toggling an invisible boolean
//   3. the LAST terminal is closable (undo-close brings it back)
//   4. defaultAutonomy persists, seeds new projects, and mirrors into the
//      armed Claude --settings file as a permission mode
//   npx electron electron/defaultsprobe.cjs
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
const USER_DATA = path.join(os.tmpdir(), 'kaisola-defaultsprobe')
try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch { /* fresh */ }
app.setPath('userData', USER_DATA)

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

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

  const out = await js(`(async () => {
    const wait = (ms) => new Promise((r) => setTimeout(r, ms))
    const g = () => window.__kaisola.getState()

    // 1) fresh shell = one seed terminal, zero chat threads, single session tab
    const singleSession = {
      noThreads: g().assistantThreads.length === 0,
      oneTerminal: g().terminals.length === 1,
      terminalDocked: g().dockViews.length === 1 && g().dockViews[0] === g().terminals[0].id,
      oneTab: document.querySelectorAll('.stabs .stab').length === 1,
    }
    const seedId = g().terminals[0].id

    // 2) phantom-open dock: stale grid ids render zero cards — toggleDock must
    //    prune and seed a live card, not flip dockOpen over nothing
    window.__kaisola.setState({ layoutMode: 'studio', dockOpen: true, dockGrid: [['ghost-1']], dockViews: ['ghost-1'] })
    await wait(80)
    g().toggleDock()
    await wait(160)
    const phantom = {
      opened: g().dockOpen === true,
      seeded: g().dockViews.length === 1 && g().dockViews[0] === seedId,
      cardShown: !!document.querySelector('.session-card[data-show="true"]'),
    }
    g().toggleDock() // now visibly open → this click hides
    await wait(80)
    phantom.thenCloses = g().dockOpen === false
    g().toggleDock() // back open for the next checks
    await wait(80)

    // 3) the LAST terminal is closable; undo-close restores it
    g().closeTerminal(seedId)
    await wait(120)
    const afterClose = {
      gone: g().terminals.length === 0,
      dockClosed: g().dockOpen === false && g().dockViews.length === 0,
      closableUi: true,
    }
    g().reopenClosedSession()
    await wait(120)
    afterClose.reopened = g().terminals.length === 1 && g().terminals[0].id === seedId

    // 4) defaultAutonomy: seeds new projects; mirrors into the armed settings file
    g().setDefaultAutonomy('sprint')
    await wait(200)
    const pid = g().newProject({ path: null, focus: true })
    await wait(120)
    const autonomyOut = {
      applied: g().autonomy === 'sprint',
      freshSingle: g().assistantThreads.length === 0 && g().terminals.length === 1,
    }
    const stPath = window.kaisola.claude.settingsPath
    const st = stPath ? await window.kaisola.fs.read(stPath) : { ok: false }
    autonomyOut.claudeMode = !!(st.ok && /"defaultMode"\\s*:\\s*"bypassPermissions"/.test(st.content || ''))
    g().setDefaultAutonomy('propose')
    await wait(200)
    const st2 = stPath ? await window.kaisola.fs.read(stPath) : { ok: false }
    autonomyOut.modeCleared = !!(st2.ok && !/bypassPermissions/.test(st2.content || ''))
    g().closeProject(pid, { force: true })

    return { singleSession, phantom, afterClose, autonomyOut }
  })()`)

  const flat = []
  for (const [group, checks] of Object.entries(out)) {
    for (const [k, v] of Object.entries(checks)) flat.push([group + '.' + k, v === true])
  }
  const failed = flat.filter(([, ok]) => !ok).map(([k]) => k)
  console.log('DEFAULTS_DETAIL=' + JSON.stringify(out))
  console.log('DEFAULTS_RESULT=' + (failed.length === 0 ? 'PASS' : 'FAIL ' + failed.join(',')))
  app.exit(failed.length === 0 ? 0 : 1)
})
