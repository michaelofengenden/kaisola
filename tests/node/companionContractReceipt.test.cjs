'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const root = path.join(__dirname, '..', '..')
const script = path.join(root, 'scripts', 'companion-contract-receipt.cjs')
const repository = 'michaelofengenden/kaisola'
const commit = 'a'.repeat(40)
const runID = '123456789'
const destination = 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest'

const TOOLCHAIN_LOG = [
  'swift-driver version: 1.127.14 Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)',
  'Target: arm64-apple-macosx15.0',
  'Xcode 26.0',
  'Build version 17A400',
  '',
].join('\n')

function testLog({ executed = 46, failures = 0, unexpected = 0, status = 'passed', banner = '** TEST EXECUTE SUCCEEDED **' } = {}) {
  return [
    "Test Suite 'All tests' started at 2026-08-09 09:00:00.000.",
    "Test Suite 'KaisolaCompanionTests.xctest' started at 2026-08-09 09:00:00.001.",
    "Test Suite 'ProtocolFixtureTests' started at 2026-08-09 09:00:00.002.",
    "Test Case '-[KaisolaCompanionTests.ProtocolFixtureTests testFrameRoundTrip]' passed (0.001 seconds).",
    `Test Suite 'ProtocolFixtureTests' ${status} at 2026-08-09 09:00:00.010.`,
    `\t Executed ${executed} tests, with ${failures} failures (${unexpected} unexpected) in 0.010 (0.011) seconds`,
    `Test Suite 'KaisolaCompanionTests.xctest' ${status} at 2026-08-09 09:00:00.011.`,
    `\t Executed ${executed} tests, with ${failures} failures (${unexpected} unexpected) in 0.010 (0.012) seconds`,
    `Test Suite 'All tests' ${status} at 2026-08-09 09:00:00.012.`,
    `\t Executed ${executed} tests, with ${failures} failures (${unexpected} unexpected) in 0.010 (0.013) seconds`,
    '',
    banner,
    '',
  ].join('\n')
}

function fixture(t, overrides = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-contract-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const paths = {
    directory,
    testLog: path.join(directory, 'companion-tests.log'),
    toolchainLog: path.join(directory, 'apple-toolchain.txt'),
    receipt: path.join(directory, 'companion-contract.json'),
  }
  fs.writeFileSync(paths.testLog, overrides.testLog ?? testLog())
  fs.writeFileSync(paths.toolchainLog, overrides.toolchainLog ?? TOOLCHAIN_LOG)
  return paths
}

function createArgs(paths, overrides = {}) {
  return [
    'create',
    '--test-log', paths.testLog,
    '--toolchain-log', paths.toolchainLog,
    '--destination', overrides.destination ?? destination,
    '--runner-image', overrides.runnerImage ?? 'macos15',
    '--runner-image-version', '20260801.1',
    '--repository', repository,
    '--commit', commit,
    '--source-ref', overrides.sourceRef ?? 'refs/heads/main',
    '--run-id', runID,
    '--run-attempt', '1',
    '--output', paths.receipt,
  ]
}

function verifyArgs(paths, overrides = {}) {
  const values = {
    repository,
    commit,
    runID,
    requireRunnerImage: 'macos15',
    minimumTests: '20',
    ...overrides,
  }
  const args = [
    'verify',
    '--receipt', paths.receipt,
    '--repository', values.repository,
    '--commit', values.commit,
    '--run-id', values.runID,
    '--require-runner-image', values.requireRunnerImage,
    '--minimum-tests', values.minimumTests,
  ]
  if (values.runAttempt) args.push('--run-attempt', values.runAttempt)
  if (values.requireDevice) args.push('--require-device', values.requireDevice)
  if (values.maxAgeSeconds) args.push('--max-age-seconds', values.maxAgeSeconds)
  return args
}

function run(args) {
  return spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' })
}

function create(paths, overrides = {}) {
  const result = run(createArgs(paths, overrides))
  assert.equal(result.status, 0, result.stderr)
  return JSON.parse(fs.readFileSync(paths.receipt, 'utf8'))
}

function tamper(paths, mutate) {
  const receipt = JSON.parse(fs.readFileSync(paths.receipt, 'utf8'))
  mutate(receipt)
  fs.writeFileSync(paths.receipt, `${JSON.stringify(receipt, null, 2)}\n`)
}

function workflow(name) {
  return fs.readFileSync(path.join(root, '.github', 'workflows', name), 'utf8')
}

function step(contents, name) {
  const start = contents.indexOf(`- name: ${name}`)
  assert.ok(start >= 0, `${name} must exist`)
  const next = contents.indexOf('\n      - ', start)
  return contents.slice(start, next < 0 ? contents.length : next)
}

test('companion receipt seals the executed test count, toolchain, and simulator', (t) => {
  const paths = fixture(t)
  const receipt = create(paths)

  assert.equal(receipt.kind, 'kaisola-companion-contract')
  assert.equal(receipt.repository, repository)
  assert.deepEqual(receipt.source, { commit, ref: 'refs/heads/main' })
  assert.deepEqual(receipt.workflow, { runID, runAttempt: 1 })
  assert.deepEqual(receipt.tests, { executed: 46, failed: 0, unexpected: 0, suites: 1 })
  assert.deepEqual(receipt.destination, { platform: 'iOS Simulator', device: 'iPhone 16 Pro', os: 'latest' })
  assert.equal(receipt.toolchain.swift, '6.2')
  assert.equal(receipt.toolchain.xcode, '26.0')
  assert.equal(receipt.toolchain.xcodeBuild, '17A400')
  assert.equal(receipt.toolchain.runnerImage, 'macos15')
  assert.match(receipt.toolchain.fingerprint, /^[0-9a-f]{64}$/)

  const verified = run(verifyArgs(paths))
  assert.equal(verified.status, 0, verified.stderr)
  assert.match(verified.stdout, /COMPANION_CONTRACT=.*"pass":true/)
  assert.match(verified.stdout, /"testsExecuted":46/)
})

test('companion promotion refuses a green run that executed nothing', (t) => {
  // The whole point of the receipt: a job can conclude success while the
  // Companion surface was skipped, filtered to zero, or never bootstrapped.
  const executedNothing = fixture(t, { testLog: testLog({ executed: 0 }) })
  const zero = run(createArgs(executedNothing))
  assert.notEqual(zero.status, 0)
  assert.match(zero.stderr, /executed no tests/)
  assert.equal(fs.existsSync(executedNothing.receipt), false)

  const noSuites = fixture(t, {
    testLog: '** TEST EXECUTE SUCCEEDED **\n',
  })
  const empty = run(createArgs(noSuites))
  assert.notEqual(empty.status, 0)
  assert.match(empty.stderr, /no aggregate test suite result/)

  const belowFloor = fixture(t, { testLog: testLog({ executed: 3 }) })
  create(belowFloor)
  const thin = run(verifyArgs(belowFloor))
  assert.notEqual(thin.status, 0)
  assert.match(thin.stderr, /executed 3 tests, fewer than the required 20/)
})

test('companion receipt creation refuses a failed, cancelled, or bannerless run', (t) => {
  const cases = [
    [testLog({ failures: 2, status: 'failed', banner: '** TEST EXECUTE FAILED **' }), /failed or cancelled run/],
    [testLog({ banner: 'Testing cancelled.' }), /failed or cancelled run/],
    [testLog({ banner: '' }), /no completed xcodebuild test result/],
    [testLog({ failures: 1, unexpected: 1 }), /reports test failures/],
    [testLog({ status: 'failed' }), /failed aggregate test suite/],
  ]
  for (const [log, expected] of cases) {
    const paths = fixture(t, { testLog: log })
    const result = run(createArgs(paths))
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, expected)
    assert.equal(fs.existsSync(paths.receipt), false)
  }
})

test('companion receipt creation refuses a destination that is not the pinned simulator', (t) => {
  for (const value of [
    'platform=iOS,name=Michael iPhone,OS=18.0',
    'platform=macOS,name=Any Mac,OS=latest',
    'platform=iOS Simulator,name=iPhone 16 Pro',
  ]) {
    const paths = fixture(t)
    const result = run(createArgs(paths, { destination: value }))
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /iOS Simulator|exactly a platform/)
  }
})

test('companion promotion is bound to the exact repository, commit, run, and protected ref', (t) => {
  const paths = fixture(t)
  create(paths)

  for (const override of [
    { commit: 'c'.repeat(40) },
    { runID: '987654321' },
    { repository: 'attacker/kaisola' },
    { runAttempt: '4' },
  ]) {
    const result = run(verifyArgs(paths, override))
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /does not belong to this repository|different run attempt/)
  }

  const pullRequest = fixture(t)
  create(pullRequest, { sourceRef: 'refs/pull/17/merge' })
  const promoted = run(verifyArgs(pullRequest))
  assert.notEqual(promoted.status, 0)
  assert.match(promoted.stderr, /does not belong to this repository, commit, protected ref, and run/)
})

test('companion promotion refuses a forged pass, count, or toolchain', (t) => {
  const cases = [
    [(receipt) => { receipt.pass = false }, /does not record a passing iPhone run/],
    [(receipt) => { receipt.tests.executed = 0 }, /executed test count must be an integer >= 1/],
    [(receipt) => { receipt.tests.failed = 1 }, /records test failures/],
    [(receipt) => { receipt.tests.unexpected = 1 }, /records test failures/],
    [(receipt) => { receipt.tests.suites = 0 }, /aggregate suite count/],
    [(receipt) => { receipt.toolchain.xcode = '14.0' }, /fingerprint does not seal/],
    [(receipt) => { delete receipt.toolchain.runnerImageVersion }, /runner image version is invalid/],
    [(receipt) => { receipt.schemaVersion = 2 }, /schema is unsupported/],
    [(receipt) => { receipt.kind = 'kaisola-native-release-candidate' }, /schema is unsupported/],
    [(receipt) => { receipt.generatedAt = new Date(Date.now() + 3_600_000).toISOString() }, /timestamped in the future/],
    [(receipt) => { receipt.generatedAt = '2026-08-09 09:00:00' }, /not canonical ISO-8601/],
  ]
  for (const [mutate, expected] of cases) {
    const paths = fixture(t)
    create(paths)
    tamper(paths, mutate)
    const result = run(verifyArgs(paths))
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, expected)
  }
})

test('companion promotion refuses a foreign toolchain, simulator, or stale receipt', (t) => {
  const paths = fixture(t)
  create(paths)

  const foreignImage = run(verifyArgs(paths, { requireRunnerImage: 'macos14' }))
  assert.notEqual(foreignImage.status, 0)
  assert.match(foreignImage.stderr, /ran on runner image macos15, not macos14/)

  const foreignDevice = run(verifyArgs(paths, { requireDevice: 'iPhone 12 mini' }))
  assert.notEqual(foreignDevice.status, 0)
  assert.match(foreignDevice.stderr, /ran on iPhone 16 Pro, not iPhone 12 mini/)

  tamper(paths, (receipt) => { receipt.destination.platform = 'iOS' })
  const foreignPlatform = run(verifyArgs(paths))
  assert.notEqual(foreignPlatform.status, 0)
  assert.match(foreignPlatform.stderr, /did not run on the iOS Simulator/)

  const stale = fixture(t)
  create(stale)
  tamper(stale, (receipt) => {
    receipt.generatedAt = new Date(Date.now() - 30 * 24 * 3_600_000).toISOString()
  })
  const expired = run(verifyArgs(stale, { maxAgeSeconds: '3600' }))
  assert.notEqual(expired.status, 0)
  assert.match(expired.stderr, /older than the required 3600s/)
})

test('companion promotion refuses a missing receipt instead of continuing', (t) => {
  const paths = fixture(t)
  const missing = run(verifyArgs(paths))
  assert.notEqual(missing.status, 0)
  assert.match(missing.stderr, /could not read companion contract receipt/)

  fs.writeFileSync(paths.receipt, '')
  const empty = run(verifyArgs(paths))
  assert.notEqual(empty.status, 0)

  const wrongName = { ...paths, receipt: path.join(paths.directory, 'contract.json') }
  fs.writeFileSync(wrongName.receipt, '{}')
  const renamed = run(verifyArgs(wrongName))
  assert.notEqual(renamed.status, 0)
  assert.match(renamed.stderr, /must be named companion-contract\.json/)
})

test('the shared Swift workflow has no switch that skips the iPhone lane', () => {
  const contracts = workflow('swift-contracts.yml')

  assert.doesNotMatch(contracts, /skip-ios/, 'a skippable iPhone lane is exactly the promotion bypass')
  for (const name of [
    'Compile optimized iPhone app against KaisolaCore',
    'Compile iPhone test bundle against KaisolaCore',
    'Run iPhone contract and app tests',
    'Receipt the executed iPhone contract run',
    'Upload the executed iPhone contract receipt',
  ]) {
    assert.doesNotMatch(step(contracts, name), /\n\s+if:/, `${name} must never be conditional`)
  }

  assert.match(contracts, /runs-on: macos-15/)
  assert.match(contracts, /KAISOLA_COMPANION_SIMULATOR_OS: '18\.5'/)
  assert.match(contracts, /COMPANION_TEST_DESTINATION: 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18\.5'/)
  const testStep = step(contracts, 'Run iPhone contract and app tests')
  assert.match(testStep, /-destination "\$\{\{ steps\.companion-simulator\.outputs\.destination \}\}"/)
  assert.match(testStep, /"\$RUNNER_TEMP\/companion-contract\/companion-tests\.log"/)

  const receiptStep = step(contracts, 'Receipt the executed iPhone contract run')
  assert.match(receiptStep, /node scripts\/companion-contract-receipt\.cjs create/)
  assert.match(receiptStep, /--destination "\$COMPANION_TEST_DESTINATION"/)
  assert.match(receiptStep, /--commit "\$GITHUB_SHA"/)
  assert.match(receiptStep, /--run-id "\$GITHUB_RUN_ID"/)
  assert.match(receiptStep, /--runner-image "\$ImageOS"/)

  const uploadStep = step(contracts, 'Upload the executed iPhone contract receipt')
  assert.match(uploadStep, /uses: actions\/upload-artifact@[0-9a-f]{40}/)
  assert.match(uploadStep, /name: kaisola-companion-contract/)
  assert.match(uploadStep, /if-no-files-found: error/)

  const testsIndex = contracts.indexOf('- name: Run iPhone contract and app tests')
  const receiptIndex = contracts.indexOf('- name: Receipt the executed iPhone contract run')
  const uploadIndex = contracts.indexOf('- name: Upload the executed iPhone contract receipt')
  assert.ok(testsIndex < receiptIndex && receiptIndex < uploadIndex,
    'only an executed test run may be receipted, and only a receipt may be uploaded')
  assert.match(contracts, /tests\/node\/companionContractReceipt\.test\.cjs/)
})

test('the release candidate proves the Companion for the commit it seals', () => {
  const candidate = workflow('release-candidate.yml')

  assert.match(candidate, /uses: \.\/\.github\/workflows\/swift-contracts\.yml/)
  assert.doesNotMatch(candidate, /skip-ios/)
  assert.match(candidate, /skip-macos-release-build: true/)
})

test('tag promotion fails closed on the executed iPhone contract before touching bytes', () => {
  const release = workflow('release.yml')

  assert.match(release, /select\(\.name == "kaisola-companion-contract" and \(\.expired \| not\)\)/)
  assert.match(release, /exactly one unexpired iPhone contract receipt/)

  const download = step(release, 'Download the executed iPhone contract receipt')
  assert.match(download, /uses: actions\/download-artifact@[0-9a-f]{40}/)
  assert.match(download, /run-id: \$\{\{ steps\.candidate\.outputs\.run-id \}\}/)

  const gate = step(release, 'Require an executed iPhone contract run for this exact commit')
  assert.match(gate, /node scripts\/companion-contract-receipt\.cjs verify/)
  assert.match(gate, /--commit "\$GITHUB_SHA"/)
  assert.match(gate, /--run-id "\$\{\{ steps\.candidate\.outputs\.run-id \}\}"/)
  assert.match(gate, /--require-runner-image macos15/)
  assert.match(gate, /--require-device 'iPhone 16 Pro'/)
  const floor = gate.match(/--minimum-tests (\d+)/)
  assert.ok(floor && Number(floor[1]) >= 1, 'promotion must demand a real executed test count')

  // macos15 is the ImageOS the pinned runner reports; the two must agree or the
  // gate would reject every honest receipt.
  assert.match(release, /runs-on: macos-15/)

  const gateIndex = release.indexOf('- name: Require an executed iPhone contract run for this exact commit')
  const candidateIndex = release.indexOf('- name: Download exact candidate artifact')
  const publishIndex = release.indexOf('- name: Publish exact candidate assets')
  assert.ok(gateIndex >= 0 && gateIndex < candidateIndex && candidateIndex < publishIndex,
    'the Companion gate must pass before any candidate byte is downloaded or published')
})
