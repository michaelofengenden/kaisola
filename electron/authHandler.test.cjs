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

test('Firebase refresh only treats explicit credential revocation as a sign-out', () => {
  assert.equal(__test.isTerminalRefreshError('INVALID_REFRESH_TOKEN'), true)
  assert.equal(__test.isTerminalRefreshError('USER_DISABLED : account disabled'), true)
  assert.equal(__test.isTerminalRefreshError('INTERNAL_ERROR'), false)
  assert.equal(__test.isTerminalRefreshError('network request failed'), false)
})

test('Google token exchange sends the desktop client secret and preserves the provider error', async () => {
  const previous = global.fetch
  let requestBody
  global.fetch = async (_url, init) => {
    requestBody = new URLSearchParams(init.body)
    return {
      ok: false,
      status: 400,
      async json() {
        return { error: 'invalid_request', error_description: 'authorization code is invalid' }
      },
    }
  }
  try {
    await assert.rejects(
      __test.exchangeGoogleCode({
        code: 'code',
        clientId: 'client.apps.googleusercontent.com',
        clientSecret: 'GOCSPX-test-secret',
        redirectUri: 'http://127.0.0.1:49152/oauth/callback',
        verifier: 'verifier',
        nonce: 'nonce',
      }),
      /authorization code is invalid/,
    )
    assert.equal(requestBody.get('client_secret'), 'GOCSPX-test-secret')
    assert.equal(requestBody.get('code_verifier'), 'verifier')
  } finally {
    global.fetch = previous
  }
})

test('Google credential is exchanged for a bounded Firebase session', async () => {
  const previous = global.fetch
  let request
  global.fetch = async (url, init) => {
    request = { url, init, body: JSON.parse(init.body) }
    return {
      ok: true,
      async json() {
        return { localId: 'firebase-user', idToken: 'firebase-id', refreshToken: 'firebase-refresh', expiresIn: '3600' }
      },
    }
  }
  try {
    const result = await __test.firebaseSignInWithGoogle('google-id', 'http://localhost', { apiKey: 'public-api-key' })
    assert.equal(result.localId, 'firebase-user')
    assert.match(request.url, /accounts:signInWithIdp\?key=public-api-key$/)
    assert.equal(request.body.requestUri, 'http://localhost')
    assert.equal(request.body.postBody, 'access_token=google-id&providerId=google.com')
    assert.equal(request.body.returnSecureToken, true)
  } finally {
    global.fetch = previous
  }
})
