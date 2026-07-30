#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const ADAPTER_PACKAGES = Object.freeze([
  Object.freeze({ agent: 'claude', packageName: '@agentclientprotocol/claude-agent-acp', namespace: 'current', legacy: false }),
  Object.freeze({ agent: 'codex', packageName: '@agentclientprotocol/codex-acp', namespace: 'current', legacy: false }),
  Object.freeze({ agent: 'claude', packageName: '@zed-industries/claude-code-acp', namespace: 'legacy', legacy: true }),
  Object.freeze({ agent: 'codex', packageName: '@zed-industries/codex-acp', namespace: 'legacy', legacy: true }),
])

const PACKAGE_NAME_RE = /^(@[a-z0-9~][\w.-]*\/)?[a-z0-9~][\w.-]*$/i
const EXACT_VERSION_RE = /^v?(\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$/

function defaultNpmRunner(packageName, fields = ['version', 'time.modified']) {
  let result
  try {
    result = spawnSync('npm', ['view', packageName, ...fields, '--json'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 30_000,
      maxBuffer: 1024 * 1024,
    })
  } catch (error) {
    return { ok: false, code: null, stdout: '', stderr: '', error: String(error?.message || error) }
  }
  if (result.error) {
    return {
      ok: false,
      code: result.status ?? null,
      stdout: String(result.stdout || ''),
      stderr: String(result.stderr || ''),
      error: String(result.error.message || result.error),
    }
  }
  return {
    ok: result.status === 0,
    code: result.status,
    stdout: String(result.stdout || ''),
    stderr: String(result.stderr || ''),
    error: result.status === 0 ? null : `npm exited with code ${result.status}`,
  }
}

function parseNpmResult(packageName, rawResult) {
  if (typeof rawResult === 'string') rawResult = { ok: true, stdout: rawResult }
  if (!rawResult || typeof rawResult !== 'object') {
    return { ok: false, status: 'npm-error', latestVersion: null, modified: null, error: 'npm runner returned no result' }
  }
  if (rawResult.ok === false) {
    return {
      ok: false,
      status: 'npm-error',
      latestVersion: null,
      modified: null,
      error: String(rawResult.error || rawResult.stderr || `npm view failed for ${packageName}`).trim(),
    }
  }

  let payload = rawResult.data
  if (payload == null) {
    try {
      payload = JSON.parse(String(rawResult.stdout || '').trim())
    } catch (error) {
      return {
        ok: false,
        status: 'invalid-response',
        latestVersion: null,
        modified: null,
        error: `invalid npm response for ${packageName}: ${String(error?.message || error)}`,
      }
    }
  }
  if (typeof payload === 'string') payload = { version: payload }
  const latestVersion = typeof payload?.version === 'string' ? payload.version.trim() : ''
  const modified = typeof payload?.['time.modified'] === 'string'
    ? payload['time.modified']
    : typeof payload?.time?.modified === 'string' ? payload.time.modified : null
  if (!latestVersion) {
    return { ok: false, status: 'invalid-response', latestVersion: null, modified, error: `npm returned no version for ${packageName}` }
  }
  return { ok: true, status: 'ok', latestVersion, modified, error: null }
}

function queryPublishedPackage(packageName, npmRunner = defaultNpmRunner) {
  if (!PACKAGE_NAME_RE.test(packageName)) {
    return { ok: false, status: 'invalid-package', latestVersion: null, modified: null, error: `invalid npm package name: ${packageName}` }
  }
  try {
    return parseNpmResult(packageName, npmRunner(packageName, ['version', 'time.modified']))
  } catch (error) {
    return {
      ok: false,
      status: 'npm-error',
      latestVersion: null,
      modified: null,
      error: String(error?.message || error),
    }
  }
}

function parseVersion(value) {
  if (typeof value !== 'string') return null
  const clean = value.trim().replace(/^v/, '').split('+', 1)[0]
  const [core, prerelease = ''] = clean.split('-', 2)
  const numbers = core.split('.').map(Number)
  if (numbers.length < 2 || numbers.length > 4 || numbers.some((part) => !Number.isSafeInteger(part) || part < 0)) return null
  return { numbers, prerelease: prerelease ? prerelease.split('.') : [] }
}

function compareIdentifiers(left, right) {
  const leftNumber = /^\d+$/.test(left) ? Number(left) : null
  const rightNumber = /^\d+$/.test(right) ? Number(right) : null
  if (leftNumber != null && rightNumber != null) return Math.sign(leftNumber - rightNumber)
  if (leftNumber != null) return -1
  if (rightNumber != null) return 1
  return left.localeCompare(right)
}

function compareVersions(left, right) {
  const a = parseVersion(left)
  const b = parseVersion(right)
  if (!a || !b) return null
  const width = Math.max(a.numbers.length, b.numbers.length)
  for (let index = 0; index < width; index += 1) {
    const difference = (a.numbers[index] || 0) - (b.numbers[index] || 0)
    if (difference) return Math.sign(difference)
  }
  if (!a.prerelease.length && !b.prerelease.length) return 0
  if (!a.prerelease.length) return 1
  if (!b.prerelease.length) return -1
  for (let index = 0; index < Math.max(a.prerelease.length, b.prerelease.length); index += 1) {
    if (a.prerelease[index] == null) return -1
    if (b.prerelease[index] == null) return 1
    const difference = compareIdentifiers(a.prerelease[index], b.prerelease[index])
    if (difference) return difference
  }
  return 0
}

function versionFromSpecifier(specifier) {
  if (typeof specifier !== 'string') return null
  const match = specifier.trim().match(EXACT_VERSION_RE)
  return match ? match[1] : null
}

function declaredPackage(packageJson, packageName) {
  for (const section of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
    const specifier = packageJson?.[section]?.[packageName]
    if (typeof specifier === 'string') return { section, specifier }
  }
  return { section: null, specifier: null }
}

function readJsonIfPresent(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return null }
}

function findInstalledVersion(packageName, options = {}) {
  if (typeof options.installedVersions?.[packageName] === 'string') return options.installedVersions[packageName]
  const root = options.projectRoot || process.cwd()
  const manifest = readJsonIfPresent(path.join(root, 'node_modules', ...packageName.split('/'), 'package.json'))
  if (typeof manifest?.version === 'string') return manifest.version
  const lock = options.packageLock || readJsonIfPresent(path.join(root, 'package-lock.json'))
  const locked = lock?.packages?.[`node_modules/${packageName}`]?.version
  return typeof locked === 'string' ? locked : null
}

function extractNpxPackage(raw) {
  if (!raw || typeof raw !== 'object' || raw.command !== 'npx' || !Array.isArray(raw.args)) return null
  let index = 0
  while (index < raw.args.length && ['-y', '--yes', '-q', '--quiet'].includes(raw.args[index])) index += 1
  const spec = raw.args[index]
  if (typeof spec !== 'string' || !spec || spec.startsWith('-')) return null
  const at = spec.lastIndexOf('@')
  const packageName = at > 0 ? spec.slice(0, at) : spec
  return PACKAGE_NAME_RE.test(packageName) ? packageName : null
}

function isMcpDependency(packageName) {
  return packageName.startsWith('@modelcontextprotocol/server-')
    || /(^|[/.-])mcp([/.-]|$)/i.test(packageName)
    || /mcp-server/i.test(packageName)
}

function configuredMcpPackages(packageJson, options = {}) {
  const packages = new Set()
  for (const section of ['dependencies', 'devDependencies', 'optionalDependencies']) {
    for (const packageName of Object.keys(packageJson?.[section] || {})) {
      if (isMcpDependency(packageName)) packages.add(packageName)
    }
  }
  for (const configData of options.mcpConfigs || []) {
    const servers = configData && typeof configData === 'object' && !Array.isArray(configData) ? configData.mcpServers : null
    if (!servers || typeof servers !== 'object' || Array.isArray(servers)) continue
    for (const raw of Object.values(servers)) {
      const packageName = extractNpxPackage(raw)
      if (packageName) packages.add(packageName)
    }
  }
  return [...packages].sort()
}

function recommendationFor(agent, packages) {
  const current = packages.find((entry) => entry.agent === agent && !entry.legacy)
  const legacy = packages.find((entry) => entry.agent === agent && entry.legacy)
  const currentModified = Date.parse(current?.modified || '')
  const legacyModified = Date.parse(legacy?.modified || '')
  const currentPublishedMoreRecently = Number.isFinite(currentModified) && Number.isFinite(legacyModified)
    ? currentModified >= legacyModified
    : null
  return {
    packageName: current.packageName,
    latestVersion: current.latestVersion,
    legacyPackageName: legacy.packageName,
    legacyLatestVersion: legacy.latestVersion,
    currentPublishedMoreRecently,
    reason: 'The @agentclientprotocol namespace is current; @zed-industries is retained only for legacy compatibility.',
  }
}

function createVersionReport(options = {}) {
  const packageJsonPath = path.resolve(options.packageJsonPath || path.join(process.cwd(), 'package.json'))
  const packageJson = options.packageJson || readJsonIfPresent(packageJsonPath) || {}
  const projectRoot = options.projectRoot || path.dirname(packageJsonPath)
  const extraPackages = [...new Set(options.extraPackages || [])]
    .filter((packageName) => PACKAGE_NAME_RE.test(packageName) && !ADAPTER_PACKAGES.some((entry) => entry.packageName === packageName))
    .sort()
  const definitions = [
    ...ADAPTER_PACKAGES,
    ...extraPackages.map((packageName) => ({ agent: null, packageName, namespace: 'mcp', legacy: false, kind: 'mcp' })),
  ]
  const packages = definitions.map((definition) => {
    const published = queryPublishedPackage(definition.packageName, options.npmRunner)
    const declared = declaredPackage(packageJson, definition.packageName)
    const installedVersion = findInstalledVersion(definition.packageName, {
      projectRoot,
      installedVersions: options.installedVersions,
      packageLock: options.packageLock,
    })
    const comparisonVersion = installedVersion || versionFromSpecifier(declared.specifier)
    const comparison = comparisonVersion && published.latestVersion ? compareVersions(comparisonVersion, published.latestVersion) : null
    return {
      kind: definition.kind || 'adapter',
      agent: definition.agent,
      packageName: definition.packageName,
      namespace: definition.namespace,
      legacy: definition.legacy,
      declaredSection: declared.section,
      declaredSpecifier: declared.specifier,
      installedVersion,
      latestVersion: published.latestVersion,
      modified: published.modified,
      updateAvailable: comparison == null ? null : comparison < 0,
      status: published.status,
      error: published.error,
    }
  })
  return {
    schemaVersion: 1,
    checkedAt: typeof options.now === 'function' ? options.now() : new Date().toISOString(),
    ok: packages.every((entry) => entry.status === 'ok'),
    packages,
    recommendations: {
      claude: recommendationFor('claude', packages),
      codex: recommendationFor('codex', packages),
    },
  }
}

function usage() {
  return 'Usage: node scripts/agent-adapter-versions.cjs check [--json]'
}

function main(argv) {
  const args = argv.filter((argument) => argument !== '--json')
  if (args.length > 1 || (args[0] && args[0] !== 'check')) {
    console.error(usage())
    process.exitCode = 2
    return
  }
  const packageJsonPath = path.join(__dirname, '..', 'package.json')
  const packageJson = readJsonIfPresent(packageJsonPath) || {}
  const extraPackages = configuredMcpPackages(packageJson)
  console.log(JSON.stringify(createVersionReport({ packageJson, packageJsonPath, extraPackages }), null, 2))
}

if (require.main === module) main(process.argv.slice(2))

module.exports = {
  ADAPTER_PACKAGES,
  compareVersions,
  configuredMcpPackages,
  createVersionReport,
  defaultNpmRunner,
  extractNpxPackage,
  findInstalledVersion,
  isMcpDependency,
  parseNpmResult,
  queryPublishedPackage,
  versionFromSpecifier,
}
