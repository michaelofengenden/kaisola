'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  gateSummaries,
  parseArguments,
  parseTraceQueryRows,
  summarizeRows,
} = require('../../scripts/native-frame-trace-gate.cjs')

test('frame trace parser resolves xctrace ids and cross-row references', () => {
  const xml = `<?xml version="1.0"?><trace-query-result><node>
    <schema name="hitches"></schema>
    <row><start-time id="1">5000000000</start-time><duration id="2">20000000</duration></row>
    <row><start-time id="6">9990000000</start-time><duration ref="2"/></row>
    <row><start-time id="3">11000000000</start-time><duration ref="2"/></row>
    <row><start-time id="4">15000000000</start-time><duration id="5">40000000</duration></row>
  </node></trace-query-result>`
  const parsed = parseTraceQueryRows(xml, 'hitches')
  assert.deepEqual(parsed.rows, [
    { startNanoseconds: 5_000_000_000, durationNanoseconds: 20_000_000 },
    { startNanoseconds: 9_990_000_000, durationNanoseconds: 20_000_000 },
    { startNanoseconds: 11_000_000_000, durationNanoseconds: 20_000_000 },
    { startNanoseconds: 15_000_000_000, durationNanoseconds: 40_000_000 },
  ])
  const summary = summarizeRows(parsed.rows, 10_000_000_000, 20_000_000_000)
  assert.equal(summary.count, 3)
  assert.equal(summary.crossBoundaryCount, 1)
  assert.equal(summary.p50Ms, 20)
  assert.equal(summary.p95Ms, 40)
  assert.equal(summary.durationRateMsPerSecond, 7)
})

test('frame trace gate enforces Apple-good hitch rate plus update/render tails', () => {
  const summaries = {
    hitches: { count: 1, durationRateMsPerSecond: 9.5 },
    'potential-hangs': { count: 0 },
    'hitches-updates': { count: 1, p95Ms: 3.2 },
    'hitches-renders': { count: 0, p95Ms: 5.7 },
  }
  const limits = {
    maximumHitchRateMsPerSecond: 10,
    maximumPotentialHangs: 0,
    maximumUpdateP95Ms: 8.33,
    maximumRenderP95Ms: 8.33,
  }
  assert.equal(gateSummaries(summaries, limits).pass, true)
  assert.equal(gateSummaries({ ...summaries, hitches: { count: 1, durationRateMsPerSecond: 10.01 } }, limits).pass, false)
  assert.equal(gateSummaries({ ...summaries, 'potential-hangs': { count: 1 } }, limits).pass, false)
  assert.equal(gateSummaries({
    ...summaries,
    'hitches-updates': { count: 0, p95Ms: 0 },
    'hitches-renders': { count: 0, p95Ms: 0 },
  }, limits).pass, false)
})

test('frame trace CLI keeps a bounded steady interval and absolute limits', () => {
  const options = parseArguments([
    '--trace', '/tmp/native.trace', '--label', 'native-streaming', '--output', '/tmp/report.json',
  ])
  assert.equal(options.steadyStartSeconds, 10)
  assert.equal(options.steadyEndSeconds, 20)
  assert.equal(options.maximumHitchRateMsPerSecond, 10)
  assert.equal(parseArguments([
    '--trace', '/tmp/native.trace', '--label', 'native-streaming', '--output', '/tmp/report.json',
    '--target-pid', '123',
  ]).targetPid, 123)
  assert.throws(() => parseArguments([
    '--trace', '/tmp/native.trace', '--label', 'native-streaming', '--output', '/tmp/report.json',
    '--target-pid', '0',
  ]), /positive integer/)
  assert.throws(() => parseArguments([
    '--trace', '/tmp/native.trace', '--label', 'native-streaming', '--output', '/tmp/report.json',
    '--steady-start-s', '20', '--steady-end-s', '10',
  ]), /positive and ordered/)
})
