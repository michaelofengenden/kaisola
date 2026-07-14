// Electron-main client for the detached session broker. Renderers continue to
// use the existing preload IPC; only main can authenticate to this socket.
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { StringDecoder } = require('node:string_decoder')

// Protocol 1 shipped without project-scoped terminal ownership. It must never
// be reused by a build which promises project isolation: the legacy broker has
// no trustworthy project label to migrate for already-running PTYs.
const PROTOCOL = 2
const SECURITY_EPOCH = 1
const LEGACY_UNSCOPED_PROTOCOL = 1
// A terminal snapshot may legally carry 8 MiB of UTF-8 output; JSON escaping
// can roughly double that. Keep one bounded envelope that can carry the
// documented payload without turning a valid response into a reconnect loop.
const MAX_FRAME = 20 * 1024 * 1024
const CONNECT_TIMEOUT_MS = 8_000
const LEGACY_RETIRE_TIMEOUT_MS = 5_000

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 })
  fs.renameSync(tmp, file)
  try { fs.chmodSync(file, 0o600) } catch { /* best effort */ }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return null }
}

function logTail(file, bytes = 4096) {
  try {
    const size = fs.statSync(file).size
    const take = Math.min(size, bytes)
    const fd = fs.openSync(file, 'r')
    try {
      const buffer = Buffer.allocUnsafe(take)
      fs.readSync(fd, buffer, 0, take, size - take)
      return buffer.toString('utf8').trim()
    } finally { fs.closeSync(fd) }
  } catch { return '' }
}

function pidAlive(pid) {
  if (!Number.isInteger(Number(pid)) || Number(pid) <= 1) return false
  try { process.kill(Number(pid), 0); return true } catch { return false }
}

function validToken(token) {
  return /^[0-9a-f]{64}$/i.test(String(token || ''))
}

function validateBrokerHello(frame, info) {
  if (!frame?.ok) throw new Error(frame?.message || 'session broker rejected this app')
  if (frame.protocol !== PROTOCOL) {
    throw new Error(`session broker protocol ${String(frame.protocol)} is not supported by protocol ${PROTOCOL}`)
  }
  if (frame.securityEpoch !== SECURITY_EPOCH) {
    throw new Error('session broker does not advertise project-scoped terminal isolation')
  }
  if (Number.isInteger(Number(info?.pid)) && Number(frame.pid) !== Number(info.pid)) {
    throw new Error('session broker identity changed during handshake')
  }
  return frame
}

/** Send one authenticated administrative request without adopting the broker
 * as this client's live transport. This is intentionally used only to retire
 * the known protocol-1 broker; ordinary requests can never cross that boundary. */
function requestBrokerControl(info, {
  protocol,
  appVersion,
  method,
  timeoutMs = CONNECT_TIMEOUT_MS,
  createConnection = net.createConnection,
}) {
  return new Promise((resolve, reject) => {
    let settled = false
    let authenticated = false
    let buffer = ''
    const decoder = new StringDecoder('utf8')
    const requestId = `broker-control:${crypto.randomUUID()}`
    const socket = createConnection(info.socketPath)
    const timer = setTimeout(() => finish(new Error(`session broker ${method} timed out`)), timeoutMs)
    timer.unref?.()
    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try { socket.destroy() } catch {}
      if (error) reject(error)
      else resolve(value)
    }
    const send = (frame) => {
      try { socket.write(`${JSON.stringify(frame)}\n`) } catch (error) { finish(error) }
    }
    socket.setNoDelay?.(true)
    socket.once('connect', () => send({
      type: 'hello',
      protocol,
      token: info.token,
      instanceId: crypto.randomUUID(),
      appVersion,
    }))
    socket.on('data', (chunk) => {
      buffer += decoder.write(chunk)
      if (Buffer.byteLength(buffer) > MAX_FRAME) {
        finish(new Error('session broker sent an oversized control frame'))
        return
      }
      let newline
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline)
        buffer = buffer.slice(newline + 1)
        if (!line) continue
        let frame
        try { frame = JSON.parse(line) } catch {
          finish(new Error('session broker sent malformed control data'))
          return
        }
        if (!authenticated) {
          if (frame?.type !== 'hello') continue
          if (!frame.ok || frame.protocol !== protocol) {
            finish(new Error(frame?.message || 'legacy session broker authentication failed'))
            return
          }
          authenticated = true
          send({ type: 'request', id: requestId, method, params: {} })
          continue
        }
        if (frame?.type !== 'response' || frame.id !== requestId) continue
        if (!frame.ok) finish(new Error(frame.message || `session broker ${method} failed`))
        else finish(null, frame.result)
        return
      }
    })
    socket.once('error', (error) => finish(error))
    socket.once('close', () => {
      decoder.end()
      if (!settled) finish(new Error(`session broker closed before ${method} completed`))
    })
  })
}

class SessionBrokerClient {
  constructor({ userData, execPath, brokerScript, appVersion, smoke = false }) {
    const digest = crypto.createHash('sha256').update(String(userData)).digest('hex').slice(0, 18)
    this.root = path.join(userData, 'session-broker')
    this.infoFile = path.join(this.root, 'broker.json')
    this.lockFile = path.join(this.root, 'broker.lock')
    this.logFile = path.join(this.root, 'broker.log')
    this.storageDir = path.join(userData, 'terminal-cache')
    this.socketPath = process.platform === 'win32'
      ? `\\\\.\\pipe\\kaisola-session-${digest}`
      : path.join(os.tmpdir(), `kaisola-session-${digest}.sock`)
    this.execPath = execPath
    this.brokerScript = brokerScript
    this.appVersion = appVersion
    this.smoke = smoke
    this.instanceId = crypto.randomUUID()
    this.socket = null
    this.buffer = ''
    this.pending = new Map()
    this.owners = new Map() // webContents.id -> WebContents
    this.seq = 0
    this.connecting = null
    this.closing = false
    this.hello = null
  }

  registerOwner(sender) {
    if (sender && !sender.isDestroyed?.()) this.owners.set(String(sender.id), sender)
  }

  unregisterOwner(sender) {
    if (!sender) return
    const id = String(sender.id ?? sender)
    const current = this.owners.get(id)
    if (!current || current === sender || current.isDestroyed?.()) this.owners.delete(id)
  }

  /** Stop routing terminal events to a destroyed WebContents without changing
   * broker ownership. ACP commands created by an in-flight turn retain the
   * exact owner key until they can read/release their PTY; a replacement
   * renderer can explicitly adopt same-project terminals later. */
  forgetOwner(sender) {
    this.unregisterOwner(sender)
    return { ok: true }
  }

  _send(frame) {
    if (!this.socket || this.socket.destroyed) throw new Error('session broker is not connected')
    this.socket.write(`${JSON.stringify(frame)}\n`)
  }

  _onFrame(frame, helloResolve, helloReject, expectedInfo) {
    if (frame?.type === 'hello') {
      try {
        validateBrokerHello(frame, expectedInfo)
        this.hello = frame
        helloResolve(frame)
      } catch (error) { helloReject(error) }
      return
    }
    if (frame?.type === 'response' && typeof frame.id === 'string') {
      const pending = this.pending.get(frame.id)
      if (!pending) return
      this.pending.delete(frame.id)
      if (pending.timer) clearTimeout(pending.timer)
      if (frame.ok) pending.resolve(frame.result)
      else pending.reject(new Error(frame.message || 'session broker request failed'))
      return
    }
    if (frame?.type === 'event') {
      const owner = this.owners.get(String(frame.ownerId))
      if (owner && !owner.isDestroyed?.()) owner.send(frame.channel, frame.payload)
    }
  }

  _open(info) {
    return new Promise((resolve, reject) => {
      let settled = false
      const socket = net.createConnection(info.socketPath)
      const decoder = new StringDecoder('utf8')
      const timer = setTimeout(() => finish(new Error('session broker handshake timed out')), CONNECT_TIMEOUT_MS)
      const finish = (error, value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        if (error) {
          try { socket.destroy() } catch {}
          reject(error)
        } else resolve(value)
      }
      this.buffer = ''
      socket.setNoDelay(true)
      socket.once('connect', () => {
        this.socket = socket
        try {
          this._send({ type: 'hello', protocol: PROTOCOL, token: info.token, instanceId: this.instanceId, appVersion: this.appVersion })
        } catch (error) { finish(error) }
      })
      socket.on('data', (chunk) => {
        this.buffer += decoder.write(chunk)
        if (Buffer.byteLength(this.buffer) > MAX_FRAME) {
          const error = new Error('session broker sent an oversized frame')
          this.buffer = ''
          socket.destroy(error)
          if (!settled) finish(error)
          return
        }
        let newline
        while ((newline = this.buffer.indexOf('\n')) >= 0) {
          const line = this.buffer.slice(0, newline)
          this.buffer = this.buffer.slice(newline + 1)
          if (!line) continue
          try {
            const frame = JSON.parse(line)
            this._onFrame(frame, (value) => finish(null, value), (error) => finish(error), info)
          } catch { /* malformed broker frame is ignored */ }
        }
      })
      socket.once('error', (error) => { if (!settled) finish(error) })
      socket.on('close', () => {
        const tail = decoder.end()
        if (tail) this.buffer += tail
        if (this.socket === socket) this.socket = null
        if (!settled) finish(new Error('session broker closed during handshake'))
        for (const [id, pending] of this.pending) {
          if (pending.timer) clearTimeout(pending.timer)
          pending.reject(new Error('session broker disconnected; running sessions remain on disk-backed broker'))
          this.pending.delete(id)
        }
      })
    })
  }

  _clearStaleBroker(info) {
    // Never unlink a replacement broker another app instance installed while
    // we were waiting for the old PID to exit.
    const current = readJson(this.infoFile)
    if (current && (current.pid !== info?.pid || current.token !== info?.token)) return false
    try { fs.unlinkSync(this.infoFile) } catch {}
    try { fs.unlinkSync(this.lockFile) } catch {}
    if (process.platform !== 'win32') try { fs.unlinkSync(info?.socketPath || this.socketPath) } catch {}
    return true
  }

  _requestLegacyShutdown(info) {
    return requestBrokerControl(info, {
      protocol: LEGACY_UNSCOPED_PROTOCOL,
      appVersion: this.appVersion,
      method: 'broker.shutdown',
      timeoutMs: CONNECT_TIMEOUT_MS,
    })
  }

  async _waitForBrokerExit(info) {
    const deadline = Date.now() + LEGACY_RETIRE_TIMEOUT_MS
    while (Date.now() < deadline) {
      if (!pidAlive(info.pid)) return
      await sleep(50)
    }
    throw new Error('legacy session broker did not exit after authenticated shutdown')
  }

  async _retireLegacyBroker(info) {
    let acknowledged = false
    let lastError = null
    // The old process may be between listener teardown/startup while Electron
    // is relaunching. Retry only the authenticated control path; never attach it
    // as the active terminal transport.
    for (let attempt = 0; attempt < 3 && pidAlive(info.pid); attempt++) {
      try {
        await this._requestLegacyShutdown(info)
        acknowledged = true
        break
      } catch (error) {
        lastError = error
        if (attempt < 2) await sleep(100)
      }
    }
    if (!acknowledged && pidAlive(info.pid)) {
      throw new Error(`could not safely retire legacy session broker: ${lastError?.message || 'authenticated shutdown failed'}`)
    }
    if (pidAlive(info.pid)) await this._waitForBrokerExit(info)
    this._clearStaleBroker(info)
  }

  async _connectCurrentBroker(info) {
    try {
      await this._open(info)
      return info
    } catch (error) {
      if (pidAlive(info.pid)) {
        // The broker may be between app versions and briefly relistening. Do
        // not unlink/replace a live authenticated service or its PTYs.
        for (let attempt = 0; attempt < 12; attempt++) {
          await sleep(100)
          try { await this._open(info); return info } catch { /* retry */ }
        }
        // An intentionally idle broker may have exited during the retry
        // window. Treat that as stale state and start a fresh helper below.
        if (!pidAlive(info.pid)) {
          this._clearStaleBroker(info)
          return null
        }
        throw new Error(`live session broker is not accepting connections: ${error.message}`)
      }
      this._clearStaleBroker(info)
      return null
    }
  }

  async _replacementAfterLegacy(legacyInfo) {
    // Another app instance can win the v2 spawn race while the retired broker
    // is exiting. Re-read once and adopt that exact replacement instead of
    // blindly starting a competing broker. This is deliberately bounded: a
    // second legacy/unknown broker is rejected, never recursively migrated.
    const replacement = readJson(this.infoFile)
    if (!replacement) return null
    if (replacement.pid === legacyInfo.pid && replacement.token === legacyInfo.token) {
      throw new Error('legacy session broker metadata remained after shutdown; refusing to start a competing broker')
    }
    if (!validToken(replacement.token)) {
      if (pidAlive(replacement.pid)) throw new Error('replacement session broker metadata has no valid authentication token')
      this._clearStaleBroker(replacement)
      return null
    }
    if (replacement.protocol !== PROTOCOL) {
      if (pidAlive(replacement.pid)) {
        throw new Error(`replacement session broker uses unsupported protocol ${String(replacement.protocol)}; refusing an unsafe downgrade`)
      }
      this._clearStaleBroker(replacement)
      return null
    }
    return this._connectCurrentBroker(replacement)
  }

  async _tryExisting() {
    const info = readJson(this.infoFile)
    if (!info) return null
    if (!validToken(info.token)) {
      if (pidAlive(info.pid)) throw new Error('live session broker metadata has no valid authentication token')
      this._clearStaleBroker(info)
      return null
    }
    if (info.protocol !== PROTOCOL) {
      if (!pidAlive(info.pid)) {
        this._clearStaleBroker(info)
        return null
      }
      if (info.protocol !== LEGACY_UNSCOPED_PROTOCOL) {
        throw new Error(`unsupported live session broker protocol ${String(info.protocol)}; refusing an unsafe downgrade`)
      }
      // Protocol 1 has no project ownership data. Its live PTYs cannot be
      // relabeled securely, so authenticated retirement kills them while
      // terminalManager retains their disk scrollback for the replacement.
      await this._retireLegacyBroker(info)
      return this._replacementAfterLegacy(info)
    }
    return this._connectCurrentBroker(info)
  }

  async _spawn() {
    fs.mkdirSync(this.root, { recursive: true, mode: 0o700 })
    try { fs.chmodSync(this.root, 0o700) } catch {}
    const token = crypto.randomBytes(32).toString('hex')
    const startedAt = Date.now()
    const launchFile = path.join(this.root, `launch-${process.pid}-${crypto.randomBytes(6).toString('hex')}.json`)
    atomicJson(launchFile, {
      protocol: PROTOCOL,
      securityEpoch: SECURITY_EPOCH,
      token,
      socketPath: this.socketPath,
      infoFile: this.infoFile,
      lockFile: this.lockFile,
      storageDir: this.storageDir,
      logFile: this.logFile,
      startedAt,
      version: this.appVersion,
      smoke: this.smoke,
    })
    const env = { ...process.env, ELECTRON_RUN_AS_NODE: '1', KAISOLA_SESSION_BROKER: '1' }
    delete env.KAISOLA_DEV_URL
    delete env.PASOLA_DEV_URL
    const child = spawn(this.execPath, [this.brokerScript, '--launch', launchFile], {
      detached: true,
      stdio: 'ignore',
      windowsHide: true,
      env,
    })
    let earlyExit = null
    child.once('exit', (code, signal) => { earlyExit = { code, signal } })
    child.unref()
    const info = { protocol: PROTOCOL, securityEpoch: SECURITY_EPOCH, pid: child.pid, socketPath: this.socketPath, token, startedAt, version: this.appVersion }
    const deadline = Date.now() + CONNECT_TIMEOUT_MS
    let lastError = null
    while (Date.now() < deadline) {
      await sleep(60)
      if (earlyExit) break
      const written = readJson(this.infoFile)
      if (!written || written.pid !== child.pid) continue
      try { await this._open(written); return written } catch (error) { lastError = error }
    }
    try { fs.unlinkSync(launchFile) } catch {}
    const tail = logTail(this.logFile)
    const detail = earlyExit
      ? ` (broker exited code=${earlyExit.code ?? 'null'} signal=${earlyExit.signal ?? 'none'})`
      : ''
    throw new Error(`could not start session broker${detail}${lastError ? `: ${lastError.message}` : ''}${tail ? `\n${tail}` : ''}`)
  }

  async connect() {
    if (this.socket && !this.socket.destroyed && this.hello) return this.hello
    if (this.connecting) return this.connecting
    this.closing = false
    this.connecting = (async () => {
      const existing = await this._tryExisting()
      if (!existing) await this._spawn()
      return this.hello
    })().finally(() => { this.connecting = null })
    return this.connecting
  }

  async request(method, params = {}, { timeoutMs = 15_000 } = {}) {
    await this.connect()
    const id = `${this.instanceId}:${++this.seq}`
    return new Promise((resolve, reject) => {
      const timer = timeoutMs > 0
        ? setTimeout(() => {
            this.pending.delete(id)
            reject(new Error(`session broker ${method} timed out`))
          }, timeoutMs)
        : null
      timer?.unref?.()
      this.pending.set(id, { resolve, reject, timer })
      try { this._send({ type: 'request', id, method, params }) } catch (error) {
        if (timer) clearTimeout(timer)
        this.pending.delete(id)
        reject(error)
      }
    })
  }

  async terminal(method, sender, params = {}, options) {
    if (sender) this.registerOwner(sender)
    const ownerId = sender?.id ?? params.ownerId ?? '0'
    return this.request(`terminal.${method}`, { ...params, ownerId }, options)
  }

  async detachOwner(sender) {
    if (!sender) return { ok: false }
    try { return await this.terminal('detachOwner', sender, {}, { timeoutMs: 3000 }) }
    finally { this.unregisterOwner(sender) }
  }

  async disconnect() {
    this.closing = true
    const socket = this.socket
    this.socket = null
    this.hello = null
    if (socket && !socket.destroyed) {
      try { socket.end() } catch {}
      setTimeout(() => { try { socket.destroy() } catch {} }, 100).unref?.()
    }
  }

  async shutdown() {
    try { await this.request('broker.shutdown', {}, { timeoutMs: 3000 }) } catch {}
    await this.disconnect()
  }
}

let singleton = null

function configureSessionBroker(config) {
  if (!singleton) singleton = new SessionBrokerClient(config)
  return singleton
}

function sessionBroker() {
  if (!singleton) throw new Error('session broker has not been configured')
  return singleton
}

function resetSessionBrokerForTests() {
  singleton = null
}

module.exports = {
  SessionBrokerClient,
  configureSessionBroker,
  sessionBroker,
  resetSessionBrokerForTests,
  PROTOCOL,
  SECURITY_EPOCH,
  __test: { LEGACY_UNSCOPED_PROTOCOL, requestBrokerControl, validateBrokerHello },
}
