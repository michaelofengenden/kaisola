'use strict'

const crypto = require('node:crypto')
const {
  NOISE_PROTOCOL,
  NoiseXXResponder,
  PROTOCOL_VERSION,
  b64url,
  canonicalBytes,
  canonicalJson,
  createNoisePrologue,
  createSecureChannel,
  deriveSas,
  fromB64url,
  makeKeyConfirmation,
  verifyKeyConfirmation,
  verifySignedKeyRecord,
} = require('./crypto.cjs')
const { validateCapabilities } = require('./deviceStore.cjs')

const QR_TYPE = 'kaisola-companion-pairing'
const DEFAULT_PAIRING_TTL_MS = 2 * 60 * 1000
const MAX_PAIRING_TTL_MS = 5 * 60 * 1000
const DEFAULT_CLOCK_SKEW_MS = 30 * 1000
const HANDSHAKE_TIMEOUT_MS = 30 * 1000
const MAX_ACTIVE_HANDSHAKES = 8
const MAX_QR_BYTES = 16 * 1024

class CompanionPairingError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionPairingError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionPairingError(code, message)
}

function validateId(value, label) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$/.test(value)) fail('invalid_pairing_payload', `${label} is invalid`)
  return value
}

function normalizeTransportHint(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('invalid_pairing_payload', 'transportHint is invalid')
  const allowed = new Set(['service', 'protocol', 'host', 'port'])
  if (Object.keys(value).some((key) => !allowed.has(key))) fail('invalid_pairing_payload', 'transportHint is invalid')
  if (value.service !== '_kaisola._tcp' || value.protocol !== 'tcp') fail('invalid_pairing_payload', 'transportHint is invalid')
  const output = { service: value.service, protocol: value.protocol }
  if (value.host != null) {
    if (typeof value.host !== 'string' || value.host.length < 1 || value.host.length > 253 || /[\0\r\n]/.test(value.host)) fail('invalid_pairing_payload', 'transport host is invalid')
    output.host = value.host
  }
  if (value.port != null) {
    if (!Number.isSafeInteger(value.port) || value.port < 1 || value.port > 65535) fail('invalid_pairing_payload', 'transport port is invalid')
    output.port = value.port
  }
  return output
}

function pairingPayloadHash(payload) {
  return b64url(crypto.createHash('sha256').update(canonicalBytes(payload)).digest())
}

function pairingHandshakeContext(payload, connectionId) {
  return {
    v: PROTOCOL_VERSION,
    mode: 'pair',
    protocol: NOISE_PROTOCOL,
    desktopId: payload.desktopId,
    connectionId: validateId(connectionId, 'connectionId'),
    qrHash: pairingPayloadHash(payload),
  }
}

function resumeHandshakeContext({ desktopId, deviceId, connectionId }) {
  return {
    v: PROTOCOL_VERSION,
    mode: 'resume',
    protocol: NOISE_PROTOCOL,
    desktopId: validateId(desktopId, 'desktopId'),
    deviceId: validateId(deviceId, 'deviceId'),
    connectionId: validateId(connectionId, 'connectionId'),
  }
}

function validatePairingPayload(input, {
  now = Date.now(),
  clockSkewMs = DEFAULT_CLOCK_SKEW_MS,
  expectedDesktopId,
  expectedPayload,
} = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) fail('invalid_pairing_payload', 'pairing payload is invalid')
  const allowed = new Set([
    'type', 'protocolVersion', 'noiseProtocol', 'desktopId', 'identityPublic', 'keyRecord',
    'pairingNonce', 'requestedCapabilities', 'transportHint', 'expiresAt',
  ])
  if (Object.keys(input).some((key) => !allowed.has(key))) fail('invalid_pairing_payload', 'pairing payload is invalid')
  if (input.type !== QR_TYPE || input.protocolVersion !== PROTOCOL_VERSION || input.noiseProtocol !== NOISE_PROTOCOL) {
    fail('protocol_mismatch', 'pairing protocol is not supported')
  }
  const desktopId = validateId(input.desktopId, 'desktopId')
  if (expectedDesktopId && desktopId !== expectedDesktopId) fail('identity_mismatch', 'pairing payload names another desktop')
  const identityPublic = b64url(fromB64url(input.identityPublic, 32, 'identityPublic'))
  const keyRecord = verifySignedKeyRecord(input.keyRecord, identityPublic, { expectedRole: 'desktop', expectedId: desktopId })
  const pairingNonce = b64url(fromB64url(input.pairingNonce, 32, 'pairingNonce'))
  const requestedCapabilities = validateCapabilities(input.requestedCapabilities, { defaultObserve: true })
  const transportHint = normalizeTransportHint(input.transportHint)
  if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt < 0) fail('invalid_pairing_payload', 'pairing expiry is invalid')
  if (!Number.isSafeInteger(clockSkewMs) || clockSkewMs < 0 || now > input.expiresAt + clockSkewMs) fail('pairing_expired', 'pairing payload expired')
  const clean = {
    type: QR_TYPE,
    protocolVersion: PROTOCOL_VERSION,
    noiseProtocol: NOISE_PROTOCOL,
    desktopId,
    identityPublic,
    keyRecord,
    pairingNonce,
    requestedCapabilities,
    transportHint,
    expiresAt: input.expiresAt,
  }
  if (canonicalBytes(clean).length > MAX_QR_BYTES) fail('pairing_payload_too_large', 'pairing payload is too large')
  if (expectedPayload && canonicalJson(clean) !== canonicalJson(expectedPayload)) fail('pairing_offer_mismatch', 'pairing payload does not match its single-use offer')
  return clean
}

function sasConfirmationPayload(role, handshakeHash) {
  if (role !== 'desktop' && role !== 'device') fail('role_mismatch', 'SAS confirmation role is invalid')
  return { type: 'sas-confirm', role, transcriptHash: b64url(handshakeHash) }
}

class CompanionPairingManager {
  constructor({ deviceStore, now = Date.now, randomBytes = crypto.randomBytes, randomUUID = crypto.randomUUID } = {}) {
    if (!deviceStore || typeof deviceStore.desktopIdentity !== 'function' || typeof deviceStore.pairDevice !== 'function') {
      fail('device_store_required', 'device store is required')
    }
    this.deviceStore = deviceStore
    this.now = now
    this.randomBytes = randomBytes
    this.randomUUID = randomUUID
    this.offers = new Map()
    this.sessions = new Map()
  }

  createOffer({
    requestedCapabilities = ['observe'],
    transportHint = { service: '_kaisola._tcp', protocol: 'tcp' },
    expiresInMs = DEFAULT_PAIRING_TTL_MS,
    replaceDeviceId = null,
  } = {}) {
    if (!Number.isSafeInteger(expiresInMs) || expiresInMs < 1 || expiresInMs > MAX_PAIRING_TTL_MS) {
      fail('invalid_expiry', 'pairing expiry is invalid')
    }
    if (replaceDeviceId != null && !this.deviceStore.getDevice(validateId(replaceDeviceId, 'replaceDeviceId'))) {
      fail('unknown_device', 'replacement device is not paired')
    }
    this.prune()
    const desktop = this.deviceStore.desktopIdentity()
    const payload = validatePairingPayload({
      type: QR_TYPE,
      protocolVersion: PROTOCOL_VERSION,
      noiseProtocol: NOISE_PROTOCOL,
      desktopId: desktop.id,
      identityPublic: desktop.identityPublic,
      keyRecord: desktop.keyRecord,
      pairingNonce: b64url(this.randomBytes(32)),
      requestedCapabilities: validateCapabilities(requestedCapabilities, { defaultObserve: true }),
      transportHint: normalizeTransportHint(transportHint),
      expiresAt: this.now() + expiresInMs,
    }, { now: this.now(), clockSkewMs: 0, expectedDesktopId: desktop.id })
    this.offers.set(payload.pairingNonce, { payload, replaceDeviceId, expiresAt: payload.expiresAt })
    return JSON.parse(JSON.stringify(payload))
  }

  startPairing({ qrPayload, connectionId, message1 } = {}) {
    this.prune()
    if (this.sessions.size >= MAX_ACTIVE_HANDSHAKES) fail('server_busy', 'too many pairing handshakes')
    const desktop = this.deviceStore.desktopIdentity()
    const clean = validatePairingPayload(qrPayload, { now: this.now(), clockSkewMs: 0, expectedDesktopId: desktop.id })
    const offer = this.offers.get(clean.pairingNonce)
    if (!offer) fail('pairing_offer_unavailable', 'pairing offer is unavailable')
    this.offers.delete(clean.pairingNonce) // Claim before any DH work: every QR is single-use, including malformed attempts.
    validatePairingPayload(clean, { now: this.now(), clockSkewMs: 0, expectedDesktopId: desktop.id, expectedPayload: offer.payload })
    const handshakeContext = pairingHandshakeContext(clean, connectionId)
    const responder = new NoiseXXResponder({ identity: desktop, prologue: createNoisePrologue(handshakeContext) })
    responder.readMessage1(message1)
    const sessionId = `pair-${this.randomUUID()}`
    this.sessions.set(sessionId, {
      sessionId,
      kind: 'pair',
      state: 'awaiting_message_3',
      expiresAt: Math.min(clean.expiresAt, this.now() + HANDSHAKE_TIMEOUT_MS),
      responder,
      handshakeContext,
      requestedCapabilities: clean.requestedCapabilities,
      replaceDeviceId: offer.replaceDeviceId,
      localSasConfirmed: false,
      remoteSasConfirmed: false,
      remoteKeyConfirmed: false,
      completed: false,
    })
    return { sessionId, message2: b64url(responder.writeMessage2()) }
  }

  startResume({ deviceId, connectionId, message1 } = {}) {
    this.prune()
    if (this.sessions.size >= MAX_ACTIVE_HANDSHAKES) fail('server_busy', 'too many companion handshakes')
    const requestedDeviceId = validateId(deviceId, 'deviceId')
    const storedRecord = this.deviceStore.getDevice(requestedDeviceId)
    // Unknown ids still receive the same bounded XX message-2 work. The random
    // pin makes message 3 fail indistinguishably instead of exposing a paired-id
    // membership oracle from the first response or its timing.
    const record = storedRecord ?? {
      deviceId: requestedDeviceId,
      identityPublic: b64url(this.randomBytes(32)),
      x25519StaticPublic: b64url(this.randomBytes(32)),
    }
    const desktop = this.deviceStore.desktopIdentity()
    const handshakeContext = resumeHandshakeContext({ desktopId: desktop.id, deviceId: record.deviceId, connectionId })
    const responder = new NoiseXXResponder({
      identity: desktop,
      prologue: createNoisePrologue(handshakeContext),
      peerPin: { id: record.deviceId, identityPublic: record.identityPublic, x25519StaticPublic: record.x25519StaticPublic },
    })
    responder.readMessage1(message1)
    const sessionId = `resume-${this.randomUUID()}`
    this.sessions.set(sessionId, {
      sessionId,
      kind: 'resume',
      state: 'awaiting_message_3',
      expiresAt: this.now() + HANDSHAKE_TIMEOUT_MS,
      responder,
      handshakeContext,
      deviceRecord: record,
      knownDevice: !!storedRecord,
      remoteKeyConfirmed: false,
      completed: false,
    })
    return { sessionId, message2: b64url(responder.writeMessage2()) }
  }

  #session(sessionId, kind) {
    this.prune()
    const session = this.sessions.get(String(sessionId))
    if (!session || (kind && session.kind !== kind)) fail('handshake_unavailable', 'companion handshake is unavailable')
    return session
  }

  completeHandshake(sessionId, message3) {
    const session = this.#session(sessionId)
    if (session.state !== 'awaiting_message_3') fail('handshake_order', 'handshake message is out of order')
    const peer = session.responder.readMessage3(message3)
    const result = session.responder.result()
    if (session.kind === 'resume' && (!session.knownDevice || peer.id !== session.deviceRecord.deviceId)) fail('authentication_failed', 'companion authentication failed')
    if (session.kind === 'pair') {
      if (session.replaceDeviceId && peer.id !== session.replaceDeviceId) fail('identity_mismatch', 're-pair identity does not match the selected device')
      if (!session.replaceDeviceId && this.deviceStore.getDevice(peer.id)) fail('device_exists', 'device is already paired; use an explicit re-pair offer')
      session.pendingDevice = {
        deviceId: peer.id,
        displayName: peer.displayName,
        identityPublic: peer.identityPublic,
        x25519StaticPublic: peer.x25519StaticPublic,
        capabilities: session.requestedCapabilities,
        pairedAt: this.now(),
        lastSeenAt: this.now(),
      }
    }
    const context = {
      desktopId: session.handshakeContext.desktopId,
      deviceId: peer.id,
      connectionId: session.handshakeContext.connectionId,
    }
    session.peer = peer
    session.handshakeResult = result
    session.channel = createSecureChannel(result, context, 'desktop')
    session.sas = deriveSas(result.handshakeHash)
    session.state = session.kind === 'pair' ? 'awaiting_pairing_confirmation' : 'awaiting_key_confirmation'
    session.desktopConfirmationFrame = makeKeyConfirmation(session.channel, 'desktop', result.handshakeHash)
    return {
      kind: session.kind,
      device: { id: peer.id, displayName: peer.displayName },
      confirmationFrame: session.desktopConfirmationFrame,
      ...(session.kind === 'pair' ? { sas: session.sas } : {}),
    }
  }

  receiveKeyConfirmation(sessionId, frame) {
    const session = this.#session(sessionId)
    if (!session.channel || session.remoteKeyConfirmed) fail('handshake_order', 'key confirmation is out of order')
    verifyKeyConfirmation(session.channel, frame, 'device', session.handshakeResult.handshakeHash)
    session.remoteKeyConfirmed = true
    if (session.kind === 'resume') {
      session.state = 'authenticated'
      session.completed = true
      this.deviceStore.markSeen(session.peer.id)
    }
    return { authenticated: session.kind === 'resume', sasRequired: session.kind === 'pair' }
  }

  confirmLocalSas(sessionId) {
    const session = this.#session(sessionId, 'pair')
    if (!session.channel || !session.remoteKeyConfirmed) fail('handshake_order', 'SAS confirmation requires key confirmation first')
    if (!session.localSasConfirmed) {
      session.localSasConfirmed = true
      session.desktopSasFrame = session.channel.encrypt(sasConfirmationPayload('desktop', session.handshakeResult.handshakeHash))
    }
    const pairedFrame = this.#finalizePairing(session)
    return { sasFrame: session.desktopSasFrame, paired: session.completed, pairedFrame }
  }

  receiveRemoteSasConfirmation(sessionId, frame) {
    const session = this.#session(sessionId, 'pair')
    if (!session.channel || !session.remoteKeyConfirmed || session.remoteSasConfirmed) fail('handshake_order', 'SAS confirmation is out of order')
    const payload = session.channel.decrypt(frame, { json: true })
    if (canonicalJson(payload) !== canonicalJson(sasConfirmationPayload('device', session.handshakeResult.handshakeHash))) {
      fail('sas_confirmation_failed', 'SAS confirmation failed')
    }
    session.remoteSasConfirmed = true
    const pairedFrame = this.#finalizePairing(session)
    return { paired: session.completed, pairedFrame }
  }

  #finalizePairing(session) {
    if (session.completed || !session.localSasConfirmed || !session.remoteSasConfirmed || !session.remoteKeyConfirmed) return session.pairedFrame ?? null
    const record = this.deviceStore.pairDevice(session.pendingDevice, { replace: !!session.replaceDeviceId })
    session.completed = true
    session.state = 'authenticated'
    session.deviceRecord = record
    session.pairedFrame = session.channel.encrypt({
      type: 'paired',
      deviceId: record.deviceId,
      capabilities: record.capabilities,
      transcriptHash: b64url(session.handshakeResult.handshakeHash),
    })
    return session.pairedFrame
  }

  authenticatedConnection(sessionId) {
    const session = this.#session(sessionId)
    if (!session.completed || session.state !== 'authenticated') fail('authentication_incomplete', 'companion authentication is incomplete')
    return {
      kind: session.kind,
      device: this.deviceStore.getDevice(session.peer.id),
      channel: session.channel,
      handshakeHash: Buffer.from(session.handshakeResult.handshakeHash),
      connectionId: session.handshakeContext.connectionId,
    }
  }

  releaseSession(sessionId) {
    return this.sessions.delete(String(sessionId))
  }

  prune() {
    const now = this.now()
    for (const [nonce, offer] of this.offers) if (now > offer.expiresAt) this.offers.delete(nonce)
    for (const [sessionId, session] of this.sessions) if (now > session.expiresAt && !session.completed) this.sessions.delete(sessionId)
  }

  stats() {
    this.prune()
    return {
      offers: this.offers.size,
      sessions: this.sessions.size,
      authenticated: [...this.sessions.values()].filter((session) => session.completed).length,
    }
  }
}

module.exports = {
  CompanionPairingError,
  CompanionPairingManager,
  DEFAULT_CLOCK_SKEW_MS,
  DEFAULT_PAIRING_TTL_MS,
  HANDSHAKE_TIMEOUT_MS,
  MAX_ACTIVE_HANDSHAKES,
  MAX_PAIRING_TTL_MS,
  MAX_QR_BYTES,
  QR_TYPE,
  normalizeTransportHint,
  pairingHandshakeContext,
  pairingPayloadHash,
  resumeHandshakeContext,
  sasConfirmationPayload,
  validatePairingPayload,
}
