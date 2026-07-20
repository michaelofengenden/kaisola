'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  CompanionAccountRendezvous,
  companionRendezvousUrl,
  desktopDisplayName,
} = require('./accountRendezvous.cjs')

test('derives the authenticated rendezvous sibling without carrying query data', () => {
  assert.equal(
    companionRendezvousUrl('https://us-central1-kaisola-a9ab7.cloudfunctions.net/session?secret=no'),
    'https://us-central1-kaisola-a9ab7.cloudfunctions.net/companionRendezvous',
  )
  assert.equal(companionRendezvousUrl('http://127.0.0.1/session'), null)
  assert.equal(desktopDisplayName('Michaels-MacBook.local'), 'Michaels-MacBook Mac')
})

test('publishes and withdraws a short-lived offer with Firebase bearer auth', async () => {
  const calls = []
  const rendezvous = new CompanionAccountRendezvous({
    tokenProvider: async () => 'firebase-id-token-with-enough-characters',
    configProvider: () => ({ serverUrl: 'https://region.example.test/session' }),
    nameProvider: () => "Michael's Mac",
    fetchImpl: async (url, options) => {
      calls.push({ url, options })
      return { ok: true, text: async () => '{"ok":true}' }
    },
  })
  const payload = { pairingNonce: 'nonce' }

  assert.equal(await rendezvous.publishOffer(payload), true)
  assert.equal(await rendezvous.withdrawOffer('nonce'), true)
  assert.equal(calls.length, 2)
  assert.equal(calls[0].url, 'https://region.example.test/companionRendezvous')
  assert.equal(calls[0].options.headers.authorization, 'Bearer firebase-id-token-with-enough-characters')
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    action: 'publish',
    offer: { payload, desktopName: "Michael's Mac" },
  })
  assert.deepEqual(JSON.parse(calls[1].options.body), { action: 'withdraw', pairingNonce: 'nonce' })
})

test('signed-out and server failures remain a quiet QR fallback', async () => {
  let fetched = false
  const signedOut = new CompanionAccountRendezvous({
    tokenProvider: async () => { throw new Error('signed out') },
    configProvider: () => ({ serverUrl: 'https://region.example.test/session' }),
    fetchImpl: async () => { fetched = true },
  })
  assert.equal(await signedOut.publishOffer({}), false)
  assert.equal(fetched, false)
})
