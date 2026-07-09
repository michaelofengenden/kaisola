import { useSyncExternalStore } from 'react'
import { bridge } from './bridge'

export type ExtensionCategory =
  | 'Languages'
  | 'Grammars'
  | 'Language Servers'
  | 'Debug Adapters'
  | 'Themes'
  | 'Icon Themes'
  | 'MCP Servers'
  | 'Previews'

export interface SimpleGrammar {
  type: 'simple'
  keywords?: string[]
  atoms?: string[]
  lineComments?: string[]
  blockComments?: Array<[string, string]>
}

export interface LanguageContribution {
  id: string
  name: string
  extensions: string[]
  grammar: SimpleGrammar
}

export type PreviewRenderer = 'csv' | 'json' | 'markdown' | 'html'

export interface PreviewContribution {
  id: string
  name: string
  extensions: string[]
  renderer: PreviewRenderer
}

export interface McpContribution {
  name: string
  config: {
    command?: string
    args?: string[]
    env?: Record<string, string>
    url?: string
    headers?: Record<string, string>
  }
}

export interface ExtensionManifest {
  id: string
  name: string
  version: string
  description: string
  author: string
  categories: ExtensionCategory[]
  downloads?: number
  repository?: string
  bundled?: boolean
  defaultInstalled?: boolean
  sourcePath?: string
  contributions?: {
    languages?: LanguageContribution[]
    previews?: PreviewContribution[]
    mcpServers?: McpContribution[]
  }
}

export interface InstalledExtension {
  version: string
  installedAt: number
  enabled: boolean
  source: 'bundled' | 'development'
}

interface ExtensionState {
  installed: Record<string, InstalledExtension>
  development: ExtensionManifest[]
  revision: number
}

const STORAGE_KEY = 'kaisola.extensions.v1'
const OPEN_EVENT = 'kaisola:extensions-open'
const CHANGE_EVENT = 'kaisola:extensions-changed'
const MAX_DEV_EXTENSIONS = 64
const MAX_CONTRIBUTIONS = 32

const javaKeywords = `abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while record sealed permits non-sealed var yield`.split(' ')
const rustKeywords = `as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while`.split(' ')
const tomlAtoms = ['true', 'false', 'inf', 'nan']

/**
 * The shipped catalog is deliberately declarative. Installing one of these
 * entries enables code that is already bundled and reviewed with Kaisola, or
 * adds an MCP server through the existing consent-gated user catalog. Remote
 * marketplace JavaScript is never evaluated in the renderer.
 */
export const BUILTIN_EXTENSIONS: ExtensionManifest[] = [
  {
    id: 'kaisola.html',
    name: 'HTML',
    version: '1.0.0',
    description: 'HTML syntax, editing, and a sanitized document preview.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars', 'Previews'],
    bundled: true,
    defaultInstalled: true,
  },
  {
    id: 'kaisola.markdown',
    name: 'Markdown',
    version: '1.0.0',
    description: 'GitHub-flavored Markdown with tables, images, and rendered preview.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars', 'Previews'],
    bundled: true,
    defaultInstalled: true,
  },
  {
    id: 'kaisola.javascript-typescript',
    name: 'JavaScript & TypeScript',
    version: '1.0.0',
    description: 'JavaScript, JSX, TypeScript, and TSX language support.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars'],
    bundled: true,
    defaultInstalled: true,
  },
  {
    id: 'kaisola.json-yaml',
    name: 'JSON & YAML',
    version: '1.0.0',
    description: 'Structured-data editing for JSON, JSONL, YAML, and YML.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars'],
    bundled: true,
    defaultInstalled: true,
  },
  {
    id: 'kaisola.python',
    name: 'Python',
    version: '1.0.0',
    description: 'Python syntax, indentation, and grammar support.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars'],
    bundled: true,
    defaultInstalled: true,
  },
  {
    id: 'kaisola.media-preview',
    name: 'PDF & Image Preview',
    version: '1.0.0',
    description: 'Fast, zoomable previews for PDF, SVG, PNG, JPEG, GIF, WebP, and AVIF.',
    author: 'Kaisola Contributors',
    categories: ['Previews'],
    bundled: true,
    defaultInstalled: true,
  },
  {
    id: 'kaisola.toml',
    name: 'TOML',
    version: '1.1.0',
    description: 'TOML language and grammar support.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars'],
    bundled: true,
    contributions: {
      languages: [{
        id: 'toml', name: 'TOML', extensions: ['toml'],
        grammar: { type: 'simple', atoms: tomlAtoms, lineComments: ['#'] },
      }],
    },
  },
  {
    id: 'kaisola.java',
    name: 'Java',
    version: '1.0.0',
    description: 'Java syntax support with folding-friendly tokenization.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars'],
    bundled: true,
    contributions: {
      languages: [{
        id: 'java', name: 'Java', extensions: ['java'],
        grammar: {
          type: 'simple', keywords: javaKeywords, atoms: ['true', 'false', 'null'],
          lineComments: ['//'], blockComments: [['/*', '*/']],
        },
      }],
    },
  },
  {
    id: 'kaisola.rust',
    name: 'Rust',
    version: '1.0.0',
    description: 'Rust source syntax support.',
    author: 'Kaisola Contributors',
    categories: ['Languages', 'Grammars'],
    bundled: true,
    contributions: {
      languages: [{
        id: 'rust', name: 'Rust', extensions: ['rs'],
        grammar: {
          type: 'simple', keywords: rustKeywords, atoms: ['true', 'false', 'None', 'Some', 'Ok', 'Err'],
          lineComments: ['//'], blockComments: [['/*', '*/']],
        },
      }],
    },
  },
  {
    id: 'kaisola.csv-preview',
    name: 'CSV Table Preview',
    version: '1.0.0',
    description: 'Turn CSV and TSV files into a scrollable, searchable data table.',
    author: 'Kaisola Contributors',
    categories: ['Previews'],
    bundled: true,
    contributions: {
      previews: [
        { id: 'csv-table', name: 'CSV Table', extensions: ['csv'], renderer: 'csv' },
        { id: 'tsv-table', name: 'TSV Table', extensions: ['tsv'], renderer: 'csv' },
      ],
    },
  },
  {
    id: 'kaisola.json-preview',
    name: 'JSON Tree Preview',
    version: '1.0.0',
    description: 'Inspect JSON and JSONL as a collapsible, readable tree.',
    author: 'Kaisola Contributors',
    categories: ['Previews'],
    bundled: true,
    contributions: {
      previews: [{ id: 'json-tree', name: 'JSON Tree', extensions: ['json', 'jsonl'], renderer: 'json' }],
    },
  },
  {
    id: 'mcp.context7',
    name: 'Context7 MCP Server',
    version: '3.2.0',
    description: 'Up-to-date documentation context for coding agents.',
    author: 'Upstash',
    categories: ['MCP Servers'],
    repository: 'https://github.com/upstash/context7',
    bundled: true,
    // The maintained project recommends its Streamable HTTP endpoint. This
    // avoids a floating npm package and does not execute package scripts.
    contributions: { mcpServers: [{ name: 'context7', config: { url: 'https://mcp.context7.com/mcp' } }] },
  },
  {
    id: 'mcp.sequential-thinking',
    name: 'Sequential Thinking MCP Server',
    version: '2025.12.18',
    description: 'A structured thinking tool for dynamic, revisable problem solving.',
    author: 'Model Context Protocol Contributors',
    categories: ['MCP Servers'],
    bundled: true,
    repository: 'https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking',
    contributions: { mcpServers: [{ name: 'sequential-thinking', config: { command: 'npx', args: ['-y', '@modelcontextprotocol/server-sequential-thinking@2025.12.18'] } }] },
  },
]

const defaultInstalled = () => Object.fromEntries(
  BUILTIN_EXTENSIONS.filter((extension) => extension.defaultInstalled).map((extension) => [extension.id, {
    version: extension.version,
    installedAt: 0,
    enabled: true,
    source: 'bundled' as const,
  }]),
)

function readState(): ExtensionState {
  const fallback: ExtensionState = { installed: defaultInstalled(), development: [], revision: 0 }
  if (typeof window === 'undefined') return fallback
  try {
    const parsed = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? '{}') as Partial<ExtensionState>
    const development = Array.isArray(parsed.development)
      ? parsed.development.slice(0, MAX_DEV_EXTENSIONS).filter((item): item is ExtensionManifest => !!item && typeof item.id === 'string')
      : []
    return {
      installed: { ...defaultInstalled(), ...(parsed.installed ?? {}) },
      development,
      revision: 0,
    }
  } catch {
    return fallback
  }
}

let state = readState()
const listeners = new Set<() => void>()

function persist() {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ installed: state.installed, development: state.development }))
  } catch { /* a full/disabled localStorage must not break the editor */ }
}

function emit() {
  state = { ...state, revision: state.revision + 1 }
  persist()
  listeners.forEach((listener) => listener())
  if (typeof window !== 'undefined') window.dispatchEvent(new CustomEvent(CHANGE_EVENT))
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function snapshot() {
  return state
}

export function useExtensions() {
  return useSyncExternalStore(subscribe, snapshot, snapshot)
}

export function useExtensionRevision() {
  return useSyncExternalStore(subscribe, () => state.revision, () => state.revision)
}

export function extensionCatalog() {
  const byId = new Map<string, ExtensionManifest>()
  for (const extension of BUILTIN_EXTENSIONS) byId.set(extension.id, extension)
  for (const extension of state.development) byId.set(extension.id, extension)
  return [...byId.values()]
}

export function extensionById(id: string) {
  return extensionCatalog().find((extension) => extension.id === id)
}

export function isExtensionInstalled(id: string) {
  return state.installed[id]?.enabled === true
}

export function setExtensionInstalled(extension: ExtensionManifest, installed: boolean) {
  const next = { ...state.installed }
  if (installed) {
    next[extension.id] = {
      version: extension.version,
      installedAt: Date.now(),
      enabled: true,
      source: extension.sourcePath ? 'development' : 'bundled',
    }
  } else {
    // Keep an explicit disabled record. Removing the key would make a
    // default-installed bundle reappear the next time defaults are merged at
    // startup or after main-process hydration.
    next[extension.id] = {
      version: extension.version,
      installedAt: next[extension.id]?.installedAt ?? Date.now(),
      enabled: false,
      source: extension.sourcePath ? 'development' : 'bundled',
    }
  }
  state = { ...state, installed: next }
  emit()
  void bridge.extensions?.set(extension.id, next[extension.id]).catch(() => {})
}

export function registerDevelopmentExtension(extension: ExtensionManifest, installed = true) {
  const development = [extension, ...state.development.filter((item) => item.id !== extension.id)].slice(0, MAX_DEV_EXTENSIONS)
  state = { ...state, development }
  if (installed) setExtensionInstalled(extension, true)
  else emit()
}

export function removeDevelopmentExtension(id: string) {
  const development = state.development.filter((item) => item.id !== id)
  const installed = { ...state.installed }
  delete installed[id]
  state = { ...state, development, installed }
  emit()
  void bridge.extensions?.removeDev(id).catch(() => {})
}

/** Reconcile the fast renderer cache with main's authoritative desktop state. */
export async function hydrateExtensions() {
  if (!bridge.extensions) return
  try {
    const remote = await bridge.extensions.state()
    if (!remote.ok) return
    if (!remote.exists) {
      // One-time migration for builds that previously kept this cache only in
      // the renderer. Main validates future development installs itself.
      await Promise.all(Object.entries(state.installed).map(([id, record]) => bridge.extensions!.set(id, record)))
      for (const extension of state.development) {
        if (extension.sourcePath) await bridge.extensions.registerDev(extension.sourcePath).catch(() => {})
      }
      return
    }
    const development: ExtensionManifest[] = []
    for (const value of remote.development ?? []) {
      const sourcePath = value && typeof value === 'object' && 'sourcePath' in value && typeof value.sourcePath === 'string' ? value.sourcePath : undefined
      const parsed = parseExtensionManifest(value, sourcePath)
      if (parsed.ok) development.push(parsed.manifest)
    }
    state = {
      installed: { ...defaultInstalled(), ...(remote.installed ?? {}) },
      development: development.slice(0, MAX_DEV_EXTENSIONS),
      revision: state.revision,
    }
    emit()
  } catch { /* local cache remains usable when main is unavailable */ }
}

function cleanExtensions(value: unknown) {
  if (!Array.isArray(value)) return []
  return value
    .filter((item): item is string => typeof item === 'string')
    .map((item) => item.toLowerCase().replace(/^\./, '').trim())
    .filter((item) => /^[a-z0-9][a-z0-9+_-]{0,15}$/.test(item))
    .slice(0, 24)
}

function cleanStrings(value: unknown, limit = 128) {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === 'string' && item.length > 0 && item.length < 128).slice(0, limit)
    : []
}

/** Validate and copy only the declarative fields Kaisola knows how to run. */
export function parseExtensionManifest(value: unknown, sourcePath?: string): { ok: true; manifest: ExtensionManifest } | { ok: false; message: string } {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return { ok: false, message: 'The manifest must be a JSON object.' }
  const raw = value as Record<string, unknown>
  const id = typeof raw.id === 'string' ? raw.id.trim().toLowerCase() : ''
  const name = typeof raw.name === 'string' ? raw.name.trim() : ''
  const version = typeof raw.version === 'string' ? raw.version.trim() : ''
  if (!/^[a-z0-9][a-z0-9._-]{2,79}$/.test(id)) return { ok: false, message: 'id must be 3–80 lowercase letters, numbers, dots, dashes, or underscores.' }
  if (!name || name.length > 100) return { ok: false, message: 'name is required and must be under 100 characters.' }
  if (!/^\d+\.\d+\.\d+(?:[-+][a-z0-9.-]+)?$/i.test(version)) return { ok: false, message: 'version must be semantic (for example 1.0.0).' }

  const allowedCategories = new Set<ExtensionCategory>(['Languages', 'Grammars', 'Language Servers', 'Debug Adapters', 'Themes', 'Icon Themes', 'MCP Servers', 'Previews'])
  const categories = Array.isArray(raw.categories)
    ? raw.categories.filter((item): item is ExtensionCategory => typeof item === 'string' && allowedCategories.has(item as ExtensionCategory)).slice(0, 8)
    : []
  const contrib = raw.contributions && typeof raw.contributions === 'object' && !Array.isArray(raw.contributions)
    ? raw.contributions as Record<string, unknown>
    : {}

  const languages: LanguageContribution[] = []
  if (Array.isArray(contrib.languages)) {
    for (const item of contrib.languages.slice(0, MAX_CONTRIBUTIONS)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue
      const lang = item as Record<string, unknown>
      const extensions = cleanExtensions(lang.extensions)
      if (!extensions.length) continue
      const grammarRaw = lang.grammar && typeof lang.grammar === 'object' ? lang.grammar as Record<string, unknown> : {}
      const blocks = Array.isArray(grammarRaw.blockComments)
        ? grammarRaw.blockComments.filter((pair): pair is [string, string] => Array.isArray(pair) && pair.length === 2 && pair.every((x) => typeof x === 'string' && x.length > 0 && x.length < 8)).slice(0, 4)
        : []
      languages.push({
        id: typeof lang.id === 'string' ? lang.id.slice(0, 64) : extensions[0],
        name: typeof lang.name === 'string' ? lang.name.slice(0, 100) : extensions[0].toUpperCase(),
        extensions,
        grammar: {
          type: 'simple',
          keywords: cleanStrings(grammarRaw.keywords),
          atoms: cleanStrings(grammarRaw.atoms),
          lineComments: cleanStrings(grammarRaw.lineComments, 4),
          blockComments: blocks,
        },
      })
    }
  }

  const previews: PreviewContribution[] = []
  if (Array.isArray(contrib.previews)) {
    for (const item of contrib.previews.slice(0, MAX_CONTRIBUTIONS)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue
      const preview = item as Record<string, unknown>
      const renderer = preview.renderer
      const extensions = cleanExtensions(preview.extensions)
      if (!extensions.length || (renderer !== 'csv' && renderer !== 'json' && renderer !== 'markdown' && renderer !== 'html')) continue
      previews.push({
        id: typeof preview.id === 'string' ? preview.id.slice(0, 64) : `${renderer}-preview`,
        name: typeof preview.name === 'string' ? preview.name.slice(0, 100) : `${renderer.toUpperCase()} Preview`,
        extensions,
        renderer,
      })
    }
  }

  const mcpServers: McpContribution[] = []
  if (Array.isArray(contrib.mcpServers)) {
    for (const item of contrib.mcpServers.slice(0, 8)) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue
      const mcp = item as Record<string, unknown>
      const config = mcp.config && typeof mcp.config === 'object' && !Array.isArray(mcp.config) ? mcp.config as Record<string, unknown> : {}
      const serverName = typeof mcp.name === 'string' ? mcp.name.trim().slice(0, 64) : ''
      const command = typeof config.command === 'string' ? config.command.trim().slice(0, 512) : undefined
      const url = typeof config.url === 'string' && /^https?:\/\//.test(config.url) ? config.url.slice(0, 2048) : undefined
      if (!serverName || (!command && !url) || (command && url)) continue
      const env = config.env && typeof config.env === 'object' && !Array.isArray(config.env)
        ? Object.fromEntries(Object.entries(config.env as Record<string, unknown>)
            .filter(([key, val]) => /^[A-Z_][A-Z0-9_]{0,127}$/.test(key) && typeof val === 'string')
            .slice(0, 32)) as Record<string, string>
        : undefined
      const headers = config.headers && typeof config.headers === 'object' && !Array.isArray(config.headers)
        ? Object.fromEntries(Object.entries(config.headers as Record<string, unknown>)
            .filter(([key, val]) => key.length < 128 && typeof val === 'string')
            .slice(0, 32)) as Record<string, string>
        : undefined
      mcpServers.push({ name: serverName, config: { command, url, args: cleanStrings(config.args, 64), env, headers } })
    }
  }

  const allCategories = categories.length ? categories : [
    ...(languages.length ? ['Languages', 'Grammars'] as ExtensionCategory[] : []),
    ...(previews.length ? ['Previews'] as ExtensionCategory[] : []),
    ...(mcpServers.length ? ['MCP Servers'] as ExtensionCategory[] : []),
  ]
  if (!languages.length && !previews.length && !mcpServers.length) {
    return { ok: false, message: 'No supported contributions found. Add a language, preview, or MCP server.' }
  }
  return {
    ok: true,
    manifest: {
      id,
      name,
      version,
      description: typeof raw.description === 'string' ? raw.description.trim().slice(0, 500) : '',
      author: typeof raw.author === 'string' ? raw.author.trim().slice(0, 100) : 'Local developer',
      categories: [...new Set(allCategories)],
      repository: typeof raw.repository === 'string' && /^https?:\/\//.test(raw.repository) ? raw.repository.slice(0, 2048) : undefined,
      sourcePath,
      contributions: { languages, previews, mcpServers },
    },
  }
}

function normalizedExt(ext: string | undefined) {
  return String(ext ?? '').toLowerCase().replace(/^\./, '')
}

export function languageContributionFor(ext: string | undefined) {
  const needle = normalizedExt(ext)
  if (!needle) return null
  for (const extension of extensionCatalog().slice().reverse()) {
    if (!isExtensionInstalled(extension.id)) continue
    const language = extension.contributions?.languages?.find((item) => item.extensions.includes(needle))
    if (language) return language
  }
  return null
}

export function previewContributionFor(ext: string | undefined) {
  const needle = normalizedExt(ext)
  if (!needle) return null
  for (const extension of extensionCatalog().slice().reverse()) {
    if (!isExtensionInstalled(extension.id)) continue
    const preview = extension.contributions?.previews?.find((item) => item.extensions.includes(needle))
    if (preview) return preview
  }
  return null
}

export function openExtensionsCenter() {
  if (typeof window !== 'undefined') window.dispatchEvent(new CustomEvent(OPEN_EVENT))
}

export function closeExtensionsCenter() {
  if (typeof window !== 'undefined') window.dispatchEvent(new CustomEvent(`${OPEN_EVENT}:close`))
}

export function onExtensionsOpen(open: () => void, close: () => void) {
  if (typeof window === 'undefined') return () => {}
  window.addEventListener(OPEN_EVENT, open)
  window.addEventListener(`${OPEN_EVENT}:close`, close)
  return () => {
    window.removeEventListener(OPEN_EVENT, open)
    window.removeEventListener(`${OPEN_EVENT}:close`, close)
  }
}
