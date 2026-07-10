// Electron-main client for the detached session broker. Renderers continue to
// use the existing preload IPC; only main can authenticate to this socket.
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')

const PROTOCOL = 1
const MAX_FRAME = 4 * 1024 * 1024
const CONNECT_TIMEOUT_MS = 8_000

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

  _send(frame) {
    if (!this.socket || this.socket.destroyed) throw new Error('session broker is not connected')
    this.socket.write(`${JSON.stringify(frame)}\n`)
  }

  _onFrame(frame, helloResolve, helloReject) {
    if (frame?.type === 'hello') {
      if (!frame.ok) helloReject(new Error(frame.message || 'session broker rejected this app'))
      else { this.hello = frame; helloResolve(frame) }
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
        this.buffer += chunk.toString('utf8')
        if (Buffer.byteLength(this.buffer) > MAX_FRAME) {
          finish(new Error('session broker sent an oversized frame'))
          return
        }
        let newline
        while ((newline = this.buffer.indexOf('\n')) >= 0) {
          const line = this.buffer.slice(0, newline)
          this.buffer = this.buffer.slice(newline + 1)
          if (!line) continue
          try {
            const frame = JSON.parse(line)
            this._onFrame(frame, (value) => finish(null, value), (error) => finish(error))
          } catch { /* malformed broker frame is ignored */ }
        }
      })
      socket.once('error', (error) => { if (!settled) finish(error) })
      socket.on('close', () => {
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

  async _tryExisting() {
    const info = readJson(this.infoFile)
    if (!info || info.protocol !== PROTOCOL || !/^[0-9a-f]{64}$/i.test(String(info.token || ''))) return null
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
          try { fs.unlinkSync(this.infoFile) } catch {}
          try { fs.unlinkSync(this.lockFile) } catch {}
          if (process.platform !== 'win32') try { fs.unlinkSync(info.socketPath || this.socketPath) } catch {}
          return null
        }
        throw new Error(`live session broker is not accepting connections: ${error.message}`)
      }
      try { fs.unlinkSync(this.infoFile) } catch {}
      try { fs.unlinkSync(this.lockFile) } catch {}
      if (process.platform !== 'win32') try { fs.unlinkSync(info.socketPath || this.socketPath) } catch {}
      return null
    }
  }

  async _spawn() {
    fs.mkdirSync(this.root, { recursive: true, mode: 0o700 })
    try { fs.chmodSync(this.root, 0o700) } catch {}
    const token = crypto.randomBytes(32).toString('hex')
    const startedAt = Date.now()
    const launchFile = path.join(this.root, `launch-${process.pid}-${crypto.randomBytes(6).toString('hex')}.json`)
    atomicJson(launchFile, {
      protocol: PROTOCOL,
      token,
      socketPath: this.socketPath,
      infoFile: this.infoFile,
      lockFile: this.lockFile,
      storageDir: this.storageDir,
      logFile: this.logFile,
      startedAt,
      version: this.appVersion,
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
    const info = { protocol: PROTOCOL, pid: child.pid, socketPath: this.socketPath, token, startedAt, version: this.appVersion }
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

module.exports = { SessionBrokerClient, configureSessionBroker, sessionBroker, resetSessionBrokerForTests, PROTOCOL }
