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
const { BonjourCompanionTransport } = require('../companion/bonjourTransport.cjs')
const { CompanionGateway } = require('../companion/gateway.cjs')
const { CompanionStateHub } = require('../companion/stateHub.cjs')

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
  'companion:startPairing',
  'companion:confirmPairing',
  'companion:cancelPairing',
  'companion:revokeDevice',
  'companion:renameDevice',
])

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
    deviceStore,
    pairingManager,
    stateHub,
    gateway,
    transport,
    transportFactory,
    now = Date.now,
    pairingTtlMs = DEFAULT_PAIRING_TTL_MS,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
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
    this.enabled = false
    this.startFailed = false
    this.disposed = false
    this.transition = Promise.resolve()
    this.activePairings = new Map()
    this.ipcMain = null

    const storePath = filePath ?? path.join(app.getPath('userData'), 'companion', 'devices.json')
    this.deviceStore = deviceStore ?? new CompanionDeviceStore({ filePath: storePath, safeStorage })
    this.stateHub = stateHub ?? gateway?.stateHub ?? new CompanionStateHub({ desktopState })
    this.gateway = gateway ?? new CompanionGateway({
      ...gatewayOptions,
      desktopId: this.deviceStore.desktopIdentity().id,
      stateHub: this.stateHub,
    })
    this.pairingManager = pairingManager ?? new CompanionPairingManager({ deviceStore: this.deviceStore, now })

    const transportOptions = {
      gateway: this.gateway,
      pairingManager: this.pairingManager,
      deviceStore: this.deviceStore,
      host: '0.0.0.0',
      port: 0,
      logger,
    }
    this.transport = transport
      ?? (typeof transportFactory === 'function' ? transportFactory(transportOptions) : new BonjourCompanionTransport(transportOptions))
    if (!this.transport?.enable || !this.transport?.disable || !this.transport?.status) {
      throw new Error('companion transport is invalid')
    }

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
        this.#emitState()
      },
      disabled: () => {
        this.enabled = false
        this.#emitState()
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
    ipcMain.handle('companion:startPairing', (_event, input) => this.startPairing(input))
    ipcMain.handle('companion:confirmPairing', (_event, input) => this.confirmPairing(input?.pairingId ?? input))
    ipcMain.handle('companion:cancelPairing', (_event, input) => this.cancelPairing(input?.pairingId ?? input))
    ipcMain.handle('companion:revokeDevice', (_event, input) => this.revokeDevice(input?.deviceId ?? input))
    ipcMain.handle('companion:renameDevice', (_event, input) => this.renameDevice(input?.deviceId, input?.name))
    return this
  }

  getState() {
    let transportStatus = null
    try { transportStatus = this.transport.status() } catch { /* fixed diagnostic below */ }
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
    let status
    if (this.startFailed) status = 'Companion could not start on the local network.'
    else if (!this.enabled) status = 'Companion is off. No local-network listener is running.'
    else if (!listening) status = 'Companion is starting on the local network.'
    else if (connected === 0) status = 'Listening for paired devices on your local network.'
    else status = `${connected} paired ${connected === 1 ? 'device is' : 'devices are'} connected.`
    return { enabled: this.enabled, listening, status, devices }
  }

  async setEnabled(value) {
    if (typeof value !== 'boolean') throw new Error('Companion enabled state must be true or false.')
    return this.#enqueueTransition(async () => {
      if (this.disposed) return this.getState()
      if (value) {
        try {
          await this.transport.enable()
          this.enabled = this.transport.status()?.enabled === true
          this.startFailed = !this.enabled
        } catch (error) {
          this.enabled = false
          this.startFailed = true
          try { await this.transport.disable() } catch { /* a failed start remains off */ }
          try { this.logger.warn('[companion] local-network listener did not start') } catch { /* diagnostics are best-effort */ }
        }
      } else {
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

  async startPairing({ capabilities = ['observe'] } = {}) {
    await this.transition.catch(() => {})
    if (this.disposed || !this.getState().listening) throw new Error('Enable Companion before pairing a device.')
    const requestedCapabilities = validateCapabilities(capabilities, { defaultObserve: true })
    const payload = this.pairingManager.createOffer({
      requestedCapabilities,
      transportHint: { service: '_kaisola._tcp', protocol: 'tcp' },
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

  async dispose() {
    if (this.disposed) return false
    this.disposed = true
    for (const [pairingId, record] of this.activePairings) {
      if (record.timer) this.clearTimer(record.timer)
      this.pairingManager.cancelPairing?.(pairingId)
    }
    this.activePairings.clear()
    try { await this.transport.disable() } catch { /* gateway disposal remains authoritative */ }
    for (const [eventName, listener] of this.storeListeners) this.deviceStore.off?.(eventName, listener)
    for (const [eventName, listener] of Object.entries(this.transportListeners)) this.transport.off?.(eventName, listener)
    if (this.ipcMain?.removeHandler) for (const channel of HANDLER_CHANNELS) this.ipcMain.removeHandler(channel)
    await this.gateway.dispose?.()
    return true
  }

  #enqueueTransition(task) {
    const result = this.transition.catch(() => {}).then(task)
    this.transition = result.then(() => undefined, () => undefined)
    return result
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
    this.#broadcast(PAIRING_CHANNEL, event)
    return true
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
