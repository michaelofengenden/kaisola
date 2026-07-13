// Headless render smoke test. Verifies: the app mounts, the minimal IDE shell
// renders, Files/agents/terminals work, and core workflows still avoid runtime
// regressions. Exits non-zero on any failure.
const { app, BrowserWindow, ipcMain, nativeImage } = require('electron')
const path = require('node:path')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers, killAllSessions } = require('./ipc/terminalHandler.cjs')
const { registerAcpHandlers, disposeAcp } = require('./ipc/acpHandler.cjs')
const { registerAuthHandlers } = require('./ipc/authHandler.cjs')
const { registerFsHandlers } = require('./ipc/fsHandler.cjs')
const { registerGrobidHandlers } = require('./ipc/grobidHandler.cjs')
const { registerSandboxHandlers } = require('./ipc/sandboxHandler.cjs')
const { registerDbHandlers } = require('./ipc/dbHandler.cjs')
const { registerCodexHandlers } = require('./ipc/codexHandler.cjs')
const { registerGitHandlers } = require('./ipc/gitHandler.cjs')
const { registerLatexHandlers } = require('./ipc/latexHandler.cjs')
const { registerClaudeHooksHandlers } = require('./ipc/claudeHooksHandler.cjs')
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const { registerUsageHandlers } = require('./ipc/usageHandler.cjs')
const { registerLedgerHandlers } = require('./ipc/ledgerHandler.cjs')
const { registerMcpHandlers } = require('./ipc/mcpServer.cjs')
const { registerExtensionHandlers } = require('./ipc/extensionHandler.cjs')
const { registerGlassHandlers } = require('./ipc/glassHandler.cjs')
const { registerAssistantArchiveHandlers } = require('./ipc/assistantArchive.cjs')
const { AcpProcessLedger } = require('./ipc/acpProcessLedger.cjs')
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
// Reclaim the PREVIOUS harness run before deleting its ephemeral userData;
// otherwise the ownership ledger disappears before it can reap an interrupted
// adapter tree on the next run.
try {
  const priorLedger = path.join(SMOKE_USERDATA, 'process-ledger')
  if (fsx.existsSync(path.join(priorLedger, 'acp-processes.json'))) new AcpProcessLedger(priorLedger).reclaimStale()
} catch { /* no prior harness */ }
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
  registerUpdateHandlers(ipcMain)
  registerUsageHandlers(ipcMain)
  registerLedgerHandlers(ipcMain)
  registerMcpHandlers(ipcMain)
  registerExtensionHandlers(ipcMain)
  registerGlassHandlers(ipcMain)
  registerAssistantArchiveHandlers(ipcMain, path.join(SMOKE_USERDATA, 'assistant-archives'))
  // Liquid Glass prefs are cosmetic; the smoke shell answers with "unsupported"
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: false, liveSolid: false }))
  ipcMain.handle('window:popped', () => ({ ok: true, termIds: [], states: [], closed: [] }))
  ipcMain.handle('window:pop-closed-ack', () => ({ ok: false }))
  ipcMain.handle('window:pop', () => ({ ok: false }))
  ipcMain.on('window:terminal-state', () => {})
  worktree.registerWorktreeHandlers(ipcMain)

  // Transactional tear-off/recombine replica: delivery waits for the renderer
  // listener, the source waits for ACK, and a drop over an existing top strip
  // reuses that BrowserWindow instead of spawning a third one.
  const pendingAdoptions = new Map()
  const adoptionReady = new Set()
  const ackWaiters = new Map()
  const completedTransfers = new Map()
  let smokeTransferSeq = 0
  ipcMain.on('window:adopt-ready', (e) => {
    adoptionReady.add(e.sender.id)
    const a = pendingAdoptions.get(e.sender.id)
    if (a) { pendingAdoptions.delete(e.sender.id); e.sender.send('tab:adopt', a) }
  })
  ipcMain.on('window:adopt-complete', (e, { transferId, ok } = {}) => {
    const p = ackWaiters.get(transferId)
    if (!p || p.targetId !== e.sender.id) return
    ackWaiters.delete(transferId)
    clearTimeout(p.timer)
    p.resolve(!!ok)
  })
  ipcMain.handle('window:detach-project', async (e, payload = {}) => {
    if (!payload.tab || !payload.slice) return { ok: false }
    const source = BrowserWindow.fromWebContents(e.sender)
    const point = payload.at && Number.isFinite(payload.at.x) && Number.isFinite(payload.at.y) ? payload.at : null
    let target = point ? BrowserWindow.getAllWindows().find((candidate) => {
      if (candidate === source || candidate.isDestroyed() || !adoptionReady.has(candidate.webContents.id)) return false
      const b = candidate.getBounds()
      return point.x >= b.x && point.x <= b.x + b.width && point.y >= b.y && point.y <= b.y + 56
    }) : null
    const targetKind = target ? 'existing' : 'new'
    if (!target) {
      target = new BrowserWindow({
        show: false,
        width: 900,
        height: 600,
        webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, webviewTag: true, plugins: true },
      })
      target.__smokeAdopt = true
      void target.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { adopt: '1', win: 'detach-smoke' } })
    }
    const transferId = `smoke-transfer-${++smokeTransferSeq}`
    const b = target.getBounds()
    const adoption = { tab: payload.tab, slice: payload.slice, globals: payload.globals, popped: payload.popped, transferId, ...(point ? { dropX: point.x - b.x } : {}) }
    const adopted = await new Promise((resolve) => {
      const timer = setTimeout(() => { ackWaiters.delete(transferId); resolve(false) }, 15_000)
      ackWaiters.set(transferId, { targetId: target.webContents.id, resolve, timer })
      if (adoptionReady.has(target.webContents.id)) target.webContents.send('tab:adopt', adoption)
      else pendingAdoptions.set(target.webContents.id, adoption)
    })
    if (!adopted) return { ok: false }
    const closeSource = targetKind === 'existing' && source.__smokeAdopt === true && payload.sourceTabCount === 1
    if (closeSource) completedTransfers.set(transferId, { source, sourceId: e.sender.id })
    return { ok: true, transferId, target: targetKind, closeSource }
  })
  ipcMain.handle('window:finish-transfer', (e, { transferId } = {}) => {
    const done = completedTransfers.get(transferId)
    if (!done || done.sourceId !== e.sender.id) return { ok: false }
    completedTransfers.delete(transferId)
    setImmediate(() => { if (!done.source.isDestroyed()) done.source.close() })
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
    // fresh installs use the split composition: sessions left, files right.
    splitSidebarsDefault: !!document.querySelector('.app-body[data-session-nav="sidebar"] > .session-sidebar') &&
      !!document.querySelector('.app-body[data-session-nav="sidebar"] > .wsrail[data-side="right"]'),
    // the fresh shell is ONE session (the seed terminal; chats are opt-in)
    hasSessions: document.querySelectorAll('.stabs .stab').length >= 1,
    railFilesOnly: document.querySelectorAll('.wsrail .session-row').length === 0,
    // with no workspace bound (fresh empty tab) the canvas shows the project
    // launcher (open-a-folder empty state), not the file view.
    hasEmptyLauncher: !!document.querySelector('.canvas .plaunch'),
    stageFiles: window.__kaisola.getState().stage === 'files',
    studioDefault: window.__kaisola.getState().layoutMode === 'studio',
    // Utilities stay in the navigation footer; the two structural switches
    // stay in one stable top-right group.
    sidebarFooter: !!document.querySelector('.session-sidebar > .shell-sidebar-footer'),
    topViewControls: document.querySelectorAll('.tabstrip-view-controls > button').length === 2 &&
      !!document.querySelector('.tabstrip-view-controls [aria-label="Hide file tree"]') &&
      !!document.querySelector('.tabstrip-view-controls [aria-label="Hide file preview"]'),
  }))()`)
  win.webContents.send('app-auth:changed', {
    ok: true,
    configured: true,
    serverVerified: true,
    profile: {
      provider: 'google',
      id: 'smoke-user',
      email: 'person@example.com',
      name: 'Kaisola Tester',
      avatarUrl: 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="32" height="32"%3E%3Crect width="32" height="32" rx="16" fill="%2395a456"/%3E%3C/svg%3E',
    },
  })
  await new Promise((r) => setTimeout(r, 100))
  const accountUi = await win.webContents.executeJavaScript(`(async () => {
    const footer = document.querySelector('.session-sidebar > .shell-sidebar-footer')
    const avatar = footer?.querySelector('.app-account-avatar')
    avatar?.click()
    await new Promise((resolve) => setTimeout(resolve, 60))
    const menu = document.querySelector('.app-account-menu')
    const result = {
      avatar: !!avatar,
      headshot: !!avatar?.querySelector('img'),
      menu: !!menu && /Kaisola Tester/.test(menu.textContent || '') && /person@example.com/.test(menu.textContent || ''),
      usageInMenu: !!menu && /Usage/.test(menu.textContent || ''),
      avatarOnly: !/Kaisola Tester/.test(avatar?.textContent || ''),
      bottomLeft: (() => {
        if (!footer) return false
        const rail = document.querySelector('.session-sidebar')?.getBoundingClientRect()
        const rect = footer.getBoundingClientRect()
        return !!rail && Math.abs(rect.left - rail.left) <= 1 && Math.abs(rect.bottom - rail.bottom) <= 1
      })(),
      menuAbove: !!menu && !!avatar && menu.getBoundingClientRect().bottom <= avatar.getBoundingClientRect().top,
      menuFits: !!menu && menu.getBoundingClientRect().left >= 8 && menu.getBoundingClientRect().right <= window.innerWidth - 8,
      aligned: (() => {
        const row = footer?.querySelector('.shell-sidebar-footer-tools')
        const buttons = [...(row?.querySelectorAll(':scope > button, :scope > .inbox-wrap > button') || [])]
        if (!row || buttons.length < 2) return false
        const rects = buttons.map((button) => button.getBoundingClientRect())
        const centers = rects.map((rect) => rect.top + rect.height / 2)
        const sameCenter = Math.max(...centers) - Math.min(...centers) <= 0.5
        const sameHeight = rects.every((rect) => Math.abs(rect.height - 28) <= 0.5)
        return getComputedStyle(row).alignItems === 'center' && sameCenter && sameHeight
      })(),
      usageOpened: false,
    }
    const accountUsage = [...(menu?.querySelectorAll(':scope > button') || [])].find((button) => /^Usage$/.test((button.textContent || '').trim()))
    accountUsage?.click()
    await new Promise((resolve) => setTimeout(resolve, 40))
    result.usageOpened = /Usage/.test(document.querySelector('.settings-pane-title')?.textContent || '') && !!document.querySelector('.settings-usage')
    window.__kaisola.getState().setSettingsOpen(false)
    await new Promise((resolve) => setTimeout(resolve, 30))
    return result
  })()`)
  console.log('ACCOUNT_UI=' + JSON.stringify(accountUi))
  // the empty-shell probe asserted the closed-by-default rail above — open it
  // now; every later section (tree, GLASS veils, drag regions) drives the rail
  await win.webContents.executeJavaScript(`(async () => {
    if (!document.querySelector('.wsrail')) {
      window.__kaisola.getState().toggleRail()
      await new Promise((r) => setTimeout(r, 150))
    }
    return !!document.querySelector('.wsrail')
  })()`)
  const autonomy = await win.webContents.executeJavaScript(`(document.querySelector('.autonomy-seg[data-active="true"]')||{}).innerText || ''`)
  // Opening a folder is not permission to spend tokens or start a provider.
  // Claude remains opt-in through New session after a workspace is chosen.
  const claudeRoot = path.join(os.tmpdir(), 'kaisola-claude-smoke')
  fsx.mkdirSync(claudeRoot, { recursive: true })
  const claudeOptIn = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const before = st.terminals.some((term) => term.singletonKey === 'agent:claude-code')
    st.setWorkspace(${JSON.stringify(claudeRoot)})
    await new Promise((r) => setTimeout(r, 600))
    const after = window.__kaisola.getState().terminals.some((term) => term.singletonKey === 'agent:claude-code')
    return !before && !after
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
    const previousPerfMode = store.perfMode
    const previousWinFocus = document.documentElement.dataset.winfocus
    // this check asserts LIGHT-theme token values — force the theme, or the
    // suite goes red every night when macOS's scheduled dark mode flips the
    // default 'system' theme under it (found 2026-07-09, 1am)
    const previousThemeMode = store.themeMode
    store.setThemeMode('light')
    store.setPerfMode('eco')
    store.setLayoutMode('studio')
    document.documentElement.dataset.winfocus = 'true'
    await new Promise((r) => setTimeout(r, 160))
    const app = document.querySelector('.app')
    const rail = document.querySelector('.wsrail')
    const canvas = document.querySelector('.canvas-wrap > .canvas')
    if (!app || !rail || !canvas) {
      store.setThemeMode(previousThemeMode)
      store.setPerfMode(previousPerfMode)
      store.setLayoutMode(previousLayout)
      if (previousWinFocus == null) delete document.documentElement.dataset.winfocus
      else document.documentElement.dataset.winfocus = previousWinFocus
      await new Promise((r) => setTimeout(r, 80))
      return { appSamplingLayer: false, chromeGlass: false, activeTintWhite: false, railLayerFlattened: false, contentGlassy: false, sessionGlassy: false, termGlassTint: false, blurKeepsGlass: false, lightsGray: false, nativeWindowRounding: false }
    }
    const appStyle = getComputedStyle(app)
    const railStyle = getComputedStyle(rail)
    const canvasStyle = getComputedStyle(canvas)
    const appGlassStyle = getComputedStyle(app, '::before')
    const card = document.querySelector('.session-card')
    const termPane = document.querySelector('.dock-pane-term')
    const light = document.querySelector('.light-close')
    const activeAppTint = appStyle.getPropertyValue('--app-active-glass-tint').trim()
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
    const tabstrip = document.querySelector('.tabstrip')
    const tabstripGlassBd = tabstrip ? backdrop(getComputedStyle(tabstrip, '::before')) : ''
    const railGlassBd = backdrop(getComputedStyle(rail, '::before'))
    const out = {
      // ECO CHROME: pure white, opaque and compositor-still. The app/window
      // field owns the paper base and no descendant reintroduces a blur.
      appSamplingLayer: !/blur/.test(activeAppBackdrop) && !/blur/.test(activeAppGlassBackdrop)
        && alpha(activeAppBackground) < 0.05 && appGlassStyle.backgroundColor === 'rgb(255, 255, 255)',
      chromeGlass: !/blur/.test(tabstripGlassBd) && !/blur/.test(railGlassBd)
        && getComputedStyle(rail, '::before').display === 'none'
        && !getComputedStyle(tabstrip, '::before').backgroundImage.includes('linear-gradient')
        && alpha(getComputedStyle(tabstrip).backgroundColor) <= 0.02,
      activeTintWhite: activeAppTint === '#fffefd',
      railBackdrop: activeRailBackdrop,
      railLayerFlattened: !activeRailBackdrop && activeRailBackgroundAlpha <= 0.02 && (!activeRailBgImage || activeRailBgImage === 'none') && activeSessionListFlat && activeRailDividerFlat && activeRailSearchFlat && veilAlpha >= 0 && veilAlpha <= 1,
      contentGlassy: !activeCanvasBackdrop && alpha(canvasStyle.backgroundColor) >= 0.99 && canvasStyle.backgroundColor === 'rgb(255, 255, 255)' && !canvasStyle.backgroundImage.includes('data:image/svg'),
      sessionGlassy: !!cardStyle && !/blur/.test(backdrop(cardStyle)) && alpha(cardStyle.backgroundColor) >= 0.99 && cardStyle.backgroundColor === 'rgb(255, 255, 255)' && !cardStyle.backgroundImage.includes('data:image/svg'),
      termGlassTint: !!termStyle && alpha(termStyle.backgroundColor) >= 0.99,
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
    store.setPerfMode(previousPerfMode)
    store.setThemeMode(previousThemeMode)
    if (previousWinFocus == null) delete document.documentElement.dataset.winfocus
    else document.documentElement.dataset.winfocus = previousWinFocus
    await new Promise((r) => setTimeout(r, 80))
    return out
  })()`)

  console.log('ROOT_CHILDREN=' + rootChildren)
  console.log('MINIMAL_SHELL=' + JSON.stringify(minimalShell))
  console.log('AUTONOMY_DEFAULT=' + autonomy)
  console.log('CLAUDE_OPT_IN=' + claudeOptIn)
  console.log('NATIVE_WINDOW=' + JSON.stringify(nativeWindow))
  console.log('ICON=' + JSON.stringify(icon))
  console.log('GLASS=' + JSON.stringify(glass))

  // 1) empty project — the minimal shell should land on the project launcher
  //    (open-a-folder empty state), not the old workflow nav.
  const emptyOk = !!(minimalShell.noWorkflowSidebar && minimalShell.splitSidebarsDefault && minimalShell.hasSessions && minimalShell.hasEmptyLauncher && minimalShell.stageFiles && minimalShell.studioDefault)
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
    const previousTheme = st.theme
    st.setLayoutMode('studio')
    st.setDock(true, 'terminal')
    st.setTheme('light')
    await new Promise(r => setTimeout(r, 150))
    const lightHosts = [...document.querySelectorAll('.term-wrap[data-terminal-theme="light"]')]
    const lightComposerPalette = lightHosts.length > 0 && lightHosts.every((host) => host.dataset.ansiBlack === '#eef0f4')
    const runRes = await window.kaisola.terminal.run('echo pasola-run-ok')
    let buf = ''
    const id = 'smoke-pty'
    const off = window.kaisola.terminal.onData(id, d => { buf += d })
    const cr = await window.kaisola.terminal.create(id, undefined, 80, 24, st.activeProjectId)
    await new Promise(r => setTimeout(r, 500))
    await window.kaisola.terminal.write(id, 'cd /tmp\\r', st.activeProjectId)
    await new Promise(r => setTimeout(r, 300))
    await window.kaisola.terminal.write(id, 'pwd\\r', st.activeProjectId)
    await new Promise(r => setTimeout(r, 600))
    off(); window.kaisola.terminal.kill(id, st.activeProjectId)
    st.setTheme(previousTheme)
    return {
      run: !!(runRes && runRes.ok && (runRes.stdout||'').includes('pasola-run-ok')),
      ptyOk: !!cr.ok,
      cdWorks: /\\/(private\\/)?tmp/.test(buf),
      dock: !!document.querySelector('.session-card'),
      host: !!document.querySelector('.term-host'),
      lightComposerPalette,
    }
  })()`)
  console.log('TERMINAL=' + JSON.stringify(term))

  // 4a) appearance and shell reflow are visual mutations, not navigation:
  //      terminal + ACP composers stay at the live prompt and keep drafts.
  const viewportPersistence = await win.webContents.executeJavaScript(`(async () => {
    try {
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
    const st = window.__kaisola.getState()
    const previous = { themeMode: st.themeMode, perfMode: st.perfMode, railOpen: st.railOpen, layoutMode: st.layoutMode }
    st.setLayoutMode('studio')
    st.setDock(true, 'terminal')
    const terminal = st.terminals.find((row) => st.dockViews.includes(row.id)) || st.terminals[0]
    await window.kaisola.terminal.write(terminal.id, "i=0; while [ $i -lt 180 ]; do echo viewport-$i; i=$((i+1)); done\\r", st.activeProjectId)
    await wait(700)
    const termViewport = document.querySelector('[data-terminal-id="' + terminal.id + '"] .xterm-viewport')
    if (termViewport) termViewport.scrollTop = termViewport.scrollHeight
    const termDistance = () => termViewport ? Math.max(0, termViewport.scrollHeight - termViewport.scrollTop - termViewport.clientHeight) : 9999
    st.setThemeMode(st.theme === 'light' ? 'dark' : 'light')
    st.setPerfMode(st.perfMode === 'eco' ? 'glass' : 'eco')
    st.toggleRail()
    await wait(220)
    const terminalBottomKept = termDistance() < 12

    st.requestNewThread('mock')
    const threadId = window.__kaisola.getState().activeThreadId
    st.updateAssistantRuntime(threadId, () => ({
      first: false,
      turns: Array.from({ length: 70 }, (_, i) => ({ kind: i % 2 ? 'assistant' : 'user', text: 'Viewport line ' + i + ' '.repeat(20) + 'content '.repeat(18) })),
    }))
    st.setAssistantDraft(threadId, { text: 'draft survives visual changes' })
    st.setDockView(threadId)
    await wait(260)
    let stream = document.querySelector('.assistant[data-thread-id="' + threadId + '"] .assistant-stream')
    if (stream) stream.scrollTop = stream.scrollHeight
    st.setThemeMode(st.theme === 'light' ? 'dark' : 'light')
    st.setPerfMode(st.perfMode === 'eco' ? 'glass' : 'eco')
    st.toggleRail()
    await wait(180)
    const assistantBottomAfterReflow = !!stream && stream.scrollHeight - stream.scrollTop - stream.clientHeight < 12
    st.setLayoutMode('focus')
    await wait(90)
    st.setLayoutMode('studio')
    await wait(220)
    stream = document.querySelector('.assistant[data-thread-id="' + threadId + '"] .assistant-stream')
    const assistantRemountDistance = stream ? stream.scrollHeight - stream.scrollTop - stream.clientHeight : null
    const assistantBottomAfterRemount = !!stream && assistantRemountDistance < 12
    const draftKept = window.__kaisola.getState().assistantDrafts[threadId]?.text === 'draft survives visual changes'
    window.__kaisola.getState().closeAssistantThread(threadId)
    st.setThemeMode(previous.themeMode)
    st.setPerfMode(previous.perfMode)
    if (window.__kaisola.getState().railOpen !== previous.railOpen) st.toggleRail()
    st.setLayoutMode(previous.layoutMode)
    return { terminalBottomKept, assistantBottomAfterReflow, assistantBottomAfterRemount, assistantRemountDistance, assistantStreamFound: !!stream, draftKept }
    } catch (error) {
      return { terminalBottomKept: false, assistantBottomAfterReflow: false, assistantBottomAfterRemount: false, draftKept: false, error: String(error && (error.stack || error.message) || error) }
    }
  })()`)
  console.log('VIEWPORT_PERSISTENCE=' + JSON.stringify(viewportPersistence))

  // 4b) window hibernation tears down the renderer only: after the grace the
  //     broker owns the same live PTY + disk spool, visibility reattaches it,
  //     replays hidden output, and an existing boot command is never re-run.
  //     The across-update receipt is durable until it is actually seen.
  const terminalContinuity = await win.webContents.executeJavaScript(`(async () => {
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
    const st = window.__kaisola.getState()
    const markerFile = '/tmp/kaisola-hibernate-smoke.txt'
    await window.kaisola.fs.write(markerFile, '')
    st.setLayoutMode('studio')
    st.requestTerminal("printf 'boot-once\\n' >> " + markerFile, { name: 'Hibernate smoke' })
    // fresh read — \`st\` predates the requestTerminal set(), so its stale
    // terminals array would point this whole probe at whatever terminal
    // happened to be last BEFORE the hibernate one was created
    const id = window.__kaisola.getState().terminals.find((t) => t.name === 'Hibernate smoke').id
    st.setDockView(id)
    const originalHidden = Object.getOwnPropertyDescriptor(document, 'hidden')
    let forcedHidden = false
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => forcedHidden })
    document.dispatchEvent(new Event('visibilitychange'))
    await wait(1500) // terminal create + one-shot boot
    const before = (await window.kaisola.terminal.diagnostics(st.activeProjectId)).find((row) => row.id === id)
    const hostBefore = document.querySelector('.term-wrap[data-terminal-id="' + id + '"]')

    forcedHidden = true
    document.dispatchEvent(new Event('visibilitychange'))
    await wait(1550) // > WINDOW_HIBERNATE_GRACE_MS
    const asleepHost = document.querySelector('.term-wrap[data-terminal-id="' + id + '"]')
    const asleepDiag = (await window.kaisola.terminal.diagnostics(st.activeProjectId)).find((row) => row.id === id)
    const rendererReleased = asleepHost?.getAttribute('data-renderer-awake') === 'false' && asleepDiag?.visible === false
    await window.kaisola.terminal.write(id, 'echo hidden-output\\r', st.activeProjectId)
    await wait(300)
    const detachedSnap = await window.kaisola.terminal.snapshot(id, st.activeProjectId)
    const spooled = (detachedSnap.output || '').includes('hidden-output')

    forcedHidden = false
    document.dispatchEvent(new Event('visibilitychange'))
    await wait(750)
    const awakeHost = document.querySelector('.term-wrap[data-terminal-id="' + id + '"]')
    const after = (await window.kaisola.terminal.diagnostics(st.activeProjectId)).find((row) => row.id === id)
    const snap = await window.kaisola.terminal.snapshot(id, st.activeProjectId)
    const samePid = !!before?.pid && before.pid === after?.pid && !after?.exited
    const replayed = (snap.output || '').includes('hidden-output')
    const reattached = awakeHost?.getAttribute('data-renderer-awake') === 'true' && after?.visible === true
    const bootFile = await window.kaisola.fs.read(markerFile)
    const bootOnce = !!bootFile.ok && (bootFile.content.match(/boot-once/g) || []).length === 1

    st.setTerminalContinuation(id, { sameProcess: true, at: Date.now(), terminalPid: after?.pid, outputBytes: 42 })
    await wait(950) // outlast persisted-store throttle
    const raw = window.kaisola.db.getSync('kaisola-store') || ''
    const receiptPersisted = raw.includes('"continued":{"sameProcess":true')
    const tabReceipt = !!document.querySelector('.stab[data-sid="' + id + '"] .stab-continuity')
    const receipt = document.querySelector('.term-wrap[data-terminal-id="' + id + '"] .term-continuity')
    const receiptShown = /Continued/.test(receipt?.textContent || '') && /same process/.test(receipt?.textContent || '')
    receipt?.click()
    await wait(80)
    const receiptCleared = !window.__kaisola.getState().terminals.find((terminal) => terminal.id === id)?.continued &&
      !document.querySelector('.stab[data-sid="' + id + '"] .stab-continuity')

    if (originalHidden) Object.defineProperty(document, 'hidden', originalHidden)
    else delete document.hidden
    await window.kaisola.terminal.kill(id, st.activeProjectId)
    st.closeTerminal(id)
    return {
      mounted: !!hostBefore && before?.visible === true,
      rendererReleased,
      reattached,
      samePid,
      spooled,
      replayed,
      bootOnce,
      receiptPersisted,
      tabReceipt,
      receiptShown,
      receiptCleared,
    }
  })()`)
  console.log('TERMINAL_CONTINUITY=' + JSON.stringify(terminalContinuity))

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
    // Claude is an ACP chat agent (the + menu opens a thread); the prepared
    // per-project TERMINAL still exists separately (claudePrepared covers it)
    const claudeTerminal = !!(claude && !claude.terminalOnly && claude.name === 'Claude')
    const current = window.__kaisola.getState()
    const scope = current.activeProjectId
    const conn = await window.kaisola.acp.connect({ presetId: 'mock', scope, cwd: current.workspacePath })
    if (!conn.ok) return { presets: presets.length, claudeTerminal, connect: false, message: conn.message }
    const agentKey = conn.key
    const authCount = (conn.authMethods || []).length
    // standard ACP set_model (Gemini-style), set_config_option (codex-style), and authenticate
    const setModelRes = await window.kaisola.acp.setModel(agentKey, 'mock-mini')
    const setCfgRes = await window.kaisola.acp.setConfigOption(agentKey, 'reasoning_effort', 'low')
    let authUrlSeen = false
    const offN = window.kaisola.acp.onNotice((n) => { if (n.url) authUrlSeen = true })
    const authRes = await window.kaisola.acp.authenticate(agentKey, 'oauth-mock')
    await new Promise((r) => setTimeout(r, 250))
    offN()
    let streamed = '', thought = '', tools = 0, termEvents = 0
    const offT = window.kaisola.acp.onTerminal(() => { termEvents++ })
    const res = await window.kaisola.acp.prompt(agentKey, 'ping', (u) => {
      if (u.sessionUpdate === 'agent_message_chunk') streamed += (u.content && u.content.text) || ''
      else if (u.sessionUpdate === 'agent_thought_chunk') thought += (u.content && u.content.text) || ''
      else if (u.sessionUpdate === 'tool_call' || u.sessionUpdate === 'tool_call_update') tools++
    })
    offT()
    const st = await window.kaisola.acp.status([agentKey], scope)
    const c = (st.agents.find((a) => a.key === agentKey) || {}).controls || {}
    const modelAfter = (c.models || {}).currentModelId
    const reasoningAfter = ((c.configOptions || []).find((o) => o.id === 'reasoning_effort') || {}).currentValue
    const cancelOk = (await window.kaisola.acp.cancel(agentKey)).ok
    await window.kaisola.acp.disconnect(agentKey)
    return {
      presets: presets.length, claudeTerminal, connect: true, ok: !!res.ok, key: conn.key, cancelOk: !!cancelOk,
      authCount, authOk: !!authRes.ok, authUrlSeen, setModelOk: !!setModelRes.ok, setCfgOk: !!setCfgRes.ok,
      modelAfter, reasoningAfter, ranCommand: streamed.includes('agent-ran-this'),
      gotThought: thought.length > 0, tools, termEvents,
    }
  })()`)
  console.log('ACP=' + JSON.stringify(acp))

  // 7) the + New Session menu opens in a portal (not clipped) and a pointer
  //    anywhere outside it dismisses it immediately.
  const dd = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const originalLayout = get().tabLayout
    get().setTabLayout('sidebar')
    await new Promise((r) => setTimeout(r, 100))
    const btn = document.querySelector('.session-sidebar .stabs > .drop-btn')
    if (!btn) return { hasBtn: false }
    btn.click()
    await new Promise((r) => setTimeout(r, 150))
    const menu = document.querySelector('body > .drop-menu') || document.querySelector('.drop-menu')
    const items = document.querySelectorAll('.drop-menu .drop-item')
    const portal = !!(menu && menu.parentElement === document.body)
    document.querySelector('.canvas')?.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 50))
    const clickAway = !document.querySelector('.drop-menu')
    get().setTabLayout(originalLayout)
    const out = { hasBtn: true, newSession: /new session/i.test(btn.getAttribute('title') || ''), portal, items: items.length, clickAway }
    return out
  })()`)
  console.log('DROPDOWN=' + JSON.stringify(dd))

  // 7a) permission rulesets — "always allow" saves a rule + retroactively
  //     resolves matching pending asks; deny cascades across the agent's
  //     other asks; rule-covered asks never surface a card at all.
  const permrules = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const prevWs = st.workspacePath
    const ruleWs = prevWs || '/tmp/permrules-ws'
    if (!prevWs) st.setWorkspace(ruleWs)
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
    const saved = g().permissionRules.some((r) => r.workspace === ruleWs && r.action === 'execute' && r.resource === 'git *')
    const cascaded = afterAlways.length === 1 && afterAlways[0] === 'p3' // p2 resolved retroactively
    // a NEW matching ask is auto-answered — no card
    g().receivePermission(ask('p4', 'execute', 'git log'))
    const autoAnswered = !g().pendingPermissions.some((p) => p.permId === 'p4')
    // deny cascades across the same agent's remaining asks
    g().pushPermission(ask('p5', 'execute', 'rm -rf build'))
    g().answerPermission('p3', { optionId: 'r1' }, { cascadeReject: true })
    const pendingAfter = g().pendingPermissions.length
    // cleanup
    g().permissionRules.filter((r) => r.workspace === ruleWs && r.resource === 'git *').forEach((r) => g().removePermissionRule(r.id))
    return { saved, cascaded, autoAnswered, rejectCascade: pendingAfter === 0, pendingAfter }
  })()`)
  console.log('PERMRULES=' + JSON.stringify(permrules))

  // 7a-ii) sensitive-file guardrails — matching asks always surface a card
  //        (flagged), rules can never cover them, and no rule auto-allows them.
  const sensitive = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const prevWs = st.workspacePath
    const ruleWs = prevWs || '/tmp/sensitive-ws'
    if (!prevWs) st.setWorkspace(ruleWs)
    const g = () => window.__kaisola.getState()
    const ask = (permId, kind, title, diffs) => ({ permId, key: 'mock', agent: 'Mock', title, kind, diffs,
      options: [{ optionId: 'a1', name: 'Allow', kind: 'allow_once' }, { optionId: 'r1', name: 'Deny', kind: 'reject_once' }] })
    // a rule that WOULD cover cat — the sensitive path must beat it
    g().pushPermission(ask('s0', 'execute', 'cat README.md'))
    g().alwaysAllowPermission('s0')
    const baselineRuleIds = new Set(g().permissionRules.map((r) => r.id))
    g().receivePermission(ask('s1', 'execute', 'cat .env.local'))
    const p1 = g().pendingPermissions.find((p) => p.permId === 's1')
    const surfaced = !!p1 && p1.sensitive === true
    g().alwaysAllowPermission('s1')
    const stillPending = g().pendingPermissions.some((p) => p.permId === 's1') // refused to make a rule
    const noSensitiveRule = g().permissionRules.every((r) => baselineRuleIds.has(r.id))
    // diff-shaped sensitive ask (edit kind carries the path in diffs)
    g().receivePermission(ask('s2', 'edit', 'Edit config', [{ path: 'conf/secrets.yml', oldText: '', newText: 'x' }]))
    const diffFlagged = g().pendingPermissions.find((p) => p.permId === 's2')?.sensitive === true
    // cleanup
    g().answerPermission('s1', { optionId: 'a1' })
    g().answerPermission('s2', { optionId: 'r1' }, { cascadeReject: true })
    g().permissionRules.filter((r) => r.workspace === ruleWs && r.resource === 'cat *').forEach((r) => g().removePermissionRule(r.id))
    return { surfaced, stillPending, diffFlagged, noSensitiveRule, pendingAfter: g().pendingPermissions.length }
  })()`)
  console.log('SENSITIVE=' + JSON.stringify(sensitive))

  // 7b) current agent work is ONE compact live line (the transcript owns
  //     history); subagents and live terminals remain directly reachable.
  const activityUi = await win.webContents.executeJavaScript(`(async () => {
    // the fresh shell seeds no chat thread — this probe exercises one
    if (!window.__kaisola.getState().assistantThreads.length) window.__kaisola.getState().requestNewThread('mock')
    const st = window.__kaisola.getState()
    st.setLayoutMode('studio')
    st.setTabLayout('sidebar')
    if (!st.railOpen) st.toggleRail()
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
      terminalMeta: { ...s.terminalMeta, 'activity-smoke-term': { running: true, fgProcess: 'npm' } },
    }))
    await new Promise((r) => setTimeout(r, 180))
    const card = document.querySelector('.agent-livebar')
    const text = card?.textContent || ''
    const liveDot = card?.querySelector('.agent-live-dot')
    const liveDotStyle = liveDot ? getComputedStyle(liveDot) : null
    return {
      card: !!card,
      hasSubagent: /coding subagent/.test(text) && !!card?.querySelector('.agent-live-pill svg'),
      hasTerminal: /npm run smoke/.test(text),
      hasStatus: !!card?.querySelector('.agent-live-dot') && !document.querySelector('.agent-activity'),
      standardizedDot: liveDotStyle?.width === '6px' && liveDotStyle?.height === '6px',
      openBtn: !!card?.querySelector('button.agent-live-pill'),
      noContext: !document.querySelector('.context-ledger'),
      noMention: !document.querySelector('button[title^="Reference a paper"]'),
      compactChrome: !document.querySelector('.tabstrip-tools') && !!document.querySelector('.shell-sidebar-footer'),
      noLayoutControl: !document.querySelector('.shell-layout-trigger'),
      settingsControl: !!document.querySelector('.shell-sidebar-footer .shell-settings-trigger[aria-label="Open settings"]'),
      addContext: !!document.querySelector('.composer-add[aria-label*="Add files"]'),
    }
  })()`)
  console.log('ACTIVITY_UI=' + JSON.stringify(activityUi))

  const composerAddUi = await win.webContents.executeJavaScript(`(async () => {
    const wait = (ms = 100) => new Promise((resolve) => setTimeout(resolve, ms))
    const state = window.__kaisola.getState()
    let createdThreadId = null
    if (state.assistantThreads.length < 2) {
      state.requestNewThread('mock')
      await wait(180)
      createdThreadId = window.__kaisola.getState().activeThreadId
    }
    const button = document.querySelector('.composer-add')
    button?.click()
    await wait()
    const menu = document.querySelector('.composer-add-pop')
    const text = menu?.textContent || ''
    const buttonRect = button?.getBoundingClientRect()
    const menuRect = menu?.getBoundingClientRect()
    const input = document.querySelector('.composer textarea')
    input?.focus()
    await wait(220)
    const composerStyle = getComputedStyle(document.querySelector('.composer'))
    const result = {
      button: !!button,
      menu: !!menu,
      files: /Files/.test(text),
      plugins: /Plugins and integrations/.test(text),
      sessions: /Prior sessions/.test(text),
      noPaperPin: !document.querySelector('button[title^="Reference a paper"]'),
      opensAbove: !!buttonRect && !!menuRect && menuRect.bottom <= buttonRect.top + 1,
      elevatedFocus: composerStyle.boxShadow !== 'none' && composerStyle.transform !== 'none',
    }
    button?.click()
    if (createdThreadId) state.closeAssistantThread(createdThreadId)
    return result
  })()`)
  console.log('COMPOSER_ADD_UI=' + JSON.stringify(composerAddUi))

  // 7b-ii) project/window tabs derive running state from parked slices. Eco
  // keeps the tiny opacity pulse, completion stays still, and clearing the
  // unread receipt removes the dot. Native attention plumbing is exposed.
  const attentionUi = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const pid = st.newProject({ path: '/tmp/attention-smoke', focus: false })
    // fresh slices seed no chat thread — park one to drive the busy/needs-you dots
    st.patchProject(pid, () => ({ assistantThreads: [{ id: 'att-thr', agentKey: 'mock', busy: false }], activeThreadId: 'att-thr' }))
    const tid = 'att-thr'
    st.patchProject(pid, (sl) => ({
      assistantThreads: sl.assistantThreads.map((thread) => thread.id === tid ? { ...thread, busy: true } : thread),
    }))
    await new Promise((resolve) => setTimeout(resolve, 100))
    let tab = document.querySelector('.ptab[data-project-id="' + pid + '"]')
    const dot = tab?.querySelector('.ptab-badge')
    const running = tab?.getAttribute('data-state') === 'running'
    const pulse = dot ? getComputedStyle(dot).animationName.includes('queue-pulse') : false
    st.patchProject(pid, (sl) => ({
      assistantThreads: sl.assistantThreads.map((thread) => thread.id === tid ? { ...thread, busy: false } : thread),
      needsYou: { ...sl.needsYou, [tid]: true },
    }))
    await new Promise((resolve) => setTimeout(resolve, 80))
    tab = document.querySelector('.ptab[data-project-id="' + pid + '"]')
    const completed = tab?.getAttribute('data-state') === 'completed'
    const still = tab?.querySelector('.ptab-badge') ? getComputedStyle(tab.querySelector('.ptab-badge')).animationName === 'none' : false
    st.patchProject(pid, (sl) => ({ needsYou: {} }))
    await new Promise((resolve) => setTimeout(resolve, 80))
    tab = document.querySelector('.ptab[data-project-id="' + pid + '"]')
    const cleared = !tab?.getAttribute('data-state')
    const nativeAttention = typeof window.kaisola.attention?.setCount === 'function' && typeof window.kaisola.attention?.notify === 'function'
    st.closeProject(pid, { force: true })
    return { running, pulse, completed, still, cleared, nativeAttention }
  })()`)
  console.log('ATTENTION_UI=' + JSON.stringify(attentionUi))

  // The detached PTY broker, not xterm, owns CLI turn quieting. Prove an Eco
  // renderer can detach completely and still receive the completion receipt.
  const brokerActivity = await win.webContents.executeJavaScript(`(async () => {
    const id = 'agent-activity-broker-smoke'
    const events = []
    const off = window.kaisola.terminal.onAgentActivity((event) => {
      if (event.id === id) events.push(event)
    })
    const projectId = window.__kaisola.getState().activeProjectId
    const created = await window.kaisola.terminal.create(id, '/tmp', 80, 24, projectId)
    window.kaisola.terminal.agentTurn(id, true, projectId)
    await new Promise((resolve) => setTimeout(resolve, 160))
    const detached = await window.kaisola.terminal.detachRenderer(id, undefined, projectId)
    for (let i = 0; i < 32 && !events.some((event) => !event.busy && event.completedAt); i++) {
      await new Promise((resolve) => setTimeout(resolve, 180))
    }
    const snapshot = await window.kaisola.terminal.snapshot(id, projectId)
    off()
    await window.kaisola.terminal.kill(id, projectId)
    return {
      created: !!created.ok,
      began: events.some((event) => event.busy),
      detached: !!detached.ok,
      settled: events.some((event) => !event.busy && !!event.completedAt),
      durable: snapshot.agentBusy === false && Number(snapshot.agentCompletedAt) > 0,
    }
  })()`)
  console.log('BROKER_ACTIVITY=' + JSON.stringify(brokerActivity))

  // 7b-iii) ACP prose uses compact Markdown rhythm rather than preserving
  // source blank lines on top of block margins. Local Markdown links route to
  // the Files preview (and retain line hints) instead of leaving the app.
  const agentLinkRoot = path.join(os.tmpdir(), 'kaisola-agent-link-smoke')
  const agentLinkTarget = path.join(agentLinkRoot, 'linked-note.md')
  fsx.mkdirSync(agentLinkRoot, { recursive: true })
  fsx.writeFileSync(agentLinkTarget, Array.from({ length: 24 }, (_, i) => `line ${i + 1}`).join('\n'))
  const transcriptTypography = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const tid = st.activeThreadId
    st.setWorkspace(${JSON.stringify(agentLinkRoot)})
    st.setAssistantThreadAgent(tid, 'mock')
    st.updateAssistantRuntime(tid, () => ({
      first: false,
      turns: [
        { kind: 'user', text: 'Inspect the linked note', at: Date.now() - 4000 },
        { kind: 'assistant', text: ${JSON.stringify(`A concise paragraph.\n\n- First item\n- Second item\n\n[linked note](${agentLinkTarget}:17)`)}, at: Date.now() - 3000 },
        { kind: 'user', text: 'Summarize the result', at: Date.now() - 2000 },
        { kind: 'assistant', text: 'The note is ready to review.', at: Date.now() - 1000 },
      ],
    }))
    st.setDockView(tid)
    await new Promise((resolve) => setTimeout(resolve, 120))
    const text = document.querySelector('.turn-assistant .turn-text')
    const stream = document.querySelector('.assistant-stream')
    const li = text?.querySelector('li')
    const userText = document.querySelector('.turn-user .turn-text')
    const userTurn = document.querySelector('.turn-user')
    const agentTurn = document.querySelector('.turn-assistant')
    const userRect = userText?.getBoundingClientRect()
    const agentRect = text?.getBoundingClientRect()
    const userTurnRect = userTurn?.getBoundingClientRect()
    const agentTurnRect = agentTurn?.getBoundingClientRect()
    const userStyle = userText ? getComputedStyle(userText) : null
    const agentStyle = text ? getComputedStyle(text) : null
    const roleAlignment = !!userTurnRect && !!agentTurnRect && userTurnRect.left > agentTurnRect.left && Math.abs(userTurnRect.right - agentTurnRect.right) < 2
    const roleBackground = !!userStyle && !!agentStyle && userStyle.backgroundColor !== agentStyle.backgroundColor
    const roleIcons = !!document.querySelector('.turn-user .turn-avatar svg') && !!document.querySelector('.turn-assistant .turn-avatar svg')
    const differentiatedRoles = roleAlignment && roleBackground && roleIcons
    const promptTabs = [...document.querySelectorAll('.turn-tab-prompt')]
    promptTabs[0]?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 80))
    const localLink = text?.querySelector('a[data-local-file="true"]')
    localLink?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))
    await new Promise((resolve) => setTimeout(resolve, 240))
    const afterLink = window.__kaisola.getState()
    const style = text ? getComputedStyle(text) : null
    return {
      rendered: !!text?.querySelector('.md p') && !!li,
      normalWhitespace: style?.whiteSpace === 'normal',
      readableWidth: !!style?.maxWidth && style.maxWidth !== 'none' && parseFloat(style.maxWidth) <= 1100,
      compactStream: stream ? parseFloat(getComputedStyle(stream).rowGap) <= 10 : false,
      compactList: li ? parseFloat(getComputedStyle(li).marginBottom) <= 4 : false,
      differentiatedRoles,
      roleDebug: { roleAlignment, roleBackground, roleIcons, userLeft: userTurnRect?.left, agentLeft: agentTurnRect?.left, userBg: userStyle?.backgroundColor, agentBg: agentStyle?.backgroundColor },
      promptRail: promptTabs.length === 2 && promptTabs[0]?.getAttribute('data-active') === 'true',
      promptRailMinimal: (() => {
        const rail = document.querySelector('.turn-rail')
        const style = rail ? getComputedStyle(rail) : null
        return !!rail && rail.parentElement?.classList.contains('assistant') && style?.position === 'absolute' && !document.querySelector('.turn-tabs-wrap')
      })(),
      localLink: !!localLink,
      linkOpenedFiles: afterLink.stage === 'files' && afterLink.fileRequest?.path === ${JSON.stringify(agentLinkTarget)},
      lineJump: afterLink.scrollRequest?.path === ${JSON.stringify(agentLinkTarget)} && afterLink.scrollRequest?.line === 17,
    }
  })()`)
  console.log('TRANSCRIPT_TYPOGRAPHY=' + JSON.stringify(transcriptTypography))

  // 7c) prompts typed while an ACP turn is active coalesce into ONE ordered
  //     follow-up and drain without relying on a React re-render after a ref
  //     flips. This regresses the two-item queue that used to remain stranded.
  const promptQueue = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
    get().setWorkspace(${JSON.stringify(claudeRoot)})
    const tid = get().activeThreadId
    get().setAssistantThreadAgent(tid, 'mock')
    get().resetAssistantRuntime(tid)
    get().setDockView(tid)
    await wait(220)
    get().setAssistantDraft(tid, { text: '[queue-smoke-hold] first turn', attachments: [], mentions: [], speed: 'default' })
    await wait(80)
    const assistant = document.querySelector('.assistant[data-thread-id="' + tid + '"]')
    const send = assistant?.querySelector('.composer-send:not(.composer-stop)')
    send?.click()
    let started = false
    for (let i = 0; i < 50; i++) {
      if (get().assistantThreads.find((thread) => thread.id === tid)?.busy) { started = true; break }
      await wait(40)
    }
    get().enqueueAssistantPrompt(tid, { text: 'queue-smoke-second', attachments: [], mentions: [], speed: 'default' })
    get().enqueueAssistantPrompt(tid, { text: 'queue-smoke-third', attachments: [], mentions: [], speed: 'fast' })
    const queuedTwo = (get().assistantPromptQueues[tid] || []).length === 2
    await wait(80)
    const queueRows = [...(assistant?.querySelectorAll('.composer-queue-preview-row') || [])]
    const inlinePreview = queueRows.length === 2 && !assistant?.querySelector('.composer-queue-capsule')
    const preview = assistant?.querySelector('.composer-queue-preview')
    const aboveComposer = preview?.nextElementSibling?.classList.contains('composer') === true
    const attachedComposer = preview?.parentElement?.classList.contains('composer-stack') === true
    const queueActions = queueRows.every((row) =>
      !!row.querySelector('.composer-queue-steer') &&
      !!row.querySelector('[aria-label="Delete queued prompt"]') &&
      !!row.querySelector('[aria-label="Edit queued prompt"]'))
    const noQueueToast = ![...document.querySelectorAll('.toast')].some((node) => /queued prompt/i.test(node.textContent || ''))
    for (let i = 0; i < 180; i++) {
      const state = get()
      const threadBusy = state.assistantThreads.find((thread) => thread.id === tid)?.busy
      const turns = state.assistantRuntimes[tid]?.turns || []
      const delivered = turns.some((turn) => turn.kind === 'assistant' && turn.text.includes('queue-smoke-second') && turn.text.includes('queue-smoke-third'))
      if (!threadBusy && !(state.assistantPromptQueues[tid] || []).length && delivered) break
      await wait(50)
    }
    const state = get()
    const turns = state.assistantRuntimes[tid]?.turns || []
    const users = turns.filter((turn) => turn.kind === 'user')
    const combined = users.filter((turn) => turn.text.includes('queue-smoke-second') && turn.text.includes('queue-smoke-third'))
    return {
      started,
      queuedTwo,
      inlinePreview,
      aboveComposer,
      attachedComposer,
      queueActions,
      noQueueToast,
      drained: !(state.assistantPromptQueues[tid] || []).length && !state.assistantThreads.find((thread) => thread.id === tid)?.busy,
      combinedOnce: users.length === 2 && combined.length === 1 && combined[0].text.indexOf('queue-smoke-second') < combined[0].text.indexOf('queue-smoke-third'),
      deliveredTogether: turns.some((turn) => turn.kind === 'assistant' && turn.text.includes('queue-smoke-second') && turn.text.includes('queue-smoke-third')),
      newestSpeedWon: turns.some((turn) => turn.kind === 'assistant' && turn.text.includes('Kaisola speed: Fast') && turn.text.includes('queue-smoke-third')),
    }
  })()`)
  console.log('PROMPT_QUEUE=' + JSON.stringify(promptQueue))

  // 7c-ii) QUEUE THEN EXPLICIT STEER — submitting while a turn runs must QUEUE
  //        the follow-up (auto-steer made "Queue prompt" silently mean "send
  //        now"). The queued row's Steer button then injects it into the
  //        RUNNING turn, and the turn ends only after BOTH settle.
  const steer = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
    get().setWorkspace(${JSON.stringify(claudeRoot)})
    const tid = get().activeThreadId
    get().setAssistantThreadAgent(tid, 'mock')
    get().resetAssistantRuntime(tid)
    get().setDockView(tid)
    await wait(200) // the mock (connected in PROMPT_QUEUE) advertises promptQueueing → canSteer
    const assistant = document.querySelector('.assistant[data-thread-id="' + tid + '"]')
    // first turn holds ~350ms before streaming (the mock's [queue-smoke-hold])
    get().setAssistantDraft(tid, { text: '[queue-smoke-hold] steer-base', attachments: [], mentions: [], speed: 'default' })
    await wait(80)
    const send = () => assistant?.querySelector('.composer-send:not(.composer-stop)')
    send()?.click()
    let started = false
    for (let i = 0; i < 50; i++) { if (get().assistantThreads.find((t) => t.id === tid)?.busy) { started = true; break } await wait(20) }
    // while busy, submit a follow-up — it must land in the QUEUE, untouched
    get().setAssistantDraft(tid, { text: 'steer-follow', attachments: [], mentions: [], speed: 'default' })
    await wait(40)
    send()?.click()
    await wait(120)
    const queuedWhileBusy = (get().assistantPromptQueues[tid] || []).some((q) => q.text.includes('steer-follow'))
      && !(get().assistantRuntimes[tid]?.turns || []).some((t) => t.kind === 'user' && t.text.includes('steer-follow'))
    // the queued row's explicit Steer action injects it into the running turn
    assistant?.querySelector('.composer-queue-steer')?.click()
    await wait(120)
    const midUsers = (get().assistantRuntimes[tid]?.turns || []).filter((t) => t.kind === 'user')
    const steeredWhileBusy = get().assistantThreads.find((t) => t.id === tid)?.busy
      && midUsers.some((t) => t.text.includes('steer-follow'))
      && (get().assistantPromptQueues[tid] || []).length === 0
    // let both turns settle
    for (let i = 0; i < 200; i++) {
      const s = get()
      const busy = s.assistantThreads.find((t) => t.id === tid)?.busy
      const turns = s.assistantRuntimes[tid]?.turns || []
      const both = turns.some((t) => t.kind === 'assistant' && t.text.includes('steer-follow')) && turns.some((t) => t.kind === 'assistant' && t.text.includes('steer-base'))
      if (!busy && both) break
      await wait(50)
    }
    const turns = get().assistantRuntimes[tid]?.turns || []
    const users = turns.filter((t) => t.kind === 'user')
    return {
      started,
      queuedWhileBusy: !!queuedWhileBusy,
      steeredWhileBusy: !!steeredWhileBusy,
      twoUserTurns: users.length === 2 && users.some((t) => t.text.includes('steer-base')) && users.some((t) => t.text.includes('steer-follow')),
      followDelivered: turns.some((t) => t.kind === 'assistant' && t.text.includes('you said: steer-follow')),
      // the base turn rides sendText, whose payload prepends speed/context — so
      // match the echoed prompt as a substring, not the bare "you said:" prefix
      baseDelivered: turns.some((t) => t.kind === 'assistant' && t.text.includes('steer-base')),
      endedIdle: !get().assistantThreads.find((t) => t.id === tid)?.busy,
    }
  })()`)
  console.log('STEER=' + JSON.stringify(steer))

  // 7c-iii) STOP DURING AWAITED PREFLIGHT -> IMMEDIATE CLOSE. The mock's Fast
  // config request stays pending for 700ms. Stop and close in the same renderer
  // task; the recently-closed snapshot must contain the restored draft, never
  // the optimistic unsent row. Reopening before the await settles must remain
  // stable when the stale continuation eventually resumes.
  const preflightStopClose = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
    const marker = 'preflight-stop-close-regression'
    get().requestNewThread('mock')
    const tid = get().activeThreadId
    get().setDockView(tid)

    let assistant = null
    let connectButton = null
    for (let i = 0; i < 80; i++) {
      assistant = document.querySelector('.assistant[data-thread-id="' + tid + '"]')
      connectButton = assistant?.querySelector('.assistant-foot .foot-link')
      if (connectButton) break
      await wait(50)
    }
    // Ordinary transcripts connect lazily. Drive the real Connect control first
    // so the subsequent Send render owns the mock's native speed control.
    connectButton?.click()
    let speedReady = false
    for (let i = 0; i < 100; i++) {
      const status = await window.kaisola.acp.status(['mock::' + tid], get().activeProjectId)
      // Raw preload summaries retain the internal @@project scope suffix; the
      // renderer bridge strips it before Assistant sees the same connection.
      const controls = status.agents.find((agent) => agent.key.startsWith('mock::' + tid))?.controls
      if (controls?.configOptions?.some((option) => option.id === 'response_speed')) { speedReady = true; break }
      await wait(50)
    }
    await wait(160) // refresh() -> local controls -> Send closure with applySpeed
    get().setAssistantDraft(tid, { text: marker, attachments: [], mentions: [], speed: 'fast' })
    await wait(80)
    assistant = document.querySelector('.assistant[data-thread-id="' + tid + '"]')
    assistant?.querySelector('.composer-send:not(.composer-stop)')?.click()

    let pendingSeen = false
    for (let i = 0; i < 80; i++) {
      const state = get()
      if (state.assistantThreads.find((thread) => thread.id === tid)?.busy && state.assistantRuntimes[tid]?.pendingDispatch) {
        pendingSeen = true
        break
      }
      await wait(25)
    }
    const stop = assistant?.querySelector('.composer-stop')
    stop?.click()
    // Deliberately no await: this is the original same-tick close race.
    get().closeAssistantThread(tid)

    const closed = get().closedStack.find((entry) => entry.thread?.id === tid)
    const closedTurns = closed?.runtime?.turns || []
    const closedClean = !!closed && !closed.runtime?.pendingDispatch && !closedTurns.some((turn) => turn.text.includes(marker))
    const closedDraft = closed?.draft?.text === marker
    const closedImmediately = !get().assistantThreads.some((thread) => thread.id === tid)

    get().reopenClosedSession(tid)
    const reopenedNow = get()
    const reopenedDraft = reopenedNow.assistantDrafts[tid]?.text === marker
    const reopenedClean = !reopenedNow.assistantRuntimes[tid]?.pendingDispatch &&
      !(reopenedNow.assistantRuntimes[tid]?.turns || []).some((turn) => turn.text.includes(marker))
    await wait(950)
    const settled = get()
    const turns = settled.assistantRuntimes[tid]?.turns || []
    const staleContinuationIgnored = settled.assistantDrafts[tid]?.text === marker &&
      !settled.assistantRuntimes[tid]?.pendingDispatch &&
      !turns.some((turn) => turn.text.includes(marker)) &&
      !(settled.assistantPromptQueues[tid] || []).some((prompt) => prompt.text.includes(marker)) &&
      !settled.assistantThreads.find((thread) => thread.id === tid)?.busy
    const firstPreserved = settled.assistantRuntimes[tid]?.first === true
    get().closeAssistantThread(tid)
    get().forgetClosedSession(tid)
    return { speedReady, pendingSeen, stopRendered: !!stop, closedImmediately, closedClean, closedDraft, reopenedDraft, reopenedClean, staleContinuationIgnored, firstPreserved }
  })()`)
  console.log('PREFLIGHT_STOP_CLOSE=' + JSON.stringify(preflightStopClose))

  // 8) persistence — the store writes to the durable main-process DB (SQLite,
  //    JSON fallback). Verify the blob round-trips + which backend is active.
  const persist = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setTheme('dark')
    st.setAgentPreset('opencode')
    st.updateAssistantRuntime(st.activeThreadId, () => ({ first: false, turns: [{ kind: 'user', text: 'persisted chat turn', at: 1 }] }))
    st.setAssistantDraft(st.activeThreadId, { text: 'x'.repeat(1000100) })
    const draftBounded = window.__kaisola.getState().assistantDrafts[st.activeThreadId].text.length === 1000000
    st.setAssistantDraft(st.activeThreadId, { text: 'persisted unsent draft' })
    st.setThreadCodexEffort(st.activeThreadId, 'ultra')
    st.setTabLayout('bare')
    await new Promise((r) => setTimeout(r, 1000)) // outlast the write-throttled persist (800ms) + async db.set
    const raw = window.kaisola.db.getSync('kaisola-store')
    const kind = await window.kaisola.db.kind()
    return {
      stored: !!raw,
      hasTheme: !!(raw && raw.includes('"theme":"dark"')),
      hasAgent: !!(raw && raw.includes('"agentPreset":"opencode"')),
      hasThread: !!(raw && raw.includes('"assistantThreads"')),
      hasChatTurn: !!(raw && raw.includes('persisted chat turn')),
      hasDraft: !!(raw && raw.includes('persisted unsent draft')),
      draftBounded,
      hasCodexEffort: !!(raw && raw.includes('"codexEffort":"ultra"')),
      hasTabLayout: !!(raw && raw.includes('"tabLayout":"bare"')),
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
    // the solo-baseline assertions below need EXACTLY one card — earlier
    // probes (thread creation, terminals) leave their session cards docked
    for (const v of window.__kaisola.getState().dockViews.filter((x) => x !== window.__kaisola.getState().activeThreadId)) {
      window.__kaisola.getState().removeDockView(v)
    }
    await new Promise((r) => setTimeout(r, 150))
    const shown = document.querySelectorAll('.session-card[data-show="true"]')
    const canvas = document.querySelector('.canvas-wrap > .canvas')
    const c = canvas && canvas.getBoundingClientRect()
    const s0 = shown[0] && shown[0].getBoundingClientRect()
    const baseline = {
      cardPerView: shown.length === window.__kaisola.getState().dockViews.length,
      chatLeftOfFiles: !!(s0 && c && s0.left < c.left),
      soloHeadSuppressed: !!document.querySelector('.session-card[data-show="true"][data-headless="true"]') && !document.querySelector('.session-card[data-show="true"] .pane-head'),
      noDockPanel: !document.querySelector('.dock'),
    }
    return {
      ...baseline,
      emptyMessageGone: !document.querySelector('.assistant-empty'),
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
  fsx.writeFileSync(path.join(fileUiRoot, 'table.csv'), 'name,score\nAda,98\nGrace,97\n')
  fsx.writeFileSync(path.join(fileUiRoot, 'tree.json'), '{"project":"Kaisola","features":["extensions","previews"]}\n')
  fsx.writeFileSync(path.join(fileUiRoot, 'tree-wide.json'), JSON.stringify(Array.from({ length: 240 }, () => Array.from({ length: 240 }, () => 1))))
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
    document.querySelector('.fx-doc-markdown')?.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true }))
    await new Promise((r) => setTimeout(r, 180))
    const cleanEditor = document.querySelector('.fx-doc-markdown[data-editing] .fx-doc-page[contenteditable="true"]')
    const mdCleanEdit = !!cleanEditor && !!document.querySelector('.fx-md-editing') && !document.querySelector('.fx-doc-markdown .cm-editor')
    const mdAuthoringToolbar = !!document.querySelector('.fx-md-toolbar[role="toolbar"]') &&
      !!document.querySelector('.fx-md-toolbar [aria-label="Text style"]') &&
      !!document.querySelector('.fx-md-toolbar [aria-label="Bold"]') &&
      !!document.querySelector('.fx-md-toolbar [aria-label="Add link"]') &&
      !!document.querySelector('.fx-md-toolbar [aria-label="Bulleted list"]')
    let mdBoldCommand = false
    if (cleanEditor) {
      cleanEditor.innerHTML = '<h1>beta</h1><p>Edited cleanly olive.</p>'
      cleanEditor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: '.' }))
      const textNode = cleanEditor.querySelector('p')?.firstChild
      if (textNode) {
        const range = document.createRange()
        range.setStart(textNode, 0)
        range.setEnd(textNode, 6)
        const selection = window.getSelection()
        selection.removeAllRanges()
        selection.addRange(range)
        document.dispatchEvent(new Event('selectionchange'))
        await new Promise((r) => setTimeout(r, 40))
        document.querySelector('.fx-md-toolbar [aria-label="Bold"]')?.click()
        await new Promise((r) => setTimeout(r, 40))
        mdBoldCommand = /Edited/.test(cleanEditor.querySelector('strong, b')?.textContent || '')
      }
    }
    await new Promise((r) => setTimeout(r, 180))
    const saveButton = [...document.querySelectorAll('.fx-save')].find((button) => !button.disabled)
    saveButton?.click()
    await new Promise((r) => setTimeout(r, 260))
    const cleanSaved = await window.kaisola.fs.read(${JSON.stringify(path.join(fileUiRoot, 'beta-notes.md'))})
    const mdCleanMarkdown = /^# beta\\n\\n\\*\\*Edited\\*\\* cleanly olive\\./.test(cleanSaved.content || '')
    const previewButton = [...document.querySelectorAll('.fx-mode')].find((button) => /preview/i.test(button.textContent || ''))
    previewButton?.click()
    await new Promise((r) => setTimeout(r, 180))
    const mdCleanPreview = /Edited cleanly olive\\./.test(document.querySelector('.fx-doc-markdown')?.textContent || '')
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
        // 2.5s deadline: without per-frame glass recomposition the hidden
        // window schedules frames lazily, and a loaded machine can push the
        // rAF-applied zoom past the old 1.2s (it flaked, not failed)
        if (codeCssNow > codeCssBefore || performance.now() - started > 2500) resolve()
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
    const toolbarNode = document.querySelector('.fx-toolbar')
    const topBarBordersVisible = !!toolbarNode &&
      cssAlpha(getComputedStyle(toolbarNode).borderBottomColor) > 0.05
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
    await new Promise((r) => setTimeout(r, 1000)) // outlast the write-throttled persist (800ms)
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
      mdCleanEdit,
      mdAuthoringToolbar,
      mdBoldCommand,
      mdCleanMarkdown,
      mdCleanPreview,
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

  // 13) sessions live in the left vertical navigator (the right rail is files
  //     only); a new agent thread adds a tab there and focuses the dock pane.
  //     The dock itself carries no tab chrome; identity sits in the foot.
  const layout = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    st.setLayoutMode('studio')
    st.setTabLayout('sidebar')
    if (!st.railOpen) st.toggleRail()
    st.setDock(true, 'assistant')
    await new Promise((r) => setTimeout(r, 150))
    const tabsN = () => document.querySelectorAll('.stabs .stab').length
    const before = tabsN()
    const foot = document.querySelector('.assistant-foot')
    st.requestNewThread()
    await new Promise((r) => setTimeout(r, 150))
    const after = tabsN()
    const s2 = window.__kaisola.getState()
    return {
      sessionsInRail: before >= 2 && !!document.querySelector('.session-sidebar .stabs[aria-orientation="vertical"]'),
      hasRailTreeArea: !!document.querySelector('.app-body > .wsrail[data-side="right"] .wsrail-files'),
      railHasNoSessions: document.querySelectorAll('.wsrail .session-row').length === 0,
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
    const btn = document.querySelector('.stabs .drop-btn')
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
    // Claude is an ACP chat agent since v0.1.20 — the + menu opens a THREAD
    // keyed to claude-code (the prepared per-project terminal is separate)
    const claudeThread = mid.assistantThreads[mid.assistantThreads.length - 1]
    const claudeOpensThread = mid.assistantThreads.length === before + 1 && claudeThread?.agentKey === 'claude-code'
    const claudeNoTerminal = mid.terminals.length === beforeTerms
    btn.click()
    await new Promise((rr) => setTimeout(rr, 150))
    const items2 = [...document.querySelectorAll('.drop-menu .drop-item')]
    const agentItem = items2.find((i) => /codex/i.test(i.textContent || ''))
      || items.find((i) => /codex/i.test(i.textContent || ''))
    if (agentItem) agentItem.click() // really adds a session
    await new Promise((rr) => setTimeout(rr, 150))
    const after = window.__kaisola.getState().assistantThreads.length
    const claudeBrandIcon = !!document.querySelector('.stab svg[aria-label="Claude"]')
    const openaiBrandIcon = !!document.querySelector('.stab svg[aria-label="OpenAI"]')
    return {
      hasBtn: true,
      noDrag,
      pronounced: r.width >= 24 && r.height >= 24,
      hasTerminalOption: labels.some((l) => /terminal/i.test(l)),
      agentChoices: labels.length >= 4, // 3+ agent presets + terminal
      claudeOpensThread,
      claudeNoTerminal,
      claudeBrandIcon,
      openaiBrandIcon,
      adds: after === before + 2, // the claude thread above + the codex thread here
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

  // 13e0) the main view is minimizable from the permanent top-right pair; when
  //       hidden the work row holds only session cards.
  const canvasMin = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    get().setStage('corpus') // canvas shown
    await new Promise((r) => setTimeout(r, 120))
    const shownBefore = !!document.querySelector('.canvas-wrap')
    const topClose = document.querySelector('.tabstrip-view-controls [aria-label="Hide file preview"]')
    const permanentTopControl = !!topClose && !document.querySelector('.canvas-local-close')
    topClose?.click()
    await new Promise((r) => setTimeout(r, 300))
    const hidden = !document.querySelector('.canvas-wrap') && get().canvasOpen === false
    const topRestore = document.querySelector('.tabstrip-view-controls [aria-label="Show file preview"]')
    const permanentRestore = !!topRestore && !document.querySelector('.shell-sidebar-footer [aria-label="Show file preview"]')
    const cardsStay = get().dockOpen && !!document.querySelector('.session-card[data-show="true"]')
    topRestore?.click()
    await new Promise((r) => setTimeout(r, 300))
    const restoredByTop = !!document.querySelector('.canvas-wrap') && get().canvasOpen === true && !!document.querySelector('.tabstrip-view-controls [aria-label="Hide file preview"]')
    get().toggleCanvas()
    get().setStage('claims') // navigating restores the main view
    await new Promise((r) => setTimeout(r, 120))
    const restoredByNav = !!document.querySelector('.canvas-wrap') && get().canvasOpen === true
    get().toggleCanvas()
    await new Promise((r) => setTimeout(r, 100))
    const hiddenAgain = !document.querySelector('.canvas-wrap')
    get().requestFile('/etc/hosts') // opening a file restores it too
    await new Promise((r) => setTimeout(r, 120))
    const restoredByFile = !!document.querySelector('.canvas-wrap') && get().canvasOpen === true
    return { shownBefore, permanentTopControl, hidden, permanentRestore, restoredByTop, cardsStay, restoredByNav, restoredByFile }
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
    g().setLayoutMode('focus')
    const firstFocus = g().layoutMode === 'focus' && g().canvasOpen
    // 1) open a SECOND project tab (fresh slice, its own seeded terminal + dock)
    const secondId = g().newProject({ path: null, focus: true })
    await wait(160)
    const isSecondActive = g().activeProjectId === secondId
    const twoTabs = g().projectTabs.length === startTabs + 1
    const secondTerms = g().terminals.map((t) => t.id).sort().join()
    const initialSecondGrid = JSON.stringify(g().dockGrid)
    const layoutIndependent = firstFocus && g().layoutMode === 'studio'
    // Every control must make a visible, coherent state transition — no open
    // boolean with an empty grid, and no hidden canvas bit under Focus.
    g().setDock(true)
    const showSessionsWorks = g().layoutMode === 'studio' && g().dockOpen && g().dockViews.length > 0
    g().setLayoutMode('focus')
    g().toggleCanvas()
    const hideFilesWorks = g().layoutMode === 'studio' && !g().canvasOpen && g().dockOpen && g().dockViews.length > 0
    g().toggleCanvas()
    const showFilesWorks = g().layoutMode === 'studio' && g().canvasOpen
    g().setDock(false)
    g().setLayoutMode('studio')
    const studioWorks = g().layoutMode === 'studio' && g().canvasOpen && g().dockOpen && g().dockViews.length > 0
    const secondGrid = JSON.stringify(g().dockGrid)
    // isolation: the tabs have DIFFERENT terminal ids and dock grids, and the
    // outgoing first slice is parked intact
    const termsDiffer = !!secondTerms && !!firstTerms && secondTerms !== firstTerms
    const gridsDiffer = initialSecondGrid !== firstGrid
    const parkedFirst = g().projectSlices[firstId]
    const parkedFirstOk = !!parkedFirst && parkedFirst.terminals.map((t) => t.id).sort().join() === firstTerms
    // A live ACP callback retains its origin pid. While tab two is active, its
    // runtime write must land in parked tab one and leave tab two untouched.
    const firstThread = parkedFirst?.assistantThreads?.[0]?.id
    if (firstThread) g().updateAssistantRuntime(firstThread, () => ({ first: false, turns: [{ kind: 'assistant', text: 'origin-routed', at: 2 }] }), firstId)
    const runtimeRouted = !!firstThread && g().projectSlices[firstId]?.assistantRuntimes?.[firstThread]?.turns?.[0]?.text === 'origin-routed'
    const activeRuntimeUntouched = !!firstThread && !g().assistantRuntimes[firstThread]
    // 2) switch back to the first tab — live fields restored, second parked
    g().switchProject(firstId)
    await wait(160)
    const backToFirst = g().activeProjectId === firstId
    const focusRestored = g().layoutMode === 'focus' && g().canvasOpen
    const firstRestored = g().terminals.map((t) => t.id).sort().join() === firstTerms && JSON.stringify(g().dockGrid) === firstGrid
    const parkedSecond = g().projectSlices[secondId]
    const parkedSecondOk = !!parkedSecond && parkedSecond.terminals.map((t) => t.id).sort().join() === secondTerms
    // Restore the first tab's ordinary Studio layout for downstream probes.
    g().setLayoutMode('studio')
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
    const adaptiveSingle = !!document.querySelector('.tabstrip[data-single="true"] .ptab')
    return {
      twoTabs, isSecondActive, termsDiffer, gridsDiffer, parkedFirstOk, runtimeRouted, activeRuntimeUntouched,
      layoutIndependent, showSessionsWorks, hideFilesWorks, showFilesWorks, studioWorks, focusRestored,
      backToFirst, firstRestored, parkedSecondOk,
      domTwoTabs, domActiveOne,
      closedGone, stackHas, reopened, reopenedTermsOk, reopenedGridOk, backToSingle, adaptiveSingle,
    }
  })()`)
  console.log('PROJTABS=' + JSON.stringify(projtabs))

  // Warm project switching stays a small in-memory pointer swap: persistence
  // shaping is postponed to browser idle time and the previous file session is
  // restored from its small LRU rather than cold-reading every open file.
  const projectSwitchPerf = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const original = g().activeProjectId
    const hadFile = !!document.querySelector('.fx-tab[data-active="true"]')
    const other = g().newProject({ path: null, focus: false })
    const switchOnce = async (id) => {
      const started = performance.now()
      g().switchProject(id)
      const syncMs = performance.now() - started
      const loopStarted = performance.now()
      await new Promise((resolve) => setTimeout(resolve, 0))
      return { syncMs, loopMs: performance.now() - loopStarted }
    }
    const away = await switchOnce(other)
    const back = await switchOnce(original)
    await new Promise((resolve) => setTimeout(resolve, 80))
    const warmFiles = !hadFile || !document.querySelector('.canvas .fx-loading')
    g().closeProject(other, { force: true })
    return {
      syncMs: Math.max(away.syncMs, back.syncMs),
      loopMs: Math.max(away.loopMs, back.loopMs),
      responsive: Math.max(away.syncMs, back.syncMs) < 120 && Math.max(away.loopMs, back.loopMs) < 250,
      warmFiles,
      restored: g().activeProjectId === original,
    }
  })()`)
  console.log('PROJECT_SWITCH_PERF=' + JSON.stringify(projectSwitchPerf))

  // 13e-iii) tear-off + recombine: appearance/drafts travel to the hidden new
  //           window, then the same project and PTYs merge back into the
  //           original strip and the empty detached shell closes.
  const windowsBeforeDetach = BrowserWindow.getAllWindows().length
  const detachInfo = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const prefs = {
      themeMode: g().themeMode, perfMode: g().perfMode, termBackground: g().termBackground,
      fileTextZoom: g().fileTextZoom, termFontSize: g().termFontSize, termFontFamily: g().termFontFamily,
      termFontWeight: g().termFontWeight, termCursorColor: g().termCursorColor, wallpaperTint: g().wallpaperTint,
    }
    g().setThemeMode('dark')
    g().setPerfMode('eco')
    g().setTermBackground('paper')
    g().setFileTextZoom(1.37)
    g().setTermFontSize(17)
    g().setTermFontFamily('SF Mono')
    g().setTermFontWeight(700)
    g().setTermCursorColor('#6f5cff')
    g().setWallpaperTint(false)
    const before = g().projectTabs.length
    const pid = g().newProject({ path: null, focus: true })
    await new Promise((r) => setTimeout(r, 250))
    const movedTermIds = g().terminals.map((t) => t.id)
    if (movedTermIds[0]) g().setTermDraft(movedTermIds[0], 'detach-smoke-draft')
    if (movedTermIds[0]) await window.kaisola.terminal.create(movedTermIds[0], undefined, 80, 24, pid)
    await new Promise((r) => setTimeout(r, 80))
    const diagnosticsBefore = await window.kaisola.terminal.diagnostics(pid)
    await g().detachProjectToWindow(pid)
    await new Promise((r) => setTimeout(r, 200))
    return { pid, prefs, movedTermIds, diagnosticsBefore, srcTabsAfter: g().projectTabs.length, srcStillHasIt: g().projectTabs.some((t) => t.id === pid), srcTabsBefore: before }
  })()`)
  const windetach = {
    spawned: false,
    adopted: false,
    termsMoved: false,
    globalsMoved: false,
    styleApplied: false,
    draftMoved: false,
    srcDropped: detachInfo.srcTabsAfter === detachInfo.srcTabsBefore && !detachInfo.srcStillHasIt,
    recombined: false,
    insertedAtDrop: false,
    termsSame: false,
    pidsSame: false,
    pidDebug: null,
    sourceClosed: false,
    targetReused: false,
    windowCountRestored: false,
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
          return {
            tabIds: s.projectTabs.map((t) => t.id), active: s.activeProjectId, termIds: s.terminals.map((t) => t.id),
            theme: s.theme, themeMode: s.themeMode, perfMode: s.perfMode, termBackground: s.termBackground,
            fileTextZoom: s.fileTextZoom, termFontSize: s.termFontSize, termFontFamily: s.termFontFamily,
            termFontWeight: s.termFontWeight, termCursorColor: s.termCursorColor, wallpaperTint: s.wallpaperTint,
            datasets: { theme: document.documentElement.dataset.theme, perf: document.documentElement.dataset.perf, termbg: document.documentElement.dataset.termbg },
            draft: s.termDrafts[${JSON.stringify(detachInfo.movedTermIds[0] || '')}],
          }
        })()`).catch(() => null)
        if (probe && probe.tabIds.includes(detachInfo.pid)) break
        await new Promise((r) => setTimeout(r, 300))
      }
      windetach.adopted = !!probe && probe.tabIds.includes(detachInfo.pid) && probe.active === detachInfo.pid
      windetach.termsMoved = !!probe && detachInfo.movedTermIds.every((id) => probe.termIds.includes(id))
      windetach.globalsMoved = !!probe && probe.theme === 'dark' && probe.themeMode === 'dark' && probe.perfMode === 'eco' && probe.termBackground === 'paper' &&
        probe.fileTextZoom === 1.37 && probe.termFontSize === 17 && probe.termFontFamily === 'SF Mono' && probe.termFontWeight === 700 &&
        probe.termCursorColor === '#6f5cff' && probe.wallpaperTint === false
      windetach.styleApplied = !!probe && probe.datasets.theme === 'dark' && probe.datasets.perf === 'eco' && probe.datasets.termbg === 'paper'
      windetach.draftMoved = !!probe && probe.draft === 'detach-smoke-draft'

      const adoptWcId = adoptWin.webContents.id
      const firstTabLeft = await win.webContents.executeJavaScript(`document.querySelector('.ptab')?.getBoundingClientRect().left ?? 180`)
      await adoptWin.webContents.executeJavaScript(`window.__kaisola.getState().detachProjectToWindow(${JSON.stringify(detachInfo.pid)}, { x: ${Math.round(win.getBounds().x)} + ${Number(firstTabLeft) + 2}, y: ${Math.round(win.getBounds().y)} + 20 })`).catch(() => null)
      const t3 = Date.now()
      while (Date.now() - t3 < 15000 && !adoptWin.isDestroyed()) await new Promise((r) => setTimeout(r, 120))
      windetach.sourceClosed = adoptWin.isDestroyed()
      let merged = null
      const t4 = Date.now()
      while (Date.now() - t4 < 15000) {
        merged = await win.webContents.executeJavaScript(`(async () => {
          const s = window.__kaisola.getState()
          return { tabIds: s.projectTabs.map((t) => t.id), active: s.activeProjectId, termIds: s.terminals.map((t) => t.id), draft: s.termDrafts[${JSON.stringify(detachInfo.movedTermIds[0] || '')}], diagnostics: await window.kaisola.terminal.diagnostics(s.activeProjectId) }
        })()`).catch(() => null)
        if (merged?.tabIds?.includes(detachInfo.pid)) break
        await new Promise((r) => setTimeout(r, 150))
      }
      windetach.recombined = !!merged && merged.tabIds.filter((id) => id === detachInfo.pid).length === 1 && merged.active === detachInfo.pid && merged.draft === 'detach-smoke-draft'
      windetach.insertedAtDrop = !!merged && merged.tabIds[0] === detachInfo.pid
      windetach.termsSame = !!merged && detachInfo.movedTermIds.length === merged.termIds.length && detachInfo.movedTermIds.every((id) => merged.termIds.filter((x) => x === id).length === 1)
      const beforePids = Object.fromEntries((detachInfo.diagnosticsBefore ?? []).filter((d) => detachInfo.movedTermIds.includes(d.id)).map((d) => [d.id, d.pid]))
      windetach.pidDebug = { before: beforePids, after: (merged?.diagnostics ?? []).filter((d) => detachInfo.movedTermIds.includes(d.id)).map((d) => ({ id: d.id, pid: d.pid, exited: d.exited })) }
      windetach.pidsSame = !!merged && detachInfo.movedTermIds.every((id) => {
        const after = (merged.diagnostics ?? []).find((d) => d.id === id)
        return !!after && !after.exited && (!beforePids[id] || after.pid === beforePids[id])
      })
      windetach.targetReused = !BrowserWindow.getAllWindows().some((w) => !w.isDestroyed() && w.webContents.id === adoptWcId) && BrowserWindow.getAllWindows().includes(win)
      windetach.windowCountRestored = BrowserWindow.getAllWindows().length === windowsBeforeDetach

      // Restore source preferences and a single project for downstream groups.
      await win.webContents.executeJavaScript(`(async () => {
        const g = () => window.__kaisola.getState()
        const p = ${JSON.stringify(detachInfo.prefs)}
        g().setThemeMode(p.themeMode); g().setPerfMode(p.perfMode); g().setTermBackground(p.termBackground)
        g().setFileTextZoom(p.fileTextZoom); g().setTermFontSize(p.termFontSize); g().setTermFontFamily(p.termFontFamily)
        g().setTermFontWeight(p.termFontWeight); g().setTermCursorColor(p.termCursorColor); g().setWallpaperTint(p.wallpaperTint)
        g().closeProject(${JSON.stringify(detachInfo.pid)}, { force: true })
        await new Promise((r) => setTimeout(r, 180))
      })()`)
    }
  }
  console.log('WINDETACH=' + JSON.stringify(windetach))

  // 13f) the two-pane figure on each session TAB toggles its CARD — press to
  //      put the card away (the session stays alive), press again to bring it
  //      back; putting away the last card hides the whole work area
  const toggle = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const a1 = get().assistantThreads[0].id
    get().setDockView(a1)
    await new Promise((r) => setTimeout(r, 300))
    const fig = () => {
      const tab = document.querySelector('.stab[data-sid="' + a1 + '"]')
      return tab ? tab.querySelector('.stab-split') : null
    }
    if (!fig()) return { hasFig: false }
    // while its pane is up the figure stays visible (accent, data-on)
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
    const rowShows = [...document.querySelectorAll('.stabs .stab')].some((r) => (r.textContent || '').includes('Investigate flaky'))
    get().autoNameThread(tid, 'a totally different topic now')
    const sticky = !!th().autoName && th().autoName.startsWith('Investigate')
    get().renameAssistantThread(tid, 'Parser deep-dive')
    await new Promise((r) => setTimeout(r, 100))
    const manualWins = [...document.querySelectorAll('.stabs .stab')].some((r) => (r.textContent || '').includes('Parser deep-dive'))
    get().requestTerminal('echo train-model-v2')
    await new Promise((r) => setTimeout(r, 120))
    const term = get().terminals[get().terminals.length - 1]
    const termNamed = !!term.autoName && term.autoName.startsWith('Echo train-model-v2')
    get().closeAssistantThread(tid)
    get().closeTerminal(term.id)
    return { named, rowShows, sticky, manualWins, termNamed }
  })()`)
  console.log('AUTONAME=' + JSON.stringify(autoname))

  // 14) the old workflow sidebar is hidden; only the focused sessions/files
  //     sidebars remain.
  const minimalUi = await win.webContents.executeJavaScript(`(async () => {
    await new Promise((r) => setTimeout(r, 120))
    return {
      noSidebar: !document.querySelector('.sidebar'),
      noSidebarResize: !document.querySelector('.sidebar-resize'),
      noStageNav: document.querySelectorAll('.side-nav-item').length === 0,
      hasSessionSidebar: !!document.querySelector('.session-sidebar'),
      hasRail: !!document.querySelector('.wsrail'),
      filesOnRight: !!document.querySelector('.app-body > .wsrail[data-side="right"]'),
      hasPlus: !!document.querySelector('.stabs .drop-btn'),
      hasFiles: !!document.querySelector('.wsrail-files'),
    }
  })()`)
  console.log('MINIMAL_UI=' + JSON.stringify(minimalUi))

  // 14b) project/session hierarchy is user-selectable and switches in place.
  //      Every treatment keeps the same terminal/thread identities and drafts;
  //      even Compact moves the one existing session row rather than cloning it.
  const tabLayouts = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const wait = () => new Promise((r) => setTimeout(r, 45))
    const project = document.querySelector('.ptab[data-active="true"]')
    if (!project) return { rendered: false }
    const original = get().tabLayout
    const termIds = get().terminals.map((t) => t.id).join('|')
    const threadIds = get().assistantThreads.map((t) => t.id).join('|')
    const active = get().activeThreadId
    get().setAssistantDraft(active, { text: 'layout-switch-draft' })
    const inspect = () => {
      const shelf = document.querySelector('.stabs')
      const marker = shelf?.querySelector('.stabs-project-anchor')
      const session = shelf?.querySelector('.stab[data-active="true"]') || shelf?.querySelector('.stab')
      const style = shelf ? getComputedStyle(shelf) : null
      return { shelf, marker, session, style }
    }
    get().setTabLayout('sidebar'); await wait()
    const sidebar = inspect()
    const sidebarOk = document.querySelectorAll('.stabs').length === 1 &&
      !!document.querySelector('.session-sidebar > .stabs[aria-orientation="vertical"]') &&
      !document.querySelector('.dock-col > .stabs') &&
      !!document.querySelector('.app-body > .wsrail[data-side="right"]') && !!sidebar.session

    get().setTabLayout('shelf'); await wait()
    const shelf = inspect()
    const shelfOk = !!shelf.shelf && !!shelf.marker && shelf.marker.getBoundingClientRect().width >= 16 &&
      getComputedStyle(project, '::after').display !== 'none' && shelf.style.borderTopWidth !== '0px'

    get().setTabLayout('bare'); await wait()
    const bare = inspect()
    const bareOk = document.documentElement.dataset.tabLayout === 'bare' && !!bare.shelf &&
      getComputedStyle(project, '::after').display === 'none' && getComputedStyle(bare.marker).display === 'none' &&
      bare.style.borderTopWidth === '0px' && bare.style.backgroundImage === 'none'

    get().setTabLayout('runway'); await wait()
    const runway = inspect()
    const runwayOk = !!runway.shelf && runway.style.backgroundColor !== 'rgba(0, 0, 0, 0)' &&
      runway.style.backgroundColor !== 'transparent' && getComputedStyle(runway.marker).display === 'none'

    get().setTabLayout('flat'); await wait()
    const flat = inspect()
    const flatSession = flat.session && getComputedStyle(flat.session)
    const flatOk = document.documentElement.dataset.tabLayout === 'flat' && !!flatSession &&
      Number.parseInt(flatSession.fontWeight, 10) >= 600 && flatSession.boxShadow === 'none' &&
      getComputedStyle(flat.marker).display === 'none'

    get().setTabLayout('compact'); await wait()
    const compact = inspect()
    const compactOk = document.querySelectorAll('.stabs').length === 1 &&
      !!document.querySelector('.compact-session-slot > .stabs') && !document.querySelector('.dock-col > .stabs') &&
      !!compact.session

    get().setTabLayout('bare'); await wait()
    const toSidebar = document.querySelector('.stabs-sidebar-toggle')
    const sidebarActionClear = /left sidebar/i.test(toSidebar?.getAttribute('aria-label') || toSidebar?.getAttribute('title') || '')
    toSidebar?.click(); await wait()
    const verticalTabs = document.querySelector('.session-sidebar > .stabs[aria-orientation="vertical"]')
    const verticalTrack = verticalTabs?.querySelector(':scope > .stabs-track')
    const verticalAdd = verticalTabs?.querySelector(':scope > .drop-btn')
    const addBelowLastTab = !!verticalTrack && verticalTrack.nextElementSibling === verticalAdd
    verticalAdd?.click(); await wait()
    const addMenu = document.querySelector('.drop-menu')
    const addRect = verticalAdd?.getBoundingClientRect()
    const menuRect = addMenu?.getBoundingClientRect()
    const addOptionsBelow = !!addRect && !!menuRect && menuRect.top >= addRect.bottom - 1
    verticalAdd?.click(); await wait()
    const movedToSidebar = get().tabLayout === 'sidebar' && !!verticalTabs
    const toTop = document.querySelector('.session-sidebar-head button')
    const topActionClear = /across the top/i.test(toTop?.getAttribute('aria-label') || toTop?.getAttribute('title') || '')
    toTop?.click(); await wait()
    const movedBackTop = get().tabLayout === 'bare' && !!document.querySelector('.stabs-sidebar-toggle')
    const reciprocalToggle = !!toSidebar && !!toTop && movedToSidebar && movedBackTop && sidebarActionClear && topActionClear
    const verticalAddFlow = addBelowLastTab && addOptionsBelow

    const stateKept = get().terminals.map((t) => t.id).join('|') === termIds &&
      get().assistantThreads.map((t) => t.id).join('|') === threadIds &&
      get().assistantDrafts[active]?.text === 'layout-switch-draft'
    const staticPaint = [sidebar, shelf, bare, runway, flat, compact].every((v) => !v.style?.backdropFilter || v.style.backdropFilter === 'none')
    const accessible = /sessions$/i.test(compact.shelf?.getAttribute('aria-label') || '') && sidebar.shelf?.getAttribute('aria-orientation') === 'vertical'
    const sessionIdentity = !!compact.session?.style.getPropertyValue('--sid').trim()
    get().setTabLayout(original); await wait()
    return { rendered: true, sidebarOk, shelfOk, bareOk, runwayOk, flatOk, compactOk, reciprocalToggle, verticalAddFlow, stateKept, staticPaint, accessible, sessionIdentity }
  })()`)
  console.log('TAB_LAYOUTS=' + JSON.stringify(tabLayouts))

  // 14b2) layout actions remain reversible and the structural switches stay
  //       in the same top-right slots regardless of panel visibility.
  const intuitiveLayoutControls = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const wait = () => new Promise((r) => setTimeout(r, 70))
    const originalLayout = get().tabLayout
    const originalMode = get().layoutMode
    const originalDock = get().dockOpen
    const originalRail = get().railOpen
    get().setTabLayout('sidebar')
    if (!get().railOpen) get().toggleRail()
    await wait()
    const permanentTopControls = document.querySelectorAll('.tabstrip-view-controls > button').length === 2
    const tree = document.querySelector('.wsrail[data-side="right"]')
    const topClose = document.querySelector('.tabstrip-view-controls [aria-label="Hide file tree"]')
    const noLocalClose = !!tree && !tree.querySelector('.wsrail-head button')
    const fileTreeIconOnly = !!topClose?.querySelector('svg') && !(topClose?.textContent || '').trim()
    topClose?.click(); await new Promise((r) => setTimeout(r, 300))
    const hidden = !document.querySelector('.wsrail') && get().railOpen === false
    const topRestore = document.querySelector('.tabstrip-view-controls [aria-label="Show file tree"]')
    const noFooterRecovery = !document.querySelector('.shell-sidebar-footer [aria-label="Show file tree"]')
    topRestore?.click(); await new Promise((r) => setTimeout(r, 300))
    const restored = !!document.querySelector('.wsrail[data-side="right"]') && get().railOpen === true

    const settingsTrigger = document.querySelector('.shell-settings-trigger')
    settingsTrigger?.click(); await wait()
    const startsInGeneral = /Appearance/.test(document.querySelector('.settings-pane')?.textContent || '')
    const interfaceNav = [...document.querySelectorAll('.settings-nav-item')].find((node) => /Interface/.test(node.textContent || ''))
    interfaceNav?.click()
    await wait()
    const settingsOwned = !!document.querySelector('.settings-row[data-setting="workspace-view"]') &&
      !!document.querySelector('.settings-row[data-setting="session-panels"]') &&
      !!document.querySelector('.settings-row[data-setting="session-placement"]')
    const advancedStylesDisclosed = !!document.querySelector('.settings-layout-advanced [data-setting="advanced-session-style"]')
    const choose = async (setting, label) => {
      document.querySelector('.settings-row[data-setting="' + setting + '"] .drop-btn')?.click()
      await wait()
      const option = [...document.querySelectorAll('.drop-menu .drop-item')].find((node) =>
        (node.textContent || '').trim().includes(label),
      )
      option?.click()
      await wait()
      return !!option
    }
    const toFilesOnly = await choose('workspace-view', 'Files only') && get().layoutMode === 'focus'
    const toFilesAndSessions = await choose('workspace-view', 'Files and sessions') && get().layoutMode === 'studio'
    const panelsHidden = await choose('session-panels', 'Hidden') && get().dockOpen === false
    const panelsShown = await choose('session-panels', 'Shown') && get().dockOpen === true
    const movedToTop = await choose('session-placement', 'Across top') && get().tabLayout === 'bare'
    const footerInFileTree = !!document.querySelector('.wsrail[data-side="left"] > .shell-sidebar-footer')
    const movedToLeft = await choose('session-placement', 'Left sidebar') && get().tabLayout === 'sidebar'
    const footerInSessions = !!document.querySelector('.session-sidebar > .shell-sidebar-footer')
    get().setSettingsOpen(false)
    await wait()
    get().openPalette('commands')
    await wait()
    const paletteText = document.querySelector('.palette')?.textContent || ''
    const rareActionsInPalette = /Place sessions on the left/.test(paletteText) && /Use compact session row/.test(paletteText) && /file tree/.test(paletteText)
    get().closePalette()
    await wait()

    get().setTabLayout(originalLayout)
    window.__kaisola.setState({ layoutMode: originalMode, dockOpen: originalDock })
    if (get().railOpen !== originalRail) get().toggleRail()
    await wait()
    return {
      permanentTopControls,
      fileTreeIconOnly,
      noLocalClose,
      hidden,
      topRestore: !!topRestore,
      restored,
      noFooterRecovery,
      noStandaloneLayout: !document.querySelector('.shell-layout-trigger'),
      settingsOwned,
      advancedStylesDisclosed,
      startsInGeneral,
      workspaceReversible: toFilesOnly && toFilesAndSessions,
      panelsReversible: panelsHidden && panelsShown,
      placementReversible: movedToTop && movedToLeft,
      footerFollowsNavigation: footerInFileTree && footerInSessions,
      rareActionsInPalette,
      previewPermanent: !!document.querySelector('.tabstrip-view-controls [aria-label$="file preview"]') &&
        !document.querySelector('.canvas-local-close, .file-preview-toggle'),
    }
  })()`)
  console.log('INTUITIVE_LAYOUT_CONTROLS=' + JSON.stringify(intuitiveLayoutControls))

  // A DOM element.click() bypasses Chromium's frameless-window hit regions.
  // Exercise Settings' layout dropdown with real pointer input so its portal
  // cannot be visible yet covered by a stale drag region.
  const pointerSetup = await win.webContents.executeJavaScript(`(async () => {
    const get = () => window.__kaisola.getState()
    const original = get().tabLayout
    get().setTabLayout('sidebar')
    await new Promise((r) => setTimeout(r, 70))
    document.querySelector('.shell-settings-trigger')?.click()
    await new Promise((r) => setTimeout(r, 70))
    ;[...document.querySelectorAll('.settings-nav-item')].find((node) => /Interface/.test(node.textContent || ''))?.click()
    await new Promise((r) => setTimeout(r, 70))
    document.querySelector('.settings-row[data-setting="session-placement"] .drop-btn')?.click()
    await new Promise((r) => setTimeout(r, 70))
    const action = [...document.querySelectorAll('.drop-menu .drop-item')].find((node) => /Across top/.test(node.textContent || ''))
    const rect = action?.getBoundingClientRect()
    return { original, rect: rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : null }
  })()`)
  const realPointerLayout = { firstWorked: false, reverseWorked: false, stayedInteractive: false }
  const pointerClick = async (point) => {
    win.webContents.sendInputEvent({ type: 'mouseDown', x: Math.round(point.x), y: Math.round(point.y), button: 'left', clickCount: 1 })
    win.webContents.sendInputEvent({ type: 'mouseUp', x: Math.round(point.x), y: Math.round(point.y), button: 'left', clickCount: 1 })
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  if (pointerSetup.rect) {
    await pointerClick(pointerSetup.rect)
    const afterFirst = await win.webContents.executeJavaScript(`(async () => {
      document.querySelector('.settings-row[data-setting="session-placement"] .drop-btn')?.click()
      await new Promise((r) => setTimeout(r, 70))
      const action = [...document.querySelectorAll('.drop-menu .drop-item')].find((node) => /Left sidebar/.test(node.textContent || ''))
      const rect = action?.getBoundingClientRect()
      return {
        worked: window.__kaisola.getState().tabLayout === 'bare',
        menu: !!document.querySelector('.drop-menu'),
        rect: rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : null,
      }
    })()`)
    realPointerLayout.firstWorked = afterFirst.worked
    realPointerLayout.stayedInteractive = afterFirst.menu
    if (afterFirst.rect) {
      await pointerClick(afterFirst.rect)
      realPointerLayout.reverseWorked = await win.webContents.executeJavaScript(`window.__kaisola.getState().tabLayout === 'sidebar'`)
    }
  }
  await win.webContents.executeJavaScript(`(async () => {
    window.__kaisola.getState().setTabLayout(${JSON.stringify(pointerSetup.original)})
    window.__kaisola.getState().setSettingsOpen(false)
    await new Promise((r) => setTimeout(r, 50))
  })()`)
  console.log('REAL_POINTER_LAYOUT=' + JSON.stringify(realPointerLayout))

  // 14c) a narrow agent card wraps its composer and identity controls instead
  //      of clipping the model picker or send/connection actions.
  const narrowAgentUi = await win.webContents.executeJavaScript(`(async () => {
    const assistant = document.querySelector('.assistant')
    const card = assistant?.closest('.session-card')
    if (!assistant || !card) return { rendered: false }
    const state = window.__kaisola.getState()
    const threadId = assistant.getAttribute('data-thread-id')
    const originalDraft = threadId ? state.assistantDrafts[threadId] : null
    const longDraft = 'This narrow composer must keep every word readable and scrollable after the card moves to the right. '.repeat(18)
    if (threadId) state.setAssistantDraft(threadId, { text: longDraft })
    const originalStyle = card.getAttribute('style') || ''
    card.style.width = '340px'
    card.style.maxWidth = '340px'
    card.style.justifySelf = 'start'
    await new Promise((r) => setTimeout(r, 80))
    const composer = assistant.querySelector('.composer')
    const input = assistant.querySelector('.composer-input')
    const bar = assistant.querySelector('.composer-bar')
    const send = assistant.querySelector('.composer-send')
    const foot = assistant.querySelector('.assistant-foot')
    const conn = assistant.querySelector('.foot-conn')
    const within = (child, parent) => {
      if (!child || !parent) return false
      const c = child.getBoundingClientRect()
      const p = parent.getBoundingClientRect()
      return c.left >= p.left - 1 && c.right <= p.right + 1
    }
    const inputStyle = input ? getComputedStyle(input) : null
    const leftHeight = input?.clientHeight ?? 0
    card.style.justifySelf = 'end'
    await new Promise((r) => setTimeout(r, 60))
    const sideAgnostic = !!input && input.value === longDraft && input.clientHeight === leftHeight
    const result = {
      rendered: true,
      narrow: assistant.getBoundingClientRect().width <= 342,
      containerAware: getComputedStyle(assistant).containerType === 'inline-size',
      composerFits: !!bar && bar.scrollWidth <= bar.clientWidth + 1,
      sendVisible: within(send, composer),
      footerFits: !!foot && foot.scrollWidth <= foot.clientWidth + 1 && within(conn, foot),
      wraps: !!bar && getComputedStyle(bar).flexWrap === 'wrap',
      draftReadable: !!input && input.value === longDraft && input.clientHeight >= 100,
      draftScrollable: !!input && !!inputStyle && /auto|scroll/.test(inputStyle.overflowY) && input.scrollHeight >= input.clientHeight,
      draftResponsive: !!inputStyle && inputStyle.fieldSizing === 'content',
      sideAgnostic,
    }
    if (threadId) state.setAssistantDraft(threadId, originalDraft ?? { text: '', attachments: [], mentions: [], speed: 'default' })
    card.setAttribute('style', originalStyle)
    await new Promise((r) => setTimeout(r, 45))
    return result
  })()`)
  console.log('NARROW_AGENT_UI=' + JSON.stringify(narrowAgentUi))

  // 14d) the inbox stays anchored even at zero, then gains/loses only its
  //      badge as attention arrives and is cleared.
  const inboxAnchorUi = await win.webContents.executeJavaScript(`(async () => {
    const st = window.__kaisola.getState()
    const saved = { inbox: st.inbox, needsYou: st.needsYou, projectTabs: st.projectTabs, projectSlices: st.projectSlices }
    st.setInbox(true)
    window.__kaisola.setState({
      needsYou: {},
      projectTabs: st.projectTabs.map((tab) => ({ ...tab, activity: tab.activity === 'needs-you' || tab.activity === 'failed' ? undefined : tab.activity })),
      projectSlices: Object.fromEntries(Object.entries(st.projectSlices).map(([id, slice]) => [id, slice ? { ...slice, needsYou: {} } : slice])),
    })
    await new Promise((r) => setTimeout(r, 80))
    const zeroButton = document.querySelector('.shell-sidebar-footer .inbox-btn')
    const anchoredAtZero = !!zeroButton && !zeroButton.querySelector('.inbox-count')
    const sessionId = window.__kaisola.getState().activeThreadId
    if (sessionId) window.__kaisola.getState().markNeedsYou(sessionId)
    await new Promise((r) => setTimeout(r, 80))
    const activeButton = document.querySelector('.shell-sidebar-footer .inbox-btn')
    const badged = !!activeButton?.querySelector('.inbox-count')
    window.__kaisola.getState().clearInbox()
    await new Promise((r) => setTimeout(r, 80))
    const clearedButton = document.querySelector('.shell-sidebar-footer .inbox-btn')
    const staysAfterClear = !!clearedButton && !clearedButton.querySelector('.inbox-count')
    window.__kaisola.setState(saved)
    if (!saved.inbox) window.__kaisola.getState().setInbox(false)
    return { anchoredAtZero, badged, staysAfterClear }
  })()`)
  console.log('INBOX_ANCHOR_UI=' + JSON.stringify(inboxAnchorUi))

  // 15) settings exposes the appearance/layout configuration
  const settings = await win.webContents.executeJavaScript(`(async () => {
    const settingsButton = document.querySelector('.shell-sidebar-footer .shell-settings-trigger[aria-label="Open settings"]')
    settingsButton?.click()
    await new Promise((r) => setTimeout(r, 150))
    // Zed-style settings: a nav of categories, one pane at a time
    const navNames = [...document.querySelectorAll('.settings-nav-item')].map((e) => e.textContent || '')
    const startsInGeneral = /Appearance/.test(document.querySelector('.settings-pane')?.textContent || '')
    const hasAppearance = navNames.some((l) => /General/.test(l))
    const usageNav = [...document.querySelectorAll('.settings-nav-item')].find((e) => /Usage/.test(e.textContent || ''))
    usageNav?.click()
    await new Promise((r) => setTimeout(r, 50))
    const hasUsage = !!document.querySelector('.settings-usage') && /Codex/.test(document.querySelector('.settings-pane')?.textContent || '') && /Claude/.test(document.querySelector('.settings-pane')?.textContent || '')
    const advancedNav = [...document.querySelectorAll('.settings-nav-item')].find((e) => /Advanced/.test(e.textContent || ''))
    advancedNav?.click()
    await new Promise((r) => setTimeout(r, 50))
    const hasDiskResidency = /Hidden terminal renderers/.test(document.querySelector('.settings-pane')?.textContent || '') && /settings\.json/.test(document.querySelector('.settings-pane')?.textContent || '')
    const interfaceNav = [...document.querySelectorAll('.settings-nav-item')].find((e) => /Interface/.test(e.textContent || ''))
    interfaceNav?.click()
    await new Promise((r) => setTimeout(r, 50))
    const hasLayoutSettings = !!document.querySelector('[data-setting="workspace-view"]') && !!document.querySelector('[data-setting="session-panels"]') && !!document.querySelector('[data-setting="session-placement"]')
    const hasAdvancedStyles = !!document.querySelector('.settings-layout-advanced [data-setting="advanced-session-style"]')
    const hasTabLayout = /Session placement/.test(document.querySelector('.settings-pane')?.textContent || '')
    const extensionsNav = [...document.querySelectorAll('.settings-nav-item')].find((e) => /Extensions/.test(e.textContent || ''))
    extensionsNav?.click()
    await new Promise((r) => setTimeout(r, 40))
    const extensionsInSettings = /Open Extensions/.test(document.querySelector('.settings-pane')?.textContent || '')
    const generalNav = [...document.querySelectorAll('.settings-nav-item')].find((e) => /General/.test(e.textContent || ''))
    generalNav?.click()
    await new Promise((r) => setTimeout(r, 30))
    const hasSidebarControls = /Sidebar/.test(document.querySelector('.settings-panel-v2')?.textContent || '')
    const dropdown = document.querySelector('.settings-pane .drop-btn')
    dropdown?.click()
    await new Promise((r) => setTimeout(r, 50))
    const previewOpened = !!document.querySelector('.drop-menu')
    document.querySelector('.settings-pane-head')?.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 50))
    const previewDismissed = !document.querySelector('.drop-menu')
    window.__kaisola.getState().setSettingsOpen(false)
    await new Promise((r) => setTimeout(r, 30))
    const permanentFilesControls = document.querySelectorAll('.tabstrip-view-controls > button').length === 2 &&
      !document.querySelector('.canvas-local-close, .file-preview-toggle, .wsrail-head button')
    const footerOwned = !!settingsButton && !document.querySelector('.tabstrip .shell-settings-trigger')
    return { settingsSeparate: !!settingsButton, footerOwned, startsInGeneral, hasLayoutSettings, hasAdvancedStyles, noStandaloneLayout: !document.querySelector('.shell-layout-trigger'), hasAppearance, hasUsage, hasDiskResidency, hasTabLayout, extensionsInSettings, permanentFilesControls, noSidebarControls: !hasSidebarControls, previewOpened, previewDismissed }
  })()`)
  console.log('SETTINGS=' + JSON.stringify(settings))

  // 15b) Extensions is a real full-screen browser; bundled installs hot-load
  //      preview contributions and persist their authoritative main record.
  const extensionsUi = await win.webContents.executeJavaScript(`(async () => {
    window.dispatchEvent(new CustomEvent('kaisola:extensions-open'))
    await new Promise((r) => setTimeout(r, 180))
    const surface = document.querySelector('.extensions-surface')
    const cards = [...document.querySelectorAll('.ext-card')]
    const hasFilters = !!document.querySelector('.extensions-status') && !!document.querySelector('.extensions-categories')
    const install = async (name) => {
      const card = [...document.querySelectorAll('.ext-card')].find((node) => node.querySelector('h2')?.textContent === name)
      const button = card && [...card.querySelectorAll('button')].find((node) => /Install/.test(node.textContent || ''))
      button?.click()
      await new Promise((r) => setTimeout(r, 120))
      return !!card && /Uninstall/.test(card.textContent || '')
    }
    const csvInstalled = await install('CSV Table Preview')
    const jsonInstalled = await install('JSON Tree Preview')
    const htmlCard = [...document.querySelectorAll('.ext-card')].find((node) => node.querySelector('h2')?.textContent === 'HTML')
    const htmlUninstall = htmlCard && [...htmlCard.querySelectorAll('button')].find((node) => node.textContent?.trim() === 'Uninstall')
    htmlUninstall?.click()
    await new Promise((r) => setTimeout(r, 120))
    const mainState = await window.kaisola.extensions.state()
    const defaultUninstallPersisted = mainState.installed?.['kaisola.html']?.enabled === false
    document.querySelector('.extensions-head-actions .btn-icon')?.click()
    const st = window.__kaisola.getState()
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'table.csv'))}, undefined, { pinned: true })
    await new Promise((r) => setTimeout(r, 220))
    const csvPreview = !!document.querySelector('.fx-doc-table table') && /Ada/.test(document.querySelector('.fx-doc-table')?.textContent || '')
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'tree.json'))}, undefined, { pinned: true })
    await new Promise((r) => setTimeout(r, 220))
    const jsonPreview = !!document.querySelector('.fx-json-tree') && /Kaisola/.test(document.querySelector('.fx-json-tree')?.textContent || '')
    st.requestFile(${JSON.stringify(path.join(fileUiRoot, 'tree-wide.json'))}, undefined, { pinned: true })
    await new Promise((r) => setTimeout(r, 320))
    const jsonNodeCount = document.querySelectorAll('.fx-json-node,.fx-json-leaf').length
    const boundedJsonPreview = jsonNodeCount > 0 && jsonNodeCount <= 5000 && /Preview capped/.test(document.querySelector('.fx-doc-json')?.textContent || '')
    return {
      opened: !!surface,
      cards: cards.length,
      hasFilters,
      csvInstalled,
      jsonInstalled,
      persisted: !!mainState.installed?.['kaisola.csv-preview'] && !!mainState.installed?.['kaisola.json-preview'],
      defaultUninstallPersisted,
      csvPreview,
      jsonPreview,
      boundedJsonPreview,
      jsonNodeCount,
      closed: !document.querySelector('.extensions-surface'),
    }
  })()`)
  console.log('EXTENSIONS=' + JSON.stringify(extensionsUi))

  const devExtensionRoot = path.join(os.tmpdir(), 'kaisola-dev-extension-smoke')
  fsx.rmSync(devExtensionRoot, { recursive: true, force: true })
  fsx.mkdirSync(devExtensionRoot, { recursive: true })
  const devManifestPath = path.join(devExtensionRoot, 'kaisola-extension.json')
  const devManifest = (version, name) => ({
    id: 'smoke.hot-reload', name, version, description: 'Smoke-only extension', author: 'Kaisola smoke',
    contributions: { languages: [{ id: 'probe', name: 'Probe', extensions: ['probe'], grammar: { lineComments: ['#'] } }] },
  })
  fsx.writeFileSync(devManifestPath, JSON.stringify(devManifest('1.0.0', 'Hot Reload Extension')))
  const devRegistered = await win.webContents.executeJavaScript(`window.kaisola.extensions.registerDev(${JSON.stringify(devExtensionRoot)})`)
  const devManifestTemp = `${devManifestPath}.tmp`
  fsx.writeFileSync(devManifestTemp, JSON.stringify(devManifest('1.1.0', 'Hot Reloaded Extension')))
  fsx.renameSync(devManifestTemp, devManifestPath)
  await new Promise((r) => setTimeout(r, 420))
  const devExtensionHotReload = await win.webContents.executeJavaScript(`(async () => {
    const state = await window.kaisola.extensions.state()
    window.dispatchEvent(new CustomEvent('kaisola:extensions-open'))
    await new Promise((r) => setTimeout(r, 160))
    const visible = [...document.querySelectorAll('.ext-card h2')].some((node) => node.textContent === 'Hot Reloaded Extension')
    window.dispatchEvent(new CustomEvent('kaisola:extensions-open:close'))
    const current = state.development?.find((item) => item.id === 'smoke.hot-reload')
    await window.kaisola.extensions.removeDev('smoke.hot-reload')
    return { registered: !!${JSON.stringify(!!devRegistered?.ok)}, updated: current?.version === '1.1.0', visible }
  })()`)
  fsx.rmSync(devExtensionRoot, { recursive: true, force: true })
  console.log('DEV_EXTENSION_HOT_RELOAD=' + JSON.stringify(devExtensionHotReload))

  // 15c) MCP handoff files are private/atomic and retain ${VAR} references.
  //      A stdio entry avoids network activity while exercising the same
  //      generated Claude config path used by real catalog servers.
  process.env.KAISOLA_SMOKE_MCP_TOKEN = 'must-never-land-on-disk'
  const mcpConfigSecurity = await win.webContents.executeJavaScript(`(async () => {
    const added = await window.kaisola.mcp.serverAdd('smoke-private', {
      command: 'node', args: ['server.js'], env: { API_TOKEN: '\${KAISOLA_SMOKE_MCP_TOKEN}' },
    })
    await new Promise((r) => setTimeout(r, 80))
    const state = window.__kaisola.getState()
    const info = await window.kaisola.mcp.info({ projectId: state.activeProjectId, workspace: state.workspacePath })
    return { added: !!added?.ok, running: !!info?.ok, tools: info?.toolCount, configPath: info?.configPath }
  })()`)
  const generatedMcpPath = typeof mcpConfigSecurity.configPath === 'string'
    && path.dirname(mcpConfigSecurity.configPath) === SMOKE_USERDATA
    && /^kaisola-mcp-[0-9a-f]{24}\.json$/.test(path.basename(mcpConfigSecurity.configPath))
    ? mcpConfigSecurity.configPath
    : path.join(SMOKE_USERDATA, 'missing-mcp-config.json')
  const generatedMcp = fsx.existsSync(generatedMcpPath) ? fsx.readFileSync(generatedMcpPath, 'utf8') : ''
  mcpConfigSecurity.private = !!generatedMcp && (fsx.statSync(generatedMcpPath).mode & 0o777) === 0o600
  mcpConfigSecurity.placeholder = generatedMcp.includes('${KAISOLA_SMOKE_MCP_TOKEN}')
  mcpConfigSecurity.notExpanded = !generatedMcp.includes(process.env.KAISOLA_SMOKE_MCP_TOKEN)
  try {
    const builtin = JSON.parse(generatedMcp).mcpServers.kaisola
    const rpc = async (method, params) => {
      const response = await fetch(builtin.url, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...builtin.headers },
        body: JSON.stringify({ jsonrpc: '2.0', id: method, method, ...(params ? { params } : {}) }),
      })
      return response.json()
    }
    const initialized = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'smoke', version: '1' } })
    const resources = await rpc('resources/list')
    const prompts = await rpc('prompts/list')
    mcpConfigSecurity.resources = resources?.result?.resources?.length ?? 0
    mcpConfigSecurity.prompts = prompts?.result?.prompts?.length ?? 0
    mcpConfigSecurity.fullSurface = !!initialized?.result?.capabilities?.resources && !!initialized?.result?.capabilities?.prompts
    const gated = await rpc('tools/call', {
      name: 'hypothesis_propose',
      arguments: { title: 'MCP scope smoke', claim: 'This must remain pending until reviewed.', from: 'smoke' },
    })
    await new Promise((r) => setTimeout(r, 80))
    const routed = await win.webContents.executeJavaScript(`(() => {
      const state = window.__kaisola.getState()
      const proposal = state.project.proposals.find((item) => item.title === 'Hypothesis: MCP scope smoke')
      const applied = state.project.hypotheses.some((item) => item.title === 'MCP scope smoke')
      if (proposal) state.rejectProposal(proposal.id)
      return { pending: proposal?.status === 'pending', applied }
    })()`)
    mcpConfigSecurity.proposalGated = gated?.result?.structuredContent?.status === 'pending_human_review' && routed.pending && !routed.applied
    const denied = await fetch(builtin.url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${'0'.repeat(64)}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: 'denied', method: 'ping' }),
    })
    mcpConfigSecurity.badBearerDenied = denied.status === 401
  } catch { mcpConfigSecurity.fullSurface = false }
  await win.webContents.executeJavaScript(`window.kaisola.mcp.serverRemove('smoke-private')`)
  console.log('MCP_CONFIG_SECURITY=' + JSON.stringify(mcpConfigSecurity))

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
    // Zed-style settings: ten focused categories (including Extensions),
    // exactly one active, no accordion folds left.
    const tabsOk = document.querySelectorAll('.settings-fold').length === 0 &&
      document.querySelectorAll('.settings-nav-item').length === 10 &&
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
    const btn = document.querySelector('.stabs .drop-btn')
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
      const railRow = [...document.querySelectorAll('.stabs .stab')].some((row) => /Commit/.test(row.textContent || ''))
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
      const topRow = !!document.querySelector('.fx-toolbar-main .fx-latexbar') && !document.querySelector('.fx-toolbar-sub .fx-latexbar')
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
      let popDbg = null
      if (b?.ok) {
        await window.kaisola.fs.write(ws + '/broken.tex', '\\\\documentclass{article}\\n\\\\begin{document}\\n\\\\undefinedcommandwithanintentionallylongnamethatshouldwrapinsidepasola\\n\\\\end{document}\\n')
        g().requestFile(ws + '/broken.tex', 'edit', { pinned: true })
        g().setLatexMain(ws, ws + '/broken.tex')
        await waitFor(() => /broken\\.tex/.test(document.querySelector('.fx-tab[data-active="true"]')?.textContent || ''), 3000)
        // the broken.tex WRITE can kick off an auto-build of the OLD main —
        // while it runs the Compile button is disabled and a click is a
        // silent no-op (the successful old-main result then shows no issues).
        // Wait for the bar to retarget AND be clickable before compiling.
        const brokenBtn = await waitFor(() => {
          const btn = [...document.querySelectorAll('.fx-latexbar button')].find((x) => /Compile broken\\.tex/.test(x.getAttribute('title') || ''))
          return btn && !btn.disabled ? btn : null
        }, 30000)
        brokenBtn?.click()
        const spinnerSeen = !!(await waitFor(() => document.querySelector('.fx-latexbar .spin'), 2500))
        // the failing build itself can exceed a fixed popover wait under machine
        // load — wait for the BUILD to finish first, then the popover must be up
        await waitFor(() => !document.querySelector('.fx-latexbar .spin'), 60000)
        const popover = await waitFor(() => {
          const node = document.querySelector('.fx-latex-issues-popover')
          if (!node) return null
          const style = getComputedStyle(node)
          return style.visibility !== 'hidden' && style.position === 'fixed' ? node : null
        }, 20000)
        const messageNode = popover?.querySelector('.fx-latex-issue .truncate')
        const whiteSpace = messageNode ? getComputedStyle(messageNode).whiteSpace : ''
        // the bar repositions the popover in a rAF after it mounts — under
        // machine load the first paint can be mid-flight, so wait for a
        // settled in-viewport rect instead of measuring the first frame
        // (a genuinely escaping popover still fails: it never settles inside)
        const settledRect = popover
          ? await waitFor(() => {
              const rect = popover.getBoundingClientRect()
              return rect.left >= -1 &&
                rect.top >= -1 &&
                rect.right <= window.innerWidth + 1 &&
                rect.bottom <= window.innerHeight + 1 &&
                rect.width <= window.innerWidth
                ? rect
                : null
            }, 3000)
          : null
        latexIssuePopoverContained = !!settledRect && whiteSpace !== 'nowrap'
        const dbg = popover ? popover.getBoundingClientRect() : null
        const anyIssues = document.querySelector('.fx-latex-issues')
        popDbg = popover ? {
          rect: [Math.round(dbg.left), Math.round(dbg.top), Math.round(dbg.right), Math.round(dbg.bottom)],
          win: [window.innerWidth, window.innerHeight],
          pos: getComputedStyle(popover).position,
          ws: whiteSpace,
          offsetParent: popover.offsetParent ? popover.offsetParent.className : null,
        } : {
          found: false,
          anyIssues: !!anyIssues,
          anyClass: anyIssues ? anyIssues.className : null,
          vis: anyIssues ? getComputedStyle(anyIssues).visibility : null,
          pos: anyIssues ? getComputedStyle(anyIssues).position : null,
          bar: !!document.querySelector('.fx-latexbar'),
          brokenBtnFound: !!brokenBtn,
          spinnerSeen,
          mainInStore: g().latexMain[ws],
        }
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
      return { chip, offAtFirst, autoOn, autoMain, bar, topRow, noOverleafLink, buildShape, syncShape, pdfDblClickSync, pdfAutoBuildSynctex, pdfSourceZoomIndependent, uiBuildNoPdf, latexIssuePopoverContained, popDbg, buildGuard, barGone, dismissedSticks }
    })()`)
    fsx.rmSync(texRepo, { recursive: true, force: true })
  } catch (e) {
    latex = { error: String((e && e.message) || e) }
  }
  console.log('LATEX=' + JSON.stringify(latex))

  // 28) Chrome-style session groups + tab switching: a grouped session leads
  //     the strip order (groups drive ordering; their chrome lives in the
  //     tab's right-click menu now), collapse works, switchSession swaps the
  //     anchor card, empty groups die
  const groups = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    const tid = g().terminals[0].id
    g().createSessionGroup('Research', [tid])
    await new Promise((r) => setTimeout(r, 180))
    const grp = g().sessionGroups.find((x) => x.name === 'Research')
    const created = !!grp && grp.members.includes(tid)
    // grouped sessions cluster at the head of the ⌘1..9 / strip order
    const order = window.__kaisolaLib && window.__kaisolaLib.sessionOrderIds ? window.__kaisolaLib.sessionOrderIds(g()) : []
    const headEl = order[0] === tid
    const rowInGroup = !!document.querySelector('.stab[data-sid="' + tid + '"]')
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
    // pin: floats to slot 1 (⌘1 order) and the strip hides its close button
    g().togglePinSession(tid)
    await new Promise((r) => setTimeout(r, 150))
    const pinnedFirst = (window.__kaisolaLib && window.__kaisolaLib.sessionOrderIds
      ? window.__kaisolaLib.sessionOrderIds(g())
      : [tid])[0] === tid
    const pinnedTab = document.querySelector('.stab[data-sid="' + tid + '"]')
    const pinnedSection = !!pinnedTab && !pinnedTab.querySelector('.stab-close')
    g().togglePinSession(tid)
    const unpinned = !g().pinnedSessions.includes(tid)
    // unseen completion: a STILL completed dot renders; viewing clears it
    g().markNeedsYou(tid)
    await new Promise((r) => setTimeout(r, 120))
    const dot = !!document.querySelector('.stab[data-state="completed"]')
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
    await window.kaisola.fs.write(paths.settings, '// smoke\\n{ "theme": "dark", "termFontSize": 15, "tabLayout": "runway", }\\n')
    await window.kaisola.fs.write(paths.keymap, '[ { "bindings": { "cmd-9": null, "cmd-shift-y": "dock.toggle" } } ]\\n')
    await window.__kaisolaLib.loadUserConfig()
    const applied = g().theme === 'dark' && g().termFontSize === 15 && g().tabLayout === 'runway'
    const km = g().keymapOverrides
    const kmOk = km['cmd-9'] === null && km['cmd-shift-y'] === 'dock.toggle'
    // restore
    await window.kaisola.fs.write(paths.settings, '')
    await window.kaisola.fs.write(paths.keymap, '')
    g().setTheme(${JSON.stringify('light')})
    g().setTermFontSize(13)
    g().setTabLayout('bare')
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
    const btn = document.querySelector('.stabs .drop-btn')
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

  // A MANUAL claude (plain terminal, user typed `claude`) upgrades to a
  // restart-surviving agent: singleton on the fg-process signal, and downgrades
  // back when claude exits to the shell — the "second claude + its draft
  // vanished on restart" fix (setTerminalMeta, store.ts).
  const manualClaude = await win.webContents.executeJavaScript(`(async () => {
    const g = () => window.__kaisola.getState()
    g().requestTerminal()
    const t = g().terminals[g().terminals.length - 1]
    g().setTerminalMeta(t.id, { fgProcess: 'claude' })
    const up = g().terminals.find((x) => x.id === t.id)
    const upgraded = !!up && up.singletonKey === 'agent:claude-cli-' + t.id && up.restart === true && up.boot === 'claude --continue'
    // drafts must track from this moment (the trackDraft gate keys off agent:*)
    g().setTermDraft(t.id, 'half-typed thought')
    const draftKept = g().termDrafts[t.id] === 'half-typed thought'
    // a mid-session tool run (fg flips to a non-shell) must NOT downgrade…
    g().setTerminalMeta(t.id, { fgProcess: 'git' })
    const toolKept = g().terminals.find((x) => x.id === t.id).singletonKey === 'agent:claude-cli-' + t.id
    // …but exiting claude back to the shell must
    g().setTerminalMeta(t.id, { fgProcess: 'zsh' })
    const down = g().terminals.find((x) => x.id === t.id)
    const downgraded = !!down && !down.singletonKey && !down.boot && !down.restart
    g().closeTerminal(t.id)
    return { upgraded, draftKept, toolKept, downgraded }
  })()`)
  console.log('MANUAL_CLAUDE=' + JSON.stringify(manualClaude))

  // Manual Codex gets the same restart contract, then an exact discovered
  // session id upgrades the --last fallback. Drafts remain disk-persisted.
  const manualCodex = await win.webContents.executeJavaScript(`(() => {
    const g = () => window.__kaisola.getState()
    g().requestTerminal()
    const t = g().terminals[g().terminals.length - 1]
    g().setTerminalMeta(t.id, { fgProcess: 'codex' })
    let row = g().terminals.find((x) => x.id === t.id)
    const upgraded = row?.singletonKey === 'agent:codex-cli-' + t.id && row?.restart === true && row?.boot === 'codex resume --last'
    g().setTermDraft(t.id, 'preserve this codex draft')
    g().setTerminalResume(t.id, 'codex resume 019f4965-6294-77c0-abf8-ddae5bce85dc')
    row = g().terminals.find((x) => x.id === t.id)
    const exact = row?.boot === 'codex resume 019f4965-6294-77c0-abf8-ddae5bce85dc' && row?.restart === true
    const draftKept = g().termDrafts[t.id] === 'preserve this codex draft'
    g().setTerminalMeta(t.id, { fgProcess: 'zsh' })
    row = g().terminals.find((x) => x.id === t.id)
    const downgraded = !row?.singletonKey && !row?.boot && !row?.restart
    g().closeTerminal(t.id)
    return { upgraded, exact, draftKept, downgraded }
  })()`)
  console.log('MANUAL_CODEX=' + JSON.stringify(manualCodex))

  const failed =
    !manualCodex.upgraded || !manualCodex.exact || !manualCodex.draftKept || !manualCodex.downgraded ||
    !manualClaude.upgraded || !manualClaude.draftKept || !manualClaude.toolKept || !manualClaude.downgraded ||
    !rootChildren || !minimalShell.noWorkflowSidebar || !minimalShell.splitSidebarsDefault || !minimalShell.hasSessions || !minimalShell.railFilesOnly || !minimalShell.hasEmptyLauncher || !minimalShell.stageFiles || !minimalShell.studioDefault || !minimalShell.sidebarFooter || !minimalShell.topViewControls || !accountUi.avatar || !accountUi.headshot || !accountUi.menu || !accountUi.usageInMenu || !accountUi.usageOpened || !accountUi.avatarOnly || !accountUi.bottomLeft || !accountUi.menuAbove || !accountUi.menuFits || !accountUi.aligned || !claudeOptIn || !nativeWindow.rendererClippedMaterial || !icon.exists || !icon.usable || !icon.square || !icon.large || !glass.appSamplingLayer || !glass.chromeGlass || !glass.activeTintWhite || !glass.railLayerFlattened || !glass.contentGlassy || !glass.sessionGlassy || !glass.termGlassTint || !glass.blurKeepsGlass || !glass.lightsGray || !glass.nativeWindowRounding ||
    !emptyOk || !demoOk ||
    !review.opened || !review.closed || !review.decided ||
    !term.run || !term.ptyOk || !term.cdWorks || !term.dock || !term.host || !term.lightComposerPalette ||
    !viewportPersistence.terminalBottomKept || !viewportPersistence.assistantBottomAfterReflow || !viewportPersistence.assistantBottomAfterRemount || !viewportPersistence.draftKept ||
    !terminalContinuity.mounted || !terminalContinuity.rendererReleased || !terminalContinuity.reattached || !terminalContinuity.samePid || !terminalContinuity.spooled || !terminalContinuity.replayed || !terminalContinuity.bootOnce ||
    !terminalContinuity.receiptPersisted || !terminalContinuity.tabReceipt || !terminalContinuity.receiptShown || !terminalContinuity.receiptCleared ||
    !model.shape || !model.graceful ||
    !acp.connect || !acp.ok || !acp.claudeTerminal || !acp.ranCommand || acp.termEvents < 1 || !acp.cancelOk ||
    acp.authCount < 1 || !acp.authOk || !acp.authUrlSeen || !acp.setModelOk || acp.modelAfter !== 'mock-mini' ||
    acp.reasoningAfter !== 'low' || !acp.gotThought || acp.tools < 1 ||
    // chat agents = presets minus terminal-only ones (Claude runs as a terminal)
    !dd.hasBtn || !dd.newSession || !dd.portal || dd.items < 2 || !dd.clickAway ||
    !permrules.saved || !permrules.cascaded || !permrules.autoAnswered || !permrules.rejectCascade ||
    !sensitive.surfaced || !sensitive.stillPending || !sensitive.diffFlagged || sensitive.pendingAfter !== 0 ||
    !activityUi.card || !activityUi.hasSubagent || !activityUi.hasTerminal || !activityUi.hasStatus || !activityUi.standardizedDot || !activityUi.openBtn || !activityUi.noContext || !activityUi.noMention || !activityUi.compactChrome || !activityUi.noLayoutControl || !activityUi.settingsControl || !activityUi.addContext ||
    !composerAddUi.button || !composerAddUi.menu || !composerAddUi.files || !composerAddUi.plugins || !composerAddUi.sessions || !composerAddUi.noPaperPin || !composerAddUi.opensAbove || !composerAddUi.elevatedFocus ||
    !attentionUi.running || !attentionUi.pulse || !attentionUi.completed || !attentionUi.still || !attentionUi.cleared || !attentionUi.nativeAttention ||
    !brokerActivity.created || !brokerActivity.began || !brokerActivity.detached || !brokerActivity.settled || !brokerActivity.durable ||
    !transcriptTypography.rendered || !transcriptTypography.normalWhitespace || !transcriptTypography.readableWidth || !transcriptTypography.compactStream || !transcriptTypography.compactList || !transcriptTypography.differentiatedRoles || !transcriptTypography.promptRail || !transcriptTypography.promptRailMinimal || !transcriptTypography.localLink || !transcriptTypography.linkOpenedFiles || !transcriptTypography.lineJump ||
    !promptQueue.started || !promptQueue.queuedTwo || !promptQueue.inlinePreview || !promptQueue.aboveComposer || !promptQueue.attachedComposer || !promptQueue.queueActions || !promptQueue.noQueueToast || !promptQueue.drained || !promptQueue.combinedOnce || !promptQueue.deliveredTogether || !promptQueue.newestSpeedWon ||
    !steer.started || !steer.queuedWhileBusy || !steer.steeredWhileBusy || !steer.twoUserTurns || !steer.followDelivered || !steer.baseDelivered || !steer.endedIdle ||
    !preflightStopClose.speedReady || !preflightStopClose.pendingSeen || !preflightStopClose.stopRendered || !preflightStopClose.closedImmediately || !preflightStopClose.closedClean || !preflightStopClose.closedDraft || !preflightStopClose.reopenedDraft || !preflightStopClose.reopenedClean || !preflightStopClose.staleContinuationIgnored || !preflightStopClose.firstPreserved ||
    !persist.stored || !persist.hasTheme || !persist.hasAgent || !persist.hasThread || !persist.hasChatTurn || !persist.hasDraft || !persist.draftBounded || !persist.hasCodexEffort || !persist.hasTabLayout ||
    !boot.hasId || !boot.ran ||
    !auth.hasUrl || auth.code !== 'ABCD-1234' || !auth.done ||
    !cards.cardPerView || !cards.chatLeftOfFiles || !cards.soloHeadSuppressed || !cards.noDockPanel || !cards.emptyMessageGone || !fschk.listed || !fschk.read || !fschk.wrote ||
    !fileui.hasSearch || fileui.resultCount < 1 || fileui.tabs < 1 || !fileui.alphaPreview || !fileui.previewReplaced || !fileui.betaPinned || !fileui.hasBeta || !fileui.activeBeta ||
    !fileui.mdPreview || !fileui.mdImage || !fileui.mdMark || !fileui.mdExternal || !fileui.mdCleanEdit || !fileui.mdAuthoringToolbar || !fileui.mdBoldCommand || !fileui.mdCleanMarkdown || !fileui.mdCleanPreview || !fileui.mdReadableChannel || !fileui.mdSplitFillsPane ||
    !fileui.htmlPreview || !fileui.htmlSafe || !fileui.texSource || !fileui.texEditable || !fileui.texNoPreview ||
    fileui.imageReadKind !== 'image' || !fileui.imageHasDataUrl || !fileui.imagePreview || !fileui.imageZoomed ||
    fileui.pdfReadKind !== 'pdf' || !fileui.pdfHasPreviewUrl || !fileui.pdfNoDataUrl || !fileui.pdfPreview || !fileui.pdfNoSidePane || !fileui.pdfZoomed || !fileui.pdfChromeCollapsed ||
    fileui.largePdfReadKind !== 'pdf' || !fileui.largePdfHasPreviewUrl || !fileui.largePdfNotTooLarge || !fileui.largePdfNoDataUrl || !fileui.railSawDelta ||
    !fileui.zoomed || !fileui.zoomCss || !fileui.mdHeadingZoomed ||
    !fileui.codeZoomed || !fileui.gutterZoomed || !fileui.codeGutterAligned ||
    !fileui.topBarsDrag || !fileui.compactFileChrome || !fileui.topBarControlsNoDrag || !fileui.topBarBordersVisible ||
    !fileui.shellGuttersDrag || !fileui.shellSurfacesDrag || !fileui.shellInnerNoDrag || !fileui.shellHandlesNoDrag ||
    !fileui.fileTabsPersisted || !fileui.fileZoomPersisted ||
    !layout.sessionsInRail || !layout.hasRailTreeArea || !layout.railHasNoSessions || !layout.addsRow || !layout.focusesNewThread || !layout.noDockChrome ||
    !layout.hasFoot || !layout.footWs || !layout.footConn ||
    !splits.one || !splits.appended || !splits.heads || !splits.stacked || !splits.besides || !splits.uncapped || !splits.closes ||
    !plus.hasBtn || !plus.noDrag || !plus.pronounced || !plus.hasTerminalOption || !plus.agentChoices || !plus.claudeOpensThread || !plus.claudeNoTerminal || !plus.claudeBrandIcon || !plus.openaiBrandIcon || !plus.adds ||
    !canvasR.hasHandle || !canvasR.sized || !canvasR.clampedMin || !canvasR.resets ||
    !canvasMin.shownBefore || !canvasMin.permanentTopControl || !canvasMin.hidden || !canvasMin.permanentRestore || !canvasMin.restoredByTop || !canvasMin.cardsStay || !canvasMin.restoredByNav || !canvasMin.restoredByFile ||
    !lights.three || !lights.bigger || !lights.corner || !lights.noDrag || !lights.ctlApi ||
    !projtabs.twoTabs || !projtabs.isSecondActive || !projtabs.termsDiffer || !projtabs.gridsDiffer || !projtabs.parkedFirstOk || !projtabs.runtimeRouted || !projtabs.activeRuntimeUntouched ||
    !projtabs.layoutIndependent || !projtabs.showSessionsWorks || !projtabs.hideFilesWorks || !projtabs.showFilesWorks || !projtabs.studioWorks || !projtabs.focusRestored ||
    !projtabs.backToFirst || !projtabs.firstRestored || !projtabs.parkedSecondOk ||
    !projtabs.domTwoTabs || !projtabs.domActiveOne ||
    !projtabs.closedGone || !projtabs.stackHas || !projtabs.reopened || !projtabs.reopenedTermsOk || !projtabs.reopenedGridOk || !projtabs.backToSingle || !projtabs.adaptiveSingle ||
    !projectSwitchPerf.responsive || !projectSwitchPerf.warmFiles || !projectSwitchPerf.restored ||
    !windetach.spawned || !windetach.adopted || !windetach.termsMoved || !windetach.globalsMoved || !windetach.styleApplied || !windetach.draftMoved || !windetach.srcDropped ||
    !windetach.recombined || !windetach.insertedAtDrop || !windetach.termsSame || !windetach.pidsSame || !windetach.sourceClosed || !windetach.targetReused || !windetach.windowCountRestored ||
    !toggle.hasFig || !toggle.visibleAtRest || !toggle.putAway || !toggle.back || !toggle.hidesAll ||
    !autoname.named || !autoname.rowShows || !autoname.sticky || !autoname.manualWins || !autoname.termNamed ||
    !minimalUi.noSidebar || !minimalUi.noSidebarResize || !minimalUi.noStageNav || !minimalUi.hasSessionSidebar || !minimalUi.hasRail || !minimalUi.filesOnRight || !minimalUi.hasPlus || !minimalUi.hasFiles ||
    !tabLayouts.rendered || !tabLayouts.sidebarOk || !tabLayouts.shelfOk || !tabLayouts.bareOk || !tabLayouts.runwayOk || !tabLayouts.flatOk || !tabLayouts.compactOk || !tabLayouts.reciprocalToggle || !tabLayouts.verticalAddFlow || !tabLayouts.stateKept || !tabLayouts.staticPaint || !tabLayouts.accessible || !tabLayouts.sessionIdentity ||
    !intuitiveLayoutControls.permanentTopControls || !intuitiveLayoutControls.fileTreeIconOnly || !intuitiveLayoutControls.noLocalClose || !intuitiveLayoutControls.hidden || !intuitiveLayoutControls.topRestore || !intuitiveLayoutControls.restored || !intuitiveLayoutControls.noFooterRecovery || !intuitiveLayoutControls.noStandaloneLayout || !intuitiveLayoutControls.settingsOwned || !intuitiveLayoutControls.advancedStylesDisclosed || !intuitiveLayoutControls.startsInGeneral || !intuitiveLayoutControls.workspaceReversible || !intuitiveLayoutControls.panelsReversible || !intuitiveLayoutControls.placementReversible || !intuitiveLayoutControls.footerFollowsNavigation || !intuitiveLayoutControls.rareActionsInPalette || !intuitiveLayoutControls.previewPermanent ||
    !realPointerLayout.firstWorked || !realPointerLayout.reverseWorked || !realPointerLayout.stayedInteractive ||
    !narrowAgentUi.rendered || !narrowAgentUi.narrow || !narrowAgentUi.containerAware || !narrowAgentUi.composerFits || !narrowAgentUi.sendVisible || !narrowAgentUi.footerFits || !narrowAgentUi.wraps || !narrowAgentUi.draftReadable || !narrowAgentUi.draftScrollable || !narrowAgentUi.draftResponsive || !narrowAgentUi.sideAgnostic ||
    !inboxAnchorUi.anchoredAtZero || !inboxAnchorUi.badged || !inboxAnchorUi.staysAfterClear ||
    !settings.settingsSeparate || !settings.footerOwned || !settings.startsInGeneral || !settings.hasLayoutSettings || !settings.hasAdvancedStyles || !settings.noStandaloneLayout || !settings.hasAppearance || !settings.hasUsage || !settings.hasDiskResidency || !settings.hasTabLayout || !settings.extensionsInSettings || !settings.permanentFilesControls || !settings.noSidebarControls || !settings.previewOpened || !settings.previewDismissed ||
    !extensionsUi.opened || extensionsUi.cards < 8 || !extensionsUi.hasFilters || !extensionsUi.csvInstalled || !extensionsUi.jsonInstalled ||
    !extensionsUi.persisted || !extensionsUi.defaultUninstallPersisted || !extensionsUi.csvPreview || !extensionsUi.jsonPreview || !extensionsUi.boundedJsonPreview || !extensionsUi.closed ||
    !devExtensionHotReload.registered || !devExtensionHotReload.updated || !devExtensionHotReload.visible ||
    !mcpConfigSecurity.added || !mcpConfigSecurity.running || mcpConfigSecurity.tools < 1 || !mcpConfigSecurity.private || !mcpConfigSecurity.placeholder || !mcpConfigSecurity.notExpanded || !mcpConfigSecurity.fullSurface || mcpConfigSecurity.resources < 1 || mcpConfigSecurity.prompts < 1 || !mcpConfigSecurity.proposalGated || !mcpConfigSecurity.badBearerDenied ||
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
    !latex.chip || !latex.offAtFirst || !latex.autoOn || !latex.autoMain || !latex.bar || !latex.topRow || !latex.noOverleafLink || !latex.buildShape || !latex.syncShape || !latex.pdfDblClickSync || !latex.pdfAutoBuildSynctex || !latex.pdfSourceZoomIndependent || !latex.uiBuildNoPdf || !latex.latexIssuePopoverContained || !latex.buildGuard ||
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
  // The harness calls app.exit directly (production's before-quit hooks do not
  // run here). Reap exact owned groups so repeated smoke runs never manufacture
  // the very PPID-1 adapter leak the lifecycle suite guards against.
  await disposeAcp()
  killAllSessions()
  await new Promise((resolve) => setTimeout(resolve, 250))
  app.exit(failed ? 1 : 0)
})
