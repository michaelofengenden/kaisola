// Visual probe for the Codex Model/Effort/Speed control. Uses a deterministic
// live-control catalog and the real production renderer, but never starts an
// agent or sends a prompt.
const { app, BrowserWindow, ipcMain } = require('electron')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const userData = path.join(os.tmpdir(), 'kaisola-effort-ui-probe')
fs.rmSync(userData, { recursive: true, force: true })
app.setPath('userData', userData)

const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers } = require('./ipc/terminalHandler.cjs')
const { registerAuthHandlers } = require('./ipc/authHandler.cjs')
const { registerFsHandlers } = require('./ipc/fsHandler.cjs')
const { registerDbHandlers } = require('./ipc/dbHandler.cjs')
const { registerMcpHandlers } = require('./ipc/mcpServer.cjs')
const { registerExtensionHandlers } = require('./ipc/extensionHandler.cjs')
const { registerClaudeHooksHandlers } = require('./ipc/claudeHooksHandler.cjs')
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const { registerAssistantArchiveHandlers } = require('./ipc/assistantArchive.cjs')

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const controls = {
  modes: null,
  models: null,
  configOptions: [
    {
      id: 'model', name: 'Model', category: 'model', currentValue: 'gpt-5.6-sol',
      options: [
        { value: 'gpt-5.6-sol', name: 'GPT-5.6-Sol', description: 'Flagship reasoning model' },
        { value: 'gpt-5.6-terra', name: 'GPT-5.6-Terra', description: 'Balanced coding model' },
        { value: 'gpt-5.6-luna', name: 'GPT-5.6-Luna', description: 'Fast coding model' },
      ],
    },
    {
      id: 'reasoning_effort', name: 'Effort', category: 'thought_level', currentValue: 'ultra',
      options: ['low', 'medium', 'high', 'xhigh', 'ultra'].map((value, index) => ({ value, name: ['Light', 'Medium', 'High', 'Extra High', 'Ultra'][index] })),
    },
    {
      id: 'fast-mode', name: 'Fast mode', category: 'speed', currentValue: 'on',
      options: [{ value: 'off', name: 'Off' }, { value: 'on', name: 'On' }],
    },
  ],
}

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAuthHandlers(ipcMain); registerFsHandlers(ipcMain); registerDbHandlers(ipcMain)
  registerMcpHandlers(ipcMain); registerExtensionHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerAssistantArchiveHandlers(ipcMain, path.join(userData, 'assistant-archives'))
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: true, liveSolid: true }))
  ipcMain.handle('acp:presets', () => [{ id: 'codex', name: 'Codex', builtin: false }])
  ipcMain.handle('acp:status', (_event, { clientKeys } = {}) => {
    const key = clientKeys?.[0] || 'codex::probe'
    return { ok: true, agents: [{ key, presetId: 'codex', name: 'Codex', connected: true, controls }] }
  })
  for (const channel of ['acp:lease', 'acp:setMode', 'acp:setModel', 'acp:setConfigOption', 'acp:set-autonomy']) {
    ipcMain.handle(channel, () => ({ ok: true }))
  }
  ipcMain.handle('acp:diagnostics', () => ({}))

  const win = new BrowserWindow({
    show: true, width: 980, height: 720, frame: false, transparent: false, backgroundColor: '#f4f3f0',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: false },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1' } })
  await wait(1000)
  await win.webContents.executeJavaScript(`(() => { const s=window.__kaisola.getState(); s.clearProject(); s.requestNewThread('codex'); })()`)
  await wait(1000)
  const opened = await win.webContents.executeJavaScript(`(() => { const b=document.querySelector('.codex-summary'); if (!b) return false; b.click(); return true })()`)
  await wait(500)
  const image = await win.webContents.capturePage()
  const out = path.join(os.tmpdir(), 'kaisola-codex-effort.png')
  fs.writeFileSync(out, image.toPNG())
  // The matrix popover: model rows × effort columns on ONE surface (no tabs),
  // the active row filled to its effort, speed as a segmented footer.
  const facts = await win.webContents.executeJavaScript(`(() => ({
    opened: !!document.querySelector('.matrix-pop'),
    colLabels: [...document.querySelectorAll('.matrix-col-label')].map((el) => el.textContent.trim()),
    modelRows: [...document.querySelectorAll('.matrix-model')].map((el) => el.textContent.trim()),
    checked: document.querySelector('.matrix-cell[aria-checked="true"]')?.getAttribute('aria-label') ?? null,
    fillWidth: document.querySelector('.matrix-track[data-active] .matrix-fill')?.style.width ?? null,
    speedRows: [...document.querySelectorAll('.matrix-speed button')].map((el) => el.textContent.trim()),
    speedActive: document.querySelector('.matrix-speed button[data-active]')?.textContent.trim() ?? null,
  }))()`)
  // clicking any cell sets model AND effort in one gesture, then closes
  await win.webContents.executeJavaScript(`(() => document.querySelector('.matrix-cell[aria-label="GPT-5.6-Terra at High effort"]')?.click())()`)
  await wait(80)
  const closedAfterPick = await win.webContents.executeJavaScript(`(() => !document.querySelector('.matrix-pop'))()`)
  console.log('EFFORT_UI=' + JSON.stringify({ clicked: opened, ...facts, closedAfterPick, screenshot: out }))
  app.exit(
    opened
    && facts.opened
    && facts.colLabels.join(',') === 'Light,Medium,High,Extra High,Ultra'
    && facts.modelRows.length === 3
    && facts.checked === 'GPT-5.6-Sol at Ultra effort'
    && facts.fillWidth === '100%'
    && facts.speedRows.join(',') === 'Default,Fast'
    && facts.speedActive === 'Fast'
    && closedAfterPick
      ? 0
      : 1,
  )
}).catch((error) => { console.error(error); app.exit(1) })
