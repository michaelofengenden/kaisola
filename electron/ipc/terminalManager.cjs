// Shared pty manager. Both the interactive dock terminal (driven by the user via
// IPC) and the agent's terminals (created over ACP when the agent runs a command)
// go through here, so an agent command is a real pty that streams LIVE into the
// dock — you watch it happen and can take over — while its output + exit status
// flow back to the agent.
const os = require('node:os')
const path = require('node:path')
const fs = require('node:fs')
const { agentEnv } = require('./shellEnv.cjs')
const { TerminalSpool, DEFAULT_HOT_CAP } = require('./terminalSpool.cjs')

let pty = null
let ptyLoadAttempted = false

/** Hardened macOS apps may load node-pty's native module from Resources, but
 * posix_spawn refuses its nested spawn-helper at that location. Copy only the
 * signed 50 KB helper into private userData and point node-pty at that stable
 * executable. The native module remains packaged and signed in the app. */
function loadPty(helperRoot) {
  if (pty || ptyLoadAttempted) return
  ptyLoadAttempted = true
  let restore = null
  try {
    if (process.platform === 'darwin' && helperRoot) {
      const packageRoot = path.dirname(require.resolve('node-pty/package.json'))
      const candidates = [
        path.join(packageRoot, 'build', 'Release', 'spawn-helper'),
        path.join(packageRoot, 'prebuilds', `${process.platform}-${process.arch}`, 'spawn-helper'),
      ]
      const source = candidates.find((file) => fs.existsSync(file))
      if (!source) throw new Error('node-pty spawn-helper is missing')
      const helperDir = path.join(helperRoot, `darwin-${process.arch}`)
      fs.mkdirSync(helperDir, { recursive: true, mode: 0o700 })
      try { fs.chmodSync(helperDir, 0o700) } catch { /* best effort */ }
      const helper = path.join(helperDir, 'spawn-helper')
      const tmp = `${helper}.${process.pid}.${Date.now()}.tmp`
      fs.copyFileSync(source, tmp)
      fs.chmodSync(tmp, 0o700)
      fs.renameSync(tmp, helper)
      fs.chmodSync(helper, 0o700)

      // unixTerminal captures `native.dir` at module evaluation. Override the
      // loader for that one require, then restore the package unchanged.
      const utils = require('node-pty/lib/utils.js')
      const original = utils.loadNativeModule
      utils.loadNativeModule = (name) => ({ ...original(name), dir: helperDir })
      restore = () => { utils.loadNativeModule = original }
    }
    pty = require('node-pty')
  } catch (err) {
    console.error('[kaisola] node-pty unavailable:', err.message)
  } finally {
    restore?.()
  }
}

const OUTPUT_CAP = DEFAULT_HOT_CAP // older scrollback is disk-backed
// Coalesce pty output into ~one IPC frame per flush window: agent TUIs emit
// hundreds of tiny chunks a second (spinner frames, cursor moves), and one
// renderer wake-up per chunk is what makes an idle-looking app burn CPU.
// 16ms ≈ one 60Hz frame — flushing faster than the display paints is waste.
// While NO app window is focused the window stretches to 100ms: output still
// flows (nothing is dropped), the machine just stops compositing an agent
// spinner at full rate for a window the user isn't working in.
const FLUSH_MS_FOCUSED = 16
const FLUSH_MS_BLURRED = 100
let flushMs = FLUSH_MS_FOCUSED
const FLUSH_CAP = 65_536 // a burst bigger than this flushes immediately
const AGENT_QUIET_MS = 4500

/** main.cjs calls this on app focus/blur — the stream profile follows. */
function setAppFocused(focused) {
  flushMs = focused ? FLUSH_MS_FOCUSED : FLUSH_MS_BLURRED
}

/** id → record */
const terms = new Map()
const releaseTimers = new Map()
let spoolDir = path.join(os.tmpdir(), `kaisola-terminal-cache-${process.pid}`)
let eventSink = null

function configureStorage(dir) {
  if (dir) {
    spoolDir = dir
    loadPty(path.join(dir, '.native'))
  } else loadPty()
}

/** A detached session broker supplies an event sink instead of Electron
 * WebContents. Keeping this injectable preserves the direct in-main probes. */
function setEventSink(sink) {
  eventSink = typeof sink === 'function' ? sink : null
}

/** terminal:run children (plain child_process, not node-pty) — tracked here so
 *  a non-terminating run command dies on app quit instead of reparenting to
 *  launchd. terminalHandler registers/unregisters each spawned child. */
const runChildren = new Set()

function terminalEnv(extra) {
  const env = agentEnv({
    ...(extra || {}),
    TERM: 'xterm-256color',
    COLORTERM: 'truecolor',
    // macOS Terminal's zsh integration prints "Restored session: ..." when
    // TERM_PROGRAM/TERM_SESSION_ID leak into a child pty. Kaisola terminals
    // should open directly at the user's normal prompt instead.
    SHELL_SESSIONS_DISABLE: '1',
    TERM_PROGRAM: 'Kaisola',
    TERM_PROGRAM_VERSION: '1',
  })
  delete env.TERM_SESSION_ID
  delete env.SHELL_SESSION_DID_INIT
  delete env.SHELL_SESSION_FILE
  delete env.SHELL_SESSION_HISTORY
  delete env.SHELL_SESSION_HISTFILE
  delete env.SHELL_SESSION_HISTFILE_NEW
  delete env.SHELL_SESSION_TIMESTAMP
  // These variables belong only to the detached helper itself. Leaking
  // ELECTRON_RUN_AS_NODE into a user's shell would make any Electron binary
  // launched from that terminal behave like plain Node; broker identity is
  // private implementation state and must not reach child commands either.
  delete env.ELECTRON_RUN_AS_NODE
  delete env.KAISOLA_SESSION_BROKER
  return env
}

function available() {
  return !!pty
}

function has(id) {
  return terms.has(id)
}

/** A record exists AND its pty hasn't exited — safe to write/reuse. */
function isLive(id) {
  const r = terms.get(id)
  return !!r && !r.exited
}

function senderId(sender) {
  if (sender == null) return ''
  if (typeof sender === 'string') return sender
  return String(sender.id ?? '')
}

function sameSender(a, b) {
  if (a === b) return true
  const aa = senderId(a)
  const bb = senderId(b)
  return !!aa && aa === bb
}

function send(sender, channel, payload) {
  if (eventSink) {
    eventSink(sender, channel, payload)
    return
  }
  if (sender && !sender.isDestroyed?.()) sender.send(channel, payload)
}

/**
 * Spawn a pty. `command`/`args` default to an interactive login shell. Streams
 * data to `sender` on terminal:data:<id> and accumulates output for snapshots
 * and ACP terminal/output. Resolves exit via waitForExit().
 */
function spawn({ id, command, args, cwd, env, outputByteLimit, cols, rows, sender }) {
  cancelRelease(id)
  if (!pty) return null
  const prior = terms.get(id)
  if (prior) {
    if (!prior.exited) return prior
    // a dead pty is not a session — drop the record and spawn fresh under the
    // same id, so a reloaded window gets a working shell instead of a corpse
    terms.delete(id)
  }
  const shell = process.env.SHELL || '/bin/zsh'
  // a persisted cwd can be GONE by now (removed worktree, deleted folder) —
  // pty.spawn throws uncaught on a missing dir; fall back to home instead
  const missingCwd = !!cwd && !fs.existsSync(cwd)
  const startCwd = missingCwd ? os.homedir() : (cwd || os.homedir())
  const retainedOutputBytes = Number.isFinite(outputByteLimit) ? Math.max(0, Math.floor(outputByteLimit)) : null
  const p = pty.spawn(command || shell, command ? args || [] : ['-l'], {
    name: 'xterm-256color',
    cols: cols || 80,
    rows: rows || 24,
    cwd: startCwd,
    env: terminalEnv(env),
  })
  const rec = {
    id,
    pty: p,
    sender,
    // Hidden renderers leave zero scrollback in RAM. The pty stays alive and
    // writes to this bounded disk spool until an xterm reattaches.
    spool: new TerminalSpool({
      dir: spoolDir,
      id,
      ...(retainedOutputBytes == null ? {} : {
        diskCap: Math.max(1, retainedOutputBytes),
        hotCap: Math.max(1, Math.min(DEFAULT_HOT_CAP, retainedOutputBytes)),
        queueCap: Math.max(1, Math.min(256 * 1024, retainedOutputBytes)),
        retentionCap: retainedOutputBytes,
      }),
    }),
    outputByteLimit: retainedOutputBytes,
    rendererVisible: true,
    pending: '', // coalesced-but-unsent output (already part of the ring)
    flushTimer: null,
    truncated: false,
    exited: false,
    exitStatus: null, // { exitCode, signal }
    waiters: [],
    // Restart continuation accounting. The hot tail remains bounded by the
    // spool; this is only metadata and a byte counter while no UI is attached.
    lastSender: sender,
    detachedAt: null,
    detachedBytes: 0,
    exitedWhileDetached: false,
    // Agent activity is deliberately broker-owned: hidden Eco tabs retain no
    // xterm/React renderer, but their turn still settles and notifies the app.
    agentBusy: false,
    agentCompletedAt: null,
    agentQuietTimer: null,
  }
  const broadcastAgentActivity = () => {
    send(rec.sender || rec.lastSender, 'terminal:agent-activity', {
      id,
      busy: rec.agentBusy,
      completedAt: rec.agentCompletedAt,
    })
  }
  const settleAgentTurn = () => {
    if (rec.agentQuietTimer) clearTimeout(rec.agentQuietTimer)
    rec.agentQuietTimer = null
    if (!rec.agentBusy) return
    rec.agentBusy = false
    rec.agentCompletedAt = Date.now()
    broadcastAgentActivity()
  }
  const armAgentQuiet = () => {
    if (!rec.agentBusy) return
    if (rec.agentQuietTimer) clearTimeout(rec.agentQuietTimer)
    rec.agentQuietTimer = setTimeout(settleAgentTurn, AGENT_QUIET_MS)
    rec.agentQuietTimer.unref?.()
  }
  rec.setAgentTurn = (busy) => {
    if (busy) {
      if (rec.agentQuietTimer) clearTimeout(rec.agentQuietTimer)
      rec.agentBusy = true
      rec.agentCompletedAt = null
      broadcastAgentActivity()
      armAgentQuiet()
    } else settleAgentTurn()
    return true
  }
  const flushPending = () => {
    if (rec.flushTimer) {
      clearTimeout(rec.flushTimer)
      rec.flushTimer = null
    }
    if (!rec.pending) return
    const chunk = rec.pending
    rec.pending = ''
    if (rec.rendererVisible) send(rec.sender, `terminal:data:${id}`, chunk)
  }
  rec.flushPending = flushPending
  p.onData((data) => {
    rec.spool.push(data)
    if (!rec.rendererVisible) rec.detachedBytes += Buffer.byteLength(data)
    if (rec.rendererVisible) {
      rec.pending += data
      if (rec.pending.length >= FLUSH_CAP) flushPending()
      else if (!rec.flushTimer) rec.flushTimer = setTimeout(flushPending, flushMs)
    }
    armAgentQuiet()
  })
  p.onExit(({ exitCode, signal }) => {
    flushPending() // the tail of the stream must land before the exit signal
    rec.exited = true
    rec.exitedWhileDetached = !rec.rendererVisible
    rec.exitStatus = { exitCode: exitCode ?? 0, signal: signal ?? null }
    settleAgentTurn()
    send(rec.sender, `terminal:exit:${id}`, rec.exitStatus.exitCode)
    rec.waiters.forEach((w) => w(rec.exitStatus))
    rec.waiters = []
  })
  terms.set(id, rec)
  if (missingCwd) {
    // NOT silent: a "worktree" agent that actually landed in $HOME must be
    // visibly flagged at the top of its terminal, never mistaken for an
    // isolated checkout. Seeded as chunks[0] so the create-reply snapshot
    // carries it — a live send here would fire before Terminal.tsx's data
    // listener is wired (Electron drops it) and never reach the renderer.
    const warn = `\r\n\x1b[33m⚠ working directory not found:\x1b[0m ${cwd}\r\n\x1b[33m  started in ${os.homedir()} instead — this session is NOT isolated.\x1b[0m\r\n\r\n`
    rec.spool.push(warn)
  }
  return rec
}

function write(id, data) {
  const r = terms.get(id)
  if (r) r.pty.write(data)
  return !!r
}

function agentTurn(id, busy) {
  const rec = terms.get(id)
  return rec?.setAgentTurn?.(!!busy) ?? false
}

function resize(id, cols, rows) {
  const r = terms.get(id)
  if (r && cols > 0 && rows > 0) {
    try {
      r.pty.resize(cols, rows)
    } catch {
      /* ignore transient races */
    }
    return true
  }
  return false
}

/** Re-bind a record's output stream to a (possibly new) renderer webContents. */
function setSender(id, sender) {
  cancelRelease(id)
  const r = terms.get(id)
  if (!r) return null
  const priorSender = r.lastSender
  const continuation = r.detachedAt
    ? {
        detachedAt: r.detachedAt,
        outputBytes: r.detachedBytes,
        exitedWhileDetached: r.exitedWhileDetached,
        previousOwner: senderId(priorSender),
        ownerChanged: !sameSender(priorSender, sender),
      }
    : null
  // drop unflushed bytes: they are already in the snapshot ring, and the
  // (re)attaching renderer replays the snapshot — flushing them too would
  // double-print
  if (r.flushTimer) {
    clearTimeout(r.flushTimer)
    r.flushTimer = null
  }
  r.pending = ''
  r.sender = sender
  r.lastSender = sender
  r.rendererVisible = true
  r.spool.setVisible(true)
  r.detachedAt = null
  r.detachedBytes = 0
  r.exitedWhileDetached = false
  return continuation
}

/** Drop only the renderer. The pty/command continues and all output moves to
 * disk. Sender identity prevents an old window cleanup racing a new pop-out. */
function detachRenderer(id, sender, viewState) {
  const r = terms.get(id)
  if (!r || (sender && r.sender && !sameSender(sender, r.sender))) return false
  if (r.flushTimer) {
    clearTimeout(r.flushTimer)
    r.flushTimer = null
  }
  r.pending = ''
  r.rendererVisible = false
  r.lastSender = r.sender || r.lastSender
  // Hiding xterm is not an ownership transfer. Keep the authenticated control
  // owner so an ACP command can still read/wait/release its PTY while its card
  // is hibernated. A destroyed renderer or disconnected Electron instance uses
  // detachSender[Prefix] below, which explicitly clears this live owner.
  if (!r.detachedAt) r.detachedAt = Date.now()
  r.spool.setVisible(false, viewState)
  return true
}

/** Main-process fallback for a renderer crash/window close where React cleanup
 * never got a chance to send terminal:detachRenderer. PTYs keep running; only
 * renderer ownership and hot scrollback move to the disk spool. */
function detachSender(sender) {
  let detached = 0
  for (const [id, r] of terms) {
    if (!r.sender || !sender || !sameSender(r.sender, sender)) continue
    const prior = r.sender
    if (detachRenderer(id, prior)) {
      r.lastSender = prior
      r.sender = null
      detached++
    }
  }
  return detached
}

/** Broker socket loss means every renderer owner from that app instance is
 * gone. Move all matching terminals to disk without stopping their PTYs. */
function detachSenderPrefix(prefix) {
  if (!prefix) return 0
  let detached = 0
  for (const [id, r] of terms) {
    if (typeof r.sender !== 'string' || !r.sender.startsWith(prefix)) continue
    const prior = r.sender
    if (detachRenderer(id, prior)) {
      r.lastSender = prior
      r.sender = null
      detached++
    }
  }
  return detached
}

function ownership(id) {
  const r = terms.get(id)
  return r
    ? { exists: true, owner: senderId(r.sender), lastOwner: senderId(r.lastSender), exited: !!r.exited }
    : { exists: false, owner: '', lastOwner: '', exited: true }
}

function snapshot(id) {
  const r = terms.get(id)
  if (!r) return { output: '', exited: true, exitStatus: null }
  return {
    ...r.spool.snapshot(r.outputByteLimit ?? OUTPUT_CAP),
    exited: r.exited,
    exitStatus: r.exitStatus,
    agentBusy: r.agentBusy,
    agentCompletedAt: r.agentCompletedAt,
  }
}

function waitForExit(id) {
  const r = terms.get(id)
  if (!r) return Promise.reject(new Error('Terminal is no longer available.'))
  if (r.exited) return Promise.resolve(r.exitStatus)
  return new Promise((resolve) => r.waiters.push(resolve))
}

function kill(id) {
  const r = terms.get(id)
  if (r) {
    try {
      r.pty.kill()
    } catch {
      /* noop */
    }
  }
  return !!r
}

function release(id) {
  cancelRelease(id)
  const r = terms.get(id)
  if (r?.flushTimer) clearTimeout(r.flushTimer)
  if (r?.agentQuietTimer) clearTimeout(r.agentQuietTimer)
  kill(id)
  r?.spool.close({ remove: true })
  terms.delete(id)
}

/** Broker-owned close grace survives renderer crashes, appearance swaps, and
 * full Electron restarts while the detached broker keeps the PTY alive. */
function scheduleRelease(id, delayMs = 60_000) {
  cancelRelease(id)
  if (!terms.has(id)) return false
  const timer = setTimeout(() => {
    releaseTimers.delete(id)
    release(id)
  }, Math.max(1_000, Math.min(Number(delayMs) || 60_000, 5 * 60_000)))
  timer.unref?.()
  releaseTimers.set(id, timer)
  return true
}

function cancelRelease(id) {
  const timer = releaseTimers.get(id)
  if (!timer) return false
  clearTimeout(timer)
  releaseTimers.delete(id)
  return true
}

/** Track a terminal:run child so killAll() reaps it on quit; it auto-drops
 *  itself when the child exits, so the set never accumulates corpses. */
function trackChild(child) {
  runChildren.add(child)
  const drop = () => runChildren.delete(child)
  child.once('exit', drop)
  child.once('error', drop)
  return child
}

function untrackChild(child) {
  runChildren.delete(child)
}

function killAll() {
  for (const timer of releaseTimers.values()) clearTimeout(timer)
  releaseTimers.clear()
  for (const r of terms.values()) {
    if (r.flushTimer) clearTimeout(r.flushTimer)
    if (r.agentQuietTimer) clearTimeout(r.agentQuietTimer)
    try {
      r.pty.kill()
    } catch {
      /* noop */
    }
    // App quit is not a user close: retain the spool so persisted terminal
    // records can restore their previous scrollback on next launch.
    r.spool.close()
  }
  terms.clear()
  // terminal:run children are plain child_process, not ptys — reap them too, or
  // a non-terminating run command (dev server, tail -f) reparents to launchd
  // and outlives the app.
  for (const child of runChildren) {
    // -pid: the run-child is spawned detached (its own group), so a negative pid
    // SIGKILLs the shell AND its grandchildren (dev server / pipeline members);
    // fall back to the bare child if the group is already gone.
    try {
      process.kill(-child.pid, 'SIGKILL')
    } catch {
      try { child.kill('SIGKILL') } catch { /* noop */ }
    }
  }
  runChildren.clear()
}

/** Live sessions with their pid + FOREGROUND process name (node-pty reads the
 *  active process on the pty, e.g. 'zsh' idle vs 'node'/'python' running). */
function list() {
  const out = []
  for (const r of terms.values()) {
    if (r.exited) continue
    let proc = ''
    try {
      proc = r.pty.process || ''
    } catch { /* pty backend may refuse mid-teardown */ }
    out.push({ id: r.id, pid: r.pty.pid, process: proc, owner: senderId(r.sender), lastOwner: senderId(r.lastSender), agentBusy: r.agentBusy, agentCompletedAt: r.agentCompletedAt })
  }
  return out
}

function diagnostics() {
  return [...terms.values()].map((r) => ({
    ...r.spool.stats(),
    pid: r.pty && r.pty.pid,
    exited: r.exited,
    owner: senderId(r.sender),
    lastOwner: senderId(r.lastSender),
    detachedAt: r.detachedAt,
    detachedBytes: r.detachedBytes,
  }))
}

module.exports = { available, has, isLive, ownership, spawn, write, agentTurn, resize, setSender, detachRenderer, detachSender, detachSenderPrefix, snapshot, waitForExit, kill, release, scheduleRelease, cancelRelease, trackChild, untrackChild, killAll, list, setAppFocused, configureStorage, setEventSink, diagnostics }
