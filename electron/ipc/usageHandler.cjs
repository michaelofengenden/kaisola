// Subscription limits at a click. Two very different sources, one IPC surface:
//
// • Codex — the CLI ships an app-server (JSON-RPC over stdio) whose
//   account/rateLimits/read returns the real rolling rate-limit state.
//
// • Claude — the pinned official Agent SDK exposes the structured data behind
//   `/usage` as an experimental, feature-detected control request. It does not
//   send a model prompt. A stable Claude Code status-line capture supplies the
//   official 5h/7d fields when that experimental control changes or is offline;
//   local JSONL token sums remain a secondary diagnostic only.
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
const { resolveBundledCodexExecutable, resolveBundledClaudeExecutable } = require('./nativeAgentPaths.cjs')

const CODEX_TIMEOUT_MS = 15_000
const CODEX_ERROR_TAIL = 1_200
const CLAUDE_FILE_CAP = 600 // most-recent transcript files scanned per account
const CLAUDE_TOTAL_BYTE_CAP = 512 * 1024 * 1024
const CLAUDE_TREE_ENTRY_CAP = 20_000
const CLAUDE_SDK_VERSION = '0.3.205'
const CLAUDE_LIMIT_CACHE_MS = 5 * 60_000
const CODEX_LIMIT_CACHE_MS = 60_000
const CLAUDE_LIMIT_TIMEOUT_MS = 15_000
const CLAUDE_STATUS_READ_CAP = 768 * 1024

// Exact reads are serialized globally: each one briefly launches the bundled
// Claude Code control process, and starting several account probes at once is a
// needless memory spike. Per-account cache entries retain the last good result.
const claudeLimitCache = new Map()
const codexLimitCache = new Map()
const knownClaudeConfigs = new Map()
let claudeReadQueue = Promise.resolve()
let claudeRefreshTimer = null

const expandHome = (p) => (typeof p === 'string' ? p.replace(/^~(?=\/|$)/, os.homedir()) : p)
const messageOf = (err) => String((err && err.message) || err || 'Unknown error')
const tail = (text, cap = CODEX_ERROR_TAIL) => text.slice(-cap).trim()

const claudeBase = (configDir) => path.resolve(
  configDir && typeof configDir === 'string' && configDir.trim()
    ? expandHome(configDir.trim())
    : path.join(os.homedir(), '.claude'),
)

const finite = (value, min = 0, max = Number.MAX_SAFE_INTEGER) => {
  if (value == null || value === '') return null
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) && n >= min && n <= max ? n : null
}

const percent = (value) => finite(value, 0, 100)

const resetEpoch = (value) => {
  if (typeof value === 'string') {
    const millis = Date.parse(value)
    return Number.isFinite(millis) ? Math.floor(millis / 1000) : null
  }
  const n = finite(value, 0)
  // Status-line values are epoch seconds; tolerate milliseconds defensively.
  return n == null ? null : Math.floor(n > 10_000_000_000 ? n / 1000 : n)
}

function normalizeClaudeWindow(raw, utilizationKey = 'utilization', resetKey = 'resets_at') {
  if (!raw || typeof raw !== 'object') return null
  const usedPercent = percent(raw[utilizationKey])
  const resetsAt = resetEpoch(raw[resetKey])
  if (usedPercent == null && resetsAt == null) return null
  return {
    ...(usedPercent == null ? {} : { usedPercent }),
    ...(resetsAt == null ? {} : { resetsAt }),
  }
}

/** Validate the SDK's deliberately experimental shape before it crosses IPC. */
function normalizeClaudeSdkUsage(raw, now = Date.now()) {
  if (!raw || typeof raw !== 'object') throw new Error('Claude Agent SDK returned an invalid usage response.')
  if (typeof raw.rate_limits_available !== 'boolean') throw new Error('Claude Agent SDK usage response is missing rate_limits_available.')
  if (raw.subscription_type != null && typeof raw.subscription_type !== 'string') throw new Error('Claude Agent SDK returned an invalid subscription type.')
  const limits = raw.rate_limits && typeof raw.rate_limits === 'object' ? raw.rate_limits : null
  const modelScoped = []
  if (Array.isArray(limits && limits.model_scoped)) {
    for (const row of limits.model_scoped.slice(0, 24)) {
      if (!row || typeof row !== 'object' || typeof row.display_name !== 'string') continue
      const label = row.display_name.trim().slice(0, 80)
      if (!label) continue
      const win = normalizeClaudeWindow(row)
      if (win) modelScoped.push({ label, ...win })
    }
  }
  // Older server responses expose named model windows instead of model_scoped.
  for (const [key, label] of [['seven_day_opus', 'Opus'], ['seven_day_sonnet', 'Sonnet']]) {
    const win = normalizeClaudeWindow(limits && limits[key])
    if (win && !modelScoped.some((row) => row.label.toLowerCase() === label.toLowerCase())) modelScoped.push({ label, ...win })
  }

  let extraUsage = null
  if (limits && limits.extra_usage && typeof limits.extra_usage === 'object') {
    const extra = limits.extra_usage
    if (typeof extra.is_enabled === 'boolean') {
      const monthlyLimit = finite(extra.monthly_limit, 0)
      const usedCredits = finite(extra.used_credits, 0)
      const utilization = percent(extra.utilization)
      extraUsage = {
        enabled: extra.is_enabled,
        ...(monthlyLimit == null ? {} : { monthlyLimit }),
        ...(usedCredits == null ? {} : { usedCredits }),
        ...(utilization == null ? {} : { utilization }),
        ...(typeof extra.currency === 'string' && extra.currency.trim() ? { currency: extra.currency.trim().slice(0, 12) } : {}),
      }
    }
  }

  return {
    ok: true,
    source: 'agent-sdk',
    sourceLabel: `Claude Agent SDK ${CLAUDE_SDK_VERSION}`,
    experimental: true,
    updatedAt: now,
    subscriptionType: raw.subscription_type || undefined,
    rateLimitsAvailable: raw.rate_limits_available,
    limits: {
      fiveHour: normalizeClaudeWindow(limits && limits.five_hour),
      sevenDay: normalizeClaudeWindow(limits && limits.seven_day),
      modelScoped,
      extraUsage,
    },
  }
}

/** Stable official fallback captured from Claude Code's documented statusLine
 * JSON after a real response. It contains 5h/7d only, not per-model buckets. */
function normalizeClaudeStatusLine(raw, now = Date.now()) {
  if (!raw || typeof raw !== 'object' || !raw.rate_limits || typeof raw.rate_limits !== 'object') return null
  const fiveHour = normalizeClaudeWindow(raw.rate_limits.five_hour, 'used_percentage', 'resets_at')
  const sevenDay = normalizeClaudeWindow(raw.rate_limits.seven_day, 'used_percentage', 'resets_at')
  if (!fiveHour && !sevenDay) return null
  return {
    ok: true,
    source: 'status-line',
    sourceLabel: 'Claude Code status line',
    experimental: false,
    updatedAt: finite(raw.__kaisolaCapturedAt, 0) || now,
    rateLimitsAvailable: true,
    limits: { fiveHour, sevenDay, modelScoped: [], extraUsage: null },
  }
}

async function readClaudeStatusLine(base, options = {}) {
  const cachePath = options.statusCachePath || process.env.KAISOLA_CLAUDE_STATUS_CACHE
  if (!cachePath) return null
  let handle
  try {
    handle = await fsp.open(cachePath, 'r')
    const st = await handle.stat()
    const length = Math.min(st.size, CLAUDE_STATUS_READ_CAP)
    if (!length) return null
    const buf = Buffer.alloc(length)
    await handle.read(buf, 0, length, st.size - length)
    const lines = buf.toString('utf8').split('\n')
    if (st.size > length) lines.shift() // began in the middle of a JSON line
    const projectsRoot = path.join(base, 'projects') + path.sep
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      let row
      try {
        const tab = lines[i].indexOf('\t')
        const capturedSeconds = tab > 0 ? finite(lines[i].slice(0, tab), 0) : null
        row = JSON.parse(tab > 0 ? lines[i].slice(tab + 1) : lines[i])
        if (capturedSeconds != null) row.__kaisolaCapturedAt = capturedSeconds * 1000
      } catch { continue }
      const transcript = typeof row.transcript_path === 'string' ? path.resolve(expandHome(row.transcript_path)) : ''
      if (!transcript.startsWith(projectsRoot)) continue
      const normalized = normalizeClaudeStatusLine(row)
      if (normalized) return normalized
    }
  } catch { /* no captured status line yet */ } finally {
    try { await handle?.close() } catch { /* already closed */ }
  }
  return null
}

function claudeSdkEnvironment(base, envOverride) {
  const env = { ...(envOverride || agentEnv()) }
  // The meter is specifically for a claude.ai subscription. Do not let an API
  // or third-party-provider variable shadow the selected CLAUDE_CONFIG_DIR.
  for (const key of [
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_CUSTOM_HEADERS',
    'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR',
    'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
  ]) delete env[key]
  env.CLAUDE_CONFIG_DIR = base
  env.CLAUDE_AGENT_SDK_CLIENT_APP = `kaisola/${CLAUDE_SDK_VERSION}`
  env.CLAUDE_CODE_DISABLE_AUTO_MEMORY = '1'
  env.CLAUDE_CODE_DISABLE_BUNDLED_SKILLS = '1'
  return env
}

/** Launch a control-only SDK session. The async prompt never yields, so no API
 * request/model turn occurs; only initialization + get_usage are sent. */
async function readClaudeSdkUsage(base, options = {}) {
  const sdk = options.sdk || await import('@anthropic-ai/claude-agent-sdk')
  if (!sdk || typeof sdk.query !== 'function') throw new Error('Claude Agent SDK is unavailable.')
  const abortController = new AbortController()
  let releaseInput
  async function* idleInput() {
    await new Promise((resolve) => {
      releaseInput = resolve
      abortController.signal.addEventListener('abort', resolve, { once: true })
    })
  }
  const query = sdk.query({
    prompt: idleInput(),
    options: {
      abortController,
      cwd: base,
      env: claudeSdkEnvironment(base, options.env),
      tools: [],
      allowedTools: [],
      disallowedTools: ['Bash', 'Edit', 'Write', 'Read', 'Glob', 'Grep', 'WebFetch', 'WebSearch', 'Agent'],
      mcpServers: {},
      strictMcpConfig: true,
      settingSources: [],
      settings: {
        disableAllHooks: true,
        disableBundledSkills: true,
        disableClaudeAiConnectors: true,
        disableAgentView: true,
        disableRemoteControl: true,
        disableWorkflows: true,
        disableArtifact: true,
        disableSkillShellExecution: true,
      },
      plugins: [],
      skills: [],
      persistSession: false,
      permissionMode: 'plan',
      includePartialMessages: false,
      includeHookEvents: false,
      promptSuggestions: false,
      agentProgressSummaries: false,
      stderr: () => {},
      // Electron can read JS from app.asar, but macOS cannot spawn a native
      // executable through that virtual path. Point the SDK at the verified
      // electron-builder unpacked payload explicitly.
      pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable || resolveBundledClaudeExecutable() || undefined,
    },
  })
  const timeoutMs = options.timeoutMs || CLAUDE_LIMIT_TIMEOUT_MS
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      abortController.abort()
      reject(new Error('Claude subscription usage timed out.'))
    }, timeoutMs)
    timer.unref?.()
  })
  try {
    await Promise.race([query.initializationResult(), timeout])
    const method = query.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET
    if (typeof method !== 'function') throw new Error('This Claude Agent SDK version does not expose structured usage.')
    const raw = await Promise.race([method.call(query), timeout])
    return normalizeClaudeSdkUsage(raw, options.now || Date.now())
  } finally {
    if (timer) clearTimeout(timer)
    abortController.abort()
    try { releaseInput?.() } catch { /* already released */ }
    try { query.close() } catch { /* already closed */ }
  }
}

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
      const codexCommand = options.command || resolveBundledCodexExecutable() || 'codex'
      proc = spawnImpl(codexCommand, ['-s', 'read-only', '-a', 'untrusted', 'app-server'], {
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

/** Bound startup-prime/panel-open churn to one app-server process per account.
 * Manual refresh bypasses the short value cache but still shares an in-flight
 * read, so rapid clicks cannot multiply 15-second process trees. */
async function codexSubscriptionUsage(codexHome, options = {}) {
  const key = codexHome ? path.resolve(expandHome(codexHome)) : '__default__'
  const now = options.now || Date.now()
  const cached = codexLimitCache.get(key)
  if (cached?.inFlight) return cached.inFlight
  if (!options.force && cached && now - cached.refreshedAt < CODEX_LIMIT_CACHE_MS) return cached.value
  const reader = options.reader || codexUsage
  const inFlight = Promise.resolve(reader(codexHome, options.readerOptions || {}))
  codexLimitCache.set(key, { ...cached, inFlight })
  try {
    const value = await inFlight
    codexLimitCache.set(key, { value, refreshedAt: now, inFlight: null })
    return value
  } catch (err) {
    const value = { ok: false, message: messageOf(err) }
    codexLimitCache.set(key, { value, refreshedAt: now, inFlight: null })
    return value
  }
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
  const base = claudeBase(configDir)
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

const hasExactClaudeWindows = (value) => Boolean(value && value.limits && (value.limits.fiveHour || value.limits.sevenDay || value.limits.modelScoped?.length))

function withClaudeActivity(value, activity) {
  if (!activity) return value
  return {
    ...value,
    exists: activity.exists,
    // Keep these fields for existing session-card callers while the usage panel
    // consumes the explicitly secondary `activity` object.
    fiveHour: activity.fiveHour,
    week: activity.week,
    lastActivity: activity.lastActivity,
    scannedFiles: activity.scannedFiles,
    partial: activity.partial,
    activity: {
      fiveHour: activity.fiveHour,
      week: activity.week,
      lastActivity: activity.lastActivity,
      scannedFiles: activity.scannedFiles,
      partial: activity.partial,
    },
  }
}

function enqueueClaudeRead(task) {
  const run = claudeReadQueue.catch(() => {}).then(task)
  claudeReadQueue = run.catch(() => {})
  return run
}

function ensureClaudeRefreshTimer() {
  if (claudeRefreshTimer || process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE) return
  claudeRefreshTimer = setInterval(() => {
    for (const configDir of knownClaudeConfigs.values()) {
      // Refresh the exact lightweight control data. Transcript activity is
      // disk-heavy and only rescans when the human opens/refreshes the panel.
      void claudeSubscriptionUsage(configDir, { force: true, background: true })
    }
  }, CLAUDE_LIMIT_CACHE_MS)
  claudeRefreshTimer.unref?.()
}

/** One account's exact Claude plan limits plus optional local diagnostics. */
async function claudeSubscriptionUsage(configDir, options = {}) {
  const base = claudeBase(configDir)
  const key = base
  knownClaudeConfigs.set(key, configDir)
  ensureClaudeRefreshTimer()
  const now = options.now || Date.now()
  const cached = claudeLimitCache.get(key)
  if (!options.force && cached && now - cached.refreshedAt < CLAUDE_LIMIT_CACHE_MS) {
    // Startup asks only for exact plan windows. Defer the potentially huge
    // transcript diagnostic until the human actually opens the panel.
    if (!options.background && !cached.activity) {
      let activity = null
      try { activity = await claudeUsage(configDir, now) } catch { /* diagnostic only */ }
      if (activity) {
        const value = withClaudeActivity(cached.value, activity)
        claudeLimitCache.set(key, { ...cached, value, activity })
        return value
      }
    }
    return cached.value
  }

  return enqueueClaudeRead(async () => {
    // A same-account request may have filled the cache while this request sat
    // behind another config directory in the global queue.
    const latest = claudeLimitCache.get(key)
    if (!options.force && latest && now - latest.refreshedAt < CLAUDE_LIMIT_CACHE_MS) return latest.value

    let sdkValue = null
    let sdkError = null
    try {
      sdkValue = await readClaudeSdkUsage(base, { ...options, now })
    } catch (err) {
      sdkError = messageOf(err)
    }

    let statusValue = null
    // Prefer stable status-line data when the experimental SDK returns a valid
    // response but no claude.ai limits (e.g. a transient auth/profile-scope gap).
    if (!hasExactClaudeWindows(sdkValue)) statusValue = await readClaudeStatusLine(base, options)

    let exact = hasExactClaudeWindows(sdkValue) ? sdkValue : statusValue
    const lastKnownGood = latest && latest.lastKnownGood
    if (!exact && lastKnownGood) {
      exact = {
        ...lastKnownGood,
        stale: true,
        refreshError: sdkError || sdkValue?.message || 'Claude returned no plan limit windows.',
      }
    }

    let activity = latest && latest.activity
    if (!options.background) {
      try { activity = await claudeUsage(configDir, now) } catch { /* diagnostic only */ }
    }

    let value
    if (exact) {
      const age = Math.max(0, now - (exact.updatedAt || now))
      value = withClaudeActivity({
        ...exact,
        stale: exact.stale === true || age > CLAUDE_LIMIT_CACHE_MS,
        ...(sdkError && exact.source !== 'agent-sdk' ? { refreshError: sdkError } : {}),
      }, activity)
    } else if (sdkValue) {
      value = withClaudeActivity({
        ...sdkValue,
        source: 'agent-sdk',
        sourceLabel: `Claude Agent SDK ${CLAUDE_SDK_VERSION}`,
        message: sdkValue.rateLimitsAvailable
          ? 'Claude returned no subscription windows yet.'
          : 'Plan limits are unavailable for this Claude account. Sign in with a Claude.ai subscription or complete one Claude response.',
      }, activity)
    } else {
      value = withClaudeActivity({
        ok: Boolean(activity),
        source: activity ? 'transcripts' : 'unavailable',
        sourceLabel: activity ? 'Local transcripts only' : 'Unavailable',
        rateLimitsAvailable: false,
        updatedAt: now,
        message: sdkError || 'Claude plan limits are not available yet.',
      }, activity)
    }

    const lkg = hasExactClaudeWindows(value) && !value.stale ? value : lastKnownGood
    claudeLimitCache.set(key, { value, refreshedAt: now, lastKnownGood: lkg, activity })
    return value
  })
}

// Per-session token sums, grouped by model (the $ chip on session cards).
async function claudeSessionUsage(configDir, sessionId) {
  if (!sessionId || /[/\\]/.test(sessionId)) return { ok: false }
  const base = claudeBase(configDir)
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
  ipcMain.handle('usage:codex', async (_e, { codexHome, force } = {}) => codexSubscriptionUsage(codexHome, { force: force === true }))
  ipcMain.handle('usage:claude', async (_e, { configDir, force, exactOnly } = {}) => {
    try { return await claudeSubscriptionUsage(configDir, { force: force === true, background: exactOnly === true }) } catch (err) { return { ok: false, message: messageOf(err) } }
  })
  ipcMain.handle('usage:claudeSession', async (_e, { configDir, sessionId } = {}) => {
    try { return await claudeSessionUsage(configDir, sessionId) } catch (err) { return { ok: false, message: messageOf(err) } }
  })
}

module.exports = {
  registerUsageHandlers,
  // Focused probes/tests use the real parsers without booting Electron.
  codexUsage,
  codexSubscriptionUsage,
  codexRateLimitSnapshot,
  claudeUsage,
  claudeSubscriptionUsage,
  claudeSessionUsage,
  readClaudeSdkUsage,
  readClaudeStatusLine,
  normalizeClaudeSdkUsage,
  normalizeClaudeStatusLine,
  _clearClaudeUsageCacheForTests() {
    claudeLimitCache.clear()
    codexLimitCache.clear()
    knownClaudeConfigs.clear()
    claudeReadQueue = Promise.resolve()
  },
}
