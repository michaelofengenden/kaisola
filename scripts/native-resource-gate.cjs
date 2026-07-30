#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const SCHEMA_VERSION = 1
const METRIC = Object.freeze({
  family: 'macOS-footprint',
  name: 'total footprint',
  source: '/usr/bin/footprint JSON',
  unit: 'byte',
})

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
const roundMiB = (bytes) => Math.round((bytes / 1024 / 1024) * 10) / 10

function percentile(values, fraction) {
  if (!Array.isArray(values) || values.length === 0) throw new Error('cannot summarize an empty sample set')
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)]
}

function summarizeSamples(samples) {
  const values = samples.map((sample) => sample.totalBytes)
  return {
    count: values.length,
    medianBytes: percentile(values, 0.5),
    p95Bytes: percentile(values, 0.95),
    minimumBytes: Math.min(...values),
    maximumBytes: Math.max(...values),
    medianMiB: roundMiB(percentile(values, 0.5)),
    p95MiB: roundMiB(percentile(values, 0.95)),
  }
}

function parseProcessTable(text) {
  return String(text).split('\n').flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+?)\s*$/)
    if (!match) return []
    return [{ pid: Number(match[1]), parentPID: Number(match[2]), command: match[3] }]
  })
}

function collectDescendantPIDs(rows, roots) {
  const result = new Set(roots)
  let changed = true
  while (changed) {
    changed = false
    for (const row of rows) {
      if (!result.has(row.pid) && result.has(row.parentPID)) {
        result.add(row.pid)
        changed = true
      }
    }
  }
  return [...result].sort((a, b) => a - b)
}

function parseFootprintJSON(raw, expectedPIDs = []) {
  const payload = typeof raw === 'string' || Buffer.isBuffer(raw) ? JSON.parse(raw) : raw
  if (payload?.unit !== 'byte' || payload?.['bytes per unit'] !== 1) {
    throw new Error('footprint returned an unsupported unit')
  }
  if (!Number.isSafeInteger(payload?.['total footprint']) || payload['total footprint'] < 0) {
    throw new Error('footprint returned no total physical-footprint metric')
  }
  const processes = Array.isArray(payload.processes) ? payload.processes.map((process) => ({
    pid: Number(process.pid),
    name: String(process.name || ''),
    footprintBytes: Number(process.footprint || 0),
    physicalFootprintBytes: Number(process.auxiliary?.phys_footprint || process.footprint || 0),
    peakPhysicalFootprintBytes: Number(process.auxiliary?.phys_footprint_peak || 0),
    translated: Boolean(process.translated),
  })).filter((process) => Number.isInteger(process.pid) && process.pid > 0) : []
  const measured = new Set(processes.map((process) => process.pid))
  const missingPIDs = expectedPIDs.filter((pid) => !measured.has(pid))
  if (missingPIDs.length > 0) {
    throw new Error(`footprint omitted requested live processes: ${missingPIDs.join(', ')}`)
  }
  return {
    capturedAt: payload.start_time?.date || new Date().toISOString(),
    totalBytes: payload['total footprint'],
    totalMiB: roundMiB(payload['total footprint']),
    processes: processes.sort((a, b) => b.physicalFootprintBytes - a.physicalFootprintBytes || a.pid - b.pid),
    warnings: Array.isArray(payload.warnings) ? payload.warnings.map(String) : [],
  }
}

function compareReports(candidate, baseline, maximumFraction = null) {
  for (const report of [candidate, baseline]) {
    if (report?.schemaVersion !== SCHEMA_VERSION || report?.metric?.family !== METRIC.family || report?.metric?.name !== METRIC.name) {
      throw new Error('reports do not use the same physical-footprint metric family')
    }
  }
  if (candidate.workload !== baseline.workload) throw new Error('reports measure different workloads')
  if (candidate.fixture || baseline.fixture) {
    if (!candidate.fixture || !baseline.fixture
        || !Number.isSafeInteger(candidate.fixture.warmupMs)
        || candidate.fixture.warmupMs !== baseline.fixture.warmupMs) {
      throw new Error('paired reports use different warm-up periods')
    }
    if (!Number.isSafeInteger(candidate.summary?.count)
        || !Number.isSafeInteger(baseline.summary?.count)
        || candidate.summary.count < 11
        || baseline.summary.count < 11
        || candidate.summary.count !== baseline.summary.count) {
      throw new Error('paired reports use weak or different sample counts')
    }
    if (!Number.isSafeInteger(candidate.sampleIntervalMs)
        || !Number.isSafeInteger(baseline.sampleIntervalMs)
        || candidate.sampleIntervalMs !== baseline.sampleIntervalMs) {
      throw new Error('paired reports use different sample intervals')
    }
  }
  const candidateMedianBytes = candidate.summary.medianBytes
  const baselineMedianBytes = baseline.summary.medianBytes
  const candidateP95Bytes = candidate.summary.p95Bytes
  const baselineP95Bytes = baseline.summary.p95Bytes
  if (!(candidateMedianBytes >= 0) || !(baselineMedianBytes > 0)
      || !(candidateP95Bytes >= 0) || !(baselineP95Bytes > 0)) {
    throw new Error('reports contain invalid median or p95 values')
  }
  const medianFraction = candidateMedianBytes / baselineMedianBytes
  const p95Fraction = candidateP95Bytes / baselineP95Bytes
  const result = {
    workload: candidate.workload,
    metric: METRIC,
    candidate: {
      label: candidate.label,
      medianBytes: candidateMedianBytes,
      medianMiB: roundMiB(candidateMedianBytes),
      p95Bytes: candidateP95Bytes,
      p95MiB: roundMiB(candidateP95Bytes),
    },
    baseline: {
      label: baseline.label,
      medianBytes: baselineMedianBytes,
      medianMiB: roundMiB(baselineMedianBytes),
      p95Bytes: baselineP95Bytes,
      p95MiB: roundMiB(baselineP95Bytes),
    },
    deltaBytes: candidateMedianBytes - baselineMedianBytes,
    deltaMiB: roundMiB(candidateMedianBytes - baselineMedianBytes),
    p95DeltaBytes: candidateP95Bytes - baselineP95Bytes,
    p95DeltaMiB: roundMiB(candidateP95Bytes - baselineP95Bytes),
    candidateFraction: Math.round(medianFraction * 1_000) / 1_000,
    p95CandidateFraction: Math.round(p95Fraction * 1_000) / 1_000,
    reductionPercent: Math.round((1 - medianFraction) * 1_000) / 10,
    p95ReductionPercent: Math.round((1 - p95Fraction) * 1_000) / 10,
  }
  if (maximumFraction != null) {
    result.relativeGate = {
      statistics: ['median', 'p95'],
      maximumFraction,
      pass: medianFraction <= maximumFraction && p95Fraction <= maximumFraction,
    }
    result.pass = result.relativeGate.pass
  }
  return result
}

function gateReportByP95(report, maximumMiB) {
  if (report?.schemaVersion !== SCHEMA_VERSION || report?.metric?.family !== METRIC.family || report?.metric?.name !== METRIC.name) {
    throw new Error('report does not use the physical-footprint metric family')
  }
  if (!(maximumMiB > 0) || !Number.isFinite(maximumMiB)) {
    throw new Error('maximum p95 MiB must be a positive number')
  }
  const observedBytes = report?.summary?.p95Bytes
  if (!Number.isSafeInteger(observedBytes) || observedBytes < 0) {
    throw new Error('report contains no valid p95 physical-footprint value')
  }
  const maximumBytes = Math.floor(maximumMiB * 1024 * 1024)
  const pass = observedBytes <= maximumBytes
  return {
    ...report,
    absoluteGate: {
      statistic: 'p95',
      observedBytes,
      observedMiB: roundMiB(observedBytes),
      maximumBytes,
      maximumMiB: roundMiB(maximumBytes),
      pass,
    },
    pass,
  }
}

function positiveInteger(value, name) {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number <= 0) throw new Error(`${name} must be a positive integer`)
  return number
}

function parseArguments(argv) {
  const options = { roots: [], includes: [], infoFiles: [], samples: 5, intervalMs: 1_000 }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const next = () => {
      const value = argv[++index]
      if (value == null) throw new Error(`${argument} requires a value`)
      return value
    }
    if (argument === '--label') options.label = next()
    else if (argument === '--workload') options.workload = next()
    else if (argument === '--root-pid') options.roots.push(positiveInteger(next(), argument))
    else if (argument === '--include-pid') options.includes.push(positiveInteger(next(), argument))
    else if (argument === '--include-info') options.infoFiles.push(path.resolve(next()))
    else if (argument === '--samples') options.samples = positiveInteger(next(), argument)
    else if (argument === '--interval-ms') options.intervalMs = positiveInteger(next(), argument)
    else if (argument === '--output') options.output = path.resolve(next())
    else if (argument === '--compare-candidate') options.compareCandidate = path.resolve(next())
    else if (argument === '--compare-baseline') options.compareBaseline = path.resolve(next())
    else if (argument === '--max-fraction') options.maximumFraction = Number(next())
    else if (argument === '--max-p95-mib') options.maximumP95MiB = Number(next())
    else if (argument === '--help' || argument === '-h') options.help = true
    else throw new Error(`unknown argument: ${argument}`)
  }
  return options
}

function readBrokerPID(file) {
  const payload = JSON.parse(fs.readFileSync(file, 'utf8'))
  return positiveInteger(payload.pid, `broker pid in ${file}`)
}

function processTable() {
  return parseProcessTable(execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8' }))
}

function pidIsAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

function takeSample(rootPIDs, includePIDs) {
  const rows = processTable()
  const aliveRoots = rootPIDs.filter(pidIsAlive)
  if (aliveRoots.length !== rootPIDs.length) {
    throw new Error(`root process exited before measurement: ${rootPIDs.filter((pid) => !aliveRoots.includes(pid)).join(', ')}`)
  }
  const descendants = collectDescendantPIDs(rows, aliveRoots)
  const explicit = includePIDs.filter(pidIsAlive)
  if (explicit.length !== includePIDs.length) {
    throw new Error(`explicit helper exited before measurement: ${includePIDs.filter((pid) => !explicit.includes(pid)).join(', ')}`)
  }
  const pids = [...new Set([...descendants, ...explicit])].sort((a, b) => a - b)
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-footprint-'))
  const output = path.join(temporary, 'sample.json')
  try {
    execFileSync('/usr/bin/footprint', ['-j', output, ...pids.map(String)], { stdio: ['ignore', 'pipe', 'pipe'] })
    // Roots and explicitly counted helpers define the measurement and must
    // survive the capture. Descendants may be intentionally ephemeral (the
    // streaming workload creates an 80 ms `sleep` each loop); requiring every
    // process-table snapshot PID to outlive footprint makes a valid sustained
    // workload nondeterministically fail. Keep those PIDs in the request and
    // receipt, but distinguish normal process churn from a missing app/broker.
    const sample = parseFootprintJSON(
      fs.readFileSync(output),
      [...new Set([...aliveRoots, ...explicit])],
    )
    const measuredPIDs = new Set(sample.processes.map((process) => process.pid))
    return {
      ...sample,
      requestedPIDs: pids,
      exitedDescendantPIDs: pids.filter((pid) => !measuredPIDs.has(pid)),
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

async function measure(options) {
  if (!options.label || !options.workload || options.roots.length === 0) {
    throw new Error('measurement requires --label, --workload, and at least one --root-pid')
  }
  const includePIDs = [...new Set([
    ...options.includes,
    ...options.infoFiles.map(readBrokerPID),
  ])]
  const samples = []
  for (let index = 0; index < options.samples; index += 1) {
    samples.push(takeSample(options.roots, includePIDs))
    if (index + 1 < options.samples) await wait(options.intervalMs)
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    label: options.label,
    workload: options.workload,
    metric: METRIC,
    roots: options.roots,
    explicitHelpers: includePIDs,
    sampleIntervalMs: options.intervalMs,
    samples,
    summary: summarizeSamples(samples),
  }
}

function usage() {
  return `Usage:
  node scripts/native-resource-gate.cjs --label native --workload idle-terminal \\
    --root-pid PID [--include-pid PID | --include-info broker.json] \\
    [--samples 5] [--interval-ms 1000] [--max-p95-mib MIB] \\
    [--output report.json]

  node scripts/native-resource-gate.cjs --compare-candidate native.json \\
    --compare-baseline electron.json [--max-fraction 0.5]`
}

async function main(argv) {
  const options = parseArguments(argv)
  if (options.help) {
    console.log(usage())
    return
  }
  let result
  if (options.compareCandidate || options.compareBaseline) {
    if (!options.compareCandidate || !options.compareBaseline) throw new Error('comparison requires both report paths')
    if (options.maximumP95MiB != null) throw new Error('--max-p95-mib applies only to a measurement')
    if (options.maximumFraction != null && (!(options.maximumFraction > 0) || !Number.isFinite(options.maximumFraction))) {
      throw new Error('--max-fraction must be a positive number')
    }
    result = compareReports(
      JSON.parse(fs.readFileSync(options.compareCandidate, 'utf8')),
      JSON.parse(fs.readFileSync(options.compareBaseline, 'utf8')),
      options.maximumFraction,
    )
  } else {
    result = await measure(options)
    if (options.maximumP95MiB != null) {
      result = gateReportByP95(result, options.maximumP95MiB)
    }
  }
  if (options.output) fs.writeFileSync(options.output, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o644 })
  console.log(`NATIVE_RESOURCE_GATE=${JSON.stringify(result)}`)
  if (result.pass === false) process.exitCode = 1
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`NATIVE_RESOURCE_GATE=FAIL ${error.message}`)
    process.exitCode = 1
  })
}

module.exports = {
  METRIC,
  SCHEMA_VERSION,
  collectDescendantPIDs,
  compareReports,
  gateReportByP95,
  measure,
  parseArguments,
  parseFootprintJSON,
  parseProcessTable,
  summarizeSamples,
  takeSample,
}
