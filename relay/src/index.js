const MAX_AUTH_TOKEN_BYTES = 20_000
const MAX_REQUEST_BYTES = 8 * 1024
const MAX_RELAY_MESSAGE_BYTES = 2 * 1024 * 1024
const MAX_BUFFERED_BYTES = 4 * 1024 * 1024
const MAX_DESKTOPS_PER_ACCOUNT = 8
const MAX_DEVICES_PER_ACCOUNT = 16
const TICKET_TTL_MS = 60_000
const TICKET_PREFIX = 'ticket:'

export const MUX_VERSION = 1
export const MUX_OPEN = 1
export const MUX_DATA = 2
export const MUX_CLOSE = 3

const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$/
const ACCOUNT_KEY = /^[A-Za-z0-9_-]{43}$/
const TICKET = /^[A-Za-z0-9_-]{43}$/
const CHANNEL = /^[A-Za-z0-9_-]{22}$/

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'cache-control': 'no-store',
      'content-type': 'application/json; charset=utf-8',
      'x-content-type-options': 'nosniff',
    },
  })
}

function base64url(bytes) {
  let binary = ''
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

function randomToken(bytes = 32) {
  const value = new Uint8Array(bytes)
  crypto.getRandomValues(value)
  return base64url(value)
}

async function sha256(value) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))
}

export async function deriveAccountKey(uid, secret) {
  const cleanUid = typeof uid === 'string' && IDENTIFIER.test(uid) ? uid : null
  if (!cleanUid || typeof secret !== 'string' || secret.length < 32) {
    throw new Error('relay account-key configuration is invalid')
  }
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  return base64url(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(cleanUid)))
}

function bearerToken(header) {
  const match = String(header || '').match(/^Bearer\s+([^\s]+)$/i)
  return match && match[1].length <= MAX_AUTH_TOKEN_BYTES ? match[1] : null
}

export function validateTicketRequest(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('invalid_ticket_request')
  if (Object.keys(input).some((key) => !['role', 'desktopId', 'deviceId'].includes(key))) {
    throw new Error('invalid_ticket_request')
  }
  const role = input.role === 'desktop' || input.role === 'device' ? input.role : null
  const desktopId = typeof input.desktopId === 'string' && IDENTIFIER.test(input.desktopId) ? input.desktopId : null
  const deviceId = typeof input.deviceId === 'string' && IDENTIFIER.test(input.deviceId) ? input.deviceId : null
  if (!role || !desktopId || (role === 'device' && !deviceId) || (role === 'desktop' && input.deviceId != null)) {
    throw new Error('invalid_ticket_request')
  }
  return { role, desktopId, ...(deviceId ? { deviceId } : {}) }
}

async function readBoundedJSON(request) {
  const declared = Number(request.headers.get('content-length'))
  if (Number.isFinite(declared) && declared > MAX_REQUEST_BYTES) throw new Error('request_too_large')
  const text = await request.text()
  if (!text || new TextEncoder().encode(text).byteLength > MAX_REQUEST_BYTES) throw new Error('request_too_large')
  try { return JSON.parse(text) } catch { throw new Error('invalid_json') }
}

export async function verifyFirebaseSession(token, endpoint, fetchImpl = fetch) {
  let url
  try { url = new URL(endpoint) } catch { throw new Error('relay auth configuration is invalid') }
  if (url.protocol !== 'https:' || url.username || url.password) throw new Error('relay auth configuration is invalid')
  const response = await fetchImpl(url.toString(), {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      'user-agent': 'Kaisola-Link/1',
      'x-kaisola-purpose': 'relay-ticket',
    },
    body: '{}',
  })
  const text = await response.text()
  if (!response.ok || new TextEncoder().encode(text).byteLength > 64 * 1024) throw new Error('invalid_session')
  let payload
  try { payload = JSON.parse(text) } catch { throw new Error('invalid_session') }
  const uid = payload?.ok === true && typeof payload?.user?.uid === 'string' && IDENTIFIER.test(payload.user.uid)
    ? payload.user.uid
    : null
  if (!uid) throw new Error('invalid_session')
  return uid
}

function asBytes(value) {
  if (value instanceof ArrayBuffer) return new Uint8Array(value)
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
  return null
}

export function encodeMuxFrame(type, channelId, payload = new Uint8Array()) {
  if (![MUX_OPEN, MUX_DATA, MUX_CLOSE].includes(type) || typeof channelId !== 'string' || !CHANNEL.test(channelId)) {
    throw new Error('invalid_mux_frame')
  }
  const channel = new TextEncoder().encode(channelId)
  const body = asBytes(payload)
  if (!body || 3 + channel.byteLength + body.byteLength > MAX_RELAY_MESSAGE_BYTES) throw new Error('invalid_mux_frame')
  const result = new Uint8Array(3 + channel.byteLength + body.byteLength)
  result[0] = MUX_VERSION
  result[1] = type
  result[2] = channel.byteLength
  result.set(channel, 3)
  result.set(body, 3 + channel.byteLength)
  return result.buffer
}

export function decodeMuxFrame(value) {
  const bytes = asBytes(value)
  if (!bytes || bytes.byteLength < 4 || bytes.byteLength > MAX_RELAY_MESSAGE_BYTES) throw new Error('invalid_mux_frame')
  const channelLength = bytes[2]
  if (bytes[0] !== MUX_VERSION || ![MUX_OPEN, MUX_DATA, MUX_CLOSE].includes(bytes[1])
      || channelLength < 1 || 3 + channelLength > bytes.byteLength) throw new Error('invalid_mux_frame')
  const channelId = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(3, 3 + channelLength))
  if (!CHANNEL.test(channelId)) throw new Error('invalid_mux_frame')
  return { type: bytes[1], channelId, payload: bytes.slice(3 + channelLength) }
}

function safeAttachment(socket) {
  try {
    const value = socket.deserializeAttachment()
    return value && typeof value === 'object' ? value : null
  } catch { return null }
}

function send(socket, value) {
  try {
    const bytes = typeof value === 'string'
      ? new TextEncoder().encode(value).byteLength
      : asBytes(value)?.byteLength
    if (!Number.isSafeInteger(bytes) || socket.readyState !== 1
        || Number(socket.bufferedAmount || 0) + bytes > MAX_BUFFERED_BYTES) return false
    socket.send(value)
    return true
  } catch { return false }
}

function close(socket, code, reason) {
  try { socket.close(code, String(reason).slice(0, 120)) } catch { /* already closed */ }
}

function control(type) {
  return JSON.stringify({ type })
}

function desktopTag(desktopId) { return `desktop:${desktopId}` }
function deviceTag(deviceId) { return `device:${deviceId}` }
function targetTag(desktopId) { return `target:${desktopId}` }
function channelTag(channelId) { return `channel:${channelId}` }

export class KaisolaLinkRoom {
  constructor(ctx, env) {
    this.ctx = ctx
    this.env = env
    // Protocol keepalives are answered by the runtime without waking a
    // hibernating room, so NAT health does not become Durable Object duration.
    if (typeof globalThis.WebSocketRequestResponsePair === 'function'
        && typeof ctx.setWebSocketAutoResponse === 'function') {
      ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(
        control('relay.ping'),
        control('relay.pong'),
      ))
    }
  }

  async fetch(request) {
    const url = new URL(request.url)
    if (request.method === 'POST' && url.pathname === '/issue') return this.#issue(request)
    if (request.method === 'GET' && url.pathname === '/connect' && request.headers.get('upgrade')?.toLowerCase() === 'websocket') {
      return this.#connect(url)
    }
    return jsonResponse(404, { ok: false })
  }

  async #issue(request) {
    let metadata
    try { metadata = validateTicketRequest(await readBoundedJSON(request)) } catch {
      return jsonResponse(400, { ok: false })
    }
    const now = Date.now()
    const activeTickets = await this.#clearExpiredTickets(now)
    if (activeTickets >= 64) return jsonResponse(429, { ok: false })
    const ticket = randomToken(32)
    const digest = base64url(await sha256(ticket))
    const expiresAt = now + TICKET_TTL_MS
    await this.ctx.storage.put(`${TICKET_PREFIX}${digest}`, { ...metadata, expiresAt })
    return jsonResponse(200, { ok: true, ticket, expiresAt })
  }

  async #clearExpiredTickets(now) {
    const tickets = await this.ctx.storage.list({ prefix: TICKET_PREFIX, limit: 64 })
    const stale = []
    for (const [key, value] of tickets) {
      if (!Number.isSafeInteger(value?.expiresAt) || value.expiresAt <= now) stale.push(key)
    }
    if (stale.length) await this.ctx.storage.delete(stale)
    return tickets.size - stale.length
  }

  async #consumeTicket(ticket) {
    if (!TICKET.test(ticket)) return null
    const digest = base64url(await sha256(ticket))
    const key = `${TICKET_PREFIX}${digest}`
    return this.ctx.storage.transaction(async (txn) => {
      const metadata = await txn.get(key)
      if (!metadata) return null
      await txn.delete(key)
      if (!Number.isSafeInteger(metadata.expiresAt) || metadata.expiresAt <= Date.now()) return null
      const { expiresAt: _expiresAt, ...request } = metadata
      try { return validateTicketRequest(request) } catch { return null }
    })
  }

  async #connect(url) {
    const metadata = await this.#consumeTicket(url.searchParams.get('ticket') || '')
    if (!metadata) return jsonResponse(401, { ok: false, message: 'This relay ticket is invalid or expired.' })
    const desktops = this.ctx.getWebSockets('desktop').length
    const devices = this.ctx.getWebSockets('device').length
    const replacing = metadata.role === 'desktop'
      ? this.ctx.getWebSockets(desktopTag(metadata.desktopId)).length > 0
      : this.ctx.getWebSockets(deviceTag(metadata.deviceId)).length > 0
    if (!replacing && ((metadata.role === 'desktop' && desktops >= MAX_DESKTOPS_PER_ACCOUNT)
        || (metadata.role === 'device' && devices >= MAX_DEVICES_PER_ACCOUNT))) {
      return jsonResponse(429, { ok: false, message: 'Too many active Kaisola Link connections.' })
    }

    const pair = new WebSocketPair()
    const [client, server] = Object.values(pair)
    const attachment = metadata.role === 'desktop'
      ? metadata
      : { ...metadata, channelId: randomToken(16) }
    const tags = metadata.role === 'desktop'
      ? ['desktop', desktopTag(metadata.desktopId)]
      : ['device', deviceTag(metadata.deviceId), targetTag(metadata.desktopId), channelTag(attachment.channelId)]
    this.ctx.acceptWebSocket(server, tags)
    server.serializeAttachment(attachment)

    if (metadata.role === 'desktop') {
      for (const prior of this.ctx.getWebSockets(desktopTag(metadata.desktopId))) {
        if (prior !== server) close(prior, 4001, 'replaced')
      }
      send(server, control('relay.desktop-ready'))
      for (const device of this.ctx.getWebSockets(targetTag(metadata.desktopId))) this.#openDevice(device, server)
    } else {
      for (const prior of this.ctx.getWebSockets(deviceTag(metadata.deviceId))) {
        if (prior !== server) close(prior, 4001, 'replaced')
      }
      const desktop = this.#desktop(metadata.desktopId)
      if (desktop) this.#openDevice(server, desktop)
      else send(server, control('relay.waiting'))
    }

    return new Response(null, { status: 101, webSocket: client })
  }

  #desktop(desktopId) {
    return this.ctx.getWebSockets(desktopTag(desktopId)).find((socket) => socket.readyState === 1) || null
  }

  #device(channelId) {
    return this.ctx.getWebSockets(channelTag(channelId)).find((socket) => socket.readyState === 1) || null
  }

  #openDevice(device, desktop) {
    const metadata = safeAttachment(device)
    if (!metadata?.channelId || !metadata?.deviceId) return
    const details = new TextEncoder().encode(JSON.stringify({ deviceId: metadata.deviceId }))
    if (!send(desktop, encodeMuxFrame(MUX_OPEN, metadata.channelId, details))) {
      close(desktop, 4008, 'slow_consumer')
      send(device, control('relay.waiting'))
      return
    }
    send(device, control('relay.ready'))
  }

  async webSocketMessage(socket, message) {
    const metadata = safeAttachment(socket)
    if (!metadata) {
      close(socket, 1003, 'binary_only')
      return
    }
    // Fallback for runtimes that do not expose auto responses. Production
    // Cloudflare handles this before waking the object.
    if (typeof message === 'string') {
      if (message === control('relay.ping')) send(socket, control('relay.pong'))
      else close(socket, 1003, 'binary_only')
      return
    }
    const bytes = asBytes(message)
    if (!bytes || bytes.byteLength < 1
        || bytes.byteLength > (metadata.role === 'device' ? MAX_RELAY_MESSAGE_BYTES - 64 : MAX_RELAY_MESSAGE_BYTES)) {
      close(socket, 1009, 'message_too_large')
      return
    }
    if (metadata.role === 'device') {
      const desktop = this.#desktop(metadata.desktopId)
      if (!desktop) {
        send(socket, control('relay.waiting'))
        return
      }
      if (!send(desktop, encodeMuxFrame(MUX_DATA, metadata.channelId, bytes))) {
        close(desktop, 4008, 'slow_consumer')
        send(socket, control('relay.waiting'))
      }
      return
    }
    if (metadata.role !== 'desktop') {
      close(socket, 1008, 'invalid_role')
      return
    }
    let frame
    try { frame = decodeMuxFrame(bytes) } catch {
      close(socket, 1008, 'invalid_mux_frame')
      return
    }
    if (frame.type !== MUX_DATA && frame.type !== MUX_CLOSE) {
      close(socket, 1008, 'invalid_mux_direction')
      return
    }
    const device = this.#device(frame.channelId)
    const target = device && safeAttachment(device)
    if (!device || target?.desktopId !== metadata.desktopId) return
    if (frame.type === MUX_CLOSE) close(device, 4000, 'desktop_closed_channel')
    else if (!send(device, frame.payload.buffer)) close(device, 4008, 'slow_consumer')
  }

  async webSocketClose(socket) {
    this.#handleClosed(socket)
  }

  async webSocketError(socket) {
    this.#handleClosed(socket)
  }

  #handleClosed(socket) {
    const metadata = safeAttachment(socket)
    if (!metadata) return
    if (metadata.role === 'desktop') {
      const replacement = this.#desktop(metadata.desktopId)
      for (const device of this.ctx.getWebSockets(targetTag(metadata.desktopId))) {
        // A replacement opens its devices synchronously in #connect. Do not
        // repeat OPEN here when the replaced socket's close event arrives.
        if (!replacement || replacement === socket) send(device, control('relay.waiting'))
      }
      return
    }
    if (metadata.role === 'device' && metadata.channelId) {
      const desktop = this.#desktop(metadata.desktopId)
      if (desktop) send(desktop, encodeMuxFrame(MUX_CLOSE, metadata.channelId))
    }
  }
}

async function issueTicket(request, env) {
  const token = bearerToken(request.headers.get('authorization'))
  if (!token) return jsonResponse(401, { ok: false, message: 'A current Kaisola sign-in is required.' })
  let metadata
  try { metadata = validateTicketRequest(await readBoundedJSON(request)) } catch {
    return jsonResponse(400, { ok: false, message: 'The relay request is invalid.' })
  }
  let uid
  try { uid = await verifyFirebaseSession(token, env.FIREBASE_SESSION_URL) } catch {
    return jsonResponse(401, { ok: false, message: 'This Kaisola sign-in is invalid or expired.' })
  }
  let accountKey
  try { accountKey = await deriveAccountKey(uid, env.ACCOUNT_KEY_SECRET) } catch {
    return jsonResponse(503, { ok: false, message: 'Kaisola Link is not configured.' })
  }
  const room = env.LINK_ROOMS.get(env.LINK_ROOMS.idFromName(accountKey))
  const issued = await room.fetch(new Request('https://kaisola.internal/issue', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(metadata),
  }))
  if (!issued.ok) return jsonResponse(issued.status, { ok: false, message: 'Kaisola Link could not create a connection ticket.' })
  const payload = await issued.json()
  const url = new URL(request.url)
  url.protocol = 'wss:'
  url.pathname = `/v1/connect/${accountKey}`
  url.search = `?ticket=${encodeURIComponent(payload.ticket)}`
  url.hash = ''
  return jsonResponse(200, { ok: true, websocketUrl: url.toString(), expiresAt: payload.expiresAt })
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (request.method === 'GET' && url.pathname === '/health') {
      return jsonResponse(200, { ok: true, service: 'kaisola-link', protocol: 1 })
    }
    if (request.method === 'POST' && url.pathname === '/v1/ticket') return issueTicket(request, env)
    const match = request.method === 'GET' && url.pathname.match(/^\/v1\/connect\/([A-Za-z0-9_-]{43})$/)
    if (match && request.headers.get('upgrade')?.toLowerCase() === 'websocket' && ACCOUNT_KEY.test(match[1])) {
      const room = env.LINK_ROOMS.get(env.LINK_ROOMS.idFromName(match[1]))
      const target = new URL('https://kaisola.internal/connect')
      target.search = url.search
      return room.fetch(new Request(target, request))
    }
    return jsonResponse(404, { ok: false })
  },
}

export const __test = {
  bearerToken,
  constants: {
    MAX_RELAY_MESSAGE_BYTES,
    TICKET_TTL_MS,
  },
}
