'use strict'

const path = require('node:path')
const {
  CAPABILITIES,
  CompanionDeviceStore,
  validateCapabilities,
} = require('../companion/deviceStore.cjs')
const {
  CompanionPairingManager,
  DEFAULT_PAIRING_TTL_MS,
} = require('../companion/pairing.cjs')
const { BonjourCompanionTransport, DEFAULT_COMPANION_PORT } = require('../companion/bonjourTransport.cjs')
const { CompanionGateway } = require('../companion/gateway.cjs')
const { KaisolaLinkClient } = require('../companion/kaisolaLinkClient.cjs')
const { CompanionStateHub } = require('../companion/stateHub.cjs')
const { CompanionPreferenceStore } = require('../companion/preferenceStore.cjs')

const STATE_CHANNEL = 'companion:state'
const PAIRING_CHANNEL = 'companion:pairing-event'
const DEVICE_STORE_EVENTS = Object.freeze([
  'paired',
  'repaired',
  'capabilities',
  'renamed',
  'seen',
  'connected',
  'disconnected',
  'revoked',
])
const HANDLER_CHANNELS = Object.freeze([
  'companion:getState',
  'companion:setEnabled',
  'companion:refresh',
  'companion:startPairing',
  'companion:confirmPairing',
  'companion:cancelPairing',
  'companion:revokeDevice',
  'companion:renameDevice',
  'companion:setDeviceCapabilities',
])
const DEFAULT_RETRY_BASE_MS = 2_000
const DEFAULT_RETRY_MAX_MS = 30_000

function pairingFailureMessage(reason) {
  if (reason === 'authentication_timeout') return 'Pairing timed out. Try again.'
  if (reason === 'companion_disabled') return 'Pairing stopped because Companion was turned off.'
  return 'Pairing failed. Try again.'
}

function displayName(value) {
  if (typeof value !== 'string') return undefined
  const clean = value.replace(/[\0-\x1f\x7f]/g, '').trim().slice(0, 80)
  return clean || undefined
}

function sasPhrase(value) {
  const phrase = typeof value === 'string' ? value : value?.phrase
  if (typeof phrase !== 'string') return undefined
  const clean = phrase.trim()
  return clean.split(/\s+/).length === 4 && /^[a-z-]+(?: [a-z-]+){3}$/.test(clean) ? clean : undefined
}

class CompanionHandler {
  constructor({
    app,
    BrowserWindow,
    safeStorage,
    desktopState,
    gatewayOptions = {},
    filePath,
    settingsPath,
    deviceStore,
    preferenceStore,
    pairingManager,
    stateHub,
    gateway,
    transport,
    transportFactory,
    linkClient,
    linkOptions,
    accountRendezvous = null,
    now = Date.now,
    pairingTtlMs = DEFAULT_PAIRING_TTL_MS,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    setBackgroundLaunchEnabled = null,
    retryBaseMs = DEFAULT_RETRY_BASE_MS,
    retryMaxMs = DEFAULT_RETRY_MAX_MS,
    logger = console,
  } = {}) {
    if (!app?.getPath || !BrowserWindow?.getAllWindows) throw new Error('companion handler Electron dependencies are invalid')
    this.app = app
    this.BrowserWindow = BrowserWindow
    this.now = now
    this.pairingTtlMs = pairingTtlMs
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.logger = logger
    this.accountRendezvous = accountRendezvous
    this.setBackgroundLaunchEnabled = typeof setBackgroundLaunchEnabled === 'function' ? setBackgroundLaunchEnabled : null
    this.enabled = false
    this.desiredEnabled = false
    this.startFailed = false
    this.disposed = false
    this.transition = Promise.resolve()
    this.activePairings = new Map()
    this.ipcMain = null
    this.retryBaseMs = Math.max(100, Number(retryBaseMs) || DEFAULT_RETRY_BASE_MS)
    this.retryMaxMs = Math.max(this.retryBaseMs, Number(retryMaxMs) || DEFAULT_RETRY_MAX_MS)
    this.retryAttempt = 0
    this.retryTimer = null

    const storePath = filePath ?? path.join(app.getPath('userData'), 'companion', 'devices.json')
    this.deviceStore = deviceStore ?? new CompanionDeviceStore({ filePath: storePath, safeStorage })
    const preferencePath = settingsPath ?? path.join(path.dirname(storePath), 'settings.json')
    this.preferenceStore = preferenceStore ?? new CompanionPreferenceStore({ filePath: preferencePath })
    this.desiredEnabled = this.preferenceStore.load({
      // Migration for builds that already paired a phone before the listener
      // preference existed: a trusted device means Companion was intentionally
      // enabled, so restore it automatically on the first upgraded launch.
      defaultEnabled: this.deviceStore.listDevices().length > 0,
    }).enabled
    this.stateHub = stateHub ?? gateway?.stateHub ?? new CompanionStateHub({ desktopState })
    this.gateway = gateway ?? new CompanionGateway({
      ...gatewayOptions,
      desktopId: this.deviceStore.desktopIdentity().id,
      stateHub: this.stateHub,
      // The provider is evaluated only after the listener is alive. This lets
      // already-paired phones learn a newly installed Tailscale route in the
      // authenticated hello without weakening or repeating pairing.
      transportHintProvider: () => this.transport?.pairingTransportHint?.(),
    })
    this.pairingManager = pairingManager ?? new CompanionPairingManager({ deviceStore: this.deviceStore, now })

    const transportOptions = {
      gateway: this.gateway,
      pairingManager: this.pairingManager,
      deviceStore: this.deviceStore,
      host: '0.0.0.0',
      port: DEFAULT_COMPANION_PORT,
      logger,
    }
    this.transport = transport
      ?? (typeof transportFactory === 'function' ? transportFactory(transportOptions) : new BonjourCompanionTransport(transportOptions))
    if (!this.transport?.enable || !this.transport?.disable || !this.transport?.status) {
      throw new Error('companion transport is invalid')
    }
    this.linkClient = linkClient ?? (linkOptions ? new KaisolaLinkClient({
      ...linkOptions,
      desktopId: this.deviceStore.desktopIdentity().id,
      acceptSocket: (socket) => this.transport.acceptSocket(socket),
      logger,
    }) : null)
    if (this.linkClient && (!this.transport.acceptSocket || !this.linkClient.enable || !this.linkClient.disable || !this.linkClient.status)) {
      throw new Error('Kaisola Link transport is invalid')
    }
    this.linkStateListener = () => this.#emitState()
    this.linkClient?.on?.('state', this.linkStateListener)
    this.storeListeners = new Map()
    for (const eventName of DEVICE_STORE_EVENTS) {
      const listener = () => this.#emitState()
      this.deviceStore.on?.(eventName, listener)
      this.storeListeners.set(eventName, listener)
    }
    this.transportListeners = {
      enabled: () => {
        this.enabled = true
        this.startFailed = false
        this.retryAttempt = 0
        this.#cancelRetry()
        this.#emitState()
      },
      disabled: () => {
        this.enabled = false
        this.#emitState()
        this.#scheduleRetry()
      },
      pairingPhrase: (event) => this.#pairingPhrase(event),
      pairingFailed: (event) => this.#pairingFailed(event),
      authenticated: (event) => this.#authenticated(event),
    }
    for (const [eventName, listener] of Object.entries(this.transportListeners)) this.transport.on?.(eventName, listener)
  }

  register(ipcMain) {
    if (!ipcMain?.handle) throw new Error('companion ipcMain dependency is invalid')
    if (this.ipcMain) throw new Error('companion handlers are already registered')
    this.ipcMain = ipcMain
    ipcMain.handle('companion:getState', () => this.getState())
    ipcMain.handle('companion:setEnabled', (_event, input) => this.setEnabled(input?.enabled ?? input))
    ipcMain.handle('companion:refresh', () => this.refresh())
    ipcMain.handle('companion:startPairing', (_event, input) => this.startPairing(input))
    ipcMain.handle('companion:confirmPairing', (_event, input) => this.confirmPairing(input?.pairingId ?? input))
    ipcMain.handle('companion:cancelPairing', (_event, input) => this.cancelPairing(input?.pairingId ?? input))
    ipcMain.handle('companion:revokeDevice', (_event, input) => this.revokeDevice(input?.deviceId ?? input))
    ipcMain.handle('companion:renameDevice', (_event, input) => this.renameDevice(input?.deviceId, input?.name))
    ipcMain.handle('companion:setDeviceCapabilities', (_event, input) => this.setDeviceCapabilities(input?.deviceId, input?.capabilities))
    return this
  }

  getState() {
    let transportStatus = null
    try { transportStatus = this.transport.status() } catch { /* fixed diagnostic below */ }
    let linkStatus = null
    try { linkStatus = this.linkClient?.status?.() ?? null } catch { /* fixed diagnostic below */ }
    const listening = this.enabled === true && transportStatus?.enabled === true
    const devices = this.deviceStore.listDevices().map((device) => ({
      deviceId: device.deviceId,
      name: displayName(device.displayName) ?? 'Kaisola Device',
      capabilities: CAPABILITIES.filter((capability) => device.capabilities.includes(capability)),
      pairedAt: device.pairedAt,
      ...(Number.isSafeInteger(device.lastSeenAt) ? { lastSeenAt: device.lastSeenAt } : {}),
      connected: this.deviceStore.isConnected?.(device.deviceId) === true,
    }))
    const connected = devices.reduce((count, device) => count + Number(device.connected), 0)
    const tailscaleAvailable = listening && transportStatus?.tailscaleAvailable === true
    const linkAvailable = linkStatus?.configured === true
    const linkConnected = linkStatus?.connected === true
    const linkReady = linkConnected && listening
    const linkPhase = ['off', 'connecting', 'ready', 'reconnecting', 'auth-required', 'unreachable', 'unavailable'].includes(linkStatus?.phase)
      ? linkStatus.phase
      : 'unavailable'
    let status
    if (!this.desiredEnabled) status = 'Companion is off. No local-network listener is running.'
    else if (connected > 0) status = `${connected} paired ${connected === 1 ? 'device is' : 'devices are'} connected.`
    else if (this.startFailed && linkAvailable) status = 'Kaisola Link and the local listener are reconnecting.'
    else if (linkReady) status = 'Ready nearby over LAN or away through Kaisola Link.'
    else if (tailscaleAvailable) status = 'Ready nearby over LAN or away through Tailscale.'
    else if (linkPhase === 'auth-required') status = 'Listening nearby. Sign in to use Kaisola Link away from this network.'
    else if (this.startFailed) status = 'Companion is reconnecting to the local network.'
    else if (!listening) status = 'Companion is starting on the local network.'
    else if (linkAvailable) status = 'Listening nearby; Kaisola Link is reconnecting automatically.'
    else status = 'Listening for paired devices on your local network.'
    return {
      enabled: this.desiredEnabled,
      listening,
      remote: this.linkClient ? {
        kind: 'kaisola-link',
        available: linkAvailable || tailscaleAvailable,
        linkAvailable,
        connected: linkReady,
        phase: linkPhase,
        tailscaleAvailable,
      } : { kind: 'tailscale', available: tailscaleAvailable },
      status,
      devices,
    }
  }

  async setEnabled(value) {
    if (typeof value !== 'boolean') throw new Error('Companion enabled state must be true or false.')
    return this.#enqueueTransition(async () => {
      if (this.disposed) return this.getState()
      this.preferenceStore.setEnabled(value)
      this.desiredEnabled = value
      this.#syncBackgroundLaunch()
      if (value) {
        await this.#startListening()
      } else {
        this.#cancelRetry()
        this.linkClient?.disable?.()
        this.enabled = false
        this.startFailed = false
        try { await this.transport.disable() } catch {
          try { this.logger.warn('[companion] local-network listener cleanup was incomplete') } catch { /* diagnostics are best-effort */ }
        }
        for (const pairingId of [...this.activePairings.keys()]) {
          if (!this.activePairings.has(pairingId)) continue
          this.#finishPairing(pairingId, {
            pairingId,
            phase: 'failed',
            message: 'Pairing stopped because Companion was turned off.',
          })
          this.pairingManager.cancelPairing?.(pairingId)
        }
      }
      const state = this.getState()
      this.#broadcast(STATE_CHANNEL, state)
      return state
    })
  }

  /** Restore the persisted listener intent after every launch/update. Pairing
   * keys and grants already survive in devices.json; this closes the former gap
   * where the listener itself silently reset to off. */
  async restore() {
    return this.#enqueueTransition(async () => {
      if (this.disposed) return this.getState()
      this.#syncBackgroundLaunch()
      if (this.desiredEnabled) await this.#startListening()
      return this.getState()
    })
  }

  /** Refresh Bonjour after wake or a network-interface change without dropping
   * an otherwise healthy authenticated phone connection. */
  async refresh() {
    return this.#enqueueTransition(async () => {
      if (this.disposed || !this.desiredEnabled) return this.getState()
      this.linkClient?.refresh?.()
      if (this.getState().listening && typeof this.transport.refresh === 'function') {
        try {
          await this.transport.refresh()
          this.startFailed = false
          return this.getState()
        } catch { /* fall through to a bounded listener restart */ }
      }
      await this.#startListening()
      return this.getState()
    })
  }

  async startPairing({ capabilities = CAPABILITIES } = {}) {
    await this.transition.catch(() => {})
    const state = this.getState()
    if (this.disposed || !state.listening) {
      throw new Error('Enable Companion before pairing a device.')
    }
    const requestedCapabilities = validateCapabilities(capabilities, { defaultObserve: true })
    const transportHint = this.transport.pairingTransportHint?.()
      ?? { service: '_kaisola._tcp', protocol: 'tcp' }
    const payload = this.pairingManager.createOffer({
      requestedCapabilities,
      transportHint,
      expiresInMs: this.pairingTtlMs,
    })
    const pairingId = payload.pairingNonce
    const record = {
      pairingId,
      phase: 'awaiting',
      expiresAt: payload.expiresAt,
      localConfirmed: false,
      timer: null,
    }
    const delay = Math.max(0, payload.expiresAt - this.now())
    record.timer = this.setTimer(() => {
      if (!this.activePairings.has(pairingId)) return
      this.transport.cancelPairing?.(pairingId, 'pairing_expired')
      this.pairingManager.cancelPairing?.(pairingId)
      this.#finishPairing(pairingId, {
        pairingId,
        phase: 'expired',
        message: 'Pairing code expired. Start a new pairing.',
      })
    }, delay)
    record.timer?.unref?.()
    this.activePairings.set(pairingId, record)
    this.#broadcast(PAIRING_CHANNEL, { pairingId, phase: 'awaiting' })
    this.#publishAccountOffer(record, payload)
    return { pairingId, qrPayload: JSON.stringify(payload), expiresAt: payload.expiresAt }
  }

  async confirmPairing(pairingId) {
    const id = String(pairingId ?? '')
    const record = this.activePairings.get(id)
    if (!record) return { ok: false, message: 'Pairing is no longer available.' }
    if (record.phase !== 'confirm') return { ok: false, message: 'Wait for the device to show the authentication phrase.' }
    if (record.localConfirmed) return { ok: true }
    let ok = false
    try { ok = this.transport.confirmPairing(id) === true } catch { ok = false }
    if (!ok) {
      this.#finishPairing(id, { pairingId: id, phase: 'failed', message: 'Pairing could not be confirmed. Try again.' })
      this.transport.cancelPairing?.(id, 'pairing_confirmation_failed')
      this.pairingManager.cancelPairing?.(id)
      return { ok: false, message: 'Pairing could not be confirmed. Try again.' }
    }
    record.localConfirmed = true
    return { ok: true }
  }

  async cancelPairing(pairingId) {
    const id = String(pairingId ?? '')
    const record = this.activePairings.get(id)
    if (!record) return { ok: false }
    this.activePairings.delete(id)
    if (record.timer) this.clearTimer(record.timer)
    this.#withdrawAccountOffer(record)
    try { this.transport.cancelPairing?.(id, 'pairing_cancelled') } catch { /* offer cancellation below remains authoritative */ }
    this.pairingManager.cancelPairing?.(id)
    return { ok: true }
  }

  async revokeDevice(deviceId) {
    try { this.deviceStore.revokeDevice(String(deviceId ?? '')) } catch {
      throw new Error('Device could not be revoked. Try again.')
    }
    const state = this.getState()
    this.#broadcast(STATE_CHANNEL, state)
    return state
  }

  async renameDevice(deviceId, name) {
    try {
      this.deviceStore.renameDevice(String(deviceId ?? ''), name)
    } catch (error) {
      if (error?.code === 'unknown_device') throw new Error('Device is no longer paired.')
      throw new Error('Enter a device name between 1 and 80 characters.')
    }
    const state = this.getState()
    this.#broadcast(STATE_CHANNEL, state)
    return state
  }

  async setDeviceCapabilities(deviceId, capabilities) {
    try {
      this.deviceStore.setCapabilities(String(deviceId ?? ''), capabilities)
    } catch (error) {
      if (error?.code === 'unknown_device') throw new Error('Device is no longer paired.')
      throw new Error('Choose a valid Companion access level.')
    }
    const state = this.getState()
    this.#broadcast(STATE_CHANNEL, state)
    return state
  }

  async dispose() {
    if (this.disposed) return false
    this.disposed = true
    this.#cancelRetry()
    for (const [pairingId, record] of this.activePairings) {
      if (record.timer) this.clearTimer(record.timer)
      this.#withdrawAccountOffer(record)
      this.pairingManager.cancelPairing?.(pairingId)
    }
    this.activePairings.clear()
    try { this.linkClient?.disable?.() } catch { /* link teardown is best-effort */ }
    try { await this.transport.disable() } catch { /* gateway disposal remains authoritative */ }
    for (const [eventName, listener] of this.storeListeners) this.deviceStore.off?.(eventName, listener)
    for (const [eventName, listener] of Object.entries(this.transportListeners)) this.transport.off?.(eventName, listener)
    this.linkClient?.off?.('state', this.linkStateListener)
    if (this.ipcMain?.removeHandler) for (const channel of HANDLER_CHANNELS) this.ipcMain.removeHandler(channel)
    await this.gateway.dispose?.()
    return true
  }

  #enqueueTransition(task) {
    const result = this.transition.catch(() => {}).then(task)
    this.transition = result.then(() => undefined, () => undefined)
    return result
  }

  async #startListening() {
    if (this.disposed || !this.desiredEnabled) return false
    this.#cancelRetry()
    this.linkClient?.enable?.()
    try {
      await this.transport.enable()
      this.enabled = this.transport.status()?.enabled === true
      this.startFailed = !this.enabled
    } catch {
      this.enabled = false
      this.startFailed = true
      try { await this.transport.disable() } catch { /* retry owns later recovery */ }
      try { this.logger.warn('[companion] local-network listener did not start; retrying') } catch { /* diagnostics are best-effort */ }
    }
    if (!this.enabled) this.#scheduleRetry()
    return this.enabled
  }

  #scheduleRetry() {
    if (this.disposed || !this.desiredEnabled || this.retryTimer) return false
    const delay = Math.min(this.retryMaxMs, this.retryBaseMs * (2 ** Math.min(this.retryAttempt, 6)))
    this.retryAttempt++
    this.retryTimer = this.setTimer(() => {
      this.retryTimer = null
      void this.restore()
    }, delay)
    this.retryTimer?.unref?.()
    return true
  }

  #cancelRetry() {
    if (!this.retryTimer) return false
    this.clearTimer(this.retryTimer)
    this.retryTimer = null
    return true
  }

  #syncBackgroundLaunch() {
    if (!this.setBackgroundLaunchEnabled) return
    try { this.setBackgroundLaunchEnabled(this.desiredEnabled) } catch {
      try { this.logger.warn('[companion] login launch setting could not be updated') } catch { /* best effort */ }
    }
  }

  #pairingPhrase(event) {
    const pairingId = String(event?.pairingId ?? '')
    const record = this.activePairings.get(pairingId)
    const sas = sasPhrase(event?.sas)
    if (!record || !sas) return
    record.phase = 'confirm'
    this.#broadcast(PAIRING_CHANNEL, {
      pairingId,
      phase: 'confirm',
      sas,
      ...(displayName(event?.device?.displayName) ? { deviceName: displayName(event.device.displayName) } : {}),
    })
  }

  #pairingFailed(event) {
    const pairingId = String(event?.pairingId ?? '')
    if (!this.activePairings.has(pairingId)) return
    this.#finishPairing(pairingId, {
      pairingId,
      phase: event?.reason === 'pairing_expired' ? 'expired' : 'failed',
      message: event?.reason === 'pairing_expired'
        ? 'Pairing code expired. Start a new pairing.'
        : pairingFailureMessage(event?.reason),
    })
  }

  #authenticated(event) {
    this.#emitState()
    if (event?.mode !== 'pair') return
    const pairingId = String(event?.pairingId ?? '')
    if (!this.activePairings.has(pairingId)) return
    const device = this.deviceStore.getDevice(event.deviceId)
    this.#finishPairing(pairingId, {
      pairingId,
      phase: 'paired',
      ...(displayName(device?.displayName) ? { deviceName: displayName(device.displayName) } : {}),
    })
  }

  #finishPairing(pairingId, event) {
    const record = this.activePairings.get(pairingId)
    if (!record) return false
    this.activePairings.delete(pairingId)
    if (record.timer) this.clearTimer(record.timer)
    this.#withdrawAccountOffer(record)
    this.#broadcast(PAIRING_CHANNEL, event)
    return true
  }

  #publishAccountOffer(record, payload) {
    if (!this.accountRendezvous?.publishOffer) return
    void Promise.resolve(this.accountRendezvous.publishOffer(payload)).then((published) => {
      if (!published) return
      const current = this.activePairings.get(record.pairingId)
      if (current === record) {
        record.accountPublished = true
        return
      }
      void Promise.resolve(this.accountRendezvous.withdrawOffer?.(record.pairingId)).catch(() => {})
    }).catch(() => {})
  }

  #withdrawAccountOffer(record) {
    if (!record?.accountPublished || !this.accountRendezvous?.withdrawOffer) return
    record.accountPublished = false
    void Promise.resolve(this.accountRendezvous.withdrawOffer(record.pairingId)).catch(() => {})
  }

  #emitState() {
    if (!this.disposed) this.#broadcast(STATE_CHANNEL, this.getState())
  }

  #broadcast(channel, payload) {
    if (this.disposed) return
    for (const win of this.BrowserWindow.getAllWindows()) {
      if (win?.isDestroyed?.() || win?.webContents?.isDestroyed?.()) continue
      try { win.webContents.send(channel, payload) } catch { /* another renderer receives the next state */ }
    }
  }
}

function registerCompanionHandlers(ipcMain, options) {
  return new CompanionHandler(options).register(ipcMain)
}

module.exports = {
  CompanionHandler,
  HANDLER_CHANNELS,
  PAIRING_CHANNEL,
  STATE_CHANNEL,
  registerCompanionHandlers,
}
