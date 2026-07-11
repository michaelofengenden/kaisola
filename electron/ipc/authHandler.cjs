// Headless device-code login — runs a CLI's device-auth command (e.g.
// `codex login --device-auth`) as a background process, parses the URL + code
// it prints, and streams them to an in-app Sign-in card. No visible terminal:
// the user clicks "Open authorization page", signs in, and the process completes.
const { spawn } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const http = require('node:http')
const path = require('node:path')
const { app, safeStorage, shell } = require('electron')
const { agentEnv } = require('./shellEnv.cjs')

const sessions = new Map() // id → child
const ANSI = /\x1b\[[0-9;]*m/g
const URL_RE = /https?:\/\/[^\s"'<>)\]]+/
const CODE_RE = /\b[A-Z0-9]{4}-[A-Z0-9]{4,8}\b/
let googleSession = null
let firebaseTokenCache = null
let firebaseRefreshPromise = null
let firebaseSessionGeneration = 0

const TERMINAL_REFRESH_ERRORS = new Set([
  'INVALID_REFRESH_TOKEN',
  'TOKEN_EXPIRED',
  'USER_DISABLED',
  'USER_NOT_FOUND',
  'INVALID_GRANT',
])

class FirebaseSessionError extends Error {
  constructor(message, terminal = false) {
    super(message)
    this.name = 'FirebaseSessionError'
    this.terminal = terminal
  }
}

const b64url = (value) => Buffer.from(value).toString('base64url')
const pkceChallenge = (verifier) => b64url(crypto.createHash('sha256').update(verifier).digest())

function decodeIdToken(token) {
  try {
    const parts = String(token || '').split('.')
    if (parts.length !== 3) return null
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'))
    return payload && typeof payload === 'object' ? payload : null
  } catch {
    return null
  }
}

const safeAvatarUrl = (value) => {
  const url = String(value || '').trim()
  return /^https:\/\//i.test(url) && url.length <= 2000 ? url : undefined
}

const isTerminalRefreshError = (value) => {
  const code = String(value || '').trim().toUpperCase().split(/\s|:/)[0]
  return TERMINAL_REFRESH_ERRORS.has(code)
}

const identityPath = () => path.join(app.getPath('userData'), 'app-identity.json')
const firebaseSessionPath = () => path.join(app.getPath('userData'), 'firebase-session.bin')
const firebaseConfigPaths = () => [
  path.join(app.getPath('userData'), 'firebase-config.json'),
  path.join(__dirname, '..', 'firebase-config.json'),
  ...(app.isPackaged ? [path.join(process.resourcesPath, 'firebase-config.json')] : []),
]
const oauthConfigPaths = () => [
  path.join(app.getPath('userData'), 'google-oauth.json'),
  path.join(__dirname, '..', 'google-oauth.json'),
  ...(app.isPackaged ? [path.join(process.resourcesPath, 'google-oauth.json')] : []),
]

function readPublicConfig() {
  let fileConfig = {}
  for (const file of firebaseConfigPaths()) {
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8'))
      if (parsed && typeof parsed === 'object') { fileConfig = parsed; break }
    } catch { /* optional config */ }
  }
  const projectId = String(process.env.KAISOLA_FIREBASE_PROJECT_ID || fileConfig.projectId || '').trim()
  const apiKey = String(process.env.KAISOLA_FIREBASE_API_KEY || fileConfig.apiKey || '').trim()
  const googleClientId = String(process.env.KAISOLA_GOOGLE_CLIENT_ID || fileConfig.googleClientId || '').trim()
  const serverUrl = String(
    process.env.KAISOLA_AUTH_SERVER_URL ||
    fileConfig.serverUrl ||
    (projectId ? `https://us-central1-${projectId}.cloudfunctions.net/session` : ''),
  ).trim()
  return {
    projectId: /^[a-z0-9][a-z0-9-]{4,60}$/.test(projectId) ? projectId : null,
    apiKey: /^[a-zA-Z0-9_-]{20,200}$/.test(apiKey) ? apiKey : null,
    googleClientId: /^[a-zA-Z0-9._-]+\.apps\.googleusercontent\.com$/.test(googleClientId) ? googleClientId : null,
    serverUrl: /^https:\/\//.test(serverUrl) ? serverUrl : null,
  }
}

function googleClientId() {
  const firebaseId = readPublicConfig().googleClientId
  if (firebaseId) return firebaseId
  const fromEnv = String(process.env.KAISOLA_GOOGLE_CLIENT_ID || '').trim()
  if (/^[a-zA-Z0-9._-]+\.apps\.googleusercontent\.com$/.test(fromEnv)) return fromEnv
  for (const file of oauthConfigPaths()) {
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8'))
      const id = String(parsed.clientId || parsed.installed?.client_id || '').trim()
      if (/^[a-zA-Z0-9._-]+\.apps\.googleusercontent\.com$/.test(id)) return id
    } catch { /* optional config */ }
  }
  return null
}

function googleClientSecret(clientId = googleClientId()) {
  const fromEnv = String(process.env.KAISOLA_GOOGLE_CLIENT_SECRET || '').trim()
  if (/^[a-zA-Z0-9._-]{8,256}$/.test(fromEnv)) return fromEnv
  for (const file of oauthConfigPaths()) {
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8'))
      const credentials = parsed.installed || parsed.web || parsed
      const id = String(credentials?.client_id || credentials?.clientId || '').trim()
      const secret = String(credentials?.client_secret || credentials?.clientSecret || '').trim()
      if (id === clientId && /^[a-zA-Z0-9._-]{8,256}$/.test(secret)) return secret
    } catch { /* optional config */ }
  }
  return null
}

function authConfigIssue() {
  const cfg = readPublicConfig()
  const clientId = googleClientId()
  if (!clientId || !cfg.projectId || !cfg.apiKey || !cfg.serverUrl) {
    return 'This build is missing its Firebase public config or Google Desktop OAuth client.'
  }
  if (!googleClientSecret(clientId)) {
    return 'Download the matching Desktop OAuth JSON from Google Cloud and save it as electron/google-oauth.json.'
  }
  return null
}

const firebaseConfigured = () => !authConfigIssue()

function readIdentity() {
  try {
    const parsed = JSON.parse(fs.readFileSync(identityPath(), 'utf8'))
    if (parsed?.provider !== 'google' || typeof parsed?.id !== 'string' || typeof parsed?.email !== 'string') return null
    return {
      provider: 'google',
      id: parsed.id.slice(0, 320),
      email: parsed.email.slice(0, 320),
      name: typeof parsed.name === 'string' ? parsed.name.slice(0, 320) : undefined,
      avatarUrl: safeAvatarUrl(parsed.avatarUrl),
      signedInAt: Number(parsed.signedInAt) || undefined,
      serverVerified: parsed.serverVerified === true,
    }
  } catch {
    return null
  }
}

function writeIdentity(profile) {
  const file = identityPath()
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(profile, null, 2), { mode: 0o600 })
  fs.renameSync(tmp, file)
}

function readFirebaseSession() {
  try {
    if (!safeStorage.isEncryptionAvailable()) return null
    const parsed = JSON.parse(safeStorage.decryptString(fs.readFileSync(firebaseSessionPath())))
    if (typeof parsed?.refreshToken !== 'string' || !parsed.refreshToken) return null
    return { refreshToken: parsed.refreshToken }
  } catch {
    return null
  }
}

function writeFirebaseSession(refreshToken) {
  if (!safeStorage.isEncryptionAvailable()) throw new Error('OS keychain encryption is unavailable; Kaisola cannot store a secure sign-in session.')
  const file = firebaseSessionPath()
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, safeStorage.encryptString(JSON.stringify({ refreshToken })), { mode: 0o600 })
  fs.renameSync(tmp, file)
}

function clearFirebaseSession() {
  firebaseSessionGeneration += 1
  firebaseTokenCache = null
  firebaseRefreshPromise = null
  try { fs.rmSync(firebaseSessionPath(), { force: true }) } catch { /* already signed out */ }
}

async function firebaseSignInWithGoogle(googleAccessToken, requestUri, cfg = readPublicConfig()) {
  const response = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=${encodeURIComponent(cfg.apiKey)}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      postBody: new URLSearchParams({ access_token: googleAccessToken, providerId: 'google.com' }).toString(),
      requestUri,
      returnIdpCredential: false,
      returnSecureToken: true,
    }),
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok || !payload.idToken || !payload.refreshToken || !payload.localId) {
    const code = payload?.error?.message
    throw new Error(code ? `Firebase sign-in failed: ${String(code).replace(/_/g, ' ').toLowerCase()}.` : `Firebase sign-in failed (${response.status}).`)
  }
  return payload
}

async function refreshFirebaseIdToken(cfg = readPublicConfig()) {
  const generation = firebaseSessionGeneration
  const session = readFirebaseSession()
  if (!session) throw new FirebaseSessionError('The saved Firebase session is temporarily unavailable.')
  const response = await fetch(`https://securetoken.googleapis.com/v1/token?key=${encodeURIComponent(cfg.apiKey)}`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: session.refreshToken }),
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) {
    const code = payload?.error?.message || payload?.error || ''
    const terminal = isTerminalRefreshError(code)
    throw new FirebaseSessionError(
      terminal ? 'The saved Firebase session has expired. Sign in again.' : 'Kaisola could not refresh Google sign-in right now.',
      terminal,
    )
  }
  if (!payload.id_token) throw new FirebaseSessionError('Google returned an incomplete session refresh. Kaisola kept the saved sign-in.')
  if (generation !== firebaseSessionGeneration) throw new FirebaseSessionError('Sign-in state changed while refreshing.')
  writeFirebaseSession(payload.refresh_token || session.refreshToken)
  firebaseTokenCache = {
    idToken: payload.id_token,
    expiresAt: Date.now() + Math.max(60, Number(payload.expires_in) || 3600) * 1000,
  }
  return firebaseTokenCache.idToken
}

async function currentFirebaseIdToken(force = false, cfg = readPublicConfig()) {
  if (!force && firebaseTokenCache && firebaseTokenCache.expiresAt > Date.now() + 60_000) return firebaseTokenCache.idToken
  if (firebaseRefreshPromise) return firebaseRefreshPromise
  const pending = refreshFirebaseIdToken(cfg)
  firebaseRefreshPromise = pending
  try {
    return await pending
  } finally {
    if (firebaseRefreshPromise === pending) firebaseRefreshPromise = null
  }
}

async function verifyServerSession(idToken, cfg = readPublicConfig()) {
  const response = await fetch(cfg.serverUrl, {
    method: 'POST',
    headers: { authorization: `Bearer ${idToken}`, 'content-type': 'application/json' },
    body: '{}',
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok || !payload.ok || !payload.user?.uid) {
    throw new Error(payload?.message || `Kaisola's login server could not verify this session (${response.status}).`)
  }
  return payload.user
}

const callbackPage = (ok, message) => `<!doctype html><meta charset="utf-8"><title>Kaisola</title><style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;color:#202124;background:#fff}.card{max-width:420px;padding:32px;text-align:center}h1{font-size:22px;margin:0 0 10px}p{color:#6b7280;line-height:1.5}</style><div class="card"><h1>${ok ? 'Signed in to Kaisola' : 'Sign-in did not finish'}</h1><p>${message}</p></div>`

function closeGoogleSession() {
  const current = googleSession
  googleSession = null
  if (!current) return
  clearTimeout(current.timer)
  try { current.server.close() } catch { /* already closed */ }
}

async function exchangeGoogleCode({ code, clientId, clientSecret, redirectUri, verifier, nonce }) {
  const body = new URLSearchParams({
    code,
    client_id: clientId,
    redirect_uri: redirectUri,
    grant_type: 'authorization_code',
    code_verifier: verifier,
  })
  if (clientSecret) body.set('client_secret', clientSecret)
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  })
  const tokens = await response.json().catch(() => ({}))
  if (!response.ok) {
    const detail = String(tokens.error_description || tokens.error || '')
      .replace(/[\r\n]+/g, ' ')
      .slice(0, 240)
    throw new Error(detail ? `Google token exchange failed: ${detail}` : `Google token exchange failed (${response.status}).`)
  }
  const claims = decodeIdToken(tokens.id_token)
  const issuerOk = claims?.iss === 'https://accounts.google.com' || claims?.iss === 'accounts.google.com'
  if (!claims || !issuerOk || claims.aud !== clientId || claims.nonce !== nonce || Number(claims.exp) * 1000 <= Date.now()) {
    throw new Error('Google returned an invalid identity token.')
  }
  if (!tokens.access_token) throw new Error('Google did not return an access token for Firebase.')
  if (!claims.sub || !claims.email) throw new Error('Google did not return an email identity.')
  return { tokens, claims }
}

function registerAuthHandlers(ipcMain) {
  ipcMain.handle('auth:start', (event, { id, command, args } = {}) => {
    if (sessions.has(id)) return { ok: true, reused: true }
    let child
    try {
      child = spawn(command, args || [], { env: agentEnv(), stdio: ['pipe', 'pipe', 'pipe'] })
    } catch (err) {
      return { ok: false, message: err.message }
    }
    sessions.set(id, child)
    const sender = event.sender
    const chan = `auth:event:${id}`
    let url = null
    let code = null
    let buf = ''
    const send = (ev) => { if (!sender.isDestroyed()) sender.send(chan, ev) }
    const onData = (d) => {
      const text = d.toString('utf8').replace(ANSI, '')
      buf += text
      buf = buf.slice(-4000)
      if (!url) { const m = buf.match(URL_RE); if (m) url = m[0] }
      if (!code) { const m = buf.match(CODE_RE); if (m) code = m[0] }
      send({ phase: 'progress', url, code })
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', onData)
    child.on('exit', (exitCode) => {
      sessions.delete(id)
      send({ phase: exitCode === 0 ? 'done' : 'failed', exitCode, url, code, tail: buf.slice(-300) })
    })
    child.on('error', (err) => {
      sessions.delete(id)
      send({ phase: 'failed', error: err.message })
    })
    return { ok: true }
  })

  ipcMain.handle('auth:cancel', (_e, { id } = {}) => {
    const c = sessions.get(id)
    if (c) {
      try { c.kill() } catch { /* noop */ }
      sessions.delete(id)
    }
    return { ok: true }
  })

  ipcMain.handle('app-auth:status', async () => {
    const configIssue = authConfigIssue()
    const configured = !configIssue
    const profile = readIdentity()
    if (!configured) return { configured: false, profile: null, message: configIssue }
    if (!profile) return { configured: true, profile: null }
    if (!readFirebaseSession()) {
      return { configured: true, serverVerified: false, profile, message: 'The secure session is temporarily unavailable; Kaisola kept your account.' }
    }
    let idToken
    try {
      idToken = await currentFirebaseIdToken()
    } catch (error) {
      if (error?.terminal === true) {
        clearFirebaseSession()
        try { fs.rmSync(identityPath(), { force: true }) } catch { /* already signed out */ }
        return { configured: true, serverVerified: false, profile: null, message: String(error?.message || error) }
      }
      return { configured: true, serverVerified: false, profile, message: String(error?.message || error) }
    }
    try {
      const user = await verifyServerSession(idToken)
      const tokenClaims = decodeIdToken(idToken)
      const avatarUrl = safeAvatarUrl(profile.avatarUrl || user.photoUrl || tokenClaims?.picture)
      const verified = { ...profile, id: String(user.uid), ...(avatarUrl ? { avatarUrl } : {}), serverVerified: true }
      writeIdentity(verified)
      return { ok: true, configured: true, serverVerified: true, profile: verified }
    } catch (error) {
      return { configured: true, serverVerified: false, profile, message: String(error?.message || error) }
    }
  })

  ipcMain.handle('app-auth:google-start', async (event) => {
    const clientId = googleClientId()
    const clientSecret = googleClientSecret(clientId)
    const firebase = readPublicConfig()
    const configIssue = authConfigIssue()
    if (configIssue || !clientId || !clientSecret || !firebase.projectId || !firebase.apiKey || !firebase.serverUrl) {
      return { ok: false, configured: false, message: configIssue || 'This build is missing its Firebase or Google OAuth configuration.' }
    }
    if (googleSession) return { ok: true, configured: true, pending: true }

    const verifier = b64url(crypto.randomBytes(48))
    const state = b64url(crypto.randomBytes(24))
    const nonce = b64url(crypto.randomBytes(24))
    const sender = event.sender
    const server = http.createServer()
    const listening = new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', resolve)
    })
    try {
      await listening
    } catch (error) {
      return { ok: false, configured: true, message: String(error?.message || error) }
    }
    const address = server.address()
    if (!address || typeof address === 'string') {
      server.close()
      return { ok: false, configured: true, message: 'Could not open the secure local OAuth callback.' }
    }
    const redirectUri = `http://127.0.0.1:${address.port}/oauth/callback`
    const timer = setTimeout(() => {
      if (!sender.isDestroyed()) sender.send('app-auth:changed', { ok: false, message: 'Google sign-in timed out.' })
      closeGoogleSession()
    }, 5 * 60 * 1000)
    if (timer.unref) timer.unref()
    googleSession = { server, timer }

    server.on('request', async (req, res) => {
      try {
        const url = new URL(req.url || '/', redirectUri)
        if (url.pathname !== '/oauth/callback') {
          res.writeHead(404).end()
          return
        }
        const returnedState = url.searchParams.get('state')
        const code = url.searchParams.get('code')
        const oauthError = url.searchParams.get('error')
        if (oauthError) throw new Error(oauthError === 'access_denied' ? 'Google sign-in was cancelled.' : `Google sign-in failed: ${oauthError}`)
        if (!code || returnedState !== state) throw new Error('The OAuth callback could not be verified.')
        const { tokens, claims } = await exchangeGoogleCode({ code, clientId, clientSecret, redirectUri, verifier, nonce })
        const firebaseSession = await firebaseSignInWithGoogle(tokens.access_token, 'http://localhost', firebase)
        firebaseTokenCache = {
          idToken: firebaseSession.idToken,
          expiresAt: Date.now() + Math.max(60, Number(firebaseSession.expiresIn) || 3600) * 1000,
        }
        const serverUser = await verifyServerSession(firebaseSession.idToken, firebase)
        firebaseSessionGeneration += 1
        writeFirebaseSession(firebaseSession.refreshToken)
        const avatarUrl = safeAvatarUrl(firebaseSession.photoUrl || claims.picture)
        const profile = {
          provider: 'google',
          id: String(serverUser.uid || firebaseSession.localId),
          email: String(serverUser.email || firebaseSession.email || claims.email),
          name: typeof serverUser.name === 'string' ? serverUser.name : (firebaseSession.displayName || claims.name || undefined),
          ...(avatarUrl ? { avatarUrl } : {}),
          signedInAt: Date.now(),
          serverVerified: true,
        }
        writeIdentity(profile)
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(callbackPage(true, 'You can close this tab and return to the app.'))
        if (!sender.isDestroyed()) sender.send('app-auth:changed', { ok: true, configured: true, serverVerified: true, profile })
      } catch (error) {
        firebaseTokenCache = null
        const message = String(error?.message || error)
        res.writeHead(400, { 'content-type': 'text/html; charset=utf-8' }).end(callbackPage(false, 'Return to Kaisola and try again.'))
        if (!sender.isDestroyed()) sender.send('app-auth:changed', { ok: false, configured: true, message })
      } finally {
        closeGoogleSession()
      }
    })

    const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth')
    authUrl.search = new URLSearchParams({
      client_id: clientId,
      redirect_uri: redirectUri,
      response_type: 'code',
      scope: 'openid email profile',
      code_challenge: pkceChallenge(verifier),
      code_challenge_method: 'S256',
      state,
      nonce,
      prompt: 'select_account',
    }).toString()
    try {
      await shell.openExternal(authUrl.toString())
      return { ok: true, configured: true, pending: true }
    } catch (error) {
      closeGoogleSession()
      return { ok: false, configured: true, message: String(error?.message || error) }
    }
  })

  ipcMain.handle('app-auth:sign-out', () => {
    closeGoogleSession()
    clearFirebaseSession()
    try { fs.rmSync(identityPath(), { force: true }) } catch { /* already signed out */ }
    return { ok: true, configured: firebaseConfigured(), serverVerified: false, profile: null }
  })
}

function disposeAuth() {
  closeGoogleSession()
  for (const c of sessions.values()) {
    try { c.kill() } catch { /* noop */ }
  }
  sessions.clear()
}

module.exports = {
  registerAuthHandlers,
  disposeAuth,
  __test: { pkceChallenge, decodeIdToken, exchangeGoogleCode, firebaseSignInWithGoogle, isTerminalRefreshError, readPublicConfig },
}
