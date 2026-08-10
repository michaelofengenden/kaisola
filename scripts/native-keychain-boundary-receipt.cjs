#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')

const SCHEMA_VERSION = 2
const EXPECTED_IDENTIFIER = 'com.kaisola.mac'
const EXPECTED_ARCHITECTURE = 'arm64'
const EXPECTED_PLATFORM = 'macOS'
const EXPECTED_ISOLATION = 'github-hosted-ephemeral-vm'
const MAX_JSON_BYTES = 4 * 1024 * 1024
const MAX_SIGNATURE_BYTES = 64 * 1024
const MAX_PROFILE_BYTES = 4 * 1024 * 1024
const REQUIRED_TESTS = Object.freeze([
  'testAPIKeyErrorMappingIsActionableAndSecretFree()',
  'testAPIKeyRoundTripOverwriteTrimDeleteAndServiceIsolation()',
  'testCompanionIdentityIsStableAndPrivateItemsNeverSynchronize()',
])

function fail(message) {
  throw new Error(`Keychain boundary receipt rejected: ${message}`)
}

function collectTestCases(value) {
  const cases = []
  const seen = new Set()

  function visit(node) {
    if (!node || typeof node !== 'object') return
    if (seen.has(node)) return
    seen.add(node)
    if (Array.isArray(node)) {
      node.forEach(visit)
      return
    }

    const nodeType = typeof node.nodeType === 'string' ? node.nodeType.toLowerCase() : ''
    if ((nodeType === 'test case' || nodeType === 'test')
        && typeof node.name === 'string'
        && typeof node.result === 'string') {
      cases.push({ name: normalizeTestName(node.name), result: node.result })
    }
    Object.values(node).forEach(visit)
  }

  visit(value)
  return cases
}

function normalizeTestName(value) {
  const name = String(value).trim()
  return name.slice(name.lastIndexOf('/') + 1)
}

function validateSummary(summary) {
  if (!summary || typeof summary !== 'object' || Array.isArray(summary)) {
    fail('xcresult summary must be an object')
  }
  for (const field of [
    'totalTestCount',
    'passedTests',
    'failedTests',
    'skippedTests',
    'expectedFailures',
  ]) {
    if (!Number.isSafeInteger(summary[field]) || summary[field] < 0) {
      fail(`xcresult summary has an invalid ${field}`)
    }
  }
  if (summary.result !== 'Passed' || summary.failedTests !== 0 || summary.expectedFailures !== 0) {
    fail('xcresult must report a passed result with zero failures or expected failures')
  }
  if (summary.skippedTests !== 0) fail('xcresult must report zero skipped tests')
  if (summary.totalTestCount !== REQUIRED_TESTS.length
      || summary.passedTests !== REQUIRED_TESTS.length) {
    fail(`xcresult must report exactly ${REQUIRED_TESTS.length} passed tests`)
  }
  if (!Array.isArray(summary.devicesAndConfigurations)
      || summary.devicesAndConfigurations.length !== 1) {
    fail('xcresult must contain exactly one device and configuration')
  }

  const configuration = summary.devicesAndConfigurations[0]
  const device = configuration?.device
  if (!device || typeof device !== 'object' || Array.isArray(device)) {
    fail('xcresult omitted its macOS device receipt')
  }
  for (const field of ['passedTests', 'failedTests', 'skippedTests', 'expectedFailures']) {
    if (configuration[field] !== summary[field]) {
      fail(`xcresult device configuration ${field} disagrees with the summary`)
    }
  }
  if (device.platform !== EXPECTED_PLATFORM) fail(`test platform must be ${EXPECTED_PLATFORM}`)
  if (device.architecture !== EXPECTED_ARCHITECTURE) {
    fail(`test architecture must be exactly ${EXPECTED_ARCHITECTURE}`)
  }
  return device
}

function parseSignature(text) {
  const value = String(text || '')
  if (!value.trim() || /not signed at all/iu.test(value)) fail('host must have a valid code signature')
  const identifier = value.match(/^Identifier=(.+)$/mu)?.[1]?.trim()
  if (identifier !== EXPECTED_IDENTIFIER) fail(`host signature identifier must be ${EXPECTED_IDENTIFIER}`)
  const format = value.match(/^Format=(.+)$/mu)?.[1]?.trim()
  if (!format || !new RegExp(`Mach-O thin \\(${EXPECTED_ARCHITECTURE}\\)$`, 'u').test(format)) {
    fail(`host signature must seal an exact ${EXPECTED_ARCHITECTURE} binary`)
  }

  if (/^Signature=adhoc$/mu.test(value)) {
    fail('ad-hoc signatures cannot authorize a data-protection Keychain access group')
  }

  let kind = null
  if (/^Authority=Apple Development:/mu.test(value)) kind = 'apple-development'
  else if (/^Authority=Developer ID Application:/mu.test(value)) kind = 'developer-id'
  if (!kind) fail('host must have a valid code signature')
  const teamIdentifier = value.match(/^TeamIdentifier=(.+)$/mu)?.[1]?.trim()
  if (!/^[A-Z0-9]{10}$/u.test(teamIdentifier || '')) {
    fail('developer-signed host must have a valid TeamIdentifier')
  }
  return { identifier, kind, teamIdentifier }
}

function validateEntitlements(entitlements, signature) {
  if (!entitlements || typeof entitlements !== 'object' || Array.isArray(entitlements)) {
    fail('host entitlements must be an object')
  }
  const applicationIdentifier = entitlements['com.apple.application-identifier']
  const identifierSuffix = `.${EXPECTED_IDENTIFIER}`
  const identifierPrefix = typeof applicationIdentifier === 'string'
    && applicationIdentifier.endsWith(identifierSuffix)
    ? applicationIdentifier.slice(0, -identifierSuffix.length)
    : null
  if (!/^[A-Z0-9]{10}$/u.test(identifierPrefix || '')) {
    fail(`host needs the ${EXPECTED_IDENTIFIER} application-identifier entitlement`)
  }
  const groups = entitlements['keychain-access-groups']
  if (!Array.isArray(groups) || groups.length !== 1 || groups[0] !== applicationIdentifier) {
    fail('host needs one exact, identity-bound keychain access group')
  }
  if (entitlements['com.apple.security.get-task-allow'] !== true) {
    fail('host needs the test-only get-task-allow entitlement')
  }
  return { applicationIdentifier, identifierPrefix }
}

function profileAllows(allowance, value) {
  if (typeof allowance !== 'string' || !allowance) return false
  if (!allowance.endsWith('*')) return allowance === value
  return value.startsWith(allowance.slice(0, -1))
}

function validateProvisioningProfile(profile, signature, identity) {
  if (!profile || typeof profile !== 'object' || Array.isArray(profile)) {
    fail('host provisioning profile must be an object')
  }
  if (!Array.isArray(profile.TeamIdentifier)
      || profile.TeamIdentifier.length !== 1
      || profile.TeamIdentifier[0] !== signature.teamIdentifier) {
    fail('host provisioning profile must belong to the signing team')
  }
  if (!Array.isArray(profile.ApplicationIdentifierPrefix)
      || profile.ApplicationIdentifierPrefix.length !== 1
      || profile.ApplicationIdentifierPrefix[0] !== identity.identifierPrefix) {
    fail('host provisioning profile must authorize the application identifier prefix')
  }
  if (signature.kind === 'developer-id' && profile.ProvisionsAllDevices !== true) {
    fail('Developer ID provisioning profile must authorize all devices')
  }
  const expiration = Date.parse(profile.ExpirationDate)
  if (!Number.isFinite(expiration) || expiration <= Date.now()) {
    fail('host provisioning profile must be unexpired')
  }

  const entitlements = profile.Entitlements
  if (!entitlements || typeof entitlements !== 'object' || Array.isArray(entitlements)) {
    fail('host provisioning profile must contain entitlement allowances')
  }
  const applicationAllowance = entitlements['com.apple.application-identifier']
    ?? entitlements['application-identifier']
  if (!profileAllows(applicationAllowance, identity.applicationIdentifier)) {
    fail('host provisioning profile does not authorize the application identifier')
  }
  const groupAllowances = entitlements['keychain-access-groups']
  if (!Array.isArray(groupAllowances)
      || !groupAllowances.some((allowance) => profileAllows(
        allowance,
        identity.applicationIdentifier,
      ))) {
    fail('host provisioning profile does not authorize the Keychain access group')
  }
  return `${signature.kind}-profile-authorized`
}

function validateInputProvisioningProfile(profile, teamIdentifier) {
  if (!/^[A-Z0-9]{10}$/u.test(teamIdentifier || '')) {
    fail('input signing team identifier must be exactly 10 uppercase letters or digits')
  }
  if (!profile || typeof profile !== 'object' || Array.isArray(profile)) {
    fail('input provisioning profile must be an object')
  }

  const uuid = profile.UUID
  if (typeof uuid !== 'string'
      || !/^[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}$/iu.test(uuid)) {
    fail('input provisioning profile UUID is invalid')
  }
  if (typeof profile.Name !== 'string'
      || profile.Name.trim().length === 0
      || Buffer.byteLength(profile.Name, 'utf8') > 256) {
    fail('input provisioning profile name is missing or over its byte limit')
  }
  if (!Array.isArray(profile.Platform)
      || profile.Platform.length !== 1
      || profile.Platform[0] !== 'OSX') {
    fail('input provisioning profile must target only macOS')
  }

  const identifierPrefix = Array.isArray(profile.ApplicationIdentifierPrefix)
    && profile.ApplicationIdentifierPrefix.length === 1
    ? profile.ApplicationIdentifierPrefix[0]
    : null
  if (!/^[A-Z0-9]{10}$/u.test(identifierPrefix || '')) {
    fail('input provisioning profile must contain one valid application identifier prefix')
  }

  const applicationIdentifier = `${identifierPrefix}.${EXPECTED_IDENTIFIER}`
  validateProvisioningProfile(
    profile,
    { kind: 'developer-id', teamIdentifier },
    { applicationIdentifier, identifierPrefix },
  )
  return { uuid: uuid.toUpperCase() }
}

function validateBoundaryEvidence(evidence, options = {}) {
  if (!evidence || typeof evidence !== 'object' || Array.isArray(evidence)) {
    fail('evidence must be an object')
  }
  const device = validateSummary(evidence.summary)
  const testCases = collectTestCases(evidence.tests)
  const names = testCases.map(({ name }) => name).sort()
  const required = [...REQUIRED_TESTS].sort()
  if (names.length !== required.length
      || names.some((name, index) => name !== required[index])) {
    fail('xcresult must contain the exact Keychain boundary test set once')
  }
  if (testCases.some(({ result }) => result !== 'Passed')) {
    fail('every Keychain boundary test case must pass')
  }

  const parsedSignature = parseSignature(evidence.host?.signature)
  if (options.requiredSignatureKind !== undefined) {
    if (options.requiredSignatureKind !== 'developer-id') {
      fail('required signature kind must be developer-id')
    }
    if (parsedSignature.kind !== options.requiredSignatureKind) {
      fail('physical boundary host must use a Developer ID Application signature')
    }
  }
  const identity = validateEntitlements(
    evidence.host?.entitlements,
    parsedSignature,
  )
  const keychainAuthorization = validateProvisioningProfile(
    evidence.host?.provisioningProfile,
    parsedSignature,
    identity,
  )
  if (evidence.keychain?.isolation !== EXPECTED_ISOLATION) {
    fail('tests must use a fresh GitHub-hosted ephemeral VM Keychain')
  }
  if (evidence.keychain?.cleanupVerified !== true) {
    fail('test-secret cleanup verification is required')
  }

  // Deliberately allowlist the receipt. xcresult payloads, test logs, Keychain
  // paths/passwords, and credential-shaped fixture values cannot reach it.
  return {
    schemaVersion: SCHEMA_VERSION,
    pass: true,
    platform: device.platform,
    architecture: device.architecture,
    signature: {
      identifier: parsedSignature.identifier,
      kind: parsedSignature.kind,
    },
    keychainAuthorization,
    keychainIsolation: `${EXPECTED_ISOLATION}-cleanup-verified`,
    testCount: REQUIRED_TESTS.length,
    tests: required,
  }
}

function readBounded(file, maximumBytes, label) {
  const stat = fs.statSync(file)
  if (!stat.isFile() || stat.size <= 0 || stat.size > maximumBytes) {
    fail(`${label} is missing, empty, or over its byte limit`)
  }
  return fs.readFileSync(file, 'utf8')
}

function readJSON(file, label) {
  const text = readBounded(file, MAX_JSON_BYTES, label)
  try {
    return JSON.parse(text)
  } catch {
    fail(`${label} is not valid JSON`)
  }
}

function parseOptions(argv) {
  const options = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || value === undefined || options.has(key)) {
      fail('CLI options must be unique --name value pairs')
    }
    options.set(key, value)
  }
  return options
}

function required(options, key) {
  const value = options.get(key)
  if (!value) fail(`missing ${key}`)
  return value
}

function sealFromCLI(argv) {
  const [command, ...rest] = argv
  if (command !== 'seal') fail('expected the seal command')
  const options = parseOptions(rest)
  const evidence = {
    summary: readJSON(required(options, '--summary'), 'xcresult summary'),
    tests: readJSON(required(options, '--tests'), 'xcresult tests'),
    host: {
      signature: readBounded(
        required(options, '--signature'),
        MAX_SIGNATURE_BYTES,
        'host signature',
      ),
      entitlements: readJSON(required(options, '--entitlements'), 'host entitlements'),
      provisioningProfile: readJSON(
        required(options, '--provisioning-profile'),
        'host provisioning profile',
      ),
    },
    keychain: {
      isolation: required(options, '--keychain-isolation'),
      cleanupVerified: required(options, '--cleanup-verified') === 'true',
    },
  }
  const receipt = validateBoundaryEvidence(evidence, {
    requiredSignatureKind: required(options, '--required-signature-kind'),
  })
  const output = path.resolve(required(options, '--output'))
  fs.mkdirSync(path.dirname(output), { recursive: true, mode: 0o700 })
  fs.writeFileSync(output, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx', mode: 0o600 })
  process.stdout.write(`Keychain boundary receipt sealed: ${receipt.testCount} tests passed\n`)
}

function inspectProfileFromCLI(argv) {
  const options = parseOptions(argv)
  const profile = readJSON(
    required(options, '--profile'),
    'input provisioning profile',
  )
  const result = validateInputProvisioningProfile(
    profile,
    required(options, '--team-identifier'),
  )
  process.stdout.write(`${result.uuid}\n`)
}

function runCLI(argv) {
  const [command, ...rest] = argv
  if (command === 'seal') {
    sealFromCLI(argv)
    return
  }
  if (command === 'inspect-profile') {
    inspectProfileFromCLI(rest)
    return
  }
  fail('expected the seal or inspect-profile command')
}

if (require.main === module) {
  try {
    runCLI(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : 'Keychain receipt failed'}\n`)
    process.exitCode = 1
  }
}

module.exports = {
  REQUIRED_TESTS,
  collectTestCases,
  parseSignature,
  runCLI,
  sealFromCLI,
  validateBoundaryEvidence,
  validateEntitlements,
  validateInputProvisioningProfile,
  validateProvisioningProfile,
  validateSummary,
}
