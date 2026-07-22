'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const {
  BROKER_IMPLEMENTATION_VERSION,
  BROKER_PACKAGE_SCHEMA,
  brokerVersionsCompatible,
} = require('./ipc/brokerWire.cjs')

test('independent broker implementation and helper package versions are pinned', () => {
  assert.equal(BROKER_IMPLEMENTATION_VERSION, 1)
  assert.equal(BROKER_PACKAGE_SCHEMA, 1)
})

test('Node and Swift consume the same broker N/N+1 compatibility matrix', () => {
  const fixture = JSON.parse(fs.readFileSync(
    path.join(__dirname, '..', 'protocol', 'broker', 'compatibility-v1.json'),
    'utf8',
  ))
  assert.equal(fixture.schemaVersion, 1)
  assert.ok(fixture.combinations.length >= 7)
  for (const row of fixture.combinations) {
    assert.equal(brokerVersionsCompatible(row), row.supported, row.name)
  }
})
