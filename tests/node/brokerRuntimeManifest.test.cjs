'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

const {
  brokerRuntimeTestFiles,
  discoverBrokerRuntimeTestFiles,
  guardTestFile,
} = require('./brokerRuntimeManifest.cjs')

const root = path.join(__dirname, '..', '..')

test('broker runtime manifest enumerates every durability test exactly once', () => {
  assert.deepEqual(
    brokerRuntimeTestFiles,
    [...new Set(brokerRuntimeTestFiles)].sort(),
    'broker runtime manifest must stay sorted and duplicate-free',
  )
  for (const file of brokerRuntimeTestFiles) {
    assert.ok(fs.existsSync(path.join(root, file)), `manifest entry must exist: ${file}`)
  }
  assert.deepEqual(
    brokerRuntimeTestFiles,
    discoverBrokerRuntimeTestFiles(),
    'a broker runtime test was added or removed without updating the required manifest',
  )
})

test('required Swift contracts run the broker runtime manifest', () => {
  const workflow = fs.readFileSync(
    path.join(root, '.github', 'workflows', 'swift-contracts.yml'),
    'utf8',
  )
  assert.match(workflow, /run: node tests\/node\/brokerRuntimeManifest\.cjs/u)
  assert.equal(guardTestFile, 'tests/node/brokerRuntimeManifest.test.cjs')
})

test('guard discovers newly added broker tests without sweeping unrelated Node tests', (t) => {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-broker-manifest-'))
  t.after(() => fs.rmSync(fixture, { recursive: true, force: true }))
  fs.writeFileSync(path.join(fixture, 'brokerFuture.test.cjs'), "'use strict'\n")
  fs.writeFileSync(
    path.join(fixture, 'terminalFuture.test.cjs'),
    "require('../../runtime/node-broker/ipc/future.cjs')\n",
  )
  fs.writeFileSync(path.join(fixture, 'nativeFuture.test.cjs'), "'use strict'\n")

  assert.deepEqual(discoverBrokerRuntimeTestFiles(fixture), [
    'tests/node/brokerFuture.test.cjs',
    'tests/node/terminalFuture.test.cjs',
  ])
})
