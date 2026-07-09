// Deterministic updater probe: no network, releases, or installed build needed.
// Run with: node electron/updateprobe.cjs
const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const { createUpdateController, newer } = require('./ipc/updateHandler.cjs')

const deferred = () => {
  let resolve
  let reject
  const promise = new Promise((res, rej) => { resolve = res; reject = rej })
  return { promise, resolve, reject }
}
const turn = () => new Promise((resolve) => setImmediate(resolve))

class FakeUpdater extends EventEmitter {
  constructor() {
    super()
    this.autoDownload = true
    this.scenarios = []
    this.manualDownload = null
    this.quitCalls = 0
  }

  async checkForUpdates() {
    const next = this.scenarios.shift()
    assert.ok(next, 'probe supplied a check scenario')
    this.emit('checking-for-update')
    if (next.error) {
      this.emit('error', next.error)
      throw next.error
    }
    if (!next.available) {
      this.emit('update-not-available', { version: next.version })
      return { isUpdateAvailable: false, updateInfo: { version: next.version }, downloadPromise: null }
    }
    this.emit('update-available', { version: next.version })
    return {
      isUpdateAvailable: true,
      updateInfo: { version: next.version },
      downloadPromise: this.autoDownload ? next.download?.promise ?? null : null,
    }
  }

  downloadUpdate() {
    assert.ok(this.manualDownload, 'probe supplied a replacement download')
    return this.manualDownload.promise
  }

  quitAndInstall() {
    this.quitCalls += 1
  }
}

async function main() {
  assert.equal(newer('v1.2.0', '1.1.9'), true)
  assert.equal(newer('1.2.0', '1.2.0'), false)
  assert.equal(newer('1.1.9', '1.2.0'), false)

  const updater = new FakeUpdater()
  const appEvents = new EventEmitter()
  const states = []
  let clock = 1_000
  let watchdog = null
  const controller = createUpdateController({
    autoUpdater: updater,
    appVersion: '1.0.0',
    appEmitter: appEvents,
    now: () => ++clock,
    publish: (state) => states.push(state),
    setTimeoutFn: (fn) => { watchdog = fn; return 7 },
    clearTimeoutFn: () => { watchdog = null },
  })

  // Normal update: the early downloaded event is NOT enough to arm Restart.
  const firstDownload = deferred()
  updater.scenarios.push({ available: true, version: '1.1.0', download: firstDownload })
  const firstCheck = controller.check()
  await turn()
  updater.emit('download-progress', { percent: 63.7 })
  assert.equal(controller.snapshot().type, 'downloading')
  assert.equal(controller.snapshot().percent, 64)
  updater.emit('update-downloaded', { version: '1.1.0' })
  assert.equal(controller.snapshot().type, 'downloading', 'platform staging keeps Restart hidden')
  assert.equal(controller.snapshot().message, 'Preparing update…')
  firstDownload.resolve([])
  assert.equal((await firstCheck).ok, true)
  assert.equal(controller.snapshot().type, 'ready')
  assert.equal(controller.snapshot().version, '1.1.0')

  // A latest check against the same release preserves the ready build/action.
  updater.scenarios.push({ available: true, version: '1.1.0' })
  assert.equal((await controller.recheck()).ok, true)
  assert.equal(controller.snapshot().type, 'ready')
  assert.equal(controller.snapshot().checkingForLatest, false)

  // Offline while checking a ready build: keep Restart and expose the error.
  updater.scenarios.push({ error: new Error('probe offline') })
  assert.equal((await controller.recheck()).ok, false)
  assert.equal(controller.snapshot().type, 'ready')
  assert.equal(controller.snapshot().checkError, 'probe offline')

  // The historic race: Restart arrives after the newer feed response but
  // before the replacement download settles. It must wait for the WHOLE task.
  const replacement = deferred()
  updater.manualDownload = replacement
  updater.scenarios.push({ available: true, version: '1.2.0' })
  const refresh = controller.recheck()
  await turn()
  assert.equal(controller.snapshot().type, 'downloading')
  const install = controller.install()
  await turn()
  assert.equal(updater.quitCalls, 0, 'restart cannot race the replacement download')
  updater.emit('update-downloaded', { version: '1.2.0' })
  replacement.resolve([])
  assert.equal((await refresh).ok, true)
  assert.equal((await install).ok, true)
  assert.equal(updater.quitCalls, 1)
  assert.equal(controller.snapshot().type, 'installing')

  // A no-op platform restart recovers to a retryable state with instructions;
  // it never force-exits and interrupts macOS staging.
  assert.equal(typeof watchdog, 'function')
  watchdog()
  assert.equal(controller.snapshot().type, 'ready')
  assert.match(controller.snapshot().checkError, /Quit and reopen Kaisola/)

  // Every publication is monotonic, which makes renderer snapshot/event races safe.
  for (let i = 1; i < states.length; i += 1) {
    assert.ok(states[i].revision > states[i - 1].revision)
  }

  controller.dispose()
  process.stdout.write(`UPDATE_PROBE=PASS states=${states.length}\n`)
}

main()
  .catch((error) => {
    process.stderr.write(`${error.stack ?? error}\nUPDATE_PROBE=FAIL\n`)
    process.exitCode = 1
  })
