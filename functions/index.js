'use strict'

const { initializeApp } = require('firebase-admin/app')
const { getAuth } = require('firebase-admin/auth')
const { FieldValue, getFirestore } = require('firebase-admin/firestore')
const { onRequest } = require('firebase-functions/v2/https')
const { setGlobalOptions } = require('firebase-functions/v2/options')

initializeApp()
setGlobalOptions({ region: 'us-central1', maxInstances: 10 })

function bearerToken(header) {
  const match = String(header || '').match(/^Bearer\s+([^\s]+)$/i)
  return match && match[1].length <= 20_000 ? match[1] : null
}

function plainObject(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value)
}

function invalidCompanionOffer() {
  throw Object.assign(new Error('invalid_offer'), { status: 400 })
}

const BASE64URL_32 = /^[A-Za-z0-9_-]{43}$/
const BASE64URL_64 = /^[A-Za-z0-9_-]{86}$/

function validateCompanionOffer(input, now = Date.now()) {
  if (!plainObject(input) || !plainObject(input.payload)) invalidCompanionOffer()
  const encoded = JSON.stringify(input)
  if (Buffer.byteLength(encoded, 'utf8') > 20 * 1024) invalidCompanionOffer()
  const payload = input.payload
  const allowedPayloadKeys = new Set([
    'type', 'protocolVersion', 'noiseProtocol', 'desktopId', 'identityPublic', 'keyRecord',
    'pairingNonce', 'requestedCapabilities', 'transportHint', 'expiresAt',
  ])
  const nonce = typeof payload.pairingNonce === 'string' && BASE64URL_32.test(payload.pairingNonce)
    ? payload.pairingNonce
    : null
  const desktopId = typeof payload.desktopId === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$/.test(payload.desktopId)
    ? payload.desktopId
    : null
  const hint = payload.transportHint
  const keyRecord = payload.keyRecord
  const expiresAt = payload.expiresAt
  if (Object.keys(payload).some((key) => !allowedPayloadKeys.has(key))
      || payload.type !== 'kaisola-companion-pairing'
      || payload.protocolVersion !== 1
      || payload.noiseProtocol !== 'Noise_XX_25519_ChaChaPoly_SHA256'
      || !nonce
      || !desktopId
      || !BASE64URL_32.test(payload.identityPublic)
      || !plainObject(keyRecord)
      || Object.keys(keyRecord).some((key) => !['desktopId', 'role', 'x25519StaticPublic', 'signature'].includes(key))
      || keyRecord.desktopId !== desktopId
      || keyRecord.role !== 'desktop'
      || !BASE64URL_32.test(keyRecord.x25519StaticPublic)
      || !BASE64URL_64.test(keyRecord.signature)
      || !Array.isArray(payload.requestedCapabilities)
      || payload.requestedCapabilities.length < 1
      || payload.requestedCapabilities.length > 3
      || !payload.requestedCapabilities.includes('observe')
      || new Set(payload.requestedCapabilities).size !== payload.requestedCapabilities.length
      || payload.requestedCapabilities.some((capability) => !['observe', 'agent-control', 'terminal-control'].includes(capability))
      || !plainObject(hint)
      || Object.keys(hint).some((key) => !['service', 'protocol', 'host', 'port'].includes(key))
      || hint.service !== '_kaisola._tcp'
      || hint.protocol !== 'tcp'
      || typeof hint.host !== 'string'
      || hint.host.length < 1
      || hint.host.length > 253
      || /[\0\r\n]/.test(hint.host)
      || !Number.isSafeInteger(hint.port)
      || hint.port < 1
      || hint.port > 65535
      || !Number.isSafeInteger(expiresAt)
      || expiresAt <= now
      || expiresAt > now + 5 * 60 * 1000) {
    invalidCompanionOffer()
  }
  const desktopName = typeof input.desktopName === 'string'
    ? input.desktopName.replace(/[\0-\x1f\x7f]/g, '').trim().slice(0, 80)
    : ''
  return { nonce, desktopId, payload, expiresAt, desktopName: desktopName || 'Kaisola Mac' }
}

async function authenticatedUser(req) {
  const token = bearerToken(req.get('authorization'))
  if (!token) throw Object.assign(new Error('missing_token'), { status: 401 })
  try {
    return await getAuth().verifyIdToken(token, true)
  } catch {
    throw Object.assign(new Error('invalid_token'), { status: 401 })
  }
}

/**
 * The desktop app exchanges Google OAuth for a Firebase session, then sends
 * the short-lived Firebase ID token here. Admin verifies signature, audience,
 * issuer, expiry, disabled-user state, and revocation before any server work.
 */
exports.session = onRequest({ cors: false, invoker: 'public' }, async (req, res) => {
  res.set('Cache-Control', 'no-store')
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false, message: 'Method not allowed.' })
    return
  }
  const token = bearerToken(req.get('authorization'))
  if (!token) {
    res.status(401).json({ ok: false, message: 'A Firebase bearer token is required.' })
    return
  }
  try {
    const decoded = await getAuth().verifyIdToken(token, true)
    const ref = getFirestore().collection('users').doc(decoded.uid)
    const existing = await ref.get()
    await ref.set({
      email: decoded.email || null,
      name: decoded.name || null,
      provider: decoded.firebase?.sign_in_provider || null,
      lastSeenAt: FieldValue.serverTimestamp(),
      ...(!existing.exists ? { createdAt: FieldValue.serverTimestamp() } : {}),
    }, { merge: true })
    res.status(200).json({
      ok: true,
      user: { uid: decoded.uid, email: decoded.email || null, name: decoded.name || null },
    })
  } catch {
    res.status(401).json({ ok: false, message: 'This sign-in is invalid, expired, disabled, or revoked.' })
  }
})

/**
 * Same-account rendezvous for a pending local pairing. Firestore clients stay
 * deny-all: only this Admin-backed function can publish or read the short-lived
 * signed offer. The offer contains a LAN endpoint, never a private key, refresh
 * token, transcript, terminal content, or durable remote-control credential.
 */
exports.companionRendezvous = onRequest({ cors: false, invoker: 'public' }, async (req, res) => {
  res.set('Cache-Control', 'no-store')
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false, message: 'Method not allowed.' })
    return
  }
  try {
    const decoded = await authenticatedUser(req)
    const action = req.body?.action
    const offers = getFirestore().collection('users').doc(decoded.uid).collection('companionOffers')
    if (action === 'publish') {
      const offer = validateCompanionOffer(req.body?.offer)
      await offers.doc(offer.nonce).set({
        desktopId: offer.desktopId,
        desktopName: offer.desktopName,
        payload: offer.payload,
        expiresAt: offer.expiresAt,
        updatedAt: FieldValue.serverTimestamp(),
      })
      res.status(200).json({ ok: true, expiresAt: offer.expiresAt })
      return
    }
    if (action === 'list') {
      const now = Date.now()
      const snapshot = await offers.orderBy('expiresAt', 'desc').limit(16).get()
      const active = []
      const expired = []
      for (const document of snapshot.docs) {
        const data = document.data()
        if (!Number.isSafeInteger(data.expiresAt) || data.expiresAt <= now) {
          expired.push(document.ref)
          continue
        }
        try {
          const offer = validateCompanionOffer({
            payload: data.payload,
            desktopName: data.desktopName,
          }, now)
          active.push({ desktopName: offer.desktopName, payload: offer.payload, expiresAt: offer.expiresAt })
        } catch { expired.push(document.ref) }
        if (active.length >= 8) break
      }
      if (expired.length) {
        const batch = getFirestore().batch()
        for (const ref of expired) batch.delete(ref)
        await batch.commit().catch(() => {})
      }
      res.status(200).json({ ok: true, offers: active })
      return
    }
    if (action === 'withdraw') {
      const nonce = typeof req.body?.pairingNonce === 'string' && BASE64URL_32.test(req.body.pairingNonce)
        ? req.body.pairingNonce
        : null
      if (!nonce) throw Object.assign(new Error('invalid_request'), { status: 400 })
      await offers.doc(nonce).delete()
      res.status(200).json({ ok: true })
      return
    }
    throw Object.assign(new Error('invalid_request'), { status: 400 })
  } catch (error) {
    const status = error?.status === 401 ? 401 : error?.status === 400 ? 400 : 503
    res.status(status).json({
      ok: false,
      message: status === 401
        ? 'This sign-in is invalid, expired, disabled, or revoked.'
        : status === 400
          ? 'The companion pairing request is invalid or expired.'
          : 'Account pairing is temporarily unavailable.',
    })
  }
})

exports.__test = { bearerToken, validateCompanionOffer }
