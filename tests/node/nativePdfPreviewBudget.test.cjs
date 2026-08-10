'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const {
  APP_RECEIPT_PREFIX,
  FIXTURES,
  THRESHOLDS,
  assertInstalledAppUnchanged,
  assertReceiptBundlePath,
  buildFixtureEnvironment,
  buildFixtureLaunchOptions,
  mergeMemoryMeasurement,
  parseArguments,
  parseAppReceiptLine,
  resolveInstalledExecutable,
  validateAppReceipt,
  validateAppStderr,
} = require('../../scripts/native-pdf-preview-budget.cjs')

function workflowJobSource(source, job) {
  const lines = source.split('\n')
  const start = lines.findIndex((line) => line === `  ${job}:`)
  assert.notEqual(start, -1, `swift-contracts must define the ${job} job`)

  let end = lines.length
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^  [a-zA-Z0-9_-]+:\s*(?:#.*)?$/u.test(lines[index])) {
      end = index
      break
    }
  }
  return lines.slice(start, end).join('\n')
}

function passingReceipt(fixture = FIXTURES[0]) {
  const pagingLatencies = fixture.pagingPageIndexes.map((_, index) => 50 + index)
  const scroll = fixture.measuresSustainedScroll ? {
    callbackCount: 170,
    measurementDurationSeconds: 3,
    nominalFrameDurationMs: 16.67,
    p95IntervalMs: 20,
    maximumIntervalMs: 60,
    callbackCoverage: 0.96,
  } : null
  return {
    schemaVersion: 1,
    workload: 'bounded-pdf-preview-v1',
    fixture: fixture.id,
    appPid: 123,
    build: {
      optimized: true,
      bundleIdentifier: 'com.kaisola.mac.pdf-budget-tests',
      bundlePath: '/tmp/Applications/Kaisola PDF Budget QA.app',
      version: '0.1.114',
      build: '1',
    },
    thresholds: THRESHOLDS,
    specification: fixture,
    result: {
      fixture: fixture.id,
      generatedBytes: fixture.minimumBytes === fixture.maximumBytes
        ? fixture.minimumBytes
        : Math.max(fixture.minimumBytes, 64_000),
      actualPageCount: fixture.expectedPageCount,
      outcome: fixture.expectedOutcome,
      firstVisiblePageLatencyMs: fixture.expectedOutcome === 'rendered' ? 200 : null,
      subsequentPagingLatenciesMs: pagingLatencies,
      subsequentPagingP95LatencyMs: pagingLatencies.at(-1) ?? null,
      malformedRejectionLatencyMs: fixture.expectedOutcome === 'rejected' ? 20 : null,
      scroll,
      diagnostics: [],
      pass: true,
    },
  }
}

test('fixture catalog and thresholds are exact, deterministic, and bounded', () => {
  assert.deepEqual(FIXTURES.map((fixture) => fixture.id), [
    'many-page', 'image-heavy', 'malformed', 'large-page',
  ])
  assert.deepEqual(FIXTURES.map((fixture) => fixture.expectedPageCount), [96, 6, 0, 1])
  assert.equal(FIXTURES.find((fixture) => fixture.id === 'image-heavy').rasterWidthPixels, 896)
  assert.equal(FIXTURES.find((fixture) => fixture.id === 'large-page').pageWidthPoints, 14_400)
  assert.deepEqual(THRESHOLDS, {
    maximumFirstVisiblePageLatencyMs: 3_000,
    maximumSubsequentPagingP95LatencyMs: 750,
    maximumMalformedRejectionLatencyMs: 1_000,
    scrollMeasurementDurationSeconds: 3,
    maximumScrollP95IntervalMs: 50,
    maximumScrollIntervalMs: 250,
    minimumScrollCallbackCoverage: 0.8,
    maximumPeakPhysicalFootprintBytes: 768 * 1024 * 1024,
  })
  assert.ok(FIXTURES.every((fixture) => fixture.maximumBytes <= 20 * 1024 * 1024))
})

test('optimized PDF qualification runs in a fresh simulator-free macOS job', () => {
  const workflow = fs.readFileSync(path.resolve(
    __dirname,
    '../../.github/workflows/swift-contracts.yml',
  ), 'utf8')
  const verify = workflowJobSource(workflow, 'verify')
  const qualification = workflowJobSource(workflow, 'optimized-macos-pdf')

  assert.match(qualification, /runs-on: macos-15/u)
  assert.match(qualification, /if: \$\{\{ !inputs\.skip-macos-release-build \}\}/u)
  assert.match(qualification, /uses: actions\/checkout@[0-9a-f]{40}/u)
  assert.match(qualification, /persist-credentials: false/u)
  assert.match(qualification, /uses: actions\/setup-node@[0-9a-f]{40}/u)
  assert.match(qualification, /node-version: 22/u)
  assert.match(qualification, /npm ci --prefer-offline --no-audit --no-fund/u)
  assert.match(qualification, /node scripts\/download-native-node-runtime\.cjs arm64/u)

  const orderedPrerequisites = [
    'uses: actions/checkout@',
    'uses: actions/setup-node@',
    'run: npm ci --prefer-offline --no-audit --no-fund',
    '- name: Download checksum-pinned Node runtime',
  ]
  let previous = -1
  for (const prerequisite of orderedPrerequisites) {
    const position = qualification.indexOf(prerequisite)
    assert.ok(position > previous, `${prerequisite} must precede optimized qualification`)
    previous = position
  }

  const requiredSteps = [
    'Compile optimized Kaisola macOS app',
    'Verify sealed Kaisola package',
    'Prove packaged broker and PTY continuity',
    'Gate installed optimized PDF previews',
  ]
  for (const step of requiredSteps) {
    const position = qualification.indexOf(`- name: ${step}`)
    assert.ok(position > previous, `${step} must run in qualification order`)
    previous = position
    assert.equal(verify.includes(`- name: ${step}`), false, `${step} must leave the simulator job`)
  }

  assert.match(qualification, /-configuration LocalRelease/u)
  assert.match(qualification, /npm run native:preflight --/u)
  assert.match(qualification, /npm run native:helper:probe --/u)
  assert.match(qualification, /--require-signed-host/u)
  assert.match(qualification, /npm run native:pdf-preview-budget --/u)
  assert.match(qualification, /--output "\$RUNNER_TEMP\/native-pdf-preview-budget\.json"/u)
  assert.doesNotMatch(
    qualification,
    /simctl|CoreSimulator|KaisolaCompanion|KAISOLA_COMPANION|iPhone/u,
  )
})

test('app receipts cannot claim green with missing metrics, threshold drift, or Debug bytes', () => {
  const receipt = passingReceipt()
  assert.deepEqual(validateAppReceipt(receipt, receipt.fixture, 123), receipt)
  assert.deepEqual(parseAppReceiptLine(`${APP_RECEIPT_PREFIX}${JSON.stringify(receipt)}`, receipt.fixture, 123), receipt)

  const sortedKeyReceipt = {
    ...receipt,
    thresholds: Object.fromEntries(Object.entries(receipt.thresholds).sort()),
    specification: Object.fromEntries(Object.entries(receipt.specification).sort()),
  }
  assert.equal(validateAppReceipt(sortedKeyReceipt, receipt.fixture, 123).result.pass, true)

  assert.throws(
    () => validateAppReceipt({ ...receipt, build: { ...receipt.build, optimized: false } }, receipt.fixture, 123),
    /optimized/u,
  )
  assert.throws(
    () => validateAppReceipt({ ...receipt, thresholds: { ...THRESHOLDS, maximumFirstVisiblePageLatencyMs: 30_000 } }, receipt.fixture, 123),
    /threshold/u,
  )
  assert.throws(
    () => validateAppReceipt({
      ...receipt,
      result: { ...receipt.result, firstVisiblePageLatencyMs: null },
    }, receipt.fixture, 123),
    /first-visible/u,
  )
  assert.throws(
    () => validateAppReceipt({ ...receipt, appPid: 124 }, receipt.fixture, 123),
    /pid/u,
  )
})

test('every fixture has independently validated render, paging, scroll, or rejection semantics', () => {
  for (const fixture of FIXTURES) {
    const receipt = passingReceipt(fixture)
    assert.equal(validateAppReceipt(receipt, fixture.id, 123).result.pass, true)
  }
  const many = passingReceipt(FIXTURES[0])
  many.result.subsequentPagingLatenciesMs.pop()
  assert.throws(() => validateAppReceipt(many, 'many-page', 123), /paging sample count/u)

  const malformed = passingReceipt(FIXTURES[2])
  malformed.result.outcome = 'rendered'
  assert.throws(() => validateAppReceipt(malformed, 'malformed', 123), /outcome/u)
})

test('memory gating appends a fixture-named physical-footprint diagnostic exactly once', () => {
  const receipt = passingReceipt(FIXTURES[1])
  const passing = mergeMemoryMeasurement(receipt, {
    peakPhysicalFootprintBytes: THRESHOLDS.maximumPeakPhysicalFootprintBytes,
    measuredProcessCount: 1,
    currentPhysicalFootprintBytes: 200 * 1024 * 1024,
  })
  assert.equal(passing.pass, true)
  assert.deepEqual(passing.diagnostics, [])

  const observed = THRESHOLDS.maximumPeakPhysicalFootprintBytes + 1
  const failing = mergeMemoryMeasurement(receipt, {
    peakPhysicalFootprintBytes: observed,
    measuredProcessCount: 2,
    currentPhysicalFootprintBytes: 300 * 1024 * 1024,
  })
  assert.equal(failing.pass, false)
  assert.deepEqual(failing.diagnostics, [{
    fixture: 'image-heavy',
    threshold: 'peakPhysicalFootprintBytes.maximum',
    observed,
    limit: THRESHOLDS.maximumPeakPhysicalFootprintBytes,
  }])
})

test('launch environment is broker-free and rooted in the caller temporary directory', () => {
  const environment = buildFixtureEnvironment('/tmp/kaisola-pdf-run', 'large-page')
  assert.deepEqual(environment, {
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
    LANG: 'en_US.UTF-8',
    TMPDIR: process.env.TMPDIR || require('node:os').tmpdir(),
    HOME: '/tmp/kaisola-pdf-run',
    CFFIXED_USER_HOME: '/tmp/kaisola-pdf-run',
    KAISOLA_NATIVE_PDF_PREVIEW_BUDGET: '1',
    KAISOLA_NATIVE_PDF_PREVIEW_FIXTURE: 'large-page',
    KAISOLA_NATIVE_PDF_PREVIEW_ROOT: '/tmp/kaisola-pdf-run',
  })
  assert.equal(Object.keys(environment).some((key) => /broker/u.test(key)), false)
  assert.deepEqual(buildFixtureLaunchOptions('/tmp/kaisola-pdf-run', 'large-page'), {
    cwd: '/tmp/kaisola-pdf-run',
    env: environment,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
})

test('CLI requires a copied installed app and refuses build-product paths', () => {
  assert.deepEqual(parseArguments([
    '--app', '/tmp/Applications/Kaisola PDF Budget QA.app',
    '--output', '/tmp/pdf-receipt.json',
  ]), {
    app: path.resolve('/tmp/Applications/Kaisola PDF Budget QA.app'),
    output: path.resolve('/tmp/pdf-receipt.json'),
  })
  assert.throws(() => parseArguments([]), /--app and --output are required/u)
  assert.throws(() => parseArguments(['--app', '/tmp/Kaisola.app', '--fixture', 'many-page']), /unknown argument/u)
  assert.throws(
    () => resolveInstalledExecutable('/tmp/DerivedData/Build/Products/LocalRelease/Kaisola.app'),
    /copied installed app/u,
  )
})

test('installed app identity is pinned across every fixture launch', (context) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-pdf-app-'))
  context.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const app = path.join(root, 'Applications', 'Kaisola PDF Budget QA.app')
  const executable = path.join(app, 'Contents', 'MacOS', 'Kaisola')
  fs.mkdirSync(path.dirname(executable), { recursive: true })
  fs.writeFileSync(executable, 'optimized-app-v1')
  fs.chmodSync(executable, 0o755)
  fs.writeFileSync(path.join(app, 'Contents', 'Info.plist'), 'fixture-info-v1')

  const installed = resolveInstalledExecutable(app)
  assert.doesNotThrow(() => assertInstalledAppUnchanged(installed))
  const alias = path.join(root, 'app-alias')
  fs.symlinkSync(app, alias)
  assert.doesNotThrow(() => assertReceiptBundlePath(installed, 'many-page', alias))
  assert.throws(
    () => assertReceiptBundlePath(installed, 'many-page', path.dirname(app)),
    /bundlePath does not match/u,
  )
  fs.writeFileSync(executable, 'unexpected-update')
  assert.throws(() => assertInstalledAppUnchanged(installed), /installed app changed/u)
})

test('PDF budget launch returns before updater, broker, workspace, and PTY startup', () => {
  const delegate = fs.readFileSync(path.resolve(
    __dirname,
    '../../native/KaisolaMac/Kaisola/App/KaisolaMacAppDelegate.swift',
  ), 'utf8')
  const settings = fs.readFileSync(path.resolve(
    __dirname,
    '../../native/KaisolaMac/Kaisola/App/NativePreviewSettings.swift',
  ), 'utf8')
  assert.match(
    delegate,
    /private lazy var updateController = NativeUpdateController\(\s*isolatedFixture: visualFixture \|\| resourceWorkload != nil \|\| pdfPreviewBudgetRequested\s*\)/u,
  )
  assert.match(settings, /environment\["KAISOLA_NATIVE_PDF_PREVIEW_BUDGET"\] != nil/u)

  const launch = delegate.slice(delegate.indexOf('func applicationDidFinishLaunching'))
  const budgetStart = launch.indexOf('if pdfPreviewBudgetRequested {')
  const normalStart = launch.indexOf('MemoryPressureResponder.shared.register')
  assert.ok(budgetStart >= 0 && normalStart > budgetStart)
  const isolatedBranch = launch.slice(budgetStart, normalStart)
  assert.match(isolatedBranch, /runner\.start\(\)\s+return/u)
  for (const forbidden of [
    'NativeUpdateController(',
    'ObserveOnlyBrokerClient(',
    'BrokerStartupCoordinator(',
    'AppModel(',
    'NativeTerminalSurface(',
    'CompanionHost(',
  ]) {
    assert.equal(isolatedBranch.includes(forbidden), false, forbidden)
  }
})

test('installed paging waits for PDFKit page draw completion instead of page selection alone', () => {
  const budget = fs.readFileSync(path.resolve(
    __dirname,
    '../../native/KaisolaMac/Kaisola/Features/Workspace/PDFPreviewBudget.swift',
  ), 'utf8')

  assert.match(budget, /final class PDFPreviewBudgetPage: PDFPage/u)
  assert.match(budget, /override var pageClass: AnyClass\s*\{\s*PDFPreviewBudgetPage\.self\s*\}/u)
  assert.match(
    budget,
    /nonisolated override func draw\(with box: PDFDisplayBox, to context: CGContext\)\s*\{\s*super\.draw\(with: box, to: context\)[\s\S]*?completedDrawCountStorage \+= 1\s*\}/u,
  )
  assert.match(
    budget,
    /page\.completedDrawCount > afterDrawCount, view\.currentPage === page/u,
  )
})

test('product and gate rely on PDFKit automatic layout without eager relayout', () => {
  const budget = fs.readFileSync(path.resolve(
    __dirname,
    '../../native/KaisolaMac/Kaisola/Features/Workspace/PDFPreviewBudget.swift',
  ), 'utf8')
  const editors = fs.readFileSync(path.resolve(
    __dirname,
    '../../native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewEditors.swift',
  ), 'utf8')

  const configurationStart = budget.indexOf('enum PDFPreviewViewConfiguration')
  const pageStart = budget.indexOf('final class PDFPreviewBudgetPage')
  assert.ok(configurationStart >= 0 && pageStart > configurationStart)
  const configuration = budget.slice(configurationStart, pageStart)
  assert.match(configuration, /view\.autoScales = true/u)
  assert.match(configuration, /view\.displayMode = \.singlePageContinuous/u)
  assert.match(configuration, /view\.displayDirection = \.vertical/u)
  assert.match(configuration, /view\.document = document/u)
  assert.doesNotMatch(configuration, /layoutDocumentView\(\)/u)

  const measureStart = budget.indexOf('private func measure(')
  const windowStart = budget.indexOf('private func makeWindowIfNeeded', measureStart)
  assert.ok(measureStart >= 0 && windowStart > measureStart)
  const measure = budget.slice(measureStart, windowStart)
  assert.match(measure, /PDFPreviewViewConfiguration\.install\(document: document, in: view\)/u)
  assert.match(
    measure,
    /view\.go\(to: firstPage\)\s+try\? await Task\.sleep\(for: \.milliseconds\(250\)\)/u,
  )
  assert.doesNotMatch(measure, /layoutDocumentView\(\)/u)

  assert.match(editors, /PDFPreviewViewConfiguration\.install\(document: document, in: view\)/u)
  assert.doesNotMatch(editors, /layoutDocumentView\(\)/u)
})

test('stderr is fail-closed except for exact fixture-scoped framework notices', () => {
  const persistence = '2026-08-08 22:26:13.078 Kaisola[2862:7385610] ApplePersistenceIgnoreState: Existing state will not be touched. New state will be written to /tmp/com.kaisola.mac.savedState'
  const malformed = 'CoreGraphics PDF has logged an error. Set environment variable "CG_PDF_VERBOSE" to learn more.'
  assert.doesNotThrow(() => validateAppStderr('', 'many-page'))
  assert.doesNotThrow(() => validateAppStderr(`${persistence}\n`, 'many-page'))
  assert.doesNotThrow(() => validateAppStderr(`${persistence}\n${malformed}\n`, 'malformed'))
  assert.throws(() => validateAppStderr(`${malformed}\n`, 'many-page'), /app emitted stderr/u)
  assert.throws(() => validateAppStderr('unexpected warning\n', 'malformed'), /app emitted stderr/u)
  assert.throws(() => validateAppStderr(`${malformed}\n${malformed}\n`, 'malformed'), /duplicate/u)
})
