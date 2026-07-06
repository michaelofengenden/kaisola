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

/** id → record */
const terms = new Map()

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
    output: '',
    truncated: false,
    exited: false,
    exitStatus: null, // { exitCode, signal }
    waiters: [],
  }
  p.onData((data) => {
    rec.output += data
    if (rec.output.length > OUTPUT_CAP) {
      rec.output = rec.output.slice(-OUTPUT_CAP)
      rec.truncated = true
    }
    send(rec.sender, `terminal:data:${id}`, data)
  })
  p.onExit(({ exitCode, signal }) => {
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
    // isolated checkout. Sent through the same data channel the shell uses.
    const warn = `\r\n\x1b[33m⚠ working directory not found:\x1b[0m ${cwd}\r\n\x1b[33m  started in ${os.homedir()} instead — this session is NOT isolated.\x1b[0m\r\n\r\n`
    queueMicrotask(() => send(rec.sender, `terminal:data:${id}`, warn))
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
  if (r) r.sender = sender
}

function snapshot(id) {
  const r = terms.get(id)
  if (!r) return { output: '', exited: true, exitStatus: null }
  return { output: r.output, truncated: r.truncated, exited: r.exited, exitStatus: r.exitStatus }
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
  kill(id)
  terms.delete(id)
}

function killAll() {
  for (const r of terms.values()) {
    try {
      r.pty.kill()
    } catch {
      /* noop */
    }
  }
  terms.clear()
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

module.exports = { available, has, isLive, spawn, write, resize, setSender, snapshot, waitForExit, kill, release, killAll, list }
