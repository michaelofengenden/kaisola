// IPC for the interactive dock terminal. Backed by the shared terminalManager
// (node-pty), so a real pseudo-terminal renders its own prompt, `cd` works, and
// colors/interactive apps work. The renderer (xterm.js) forwards raw bytes.
const os = require('node:os')
const path = require('node:path')
const { spawn, execFile } = require('node:child_process')
const { BrowserWindow } = require('electron')
const mgr = require('./terminalManager.cjs')

// terminal:run cap: a non-terminating command (dev server, tail -f, blocked on
// stdin) never fires 'close', so without this the invoke Promise hangs forever.
// On timeout the child is killed and the promise resolves with partial output.
const RUN_TIMEOUT_MS = 120_000

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
  const live = mgr.list()
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
  mgr.setAppFocused(focused)
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
  ipcMain.handle('terminal:create', (event, { id, cwd, cols, rows } = {}) => {
    if (!mgr.available()) {
      return { ok: false, message: 'node-pty unavailable (run: npm run rebuild)' }
    }
    // "existed" means a LIVE session was reused — an exited pty respawns fresh
    // (spawn drops dead records), and the caller should treat that as new
    const existed = mgr.isLive(id)
    const rec = mgr.spawn({ id, cwd: cwd || os.homedir(), cols, rows, sender: event.sender })
    if (!rec) return { ok: false, message: 'could not start terminal' }
    // keep the stream pointed at the live window
    mgr.setSender(id, event.sender)
    ensureMetaPolling()
    const snap = mgr.snapshot(id)
    return { ok: true, cwd: cwd || os.homedir(), shell: process.env.SHELL || '/bin/zsh', existed, ...snap }
  })

  ipcMain.handle('terminal:write', (_e, { id, data } = {}) => ({ ok: mgr.write(id, data) }))
  ipcMain.handle('terminal:resize', (_e, { id, cols, rows } = {}) => ({ ok: mgr.resize(id, cols, rows) }))
  ipcMain.handle('terminal:snapshot', (_e, { id } = {}) => mgr.snapshot(id))
  ipcMain.handle('terminal:signal', (_e, { id } = {}) => ({ ok: mgr.write(id, '\x03') }))
  ipcMain.handle('terminal:kill', (_e, { id } = {}) => {
    mgr.release(id)
    return { ok: true }
  })

  // when a renderer (re)attaches to an existing session, re-point its stream
  // (agent-spawned ptys arrive this way — make sure they're polled too)
  ipcMain.handle('terminal:attach', (event, { id } = {}) => {
    mgr.setSender(id, event.sender)
    ensureMetaPolling()
    return mgr.snapshot(id)
  })

  // One-shot capture (used by the agent's lightweight run-command tool).
  ipcMain.handle('terminal:run', (_e, { command, cwd } = {}) => {
    return new Promise((resolve) => {
      const shell = process.env.SHELL || '/bin/zsh'
      // detached: give the shell its OWN process group so killing -pid reaps the
      // whole tree (npm → node/vite, pipeline members), not just the shell — a bare
      // child.kill would orphan grandchildren (a dev server) to launchd.
      const child = spawn(shell, ['-lc', command], { cwd: cwd || os.homedir(), env: process.env, detached: true })
      mgr.trackChild(child) // reaped on app quit instead of reparenting to launchd
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
        mgr.untrackChild(child)
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

function killAllSessions() {
  mgr.killAll()
  if (metaTimer) {
    clearInterval(metaTimer)
    metaTimer = null
  }
}

module.exports = { registerTerminalHandlers, killAllSessions, setAppFocused }
