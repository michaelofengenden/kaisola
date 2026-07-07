// Claude Code runs as a TUI inside Kaisola's terminal — a black box to the shell
// around it. Its hooks system is the sanctioned tap: we generate a settings
// file whose hooks append each event (UserPromptSubmit / PostToolUse / Stop) as
// a JSON line to a file, launch `claude --settings <file>`, tail the file here,
// and stream parsed events to the renderer. That powers the agent-activity
// feed, follow-the-agent, and automatic per-turn checkpoints — without patching
// or wrapping the CLI itself.
const { app, BrowserWindow } = require('electron')
const fs = require('node:fs')
const path = require('node:path')

const EVENTS_CAP_BYTES = 5 * 1024 * 1024
let tail = null // { file, watcher, offset, timer }

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`

function eventsPath() {
  return path.join(app.getPath('userData'), 'claude-events.jsonl')
}
function settingsPath() {
  return path.join(app.getPath('userData'), 'claude-hooks.json')
}

function buildSettings(evFile) {
  // append stdin (one JSON doc) as ONE line; tr strips interior newlines
  const append = `tr -d '\\n\\r' >> ${shq(evFile)}; printf '\\n' >> ${shq(evFile)}`
  const entry = [{ hooks: [{ type: 'command', command: append, timeout: 10 }] }]
  return {
    hooks: {
      UserPromptSubmit: entry,
      PostToolUse: entry,
      Stop: entry,
      // fires when Claude is WAITING on the human (permission ask / idle) —
      // drives the rail's amber "needs you" dot
      Notification: entry,
    },
  }
}

/** Forward only what the renderer needs — tool_input can carry whole files. */
function slim(ev) {
  const input = ev.tool_input || {}
  return {
    at: Date.now(),
    event: ev.hook_event_name,
    sessionId: ev.session_id,
    cwd: ev.cwd,
    tool: ev.tool_name,
    filePath: typeof input.file_path === 'string' ? input.file_path : undefined,
    command: typeof input.command === 'string' ? input.command.slice(0, 200) : undefined,
    prompt: typeof ev.prompt === 'string' ? ev.prompt.slice(0, 200) : undefined,
  }
}

function stopTail() {
  if (!tail) return
  try { tail.watcher.close() } catch { /* already closed */ }
  if (tail.timer) clearInterval(tail.timer)
  tail = null
}

function drain() {
  if (!tail) return
  let stat
  try {
    stat = fs.statSync(tail.file)
  } catch {
    return
  }
  if (stat.size < tail.offset) tail.offset = 0 // file was truncated/reset
  if (stat.size === tail.offset) return
  const fd = fs.openSync(tail.file, 'r')
  const buf = Buffer.alloc(stat.size - tail.offset)
  fs.readSync(fd, buf, 0, buf.length, tail.offset)
  fs.closeSync(fd)
  tail.offset = stat.size
  const text = buf.toString('utf8')
  const lastNl = text.lastIndexOf('\n')
  if (lastNl < 0) {
    tail.offset -= Buffer.byteLength(text, 'utf8') // partial line — re-read next drain
    return
  }
  // a trailing partial line stays unconsumed until its newline arrives
  tail.offset -= Buffer.byteLength(text.slice(lastNl + 1), 'utf8')
  for (const line of text.slice(0, lastNl).split('\n')) {
    const t = line.trim()
    if (!t) continue
    try {
      const ev = JSON.parse(t)
      const payload = slim(ev)
      // broadcast — the tap outlives any single renderer (reloads, reopens)
      for (const win of BrowserWindow.getAllWindows()) {
        if (!win.webContents.isDestroyed()) win.webContents.send('claude:event', payload)
      }
    } catch { /* interleaved/partial write — skip the line */ }
  }
  // keep the tap from growing without bound across long sessions
  if (stat.size > EVENTS_CAP_BYTES) {
    try {
      fs.truncateSync(tail.file, 0)
      tail.offset = 0
    } catch { /* next drain retries */ }
  }
}

/** Write the settings file, reset the events file, start tailing. */
function armTap() {
  const evFile = eventsPath()
  const stFile = settingsPath()
  fs.writeFileSync(evFile, '')
  fs.writeFileSync(stFile, JSON.stringify(buildSettings(evFile), null, 2))
  stopTail()
  const watcher = fs.watch(evFile, { persistent: false }, () => drain())
  // fs.watch on a single file can go quiet after atomic replaces — a slow
  // poll guarantees delivery without meaningful cost
  const timer = setInterval(() => drain(), 1500)
  tail = { file: evFile, watcher, offset: 0, timer }
  return stFile
}

function registerClaudeHooksHandlers(ipcMain) {
  // Arm at STARTUP, not on renderer request — the boot line must be knowable
  // synchronously (a persisted `claude` terminal renders before any async IPC
  // resolves; an await here is how follow-mode silently failed to arm).
  let armedPath = null
  try {
    armedPath = armTap()
  } catch { /* hooks tap is an enhancement — claude still boots plain */ }

  // SYNC path getter — preload exposes it as a constant on the bridge
  ipcMain.on('claude:settings-path-sync', (event) => {
    event.returnValue = armedPath
  })

  // kept for compatibility: re-arm on demand (also resets the events file)
  ipcMain.handle('claude:arm', async () => {
    try {
      armedPath = armTap()
      return { ok: true, settingsPath: armedPath }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  // events broadcast to every window now — rebind is a no-op kept for callers
  ipcMain.handle('claude:rebind', () => ({ ok: true }))

  // Does a Claude Code session transcript still exist for this workspace?
  // Claude stores sessions at ~/.claude/projects/<cwd with non-alnum → '-'>/
  // <session-id>.jsonl — the renderer asks before booting `claude --resume`,
  // so a pruned/stale id never boots into an error message.
  ipcMain.handle('claude:session-exists', (_e, { cwd, sessionId } = {}) => {
    if (typeof cwd !== 'string' || !cwd || typeof sessionId !== 'string' || !/^[a-zA-Z0-9-]+$/.test(sessionId)) {
      return { ok: false, exists: false }
    }
    try {
      const os = require('node:os')
      const dir = path.join(os.homedir(), '.claude', 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'))
      return { ok: true, exists: fs.existsSync(path.join(dir, `${sessionId}.jsonl`)) }
    } catch {
      return { ok: false, exists: false }
    }
  })
}

function disposeClaudeHooks() {
  stopTail()
}

module.exports = { registerClaudeHooksHandlers, disposeClaudeHooks }
