'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const { CompanionDeviceStore } = require('./deviceStore.cjs')
const {
  NoiseXXInitiator,
  b64url,
  createNoisePrologue,
  createSecureChannel,
  deriveSas,
  identityFromSeeds,
  makeKeyConfirmation,
  verifyKeyConfirmation,
} = require('./crypto.cjs')
const {
  CompanionPairingManager,
  pairingHandshakeContext,
  resumeHandshakeContext,
  sasConfirmationPayload,
  validatePairingPayload,
} = require('./pairing.cjs')

function safeStorage() {
  return {
    isEncryptionAvailable: () => true,
    encryptString: (value) => Buffer.from(`protected:${Buffer.from(value).toString('base64')}`),
    decryptString: (value) => Buffer.from(value.toString().slice('protected:'.length), 'base64').toString(),
  }
}

function setup(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-pairing-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  let now = 1_784_250_001_000
  let randomCounter = 0
  const desktop = identityFromSeeds({
    id: 'desktop-pairing-test',
    role: 'desktop',
    displayName: 'Michael Mac',
    identitySeed: Buffer.alloc(32, 51),
    staticSeed: Buffer.alloc(32, 52),
  })
  const filePath = path.join(directory, 'devices.json')
  const store = new CompanionDeviceStore({ filePath, safeStorage: safeStorage(), identityFactory: () => desktop, now: () => now })
  const manager = new CompanionPairingManager({
    deviceStore: store,
    now: () => now,
    randomBytes: (size) => Buffer.alloc(size, 100 + (++randomCounter)),
    randomUUID: () => `00000000-0000-4000-8000-${String(++randomCounter).padStart(12, '0')}`,
  })
  return { directory, filePath, desktop, store, manager, now: () => now, setNow: (value) => { now = value } }
}

function phoneIdentity(seed = 61, deviceId = 'device-pairing-test') {
  return identityFromSeeds({
    id: deviceId,
    role: 'device',
    displayName: "Michael's iPhone",
    identitySeed: Buffer.alloc(32, seed),
    staticSeed: Buffer.alloc(32, seed + 1),
  })
}

function finishPairing({ manager, payload, phone, connectionId = 'connection-pairing-1' }) {
  const handshakeContext = pairingHandshakeContext(payload, connectionId)
  const initiator = new NoiseXXInitiator({
    identity: phone,
    prologue: createNoisePrologue(handshakeContext),
    peerPin: {
      id: payload.desktopId,
      identityPublic: payload.identityPublic,
      x25519StaticPublic: payload.keyRecord.x25519StaticPublic,
    },
  })
  const started = manager.startPairing({ qrPayload: payload, connectionId, message1: b64url(initiator.writeMessage1()) })
  initiator.readMessage2(started.message2)
  const completed = manager.completeHandshake(started.sessionId, b64url(initiator.writeMessage3()))
  const result = initiator.result()
  const channel = createSecureChannel(result, { desktopId: payload.desktopId, deviceId: phone.id, connectionId }, 'device')
  assert.equal(verifyKeyConfirmation(channel, completed.confirmationFrame, 'desktop', result.handshakeHash), true)
  manager.receiveKeyConfirmation(started.sessionId, makeKeyConfirmation(channel, 'device', result.handshakeHash))
  const local = manager.confirmLocalSas(started.sessionId)
  assert.deepEqual(channel.decrypt(local.sasFrame, { json: true }), sasConfirmationPayload('desktop', result.handshakeHash))
  const remote = manager.receiveRemoteSasConfirmation(started.sessionId, channel.encrypt(sasConfirmationPayload('device', result.handshakeHash)))
  assert.equal(remote.paired, true)
  const paired = channel.decrypt(remote.pairedFrame, { json: true })
  return { started, completed, result, channel, paired, authenticated: manager.authenticatedConnection(started.sessionId) }
}

function finishResume({ manager, desktop, phone, connectionId = 'connection-resume-1' }) {
  const context = resumeHandshakeContext({ desktopId: desktop.id, deviceId: phone.id, connectionId })
  const initiator = new NoiseXXInitiator({
    identity: phone,
    prologue: createNoisePrologue(context),
    peerPin: { id: desktop.id, identityPublic: desktop.identityPublic, x25519StaticPublic: desktop.x25519StaticPublic },
  })
  const started = manager.startResume({ deviceId: phone.id, connectionId, message1: b64url(initiator.writeMessage1()) })
  initiator.readMessage2(started.message2)
  const completed = manager.completeHandshake(started.sessionId, b64url(initiator.writeMessage3()))
  const result = initiator.result()
  const channel = createSecureChannel(result, { desktopId: desktop.id, deviceId: phone.id, connectionId }, 'device')
  verifyKeyConfirmation(channel, completed.confirmationFrame, 'desktop', result.handshakeHash)
  assert.deepEqual(manager.receiveKeyConfirmation(started.sessionId, makeKeyConfirmation(channel, 'device', result.handshakeHash)), { authenticated: true, sasRequired: false })
  return { started, channel, authenticated: manager.authenticatedConnection(started.sessionId) }
}

test('single-use QR binds the signed desktop record, requested observe capability, transport, and short expiry', (t) => {
  const { desktop, manager, now } = setup(t)
  const payload = manager.createOffer()
  assert.equal(payload.desktopId, desktop.id)
  assert.notEqual(payload.identityPublic, payload.keyRecord.x25519StaticPublic)
  assert.deepEqual(payload.requestedCapabilities, ['observe'])
  assert.deepEqual(payload.transportHint, { service: '_kaisola._tcp', protocol: 'tcp' })
  assert.equal(payload.expiresAt - now(), 120_000)
  assert.deepEqual(validatePairingPayload(payload, { now: now(), expectedDesktopId: desktop.id }), payload)

  const phone = phoneIdentity()
  const initiator = new NoiseXXInitiator({
    identity: phone,
    prologue: createNoisePrologue(pairingHandshakeContext(payload, 'connection-claim-once')),
    peerPin: { id: desktop.id, identityPublic: desktop.identityPublic, x25519StaticPublic: desktop.x25519StaticPublic },
  })
  const message1 = b64url(initiator.writeMessage1())
  manager.startPairing({ qrPayload: payload, connectionId: 'connection-claim-once', message1 })
  assert.throws(() => manager.startPairing({ qrPayload: payload, connectionId: 'connection-claim-once', message1 }), (error) => error.code === 'pairing_offer_unavailable')
})

test('QR expiry allows a bounded phone clock skew but desktop consumption uses authoritative strict time', (t) => {
  const { desktop, manager, setNow } = setup(t)
  const payload = manager.createOffer({ expiresInMs: 10_000 })
  setNow(payload.expiresAt + 20_000)
  assert.equal(validatePairingPayload(payload, { now: payload.expiresAt + 20_000, expectedDesktopId: desktop.id }).desktopId, desktop.id)
  assert.throws(() => validatePairingPayload(payload, { now: payload.expiresAt + 30_001 }), (error) => error.code === 'pairing_expired')
  const phone = phoneIdentity()
  const initiator = new NoiseXXInitiator({
    identity: phone,
    prologue: createNoisePrologue(pairingHandshakeContext(payload, 'connection-expired')),
    peerPin: { id: desktop.id, identityPublic: desktop.identityPublic, x25519StaticPublic: desktop.x25519StaticPublic },
  })
  assert.throws(() => manager.startPairing({ qrPayload: payload, connectionId: 'connection-expired', message1: b64url(initiator.writeMessage1()) }), (error) => error.code === 'pairing_expired')
})

test('pairing persists only after mutual key proof and both matching SAS confirmations', (t) => {
  const { filePath, manager, store } = setup(t)
  const phone = phoneIdentity()
  const payload = manager.createOffer({ requestedCapabilities: ['observe'] })
  const paired = finishPairing({ manager, payload, phone })
  assert.deepEqual(paired.completed.sas, deriveSas(paired.result.handshakeHash))
  assert.equal(paired.paired.type, 'paired')
  assert.deepEqual(paired.paired.capabilities, ['observe'])
  const record = store.getDevice(phone.id)
  assert.equal(record.identityPublic, phone.identityPublic)
  assert.equal(record.x25519StaticPublic, phone.x25519StaticPublic)
  const persisted = fs.readFileSync(filePath, 'utf8')
  assert.equal(persisted.includes(payload.pairingNonce), false)
  assert.equal(Object.hasOwn(JSON.parse(persisted), 'pairingSecret'), false)
})

test('failed or incomplete SAS confirmation never creates a device record', (t) => {
  const { desktop, manager, store } = setup(t)
  const phone = phoneIdentity()
  const payload = manager.createOffer()
  const connectionId = 'connection-incomplete-sas'
  const initiator = new NoiseXXInitiator({
    identity: phone,
    prologue: createNoisePrologue(pairingHandshakeContext(payload, connectionId)),
    peerPin: { id: desktop.id, identityPublic: desktop.identityPublic, x25519StaticPublic: desktop.x25519StaticPublic },
  })
  const started = manager.startPairing({ qrPayload: payload, connectionId, message1: b64url(initiator.writeMessage1()) })
  initiator.readMessage2(started.message2)
  const completed = manager.completeHandshake(started.sessionId, b64url(initiator.writeMessage3()))
  const result = initiator.result()
  const channel = createSecureChannel(result, { desktopId: desktop.id, deviceId: phone.id, connectionId }, 'device')
  verifyKeyConfirmation(channel, completed.confirmationFrame, 'desktop', result.handshakeHash)
  manager.receiveKeyConfirmation(started.sessionId, makeKeyConfirmation(channel, 'device', result.handshakeHash))
  manager.confirmLocalSas(started.sessionId)
  assert.equal(store.getDevice(phone.id), null)
  assert.throws(() => manager.receiveRemoteSasConfirmation(started.sessionId, channel.encrypt({ ...sasConfirmationPayload('device', result.handshakeHash), transcriptHash: b64url(Buffer.alloc(32)) })), (error) => error.code === 'sas_confirmation_failed')
  assert.equal(store.getDevice(phone.id), null)
})

test('explicit re-pair closes old connections, replaces both keys, and rejects the old identity on resume', (t) => {
  const { desktop, manager, store } = setup(t)
  const oldPhone = phoneIdentity(61)
  finishPairing({ manager, payload: manager.createOffer(), phone: oldPhone })
  let closeReason = null
  store.registerConnection(oldPhone.id, (reason) => { closeReason = reason })

  const newPhone = phoneIdentity(81)
  const replaceOffer = manager.createOffer({ replaceDeviceId: oldPhone.id })
  finishPairing({ manager, payload: replaceOffer, phone: newPhone, connectionId: 'connection-repair' })
  assert.equal(closeReason, 'device_repaired')
  assert.equal(store.getDevice(oldPhone.id).identityPublic, newPhone.identityPublic)
  assert.equal(store.getDevice(oldPhone.id).x25519StaticPublic, newPhone.x25519StaticPublic)

  const oldContext = resumeHandshakeContext({ desktopId: desktop.id, deviceId: oldPhone.id, connectionId: 'connection-old-key' })
  const oldInitiator = new NoiseXXInitiator({
    identity: oldPhone,
    prologue: createNoisePrologue(oldContext),
    peerPin: { id: desktop.id, identityPublic: desktop.identityPublic, x25519StaticPublic: desktop.x25519StaticPublic },
  })
  const oldStart = manager.startResume({ deviceId: oldPhone.id, connectionId: oldContext.connectionId, message1: b64url(oldInitiator.writeMessage1()) })
  oldInitiator.readMessage2(oldStart.message2)
  assert.throws(() => manager.completeHandshake(oldStart.sessionId, b64url(oldInitiator.writeMessage3())), (error) => error.code === 'identity_mismatch')

  const resumed = finishResume({ manager, desktop, phone: newPhone, connectionId: 'connection-new-key' })
  assert.equal(resumed.authenticated.device.identityPublic, newPhone.identityPublic)
  assert.deepEqual(resumed.authenticated.channel.stats(), { sendCounter: '1', receiveCounter: '1' })
})

test('unknown resume ids receive bounded XX message 2 work instead of a paired-device state oracle', (t) => {
  const { desktop, manager } = setup(t)
  const stranger = phoneIdentity(91, 'device-unknown')
  const context = resumeHandshakeContext({ desktopId: desktop.id, deviceId: stranger.id, connectionId: 'connection-unknown' })
  const initiator = new NoiseXXInitiator({
    identity: stranger,
    prologue: createNoisePrologue(context),
    peerPin: { id: desktop.id, identityPublic: desktop.identityPublic, x25519StaticPublic: desktop.x25519StaticPublic },
  })
  const started = manager.startResume({ deviceId: stranger.id, connectionId: context.connectionId, message1: b64url(initiator.writeMessage1()) })
  assert.equal(typeof started.message2, 'string')
  initiator.readMessage2(started.message2)
  assert.throws(() => manager.completeHandshake(started.sessionId, b64url(initiator.writeMessage3())), (error) => ['identity_mismatch', 'authentication_failed'].includes(error.code))
})
