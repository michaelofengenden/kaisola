const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('./ipc/authHandler.cjs')

test('Google OAuth uses the RFC 7636 S256 PKCE challenge', () => {
  const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
  assert.equal(__test.pkceChallenge(verifier), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
})

test('Google ID token payload decoding is bounded to valid JWT structure', () => {
  const token = [
    Buffer.from('{}').toString('base64url'),
    Buffer.from(JSON.stringify({ iss: 'https://accounts.google.com', aud: 'kaisola', email: 'person@example.com' })).toString('base64url'),
    'signature',
  ].join('.')
  assert.equal(__test.decodeIdToken(token).email, 'person@example.com')
  assert.equal(__test.decodeIdToken('not-a-jwt'), null)
})
