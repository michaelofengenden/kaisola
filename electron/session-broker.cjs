#!/usr/bin/env node
// Kaisola's durable PTY host. It runs outside Electron's main-process lifetime
// (ELECTRON_RUN_AS_NODE=1), so app updates/restarts can replace the UI while the
// same shell, Codex, Claude, dev server, and process IDs keep running.
//
// Transport is authenticated newline-delimited JSON over a private local
// socket. Terminal output remains byte-capped by terminalManager/TerminalSpool;
// when no renderer is attached, hot scrollback is flushed to disk.
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const os = require('node:os')
const path = require('node:path')
const { StringDecoder } = require('node:string_decoder')
const mgr = require('./ipc/terminalManager.cjs')
const { terminalOwnerAllowed, terminalOwnerParts } = require('./ipc/securityPolicy.cjs')

const PROTOCOL = 2
const SECURITY_EPOCH = 1
const MAX_FRAME = 20 * 1024 * 1024
const NO_CLIENT_EXIT_MS = 30_000

function readLaunch() {
  const marker = process.argv.indexOf('--launch')
  const file = marker >= 0 ? process.argv[marker + 1] : null
  if (!file || !path.isAbsolute(file)) throw new Error('missing broker launch file')
  const raw = fs.readFileSync(file, 'utf8')
  try { fs.unlinkSync(file) } catch { /* private one-shot file */ }
  const config = JSON.parse(raw)
  if (config.protocol !== PROTOCOL) throw new Error('unsupported broker protocol')
  if (config.securityEpoch !== SECURITY_EPOCH) throw new Error('unsupported broker security epoch')
  if (!/^[0-9a-f]{64}$/i.test(String(config.token || ''))) throw new Error('invalid broker token')
  for (const key of ['socketPath', 'infoFile', 'lockFile', 'storageDir', 'logFile']) {
    if (!path.isAbsolute(String(config[key] || ''))) throw new Error(`invalid ${key}`)
  }
  return config
}

const config = readLaunch()
const smoke = config.smoke === true
process.umask(0o077)
mgr.configureStorage(config.storageDir)

function log(message) {
  try {
    fs.mkdirSync(path.dirname(config.logFile), { recursive: true, mode: 0o700 })
    if (fs.existsSync(config.logFile) && fs.statSync(config.logFile).size > 1024 * 1024) {
      fs.renameSync(config.logFile, `${config.logFile}.previous`)
    }
    fs.appendFileSync(config.logFile, `${new Date().toISOString()} ${message}\n`, { mode: 0o600 })
  } catch { /* diagnostics must never stop sessions */ }
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 })
  fs.renameSync(tmp, file)
  try { fs.chmodSync(file, 0o600) } catch { /* best effort */ }
}

function tokenMatches(candidate) {
  const a = Buffer.from(String(candidate || ''))
  const b = Buffer.from(config.token)
  return a.length === b.length && crypto.timingSafeEqual(a, b)
}

const clients = new Map() // app instance id -> authenticated socket record
let noClientTimer = null
let shuttingDown = false
let everConnected = false

function send(socket, frame) {
  if (!socket || socket.destroyed) return
  try { socket.write(`${JSON.stringify(frame)}\n`) } catch { /* reconnect replays snapshots */ }
}

const LEGACY_PROJECT_SCOPE = 'legacy'

function projectScope(value) {
  if (value == null || value === '') return LEGACY_PROJECT_SCOPE
  const scope = String(value)
  if (!/^[a-zA-Z0-9_.:-]{1,160}$/.test(scope)) throw new Error('invalid terminal project scope')
  return scope
}

function ownerId(value) {
  const id = String(value ?? '0').replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 80)
  return id || '0'
}

function ownerKey(instanceId, rendererId, projectId) {
  return `${instanceId}|${ownerId(rendererId)}|${projectScope(projectId)}`
}

function rendererOwnerPrefix(instanceId, rendererId) {
  return `${instanceId}|${ownerId(rendererId)}|`
}

function clearNoClientTimer() {
  if (noClientTimer) clearTimeout(noClientTimer)
  noClientTimer = null
}

function scheduleNoClientExit() {
  clearNoClientTimer()
  // Probe brokers must never outlive a crashed or abruptly-exited harness.
  // Production deliberately preserves live PTYs across UI restarts; the
  // authenticated launch flag makes this stricter teardown test-only.
  if (smoke && everConnected && clients.size === 0) {
    noClientTimer = setTimeout(() => gracefulExit(true), 250)
    noClientTimer.unref?.()
    return
  }
  // Connected Electron main must not pin an otherwise empty ~60 MB helper.
  // A later terminal request transparently starts/adopts a broker again.
  // Dead-but-unreleased records still carry a snapshot, so wait for release.
  if (mgr.diagnostics().length) return
  noClientTimer = setTimeout(() => gracefulExit(false), NO_CLIENT_EXIT_MS)
  noClientTimer.unref?.()
}

function detachInstance(instanceId) {
  if (!instanceId) return
  mgr.detachSenderPrefix(`${instanceId}|`)
  scheduleNoClientExit()
}

mgr.setEventSink((owner, channel, payload) => {
  const parts = terminalOwnerParts(owner)
  if (!parts) return
  const client = clients.get(parts.instanceId)
  if (!client) return
  send(client.socket, { type: 'event', ownerId: parts.ownerId, channel, payload })
})

async function dispatch(client, method, params = {}) {
  const admin = String(params.ownerId ?? '0') === '0'
  const requestProject = projectScope(params.projectId)
  const owner = ownerKey(client.instanceId, params.ownerId, requestProject)
  const terminalId = () => String(params.id || '').slice(0, 240)
  const allowed = (id, adopt = false) => {
    const record = mgr.ownership(id)
    // Renderer cleanup is intentionally idempotent: a released terminal has
    // no resource left to protect, so late resize/detach/snapshot calls are
    // harmless no-ops instead of noisy rejected promises.
    if (!record.exists) return true
    return terminalOwnerAllowed({
      recordOwner: record.owner,
      recordLastOwner: record.lastOwner,
      requestOwner: owner,
      requestProject,
      adopt,
      admin,
    })
  }
  const requireAllowed = (id, adopt = false) => {
    if (!allowed(id, adopt)) throw new Error('terminal access denied')
  }
  switch (method) {
    case 'broker.status':
      return { ok: true, protocol: PROTOCOL, securityEpoch: SECURITY_EPOCH, pid: process.pid, startedAt: config.startedAt, version: config.version, terminals: mgr.diagnostics() }
    case 'broker.shutdown':
      setTimeout(() => gracefulExit(true), 20).unref?.()
      return { ok: true }
    case 'terminal.available':
      return { ok: mgr.available() }
    case 'terminal.create': { // user terminal or ACP terminal
      if (!mgr.available()) return { ok: false, message: 'node-pty unavailable in session broker' }
      const id = String(params.id || '').slice(0, 240)
      if (!id) return { ok: false, message: 'terminal id required' }
      if (mgr.has(id)) requireAllowed(id, true)
      const existed = mgr.isLive(id)
      const rec = mgr.spawn({
        id,
        command: typeof params.command === 'string' ? params.command : undefined,
        args: Array.isArray(params.args) ? params.args.map(String).slice(0, 200) : undefined,
        cwd: typeof params.cwd === 'string' ? params.cwd : os.homedir(),
        env: params.env && typeof params.env === 'object' ? params.env : undefined,
        outputByteLimit: Number.isFinite(Number(params.outputByteLimit))
          ? Math.max(0, Math.min(Math.floor(Number(params.outputByteLimit)), 8 * 1024 * 1024))
          : undefined,
        cols: Number(params.cols) || 80,
        rows: Number(params.rows) || 24,
        sender: owner,
      })
      if (!rec) return { ok: false, message: 'could not start terminal' }
      const continuity = mgr.setSender(id, owner)
      const previousInstance = continuity?.previousOwner?.split('|')[0]
      const continuation = continuity && previousInstance && previousInstance !== client.instanceId
        ? { ...continuity, acrossRestart: true, reattachedAt: Date.now(), brokerPid: process.pid, terminalPid: rec.pty?.pid }
        : null
      return { ok: true, existed, pid: rec.pty?.pid, continuation, ...mgr.snapshot(id) }
    }
    case 'terminal.attach': {
      const id = terminalId()
      requireAllowed(id, true)
      const continuity = mgr.setSender(id, owner)
      const previousInstance = continuity?.previousOwner?.split('|')[0]
      const continuation = continuity && previousInstance && previousInstance !== client.instanceId
        ? { ...continuity, acrossRestart: true, reattachedAt: Date.now(), brokerPid: process.pid }
        : null
      return { ...mgr.snapshot(id), continuation }
    }
    case 'terminal.detachRenderer': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.detachRenderer(id, owner, params.viewState) }
    }
    case 'terminal.detachOwner':
      // A WebContents can own parked terminals in several project tabs. Window
      // teardown drops every one, while normal project handoff remains explicit
      // through attach/create with that project's capability.
      return { ok: true, detached: mgr.detachSenderPrefix(rendererOwnerPrefix(client.instanceId, params.ownerId)) }
    case 'terminal.write': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.write(id, String(params.data ?? '')) }
    }
    case 'terminal.agentTurn': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.agentTurn(id, !!params.busy) }
    }
    case 'terminal.resize': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.resize(id, Number(params.cols), Number(params.rows)) }
    }
    case 'terminal.snapshot':
    case 'terminal.output': {
      const id = terminalId()
      requireAllowed(id)
      return mgr.snapshot(id)
    }
    case 'terminal.waitForExit': {
      const id = terminalId()
      requireAllowed(id)
      return await mgr.waitForExit(id)
    }
    case 'terminal.signal': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.write(id, '\x03') }
    }
    case 'terminal.kill': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.kill(id) }
    }
    case 'terminal.release': {
      const id = terminalId()
      requireAllowed(id)
      mgr.release(id)
      scheduleNoClientExit()
      return { ok: true }
    }
    case 'terminal.scheduleRelease': {
      const id = terminalId()
      // A pop-out and its source renderer have distinct owner ids but share one
      // project capability. Scheduling does not adopt or expose the terminal.
      requireAllowed(id, true)
      return { ok: mgr.scheduleRelease(id, Number(params.delayMs)) }
    }
    case 'terminal.cancelRelease': {
      const id = terminalId()
      requireAllowed(id, true)
      return { ok: mgr.cancelRelease(id) }
    }
    case 'terminal.list': {
      const rows = mgr.list()
      return admin ? rows : rows.filter((row) => terminalOwnerAllowed({
        recordOwner: row.owner,
        recordLastOwner: row.lastOwner,
        requestOwner: owner,
        requestProject,
      }))
    }
    case 'terminal.diagnostics': {
      const rows = mgr.diagnostics()
      return admin ? rows : rows.filter((row) => terminalOwnerAllowed({
        recordOwner: row.owner,
        recordLastOwner: row.lastOwner,
        requestOwner: owner,
        requestProject,
      }))
    }
    case 'terminal.setFocused':
      mgr.setAppFocused(!!params.focused)
      return { ok: true }
    default:
      throw new Error(`unsupported broker method: ${method}`)
  }
}

function handleLine(client, line) {
  let frame
  try { frame = JSON.parse(line) } catch { return }
  if (!client.authenticated) {
    if (frame?.type !== 'hello' || frame.protocol !== PROTOCOL || !tokenMatches(frame.token)) {
      send(client.socket, { type: 'hello', ok: false, message: 'broker authentication failed' })
      client.socket.destroy()
      return
    }
    const instanceId = String(frame.instanceId || '')
    if (!/^[0-9a-f-]{20,80}$/i.test(instanceId)) {
      client.socket.destroy()
      return
    }
    const prior = clients.get(instanceId)
    if (prior && prior.socket !== client.socket) prior.socket.destroy()
    client.instanceId = instanceId
    client.authenticated = true
    everConnected = true
    clients.set(instanceId, client)
    clearNoClientTimer()
    send(client.socket, { type: 'hello', ok: true, protocol: PROTOCOL, securityEpoch: SECURITY_EPOCH, pid: process.pid, startedAt: config.startedAt, version: config.version })
    return
  }
  if (frame?.type !== 'request' || typeof frame.id !== 'string' || typeof frame.method !== 'string') return
  void dispatch(client, frame.method, frame.params).then(
    (result) => {
      send(client.socket, { type: 'response', id: frame.id, ok: true, result })
      scheduleNoClientExit()
    },
    (error) => send(client.socket, { type: 'response', id: frame.id, ok: false, message: String(error?.message || error) }),
  )
}

const server = net.createServer((socket) => {
  socket.setNoDelay(true)
  const client = { socket, authenticated: false, instanceId: null, buffer: '', decoder: new StringDecoder('utf8') }
  socket.on('data', (chunk) => {
    client.buffer += client.decoder.write(chunk)
    if (Buffer.byteLength(client.buffer) > MAX_FRAME) {
      socket.destroy()
      return
    }
    let newline
    while ((newline = client.buffer.indexOf('\n')) >= 0) {
      const line = client.buffer.slice(0, newline)
      client.buffer = client.buffer.slice(newline + 1)
      if (line) handleLine(client, line)
    }
  })
  socket.on('close', () => {
    client.decoder.end()
    if (client.instanceId && clients.get(client.instanceId) === client) {
      clients.delete(client.instanceId)
      detachInstance(client.instanceId)
    }
  })
  socket.on('error', () => {})
})

// Listen failures (sandbox policy, stale platform pipe state, path limits) are
// startup diagnostics, not uncaught session failures. Record them directly so
// the parent can surface the real reason instead of a generic timeout.
server.on('error', (error) => {
  log(`listen ${error?.code || ''} ${error?.stack || error}`)
  cleanupFiles()
  process.exit(error?.code === 'EPERM' ? 77 : 1)
})

function cleanupFiles() {
  if (process.platform !== 'win32') try { fs.unlinkSync(config.socketPath) } catch { /* absent */ }
  try { fs.unlinkSync(config.infoFile) } catch { /* absent */ }
  try { fs.unlinkSync(config.lockFile) } catch { /* absent */ }
}

function gracefulExit(killSessions) {
  if (shuttingDown) return
  shuttingDown = true
  clearNoClientTimer()
  if (killSessions) mgr.killAll()
  else for (const client of clients.values()) detachInstance(client.instanceId)
  for (const client of clients.values()) client.socket.destroy()
  clients.clear()
  server.close(() => {
    cleanupFiles()
    process.exit(0)
  })
  const hard = setTimeout(() => { cleanupFiles(); process.exit(0) }, 1500)
  hard.unref?.()
}

process.on('SIGTERM', () => gracefulExit(true))
process.on('SIGINT', () => gracefulExit(true))
process.on('uncaughtException', (error) => { log(`fatal ${error?.stack || error}`); gracefulExit(true) })
process.on('unhandledRejection', (error) => { log(`rejection ${error?.stack || error}`) })

try {
  const lockFd = fs.openSync(config.lockFile, 'wx', 0o600)
  process.on('exit', () => { try { fs.closeSync(lockFd) } catch {}; cleanupFiles() })
} catch {
  process.exit(2)
}

if (process.platform !== 'win32') try { fs.unlinkSync(config.socketPath) } catch { /* stale */ }
server.listen(config.socketPath, () => {
  if (process.platform !== 'win32') try { fs.chmodSync(config.socketPath, 0o600) } catch { /* token still gates */ }
  atomicJson(config.infoFile, {
    protocol: PROTOCOL,
    securityEpoch: SECURITY_EPOCH,
    pid: process.pid,
    socketPath: config.socketPath,
    token: config.token,
    startedAt: config.startedAt,
    version: config.version,
  })
  log(`ready pid=${process.pid} protocol=${PROTOCOL} version=${config.version}`)
  scheduleNoClientExit()
})
