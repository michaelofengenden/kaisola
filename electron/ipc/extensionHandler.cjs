// Declarative extension installation state. The renderer keeps a local cache
// for instant startup, but this main-process record is authoritative on desktop.
// Development manifests are re-read and validated here; renderer input never
// becomes an executable module or an unrestricted contribution.
const fs = require('node:fs')
const path = require('node:path')
const { app } = require('electron')

const MAX_STATE_BYTES = 512 * 1024
const MAX_MANIFEST_BYTES = 128 * 1024
const MAX_DEV_EXTENSIONS = 64
const MAX_CONTRIBUTIONS = 32
const ID_RE = /^[a-z0-9][a-z0-9._-]{2,79}$/
const VERSION_RE = /^\d+\.\d+\.\d+(?:[-+][a-z0-9.-]+)?$/i
const EXT_RE = /^[a-z0-9][a-z0-9+_-]{0,15}$/
const ENV_RE = /^[A-Z_][A-Z0-9_]{0,127}$/
const CATEGORIES = new Set(['Languages', 'Grammars', 'Language Servers', 'Debug Adapters', 'Themes', 'Icon Themes', 'MCP Servers', 'Previews'])
const RENDERERS = new Set(['csv', 'json', 'markdown', 'html'])

const statePath = () => path.join(app.getPath('userData'), 'extensions-state.json')

function readState() {
  const file = statePath()
  try {
    const stat = fs.statSync(file)
    if (stat.size > MAX_STATE_BYTES) throw new Error('Extension state is too large.')
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
    return {
      exists: true,
      installed: raw && typeof raw.installed === 'object' && !Array.isArray(raw.installed) ? raw.installed : {},
      development: Array.isArray(raw.development) ? raw.development.slice(0, MAX_DEV_EXTENSIONS) : [],
    }
  } catch (err) {
    if (err && err.code !== 'ENOENT') return { exists: true, installed: {}, development: [], error: String(err.message || err) }
    return { exists: false, installed: {}, development: [] }
  }
}

function writeState(state) {
  const file = statePath()
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const json = JSON.stringify({ schemaVersion: 1, installed: state.installed, development: state.development }, null, 2)
  if (Buffer.byteLength(json) > MAX_STATE_BYTES) throw new Error('Extension state is too large.')
  const temp = `${file}.tmp.${process.pid}.${Date.now()}`
  fs.writeFileSync(temp, json, { mode: 0o600 })
  fs.renameSync(temp, file)
}

const strings = (value, limit = 128) => Array.isArray(value)
  ? value.filter((item) => typeof item === 'string' && item.length > 0 && item.length < 128).slice(0, limit)
  : []
const extensions = (value) => strings(value, 24)
  .map((item) => item.toLowerCase().replace(/^\./, '').trim())
  .filter((item) => EXT_RE.test(item))

function sanitizeManifest(raw, sourcePath) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('The manifest must be a JSON object.')
  const id = typeof raw.id === 'string' ? raw.id.trim().toLowerCase() : ''
  const name = typeof raw.name === 'string' ? raw.name.trim() : ''
  const version = typeof raw.version === 'string' ? raw.version.trim() : ''
  if (!ID_RE.test(id)) throw new Error('Invalid extension id.')
  if (!name || name.length > 100) throw new Error('Invalid extension name.')
  if (!VERSION_RE.test(version)) throw new Error('Invalid semantic version.')
  const contributes = raw.contributions && typeof raw.contributions === 'object' && !Array.isArray(raw.contributions) ? raw.contributions : {}

  const languages = []
  if (Array.isArray(contributes.languages)) {
    for (const item of contributes.languages.slice(0, MAX_CONTRIBUTIONS)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue
      const exts = extensions(item.extensions)
      if (!exts.length) continue
      const grammar = item.grammar && typeof item.grammar === 'object' && !Array.isArray(item.grammar) ? item.grammar : {}
      const blockComments = Array.isArray(grammar.blockComments)
        ? grammar.blockComments.filter((pair) => Array.isArray(pair) && pair.length === 2 && pair.every((part) => typeof part === 'string' && part.length > 0 && part.length < 8)).slice(0, 4)
        : []
      languages.push({
        id: typeof item.id === 'string' ? item.id.slice(0, 64) : exts[0],
        name: typeof item.name === 'string' ? item.name.slice(0, 100) : exts[0].toUpperCase(),
        extensions: exts,
        grammar: {
          type: 'simple',
          keywords: strings(grammar.keywords),
          atoms: strings(grammar.atoms),
          lineComments: strings(grammar.lineComments, 4),
          blockComments,
        },
      })
    }
  }

  const previews = []
  if (Array.isArray(contributes.previews)) {
    for (const item of contributes.previews.slice(0, MAX_CONTRIBUTIONS)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue
      const exts = extensions(item.extensions)
      if (!exts.length || !RENDERERS.has(item.renderer)) continue
      previews.push({
        id: typeof item.id === 'string' ? item.id.slice(0, 64) : `${item.renderer}-preview`,
        name: typeof item.name === 'string' ? item.name.slice(0, 100) : `${String(item.renderer).toUpperCase()} Preview`,
        extensions: exts,
        renderer: item.renderer,
      })
    }
  }

  const mcpServers = []
  if (Array.isArray(contributes.mcpServers)) {
    for (const item of contributes.mcpServers.slice(0, 8)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue
      const config = item.config && typeof item.config === 'object' && !Array.isArray(item.config) ? item.config : {}
      const serverName = typeof item.name === 'string' ? item.name.trim().slice(0, 64) : ''
      const command = typeof config.command === 'string' ? config.command.trim().slice(0, 512) : undefined
      let url
      if (typeof config.url === 'string') {
        try {
          const parsed = new URL(config.url)
          if (parsed.protocol === 'https:' || (parsed.protocol === 'http:' && ['localhost', '127.0.0.1', '::1'].includes(parsed.hostname))) url = parsed.toString()
        } catch { /* invalid URL */ }
      }
      if (!serverName || (!command && !url) || (command && url)) continue
      const env = config.env && typeof config.env === 'object' && !Array.isArray(config.env)
        ? Object.fromEntries(Object.entries(config.env).filter(([key, value]) => ENV_RE.test(key) && typeof value === 'string').slice(0, 32))
        : undefined
      const headers = config.headers && typeof config.headers === 'object' && !Array.isArray(config.headers)
        ? Object.fromEntries(Object.entries(config.headers).filter(([key, value]) => key.length < 128 && typeof value === 'string').slice(0, 32))
        : undefined
      mcpServers.push({ name: serverName, config: { command, url, args: strings(config.args, 64), env, headers } })
    }
  }
  if (!languages.length && !previews.length && !mcpServers.length) throw new Error('No supported language, preview, or MCP contributions found.')

  const categories = Array.isArray(raw.categories) ? raw.categories.filter((item) => CATEGORIES.has(item)).slice(0, 8) : []
  const inferred = [
    ...(languages.length ? ['Languages', 'Grammars'] : []),
    ...(previews.length ? ['Previews'] : []),
    ...(mcpServers.length ? ['MCP Servers'] : []),
  ]
  return {
    id,
    name,
    version,
    description: typeof raw.description === 'string' ? raw.description.trim().slice(0, 500) : '',
    author: typeof raw.author === 'string' ? raw.author.trim().slice(0, 100) : 'Local developer',
    categories: [...new Set(categories.length ? categories : inferred)],
    repository: typeof raw.repository === 'string' && /^https:\/\//.test(raw.repository) ? raw.repository.slice(0, 2048) : undefined,
    sourcePath,
    contributions: { languages, previews, mcpServers },
  }
}

function inspectDevelopment(sourcePath) {
  if (typeof sourcePath !== 'string' || !path.isAbsolute(sourcePath)) throw new Error('Choose an absolute extension folder.')
  const real = fs.realpathSync.native(sourcePath)
  const stat = fs.statSync(real)
  if (!stat.isDirectory()) throw new Error('Choose an extension folder.')
  const file = path.join(real, 'kaisola-extension.json')
  const fileStat = fs.statSync(file)
  if (!fileStat.isFile() || fileStat.size > MAX_MANIFEST_BYTES) throw new Error('The manifest is missing or too large.')
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
  return sanitizeManifest(raw, real)
}

function cleanRecord(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const version = typeof value.version === 'string' ? value.version.slice(0, 80) : ''
  if (!version) return null
  return {
    version,
    installedAt: Number.isFinite(value.installedAt) ? value.installedAt : Date.now(),
    enabled: value.enabled !== false,
    source: value.source === 'development' ? 'development' : 'bundled',
  }
}

function registerExtensionHandlers(ipcMain) {
  ipcMain.handle('extensions:state', () => {
    const state = readState()
    return { ok: !state.error, ...state }
  })
  ipcMain.handle('extensions:set', (_event, { id, record } = {}) => {
    try {
      if (typeof id !== 'string' || !ID_RE.test(id)) throw new Error('Invalid extension id.')
      const state = readState()
      const installed = { ...state.installed }
      if (record == null) delete installed[id]
      else {
        const clean = cleanRecord(record)
        if (!clean) throw new Error('Invalid install record.')
        installed[id] = clean
      }
      writeState({ installed, development: state.development })
      return { ok: true }
    } catch (err) { return { ok: false, message: String(err.message || err) } }
  })
  ipcMain.handle('extensions:dev-inspect', (_event, { sourcePath } = {}) => {
    try { return { ok: true, manifest: inspectDevelopment(sourcePath) } }
    catch (err) { return { ok: false, message: String(err.message || err) } }
  })
  ipcMain.handle('extensions:dev-register', (_event, { sourcePath } = {}) => {
    try {
      const manifest = inspectDevelopment(sourcePath)
      const state = readState()
      const development = [manifest, ...state.development.filter((item) => item && item.id !== manifest.id)].slice(0, MAX_DEV_EXTENSIONS)
      const installed = { ...state.installed, [manifest.id]: { version: manifest.version, installedAt: Date.now(), enabled: true, source: 'development' } }
      writeState({ installed, development })
      return { ok: true, manifest }
    } catch (err) { return { ok: false, message: String(err.message || err) } }
  })
  ipcMain.handle('extensions:dev-remove', (_event, { id } = {}) => {
    try {
      if (typeof id !== 'string' || !ID_RE.test(id)) throw new Error('Invalid extension id.')
      const state = readState()
      const installed = { ...state.installed }
      delete installed[id]
      writeState({ installed, development: state.development.filter((item) => item && item.id !== id) })
      return { ok: true }
    } catch (err) { return { ok: false, message: String(err.message || err) } }
  })
}

module.exports = { registerExtensionHandlers, sanitizeManifest, inspectDevelopment }
