#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const {
  compareVersions,
  configuredMcpPackages,
  createVersionReport,
  versionFromSpecifier,
} = require('./agent-adapter-versions.cjs')

const DEFAULT_INTERVAL_SECONDS = 21_600
const DEPENDENCY_SECTIONS = ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']

function nextSpecifier(current, latestVersion) {
  if (typeof current !== 'string' || typeof latestVersion !== 'string') return null
  const trimmed = current.trim()
  const prefix = trimmed.startsWith('^') ? '^' : trimmed.startsWith('~') ? '~' : ''
  const currentVersion = versionFromSpecifier(prefix ? trimmed.slice(1) : trimmed)
  if (!currentVersion || compareVersions(currentVersion, latestVersion) == null) return null
  return compareVersions(currentVersion, latestVersion) < 0 ? `${prefix}${latestVersion}` : trimmed
}

function atomicWritePackageJson(file, packageJson) {
  const directory = path.dirname(file)
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.tmp`)
  const mode = (() => {
    try { return fs.statSync(file).mode & 0o777 } catch { return 0o644 }
  })()
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(packageJson, null, 2)}\n`, { mode })
    fs.renameSync(temporary, file)
  } finally {
    try { fs.unlinkSync(temporary) } catch { /* already moved or never created */ }
  }
}

function readMcpConfigs(paths) {
  return paths.flatMap((file) => {
    try { return [JSON.parse(fs.readFileSync(file, 'utf8'))] } catch { return [] }
  })
}

function runOnce(options = {}) {
  const packageJsonPath = path.resolve(options.packageJsonPath || path.join(__dirname, '..', 'package.json'))
  let packageJson
  try {
    packageJson = options.packageJson
      ? JSON.parse(JSON.stringify(options.packageJson))
      : JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'))
  } catch (error) {
    return {
      ok: false,
      checkedAt: typeof options.now === 'function' ? options.now() : new Date().toISOString(),
      packageJsonPath,
      written: false,
      updates: [],
      installCommand: null,
      error: `could not read package.json: ${String(error?.message || error)}`,
    }
  }

  const configPaths = options.mcpConfigPaths || [path.join(path.dirname(packageJsonPath), '.mcp.json')]
  const mcpConfigs = options.mcpConfigs || readMcpConfigs(configPaths)
  const mcpPackages = configuredMcpPackages(packageJson, { mcpConfigs })
  const report = createVersionReport({
    packageJson,
    packageJsonPath,
    projectRoot: options.projectRoot || path.dirname(packageJsonPath),
    packageLock: options.packageLock,
    installedVersions: options.installedVersions,
    npmRunner: options.npmRunner,
    now: options.now,
    extraPackages: mcpPackages,
  })
  const published = new Map(report.packages.map((entry) => [entry.packageName, entry]))
  const updates = []
  for (const section of DEPENDENCY_SECTIONS) {
    for (const [packageName, current] of Object.entries(packageJson[section] || {})) {
      const latest = published.get(packageName)
      if (!latest?.latestVersion) continue
      const replacement = nextSpecifier(current, latest.latestVersion)
      if (!replacement || replacement === current) continue
      packageJson[section][packageName] = replacement
      updates.push({
        packageName,
        kind: latest.kind,
        section,
        from: current,
        to: replacement,
        latestVersion: latest.latestVersion,
      })
    }
  }

  let written = false
  let writeError = null
  if (updates.length > 0 && !options.dryRun) {
    try {
      atomicWritePackageJson(packageJsonPath, packageJson)
      written = true
    } catch (error) {
      writeError = `could not write package.json: ${String(error?.message || error)}`
    }
  }
  return {
    ok: report.ok && !writeError,
    checkedAt: report.checkedAt,
    packageJsonPath,
    written,
    dryRun: !!options.dryRun,
    updates,
    installCommand: updates.length > 0 ? 'npm install' : null,
    report,
    error: writeError,
  }
}

function normalizeIntervalSeconds(value) {
  if (value == null) return DEFAULT_INTERVAL_SECONDS
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number < 1) throw new Error('--interval-seconds must be a positive integer')
  return number
}

function startWatch(options = {}) {
  const intervalSeconds = normalizeIntervalSeconds(options.intervalSeconds)
  const clock = options.clock || { setInterval, clearInterval }
  const logger = options.logger || console
  const once = options.runOnce || (() => runOnce(options))
  let running = false
  let stopped = false
  let tickCount = 0

  const tick = () => {
    if (stopped) return { ok: false, skipped: true, reason: 'stopped' }
    if (running) return { ok: false, skipped: true, reason: 'check-already-running' }
    running = true
    tickCount += 1
    const startedAt = typeof options.now === 'function' ? options.now() : new Date().toISOString()
    try {
      const result = once()
      logger.log(`[agent-update] ${startedAt} check ${tickCount}: ${result.ok ? 'ok' : 'degraded'}, ${result.updates?.length || 0} update(s)`)
      if (result.installCommand) logger.log(`[agent-update] run: ${result.installCommand}`)
      return result
    } catch (error) {
      const result = { ok: false, checkedAt: startedAt, updates: [], error: String(error?.message || error) }
      logger.error(`[agent-update] ${startedAt} check ${tickCount} failed: ${result.error}`)
      return result
    } finally {
      running = false
    }
  }

  const firstResult = options.immediate === false ? null : tick()
  const timer = clock.setInterval(tick, intervalSeconds * 1000)
  return {
    intervalSeconds,
    firstResult,
    tick,
    stop() {
      if (stopped) return
      stopped = true
      clock.clearInterval(timer)
    },
  }
}

function parseArguments(argv) {
  const options = { command: 'once', json: false }
  let index = 0
  if (argv[0] === 'once' || argv[0] === 'watch') options.command = argv[index++]
  for (; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--json') options.json = true
    else if (argument === '--interval-seconds') {
      if (argv[index + 1] == null) throw new Error('--interval-seconds requires a value')
      options.intervalSeconds = normalizeIntervalSeconds(argv[++index])
    } else throw new Error(`unknown argument: ${argument}`)
  }
  if (options.command !== 'watch' && options.intervalSeconds != null) throw new Error('--interval-seconds is only valid with watch')
  return options
}

function printOnce(result, json) {
  if (json) {
    console.log(JSON.stringify(result, null, 2))
    return
  }
  if (!result.updates.length) console.log('Agent adapters and configured MCP packages are already current.')
  for (const update of result.updates) {
    console.log(`${update.packageName}: ${update.from} -> ${update.to} (${update.section})`)
  }
  if (result.written) console.log(`Updated ${result.packageJsonPath}`)
  if (result.installCommand) console.log(`Run: ${result.installCommand}`)
  const failures = result.report?.packages?.filter((entry) => entry.status !== 'ok') || []
  for (const failure of failures) console.warn(`${failure.packageName}: ${failure.error}`)
  if (result.error) console.warn(result.error)
}

function usage() {
  return `Usage:
  node scripts/agent-adapter-update.cjs once [--json]
  node scripts/agent-adapter-update.cjs watch [--interval-seconds N]`
}

function main(argv) {
  let options
  try { options = parseArguments(argv) } catch (error) {
    console.error(String(error?.message || error))
    console.error(usage())
    process.exitCode = 2
    return
  }
  if (options.command === 'watch') {
    console.log(`[agent-update] watching every ${normalizeIntervalSeconds(options.intervalSeconds)} seconds`)
    startWatch({ intervalSeconds: options.intervalSeconds })
    return
  }
  printOnce(runOnce(), options.json)
}

if (require.main === module) main(process.argv.slice(2))

module.exports = {
  DEFAULT_INTERVAL_SECONDS,
  atomicWritePackageJson,
  nextSpecifier,
  normalizeIntervalSeconds,
  parseArguments,
  runOnce,
  startWatch,
}
