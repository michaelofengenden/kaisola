'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  parseCodeSignature,
  parseArguments,
  requireExactArchitectures,
  validateDistributionAppEntitlements,
  validateLaunchAgent,
  validateLocalAppEntitlements,
  validateNodeEntitlements,
  validateNativeCodePolicy,
  validateNativeReleaseMetadata,
  validateUpdateConfiguration,
  writeJSONAtomic,
} = require('../../scripts/native-release-preflight.cjs')

const validKey = Buffer.alloc(32, 0xA5).toString('base64')

test('release preflight requires exact Apple Silicon architecture coverage', () => {
  assert.deepEqual(requireExactArchitectures(['arm64'], 'test'), ['arm64'])
  assert.throws(() => requireExactArchitectures(['x86_64', 'arm64'], 'test'), /exactly arm64/)
  assert.throws(() => requireExactArchitectures(['x86_64'], 'test'), /exactly arm64/)
  assert.throws(() => requireExactArchitectures([], 'test'), /exactly arm64/)
})

test('release preflight mirrors the fail-closed Sparkle configuration policy', () => {
  assert.equal(validateUpdateConfiguration({}, false), null)
  assert.deepEqual(validateUpdateConfiguration({
    SUFeedURL: 'https://updates.kaisola.app/native-preview/appcast.xml',
    SUPublicEDKey: validKey,
    SUEnableAutomaticChecks: true,
    SUAutomaticallyUpdate: true,
  }, true), {
    feedURL: 'https://updates.kaisola.app/native-preview/appcast.xml',
    publicKeyBytes: 32,
  })
  assert.throws(() => validateUpdateConfiguration({ SUFeedURL: 'https://updates.kaisola.app/appcast.xml' }), /incomplete/)
  assert.throws(() => validateUpdateConfiguration({
    SUFeedURL: 'https://updates.kaisola.app/appcast.xml', SUPublicEDKey: validKey,
    SUEnableAutomaticChecks: false, SUAutomaticallyUpdate: true,
  }, true), /check for updates automatically/)
  assert.throws(() => validateUpdateConfiguration({
    SUFeedURL: 'https://updates.kaisola.app/appcast.xml', SUPublicEDKey: validKey,
    SUEnableAutomaticChecks: true, SUAutomaticallyUpdate: false,
  }, true), /download updates automatically/)
  assert.throws(() => validateUpdateConfiguration({
    SUFeedURL: 'http://updates.kaisola.app/appcast.xml', SUPublicEDKey: validKey,
  }), /must use HTTPS/)
  assert.throws(() => validateUpdateConfiguration({
    SUFeedURL: 'https://user:secret@updates.kaisola.app/appcast.xml', SUPublicEDKey: validKey,
  }), /without credentials/)
  assert.throws(() => validateUpdateConfiguration({
    SUFeedURL: 'https://updates.kaisola.app/appcast.xml', SUPublicEDKey: Buffer.alloc(31).toString('base64'),
  }), /canonical base64|exactly 32 bytes/)
})

test('release preflight pins the per-user helper launch contract', () => {
  assert.doesNotThrow(() => validateLaunchAgent({
    Label: 'com.kaisola.mac.broker-bootstrap',
    BundleProgram: 'Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap',
    MachServices: { 'com.kaisola.mac.broker-bootstrap': true },
    AssociatedBundleIdentifiers: ['com.kaisola.mac'],
  }))
  assert.throws(() => validateLaunchAgent({
    Label: 'com.kaisola.mac.broker-bootstrap',
    BundleProgram: '/tmp/unsealed-helper',
    MachServices: { 'com.kaisola.mac.broker-bootstrap': true },
    AssociatedBundleIdentifiers: ['com.kaisola.mac'],
  }), /does not point/)
})

test('release preflight binds the native helper to this exact app release', () => {
  const manifest = {
    schemaVersion: 2,
    packageVersion: '2.0.0',
    contentDigest: 'a'.repeat(64),
    brokerImplementationVersion: 2,
    brokerProtocol: { minimum: 2, maximum: 2, securityEpoch: 1 },
    appRelease: { version: '0.1.125', build: '1125000' },
    launch: {
      kind: 'native',
      executable: 'bin/kaisola-session-broker',
      arguments: [],
    },
    files: [
      {
        path: 'bin/kaisola-broker-bootstrap',
        role: 'launch-agent-bootstrap',
        mode: '0755',
        machO: { architectures: ['arm64'], designatedRequirement: 'identifier bootstrap' },
      },
      {
        path: 'bin/kaisola-session-broker',
        role: 'session-broker-executable',
        mode: '0755',
        machO: { architectures: ['arm64'], designatedRequirement: 'identifier broker' },
      },
    ],
  }

  assert.deepEqual(validateNativeReleaseMetadata(manifest, {
    CFBundleShortVersionString: '0.1.125',
    CFBundleVersion: '1125000',
  }), {
    packageVersion: '2.0.0',
    contentDigest: 'a'.repeat(64),
    schemaVersion: 2,
    implementationVersion: 2,
    protocol: { minimum: 2, maximum: 2, securityEpoch: 1 },
    appRelease: { version: '0.1.125', build: '1125000' },
    launchExecutable: 'bin/kaisola-session-broker',
    fileCount: 2,
  })
  assert.throws(() => validateNativeReleaseMetadata(manifest, {
    CFBundleShortVersionString: '0.1.126',
    CFBundleVersion: '1125000',
  }), /does not match the app release/)
  assert.throws(() => validateNativeReleaseMetadata({
    ...manifest,
    launch: { ...manifest.launch, executable: 'bin/node' },
  }, {
    CFBundleShortVersionString: '0.1.125',
    CFBundleVersion: '1125000',
  }), /launch contract/)
  assert.throws(() => validateNativeReleaseMetadata({
    ...manifest,
    files: manifest.files.filter((entry) => entry.role !== 'launch-agent-bootstrap'),
  }, {
    CFBundleShortVersionString: '0.1.125',
    CFBundleVersion: '1125000',
  }), /bootstrap contract/)
})

test('distribution preflight pins native code to the app team without Node entitlements', () => {
  const appSignature = {
    developerID: true,
    teamIdentifier: 'TEAM123456',
    hardenedRuntime: true,
    secureTimestamp: true,
  }
  const validEntry = (relativePath) => ({
    relativePath,
    signature: {
      developerID: true,
      teamIdentifier: 'TEAM123456',
      hardenedRuntime: true,
      secureTimestamp: true,
    },
    entitlements: {},
  })
  const entries = [
    validEntry('bin/kaisola-broker-bootstrap'),
    validEntry('bin/kaisola-session-broker'),
  ]

  assert.doesNotThrow(() => validateNativeCodePolicy({ appSignature, entries }))
  assert.throws(() => validateNativeCodePolicy({
    appSignature,
    entries: [{
      ...entries[0],
      signature: { ...entries[0].signature, teamIdentifier: 'OTHER12345' },
    }],
  }), /not signed by the app Developer ID team/)
  assert.throws(() => validateNativeCodePolicy({
    appSignature,
    entries: [{
      ...entries[0],
      signature: { ...entries[0].signature, hardenedRuntime: false },
    }],
  }), /does not enable the hardened runtime/)
  assert.throws(() => validateNativeCodePolicy({
    appSignature,
    entries: [{
      ...entries[0],
      signature: { ...entries[0].signature, secureTimestamp: false },
    }],
  }), /has no secure timestamp/)
  assert.throws(() => validateNativeCodePolicy({
    appSignature,
    entries: [{
      ...entries[1],
      entitlements: { 'com.apple.security.cs.allow-jit': true },
    }],
  }), /contains forbidden Node runtime entitlements/)
  assert.throws(() => validateNativeCodePolicy({
    appSignature,
    entries: [{
      ...entries[0],
      entitlements: { 'com.apple.security.cs.allow-unsigned-executable-memory': true },
    }],
  }), /contains forbidden Node runtime entitlements/)
})

test('notarization implies Developer ID validation', () => {
  assert.deepEqual(parseArguments([
    '--app', '/tmp/Kaisola.app', '--require-updates', '--require-notarized',
  ]), {
    app: '/tmp/Kaisola.app',
    requireUpdates: true,
    requireDeveloperID: true,
    requireNotarized: true,
  })
})

test('release preflight records exact source provenance in an atomic JSON receipt', (t) => {
  const fs = require('node:fs')
  const os = require('node:os')
  const path = require('node:path')
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-preflight-receipt-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const destination = path.join(root, 'nested', 'preflight.json')
  const commit = 'a'.repeat(40)

  const options = parseArguments([
    '--app', '/tmp/Kaisola.app',
    '--source-commit', commit,
    '--json-output', destination,
  ])
  assert.equal(options.sourceCommit, commit)
  assert.equal(options.jsonOutput, destination)
  writeJSONAtomic(destination, { pass: true, sourceCommit: commit })
  assert.deepEqual(JSON.parse(fs.readFileSync(destination, 'utf8')), {
    pass: true,
    sourceCommit: commit,
  })

  assert.throws(() => parseArguments([
    '--app', '/tmp/Kaisola.app', '--source-commit', 'not-a-commit',
  ]), /lowercase 40-character Git commit/)
})

test('release preflight distinguishes local and hardened Developer ID signatures', () => {
  assert.deepEqual(parseCodeSignature(`Executable=/tmp/Kaisola\nIdentifier=com.kaisola.mac\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+7 location=embedded\nAuthority=Developer ID Application: Kaisola Labs (TEAM123456)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=TEAM123456`), {
    authorities: [
      'Developer ID Application: Kaisola Labs (TEAM123456)',
      'Developer ID Certification Authority',
    ],
    developerID: true,
    teamIdentifier: 'TEAM123456',
    hardenedRuntime: true,
    secureTimestamp: false,
  })
  assert.equal(parseCodeSignature('CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+7 location=embedded\nAuthority=Developer ID Application: Kaisola Labs (TEAM123456)\nTeamIdentifier=TEAM123456\nTimestamp=Jul 22, 2026 at 1:00:00 AM').secureTimestamp, true)
  assert.deepEqual(parseCodeSignature('CodeDirectory v=20400 size=123 flags=0x2(adhoc) hashes=1+7 location=embedded\nTeamIdentifier=not set'), {
    authorities: [],
    developerID: false,
    teamIdentifier: null,
    hardenedRuntime: false,
    secureTimestamp: false,
  })
})

test('distribution Node entitlement policy enables JIT without disabling library validation', () => {
  assert.doesNotThrow(() => validateNodeEntitlements({
    'com.apple.security.cs.allow-jit': true,
    'com.apple.security.cs.allow-unsigned-executable-memory': true,
  }))
  assert.throws(() => validateNodeEntitlements({
    'com.apple.security.cs.allow-jit': true,
  }), /minimum JIT entitlements/)
  assert.throws(() => validateNodeEntitlements({
    'com.apple.security.cs.allow-jit': true,
    'com.apple.security.cs.allow-unsigned-executable-memory': true,
    'com.apple.security.cs.disable-library-validation': true,
  }), /forbidden code-signing entitlement/)
  assert.throws(() => validateNodeEntitlements({
    'com.apple.security.cs.allow-jit': true,
    'com.apple.security.cs.allow-unsigned-executable-memory': true,
    'com.apple.security.get-task-allow': true,
  }), /forbidden code-signing entitlement/)
})

test('local and distribution app signing profiles are mutually exclusive', () => {
  assert.doesNotThrow(() => validateLocalAppEntitlements({
    'com.apple.security.cs.disable-library-validation': true,
    'com.apple.security.get-task-allow': true,
  }))
  assert.throws(() => validateLocalAppEntitlements({}), /hardened ad-hoc preview/)

  assert.doesNotThrow(() => validateDistributionAppEntitlements({}))
  assert.throws(() => validateDistributionAppEntitlements({
    'com.apple.security.cs.disable-library-validation': true,
  }), /distribution app contains a forbidden/)
  assert.throws(() => validateDistributionAppEntitlements({
    'com.apple.security.get-task-allow': true,
  }), /distribution app contains a forbidden/)
})

test('the Release build disables Xcode development entitlement injection', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const root = path.join(__dirname, '..', '..')
  const source = fs.readFileSync(path.join(root, 'native/KaisolaMac/project.yml'), 'utf8')
  const project = fs.readFileSync(
    path.join(root, 'native/KaisolaMac/KaisolaMac.xcodeproj/project.pbxproj'),
    'utf8',
  )

  assert.match(source, /Release:\s+[\s\S]*?CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO/)
  assert.match(project, /AA529D5536DE8EAB8F9BB0E1 \/\* Release \*\/[\s\S]*?CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;/)
})

test('the candidate workflow reseals BrokerHelper before notarization and provenance capture', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const workflow = fs.readFileSync(
    path.join(__dirname, '..', '..', '.github/workflows/release-candidate.yml'),
    'utf8',
  )

  assert.match(workflow, /npm run native:sign:distribution --/)
  assert.match(workflow, /--identity "Developer ID Application"/)
  const signingIndex = workflow.indexOf('- name: Re-sign nested components and seal BrokerHelper')
  const preflightIndex = workflow.indexOf('- name: Verify Developer ID candidate before notarization')
  const receiptIndex = workflow.indexOf('native-release-candidate.cjs create')
  assert.ok(signingIndex >= 0, 'the distribution signer must run in the candidate workflow')
  assert.ok(signingIndex < preflightIndex, 'the resealed package must be verified by release preflight')
  assert.ok(preflightIndex < receiptIndex, 'only a verified candidate may receive provenance')
})

test('the candidate build produces and explicitly verifies the native broker package', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const root = path.join(__dirname, '..', '..')
  const workflow = fs.readFileSync(
    path.join(root, '.github/workflows/release-candidate.yml'),
    'utf8',
  )
  const project = fs.readFileSync(path.join(root, 'native/KaisolaMac/project.yml'), 'utf8')

  assert.match(
    project,
    /target: KaisolaSessionBroker\s+embed: false\s+link: false/,
    'the app target must build its Swift broker dependency implicitly',
  )
  assert.match(workflow, /Contents\/Resources\/BrokerSessionHelper/)
  assert.match(workflow, /native-package-policy\.json/)
  assert.match(workflow, /--app-release-version "\$NATIVE_MARKETING_VERSION"/)
  assert.match(workflow, /--app-release-build "\$NATIVE_BUILD_VERSION"/)
  assert.match(workflow, /--require-signatures/)
})

test('macOS workflows run the native distribution reseal regression', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const root = path.join(__dirname, '..', '..')
  for (const workflow of ['swift-contracts.yml', 'release-candidate.yml']) {
    const contents = fs.readFileSync(path.join(root, '.github/workflows', workflow), 'utf8')
    assert.match(
      contents,
      /tests\/node\/nativeDistributionSign\.test\.cjs/,
      `${workflow} must run the native reseal and no-JIT contract`,
    )
  }
})

test('the shipped update key matches the key that signs the appcast', () => {
  // Regression guard for the defect that made every build from 2026-07-22
  // onward unable to install its own updates: the release workflow pinned a
  // public key whose private half never signed anything, so Sparkle rejected
  // every appcast entry — manually and automatically alike.
  //
  // The signing key is file-custodied and deliberately not in the repo, so this
  // cannot verify a signature here. What it can do is pin the two places the
  // public key is written so they can never drift apart again, and fail loudly
  // if either reverts to the known-bad value.
  const fs = require('node:fs')
  const path = require('node:path')
  const root = path.join(__dirname, '..', '..')

  const SIGNING_PUBLIC_KEY = 'BQgU8WTQzeYBaYnbWrYBgoP7JPYyCXVrNgHCMBvmYrk='
  const KNOWN_BAD_KEY = 'FAk/3R33fKfyvsHiUKiNctprqxw/Y/guajgQXGb8r60='

  const sources = {
    'candidate workflow': fs.readFileSync(path.join(root, '.github/workflows/release-candidate.yml'), 'utf8'),
    'candidate receipt verifier': fs.readFileSync(path.join(root, 'scripts/native-release-candidate.cjs'), 'utf8'),
    'project.yml': fs.readFileSync(path.join(root, 'native/KaisolaMac/project.yml'), 'utf8'),
  }

  for (const [label, contents] of Object.entries(sources)) {
    assert.ok(
      contents.includes(SIGNING_PUBLIC_KEY),
      `${label} must pin the public half of the appcast signing key`,
    )
    assert.ok(
      !contents.includes(KNOWN_BAD_KEY),
      `${label} still pins the key that cannot verify any published release`,
    )
  }
})

test('candidate workflow performs expensive signing and supports API-key notarization', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const candidate = fs.readFileSync(
    path.join(__dirname, '..', '..', '.github/workflows/release-candidate.yml'),
    'utf8',
  )
  const contracts = fs.readFileSync(
    path.join(__dirname, '..', '..', '.github/workflows/swift-contracts.yml'),
    'utf8',
  )

  assert.match(candidate, /branches: \[main\]/)
  assert.match(candidate, /test "\$GITHUB_REF" = refs\/heads\/main/)
  assert.match(candidate, /uses: \.\/\.github\/workflows\/swift-contracts\.yml/)
  assert.match(candidate, /APPLE_API_KEY_ID: \$\{\{ secrets\.APPLE_API_KEY_ID \}\}/)
  assert.match(candidate, /APPLE_API_PRIVATE_KEY: \$\{\{ secrets\.APPLE_API_PRIVATE_KEY \}\}/)
  assert.match(candidate, /APPLE_API_ISSUER: \$\{\{ secrets\.APPLE_API_ISSUER \}\}/)
  assert.match(candidate, /NOTARY_AUTH_MODE=api-key/)
  assert.match(
    candidate,
    /--key "\$APPLE_API_PRIVATE_KEY_FILE" --key-id "\$APPLE_API_KEY_ID" --issuer "\$APPLE_API_ISSUER"/,
  )
  assert.match(candidate, /Individual API keys are unsupported by notarytool/)
  assert.match(candidate, /authentication=\(--apple-id "\$APPLE_ID"/)
  assert.match(candidate, /xcrun notarytool submit/)
  assert.match(candidate, /xcrun stapler staple/)
  assert.match(candidate, /1000000 \+ GITHUB_RUN_NUMBER \* 1000 \+ GITHUB_RUN_ATTEMPT/)
  assert.match(candidate, /native_build > 15501/)
  assert.match(candidate, /native-release-candidate\.cjs create/)
  assert.match(candidate, /uses: actions\/upload-artifact@[0-9a-f]{40}/)
  assert.match(contracts, /tests\/node\/nativeReleaseCandidate\.test\.cjs/)
})

test('tag release is a serialized, fail-closed promotion of exact candidate bytes', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const workflow = fs.readFileSync(
    path.join(__dirname, '..', '..', '.github/workflows/release.yml'),
    'utf8',
  )

  assert.match(workflow, /group: kaisola-release/)
  assert.match(workflow, /cancel-in-progress: false/)
  assert.doesNotMatch(workflow, /xcodebuild|notarytool|SPARKLE_PRIVATE_ED_KEY|CSC_LINK|--sign-update/)
  assert.match(workflow, /actions\/download-artifact@[0-9a-f]{40}/)
  assert.match(workflow, /run-id: \$\{\{ steps\.candidate\.outputs\.run-id \}\}/)
  assert.match(workflow, /--commit "\$GITHUB_SHA"/)
  assert.match(workflow, /--preflight "\$preflight"/)
  assert.match(workflow, /node scripts\/native-appcast\.cjs/)
  assert.match(workflow, /--ed-signature "\$signature"/)
  assert.match(workflow, /--archive-length "\$archive_length"/)
  assert.match(workflow, /appcast_arguments=\([\s\S]*?--zip "\$archive"/)
  assert.doesNotMatch(workflow, /existing_arguments=\(\)/)
  assert.match(workflow, /gh release download kaisola-updates/)
  assert.match(workflow, /gh release upload kaisola-updates "\$generated_appcast" --clobber/)
  assert.match(workflow, /cmp "\$generated_appcast" "\$verified_directory\/appcast\.xml"/)

  const artifactVerifyIndex = workflow.indexOf('- name: Verify provenance, checksums, and Sparkle signature before unpacking')
  const unpackIndex = workflow.indexOf('ditto -x -k "$archive"')
  const generateIndex = workflow.indexOf("- name: Generate appcast from the candidate's prepared signature")
  const assetsIndex = workflow.indexOf('- name: Publish exact candidate assets')
  const remoteVerifyIndex = workflow.indexOf('- name: Verify remote release asset digests before feed mutation')
  const appcastIndex = workflow.indexOf('- name: Publish and verify permanent Sparkle appcast')
  assert.ok(artifactVerifyIndex >= 0 && artifactVerifyIndex < unpackIndex,
    'checksums and Sparkle signature must verify before unpacking or executing the app')
  assert.ok(generateIndex >= 0 && generateIndex < assetsIndex, 'the appcast must be generated before publication')
  assert.ok(assetsIndex < remoteVerifyIndex && remoteVerifyIndex < appcastIndex,
    'remote assets must match the receipt before the permanent feed changes')
})
