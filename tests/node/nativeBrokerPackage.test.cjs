'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  brokerSources,
  contentDigest,
  contentDigestV1,
  contentDigestV2,
  createManifest,
  roleFor,
  verifyPackage,
} = require('../../scripts/native-broker-package.cjs')

const repoRoot = path.resolve(__dirname, '../..')
const digestVectorsFile = path.join(repoRoot, 'protocol', 'broker', 'package-digest-vectors-v1.json')
const schema1ManifestFile = path.join(repoRoot, 'protocol', 'broker', 'packages', 'schema1-v0.1.122-manifest.json')
const nativeV2FixtureRoot = path.join(repoRoot, 'tests', 'fixtures', 'broker-helper', 'native-v2')

const policy = {
  schemaVersion: 1,
  packageVersion: 'test-package',
  brokerImplementationVersion: 1,
  brokerProtocol: { minimum: 2, maximum: 2, securityEpoch: 1 },
  node: { version: '22.23.1', abi: '127' },
  nodePtyVersion: '1.1.0',
}

const nativeV2Policy = {
  schemaVersion: 2,
  packageVersion: '2.0.0',
  brokerImplementationVersion: 2,
  brokerProtocol: { minimum: 2, maximum: 2, securityEpoch: 1 },
  appRelease: { version: '0.1.123', build: '1123000' },
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function nativeFixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-v2-package-'))
  fs.cpSync(nativeV2FixtureRoot, root, { recursive: true })
  fs.chmodSync(root, 0o755)
  fs.chmodSync(path.join(root, 'bin'), 0o755)
  fs.chmodSync(path.join(root, 'bin', 'kaisola-session-broker'), 0o755)
  fs.chmodSync(path.join(root, 'manifest.json'), 0o644)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return root
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

test('shared package digest vectors dispatch to the matching schema reference', () => {
  const fixture = readJSON(digestVectorsFile)
  const { fixtureProvenance: _fixtureProvenance, ...schema1Reference } = readJSON(schema1ManifestFile)
  assert.equal(fixture.schemaVersion, 1)
  assert.deepEqual(fixture.vectors[0].manifest, schema1Reference)
  assert.deepEqual(fixture.vectors[1].manifest, readJSON(path.join(nativeV2FixtureRoot, 'manifest.json')))
  assert.deepEqual(
    fixture.vectors.map(({ name, manifest, expectedDigest }) => ({
      name,
      actual: contentDigest(manifest),
      expected: expectedDigest,
    })),
    fixture.vectors.map(({ name, expectedDigest }) => ({
      name,
      actual: expectedDigest,
      expected: expectedDigest,
    }))
  )
  assert.equal(contentDigestV1(fixture.vectors[0].manifest), fixture.vectors[0].expectedDigest)
  assert.equal(contentDigestV2(fixture.vectors[1].manifest), fixture.vectors[1].expectedDigest)
})

test('synthetic schema-2 fixture passes unsigned structural verification for one arm64 executable', (t) => {
  const root = nativeFixture(t)

  const manifest = verifyPackage(root, { policy: nativeV2Policy })

  assert.equal(manifest.schemaVersion, 2)
  assert.deepEqual(manifest.launch, {
    kind: 'native',
    executable: 'bin/kaisola-session-broker',
    arguments: ['--shadow'],
  })
  assert.equal(manifest.files[0].role, 'session-broker-executable')
  assert.deepEqual(manifest.files[0].machO.architectures, ['arm64'])
})

test('schema-2 verifier rejects undigested Node runtime metadata', (t) => {
  const root = nativeFixture(t)
  const manifest = readManifest(root)
  const frozenDigest = manifest.contentDigest
  manifest.node = { version: '22.23.1', abi: '127', architectures: ['arm64'] }
  manifest.nodePty = { version: '1.1.0' }

  assert.equal(contentDigest(manifest), frozenDigest)
  fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify(manifest), { mode: 0o644 })
  assert.throws(
    () => verifyPackage(root, { policy: nativeV2Policy }),
    /schema-2.*Node runtime metadata/
  )
})

test('schema-2 verifier binds the broker protocol package policy', (t) => {
  for (const field of ['minimum', 'maximum', 'securityEpoch']) {
    const root = nativeFixture(t)
    rewriteManifest(root, (manifest) => {
      manifest.brokerProtocol[field] = 999
    })

    assert.throws(
      () => verifyPackage(root, { policy: nativeV2Policy }),
      /broker protocol.*package policy/,
      field
    )
  }
})

test('native schema-2 verifier rejects ambiguous launch authority', (t) => {
  const mutations = [
    ['unknown launch kind', (manifest) => { manifest.launch.kind = 'node' }],
    ['path substitution', (manifest) => { manifest.launch.executable = 'bin/substitute' }],
    ['duplicate executable role', (manifest) => {
      manifest.files.push({ ...manifest.files[0], path: 'bin/duplicate-session-broker' })
    }],
  ]

  for (const [name, mutation] of mutations) {
    const root = nativeFixture(t)
    rewriteManifest(root, mutation)
    assert.throws(
      () => verifyPackage(root, { policy: nativeV2Policy }),
      /native launch|session-broker-executable/,
      name
    )
  }
})

test('native schema-2 verifier rejects unsafe static launch arguments', (t) => {
  const invalidArguments = [
    [''],
    ['contains\0nul'],
    ['--launch'],
    ['--pty-child'],
    Array.from({ length: 33 }, (_, index) => `argument-${index}`),
    ['x'.repeat(4097)],
  ]

  for (const argumentsValue of invalidArguments) {
    const root = nativeFixture(t)
    rewriteManifest(root, (manifest) => { manifest.launch.arguments = argumentsValue })
    assert.throws(
      () => verifyPackage(root, { policy: nativeV2Policy }),
      /static launch arguments/,
      JSON.stringify(argumentsValue)
    )
  }
})

test('native schema-2 verifier rejects weakened structural executable identity', (t) => {
  const mutations = [
    ['non-executable mode', (manifest) => { manifest.files[0].mode = '0644' }],
    ['wrong architecture', (manifest) => { manifest.files[0].machO.architectures = ['x86_64'] }],
    ['missing designated requirement', (manifest) => { manifest.files[0].machO.designatedRequirement = '' }],
  ]

  for (const [name, mutation] of mutations) {
    const root = nativeFixture(t)
    rewriteManifest(root, mutation)
    assert.throws(
      () => verifyPackage(root, { policy: nativeV2Policy }),
      /native executable|arm64|designated requirement/,
      name
    )
  }
})

test('native schema-2 verifier rejects hard-linked package files', (t) => {
  const root = nativeFixture(t)
  const executable = path.join(root, 'bin', 'kaisola-session-broker')
  const aliasDirectory = path.join(root, 'lib')
  const alias = path.join(aliasDirectory, 'broker-alias')
  fs.mkdirSync(aliasDirectory, { mode: 0o755 })
  fs.linkSync(executable, alias)
  rewriteManifest(root, (manifest) => {
    manifest.files.push({
      ...manifest.files[0],
      path: 'lib/broker-alias',
      role: 'resource',
    })
  })

  assert.throws(
    () => verifyPackage(root, { policy: nativeV2Policy }),
    /link count/
  )
})

test('native schema-2 verifier rejects a hard-linked manifest authority', (t) => {
  const root = nativeFixture(t)
  const alias = path.join(os.tmpdir(), `kaisola-native-v2-manifest-alias-${process.pid}-${Date.now()}`)
  fs.linkSync(path.join(root, 'manifest.json'), alias)
  t.after(() => fs.rmSync(alias, { force: true }))

  assert.throws(
    () => verifyPackage(root, { policy: nativeV2Policy }),
    /manifest.*link count/
  )
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
  assert.equal(roleFor('bin/kaisola-broker-bootstrap'), 'launch-agent-bootstrap')
  assert.equal(roleFor('bin/kaisola-session-broker'), 'session-broker-executable')
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
