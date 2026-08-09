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
const path = require('node:path')
const { StringDecoder } = require('node:string_decoder')
const mgr = require('./ipc/terminalManager.cjs')
const { terminalAttachRoute, terminalCreateRoute, terminalKillRoute, terminalResizeRoute } = require('./ipc/terminalCreateRoute.cjs')
const { terminalDetachOwnerRoute } = require('./ipc/terminalDetachOwnerRoute.cjs')
const { terminalOwnerAllowed, terminalOwnerParts } = require('./ipc/securityPolicy.cjs')
const {
  PROTOCOL,
  SECURITY_EPOCH,
  BROKER_IMPLEMENTATION_VERSION,
  BROKER_PACKAGE_SCHEMA,
  FEATURES,
  OBSERVER_ACCESS,
  MAX_FRAME,
  atomicJson,
  brokerMethodAllowedForAccess,
  negotiateFeatures,
  eventPayloadForFeatures,
  // Framing and queue accounting live in brokerWire so the observer layer can
  // be exercised against the exact delivery verdict a real socket produces.
  writeFrame: send,
} = require('./ipc/brokerWire.cjs')

const NO_CLIENT_EXIT_MS = process.env.NODE_ENV === 'test' && process.env.KAISOLA_TEST_BROKER_NO_CLIENT_EXIT_MS
  ? Math.max(50, Math.min(30_000, Number(process.env.KAISOLA_TEST_BROKER_NO_CLIENT_EXIT_MS) || 30_000))
  : 30_000
// macOS may reap old entries from its per-user temporary directory even while
// a process still has the AF_UNIX listener open. The broker and every PTY stay
// alive, but a replacement app cannot reach that now-unlinked listener. Check
// the pathname cheaply and publish a replacement listener without disturbing
// existing authenticated connections or terminal processes.
const SOCKET_PATH_CHECK_MS = 1_000

function readLaunch() {
  const marker = process.argv.indexOf('--launch')
  const file = marker >= 0 ? process.argv[marker + 1] : null
  if (!file || !path.isAbsolute(file)) throw new Error('missing broker launch file')
  const raw = fs.readFileSync(file, 'utf8')
  try { fs.unlinkSync(file) } catch { /* private one-shot file */ }
  const config = JSON.parse(raw)
  if (config.protocol !== PROTOCOL) throw new Error('unsupported broker protocol')
  if (config.securityEpoch !== SECURITY_EPOCH) throw new Error('unsupported broker security epoch')
  if (Number(config.implementationVersion) !== BROKER_IMPLEMENTATION_VERSION) throw new Error('unsupported broker implementation version')
  if (Number(config.packageSchema) !== BROKER_PACKAGE_SCHEMA) throw new Error('unsupported broker package schema')
  if (typeof config.packageVersion !== 'string' || !config.packageVersion || config.packageVersion.length > 64) {
    throw new Error('invalid broker package version')
  }
  if (!/^[0-9a-f]{64}$/i.test(String(config.token || ''))) throw new Error('invalid broker token')
  if (config.contentDigest != null && !/^[0-9a-f]{64}$/.test(String(config.contentDigest))) {
    throw new Error('invalid broker helper content digest')
  }
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

function tokenMatches(candidate) {
  const a = Buffer.from(String(candidate || ''))
  const b = Buffer.from(config.token)
  return a.length === b.length && crypto.timingSafeEqual(a, b)
}

const clients = new Map() // app instance id -> authenticated socket record
let noClientTimer = null
let shuttingDown = false
// Set synchronously in the authenticated update request before its response is
// emitted. From that instant onward no mutation can create a PTY/child and race
// the broker-authoritative quiescence snapshot.
let updateCommitted = false
let drainingTarget = null
let activityEpoch = 1
let companionLeaseEpoch = 1
const companionLeases = new Set()
let inFlightMutations = 0
let everConnected = false

const MUTATING_METHODS = new Set([
  'terminal.create',
  'terminal.attach',
  'terminal.detachRenderer',
  'terminal.detachOwner',
  'terminal.write',
  'terminal.agentTurn',
  'terminal.resize',
  'terminal.signal',
  'terminal.kill',
  'terminal.release',
  'terminal.scheduleRelease',
  'terminal.cancelRelease',
  'terminal.setFocused',
  'terminal.controlLease',
])

function noteActivity() {
  activityEpoch = activityEpoch >= Number.MAX_SAFE_INTEGER ? 1 : activityEpoch + 1
}

function beginMutation() {
  inFlightMutations++
  noteActivity()
}

function endMutation() {
  inFlightMutations = Math.max(0, inFlightMutations - 1)
  noteActivity()
}

function waitMilliseconds(milliseconds) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds)
    timer.unref?.()
  })
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
  // Draining generations are different: only the registry owner may retire
  // them after every app lane detaches and identity is rechecked. Keeping an
  // empty drain alive closes the crash window between UI detachment and that
  // explicit retirement transaction (and preserves a selected rollback
  // fallback across app relaunches).
  if (drainingTarget) return
  if (mgr.diagnostics().length) return
  noClientTimer = setTimeout(() => gracefulExit(false), NO_CLIENT_EXIT_MS)
  noClientTimer.unref?.()
}

function detachInstance(instanceId) {
  if (!instanceId) return
  mgr.detachSenderPrefix(`${instanceId}|`)
  mgr.unsubscribeSubscriberPrefix(`${instanceId}|`)
  // A pending exit wait can never be answered once the socket is gone, and the
  // pty it watches may run for hours: drop those closures with the connection.
  mgr.cancelExitWaitersPrefix(`${instanceId}|`)
  scheduleNoClientExit()
}

mgr.setEventSink((owner, channel, payload, options) => {
  const parts = terminalOwnerParts(owner)
  if (!parts) return false
  const client = clients.get(parts.instanceId)
  if (!client) return false
  return send(client.socket, {
    type: 'event',
    ownerId: parts.ownerId,
    projectId: parts.projectId,
    channel,
    // One live broker serves app lanes of different vintages across a rolling
    // update, so the shape is per-client, not per-broker.
    payload: eventPayloadForFeatures(channel, payload, client.features),
  }, options)
})
mgr.setActivitySink(() => noteActivity())

async function dispatch(client, method, params = {}) {
  if (!brokerMethodAllowedForAccess(client.access, method)) {
    throw new Error('observer access cannot invoke broker mutations')
  }
  if (updateCommitted && method !== 'broker.status') {
    throw new Error('broker helper update is already committed')
  }
  const admin = String(params.ownerId ?? '0') === '0'
  const requestProject = projectScope(params.projectId)
  const owner = ownerKey(client.instanceId, params.ownerId, requestProject)
  const terminalId = () => String(params.id || '').slice(0, 240)
  if (drainingTarget && method === 'terminal.create' && !mgr.has(terminalId())) {
    throw new Error('broker generation is draining; create on the current generation')
  }
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
      return {
        ok: true,
        protocol: PROTOCOL,
        securityEpoch: SECURITY_EPOCH,
        implementationVersion: BROKER_IMPLEMENTATION_VERSION,
        packageSchema: Number(config.packageSchema) || BROKER_PACKAGE_SCHEMA,
        packageVersion: typeof config.packageVersion === 'string' ? config.packageVersion : null,
        contentDigest: typeof config.contentDigest === 'string' ? config.contentDigest : null,
        features: FEATURES,
        pid: process.pid,
        startedAt: config.startedAt,
        version: config.version,
        activityEpoch,
        companionLeaseEpoch,
        companionLeaseCount: companionLeases.size,
        inFlightMutations,
        generationState: drainingTarget ? 'draining' : 'current',
        drainingTargetContentDigest: drainingTarget?.targetContentDigest ?? null,
        authenticatedClientCount: clients.size,
        terminals: mgr.diagnostics(),
      }
    case 'broker.shutdown':
      setTimeout(() => gracefulExit(true), 20).unref?.()
      return { ok: true }
    case 'broker.shutdownForUpdate': { // sealed native helper promotion only
      if (!admin) throw new Error('broker update requires administrative owner scope')
      const runningDigest = typeof config.contentDigest === 'string' ? config.contentDigest : null
      const targetDigest = String(params.targetContentDigest || '')
      const expectedDigest = String(params.expectedContentDigest || '')
      const identityMatches = Number(params.expectedPid) === process.pid
        && Number(params.expectedStartedAt) === Number(config.startedAt)
        && /^[0-9a-f]{64}$/.test(expectedDigest)
        && expectedDigest === runningDigest
      if (!identityMatches) {
        return {
          ok: false,
          state: 'identity_changed',
          pid: process.pid,
          startedAt: config.startedAt,
          contentDigest: runningDigest,
        }
      }
      if (!/^[0-9a-f]{64}$/.test(targetDigest)) throw new Error('invalid target helper content digest')
      if (targetDigest === runningDigest) {
        return { ok: true, state: 'current', contentDigest: runningDigest }
      }
      const readiness = mgr.upgradeReadiness()
      if (!readiness.safe) {
        return { ok: false, state: 'pending', ...readiness }
      }

      // JavaScript executes this check-and-commit without an await, so another
      // socket cannot interleave a terminal.create/agentTurn/child mutation.
      updateCommitted = true
      log(`helper update committed from=${runningDigest} to=${targetDigest}`)
      const timer = setTimeout(() => gracefulExit(false), 100)
      timer.unref?.()
      return {
        ok: true,
        state: 'updating',
        fromContentDigest: runningDigest,
        targetContentDigest: targetDigest,
      }
    }
    case 'broker.prepareRollingUpdate': {
      if (!admin) throw new Error('broker rolling update requires administrative owner scope')
      const runningDigest = typeof config.contentDigest === 'string' ? config.contentDigest : null
      const targetDigest = String(params.targetContentDigest || '')
      const expectedDigest = String(params.expectedContentDigest || '')
      const identityMatches = Number(params.expectedPid) === process.pid
        && Number(params.expectedStartedAt) === Number(config.startedAt)
        && /^[0-9a-f]{64}$/.test(expectedDigest)
        && expectedDigest === runningDigest
      if (!identityMatches) {
        return {
          ok: false,
          state: 'identity_changed',
          pid: process.pid,
          startedAt: config.startedAt,
          contentDigest: runningDigest,
        }
      }
      if (!/^[0-9a-f]{64}$/.test(targetDigest)) throw new Error('invalid target helper content digest')
      if (targetDigest === runningDigest) {
        return { ok: true, state: 'current', contentDigest: runningDigest }
      }
      if (drainingTarget) {
        return drainingTarget.targetContentDigest === targetDigest
          ? { ok: true, state: 'rolling', ...drainingTarget }
          : { ok: false, state: 'identity_changed', contentDigest: runningDigest }
      }

      const stabilityWindowMs = Math.max(50, Math.min(2_000, Math.floor(Number(params.stabilityWindowMs) || 300)))
      const initial = mgr.rollingUpdateReadiness()
      if (!initial.safe || inFlightMutations !== 0) {
        return { ok: false, state: 'pending', reason: 'busy', ...initial, inFlightMutations }
      }
      const expectedActivityEpoch = activityEpoch
      const expectedLeaseEpoch = companionLeaseEpoch
      await waitMilliseconds(stabilityWindowMs)
      const final = mgr.rollingUpdateReadiness()
      if (companionLeaseEpoch !== expectedLeaseEpoch) {
        return { ok: false, state: 'pending', reason: 'lease_changed', ...final, inFlightMutations }
      }
      if (activityEpoch !== expectedActivityEpoch || inFlightMutations !== 0 || !final.safe) {
        return { ok: false, state: 'pending', reason: 'activity_changed', ...final, inFlightMutations }
      }

      drainingTarget = {
        fromContentDigest: runningDigest,
        targetContentDigest: targetDigest,
        committedActivityEpoch: activityEpoch,
        committedLeaseEpoch: companionLeaseEpoch,
        committedAt: Date.now(),
      }
      noteActivity()
      log(`rolling update committed from=${runningDigest} to=${targetDigest} live=${final.liveTerminalCount}`)
      return { ok: true, state: 'rolling', ...drainingTarget }
    }
    case 'broker.cancelRollingUpdate': {
      if (!admin) throw new Error('broker rolling update requires administrative owner scope')
      const targetDigest = String(params.targetContentDigest || '')
      const identityMatches = Number(params.expectedPid) === process.pid
        && Number(params.expectedStartedAt) === Number(config.startedAt)
        && String(params.expectedContentDigest || '') === String(config.contentDigest || '')
      if (!identityMatches || !drainingTarget || drainingTarget.targetContentDigest !== targetDigest) {
        return { ok: false, state: 'identity_changed' }
      }
      drainingTarget = null
      noteActivity()
      log(`rolling update cancelled target=${targetDigest}`)
      return { ok: true, state: 'current', contentDigest: config.contentDigest }
    }
    case 'broker.retireDraining': {
      if (!admin) throw new Error('broker retirement requires administrative owner scope')
      const identityMatches = Number(params.expectedPid) === process.pid
        && Number(params.expectedStartedAt) === Number(config.startedAt)
        && String(params.expectedContentDigest || '') === String(config.contentDigest || '')
        && drainingTarget?.targetContentDigest === String(params.targetContentDigest || '')
      if (!identityMatches) return { ok: false, state: 'identity_changed' }
      const readiness = mgr.upgradeReadiness()
      const otherClientCount = Math.max(0, clients.size - 1)
      if (mgr.diagnostics().length !== 0 || otherClientCount !== 0 || inFlightMutations !== 0) {
        return {
          ok: false,
          state: 'pending',
          ...readiness,
          clientCount: otherClientCount,
          inFlightMutations,
        }
      }
      updateCommitted = true
      const timer = setTimeout(() => gracefulExit(false), 100)
      timer.unref?.()
      return { ok: true, state: 'retiring', contentDigest: config.contentDigest }
    }
    case 'terminal.available':
      return { ok: mgr.available() }
    case 'terminal.create': { // user terminal or ACP terminal
      return terminalCreateRoute({
        manager: mgr,
        params,
        owner,
        clientInstanceId: client.instanceId,
        requireAllowed,
      })
    }
    case 'terminal.attach': {
      const id = terminalId()
      return terminalAttachRoute({
        manager: mgr,
        id,
        owner,
        clientInstanceId: client.instanceId,
        requireAllowed,
      })
    }
    case 'terminal.subscribe': {
      if (admin) throw new Error('terminal observer requires an exact project capability')
      const id = terminalId()
      requireAllowed(id, true)
      return mgr.subscribe(id, owner, {
        streamEpoch: params.streamEpoch,
        afterOffset: params.afterOffset,
        maxQueueBytes: params.maxQueueBytes,
      })
    }
    case 'terminal.history': {
      if (admin) throw new Error('terminal history requires an exact project capability')
      const id = terminalId()
      requireAllowed(id, true)
      return mgr.history(id, {
        streamEpoch: params.streamEpoch,
        beforeOffset: params.beforeOffset,
        maxBytes: params.maxBytes,
      })
    }
    case 'terminal.unsubscribe': {
      if (admin) throw new Error('terminal observer requires an exact project capability')
      const id = terminalId()
      requireAllowed(id, true)
      return { ok: true, removed: mgr.unsubscribe(id, owner) }
    }
    case 'terminal.detachRenderer': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.detachRenderer(id, owner, params.viewState) }
    }
    case 'terminal.detachOwner': {
      return terminalDetachOwnerRoute({ manager: mgr, params, owner, requireAllowed })
    }
    case 'terminal.write': {
      const id = terminalId()
      requireAllowed(id)
      return mgr.write(id, String(params.data ?? ''))
    }
    case 'terminal.agentTurn': {
      const id = terminalId()
      requireAllowed(id)
      return { ok: mgr.agentTurn(id, !!params.busy) }
    }
    case 'terminal.controlLease': {
      const id = terminalId()
      requireAllowed(id)
      companionLeaseEpoch = companionLeaseEpoch >= Number.MAX_SAFE_INTEGER ? 1 : companionLeaseEpoch + 1
      if (params.active === true) companionLeases.add(id)
      else companionLeases.delete(id)
      return {
        ok: true,
        active: companionLeases.has(id),
        companionLeaseEpoch,
      }
    }
    case 'terminal.resize': {
      const id = terminalId()
      return terminalResizeRoute({ manager: mgr, id, params, requireAllowed })
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
      // The owner key is the wait's identity: it collapses a client's repeat
      // asks onto one resolver and is what a socket close cancels by prefix.
      return await mgr.waitForExit(id, { owner, timeoutMs: params.timeoutMs })
    }
    case 'terminal.signal': {
      const id = terminalId()
      requireAllowed(id)
      return mgr.write(id, '\x03')
    }
    case 'terminal.kill': {
      const id = terminalId()
      return terminalKillRoute({ manager: mgr, id, requireAllowed })
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
    const access = frame.access == null ? 'controller' : String(frame.access)
    if (access !== 'controller' && access !== OBSERVER_ACCESS) {
      client.socket.destroy()
      return
    }
    client.instanceId = instanceId
    client.access = access
    client.features = negotiateFeatures(frame.features)
    client.authenticated = true
    everConnected = true
    clients.set(instanceId, client)
    clearNoClientTimer()
    send(client.socket, {
      type: 'hello',
      ok: true,
      protocol: PROTOCOL,
      securityEpoch: SECURITY_EPOCH,
      implementationVersion: BROKER_IMPLEMENTATION_VERSION,
      packageSchema: Number(config.packageSchema) || BROKER_PACKAGE_SCHEMA,
      packageVersion: typeof config.packageVersion === 'string' ? config.packageVersion : null,
      contentDigest: typeof config.contentDigest === 'string' ? config.contentDigest : null,
      features: FEATURES,
      // What this connection actually asked for and got, so a client never has
      // to infer its own event shapes from the broker's full capability list.
      negotiatedFeatures: [...client.features],
      access,
      pid: process.pid,
      startedAt: config.startedAt,
      version: config.version,
    })
    return
  }
  if (frame?.type !== 'request' || typeof frame.id !== 'string' || typeof frame.method !== 'string') return
  const mutating = MUTATING_METHODS.has(frame.method)
  if (mutating) beginMutation()
  void dispatch(client, frame.method, frame.params).finally(() => {
    if (mutating) endMutation()
  }).then(
    (result) => {
      send(client.socket, { type: 'response', id: frame.id, ok: true, result })
      scheduleNoClientExit()
    },
    (error) => send(client.socket, { type: 'response', id: frame.id, ok: false, message: String(error?.message || error) }),
  )
}

function acceptClient(socket) {
  socket.setNoDelay(true)
  const client = {
    socket,
    authenticated: false,
    instanceId: null,
    access: 'controller',
    features: new Set(),
    buffer: '',
    decoder: new StringDecoder('utf8'),
  }
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
}

const servers = new Set()
let server = null
let socketRecoveryPending = false
let socketPathTimer = null

function brokerInfo() {
  return {
    protocol: PROTOCOL,
    securityEpoch: SECURITY_EPOCH,
    implementationVersion: BROKER_IMPLEMENTATION_VERSION,
    packageSchema: Number(config.packageSchema) || BROKER_PACKAGE_SCHEMA,
    packageVersion: typeof config.packageVersion === 'string' ? config.packageVersion : null,
    contentDigest: typeof config.contentDigest === 'string' ? config.contentDigest : null,
    pid: process.pid,
    socketPath: config.socketPath,
    token: config.token,
    startedAt: config.startedAt,
    version: config.version,
  }
}

function configureServer(candidate, { recovery = false } = {}) {
  servers.add(candidate)
  candidate.once('close', () => servers.delete(candidate))
  candidate.on('error', (error) => {
    log(`${recovery ? 'relisten' : 'listen'} ${error?.code || ''} ${error?.stack || error}`)
    if (recovery) {
      socketRecoveryPending = false
      try { candidate.close() } catch { /* failed listeners may already be closed */ }
      return
    }
    cleanupFiles()
    process.exit(error?.code === 'EPERM' ? 77 : 1)
  })
  return candidate
}

function publishListener({ recovered = false } = {}) {
  if (process.platform !== 'win32') try { fs.chmodSync(config.socketPath, 0o600) } catch { /* token still gates */ }
  // Info-file publication is diagnostics/rendezvous, not session state. A
  // transient write failure (ENOSPC, unwritable userData) during socket-path
  // recovery must degrade — letting it escape into uncaughtException would
  // gracefulExit(true) and kill every live PTY over a bookkeeping file.
  try { atomicJson(config.infoFile, brokerInfo()) } catch (error) { log(`publish info failed ${error?.code || ''} ${error?.message || error}`) }
  log(`${recovered ? 'recovered socket' : 'ready'} pid=${process.pid} protocol=${PROTOCOL} version=${config.version}`)
}

function socketPathState() {
  if (process.platform === 'win32') return 'present'
  try { return fs.lstatSync(config.socketPath).isSocket() ? 'present' : 'unsafe' } catch (error) {
    return error?.code === 'ENOENT' ? 'missing' : 'unknown'
  }
}

function recoverMissingSocketPath() {
  if (shuttingDown || socketRecoveryPending || socketPathState() !== 'missing') return
  socketRecoveryPending = true
  const previous = server
  const candidate = configureServer(net.createServer(acceptClient), { recovery: true })
  // Node unlinks an AF_UNIX server's remembered pathname when close() starts.
  // Close the inaccessible listener BEFORE binding its replacement; reversing
  // this order would let the old close remove the newly published path. Any
  // accepted app sockets keep draining, and terminalManager continues to own
  // every PTY throughout the listener swap.
  if (previous && previous !== candidate) try { previous.close() } catch {}
  server = candidate
  candidate.listen(config.socketPath, () => {
    if (shuttingDown) {
      try { candidate.close() } catch {}
      socketRecoveryPending = false
      return
    }
    socketRecoveryPending = false
    publishListener({ recovered: true })
  })
}

// Listen failures (sandbox policy, stale platform pipe state, path limits) are
// startup diagnostics, not uncaught session failures. Record them directly so
// the parent can surface the real reason instead of a generic timeout.
server = configureServer(net.createServer(acceptClient))

function cleanupFiles() {
  if (process.platform !== 'win32') try { fs.unlinkSync(config.socketPath) } catch { /* absent */ }
  try { fs.unlinkSync(config.infoFile) } catch { /* absent */ }
  try { fs.unlinkSync(config.lockFile) } catch { /* absent */ }
}

function gracefulExit(killSessions) {
  if (shuttingDown) return
  shuttingDown = true
  clearNoClientTimer()
  if (socketPathTimer) clearInterval(socketPathTimer)
  socketPathTimer = null
  if (killSessions) mgr.killAll()
  else for (const client of clients.values()) detachInstance(client.instanceId)
  for (const client of clients.values()) client.socket.destroy()
  clients.clear()
  const active = server
  for (const candidate of servers) {
    if (candidate === active) continue
    try { candidate.close() } catch {}
  }
  active.close(() => {
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
  publishListener()
  if (process.platform !== 'win32') {
    socketPathTimer = setInterval(recoverMissingSocketPath, SOCKET_PATH_CHECK_MS)
    socketPathTimer.unref?.()
  }
  scheduleNoClientExit()
})
