// Kaisola — Electron main process.
//
// The renderer is the SAME Vite app that `npm run dev` serves in a browser, so
// the UI is fully usable without Electron. Electron adds the native shell plus
// the privileged "tools" the research IDE needs (model calls, filesystem,
// running experiments) — all behind a locked-down preload bridge.
const { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage, nativeTheme, Notification, screen, session, shell } = require('electron')
const path = require('node:path')
const fs = require('node:fs')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers, detachSessionBroker, setAppFocused, forgetRendererOwner } = require('./ipc/terminalHandler.cjs')
const { registerAcpHandlers, disposeAcp, acpRendererSwapState, acpRestartSafetyState, waitForAcpRestartSafe, acpProjectTransferState, transferAcpProject, releaseAcpRenderer } = require('./ipc/acpHandler.cjs')
const { createPopMirrorCache, sanitizeTerminalMirror, tabListOwnsProject } = require('./ipc/terminalMirrorPolicy.cjs')
const { registerAuthHandlers, disposeAuth } = require('./ipc/authHandler.cjs')
const { registerFsHandlers, disposeFs } = require('./ipc/fsHandler.cjs')
const { registerGrobidHandlers } = require('./ipc/grobidHandler.cjs')
const { registerSandboxHandlers } = require('./ipc/sandboxHandler.cjs')
const { registerDbHandlers, dbGet, dbKeys, dbMutate } = require('./ipc/dbHandler.cjs')
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
const { hardenWebviewAttachment, installPermissionPolicy, isSafeWebUrl, isTrustedRendererUrl } = require('./ipc/securityPolicy.cjs')
const { BrowserGuestRegistry } = require('./ipc/browserGuestRegistry.cjs')
const {
  MANIFEST_KEY: WINDOW_MANIFEST_KEY,
  OPEN_AT_QUIT,
  PARKED,
  idForSlot,
  mostRecentParked,
  occupiedSlots,
  parseManifest,
  removeEntry: removeManifestEntry,
  restoreCandidates,
  serializeManifest,
  slotFromStoreKey,
  storeKeysForSlot,
  upsertEntry: upsertManifestEntry,
} = require('./ipc/windowManifestPolicy.cjs')

const DEV_URL = process.env.KAISOLA_DEV_URL ?? process.env.PASOLA_DEV_URL // set by `npm run electron:dev`
const isDev = !!DEV_URL
const APP_NAME = 'Kaisola'
const rendererFile = path.join(__dirname, '..', 'dist', 'index.html')
const trustedRendererContents = new WeakSet()
const appIconPath = path.join(__dirname, 'assets', 'kaisola-icon.png')
const macVibrancyType = 'under-window'
const macVibrancy = process.platform === 'darwin'
  ? { vibrancy: macVibrancyType, visualEffectState: 'active' }
  : {}
let appIsQuitting = false
let appCleanupStarted = false
let appCleanupFinished = false
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
  if (!app.isReady()) {
    void app.whenReady().then(() => { focusSavedWindow(activateSavedWindows()) })
    return
  }
  const focused = BrowserWindow.getFocusedWindow()
  const win = focused && !focused.__kaisolaPop && !focused.__kaisolaDeleteBoot ? focused : activateSavedWindows()
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
const browserGuests = new BrowserGuestRegistry()

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
          click: () => {
            try { createWindow({ slot: freeSlot() }) }
            catch {
              void dialog.showMessageBox({
                type: 'warning',
                title: 'New window was not opened',
                message: 'Kaisola could not verify which saved window slots are occupied.',
                detail: 'No saved session was changed. Check that the app data directory is readable, then try again.',
                buttons: ['OK'],
              })
            }
          },
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
  const win = BrowserWindow.getAllWindows().find((w) => !w.__kaisolaPop && !w.__kaisolaDeleteBoot && !w.isDestroyed()) ?? null
  if (!win || !rendererReady) {
    pendingOpenFiles.push(filePath)
    // only pop-outs left (macOS keeps the app alive) → nothing would ever drain
    // the queue; spawn a full window whose did-finish-load delivers the file
    if (!win && app.isReady()) activateSavedWindows()
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
  const focused = BrowserWindow.getFocusedWindow()
  const win = focused && !focused.__kaisolaPop && !focused.__kaisolaDeleteBoot
    ? focused
    : BrowserWindow.getAllWindows().find((w) => !w.__kaisolaPop && !w.__kaisolaDeleteBoot && !w.webContents.isDestroyed())
  if (!win || !installsReady) {
    pendingInstalls.push(req)
    if (!win && app.isReady()) activateSavedWindows()
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
  const slot = opts.slot == null ? null : Number(opts.slot)
  const savedEntry = opts.savedEntry ?? null
  const savedId = !isPop && !opts.untracked ? (opts.savedId ?? idForSlot(slot)) : null
  const existingSaved = savedId ? liveSavedWindows.get(savedId) : null
  if (existingSaved && !existingSaved.isDestroyed()) return existingSaved
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
  const restoreBounds = !isPop ? savedEntry?.bounds : null
  const win = new BrowserWindow({
    ...((opts.adopt || opts.restore || opts.deleteBoot) ? { show: false } : {}),
    width: restoreBounds?.width ?? (isPop ? 760 : 1440),
    height: restoreBounds?.height ?? (isPop ? 520 : 920),
    ...(restoreBounds ? { x: restoreBounds.x, y: restoreBounds.y } : {}),
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
  trustedRendererContents.add(win.webContents)
  win.__kaisolaPop = isPop
  win.__kaisolaSlot = slot == null ? null : String(slot)
  win.__kaisolaSavedId = savedId
  win.__kaisolaDeleteBoot = !!opts.deleteBoot
  win.__kaisolaSuppressPark = false
  win.__kaisolaDeleting = false
  win.__kaisolaAdoptBoot = !!opts.adopt
  win.__kaisolaPendingAdoption = !!opts.adopt
  win.__kaisolaPendingTheme = null
  win.__kaisolaLastFocus = Date.now()
  if (savedId) trackSavedWindow(win, { entry: savedEntry, persist: !opts.deleteBoot })
  win.webContents.on('did-start-loading', () => adoptionReadyWc.delete(win.webContents.id))
  // A privileged preload is safe only while the top-level frame remains on the
  // exact packaged entry (or the configured Vite origin in development).
  const containRendererNavigation = (event, url) => {
    if (!isTrustedRendererUrl(url, { devUrl: DEV_URL, rendererFile })) event.preventDefault()
  }
  win.webContents.on('will-navigate', containRendererNavigation)
  win.webContents.on('will-redirect', containRendererNavigation)
  // Strip every capability-bearing webview preference before Chromium creates
  // the guest, and reject non-web URLs or attempts to escape the browser partition.
  win.webContents.on('will-attach-webview', (event, webPreferences, params) => {
    if (!hardenWebviewAttachment(webPreferences, params)) event.preventDefault()
  })
  // browser-card guests: popups/target=_blank navigate the SAME webview —
  // never a new Electron window
  win.webContents.on('did-attach-webview', (_event, guest) => {
    browserGuests.attach(win.webContents, guest)
    const containGuestNavigation = (event, url) => {
      if (!isSafeWebUrl(url)) event.preventDefault()
    }
    guest.on('will-navigate', containGuestNavigation)
    guest.on('will-redirect', containGuestNavigation)
    guest.setWindowOpenHandler(({ url }) => {
      if (isSafeWebUrl(url)) guest.loadURL(url).catch(() => {})
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
  if (opts.deleteBoot) query.deleteWindow = '1' // hydrate state, but mount only the deletion transaction listener
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
    if (opts.projectId) query.project = String(opts.projectId).slice(0, 240)
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
    if (opts.restore && !opts.deleteBoot && !win.isDestroyed()) {
      if (savedEntry?.maximized) win.maximize()
      if (savedEntry?.fullScreen) win.setFullScreen(true)
      win.show()
    }
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
    if (appIsQuitting) {
      if (win.__kaisolaSavedId) persistWindowSnapshot(win, OPEN_AT_QUIT)
      return
    }
    if (win.__kaisolaSuppressPark || win.__kaisolaDeleting || win.__kaisolaDeleteBoot) return
    const state = acpRendererSwapState(rendererOwner)
    if (state.safe) {
      if (win.__kaisolaSavedId && !persistWindowSnapshot(win, PARKED)) {
        event.preventDefault()
        void dialog.showMessageBox(win, {
          type: 'warning',
          title: 'Window was not closed',
          message: 'Kaisola could not save this window safely.',
          detail: 'Your sessions are still open. Try closing the window again after checking that the app data directory is writable.',
          buttons: ['OK'],
        })
      }
      return
    }
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
    clearDeleteRendererWaiters(rendererOwner.id)
    // React cleanup does not reliably run on window crashes/closes. Main owns
    // the authoritative fallback: keep processes alive, but release all hot
    // renderer resources and leases for this exact WebContents.
    // Do not clear broker ownership here: a live ACP turn can still need to
    // read/release its command PTY after this renderer crashes. Forget only
    // the dead event route; same-project replacement renderers adopt explicitly.
    forgetRendererOwner(rendererOwner)
    releaseAcpRenderer(rendererOwner)
    browserGuests.releaseOwner(rendererOwner)
  })
  win.on('closed', () => {
    nativeGlass.active = false
    nativeGlass.fallback = 'closed'
    tabsByWc.delete(wcId)
    pendingAdoptions.delete(wcId)
    adoptionReadyWc.delete(wcId)
    clearDeleteRendererWaiters(wcId)
    untrackSavedWindow(win)
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
    if (!isPop && !opts.deleteBoot) {
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
    if (isSafeWebUrl(url)) shell.openExternal(url)
    return { action: 'deny' }
  })
  return win
}

// ── multi-window ─────────────────────────────────────────────────────────────
// Full windows are numbered slots (2, 3, …) so each keeps ITS OWN persisted
// store — a second window is a fresh shell you point at a different folder,
// and it comes back as itself next launch. Pop windows host one terminal card.
let windowManifest = []
let windowManifestLoaded = false
let windowManifestWritable = true
let windowDeleteTransactions = 0
let windowDeleteQuitRequested = false
const liveSavedWindows = new Map() // manifest id → full BrowserWindow
const deleteReadyWc = new Set()
const pendingDeleteReady = new Map() // webContents.id → resolver
const pendingDeleteAcks = new Map() // transaction id → { senderId, resolve, timer }
const deletingSavedWindows = new Set()
const popWindows = new Map() // termId → BrowserWindow
const popTerminalMirrors = createPopMirrorCache({ retentionMs: 10 * 60_000, maxClosed: 128 })

function broadcastSavedWindowsChanged() {
  for (const win of BrowserWindow.getAllWindows()) {
    if (win.__kaisolaPop || win.isDestroyed() || win.webContents.isDestroyed()) continue
    win.webContents.send('window:saved-changed')
  }
}

function commitWindowManifest(next) {
  if (!windowManifestWritable) return false
  const clean = parseManifest({ version: 1, entries: next })
  try {
    dbMutate({ set: { [WINDOW_MANIFEST_KEY]: serializeManifest(clean) } })
  } catch {
    return false
  }
  windowManifest = clean
  try { broadcastSavedWindowsChanged() } catch { /* list IPC remains authoritative */ }
  return true
}

function loadWindowManifest() {
  if (windowManifestLoaded) return windowManifest
  windowManifestLoaded = true
  let raw = null
  try { raw = dbGet(WINDOW_MANIFEST_KEY) } catch {
    // Never overwrite an unreadable manifest with an empty one. The primary UI
    // can still open, but close/delete stays fail-closed until a clean relaunch.
    windowManifestWritable = false
    return windowManifest
  }
  let entries = parseManifest(raw)
  const known = new Set(entries.map((entry) => entry.id))
  let changed = raw == null
  let discovered = []
  try {
    discovered = [...new Set(dbKeys().map(slotFromStoreKey).filter((slot) => slot !== undefined))]
  } catch { /* DB enumeration is migration-only; freeSlot still probes keys */ }
  const now = Date.now()
  for (let index = 0; index < discovered.length; index++) {
    const slot = discovered[index]
    const id = idForSlot(slot)
    if (known.has(id)) continue
    // Before the manifest existed, only the primary window was known to open
    // automatically. Preserve every numbered store as parked rather than
    // guessing that it was visible at the previous quit.
    entries = upsertManifestEntry(entries, {
      slot,
      state: raw == null && slot == null ? OPEN_AT_QUIT : PARKED,
      updatedAt: now - discovered.length + index,
    })
    known.add(id)
    changed = true
  }
  windowManifest = entries
  if (changed) {
    try { dbMutate({ set: { [WINDOW_MANIFEST_KEY]: serializeManifest(entries) } }) } catch { /* UI can still run; later lifecycle writes retry */ }
  }
  return windowManifest
}

function savedWindowBounds(win) {
  try {
    return win.isMaximized() || win.isFullScreen() ? win.getNormalBounds() : win.getBounds()
  } catch {
    return undefined
  }
}

function persistWindowSnapshot(win, state, patch = {}) {
  const id = win?.__kaisolaSavedId
  if (!id || win.__kaisolaDeleteBoot || win.isDestroyed()) return true
  const current = windowManifest.find((entry) => entry.id === id)
  const slot = win.__kaisolaSlot == null ? null : Number(win.__kaisolaSlot)
  const next = upsertManifestEntry(windowManifest, {
    ...current,
    ...patch,
    slot,
    state,
    bounds: savedWindowBounds(win) ?? current?.bounds,
    maximized: win.isMaximized(),
    fullScreen: win.isFullScreen(),
    updatedAt: Date.now(),
  })
  return commitWindowManifest(next)
}

function scheduleWindowSnapshot(win) {
  if (!win.__kaisolaSavedId || win.__kaisolaDeleteBoot || win.__kaisolaDeleting || win.isDestroyed()) return
  if (win.__kaisolaManifestTimer) clearTimeout(win.__kaisolaManifestTimer)
  win.__kaisolaManifestTimer = setTimeout(() => {
    win.__kaisolaManifestTimer = null
    persistWindowSnapshot(win, OPEN_AT_QUIT)
  }, 220)
  win.__kaisolaManifestTimer.unref?.()
}

function trackSavedWindow(win, { entry, persist = true } = {}) {
  const id = win.__kaisolaSavedId
  if (!id) return
  liveSavedWindows.set(id, win)
  win.on('move', () => scheduleWindowSnapshot(win))
  win.on('resize', () => scheduleWindowSnapshot(win))
  win.on('maximize', () => scheduleWindowSnapshot(win))
  win.on('unmaximize', () => scheduleWindowSnapshot(win))
  win.on('enter-full-screen', () => scheduleWindowSnapshot(win))
  win.on('leave-full-screen', () => scheduleWindowSnapshot(win))
  if (persist) persistWindowSnapshot(win, OPEN_AT_QUIT, entry ?? {})
}

function untrackSavedWindow(win) {
  if (win.__kaisolaManifestTimer) clearTimeout(win.__kaisolaManifestTimer)
  win.__kaisolaManifestTimer = null
  const id = win.__kaisolaSavedId
  if (id && liveSavedWindows.get(id) === win) liveSavedWindows.delete(id)
}

function fullWindows() {
  return BrowserWindow.getAllWindows().filter((win) => !win.__kaisolaPop && !win.isDestroyed())
}

function visibleFullWindows() {
  return fullWindows().filter((win) => !win.__kaisolaDeleteBoot && win.isVisible())
}

function focusSavedWindow(win) {
  if (!win || win.isDestroyed()) return null
  if (win.isMinimized()) win.restore()
  if (!win.webContents.isLoadingMainFrame()) win.show()
  win.focus()
  return win
}

function reopenSavedEntry(entry, { deleteBoot = false } = {}) {
  const existing = liveSavedWindows.get(entry.id)
  if (existing && !existing.isDestroyed()) return deleteBoot ? existing : focusSavedWindow(existing)
  return createWindow({
    ...(entry.slot == null ? {} : { slot: entry.slot }),
    savedId: entry.id,
    savedEntry: entry,
    restore: true,
    deleteBoot,
  })
}

function restoreSavedWindowsOnLaunch() {
  loadWindowManifest()
  const candidates = restoreCandidates(windowManifest, new Set(liveSavedWindows.keys()))
  for (const entry of candidates) reopenSavedEntry(entry)
  if (!candidates.length) activateSavedWindows()
  return candidates.length
}

function activateSavedWindows() {
  loadWindowManifest()
  const visible = visibleFullWindows().sort((a, b) => (b.__kaisolaLastFocus || 0) - (a.__kaisolaLastFocus || 0))[0]
  if (visible) return focusSavedWindow(visible)
  const live = fullWindows().filter((win) => !win.__kaisolaDeleteBoot)[0]
  if (live) return focusSavedWindow(live)
  const parked = mostRecentParked(windowManifest)
  if (parked) return reopenSavedEntry(parked)
  const unrestored = restoreCandidates(windowManifest, new Set(liveSavedWindows.keys()))[0]
  if (unrestored) return reopenSavedEntry(unrestored)
  return createWindow({ savedId: 'primary' })
}

function savedWindowList(sender) {
  loadWindowManifest()
  return windowManifest.map((entry) => {
    const live = liveSavedWindows.get(entry.id)
    return {
      ...entry,
      open: !!live && !live.isDestroyed() && !live.__kaisolaDeleteBoot,
      current: !!live && live.webContents === sender,
    }
  })
}

function projectWindows(projectId) {
  return BrowserWindow.getAllWindows().filter((win) =>
    !win.__kaisolaPop && !win.isDestroyed() && !win.webContents.isDestroyed() &&
    tabListOwnsProject(tabsByWc.get(win.webContents.id), projectId),
  )
}

function sendTerminalMirror(win, payload) {
  if (!win || win.__kaisolaPop || win.isDestroyed() || win.webContents.isDestroyed()) return false
  if (!tabListOwnsProject(tabsByWc.get(win.webContents.id), payload.projectId)) return false
  win.webContents.send('terminal:state-mirror', payload)
  return true
}

function sendClosedPop(win, record) {
  const state = record?.state
  if (!state || !record.closed || !Number.isSafeInteger(record.revision)) return false
  if (!win || win.__kaisolaPop || win.isDestroyed() || win.webContents.isDestroyed()) return false
  if (!tabListOwnsProject(tabsByWc.get(win.webContents.id), state.projectId)) return false
  win.webContents.send('pop:closed', { ...state, revision: record.revision })
  return true
}

function replayPopRecord(win, record) {
  return record.closed ? sendClosedPop(win, record) : sendTerminalMirror(win, record.state)
}

/** A project close removes its ownership capability from the last full window.
 * Close its detached terminal windows immediately too; their broker grace
 * releases are already scheduled by closeProject, so they must not re-dock or
 * remain visible as dead cards after that grace expires. */
function closeUnownedProjectPops(projectId) {
  if (projectWindows(projectId).length) return 0
  let closed = 0
  for (const [termId, pop] of [...popWindows.entries()]) {
    if (pop.__kaisolaProjectId !== projectId) continue
    pop.__kaisolaDiscardOnClose = true
    popTerminalMirrors.discard(termId)
    if (!pop.isDestroyed()) pop.close()
    closed++
  }
  return closed
}

ipcMain.handle('window:new', () => {
  try {
    createWindow({ slot: freeSlot() })
    return { ok: true }
  } catch {
    return { ok: false, message: 'Kaisola could not verify a free saved-window slot.' }
  }
})

let windowDeleteSeq = 0

function clearDeleteRendererWaiters(senderId) {
  deleteReadyWc.delete(senderId)
  const ready = pendingDeleteReady.get(senderId)
  if (ready) {
    pendingDeleteReady.delete(senderId)
    ready(false)
  }
  for (const [transactionId, pending] of pendingDeleteAcks) {
    if (pending.senderId !== senderId) continue
    pendingDeleteAcks.delete(transactionId)
    clearTimeout(pending.timer)
    pending.resolve({ ok: false, message: 'The saved window closed before teardown completed.' })
  }
}

ipcMain.on('window:delete-ready', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender)
  // A pristine tear-off renderer announces readiness before its project
  // adoption commits the saved slot. Retain that readiness for the moment the
  // same trusted full window becomes manifest-owned.
  if (!win || win.__kaisolaPop) return
  deleteReadyWc.add(event.sender.id)
  const ready = pendingDeleteReady.get(event.sender.id)
  if (ready) {
    pendingDeleteReady.delete(event.sender.id)
    ready(true)
  }
})

ipcMain.on('window:prepare-delete-ack', (event, payload = {}) => {
  const pending = pendingDeleteAcks.get(payload.transactionId)
  if (!pending || pending.senderId !== event.sender.id) return
  pendingDeleteAcks.delete(payload.transactionId)
  clearTimeout(pending.timer)
  const projectIds = Array.isArray(payload.projectIds)
    ? payload.projectIds.filter((id) => typeof id === 'string' && /^[A-Za-z0-9_-]{1,240}$/.test(id)).slice(0, 1_000)
    : []
  pending.resolve({
    ok: payload.ok === true,
    projectIds,
    ...(typeof payload.message === 'string' ? { message: payload.message.slice(0, 500) } : {}),
  })
})

function waitForDeleteReady(win, timeoutMs = 15_000) {
  if (!win || win.isDestroyed() || win.webContents.isDestroyed()) return Promise.resolve(false)
  if (deleteReadyWc.has(win.webContents.id)) return Promise.resolve(true)
  return new Promise((resolve) => {
    const senderId = win.webContents.id
    const timer = setTimeout(() => {
      if (pendingDeleteReady.get(senderId) === settle) pendingDeleteReady.delete(senderId)
      resolve(false)
    }, timeoutMs)
    timer.unref?.()
    const settle = (ready) => {
      clearTimeout(timer)
      resolve(ready)
    }
    pendingDeleteReady.set(senderId, settle)
  })
}

function requestRendererDelete(win) {
  if (!win || win.isDestroyed() || win.webContents.isDestroyed()) return Promise.resolve({ ok: false, message: 'The saved window is unavailable.' })
  const transactionId = `window-delete-${Date.now()}-${++windowDeleteSeq}`
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingDeleteAcks.delete(transactionId)
      resolve({ ok: false, timedOut: true, message: 'The saved window did not finish preparing for deletion.' })
    }, 15_000)
    timer.unref?.()
    pendingDeleteAcks.set(transactionId, { senderId: win.webContents.id, resolve, timer })
    win.webContents.send('window:prepare-delete', { transactionId })
  })
}

function captureSavedStore(slot) {
  const values = {}
  const absent = []
  for (const key of storeKeysForSlot(slot)) {
    const value = dbGet(key)
    if (value == null) absent.push(key)
    else values[key] = value
  }
  return { values, absent }
}

function restoreSavedStore(backup) {
  dbMutate({ set: backup.values, delete: backup.absent })
}

function discardDeleteBoot(win) {
  if (!win || win.isDestroyed()) return
  win.__kaisolaSuppressPark = true
  win.__kaisolaDeleteBoot = true
  win.destroy()
}

function reloadSavedWindowFromBackup(win, backup) {
  if (!win || win.isDestroyed() || win.webContents.isDestroyed()) {
    restoreSavedStore(backup)
    return
  }
  win.__kaisolaDeleting = false
  win.__kaisolaSuppressPark = false
  const restore = () => {
    try { restoreSavedStore(backup) } catch { /* the original manifest remains authoritative */ }
  }
  win.webContents.once('did-start-loading', restore)
  try { win.webContents.reload() } catch { restore() }
}

async function deleteSavedWindow(event, id) {
  loadWindowManifest()
  if (typeof id !== 'string' || id.length > 80) return { ok: false, message: 'That saved window is invalid.' }
  const entry = windowManifest.find((candidate) => candidate.id === id)
  if (!entry) return { ok: false, missing: true, message: 'That saved window was already deleted.' }
  if (deletingSavedWindows.has(id)) return { ok: false, busy: true, message: 'That saved window is already being deleted.' }
  let target = liveSavedWindows.get(id)
  const wasLive = !!target && !target.isDestroyed() && !target.__kaisolaDeleteBoot
  if (wasLive) {
    const safety = acpRendererSwapState(target.webContents)
    if (!safety.safe) {
      return {
        ok: false,
        busy: true,
        awaitingPermission: safety.awaitingPermission,
        message: safety.awaitingPermission
          ? 'Resolve the pending agent approval before deleting this window.'
          : 'Stop active agent work before deleting this window.',
      }
    }
  }

  const requester = BrowserWindow.fromWebContents(event.sender)
  const options = {
    type: 'warning',
    title: 'Delete saved window?',
    message: `Delete “${entry.title || (entry.slot == null ? 'Primary window' : `Window ${entry.slot}`)}”?`,
    detail: 'Its saved projects, drafts, layouts, chats, and terminal sessions will be removed from Kaisola. Workspace files on disk will not be touched.',
    buttons: ['Delete window', 'Cancel'],
    defaultId: 1,
    cancelId: 1,
    noLink: true,
  }
  const confirmation = requester && !requester.isDestroyed()
    ? await dialog.showMessageBox(requester, options)
    : await dialog.showMessageBox(options)
  if (confirmation.response !== 0) return { ok: false, cancelled: true }

  // The dialog is asynchronous; a turn could have started while it was open.
  target = liveSavedWindows.get(id)
  if (target && !target.isDestroyed() && !target.__kaisolaDeleteBoot) {
    const safety = acpRendererSwapState(target.webContents)
    if (!safety.safe) return { ok: false, busy: true, awaitingPermission: safety.awaitingPermission, message: 'Agent work started, so the window was not deleted.' }
  }

  deletingSavedWindows.add(id)
  let deleteBoot = false
  let countedTransaction = false
  let backup
  try {
    if (!target || target.isDestroyed()) {
      target = reopenSavedEntry(entry, { deleteBoot: true })
      deleteBoot = true
    }
    if (!target || target.isDestroyed() || !(await waitForDeleteReady(target))) {
      if (deleteBoot) discardDeleteBoot(target)
      return { ok: false, message: 'Kaisola could not safely open the saved window for teardown.' }
    }
    const safety = acpRendererSwapState(target.webContents)
    if (!safety.safe) {
      if (deleteBoot) discardDeleteBoot(target)
      return { ok: false, busy: true, awaitingPermission: safety.awaitingPermission, message: 'Active agent work blocked deletion.' }
    }
    // The renderer copies any legacy localStorage-only blob into the durable
    // DB before announcing readiness. Capture after that handshake so even an
    // ACK-timeout or failed delete can restore the last remaining user copy.
    try { backup = captureSavedStore(entry.slot) } catch {
      if (deleteBoot) discardDeleteBoot(target)
      return { ok: false, message: 'Kaisola could not verify the saved session before deletion.' }
    }
    const prepared = await requestRendererDelete(target)
    if (!prepared.ok) {
      if (deleteBoot) {
        discardDeleteBoot(target)
        try { restoreSavedStore(backup) } catch { /* keep the manifest entry */ }
      } else if (prepared.timedOut) {
        reloadSavedWindowFromBackup(target, backup)
      }
      return { ok: false, message: prepared.message || 'The saved window could not be prepared for deletion.' }
    }

    target.__kaisolaDeleting = true
    target.__kaisolaSuppressPark = true
    const destroyedId = target.webContents.id
    windowDeleteTransactions++
    countedTransaction = true
    const result = await new Promise((resolve) => {
      let settled = false
      const finish = (value) => {
        if (settled) return
        settled = true
        resolve(value)
      }
      target.once('closed', () => {
        const nextManifest = removeManifestEntry(windowManifest, id)
        try {
          dbMutate({
            set: { [WINDOW_MANIFEST_KEY]: serializeManifest(nextManifest) },
            delete: storeKeysForSlot(entry.slot),
          })
        } catch {
          try {
            restoreSavedStore(backup)
            finish({ ok: false, message: 'Deletion failed; Kaisola restored the saved window and its session data.' })
          } catch {
            finish({ ok: false, message: 'Deletion failed and the app data store could not be restored. The manifest was retained.' })
          }
          return
        }
        // The manifest+store commit above is the transaction boundary. UI
        // notifications and orphan pop cleanup are best-effort follow-ups and
        // must never turn a successful durable deletion into a false rollback.
        windowManifest = nextManifest
        for (const projectId of prepared.projectIds ?? []) {
          try { closeUnownedProjectPops(projectId) } catch { /* next launch also excludes the deleted owner */ }
        }
        try { broadcastSavedWindowsChanged() } catch { /* surviving windows can refresh when opened */ }
        finish({ ok: true, id })
      })
      try { target.destroy() } catch {
        clearDeleteRendererWaiters(destroyedId)
        try { restoreSavedStore(backup) } catch { /* reported below */ }
        finish({ ok: false, message: 'The renderer could not be destroyed, so the saved window was not deleted.' })
      }
    })
    if (!result.ok && wasLive && windowManifest.some((candidate) => candidate.id === id)) {
      const surviving = liveSavedWindows.get(id)
      if (surviving && !surviving.isDestroyed()) {
        surviving.__kaisolaDeleting = false
        surviving.__kaisolaSuppressPark = false
        surviving.webContents.reload()
      } else {
        reopenSavedEntry(windowManifest.find((candidate) => candidate.id === id))
      }
    }
    return result
  } finally {
    if (countedTransaction) windowDeleteTransactions = Math.max(0, windowDeleteTransactions - 1)
    deletingSavedWindows.delete(id)
    if (windowDeleteQuitRequested && deletingSavedWindows.size === 0) {
      windowDeleteQuitRequested = false
      app.quit()
    } else if (process.platform !== 'darwin' && windowDeleteTransactions === 0 && BrowserWindow.getAllWindows().length === 0) app.quit()
  }
}

ipcMain.handle('window:list-saved', (event) => ({ ok: true, windows: savedWindowList(event.sender) }))
ipcMain.handle('window:reopen-saved', (_event, { id } = {}) => {
  loadWindowManifest()
  const entry = typeof id === 'string' ? windowManifest.find((candidate) => candidate.id === id) : null
  if (!entry) return { ok: false, missing: true, message: 'That saved window no longer exists.' }
  if (deletingSavedWindows.has(entry.id)) return { ok: false, busy: true, message: 'That saved window is being deleted.' }
  const win = reopenSavedEntry(entry)
  return { ok: !!win, id: entry.id }
})
ipcMain.handle('window:delete-saved', (event, { id } = {}) => deleteSavedWindow(event, id))

// Transactional Chrome-style project transfers. A drop over another Kaisola
// tab strip reuses that renderer; any other drag-out creates a HIDDEN window.
// The source keeps its project until the receiver applies it and ACKs.
const pendingAdoptions = new Map() // target webContents.id → adoption payload
const adoptionReadyWc = new Set() // renderer installed onAdoptProject listener
const pendingTransferAcks = new Map() // transferId → { targetId, resolve, timer }
const completedTransfers = new Map() // transferId → source window (until finish)
let transferSeq = 0
// Cross-renderer transfer still lacks a durable two-sided commit journal. Keep
// the safe physical move of a lone window below, but fail closed before any
// renderer/ACP ownership handoff until that transaction can survive either
// renderer crashing between its two disk commits.
const CROSS_RENDERER_PROJECT_TRANSFERS_ENABLED = false

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
// New windows allocate only truly free slots; saved windows reopen through the
// manifest IPC with their exact original slot and without adoption semantics.
function freeSlot() {
  loadWindowManifest()
  const manifestSlots = occupiedSlots(windowManifest)
  const liveSlots = new Set(fullWindows().flatMap((win) => win.__kaisolaSlot == null ? [] : [Number(win.__kaisolaSlot)]))
  // Enumerate atomically and fail closed. Guessing on an unreadable DB could
  // hand a new renderer a slot whose first persist overwrites user state.
  const storedSlots = new Set(dbKeys().map(slotFromStoreKey).filter((slot) => Number.isSafeInteger(slot)))
  const taken = (n) => manifestSlots.has(n) || liveSlots.has(n) || storedSlots.has(n)
  let n = 2
  while (n <= 999_999 && taken(n)) n++
  if (n <= 999_999) return n
  throw new Error('No saved-window slot is available.')
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

  if (!CROSS_RENDERER_PROJECT_TRANSFERS_ENABLED) {
    return {
      ok: false,
      disabled: true,
      message: 'Moving a project between windows is temporarily unavailable while Kaisola protects its live sessions. A lone project can still be moved by dragging its window.',
    }
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
  if (!target) {
    try { target = createWindow({ slot: freeSlot(), adopt: true, untracked: true, at: point }) } catch {
      return { ok: false, message: 'Kaisola could not verify a free saved-window slot, so the project stayed here.' }
    }
  }
  const acpMove = await transferAcpProject(event.sender, target.webContents, payload.tab.id)
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
    await acpMove.rollback?.()
    if (targetKind === 'new') destroyDiscardedAdoptionWindow(target)
    return { ok: false, message: 'The destination window did not accept the project; everything remains in this window.' }
  }
  acpMove.commit?.()

  if (!target.isDestroyed()) {
    if (targetKind === 'new' && !target.__kaisolaSavedId) {
      target.__kaisolaSavedId = idForSlot(Number(target.__kaisolaSlot))
      trackSavedWindow(target)
    }
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

ipcMain.handle('window:pop', (event, { termId, title, hue, projectId } = {}) => {
  if (typeof termId !== 'string' || !termId) return { ok: false }
  if (typeof projectId !== 'string' || !/^[A-Za-z0-9_-]{1,240}$/.test(projectId)) return { ok: false }
  const source = BrowserWindow.fromWebContents(event.sender)
  if (!source || source.__kaisolaPop || !tabListOwnsProject(tabsByWc.get(event.sender.id), projectId)) return { ok: false }
  const existing = popWindows.get(termId)
  if (existing && !existing.isDestroyed()) {
    if (existing.__kaisolaProjectId !== projectId) return { ok: false }
    existing.focus()
    return { ok: true, existed: true }
  }
  // A pop-out is read-only, but it still needs the originating window's
  // terminal row to recognize a manually launched CLI agent and capture its
  // exact resume id. Rehydrate that slot rather than always reading slot 1.
  const sourceSlot = source?.__kaisolaSlot ? Number(source.__kaisolaSlot) : undefined
  const win = createWindow({ pop: termId, title, hue, projectId, slot: sourceSlot })
  win.__kaisolaProjectId = projectId
  popTerminalMirrors.activate(termId, projectId)
  popWindows.set(termId, win)
  win.on('closed', () => {
    if (popWindows.get(termId) === win) popWindows.delete(termId)
    if (win.__kaisolaDiscardOnClose) {
      popTerminalMirrors.discard(termId)
      return
    }
    // Keep the merged terminal state and close marker until the exact owning
    // project ACKs this revision. A window-mode swap or a closed full shell can
    // therefore rehydrate and re-dock later without losing draft/resume state.
    const record = popTerminalMirrors.close(termId, projectId)
    if (!record) return
    for (const owner of projectWindows(projectId)) sendClosedPop(owner, record)
  })
  return { ok: true }
})
ipcMain.handle('window:popped', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender)
  if (!win || win.__kaisolaPop) return { ok: false, termIds: [], states: [] }
  const tabs = tabsByWc.get(event.sender.id)
  const records = popTerminalMirrors.values().filter((record) => tabListOwnsProject(tabs, record.state.projectId))
  return {
    ok: true,
    termIds: [...popWindows.entries()].filter(([, pop]) => tabListOwnsProject(tabs, pop.__kaisolaProjectId)).map(([termId]) => termId),
    states: records.filter((record) => !record.closed).map((record) => record.state),
    closed: records.filter((record) => record.closed).map((record) => ({ ...record.state, revision: record.revision })),
  }
})
ipcMain.handle('window:pop-closed-ack', (event, ack = {}) => {
  const win = BrowserWindow.fromWebContents(event.sender)
  if (!win || win.__kaisolaPop || win.isDestroyed() || event.sender.isDestroyed()) return { ok: false }
  if (typeof ack.termId !== 'string' || typeof ack.projectId !== 'string' || !Number.isSafeInteger(ack.revision)) return { ok: false }
  if (!tabListOwnsProject(tabsByWc.get(event.sender.id), ack.projectId)) return { ok: false }
  return { ok: popTerminalMirrors.acknowledge(ack) }
})
ipcMain.on('window:terminal-state', (event, raw) => {
  const pop = BrowserWindow.fromWebContents(event.sender)
  if (!pop || pop.isDestroyed() || !pop.__kaisolaPop || pop.__kaisolaDiscardOnClose) return
  const terminalId = [...popWindows.entries()].find(([, win]) => win === pop)?.[0]
  const projectId = pop.__kaisolaProjectId
  const payload = sanitizeTerminalMirror(raw, terminalId, projectId)
  if (!payload) return
  if (!popTerminalMirrors.update(payload)) return
  // A project can move to another full window while its terminal remains
  // popped out. Route prompt-bearing state only to the full window whose
  // registered tab list proves ownership; the cache covers renderer swaps.
  for (const owner of projectWindows(projectId)) sendTerminalMirror(owner, payload)
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
  const previous = tabsByWc.get(e.sender.id)
  if (Array.isArray(list)) tabsByWc.set(e.sender.id, list)
  else tabsByWc.delete(e.sender.id)
  if (Array.isArray(list)) {
    const win = BrowserWindow.fromWebContents(e.sender)
    const active = list.find((tab) => tab?.active) ?? list[0]
    if (win?.__kaisolaSavedId && !win.__kaisolaDeleteBoot) {
      persistWindowSnapshot(win, OPEN_AT_QUIT, {
        title: typeof active?.title === 'string' ? active.title : undefined,
        projectCount: list.length,
      })
    }
    for (const record of popTerminalMirrors.values()) replayPopRecord(win, record)
    // A normal project close updates this live tab list. Window teardown and
    // appearance swaps instead destroy WebContents without sending an empty
    // list, so their intentionally surviving pop-outs are not mistaken for a
    // closed project.
    if (Array.isArray(previous)) {
      const nextIds = new Set(list.map((tab) => tab?.id).filter((id) => typeof id === 'string'))
      for (const tab of previous) {
        if (typeof tab?.id === 'string' && !nextIds.has(tab.id)) closeUnownedProjectPops(tab.id)
      }
    }
  }
  installAppMenu()
})

// Sync the native window title to the active project name (empty → the app name).
ipcMain.on('win:set-title', (e, title) => {
  const win = BrowserWindow.fromWebContents(e.sender)
  if (!win || win.isDestroyed()) return
  win.setTitle(typeof title === 'string' && title ? `${title} — ${APP_NAME}` : APP_NAME)
  if (win.__kaisolaSavedId && !win.__kaisolaDeleteBoot && typeof title === 'string' && title) {
    persistWindowSnapshot(win, OPEN_AT_QUIT, { title })
  }
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
  const savedId = win.__kaisolaSavedId
  const savedEntry = windowManifest.find((entry) => entry.id === savedId)
  windowModeSwapCount++
  reapplyingWindows++
  win.__kaisolaSuppressPark = true
  if (savedId) persistWindowSnapshot(win, OPEN_AT_QUIT)
  win.once('closed', () => {
    const next = createWindow({
      ...(slot ? { slot: Number(slot) } : {}),
      ...(savedId ? { savedId } : {}),
      ...(savedEntry ? { savedEntry: { ...savedEntry, bounds, maximized: wasMaximized, fullScreen: wasFullScreen } } : {}),
      restore: true,
    })
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
  // Electron otherwise approves permission requests by default. Browser cards
  // get no ambient permissions; the app renderer gets only its one required,
  // explicitly enumerated permission while it remains on the trusted entry.
  installPermissionPolicy(session.defaultSession, {
    allowTrustedRenderer: true,
    trustedContents: trustedRendererContents,
    devUrl: DEV_URL,
    rendererFile,
  })
  installPermissionPolicy(session.fromPartition('persist:browser'), {
    allowTrustedRenderer: false,
    trustedContents: trustedRendererContents,
    devUrl: DEV_URL,
    rendererFile,
  })
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
  ipcMain.handle('browser:release-guest', (event, { guestId } = {}) => ({
    ok: browserGuests.release(event.sender, guestId),
  }))
  registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain)
  registerAcpHandlers(ipcMain)
  registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain)
  registerGrobidHandlers(ipcMain)
  registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain)
  loadWindowManifest()
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
  restoreSavedWindowsOnLaunch()
  app.on('activate', () => {
    if (visibleFullWindows().length === 0) activateSavedWindows()
  })
})

app.on('window-all-closed', () => {
  // A mode swap closes the old renderer before constructing its replacement.
  // Do not treat that intentional gap as an application quit on Windows/Linux.
  if (process.platform !== 'darwin' && reapplyingWindows === 0 && windowDeleteTransactions === 0) app.quit()
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
  if (deletingSavedWindows.size > 0) {
    event.preventDefault()
    windowDeleteQuitRequested = true
    void dialog.showMessageBox({
      type: 'info',
      title: 'Finishing saved-window deletion',
      message: 'Kaisola is completing the current saved-window transaction before quitting.',
      buttons: ['OK'],
    }).catch(() => {})
    return
  }
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
  let manifestSaved = true
  for (const win of fullWindows()) {
    if (!win.__kaisolaDeleting && !win.__kaisolaDeleteBoot && !persistWindowSnapshot(win, OPEN_AT_QUIT)) manifestSaved = false
  }
  if (!manifestSaved) {
    event.preventDefault()
    appIsQuitting = false
    void dialog.showMessageBox({
      type: 'warning',
      title: 'Kaisola stayed open',
      message: 'The open-window list could not be saved safely.',
      detail: 'No window was closed. Check that the app data directory is writable, then quit again.',
      buttons: ['OK'],
    }).catch(() => {})
    return
  }
  appIsQuitting = true
  if (appCleanupFinished) return
  event.preventDefault()
  if (appCleanupStarted) return
  appCleanupStarted = true
  void (async () => {
    // ACP command PTYs are connection-private and cannot be rediscovered after
    // their adapter exits. Release those exact records while the authenticated
    // broker socket is still live; user/CLI PTYs remain detached and continue.
    await disposeAcp()
    await detachSessionBroker()
    disposeAuth()
    disposeFs()
    disposeClaudeHooks()
    disposeMcp()
    appCleanupFinished = true
    app.quit()
  })()
})
