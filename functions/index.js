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

exports.__test = { bearerToken }
