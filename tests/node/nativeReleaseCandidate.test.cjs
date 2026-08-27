'use strict'

const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const script = path.join(__dirname, '..', '..', 'scripts', 'native-release-candidate.cjs')
// Public, deterministic signature for the fixed ZIP fixture below. It verifies
// with the same public key embedded in Kaisola; no private key is stored here.
const signature = 'F90f7NJKxDWZpmkeRXfYMTRfw6sL9CmI3KVCna96Nror88SqAWQjBxTswO86Yk/Ouu+zxv10JFIA+HLMIyiMAA=='

function digest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-release-candidate-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const directory = path.join(root, 'native')
  fs.mkdirSync(directory)
  const version = '1.0.0'
  const build = '1001201'
  const commit = 'a'.repeat(40)
  const repository = 'michaelofengenden/kaisola'
  const runID = '123456789'
  const files = [
    `Kaisola-${version}-b${build}.zip`,
    `Kaisola-${version}-b${build}.dmg`,
    'Kaisola.dmg',
  ]
  for (const name of files) {
    const file = path.join(directory, name)
    fs.writeFileSync(file, `immutable candidate: ${name}\n`)
    fs.writeFileSync(`${file}.sha256`, `${digest(file)}  ${name}\n`)
  }

  const preflight = path.join(root, 'preflight.json')
  fs.writeFileSync(preflight, `${JSON.stringify({
    pass: true,
    app: '/private/ephemeral/Kaisola.app',
    sourceCommit: commit,
    bundleIdentifier: 'com.kaisola.mac',
    version,
    build,
    architectures: {
      app: ['arm64'],
      node: ['arm64'],
    },
    helper: {
      packageVersion: '1.1.0',
      contentDigest: 'b'.repeat(64),
      schemaVersion: 1,
      implementationVersion: 1,
      protocol: { minimum: 2, maximum: 2, securityEpoch: 1 },
      fileCount: 17,
    },
    updatesConfigured: true,
    developerID: true,
    teamIdentifier: 'KBD9RS8425',
    secureTimestamp: true,
    notarizationRequired: true,
    launchProbe: true,
  }, null, 2)}\n`)

  const signatureOutput = path.join(root, 'signature.txt')
  const zip = path.join(directory, files[0])
  fs.writeFileSync(signatureOutput, `sparkle:edSignature="${signature}" length="${fs.statSync(zip).size}"\n`)
  const receipt = path.join(directory, 'release-candidate.json')
  return { root, directory, version, build, commit, repository, runID, preflight, signatureOutput, receipt }
}

function createArgs(paths) {
  return [
    'create',
    '--directory', paths.directory,
    '--preflight', paths.preflight,
    '--sparkle-signature-output', paths.signatureOutput,
    '--output', paths.receipt,
    '--repository', paths.repository,
    '--commit', paths.commit,
    '--source-ref', 'refs/heads/main',
    '--source-committed-at', '2026-07-30T05:06:07-07:00',
    '--run-id', paths.runID,
    '--run-attempt', '2',
    '--version', paths.version,
    '--build', paths.build,
  ]
}

function verifyArgs(paths, overrides = {}) {
  const values = {
    repository: paths.repository,
    commit: paths.commit,
    runID: paths.runID,
    version: paths.version,
    tag: `v${paths.version}`,
    ...overrides,
  }
  return [
    'verify',
    '--directory', paths.directory,
    '--receipt', paths.receipt,
    '--preflight', paths.preflight,
    '--repository', values.repository,
    '--commit', values.commit,
    '--run-id', values.runID,
    '--version', values.version,
    '--tag', values.tag,
  ]
}

function run(args) {
  return spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' })
}

function create(paths) {
  const result = run(createArgs(paths))
  assert.equal(result.status, 0, result.stderr)
  return JSON.parse(fs.readFileSync(paths.receipt, 'utf8'))
}

test('candidate receipt seals exact app, helper, workflow, Sparkle, and artifact provenance', (t) => {
  const paths = fixture(t)
  const receipt = create(paths)

  assert.equal(receipt.source.commit, paths.commit)
  assert.equal(receipt.source.committedAt, '2026-07-30T12:06:07.000Z')
  assert.deepEqual(receipt.workflow, { runID: paths.runID, runAttempt: 2 })
  assert.equal(receipt.application.version, paths.version)
  assert.equal(receipt.application.build, paths.build)
  assert.equal(receipt.application.developerIDTeamIdentifier, 'KBD9RS8425')
  assert.equal(receipt.application.secureTimestamp, true)
  assert.equal(receipt.application.notarized, true)
  assert.equal(receipt.brokerHelper.contentDigest, 'b'.repeat(64))
  assert.deepEqual(receipt.brokerHelper.protocol, { minimum: 2, maximum: 2, securityEpoch: 1 })
  assert.equal(receipt.sparkle.edSignature, signature)
  assert.equal(receipt.artifacts.length, 6)
  assert.ok(receipt.artifacts.every((artifact) => /^[0-9a-f]{64}$/.test(artifact.sha256)))
  assert.doesNotMatch(fs.readFileSync(paths.receipt, 'utf8'), /private\/ephemeral|signature\.txt/)

  const verified = run(verifyArgs(paths))
  assert.equal(verified.status, 0, verified.stderr)
  assert.match(verified.stdout, /NATIVE_RELEASE_CANDIDATE=.*"pass":true/)
  assert.match(verified.stdout, /"applicationVerified":true/)
  assert.match(verified.stdout, new RegExp(`"helperContentDigest":"${'b'.repeat(64)}"`))

  const artifactOnlyArguments = verifyArgs(paths)
  artifactOnlyArguments.splice(artifactOnlyArguments.indexOf('--preflight'), 2)
  const artifactOnly = run(artifactOnlyArguments)
  assert.equal(artifactOnly.status, 0, artifactOnly.stderr)
  assert.match(artifactOnly.stdout, /"applicationVerified":false/)
})

test('candidate promotion rejects modified bytes before publication', (t) => {
  const paths = fixture(t)
  create(paths)
  fs.appendFileSync(path.join(paths.directory, `Kaisola-${paths.version}-b${paths.build}.zip`), 'tamper')

  const result = run(verifyArgs(paths))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /does not canonically checksum/)
})

test('candidate promotion is bound to exact commit, run, version, and tag', (t) => {
  const paths = fixture(t)
  create(paths)

  for (const override of [
    { commit: 'c'.repeat(40) },
    { runID: '987654321' },
    { version: '1.0.1', tag: 'v1.0.1' },
    { tag: 'v9.9.9' },
  ]) {
    const result = run(verifyArgs(paths, override))
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /does not match|provenance/)
  }
})

test('candidate creation rejects incomplete notarization or helper identity evidence', (t) => {
  const paths = fixture(t)
  const receipt = JSON.parse(fs.readFileSync(paths.preflight, 'utf8'))
  receipt.secureTimestamp = false
  delete receipt.helper.contentDigest
  fs.writeFileSync(paths.preflight, JSON.stringify(receipt))

  const result = run(createArgs(paths))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /does not describe this exact notarized release candidate|content digest/)
  assert.equal(fs.existsSync(paths.receipt), false)
})

test('candidate promotion rejects receipt signature tampering', (t) => {
  const paths = fixture(t)
  const receipt = create(paths)
  receipt.sparkle.edSignature = Buffer.alloc(64, 0x5A).toString('base64')
  fs.writeFileSync(paths.receipt, `${JSON.stringify(receipt, null, 2)}\n`)

  const result = run(verifyArgs(paths))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /artifact inventory|signature|immutable archive/)
})

test('candidate promotion rejects any unreceipted file', (t) => {
  const paths = fixture(t)
  create(paths)
  fs.writeFileSync(path.join(paths.directory, 'surprise.pkg'), 'unreceipted')

  const result = run(verifyArgs(paths))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /unexpected files: surprise\.pkg/)
})

test('candidate checksums use a deterministic filename-bound representation', (t) => {
  const paths = fixture(t)
  const checksum = path.join(paths.directory, `Kaisola-${paths.version}-b${paths.build}.zip.sha256`)
  fs.writeFileSync(checksum, `${'0'.repeat(64)} *wrong-name.zip\n`)

  const result = run(createArgs(paths))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /does not canonically checksum/)
  assert.equal(fs.existsSync(paths.receipt), false)
})

test('candidate creation only accepts protected main-branch provenance', (t) => {
  const paths = fixture(t)
  const arguments_ = createArgs(paths)
  arguments_[arguments_.indexOf('--source-ref') + 1] = 'refs/pull/17/merge'
  const result = run(arguments_)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /--source-ref must be refs\/heads\/main/)
})

test('candidate build must be newer than the pre-recreation public build', (t) => {
  const paths = fixture(t)
  const arguments_ = createArgs(paths)
  arguments_[arguments_.indexOf('--build') + 1] = '15501'
  const result = run(arguments_)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /newer than the last public build 15501/)
})
