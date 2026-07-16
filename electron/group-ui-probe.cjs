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
// Per-process isolation lets CI/reviewers run the probe concurrently without
// deleting or pre-populating each other's git fixture midway through a stage.
const userData = path.join(os.tmpdir(), `kaisola-group-ui-probe-${process.pid}`)
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
const { registerTerminalHandlers, killAllSessions } = require('./ipc/terminalHandler.cjs')
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
const cancelled = new Set()
const adoptedBusy = new Set()
const lifecycleEvents = []
let delayCloseSessions = false
let connectCalls = 0
let largeReviewRouted = false
const selectedModels = new Map()
const selectedEfforts = new Map()
const promptCounts = new Map()
const ideaPrompts = []
const ideaCounts = new Map()
const bareAgentKey = (key) => String(key ?? '').split('@@')[0]
const controlsFor = (key) => {
  const provider = key.startsWith('claude') ? 'claude' : 'codex'
  const options = provider === 'claude'
    ? [{ modelId: 'claude-default', name: 'Claude Default' }, { modelId: 'claude-fast', name: 'Claude Fast' }]
    : [{ modelId: 'codex-default', name: 'Codex Default' }, { modelId: 'codex-deep', name: 'Codex Deep' }]
  // Both adapters report a live effort control; Codex mirrors the app-server's
  // model_reasoning_effort so Mesh must pass its wire values untranslated.
  const configOptions = provider === 'claude' ? [{
    id: 'reasoning_effort',
    name: 'Reasoning effort',
    category: 'thought_level',
    currentValue: selectedEfforts.get(key) ?? 'high',
    options: ['low', 'medium', 'high', 'xhigh', 'max'].map((value) => ({ value, name: value })),
  }] : [{
    id: 'model_reasoning_effort',
    name: 'Reasoning effort',
    category: 'thought_level',
    currentValue: selectedEfforts.get(key) ?? 'high',
    options: ['low', 'medium', 'high', 'xhigh'].map((value) => ({ value, name: value })),
  }]
  return { modes: null, configOptions, models: { currentModelId: selectedModels.get(key) ?? options[0].modelId, availableModels: options } }
}

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAuthHandlers(ipcMain); registerFsHandlers(ipcMain); registerDbHandlers(ipcMain); registerGitHandlers(ipcMain)
  registerMcpHandlers(ipcMain); registerExtensionHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerAssistantArchiveHandlers(ipcMain, path.join(userData, 'assistant-archives'))
  registerWorktreeHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: true, liveSolid: true }))
  ipcMain.handle('window:list-saved', () => ({ ok: true, windows: [] }))
  ipcMain.handle('window:reopen-saved', () => ({ ok: false, missing: true }))
  ipcMain.handle('window:delete-saved', () => ({ ok: false, missing: true }))
  ipcMain.handle('window:popped', () => ({ ok: true, termIds: [], states: [], closed: [] }))
  ipcMain.handle('window:pop-closed-ack', () => ({ ok: false }))
  ipcMain.on('window:terminal-state', () => {})
  ipcMain.handle('acp:presets', () => [
    { id: 'claude-code', name: 'Claude' },
    { id: 'codex', name: 'Codex' },
  ])
  ipcMain.handle('acp:status', (_event, { clientKeys } = {}) => ({
    ok: true,
    agents: (clientKeys ?? []).map((key) => ({ key, presetId: key.split('::')[0], name: key.startsWith('claude') ? 'Claude' : 'Codex', connected: connected.has(key), busy: adoptedBusy.has(key), controls: controlsFor(key) })),
  }))
  ipcMain.handle('acp:connect', (_event, config) => {
    const key = bareAgentKey(config.clientKey)
    connectCalls += 1
    connected.add(key)
    return { ok: true, agent: { key, connected: true, sessionId: `session-${key}` }, controls: controlsFor(key) }
  })
  ipcMain.handle('acp:disconnect', (_event, { agentKey } = {}) => {
    const key = bareAgentKey(agentKey)
    lifecycleEvents.push(['disconnect', key])
    connected.delete(key)
    adoptedBusy.delete(key)
    return { ok: true }
  })
  ipcMain.handle('acp:prompt', async (event, { agentKey, reqId, text }) => {
    const key = bareAgentKey(agentKey)
    if (!connected.has(key)) return { ok: false, message: 'Probe adapter is parked.' }
    const provider = agentKey.startsWith('claude') ? 'Claude' : 'Codex'
    const count = (promptCounts.get(key) ?? 0) + 1
    promptCounts.set(key, count)
    let reply = `${provider} independent proposal with an ownership boundary and acceptance tests. `.repeat(12).trim()
    if (/group idea chat/.test(text)) {
      const n = (ideaCounts.get(`${key}:initial`) ?? 0) + 1
      ideaCounts.set(`${key}:initial`, n)
      ideaPrompts.push([key, 'initial', text])
      reply = `${provider} initial thought #${n}`
    } else if (/React once to the group/.test(text)) {
      const n = (ideaCounts.get(`${key}:reaction`) ?? 0) + 1
      ideaCounts.set(`${key}:reaction`, n)
      ideaPrompts.push([key, 'reaction', text])
      reply = `${provider} reaction building #${n}`
    } else if (/only role-negotiation round/.test(text)) {
      reply = `${provider} accepts the peer constraint and proposes an orthogonal role split.`
    } else if (/Act as the coordinator/.test(text)) {
      reply = 'Mission intent\nShared invariants\nClaude assignment\nCodex assignment\nIntegration order\nAcceptance tests\nStop and escalation conditions'
    } else if (/Execute only your named assignment/.test(text)) {
      const worktree = text.match(/isolated worktree: (.+?)\. Do not/)?.[1]
      if (worktree) fs.writeFileSync(
        path.join(worktree, `${provider.toLowerCase()}-result.txt`),
        provider === 'Codex' ? `${provider} isolated result\n${'large-review-fixture\n'.repeat(2_200)}` : `${provider} isolated result\n`,
      )
      reply = `${provider} execution complete; changed one owned file and ran the probe check.`
    } else if (/sole integration owner/.test(text)) {
      reply = 'Integrated both reviewed branches and verified the shared acceptance tests.'
    } else if (/Cross-review/.test(text)) {
      if (/Immutable review source/.test(text) && /git -C .* diff --no-ext-diff --find-renames/.test(text)) largeReviewRouted = true
      const receipt = text.match(/MESH_REVIEW_RECEIPT\n(\{[^\n]+\})/)?.[1]
      reply = `${provider} verifier verdict: pass; ownership and integration checks are satisfied.\n\nMESH_REVIEW_RECEIPT\n${receipt ?? '{}'}`
    }
    const firstScout = /scouting independently/.test(text) && count === 1
    // Idea initials get split latencies so the transcript's chronological
    // completion order is observable (Claude lands first).
    const ideaInitial = /group idea chat/.test(text)
    await wait(firstScout ? (provider === 'Claude' ? 55 : 520) : ideaInitial ? (provider === 'Claude' ? 30 : 160) : 35)
    if (cancelled.delete(key)) return { ok: true, stopReason: 'cancelled' }
    event.sender.send(`acp:update:${reqId}`, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: reply } })
    event.sender.send(`acp:update:${reqId}`, { __done: true })
    return { ok: true, stopReason: 'end_turn' }
  })
  ipcMain.handle('acp:setModel', (_event, { agentKey, modelId }) => {
    selectedModels.set(String(agentKey).split('@@')[0], modelId)
    return { ok: true }
  })
  ipcMain.handle('acp:setConfigOption', (_event, { agentKey, value }) => {
    selectedEfforts.set(String(agentKey).split('@@')[0], value)
    return { ok: true }
  })
  ipcMain.handle('acp:cancel', (_event, { agentKey }) => {
    const key = bareAgentKey(agentKey)
    lifecycleEvents.push(['cancel', key])
    if (adoptedBusy.has(key)) setTimeout(() => adoptedBusy.delete(key), 80)
    else cancelled.add(key)
    return { ok: true }
  })
  ipcMain.handle('acp:close-session', async (_event, { agentKey }) => {
    lifecycleEvents.push(['close', bareAgentKey(agentKey)])
    if (delayCloseSessions) await wait(180)
    return { ok: true, closed: true }
  })
  for (const channel of ['acp:lease', 'acp:setMode', 'acp:set-autonomy']) {
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
  const captureAsset = async (name, selector) => {
    const assetDir = process.env.KAISOLA_SITE_ASSETS
    if (!assetDir) return null
    win.setSize(1440, 900)
    await wait(180)
    await win.webContents.executeJavaScript(`(() => {
      const state = window.__kaisola.getState()
      const group = state.assistantThreads.find((thread) => thread.group)
      if (!group) return
      for (const id of [...state.dockViews]) if (id !== group.id) state.removeDockView(id)
      state.setDockView(group.id)
      if (window.__kaisola.getState().canvasOpen) state.toggleCanvas()
      const stream = document.querySelector('.group-stream')
      const target = document.querySelector(${JSON.stringify(selector)})
      if (stream) stream.scrollTop = target ? Math.max(0, target.offsetTop - 72) : 0
    })()`)
    await wait(320)
    const image = await win.webContents.capturePage()
    const target = path.resolve(assetDir, name)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.writeFileSync(target, image.resize({ width: 1600 }).toJPEG(91))
    return target
  }
  await wait(800)
  await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    state.clearProject()
    state.setWorkspace(${JSON.stringify(workspace)})
    state.requestNewGroup()
    const next = window.__kaisola.getState()
    const group = next.assistantThreads.find((thread) => thread.group)
    if (group) next.setGroupSession(group.id, { flow: 'guided' })
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

  const configuredControls = await win.webContents.executeJavaScript(`(() => {
    const selects = [...document.querySelectorAll('.group-model-select')]
    const efforts = [...document.querySelectorAll('.group-effort-select')]
    if (selects.length !== 2 || selects.some((select) => select.options.length < 2) || efforts.length !== 2) return false
    selects.forEach((select) => {
      select.value = select.options[select.options.length - 1].value
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    efforts.forEach((effort) => {
      effort.value = 'xhigh'
      effort.dispatchEvent(new Event('change', { bubbles: true }))
    })
    return !!document.querySelector('.group-add-member')
  })()`)
  await wait(240)
  const configured = configuredControls && await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    const claude = group?.group?.members.find((member) => member.agentKey === 'claude-code')
    const codex = group?.group?.members.find((member) => member.agentKey === 'codex')
    const claudeChild = state.assistantThreads.find((thread) => thread.id === claude?.threadId)
    const codexChild = state.assistantThreads.find((thread) => thread.id === codex?.threadId)
    return claudeChild?.claudeEffort === 'xhigh' && codexChild?.codexEffort === 'xhigh'
      && group?.group?.members.map((member) => member.modelLabel).join(',') === 'Claude Fast,Codex Deep'
  })()`)
  // The renderer must have handed each provider its exact wire value.
  const effortWire = [...selectedEfforts.entries()]
    .map(([key, value]) => `${key.split('::')[0]}:${value}`).sort().join(',')

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
  const waitForAnyPhase = async (phases) => {
    for (let i = 0; i < 120; i++) {
      const current = await win.webContents.executeJavaScript(`document.querySelector('.group-assistant')?.getAttribute('data-phase')`)
      if (phases.includes(current)) return true
      await wait(50)
    }
    return false
  }
  const waitForPaused = async () => {
    for (let i = 0; i < 120; i++) {
      const paused = await win.webContents.executeJavaScript(`window.__kaisola.getState().assistantThreads.find((thread) => thread.group)?.group?.paused === true`)
      if (paused) return true
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
  await wait(150)
  const stopped = await win.webContents.executeJavaScript(`(() => { const stop = document.querySelector('.group-stop'); if (!stop) return false; stop.click(); return true })()`)
  const paused = await waitForPaused()
  await wait(700)
  // Simulate a renderer restart that adopts a provider connection whose old
  // prompt is still busy even though the renderer's transient thread.busy bit
  // was reset. Continue must consult authoritative ACP status and cancel it
  // before dispatching a replacement attempt.
  const adoptedKey = [...promptCounts.keys()].find((key) => key.startsWith('codex'))
  if (adoptedKey) adoptedBusy.add(adoptedKey)
  win.webContents.reload()
  await wait(900)
  const pausedPersisted = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    return group?.group?.paused === true && group.group.pausedPending?.length === 1 && group.group.stagePrompts && group.group.stageAttemptId
  })()`)
  const pausedScreenshot = await captureAsset('mesh-control-light.jpg', '.group-task')
  const pausedCloseReopen = await win.webContents.executeJavaScript(`(() => {
    const before = window.__kaisola.getState()
    const parent = before.assistantThreads.find((thread) => thread.group)
    if (!parent) return { ok: false }
    const memberIds = parent.group.members.map((member) => member.threadId)
    before.closeAssistantThread(parent.id)
    const closed = window.__kaisola.getState()
    const bundle = closed.closedStack.find((entry) => entry.kind === 'group' && entry.thread?.id === parent.id)
    closed.reopenClosedSession(parent.id)
    const reopened = window.__kaisola.getState()
    const restored = reopened.assistantThreads.find((thread) => thread.id === parent.id)
    return {
      ok: bundle?.thread?.group?.paused === true && bundle.thread.group.pausedPending?.length === 1 && restored?.group?.paused === true && restored.group.pausedPending?.length === 1 && memberIds.every((id) => reopened.assistantThreads.some((thread) => thread.id === id)),
      pending: restored?.group?.pausedPending?.length ?? 0,
      bundledThreads: bundle?.groupThreads?.length ?? 0,
    }
  })()`)
  await wait(300)
  const continued = await clickAction()
  const ready = await waitForPhase('ready')
  const adoptedBusyRecovered = !!adoptedKey && !adoptedBusy.has(adoptedKey)
  const selectiveResume = [...promptCounts.entries()].filter(([key]) => key.includes('::')).sort().map(([key, count]) => [key.split('::')[0], count])
  // Reproduce the production failure: both scouts are finished, their adapter
  // processes park, and the renderer still has an optimistic connected badge.
  // Negotiation must probe, reconnect, and drain its durable prompts.
  if (ready) connected.clear()
  const parkedBeforeNegotiation = ready && connected.size === 0
  // Switch from the fully manual control path into Fluid mode at a settled
  // checkpoint. Negotiation and role-contract drafting must advance without
  // synthetic button clicks, including reconnecting the parked adapters.
  const fluidEnabled = ready && await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    if (!group) return false
    state.setGroupSession(group.id, { flow: 'fluid' })
    return true
  })()`)
  const assigned = await waitForPhase('assigned')
  const negotiated = assigned
  // A double activation lands before React can disable the button. The
  // durable compare-and-set operation journal must still create exactly one
  // worktree per member (a component-local ref cannot guarantee this).
  const doubleExecuteClaimed = assigned && await win.webContents.executeJavaScript(`(() => {
    const action = document.querySelector('.group-action')
    if (!action || action.disabled) return false
    action.click()
    action.click()
    return true
  })()`)
  const executed = await waitForAnyPhase(['execution-ready', 'reviewing', 'merge-ready'])
  const isolatedWorktreeCount = executed
    ? execFileSync('git', ['worktree', 'list', '--porcelain'], { cwd: workspace, encoding: 'utf8' }).split('\n').filter((line) => line.startsWith('worktree ')).length - 1
    : -1
  // Fluid mode auto-starts the read-only cross-review stage. Integration is
  // still a state-changing gate and remains the explicit click below.
  const reviewed = await waitForPhase('merge-ready')
  if (reviewed) await clickAction()
  const done = await waitForPhase('done')
  let worktreeCleanupDone = false
  for (let i = 0; i < 120; i++) {
    const durableCleanup = await win.webContents.executeJavaScript(`(() => {
      const group = window.__kaisola.getState().assistantThreads.find((thread) => thread.group)?.group
      return !!group && !group.worktreeCleanup && Object.keys(group.worktrees ?? {}).length === 0
    })()`)
    const diskCount = execFileSync('git', ['worktree', 'list', '--porcelain'], { cwd: workspace, encoding: 'utf8' }).split('\n').filter((line) => line.startsWith('worktree ')).length - 1
    if (durableCleanup && diskCount === 0) { worktreeCleanupDone = true; break }
    await wait(50)
  }

  const facts = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    const workerIds = group?.group?.members.map((member) => member.threadId) ?? []
    return {
    phase: document.querySelector('.group-assistant')?.getAttribute('data-phase'),
    visibleGroupTabs: group && document.querySelector('.stab[data-sid="' + group.id + '"]') ? 1 : 0,
    leakedWorkerTabs: workerIds.filter((id) => document.querySelector('.stab[data-sid="' + id + '"]')).length,
    answers: [...document.querySelectorAll('.group-result p')].map((node) => node.textContent.trim()),
    answerMap: group?.group?.answers,
    negotiations: [...document.querySelectorAll('.group-review')][0]?.querySelectorAll('p').length ?? 0,
    reviews: [...document.querySelectorAll('.group-review')].at(-1)?.querySelectorAll('p').length ?? 0,
    roleContract: group?.group?.jointPlan,
    executions: Object.keys(group?.group?.executions ?? {}).length,
    worktrees: Object.keys(group?.group?.worktrees ?? {}).length,
    changedFiles: Object.values(group?.group?.changedFiles ?? {}).flat().map((file) => file.path).sort(),
    reviewReceipts: Object.keys(group?.group?.reviewReceipts ?? {}).length,
    integration: group?.group?.integration,
    error: group?.group?.error,
    workerReceipts: Object.fromEntries(workerIds.map((id) => [id, state.assistantRuntimes[id]?.lastRun])),
    workerTails: Object.fromEntries(workerIds.map((id) => [id, (state.assistantRuntimes[id]?.turns ?? []).slice(-4).map((turn) => ({ kind: turn.kind, at: turn.at, text: turn.text?.slice(0, 120) }))])),
    memberModels: group?.group?.members.map((member) => member.modelLabel),
    flow: group?.group?.flow,
    workerCount: document.querySelectorAll('.group-workers .assistant').length,
    compactGeometry: [...document.querySelectorAll('.group-review-card')].every((card) => {
      const copy = card.querySelector('.group-review-copy')
      const header = copy?.querySelector('header')
      const body = copy?.querySelector('p')
      if (!copy || !header || !body) return false
      const h = header.getBoundingClientRect()
      const b = body.getBoundingClientRect()
      return h.right <= copy.getBoundingClientRect().right + 1 && h.bottom <= b.top + 1 && card.scrollWidth <= card.clientWidth + 1
    }),
    condensedResponses: [...document.querySelectorAll('.group-result p')].every((body) =>
      body.clientHeight <= 48 && body.scrollHeight > body.clientHeight
    ),
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
  const invalidReviewBlocked = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const parent = state.assistantThreads.find((thread) => thread.group)
    if (!parent) return false
    const attemptId = 'probe-invalid-review-' + Date.now()
    const ids = parent.group.members.map((member) => member.threadId)
    for (const id of ids) {
      state.updateAssistantRuntime(id, (runtime) => ({ ...runtime, lastRun: { attemptId, ok: true, text: 'prose without a structured receipt', completedAt: Date.now() } }))
      state.setThreadBusy(id, false)
    }
    state.setGroupSession(parent.id, { phase: 'reviewing', flow: 'fluid', stageAttemptId: attemptId, stageTargets: ids, stageStatus: Object.fromEntries(ids.map((id) => [id, 'succeeded'])), error: undefined })
    return true
  })()`)
  await wait(180)
  const invalidReviewStoppedMerge = invalidReviewBlocked && await win.webContents.executeJavaScript(`(() => {
    const group = window.__kaisola.getState().assistantThreads.find((thread) => thread.group)?.group
    return group?.phase === 'execution-ready' && /machine-readable|malformed/.test(group?.error ?? '')
  })()`)
  await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    if (group) state.setGroupSession(group.id, { phase: 'execution-ready', flow: 'fluid', error: "Codex's frozen patch is too large for a complete Mesh review." })
  })()`)
  await wait(100)
  const staleReviewRecovery = await win.webContents.executeJavaScript(`/Retry cross-review/.test(document.querySelector('.group-action')?.textContent ?? '')`)
  await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    if (group) state.setGroupSession(group.id, { phase: 'done', error: undefined })
  })()`)
  await wait(80)
  const siteScreenshot = await captureAsset('mesh-light.jpg', '.group-execution')
  const image = await win.webContents.capturePage()
  const screenshot = path.join(os.tmpdir(), 'kaisola-group-session.png')
  fs.writeFileSync(screenshot, image.toPNG())
  const closeReopen = await win.webContents.executeJavaScript(`(() => {
    const before = window.__kaisola.getState()
    const parent = before.assistantThreads.find((thread) => thread.group)
    if (!parent) return { ok: false }
    const parentId = parent.id
    const memberIds = parent.group.members.map((member) => member.threadId)
    before.closeAssistantThread(parentId)
    const closed = window.__kaisola.getState()
    const bundled = closed.closedStack.find((entry) => entry.kind === 'group' && entry.thread?.id === parentId)
    const removedTogether = !closed.assistantThreads.some((thread) => thread.id === parentId || memberIds.includes(thread.id))
    closed.reopenClosedSession(parentId)
    const reopened = window.__kaisola.getState()
    const restoredParent = reopened.assistantThreads.find((thread) => thread.id === parentId)
    const restoredMembers = memberIds.every((id) => reopened.assistantThreads.some((thread) => thread.id === id && thread.queuePaused))
    return {
      ok: !!bundled && removedTogether && restoredParent?.group?.phase === 'done' && restoredMembers,
      bundledThreads: bundled?.groupThreads?.length ?? 0,
      restoredPhase: restoredParent?.group?.phase,
      restoredMembers,
    }
  })()`)
  const deleteArchiveScopes = await win.webContents.executeJavaScript(`(async () => {
    const state = window.__kaisola.getState()
    const parent = state.assistantThreads.find((thread) => thread.group)
    if (!parent) return []
    const scopes = parent.group.members.map((member) => ({
      projectId: state.activeProjectId,
      threadId: member.threadId,
      epoch: 'delete-switch-' + member.threadId,
    }))
    for (const scope of scopes) {
      state.updateAssistantRuntime(scope.threadId, (runtime) => ({ ...runtime, archiveEpoch: scope.epoch }))
      const written = await window.kaisola.assistantArchive.append(scope, 'delete-fixture-' + scope.threadId, [{ kind: 'user', text: 'archive deletion fixture', at: Date.now() }])
      if (!written?.ok) return []
    }
    return scopes
  })()`)
  const deleteLifecycleStart = lifecycleEvents.length
  delayCloseSessions = true
  const openedDeleteMenu = await win.webContents.executeJavaScript(`(() => {
    window.confirm = () => true
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group)
    const tab = group && document.querySelector('.stab[data-sid="' + group.id + '"] > .stab-select')
    if (!tab) return { opened: false }
    tab.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 140, clientY: 120 }))
    return { opened: true, originProjectId: state.activeProjectId, groupId: group.id }
  })()`)
  await wait(120)
  const clickedDelete = openedDeleteMenu.opened && await win.webContents.executeJavaScript(`(() => {
    const action = [...document.querySelectorAll('.tree-menu-danger')].find((button) => /Delete permanently/.test(button.textContent))
    if (!action) return false
    action.click()
    return true
  })()`)
  await wait(25)
  const switchedProjectId = clickedDelete && await win.webContents.executeJavaScript(`window.__kaisola.getState().newProject({ focus: true })`)
  let deleted = false
  for (let i = 0; i < 80; i++) {
    deleted = await win.webContents.executeJavaScript(`(() => {
      const state = window.__kaisola.getState()
      const origin = state.projectSlices[${JSON.stringify(openedDeleteMenu.originProjectId)}]
      return !!origin && !origin.assistantThreads.some((thread) => thread.id === ${JSON.stringify(openedDeleteMenu.groupId)}) && !origin.closedStack.some((entry) => entry.thread?.id === ${JSON.stringify(openedDeleteMenu.groupId)})
    })()`)
    if (deleted) break
    await wait(50)
  }
  delayCloseSessions = false
  const projectSwitchSafe = !!switchedProjectId && await win.webContents.executeJavaScript(`window.__kaisola.getState().activeProjectId === ${JSON.stringify(switchedProjectId)}`)
  const archiveDeleteVerified = deleteArchiveScopes.length === 2 && await win.webContents.executeJavaScript(`(async () => {
    const scopes = ${JSON.stringify(deleteArchiveScopes)}
    const results = await Promise.all(scopes.map((scope) => window.kaisola.assistantArchive.info(scope)))
    return results.every((result) => result?.ok && result.total === 0)
  })()`)
  const deleteLifecycle = lifecycleEvents.slice(deleteLifecycleStart)
  const deleteKeys = [...promptCounts.keys()].filter((key) => key.includes('::'))
  const deleteTeardownOrdered = deleteKeys.length === 2 && deleteKeys.every((key) =>
    deleteLifecycle.filter((event) => event[1] === key).map((event) => event[0]).join(',') === 'cancel,close,disconnect')
  const sessionDraftRoundTrip = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    state.requestNewThread('codex')
    const created = window.__kaisola.getState().assistantThreads.at(-1)
    if (!created) return false
    window.__kaisola.getState().setAssistantDraft(created.id, { text: 'preserve this draft' })
    window.__kaisola.getState().enqueueAssistantPrompt(created.id, { text: 'preserve this queued follow-up', attachments: [], mentions: [], speed: 'default' })
    window.__kaisola.getState().closeAssistantThread(created.id)
    window.__kaisola.getState().reopenClosedSession(created.id)
    const restored = window.__kaisola.getState()
    return restored.assistantDrafts[created.id]?.text === 'preserve this draft'
      && restored.assistantPromptQueues[created.id]?.[0]?.text === 'preserve this queued follow-up'
      && restored.assistantThreads.find((thread) => thread.id === created.id)?.queuePaused === true
  })()`)
  // ── Idea mode: bounded group-chat cycles, zero repository machinery ──────
  const ideaStarted = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    state.setWorkspace(${JSON.stringify(workspace)})
    state.requestNewGroup()
    const next = window.__kaisola.getState()
    const group = next.assistantThreads.find((thread) => thread.group && thread.group.phase === 'idle')
    if (!group) return false
    next.setGroupSession(group.id, { purpose: 'idea' })
    return true
  })()`)
  await wait(400)
  const sendIdeaMessage = async (text) => win.webContents.executeJavaScript(`(() => {
    const input = document.querySelector('.group-composer textarea')
    const send = document.querySelector('.group-primary')
    if (!input || !send) return false
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set
    setter.call(input, ${JSON.stringify(text)})
    input.dispatchEvent(new Event('input', { bubbles: true }))
    send.click()
    return true
  })()`)
  const ideaAsked = ideaStarted && await sendIdeaMessage('Pitch: a plugin bazaar for Kaisola.')
  const ideaCycle1 = ideaAsked && await waitForPhase('idea-ready')
  const ideaFacts1 = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group?.purpose === 'idea')
    const transcript = group?.group?.ideaTranscript ?? []
    return {
      phase: group?.group?.phase,
      kinds: transcript.map((message) => message.kind).join(','),
      initialOrder: transcript.filter((message) => message.kind === 'initial').map((message) => message.label).join(','),
      domMessages: document.querySelectorAll('.group-idea-msg').length,
      worktrees: Object.keys(group?.group?.worktrees ?? {}).length,
      buildSections: document.querySelectorAll('.group-results-wrap, .group-execution, .group-contract').length,
    }
  })()`)
  const ideaAskedAgain = ideaCycle1 && await sendIdeaMessage('Second push: how would pricing work?')
  const ideaCycle2 = ideaAskedAgain && await waitForPhase('idea-ready')
  // A settled cycle must stay settled: no automatic second reaction pass.
  await wait(800)
  const ideaFacts2 = await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    const group = state.assistantThreads.find((thread) => thread.group?.purpose === 'idea')
    const transcript = group?.group?.ideaTranscript ?? []
    return {
      phase: group?.group?.phase,
      kinds: transcript.map((message) => message.kind).join(','),
      domMessages: document.querySelectorAll('.group-idea-msg').length,
    }
  })()`)
  const ideaWorktreesOnDisk = execFileSync('git', ['worktree', 'list', '--porcelain'], { cwd: workspace, encoding: 'utf8' })
    .split('\n').filter((line) => line.startsWith('worktree ')).length - 1
  const ideaSeq = {}
  for (const [key, kind, text] of ideaPrompts) { (ideaSeq[key.split('::')[0]] ??= []).push([kind, text]) }
  const ideaPromptTotal = ideaPrompts.length
  const ideaFlow = ['claude-code', 'codex'].every((preset) => {
    const seq = ideaSeq[preset] ?? []
    if (seq.map((entry) => entry[0]).join(',') !== 'initial,reaction,initial,reaction') return false
    const own = preset === 'claude-code' ? 'Claude' : 'Codex'
    const peer = preset === 'claude-code' ? 'Codex' : 'Claude'
    return !seq[0][1].includes('initial thought') // first pass carries no peer content
      && seq[0][1].includes('Pitch: a plugin bazaar')
      && seq[1][1].includes(`${peer} initial thought #1`) // reaction sees every peer initial…
      && !seq[1][1].includes(`${own} initial thought`) // …but never the member's own
      && seq[1][1].includes('Pitch: a plugin bazaar') // …plus the original user message
      && seq[2][1].includes(`${peer} reaction building #1`) // unseen carryover into cycle 2
      && !seq[2][1].includes(`${own} reaction building`)
      && !seq[2][1].includes('initial thought #1') // already seen in cycle 1's reaction pass
      && seq[2][1].includes('pricing')
      && seq[3][1].includes(`${peer} initial thought #2`)
      && seq[3][1].includes('pricing')
  })

  const result = { configured, effortWire, saturated, asked, stopped, paused, pausedPersisted: !!pausedPersisted, pausedScreenshot, pausedCloseReopen, continued, adoptedBusyRecovered, selectiveResume, ready, parkedBeforeNegotiation, fluidEnabled, connectCalls, negotiated, assigned, doubleExecuteClaimed, isolatedWorktreeCount, executed, reviewed, largeReviewRouted, done, worktreeCleanupDone, ...facts, persisted, invalidReviewStoppedMerge, staleReviewRecovery, siteScreenshot, screenshot, closeReopen, openedDeleteMenu, clickedDelete, switchedProjectId, deleted, projectSwitchSafe, archiveDeleteVerified, deleteTeardownOrdered, sessionDraftRoundTrip, ideaStarted, ideaAsked, ideaCycle1, ideaFacts1, ideaCycle2, ideaFacts2, ideaWorktreesOnDisk, ideaPromptTotal, ideaFlow, deleteLifecycle }
  console.log('GROUP_UI=' + JSON.stringify(result))
  const passed = configured
    && effortWire === 'claude-code:xhigh,codex:xhigh'
    && saturated
    && asked
    && stopped
    && paused
    && pausedPersisted
    && pausedCloseReopen.ok
    && pausedCloseReopen.bundledThreads === 3
    && continued
    && adoptedBusyRecovered
    && selectiveResume.map((entry) => entry.join(':')).join(',') === 'claude-code:1,codex:2'
    && ready
    && parkedBeforeNegotiation
    && fluidEnabled
    && connectCalls >= 4
    && negotiated
    && assigned
    && doubleExecuteClaimed
    && isolatedWorktreeCount === 2
    && executed
    && reviewed
    && largeReviewRouted
    && done
    && worktreeCleanupDone
    && facts.phase === 'done'
    && facts.visibleGroupTabs === 1
    && facts.leakedWorkerTabs === 0
    && facts.answers.length === 2
    && facts.negotiations === 2
    && facts.reviews === 2
    && facts.reviewReceipts === 2
    && facts.executions === 2
    && facts.worktrees === 0
    && facts.memberModels.join(',') === 'Claude Fast,Codex Deep'
    && facts.flow === 'fluid'
    && facts.changedFiles.join(',') === 'claude-result.txt,codex-result.txt'
    && facts.roleContract.startsWith('Mission intent')
    && facts.integration === 'Integrated both reviewed branches and verified the shared acceptance tests.'
    && facts.workerCount === 2
    && facts.compactGeometry
    && facts.condensedResponses
    && persisted.phase === 'done'
    && persisted.members === 2
    && persisted.integration === 'Integrated both reviewed branches and verified the shared acceptance tests.'
    && persisted.worktrees === 0
    && persisted.visible
    && invalidReviewStoppedMerge
    && staleReviewRecovery
    && closeReopen.ok
    && closeReopen.bundledThreads === 3
    && clickedDelete
    && deleted
    && projectSwitchSafe
    && archiveDeleteVerified
    && deleteTeardownOrdered
    && sessionDraftRoundTrip
    && ideaStarted
    && ideaAsked
    && ideaCycle1
    && ideaFacts1.phase === 'idea-ready'
    && ideaFacts1.kinds === 'user,initial,initial,reaction,reaction'
    && ideaFacts1.initialOrder === 'Claude,Codex'
    && ideaFacts1.domMessages === 5
    && ideaFacts1.worktrees === 0
    && ideaFacts1.buildSections === 0
    && ideaCycle2
    && ideaFacts2.phase === 'idea-ready'
    && ideaFacts2.kinds === 'user,initial,initial,reaction,reaction,user,initial,initial,reaction,reaction'
    && ideaFacts2.domMessages === 10
    && ideaWorktreesOnDisk === 0
    && ideaPromptTotal === 8
    && ideaFlow
  killAllSessions()
  await wait(250)
  app.exit(passed ? 0 : 1)
}).catch(async (error) => {
  console.error(error)
  killAllSessions()
  await wait(250)
  app.exit(1)
})
