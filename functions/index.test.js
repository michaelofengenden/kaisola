'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('./index.js')

test('server accepts one bounded Bearer token and rejects malformed headers', () => {
  assert.equal(__test.bearerToken('Bearer abc.def.ghi'), 'abc.def.ghi')
  assert.equal(__test.bearerToken('Basic abc'), null)
  assert.equal(__test.bearerToken('Bearer one two'), null)
  assert.equal(__test.bearerToken(`Bearer ${'x'.repeat(20_001)}`), null)
})

test('account rendezvous accepts only short-lived direct-LAN pairing offers', () => {
  const now = 1_784_250_000_000
  const offer = {
    desktopName: 'Michael\u0000 Mac',
    payload: {
      type: 'kaisola-companion-pairing',
      protocolVersion: 1,
      noiseProtocol: 'Noise_XX_25519_ChaChaPoly_SHA256',
      desktopId: 'desktop-test',
      identityPublic: 'b'.repeat(43),
      keyRecord: {
        desktopId: 'desktop-test',
        role: 'desktop',
        x25519StaticPublic: 'c'.repeat(43),
        signature: 'd'.repeat(86),
      },
      pairingNonce: 'a'.repeat(43),
      requestedCapabilities: ['observe'],
      transportHint: { service: '_kaisola._tcp', protocol: 'tcp', host: '192.168.1.8', port: 49321 },
      expiresAt: now + 120_000,
    },
  }
  assert.deepEqual(__test.validateCompanionOffer(offer, now), {
    nonce: 'a'.repeat(43),
    desktopId: 'desktop-test',
    desktopName: 'Michael Mac',
    payload: offer.payload,
    expiresAt: now + 120_000,
  })
  assert.throws(() => __test.validateCompanionOffer({
    ...offer,
    payload: { ...offer.payload, transportHint: { service: '_kaisola._tcp', protocol: 'tcp' } },
  }, now), /invalid_offer/)
  assert.throws(() => __test.validateCompanionOffer({
    ...offer,
    payload: { ...offer.payload, expiresAt: now + 10 * 60_000 },
  }, now), /invalid_offer/)
})
