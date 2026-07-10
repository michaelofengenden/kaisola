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
  const facts = await win.webContents.executeJavaScript(`(() => ({
    opened: !!document.querySelector('.codex-minimal-pop'),
    tabs: [...document.querySelectorAll('.provider-section-tabs button')].map((el) => el.textContent.trim()),
    rows: [...document.querySelectorAll('.codex-minimal-pop .provider-choice-row')].map((el) => el.textContent.trim()),
    checked: document.querySelector('.codex-minimal-pop [aria-checked="true"]')?.textContent.trim(),
    note: document.querySelector('.provider-choice-note')?.textContent.trim() || null,
  }))()`)
  await win.webContents.executeJavaScript(`(() => [...document.querySelectorAll('.provider-section-tabs button')].find((el) => el.textContent.trim() === 'Speed')?.click())()`)
  await wait(80)
  const speedRows = await win.webContents.executeJavaScript(`(() => [...document.querySelectorAll('.codex-minimal-pop .provider-choice-row')].map((el) => el.textContent.trim()))()`)
  await win.webContents.executeJavaScript(`(() => [...document.querySelectorAll('.provider-section-tabs button')].find((el) => el.textContent.trim() === 'Model')?.click())()`)
  await wait(80)
  const modelRows = await win.webContents.executeJavaScript(`(() => [...document.querySelectorAll('.codex-minimal-pop .provider-choice-row')].map((el) => el.textContent.trim()))()`)
  await win.webContents.executeJavaScript(`(() => { document.querySelector('.codex-summary')?.click(); document.querySelector('.tabstrip-tools > button[title="More"]')?.click() })()`)
  await wait(100)
  const moreRows = await win.webContents.executeJavaScript(`(() => [...document.querySelectorAll('.shell-more-menu .tree-menu-item')].map((el) => el.textContent.replace(/\\s+/g, ' ').trim()))()`)
  const moreImage = await win.webContents.capturePage()
  const moreOut = path.join(os.tmpdir(), 'kaisola-shell-more.png')
  fs.writeFileSync(moreOut, moreImage.toPNG())
  console.log('EFFORT_UI=' + JSON.stringify({ clicked: opened, ...facts, speedRows, modelRows, moreRows, screenshot: out, moreScreenshot: moreOut }))
  app.exit(opened && facts.tabs.join(',') === 'Model,Effort,Speed' && facts.rows.length === 5 && facts.checked === 'Ultra' && facts.note === null && speedRows.join(',') === 'Default,Fast' && modelRows.length === 3 && modelRows.every((row) => !/model$/i.test(row)) && moreRows.length === 5 ? 0 : 1)
}).catch((error) => { console.error(error); app.exit(1) })
