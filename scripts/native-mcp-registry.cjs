'use strict'

// Native Kaisola MCP registry. The native app passes its own Application
// Support directory; this module never reads or writes Electron's userData.

const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const SCHEMA_VERSION = 1
const CONFIG_DIRECTORY = path.join('mcp', 'workspaces')
const SERVER_ID_RE = /^[a-z0-9][a-z0-9._-]{0,79}$/i
const TRANSPORTS = new Set(['stdio', 'http', 'sse'])

function defaultBaseDir() {
  if (process.env.KAISOLA_NATIVE_APP_SUPPORT_DIR) {
    return path.resolve(process.env.KAISOLA_NATIVE_APP_SUPPORT_DIR)
  }
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'com.kaisola.mac.preview')
  }
  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Kaisola Native')
  }
  return path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'kaisola-native')
}

function canonicalWorkspace(workspace = process.cwd()) {
  const resolved = path.resolve(workspace)
  try {
    return fs.realpathSync.native(resolved)
  } catch {
    return resolved
  }
}

function workspaceDigest(workspace) {
  return crypto.createHash('sha256').update(canonicalWorkspace(workspace)).digest('hex').slice(0, 24)
}

function resolveConfigPath(options = {}) {
  if (typeof options === 'string') return path.resolve(options)
  const injected = options.configPath || options.filePath
  if (injected) return path.resolve(injected)
  const baseDir = path.resolve(options.baseDir || defaultBaseDir())
  return path.join(baseDir, CONFIG_DIRECTORY, `${workspaceDigest(options.workspace)}.json`)
}

function emptyConfig(workspace) {
  return {
    schemaVersion: SCHEMA_VERSION,
    workspace: canonicalWorkspace(workspace),
    servers: [],
  }
}

function cleanRequiredString(value, field) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${field} is required`)
  const clean = value.trim()
  if (clean.length > 4096 || /[\0\r\n]/.test(clean)) throw new Error(`${field} is invalid`)
  return clean
}

function cleanStringArray(value, field) {
  if (value == null) return []
  if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) {
    throw new Error(`${field} must be an array of strings`)
  }
  return [...value]
}

function cleanStringMap(value, field) {
  if (value == null) return {}
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${field} must be an object of string values`)
  }
  const clean = {}
  for (const [name, item] of Object.entries(value)) {
    if (!name || /[\0\r\n]/.test(name) || typeof item !== 'string') {
      throw new Error(`${field} must be an object of string values`)
    }
    clean[name] = item
  }
  return clean
}

function validateServer(server) {
  if (!server || typeof server !== 'object' || Array.isArray(server)) throw new Error('server must be an object')
  const id = cleanRequiredString(server.id, 'id')
  if (!SERVER_ID_RE.test(id)) throw new Error('id is invalid')
  const name = cleanRequiredString(server.name, 'name')
  const transport = cleanRequiredString(server.transport, 'transport')
  if (!TRANSPORTS.has(transport)) throw new Error(`bad transport: ${transport}`)
  if (server.enabled != null && typeof server.enabled !== 'boolean') throw new Error('enabled must be a boolean')

  if (transport === 'stdio') {
    return {
      id,
      name,
      transport,
      enabled: server.enabled !== false,
      command: cleanRequiredString(server.command, 'command'),
      args: cleanStringArray(server.args, 'args'),
      env: cleanStringMap(server.env, 'env'),
    }
  }

  const rawUrl = cleanRequiredString(server.url, 'url')
  let parsed
  try {
    parsed = new URL(rawUrl)
  } catch {
    throw new Error('url is invalid')
  }
  if (parsed.protocol !== 'https:') throw new Error('url must use HTTPS')
  if (parsed.username || parsed.password) throw new Error('url must not contain credentials')
  return {
    id,
    name,
    transport,
    enabled: server.enabled !== false,
    url: parsed.toString(),
    headers: cleanStringMap(server.headers, 'headers'),
  }
}

function readConfig(options = {}) {
  const workspace = typeof options === 'string' ? process.cwd() : options.workspace
  const fallback = emptyConfig(workspace)
  let parsed
  try {
    parsed = JSON.parse(fs.readFileSync(resolveConfigPath(options), 'utf8'))
  } catch {
    return fallback
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) || !Array.isArray(parsed.servers)) return fallback

  const servers = []
  const ids = new Set()
  for (const candidate of parsed.servers) {
    try {
      const server = validateServer(candidate)
      if (!ids.has(server.id)) {
        ids.add(server.id)
        servers.push(server)
      }
    } catch {
      // A damaged record must not stop the native app from starting a session.
    }
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    workspace: typeof parsed.workspace === 'string' && parsed.workspace ? parsed.workspace : fallback.workspace,
    servers,
  }
}

function writePrivateJson(file, value) {
  const directory = path.dirname(file)
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
  try { fs.chmodSync(directory, 0o700) } catch { /* non-POSIX or restrictive filesystem */ }
  const temporary = path.join(directory, `.${path.basename(file)}.tmp.${process.pid}.${Date.now()}.${crypto.randomBytes(4).toString('hex')}`)
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
    try { fs.chmodSync(temporary, 0o600) } catch { /* non-POSIX or restrictive filesystem */ }
    fs.renameSync(temporary, file)
    try { fs.chmodSync(file, 0o600) } catch { /* non-POSIX or restrictive filesystem */ }
  } catch (error) {
    try { fs.unlinkSync(temporary) } catch { /* absent or already renamed */ }
    throw error
  }
}

function writeConfig(options, config) {
  const clean = emptyConfig(options && typeof options === 'object' ? options.workspace : undefined)
  clean.workspace = typeof config.workspace === 'string' && config.workspace ? config.workspace : clean.workspace
  clean.servers = config.servers.map(validateServer)
  writePrivateJson(resolveConfigPath(options), clean)
  return clean
}

function addArguments(input, options) {
  if (input && typeof input === 'object' && !Array.isArray(input) && input.server) {
    const { server, ...location } = input
    return { server, location }
  }
  return { server: input, location: options || {} }
}

function idArguments(input, options) {
  if (input && typeof input === 'object' && !Array.isArray(input) && Object.hasOwn(input, 'id')) {
    const { id, ...location } = input
    return { id, location }
  }
  return { id: input, location: options || {} }
}

function addServer(input, options) {
  const { server: rawServer, location } = addArguments(input, options)
  const server = validateServer(rawServer)
  const config = readConfig(location)
  if (config.servers.some((candidate) => candidate.id === server.id)) {
    throw new Error(`server id already exists: ${server.id}`)
  }
  config.servers.push(server)
  writeConfig(location, config)
  return { ...server }
}

function listServers(options = {}) {
  return readConfig(options).servers.map((server) => ({ ...server }))
}

function removeServer(input, options) {
  const { id: rawId, location } = idArguments(input, options)
  const id = cleanRequiredString(rawId, 'id')
  const config = readConfig(location)
  const next = config.servers.filter((server) => server.id !== id)
  if (next.length === config.servers.length) return false
  config.servers = next
  writeConfig(location, config)
  return true
}

function setServerEnabled(input, enabled, options) {
  let id = input
  let location = options || {}
  let target = enabled
  if (input && typeof input === 'object' && !Array.isArray(input) && Object.hasOwn(input, 'id')) {
    ({ id, enabled: target, ...location } = input)
  }
  id = cleanRequiredString(id, 'id')
  if (typeof target !== 'boolean') throw new Error('enabled must be a boolean')
  const config = readConfig(location)
  const server = config.servers.find((candidate) => candidate.id === id)
  if (!server) throw new Error(`unknown server id: ${id}`)
  server.enabled = target
  writeConfig(location, config)
  return { ...server }
}

function enableServer(input, options) {
  const { id, location } = idArguments(input, options)
  return setServerEnabled(id, true, location)
}

function disableServer(input, options) {
  const { id, location } = idArguments(input, options)
  return setServerEnabled(id, false, location)
}

const toPairs = (object) => Object.entries(object).map(([name, value]) => ({ name, value }))

function buildSessionServers(options = {}) {
  const enabledOnly = options.enabledOnly !== false
  const agentCaps = options.agentCaps || {}
  const output = []
  for (const server of listServers(options)) {
    if (enabledOnly && !server.enabled) continue
    if (server.transport === 'stdio') {
      output.push({ name: server.name, command: server.command, args: server.args, env: toPairs(server.env) })
    } else if (agentCaps[server.transport]) {
      output.push({ type: server.transport, name: server.name, url: server.url, headers: toPairs(server.headers) })
    }
  }
  return output
}

function createRegistry(options = {}) {
  const location = { ...options, configPath: resolveConfigPath(options) }
  return Object.freeze({
    configPath: location.configPath,
    add: (server) => addServer(server, location),
    remove: (id) => removeServer(id, location),
    list: () => listServers(location),
    enable: (id) => enableServer(id, location),
    disable: (id) => disableServer(id, location),
    buildSessionServers: (buildOptions = {}) => buildSessionServers({ ...location, ...buildOptions }),
  })
}

function usage() {
  return `Usage:
  node scripts/native-mcp-registry.cjs list [--json] [location options]
  node scripts/native-mcp-registry.cjs add --file <server.json> [location options]
  node scripts/native-mcp-registry.cjs remove <id> [location options]
  node scripts/native-mcp-registry.cjs enable <id> [location options]
  node scripts/native-mcp-registry.cjs disable <id> [location options]
  node scripts/native-mcp-registry.cjs build [--http] [--sse] [--json] [location options]

Location options:
  --config <path>      Use an exact config path
  --base-dir <path>    Native Application Support base directory
  --workspace <path>   Workspace used to derive the per-workspace config path
`
}

function parseCliArguments(argv) {
  const [command, ...rest] = argv
  if (!command || command === '--help' || command === '-h') return { help: true }
  const parsed = { command, positionals: [], agentCaps: {} }
  for (let index = 0; index < rest.length; index += 1) {
    const argument = rest[index]
    const take = () => {
      const value = rest[index + 1]
      if (!value || value.startsWith('--')) throw new Error(`${argument} requires a value`)
      index += 1
      return value
    }
    if (argument === '--json') parsed.json = true
    else if (argument === '--http') parsed.agentCaps.http = true
    else if (argument === '--sse') parsed.agentCaps.sse = true
    else if (argument === '--config') parsed.configPath = take()
    else if (argument === '--base-dir') parsed.baseDir = take()
    else if (argument === '--workspace') parsed.workspace = take()
    else if (argument === '--file') parsed.inputFile = take()
    else if (argument.startsWith('--')) throw new Error(`unknown option: ${argument}`)
    else parsed.positionals.push(argument)
  }
  return parsed
}

function main(argv = process.argv.slice(2)) {
  const options = parseCliArguments(argv)
  if (options.help) {
    process.stdout.write(usage())
    return
  }
  const location = { configPath: options.configPath, baseDir: options.baseDir, workspace: options.workspace }
  if (options.command === 'list') {
    const servers = listServers(location)
    if (options.json) process.stdout.write(`${JSON.stringify(servers, null, 2)}\n`)
    else if (!servers.length) process.stdout.write('No MCP servers configured.\n')
    else for (const server of servers) process.stdout.write(`${server.enabled ? 'enabled ' : 'disabled'}\t${server.id}\t${server.transport}\t${server.name}\n`)
    return
  }
  if (options.command === 'add') {
    if (!options.inputFile) throw new Error('add requires --file <server.json>')
    const parsed = JSON.parse(fs.readFileSync(path.resolve(options.inputFile), 'utf8'))
    const server = addServer(parsed.server || parsed, location)
    process.stdout.write(options.json ? `${JSON.stringify(server, null, 2)}\n` : `Added ${server.id}.\n`)
    return
  }
  if (options.command === 'build') {
    const servers = buildSessionServers({ ...location, enabledOnly: true, agentCaps: options.agentCaps })
    process.stdout.write(`${JSON.stringify(servers, null, options.json ? 2 : 0)}\n`)
    return
  }
  if (['remove', 'enable', 'disable'].includes(options.command)) {
    const id = options.positionals[0]
    if (!id || options.positionals.length !== 1) throw new Error(`${options.command} requires exactly one server id`)
    if (options.command === 'remove') {
      const removed = removeServer(id, location)
      process.stdout.write(removed ? `Removed ${id}.\n` : `Server ${id} was not configured.\n`)
    } else {
      const server = options.command === 'enable' ? enableServer(id, location) : disableServer(id, location)
      process.stdout.write(`${options.command === 'enable' ? 'Enabled' : 'Disabled'} ${server.id}.\n`)
    }
    return
  }
  throw new Error(`unknown command: ${options.command}`)
}

if (require.main === module) {
  try {
    main()
  } catch (error) {
    process.stderr.write(`native-mcp-registry: ${String(error && error.message ? error.message : error)}\n`)
    process.exitCode = 1
  }
}

module.exports = {
  SCHEMA_VERSION,
  add: addServer,
  addServer,
  buildSessionServers,
  createRegistry,
  defaultBaseDir,
  disable: disableServer,
  disableServer,
  enable: enableServer,
  enableServer,
  list: listServers,
  listServers,
  main,
  readConfig,
  remove: removeServer,
  removeServer,
  resolveConfigPath,
  setServerEnabled,
  validateServer,
  writeConfig,
}
