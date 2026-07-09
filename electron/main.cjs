// Kaisola — Electron main process.
//
// The renderer is the SAME Vite app that `npm run dev` serves in a browser, so
// the UI is fully usable without Electron. Electron adds the native shell plus
// the privileged "tools" the research IDE needs (model calls, filesystem,
// running experiments) — all behind a locked-down preload bridge.
const { app, BrowserWindow, ipcMain, Menu, nativeImage, nativeTheme, shell } = require('electron')
const path = require('node:path')
const fs = require('node:fs')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers, killAllSessions, setAppFocused } = require('./ipc/terminalHandler.cjs')
const { registerAcpHandlers, disposeAcp } = require('./ipc/acpHandler.cjs')
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
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const { registerGlassHandlers, wireGlassEvents } = require('./ipc/glassHandler.cjs')

const DEV_URL = process.env.KAISOLA_DEV_URL ?? process.env.PASOLA_DEV_URL // set by `npm run electron:dev`
const isDev = !!DEV_URL
const APP_NAME = 'Kaisola'
const appIconPath = path.join(__dirname, 'assets', 'kaisola-icon.png')
const macVibrancyType = 'under-window'
const macVibrancy = process.platform === 'darwin'
  ? { vibrancy: macVibrancyType, visualEffectState: 'active' }
  : {}

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
let glassActive = false
function tryLiquidGlass(win) {
  if (!glassSupported || (process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE)) return false
  if (readShellPrefs().liquidGlass === false) return false
  try {
    // stable API surface only (addView); the unstable_* variant tuners use
    // private APIs and stay untouched. The module itself falls back to legacy
    // blur pre-Tahoe, but we gate on Darwin ≥ 25 anyway.
    const liquidGlass = require('electron-liquid-glass')
    const id = liquidGlass.addView(win.getNativeWindowHandle(), { cornerRadius: 24 })
    if (id != null && id >= 0) {
      glassActive = true
      return true
    }
  } catch { /* module missing or OS refused — vibrancy remains */ }
  return false
}

app.setName(APP_NAME)
// The app has been renamed over its life (see git history); each rename moves
// the default userData dir. Keep using the OLDEST existing dir so sessions,
// the sqlite store, settings and keys survive every upgrade — new installs get
// the current name.
try {
  for (const legacy of ['pasola', 'Pasola', 'Kiasola']) {
    const legacyUserData = path.join(app.getPath('appData'), legacy)
    if (fs.existsSync(legacyUserData)) {
      app.setPath('userData', legacyUserData)
      break
    }
  }
} catch {
  /* keep the default path */
}

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

/**
 * All windows share this chrome. `opts.slot` opens a FULL app window with its
 * own persisted state (slot 2, 3, … — each remembers its own workspace and
 * layout across launches). `opts.pop` opens a slim pop-out window hosting one
 * terminal card (`opts.pop` = terminal id; title/hue ride along for the head).
 */
function createWindow(opts = {}) {
  const appIcon = loadAppIcon()
  const isPop = !!opts.pop
  // painted/eco perf modes want an OPAQUE window (occlusion culling returns,
  // no vibrancy tax) — transparency is a creation-time option, so the
  // renderer persists its preference in shell-prefs and it lands here on the
  // next launch. solidBg avoids a wrong-color flash before first paint.
  const solidWin = readShellPrefs().solidWindow === true
  const solidBgRaw = readShellPrefs().solidBg
  const solidBg = /^#[0-9a-fA-F]{6}$/.test(solidBgRaw || '') ? solidBgRaw : '#0b0d11'
  const win = new BrowserWindow({
    width: isPop ? 760 : 1440,
    height: isPop ? 520 : 920,
    minWidth: isPop ? 420 : 1040,
    minHeight: isPop ? 280 : 680,
    title: isPop ? `${APP_NAME} — ${opts.title || 'Terminal'}` : `${APP_NAME} — Research IDE`,
    frame: false,
    ...(process.platform === 'darwin' ? { roundedCorners: true } : {}),
    // transparent window: the renderer paints its own (rounder) corners on the
    // .app surface, Codex-style; macOS draws the shadow around the painted
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
  // browser-card guests: popups/target=_blank navigate the SAME webview —
  // never a new Electron window
  win.webContents.on('did-attach-webview', (_event, guest) => {
    guest.setWindowOpenHandler(({ url }) => {
      if (url.startsWith('http')) guest.loadURL(url).catch(() => {})
      return { action: 'deny' }
    })
  })
  const query = {}
  if (solidWin) query.solidwin = '1' // renderer squares its painted corners to the native clip
  win.__kaisolaSolid = solidWin // what THIS window is (vs what prefs now want)
  if (opts.slot) query.win = String(opts.slot)
  if (opts.adopt) query.adopt = '1' // tear-off adoption: boot pristine, never rehydrate the slot
  if (opts.at && Number.isFinite(opts.at.x) && Number.isFinite(opts.at.y)) {
    // land the torn-off window under the drop point, clamped to that display
    const { screen } = require('electron')
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
    if (process.platform === 'darwin' && typeof win.setVibrancy === 'function' && !glassActive && !solidWin) {
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
  // (glassActive) has no stable detach API — the nap covers vibrancy only.
  const napMacMaterial = () => {
    if (process.platform === 'darwin' && typeof win.setVibrancy === 'function' && !glassActive && !solidWin) {
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
  win.on('closed', () => {
    tabsByWc.delete(wcId)
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
    // a torn-off project waiting for this window — hand it over exactly once
    const adoption = pendingAdoptions.get(win.webContents.id)
    if (adoption) {
      pendingAdoptions.delete(win.webContents.id)
      win.webContents.send('tab:adopt', adoption)
    }
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

// Chrome-style tear-off: a renderer ships a project (tab + persisted slice)
// here; a fresh-slot window spawns at the drop point and adopts it on load.
// The ptys are global to the main process, so the project's terminals simply
// re-attach in the new window — nothing restarts.
const pendingAdoptions = new Map() // webContents.id → { tab, slice, popped }
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
ipcMain.handle('window:detach-project', (_e, payload = {}) => {
  if (!payload.tab || !payload.slice) return { ok: false }
  const win = createWindow({ slot: freeSlot(), adopt: true, at: payload.at })
  pendingAdoptions.set(win.webContents.id, { tab: payload.tab, slice: payload.slice, popped: payload.popped })
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
ipcMain.handle('shell:glass', (_e, patch) => {
  if (patch && typeof patch.enabled === 'boolean') writeShellPrefs({ liquidGlass: patch.enabled })
  return {
    supported: glassSupported,
    active: glassActive,
    enabled: readShellPrefs().liquidGlass !== false,
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
  app.relaunch()
  app.exit(0)
})

// Apply the persisted window mode NOW by recreating THIS window — no app
// restart. Transparency is creation-time, but everything that matters lives
// in the MAIN process and survives a window swap: ptys re-attach by id
// (tear-off already relies on this), ACP agents are orphan-adopted by the
// next acp:status, and the renderer rehydrates its slot from sqlite. The
// swap is close→create so the two renderers never race one store slot.
let reapplyingWindow = false
ipcMain.handle('shell:reapply-window', (e) => {
  const win = BrowserWindow.fromWebContents(e.sender)
  if (!win) return { ok: false }
  const wantSolid = readShellPrefs().solidWindow === true
  if (!!win.__kaisolaSolid === wantSolid) return { ok: true, unchanged: true }
  let slot = null
  try { slot = new URL(win.webContents.getURL()).searchParams.get('win') } catch { /* fresh window keeps no slot */ }
  const bounds = win.isFullScreen() ? null : win.getBounds()
  reapplyingWindow = true
  win.once('closed', () => {
    const next = createWindow(slot ? { slot: Number(slot) } : {})
    if (bounds) next.setBounds(bounds)
    next.once('ready-to-show', () => { reapplyingWindow = false })
  })
  win.close()
  return { ok: true }
})

// The app has its own theme toggle; the native under-window material
// (vibrancy / Liquid Glass) follows the SYSTEM appearance unless told
// otherwise — sync it, or a dark app sits on a light blur and the
// transparent rail becomes unreadable. Persisted so startup paints right.
ipcMain.on('shell:app-theme', (e, theme) => {
  if (theme !== 'dark' && theme !== 'light' && theme !== 'system') return
  nativeTheme.themeSource = theme
  writeShellPrefs({ appTheme: theme })
  // theme is app-wide: sync every OTHER open window (incl. torn-off projects
  // and pop-outs) — without this a toggle only repaints the window it came from
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.webContents.isDestroyed() && w.webContents.id !== e.sender.id) {
      w.webContents.send('shell:theme-changed', theme)
    }
  }
})

app.whenReady().then(() => {
  // paint the native material in the persisted app theme from the first frame
  const savedTheme = readShellPrefs().appTheme
  if (savedTheme === 'dark' || savedTheme === 'light' || savedTheme === 'system') nativeTheme.themeSource = savedTheme
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
  registerUpdateHandlers(ipcMain)
  registerGlassHandlers(ipcMain)
  createWindow()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  // a window-mode reapply swaps the last window close→create — not a quit
  if (process.platform !== 'darwin' && !reapplyingWindow) app.quit()
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

app.on('before-quit', () => {
  killAllSessions()
  disposeAcp()
  disposeAuth()
  disposeFs()
  disposeClaudeHooks()
  disposeMcp()
})
