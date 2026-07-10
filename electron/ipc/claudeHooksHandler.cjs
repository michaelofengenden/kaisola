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
const STATUS_CAP_BYTES = 5 * 1024 * 1024
const STATUS_RETAIN_BYTES = 768 * 1024
let tail = null // { file, watcher, offset, timer, statusTimer }

const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`

function eventsPath() {
  return path.join(app.getPath('userData'), 'claude-events.jsonl')
}
function settingsPath() {
  return path.join(app.getPath('userData'), 'claude-hooks.json')
}
function statusCachePath() {
  return path.join(app.getPath('userData'), 'claude-statusline.jsonl')
}

function buildSettings(evFile, statusFile = statusCachePath(), includeStatusLine = true) {
  // append stdin (one JSON doc) as ONE line; tr strips interior newlines
  const append = `tr -d '\\n\\r' >> ${shq(evFile)}; printf '\\n' >> ${shq(evFile)}`
  // Claude Code's documented status-line JSON is a stable fallback for exact
  // 5h/7d plan windows. Prefix each captured object with epoch seconds so the
  // renderer can be honest about staleness. This command does not read auth or
  // call a model; the cache is private app data and contains no credentials.
  const captureStatus = `input=$(tr -d '\\n\\r'); printf '%s\\t%s\\n' "$(date +%s)" "$input" >> ${shq(statusFile)}; five=$(printf '%s' "$input" | sed -nE 's/.*"five_hour"[[:space:]]*:[[:space:]]*\\{[^}]*"used_percentage"[[:space:]]*:[[:space:]]*([0-9]+([.][0-9]+)?).*/\\1/p'); week=$(printf '%s' "$input" | sed -nE 's/.*"seven_day"[[:space:]]*:[[:space:]]*\\{[^}]*"used_percentage"[[:space:]]*:[[:space:]]*([0-9]+([.][0-9]+)?).*/\\1/p'); label='Claude'; [ -n "$five" ] && label="$label · 5h \${five}%"; [ -n "$week" ] && label="$label · 7d \${week}%"; printf '%s\\n' "$label"`
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
    ...(includeStatusLine ? {
      statusLine: {
        type: 'command',
        command: captureStatus,
        padding: 0,
      },
    } : {}),
  }
}

const expandHome = (value) => typeof value === 'string'
  ? value.replace(/^~(?=\/|$)/, require('node:os').homedir())
  : value

/** Respect an existing Claude status-line in user, project, or local-project
 * settings. `--settings` has high precedence, so injecting our usage fallback
 * unconditionally would silently replace the user's own status UI. */
function hasCustomStatusLine(configDir, cwd) {
  const base = typeof configDir === 'string' && configDir.trim()
    ? path.resolve(expandHome(configDir.trim()))
    : path.join(require('node:os').homedir(), '.claude')
  const candidates = [path.join(base, 'settings.json')]
  if (typeof cwd === 'string' && cwd.trim()) {
    const root = path.resolve(expandHome(cwd.trim()))
    candidates.push(path.join(root, '.claude', 'settings.json'), path.join(root, '.claude', 'settings.local.json'))
  }
  return candidates.some((file) => {
    try {
      const value = JSON.parse(fs.readFileSync(file, 'utf8'))
      return !!(value && typeof value === 'object' && value.statusLine && typeof value.statusLine === 'object')
    } catch {
      return false
    }
  })
}

function prepareStatusCache(file) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true })
    if (!fs.existsSync(file)) fs.writeFileSync(file, '', { mode: 0o600 })
    const st = fs.statSync(file)
    if (st.size > STATUS_CAP_BYTES) {
      const fd = fs.openSync(file, 'r')
      const length = Math.min(st.size, STATUS_RETAIN_BYTES)
      const buf = Buffer.alloc(length)
      fs.readSync(fd, buf, 0, length, st.size - length)
      fs.closeSync(fd)
      const firstNl = buf.indexOf(10)
      fs.writeFileSync(file, firstNl >= 0 ? buf.subarray(firstNl + 1) : buf, { mode: 0o600 })
    }
    fs.chmodSync(file, 0o600)
  } catch { /* capture is a fallback; Claude still launches without it */ }
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
  if (tail.statusTimer) clearInterval(tail.statusTimer)
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

// renderer-chosen Claude Code settings (fastMode, …) merged into the same
// --settings file the boot line already carries — hooks stay authoritative
let extraFlags = {}

/** Write the settings file, reset the events file, start tailing. */
function armTap(context = {}) {
  const evFile = eventsPath()
  const stFile = settingsPath()
  const statusFile = statusCachePath()
  prepareStatusCache(statusFile)
  // usageHandler intentionally avoids importing Electron in its unit-testable
  // module. This process-local pointer joins the two main-process services.
  process.env.KAISOLA_CLAUDE_STATUS_CACHE = statusFile
  fs.writeFileSync(evFile, '')
  const includeStatusLine = !hasCustomStatusLine(context.configDir, context.cwd)
  fs.writeFileSync(stFile, JSON.stringify({ ...buildSettings(evFile, statusFile, includeStatusLine), ...extraFlags }, null, 2))
  stopTail()
  const watcher = fs.watch(evFile, { persistent: false }, () => drain())
  // fs.watch on a single file can go quiet after atomic replaces — a slow
  // poll guarantees delivery without meaningful cost
  const timer = setInterval(() => drain(), 1500)
  // Status-line commands can run for weeks without restarting Kaisola. Keep
  // their private JSONL fallback bounded during the live process too, not only
  // at startup.
  const statusTimer = setInterval(() => prepareStatusCache(statusFile), 60_000)
  statusTimer.unref?.()
  tail = { file: evFile, watcher, offset: 0, timer, statusTimer }
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

  // fast mode etc. — rewrite ONLY the settings file (never resets the events
  // tail); a claude launched after this boots with the new flags
  ipcMain.handle('claude:settings-flags', (_event, payload) => {
    // Backwards compatible with old renderers that sent the flags object
    // directly; current renderers also identify the account/workspace whose
    // settings precedence must be respected.
    const wrapped = payload && typeof payload === 'object' && Object.prototype.hasOwnProperty.call(payload, 'flags')
    const flags = wrapped ? payload.flags : payload
    const configDir = wrapped ? payload.configDir : undefined
    const cwd = wrapped ? payload.cwd : undefined
    extraFlags = flags && typeof flags === 'object' ? flags : {}
    try {
      const includeStatusLine = !hasCustomStatusLine(configDir, cwd)
      fs.writeFileSync(settingsPath(), JSON.stringify({ ...buildSettings(eventsPath(), statusCachePath(), includeStatusLine), ...extraFlags }, null, 2))
      return { ok: true, usageStatusLine: includeStatusLine }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
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
  // Claude stores sessions at <config dir>/projects/<cwd with non-alnum → '-'>/
  // <session-id>.jsonl — the renderer asks before booting `claude --resume`,
  // so a pruned/stale id never boots into an error message. `any` reports
  // whether the workspace has ANY transcript at all: with no tracked id the
  // boot falls back to `claude --continue` (most recent conversation in that
  // directory — covers sessions started outside Kaisola too). `configDir` is
  // the account's CLAUDE_CONFIG_DIR (multi-subscription); empty = ~/.claude.
  ipcMain.handle('claude:session-exists', (_e, { cwd, sessionId, configDir } = {}) => {
    if (typeof cwd !== 'string' || !cwd) return { ok: false, exists: false, any: false }
    try {
      const os = require('node:os')
      const base = typeof configDir === 'string' && configDir.trim()
        ? configDir.replace(/^~(?=\/|$)/, os.homedir())
        : path.join(os.homedir(), '.claude')
      const dir = path.join(base, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'))
      const any = fs.existsSync(dir) && fs.readdirSync(dir).some((f) => f.endsWith('.jsonl'))
      const exists =
        typeof sessionId === 'string' && /^[a-zA-Z0-9-]+$/.test(sessionId)
          ? fs.existsSync(path.join(dir, `${sessionId}.jsonl`))
          : false
      return { ok: true, exists, any }
    } catch {
      return { ok: false, exists: false, any: false }
    }
  })

  // Who is signed in under a Claude config dir? Reads <dir>/.claude.json —
  // the CLI records the OAuth account there (email + org). Powers the account
  // labels on session cards and Settings rows. Empty configDir = ~/.claude.
  ipcMain.handle('claude:account-info', (_e, { configDir } = {}) => {
    try {
      const os = require('node:os')
      const custom = typeof configDir === 'string' && !!configDir.trim()
      const base = custom
        ? path.resolve(configDir.trim().replace(/^~(?=\/|$)/, os.homedir()))
        : path.join(os.homedir(), '.claude')
      // The default profile's account metadata is ~/.claude.json. Isolated
      // CLAUDE_CONFIG_DIR profiles keep it inside their selected directory.
      // Retain the nested path as a legacy fallback for older installs.
      const candidates = custom
        ? [path.join(base, '.claude.json')]
        : [path.join(os.homedir(), '.claude.json'), path.join(base, '.claude.json')]
      let oa = null
      for (const file of candidates) {
        try {
          const cfg = JSON.parse(fs.readFileSync(file, 'utf8'))
          if (cfg && typeof cfg === 'object' && cfg.oauthAccount && typeof cfg.oauthAccount === 'object') {
            oa = cfg.oauthAccount
            break
          }
        } catch { /* try the next compatible location */ }
      }
      if (!oa) return { ok: true, exists: false }
      const email = typeof oa.emailAddress === 'string' ? oa.emailAddress : undefined
      const org = typeof oa.organizationName === 'string' ? oa.organizationName : undefined
      return { ok: true, email, org, exists: true }
    } catch {
      // dir missing or not signed in yet — both are fine, the row just shows "not signed in"
      return { ok: true, exists: false }
    }
  })
}

function disposeClaudeHooks() {
  stopTail()
}

module.exports = { registerClaudeHooksHandlers, disposeClaudeHooks, _buildSettingsForTests: buildSettings, _hasCustomStatusLineForTests: hasCustomStatusLine }
