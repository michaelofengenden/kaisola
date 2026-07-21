import assert from 'node:assert/strict'
import test from 'node:test'

import {
  MUX_CLOSE,
  MUX_DATA,
  MUX_OPEN,
  __test,
  decodeMuxFrame,
  deriveAccountKey,
  encodeMuxFrame,
  validateTicketRequest,
  verifyFirebaseSession,
} from '../src/index.js'

test('ticket metadata is narrow and role-specific', () => {
  assert.deepEqual(validateTicketRequest({ role: 'desktop', desktopId: 'desktop-1' }), {
    role: 'desktop', desktopId: 'desktop-1',
  })
  assert.deepEqual(validateTicketRequest({ role: 'device', desktopId: 'desktop-1', deviceId: 'device-1' }), {
    role: 'device', desktopId: 'desktop-1', deviceId: 'device-1',
  })
  assert.throws(() => validateTicketRequest({ role: 'device', desktopId: 'desktop-1' }), /invalid_ticket_request/)
  assert.throws(() => validateTicketRequest({ role: 'desktop', desktopId: 'desktop-1', deviceId: 'spoof' }), /invalid_ticket_request/)
  assert.throws(() => validateTicketRequest({ role: 'desktop', desktopId: 'desktop-1', extra: true }), /invalid_ticket_request/)
})

test('multiplex frames preserve opaque bytes and reject malformed input', () => {
  const channelId = 'a'.repeat(22)
  const payload = Uint8Array.from([0, 1, 2, 127, 255])
  for (const type of [MUX_OPEN, MUX_DATA, MUX_CLOSE]) {
    const decoded = decodeMuxFrame(encodeMuxFrame(type, channelId, payload))
    assert.equal(decoded.type, type)
    assert.equal(decoded.channelId, channelId)
    assert.deepEqual([...decoded.payload], [...payload])
  }
  assert.throws(
    () => encodeMuxFrame(MUX_DATA, channelId, new Uint8Array(__test.constants.MAX_RELAY_MESSAGE_BYTES)),
    /invalid_mux_frame/,
  )
  assert.throws(
    () => decodeMuxFrame(new Uint8Array(__test.constants.MAX_RELAY_MESSAGE_BYTES + 1)),
    /invalid_mux_frame/,
  )
  assert.throws(() => decodeMuxFrame(Uint8Array.from([1, MUX_DATA, 22, 1])), /invalid_mux_frame/)
  assert.throws(() => encodeMuxFrame(9, channelId, payload), /invalid_mux_frame/)
})

test('account routing keys are stable, secret-scoped, and pseudonymous', async () => {
  const first = await deriveAccountKey('firebase-user', 'a'.repeat(32))
  const repeated = await deriveAccountKey('firebase-user', 'a'.repeat(32))
  const otherSecret = await deriveAccountKey('firebase-user', 'b'.repeat(32))
  assert.match(first, /^[A-Za-z0-9_-]{43}$/)
  assert.equal(first, repeated)
  assert.notEqual(first, otherSecret)
  assert.equal(first.includes('firebase-user'), false)
})

test('Firebase verification accepts only a bounded verified uid', async () => {
  const calls = []
  const uid = await verifyFirebaseSession('firebase-token', 'https://auth.example/session', async (url, options) => {
    calls.push({ url, options })
    return new Response(JSON.stringify({ ok: true, user: { uid: 'user-123' } }), { status: 200 })
  })
  assert.equal(uid, 'user-123')
  assert.equal(calls[0].options.headers.authorization, 'Bearer firebase-token')
  assert.equal(calls[0].options.headers['x-kaisola-purpose'], 'relay-ticket')
  await assert.rejects(
    verifyFirebaseSession('bad', 'https://auth.example/session', async () => new Response('{}', { status: 401 })),
    /invalid_session/,
  )
})

test('bearer parsing and message limits are bounded', () => {
  assert.equal(__test.bearerToken('Bearer abc.def'), 'abc.def')
  assert.equal(__test.bearerToken('Basic abc'), null)
  assert.equal(__test.bearerToken(`Bearer ${'x'.repeat(20_001)}`), null)
  assert.equal(__test.constants.MAX_RELAY_MESSAGE_BYTES, 2 * 1024 * 1024)
  assert.equal(__test.constants.TICKET_TTL_MS, 60_000)
})
