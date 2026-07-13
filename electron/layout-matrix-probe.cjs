// Responsive shell matrix: mixed session kinds, sidebar/top navigation,
// narrow/stretched widths, and real Electron pointer hit-testing.
const { app, BrowserWindow, ipcMain } = require('electron')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const userData = path.join(os.tmpdir(), 'kaisola-layout-matrix')
const workspace = path.join(userData, 'workspace')
fs.rmSync(userData, { recursive: true, force: true })
fs.mkdirSync(workspace, { recursive: true })
const markdownFixture = path.join(workspace, 'BACKLOG.md')
fs.writeFileSync(markdownFixture, '# Backlog title\n\n- [ ] Keep editing calm.\n')
app.setPath('userData', userData)

const registrations = [
  ['./ipc/modelHandler.cjs', 'registerModelHandlers'],
  ['./ipc/toolHandler.cjs', 'registerToolHandlers'],
  ['./ipc/settingsHandler.cjs', 'registerSettingsHandlers'],
  ['./ipc/terminalHandler.cjs', 'registerTerminalHandlers'],
  ['./ipc/fsHandler.cjs', 'registerFsHandlers'],
  ['./ipc/dbHandler.cjs', 'registerDbHandlers'],
  ['./ipc/gitHandler.cjs', 'registerGitHandlers'],
  ['./ipc/mcpServer.cjs', 'registerMcpHandlers'],
  ['./ipc/extensionHandler.cjs', 'registerExtensionHandlers'],
  ['./ipc/claudeHooksHandler.cjs', 'registerClaudeHooksHandlers'],
  ['./ipc/updateHandler.cjs', 'registerUpdateHandlers'],
]
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

app.whenReady().then(async () => {
  for (const [modulePath, name] of registrations) require(modulePath)[name](ipcMain)
  require('./ipc/assistantArchive.cjs').registerAssistantArchiveHandlers(ipcMain, path.join(userData, 'assistant-archives'))
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: true, liveSolid: true }))
  ipcMain.handle('app-auth:status', () => ({
    ok: true,
    configured: true,
    serverVerified: true,
    profile: { uid: 'layout-user', email: 'layout@example.com', name: 'Layout Tester' },
  }))
  ipcMain.handle('app-auth:sign-out', () => ({ ok: true, configured: true }))
  ipcMain.handle('acp:presets', () => [
    { id: 'codex', name: 'Codex' },
    { id: 'claude-code', name: 'Claude' },
  ])
  ipcMain.handle('acp:status', (_event, { clientKeys } = {}) => ({
    ok: true,
    agents: (clientKeys ?? []).map((key) => ({ key, presetId: key.split('::')[0], name: key.startsWith('claude') ? 'Claude' : 'Codex', connected: false, controls: null })),
  }))
  ipcMain.handle('acp:diagnostics', () => ({}))
  ipcMain.handle('acp:connect', () => ({ ok: false, message: 'Layout probe does not start agents.' }))
  ipcMain.handle('acp:lease', () => ({ ok: true }))

  const win = new BrowserWindow({
    show: true,
    width: 1560,
    height: 900,
    minWidth: 640,
    frame: false,
    transparent: false,
    backgroundColor: '#f4f3f0',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: false },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1' } })
  await wait(900)
  await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    state.clearProject()
    state.setWorkspace(${JSON.stringify(workspace)})
    state.requestNewGroup()
    state.requestNewThread('codex')
    state.requestTerminal(undefined, { name: 'Shell matrix' })
    state.openGitPanel()
    state.openBrowserPanel('about:blank')
    state.setTabLayout('sidebar')
    state.setSessionRailWidth(260)
    state.setRailWidth(280)
    const now = window.__kaisola.getState()
    const visibleThreads = now.assistantThreads.filter((thread) => !thread.groupParentId)
    const ids = [
      visibleThreads.find((thread) => thread.group)?.id,
      now.terminals[0]?.id,
      visibleThreads.find((thread) => !thread.group)?.id,
      now.panels.find((panel) => panel.kind === 'git')?.id,
      now.panels.find((panel) => panel.kind === 'browser')?.id,
    ].filter(Boolean)
    window.__kaisola.setState({ dockGrid: [[ids[0], ids[1], ids[4]], [ids[2], ids[3]]], dockViews: ids, dockOpen: true, canvasOpen: true })
  })()`)
  await wait(1000)

  const inspect = async (name) => win.webContents.executeJavaScript(`(() => {
    const body = document.querySelector('.app-body')
    const sidebar = document.querySelector('.session-sidebar')
    const fileRail = document.querySelector('.wsrail')
    const cards = [...document.querySelectorAll('.session-card[data-show="true"]')]
    const viewport = { width: innerWidth, height: innerHeight }
    const inViewport = (element) => {
      const rect = element.getBoundingClientRect()
      return rect.left >= -1 && rect.top >= -1 && rect.right <= innerWidth + 1 && rect.bottom <= innerHeight + 1
    }
    return {
      name: ${JSON.stringify(name)},
      viewport,
      bodyFits: document.documentElement.scrollWidth <= innerWidth + 1 && document.documentElement.scrollHeight <= innerHeight + 1,
      sidebarWidth: sidebar?.getBoundingClientRect().width ?? 0,
      fileRailWidth: fileRail?.getBoundingClientRect().width ?? 0,
      sidebarFits: !sidebar || (sidebar.scrollWidth <= sidebar.clientWidth + 1 && inViewport(sidebar)),
      cardCount: cards.length,
      cardsFit: cards.every(inViewport),
      cardWidths: cards.map((card) => Math.round(card.getBoundingClientRect().width)),
      controlsFit: [...document.querySelectorAll('.stab[data-sid]')].every((tab) => tab.scrollWidth <= tab.clientWidth + 18),
      visibleKinds: {
        group: !!document.querySelector('.group-assistant'),
        assistant: !!document.querySelector('.assistant:not(.group-workers .assistant)'),
        terminal: !!document.querySelector('.dock-pane-term'),
        git: !!document.querySelector('.git-panel'),
        browser: !!document.querySelector('.web-panel'),
      },
      horizontalTabs: !!document.querySelector('.dock-col > .stabs'),
      verticalTabs: !!document.querySelector('.session-sidebar .stabs'),
    }
  })()`)

  const wide = await inspect('wide-mixed')

  // The local preview close must be the top hit target, not a draggable canvas.
  const closePoint = await win.webContents.executeJavaScript(`(() => {
    const button = document.querySelector('.canvas-local-close')
    const rect = button?.getBoundingClientRect()
    if (!button || !rect) return null
    const x = Math.round(rect.left + rect.width / 2)
    const y = Math.round(rect.top + rect.height / 2)
    return { x, y, topmost: button.contains(document.elementFromPoint(x, y)) }
  })()`)
  if (closePoint) {
    win.webContents.sendInputEvent({ type: 'mouseDown', x: closePoint.x, y: closePoint.y, button: 'left', clickCount: 1 })
    win.webContents.sendInputEvent({ type: 'mouseUp', x: closePoint.x, y: closePoint.y, button: 'left', clickCount: 1 })
  }
  await wait(180)
  const canvasClosed = await win.webContents.executeJavaScript(`!window.__kaisola.getState().canvasOpen`)
  await win.webContents.executeJavaScript(`document.querySelector('[aria-label="Show file preview"]')?.click()`)
  await wait(180)
  const canvasRestored = await win.webContents.executeJavaScript(`window.__kaisola.getState().canvasOpen`)

  // Markdown enters the clean rich editor without the old inset accent bar.
  await win.webContents.executeJavaScript(`window.__kaisola.getState().requestFile(${JSON.stringify(markdownFixture)}, 'preview', { pinned: true })`)
  await wait(240)
  await win.webContents.executeJavaScript(`document.querySelector('.fx-doc-markdown')?.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))`)
  await wait(220)
  const markdownEditing = await win.webContents.executeJavaScript(`(() => {
    const root = document.querySelector('.fx-doc-markdown[data-editing]')
    const page = root?.querySelector('.fx-doc-page')
    if (!root || !page) return false
    page.focus()
    return !getComputedStyle(page).boxShadow.includes('inset')
  })()`)

  // Real pointer drag: Sessions stretches, Files remains unchanged.
  const resizeStart = await win.webContents.executeJavaScript(`(() => {
    const handle = document.querySelector('.session-sidebar-resize')
    const rect = handle?.getBoundingClientRect()
    if (!rect) return null
    return { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + 120) }
  })()`)
  const widthsBefore = await win.webContents.executeJavaScript(`(() => ({
    sessions: document.querySelector('.session-sidebar')?.getBoundingClientRect().width,
    files: document.querySelector('.wsrail')?.getBoundingClientRect().width,
  }))()`)
  if (resizeStart) {
    win.webContents.sendInputEvent({ type: 'mouseDown', x: resizeStart.x, y: resizeStart.y, button: 'left', clickCount: 1 })
    win.webContents.sendInputEvent({ type: 'mouseMove', x: resizeStart.x + 72, y: resizeStart.y, button: 'left' })
    win.webContents.sendInputEvent({ type: 'mouseUp', x: resizeStart.x + 72, y: resizeStart.y, button: 'left', clickCount: 1 })
  }
  await wait(180)
  const widthsAfter = await win.webContents.executeJavaScript(`(() => ({
    sessions: document.querySelector('.session-sidebar')?.getBoundingClientRect().width,
    files: document.querySelector('.wsrail')?.getBoundingClientRect().width,
  }))()`)

  // New-session priority: terminal, Codex, Claude.
  await win.webContents.executeJavaScript(`document.querySelector('.session-sidebar .drop-btn')?.click()`)
  await wait(120)
  const newSessionOrder = await win.webContents.executeJavaScript(`[...document.querySelectorAll('.drop-menu .drop-item')].slice(0, 3).map((item) => item.textContent.trim())`)
  await win.webContents.executeJavaScript(`document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))`)

  // Settings opens on General from the ordinary footer button.
  await win.webContents.executeJavaScript(`document.querySelector('.shell-sidebar-footer .shell-settings-trigger')?.click()`)
  await wait(160)
  const settingsGeneral = await win.webContents.executeJavaScript(`document.querySelector('.settings-nav-item[data-active="true"]')?.textContent.trim() === 'General'`)
  await win.webContents.executeJavaScript(`document.querySelector('.settings-head [aria-label="Close"]')?.click()`)

  // Account menu closes even when the away-click lands on a native drag area.
  await win.webContents.executeJavaScript(`document.querySelector('.shell-sidebar-footer [aria-label="Kaisola account"]')?.click()`)
  await wait(120)
  const accountOpened = await win.webContents.executeJavaScript(`!!document.querySelector('.app-account-menu')`)
  const away = await win.webContents.executeJavaScript(`(() => {
    const rect = document.querySelector('.work-row')?.getBoundingClientRect()
    return rect ? { x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + 8) } : null
  })()`)
  if (away) {
    win.webContents.sendInputEvent({ type: 'mouseDown', x: away.x, y: away.y, button: 'left', clickCount: 1 })
    win.webContents.sendInputEvent({ type: 'mouseUp', x: away.x, y: away.y, button: 'left', clickCount: 1 })
  }
  await wait(120)
  const accountClosed = await win.webContents.executeJavaScript(`!document.querySelector('.app-account-menu')`)
  const footerSingleRow = await win.webContents.executeJavaScript(`(() => {
    const footer = document.querySelector('.shell-sidebar-footer')
    const controls = [...footer?.querySelectorAll('button') ?? []]
    if (!footer || controls.length < 4 || footer.querySelector('.app-account-name')) return false
    const tops = controls.map((control) => Math.round(control.getBoundingClientRect().top))
    return Math.max(...tops) - Math.min(...tops) <= 2
  })()`)

  // Medium: two columns remain legible beside files and both rails.
  win.setSize(1180, 760)
  await win.webContents.executeJavaScript(`window.__kaisola.getState().setSessionRailWidth(210); window.__kaisola.getState().setRailWidth(220)`)
  await wait(220)
  const medium = await inspect('medium-mixed')

  // Compact: sessions only, stacked; no hidden horizontal overflow.
  win.setSize(820, 680)
  await win.webContents.executeJavaScript(`(() => {
    const state = window.__kaisola.getState()
    if (state.railOpen) state.toggleRail()
    if (state.canvasOpen) state.toggleCanvas()
    const ids = state.dockViews
    window.__kaisola.setState({ dockGrid: [ids], dockViews: ids })
    state.setSessionRailWidth(188)
  })()`)
  await wait(220)
  const compact = await inspect('compact-stacked')

  // Across-top navigation at a medium width: strip scrolls instead of clipping.
  win.setSize(1080, 720)
  await win.webContents.executeJavaScript(`window.__kaisola.getState().setTabLayout('bare')`)
  await wait(220)
  const top = await inspect('top-tabs')
  const topStripScrolls = await win.webContents.executeJavaScript(`(() => {
    const track = document.querySelector('.dock-col > .stabs .stabs-track')
    return !!track && getComputedStyle(track).overflowX === 'auto' && track.scrollWidth >= track.clientWidth
  })()`)

  const shots = []
  for (const [name, size] of [['top-tabs', [1080, 720]], ['wide-stretched', [1560, 900]]]) {
    win.setSize(...size)
    if (name === 'wide-stretched') await win.webContents.executeJavaScript(`window.__kaisola.getState().setTabLayout('sidebar'); window.__kaisola.getState().setSessionRailWidth(400)`)
    await wait(160)
    const image = await win.webContents.capturePage()
    const target = path.join(os.tmpdir(), `kaisola-${name}.png`)
    fs.writeFileSync(target, image.toPNG())
    shots.push(target)
  }

  const result = {
    wide,
    closePoint,
    canvasClosed,
    canvasRestored,
    markdownEditing,
    widthsBefore,
    widthsAfter,
    newSessionOrder,
    settingsGeneral,
    accountOpened,
    accountClosed,
    footerSingleRow,
    medium,
    compact,
    top,
    topStripScrolls,
    shots,
  }
  console.log('LAYOUT_MATRIX=' + JSON.stringify(result))
  const resized = (widthsAfter.sessions ?? 0) >= (widthsBefore.sessions ?? 0) + 60 && Math.abs((widthsAfter.files ?? 0) - (widthsBefore.files ?? 0)) <= 2
  const orderOk = /New terminal/.test(newSessionOrder[0] ?? '') && /Codex/.test(newSessionOrder[1] ?? '') && /Claude/.test(newSessionOrder[2] ?? '')
  const layoutsOk = [wide, medium, compact, top].every((view) => view.bodyFits && view.sidebarFits !== false && view.cardsFit && view.controlsFit)
  app.exit(
    layoutsOk
    && wide.cardCount >= 5
    && Object.values(wide.visibleKinds).every(Boolean)
    && closePoint?.topmost
    && canvasClosed
    && canvasRestored
    && markdownEditing
    && resized
    && orderOk
    && settingsGeneral
    && accountOpened
    && accountClosed
    && footerSingleRow
    && top.horizontalTabs
    && topStripScrolls
      ? 0
      : 1,
  )
}).catch((error) => { console.error(error); app.exit(1) })
