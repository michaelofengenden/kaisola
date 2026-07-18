'use strict'

const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const {
  HANDLER_CHANNELS,
  registerCompanionHandlers,
} = require('./ipc/companionHandler.cjs')
const { identityFromSeeds } = require('./companion/crypto.cjs')

function fakeSafeStorage() {
  const mask = Buffer.from('kaisola-companion-handler-test', 'utf8')
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

class FakeTransport extends EventEmitter {
  constructor(options) {
    super()
    this.options = options
    this.enabled = false
    this.enableCalls = 0
    this.disableCalls = 0
    this.confirmed = []
    this.cancelled = []
  }

  async enable() {
    this.enableCalls++
    this.enabled = true
    this.emit('enabled', this.status())
    return this.status()
  }

  async disable() {
    this.disableCalls++
    const changed = this.enabled
    this.enabled = false
    if (changed) this.emit('disabled')
    return changed
  }

  confirmPairing(pairingId) {
    this.confirmed.push(pairingId)
    return true
  }

  cancelPairing(pairingId, reason) {
    this.cancelled.push({ pairingId, reason })
    return true
  }

  status() {
    return {
      enabled: this.enabled,
      service: '_kaisola._tcp',
      host: '0.0.0.0',
      port: this.enabled ? 49321 : null,
      token: 'transport-token-that-must-not-leak',
      internalPath: '/private/secret/companion.sock',
      connections: 0,
      unauthenticatedClients: 0,
    }
  }
}

function phoneRecord(seed = 51, deviceId = 'device-handler-iphone') {
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
      capabilities: ['observe', 'agent-control'],
    },
  }
}

function setup(t, { now = 1_784_250_100_000 } = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-handler-'))
  const handlers = new Map()
  const removedHandlers = []
  const sent = []
  const ipcMain = {
    handle(channel, listener) {
      assert.equal(handlers.has(channel), false)
      handlers.set(channel, listener)
    },
    removeHandler(channel) {
      handlers.delete(channel)
      removedHandlers.push(channel)
    },
  }
  const webContents = {
    isDestroyed: () => false,
    send: (channel, payload) => sent.push({ channel, payload }),
  }
  const BrowserWindow = {
    getAllWindows: () => [{ isDestroyed: () => false, webContents }],
  }
  const gateway = {
    stateHub: {},
    attach() {},
    disposeCalls: 0,
    async dispose() { this.disposeCalls++ },
  }
  let transport
  const handler = registerCompanionHandlers(ipcMain, {
    app: { getPath: (name) => {
      assert.equal(name, 'userData')
      return directory
    } },
    BrowserWindow,
    safeStorage: fakeSafeStorage(),
    gateway,
    now: () => now,
    transportFactory: (options) => {
      transport = new FakeTransport(options)
      return transport
    },
    logger: { warn() {} },
  })
  t.after(async () => {
    await handler.dispose()
    fs.rmSync(directory, { recursive: true, force: true })
  })
  return { directory, gateway, handler, handlers, ipcMain, removedHandlers, sent, transport }
}

test('Companion IPC is registered default-disabled without starting a LAN listener', (t) => {
  const { handler, handlers, transport } = setup(t)
  assert.deepEqual([...handlers.keys()], [...HANDLER_CHANNELS])
  assert.equal(transport.options.host, '0.0.0.0')
  assert.equal(transport.options.port, 0)
  assert.equal(transport.enableCalls, 0)
  assert.deepEqual(handler.getState(), {
    enabled: false,
    listening: false,
    status: 'Companion is off. No local-network listener is running.',
    devices: [],
  })
})

test('enable then getState reflects a live loopback-and-LAN listener without exposing its port', async (t) => {
  const { handler, handlers, transport } = setup(t)
  const enabled = await handlers.get('companion:setEnabled')({}, { enabled: true })
  assert.equal(transport.enableCalls, 1)
  assert.equal(enabled.enabled, true)
  assert.equal(enabled.listening, true)
  assert.equal(enabled.status, 'Listening for paired devices on your local network.')
  assert.deepEqual(await handlers.get('companion:getState')(), enabled)
  assert.equal(JSON.stringify(enabled).includes('49321'), false)
})

test('startPairing returns one opaque QR payload and expiry, then emits awaiting and four-word confirmation events', async (t) => {
  const { handler, sent, transport } = setup(t)
  await handler.setEnabled(true)
  const started = await handler.startPairing({ capabilities: ['observe', 'agent-control'] })
  assert.equal(typeof started.pairingId, 'string')
  assert.ok(started.pairingId.length > 20)
  assert.equal(started.expiresAt, 1_784_250_220_000)
  const payload = JSON.parse(started.qrPayload)
  assert.equal(payload.pairingNonce, started.pairingId)
  assert.equal(payload.expiresAt, started.expiresAt)
  assert.deepEqual(payload.requestedCapabilities, ['observe', 'agent-control'])
  assert.deepEqual(payload.transportHint, { service: '_kaisola._tcp', protocol: 'tcp' })
  assert.deepEqual(sent.find((entry) => entry.channel === 'companion:pairing-event')?.payload, {
    pairingId: started.pairingId,
    phase: 'awaiting',
  })

  transport.emit('pairingPhrase', {
    pairingId: started.pairingId,
    device: { displayName: "Michael's iPhone" },
    sas: { phrase: 'amber-anchor brisk-bird calm-cedar clear-cloud' },
  })
  const confirmation = sent.filter((entry) => entry.channel === 'companion:pairing-event').at(-1).payload
  assert.deepEqual(confirmation, {
    pairingId: started.pairingId,
    phase: 'confirm',
    sas: 'amber-anchor brisk-bird calm-cedar clear-cloud',
    deviceName: "Michael's iPhone",
  })
  assert.deepEqual(await handler.confirmPairing(started.pairingId), { ok: true })
  assert.deepEqual(transport.confirmed, [started.pairingId])
  assert.deepEqual(await handler.cancelPairing(started.pairingId), { ok: true })
  assert.deepEqual(await handler.cancelPairing(started.pairingId), { ok: false })
  assert.deepEqual(transport.cancelled, [{ pairingId: started.pairingId, reason: 'pairing_cancelled' }])
  assert.equal(handler.pairingManager.stats().offers, 0)
})

test('revoke closes every live connection, drops the device row, and rename persists safe display metadata', async (t) => {
  const { handler } = setup(t)
  const phone = phoneRecord()
  handler.deviceStore.pairDevice(phone.record)
  const closed = []
  handler.deviceStore.registerConnection(phone.record.deviceId, (reason) => closed.push(reason))
  assert.equal(handler.getState().devices[0].connected, true)
  const renamed = await handler.renameDevice(phone.record.deviceId, 'Travel iPhone')
  assert.equal(renamed.devices[0].name, 'Travel iPhone')
  const revoked = await handler.revokeDevice(phone.record.deviceId)
  assert.deepEqual(closed, ['device_revoked'])
  assert.deepEqual(revoked.devices, [])
  assert.equal(handler.deviceStore.getDevice(phone.record.deviceId), null)
})

test('diagnostic state and device rows omit transport details, paths, and cryptographic records', async (t) => {
  const { directory, handler } = setup(t)
  const phone = phoneRecord(71, 'device-safe-row')
  handler.deviceStore.pairDevice(phone.record)
  handler.deviceStore.registerConnection(phone.record.deviceId, () => {})
  await handler.setEnabled(true)
  const state = handler.getState()
  assert.deepEqual(Object.keys(state.devices[0]).sort(), [
    'capabilities',
    'connected',
    'deviceId',
    'lastSeenAt',
    'name',
    'pairedAt',
  ])
  const diagnostics = JSON.stringify(state)
  for (const forbidden of [
    phone.identity.identityPublic,
    phone.identity.x25519StaticPublic,
    'transport-token-that-must-not-leak',
    '49321',
    '/private/secret/companion.sock',
    directory,
  ]) assert.equal(diagnostics.includes(forbidden), false, `state leaked ${forbidden}`)
})
