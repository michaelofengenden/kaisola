'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const { FEATURES } = require('../../runtime/node-broker/ipc/brokerWire.cjs')

function loadFeatureFixture() {
  return JSON.parse(fs.readFileSync(
    path.join(__dirname, '..', '..', 'protocol', 'broker', 'features-v1.json'),
    'utf8',
  ))
}

function assertFeatureContract(actualFeatures, fixture) {
  assert.equal(fixture.schemaVersion, 1)
  assert.deepEqual(actualFeatures, fixture.features)
}

test('the Node broker advertises the shared ordered feature contract', () => {
  assertFeatureContract(FEATURES, loadFeatureFixture())
})

test('the shared feature contract detects one deliberately drifted Node feature', () => {
  const fixture = loadFeatureFixture()
  const driftedFeatures = [...FEATURES]
  const index = driftedFeatures.indexOf('terminal-history-continuous-v1')
  assert.notEqual(index, -1)
  driftedFeatures[index] = 'terminal-history-continuous-v1-drift'

  assert.throws(
    () => assertFeatureContract(driftedFeatures, fixture),
    { code: 'ERR_ASSERTION' },
  )
})
