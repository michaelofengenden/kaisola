'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const {
  REQUIRED_TESTS,
  collectTestCases,
  validateBoundaryEvidence,
  validateInputProvisioningProfile,
} = require('../../scripts/native-keychain-boundary-receipt.cjs')

const root = path.resolve(__dirname, '../..')
const TEST_TEAM_IDENTIFIER = 'TESTTEAM01'

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
      'CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+7 location=embedded',
      `Authority=Developer ID Application: Kaisola Boundary (${TEST_TEAM_IDENTIFIER})`,
      'Authority=Developer ID Certification Authority',
      'Authority=Apple Root CA',
      `TeamIdentifier=${TEST_TEAM_IDENTIFIER}`,
    ].join('\n'),
    entitlements: {
      'com.apple.application-identifier': `${TEST_TEAM_IDENTIFIER}.com.kaisola.mac`,
      'com.apple.security.get-task-allow': true,
      'keychain-access-groups': [`${TEST_TEAM_IDENTIFIER}.com.kaisola.mac`],
    },
    provisioningProfile: {
      UUID: '00000000-0000-0000-0000-000000000001',
      Name: 'Kaisola Keychain Boundary',
      TeamIdentifier: [TEST_TEAM_IDENTIFIER],
      ApplicationIdentifierPrefix: [TEST_TEAM_IDENTIFIER],
      ProvisionsAllDevices: true,
      ExpirationDate: '2099-01-01T00:00:00Z',
      Entitlements: {
        'com.apple.application-identifier': `${TEST_TEAM_IDENTIFIER}.*`,
        'keychain-access-groups': [`${TEST_TEAM_IDENTIFIER}.*`],
      },
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

  assert.equal(receipt.schemaVersion, 2)
  assert.equal(receipt.pass, true)
  assert.equal(receipt.signature.kind, 'developer-id')
  assert.equal(receipt.signature.identifier, 'com.kaisola.mac')
  assert.equal(receipt.keychainAuthorization, 'developer-id-profile-authorized')
  assert.equal(
    receipt.keychainIsolation,
    'github-hosted-ephemeral-vm-cleanup-verified',
  )
  assert.equal(receipt.testCount, REQUIRED_TESTS.length)
  assert.deepEqual(receipt.tests, REQUIRED_TESTS)
  assert.doesNotMatch(JSON.stringify(receipt), /fixture-secret-value/u)
  assert.deepEqual(Object.keys(receipt).sort(), [
    'architecture',
    'keychainAuthorization',
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
          'com.apple.application-identifier': `${TEST_TEAM_IDENTIFIER}.com.kaisola.mac`,
          'com.apple.security.get-task-allow': true,
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
          'com.apple.security.get-task-allow': true,
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

test('rejects ad-hoc restricted entitlements even when the bundle verifies', () => {
  assert.throws(
    () => validateBoundaryEvidence(passingEvidence({
      host: signedHost({
        signature: [
          'Identifier=com.kaisola.mac',
          'Format=app bundle with Mach-O thin (arm64)',
          'Signature=adhoc',
          'TeamIdentifier=not set',
        ].join('\n'),
        entitlements: {
          'com.apple.application-identifier': 'com.kaisola.mac',
          'com.apple.security.get-task-allow': true,
          'keychain-access-groups': ['com.kaisola.mac'],
        },
      }),
    })),
    /ad-hoc.*cannot authorize.*data-protection Keychain/iu,
  )
})

test('physical receipt requires Developer ID even if Apple Development is otherwise valid', () => {
  const host = signedHost()
  host.signature = host.signature.replace(
    'Authority=Developer ID Application:',
    'Authority=Apple Development:',
  )
  assert.throws(
    () => validateBoundaryEvidence(
      passingEvidence({ host }),
      { requiredSignatureKind: 'developer-id' },
    ),
    /Developer ID Application signature/u,
  )
})

test('fails closed unless the embedded profile authorizes the exact identity and group', () => {
  for (const provisioningProfile of [
    undefined,
    {
      ...signedHost().provisioningProfile,
      TeamIdentifier: ['ATTACKER1'],
    },
    {
      ...signedHost().provisioningProfile,
      ApplicationIdentifierPrefix: ['ATTACKER1'],
    },
    {
      ...signedHost().provisioningProfile,
      Entitlements: {
        'com.apple.application-identifier': `${TEST_TEAM_IDENTIFIER}.com.attacker.alias`,
        'keychain-access-groups': [`${TEST_TEAM_IDENTIFIER}.com.attacker.alias`],
      },
    },
    {
      ...signedHost().provisioningProfile,
      ProvisionsAllDevices: false,
    },
    {
      ...signedHost().provisioningProfile,
      ExpirationDate: '2001-01-01T00:00:00Z',
    },
  ]) {
    assert.throws(
      () => validateBoundaryEvidence(passingEvidence({
        host: signedHost({ provisioningProfile }),
      })),
      /provisioning profile/iu,
    )
  }
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

test('accepts only an exact unexpired Developer ID input profile', () => {
  const profile = {
    ...signedHost().provisioningProfile,
    Platform: ['OSX'],
  }

  assert.deepEqual(
    validateInputProvisioningProfile(profile, TEST_TEAM_IDENTIFIER),
    { uuid: '00000000-0000-0000-0000-000000000001' },
  )

  const legacyPrefix = 'LEGACYID01'
  assert.deepEqual(
    validateInputProvisioningProfile({
      ...profile,
      ApplicationIdentifierPrefix: [legacyPrefix],
      Entitlements: {
        'com.apple.application-identifier': `${legacyPrefix}.com.kaisola.mac`,
        'keychain-access-groups': [`${legacyPrefix}.com.kaisola.mac`],
      },
    }, TEST_TEAM_IDENTIFIER),
    { uuid: '00000000-0000-0000-0000-000000000001' },
  )

  for (const [changedProfile, message] of [
    [{ ...profile, UUID: '../attacker' }, /UUID/u],
    [{ ...profile, Name: '' }, /name/u],
    [{ ...profile, Platform: ['iOS'] }, /macOS/u],
    [{ ...profile, ApplicationIdentifierPrefix: [] }, /identifier prefix/u],
    [{ ...profile, TeamIdentifier: ['ATTACKER1'] }, /signing team/u],
    [{ ...profile, ProvisionsAllDevices: false }, /all devices/u],
    [{ ...profile, ExpirationDate: '2001-01-01T00:00:00Z' }, /unexpired/u],
    [{
      ...profile,
      Entitlements: {
        'com.apple.application-identifier': `${TEST_TEAM_IDENTIFIER}.com.kaisola.mac`,
        'keychain-access-groups': [`${TEST_TEAM_IDENTIFIER}.com.attacker.alias`],
      },
    }, /Keychain access group/u],
  ]) {
    assert.throws(
      () => validateInputProvisioningProfile(changedProfile, TEST_TEAM_IDENTIFIER),
      message,
    )
  }

  assert.throws(
    () => validateInputProvisioningProfile(profile, 'not-a-team'),
    /team identifier/u,
  )
})

test('workflow pins the signed lane and uploads only the redacted receipt', () => {
  const workflow = fs.readFileSync(
    path.join(root, '.github/workflows/native-keychain-boundaries.yml'),
    'utf8',
  )
  const project = fs.readFileSync(
    path.join(root, 'native/KaisolaMac/KaisolaMac.xcodeproj/project.pbxproj'),
    'utf8',
  )

  assert.match(workflow, /runs-on:\s*macos-15/u)
  assert.match(workflow, /DEVELOPER_DIR:\s*\/Applications\/Xcode_16\.4\.app/u)
  assert.match(workflow, /RUNNER_ENVIRONMENT:-.*github-hosted/u)
  assert.match(workflow, /RUNNER_ARCH:-.*ARM64/u)
  assert.doesNotMatch(workflow, /^\s*security default-keychain/mu)
  assert.doesNotMatch(workflow, /codesign --force --deep --sign - --entitlements/u)
  assert.doesNotMatch(
    workflow,
    /^\s*(?:CODE_SIGNING_ALLOWED|CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|DEVELOPMENT_TEAM|CODE_SIGN_INJECT_BASE_ENTITLEMENTS|OTHER_CODE_SIGN_FLAGS|PROVISIONING_PROFILE(?:_SPECIFIER)?)=/mu,
  )
  assert.equal(
    (workflow.match(/^\s*KAISOLA_KEYCHAIN_BOUNDARY_CODE_SIGN_IDENTITY="Developer ID Application"/gmu) ?? []).length,
    2,
  )
  assert.equal(
    (workflow.match(/^\s*KAISOLA_KEYCHAIN_BOUNDARY_DEVELOPMENT_TEAM="\$APPLE_TEAM_ID"/gmu) ?? []).length,
    2,
  )
  assert.equal(
    (workflow.match(/^\s*KAISOLA_KEYCHAIN_BOUNDARY_OTHER_CODE_SIGN_FLAGS="--keychain \$KAISOLA_SIGNING_KEYCHAIN"/gmu) ?? []).length,
    2,
  )
  assert.equal(
    (workflow.match(/^\s*KAISOLA_KEYCHAIN_BOUNDARY_CODE_SIGN_STYLE=Manual/gmu) ?? []).length,
    2,
  )
  assert.equal(
    (workflow.match(/^\s*KAISOLA_KEYCHAIN_BOUNDARY_PROVISIONING_PROFILE_SPECIFIER="\$KAISOLA_KEYCHAIN_PROFILE_UUID"/gmu) ?? []).length,
    2,
  )
  assert.doesNotMatch(workflow, /-allowProvisioningUpdates/u)
  assert.doesNotMatch(workflow, /-authenticationKey(?:Path|ID|IssuerID)/u)
  assert.doesNotMatch(workflow, /secrets\.APPLE_API_(?:KEY_ID|PRIVATE_KEY|ISSUER)/u)
  assert.match(workflow, /KAISOLA_KEYCHAIN_BOUNDARY_ENTITLEMENTS=/u)
  assert.match(workflow, /secrets\.KAISOLA_KEYCHAIN_PROVISIONING_PROFILE/u)
  assert.match(workflow, /security cms -D -i "\$profile_path"/u)
  assert.match(workflow, /native-keychain-boundary-receipt\.cjs inspect-profile/u)
  assert.match(
    workflow,
    /Library\/Developer\/Xcode\/UserData\/Provisioning Profiles/u,
  )
  assert.match(workflow, /\$profile_uuid\.provisionprofile/u)
  assert.match(
    workflow,
    /test "\$embedded_profile_uuid" = "\$KAISOLA_KEYCHAIN_PROFILE_UUID"/u,
  )
  assert.match(workflow, /embedded\.provisionprofile/u)
  assert.match(workflow, /--provisioning-profile/u)
  assert.match(workflow, /KAISOLA_REQUIRE_KEYCHAIN_BOUNDARIES=1/u)
  assert.match(workflow, /KAISOLA_KEYCHAIN_BOUNDARY_ISOLATION=github-hosted-ephemeral-vm/u)
  assert.match(workflow, /--cleanup-verified true/u)
  assert.match(workflow, /--required-signature-kind developer-id/u)
  assert.match(workflow, /only-testing:KaisolaTests\/KeychainBoundaryTests/u)
  assert.match(workflow, /native-keychain-boundary-receipt\.cjs/u)
  assert.match(workflow, /native\/KaisolaMac\/KaisolaMac\.xcodeproj\/project\.pbxproj/u)
  assert.match(workflow, /path:\s*[^\n]*keychain-boundary-receipt\.json/u)
  assert.doesNotMatch(workflow, /path:\s*[^\n]*(?:\.xcresult|xcodebuild|tests\.json)/u)

  for (const setting of [
    'CODE_SIGN_IDENTITY = "\\$\\(KAISOLA_KEYCHAIN_BOUNDARY_CODE_SIGN_IDENTITY\\)";',
    'CODE_SIGN_STYLE = "\\$\\(KAISOLA_KEYCHAIN_BOUNDARY_CODE_SIGN_STYLE\\)";',
    'DEVELOPMENT_TEAM = "\\$\\(KAISOLA_KEYCHAIN_BOUNDARY_DEVELOPMENT_TEAM\\)";',
    'OTHER_CODE_SIGN_FLAGS = "\\$\\(inherited\\) \\$\\(KAISOLA_KEYCHAIN_BOUNDARY_OTHER_CODE_SIGN_FLAGS\\)";',
    'PROVISIONING_PROFILE_SPECIFIER = "\\$\\(KAISOLA_KEYCHAIN_BOUNDARY_PROVISIONING_PROFILE_SPECIFIER\\)";',
  ]) {
    assert.equal(
      (project.match(new RegExp(setting, 'gu')) ?? []).length,
      1,
      `${setting} must be mapped only by the Kaisola Debug target`,
    )
  }
  assert.equal(
    (project.match(/CODE_SIGN_ENTITLEMENTS = "\$\(KAISOLA_KEYCHAIN_BOUNDARY_ENTITLEMENTS\)";/gu) ?? []).length,
    1,
  )
  assert.match(project, /KAISOLA_KEYCHAIN_BOUNDARY_CODE_SIGN_IDENTITY = "-";/u)
  assert.match(project, /KAISOLA_KEYCHAIN_BOUNDARY_CODE_SIGN_STYLE = Automatic;/u)
  assert.match(project, /KAISOLA_KEYCHAIN_BOUNDARY_DEVELOPMENT_TEAM = "";/u)
  assert.match(project, /KAISOLA_KEYCHAIN_BOUNDARY_OTHER_CODE_SIGN_FLAGS = "";/u)
  assert.match(project, /KAISOLA_KEYCHAIN_BOUNDARY_PROVISIONING_PROFILE_SPECIFIER = "";/u)

  const debugConfigurations = [...project.matchAll(
    /^\t\t[A-F0-9]+ \/\* Debug \*\/ = \{\n([\s\S]*?)^\t\t\};$/gmu,
  )].map(([block]) => block)
  function debugConfiguration(bundleIdentifierSetting) {
    const block = debugConfigurations.find((candidate) => candidate.includes(
      `PRODUCT_BUNDLE_IDENTIFIER = ${bundleIdentifierSetting};`,
    ))
    assert.ok(block, `missing Debug configuration for ${bundleIdentifierSetting}`)
    return block
  }

  const appDebug = debugConfiguration('com.kaisola.mac')
  assert.match(appDebug, /CODE_SIGN_STYLE = "\$\(KAISOLA_KEYCHAIN_BOUNDARY_CODE_SIGN_STYLE\)";/u)
  assert.match(appDebug, /PROVISIONING_PROFILE_SPECIFIER = "\$\(KAISOLA_KEYCHAIN_BOUNDARY_PROVISIONING_PROFILE_SPECIFIER\)";/u)
  for (const dependencyDebug of [
    debugConfiguration('com.kaisola.mac.tests'),
  ]) {
    assert.match(dependencyDebug, /CODE_SIGN_STYLE = Automatic;/u)
    assert.doesNotMatch(dependencyDebug, /KAISOLA_KEYCHAIN_BOUNDARY_/u)
    assert.doesNotMatch(dependencyDebug, /PROVISIONING_PROFILE_SPECIFIER/u)
  }

  const contractStart = workflow.indexOf('  contract:')
  const physicalStart = workflow.indexOf('  keychain-boundaries:')
  assert.notEqual(contractStart, -1)
  assert.notEqual(physicalStart, -1)
  const contractJob = workflow.slice(contractStart, physicalStart)
  const physicalJob = workflow.slice(physicalStart)
  assert.doesNotMatch(contractJob, /secrets\./u)
  assert.match(physicalJob, /github\.event_name == 'push'/u)
  assert.match(physicalJob, /github\.ref == 'refs\/heads\/main'/u)
  assert.match(physicalJob, /github\.event_name == 'workflow_dispatch'/u)
  assert.match(physicalJob, /github\.actor == github\.repository_owner/u)
  assert.match(physicalJob, /github\.event_name == 'pull_request'/u)
  assert.match(
    physicalJob,
    /github\.event\.pull_request\.head\.repo\.full_name == github\.repository/u,
  )
  assert.match(physicalJob, /secrets\.CSC_LINK/u)
  assert.match(physicalJob, /secrets\.KAISOLA_KEYCHAIN_PROVISIONING_PROFILE/u)
  assert.match(physicalJob, /rm -f "\$\{signing_material\[@\]\}"/u)
  assert.match(physicalJob, /test ! -e "\$material"/u)
  assert.match(physicalJob, /KAISOLA_INSTALLED_PROVISIONING_PROFILE/u)
})
