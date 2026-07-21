'use strict'

const crypto = require('node:crypto')
const { IDENTIFIER_RE } = require('./protocol.cjs')

const NOISE_PROTOCOL = 'Noise_XX_25519_ChaChaPoly_SHA256'
const PROTOCOL_VERSION = 1
const MAX_HANDSHAKE_MESSAGE_BYTES = 64 * 1024
const MAX_IDENTITY_PAYLOAD_BYTES = 8 * 1024
const MAX_SECURE_PLAINTEXT_BYTES = 1024 * 1024
const SAS_ENTROPY_BITS = 32

const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex')
const X25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex')
const KEY_RECORD_DOMAIN = Buffer.from('kaisola-companion-key-record-v1\0', 'utf8')
const HANDSHAKE_SIGNATURE_DOMAIN = Buffer.from('kaisola-companion-noise-hash-v1\0', 'utf8')
const PROLOGUE_DOMAIN = Buffer.from('kaisola-companion-noise-prologue-v1\0', 'utf8')
const SAS_SALT = crypto.createHash('sha256').update('kaisola-companion-sas-v1', 'utf8').digest()
const CHACHA_CONSTANTS = Buffer.from('expand 32-byte k', 'ascii')
const HAS_NATIVE_CHACHA = crypto.getCiphers().includes('chacha20-poly1305')

const SAS_ADJECTIVES = Object.freeze([
  'amber', 'brisk', 'calm', 'clear', 'coral', 'dawn', 'ember', 'fair',
  'gentle', 'green', 'lunar', 'merry', 'quiet', 'rapid', 'silver', 'warm',
])
const SAS_NOUNS = Object.freeze([
  'anchor', 'bird', 'cedar', 'cloud', 'comet', 'field', 'harbor', 'island',
  'maple', 'meadow', 'otter', 'river', 'stone', 'trail', 'willow', 'wind',
])

class CompanionCryptoError extends Error {
  constructor(code, message = 'companion cryptographic operation failed') {
    super(message)
    this.name = 'CompanionCryptoError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionCryptoError(code, message)
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function canonicalJson(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return JSON.stringify(value)
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) fail('invalid_canonical_value', 'canonical numbers must be safe integers')
    return String(value)
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (!isPlainObject(value)) fail('invalid_canonical_value', 'canonical value must be JSON data')
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`
}

function canonicalBytes(value) {
  return Buffer.from(canonicalJson(value), 'utf8')
}

function b64url(value) {
  return Buffer.from(value).toString('base64url')
}

function fromB64url(value, bytes, label = 'value') {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) fail('invalid_encoding', `${label} is invalid`)
  const decoded = Buffer.from(value, 'base64url')
  if (decoded.toString('base64url') !== value || (bytes != null && decoded.length !== bytes)) {
    fail('invalid_encoding', `${label} is invalid`)
  }
  return decoded
}

function validateId(value, label = 'id') {
  if (typeof value !== 'string' || !IDENTIFIER_RE.test(value)) {
    fail('invalid_identity', `${label} is invalid`)
  }
  return value
}

function keyPairFromSeed(type, seed) {
  const raw = Buffer.from(seed)
  if (raw.length !== 32) fail('invalid_private_key', `${type} seed must be 32 bytes`)
  const prefix = type === 'ed25519' ? ED25519_PKCS8_PREFIX : type === 'x25519' ? X25519_PKCS8_PREFIX : null
  if (!prefix) fail('invalid_key_type', 'unsupported key type')
  const privateKey = crypto.createPrivateKey({ key: Buffer.concat([prefix, raw]), format: 'der', type: 'pkcs8' })
  return { privateKey, publicKey: crypto.createPublicKey(privateKey) }
}

function generateKeyPair(type) {
  if (type !== 'ed25519' && type !== 'x25519') fail('invalid_key_type', 'unsupported key type')
  return crypto.generateKeyPairSync(type)
}

function exportPublicRaw(key) {
  const jwk = key.export({ format: 'jwk' })
  return fromB64url(jwk.x, 32, 'public key')
}

function exportPublicB64(key) {
  return b64url(exportPublicRaw(key))
}

function publicKeyFromRaw(type, value) {
  const raw = typeof value === 'string' ? fromB64url(value, 32, `${type} public key`) : Buffer.from(value)
  if (raw.length !== 32) fail('invalid_public_key', `${type} public key is invalid`)
  const crv = type === 'ed25519' ? 'Ed25519' : type === 'x25519' ? 'X25519' : null
  if (!crv) fail('invalid_key_type', 'unsupported key type')
  try {
    return crypto.createPublicKey({ key: { kty: 'OKP', crv, x: b64url(raw) }, format: 'jwk' })
  } catch {
    fail('invalid_public_key', `${type} public key is invalid`)
  }
}

function exportPrivatePkcs8(key) {
  return Buffer.from(key.export({ format: 'der', type: 'pkcs8' }))
}

function privateKeyFromPkcs8(type, value) {
  try {
    const key = crypto.createPrivateKey({ key: Buffer.from(value), format: 'der', type: 'pkcs8' })
    if (key.asymmetricKeyType !== type) fail('invalid_private_key', `${type} private key is invalid`)
    return key
  } catch (error) {
    if (error instanceof CompanionCryptoError) throw error
    fail('invalid_private_key', `${type} private key is invalid`)
  }
}

function identityIdField(role) {
  if (role === 'desktop') return 'desktopId'
  if (role === 'device') return 'deviceId'
  fail('invalid_role', 'identity role is invalid')
}

function unsignedKeyRecord({ id, role, x25519StaticPublic }) {
  const field = identityIdField(role)
  return { [field]: validateId(id, field), role, x25519StaticPublic: b64url(fromB64url(x25519StaticPublic, 32, 'x25519StaticPublic')) }
}

function keyRecordSigningBytes(record) {
  return Buffer.concat([KEY_RECORD_DOMAIN, canonicalBytes(record)])
}

function signKeyRecord(identityPrivateKey, fields) {
  const record = unsignedKeyRecord(fields)
  return { ...record, signature: b64url(crypto.sign(null, keyRecordSigningBytes(record), identityPrivateKey)) }
}

function verifySignedKeyRecord(signed, identityPublic, { expectedRole, expectedId } = {}) {
  if (!isPlainObject(signed)) fail('invalid_key_record', 'signed key record is invalid')
  const allowed = new Set(['desktopId', 'deviceId', 'role', 'x25519StaticPublic', 'signature'])
  if (Object.keys(signed).some((key) => !allowed.has(key))) fail('invalid_key_record', 'signed key record is invalid')
  const role = signed.role
  const field = identityIdField(role)
  if (role === 'desktop' && Object.hasOwn(signed, 'deviceId')) fail('invalid_key_record', 'signed key record is invalid')
  if (role === 'device' && Object.hasOwn(signed, 'desktopId')) fail('invalid_key_record', 'signed key record is invalid')
  const record = unsignedKeyRecord({ id: signed[field], role, x25519StaticPublic: signed.x25519StaticPublic })
  const signature = fromB64url(signed.signature, 64, 'key record signature')
  const publicKey = typeof identityPublic === 'string' ? publicKeyFromRaw('ed25519', identityPublic) : identityPublic
  if (!crypto.verify(null, keyRecordSigningBytes(record), publicKey, signature)) fail('identity_proof_failed', 'identity proof failed')
  if (expectedRole && role !== expectedRole) fail('role_mismatch', 'identity role does not match the connection role')
  if (expectedId && record[field] !== expectedId) fail('identity_mismatch', 'identity id does not match the pinned peer')
  return { ...record, signature: signed.signature }
}

function createIdentity({ id, role, displayName, identityKeyPair, staticKeyPair } = {}) {
  validateId(id, identityIdField(role))
  const signing = identityKeyPair ?? generateKeyPair('ed25519')
  const agreement = staticKeyPair ?? generateKeyPair('x25519')
  if (signing.privateKey.asymmetricKeyType !== 'ed25519' || agreement.privateKey.asymmetricKeyType !== 'x25519') {
    fail('invalid_identity', 'identity keys have the wrong roles')
  }
  const identityPublic = exportPublicB64(signing.publicKey)
  const x25519StaticPublic = exportPublicB64(agreement.publicKey)
  const keyRecord = signKeyRecord(signing.privateKey, { id, role, x25519StaticPublic })
  return {
    id,
    role,
    displayName: typeof displayName === 'string' ? displayName.slice(0, 80) : role === 'desktop' ? 'Kaisola Desktop' : 'Kaisola Device',
    identityPrivateKey: signing.privateKey,
    identityPublicKey: signing.publicKey,
    identityPublic,
    x25519StaticPrivateKey: agreement.privateKey,
    x25519StaticPublicKey: agreement.publicKey,
    x25519StaticPublic,
    keyRecord,
  }
}

function identityFromSeeds({ id, role, displayName, identitySeed, staticSeed }) {
  return createIdentity({
    id,
    role,
    displayName,
    identityKeyPair: keyPairFromSeed('ed25519', identitySeed),
    staticKeyPair: keyPairFromSeed('x25519', staticSeed),
  })
}

function sha256(...parts) {
  const hash = crypto.createHash('sha256')
  for (const part of parts) hash.update(part)
  return hash.digest()
}

function hmac(key, ...parts) {
  const mac = crypto.createHmac('sha256', key)
  for (const part of parts) mac.update(part)
  return mac.digest()
}

function noiseHkdf(chainingKey, inputKeyMaterial) {
  const temporaryKey = hmac(chainingKey, inputKeyMaterial)
  const output1 = hmac(temporaryKey, Buffer.from([1]))
  const output2 = hmac(temporaryKey, output1, Buffer.from([2]))
  return [output1, output2]
}

function hkdf32(inputKeyMaterial, salt, info) {
  return Buffer.from(crypto.hkdfSync('sha256', inputKeyMaterial, salt, info, 32))
}

function rotl32(value, shift) {
  return ((value << shift) | (value >>> (32 - shift))) >>> 0
}

function quarterRound(state, a, b, c, d) {
  state[a] = (state[a] + state[b]) >>> 0; state[d] = rotl32((state[d] ^ state[a]) >>> 0, 16)
  state[c] = (state[c] + state[d]) >>> 0; state[b] = rotl32((state[b] ^ state[c]) >>> 0, 12)
  state[a] = (state[a] + state[b]) >>> 0; state[d] = rotl32((state[d] ^ state[a]) >>> 0, 8)
  state[c] = (state[c] + state[d]) >>> 0; state[b] = rotl32((state[b] ^ state[c]) >>> 0, 7)
}

function chachaBlock(key, counter, nonce) {
  const initial = new Uint32Array(16)
  for (let index = 0; index < 4; index++) initial[index] = CHACHA_CONSTANTS.readUInt32LE(index * 4)
  for (let index = 0; index < 8; index++) initial[4 + index] = key.readUInt32LE(index * 4)
  initial[12] = counter >>> 0
  for (let index = 0; index < 3; index++) initial[13 + index] = nonce.readUInt32LE(index * 4)
  const state = new Uint32Array(initial)
  for (let round = 0; round < 10; round++) {
    quarterRound(state, 0, 4, 8, 12); quarterRound(state, 1, 5, 9, 13)
    quarterRound(state, 2, 6, 10, 14); quarterRound(state, 3, 7, 11, 15)
    quarterRound(state, 0, 5, 10, 15); quarterRound(state, 1, 6, 11, 12)
    quarterRound(state, 2, 7, 8, 13); quarterRound(state, 3, 4, 9, 14)
  }
  const output = Buffer.alloc(64)
  for (let index = 0; index < 16; index++) output.writeUInt32LE((state[index] + initial[index]) >>> 0, index * 4)
  return output
}

function chachaXor(key, nonce, initialCounter, input) {
  const output = Buffer.alloc(input.length)
  for (let offset = 0, block = 0; offset < input.length; offset += 64, block++) {
    const counter = initialCounter + block
    if (counter > 0xffffffff) fail('message_too_large', 'ChaCha20 counter exhausted')
    const stream = chachaBlock(key, counter, nonce)
    const size = Math.min(64, input.length - offset)
    for (let index = 0; index < size; index++) output[offset + index] = input[offset + index] ^ stream[index]
  }
  return output
}

function littleEndianBigInt(bytes) {
  let value = 0n
  for (let index = bytes.length - 1; index >= 0; index--) value = (value << 8n) | BigInt(bytes[index])
  return value
}

function bigIntLittleEndian(value, bytes) {
  const output = Buffer.alloc(bytes)
  let remaining = value
  for (let index = 0; index < bytes; index++) {
    output[index] = Number(remaining & 0xffn)
    remaining >>= 8n
  }
  return output
}

function poly1305(message, oneTimeKey) {
  const rBytes = Buffer.from(oneTimeKey.subarray(0, 16))
  rBytes[3] &= 15; rBytes[7] &= 15; rBytes[11] &= 15; rBytes[15] &= 15
  rBytes[4] &= 252; rBytes[8] &= 252; rBytes[12] &= 252
  const r = littleEndianBigInt(rBytes)
  const s = littleEndianBigInt(oneTimeKey.subarray(16, 32))
  const prime = (1n << 130n) - 5n
  let accumulator = 0n
  for (let offset = 0; offset < message.length; offset += 16) {
    const block = message.subarray(offset, Math.min(offset + 16, message.length))
    const value = littleEndianBigInt(block) + (1n << BigInt(block.length * 8))
    accumulator = ((accumulator + value) * r) % prime
  }
  return bigIntLittleEndian((accumulator + s) & ((1n << 128n) - 1n), 16)
}

function pad16(value) {
  const remainder = value.length % 16
  return remainder === 0 ? Buffer.alloc(0) : Buffer.alloc(16 - remainder)
}

function aeadMacData(aad, ciphertext) {
  const lengths = Buffer.alloc(16)
  lengths.writeBigUInt64LE(BigInt(aad.length), 0)
  lengths.writeBigUInt64LE(BigInt(ciphertext.length), 8)
  return Buffer.concat([aad, pad16(aad), ciphertext, pad16(ciphertext), lengths])
}

function fallbackAeadEncrypt(key, nonce, aad, plaintext) {
  const polyKey = chachaBlock(key, 0, nonce).subarray(0, 32)
  const ciphertext = chachaXor(key, nonce, 1, plaintext)
  return Buffer.concat([ciphertext, poly1305(aeadMacData(aad, ciphertext), polyKey)])
}

function fallbackAeadDecrypt(key, nonce, aad, combined) {
  if (combined.length < 16) fail('authentication_failed', 'ciphertext authentication failed')
  const ciphertext = combined.subarray(0, -16)
  const tag = combined.subarray(-16)
  const polyKey = chachaBlock(key, 0, nonce).subarray(0, 32)
  const expected = poly1305(aeadMacData(aad, ciphertext), polyKey)
  if (!crypto.timingSafeEqual(tag, expected)) fail('authentication_failed', 'ciphertext authentication failed')
  return chachaXor(key, nonce, 1, ciphertext)
}

function aeadEncrypt(key, nonce, aad, plaintext) {
  if (!HAS_NATIVE_CHACHA) return fallbackAeadEncrypt(key, nonce, aad, plaintext)
  const cipher = crypto.createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  cipher.setAAD(aad, { plaintextLength: plaintext.length })
  return Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()])
}

function aeadDecrypt(key, nonce, aad, combined) {
  if (!HAS_NATIVE_CHACHA) return fallbackAeadDecrypt(key, nonce, aad, combined)
  if (combined.length < 16) fail('authentication_failed', 'ciphertext authentication failed')
  try {
    const ciphertext = combined.subarray(0, -16)
    const decipher = crypto.createDecipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
    decipher.setAAD(aad, { plaintextLength: ciphertext.length })
    decipher.setAuthTag(combined.subarray(-16))
    return Buffer.concat([decipher.update(ciphertext), decipher.final()])
  } catch {
    fail('authentication_failed', 'ciphertext authentication failed')
  }
}

function noiseNonce(counter) {
  const nonce = Buffer.alloc(12)
  nonce.writeBigUInt64LE(counter, 4)
  return nonce
}

function transportNonce(counter) {
  const value = typeof counter === 'bigint' ? counter : BigInt(counter)
  if (value < 0n || value > 0xffffffffffffffffn) fail('counter_exhausted', 'secure frame counter exhausted')
  return noiseNonce(value)
}

function dh(privateKey, remotePublicRaw) {
  try {
    const shared = crypto.diffieHellman({ privateKey, publicKey: publicKeyFromRaw('x25519', remotePublicRaw) })
    if (shared.equals(Buffer.alloc(32))) fail('invalid_dh', 'X25519 agreement failed')
    return shared
  } catch (error) {
    if (error instanceof CompanionCryptoError) throw error
    fail('invalid_dh', 'X25519 agreement failed')
  }
}

class NoiseSymmetricState {
  constructor(prologue) {
    const name = Buffer.from(NOISE_PROTOCOL, 'ascii')
    this.h = name.length <= 32 ? Buffer.concat([name, Buffer.alloc(32 - name.length)]) : sha256(name)
    this.ck = Buffer.from(this.h)
    this.key = null
    this.counter = 0n
    this.mixHash(prologue)
  }

  mixHash(data) {
    this.h = sha256(this.h, data)
  }

  mixKey(inputKeyMaterial) {
    const [ck, key] = noiseHkdf(this.ck, inputKeyMaterial)
    this.ck = ck
    this.key = key
    this.counter = 0n
  }

  encryptAndHash(plaintext) {
    const output = this.key ? aeadEncrypt(this.key, noiseNonce(this.counter++), this.h, plaintext) : Buffer.from(plaintext)
    this.mixHash(output)
    return output
  }

  decryptAndHash(ciphertext) {
    const output = this.key ? aeadDecrypt(this.key, noiseNonce(this.counter++), this.h, ciphertext) : Buffer.from(ciphertext)
    this.mixHash(ciphertext)
    return output
  }

  split() {
    return noiseHkdf(this.ck, Buffer.alloc(0))
  }
}

function createNoisePrologue(context) {
  if (!isPlainObject(context)) fail('invalid_handshake_context', 'handshake context is invalid')
  return Buffer.concat([PROLOGUE_DOMAIN, canonicalBytes(context)])
}

function handshakeSignatureBytes(role, handshakeHash) {
  return Buffer.concat([HANDSHAKE_SIGNATURE_DOMAIN, Buffer.from(role, 'ascii'), Buffer.from([0]), handshakeHash])
}

function identityProof(identity, handshakeHash) {
  const proof = {
    v: PROTOCOL_VERSION,
    role: identity.role,
    identityPublic: identity.identityPublic,
    keyRecord: identity.keyRecord,
    displayName: identity.displayName,
    handshakeSignature: b64url(crypto.sign(null, handshakeSignatureBytes(identity.role, handshakeHash), identity.identityPrivateKey)),
  }
  const encoded = canonicalBytes(proof)
  if (encoded.length > MAX_IDENTITY_PAYLOAD_BYTES) fail('identity_payload_too_large', 'identity proof is too large')
  return encoded
}

function parseIdentityProof(encoded, handshakeHash, staticPublic, { expectedRole, pin } = {}) {
  if (encoded.length > MAX_IDENTITY_PAYLOAD_BYTES) fail('identity_payload_too_large', 'identity proof is too large')
  let proof
  try { proof = JSON.parse(encoded.toString('utf8')) } catch { fail('identity_proof_failed', 'identity proof failed') }
  if (!isPlainObject(proof)) fail('identity_proof_failed', 'identity proof failed')
  const allowed = new Set(['v', 'role', 'identityPublic', 'keyRecord', 'displayName', 'handshakeSignature'])
  if (Object.keys(proof).some((key) => !allowed.has(key)) || proof.v !== PROTOCOL_VERSION || proof.role !== expectedRole) {
    fail('role_mismatch', 'identity role does not match the connection role')
  }
  const identityPublic = b64url(fromB64url(proof.identityPublic, 32, 'identityPublic'))
  const record = verifySignedKeyRecord(proof.keyRecord, identityPublic, {
    expectedRole,
    expectedId: pin?.id,
  })
  if (record.x25519StaticPublic !== b64url(staticPublic)) fail('identity_proof_failed', 'identity proof failed')
  if (pin?.identityPublic && pin.identityPublic !== identityPublic) fail('identity_mismatch', 'identity key does not match the pinned peer')
  if (pin?.x25519StaticPublic && pin.x25519StaticPublic !== record.x25519StaticPublic) fail('identity_mismatch', 'agreement key does not match the pinned peer')
  const signature = fromB64url(proof.handshakeSignature, 64, 'handshake signature')
  if (!crypto.verify(null, handshakeSignatureBytes(expectedRole, handshakeHash), publicKeyFromRaw('ed25519', identityPublic), signature)) {
    fail('identity_proof_failed', 'identity proof failed')
  }
  const field = identityIdField(expectedRole)
  return {
    id: record[field],
    role: expectedRole,
    displayName: typeof proof.displayName === 'string' && proof.displayName.trim() ? proof.displayName.trim().slice(0, 80) : expectedRole === 'desktop' ? 'Kaisola Desktop' : 'Kaisola Device',
    identityPublic,
    x25519StaticPublic: record.x25519StaticPublic,
    keyRecord: record,
  }
}

function normalizeMessage(value) {
  const message = typeof value === 'string' ? fromB64url(value, null, 'Noise message') : Buffer.from(value)
  if (!message.length || message.length > MAX_HANDSHAKE_MESSAGE_BYTES) fail('invalid_handshake_message', 'Noise message is invalid')
  return message
}

function ensureState(actual, expected) {
  if (actual !== expected) fail('handshake_order', `Noise message is out of order; expected ${expected}`)
}

class NoiseXXInitiator {
  constructor({ identity, prologue, peerPin, ephemeralKeyPair } = {}) {
    if (identity?.role !== 'device') fail('role_mismatch', 'Noise initiator must be the device')
    this.identity = identity
    this.peerPin = peerPin
    this.ephemeral = ephemeralKeyPair ?? generateKeyPair('x25519')
    this.symmetric = new NoiseSymmetricState(Buffer.from(prologue))
    this.state = 'write_message_1'
    this.remoteEphemeral = null
    this.remoteStatic = null
    this.peer = null
  }

  writeMessage1() {
    ensureState(this.state, 'write_message_1')
    const message = exportPublicRaw(this.ephemeral.publicKey)
    this.symmetric.mixHash(message)
    this.state = 'read_message_2'
    return message
  }

  readMessage2(value) {
    ensureState(this.state, 'read_message_2')
    const message = normalizeMessage(value)
    if (message.length < 32 + 48 + 16) fail('invalid_handshake_message', 'Noise message 2 is invalid')
    this.remoteEphemeral = message.subarray(0, 32)
    this.symmetric.mixHash(this.remoteEphemeral)
    this.symmetric.mixKey(dh(this.ephemeral.privateKey, this.remoteEphemeral))
    this.remoteStatic = this.symmetric.decryptAndHash(message.subarray(32, 80))
    this.symmetric.mixKey(dh(this.ephemeral.privateKey, this.remoteStatic))
    const beforePayload = Buffer.from(this.symmetric.h)
    const payload = this.symmetric.decryptAndHash(message.subarray(80))
    this.peer = parseIdentityProof(payload, beforePayload, this.remoteStatic, { expectedRole: 'desktop', pin: this.peerPin })
    this.state = 'write_message_3'
    return this.peer
  }

  writeMessage3() {
    ensureState(this.state, 'write_message_3')
    const encryptedStatic = this.symmetric.encryptAndHash(exportPublicRaw(this.identity.x25519StaticPublicKey))
    this.symmetric.mixKey(dh(this.identity.x25519StaticPrivateKey, this.remoteEphemeral))
    const beforePayload = Buffer.from(this.symmetric.h)
    const encryptedPayload = this.symmetric.encryptAndHash(identityProof(this.identity, beforePayload))
    this.state = 'complete'
    return Buffer.concat([encryptedStatic, encryptedPayload])
  }

  result() {
    ensureState(this.state, 'complete')
    return { handshakeHash: Buffer.from(this.symmetric.h), splitKeys: this.symmetric.split(), peer: this.peer }
  }
}

class NoiseXXResponder {
  constructor({ identity, prologue, peerPin, ephemeralKeyPair } = {}) {
    if (identity?.role !== 'desktop') fail('role_mismatch', 'Noise responder must be the desktop')
    this.identity = identity
    this.peerPin = peerPin
    this.ephemeral = ephemeralKeyPair ?? generateKeyPair('x25519')
    this.symmetric = new NoiseSymmetricState(Buffer.from(prologue))
    this.state = 'read_message_1'
    this.remoteEphemeral = null
    this.remoteStatic = null
    this.peer = null
  }

  readMessage1(value) {
    ensureState(this.state, 'read_message_1')
    const message = normalizeMessage(value)
    if (message.length !== 32) fail('invalid_handshake_message', 'Noise message 1 is invalid')
    this.remoteEphemeral = message
    this.symmetric.mixHash(message)
    this.state = 'write_message_2'
  }

  writeMessage2() {
    ensureState(this.state, 'write_message_2')
    const localEphemeral = exportPublicRaw(this.ephemeral.publicKey)
    this.symmetric.mixHash(localEphemeral)
    this.symmetric.mixKey(dh(this.ephemeral.privateKey, this.remoteEphemeral))
    const encryptedStatic = this.symmetric.encryptAndHash(exportPublicRaw(this.identity.x25519StaticPublicKey))
    this.symmetric.mixKey(dh(this.identity.x25519StaticPrivateKey, this.remoteEphemeral))
    const beforePayload = Buffer.from(this.symmetric.h)
    const encryptedPayload = this.symmetric.encryptAndHash(identityProof(this.identity, beforePayload))
    this.state = 'read_message_3'
    return Buffer.concat([localEphemeral, encryptedStatic, encryptedPayload])
  }

  readMessage3(value) {
    ensureState(this.state, 'read_message_3')
    const message = normalizeMessage(value)
    if (message.length < 48 + 16) fail('invalid_handshake_message', 'Noise message 3 is invalid')
    this.remoteStatic = this.symmetric.decryptAndHash(message.subarray(0, 48))
    this.symmetric.mixKey(dh(this.ephemeral.privateKey, this.remoteStatic))
    const beforePayload = Buffer.from(this.symmetric.h)
    const payload = this.symmetric.decryptAndHash(message.subarray(48))
    this.peer = parseIdentityProof(payload, beforePayload, this.remoteStatic, { expectedRole: 'device', pin: this.peerPin })
    this.state = 'complete'
    return this.peer
  }

  result() {
    ensureState(this.state, 'complete')
    return { handshakeHash: Buffer.from(this.symmetric.h), splitKeys: this.symmetric.split(), peer: this.peer }
  }
}

function connectionInfo(context, direction) {
  return canonicalBytes({
    v: PROTOCOL_VERSION,
    protocol: NOISE_PROTOCOL,
    desktopId: validateId(context.desktopId, 'desktopId'),
    deviceId: validateId(context.deviceId, 'deviceId'),
    connectionId: validateId(context.connectionId, 'connectionId'),
    direction,
  })
}

function deriveConnectionKeys(result, context) {
  if (!result || !Array.isArray(result.splitKeys) || result.splitKeys.length !== 2) fail('invalid_handshake_result', 'Noise result is invalid')
  const deviceToDesktop = hkdf32(result.splitKeys[0], result.handshakeHash, connectionInfo(context, 'device-to-desktop'))
  const desktopToDevice = hkdf32(result.splitKeys[1], result.handshakeHash, connectionInfo(context, 'desktop-to-device'))
  return { deviceToDesktop, desktopToDevice }
}

function secureFrameAad(header) {
  return canonicalBytes(header)
}

class SecureFrameChannel {
  constructor({ sendKey, receiveKey, desktopId, deviceId, connectionId, sendDirection, receiveDirection } = {}) {
    this.sendKey = Buffer.from(sendKey)
    this.receiveKey = Buffer.from(receiveKey)
    if (this.sendKey.length !== 32 || this.receiveKey.length !== 32) fail('invalid_transport_key', 'transport keys are invalid')
    this.desktopId = validateId(desktopId, 'desktopId')
    this.deviceId = validateId(deviceId, 'deviceId')
    this.connectionId = validateId(connectionId, 'connectionId')
    this.sendDirection = sendDirection
    this.receiveDirection = receiveDirection
    if (!['device-to-desktop', 'desktop-to-device'].includes(sendDirection) || !['device-to-desktop', 'desktop-to-device'].includes(receiveDirection) || sendDirection === receiveDirection) {
      fail('invalid_direction', 'transport directions are invalid')
    }
    this.sendCounter = 0n
    this.receiveCounter = 0n
  }

  encrypt(value) {
    const plaintext = Buffer.isBuffer(value) ? Buffer.from(value) : canonicalBytes(value)
    if (plaintext.length > MAX_SECURE_PLAINTEXT_BYTES) fail('frame_too_large', 'secure frame is too large')
    const header = {
      v: PROTOCOL_VERSION,
      desktopId: this.desktopId,
      deviceId: this.deviceId,
      connectionId: this.connectionId,
      direction: this.sendDirection,
      counter: this.sendCounter.toString(),
      ciphertextLength: plaintext.length,
    }
    const combined = aeadEncrypt(this.sendKey, transportNonce(this.sendCounter), secureFrameAad(header), plaintext)
    this.sendCounter++
    return { ...header, ciphertext: b64url(combined) }
  }

  decrypt(frame, { json = false } = {}) {
    if (!isPlainObject(frame)) fail('invalid_secure_frame', 'secure frame is invalid')
    const allowed = new Set(['v', 'desktopId', 'deviceId', 'connectionId', 'direction', 'counter', 'ciphertextLength', 'ciphertext'])
    if (Object.keys(frame).some((key) => !allowed.has(key))) fail('invalid_secure_frame', 'secure frame is invalid')
    if (frame.v !== PROTOCOL_VERSION || frame.desktopId !== this.desktopId || frame.deviceId !== this.deviceId
      || frame.connectionId !== this.connectionId || frame.direction !== this.receiveDirection) {
      fail('invalid_secure_frame', 'secure frame metadata is invalid')
    }
    if (typeof frame.counter !== 'string' || !/^(0|[1-9][0-9]{0,19})$/.test(frame.counter)) fail('invalid_secure_frame', 'secure frame counter is invalid')
    const counter = BigInt(frame.counter)
    if (counter !== this.receiveCounter) fail('replay_or_out_of_order', 'secure frame counter is replayed or out of order')
    if (!Number.isSafeInteger(frame.ciphertextLength) || frame.ciphertextLength < 0 || frame.ciphertextLength > MAX_SECURE_PLAINTEXT_BYTES) {
      fail('frame_too_large', 'secure frame is too large')
    }
    const combined = fromB64url(frame.ciphertext, null, 'ciphertext')
    if (combined.length !== frame.ciphertextLength + 16) fail('invalid_secure_frame', 'secure frame length is invalid')
    const { ciphertext, ...header } = frame
    const plaintext = aeadDecrypt(this.receiveKey, transportNonce(counter), secureFrameAad(header), combined)
    this.receiveCounter++
    if (!json) return plaintext
    try { return JSON.parse(plaintext.toString('utf8')) } catch { fail('invalid_secure_payload', 'secure payload is invalid') }
  }

  stats() {
    return { sendCounter: this.sendCounter.toString(), receiveCounter: this.receiveCounter.toString() }
  }
}

function createSecureChannel(result, context, role) {
  const keys = deriveConnectionKeys(result, context)
  if (role === 'desktop') {
    return new SecureFrameChannel({
      ...context,
      sendKey: keys.desktopToDevice,
      receiveKey: keys.deviceToDesktop,
      sendDirection: 'desktop-to-device',
      receiveDirection: 'device-to-desktop',
    })
  }
  if (role === 'device') {
    return new SecureFrameChannel({
      ...context,
      sendKey: keys.deviceToDesktop,
      receiveKey: keys.desktopToDevice,
      sendDirection: 'device-to-desktop',
      receiveDirection: 'desktop-to-device',
    })
  }
  fail('invalid_role', 'transport role is invalid')
}

function deriveSas(handshakeHash) {
  const bytes = hkdf32(Buffer.from(handshakeHash), SAS_SALT, Buffer.from('transcript-authentication-phrase', 'utf8')).subarray(0, 4)
  const words = [...bytes].map((value) => `${SAS_ADJECTIVES[value >>> 4]}-${SAS_NOUNS[value & 15]}`)
  return { phrase: words.join(' '), words, entropyBits: SAS_ENTROPY_BITS, bytes: b64url(bytes) }
}

function keyConfirmationPayload(role, handshakeHash) {
  if (role !== 'desktop' && role !== 'device') fail('invalid_role', 'confirmation role is invalid')
  return { type: 'key-confirm', role, transcriptHash: b64url(handshakeHash) }
}

function makeKeyConfirmation(channel, role, handshakeHash) {
  return channel.encrypt(keyConfirmationPayload(role, handshakeHash))
}

function verifyKeyConfirmation(channel, frame, expectedRole, handshakeHash) {
  const payload = channel.decrypt(frame, { json: true })
  const expected = keyConfirmationPayload(expectedRole, handshakeHash)
  if (canonicalJson(payload) !== canonicalJson(expected)) fail('key_confirmation_failed', 'key confirmation failed')
  return true
}

module.exports = {
  CompanionCryptoError,
  HAS_NATIVE_CHACHA,
  MAX_HANDSHAKE_MESSAGE_BYTES,
  MAX_SECURE_PLAINTEXT_BYTES,
  NOISE_PROTOCOL,
  NoiseXXInitiator,
  NoiseXXResponder,
  PROTOCOL_VERSION,
  SAS_ENTROPY_BITS,
  SecureFrameChannel,
  aeadDecrypt,
  aeadEncrypt,
  b64url,
  canonicalBytes,
  canonicalJson,
  createIdentity,
  createNoisePrologue,
  createSecureChannel,
  deriveConnectionKeys,
  deriveSas,
  exportPrivatePkcs8,
  exportPublicB64,
  exportPublicRaw,
  fallbackAeadDecrypt,
  fallbackAeadEncrypt,
  fromB64url,
  generateKeyPair,
  identityFromSeeds,
  keyPairFromSeed,
  makeKeyConfirmation,
  privateKeyFromPkcs8,
  publicKeyFromRaw,
  secureFrameAad,
  signKeyRecord,
  transportNonce,
  verifyKeyConfirmation,
  verifySignedKeyRecord,
}
