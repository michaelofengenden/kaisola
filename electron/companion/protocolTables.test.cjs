'use strict'

// Desktop half of the cross-language protocol-table contract. Asserts every
// enum table in protocol.cjs equals the checked-in canonical protocolTables.json.
// CompanionProtocolTableTests.swift asserts the iPhone enums against the SAME
// file, so a kind/event/command/capability/status added or renamed on either
// platform fails CI until both sides (and this JSON) agree.
const test = require('node:test')
const assert = require('node:assert/strict')
const tables = require('./protocolTables.json')
const protocol = require('./protocol.cjs')
const { COMMAND_CAPABILITIES } = require('./protocol.cjs')

const sorted = (values) => [...values].sort()

test('protocol.cjs envelope kinds match the canonical table', () => {
  assert.deepEqual(sorted(protocol.KINDS), sorted(tables.kinds))
})

test('protocol.cjs capabilities match the canonical table', () => {
  assert.deepEqual(sorted(protocol.CAPABILITIES), sorted(tables.capabilities))
})

test('protocol.cjs event types match the canonical table', () => {
  assert.deepEqual(sorted(protocol.EVENT_TYPES), sorted(tables.eventTypes))
})

test('protocol.cjs snapshot types match the canonical table', () => {
  assert.deepEqual(sorted(protocol.SNAPSHOT_TYPES), sorted(tables.snapshotTypes))
})

test('protocol.cjs receipt statuses match the canonical table', () => {
  assert.deepEqual(sorted(protocol.RECEIPT_STATUSES), sorted(tables.receiptStatuses))
})

test('protocol.cjs command→capability map matches the canonical table', () => {
  assert.deepEqual(COMMAND_CAPABILITIES, tables.commandCapabilities)
  // Every command capability must be a declared capability.
  for (const capability of Object.values(tables.commandCapabilities)) {
    assert.ok(tables.capabilities.includes(capability), `${capability} is not a declared capability`)
  }
})
