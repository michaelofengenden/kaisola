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
  'electron/session-broker.cjs',
  'electron/ipc/brokerWire.cjs',
  'electron/ipc/securityPolicy.cjs',
  'electron/ipc/shellEnv.cjs',
  'electron/ipc/terminalManager.cjs',
  'electron/ipc/terminalObservers.cjs',
  'electron/ipc/terminalSpool.cjs',
  'electron/companion/protocol.cjs',
  'electron/companion/terminalCursor.cjs',
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
  if (relative.endsWith('/pty.node')) return 'native-module'
  if (relative.endsWith('/spawn-helper')) return 'node-pty-spawn-helper'
  if (relative.endsWith('.cjs') || relative.endsWith('.js')) return 'broker-javascript'
  if (relative.includes('/LICENSE') || relative.startsWith('LICENSES/')) return 'license'
  return 'resource'
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
  return { ...metadata, files }
}

function verifyPackage(root, { requireSignatures = false, policy = readJSON(policyFile) } = {}) {
  const manifestFile = path.join(root, manifestName)
  const manifestStat = fs.lstatSync(manifestFile)
  if (manifestStat.isSymbolicLink() || !manifestStat.isFile()) fail('helper manifest is not a regular file')
  const manifest = readJSON(manifestFile)
  if (manifest.schemaVersion !== policy.schemaVersion) fail('helper manifest schema does not match package policy')
  if (manifest.packageVersion !== policy.packageVersion) fail('helper package version does not match package policy')
  if (manifest.brokerImplementationVersion !== policy.brokerImplementationVersion) fail('broker implementation version does not match package policy')
  if (manifest.node?.version !== policy.node.version || String(manifest.node?.abi) !== String(policy.node.abi)) {
    fail('helper Node runtime does not match package policy')
  }
  if (manifest.nodePty?.version !== policy.nodePtyVersion) fail('helper node-pty version does not match package policy')

  const actual = new Map(walkFiles(root)
    .filter(({ relative }) => relative !== manifestName)
    .map((entry) => [entry.relative, entry]))
  if (!Array.isArray(manifest.files) || manifest.files.length !== actual.size) fail('helper manifest file inventory is incomplete')
  for (const expected of manifest.files) {
    if (!expected || typeof expected.path !== 'string' || expected.path.includes('..') || path.isAbsolute(expected.path)) {
      fail('helper manifest contains an unsafe path')
    }
    const entry = actual.get(expected.path)
    if (!entry) fail(`helper package is missing ${expected.path}`)
    if (entry.stat.size !== expected.size || sha256(entry.absolute) !== expected.sha256) {
      fail(`helper package integrity mismatch: ${expected.path}`)
    }
    const mode = (entry.stat.mode & 0o777).toString(8).padStart(4, '0')
    if (mode !== expected.mode || (entry.stat.mode & 0o022)) fail(`helper package mode mismatch: ${expected.path}`)
    const macho = machoDetails(entry.absolute)
    if (Boolean(macho) !== Boolean(expected.machO)) fail(`helper Mach-O inventory mismatch: ${expected.path}`)
    if (macho) {
      const requirement = designatedRequirement(entry.absolute)
      if ((expected.machO.designatedRequirement || null) !== requirement) {
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

function stagePackage({
  output,
  runtimes,
  bootstrap,
  signIdentity,
  entitlements,
  requireSignatures = false,
  allowRuntimeMismatch = false,
}) {
  const policy = readJSON(policyFile)
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

    if (signIdentity) signNestedCode(temporary, signIdentity, entitlements)

    const manifest = createManifest(temporary, {
      schemaVersion: policy.schemaVersion,
      packageVersion: policy.packageVersion,
      brokerImplementationVersion: policy.brokerImplementationVersion,
      brokerProtocol: policy.brokerProtocol,
      node: { version: runtime.version, abi: runtime.abi, architectures: [...runtimeArchitectures].sort() },
      nodePty: { version: nodePtyPackage.version },
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
  const options = { runtimes: [] }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const value = () => {
      if (index + 1 >= argv.length) fail(`missing value for ${argument}`)
      return argv[++index]
    }
    if (argument === '--output') options.output = path.resolve(value())
    else if (argument === '--runtime' || argument === '--runtime-arm64' || argument === '--runtime-x86_64') options.runtimes.push(path.resolve(value()))
    else if (argument === '--bootstrap') options.bootstrap = path.resolve(value())
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
      const manifest = verifyPackage(options.verify, { requireSignatures: options.requireSignatures })
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
  createManifest,
  parseArguments,
  roleFor,
  sha256,
  stagePackage,
  verifyPackage,
  walkFiles,
}
