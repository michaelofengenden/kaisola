'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  contentDigest,
  createManifest,
  roleFor,
  verifyPackage,
} = require('../../scripts/native-broker-package.cjs')

const policy = {
  schemaVersion: 1,
  packageVersion: 'test-package',
  brokerImplementationVersion: 1,
  node: { version: '22.23.1', abi: '127' },
  nodePtyVersion: '1.1.0',
}

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-package-'))
  fs.mkdirSync(path.join(root, 'lib'), { mode: 0o755 })
  fs.writeFileSync(path.join(root, 'lib', 'broker.cjs'), 'module.exports = true\n', { mode: 0o644 })
  const manifest = createManifest(root, {
    schemaVersion: 1,
    packageVersion: 'test-package',
    brokerImplementationVersion: 1,
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
  return JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'))
}

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
  assert.equal(roleFor('lib/node_modules/node-pty/prebuilds/darwin-arm64/pty.node'), 'native-module')
  assert.equal(roleFor('lib/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper'), 'node-pty-spawn-helper')
  assert.equal(roleFor('lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs'), 'broker-javascript')
})
