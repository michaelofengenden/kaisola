'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {
  BROKER_IMPLEMENTATION_VERSION,
  BROKER_PACKAGE_SCHEMA,
  BROKER_UPDATE_FEATURE,
  BROKER_ROLLING_UPDATE_FEATURE,
  TERMINAL_HISTORY_CONTINUOUS_FEATURE,
  FEATURES,
  brokerVersionsCompatible,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

test('independent broker implementation and helper package versions are pinned', () => {
  assert.equal(BROKER_IMPLEMENTATION_VERSION, 2)
  assert.equal(BROKER_PACKAGE_SCHEMA, 1)
  assert.equal(BROKER_UPDATE_FEATURE, 'broker-update-v1')
  assert.equal(BROKER_ROLLING_UPDATE_FEATURE, 'broker-rolling-update-v1')
  assert.equal(TERMINAL_HISTORY_CONTINUOUS_FEATURE, 'terminal-history-continuous-v1')
  assert.ok(FEATURES.includes(TERMINAL_HISTORY_CONTINUOUS_FEATURE))
})

test('Node and Swift consume the same broker N/N+1 compatibility matrix', () => {
  const fixture = JSON.parse(fs.readFileSync(
    path.join(__dirname, '..', '..', 'protocol', 'broker', 'compatibility-v1.json'),
    'utf8',
  ))
  assert.equal(fixture.schemaVersion, 1)
  assert.ok(fixture.combinations.length >= 7)
  for (const row of fixture.combinations) {
    assert.equal(brokerVersionsCompatible(row), row.supported, row.name)
  }
})
