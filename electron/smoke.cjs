// Headless render smoke test. Verifies: the app mounts, the minimal IDE shell
// renders, Files/agents/terminals work, and core workflows still avoid runtime
// regressions. Exits non-zero on any failure.
const { app, BrowserWindow, ipcMain, nativeImage } = require('electron')
const path = require('node:path')
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
const { registerLatexHandlers } = require('./ipc/latexHandler.cjs')
const { registerClaudeHooksHandlers } = require('./ipc/claudeHooksHandler.cjs')
const worktree = require('./ipc/worktreeHandler.cjs')

process.env.KAISOLA_SMOKE = '1' // never auto-open a real browser during the test
const errors = []
const SMOKE_MAC_VIBRANCY = 'under-window'
app.disableHardwareAcceleration()
// isolated, ephemeral userData so the persisted DB + localStorage start empty
// each run (no demo/agent state leaks between runs).
const os = require('node:os')
const fsx = require('node:fs')
const SMOKE_USERDATA = path.join(os.tmpdir(), 'kaisola-smoke-userdata')
try { fsx.rmSync(SMOKE_USERDATA, { recursive: true, force: true }) } catch { /* fresh */ }
app.setPath('userData', SMOKE_USERDATA)

function smokePdf(label) {
  const stream = `BT /F1 18 Tf 20 50 Td (${label}) Tj ET\n`
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 120] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${Buffer.byteLength(stream, 'utf8')} >>\nstream\n${stream}endstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ]
  let body = '%PDF-1.4\n'
  const offsets = [0]
  objects.forEach((object, index) => {
    offsets[index + 1] = Buffer.byteLength(body, 'utf8')
    body += `${index + 1} 0 obj\n${object}\nendobj\n`
  })
  const xref = Buffer.byteLength(body, 'utf8')
  body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
  for (let i = 1; i <= objects.length; i += 1) body += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
  return body
}

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain)
  registerToolHandlers(ipcMain)
  registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain)
  registerAcpHandlers(ipcMain)
  registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain)
  registerGrobidHandlers(ipcMain)
  registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain)
  registerCodexHandlers(ipcMain)
  registerGitHandlers(ipcMain)
  registerLatexHandlers(ipcMain)
  registerClaudeHooksHandlers(ipcMain)
  // Liquid Glass prefs are cosmetic; the smoke shell answers with "unsupported"
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  worktree.registerWorktreeHandlers(ipcMain)

  // tear-off support: a minimal replica of main.cjs's window:detach-project —
  // spawn a second harness window in adoption mode and hand it the project
  const pendingAdoptions = new Map()
  ipcMain.handle('window:detach-project', (_e, payload = {}) => {
    if (!payload.tab || !payload.slice) return { ok: false }
    const w2 = new BrowserWindow({
      show: false,
      width: 900,
      height: 600,
      webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, webviewTag: true, plugins: true },
    })
    pendingAdoptions.set(w2.webContents.id, { tab: payload.tab, slice: payload.slice })
    w2.webContents.on('did-finish-load', () => {
      const a = pendingAdoptions.get(w2.webContents.id)
      if (a) {
        pendingAdoptions.delete(w2.webContents.id)
        w2.webContents.send('tab:adopt', a)
      }
    })
    void w2.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { adopt: '1', win: 'detach-smoke' } })
    return { ok: true }
  })

  const win = new BrowserWindow({
    show: false,
    width: 1440,
    height: 900,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    ...(process.platform === 'darwin' ? { vibrancy: SMOKE_MAC_VIBRANCY, visualEffectState: 'active', roundedCorners: true } : {}),
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, webviewTag: true, plugins: true },
  })
  win.webContents.on('console-message', (_e, level, message) => {
    if (level >= 3) errors.push(`console.error: ${message}`)
  })
  win.webContents.on('render-process-gone', (_e, d) => errors.push(`render-process-gone: ${d.reason}`))
  win.webContents.on('zoom-changed', (event, zoomDirection) => {
    event.preventDefault()
    win.webContents.setZoomFactor(1)
    if (zoomDirection === 'in' || zoomDirection === 'out') {
      win.webContents.send('files:text-zoom-gesture', { direction: zoomDirection })
    }
  })

  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  await new Promise((r) => setTimeout(r, 700))
  // the store now persists to localStorage — clear it so the run starts empty
  await win.webContents.executeJavaScript(`(() => { try { localStorage.removeItem('kaisola-store') } catch (e) {} ; window.__kaisola.getState().clearProject() })()`)
  await new Promise((r) => setTimeout(r, 200))

  const rootChildren = await win.webContents.executeJavaScript(`document.getElementById('root').children.length`)
  const minimalShell = await win.webContents.executeJavaScript(`(() => ({
    noWorkflowSidebar: !document.querySelector('.sidebar') && !document.querySelector('.side-nav') && !document.querySelector('.side-section'),
    hasRail: !!document.querySelector('.wsrail'),
    hasSessions: document.querySelectorAll('.wsrail .session-row').length >= 2,
    // with no workspace bound (fresh empty tab) the canvas shows the project
    // launcher (open-a-folder empty state), not the file view.
    hasEmptyLauncher: !!document.querySelector('.canvas .plaunch'),
    stageFiles: window.__kaisola.getState().stage === 'files',
    studioDefault: window.__kaisola.getState().layoutMode === 'studio',
    floatingTools: !!document.querySelector('.float-tools'),
  }))()`)
  const autonomy = await win.webContents.executeJavaScript(`(document.querySelector('.autonomy-seg[data-active="true"]')||{}).innerText || ''`)
  // auto-claude waits for a workspace (never boots the agent in $HOME): absent
  // before one is chosen, prepared with the workspace as cwd right after.
  const claudeRoot = path.join(os.tmpdir(), 'kaisola-claude-smoke')
  fsx.mkdirSync(claudeRoot, { recursive: true })
  const claudePrepared = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const before = st.terminals.some((term) => term.singletonKey === 'agent:claude-code')
    st.setWorkspace(${JSON.stringify(claudeRoot)})
    // the boot line is prepared asynchronously (hooks tap arms first)
    await new Promise((r) => setTimeout(r, 600))
    const t = window.__kaisola.getState().terminals.find((term) => term.singletonKey === 'agent:claude-code')
    // boot = plain \`claude\` or \`claude --settings '<hooks file>'\` when the tap armed
    const bootOk = !!t && typeof t.boot === 'string' && /^claude( --settings .+)?$/.test(t.boot)
    return !!(!before && t && bootOk && t.restart === true && t.name === 'Claude' && t.cwd === ${JSON.stringify(claudeRoot)})
  })()`)
  const nativeWindow = {
    frame: false,
    transparent: true,
    macVibrancy: process.platform === 'darwin' ? SMOKE_MAC_VIBRANCY : null,
    rendererClippedMaterial: process.platform !== 'darwin' || SMOKE_MAC_VIBRANCY === 'under-window',
  }
  const appIconPath = path.join(__dirname, 'assets', 'kaisola-icon.png')
  const appIcon = nativeImage.createFromPath(appIconPath)
  const appIconSize = appIcon.getSize()
  const icon = {
    exists: fsx.existsSync(appIconPath),
    usable: !appIcon.isEmpty(),
    width: appIconSize.width,
    height: appIconSize.height,
    square: appIconSize.width === appIconSize.height,
    large: appIconSize.width >= 1024,
  }
  const glass = await win.webContents.executeJavaScript(`(async () => {
    const pct = (value) => Number(String(value || '').trim().replace('%', ''))
    const px = (value) => Number(String(value || '').trim().replace('px', ''))
    const alpha = (value) => {
      const text = String(value || '')
      if (text === 'transparent') return 0
      const slashAlpha = text.match(/\\/\\s*([0-9.]+%?)\\s*\\)$/)
      if (slashAlpha) {
        const raw = slashAlpha[1]
        return raw.endsWith('%') ? Number(raw.slice(0, -1)) / 100 : Number(raw)
      }
      const match = text.match(/rgba?\\(([^)]+)\\)/)
      if (!match) return 1
      const parts = match[1].split(/[ ,/]+/).filter(Boolean)
      return parts.length >= 4 ? Number(parts[3]) : 1
    }
    const backdrop = (style) => [style.backdropFilter, style.getPropertyValue('-webkit-backdrop-filter')].filter(Boolean).join(' ')
    const store = window.__kaisola.getState()
    const previousLayout = store.layoutMode
    const previousWinFocus = document.documentElement.dataset.winfocus
    store.setLayoutMode('studio')
    document.documentElement.dataset.winfocus = 'true'
    await new Promise((r) => setTimeout(r, 120))
    const app = document.querySelector('.app')
    const rail = document.querySelector('.wsrail')
    const canvas = document.querySelector('.canvas-wrap > .canvas')
    if (!app || !rail || !canvas) {
      store.setLayoutMode(previousLayout)
      if (previousWinFocus == null) delete document.documentElement.dataset.winfocus
      else document.documentElement.dataset.winfocus = previousWinFocus
      await new Promise((r) => setTimeout(r, 80))
      return { appSamplingLayer: false, activeTintWhite: false, railLayerFlattened: false, contentGlassy: false, sessionGlassy: false, termGlassTint: false, blurKeepsGlass: false, lightsGray: false, nativeWindowRounding: false }
    }
    const appStyle = getComputedStyle(app)
    const railStyle = getComputedStyle(rail)
    const canvasStyle = getComputedStyle(canvas)
    const appGlassStyle = getComputedStyle(app, '::before')
    const card = document.querySelector('.session-card')
    const termPane = document.querySelector('.dock-pane-term')
    const light = document.querySelector('.light-close')
    const activeAppTint = appStyle.getPropertyValue('--app-active-glass-tint').trim()
    const appGlassBlur = appStyle.getPropertyValue('--app-active-glass-blur').trim()
    const appLiftTop = pct(appStyle.getPropertyValue('--app-active-glass-lift-top'))
    const appLiftBottom = pct(appStyle.getPropertyValue('--app-active-glass-lift-bottom'))
    const veilAlpha = pct(appStyle.getPropertyValue('--side-veil-alpha'))
    const contentAlpha = pct(appStyle.getPropertyValue('--content-glass-alpha'))
    const sessionAlpha = pct(appStyle.getPropertyValue('--session-glass-alpha'))
    const contentBlur = appStyle.getPropertyValue('--content-glass-blur').trim()
    const activeRailBackdrop = /blur/.test(backdrop(railStyle))
    const activeCanvasBackdrop = /blur/.test(backdrop(canvasStyle))
    const activeAppBackground = appStyle.backgroundColor
    const activeAppBackdrop = backdrop(appStyle)
    const activeAppGlassBackdrop = backdrop(appGlassStyle)
    const appRadius = px(appStyle.borderTopLeftRadius)
    const railRadius = px(railStyle.borderTopLeftRadius)
    const canvasRadius = px(canvasStyle.borderTopLeftRadius)
    const activeRailBackgroundAlpha = alpha(railStyle.backgroundColor)
    const activeRailBgImage = railStyle.backgroundImage
    const sessionListStyle = document.querySelector('.wsrail .session-list')
      ? getComputedStyle(document.querySelector('.wsrail .session-list'))
      : null
    const railFilesStyle = document.querySelector('.wsrail-files')
      ? getComputedStyle(document.querySelector('.wsrail-files'))
      : null
    const railSearchStyle = document.querySelector('.fx-rail-search')
      ? getComputedStyle(document.querySelector('.fx-rail-search'))
      : null
    const activeSessionListAlpha = sessionListStyle ? alpha(sessionListStyle.backgroundColor) : null
    const activeRailDividerAlpha = railFilesStyle ? alpha(railFilesStyle.borderTopColor) : null
    const activeRailSearchAlpha = railSearchStyle ? alpha(railSearchStyle.backgroundColor) : null
    const activeSessionListFlat = !sessionListStyle || (activeSessionListAlpha <= 0.02 && !/blur/.test(backdrop(sessionListStyle)))
    const activeRailDividerFlat = !railFilesStyle || activeRailDividerAlpha <= 0.02
    const activeRailSearchFlat = !railSearchStyle || (activeRailSearchAlpha <= 0.28 && !/blur/.test(backdrop(railSearchStyle)))
    // active-state fingerprints of every glass surface…
    const cardStyle = card ? getComputedStyle(card) : null
    const termStyle = termPane ? getComputedStyle(termPane) : null
    const fp = () => ({
      appGlassDisplay: getComputedStyle(app, '::before').display,
      appBg: getComputedStyle(app).backgroundColor,
      railBg: getComputedStyle(rail).backgroundColor,
      railBd: backdrop(getComputedStyle(rail)),
      canvasBg: getComputedStyle(canvas).backgroundColor,
      canvasBd: backdrop(getComputedStyle(canvas)),
      cardBg: card ? getComputedStyle(card).backgroundColor : null,
      cardBd: card ? backdrop(getComputedStyle(card)) : null,
      termBg: termPane ? getComputedStyle(termPane).backgroundColor : null,
      lightBg: light ? getComputedStyle(light).backgroundColor : null,
    })
    const activeFp = fp()
    // …must be IDENTICAL when the window blurs (only the lights gray)
    document.documentElement.dataset.winfocus = 'false'
    await new Promise((r) => setTimeout(r, 120))
    const blurredFp = fp()
    const surfacesEqual = ['appGlassDisplay', 'appBg', 'railBg', 'railBd', 'canvasBg', 'canvasBd', 'cardBg', 'cardBd', 'termBg']
      .every((k) => activeFp[k] === blurredFp[k])
    const out = {
      // NO brightness() in the light glass backdrop — a >1 multiplier after the
      // blur amplifies 8-bit quantization into visible bands; the lift moved into
      // the pre-blur gradient tint instead (hence the higher lift percentages)
      appSamplingLayer: !/blur/.test(activeAppBackdrop) && /blur/.test(activeAppGlassBackdrop) && !/brightness/.test(activeAppGlassBackdrop) && alpha(activeAppBackground) < 0.05 && appLiftTop >= 43 && appLiftTop <= 47 && appLiftBottom >= 28 && appLiftBottom <= 32 && /1[0-9]{3}px/.test(appGlassBlur),
      activeTintWhite: activeAppTint === '#fffefd',
      railBackdrop: activeRailBackdrop,
      railLayerFlattened: !activeRailBackdrop && activeRailBackgroundAlpha <= 0.02 && (!activeRailBgImage || activeRailBgImage === 'none') && activeSessionListFlat && activeRailDividerFlat && activeRailSearchFlat && veilAlpha >= 0 && veilAlpha <= 1,
      contentGlassy: contentAlpha >= 88 && contentAlpha <= 92 && activeCanvasBackdrop && /1[0-9][0-9]px/.test(contentBlur),
      // the session cards are the CLEAR glass: lighter ink than the canvas,
      // their own deeper blur, and saturate ≥1.3 (glass, not milk)
      sessionGlassy: sessionAlpha >= 50 && sessionAlpha <= 70 && !!cardStyle && alpha(cardStyle.backgroundColor) >= 0.4 && alpha(cardStyle.backgroundColor) <= 0.75 && /blur\\([2-4][0-9][0-9]px\\)/.test(backdrop(cardStyle)) && /saturate\\(1\\.[3-9]/.test(backdrop(cardStyle)),
      termGlassTint: !!termStyle && alpha(termStyle.backgroundColor) <= 0.5,
      blurKeepsGlass: surfacesEqual && blurredFp.appGlassDisplay !== 'none',
      lightsGray: !!light && activeFp.lightBg !== blurredFp.lightBg,
      nativeWindowRounding: appRadius >= 23 && appRadius <= 26 && railRadius >= 19 && railRadius <= 22 && canvasRadius >= 19 && canvasRadius <= 22,
      appBackground: activeAppBackground,
      appGlassBackdrop: activeAppGlassBackdrop,
      activeRailBackgroundAlpha,
      sessionAlpha,
      cardBg: activeFp.cardBg,
      cardBd: activeFp.cardBd,
      termBg: activeFp.termBg,
      blurredRailBg: blurredFp.railBg,
      contentAlpha,
      contentBlur,
      appRadius,
      railRadius,
      canvasRadius,
    }
    store.setLayoutMode(previousLayout)
    if (previousWinFocus == null) delete document.documentElement.dataset.winfocus
    else document.documentElement.dataset.winfocus = previousWinFocus
    await new Promise((r) => setTimeout(r, 80))
    return out
  })()`)

  console.log('ROOT_CHILDREN=' + rootChildren)
  console.log('MINIMAL_SHELL=' + JSON.stringify(minimalShell))
  console.log('AUTONOMY_DEFAULT=' + autonomy)
  console.log('CLAUDE_DEFAULT=' + claudePrepared)
  console.log('NATIVE_WINDOW=' + JSON.stringify(nativeWindow))
  console.log('ICON=' + JSON.stringify(icon))
  console.log('GLASS=' + JSON.stringify(glass))

  // 1) empty project — the minimal shell should land on the project launcher
  //    (open-a-folder empty state), not the old workflow nav.
  const emptyOk = !!(minimalShell.noWorkflowSidebar && minimalShell.hasRail && minimalShell.hasSessions && minimalShell.hasEmptyLauncher && minimalShell.stageFiles && minimalShell.studioDefault)
  console.log('EMPTY_MINIMAL=' + emptyOk)

  // 2) load the demo and confirm state still seeds correctly without exposing old views.
  await win.webContents.executeJavaScript(`window.__kaisola.getState().loadDemo()`)
  await new Promise((r) => setTimeout(r, 200))
  const demoOk = await win.webContents.executeJavaScript(`(() => {
    const s = window.__kaisola.getState()
    return s.stage === 'files' && s.project.corpus.length > 20 && s.project.proposals.some((p) => p.status === 'pending') && !!document.querySelector('.canvas .files-view')
  })()`)
  console.log('DEMO_MINIMAL=' + demoOk)

  // 3) the review-focus flow: open a pending decision → see the diff → approve
  const review = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const pending = st.project.proposals.filter(p => p.status === 'pending')
    const before = pending.length
    if (!pending.length) return { opened: false }
    st.focusProposal(pending[0].id)
    await new Promise(r => setTimeout(r, 120))
    const panel = !!document.querySelector('.focus-panel')
    const approve = [...document.querySelectorAll('.focus-panel button')].find(b => /approve/i.test(b.innerText))
    if (approve) approve.click()
    await new Promise(r => setTimeout(r, 120))
    const closed = !document.querySelector('.focus-panel')
    const after = window.__kaisola.getState().project.proposals.filter(p => p.status === 'pending').length
    return { opened: panel, closed, decided: after === before - 1 }
  })()`)
  console.log('REVIEW_FOCUS=' + JSON.stringify(review))

  // 4) the REAL terminal (node-pty) — verify `cd` actually changes directory
  const term = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setLayoutMode('studio')
    st.setDock(true, 'terminal')
    await new Promise(r => setTimeout(r, 150))
    const runRes = await window.kaisola.terminal.run('echo pasola-run-ok')
    let buf = ''
    const id = 'smoke-pty'
    const off = window.kaisola.terminal.onData(id, d => { buf += d })
    const cr = await window.kaisola.terminal.create(id, undefined, 80, 24)
    await new Promise(r => setTimeout(r, 500))
    await window.kaisola.terminal.write(id, 'cd /tmp\\r')
    await new Promise(r => setTimeout(r, 300))
    await window.kaisola.terminal.write(id, 'pwd\\r')
    await new Promise(r => setTimeout(r, 600))
    off(); window.kaisola.terminal.kill(id)
    return {
      run: !!(runRes && runRes.ok && (runRes.stdout||'').includes('pasola-run-ok')),
      ptyOk: !!cr.ok,
      cdWorks: /\\/(private\\/)?tmp/.test(buf),
      dock: !!document.querySelector('.session-card'),
      host: !!document.querySelector('.term-host'),
    }
  })()`)
  console.log('TERMINAL=' + JSON.stringify(term))

  // 5) live model wiring — no key in the sandbox, so it must degrade gracefully
  const model = await win.webContents.executeJavaScript(`(async () => {
    const k = await window.kaisola.settings.hasApiKey()
    const c = await window.kaisola.model.call({ messages: [{ role:'user', content:'hi' }] })
    return { hasKey: k.present, shape: typeof c.ok === 'boolean', graceful: c.ok === false }
  })()`)
  console.log('MODEL=' + JSON.stringify(model))

  // 6) ACP agent — connect to the mock, which RUNS A COMMAND via the terminal
  //    host (terminal/create → wait_for_exit → output). Verifies the full
  //    agent→terminal→dock loop: the command output streams back, and the
  //    renderer gets an acp:terminal event (the live tab).
  const acp = await win.webContents.executeJavaScript(`(async () => {
    const presets = await window.kaisola.acp.presets()
    const claude = presets.find((p) => p.id === 'claude-code')
    // Claude stays terminal-only (the hooks tap needs the pty); minimal name now
    const claudeTerminal = !!(claude && claude.terminalOnly && claude.terminalCommand === 'claude' && claude.name === 'Claude')
    const conn = await window.kaisola.acp.connect({ presetId: 'mock' })
    if (!conn.ok) return { presets: presets.length, claudeTerminal, connect: false, message: conn.message }
    const authCount = (conn.authMethods || []).length
    // standard ACP set_model (Gemini-style), set_config_option (codex-style), and authenticate
    const setModelRes = await window.kaisola.acp.setModel('mock', 'mock-mini')
    const setCfgRes = await window.kaisola.acp.setConfigOption('mock', 'reasoning_effort', 'low')
    let authUrlSeen = false
    const offN = window.kaisola.acp.onNotice((n) => { if (n.url) authUrlSeen = true })
    const authRes = await window.kaisola.acp.authenticate('mock', 'oauth-mock')
    await new Promise((r) => setTimeout(r, 250))
    offN()
    let streamed = '', thought = '', tools = 0, termEvents = 0
    const offT = window.kaisola.acp.onTerminal(() => { termEvents++ })
    const res = await window.kaisola.acp.prompt('mock', 'ping', (u) => {
      if (u.sessionUpdate === 'agent_message_chunk') streamed += (u.content && u.content.text) || ''
      else if (u.sessionUpdate === 'agent_thought_chunk') thought += (u.content && u.content.text) || ''
      else if (u.sessionUpdate === 'tool_call' || u.sessionUpdate === 'tool_call_update') tools++
    })
    offT()
    const st = await window.kaisola.acp.status()
    const c = (st.agents.find((a) => a.key === 'mock') || {}).controls || {}
    const modelAfter = (c.models || {}).currentModelId
    const reasoningAfter = ((c.configOptions || []).find((o) => o.id === 'reasoning_effort') || {}).currentValue
    const cancelOk = (await window.kaisola.acp.cancel('mock')).ok
    await window.kaisola.acp.disconnect('mock')
    return {
      presets: presets.length, claudeTerminal, connect: true, ok: !!res.ok, key: conn.key, cancelOk: !!cancelOk,
      authCount, authOk: !!authRes.ok, authUrlSeen, setModelOk: !!setModelRes.ok, setCfgOk: !!setCfgRes.ok,
      modelAfter, reasoningAfter, ranCommand: streamed.includes('agent-ran-this'),
      gotThought: thought.length > 0, tools, termEvents,
    }
  })()`)
  console.log('ACP=' + JSON.stringify(acp))

  // 7) the chat agent-switcher dropdown must open in a portal (not clipped) so
  //    you can actually pick another chat agent — terminal-only agents stay in
  //    the session + menu instead.
  const dd = await win.webContents.executeJavaScript(`(async () => {
    window.__kaisola.getState().setLayoutMode('studio')
    window.__kaisola.getState().setDock(true, 'assistant')
    await new Promise((r) => setTimeout(r, 200))
    const btn = document.querySelector('.assistant-foot .drop-btn')
    if (!btn) return { hasBtn: false }
    btn.click()
    await new Promise((r) => setTimeout(r, 150))
    const menu = document.querySelector('body > .drop-menu') || document.querySelector('.drop-menu')
    const items = document.querySelectorAll('.drop-menu .drop-item')
    const out = { hasBtn: true, portal: !!(menu && menu.parentElement === document.body), items: items.length }
    btn.click() // close it again — synthetic clicks never hit the click-outside handler
    return out
  })()`)
  console.log('DROPDOWN=' + JSON.stringify(dd))

  // 7a) permission rulesets — "always allow" saves a rule + retroactively
  //     resolves matching pending asks; deny cascades across the agent's
  //     other asks; rule-covered asks never surface a card at all.
  const permrules = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const prevWs = st.workspacePath
    st.setWorkspace('/tmp/permrules-ws')
    const g = () => window.__kaisola.getState()
    const ask = (permId, kind, title) => ({ permId, key: 'mock', agent: 'Mock', title, kind,
      options: [
        { optionId: 'a1', name: 'Allow', kind: 'allow_once' },
        { optionId: 'r1', name: 'Deny', kind: 'reject_once' },
      ] })
    // two matching execute asks + one edit ask stack up
    g().pushPermission(ask('p1', 'execute', 'git status'))
    g().pushPermission(ask('p2', 'execute', 'git push origin main'))
    g().pushPermission(ask('p3', 'edit', 'Edit notes.md'))
    g().alwaysAllowPermission('p1')
    const afterAlways = g().pendingPermissions.map((p) => p.permId)
    const saved = g().permissionRules.some((r) => r.workspace === '/tmp/permrules-ws' && r.action === 'execute' && r.resource === 'git *')
    const cascaded = afterAlways.length === 1 && afterAlways[0] === 'p3' // p2 resolved retroactively
    // a NEW matching ask is auto-answered — no card
    g().receivePermission(ask('p4', 'execute', 'git log'))
    const autoAnswered = !g().pendingPermissions.some((p) => p.permId === 'p4')
    // deny cascades across the same agent's remaining asks
    g().pushPermission(ask('p5', 'execute', 'rm -rf build'))
    g().answerPermission('p3', { optionId: 'r1' }, { cascadeReject: true })
    const pendingAfter = g().pendingPermissions.length
    // cleanup
    g().permissionRules.filter((r) => r.workspace === '/tmp/permrules-ws').forEach((r) => g().removePermissionRule(r.id))
    st.setWorkspace(prevWs)
    return { saved, cascaded, autoAnswered, rejectCascade: pendingAfter === 0, pendingAfter }
  })()`)
  console.log('PERMRULES=' + JSON.stringify(permrules))

  // 7a-ii) sensitive-file guardrails — matching asks always surface a card
  //        (flagged), rules can never cover them, and no rule auto-allows them.
  const sensitive = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const prevWs = st.workspacePath
    st.setWorkspace('/tmp/sensitive-ws')
    const g = () => window.__kaisola.getState()
    const ask = (permId, kind, title, diffs) => ({ permId, key: 'mock', agent: 'Mock', title, kind, diffs,
      options: [{ optionId: 'a1', name: 'Allow', kind: 'allow_once' }, { optionId: 'r1', name: 'Deny', kind: 'reject_once' }] })
    // a rule that WOULD cover cat — the sensitive path must beat it
    g().pushPermission(ask('s0', 'execute', 'cat README.md'))
    g().alwaysAllowPermission('s0')
    g().receivePermission(ask('s1', 'execute', 'cat .env.local'))
    const p1 = g().pendingPermissions.find((p) => p.permId === 's1')
    const surfaced = !!p1 && p1.sensitive === true
    g().alwaysAllowPermission('s1')
    const stillPending = g().pendingPermissions.some((p) => p.permId === 's1') // refused to make a rule
    const noSensitiveRule = !g().permissionRules.some((r) => r.resource === 'cat *' && r.workspace !== '/tmp/sensitive-ws')
    // diff-shaped sensitive ask (edit kind carries the path in diffs)
    g().receivePermission(ask('s2', 'edit', 'Edit config', [{ path: 'conf/secrets.yml', oldText: '', newText: 'x' }]))
    const diffFlagged = g().pendingPermissions.find((p) => p.permId === 's2')?.sensitive === true
    // cleanup
    g().answerPermission('s1', { optionId: 'a1' })
    g().answerPermission('s2', { optionId: 'r1' }, { cascadeReject: true })
    g().permissionRules.filter((r) => r.workspace === '/tmp/sensitive-ws').forEach((r) => g().removePermissionRule(r.id))
    st.setWorkspace(prevWs)
    return { surfaced, stillPending, diffFlagged, noSensitiveRule, pendingAfter: g().pendingPermissions.length }
  })()`)
  console.log('SENSITIVE=' + JSON.stringify(sensitive))

  // 7b) code-agent activity ledger — tool/subagent calls and background
  //     terminals should be visible as a neat summary inside the agent card.
  const activityUi = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setLayoutMode('studio')
    st.setDock(true, 'assistant')
    st.setAssistantThreadAgent(st.activeThreadId, 'mock')
    st.updateAssistantRuntime(st.activeThreadId, () => ({
      first: false,
      turns: [
        { kind: 'tool', toolId: 'sub-smoke', text: 'Task: inspect files with a coding subagent', status: 'pending', at: Date.now() },
        { kind: 'tool', toolId: 'cmd-smoke', text: 'npm run smoke', status: 'completed', at: Date.now() },
      ],
    }))
    window.__kaisola.setState((s) => ({
      agentTerminals: [
        ...s.agentTerminals.filter((t) => t.terminalId !== 'activity-smoke-term'),
        { terminalId: 'activity-smoke-term', agentKey: 'mock', agentName: 'Mock Agent', command: 'npm run smoke', label: 'npm run smoke', cwd: '/tmp/pasola-smoke' },
      ],
    }))
    await new Promise((r) => setTimeout(r, 180))
    const card = document.querySelector('.agent-activity')
    const text = card?.textContent || ''
    return {
      card: !!card,
      hasSubagent: /Subagent/.test(text) && /coding subagent/.test(text),
      hasTerminal: /Background terminals/.test(text) && /npm run smoke/.test(text),
      hasStatus: /pending/.test(text) && /completed/.test(text),
      openBtn: !!document.querySelector('.agent-activity-terminal button'),
    }
  })()`)
  console.log('ACTIVITY_UI=' + JSON.stringify(activityUi))

  // 8) persistence — the store writes to the durable main-process DB (SQLite,
  //    JSON fallback). Verify the blob round-trips + which backend is active.
  const persist = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setTheme('dark')
    st.setAgentPreset('opencode')
    st.updateAssistantRuntime(st.activeThreadId, () => ({ first: false, turns: [{ kind: 'user', text: 'persisted chat turn', at: 1 }] }))
    await new Promise((r) => setTimeout(r, 150)) // let the async db.set flush
    const raw = window.kaisola.db.getSync('kaisola-store')
    const kind = await window.kaisola.db.kind()
    return {
      stored: !!raw,
      hasTheme: !!(raw && raw.includes('"theme":"dark"')),
      hasAgent: !!(raw && raw.includes('"agentPreset":"opencode"')),
      hasThread: !!(raw && raw.includes('"assistantThreads"')),
      hasChatTurn: !!(raw && raw.includes('persisted chat turn')),
      backend: kind.kind,
    }
  })()`)
  console.log('PERSIST=' + JSON.stringify(persist))

  // 9) sign-in runs the CLI login in a real terminal — verify a requested
  //    terminal boots its command (here a harmless echo) and runs it.
  const boot = await win.webContents.executeJavaScript(`(async () => {
    window.__kaisola.getState().setDock(true, 'terminal')
    window.__kaisola.getState().requestTerminal('echo boot-login-ok')
    const terms = window.__kaisola.getState().terminals
    const id = terms.length ? terms[terms.length - 1].id : null
    if (!id) return { hasId: false }
    let buf = ''
    const off = window.kaisola.terminal.onData(id, (d) => { buf += d })
    await new Promise((r) => setTimeout(r, 1500))
    off()
    return { hasId: true, ran: buf.includes('boot-login-ok') }
  })()`)
  console.log('BOOT=' + JSON.stringify(boot))

  // 10) headless device-login runner — surfaces URL + code from a process, no terminal
  const auth = await win.webContents.executeJavaScript(`(async () => {
    const got = { url: null, code: null, done: false }
    window.kaisola.auth.start('echo', ['Visit https://example.com/device and enter ABCD-1234'], (ev) => {
      if (ev.url) got.url = ev.url
      if (ev.code) got.code = ev.code
      if (ev.phase === 'done') got.done = true
    })
    await new Promise((r) => setTimeout(r, 700))
    return { hasUrl: (got.url || '').includes('example.com/device'), code: got.code, done: got.done }
  })()`)
  console.log('AUTH=' + JSON.stringify(auth))

  // 11) the work row: each open session is its OWN card, sitting to the LEFT
  //     of the files/canvas card (which keeps the right-hand slot).
  const cards = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setLayoutMode('studio')
    st.setDock(true, 'assistant')
    await new Promise((r) => setTimeout(r, 150))
    const shown = document.querySelectorAll('.session-card[data-show="true"]')
    const canvas = document.querySelector('.canvas-wrap > .canvas')
    const c = canvas && canvas.getBoundingClientRect()
    const s0 = shown[0] && shown[0].getBoundingClientRect()
    return {
      cardPerView: shown.length === window.__kaisola.getState().dockViews.length,
      chatLeftOfFiles: !!(s0 && c && s0.left < c.left),
      hasHead: !!document.querySelector('.session-card[data-show="true"] .pane-head'),
      noDockPanel: !document.querySelector('.dock'),
    }
  })()`)
  console.log('CARDS=' + JSON.stringify(cards))

  // 12) workspace file explorer fs access
  const fschk = await win.webContents.executeJavaScript(`(async () => {
    const l = await window.kaisola.fs.list('/')
    const r = await window.kaisola.fs.read('/etc/hosts')
    const tmp = '/tmp/pasola-smoke-fswrite.txt'
    const stamp = 'roundtrip-ok'
    const w = await window.kaisola.fs.write(tmp, stamp)
    const rb = await window.kaisola.fs.read(tmp)
    return {
      listed: !!(l.ok && (l.entries || []).length > 0),
      read: !!(r.ok && typeof r.content === 'string'),
      wrote: !!(w.ok && rb.ok && rb.content === stamp),
    }
  })()`)
  console.log('FILES=' + JSON.stringify(fschk))

  // 12b) Files card quick-open search + multiple open file tabs
  const fileUiRoot = path.join(os.tmpdir(), 'pasola-file-ui-smoke')
  try { fsx.rmSync(fileUiRoot, { recursive: true, force: true }) } catch {}
  fsx.mkdirSync(fileUiRoot, { recursive: true })
  fsx.mkdirSync(path.join(fileUiRoot, 'figs'), { recursive: true })
  const smokePng = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAG0lEQVR42mP8z8Dwn4GBgYGJgYGBgQEABw0BA8LLy1kAAAAASUVORK5CYII=', 'base64')
  fsx.writeFileSync(path.join(fileUiRoot, 'figs', 'inline.png'), smokePng)
  fsx.writeFileSync(path.join(fileUiRoot, 'alpha-search-target.txt'), 'alpha\n')
  fsx.writeFileSync(path.join(fileUiRoot, 'beta-notes.md'), '# beta\n\nReadable olive markdown.\n\n![inline figure](figs/inline.png)\n\n- [x] task\n')
  fsx.writeFileSync(path.join(fileUiRoot, 'page.html'), '<main><h1>HTML title</h1><p>Readable olive html.</p><script>window.__badHtmlPreview = true</script><p onclick="window.__badHtmlPreview = true">unsafe attr</p></main>')
  fsx.writeFileSync(path.join(fileUiRoot, 'paper.tex'), String.raw`\title{Kaisola Field Notes}
\author{Research Desk}
\date{June 2026}
\begin{document}
\maketitle
\begin{abstract}
A compact LaTeX preview with inline math $E = mc^2$ and citations \cite{einstein}.
\end{abstract}
\section{Result}
The viewer should render \textbf{strong claims}, references \ref{eq:main}, and readable paragraphs.
\begin{equation}
\label{eq:main}
a^2 + b^2 = c^2
\end{equation}
\begin{itemize}
\item First observation
\item Second observation
\end{itemize}
\end{document}
`)
  fsx.writeFileSync(path.join(fileUiRoot, 'sample-image.png'), smokePng)
  fsx.writeFileSync(path.join(fileUiRoot, 'sample-paper.pdf'), smokePdf('Kaisola PDF'))
  const largePdfPath = path.join(fileUiRoot, 'large-paper.pdf')
  fsx.writeFileSync(largePdfPath, smokePdf('Large Kaisola PDF'))
  fsx.truncateSync(largePdfPath, 45 * 1024 * 1024)
  fsx.writeFileSync(path.join(fileUiRoot, 'script.py'), 'def main():\n    for i in range(12):\n        print(i)\n\nif __name__ == "__main__":\n    main()\n')
  const fileui = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setLayoutMode('focus')
    st.setWorkspace(${JSON.stringify(fileUiRoot)})
    st.setStage('files')
    await new Promise((r) => setTimeout(r, 220))
    const search = document.querySelector('.fx-search-wrap input')
    if (!search) return { hasSearch: false }
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
    setter.call(search, 'alpha')
    search.dispatchEvent(new Event('input', { bubbles: true }))
    search.dispatchEvent(new Event('focus', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 650))
    const results = document.querySelectorAll('.fx-search-result')
    if (!results.length) return { hasSearch: true, resultCount: 0 }
    const waitFor = async (check, timeout = 1200) => {
      const started = performance.now()
      while (performance.now() - started < timeout) {
        const value = check()
        if (value) return value
        await new Promise((r) => requestAnimationFrame(r))
      }
      return check()
    }
    results[0].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }))
    await new Promise((r) => setTimeout(r, 300))
    // single-click opens are TRANSIENT (Zed preview tabs): alpha renders italic…
    const alphaPreview = !!document.querySelector('.fx-tab[data-preview]') &&
      (document.querySelector('.fx-tab[data-preview]')?.textContent || '').includes('alpha-search-target.txt')
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'beta-notes.md'))})
    await new Promise((r) => setTimeout(r, 300))
    // …and the next transient open REPLACES it instead of stacking a tab
    const tabsAfterBeta = [...document.querySelectorAll('.fx-tab')].map((t) => t.textContent || '')
    const previewReplaced = tabsAfterBeta.length === 1 && !tabsAfterBeta.some((t) => t.includes('alpha-search-target.txt'))
    // double-click pins: the italic goes away and the tab survives future previews
    const betaTab = document.querySelector('.fx-tab[data-preview]')
    betaTab?.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true }))
    await new Promise((r) => setTimeout(r, 120))
    const betaPinned = !document.querySelector('.fx-tab[data-preview]')
    const tabs = [...document.querySelectorAll('.fx-tab')].map((t) => t.textContent || '')
    const activeBeta = (document.querySelector('.fx-tab[data-active="true"]')?.textContent || '').includes('beta-notes.md')
    const mdPreview = !!document.querySelector('.fx-doc-markdown h1')
    const mdImage = !!(await waitFor(() => {
      const img = document.querySelector('.fx-doc-markdown img')
      return img && img.naturalWidth > 0 && /inline figure/.test(img.getAttribute('alt') || '')
    }))
    const find = document.querySelector('.fx-doc-find input')
    if (find) {
      setter.call(find, 'olive')
      find.dispatchEvent(new Event('input', { bubbles: true }))
      await new Promise((r) => setTimeout(r, 80))
    }
    const mdMark = !!document.querySelector('.fx-doc-markdown .doc-mark')
    await window.kaisola.fs.write(${JSON.stringify(path.join(fileUiRoot, 'beta-notes.md'))}, '# beta\\n\\nUpdated externally olive.\\n')
    await new Promise((r) => setTimeout(r, 750))
    const mdExternal = /Updated externally olive/.test(document.querySelector('.fx-doc-markdown')?.textContent || '')
    const pane = document.querySelector('.fx-pane')
    const mdHeading = document.querySelector('.fx-doc-markdown h1')
    const mdHeadingBefore = mdHeading ? parseFloat(getComputedStyle(mdHeading).fontSize) : 0
    const zoomBefore = window.__kaisola.getState().fileTextZoom
    mdHeading?.dispatchEvent(new WheelEvent('wheel', { deltaY: -90, ctrlKey: true, bubbles: true, cancelable: true }))
    await new Promise((resolve) => {
      const started = performance.now()
      const tick = () => {
        const current = window.__kaisola.getState().fileTextZoom
        const cssNow = pane ? parseFloat(getComputedStyle(pane).getPropertyValue('--fx-file-font')) : 0
        if (current > zoomBefore || cssNow > 15 * zoomBefore || performance.now() - started > 1200) resolve()
        else requestAnimationFrame(tick)
      }
      tick()
    })
    await new Promise((r) => setTimeout(r, 40))
    const mdHeadingAfterNode = document.querySelector('.fx-doc-markdown h1')
    const mdHeadingAfter = mdHeadingAfterNode ? parseFloat(getComputedStyle(mdHeadingAfterNode).fontSize) : 0
    const mdDoc = document.querySelector('.fx-doc-markdown')
    const mdPage = document.querySelector('.fx-doc-markdown .fx-doc-page')
    const mdDocStyle = mdDoc ? getComputedStyle(mdDoc) : null
    const mdDocRect = mdDoc?.getBoundingClientRect()
    const mdPageRect = mdPage?.getBoundingClientRect()
    const mdContentWidth = mdDoc && mdDocStyle
      ? mdDoc.clientWidth - parseFloat(mdDocStyle.paddingLeft) - parseFloat(mdDocStyle.paddingRight)
      : 0
    const mdPageWidth = mdPageRect ? mdPageRect.width : 0
    const mdLeftMargin = mdDocRect && mdDocStyle && mdPageRect
      ? mdPageRect.left - (mdDocRect.left + parseFloat(mdDocStyle.paddingLeft))
      : 0
    const mdRightMargin = mdDocRect && mdDocStyle && mdPageRect
      ? (mdDocRect.right - parseFloat(mdDocStyle.paddingRight)) - mdPageRect.right
      : 0
    const mdOuterLeft = mdDocRect && mdPageRect ? mdPageRect.left - mdDocRect.left : 0
    const mdOuterRight = mdDocRect && mdPageRect ? mdDocRect.right - mdPageRect.right : 0
    const mdReadableChannel = mdContentWidth > 0 &&
      mdPageWidth <= mdContentWidth + 2 &&
      mdOuterLeft >= 48 &&
      mdOuterRight >= 48 &&
      Math.abs(mdOuterLeft - mdOuterRight) <= 3 &&
      Math.abs(mdLeftMargin - mdRightMargin) <= 2
    const splitModeBtn = [...document.querySelectorAll('.fx-mode')].find((btn) => /split/i.test(btn.textContent || ''))
    splitModeBtn?.click()
    await new Promise((r) => setTimeout(r, 500))
    const splitDoc = document.querySelector('.fx-split-prev .fx-doc-markdown')
    const splitPage = document.querySelector('.fx-split-prev .fx-doc-page')
    const splitDocStyle = splitDoc ? getComputedStyle(splitDoc) : null
    const splitDocRect = splitDoc?.getBoundingClientRect()
    const splitPageRect = splitPage?.getBoundingClientRect()
    const splitContentWidth = splitDoc && splitDocStyle
      ? splitDoc.clientWidth - parseFloat(splitDocStyle.paddingLeft) - parseFloat(splitDocStyle.paddingRight)
      : 0
    const splitPageWidth = splitPageRect ? splitPageRect.width : 0
    const splitPadLeft = splitDocStyle ? parseFloat(splitDocStyle.paddingLeft) : 999
    const splitPadRight = splitDocStyle ? parseFloat(splitDocStyle.paddingRight) : 999
    const mdSplitFillsPane = !!splitDocRect &&
      splitContentWidth > 0 &&
      splitPageWidth >= splitContentWidth * 0.94 &&
      splitPadLeft <= 28 &&
      splitPadRight <= 28
    const zoomCss = pane ? getComputedStyle(pane).getPropertyValue('--fx-file-font').trim() : ''
    await new Promise((r) => setTimeout(r, 220))
    const zoomAfter = window.__kaisola.getState().fileTextZoom
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'page.html'))}, undefined, { pinned: true })
    await new Promise((r) => setTimeout(r, 350))
    const htmlPreview = !!document.querySelector('.fx-doc-html h1')
    const htmlSafe = !document.querySelector('.fx-doc-html script') && !document.querySelector('.fx-doc-html [onclick]') && !window.__badHtmlPreview
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'paper.tex'))})
    const texEditor = await waitFor(() => document.querySelector('.cm-scroller'), 2200)
    const texSource = !!texEditor && /\\\\title\\{Kaisola Field Notes\\}/.test(texEditor.textContent || '')
    const texEditable = !!document.querySelector('.cm-content[contenteditable="true"]')
    const texNoPreview = !document.querySelector('.fx-doc-latex')
    st.setFileTextZoom(1)
    await new Promise((r) => setTimeout(r, 80))
    const imageRead = await window.kaisola.fs.read(${JSON.stringify(path.join(fileUiRoot, 'sample-image.png'))})
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'sample-image.png'))})
    await new Promise((r) => setTimeout(r, 450))
    const imageNode = document.querySelector('.fx-media-image img')
    const imagePreview = !!imageNode && imageNode.naturalWidth > 0 && imageNode.naturalHeight > 0
    const imageWidthBefore = imageNode ? imageNode.getBoundingClientRect().width : 0
    imageNode?.dispatchEvent(new WheelEvent('wheel', { deltaY: -130, ctrlKey: true, bubbles: true, cancelable: true }))
    const imageZoomed = !!(await waitFor(() => {
      const img = document.querySelector('.fx-media-image img')
      return img && imageWidthBefore > 0 && img.getBoundingClientRect().width > imageWidthBefore + 4
    }))
    const pdfRead = await window.kaisola.fs.read(${JSON.stringify(path.join(fileUiRoot, 'sample-paper.pdf'))})
    const largePdfRead = await window.kaisola.fs.read(${JSON.stringify(largePdfPath)})
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'sample-paper.pdf'))})
    const pdfImg = await waitFor(() => document.querySelector('.fx-pdf-page[data-page="1"] img'), 8000)
    const pdfPreview = !!pdfImg && /^kaisola-preview:\\/\\//.test(pdfImg.getAttribute('src') || '')
    const pdfNoSidePane = !document.querySelector('.fx-pdf-frame')
    const pdfWidthBefore = pdfImg?.closest('.fx-pdf-page')?.getBoundingClientRect().width || 0
    pdfImg?.dispatchEvent(new WheelEvent('wheel', { deltaY: -130, ctrlKey: true, bubbles: true, cancelable: true }))
    const pdfZoomed = !!(await waitFor(() => {
      const page = document.querySelector('.fx-pdf-page[data-page="1"]')
      return page && pdfWidthBefore > 0 && page.getBoundingClientRect().width > pdfWidthBefore + 4
    }))
    const pdfChromeCollapsed = !document.querySelector('.fx-bar') && !document.querySelector('.fx-tabs:not(.fx-tabs-inline)') && !document.querySelector('.fx-latexwrap')
    const pdfPluginOn = navigator.pdfViewerEnabled === true
    st.setFileTextZoom(1)
    await new Promise((r) => setTimeout(r, 80))
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'script.py'))}, 'edit')
    await new Promise((r) => setTimeout(r, 850))
    const cmScroller = document.querySelector('.cm-scroller')
    const cmLineBeforeNode = document.querySelector('.cm-line')
    const cmNumberBeforeNode = [...document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')].find((el) => (el.textContent || '').trim() === '1') || document.querySelector('.cm-lineNumbers .cm-gutterElement')
    const codeFontBefore = cmScroller ? parseFloat(getComputedStyle(cmScroller).fontSize) : 0
    const gutterFontBefore = cmNumberBeforeNode ? parseFloat(getComputedStyle(cmNumberBeforeNode).fontSize) : 0
    const codeCssBefore = pane ? parseFloat(getComputedStyle(pane).getPropertyValue('--fx-code-font')) : 0
    cmLineBeforeNode?.dispatchEvent(new WheelEvent('wheel', { deltaY: -120, ctrlKey: true, bubbles: true, cancelable: true }))
    await new Promise((resolve) => {
      const started = performance.now()
      const tick = () => {
        const codeCssNow = pane ? parseFloat(getComputedStyle(pane).getPropertyValue('--fx-code-font')) : 0
        if (codeCssNow > codeCssBefore || performance.now() - started > 1200) resolve()
        else requestAnimationFrame(tick)
      }
      tick()
    })
    await new Promise((r) => setTimeout(r, 80))
    const cmLineAfterNode = document.querySelector('.cm-line')
    const cmNumberAfterNode = [...document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')].find((el) => (el.textContent || '').trim() === '1') || document.querySelector('.cm-lineNumbers .cm-gutterElement')
    const codeFontAfter = cmScroller ? parseFloat(getComputedStyle(cmScroller).fontSize) : 0
    const gutterFontAfter = cmNumberAfterNode ? parseFloat(getComputedStyle(cmNumberAfterNode).fontSize) : 0
    const lineRect = cmLineAfterNode?.getBoundingClientRect()
    const gutterRect = cmNumberAfterNode?.getBoundingClientRect()
    const codeZoomed = codeFontAfter > codeFontBefore
    const gutterZoomed = gutterFontAfter > gutterFontBefore
    const codeGutterDelta = lineRect && gutterRect ? Math.abs(lineRect.top - gutterRect.top) : null
    const codeGutterAligned = codeGutterDelta !== null && codeGutterDelta <= 1.5
    const appRegion = (sel) => {
      const node = document.querySelector(sel)
      return node ? getComputedStyle(node).getPropertyValue('-webkit-app-region').trim() : ''
    }
    const compactFileChrome =
      document.querySelectorAll('.fx-file-chrome .fx-toolbar').length === 2 &&
      !!document.querySelector('.fx-toolbar-main .fx-tabs-inline') &&
      !!document.querySelector('.fx-toolbar-sub') &&
      !document.querySelector('.fx-tabs:not(.fx-tabs-inline)') &&
      !document.querySelector('.fx-bar') &&
      !document.querySelector('.fx-latexwrap')
    const topBarsDrag = [...document.querySelectorAll('.fx-file-chrome .fx-toolbar')]
      .every((node) => getComputedStyle(node).getPropertyValue('-webkit-app-region').trim() === 'drag')
    const topBarControlsNoDrag =
      appRegion('.fx-search-wrap') === 'no-drag' &&
      appRegion('.fx-search-wrap input') === 'no-drag' &&
      appRegion('.fx-tab') === 'no-drag' &&
      appRegion('.fx-tab .fx-tab-close') === 'no-drag' &&
      appRegion('.fx-zoom-pill') === 'no-drag' &&
      appRegion('.fx-modes') === 'no-drag' &&
      appRegion('.fx-mode') === 'no-drag'
    const cssAlpha = (value) => {
      const text = String(value || '')
      if (text === 'transparent') return 0
      const slashAlpha = text.match(/\\/\\s*([0-9.]+%?)\\s*\\)$/)
      if (slashAlpha) {
        const raw = slashAlpha[1]
        return raw.endsWith('%') ? Number(raw.slice(0, -1)) / 100 : Number(raw)
      }
      const match = text.match(/rgba?\\(([^)]+)\\)/)
      if (!match) return 1
      const parts = match[1].split(/[ ,/]+/).filter(Boolean)
      return parts.length >= 4 ? Number(parts[3]) : 1
    }
    // the shell renders identically when blurred (GLASS.blurKeepsGlass pins
    // that) — here we only pin that the file chrome keeps visible hairlines
    const topBarBordersVisible =
      cssAlpha(getComputedStyle(document.querySelector('.fx-toolbar')).borderBottomColor) > 0.05
    st.setLayoutMode('studio')
    await new Promise((r) => setTimeout(r, 250))
    const shellGuttersDrag =
      appRegion('.app') === 'drag' &&
      appRegion('.app-body') === 'drag' &&
      appRegion('.work-row') === 'drag' &&
      appRegion('.session-grid') === 'drag' &&
      appRegion('.canvas-wrap') === 'drag'
    const shellSurfacesDrag =
      appRegion('.wsrail') === 'drag' &&
      appRegion('.session-card[data-show="true"]') === 'drag' &&
      appRegion('.canvas-wrap > .canvas') === 'drag'
    const shellInnerNoDrag =
      appRegion('.wsrail .wsrail-files') === 'no-drag' &&
      appRegion('.session-card[data-show="true"] > *') === 'no-drag' &&
      appRegion('.canvas-wrap > .canvas > *') === 'no-drag'
    const shellHandlesNoDrag =
      appRegion('.canvas-resize') === 'no-drag'
    await window.kaisola.fs.write(${JSON.stringify(path.join(fileUiRoot, 'delta-watch.md'))}, '# delta\\n')
    await new Promise((r) => setTimeout(r, 800))
    const railSawDelta = [...document.querySelectorAll('.wsrail .fx-row')].some((row) => (row.textContent || '').includes('delta-watch.md'))
    await new Promise((r) => setTimeout(r, 180))
    const finalZoom = window.__kaisola.getState().fileTextZoom
    const raw = window.kaisola.db.getSync('kaisola-store') || ''
    return {
      hasSearch: true,
      resultCount: results.length,
      tabs: tabs.length,
      alphaPreview,
      previewReplaced,
      betaPinned,
      hasBeta: tabs.some((t) => t.includes('beta-notes.md')),
      activeBeta,
      mdPreview,
      mdImage,
      mdMark,
      mdExternal,
      htmlPreview,
      htmlSafe,
      texSource,
      texEditable,
      texNoPreview,
      imageReadKind: imageRead.mediaKind,
      imageHasDataUrl: /^data:image\\/png/.test(imageRead.dataUrl || ''),
      imagePreview,
      imageZoomed,
      pdfReadKind: pdfRead.mediaKind,
      pdfHasPreviewUrl: /^kaisola-preview:\\/\\//.test(pdfRead.previewUrl || ''),
      pdfNoDataUrl: !pdfRead.dataUrl,
      largePdfReadKind: largePdfRead.mediaKind,
      largePdfHasPreviewUrl: /^kaisola-preview:\\/\\//.test(largePdfRead.previewUrl || ''),
      largePdfNotTooLarge: !largePdfRead.tooLarge,
      largePdfNoDataUrl: !largePdfRead.dataUrl,
      pdfPreview,
      pdfNoSidePane,
      pdfZoomed,
      pdfChromeCollapsed,
      pdfPluginOn,
      zoomed: zoomAfter > zoomBefore,
      zoomCss: !!zoomCss && !zoomCss.includes('15px'),
      mdHeadingZoomed: mdHeadingAfter > mdHeadingBefore,
      mdReadableChannel,
      mdSplitFillsPane,
      codeZoomed,
      gutterZoomed,
      codeGutterAligned,
      codeGutterDelta,
      topBarsDrag,
      compactFileChrome,
      topBarControlsNoDrag,
      topBarBordersVisible,
      shellGuttersDrag,
      shellSurfacesDrag,
      shellInnerNoDrag,
      shellHandlesNoDrag,
      railSawDelta,
      fileTabsPersisted: raw.includes('"fileTabs"') && raw.includes('beta-notes.md') && raw.includes('page.html'),
      fileZoomPersisted: raw.includes('"fileTextZoom"') && raw.includes(String(finalZoom)),
    }
  })()`)
  console.log('FILEUI=' + JSON.stringify(fileui))

  // 13) sessions live in the LEFT RAIL (threads + terminals as rows, above the
  //     workspace tree); a new agent thread adds a row there and focuses the
  //     dock pane. The dock itself carries no tab chrome; identity sits in the foot.
  const layout = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setLayoutMode('studio')
    st.setDock(true, 'assistant')
    await new Promise((r) => setTimeout(r, 150))
    const rows = () => document.querySelectorAll('.wsrail .session-row').length
    const before = rows()
    const foot = document.querySelector('.assistant-foot')
    st.requestNewThread()
    await new Promise((r) => setTimeout(r, 150))
    const after = rows()
    const s2 = window.__kaisola.getState()
    return {
      sessionsInRail: before >= 2, // at least one agent thread + one terminal
      hasRailTreeArea: !!document.querySelector('.wsrail .wsrail-files'),
      addsRow: after === before + 1,
      focusesNewThread: s2.dockViews.includes(s2.activeThreadId),
      noDockChrome: !document.querySelector('.dock-head') && !document.querySelector('.dock-tab'),
      hasFoot: !!foot,
      footWs: !!(foot && foot.querySelector('.foot-ws')),
      footConn: !!(foot && foot.querySelector('.foot-conn')),
    }
  })()`)
  console.log('LAYOUT=' + JSON.stringify(layout))

  // 13b) the session-card GRID — new sessions join as their own card (no cap),
  //      and a card can be placed below/above/beside another (drag-to-place).
  const splits = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const shown = () => document.querySelectorAll('.session-card[data-show="true"]').length
    // start from a single chat card
    const a1 = get().assistantThreads[0].id
    get().setDockView(a1)
    for (const v of get().dockViews.filter((x) => x !== a1)) get().removeDockView(v)
    await new Promise((r) => setTimeout(r, 150))
    const one = get().dockViews.length === 1 && shown() === 1
    get().requestTerminal() // a new terminal joins BESIDE — it never replaces
    await new Promise((r) => setTimeout(r, 150))
    const tNew = get().terminals[get().terminals.length - 1].id
    const appended = get().dockViews.length === 2 && shown() === 2
    const heads = document.querySelectorAll('.pane-head').length === 2
    // place the terminal BELOW the chat — one column, stacked
    get().placeDockView(tNew, a1, 'bottom')
    await new Promise((r) => setTimeout(r, 120))
    const g1 = get().dockGrid
    const stacked = g1.length === 1 && g1[0][0] === a1 && g1[0][1] === tNew
    // and back out to its own column on the right
    get().placeDockView(tNew, a1, 'right')
    await new Promise((r) => setTimeout(r, 120))
    const g2 = get().dockGrid
    const besides = g2.length === 2 && g2[0][0] === a1 && g2[1][0] === tNew
    // a third and fourth card both appear — no 3-card cap
    get().addDockSplit(get().terminals[0].id)
    get().requestNewThread()
    await new Promise((r) => setTimeout(r, 150))
    const uncapped = get().dockViews.length === 4 && shown() === 4
    get().removeDockView(tNew)
    get().removeDockView(get().activeThreadId)
    get().removeDockView(get().terminals[0].id)
    await new Promise((r) => setTimeout(r, 120))
    const closes = get().dockViews.length === 1 && shown() === 1
    return { one, appended, heads, stacked, besides, uncapped, closes }
  })()`)
  console.log('SPLITS=' + JSON.stringify(splits))

  // 13c) the rail "+" — must be clickable (NOT window-drag), visibly a button,
  //      and offer every agent preset plus a terminal
  const plus = await win.webContents.executeJavaScript(`(async () => {
    const btn = document.querySelector('.rail-head .drop-btn')
    if (!btn) return { hasBtn: false }
    const noDrag = getComputedStyle(btn).getPropertyValue('-webkit-app-region') === 'no-drag'
    const r = btn.getBoundingClientRect()
    const before = window.__kaisola.getState().assistantThreads.length
    const beforeTerms = window.__kaisola.getState().terminals.length
    btn.click()
    await new Promise((rr) => setTimeout(rr, 150))
    const items = [...document.querySelectorAll('.drop-menu .drop-item')]
    const labels = items.map((i) => i.textContent || '')
    const claudeItem = items.find((i) => /claude/i.test(i.textContent || ''))
    if (claudeItem) claudeItem.click()
    await new Promise((rr) => setTimeout(rr, 150))
    const mid = window.__kaisola.getState()
    const claudeTerm = mid.terminals.find((term) => term.singletonKey === 'agent:claude-code')
    const claudeOpensTerminal =
      (mid.terminals.length === beforeTerms || mid.terminals.length === beforeTerms + 1) &&
      claudeTerm?.boot === 'claude' &&
      claudeTerm?.restart === true &&
      claudeTerm?.name === 'Claude' &&
      mid.dockViews.includes(claudeTerm.id)
    const claudeNoThread = mid.assistantThreads.length === before
    btn.click()
    await new Promise((rr) => setTimeout(rr, 150))
    const items2 = [...document.querySelectorAll('.drop-menu .drop-item')]
    const agentItem = items2.find((i) => /codex/i.test(i.textContent || ''))
      || items.find((i) => /codex/i.test(i.textContent || ''))
    if (agentItem) agentItem.click() // really adds a session
    await new Promise((rr) => setTimeout(rr, 150))
    const after = window.__kaisola.getState().assistantThreads.length
    return {
      hasBtn: true,
      noDrag,
      pronounced: r.width >= 24 && r.height >= 24,
      hasTerminalOption: labels.some((l) => /terminal/i.test(l)),
      agentChoices: labels.length >= 4, // 3+ agent presets + terminal
      claudeOpensTerminal,
      claudeNoThread,
      adds: after === before + 1,
    }
  })()`)
  console.log('PLUS=' + JSON.stringify(plus))

  // 13d) the files/canvas card is RESIZABLE — drag handle, fixed width when
  //      set, clamped, and double-click resets to automatic sharing
  const canvasR = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const wrap = () => document.querySelector('.canvas-wrap')
    const before = wrap().getBoundingClientRect().width
    st.setCanvasWidth(500)
    await new Promise((r) => setTimeout(r, 120))
    const sized = Math.abs(wrap().getBoundingClientRect().width - 500) < 2
    const hasHandle = !!document.querySelector('.canvas-resize')
    st.setCanvasWidth(100)
    const clampedMin = window.__kaisola.getState().canvasWidth === 340
    st.setCanvasWidth(null)
    await new Promise((r) => setTimeout(r, 120))
    const resets = Math.abs(wrap().getBoundingClientRect().width - before) < 2
    return { hasHandle, sized, clampedMin, resets }
  })()`)
  console.log('CANVASR=' + JSON.stringify(canvasR))

  // 13e0) the main view (files/canvas) is minimizable — when hidden the work
  //       row holds only session cards; navigating to a view restores it
  const canvasMin = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    get().setStage('corpus') // canvas shown
    await new Promise((r) => setTimeout(r, 120))
    const shownBefore = !!document.querySelector('.canvas-wrap')
    const hasBtn = !!document.querySelector('.btn-icon[title^="Toggle main view"]')
    get().toggleCanvas()
    await new Promise((r) => setTimeout(r, 120))
    const hidden = !document.querySelector('.canvas-wrap') && get().canvasOpen === false
    const cardsStay = get().dockOpen && !!document.querySelector('.session-card[data-show="true"]')
    get().setStage('claims') // navigating restores the main view
    await new Promise((r) => setTimeout(r, 120))
    const restoredByNav = !!document.querySelector('.canvas-wrap') && get().canvasOpen === true
    get().toggleCanvas()
    await new Promise((r) => setTimeout(r, 100))
    const hiddenAgain = !document.querySelector('.canvas-wrap')
    get().requestFile('/etc/hosts') // opening a file restores it too
    await new Promise((r) => setTimeout(r, 120))
    const restoredByFile = !!document.querySelector('.canvas-wrap') && get().canvasOpen === true
    return { shownBefore, hasBtn, hidden, cardsStay, restoredByNav, restoredByFile }
  })()`)
  console.log('CANVASMIN=' + JSON.stringify(canvasMin))

  // 13e) renderer-drawn window lights — slightly larger than the native 12px,
  //      now living at the top-left of the project tab strip (moved out of the
  //      rail head), clickable (no-drag), IPC-wired
  const lights = await win.webContents.executeJavaScript(`(async () => {
    const ls = [...document.querySelectorAll('.tabstrip .lights .light')]
    if (ls.length !== 3) return { three: false }
    const strip = document.querySelector('.tabstrip').getBoundingClientRect()
    const r = ls[0].getBoundingClientRect()
    return {
      three: true,
      bigger: r.width >= 13,
      // tucked into the strip's top-left corner, and the strip reaches the
      // true window top (the lights are the leftmost chrome now)
      corner: strip.top <= 2 && r.left - strip.left <= 12 && r.top - strip.top <= 16,
      noDrag: getComputedStyle(ls[0].parentElement).getPropertyValue('-webkit-app-region') === 'no-drag',
      ctlApi: typeof window.kaisola.winCtl === 'function',
    }
  })()`)
  console.log('LIGHTS=' + JSON.stringify(lights))

  // 13e-ii) PROJECT TABS — the strip drives independent workspaces. Open a
  //         second tab, prove terminal/dock isolation, round-trip a switch
  //         (both slices survive), and close→reopen to restore the slice. The
  //         strip DOM must show one .ptab per tab with exactly one active.
  const projtabs = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const wait = (ms) => new Promise((r) => setTimeout(r, ms))
    const startTabs = g().projectTabs.length
    const firstId = g().activeProjectId
    const firstTerms = g().terminals.map((t) => t.id).sort().join()
    const firstGrid = JSON.stringify(g().dockGrid)
    // 1) open a SECOND project tab (fresh slice, its own seeded terminal + dock)
    const secondId = g().newProject({ path: null, focus: true })
    await wait(160)
    const isSecondActive = g().activeProjectId === secondId
    const twoTabs = g().projectTabs.length === startTabs + 1
    const secondTerms = g().terminals.map((t) => t.id).sort().join()
    const secondGrid = JSON.stringify(g().dockGrid)
    // isolation: the tabs have DIFFERENT terminal ids and dock grids, and the
    // outgoing first slice is parked intact
    const termsDiffer = !!secondTerms && !!firstTerms && secondTerms !== firstTerms
    const gridsDiffer = secondGrid !== firstGrid
    const parkedFirst = g().projectSlices[firstId]
    const parkedFirstOk = !!parkedFirst && parkedFirst.terminals.map((t) => t.id).sort().join() === firstTerms
    // 2) switch back to the first tab — live fields restored, second parked
    g().switchProject(firstId)
    await wait(160)
    const backToFirst = g().activeProjectId === firstId
    const firstRestored = g().terminals.map((t) => t.id).sort().join() === firstTerms && JSON.stringify(g().dockGrid) === firstGrid
    const parkedSecond = g().projectSlices[secondId]
    const parkedSecondOk = !!parkedSecond && parkedSecond.terminals.map((t) => t.id).sort().join() === secondTerms
    // 3) DOM: a .ptab per tab, exactly one marked active
    const ptabs = [...document.querySelectorAll('.tabstrip .ptab')]
    const domTwoTabs = ptabs.length === startTabs + 1
    const domActiveOne = ptabs.filter((p) => p.getAttribute('data-active') === 'true').length === 1
    // 4) close the second tab, then reopen it from the undo stack — its slice
    //    (terminals + dock) comes back intact
    g().closeProject(secondId, { force: true })
    await wait(140)
    const closedGone = !g().projectTabs.some((t) => t.id === secondId) && g().projectTabs.length === startTabs
    const stackHas = g().closedProjectStack.length >= 1
    g().reopenClosedProject()
    await wait(160)
    const reopened = g().activeProjectId === secondId && g().projectTabs.some((t) => t.id === secondId)
    const reopenedTermsOk = g().terminals.map((t) => t.id).sort().join() === secondTerms
    const reopenedGridOk = JSON.stringify(g().dockGrid) === secondGrid
    // cleanup: drop the reopened tab so downstream groups see a single-tab strip
    g().closeProject(secondId, { force: true })
    await wait(140)
    const backToSingle = g().projectTabs.length === startTabs && g().activeProjectId === firstId
    return {
      twoTabs, isSecondActive, termsDiffer, gridsDiffer, parkedFirstOk,
      backToFirst, firstRestored, parkedSecondOk,
      domTwoTabs, domActiveOne,
      closedGone, stackHas, reopened, reopenedTermsOk, reopenedGridOk, backToSingle,
    }
  })()`)
  console.log('PROJTABS=' + JSON.stringify(projtabs))

  // 13e-iii) tear-off: detaching a tab ships it to a NEW window that adopts it
  //          (same terminal ids — the main-process ptys just change homes)
  const detachInfo = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const before = g().projectTabs.length
    const pid = g().newProject({ path: null, focus: true })
    const movedTermIds = g().terminals.map((t) => t.id)
    await g().detachProjectToWindow(pid)
    await new Promise((r) => setTimeout(r, 200))
    return { pid, movedTermIds, srcTabsAfter: g().projectTabs.length, srcStillHasIt: g().projectTabs.some((t) => t.id === pid), srcTabsBefore: before }
  })()`)
  const windetach = {
    spawned: false,
    adopted: false,
    termsMoved: false,
    srcDropped: detachInfo.srcTabsAfter === detachInfo.srcTabsBefore && !detachInfo.srcStillHasIt,
  }
  {
    const started = Date.now()
    let adoptWin = null
    while (Date.now() - started < 15000 && !adoptWin) {
      adoptWin = BrowserWindow.getAllWindows().find((w) => w !== win && w.webContents.getURL().includes('adopt=1')) ?? null
      if (!adoptWin) await new Promise((r) => setTimeout(r, 250))
    }
    windetach.spawned = !!adoptWin
    if (adoptWin) {
      let probe = null
      const t2 = Date.now()
      while (Date.now() - t2 < 15000) {
        probe = await adoptWin.webContents.executeJavaScript(`(() => {
          if (!window.__kaisola) return null
          const s = window.__kaisola.getState()
          return { tabIds: s.projectTabs.map((t) => t.id), active: s.activeProjectId, termIds: s.terminals.map((t) => t.id) }
        })()`).catch(() => null)
        if (probe && probe.tabIds.includes(detachInfo.pid)) break
        await new Promise((r) => setTimeout(r, 300))
      }
      windetach.adopted = !!probe && probe.tabIds.includes(detachInfo.pid) && probe.active === detachInfo.pid
      windetach.termsMoved = !!probe && detachInfo.movedTermIds.every((id) => probe.termIds.includes(id))
      adoptWin.destroy()
    }
  }
  console.log('WINDETACH=' + JSON.stringify(windetach))

  // 13f) the window figure beside each session toggles its CARD — press to put
  //      the card away (the session stays alive), press again to bring it back;
  //      putting away the last card hides the whole work area
  const toggle = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const a1 = get().assistantThreads[0].id
    get().setDockView(a1)
    await new Promise((r) => setTimeout(r, 120))
    const fig = () => document.querySelectorAll('.wsrail .session-row')[0].querySelector('.session-split')
    if (!fig()) return { hasFig: false }
    const visibleAtRest = getComputedStyle(fig()).opacity === '1'
    fig().click()
    await new Promise((r) => setTimeout(r, 120))
    const putAway = !get().dockViews.includes(a1) || !get().dockOpen
    fig().click()
    await new Promise((r) => setTimeout(r, 120))
    const back = get().dockOpen && get().dockViews.includes(a1)
    for (const v of [...get().dockViews]) get().removeDockView(v)
    await new Promise((r) => setTimeout(r, 120))
    const hidesAll = get().dockOpen === false && !document.querySelector('.session-card[data-show="true"]')
    get().setDock(true, 'assistant')
    return { hasFig: true, visibleAtRest, putAway, back, hidesAll }
  })()`)
  console.log('TOGGLE=' + JSON.stringify(toggle))

  // 13g) sessions name themselves — threads from the first message's topic,
  //      terminals from the command they run; a manual rename always wins
  const autoname = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    get().requestNewThread('mock')
    const tid = get().activeThreadId
    get().autoNameThread(tid, 'investigate flaky parser tests in the CI pipeline')
    await new Promise((r) => setTimeout(r, 120))
    const th = () => get().assistantThreads.find((t) => t.id === tid)
    const named = !!th().autoName && th().autoName.startsWith('Investigate flaky parser')
    const rowShows = [...document.querySelectorAll('.wsrail .session-row')].some((r) => (r.textContent || '').includes('Investigate flaky'))
    get().autoNameThread(tid, 'a totally different topic now')
    const sticky = !!th().autoName && th().autoName.startsWith('Investigate')
    get().renameAssistantThread(tid, 'Parser deep-dive')
    await new Promise((r) => setTimeout(r, 100))
    const manualWins = [...document.querySelectorAll('.wsrail .session-row')].some((r) => (r.textContent || '').includes('Parser deep-dive'))
    get().requestTerminal('echo train-model-v2')
    await new Promise((r) => setTimeout(r, 120))
    const term = get().terminals[get().terminals.length - 1]
    const termNamed = !!term.autoName && term.autoName.startsWith('Echo train-model-v2')
    get().closeAssistantThread(tid)
    get().closeTerminal(term.id)
    return { named, rowShows, sticky, manualWins, termNamed }
  })()`)
  console.log('AUTONAME=' + JSON.stringify(autoname))

  // 14) the old workflow sidebar is hidden for now; the workspace rail is the
  //     only persistent side surface.
  const minimalUi = await win.webContents.executeJavaScript(`(async () => {
    await new Promise((r) => setTimeout(r, 120))
    return {
      noSidebar: !document.querySelector('.sidebar'),
      noSidebarResize: !document.querySelector('.sidebar-resize'),
      noStageNav: document.querySelectorAll('.side-nav-item').length === 0,
      hasRail: !!document.querySelector('.wsrail'),
      hasPlus: !!document.querySelector('.rail-head .drop-btn'),
      hasFiles: !!document.querySelector('.wsrail-files'),
    }
  })()`)
  console.log('MINIMAL_UI=' + JSON.stringify(minimalUi))

  // 15) settings exposes the appearance/layout configuration
  const settings = await win.webContents.executeJavaScript(`(async () => {
    window.__kaisola.getState().setSettingsOpen(true)
    await new Promise((r) => setTimeout(r, 150))
    // Zed-style settings: a nav of categories, one pane at a time
    const navNames = [...document.querySelectorAll('.settings-nav-item')].map((e) => e.textContent || '')
    const hasAppearance = navNames.some((l) => /General/.test(l)) && /Theme/.test(document.querySelector('.settings-pane')?.textContent || '')
    const hasSidebarControls = /Sidebar/.test(document.querySelector('.settings-panel-v2')?.textContent || '')
    window.__kaisola.getState().setSettingsOpen(false)
    return { hasAppearance, noSidebarControls: !hasSidebarControls }
  })()`)
  console.log('SETTINGS=' + JSON.stringify(settings))

  // 16) a dropdown opened from the right-docked pane's foot stays on-screen
  const dropfit = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setDock(true, 'assistant')
    await new Promise((r) => setTimeout(r, 150))
    const btn = document.querySelector('.session-card[data-show="true"] .assistant-foot .drop-btn')
    if (!btn) { return { hasBtn: false, fits: false } }
    btn.click()
    await new Promise((r) => setTimeout(r, 150))
    const menu = document.querySelector('body > .drop-menu')
    const r = menu && menu.getBoundingClientRect()
    const fits = !!(r && r.left >= 0 && r.right <= window.innerWidth + 1)
    btn.click()
    return { hasBtn: true, fits }
  })()`)
  console.log('DROPFIT=' + JSON.stringify(dropfit))

  // 17) the agent runner — runAgent appends a reviewable Proposal (offline
  //     deterministic fallback path, since the smoke has no API key), exercising
  //     the runner + relevance context builder end-to-end.
  const agentrun = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.loadDemo()
    await new Promise((r) => setTimeout(r, 120))
    const before = window.__kaisola.getState().project.proposals.length
    await window.__kaisola.getState().runAgent('hypothesis')
    await new Promise((r) => setTimeout(r, 120))
    const props = window.__kaisola.getState().project.proposals
    const last = props[props.length - 1]
    return {
      added: props.length - before,
      agentId: last && last.agentId,
      hasChanges: !!(last && last.changes && last.changes.length),
      status: last && last.status,
    }
  })()`)
  console.log('AGENTRUN=' + JSON.stringify(agentrun))

  // 17b) approving an agent proposal actually MUTATES the trajectory (the keystone:
  //      create a hypothesis via payload, then patch one via novelty).
  const approve = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState().project
    window.__kaisola.getState().loadDemo()
    await new Promise((r) => setTimeout(r, 80))
    const hBefore = g().hypotheses.length
    await window.__kaisola.getState().runAgent('hypothesis')
    await new Promise((r) => setTimeout(r, 120))
    const createProp = g().proposals[g().proposals.length - 1]
    window.__kaisola.getState().approveProposal(createProp.id)
    await new Promise((r) => setTimeout(r, 40))
    const hypAdded = g().hypotheses.length - hBefore
    const createStatus = (g().proposals.find((p) => p.id === createProp.id) || {}).status
    const targetId = g().hypotheses[0] && g().hypotheses[0].id
    await window.__kaisola.getState().runAgent('novelty')
    await new Promise((r) => setTimeout(r, 120))
    const updProp = g().proposals[g().proposals.length - 1]
    window.__kaisola.getState().approveProposal(updProp.id)
    await new Promise((r) => setTimeout(r, 40))
    const target = g().hypotheses.find((h) => h.id === targetId)
    return { hypAdded, createStatus, patched: !!(target && target.noveltyRisk === 3) }
  })()`)
  console.log('APPROVE=' + JSON.stringify(approve))

  // 17b) checkpoint / undo timeline — approving snapshots the pre-mutation project;
  //      undoLast reverts it and consumes that checkpoint (pure local, zero model cost).
  const checkpoint = await win.webContents.executeJavaScript(`(async () => {
    const S = () => window.__kaisola.getState()
    S().loadDemo()
    await new Promise((r) => setTimeout(r, 80))
    const ckBefore = S().checkpoints.length
    const hypBefore = S().project.hypotheses.length
    await S().runAgent('hypothesis')
    await new Promise((r) => setTimeout(r, 120))
    const prop = S().project.proposals[S().project.proposals.length - 1]
    S().approveProposal(prop.id)
    await new Promise((r) => setTimeout(r, 40))
    const madeCheckpoint = S().checkpoints.length > ckBefore
    const grew = S().project.hypotheses.length > hypBefore
    S().undoLast()
    await new Promise((r) => setTimeout(r, 40))
    const reverted = S().project.hypotheses.length === hypBefore
    const consumed = S().checkpoints.length === ckBefore
    return { madeCheckpoint, grew, reverted, consumed }
  })()`)
  console.log('CHECKPOINT=' + JSON.stringify(checkpoint))

  // 17c) background agent queue + best-of-N — sequential drain, grouped tasks (cost-bounded)
  const queue = await win.webContents.executeJavaScript(`(async () => {
    const S = () => window.__kaisola.getState()
    S().loadDemo()
    await new Promise((r) => setTimeout(r, 80))
    const before = S().project.proposals.length
    S().enqueueAgent('hypothesis', { count: 3 })
    for (let i = 0; i < 80 && (S().agentQueueRunning || S().agentTasks.some((t) => t.status === 'queued' || t.status === 'running')); i++) {
      await new Promise((r) => setTimeout(r, 50))
    }
    const tasks = S().agentTasks.filter((t) => t.agentId === 'hypothesis')
    const groups = new Set(tasks.filter((t) => t.groupId).map((t) => t.groupId))
    const after = S().project.proposals.length
    return {
      enqueued: tasks.length >= 3,
      ready: tasks.filter((t) => t.status === 'ready').length,
      grouped: groups.size === 1,
      grew: after - before >= 3,
      drained: S().agentQueueRunning === false,
    }
  })()`)
  console.log('QUEUE=' + JSON.stringify(queue))

  // 17d) best-of-N grouping + pick-winner — competing proposals share a groupId;
  //      picking a winner approves it and rejects its siblings (the gate is the selector)
  const bestof = await win.webContents.executeJavaScript(`(async () => {
    const S = () => window.__kaisola.getState()
    S().loadDemo()
    await new Promise((r) => setTimeout(r, 80))
    S().enqueueAgent('hypothesis', { count: 3 })
    for (let i = 0; i < 80 && (S().agentQueueRunning || S().agentTasks.some((t) => t.status === 'queued' || t.status === 'running')); i++) {
      await new Promise((r) => setTimeout(r, 50))
    }
    const pending = S().project.proposals.filter((p) => p.status === 'pending')
    const groups = {}
    pending.forEach((p) => { if (p.groupId) groups[p.groupId] = (groups[p.groupId] || 0) + 1 })
    const gid = Object.keys(groups).find((g) => groups[g] >= 3)
    const grouped = !!gid
    const members = S().project.proposals.filter((p) => p.groupId === gid)
    const winner = members[0]
    S().pickWinner(winner.id)
    await new Promise((r) => setTimeout(r, 40))
    const after = S().project.proposals
    return {
      grouped,
      winnerApproved: (after.find((p) => p.id === winner.id) || {}).status === 'approved',
      siblingsRejected: after.filter((p) => p.groupId === gid && p.id !== winner.id).every((p) => p.status === 'rejected'),
      noPendingLeft: after.filter((p) => p.groupId === gid && p.status === 'pending').length === 0,
    }
  })()`)
  console.log('BESTOFN=' + JSON.stringify(bestof))

  // 17e) workflows / automation — a manual run enqueues its steps onto the queue;
  //      CRUD edits persist in state (Settings drives these).
  const workflow = await win.webContents.executeJavaScript(`(async () => {
    const S = () => window.__kaisola.getState()
    S().loadDemo()
    await new Promise((r) => setTimeout(r, 60))
    const seeded = S().workflows.length >= 2
    const ideasWf = S().workflows.find((w) => w.name === 'Generate 3 ideas')
    const before = S().project.proposals.length
    S().runWorkflow(ideasWf.id)
    for (let i = 0; i < 80 && (S().agentQueueRunning || S().agentTasks.some((t) => t.status === 'queued' || t.status === 'running')); i++) {
      await new Promise((r) => setTimeout(r, 50))
    }
    const ran = S().project.proposals.length - before >= 3
    const n0 = S().workflows.length
    S().addWorkflow('Test WF')
    const added = S().workflows.length === n0 + 1
    const wf = S().workflows[S().workflows.length - 1]
    S().addWorkflowStep(wf.id)
    const twoSteps = (S().workflows.find((w) => w.id === wf.id) || {}).steps.length === 2
    S().updateWorkflowStep(wf.id, wf.steps[0].id, { kind: 'stage', ref: 'ideas', count: 2 })
    const st = S().workflows.find((w) => w.id === wf.id).steps[0]
    const updated = st.kind === 'stage' && st.ref === 'ideas' && st.count === 2
    S().deleteWorkflow(wf.id)
    const deleted = S().workflows.length === n0
    return { seeded, ran, added, twoSteps, updated, deleted }
  })()`)
  console.log('WORKFLOW=' + JSON.stringify(workflow))

  // 17f) automation master switch + reset-queue escape hatch
  const automation = await win.webContents.executeJavaScript(`(async () => {
    const S = () => window.__kaisola.getState()
    S().loadDemo()
    S().resetQueue()
    S().setAutonomy('propose')
    const offDefault = S().automationsEnabled === false
    const wf = S().workflows[0]
    S().setWorkflowTrigger(wf.id, 'on-stage', 'questions')
    // disabled (default) → entering the armed stage must NOT enqueue
    S().setStage('questions')
    await new Promise((r) => setTimeout(r, 40))
    const noFireWhenOff = S().agentTasks.length === 0
    // enabled → entering the armed stage from a different stage DOES enqueue
    S().setAutomationsEnabled(true)
    S().setStage('ideas')
    await new Promise((r) => setTimeout(r, 40))
    S().setStage('questions')
    await new Promise((r) => setTimeout(r, 60))
    const firedWhenOn = S().agentTasks.length > 0
    S().resetQueue()
    const resetClears = S().agentTasks.length === 0 && S().agentQueueRunning === false
    // leave automations off so it doesn't perturb later checks
    S().setAutomationsEnabled(false)
    return { offDefault, noFireWhenOff, firedWhenOn, resetClears }
  })()`)
  console.log('AUTOMATION=' + JSON.stringify(automation))

  // 17g) toasts — dedupe + cap-at-3 + dismiss, and an agent run emits one
  const toast = await win.webContents.executeJavaScript(`(async () => {
    const S = () => window.__kaisola.getState()
    S().toasts.slice().forEach((t) => S().dismissToast(t.id))
    S().pushToast('success', 'A')
    S().pushToast('success', 'A')
    const deduped = S().toasts.length === 1
    S().pushToast('info', 'B'); S().pushToast('warn', 'C'); S().pushToast('error', 'D')
    const capped = S().toasts.length === 3
    const firstId = S().toasts[0].id
    S().dismissToast(firstId)
    const dismissed = !S().toasts.some((t) => t.id === firstId)
    S().toasts.slice().forEach((t) => S().dismissToast(t.id))
    S().loadDemo()
    await S().runAgent('hypothesis')
    const agentToast = S().toasts.some((t) => t.kind === 'success')
    return { deduped, capped, dismissed, agentToast }
  })()`)
  console.log('TOAST=' + JSON.stringify(toast))

  // 18) tournament ranking — deterministic pairwise Elo over the demo hypotheses
  const tourney = await win.webContents.executeJavaScript(`(async () => {
    const lib = window.__kaisolaLib
    const hyps = window.__kaisola.getState().project.hypotheses
    const ranked = await lib.tournament(hyps)
    const ranks = ranked.map((r) => r.rank)
    const sortedDesc = ranked.every((r, i) => i === 0 || ranked[i - 1].elo >= r.elo)
    const uniqueRanks = new Set(ranks).size === ranks.length
    return { n: ranked.length, sortedDesc, uniqueRanks, topElo: ranked[0] && ranked[0].elo }
  })()`)
  console.log('TOURNEY=' + JSON.stringify(tourney))

  // 19) citation verification — quote-match + entailment, deterministic offline
  const verify = await win.webContents.executeJavaScript(`(async () => {
    const lib = window.__kaisolaLib
    const src = 'We find that agents track wall-clock time from tool latency without an explicit timer.'
    const good = await lib.verifyCitation({ quote: 'agents track wall-clock time from tool latency', claim: 'Agents can infer elapsed time from tool latency', sourceText: src })
    const missing = await lib.verifyCitation({ quote: 'agents use a hidden GPS sensor', claim: 'Agents can infer location', sourceText: src })
    const noQuote = await lib.verifyCitation({ quote: '', claim: 'x', sourceText: src })
    // regression: a strongly-entailing quote that contains a contrast cue word
    // ("no significant") must stay 'supporting', not flip to 'contrasting'.
    const cs = await lib.verifyCitation({ quote: 'no significant overhead was observed', claim: 'the method has no significant overhead', sourceText: 'in our experiments, no significant overhead was observed for the method' })
    return {
      goodVerified: good.verified === true && good.quoteFound === true,
      missingRejected: missing.verified === false && missing.quoteFound === false,
      noQuoteRejected: noQuote.verified === false,
      goodSupporting: good.stance === 'supporting',
      missingMention: missing.stance === 'mentioning',
      contrastSupporting: cs.stance === 'supporting',
      pagerankOk: Object.keys(lib.pagerank(window.__kaisola.getState().project.claimGraph)).length > 0,
    }
  })()`)
  console.log('VERIFY=' + JSON.stringify(verify))

  // 19b) claim linter — pure, deterministic lint over provenance (zero model cost)
  const lint = await win.webContents.executeJavaScript(`(() => {
    const lib = window.__kaisolaLib
    const unsupported = lib.lintProvenanced({ trust: 'unsupported', provenance: [] })
    const unverified = lib.lintProvenanced({ trust: 'medium', provenance: [{ id: 'l1', kind: 'citation', sourceId: 'p1', quote: 'q', verified: false }] })
    const clean = lib.lintProvenanced({ trust: 'high', provenance: [{ id: 'l2', kind: 'citation', sourceId: 'p1', quote: 'q', verified: true }] })
    const spec = lib.lintProvenanced({ trust: 'unsupported', provenance: [], speculative: true })
    return {
      flagsUnsupported: unsupported.some((i) => i.kind === 'unsupported'),
      flagsUnverified: unverified.some((i) => i.kind === 'unverified-citation'),
      cleanQuiet: clean.length === 0,
      specExempt: spec.length === 0,
      severity: lib.lintSeverity(unsupported) === 'unsupported',
    }
  })()`)
  console.log('LINT=' + JSON.stringify(lint))

  // 20) store-level verifyCitations corroborates the one unverified demo citation
  //     (quote is literally in P(0)'s abstract) → flips it verified + trust→high.
  const verifyStore = await win.webContents.executeJavaScript(`(async () => {
    window.__kaisola.getState().loadDemo()
    await new Promise((r) => setTimeout(r, 60))
    const nodeBefore = window.__kaisola.getState().project.claimGraph.nodes.find((n) => n.id === 'g_long_horizon')
    const before = window.__kaisola.getState().project.activity.length
    await window.__kaisola.getState().verifyCitations()
    await new Promise((r) => setTimeout(r, 80))
    const st = window.__kaisola.getState().project
    const node = st.claimGraph.nodes.find((n) => n.id === 'g_long_horizon')
    const cit = node && node.provenance.find((p) => p.kind === 'citation')
    return {
      ran: st.activity.length > before,
      wasUnverified: !!(nodeBefore && nodeBefore.provenance.find((p) => p.kind === 'citation' && !p.verified)),
      flipped: !!(cit && cit.verified),
      trustHigh: node && node.trust === 'high',
      note: st.activity[0] && st.activity[0].text,
    }
  })()`)
  console.log('VERIFYSTORE=' + JSON.stringify(verifyStore))

  // 21) per-agent model config — the STORE round-trips (palette/agents use it),
  //     while Settings no longer shows the legacy per-agent grid (IDE-first prune)
  const models = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setAgentModel('analysis', 'claude-opus-4-7')
    const setOk = window.__kaisola.getState().agentModels.analysis === 'claude-opus-4-7'
    st.setAgentModel('analysis', '')
    const cleared = window.__kaisola.getState().agentModels.analysis === undefined
    st.setSettingsOpen(true)
    await new Promise((r) => setTimeout(r, 150))
    // models plumbing lives in the "Models & API keys" pane — click its nav item
    const nav = [...document.querySelectorAll('.settings-nav-item')].find((b) => /Models/.test(b.textContent || ''))
    if (nav) nav.click()
    await new Promise((r) => setTimeout(r, 80))
    const hasSection = !/Model per agent/.test(document.querySelector('.settings-pane')?.textContent || '')
    st.setSettingsOpen(false)
    return { setOk, cleared, hasSection }
  })()`)
  console.log('MODELS=' + JSON.stringify(models))

  // 21b) agent reasoning provider — defaults to cheap OpenAI, switchable, persisted;
  //      the OpenAI key plumbing round-trips through main (never the renderer).
  const reasoning = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const defaultOpenai = g().reasoningProvider === 'openai'
    g().setReasoningProvider('local')
    const toLocal = g().reasoningProvider === 'local'
    g().setOpenaiModel('gpt-4.1-nano')
    const modelSet = g().openaiModel === 'gpt-4.1-nano'
    g().setReasoningProvider('openai'); g().setOpenaiModel('gpt-4o-mini')
    const oa = await window.kaisola.settings.hasOpenaiKey()
    g().setSettingsOpen(true)
    await new Promise((r) => setTimeout(r, 140))
    const nav = [...document.querySelectorAll('.settings-nav-item')].find((b) => /Models/.test(b.textContent || ''))
    if (nav) nav.click()
    await new Promise((r) => setTimeout(r, 80))
    const hasSection = /Reasoning provider/.test(document.querySelector('.settings-pane')?.textContent || '')
    g().setSettingsOpen(false)
    return { defaultOpenai, toLocal, modelSet, hasSection, keyApi: !!(oa && oa.ok === true), keyAbsent: !!(oa && oa.present === false) }
  })()`)
  console.log('REASONING=' + JSON.stringify(reasoning))

  // 21c) the official OpenAI SDK (strict json_schema) loads in main + fails gracefully
  const oaisdk = await win.webContents.executeJavaScript(`(async () => {
    const r = await window.kaisola.model.call({
      provider: 'openai', apiKey: 'sk-smoke', baseUrl: 'http://127.0.0.1:9/v1', model: 'gpt-4o-mini',
      responseSchema: { name: 'emit_proposal', schema: { type: 'object', additionalProperties: false, properties: { proposals: { type: 'array', items: { type: 'object' } } }, required: ['proposals'] } },
      messages: [{ role: 'user', content: 'hi' }],
    })
    return { handled: !!(r && r.ok === false) }
  })()`)
  console.log('OPENAISDK=' + JSON.stringify(oaisdk))

  // 21d) Codex (subscription) provider — persists, codex exec is wired (disabled in smoke)
  const codex = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    g().setReasoningProvider('codex')
    const persists = g().reasoningProvider === 'codex'
    const ex = await window.kaisola.codex.exec({ prompt: 'hi' })
    g().setSettingsOpen(true)
    await new Promise((r) => setTimeout(r, 120))
    // the reasoning/codex note lives in the "Models & API keys" pane
    const nav = [...document.querySelectorAll('.settings-nav-item')].find((b) => /Models/.test(b.textContent || ''))
    if (nav) nav.click()
    await new Promise((r) => setTimeout(r, 80))
    const body = (document.querySelector('.settings-pane') || {}).textContent || ''
    // Zed-style settings: 6 nav categories, exactly one active, no folds left
    const tabsOk = document.querySelectorAll('.settings-fold').length === 0 &&
      document.querySelectorAll('.settings-nav-item').length === 6 &&
      document.querySelectorAll('.settings-nav-item[data-active="true"]').length === 1
    g().setSettingsOpen(false)
    g().setReasoningProvider('openai')
    return { persists, execHandled: !!(ex && ex.ok === false), showsCodexNote: /codex exec/.test(body), tabsOk }
  })()`)
  console.log('CODEX=' + JSON.stringify(codex))

  // 22) supervisor — with the minimal shell pinned to Files, the old stage
  //     supervisor should stay quiet unless a future workflow re-exposes stages.
  const supervisor = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.loadDemo()
    await new Promise((r) => setTimeout(r, 80))
    const before = window.__kaisola.getState().project.proposals.length
    await window.__kaisola.getState().runStageAgents()
    await new Promise((r) => setTimeout(r, 150))
    const props = window.__kaisola.getState().project.proposals
    const ids = props.slice(before).map((p) => p.agentId)
    return { added: props.length - before, ids, stage: window.__kaisola.getState().stage }
  })()`)
  console.log('SUPERVISOR=' + JSON.stringify(supervisor))

  // 23) OpenAlex helpers — DOI extraction + abstract-inverted-index reconstruction (pure)
  const openalex = await win.webContents.executeJavaScript(`(async () => {
    const lib = window.__kaisolaLib
    const doi = lib.extractDoi('see https://doi.org/10.1145/3597503.3608131 for details.')
    const abs = lib.reconstructAbstract({ 'Time': [0], 'flies': [1], 'fast': [2] })
    const norm = lib.normalizeOaId('https://openalex.org/W2741809807')
    const refs = lib.resolveReferences(['https://openalex.org/W1', 'W2', 'W9'], { W1: 'pap_a', W2: 'pap_b' })
    return {
      doi, doiOk: doi === '10.1145/3597503.3608131', abs, absOk: abs === 'Time flies fast',
      normOk: norm === 'W2741809807',
      refsOk: refs.length === 2 && refs.includes('pap_a') && refs.includes('pap_b'),
    }
  })()`)
  console.log('OPENALEX=' + JSON.stringify(openalex))

  // 23b) buildCitationGraph runs gracefully (offline → resolves nothing, no throw)
  const citegraph = await win.webContents.executeJavaScript(`(async () => {
    window.__kaisola.getState().loadDemo()
    await new Promise((r) => setTimeout(r, 60))
    const before = window.__kaisola.getState().project.activity.length
    await window.__kaisola.getState().buildCitationGraph()
    await new Promise((r) => setTimeout(r, 80))
    return { ran: window.__kaisola.getState().project.activity.length > before }
  })()`)
  console.log('CITEGRAPH=' + JSON.stringify(citegraph))

  // 23c) GROBID TEI parser (pure) — title/coords/sentence + quote location
  const grobid = await win.webContents.executeJavaScript(`(async () => {
    const lib = window.__kaisolaLib
    const tei = '<?xml version="1.0"?><TEI xmlns="http://www.tei-c.org/ns/1.0">' +
      '<teiHeader><fileDesc><titleStmt><title>Time Awareness in Agents</title></titleStmt></fileDesc></teiHeader>' +
      '<text><body><div><p>' +
      '<s coords="3,120.5,340.2,200.1,12.3">Agents infer elapsed time from tool latency.</s>' +
      '<s coords="3,120.5,360.0,180.0,12.3">A timer is not required.</s>' +
      '</p></div></body></text></TEI>'
    const doc = lib.parseTei(tei)
    const box = lib.parseCoords('3,120.5,340.2,200.1,12.3')
    const hit = lib.locateQuote(doc, 'infer elapsed time from tool latency')
    return {
      title: doc.title,
      sentences: doc.sentences.length,
      fullHasText: doc.fullText.includes('Agents infer elapsed time'),
      boxOk: box && box.page === 3 && box.w === 200.1,
      located: !!(hit && hit.bbox && hit.bbox.page === 3),
    }
  })()`)
  console.log('GROBID=' + JSON.stringify(grobid))

  // 23d) ingestAllPdfs runs gracefully with no endpoint set (no throw)
  const grobidStore = await win.webContents.executeJavaScript(`(async () => {
    window.__kaisola.getState().loadDemo()
    const before = window.__kaisola.getState().project.activity.length
    await window.__kaisola.getState().ingestAllPdfs()
    await new Promise((r) => setTimeout(r, 60))
    return { ran: window.__kaisola.getState().project.activity.length > before }
  })()`)
  console.log('GROBIDSTORE=' + JSON.stringify(grobidStore))

  // 23e) experiment sandbox — gate (needs Execute + computeApproved), then a mock
  //      run that streams a notebook into a new Run record.
  const sandbox = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    g().loadDemo()
    await new Promise((r) => setTimeout(r, 60))
    const plan = g().project.experiments[0]
    if (!plan) return { noPlan: true }
    // gated off: observe autonomy + not approved → no run created
    g().setAutonomy('observe')
    const runsBefore = g().project.runs.length
    await g().runExperiment(plan.id)
    const blocked = g().project.runs.length === runsBefore
    // approve compute + raise autonomy → mock run creates a Run with a notebook
    g().setAutonomy('execute')
    g().approveCompute(plan.id)
    g().setSandboxMode('mock')
    await g().runExperiment(plan.id)
    await new Promise((r) => setTimeout(r, 120))
    const runs = g().project.runs
    const run = runs[runs.length - 1]
    return {
      blocked,
      added: runs.length - runsBefore,
      status: run && run.status,
      notebookLines: run ? run.notebook.length : 0,
      computeApproved: g().project.experiments[0].computeApproved === true,
    }
  })()`)
  console.log('SANDBOX=' + JSON.stringify(sandbox))

  // 23f) durable DB — set/get/del round-trip + which backend is active
  const db = await win.webContents.executeJavaScript(`(async () => {
    await window.kaisola.db.set('smoke-key', 'hello-123')
    await new Promise((r) => setTimeout(r, 60))
    const v = window.kaisola.db.getSync('smoke-key')
    await window.kaisola.db.del('smoke-key')
    await new Promise((r) => setTimeout(r, 60))
    const after = window.kaisola.db.getSync('smoke-key')
    const kind = await window.kaisola.db.kind()
    return { roundTrip: v === 'hello-123', deleted: after == null, backend: kind.kind, reason: kind.reason }
  })()`)
  console.log('DB=' + JSON.stringify(db))

  // 30) worktree isolation — real git lifecycle on a throwaway repo + the
  //     file-patch Proposal round-trip (create → write → finalize → diff →
  //     createWorktreeProposal → merge → remove). Pure local git, zero model cost.
  let wt = { ok: false }
  try {
    const cp = require('child_process'), fsx = require('fs'), px = require('path'), osx = require('os')
    const repo = fsx.mkdtempSync(px.join(osx.tmpdir(), 'pz-wt-'))
    const g = (args) => cp.execFileSync('git', args, { cwd: repo, stdio: 'pipe' })
    g(['init', '-q']); g(['config', 'user.email', 't@t']); g(['config', 'user.name', 't'])
    fsx.writeFileSync(px.join(repo, 'README.md'), 'base\n')
    g(['add', '-A']); g(['commit', '-q', '-m', 'init'])
    const taskId = 'smoke1'
    const cr = await worktree.create(repo, taskId)
    fsx.writeFileSync(px.join(cr.path, 'feature.txt'), 'hello from the agent\n')
    await worktree.finalize(taskId, 'add feature')
    const df = await worktree.diff(taskId)
    const hasFile = (df.files || []).some((f) => f.path === 'feature.txt')
    const prop = await win.webContents.executeJavaScript('(() => {' +
      'const S = window.__kaisola.getState();' +
      'const before = S.project.proposals.length;' +
      'S.createWorktreeProposal(' + JSON.stringify({ taskId, branch: cr.branch, repo, agentId: 'coding', patch: df.patch, files: df.files }) + ');' +
      'const after = window.__kaisola.getState().project.proposals;' +
      'const p = after[after.length - 1];' +
      'return { added: after.length - before, isFile: p.changes.some((c) => c.entityType === "file"), pending: p.status === "pending" };' +
    '})()')
    const mg = await worktree.merge(taskId)
    const merged = fsx.existsSync(px.join(repo, 'feature.txt'))
    await worktree.remove(taskId)
    wt = { created: !!cr.ok, hasFile, propAdded: prop.added === 1, isFile: prop.isFile, merged: mg.ok && merged, removed: !fsx.existsSync(cr.path) }
  } catch (e) {
    wt = { ok: false, error: String((e && e.message) || e) }
  }
  console.log('WORKTREE=' + JSON.stringify(wt))

  // 24) the agent registry: built-ins cover the main CLIs, the + menu lists
  //     enabled agents + the panel entries, and custom agents round-trip
  const registry = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const presets = await window.kaisola.acp.presets()
    const ids = presets.map((p) => p.id)
    const hasMainOnes = ['claude-code', 'codex', 'opencode', 'gemini', 'qwen', 'kimi', 'aider', 'amp'].every((id) => ids.includes(id))
    const defaults = g().enabledAgents.join(',') === 'claude-code,codex,opencode'
    g().toggleAgentEnabled('qwen')
    const qwenOn = g().enabledAgents.includes('qwen')
    g().toggleAgentEnabled('qwen')
    const qwenOff = !g().enabledAgents.includes('qwen')
    g().addCustomAgent({ id: 'custom-smoke', name: 'Smokey', kind: 'terminal', command: 'true', args: [] })
    const customAdded = g().customAgents.some((a) => a.id === 'custom-smoke')
    const btn = document.querySelector('.rail-head .drop-btn')
    btn.click()
    await new Promise((r) => setTimeout(r, 150))
    const labels = [...document.querySelectorAll('.drop-menu .drop-item')].map((i) => i.textContent || '')
    // Dropdown closes on MOUSEDOWN outside — body.click() alone leaves it open
    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 80))
    const menuHasCustom = labels.some((l) => /Smokey/.test(l))
    const menuHasPanels = labels.some((l) => /Git commit/.test(l)) && labels.some((l) => /Browser/.test(l)) && labels.some((l) => /Add agents/.test(l))
    g().removeCustomAgent('custom-smoke')
    const customRemoved = !g().customAgents.some((a) => a.id === 'custom-smoke')
    return { count: presets.length, hasMainOnes, defaults, qwenOn, qwenOff, customAdded, menuHasCustom, menuHasPanels, customRemoved }
  })()`)
  console.log('REGISTRY=' + JSON.stringify(registry))

  // 25) the commit panel: stage → commit → log against a REAL repo (the only
  //     surface allowed to touch the user's index), and the card renders
  let gitpanel = {}
  try {
    const repo = path.join(os.tmpdir(), `pasola-smoke-commit-${Date.now()}`)
    fsx.mkdirSync(repo, { recursive: true })
    const { execFileSync } = require('node:child_process')
    execFileSync('git', ['init', '-q'], { cwd: repo })
    execFileSync('git', ['-c', 'user.name=Smoke', '-c', 'user.email=s@s', 'commit', '-q', '--allow-empty', '-m', 'root'], { cwd: repo })
    fsx.writeFileSync(path.join(repo, 'alpha.txt'), 'one\n')
    gitpanel = await win.webContents.executeJavaScript(`(async () => {
      const repo = ${JSON.stringify(repo)}
      const g = () => window.__kaisola.getState()
      const st0 = await window.kaisola.git.stageStatus(repo)
      const sawUnstaged = !!st0.ok && st0.unstaged.length === 1 && st0.unstaged[0].path === 'alpha.txt' && st0.staged.length === 0
      await window.kaisola.git.stage(repo, ['alpha.txt'])
      const st1 = await window.kaisola.git.stageStatus(repo)
      const sawStaged = !!st1.ok && st1.staged.length === 1 && st1.unstaged.length === 0
      await window.kaisola.git.unstage(repo, ['alpha.txt'])
      const st2 = await window.kaisola.git.stageStatus(repo)
      const unstagedBack = !!st2.ok && st2.staged.length === 0 && st2.unstaged.length === 1
      await window.kaisola.git.stage(repo, ['alpha.txt'])
      const commit = await window.kaisola.git.commit(repo, 'smoke: add alpha')
      const st3 = await window.kaisola.git.stageStatus(repo)
      const clean = !!st3.ok && st3.staged.length === 0 && st3.unstaged.length === 0
      const lg = await window.kaisola.git.log(repo, 5)
      const logged = !!lg.ok && lg.commits.length === 2 && lg.commits[0].subject === 'smoke: add alpha'
      // the card: opens in the grid, renders the panel, closes cleanly
      g().openGitPanel()
      await new Promise((r) => setTimeout(r, 200))
      const inGrid = g().dockViews.includes('panel-git')
      const rendered = !!document.querySelector('.session-card[data-show="true"] .git-panel')
      const railRow = [...document.querySelectorAll('.wsrail .session-row')].some((row) => /Commit/.test(row.textContent || ''))
      g().closePanel('panel-git')
      await new Promise((r) => setTimeout(r, 120))
      const closed = !g().panels.some((p) => p.id === 'panel-git') && !g().dockViews.includes('panel-git')
      return { sawUnstaged, sawStaged, unstagedBack, committed: !!commit.ok && !!commit.sha, clean, logged, inGrid, rendered, railRow, closed }
    })()`)
    fsx.rmSync(repo, { recursive: true, force: true })
  } catch (e) {
    gitpanel = { error: String((e && e.message) || e) }
  }
  console.log('GITPANEL=' + JSON.stringify(gitpanel))

  // 26) browser cards: open empty (no guest process), URL state round-trips,
  //     rail row + card render, close cleanly
  const browser = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    g().openBrowserPanel()
    await new Promise((r) => setTimeout(r, 200))
    const panel = g().panels.find((p) => p.kind === 'browser')
    const opened = !!panel && g().dockViews.includes(panel.id)
    const rendered = !!document.querySelector('.session-card[data-show="true"] .web-panel')
    const emptyState = !!document.querySelector('.web-empty') // no url yet → no webview guest
    g().setPanelState(panel.id, { url: 'http://localhost:3000/', title: 'Dev' })
    const stored = g().panels.find((p) => p.id === panel.id)
    const urlKept = stored.url === 'http://localhost:3000/' && stored.title === 'Dev'
    // same-origin re-point reuses the card (no second browser panel)
    g().openBrowserPanel('http://localhost:3000/x')
    const reused = g().panels.filter((p) => p.kind === 'browser').length === 1
    const bumped = g().panels.find((p) => p.id === panel.id).seq >= 1
    g().closePanel(panel.id)
    await new Promise((r) => setTimeout(r, 120))
    const closed = !g().panels.some((p) => p.kind === 'browser')
    return { opened, rendered, emptyState, urlKept, reused, bumped, closed }
  })()`)
  console.log('BROWSER=' + JSON.stringify(browser))

  // 27) LaTeX mode: auto-detects on .tex open (main auto-picked by
  //     \documentclass), builds HEADLESSLY (structured result whether or not
  //     a TeX engine exists), keeps Overleaf linking out of the toolbar, and
  //     respects dismiss
  let latex = {}
  try {
    const texRepo = path.join(os.tmpdir(), `pasola-smoke-latex-${Date.now()}`)
    fsx.mkdirSync(texRepo, { recursive: true })
    const { execFileSync } = require('node:child_process')
    execFileSync('git', ['init', '-q'], { cwd: texRepo })
    fsx.writeFileSync(path.join(texRepo, 'main.tex'), '\\documentclass{article}\n\\begin{document}hi\\end{document}\n')
    latex = await win.webContents.executeJavaScript(`(async () => {
      const g = () => window.__kaisola.getState()
      const ws = ${JSON.stringify(texRepo)}
      g().setWorkspace(ws)
      await new Promise((r) => setTimeout(r, 200))
      const chip = [...document.querySelectorAll('.fx-changes-chip')].some((b) => /LaTeX/.test(b.textContent || ''))
      const offAtFirst = g().latexMode === false
      // opening the .tex file flips LaTeX mode on and picks it as main
      g().requestFile(ws + '/main.tex', 'edit', { pinned: true })
      await new Promise((r) => setTimeout(r, 500))
      const autoOn = g().latexMode === true
      const autoMain = g().latexMain[ws] === ws + '/main.tex'
      const bar = !!document.querySelector('.fx-latexbar')
      const noOverleafLink = !document.querySelector('.fx-latex-connect') &&
        ![...document.querySelectorAll('.fx-latexbar button')].some((btn) => /overleaf/i.test((btn.textContent || '') + ' ' + (btn.getAttribute('title') || '')))
      const waitFor = async (check, timeout = 8000) => {
        const started = performance.now()
        while (performance.now() - started < timeout) {
          const value = check()
          if (value) return value
          await new Promise((r) => requestAnimationFrame(r))
        }
        return check()
      }
      // headless build: structured result on EVERY machine — a pdf when an
      // engine exists, missing:true (with an install hint) when none does
      const b = await window.kaisola.latex.build(ws + '/main.tex')
      const buildShape = b && (b.ok === true
        ? typeof b.pdf === 'string'
        : b.missing === true ? typeof b.hint === 'string' : Array.isArray(b.errors) || typeof b.message === 'string')
      const sync = b?.ok && b.pdf
        ? await window.kaisola.latex.syncFromPdf({ pdfPath: b.pdf, page: 1, x: 72, y: 72 })
        : { ok: true, skipped: true }
      const syncShape = sync.skipped || (sync.ok === true && sync.file === ws + '/main.tex' && sync.line >= 1)
      let pdfDblClickSync = true
      let pdfAutoBuildSynctex = true
      let pdfSourceZoomIndependent = true
      if (b?.ok && b.pdf) {
        g().requestFile(b.pdf, undefined, { pinned: true })
        const pdfPage = await waitFor(() => document.querySelector('.fx-pdf-page[data-page="1"] .fx-pdf-sheet'), 12000)
        if (!pdfPage) {
          pdfDblClickSync = false
        } else {
          const rect = pdfPage.getBoundingClientRect()
          pdfPage.dispatchEvent(new MouseEvent('dblclick', {
            bubbles: true,
            cancelable: true,
            clientX: rect.left + rect.width * 0.16,
            clientY: rect.top + rect.height * 0.16,
          }))
          pdfDblClickSync = !!(await waitFor(() =>
            g().openFilePath === b.pdf &&
            !!document.querySelector('.fx-pdf-source-pane .cm-line') &&
            /main\\.tex/.test(document.querySelector('.fx-pdf-source-head')?.textContent || ''),
          5000))
          if (pdfDblClickSync) {
            const sourceScroller = document.querySelector('.fx-pdf-source-pane .cm-scroller')
            const sourceLine = document.querySelector('.fx-pdf-source-pane .cm-line')
            const sourceFontBefore = sourceScroller ? parseFloat(getComputedStyle(sourceScroller).fontSize) : 0
            const pageWrap = pdfPage.closest('.fx-pdf-page')
            const pdfWidthBefore = pageWrap?.getBoundingClientRect().width || 0
            pdfPage.dispatchEvent(new WheelEvent('wheel', {
              bubbles: true,
              cancelable: true,
              ctrlKey: true,
              deltaY: -120,
              clientX: rect.left + rect.width * 0.5,
              clientY: rect.top + rect.height * 0.5,
            }))
            const pdfZoomed = !!(await waitFor(() => {
              const page = document.querySelector('.fx-pdf-page[data-page="1"]')
              return page && pdfWidthBefore > 0 && page.getBoundingClientRect().width > pdfWidthBefore + 4
            }, 3000))
            const sourceFontAfterPdfZoom = sourceScroller ? parseFloat(getComputedStyle(sourceScroller).fontSize) : 0
            const pdfWidthAfterPdfZoom = pageWrap?.getBoundingClientRect().width || 0
            sourceLine?.dispatchEvent(new WheelEvent('wheel', {
              bubbles: true,
              cancelable: true,
              ctrlKey: true,
              deltaY: -120,
            }))
            const sourceZoomed = !!(await waitFor(() => {
              const scroller = document.querySelector('.fx-pdf-source-pane .cm-scroller')
              return scroller && sourceFontBefore > 0 && parseFloat(getComputedStyle(scroller).fontSize) > sourceFontBefore + 0.5
            }, 3000))
            const pdfWidthAfterSourceZoom = pageWrap?.getBoundingClientRect().width || 0
            pdfSourceZoomIndependent =
              pdfZoomed &&
              sourceZoomed &&
              sourceFontBefore > 0 &&
              Math.abs(sourceFontAfterPdfZoom - sourceFontBefore) < 0.35 &&
              Math.abs(pdfWidthAfterSourceZoom - pdfWidthAfterPdfZoom) < 2
          }
          const synctex = b.pdf.replace(/\\.pdf$/i, '.synctex.gz')
          const hidden = synctex + '.hidden'
          const moved = await window.kaisola.fs.rename(synctex, hidden)
          if (moved.ok) {
            pdfPage.dispatchEvent(new MouseEvent('dblclick', {
              bubbles: true,
              cancelable: true,
              clientX: rect.left + rect.width * 0.18,
              clientY: rect.top + rect.height * 0.18,
            }))
            const started = performance.now()
            pdfAutoBuildSynctex = false
            while (performance.now() - started < 8000) {
              const retry = await window.kaisola.latex.syncFromPdf({ pdfPath: b.pdf, page: 1, x: 72, y: 72 })
              if (retry.ok === true) {
                pdfAutoBuildSynctex = true
                break
              }
              await new Promise((r) => setTimeout(r, 250))
            }
            if (!pdfAutoBuildSynctex) await window.kaisola.fs.rename(hidden, synctex)
          }
        }
      }
      const beforeUiBuild = g().openFilePath
      const buildBtn = [...document.querySelectorAll('.fx-latexbar button')].find((btn) => /Compile/.test(btn.getAttribute('title') || ''))
      buildBtn?.click()
      await waitFor(() => !document.querySelector('.fx-latexbar .spin'))
      const uiBuildNoPdf = g().openFilePath === beforeUiBuild
      let latexIssuePopoverContained = true
      if (b?.ok) {
        await window.kaisola.fs.write(ws + '/broken.tex', '\\\\documentclass{article}\\n\\\\begin{document}\\n\\\\undefinedcommandwithanintentionallylongnamethatshouldwrapinsidepasola\\n\\\\end{document}\\n')
        g().requestFile(ws + '/broken.tex', 'edit', { pinned: true })
        g().setLatexMain(ws, ws + '/broken.tex')
        await waitFor(() => /broken\\.tex/.test(document.querySelector('.fx-tab[data-active="true"]')?.textContent || ''), 3000)
        const brokenBtn = [...document.querySelectorAll('.fx-latexbar button')].find((btn) => /Compile/.test(btn.getAttribute('title') || ''))
        brokenBtn?.click()
        // the failing build itself can exceed a fixed popover wait under machine
        // load — wait for the BUILD to finish first, then the popover must be up
        await waitFor(() => !document.querySelector('.fx-latexbar .spin'), 60000)
        const popover = await waitFor(() => {
          const node = document.querySelector('.fx-latex-issues-popover')
          if (!node) return null
          const style = getComputedStyle(node)
          return style.visibility !== 'hidden' && style.position === 'fixed' ? node : null
        }, 5000)
        const rect = popover?.getBoundingClientRect()
        const messageNode = popover?.querySelector('.fx-latex-issue .truncate')
        const whiteSpace = messageNode ? getComputedStyle(messageNode).whiteSpace : ''
        latexIssuePopoverContained = !!rect &&
          rect.left >= -1 &&
          rect.top >= -1 &&
          rect.right <= window.innerWidth + 1 &&
          rect.bottom <= window.innerHeight + 1 &&
          rect.width <= window.innerWidth &&
          whiteSpace !== 'nowrap'
      }
      const badInput = await window.kaisola.latex.build(ws + '/nope.tex')
      const buildGuard = badInput && badInput.ok === false
      // dismissing the bar sticks: re-opening a .tex must NOT re-enable
      g().setLatexMode(false)
      await new Promise((r) => setTimeout(r, 120))
      const barGone = !document.querySelector('.fx-latexbar')
      g().requestFile(ws + '/main.tex', 'edit', { pinned: true })
      await new Promise((r) => setTimeout(r, 300))
      const dismissedSticks = g().latexMode === false
      g().setLatexMain(ws, null)
      return { chip, offAtFirst, autoOn, autoMain, bar, noOverleafLink, buildShape, syncShape, pdfDblClickSync, pdfAutoBuildSynctex, pdfSourceZoomIndependent, uiBuildNoPdf, latexIssuePopoverContained, buildGuard, barGone, dismissedSticks }
    })()`)
    fsx.rmSync(texRepo, { recursive: true, force: true })
  } catch (e) {
    latex = { error: String((e && e.message) || e) }
  }
  console.log('LATEX=' + JSON.stringify(latex))

  // 28) Chrome-style session groups + tab switching: grouped cluster renders,
  //     collapse works, switchSession swaps the anchor card, empty groups die
  const groups = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const tid = g().terminals[0].id
    g().createSessionGroup('Research', [tid])
    await new Promise((r) => setTimeout(r, 180))
    const grp = g().sessionGroups.find((x) => x.name === 'Research')
    const created = !!grp && grp.members.includes(tid)
    const headEl = [...document.querySelectorAll('.session-group-head')].some((h) => /Research/.test(h.textContent || ''))
    const rowInGroup = !!document.querySelector('.session-group .session-row')
    g().toggleSessionGroupCollapsed(grp.id)
    const collapsed = g().sessionGroups.find((x) => x.id === grp.id).collapsed === true
    g().toggleSessionGroupCollapsed(grp.id)
    const thr = g().assistantThreads[0]
    let switched = true
    if (thr) {
      g().switchSession(thr.id)
      g().switchSession(tid)
      switched = g().dockViews.includes(tid)
    }
    // cycling must actually MOVE the anchor when 2+ sessions exist — asserting
    // dockViews is non-empty would pass even if cycleSession were a no-op
    const orderLen = (window.__kaisolaLib && window.__kaisolaLib.sessionOrderIds ? window.__kaisolaLib.sessionOrderIds(g()) : []).length
    const anchorBefore = g().dockViews[0]
    g().cycleSession(1)
    const cycled = orderLen < 2 ? true : g().dockViews[0] !== anchorBefore
    g().assignToGroup(tid, null)
    const dissolved = !g().sessionGroups.some((x) => x.id === grp.id)
    return { created, headEl, rowInGroup, collapsed, switched, cycled, dissolved }
  })()`)
  console.log('GROUPS=' + JSON.stringify(groups))

  // 29) browser grammar: pins float to the top of the ⌘1..9 order, undo-close
  //     restores a terminal (pty grace) AND a thread (runtime intact),
  //     needs-you marks clear on view, group colors persist
  const chrome = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const tid = g().terminals[0].id
    // pin: floats to slot 1 (⌘1 order) and the rail hides its close button
    g().togglePinSession(tid)
    await new Promise((r) => setTimeout(r, 150))
    const pinnedFirst = (window.__kaisolaLib && window.__kaisolaLib.sessionOrderIds
      ? window.__kaisolaLib.sessionOrderIds(g())
      : [tid])[0] === tid
    const pinnedSection = !!document.querySelector('.session-pinned .session-row')
    g().togglePinSession(tid)
    const unpinned = !g().pinnedSessions.includes(tid)
    // needs-you: mark → dot renders; viewing the session clears it
    g().markNeedsYou(tid)
    await new Promise((r) => setTimeout(r, 120))
    const dot = !!document.querySelector('.session-needs')
    g().setDockView(tid)
    await new Promise((r) => setTimeout(r, 80))
    const cleared = !g().needsYou[tid]
    // undo-close (thread): runtime survives the round trip
    const thr0 = g().assistantThreads[0]
    let threadBack = true
    if (thr0) {
      g().updateAssistantRuntime(thr0.id, (r) => ({ ...r, turns: [{ kind: 'user', text: 'smoke-undo', at: 1 }], first: false }))
      g().closeAssistantThread(thr0.id)
      const gone = !g().assistantThreads.some((t) => t.id === thr0.id)
      g().reopenClosedSession()
      const rt = g().assistantRuntimes[thr0.id]
      threadBack = gone && g().assistantThreads.some((t) => t.id === thr0.id) &&
        !!rt && rt.turns.length === 1 && rt.turns[0].text === 'smoke-undo'
    }
    // undo-close (terminal): record returns via the stack
    g().requestTerminal(undefined, {})
    await new Promise((r) => setTimeout(r, 100))
    const t2 = g().terminals[g().terminals.length - 1]
    g().closeTerminal(t2.id)
    const stacked = g().closedStack.some((c) => c.term && c.term.id === t2.id)
    g().reopenClosedSession()
    const termBack = g().terminals.some((t) => t.id === t2.id) && !g().closedStack.some((c) => c.term && c.term.id === t2.id)
    g().closeTerminal(t2.id) // leave the shell tidy
    // group color: explicit palette color round-trips
    g().createSessionGroup('Chrome', [tid])
    const grp = g().sessionGroups.find((x) => x.name === 'Chrome')
    g().setSessionGroupColor(grp.id, '#4a7dbd')
    const colored = g().sessionGroups.find((x) => x.id === grp.id).color === '#4a7dbd'
    g().removeSessionGroup(grp.id)
    return { pinnedFirst, pinnedSection, unpinned, dot, cleared, threadBack, stacked, termBack, colored }
  })()`)
  console.log('CHROME=' + JSON.stringify(chrome))

  // 30) the ⌘L bar: opens, lists explicit rows (jump/ask/run), URL input
  //     surfaces "Open …" as the default action and it lands in a browser card
  const omni = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    g().setOmniOpen(true)
    await new Promise((r) => setTimeout(r, 150))
    const opened = !!document.querySelector('.omni-input')
    const input = document.querySelector('.omni-input')
    const setVal = (v) => {
      const proto = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
      proto.set.call(input, v)
      input.dispatchEvent(new Event('input', { bubbles: true }))
    }
    setVal('hello world')
    await new Promise((r) => setTimeout(r, 120))
    const rows = [...document.querySelectorAll('.omni-item')].map((b) => b.textContent || '')
    const hasAsk = rows.some((t) => /Ask:/.test(t))
    const hasRun = rows.some((t) => /Run:/.test(t))
    setVal('localhost:5199')
    await new Promise((r) => setTimeout(r, 120))
    const rows2 = [...document.querySelectorAll('.omni-item')]
    const urlFirst = /Open localhost:5199/.test(rows2[0] ? rows2[0].textContent : '')
    if (rows2[0]) rows2[0].click()
    await new Promise((r) => setTimeout(r, 150))
    const panel = g().panels.find((p) => p.kind === 'browser' && p.url && p.url.includes('5199'))
    const urlOpened = !!panel
    const closedAfter = !g().omniOpen
    if (panel) g().closePanel(panel.id)
    g().reopenClosedSession && g().closedStack.length && g().closedStack[0].panel ? g().setOmniOpen(false) : null
    return { opened, hasAsk, hasRun, urlFirst, urlOpened, closedAfter }
  })()`)
  console.log('OMNI=' + JSON.stringify(omni))

  // 31) user config files: paths resolve, settings.json applies on load (and
  //     the loose parser tolerates comments), keymap overrides land
  const usercfg = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const paths = await window.kaisola.settings.paths()
    const pathsOk = !!paths && typeof paths.settings === 'string' && paths.settings.endsWith('settings.json')
    const themeBefore = g().theme
    await window.kaisola.fs.write(paths.settings, '// smoke\\n{ "theme": "dark", "termFontSize": 15, }\\n')
    await window.kaisola.fs.write(paths.keymap, '[ { "bindings": { "cmd-9": null, "cmd-shift-y": "dock.toggle" } } ]\\n')
    await window.__kaisolaLib.loadUserConfig()
    const applied = g().theme === 'dark' && g().termFontSize === 15
    const km = g().keymapOverrides
    const kmOk = km['cmd-9'] === null && km['cmd-shift-y'] === 'dock.toggle'
    // restore
    await window.kaisola.fs.write(paths.settings, '')
    await window.kaisola.fs.write(paths.keymap, '')
    g().setTheme(${JSON.stringify('light')})
    g().setTermFontSize(13)
    g().setKeymapOverrides({})
    return { pathsOk, applied, kmOk, themeBefore }
  })()`)
  console.log('USERCFG=' + JSON.stringify(usercfg))

  // 32) session templates: save from a live terminal, listed in the + menu,
  //     opening one boots the command again
  const tpl = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    g().requestTerminal('echo tpl-smoke', { cwd: undefined, name: 'TplTerm', singletonKey: 'tpl-smoke-src' })
    await new Promise((r) => setTimeout(r, 150))
    const src = g().terminals.find((t) => t.singletonKey === 'tpl-smoke-src')
    g().saveSessionTemplate(src.id)
    const saved = g().sessionTemplates.find((t) => t.name === 'TplTerm')
    const savedOk = !!saved && saved.kind === 'terminal' && saved.command === 'echo tpl-smoke'
    // close any stale menu first (outside-close fires on mousedown)
    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 80))
    const btn = document.querySelector('.rail-head .drop-btn')
    btn.click()
    await new Promise((r) => setTimeout(r, 150))
    const labels = [...document.querySelectorAll('.drop-menu .drop-item')].map((i) => i.textContent || '')
    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 80))
    const listed = labels.some((l) => /TplTerm/.test(l))
    const hasWorktreeEntry = labels.some((l) => /worktree/i.test(l))
    g().removeSessionTemplate(saved.id)
    const removed = !g().sessionTemplates.some((t) => t.id === saved.id)
    g().closeTerminal(src.id)
    return { savedOk, listed, hasWorktreeEntry, removed }
  })()`)
  console.log('TPL=' + JSON.stringify(tpl))

  // 33) worktree sessions: a fresh worktree spawns an isolated claude terminal,
  //     merge lands the branch back in the base repo, remove cleans up
  let wtsess = {}
  try {
    const wtRepo = path.join(os.tmpdir(), `pasola-smoke-wtsess-${Date.now()}`)
    fsx.mkdirSync(wtRepo, { recursive: true })
    const { execFileSync } = require('node:child_process')
    execFileSync('git', ['init', '-q'], { cwd: wtRepo })
    fsx.writeFileSync(path.join(wtRepo, 'base.txt'), 'base\n')
    execFileSync('git', ['add', '-A'], { cwd: wtRepo })
    execFileSync('git', ['-c', 'user.name=S', '-c', 'user.email=s@s', 'commit', '-q', '-m', 'root'], { cwd: wtRepo })
    wtsess = await win.webContents.executeJavaScript(`(async () => {
      const g = () => window.__kaisola.getState()
      g().setWorkspace(${JSON.stringify(wtRepo)})
      await new Promise((r) => setTimeout(r, 250))
      await g().newWorktreeSession('claude-code')
      await new Promise((r) => setTimeout(r, 400))
      const sid = Object.keys(g().worktreeSessions)[0]
      const wt = sid && g().worktreeSessions[sid]
      const created = !!wt && wt.path.includes('.pasola-worktrees') && wt.branch.startsWith('pz/')
      const term = g().terminals.find((t) => t.id === sid)
      const termOk = !!term && term.cwd === wt.path && /claude/.test(term.boot || '')
      // agent writes a file in the WORKTREE, then merge brings it home
      await window.kaisola.fs.write(wt.path + '/feature.txt', 'from the worktree\\n')
      await g().mergeWorktreeSession(sid)
      await new Promise((r) => setTimeout(r, 200))
      const merged = (await window.kaisola.fs.read(${JSON.stringify(wtRepo)} + '/feature.txt')).ok
      await g().removeWorktreeSession(sid)
      await new Promise((r) => setTimeout(r, 200))
      const removed = !g().worktreeSessions[sid] && !g().terminals.some((t) => t.id === sid)
      return { created, termOk, merged, removed }
    })()`)
    fsx.rmSync(wtRepo, { recursive: true, force: true })
  } catch (e) {
    wtsess = { error: String((e && e.message) || e) }
  }
  console.log('WTSESS=' + JSON.stringify(wtsess))

  const failed =
    !rootChildren || !minimalShell.noWorkflowSidebar || !minimalShell.hasRail || !minimalShell.hasSessions || !minimalShell.hasEmptyLauncher || !minimalShell.stageFiles || !minimalShell.studioDefault || !minimalShell.floatingTools || !claudePrepared || !nativeWindow.rendererClippedMaterial || !icon.exists || !icon.usable || !icon.square || !icon.large || !glass.appSamplingLayer || !glass.activeTintWhite || !glass.railLayerFlattened || !glass.contentGlassy || !glass.sessionGlassy || !glass.termGlassTint || !glass.blurKeepsGlass || !glass.lightsGray || !glass.nativeWindowRounding ||
    !emptyOk || !demoOk ||
    !review.opened || !review.closed || !review.decided ||
    !term.run || !term.ptyOk || !term.cdWorks || !term.dock || !term.host ||
    !model.shape || !model.graceful ||
    !acp.connect || !acp.ok || !acp.claudeTerminal || !acp.ranCommand || acp.termEvents < 1 || !acp.cancelOk ||
    acp.authCount < 1 || !acp.authOk || !acp.authUrlSeen || !acp.setModelOk || acp.modelAfter !== 'mock-mini' ||
    acp.reasoningAfter !== 'low' || !acp.gotThought || acp.tools < 1 ||
    // chat agents = presets minus terminal-only ones (Claude runs as a terminal)
    !dd.hasBtn || !dd.portal || dd.items < 2 ||
    !permrules.saved || !permrules.cascaded || !permrules.autoAnswered || !permrules.rejectCascade ||
    !sensitive.surfaced || !sensitive.stillPending || !sensitive.diffFlagged || sensitive.pendingAfter !== 0 ||
    !activityUi.card || !activityUi.hasSubagent || !activityUi.hasTerminal || !activityUi.hasStatus || !activityUi.openBtn ||
    !persist.stored || !persist.hasTheme || !persist.hasAgent || !persist.hasThread || !persist.hasChatTurn ||
    !boot.hasId || !boot.ran ||
    !auth.hasUrl || auth.code !== 'ABCD-1234' || !auth.done ||
    !cards.cardPerView || !cards.chatLeftOfFiles || !cards.hasHead || !cards.noDockPanel || !fschk.listed || !fschk.read || !fschk.wrote ||
    !fileui.hasSearch || fileui.resultCount < 1 || fileui.tabs < 1 || !fileui.alphaPreview || !fileui.previewReplaced || !fileui.betaPinned || !fileui.hasBeta || !fileui.activeBeta ||
    !fileui.mdPreview || !fileui.mdImage || !fileui.mdMark || !fileui.mdExternal || !fileui.mdReadableChannel || !fileui.mdSplitFillsPane ||
    !fileui.htmlPreview || !fileui.htmlSafe || !fileui.texSource || !fileui.texEditable || !fileui.texNoPreview ||
    fileui.imageReadKind !== 'image' || !fileui.imageHasDataUrl || !fileui.imagePreview || !fileui.imageZoomed ||
    fileui.pdfReadKind !== 'pdf' || !fileui.pdfHasPreviewUrl || !fileui.pdfNoDataUrl || !fileui.pdfPreview || !fileui.pdfNoSidePane || !fileui.pdfZoomed || !fileui.pdfChromeCollapsed ||
    fileui.largePdfReadKind !== 'pdf' || !fileui.largePdfHasPreviewUrl || !fileui.largePdfNotTooLarge || !fileui.largePdfNoDataUrl || !fileui.railSawDelta ||
    !fileui.zoomed || !fileui.zoomCss || !fileui.mdHeadingZoomed ||
    !fileui.codeZoomed || !fileui.gutterZoomed || !fileui.codeGutterAligned ||
    !fileui.topBarsDrag || !fileui.compactFileChrome || !fileui.topBarControlsNoDrag || !fileui.topBarBordersVisible ||
    !fileui.shellGuttersDrag || !fileui.shellSurfacesDrag || !fileui.shellInnerNoDrag || !fileui.shellHandlesNoDrag ||
    !fileui.fileTabsPersisted || !fileui.fileZoomPersisted ||
    !layout.sessionsInRail || !layout.hasRailTreeArea || !layout.addsRow || !layout.focusesNewThread || !layout.noDockChrome ||
    !layout.hasFoot || !layout.footWs || !layout.footConn ||
    !splits.one || !splits.appended || !splits.heads || !splits.stacked || !splits.besides || !splits.uncapped || !splits.closes ||
    !plus.hasBtn || !plus.noDrag || !plus.pronounced || !plus.hasTerminalOption || !plus.agentChoices || !plus.claudeOpensTerminal || !plus.claudeNoThread || !plus.adds ||
    !canvasR.hasHandle || !canvasR.sized || !canvasR.clampedMin || !canvasR.resets ||
    !canvasMin.shownBefore || !canvasMin.hasBtn || !canvasMin.hidden || !canvasMin.cardsStay || !canvasMin.restoredByNav || !canvasMin.restoredByFile ||
    !lights.three || !lights.bigger || !lights.corner || !lights.noDrag || !lights.ctlApi ||
    !projtabs.twoTabs || !projtabs.isSecondActive || !projtabs.termsDiffer || !projtabs.gridsDiffer || !projtabs.parkedFirstOk ||
    !projtabs.backToFirst || !projtabs.firstRestored || !projtabs.parkedSecondOk ||
    !projtabs.domTwoTabs || !projtabs.domActiveOne ||
    !projtabs.closedGone || !projtabs.stackHas || !projtabs.reopened || !projtabs.reopenedTermsOk || !projtabs.reopenedGridOk || !projtabs.backToSingle ||
    !windetach.spawned || !windetach.adopted || !windetach.termsMoved || !windetach.srcDropped ||
    !toggle.hasFig || !toggle.visibleAtRest || !toggle.putAway || !toggle.back || !toggle.hidesAll ||
    !autoname.named || !autoname.rowShows || !autoname.sticky || !autoname.manualWins || !autoname.termNamed ||
    !minimalUi.noSidebar || !minimalUi.noSidebarResize || !minimalUi.noStageNav || !minimalUi.hasRail || !minimalUi.hasPlus || !minimalUi.hasFiles ||
    !settings.hasAppearance || !settings.noSidebarControls ||
    !dropfit.hasBtn || !dropfit.fits ||
    agentrun.added < 1 || agentrun.agentId !== 'hypothesis' || !agentrun.hasChanges || agentrun.status !== 'pending' ||
    approve.hypAdded < 1 || approve.createStatus !== 'approved' || !approve.patched ||
    !checkpoint.madeCheckpoint || !checkpoint.grew || !checkpoint.reverted || !checkpoint.consumed ||
    !queue.enqueued || queue.ready < 3 || !queue.grouped || !queue.grew || !queue.drained ||
    !bestof.grouped || !bestof.winnerApproved || !bestof.siblingsRejected || !bestof.noPendingLeft ||
    !workflow.seeded || !workflow.ran || !workflow.added || !workflow.twoSteps || !workflow.updated || !workflow.deleted ||
    !wt.created || !wt.hasFile || !wt.propAdded || !wt.isFile || !wt.merged || !wt.removed ||
    registry.count < 10 || !registry.hasMainOnes || !registry.defaults || !registry.qwenOn || !registry.qwenOff ||
    !registry.customAdded || !registry.menuHasCustom || !registry.menuHasPanels || !registry.customRemoved ||
    !gitpanel.sawUnstaged || !gitpanel.sawStaged || !gitpanel.unstagedBack || !gitpanel.committed || !gitpanel.clean ||
    !gitpanel.logged || !gitpanel.inGrid || !gitpanel.rendered || !gitpanel.railRow || !gitpanel.closed ||
    !browser.opened || !browser.rendered || !browser.emptyState || !browser.urlKept || !browser.reused || !browser.bumped || !browser.closed ||
    !latex.chip || !latex.offAtFirst || !latex.autoOn || !latex.autoMain || !latex.bar || !latex.noOverleafLink || !latex.buildShape || !latex.syncShape || !latex.pdfDblClickSync || !latex.pdfAutoBuildSynctex || !latex.pdfSourceZoomIndependent || !latex.uiBuildNoPdf || !latex.latexIssuePopoverContained || !latex.buildGuard ||
    !latex.barGone || !latex.dismissedSticks ||
    !groups.created || !groups.headEl || !groups.rowInGroup || !groups.collapsed || !groups.switched || !groups.cycled || !groups.dissolved ||
    !chrome.pinnedFirst || !chrome.pinnedSection || !chrome.unpinned || !chrome.dot || !chrome.cleared || !chrome.threadBack || !chrome.stacked || !chrome.termBack || !chrome.colored ||
    !omni.opened || !omni.hasAsk || !omni.hasRun || !omni.urlFirst || !omni.urlOpened || !omni.closedAfter ||
    !usercfg.pathsOk || !usercfg.applied || !usercfg.kmOk ||
    !tpl.savedOk || !tpl.listed || !tpl.hasWorktreeEntry || !tpl.removed ||
    !wtsess.created || !wtsess.termOk || !wtsess.merged || !wtsess.removed ||
    tourney.n < 1 || !tourney.sortedDesc || !tourney.uniqueRanks ||
    !verify.goodVerified || !verify.missingRejected || !verify.noQuoteRejected || !verify.pagerankOk ||
    !verify.goodSupporting || !verify.missingMention || !verify.contrastSupporting ||
    !automation.offDefault || !automation.noFireWhenOff || !automation.firedWhenOn || !automation.resetClears ||
    !toast.deduped || !toast.capped || !toast.dismissed || !toast.agentToast ||
    !lint.flagsUnsupported || !lint.flagsUnverified || !lint.cleanQuiet || !lint.specExempt || !lint.severity ||
    !verifyStore.ran || !verifyStore.wasUnverified || !verifyStore.flipped || !verifyStore.trustHigh ||
    !models.setOk || !models.cleared || !models.hasSection ||
    !reasoning.defaultOpenai || !reasoning.toLocal || !reasoning.modelSet || !reasoning.hasSection || !reasoning.keyApi || !reasoning.keyAbsent ||
    !oaisdk.handled || !codex.persists || !codex.execHandled || !codex.showsCodexNote || !codex.tabsOk ||
    supervisor.stage !== 'files' || supervisor.added !== 0 ||
    !openalex.doiOk || !openalex.absOk || !openalex.normOk || !openalex.refsOk ||
    !citegraph.ran ||
    grobid.title !== 'Time Awareness in Agents' || grobid.sentences !== 2 || !grobid.fullHasText || !grobid.boxOk || !grobid.located ||
    !grobidStore.ran ||
    !sandbox.blocked || sandbox.added < 1 || sandbox.status !== 'done' || sandbox.notebookLines < 3 || !sandbox.computeApproved ||
    !db.roundTrip || !db.deleted || db.backend !== 'sqlite' ||
    errors.length
  if (errors.length) {
    console.log('--- RENDERER ERRORS ---')
    errors.forEach((e) => console.log(e))
  }
  console.log(failed ? 'SMOKE_RESULT=FAIL' : 'SMOKE_RESULT=PASS')
  app.exit(failed ? 1 : 0)
})
