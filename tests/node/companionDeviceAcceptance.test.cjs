'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const { spawnSync } = require('node:child_process')

const {
  PAIRING_TRANSCRIPT,
  createAcceptanceReceipt,
  inspectIPhoneApp,
  inventoryEvidence,
  parseArguments,
  requireOutputOutside,
  scanSensitiveText,
  validateIPhoneInspection,
  validateObservations,
  verifyAcceptanceReceipt,
  writeJSONAtomic,
} = require('../../scripts/companion-device-acceptance.cjs')

const sourceCommit = 'a'.repeat(40)
const teamIdentifier = 'KBD9RS8425'

function scenarioEvidence(name) {
  return [`scenarios/${name}-mac.log`, `scenarios/${name}-iphone.log`]
}

function passingObservations() {
  let scenarioIndex = 0
  const scenario = (name, expected, extra = {}) => {
    const minute = scenarioIndex * 2
    scenarioIndex += 1
    const startedAt = new Date(Date.UTC(2026, 7, 8, 20, minute)).toISOString()
    const completedAt = new Date(Date.UTC(2026, 7, 8, 20, minute + 1)).toISOString()
    return {
    result: 'pass',
    expected,
    observed: expected,
    startedAt,
    completedAt,
    evidence: scenarioEvidence(name),
    ...extra,
    }
  }
  const positive = (name, rendezvous) => scenario(name, 'paired', {
    transcript: [...PAIRING_TRANSCRIPT],
    sasConfirmation: 'matched-on-both',
    storedIdentity: 'mac-and-iphone',
    rendezvous,
  })
  const rejected = (name, expected) => scenario(name, expected, {
    persistedIdentity: false,
    activeChannel: false,
    userVisibleResult: true,
  })
  const logEvidence = [
    ...scenarioEvidence('qr'),
    ...scenarioEvidence('manualCode'),
    ...scenarioEvidence('accountRendezvous'),
    ...scenarioEvidence('userCancellation'),
    ...scenarioEvidence('malformedOffer'),
    ...scenarioEvidence('staleOffer'),
    ...scenarioEvidence('wrongAccount'),
    ...scenarioEvidence('protocolVersionMismatch'),
  ]

  return {
    schemaVersion: 1,
    kind: 'kaisola-companion-real-device-observations',
    sourceCommit,
    run: {
      id: '3baf9fe6-53f7-4b5d-bb5a-a6183d7ba7ca',
      startedAt: '2026-08-08T20:00:00.000Z',
      completedAt: '2026-08-08T21:00:00.000Z',
    },
    hardware: {
      mac: { modelIdentifier: 'Mac16,1', osVersion: '15.7.7' },
      iphone: {
        modelIdentifier: 'iPhone17,1',
        osVersion: '26.2',
        deviceIdentifierHash: 'b'.repeat(64),
        physicalDevice: true,
        cleanInstall: true,
      },
    },
    scenarios: {
      qr: positive('qr', 'not-used'),
      manualCode: positive('manualCode', 'not-used'),
      accountRendezvous: positive('accountRendezvous', 'same-account-offer-claimed'),
      userCancellation: rejected('userCancellation', 'cancelled-without-pairing'),
      malformedOffer: rejected('malformedOffer', 'rejected-malformed-offer'),
      staleOffer: rejected('staleOffer', 'rejected-expired-offer'),
      wrongAccount: rejected('wrongAccount', 'rejected-account-mismatch'),
      protocolVersionMismatch: rejected('protocolVersionMismatch', 'rejected-protocol-mismatch'),
    },
    privacy: {
      logs: { result: 'pass', evidence: logEvidence },
      screenshots: {
        result: 'pass',
        evidence: ['privacy/pairing.png', 'privacy/pairing.ocr.txt'],
        ocrReviewed: true,
      },
      pasteboard: {
        result: 'pass',
        evidence: ['privacy/pasteboard-audit.json'],
        pairingOfferClearedAfterManualEntry: true,
      },
      analytics: {
        result: 'pass',
        evidence: ['privacy/analytics-audit.json'],
        captureReviewed: true,
      },
    },
    evidence: [
      ...logEvidence.map((evidencePath) => ({
        path: evidencePath,
        kind: evidencePath.endsWith('-mac.log') ? 'mac-log' : 'iphone-log',
      })),
      { path: 'privacy/pairing.png', kind: 'screenshot' },
      { path: 'privacy/pairing.ocr.txt', kind: 'screenshot-ocr' },
      { path: 'privacy/pasteboard-audit.json', kind: 'pasteboard-audit' },
      { path: 'privacy/analytics-audit.json', kind: 'analytics-audit' },
    ],
  }
}

function writeEvidence(t, observations = passingObservations()) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-device-acceptance-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  for (const entry of observations.evidence) {
    const target = path.join(directory, entry.path)
    fs.mkdirSync(path.dirname(target), { recursive: true })
    let contents = `accepted redacted evidence for ${entry.kind}\n`
    if (entry.kind === 'mac-log' || entry.kind === 'iphone-log') {
      const side = entry.kind === 'mac-log' ? 'mac' : 'iphone'
      const name = path.basename(entry.path).replace(/-(?:mac|iphone)\.log$/u, '')
      const scenario = observations.scenarios[name]
      if (scenario.transcript) {
        contents = [
          `side=${side}`,
          `startedAt=${scenario.startedAt}`,
          `completedAt=${scenario.completedAt}`,
          ...scenario.transcript.map((event) => `event=${event}`),
          `result=${scenario.observed}`,
          `sas=${scenario.sasConfirmation}`,
          `storedIdentity=${scenario.storedIdentity}`,
          `rendezvous=${scenario.rendezvous}`,
        ].join('\n') + '\n'
      } else {
        contents = [
          `side=${side}`,
          `startedAt=${scenario.startedAt}`,
          `completedAt=${scenario.completedAt}`,
          `result=${scenario.observed}`,
          `persistedIdentity=${scenario.persistedIdentity}`,
          `activeChannel=${scenario.activeChannel}`,
          `userVisibleResult=${scenario.userVisibleResult}`,
        ].join('\n') + '\n'
      }
    }
    if (entry.kind === 'screenshot') contents = Buffer.from('89504e470d0a1a0a', 'hex')
    if (entry.kind === 'pasteboard-audit') contents = `${JSON.stringify({
      schemaVersion: 1,
      kind: 'kaisola-companion-pasteboard-audit',
      longTermKeyObserved: false,
      privateKeyObserved: false,
      bearerCredentialObserved: false,
      pairingOfferClearedAfterManualEntry: true,
    })}\n`
    if (entry.kind === 'analytics-audit') contents = `${JSON.stringify({
      schemaVersion: 1,
      kind: 'kaisola-companion-analytics-audit',
      longTermKeyObserved: false,
      privateKeyObserved: false,
      bearerCredentialObserved: false,
      rawPairingOfferObserved: false,
    })}\n`
    fs.writeFileSync(target, contents)
  }
  return directory
}

function macPreflight(overrides = {}) {
  return {
    pass: true,
    app: '/Applications/Kaisola.app',
    sourceCommit,
    bundleIdentifier: 'com.kaisola.mac',
    version: '0.1.114',
    build: '15510',
    architectures: { app: ['arm64'], node: ['arm64'], bootstrap: ['arm64'] },
    developerID: true,
    teamIdentifier,
    secureTimestamp: true,
    launchProbe: true,
    ...overrides,
  }
}

function iphoneBuild(overrides = {}) {
  return {
    schemaVersion: 1,
    kind: 'kaisola-companion-iphone-build',
    pass: true,
    sourceCommit,
    bundleIdentifier: 'com.kaisola.companion',
    version: '1.0.0',
    build: '5',
    minimumOSVersion: '18.0',
    teamIdentifier,
    signatureKind: 'apple-development',
    getTaskAllow: true,
    architectures: ['arm64'],
    executableSHA256: 'c'.repeat(64),
    provisioningProfileSHA256: 'd'.repeat(64),
    bundleDigest: 'e'.repeat(64),
    fileCount: 42,
    ...overrides,
  }
}

test('arguments expose only bounded receipt commands and reject credential inputs', () => {
  assert.deepEqual(parseArguments([
    'inspect-ios', '--app', '/tmp/KaisolaCompanion.app',
    '--source-commit', sourceCommit, '--output', '/tmp/iphone.json',
  ]), {
    command: 'inspect-ios',
    app: '/tmp/KaisolaCompanion.app',
    sourceCommit,
    output: '/tmp/iphone.json',
  })
  assert.deepEqual(parseArguments([
    'seal', '--mac-preflight', '/tmp/mac.json', '--iphone-build', '/tmp/iphone.json',
    '--observations', '/tmp/observations.json', '--evidence-directory', '/tmp/evidence',
    '--output', '/tmp/receipt.json',
  ]), {
    command: 'seal',
    macPreflight: '/tmp/mac.json',
    iphoneBuild: '/tmp/iphone.json',
    observations: '/tmp/observations.json',
    evidenceDirectory: '/tmp/evidence',
    output: '/tmp/receipt.json',
  })
  assert.throws(() => parseArguments(['seal', '--token', 'secret']), /unknown argument/)
  assert.throws(() => parseArguments([
    'inspect-ios', '--app', '/tmp/KaisolaCompanion.app', '--source-commit', sourceCommit,
    '--output', '/tmp/iphone.json', '--receipt', '/tmp/receipt.json',
  ]), /not valid for inspect-ios/)
  assert.throws(() => parseArguments(['inspect-ios', '--source-commit', 'main']), /40-character/)
  assert.throws(() => parseArguments(['seal', '--output', '/tmp/out']), /--mac-preflight is required/)
  assert.throws(() => requireOutputOutside(
    '/tmp/KaisolaCompanion.app',
    '/tmp/KaisolaCompanion.app/build-receipt.json',
    'iPhone app',
  ), /outside iPhone app/)
  assert.doesNotThrow(() => requireOutputOutside(
    '/tmp/KaisolaCompanion.app',
    '/tmp/build-receipt.json',
    'iPhone app',
  ))
})

test('iPhone inspection requires a real Apple-signed arm64 device build', () => {
  const inspection = validateIPhoneInspection({
    sourceCommit,
    info: {
      CFBundleIdentifier: 'com.kaisola.companion',
      CFBundleShortVersionString: '1.0.0',
      CFBundleVersion: '5',
      MinimumOSVersion: '18.0',
      CFBundleSupportedPlatforms: ['iPhoneOS'],
    },
    signature: {
      authorities: ['Apple Development: Developer (KBD9RS8425)'],
      teamIdentifier,
    },
    entitlements: {
      'application-identifier': `${teamIdentifier}.com.kaisola.companion`,
      'com.apple.developer.team-identifier': teamIdentifier,
      'get-task-allow': true,
    },
    architectures: ['arm64'],
    executableSHA256: 'c'.repeat(64),
    provisioningProfileSHA256: 'd'.repeat(64),
    bundleDigest: 'e'.repeat(64),
    fileCount: 42,
  })

  assert.deepEqual(inspection, iphoneBuild())
  assert.throws(() => validateIPhoneInspection({
    ...inspection,
    info: {
      CFBundleIdentifier: inspection.bundleIdentifier,
      CFBundleShortVersionString: inspection.version,
      CFBundleVersion: inspection.build,
      MinimumOSVersion: inspection.minimumOSVersion,
      CFBundleSupportedPlatforms: ['iPhoneSimulator'],
    },
    signature: { authorities: [], teamIdentifier: null },
    entitlements: {},
    architectures: ['arm64', 'x86_64'],
  }), /device platform|Apple development or distribution signature|arm64/)
})

test('inspect-ios binds the signed bundle bytes without launching a device', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-iphone-build-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const app = path.join(root, 'KaisolaCompanion.app')
  fs.mkdirSync(app)
  fs.writeFileSync(path.join(app, 'Info.plist'), 'plist')
  fs.writeFileSync(path.join(app, 'KaisolaCompanion'), 'device-binary', { mode: 0o755 })
  fs.writeFileSync(path.join(app, 'embedded.mobileprovision'), 'profile')
  fs.mkdirSync(path.join(app, '_CodeSignature'))
  fs.writeFileSync(path.join(app, '_CodeSignature', 'CodeResources'), 'signature')

  const run = (executable, arguments_) => {
    if (executable === '/usr/bin/codesign' && arguments_[0] === '--verify') return ''
    if (executable === '/usr/bin/codesign' && arguments_[0] === '-dv') {
      return 'Authority=Apple Development: Developer (KBD9RS8425)\nTeamIdentifier=KBD9RS8425'
    }
    if (executable === '/usr/bin/codesign' && arguments_[0] === '-d') {
      return JSON.stringify({
        'application-identifier': `${teamIdentifier}.com.kaisola.companion`,
        'com.apple.developer.team-identifier': teamIdentifier,
        'get-task-allow': true,
      })
    }
    if (executable === '/usr/bin/lipo') return 'arm64'
    throw new Error(`unexpected command ${executable} ${arguments_.join(' ')}`)
  }
  const receipt = inspectIPhoneApp({ app, sourceCommit }, {
    run,
    readPlist: () => ({
      CFBundleIdentifier: 'com.kaisola.companion',
      CFBundleShortVersionString: '1.0.0',
      CFBundleVersion: '5',
      MinimumOSVersion: '18.0',
      CFBundleSupportedPlatforms: ['iPhoneOS'],
      CFBundleExecutable: 'KaisolaCompanion',
    }),
  })

  assert.equal(receipt.pass, true)
  assert.equal(receipt.teamIdentifier, teamIdentifier)
  assert.match(receipt.bundleDigest, /^[0-9a-f]{64}$/)
  assert.ok(receipt.fileCount >= 5)
  assert.equal(JSON.stringify(receipt).includes(root), false)

  assert.throws(() => inspectIPhoneApp({ app, sourceCommit }, {
    run,
    readPlist: () => ({
      CFBundleIdentifier: 'com.kaisola.companion',
      CFBundleShortVersionString: '1.0.0',
      CFBundleVersion: '5',
      MinimumOSVersion: '18.0',
      CFBundleSupportedPlatforms: ['iPhoneOS'],
      CFBundleExecutable: '../outside-bundle',
    }),
  }), /stay inside the application bundle/)
})

test('observations require every physical positive and negative scenario', () => {
  const observations = passingObservations()
  const validated = validateObservations(observations)
  assert.equal(validated.hardware.iphone.physicalDevice, true)
  assert.equal(validated.hardware.iphone.cleanInstall, true)
  assert.deepEqual(validated.scenarios.qr.transcript, PAIRING_TRANSCRIPT)
  assert.equal(validated.scenarios.accountRendezvous.rendezvous, 'same-account-offer-claimed')

  const missing = structuredClone(observations)
  delete missing.scenarios.wrongAccount
  assert.throws(() => validateObservations(missing), /wrongAccount/)

  const simulator = structuredClone(observations)
  simulator.hardware.iphone.physicalDevice = false
  assert.throws(() => validateObservations(simulator), /physical device/)

  const incompleteNoise = structuredClone(observations)
  incompleteNoise.scenarios.qr.transcript.pop()
  assert.throws(() => validateObservations(incompleteNoise), /transcript/)

  const leakedIdentity = structuredClone(observations)
  leakedIdentity.scenarios.staleOffer.persistedIdentity = true
  assert.throws(() => validateObservations(leakedIdentity), /persisted identity/)

  const overlapping = structuredClone(observations)
  overlapping.scenarios.manualCode.startedAt = overlapping.scenarios.qr.startedAt
  assert.throws(() => validateObservations(overlapping), /ordered and non-overlapping/)

  const simulatorModel = structuredClone(observations)
  simulatorModel.hardware.iphone.modelIdentifier = 'iPhoneSimulator1,1'
  assert.throws(() => validateObservations(simulatorModel), /iPhone model identifier/)

  const reusedLog = structuredClone(observations)
  reusedLog.scenarios.manualCode.evidence[0] = reusedLog.scenarios.qr.evidence[0]
  assert.throws(() => validateObservations(reusedLog), /unique Mac and iPhone logs/)

  const incompletePrivacy = structuredClone(observations)
  incompletePrivacy.privacy.logs.evidence.pop()
  assert.throws(() => validateObservations(incompletePrivacy), /every scenario log/)

  const noted = structuredClone(observations)
  noted.evidence.push({ path: 'scenarios/qr-note.txt', kind: 'operator-note' })
  noted.scenarios.qr.evidence.push('scenarios/qr-note.txt')
  assert.doesNotThrow(() => validateObservations(noted))
})

test('credential scanner rejects bearer tokens, private keys, and token fields', () => {
  assert.doesNotThrow(() => scanSensitiveText('paired stage=complete credential=<redacted>', 'log'))
  assert.throws(() => scanSensitiveText('Authorization: Bearer abcdefghijklmnopqrstuvwxyz', 'log'), /bearer credential/)
  assert.throws(() => scanSensitiveText('-----BEGIN PRIVATE KEY-----', 'log'), /private key/)
  assert.throws(() => scanSensitiveText('"refreshToken":"very-secret-token-value"', 'log'), /credential field/)
  assert.throws(() => scanSensitiveText('identityPrivateKey=abcdefghijklmnopqrstuvwxyz', 'log'), /credential field/)
  assert.throws(() => scanSensitiveText('{"type":"kaisola-companion-pairing","version":1}', 'log'), /raw pairing offer/)
  assert.throws(() => scanSensitiveText('eyJabcdefghijk.eyJabcdefghijkl.abcdefghijklmnop', 'log'), /JWT/)
})

test('evidence inventory is bounded, path-safe, symlink-free, and privacy checked', (t) => {
  const observations = passingObservations()
  const directory = writeEvidence(t, observations)
  const inventory = inventoryEvidence(directory, observations.evidence)
  assert.equal(inventory.length, observations.evidence.length)
  assert.ok(inventory.every((entry) => /^[0-9a-f]{64}$/.test(entry.sha256)))
  assert.ok(inventory.every((entry) => !path.isAbsolute(entry.path)))

  assert.throws(() => inventoryEvidence(directory, [{ path: '../escape.log', kind: 'mac-log' }]), /relative evidence path/)
  const link = path.join(directory, 'privacy', 'linked.log')
  fs.symlinkSync(path.join(directory, 'scenarios', 'qr-mac.log'), link)
  assert.throws(() => inventoryEvidence(directory, [{ path: 'privacy/linked.log', kind: 'mac-log' }]), /symbolic link/)
  fs.unlinkSync(link)

  const qrMacLog = path.join(directory, 'scenarios', 'qr-mac.log')
  const cleanQRMacLog = fs.readFileSync(qrMacLog, 'utf8')
  fs.writeFileSync(qrMacLog, 'Authorization: Bearer secret-secret-secret')
  assert.throws(() => inventoryEvidence(directory, observations.evidence), /bearer credential/)
  fs.writeFileSync(qrMacLog, cleanQRMacLog)

  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-device-outside-'))
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }))
  fs.writeFileSync(path.join(outside, 'escaped.log'), 'redacted')
  const linkedDirectory = path.join(directory, 'linked-directory')
  fs.symlinkSync(outside, linkedDirectory)
  assert.throws(() => inventoryEvidence(directory, [{
    path: 'linked-directory/escaped.log', kind: 'mac-log',
  }]), /symbolic link|declared root/)
  fs.unlinkSync(linkedDirectory)

  fs.writeFileSync(path.join(directory, 'privacy', 'undeclared.txt'), 'redacted but undeclared')
  assert.throws(() => inventoryEvidence(directory, observations.evidence), /undeclared evidence file/)
})

test('privacy audits fail closed and require screenshot OCR plus cleared pasteboard', (t) => {
  const observations = passingObservations()
  const directory = writeEvidence(t, observations)
  assert.doesNotThrow(() => createAcceptanceReceipt({
    macPreflight: macPreflight(),
    iphoneBuild: iphoneBuild(),
    observations,
    evidenceDirectory: directory,
    macPreflightSHA256: '1'.repeat(64),
    iphoneBuildSHA256: '2'.repeat(64),
  }))

  const noOCR = structuredClone(observations)
  noOCR.privacy.screenshots.evidence = ['privacy/pairing.png']
  assert.throws(() => createAcceptanceReceipt({
    macPreflight: macPreflight(), iphoneBuild: iphoneBuild(), observations: noOCR,
    evidenceDirectory: directory, macPreflightSHA256: '1'.repeat(64), iphoneBuildSHA256: '2'.repeat(64),
  }), /screenshot OCR/)

  const uncleared = structuredClone(observations)
  uncleared.privacy.pasteboard.pairingOfferClearedAfterManualEntry = false
  assert.throws(() => createAcceptanceReceipt({
    macPreflight: macPreflight(), iphoneBuild: iphoneBuild(), observations: uncleared,
    evidenceDirectory: directory, macPreflightSHA256: '1'.repeat(64), iphoneBuildSHA256: '2'.repeat(64),
  }), /pasteboard/)

  const incompleteTranscriptLog = path.join(directory, 'scenarios', 'qr-mac.log')
  const completeLog = fs.readFileSync(incompleteTranscriptLog, 'utf8')
  fs.writeFileSync(incompleteTranscriptLog, completeLog.replace('event=pair.message2\n', ''))
  assert.throws(() => createAcceptanceReceipt({
    macPreflight: macPreflight(), iphoneBuild: iphoneBuild(), observations,
    evidenceDirectory: directory, macPreflightSHA256: '1'.repeat(64), iphoneBuildSHA256: '2'.repeat(64),
  }), /exact Noise XX transcript/)
})

test('receipt binds one commit and signing team and strips absolute build paths', (t) => {
  const observations = passingObservations()
  const directory = writeEvidence(t, observations)
  const input = {
    macPreflight: macPreflight(),
    iphoneBuild: iphoneBuild(),
    observations,
    evidenceDirectory: directory,
    macPreflightSHA256: '1'.repeat(64),
    iphoneBuildSHA256: '2'.repeat(64),
  }
  const first = createAcceptanceReceipt(input)
  const second = createAcceptanceReceipt(input)
  assert.deepEqual(first, second)
  assert.equal(first.pass, true)
  assert.equal(first.sourceCommit, sourceCommit)
  assert.equal(first.builds.mac.teamIdentifier, teamIdentifier)
  assert.equal(first.builds.iphone.teamIdentifier, teamIdentifier)
  assert.doesNotMatch(JSON.stringify(first), /\/Applications|kaisola-device-acceptance-/)
  assert.equal(verifyAcceptanceReceipt(first, input), true)

  assert.throws(() => createAcceptanceReceipt({
    ...input,
    iphoneBuild: iphoneBuild({ sourceCommit: 'f'.repeat(40) }),
  }), /source commit/)
  assert.throws(() => createAcceptanceReceipt({
    ...input,
    iphoneBuild: iphoneBuild({ teamIdentifier: 'OTHER12345' }),
  }), /signing team/)
  assert.throws(() => createAcceptanceReceipt({
    ...input,
    macPreflight: macPreflight({ developerID: false }),
  }), /Developer ID/)
  assert.throws(() => createAcceptanceReceipt({
    ...input,
    macPreflight: macPreflight({ architectures: { app: ['arm64'], node: ['x86_64'], bootstrap: ['arm64'] } }),
  }), /Node runtime architectures/)
})

test('receipt output is private and immutable once published', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-device-output-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const output = path.join(directory, 'receipt.json')
  writeJSONAtomic(output, { pass: true })
  assert.deepEqual(JSON.parse(fs.readFileSync(output, 'utf8')), { pass: true })
  assert.equal(fs.statSync(output).mode & 0o777, 0o600)
  assert.throws(() => writeJSONAtomic(output, { pass: false }), /already exists/)

  const linked = path.join(directory, 'linked.json')
  fs.symlinkSync(output, linked)
  assert.throws(() => writeJSONAtomic(linked, { pass: false }), /already exists/)
})

test('CLI seals, verifies, and detects changed or symlinked inputs offline', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-device-cli-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const observations = passingObservations()
  const evidence = writeEvidence(t, observations)
  const mac = path.join(directory, 'mac.json')
  const iphone = path.join(directory, 'iphone.json')
  const observed = path.join(directory, 'observations.json')
  const receipt = path.join(directory, 'receipt.json')
  fs.writeFileSync(mac, `${JSON.stringify(macPreflight())}\n`)
  fs.writeFileSync(iphone, `${JSON.stringify(iphoneBuild())}\n`)
  fs.writeFileSync(observed, `${JSON.stringify(observations)}\n`)

  const invoke = (...arguments_) => spawnSync(process.execPath, [
    path.join(__dirname, '..', '..', 'scripts', 'companion-device-acceptance.cjs'),
    ...arguments_,
  ], { encoding: 'utf8' })
  const shared = [
    '--mac-preflight', mac,
    '--iphone-build', iphone,
    '--observations', observed,
    '--evidence-directory', evidence,
  ]
  const sealed = invoke('seal', ...shared, '--output', receipt)
  assert.equal(sealed.status, 0, sealed.stderr)
  assert.match(sealed.stdout, /^COMPANION_DEVICE_ACCEPTANCE=PASS evidence=[0-9a-f]{64}\n$/u)

  const verified = invoke('verify', '--receipt', receipt, ...shared)
  assert.equal(verified.status, 0, verified.stderr)
  assert.match(verified.stdout, /^COMPANION_DEVICE_ACCEPTANCE=VERIFIED evidence=[0-9a-f]{64}\n$/u)

  const nestedReceipt = path.join(evidence, 'nested-receipt.json')
  const nested = invoke('seal', ...shared, '--output', nestedReceipt)
  assert.equal(nested.status, 1)
  assert.match(nested.stderr, /outside evidence directory/)
  assert.equal(fs.existsSync(nestedReceipt), false)

  fs.appendFileSync(path.join(evidence, 'scenarios', 'qr-mac.log'), 'operatorNote=changed\n')
  const changed = invoke('verify', '--receipt', receipt, ...shared)
  assert.equal(changed.status, 1)
  assert.match(changed.stderr, /does not match exact builds and evidence/)

  const linkedMac = path.join(directory, 'linked-mac.json')
  fs.symlinkSync(mac, linkedMac)
  const linkedReceipt = path.join(directory, 'linked-input-receipt.json')
  const linked = invoke(
    'seal', '--mac-preflight', linkedMac,
    '--iphone-build', iphone,
    '--observations', observed,
    '--evidence-directory', evidence,
    '--output', linkedReceipt,
  )
  assert.equal(linked.status, 1)
  assert.match(linked.stderr, /symbolic link/)
  assert.equal(fs.existsSync(linkedReceipt), false)
})

test('package and runbook expose a real-hardware gate without claiming local success', () => {
  const root = path.join(__dirname, '..', '..')
  const packageJSON = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
  const runbook = fs.readFileSync(path.join(root, 'docs', 'companion-real-device-acceptance.md'), 'utf8')
  const source = fs.readFileSync(path.join(root, 'scripts', 'companion-device-acceptance.cjs'), 'utf8')

  assert.equal(packageJSON.scripts['companion:device-acceptance'], 'node scripts/companion-device-acceptance.cjs')
  assert.match(runbook, /clean physical iPhone/i)
  assert.match(runbook, /QR.*manual code.*account rendezvous/is)
  assert.match(runbook, /user cancellation.*malformed offer.*stale offer.*wrong account.*protocol-version mismatch/is)
  assert.match(runbook, /does not complete Issue #14/i)
  assert.doesNotMatch(source, /Date\.now\(|randomUUID\(/)
})
