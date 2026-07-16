// IPC surface for ACP agents. Supports MULTIPLE simultaneous connections (keyed
// by preset id), each with its own session, declared controls (modes / config
// options that drive the composer dropdowns), and live terminals. Also a
// registry of presets — open-source agents you can add, Zed-style.
const path = require('node:path')
const os = require('node:os')
const fs = require('node:fs')
const { randomUUID } = require('node:crypto')
const { execFileSync } = require('node:child_process')
const { shell, app } = require('electron')
const { AcpConnection } = require('./acp.cjs')
const { agentEnv } = require('./shellEnv.cjs')
const { mcpHttpEntry } = require('./mcpServer.cjs')
const { acpEntries } = require('./mcpCatalog.cjs')
const { sessionBroker } = require('./sessionBrokerClient.cjs')
const { AcpProcessLedger } = require('./acpProcessLedger.cjs')
const { resolveBundledCodexExecutable, resolveBundledClaudeExecutable } = require('./nativeAgentPaths.cjs')

const URL_RE = /https?:\/\/[^\s"'<>)]+/
const AUTH_TEXT_RE = /\b(auth(?:entication|orization|orize)?|oauth|log[ -]?in|sign[ -]?in|device code)\b/i

/** Send to a connection's CURRENT renderer, skipping destroyed windows. */
function sendTo(entry, channel, payload) {
  if (entry.sender && !entry.sender.isDestroyed()) entry.sender.send(channel, payload)
}

/** Surface (and, just after a sign-in, auto-open) an OAuth URL the agent printed. */
function surfaceAuthUrl(entry, name, key, url) {
  if (!url || entry.lastAuthUrl === url) return
  entry.lastAuthUrl = url
  sendTo(entry, 'acp:notice', { agent: name, key, kind: 'auth', text: 'Authorize in your browser', url })
  // if a sign-in was just requested, open it for the user (never during smoke tests)
  if (entry.recentAuthAt && Date.now() - entry.recentAuthAt < 180_000 && !(process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE)) {
    shell.openExternal(url).catch(() => {})
  }
}

function sanitizedCommands(value) {
  if (!Array.isArray(value)) return []
  return value.slice(0, 160).flatMap((command) => {
    if (!command || typeof command.name !== 'string') return []
    const name = command.name.trim().replace(/^\/+/, '').slice(0, 100)
    if (!name || !/^[\w$][\w$.-]*$/.test(name)) return []
    return [{
      name,
      description: typeof command.description === 'string' ? command.description.trim().slice(0, 500) : '',
      inputHint: typeof command.input?.hint === 'string' ? command.input.hint.trim().slice(0, 240) : undefined,
    }]
  })
}

function authUrlFromNotice(notice, recentAuthAt, at = Date.now()) {
  if (!notice || typeof notice.text !== 'string') return null
  const match = notice.text.match(URL_RE)
  if (!match) return null
  if (notice.kind === 'auth') return match[0]
  return recentAuthAt && at - recentAuthAt < 180_000 && AUTH_TEXT_RE.test(notice.text) ? match[0] : null
}

function authUrlFromUpdate(update, recentAuthAt, at = Date.now()) {
  if (!recentAuthAt || at - recentAuthAt >= 180_000 || !update || typeof update !== 'object') return null
  const text = typeof update.content?.text === 'string'
    ? update.content.text
    : typeof update.text === 'string' ? update.text : ''
  return text ? authUrlFromNotice({ kind: 'stderr', text }, recentAuthAt, at) : null
}

const MOCK_AGENT = path.join(__dirname, '..', 'acp-mock-agent.cjs')
let acpTermSeq = 0
// autonomy is PER-CONNECTION (entry.autonomy) — this is only the initial default
// a connect uses when the renderer didn't send one.
const DEFAULT_AUTONOMY = 'propose'
// Sensitive-file guardrails (Zed's pattern): agents' fs channel refuses these.
// Each renderer owns its own bounded list. A process-global mutable list let one
// live window silently change another window's filesystem policy.
const DEFAULT_SENSITIVE_GLOBS = Object.freeze(['**/.env*', '**/*.pem', '**/*.key', '**/*.cert', '**/*.crt', '**/.dev.vars', '**/secrets.yml'])
const MAX_SENSITIVE_GLOBS = 64
const MAX_SENSITIVE_GLOB_LENGTH = 512
const MAX_SENSITIVE_GLOB_INPUTS = MAX_SENSITIVE_GLOBS * 4
const sensitiveGlobsBySender = new Map()

function sanitizeSensitiveGlobs(value) {
  if (!Array.isArray(value)) return null
  const clean = []
  const seen = new Set()
  for (const raw of value.slice(0, MAX_SENSITIVE_GLOB_INPUTS)) {
    if (typeof raw !== 'string') continue
    // NUL cannot occur in a filesystem path. Preserve other characters,
    // including newlines, because renderer and main deliberately use the same
    // case-insensitive dotAll wildcard semantics.
    const glob = raw.replaceAll('\0', '').trim().slice(0, MAX_SENSITIVE_GLOB_LENGTH)
    if (!glob || seen.has(glob)) continue
    seen.add(glob)
    clean.push(glob)
    if (clean.length >= MAX_SENSITIVE_GLOBS) break
  }
  return Object.freeze(clean)
}

function sensitiveGlobsForSender(sender) {
  return (sender && sensitiveGlobsBySender.get(sender)) || DEFAULT_SENSITIVE_GLOBS
}

/** Bind an entry to a renderer and reset its policy to that renderer's list.
 * Adoption must never carry the previous window's custom guardrails forward. */
function bindEntryToSender(entry, sender) {
  entry.sender = sender
  entry.sensitiveGlobs = sensitiveGlobsForSender(sender)
  return entry
}

function setRendererSensitiveGlobs(sender, value) {
  const clean = sanitizeSensitiveGlobs(value)
  if (!sender || !clean) return null
  sensitiveGlobsBySender.set(sender, clean)
  // Update only entries owned by this exact WebContents object. Renderer ids
  // can be reused after destruction; id equality must not inherit old policy.
  for (const entry of connections.values()) {
    if (entry.sender === sender) entry.sensitiveGlobs = clean
  }
  for (const task of connectTasks.values()) {
    if (task.sender === sender && task.entry) task.entry.sensitiveGlobs = clean
  }
  return clean
}

function clearRendererSensitiveGlobs(sender) {
  if (!sender) return false
  return sensitiveGlobsBySender.delete(sender)
}
// MUST mirror src/lib/permissionRules.ts `wildcardMatch` (the canonical spec):
// same flags 'is' (case-insensitive + dotAll) so a newline-containing path the
// renderer flags sensitive is refused here too, not silently allowed.
const globRe = (g) =>
  new RegExp('^' + g.split('*').map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$', 'is')
function isSensitivePath(p, globs = DEFAULT_SENSITIVE_GLOBS) {
  const s = String(p || '')
  return globs.some(
    (g) => globRe(g).test(s) || (g.startsWith('**/') && (globRe(g.slice(3)).test(s) || globRe('*' + g.slice(2)).test(s))),
  )
}
// inline permission cards: permId → { resolve, timer, entry } for the agent's
// blocked request (entry lets us clean up a dying connection's cards)
const pendingPermissions = new Map()
const PERMISSION_TIMEOUT_MS = 300_000
const CANCEL_GRACE_MS = 8_000
// How long a finished turn waits for injected steer turns to settle. Real
// adapters (claude-code-acp) may absorb an injected session/prompt into the
// running turn and never answer its own JSON-RPC id — an unbounded wait here
// wedged the whole connection (busy forever, every next prompt rejected).
const STEER_FLUSH_MS = 2_000

/** Auto-resolve (as cancel) and clear every inline permission a dying connection
 * left pending, telling its renderer to drop the now-orphaned card + needs-you
 * badge. Idempotent — an already-answered/timed-out permId is simply absent. */
function cancelPendingFor(entry) {
  for (const [permId, p] of pendingPermissions) {
    if (p.entry !== entry) continue
    clearTimeout(p.timer)
    pendingPermissions.delete(permId)
    p.resolve('cancel')
    sendTo(entry, 'acp:permission-resolved', { permId })
  }
}

/** Decisions that never need a renderer round-trip. Cancellation wins over
 * even Execute/Sprint autonomy so a late provider callback cannot reopen a
 * state-changing permission gate after the user pressed Stop. */
function immediatePermissionDecision(entry) {
  if (entry?.cancelRequested) return 'cancel'
  if (entry?.autonomy === 'observe') return 'reject'
  if (entry?.autonomy === 'execute' || entry?.autonomy === 'sprint') return 'allow'
  return null
}

function beginEntryCancellation(entry) {
  if (!entry) return false
  entry.cancelRequested = (entry.inFlightTurns ?? 0) > 0 || !!entry.current?.channel
  cancelPendingFor(entry)
  return entry.cancelRequested
}

function clearCancelWatchdog(entry) {
  if (entry?.cancelWatchdog) clearTimeout(entry.cancelWatchdog)
  if (entry) entry.cancelWatchdog = null
}

/**
 * `${webContents.id}|${presetId}` → { conn, meta, sender, controls, current }.
 * Connections are scoped PER WINDOW (multi-window: window 2 connecting codex
 * must never dispose or hijack window 1's live session). The renderer-facing
 * key stays the bare presetId — handlers resolve the internal key from the
 * calling webContents. Orphans (window closed, agent alive) are adopted by
 * the next window that announces itself via acp:status.
 */
const connections = new Map()
const connectTasks = new Map() // internalKey -> completion gate (dedup handshakes)
const ikey = (sender, presetId) => `${sender.id}|${presetId}`
const entryFor = (sender, presetId) => connections.get(ikey(sender, presetId))
const terminalOwnerMoves = new WeakSet()
const projectMoves = new Set()
const projectMoveKey = (sender, scope) => `${sender?.id ?? 'none'}|${scope || ''}`
let processLedger = null
const connectionLeases = new Map() // internalKey -> Set<renderer thread id>
const idleTimers = new Map()
const DEFAULT_ACP_RESTART_WAIT_MS = 5 * 60_000
const MAX_ACP_RESTART_WAIT_MS = 10 * 60_000
const DEFAULT_ACP_RESTART_POLL_MS = 100
const ACP_IDLE_MS = (() => {
  const n = Number(process.env.KAISOLA_ACP_IDLE_MS)
  return Number.isFinite(n) ? Math.min(24 * 60 * 60_000, Math.max(30_000, Math.round(n))) : 5 * 60_000
})()

function clearIdleTimer(internalKey) {
  const timer = idleTimers.get(internalKey)
  if (timer) clearTimeout(timer)
  idleTimers.delete(internalKey)
}

function scheduleIdlePark(internalKey, requestedMs) {
  clearIdleTimer(internalKey)
  const delay = Number.isFinite(Number(requestedMs))
    ? Math.min(24 * 60 * 60_000, Math.max(30_000, Math.round(Number(requestedMs))))
    : ACP_IDLE_MS
  const timer = setTimeout(() => {
    idleTimers.delete(internalKey)
    if ((connectionLeases.get(internalKey)?.size ?? 0) > 0) return
    const entry = connections.get(internalKey)
    if (!entry || !entry.conn || !entry.conn.alive) return
    if (terminalOwnerMoves.has(entry)) {
      scheduleIdlePark(internalKey, delay)
      return
    }
    // Conservative gate: only an agent that promised session/load and has a
    // durable session id may park. Never stop a turn or a permission wait.
    if (!canIdlePark(entry)) {
      const temporarilyBusy = (entry.inFlightTurns ?? 0) > 0 || !!entry.current?.channel || [...pendingPermissions.values()].some((p) => p.entry === entry)
      if (temporarilyBusy) scheduleIdlePark(internalKey, delay)
      return
    }
    entry.conn.dispose()
    connections.delete(internalKey)
  }, delay)
  timer.unref?.()
  idleTimers.set(internalKey, timer)
}

function canIdlePark(entry) {
  const awaitingPermission = [...pendingPermissions.values()].some((p) => p.entry === entry)
  return !!entry && (entry.inFlightTurns ?? 0) === 0 && !entry.current?.channel && !awaitingPermission && !!entry.conn?.alive && !!(entry.conn.canResumeSession || entry.conn.canLoadSession) && !!entry.meta?.sessionId
}

/** A renderer-window swap is safe only while its ACP sessions are between
 * turns and not waiting for a permission answer. An active prompt streams to a
 * request-specific renderer listener, so closing that renderer would preserve
 * the process but lose output and the completion signal. */
function acpRendererSwapState(sender) {
  const owned = [...connections.values()].filter((entry) => entry.sender === sender)
  const connecting = [...connectTasks.values()].some((task) => task.sender === sender || task.sender?.id === sender?.id)
  const busy = connecting || owned.some((entry) => (entry.inFlightTurns ?? 0) > 0 || !!entry.current?.channel)
  const awaitingPermission = [...pendingPermissions.values()].some((pending) => pending.entry?.sender === sender)
  return { safe: !busy && !awaitingPermission, busy, connecting, awaitingPermission }
}

/** Authoritative process-wide ACP restart gate. An updater restart must not
 * close a renderer while a handshake, prompt, or approval is live: the agent
 * process may survive, but its request-specific output/completion listener does
 * not. Counts make the state useful for diagnostics without exposing prompts. */
function acpRestartSafetyState() {
  let activeConnections = 0
  let inFlightTurns = 0
  for (const entry of connections.values()) {
    const entryTurns = Math.max(0, Number(entry.inFlightTurns) || 0)
    inFlightTurns += entryTurns
    if (entryTurns > 0 || !!entry.current?.channel) activeConnections++
  }

  const connectingCount = connectTasks.size
  const pendingPermissionCount = pendingPermissions.size
  const connecting = connectingCount > 0
  const busy = connecting || activeConnections > 0
  const awaitingPermission = pendingPermissionCount > 0
  const blockers = []
  if (connecting) blockers.push('connecting')
  if (activeConnections > 0) blockers.push('active-turns')
  if (awaitingPermission) blockers.push('permission')

  return {
    safe: !busy && !awaitingPermission,
    busy,
    connecting,
    awaitingPermission,
    connectingCount,
    activeConnections,
    inFlightTurns,
    pendingPermissionCount,
    blockers,
  }
}

/** Wait for the ACP restart gate, but never turn a timeout into permission to
 * quit. Callers receive the last authoritative unsafe snapshot and must leave
 * the update ready for a later retry. The hard cap also prevents a malformed
 * option/environment value from holding an IPC request forever. */
function waitForAcpRestartSafe(options = {}) {
  const requestedTimeout = Number(options.timeoutMs)
  const timeoutMs = Number.isFinite(requestedTimeout)
    ? Math.min(MAX_ACP_RESTART_WAIT_MS, Math.max(0, Math.round(requestedTimeout)))
    : DEFAULT_ACP_RESTART_WAIT_MS
  const requestedPoll = Number(options.pollMs)
  const pollMs = Number.isFinite(requestedPoll)
    ? Math.min(1_000, Math.max(1, Math.round(requestedPoll)))
    : DEFAULT_ACP_RESTART_POLL_MS
  const now = typeof options.now === 'function' ? options.now : Date.now
  const setTimeoutFn = typeof options.setTimeoutFn === 'function' ? options.setTimeoutFn : setTimeout
  const startedAt = now()

  return new Promise((resolve) => {
    const check = () => {
      const state = acpRestartSafetyState()
      const waitedMs = Math.max(0, now() - startedAt)
      if (state.safe) {
        resolve({ ok: true, timedOut: false, waitedMs, ...state })
        return
      }
      if (waitedMs >= timeoutMs) {
        resolve({ ok: false, timedOut: true, waitedMs, ...state })
        return
      }
      setTimeoutFn(check, Math.max(1, Math.min(pollMs, timeoutMs - waitedMs)))
    }
    check()
  })
}

/** A project tab may change renderer owners between turns, but an active ACP
 * prompt has a request-specific listener in the source renderer and therefore
 * cannot be moved safely. CLI terminals do not use this path. */
function acpProjectTransferState(sender, scope) {
  const owned = [...connections.values()].filter(
    (entry) => (entry.sender === sender || entry.sender?.id === sender?.id) && entry.meta?.scope === scope,
  )
  const connecting = [...connectTasks.entries()].some(
    ([key, task]) => (task.sender === sender || task.sender?.id === sender?.id) && key.endsWith(`@@${scope}`),
  )
  const busy = connecting || owned.some((entry) => (entry.inFlightTurns ?? 0) > 0 || !!entry.current?.channel)
  const awaitingPermission = [...pendingPermissions.values()].some(
    (pending) => (pending.entry?.sender === sender || pending.entry?.sender?.id === sender?.id) && pending.entry?.meta?.scope === scope,
  )
  return { safe: !busy && !awaitingPermission, busy, connecting, awaitingPermission }
}

/** Rekey idle ACP connections + leases to a receiving renderer without
 * restarting their adapter processes. Returns an exact rollback for a failed
 * renderer adoption. */
async function transferAcpProject(fromSender, toSender, scope) {
  const state = acpProjectTransferState(fromSender, scope)
  if (!state.safe) return { ok: false, ...state }
  const moves = [...connections.entries()].filter(
    ([, entry]) => (entry.sender === fromSender || entry.sender?.id === fromSender?.id) && entry.meta?.scope === scope,
  ).map(([oldKey, entry]) => ({ oldKey, newKey: ikey(toSender, entry.meta.key || entry.meta.presetId), entry }))
  if (moves.some(({ newKey, entry }) => connections.has(newKey) && connections.get(newKey) !== entry)) {
    return { ok: false, collision: true }
  }
  if (moves.some(({ entry }) => terminalOwnerMoves.has(entry))) return { ok: false, busy: true }
  const sourceMoveKey = projectMoveKey(fromSender, scope)
  const targetMoveKey = projectMoveKey(toSender, scope)
  if (projectMoves.has(sourceMoveKey) || projectMoves.has(targetMoveKey)) return { ok: false, busy: true }
  for (const { entry } of moves) terminalOwnerMoves.add(entry)
  projectMoves.add(sourceMoveKey)
  projectMoves.add(targetMoveKey)
  let settled = false
  const unlock = () => {
    if (settled) return
    settled = true
    for (const { entry } of moves) terminalOwnerMoves.delete(entry)
    projectMoves.delete(sourceMoveKey)
    projectMoves.delete(targetMoveKey)
  }
  const transferred = []
  try {
    for (const move of moves) {
      const result = await transferEntryTerminalOwnership(move.entry, toSender)
      if (!result.ok) {
        for (const prior of [...transferred].reverse()) {
          await transferEntryTerminalOwnership(prior.entry, fromSender).catch(() => ({ ok: false }))
        }
        unlock()
        return { ok: false, terminalTransfer: true, message: result.message }
      }
      transferred.push(move)
    }
    // IPC stays live while broker handoffs await. Revalidate the authoritative
    // turn/permission state and exact map identity before changing ownership.
    const finalState = acpProjectTransferState(fromSender, scope)
    const intact = moves.every(({ oldKey, entry }) =>
      connections.get(oldKey) === entry && (entry.sender === fromSender || entry.sender?.id === fromSender?.id),
    )
    if (!finalState.safe || !intact) {
      for (const prior of [...transferred].reverse()) {
        await transferEntryTerminalOwnership(prior.entry, fromSender).catch(() => ({ ok: false }))
      }
      unlock()
      return { ok: false, stale: true, ...finalState }
    }
  } catch (error) {
    for (const prior of [...transferred].reverse()) {
      await transferEntryTerminalOwnership(prior.entry, fromSender).catch(() => ({ ok: false }))
    }
    unlock()
    return { ok: false, terminalTransfer: true, message: String(error?.message || error) }
  }
  const apply = (forward) => {
    for (const move of moves) {
      const fromKey = forward ? move.oldKey : move.newKey
      const toKey = forward ? move.newKey : move.oldKey
      const owner = forward ? toSender : fromSender
      const leases = connectionLeases.get(fromKey)
      clearIdleTimer(fromKey)
      clearIdleTimer(toKey)
      connectionLeases.delete(fromKey)
      connections.delete(fromKey)
      bindEntryToSender(move.entry, owner)
      connections.set(toKey, move.entry)
      if (leases?.size) connectionLeases.set(toKey, new Set(leases))
      else scheduleIdlePark(toKey)
    }
  }
  apply(true)
  return {
    ok: true,
    moved: moves.length,
    commit: () => { unlock(); return { ok: true } },
    rollback: async () => {
      if (settled) return { ok: false, settled: true }
      const collision = moves.some(({ oldKey, entry }) => connections.has(oldKey) && connections.get(oldKey) !== entry)
      if (collision) {
        // Never overwrite a replacement source connection. End only the moved
        // duplicate; its terminal host still knows the exact current owners
        // and releases them before the adapter process is reaped.
        for (const move of moves) {
          if (connections.get(move.newKey) === move.entry) connections.delete(move.newKey)
          connectionLeases.delete(move.newKey)
          clearIdleTimer(move.newKey)
          cancelPendingFor(move.entry)
          clearCancelWatchdog(move.entry)
          move.entry.conn.dispose()
        }
        unlock()
        return { ok: false, collision: true, disposed: true }
      }
      for (const move of [...moves].reverse()) {
        const result = await transferEntryTerminalOwnership(move.entry, fromSender)
        if (!result.ok) {
          for (const stale of moves) {
            if (connections.get(stale.newKey) === stale.entry) connections.delete(stale.newKey)
            connectionLeases.delete(stale.newKey)
            clearIdleTimer(stale.newKey)
            stale.entry.conn.dispose()
          }
          unlock()
          return { ok: false, message: result.message, disposed: true }
        }
      }
      apply(false)
      unlock()
      return { ok: true }
    },
  }
}

/** Renderer destruction is not guaranteed to run React effect cleanup. Clear
 * its leases in main, cancel now-unanswerable approvals, and start the normal
 * conservative idle timer without stopping any live turn. */
function releaseAcpRenderer(sender) {
  if (!sender) return 0
  // Entries keep their last policy while orphaned. Remove only the destroyed
  // renderer's lookup record; adoption explicitly rebinds to the new owner's
  // policy (or the safe defaults) through bindEntryToSender.
  clearRendererSensitiveGlobs(sender)
  let released = 0
  for (const [internalKey, entry] of connections) {
    if (entry.sender !== sender && entry.sender?.id !== sender.id) continue
    cancelPendingFor(entry)
    connectionLeases.delete(internalKey)
    clearIdleTimer(internalKey)
    scheduleIdlePark(internalKey)
    released++
  }
  for (const task of connectTasks.values()) {
    if (task.sender !== sender && task.sender?.id !== sender.id) continue
    task.cancelled = true
    task.entry?.conn?.dispose()
  }
  return released
}

const adapterCache = new Map()
/** Resolve an adapter already downloaded by npx to its exact JS entrypoint.
 * This removes the npm+npx wrapper processes while preserving npx as a safe
 * fallback when the cache is absent. Every path is realpathed beneath ~/.npm. */
function cachedNpxAdapter(packageName, binName) {
  const cacheKey = `${packageName}|${binName}`
  if (adapterCache.has(cacheKey)) return adapterCache.get(cacheKey)
  const root = path.join(os.homedir(), '.npm', '_npx')
  const hits = []
  try {
    const realRoot = fs.realpathSync(root) + path.sep
    for (const bucket of fs.readdirSync(root)) {
      const pkgDir = path.join(root, bucket, 'node_modules', ...packageName.split('/'))
      const manifestFile = path.join(pkgDir, 'package.json')
      let manifest
      try { manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8')) } catch { continue }
      if (manifest.name !== packageName) continue
      const rel = typeof manifest.bin === 'string' ? manifest.bin : manifest.bin && manifest.bin[binName]
      if (typeof rel !== 'string' || path.isAbsolute(rel) || rel.split(path.sep).includes('..')) continue
      let script
      try { script = fs.realpathSync(path.join(pkgDir, rel)) } catch { continue }
      if (!script.startsWith(realRoot) || !fs.statSync(script).isFile()) continue
      hits.push({ script, pkgDir: fs.realpathSync(pkgDir), version: String(manifest.version || ''), mtime: fs.statSync(manifestFile).mtimeMs })
    }
  } catch { /* cache absent */ }
  hits.sort((a, b) => b.mtime - a.mtime)
  const hit = hits[0] || null
  adapterCache.set(cacheKey, hit)
  return hit
}

function adapterPreset({ id, name, packageName, binName, ...rest }) {
  const cached = cachedNpxAdapter(packageName, binName)
  let direct = cached ? { command: process.execPath, args: [cached.script], env: { ELECTRON_RUN_AS_NODE: '1' } } : null
  // codex-acp's JS bin is only a spawnSync trampoline. Resolve its signed,
  // platform-specific binary directly too, removing the final Node wrapper.
  if (cached && packageName === '@zed-industries/codex-acp') {
    const platformName = `@zed-industries/codex-acp-${process.platform}-${process.arch}`
    const platformDir = path.join(path.dirname(path.dirname(cached.pkgDir)), ...platformName.split('/'))
    const binary = path.join(platformDir, 'bin', process.platform === 'win32' ? 'codex-acp.exe' : 'codex-acp')
    try {
      const manifest = JSON.parse(fs.readFileSync(path.join(platformDir, 'package.json'), 'utf8'))
      const real = fs.realpathSync(binary)
      const npmRoot = fs.realpathSync(path.join(os.homedir(), '.npm')) + path.sep
      if (manifest.name === platformName && real.startsWith(npmRoot) && fs.statSync(real).isFile()) direct = { command: real, args: [], env: {} }
    } catch { /* use the verified JS entrypoint */ }
  }
  return direct
    ? { id, name, ...direct, adapterVersion: cached.version, direct: true, ...rest }
    : { id, name, command: 'npx', args: ['-y', packageName], direct: false, ...rest }
}

function installedPackageAdapter(packageName, binName) {
  const roots = [
    path.join(__dirname, '..', '..', 'node_modules'),
    process.resourcesPath && path.join(process.resourcesPath, 'app.asar', 'node_modules'),
    process.resourcesPath && path.join(process.resourcesPath, 'app.asar.unpacked', 'node_modules'),
  ].filter(Boolean)
  for (const root of roots) {
    const pkgDir = path.join(root, ...packageName.split('/'))
    try {
      const manifest = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'))
      if (manifest.name !== packageName) continue
      const rel = typeof manifest.bin === 'string' ? manifest.bin : manifest.bin && manifest.bin[binName]
      if (typeof rel !== 'string' || path.isAbsolute(rel) || rel.split(path.sep).includes('..')) continue
      const script = path.join(pkgDir, rel)
      if (!fs.statSync(script).isFile()) continue
      return { command: process.execPath, args: [script], env: { ELECTRON_RUN_AS_NODE: '1' }, version: String(manifest.version || '') }
    } catch { /* next root */ }
  }
  return null
}

let currentCodexPath

function directCodexBinary(command) {
  try {
    const real = fs.realpathSync(command)
    if (!/[/\\]@openai[/\\]codex[/\\]bin[/\\]codex\.js$/.test(real)) return command
    const packageRoot = path.dirname(path.dirname(real))
    const platformPackage = `@openai/codex-${process.platform}-${process.arch}`
    const triples = {
      'darwin-arm64': 'aarch64-apple-darwin', 'darwin-x64': 'x86_64-apple-darwin',
      'linux-arm64': 'aarch64-unknown-linux-musl', 'linux-x64': 'x86_64-unknown-linux-musl',
      'win32-arm64': 'aarch64-pc-windows-msvc', 'win32-x64': 'x86_64-pc-windows-msvc',
    }
    const triple = triples[`${process.platform}-${process.arch}`]
    if (!triple) return command
    const platformRoot = path.join(packageRoot, 'node_modules', ...platformPackage.split('/'))
    const manifest = JSON.parse(fs.readFileSync(path.join(platformRoot, 'package.json'), 'utf8'))
    const native = fs.realpathSync(path.join(platformRoot, 'vendor', triple, 'bin', process.platform === 'win32' ? 'codex.exe' : 'codex'))
    const manifestMatches = manifest.name === platformPackage
      || (manifest.name === '@openai/codex' && manifest.os?.includes(process.platform) && manifest.cpu?.includes(process.arch))
    if (manifestMatches && native.startsWith(fs.realpathSync(platformRoot) + path.sep) && fs.statSync(native).isFile()) return native
  } catch { /* wrapper layout changed */ }
  return command
}

function newestCodexExecutable(extraEnv) {
  if (currentCodexPath !== undefined) return currentCodexPath
  const env = agentEnv(extraEnv)
  const pathCandidates = []
  for (const dir of String(env.PATH || '').split(path.delimiter)) {
    const candidate = path.join(dir, process.platform === 'win32' ? 'codex.exe' : 'codex')
    try {
      fs.accessSync(candidate, fs.constants.X_OK)
      if (!pathCandidates.includes(candidate)) pathCandidates.push(candidate)
    } catch { /* next */ }
  }
  const candidates = [
    ...pathCandidates,
    process.platform === 'darwin' ? '/Applications/ChatGPT.app/Contents/Resources/codex' : null,
    resolveBundledCodexExecutable(),
  ].filter(Boolean)
  const versions = candidates.map((command) => {
    try {
      const raw = execFileSync(command, ['--version'], { encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'] })
      const m = raw.match(/(\d+)\.(\d+)\.(\d+)/)
      return { command, tuple: m ? m.slice(1).map(Number) : [0, 0, 0], prerelease: /(?:alpha|beta|rc|nightly|dev)/i.test(raw) }
    } catch { return null }
  }).filter(Boolean)
  versions.sort((a, b) => (b.tuple[0] - a.tuple[0]) || (b.tuple[1] - a.tuple[1]) || (b.tuple[2] - a.tuple[2]) || Number(a.prerelease) - Number(b.prerelease))
  currentCodexPath = versions[0]?.command ? directCodexBinary(versions[0].command) : null
  return currentCodexPath
}

function codexPreset() {
  // Modern app-server adapter: this is the maintained package and supports the
  // model/reasoning/fast controls (including Ultra) exposed by current Codex.
  const modern = installedPackageAdapter('@agentclientprotocol/codex-acp', 'codex-acp')
  const base = modern
    ? { id: 'codex', name: 'Codex', command: modern.command, args: modern.args, env: modern.env, adapterVersion: modern.version, direct: true, modern: true }
    : adapterPreset({ id: 'codex', name: 'Codex', packageName: '@zed-industries/codex-acp', binName: 'codex-acp' })
  const codexPath = newestCodexExecutable(base.env)
  return { ...base, env: codexPath ? { ...(base.env || {}), CODEX_PATH: codexPath } : base.env }
}

function claudePreset() {
  const modern = installedPackageAdapter('@agentclientprotocol/claude-agent-acp', 'claude-agent-acp')
  const nativeClaude = resolveBundledClaudeExecutable()
  return modern
    ? { id: 'claude-code', name: 'Claude', command: modern.command, args: modern.args, env: nativeClaude ? { ...(modern.env || {}), CLAUDE_CODE_EXECUTABLE: nativeClaude } : modern.env, adapterVersion: modern.version, direct: true, modern: true }
    : adapterPreset({ id: 'claude-code', name: 'Claude', packageName: '@zed-industries/claude-code-acp', binName: 'claude-code-acp' })
}

// The built-in agent registry (Zed's agent_servers pattern). Each agent runs
// as the official CLI (installed by the user). Auth is owned by the CLI:
// `login` is run in Kaisola's real terminal so the browser OAuth works;
// `installCmd` installs it; `command/args` connect over ACP using cached
// creds; terminalOnly agents launch their CLI in a real pty instead. The
// renderer decides WHICH of these show in the + menu (Settings → Agents).
function presets() {
  return [
    // Claude speaks ACP (chat threads) since v0.1.20 — the auto-prepared
    // per-project terminal (accounts, hooks tap, --mcp-config, --resume) stays
    // the workspace default until the ACP path reaches feature parity.
    { ...claudePreset(),
      login: 'claude /login', installCmd: 'npm i -g @anthropic-ai/claude-code',
      docs: 'https://docs.anthropic.com/en/docs/claude-code/overview', builtin: false },
    { ...codexPreset(),
      login: 'codex login', installCmd: 'npm i -g @openai/codex',
      // plain `codex login` — the CLI retired `--device-auth` (codex-cli
      // ≥0.14x rejects it, which surfaced as a bare "invalid params" in the
      // sign-in card). It prints/opens the OAuth URL and exits 0 when the
      // browser flow completes, which is exactly what auth:start streams.
      deviceLogin: { command: 'codex', args: ['login'] },
      docs: 'https://developers.openai.com/codex/cli', builtin: false },
    // OpenCode ships a real ACP server (`opencode acp`) — full chat threads,
    // inline permission cards, the autonomy dial. No wrapper package needed.
    { id: 'opencode', name: 'OpenCode', command: 'opencode', args: ['acp'],
      login: 'opencode auth login', installCmd: 'npm i -g opencode-ai',
      docs: 'https://opencode.ai/docs', builtin: false },
    { id: 'gemini', name: 'Gemini', command: 'gemini', args: ['--experimental-acp'],
      login: 'gemini', installCmd: 'npm i -g @google/gemini-cli',
      docs: 'https://github.com/google-gemini/gemini-cli', builtin: false },
    // Qwen Code is a gemini-cli fork — same ACP flag, Qwen OAuth
    { id: 'qwen', name: 'Qwen Code', command: 'qwen', args: ['--experimental-acp'],
      login: 'qwen', installCmd: 'npm i -g @qwen-code/qwen-code',
      docs: 'https://github.com/QwenLM/qwen-code', builtin: false },
    { id: 'kimi', name: 'Kimi', command: 'kimi', args: ['--acp'],
      login: 'kimi', installCmd: 'uv tool install --python 3.13 kimi-cli',
      docs: 'https://github.com/MoonshotAI/kimi-cli', builtin: false },
    { id: 'amp', name: 'Amp', terminalOnly: true, terminalCommand: 'amp',
      login: 'amp login', installCmd: 'npm i -g @sourcegraph/amp',
      docs: 'https://ampcode.com/manual', builtin: false },
    { id: 'aider', name: 'Aider', terminalOnly: true, terminalCommand: 'aider',
      installCmd: 'uv tool install aider-chat',
      docs: 'https://aider.chat', builtin: false },
    { id: 'goose', name: 'Goose', terminalOnly: true, terminalCommand: 'goose',
      installCmd: 'brew install block-goose-cli',
      docs: 'https://block.github.io/goose', builtin: false },
    { id: 'crush', name: 'Crush', terminalOnly: true, terminalCommand: 'crush',
      installCmd: 'npm i -g @charmland/crush',
      docs: 'https://github.com/charmbracelet/crush', builtin: false },
    // test wiring — reachable programmatically (smoke), never listed in menus
    { id: 'mock', name: 'Mock agent (test wiring)', command: process.execPath, args: [MOCK_AGENT],
      env: { ELECTRON_RUN_AS_NODE: '1' }, builtin: true, hidden: true },
  ]
}

const CONNECT_TIMEOUT_MS = 120_000
const CLAUDE_EFFORTS = new Set(['low', 'medium', 'high', 'xhigh', 'max'])

/** Resolve a CLI on the same recovered login-shell PATH used to spawn agents.
 * claude-code-acp bundles a lagging Claude binary, but explicitly supports
 * CLAUDE_CODE_EXECUTABLE. Pointing it at the user's current installation keeps
 * models and effort levels (including xhigh) in step with their terminal. */
function agentExecutable(name, extraEnv) {
  const env = agentEnv(extraEnv)
  const suffixes = process.platform === 'win32' ? ['', '.exe', '.cmd', '.bat'] : ['']
  for (const dir of String(env.PATH || '').split(path.delimiter)) {
    if (!dir) continue
    for (const suffix of suffixes) {
      const candidate = path.join(dir, `${name}${suffix}`)
      try { fs.accessSync(candidate, fs.constants.X_OK); return candidate } catch { /* next */ }
    }
  }
  return null
}

// ---- keeping the model surface CURRENT (checked 2026-07-09) -----------------
// The adapters' declared lists trail the release train: claude-code-acp still
// describes the Opus 4.6 era, and codex-acp 0.16.0 (newest published) predates
// GPT-5.6. Both agents accept ids beyond their declared list (probe-verified
// pass-through), so the dropdowns get the current lineup merged in — anything
// the adapter declares that we don't know stays.
const CURRENT_CLAUDE_MODELS = [
  { modelId: 'fable', name: 'Fable 5', description: 'Deepest reasoning for the hardest, longest-running work' },
  { modelId: 'opus', name: 'Opus 4.8', description: 'Frontier Opus for complex work · fast-mode capable' },
  { modelId: 'sonnet', name: 'Sonnet 5', description: 'Everyday coding · native 1M context' },
  { modelId: 'haiku', name: 'Haiku 4.5', description: 'Fastest for quick tasks' },
  { modelId: 'opusplan', name: 'Opus Plan', description: 'Opus plans, Sonnet executes' },
]
const CURRENT_CODEX_MODELS = [
  { value: 'gpt-5.6-sol', name: 'GPT-5.6 Sol', description: 'Flagship — deepest reasoning (ultra effort in the codex CLI)' },
  { value: 'gpt-5.6-terra', name: 'GPT-5.6 Terra', description: 'Balanced tier' },
  { value: 'gpt-5.6-luna', name: 'GPT-5.6 Luna', description: 'Fast tier' },
]

// Match Codex's own approval copy instead of surfacing the adapter's internal
// preset names. Values stay untouched — only the human-facing labels change.
const CODEX_APPROVAL_LABELS = {
  'read-only': { name: 'Ask for approval', description: 'Always ask before editing external files or using the internet.' },
  auto: { name: 'Approve for me', description: 'Only ask for actions detected as potentially unsafe.' },
  agent: { name: 'Approve for me', description: 'Only ask for actions detected as potentially unsafe.' },
  'full-access': { name: 'Full access', description: 'Unrestricted access to the internet and files on this computer.' },
  'agent-full-access': { name: 'Full access', description: 'Unrestricted access to the internet and files on this computer.' },
}
const CODEX_EFFORT_LABELS = {
  low: { name: 'Light', description: 'Fastest · minimal reasoning' },
  medium: { name: 'Medium', description: 'Balanced reasoning' },
  high: { name: 'High', description: 'Deep reasoning' },
  xhigh: { name: 'Extra High', description: 'More time for difficult work' },
  max: { name: 'Ultra', description: 'Maximum reasoning available for this model' },
  ultra: { name: 'Ultra', description: 'Maximum Codex reasoning · higher usage' },
}
const CODEX_EFFORT_BASE_ORDER = ['low', 'medium', 'high', 'xhigh']
const labelCodexApproval = (option) => option && CODEX_APPROVAL_LABELS[option.value || option.id]
  ? { ...option, ...CODEX_APPROVAL_LABELS[option.value || option.id] }
  : option

/** Pick a provider-declared mode that actually constrains mutations. Values
 * remain provider-native: Codex exposes read-only, while Claude exposes plan.
 * If an adapter declares neither, Idea mode fails closed instead of trusting
 * prompt prose as a security boundary. */
function readOnlyModeForControls(controls) {
  const standard = controls?.modes && Array.isArray(controls.modes.availableModes)
    ? {
        current: controls.modes.currentModeId,
        options: controls.modes.availableModes.map((option) => ({
          value: option.id,
          name: option.name,
        })),
      }
    : null
  const config = Array.isArray(controls?.configOptions)
    ? controls.configOptions.find((option) => (option.category === 'mode' || option.id === 'mode') && Array.isArray(option.options))
    : null
  const control = standard || (config ? { current: config.currentValue, options: config.options } : null)
  if (!control) return null
  const exact = ['read-only', 'readonly', 'read_only', 'plan']
  const selected = exact
    .map((value) => control.options.find((option) => String(option.value ?? option.id).toLowerCase() === value))
    .find(Boolean)
    || control.options.find((option) => /read\s*-?\s*only|planning?\b/i.test(`${option.value ?? option.id} ${option.name ?? ''}`))
  if (!selected) return null
  return {
    modeId: String(selected.value ?? selected.id),
    previousModeId: typeof control.current === 'string' ? control.current : null,
  }
}

/** Merge the current model lineup into an adapter's declared controls. */
function freshenControls(presetId, controls, { modern = false } = {}) {
  try {
    if (presetId === 'claude-code' && !modern && controls && controls.models && Array.isArray(controls.models.availableModels)) {
      const curIds = new Set(CURRENT_CLAUDE_MODELS.map((m) => m.modelId))
      const declared = controls.models.availableModels
      // adapter's `default` leads; our current aliases replace its stale
      // alias rows (wrong era descriptions); unknown extras (custom ids,
      // whatever the user set) ride along at the end
      const head = declared.filter((m) => m.modelId === 'default')
      const tail = declared.filter((m) => m.modelId !== 'default' && !curIds.has(m.modelId))
      return { ...controls, models: { ...controls.models, availableModels: [...head, ...CURRENT_CLAUDE_MODELS, ...tail] } }
    }
    if (presetId === 'codex' && controls && Array.isArray(controls.configOptions)) {
      const currentIds = new Set(CURRENT_CODEX_MODELS.map((m) => m.value))
      return {
        ...controls,
        modes: controls.modes && Array.isArray(controls.modes.availableModes)
          ? { ...controls.modes, availableModes: controls.modes.availableModes.map(labelCodexApproval) }
          : controls.modes,
        configOptions: controls.configOptions.map((o) => {
          if ((o.id === 'mode' || o.category === 'mode') && Array.isArray(o.options)) {
            return { ...o, name: 'Approval', options: o.options.map(labelCodexApproval) }
          }
          if (/reasoning.*effort|effort/i.test(`${o.id} ${o.name} ${o.category}`) && Array.isArray(o.options)) {
            const declared = new Map(o.options.map((x) => [String(x.value), x]))
            // The product surface has one top "Ultra" slot. Preserve an
            // already-active `max` wire (notably Luna→Sol) instead of hiding
            // it and falsely falling back to High; otherwise prefer Sol/Terra's
            // real `ultra` wire. The description remains wire-specific.
            const top = String(o.currentValue) === 'max' && declared.has('max')
              ? 'max'
              : declared.has('ultra') ? 'ultra' : declared.has('max') ? 'max' : null
            const options = [...CODEX_EFFORT_BASE_ORDER, ...(top ? [top] : [])]
              .filter((value) => declared.has(value))
              .map((value) => ({ ...declared.get(value), value, ...CODEX_EFFORT_LABELS[value] }))
            return { ...o, name: 'Effort', category: 'thought_level', options: options.length ? options : o.options }
          }
          if (!(o.id === 'model' || o.category === 'model') || !Array.isArray(o.options)) return o
          // The app-server catalog is authoritative for this account/model.
          // Hardcoded model rows are only a legacy-adapter compatibility shim.
          if (modern) return o
          const declared = new Map(o.options.map((x) => [x.value, x]))
          // Known current rows are replaced, not merely appended: adapters often
          // report a raw id ("gpt-5.6-sol") before they ship its display metadata.
          const current = CURRENT_CODEX_MODELS.map((m) => ({ ...(declared.get(m.value) || {}), ...m }))
          const extras = o.options.filter((x) => !currentIds.has(x.value))
          return { ...o, options: [...current, ...extras] }
        }),
      }
    }
  } catch { /* a stale-but-working dropdown beats a broken one */ }
  return controls
}

// codex-acp 0.16.0 predates the GPT-5.6 effort levels — a config.toml carrying
// model_reasoning_effort = "ultra" | "max" kills the adapter at boot ("unknown
// variant"). Until Zed ships a newer adapter, spawn it against a shadow
// CODEX_HOME: every entry of the real home symlinked (auth, sessions,
// memories…), only config.toml copied with the effort capped at xhigh — the
// adapter's ceiling. The real ~/.codex, and the codex CLI everywhere else,
// keep ultra untouched. Drop this once codex-acp parses the new levels.
function codexCompatHome(overrideHome) {
  try {
    const home = overrideHome || process.env.CODEX_HOME || path.join(os.homedir(), '.codex')
    const cfg = fs.readFileSync(path.join(home, 'config.toml'), 'utf8')
    const m = cfg.match(/^(\s*model_reasoning_effort\s*=\s*")(ultra|max)(")/m)
    if (!m) return null
    const shim = path.join(app.getPath('userData'), 'codex-acp-home')
    fs.mkdirSync(shim, { recursive: true })
    for (const entry of fs.readdirSync(home)) {
      if (entry === 'config.toml') continue
      try { fs.symlinkSync(path.join(home, entry), path.join(shim, entry)) } catch { /* exists */ }
    }
    fs.writeFileSync(path.join(shim, 'config.toml'), cfg.replace(m[0], `${m[1]}xhigh${m[3]}`))
    return shim
  } catch { return null } // no config / unreadable — spawn plain, agent decides
}

function resolveConfig(config) {
  if (config && config.command) return { presetId: config.presetId || config.command, name: config.name || config.command, command: config.command, args: config.args, env: config.env }
  const p = presets().find((x) => x.id === (config && config.presetId)) || presets()[0]
  return { presetId: p.id, name: p.name, command: p.command, args: p.args, env: p.env, modern: p.modern, adapterVersion: p.adapterVersion }
}

function buildTerminalHost(entry, sessionCwd, agentKey, agentName, projectId, brokerClient = sessionBroker()) {
  // A broker PTY is owned by the renderer that created (or explicitly
  // adopted) it. Keep that owner per terminal instead of consulting the
  // mutable entry.sender: a renderer can crash or a project can move while an
  // ACP adapter still owns completed command terminals that it must release.
  const controlOwners = new Map()
  const controlOwner = (terminalId) => {
    const owner = controlOwners.get(terminalId)
    if (!owner) throw new Error('Agent terminal ownership is unavailable.')
    return owner
  }
  const host = {
    async create({ command, args, env, cwd, outputByteLimit }) {
      const terminalId = `acp-term-${++acpTermSeq}`
      const owner = entry.sender
      const created = await brokerClient.terminal('create', owner, {
        id: terminalId,
        command,
        args,
        env,
        cwd: cwd || sessionCwd,
        outputByteLimit,
        cols: 100,
        rows: 30,
        projectId,
      }, { timeoutMs: 20_000 })
      if (!created?.ok) throw new Error(created?.message || 'Could not start the agent terminal.')
      controlOwners.set(terminalId, owner)
      const label = [command, ...(args || [])].join(' ').slice(0, 80)
      sendTo(entry, 'acp:terminal', { terminalId, command, label, cwd: cwd || sessionCwd, agentKey, agentName })
      return { terminalId }
    },
    async output(terminalId) {
      const s = await brokerClient.terminal('output', controlOwner(terminalId), { id: terminalId, projectId })
      return { output: s.output, truncated: !!s.truncated, exitStatus: s.exitStatus }
    },
    waitForExit(terminalId) { return brokerClient.terminal('waitForExit', controlOwner(terminalId), { id: terminalId, projectId }, { timeoutMs: 0 }) },
    kill(terminalId) { return brokerClient.terminal('kill', controlOwner(terminalId), { id: terminalId, projectId }) },
    async release(terminalId) {
      const result = await brokerClient.terminal('release', controlOwner(terminalId), { id: terminalId, projectId }, { timeoutMs: 3_000 })
      controlOwners.delete(terminalId)
      return result
    },
    async transferOwnership(terminalIds, toSender) {
      const moved = []
      try {
        for (const terminalId of terminalIds) {
          const fromSender = controlOwner(terminalId)
          if (fromSender === toSender) continue
          await brokerClient.terminal('attach', toSender, { id: terminalId, projectId })
          controlOwners.set(terminalId, toSender)
          moved.push({ terminalId, fromSender })
        }
        return { ok: true, moved: moved.length }
      } catch (error) {
        // Attach is a same-project capability handoff. Put every completed
        // handoff back before reporting failure so host and broker can never
        // disagree about which renderer may clean up the PTY.
        for (const move of moved.reverse()) {
          try {
            await brokerClient.terminal('attach', move.fromSender, { id: move.terminalId, projectId })
            controlOwners.set(move.terminalId, move.fromSender)
          } catch { /* preserve the first failure for diagnostics */ }
        }
        return { ok: false, message: String(error?.message || error) }
      }
    },
  }
  return host
}

async function transferEntryTerminalOwnership(entry, toSender) {
  const terminalIds = [...(entry?.conn?.ownedTerminalIds || [])]
  if (!terminalIds.length) return { ok: true, moved: 0 }
  if (!entry?.terminalHost?.transferOwnership) {
    return { ok: false, message: 'Agent terminal ownership cannot be transferred safely.' }
  }
  return entry.terminalHost.transferOwnership(terminalIds, toSender)
}

function friendly(resolved, err, stderrTail) {
  const tail = stderrTail && stderrTail.trim() ? ` — ${stderrTail.trim().slice(-240)}` : ''
  if (err.message === 'TIMEOUT') {
    return `Timed out starting ${resolved.name}. First run via npx downloads the binary and can be slow — try again, install it once, or check auth (OPENAI_API_KEY / \`codex login\`).${tail}`
  }
  if (/ENOENT|not found|spawn/i.test(err.message)) {
    return `Could not start "${resolved.command} ${(resolved.args || []).join(' ')}". Is it installed and on your PATH?${tail}`
  }
  return `${err.message}${tail}`
}

/** The calling window's connections. `key` is the scoped wire key (bridge.ts
 * splits it back into bare presetId + project scope for the renderer). */
function agentSummary(sender) {
  return [...connections.values()]
    .filter((e) => e.sender === sender)
    .map((e) => ({
      key: (e.meta && (e.meta.key || e.meta.presetId)), name: e.meta && e.meta.name, presetId: e.meta && e.meta.presetId,
      connected: !!(e.conn && e.conn.alive), controls: e.controls,
      availableCommands: e.availableCommands || [],
      authMethods: (e.conn && e.conn.authMethods) || [],
      sessionId: e.meta && e.meta.sessionId,
      scope: e.meta && e.meta.scope,
      cwd: e.conn && e.conn.cwd,
      mcpHttp: !!(e.conn && e.conn.mcpHttpOk && e.conn.sessionMcpServers && e.conn.sessionMcpServers().length),
      canLoadSession: !!(e.conn && e.conn.canLoadSession),
      promptImages: !!(e.conn && e.conn.promptImageOk),
      promptQueue: !!(e.conn && e.conn.supportsPromptQueue),
      // cancel clears the renderer stream channel immediately, but the
      // provider promise can remain alive until its cooperative cancellation
      // settles (or the watchdog reaps it). Report both so restart recovery
      // never dispatches a replacement turn into that old connection.
      busy: !!(e.current && e.current.channel) || (e.inFlightTurns ?? 0) > 0,
      autonomy: e.autonomy,
    }))
}

function registerAcpHandlers(ipcMain) {
  if (!processLedger) {
    processLedger = new AcpProcessLedger(path.join(app.getPath('userData'), 'process-ledger'))
    processLedger.reclaimStale()
  }
  ipcMain.handle('acp:presets', () =>
    presets().map(({ id, name, login, installCmd, deviceLogin, docs, builtin, terminalOnly, terminalCommand, hidden }) =>
      ({ id, name, login, installCmd, deviceLogin, docs, builtin, terminalOnly, terminalCommand, hidden })),
  )

  // status is the renderer announcing itself (Assistant calls it on mount).
  // ONLY orphaned connections (their window's webContents destroyed) are
  // adopted by the caller — so agents survive a window close/reopen on macOS,
  // while a second live window can never hijack the first window's agents.
  ipcMain.handle('acp:status', async (event, { clientKeys, scope } = {}) => {
    const requested = Array.isArray(clientKeys) ? new Set(clientKeys.filter((key) => typeof key === 'string')) : null
    for (const [k, entry] of [...connections.entries()]) {
      if (!entry.sender || entry.sender.isDestroyed()) {
        const rendererKey = entry.meta && (entry.meta.key || entry.meta.presetId)
        const bareKey = typeof rendererKey === 'string' ? rendererKey.split('@@')[0] : rendererKey
        if (scope && entry.meta?.scope && entry.meta.scope !== scope) continue
        if (requested && !requested.has(bareKey)) continue
        const nk = ikey(event.sender, rendererKey)
        if (!connections.has(nk) && !terminalOwnerMoves.has(entry)) {
          terminalOwnerMoves.add(entry)
          const terminalMove = await transferEntryTerminalOwnership(entry, event.sender)
            .catch((error) => ({ ok: false, message: String(error?.message || error) }))
          terminalOwnerMoves.delete(entry)
          if (!terminalMove.ok) continue
          const oldLeases = connectionLeases.get(k)
          clearIdleTimer(k)
          connectionLeases.delete(k)
          connections.delete(k)
          bindEntryToSender(entry, event.sender)
          connections.set(nk, entry)
          if (oldLeases?.size) connectionLeases.set(nk, new Set(oldLeases))
          if ((connectionLeases.get(nk)?.size ?? 0) === 0) scheduleIdlePark(nk)
        }
      }
    }
    return { ok: true, agents: agentSummary(event.sender) }
  })

  // A mounted Assistant card holds one lease. Unmounting only schedules a
  // delayed park; a remount cancels it. Multiple visible cards sharing an ACP
  // key keep independent leases, so one card can never park another's agent.
  ipcMain.handle('acp:lease', (event, { agentKey, leaseId, active, idleMs } = {}) => {
    if (!agentKey || !leaseId) return { ok: false }
    const internalKey = ikey(event.sender, agentKey)
    const leases = new Set(connectionLeases.get(internalKey) || [])
    if (active) {
      leases.add(String(leaseId))
      connectionLeases.set(internalKey, leases)
      clearIdleTimer(internalKey)
    } else {
      leases.delete(String(leaseId))
      if (leases.size) connectionLeases.set(internalKey, leases)
      else {
        connectionLeases.delete(internalKey)
        scheduleIdlePark(internalKey, idleMs)
      }
    }
    return { ok: true, leases: leases.size }
  })
  ipcMain.handle('acp:diagnostics', () => ({
    idleMs: ACP_IDLE_MS,
    directAdapters: presets().filter((p) => p.direct).map((p) => ({ id: p.id, version: p.adapterVersion, command: p.command, args: p.args })),
    connections: [...connections.entries()].map(([key, e]) => ({ key, pid: e.conn?.proc?.pid, busy: !!e.current?.channel, inFlightTurns: e.inFlightTurns ?? 0, canLoadSession: !!e.conn?.canLoadSession, sessionId: e.meta?.sessionId, leases: connectionLeases.get(key)?.size ?? 0 })),
    ledger: processLedger?.diagnostics(),
  }))

  ipcMain.handle('acp:connect', async (event, config = {}) => {
    const resolved = resolveConfig(config)
    // scope = the renderer's project id: the SAME preset in two project tabs is
    // two independent connections/sessions. The composed key is what the
    // renderer echoes back on every later call (bridge.ts scopes/unscopes it).
    const scope = typeof config.scope === 'string' && config.scope ? config.scope : ''
    if (scope && projectMoves.has(projectMoveKey(event.sender, scope))) {
      return { ok: false, moving: true, message: 'This project is moving to another window. Try again in a moment.' }
    }
    const clientKey = typeof config.clientKey === 'string' && config.clientKey.length <= 240 && !config.clientKey.includes('@@')
      ? config.clientKey
      : resolved.presetId
    const key = scope ? `${clientKey}@@${scope}` : clientKey
    const internalKey = ikey(event.sender, key)
    // Autoconnect and an immediate Send can arrive together. Serialize by the
    // authoritative main-process key so only one adapter/process ledger entry
    // is ever created for this exact thread.
    while (connectTasks.has(internalKey)) await connectTasks.get(internalKey).promise
    const already = connections.get(internalKey)
    if (already?.conn?.alive && !config.forceReconnect) {
      return { ok: true, key, agent: already.meta, controls: already.controls, authMethods: already.conn.authMethods, resumed: true, existing: true }
    }
    let releaseConnect
    const connectGate = new Promise((resolve) => { releaseConnect = resolve })
    const connectTask = { promise: connectGate, sender: event.sender, entry: null, cancelled: false }
    connectTasks.set(internalKey, connectTask)
    try {
    const preset = presets().find((x) => x.id === resolved.presetId)
    if (preset && preset.terminalOnly) {
      return { ok: false, message: `${preset.name} runs as a terminal session. Open it from the + menu or Settings.` }
    }
    // a reconnect replaces THIS window's session only — never another window's
    if (connections.has(internalKey)) {
      connections.get(internalKey).conn.dispose()
      connections.delete(internalKey)
    }
    const sessionCwd = config.cwd || os.homedir()
    let workspaceReady = false
    try { workspaceReady = fs.statSync(sessionCwd).isDirectory() } catch { /* moved, deleted, or inaccessible */ }
    if (!workspaceReady) {
      return { ok: false, message: `Workspace folder is unavailable: ${sessionCwd}` }
    }
    let stderrTail = ''
    // entry.sender tracks the CURRENT window (acp:status rebinds it), so these
    // callbacks keep reaching the renderer after a window close/reopen
    const processToken = processLedger ? processLedger.newToken() : null
    const entry = bindEntryToSender({ conn: null, terminalHost: null, meta: null, controls: { modes: null, configOptions: [] }, availableCommands: [], current: { sender: null, channel: null }, inFlightTurns: 0, cancelRequested: false, autonomy: config.autonomy || DEFAULT_AUTONOMY, processToken }, event.sender)
    connectTask.entry = entry

    // per-connection env on top of the preset's (e.g. CLAUDE_CONFIG_DIR / CODEX_HOME
    // for the project's bound subscription)
    let env = config.env && typeof config.env === 'object'
      ? { ...(resolved.env || {}), ...config.env }
      : resolved.env
    if (resolved.presetId === 'claude-code' && Object.prototype.hasOwnProperty.call(config, 'claudeConfigDir')) {
      env = { ...(env || {}) }
      if (typeof config.claudeConfigDir === 'string' && config.claudeConfigDir.trim()) env.CLAUDE_CONFIG_DIR = config.claudeConfigDir.trim()
      else delete env.CLAUDE_CONFIG_DIR
    }
    if (resolved.presetId === 'codex' && !resolved.modern) {
      const shim = codexCompatHome(env && env.CODEX_HOME)
      if (shim) env = { ...(env || {}), CODEX_HOME: shim }
    } else if (resolved.presetId === 'claude-code' && !(env && env.CLAUDE_CODE_EXECUTABLE)) {
      const currentClaude = agentExecutable('claude', env)
      if (currentClaude) env = { ...(env || {}), CLAUDE_CODE_EXECUTABLE: currentClaude }
    }
    if (processLedger && processToken) env = { ...(env || {}), ...processLedger.markers(processToken) }
    // claude-code-acp intentionally exposes namespaced Claude Agent SDK
    // options through session/new|load `_meta`. Effort is fixed when that SDK
    // session is created, so the renderer reconnects the resumable session when
    // it changes; no global ~/.claude setting is modified.
    const sessionMeta = resolved.presetId === 'claude-code' && CLAUDE_EFFORTS.has(config.claudeEffort)
      ? { claudeCode: { options: { effort: config.claudeEffort } } }
      : null
    const terminalHost = buildTerminalHost(entry, sessionCwd, key, resolved.name, scope)
    entry.terminalHost = terminalHost
    const conn = new AcpConnection(
      // every ACP agent gets the shared Kaisola MCP server (project state +
      // agent-task ledger) plus the workspace's armed external servers
      // (.mcp.json approved + user catalog). The connection filters remote
      // entries per the agent's declared mcp capabilities at session time.
      {
        command: resolved.command,
        args: resolved.args,
        env,
        cwd: sessionCwd,
        sessionMeta,
        mcpServers: [
          mcpHttpEntry({ projectId: config.scope, workspace: sessionCwd, sender: entry.sender }),
          ...acpEntries(sessionCwd, { http: true, sse: true }),
        ].filter(Boolean),
      },
      {
        onUpdate: (params) => {
          const update = params && params.update ? params.update : params
          const authUrl = authUrlFromUpdate(update, entry.recentAuthAt)
          if (authUrl) surfaceAuthUrl(entry, resolved.name, key, authUrl)
          if (update && update.sessionUpdate === 'available_commands_update') {
            entry.availableCommands = sanitizedCommands(update.availableCommands)
            sendTo(entry, 'acp:commands', { key, commands: entry.availableCommands })
          }
          if (entry.current.channel && entry.current.sender && !entry.current.sender.isDestroyed()) {
            entry.current.sender.send(entry.current.channel, update)
          }
        },
        onNotice: (n) => {
          if (n && n.kind === 'stderr' && n.text) stderrTail = (stderrTail + n.text).slice(-600)
          // the agent process died — drop any inline cards it left pending, else
          // their resolvers + needs-you badge leak until the 5-min timeout
          if (n && n.kind === 'exit') { cancelPendingFor(entry); clearCancelWatchdog(entry) }
          sendTo(entry, 'acp:notice', { agent: resolved.name, key, ...n })
          const authUrl = authUrlFromNotice(n, entry.recentAuthAt)
          if (authUrl) surfaceAuthUrl(entry, resolved.name, key, authUrl)
        },
        onControls: (controls) => {
          entry.controls = freshenControls(resolved.presetId, controls, { modern: !!resolved.modern })
          sendTo(entry, 'acp:controls', { key, controls: entry.controls })
        },
        // The autonomy ladder decides who answers: observe auto-rejects,
        // execute/sprint auto-allow, propose asks the human via an inline
        // card in the thread (Zed-style — non-modal, option-per-button).
        onPermission: async (params) => {
          // per-connection autonomy (NOT a shared global): a window-1 Observe
          // agent stays read-only even after window-2 connects at Sprint, and the
          // live dial (acp:set-autonomy) can lower it mid-turn to stop this agent
          const immediate = immediatePermissionDecision(entry)
          if (immediate) return immediate
          // no live window to ask → fail CLOSED, never silently allow
          if (!entry.sender || entry.sender.isDestroyed()) return 'cancel'
          const toolCall = (params && params.toolCall) || {}
          const permId = `perm-${randomUUID()}`
          // diff-shaped content (OpenCode sends one diff block per file) —
          // the card renders the ACTUAL change, not just a tool name
          const diffs = (Array.isArray(toolCall.content) ? toolCall.content : [])
            .filter((c) => c && c.type === 'diff' && typeof c.path === 'string')
            .slice(0, 8)
            .map((c) => ({
              path: c.path,
              oldText: typeof c.oldText === 'string' ? c.oldText.slice(0, 40_000) : '',
              newText: typeof c.newText === 'string' ? c.newText.slice(0, 40_000) : '',
            }))
          return await new Promise((resolve) => {
            const timer = setTimeout(() => {
              pendingPermissions.delete(permId)
              resolve('cancel') // nobody answered — never silently allow
              // symmetrical to the acp:permission emit below: clear the orphaned
              // inline card + needs-you badge the renderer is still showing
              sendTo(entry, 'acp:permission-resolved', { permId })
            }, PERMISSION_TIMEOUT_MS)
            pendingPermissions.set(permId, { resolve, timer, entry })
            sendTo(entry, 'acp:permission', {
              permId,
              key,
              agent: resolved.name,
              title: toolCall.title || toolCall.kind || 'Agent action',
              kind: toolCall.kind,
              options: (params && params.options) || [],
              diffs,
            })
          })
        },
        terminalHost,
        fsGuard: (p) => !isSensitivePath(p, entry.sensitiveGlobs),
        onSpawn: ({ pid, pgid, command }) => processLedger?.recordSpawn({ token: processToken, pid, pgid, presetId: resolved.presetId, command }),
        onProcessExit: () => processLedger?.recordExit(processToken),
      },
    )
    entry.conn = conn

    try {
      conn.start()
      const handshake = (async () => {
        await conn.initialize()
        // restart/relaunch continuity: resume the thread's prior session when
        // the agent supports session/load; a stale/pruned id falls back fresh
        if (config.resumeSessionId) {
          if (conn.canResumeSession) {
            try {
              await conn.resumeSession(String(config.resumeSessionId))
              return { sessionId: String(config.resumeSessionId), resumed: true }
            } catch { /* try legacy load or fall through fresh */ }
          }
          if (conn.canLoadSession) {
            try {
              await conn.loadSession(String(config.resumeSessionId))
              return { sessionId: String(config.resumeSessionId), resumed: true }
            } catch { /* fall through to session/new */ }
          }
        }
        const session = await conn.newSession()
        return session
      })()
      const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('TIMEOUT')), CONNECT_TIMEOUT_MS))
      const session = await Promise.race([handshake, timeout])
      if (connectTask.cancelled || event.sender.isDestroyed()) {
        conn.dispose()
        return { ok: false, message: 'The window closed while the agent was connecting.' }
      }
      entry.meta = { key, presetId: resolved.presetId, scope, name: resolved.name, sessionId: session.sessionId }
      entry.controls = freshenControls(resolved.presetId, conn.getControls(), { modern: !!resolved.modern })
      connections.set(internalKey, entry)
      if ((connectionLeases.get(internalKey)?.size ?? 0) === 0) scheduleIdlePark(internalKey)
      return { ok: true, key, agent: entry.meta, controls: entry.controls, authMethods: conn.authMethods, resumed: !!session.resumed }
    } catch (err) {
      conn.dispose()
      return { ok: false, message: friendly(resolved, err, stderrTail) }
    }
    } finally {
      if (connectTasks.get(internalKey) === connectTask) connectTasks.delete(internalKey)
      releaseConnect()
    }
  })

  ipcMain.handle('acp:prompt', async (event, { agentKey, reqId, text, images, readOnly } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    if (terminalOwnerMoves.has(entry)) return { ok: false, moving: true, message: 'This project is moving to another window. Try again in a moment.' }
    if (entry.current.channel || (entry.inFlightTurns ?? 0) > 0) return { ok: false, message: 'The previous agent turn is still stopping — send again in a moment.' }
    entry.cancelRequested = false
    // identity token: acp:cancel may null entry.current to free the composer for a
    // hung agent, so read the __done target from this local turn (not entry.current,
    // which cancel/a newer prompt may have replaced) and clear only if still ours.
    const turn = { sender: event.sender, channel: `acp:update:${reqId}` }
    entry.current = turn
    entry.turnSeq = (entry.turnSeq ?? 0) + 1
    entry.inFlightTurns = (entry.inFlightTurns ?? 0) + 1
    entry.steerPromises = [] // steering follow-ups injected while THIS turn runs
    let signalTurnDone
    entry.turnDone = new Promise((resolve) => { signalTurnDone = resolve })
    const constrainedMode = readOnly === true ? readOnlyModeForControls(entry.controls) : null
    let restoreModeId = null
    // A finished turn holds its channel briefly so a steer that IS still
    // streaming can flush — but only briefly. The adapter may never answer an
    // injected prompt's own request id (promptQueueing absorbs it into the
    // turn), and an unbounded allSettled here wedged the connection for good.
    const flushSteers = async () => {
      entry.turnEnding = true // refuse new steers into a turn that's over
      signalTurnDone()
      if (entry.steerPromises.length) {
        await Promise.race([
          Promise.allSettled(entry.steerPromises),
          new Promise((resolve) => setTimeout(resolve, STEER_FLUSH_MS)),
        ])
      }
    }
    try {
      if (readOnly === true) {
        if (!constrainedMode) throw new Error('This agent does not expose a read-only mode required by Mesh Idea mode.')
        if (constrainedMode.previousModeId !== constrainedMode.modeId) {
          await entry.conn.setMode(constrainedMode.modeId)
          restoreModeId = constrainedMode.previousModeId
        }
      }
      const res = await entry.conn.prompt(text, images)
      await flushSteers()
      if (turn.sender && !turn.sender.isDestroyed()) {
        turn.sender.send(turn.channel, { __done: true, stopReason: res && res.stopReason })
      }
      return { ok: true, stopReason: res && res.stopReason }
    } catch (err) {
      await flushSteers()
      if (turn.sender && !turn.sender.isDestroyed()) turn.sender.send(turn.channel, { __done: true })
      return { ok: false, message: err.message }
    } finally {
      if (restoreModeId && entry.conn.alive) {
        try { await entry.conn.setMode(restoreModeId) } catch { /* fail safe: remaining read-only is safer than widening silently */ }
      }
      if (entry.current === turn) entry.current = { sender: null, channel: null }
      entry.steerPromises = []
      entry.turnEnding = false
      // prompts are serialized by the guard above, so when a turn fully
      // unwinds NOTHING is legitimately in flight — force-reset instead of
      // decrementing so an unanswered steer can never strand the counter
      entry.inFlightTurns = 0
      entry.cancelRequested = false
      clearCancelWatchdog(entry)
    }
  })

  // Mid-turn STEER: deliver a follow-up to an agent whose turn is already
  // running, WITHOUT opening a new stream channel. For a promptQueueing agent
  // (claude-code-acp) the SDK injects it at the next tool boundary; its output
  // rides the active turn's channel, and the original acp:prompt above holds
  // that channel open until this settles. Refused (so the renderer falls back
  // to normal enqueue) when the agent can't queue or there's no active turn.
  ipcMain.handle('acp:steer', async (event, { agentKey, text, images } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    if (!entry.conn.supportsPromptQueue) return { ok: false, message: 'unsupported', unsupported: true }
    // turnEnding: the turn's result already landed and only its flush window
    // remains — a steer now would ride a channel about to close, so refuse it
    // (the renderer falls back to the normal queue; nothing is lost)
    if (!(entry.current && entry.current.channel) || entry.turnEnding) return { ok: false, message: 'No active turn to steer.', noTurn: true }
    const seq = entry.turnSeq
    const turnDone = entry.turnDone
    entry.inFlightTurns = (entry.inFlightTurns ?? 0) + 1
    const p = entry.conn.prompt(text, images)
    ;(entry.steerPromises ??= []).push(p.catch(() => {}))
    try {
      // The adapter may absorb this injected prompt into the running turn and
      // never answer its own request id. Never hang the renderer on that:
      // once the owning turn ends (plus a short grace for a racing response),
      // the steered text was either woven into the turn — its output already
      // streamed on the shared channel — or the turn closed without it.
      const settled = await Promise.race([
        p.then((res) => ({ res })).catch((err) => ({ err })),
        turnDone.then(() => new Promise((resolve) => setTimeout(resolve, STEER_FLUSH_MS))).then(() => ({ turnEnded: true })),
      ])
      if (settled.turnEnded) return { ok: true, stopReason: 'turn_ended' }
      if (settled.err) return { ok: false, message: settled.err.message }
      return { ok: true, stopReason: settled.res && settled.res.stopReason }
    } finally {
      // the owning turn's finally force-resets the counter; only decrement if
      // that turn is still the live one (never steal from a NEWER turn)
      if (entry.turnSeq === seq) entry.inFlightTurns = Math.max(0, (entry.inFlightTurns ?? 1) - 1)
    }
  })

  ipcMain.handle('acp:setMode', async (event, { agentKey, modeId } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    if (terminalOwnerMoves.has(entry)) return { ok: false, moving: true }
    try { await entry.conn.setMode(modeId); return { ok: true } } catch (err) { return { ok: false, message: err.message } }
  })

  ipcMain.handle('acp:setConfigOption', async (event, { agentKey, configId, value } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    if (terminalOwnerMoves.has(entry)) return { ok: false, moving: true }
    try { await entry.conn.setConfigOption(configId, value); return { ok: true } } catch (err) { return { ok: false, message: err.message } }
  })

  ipcMain.handle('acp:setModel', async (event, { agentKey, modelId } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry || !entry.conn.alive) return { ok: false, message: 'Agent not connected.' }
    if (terminalOwnerMoves.has(entry)) return { ok: false, moving: true }
    try { await entry.conn.setModel(modelId); return { ok: true } } catch (err) { return { ok: false, message: err.message } }
  })

  // Trigger an agent's auth method. The agent prints/opens its OAuth URL; we
  // auto-open it (surfaceAuthUrl). The `authenticate` call itself can block until
  // the user finishes signing in, so we do NOT await it — we race a short timeout
  // and let the URL surface asynchronously.
  ipcMain.handle('acp:authenticate', async (event, { agentKey, methodId } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry) return { ok: false, message: 'Agent not connected.' }
    if (terminalOwnerMoves.has(entry)) return { ok: false, moving: true }
    // never send a methodId the agent didn't advertise — agents answer an
    // unknown/absent id with a bare JSON-RPC "Invalid params", which is
    // useless to a human. Fall back to the first advertised method.
    const methods = (entry.conn && entry.conn.authMethods) || []
    const mid = methods.some((m) => m && m.id === methodId) ? methodId : methods[0] && methods[0].id
    if (mid == null) return { ok: false, message: 'This agent offers no in-app sign-in — use its CLI login instead.' }
    entry.recentAuthAt = Date.now()
    entry.lastAuthUrl = null
    const call = entry.conn.authenticate(mid).then(() => ({ done: true })).catch((err) => ({ err: err.message }))
    const quick = await Promise.race([call, new Promise((r) => setTimeout(() => r({ pending: true }), 2500))])
    if (quick.err) return { ok: false, message: quick.err }
    if (quick.pending) return { ok: true, pending: true } // browser flow in progress; URL opens via surfaceAuthUrl
    return { ok: true }
  })

  // Renderer-owned guardrail globs (Settings → Agents). Never let one live
  // WebContents mutate the filesystem policy of another.
  ipcMain.on('acp:guardrails', (event, globs) => {
    setRendererSensitiveGlobs(event.sender, globs)
  })

  // live autonomy dial: apply to EVERY connection this window owns (keys start
  // `${sender.id}|`) so lowering to Observe mid-session immediately stops each
  // running agent's next request, without touching another window's agents.
  ipcMain.handle('acp:set-autonomy', (event, { autonomy } = {}) => {
    const prefix = `${event.sender.id}|`
    for (const [k, entry] of connections) {
      if (k.startsWith(prefix)) entry.autonomy = autonomy || DEFAULT_AUTONOMY
    }
    return { ok: true }
  })

  // the inline card's answer — 'allow' | 'reject' | a concrete optionId
  ipcMain.handle('acp:permission:respond', (event, { permId, optionId, decision } = {}) => {
    const pending = pendingPermissions.get(permId)
    if (!pending) return { ok: false }
    if (pending.entry?.sender !== event.sender && pending.entry?.sender?.id !== event.sender?.id) return { ok: false }
    pendingPermissions.delete(permId)
    clearTimeout(pending.timer)
    pending.resolve(optionId ? { optionId } : decision === 'reject' ? 'reject' : 'allow')
    return { ok: true }
  })

  ipcMain.handle('acp:cancel', (event, { agentKey } = {}) => {
    const internalKey = ikey(event.sender, agentKey)
    const entry = entryFor(event.sender, agentKey)
    // Stop is a fail-closed boundary. A permission prompt must become
    // unactionable as soon as cancellation is requested, not several seconds
    // later when the stuck-turn watchdog reaps the adapter. Otherwise a human
    // can approve a state-changing tool after Mesh has visibly paused.
    if (entry) beginEntryCancellation(entry)
    entry?.conn.cancel()
    // a hung agent may ACK session/cancel but neither finish nor exit, so the
    // prompt's promise never settles and its finally never clears the lock —
    // free it here so the composer isn't wedged. The in-flight prompt's finally
    // is identity-guarded (only clears if entry.current is still its own turn),
    // so this can't double-clear or stomp a newer turn.
    if (entry && entry.current.channel) entry.current = { sender: null, channel: null }
    if (entry && (entry.inFlightTurns ?? 0) > 0 && !entry.cancelWatchdog) {
      entry.cancelWatchdog = setTimeout(() => {
        entry.cancelWatchdog = null
        if ((entry.inFlightTurns ?? 0) <= 0) return
        // Some adapters acknowledge cancel but never settle session/prompt.
        // Reap this exact owned group after a grace period; its durable session
        // id lets the next send reconnect without mixing old/new turn streams.
        cancelPendingFor(entry)
        entry.conn.dispose()
        if (connections.get(internalKey) === entry) connections.delete(internalKey)
        connectionLeases.delete(internalKey)
        clearIdleTimer(internalKey)
        sendTo(entry, 'acp:notice', { agent: entry.meta?.name, key: agentKey, kind: 'cancel-timeout', text: 'The agent did not stop cleanly; Kaisola safely ended its owned process group. Send again to resume.' })
      }, CANCEL_GRACE_MS)
      entry.cancelWatchdog.unref?.()
    }
    return { ok: true }
  })

  ipcMain.handle('acp:close-session', async (event, { agentKey } = {}) => {
    const entry = entryFor(event.sender, agentKey)
    if (!entry?.conn?.alive) return { ok: true, closed: false }
    if (terminalOwnerMoves.has(entry)) return { ok: false, closed: false, moving: true }
    if (!entry.conn.canCloseSession) return { ok: true, closed: false }
    try {
      const result = await entry.conn.closeSession()
      return { ok: true, closed: !!result.closed }
    } catch (error) {
      return { ok: false, closed: false, message: String(error?.message ?? error) }
    }
  })

  ipcMain.handle('acp:disconnect', (event, { agentKey } = {}) => {
    const internalKey = ikey(event.sender, agentKey)
    const connecting = connectTasks.get(internalKey)
    if (connecting) {
      connecting.cancelled = true
      connecting.entry?.conn?.dispose()
    }
    clearIdleTimer(internalKey)
    connectionLeases.delete(internalKey)
    const entry = connections.get(internalKey)
    if (entry && terminalOwnerMoves.has(entry)) return { ok: false, moving: true }
    if (entry) {
      cancelPendingFor(entry) // drop any inline cards before the connection goes away
      clearCancelWatchdog(entry)
      entry.conn.dispose()
      connections.delete(internalKey)
    }
    return { ok: true }
  })
}

async function disposeAcp() {
  for (const timer of idleTimers.values()) clearTimeout(timer)
  idleTimers.clear()
  connectionLeases.clear()
  const entries = new Set([...connections.values(), ...[...connectTasks.values()].map((task) => task.entry).filter(Boolean)])
  for (const entry of entries) clearCancelWatchdog(entry)
  await Promise.allSettled([...entries].map((entry) => entry.conn?.disposeAndWait?.() ?? Promise.resolve(entry.conn?.dispose())))
  connections.clear()
  connectTasks.clear()
  sensitiveGlobsBySender.clear()
}

module.exports = {
  registerAcpHandlers,
  disposeAcp,
  acpRendererSwapState,
  acpRestartSafetyState,
  waitForAcpRestartSafe,
  acpProjectTransferState,
  transferAcpProject,
  releaseAcpRenderer,
  cachedNpxAdapter,
  adapterPreset,
  claudePreset,
  codexPreset,
  newestCodexExecutable,
  freshenControls,
  sanitizedCommands,
  authUrlFromNotice,
  authUrlFromUpdate,
  _acpTest: {
    connections,
    connectTasks,
    pendingPermissions,
    connectionLeases,
    idleTimers,
    scheduleIdlePark,
    canIdlePark,
    cancelPendingFor,
    immediatePermissionDecision,
    beginEntryCancellation,
    agentSummary,
    acpRendererSwapState,
    acpRestartSafetyState,
    waitForAcpRestartSafe,
    acpProjectTransferState,
    transferAcpProject,
    releaseAcpRenderer,
    sanitizeSensitiveGlobs,
    sensitiveGlobsForSender,
    setRendererSensitiveGlobs,
    clearRendererSensitiveGlobs,
    bindEntryToSender,
    buildTerminalHost,
    transferEntryTerminalOwnership,
    isSensitivePath,
    resolveBundledCodexExecutable,
    resolveBundledClaudeExecutable,
    readOnlyModeForControls,
  },
}
