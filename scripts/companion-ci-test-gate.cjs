#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const SCHEMA_VERSION = 1
const REQUIRED_ARCHITECTURE = 'arm64'
const REQUIRED_BINARY_LABELS = Object.freeze([
  'test-bundle',
  'test-host',
  'test-host-debug-dylib',
])
const UUID_PATTERN = /^[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/iu
const EXACT_VERSION_PATTERN = /^\d+(?:\.\d+){1,2}$/u
const RUNTIME_IDENTIFIER_PATTERN = /^com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/u
const DEVICE_TYPE_IDENTIFIER_PATTERN = /^com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/u
const LAUNCH_PHASES = Object.freeze([
  'app_init_started',
  'auth_model_constructed',
  'app_init_completed',
  'auth_restore_started',
  'auth_restore_completed',
  'root_task_completed',
])
const REQUIRED_SUCCESS_PHASES = Object.freeze([
  'app_init_started',
  'auth_model_constructed',
  'app_init_completed',
])

function parseXcodeVersion(text) {
  const match = String(text).trim().match(/^Xcode ([0-9]+(?:\.[0-9]+)*)\r?\nBuild version ([A-Za-z0-9.]+)$/u)
  if (!match) throw new Error('xcodebuild -version did not return the expected two-line receipt')
  return { version: match[1], buildVersion: match[2] }
}

function requireExactArchitectures(text, label = 'binary') {
  const architectures = [...new Set(String(text).trim().split(/\s+/u).filter(Boolean))].sort()
  if (architectures.length !== 1 || architectures[0] !== REQUIRED_ARCHITECTURE) {
    throw new Error(`${label} must contain exactly arm64; observed ${architectures.join(', ') || 'none'}`)
  }
  return architectures
}

function validateArchitectureReceipt(receipt) {
  if (receipt?.schemaVersion !== SCHEMA_VERSION
      || receipt?.architecture !== REQUIRED_ARCHITECTURE
      || receipt?.pass !== true
      || !Array.isArray(receipt?.binaries)
      || receipt.binaries.length !== REQUIRED_BINARY_LABELS.length) {
    return false
  }
  const labels = receipt.binaries.map((binary) => binary?.label).sort()
  if (!REQUIRED_BINARY_LABELS.every((label, index) => labels[index] === label)) return false
  return receipt.binaries.every((binary) => (
    typeof binary.path === 'string'
      && binary.path.length > 0
      && Array.isArray(binary.architectures)
      && binary.architectures.length === 1
      && binary.architectures[0] === REQUIRED_ARCHITECTURE
  ))
}

function verifySimulatorProbe(text, expectedArchitecture = REQUIRED_ARCHITECTURE) {
  if (expectedArchitecture !== REQUIRED_ARCHITECTURE) {
    throw new Error(`Companion CI requires ${REQUIRED_ARCHITECTURE}, not ${expectedArchitecture}`)
  }
  const lines = String(text).split(/\r?\n/u).map((line) => line.trim()).filter(Boolean)
  if (lines.length !== 1 || lines[0] !== expectedArchitecture) {
    throw new Error(`pinned simulator probe reported ${lines.join(', ') || 'no architecture'} instead of ${expectedArchitecture}`)
  }
  return { architecture: expectedArchitecture, pass: true }
}

function parseXCResultSummary(payload, expectedEnvironment = null) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error('xcresult summary must be an object')
  }
  const countFields = ['totalTestCount', 'passedTests', 'failedTests', 'skippedTests', 'expectedFailures']
  for (const field of countFields) {
    if (!Number.isSafeInteger(payload[field]) || payload[field] < 0) {
      throw new Error(`xcresult summary has an invalid ${field}`)
    }
    if (field !== 'totalTestCount' && payload[field] > payload.totalTestCount) {
      throw new Error(`xcresult summary ${field} exceeds totalTestCount`)
    }
  }
  if (!['Passed', 'Failed', 'Skipped', 'Expected Failure', 'unknown'].includes(payload.result)) {
    throw new Error('xcresult summary has an invalid result')
  }
  if (!Array.isArray(payload.devicesAndConfigurations)
      || payload.devicesAndConfigurations.length !== 1) {
    throw new Error('xcresult summary must contain exactly one device and configuration')
  }
  const configuration = payload.devicesAndConfigurations[0]
  const device = configuration?.device
  if (!device || typeof device !== 'object' || Array.isArray(device)) {
    throw new Error('xcresult summary omitted its device and configuration')
  }
  for (const field of ['passedTests', 'failedTests', 'skippedTests', 'expectedFailures']) {
    if (configuration[field] !== payload[field]) {
      throw new Error(`xcresult device configuration ${field} disagrees with the summary`)
    }
  }
  if (typeof configuration.testPlanConfiguration?.configurationId !== 'string'
      || !configuration.testPlanConfiguration.configurationId
      || typeof configuration.testPlanConfiguration?.configurationName !== 'string'
      || !configuration.testPlanConfiguration.configurationName) {
    throw new Error('xcresult summary omitted its test plan configuration')
  }
  for (const field of ['deviceId', 'deviceName', 'architecture', 'modelName', 'platform', 'osVersion']) {
    if (typeof device[field] !== 'string' || !device[field]) {
      throw new Error(`xcresult summary device omitted ${field}`)
    }
  }

  let environmentMatches = null
  if (expectedEnvironment) {
    environmentMatches = (
      device.deviceId.toUpperCase() === String(expectedEnvironment.udid).toUpperCase()
        && device.deviceName === expectedEnvironment.deviceName
        && device.architecture === expectedEnvironment.architecture
        && device.osVersion === expectedEnvironment.runtimeVersion
        && device.platform === 'iOS Simulator'
    )
    if (!environmentMatches) {
      throw new Error('xcresult summary environment does not match the pinned simulator receipt')
    }
  }

  return {
    result: payload.result,
    totalTestCount: payload.totalTestCount,
    passedTests: payload.passedTests,
    failedTests: payload.failedTests,
    skippedTests: payload.skippedTests,
    expectedFailures: payload.expectedFailures,
    environmentMatches,
    device,
  }
}

function resolveSimulator({
  devices,
  runtimes,
  expectedXcodeVersion,
  expectedXcodeBuildVersion,
  xcodeVersionText,
  runtimeIdentifier,
  runtimeVersion,
  deviceTypeIdentifier,
  deviceName,
  architecture,
}) {
  if (!EXACT_VERSION_PATTERN.test(String(runtimeVersion))) {
    throw new Error('runtime version must be an exact numeric version such as 26.2')
  }
  if (architecture !== REQUIRED_ARCHITECTURE) {
    throw new Error(`Companion CI requires ${REQUIRED_ARCHITECTURE}, not ${architecture || 'an unspecified architecture'}`)
  }
  if (!RUNTIME_IDENTIFIER_PATTERN.test(String(runtimeIdentifier))) {
    throw new Error('runtime identifier must be an exact CoreSimulator runtime identifier')
  }
  if (!DEVICE_TYPE_IDENTIFIER_PATTERN.test(String(deviceTypeIdentifier))) {
    throw new Error('device type must be an exact CoreSimulator device type identifier')
  }
  if (!deviceName || /latest/iu.test(deviceName)) throw new Error('device name must be exact')

  const xcode = parseXcodeVersion(xcodeVersionText)
  if (xcode.version !== expectedXcodeVersion) {
    throw new Error(`Xcode version drifted: expected ${expectedXcodeVersion}, observed ${xcode.version}`)
  }
  if (xcode.buildVersion !== expectedXcodeBuildVersion) {
    throw new Error(`Xcode build drifted: expected ${expectedXcodeBuildVersion}, observed ${xcode.buildVersion}`)
  }

  const matchingRuntimes = Array.isArray(runtimes?.runtimes)
    ? runtimes.runtimes.filter((runtime) => runtime?.identifier === runtimeIdentifier)
    : []
  if (matchingRuntimes.length !== 1) {
    throw new Error(`expected exactly one runtime with identifier ${runtimeIdentifier}; observed ${matchingRuntimes.length}`)
  }
  const runtime = matchingRuntimes[0]
  if (runtime.isAvailable !== true) throw new Error(`pinned runtime is unavailable: ${runtimeIdentifier}`)
  if (runtime.version !== runtimeVersion) {
    throw new Error(`runtime version drifted: expected ${runtimeVersion}, observed ${runtime.version || 'none'}`)
  }
  if (!Array.isArray(runtime.supportedArchitectures)
      || !runtime.supportedArchitectures.includes(REQUIRED_ARCHITECTURE)) {
    throw new Error(`pinned runtime does not support ${REQUIRED_ARCHITECTURE}`)
  }

  const runtimeDevices = devices?.devices?.[runtimeIdentifier]
  if (!Array.isArray(runtimeDevices)) {
    throw new Error(`device inventory omitted pinned runtime ${runtimeIdentifier}`)
  }
  const matches = runtimeDevices.filter((device) => (
    device?.isAvailable === true
      && device?.name === deviceName
      && device?.deviceTypeIdentifier === deviceTypeIdentifier
  ))
  if (matches.length !== 1) {
    throw new Error(`expected exactly one available simulator for ${deviceName} (${deviceTypeIdentifier}); observed ${matches.length}`)
  }
  const device = matches[0]
  if (!UUID_PATTERN.test(String(device.udid))) throw new Error('simulator inventory returned an invalid UDID')

  return {
    schemaVersion: SCHEMA_VERSION,
    xcode,
    runtime: {
      identifier: runtime.identifier,
      version: runtime.version,
      name: String(runtime.name || ''),
      buildVersion: String(runtime.buildversion || ''),
    },
    device: {
      name: device.name,
      typeIdentifier: device.deviceTypeIdentifier,
      udid: device.udid,
      state: String(device.state || 'Unknown'),
    },
    architecture,
    destination: `platform=iOS Simulator,id=${device.udid},arch=${architecture}`,
  }
}

function parseLaunchAttempts(log) {
  const phaseIndexes = new Map(LAUNCH_PHASES.map((phase, index) => [phase, index]))
  const byPID = new Map()
  const marker = /KAISOLA_COMPANION_TEST_LAUNCH phase=([a-z_]+) pid=(\d+)/gu
  for (const match of String(log).matchAll(marker)) {
    const phase = match[1]
    const pid = Number(match[2])
    if (!phaseIndexes.has(phase) || !Number.isSafeInteger(pid) || pid <= 0) continue
    let attempt = byPID.get(pid)
    if (!attempt) {
      attempt = { pid, phases: [], orderValid: true }
      byPID.set(pid, attempt)
    }
    const previous = attempt.phases.at(-1)
    if (previous === phase) continue
    if (previous && phaseIndexes.get(phase) < phaseIndexes.get(previous)) attempt.orderValid = false
    attempt.phases.push(phase)
  }
  return [...byPID.values()]
}

function extractCrashProcess(log) {
  let result = null
  for (const line of String(log).split(/\r?\n/u)) {
    if (!/(?:signal bus|SIGBUS)/iu.test(line)) continue
    const matches = [...line.matchAll(/\b([A-Za-z_][A-Za-z0-9_.-]*)\s*\((\d+)\)/gu)]
    const match = matches.at(-1)
    if (match) result = { process: match[1], pid: Number(match[2]) }
  }
  return result
}

function lastExecutedTestCount(log) {
  const counts = [...String(log).matchAll(/\bExecuted\s+(\d+)\s+tests?\b/gu)]
    .map((match) => Number(match[1]))
    .filter(Number.isSafeInteger)
  return counts.length ? Math.max(...counts) : 0
}

function launchStageForSIGBUS(attempt) {
  if (!attempt) return 'pre_app_entry_sigbus'
  const phases = new Set(attempt.phases)
  if (!phases.has('app_init_completed')) return 'app_initialization_sigbus'
  if (phases.has('auth_restore_started') && !phases.has('auth_restore_completed')) {
    return 'auth_restore_sigbus'
  }
  if (phases.has('auth_restore_completed')) return 'test_bootstrap_sigbus'
  return 'post_app_init_pre_restore_sigbus'
}

function classifyTestRun({
  log,
  launchDiagnostics,
  exitCode,
  resultBundlePresent,
  destinationReceiptValid,
  architectureReceiptValid,
  simulatorProbeValid,
  launchDiagnosticsPresent = true,
  xcresultDiagnosticsPresent = true,
  simulatorLogPresent,
  simulatorDiagnosePresent,
  crashReportPresent,
  xcresultSummaryPresent,
  xcresultTestCount,
  xcresultResult,
  xcresultEnvironmentMatches,
}) {
  const text = String(log || '')
  const signalBus = /(?:signal bus|SIGBUS)/iu.test(text)
  const explicitlyPreBootstrap = /(?:before starting test execution|never finished bootstrapping)/iu.test(text)
  const testCaseStartedCount = [...text.matchAll(/\bTest Case ['"].+? started\./gu)].length
  const executedTestCount = lastExecutedTestCount(text)
  const testsStarted = testCaseStartedCount > 0 || executedTestCount > 0
  const xcodeReportedSuccess = /\*\* TEST EXECUTE SUCCEEDED \*\*/u.test(text)
  const attempts = parseLaunchAttempts(
    launchDiagnostics === undefined ? text : String(launchDiagnostics),
  )
  const crashProcess = extractCrashProcess(text)
  const crashedPID = crashProcess?.pid ?? null
  const relevantLaunchAttempt = crashedPID === null
    ? (attempts.at(-1) || null)
    : (attempts.find((attempt) => attempt.pid === crashedPID) || null)
  const relevantPhases = new Set(relevantLaunchAttempt?.phases || [])
  const launchDiagnosticsComplete = Boolean(
    relevantLaunchAttempt?.orderValid
      && REQUIRED_SUCCESS_PHASES.every((phase) => relevantPhases.has(phase)),
  )

  let classification
  if (!text.trim()) {
    classification = 'test_not_run'
  } else if (signalBus) {
    classification = testsStarted ? 'post_bootstrap_sigbus' : launchStageForSIGBUS(relevantLaunchAttempt)
  } else if (exitCode === 0 && xcodeReportedSuccess) {
    if (!testsStarted || executedTestCount === 0) classification = 'zero_test_success'
    else if (xcresultSummaryPresent && xcresultTestCount === 0) classification = 'zero_test_success'
    else if (xcresultSummaryPresent && xcresultEnvironmentMatches !== true) classification = 'xcresult_environment_mismatch'
    else if (xcresultSummaryPresent && xcresultResult !== 'Passed') classification = 'xcresult_not_passed'
    else if (xcresultSummaryPresent && xcresultTestCount !== executedTestCount) classification = 'test_count_mismatch'
    else if (!launchDiagnosticsComplete) classification = 'missing_launch_diagnostics'
    else classification = 'pass'
  } else if (exitCode === 0) {
    classification = 'xcode_success_without_success_marker'
  } else if (testsStarted) {
    classification = 'test_failure'
  } else {
    classification = 'prebootstrap_test_failure'
  }

  const artifactChecks = [
    ['destination-receipt', destinationReceiptValid],
    ['architecture-receipt', architectureReceiptValid],
    ['simulator-probe-receipt', simulatorProbeValid],
    ['launch-diagnostics', launchDiagnosticsPresent],
    ['xcresult-bundle', resultBundlePresent],
    ['xcresult-diagnostics', xcresultDiagnosticsPresent],
    ['xcresult-summary', xcresultSummaryPresent],
  ]
  if (classification !== 'pass') {
    artifactChecks.push(
      ['simulator-log', simulatorLogPresent],
      ['simctl-diagnose', simulatorDiagnosePresent],
    )
    if (signalBus) artifactChecks.push(['crash-report', crashReportPresent])
  }
  const missingArtifacts = artifactChecks
    .filter(([, present]) => present !== true)
    .map(([name]) => name)
  const diagnosticsComplete = missingArtifacts.length === 0
  if (classification === 'pass' && !diagnosticsComplete) classification = 'incomplete_success_evidence'

  return {
    schemaVersion: SCHEMA_VERSION,
    pass: classification === 'pass' && diagnosticsComplete,
    classification,
    exitCode: Number.isInteger(exitCode) ? exitCode : null,
    signalBus,
    explicitlyPreBootstrap,
    testCaseStartedCount,
    executedTestCount,
    xcresultTestCount: Number.isSafeInteger(xcresultTestCount) ? xcresultTestCount : null,
    xcresultResult: typeof xcresultResult === 'string' ? xcresultResult : null,
    xcresultEnvironmentMatches: xcresultEnvironmentMatches === true,
    xcodeReportedSuccess,
    crashedProcess: crashProcess?.process ?? null,
    crashedPID,
    launchAttempts: attempts,
    relevantLaunchAttempt,
    launchDiagnosticsComplete,
    simulatorProbePassed: simulatorProbeValid === true,
    diagnosticsComplete,
    missingArtifacts,
  }
}

function parseArguments(argv) {
  const [command, ...tokens] = argv
  if (!command) throw new Error('a command is required')
  const options = new Map()
  for (let index = 0; index < tokens.length; index += 2) {
    const name = tokens[index]
    const value = tokens[index + 1]
    if (!name?.startsWith('--') || value === undefined) throw new Error(`invalid option near ${name || 'end of input'}`)
    const key = name.slice(2)
    if (key !== 'binary' && options.has(key)) throw new Error(`duplicate option --${key}`)
    if (key === 'binary') options.set(key, [...(options.get(key) || []), value])
    else options.set(key, value)
  }
  return { command, options }
}

function required(options, name) {
  const value = options.get(name)
  if (value === undefined || value === '') throw new Error(`--${name} is required`)
  return value
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function writeJSONAtomic(destination, value) {
  const directory = path.dirname(destination)
  fs.mkdirSync(directory, { recursive: true })
  const temporary = path.join(directory, `.${path.basename(destination)}.${process.pid}.tmp`)
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  fs.renameSync(temporary, destination)
}

function hasContent(target) {
  if (!target || !fs.existsSync(target)) return false
  const stats = fs.statSync(target)
  if (stats.isFile()) return stats.size > 0
  if (!stats.isDirectory()) return false
  const pending = [target]
  while (pending.length) {
    const directory = pending.pop()
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name)
      if (entry.isFile() && fs.statSync(candidate).size > 0) return true
      if (entry.isDirectory()) pending.push(candidate)
    }
  }
  return false
}

function hasFile(target) {
  try {
    return Boolean(target) && fs.statSync(target).isFile()
  } catch {
    return false
  }
}

function hasCrashReport(target) {
  if (!target || !fs.existsSync(target) || !fs.statSync(target).isDirectory()) return false
  const pending = [target]
  while (pending.length) {
    const directory = pending.pop()
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const candidate = path.join(directory, entry.name)
      if (entry.isFile() && /\.(?:crash|ips)$/iu.test(entry.name) && fs.statSync(candidate).size > 0) {
        return true
      }
      if (entry.isDirectory()) pending.push(candidate)
    }
  }
  return false
}

function validJSONReceipt(target, validate) {
  try {
    if (!hasContent(target)) return false
    return validate(readJSON(target)) === true
  } catch {
    return false
  }
}

function readExitCode(target) {
  try {
    const value = Number(fs.readFileSync(target, 'utf8').trim())
    return Number.isInteger(value) && value >= 0 && value <= 255 ? value : null
  } catch {
    return null
  }
}

function runResolve(options) {
  const receipt = resolveSimulator({
    devices: readJSON(required(options, 'devices-json')),
    runtimes: readJSON(required(options, 'runtimes-json')),
    expectedXcodeVersion: required(options, 'expected-xcode-version'),
    expectedXcodeBuildVersion: required(options, 'expected-xcode-build-version'),
    xcodeVersionText: fs.readFileSync(required(options, 'xcode-version-file'), 'utf8'),
    runtimeIdentifier: required(options, 'runtime-identifier'),
    runtimeVersion: required(options, 'runtime-version'),
    deviceTypeIdentifier: required(options, 'device-type-identifier'),
    deviceName: required(options, 'device-name'),
    architecture: required(options, 'architecture'),
  })
  writeJSONAtomic(required(options, 'output'), receipt)
  const githubOutput = required(options, 'github-output')
  fs.appendFileSync(githubOutput, [
    `udid=${receipt.device.udid}`,
    `destination=${receipt.destination}`,
    `runtime_identifier=${receipt.runtime.identifier}`,
    `runtime_version=${receipt.runtime.version}`,
    `architecture=${receipt.architecture}`,
    '',
  ].join('\n'))
}

function runVerifyArchitectures(options) {
  const expected = required(options, 'architecture')
  if (expected !== REQUIRED_ARCHITECTURE) throw new Error(`Companion CI requires ${REQUIRED_ARCHITECTURE}`)
  const specifications = options.get('binary') || []
  if (!specifications.length) throw new Error('at least one --binary label=path is required')
  const binaries = specifications.map((specification) => {
    const separator = specification.indexOf('=')
    if (separator <= 0) throw new Error(`invalid binary specification: ${specification}`)
    const label = specification.slice(0, separator)
    const target = specification.slice(separator + 1)
    if (!/^[a-z][a-z0-9-]*$/u.test(label) || !target) throw new Error(`invalid binary specification: ${specification}`)
    if (!fs.statSync(target).isFile()) throw new Error(`${label} is not a regular binary: ${target}`)
    const result = spawnSync('/usr/bin/lipo', ['-archs', target], { encoding: 'utf8' })
    if (result.status !== 0) throw new Error(`lipo failed for ${label}: ${String(result.stderr).trim()}`)
    return { label, path: target, architectures: requireExactArchitectures(result.stdout, label) }
  })
  const receipt = {
    schemaVersion: SCHEMA_VERSION,
    architecture: expected,
    binaries,
    pass: true,
  }
  if (!validateArchitectureReceipt(receipt)) {
    throw new Error(`binary set must be exactly: ${REQUIRED_BINARY_LABELS.join(', ')}`)
  }
  writeJSONAtomic(required(options, 'output'), receipt)
}

function runVerifyProbe(options) {
  const architecture = required(options, 'architecture')
  const result = verifySimulatorProbe(fs.readFileSync(required(options, 'input'), 'utf8'), architecture)
  writeJSONAtomic(required(options, 'output'), { schemaVersion: SCHEMA_VERSION, ...result })
}

function runClassify(options) {
  const logPath = required(options, 'log')
  const launchDiagnosticsPath = required(options, 'launch-diagnostics')
  const readOptionalText = (target) => {
    try { return fs.readFileSync(target, 'utf8') } catch { return '' }
  }
  const destinationReceipt = required(options, 'destination-receipt')
  const architectureReceipt = required(options, 'architecture-receipt')
  const simulatorProbeReceipt = required(options, 'simulator-probe-receipt')
  let destinationPayload = null
  try { destinationPayload = readJSON(destinationReceipt) } catch {}
  const destinationReceiptValid = Boolean(
    destinationPayload?.schemaVersion === SCHEMA_VERSION
      && destinationPayload?.architecture === REQUIRED_ARCHITECTURE
      && UUID_PATTERN.test(String(destinationPayload?.device?.udid))
      && destinationPayload?.destination === `platform=iOS Simulator,id=${destinationPayload.device.udid},arch=${REQUIRED_ARCHITECTURE}`,
  )
  let xcresultSummary = null
  let xcresultEnvironmentMatches = false
  try {
    const summaryPayload = readJSON(required(options, 'xcresult-summary'))
    xcresultSummary = parseXCResultSummary(summaryPayload)
    if (destinationReceiptValid) {
      parseXCResultSummary(summaryPayload, {
        udid: destinationPayload.device.udid,
        deviceName: destinationPayload.device.name,
        architecture: destinationPayload.architecture,
        runtimeVersion: destinationPayload.runtime.version,
      })
      xcresultEnvironmentMatches = true
    }
  } catch {}
  const result = classifyTestRun({
    log: readOptionalText(logPath),
    launchDiagnostics: readOptionalText(launchDiagnosticsPath),
    exitCode: readExitCode(required(options, 'exit-code-file')),
    resultBundlePresent: hasContent(required(options, 'result-bundle')),
    destinationReceiptValid,
    architectureReceiptValid: validJSONReceipt(architectureReceipt, validateArchitectureReceipt),
    simulatorProbeValid: validJSONReceipt(simulatorProbeReceipt, (receipt) => (
      receipt?.schemaVersion === SCHEMA_VERSION
        && receipt?.architecture === REQUIRED_ARCHITECTURE
        && receipt?.pass === true
    )),
    launchDiagnosticsPresent: hasFile(launchDiagnosticsPath),
    xcresultDiagnosticsPresent: hasContent(required(options, 'xcresult-diagnostics'))
      && hasContent(required(options, 'xcresult-diagnostics-success')),
    simulatorLogPresent: hasContent(required(options, 'simulator-log')),
    simulatorDiagnosePresent: hasContent(required(options, 'simulator-diagnose'))
      && hasContent(required(options, 'simulator-diagnose-success')),
    crashReportPresent: hasCrashReport(required(options, 'crash-reports')),
    xcresultSummaryPresent: xcresultSummary !== null,
    xcresultTestCount: xcresultSummary?.totalTestCount,
    xcresultResult: xcresultSummary?.result,
    xcresultEnvironmentMatches,
  })
  const receipt = {
    ...result,
    artifacts: {
      testLog: logPath,
      launchDiagnostics: launchDiagnosticsPath,
      resultBundle: required(options, 'result-bundle'),
      xcresultDiagnostics: required(options, 'xcresult-diagnostics'),
      destinationReceipt,
      architectureReceipt,
      simulatorProbeReceipt,
      xcresultSummary: required(options, 'xcresult-summary'),
      simulatorLog: required(options, 'simulator-log'),
      simulatorDiagnose: required(options, 'simulator-diagnose'),
      crashReports: required(options, 'crash-reports'),
    },
  }
  writeJSONAtomic(required(options, 'output'), receipt)
  if (!receipt.pass) process.exitCode = 1
}

function main(argv) {
  const { command, options } = parseArguments(argv)
  if (command === 'resolve-simulator') return runResolve(options)
  if (command === 'verify-architectures') return runVerifyArchitectures(options)
  if (command === 'verify-simulator-probe') return runVerifyProbe(options)
  if (command === 'classify-test') return runClassify(options)
  throw new Error(`unknown command: ${command}`)
}

if (require.main === module) {
  try {
    main(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`companion-ci-test-gate: ${error.message}\n`)
    process.exitCode = 1
  }
}

module.exports = {
  classifyTestRun,
  hasCrashReport,
  hasContent,
  parseArguments,
  parseLaunchAttempts,
  parseXCResultSummary,
  parseXcodeVersion,
  requireExactArchitectures,
  resolveSimulator,
  validateArchitectureReceipt,
  verifySimulatorProbe,
  writeJSONAtomic,
}
