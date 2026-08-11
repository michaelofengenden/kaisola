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
  BROKER_MUTATION_IDEMPOTENCY_FEATURE,
  BROKER_INVENTORY_FEATURE,
  BROKER_ADMINISTRATION_FEATURE,
  DEFAULT_MAX_LIVE_TERMINALS,
  MAX_CONFIGURABLE_LIVE_TERMINALS,
  TERMINAL_HISTORY_CONTINUOUS_FEATURE,
  TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE,
  TERMINAL_ATTACH_ACK_FEATURE,
  FEATURES,
  brokerVersionsCompatible,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

test('independent broker implementation and helper package versions are pinned', () => {
  assert.equal(BROKER_IMPLEMENTATION_VERSION, 2)
  assert.equal(BROKER_PACKAGE_SCHEMA, 1)
  assert.equal(BROKER_UPDATE_FEATURE, 'broker-update-v1')
  assert.equal(BROKER_ROLLING_UPDATE_FEATURE, 'broker-rolling-update-v1')
  assert.equal(BROKER_MUTATION_IDEMPOTENCY_FEATURE, 'broker-mutation-idempotency-v1')
  assert.equal(BROKER_INVENTORY_FEATURE, 'broker-inventory-v1')
  assert.equal(BROKER_ADMINISTRATION_FEATURE, 'broker-administration-v1')
  assert.equal(DEFAULT_MAX_LIVE_TERMINALS, 64)
  assert.equal(MAX_CONFIGURABLE_LIVE_TERMINALS, 512)
  assert.equal(TERMINAL_HISTORY_CONTINUOUS_FEATURE, 'terminal-history-continuous-v1')
  assert.ok(FEATURES.includes(TERMINAL_HISTORY_CONTINUOUS_FEATURE))
  assert.ok(FEATURES.includes(BROKER_MUTATION_IDEMPOTENCY_FEATURE))
  assert.ok(FEATURES.includes(BROKER_INVENTORY_FEATURE))
  assert.ok(FEATURES.includes(BROKER_ADMINISTRATION_FEATURE))
})

// These two strings are the whole negotiation. Swift declares them separately
// in BrokerWire.swift, and a drift on either side fails silently rather than
// loudly: the observer-only request stops being recognised and the broker goes
// back to serialising output nobody reads, and — worse — the attach
// acknowledgement stops being advertised, which is what left every terminal
// read-only when v0.1.114 met a retained v0.1.113 broker.
test('the terminal output and attach negotiation strings are pinned on the wire', () => {
  assert.equal(TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE, 'terminal-observer-only-output-v1')
  assert.equal(TERMINAL_ATTACH_ACK_FEATURE, 'terminal-attach-ack-v1')
  assert.ok(FEATURES.includes(TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE))
  assert.ok(FEATURES.includes(TERMINAL_ATTACH_ACK_FEATURE))

  // A broker advertising the acknowledgement must actually answer with one, or
  // clients hold it to a promise it does not keep.
  const source = fs.readFileSync(
    path.join(__dirname, '..', '..', 'runtime', 'node-broker', 'ipc', 'terminalCreateRoute.cjs'),
    'utf8',
  )
  const attachRoute = source.slice(source.indexOf('function terminalAttachRoute'))
  assert.ok(attachRoute.includes('ok: true'), 'terminal.attach acknowledges success')
  assert.ok(attachRoute.includes('ok: false'), 'terminal.attach reports refusal explicitly')
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
