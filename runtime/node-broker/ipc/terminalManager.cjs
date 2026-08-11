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
const { DEFAULT_OBSERVER_QUEUE_BYTES, TerminalObservers } = require('./terminalObservers.cjs')
const { TerminalCursor, isUtf8Boundary } = require('../companion/terminalCursor.cjs')
const { validatedTerminalGeometry } = require('./terminalCreateRoute.cjs')
const {
  DEFAULT_MAX_LIVE_TERMINALS,
  MAX_CONFIGURABLE_LIVE_TERMINALS,
  TERMINAL_HISTORY_PAGE_BYTES,
  TERMINAL_WRITE_PAYLOAD_BYTES,
} = require('./brokerWire.cjs')

// One terminal.write is deliberately much smaller than the broker's framing
// ceiling. Large paste is split by the controller so the broker event loop and
// node-pty queue never have to absorb one unbounded mutation.
const MAX_TERMINAL_WRITE_BYTES = TERMINAL_WRITE_PAYLOAD_BYTES

let pty = null
let ptyLoadAttempted = false

const HELPER_MODE = 0o700
const HELPER_TEMP_FLAGS = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL

/** lstat, never stat: a symlink has to be visible AS a symlink here. Whoever
 * controls a component of the helper path controls the executable node-pty
 * hands to posix_spawn, so a link, a non-directory or another account's inode
 * on that path is refused rather than followed. */
function assertRealDirectory(dir, { mustOwn = true } = {}) {
  const stat = fs.lstatSync(dir)
  if (stat.isSymbolicLink()) throw new Error(`helper path component is a symlink: ${dir}`)
  if (!stat.isDirectory()) throw new Error(`helper path component is not a directory: ${dir}`)
  const ours = stat.uid === process.getuid()
  if (!ours && (mustOwn || stat.uid !== 0)) throw new Error(`helper path component is foreign-owned: ${dir}`)
  return stat
}

/** Writable by group or other is tolerable only with the sticky bit (/tmp,
 * /var/folders): there just the owner may replace an entry, and the component
 * below it still has to pass the ownership check. */
function assertNotOtherWritable(dir, stat) {
  if ((stat.mode & 0o022) !== 0 && (stat.mode & 0o1000) === 0) {
    throw new Error(`helper path component is writable by other users: ${dir}`)
  }
}

/** Create one level of the private helper path. Plain mkdir (unlike the
 * recursive form) fails with EEXIST on a pre-existing symlink instead of
 * following it, so create-then-verify leaves an attacker no entry to redirect.
 * A directory an earlier, looser build left behind is ours to tighten back to
 * 0700; the repair is then re-checked instead of assumed. */
function createPrivateDir(dir) {
  try {
    fs.mkdirSync(dir, { mode: HELPER_MODE })
  } catch (err) {
    if (err.code !== 'EEXIST') throw err
  }
  if ((assertRealDirectory(dir).mode & 0o077) !== 0) fs.chmodSync(dir, HELPER_MODE)
  if ((assertRealDirectory(dir).mode & 0o077) !== 0) throw new Error(`helper path component stayed group- or world-accessible: ${dir}`)
  return dir
}

/** Resolve and validate the private directory the signed helper is copied into.
 * Everything above `root` is canonicalized first — macOS reaches real storage
 * through the /var and /tmp symlinks, so a blanket link rejection would refuse
 * every default path — and each canonical component is then checked for owner
 * and mode, which is what a hostile ancestor link would fail anyway once it
 * lands in the attacker's own directory. `root` and the arch directory below it
 * are ours to create, so there a link is rejected outright. */
function prepareHelperDir(root, arch) {
  const resolved = path.resolve(root)
  const parent = path.dirname(resolved)
  fs.mkdirSync(parent, { recursive: true, mode: HELPER_MODE })
  const canonicalParent = fs.realpathSync(parent)
  let walked = path.sep
  for (const part of canonicalParent.split(path.sep).filter(Boolean)) {
    walked = path.join(walked, part)
    assertNotOtherWritable(walked, assertRealDirectory(walked, { mustOwn: false }))
  }
  const base = createPrivateDir(path.join(canonicalParent, path.basename(resolved)))
  return createPrivateDir(path.join(base, `darwin-${arch}`))
}

/** Write the helper through an unpredictable, exclusively created temp file and
 * rename it into place. O_EXCL refuses an existing entry, so a pre-planted
 * symlink at the temp path cannot be written through the way copyFileSync would
 * have, and the rename replaces a tampered helper atomically instead of
 * following it. */
function installSpawnHelper(source, helperDir) {
  const helper = path.join(helperDir, 'spawn-helper')
  const tmp = path.join(helperDir, `spawn-helper.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`)
  const fd = fs.openSync(tmp, HELPER_TEMP_FLAGS, HELPER_MODE)
  try {
    try {
      fs.writeFileSync(fd, fs.readFileSync(source))
      fs.fchmodSync(fd, HELPER_MODE)
    } finally {
      fs.closeSync(fd)
    }
    fs.renameSync(tmp, helper)
  } catch (err) {
    try { fs.unlinkSync(tmp) } catch { /* nothing left to clean up */ }
    throw err
  }
  return helper
}

/** The packaged helper must be a plain file: the packager already refuses to
 * ship a symlink, so one here means the bundle was rewritten after signing. */
function isRegularFile(file) {
  try { return fs.lstatSync(file).isFile() } catch { return false }
}

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
      const source = candidates.find(isRegularFile)
      if (!source) throw new Error('node-pty spawn-helper is missing')
      const helperDir = prepareHelperDir(helperRoot, process.arch)
      installSpawnHelper(source, helperDir)

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
// The observer stream is broadcast straight out of the pty callback, once per
// splitUtf8 piece, so an agent TUI redrawing a spinner produced hundreds of
// frames a second — each one a JSON encode, a socket write, and a full decode
// plus two actor hops on the far side. This is the same 16 ms window the
// primary path always had.
//
// Deliberately not split into focused/blurred like FLUSH_MS_*. Observer sockets
// are not all the desktop app: Companion subscribes too, and a broker-side
// blurred delay would slow the phone's output whenever the Mac lost focus,
// which is exactly when someone is driving the terminal from their phone.
const OBSERVER_FLUSH_MS = 16
// Never accumulate past what one piece could already produce. splitUtf8 caps a
// piece at OBSERVER_CHUNK_BYTES, and JSON escaping of control-dense output
// expands that severalfold, so a single piece can already approach a small
// subscriber's queue budget (configurable down to 64 KiB in terminalObservers).
// Coalescing must not make the worst-case frame any larger than it is today.
const OBSERVER_BATCH_CAP = OBSERVER_CHUNK_BYTES
const AGENT_QUIET_MS = 4500
const CWD_REFRESH_COALESCE_MS = 250
// An exit wait lives as long as the pty it watches, which for a dev server is
// hours. Every waiter therefore carries the owner key that asked for it, so a
// dropped socket can drop its closures, and one terminal holds at most this
// many: a reconnect-looping or abusive client must not be able to pin an
// unbounded list of resolvers to a long-running terminal.
const MAX_EXIT_WAITERS = 32
// A caller may bound its own wait; this clamps that bound, because setTimeout
// fires IMMEDIATELY past 2^31-1 ms and a wild timeoutMs would then read as an
// instant timeout. Unbounded stays the default: a wait is how the agent learns
// a command finished, and cutting it short would report a false non-exit.
const MAX_EXIT_WAIT_MS = 6 * 60 * 60 * 1_000
// A normal node-pty kill reports exit promptly, so release can preserve its
// historic awaitable-success contract. A backend that accepted the signal but
// never confirms exit must not hold an RPC forever or erase recovery evidence.
const RELEASE_CONFIRM_MS = 2_000
// A single detached broker serves every open project, so PTYs need a broker-
// wide ceiling in addition to per-terminal byte and waiter limits. The launch
// request may lower or raise the production default, but never remove the
// ceiling or turn one typo into an effectively unbounded process inventory.

/** main.cjs calls this on app focus/blur — the stream profile follows. */
function setAppFocused(focused) {
  flushMs = focused ? FLUSH_MS_FOCUSED : FLUSH_MS_BLURRED
}

/** id → record */
const terms = new Map()
const releaseTimers = new Map()
let shuttingDown = false
let spoolDir = path.join(os.tmpdir(), `kaisola-terminal-cache-${process.pid}`)
let asyncSpoolWrites = true
let eventSink = null
let activitySink = null
// Answers "does this owner's connection still want terminal:data:<id>?". Unset
// means yes, so a host that never installs a policy — every existing test, and
// any embedder that does not negotiate — keeps the primary stream.
let primaryStreamPolicy = null
let lastCwdRefreshAt = 0
let maximumLiveTerminals = DEFAULT_MAX_LIVE_TERMINALS

class TerminalCapacityError extends Error {
  constructor({ liveTerminalCount, maximumLiveTerminals }) {
    super('broker terminal capacity reached')
    this.name = 'TerminalCapacityError'
    this.code = 'TERMINAL_CAPACITY_EXCEEDED'
    this.liveTerminalCount = liveTerminalCount
    this.maximumLiveTerminals = maximumLiveTerminals
  }
}

function validatedMaximumLiveTerminals(value) {
  if (!Number.isSafeInteger(value)
      || value < 1
      || value > MAX_CONFIGURABLE_LIVE_TERMINALS) {
    throw new RangeError(
      `maximum live terminals must be an integer from 1 to ${MAX_CONFIGURABLE_LIVE_TERMINALS}`,
    )
  }
  return value
}

function configureCapacity(value = DEFAULT_MAX_LIVE_TERMINALS) {
  maximumLiveTerminals = validatedMaximumLiveTerminals(value)
  return capacity()
}

function liveTerminalCount() {
  let count = 0
  for (const record of terms.values()) {
    if (!record.exited) count += 1
  }
  return count
}

function capacity() {
  const live = liveTerminalCount()
  return {
    liveTerminalCount: live,
    maximumLiveTerminals,
    availableTerminalSlots: Math.max(0, maximumLiveTerminals - live),
  }
}

function configureStorage(dir, { asyncWrites = true } = {}) {
  asyncSpoolWrites = asyncWrites !== false
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

/** The broker owns feature negotiation, and negotiation is per connection, so
 * the manager asks rather than deciding. */
function setPrimaryStreamPolicy(policy) {
  primaryStreamPolicy = typeof policy === 'function' ? policy : null
}

/** Fail open. A policy that throws, or one that has not been installed, must
 * leave the primary stream on: sending a copy nobody reads wastes work, but
 * withholding one a renderer is waiting for blanks the terminal. */
function primaryStreamWanted(sender) {
  if (!primaryStreamPolicy) return true
  try {
    return primaryStreamPolicy(sender) !== false
  } catch {
    return true
  }
}

function reportActivity(kind, id = null) {
  try { activitySink?.(String(kind || 'terminal'), id == null ? null : String(id)) } catch { /* safety telemetry only */ }
}

/** Retained history is quota-bounded, and a dropped page is real user-visible
 * history loss — worth a broker log line both while a quota is being approached
 * and once something has actually been evicted. The eviction itself is also
 * stamped into the spool meta, so `snapshot` and `history` keep reporting it
 * long after the log line has scrolled away. */
function reportQuota(event) {
  const surface = event.scope === 'directory' ? 'terminal history directory' : 'terminal history'
  const id = event.id || 'unknown terminal'
  if (event.phase === 'warning') {
    console.warn(`[kaisola] ${surface} quota nearly reached for ${id}: ${event.retainedBytes} of ${event.quotaBytes} bytes retained`)
    return
  }
  console.warn(`[kaisola] ${surface} quota evicted ${event.evictedBytes} bytes of scrollback for ${id}`)
}

/** terminal:run children (plain child_process, not node-pty) — tracked here so
 *  a non-terminating run command dies on app quit instead of reparenting to
 *  launchd. terminalHandler registers/unregisters each spawned child. */
const runChildren = new Set()

// OSC 133 "D" is the shell's own end-of-command mark, emitted by the private
// startup files Kaisola installs (see AppModel's semantic prompt integration).
// It is a real lifecycle event from the process, not an inference from
// quietness, so it is allowed to close an agent turn: the foreground command
// the turn was opened for has returned to the prompt.
const COMMAND_END_MARK = '\u001b]133;D'
const MARK_CARRY = COMMAND_END_MARK.length - 1

/** True when this chunk (joined to the carried tail of the previous one, so a
 *  mark split across two pty writes still matches) reports a finished command.
 *  The carry is only maintained while a turn is open — see p.onData. */
function consumeCommandEndMark(record, data) {
  const window = record.agentMarkCarry ? record.agentMarkCarry + data : data
  record.agentMarkCarry = window.slice(-MARK_CARRY)
  return window.includes(COMMAND_END_MARK)
}

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

/** Keep the primary renderer socket bounded just like observer sockets. Once a
 * delta cannot be queued, the spool remains authoritative and no more deltas
 * are offered until terminal.attach rebinds the sender and returns a snapshot. */
function deliverPrimaryOutput(record, id, payload) {
  if (record.primaryOutputPaused) return false
  const delivered = send(
    record.sender,
    `terminal:data:${id}`,
    payload,
    { maxQueueBytes: DEFAULT_OBSERVER_QUEUE_BYTES },
  )
  if (delivered) return true
  record.primaryOutputPaused = true
  // One forced, small reset marker is the only permitted overflow. Future
  // deltas are discarded until an explicit attach obtains a fresh snapshot.
  send(record.sender, 'terminal:snapshot-required', {
    id,
    reason: 'slow_consumer',
    streamEpoch: record.cursor.streamEpoch,
    endOffset: record.cursor.nextOffset,
  }, { force: true, maxQueueBytes: DEFAULT_OBSERVER_QUEUE_BYTES })
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
  // Continuous cross-restart offsets assume an append-only spool; bounded
  // two-segment rotation would shrink disk bytes underneath a cursor that
  // never decreases. No caller combines these today — refuse loudly so a
  // future one cannot silently corrupt history offsets.
  if (restore && Number.isFinite(outputByteLimit)) return null
  const geometry = validatedTerminalGeometry({ cols, rows }, { defaults: true })
  if (!geometry.ok) return null
  const restoring = restore === true
  const prior = terms.get(id)
  if (prior) {
    if (!prior.exited) {
      cancelRelease(id)
      return prior
    }
    if (restoring && !prior.pty) {
      cancelRelease(id)
      return prior
    }
  }
  const retainedMeta = restoring ? TerminalSpool.readMeta(id, spoolDir) : null
  const restoresColdRecord = retainedMeta
    && Number.isSafeInteger(retainedMeta.exitedAt)
    && retainedMeta.exitedAt >= 0
  if (!restoresColdRecord) {
    const currentCapacity = capacity()
    if (currentCapacity.availableTerminalSlots === 0) {
      throw new TerminalCapacityError(currentCapacity)
    }
  }
  cancelRelease(id)
  if (prior) {
    // a dead pty is not a session — drop the record and spawn fresh under the
    // same id, so a reloaded window gets a working shell instead of a corpse
    const closing = prior.spool.close({ remove: !restoring })
    terms.delete(id)
    if (closing && typeof closing.then === 'function') {
      return closing.then(() => spawn({
        id,
        command,
        args,
        cwd,
        env,
        outputByteLimit,
        cols,
        rows,
        sender,
        restore,
      }))
    }
  }
  const retainedOutputBytes = Number.isFinite(outputByteLimit) ? Math.max(0, Math.floor(outputByteLimit)) : null
  const initialCols = geometry.value.cols
  const initialRows = geometry.value.rows
  const spoolOptions = {
    dir: spoolDir,
    id,
    fresh: !restoring,
    onQuota: reportQuota,
    asyncWriter: asyncSpoolWrites,
    ...(retainedOutputBytes == null ? {} : {
      diskCap: Math.max(1, retainedOutputBytes),
      hotCap: Math.max(1, Math.min(DEFAULT_HOT_CAP, retainedOutputBytes)),
      queueCap: Math.max(1, Math.min(256 * 1024, retainedOutputBytes)),
      retentionCap: retainedOutputBytes,
    }),
  }
  if (restoresColdRecord) {
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
      primaryStreamEnabled: true,
      pending: '',
      flushTimer: null,
      observerPending: null,
      observerFlushTimer: null,
      truncated: false,
      exited: true,
      exitStatus: retainedMeta.exitStatus ?? null,
      waiters: [],
      lastSender: sender,
      detachedAt: null,
      detachedBytes: 0,
      exitedWhileDetached: false,
      agentBusy: false,
      agentTurnOpen: false,
      agentCompletedAt: null,
      agentCompletionSignal: null,
      agentQuietSince: null,
      agentRespondedAt: null,
      agentQuietTimer: null,
      agentMarkCarry: '',
      releasePending: false,
      releaseSignalAccepted: false,
      releaseConfirmation: null,
      releaseFinalizing: null,
    }
    rec.observers = new TerminalObservers({
      terminalId: id,
      deliver: (subscriber, channel, payload, options) => send(subscriber, channel, payload, options),
      onDrop: () => syncSpoolVisibility(rec),
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
  // The spool refuses a storage root it cannot prove is private, and that
  // check lands after the pty already exists. Kill the shell rather than leave
  // an unreferenced process behind on every rejected create.
  let terminalSpool
  try {
    terminalSpool = new TerminalSpool({
      ...spoolOptions,
      onWriterBackpressure: (paused) => {
        try {
          if (paused) p.pause()
          else p.resume()
        } catch { /* a PTY may exit while its final spool append drains */ }
      },
    })
  } catch (error) {
    try { p.kill() } catch { /* already gone */ }
    throw error
  }
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
    // Whether `terminal:data:<id>` is produced at all. That is a different
    // question from who owns the terminal (`sender`, which authorization reads)
    // and from whether a renderer is attached (`rendererVisible`, which drives
    // detached-byte accounting and `exitedWhileDetached`). A client reading the
    // observer stream asks for this to be false so the broker stops serialising
    // a second copy nobody reads; ownership and detach accounting stay put.
    primaryStreamEnabled: true,
    pending: '', // coalesced-but-unsent output (already part of the ring)
    flushTimer: null,
    // The observer batch is kept apart from `pending` on purpose. setSender and
    // detachRenderer discard `pending` because a reattaching renderer replays
    // the snapshot; observers get no such replay, and the cursor has already
    // advanced past these bytes, so the same discard would lose output without
    // surfacing a discontinuity to anyone.
    observerPending: null,
    observerFlushTimer: null,
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
    // `agentBusy` is the indicator the UI spins on; `agentTurnOpen` is the
    // process truth an update gate reads, and only an explicit completion
    // signal ever clears it — see settleAgentTurn/markAgentQuiet below.
    agentBusy: false,
    agentTurnOpen: false,
    agentCompletedAt: null,
    agentCompletionSignal: null,
    agentQuietSince: null,
    agentRespondedAt: null,
    agentQuietTimer: null,
    agentMarkCarry: '', // straddle buffer for OSC 133 marks split across chunks
    // A release request is only a tombstone until node-pty reports exit or the
    // exact child pid is absent. Keeping the live record and spool here is the
    // recovery evidence when signaling fails or races process teardown.
    releasePending: false,
    releaseSignalAccepted: false,
    releaseConfirmation: null,
    releaseFinalizing: null,
  }
  rec.observers = new TerminalObservers({
    terminalId: id,
    deliver: (subscriber, channel, payload, options) => send(subscriber, channel, payload, options),
    // A retired subscription changes the observer count, and the spool's RAM
    // read cache is derived from it.
    onDrop: () => syncSpoolVisibility(rec),
  })
  const broadcastAgentActivity = () => {
    // This event reports cursor.nextOffset, which already counts bytes sitting
    // in the observer batch. Sending it first would claim an offset the client
    // has not been given the output for.
    rec.flushObserverOutput?.()
    send(rec.sender || rec.lastSender, 'terminal:agent-activity', {
      id,
      busy: rec.agentBusy,
      completedAt: rec.agentCompletedAt,
      turnOpen: rec.agentTurnOpen,
      completionSignal: rec.agentCompletionSignal,
      quietSince: rec.agentQuietSince,
    })
    rec.observers.broadcast('terminal:observer-activity', {
      id,
      streamEpoch: rec.cursor.streamEpoch,
      offset: rec.cursor.nextOffset,
      busy: rec.agentBusy,
      completedAt: rec.agentCompletedAt,
      turnOpen: rec.agentTurnOpen,
      completionSignal: rec.agentCompletionSignal,
      quietSince: rec.agentQuietSince,
    }, { streamEpoch: rec.cursor.streamEpoch, endOffset: rec.cursor.nextOffset })
  }
  /** The authoritative end of a turn. Only an explicit lifecycle signal gets
   *  here: the controller's terminal.agentTurn(busy:false), the pty exiting, or
   *  the shell's own OSC 133 command-end mark. Quietness never does. */
  const settleAgentTurn = (signal) => {
    if (rec.agentQuietTimer) clearTimeout(rec.agentQuietTimer)
    rec.agentQuietTimer = null
    if (!rec.agentBusy && !rec.agentTurnOpen) return
    rec.agentBusy = false
    rec.agentTurnOpen = false
    rec.agentQuietSince = null
    rec.agentMarkCarry = ''
    rec.agentCompletionSignal = signal
    // A turn demoted by silence first already carries the moment output
    // stopped; confirming it later must not move the timestamp the UI shows.
    rec.agentCompletedAt = rec.agentCompletedAt ?? Date.now()
    reportActivity('agent-settled', id)
    broadcastAgentActivity()
  }
  /** Degraded fallback for agents that never signal an end of turn: after
   *  AGENT_QUIET_MS the busy indicator relaxes so the UI stops claiming live
   *  work, but the turn stays OPEN and unconfirmed. A quiet model or a slow
   *  tool call is still work in progress, so this state keeps blocking every
   *  update/retirement gate until a real completion signal arrives. */
  const markAgentQuiet = () => {
    rec.agentQuietTimer = null
    if (!rec.agentBusy) return
    rec.agentBusy = false
    rec.agentQuietSince = Date.now()
    rec.agentCompletedAt = rec.agentQuietSince
    rec.agentCompletionSignal = null
    reportActivity('agent-quiet', id)
    broadcastAgentActivity()
  }
  const armAgentQuiet = () => {
    if (!rec.agentBusy) return
    if (rec.agentQuietTimer) clearTimeout(rec.agentQuietTimer)
    rec.agentQuietTimer = setTimeout(markAgentQuiet, AGENT_QUIET_MS)
    rec.agentQuietTimer.unref?.()
  }
  rec.setAgentTurn = (busy) => {
    if (busy) {
      if (rec.agentQuietTimer) clearTimeout(rec.agentQuietTimer)
      rec.agentBusy = true
      rec.agentTurnOpen = true
      rec.agentCompletedAt = null
      rec.agentCompletionSignal = null
      rec.agentQuietSince = null
      rec.agentMarkCarry = ''
      reportActivity('agent-busy', id)
      broadcastAgentActivity()
      armAgentQuiet()
    } else settleAgentTurn('agent-turn')
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
    if (rec.rendererVisible && rec.primaryStreamEnabled) deliverPrimaryOutput(rec, id, chunk)
  }
  rec.flushPending = flushPending
  const flushObserverOutput = () => {
    if (rec.observerFlushTimer) {
      clearTimeout(rec.observerFlushTimer)
      rec.observerFlushTimer = null
    }
    const batch = rec.observerPending
    if (!batch) return
    rec.observerPending = null
    rec.observers.broadcast('terminal:observer-output', { id, ...batch }, {
      streamEpoch: batch.streamEpoch,
      endOffset: batch.endOffset,
    })
  }
  rec.flushObserverOutput = flushObserverOutput
  /** Merge into the open batch when the bytes are genuinely adjacent, and
   * otherwise send what is held and start a new one. Adjacency is checked
   * rather than assumed: the app merges batches only when endOffset meets the
   * next startOffset exactly, and treats any discontinuity as a gap worth
   * recovering from, so a coalescer that silently spanned one would turn a
   * cheap merge into a snapshot refetch. */
  const appendObserverChunk = (chunk) => {
    const batch = rec.observerPending
    // A repair carries counts with their own validation on the far side.
    // Summing them here would invent semantics for a diagnostic, and repairs
    // are rare by construction, so such a chunk simply travels alone.
    if (chunk.unicodeRepair) {
      flushObserverOutput()
      rec.observerPending = { ...chunk }
      flushObserverOutput()
      return
    }
    if (batch
        && batch.streamEpoch === chunk.streamEpoch
        && batch.endOffset === chunk.startOffset) {
      batch.data += chunk.data
      batch.endOffset = chunk.endOffset
    } else {
      flushObserverOutput()
      rec.observerPending = { ...chunk }
    }
    if (Buffer.byteLength(rec.observerPending.data, 'utf8') >= OBSERVER_BATCH_CAP) {
      flushObserverOutput()
      return
    }
    if (!rec.observerFlushTimer) {
      rec.observerFlushTimer = setTimeout(flushObserverOutput, OBSERVER_FLUSH_MS)
    }
  }
  p.onData((data) => {
    reportActivity('terminal-output', id)
    rec.spool.push(data)
    if (rec.agentBusy) {
      const responseAt = Date.now()
      if (!rec.agentRespondedAt || responseAt - rec.agentRespondedAt >= 1_000) {
        rec.agentRespondedAt = responseAt
      }
    }
    // Append before settling. settleAgentTurn broadcasts activity, and activity
    // flushes the observer buffer so a client never sees "turn ended" ahead of
    // the bytes that ended it. Settling first put the broadcast before those
    // bytes were even appended, so no flush could have reached them.
    const endsAgentTurn = rec.agentTurnOpen && consumeCommandEndMark(rec, data)
    for (const piece of splitUtf8(data)) {
      appendObserverChunk(rec.cursor.append(piece))
    }
    if (endsAgentTurn) settleAgentTurn('shell-command-end')
    // Detach accounting is deliberately keyed on rendererVisible alone. A client
    // that reads the observer stream is still attached; it just does not want a
    // second copy. Folding primaryStreamEnabled in here would count visible
    // output as detached and make a visible exit report exitedWhileDetached.
    if (!rec.rendererVisible) rec.detachedBytes += Buffer.byteLength(data)
    if (rec.rendererVisible && rec.primaryStreamEnabled) {
      rec.pending += data
      if (rec.pending.length >= FLUSH_CAP) flushPending()
      else if (!rec.flushTimer) rec.flushTimer = setTimeout(flushPending, flushMs)
    }
    armAgentQuiet()
  })
  p.onExit(({ exitCode, signal }) => {
    reportActivity('terminal-exit', id)
    flushPending() // the tail of the stream must land before the exit signal
    flushObserverOutput() // and the same tail on the stream anyone actually reads
    rec.exited = true
    rec.exitedWhileDetached = !rec.rendererVisible
    rec.exitStatus = { exitCode: exitCode ?? 0, signal: signal ?? null }
    const finishExit = () => {
      settleAgentTurn('terminal-exit')
      // The whole status, not just the code: a signal-killed session exits 0 and
      // would otherwise be indistinguishable from a clean one. Clients that never
      // negotiated terminal-exit-status-v1 are downgraded back to the bare code
      // by the broker's event sink — the manager does not track features.
      send(rec.sender, `terminal:exit:${id}`, rec.exitStatus)
      rec.observers.broadcast('terminal:observer-exit', {
        id,
        streamEpoch: rec.cursor.streamEpoch,
        offset: rec.cursor.nextOffset,
        exitStatus: rec.exitStatus,
      }, { streamEpoch: rec.cursor.streamEpoch, endOffset: rec.cursor.nextOffset })
      resolveExitWaiters(rec, rec.exitStatus)
      if (rec.releasePending && terms.get(id) === rec) {
        const finalized = finalizeReleasedRecord(rec, 'exit-event')
        // Async spool writers drain before deletion. The receipt has no caller
        // once an earlier release returned its retained-tombstone result, but
        // cleanup must still finish and must never become an unhandled reject.
        if (finalized && typeof finalized.then === 'function') void finalized.catch(() => {})
      }
    }
    const persisted = !shuttingDown ? rec.spool.markExited(rec.exitStatus) : null
    if (persisted && typeof persisted.then === 'function') persisted.then(finishExit, finishExit)
    else finishExit()
  })
  terms.set(id, rec)
  if (missingCwd) {
    // NOT silent: a "worktree" agent that actually landed in $HOME must be
    // visibly flagged at the top of its terminal, never mistaken for an
    // isolated checkout. Seeded as chunks[0] so the create-reply snapshot
    // carries it — a live send here would fire before Terminal.tsx's data
    // listener is wired (Electron drops it) and never reach the renderer.
    const { missingCwdWarning } = require('./terminalText.cjs')
    const warn = missingCwdWarning(cwd)
    rec.spool.push(warn)
    rec.cursor.append(warn)
  }
  return rec
}

function write(id, data) {
  if (typeof data !== 'string') {
    return {
      ok: false,
      code: 'invalid_terminal_write_payload',
      message: 'terminal.write data must be a string',
      maximumBytes: MAX_TERMINAL_WRITE_BYTES,
    }
  }
  const actualBytes = Buffer.byteLength(data, 'utf8')
  if (actualBytes > MAX_TERMINAL_WRITE_BYTES) {
    return {
      ok: false,
      code: 'terminal_write_payload_too_large',
      message: `terminal.write data exceeds ${MAX_TERMINAL_WRITE_BYTES} UTF-8 bytes`,
      maximumBytes: MAX_TERMINAL_WRITE_BYTES,
      actualBytes,
    }
  }
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
  if (!record) return false
  const geometry = validatedTerminalGeometry({ cols, rows })
  if (!geometry.ok) return false
  try {
    record.pty.resize(geometry.value.cols, geometry.value.rows)
  } catch {
    // The controller must not cache a geometry the PTY never accepted. A later
    // level-triggered desktop synchronization can safely retry the same size.
    return false
  }
  record.cols = geometry.value.cols
  record.rows = geometry.value.rows
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
  r.flushObserverOutput?.() // attach must not strand the batch either
  r.pending = ''
  r.sender = sender
  r.primaryOutputPaused = false
  r.lastSender = sender
  r.rendererVisible = true
  // Resolved here rather than at spawn because this is the one function both
  // create and attach go through, so a reconnect, an input recovery and a
  // startup restore all re-answer it for whoever is attaching now. Asking the
  // owner's own connection also keeps the answer per-client: during a rolling
  // update one broker serves app lanes of different vintages, and the current
  // and draining generations can have negotiated differently.
  r.primaryStreamEnabled = primaryStreamWanted(sender)
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
  // Discarding r.pending is safe because the reattaching renderer replays the
  // snapshot. Observer bytes have no such second chance: the cursor has already
  // advanced past them, so dropping them loses output with no discontinuity for
  // anyone to notice. A control socket can drop while independent app and
  // Companion observer sockets stay live, so this is reachable, not theoretical.
  r.flushObserverOutput?.()
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

/** Drop ownership only for the exact authenticated terminal. A missing id
 * fails closed; broad socket-loss cleanup has the explicitly named
 * detachSenderPrefix path below. PTYs keep running and move to the disk spool. */
function detachSender(sender, terminalId) {
  if (typeof terminalId !== 'string' || !terminalId) return 0
  const r = terms.get(terminalId)
  if (!r?.sender || !sender || !sameSender(r.sender, sender)) return 0
  const prior = r.sender
  if (!detachRenderer(terminalId, prior)) return 0
  r.lastSender = prior
  r.sender = null
  return 1
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

function missingSnapshot() {
  return { output: '', startOffset: 0, endOffset: 0, streamEpoch: null, truncated: false, exited: true, exitStatus: null }
}

function snapshotRecord(r) {
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
    agentTurnOpen: r.agentTurnOpen,
    agentCompletionSignal: r.agentCompletionSignal,
    agentCompletedAt: r.agentCompletedAt,
    agentRespondedAt: r.agentRespondedAt,
  }
}

function snapshot(id, { responseBarrier = false } = {}) {
  const r = terms.get(id)
  if (!r) return missingSnapshot()
  // A snapshot's endOffset comes from the cursor, which has already advanced
  // past anything held in the observer batch. Answering without flushing first
  // hands those bytes over twice: once inside the snapshot, then again when the
  // timer fires. The app answers a duplicate with gap recovery and Companion
  // resets its projection, so the cost of getting this wrong is not subtle.
  r.flushObserverOutput?.()
  const waiting = r.spool.whenSettled()
  if (waiting) {
    let pausedForResponse = false
    if (responseBarrier && r.pty && !r.spool.writerPaused) {
      try {
        r.pty.pause()
        pausedForResponse = true
      } catch { /* an exited PTY can still serve its durable snapshot */ }
    }
    const result = waiting.then(() => {
      const current = terms.get(id)
      return current ? snapshotRecord(current) : missingSnapshot()
    })
    return pausedForResponse
      ? result.finally(() => {
          try { r.pty.resume() } catch { /* exited while storage drained */ }
        })
      : result
  }
  return snapshotRecord(r)
}

/** Read one older, observer-safe history page without mutating terminal state. */
function history(id, { streamEpoch, beforeOffset, maxBytes } = {}) {
  const r = terms.get(id)
  if (!r) return { ok: false, message: 'Terminal is no longer available.' }
  if (streamEpoch !== r.cursor.streamEpoch) throw new Error('terminal history epoch mismatch')
  if (!Number.isSafeInteger(beforeOffset) || beforeOffset < 0 || beforeOffset > r.cursor.nextOffset) {
    throw new Error('invalid terminal history offset')
  }
  const waiting = r.spool.whenSettled()
  if (waiting) {
    return waiting.then(() => history(id, { streamEpoch, beforeOffset, maxBytes }))
  }
  const cap = Math.min(TERMINAL_HISTORY_PAGE_BYTES, Math.max(64 * 1024, Math.floor(Number(maxBytes) || DEFAULT_SNAPSHOT_CAP)))
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
    // Present only when the spool could not read a retained segment. Absent
    // means the page is complete, not merely non-empty.
    ...(page.readError ? { readError: page.readError } : {}),
    // Only present once a quota evicted something — the page that stops short
    // of byte zero carries the reason it does.
    ...(page.truncation ? { truncation: page.truncation } : {}),
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

// The spool's RAM read cache exists only for attached readers. Deriving its
// visibility from the observer COUNT (2026-08-06 spec §2d) frees ~1 MiB per
// unwatched terminal — the never-called renderer bit had left every terminal
// ever attached holding its hot cache for the broker's lifetime — and a
// count can never let one window's detach clear another window's cache.
function syncSpoolVisibility(r) {
  if (!r) return
  r.spool.setVisible(r.observers.stats().subscribers > 0)
}

function subscribe(id, subscriber, { streamEpoch, afterOffset, maxQueueBytes } = {}) {
  const r = terms.get(id)
  if (!r) return { ok: false, message: 'Terminal is no longer available.' }
  // Same duplicate-delivery hazard as snapshot, and reachable by a different
  // route: the reply is built from a snapshot whose endOffset already covers
  // the held batch, and the new subscriber would then receive that batch again
  // on the next flush. Subscribe and attach are different operations on
  // different sockets; covering one does not cover the other.
  r.flushObserverOutput?.()
  const finish = (record) => {
    record.observers.subscribe(subscriber, { maxQueueBytes })
    syncSpoolVisibility(record)
    try {
      return { ok: true, ...resumeFromSnapshot(snapshotRecord(record), streamEpoch, afterOffset) }
    } catch (error) {
      record.observers.unsubscribe(subscriber)
      syncSpoolVisibility(record)
      throw error
    }
  }
  const waiting = r.spool.whenSettled()
  if (waiting) {
    return waiting.then(() => {
      const current = terms.get(id)
      return current
        ? finish(current)
        : { ok: false, message: 'Terminal is no longer available.' }
    })
  }
  return finish(r)
}

function unsubscribe(id, subscriber) {
  const r = terms.get(id)
  const removed = r?.observers.unsubscribe(subscriber) ?? false
  syncSpoolVisibility(r)
  return removed
}

function unsubscribeSubscriberPrefix(prefix) {
  let removed = 0
  for (const r of terms.values()) {
    removed += r.observers.unsubscribePrefix(prefix)
    syncSpoolVisibility(r)
  }
  return removed
}

function disarmExitWaiter(entry) {
  if (entry.timer) clearTimeout(entry.timer)
  entry.timer = null
  return entry
}

/** Take the whole waiter list off a record so a settle can never run twice. */
function takeExitWaiters(record) {
  const entries = record.waiters
  record.waiters = []
  return entries.map(disarmExitWaiter)
}

function resolveExitWaiters(record, exitStatus) {
  for (const entry of takeExitWaiters(record)) entry.resolve(exitStatus)
}

/** A wait that can no longer be answered is rejected, never left pending: the
 * caller's request must fail loudly instead of hanging on a dead terminal. */
function rejectExitWaiters(entries, message) {
  for (const entry of entries) entry.reject(new Error(message))
  return entries.length
}

function dropExitWaiter(record, entry) {
  const index = record.waiters.indexOf(entry)
  if (index >= 0) record.waiters.splice(index, 1)
  disarmExitWaiter(entry)
}

/** Reject and forget every waiter a predicate matches. The terminal itself is
 * untouched: a client leaving says nothing about the command it was watching. */
function cancelMatchingExitWaiters(record, matches) {
  const kept = []
  const cancelled = []
  for (const entry of record.waiters) {
    if (matches(entry)) cancelled.push(disarmExitWaiter(entry))
    else kept.push(entry)
  }
  record.waiters = kept
  return rejectExitWaiters(cancelled, 'terminal exit wait cancelled')
}

/**
 * Await a terminal's exit status. `owner` is the requesting client's capability
 * key: one client asking twice for the same terminal shares a single resolver
 * (and the first ask's bound), and cancelExitWaiters[Prefix]() can drop that
 * closure when the client goes away. `timeoutMs` bounds one wait; without it the
 * wait lasts as long as the pty, which is the right answer for a command that
 * legitimately runs for hours.
 */
function waitForExit(id, { owner = null, timeoutMs = null } = {}) {
  const r = terms.get(id)
  if (!r) return Promise.reject(new Error('Terminal is no longer available.'))
  if (r.exited) return Promise.resolve(r.exitStatus)
  const key = senderId(owner)
  const existing = key ? r.waiters.find((entry) => entry.owner === key) : null
  if (existing) return existing.promise
  if (r.waiters.length >= MAX_EXIT_WAITERS) {
    return Promise.reject(new Error('too many terminal exit waiters'))
  }
  const entry = { owner: key, resolve: null, reject: null, timer: null, promise: null }
  entry.promise = new Promise((resolve, reject) => {
    entry.resolve = resolve
    entry.reject = reject
  })
  const bound = Number(timeoutMs)
  if (Number.isFinite(bound) && bound > 0) {
    entry.timer = setTimeout(() => {
      dropExitWaiter(r, entry)
      entry.reject(new Error('terminal exit wait timed out'))
    }, Math.min(bound, MAX_EXIT_WAIT_MS))
    entry.timer.unref?.()
  }
  r.waiters.push(entry)
  return entry.promise
}

function exitWaiterCount(id) {
  return terms.get(id)?.waiters.length ?? 0
}

/** Cancel one owner's pending waits on one terminal. */
function cancelExitWaiters(id, owner) {
  const r = terms.get(id)
  const key = senderId(owner)
  if (!r || !key) return 0
  return cancelMatchingExitWaiters(r, (entry) => entry.owner === key)
}

/** Broker socket loss: every wait owned by that app instance is unanswerable,
 * so the closures go with the connection instead of outliving it on a pty that
 * may keep running for hours. */
function cancelExitWaitersPrefix(prefix) {
  if (!prefix) return 0
  let cancelled = 0
  for (const r of terms.values()) {
    cancelled += cancelMatchingExitWaiters(r, (entry) => entry.owner.startsWith(prefix))
  }
  return cancelled
}

function killRecord(record) {
  if (!record) {
    return {
      ok: false,
      code: 'terminal_not_found',
      message: 'terminal is no longer available',
    }
  }
  // Killing is idempotent once node-pty has already delivered its exit event.
  // Cold history records also have no pty, but always carry exited=true.
  if (record.exited) return { ok: true, alreadyExited: true }
  if (!record.pty) {
    return {
      ok: false,
      code: 'terminal_kill_unavailable',
      message: 'terminal signal unavailable',
    }
  }
  try {
    if (record.pty.kill() === false) {
      return { ok: false, code: 'terminal_kill_failed', message: 'terminal signal failed' }
    }
  } catch {
    // Never reflect a native/backend diagnostic across the authenticated wire:
    // it can contain process or filesystem details. The fixed code remains
    // actionable while the unchanged record proves the terminal is still live.
    return { ok: false, code: 'terminal_kill_failed', message: 'terminal signal failed' }
  }
  return { ok: true }
}

function kill(id) {
  return { id, ...killRecord(terms.get(id)) }
}

/** `kill(pid, 0)` sends no signal. Only ESRCH proves the exact numeric child is
 * absent; EPERM and every other diagnostic mean "not confirmed" and therefore
 * retain the spool. We never signal by pid here, so a recycled pid can at worst
 * preserve a tombstone longer, never terminate an unrelated process. */
function terminalProcessMissing(record) {
  let pid
  try { pid = record?.pty?.pid } catch { return false }
  if (!Number.isSafeInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return false
  } catch (error) {
    return error?.code === 'ESRCH'
  }
}

function releaseResult(id, receipt, terminationEvidence) {
  return {
    id,
    ok: receipt.complete,
    released: true,
    termination: { confirmed: true, evidence: terminationEvidence },
    deletion: receipt,
    cleanup: receipt.complete ? null : { method: 'terminal.release', id },
  }
}

function finalizeReleasedRecord(record, terminationEvidence) {
  if (record.releaseFinalizing) return record.releaseFinalizing
  const { id } = record
  const confirmation = record.releaseConfirmation
  if (confirmation?.timer) clearTimeout(confirmation.timer)
  record.releaseConfirmation = null
  if (record.flushTimer) clearTimeout(record.flushTimer)
  if (record.agentQuietTimer) clearTimeout(record.agentQuietTimer)
  record.flushTimer = null
  record.agentQuietTimer = null
  const finish = (receipt) => {
    if (terms.get(id) === record) terms.delete(id)
    // Once termination is confirmed, no future exit event is needed to answer
    // these closures. Refuse them explicitly rather than stranding callers on
    // a record that has now been durably retired.
    rejectExitWaiters(takeExitWaiters(record), 'Terminal is no longer available.')
    record.releaseFinalizing = null
    return releaseResult(id, receipt, terminationEvidence)
  }
  const deletion = record.spool.close({ remove: true })
  if (deletion && typeof deletion.then === 'function') {
    record.releaseFinalizing = deletion.then(finish)
    if (confirmation) record.releaseFinalizing.then(confirmation.resolve, confirmation.reject)
    return record.releaseFinalizing
  }
  const result = finish(deletion)
  confirmation?.resolve(result)
  return result
}

function unconfirmedReleaseResult(id, code) {
  return {
    id,
    ok: false,
    released: false,
    termination: {
      confirmed: false,
      retryable: true,
      code,
      message: 'terminal termination is not confirmed',
    },
    deletion: null,
    cleanup: { method: 'terminal.release', id },
  }
}

function waitForReleaseConfirmation(record) {
  if (record.releaseConfirmation) return record.releaseConfirmation.promise
  const confirmation = {
    timer: null,
    resolve: null,
    reject: null,
    promise: null,
  }
  confirmation.promise = new Promise((resolve, reject) => {
    confirmation.resolve = resolve
    confirmation.reject = reject
  })
  confirmation.timer = setTimeout(() => {
    if (record.releaseConfirmation !== confirmation) return
    record.releaseConfirmation = null
    // A retry may signal again: an accepted signal is not a durable fact about
    // the still-live child, and the first delivery may have been lost.
    record.releaseSignalAccepted = false
    confirmation.resolve(unconfirmedReleaseResult(record.id, 'terminal_exit_unconfirmed'))
  }, RELEASE_CONFIRM_MS)
  confirmation.timer.unref?.()
  record.releaseConfirmation = confirmation
  return confirmation.promise
}

function release(id) {
  cancelRelease(id)
  const r = terms.get(id)
  // The record and its observers are about to go. Anything still batched has
  // nowhere else to be delivered from.
  r?.flushObserverOutput?.()
  if (!r) {
    const deletion = TerminalSpool.cleanup(id, spoolDir)
    return {
      id,
      ok: deletion.complete,
      released: true,
      deletion,
      cleanup: deletion.complete ? null : { method: 'terminal.release', id },
    }
  }
  if (r.releaseFinalizing) return r.releaseFinalizing
  if (r.releaseConfirmation) return r.releaseConfirmation.promise
  if (r.exited) return finalizeReleasedRecord(r, 'exit-event')
  if (terminalProcessMissing(r)) return finalizeReleasedRecord(r, 'pid-missing')

  r.releasePending = true
  reportActivity('terminal-release-pending', id)
  const termination = r.releaseSignalAccepted ? { ok: true } : killRecord(r)
  if (termination.ok) r.releaseSignalAccepted = true

  // node-pty may deliver onExit synchronously for an already-dead child. Check
  // both authoritative forms again after signaling before retaining the
  // tombstone. A merely accepted signal is not evidence of termination.
  if (r.exited) return finalizeReleasedRecord(r, 'exit-event')
  if (terminalProcessMissing(r)) return finalizeReleasedRecord(r, 'pid-missing')
  if (termination.ok) return waitForReleaseConfirmation(r)
  return unconfirmedReleaseResult(
    id,
    termination.code,
  )
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
 * live PTY, every open agent turn, and every tracked non-PTY child must be
 * absent in this single event-loop snapshot. A turn the silence fallback
 * demoted still counts — it is reported separately as unconfirmed so a pending
 * response names the terminals that never signalled an end of turn.
 */
function summarizeUpgradeReadiness(records, childCount) {
  const liveTerminalIds = []
  const busyTerminalIds = []
  const unconfirmedTurnIds = []
  for (const record of records) {
    if (!record.exited) liveTerminalIds.push(String(record.id))
    if (record.agentBusy || record.agentTurnOpen) busyTerminalIds.push(String(record.id))
    if (!record.agentBusy && record.agentTurnOpen) unconfirmedTurnIds.push(String(record.id))
  }
  liveTerminalIds.sort()
  busyTerminalIds.sort()
  unconfirmedTurnIds.sort()
  const runningChildCount = Math.max(0, Number(childCount) || 0)
  return {
    safe: liveTerminalIds.length === 0 && busyTerminalIds.length === 0 && runningChildCount === 0,
    liveTerminalCount: liveTerminalIds.length,
    liveTerminalIds,
    busyAgentCount: busyTerminalIds.length,
    busyTerminalIds,
    unconfirmedTurnCount: unconfirmedTurnIds.length,
    unconfirmedTurnIds,
    childTaskCount: runningChildCount,
  }
}

function upgradeReadiness() {
  return summarizeUpgradeReadiness(terms.values(), runChildren.size)
}

/** Rolling cutover preserves live PTYs and tracked child processes in this
 * process. Only an open CLI agent turn blocks the stability window — including
 * one that merely went quiet, because no completion signal arrived to prove the
 * work finished; socket-request and lease races are fenced by the broker's
 * activity epoch. */
function rollingUpdateReadiness() {
  const summary = summarizeUpgradeReadiness(terms.values(), runChildren.size)
  return { ...summary, safe: summary.busyAgentCount === 0 }
}

function killAll() {
  shuttingDown = true
  const closing = []
  // Capture one last shell cwd while every pid is still live. Missing/erroring
  // lsof is non-fatal and leaves the last inventory value intact.
  refreshCwds({ force: true })
  for (const timer of releaseTimers.values()) clearTimeout(timer)
  releaseTimers.clear()
  for (const r of terms.values()) {
    if (r.flushTimer) clearTimeout(r.flushTimer)
    if (r.agentQuietTimer) clearTimeout(r.agentQuietTimer)
    try {
      if (r.pty) r.pty.kill()
    } catch {
      /* noop */
    }
    // App quit is not a user close: retain the spool so persisted terminal
    // records can restore their previous scrollback on next launch.
    const result = r.spool.close()
    if (result && typeof result.then === 'function') closing.push(result)
    rejectExitWaiters(takeExitWaiters(r), 'Terminal is no longer available.')
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
  return closing.length > 0 ? Promise.allSettled(closing).then(() => undefined) : undefined
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
    out.push({ id: r.id, pid: r.pty.pid, process: proc, cwd: r.cwd, cols: r.cols, rows: r.rows, owner: senderId(r.sender), lastOwner: senderId(r.lastSender), agentBusy: r.agentBusy, agentTurnOpen: r.agentTurnOpen, agentCompletionSignal: r.agentCompletionSignal, agentCompletedAt: r.agentCompletedAt, agentRespondedAt: r.agentRespondedAt })
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
    // Surfaced in broker.status so an unconfirmed (silence-demoted) turn is
    // legible to whoever is deciding whether this helper may be replaced.
    agentBusy: r.agentBusy,
    agentTurnOpen: r.agentTurnOpen,
    agentCompletionSignal: r.agentCompletionSignal,
    agentQuietSince: r.agentQuietSince,
    detachedAt: r.detachedAt,
    detachedBytes: r.detachedBytes,
    streamEpoch: r.cursor.streamEpoch,
    endOffset: r.cursor.nextOffset,
    observerCount: r.observers.stats().subscribers,
    pausedObserverCount: r.observers.stats().paused,
    exitWaiterCount: r.waiters.length,
    releasePending: r.releasePending === true,
  }))
}

module.exports = { available, has, isLive, ownership, spawn, write, agentTurn, resize, setSender, detachRenderer, detachSender, detachSenderPrefix, snapshot, history, subscribe, unsubscribe, unsubscribeSubscriberPrefix, waitForExit, cancelExitWaiters, cancelExitWaitersPrefix, kill, release, scheduleRelease, cancelRelease, trackChild, untrackChild, upgradeReadiness, rollingUpdateReadiness, killAll, list, setAppFocused, configureStorage, configureCapacity, capacity, setEventSink, setActivitySink, setPrimaryStreamPolicy, diagnostics, DEFAULT_MAX_LIVE_TERMINALS, MAX_CONFIGURABLE_LIVE_TERMINALS, MAX_TERMINAL_WRITE_BYTES, __test: { resizeRecord, resumeFromSnapshot, splitUtf8, terminalEnv, summarizeUpgradeReadiness, consumeCommandEndMark, parseLsofCwd, refreshTerminalCwds, prepareHelperDir, installSpawnHelper, exitWaiterCount, liveTerminalCount, validatedMaximumLiveTerminals, TerminalCapacityError, MAX_EXIT_WAITERS, RELEASE_CONFIRM_MS } }
