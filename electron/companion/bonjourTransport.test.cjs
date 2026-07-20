'use strict'

const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const {
  BonjourCompanionTransport,
  LengthFrameDecoder,
  MAX_HANDSHAKE_WIRE_BYTES,
  SERVICE_TYPE,
  dnsName,
  encodeMdnsResponse,
  encodeWireFrame,
  localIpv4Addresses,
  preferredLocalIpv4Address,
  parseDnsQuestions,
} = require('./bonjourTransport.cjs')
const { CompanionDeviceStore } = require('./deviceStore.cjs')
const {
  NoiseXXInitiator,
  b64url,
  createNoisePrologue,
  createSecureChannel,
  identityFromSeeds,
  makeKeyConfirmation,
  verifyKeyConfirmation,
} = require('./crypto.cjs')
const { CompanionPairingManager, resumeHandshakeContext } = require('./pairing.cjs')

function safeStorage() {
  return {
    isEncryptionAvailable: () => true,
    encryptString: (value) => Buffer.from(`safe:${value}`, 'utf8'),
    decryptString: (value) => value.toString('utf8').slice(5),
  }
}

function memoryNetwork() {
  let handler = null
  let server = null
  class MemorySocket extends EventEmitter {
    constructor() {
      super()
      this.destroyed = false
      this.writableLength = 0
      this.peer = null
    }
    setNoDelay() {}
    write(value) {
      if (this.destroyed) return false
      const data = Buffer.from(value)
      queueMicrotask(() => { if (!this.peer.destroyed) this.peer.emit('data', data) })
      return true
    }
    destroy() {
      if (this.destroyed) return
      this.destroyed = true
      queueMicrotask(() => this.emit('close'))
      if (this.peer && !this.peer.destroyed) {
        this.peer.destroyed = true
        queueMicrotask(() => this.peer.emit('close'))
      }
    }
  }
  return {
    serverFactory(connectionHandler) {
      handler = connectionHandler
      server = new EventEmitter()
      server.listen = () => queueMicrotask(() => server.emit('listening'))
      server.address = () => ({ address: '127.0.0.1', family: 'IPv4', port: 49321 })
      server.close = (callback) => queueMicrotask(callback)
      return server
    },
    connect() {
      const client = new MemorySocket()
      const accepted = new MemorySocket()
      client.peer = accepted
      accepted.peer = client
      handler(accepted)
      return client
    },
  }
}

function setup(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-bonjour-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const desktop = identityFromSeeds({
    id: 'desktop-bonjour-test', role: 'desktop', displayName: 'Michael Mac',
    identitySeed: Buffer.alloc(32, 111), staticSeed: Buffer.alloc(32, 112),
  })
  const phone = identityFromSeeds({
    id: 'device-bonjour-test', role: 'device', displayName: "Michael's iPhone",
    identitySeed: Buffer.alloc(32, 113), staticSeed: Buffer.alloc(32, 114),
  })
  const store = new CompanionDeviceStore({
    filePath: path.join(directory, 'devices.json'), safeStorage: safeStorage(), identityFactory: () => desktop,
  })
  store.pairDevice({
    deviceId: phone.id,
    displayName: phone.displayName,
    identityPublic: phone.identityPublic,
    x25519StaticPublic: phone.x25519StaticPublic,
    capabilities: ['observe'],
  })
  let uuid = 0
  const manager = new CompanionPairingManager({ deviceStore: store, randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, '0')}` })
  const inbound = []
  let attachedTransport = null
  const gateway = {
    attach(transport, device) {
      attachedTransport = transport
      assert.equal(device.deviceId, phone.id)
      transport.bindGateway(async (frame) => { inbound.push(frame); return { ok: true } })
      return { device }
    },
  }
  const advertiser = {
    starts: [], stops: 0,
    async start(value) { this.starts.push(value) },
    async stop() { this.stops++; return true },
  }
  const network = memoryNetwork()
  const service = new BonjourCompanionTransport({
    gateway,
    pairingManager: manager,
    deviceStore: store,
    host: '127.0.0.1',
    serverFactory: network.serverFactory,
    advertiserFactory: () => advertiser,
  })
  t.after(async () => { await service.disable() })
  return { advertiser, desktop, phone, store, manager, gateway, inbound, network, service, attachedTransport: () => attachedTransport }
}

function queryPacket(name, type = 12) {
  const header = Buffer.alloc(12)
  header.writeUInt16BE(1, 4)
  const trailer = Buffer.alloc(4)
  trailer.writeUInt16BE(type, 0)
  trailer.writeUInt16BE(1, 2)
  return Buffer.concat([header, dnsName(name), trailer])
}

function socketFrames(socket) {
  const decoder = new LengthFrameDecoder()
  const frames = []
  const waiters = []
  socket.on('data', (chunk) => {
    for (const frame of decoder.push(chunk, 2 * 1024 * 1024)) {
      const waiter = waiters.shift()
      if (waiter) waiter.resolve(frame)
      else frames.push(frame)
    }
  })
  socket.on('error', (error) => {
    while (waiters.length) waiters.shift().reject(error)
  })
  return {
    next(timeoutMs = 2000) {
      if (frames.length) return Promise.resolve(frames.shift())
      return new Promise((resolve, reject) => {
        const waiter = { resolve, reject }
        waiters.push(waiter)
        const timer = setTimeout(() => {
          const index = waiters.indexOf(waiter)
          if (index >= 0) waiters.splice(index, 1)
          reject(new Error('timed out waiting for transport frame'))
        }, timeoutMs)
        const original = waiter.resolve
        waiter.resolve = (value) => { clearTimeout(timer); original(value) }
      })
    },
  }
}

test('minimal in-repo mDNS encoding advertises PTR, SRV, TXT, and local-interface A records', () => {
  const questions = parseDnsQuestions(queryPacket('_kaisola._tcp.local'))
  assert.deepEqual(questions, [{ name: '_kaisola._tcp.local', type: 12, class: 1 }])
  const response = encodeMdnsResponse({ desktopId: 'desktop-mdns-vector', port: 49321, addresses: ['192.168.1.23'], ttl: 120 })
  assert.equal(response.readUInt16BE(2), 0x8400)
  assert.equal(response.readUInt16BE(6), 4)
  assert.ok(response.includes(Buffer.from('_kaisola', 'utf8')))
  assert.ok(response.includes(Buffer.from('v=1', 'utf8')))
  assert.ok(response.includes(Buffer.from([192, 168, 1, 23])))
  assert.deepEqual(localIpv4Addresses({
    en0: [{ family: 'IPv4', internal: false, address: '192.168.1.23' }],
    lo0: [{ family: 'IPv4', internal: true, address: '127.0.0.1' }],
  }), ['192.168.1.23'])
  assert.equal(preferredLocalIpv4Address({
    utun4: [{ family: 'IPv4', internal: false, address: '100.64.0.4' }],
    en0: [{ family: 'IPv4', internal: false, address: '192.168.1.23' }],
  }), '192.168.1.23')
})

test('Bonjour listener and advertisement remain disabled until the explicit enable call', async (t) => {
  const { advertiser, service, store } = setup(t)
  assert.deepEqual(service.status(), {
    enabled: false,
    service: '_kaisola._tcp',
    host: '127.0.0.1',
    port: null,
    connections: 0,
    unauthenticatedClients: 0,
  })
  assert.equal(advertiser.starts.length, 0)
  const enabled = await service.enable()
  assert.equal(enabled.enabled, true)
  assert.ok(enabled.port > 0)
  assert.deepEqual(advertiser.starts, [{ desktopId: store.desktopIdentity().id, port: enabled.port }])
  const hint = service.pairingTransportHint()
  assert.equal(hint.service, '_kaisola._tcp')
  assert.equal(hint.protocol, 'tcp')
  assert.equal(hint.port, enabled.port)
  if (hint.host != null) assert.match(hint.host, /^\d{1,3}(?:\.\d{1,3}){3}$/)
  assert.equal(await service.disable(), true)
  assert.equal(advertiser.stops, 1)
  assert.equal(service.status().enabled, false)
})

test('direct TCP resume performs Noise XX, explicit key confirmation, encrypted gateway frames, replay defense, and live revocation', async (t) => {
  const { desktop, phone, store, inbound, network, service, attachedTransport } = setup(t)
  const enabled = await service.enable()
  const socket = network.connect()
  t.after(() => socket.destroy())
  const received = socketFrames(socket)
  const connectionId = 'connection-bonjour-resume'
  const context = resumeHandshakeContext({ desktopId: desktop.id, deviceId: phone.id, connectionId })
  const initiator = new NoiseXXInitiator({
    identity: phone,
    prologue: createNoisePrologue(context),
    peerPin: { id: desktop.id, identityPublic: desktop.identityPublic, x25519StaticPublic: desktop.x25519StaticPublic },
  })
  socket.write(encodeWireFrame({
    v: 1,
    type: 'resume.start',
    deviceId: phone.id,
    connectionId,
    message1: b64url(initiator.writeMessage1()),
  }))
  const message2 = await received.next()
  assert.equal(message2.type, 'resume.message2')
  initiator.readMessage2(message2.message2)
  socket.write(encodeWireFrame({ v: 1, type: 'resume.message3', sessionId: message2.sessionId, message3: b64url(initiator.writeMessage3()) }))
  const confirmation = await received.next()
  assert.equal(confirmation.type, 'resume.confirmation')
  const result = initiator.result()
  const channel = createSecureChannel(result, { desktopId: desktop.id, deviceId: phone.id, connectionId }, 'device')
  verifyKeyConfirmation(channel, confirmation.confirmationFrame, 'desktop', result.handshakeHash)
  const authenticated = new Promise((resolve) => service.once('authenticated', resolve))
  socket.write(encodeWireFrame(makeKeyConfirmation(channel, 'device', result.handshakeHash)))
  assert.deepEqual(await authenticated, { deviceId: phone.id, connectionId, mode: 'resume' })

  const hello = { v: 1, kind: 'hello', connectionId, body: { type: 'hello', role: 'device' } }
  const encryptedHello = channel.encrypt(hello)
  socket.write(encodeWireFrame(encryptedHello))
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.deepEqual(inbound, [hello])
  assert.equal(attachedTransport().sendToDevice({ kind: 'event', body: { type: 'desktop.status', online: true } }), true)
  assert.deepEqual(channel.decrypt(await received.next(), { json: true }), { kind: 'event', body: { type: 'desktop.status', online: true } })

  socket.write(encodeWireFrame(encryptedHello))
  await new Promise((resolve) => socket.once('close', resolve))
  assert.deepEqual(inbound, [hello])

  // A fresh authenticated connection is also dropped synchronously by record revocation.
  const closeReasons = []
  store.registerConnection(phone.id, (reason) => closeReasons.push(reason))
  assert.equal(store.revokeDevice(phone.id), true)
  assert.deepEqual(closeReasons, ['device_revoked'])
})

test('wire decoder bounds malformed unauthenticated work before JSON or cryptography', () => {
  const decoder = new LengthFrameDecoder()
  const oversized = Buffer.alloc(4)
  oversized.writeUInt32BE(MAX_HANDSHAKE_WIRE_BYTES + 1)
  assert.throws(() => decoder.push(oversized, MAX_HANDSHAKE_WIRE_BYTES), /exceeds limit/)
  assert.throws(() => new LengthFrameDecoder().push(Buffer.concat([Buffer.from([0, 0, 0, 1]), Buffer.from('{')]), MAX_HANDSHAKE_WIRE_BYTES), /invalid/)
  assert.equal(SERVICE_TYPE, '_kaisola._tcp.local')
})
