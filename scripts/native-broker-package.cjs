#!/usr/bin/env node
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const repoRoot = path.resolve(__dirname, '..')
const policyFile = path.join(repoRoot, 'native', 'KaisolaMac', 'BrokerHelper', 'package-policy.json')
const manifestName = 'manifest.json'

const brokerSources = Object.freeze([
  'runtime/node-broker/session-broker.cjs',
  'runtime/node-broker/ipc/brokerInventorySnapshot.cjs',
  'runtime/node-broker/ipc/brokerRejectionPolicy.cjs',
  'runtime/node-broker/ipc/brokerRequestGate.cjs',
  'runtime/node-broker/ipc/brokerWire.cjs',
  'runtime/node-broker/ipc/securityPolicy.cjs',
  'runtime/node-broker/ipc/shellEnv.cjs',
  'runtime/node-broker/ipc/nativeAgentPaths.cjs',
  'runtime/node-broker/ipc/usageHandler.cjs',
  'runtime/node-broker/ipc/terminalCreateRoute.cjs',
  'runtime/node-broker/ipc/terminalDetachOwnerRoute.cjs',
  'runtime/node-broker/ipc/terminalManager.cjs',
  'runtime/node-broker/ipc/terminalObservers.cjs',
  'runtime/node-broker/ipc/terminalSpool.cjs',
  'runtime/node-broker/ipc/terminalText.cjs',
  'runtime/node-broker/companion/protocol.cjs',
  'runtime/node-broker/companion/terminalCursor.cjs',
  'scripts/native-usage-service.cjs',
])

function fail(message) {
  const error = new Error(message)
  error.name = 'NativeBrokerPackageError'
  throw error
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function run(command, args, { allowFailure = false, encoding = 'utf8' } = {}) {
  const result = spawnSync(command, args, { encoding, stdio: ['ignore', 'pipe', 'pipe'] })
  if (!allowFailure && (result.error || result.status !== 0)) {
    const detail = String(result.stderr || result.stdout || result.error?.message || '').trim()
    fail(`${command} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`)
  }
  return result
}

function sha256(file) {
  const hash = crypto.createHash('sha256')
  hash.update(fs.readFileSync(file))
  return hash.digest('hex')
}

// Frozen schema-1 identity for the behavior-bearing Node helper payload.
// `generatedAt`, code signing metadata, and JSON formatting are deliberately
// excluded. Keep this byte stream unchanged while schema-1 packages can remain
// installed or draining.
function contentDigestV1(manifest) {
  const hash = crypto.createHash('sha256')
  const field = (value) => {
    const bytes = Buffer.from(String(value), 'utf8')
    hash.update(Buffer.from(`${bytes.length}:`, 'ascii'))
    hash.update(bytes)
  }
  field('kaisola-broker-helper-content-v1')
  field(manifest.schemaVersion)
  field(manifest.packageVersion)
  field(manifest.brokerImplementationVersion)
  field(manifest.brokerProtocol?.minimum)
  field(manifest.brokerProtocol?.maximum)
  field(manifest.brokerProtocol?.securityEpoch)
  for (const record of [...(manifest.files || [])].sort((a, b) => String(a.path) < String(b.path) ? -1 : String(a.path) > String(b.path) ? 1 : 0)) {
    field(record.path)
    field(record.size)
    field(record.mode)
    field(String(record.sha256).toLowerCase())
  }
  return hash.digest('hex')
}

// Schema 2 binds the native launch authority and release provenance in
// addition to the compatibility envelope and sealed files. Arrays retain
// their declared order; files remain path-sorted so JSON ordering is inert.
function contentDigestV2(manifest) {
  const hash = crypto.createHash('sha256')
  const field = (value) => {
    const bytes = Buffer.from(String(value), 'utf8')
    hash.update(Buffer.from(`${bytes.length}:`, 'ascii'))
    hash.update(bytes)
  }
  field('kaisola-broker-helper-content-v2')
  field(manifest.schemaVersion)
  field(manifest.packageVersion)
  field(manifest.appRelease?.version)
  field(manifest.appRelease?.build)
  field(manifest.brokerImplementationVersion)
  field(manifest.brokerProtocol?.minimum)
  field(manifest.brokerProtocol?.maximum)
  field(manifest.brokerProtocol?.securityEpoch)
  field(manifest.launch?.kind)
  field(manifest.launch?.executable)
  const argumentsValue = Array.isArray(manifest.launch?.arguments) ? manifest.launch.arguments : []
  field(argumentsValue.length)
  for (const argument of argumentsValue) field(argument)
  for (const record of [...(manifest.files || [])].sort((a, b) => String(a.path) < String(b.path) ? -1 : String(a.path) > String(b.path) ? 1 : 0)) {
    field(record.path)
    field(record.role)
    field(record.size)
    field(record.mode)
    field(String(record.sha256).toLowerCase())
    const architectures = Array.isArray(record.machO?.architectures) ? record.machO.architectures : []
    field(architectures.length)
    for (const architecture of architectures) field(architecture)
    field(record.machO?.designatedRequirement || '')
  }
  return hash.digest('hex')
}

function contentDigest(manifest) {
  if (manifest?.schemaVersion === 1) return contentDigestV1(manifest)
  if (manifest?.schemaVersion === 2) return contentDigestV2(manifest)
  fail(`unsupported helper manifest schema: ${manifest?.schemaVersion}`)
}

function ensureDirectory(directory, mode = 0o755) {
  fs.mkdirSync(directory, { recursive: true, mode })
  fs.chmodSync(directory, mode)
}

function copyFile(source, destination, mode) {
  const stat = fs.lstatSync(source)
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`refusing non-regular package source: ${source}`)
  ensureDirectory(path.dirname(destination))
  fs.copyFileSync(source, destination)
  fs.chmodSync(destination, mode)
}

function copyTree(source, destination, predicate = () => true) {
  const rootStat = fs.lstatSync(source)
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) fail(`refusing non-directory package source: ${source}`)
  ensureDirectory(destination)
  for (const name of fs.readdirSync(source).sort()) {
    const from = path.join(source, name)
    const relative = path.relative(source, from)
    const stat = fs.lstatSync(from)
    if (stat.isSymbolicLink()) fail(`refusing symlink in package source: ${from}`)
    if (stat.isDirectory()) {
      copyTree(from, path.join(destination, name), (nested, nestedStat) => predicate(path.join(relative, nested), nestedStat))
    } else if (stat.isFile() && predicate(relative, stat)) {
      copyFile(from, path.join(destination, name), stat.mode & 0o111 ? 0o755 : 0o644)
    }
  }
}

function walkFiles(root) {
  const files = []
  const visit = (directory) => {
    for (const name of fs.readdirSync(directory).sort()) {
      const absolute = path.join(directory, name)
      const stat = fs.lstatSync(absolute)
      if (stat.isSymbolicLink()) fail(`package contains a symlink: ${path.relative(root, absolute)}`)
      if (stat.isDirectory()) {
        if (stat.mode & 0o022) fail(`package directory is group/world writable: ${path.relative(root, absolute)}`)
        visit(absolute)
      } else if (stat.isFile()) {
        files.push({ absolute, relative: path.relative(root, absolute).split(path.sep).join('/'), stat })
      } else {
        fail(`package contains a non-regular entry: ${path.relative(root, absolute)}`)
      }
    }
  }
  visit(root)
  return files
}

function machoDetails(file) {
  const description = String(run('/usr/bin/file', ['-b', file]).stdout || '').trim()
  if (!description.includes('Mach-O')) return null
  const result = run('/usr/bin/lipo', ['-archs', file], { allowFailure: true })
  const architectures = result.status === 0
    ? String(result.stdout).trim().split(/\s+/).filter(Boolean).map((arch) => arch === 'x86_64' ? 'x86_64' : arch).sort()
    : []
  return { description, architectures }
}

function designatedRequirement(file) {
  const result = run('/usr/bin/codesign', ['-d', '-r-', file], { allowFailure: true })
  const output = `${result.stdout || ''}\n${result.stderr || ''}`
  const match = output.match(/designated => (.+)/)
  return result.status === 0 && match ? match[1].trim() : null
}

function roleFor(relative) {
  if (relative === 'bin/node') return 'node-runtime'
  if (relative === 'bin/kaisola-broker-bootstrap') return 'launch-agent-bootstrap'
  if (relative === 'bin/kaisola-session-broker') return 'session-broker-executable'
  if (relative.endsWith('/pty.node')) return 'native-module'
  if (relative.endsWith('/spawn-helper')) return 'node-pty-spawn-helper'
  if (relative.endsWith('.cjs') || relative.endsWith('.js') || relative.endsWith('.mjs')) return 'broker-javascript'
  if (relative.includes('/LICENSE') || relative.startsWith('LICENSES/')) return 'license'
  return 'resource'
}

function isSafePackagePath(value) {
  if (typeof value !== 'string'
      || value.length < 1
      || value.startsWith('/')
      || value.includes('\\')
      || value.includes('\0')) return false
  return value.split('/').every((component) => component.length > 0 && component !== '.' && component !== '..')
}

function validateNativeV2Manifest(manifest, policy) {
  if (typeof manifest.appRelease?.version !== 'string'
      || manifest.appRelease.version.length < 1
      || manifest.appRelease.version.length > 64
      || typeof manifest.appRelease?.build !== 'string'
      || manifest.appRelease.build.length < 1
      || manifest.appRelease.build.length > 64) {
    fail('native schema-2 app release is invalid')
  }
  if (policy.appRelease
      && (manifest.appRelease.version !== policy.appRelease.version
        || manifest.appRelease.build !== policy.appRelease.build)) {
    fail('native schema-2 app release does not match package policy')
  }
  if (manifest.launch?.kind !== 'native'
      || !isSafePackagePath(manifest.launch?.executable)) {
    fail('native launch authority is invalid')
  }
  const argumentsValue = manifest.launch?.arguments
  if (!Array.isArray(argumentsValue)
      || argumentsValue.length > 32
      || argumentsValue.some((argument) => typeof argument !== 'string'
        || Buffer.byteLength(argument, 'utf8') < 1
        || Buffer.byteLength(argument, 'utf8') > 4_096
        || argument.includes('\0')
        || argument === '--launch'
        || argument === '--pty-child')) {
    fail('native static launch arguments are invalid')
  }
  if (!Array.isArray(manifest.files)) fail('native schema-2 file inventory is invalid')
  const executables = manifest.files.filter((record) => record?.role === 'session-broker-executable')
  if (executables.length !== 1) fail('native package requires exactly one session-broker-executable')
  const executable = executables[0]
  if (manifest.launch.executable !== executable.path) {
    fail('native launch executable does not match session-broker-executable')
  }
  if (executable.mode !== '0755') fail('native executable mode must be 0755')
  if (!executable.machO
      || !Array.isArray(executable.machO.architectures)
      || executable.machO.architectures.length !== 1
      || executable.machO.architectures[0] !== 'arm64') {
    fail('native executable must declare exactly arm64')
  }
  if (typeof executable.machO.designatedRequirement !== 'string'
      || executable.machO.designatedRequirement.length < 1) {
    fail('native executable designated requirement is missing')
  }
  for (const record of manifest.files) {
    if (record?.machO
        && (!Array.isArray(record.machO.architectures)
          || record.machO.architectures.length !== 1
          || record.machO.architectures[0] !== 'arm64')) {
      fail(`native Mach-O must declare exactly arm64: ${record?.path}`)
    }
  }
  if (policy.requireBootstrap === true) {
    const bootstrapRecords = manifest.files.filter(
      (record) => record?.role === 'launch-agent-bootstrap',
    )
    if (bootstrapRecords.length !== 1
        || bootstrapRecords[0].path !== 'bin/kaisola-broker-bootstrap') {
      fail('native package bootstrap is required at bin/kaisola-broker-bootstrap')
    }
    const bootstrap = bootstrapRecords[0]
    if (bootstrap.mode !== '0755'
        || !bootstrap.machO
        || !Array.isArray(bootstrap.machO.architectures)
        || bootstrap.machO.architectures.length !== 1
        || bootstrap.machO.architectures[0] !== 'arm64'
        || typeof bootstrap.machO.designatedRequirement !== 'string'
        || bootstrap.machO.designatedRequirement.length < 1) {
      fail('native bootstrap must be a signed arm64 Mach-O with mode 0755')
    }
  }
}

function createManifest(root, metadata) {
  const files = walkFiles(root)
    .filter(({ relative }) => relative !== manifestName)
    .map(({ absolute, relative, stat }) => {
      const macho = machoDetails(absolute)
      return {
        path: relative,
        role: roleFor(relative),
        size: stat.size,
        mode: (stat.mode & 0o777).toString(8).padStart(4, '0'),
        sha256: sha256(absolute),
        ...(macho ? {
          machO: {
            architectures: macho.architectures,
            designatedRequirement: designatedRequirement(absolute),
          },
        } : {}),
      }
    })
  const manifest = { ...metadata, files }
  return { ...manifest, contentDigest: contentDigest(manifest) }
}

function verifyPackage(root, { requireSignatures = false, policy = readJSON(policyFile) } = {}) {
  const manifestFile = path.join(root, manifestName)
  const manifestStat = fs.lstatSync(manifestFile)
  if (manifestStat.isSymbolicLink() || !manifestStat.isFile()) fail('helper manifest is not a regular file')
  const manifest = readJSON(manifestFile)
  if (manifest.schemaVersion === 2 && manifestStat.nlink !== 1) {
    fail('native manifest has invalid link count')
  }
  if (manifest.schemaVersion !== policy.schemaVersion) fail('helper manifest schema does not match package policy')
  if (manifest.packageVersion !== policy.packageVersion) fail('helper package version does not match package policy')
  if (manifest.brokerImplementationVersion !== policy.brokerImplementationVersion) fail('broker implementation version does not match package policy')
  if (!policy.brokerProtocol
      || manifest.brokerProtocol?.minimum !== policy.brokerProtocol.minimum
      || manifest.brokerProtocol?.maximum !== policy.brokerProtocol.maximum
      || manifest.brokerProtocol?.securityEpoch !== policy.brokerProtocol.securityEpoch) {
    fail('broker protocol does not match package policy')
  }
  if (manifest.schemaVersion === 1) {
    if (Object.hasOwn(manifest, 'appRelease') || Object.hasOwn(manifest, 'launch')) {
      fail('schema-1 package cannot contain native launch metadata')
    }
    if (manifest.node?.version !== policy.node.version || String(manifest.node?.abi) !== String(policy.node.abi)) {
      fail('helper Node runtime does not match package policy')
    }
    if (manifest.nodePty?.version !== policy.nodePtyVersion) fail('helper node-pty version does not match package policy')
    if (policy.claudeAgentSDKVersion
        && manifest.claudeAgentSDK?.version !== policy.claudeAgentSDKVersion) {
      fail('helper Claude Agent SDK version does not match package policy')
    }
  } else if (manifest.schemaVersion === 2) {
    if (Object.hasOwn(manifest, 'node') || Object.hasOwn(manifest, 'nodePty')) {
      fail('schema-2 package cannot contain Node runtime metadata')
    }
    validateNativeV2Manifest(manifest, policy)
  } else {
    fail(`unsupported helper manifest schema: ${manifest.schemaVersion}`)
  }
  if (!/^[0-9a-f]{64}$/.test(String(manifest.contentDigest || ''))
      || manifest.contentDigest !== contentDigest(manifest)) {
    fail('helper content digest does not match sealed package inventory')
  }

  const actual = new Map(walkFiles(root)
    .filter(({ relative }) => relative !== manifestName)
    .map((entry) => [entry.relative, entry]))
  if (!Array.isArray(manifest.files) || manifest.files.length !== actual.size) fail('helper manifest file inventory is incomplete')
  for (const expected of manifest.files) {
    const safePath = manifest.schemaVersion === 1
      ? expected && typeof expected.path === 'string' && !expected.path.includes('..') && !path.isAbsolute(expected.path)
      : expected && isSafePackagePath(expected.path)
    if (!safePath) {
      fail('helper manifest contains an unsafe path')
    }
    const entry = actual.get(expected.path)
    if (!entry) fail(`helper package is missing ${expected.path}`)
    if (manifest.schemaVersion === 2 && entry.stat.nlink !== 1) {
      fail(`native package file has invalid link count: ${expected.path}`)
    }
    if (entry.stat.size !== expected.size || sha256(entry.absolute) !== expected.sha256) {
      fail(`helper package integrity mismatch: ${expected.path}`)
    }
    const mode = (entry.stat.mode & 0o777).toString(8).padStart(4, '0')
    if (mode !== expected.mode || (entry.stat.mode & 0o022)) fail(`helper package mode mismatch: ${expected.path}`)
    const macho = machoDetails(entry.absolute)
    if (Boolean(macho) !== Boolean(expected.machO)) fail(`helper Mach-O inventory mismatch: ${expected.path}`)
    if (macho) {
      const requirement = designatedRequirement(entry.absolute)
      if (manifest.schemaVersion === 2
          && JSON.stringify(macho.architectures) !== JSON.stringify(expected.machO.architectures)) {
        fail(`native Mach-O architecture mismatch: ${expected.path}`)
      }
      if ((manifest.schemaVersion === 1 || requireSignatures)
          && (expected.machO.designatedRequirement || null) !== requirement) {
        fail(`helper designated requirement mismatch: ${expected.path}`)
      }
      if (requireSignatures && !requirement) fail(`helper nested code is unsigned: ${expected.path}`)
      if (requireSignatures) run('/usr/bin/codesign', ['--verify', '--strict', entry.absolute])
    }
    actual.delete(expected.path)
  }
  if (actual.size) fail(`helper package has unmanifested files: ${[...actual.keys()].join(', ')}`)
  return manifest
}

function runtimeMetadata(runtime, policy, allowRuntimeMismatch) {
  const versionResult = run(runtime, ['--version'])
  const abiResult = run(runtime, ['-p', 'process.versions.modules'])
  const version = String(versionResult.stdout).trim().replace(/^v/, '')
  const abi = String(abiResult.stdout).trim()
  if (!allowRuntimeMismatch && (version !== policy.node.version || abi !== String(policy.node.abi))) {
    fail(`Node runtime ${version} ABI ${abi} does not match pinned ${policy.node.version} ABI ${policy.node.abi}`)
  }
  return { version, abi }
}

function signNestedCode(root, identity, entitlements) {
  const entries = walkFiles(root)
    .filter(({ absolute }) => machoDetails(absolute))
    .sort((a, b) => b.relative.split('/').length - a.relative.split('/').length)
  for (const entry of entries) {
    const args = ['--force', '--sign', identity]
    // Developer ID distribution code is always hardened. Ad-hoc code has no
    // Team ID, so hardened Node would reject its equally ad-hoc pty.node as a
    // different team before the signed-host continuity probe can run. The
    // local build remains sealed and signature-verified, while the strict
    // distribution preflight separately requires Developer ID + notarization.
    if (identity !== '-') args.push('--options', 'runtime')
    if (entitlements && entry.relative === 'bin/node') args.push('--entitlements', entitlements)
    if (identity !== '-') args.push('--timestamp')
    args.push(entry.absolute)
    run('/usr/bin/codesign', args)
  }
}

function effectivePolicy(policy, appRelease) {
  return appRelease ? { ...policy, appRelease } : policy
}

function assertCompleteAppRelease({ appReleaseVersion, appReleaseBuild }) {
  const hasVersion = typeof appReleaseVersion === 'string'
  const hasBuild = typeof appReleaseBuild === 'string'
  if (hasVersion !== hasBuild) fail('app release version and build must be provided together')
  return hasVersion ? { version: appReleaseVersion, build: appReleaseBuild } : null
}

function stageNativePackage({
  output,
  nativeBroker,
  bootstrap,
  signIdentity,
  requireSignatures,
  policy,
  appRelease,
  launchArguments,
}) {
  if (!output || !nativeBroker) fail('output and native broker are required')
  if (!bootstrap) fail('native broker bootstrap is required')
  const temporary = fs.mkdtempSync(path.join(path.dirname(output), '.broker-helper-'))
  try {
    ensureDirectory(temporary)
    ensureDirectory(path.join(temporary, 'bin'))
    copyFile(nativeBroker, path.join(temporary, 'bin', 'kaisola-session-broker'), 0o755)
    copyFile(bootstrap, path.join(temporary, 'bin', 'kaisola-broker-bootstrap'), 0o755)

    if (signIdentity) signNestedCode(temporary, signIdentity)

    const manifest = createManifest(temporary, {
      schemaVersion: policy.schemaVersion,
      packageVersion: policy.packageVersion,
      appRelease,
      brokerImplementationVersion: policy.brokerImplementationVersion,
      brokerProtocol: policy.brokerProtocol,
      launch: {
        kind: 'native',
        executable: 'bin/kaisola-session-broker',
        arguments: launchArguments,
      },
    })
    fs.writeFileSync(path.join(temporary, manifestName), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 })
    verifyPackage(temporary, {
      requireSignatures,
      // A caller-supplied schema-2 policy cannot weaken the official staging
      // contract. Generic verifier fixtures may omit a bootstrap, but every
      // package emitted for the application must carry its signed launcher.
      policy: {
        ...effectivePolicy(policy, appRelease),
        requireBootstrap: true,
      },
    })

    fs.rmSync(output, { recursive: true, force: true })
    fs.renameSync(temporary, output)
    return manifest
  } catch (error) {
    fs.rmSync(temporary, { recursive: true, force: true })
    throw error
  }
}

function stagePackage({
  output,
  runtimes = [],
  bootstrap,
  signIdentity,
  entitlements,
  requireSignatures = false,
  allowRuntimeMismatch = false,
  nativeBroker,
  appReleaseVersion,
  appReleaseBuild,
  launchArguments = [],
  policyPath,
}) {
  const policy = readJSON(policyPath || policyFile)
  const appRelease = assertCompleteAppRelease({ appReleaseVersion, appReleaseBuild })
  if (nativeBroker) {
    if (runtimes.length) fail('native broker package cannot include Node runtimes')
    if (allowRuntimeMismatch) fail('native broker package cannot use Node runtime options')
    if (entitlements) fail('native broker package cannot use Node entitlements')
    if (!appRelease) fail('native broker package requires app release version and build')
    return stageNativePackage({
      output,
      nativeBroker,
      bootstrap,
      signIdentity,
      requireSignatures,
      policy,
      appRelease,
      launchArguments,
    })
  }
  if (appRelease || launchArguments.length) fail('app release and launch arguments require --native-broker')
  if (!output || !Array.isArray(runtimes) || runtimes.length < 1) fail('output and at least one Node runtime are required')
  const temporary = fs.mkdtempSync(path.join(path.dirname(output), '.broker-helper-'))
  try {
    ensureDirectory(temporary)
    ensureDirectory(path.join(temporary, 'bin'))
    ensureDirectory(path.join(temporary, 'lib'))

    const runtimeArchitectures = new Set()
    for (const runtime of runtimes) {
      const macho = machoDetails(runtime)
      if (!macho || !macho.architectures.length) fail(`Node runtime is not a Mach-O executable: ${runtime}`)
      for (const architecture of macho.architectures) runtimeArchitectures.add(architecture)
    }
    const runtimeDestination = path.join(temporary, 'bin', 'node')
    if (runtimes.length === 1) copyFile(runtimes[0], runtimeDestination, 0o755)
    else {
      run('/usr/bin/lipo', ['-create', ...runtimes, '-output', runtimeDestination])
      fs.chmodSync(runtimeDestination, 0o755)
    }
    const runtime = runtimeMetadata(runtimeDestination, policy, allowRuntimeMismatch)

    if (bootstrap) copyFile(bootstrap, path.join(temporary, 'bin', 'kaisola-broker-bootstrap'), 0o755)
    for (const relative of brokerSources) {
      copyFile(path.join(repoRoot, relative), path.join(temporary, 'lib', relative), 0o644)
    }

    const nodePtyRoot = path.join(repoRoot, 'node_modules', 'node-pty')
    const nodePtyPackage = readJSON(path.join(nodePtyRoot, 'package.json'))
    if (nodePtyPackage.version !== policy.nodePtyVersion) fail('installed node-pty does not match helper package policy')
    const nodePtyDestination = path.join(temporary, 'lib', 'node_modules', 'node-pty')
    copyFile(path.join(nodePtyRoot, 'package.json'), path.join(nodePtyDestination, 'package.json'), 0o644)
    copyFile(path.join(nodePtyRoot, 'LICENSE'), path.join(nodePtyDestination, 'LICENSE'), 0o644)
    copyTree(path.join(nodePtyRoot, 'lib'), path.join(nodePtyDestination, 'lib'), (relative) => relative.endsWith('.js'))
    for (const architecture of runtimeArchitectures) {
      const nodeArch = architecture === 'x86_64' ? 'x64' : architecture
      const source = path.join(nodePtyRoot, 'prebuilds', `darwin-${nodeArch}`)
      if (!fs.existsSync(source)) fail(`node-pty has no prebuild for ${architecture}`)
      copyTree(source, path.join(nodePtyDestination, 'prebuilds', `darwin-${nodeArch}`))
    }
    const nodeLicense = path.join(path.dirname(path.dirname(runtimes[0])), 'LICENSE')
    if (!fs.existsSync(nodeLicense)) fail(`Node runtime distribution has no LICENSE beside ${runtimes[0]}`)
    copyFile(nodeLicense, path.join(temporary, 'LICENSES', 'Node.js-LICENSE'), 0o644)
    copyFile(path.join(nodePtyRoot, 'LICENSE'), path.join(temporary, 'LICENSES', 'node-pty-LICENSE'), 0o644)

    const claudeSDKRoot = path.join(repoRoot, 'node_modules', '@anthropic-ai', 'claude-agent-sdk')
    const claudeSDKPackage = readJSON(path.join(claudeSDKRoot, 'package.json'))
    if (claudeSDKPackage.version !== policy.claudeAgentSDKVersion) {
      fail('installed Claude Agent SDK does not match helper package policy')
    }
    const claudeSDKDestination = path.join(temporary, 'lib', 'node_modules', '@anthropic-ai', 'claude-agent-sdk')
    copyTree(claudeSDKRoot, claudeSDKDestination)
    copyFile(
      path.join(claudeSDKRoot, 'LICENSE.md'),
      path.join(temporary, 'LICENSES', 'Claude-Agent-SDK-LICENSE.md'),
      0o644
    )

    if (signIdentity) signNestedCode(temporary, signIdentity, entitlements)

    const manifest = createManifest(temporary, {
      schemaVersion: policy.schemaVersion,
      packageVersion: policy.packageVersion,
      brokerImplementationVersion: policy.brokerImplementationVersion,
      brokerProtocol: policy.brokerProtocol,
      node: { version: runtime.version, abi: runtime.abi, architectures: [...runtimeArchitectures].sort() },
      nodePty: { version: nodePtyPackage.version },
      claudeAgentSDK: { version: claudeSDKPackage.version },
      generatedAt: new Date().toISOString(),
    })
    fs.writeFileSync(path.join(temporary, manifestName), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 })
    verifyPackage(temporary, { requireSignatures, policy })

    fs.rmSync(output, { recursive: true, force: true })
    fs.renameSync(temporary, output)
    return manifest
  } catch (error) {
    fs.rmSync(temporary, { recursive: true, force: true })
    throw error
  }
}

function parseArguments(argv) {
  const options = { runtimes: [], launchArguments: [] }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const value = () => {
      if (index + 1 >= argv.length) fail(`missing value for ${argument}`)
      return argv[++index]
    }
    if (argument === '--output') options.output = path.resolve(value())
    else if (argument === '--runtime' || argument === '--runtime-arm64' || argument === '--runtime-x86_64') options.runtimes.push(path.resolve(value()))
    else if (argument === '--native-broker') options.nativeBroker = path.resolve(value())
    else if (argument === '--bootstrap') options.bootstrap = path.resolve(value())
    else if (argument === '--app-release-version') options.appReleaseVersion = value()
    else if (argument === '--app-release-build') options.appReleaseBuild = value()
    else if (argument === '--launch-argument') options.launchArguments.push(value())
    else if (argument === '--policy') options.policyPath = path.resolve(value())
    else if (argument === '--sign-identity') options.signIdentity = value()
    else if (argument === '--entitlements') options.entitlements = path.resolve(value())
    else if (argument === '--require-signatures') options.requireSignatures = true
    else if (argument === '--allow-runtime-mismatch') options.allowRuntimeMismatch = true
    else if (argument === '--verify') options.verify = path.resolve(value())
    else fail(`unknown argument: ${argument}`)
  }
  return options
}

if (require.main === module) {
  try {
    const options = parseArguments(process.argv.slice(2))
    if (options.verify) {
      const appRelease = assertCompleteAppRelease(options)
      if (options.nativeBroker || options.runtimes.length || options.bootstrap || options.launchArguments.length
          || options.signIdentity || options.entitlements || options.allowRuntimeMismatch) {
        fail('--verify cannot be combined with package staging inputs')
      }
      const policy = effectivePolicy(readJSON(options.policyPath || policyFile), appRelease)
      const manifest = verifyPackage(options.verify, { requireSignatures: options.requireSignatures, policy })
      console.log(`NATIVE_BROKER_PACKAGE_VERIFY=PASS package=${manifest.packageVersion} files=${manifest.files.length}`)
    } else {
      const manifest = stagePackage(options)
      console.log(`NATIVE_BROKER_PACKAGE=PASS package=${manifest.packageVersion} files=${manifest.files.length}`)
    }
  } catch (error) {
    console.error(`NATIVE_BROKER_PACKAGE=FAIL ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = {
  brokerSources,
  contentDigest,
  contentDigestV1,
  contentDigestV2,
  createManifest,
  parseArguments,
  roleFor,
  sha256,
  signNestedCode,
  stagePackage,
  verifyPackage,
  walkFiles,
}
