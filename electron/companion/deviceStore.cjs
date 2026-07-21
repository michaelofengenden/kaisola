'use strict'

const { EventEmitter } = require('node:events')
const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const {
  createIdentity,
  exportPrivatePkcs8,
  exportPublicB64,
  privateKeyFromPkcs8,
  verifySignedKeyRecord,
} = require('./crypto.cjs')
const { IDENTIFIER_RE } = require('./protocol.cjs')

const STORE_VERSION = 1
const MAX_STORE_BYTES = 1024 * 1024
const MAX_PAIRED_DEVICES = 64
const CAPABILITIES = Object.freeze(['observe', 'agent-control', 'terminal-control'])
const CAPABILITY_SET = new Set(CAPABILITIES)

class CompanionDeviceStoreError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionDeviceStoreError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionDeviceStoreError(code, message)
}

function validateId(value, label) {
  if (typeof value !== 'string' || !IDENTIFIER_RE.test(value)) fail('invalid_record', `${label} is invalid`)
  return value
}

function validateCapabilities(value, { defaultObserve = false } = {}) {
  const capabilities = value == null && defaultObserve ? ['observe'] : value
  if (!Array.isArray(capabilities) || capabilities.length < 1 || capabilities.length > CAPABILITIES.length) {
    fail('invalid_capabilities', 'device capabilities are invalid')
  }
  const unique = new Set()
  for (const capability of capabilities) {
    if (!CAPABILITY_SET.has(capability) || unique.has(capability)) fail('invalid_capabilities', 'device capabilities are invalid')
    unique.add(capability)
  }
  if (!unique.has('observe')) fail('invalid_capabilities', 'observe capability is required')
  return CAPABILITIES.filter((capability) => unique.has(capability))
}

function validatePublic(value, label) {
  if (typeof value !== 'string' || Buffer.from(value, 'base64url').length !== 32 || Buffer.from(value, 'base64url').toString('base64url') !== value) {
    fail('invalid_record', `${label} is invalid`)
  }
  return value
}

function cleanDeviceRecord(input, now) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) fail('invalid_record', 'device record is invalid')
  const deviceId = validateId(input.deviceId, 'deviceId')
  const identityPublic = validatePublic(input.identityPublic, 'identityPublic')
  const x25519StaticPublic = validatePublic(input.x25519StaticPublic, 'x25519StaticPublic')
  const pairedAt = Number.isSafeInteger(input.pairedAt) && input.pairedAt >= 0 ? input.pairedAt : now
  const lastSeenAt = Number.isSafeInteger(input.lastSeenAt) && input.lastSeenAt >= pairedAt ? input.lastSeenAt : pairedAt
  return {
    deviceId,
    displayName: typeof input.displayName === 'string' && input.displayName.trim() ? input.displayName.trim().slice(0, 80) : 'Kaisola Device',
    identityPublic,
    x25519StaticPublic,
    capabilities: validateCapabilities(input.capabilities, { defaultObserve: true }),
    pairedAt,
    lastSeenAt,
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

class CompanionDeviceStore extends EventEmitter {
  constructor({ filePath, safeStorage, now = Date.now, randomUUID = crypto.randomUUID, identityFactory } = {}) {
    super()
    if (typeof filePath !== 'string' || !path.isAbsolute(filePath)) fail('invalid_path', 'device store path must be absolute')
    if (!safeStorage || typeof safeStorage.isEncryptionAvailable !== 'function'
      || typeof safeStorage.encryptString !== 'function' || typeof safeStorage.decryptString !== 'function') {
      fail('safe_storage_required', 'Electron safeStorage is required')
    }
    if (!safeStorage.isEncryptionAvailable()) fail('safe_storage_unavailable', 'Electron safeStorage is unavailable')
    this.filePath = filePath
    this.safeStorage = safeStorage
    this.now = now
    this.randomUUID = randomUUID
    this.identityFactory = identityFactory
    this.devices = new Map()
    this.connections = new Map()
    this.identity = null
    this.#loadOrCreate()
  }

  #protect(privateKey) {
    const plaintext = exportPrivatePkcs8(privateKey).toString('base64')
    const encrypted = this.safeStorage.encryptString(plaintext)
    if (!Buffer.isBuffer(encrypted) || encrypted.length < 1) fail('safe_storage_failed', 'safeStorage did not protect the private key')
    return encrypted.toString('base64')
  }

  #unprotect(value, type) {
    try {
      const encrypted = Buffer.from(value, 'base64')
      if (!encrypted.length || encrypted.toString('base64') !== value) fail('invalid_store', 'protected private key is invalid')
      const plaintext = this.safeStorage.decryptString(encrypted)
      return privateKeyFromPkcs8(type, Buffer.from(plaintext, 'base64'))
    } catch (error) {
      if (error instanceof CompanionDeviceStoreError) throw error
      fail('safe_storage_failed', 'safeStorage could not unlock the desktop identity')
    }
  }

  #createDesktopIdentity() {
    if (this.identityFactory) return this.identityFactory()
    return createIdentity({ id: `desktop-${this.randomUUID()}`, role: 'desktop', displayName: 'Kaisola Desktop' })
  }

  #loadOrCreate() {
    let parsed = null
    try {
      const stat = fs.statSync(this.filePath)
      if (stat.size < 1 || stat.size > MAX_STORE_BYTES) fail('invalid_store', 'device store is invalid')
      parsed = JSON.parse(fs.readFileSync(this.filePath, 'utf8'))
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        if (error instanceof CompanionDeviceStoreError) throw error
        fail('invalid_store', 'device store is invalid')
      }
    }
    if (!parsed) {
      this.identity = this.#createDesktopIdentity()
      if (this.identity?.role !== 'desktop') fail('invalid_identity', 'desktop identity factory returned the wrong role')
      this.#persist()
      return
    }
    if (parsed.v !== STORE_VERSION || !parsed.desktop || !parsed.protectedPrivate || !Array.isArray(parsed.devices)) {
      fail('invalid_store', 'device store is invalid')
    }
    const identityPrivateKey = this.#unprotect(parsed.protectedPrivate.ed25519, 'ed25519')
    const staticPrivateKey = this.#unprotect(parsed.protectedPrivate.x25519, 'x25519')
    const identity = createIdentity({
      id: validateId(parsed.desktop.desktopId, 'desktopId'),
      role: 'desktop',
      displayName: parsed.desktop.displayName,
      identityKeyPair: { privateKey: identityPrivateKey, publicKey: crypto.createPublicKey(identityPrivateKey) },
      staticKeyPair: { privateKey: staticPrivateKey, publicKey: crypto.createPublicKey(staticPrivateKey) },
    })
    if (identity.identityPublic !== parsed.desktop.identityPublic || identity.x25519StaticPublic !== parsed.desktop.x25519StaticPublic) {
      fail('invalid_store', 'desktop public keys do not match protected private keys')
    }
    verifySignedKeyRecord(parsed.desktop.keyRecord, identity.identityPublic, { expectedRole: 'desktop', expectedId: identity.id })
    if (parsed.desktop.keyRecord.x25519StaticPublic !== identity.x25519StaticPublic) fail('invalid_store', 'desktop key record does not match the protected private key')
    identity.keyRecord = clone(parsed.desktop.keyRecord)
    this.identity = identity
    for (const record of parsed.devices) {
      const clean = cleanDeviceRecord(record, this.now())
      if (this.devices.has(clean.deviceId)) fail('invalid_store', 'device store contains a duplicate device')
      this.devices.set(clean.deviceId, clean)
    }
  }

  #persist() {
    const payload = {
      v: STORE_VERSION,
      desktop: {
        desktopId: this.identity.id,
        displayName: this.identity.displayName,
        identityPublic: this.identity.identityPublic,
        x25519StaticPublic: this.identity.x25519StaticPublic,
        keyRecord: this.identity.keyRecord,
      },
      protectedPrivate: {
        ed25519: this.#protect(this.identity.identityPrivateKey),
        x25519: this.#protect(this.identity.x25519StaticPrivateKey),
      },
      devices: [...this.devices.values()].sort((left, right) => left.deviceId.localeCompare(right.deviceId)),
    }
    const encoded = JSON.stringify(payload)
    if (Buffer.byteLength(encoded, 'utf8') > MAX_STORE_BYTES) fail('store_too_large', 'device store exceeds its size limit')
    fs.mkdirSync(path.dirname(this.filePath), { recursive: true, mode: 0o700 })
    const temporary = `${this.filePath}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`
    try {
      fs.writeFileSync(temporary, encoded, { mode: 0o600, flag: 'wx' })
      fs.renameSync(temporary, this.filePath)
      try { fs.chmodSync(this.filePath, 0o600) } catch { /* best effort on non-POSIX filesystems */ }
    } finally {
      try { fs.unlinkSync(temporary) } catch { /* renamed or never created */ }
    }
  }

  desktopIdentity() {
    return this.identity
  }

  desktopPublicRecord() {
    return clone({
      desktopId: this.identity.id,
      displayName: this.identity.displayName,
      identityPublic: this.identity.identityPublic,
      x25519StaticPublic: this.identity.x25519StaticPublic,
      keyRecord: this.identity.keyRecord,
    })
  }

  listDevices() {
    return [...this.devices.values()].map(clone).sort((left, right) => left.displayName.localeCompare(right.displayName) || left.deviceId.localeCompare(right.deviceId))
  }

  getDevice(deviceId) {
    const record = this.devices.get(String(deviceId))
    return record ? clone(record) : null
  }

  pairDevice(record, { replace = false } = {}) {
    const clean = cleanDeviceRecord(record, this.now())
    const existing = this.devices.get(clean.deviceId)
    if (existing && !replace) fail('device_exists', 'device is already paired')
    if (!existing && this.devices.size >= MAX_PAIRED_DEVICES) fail('device_limit', 'paired device limit reached')
    this.devices.set(clean.deviceId, clean)
    try { this.#persist() } catch (error) {
      if (existing) this.devices.set(clean.deviceId, existing)
      else this.devices.delete(clean.deviceId)
      throw error
    }
    if (existing) this.#closeConnections(clean.deviceId, 'device_repaired')
    this.emit(existing ? 'repaired' : 'paired', clone(clean))
    return clone(clean)
  }

  setCapabilities(deviceId, capabilities) {
    const existing = this.devices.get(String(deviceId))
    if (!existing) fail('unknown_device', 'device is not paired')
    const next = { ...existing, capabilities: validateCapabilities(capabilities) }
    this.devices.set(next.deviceId, next)
    try { this.#persist() } catch (error) { this.devices.set(existing.deviceId, existing); throw error }
    // A live gateway session holds the capabilities negotiated in its hello.
    // Reconnect immediately so narrowing is instant and widening cannot take
    // effect without a fresh authenticated negotiation.
    this.#closeConnections(next.deviceId, 'device_capabilities_changed')
    this.emit('capabilities', clone(next))
    return clone(next)
  }

  renameDevice(deviceId, displayName) {
    const existing = this.devices.get(String(deviceId))
    if (!existing) fail('unknown_device', 'device is not paired')
    if (typeof displayName !== 'string') fail('invalid_name', 'device name is invalid')
    const name = displayName.trim()
    if (!name || name.length > 80 || /[\0-\x1f\x7f]/.test(name)) fail('invalid_name', 'device name is invalid')
    if (name === existing.displayName) return clone(existing)
    const next = { ...existing, displayName: name }
    this.devices.set(next.deviceId, next)
    try { this.#persist() } catch (error) { this.devices.set(existing.deviceId, existing); throw error }
    this.emit('renamed', clone(next))
    return clone(next)
  }

  markSeen(deviceId) {
    const existing = this.devices.get(String(deviceId))
    if (!existing) return false
    const next = { ...existing, lastSeenAt: Math.max(existing.lastSeenAt, this.now()) }
    this.devices.set(next.deviceId, next)
    try { this.#persist() } catch (error) { this.devices.set(existing.deviceId, existing); throw error }
    this.emit('seen', clone(next))
    return true
  }

  registerConnection(deviceId, close) {
    const id = String(deviceId)
    if (!this.devices.has(id)) fail('unknown_device', 'device is not paired')
    if (typeof close !== 'function') fail('invalid_connection', 'connection close callback is invalid')
    const token = Symbol(id)
    let records = this.connections.get(id)
    if (!records) { records = new Map(); this.connections.set(id, records) }
    records.set(token, close)
    if (records.size === 1) this.emit('connected', { deviceId: id })
    return () => {
      const current = this.connections.get(id)
      if (!current) return false
      const deleted = current.delete(token)
      if (!current.size) {
        this.connections.delete(id)
        if (deleted) this.emit('disconnected', { deviceId: id })
      }
      return deleted
    }
  }

  isConnected(deviceId) {
    return (this.connections.get(String(deviceId))?.size ?? 0) > 0
  }

  #closeConnections(deviceId, reason) {
    const records = this.connections.get(deviceId)
    this.connections.delete(deviceId)
    if (!records) return 0
    let closed = 0
    for (const close of records.values()) {
      try { close(reason); closed++ } catch { /* revocation remains authoritative */ }
    }
    this.emit('disconnected', { deviceId })
    return closed
  }

  revokeDevice(deviceId) {
    const id = String(deviceId)
    const existing = this.devices.get(id)
    if (!existing) return false
    this.devices.delete(id)
    try { this.#persist() } catch (error) { this.devices.set(id, existing); throw error }
    const closedConnections = this.#closeConnections(id, 'device_revoked')
    this.emit('revoked', { deviceId: id, closedConnections })
    return true
  }

  stats() {
    return {
      desktopId: this.identity.id,
      devices: this.devices.size,
      liveConnections: [...this.connections.values()].reduce((total, records) => total + records.size, 0),
      encryptionAvailable: this.safeStorage.isEncryptionAvailable(),
    }
  }
}

module.exports = {
  CAPABILITIES,
  CompanionDeviceStore,
  CompanionDeviceStoreError,
  MAX_PAIRED_DEVICES,
  MAX_STORE_BYTES,
  STORE_VERSION,
  validateCapabilities,
}
