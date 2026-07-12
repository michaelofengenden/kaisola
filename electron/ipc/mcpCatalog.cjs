// External MCP servers — the catalog every agent session draws from.
//
// Two scopes, both the ecosystem's standard shapes:
//   project  <workspace>/.mcp.json      (Claude Code's project scope — repos
//            already configured for Claude/Cursor/VS Code just work)
//   user     <userData>/mcp-servers.json (added in Kaisola, follows you across
//            projects; `disabled: []` holds the toggled-off names)
//
// TRUST GATE (MCP 2025-06-18 consent guidance): a project file arrives with
// the repo — its servers are listed but NEVER armed until the human approves
// them once per workspace. Approval is keyed to a hash of the server's spec,
// so an edited entry (new command, new url) re-requires approval. User-scope
// servers were added deliberately in-app and default to enabled.
//
// Consumers:
//   acpHandler  → acpEntries(cwd, caps): ACP session/new mcpServers wire shapes
//   mcpServer   → claudeUserEntries(): the user servers merged into the
//                 generated `claude --mcp-config` file (the claude terminal
//                 reads the project .mcp.json natively — no merge needed there)
//   renderer    → mcp:servers / mcp:server-set / mcp:server-probe IPC
const fs = require('node:fs')
const path = require('node:path')
const http = require('node:http')
const https = require('node:https')
const crypto = require('node:crypto')
const { app, BrowserWindow } = require('electron')

const PROBE_TIMEOUT_MS = 3500
const PROBE_CACHE_MS = 30_000
const MAX_SERVERS_PER_SCOPE = 24

// ── config files ─────────────────────────────────────────────────────────────
const userConfigPath = () => path.join(app.getPath('userData'), 'mcp-servers.json')
const approvalsPath = () => path.join(app.getPath('userData'), 'mcp-approvals.json')
const projectConfigPath = (workspace) => path.join(workspace, '.mcp.json')

function readJson(file) {
  try {
    return { data: JSON.parse(fs.readFileSync(file, 'utf8')), error: null, exists: true }
  } catch (err) {
    const missing = err && err.code === 'ENOENT'
    return { data: null, error: missing ? null : `Invalid JSON in ${path.basename(file)}: ${String(err.message || err)}`, exists: !missing }
  }
}
function writePrivateJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const json = JSON.stringify(data, null, 2)
  const temp = `${file}.tmp.${process.pid}.${Date.now()}.${crypto.randomBytes(4).toString('hex')}`
  try {
    fs.writeFileSync(temp, json, { mode: 0o600 })
    // An existing file can have inherited permissive bits; rename preserves the
    // freshly-created temp file's private mode on POSIX.
    try { fs.chmodSync(temp, 0o600) } catch { /* Windows / restrictive FS */ }
    fs.renameSync(temp, file)
    try { fs.chmodSync(file, 0o600) } catch { /* Windows / restrictive FS */ }
  } catch (err) {
    try { fs.unlinkSync(temp) } catch { /* no temp / already renamed */ }
    throw err
  }
}

// ── spec normalization ───────────────────────────────────────────────────────
/** Expand ${VAR} from the process env (Claude Code's .mcp.json convention). */
function expandEnv(value) {
  return typeof value === 'string'
    ? value.replace(/\$\{([A-Z0-9_]+)\}/gi, (_, k) => process.env[k] ?? '')
    : value
}

/**
 * Normalize one raw server spec into { kind, command, args, env } (stdio) or
 * { kind, url, headers } (http/sse). Returns null for unusable entries.
 */
function normalizeSpec(raw) {
  if (!raw || typeof raw !== 'object') return null
  // Manual user/project configs share the same plaintext-secret boundary as
  // install links. The file is preserved verbatim, but unsafe entries are not
  // surfaced, armed, or copied into agent sessions. ${NAME} references remain
  // valid; env/header references expand only in the in-memory representation.
  if (containsLiteralSecret(raw)) return null
  if (typeof raw.url === 'string' && raw.url) {
    let parsed
    try { parsed = new URL(raw.url) } catch { return null }
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    const kind = raw.type === 'sse' ? 'sse' : 'http'
    const headers = {}
    if (raw.headers && typeof raw.headers === 'object' && !Array.isArray(raw.headers)) {
      for (const [k, v] of Object.entries(raw.headers).slice(0, 32)) {
        if (/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(k) && typeof v === 'string' && v.length <= 4096) headers[k] = expandEnv(v)
      }
    }
    return { kind, url: parsed.toString(), headers }
  }
  if (typeof raw.command === 'string' && raw.command.trim() && raw.command.length <= 512) {
    const env = {}
    if (raw.env && typeof raw.env === 'object' && !Array.isArray(raw.env)) {
      for (const [k, v] of Object.entries(raw.env).slice(0, 32)) {
        if (/^[A-Z_][A-Z0-9_]{0,127}$/i.test(k) && typeof v === 'string' && v.length <= 4096) env[k] = expandEnv(v)
      }
    }
    return {
      kind: 'stdio',
      command: expandEnv(raw.command.trim()),
      args: Array.isArray(raw.args) ? raw.args.filter((a) => typeof a === 'string' && a.length <= 4096).slice(0, 64).map(expandEnv) : [],
      env,
    }
  }
  return null
}

/** Stable hash of a spec — the approval key ingredient (edits re-prompt). */
function specHash(spec) {
  const canon = spec.kind === 'stdio'
    ? ['stdio', spec.command, ...spec.args, ...Object.entries(spec.env).sort(([a], [b]) => a.localeCompare(b)).flat()]
    : [spec.kind, spec.url, ...Object.entries(spec.headers).sort(([a], [b]) => a.localeCompare(b)).flat()]
  return crypto.createHash('sha256').update(JSON.stringify(canon)).digest('hex').slice(0, 24)
}

function parseServers(configData) {
  const out = []
  const map = configData && typeof configData === 'object' ? configData.mcpServers : null
  if (!map || typeof map !== 'object' || Array.isArray(map)) return out
  for (const [name, raw] of Object.entries(map).slice(0, MAX_SERVERS_PER_SCOPE)) {
    // 'kaisola' is the built-in server's reserved name — never shadowed
    if (!name || name === 'kaisola') continue
    const spec = normalizeSpec(raw)
    if (spec) out.push({ name, spec })
  }
  return out
}

// ── approvals (project scope) ────────────────────────────────────────────────
const canonicalWorkspace = (workspace) => {
  try { return fs.realpathSync.native(path.resolve(workspace)) } catch { return path.resolve(workspace) }
}
const approvalKey = (workspace, name) => `${canonicalWorkspace(workspace)}\u0000${name}`

function readApprovals() {
  const { data } = readJson(approvalsPath())
  return data && typeof data === 'object' && !Array.isArray(data) ? data : {}
}
function approved(workspace, name, hash) {
  return readApprovals()[approvalKey(workspace, name)] === hash
}
function setApproval(workspace, name, hash) {
  const all = readApprovals()
  if (hash) all[approvalKey(workspace, name)] = hash
  else delete all[approvalKey(workspace, name)]
  writePrivateJson(approvalsPath(), all)
}

// ── the assembled catalog ────────────────────────────────────────────────────
/** Every configured server for a workspace, with its enable/trust state. */
function listServers(workspace) {
  const userCfg = readJson(userConfigPath())
  const disabled = new Set(
    userCfg.data && Array.isArray(userCfg.data.disabled) ? userCfg.data.disabled.filter((n) => typeof n === 'string') : [],
  )
  const rows = []
  for (const { name, spec } of parseServers(userCfg.data)) {
    rows.push({
      name,
      scope: 'user',
      kind: spec.kind,
      enabled: !disabled.has(name),
      approved: true,
      detail: spec.kind === 'stdio' ? [spec.command, ...spec.args].join(' ') : spec.url,
    })
  }
  let projectError = null
  if (workspace) {
    const projCfg = readJson(projectConfigPath(workspace))
    projectError = projCfg.error
    for (const { name, spec } of parseServers(projCfg.data)) {
      if (rows.some((r) => r.name === name)) continue // user scope wins a name clash
      const hash = specHash(spec)
      const ok = approved(workspace, name, hash)
      rows.push({
        name,
        scope: 'project',
        kind: spec.kind,
        enabled: ok,
        approved: ok,
        detail: spec.kind === 'stdio' ? [spec.command, ...spec.args].join(' ') : spec.url,
      })
    }
  }
  return { servers: rows, userError: userCfg.error, projectError, userConfigPath: userConfigPath() }
}

/** The armed (enabled + approved) specs for a workspace, keyed by name. */
function armedSpecs(workspace) {
  const userCfg = readJson(userConfigPath())
  const disabled = new Set(
    userCfg.data && Array.isArray(userCfg.data.disabled) ? userCfg.data.disabled.filter((n) => typeof n === 'string') : [],
  )
  const armed = new Map()
  for (const { name, spec } of parseServers(userCfg.data)) {
    if (!disabled.has(name)) armed.set(name, spec)
  }
  if (workspace) {
    for (const { name, spec } of parseServers(readJson(projectConfigPath(workspace)).data)) {
      if (!armed.has(name) && approved(workspace, name, specHash(spec))) armed.set(name, spec)
    }
  }
  return armed
}

const toPairs = (obj) => Object.entries(obj).map(([name, value]) => ({ name, value }))

/**
 * ACP session/new wire entries for the armed servers.
 * caps = { http, sse } from the agent's initialize response — remote entries
 * only ride when the agent declared it can dial them; stdio always can.
 */
function acpEntries(workspace, caps = {}) {
  const out = []
  for (const [name, spec] of armedSpecs(workspace)) {
    if (spec.kind === 'stdio') {
      out.push({ name, command: spec.command, args: spec.args, env: toPairs(spec.env) })
    } else if (spec.kind === 'http' ? caps.http : caps.sse) {
      out.push({ type: spec.kind, name, url: spec.url, headers: toPairs(spec.headers) })
    }
  }
  return out
}

/**
 * User-scope servers in `claude --mcp-config` object-map shape, merged into
 * the generated kaisola-mcp.json (mcpServer.cjs). Project .mcp.json is NOT
 * merged — the claude CLI reads it natively with its own approval prompt.
 */
function claudeEntriesFromConfig(configData) {
  const entries = {}
  const disabled = new Set(
    configData && Array.isArray(configData.disabled) ? configData.disabled.filter((n) => typeof n === 'string') : [],
  )
  const map = configData && typeof configData === 'object' && configData.mcpServers && typeof configData.mcpServers === 'object' && !Array.isArray(configData.mcpServers)
    ? configData.mcpServers
    : {}
  for (const [name, raw] of Object.entries(map).slice(0, MAX_SERVERS_PER_SCOPE)) {
    if (!name || name === 'kaisola' || disabled.has(name)) continue
    // Claude understands ${NAME} placeholders itself. Preserve the sanitized
    // raw form here so its generated --mcp-config never materializes a secret
    // from Kaisola's process environment onto disk.
    const spec = sanitizeRaw(raw)
    if (!spec) continue
    entries[name] = spec.command
      ? { command: spec.command, ...(spec.args && spec.args.length ? { args: spec.args } : {}), ...(spec.env && Object.keys(spec.env).length ? { env: spec.env } : {}) }
      : { type: spec.type === 'sse' ? 'sse' : 'http', url: spec.url, ...(spec.headers && Object.keys(spec.headers).length ? { headers: spec.headers } : {}) }
  }
  return entries
}

function claudeUserEntries() {
  return claudeEntriesFromConfig(readJson(userConfigPath()).data)
}

// ── health probe (remote servers only) ───────────────────────────────────────
function parseRpcBody(body, contentType) {
  if (!body.trim()) return null
  if (/text\/event-stream/i.test(contentType || '')) {
    const messages = body.split(/\r?\n\r?\n/)
      .flatMap((event) => event.split(/\r?\n/).filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()))
      .filter((line) => line && line !== '[DONE]')
    if (!messages.length) return null
    return JSON.parse(messages[messages.length - 1])
  }
  return JSON.parse(body)
}

function rpcPost(url, headers, payload, { sessionId, protocolVersion } = {}) {
  return new Promise((resolve) => {
    let u
    try { u = new URL(url) } catch { return resolve({ ok: false, message: 'invalid url' }) }
    const lib = u.protocol === 'https:' ? https : http
    const req = lib.request(
      u,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json, text/event-stream',
          ...(sessionId ? { 'Mcp-Session-Id': sessionId } : {}),
          ...(protocolVersion ? { 'MCP-Protocol-Version': protocolVersion } : {}),
          ...headers,
        },
      },
      (res) => {
        let body = ''
        res.on('data', (c) => {
          body += c
          if (body.length > 200_000) req.destroy(new Error('response too large'))
        })
        res.on('end', () => {
          if (!res.statusCode || res.statusCode >= 400) return resolve({ ok: false, message: `HTTP ${res.statusCode}` })
          try {
            resolve({
              ok: true,
              json: parseRpcBody(body, res.headers['content-type']),
              sessionId: typeof res.headers['mcp-session-id'] === 'string' ? res.headers['mcp-session-id'] : sessionId,
            })
          } catch { resolve({ ok: false, message: /text\/event-stream/i.test(res.headers['content-type'] || '') ? 'invalid SSE reply' : 'non-JSON reply' }) }
        })
      },
    )
    req.setTimeout(PROBE_TIMEOUT_MS, () => req.destroy(new Error('timeout')))
    req.on('error', (err) => resolve({ ok: false, message: String((err && err.message) || err) }))
    req.end(JSON.stringify(payload))
  })
}

/** initialize + tools/list against a remote server — the popover's health dot. */
async function probeServer(workspace, name) {
  const spec = armedSpecs(workspace).get(name) ?? specByName(workspace, name)
  if (!spec) return { ok: false, message: 'unknown server' }
  if (spec.kind === 'stdio') return { ok: true, kind: 'stdio', status: 'configured', verified: false, message: 'configured — starts inside a new agent session' }
  if (spec.kind === 'sse') return { ok: true, kind: 'sse', status: 'configured', verified: false, message: 'configured — legacy SSE is verified only when an agent session connects' }
  const init = await rpcPost(spec.url, spec.headers, {
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'kaisola', version: app.getVersion() } },
  })
  if (!init.ok) return { ok: false, kind: spec.kind, message: init.message }
  const serverInfo = init.json && init.json.result && init.json.result.serverInfo
  const protocolVersion = init.json && init.json.result && init.json.result.protocolVersion || '2025-06-18'
  const initialized = await rpcPost(
    spec.url,
    spec.headers,
    { jsonrpc: '2.0', method: 'notifications/initialized', params: {} },
    { sessionId: init.sessionId, protocolVersion },
  )
  if (!initialized.ok) return { ok: false, kind: spec.kind, message: initialized.message }
  const tools = await rpcPost(
    spec.url,
    spec.headers,
    { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} },
    { sessionId: init.sessionId, protocolVersion },
  )
  if (!tools.ok) return { ok: false, kind: spec.kind, message: tools.message }
  const toolCount = tools.ok && tools.json && tools.json.result && Array.isArray(tools.json.result.tools)
    ? tools.json.result.tools.length
    : undefined
  return { ok: true, kind: spec.kind, status: 'ready', verified: true, serverName: serverInfo && serverInfo.name, version: serverInfo && serverInfo.version, toolCount }
}

const probeCache = new Map()
const probeInFlight = new Map()
let probeRevision = 0
async function cachedProbeServer(workspace, name, force = false) {
  const key = `${canonicalWorkspace(workspace || '')}\u0000${name}`
  const cached = probeCache.get(key)
  if (!force && cached && Date.now() - cached.at < PROBE_CACHE_MS) return { ...cached.result, cached: true }
  if (!force && probeInFlight.has(key)) return probeInFlight.get(key)
  const revision = probeRevision
  const task = probeServer(workspace, name).then((raw) => {
    const result = raw.ok ? raw : { ...raw, status: 'failed', verified: true }
    if (revision === probeRevision) probeCache.set(key, { at: Date.now(), result })
    return result
  }).finally(() => { if (probeInFlight.get(key) === task) probeInFlight.delete(key) })
  probeInFlight.set(key, task)
  return task
}

/** Find a spec across both scopes regardless of armed state (probe-before-approve). */
function specByName(workspace, name) {
  for (const { name: n, spec } of parseServers(readJson(userConfigPath()).data)) {
    if (n === name) return spec
  }
  if (workspace) {
    for (const { name: n, spec } of parseServers(readJson(projectConfigPath(workspace)).data)) {
      if (n === name) return spec
    }
  }
  return null
}

// ── mutations ────────────────────────────────────────────────────────────────
const changeListeners = new Set()
function onChange(fn) { changeListeners.add(fn); return () => changeListeners.delete(fn) }
function emitChange() {
  probeRevision += 1
  probeCache.clear()
  probeInFlight.clear()
  for (const fn of changeListeners) { try { fn() } catch { /* listener's problem */ } }
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.webContents.isDestroyed()) w.webContents.send('mcp:servers-changed')
  }
}

/** Enable/disable (user scope) or approve/revoke (project scope) one server. */
function setServerEnabled(workspace, scope, name, enabled) {
  if (scope === 'user') {
    const loaded = readJson(userConfigPath())
    if (loaded.error) return { ok: false, message: loaded.error }
    const cfg = loaded.data ?? {}
    const disabled = new Set(Array.isArray(cfg.disabled) ? cfg.disabled : [])
    if (enabled) disabled.delete(name)
    else disabled.add(name)
    writePrivateJson(userConfigPath(), { ...cfg, mcpServers: cfg.mcpServers ?? {}, disabled: [...disabled] })
  } else {
    if (!workspace) return { ok: false, message: 'no workspace' }
    const spec = specByName(workspace, name)
    if (!spec) return { ok: false, message: 'unknown server' }
    setApproval(workspace, name, enabled ? specHash(spec) : null)
  }
  emitChange()
  return { ok: true }
}

// ── discovery: import servers already configured in sibling apps ─────────────
// Continue.dev's onboarding pattern: the user very likely configured MCP
// servers in Cursor / Claude Desktop / the Claude CLI already — offer those
// instead of making them re-type. Imports are SANITIZED RAW (never env-
// expanded: baking ${VAR} secrets into our config file would leak them) and
// arrive DISABLED — nothing arms without an explicit per-server toggle.
function parseTomlScalar(raw) {
  const value = String(raw || '').trim()
  if (!value) return undefined
  if (value.startsWith('"')) {
    try { return JSON.parse(value) } catch { return undefined }
  }
  if (value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1)
  if (value === 'true') return true
  if (value === 'false') return false
  if (value.startsWith('[') && value.endsWith(']')) {
    try {
      const parsed = JSON.parse(value)
      return Array.isArray(parsed) && parsed.every((item) => typeof item === 'string') ? parsed : undefined
    } catch { return undefined }
  }
  return undefined
}

/** Minimal, bounded parser for Codex's documented [mcp_servers.*] TOML shape.
 * It deliberately ignores the rest of config.toml and unsupported TOML
 * syntax; we only need strings, string arrays, booleans, and nested env/header
 * tables to safely discover existing servers. */
function parseCodexMcpToml(text) {
  const mcpServers = {}
  let active = null
  let section = null
  const sectionRe = /^\[mcp_servers\.("(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+)(?:\.(env|http_headers|env_http_headers))?\]$/
  for (const rawLine of String(text || '').slice(0, 1_000_000).split(/\r?\n/).slice(0, 20_000)) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue
    const header = line.match(sectionRe)
    if (header) {
      const parsedName = parseTomlScalar(header[1])
      active = typeof parsedName === 'string' ? parsedName : header[1]
      section = header[2] || null
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(active)) { active = null; continue }
      mcpServers[active] ??= {}
      continue
    }
    if (line.startsWith('[')) { active = null; section = null; continue }
    if (!active) continue
    const assignment = line.match(/^([A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*")\s*=\s*(.+)$/)
    if (!assignment) continue
    const parsedKey = parseTomlScalar(assignment[1])
    const key = typeof parsedKey === 'string' ? parsedKey : assignment[1]
    const value = parseTomlScalar(assignment[2])
    if (value === undefined) continue
    const server = mcpServers[active]
    if (section === 'env' && typeof value === 'string') (server.env ??= {})[key] = value
    else if (section === 'http_headers' && typeof value === 'string') (server.headers ??= {})[key] = value
    else if (section === 'env_http_headers' && typeof value === 'string' && /^[A-Z_][A-Z0-9_]*$/i.test(value)) (server.headers ??= {})[key] = `\${${value}}`
    else if (!section && ['command', 'url', 'type', 'enabled', 'args', 'bearer_token_env_var'].includes(key)) server[key] = value
  }
  for (const server of Object.values(mcpServers)) {
    if (typeof server.bearer_token_env_var === 'string' && /^[A-Z_][A-Z0-9_]*$/i.test(server.bearer_token_env_var)) {
      ;(server.headers ??= {}).Authorization = `Bearer \${${server.bearer_token_env_var}}`
    }
    delete server.bearer_token_env_var
  }
  return { mcpServers }
}

function discoverySources() {
  const home = app.getPath('home')
  return [
    { origin: 'Cursor', file: path.join(home, '.cursor', 'mcp.json'), pick: (d) => d && d.mcpServers },
    { origin: 'Claude Desktop', file: path.join(home, 'Library', 'Application Support', 'Claude', 'claude_desktop_config.json'), pick: (d) => d && d.mcpServers },
    { origin: 'Claude CLI', file: path.join(home, '.claude.json'), pick: (d) => d && d.mcpServers },
    { origin: 'Codex CLI', file: path.join(home, '.codex', 'config.toml'), load: (file) => parseCodexMcpToml(fs.readFileSync(file, 'utf8')), pick: (d) => d && d.mcpServers },
    { origin: 'Gemini CLI', file: path.join(home, '.gemini', 'settings.json'), pick: (d) => d && d.mcpServers },
    { origin: 'VS Code', file: path.join(home, 'Library', 'Application Support', 'Code', 'User', 'mcp.json'), pick: (d) => d && (d.servers || d.mcpServers) },
    { origin: 'Windsurf', file: path.join(home, '.codeium', 'windsurf', 'mcp_config.json'), pick: (d) => d && d.mcpServers },
  ]
}

/** Copy only the known spec keys, verbatim (no ${VAR} expansion). */
function sanitizeRaw(raw) {
  if (!raw || typeof raw !== 'object') return null
  if (typeof raw.url === 'string' && raw.url) {
    let parsed
    try { parsed = new URL(raw.url) } catch { return null }
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    const out = { type: raw.type === 'sse' ? 'sse' : 'http', url: parsed.toString() }
    const headers = raw.headers && typeof raw.headers === 'object' && !Array.isArray(raw.headers)
      ? Object.fromEntries(Object.entries(raw.headers)
          .filter(([k, v]) => /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(k) && typeof v === 'string' && v.length <= 4096)
          .slice(0, 32))
      : {}
    if (Object.keys(headers).length) out.headers = headers
    if (containsLiteralSecret(out)) return null
    return out
  }
  if (typeof raw.command === 'string' && raw.command.trim() && raw.command.length <= 512) {
    const out = { command: raw.command.trim() }
    if (Array.isArray(raw.args)) out.args = raw.args.filter((a) => typeof a === 'string' && a.length <= 4096).slice(0, 64)
    const env = raw.env && typeof raw.env === 'object' && !Array.isArray(raw.env)
      ? Object.fromEntries(Object.entries(raw.env)
          .filter(([k, v]) => /^[A-Z_][A-Z0-9_]{0,127}$/i.test(k) && typeof v === 'string' && v.length <= 4096)
          .slice(0, 32))
      : {}
    if (Object.keys(env).length) out.env = env
    if (containsLiteralSecret(out)) return null
    return out
  }
  return null
}

/** Servers configured in sibling apps that the user catalog doesn't have yet. */
function discoverExternal() {
  const existing = new Set(parseServers(readJson(userConfigPath()).data).map((s) => s.name))
  const found = []
  const seen = new Set()
  for (const src of discoverySources()) {
    let data
    if (src.load) {
      try { data = src.load(src.file) } catch { data = null }
    } else data = readJson(src.file).data
    const map = src.pick(data)
    if (!map || typeof map !== 'object' || Array.isArray(map)) continue
    for (const [name, raw] of Object.entries(map).slice(0, MAX_SERVERS_PER_SCOPE)) {
      if (!name || name === 'kaisola' || existing.has(name) || seen.has(name)) continue
      const spec = sanitizeRaw(raw)
      if (!spec) continue
      seen.add(name)
      found.push({ name, origin: src.origin, spec })
    }
  }
  return found
}

/** Merge every discovered server into the user catalog, DISABLED. */
function importDiscovered() {
  const found = discoverExternal()
  if (!found.length) return { ok: true, imported: 0 }
  const loaded = readJson(userConfigPath())
  if (loaded.error) return { ok: false, imported: 0, message: loaded.error }
  const cfg = loaded.data ?? {}
  const mcpServers = { ...(cfg.mcpServers && typeof cfg.mcpServers === 'object' ? cfg.mcpServers : {}) }
  const disabled = new Set(Array.isArray(cfg.disabled) ? cfg.disabled : [])
  for (const { name, spec } of found) {
    mcpServers[name] = spec
    disabled.add(name) // arrives off — arming is an explicit per-server choice
  }
  writePrivateJson(userConfigPath(), { ...cfg, mcpServers, disabled: [...disabled] })
  emitChange()
  return { ok: true, imported: found.length }
}

/** Ensure the user config file exists (with a template) and return its path —
 * "Add server…" opens it in the editor instead of a bespoke form. */
function ensureUserConfig() {
  const file = userConfigPath()
  if (!fs.existsSync(file)) {
    writePrivateJson(file, {
      mcpServers: {
        // "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] },
        // "linear": { "type": "http", "url": "https://mcp.linear.app/mcp" },
      },
      disabled: [],
    })
  }
  return file
}

// ── install deeplink (kaisola://mcp/install?name=…&config=BASE64(json)) ─────
// Mirrors Cursor's install-link shape so ecosystem "Add to Cursor" buttons
// translate 1:1. The parser only VALIDATES — nothing is written until the
// renderer's trust modal gets an explicit Install click.
const INSTALL_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,39}$/i
const MAX_INSTALL_CONFIG_BYTES = 64 * 1024
const SECRET_NAME_RE = /(authorization|api[-_]?key|token|secret|password|credential)/i
const ENV_PLACEHOLDER_RE = /^(?:Bearer\s+)?\$\{[A-Z_][A-Z0-9_]*\}$/i
function containsLiteralSecret(config) {
  for (const field of ['env', 'headers']) {
    const values = config && config[field]
    if (!values || typeof values !== 'object' || Array.isArray(values)) continue
    for (const [name, value] of Object.entries(values)) {
      if (SECRET_NAME_RE.test(name) && typeof value === 'string' && value && !ENV_PLACEHOLDER_RE.test(value)) return true
    }
  }
  if (config && typeof config.url === 'string') {
    try {
      const parsed = new URL(config.url)
      // URL userinfo is itself a credential carrier and is also easy to expose
      // accidentally in the review UI, logs, and server detail rows.
      if (parsed.username || parsed.password) return true
      for (const [name, value] of parsed.searchParams) {
        if (SECRET_NAME_RE.test(name) && value && !ENV_PLACEHOLDER_RE.test(value)) return true
      }
    } catch { return true }
  }
  return false
}
function parseInstallUrl(rawUrl) {
  let u
  try { u = new URL(rawUrl) } catch { return null }
  // both kaisola://mcp/install (host=mcp, path=/install) and kaisola:mcp/install
  const where = `${u.host}${u.pathname}`.replace(/\/+$/, '')
  if (u.protocol !== 'kaisola:' || where !== 'mcp/install') return null
  const name = u.searchParams.get('name') ?? ''
  const b64 = u.searchParams.get('config') ?? ''
  if (!INSTALL_NAME_RE.test(name)) return null
  if (!b64 || b64.length > MAX_INSTALL_CONFIG_BYTES * 2) return null
  let config
  try {
    const decoded = Buffer.from(b64, 'base64')
    if (decoded.length > MAX_INSTALL_CONFIG_BYTES) return null
    config = JSON.parse(decoded.toString('utf8'))
  } catch { return null }
  if (!config || typeof config !== 'object' || Array.isArray(config)) return null
  const clean = sanitizeRaw(config)
  if (!clean) return null
  return { name, config: clean }
}

/** Write one server into the USER catalog (raw spec verbatim — never
 *  env-expanded into the file). Called only after the trust modal's Install. */
const EXTENSION_OWNER_RE = /^[a-z0-9][a-z0-9._-]{2,79}$/
const SPEC_HASH_RE = /^[a-f0-9]{64}$/

/** Canonical hash of the RAW persisted spec. Unlike specHash(), this never
 * expands ${VAR}; changing an environment variable must not make an extension
 * lose ownership of the record it installed. */
function storedSpecHash(raw) {
  const clean = sanitizeRaw(raw)
  if (!clean) return null
  const canon = clean.command
    ? ['stdio', clean.command, ...(clean.args || []), ...Object.entries(clean.env || {}).sort(([a], [b]) => a.localeCompare(b)).flat()]
    : [clean.type === 'sse' ? 'sse' : 'http', clean.url, ...Object.entries(clean.headers || {}).sort(([a], [b]) => a.localeCompare(b)).flat()]
  return crypto.createHash('sha256').update(JSON.stringify(canon)).digest('hex')
}

function cleanExtensionOwners(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  return Object.fromEntries(Object.entries(value).filter(([name, record]) =>
    INSTALL_NAME_RE.test(name)
      && record && typeof record === 'object' && !Array.isArray(record)
      && EXTENSION_OWNER_RE.test(record.extensionId)
      && SPEC_HASH_RE.test(record.specHash),
  ))
}

/** Pure mutation planner, exported to focused tests. Existing configs without
 * ownership metadata remain user-owned and are never silently claimed/deleted. */
function planAddUserServer(input, name, config, extensionId) {
  if (!INSTALL_NAME_RE.test(name)) return { ok: false, message: 'Invalid server name.' }
  if (extensionId != null && (typeof extensionId !== 'string' || !EXTENSION_OWNER_RE.test(extensionId))) {
    return { ok: false, message: 'Invalid extension owner.' }
  }
  const clean = sanitizeRaw(config)
  const nextHash = clean && storedSpecHash(clean)
  if (!clean || !nextHash) return { ok: false, message: containsLiteralSecret(config) ? 'Store secrets in an environment variable and use a ${NAME} placeholder.' : 'Invalid server spec.' }

  const cfg = input && typeof input === 'object' && !Array.isArray(input) ? input : {}
  const mcpServers = cfg.mcpServers && typeof cfg.mcpServers === 'object' && !Array.isArray(cfg.mcpServers)
    ? { ...cfg.mcpServers }
    : {}
  const extensionOwners = cleanExtensionOwners(cfg.extensionOwners)
  const owner = Object.prototype.hasOwnProperty.call(extensionOwners, name) ? extensionOwners[name] : null
  const hasExisting = Object.prototype.hasOwnProperty.call(mcpServers, name)
  const existingHash = hasExisting ? storedSpecHash(mcpServers[name]) : null

  if (hasExisting) {
    if (owner && owner.extensionId !== extensionId) {
      return { ok: false, conflict: true, message: `“${name}” is managed by extension ${owner.extensionId}.` }
    }
    if (extensionId && owner && owner.extensionId === extensionId) {
      // Only replace an owned entry while it still matches the last spec this
      // extension wrote. A user edit is an ownership handoff, not an update target.
      if (!existingHash || existingHash !== owner.specHash) {
        return { ok: false, conflict: true, message: `“${name}” was edited after installation; the existing server was preserved.` }
      }
      mcpServers[name] = clean
      extensionOwners[name] = { extensionId, specHash: nextHash }
      const disabled = Array.isArray(cfg.disabled) ? cfg.disabled.filter((item) => item !== name) : []
      return { ok: true, created: false, owned: true, updated: existingHash !== nextHash, config: { ...cfg, mcpServers, disabled, extensionOwners } }
    }
    if (existingHash === nextHash) {
      // Exact user-owned matches can satisfy an extension without transferring
      // ownership. Uninstall will consequently preserve the user's record.
      const disabled = Array.isArray(cfg.disabled) ? cfg.disabled.filter((item) => item !== name) : []
      return { ok: true, created: false, owned: false, existing: true, config: { ...cfg, mcpServers, disabled, extensionOwners } }
    }
    return { ok: false, conflict: true, message: `A different user server named “${name}” already exists. Rename or remove it before installing.` }
  }

  if (Object.keys(mcpServers).length >= MAX_SERVERS_PER_SCOPE) return { ok: false, message: `User catalog is full (${MAX_SERVERS_PER_SCOPE}).` }
  mcpServers[name] = clean
  if (extensionId) extensionOwners[name] = { extensionId, specHash: nextHash }
  else delete extensionOwners[name]
  const disabled = Array.isArray(cfg.disabled) ? cfg.disabled.filter((item) => item !== name) : []
  return { ok: true, created: true, owned: !!extensionId, config: { ...cfg, mcpServers, disabled, extensionOwners } }
}

function addUserServer(name, config, extensionId) {
  const loaded = readJson(userConfigPath())
  if (loaded.error) return { ok: false, message: loaded.error }
  const planned = planAddUserServer(loaded.data, name, config, extensionId)
  if (!planned.ok) return planned
  writePrivateJson(userConfigPath(), planned.config)
  emitChange()
  const { config: _config, ...result } = planned
  return result
}

function planRemoveUserServer(input, name, extensionId) {
  if (!INSTALL_NAME_RE.test(name)) return { ok: false, message: 'Invalid server name.' }
  if (extensionId != null && (typeof extensionId !== 'string' || !EXTENSION_OWNER_RE.test(extensionId))) {
    return { ok: false, message: 'Invalid extension owner.' }
  }
  const cfg = input && typeof input === 'object' && !Array.isArray(input) ? input : {}
  const mcpServers = cfg.mcpServers && typeof cfg.mcpServers === 'object' && !Array.isArray(cfg.mcpServers)
    ? { ...cfg.mcpServers }
    : {}
  const extensionOwners = cleanExtensionOwners(cfg.extensionOwners)
  const owner = Object.prototype.hasOwnProperty.call(extensionOwners, name) ? extensionOwners[name] : null
  if (!Object.prototype.hasOwnProperty.call(mcpServers, name)) {
    if (owner) {
      delete extensionOwners[name]
      return { ok: true, missing: true, config: { ...cfg, mcpServers, extensionOwners } }
    }
    return { ok: true, missing: true }
  }
  if (extensionId) {
    if (!owner || owner.extensionId !== extensionId) return { ok: true, preserved: true }
    const currentHash = storedSpecHash(mcpServers[name])
    if (!currentHash || currentHash !== owner.specHash) {
      // A post-install user edit releases ownership. Keep the server and remove
      // stale metadata so no later uninstall can delete it.
      delete extensionOwners[name]
      return { ok: true, preserved: true, modified: true, config: { ...cfg, mcpServers, extensionOwners } }
    }
  } else if (owner) {
    return { ok: false, conflict: true, message: `“${name}” is managed by extension ${owner.extensionId}. Uninstall that extension first.` }
  }
  delete mcpServers[name]
  delete extensionOwners[name]
  const disabled = Array.isArray(cfg.disabled) ? cfg.disabled.filter((item) => item !== name) : []
  return { ok: true, removed: true, config: { ...cfg, mcpServers, disabled, extensionOwners } }
}

function removeUserServer(name, extensionId) {
  const loaded = readJson(userConfigPath())
  if (loaded.error) return { ok: false, message: loaded.error }
  const planned = planRemoveUserServer(loaded.data, name, extensionId)
  if (!planned.ok) return planned
  if (planned.config) writePrivateJson(userConfigPath(), planned.config)
  emitChange()
  const { config: _config, ...result } = planned
  return result
}

function registerMcpCatalogHandlers(ipcMain) {
  // Sync sibling-agent catalogs into Kaisola on every launch. Imports remain
  // disabled until the user enables each server, so discovery never executes
  // a newly found command or contacts a remote endpoint on its own.
  try { importDiscovered() } catch { /* optional sibling configs */ }
  ipcMain.handle('mcp:server-add', (_e, { name, config, extensionId } = {}) => {
    try { return addUserServer(String(name ?? ''), config, extensionId == null ? undefined : String(extensionId)) } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('mcp:server-remove', (_e, { name, extensionId } = {}) => {
    try { return removeUserServer(String(name ?? ''), extensionId == null ? undefined : String(extensionId)) } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('mcp:servers', (_e, { workspace } = {}) => {
    try { return { ok: true, ...listServers(workspace || null) } } catch (err) {
      return { ok: false, servers: [], message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('mcp:server-set', (_e, { workspace, scope, name, enabled } = {}) => {
    if (typeof name !== 'string' || !name || (scope !== 'user' && scope !== 'project')) return { ok: false, message: 'bad args' }
    try { return setServerEnabled(workspace || null, scope, name, !!enabled) } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('mcp:server-probe', async (_e, { workspace, name, force } = {}) => {
    if (typeof name !== 'string' || !name) return { ok: false, message: 'bad args' }
    try { return await cachedProbeServer(workspace || null, name, !!force) } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('mcp:user-config', () => {
    try { return { ok: true, path: ensureUserConfig() } } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('mcp:discover', () => {
    try { return { ok: true, found: discoverExternal().map(({ name, origin }) => ({ name, origin })) } } catch (err) {
      return { ok: false, found: [], message: String((err && err.message) || err) }
    }
  })
  ipcMain.handle('mcp:import-discovered', () => {
    try { return importDiscovered() } catch (err) {
      return { ok: false, imported: 0, message: String((err && err.message) || err) }
    }
  })
}

module.exports = {
  registerMcpCatalogHandlers,
  acpEntries,
  claudeUserEntries,
  onChange,
  parseInstallUrl,
  addUserServer,
  removeUserServer,
  writePrivateJson,
  __test: { normalizeSpec, parseRpcBody, containsLiteralSecret, specHash, sanitizeRaw, storedSpecHash, planAddUserServer, planRemoveUserServer, writePrivateJson, claudeEntriesFromConfig, parseCodexMcpToml },
}
