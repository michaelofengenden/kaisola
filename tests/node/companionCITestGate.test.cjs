'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')
const {
  classifyTestRun,
  hasCrashReport,
  parseXCResultSummary,
  parseXcodeVersion,
  requireExactArchitectures,
  resolveSimulator,
  validateArchitectureReceipt,
  verifySimulatorProbe,
} = require('../../scripts/companion-ci-test-gate.cjs')

const runtimeIdentifier = 'com.apple.CoreSimulator.SimRuntime.iOS-18-5'
const deviceTypeIdentifier = 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro'

function simulatorInventory(overrides = {}) {
  return {
    runtimes: {
      runtimes: [{
        identifier: runtimeIdentifier,
        version: '18.5',
        name: 'iOS 18.5',
        buildversion: '22F76',
        isAvailable: true,
        supportedArchitectures: ['x86_64', 'arm64'],
      }],
    },
    devices: {
      devices: {
        [runtimeIdentifier]: [{
          name: 'iPhone 16 Pro',
          udid: 'DB7A4F45-473E-4AFF-B207-43FBCE9682DE',
          state: 'Shutdown',
          isAvailable: true,
          deviceTypeIdentifier,
        }],
      },
    },
    ...overrides,
  }
}

function classify(log, overrides = {}) {
  return classifyTestRun({
    log,
    exitCode: 65,
    resultBundlePresent: true,
    destinationReceiptValid: true,
    architectureReceiptValid: true,
    simulatorProbeValid: true,
    launchDiagnosticsPresent: true,
    xcresultDiagnosticsPresent: true,
    simulatorLogPresent: true,
    simulatorDiagnosePresent: true,
    crashReportPresent: true,
    xcresultSummaryPresent: true,
    xcresultTestCount: 0,
    xcresultResult: 'Failed',
    xcresultEnvironmentMatches: true,
    ...overrides,
  })
}

test('simulator resolver pins exact Xcode, runtime, device type, UDID, and architecture', () => {
  assert.deepEqual(parseXcodeVersion('Xcode 16.4\nBuild version 16F6\n'), {
    version: '16.4',
    buildVersion: '16F6',
  })

  const inventory = simulatorInventory()
  const receipt = resolveSimulator({
    ...inventory,
    expectedXcodeVersion: '16.4',
    expectedXcodeBuildVersion: '16F6',
    xcodeVersionText: 'Xcode 16.4\nBuild version 16F6\n',
    runtimeIdentifier,
    runtimeVersion: '18.5',
    deviceTypeIdentifier,
    deviceName: 'iPhone 16 Pro',
    architecture: 'arm64',
  })

  assert.equal(receipt.runtime.identifier, runtimeIdentifier)
  assert.equal(receipt.device.udid, 'DB7A4F45-473E-4AFF-B207-43FBCE9682DE')
  assert.equal(receipt.architecture, 'arm64')
  assert.equal(
    receipt.destination,
    'platform=iOS Simulator,id=DB7A4F45-473E-4AFF-B207-43FBCE9682DE,arch=arm64',
  )
})

test('simulator resolver fails closed on runtime drift or ambiguous devices', () => {
  const inventory = simulatorInventory()
  const options = {
    ...inventory,
    expectedXcodeVersion: '16.4',
    expectedXcodeBuildVersion: '16F6',
    xcodeVersionText: 'Xcode 16.4\nBuild version 16F6\n',
    runtimeIdentifier,
    runtimeVersion: '18.5',
    deviceTypeIdentifier,
    deviceName: 'iPhone 16 Pro',
    architecture: 'arm64',
  }

  assert.throws(
    () => resolveSimulator({ ...options, runtimeIdentifier: `${runtimeIdentifier}\noutput=forged` }),
    /runtime identifier must be an exact/,
  )
  assert.throws(
    () => resolveSimulator({ ...options, deviceTypeIdentifier: `${deviceTypeIdentifier}\noutput=forged` }),
    /device type must be an exact/,
  )
  assert.throws(
    () => resolveSimulator({ ...options, expectedXcodeBuildVersion: '16F5' }),
    /Xcode build drifted/,
  )
  assert.throws(
    () => resolveSimulator({
      ...options,
      runtimes: {
        runtimes: [{ ...inventory.runtimes.runtimes[0], supportedArchitectures: ['x86_64'] }],
      },
    }),
    /does not support arm64/,
  )
  assert.throws(
    () => resolveSimulator({ ...options, runtimeVersion: 'latest' }),
    /runtime version must be an exact numeric version/,
  )
  assert.throws(
    () => resolveSimulator({ ...options, architecture: 'x86_64' }),
    /requires arm64/,
  )
  assert.throws(
    () => resolveSimulator({
      ...options,
      devices: {
        devices: {
          [runtimeIdentifier]: [
            inventory.devices.devices[runtimeIdentifier][0],
            {
              ...inventory.devices.devices[runtimeIdentifier][0],
              udid: 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
            },
          ],
        },
      },
    }),
    /exactly one available simulator/,
  )
  assert.throws(
    () => resolveSimulator({
      ...options,
      runtimes: {
        runtimes: [{ ...inventory.runtimes.runtimes[0], isAvailable: false }],
      },
    }),
    /runtime is unavailable/,
  )
})

test('binary and boot probes reject translated or universal execution', () => {
  assert.deepEqual(requireExactArchitectures('arm64\n', 'app'), ['arm64'])
  assert.throws(() => requireExactArchitectures('arm64 x86_64\n', 'app'), /exactly arm64/)
  assert.throws(() => requireExactArchitectures('x86_64\n', 'app'), /exactly arm64/)
  assert.deepEqual(verifySimulatorProbe('arm64\n', 'arm64'), {
    architecture: 'arm64',
    pass: true,
  })
  assert.throws(() => verifySimulatorProbe('x86_64\n', 'arm64'), /reported x86_64/)
})

test('architecture receipt covers the host stub, app debug dylib, and test bundle exactly', () => {
  const binary = (label) => ({ label, path: `/tmp/${label}`, architectures: ['arm64'] })
  const receipt = {
    schemaVersion: 1,
    architecture: 'arm64',
    binaries: [
      binary('test-host'),
      binary('test-host-debug-dylib'),
      binary('test-bundle'),
    ],
    pass: true,
  }

  assert.equal(validateArchitectureReceipt(receipt), true)
  assert.equal(validateArchitectureReceipt({
    ...receipt,
    binaries: receipt.binaries.filter((entry) => entry.label !== 'test-host-debug-dylib'),
  }), false)
  assert.equal(validateArchitectureReceipt({
    ...receipt,
    binaries: [...receipt.binaries, binary('unreviewed-extra')],
  }), false)
  assert.equal(validateArchitectureReceipt({
    ...receipt,
    binaries: receipt.binaries.map((entry) => (
      entry.label === 'test-host-debug-dylib'
        ? { ...entry, architectures: ['arm64', 'x86_64'] }
        : entry
    )),
  }), false)
})

test('xcresult summary pins the counted tests to the resolved simulator environment', () => {
  const summary = {
    title: 'Test - KaisolaCompanion',
    result: 'Passed',
    totalTestCount: 46,
    passedTests: 46,
    failedTests: 0,
    skippedTests: 0,
    expectedFailures: 0,
    devicesAndConfigurations: [{
      device: {
        deviceId: 'DB7A4F45-473E-4AFF-B207-43FBCE9682DE',
        deviceName: 'iPhone 16 Pro',
        architecture: 'arm64',
        modelName: 'iPhone 16 Pro',
        platform: 'iOS Simulator',
        osVersion: '18.5',
      },
      passedTests: 46,
      failedTests: 0,
      skippedTests: 0,
      expectedFailures: 0,
      testPlanConfiguration: {
        configurationId: '1',
        configurationName: 'Test Scheme Action',
      },
    }],
  }
  assert.deepEqual(parseXCResultSummary(summary, {
    udid: 'DB7A4F45-473E-4AFF-B207-43FBCE9682DE',
    deviceName: 'iPhone 16 Pro',
    architecture: 'arm64',
    runtimeVersion: '18.5',
  }), {
    result: 'Passed',
    totalTestCount: 46,
    passedTests: 46,
    failedTests: 0,
    skippedTests: 0,
    expectedFailures: 0,
    environmentMatches: true,
    device: summary.devicesAndConfigurations[0].device,
  })
  assert.throws(() => parseXCResultSummary({
    ...summary,
    devicesAndConfigurations: [{
      ...summary.devicesAndConfigurations[0],
      device: { ...summary.devicesAndConfigurations[0].device, architecture: 'x86_64' },
    }],
  }, {
    udid: 'DB7A4F45-473E-4AFF-B207-43FBCE9682DE',
    deviceName: 'iPhone 16 Pro',
    architecture: 'arm64',
    runtimeVersion: '18.5',
  }), /environment does not match/)
})

test('SIGBUS classification locates the last reached app launch boundary', () => {
  const crash = 'Test crashed with signal bus before starting test execution. KaisolaCompanion (15025)'
  assert.equal(classify(crash).classification, 'pre_app_entry_sigbus')
  assert.equal(classify(`${crash}\nKAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=15025`).classification, 'app_initialization_sigbus')
  assert.equal(classify(`${crash}\nKAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=15025\nKAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=15025\nKAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=15025\nKAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_started pid=15025`).classification, 'auth_restore_sigbus')
  assert.equal(classify(`${crash}\nKAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=15025\nKAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=15025\nKAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=15025\nKAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_started pid=15025\nKAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_completed pid=15025`).classification, 'test_bootstrap_sigbus')
  assert.equal(classify(`${crash}\nTest Case '-[KaisolaCompanionTests.ExampleTests testOne]' started.`).classification, 'post_bootstrap_sigbus')
})

test('classification uses the crashed PID instead of stale milestones from an earlier host', () => {
  const result = classify(`
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_started pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_completed pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=200
KaisolaCompanion (200) encountered an error (Test crashed with signal bus before starting test execution.)
`)
  assert.equal(result.crashedPID, 200)
  assert.equal(result.relevantLaunchAttempt.pid, 200)
  assert.equal(result.classification, 'app_initialization_sigbus')
})

test('suite-runner SIGBUS cannot inherit launch milestones from a different app PID', () => {
  const result = classify(`
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_started pid=100
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_completed pid=100
CryptoNoiseVectorTests (200) encountered an error (Test crashed with signal bus before starting test execution.)
`)
  assert.equal(result.crashedProcess, 'CryptoNoiseVectorTests')
  assert.equal(result.crashedPID, 200)
  assert.equal(result.relevantLaunchAttempt, null)
  assert.equal(result.classification, 'pre_app_entry_sigbus')
})

test('successful xcodebuild is rejected unless app milestones and real tests are counted', () => {
  const milestones = `
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_started pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_completed pid=501
`
  const pass = classify(`${milestones}\nTest Case '-[KaisolaCompanionTests.ExampleTests testOne]' started.\nExecuted 46 tests, with 0 failures\n** TEST EXECUTE SUCCEEDED **`, {
    exitCode: 0,
    crashReportPresent: false,
    simulatorLogPresent: false,
    simulatorDiagnosePresent: false,
    xcresultSummaryPresent: true,
    xcresultTestCount: 46,
    xcresultResult: 'Passed',
  })
  assert.equal(pass.classification, 'pass')
  assert.equal(pass.executedTestCount, 46)
  assert.equal(pass.pass, true)

  const zeroTests = classify(`${milestones}\n** TEST EXECUTE SUCCEEDED **`, {
    exitCode: 0,
    crashReportPresent: false,
    simulatorLogPresent: false,
    simulatorDiagnosePresent: false,
    xcresultResult: 'Passed',
  })
  assert.equal(zeroTests.classification, 'zero_test_success')
  assert.equal(zeroTests.pass, false)

  const missingMilestones = classify("Test Case '-[KaisolaCompanionTests.ExampleTests testOne]' started.\nExecuted 1 test, with 0 failures\n** TEST EXECUTE SUCCEEDED **", {
    exitCode: 0,
    crashReportPresent: false,
    simulatorLogPresent: false,
    simulatorDiagnosePresent: false,
    xcresultTestCount: 1,
    xcresultResult: 'Passed',
  })
  assert.equal(missingMilestones.classification, 'missing_launch_diagnostics')
  assert.equal(missingMilestones.pass, false)

  const mismatchedCount = classify(`${milestones}\nTest Case '-[KaisolaCompanionTests.ExampleTests testOne]' started.\nExecuted 46 tests, with 0 failures\n** TEST EXECUTE SUCCEEDED **`, {
    exitCode: 0,
    crashReportPresent: false,
    simulatorLogPresent: false,
    simulatorDiagnosePresent: false,
    xcresultTestCount: 45,
    xcresultResult: 'Passed',
  })
  assert.equal(mismatchedCount.classification, 'test_count_mismatch')
  assert.equal(mismatchedCount.pass, false)
})

test('successful gating requires synchronous app init but not async root-task scheduling', () => {
  const synchronousInit = `
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=501
`
  const result = classify(`${synchronousInit}\nTest Case '-[KaisolaCompanionTests.ExampleTests testOne]' started.\nExecuted 1 test, with 0 failures\n** TEST EXECUTE SUCCEEDED **`, {
    exitCode: 0,
    crashReportPresent: false,
    simulatorLogPresent: false,
    simulatorDiagnosePresent: false,
    xcresultTestCount: 1,
    xcresultResult: 'Passed',
  })

  assert.equal(result.classification, 'pass')
  assert.equal(result.launchDiagnosticsComplete, true)
})

test('canonical launch diagnostics prevent duplicate capture from corrupting phase order', () => {
  const milestones = `
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_started pid=501
KAISOLA_COMPANION_TEST_LAUNCH phase=auth_restore_completed pid=501
`
  const result = classify(`${milestones}${milestones}\nTest Case '-[KaisolaCompanionTests.ExampleTests testOne]' started.\nExecuted 1 test, with 0 failures\n** TEST EXECUTE SUCCEEDED **`, {
    launchDiagnostics: milestones,
    exitCode: 0,
    crashReportPresent: false,
    simulatorLogPresent: false,
    simulatorDiagnosePresent: false,
    xcresultTestCount: 1,
    xcresultResult: 'Passed',
  })

  assert.equal(result.launchAttempts[0].orderValid, true)
  assert.equal(result.classification, 'pass')
})

test('pre-bootstrap failure receipt exposes every missing diagnostic artifact', () => {
  const result = classifyTestRun({
    log: 'Test crashed with signal bus before starting test execution.',
    exitCode: 65,
    resultBundlePresent: false,
    destinationReceiptValid: true,
    architectureReceiptValid: false,
    simulatorProbeValid: true,
    launchDiagnosticsPresent: false,
    xcresultDiagnosticsPresent: false,
    simulatorLogPresent: false,
    simulatorDiagnosePresent: false,
    crashReportPresent: false,
    xcresultSummaryPresent: false,
  })
  assert.equal(result.pass, false)
  assert.equal(result.diagnosticsComplete, false)
  assert.deepEqual(result.missingArtifacts, [
    'architecture-receipt',
    'launch-diagnostics',
    'xcresult-bundle',
    'xcresult-diagnostics',
    'xcresult-summary',
    'simulator-log',
    'simctl-diagnose',
    'crash-report',
  ])
})

test('crash evidence requires a nonempty ips or crash report, not any directory entry', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-crash-evidence-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.writeFileSync(path.join(root, 'collector.stderr'), 'command failed\n')
  assert.equal(hasCrashReport(root), false)
  fs.writeFileSync(path.join(root, 'KaisolaCompanion-2026-08-08.ips'), 'SIGBUS\n')
  assert.equal(hasCrashReport(root), true)
})

test('classify-test CLI seals a complete passing receipt end to end', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-classifier-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const script = path.join(__dirname, '..', '..', 'scripts', 'companion-ci-test-gate.cjs')
  const paths = Object.fromEntries([
    'log',
    'exit-code',
    'launch-diagnostics',
    'destination',
    'architectures',
    'probe',
    'summary',
    'xcresult-diagnostics.complete',
    'output',
  ].map((name) => [name, path.join(root, name)]))
  const resultBundle = path.join(root, 'KaisolaCompanion.xcresult')
  const xcresultDiagnostics = path.join(root, 'xcresult-diagnostics')
  fs.mkdirSync(resultBundle)
  fs.mkdirSync(xcresultDiagnostics)
  fs.writeFileSync(path.join(resultBundle, 'Info.plist'), 'receipt')
  fs.writeFileSync(path.join(xcresultDiagnostics, 'session.log'), 'receipt')
  fs.writeFileSync(paths['xcresult-diagnostics.complete'], 'complete\n')
  fs.writeFileSync(paths['exit-code'], '0\n')
  fs.writeFileSync(paths.log, "Test Case '-[KaisolaCompanionTests.ExampleTests testOne]' started.\nExecuted 1 test, with 0 failures\n** TEST EXECUTE SUCCEEDED **\n")
  fs.writeFileSync(paths['launch-diagnostics'], [
    'KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_started pid=501',
    'KAISOLA_COMPANION_TEST_LAUNCH phase=auth_model_constructed pid=501',
    'KAISOLA_COMPANION_TEST_LAUNCH phase=app_init_completed pid=501',
    '',
  ].join('\n'))
  fs.writeFileSync(paths.destination, JSON.stringify({
    schemaVersion: 1,
    architecture: 'arm64',
    device: {
      name: 'iPhone 16 Pro',
      udid: 'DB7A4F45-473E-4AFF-B207-43FBCE9682DE',
    },
    runtime: { version: '18.5' },
    destination: 'platform=iOS Simulator,id=DB7A4F45-473E-4AFF-B207-43FBCE9682DE,arch=arm64',
  }))
  fs.writeFileSync(paths.architectures, JSON.stringify({
    schemaVersion: 1,
    architecture: 'arm64',
    pass: true,
    binaries: ['test-host', 'test-host-debug-dylib', 'test-bundle'].map((label) => ({
      label,
      path: `/tmp/${label}`,
      architectures: ['arm64'],
    })),
  }))
  fs.writeFileSync(paths.probe, JSON.stringify({
    schemaVersion: 1,
    architecture: 'arm64',
    pass: true,
  }))
  fs.writeFileSync(paths.summary, JSON.stringify({
    result: 'Passed',
    totalTestCount: 1,
    passedTests: 1,
    failedTests: 0,
    skippedTests: 0,
    expectedFailures: 0,
    devicesAndConfigurations: [{
      device: {
        deviceId: 'DB7A4F45-473E-4AFF-B207-43FBCE9682DE',
        deviceName: 'iPhone 16 Pro',
        architecture: 'arm64',
        modelName: 'iPhone 16 Pro',
        platform: 'iOS Simulator',
        osVersion: '18.5',
      },
      passedTests: 1,
      failedTests: 0,
      skippedTests: 0,
      expectedFailures: 0,
      testPlanConfiguration: { configurationId: '1', configurationName: 'Test Scheme Action' },
    }],
  }))

  const result = spawnSync(process.execPath, [
    script,
    'classify-test',
    '--log', paths.log,
    '--launch-diagnostics', paths['launch-diagnostics'],
    '--exit-code-file', paths['exit-code'],
    '--result-bundle', resultBundle,
    '--xcresult-diagnostics', xcresultDiagnostics,
    '--xcresult-diagnostics-success', paths['xcresult-diagnostics.complete'],
    '--destination-receipt', paths.destination,
    '--architecture-receipt', paths.architectures,
    '--simulator-probe-receipt', paths.probe,
    '--xcresult-summary', paths.summary,
    '--simulator-log', path.join(root, 'simulator.log'),
    '--simulator-diagnose', path.join(root, 'simctl-diagnose'),
    '--simulator-diagnose-success', path.join(root, 'simctl-diagnose.complete'),
    '--crash-reports', path.join(root, 'crash-reports'),
    '--output', paths.output,
  ], { encoding: 'utf8' })

  assert.equal(result.status, 0, result.stderr)
  const receipt = JSON.parse(fs.readFileSync(paths.output, 'utf8'))
  assert.equal(receipt.classification, 'pass')
  assert.equal(receipt.pass, true)
  assert.equal(receipt.executedTestCount, 1)
  assert.deepEqual(receipt.missingArtifacts, [])
})

test('Companion launch emits ordered, PID-scoped boundaries around auth construction and restore', () => {
  const root = path.join(__dirname, '..', '..')
  const source = fs.readFileSync(
    path.join(root, 'mobile/KaisolaCompanion/KaisolaCompanion/App/KaisolaCompanionApp.swift'),
    'utf8',
  )
  const initStarted = source.indexOf('testLaunchDiagnostic("app_init_started")')
  const makeAuth = source.indexOf('_auth = StateObject(wrappedValue: Self.makeAuth())')
  const authConstructed = source.indexOf('testLaunchDiagnostic("auth_model_constructed")')
  const initCompleted = source.indexOf('testLaunchDiagnostic("app_init_completed")')
  const restoreStarted = source.indexOf('testLaunchDiagnostic("auth_restore_started")')
  const restore = source.indexOf('await auth.restore()')
  const restoreCompleted = source.indexOf('testLaunchDiagnostic("auth_restore_completed")')

  assert.ok(initStarted >= 0 && initStarted < makeAuth)
  assert.ok(makeAuth < authConstructed && authConstructed < initCompleted)
  assert.ok(initCompleted < restoreStarted && restoreStarted < restore && restore < restoreCompleted)
  assert.match(source, /KAISOLA_COMPANION_TEST_LAUNCH phase=\\\(phase\) pid=\\\(ProcessInfo\.processInfo\.processIdentifier\)/)
  assert.match(source, /KAISOLA_COMPANION_TEST_LAUNCH_DIAGNOSTICS.*== "1"/s)
})

test('swift-contracts workflow preserves full failure evidence without blind retry', () => {
  const root = path.join(__dirname, '..', '..')
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/swift-contracts.yml'), 'utf8')

  assert.match(workflow, /DEVELOPER_DIR: \/Applications\/Xcode_16\.4\.app\/Contents\/Developer/)
  assert.match(workflow, /KAISOLA_COMPANION_XCODE_BUILD: 16F6/)
  assert.match(workflow, /KAISOLA_COMPANION_SIMULATOR_RUNTIME: com\.apple\.CoreSimulator\.SimRuntime\.iOS-18-5/)
  assert.match(workflow, /KAISOLA_COMPANION_SIMULATOR_OS: '18\.5'/)
  assert.match(workflow, /KAISOLA_COMPANION_SIMULATOR_ARCH: arm64/)
  assert.match(workflow, /runner-host\.txt/)
  assert.match(workflow, /companion-ci-test-gate\.cjs resolve-simulator/)
  assert.match(workflow, /-destination "\$\{\{ steps\.companion-simulator\.outputs\.destination \}\}"/)
  assert.equal(
    [...workflow.matchAll(/-destination "\$\{\{ steps\.companion-simulator\.outputs\.destination \}\}"/g)].length,
    3,
  )
  assert.match(workflow, /ARCHS=arm64/)
  assert.match(workflow, /ONLY_ACTIVE_ARCH=YES/)
  assert.match(workflow, /--binary "test-host-debug-dylib=.*KaisolaCompanion\.debug\.dylib"/)
  assert.match(workflow, /simulator-architecture-probe\.c/)
  assert.match(workflow, /-target "\$KAISOLA_COMPANION_SIMULATOR_ARCH-apple-ios\$KAISOLA_COMPANION_SIMULATOR_OS-simulator"/)
  assert.match(workflow, /codesign --force --sign - "\$PROBE_BINARY"/)
  assert.ok(workflow.includes('return printf("%s\\n", value.machine)'))
  assert.ok(!workflow.includes('return printf("%s\\\\n", value.machine)'))
  assert.match(workflow, /simctl spawn --arch="\$KAISOLA_COMPANION_SIMULATOR_ARCH" "\$UDID" "\$PROBE_BINARY"/)
  assert.doesNotMatch(workflow, /simctl spawn[^\n]*uname/)
  assert.match(workflow, /-resultBundlePath "\$KAISOLA_COMPANION_RESULT_BUNDLE"/)
  assert.match(workflow, /name: Run iPhone contract and app tests[\s\S]*?timeout-minutes: 12/)
  assert.match(workflow, /TEST_RUNNER_KAISOLA_COMPANION_TEST_LAUNCH_DIAGNOSTICS=1/)
  assert.match(workflow, /xcresulttool get test-results summary/)
  assert.match(workflow, /xcresulttool export diagnostics/)
  assert.match(workflow, /xcresult-diagnostics\.complete/)
  assert.match(workflow, /launch-diagnostics\.log/)
  assert.match(workflow, /--launch-diagnostics "\$KAISOLA_COMPANION_DIAGNOSTICS\/launch-diagnostics\.log"/)
  assert.match(workflow, /simctl spawn .* log show/)
  assert.match(workflow, /simctl diagnose .*--udid=/)
  assert.match(workflow, /name: Collect failed Companion simulator and crash evidence[\s\S]*?timeout-minutes: 3/)
  assert.match(workflow, /Library\/Logs\/DiagnosticReports/)
  assert.match(workflow, /uses: actions\/upload-artifact@[0-9a-f]{40}/)
  assert.match(workflow, /if-no-files-found: error/)
  assert.doesNotMatch(workflow, /-destination [^\n]*OS=latest/)
  assert.doesNotMatch(workflow, /retry/i)
})
