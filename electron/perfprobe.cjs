// Real-renderer performance harness.
//
//   electron electron/perfprobe.cjs E     Eco memory/material sample
//   electron electron/perfprobe.cjs G     Live Glass memory/material sample
//   electron electron/perfprobe.cjs NAV   project-tab + OS-window latency/continuity
//   electron electron/perfprobe.cjs LIFE  switch/open/close retained-memory lifecycle
const { app, BrowserWindow, ipcMain } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fs = require('node:fs')
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
const { registerExtensionHandlers } = require('./ipc/extensionHandler.cjs')
const { registerAssistantArchiveHandlers } = require('./ipc/assistantArchive.cjs')
const { evaluateLifecycleRun } = require('./memoryAudit.cjs')
const worktree = require('./ipc/worktreeHandler.cjs')

process.env.KAISOLA_SMOKE = '1'
const arg = String(process.argv.at(-1) || 'A').toUpperCase()
const scenario = arg === 'NAV' || arg === 'LIFE' ? arg : null
const variant = scenario ? 'E' : (/^[ABCGE]$/.test(arg) ? arg : 'A')
const solidWindow = scenario !== null || variant === 'E'
if (scenario === 'LIFE') app.commandLine.appendSwitch('js-flags', '--expose-gc')
const userData = path.join(os.tmpdir(), `kaisola-perfprobe-${scenario || variant}-${process.pid}`)
const fixtureRoot = path.join(userData, 'workspaces')
fs.rmSync(userData, { recursive: true, force: true })
fs.mkdirSync(fixtureRoot, { recursive: true })
app.setPath('userData', userData)

const fixtures = Array.from({ length: 4 }, (_, index) => {
  const dir = path.join(fixtureRoot, `project-${index + 1}`)
  const file = path.join(dir, `project-${index + 1}.md`)
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(file, `# Project ${index + 1} document\n\nContinuity marker ${index + 1}.\n\n${'Warm navigation content. '.repeat(120)}\n`)
  return { index, dir, file, marker: `Project ${index + 1} document`, sentinel: `__KAISOLA_NAV_${index + 1}__` }
})

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const round = (value, digits = 1) => Number(Number(value).toFixed(digits))
const percentile = (values, value) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.max(0, Math.ceil(sorted.length * value) - 1)] ?? 0
}
const stats = (values) => ({
  count: values.length,
  medianMs: round(percentile(values, 0.5), 2),
  p95Ms: round(percentile(values, 0.95), 2),
  minMs: round(Math.min(...values), 2),
  maxMs: round(Math.max(...values), 2),
})

function totalWorkingSetMiB() {
  return app.getAppMetrics().reduce((sum, metric) => sum + (Number(metric.memory?.workingSetSize) || 0), 0) / 1024
}

async function memorySample(count = 5, gapMs = 120) {
  const values = []
  for (let i = 0; i < count; i += 1) {
    values.push(totalWorkingSetMiB())
    if (i + 1 < count) await wait(gapMs)
  }
  const sorted = [...values].sort((a, b) => a - b)
  const byTypeMiB = {}
  for (const metric of app.getAppMetrics()) {
    byTypeMiB[metric.type] = round((byTypeMiB[metric.type] || 0) + (Number(metric.memory?.workingSetSize) || 0) / 1024)
  }
  return {
    medianMiB: round(percentile(sorted, 0.5)),
    minMiB: round(sorted[0]),
    maxMiB: round(sorted.at(-1)),
    dispersionMiB: round(sorted.at(-1) - sorted[0]),
    processCount: app.getAppMetrics().length,
    byTypeMiB,
  }
}

function createWindow(query = { solidwin: '1' }, show = true) {
  return new BrowserWindow({
    show,
    width: 1280,
    height: 800,
    frame: false,
    transparent: !solidWindow,
    backgroundColor: solidWindow ? '#ffffff' : '#00000000',
    ...(solidWindow ? {} : { vibrancy: 'under-window', visualEffectState: 'active' }),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: true,
      plugins: true,
      backgroundThrottling: false,
    },
  })
}

const execute = (win, code) => win.webContents.executeJavaScript(code, true)

async function waitForRenderer(win, expression, timeoutMs = 8_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (!win.isDestroyed() && await execute(win, `Promise.resolve(${expression}).then(Boolean)`)) return true
    await wait(40)
  }
  return false
}

async function configureProject(win, fixture, createNew) {
  const start = performance.now()
  const identity = await execute(win, `(async () => {
    const state = window.__kaisola.getState()
    if (${createNew}) state.newProject({ path: ${JSON.stringify(fixture.dir)}, focus: true })
    else state.setWorkspace(${JSON.stringify(fixture.dir)})
    const current = window.__kaisola.getState()
    const projectId = current.activeProjectId
    current.requestFile(${JSON.stringify(fixture.file)}, 'edit', { pinned: true })
    current.requestNewThread('codex')
    const threadId = window.__kaisola.getState().activeThreadId
    const before = new Set(window.__kaisola.getState().terminals.map((terminal) => terminal.id))
    window.__kaisola.getState().requestTerminal(undefined, { cwd: ${JSON.stringify(fixture.dir)}, name: 'Navigation probe', reveal: true })
    const after = window.__kaisola.getState()
    const termId = after.terminals.find((terminal) => !before.has(terminal.id))?.id
    if (threadId) after.addDockSplit(threadId)
    if (termId) after.setTermDraft(termId, ${JSON.stringify(`draft-${fixture.index + 1}`)})
    if (threadId) after.updateAssistantRuntime(threadId, (runtime) => ({
      ...runtime,
      turns: [{ kind: 'assistant', at: Date.now(), text: ${JSON.stringify(`agent-state-${fixture.index + 1}`)} }],
      first: false,
    }))
    after.setInbox(true)
    return { projectId, termId, threadId, file: ${JSON.stringify(fixture.file)}, marker: ${JSON.stringify(fixture.marker)}, sentinel: ${JSON.stringify(fixture.sentinel)} }
  })()`)
  const ready = await waitForRenderer(win, `(() => {
    const state = window.__kaisola.getState()
    return state.activeProjectId === ${JSON.stringify(identity.projectId)}
      && state.openFilePath === ${JSON.stringify(identity.file)}
      && !![...document.querySelectorAll('.session-card[data-show="true"]')].find((card) => card.dataset.sessionId === ${JSON.stringify(identity.termId)})
      && (document.querySelector('.fx-doc-page')?.textContent || '').includes(${JSON.stringify(identity.marker)})
  })()`)
  if (!ready) {
    const detail = await execute(win, `(() => {
      const state = window.__kaisola.getState()
      return {
        activeProjectId: state.activeProjectId,
        openFilePath: state.openFilePath,
        fileRequest: state.fileRequest,
        dockGrid: state.dockGrid,
        visibleCards: [...document.querySelectorAll('.session-card[data-show="true"]')].map((card) => card.dataset.sessionId),
        documentText: (document.querySelector('.fx-doc-page')?.textContent || '').slice(0, 80),
      }
    })()`)
    throw new Error(`Project ${fixture.index + 1} did not become ready: ${JSON.stringify(detail)}`)
  }
  const terminalReady = await waitForRenderer(win, `window.kaisola.terminal.diagnostics(${JSON.stringify(identity.projectId)}).then((rows) => rows.some((row) => row.id === ${JSON.stringify(identity.termId)} && row.pid))`)
  if (!terminalReady) throw new Error(`Project ${fixture.index + 1} terminal did not attach.`)
  await execute(win, `window.kaisola.terminal.write(${JSON.stringify(identity.termId)}, ${JSON.stringify(`printf '${fixture.sentinel}\\n'\n`)}, ${JSON.stringify(identity.projectId)})`)
  await wait(180)
  const diagnostics = await execute(win, `window.kaisola.terminal.diagnostics(${JSON.stringify(identity.projectId)})`)
  const row = diagnostics.find((candidate) => candidate.id === identity.termId)
  return { ...identity, terminalPid: row?.pid, coldMs: round(performance.now() - start, 2) }
}

async function switchSequence(win, projects, count, offset = 0) {
  return execute(win, `(async () => {
    const projects = ${JSON.stringify(projects)}
    const rows = []
    for (let index = 0; index < ${count}; index += 1) {
      const target = projects[(${offset} + index) % projects.length]
      const start = performance.now()
      let staleFrames = 0
      window.__kaisola.getState().switchProject(target.projectId)
      const ready = () => {
        const state = window.__kaisola.getState()
        const activeTab = [...document.querySelectorAll('.ptab[data-project-id]')].some((tab) => tab.dataset.projectId === target.projectId && tab.dataset.active === 'true')
        const terminal = [...document.querySelectorAll('.session-card[data-show="true"]')].some((card) => card.dataset.sessionId === target.termId)
        const documentReady = (document.querySelector('.fx-doc-page')?.textContent || '').includes(target.marker)
        const agent = [...document.querySelectorAll('.session-card[data-show="true"]')].some((card) => card.dataset.sessionId === target.threadId)
        return state.activeProjectId === target.projectId && state.openFilePath === target.file && activeTab && terminal && documentReady && agent
      }
      while (!ready() && performance.now() - start < 2_000) {
        staleFrames += 1
        await new Promise((resolve) => requestAnimationFrame(resolve))
      }
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
      rows.push({ ms: performance.now() - start, staleFrames, ready: ready() })
    }
    return rows
  })()`)
}

async function switchAndPaint(win, project) {
  return (await switchSequence(win, [project], 1))[0]
}

async function continuityFor(win, project) {
  await switchAndPaint(win, project)
  return execute(win, `(async () => {
    const target = ${JSON.stringify(project)}
    const state = window.__kaisola.getState()
    const diagnostics = await window.kaisola.terminal.diagnostics(target.projectId)
    const row = diagnostics.find((candidate) => candidate.id === target.termId)
    const snapshot = await window.kaisola.terminal.snapshot(target.termId, target.projectId)
    const runtime = state.assistantRuntimes[target.threadId]
    return {
      projectId: target.projectId,
      pidBefore: target.terminalPid,
      pidAfter: row?.pid,
      pidStable: !!target.terminalPid && row?.pid === target.terminalPid,
      output: snapshot.output.includes(target.sentinel),
      scrollbackBytes: snapshot.output.length,
      draft: state.termDrafts[target.termId] === ${JSON.stringify(`draft-${project.index + 1}`)},
      agent: state.assistantThreads.some((thread) => thread.id === target.threadId) && runtime?.turns?.some((turn) => turn.text === ${JSON.stringify(`agent-state-${project.index + 1}`)}),
      activeFile: state.openFilePath === target.file,
      notificationSetting: state.inbox === true,
    }
  })()`)
}

async function activateWindow(win) {
  const start = performance.now()
  win.show()
  win.moveTop()
  win.focus()
  const deadline = Date.now() + 2_000
  while (!win.isFocused() && Date.now() < deadline) await wait(4)
  const rendererFocused = await execute(win, `new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(document.hasFocus()))))`)
  return { ms: performance.now() - start, focused: win.isFocused() && rendererFocused }
}

async function runNavigationProbe(win) {
  await execute(win, `window.__kaisola.getState().setThemeMode('light'); window.__kaisola.setState({ perfMode: 'glass' }); localStorage.setItem('kaisola:hidden-terminal-residents', '1')`)
  const projects = []
  for (let i = 0; i < 3; i += 1) projects.push({ ...fixtures[i], ...(await configureProject(win, fixtures[i], i > 0)) })
  const memoryBefore = await memorySample()
  const warm = await switchSequence(win, projects, 36)
  const continuity = []
  for (const project of projects) continuity.push(await continuityFor(win, project))

  const secondStart = performance.now()
  const second = createWindow({ solidwin: '1', win: 'perf-window-2' }, true)
  await second.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1', win: 'perf-window-2' } })
  const secondMounted = await waitForRenderer(second, `document.querySelector('.app')`)
  if (!secondMounted) throw new Error('Second window did not mount.')
  const osColdMs = performance.now() - secondStart
  await execute(second, `window.__kaisola.getState().setThemeMode('light'); window.__kaisola.setState({ perfMode: 'glass' })`)
  const secondProject = { ...fixtures[3], ...(await configureProject(second, fixtures[3], false)) }
  const activation = []
  for (let i = 0; i < 30; i += 1) activation.push(await activateWindow(i % 2 === 0 ? win : second))
  const secondContinuity = await continuityFor(second, secondProject)
  const memoryAfter = await memorySample()

  const warmMs = warm.map((row) => row.ms)
  const activationMs = activation.map((row) => row.ms)
  const result = {
    scenario: 'navigation',
    projects: projects.length,
    warmSwitches: stats(warmMs),
    warmStaleFrames: warm.reduce((sum, row) => sum + row.staleFrames, 0),
    warmReady: warm.every((row) => row.ready),
    coldProjectMs: projects.map((project) => project.coldMs),
    osWindowColdMs: round(osColdMs, 2),
    osWindowActivations: stats(activationMs),
    osWindowFocused: activation.every((row) => row.focused),
    processMemory: { before: memoryBefore, after: memoryAfter, deltaMiB: round(memoryAfter.medianMiB - memoryBefore.medianMiB) },
    continuity: [...continuity, secondContinuity],
  }
  result.pass = result.warmReady
    && result.warmSwitches.p95Ms <= 150
    && result.warmSwitches.maxMs <= 250
    && result.osWindowFocused
    && result.osWindowActivations.p95Ms <= 150
    && result.osWindowActivations.maxMs <= 250
    && result.continuity.every((row) => row.pidStable && row.output && row.draft && row.agent && row.activeFile && row.notificationSetting)
  console.log('NAVIGATION_PROBE=' + JSON.stringify(result))
  second.destroy()
  return result.pass
}

async function runLifecycleProbe(win) {
  const residentCap = Math.max(0, Math.min(8, Number(process.env.KAISOLA_LIFE_RESIDENTS) || 0))
  const openClosePerBatch = Math.max(0, Math.min(30, process.env.KAISOLA_LIFE_OPEN_CLOSE == null ? 12 : Number(process.env.KAISOLA_LIFE_OPEN_CLOSE)))
  const switchesPerBatch = Math.max(0, Math.min(60, process.env.KAISOLA_LIFE_SWITCHES == null ? 18 : Number(process.env.KAISOLA_LIFE_SWITCHES)))
  await execute(win, `window.__kaisola.getState().setThemeMode('light'); window.__kaisola.setState({ perfMode: 'eco' }); localStorage.setItem('kaisola:hidden-terminal-residents', ${JSON.stringify(String(residentCap))})`)
  const projects = []
  for (let i = 0; i < 3; i += 1) projects.push({ ...fixtures[i], ...(await configureProject(win, fixtures[i], i > 0)) })
  // Establish a stabilized baseline. Chromium, xterm, and the JS allocator all
  // retain bounded reusable arenas after their first several remounts; counting
  // that one-time warm-up as a leak produces a false lifecycle failure. Exercise
  // the exact switch and OS-window paths once before measuring repeat cycles.
  await switchSequence(win, projects, 45)
  const warmWindow = createWindow({ solidwin: '1', win: 'life-warm' }, false)
  await warmWindow.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1', win: 'life-warm' } })
  await waitForRenderer(warmWindow, `document.querySelector('.app')`)
  warmWindow.destroy()
  const gcExposed = await execute(win, `typeof window.gc === 'function'`)
  // Compare settled retention at every point. A single renderer GC followed
  // by 350 ms measured Chromium's deferred allocator work as though it were a
  // leak, while the final sample received two GCs and three seconds to settle.
  // Keep the cap and monotonic-growth gate strict, but give the baseline,
  // checkpoints, and final result the same collection protocol.
  const settledMemorySample = async () => {
    await execute(win, `window.gc?.()`)
    await wait(1_000)
    await execute(win, `window.gc?.()`)
    await wait(1_000)
    return memorySample(3, 80)
  }
  const lifecycleDiagnostics = () => execute(win, `(() => {
    const state = window.__kaisola.getState()
    const memory = performance.memory
    return {
      usedJsHeapMiB: memory ? Math.round(memory.usedJSHeapSize / 104857.6) / 10 : null,
      totalJsHeapMiB: memory ? Math.round(memory.totalJSHeapSize / 104857.6) / 10 : null,
      domNodes: document.getElementsByTagName('*').length,
      canvases: document.querySelectorAll('canvas').length,
      xterms: document.querySelectorAll('.xterm').length,
      projectTabs: state.projectTabs.length,
      projectSlices: Object.keys(state.projectSlices).length,
      closedProjects: state.closedProjectStack.length,
      terminalMeta: Object.keys(state.terminalMeta).length,
      termRemounts: Object.keys(state.termRemounts).length,
      termDrafts: Object.keys(state.termDrafts).length,
    }
  })()`)
  const baseline = await settledMemorySample()
  const baselineDiagnostics = await lifecycleDiagnostics()
  const checkpoints = []
  const checkpointDiagnostics = []
  for (let batch = 0; batch < 5; batch += 1) {
    await execute(win, `(() => {
      const state = window.__kaisola.getState()
      const ids = []
      for (let i = 0; i < ${openClosePerBatch}; i += 1) ids.push(state.newProject({ path: null, focus: false }))
      for (const id of ids) state.closeProject(id)
    })()`)
    await switchSequence(win, projects, switchesPerBatch, batch)
    checkpoints.push(await settledMemorySample())
    checkpointDiagnostics.push(await lifecycleDiagnostics())
  }
  const teardownWindows = []
  for (let i = 0; i < 3; i += 1) {
    const extra = createWindow({ solidwin: '1', win: `life-${i}` }, false)
    await extra.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1', win: `life-${i}` } })
    await waitForRenderer(extra, `document.querySelector('.app')`)
    teardownWindows.push(extra)
  }
  for (const extra of teardownWindows) extra.destroy()
  const retained = await settledMemorySample()
  const retainedDiagnostics = await lifecycleDiagnostics()
  const continuity = []
  for (const project of projects) continuity.push(await continuityFor(win, project))
  const audit = evaluateLifecycleRun({
    baseline,
    baselineDiagnostics,
    checkpoints,
    checkpointDiagnostics,
    retained,
    retainedDiagnostics,
    continuity,
  })
  const result = {
    scenario: 'lifecycle',
    baseline,
    baselineDiagnostics,
    checkpoints,
    checkpointDiagnostics,
    retained,
    retainedDiagnostics,
    ...audit,
    cycles: { warmupSwitches: 45, projectOpenClose: openClosePerBatch * 5, warmSwitches: switchesPerBatch * 5, osWindowOpenClose: teardownWindows.length },
    gcExposed,
    residentCap,
    continuity,
  }
  console.log('MEMORY_LIFECYCLE=' + JSON.stringify(result))
  return result.pass
}

const VARIANT_CSS = {
  A: '',
  B: `.session-card, .canvas-wrap > .canvas { background: var(--bg-1) !important; backdrop-filter: none !important; -webkit-backdrop-filter: none !important; }`,
  C: `.session-card, .canvas-wrap > .canvas { background: var(--bg-1) !important; backdrop-filter: none !important; -webkit-backdrop-filter: none !important; } .app::before { backdrop-filter: none !important; -webkit-backdrop-filter: none !important; }`,
}

async function runMaterialProbe(win) {
  let material = solidWindow ? 'solid' : 'vibrancy'
  if (variant === 'G' && process.platform === 'darwin') {
    try {
      const liquidGlass = require('electron-liquid-glass')
      const id = liquidGlass.addView(win.getNativeWindowHandle(), { cornerRadius: 24 })
      if (id != null && id >= 0) {
        material = 'liquid-glass'
        if (typeof win.setVibrancy === 'function') win.setVibrancy(null)
      }
    } catch { /* production uses the same vibrancy fallback */ }
  }
  await wait(1200)
  if (variant === 'E' || variant === 'G') {
    await execute(win, `window.__kaisola.getState().setThemeMode('light'); window.__kaisola.setState({ perfMode: ${JSON.stringify(variant === 'E' ? 'eco' : 'glass')} })`)
    await wait(600)
  }
  const css = VARIANT_CSS[variant]
  if (css) await win.webContents.insertCSS(css)
  await execute(win, `window.__kaisola.getState().requestTerminal()`)
  await wait(4500)
  const termId = await execute(win, `window.__kaisola.getState().terminals[0]?.id ?? ''`)
  if (termId) {
    const spinner = `while :; do printf '\\033[H'; for i in 1 2 3 4 5 6 7 8 9 10; do printf '── streaming line %s %s ──────────────────────\\033[K\\n' "$i" "$RANDOM"; done; sleep 0.08; done\n`
    await execute(win, `window.kaisola.terminal.write(${JSON.stringify(termId)}, ${JSON.stringify(spinner)}, window.__kaisola.getState().activeProjectId)`)
  }
  await wait(1500)
  const len1 = termId ? await execute(win, `window.kaisola.terminal.snapshot(${JSON.stringify(termId)}, window.__kaisola.getState().activeProjectId).then((snapshot) => snapshot.output.length)`) : 0
  await wait(1000)
  const len2 = termId ? await execute(win, `window.kaisola.terminal.snapshot(${JSON.stringify(termId)}, window.__kaisola.getState().activeProjectId).then((snapshot) => snapshot.output.length)`) : 0
  console.log(`PROBE_READY variant=${variant} pid=${process.pid} solid=${solidWindow} material=${material} term=${termId || 'NONE'} spinner=${len2 > len1 ? 'FLOWING' : 'STALLED'} (+${len2 - len1}b/s)`)
  const sample = await memorySample(8, 700)
  const byType = {}
  for (const metric of app.getAppMetrics()) byType[metric.type] = round((Number(metric.memory?.workingSetSize) || 0) / 1024)
  console.log('PROBE_MEMORY=' + JSON.stringify({ variant, material, ...sample, byTypeMiB: byType }))
  return true
}

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerExtensionHandlers(ipcMain)
  registerAssistantArchiveHandlers(ipcMain, path.join(userData, 'assistant-archives'))
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: solidWindow, liveSolid: solidWindow }))
  ipcMain.handle('window:list-saved', () => ({ ok: true, windows: [] }))
  ipcMain.handle('window:reopen-saved', () => ({ ok: false, missing: true }))
  ipcMain.handle('window:delete-saved', () => ({ ok: false, missing: true }))
  ipcMain.handle('window:popped', () => ({ ok: true, termIds: [], states: [], closed: [] }))
  ipcMain.handle('window:pop-closed-ack', () => ({ ok: false }))
  ipcMain.on('window:terminal-state', () => {})
  ipcMain.handle('glass:sample', () => ({ ok: false }))
  ipcMain.handle('mcp:info', () => ({ ok: false }))
  ipcMain.handle('mcp:servers', () => [])
  ipcMain.handle('mcp:discover', () => [])

  const win = createWindow({ solidwin: solidWindow ? '1' : '0' }, true)
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), solidWindow ? { query: { solidwin: '1' } } : undefined)
  const mounted = await waitForRenderer(win, `document.querySelector('.app')`)
  if (!mounted) throw new Error('Primary probe window did not mount.')
  const pass = scenario === 'NAV'
    ? await runNavigationProbe(win)
    : scenario === 'LIFE'
      ? await runLifecycleProbe(win)
      : await runMaterialProbe(win)
  killAllSessions()
  await wait(200)
  app.exit(pass ? 0 : 1)
}).catch((error) => {
  console.error(`${scenario === 'NAV' ? 'NAVIGATION_PROBE' : scenario === 'LIFE' ? 'MEMORY_LIFECYCLE' : 'PROBE_MEMORY'}=FAIL`, error)
  killAllSessions()
  app.exit(1)
})
