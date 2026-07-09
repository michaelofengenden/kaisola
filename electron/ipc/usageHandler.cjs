// Subscription limits at a click. Two very different sources, one IPC surface:
//
// • Codex — the CLI ships an app-server (JSON-RPC over stdio) whose
//   account/rateLimits/read returns the real rolling rate-limit state.
//
// • Claude — Claude Code does not expose its subscription percentage through a
//   supported non-interactive command. The honest local proxy is its JSONL
//   transcripts. We sum the last 5h / 7d and label the result as local activity.
//
// Keep both paths non-blocking. In particular, transcript trees can be large;
// synchronous reads here freeze Electron's main process and make every window
// look hung while the Limits panel is open.
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const fsp = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const readline = require('node:readline')
const { agentEnv } = require('./shellEnv.cjs')

const CODEX_TIMEOUT_MS = 15_000
const CODEX_ERROR_TAIL = 1_200
const CLAUDE_FILE_CAP = 600 // most-recent transcript files scanned per account
const CLAUDE_TOTAL_BYTE_CAP = 512 * 1024 * 1024
const CLAUDE_TREE_ENTRY_CAP = 20_000

const expandHome = (p) => (typeof p === 'string' ? p.replace(/^~(?=\/|$)/, os.homedir()) : p)
const messageOf = (err) => String((err && err.message) || err || 'Unknown error')
const tail = (text, cap = CODEX_ERROR_TAIL) => text.slice(-cap).trim()

/** Pick the backwards-compatible Codex bucket, with support for the newer
 * multi-bucket response. The latter matters for accounts with several metered
 * products: the first object key is not guaranteed to be Codex. */
function codexRateLimitSnapshot(result) {
  const legacy = result && result.rateLimits
  const byId = result && result.rateLimitsByLimitId
  if (!byId || typeof byId !== 'object') return legacy || null
  return byId.codex || Object.values(byId).find((x) => x && (x.limitId === 'codex' || x.primary || x.secondary)) || legacy || null
}

/** codex app-server: initialize -> account/read -> account/rateLimits/read. */
function codexUsage(codexHome, options = {}) {
  if (!options.spawnImpl && (process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE)) {
    return Promise.resolve({ ok: false, message: 'Codex usage disabled during smoke tests.' })
  }
  return new Promise((resolve) => {
    const spawnImpl = options.spawnImpl || spawn
    const timeoutMs = options.timeoutMs || CODEX_TIMEOUT_MS
    const extraEnv = codexHome ? { CODEX_HOME: expandHome(codexHome) } : undefined
    // GUI-launched macOS apps inherit /usr/bin:/bin, not the user's shell PATH.
    // Every other agent process already uses agentEnv(); usage must do the same.
    const env = options.env || agentEnv(extraEnv)
    let proc
    let timer
    let lines
    let settled = false
    let stderr = ''

    const cleanup = () => {
      if (timer) clearTimeout(timer)
      try { lines && lines.close() } catch { /* already closed */ }
      try { proc && proc.kill() } catch { /* already gone */ }
    }
    const done = (value) => {
      if (settled) return
      settled = true
      cleanup()
      resolve(value)
    }
    const fail = (fallback) => {
      const detail = tail(stderr)
      done({ ok: false, message: detail || fallback })
    }

    try {
      proc = spawnImpl('codex', ['-s', 'read-only', '-a', 'untrusted', 'app-server'], {
        env,
        stdio: ['pipe', 'pipe', 'pipe'],
      })
    } catch (err) {
      done({ ok: false, message: /ENOENT/.test(messageOf(err)) ? 'Codex CLI not found on PATH.' : messageOf(err) })
      return
    }

    proc.on('error', (err) => {
      const msg = /ENOENT/.test(messageOf(err)) ? 'Codex CLI not found on PATH.' : messageOf(err)
      fail(msg)
    })
    proc.on('exit', (code, signal) => {
      if (settled) return
      fail(`Codex app-server exited before returning limits (${signal || `code ${code}`}).`)
    })
    proc.stderr.on('data', (chunk) => { stderr = (stderr + chunk.toString()).slice(-CODEX_ERROR_TAIL) })
    // Killing after a completed response can race a final stdin write.
    proc.stdin.on('error', () => {})
    timer = setTimeout(() => fail('Codex app-server timed out.'), timeoutMs)
    timer.unref?.()

    const account = { value: null }
    const send = (id, method, params) => {
      if (settled || !proc.stdin.writable) return
      try { proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n') } catch { /* exit/error reports the cause */ }
    }
    const notify = (method, params = {}) => {
      if (settled || !proc.stdin.writable) return
      try { proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n') } catch { /* exit/error reports the cause */ }
    }

    lines = readline.createInterface({ input: proc.stdout })
    lines.on('line', (line) => {
      let msg
      try { msg = JSON.parse(line) } catch { return }
      if (msg.id === 1) {
        if (msg.error) { fail(msg.error.message || 'Codex app-server initialization failed.'); return }
        notify('initialized')
        send(2, 'account/read', { refreshToken: false })
      } else if (msg.id === 2) {
        if (msg.error) { fail(msg.error.message || 'Codex account read failed.'); return }
        account.value = (msg.result && msg.result.account) || null
        if (!account.value) {
          done({ ok: false, message: 'Codex is not signed in. Run `codex login`.' })
          return
        }
        send(3, 'account/rateLimits/read', {})
      } else if (msg.id === 3) {
        if (msg.error) { fail(msg.error.message || 'Codex rate-limit read failed.'); return }
        const snapshot = codexRateLimitSnapshot(msg.result)
        if (!snapshot) {
          done({ ok: false, message: 'Codex returned no rate-limit windows for this account.' })
          return
        }
        done({
          ok: true,
          email: account.value && account.value.email,
          plan: (account.value && account.value.planType) || snapshot.planType,
          primary: snapshot.primary || null,
          secondary: snapshot.secondary || null,
          updatedAt: Date.now(),
        })
      }
    })

    send(1, 'initialize', { clientInfo: { name: 'kaisola', title: 'Kaisola', version: '0' } })
  })
}

const zeroTokens = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 })

/** Recursively collect Claude's main + subagent JSONL transcripts. Newer
 * Claude versions put subagent logs below a session directory; a one-level
 * scan silently under-counts them. */
async function claudeTranscriptFiles(projectsDir, since) {
  const stack = [projectsDir]
  const files = []
  let entries = 0
  let treeCapped = false
  while (stack.length && entries < CLAUDE_TREE_ENTRY_CAP) {
    const dir = stack.pop()
    let children
    try { children = await fsp.readdir(dir, { withFileTypes: true }) } catch { continue }
    for (const child of children) {
      entries += 1
      if (entries >= CLAUDE_TREE_ENTRY_CAP) { treeCapped = true; break }
      const full = path.join(dir, child.name)
      if (child.isDirectory()) { stack.push(full); continue }
      if (!child.isFile() || !child.name.endsWith('.jsonl')) continue
      try {
        const st = await fsp.stat(full)
        if (st.mtimeMs >= since) files.push({ full, mtime: st.mtimeMs, size: st.size })
      } catch { /* raced with cleanup */ }
    }
  }
  return { files, treeCapped }
}

function addClaudeUsage(acc, usage) {
  acc.input += Number(usage.input_tokens) || 0
  acc.output += Number(usage.output_tokens) || 0
  acc.cacheRead += Number(usage.cache_read_input_tokens) || 0
  acc.cacheWrite += Number(usage.cache_creation_input_tokens) || 0
}

/** Stream one transcript instead of readFileSync(JSONL). This bounds memory and
 * yields to Electron between filesystem reads. */
async function scanClaudeTranscript(full, onUsage) {
  const input = fs.createReadStream(full, { encoding: 'utf8' })
  const lines = readline.createInterface({ input, crlfDelay: Infinity })
  try {
    for await (const line of lines) {
      if (!line.includes('"usage"')) continue
      let ev
      try { ev = JSON.parse(line) } catch { continue }
      const usage = ev && ev.message && ev.message.usage
      if (usage) onUsage(ev, usage)
    }
  } finally {
    lines.close()
    input.destroy()
  }
}

/** Sum assistant-message token usage in <configDir>/projects over 5h / 7d. */
async function claudeUsage(configDir, now = Date.now()) {
  const base = configDir ? expandHome(configDir) : path.join(os.homedir(), '.claude')
  const projectsDir = path.join(base, 'projects')
  const H5 = now - 5 * 3600_000
  const D7 = now - 7 * 24 * 3600_000
  const fiveHour = zeroTokens()
  const week = zeroTokens()
  const seen = new Set()
  let lastActivity = 0

  const collected = await claudeTranscriptFiles(projectsDir, D7)
  if (!collected.files.length) {
    let exists = false
    try { exists = (await fsp.stat(projectsDir)).isDirectory() } catch { /* absent */ }
    return { ok: true, exists, fiveHour, week, lastActivity: 0, scannedFiles: 0, partial: collected.treeCapped }
  }

  const candidates = collected.files.sort((a, b) => b.mtime - a.mtime).slice(0, CLAUDE_FILE_CAP)
  const selected = []
  let bytes = 0
  for (const file of candidates) {
    // Always include the newest file, even if one exceptionally large active
    // transcript exceeds the aggregate cap by itself.
    if (selected.length && bytes + file.size > CLAUDE_TOTAL_BYTE_CAP) break
    selected.push(file)
    bytes += file.size
  }
  const partial = collected.treeCapped || collected.files.length > candidates.length || selected.length < candidates.length

  // Sequential streaming gives deterministic cross-file dedupe and avoids
  // opening hundreds of descriptors at once.
  for (const { full } of selected) {
    try {
      await scanClaudeTranscript(full, (ev, usage) => {
        const ts = Date.parse(ev.timestamp || '') || 0
        if (!ts || ts < D7) return
        // Retries and subagent mirrors can log the same request more than once.
        const id = `${(ev.message && ev.message.id) || ''}:${ev.requestId || ''}`
        if (id !== ':' && seen.has(id)) return
        if (id !== ':') seen.add(id)
        if (ts > lastActivity) lastActivity = ts
        addClaudeUsage(week, usage)
        if (ts >= H5) addClaudeUsage(fiveHour, usage)
      })
    } catch { /* one corrupt/raced transcript must not blank the whole meter */ }
  }
  return { ok: true, exists: true, fiveHour, week, lastActivity, scannedFiles: selected.length, partial }
}

// Per-session token sums, grouped by model (the $ chip on session cards).
async function claudeSessionUsage(configDir, sessionId) {
  if (!sessionId || /[/\\]/.test(sessionId)) return { ok: false }
  const base = configDir ? expandHome(configDir) : path.join(os.homedir(), '.claude')
  const projectsDir = path.join(base, 'projects')
  const seen = new Set()
  const models = new Map()
  let found = false
  let dirs = []
  try { dirs = await fsp.readdir(projectsDir, { withFileTypes: true }) } catch { return { ok: true, exists: false, models: [] } }
  for (const dir of dirs) {
    if (!dir.isDirectory()) continue
    const full = path.join(projectsDir, dir.name, `${sessionId}.jsonl`)
    try {
      await fsp.access(full)
      found = true
      await scanClaudeTranscript(full, (ev, usage) => {
        const id = `${(ev.message && ev.message.id) || ''}:${ev.requestId || ''}`
        if (id !== ':' && seen.has(id)) return
        if (id !== ':') seen.add(id)
        const model = (ev.message && ev.message.model) || 'unknown'
        const acc = models.get(model) || { model, ...zeroTokens() }
        addClaudeUsage(acc, usage)
        models.set(model, acc)
      })
    } catch { /* not in this project / raced */ }
  }
  return { ok: true, exists: found, models: [...models.values()] }
}

function registerUsageHandlers(ipcMain) {
  ipcMain.handle('usage:codex', async (_e, { codexHome } = {}) => codexUsage(codexHome))
  ipcMain.handle('usage:claude', async (_e, { configDir } = {}) => {
    try { return await claudeUsage(configDir) } catch (err) { return { ok: false, message: messageOf(err) } }
  })
  ipcMain.handle('usage:claudeSession', async (_e, { configDir, sessionId } = {}) => {
    try { return await claudeSessionUsage(configDir, sessionId) } catch (err) { return { ok: false, message: messageOf(err) } }
  })
}

module.exports = {
  registerUsageHandlers,
  // Focused probes/tests use the real parsers without booting Electron.
  codexUsage,
  codexRateLimitSnapshot,
  claudeUsage,
  claudeSessionUsage,
}
