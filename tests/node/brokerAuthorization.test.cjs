'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  BROKER_ADMINISTRATION_FEATURE,
  CONTROLLER_ACCESS,
  OBSERVER_ACCESS,
  ADMINISTRATOR_ACCESS,
  ADMINISTRATOR_METHODS,
  brokerAccessSupported,
  brokerMethodAllowedForAccess,
  brokerAccessGrantsAdministration,
  brokerAccessGrantsGlobalObservation,
  normalizeBrokerOwnerID,
  brokerOwnerIDAllowedForAccess,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

test('broker administration is an explicit authenticated access identity', () => {
  assert.equal(BROKER_ADMINISTRATION_FEATURE, 'broker-administration-v1')
  assert.equal(brokerAccessSupported(CONTROLLER_ACCESS), true)
  assert.equal(brokerAccessSupported(OBSERVER_ACCESS), true)
  assert.equal(brokerAccessSupported(ADMINISTRATOR_ACCESS), true)
  assert.equal(brokerAccessSupported('administrator '), false)
  assert.equal(brokerAccessSupported('ADMINISTRATOR'), false)

  for (const method of ADMINISTRATOR_METHODS) {
    assert.equal(brokerMethodAllowedForAccess(CONTROLLER_ACCESS, method), false, method)
    assert.equal(brokerMethodAllowedForAccess(OBSERVER_ACCESS, method), false, method)
    assert.equal(brokerMethodAllowedForAccess(ADMINISTRATOR_ACCESS, method), true, method)
  }
  assert.equal(brokerMethodAllowedForAccess(CONTROLLER_ACCESS, 'terminal.create'), true)
  assert.equal(brokerMethodAllowedForAccess(OBSERVER_ACCESS, 'broker.inventory'), true)
  assert.equal(brokerMethodAllowedForAccess('unknown', 'broker.status'), false)
})

test('ordinary controller owner identities can never normalize to zero', () => {
  for (const value of [undefined, null, 0, '0', '', ' 0 ', '\u0660', '!@#$']) {
    assert.equal(normalizeBrokerOwnerID(value), '0', JSON.stringify(value))
    assert.equal(brokerOwnerIDAllowedForAccess(CONTROLLER_ACCESS, value), false, JSON.stringify(value))
  }
  for (const value of ['native-owner', 'owner_1', '000']) {
    assert.equal(brokerOwnerIDAllowedForAccess(CONTROLLER_ACCESS, value), true, value)
  }
  assert.equal(brokerOwnerIDAllowedForAccess(OBSERVER_ACCESS, '0'), true)
  assert.equal(brokerOwnerIDAllowedForAccess(ADMINISTRATOR_ACCESS, '0'), true)
})

test('global observation and administration are separate access grants', () => {
  assert.equal(brokerAccessGrantsAdministration(CONTROLLER_ACCESS), false)
  assert.equal(brokerAccessGrantsAdministration(OBSERVER_ACCESS), false)
  assert.equal(brokerAccessGrantsAdministration(ADMINISTRATOR_ACCESS), true)

  assert.equal(brokerAccessGrantsGlobalObservation(CONTROLLER_ACCESS), false)
  assert.equal(brokerAccessGrantsGlobalObservation(OBSERVER_ACCESS), true)
  assert.equal(brokerAccessGrantsGlobalObservation(ADMINISTRATOR_ACCESS), true)
})
