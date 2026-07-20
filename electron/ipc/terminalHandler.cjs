// IPC for the interactive dock terminal. Backed by the shared terminalManager
// (node-pty), so a real pseudo-terminal renders its own prompt, `cd` works, and
// colors/interactive apps work. The renderer (xterm.js) forwards raw bytes.
const os = require('node:os')
const path = require('node:path')
const crypto = require('node:crypto')
const fs = require('node:fs/promises')
const { spawn, execFile } = require('node:child_process')
const { BrowserWindow, app } = require('electron')
const { configureSessionBroker, sessionBroker, TERMINAL_OBSERVE_FEATURE } = require('./sessionBrokerClient.cjs')
const { terminalOwnerParts } = require('./securityPolicy.cjs')

// terminal:run cap: a non-terminating command (dev server, tail -f, blocked on
// stdin) never fires 'close', so without this the invoke Promise hangs forever.
// On timeout the child is killed and the promise resolves with partial output.
const RUN_TIMEOUT_MS = 120_000
const COMPANION_SNAPSHOT_POLL_MS = 350
const runChildren = new Set()
let brokerClient = null
let terminalAttentionSink = null
const terminalProjects = new Map()

function setTerminalAttentionSink(sink) {
  terminalAttentionSink = typeof sink === 'function' ? sink : null
}

function broker() {
  return brokerClient || sessionBroker()
}

// ── session identity poller ──────────────────────────────────────────────────
// Every live pty is polled for its FOREGROUND process (free via node-pty) and
// its live cwd (lsof — the shell cd's after spawn, so the record cwd goes
// stale); cwd changes refresh repo root + branch. Only DIFFS are broadcast
// (terminal:meta) so an idle shell costs nothing downstream.
// 2.5s while the app is focused; 10s while it's in the background — the meta
// only feeds badges/labels, and lsof every 2.5s for an app nobody is looking
// at is pure heat. Refocus polls immediately, so badges are fresh on return.
const POLL_MS_FOCUSED = 2500
const POLL_MS_BLURRED = 10_000
let pollMs = POLL_MS_FOCUSED
const SHELLS = new Set(['zsh', 'bash', 'fish', 'sh', 'dash', '-zsh', '-bash', 'login'])
let metaTimer = null
const metaCache = new Map() // id → { process, cwd, root, branch }
const gitCache = new Map() // cwd → { root, branch, at }

function execOut(cmd, args) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 4000 }, (err, stdout) => resolve(err ? null : stdout))
  })
}

/** node-pty reports the foreground process-group leader. Package-installed
 * JavaScript CLIs often make that leader `node`, even though the command the
 * user launched is Codex. Reduce only known wrappers to a safe identity; never
 * expose the full command line (which may contain private arguments). */
function wrappedCliProcess(processName, commandLine) {
  const leaf = path.basename(String(processName || '')).replace(/^-/, '').toLowerCase()
  if (!['node', 'bun', 'deno'].includes(leaf)) return processName || ''
  const command = String(commandLine || '')
  if (/(?:^|[\s/])codex(?:\.js)?(?:\s|$)/i.test(command)) return 'codex'
  return processName || ''
}

async function foregroundProcessIdentity(terminal) {
  const raw = terminal?.process || ''
  const leaf = path.basename(raw).replace(/^-/, '').toLowerCase()
  if (!['node', 'bun', 'deno'].includes(leaf) || !terminal?.pid) return raw
  const foreground = Number(String(await execOut('ps', ['-o', 'tpgid=', '-p', String(terminal.pid)]) || '').trim())
  if (!(foreground > 0)) return raw
  const commandLine = await execOut('ps', ['-o', 'command=', '-p', String(foreground)])
  return wrappedCliProcess(raw, commandLine)
}

const CODEX_SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const codexIdFromPath = (file) => {
  const match = path.basename(file).match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i)
  return match?.[1] && CODEX_SESSION_ID.test(match[1]) ? match[1] : null
}
const jsonStringField = (text, field) => {
  const match = text.match(new RegExp(`"${field}":"((?:\\\\.|[^"\\\\])*)"`))
  if (!match) return null
  try { return JSON.parse(`"${match[1]}"`) } catch { return null }
}

/** Resolve a live Codex TUI to its exact rollout. First ask the foreground
 * process which JSONL it has open (exact even with many sessions); fall back to
 * the newest CLI/TUI rollout for this cwd if lsof races startup. */
async function codexSession(id, cwd, sender = null, projectId) {
  let terminals = []
  try { terminals = await broker().terminal('list', sender, { projectId }, { timeoutMs: 5000 }) } catch { /* semantic fallback below */ }
  const live = terminals.find((terminal) => terminal.id === id)
  // Renderer callers must prove this terminal belongs to their exact live
  // window+project capability before the rollout fallback scans local files.
  if (sender && !live) return { ok: false, message: 'Terminal is unavailable in this project.' }
  if (live?.pid) {
    const foreground = Number(String(await execOut('ps', ['-o', 'tpgid=', '-p', String(live.pid)]) || '').trim())
    if (foreground > 0) {
      const openFiles = await execOut('lsof', ['-a', '-p', String(foreground), '-Fn'])
      for (const line of String(openFiles || '').split('\n')) {
        if (!line.startsWith('n') || !/\/\.codex\/sessions\/.+\.jsonl$/.test(line)) continue
        const sessionId = codexIdFromPath(line.slice(1))
        if (sessionId) return { ok: true, sessionId, exact: true }
      }
    }
  }

  const root = path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'sessions')
  const files = []
  const walk = async (dir, depth = 0) => {
    if (depth > 4 || files.length >= 3000) return
    let entries
    try { entries = await fs.readdir(dir, { withFileTypes: true }) } catch { return }
    // Session directories are YYYY/MM/DD. Newest-first sequential traversal
    // makes the cap deterministic instead of letting Promise scheduling fill
    // it with arbitrary old years on large Codex histories.
    entries.sort((a, b) => b.name.localeCompare(a.name))
    for (const entry of entries) {
      if (files.length >= 3000) break
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) await walk(full, depth + 1)
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        files.push({ file: full })
      }
    }
  }
  await walk(root)
  // Rollout filenames carry their creation timestamp. mtime is wrong here: a
  // day-old Codex window that is still chatting would beat a newly launched
  // terminal and attach the restart command to the wrong conversation.
  files.sort((a, b) => b.file.localeCompare(a.file))
  for (const candidate of files.slice(0, 120)) {
    let handle
    try {
      handle = await fs.open(candidate.file, 'r')
      const buffer = Buffer.alloc(32 * 1024)
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0)
      const head = buffer.subarray(0, bytesRead).toString('utf8')
      const originator = jsonStringField(head, 'originator')
      if (!/codex[-_](?:tui|cli)|codex_cli_rs/i.test(originator || '')) continue
      if (cwd && jsonStringField(head, 'cwd') !== cwd) continue
      const sessionId = jsonStringField(head, 'session_id') || codexIdFromPath(candidate.file)
      if (sessionId && CODEX_SESSION_ID.test(sessionId)) return { ok: true, sessionId, exact: false }
    } catch { /* unreadable candidate */ } finally { await handle?.close().catch(() => {}) }
  }
  return { ok: false, message: 'Codex session is not discoverable yet.' }
}

/** cwd per pid for MANY pids in ONE lsof call — lsof enumerates fd tables and
 *  is the priciest thing this poller does; one process per tick beats one per pty. */
async function cwdOfPids(pids) {
  const map = new Map()
  if (!pids.length) return map
  // macOS has no /proc; lsof's cwd descriptor is the portable answer
  const out = await execOut('lsof', ['-a', '-p', pids.join(','), '-d', 'cwd', '-Fpn'])
  if (!out) return map
  let pid = null
  for (const line of out.split('\n')) {
    if (line.startsWith('p')) pid = Number(line.slice(1))
    else if (line.startsWith('n') && pid != null) map.set(pid, line.slice(1))
  }
  return map
}

async function gitInfo(cwd) {
  const hit = gitCache.get(cwd)
  if (hit && Date.now() - hit.at < 15_000) return hit
  const out = await execOut('git', ['-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD', '--show-toplevel'])
  const info = out
    ? { branch: out.split('\n')[0]?.trim() || null, root: out.split('\n')[1]?.trim() || null, at: Date.now() }
    : { branch: null, root: null, at: Date.now() }
  gitCache.set(cwd, info)
  return info
}

async function pollMeta() {
  let live = []
  try { live = await broker().terminal('list', null, {}, { timeoutMs: 5000 }) } catch { return }
  for (const id of Array.from(metaCache.keys())) {
    if (!live.some((t) => t.id === id)) metaCache.delete(id)
  }
  // only shells sitting at a prompt can `cd` — while a program (an agent, vim,
  // a build) holds the foreground the cwd is frozen, so skip lsof for it.
  // Unknown cwd (fresh pty) is always resolved once.
  const pollable = live.filter((t) => {
    const prev = metaCache.get(t.id)
    return !prev?.cwd || SHELLS.has(path.basename(t.process || ''))
  })
  const cwds = await cwdOfPids(pollable.map((t) => t.pid))
  for (const t of live) {
    const prev = metaCache.get(t.id) || {}
    const processIdentity = await foregroundProcessIdentity(t)
    const next = {
      ...prev,
      process: processIdentity,
      agentBusy: !!t.agentBusy,
      agentCompletedAt: t.agentCompletedAt || null,
      agentRespondedAt: t.agentRespondedAt || null,
    }
    const cwd = cwds.get(t.pid)
    if (cwd) next.cwd = cwd
    if (next.cwd && next.cwd !== prev.cwd) {
      const git = await gitInfo(next.cwd)
      next.root = git.root
      next.branch = git.branch
    } else if (next.cwd && prev.root !== undefined) {
      // same dir — refresh the branch on the git cache's own cadence
      const git = await gitInfo(next.cwd)
      next.root = git.root
      next.branch = git.branch
    }
    if (next.process !== prev.process || next.cwd !== prev.cwd || next.branch !== prev.branch || next.root !== prev.root || next.agentBusy !== prev.agentBusy || next.agentCompletedAt !== prev.agentCompletedAt || next.agentRespondedAt !== prev.agentRespondedAt) {
      metaCache.set(t.id, next)
      const payload = {
        id: t.id,
        fgProcess: next.process || null,
        running: !!next.process && !SHELLS.has(path.basename(next.process)),
        cwd: next.cwd || null,
        root: next.root || null,
        repo: next.root ? path.basename(next.root) : null,
        branch: next.branch || null,
        agentBusy: next.agentBusy,
        agentCompletedAt: next.agentCompletedAt,
        agentRespondedAt: next.agentRespondedAt,
      }
      for (const win of BrowserWindow.getAllWindows()) {
        const owner = terminalOwnerParts(t.owner)
        if (!win.webContents.isDestroyed() && owner?.instanceId === broker().instanceId && owner.ownerId === String(win.webContents.id)) {
          win.webContents.send('terminal:meta', payload)
        }
      }
    }
  }
  // idle-stop: no sessions → no timer (spawn restarts it)
  if (!live.length && metaTimer) {
    clearInterval(metaTimer)
    metaTimer = null
  }
}

function ensureMetaPolling() {
  if (metaTimer || process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE) return // deterministic harnesses skip the poller
  metaTimer = setInterval(() => { void pollMeta() }, pollMs)
  void pollMeta()
}

/** App focus drives the whole terminal-stream profile: pty flush coalescing
 * (manager) and this poller's cadence. Called from main.cjs. */
function setAppFocused(focused) {
  void broker().terminal('setFocused', null, { focused }, { timeoutMs: 3000 }).catch(() => {})
  const next = focused ? POLL_MS_FOCUSED : POLL_MS_BLURRED
  if (next === pollMs) return
  pollMs = next
  if (metaTimer) {
    clearInterval(metaTimer)
    metaTimer = setInterval(() => { void pollMeta() }, pollMs)
    if (focused) void pollMeta() // catch up the badges the moment the user is back
  }
}

function registerTerminalHandlers(ipcMain) {
  const brokerScript = app.isPackaged
    ? path.join(process.resourcesPath, 'app.asar.unpacked', 'electron', 'session-broker.cjs')
    : path.join(__dirname, '..', 'session-broker.cjs')
  brokerClient = configureSessionBroker({
    userData: app.getPath('userData'),
    execPath: process.execPath,
    brokerScript,
    appVersion: app.getVersion(),
    smoke: !!(process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE),
  })
  brokerClient.setEventSink?.(({ projectId, channel, payload }) => {
    if (!terminalAttentionSink || typeof channel !== 'string') return
    const id = typeof payload?.id === 'string'
      ? payload.id
      : channel.startsWith('terminal:exit:') ? channel.slice('terminal:exit:'.length) : null
    const exactProjectId = typeof projectId === 'string' && projectId !== 'legacy'
      ? projectId
      : id ? terminalProjects.get(id) : null
    if (!id || !exactProjectId) return
    if (channel === 'terminal:agent-activity') {
      terminalAttentionSink({
        projectId: exactProjectId,
        sessionId: id,
        busy: payload?.busy === true,
        completedAt: payload?.completedAt,
      })
    } else if (channel === `terminal:exit:${id}`) {
      terminalAttentionSink({ projectId: exactProjectId, sessionId: id, exitCode: Number(payload) })
      terminalProjects.delete(id)
    }
  })
  // Lazy by design: file-only work should not pay for a helper process. The
  // first terminal/CLI/ACP-terminal request adopts an existing broker or starts
  // one; closing the last session lets that helper retire again.

  ipcMain.handle('terminal:create', async (event, { id, cwd, cols, rows, projectId } = {}) => {
    const result = await broker().terminal('create', event.sender, { id, cwd: cwd || os.homedir(), cols, rows, projectId }, { timeoutMs: 20_000 })
    if (!result?.ok) return result || { ok: false, message: 'could not start terminal' }
    if (typeof id === 'string' && typeof projectId === 'string') {
      terminalProjects.delete(id)
      terminalProjects.set(id, projectId)
      while (terminalProjects.size > 500) terminalProjects.delete(terminalProjects.keys().next().value)
    }
    ensureMetaPolling()
    return { ...result, cwd: cwd || os.homedir(), shell: process.env.SHELL || '/bin/zsh' }
  })

  ipcMain.handle('terminal:write', (event, { id, data, projectId } = {}) => broker().terminal('write', event.sender, { id, data, projectId }))
  ipcMain.on('terminal:agent-turn', (event, { id, busy, projectId } = {}) => {
    void broker().terminal('agentTurn', event.sender, { id, busy, projectId }, { timeoutMs: 3000 }).catch(() => {})
  })
  ipcMain.handle('terminal:resize', (event, { id, cols, rows, projectId } = {}) => broker().terminal('resize', event.sender, { id, cols, rows, projectId }))
  ipcMain.handle('terminal:snapshot', (event, { id, projectId } = {}) => broker().terminal('snapshot', event.sender, { id, projectId }))
  ipcMain.handle('terminal:detachRenderer', (event, { id, viewState, projectId } = {}) => broker().terminal('detachRenderer', event.sender, { id, viewState, projectId }))
  ipcMain.handle('terminal:diagnostics', (event, { projectId } = {}) => broker().terminal('diagnostics', event.sender, { projectId }))
  ipcMain.handle('terminal:codexSession', (event, { id, cwd, projectId } = {}) => codexSession(id, cwd, event.sender, projectId))
  ipcMain.handle('terminal:signal', (event, { id, projectId } = {}) => broker().terminal('signal', event.sender, { id, projectId }))
  ipcMain.handle('terminal:kill', (event, { id, projectId } = {}) => broker().terminal('release', event.sender, { id, projectId }))
  ipcMain.handle('terminal:schedule-release', (event, { id, projectId, delayMs } = {}) => broker().terminal('scheduleRelease', event.sender, { id, projectId, delayMs }))
  ipcMain.handle('terminal:cancel-release', (event, { id, projectId } = {}) => broker().terminal('cancelRelease', event.sender, { id, projectId }))

  // when a renderer (re)attaches to an existing session, re-point its stream
  // (agent-spawned ptys arrive this way — make sure they're polled too)
  ipcMain.handle('terminal:attach', async (event, { id, projectId } = {}) => {
    const result = await broker().terminal('attach', event.sender, { id, projectId })
    if (result?.ok && typeof id === 'string' && typeof projectId === 'string') {
      terminalProjects.delete(id)
      terminalProjects.set(id, projectId)
      while (terminalProjects.size > 500) terminalProjects.delete(terminalProjects.keys().next().value)
    }
    ensureMetaPolling()
    return result
  })

  // One-shot capture (used by the agent's lightweight run-command tool).
  ipcMain.handle('terminal:run', (_e, { command, cwd } = {}) => {
    return new Promise((resolve) => {
      const shell = process.env.SHELL || '/bin/zsh'
      // detached: give the shell its OWN process group so killing -pid reaps the
      // whole tree (npm → node/vite, pipeline members), not just the shell — a bare
      // child.kill would orphan grandchildren (a dev server) to launchd.
      const child = spawn(shell, ['-lc', command], { cwd: cwd || os.homedir(), env: process.env, detached: true })
      runChildren.add(child)
      const dropChild = () => runChildren.delete(child)
      child.once('exit', dropChild)
      child.once('error', dropChild)
      child.unref() // a lingering run-child must not, by itself, hold the app open
      // only the first 20k chars survive anyway — cap DURING accumulation so a
      // huge-output command can't balloon main-process memory first
      let out = ''
      let err = ''
      let settled = false
      let timer = null
      const finish = (result) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        runChildren.delete(child)
        resolve(result)
      }
      // a command that never terminates (dev server, tail -f, blocked on stdin)
      // never fires 'close', so cap it: kill the child and resolve with whatever
      // it printed so far (flagged timedOut) rather than hang the invoke forever.
      timer = setTimeout(() => {
        // -pid kills the whole detached group (shell + grandchildren); fall back
        // to the bare child if it already exited and the group is gone.
        try { process.kill(-child.pid, 'SIGKILL') } catch { try { child.kill('SIGKILL') } catch { /* already gone */ } }
        finish({ ok: false, code: -1, stdout: out.slice(0, 20000), stderr: err.slice(0, 20000), timedOut: true })
      }, RUN_TIMEOUT_MS)
      timer.unref?.() // the timeout itself must not keep the event loop alive
      child.stdout.on('data', (d) => { if (out.length < 20000) out += d.toString() })
      child.stderr.on('data', (d) => { if (err.length < 20000) err += d.toString() })
      child.on('close', (code) => finish({ ok: code === 0, code, stdout: out.slice(0, 20000), stderr: err.slice(0, 20000) }))
      child.on('error', (e) => finish({ ok: false, code: -1, stdout: '', stderr: String(e.message) }))
    })
  })
}

function killRunChildren() {
  for (const child of runChildren) {
    try { process.kill(-child.pid, 'SIGKILL') } catch { try { child.kill('SIGKILL') } catch {} }
  }
  runChildren.clear()
}

function killAllSessions() {
  void broker().shutdown()
  killRunChildren()
  if (metaTimer) {
    clearInterval(metaTimer)
    metaTimer = null
  }
}

function forgetRendererOwner(sender) {
  return broker().forgetOwner(sender)
}

/** Resolve a companion request against the broker's authoritative inventory.
 * The caller supplies both the opaque terminal id and immutable project id;
 * neither is sufficient on its own. Administrative broker calls below never
 * adopt or replace the renderer owner. */
async function companionTerminalRecord({ id, projectId }) {
  if (typeof id !== 'string' || !id || typeof projectId !== 'string' || !projectId) {
    return { ok: false, status: 'rejected', message: 'Terminal target is invalid.' }
  }
  await broker().connect()
  const rows = await broker().terminal('list', null, {}, { timeoutMs: 5_000 })
  const row = Array.isArray(rows) ? rows.find((candidate) => candidate?.id === id) : null
  if (!row) return { ok: false, status: 'unavailable', message: 'Terminal is no longer available.' }
  const owner = terminalOwnerParts(row.owner) || terminalOwnerParts(row.lastOwner)
  if (!owner || owner.projectId !== projectId) {
    return { ok: false, status: 'rejected', message: 'Terminal does not belong to this project.' }
  }
  return { ok: true, row, owner }
}

async function companionTerminalSnapshot({ id, projectId }) {
  const target = await companionTerminalRecord({ id, projectId })
  if (!target.ok) return target
  const snapshot = await broker().terminal('snapshot', null, { id, projectId }, { timeoutMs: 5_000 })
  if (!snapshot?.streamEpoch) {
    return { ok: false, status: 'unavailable', message: 'Terminal output is no longer available.' }
  }
  return { ok: true, snapshot }
}

/** Main-owned terminal control adapter. Every operation revalidates the
 * terminal/project tuple and uses the broker's administrative path only after
 * that exact match. It never calls attach/create/setSender. */
const companionTerminalControl = Object.freeze({
  async available({ id, projectId }) {
    const target = await companionTerminalRecord({ id, projectId })
    if (!target.ok) return target
    const { cols, rows } = target.row
    return Number.isSafeInteger(cols) && cols > 0 && Number.isSafeInteger(rows) && rows > 0
      ? { ok: true, geometry: { cols, rows } }
      : { ok: true }
  },
  async write({ id, projectId, data }) {
    const target = await companionTerminalRecord({ id, projectId })
    if (!target.ok) return target
    return broker().terminal('write', null, { id, projectId, data }, { timeoutMs: 5_000 })
  },
  async resize({ id, projectId, cols, rows }) {
    const target = await companionTerminalRecord({ id, projectId })
    if (!target.ok) return target
    return broker().terminal('resize', null, { id, projectId, cols, rows }, { timeoutMs: 5_000 })
  },
  async interrupt({ id, projectId }) {
    const target = await companionTerminalRecord({ id, projectId })
    if (!target.ok) return target
    return broker().terminal('signal', null, { id, projectId }, { timeoutMs: 5_000 })
  },
})

/** Internal-only observer path used by the companion gateway. It never
 * enters ipcMain/preload, and its broker method cannot adopt terminal owner. */
async function subscribeTerminalObserver({
  id,
  projectId,
  subscriberId,
  streamEpoch,
  afterOffset,
  maxQueueBytes,
  onEvent,
}) {
  if (typeof onEvent !== 'function') throw new Error('terminal observer callback is required')
  if (typeof id !== 'string' || !id || typeof projectId !== 'string' || !projectId) throw new Error('terminal observer target is invalid')
  const digest = crypto.createHash('sha256').update(`${subscriberId || 'device'}\0${id}\0${projectId}`).digest('hex').slice(0, 24)
  const sender = {
    id: `companion-${digest}`,
    isDestroyed: () => false,
    send: (channel, payload) => onEvent({ channel, payload }),
  }
  await broker().connect()
  if (!broker().supports(TERMINAL_OBSERVE_FEATURE)) {
    // A broker may outlive the Electron build that launched it so its PTYs
    // survive app updates. Older protocol-2 brokers do not have observer fanout,
    // but they do expose bounded snapshots. Poll those snapshots without
    // replacing the broker or adopting its terminals, then automatically use
    // native observer deltas once the durable broker eventually retires.
    const initial = await companionTerminalSnapshot({ id, projectId })
    if (!initial.ok) return { ...initial, unavailable: initial.status === 'unavailable' }
    let closed = false
    let polling = false
    let lastEpoch = initial.snapshot.streamEpoch
    let lastOffset = initial.snapshot.endOffset
    let lastExited = initial.snapshot.exited === true
    const timer = setInterval(async () => {
      if (closed || polling) return
      polling = true
      try {
        const next = await companionTerminalSnapshot({ id, projectId })
        if (!next.ok || closed) return
        const snapshot = next.snapshot
        const changed = snapshot.streamEpoch !== lastEpoch
          || snapshot.endOffset !== lastOffset
          || (snapshot.exited === true) !== lastExited
        if (!changed) return
        lastEpoch = snapshot.streamEpoch
        lastOffset = snapshot.endOffset
        lastExited = snapshot.exited === true
        onEvent({ channel: 'terminal:observer-snapshot', payload: { id, ...snapshot } })
      } catch { /* reconnect/poll retries remain bounded and silent */ }
      finally { polling = false }
    }, COMPANION_SNAPSHOT_POLL_MS)
    timer.unref?.()
    return {
      ok: true,
      mode: 'snapshot',
      snapshot: initial.snapshot,
      compatibilityMode: true,
      unsubscribe: async () => {
        if (closed) return { ok: true, removed: false }
        closed = true
        clearInterval(timer)
        return { ok: true, removed: true }
      },
    }
  }
  const result = await broker().terminal('subscribe', sender, {
    id,
    projectId,
    streamEpoch,
    afterOffset,
    maxQueueBytes,
  })
  if (!result?.ok) {
    broker().unregisterOwner(sender)
    return result
  }
  let closed = false
  return {
    ...result,
    unsubscribe: async () => {
      if (closed) return { ok: true, removed: false }
      closed = true
      try { return await broker().terminal('unsubscribe', sender, { id, projectId }, { timeoutMs: 3_000 }) }
      finally { broker().unregisterOwner(sender) }
    },
  }
}

/** Normal app quit/update: close only Electron's authenticated socket. The
 * detached broker and every PTY continue, writing unseen output to disk. */
function detachSessionBroker() {
  if (metaTimer) {
    clearInterval(metaTimer)
    metaTimer = null
  }
  // terminal:run is a bounded one-shot helper rather than a user-owned PTY.
  // Never orphan its shell/process group during an app replacement.
  killRunChildren()
  return broker().disconnect()
}

module.exports = {
  registerTerminalHandlers,
  killAllSessions,
  detachSessionBroker,
  setAppFocused,
  forgetRendererOwner,
  subscribeTerminalObserver,
  companionTerminalControl,
  setTerminalAttentionSink,
  __test: { codexIdFromPath, jsonStringField, codexSession, wrappedCliProcess, companionTerminalRecord, companionTerminalSnapshot },
}
