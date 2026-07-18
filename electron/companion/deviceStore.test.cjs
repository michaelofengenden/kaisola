'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const { CompanionDeviceStore } = require('./deviceStore.cjs')
const { identityFromSeeds } = require('./crypto.cjs')

function fakeSafeStorage() {
  const mask = Buffer.from('kaisola-test-safe-storage-mask', 'utf8')
  return {
    isEncryptionAvailable: () => true,
    encryptString(value) {
      const input = Buffer.from(value, 'utf8')
      const output = Buffer.alloc(input.length + 4)
      output.write('safe', 0, 'ascii')
      for (let index = 0; index < input.length; index++) output[index + 4] = input[index] ^ mask[index % mask.length]
      return output
    },
    decryptString(value) {
      assert.equal(value.subarray(0, 4).toString('ascii'), 'safe')
      const output = Buffer.alloc(value.length - 4)
      for (let index = 0; index < output.length; index++) output[index] = value[index + 4] ^ mask[index % mask.length]
      return output.toString('utf8')
    },
  }
}

function setup(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-devices-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  let now = 1_784_250_001_000
  const desktop = identityFromSeeds({
    id: 'desktop-device-store',
    role: 'desktop',
    displayName: 'Michael Mac',
    identitySeed: Buffer.alloc(32, 11),
    staticSeed: Buffer.alloc(32, 12),
  })
  const options = {
    filePath: path.join(directory, 'companion-devices.json'),
    safeStorage: fakeSafeStorage(),
    identityFactory: () => desktop,
    now: () => now,
  }
  const store = new CompanionDeviceStore(options)
  return { directory, options, store, desktop, setNow: (value) => { now = value } }
}

function phoneRecord(seed = 20, deviceId = 'device-michael-iphone') {
  const identity = identityFromSeeds({
    id: deviceId,
    role: 'device',
    displayName: "Michael's iPhone",
    identitySeed: Buffer.alloc(32, seed),
    staticSeed: Buffer.alloc(32, seed + 1),
  })
  return {
    identity,
    record: {
      deviceId,
      displayName: identity.displayName,
      identityPublic: identity.identityPublic,
      x25519StaticPublic: identity.x25519StaticPublic,
    },
  }
}

test('desktop Ed25519 and X25519 private keys persist only through safeStorage protection', (t) => {
  const { options, store, desktop } = setup(t)
  assert.notEqual(desktop.identityPublic, desktop.x25519StaticPublic)
  const raw = fs.readFileSync(options.filePath, 'utf8')
  assert.equal(raw.includes(desktop.identityPrivateKey.export({ format: 'der', type: 'pkcs8' }).toString('base64')), false)
  assert.equal(raw.includes(desktop.x25519StaticPrivateKey.export({ format: 'der', type: 'pkcs8' }).toString('base64')), false)
  assert.match(raw, /"protectedPrivate"/)
  assert.equal(fs.statSync(options.filePath).mode & 0o777, 0o600)

  const reopened = new CompanionDeviceStore({ ...options, identityFactory: () => { throw new Error('must load') } })
  assert.deepEqual(reopened.desktopPublicRecord(), store.desktopPublicRecord())
  assert.equal(reopened.desktopIdentity().identityPublic, desktop.identityPublic)
  assert.equal(reopened.desktopIdentity().x25519StaticPublic, desktop.x25519StaticPublic)
})

test('device records default to observe and capability widening remains explicit', (t) => {
  const { store, setNow } = setup(t)
  const phone = phoneRecord()
  const paired = store.pairDevice(phone.record)
  assert.deepEqual(paired.capabilities, ['observe'])
  assert.equal(paired.pairedAt, 1_784_250_001_000)
  assert.throws(() => store.pairDevice(phone.record), (error) => error.code === 'device_exists')
  assert.throws(() => store.setCapabilities(phone.record.deviceId, ['terminal-control']), (error) => error.code === 'invalid_capabilities')
  assert.deepEqual(store.setCapabilities(phone.record.deviceId, ['observe', 'terminal-control']).capabilities, ['observe', 'terminal-control'])
  setNow(1_784_250_010_000)
  assert.equal(store.markSeen(phone.record.deviceId), true)
  assert.equal(store.getDevice(phone.record.deviceId).lastSeenAt, 1_784_250_010_000)
})

test('revocation is event-driven, removes public keys, and closes every live connection immediately', (t) => {
  const { store } = setup(t)
  const phone = phoneRecord()
  store.pairDevice(phone.record)
  const closed = []
  store.registerConnection(phone.record.deviceId, (reason) => closed.push(`a:${reason}`))
  store.registerConnection(phone.record.deviceId, (reason) => closed.push(`b:${reason}`))
  let event = null
  store.once('revoked', (value) => { event = value })
  assert.equal(store.revokeDevice(phone.record.deviceId), true)
  assert.equal(store.getDevice(phone.record.deviceId), null)
  assert.deepEqual(closed.sort(), ['a:device_revoked', 'b:device_revoked'])
  assert.deepEqual(event, { deviceId: phone.record.deviceId, closedConnections: 2 })
  assert.equal(store.stats().liveConnections, 0)
  assert.equal(store.revokeDevice(phone.record.deviceId), false)
})

test('explicit re-pair atomically replaces both public keys and disconnects the old identity', (t) => {
  const { store } = setup(t)
  const oldPhone = phoneRecord(20)
  const newPhone = phoneRecord(40)
  store.pairDevice(oldPhone.record)
  let reason = null
  store.registerConnection(oldPhone.record.deviceId, (value) => { reason = value })
  const replaced = store.pairDevice(newPhone.record, { replace: true })
  assert.equal(reason, 'device_repaired')
  assert.equal(replaced.deviceId, oldPhone.record.deviceId)
  assert.equal(replaced.identityPublic, newPhone.identity.identityPublic)
  assert.equal(replaced.x25519StaticPublic, newPhone.identity.x25519StaticPublic)
  assert.notEqual(replaced.identityPublic, oldPhone.identity.identityPublic)
  assert.notEqual(replaced.x25519StaticPublic, oldPhone.identity.x25519StaticPublic)
})

test('safeStorage availability is a fail-closed constructor requirement', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-no-safe-storage-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  assert.throws(() => new CompanionDeviceStore({
    filePath: path.join(directory, 'devices.json'),
    safeStorage: { isEncryptionAvailable: () => false, encryptString() {}, decryptString() {} },
  }), (error) => error.code === 'safe_storage_unavailable')
})

module.exports = { fakeSafeStorage }
