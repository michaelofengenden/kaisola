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
function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(data, null, 2))
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
  if (typeof raw.url === 'string' && raw.url) {
    const kind = raw.type === 'sse' ? 'sse' : 'http'
    const headers = {}
    if (raw.headers && typeof raw.headers === 'object' && !Array.isArray(raw.headers)) {
      for (const [k, v] of Object.entries(raw.headers)) {
        if (typeof v === 'string') headers[k] = expandEnv(v)
      }
    }
    return { kind, url: expandEnv(raw.url), headers }
  }
  if (typeof raw.command === 'string' && raw.command.trim()) {
    const env = {}
    if (raw.env && typeof raw.env === 'object' && !Array.isArray(raw.env)) {
      for (const [k, v] of Object.entries(raw.env)) {
        if (typeof v === 'string') env[k] = expandEnv(v)
      }
    }
    return {
      kind: 'stdio',
      command: expandEnv(raw.command.trim()),
      args: Array.isArray(raw.args) ? raw.args.filter((a) => typeof a === 'string').map(expandEnv) : [],
      env,
    }
  }
  return null
}

/** Stable hash of a spec — the approval key ingredient (edits re-prompt). */
function specHash(spec) {
  const canon = spec.kind === 'stdio'
    ? ['stdio', spec.command, ...spec.args, ...Object.entries(spec.env).flat()]
    : [spec.kind, spec.url, ...Object.entries(spec.headers).flat()]
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
const approvalKey = (workspace, name) => `${workspace}\u0000${name}`

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
  writeJson(approvalsPath(), all)
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
function claudeUserEntries() {
  const entries = {}
  const userCfg = readJson(userConfigPath())
  const disabled = new Set(
    userCfg.data && Array.isArray(userCfg.data.disabled) ? userCfg.data.disabled.filter((n) => typeof n === 'string') : [],
  )
  for (const { name, spec } of parseServers(userCfg.data)) {
    if (disabled.has(name)) continue
    entries[name] = spec.kind === 'stdio'
      ? { command: spec.command, args: spec.args, ...(Object.keys(spec.env).length ? { env: spec.env } : {}) }
      : { type: spec.kind, url: spec.url, ...(Object.keys(spec.headers).length ? { headers: spec.headers } : {}) }
  }
  return entries
}

// ── health probe (remote servers only) ───────────────────────────────────────
function rpcPost(url, headers, payload) {
  return new Promise((resolve) => {
    let u
    try { u = new URL(url) } catch { return resolve({ ok: false, message: 'invalid url' }) }
    const lib = u.protocol === 'https:' ? https : http
    const req = lib.request(
      u,
      { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...headers } },
      (res) => {
        let body = ''
        res.on('data', (c) => { body += c; if (body.length > 200_000) req.destroy() })
        res.on('end', () => {
          if (!res.statusCode || res.statusCode >= 400) return resolve({ ok: false, message: `HTTP ${res.statusCode}` })
          try { resolve({ ok: true, json: JSON.parse(body) }) } catch { resolve({ ok: false, message: 'non-JSON reply' }) }
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
  if (spec.kind === 'stdio') return { ok: true, kind: 'stdio', message: 'stdio servers start with the agent session' }
  const init = await rpcPost(spec.url, spec.headers, {
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'kaisola', version: app.getVersion() } },
  })
  if (!init.ok) return { ok: false, kind: spec.kind, message: init.message }
  const serverInfo = init.json && init.json.result && init.json.result.serverInfo
  const tools = await rpcPost(spec.url, spec.headers, { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} })
  const toolCount = tools.ok && tools.json && tools.json.result && Array.isArray(tools.json.result.tools)
    ? tools.json.result.tools.length
    : undefined
  return { ok: true, kind: spec.kind, serverName: serverInfo && serverInfo.name, version: serverInfo && serverInfo.version, toolCount }
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
  for (const fn of changeListeners) { try { fn() } catch { /* listener's problem */ } }
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.webContents.isDestroyed()) w.webContents.send('mcp:servers-changed')
  }
}

/** Enable/disable (user scope) or approve/revoke (project scope) one server. */
function setServerEnabled(workspace, scope, name, enabled) {
  if (scope === 'user') {
    const cfg = readJson(userConfigPath()).data ?? {}
    const disabled = new Set(Array.isArray(cfg.disabled) ? cfg.disabled : [])
    if (enabled) disabled.delete(name)
    else disabled.add(name)
    writeJson(userConfigPath(), { ...cfg, mcpServers: cfg.mcpServers ?? {}, disabled: [...disabled] })
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
function discoverySources() {
  const home = app.getPath('home')
  return [
    { origin: 'Cursor', file: path.join(home, '.cursor', 'mcp.json'), pick: (d) => d && d.mcpServers },
    { origin: 'Claude Desktop', file: path.join(home, 'Library', 'Application Support', 'Claude', 'claude_desktop_config.json'), pick: (d) => d && d.mcpServers },
    { origin: 'Claude CLI', file: path.join(home, '.claude.json'), pick: (d) => d && d.mcpServers },
  ]
}

/** Copy only the known spec keys, verbatim (no ${VAR} expansion). */
function sanitizeRaw(raw) {
  if (!raw || typeof raw !== 'object') return null
  if (typeof raw.url === 'string' && raw.url) {
    const out = { type: raw.type === 'sse' ? 'sse' : 'http', url: raw.url }
    const headers = raw.headers && typeof raw.headers === 'object' && !Array.isArray(raw.headers)
      ? Object.fromEntries(Object.entries(raw.headers).filter(([, v]) => typeof v === 'string'))
      : {}
    if (Object.keys(headers).length) out.headers = headers
    return out
  }
  if (typeof raw.command === 'string' && raw.command.trim()) {
    const out = { command: raw.command.trim() }
    if (Array.isArray(raw.args)) out.args = raw.args.filter((a) => typeof a === 'string')
    const env = raw.env && typeof raw.env === 'object' && !Array.isArray(raw.env)
      ? Object.fromEntries(Object.entries(raw.env).filter(([, v]) => typeof v === 'string'))
      : {}
    if (Object.keys(env).length) out.env = env
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
    const { data } = readJson(src.file)
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
  const cfg = readJson(userConfigPath()).data ?? {}
  const mcpServers = { ...(cfg.mcpServers && typeof cfg.mcpServers === 'object' ? cfg.mcpServers : {}) }
  const disabled = new Set(Array.isArray(cfg.disabled) ? cfg.disabled : [])
  for (const { name, spec } of found) {
    mcpServers[name] = spec
    disabled.add(name) // arrives off — arming is an explicit per-server choice
  }
  writeJson(userConfigPath(), { ...cfg, mcpServers, disabled: [...disabled] })
  emitChange()
  return { ok: true, imported: found.length }
}

/** Ensure the user config file exists (with a template) and return its path —
 * "Add server…" opens it in the editor instead of a bespoke form. */
function ensureUserConfig() {
  const file = userConfigPath()
  if (!fs.existsSync(file)) {
    writeJson(file, {
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
function parseInstallUrl(rawUrl) {
  let u
  try { u = new URL(rawUrl) } catch { return null }
  // both kaisola://mcp/install (host=mcp, path=/install) and kaisola:mcp/install
  const where = `${u.host}${u.pathname}`.replace(/\/+$/, '')
  if (u.protocol !== 'kaisola:' || where !== 'mcp/install') return null
  const name = u.searchParams.get('name') ?? ''
  const b64 = u.searchParams.get('config') ?? ''
  if (!INSTALL_NAME_RE.test(name)) return null
  let config
  try { config = JSON.parse(Buffer.from(b64, 'base64').toString('utf8')) } catch { return null }
  if (!config || typeof config !== 'object' || Array.isArray(config)) return null
  // must normalize to something runnable — same validator the catalog uses
  if (!normalizeSpec(config)) return null
  return { name, config }
}

/** Write one server into the USER catalog (raw spec verbatim — never
 *  env-expanded into the file). Called only after the trust modal's Install. */
function addUserServer(name, config) {
  if (!INSTALL_NAME_RE.test(name) || !normalizeSpec(config)) return { ok: false, message: 'Invalid server spec.' }
  const { data } = readJson(userConfigPath())
  const cfg = data && typeof data === 'object' ? data : {}
  cfg.mcpServers = { ...(cfg.mcpServers || {}), [name]: config }
  if (Object.keys(cfg.mcpServers).length > MAX_SERVERS_PER_SCOPE) return { ok: false, message: `User catalog is full (${MAX_SERVERS_PER_SCOPE}).` }
  writeJson(userConfigPath(), cfg)
  emitChange()
  return { ok: true }
}

function registerMcpCatalogHandlers(ipcMain) {
  ipcMain.handle('mcp:server-add', (_e, { name, config } = {}) => {
    try { return addUserServer(String(name ?? ''), config) } catch (err) {
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
  ipcMain.handle('mcp:server-probe', async (_e, { workspace, name } = {}) => {
    if (typeof name !== 'string' || !name) return { ok: false, message: 'bad args' }
    try { return await probeServer(workspace || null, name) } catch (err) {
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

module.exports = { registerMcpCatalogHandlers, acpEntries, claudeUserEntries, onChange, parseInstallUrl, addUserServer }
