#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const EXPECTED_ARCHITECTURES = Object.freeze(['arm64', 'x86_64'])
const EXPECTED_BUNDLE_IDENTIFIER = 'com.kaisola.mac'
const EXPECTED_HELPER_LABEL = 'com.kaisola.mac.broker-bootstrap'

function fail(message) {
  throw new Error(message)
}

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  })
  if (result.error) throw result.error
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim()
  if (result.status !== 0) {
    fail(`${path.basename(executable)} ${args[0] || ''} failed${output ? `: ${output}` : ''}`)
  }
  return output
}

function readPlist(file) {
  return JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file]))
}

function architectures(file) {
  return run('/usr/bin/lipo', ['-archs', file]).split(/\s+/).filter(Boolean).sort()
}

function requireExactArchitectures(actual, label) {
  const normalized = [...new Set(actual)].sort()
  if (JSON.stringify(normalized) !== JSON.stringify(EXPECTED_ARCHITECTURES)) {
    fail(`${label} must contain exactly arm64 and x86_64; found ${normalized.join(', ') || 'none'}`)
  }
  return normalized
}

function parseCodeSignature(output) {
  const authorities = [...String(output).matchAll(/^Authority=(.+)$/gm)].map((match) => match[1].trim())
  const rawTeamIdentifier = String(output).match(/^TeamIdentifier=(.+)$/m)?.[1]?.trim() || null
  const teamIdentifier = rawTeamIdentifier === 'not set' ? null : rawTeamIdentifier
  const flags = String(output).match(/^CodeDirectory .+ flags=.+\(([^)]*)\)/m)?.[1]
    ?.split(',')
    .map((flag) => flag.trim())
    .filter(Boolean) || []
  return {
    authorities,
    developerID: authorities.some((authority) => authority.startsWith('Developer ID Application:')),
    teamIdentifier,
    hardenedRuntime: flags.includes('runtime'),
    secureTimestamp: /^Timestamp=/m.test(String(output)),
  }
}

function validateNodeEntitlements(entitlements) {
  if (entitlements['com.apple.security.cs.allow-jit'] !== true
      || entitlements['com.apple.security.cs.allow-unsigned-executable-memory'] !== true) {
    fail('distribution Node runtime is missing its minimum JIT entitlements')
  }
  if (entitlements['com.apple.security.cs.disable-library-validation'] === true
      || entitlements['com.apple.security.get-task-allow'] === true) {
    fail('distribution Node runtime contains a forbidden code-signing entitlement')
  }
}

function validateLocalAppEntitlements(entitlements) {
  if (entitlements['com.apple.security.cs.disable-library-validation'] !== true) {
    fail('hardened ad-hoc preview must disable library validation to load embedded Sparkle')
  }
}

function validateDistributionAppEntitlements(entitlements) {
  if (entitlements['com.apple.security.cs.disable-library-validation'] === true
      || entitlements['com.apple.security.get-task-allow'] === true) {
    fail('distribution app contains a forbidden code-signing entitlement')
  }
}

function validateUpdateConfiguration(info, required = false) {
  const feed = typeof info.SUFeedURL === 'string' ? info.SUFeedURL.trim() : ''
  const publicKey = typeof info.SUPublicEDKey === 'string' ? info.SUPublicEDKey.trim() : ''
  if (!feed && !publicKey) {
    if (required) fail('Sparkle update feed and Ed25519 public key are required')
    return null
  }
  if (!feed || !publicKey) fail('Sparkle update configuration is incomplete')

  let url
  try { url = new URL(feed) } catch { fail('Sparkle update feed is not a valid URL') }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.hash) {
    fail('Sparkle update feed must use HTTPS without credentials or a fragment')
  }
  if (!/^[A-Za-z0-9+/]{43}=$/.test(publicKey)) {
    fail('Sparkle Ed25519 public key is not canonical base64')
  }
  const decoded = Buffer.from(publicKey, 'base64')
  if (decoded.length !== 32 || decoded.toString('base64') !== publicKey) {
    fail('Sparkle Ed25519 public key must encode exactly 32 bytes')
  }
  if (required && info.SUEnableAutomaticChecks !== true) {
    fail('distribution builds must check for updates automatically')
  }
  if (required && info.SUAutomaticallyUpdate !== true) {
    fail('distribution builds must download updates automatically')
  }
  return { feedURL: url.toString(), publicKeyBytes: decoded.length }
}

function validateLaunchAgent(plist) {
  if (plist.Label !== EXPECTED_HELPER_LABEL
      || plist.BundleProgram !== 'Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap'
      || plist.MachServices?.[EXPECTED_HELPER_LABEL] !== true
      || !Array.isArray(plist.AssociatedBundleIdentifiers)
      || !plist.AssociatedBundleIdentifiers.includes(EXPECTED_BUNDLE_IDENTIFIER)) {
    fail('bundled LaunchAgent does not point at the scoped broker bootstrap service')
  }
}

function codeSignature(file) {
  return parseCodeSignature(run('/usr/bin/codesign', ['-dv', '--verbose=4', file]))
}

function codeEntitlements(file) {
  const output = run('/usr/bin/codesign', ['-d', '--entitlements', ':-', file])
  const start = output.indexOf('<?xml')
  const end = output.lastIndexOf('</plist>')
  if (start < 0 || end < start) return {}
  return JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '--', '-'], {
    input: output.slice(start, end + '</plist>'.length),
  }))
}

function validateDistributionCode({ app, appSignature, helperRoot, manifest, node }) {
  if (!appSignature.developerID || !appSignature.teamIdentifier) {
    fail('distribution preflight requires a Developer ID Application signature and team identifier')
  }
  if (!appSignature.hardenedRuntime) fail('distribution app must enable the hardened runtime')
  if (!appSignature.secureTimestamp) fail('distribution app must carry a secure timestamp')
  validateDistributionAppEntitlements(codeEntitlements(app))

  const machOEntries = manifest.files.filter((entry) => entry?.machO)
  if (!machOEntries.length) fail('helper manifest contains no signed Mach-O code')
  for (const entry of machOEntries) {
    const signature = codeSignature(path.join(helperRoot, entry.path))
    if (!signature.developerID || signature.teamIdentifier !== appSignature.teamIdentifier) {
      fail(`helper code is not signed by the app Developer ID team: ${entry.path}`)
    }
    if (!signature.hardenedRuntime) fail(`helper code does not enable the hardened runtime: ${entry.path}`)
  }
  validateNodeEntitlements(codeEntitlements(node))
  validateEmbeddedFrameworks(app, appSignature)
}

/** Notarization rejects any nested executable without a Developer ID chain,
 *  hardened runtime, and secure timestamp. SPM-embedded frameworks ship with
 *  the vendor's ad-hoc signatures on their nested helpers (Sparkle's
 *  Autoupdate/Updater/XPC services), and Xcode re-signs only the framework
 *  bundle itself — so walk every Mach-O under Frameworks and hold it to the
 *  distribution standard before wasting a notarization round trip. */
function validateEmbeddedFrameworks(app, appSignature) {
  const frameworksRoot = path.join(app, 'Contents', 'Frameworks')
  if (!fs.existsSync(frameworksRoot)) return
  const pending = [frameworksRoot]
  while (pending.length) {
    const directory = pending.pop()
    for (const name of fs.readdirSync(directory)) {
      const absolute = path.join(directory, name)
      const stat = fs.lstatSync(absolute)
      if (stat.isSymbolicLink()) continue
      if (stat.isDirectory()) {
        pending.push(absolute)
        continue
      }
      if (!stat.isFile()) continue
      const header = Buffer.alloc(4)
      const fd = fs.openSync(absolute, 'r')
      try {
        fs.readSync(fd, header, 0, 4, 0)
      } finally {
        fs.closeSync(fd)
      }
      const magic = header.readUInt32BE(0)
      const machO = [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca].includes(magic)
      if (!machO) continue
      const relative = path.relative(app, absolute)
      const signature = codeSignature(absolute)
      if (!signature.developerID || signature.teamIdentifier !== appSignature.teamIdentifier) {
        fail(`embedded framework code is not signed by the app Developer ID team: ${relative}`)
      }
      if (!signature.hardenedRuntime) fail(`embedded framework code does not enable the hardened runtime: ${relative}`)
      if (!signature.secureTimestamp) fail(`embedded framework code has no secure timestamp: ${relative}`)
    }
  }
}

function parseArguments(argv) {
  const options = {
    requireUpdates: false,
    requireDeveloperID: false,
    requireNotarized: false,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--app') {
      const value = argv[++index]
      if (!value) fail('--app requires a path')
      options.app = path.resolve(value)
    } else if (argument === '--source-commit') {
      const value = argv[++index]
      if (!value || !/^[0-9a-f]{40}$/.test(value)) {
        fail('--source-commit must be a lowercase 40-character Git commit')
      }
      options.sourceCommit = value
    } else if (argument === '--json-output') {
      const value = argv[++index]
      if (!value) fail('--json-output requires a path')
      options.jsonOutput = path.resolve(value)
    } else if (argument === '--require-updates') options.requireUpdates = true
    else if (argument === '--require-developer-id') options.requireDeveloperID = true
    else if (argument === '--require-notarized') options.requireNotarized = true
    else if (argument === '--help' || argument === '-h') options.help = true
    else fail(`unknown argument: ${argument}`)
  }
  if (options.requireNotarized) options.requireDeveloperID = true
  return options
}

function usage() {
  return `Usage:
  node scripts/native-release-preflight.cjs --app /path/Kaisola.app \\
    [--require-updates] [--require-developer-id] [--require-notarized] \\
    [--source-commit <40-hex>] [--json-output <receipt.json>]

The default gate accepts a locally signed universal build. Distribution flags
add real Sparkle configuration, Developer ID, Gatekeeper, and stapling checks.`
}

function preflight(options) {
  if (!options.app) fail('preflight requires --app')
  const app = options.app
  const appStat = fs.lstatSync(app)
  if (!appStat.isDirectory() || appStat.isSymbolicLink()) fail('app path must be a real application directory')

  const contents = path.join(app, 'Contents')
  const infoFile = path.join(contents, 'Info.plist')
  const info = readPlist(infoFile)
  if (info.CFBundleIdentifier !== EXPECTED_BUNDLE_IDENTIFIER) {
    fail(`unexpected Kaisola bundle identifier: ${String(info.CFBundleIdentifier)}`)
  }

  const main = path.join(contents, 'MacOS', String(info.CFBundleExecutable || ''))
  const helperRoot = path.join(contents, 'Resources', 'BrokerHelper')
  const node = path.join(helperRoot, 'bin', 'node')
  const bootstrap = path.join(helperRoot, 'bin', 'kaisola-broker-bootstrap')
  const manifestFile = path.join(helperRoot, 'manifest.json')
  const launchAgentFile = path.join(contents, 'Library', 'LaunchAgents', `${EXPECTED_HELPER_LABEL}.plist`)
  const sparkle = path.join(contents, 'Frameworks', 'Sparkle.framework')
  for (const required of [main, node, bootstrap, manifestFile, launchAgentFile, sparkle]) {
    if (!fs.existsSync(required)) fail(`packaged build is missing ${path.relative(app, required)}`)
  }

  const appArchitectures = requireExactArchitectures(architectures(main), 'native app')
  const nodeArchitectures = requireExactArchitectures(architectures(node), 'Node runtime')
  const bootstrapArchitectures = requireExactArchitectures(architectures(bootstrap), 'broker bootstrap')
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
  requireExactArchitectures(manifest?.node?.architectures || [], 'helper manifest Node runtime')
  if (manifest.schemaVersion !== 1 || manifest.brokerImplementationVersion !== 1) {
    fail('helper manifest version is outside this preflight policy')
  }
  if (!/^[0-9a-f]{64}$/.test(String(manifest.contentDigest || ''))) {
    fail('helper manifest has no canonical content digest')
  }
  validateLaunchAgent(readPlist(launchAgentFile))
  const updates = validateUpdateConfiguration(info, options.requireUpdates)

  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=4', app])
  run(process.execPath, [
    path.join(__dirname, 'native-broker-package.cjs'),
    '--verify', helperRoot,
    '--require-signatures',
  ])
  run(bootstrap, ['--verify-package'])

  const signature = codeSignature(app)
  if (signature.developerID || options.requireDeveloperID) validateDistributionCode({
    app,
    appSignature: signature,
    helperRoot,
    manifest,
    node,
  })
  else {
    if (!signature.hardenedRuntime) fail('local preview must enable the hardened runtime')
    validateLocalAppEntitlements(codeEntitlements(app))
  }

  const launchProbe = run(main, ['--launch-probe'])
  if (launchProbe !== 'KAISOLA_NATIVE_LAUNCH_PROBE=PASS') {
    fail(`native launch probe returned unexpected output: ${launchProbe || 'empty'}`)
  }

  if (options.requireNotarized) {
    run('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=4', app])
    run('/usr/bin/xcrun', ['stapler', 'validate', app])
  }

  return {
    pass: true,
    app,
    sourceCommit: options.sourceCommit || null,
    bundleIdentifier: info.CFBundleIdentifier,
    version: info.CFBundleShortVersionString,
    build: info.CFBundleVersion,
    architectures: {
      app: appArchitectures,
      node: nodeArchitectures,
      bootstrap: bootstrapArchitectures,
    },
    helper: {
      packageVersion: manifest.packageVersion,
      contentDigest: manifest.contentDigest,
      schemaVersion: manifest.schemaVersion,
      implementationVersion: manifest.brokerImplementationVersion,
      protocol: {
        minimum: manifest.brokerProtocol?.minimum,
        maximum: manifest.brokerProtocol?.maximum,
        securityEpoch: manifest.brokerProtocol?.securityEpoch,
      },
      fileCount: manifest.files?.length,
    },
    updatesConfigured: updates != null,
    developerID: signature.developerID,
    teamIdentifier: signature.teamIdentifier,
    secureTimestamp: signature.secureTimestamp,
    notarizationRequired: options.requireNotarized,
    launchProbe: true,
  }
}

function writeJSONAtomic(destination, value) {
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}.${process.pid}.tmp`)
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: 'utf8',
      flag: 'wx',
      mode: 0o644,
    })
    fs.renameSync(temporary, destination)
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

if (require.main === module) {
  try {
    const options = parseArguments(process.argv.slice(2))
    if (options.help) console.log(usage())
    else {
      const receipt = preflight(options)
      if (options.jsonOutput) writeJSONAtomic(options.jsonOutput, receipt)
      console.log(`NATIVE_RELEASE_PREFLIGHT=${JSON.stringify(receipt)}`)
    }
  } catch (error) {
    console.error(`NATIVE_RELEASE_PREFLIGHT=FAIL ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = {
  EXPECTED_ARCHITECTURES,
  parseCodeSignature,
  parseArguments,
  preflight,
  requireExactArchitectures,
  validateDistributionAppEntitlements,
  validateLocalAppEntitlements,
  validateNodeEntitlements,
  validateLaunchAgent,
  validateUpdateConfiguration,
  writeJSONAtomic,
}
