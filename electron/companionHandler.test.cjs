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
    this.refreshCalls = 0
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

  async refresh() {
    this.refreshCalls++
    return this.status()
  }

  confirmPairing(pairingId) {
    this.confirmed.push(pairingId)
    return true
  }

  cancelPairing(pairingId, reason) {
    this.cancelled.push({ pairingId, reason })
    return true
  }

  pairingTransportHint() {
    return this.enabled
      ? { service: '_kaisola._tcp', protocol: 'tcp', host: '192.168.1.23', port: 49321 }
      : { service: '_kaisola._tcp', protocol: 'tcp' }
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
      tailscaleAvailable: false,
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

function setup(t, {
  now = 1_784_250_100_000,
  accountRendezvous = null,
  directory: suppliedDirectory = null,
  setBackgroundLaunchEnabled = null,
  makeTransport = null,
  retryBaseMs,
  retryMaxMs,
} = {}) {
  const directory = suppliedDirectory ?? fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-handler-'))
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
    accountRendezvous,
    now: () => now,
    transportFactory: (options) => {
      transport = makeTransport ? makeTransport(options) : new FakeTransport(options)
      return transport
    },
    setBackgroundLaunchEnabled,
    retryBaseMs,
    retryMaxMs,
    logger: { warn() {} },
  })
  t.after(async () => {
    await handler.dispose()
    if (!suppliedDirectory) fs.rmSync(directory, { recursive: true, force: true })
  })
  return { directory, gateway, handler, handlers, ipcMain, removedHandlers, sent, transport }
}

test('Companion IPC is registered default-disabled without starting a LAN listener', (t) => {
  const { handler, handlers, transport } = setup(t)
  assert.deepEqual([...handlers.keys()], [...HANDLER_CHANNELS])
  assert.equal(transport.options.host, '0.0.0.0')
  assert.equal(transport.options.port, 49321)
  assert.equal(transport.enableCalls, 0)
  assert.deepEqual(handler.getState(), {
    enabled: false,
    listening: false,
    remote: { kind: 'tailscale', available: false },
    status: 'Companion is off. No local-network listener is running.',
    devices: [],
  })
})

test('enable then getState reflects a live loopback-and-LAN listener without exposing its port', async (t) => {
  const backgroundLaunch = []
  const { directory, handler, handlers, transport } = setup(t, {
    setBackgroundLaunchEnabled: (enabled) => backgroundLaunch.push(enabled),
  })
  const enabled = await handlers.get('companion:setEnabled')({}, { enabled: true })
  assert.equal(transport.enableCalls, 1)
  assert.equal(enabled.enabled, true)
  assert.equal(enabled.listening, true)
  assert.equal(enabled.status, 'Listening for paired devices on your local network.')
  assert.deepEqual(await handlers.get('companion:getState')(), enabled)
  assert.equal(JSON.stringify(enabled).includes('49321'), false)
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'companion', 'settings.json'), 'utf8')), {
    v: 1,
    enabled: true,
  })
  assert.deepEqual(backgroundLaunch, [true])
})

test('persisted Companion intent restores the listener after an app restart', async (t) => {
  const first = setup(t)
  await first.handler.setEnabled(true)
  await first.handler.dispose()

  const backgroundLaunch = []
  const second = setup(t, {
    directory: first.directory,
    setBackgroundLaunchEnabled: (enabled) => backgroundLaunch.push(enabled),
  })
  assert.equal(second.handler.getState().enabled, true)
  assert.equal(second.handler.getState().listening, false)
  const restored = await second.handler.restore()
  assert.equal(restored.enabled, true)
  assert.equal(restored.listening, true)
  assert.equal(second.transport.enableCalls, 1)
  assert.deepEqual(backgroundLaunch, [true])
})

test('a transient listener failure keeps intent on and heals automatically', async (t) => {
  class FailOnceTransport extends FakeTransport {
    async enable() {
      this.enableCalls++
      if (this.enableCalls === 1) throw new Error('network not ready after wake')
      this.enabled = true
      this.emit('enabled', this.status())
      return this.status()
    }
  }
  const { handler, transport } = setup(t, {
    makeTransport: (options) => new FailOnceTransport(options),
    retryBaseMs: 100,
    retryMaxMs: 100,
  })
  const initial = await handler.setEnabled(true)
  assert.equal(initial.enabled, true, 'saved intent remains on while the socket recovers')
  assert.equal(initial.listening, false)
  assert.match(initial.status, /reconnecting/)
  await new Promise((resolve) => setTimeout(resolve, 160))
  assert.equal(transport.enableCalls, 2)
  assert.equal(handler.getState().listening, true)
})

test('active Tailscale is reported without exposing its address or listener port', async (t) => {
  class TailscaleTransport extends FakeTransport {
    status() { return { ...super.status(), tailscaleAvailable: this.enabled } }
    pairingTransportHint() {
      return this.enabled
        ? { service: '_kaisola._tcp', protocol: 'tcp', host: '192.168.1.23', tailscaleHost: '100.90.1.14', port: 49321 }
        : { service: '_kaisola._tcp', protocol: 'tcp' }
    }
  }
  const { handler } = setup(t, { makeTransport: (options) => new TailscaleTransport(options) })
  const state = await handler.setEnabled(true)
  assert.equal(state.remote.available, true)
  assert.match(state.status, /LAN or away through Tailscale/)
  assert.equal(JSON.stringify(state).includes('100.90.1.14'), false)
  assert.equal(JSON.stringify(state).includes('49321'), false)
  const pairing = await handler.startPairing()
  assert.equal(JSON.parse(pairing.qrPayload).transportHint.tailscaleHost, '100.90.1.14')
})

test('wake refresh republishes the listener without dropping its connection', async (t) => {
  const { handler, transport } = setup(t)
  await handler.setEnabled(true)
  const refreshed = await handler.refresh()
  assert.equal(refreshed.listening, true)
  assert.equal(transport.refreshCalls, 1)
  assert.equal(transport.enableCalls, 1)
  assert.equal(transport.disableCalls, 0)
})

test('paired devices migrate to automatic listener restore when the preference is first introduced', async (t) => {
  const first = setup(t)
  first.handler.deviceStore.pairDevice(phoneRecord(61, 'device-existing-before-preference').record)
  await first.handler.dispose()
  fs.unlinkSync(path.join(first.directory, 'companion', 'settings.json'))

  const second = setup(t, { directory: first.directory })
  assert.equal(second.handler.getState().enabled, true)
  const restored = await second.handler.restore()
  assert.equal(restored.listening, true)
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
  assert.deepEqual(payload.transportHint, {
    service: '_kaisola._tcp',
    protocol: 'tcp',
    host: '192.168.1.23',
    port: 49321,
  })
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

test('a pairing offer is published for the signed-in account and withdrawn on cancellation', async (t) => {
  const published = []
  const withdrawn = []
  const accountRendezvous = {
    async publishOffer(payload) { published.push(payload); return true },
    async withdrawOffer(nonce) { withdrawn.push(nonce); return true },
  }
  const { handler } = setup(t, { accountRendezvous })
  await handler.setEnabled(true)
  const started = await handler.startPairing()
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(published.length, 1)
  assert.equal(published[0].pairingNonce, started.pairingId)
  assert.deepEqual(published[0].requestedCapabilities, ['observe', 'agent-control', 'terminal-control'])

  assert.deepEqual(await handler.cancelPairing(started.pairingId), { ok: true })
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(withdrawn, [started.pairingId])
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

test('per-device control grants persist and force an authenticated capability renegotiation', async (t) => {
  const { handler, handlers } = setup(t)
  const phone = phoneRecord()
  handler.deviceStore.pairDevice(phone.record)
  const closed = []
  handler.deviceStore.registerConnection(phone.record.deviceId, (reason) => closed.push(reason))

  const state = await handlers.get('companion:setDeviceCapabilities')({}, {
    deviceId: phone.record.deviceId,
    capabilities: ['observe', 'agent-control', 'terminal-control'],
  })
  assert.deepEqual(state.devices[0].capabilities, ['observe', 'agent-control', 'terminal-control'])
  assert.deepEqual(closed, ['device_capabilities_changed'])
  assert.equal(state.devices[0].connected, false)

  await assert.rejects(
    handlers.get('companion:setDeviceCapabilities')({}, {
      deviceId: phone.record.deviceId,
      capabilities: ['terminal-control'],
    }),
    /valid Companion access level/,
  )
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
