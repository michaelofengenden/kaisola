'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const {
  brokerSources,
  contentDigest,
  contentDigestV1,
  createManifest,
  roleFor,
  verifyPackage,
} = require('../../scripts/native-broker-package.cjs')

const repoRoot = path.resolve(__dirname, '../..')
const digestVectorsFile = path.join(repoRoot, 'protocol', 'broker', 'package-digest-vectors-v1.json')
const schema1ManifestFile = path.join(repoRoot, 'protocol', 'broker', 'packages', 'schema1-v0.1.122-manifest.json')

const policy = {
  schemaVersion: 1,
  packageVersion: 'test-package',
  brokerImplementationVersion: 1,
  brokerProtocol: { minimum: 2, maximum: 2, securityEpoch: 1 },
  node: { version: '22.23.1', abi: '127' },
  nodePtyVersion: '1.1.0',
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options })
  if (result.error || result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed: ${String(result.stderr || result.stdout || result.error?.message).trim()}`)
  }
  return result
}

function runFailure(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options })
  assert.notEqual(result.status, 0, `${command} ${args.join(' ')} unexpectedly passed`)
  return `${result.stdout || ''}${result.stderr || ''}`
}

function rewriteManifest(root, mutation) {
  const manifestFile = path.join(root, 'manifest.json')
  const manifest = readJSON(manifestFile)
  mutation(manifest)
  manifest.contentDigest = contentDigest(manifest)
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 })
  return manifest
}

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-package-'))
  fs.mkdirSync(path.join(root, 'lib'), { mode: 0o755 })
  fs.writeFileSync(path.join(root, 'lib', 'broker.cjs'), 'module.exports = true\n', { mode: 0o644 })
  const manifest = createManifest(root, {
    schemaVersion: 1,
    packageVersion: 'test-package',
    brokerImplementationVersion: 1,
    brokerProtocol: { minimum: 2, maximum: 2, securityEpoch: 1 },
    node: { version: '22.23.1', abi: '127', architectures: [] },
    nodePty: { version: '1.1.0' },
  })
  fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify(manifest), { mode: 0o644 })
  return root
}

test('native broker package records every file and verifies exact hashes', (t) => {
  const root = fixture()
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const manifest = verifyPackage(root, { policy })
  assert.deepEqual(manifest.files.map((entry) => entry.path), ['lib/broker.cjs'])
  assert.match(manifest.contentDigest, /^[0-9a-f]{64}$/)
  assert.equal(manifest.contentDigest, contentDigest(manifest))

  fs.appendFileSync(path.join(root, 'lib', 'broker.cjs'), 'tampered\n')
  assert.throws(() => verifyPackage(root, { policy }), /integrity mismatch/)
})

test('helper content identity is deterministic and excludes generation time', (t) => {
  const root = fixture()
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const first = readManifest(root)
  const regenerated = createManifest(root, {
    schemaVersion: first.schemaVersion,
    packageVersion: first.packageVersion,
    brokerImplementationVersion: first.brokerImplementationVersion,
    brokerProtocol: first.brokerProtocol,
    node: first.node,
    nodePty: first.nodePty,
    generatedAt: '2099-01-01T00:00:00.000Z',
  })
  assert.equal(regenerated.contentDigest, first.contentDigest)

  regenerated.files[0].sha256 = '0'.repeat(64)
  assert.notEqual(contentDigest(regenerated), first.contentDigest)
})

function readManifest(root) {
  return readJSON(path.join(root, 'manifest.json'))
}

test('synthetic v0.1.122-shaped schema-1 reference pins the v1 digest algorithm', () => {
  const manifest = readJSON(schema1ManifestFile)
  const frozenDigest = '45af6df1106c641a4d0efc6d1cffe5c9fbae24c7e4a774509b721dbbaed6f881'

  assert.match(manifest.fixtureProvenance, /synthetic schema-1 digest reference/u)
  assert.equal(manifest.contentDigest, frozenDigest)
  assert.equal(contentDigestV1(manifest), frozenDigest)
  assert.equal(contentDigest(manifest), frozenDigest)
})

test('schema-1 verifier rejects undigested native launch metadata', (t) => {
  const root = fixture()
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const manifest = readManifest(root)
  const frozenDigest = manifest.contentDigest
  manifest.appRelease = { version: '0.1.123', build: '1123000' }
  manifest.launch = {
    kind: 'native',
    executable: 'bin/kaisola-session-broker',
    arguments: [],
  }

  assert.equal(contentDigest(manifest), frozenDigest)
  fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify(manifest), { mode: 0o644 })
  assert.throws(
    () => verifyPackage(root, { policy }),
    /schema-1.*native launch metadata/
  )
})

test('schema-1 verifier binds the broker protocol package policy', (t) => {
  for (const field of ['minimum', 'maximum', 'securityEpoch']) {
    const root = fixture()
    t.after(() => fs.rmSync(root, { recursive: true, force: true }))
    rewriteManifest(root, (manifest) => {
      manifest.brokerProtocol[field] = 999
    })

    assert.throws(
      () => verifyPackage(root, { policy }),
      /broker protocol.*package policy/,
      field
    )
  }
})

test('shared package digest vectors pin the schema-1 reference', () => {
  const fixture = readJSON(digestVectorsFile)
  const { fixtureProvenance: _fixtureProvenance, ...schema1Reference } = readJSON(schema1ManifestFile)
  assert.equal(fixture.schemaVersion, 1)
  assert.deepEqual(fixture.vectors[0].manifest, schema1Reference)
  assert.equal(contentDigest(fixture.vectors[0].manifest), fixture.vectors[0].expectedDigest)
  assert.equal(contentDigestV1(fixture.vectors[0].manifest), fixture.vectors[0].expectedDigest)
})

test('native broker package rejects unmanifested files, writable code, and symlinks', (t) => {
  const unmanifested = fixture()
  const writable = fixture()
  const linked = fixture()
  t.after(() => {
    for (const root of [unmanifested, writable, linked]) fs.rmSync(root, { recursive: true, force: true })
  })

  fs.writeFileSync(path.join(unmanifested, 'extra'), 'extra')
  assert.throws(() => verifyPackage(unmanifested, { policy }), /inventory is incomplete|unmanifested/)

  fs.chmodSync(path.join(writable, 'lib', 'broker.cjs'), 0o666)
  assert.throws(() => verifyPackage(writable, { policy }), /mode mismatch|writable/)

  fs.symlinkSync(path.join(linked, 'lib', 'broker.cjs'), path.join(linked, 'linked'))
  assert.throws(() => verifyPackage(linked, { policy }), /symlink/)
})

test('native broker manifest roles distinguish nested executable code', () => {
  assert.equal(roleFor('bin/node'), 'node-runtime')
  assert.equal(roleFor('lib/node_modules/node-pty/prebuilds/darwin-arm64/pty.node'), 'native-module')
  assert.equal(roleFor('lib/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper'), 'node-pty-spawn-helper')
  assert.equal(roleFor('lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs'), 'broker-javascript')
})

test('native broker source inventory includes every local CommonJS dependency', () => {
  const packagedSources = new Set(brokerSources)
  const localRequire = /require\(\s*(['"])(\.[^'"]+)\1\s*\)/g

  for (const relative of brokerSources) {
    const source = fs.readFileSync(path.join(repoRoot, relative), 'utf8')
    for (const match of source.matchAll(localRequire)) {
      const dependency = path.posix.normalize(path.posix.join(path.posix.dirname(relative), match[2]))
      assert.ok(
        packagedSources.has(dependency),
        `${relative} requires unpackaged local dependency ${dependency}`
      )
    }
  }
})
