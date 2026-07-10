// IPC for the interactive dock terminal. Backed by the shared terminalManager
// (node-pty), so a real pseudo-terminal renders its own prompt, `cd` works, and
// colors/interactive apps work. The renderer (xterm.js) forwards raw bytes.
const os = require('node:os')
const path = require('node:path')
const fs = require('node:fs/promises')
const { spawn, execFile } = require('node:child_process')
const { BrowserWindow, app } = require('electron')
const { configureSessionBroker, sessionBroker } = require('./sessionBrokerClient.cjs')

// terminal:run cap: a non-terminating command (dev server, tail -f, blocked on
// stdin) never fires 'close', so without this the invoke Promise hangs forever.
// On timeout the child is killed and the promise resolves with partial output.
const RUN_TIMEOUT_MS = 120_000
const runChildren = new Set()
let brokerClient = null

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
async function codexSession(id, cwd) {
  let terminals = []
  try { terminals = await broker().terminal('list', null, {}, { timeoutMs: 5000 }) } catch { /* semantic fallback below */ }
  const live = terminals.find((terminal) => terminal.id === id)
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
    const next = { ...prev, process: t.process }
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
    if (next.process !== prev.process || next.cwd !== prev.cwd || next.branch !== prev.branch || next.root !== prev.root) {
      metaCache.set(t.id, next)
      const payload = {
        id: t.id,
        fgProcess: next.process || null,
        running: !!next.process && !SHELLS.has(path.basename(next.process)),
        cwd: next.cwd || null,
        root: next.root || null,
        repo: next.root ? path.basename(next.root) : null,
        branch: next.branch || null,
      }
      for (const win of BrowserWindow.getAllWindows()) {
        if (!win.webContents.isDestroyed()) win.webContents.send('terminal:meta', payload)
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
  // Lazy by design: file-only work should not pay for a helper process. The
  // first terminal/CLI/ACP-terminal request adopts an existing broker or starts
  // one; closing the last session lets that helper retire again.

  ipcMain.handle('terminal:create', async (event, { id, cwd, cols, rows } = {}) => {
    const result = await broker().terminal('create', event.sender, { id, cwd: cwd || os.homedir(), cols, rows }, { timeoutMs: 20_000 })
    if (!result?.ok) return result || { ok: false, message: 'could not start terminal' }
    ensureMetaPolling()
    return { ...result, cwd: cwd || os.homedir(), shell: process.env.SHELL || '/bin/zsh' }
  })

  ipcMain.handle('terminal:write', (event, { id, data } = {}) => broker().terminal('write', event.sender, { id, data }))
  ipcMain.handle('terminal:resize', (event, { id, cols, rows } = {}) => broker().terminal('resize', event.sender, { id, cols, rows }))
  ipcMain.handle('terminal:snapshot', (event, { id } = {}) => broker().terminal('snapshot', event.sender, { id }))
  ipcMain.handle('terminal:detachRenderer', (event, { id, viewState } = {}) => broker().terminal('detachRenderer', event.sender, { id, viewState }))
  ipcMain.handle('terminal:diagnostics', () => broker().terminal('diagnostics', null))
  ipcMain.handle('terminal:codexSession', (_event, { id, cwd } = {}) => codexSession(id, cwd))
  ipcMain.handle('terminal:signal', (event, { id } = {}) => broker().terminal('signal', event.sender, { id }))
  ipcMain.handle('terminal:kill', (event, { id } = {}) => broker().terminal('release', event.sender, { id }))

  // when a renderer (re)attaches to an existing session, re-point its stream
  // (agent-spawned ptys arrive this way — make sure they're polled too)
  ipcMain.handle('terminal:attach', async (event, { id } = {}) => {
    const result = await broker().terminal('attach', event.sender, { id })
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

function detachRendererOwner(sender) {
  return broker().detachOwner(sender)
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
  detachRendererOwner,
  __test: { codexIdFromPath, jsonStringField, codexSession },
}
