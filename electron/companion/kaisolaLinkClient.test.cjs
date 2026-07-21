'use strict'

const { EventEmitter } = require('node:events')
const assert = require('node:assert/strict')
const test = require('node:test')
const { encodeWireFrame } = require('./bonjourTransport.cjs')
const { KaisolaLinkClient, RelayVirtualSocket, relayBaseUrl, ticketUrl, validateWebSocketUrl } = require('./kaisolaLinkClient.cjs')
const { MUX_DATA, MUX_OPEN, decodeMuxFrame, encodeMuxFrame } = require('./linkProtocol.cjs')

class FakeWebSocket {
  constructor(url) {
    this.url = url
    this.readyState = 0
    this.bufferedAmount = 0
    this.sent = []
  }
  send(value) { this.sent.push(Buffer.from(value)) }
  open() { this.readyState = 1; this.onopen?.() }
  message(value) { this.onmessage?.({ data: value }) }
  close() { this.readyState = 3; this.onclose?.({ code: 1000 }) }
}

const flush = () => new Promise((resolve) => setImmediate(resolve))

test('relay URLs stay HTTPS/WSS on the configured host', () => {
  const config = { relayUrl: 'https://link.example/base/' }
  assert.equal(relayBaseUrl(config).toString(), 'https://link.example/base')
  assert.equal(ticketUrl(config).toString(), 'https://link.example/base/v1/ticket')
  assert.equal(validateWebSocketUrl('wss://link.example/v1/connect/abc?ticket=one', relayBaseUrl(config)), 'wss://link.example/v1/connect/abc?ticket=one')
  assert.equal(validateWebSocketUrl('wss://evil.example/v1/connect/abc?ticket=one', relayBaseUrl(config)), null)
  assert.equal(relayBaseUrl({ relayUrl: 'http://link.example' }), null)
})

test('desktop Link requests a ticket, accepts channels, and sends opaque bytes', async () => {
  let webSocket
  const accepted = []
  const client = new KaisolaLinkClient({
    desktopId: 'desktop-1',
    acceptSocket: (socket) => accepted.push(socket),
    tokenProvider: async () => 'firebase-id-token-with-enough-characters',
    configProvider: () => ({ relayUrl: 'https://link.example' }),
    fetchImpl: async (_url, options) => {
      assert.equal(options.headers.authorization, 'Bearer firebase-id-token-with-enough-characters')
      assert.deepEqual(JSON.parse(options.body), { role: 'desktop', desktopId: 'desktop-1' })
      return new Response(JSON.stringify({
        ok: true,
        websocketUrl: 'wss://link.example/v1/connect/' + 'x'.repeat(43) + '?ticket=' + 'y'.repeat(43),
        expiresAt: Date.now() + 30_000,
      }), { status: 200 })
    },
    webSocketFactory: (url) => (webSocket = new FakeWebSocket(url)),
  })
  client.enable()
  await flush()
  webSocket.open()
  webSocket.message(JSON.stringify({ type: 'relay.desktop-ready' }))
  assert.equal(client.status().connected, true)

  const channelId = 'c'.repeat(22)
  webSocket.message(encodeMuxFrame(MUX_OPEN, channelId, Buffer.from(JSON.stringify({ deviceId: 'phone-1' }))))
  assert.equal(accepted.length, 1)
  const inbound = []
  accepted[0].on('data', (value) => inbound.push(value))
  webSocket.message(encodeMuxFrame(MUX_DATA, channelId, Buffer.from('from-phone')))
  assert.deepEqual(inbound, [Buffer.from('from-phone')])

  accepted[0].write(encodeWireFrame({ type: 'desktop-frame' }))
  const outbound = decodeMuxFrame(webSocket.sent.at(-1))
  assert.equal(outbound.type, MUX_DATA)
  assert.equal(outbound.channelId, channelId)
  assert.deepEqual(outbound.payload, encodeWireFrame({ type: 'desktop-frame' }))
  client.disable()
})

test('virtual relay sockets close synchronously and bound failed writes', () => {
  const calls = []
  const owner = {
    bufferedAmount: () => 0,
    sendChannel: (channel, bytes) => { calls.push({ channel, bytes }); return true },
    closeChannel: (channel) => calls.push({ close: channel }),
  }
  const socket = new RelayVirtualSocket({ client: owner, channelId: 'd'.repeat(22) })
  assert.equal(socket.write(Buffer.from('hello')), true)
  socket.destroy()
  assert.equal(socket.destroyed, true)
  assert.throws(() => socket.write(Buffer.from('again')), /closed/)
  assert.equal(calls.at(-1).close, 'd'.repeat(22))
})

test('desktop Link keeps an idle hibernating relay alive without leaking auth into the socket', async () => {
  let webSocket
  const timers = []
  const client = new KaisolaLinkClient({
    desktopId: 'desktop-heartbeat',
    acceptSocket: () => {},
    tokenProvider: async () => 'firebase-id-token-with-enough-characters',
    configProvider: () => ({ relayUrl: 'https://link.example' }),
    fetchImpl: async () => new Response(JSON.stringify({
      ok: true,
      websocketUrl: 'wss://link.example/v1/connect/' + 'x'.repeat(43) + '?ticket=' + 'y'.repeat(43),
      expiresAt: Date.now() + 30_000,
    }), { status: 200 }),
    webSocketFactory: (url) => (webSocket = new FakeWebSocket(url)),
    setTimer: (fn, ms) => {
      const timer = { fn, ms, cleared: false, unref() {} }
      timers.push(timer)
      return timer
    },
    clearTimer: (timer) => { timer.cleared = true },
  })
  client.enable()
  await flush()
  webSocket.open()
  webSocket.message(JSON.stringify({ type: 'relay.desktop-ready' }))
  const heartbeat = timers.find((timer) => timer.ms === 20_000 && !timer.cleared)
  assert.ok(heartbeat)
  heartbeat.fn()
  assert.deepEqual(JSON.parse(webSocket.sent.at(-1).toString('utf8')), { type: 'relay.ping' })
  assert.equal(webSocket.url.includes('firebase-id-token'), false)
  client.disable()
  assert.equal(timers.filter((timer) => timer.ms === 20_000).at(-1).cleared, true)
})

test('desktop Link bounds a WebSocket that never becomes relay-ready', async () => {
  let webSocket
  const timers = []
  const client = new KaisolaLinkClient({
    desktopId: 'desktop-timeout',
    acceptSocket: () => {},
    tokenProvider: async () => 'firebase-id-token-with-enough-characters',
    configProvider: () => ({ relayUrl: 'https://link.example' }),
    fetchImpl: async () => new Response(JSON.stringify({
      ok: true,
      websocketUrl: 'wss://link.example/v1/connect/' + 'x'.repeat(43) + '?ticket=' + 'y'.repeat(43),
      expiresAt: Date.now() + 30_000,
    }), { status: 200 }),
    webSocketFactory: (url) => (webSocket = new FakeWebSocket(url)),
    setTimer: (fn, ms) => {
      const timer = { fn, ms, cleared: false, unref() {} }
      timers.push(timer)
      return timer
    },
    clearTimer: (timer) => { timer.cleared = true },
  })
  client.enable()
  await flush()
  webSocket.open()
  const deadline = timers.find((timer) => timer.ms === 10_000 && !timer.cleared)
  assert.ok(deadline)
  deadline.fn()
  assert.equal(webSocket.readyState, 3)
  assert.equal(client.status().connected, false)
  assert.equal(client.status().phase, 'reconnecting')
  client.disable()
})
