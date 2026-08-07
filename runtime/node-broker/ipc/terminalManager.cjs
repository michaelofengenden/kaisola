// Shared pty manager. Both the interactive dock terminal (driven by the user via
// IPC) and the agent's terminals (created over ACP when the agent runs a command)
// go through here, so an agent command is a real pty that streams LIVE into the
// dock — you watch it happen and can take over — while its output + exit status
// flow back to the agent.
const os = require('node:os')
const path = require('node:path')
const fs = require('node:fs')
const crypto = require('node:crypto')
const { execFile, execFileSync } = require('node:child_process')
const { agentEnv } = require('./shellEnv.cjs')
const { TerminalSpool, DEFAULT_HOT_CAP, DEFAULT_SNAPSHOT_CAP } = require('./terminalSpool.cjs')
const { TerminalObservers } = require('./terminalObservers.cjs')
const { TerminalCursor, isUtf8Boundary } = require('../companion/terminalCursor.cjs')

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
// Reattach window. Independent of OUTPUT_CAP on purpose — see
// DEFAULT_SNAPSHOT_CAP in terminalSpool.cjs. Note this must NOT be routed
// through a terminal's `outputByteLimit`: that field also shrinks the disk cap
// and sets the retention cap, so raising it would *reduce* durable history.
const SNAPSHOT_CAP = DEFAULT_SNAPSHOT_CAP
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
const OBSERVER_CHUNK_BYTES = 64 * 1024
const AGENT_QUIET_MS = 4500
const CWD_REFRESH_COALESCE_MS = 250

/** main.cjs calls this on app focus/blur — the stream profile follows. */
function setAppFocused(focused) {
  flushMs = focused ? FLUSH_MS_FOCUSED : FLUSH_MS_BLURRED
}

/** id → record */
const terms = new Map()
const releaseTimers = new Map()
let shuttingDown = false
let spoolDir = path.join(os.tmpdir(), `kaisola-terminal-cache-${process.pid}`)
let eventSink = null
let activitySink = null
let lastCwdRefreshAt = 0

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

/** The detached broker owns the rolling-update activity epoch. Terminal output
 * and broker-internal state changes can occur without a new socket request, so
 * the manager reports them explicitly instead of letting UI quietness stand in
 * for process truth. */
function setActivitySink(sink) {
  activitySink = typeof sink === 'function' ? sink : null
}

function reportActivity(kind, id = null) {
  try { activitySink?.(String(kind || 'terminal'), id == null ? null : String(id)) } catch { /* safety telemetry only */ }
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
    // zsh otherwise paints an inverse-video "%" when a fresh PTY redraws
    // after its first resize. Native Terminal hides that implementation
    // marker; keeping it empty gives new Kaisola shells the same clean start.
    PROMPT_EOL_MARK: '',
  })
  // A GUI terminal is a fresh user shell, not a child task of whichever CLI
  // happened to launch/reinstall Kaisola. Codex sets these variables on its
  // own process (notably NO_COLOR=1); inheriting them made Claude/Codex inside
  // Kaisola suppress their native ANSI UI and could make a nested Codex think
  // it was still managed by the outer installation. Terminal.app does not
  // propagate that private invocation state into a new window.
  for (const key of [
    'NO_COLOR',
    'FORCE_COLOR',
    'CODEX_CI',
    'CODEX_MANAGED_BY_NPM',
    'CODEX_MANAGED_PACKAGE_ROOT',
    'CODEX_THREAD_ID',
  ]) delete env[key]
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

function send(sender, channel, payload, options) {
  if (eventSink) {
    return eventSink(sender, channel, payload, options) !== false
  }
  if (sender && !sender.isDestroyed?.()) {
    sender.send(channel, payload)
    return true
  }
  return false
}

/** Split a pty callback into bounded frames without cutting a UTF-8 codepoint. */
function splitUtf8(value, maxBytes = OBSERVER_CHUNK_BYTES) {
  const cap = Math.max(4, Math.floor(Number(maxBytes) || OBSERVER_CHUNK_BYTES))
  const buffer = Buffer.from(String(value ?? ''), 'utf8')
  const chunks = []
  for (let start = 0; start < buffer.length;) {
    let end = Math.min(buffer.length, start + cap)
    while (end < buffer.length && end > start && !isUtf8Boundary(buffer, end)) end--
    if (end === start) {
      end = Math.min(buffer.length, start + cap)
      while (end < buffer.length && !isUtf8Boundary(buffer, end)) end++
    }
    chunks.push(buffer.subarray(start, end).toString('utf8'))
    start = end
  }
  return chunks
}

/** Parse macOS `lsof -Fn` process/name records for `-d cwd`. Process markers
 * scope the following name field; malformed blocks are ignored. */
function parseLsofCwd(output) {
  const cwdByPid = new Map()
  let currentPid = null
  for (const line of String(output ?? '').split(/\r?\n/)) {
    if (line.startsWith('p')) {
      const pid = Number(line.slice(1))
      // A malformed p-line (e.g. a path fragment from a cwd containing an
      // embedded newline) drops tracking until the next valid p-line: the
      // stray n-fragments that follow it must not be misattributed to the
      // previous pid, and real output always re-anchors on the next record.
      currentPid = Number.isSafeInteger(pid) && pid > 0 ? pid : null
    } else if (line.startsWith('n') && currentPid != null) {
      const cwd = line.slice(1)
      if (path.isAbsolute(cwd)) cwdByPid.set(currentPid, cwd)
    }
  }
  return cwdByPid
}

/** Refresh live records through one lsof process. Failure is deliberately
 * non-destructive: every record keeps its last known cwd. */
function refreshTerminalCwds(records, run = execFileSync) {
  const live = [...records].filter((record) => !record.exited)
  const pids = [...new Set(live
    .map((record) => Number(record.pty?.pid))
    .filter((pid) => Number.isSafeInteger(pid) && pid > 0))]
    .sort((a, b) => a - b)
  if (!pids.length) return true

  let output
  try {
    output = run('/usr/sbin/lsof', ['-a', '-p', pids.join(','), '-d', 'cwd', '-Fn'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 1_500,
      maxBuffer: 1024 * 1024,
    })
  } catch {
    return false
  }
  const cwdByPid = parseLsofCwd(output)
  for (const record of live) {
    const cwd = cwdByPid.get(Number(record.pty?.pid))
    if (cwd) record.cwd = cwd
  }
  return true
}

function refreshCwds({ force = false, now = Date.now, run = execFileSync } = {}) {
  const refreshedAt = Number(now())
  if (!force
    && lastCwdRefreshAt > 0
    && refreshedAt >= lastCwdRefreshAt
    && refreshedAt - lastCwdRefreshAt < CWD_REFRESH_COALESCE_MS) return true
  lastCwdRefreshAt = refreshedAt
  // Only the forced path (shutdown flush, tests) runs lsof synchronously.
  // The periodic path — the app's ~2.5s inventory heartbeat — must never
  // block the event loop: a slow lsof under load froze every terminal's
  // write/output for up to 1.5s per tick. Callers get the last known cwd
  // immediately; the refresh lands in the background.
  if (force || run !== execFileSync) return refreshTerminalCwds(terms.values(), run)
  if (cwdRefreshInFlight) return true
  cwdRefreshInFlight = true
  refreshTerminalCwdsAsync(terms.values()).finally(() => {
    cwdRefreshInFlight = false
  })
  return true
}

let cwdRefreshInFlight = false

/** The non-blocking twin of `refreshTerminalCwds`: same lsof invocation and
 * parse, run through the async `execFile` so a stalled lsof never stalls the
 * broker. Failure is equally non-destructive. */
function refreshTerminalCwdsAsync(records) {
  const live = [...records].filter((record) => !record.exited)
  const pids = [...new Set(live
    .map((record) => Number(record.pty?.pid))
    .filter((pid) => Number.isSafeInteger(pid) && pid > 0))]
    .sort((a, b) => a - b)
  if (!pids.length) return Promise.resolve(true)
  return new Promise((resolve) => {
    execFile('/usr/sbin/lsof', ['-a', '-p', pids.join(','), '-d', 'cwd', '-Fn'], {
      encoding: 'utf8',
      timeout: 1_500,
      maxBuffer: 1024 * 1024,
    }, (error, stdout) => {
      if (error && !stdout) { resolve(false); return }
      const cwdByPid = parseLsofCwd(stdout)
      for (const record of live) {
        const cwd = cwdByPid.get(Number(record.pty?.pid))
        if (cwd) record.cwd = cwd
      }
      resolve(true)
    })
  })
}

/**
 * Spawn a pty. `command`/`args` default to an interactive login shell. Streams
 * data to `sender` on terminal:data:<id> and accumulates output for snapshots
 * and ACP terminal/output. Resolves exit via waitForExit().
 */
function spawn({ id, command, args, cwd, env, outputByteLimit, cols, rows, sender, restore = false }) {
  cancelRelease(id)
  const restoring = restore === true
  const prior = terms.get(id)
  if (prior) {
    if (!prior.exited) return prior
    if (restoring && !prior.pty) return prior
    // a dead pty is not a session — drop the record and spawn fresh under the
    // same id, so a reloaded window gets a working shell instead of a corpse
    prior.spool.close({ remove: !restoring })
    terms.delete(id)
  }
  const retainedOutputBytes = Number.isFinite(outputByteLimit) ? Math.max(0, Math.floor(outputByteLimit)) : null
  const initialCols = cols || 80
  const initialRows = rows || 24
  const spoolOptions = {
    dir: spoolDir,
    id,
    fresh: !restoring,
    ...(retainedOutputBytes == null ? {} : {
      diskCap: Math.max(1, retainedOutputBytes),
      hotCap: Math.max(1, Math.min(DEFAULT_HOT_CAP, retainedOutputBytes)),
      queueCap: Math.max(1, Math.min(256 * 1024, retainedOutputBytes)),
      retentionCap: retainedOutputBytes,
    }),
  }
  const retainedMeta = restoring ? TerminalSpool.readMeta(id, spoolDir) : null
  if (retainedMeta && Number.isSafeInteger(retainedMeta.exitedAt) && retainedMeta.exitedAt >= 0) {
    const terminalSpool = new TerminalSpool(spoolOptions)
    const epochStartOffset = terminalSpool.retainedByteCount()
    terminalSpool.startEpoch(epochStartOffset)
    const cursor = new TerminalCursor({ streamEpoch: crypto.randomUUID(), startOffset: epochStartOffset })
    const rec = {
      id,
      pty: null,
      cols: initialCols,
      rows: initialRows,
      cwd: cwd || os.homedir(),
      sender,
      spool: terminalSpool,
      outputByteLimit: retainedOutputBytes,
      cursor,
      observers: null,
      rendererVisible: true,
      pending: '',
      flushTimer: null,
      truncated: false,
      exited: true,
      exitStatus: retainedMeta.exitStatus ?? null,
      waiters: [],
      lastSender: sender,
      detachedAt: null,
      detachedBytes: 0,
      exitedWhileDetached: false,
      agentBusy: false,
      agentCompletedAt: null,
      agentRespondedAt: null,
      agentQuietTimer: null,
    }
    rec.observers = new TerminalObservers({
      terminalId: id,
      deliver: (subscriber, channel, payload, options) => send(subscriber, channel, payload, options),
    })
    terms.set(id, rec)
    return rec
  }
  if (!pty) return null
  const shell = process.env.SHELL || '/bin/zsh'
  // a persisted cwd can be GONE by now (removed worktree, deleted folder) —
  // pty.spawn throws uncaught on a missing dir; fall back to home instead
  const missingCwd = !!cwd && !fs.existsSync(cwd)
  const startCwd = missingCwd ? os.homedir() : (cwd || os.homedir())
  const p = pty.spawn(command || shell, command ? args || [] : ['-l'], {
    name: 'xterm-256color',
    cols: initialCols,
    rows: initialRows,
    cwd: startCwd,
    env: terminalEnv(env),
  })
  const terminalSpool = new TerminalSpool(spoolOptions)
  const epochStartOffset = restoring ? terminalSpool.retainedByteCount() : 0
  terminalSpool.startEpoch(epochStartOffset)
  const streamEpoch = crypto.randomUUID()
  const cursor = new TerminalCursor({ streamEpoch, startOffset: epochStartOffset })
  const rec = {
    id,
    pty: p,
    cols: initialCols,
    rows: initialRows,
    cwd: startCwd,
    sender,
    // Hidden renderers leave zero scrollback in RAM. The pty stays alive and
    // writes to this bounded disk spool until an xterm reattaches.
    spool: terminalSpool,
    outputByteLimit: retainedOutputBytes,
    cursor,
    observers: null,
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
    agentRespondedAt: null,
    agentQuietTimer: null,
  }
  rec.observers = new TerminalObservers({
    terminalId: id,
    deliver: (subscriber, channel, payload, options) => send(subscriber, channel, payload, options),
  })
  const broadcastAgentActivity = () => {
    send(rec.sender || rec.lastSender, 'terminal:agent-activity', {
      id,
      busy: rec.agentBusy,
      completedAt: rec.agentCompletedAt,
    })
    rec.observers.broadcast('terminal:observer-activity', {
      id,
      streamEpoch: rec.cursor.streamEpoch,
      offset: rec.cursor.nextOffset,
      busy: rec.agentBusy,
      completedAt: rec.agentCompletedAt,
    }, { streamEpoch: rec.cursor.streamEpoch, endOffset: rec.cursor.nextOffset })
  }
  const settleAgentTurn = () => {
    if (rec.agentQuietTimer) clearTimeout(rec.agentQuietTimer)
    rec.agentQuietTimer = null
    if (!rec.agentBusy) return
    rec.agentBusy = false
    rec.agentCompletedAt = Date.now()
    reportActivity('agent-settled', id)
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
      reportActivity('agent-busy', id)
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
    reportActivity('terminal-output', id)
    rec.spool.push(data)
    if (rec.agentBusy) {
      const responseAt = Date.now()
      if (!rec.agentRespondedAt || responseAt - rec.agentRespondedAt >= 1_000) {
        rec.agentRespondedAt = responseAt
      }
    }
    for (const piece of splitUtf8(data)) {
      const chunk = rec.cursor.append(piece)
      rec.observers.broadcast('terminal:observer-output', { id, ...chunk }, {
        streamEpoch: rec.cursor.streamEpoch,
        endOffset: chunk.endOffset,
      })
    }
    if (!rec.rendererVisible) rec.detachedBytes += Buffer.byteLength(data)
    if (rec.rendererVisible) {
      rec.pending += data
      if (rec.pending.length >= FLUSH_CAP) flushPending()
      else if (!rec.flushTimer) rec.flushTimer = setTimeout(flushPending, flushMs)
    }
    armAgentQuiet()
  })
  p.onExit(({ exitCode, signal }) => {
    reportActivity('terminal-exit', id)
    flushPending() // the tail of the stream must land before the exit signal
    rec.exited = true
    rec.exitedWhileDetached = !rec.rendererVisible
    rec.exitStatus = { exitCode: exitCode ?? 0, signal: signal ?? null }
    if (!shuttingDown) rec.spool.markExited(rec.exitStatus)
    settleAgentTurn()
    send(rec.sender, `terminal:exit:${id}`, rec.exitStatus.exitCode)
    rec.observers.broadcast('terminal:observer-exit', {
      id,
      streamEpoch: rec.cursor.streamEpoch,
      offset: rec.cursor.nextOffset,
      exitStatus: rec.exitStatus,
    }, { streamEpoch: rec.cursor.streamEpoch, endOffset: rec.cursor.nextOffset })
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
    rec.cursor.append(warn)
  }
  return rec
}

function write(id, data) {
  const r = terms.get(id)
  if (!r) return { ok: false }
  if (r.exited || !r.pty) return { ok: false, message: 'terminal already ended' }
  r.pty.write(data)
  return { ok: true }
}

function agentTurn(id, busy) {
  const rec = terms.get(id)
  return rec?.setAgentTurn?.(!!busy) ?? false
}

function resizeRecord(record, cols, rows) {
  if (!record || !Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0) {
    return false
  }
  try {
    record.pty.resize(cols, rows)
  } catch {
    // The controller must not cache a geometry the PTY never accepted. A later
    // level-triggered desktop synchronization can safely retry the same size.
    return false
  }
  record.cols = cols
  record.rows = rows
  return true
}

function resize(id, cols, rows) {
  const record = terms.get(id)
  if (record?.exited || (record && !record.pty)) return { ok: false, message: 'terminal already ended' }
  return { ok: resizeRecord(record, cols, rows) }
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
  if (!r) return { output: '', startOffset: 0, endOffset: 0, streamEpoch: null, truncated: false, exited: true, exitStatus: null }
  const retained = r.spool.snapshot(r.outputByteLimit ?? SNAPSHOT_CAP)
  const outputBytes = Buffer.byteLength(retained.output, 'utf8')
  return {
    ...retained,
    streamEpoch: r.cursor.streamEpoch,
    startOffset: Math.max(0, r.cursor.nextOffset - outputBytes),
    endOffset: r.cursor.nextOffset,
    exited: r.exited,
    exitStatus: r.exitStatus,
    agentBusy: r.agentBusy,
    agentCompletedAt: r.agentCompletedAt,
    agentRespondedAt: r.agentRespondedAt,
  }
}

/** Read one older, observer-safe history page without mutating terminal state. */
function history(id, { streamEpoch, beforeOffset, maxBytes } = {}) {
  const r = terms.get(id)
  if (!r) return { ok: false, message: 'Terminal is no longer available.' }
  if (streamEpoch !== r.cursor.streamEpoch) throw new Error('terminal history epoch mismatch')
  if (!Number.isSafeInteger(beforeOffset) || beforeOffset < 0 || beforeOffset > r.cursor.nextOffset) {
    throw new Error('invalid terminal history offset')
  }
  const cap = Math.min(4 * 1024 * 1024, Math.max(64 * 1024, Math.floor(Number(maxBytes) || DEFAULT_SNAPSHOT_CAP)))
  const page = r.spool.historyPage(r.cursor.nextOffset - beforeOffset, cap)
  const retainedStart = Math.max(0, r.cursor.nextOffset - page.totalBytes)
  const startOffset = retainedStart + page.startByte
  const endOffset = retainedStart + page.endByte
  return {
    ok: true,
    streamEpoch: r.cursor.streamEpoch,
    output: page.output,
    startOffset,
    endOffset,
    hasMore: page.hasMore,
    truncated: page.truncated,
  }
}

function resumeFromSnapshot(current, streamEpoch, afterOffset) {
  if (streamEpoch == null && afterOffset == null) return { mode: 'snapshot', snapshot: current }
  if (typeof streamEpoch !== 'string' || !streamEpoch || !Number.isSafeInteger(afterOffset) || afterOffset < 0) {
    throw new Error('invalid terminal observer cursor')
  }
  if (streamEpoch !== current.streamEpoch) return { mode: 'snapshot', resetReason: 'epoch_mismatch', snapshot: current }
  if (afterOffset > current.endOffset) return { mode: 'snapshot', resetReason: 'cursor_ahead', snapshot: current }
  if (afterOffset < current.startOffset) return { mode: 'snapshot', resetReason: 'event_gap', snapshot: current }
  if (afterOffset === current.endOffset) {
    return { mode: 'current', cursor: { streamEpoch: current.streamEpoch, offset: current.endOffset } }
  }
  const output = Buffer.from(current.output, 'utf8')
  const relative = afterOffset - current.startOffset
  if (!isUtf8Boundary(output, relative)) {
    return { mode: 'snapshot', resetReason: 'invalid_utf8_boundary', snapshot: current }
  }
  return {
    mode: 'snapshot',
    snapshot: {
      ...current,
      output: output.subarray(relative).toString('utf8'),
      startOffset: afterOffset,
      truncated: current.truncated || afterOffset > 0,
    },
  }
}

function subscribe(id, subscriber, { streamEpoch, afterOffset, maxQueueBytes } = {}) {
  const r = terms.get(id)
  if (!r) return { ok: false, message: 'Terminal is no longer available.' }
  r.observers.subscribe(subscriber, { maxQueueBytes })
  try {
    return { ok: true, ...resumeFromSnapshot(snapshot(id), streamEpoch, afterOffset) }
  } catch (error) {
    r.observers.unsubscribe(subscriber)
    throw error
  }
}

function unsubscribe(id, subscriber) {
  return terms.get(id)?.observers.unsubscribe(subscriber) ?? false
}

function unsubscribeSubscriberPrefix(prefix) {
  let removed = 0
  for (const r of terms.values()) removed += r.observers.unsubscribePrefix(prefix)
  return removed
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
    reportActivity('scheduled-release', id)
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
  reportActivity('child-started')
  const drop = () => {
    if (runChildren.delete(child)) reportActivity('child-ended')
  }
  child.once('exit', drop)
  child.once('error', drop)
  return child
}

function untrackChild(child) {
  if (runChildren.delete(child)) reportActivity('child-ended')
}

/**
 * Broker-authoritative update gate. UI visibility, cached inventory, and a
 * quiet timer are never treated as permission to replace the process: every
 * live PTY, every explicit agent turn, and every tracked non-PTY child must be
 * absent in this single event-loop snapshot.
 */
function summarizeUpgradeReadiness(records, childCount) {
  const liveTerminalIds = []
  const busyTerminalIds = []
  for (const record of records) {
    if (!record.exited) liveTerminalIds.push(String(record.id))
    if (record.agentBusy) busyTerminalIds.push(String(record.id))
  }
  liveTerminalIds.sort()
  busyTerminalIds.sort()
  const runningChildCount = Math.max(0, Number(childCount) || 0)
  return {
    safe: liveTerminalIds.length === 0 && busyTerminalIds.length === 0 && runningChildCount === 0,
    liveTerminalCount: liveTerminalIds.length,
    liveTerminalIds,
    busyAgentCount: busyTerminalIds.length,
    busyTerminalIds,
    childTaskCount: runningChildCount,
  }
}

function upgradeReadiness() {
  return summarizeUpgradeReadiness(terms.values(), runChildren.size)
}

/** Rolling cutover preserves live PTYs and tracked child processes in this
 * process. Only an explicitly working CLI agent blocks the stability window;
 * socket-request and lease races are fenced by the broker's activity epoch. */
function rollingUpdateReadiness() {
  const summary = summarizeUpgradeReadiness(terms.values(), runChildren.size)
  return { ...summary, safe: summary.busyAgentCount === 0 }
}

function killAll() {
  shuttingDown = true
  // Capture one last shell cwd while every pid is still live. Missing/erroring
  // lsof is non-fatal and leaves the last inventory value intact.
  refreshCwds({ force: true })
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
  refreshCwds()
  const out = []
  for (const r of terms.values()) {
    if (r.exited) continue
    let proc = ''
    try {
      proc = r.pty.process || ''
    } catch { /* pty backend may refuse mid-teardown */ }
    out.push({ id: r.id, pid: r.pty.pid, process: proc, cwd: r.cwd, cols: r.cols, rows: r.rows, owner: senderId(r.sender), lastOwner: senderId(r.lastSender), agentBusy: r.agentBusy, agentCompletedAt: r.agentCompletedAt, agentRespondedAt: r.agentRespondedAt })
  }
  return out
}

function diagnostics() {
  refreshCwds()
  return [...terms.values()].map((r) => ({
    ...r.spool.stats(),
    pid: r.pty && r.pty.pid,
    cwd: r.cwd,
    cols: r.cols,
    rows: r.rows,
    exited: r.exited,
    owner: senderId(r.sender),
    lastOwner: senderId(r.lastSender),
    detachedAt: r.detachedAt,
    detachedBytes: r.detachedBytes,
    streamEpoch: r.cursor.streamEpoch,
    endOffset: r.cursor.nextOffset,
    observerCount: r.observers.stats().subscribers,
    pausedObserverCount: r.observers.stats().paused,
  }))
}

module.exports = { available, has, isLive, ownership, spawn, write, agentTurn, resize, setSender, detachRenderer, detachSender, detachSenderPrefix, snapshot, history, subscribe, unsubscribe, unsubscribeSubscriberPrefix, waitForExit, kill, release, scheduleRelease, cancelRelease, trackChild, untrackChild, upgradeReadiness, rollingUpdateReadiness, killAll, list, setAppFocused, configureStorage, setEventSink, setActivitySink, diagnostics, __test: { resizeRecord, resumeFromSnapshot, splitUtf8, terminalEnv, summarizeUpgradeReadiness, parseLsofCwd, refreshTerminalCwds } }
