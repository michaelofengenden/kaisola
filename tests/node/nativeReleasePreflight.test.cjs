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
  validateUpdateConfiguration,
} = require('../../scripts/native-release-preflight.cjs')

const validKey = Buffer.alloc(32, 0xA5).toString('base64')

test('release preflight requires exact universal architecture coverage', () => {
  assert.deepEqual(requireExactArchitectures(['x86_64', 'arm64'], 'test'), ['arm64', 'x86_64'])
  assert.throws(() => requireExactArchitectures(['arm64'], 'test'), /exactly arm64 and x86_64/)
  assert.throws(() => requireExactArchitectures(['arm64', 'x86_64', 'i386'], 'test'), /exactly arm64 and x86_64/)
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

test('the release workflow reseals the loose BrokerHelper code before preflight', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const workflow = fs.readFileSync(
    path.join(__dirname, '..', '..', '.github/workflows/release.yml'),
    'utf8',
  )

  assert.match(workflow, /npm run native:sign:distribution --/)
  assert.match(workflow, /--identity "Developer ID Application"/)
  const signingIndex = workflow.indexOf('- name: Re-sign nested components and seal BrokerHelper')
  const preflightIndex = workflow.indexOf('- name: Verify Kaisola release package')
  assert.ok(signingIndex >= 0, 'the distribution signer must run in the release workflow')
  assert.ok(signingIndex < preflightIndex, 'the resealed package must be verified by release preflight')
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
    'release workflow': fs.readFileSync(path.join(root, '.github/workflows/release.yml'), 'utf8'),
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

test('tag releases publish and verify the signed appcast after immutable assets', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const workflow = fs.readFileSync(
    path.join(__dirname, '..', '..', '.github/workflows/release.yml'),
    'utf8',
  )

  assert.match(workflow, /group: kaisola-release/)
  assert.match(workflow, /cancel-in-progress: false/)
  assert.match(workflow, /SPARKLE_PRIVATE_ED_KEY: \$\{\{ secrets\.SPARKLE_PRIVATE_ED_KEY \}\}/)
  assert.match(workflow, /Missing required tag-release credential: SPARKLE_PRIVATE_ED_KEY/)
  assert.match(workflow, /node scripts\/native-appcast\.cjs/)
  assert.match(workflow, /--ed-key-file "\$private_key"/)
  assert.match(workflow, /gh release download kaisola-updates/)
  assert.match(workflow, /gh release upload kaisola-updates "\$generated_appcast" --clobber/)
  assert.match(workflow, /cmp "\$generated_appcast" "\$verified_directory\/appcast\.xml"/)

  const generateIndex = workflow.indexOf('- name: Generate signed Sparkle appcast')
  const assetsIndex = workflow.indexOf('- name: Publish Kaisola assets')
  const appcastIndex = workflow.indexOf('- name: Publish and verify permanent Sparkle appcast')
  assert.ok(generateIndex >= 0 && generateIndex < assetsIndex, 'the appcast must be generated before publication')
  assert.ok(assetsIndex < appcastIndex, 'the immutable archive must publish before the appcast points at it')
})
