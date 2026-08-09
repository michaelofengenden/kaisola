'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const {
  REQUIRED_TESTS,
  collectTestCases,
  validateBoundaryEvidence,
} = require('../../scripts/native-keychain-boundary-receipt.cjs')

const root = path.resolve(__dirname, '../..')

function passingSummary(overrides = {}) {
  return {
    result: 'Passed',
    totalTestCount: REQUIRED_TESTS.length,
    passedTests: REQUIRED_TESTS.length,
    failedTests: 0,
    skippedTests: 0,
    expectedFailures: 0,
    devicesAndConfigurations: [{
      device: {
        deviceId: '00008120-TEST-HOST',
        deviceName: 'GitHub Actions Mac',
        architecture: 'arm64',
        modelName: 'Mac',
        platform: 'macOS',
        osVersion: '15.6',
      },
      passedTests: REQUIRED_TESTS.length,
      failedTests: 0,
      skippedTests: 0,
      expectedFailures: 0,
      testPlanConfiguration: {
        configurationId: '1',
        configurationName: 'Test Scheme Action',
      },
    }],
    ...overrides,
  }
}

function passingTests(overrides = {}) {
  return {
    testNodes: [{
      nodeType: 'Test Suite',
      name: 'KeychainBoundaryTests',
      children: REQUIRED_TESTS.map((name) => ({
        nodeType: 'Test Case',
        name,
        result: 'Passed',
      })),
    }],
    ...overrides,
  }
}

function signedHost(overrides = {}) {
  return {
    signature: [
      'Executable=/tmp/Kaisola.app/Contents/MacOS/Kaisola',
      'Identifier=com.kaisola.mac',
      'Format=app bundle with Mach-O thin (arm64)',
      'CodeDirectory v=20500 size=123 flags=0x2(adhoc) hashes=1+7 location=embedded',
      'Signature=adhoc',
      'TeamIdentifier=not set',
    ].join('\n'),
    entitlements: {
      'com.apple.application-identifier': 'com.kaisola.mac',
      'keychain-access-groups': ['com.kaisola.mac'],
    },
    ...overrides,
  }
}

function passingEvidence(overrides = {}) {
  return {
    summary: passingSummary(),
    tests: passingTests(),
    host: signedHost(),
    keychain: {
      isolation: 'github-hosted-ephemeral-vm',
      cleanupVerified: true,
    },
    ...overrides,
  }
}

test('collects only concrete test cases from nested xcresult nodes', () => {
  assert.deepEqual(
    collectTestCases(passingTests()).map(({ name, result }) => ({ name, result })),
    REQUIRED_TESTS.map((name) => ({ name, result: 'Passed' })),
  )
})

test('accepts an exact signed entitled no-skip Keychain boundary run', () => {
  const evidence = passingEvidence()
  evidence.tests.diagnostic = 'fixture-secret-value'
  const receipt = validateBoundaryEvidence(evidence)

  assert.equal(receipt.schemaVersion, 1)
  assert.equal(receipt.pass, true)
  assert.equal(receipt.signature.kind, 'adhoc')
  assert.equal(receipt.signature.identifier, 'com.kaisola.mac')
  assert.equal(
    receipt.keychainIsolation,
    'github-hosted-ephemeral-vm-cleanup-verified',
  )
  assert.equal(receipt.testCount, REQUIRED_TESTS.length)
  assert.deepEqual(receipt.tests, REQUIRED_TESTS)
  assert.doesNotMatch(JSON.stringify(receipt), /fixture-secret-value/u)
  assert.deepEqual(Object.keys(receipt).sort(), [
    'architecture',
    'keychainIsolation',
    'pass',
    'platform',
    'schemaVersion',
    'signature',
    'testCount',
    'tests',
  ])
})

test('fails closed on skipped, failed, missing, duplicated, or extra tests', () => {
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      summary: passingSummary({ passedTests: 2, skippedTests: 1 }),
    })),
    /zero skipped tests/,
  )
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      summary: passingSummary({ result: 'Failed', passedTests: 2, failedTests: 1 }),
    })),
    /passed result with zero failures/,
  )

  for (const changedTests of [
    REQUIRED_TESTS.slice(0, -1),
    [...REQUIRED_TESTS, REQUIRED_TESTS[0]],
    [...REQUIRED_TESTS, 'testUnexpectedBoundary()'],
  ]) {
    assert.throws(
      () => validateBoundaryEvidence(passingEvidence({
        tests: {
          testNodes: changedTests.map((name) => ({
            nodeType: 'Test Case',
            name,
            result: 'Passed',
          })),
        },
      })),
      /exact Keychain boundary test set/,
    )
  }
})

test('fails closed on unsigned, mismatched, or under-entitled hosts', () => {
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      host: signedHost({ signature: 'code object is not signed at all' }),
    })),
    /valid code signature/,
  )
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      host: signedHost({
        signature: signedHost().signature.replace(
          'Identifier=com.kaisola.mac',
          'Identifier=com.attacker.alias',
        ),
      }),
    })),
    /signature identifier/,
  )
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      host: signedHost({ entitlements: {} }),
    })),
    /application-identifier entitlement/,
  )
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      host: signedHost({
        entitlements: {
          'com.apple.application-identifier': 'com.kaisola.mac',
          'keychain-access-groups': ['com.attacker.alias'],
        },
      }),
    })),
    /keychain access group/,
  )
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      host: signedHost({
        entitlements: {
          'com.apple.application-identifier': 'ATTACKER1.com.kaisola.mac',
          'keychain-access-groups': ['ATTACKER1.com.kaisola.mac'],
        },
      }),
    })),
    /application-identifier entitlement/,
  )
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      host: signedHost({
        signature: signedHost().signature.replace(
          'Mach-O thin (arm64)',
          'Mach-O universal (x86_64 arm64)',
        ),
      }),
    })),
    /exact arm64 binary/,
  )
})

test('fails closed unless the Keychain is isolated and secret cleanup is verified', () => {
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      keychain: { isolation: 'self-hosted', cleanupVerified: true },
    })),
    /GitHub-hosted ephemeral VM Keychain/,
  )
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      keychain: { isolation: 'github-hosted-ephemeral-vm', cleanupVerified: false },
    })),
    /cleanup verification/,
  )
})

test('workflow pins the signed lane and uploads only the redacted receipt', () => {
  const workflow = fs.readFileSync(
    path.join(root, '.github/workflows/native-keychain-boundaries.yml'),
    'utf8',
  )

  assert.match(workflow, /runs-on:\s*macos-15/u)
  assert.match(workflow, /DEVELOPER_DIR:\s*\/Applications\/Xcode_16\.4\.app/u)
  assert.match(workflow, /RUNNER_ENVIRONMENT:-.*github-hosted/u)
  assert.match(workflow, /RUNNER_ARCH:-.*ARM64/u)
  assert.doesNotMatch(workflow, /^\s*security (?:create|default|list)-keychain/mu)
  assert.match(workflow, /CODE_SIGNING_ALLOWED=YES/u)
  assert.match(workflow, /codesign --force --deep --sign - --entitlements/u)
  assert.match(workflow, /KAISOLA_REQUIRE_KEYCHAIN_BOUNDARIES=1/u)
  assert.match(workflow, /KAISOLA_KEYCHAIN_BOUNDARY_ISOLATION=github-hosted-ephemeral-vm/u)
  assert.match(workflow, /--cleanup-verified true/u)
  assert.match(workflow, /only-testing:KaisolaTests\/KeychainBoundaryTests/u)
  assert.match(workflow, /native-keychain-boundary-receipt\.cjs/u)
  assert.match(workflow, /path:\s*[^\n]*keychain-boundary-receipt\.json/u)
  assert.doesNotMatch(workflow, /path:\s*[^\n]*(?:\.xcresult|xcodebuild|tests\.json)/u)
})
