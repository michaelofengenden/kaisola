// Kaisola — Electron main process.
//
// The renderer is the SAME Vite app that `npm run dev` serves in a browser, so
// the UI is fully usable without Electron. Electron adds the native shell plus
// the privileged "tools" the research IDE needs (model calls, filesystem,
// running experiments) — all behind a locked-down preload bridge.
const { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage, nativeTheme, Notification, screen, shell } = require('electron')
const path = require('node:path')
const fs = require('node:fs')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers, detachSessionBroker, setAppFocused, detachRendererOwner } = require('./ipc/terminalHandler.cjs')
const { registerAcpHandlers, disposeAcp, acpRendererSwapState, acpRestartSafetyState, waitForAcpRestartSafe, acpProjectTransferState, transferAcpProject, releaseAcpRenderer } = require('./ipc/acpHandler.cjs')
const { registerAuthHandlers, disposeAuth } = require('./ipc/authHandler.cjs')
const { registerFsHandlers, disposeFs } = require('./ipc/fsHandler.cjs')
const { registerGrobidHandlers } = require('./ipc/grobidHandler.cjs')
const { registerSandboxHandlers } = require('./ipc/sandboxHandler.cjs')
const { registerDbHandlers } = require('./ipc/dbHandler.cjs')
const { registerCodexHandlers } = require('./ipc/codexHandler.cjs')
const { registerWorktreeHandlers } = require('./ipc/worktreeHandler.cjs')
const { registerGitHandlers } = require('./ipc/gitHandler.cjs')
const { registerLatexHandlers } = require('./ipc/latexHandler.cjs')
const { registerClaudeHooksHandlers, disposeClaudeHooks } = require('./ipc/claudeHooksHandler.cjs')
const { registerUsageHandlers } = require('./ipc/usageHandler.cjs')
const { registerLedgerHandlers } = require('./ipc/ledgerHandler.cjs')
const { registerMcpHandlers, disposeMcp } = require('./ipc/mcpServer.cjs')
const { registerExtensionHandlers } = require('./ipc/extensionHandler.cjs')
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const { registerGlassHandlers, wireGlassEvents } = require('./ipc/glassHandler.cjs')
const { registerAssistantArchiveHandlers } = require('./ipc/assistantArchive.cjs')
const { registerAttentionHandlers } = require('./ipc/attentionHandler.cjs')

const DEV_URL = process.env.KAISOLA_DEV_URL ?? process.env.PASOLA_DEV_URL // set by `npm run electron:dev`
const isDev = !!DEV_URL
const APP_NAME = 'Kaisola'
const appIconPath = path.join(__dirname, 'assets', 'kaisola-icon.png')
const macVibrancyType = 'under-window'
const macVibrancy = process.platform === 'darwin'
  ? { vibrancy: macVibrancyType, visualEffectState: 'active' }
  : {}
let appIsQuitting = false
let appCleanupStarted = false
let deferredQuitTask = null

// ── Liquid Glass (macOS 26 "Tahoe"+) ─────────────────────────────────────────
// Darwin 25 == macOS 26. When the native module is present and supported, the
// under-window material upgrades from NSVisualEffectView vibrancy to Apple's
// real NSGlassEffectView. Opt-out via prefs; everything degrades to vibrancy.
const prefsPath = () => path.join(app.getPath('userData'), 'shell-prefs.json')
function readShellPrefs() {
  try {
    return JSON.parse(fs.readFileSync(prefsPath(), 'utf8'))
  } catch {
    return {}
  }
}
function writeShellPrefs(patch) {
  try {
    fs.writeFileSync(prefsPath(), JSON.stringify({ ...readShellPrefs(), ...patch }, null, 2))
  } catch { /* prefs are cosmetic — never fatal */ }
}
const glassSupported =
  process.platform === 'darwin' && Number.parseInt(require('node:os').release(), 10) >= 25
// Native-glass lifetime belongs to a BrowserWindow, never the app globally.
// A global boolean made one successful window disable vibrancy fallbacks in
// every other window (including solid/pop-out windows). The dependency has no
// stable removeView API, so the id is diagnostic only and the native view dies
// with its owning window. A bounded renderer-window swap handles live↔solid
// transitions without stopping PTYs or agent turns in the main process.
const glassByWindow = new WeakMap()
function glassState(win) {
  let state = glassByWindow.get(win)
  if (!state) {
    state = { attempted: false, active: false, id: null, fallback: 'pending' }
    glassByWindow.set(win, state)
  }
  return state
}
function tryLiquidGlass(win) {
  const state = glassState(win)
  if (state.attempted) return state.active
  state.attempted = true
  if (win.__kaisolaSolid) { state.fallback = 'solid'; return false }
  if (!glassSupported) { state.fallback = 'unsupported'; return false }
  if (process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE) { state.fallback = 'probe'; return false }
  if (readShellPrefs().liquidGlass === false) { state.fallback = 'disabled'; return false }
  try {
    // stable API surface only (addView); the unstable_* variant tuners use
    // private APIs and stay untouched. The module itself falls back to legacy
    // blur pre-Tahoe, but we gate on Darwin ≥ 25 anyway.
    const liquidGlass = require('electron-liquid-glass')
    const id = liquidGlass.addView(win.getNativeWindowHandle(), { cornerRadius: 24 })
    if (id != null && id >= 0) {
      state.id = id
      state.active = true
      state.fallback = null
      return true
    }
    state.fallback = 'native-refused'
  } catch { state.fallback = 'native-error' /* module missing or OS refused — vibrancy remains */ }
  return false
}

app.setName(APP_NAME)
// The app has been renamed over its life (see git history); each rename moves
// the default userData dir. Keep using the OLDEST existing dir so sessions,
// the sqlite store, settings and keys survive every upgrade — new installs get
// the current name. Development gets its own profile so it can run beside the
// installed app without sharing live sessions or tripping the instance lock.
try {
  if (isDev) {
    app.setPath('userData', path.join(app.getPath('appData'), `${APP_NAME} Dev`))
  } else {
    for (const legacy of ['pasola', 'Pasola', 'Kiasola']) {
      const legacyUserData = path.join(app.getPath('appData'), legacy)
      if (fs.existsSync(legacyUserData)) {
        app.setPath('userData', legacyUserData)
        break
      }
    }
  }
} catch {
  /* keep the default path */
}

// A second process sharing userData must never run the stale-process reclaimer
// against the first process's live ACP groups. Electron's single-instance lock
// makes one main process the sole ledger owner; subsequent launches simply
// focus the existing shell.
const hasSingleInstanceLock = app.requestSingleInstanceLock()
if (!hasSingleInstanceLock) app.quit()
else app.on('second-instance', () => {
  const win = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows().find((candidate) => !candidate.isDestroyed())
  if (!win) return
  if (win.isMinimized()) win.restore()
  win.show()
  win.focus()
})

function loadAppIcon() {
  const icon = nativeImage.createFromPath(appIconPath)
  return icon.isEmpty() ? null : icon
}

// The renderer pushes its project-tab list (id/title/active) on every change;
// keep it per full window so the Window menu can mirror the FOCUSED window's
// tabs (the application menu is global on macOS).
const tabsByWc = new Map() // webContents.id → { id, title, active }[]

// tab:* menu actions only make sense in a full window with a tab strip — never
// a pop-out (pop windows carry `pop=` in their URL and have no strip).
function sendToFocusedTabWindow(channel, payload) {
  const win = BrowserWindow.getFocusedWindow()
  if (!win || win.webContents.isDestroyed()) return
  if (win.webContents.getURL().includes('pop=')) return
  win.webContents.send(channel, payload)
}

// The Window-menu tab list mirrors the focused full window's tabs, with a
// checkmark on the active one; clicking activates that project in that window.
function windowTabMenuItems() {
  const win = BrowserWindow.getFocusedWindow()
  if (!win || win.webContents.isDestroyed() || win.webContents.getURL().includes('pop=')) return []
  const wcId = win.webContents.id
  const list = tabsByWc.get(wcId)
  if (!Array.isArray(list) || !list.length) return []
  return [
    { type: 'separator' },
    ...list.map((t) => ({
      label: t.title || 'New Project',
      type: 'checkbox',
      checked: !!t.active,
      click: () => {
        const w = BrowserWindow.getAllWindows().find(
          (b) => b.webContents.id === wcId && !b.webContents.isDestroyed(),
        )
        if (w) w.webContents.send('tab:activate', t.id)
      },
    })),
  ]
}

function installAppMenu() {
  if (process.platform !== 'darwin') return
  const template = [
    {
      label: APP_NAME,
      submenu: [
        { role: 'about', label: `About ${APP_NAME}` },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide', label: `Hide ${APP_NAME}` },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit', label: `Quit ${APP_NAME}` },
      ],
    },
    {
      label: 'File',
      submenu: [
        {
          label: 'New Window',
          accelerator: 'CmdOrCtrl+Shift+N',
          click: () => createWindow({ slot: nextSlot++ }),
        },
        {
          label: 'New Tab',
          accelerator: 'CmdOrCtrl+T',
          click: () => sendToFocusedTabWindow('tab:new'),
        },
        {
          label: 'Reopen Closed Tab',
          accelerator: 'CmdOrCtrl+Alt+T',
          click: () => sendToFocusedTabWindow('tab:reopen'),
        },
        { type: 'separator' },
        // ⌘W closes the active TAB (menu accelerators fire before the page, so
        // no renderer double-fire); ⌘⇧W closes the whole window.
        {
          label: 'Close Tab',
          accelerator: 'CmdOrCtrl+W',
          click: () => sendToFocusedTabWindow('tab:close-active'),
        },
        {
          label: 'Close Window',
          accelerator: 'CmdOrCtrl+Shift+W',
          role: 'close',
        },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    {
      label: 'View',
      submenu: [
        ...(isDev ? [{ role: 'reload' }, { role: 'toggleDevTools' }, { type: 'separator' }] : []),
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        { type: 'separator' },
        { role: 'front' },
        // dynamic list of the focused window's project tabs (checkmark = active)
        ...windowTabMenuItems(),
      ],
    },
    {
      label: 'Help',
      submenu: [
        { label: APP_NAME, enabled: false },
      ],
    },
  ]
  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

// Files the OS hands us (Finder double-click / "Open With" / dock drop). The
// event can fire before any window exists (launch-by-file), so queue paths
// until a renderer has loaded; did-finish-load drains the queue.
const pendingOpenFiles = []
let rendererReady = false
function deliverOpenFile(filePath) {
  // never hand OS file-opens to a pop-out window — it has no Files surface
  const win = BrowserWindow.getAllWindows().find((w) => !w.webContents.getURL().includes('pop=')) ?? null
  if (!win || !rendererReady) {
    pendingOpenFiles.push(filePath)
    // only pop-outs left (macOS keeps the app alive) → nothing would ever drain
    // the queue; spawn a full window whose did-finish-load delivers the file
    if (!win && app.isReady()) createWindow({ slot: nextSlot++ })
    return
  }
  if (win.isMinimized()) win.restore()
  win.show()
  win.webContents.send('files:open-external', { path: filePath })
}
app.on('open-file', (event, filePath) => {
  event.preventDefault()
  deliverOpenFile(filePath)
})

// ── kaisola:// deeplinks ──────────────────────────────────────────────────────
// kaisola://mcp/install?name=<name>&config=<base64 json> — the Cursor-shaped
// MCP install link. The URL is parsed + validated in main; NOTHING is written
// until the renderer's trust modal gets an explicit Install. Links arriving
// before any window exists queue and deliver on first load.
const { parseInstallUrl } = require('./ipc/mcpCatalog.cjs')
const pendingInstalls = []
let installsReady = false
function deliverInstall(req) {
  const win = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows().find((w) => !w.webContents.isDestroyed())
  if (!win || !installsReady) {
    pendingInstalls.push(req)
    if (!win && app.isReady()) createWindow({ slot: nextSlot++ })
    return
  }
  if (win.isMinimized()) win.restore()
  win.show()
  win.webContents.send('mcp:install-request', req)
}
app.on('open-url', (event, url) => {
  event.preventDefault()
  const req = parseInstallUrl(url)
  if (req) deliverInstall(req)
})
ipcMain.on('mcp:install-ready', (e) => {
  installsReady = true
  for (const req of pendingInstalls.splice(0)) {
    if (!e.sender.isDestroyed()) e.sender.send('mcp:install-request', req)
  }
})

/**
 * All windows share this chrome. `opts.slot` opens a FULL app window with its
 * own persisted state (slot 2, 3, … — each remembers its own workspace and
 * layout across launches). `opts.pop` opens a slim pop-out window hosting one
 * terminal card (`opts.pop` = terminal id; title/hue ride along for the head).
 */
function createWindow(opts = {}) {
  const appIcon = loadAppIcon()
  const isPop = !!opts.pop
  // Eco mode wants an OPAQUE window (occlusion culling returns,
  // no vibrancy tax) — transparency is a creation-time option, so the
  // renderer persists its preference in shell-prefs and it lands here on the
  // next launch. solidBg avoids a wrong-color flash before first paint.
  // A terminal pop-out is almost entirely an opaque xterm surface; backing it
  // with another full-window native glass view wastes compositor memory for a
  // few header pixels. Keep pop-outs solid even when the full shell is live.
  const solidWin = isPop || readShellPrefs().solidWindow === true
  const solidBgRaw = readShellPrefs().solidBg
  const solidBg = /^#[0-9a-fA-F]{6}$/.test(solidBgRaw || '') ? solidBgRaw : '#0b0d11'
  const win = new BrowserWindow({
    ...(opts.adopt ? { show: false } : {}),
    width: isPop ? 760 : 1440,
    height: isPop ? 520 : 920,
    minWidth: isPop ? 420 : 1040,
    minHeight: isPop ? 280 : 680,
    title: isPop ? `${APP_NAME} — ${opts.title || 'Terminal'}` : `${APP_NAME} — Research IDE`,
    frame: false,
    ...(process.platform === 'darwin' ? { roundedCorners: true } : {}),
    // transparent window: the renderer paints its own (rounder) corners on the
    // .app surface, Codex-style; macOS draws the shadow around the custom
    // shape. Solid windows keep native rounding instead (see data-solidwin).
    transparent: !solidWin,
    backgroundColor: solidWin ? solidBg : '#00000000',
    ...(appIcon ? { icon: appIcon } : {}),
    ...(solidWin ? {} : macVibrancy),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, // renderer cannot touch Node
      nodeIntegration: false,
      sandbox: false, // preload needs require(); IPC surface stays minimal
      webviewTag: true, // browser session cards (<webview> guests, no node/preload)
      plugins: true, // Chromium's PDF viewer IS a plugin — without this the PDF iframe is blank
    },
  })
  win.__kaisolaPop = isPop
  win.__kaisolaSlot = opts.slot ? String(opts.slot) : null
  win.__kaisolaAdoptBoot = !!opts.adopt
  win.__kaisolaPendingAdoption = !!opts.adopt
  win.__kaisolaPendingTheme = null
  win.__kaisolaLastFocus = Date.now()
  win.webContents.on('did-start-loading', () => adoptionReadyWc.delete(win.webContents.id))
  // browser-card guests: popups/target=_blank navigate the SAME webview —
  // never a new Electron window
  win.webContents.on('did-attach-webview', (_event, guest) => {
    guest.setWindowOpenHandler(({ url }) => {
      if (url.startsWith('http')) guest.loadURL(url).catch(() => {})
      return { action: 'deny' }
    })
  })
  const query = {}
  if (solidWin) query.solidwin = '1' // renderer squares its custom corners to the native clip
  win.__kaisolaSolid = solidWin // what THIS window is (vs what prefs now want)
  const nativeGlass = glassState(win)
  nativeGlass.fallback = solidWin ? 'solid' : 'vibrancy'
  if (opts.slot) query.win = String(opts.slot)
  if (opts.adopt) query.adopt = '1' // tear-off adoption: boot pristine, never rehydrate the slot
  if (opts.at && Number.isFinite(opts.at.x) && Number.isFinite(opts.at.y)) {
    // land the torn-off window under the drop point, clamped to that display
    const disp = screen.getDisplayNearestPoint({ x: Math.round(opts.at.x), y: Math.round(opts.at.y) })
    const [w, h] = win.getSize()
    win.setPosition(
      Math.round(Math.min(Math.max(opts.at.x - 200, disp.workArea.x), disp.workArea.x + disp.workArea.width - w)),
      Math.round(Math.min(Math.max(opts.at.y - 20, disp.workArea.y), disp.workArea.y + disp.workArea.height - h)),
    )
  }
  if (opts.pop) {
    query.pop = String(opts.pop)
    if (opts.title) query.title = String(opts.title).slice(0, 60)
    if (opts.hue) query.hue = String(opts.hue).slice(0, 60)
  }

  // the renderer draws the traffic lights itself (macOS can't resize the native
  // ones) — hide the system buttons and let CSS own size and placement
  if (win.setWindowButtonVisibility) win.setWindowButtonVisibility(false)
  const syncMacMaterial = () => {
    // with Liquid Glass active the glass view IS the material — vibrancy off.
    // The material stays ON while blurred (visualEffectState 'active' keeps it
    // sampling): the app deliberately looks IDENTICAL when inactive — only the
    // traffic lights gray. Dropping vibrancy on blur is what used to flash the
    // shell to flat white.
    if (process.platform === 'darwin' && typeof win.setVibrancy === 'function' && !nativeGlass.active && !solidWin) {
      win.setVibrancy(macVibrancyType)
    }
    if (typeof win.setHasShadow === 'function') {
      win.setHasShadow(true)
    }
  }
  win.once('ready-to-show', () => {
    if (!solidWin && tryLiquidGlass(win) && typeof win.setVibrancy === 'function') win.setVibrancy(null)
  })
  syncMacMaterial()
  // vibrancy nap: the under-window material keeps sampling the desktop even
  // for a hidden window (visualEffectState 'active'). Detach while nothing is
  // visible; syncMacMaterial re-attaches on show/restore/focus. Liquid Glass
  // Native Liquid Glass has no stable detach API — the nap covers vibrancy
  // only. Its state is window-local, so another glass window cannot suppress
  // this window's fallback.
  const napMacMaterial = () => {
    if (process.platform === 'darwin' && typeof win.setVibrancy === 'function' && !nativeGlass.active && !solidWin) {
      win.setVibrancy(null)
    }
  }
  win.on('hide', napMacMaterial)
  win.on('minimize', napMacMaterial)
  win.on('restore', syncMacMaterial)
  wireGlassEvents(win) // wallpaper re-sample nudges (moved/resize/display/theme)

  // corners square off while full-screen; the lights gray out while blurred
  // (the renderer listens for this)
  const sendWinState = () =>
    win.webContents.send('win:state', { fullscreen: win.isFullScreen(), focused: win.isFocused() })
  win.on('enter-full-screen', sendWinState)
  win.on('leave-full-screen', sendWinState)
  win.once('ready-to-show', syncMacMaterial)
  win.on('show', syncMacMaterial)
  win.on('focus', () => {
    win.__kaisolaLastFocus = Date.now()
    syncMacMaterial()
    sendWinState()
    // the app menu is global on macOS — refresh so the Window menu mirrors THIS
    // window's tab list now that it's focused
    if (!isPop) installAppMenu()
  })
  win.on('blur', () => {
    syncMacMaterial()
    sendWinState()
  })
  // drop this window's cached tab list when it goes away, then refresh the menu
  const wcId = win.webContents.id
  const rendererOwner = win.webContents
  win.on('close', (event) => {
    if (appIsQuitting) return
    const state = acpRendererSwapState(rendererOwner)
    if (state.safe) return
    // A normal macOS window close is not an app quit. Preserve the live turn
    // and its request-specific stream listener instead of silently creating a
    // transcript/provider-context fork on reopen.
    event.preventDefault()
    if (win.__kaisolaCloseWarning) return
    win.__kaisolaCloseWarning = true
    const detail = state.awaitingPermission
      ? 'Answer or reject the pending agent approval, then close the window.'
      : 'Let the active agent turn finish, or cancel it and allow a few seconds for shutdown, then close the window.'
    void dialog.showMessageBox(win, {
      type: 'info',
      title: 'Agent work is still active',
      message: 'Kaisola kept this window open to preserve the live agent stream.',
      detail,
      buttons: ['OK'],
    }).finally(() => { win.__kaisolaCloseWarning = false })
  })
  rendererOwner.once('destroyed', () => {
    adoptionReadyWc.delete(rendererOwner.id)
    // React cleanup does not reliably run on window crashes/closes. Main owns
    // the authoritative fallback: keep processes alive, but release all hot
    // renderer resources and leases for this exact WebContents.
    detachRendererOwner(rendererOwner)
    releaseAcpRenderer(rendererOwner)
  })
  win.on('closed', () => {
    nativeGlass.active = false
    nativeGlass.fallback = 'closed'
    tabsByWc.delete(wcId)
    pendingAdoptions.delete(wcId)
    adoptionReadyWc.delete(wcId)
    if (!isPop) installAppMenu()
  })

  // Trackpad pinch sometimes reaches Electron as a page-zoom request instead of
  // a DOM wheel event. Keep the app zoom fixed and forward the intent to the
  // renderer so the Files pane can zoom document text only.
  win.webContents.on('zoom-changed', (event, zoomDirection) => {
    event.preventDefault()
    win.webContents.setZoomFactor(1)
    if (zoomDirection === 'in' || zoomDirection === 'out') {
      win.webContents.send('files:text-zoom-gesture', { direction: zoomDirection })
    }
  })
  win.webContents.on('did-finish-load', () => {
    win.webContents.setZoomFactor(1)
    syncMacMaterial()
    sendWinState()
    // pop-out windows can't host file opens — leave the queue for a full shell
    if (!isPop) {
      rendererReady = true
      for (const p of pendingOpenFiles.splice(0)) {
        win.webContents.send('files:open-external', { path: p })
      }
    }
    // Adoption is delivered by the renderer's explicit `window:adopt-ready`
    // handshake, never merely because HTML finished loading: React must have
    // installed its receiver before main sends the one-shot project payload.
  })

  if (isDev) {
    const qs = new URLSearchParams(query).toString()
    win.loadURL(qs ? `${DEV_URL}?${qs}` : DEV_URL)
    if ((process.env.KAISOLA_OPEN_DEVTOOLS ?? process.env.PASOLA_OPEN_DEVTOOLS) === '1' && !isPop && !opts.slot) win.webContents.openDevTools({ mode: 'detach' })
  } else {
    win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), Object.keys(query).length ? { query } : undefined)
  }

  // open external links in the user's browser, never in-app
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('http')) shell.openExternal(url)
    return { action: 'deny' }
  })
  return win
}

// ── multi-window ─────────────────────────────────────────────────────────────
// Full windows are numbered slots (2, 3, …) so each keeps ITS OWN persisted
// store — a second window is a fresh shell you point at a different folder,
// and it comes back as itself next launch. Pop windows host one terminal card.
let nextSlot = 2
const popWindows = new Map() // termId → BrowserWindow

ipcMain.handle('window:new', () => {
  createWindow({ slot: nextSlot++ })
  return { ok: true }
})

// Transactional Chrome-style project transfers. A drop over another Kaisola
// tab strip reuses that renderer; any other drag-out creates a HIDDEN window.
// The source keeps its project until the receiver applies it and ACKs.
const pendingAdoptions = new Map() // target webContents.id → adoption payload
const adoptionReadyWc = new Set() // renderer installed onAdoptProject listener
const pendingTransferAcks = new Map() // transferId → { targetId, resolve, timer }
const completedTransfers = new Map() // transferId → source window (until finish)
let transferSeq = 0

function transferPoint(at) {
  if (!at || !Number.isFinite(at.x) || !Number.isFinite(at.y)) return null
  return { x: Math.round(at.x), y: Math.round(at.y) }
}

function existingProjectDropTarget(source, point) {
  if (!point) return null
  return BrowserWindow.getAllWindows()
    .filter((candidate) =>
      candidate !== source && !candidate.isDestroyed() && !candidate.__kaisolaPop &&
      candidate.isVisible() && !candidate.isMinimized() && tabsByWc.has(candidate.webContents.id))
    .filter((candidate) => {
      const b = candidate.getBounds()
      // The frameless project strip is 40px; a small tolerance makes high-DPI
      // and cross-display drops forgiving without accepting the editor body.
      return point.x >= b.x && point.x <= b.x + b.width && point.y >= b.y && point.y <= b.y + 56
    })
    .sort((a, b) => (b.__kaisolaLastFocus || 0) - (a.__kaisolaLastFocus || 0))[0] ?? null
}

function deliverAdoption(target, adoption) {
  if (target.isDestroyed() || target.webContents.isDestroyed()) return false
  if (!adoptionReadyWc.has(target.webContents.id)) {
    pendingAdoptions.set(target.webContents.id, adoption)
    return true
  }
  target.webContents.send('tab:adopt', adoption)
  return true
}

ipcMain.on('window:adopt-ready', (event) => {
  adoptionReadyWc.add(event.sender.id)
  const adoption = pendingAdoptions.get(event.sender.id)
  if (!adoption) return
  pendingAdoptions.delete(event.sender.id)
  if (!event.sender.isDestroyed()) event.sender.send('tab:adopt', adoption)
})

ipcMain.on('window:adopt-complete', (event, { transferId, ok } = {}) => {
  const pending = pendingTransferAcks.get(transferId)
  if (!pending || pending.targetId !== event.sender.id) return
  pendingTransferAcks.delete(transferId)
  clearTimeout(pending.timer)
  if (ok) {
    const target = BrowserWindow.fromWebContents(event.sender)
    if (target?.__kaisolaPendingAdoption) {
      target.__kaisolaPendingAdoption = false
      const theme = target.__kaisolaPendingTheme
      target.__kaisolaPendingTheme = null
      if (theme) applyAppTheme(event.sender, theme)
    }
  }
  pending.resolve(!!ok)
})
// a torn-off window persists under its slot — NEVER hand it a slot that already
// holds a saved session, or the first persist silently destroys that session.
// (window:new keeps plain sequential slots on purpose: reopening slot 2 is how
// a saved second window — or a previously torn-off project — comes back.)
function freeSlot() {
  const { dbGet } = require('./ipc/dbHandler.cjs')
  const taken = (n) => {
    try { return dbGet(`kaisola-store-w${n}`) != null || dbGet(`pasola-store-w${n}`) != null } catch { return false }
  }
  let n = nextSlot
  while (taken(n)) n++
  nextSlot = n + 1
  return n
}
function destroyDiscardedAdoptionWindow(win) {
  if (!win) return
  const slot = win.__kaisolaSlot
  const discard = () => {
    if (!slot) return
    const { dbDel } = require('./ipc/dbHandler.cjs')
    for (const key of [`kaisola-store-w${slot}`, `kiasola-store-w${slot}`, `pasola-store-w${slot}`]) {
      try { dbDel(key) } catch { /* best-effort failed-transfer cleanup */ }
    }
  }
  if (win.isDestroyed()) { discard(); return }
  // Delete AFTER WebContents is gone so a queued persist/pagehide write cannot
  // recreate the rejected slot behind us.
  win.once('closed', discard)
  win.destroy()
}
ipcMain.handle('window:detach-project', async (event, payload = {}) => {
  if (!payload.tab?.id || !payload.slice) return { ok: false, message: 'That project could not be moved.' }
  const source = BrowserWindow.fromWebContents(event.sender)
  if (!source || source.isDestroyed()) return { ok: false, message: 'The source window is no longer available.' }

  const point = transferPoint(payload.at)
  let target = existingProjectDropTarget(source, point)
  // Chrome does not clone a renderer when its last tab is dragged to empty
  // desktop: it simply moves that window. This is both more faithful and the
  // lowest-memory path, and active agents need no ownership handoff at all.
  if (!target && point && payload.sourceTabCount === 1) {
    const display = screen.getDisplayNearestPoint(point)
    const [width, height] = source.getSize()
    if (source.isMaximized()) source.unmaximize()
    source.setPosition(
      Math.round(Math.min(Math.max(point.x - 200, display.workArea.x), display.workArea.x + display.workArea.width - width)),
      Math.round(Math.min(Math.max(point.y - 20, display.workArea.y), display.workArea.y + display.workArea.height - height)),
    )
    source.show()
    source.focus()
    return { ok: true, target: 'same' }
  }

  // ACP prompts stream through a request-specific renderer listener. Moving
  // between turns is lossless; moving mid-turn would strand that stream.
  const acpState = acpProjectTransferState(event.sender, payload.tab.id)
  if (!acpState.safe) {
    return {
      ok: false,
      message: acpState.awaitingPermission
        ? 'Answer the agent approval before moving this project to another window.'
        : 'Let the active agent turn finish before moving this project to another window.',
    }
  }

  const targetKind = target ? 'existing' : 'new'
  if (!target) target = createWindow({ slot: freeSlot(), adopt: true, at: point })
  const acpMove = transferAcpProject(event.sender, target.webContents, payload.tab.id)
  if (!acpMove.ok) {
    if (targetKind === 'new') destroyDiscardedAdoptionWindow(target)
    return { ok: false, message: 'That project already has an agent connection in the destination window.' }
  }

  const transferId = `project-transfer-${Date.now()}-${++transferSeq}`
  const targetBounds = target.getBounds()
  const adoption = {
    tab: payload.tab,
    slice: payload.slice,
    globals: payload.globals,
    popped: payload.popped,
    transferId,
    ...(point ? { dropX: point.x - targetBounds.x } : {}),
  }
  const adopted = await new Promise((resolve) => {
    const timer = setTimeout(() => {
      const pending = pendingTransferAcks.get(transferId)
      if (!pending) return
      pendingTransferAcks.delete(transferId)
      resolve(false)
    }, 15_000)
    pendingTransferAcks.set(transferId, { targetId: target.webContents.id, resolve, timer })
    if (!deliverAdoption(target, adoption)) {
      clearTimeout(timer)
      pendingTransferAcks.delete(transferId)
      resolve(false)
    }
  })
  if (!adopted) {
    pendingAdoptions.delete(target.webContents.id)
    acpMove.rollback?.()
    if (targetKind === 'new') destroyDiscardedAdoptionWindow(target)
    return { ok: false, message: 'The destination window did not accept the project; everything remains in this window.' }
  }

  if (!target.isDestroyed()) {
    target.show()
    target.focus()
  }
  const closeSource = targetKind === 'existing' && source.__kaisolaAdoptBoot === true && payload.sourceTabCount === 1
  if (closeSource) {
    completedTransfers.set(transferId, { source, sourceId: event.sender.id })
    setTimeout(() => completedTransfers.delete(transferId), 30_000).unref?.()
  }
  return { ok: true, transferId, target: targetKind, closeSource }
})

ipcMain.handle('window:finish-transfer', (event, { transferId } = {}) => {
  const completed = completedTransfers.get(transferId)
  if (!completed || completed.sourceId !== event.sender.id) return { ok: false }
  completedTransfers.delete(transferId)
  setImmediate(() => {
    if (!completed.source.isDestroyed()) completed.source.close()
  })
  return { ok: true }
})

ipcMain.handle('window:pop', (_e, { termId, title, hue } = {}) => {
  if (typeof termId !== 'string' || !termId) return { ok: false }
  const existing = popWindows.get(termId)
  if (existing && !existing.isDestroyed()) {
    existing.focus()
    return { ok: true, existed: true }
  }
  const win = createWindow({ pop: termId, title, hue })
  popWindows.set(termId, win)
  win.on('closed', () => {
    popWindows.delete(termId)
    // the origin window re-adopts the card (and re-points the pty stream)
    for (const w of BrowserWindow.getAllWindows()) {
      if (!w.webContents.isDestroyed()) w.webContents.send('pop:closed', { termId })
    }
  })
  return { ok: true }
})

// window controls for the renderer-drawn traffic lights
ipcMain.on('win:ctl', (e, action) => {
  const win = BrowserWindow.fromWebContents(e.sender)
  if (!win) return
  if (action === 'close') win.close()
  else if (action === 'minimize') win.minimize()
  else if (action === 'fullscreen') win.setFullScreen(!win.isFullScreen())
  // macOS titlebar convention: double-clicking the drag strip zooms the window
  else if (action === 'zoom') (win.isMaximized() ? win.unmaximize() : win.maximize())
})

// The renderer pushes its project-tab list on any projectTabs/activeProjectId
// change; cache it per window and rebuild the menu so the Window menu mirrors it.
ipcMain.on('tabs:changed', (e, list) => {
  if (e.sender.isDestroyed()) return
  if (Array.isArray(list)) tabsByWc.set(e.sender.id, list)
  else tabsByWc.delete(e.sender.id)
  installAppMenu()
})

// Sync the native window title to the active project name (empty → the app name).
ipcMain.on('win:set-title', (e, title) => {
  const win = BrowserWindow.fromWebContents(e.sender)
  if (!win || win.isDestroyed()) return
  win.setTitle(typeof title === 'string' && title ? `${title} — ${APP_NAME}` : APP_NAME)
})

// Liquid Glass preference — read by Settings, applied on next launch
ipcMain.handle('shell:glass', (e, patch) => {
  if (patch && typeof patch.enabled === 'boolean') writeShellPrefs({ liquidGlass: patch.enabled })
  const win = BrowserWindow.fromWebContents(e.sender)
  const state = win ? glassState(win) : null
  return {
    supported: glassSupported,
    active: !!state?.active,
    enabled: readShellPrefs().liquidGlass !== false,
    fallback: state?.fallback ?? 'no-window',
  }
})

// Perf-mode window plumbing: the renderer persists what the NEXT window
// should be (transparency is creation-time); liveSolid is what THIS window
// already is — a mismatch drives the "Restart to finish applying" chip.
ipcMain.handle('shell:window-mode', (e, patch) => {
  if (patch && typeof patch.solidWindow === 'boolean') writeShellPrefs({ solidWindow: patch.solidWindow })
  if (patch && typeof patch.solidBg === 'string' && /^#[0-9a-fA-F]{6}$/.test(patch.solidBg)) writeShellPrefs({ solidBg: patch.solidBg })
  const win = BrowserWindow.fromWebContents(e.sender)
  return { wantSolid: readShellPrefs().solidWindow === true, liveSolid: !!(win && win.__kaisolaSolid) }
})
ipcMain.handle('shell:relaunch', () => {
  // Let the replacement acquire the single-instance lock while this process
  // enters its normal before-quit cleanup path.
  app.releaseSingleInstanceLock()
  app.relaunch()
  // quit (rather than exit) runs the normal cleanup path; renderer state and
  // drafts are already synchronously disk-backed, while native/PTY resources
  // are released before the replacement process starts.
  setImmediate(() => app.quit())
})

// Transparency is creation-time. Recreate ONLY the requesting renderer window:
// PTYs, ACP turns, hooks and the terminal spool live in main and continue
// uninterrupted, while the renderer rehydrates its disk-backed slot. The
// Liquid Glass dependency has no stable removeView API; its registry holds a
// non-retaining raw pointer after the old NSView dies. Bound repeated swaps so
// pathological theme-toggle loops cannot grow even that tiny registry forever.
let reapplyingWindows = 0
let windowModeSwapCount = 0
const MAX_WINDOW_MODE_SWAPS = 8
ipcMain.handle('shell:reapply-window', (e) => {
  const win = BrowserWindow.fromWebContents(e.sender)
  if (!win || win.isDestroyed()) return { ok: false }
  const wantSolid = readShellPrefs().solidWindow === true
  if (!!win.__kaisolaSolid === wantSolid) return { ok: true, unchanged: true }
  if (windowModeSwapCount >= MAX_WINDOW_MODE_SWAPS) {
    return {
      ok: false,
      restartRequired: true,
      message: 'Kaisola left running work untouched. Quit and reopen when convenient to apply another glass-mode change.',
    }
  }
  const acpState = acpRendererSwapState(e.sender)
  if (!acpState.safe) {
    return {
      ok: false,
      busy: acpState.busy,
      awaitingPermission: acpState.awaitingPermission,
      message: acpState.awaitingPermission
        ? 'Answer the pending agent approval before applying this appearance change.'
        : 'Let the active agent turn finish before applying this appearance change.',
    }
  }
  let slot = null
  try { slot = new URL(win.webContents.getURL()).searchParams.get('win') } catch { /* primary window has no slot */ }
  const bounds = win.isFullScreen() ? win.getNormalBounds() : win.getBounds()
  const wasMaximized = win.isMaximized()
  const wasFullScreen = win.isFullScreen()
  windowModeSwapCount++
  reapplyingWindows++
  win.once('closed', () => {
    const next = createWindow(slot ? { slot: Number(slot) } : {})
    if (bounds) next.setBounds(bounds)
    next.once('ready-to-show', () => {
      if (wasMaximized) next.maximize()
      if (wasFullScreen) next.setFullScreen(true)
      reapplyingWindows = Math.max(0, reapplyingWindows - 1)
    })
  })
  win.close()
  return { ok: true }
})

// The app has its own theme toggle; the native under-window material follows
// it. A hidden adoption renderer initially boots with defaults, so quarantine
// its theme messages until its transferred globals are applied and ACKed —
// otherwise merely tearing off a tab briefly resets every visible window.
function applyAppTheme(sender, theme) {
  if (theme !== 'dark' && theme !== 'light' && theme !== 'system') return
  nativeTheme.themeSource = theme
  writeShellPrefs({ appTheme: theme })
  // theme is app-wide: sync every OTHER open window (incl. torn-off projects
  // and pop-outs) — without this a toggle only repaints the window it came from
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.webContents.isDestroyed() && w.webContents.id !== sender.id) {
      w.webContents.send('shell:theme-changed', theme)
    }
  }
}
ipcMain.on('shell:app-theme', (e, theme) => {
  if (theme !== 'dark' && theme !== 'light' && theme !== 'system') return
  const win = BrowserWindow.fromWebContents(e.sender)
  if (win?.__kaisolaPendingAdoption) {
    win.__kaisolaPendingTheme = theme
    return
  }
  applyAppTheme(e.sender, theme)
})

if (hasSingleInstanceLock) app.whenReady().then(() => {
  // paint the native material in the persisted app theme from the first frame
  const savedTheme = readShellPrefs().appTheme
  if (savedTheme === 'dark' || savedTheme === 'light' || savedTheme === 'system') nativeTheme.themeSource = savedTheme
  // kaisola:// deeplinks (MCP install links) — packaged builds only; a dev
  // registration would hijack the protocol from the installed app
  if (app.isPackaged) app.setAsDefaultProtocolClient('kaisola')
  installAppMenu()
  const appIcon = loadAppIcon()
  if (appIcon) {
    if (process.platform === 'darwin' && app.dock) app.dock.setIcon(appIcon)
    app.setAboutPanelOptions({
      applicationName: APP_NAME,
      applicationVersion: app.getVersion(),
      iconPath: appIconPath,
    })
  }
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
  registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain)
  registerLatexHandlers(ipcMain)
  registerClaudeHooksHandlers(ipcMain)
  registerUsageHandlers(ipcMain)
  registerLedgerHandlers(ipcMain)
  registerMcpHandlers(ipcMain)
  registerExtensionHandlers(ipcMain)
  registerUpdateHandlers(ipcMain, { waitForRestartSafe: waitForAcpRestartSafe })
  registerGlassHandlers(ipcMain)
  registerAssistantArchiveHandlers(ipcMain, path.join(app.getPath('userData'), 'assistant-archives'))
  registerAttentionHandlers(ipcMain, { app, BrowserWindow, Notification })
  createWindow()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  // A mode swap closes the old renderer before constructing its replacement.
  // Do not treat that intentional gap as an application quit on Windows/Linux.
  if (process.platform !== 'darwin' && reapplyingWindows === 0) app.quit()
})

// Energy: while the user works elsewhere, terminals stream in a slower profile
// (pty flush coalescing widens, the identity poller relaxes) — nothing is
// dropped, the machine just stops burning frames for windows out of focus.
// blur fires before the next window's focus, so confirm nobody has focus.
app.on('browser-window-focus', () => setAppFocused(true))
app.on('browser-window-blur', () => {
  setTimeout(() => {
    if (!BrowserWindow.getFocusedWindow()) setAppFocused(false)
  }, 150)
})

app.on('before-quit', (event) => {
  const restartState = acpRestartSafetyState()
  if (!restartState.safe) {
    // ACP streams still terminate in Electron main. Keep the UI available for
    // a live turn/approval, then complete this one quit request automatically.
    // PTY/CLI sessions are broker-owned and never enter this gate.
    event.preventDefault()
    appIsQuitting = false
    if (!deferredQuitTask) {
      const focused = BrowserWindow.getFocusedWindow()
      const options = {
        type: 'info',
        title: 'Finishing active agent work',
        message: 'Kaisola will close as soon as the active agent reaches a safe stopping point.',
        detail: restartState.awaitingPermission
          ? 'Respond to the pending approval in the app. Terminal and CLI sessions will continue in the background through the restart.'
          : 'You can let the response finish or stop it. Terminal and CLI sessions will continue in the background through the restart.',
        buttons: ['OK'],
      }
      const notice = focused ? dialog.showMessageBox(focused, options) : dialog.showMessageBox(options)
      void notice.catch(() => {})
      deferredQuitTask = waitForAcpRestartSafe().then((result) => {
        deferredQuitTask = null
        if (result.ok && result.safe) app.quit()
        else {
          const detail = result.awaitingPermission
            ? 'A permission request is still waiting for your response.'
            : 'Agent work did not reach a safe stopping point. Stop it or let it finish, then quit again.'
          void dialog.showMessageBox({ type: 'warning', title: 'Kaisola stayed open', message: 'The app was not closed, so live agent output was not lost.', detail, buttons: ['OK'] })
        }
      })
    }
    return
  }
  appIsQuitting = true
  if (appCleanupStarted) return
  appCleanupStarted = true
  // PTYs/CLI agents belong to the detached broker and continue through app
  // replacement. Closing this authenticated client makes their hot tails flush
  // to disk; the next main process reattaches to the same PIDs.
  void detachSessionBroker()
  disposeAcp()
  disposeAuth()
  disposeFs()
  disposeClaudeHooks()
  disposeMcp()
})
