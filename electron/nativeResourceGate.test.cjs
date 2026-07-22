'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  METRIC,
  collectDescendantPIDs,
  compareReports,
  parseFootprintJSON,
  parseProcessTable,
  summarizeSamples,
} = require('../scripts/native-resource-gate.cjs')

test('resource gate follows the complete app process tree without unrelated siblings', () => {
  const rows = parseProcessTable(`
    10 1 /Applications/Kaisola.app/Contents/MacOS/Kaisola
    11 10 /Applications/Kaisola.app/Contents/Frameworks/helper
    12 11 /Applications/Kaisola.app/Contents/Frameworks/WebKit
    20 1 unrelated
    21 20 unrelated-child
  `)
  assert.deepEqual(collectDescendantPIDs(rows, [10]), [10, 11, 12])
})

test('resource gate uses footprints total byte metric and retains process diagnostics', () => {
  const sample = parseFootprintJSON({
    unit: 'byte',
    'bytes per unit': 1,
    'total footprint': 157286400,
    start_time: { date: '2026-07-21T20:00:00-07:00' },
    processes: [
      { name: 'Kaisola', pid: 10, footprint: 100, auxiliary: { phys_footprint: 120, phys_footprint_peak: 150 } },
      { name: 'helper', pid: 11, footprint: 50, auxiliary: { phys_footprint: 60, phys_footprint_peak: 90 } },
    ],
    warnings: [],
  }, [10, 11])
  assert.equal(sample.totalMiB, 150)
  assert.deepEqual(sample.processes.map((row) => row.pid), [10, 11])
  assert.throws(() => parseFootprintJSON({
    unit: 'byte', 'bytes per unit': 1, 'total footprint': 1, processes: [{ pid: 10 }],
  }, [10, 11]), /omitted requested live processes/)
})

test('resource summaries report deterministic median and nearest-rank p95', () => {
  const values = [10, 40, 20, 50, 30].map((totalBytes) => ({ totalBytes }))
  assert.deepEqual(summarizeSamples(values), {
    count: 5,
    medianBytes: 30,
    p95Bytes: 50,
    minimumBytes: 10,
    maximumBytes: 50,
    medianMiB: 0,
    p95MiB: 0,
  })
})

test('resource comparison requires the same workload and metric family', () => {
  const report = (label, medianBytes) => ({
    schemaVersion: 1,
    label,
    workload: 'idle-terminal',
    metric: METRIC,
    summary: { medianBytes },
  })
  const comparison = compareReports(report('native', 200), report('electron', 1_000), 0.5)
  assert.equal(comparison.candidateFraction, 0.2)
  assert.equal(comparison.reductionPercent, 80)
  assert.equal(comparison.pass, true)

  assert.throws(() => compareReports(
    { ...report('native', 200), workload: 'streaming-terminal' },
    report('electron', 1_000),
  ), /different workloads/)
  assert.throws(() => compareReports(
    { ...report('native', 200), metric: { ...METRIC, family: 'summed-rss' } },
    report('electron', 1_000),
  ), /same physical-footprint metric family/)
})
