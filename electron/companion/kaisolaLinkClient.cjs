'use strict'

const { EventEmitter } = require('node:events')
const {
  MAX_RELAY_MESSAGE_BYTES,
  MUX_CLOSE,
  MUX_DATA,
  MUX_OPEN,
  decodeMuxFrame,
  encodeMuxFrame,
} = require('./linkProtocol.cjs')

const MAX_TICKET_RESPONSE_BYTES = 64 * 1024
const MAX_BUFFERED_BYTES = 4 * 1024 * 1024
const RETRY_BASE_MS = 1_000
const RETRY_MAX_MS = 30_000
const HEARTBEAT_MS = 20_000
const SOCKET_READY_TIMEOUT_MS = 10_000
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$/

function relayBaseUrl(config) {
  const value = config?.relayUrl
  let url
  try { url = new URL(value) } catch { return null }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) return null
  url.pathname = url.pathname.replace(/\/+$/, '')
  url.search = ''
  url.hash = ''
  return url
}

function ticketUrl(config) {
  const url = relayBaseUrl(config)
  if (!url) return null
  url.pathname = `${url.pathname}/v1/ticket`.replace(/\/+/g, '/')
  return url
}

function validateWebSocketUrl(value, base) {
  let url
  try { url = new URL(value) } catch { return null }
  if (url.protocol !== 'wss:' || url.hostname !== base.hostname || url.port !== base.port
      || url.username || url.password || !url.pathname.startsWith('/v1/connect/')) return null
  return url.toString()
}

class RelayVirtualSocket extends EventEmitter {
  constructor({ client, channelId }) {
    super()
    this.client = client
    this.channelId = channelId
    this.destroyed = false
  }

  get writableLength() { return this.client.bufferedAmount() }
  setNoDelay() { return this }

  write(value) {
    if (this.destroyed) throw new Error('relay socket is closed')
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value)
    if (!bytes.length || bytes.length > MAX_RELAY_MESSAGE_BYTES - 64 || !this.client.sendChannel(this.channelId, bytes)) {
      throw new Error('relay socket is unavailable')
    }
    return this.writableLength < MAX_BUFFERED_BYTES
  }

  receive(value) {
    if (!this.destroyed) this.emit('data', Buffer.from(value))
  }

  destroy() {
    if (this.destroyed) return this
    this.destroyed = true
    this.client.closeChannel(this.channelId)
    queueMicrotask(() => this.emit('close'))
    return this
  }

  remoteClose() {
    if (this.destroyed) return false
    this.destroyed = true
    queueMicrotask(() => this.emit('close'))
    return true
  }
}

class KaisolaLinkClient extends EventEmitter {
  constructor({
    desktopId,
    acceptSocket,
    tokenProvider,
    configProvider,
    fetchImpl = globalThis.fetch,
    webSocketFactory = (url) => new WebSocket(url),
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    now = Date.now,
    logger = console,
  } = {}) {
    super()
    if (!IDENTIFIER.test(desktopId) || typeof acceptSocket !== 'function' || typeof tokenProvider !== 'function'
        || typeof configProvider !== 'function' || typeof fetchImpl !== 'function' || typeof webSocketFactory !== 'function') {
      throw new Error('Kaisola Link dependencies are invalid')
    }
    this.desktopId = desktopId
    this.acceptSocket = acceptSocket
    this.tokenProvider = tokenProvider
    this.configProvider = configProvider
    this.fetchImpl = fetchImpl
    this.webSocketFactory = webSocketFactory
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.now = now
    this.logger = logger
    this.desired = false
    this.phase = 'off'
    this.socket = null
    this.channels = new Map()
    this.retryTimer = null
    this.heartbeatTimer = null
    this.readyTimer = null
    this.retryAttempt = 0
    this.connectionGeneration = 0
    this.lastConnectedAt = null
  }

  enable() {
    this.desired = true
    if (!relayBaseUrl(this.configProvider())) {
      this.#setPhase('unavailable')
      return this.status()
    }
    if (!this.socket && !this.retryTimer) void this.#connect()
    return this.status()
  }

  disable() {
    this.desired = false
    this.connectionGeneration++
    this.#cancelRetry()
    this.#cancelHeartbeat()
    this.#cancelReadyDeadline()
    const socket = this.socket
    this.socket = null
    try { socket?.close?.(1000, 'disabled') } catch { /* already closed */ }
    this.#closeChannels()
    this.retryAttempt = 0
    this.#setPhase('off')
    return this.status()
  }

  refresh() {
    if (!this.desired || this.phase === 'ready' || this.phase === 'connecting') return this.status()
    this.#cancelRetry()
    this.retryAttempt = 0
    void this.#connect()
    return this.status()
  }

  status() {
    return {
      configured: !!relayBaseUrl(this.configProvider()),
      connected: this.phase === 'ready',
      phase: this.phase,
      channels: this.channels.size,
      ...(Number.isSafeInteger(this.lastConnectedAt) ? { lastConnectedAt: this.lastConnectedAt } : {}),
    }
  }

  bufferedAmount() {
    return Number(this.socket?.bufferedAmount || 0)
  }

  sendChannel(channelId, bytes) {
    const socket = this.socket
    if (!socket || socket.readyState !== 1 || this.phase !== 'ready'
        || this.bufferedAmount() + bytes.length > MAX_BUFFERED_BYTES) return false
    try {
      socket.send(encodeMuxFrame(MUX_DATA, channelId, bytes))
      return true
    } catch { return false }
  }

  closeChannel(channelId) {
    this.channels.delete(channelId)
    const socket = this.socket
    if (!socket || socket.readyState !== 1 || this.phase !== 'ready') return false
    try { socket.send(encodeMuxFrame(MUX_CLOSE, channelId)); return true } catch { return false }
  }

  async #connect() {
    if (!this.desired || this.socket) return
    const base = relayBaseUrl(this.configProvider())
    const endpoint = ticketUrl(this.configProvider())
    if (!base || !endpoint) { this.#setPhase('unavailable'); return }
    const generation = ++this.connectionGeneration
    this.#setPhase('connecting')
    let token
    try { token = await this.tokenProvider() } catch {
      if (generation === this.connectionGeneration) this.#fail('auth-required')
      return
    }
    if (generation !== this.connectionGeneration || !this.desired) return
    if (typeof token !== 'string' || token.length < 20 || token.length > 20_000) { this.#fail('auth-required'); return }
    const controller = new AbortController()
    const deadline = this.setTimer(() => controller.abort(), 8_000)
    deadline?.unref?.()
    let response
    let text
    try {
      response = await this.fetchImpl(endpoint, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ role: 'desktop', desktopId: this.desktopId }),
        signal: controller.signal,
      })
      text = await response.text()
    } catch {
      this.clearTimer(deadline)
      if (generation === this.connectionGeneration) this.#fail('unreachable')
      return
    }
    this.clearTimer(deadline)
    if (generation !== this.connectionGeneration || !this.desired) return
    if (!response.ok || Buffer.byteLength(text, 'utf8') > MAX_TICKET_RESPONSE_BYTES) {
      this.#fail(response.status === 401 ? 'auth-required' : 'unreachable')
      return
    }
    let payload
    try { payload = JSON.parse(text) } catch { this.#fail('unreachable'); return }
    const url = payload?.ok === true ? validateWebSocketUrl(payload.websocketUrl, base) : null
    if (!url || !Number.isSafeInteger(payload.expiresAt) || payload.expiresAt <= this.now()) {
      this.#fail('unreachable')
      return
    }
    let socket
    try { socket = this.webSocketFactory(url) } catch { this.#fail('unreachable'); return }
    this.socket = socket
    try { socket.binaryType = 'arraybuffer' } catch { /* factory may already return buffers */ }
    socket.onopen = () => {
      if (generation !== this.connectionGeneration || socket !== this.socket || !this.desired) {
        try { socket.close(1000, 'stale') } catch { /* noop */ }
      }
    }
    this.#armReadyDeadline(socket, generation)
    socket.onmessage = (event) => {
      if (generation !== this.connectionGeneration || socket !== this.socket) return
      try { this.#message(event.data) } catch {
        try { socket.close(1008, 'invalid_relay_frame') } catch { /* noop */ }
      }
    }
    socket.onerror = () => {
      if (generation !== this.connectionGeneration || socket !== this.socket) return
      this.#setPhase('unreachable')
      this.#cancelReadyDeadline()
      this.#cancelHeartbeat()
      this.socket = null
      this.#closeChannels()
      try { socket.close(1011, 'relay_error') } catch { /* close handler retries */ }
      this.#scheduleRetry()
    }
    socket.onclose = () => {
      if (socket !== this.socket) return
      this.#cancelReadyDeadline()
      this.#cancelHeartbeat()
      this.socket = null
      this.#closeChannels()
      if (this.desired && generation === this.connectionGeneration) this.#scheduleRetry()
    }
  }

  #message(value) {
    if (typeof value === 'string') {
      const message = JSON.parse(value)
      if (message?.type === 'relay.pong') return
      if (message?.type !== 'relay.desktop-ready') throw new Error('invalid relay control')
      this.#cancelReadyDeadline()
      this.retryAttempt = 0
      this.lastConnectedAt = this.now()
      this.#setPhase('ready')
      this.#armHeartbeat(this.socket, this.connectionGeneration)
      return
    }
    const frame = decodeMuxFrame(value)
    if (frame.type === MUX_OPEN) {
      let details
      try { details = JSON.parse(frame.payload.toString('utf8')) } catch { throw new Error('invalid relay open') }
      if (!IDENTIFIER.test(details?.deviceId)) throw new Error('invalid relay device')
      this.channels.get(frame.channelId)?.remoteClose()
      const socket = new RelayVirtualSocket({ client: this, channelId: frame.channelId })
      this.channels.set(frame.channelId, socket)
      socket.once('close', () => {
        if (this.channels.get(frame.channelId) === socket) this.channels.delete(frame.channelId)
      })
      this.acceptSocket(socket)
      return
    }
    const channel = this.channels.get(frame.channelId)
    if (!channel) return
    if (frame.type === MUX_DATA) channel.receive(frame.payload)
    else if (frame.type === MUX_CLOSE) channel.remoteClose()
    else throw new Error('invalid relay direction')
  }

  #closeChannels() {
    const channels = [...this.channels.values()]
    this.channels.clear()
    for (const channel of channels) channel.remoteClose()
  }

  #fail(phase) {
    this.#setPhase(phase)
    if (this.desired) this.#scheduleRetry()
  }

  #scheduleRetry() {
    if (!this.desired || this.retryTimer) return
    this.#setPhase(this.phase === 'auth-required' ? 'auth-required' : 'reconnecting')
    const delay = Math.min(RETRY_MAX_MS, RETRY_BASE_MS * (2 ** Math.min(this.retryAttempt, 5)))
    this.retryAttempt++
    this.retryTimer = this.setTimer(() => {
      this.retryTimer = null
      void this.#connect()
    }, delay)
    this.retryTimer?.unref?.()
  }

  #cancelRetry() {
    if (!this.retryTimer) return
    this.clearTimer(this.retryTimer)
    this.retryTimer = null
  }

  #armHeartbeat(socket, generation) {
    this.#cancelHeartbeat()
    this.heartbeatTimer = this.setTimer(() => {
      this.heartbeatTimer = null
      if (!this.desired || socket !== this.socket || generation !== this.connectionGeneration
          || socket.readyState !== 1 || this.bufferedAmount() > MAX_BUFFERED_BYTES) return
      try {
        socket.send(JSON.stringify({ type: 'relay.ping' }))
        this.#armHeartbeat(socket, generation)
      } catch {
        try { socket.close(1011, 'heartbeat_failed') } catch { /* close handler retries */ }
      }
    }, HEARTBEAT_MS)
    this.heartbeatTimer?.unref?.()
  }

  #armReadyDeadline(socket, generation) {
    this.#cancelReadyDeadline()
    this.readyTimer = this.setTimer(() => {
      this.readyTimer = null
      if (!this.desired || socket !== this.socket || generation !== this.connectionGeneration
          || this.phase === 'ready') return
      this.socket = null
      try { socket.close(1011, 'relay_ready_timeout') } catch { /* detached below */ }
      this.#closeChannels()
      this.#scheduleRetry()
    }, SOCKET_READY_TIMEOUT_MS)
    this.readyTimer?.unref?.()
  }

  #cancelHeartbeat() {
    if (!this.heartbeatTimer) return false
    this.clearTimer(this.heartbeatTimer)
    this.heartbeatTimer = null
    return true
  }

  #cancelReadyDeadline() {
    if (!this.readyTimer) return false
    this.clearTimer(this.readyTimer)
    this.readyTimer = null
    return true
  }

  #setPhase(phase) {
    if (this.phase === phase) return
    this.phase = phase
    this.emit('state', this.status())
  }
}

module.exports = {
  KaisolaLinkClient,
  RelayVirtualSocket,
  relayBaseUrl,
  ticketUrl,
  validateWebSocketUrl,
}
