'use strict'

const { EventEmitter } = require('node:events')
const dgram = require('node:dgram')
const net = require('node:net')
const os = require('node:os')
const {
  MAX_SECURE_PLAINTEXT_BYTES,
  PROTOCOL_VERSION,
} = require('./crypto.cjs')

const SERVICE_TYPE = '_kaisola._tcp.local'
const MDNS_ADDRESS = '224.0.0.251'
const MDNS_PORT = 5353
const MDNS_TTL_SECONDS = 120
const MDNS_REFRESH_MS = 60 * 1000
const MAX_MDNS_PACKET_BYTES = 9000
const MAX_UNAUTHENTICATED_CLIENTS = 8
const MAX_HANDSHAKE_WIRE_BYTES = 64 * 1024
const MAX_SECURE_WIRE_BYTES = Math.ceil((MAX_SECURE_PLAINTEXT_BYTES + 16) * 4 / 3) + 2048
const MAX_SOCKET_QUEUE_BYTES = 1024 * 1024
const AUTHENTICATION_TIMEOUT_MS = 30 * 1000

function dnsName(value) {
  const labels = String(value).replace(/\.$/, '').split('.')
  const parts = []
  for (const label of labels) {
    const encoded = Buffer.from(label, 'utf8')
    if (!encoded.length || encoded.length > 63) throw new Error('mDNS label is invalid')
    parts.push(Buffer.from([encoded.length]), encoded)
  }
  parts.push(Buffer.from([0]))
  return Buffer.concat(parts)
}

function readDnsName(packet, offset, depth = 0) {
  if (depth > 4) throw new Error('mDNS compression loop')
  const labels = []
  let cursor = offset
  let consumed = 0
  let jumped = false
  while (cursor < packet.length) {
    const length = packet[cursor]
    if ((length & 0xc0) === 0xc0) {
      if (cursor + 1 >= packet.length) throw new Error('truncated mDNS pointer')
      const pointer = ((length & 0x3f) << 8) | packet[cursor + 1]
      const nested = readDnsName(packet, pointer, depth + 1)
      labels.push(nested.name)
      if (!jumped) consumed += 2
      jumped = true
      break
    }
    cursor++
    if (!jumped) consumed++
    if (length === 0) break
    if (length > 63 || cursor + length > packet.length) throw new Error('invalid mDNS name')
    labels.push(packet.subarray(cursor, cursor + length).toString('utf8'))
    cursor += length
    if (!jumped) consumed += length
  }
  return { name: labels.filter(Boolean).join('.'), bytes: consumed }
}

function parseDnsQuestions(packet) {
  if (!Buffer.isBuffer(packet) || packet.length < 12 || packet.length > MAX_MDNS_PACKET_BYTES) return []
  const count = packet.readUInt16BE(4)
  if (count > 32) return []
  const questions = []
  let offset = 12
  try {
    for (let index = 0; index < count; index++) {
      const name = readDnsName(packet, offset)
      offset += name.bytes
      if (offset + 4 > packet.length) return []
      questions.push({ name: name.name.toLowerCase(), type: packet.readUInt16BE(offset), class: packet.readUInt16BE(offset + 2) & 0x7fff })
      offset += 4
    }
  } catch { return [] }
  return questions
}

function dnsRecord(name, type, recordClass, ttl, data) {
  const header = Buffer.alloc(10)
  header.writeUInt16BE(type, 0)
  header.writeUInt16BE(recordClass, 2)
  header.writeUInt32BE(ttl, 4)
  header.writeUInt16BE(data.length, 8)
  return Buffer.concat([dnsName(name), header, data])
}

function txtData(values) {
  const records = []
  for (const value of values) {
    const encoded = Buffer.from(value, 'utf8')
    if (encoded.length > 255) throw new Error('mDNS TXT value is too large')
    records.push(Buffer.from([encoded.length]), encoded)
  }
  return Buffer.concat(records)
}

function ipv4Bytes(address) {
  const octets = String(address).split('.').map(Number)
  if (octets.length !== 4 || octets.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) throw new Error('IPv4 address is invalid')
  return Buffer.from(octets)
}

function serviceNames(desktopId) {
  const suffix = String(desktopId).replace(/[^A-Za-z0-9-]/g, '').slice(-16) || 'desktop'
  return {
    service: SERVICE_TYPE,
    instance: `Kaisola-${suffix}.${SERVICE_TYPE}`,
    host: `kaisola-${suffix}.local`,
  }
}

function encodeMdnsResponse({ desktopId, port, addresses, ttl = MDNS_TTL_SECONDS }) {
  const names = serviceNames(desktopId)
  const srv = Buffer.alloc(6)
  srv.writeUInt16BE(0, 0)
  srv.writeUInt16BE(0, 2)
  srv.writeUInt16BE(port, 4)
  const records = [
    dnsRecord(names.service, 12, 1, ttl, dnsName(names.instance)),
    dnsRecord(names.instance, 33, 0x8001, ttl, Buffer.concat([srv, dnsName(names.host)])),
    dnsRecord(names.instance, 16, 0x8001, ttl, txtData([`v=${PROTOCOL_VERSION}`, `id=${desktopId}`])),
    ...addresses.map((address) => dnsRecord(names.host, 1, 0x8001, ttl, ipv4Bytes(address))),
  ]
  const header = Buffer.alloc(12)
  header.writeUInt16BE(0x8400, 2)
  header.writeUInt16BE(records.length, 6)
  return Buffer.concat([header, ...records])
}

function localIpv4Addresses(networkInterfaces = os.networkInterfaces()) {
  const addresses = new Set()
  for (const entries of Object.values(networkInterfaces)) {
    for (const entry of entries ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) addresses.add(entry.address)
    }
  }
  return [...addresses]
}

class MinimalMdnsAdvertiser {
  constructor({ socketFactory = (options) => dgram.createSocket(options), networkInterfaces = os.networkInterfaces, logger } = {}) {
    this.socketFactory = socketFactory
    this.networkInterfaces = networkInterfaces
    this.logger = logger
    this.socket = null
    this.refreshTimer = null
    this.config = null
  }

  async start({ desktopId, port }) {
    if (this.socket) return false
    const addresses = localIpv4Addresses(this.networkInterfaces())
    this.config = { desktopId, port, addresses }
    const socket = this.socketFactory({ type: 'udp4', reuseAddr: true })
    this.socket = socket
    socket.on('error', (error) => {
      this.logger?.warn?.(`Companion mDNS error: ${String(error?.message || 'unknown').slice(0, 200)}`)
    })
    socket.on('message', (packet) => {
      const names = serviceNames(desktopId)
      const wanted = new Set([names.service, names.instance, names.host].map((name) => name.toLowerCase()))
      if (parseDnsQuestions(packet).some((question) => question.class === 1 && (question.type === 255 || [1, 12, 16, 33].includes(question.type)) && wanted.has(question.name))) {
        this.#announce(MDNS_TTL_SECONDS)
      }
    })
    await new Promise((resolve, reject) => {
      const onError = (error) => { socket.off('listening', onListening); reject(error) }
      const onListening = () => { socket.off('error', onError); resolve() }
      socket.once('error', onError)
      socket.once('listening', onListening)
      socket.bind(MDNS_PORT, '0.0.0.0')
    })
    for (const address of addresses) {
      try { socket.addMembership(MDNS_ADDRESS, address) } catch { /* another interface can still advertise */ }
    }
    socket.setMulticastTTL?.(255)
    this.#announce(MDNS_TTL_SECONDS)
    this.refreshTimer = setInterval(() => this.#announce(MDNS_TTL_SECONDS), MDNS_REFRESH_MS)
    this.refreshTimer.unref?.()
    return true
  }

  #announce(ttl) {
    if (!this.socket || !this.config) return false
    try {
      const packet = encodeMdnsResponse({ ...this.config, ttl })
      this.socket.send(packet, MDNS_PORT, MDNS_ADDRESS)
      return true
    } catch { return false }
  }

  async stop() {
    if (!this.socket) return false
    clearInterval(this.refreshTimer)
    this.refreshTimer = null
    this.#announce(0)
    const socket = this.socket
    this.socket = null
    this.config = null
    await new Promise((resolve) => {
      try { socket.close(resolve) } catch { resolve() }
    })
    return true
  }
}

function encodeWireFrame(value) {
  const payload = Buffer.from(JSON.stringify(value), 'utf8')
  const header = Buffer.alloc(4)
  header.writeUInt32BE(payload.length, 0)
  return Buffer.concat([header, payload])
}

class LengthFrameDecoder {
  constructor() {
    this.buffer = Buffer.alloc(0)
  }

  push(chunk, maxFrameBytes) {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : Buffer.from(chunk)
    if (this.buffer.length > maxFrameBytes + 4 && (this.buffer.length < 4 || this.buffer.readUInt32BE(0) > maxFrameBytes)) throw new Error('wire frame exceeds limit')
    const frames = []
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32BE(0)
      if (!length || length > maxFrameBytes) throw new Error('wire frame exceeds limit')
      if (this.buffer.length < length + 4) break
      const payload = this.buffer.subarray(4, length + 4)
      this.buffer = this.buffer.subarray(length + 4)
      try { frames.push(JSON.parse(payload.toString('utf8'))) } catch { throw new Error('wire frame is invalid') }
    }
    return frames
  }
}

function writeWireFrame(socket, value, maxQueueBytes = MAX_SOCKET_QUEUE_BYTES) {
  if (!socket || socket.destroyed) return false
  const encoded = encodeWireFrame(value)
  if (encoded.length > MAX_SECURE_WIRE_BYTES + 4 || socket.writableLength + encoded.length > maxQueueBytes) return false
  try { return socket.write(encoded) } catch { return false }
}

class SecureSocketTransport {
  constructor({ socket, channel, maxQueueBytes = MAX_SOCKET_QUEUE_BYTES, onClose } = {}) {
    this.socket = socket
    this.channel = channel
    this.maxQueueBytes = maxQueueBytes
    this.receiver = null
    this.closed = false
    this.closeReason = null
    this.onClose = onClose
  }

  bindGateway(receiver) {
    if (this.receiver || typeof receiver !== 'function') throw new Error('secure transport gateway receiver is invalid')
    this.receiver = receiver
  }

  async receiveWireFrame(frame) {
    if (this.closed || !this.receiver) throw new Error('secure transport is unavailable')
    return this.receiver(this.channel.decrypt(frame, { json: true }))
  }

  sendToDevice(frame) {
    if (this.closed) return false
    return writeWireFrame(this.socket, this.channel.encrypt(frame), this.maxQueueBytes)
  }

  close(reason = 'closed') {
    if (this.closed) return false
    this.closed = true
    this.closeReason = String(reason)
    try { this.socket.destroy() } catch { /* already closed */ }
    this.onClose?.()
    return true
  }

  stats() {
    return {
      closed: this.closed,
      closeReason: this.closeReason,
      queuedBytes: this.socket?.writableLength ?? 0,
      counters: this.channel.stats(),
    }
  }
}

class BonjourCompanionTransport extends EventEmitter {
  constructor({
    gateway,
    pairingManager,
    deviceStore,
    host = '0.0.0.0',
    port = 0,
    serverFactory = (handler) => net.createServer(handler),
    advertiserFactory = () => new MinimalMdnsAdvertiser(),
    maxUnauthenticatedClients = MAX_UNAUTHENTICATED_CLIENTS,
    authenticationTimeoutMs = AUTHENTICATION_TIMEOUT_MS,
    logger,
  } = {}) {
    super()
    if (!gateway || typeof gateway.attach !== 'function') throw new Error('companion gateway is required')
    if (!pairingManager || typeof pairingManager.startPairing !== 'function') throw new Error('pairing manager is required')
    if (!deviceStore || typeof deviceStore.registerConnection !== 'function') throw new Error('device store is required')
    this.gateway = gateway
    this.pairingManager = pairingManager
    this.deviceStore = deviceStore
    this.host = host
    this.port = port
    this.serverFactory = serverFactory
    this.advertiserFactory = advertiserFactory
    this.maxUnauthenticatedClients = maxUnauthenticatedClients
    this.authenticationTimeoutMs = authenticationTimeoutMs
    this.logger = logger
    this.enabled = false
    this.server = null
    this.advertiser = null
    this.connections = new Set()
    this.pairingSockets = new Map()
    this.unauthenticatedClients = 0
  }

  async enable() {
    if (this.enabled) return this.status()
    const server = this.serverFactory((socket) => this.#accept(socket))
    this.server = server
    await new Promise((resolve, reject) => {
      const onError = (error) => { server.off('listening', onListening); reject(error) }
      const onListening = () => { server.off('error', onError); resolve() }
      server.once('error', onError)
      server.once('listening', onListening)
      server.listen({ host: this.host, port: this.port })
    })
    const address = server.address()
    this.advertiser = this.advertiserFactory()
    try {
      await this.advertiser.start({ desktopId: this.deviceStore.desktopIdentity().id, port: address.port })
    } catch (error) {
      await new Promise((resolve) => server.close(resolve))
      this.server = null
      this.advertiser = null
      throw error
    }
    this.enabled = true
    this.emit('enabled', this.status())
    return this.status()
  }

  async disable() {
    if (!this.server && !this.enabled) return false
    this.enabled = false
    for (const state of [...this.connections]) this.#closeState(state, 'companion_disabled')
    this.pairingSockets.clear()
    const advertiser = this.advertiser
    const server = this.server
    this.advertiser = null
    this.server = null
    if (advertiser) await advertiser.stop()
    if (server) await new Promise((resolve) => {
      try { server.close(resolve) } catch { resolve() }
    })
    this.emit('disabled')
    return true
  }

  #accept(socket) {
    if (!this.enabled && !this.server) { socket.destroy(); return }
    if (this.unauthenticatedClients >= this.maxUnauthenticatedClients) { socket.destroy(); return }
    this.unauthenticatedClients++
    const state = {
      socket,
      decoder: new LengthFrameDecoder(),
      phase: 'bootstrap',
      authenticated: false,
      closed: false,
      processing: Promise.resolve(),
      sessionId: null,
      secureTransport: null,
      unregisterDeviceConnection: null,
    }
    this.connections.add(state)
    const timer = setTimeout(() => this.#closeState(state, 'authentication_timeout'), this.authenticationTimeoutMs)
    timer.unref?.()
    state.authTimer = timer
    socket.setNoDelay?.(true)
    socket.on('data', (chunk) => {
      if (state.closed) return
      let frames
      try { frames = state.decoder.push(chunk, state.authenticated ? MAX_SECURE_WIRE_BYTES : MAX_HANDSHAKE_WIRE_BYTES) } catch { this.#closeState(state, 'invalid_frame'); return }
      for (const frame of frames) {
        state.processing = state.processing.then(() => this.#handleFrame(state, frame)).catch(() => this.#closeState(state, 'authentication_failed'))
      }
    })
    socket.on('error', () => this.#closeState(state, 'socket_error'))
    socket.on('close', () => this.#closeState(state, 'socket_closed'))
  }

  async #handleFrame(state, frame) {
    if (state.closed) return
    if (state.authenticated) {
      await state.secureTransport.receiveWireFrame(frame)
      return
    }
    if (!frame || typeof frame !== 'object' || Array.isArray(frame) || frame.v !== PROTOCOL_VERSION) throw new Error('invalid handshake frame')
    if (state.phase === 'bootstrap') {
      let response
      if (frame.type === 'pair.start') {
        response = this.pairingManager.startPairing({ qrPayload: frame.qrPayload, connectionId: frame.connectionId, message1: frame.message1 })
        state.kind = 'pair'
        state.pairingId = response.pairingId
      } else if (frame.type === 'resume.start') {
        response = this.pairingManager.startResume({ deviceId: frame.deviceId, connectionId: frame.connectionId, message1: frame.message1 })
        state.kind = 'resume'
      } else throw new Error('invalid handshake start')
      state.sessionId = response.sessionId
      state.phase = 'awaiting_message_3'
      this.pairingSockets.set(state.sessionId, state)
      if (!writeWireFrame(state.socket, { v: PROTOCOL_VERSION, type: `${state.kind}.message2`, ...response })) throw new Error('slow client')
      return
    }
    if (state.phase === 'awaiting_message_3') {
      if (frame.type !== `${state.kind}.message3` || frame.sessionId !== state.sessionId || typeof frame.message3 !== 'string') throw new Error('invalid handshake message')
      const completed = this.pairingManager.completeHandshake(state.sessionId, frame.message3)
      state.pairingDetails = completed
      state.phase = 'awaiting_key_confirmation'
      if (!writeWireFrame(state.socket, {
        v: PROTOCOL_VERSION,
        type: `${state.kind}.confirmation`,
        sessionId: state.sessionId,
        confirmationFrame: completed.confirmationFrame,
        ...(completed.sas ? { sas: completed.sas } : {}),
      })) throw new Error('slow client')
      return
    }
    if (state.phase === 'awaiting_key_confirmation') {
      this.pairingManager.receiveKeyConfirmation(state.sessionId, frame)
      if (state.kind === 'resume') this.#activate(state)
      else {
        state.phase = 'awaiting_sas_confirmation'
        this.emit('pairingPhrase', {
          pairingId: state.pairingId,
          sessionId: state.sessionId,
          device: state.pairingDetails.device,
          sas: state.pairingDetails.sas,
        })
      }
      return
    }
    if (state.phase === 'awaiting_sas_confirmation') {
      const result = this.pairingManager.receiveRemoteSasConfirmation(state.sessionId, frame)
      if (result.paired) {
        if (!writeWireFrame(state.socket, result.pairedFrame)) throw new Error('slow client')
        this.#activate(state)
      }
      return
    }
    throw new Error('handshake frame is out of order')
  }

  confirmPairing(pairingId) {
    const id = String(pairingId)
    const state = [...this.pairingSockets.values()].find((candidate) => candidate.pairingId === id)
      ?? this.pairingSockets.get(id)
    if (!state || state.closed || state.kind !== 'pair' || state.phase !== 'awaiting_sas_confirmation') return false
    const result = this.pairingManager.confirmLocalSas(state.sessionId)
    if (!writeWireFrame(state.socket, result.sasFrame)) { this.#closeState(state, 'slow_client'); return false }
    if (result.paired) {
      if (!writeWireFrame(state.socket, result.pairedFrame)) { this.#closeState(state, 'slow_client'); return false }
      this.#activate(state)
    }
    return true
  }

  cancelPairing(pairingId, reason = 'pairing_cancelled') {
    const id = String(pairingId)
    let cancelled = false
    for (const state of [...this.pairingSockets.values()]) {
      if (state.pairingId !== id || state.kind !== 'pair' || state.authenticated) continue
      cancelled = this.#closeState(state, reason) || cancelled
    }
    return this.pairingManager.cancelPairing(id) || cancelled
  }

  #activate(state) {
    const authenticated = this.pairingManager.authenticatedConnection(state.sessionId)
    state.authenticated = true
    state.phase = 'authenticated'
    clearTimeout(state.authTimer)
    this.unauthenticatedClients = Math.max(0, this.unauthenticatedClients - 1)
    const secureTransport = new SecureSocketTransport({
      socket: state.socket,
      channel: authenticated.channel,
      onClose: () => this.#closeState(state, 'secure_transport_closed'),
    })
    state.secureTransport = secureTransport
    state.unregisterDeviceConnection = this.deviceStore.registerConnection(authenticated.device.deviceId, (reason) => secureTransport.close(reason))
    state.gatewaySession = this.gateway.attach(secureTransport, authenticated.device)
    this.emit('authenticated', {
      deviceId: authenticated.device.deviceId,
      connectionId: authenticated.connectionId,
      mode: authenticated.kind,
      ...(authenticated.kind === 'pair' ? { pairingId: state.pairingId } : {}),
    })
  }

  #closeState(state, reason) {
    if (!state || state.closed) return false
    state.closed = true
    clearTimeout(state.authTimer)
    this.connections.delete(state)
    if (!state.authenticated) this.unauthenticatedClients = Math.max(0, this.unauthenticatedClients - 1)
    if (state.sessionId) {
      this.pairingSockets.delete(state.sessionId)
      this.pairingManager.releaseSession(state.sessionId)
    }
    if (state.gatewaySession && !state.gatewaySession.closed && typeof state.gatewaySession.close === 'function') {
      try { state.gatewaySession.close(reason) } catch { /* socket teardown remains authoritative */ }
    }
    state.unregisterDeviceConnection?.()
    if (state.secureTransport && !state.secureTransport.closed) {
      state.secureTransport.closed = true
      state.secureTransport.closeReason = reason
    }
    try { if (!state.socket.destroyed) state.socket.destroy() } catch { /* already closed */ }
    if (state.kind === 'pair' && !state.authenticated && state.pairingId) {
      this.emit('pairingFailed', { pairingId: state.pairingId, reason })
    }
    return true
  }

  status() {
    const address = this.server?.address?.()
    return {
      enabled: this.enabled,
      service: SERVICE_TYPE.replace(/\.local$/, ''),
      host: this.host,
      port: address && typeof address === 'object' ? address.port : null,
      connections: this.connections.size,
      unauthenticatedClients: this.unauthenticatedClients,
    }
  }
}

module.exports = {
  AUTHENTICATION_TIMEOUT_MS,
  BonjourCompanionTransport,
  LengthFrameDecoder,
  MAX_HANDSHAKE_WIRE_BYTES,
  MAX_MDNS_PACKET_BYTES,
  MAX_SECURE_WIRE_BYTES,
  MAX_SOCKET_QUEUE_BYTES,
  MAX_UNAUTHENTICATED_CLIENTS,
  MDNS_ADDRESS,
  MDNS_PORT,
  MDNS_TTL_SECONDS,
  MinimalMdnsAdvertiser,
  SERVICE_TYPE,
  SecureSocketTransport,
  dnsName,
  encodeMdnsResponse,
  encodeWireFrame,
  localIpv4Addresses,
  parseDnsQuestions,
  serviceNames,
  writeWireFrame,
}
