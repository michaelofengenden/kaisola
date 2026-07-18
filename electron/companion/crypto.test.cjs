'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const {
  HAS_NATIVE_CHACHA,
  NOISE_PROTOCOL,
  NoiseXXInitiator,
  NoiseXXResponder,
  SAS_ENTROPY_BITS,
  aeadDecrypt,
  aeadEncrypt,
  b64url,
  canonicalBytes,
  createNoisePrologue,
  createSecureChannel,
  deriveConnectionKeys,
  deriveSas,
  fallbackAeadDecrypt,
  fallbackAeadEncrypt,
  identityFromSeeds,
  keyPairFromSeed,
  makeKeyConfirmation,
  secureFrameAad,
  transportNonce,
  verifyKeyConfirmation,
} = require('./crypto.cjs')

const vector = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'crypto-noise-xx-v1.json'), 'utf8'))
const bytes = (hex) => Buffer.from(hex, 'hex')

function vectorHandshake({ context = vector.handshake.context, desktopPin = vector.pins.desktop } = {}) {
  const desktop = identityFromSeeds({
    id: vector.identities.desktop.id,
    role: 'desktop',
    displayName: vector.identities.desktop.displayName,
    identitySeed: bytes(vector.identities.desktop.ed25519Seed),
    staticSeed: bytes(vector.identities.desktop.x25519StaticSeed),
  })
  const device = identityFromSeeds({
    id: vector.identities.device.id,
    role: 'device',
    displayName: vector.identities.device.displayName,
    identitySeed: bytes(vector.identities.device.ed25519Seed),
    staticSeed: bytes(vector.identities.device.x25519StaticSeed),
  })
  const prologue = createNoisePrologue(context)
  const initiator = new NoiseXXInitiator({
    identity: device,
    prologue,
    peerPin: desktopPin,
    ephemeralKeyPair: keyPairFromSeed('x25519', bytes(vector.ephemeralSeeds.device)),
  })
  const responder = new NoiseXXResponder({
    identity: desktop,
    prologue,
    ephemeralKeyPair: keyPairFromSeed('x25519', bytes(vector.ephemeralSeeds.desktop)),
  })
  return { desktop, device, initiator, responder }
}

test('published Noise XX transcript fixes message order, role binding, signatures, split, SAS, and directional keys', () => {
  assert.equal(vector.schema, 'kaisola.noise-xx.v1')
  assert.equal(vector.protocol, NOISE_PROTOCOL)
  assert.deepEqual(vector.messageOrder, [
    'device -> desktop: e',
    'desktop -> device: e, ee, encrypted s, es, encrypted Ed25519 transcript proof',
    'device -> desktop: encrypted s, se, encrypted Ed25519 transcript proof',
  ])
  const { initiator, responder } = vectorHandshake()
  const message1 = initiator.writeMessage1()
  assert.equal(b64url(message1), vector.handshake.message1)
  responder.readMessage1(message1)
  const message2 = responder.writeMessage2()
  assert.equal(b64url(message2), vector.handshake.message2)
  const desktopProof = initiator.readMessage2(message2)
  assert.deepEqual(desktopProof, vector.proofs.desktop)
  const message3 = initiator.writeMessage3()
  assert.equal(b64url(message3), vector.handshake.message3)
  const deviceProof = responder.readMessage3(message3)
  assert.deepEqual(deviceProof, vector.proofs.device)

  const initiatorResult = initiator.result()
  const responderResult = responder.result()
  assert.equal(b64url(initiatorResult.handshakeHash), vector.handshake.finalHash)
  assert.ok(initiatorResult.handshakeHash.equals(responderResult.handshakeHash))
  assert.deepEqual(initiatorResult.splitKeys.map(b64url), vector.handshake.splitKeys)
  assert.deepEqual(responderResult.splitKeys.map(b64url), vector.handshake.splitKeys)
  const keys = deriveConnectionKeys(initiatorResult, vector.connection)
  assert.deepEqual({ deviceToDesktop: b64url(keys.deviceToDesktop), desktopToDevice: b64url(keys.desktopToDevice) }, vector.connection.keys)
  assert.deepEqual(deriveSas(initiatorResult.handshakeHash), vector.sas)
  assert.equal(vector.sas.entropyBits, SAS_ENTROPY_BITS)
  assert.equal(vector.sas.words.length, 4)
})

test('golden key-confirmation and application frames bind roles, nonce, AAD, and counters', () => {
  const { initiator, responder } = vectorHandshake()
  const message1 = initiator.writeMessage1(); responder.readMessage1(message1)
  const message2 = responder.writeMessage2(); initiator.readMessage2(message2)
  const message3 = initiator.writeMessage3(); responder.readMessage3(message3)
  const deviceResult = initiator.result()
  const desktopResult = responder.result()
  const device = createSecureChannel(deviceResult, vector.connection, 'device')
  const desktop = createSecureChannel(desktopResult, vector.connection, 'desktop')

  const desktopConfirmation = makeKeyConfirmation(desktop, 'desktop', desktopResult.handshakeHash)
  assert.deepEqual(desktopConfirmation, vector.keyConfirmation.desktopFrame)
  assert.equal(verifyKeyConfirmation(device, desktopConfirmation, 'desktop', deviceResult.handshakeHash), true)
  const deviceConfirmation = makeKeyConfirmation(device, 'device', deviceResult.handshakeHash)
  assert.deepEqual(deviceConfirmation, vector.keyConfirmation.deviceFrame)
  assert.equal(verifyKeyConfirmation(desktop, deviceConfirmation, 'device', desktopResult.handshakeHash), true)

  const frame = device.encrypt(vector.application.plaintext)
  assert.deepEqual(frame, vector.application.frame)
  assert.equal(b64url(transportNonce(BigInt(frame.counter))), vector.application.nonce)
  const { ciphertext, ...header } = frame
  assert.equal(b64url(secureFrameAad(header)), vector.application.aad)
  assert.deepEqual(desktop.decrypt(frame, { json: true }), vector.application.plaintext)
  assert.throws(() => desktop.decrypt(frame), (error) => error.code === vector.replay.repeatedCounterError)
})

test('Noise XX fails closed on message reordering, changed prologue, static pin substitution, and role confusion', () => {
  const first = vectorHandshake()
  assert.throws(() => first.initiator.readMessage2(Buffer.alloc(96)), (error) => error.code === 'handshake_order')

  const changed = vectorHandshake({ context: { ...vector.handshake.context, connectionId: 'connection-substituted' } })
  const baseline = vectorHandshake()
  const message1 = baseline.initiator.writeMessage1()
  changed.responder.readMessage1(message1)
  assert.throws(() => baseline.initiator.readMessage2(changed.responder.writeMessage2()), (error) => error.code === 'authentication_failed')

  const badPin = vectorHandshake({ desktopPin: { ...vector.pins.desktop, x25519StaticPublic: vector.proofs.device.x25519StaticPublic } })
  const badMessage1 = badPin.initiator.writeMessage1(); badPin.responder.readMessage1(badMessage1)
  assert.throws(() => badPin.initiator.readMessage2(badPin.responder.writeMessage2()), (error) => error.code === 'identity_mismatch')

  assert.throws(() => new NoiseXXInitiator({ identity: first.desktop, prologue: createNoisePrologue(vector.handshake.context) }), (error) => error.code === 'role_mismatch')
  assert.throws(() => new NoiseXXResponder({ identity: first.device, prologue: createNoisePrologue(vector.handshake.context) }), (error) => error.code === 'role_mismatch')
})

test('fresh connection ids and ephemerals derive different keys while each direction safely resets at counter zero', () => {
  const first = vectorHandshake()
  let m1 = first.initiator.writeMessage1(); first.responder.readMessage1(m1)
  let m2 = first.responder.writeMessage2(); first.initiator.readMessage2(m2)
  let m3 = first.initiator.writeMessage3(); first.responder.readMessage3(m3)
  const firstResult = first.initiator.result()
  const secondContext = { ...vector.handshake.context, connectionId: 'connection-vector-0002' }
  const second = vectorHandshake({ context: secondContext })
  m1 = second.initiator.writeMessage1(); second.responder.readMessage1(m1)
  m2 = second.responder.writeMessage2(); second.initiator.readMessage2(m2)
  m3 = second.initiator.writeMessage3(); second.responder.readMessage3(m3)
  const secondResult = second.initiator.result()
  const firstKeys = deriveConnectionKeys(firstResult, vector.connection)
  const secondKeys = deriveConnectionKeys(secondResult, { ...vector.connection, connectionId: secondContext.connectionId })
  assert.notEqual(b64url(firstKeys.deviceToDesktop), b64url(secondKeys.deviceToDesktop))
  const firstChannel = createSecureChannel(firstResult, vector.connection, 'device')
  const secondChannel = createSecureChannel(secondResult, { ...vector.connection, connectionId: secondContext.connectionId }, 'device')
  assert.equal(firstChannel.encrypt({ n: 1 }).counter, '0')
  assert.equal(secondChannel.encrypt({ n: 2 }).counter, '0')
})

test('ChaCha20-Poly1305 matches RFC 8439 AEAD vector in both native and dependency-free Electron fallback paths', () => {
  const key = bytes('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f')
  const nonce = bytes('070000004041424344454647')
  const aad = bytes('50515253c0c1c2c3c4c5c6c7')
  const plaintext = Buffer.from("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
  const expected = bytes('d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691')
  assert.deepEqual(fallbackAeadEncrypt(key, nonce, aad, plaintext), expected)
  assert.deepEqual(fallbackAeadDecrypt(key, nonce, aad, expected), plaintext)
  assert.deepEqual(aeadEncrypt(key, nonce, aad, plaintext), expected)
  assert.deepEqual(aeadDecrypt(key, nonce, aad, expected), plaintext)
  const tampered = Buffer.from(expected); tampered[3] ^= 1
  assert.throws(() => aeadDecrypt(key, nonce, aad, tampered), (error) => error.code === 'authentication_failed')
  assert.equal(typeof HAS_NATIVE_CHACHA, 'boolean')
})

test('fixture declares re-pair replacement behavior for the shared Swift contract', () => {
  assert.deepEqual(vector.clockSkew, {
    expiresAt: vector.qrPayload.expiresAt,
    phoneAllowanceMs: 30_000,
    phoneAtExpiresPlus20000: 'accepted',
    phoneAtExpiresPlus30001: 'pairing_expired',
    desktopAtExpiresPlus1: 'pairing_expired',
  })
  assert.deepEqual(vector.simultaneousPairing, {
    pairingNonce: vector.qrPayload.pairingNonce,
    firstClaim: 'accepted_and_nonce_consumed',
    secondClaim: 'pairing_offer_unavailable',
    failedFirstHandshakeRestoresOffer: false,
  })
  assert.equal(vector.rePair.sameDeviceId, vector.identities.device.id)
  assert.notEqual(vector.rePair.oldIdentityPublic, vector.rePair.newIdentityPublic)
  assert.notEqual(vector.rePair.oldX25519StaticPublic, vector.rePair.newX25519StaticPublic)
  assert.deepEqual(vector.rePair.expected, {
    requiresExplicitReplacementOffer: true,
    closesOldLiveConnections: true,
    removesOldPublicKeys: true,
    oldIdentityCanResume: false,
    countersResetOnlyUnderNewConnectionKeys: true,
  })
})
