#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { createHash } = require('node:crypto')
const { isDeepStrictEqual } = require('node:util')
const { takeSample } = require('./native-resource-gate.cjs')

const APP_RECEIPT_PREFIX = 'KAISOLA_NATIVE_PDF_PREVIEW_BUDGET_RECEIPT='
const WORKLOAD = 'bounded-pdf-preview-v2'
const SCHEMA_VERSION = 3
const MAX_CAPTURE_BYTES = 64 * 1024
const LAUNCH_ARGUMENTS = ['-ApplePersistenceIgnoreState', 'YES']
const PERSISTENCE_NOTICE = /^(?:\d{4}-\d{2}-\d{2} [^\r\n]+ )?ApplePersistenceIgnoreState: Existing state will not be touched\. New state will be written to [^\r\n]*\/[^\r\n]+\.savedState$/
const CLEAN_GENERATION_EXIT_NOTICE = /^(?:\d{4}-\d{2}-\d{2} [^\r\n]+ )?NSQuitAlwaysKeepsWindows=NO$/
const MALFORMED_PDF_NOTICE = 'CoreGraphics PDF has logged an error. Set environment variable "CG_PDF_VERBOSE" to learn more.'
const MALFORMED_BYTES = Buffer.from('%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\n')

const FIXTURES = Object.freeze([
  Object.freeze({
    id: 'many-page',
    fileName: 'many-page.pdf',
    expectedOutcome: 'rendered',
    expectedPageCount: 96,
    pageWidthPoints: 612,
    pageHeightPoints: 792,
    minimumBytes: 8 * 1024,
    maximumBytes: 2 * 1024 * 1024,
    pagingPageIndexes: Object.freeze([1, 12, 24, 48, 72, 95]),
    measuresSustainedScroll: true,
  }),
  Object.freeze({
    id: 'image-heavy',
    fileName: 'image-heavy.pdf',
    expectedOutcome: 'rendered',
    expectedPageCount: 6,
    pageWidthPoints: 612,
    pageHeightPoints: 792,
    minimumBytes: 8 * 1024 * 1024,
    maximumBytes: 19 * 1024 * 1024,
    pagingPageIndexes: Object.freeze([1, 2, 3, 4, 5]),
    measuresSustainedScroll: true,
    rasterWidthPixels: 896,
    rasterHeightPixels: 896,
  }),
  Object.freeze({
    id: 'malformed',
    fileName: 'malformed.pdf',
    expectedOutcome: 'rejected',
    expectedPageCount: 0,
    pageWidthPoints: 0,
    pageHeightPoints: 0,
    minimumBytes: MALFORMED_BYTES.length,
    maximumBytes: MALFORMED_BYTES.length,
    pagingPageIndexes: Object.freeze([]),
    measuresSustainedScroll: false,
  }),
  Object.freeze({
    id: 'large-page',
    fileName: 'large-page.pdf',
    expectedOutcome: 'rendered',
    expectedPageCount: 1,
    pageWidthPoints: 14_400,
    pageHeightPoints: 14_400,
    minimumBytes: 512,
    maximumBytes: 1024 * 1024,
    pagingPageIndexes: Object.freeze([]),
    measuresSustainedScroll: false,
  }),
])

// Mirrors PDFPreviewBudgetThresholds.standard, which carries the measurements
// these two paging limits come from. Both sides are compared exactly, so a
// change here without the matching Swift change fails as threshold drift.
const THRESHOLDS = Object.freeze({
  maximumFirstVisiblePageLatencyMs: 3_000,
  maximumSubsequentPagingMedianLatencyMs: 250,
  maximumSubsequentPagingLatencyMs: 3_000,
  maximumMalformedRejectionLatencyMs: 1_000,
  scrollMeasurementDurationSeconds: 3,
  maximumScrollP95IntervalMs: 50,
  maximumScrollIntervalMs: 250,
  minimumScrollCallbackCoverage: 0.8,
  maximumPeakPhysicalFootprintBytes: 768 * 1024 * 1024,
})

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
  if (!options.help && (!options.app || !options.output)) fail('--app and --output are required')
  return options
}

function resolveInstalledExecutable(appPath) {
  const requested = path.resolve(String(appPath || ''))
  const components = requested.split(path.sep)
  if (requested.includes(`${path.sep}DerivedData${path.sep}`)
      || requested.includes(`${path.sep}Build${path.sep}Products${path.sep}`)
      || !components.includes('Applications')) {
    fail('--app must be a copied installed app, not an Xcode build product')
  }
  const app = fs.realpathSync(requested)
  if (!app.endsWith('.app') || !fs.statSync(app).isDirectory()) fail('--app must be a real .app directory')
  const executable = fs.realpathSync(path.join(app, 'Contents', 'MacOS', 'Kaisola'))
  if (!executable.startsWith(`${app}${path.sep}`)) fail('app executable escaped its installed bundle')
  fs.accessSync(executable, fs.constants.X_OK)
  const infoPlist = fs.realpathSync(path.join(app, 'Contents', 'Info.plist'))
  return {
    app,
    executable,
    infoPlist,
    executableSHA256: fileSHA256(executable),
    infoPlistSHA256: fileSHA256(infoPlist),
  }
}

function fileSHA256(file) {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

function assertInstalledAppUnchanged(installed) {
  try {
    if (fs.realpathSync(installed.executable) !== installed.executable
        || fs.realpathSync(installed.infoPlist) !== installed.infoPlist
        || fileSHA256(installed.executable) !== installed.executableSHA256
        || fileSHA256(installed.infoPlist) !== installed.infoPlistSHA256) {
      fail('installed app changed during PDF preview budget')
    }
  } catch (error) {
    if (error.message === 'installed app changed during PDF preview budget') throw error
    fail(`installed app changed during PDF preview budget: ${error.message}`)
  }
}

function assertReceiptBundlePath(installed, fixture, observed) {
  let canonical
  try {
    canonical = fs.realpathSync(observed)
  } catch (error) {
    fail(`app receipt bundlePath is not resolvable for ${fixture}: ${error.message}`)
  }
  if (canonical !== installed.app) {
    fail(
      `app receipt bundlePath does not match installed app for ${fixture}: `
      + `observed=${JSON.stringify(observed)} expected=${JSON.stringify(installed.app)}`,
    )
  }
}

function buildFixtureEnvironment(root, fixture, phase, artifact = null) {
  if (phase !== 'generate' && phase !== 'render') fail('PDF preview phase is invalid')
  if (phase === 'render' && (!artifact
      || artifact.fileName !== FIXTURES.find((candidate) => candidate.id === fixture)?.fileName
      || !Number.isSafeInteger(artifact.byteCount) || artifact.byteCount <= 0
      || !/^[0-9a-f]{64}$/u.test(artifact.sha256))) {
    fail('render phase requires an exact prepared fixture artifact')
  }
  const home = path.join(root, `${phase}-home`)
  const environment = {
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
    LANG: 'en_US.UTF-8',
    TMPDIR: process.env.TMPDIR || os.tmpdir(),
    HOME: home,
    CFFIXED_USER_HOME: home,
    KAISOLA_NATIVE_PDF_PREVIEW_BUDGET: '1',
    KAISOLA_NATIVE_PDF_PREVIEW_FIXTURE: fixture,
    KAISOLA_NATIVE_PDF_PREVIEW_ROOT: root,
    KAISOLA_NATIVE_PDF_PREVIEW_PHASE: phase,
  }
  if (phase === 'render') {
    environment.KAISOLA_NATIVE_PDF_PREVIEW_EXPECTED_BYTES = String(artifact.byteCount)
    environment.KAISOLA_NATIVE_PDF_PREVIEW_EXPECTED_SHA256 = artifact.sha256
  }
  return environment
}

function buildFixtureLaunchOptions(root, fixture, phase, artifact = null) {
  return {
    cwd: path.join(root, `${phase}-home`),
    env: buildFixtureEnvironment(root, fixture, phase, artifact),
    stdio: ['ignore', 'pipe', 'pipe'],
  }
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right)
  return sorted[Math.min(sorted.length - 1, Math.ceil((sorted.length - 1) * fraction))]
}

// Mirrors median(of:) in PDFPreviewBudget.swift.
function median(values) {
  if (!values.length) return 0
  const sorted = [...values].sort((left, right) => left - right)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

function exactObject(actual, expected, label) {
  if (!isDeepStrictEqual(actual, expected)) fail(`${label} drifted`)
}

function finiteNumber(value, label, { positive = false } = {}) {
  if (!Number.isFinite(value) || (positive ? value <= 0 : value < 0)) fail(`${label} is invalid`)
  return value
}

function validateDiagnostic(diagnostic, fixture) {
  if (!diagnostic || diagnostic.fixture !== fixture || typeof diagnostic.threshold !== 'string'
      || !diagnostic.threshold || !Number.isFinite(diagnostic.observed) || !Number.isFinite(diagnostic.limit)) {
    fail(`failure diagnostic must name fixture ${fixture} and its threshold`)
  }
  return diagnostic
}

function validateAppStderr(stderr, fixture, phase = 'render') {
  if (phase !== 'generate' && phase !== 'render') fail('PDF preview stderr phase is invalid')
  const lines = stderr.split(/\r?\n/u).filter(Boolean)
  let persistenceCount = 0
  let malformedCount = 0
  let cleanGenerationExitCount = 0
  for (const line of lines) {
    if (PERSISTENCE_NOTICE.test(line)) {
      persistenceCount += 1
    } else if (phase === 'generate' && CLEAN_GENERATION_EXIT_NOTICE.test(line)) {
      cleanGenerationExitCount += 1
    } else if (fixture === 'malformed' && line === MALFORMED_PDF_NOTICE) {
      malformedCount += 1
    } else {
      fail(`app emitted stderr for ${fixture}: ${JSON.stringify(stderr)}`)
    }
  }
  if (persistenceCount > 1 || malformedCount > 1 || cleanGenerationExitCount > 1) {
    fail(`app emitted duplicate stderr diagnostics for ${fixture}`)
  }
}

function validateReceiptEnvelope(receipt, expectedFixture, expectedPID, expectedPhase) {
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) fail('app receipt must be an object')
  if (receipt.schemaVersion !== SCHEMA_VERSION || receipt.workload !== WORKLOAD) {
    fail('app receipt schema or workload drifted')
  }
  if (receipt.phase !== expectedPhase) fail('app receipt phase drifted')
  if (receipt.fixture !== expectedFixture) fail('app receipt fixture drifted')
  if (receipt.appPid !== expectedPID) fail('app receipt pid does not match the launched process')
  if (receipt.build?.optimized !== true) fail('PDF preview budget requires optimized app bytes')
  for (const key of ['bundleIdentifier', 'bundlePath', 'version', 'build']) {
    if (typeof receipt.build?.[key] !== 'string' || !receipt.build[key]) fail(`app build ${key} is missing`)
  }
  const fixture = FIXTURES.find((candidate) => candidate.id === expectedFixture)
  if (!fixture) fail(`unsupported fixture: ${expectedFixture}`)
  exactObject(receipt.specification, fixture, 'PDF fixture specification')
  return fixture
}

function validateGenerationReceipt(receipt, expectedFixture, expectedPID) {
  const fixture = validateReceiptEnvelope(receipt, expectedFixture, expectedPID, 'generate')
  const artifact = receipt.artifact
  if (!artifact || artifact.fileName !== fixture.fileName
      || !Number.isSafeInteger(artifact.byteCount)
      || artifact.byteCount < fixture.minimumBytes
      || artifact.byteCount > fixture.maximumBytes
      || !/^[0-9a-f]{64}$/u.test(artifact.sha256)) {
    fail('generation receipt artifact is invalid')
  }
  return receipt
}

function validateAppReceipt(receipt, expectedFixture, expectedPID) {
  const fixture = validateReceiptEnvelope(receipt, expectedFixture, expectedPID, 'render')
  exactObject(receipt.thresholds, THRESHOLDS, 'PDF preview threshold')

  const result = receipt.result
  if (!result || result.fixture !== expectedFixture || !Array.isArray(result.diagnostics)) {
    fail('app result is missing or names the wrong fixture')
  }
  for (const diagnostic of result.diagnostics) validateDiagnostic(diagnostic, expectedFixture)
  if (result.pass !== (result.diagnostics.length === 0)) fail('app result pass disagrees with diagnostics')
  if (!result.pass) return receipt

  if (!Number.isSafeInteger(result.generatedBytes)
      || result.generatedBytes < fixture.minimumBytes
      || result.generatedBytes > fixture.maximumBytes) {
    fail('generated fixture byte bounds drifted')
  }
  if (result.actualPageCount !== fixture.expectedPageCount) fail('actual page count drifted')
  if (result.outcome !== fixture.expectedOutcome) fail('fixture outcome drifted')
  if (!Array.isArray(result.subsequentPagingLatenciesMs)
      || result.subsequentPagingLatenciesMs.length !== fixture.pagingPageIndexes.length) {
    fail('paging sample count drifted')
  }

  if (fixture.expectedOutcome === 'rejected') {
    finiteNumber(result.malformedRejectionLatencyMs, 'malformed rejection latency')
    if (result.malformedRejectionLatencyMs > THRESHOLDS.maximumMalformedRejectionLatencyMs) {
      fail('false-green malformed rejection latency')
    }
    if (result.firstVisiblePageLatencyMs != null || result.scroll != null) {
      fail('malformed fixture emitted render metrics')
    }
    return receipt
  }

  finiteNumber(result.firstVisiblePageLatencyMs, 'first-visible latency', { positive: true })
  if (result.firstVisiblePageLatencyMs > THRESHOLDS.maximumFirstVisiblePageLatencyMs) {
    fail('false-green first-visible latency')
  }
  for (const latency of result.subsequentPagingLatenciesMs) {
    finiteNumber(latency, 'paging latency')
  }
  if (fixture.pagingPageIndexes.length) {
    const calculatedMedian = median(result.subsequentPagingLatenciesMs)
    const calculatedMaximum = Math.max(...result.subsequentPagingLatenciesMs)
    if (Math.abs(calculatedMedian - result.subsequentPagingMedianLatencyMs) > 0.001) {
      fail('paging median is inconsistent with samples')
    }
    if (Math.abs(calculatedMaximum - result.subsequentPagingMaximumLatencyMs) > 0.001) {
      fail('paging maximum is inconsistent with samples')
    }
    if (calculatedMedian > THRESHOLDS.maximumSubsequentPagingMedianLatencyMs) {
      fail('false-green paging median latency')
    }
    if (calculatedMaximum > THRESHOLDS.maximumSubsequentPagingLatencyMs) {
      fail('false-green paging maximum latency')
    }
  } else if (result.subsequentPagingMedianLatencyMs != null
      || result.subsequentPagingMaximumLatencyMs != null) {
    fail('non-paging fixture emitted paging statistics')
  }

  if (fixture.measuresSustainedScroll) {
    const scroll = result.scroll
    if (!scroll || !Number.isSafeInteger(scroll.callbackCount) || scroll.callbackCount < 2) {
      fail('sustained-scroll callback coverage is missing')
    }
    finiteNumber(scroll.measurementDurationSeconds, 'scroll measurement duration', { positive: true })
    finiteNumber(scroll.nominalFrameDurationMs, 'scroll nominal frame duration', { positive: true })
    finiteNumber(scroll.p95IntervalMs, 'scroll p95 interval', { positive: true })
    finiteNumber(scroll.maximumIntervalMs, 'scroll maximum interval', { positive: true })
    finiteNumber(scroll.callbackCoverage, 'scroll callback coverage')
    if (scroll.measurementDurationSeconds < THRESHOLDS.scrollMeasurementDurationSeconds * 0.95
        || scroll.p95IntervalMs > THRESHOLDS.maximumScrollP95IntervalMs
        || scroll.maximumIntervalMs > THRESHOLDS.maximumScrollIntervalMs
        || scroll.callbackCoverage < THRESHOLDS.minimumScrollCallbackCoverage) {
      fail('false-green sustained-scroll metrics')
    }
  } else if (result.scroll != null) {
    fail('fixture unexpectedly emitted sustained-scroll metrics')
  }
  return receipt
}

function parseAppReceiptLine(line, expectedFixture, expectedPID, expectedPhase = 'render') {
  if (!String(line).startsWith(APP_RECEIPT_PREFIX)) fail('app receipt prefix is invalid')
  const raw = String(line).slice(APP_RECEIPT_PREFIX.length)
  if (raw.startsWith('FAIL ')) fail(raw)
  let receipt
  try {
    receipt = JSON.parse(raw)
  } catch {
    fail('app receipt JSON is invalid')
  }
  if (expectedPhase === 'generate') {
    return validateGenerationReceipt(receipt, expectedFixture, expectedPID)
  }
  if (expectedPhase === 'render') return validateAppReceipt(receipt, expectedFixture, expectedPID)
  fail('expected PDF preview phase is invalid')
}

function assertPreparedFixture(root, fixture, artifact) {
  if (!artifact || artifact.fileName !== fixture.fileName
      || !Number.isSafeInteger(artifact.byteCount)
      || artifact.byteCount < fixture.minimumBytes
      || artifact.byteCount > fixture.maximumBytes
      || !/^[0-9a-f]{64}$/u.test(artifact.sha256)) {
    fail(`prepared fixture metadata is invalid for ${fixture.id}`)
  }
  const canonicalRoot = fs.realpathSync(root)
  const expected = path.join(canonicalRoot, fixture.fileName)
  let metadata
  try {
    metadata = fs.lstatSync(expected)
  } catch (error) {
    fail(`prepared fixture is missing for ${fixture.id}: ${error.message}`)
  }
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    fail(`prepared fixture must be a regular file for ${fixture.id}`)
  }
  if (fs.realpathSync(expected) !== expected) {
    fail(`prepared fixture escaped its private root for ${fixture.id}`)
  }
  if (metadata.size !== artifact.byteCount) {
    fail(`prepared fixture byte count drifted for ${fixture.id}`)
  }
  if (fileSHA256(expected) !== artifact.sha256) {
    fail(`prepared fixture digest drifted for ${fixture.id}`)
  }
  return artifact
}

function mergeMemoryMeasurement(receipt, memory) {
  if (!Number.isSafeInteger(memory?.peakPhysicalFootprintBytes) || memory.peakPhysicalFootprintBytes <= 0
      || !Number.isSafeInteger(memory?.currentPhysicalFootprintBytes) || memory.currentPhysicalFootprintBytes <= 0
      || !Number.isSafeInteger(memory?.measuredPid) || memory.measuredPid <= 0) {
    fail('physical-footprint measurement is invalid')
  }
  if (memory.measuredProcessCount !== 1) fail('physical footprint must measure exactly one render process')
  const diagnostics = [...receipt.result.diagnostics]
  if (memory.peakPhysicalFootprintBytes > THRESHOLDS.maximumPeakPhysicalFootprintBytes) {
    diagnostics.push({
      fixture: receipt.fixture,
      threshold: 'peakPhysicalFootprintBytes.maximum',
      observed: memory.peakPhysicalFootprintBytes,
      limit: THRESHOLDS.maximumPeakPhysicalFootprintBytes,
    })
  }
  return {
    ...receipt,
    memory: {
      metric: {
        family: 'macOS-footprint',
        name: 'single render-process phys_footprint_peak',
        retainedName: 'single render-process phys_footprint',
        source: '/usr/bin/footprint JSON',
        unit: 'byte',
      },
      ...memory,
    },
    diagnostics,
    pass: receipt.result.pass && diagnostics.length === 0,
  }
}

function appendBounded(current, chunk, label) {
  const next = current + String(chunk)
  if (Buffer.byteLength(next) > MAX_CAPTURE_BYTES) fail(`${label} exceeded ${MAX_CAPTURE_BYTES} bytes`)
  return next
}

function waitForAppReceipt(
  child,
  fixture,
  phase = 'render',
  { timeoutMs = 60_000, requireCleanExit = false } = {},
) {
  return new Promise((resolve, reject) => {
    let stdout = ''
    let stderr = ''
    let settled = false
    let parsedReceipt = null
    const finish = (error, receipt) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      child.stdout.off('data', onStdout)
      child.stderr.off('data', onStderr)
      child.off('close', onClose)
      child.off('error', onError)
      if (error) reject(error)
      else resolve({ receipt, stdout, stderr })
    }
    const onStdout = (chunk) => {
      try {
        stdout = appendBounded(stdout, chunk, 'app stdout')
        const lines = stdout.split(/\r?\n/u)
        const receipts = lines.filter((line) => line.startsWith(APP_RECEIPT_PREFIX))
        if (receipts.length > 1) fail('app emitted more than one PDF receipt')
        if (receipts.length === 1 && stdout.endsWith('\n')) {
          const nonempty = lines.filter(Boolean)
          if (nonempty.length !== 1) fail('app emitted stdout outside its PDF receipt')
          parsedReceipt = parseAppReceiptLine(receipts[0], fixture, child.pid, phase)
          if (!requireCleanExit) finish(null, parsedReceipt)
        }
      } catch (error) {
        finish(error)
      }
    }
    const onStderr = (chunk) => {
      try { stderr = appendBounded(stderr, chunk, 'app stderr') } catch (error) { finish(error) }
    }
    const onClose = (code, signal) => {
      if (requireCleanExit && parsedReceipt && code === 0 && signal == null) {
        finish(null, parsedReceipt)
        return
      }
      finish(new Error(
        `app exited before a complete PDF ${phase} receipt: code=${code} signal=${signal || 'none'} stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`,
      ))
    }
    const onError = (error) => finish(new Error(`PDF ${phase} launch failed: ${error.message}`))
    const timer = setTimeout(
      () => finish(new Error(`PDF ${phase} receipt timed out for ${fixture}`)),
      timeoutMs,
    )
    child.stdout.on('data', onStdout)
    child.stderr.on('data', onStderr)
    child.on('close', onClose)
    child.on('error', onError)
  })
}

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

async function terminateExactChild(child) {
  if (!child || child.exitCode != null || child.signalCode != null) return
  child.kill('SIGTERM')
  await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    wait(2_000),
  ])
  if (child.exitCode == null && child.signalCode == null) child.kill('SIGKILL')
}

function memoryFromSample(sample) {
  if (!Array.isArray(sample?.processes) || sample.processes.length !== 1) {
    fail('physical footprint must measure exactly one render process')
  }
  const [process] = sample.processes
  if (!Number.isSafeInteger(process.pid) || process.pid <= 0
      || !Number.isSafeInteger(process.physicalFootprintBytes) || process.physicalFootprintBytes <= 0
      || !Number.isSafeInteger(process.peakPhysicalFootprintBytes) || process.peakPhysicalFootprintBytes <= 0) {
    fail('render-process physical footprint is invalid')
  }
  return {
    peakPhysicalFootprintBytes: Math.max(
      process.peakPhysicalFootprintBytes,
      process.physicalFootprintBytes,
    ),
    currentPhysicalFootprintBytes: process.physicalFootprintBytes,
    measuredProcessCount: 1,
    measuredPid: process.pid,
  }
}

async function runFixture(installed, fixture) {
  assertInstalledAppUnchanged(installed)
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `kaisola-pdf-preview-${fixture.id}-`))
  fs.mkdirSync(path.join(root, 'generate-home'), { mode: 0o700 })
  fs.mkdirSync(path.join(root, 'render-home'), { mode: 0o700 })
  let generationChild = spawn(
    installed.executable,
    LAUNCH_ARGUMENTS,
    buildFixtureLaunchOptions(root, fixture.id, 'generate'),
  )
  let renderChild = null
  try {
    const generation = await waitForAppReceipt(
      generationChild,
      fixture.id,
      'generate',
      { requireCleanExit: true },
    )
    assertReceiptBundlePath(installed, fixture.id, generation.receipt.build.bundlePath)
    validateAppStderr(generation.stderr, fixture.id, 'generate')
    const artifact = assertPreparedFixture(root, fixture, generation.receipt.artifact)
    assertInstalledAppUnchanged(installed)

    renderChild = spawn(
      installed.executable,
      LAUNCH_ARGUMENTS,
      buildFixtureLaunchOptions(root, fixture.id, 'render', artifact),
    )
    const render = await waitForAppReceipt(renderChild, fixture.id, 'render')
    assertReceiptBundlePath(installed, fixture.id, render.receipt.build.bundlePath)
    validateAppStderr(render.stderr, fixture.id, 'render')
    assertPreparedFixture(root, fixture, artifact)
    const sample = takeSample([renderChild.pid], [])
    const memory = memoryFromSample(sample)
    if (memory.measuredPid !== renderChild.pid) {
      fail('footprint measured a process other than the exact render process')
    }
    const result = mergeMemoryMeasurement(render.receipt, memory)
    return {
      ...result,
      processBoundary: {
        generationPid: generationChild.pid,
        generationExitedBeforeRender: true,
        renderPid: renderChild.pid,
        preparedArtifact: artifact,
      },
      brokerFree: !fs.existsSync(path.join(root, 'broker-profile')),
    }
  } finally {
    await terminateExactChild(renderChild)
    await terminateExactChild(generationChild)
    assertInstalledAppUnchanged(installed)
    if ((renderChild == null || renderChild.exitCode != null || renderChild.signalCode != null)
        && (generationChild.exitCode != null || generationChild.signalCode != null)) {
      fs.rmSync(root, { recursive: true, force: true })
    }
  }
}

async function run(options) {
  const installed = resolveInstalledExecutable(options.app)
  const results = []
  for (const fixture of FIXTURES) results.push(await runFixture(installed, fixture))
  const diagnostics = results.flatMap((result) => result.diagnostics)
  const report = {
    schemaVersion: SCHEMA_VERSION,
    workload: WORKLOAD,
    installedApp: installed.app,
    optimized: results.every((result) => result.build.optimized),
    brokerFree: results.every((result) => result.brokerFree),
    thresholds: THRESHOLDS,
    fixtures: results,
    diagnostics,
    pass: results.every((result) => result.pass && result.brokerFree) && diagnostics.length === 0,
  }
  fs.mkdirSync(path.dirname(options.output), { recursive: true })
  fs.writeFileSync(options.output, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o644 })
  return report
}

function usage() {
  return 'Usage: node scripts/native-pdf-preview-budget.cjs --app /installed/Kaisola.app --output /path/receipt.json'
}

async function main(argv) {
  const options = parseArguments(argv)
  if (options.help) return console.log(usage())
  const report = await run(options)
  console.log(`NATIVE_PDF_PREVIEW_BUDGET=${JSON.stringify(report)}`)
  if (!report.pass) process.exitCode = 1
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`NATIVE_PDF_PREVIEW_BUDGET=FAIL ${error.message}`)
    process.exitCode = 1
  })
}

module.exports = {
  APP_RECEIPT_PREFIX,
  FIXTURES,
  LAUNCH_ARGUMENTS,
  WORKLOAD,
  THRESHOLDS,
  assertPreparedFixture,
  assertInstalledAppUnchanged,
  assertReceiptBundlePath,
  buildFixtureEnvironment,
  buildFixtureLaunchOptions,
  memoryFromSample,
  mergeMemoryMeasurement,
  parseAppReceiptLine,
  parseArguments,
  resolveInstalledExecutable,
  run,
  validateAppReceipt,
  validateGenerationReceipt,
  validateAppStderr,
  waitForAppReceipt,
}
