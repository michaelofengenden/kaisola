// Shared pty manager. Both the interactive dock terminal (driven by the user via
// IPC) and the agent's terminals (created over ACP when the agent runs a command)
// go through here, so an agent command is a real pty that streams LIVE into the
// dock — you watch it happen and can take over — while its output + exit status
// flow back to the agent.
const os = require('node:os')
const { agentEnv } = require('./shellEnv.cjs')

let pty = null
try {
  pty = require('node-pty')
} catch (err) {
  console.error('[pasola] node-pty unavailable:', err.message)
}

const OUTPUT_CAP = 1_000_000 // keep up to ~1MB of output per terminal
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

/** main.cjs calls this on app focus/blur — the stream profile follows. */
function setAppFocused(focused) {
  flushMs = focused ? FLUSH_MS_FOCUSED : FLUSH_MS_BLURRED
}

/** id → record */
const terms = new Map()

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

function send(sender, channel, payload) {
  if (sender && !sender.isDestroyed?.()) sender.send(channel, payload)
}

/**
 * Spawn a pty. `command`/`args` default to an interactive login shell. Streams
 * data to `sender` on terminal:data:<id> and accumulates output for snapshots
 * and ACP terminal/output. Resolves exit via waitForExit().
 */
function spawn({ id, command, args, cwd, env, cols, rows, sender }) {
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
  const fs = require('node:fs')
  const missingCwd = !!cwd && !fs.existsSync(cwd)
  const startCwd = missingCwd ? os.homedir() : (cwd || os.homedir())
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
    // snapshot ring as a CHUNK LIST, joined lazily on snapshot(): the old
    // `output += data; slice(-CAP)` did a ~1MB string copy on every chunk
    // once the ring was full — a fast-scrolling command turned that into
    // gigabytes of allocation. Dropping whole stale chunks is O(dropped).
    chunks: [],
    chunksLen: 0,
    pending: '', // coalesced-but-unsent output (already part of the ring)
    flushTimer: null,
    truncated: false,
    exited: false,
    exitStatus: null, // { exitCode, signal }
    waiters: [],
  }
  const flushPending = () => {
    if (rec.flushTimer) {
      clearTimeout(rec.flushTimer)
      rec.flushTimer = null
    }
    if (!rec.pending) return
    const chunk = rec.pending
    rec.pending = ''
    send(rec.sender, `terminal:data:${id}`, chunk)
  }
  rec.flushPending = flushPending
  p.onData((data) => {
    rec.chunks.push(data)
    rec.chunksLen += data.length
    if (rec.chunksLen > OUTPUT_CAP) {
      rec.truncated = true
      while (rec.chunks.length > 1 && rec.chunksLen - rec.chunks[0].length >= OUTPUT_CAP) {
        rec.chunksLen -= rec.chunks[0].length
        rec.chunks.shift()
      }
    }
    rec.pending += data
    if (rec.pending.length >= FLUSH_CAP) flushPending()
    else if (!rec.flushTimer) rec.flushTimer = setTimeout(flushPending, flushMs)
  })
  p.onExit(({ exitCode, signal }) => {
    flushPending() // the tail of the stream must land before the exit signal
    rec.exited = true
    rec.exitStatus = { exitCode: exitCode ?? 0, signal: signal ?? null }
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
    rec.chunks.push(warn)
    rec.chunksLen += warn.length
  }
  return rec
}

function write(id, data) {
  const r = terms.get(id)
  if (r) r.pty.write(data)
  return !!r
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
  const r = terms.get(id)
  if (!r) return
  // drop unflushed bytes: they are already in the snapshot ring, and the
  // (re)attaching renderer replays the snapshot — flushing them too would
  // double-print
  if (r.flushTimer) {
    clearTimeout(r.flushTimer)
    r.flushTimer = null
  }
  r.pending = ''
  r.sender = sender
}

function snapshot(id) {
  const r = terms.get(id)
  if (!r) return { output: '', exited: true, exitStatus: null }
  // join once and collapse the ring to a single exact-cap chunk, so repeated
  // snapshots (and the next joins) stay cheap
  if (r.chunks.length > 1 || (r.chunks[0]?.length ?? 0) > OUTPUT_CAP) {
    const joined = r.chunks.join('')
    r.chunks = [joined.length > OUTPUT_CAP ? joined.slice(-OUTPUT_CAP) : joined]
    r.chunksLen = r.chunks[0].length
  }
  return { output: r.chunks[0] ?? '', truncated: r.truncated, exited: r.exited, exitStatus: r.exitStatus }
}

function waitForExit(id) {
  const r = terms.get(id)
  if (!r) return Promise.resolve({ exitCode: 0, signal: null })
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
  const r = terms.get(id)
  if (r?.flushTimer) clearTimeout(r.flushTimer)
  kill(id)
  terms.delete(id)
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
  for (const r of terms.values()) {
    if (r.flushTimer) clearTimeout(r.flushTimer)
    try {
      r.pty.kill()
    } catch {
      /* noop */
    }
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
    out.push({ id: r.id, pid: r.pty.pid, process: proc })
  }
  return out
}

module.exports = { available, has, isLive, spawn, write, resize, setSender, snapshot, waitForExit, kill, release, trackChild, untrackChild, killAll, list, setAppFocused }
