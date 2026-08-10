#!/usr/bin/env node
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const SCHEMA_VERSION = 1
const KIND = 'kaisola-companion-contract'
const RECEIPT_NAME = 'companion-contract.json'
// The Companion contract only counts when it ran on the simulator the release
// lane pins. A device or macOS destination proves a different surface.
const REQUIRED_DESTINATION_PLATFORM = 'iOS Simulator'
// Promotion only ever happens from a candidate built on protected main, so a
// receipt from a pull-request run can never gate a tag.
const PROMOTABLE_SOURCE_REF = 'refs/heads/main'
// Clock skew allowance between the runner that wrote a receipt and the one
// reading it. Anything further into the future is a fabricated timestamp.
const FUTURE_SKEW_SECONDS = 300
const DEFAULT_MINIMUM_TESTS = 1

// xcodebuild prints one aggregate line per executed test bundle. `test` ends
// with "** TEST SUCCEEDED **" and `test-without-building` with
// "** TEST EXECUTE SUCCEEDED **"; a cancelled run prints neither.
const AGGREGATE_SUITE = /^Test Suite 'All tests' (passed|failed) at [^\n]*\n[ \t]*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)/gm
const TEST_SUCCEEDED = /\*\* TEST (?:EXECUTE )?SUCCEEDED \*\*/
const TEST_ABORTED = /\*\* TEST (?:EXECUTE )?FAILED \*\*|Testing cancelled/

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
  const pathKeys = new Set(['testLog', 'toolchainLog', 'output', 'receipt'])
  const keys = {
    '--test-log': 'testLog',
    '--toolchain-log': 'toolchainLog',
    '--destination': 'destination',
    '--runner-image': 'runnerImage',
    '--runner-image-version': 'runnerImageVersion',
    '--output': 'output',
    '--receipt': 'receipt',
    '--repository': 'repository',
    '--commit': 'commit',
    '--source-ref': 'sourceRef',
    '--run-id': 'runID',
    '--run-attempt': 'runAttempt',
    '--require-runner-image': 'requireRunnerImage',
    '--require-device': 'requireDevice',
    '--minimum-tests': 'minimumTests',
    '--max-age-seconds': 'maxAgeSeconds',
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
    ? ['testLog', 'toolchainLog', 'destination', 'runnerImage', 'runnerImageVersion', 'repository',
      'commit', 'sourceRef', 'runID', 'runAttempt', 'output']
    : ['receipt', 'repository', 'commit', 'runID', 'requireRunnerImage']
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
  if (options.sourceRef && !/^refs\/[A-Za-z0-9_./-]+$/.test(options.sourceRef)) {
    fail('--source-ref must be a fully qualified Git ref')
  }
  if (options.runID && !/^[1-9]\d*$/.test(options.runID)) fail('--run-id must be a positive integer')
  if (options.runAttempt && !/^[1-9]\d*$/.test(options.runAttempt)) fail('--run-attempt must be a positive integer')
  for (const key of ['runnerImage', 'requireRunnerImage']) {
    if (options[key] && !/^[A-Za-z0-9._-]{1,32}$/.test(options[key])) {
      fail('runner image labels must be short alphanumeric identifiers')
    }
  }
  if (options.runnerImageVersion && !/^[A-Za-z0-9._-]{1,64}$/.test(options.runnerImageVersion)) {
    fail('--runner-image-version must be a short alphanumeric identifier')
  }
  if (options.requireDevice && !/^[A-Za-z0-9 ()._-]{1,64}$/.test(options.requireDevice)) {
    fail('--require-device must be a simulator device name')
  }
  if (options.minimumTests && !/^[1-9]\d*$/.test(options.minimumTests)) {
    fail('--minimum-tests must be a positive integer')
  }
  if (options.maxAgeSeconds && !/^[1-9]\d*$/.test(options.maxAgeSeconds)) {
    fail('--max-age-seconds must be a positive integer')
  }
}

function usage() {
  return `Usage:
  node scripts/companion-contract-receipt.cjs create \\
    --test-log companion-tests.log --toolchain-log apple-toolchain.txt \\
    --destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \\
    --runner-image macos15 --runner-image-version 20260801.1 \\
    --repository owner/repo --commit <40-hex> --source-ref refs/heads/main \\
    --run-id <id> --run-attempt <n> --output <dir>/${RECEIPT_NAME}

  node scripts/companion-contract-receipt.cjs verify \\
    --receipt <dir>/${RECEIPT_NAME} --repository owner/repo --commit <40-hex> \\
    --run-id <id> --require-runner-image macos15 \\
    [--run-attempt <n>] [--require-device 'iPhone 16 Pro'] \\
    [--minimum-tests <n>] [--max-age-seconds <n>]`
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

function readText(file, label) {
  regularFile(file, label)
  return fs.readFileSync(file, 'utf8')
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

function requireString(value, label, pattern) {
  if (typeof value !== 'string' || !value || !pattern.test(value)) fail(`${label} is invalid`)
  return value
}

function parseToolchainLog(text) {
  const swift = text.match(/Apple Swift version ([0-9]+(?:\.[0-9]+){1,2})/)
  const xcode = text.match(/^Xcode ([0-9]+(?:\.[0-9]+){0,2})$/m)
  const build = text.match(/^Build version ([0-9A-Za-z]+)$/m)
  if (!swift || !xcode || !build) {
    fail('toolchain log must contain the Apple Swift version and the Xcode version and build')
  }
  return { swift: swift[1], xcode: xcode[1], xcodeBuild: build[1] }
}

function parseDestination(value) {
  const fields = new Map()
  for (const part of value.split(',')) {
    const separator = part.indexOf('=')
    if (separator <= 0) fail(`--destination is not an xcodebuild destination: ${value}`)
    const key = part.slice(0, separator).trim()
    if (fields.has(key)) fail(`--destination repeats ${key}`)
    fields.set(key, part.slice(separator + 1).trim())
  }
  const platform = fields.get('platform')
  const device = fields.get('name')
  const operatingSystem = fields.get('OS')
  if (!platform || !device || !operatingSystem || fields.size !== 3) {
    fail('--destination must name exactly a platform, a device name, and an OS')
  }
  if (platform !== REQUIRED_DESTINATION_PLATFORM) {
    fail(`--destination must target the ${REQUIRED_DESTINATION_PLATFORM}; found ${platform}`)
  }
  return { platform, device, os: operatingSystem }
}

function parseTestLog(text) {
  if (TEST_ABORTED.test(text)) fail('iPhone test log records a failed or cancelled run')
  if (!TEST_SUCCEEDED.test(text)) fail('iPhone test log has no completed xcodebuild test result')
  const totals = { executed: 0, failed: 0, unexpected: 0, suites: 0 }
  for (const match of text.matchAll(AGGREGATE_SUITE)) {
    if (match[1] !== 'passed') fail('iPhone test log records a failed aggregate test suite')
    totals.suites += 1
    totals.executed += Number(match[2])
    totals.failed += Number(match[3])
    totals.unexpected += Number(match[4])
  }
  if (!totals.suites) fail('iPhone test log contains no aggregate test suite result')
  if (!totals.executed) fail('iPhone test log reports a green run that executed no tests')
  if (totals.failed || totals.unexpected) fail('iPhone test log reports test failures')
  return totals
}

function toolchainFingerprint(toolchain) {
  const canonical = [
    `image=${toolchain.runnerImage}`,
    `imageVersion=${toolchain.runnerImageVersion}`,
    `swift=${toolchain.swift}`,
    `xcode=${toolchain.xcode}`,
    `xcodeBuild=${toolchain.xcodeBuild}`,
  ].join('\n')
  return crypto.createHash('sha256').update(`${canonical}\n`).digest('hex')
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
  if (path.basename(options.output) !== RECEIPT_NAME) fail(`--output must be named ${RECEIPT_NAME}`)
  if (fs.existsSync(options.output)) fail('companion contract receipt already exists')
  const toolchain = {
    ...parseToolchainLog(readText(options.toolchainLog, 'toolchain log')),
    runnerImage: options.runnerImage,
    runnerImageVersion: options.runnerImageVersion,
  }
  toolchain.fingerprint = toolchainFingerprint(toolchain)
  const destination = parseDestination(options.destination)
  const tests = parseTestLog(readText(options.testLog, 'iPhone test log'))

  const receipt = {
    schemaVersion: SCHEMA_VERSION,
    kind: KIND,
    repository: options.repository,
    source: {
      commit: options.commit,
      ref: options.sourceRef,
    },
    workflow: {
      runID: options.runID,
      runAttempt: Number(options.runAttempt),
    },
    toolchain,
    destination,
    tests,
    generatedAt: new Date().toISOString(),
    pass: true,
  }
  writeJSONAtomic(options.output, receipt)
  return receipt
}

function verifyReceipt(options) {
  if (path.basename(options.receipt) !== RECEIPT_NAME) fail(`--receipt must be named ${RECEIPT_NAME}`)
  const receipt = readJSON(options.receipt, 'companion contract receipt')
  if (receipt.schemaVersion !== SCHEMA_VERSION || receipt.kind !== KIND) {
    fail('companion contract receipt schema is unsupported')
  }
  if (receipt.pass !== true) fail('companion contract receipt does not record a passing iPhone run')
  if (receipt.repository !== options.repository
      || receipt.source?.commit !== options.commit
      || receipt.source?.ref !== PROMOTABLE_SOURCE_REF
      || receipt.workflow?.runID !== options.runID) {
    fail('companion contract does not belong to this repository, commit, protected ref, and run')
  }
  const runAttempt = requireInteger(receipt.workflow.runAttempt, 'companion contract run attempt', { minimum: 1 })
  if (options.runAttempt && String(runAttempt) !== options.runAttempt) {
    fail('companion contract was produced by a different run attempt')
  }

  const toolchain = {
    swift: requireString(receipt.toolchain?.swift, 'companion toolchain Swift version', /^[0-9]+(?:\.[0-9]+){1,2}$/),
    xcode: requireString(receipt.toolchain?.xcode, 'companion toolchain Xcode version', /^[0-9]+(?:\.[0-9]+){0,2}$/),
    xcodeBuild: requireString(receipt.toolchain?.xcodeBuild, 'companion toolchain Xcode build', /^[0-9A-Za-z]{1,16}$/),
    runnerImage: requireString(receipt.toolchain?.runnerImage, 'companion toolchain runner image', /^[A-Za-z0-9._-]{1,32}$/),
    runnerImageVersion: requireString(receipt.toolchain?.runnerImageVersion, 'companion toolchain runner image version', /^[A-Za-z0-9._-]{1,64}$/),
  }
  if (receipt.toolchain.fingerprint !== toolchainFingerprint(toolchain)) {
    fail('companion toolchain fingerprint does not seal the recorded toolchain')
  }
  if (toolchain.runnerImage !== options.requireRunnerImage) {
    fail(`companion contract ran on runner image ${toolchain.runnerImage}, not ${options.requireRunnerImage}`)
  }

  if (receipt.destination?.platform !== REQUIRED_DESTINATION_PLATFORM) {
    fail(`companion contract did not run on the ${REQUIRED_DESTINATION_PLATFORM}`)
  }
  const device = requireString(receipt.destination?.device, 'companion destination device', /^[A-Za-z0-9 ()._-]{1,64}$/)
  requireString(receipt.destination?.os, 'companion destination OS', /^[A-Za-z0-9._-]{1,32}$/)
  if (options.requireDevice && device !== options.requireDevice) {
    fail(`companion contract ran on ${device}, not ${options.requireDevice}`)
  }

  const minimumTests = Number(options.minimumTests || DEFAULT_MINIMUM_TESTS)
  const tests = {
    executed: requireInteger(receipt.tests?.executed, 'companion executed test count', { minimum: 1 }),
    failed: requireInteger(receipt.tests?.failed, 'companion failed test count'),
    unexpected: requireInteger(receipt.tests?.unexpected, 'companion unexpected failure count'),
    suites: requireInteger(receipt.tests?.suites, 'companion aggregate suite count', { minimum: 1 }),
  }
  if (tests.failed || tests.unexpected) fail('companion contract records test failures')
  if (tests.executed < minimumTests) {
    fail(`companion contract executed ${tests.executed} tests, fewer than the required ${minimumTests}`)
  }

  const generatedAt = new Date(receipt.generatedAt)
  if (Number.isNaN(generatedAt.valueOf()) || generatedAt.toISOString() !== receipt.generatedAt) {
    fail('companion contract timestamp is not canonical ISO-8601')
  }
  const ageSeconds = Math.round((Date.now() - generatedAt.valueOf()) / 1000)
  if (ageSeconds < -FUTURE_SKEW_SECONDS) fail('companion contract is timestamped in the future')
  if (options.maxAgeSeconds && ageSeconds > Number(options.maxAgeSeconds)) {
    fail(`companion contract is ${ageSeconds}s old, older than the required ${options.maxAgeSeconds}s`)
  }

  return {
    pass: true,
    receipt: options.receipt,
    repository: receipt.repository,
    commit: receipt.source.commit,
    runID: receipt.workflow.runID,
    runAttempt,
    toolchainFingerprint: receipt.toolchain.fingerprint,
    device,
    testsExecuted: tests.executed,
  }
}

if (require.main === module) {
  try {
    const options = parseArguments(process.argv.slice(2))
    if (options.help) console.log(usage())
    else {
      const result = options.command === 'create' ? createReceipt(options) : verifyReceipt(options)
      console.log(`COMPANION_CONTRACT=${JSON.stringify(result)}`)
    }
  } catch (error) {
    console.error(`COMPANION_CONTRACT=FAIL ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = {
  KIND,
  RECEIPT_NAME,
  REQUIRED_DESTINATION_PLATFORM,
  SCHEMA_VERSION,
  createReceipt,
  parseArguments,
  parseDestination,
  parseTestLog,
  parseToolchainLog,
  toolchainFingerprint,
  verifyReceipt,
}
