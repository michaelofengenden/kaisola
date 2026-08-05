#!/usr/bin/env node
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { parseSignatureOutput, validatePreparedSignature } = require('./native-appcast.cjs')

const SCHEMA_VERSION = 1
const KIND = 'kaisola-native-release-candidate'
const RECEIPT_NAME = 'release-candidate.json'
const EXPECTED_BUNDLE_IDENTIFIER = 'com.kaisola.mac'
// Apple Silicon only, decided 2026-08-04; must stay in lockstep with
// native-release-preflight.cjs.
const EXPECTED_ARCHITECTURES = Object.freeze(['arm64'])
const SPARKLE_PUBLIC_ED_KEY = 'BQgU8WTQzeYBaYnbWrYBgoP7JPYyCXVrNgHCMBvmYrk='
// The recreated repository reset Actions run numbers, but the last public app
// was build 15501. Sparkle compares CFBundleVersion independently of SemVer.
const LAST_PUBLIC_BUILD = 15501n

function fail(message) {
  throw new Error(message)
}

function requireValue(argv, index, argument) {
  const value = argv[index + 1]
  if (value == null || value.startsWith('--')) fail(`${argument} requires a value`)
  return value
}

function parseArguments(argv) {
  const command = argv[0]
  if (command === '--help' || command === '-h') return { help: true }
  if (command !== 'create' && command !== 'verify') fail('first argument must be create or verify')
  const options = { command }
  const seen = new Set()
  const pathKeys = new Set(['directory', 'preflight', 'signatureOutput', 'output', 'receipt'])
  const keys = {
    '--directory': 'directory',
    '--preflight': 'preflight',
    '--sparkle-signature-output': 'signatureOutput',
    '--output': 'output',
    '--receipt': 'receipt',
    '--repository': 'repository',
    '--commit': 'commit',
    '--source-ref': 'sourceRef',
    '--source-committed-at': 'sourceCommittedAt',
    '--run-id': 'runID',
    '--run-attempt': 'runAttempt',
    '--version': 'version',
    '--build': 'build',
    '--tag': 'tag',
  }
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      options.help = true
      continue
    }
    const key = keys[argument]
    if (!key) fail(`unknown argument: ${argument}`)
    if (seen.has(key)) fail(`duplicate argument: ${argument}`)
    seen.add(key)
    const value = requireValue(argv, index, argument)
    index += 1
    options[key] = pathKeys.has(key) ? path.resolve(value) : value
  }
  if (options.help) return options

  const required = command === 'create'
    ? ['directory', 'preflight', 'signatureOutput', 'output', 'repository', 'commit', 'sourceRef',
      'sourceCommittedAt', 'runID', 'runAttempt', 'version', 'build']
    : ['directory', 'receipt', 'repository', 'commit', 'runID', 'version', 'tag']
  for (const key of required) {
    if (!options[key]) fail(`--${key.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)} is required`)
  }
  validateIdentityOptions(options)
  return options
}

function validateIdentityOptions(options) {
  if (options.repository && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(options.repository)) {
    fail('--repository must be a GitHub owner/name pair')
  }
  if (options.commit && !/^[0-9a-f]{40}$/.test(options.commit)) {
    fail('--commit must be a lowercase 40-character Git commit')
  }
  if (options.sourceRef && options.sourceRef !== 'refs/heads/main') {
    fail('--source-ref must be refs/heads/main')
  }
  if (options.runID && !/^[1-9]\d*$/.test(options.runID)) fail('--run-id must be a positive integer')
  if (options.runAttempt && !/^[1-9]\d*$/.test(options.runAttempt)) fail('--run-attempt must be a positive integer')
  if (options.version && !/^\d+\.\d+\.\d+$/.test(options.version)) fail('--version must be semantic x.y.z')
  if (options.build && (!/^[1-9]\d*$/.test(options.build) || BigInt(options.build) <= LAST_PUBLIC_BUILD)) {
    fail(`--build must be an integer newer than the last public build ${LAST_PUBLIC_BUILD}`)
  }
  if (options.tag && options.version && options.tag !== `v${options.version}`) {
    fail(`tag ${options.tag} does not match version ${options.version}`)
  }
}

function usage() {
  return `Usage:
  node scripts/native-release-candidate.cjs create \\
    --directory release/native --preflight preflight.json \\
    --sparkle-signature-output signature.txt --output release/native/${RECEIPT_NAME} \\
    --repository owner/repo --commit <40-hex> --source-ref refs/heads/main \\
    --source-committed-at <ISO-8601> --run-id <id> --run-attempt <n> \\
    --version <x.y.z> --build <integer>

  node scripts/native-release-candidate.cjs verify \\
    --directory release/native --receipt release/native/${RECEIPT_NAME} \\
    [--preflight promotion-preflight.json] \\
    --repository owner/repo --commit <40-hex> --run-id <id> \\
    --version <x.y.z> --tag <vx.y.z>`
}

function canonicalISODate(value) {
  const date = new Date(value)
  if (Number.isNaN(date.valueOf())) fail('--source-committed-at must be a valid ISO-8601 date')
  return date.toISOString()
}

function readJSON(file, label) {
  let value
  try {
    value = JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    fail(`could not read ${label}: ${error.message}`)
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must contain a JSON object`)
  return value
}

function requireInteger(value, label, { minimum = 0 } = {}) {
  if (!Number.isSafeInteger(value) || value < minimum) fail(`${label} must be an integer >= ${minimum}`)
  return value
}

function requireString(value, label, pattern = null) {
  if (typeof value !== 'string' || !value || (pattern && !pattern.test(value))) fail(`${label} is invalid`)
  return value
}

function requireArchitectures(value, label) {
  if (!Array.isArray(value) || JSON.stringify([...value].sort()) !== JSON.stringify(EXPECTED_ARCHITECTURES)) {
    fail(`${label} must contain exactly ${EXPECTED_ARCHITECTURES.join(' and ')}`)
  }
  return [...EXPECTED_ARCHITECTURES]
}

function validatePreflight(preflight, options) {
  if (preflight.pass !== true
      || preflight.bundleIdentifier !== EXPECTED_BUNDLE_IDENTIFIER
      || preflight.version !== options.version
      || String(preflight.build) !== options.build
      || preflight.sourceCommit !== options.commit
      || preflight.updatesConfigured !== true
      || preflight.developerID !== true
      || preflight.secureTimestamp !== true
      || preflight.notarizationRequired !== true
      || preflight.launchProbe !== true) {
    fail('preflight receipt does not describe this exact notarized release candidate')
  }
  const teamIdentifier = requireString(preflight.teamIdentifier, 'preflight team identifier', /^[A-Z0-9]{10}$/)
  const architectures = {
    app: requireArchitectures(preflight.architectures?.app, 'preflight app architectures'),
    node: requireArchitectures(preflight.architectures?.node, 'preflight Node architectures'),
    bootstrap: requireArchitectures(preflight.architectures?.bootstrap, 'preflight bootstrap architectures'),
  }
  const helper = {
    packageVersion: requireString(preflight.helper?.packageVersion, 'helper package version', /^[A-Za-z0-9._-]{1,64}$/),
    contentDigest: requireString(preflight.helper?.contentDigest, 'helper content digest', /^[0-9a-f]{64}$/),
    schemaVersion: requireInteger(preflight.helper?.schemaVersion, 'helper schema version', { minimum: 1 }),
    implementationVersion: requireInteger(preflight.helper?.implementationVersion, 'helper implementation version', { minimum: 1 }),
    protocol: {
      minimum: requireInteger(preflight.helper?.protocol?.minimum, 'helper minimum protocol', { minimum: 1 }),
      maximum: requireInteger(preflight.helper?.protocol?.maximum, 'helper maximum protocol', { minimum: 1 }),
      securityEpoch: requireInteger(preflight.helper?.protocol?.securityEpoch, 'helper security epoch', { minimum: 1 }),
    },
    fileCount: requireInteger(preflight.helper?.fileCount, 'helper file count', { minimum: 1 }),
  }
  if (helper.protocol.minimum > helper.protocol.maximum) fail('helper protocol range is inverted')
  return { teamIdentifier, architectures, helper }
}

function regularFile(file, label) {
  let stat
  try {
    stat = fs.lstatSync(file)
  } catch (error) {
    fail(`could not read ${label}: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) fail(`${label} must be a non-empty regular file`)
  return stat
}

function sha256(file) {
  const hash = crypto.createHash('sha256')
  const descriptor = fs.openSync(file, 'r')
  const buffer = Buffer.allocUnsafe(1024 * 1024)
  try {
    for (;;) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, null)
      if (!count) break
      hash.update(buffer.subarray(0, count))
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return hash.digest('hex')
}

function verifySparkleSignature(file, signature) {
  const validated = validatePreparedSignature(signature, regularFile(file, 'Sparkle archive').size)
  const rawPublicKey = Buffer.from(SPARKLE_PUBLIC_ED_KEY, 'base64')
  const subjectPublicKeyInfo = Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'),
    rawPublicKey,
  ])
  const publicKey = crypto.createPublicKey({ key: subjectPublicKeyInfo, format: 'der', type: 'spki' })
  if (!crypto.verify(null, fs.readFileSync(file), publicKey, Buffer.from(validated.signature, 'base64'))) {
    fail('Sparkle signature does not verify the immutable archive with the shipped public key')
  }
  return true
}

function artifactNames(version, build) {
  const zip = `Kaisola-${version}-b${build}.zip`
  const dmg = `Kaisola-${version}-b${build}.dmg`
  const stableDMG = 'Kaisola.dmg'
  return [
    { role: 'sparkleArchive', name: zip },
    { role: 'versionedInstaller', name: dmg },
    { role: 'stableInstaller', name: stableDMG },
    { role: 'sparkleArchiveChecksum', name: `${zip}.sha256`, checksumFor: zip },
    { role: 'versionedInstallerChecksum', name: `${dmg}.sha256`, checksumFor: dmg },
    { role: 'stableInstallerChecksum', name: `${stableDMG}.sha256`, checksumFor: stableDMG },
  ]
}

function inspectArtifacts(directory, version, build) {
  const directoryStat = fs.lstatSync(directory)
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) {
    fail('--directory must be a real directory')
  }
  const inspected = artifactNames(version, build).map((record) => {
    const file = path.join(directory, record.name)
    const stat = regularFile(file, `candidate artifact ${record.name}`)
    return { ...record, size: stat.size, sha256: sha256(file) }
  })
  const byName = new Map(inspected.map((artifact) => [artifact.name, artifact]))
  for (const artifact of inspected) {
    if (!artifact.checksumFor) continue
    const target = byName.get(artifact.checksumFor)
    const checksum = fs.readFileSync(path.join(directory, artifact.name), 'utf8')
    if (checksum !== `${target.sha256}  ${target.name}\n`) {
      fail(`${artifact.name} does not canonically checksum ${target.name}`)
    }
  }
  return inspected.map(({ checksumFor, ...artifact }) => artifact)
}

function writeJSONAtomic(destination, value) {
  const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}.${process.pid}.tmp`)
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: 'utf8', flag: 'wx', mode: 0o644,
    })
    fs.renameSync(temporary, destination)
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

function createReceipt(options) {
  if (path.basename(options.output) !== RECEIPT_NAME || path.dirname(options.output) !== options.directory) {
    fail(`--output must be ${RECEIPT_NAME} directly inside --directory`)
  }
  if (fs.existsSync(options.output)) fail('candidate receipt already exists')
  const preflight = readJSON(options.preflight, 'preflight receipt')
  const validated = validatePreflight(preflight, options)
  const artifacts = inspectArtifacts(options.directory, options.version, options.build)
  const signatureOutput = fs.readFileSync(options.signatureOutput, 'utf8')
  const signed = parseSignatureOutput(signatureOutput)
  const zip = artifacts.find((artifact) => artifact.role === 'sparkleArchive')
  if (signed.length !== zip.size) fail('Sparkle signature length does not match the immutable archive')
  verifySparkleSignature(path.join(options.directory, zip.name), signed.signature)

  const receipt = {
    schemaVersion: SCHEMA_VERSION,
    kind: KIND,
    repository: options.repository,
    source: {
      commit: options.commit,
      ref: options.sourceRef,
      committedAt: canonicalISODate(options.sourceCommittedAt),
    },
    workflow: {
      runID: options.runID,
      runAttempt: Number(options.runAttempt),
    },
    application: {
      bundleIdentifier: preflight.bundleIdentifier,
      version: options.version,
      build: options.build,
      architectures: validated.architectures,
      developerIDTeamIdentifier: validated.teamIdentifier,
      secureTimestamp: true,
      notarized: true,
      updatesConfigured: true,
    },
    brokerHelper: validated.helper,
    sparkle: {
      archive: zip.name,
      archiveLength: signed.length,
      edSignature: signed.signature,
    },
    artifacts,
  }
  writeJSONAtomic(options.output, receipt)
  return receipt
}

function sameJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function verifyReceipt(options) {
  if (path.basename(options.receipt) !== RECEIPT_NAME || path.dirname(options.receipt) !== options.directory) {
    fail(`--receipt must be ${RECEIPT_NAME} directly inside --directory`)
  }
  regularFile(options.receipt, 'candidate receipt')
  const receipt = readJSON(options.receipt, 'candidate receipt')
  if (receipt.schemaVersion !== SCHEMA_VERSION || receipt.kind !== KIND) fail('candidate receipt schema is unsupported')
  if (receipt.repository !== options.repository
      || receipt.source?.commit !== options.commit
      || receipt.source?.ref !== 'refs/heads/main'
      || receipt.workflow?.runID !== options.runID
      || receipt.application?.version !== options.version
      || receipt.application?.build == null
      || options.tag !== `v${receipt.application.version}`) {
    fail('candidate provenance does not match this repository, commit, run, version, and tag')
  }
  const normalized = {
    ...options,
    build: String(receipt.application.build),
  }
  validateIdentityOptions(normalized)
  const live = options.preflight
    ? validatePreflight(readJSON(options.preflight, 'promotion preflight receipt'), normalized)
    : null
  if (receipt.application.bundleIdentifier !== EXPECTED_BUNDLE_IDENTIFIER
      || !/^[A-Z0-9]{10}$/.test(String(receipt.application.developerIDTeamIdentifier || ''))
      || receipt.application.secureTimestamp !== true
      || receipt.application.notarized !== true
      || receipt.application.updatesConfigured !== true) {
    fail('candidate application security provenance is incomplete')
  }
  requireArchitectures(receipt.application.architectures?.app, 'candidate app architectures')
  requireArchitectures(receipt.application.architectures?.node, 'candidate Node architectures')
  requireArchitectures(receipt.application.architectures?.bootstrap, 'candidate bootstrap architectures')
  requireString(receipt.brokerHelper?.packageVersion, 'candidate helper package version', /^[A-Za-z0-9._-]{1,64}$/)
  requireString(receipt.brokerHelper?.contentDigest, 'candidate helper content digest', /^[0-9a-f]{64}$/)
  requireInteger(receipt.brokerHelper?.schemaVersion, 'candidate helper schema version', { minimum: 1 })
  requireInteger(receipt.brokerHelper?.implementationVersion, 'candidate helper implementation version', { minimum: 1 })
  requireInteger(receipt.brokerHelper?.protocol?.minimum, 'candidate helper minimum protocol', { minimum: 1 })
  requireInteger(receipt.brokerHelper?.protocol?.maximum, 'candidate helper maximum protocol', { minimum: 1 })
  requireInteger(receipt.brokerHelper?.protocol?.securityEpoch, 'candidate helper security epoch', { minimum: 1 })
  requireInteger(receipt.brokerHelper?.fileCount, 'candidate helper file count', { minimum: 1 })
  if (receipt.brokerHelper.protocol.minimum > receipt.brokerHelper.protocol.maximum) {
    fail('candidate helper protocol range is inverted')
  }
  if (!Number.isSafeInteger(receipt.workflow.runAttempt) || receipt.workflow.runAttempt < 1) {
    fail('candidate workflow attempt is invalid')
  }
  if (canonicalISODate(receipt.source.committedAt) !== receipt.source.committedAt) {
    fail('candidate source timestamp is not canonical ISO-8601')
  }
  if (live && (live.teamIdentifier !== receipt.application.developerIDTeamIdentifier
      || !sameJSON(live.architectures, receipt.application.architectures)
      || !sameJSON(live.helper, receipt.brokerHelper))) {
    fail('promoted app identity does not match the sealed candidate receipt')
  }

  const artifacts = inspectArtifacts(options.directory, options.version, normalized.build)
  if (!sameJSON(receipt.artifacts, artifacts)) fail('candidate artifact inventory or checksums do not match the receipt')
  const zip = artifacts.find((artifact) => artifact.role === 'sparkleArchive')
  const signed = validatePreparedSignature(receipt.sparkle?.edSignature, receipt.sparkle?.archiveLength)
  if (receipt.sparkle?.archive !== zip.name || signed.length !== zip.size) {
    fail('candidate Sparkle signature does not describe the immutable archive')
  }
  verifySparkleSignature(path.join(options.directory, zip.name), signed.signature)

  const expectedNames = new Set([...artifacts.map((artifact) => artifact.name), RECEIPT_NAME])
  const unexpected = fs.readdirSync(options.directory).filter((name) => !expectedNames.has(name))
  if (unexpected.length) fail(`candidate directory contains unexpected files: ${unexpected.sort().join(', ')}`)
  return {
    pass: true,
    receipt: options.receipt,
    repository: receipt.repository,
    commit: receipt.source.commit,
    runID: receipt.workflow.runID,
    version: receipt.application.version,
    build: String(receipt.application.build),
    helperContentDigest: receipt.brokerHelper.contentDigest,
    artifactCount: artifacts.length,
    applicationVerified: live != null,
  }
}

if (require.main === module) {
  try {
    const options = parseArguments(process.argv.slice(2))
    if (options.help) console.log(usage())
    else {
      const result = options.command === 'create' ? createReceipt(options) : verifyReceipt(options)
      console.log(`NATIVE_RELEASE_CANDIDATE=${JSON.stringify(result)}`)
    }
  } catch (error) {
    console.error(`NATIVE_RELEASE_CANDIDATE=FAIL ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = {
  KIND,
  LAST_PUBLIC_BUILD,
  RECEIPT_NAME,
  SCHEMA_VERSION,
  artifactNames,
  createReceipt,
  inspectArtifacts,
  parseArguments,
  sha256,
  validatePreflight,
  verifySparkleSignature,
  verifyReceipt,
}
