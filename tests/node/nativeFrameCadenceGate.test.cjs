'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  completedLine,
  parseArguments,
  validateReport,
} = require('../../scripts/native-frame-cadence-gate.cjs')
const {
  FIXTURE_LAUNCH_ARGUMENTS,
  brokerInfoPath,
} = require('../../scripts/native-frame-support.cjs')

function passingReport() {
  return {
    schemaVersion: 1,
    workload: 'one-window-streaming-terminal-fresh-broker',
    callbackCount: 1_790,
    measurementDurationSeconds: 30.01,
    nominalFrameDurationMs: 16.666,
    p95IntervalMs: 16.9,
    maximumIntervalMs: 33.2,
    missedFrameCount: 2,
    deadlineLossMs: 33.332,
    deadlineLossRateMsPerSecond: 1.11,
    callbackCoverage: 0.994,
    thresholds: {
      maximumDeadlineLossRateMsPerSecond: 10,
      maximumP95IntervalFrames: 1.5,
      maximumIntervalMs: 100,
      minimumCallbackCoverage: 0.95,
    },
    checks: {
      deadlineLossRate: true,
      p95Interval: true,
      maximumInterval: true,
      callbackCoverage: true,
    },
    pass: true,
  }
}

test('frame cadence gate accepts only the full fixed-duration fixture contract', () => {
  assert.deepEqual(FIXTURE_LAUNCH_ARGUMENTS, ['-ApplePersistenceIgnoreState', 'YES'])
  assert.equal(
    brokerInfoPath('/tmp/fixture'),
    '/tmp/fixture/broker-profile/session-broker/broker.json',
  )
  const options = parseArguments(['--app', '/tmp/Kaisola.app', '--output', '/tmp/frame.json'])
  assert.equal(options.app, '/tmp/Kaisola.app')
  assert.throws(() => parseArguments(['--app', '/tmp/Kaisola.app']), /required/)
  assert.throws(() => parseArguments(['--output', '/tmp/frame.json']), /required/)
  assert.throws(() => parseArguments(['--app', '/tmp/Kaisola.app', '--output', '/tmp/frame.json', '--warmup', '1']), /unknown/)
})

test('frame cadence receipt validation rejects threshold and pass drift', () => {
  assert.equal(validateReport(passingReport()).pass, true)
  assert.throws(() => validateReport({
    ...passingReport(),
    thresholds: { ...passingReport().thresholds, maximumIntervalMs: 200 },
  }), /threshold drifted/)
  assert.throws(() => validateReport({ ...passingReport(), pass: false }), /inconsistent/)
  assert.throws(() => validateReport({
    ...passingReport(),
    deadlineLossRateMsPerSecond: 11,
  }), /check is inconsistent/)
  assert.throws(() => validateReport({
    ...passingReport(),
    maximumIntervalMs: 10,
    p95IntervalMs: 20,
  }), /relationships/)
})

test('frame cadence stdout parser requires one complete JSON receipt', () => {
  const report = passingReport()
  assert.deepEqual(
    completedLine([`noise\nKAISOLA_NATIVE_FRAME_CADENCE=${JSON.stringify(report)}\n`]),
    report,
  )
  assert.equal(completedLine(['KAISOLA_NATIVE_FRAME_CADENCE={']), null)
  assert.throws(() => completedLine(['KAISOLA_NATIVE_FRAME_CADENCE=FAIL display-link-timeout\n']), /display-link-timeout/)
  assert.throws(() => completedLine([
    `KAISOLA_NATIVE_FRAME_CADENCE=${JSON.stringify(report)}\n`,
    `KAISOLA_NATIVE_FRAME_CADENCE=${JSON.stringify(report)}\n`,
  ]), /more than one/)
})
