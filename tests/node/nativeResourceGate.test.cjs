'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  METRIC,
  collectDescendantPIDs,
  compareReports,
  gateReportByP95,
  parseFootprintJSON,
  parseProcessTable,
  summarizeSamples,
} = require('../../scripts/native-resource-gate.cjs')

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

test('resource samples require roots and explicit helpers but tolerate exited transient descendants', () => {
  assert.throws(() => parseFootprintJSON({
    unit: 'byte',
    'bytes per unit': 1,
    'total footprint': 1,
    processes: [{ pid: 11, name: 'root', footprint: 1 }],
  }, [11, 22]), /omitted requested live processes: 22/)
  assert.doesNotThrow(() => parseFootprintJSON({
    unit: 'byte',
    'bytes per unit': 1,
    'total footprint': 1,
    processes: [{ pid: 11, name: 'root', footprint: 1 }],
  }, [11]))
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

test('resource comparison gates both median and p95 and requires a matched protocol', () => {
  const report = (label, medianBytes, p95Bytes = medianBytes) => ({
    schemaVersion: 1,
    label,
    workload: 'idle-terminal',
    metric: METRIC,
    summary: { medianBytes, p95Bytes },
  })
  const comparison = compareReports(report('native', 200, 400), report('electron', 1_000, 1_000), 0.5)
  assert.equal(comparison.candidateFraction, 0.2)
  assert.equal(comparison.p95CandidateFraction, 0.4)
  assert.equal(comparison.reductionPercent, 80)
  assert.equal(comparison.p95ReductionPercent, 60)
  assert.deepEqual(comparison.relativeGate.statistics, ['median', 'p95'])
  assert.equal(comparison.pass, true)

  assert.equal(
    compareReports(report('native', 200, 600), report('electron', 1_000, 1_000), 0.5).pass,
    false,
  )

  assert.throws(() => compareReports(
    { ...report('native', 200), workload: 'streaming-terminal' },
    report('electron', 1_000),
  ), /different workloads/)
  assert.throws(() => compareReports(
    { ...report('native', 200), metric: { ...METRIC, family: 'summed-rss' } },
    report('electron', 1_000),
  ), /same physical-footprint metric family/)
  assert.throws(() => compareReports(
    { ...report('native', 200), fixture: { warmupMs: 60_000 } },
    { ...report('electron', 1_000), fixture: { warmupMs: 15_000 } },
  ), /different warm-up periods/)
  const paired = (label, count = 11, interval = 1_000) => ({
    ...report(label, label === 'native' ? 200 : 1_000),
    sampleIntervalMs: interval,
    summary: {
      ...report(label, label === 'native' ? 200 : 1_000).summary,
      count,
    },
    fixture: { warmupMs: 60_000 },
  })
  assert.doesNotThrow(() => compareReports(paired('native'), paired('electron')))
  assert.throws(
    () => compareReports(paired('native', 10), paired('electron', 10)),
    /weak or different sample counts/,
  )
  assert.throws(
    () => compareReports(paired('native', 11), paired('electron', 12)),
    /weak or different sample counts/,
  )
  assert.throws(
    () => compareReports(paired('native'), paired('electron', 11, 750)),
    /different sample intervals/,
  )
})

test('absolute resource gate applies a p95 physical-footprint ceiling', () => {
  const report = {
    schemaVersion: 1,
    label: 'native-release',
    workload: 'broker-free-terminal-64mib',
    metric: METRIC,
    summary: { p95Bytes: 454_477_072 },
  }

  const passing = gateReportByP95(report, 512)
  assert.equal(passing.absoluteGate.statistic, 'p95')
  assert.equal(passing.absoluteGate.observedMiB, 433.4)
  assert.equal(passing.absoluteGate.maximumBytes, 512 * 1024 * 1024)
  assert.equal(passing.pass, true)

  const failing = gateReportByP95(report, 400)
  assert.equal(failing.pass, false)
  assert.throws(() => gateReportByP95({ ...report, metric: { ...METRIC, family: 'rss' } }, 512), /metric family/)
  assert.throws(() => gateReportByP95(report, 0), /positive number/)
})
