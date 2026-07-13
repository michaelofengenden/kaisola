const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('./ipc/authHandler.cjs')

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

test('Firebase creates a Google authorization URI for the exact loopback callback', async () => {
  const previous = global.fetch
  let request
  global.fetch = async (url, init) => {
    request = { url, body: JSON.parse(init.body) }
    return {
      ok: true,
      status: 200,
      async json() {
        return { authUri: 'https://accounts.google.com/o/oauth2/auth?state=firebase-state', sessionId: 'firebase-session' }
      },
    }
  }
  try {
    const result = await __test.createFirebaseAuthUri(
      'http://127.0.0.1:49152/oauth/callback',
      'local-context',
      { apiKey: 'public-api-key' },
    )
    assert.equal(result.sessionId, 'firebase-session')
    assert.match(result.authUri, /^https:\/\/accounts\.google\.com\//)
    assert.match(request.url, /accounts:createAuthUri\?key=public-api-key$/)
    assert.deepEqual(request.body, {
      providerId: 'google.com',
      continueUri: 'http://127.0.0.1:49152/oauth/callback',
      oauthScope: 'openid email profile',
      authFlowType: 'CODE_FLOW',
      context: 'local-context',
    })
  } finally {
    global.fetch = previous
  }
})

test('Firebase exchanges the browser callback only for its matching local context', async () => {
  const previous = global.fetch
  let request
  global.fetch = async (url, init) => {
    request = { url, init, body: JSON.parse(init.body) }
    return {
      ok: true,
      async json() {
        return { localId: 'firebase-user', idToken: 'firebase-id', refreshToken: 'firebase-refresh', expiresIn: '3600', context: 'local-context' }
      },
    }
  }
  try {
    const result = await __test.firebaseSignInWithAuthResponse({
      requestUri: 'http://127.0.0.1:49152/oauth/callback',
      postBody: 'code=google-code&state=firebase-state',
      sessionId: 'firebase-session',
      context: 'local-context',
    }, { apiKey: 'public-api-key' })
    assert.equal(result.localId, 'firebase-user')
    assert.match(request.url, /accounts:signInWithIdp\?key=public-api-key$/)
    assert.equal(request.body.requestUri, 'http://127.0.0.1:49152/oauth/callback')
    assert.equal(request.body.postBody, 'code=google-code&state=firebase-state')
    assert.equal(request.body.sessionId, 'firebase-session')
    assert.equal(request.body.returnIdpCredential, true)
    assert.equal(request.body.returnSecureToken, true)
  } finally {
    global.fetch = previous
  }
})

test('Firebase callback context mismatch is rejected', async () => {
  const previous = global.fetch
  global.fetch = async () => ({
    ok: true,
    async json() {
      return { localId: 'firebase-user', idToken: 'firebase-id', refreshToken: 'firebase-refresh', context: 'other-context' }
    },
  })
  try {
    await assert.rejects(
      __test.firebaseSignInWithAuthResponse({
        requestUri: 'http://127.0.0.1:49152/oauth/callback',
        postBody: 'code=google-code&state=firebase-state',
        sessionId: 'firebase-session',
        context: 'local-context',
      }, { apiKey: 'public-api-key' }),
      /different session/,
    )
  } finally {
    global.fetch = previous
  }
})

test('OAuth callback page escapes diagnostic text', () => {
  assert.equal(__test.escapeHtml('<script>bad()</script>'), '&lt;script&gt;bad()&lt;/script&gt;')
})

test('only the initiating or replacement renderer can cancel Google OAuth', () => {
  const owner = { id: 1, isDestroyed: () => false }
  const peer = { id: 2, isDestroyed: () => false }
  assert.equal(__test.canControlGoogleSession(null, peer), true)
  assert.equal(__test.canControlGoogleSession({ sender: owner }, owner), true)
  assert.equal(__test.canControlGoogleSession({ sender: owner }, peer), false)
  owner.isDestroyed = () => true
  assert.equal(__test.canControlGoogleSession({ sender: owner }, peer), true)
})

test('stale OAuth continuations cannot mutate or close a replacement attempt', () => {
  const attemptA = { cancelled: true }
  const attemptB = { cancelled: false }
  assert.equal(__test.sameGoogleSession(attemptA, attemptA), true)
  assert.equal(__test.sameGoogleSession(attemptB, attemptA), false)
  assert.equal(__test.sameGoogleSession(null, attemptA), false)
})
