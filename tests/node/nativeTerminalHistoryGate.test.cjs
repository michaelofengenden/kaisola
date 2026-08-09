'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const {
  EXPECTED_SURFACE_COUNT,
  MINIMUM_SUSTAINED_SECONDS,
  WORKLOAD,
  buildQualificationReceipt,
  cadenceReportFromLog,
  parseArguments,
  snapshotFromBrokerStatus,
  validateContinuity,
  validateInteractionAttestation,
  writeJSONExclusive,
} = require('../../scripts/native-terminal-history-gate.cjs')

const MIB = 1_024 * 1_024
const sourceCommit = 'a'.repeat(40)
const helperDigest = 'b'.repeat(64)
const surfaceIDs = Array.from({ length: EXPECTED_SURFACE_COUNT }, (_, index) => `terminal-${index + 1}`)

function releaseReceipt() {
  return {
    pass: true,
    app: '/Applications/Kaisola.app',
    sourceCommit,
    bundleIdentifier: 'com.kaisola.mac',
    version: '1.2.3',
    build: '12345',
    architectures: { app: ['arm64'], node: ['arm64'], bootstrap: ['arm64'] },
    helper: { contentDigest: helperDigest },
    updatesConfigured: true,
    developerID: true,
    teamIdentifier: 'ABCDE12345',
    secureTimestamp: true,
    notarizationRequired: true,
    launchProbe: true,
  }
}

function brokerStatus(offsetDelta = 0) {
  return {
    ok: true,
    protocol: 1,
    securityEpoch: 1,
    implementationVersion: 2,
    pid: 222,
    startedAt: 1_786_000_000_000,
    contentDigest: helperDigest,
    generationState: 'current',
    terminals: surfaceIDs.map((id, index) => ({
      id,
      pid: 500 + index,
      cwd: `/secret/project-${index}`,
      owner: `secret-owner-${index}`,
      lastOwner: `secret-last-owner-${index}`,
      cols: 120,
      rows: 40,
      exited: false,
      streamEpoch: `epoch-${index}`,
      endOffset: 100_000 + index + (index === 0 ? offsetDelta : 0),
    })),
  }
}

function snapshot({ offsetDelta = 0, capturedAt = '2026-08-08T12:00:00.000Z' } = {}) {
  return snapshotFromBrokerStatus({
    status: brokerStatus(offsetDelta),
    brokerInfo: {
      pid: 222,
      startedAt: 1_786_000_000_000,
      contentDigest: helperDigest,
      protocol: 1,
      securityEpoch: 1,
      implementationVersion: 2,
      token: 'c'.repeat(64),
      socketPath: '/secret/session.sock',
    },
    release: releaseReceipt(),
    appIdentity: {
      pid: 111,
      startedAt: 'Fri Aug  8 11:55:00 2026',
      executable: '/Applications/Kaisola.app/Contents/MacOS/Kaisola',
    },
    terminalIDs: surfaceIDs,
    capturedAt,
  })
}

function interactionAttestation() {
  return {
    schemaVersion: 1,
    workload: WORKLOAD,
    inputDevice: 'physical-trackpad',
    startedAt: '2026-08-08T12:00:00.000Z',
    completedAt: '2026-08-08T12:15:00.000Z',
    durationSeconds: MINIMUM_SUSTAINED_SECONDS,
    surfaceIDs,
    transitions: Array.from({ length: 3 }, () => surfaceIDs).flat(),
    streamingTerminalID: surfaceIDs[0],
    operations: {
      liveStreaming: { passed: true, observations: 30 },
      search: { passed: true, queries: 6 },
      pageBack: { passed: true, pages: 6 },
      selection: { passed: true, selections: 3 },
      resize: { passed: true, resizes: 4 },
      tabSwitching: { passed: true, transitions: 36 },
      returnToBottom: { passed: true, returns: 6 },
    },
    uiStalls: [],
    correctnessFailures: [],
    operatorAttested: true,
  }
}

function footprintReceipt() {
  const samples = Array.from({ length: 16 }, (_, index) => ({
    capturedAt: new Date(Date.parse('2026-08-08T12:00:00.000Z') + index * 60_000).toISOString(),
    totalBytes: (300 + index) * MIB,
    requestedPIDs: [111, 222],
    exitedDescendantPIDs: [],
    processes: [
      { pid: 111, name: 'KaisolaMac', physicalFootprintBytes: 200 * MIB },
      { pid: 222, name: 'node', physicalFootprintBytes: 100 * MIB },
    ],
  }))
  return {
    schemaVersion: 1,
    label: 'installed-optimized-physical',
    workload: WORKLOAD,
    metric: {
      family: 'macOS-footprint',
      name: 'total footprint',
      source: '/usr/bin/footprint JSON',
      unit: 'byte',
    },
    roots: [111],
    explicitHelpers: [222],
    sampleIntervalMs: 60_000,
    samples,
    summary: {
      count: samples.length,
      medianBytes: 307 * MIB,
      p95Bytes: 315 * MIB,
      minimumBytes: 300 * MIB,
      maximumBytes: 315 * MIB,
      medianMiB: 307,
      p95MiB: 315,
    },
    absoluteGate: {
      statistic: 'p95',
      observedBytes: 315 * MIB,
      observedMiB: 315,
      maximumBytes: 512 * MIB,
      maximumMiB: 512,
      pass: true,
    },
    pass: true,
  }
}

function cadenceReceipt() {
  return {
    schemaVersion: 1,
    workload: WORKLOAD,
    callbackCount: 1_790,
    measurementDurationSeconds: 30.01,
    nominalFrameDurationMs: 16.666,
    p95IntervalMs: 16.9,
    maximumIntervalMs: 33.2,
    missedFrameCount: 2,
    deadlineLossMs: 33.332,
    deadlineLossRateMsPerSecond: 1.11,
    callbackCoverage: 0.994,
    thresholds: {
      maximumDeadlineLossRateMsPerSecond: 10,
      maximumP95IntervalFrames: 1.5,
      maximumIntervalMs: 100,
      minimumCallbackCoverage: 0.95,
    },
    checks: {
      deadlineLossRate: true,
      p95Interval: true,
      maximumInterval: true,
      callbackCoverage: true,
    },
    appPid: 111,
    brokerPid: 222,
    capturedAt: '2026-08-08T12:05:00.000Z',
    pass: true,
  }
}

function frameTraceReceipt() {
  const check = { observed: 0, maximum: 0, pass: true }
  return {
    schemaVersion: 1,
    label: WORKLOAD,
    targetPid: 111,
    source: 'Xcode Animation Hitches trace exported by xctrace',
    recordingDurationSeconds: 905,
    steadyIntervalSeconds: { start: 0, end: 900 },
    summaries: {
      hitches: { count: 0, durationRateMsPerSecond: 0 },
      'hitches-updates': { count: 0, p95Ms: 0 },
      'hitches-renders': { count: 0, p95Ms: 0 },
      'potential-hangs': { count: 0 },
    },
    gate: {
      checks: {
        eventCoverage: { observedHitches: 0, observedUpdateRenderEvents: 0, pass: true },
        hitchRate: { observedMsPerSecond: 0, maximumMsPerSecond: 10, pass: true },
        potentialHangs: check,
        updateP95: { observedMs: 0, maximumMs: 8.33, pass: true },
        renderP95: { observedMs: 0, maximumMs: 8.33, pass: true },
      },
      pass: true,
    },
    pass: true,
  }
}

function evidence() {
  return {
    release: { value: releaseReceipt(), sha256: '1'.repeat(64) },
    footprint: { value: footprintReceipt(), sha256: '2'.repeat(64) },
    cadence: { value: cadenceReceipt(), sha256: '3'.repeat(64) },
    frameTrace: { value: frameTraceReceipt(), sha256: '4'.repeat(64) },
    before: { value: snapshot(), sha256: '5'.repeat(64) },
    after: {
      value: snapshot({ offsetDelta: 10_000, capturedAt: '2026-08-08T12:15:00.000Z' }),
      sha256: '6'.repeat(64),
    },
    interaction: { value: interactionAttestation(), sha256: '7'.repeat(64) },
  }
}

test('snapshot sanitizes status and pins installed app, broker generation, and twelve terminals', () => {
  const value = snapshot()
  assert.equal(value.workload, WORKLOAD)
  assert.equal(value.app.pid, 111)
  assert.equal(value.broker.pid, 222)
  assert.equal(value.terminals.length, EXPECTED_SURFACE_COUNT)
  assert.deepEqual(Object.keys(value.terminals[0]).sort(), [
    'cols', 'endOffset', 'exited', 'id', 'pid', 'rows', 'streamEpoch',
  ])
  const serialized = JSON.stringify(value)
  for (const secret of ['c'.repeat(64), '/secret/', 'secret-owner']) {
    assert.equal(serialized.includes(secret), false)
  }

  assert.throws(() => snapshotFromBrokerStatus({
    status: { ...brokerStatus(), pid: 223 },
    brokerInfo: {
      pid: 222, startedAt: 1_786_000_000_000, contentDigest: helperDigest,
      protocol: 1, securityEpoch: 1, implementationVersion: 2,
      socketPath: '/secret/session.sock', token: 'c'.repeat(64),
    },
    release: releaseReceipt(),
    appIdentity: value.app,
    terminalIDs: surfaceIDs,
    capturedAt: value.capturedAt,
  }), /broker identity changed/)
  assert.throws(() => snapshotFromBrokerStatus({
    status: { ...brokerStatus(), terminals: brokerStatus().terminals.slice(0, 11) },
    brokerInfo: {
      pid: 222, startedAt: 1_786_000_000_000, contentDigest: helperDigest,
      protocol: 1, securityEpoch: 1, implementationVersion: 2,
      socketPath: '/secret/session.sock', token: 'c'.repeat(64),
    },
    release: releaseReceipt(),
    appIdentity: value.app,
    terminalIDs: surfaceIDs,
    capturedAt: value.capturedAt,
  }), /exactly 12 live terminals/)
  assert.throws(() => snapshotFromBrokerStatus({
    status: brokerStatus(),
    brokerInfo: {
      pid: 222, startedAt: 1_786_000_000_000, contentDigest: helperDigest,
      protocol: 1, securityEpoch: 1, implementationVersion: 2,
      socketPath: '/secret/session.sock', token: 'not-a-token',
    },
    release: releaseReceipt(),
    appIdentity: value.app,
    terminalIDs: surfaceIDs,
    capturedAt: value.capturedAt,
  }), /token is invalid/)
})

test('physical interaction attestation requires the complete sustained twelve-surface tour', () => {
  assert.equal(validateInteractionAttestation(interactionAttestation()).operatorAttested, true)
  assert.throws(() => validateInteractionAttestation({
    ...interactionAttestation(),
    inputDevice: 'synthetic-scroll-wheel',
  }), /physical trackpad/)
  assert.throws(() => validateInteractionAttestation({
    ...interactionAttestation(),
    transitions: surfaceIDs,
  }), /transition tour/)
  assert.throws(() => validateInteractionAttestation({
    ...interactionAttestation(),
    operations: {
      ...interactionAttestation().operations,
      pageBack: { passed: false, pages: 0 },
    },
  }), /pageBack/)
  assert.throws(() => validateInteractionAttestation({
    ...interactionAttestation(),
    uiStalls: [{ at: 20, description: 'frozen' }],
  }), /UI stalls/)
  assert.throws(() => validateInteractionAttestation({
    ...interactionAttestation(),
    durationSeconds: MINIMUM_SUSTAINED_SECONDS - 1,
  }), /15 minutes/)
})

test('continuity rejects app, broker, PTY, generation, and cursor discontinuity', () => {
  const before = snapshot()
  const after = snapshot({ offsetDelta: 10_000, capturedAt: '2026-08-08T12:15:00.000Z' })
  const result = validateContinuity(before, after, surfaceIDs[0])
  assert.equal(result.pass, true)
  assert.equal(result.streamingDeltaBytes, 10_000)

  for (const candidate of [
    { ...after, app: { ...after.app, pid: 112 } },
    { ...after, broker: { ...after.broker, startedAt: after.broker.startedAt + 1 } },
    { ...after, terminals: after.terminals.map((row, index) => index ? row : { ...row, pid: 999 }) },
    { ...after, terminals: after.terminals.map((row, index) => index ? row : { ...row, streamEpoch: 'new' }) },
    { ...after, terminals: after.terminals.map((row, index) => index ? row : { ...row, endOffset: 1 }) },
  ]) {
    assert.throws(() => validateContinuity(before, candidate, surfaceIDs[0]), /continuity/)
  }
})

test('final receipt validates every evidence family and exposes only sealed summaries', () => {
  const receipt = buildQualificationReceipt(evidence())
  assert.equal(receipt.pass, true)
  assert.equal(receipt.sourceCommit, sourceCommit)
  assert.equal(receipt.continuity.streamingDeltaBytes, 10_000)
  assert.deepEqual(Object.keys(receipt.evidence), [
    'release', 'footprint', 'cadence', 'frameTrace', 'before', 'after', 'interaction',
  ])
  assert.equal(JSON.stringify(receipt).includes('/secret/'), false)
  assert.equal(JSON.stringify(receipt).includes('/tmp/'), false)

  const weakFootprint = evidence()
  weakFootprint.footprint.value = {
    ...weakFootprint.footprint.value,
    samples: weakFootprint.footprint.value.samples.slice(0, 15),
    summary: { ...weakFootprint.footprint.value.summary, count: 15 },
  }
  assert.throws(() => buildQualificationReceipt(weakFootprint), /15-minute footprint/)

  const unsigned = evidence()
  unsigned.release.value = { ...unsigned.release.value, developerID: false }
  assert.throws(() => buildQualificationReceipt(unsigned), /signed, timestamped, and notarized/)

  const wrongWorkload = evidence()
  wrongWorkload.cadence.value = { ...wrongWorkload.cadence.value, workload: 'isolated-fixture' }
  assert.throws(() => buildQualificationReceipt(wrongWorkload), /cadence workload/)

  const shortTrace = evidence()
  shortTrace.frameTrace.value = {
    ...shortTrace.frameTrace.value,
    recordingDurationSeconds: 30,
  }
  assert.throws(() => buildQualificationReceipt(shortTrace), /15-minute frame trace/)

  const permissiveTrace = evidence()
  permissiveTrace.frameTrace.value = {
    ...permissiveTrace.frameTrace.value,
    gate: {
      ...permissiveTrace.frameTrace.value.gate,
      checks: {
        ...permissiveTrace.frameTrace.value.gate.checks,
        hitchRate: {
          observedMsPerSecond: 0,
          maximumMsPerSecond: 100,
          pass: true,
        },
      },
    },
  }
  assert.throws(() => buildQualificationReceipt(permissiveTrace), /frame trace check is inconsistent/)
})

test('cadence extraction accepts one exact installed-workspace receipt', () => {
  const report = cadenceReceipt()
  assert.deepEqual(cadenceReportFromLog(
    `noise\nKAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=${JSON.stringify(report)}\n`,
  ), report)
  assert.throws(() => cadenceReportFromLog(
    'KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=FAIL display-link-timeout\n',
  ), /display-link-timeout/)
  assert.throws(() => cadenceReportFromLog([
    `KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=${JSON.stringify(report)}\n`,
    `KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=${JSON.stringify(report)}\n`,
  ].join('')), /exactly one/)
})

test('CLI is fail-closed and final output cannot overwrite prior evidence', () => {
  const terminalArguments = surfaceIDs.flatMap((id) => ['--terminal-id', id])
  assert.deepEqual(parseArguments(['snapshot',
    '--release', '/tmp/release.json',
    '--app-pid', '111',
    '--broker-info', '/tmp/broker.json',
    '--output', '/tmp/before.json',
    ...terminalArguments,
  ]), {
    command: 'snapshot',
    release: '/tmp/release.json',
    appPid: 111,
    brokerInfo: '/tmp/broker.json',
    output: '/tmp/before.json',
    terminalIDs: surfaceIDs,
  })
  assert.throws(() => parseArguments(['snapshot', '--output', '/tmp/x']), /exactly 12/)
  assert.throws(() => parseArguments(['finalize', '--mystery', 'x']), /unknown argument/)
  assert.throws(() => parseArguments([
    'extract-cadence', '--input', '/tmp/a', '--input', '/tmp/b', '--output', '/tmp/c',
  ]), /duplicate argument/)
  assert.deepEqual(parseArguments([
    'extract-cadence', '--input', '/tmp/app.log', '--output', '/tmp/cadence.json',
  ]), {
    command: 'extract-cadence',
    input: '/tmp/app.log',
    output: '/tmp/cadence.json',
  })

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-history-gate-test-'))
  const output = path.join(root, 'receipt.json')
  try {
    writeJSONExclusive(output, { pass: true })
    assert.equal(JSON.parse(fs.readFileSync(output, 'utf8')).pass, true)
    assert.throws(() => writeJSONExclusive(output, { pass: false }), /already exists/)
    assert.equal(JSON.parse(fs.readFileSync(output, 'utf8')).pass, true)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
