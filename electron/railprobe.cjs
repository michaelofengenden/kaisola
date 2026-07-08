// Repro probe for "outline overruns the file tree": opens a .tex with many
// sections, measures the rail's outline box vs where its content paints,
// and screenshots the window.
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
app.disableHardwareAcceleration()
app.setPath('userData', path.join(os.tmpdir(), 'kaisola-railprobe'))
try { fsx.rmSync(app.getPath('userData'), { recursive: true, force: true }) } catch { /* fresh */ }

const ROOT = path.join(os.tmpdir(), 'kaisola-railprobe-ws')
fsx.rmSync(ROOT, { recursive: true, force: true })
fsx.mkdirSync(ROOT, { recursive: true })
const sections = Array.from({ length: 40 }, (_, i) => `\\section{Section number ${i + 1} with a reasonably long title}\nText.\n`).join('\n')
fsx.writeFileSync(path.join(ROOT, 'paper.tex'), `\\documentclass{article}\n\\begin{document}\n${sections}\\end{document}\n`)
for (let i = 0; i < 8; i++) fsx.writeFileSync(path.join(ROOT, `file-${i}.md`), `# file ${i}\n`)

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))

  const win = new BrowserWindow({
    show: false,
    width: 1440,
    height: 900,
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
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await wait(800)
  await js(`window.__kaisola.getState().setWorkspace(${JSON.stringify(ROOT)})`)
  await wait(700)
  await js(`window.__kaisola.getState().requestFile(${JSON.stringify(path.join(ROOT, 'paper.tex'))}, 'edit', { pinned: true })`)
  await wait(1800) // editor mount + 250ms outline debounce
  const m = await js(`(() => {
    const sec = document.querySelector('.rail-sec')
    const body = document.querySelector('.rail-outline')
    const tree = document.querySelector('.wsrail-files')
    const items = document.querySelectorAll('.rail-outline-item').length
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return [Math.round(b.top), Math.round(b.bottom), Math.round(b.height)] }
    return {
      items,
      vh32: Math.round(window.innerHeight * 0.32),
      sec: r(sec),
      body: r(body),
      tree: r(tree),
      secOverflowY: sec ? getComputedStyle(sec).overflowY : null,
      bodyOverflowY: body ? getComputedStyle(body).overflowY : null,
      bodyScrollH: body ? body.scrollHeight : null,
      overlap: sec && tree ? Math.round(document.querySelector('.rail-outline').getBoundingClientRect().bottom - tree.getBoundingClientRect().top) : null,
    }
  })()`)
  console.log('RAIL=' + JSON.stringify(m))
  const img = await win.webContents.capturePage()
  fsx.writeFileSync(path.join(__dirname, '..', 'screenshots', 'rail-outline-repro.png'), img.toPNG())
  console.log('SHOT rail-outline-repro.png')
  app.exit(0)
})
