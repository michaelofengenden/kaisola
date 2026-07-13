// Deterministic end-to-end probe for the Claude + Codex group-session flow.
// It runs the production renderer with two tiny ACP stand-ins, then exercises
// scout → negotiate → role contract → isolated worktrees → review → integrate.
const { app, BrowserWindow, ipcMain } = require('electron')
const { execFileSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const userData = path.join(os.tmpdir(), 'kaisola-group-ui-probe')
const workspace = path.join(userData, 'workspace')
fs.rmSync(userData, { recursive: true, force: true })
fs.mkdirSync(workspace, { recursive: true })
fs.writeFileSync(path.join(workspace, 'README.md'), '# Group probe\n')
execFileSync('git', ['init', '-q'], { cwd: workspace })
execFileSync('git', ['config', 'user.name', 'Kaisola Probe'], { cwd: workspace })
execFileSync('git', ['config', 'user.email', 'probe@kaisola.local'], { cwd: workspace })
execFileSync('git', ['add', 'README.md'], { cwd: workspace })
execFileSync('git', ['commit', '-q', '-m', 'Initial probe fixture'], { cwd: workspace })
app.setPath('userData', userData)

const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers } = require('./ipc/terminalHandler.cjs')
const { registerAuthHandlers } = require('./ipc/authHandler.cjs')
const { registerFsHandlers } = require('./ipc/fsHandler.cjs')
const { registerDbHandlers } = require('./ipc/dbHandler.cjs')
const { registerGitHandlers } = require('./ipc/gitHandler.cjs')
const { registerMcpHandlers } = require('./ipc/mcpServer.cjs')
const { registerExtensionHandlers } = require('./ipc/extensionHandler.cjs')
const { registerClaudeHooksHandlers } = require('./ipc/claudeHooksHandler.cjs')
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const { registerAssistantArchiveHandlers } = require('./ipc/assistantArchive.cjs')
const { registerWorktreeHandlers } = require('./ipc/worktreeHandler.cjs')

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const connected = new Set()
let connectCalls = 0
const selectedModels = new Map()
const bareAgentKey = (key) => String(key ?? '').split('@@')[0]
const controlsFor = (key) => {
  const provider = key.startsWith('claude') ? 'claude' : 'codex'
  const options = provider === 'claude'
    ? [{ modelId: 'claude-default', name: 'Claude Default' }, { modelId: 'claude-fast', name: 'Claude Fast' }]
    : [{ modelId: 'codex-default', name: 'Codex Default' }, { modelId: 'codex-deep', name: 'Codex Deep' }]
  return { modes: null, configOptions: [], models: { currentModelId: selectedModels.get(key) ?? options[0].modelId, availableModels: options } }
}

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAuthHandlers(ipcMain); registerFsHandlers(ipcMain); registerDbHandlers(ipcMain); registerGitHandlers(ipcMain)
  registerMcpHandlers(ipcMain); registerExtensionHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerAssistantArchiveHandlers(ipcMain, path.join(userData, 'assistant-archives'))
  registerWorktreeHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: true, liveSolid: true }))
  ipcMain.handle('acp:presets', () => [
    { id: 'claude-code', name: 'Claude' },
    { id: 'codex', name: 'Codex' },
  ])
  ipcMain.handle('acp:status', (_event, { clientKeys } = {}) => ({
    ok: true,
    agents: (clientKeys ?? []).map((key) => ({ key, presetId: key.split('::')[0], name: key.startsWith('claude') ? 'Claude' : 'Codex', connected: connected.has(key), controls: controlsFor(key) })),
  }))
  ipcMain.handle('acp:connect', (_event, config) => {
    const key = bareAgentKey(config.clientKey)
    connectCalls += 1
    connected.add(key)
    return { ok: true, agent: { key, connected: true, sessionId: `session-${key}` }, controls: controlsFor(key) }
  })
  ipcMain.handle('acp:disconnect', (_event, { agentKey } = {}) => {
    connected.delete(bareAgentKey(agentKey))
    return { ok: true }
  })
  ipcMain.handle('acp:prompt', async (event, { agentKey, reqId, text }) => {
    if (!connected.has(bareAgentKey(agentKey))) return { ok: false, message: 'Probe adapter is parked.' }
    const provider = agentKey.startsWith('claude') ? 'Claude' : 'Codex'
    let reply = `${provider} independent proposal with an ownership boundary and acceptance tests.`
    if (/only role-negotiation round/.test(text)) {
      reply = `${provider} accepts the peer constraint and proposes an orthogonal role split.`
    } else if (/Act as the coordinator/.test(text)) {
      reply = 'Mission intent\nShared invariants\nClaude assignment\nCodex assignment\nIntegration order\nAcceptance tests\nStop and escalation conditions'
    } else if (/Execute only your named assignment/.test(text)) {
      const worktree = text.match(/isolated worktree: (.+?)\. Do not/)?.[1]
      if (worktree) fs.writeFileSync(path.join(worktree, `${provider.toLowerCase()}-result.txt`), `${provider} isolated result\n`)
      reply = `${provider} execution complete; changed one owned file and ran the probe check.`
    } else if (/sole integration owner/.test(text)) {
      reply = 'Integrated both reviewed branches and verified the shared acceptance tests.'
    } else if (/Cross-review/.test(text)) {
      reply = `${provider} verifier verdict: pass; ownership and integration checks are satisfied.`
    }
    await wait(35)
    event.sender.send(`acp:update:${reqId}`, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: reply } })
    event.sender.send(`acp:update:${reqId}`, { __done: true })
    return { ok: true, stopReason: 'end_turn' }
  })
  ipcMain.handle('acp:setModel', (_event, { agentKey, modelId }) => {
    selectedModels.set(String(agentKey).split('@@')[0], modelId)
    return { ok: true }
  })
  for (const channel of ['acp:lease', 'acp:setMode', 'acp:setConfigOption', 'acp:set-autonomy', 'acp:cancel']) {
    ipcMain.handle(channel, () => ({ ok: true }))
  }
  ipcMain.handle('acp:diagnostics', () => ({}))

  const win = new BrowserWindow({
    show: true,
    width: 1180,
    height: 800,
    frame: false,
    transparent: false,
    backgroundColor: '#f4f3f0',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: false },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1' } })
  await wait(800)
  await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    state.clearProject()
    state.setWorkspace(${JSON.stringify(workspace)})
    state.requestNewGroup()
  })()`)
  await wait(700)

  // A real long-lived agent often already owns the full 40-turn live window.
  // Mesh boundaries must remain monotonic while old turns page out instead of
  // relying on an array length that can no longer increase.
  const saturated = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    const before = Date.now() - 60_000
    for (const member of group?.group?.members ?? []) {
      state.updateAssistantRuntime(member.threadId, (runtime) => ({
        ...runtime,
        turns: Array.from({ length: 40 }, (_, index) => ({ kind: 'assistant', text: 'prior turn ' + index, at: before + index })),
      }))
    }
    const after = window.__kaisola.getState()
    return (group?.group?.members ?? []).every((member) => after.assistantRuntimes[member.threadId]?.turns.length === 40)
  })()`)

  const configured = await win.webContents.executeJavaScript(`(() => {
    const selects = [...document.querySelectorAll('.group-roster-row select')]
    if (selects.length !== 2 || selects.some((select) => select.options.length < 2)) return false
    selects.forEach((select) => {
      select.value = select.options[select.options.length - 1].value
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    return !!document.querySelector('.group-add-member')
  })()`)
  await wait(180)

  const asked = await win.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('.group-composer textarea')
    const send = document.querySelector('.group-primary')
    if (!input || !send) return false
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set
    setter.call(input, 'Design a safe collaboration harness.')
    input.dispatchEvent(new Event('input', { bubbles: true }))
    send.click()
    return true
  })()`)

  const waitForPhase = async (phase) => {
    for (let i = 0; i < 120; i++) {
      const current = await win.webContents.executeJavaScript(`document.querySelector('.group-assistant')?.getAttribute('data-phase')`)
      if (current === phase) return true
      await wait(50)
    }
    return false
  }
  const clickAction = async () => {
    for (let i = 0; i < 120; i++) {
      const clicked = await win.webContents.executeJavaScript(`(() => {
        const action = document.querySelector('.group-action')
        if (!action || action.disabled) return false
        action.click()
        return true
      })()`)
      if (clicked) return true
      await wait(50)
    }
    return false
  }
  const ready = await waitForPhase('ready')
  // Reproduce the production failure: both scouts are finished, their adapter
  // processes park, and the renderer still has an optimistic connected badge.
  // Negotiation must probe, reconnect, and drain its durable prompts.
  if (ready) connected.clear()
  const parkedBeforeNegotiation = ready && connected.size === 0
  if (ready) await clickAction()
  const negotiated = await waitForPhase('plan-ready')
  if (negotiated) await clickAction()
  const assigned = await waitForPhase('assigned')
  if (assigned) await clickAction()
  const executed = await waitForPhase('execution-ready')
  if (executed) await clickAction()
  const reviewed = await waitForPhase('merge-ready')
  if (reviewed) await clickAction()
  const done = await waitForPhase('done')

  const facts = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    const workerIds = group?.group?.members.map((member) => member.threadId) ?? []
    return {
    phase: document.querySelector('.group-assistant')?.getAttribute('data-phase'),
    visibleGroupTabs: group && document.querySelector('.stab[data-sid="' + group.id + '"]') ? 1 : 0,
    leakedWorkerTabs: workerIds.filter((id) => document.querySelector('.stab[data-sid="' + id + '"]')).length,
    answers: [...document.querySelectorAll('.group-result p')].map((node) => node.textContent.trim()),
    negotiations: [...document.querySelectorAll('.group-review')][0]?.querySelectorAll('p').length ?? 0,
    reviews: [...document.querySelectorAll('.group-review')].at(-1)?.querySelectorAll('p').length ?? 0,
    roleContract: group?.group?.jointPlan,
    executions: Object.keys(group?.group?.executions ?? {}).length,
    worktrees: Object.keys(group?.group?.worktrees ?? {}).length,
    changedFiles: Object.values(group?.group?.changedFiles ?? {}).flat().map((file) => file.path).sort(),
    integration: group?.group?.integration,
    error: group?.group?.error,
    memberModels: group?.group?.members.map((member) => member.modelLabel),
    workerCount: document.querySelectorAll('.group-workers .assistant').length,
    }
  })()`)
  await wait(700)
  win.webContents.reload()
  await wait(1000)
  const persisted = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    return {
      phase: group?.group?.phase,
      members: group?.group?.members.length ?? 0,
      integration: group?.group?.integration,
      worktrees: Object.keys(group?.group?.worktrees ?? {}).length,
      visible: !!(group && document.querySelector('.group-assistant[data-phase="done"]')),
    }
  })()`)
  const image = await win.webContents.capturePage()
  const screenshot = path.join(os.tmpdir(), 'kaisola-group-session.png')
  fs.writeFileSync(screenshot, image.toPNG())
  const result = { configured, saturated, asked, ready, parkedBeforeNegotiation, connectCalls, negotiated, assigned, executed, reviewed, done, ...facts, persisted, screenshot }
  console.log('GROUP_UI=' + JSON.stringify(result))
  app.exit(
    configured
    && saturated
    && asked
    && ready
    && parkedBeforeNegotiation
    && connectCalls >= 4
    && negotiated
    && assigned
    && executed
    && reviewed
    && done
    && facts.phase === 'done'
    && facts.visibleGroupTabs === 1
    && facts.leakedWorkerTabs === 0
    && facts.answers.length === 2
    && facts.negotiations === 2
    && facts.reviews === 2
    && facts.executions === 2
    && facts.worktrees === 2
    && facts.memberModels.join(',') === 'Claude Fast,Codex Deep'
    && facts.changedFiles.join(',') === 'claude-result.txt,codex-result.txt'
    && facts.roleContract.startsWith('Mission intent')
    && facts.integration === 'Integrated both reviewed branches and verified the shared acceptance tests.'
    && facts.workerCount === 2
    && persisted.phase === 'done'
    && persisted.members === 2
    && persisted.integration === 'Integrated both reviewed branches and verified the shared acceptance tests.'
    && persisted.worktrees === 2
    && persisted.visible
      ? 0
      : 1,
  )
}).catch((error) => { console.error(error); app.exit(1) })
