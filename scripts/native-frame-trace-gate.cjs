#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const SCHEMA_VERSION = 1
const TABLE_SCHEMAS = Object.freeze([
  'hitches',
  'hitches-updates',
  'hitches-renders',
  'potential-hangs',
])

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  const options = {
    steadyStartSeconds: 10,
    steadyEndSeconds: 20,
    maximumHitchRateMsPerSecond: 10,
    maximumPotentialHangs: 0,
    maximumUpdateP95Ms: 8.33,
    maximumRenderP95Ms: 8.33,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const next = () => {
      const value = argv[++index]
      if (value == null) fail(`${argument} requires a value`)
      return value
    }
    if (argument === '--trace') options.trace = path.resolve(next())
    else if (argument === '--label') options.label = next()
    else if (argument === '--target-pid') options.targetPid = Number(next())
    else if (argument === '--steady-start-s') options.steadyStartSeconds = Number(next())
    else if (argument === '--steady-end-s') options.steadyEndSeconds = Number(next())
    else if (argument === '--max-hitch-rate-ms-per-s') options.maximumHitchRateMsPerSecond = Number(next())
    else if (argument === '--max-potential-hangs') options.maximumPotentialHangs = Number(next())
    else if (argument === '--max-update-p95-ms') options.maximumUpdateP95Ms = Number(next())
    else if (argument === '--max-render-p95-ms') options.maximumRenderP95Ms = Number(next())
    else if (argument === '--output') options.output = path.resolve(next())
    else if (argument === '--help' || argument === '-h') options.help = true
    else fail(`unknown argument: ${argument}`)
  }
  if (options.help) return options
  if (!options.trace || !options.output || !options.label) fail('--trace, --label, and --output are required')
  if (options.targetPid != null
      && (!Number.isSafeInteger(options.targetPid) || options.targetPid <= 0)) {
    fail('--target-pid must be a positive integer')
  }
  if (!(options.steadyStartSeconds >= 0)
      || !(options.steadyEndSeconds > options.steadyStartSeconds)) {
    fail('steady-state interval must be positive and ordered')
  }
  for (const [label, value] of [
    ['--max-hitch-rate-ms-per-s', options.maximumHitchRateMsPerSecond],
    ['--max-potential-hangs', options.maximumPotentialHangs],
    ['--max-update-p95-ms', options.maximumUpdateP95Ms],
    ['--max-render-p95-ms', options.maximumRenderP95Ms],
  ]) {
    if (!(value >= 0) || !Number.isFinite(value)) fail(`${label} must be a finite nonnegative number`)
  }
  return options
}

function fieldValue(row, tag, valuesByID) {
  const direct = row.match(new RegExp(`<${tag} id="(\\d+)"[^>]*>(\\d+)<\\/${tag}>`))
  if (direct) return Number(direct[2])
  const reference = row.match(new RegExp(`<${tag} ref="(\\d+)"\\s*/>`))
  return reference ? valuesByID.get(reference[1]) : null
}

function parseTraceQueryRows(xml, expectedSchema = null) {
  const text = String(xml)
  const schema = text.match(/<schema name="([^"]+)"/)?.[1] || null
  if (!schema || (expectedSchema && schema !== expectedSchema)) {
    fail(`trace export schema mismatch: expected ${expectedSchema || 'one schema'}, found ${schema || 'none'}`)
  }
  const valuesByID = new Map()
  for (const match of text.matchAll(/<(start-time|duration) id="(\d+)"[^>]*>(\d+)<\/\1>/g)) {
    valuesByID.set(match[2], Number(match[3]))
  }
  const rows = []
  for (const match of text.matchAll(/<row>([\s\S]*?)<\/row>/g)) {
    const startNanoseconds = fieldValue(match[1], 'start-time', valuesByID)
    const durationNanoseconds = fieldValue(match[1], 'duration', valuesByID)
    if (!Number.isFinite(startNanoseconds) || !Number.isFinite(durationNanoseconds)) {
      fail(`${schema} row has no resolvable start or duration`)
    }
    rows.push({ startNanoseconds, durationNanoseconds })
  }
  return { schema, rows }
}

function percentile(values, fraction) {
  if (!values.length) return 0
  const sorted = [...values].sort((left, right) => left - right)
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)]
}

function summarizeRows(rows, startNanoseconds, endNanoseconds) {
  const selected = rows.flatMap((row) => {
    const eventEnd = row.startNanoseconds + row.durationNanoseconds
    const overlapNanoseconds = Math.max(
      0,
      Math.min(eventEnd, endNanoseconds) - Math.max(row.startNanoseconds, startNanoseconds),
    )
    return overlapNanoseconds > 0
      ? [{
          durationMs: row.durationNanoseconds / 1_000_000,
          overlapMs: overlapNanoseconds / 1_000_000,
          crossesBoundary: row.startNanoseconds < startNanoseconds || eventEnd > endNanoseconds,
        }]
      : []
  })
  const durationsMs = selected.map((row) => row.durationMs)
  const intervalSeconds = (endNanoseconds - startNanoseconds) / 1_000_000_000
  // Hitch ratio is hitch time *inside* the declared interval. Keep the complete
  // event duration for tail diagnosis, but clip the aggregate at both interval
  // boundaries so an event cannot contribute time that was never measured.
  const totalDurationMs = selected.reduce((sum, row) => sum + row.overlapMs, 0)
  return {
    count: durationsMs.length,
    crossBoundaryCount: selected.filter((row) => row.crossesBoundary).length,
    p50Ms: percentile(durationsMs, 0.5),
    p95Ms: percentile(durationsMs, 0.95),
    maximumMs: durationsMs.length ? Math.max(...durationsMs) : 0,
    overOne60HzFrame: durationsMs.filter((duration) => duration > 16.67).length,
    overTwo60HzFrames: durationsMs.filter((duration) => duration > 33.33).length,
    over50Ms: durationsMs.filter((duration) => duration > 50).length,
    totalDurationMs,
    durationRateMsPerSecond: totalDurationMs / intervalSeconds,
  }
}

function gateSummaries(summaries, limits) {
  const checks = {
    eventCoverage: {
      observedHitches: summaries.hitches.count,
      observedUpdateRenderEvents:
        summaries['hitches-updates'].count + summaries['hitches-renders'].count,
      pass: summaries.hitches.count === 0
        || summaries['hitches-updates'].count + summaries['hitches-renders'].count > 0,
    },
    hitchRate: {
      observedMsPerSecond: summaries.hitches.durationRateMsPerSecond,
      maximumMsPerSecond: limits.maximumHitchRateMsPerSecond,
      pass: summaries.hitches.durationRateMsPerSecond <= limits.maximumHitchRateMsPerSecond,
    },
    potentialHangs: {
      observed: summaries['potential-hangs'].count,
      maximum: limits.maximumPotentialHangs,
      pass: summaries['potential-hangs'].count <= limits.maximumPotentialHangs,
    },
    updateP95: {
      observedMs: summaries['hitches-updates'].p95Ms,
      maximumMs: limits.maximumUpdateP95Ms,
      pass: summaries['hitches-updates'].p95Ms <= limits.maximumUpdateP95Ms,
    },
    renderP95: {
      observedMs: summaries['hitches-renders'].p95Ms,
      maximumMs: limits.maximumRenderP95Ms,
      pass: summaries['hitches-renders'].p95Ms <= limits.maximumRenderP95Ms,
    },
  }
  return { checks, pass: Object.values(checks).every((check) => check.pass) }
}

function xctraceExecutable() {
  return execFileSync('/usr/bin/xcrun', ['--find', 'xctrace'], { encoding: 'utf8' }).trim()
}

function exportTrace(trace, outputDirectory) {
  const executable = xctraceExecutable()
  const tocFile = path.join(outputDirectory, 'toc.xml')
  execFileSync(executable, ['export', '--input', trace, '--toc', '--output', tocFile], {
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const toc = fs.readFileSync(tocFile, 'utf8')
  if (!toc.includes('<template-name>Animation Hitches</template-name>')) {
    fail('trace was not recorded with the Animation Hitches template')
  }
  const durationSeconds = Number(toc.match(/<duration>([0-9.]+)<\/duration>/)?.[1])
  if (!Number.isFinite(durationSeconds)) fail('trace contains no recording duration')
  const exports = {}
  for (const schema of TABLE_SCHEMAS) {
    const output = path.join(outputDirectory, `${schema}.xml`)
    execFileSync(executable, [
      'export', '--input', trace,
      '--xpath', `/trace-toc/run[@number='1']/data/table[@schema='${schema}']`,
      '--output', output,
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    exports[schema] = parseTraceQueryRows(fs.readFileSync(output, 'utf8'), schema).rows
  }
  return { durationSeconds, exports }
}

function analyzeTrace(options) {
  const stat = fs.lstatSync(options.trace)
  if (!stat.isDirectory() || stat.isSymbolicLink() || !options.trace.endsWith('.trace')) {
    fail('--trace must be one real .trace directory')
  }
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-frame-trace-'))
  try {
    const { durationSeconds, exports } = exportTrace(options.trace, temporary)
    if (durationSeconds < options.steadyEndSeconds) {
      fail(`trace duration ${durationSeconds}s does not cover the steady-state interval`)
    }
    const startNanoseconds = options.steadyStartSeconds * 1_000_000_000
    const endNanoseconds = options.steadyEndSeconds * 1_000_000_000
    const summaries = Object.fromEntries(TABLE_SCHEMAS.map((schema) => [
      schema,
      summarizeRows(exports[schema], startNanoseconds, endNanoseconds),
    ]))
    const gate = gateSummaries(summaries, options)
    return {
      schemaVersion: SCHEMA_VERSION,
      label: options.label,
      ...(options.targetPid == null ? {} : { targetPid: options.targetPid }),
      trace: options.trace,
      source: 'Xcode Animation Hitches trace exported by xctrace',
      recordingDurationSeconds: durationSeconds,
      steadyIntervalSeconds: {
        start: options.steadyStartSeconds,
        end: options.steadyEndSeconds,
      },
      summaries,
      gate,
      pass: gate.pass,
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
}

function usage() {
  return `Usage: node scripts/native-frame-trace-gate.cjs \\
  --trace /path/recording.trace --label native-streaming \\
  --output /path/report.json [--target-pid PID] \\
  [--steady-start-s 10] [--steady-end-s 20] \\
  [--max-hitch-rate-ms-per-s 10] [--max-potential-hangs 0] \\
  [--max-update-p95-ms 8.33] [--max-render-p95-ms 8.33]`
}

function main(argv) {
  const options = parseArguments(argv)
  if (options.help) return console.log(usage())
  const report = analyzeTrace(options)
  fs.mkdirSync(path.dirname(options.output), { recursive: true })
  fs.writeFileSync(options.output, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o644 })
  console.log(`NATIVE_FRAME_TRACE_GATE=${JSON.stringify(report)}`)
  if (!report.pass) process.exitCode = 1
}

if (require.main === module) {
  try {
    main(process.argv.slice(2))
  } catch (error) {
    console.error(`NATIVE_FRAME_TRACE_GATE=FAIL ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = {
  SCHEMA_VERSION,
  TABLE_SCHEMAS,
  analyzeTrace,
  gateSummaries,
  parseArguments,
  parseTraceQueryRows,
  summarizeRows,
}
