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
} = require('../scripts/native-release-preflight.cjs')

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
  }, true), {
    feedURL: 'https://updates.kaisola.app/native-preview/appcast.xml',
    publicKeyBytes: 32,
  })
  assert.throws(() => validateUpdateConfiguration({ SUFeedURL: 'https://updates.kaisola.app/appcast.xml' }), /incomplete/)
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
    Label: 'com.kaisola.mac.preview.broker-bootstrap',
    BundleProgram: 'Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap',
    MachServices: { 'com.kaisola.mac.preview.broker-bootstrap': true },
    AssociatedBundleIdentifiers: ['com.kaisola.mac.preview'],
  }))
  assert.throws(() => validateLaunchAgent({
    Label: 'com.kaisola.mac.preview.broker-bootstrap',
    BundleProgram: '/tmp/unsealed-helper',
    MachServices: { 'com.kaisola.mac.preview.broker-bootstrap': true },
    AssociatedBundleIdentifiers: ['com.kaisola.mac.preview'],
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
  assert.deepEqual(parseCodeSignature(`Executable=/tmp/Kaisola\nIdentifier=com.kaisola.mac.preview\nCodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+7 location=embedded\nAuthority=Developer ID Application: Kaisola Labs (TEAM123456)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=TEAM123456`), {
    authorities: [
      'Developer ID Application: Kaisola Labs (TEAM123456)',
      'Developer ID Certification Authority',
    ],
    developerID: true,
    teamIdentifier: 'TEAM123456',
    hardenedRuntime: true,
  })
  assert.deepEqual(parseCodeSignature('CodeDirectory v=20400 size=123 flags=0x2(adhoc) hashes=1+7 location=embedded\nTeamIdentifier=not set'), {
    authorities: [],
    developerID: false,
    teamIdentifier: null,
    hardenedRuntime: false,
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
