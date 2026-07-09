// Subscription limits at a click. Two very different sources, one IPC surface:
//
// • Codex — the CLI ships an app-server (JSON-RPC over stdio) whose
//   account/rateLimits/read returns the REAL rate-limit state: primary = the
//   rolling 5h window, secondary = the weekly window, usedPercent + resetsAt.
//   We spawn it read-only/untrusted, ask, and kill it (CodexBar's approach).
//
// • Claude — there is NO sanctioned non-interactive `/usage`. The honest local
//   proxy is the transcripts: every assistant message in
//   <configDir>/projects/*/*.jsonl carries token usage. We sum the last 5h and
//   7d (ccusage's approach) and label it an estimate. Works per account
//   (CLAUDE_CONFIG_DIR) with zero auth.
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const readline = require('node:readline')

const CODEX_TIMEOUT_MS = 15_000
const CLAUDE_FILE_CAP = 400 // most-recent transcript files scanned per account
const CLAUDE_FILE_MAX_BYTES = 30 * 1024 * 1024

const expandHome = (p) => (typeof p === 'string' ? p.replace(/^~(?=\/|$)/, os.homedir()) : p)

/** codex app-server: initialize → account/read → account/rateLimits/read. */
function codexUsage(codexHome) {
  return new Promise((resolve) => {
    let settled = false
    const done = (v) => { if (!settled) { settled = true; try { proc.kill() } catch { /* gone */ } resolve(v) } }
    const env = { ...process.env }
    if (codexHome) env.CODEX_HOME = expandHome(codexHome)
    let proc
    try {
      proc = spawn('codex', ['-s', 'read-only', '-a', 'untrusted', 'app-server'], { env, stdio: ['pipe', 'pipe', 'ignore'] })
    } catch (err) {
      return resolve({ ok: false, message: String((err && err.message) || err) })
    }
    proc.on('error', (err) => done({ ok: false, message: /ENOENT/.test(String(err)) ? 'Codex CLI not found on PATH.' : String(err.message || err) }))
    const timer = setTimeout(() => done({ ok: false, message: 'Codex app-server timed out.' }), CODEX_TIMEOUT_MS)
    timer.unref?.()

    const out = { account: null, rateLimits: null }
    const send = (id, method, params) => {
      try { proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n') } catch { /* dying */ }
    }
    const rl = readline.createInterface({ input: proc.stdout })
    rl.on('line', (line) => {
      let msg
      try { msg = JSON.parse(line) } catch { return }
      if (msg.id === 1) send(2, 'account/read', { refreshToken: false })
      else if (msg.id === 2) {
        out.account = (msg.result && msg.result.account) || null
        send(3, 'account/rateLimits/read', {})
      } else if (msg.id === 3) {
        if (msg.error) return done({ ok: false, message: msg.error.message || 'rateLimits read failed' })
        out.rateLimits = (msg.result && msg.result.rateLimits) || null
        const rl2 = out.rateLimits || {}
        done({
          ok: true,
          email: out.account && out.account.email,
          plan: (out.account && out.account.planType) || rl2.planType,
          primary: rl2.primary || null, //   { usedPercent, windowDurationMins, resetsAt }
          secondary: rl2.secondary || null, // weekly window, same shape
        })
      }
    })
    send(1, 'initialize', { clientInfo: { name: 'kaisola', title: 'Kaisola', version: '0' } })
  })
}

/** Sum assistant-message token usage in <configDir>/projects over 5h/7d. */
function claudeUsage(configDir) {
  const base = configDir ? expandHome(configDir) : path.join(os.homedir(), '.claude')
  const projectsDir = path.join(base, 'projects')
  const now = Date.now()
  const H5 = now - 5 * 3600_000
  const D7 = now - 7 * 24 * 3600_000
  const zero = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 })
  const fiveHour = zero()
  const week = zero()
  let lastActivity = 0
  const seen = new Set()

  let files = []
  try {
    for (const proj of fs.readdirSync(projectsDir)) {
      const dir = path.join(projectsDir, proj)
      let names
      try { names = fs.readdirSync(dir) } catch { continue }
      for (const f of names) {
        if (!f.endsWith('.jsonl')) continue
        const full = path.join(dir, f)
        try {
          const st = fs.statSync(full)
          if (st.mtimeMs >= D7 && st.size <= CLAUDE_FILE_MAX_BYTES) files.push({ full, mtime: st.mtimeMs })
        } catch { /* raced */ }
      }
    }
  } catch {
    return { ok: true, exists: false, fiveHour, week, lastActivity: 0 }
  }
  files = files.sort((a, b) => b.mtime - a.mtime).slice(0, CLAUDE_FILE_CAP)

  for (const { full } of files) {
    let text
    try { text = fs.readFileSync(full, 'utf8') } catch { continue }
    for (let s = 0; s < text.length;) {
      const e = text.indexOf('\n', s)
      const line = text.slice(s, e < 0 ? text.length : e)
      s = e < 0 ? text.length : e + 1
      if (!line.includes('"usage"')) continue
      let ev
      try { ev = JSON.parse(line) } catch { continue }
      const usage = ev && ev.message && ev.message.usage
      if (!usage) continue
      const ts = Date.parse(ev.timestamp || '') || 0
      if (!ts || ts < D7) continue
      // retries re-log the same request — count each message once (ccusage's dedupe)
      const id = `${(ev.message && ev.message.id) || ''}:${ev.requestId || ''}`
      if (id !== ':' && seen.has(id)) continue
      if (id !== ':') seen.add(id)
      if (ts > lastActivity) lastActivity = ts
      const add = (acc) => {
        acc.input += usage.input_tokens || 0
        acc.output += usage.output_tokens || 0
        acc.cacheRead += usage.cache_read_input_tokens || 0
        acc.cacheWrite += usage.cache_creation_input_tokens || 0
      }
      add(week)
      if (ts >= H5) add(fiveHour)
    }
  }
  return { ok: true, exists: true, fiveHour, week, lastActivity }
}

// Per-SESSION token sums, grouped by model (the $ chip on session cards).
// A Claude session's transcript is projects/<slug>/<sessionId>.jsonl — the
// session id names the file, so this reads exactly one file per project dir.
function claudeSessionUsage(configDir, sessionId) {
  if (!sessionId || /[/\\]/.test(sessionId)) return { ok: false }
  const base = configDir ? expandHome(configDir) : path.join(os.homedir(), '.claude')
  const projectsDir = path.join(base, 'projects')
  const seen = new Set()
  const models = new Map() // model → sums
  let found = false
  let dirs = []
  try { dirs = fs.readdirSync(projectsDir) } catch { return { ok: true, exists: false, models: [] } }
  for (const proj of dirs) {
    const full = path.join(projectsDir, proj, `${sessionId}.jsonl`)
    let text
    try {
      if (fs.statSync(full).size > CLAUDE_FILE_MAX_BYTES) continue
      text = fs.readFileSync(full, 'utf8')
    } catch { continue }
    found = true
    for (let s = 0; s < text.length;) {
      const e = text.indexOf('\n', s)
      const line = text.slice(s, e < 0 ? text.length : e)
      s = e < 0 ? text.length : e + 1
      if (!line.includes('"usage"')) continue
      let ev
      try { ev = JSON.parse(line) } catch { continue }
      const usage = ev && ev.message && ev.message.usage
      if (!usage) continue
      const id = `${(ev.message && ev.message.id) || ''}:${ev.requestId || ''}`
      if (id !== ':' && seen.has(id)) continue
      if (id !== ':') seen.add(id)
      const model = (ev.message && ev.message.model) || 'unknown'
      const acc = models.get(model) || { model, input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
      acc.input += usage.input_tokens || 0
      acc.output += usage.output_tokens || 0
      acc.cacheRead += usage.cache_read_input_tokens || 0
      acc.cacheWrite += usage.cache_creation_input_tokens || 0
      models.set(model, acc)
    }
  }
  return { ok: true, exists: found, models: [...models.values()] }
}

function registerUsageHandlers(ipcMain) {
  ipcMain.handle('usage:codex', async (_e, { codexHome } = {}) => codexUsage(codexHome))
  ipcMain.handle('usage:claude', async (_e, { configDir } = {}) => {
    try {
      return claudeUsage(configDir)
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('usage:claudeSession', async (_e, { configDir, sessionId } = {}) => {
    try {
      return claudeSessionUsage(configDir, sessionId)
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })
}

module.exports = { registerUsageHandlers }
