'use strict'

// Live operational probe for the production Kaisola Link route. It uses the
// saved desktop Firebase session without printing it, opens both relay roles,
// and proves opaque bytes travel in both directions through the real Worker.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { app } = require('electron')

app.setName('Kaisola')
for (const legacy of ['pasola', 'Pasola', 'Kiasola']) {
  const candidate = path.join(app.getPath('appData'), legacy)
  if (fs.existsSync(candidate)) {
    app.setPath('userData', candidate)
    break
  }
}

const { currentFirebaseIdToken, readPublicConfig } = require('./ipc/authHandler.cjs')
const {
  KaisolaLinkClient,
  relayBaseUrl,
  ticketUrl,
  validateWebSocketUrl,
} = require('./companion/kaisolaLinkClient.cjs')

const PROBE_TIMEOUT_MS = 20_000
const requestBytes = Buffer.from('kaisola-link-device-to-desktop')
const responseBytes = Buffer.from('kaisola-link-desktop-to-device')

function waitForDesktop(client) {
  if (client.status().phase === 'ready') return Promise.resolve()
  return new Promise((resolve, reject) => {
    const listener = (state) => {
      if (state.phase === 'ready') {
        client.off('state', listener)
        resolve()
      } else if (state.phase === 'auth-required' || state.phase === 'unavailable') {
        client.off('state', listener)
        reject(new Error(`desktop relay entered ${state.phase}`))
      }
    }
    client.on('state', listener)
  })
}

async function issueDeviceTicket(config, token, desktopId, deviceId) {
  const endpoint = ticketUrl(config)
  const base = relayBaseUrl(config)
  if (!endpoint || !base) throw new Error('the production Link URL is not configured')
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ role: 'device', desktopId, deviceId }),
  })
  const text = await response.text()
  if (!response.ok || Buffer.byteLength(text, 'utf8') > 64 * 1024) {
    throw new Error(`device ticket failed (${response.status})`)
  }
  let payload
  try { payload = JSON.parse(text) } catch { throw new Error('device ticket was invalid JSON') }
  const url = payload?.ok === true ? validateWebSocketUrl(payload.websocketUrl, base) : null
  if (!url || !Number.isSafeInteger(payload.expiresAt) || payload.expiresAt <= Date.now()) {
    throw new Error('device ticket was invalid')
  }
  return url
}

async function run() {
  const config = readPublicConfig()
  const token = await currentFirebaseIdToken()
  const desktopId = `probe-desktop-${crypto.randomUUID()}`
  const deviceId = `probe-device-${crypto.randomUUID()}`
  let deviceSocket = null
  let acceptedSocket = null
  let resolveDesktopData
  let rejectDesktopData
  const desktopData = new Promise((resolve, reject) => {
    resolveDesktopData = resolve
    rejectDesktopData = reject
  })
  const client = new KaisolaLinkClient({
    desktopId,
    tokenProvider: async () => token,
    configProvider: () => config,
    acceptSocket: (socket) => {
      acceptedSocket = socket
      socket.once('data', (bytes) => {
        if (!Buffer.from(bytes).equals(requestBytes)) {
          rejectDesktopData(new Error('desktop received changed relay bytes'))
          return
        }
        try {
          socket.write(responseBytes)
          resolveDesktopData()
        } catch (error) { rejectDesktopData(error) }
      })
    },
    logger: { warn() {}, error() {}, info() {} },
  })
  let deadline = null
  try {
    client.enable()
    await waitForDesktop(client)
    const url = await issueDeviceTicket(config, token, desktopId, deviceId)
    const deviceData = new Promise((resolve, reject) => {
      const socket = new WebSocket(url)
      deviceSocket = socket
      socket.binaryType = 'arraybuffer'
      socket.onmessage = (event) => {
        if (typeof event.data === 'string') {
          let control
          try { control = JSON.parse(event.data) } catch { reject(new Error('invalid relay control')); return }
          if (control?.type === 'relay.ready') socket.send(requestBytes)
          else if (control?.type !== 'relay.pong') reject(new Error(`unexpected relay control: ${control?.type || 'unknown'}`))
          return
        }
        const bytes = Buffer.from(event.data)
        if (!bytes.equals(responseBytes)) {
          reject(new Error('device received changed relay bytes'))
          return
        }
        resolve()
      }
      socket.onerror = () => reject(new Error('device relay socket failed'))
      socket.onclose = () => reject(new Error('device relay socket closed before the round trip'))
    })
    const timeout = new Promise((_, reject) => {
      deadline = setTimeout(() => reject(new Error('live relay probe timed out')), PROBE_TIMEOUT_MS)
      deadline.unref?.()
    })
    await Promise.race([Promise.all([desktopData, deviceData]), timeout])
    if (!acceptedSocket) throw new Error('desktop did not receive the relay channel')
    console.log(`KAISOLA_LINK_PROBE_RESULT=PASS bytes=${requestBytes.length + responseBytes.length}`)
  } finally {
    if (deadline) clearTimeout(deadline)
    try { deviceSocket?.close(1000, 'probe_complete') } catch { /* already closed */ }
    try { acceptedSocket?.destroy() } catch { /* already closed */ }
    client.disable()
  }
}

app.whenReady().then(async () => {
  try {
    await run()
    app.exit(0)
  } catch (error) {
    console.error(`KAISOLA_LINK_PROBE_RESULT=FAIL ${String(error?.message || error)}`)
    app.exit(1)
  }
})
