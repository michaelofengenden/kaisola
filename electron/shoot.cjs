// UI screenshot harness — a headless "computer-using" view of the REAL desktop
// renderer. Boots the app like smoke.cjs (isDesktop = true, so Settings shows
// the desktop variant), drives the store into a matrix of states, and writes a
// PNG per state via webContents.capturePage(). Any agent can then READ the PNGs
// in ./screenshots and actually SEE the UI.
//
//   npm run shoot            → capture the full matrix
//   npm run shoot -- ideas   → capture only states whose name includes "ideas"
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
const { registerMcpHandlers } = require('./ipc/mcpServer.cjs')
const { registerExtensionHandlers } = require('./ipc/extensionHandler.cjs')
const worktree = require('./ipc/worktreeHandler.cjs')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const filter = (process.argv.find((a) => !a.startsWith('-') && !a.includes('electron') && !a.includes('shoot.cjs')) || '').toLowerCase()
const OUT = path.join(__dirname, '..', 'screenshots')
fsx.mkdirSync(OUT, { recursive: true })
app.setPath('userData', path.join(os.tmpdir(), 'kaisola-shoot-userdata'))
try { fsx.rmSync(app.getPath('userData'), { recursive: true, force: true }) } catch { /* fresh */ }

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerMcpHandlers(ipcMain); registerExtensionHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))

  const win = new BrowserWindow({
    show: false,
    width: 1440,
    height: 900,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  await wait(800)
  await win.webContents.executeJavaScript(`(() => { try { localStorage.removeItem('kaisola-store') } catch (e) {}; window.__kaisola.getState().clearProject() })()`)

  const js = (code) => win.webContents.executeJavaScript(code)
  const shots = []
  const shot = async (name) => {
    if (filter && !name.toLowerCase().includes(filter)) return
    await wait(380)
    const img = await win.webContents.capturePage()
    const file = path.join(OUT, `${name}.png`)
    fsx.writeFileSync(file, img.toPNG())
    const { width, height } = img.getSize()
    shots.push({ name, file, width, height })
    console.log(`SHOT ${name} ${width}x${height}`)
  }
  const setTheme = (t) => js(`(() => { window.__kaisola.getState().setTheme(${JSON.stringify(t)}); document.documentElement.dataset.theme=${JSON.stringify(t)} })()`)
  const setStage = (s) => js(`window.__kaisola.getState().setStage(${JSON.stringify(s)})`)
  const openSettings = async (tab) => {
    await js(`window.__kaisola.getState().setSettingsOpen(true)`)
    await wait(220)
    // Zed-style Settings: click the matching category in the left nav
    if (tab) await js(`(() => { const b=[...document.querySelectorAll('.settings-nav-item')].find(x => (x.textContent||'').toLowerCase().includes(${JSON.stringify(tab)})); if (b) b.click() })()`)
    await wait(120)
  }
  const closeSettings = () => js(`window.__kaisola.getState().setSettingsOpen(false)`)

  try {
    await js(`window.__kaisola.getState().loadDemo()`)
    await wait(400)

    const views = ['corpus', 'claims', 'questions', 'ideas', 'analysis', 'manuscript', 'review', 'files']
    for (const theme of ['light', 'dark']) {
      await setTheme(theme)
      for (const v of views) {
        await setStage(v)
        // nudge ResizeObserver so react-flow (claim graph) runs fitView in offscreen mode
        await js(`window.dispatchEvent(new Event('resize'))`)
        await wait(v === 'claims' ? 650 : 60)
        await shot(`view-${v}-${theme}`)
      }
    }

    // a toast in flight (legibility pass)
    await setTheme('light'); await setStage('ideas')
    await js(`window.__kaisola.getState().pushToast('success','Hypothesis proposed 2 changes')`)
    await js(`window.__kaisola.getState().pushToast('info','Workflow “Literature pass” — 2 steps queued')`)
    await shot('toast-light')

    // Settings — every tab, both themes for the default tab
    await setTheme('light')
    for (const tab of ['general', 'interface', 'agents', 'models']) {
      await openSettings(tab); await shot(`settings-${tab}-light`)
    }
    await closeSettings()
    await setTheme('dark')
    for (const tab of ['general', 'models']) {
      await openSettings(tab); await shot(`settings-${tab}-dark`)
    }
    await closeSettings()

    // Extensions — the Zed-shaped full-screen catalog, both themes.
    await setTheme('light')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open'))`)
    await shot('extensions-light')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open:close'))`)
    await setTheme('dark')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open'))`)
    await shot('extensions-dark')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open:close'))`)

    // Files editor — set a real workspace, open a code file, switch to Edit
    await setTheme('light'); await setStage('files')
    await js(`window.__kaisola.getState().setWorkspace(${JSON.stringify(path.join(__dirname, '..', 'src', 'styles'))})`)
    await wait(600)
    await js(`(() => { const r=[...document.querySelectorAll('.fx-row')].find(x => /\\.(css|ts|tsx|json|md)$/.test(x.textContent||'')); if (r) r.click() })()`)
    await wait(600)
    await js(`(() => { const b=[...document.querySelectorAll('.fx-mode')].find(x => /Edit|Source/.test(x.textContent||'')); if (b) b.click() })()`)
    await wait(800) // CodeMirror mount
    await shot('files-editor-light')

    // the session-card grid — two agents side by side, a terminal stacked
    // below the second one (each session is its own movable card)
    await setStage('corpus')
    await js(`(() => {
      const st = window.__kaisola.getState()
      st.requestNewThread('mock')
      st.requestTerminal()
    })()`)
    await wait(400)
    await js(`(() => {
      const st = window.__kaisola.getState()
      const term = st.terminals[st.terminals.length - 1].id
      st.placeDockView(term, st.activeThreadId, 'bottom')
      // Keep the hero shot representative of the two-tier navigation: one
      // active project owns the session shelf while background projects show
      // independent activity states in the calmer parent row.
      st.renameProjectTab(st.activeProjectId, 'Kaisola')
      st.setProjectColor(st.activeProjectId, '#6376d9')
      const docs = st.newProject({ path: null, focus: false })
      st.renameProjectTab(docs, 'Docs')
      st.setProjectColor(docs, '#52a96b')
      st.setProjectActivity(docs, 'running')
      const experiments = st.newProject({ path: null, focus: false })
      st.renameProjectTab(experiments, 'Experiments')
      st.setProjectColor(experiments, '#d18a55')
      st.setProjectActivity(experiments, 'completed')
    })()`)
    // the toast-pass toasts must not linger into the hero shots
    await js(`(() => { const s = window.__kaisola.getState(); for (const t of s.toasts) s.dismissToast(t.id) })()`)
    await wait(300)
    for (const theme of ['light', 'dark']) {
      await setTheme(theme)
      for (const layout of ['sidebar', 'shelf', 'bare', 'runway', 'flat', 'compact']) {
        await js(`window.__kaisola.getState().setTabLayout(${JSON.stringify(layout)})`)
        await shot(`tab-layout-${layout}-${theme}`)
      }
    }
    await js(`window.__kaisola.getState().setTabLayout('sidebar')`)
  } catch (e) {
    console.log('SHOOT_ERROR ' + (e && e.message || e))
  }

  console.log(`SHOOT_DONE ${shots.length} → ${OUT}`)
  app.exit(0)
})
