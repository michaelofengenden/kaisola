#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const {
  isAlive,
  launchNative,
  terminalStreamDelta,
  terminalStreamHeads,
  terminate,
  wait,
  workloadAliases,
} = require('./native-frame-support.cjs')

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  const options = {}
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const next = () => {
      const value = argv[++index]
      if (value == null) fail(`${argument} requires a value`)
      return value
    }
    if (argument === '--app') options.app = path.resolve(next())
    else if (argument === '--output') options.output = path.resolve(next())
    else if (argument === '--help' || argument === '-h') options.help = true
    else fail(`unknown argument: ${argument}`)
  }
  if (options.help) return options
  if (!options.app || !options.output) fail('--app and --output are required')
  return options
}

function validateReport(report, expectedWorkload = workloadAliases.get('streaming')) {
  if (!report || report.schemaVersion !== 1) fail('frame cadence receipt schema drifted')
  if (report.workload !== expectedWorkload) fail('frame cadence workload drifted')
  if (!(report.measurementDurationSeconds >= 29.5 && report.measurementDurationSeconds <= 35)) {
    fail('frame cadence measurement duration drifted')
  }
  if (!Number.isSafeInteger(report.callbackCount) || report.callbackCount < 100) {
    fail('frame cadence callback count is incomplete')
  }
  if (!(report.nominalFrameDurationMs > 0 && report.nominalFrameDurationMs <= 50)) {
    fail('frame cadence nominal duration is invalid')
  }
  for (const [key, value] of Object.entries({
    p95IntervalMs: report.p95IntervalMs,
    maximumIntervalMs: report.maximumIntervalMs,
    deadlineLossMs: report.deadlineLossMs,
    deadlineLossRateMsPerSecond: report.deadlineLossRateMsPerSecond,
    callbackCoverage: report.callbackCoverage,
  })) {
    if (!(value >= 0) || !Number.isFinite(value)) fail(`frame cadence metric is invalid: ${key}`)
  }
  if (report.callbackCoverage > 1
      || report.maximumIntervalMs < report.p95IntervalMs
      || !Number.isSafeInteger(report.missedFrameCount)
      || report.missedFrameCount < 0) {
    fail('frame cadence metric relationships are invalid')
  }
  const expectedThresholds = {
    maximumDeadlineLossRateMsPerSecond: 10,
    maximumP95IntervalFrames: 1.5,
    maximumIntervalMs: 100,
    minimumCallbackCoverage: 0.95,
  }
  for (const [key, value] of Object.entries(expectedThresholds)) {
    if (report.thresholds?.[key] !== value) fail(`frame cadence threshold drifted: ${key}`)
  }
  const checks = report.checks || {}
  const calculatedChecks = {
    deadlineLossRate:
      report.deadlineLossRateMsPerSecond <= expectedThresholds.maximumDeadlineLossRateMsPerSecond,
    p95Interval:
      report.p95IntervalMs <= report.nominalFrameDurationMs * expectedThresholds.maximumP95IntervalFrames,
    maximumInterval: report.maximumIntervalMs <= expectedThresholds.maximumIntervalMs,
    callbackCoverage: report.callbackCoverage >= expectedThresholds.minimumCallbackCoverage,
  }
  for (const [key, expected] of Object.entries(calculatedChecks)) {
    if (checks[key] !== expected) fail(`frame cadence check is inconsistent: ${key}`)
  }
  const calculatedPass = Object.values(calculatedChecks).every(Boolean)
  if (report.pass !== calculatedPass) fail('frame cadence pass receipt is inconsistent')
  return report
}

function completedLine(chunks) {
  const text = chunks.join('')
  const matches = [...text.matchAll(/^KAISOLA_NATIVE_FRAME_CADENCE=([^\r\n]+)\r?\n/gm)]
  if (!matches.length) return null
  if (matches.length !== 1) fail('frame cadence emitted more than one receipt')
  const raw = matches[0][1]
  if (raw.startsWith('FAIL ')) fail(raw)
  try {
    return validateReport(JSON.parse(raw))
  } catch (error) {
    if (error instanceof SyntaxError) fail('frame cadence emitted malformed JSON')
    throw error
  }
}

async function waitForReport(fixture, timeoutMs = 110_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const report = completedLine(fixture.output)
    if (report) return report
    if (!isAlive(fixture.appPid)) fail('native fixture exited before frame cadence receipt')
    await wait(100)
  }
  fail(`frame cadence receipt timed out after ${timeoutMs}ms`)
}

async function run(options) {
  let fixture
  try {
    fixture = await launchNative({
      app: options.app,
      workload: workloadAliases.get('streaming'),
      extraEnvironment: { KAISOLA_NATIVE_FRAME_CADENCE: '1' },
    })
    const streamBefore = await terminalStreamHeads(fixture)
    const report = await waitForReport(fixture)
    const streamAfter = await terminalStreamHeads(fixture)
    const terminalStreams = terminalStreamDelta(streamBefore, streamAfter)
    if (terminalStreams.totalDeltaBytes < 1_024) {
      fail('terminal cursor did not advance throughout the frame cadence capture')
    }
    const output = {
      ...report,
      source: 'NSView.displayLink main-run-loop callback cadence',
      app: options.app,
      appPid: fixture.appPid,
      brokerPid: fixture.brokerPid,
      launchToReadyMs: fixture.readyElapsedMs,
      terminalStreams,
      warmupSeconds: 60,
      requestedMeasurementSeconds: 30,
    }
    fs.mkdirSync(path.dirname(options.output), { recursive: true })
    fs.writeFileSync(options.output, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 })
    console.log(`NATIVE_FRAME_CADENCE_GATE=${JSON.stringify(output)}`)
    if (!output.pass) process.exitCode = 1
    return output
  } finally {
    if (fixture) {
      await terminate(fixture.appPid)
      await terminate(fixture.brokerPid)
      if (!isAlive(fixture.appPid) && !isAlive(fixture.brokerPid)) {
        fs.rmSync(fixture.root, { recursive: true, force: true })
      }
    }
  }
}

function usage() {
  return 'Usage: node scripts/native-frame-cadence-gate.cjs --app /path/Kaisola.app --output /path/report.json'
}

async function main(argv) {
  const options = parseArguments(argv)
  if (options.help) return console.log(usage())
  await run(options)
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`NATIVE_FRAME_CADENCE_GATE=FAIL ${error.message}`)
    process.exitCode = 1
  })
}

module.exports = {
  completedLine,
  parseArguments,
  validateReport,
}
