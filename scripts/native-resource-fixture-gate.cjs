#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { gateReportByP95, measure } = require('./native-resource-gate.cjs')

const RECEIPT_PREFIX = 'KAISOLA_NATIVE_RESOURCE_FIXTURE_READY='
const EXPECTED_BYTES = 64 * 1024 * 1024
const EXPECTED_PAGE_BYTES = 1024 * 1024
const EXPECTED_PAGES = EXPECTED_BYTES / EXPECTED_PAGE_BYTES
const EXPECTED_MUTABLE_TAIL_BYTES = 16 * 1024
const EXPECTED_SCROLLBACK_LINES = 100_000
const MAX_CAPTURE_BYTES = 64 * 1024
// AppKit can stop before applicationDidFinishLaunching to show its crash-state
// restore prompt. Fixtures have private state and must be unattended, so opt
// out explicitly. AppKit writes one deterministic diagnostic for this flag;
// validate that exact line below while continuing to reject every other byte.
const FIXTURE_LAUNCH_ARGUMENTS = ['-ApplePersistenceIgnoreState', 'YES']
const PERSISTENCE_NOTICE = /^(?:\d{4}-\d{2}-\d{2} [^\r\n]+ )?ApplePersistenceIgnoreState: Existing state will not be touched\. New state will be written to [^\r\n]*\/com\.kaisola\.mac\.savedState\r?\n$/

function positiveInteger(value, label) {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number <= 0) throw new Error(`${label} must be a positive integer`)
  return number
}

function parseArguments(argv) {
  const options = { samples: 7, intervalMs: 750, warmMs: 15_000 }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const next = () => {
      const value = argv[++index]
      if (value == null) throw new Error(`${argument} requires a value`)
      return value
    }
    if (argument === '--app') options.app = path.resolve(next())
    else if (argument === '--output') options.output = path.resolve(next())
    else if (argument === '--samples') {
      options.samples = positiveInteger(next(), argument)
      if (options.samples < 7) throw new Error('--samples must be at least 7')
    }
    else if (argument === '--interval-ms') options.intervalMs = positiveInteger(next(), argument)
    else if (argument === '--warm-ms') {
      options.warmMs = positiveInteger(next(), argument)
      if (options.warmMs < 15_000) throw new Error('--warm-ms must be at least 15000')
    }
    else if (argument === '--help' || argument === '-h') options.help = true
    else throw new Error(`unknown argument: ${argument}`)
  }
  return options
}

function validateReceipt(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('resource receipt must be an object')
  const expected = {
    schemaVersion: 1,
    ok: true,
    expectedBytes: EXPECTED_BYTES,
    actualBytes: EXPECTED_BYTES,
    pages: EXPECTED_PAGES,
    pageLimitBytes: EXPECTED_PAGE_BYTES,
    mutableTailLimitBytes: EXPECTED_MUTABLE_TAIL_BYTES,
    scrollbackLines: EXPECTED_SCROLLBACK_LINES,
    renderedEndOffset: EXPECTED_BYTES,
  }
  for (const [key, value] of Object.entries(expected)) {
    if (payload[key] !== value) throw new Error(`resource receipt ${key} must equal ${value}`)
  }
  return payload
}

function parseReceiptLine(line) {
  if (!String(line).startsWith(RECEIPT_PREFIX)) throw new Error('resource receipt prefix is invalid')
  let payload
  try {
    payload = JSON.parse(String(line).slice(RECEIPT_PREFIX.length))
  } catch {
    throw new Error('resource receipt JSON is invalid')
  }
  return validateReceipt(payload)
}

function validateReadinessOutput(readiness) {
  const lines = String(readiness.stdout).split(/\r?\n/)
  while (lines.at(-1) === '') lines.pop()
  if (lines.length !== 1 || !lines[0].startsWith(RECEIPT_PREFIX)) {
    throw new Error('fixture stdout before readiness must contain exactly one receipt line')
  }
  const stderr = String(readiness.stderr)
  if (stderr.length > 0 && !PERSISTENCE_NOTICE.test(stderr)) {
    throw new Error(`fixture emitted stderr before readiness: ${JSON.stringify(readiness.stderr)}`)
  }
  return readiness
}

function createBoundedCapture(label, maximumBytes = MAX_CAPTURE_BYTES) {
  let value = ''
  let error = null
  return {
    append(chunk) {
      if (error) return
      try {
        const next = value + String(chunk)
        if (Buffer.byteLength(next) > maximumBytes) throw new Error(`${label} exceeded ${maximumBytes} bytes`)
        value = next
      } catch (captureError) {
        error = captureError
      }
    },
    assertEmpty(phase) {
      if (error) throw error
      if (value.length > 0) throw new Error(`fixture emitted ${label} ${phase}: ${JSON.stringify(value)}`)
    },
  }
}

function fixtureEnvironment() {
  return {
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
    LANG: 'en_US.UTF-8',
    TMPDIR: process.env.TMPDIR || os.tmpdir(),
    KAISOLA_NATIVE_VISUAL_FIXTURE: '1',
    KAISOLA_NATIVE_VISUAL_SURFACE: 'terminal',
    KAISOLA_NATIVE_RESOURCE_SCROLLBACK_BYTES: String(EXPECTED_BYTES),
    KAISOLA_NATIVE_RESOURCE_SCROLLBACK_LINES: String(EXPECTED_SCROLLBACK_LINES),
    KAISOLA_NATIVE_RESOURCE_RECEIPT: '1',
  }
}

function resolveExecutable(appPath) {
  if (!appPath) throw new Error('--app is required')
  const app = fs.realpathSync(appPath)
  if (!app.endsWith('.app') || !fs.statSync(app).isDirectory()) throw new Error('--app must be a real .app directory')
  const executable = fs.realpathSync(path.join(app, 'Contents', 'MacOS', 'Kaisola'))
  if (!executable.startsWith(`${app}${path.sep}`)) throw new Error('fixture executable must remain inside the app bundle')
  fs.accessSync(executable, fs.constants.X_OK)
  return executable
}

function waitForReceipt(child, timeoutMs = 60_000) {
  return new Promise((resolve, reject) => {
    let stdout = ''
    let stderr = ''
    let settled = false
    const finish = (error, receipt) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      child.stdout.off('data', onStdout)
      child.stderr.off('data', onStderr)
      child.off('exit', onExit)
      if (error) reject(error)
      else resolve({ receipt, stdout, stderr })
    }
    const cap = (current, chunk, label) => {
      const next = current + String(chunk)
      if (Buffer.byteLength(next) > MAX_CAPTURE_BYTES) throw new Error(`${label} exceeded ${MAX_CAPTURE_BYTES} bytes`)
      return next
    }
    const onStdout = (chunk) => {
      try {
        stdout = cap(stdout, chunk, 'fixture stdout')
        for (const line of stdout.split(/\r?\n/)) {
          if (line.startsWith(RECEIPT_PREFIX)) return finish(null, parseReceiptLine(line))
        }
      } catch (error) {
        finish(error)
      }
    }
    const onStderr = (chunk) => {
      try { stderr = cap(stderr, chunk, 'fixture stderr') } catch (error) { finish(error) }
    }
    const capturedOutput = () => ` stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`
    const onExit = (code, signal) => finish(new Error(
      `fixture exited before readiness: code=${code} signal=${signal || 'none'}${capturedOutput()}`,
    ))
    const timer = setTimeout(
      () => finish(new Error(`fixture readiness timed out:${capturedOutput()}`)),
      timeoutMs,
    )
    child.stdout.on('data', onStdout)
    child.stderr.on('data', onStderr)
    child.on('exit', onExit)
  })
}

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

async function terminateFixture(child) {
  if (!child || child.exitCode != null || child.signalCode != null) return
  child.kill('SIGTERM')
  await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    wait(2_000),
  ])
  if (child.exitCode == null && child.signalCode == null) child.kill('SIGKILL')
}

async function run(options) {
  const executable = resolveExecutable(options.app)
  const child = spawn(executable, FIXTURE_LAUNCH_ARGUMENTS, {
    env: fixtureEnvironment(),
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  try {
    const readiness = validateReadinessOutput(await waitForReceipt(child))
    const lateStdout = createBoundedCapture('stdout')
    const lateStderr = createBoundedCapture('stderr')
    const onLateStdout = (chunk) => lateStdout.append(chunk)
    const onLateStderr = (chunk) => lateStderr.append(chunk)
    child.stdout.on('data', onLateStdout)
    child.stderr.on('data', onLateStderr)
    try {
      await wait(options.warmMs)
      const report = gateReportByP95(await measure({
        label: 'native-release-page-native',
        workload: 'broker-free-terminal-64mib',
        roots: [child.pid],
        includes: [],
        infoFiles: [],
        samples: options.samples,
        intervalMs: options.intervalMs,
      }), 512)
      lateStdout.assertEmpty('after readiness')
      lateStderr.assertEmpty('after readiness')
      const result = { receipt: readiness.receipt, report, pass: report.pass }
      if (options.output) fs.writeFileSync(options.output, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o644 })
      return result
    } finally {
      child.stdout.off('data', onLateStdout)
      child.stderr.off('data', onLateStderr)
    }
  } finally {
    await terminateFixture(child)
  }
}

function usage() {
  return `Usage: node scripts/native-resource-fixture-gate.cjs --app /path/to/Kaisola.app \\
  [--samples 7] [--interval-ms 750] [--warm-ms 15000] [--output report.json]`
}

async function main(argv) {
  const options = parseArguments(argv)
  if (options.help) return console.log(usage())
  const result = await run(options)
  console.log(`NATIVE_RESOURCE_FIXTURE_GATE=${JSON.stringify(result)}`)
  if (!result.pass) process.exitCode = 1
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`NATIVE_RESOURCE_FIXTURE_GATE=FAIL ${error.message}`)
    process.exitCode = 1
  })
}

module.exports = {
  EXPECTED_BYTES,
  EXPECTED_MUTABLE_TAIL_BYTES,
  EXPECTED_PAGES,
  EXPECTED_PAGE_BYTES,
  EXPECTED_SCROLLBACK_LINES,
  FIXTURE_LAUNCH_ARGUMENTS,
  RECEIPT_PREFIX,
  createBoundedCapture,
  fixtureEnvironment,
  parseArguments,
  parseReceiptLine,
  resolveExecutable,
  run,
  validateReceipt,
  validateReadinessOutput,
  waitForReceipt,
}
