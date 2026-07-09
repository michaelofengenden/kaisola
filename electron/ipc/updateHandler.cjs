// In-app software updates — electron-updater against the public GitHub
// releases feed (build.publish in package.json). CI uploads latest-mac.yml
// next to the dmg/zip on every v* tag.
//
// Important macOS detail: electron-updater emits `update-downloaded` when its
// local proxy is ready, before the zip hand-off to Squirrel.Mac has necessarily
// finished. The downloadPromise settles after that hand-off. We keep the UI at
// "Preparing…" until then; quitAndInstall safely queues behind any remaining
// native staging.
//
// Updates between macOS builds also require a valid Developer ID signature.
// The release workflow signs/notarizes before uploading the ZIP; ad-hoc local
// directory builds can exercise the UI but cannot replace an installed build.
const CHECK_EVERY_MS = 60 * 60 * 1000 // startup + hourly (a tiny yml GET)
const FIRST_CHECK_DELAY_MS = 15 * 1000 // let the shell boot first
const FOCUS_CHECK_MIN_MS = 15 * 60 * 1000
const INSTALL_WATCHDOG_MS = 60 * 1000

function messageOf(err) {
  return err?.message ?? String(err)
}

// The release tags are plain x.y.z today. This deliberately accepts a leading
// `v` and ignores build metadata while still ordering numeric core segments.
function newer(a, b) {
  const parts = (value) => String(value ?? '')
    .replace(/^v/, '')
    .split('-')[0]
    .split('.')
    .map((n) => parseInt(n, 10) || 0)
  const pa = parts(a)
  const pb = parts(b)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) > (pb[i] ?? 0)
  }
  return false
}

/**
 * The packaged updater state machine. Kept injectable so updateprobe.cjs can
 * exercise download/recheck/install races without touching the release feed.
 */
function createUpdateController({
  autoUpdater,
  appVersion,
  publish = () => {},
  appEmitter,
  now = () => Date.now(),
  setTimeoutFn = setTimeout,
  clearTimeoutFn = clearTimeout,
}) {
  let state = {
    type: 'idle',
    version: null,
    percent: 0,
    message: null,
    checkError: null,
    checkingForLatest: false,
    checkedAt: null,
    appVersion,
    revision: 0,
  }
  let operation = null // check | download | ready-check | replacement-download | install
  let activeTask = null
  let lastCheckAt = 0
  let installWatchdog = null
  let removeQuitWatch = null

  const snapshot = () => ({ ...state })
  const setState = (patch) => {
    state = { ...state, ...patch, revision: state.revision + 1 }
    publish(snapshot())
  }

  const clearInstallWatchdog = () => {
    if (installWatchdog != null) clearTimeoutFn(installWatchdog)
    installWatchdog = null
    if (removeQuitWatch) removeQuitWatch()
    removeQuitWatch = null
  }

  const recordError = (err) => {
    const message = messageOf(err)
    clearInstallWatchdog()
    // A feed-only check while an update is already downloaded must never hide
    // the working Restart action just because the user is offline.
    if (operation === 'ready-check' && state.version) {
      if (state.checkError !== message || state.checkingForLatest) {
        setState({ checkingForLatest: false, checkError: message, message: null })
      }
      return
    }
    if (state.type !== 'error' || state.message !== message) {
      setState({
        type: 'error',
        percent: 0,
        message,
        checkError: message,
        checkingForLatest: false,
      })
    }
  }

  // Events paint progress immediately. Completion is committed by the
  // corresponding promise below, after the platform hand-off has settled.
  const onChecking = () => {
    if (operation === 'ready-check') {
      setState({ checkingForLatest: true, checkError: null })
    } else {
      setState({ type: 'checking', percent: 0, message: null, checkError: null, checkingForLatest: false })
    }
  }
  const onAvailable = (info) => {
    if (operation === 'ready-check') return
    setState({ type: 'downloading', version: info?.version ?? null, percent: 0, message: 'Downloading update…', checkError: null })
  }
  const onNotAvailable = () => {
    if (operation === 'ready-check') return
    setState({ type: 'idle', version: null, percent: 0, message: null, checkError: null, checkingForLatest: false })
  }
  const onProgress = (progress) => {
    if (state.type !== 'downloading' && operation !== 'download' && operation !== 'replacement-download') return
    setState({
      type: 'downloading',
      percent: Math.max(0, Math.min(100, Math.round(progress?.percent ?? 0))),
      message: 'Downloading update…',
    })
  }
  const onDownloaded = (info) => {
    setState({
      type: 'downloading',
      version: info?.version ?? state.version,
      percent: 100,
      message: 'Preparing update…',
      checkError: null,
      checkingForLatest: false,
    })
  }
  const onError = (err) => recordError(err)

  autoUpdater.on('checking-for-update', onChecking)
  autoUpdater.on('update-available', onAvailable)
  autoUpdater.on('update-not-available', onNotAvailable)
  autoUpdater.on('download-progress', onProgress)
  autoUpdater.on('update-downloaded', onDownloaded)
  autoUpdater.on('error', onError)

  const finishReady = (version) => {
    setState({
      type: 'ready',
      version: version ?? state.version,
      percent: 100,
      message: null,
      checkError: null,
      checkingForLatest: false,
    })
  }

  const startTask = (task) => {
    if (activeTask) return activeTask
    activeTask = task()
    const current = activeTask
    void current.finally(() => {
      if (activeTask === current) {
        activeTask = null
        if (operation !== 'install') operation = null
      }
    })
    return current
  }

  const check = () => startTask(async () => {
    operation = 'check'
    lastCheckAt = now()
    // Do not rely solely on the emitter: a mock, cached provider, or future
    // updater version may resolve without a checking event.
    setState({ type: 'checking', percent: 0, message: null, checkError: null, checkingForLatest: false })
    try {
      const result = await autoUpdater.checkForUpdates()
      if (!result) throw new Error('The updater is unavailable in this build.')
      const version = result.updateInfo?.version ?? result.versionInfo?.version ?? state.version
      setState({ checkedAt: now(), checkError: null })
      if (result.downloadPromise) {
        operation = 'download'
        await result.downloadPromise
        finishReady(version)
      } else if (result.isUpdateAvailable) {
        // Defensive path for updater implementations configured not to auto
        // download. Kaisola sets autoDownload=true, but this keeps the state
        // machine honest if that setting changes.
        operation = 'download'
        setState({ type: 'downloading', version, percent: 0, message: 'Downloading update…' })
        await autoUpdater.downloadUpdate()
        finishReady(version)
      } else {
        setState({ type: 'idle', version: null, percent: 0, message: null, checkError: null })
      }
      return { ok: true, version, updateAvailable: !!result.isUpdateAvailable }
    } catch (err) {
      recordError(err)
      return { ok: false, message: messageOf(err) }
    }
  })

  const refreshReady = () => startTask(async () => {
    const pendingVersion = state.version ?? appVersion
    operation = 'ready-check'
    lastCheckAt = now()
    setState({ checkingForLatest: true, checkError: null, message: null })
    autoUpdater.autoDownload = false
    try {
      const result = await autoUpdater.checkForUpdates()
      if (!result) throw new Error('The updater is unavailable in this build.')
      const version = result.updateInfo?.version ?? result.versionInfo?.version
      const checkedAt = now()
      if (version && newer(version, pendingVersion)) {
        operation = 'replacement-download'
        autoUpdater.autoDownload = true
        setState({
          type: 'downloading',
          version,
          percent: 0,
          message: 'Downloading newer update…',
          checkError: null,
          checkingForLatest: false,
          checkedAt,
        })
        // Keep activeTask alive through the WHOLE replacement download. The
        // old implementation cleared its probe flag before this await, letting
        // Restart race an incomplete replacement.
        await autoUpdater.downloadUpdate()
        finishReady(version)
        return { ok: true, version, updateAvailable: true }
      }
      setState({
        type: 'ready',
        checkingForLatest: false,
        checkedAt,
        checkError: null,
        message: null,
      })
      return { ok: true, version: pendingVersion, updateAvailable: false }
    } catch (err) {
      recordError(err)
      return { ok: false, message: messageOf(err) }
    } finally {
      autoUpdater.autoDownload = true
    }
  })

  const busy = () => !!activeTask || state.type === 'checking' || state.type === 'downloading' || state.type === 'installing'
  const recheck = () => {
    if (activeTask) return activeTask
    if (state.type === 'ready') return refreshReady()
    if (busy()) return Promise.resolve({ ok: true, busy: true })
    return check()
  }

  const install = async () => {
    // A direct IPC caller can race a ready-state refresh even though the UI
    // disables Restart during that short check. Serialize here as the hard
    // guarantee: never quit while a newer replacement is still downloading.
    if (activeTask) await activeTask
    if (state.type !== 'ready') {
      const message = 'No fully prepared update is ready to install.'
      if (state.type !== 'error') setState({ checkError: message })
      return { ok: false, message }
    }

    operation = 'install'
    setState({ type: 'installing', message: 'Restarting to apply update…', checkError: null, checkingForLatest: false })
    clearInstallWatchdog()

    const onBeforeQuit = () => clearInstallWatchdog()
    appEmitter.once('before-quit', onBeforeQuit)
    removeQuitWatch = () => appEmitter.removeListener('before-quit', onBeforeQuit)

    try {
      // electron-updater's documented contract is to call this only after its
      // downloaded event. On macOS it queues the quit until Squirrel staging is
      // complete. Do not force app.exit(): that skips the graceful quit path and
      // can interrupt the very staging operation we are waiting on.
      autoUpdater.quitAndInstall(false, true)
    } catch (err) {
      recordError(err)
      return { ok: false, message: messageOf(err) }
    }

    // If an unexpected platform/updater failure leaves the process alive,
    // restore the useful Restart state and explain the safe manual fallback.
    installWatchdog = setTimeoutFn(() => {
      if (state.type !== 'installing') return
      clearInstallWatchdog()
      setState({
        type: 'ready',
        message: null,
        checkError: 'Automatic restart did not begin. Quit and reopen Kaisola to finish installing the downloaded update.',
      })
      operation = null
    }, INSTALL_WATCHDOG_MS)
    return { ok: true }
  }

  const dispose = () => {
    clearInstallWatchdog()
    autoUpdater.removeListener('checking-for-update', onChecking)
    autoUpdater.removeListener('update-available', onAvailable)
    autoUpdater.removeListener('update-not-available', onNotAvailable)
    autoUpdater.removeListener('download-progress', onProgress)
    autoUpdater.removeListener('update-downloaded', onDownloaded)
    autoUpdater.removeListener('error', onError)
  }

  return {
    snapshot,
    check,
    recheck,
    install,
    busy,
    lastCheckAt: () => lastCheckAt,
    dispose,
  }
}

function registerUpdateHandlers(ipcMain) {
  const { app, BrowserWindow } = require('electron')
  let state = {
    type: 'idle',
    version: null,
    percent: 0,
    message: null,
    checkError: null,
    checkingForLatest: false,
    checkedAt: null,
    appVersion: app.getVersion(),
    revision: 0,
  }

  const broadcast = (next) => {
    state = next
    for (const window of BrowserWindow.getAllWindows()) {
      if (!window.webContents.isDestroyed()) window.webContents.send('update:event', state)
    }
  }
  ipcMain.handle('update:state', () => state)

  // Dev/smoke runs aren't packaged. Expose the same stateful contract so a
  // manual click explains itself instead of silently leaving "Up to date".
  if (!app.isPackaged) {
    ipcMain.handle('update:check', () => {
      const message = 'Updates apply to the installed app, not development builds.'
      broadcast({ ...state, type: 'error', message, checkError: message, revision: state.revision + 1 })
      return { ok: false, message }
    })
    ipcMain.handle('update:install', () => ({ ok: false, message: 'No downloaded update is ready to install.' }))
    return
  }

  const { autoUpdater } = require('electron-updater')
  autoUpdater.autoDownload = true
  autoUpdater.autoInstallOnAppQuit = true

  const controller = createUpdateController({
    autoUpdater,
    appVersion: app.getVersion(),
    publish: broadcast,
    appEmitter: app,
  })
  state = controller.snapshot()

  ipcMain.handle('update:check', () => controller.recheck())
  ipcMain.handle('update:install', () => controller.install())

  // The first window focus often beats this timer and starts the initial
  // check. Do not immediately repeat it (or redownload a just-found release).
  setTimeout(() => {
    if (controller.lastCheckAt() === 0 && !controller.busy()) void controller.recheck()
  }, FIRST_CHECK_DELAY_MS)
  setInterval(() => { if (!controller.busy()) void controller.recheck() }, CHECK_EVERY_MS)
  app.on('browser-window-focus', () => {
    if (controller.busy() || Date.now() - controller.lastCheckAt() < FOCUS_CHECK_MIN_MS) return
    void controller.recheck()
  })
}

module.exports = { registerUpdateHandlers, createUpdateController, newer }
