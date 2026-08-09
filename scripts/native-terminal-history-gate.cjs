#!/usr/bin/env node
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const { requestBrokerControl } = require('../runtime/node-broker/ipc/brokerControlClient.cjs')
const { validateReport: validateFrameCadenceReport } = require('./native-frame-cadence-gate.cjs')

const SCHEMA_VERSION = 1
const WORKLOAD = 'terminal-history-sustained-12-surface-v1'
const QUALIFICATION = 'installed-optimized-terminal-history-v1'
const EXPECTED_SURFACE_COUNT = 12
const MINIMUM_SUSTAINED_SECONDS = 15 * 60
const MINIMUM_TRANSITIONS = EXPECTED_SURFACE_COUNT * 3
const MAXIMUM_P95_BYTES = 512 * 1_024 * 1_024
const REQUIRED_APP = '/Applications/Kaisola.app'
const REQUIRED_EXECUTABLE = `${REQUIRED_APP}/Contents/MacOS/Kaisola`
const EVIDENCE_KEYS = Object.freeze([
  'release',
  'footprint',
  'cadence',
  'frameTrace',
  'before',
  'after',
  'interaction',
])

function fail(message) {
  throw new Error(message)
}

function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`)
  return value
}

function positiveInteger(value, label) {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number <= 0) fail(`${label} must be a positive integer`)
  return number
}

function nonnegativeInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} must be a nonnegative integer`)
  return value
}

function exactISODate(value, label) {
  if (typeof value !== 'string' || !value || !Number.isFinite(Date.parse(value))) {
    fail(`${label} must be an ISO date`)
  }
  if (new Date(value).toISOString() !== value) fail(`${label} must be a canonical ISO date`)
  return value
}

function exactString(value, label) {
  if (typeof value !== 'string' || !value || value !== value.trim()) fail(`${label} must be a nonempty exact string`)
  return value
}

function exactStringSet(values, count, label) {
  if (!Array.isArray(values) || values.length !== count) fail(`${label} must contain exactly ${count} entries`)
  const normalized = values.map((value, index) => exactString(value, `${label}[${index}]`))
  if (new Set(normalized).size !== count) fail(`${label} must contain ${count} unique entries`)
  return normalized
}

function sameStrings(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index])
}

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right, 'en'))
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

function validateReleaseReceipt(value) {
  const release = object(value, 'release receipt')
  if (release.pass !== true
      || release.app !== REQUIRED_APP
      || release.bundleIdentifier !== 'com.kaisola.mac'
      || release.developerID !== true
      || release.secureTimestamp !== true
      || release.notarizationRequired !== true
      || release.launchProbe !== true) {
    fail('release receipt must describe the installed, signed, timestamped, and notarized Kaisola app')
  }
  if (release.updatesConfigured !== true || typeof release.teamIdentifier !== 'string' || !release.teamIdentifier) {
    fail('release receipt must include distribution update and Developer ID team evidence')
  }
  if (!/^[0-9a-f]{40}$/u.test(release.sourceCommit || '')) fail('release receipt has no exact source commit')
  for (const component of ['app', 'node', 'bootstrap']) {
    if (!sameStrings(release.architectures?.[component] || [], ['arm64'])) {
      fail(`release receipt architecture drifted: ${component}`)
    }
  }
  if (!/^[0-9a-f]{64}$/u.test(release.helper?.contentDigest || '')) {
    fail('release receipt has no broker helper content digest')
  }
  exactString(release.version, 'release version')
  exactString(release.build, 'release build')
  return release
}

function validateAppIdentity(value) {
  const app = object(value, 'app identity')
  const pid = positiveInteger(app.pid, 'app pid')
  const startedAt = exactString(app.startedAt, 'app start identity')
  if (app.executable !== REQUIRED_EXECUTABLE) fail('app identity is not the installed Kaisola executable')
  return { pid, startedAt, executable: REQUIRED_EXECUTABLE }
}

function validateBrokerInfo(value, release) {
  const info = object(value, 'broker info')
  positiveInteger(info.pid, 'broker info pid')
  positiveInteger(info.startedAt, 'broker info start identity')
  for (const field of ['protocol', 'securityEpoch', 'implementationVersion']) {
    positiveInteger(info[field], `broker info ${field}`)
  }
  if (info.contentDigest !== release.helper.contentDigest) {
    fail('broker info does not match the installed helper digest')
  }
  if (typeof info.socketPath !== 'string'
      || !path.isAbsolute(info.socketPath)
      || info.socketPath.includes('\0')) {
    fail('broker info socket path is invalid')
  }
  if (!/^[0-9a-f]{64}$/u.test(info.token || '')) fail('broker info token is invalid')
  return info
}

function sanitizeTerminal(row, index) {
  object(row, `broker terminal ${index}`)
  const id = exactString(row.id, `broker terminal ${index} id`)
  const pid = positiveInteger(row.pid, `broker terminal ${id} pid`)
  const streamEpoch = exactString(row.streamEpoch, `broker terminal ${id} stream epoch`)
  const endOffset = nonnegativeInteger(row.endOffset, `broker terminal ${id} end offset`)
  const cols = positiveInteger(row.cols, `broker terminal ${id} columns`)
  const rows = positiveInteger(row.rows, `broker terminal ${id} rows`)
  if (row.exited !== false) fail(`broker terminal ${id} is not live`)
  return { id, pid, cols, rows, exited: false, streamEpoch, endOffset }
}

function snapshotFromBrokerStatus({ status, brokerInfo, release, appIdentity, terminalIDs, capturedAt }) {
  const cleanRelease = validateReleaseReceipt(release)
  const cleanApp = validateAppIdentity(appIdentity)
  exactISODate(capturedAt, 'snapshot capture time')
  object(status, 'broker status')
  const cleanBrokerInfo = validateBrokerInfo(brokerInfo, cleanRelease)

  const statusIdentity = [
    status.pid, status.startedAt, status.contentDigest,
    status.protocol, status.securityEpoch, status.implementationVersion,
  ]
  const infoIdentity = [
    cleanBrokerInfo.pid, cleanBrokerInfo.startedAt, cleanBrokerInfo.contentDigest,
    cleanBrokerInfo.protocol, cleanBrokerInfo.securityEpoch, cleanBrokerInfo.implementationVersion,
  ]
  if (status.ok !== true
      || status.generationState !== 'current'
      || !sameStrings(statusIdentity.map(String), infoIdentity.map(String))
      || status.contentDigest !== cleanRelease.helper.contentDigest) {
    fail('broker identity changed or does not match the installed helper')
  }
  const brokerPid = positiveInteger(status.pid, 'broker pid')
  const brokerStartedAt = positiveInteger(status.startedAt, 'broker start identity')
  if (!Number.isSafeInteger(status.protocol) || status.protocol <= 0
      || !Number.isSafeInteger(status.securityEpoch) || status.securityEpoch <= 0
      || !Number.isSafeInteger(status.implementationVersion) || status.implementationVersion <= 0) {
    fail('broker protocol identity is incomplete')
  }

  const selectedIDs = exactStringSet(terminalIDs, EXPECTED_SURFACE_COUNT, 'snapshot terminal IDs')
  if (!Array.isArray(status.terminals)) fail('broker status contains no terminal diagnostics')
  const statusByID = new Map(status.terminals.map((row) => [row?.id, row]))
  const terminals = selectedIDs.map((id, index) => {
    const row = statusByID.get(id)
    if (!row) fail('snapshot requires exactly 12 live terminals from the selected surface set')
    return sanitizeTerminal(row, index)
  })
  terminals.sort((left, right) => left.id.localeCompare(right.id, 'en'))

  return {
    schemaVersion: SCHEMA_VERSION,
    workload: WORKLOAD,
    capturedAt,
    sourceCommit: cleanRelease.sourceCommit,
    app: cleanApp,
    broker: {
      pid: brokerPid,
      startedAt: brokerStartedAt,
      contentDigest: status.contentDigest,
      protocol: status.protocol,
      securityEpoch: status.securityEpoch,
      implementationVersion: status.implementationVersion,
    },
    terminals,
  }
}

function validateSnapshot(value, label) {
  const snapshot = object(value, `${label} snapshot`)
  if (snapshot.schemaVersion !== SCHEMA_VERSION || snapshot.workload !== WORKLOAD) {
    fail(`${label} snapshot contract drifted`)
  }
  exactISODate(snapshot.capturedAt, `${label} capture time`)
  if (!/^[0-9a-f]{40}$/u.test(snapshot.sourceCommit || '')) fail(`${label} snapshot source commit is invalid`)
  snapshot.app = validateAppIdentity(snapshot.app)
  const broker = object(snapshot.broker, `${label} broker identity`)
  positiveInteger(broker.pid, `${label} broker pid`)
  positiveInteger(broker.startedAt, `${label} broker start identity`)
  if (!/^[0-9a-f]{64}$/u.test(broker.contentDigest || '')) fail(`${label} broker digest is invalid`)
  for (const field of ['protocol', 'securityEpoch', 'implementationVersion']) {
    positiveInteger(broker[field], `${label} broker ${field}`)
  }
  if (!Array.isArray(snapshot.terminals) || snapshot.terminals.length !== EXPECTED_SURFACE_COUNT) {
    fail(`${label} snapshot does not contain exactly 12 terminals`)
  }
  snapshot.terminals = snapshot.terminals.map(sanitizeTerminal)
  const identifiers = snapshot.terminals.map((row) => row.id)
  if (new Set(identifiers).size !== EXPECTED_SURFACE_COUNT || !sameStrings(identifiers, sorted(identifiers))) {
    fail(`${label} snapshot terminal IDs are not unique and canonical`)
  }
  return snapshot
}

function validateInteractionAttestation(value) {
  const attestation = object(value, 'interaction attestation')
  if (attestation.schemaVersion !== SCHEMA_VERSION || attestation.workload !== WORKLOAD) {
    fail('interaction attestation contract drifted')
  }
  if (attestation.inputDevice !== 'physical-trackpad') {
    fail('interaction gate requires a physical trackpad')
  }
  const startedAt = exactISODate(attestation.startedAt, 'interaction start')
  const completedAt = exactISODate(attestation.completedAt, 'interaction completion')
  const elapsedSeconds = (Date.parse(completedAt) - Date.parse(startedAt)) / 1_000
  if (!(attestation.durationSeconds >= MINIMUM_SUSTAINED_SECONDS)
      || Math.abs(attestation.durationSeconds - elapsedSeconds) > 1) {
    fail('interaction gate requires a coherent 15 minutes of sustained operation')
  }
  const surfaces = exactStringSet(attestation.surfaceIDs, EXPECTED_SURFACE_COUNT, 'interaction surface IDs')
  const surfaceSet = new Set(surfaces)
  if (!Array.isArray(attestation.transitions)
      || attestation.transitions.length < MINIMUM_TRANSITIONS
      || attestation.transitions.some((id) => !surfaceSet.has(id))) {
    fail('interaction transition tour must cross the retained-surface bound repeatedly')
  }
  const visits = new Map(surfaces.map((id) => [id, 0]))
  for (const id of attestation.transitions) visits.set(id, visits.get(id) + 1)
  if ([...visits.values()].some((count) => count < 2)) {
    fail('interaction transition tour must revisit every surface')
  }
  if (!surfaceSet.has(attestation.streamingTerminalID)) fail('streaming terminal is outside the surface set')

  const operations = object(attestation.operations, 'interaction operations')
  const requiredOperations = {
    liveStreaming: ['observations', 1],
    search: ['queries', 1],
    pageBack: ['pages', 2],
    selection: ['selections', 1],
    resize: ['resizes', 2],
    tabSwitching: ['transitions', MINIMUM_TRANSITIONS],
    returnToBottom: ['returns', 1],
  }
  for (const [name, [countKey, minimum]] of Object.entries(requiredOperations)) {
    const operation = object(operations[name], `interaction operation ${name}`)
    if (operation.passed !== true || !Number.isSafeInteger(operation[countKey]) || operation[countKey] < minimum) {
      fail(`interaction operation ${name} did not pass its minimum count`)
    }
  }
  if (!Array.isArray(attestation.uiStalls) || attestation.uiStalls.length !== 0) {
    fail('interaction attestation reports UI stalls')
  }
  if (!Array.isArray(attestation.correctnessFailures) || attestation.correctnessFailures.length !== 0) {
    fail('interaction attestation reports correctness failures')
  }
  if (attestation.operatorAttested !== true) fail('interaction attestation is not operator-attested')
  return attestation
}

function validateContinuity(beforeValue, afterValue, streamingTerminalID) {
  const before = validateSnapshot(beforeValue, 'before')
  const after = validateSnapshot(afterValue, 'after')
  const failContinuity = (detail) => fail(`terminal continuity failed: ${detail}`)
  if (before.sourceCommit !== after.sourceCommit
      || JSON.stringify(before.app) !== JSON.stringify(after.app)
      || JSON.stringify(before.broker) !== JSON.stringify(after.broker)) {
    failContinuity('app or broker generation changed')
  }
  const elapsedSeconds = (Date.parse(after.capturedAt) - Date.parse(before.capturedAt)) / 1_000
  if (elapsedSeconds < MINIMUM_SUSTAINED_SECONDS) failContinuity('capture interval was shorter than 15 minutes')
  const beforeByID = new Map(before.terminals.map((row) => [row.id, row]))
  const afterByID = new Map(after.terminals.map((row) => [row.id, row]))
  if (!sameStrings([...beforeByID.keys()], [...afterByID.keys()])) failContinuity('terminal set changed')
  const deltas = {}
  for (const [id, first] of beforeByID) {
    const last = afterByID.get(id)
    if (!last || first.pid !== last.pid || first.streamEpoch !== last.streamEpoch) {
      failContinuity(`PTY or stream epoch changed for ${id}`)
    }
    if (last.endOffset < first.endOffset) failContinuity(`cursor regressed for ${id}`)
    deltas[id] = last.endOffset - first.endOffset
  }
  if (!beforeByID.has(streamingTerminalID)) failContinuity('streaming terminal is missing')
  if (deltas[streamingTerminalID] < 1_024) failContinuity('streaming terminal did not advance')
  return {
    pass: true,
    elapsedSeconds,
    appPid: before.app.pid,
    brokerPid: before.broker.pid,
    brokerStartedAt: before.broker.startedAt,
    terminalCount: before.terminals.length,
    streamingTerminalID,
    streamingDeltaBytes: deltas[streamingTerminalID],
    minimumTerminalDeltaBytes: Math.min(...Object.values(deltas)),
  }
}

function percentile(values, fraction) {
  const ordered = [...values].sort((left, right) => left - right)
  return ordered[Math.max(0, Math.ceil(ordered.length * fraction) - 1)]
}

function validateFootprintReceipt(value, continuity) {
  const report = object(value, 'footprint receipt')
  if (report.schemaVersion !== SCHEMA_VERSION
      || report.label !== 'installed-optimized-physical'
      || report.workload !== WORKLOAD
      || report.metric?.family !== 'macOS-footprint'
      || report.metric?.name !== 'total footprint'
      || report.metric?.source !== '/usr/bin/footprint JSON'
      || report.metric?.unit !== 'byte') {
    fail('footprint receipt does not use the sustained physical-footprint contract')
  }
  if (!sameStrings(report.roots || [], [continuity.appPid])
      || !Array.isArray(report.explicitHelpers)
      || !report.explicitHelpers.includes(continuity.brokerPid)) {
    fail('footprint receipt did not measure the exact app and broker processes')
  }
  if (!Array.isArray(report.samples) || report.samples.length < 16
      || report.summary?.count !== report.samples.length) {
    fail('15-minute footprint capture requires at least 16 complete samples')
  }
  let previousTime = 0
  const totals = report.samples.map((sample, index) => {
    object(sample, `footprint sample ${index}`)
    const capturedAt = exactISODate(sample.capturedAt, `footprint sample ${index} capture time`)
    const capturedTime = Date.parse(capturedAt)
    if (capturedTime <= previousTime) fail('footprint sample times must be strictly increasing')
    previousTime = capturedTime
    nonnegativeInteger(sample.totalBytes, `footprint sample ${index} total bytes`)
    if (!Array.isArray(sample.requestedPIDs)
        || !sample.requestedPIDs.includes(continuity.appPid)
        || !sample.requestedPIDs.includes(continuity.brokerPid)) {
      fail('footprint sample omitted the app or broker process')
    }
    const measured = new Set((sample.processes || []).map((process) => process?.pid))
    if (!measured.has(continuity.appPid) || !measured.has(continuity.brokerPid)) {
      fail('footprint sample did not resolve the app or broker process')
    }
    return sample.totalBytes
  })
  const spanSeconds = (
    Date.parse(report.samples.at(-1).capturedAt) - Date.parse(report.samples[0].capturedAt)
  ) / 1_000
  if (spanSeconds < MINIMUM_SUSTAINED_SECONDS) fail('15-minute footprint capture is too short')
  const expectedSummary = {
    count: totals.length,
    medianBytes: percentile(totals, 0.5),
    p95Bytes: percentile(totals, 0.95),
    minimumBytes: Math.min(...totals),
    maximumBytes: Math.max(...totals),
  }
  for (const [key, expected] of Object.entries(expectedSummary)) {
    if (report.summary?.[key] !== expected) fail(`footprint summary is inconsistent: ${key}`)
  }
  if (report.absoluteGate?.statistic !== 'p95'
      || report.absoluteGate.observedBytes !== expectedSummary.p95Bytes
      || report.absoluteGate.maximumBytes !== MAXIMUM_P95_BYTES
      || report.absoluteGate.pass !== (expectedSummary.p95Bytes <= MAXIMUM_P95_BYTES)
      || report.pass !== true
      || report.absoluteGate.pass !== true) {
    fail('footprint p95 did not pass the fixed 512 MiB ceiling')
  }
  return { report, spanSeconds }
}

function validateCadenceReceipt(value, continuity, interaction) {
  const report = validateFrameCadenceReport(value, WORKLOAD)
  if (report.pass !== true) fail('frame cadence gate did not pass')
  if (report.appPid !== continuity.appPid || report.brokerPid !== continuity.brokerPid) {
    fail('frame cadence receipt does not belong to the qualified app and broker')
  }
  const capturedAt = exactISODate(report.capturedAt, 'frame cadence capture time')
  if (Date.parse(capturedAt) < Date.parse(interaction.startedAt)
      || Date.parse(capturedAt) > Date.parse(interaction.completedAt)) {
    fail('frame cadence receipt falls outside the physical interaction interval')
  }
  return report
}

function cadenceReportFromLog(value) {
  const matches = [...String(value).matchAll(
    /^KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=([^\r\n]+)\r?$/gmu,
  )]
  if (matches.length !== 1) fail('cadence log must contain exactly one complete receipt')
  if (matches[0][1].startsWith('FAIL ')) fail(matches[0][1])
  let report
  try {
    report = JSON.parse(matches[0][1])
  } catch {
    fail('cadence log contains malformed receipt JSON')
  }
  validateFrameCadenceReport(report, WORKLOAD)
  return report
}

function validateFrameTraceReceipt(value, continuity) {
  const report = object(value, 'frame trace receipt')
  if (report.schemaVersion !== SCHEMA_VERSION
      || report.label !== WORKLOAD
      || report.source !== 'Xcode Animation Hitches trace exported by xctrace'
      || report.targetPid !== continuity.appPid) {
    fail('frame trace receipt does not belong to the qualified workload and app')
  }
  if (!(report.recordingDurationSeconds >= MINIMUM_SUSTAINED_SECONDS)
      || report.steadyIntervalSeconds?.start !== 0
      || !(report.steadyIntervalSeconds?.end >= MINIMUM_SUSTAINED_SECONDS)
      || report.steadyIntervalSeconds.end > report.recordingDurationSeconds) {
    fail('qualification requires a 15-minute frame trace')
  }
  const checks = report.gate?.checks
  const summaries = report.summaries
  if (!checks || !summaries) fail('frame trace receipt is incomplete')
  const expectedChecks = {
    eventCoverage: {
      observedHitches: summaries.hitches?.count,
      observedUpdateRenderEvents:
        summaries['hitches-updates']?.count + summaries['hitches-renders']?.count,
    },
    hitchRate: {
      observedMsPerSecond: summaries.hitches?.durationRateMsPerSecond,
      maximumMsPerSecond: 10,
    },
    potentialHangs: {
      observed: summaries['potential-hangs']?.count,
      maximum: 0,
    },
    updateP95: {
      observedMs: summaries['hitches-updates']?.p95Ms,
      maximumMs: 8.33,
    },
    renderP95: {
      observedMs: summaries['hitches-renders']?.p95Ms,
      maximumMs: 8.33,
    },
  }
  const calculatedPasses = {
    eventCoverage: expectedChecks.eventCoverage.observedHitches === 0
      || expectedChecks.eventCoverage.observedUpdateRenderEvents > 0,
    hitchRate: expectedChecks.hitchRate.observedMsPerSecond <= 10,
    potentialHangs: expectedChecks.potentialHangs.observed <= 0,
    updateP95: expectedChecks.updateP95.observedMs <= 8.33,
    renderP95: expectedChecks.renderP95.observedMs <= 8.33,
  }
  for (const [name, expected] of Object.entries(expectedChecks)) {
    const check = checks[name]
    if (!check || Object.entries(expected).some(([key, value]) => check[key] !== value)
        || check.pass !== calculatedPasses[name]) {
      fail(`frame trace check is inconsistent: ${name}`)
    }
  }
  const calculatedPass = Object.values(calculatedPasses).every(Boolean)
  if (report.pass !== calculatedPass || report.gate?.pass !== calculatedPass || !calculatedPass) {
    fail('frame trace contains a hitch, hang, update, or render gate failure')
  }
  return report
}

function validateEvidenceEnvelope(value, key) {
  const envelope = object(value, `${key} evidence`)
  if (!/^[0-9a-f]{64}$/u.test(envelope.sha256 || '')) fail(`${key} evidence has no SHA-256 seal`)
  return envelope
}

function buildQualificationReceipt(input) {
  object(input, 'qualification evidence')
  const evidence = Object.fromEntries(EVIDENCE_KEYS.map((key) => [key, validateEvidenceEnvelope(input[key], key)]))
  const release = validateReleaseReceipt(evidence.release.value)
  const interaction = validateInteractionAttestation(evidence.interaction.value)
  const continuity = validateContinuity(
    evidence.before.value,
    evidence.after.value,
    interaction.streamingTerminalID,
  )
  for (const snapshot of [evidence.before.value, evidence.after.value]) {
    if (snapshot.sourceCommit !== release.sourceCommit
        || snapshot.broker.contentDigest !== release.helper.contentDigest) {
      fail('snapshot does not match the release source and helper generation')
    }
  }
  if (!sameStrings(sorted(interaction.surfaceIDs), evidence.before.value.terminals.map((row) => row.id))) {
    fail('interaction surfaces do not match the continuity snapshot')
  }
  if (Math.abs(Date.parse(interaction.startedAt) - Date.parse(evidence.before.value.capturedAt)) > 5_000
      || Math.abs(Date.parse(interaction.completedAt) - Date.parse(evidence.after.value.capturedAt)) > 5_000) {
    fail('interaction interval does not align with the continuity snapshots')
  }
  const footprint = validateFootprintReceipt(evidence.footprint.value, continuity)
  const cadence = validateCadenceReceipt(evidence.cadence.value, continuity, interaction)
  const frameTrace = validateFrameTraceReceipt(evidence.frameTrace.value, continuity)
  const footprintStart = Date.parse(footprint.report.samples[0].capturedAt)
  const footprintEnd = Date.parse(footprint.report.samples.at(-1).capturedAt)
  if (footprintStart < Date.parse(interaction.startedAt)
      || footprintEnd > Date.parse(interaction.completedAt)) {
    fail('footprint samples fall outside the physical interaction interval')
  }

  return {
    schemaVersion: SCHEMA_VERSION,
    qualification: QUALIFICATION,
    workload: WORKLOAD,
    sourceCommit: release.sourceCommit,
    app: {
      version: release.version,
      build: release.build,
      pid: continuity.appPid,
      executable: REQUIRED_EXECUTABLE,
    },
    interval: {
      startedAt: interaction.startedAt,
      completedAt: interaction.completedAt,
      durationSeconds: interaction.durationSeconds,
    },
    surfaces: {
      count: EXPECTED_SURFACE_COUNT,
      ids: sorted(interaction.surfaceIDs),
      transitionCount: interaction.transitions.length,
    },
    measurements: {
      physicalFootprint: {
        sampleCount: footprint.report.summary.count,
        sampleSpanSeconds: footprint.spanSeconds,
        medianBytes: footprint.report.summary.medianBytes,
        p95Bytes: footprint.report.summary.p95Bytes,
        maximumBytes: footprint.report.summary.maximumBytes,
        maximumP95Bytes: MAXIMUM_P95_BYTES,
      },
      frameCadence: {
        callbackCount: cadence.callbackCount,
        measurementDurationSeconds: cadence.measurementDurationSeconds,
        p95IntervalMs: cadence.p95IntervalMs,
        maximumIntervalMs: cadence.maximumIntervalMs,
        deadlineLossRateMsPerSecond: cadence.deadlineLossRateMsPerSecond,
        callbackCoverage: cadence.callbackCoverage,
      },
      frameTrace: {
        recordingDurationSeconds: frameTrace.recordingDurationSeconds,
        steadyIntervalSeconds: frameTrace.steadyIntervalSeconds,
        checks: Object.fromEntries(Object.entries(frameTrace.gate.checks).map(([key, check]) => [key, check.pass])),
      },
      interaction: {
        inputDevice: 'physical-trackpad',
        operations: Object.fromEntries(Object.entries(interaction.operations).map(([key, operation]) => [
          key,
          Object.fromEntries(Object.entries(operation).filter(([field]) => field === 'passed' || field !== 'notes')),
        ])),
        uiStallCount: 0,
        correctnessFailureCount: 0,
        operatorAttested: true,
      },
    },
    continuity,
    evidence: Object.fromEntries(EVIDENCE_KEYS.map((key) => [key, { sha256: evidence[key].sha256 }])),
    pass: true,
  }
}

function safeReadJSON(file, label) {
  const stat = fs.lstatSync(file)
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be one real JSON file`)
  const bytes = fs.readFileSync(file)
  let value
  try {
    value = JSON.parse(bytes)
  } catch {
    fail(`${label} contains malformed JSON`)
  }
  return { value, sha256: sha256(bytes) }
}

function safeReadBrokerInfo(file) {
  const stat = fs.lstatSync(file)
  if (!stat.isFile() || stat.isSymbolicLink()
      || stat.uid !== process.getuid()
      || (stat.mode & 0o077) !== 0) {
    fail('broker info must be one private, user-owned regular file')
  }
  return safeReadJSON(file, 'broker info')
}

function writeJSONExclusive(destination, value) {
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  if (fs.existsSync(destination)) fail(`output already exists: ${destination}`)
  const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}.${process.pid}.${crypto.randomUUID()}.tmp`)
  try {
    const descriptor = fs.openSync(temporary, 'wx', 0o644)
    try {
      fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`)
      fs.fsyncSync(descriptor)
    } finally {
      fs.closeSync(descriptor)
    }
    try {
      fs.linkSync(temporary, destination)
    } catch (error) {
      if (error?.code === 'EEXIST') fail(`output already exists: ${destination}`)
      throw error
    }
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

function nextValue(argv, index, argument) {
  const value = argv[index + 1]
  if (value == null || value.startsWith('--')) fail(`${argument} requires a value`)
  return value
}

function parseArguments(argv) {
  const command = argv[0]
  if (command === '--help' || command === '-h') return { help: true }
  if (!['snapshot', 'extract-cadence', 'finalize'].includes(command)) {
    fail('command must be snapshot, extract-cadence, or finalize')
  }
  const options = { command, ...(command === 'snapshot' ? { terminalIDs: [] } : {}) }
  const pathFlags = command === 'snapshot'
    ? new Map([['--release', 'release'], ['--broker-info', 'brokerInfo'], ['--output', 'output']])
    : command === 'extract-cadence'
      ? new Map([['--input', 'input'], ['--output', 'output']])
    : new Map([
        ['--release', 'release'], ['--footprint', 'footprint'], ['--cadence', 'cadence'],
        ['--frame-trace', 'frameTrace'], ['--before', 'before'], ['--after', 'after'],
        ['--interaction', 'interaction'], ['--output', 'output'],
      ])
  const seen = new Set()
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') options.help = true
    else if (argument === '--terminal-id' && command === 'snapshot') {
      options.terminalIDs.push(exactString(nextValue(argv, index, argument), argument))
      index += 1
    }
    else if (argument === '--app-pid' && command === 'snapshot') {
      if (seen.has(argument)) fail(`duplicate argument: ${argument}`)
      seen.add(argument)
      options.appPid = positiveInteger(nextValue(argv, index, argument), argument)
      index += 1
    } else if (pathFlags.has(argument)) {
      if (seen.has(argument)) fail(`duplicate argument: ${argument}`)
      seen.add(argument)
      options[pathFlags.get(argument)] = path.resolve(nextValue(argv, index, argument))
      index += 1
    } else fail(`unknown argument: ${argument}`)
  }
  if (options.help) return options
  if (command === 'snapshot' && options.terminalIDs.length !== EXPECTED_SURFACE_COUNT) {
    fail('snapshot requires exactly 12 --terminal-id values')
  }
  if (command === 'snapshot' && new Set(options.terminalIDs).size !== EXPECTED_SURFACE_COUNT) {
    fail('snapshot --terminal-id values must be unique')
  }
  const required = command === 'snapshot'
    ? ['release', 'appPid', 'brokerInfo', 'output']
    : command === 'extract-cadence'
      ? ['input', 'output']
    : [...EVIDENCE_KEYS, 'output']
  const missing = required.filter((key) => options[key] == null)
  if (missing.length) fail(`${command} required arguments: ${missing.map((key) => `--${key.replace(/[A-Z]/gu, (letter) => `-${letter.toLowerCase()}`)}`).join(', ')}`)
  return options
}

function processIdentity(pid) {
  const read = (field) => execFileSync('/bin/ps', ['-p', String(pid), '-o', `${field}=`], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim()
  const startedAt = read('lstart')
  const executable = read('comm')
  return validateAppIdentity({ pid, startedAt, executable })
}

function sameBrokerInfo(before, after) {
  return [
    'pid', 'startedAt', 'contentDigest', 'protocol', 'securityEpoch',
    'implementationVersion', 'socketPath', 'token',
  ].every((field) => before[field] === after[field])
}

async function captureSnapshot(options) {
  const release = safeReadJSON(options.release, 'release receipt').value
  validateReleaseReceipt(release)
  const infoBefore = safeReadBrokerInfo(options.brokerInfo).value
  validateBrokerInfo(infoBefore, release)
  const appBefore = processIdentity(options.appPid)
  const protocol = positiveInteger(infoBefore.protocol, 'broker info protocol')
  const status = await requestBrokerControl(infoBefore, {
    protocol,
    appVersion: release.version,
    method: 'broker.status',
  })
  const infoAfter = safeReadBrokerInfo(options.brokerInfo).value
  validateBrokerInfo(infoAfter, release)
  const appAfter = processIdentity(options.appPid)
  if (!sameBrokerInfo(infoBefore, infoAfter) || JSON.stringify(appBefore) !== JSON.stringify(appAfter)) {
    fail('app or broker identity changed while capturing the snapshot')
  }
  return snapshotFromBrokerStatus({
    status,
    brokerInfo: infoAfter,
    release,
    appIdentity: appAfter,
    terminalIDs: options.terminalIDs,
    capturedAt: new Date().toISOString(),
  })
}

function usage() {
  return `Usage:
  node scripts/native-terminal-history-gate.cjs snapshot \\
    --release release.json --app-pid PID --broker-info broker.json \\
    --terminal-id ID ... (exactly 12) --output before.json

  node scripts/native-terminal-history-gate.cjs extract-cadence \\
    --input installed-app.log --output cadence.json

  node scripts/native-terminal-history-gate.cjs finalize \\
    --release release.json --footprint footprint.json --cadence cadence.json \\
    --frame-trace frame-trace.json --before before.json --after after.json \\
    --interaction interaction.json --output qualification.json`
}

async function main(argv) {
  const options = parseArguments(argv)
  if (options.help) return console.log(usage())
  if (options.command === 'snapshot') {
    const receipt = await captureSnapshot(options)
    writeJSONExclusive(options.output, receipt)
    console.log(`NATIVE_TERMINAL_HISTORY_SNAPSHOT=${JSON.stringify(receipt)}`)
    return receipt
  }
  if (options.command === 'extract-cadence') {
    const stat = fs.lstatSync(options.input)
    if (!stat.isFile() || stat.isSymbolicLink()) fail('cadence log must be one real file')
    const report = cadenceReportFromLog(fs.readFileSync(options.input, 'utf8'))
    writeJSONExclusive(options.output, report)
    console.log(`NATIVE_TERMINAL_HISTORY_CADENCE=${JSON.stringify(report)}`)
    return report
  }
  const evidence = Object.fromEntries(EVIDENCE_KEYS.map((key) => [key, safeReadJSON(options[key], `${key} receipt`)]))
  const receipt = buildQualificationReceipt(evidence)
  writeJSONExclusive(options.output, receipt)
  console.log(`NATIVE_TERMINAL_HISTORY_GATE=${JSON.stringify(receipt)}`)
  return receipt
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`NATIVE_TERMINAL_HISTORY_GATE=FAIL ${error.message}`)
    process.exitCode = 1
  })
}

module.exports = {
  EXPECTED_SURFACE_COUNT,
  MINIMUM_SUSTAINED_SECONDS,
  SCHEMA_VERSION,
  WORKLOAD,
  buildQualificationReceipt,
  cadenceReportFromLog,
  captureSnapshot,
  parseArguments,
  snapshotFromBrokerStatus,
  validateContinuity,
  validateInteractionAttestation,
  writeJSONExclusive,
}
