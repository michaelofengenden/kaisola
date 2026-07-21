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
const GOOGLE_CALLBACK_PORT = 42813
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
  const serverUrl = String(
    process.env.KAISOLA_AUTH_SERVER_URL ||
    fileConfig.serverUrl ||
    (projectId ? `https://us-central1-${projectId}.cloudfunctions.net/session` : ''),
  ).trim()
  const relayUrl = String(process.env.KAISOLA_LINK_URL || fileConfig.relayUrl || '').trim()
  return {
    projectId: /^[a-z0-9][a-z0-9-]{4,60}$/.test(projectId) ? projectId : null,
    apiKey: /^[a-zA-Z0-9_-]{20,200}$/.test(apiKey) ? apiKey : null,
    serverUrl: /^https:\/\//.test(serverUrl) ? serverUrl : null,
    relayUrl: /^https:\/\//.test(relayUrl) ? relayUrl : null,
  }
}

function authConfigIssue() {
  const cfg = readPublicConfig()
  if (!cfg.projectId || !cfg.apiKey || !cfg.serverUrl) {
    return 'This build is missing its Firebase public configuration.'
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

function firebaseAuthMessage(payload, status, stage) {
  const code = String(payload?.error?.message || '').split(/\s|:/)[0]
  if (code === 'OPERATION_NOT_ALLOWED') return 'Google sign-in is not enabled for this Firebase project.'
  if (code === 'INVALID_IDP_RESPONSE' || code === 'INVALID_PENDING_TOKEN') return 'Google returned a sign-in response that Firebase could not verify.'
  if (code === 'FEDERATED_USER_ID_ALREADY_LINKED') return 'This Google account is already linked to another Kaisola account.'
  return `${stage} failed${code ? `: ${code.replace(/_/g, ' ').toLowerCase()}` : ` (${status})`}.`
}

async function createFirebaseAuthUri(continueUri, context, cfg = readPublicConfig()) {
  const response = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri?key=${encodeURIComponent(cfg.apiKey)}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      providerId: 'google.com',
      continueUri,
      oauthScope: 'openid email profile',
      authFlowType: 'CODE_FLOW',
      context,
    }),
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(firebaseAuthMessage(payload, response.status, 'Starting Google sign-in'))
  let authUri
  try { authUri = new URL(payload.authUri) } catch { /* handled below */ }
  const sessionId = String(payload.sessionId || '')
  if (!authUri || authUri.protocol !== 'https:' || authUri.hostname !== 'accounts.google.com' || !sessionId || sessionId.length > 4096) {
    throw new Error('Firebase returned an invalid Google sign-in session.')
  }
  return { authUri: authUri.toString(), sessionId }
}

async function firebaseSignInWithAuthResponse({ requestUri, postBody, sessionId, context }, cfg = readPublicConfig()) {
  const response = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=${encodeURIComponent(cfg.apiKey)}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      postBody,
      requestUri,
      sessionId,
      returnIdpCredential: true,
      returnSecureToken: true,
    }),
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok || !payload.idToken || !payload.refreshToken || !payload.localId) {
    throw new Error(firebaseAuthMessage(payload, response.status, 'Completing Google sign-in'))
  }
  if (payload.context !== context) throw new Error('Firebase returned a sign-in response for a different session.')
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

const escapeHtml = (value) => String(value || '')
  .replace(/&/g, '&amp;')
  .replace(/</g, '&lt;')
  .replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;')
  .replace(/'/g, '&#39;')

const callbackPage = (ok, message) => `<!doctype html><meta charset="utf-8"><title>Kaisola</title><style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;color:#202124;background:#fff}.card{max-width:460px;padding:32px;text-align:center}h1{font-size:22px;margin:0 0 10px}p{color:#6b7280;line-height:1.5}</style><div class="card"><h1>${ok ? 'Signed in to Kaisola' : 'Sign-in did not finish'}</h1><p>${escapeHtml(message)}</p></div>`

function closeGoogleSession() {
  const current = googleSession
  googleSession = null
  if (!current) return
  current.cancelled = true
  clearTimeout(current.timer)
  try { current.server.close() } catch { /* already closed */ }
}

function canControlGoogleSession(session, sender) {
  if (!session) return true
  return session.sender === sender || !session.sender || session.sender.isDestroyed?.()
}

const sameGoogleSession = (current, attempt) => !!attempt && current === attempt

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
    const firebase = readPublicConfig()
    const configIssue = authConfigIssue()
    if (configIssue || !firebase.projectId || !firebase.apiKey || !firebase.serverUrl) {
      return { ok: false, configured: false, message: configIssue || 'This build is missing its Firebase configuration.' }
    }
    if (googleSession) {
      return canControlGoogleSession(googleSession, event.sender)
        ? { ok: true, configured: true, pending: true }
        : { ok: false, configured: true, pending: true, message: 'Google sign-in is already open in another Kaisola window.' }
    }

    const context = b64url(crypto.randomBytes(24))
    const sender = event.sender
    const server = http.createServer()
    const listening = new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(GOOGLE_CALLBACK_PORT, '127.0.0.1', resolve)
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
    const redirectUri = `http://localhost:${address.port}/oauth/callback`
    const session = { server, timer: null, sender, sessionId: null, cancelled: false }
    const timer = setTimeout(() => {
      if (googleSession !== session || session.cancelled) return
      if (!sender.isDestroyed()) sender.send('app-auth:changed', { ok: false, message: 'Google sign-in timed out.' })
      closeGoogleSession()
    }, 5 * 60 * 1000)
    if (timer.unref) timer.unref()
    session.timer = timer
    googleSession = session

    server.on('request', async (req, res) => {
      // Lexically bind the server to the attempt that created it. A cancelled
      // server callback must never capture or close a replacement attempt.
      const requestSession = session
      try {
        const url = new URL(req.url || '/', redirectUri)
        if (url.pathname !== '/oauth/callback') {
          res.writeHead(404).end()
          return
        }
        const oauthError = url.searchParams.get('error')
        if (oauthError) throw new Error(oauthError === 'access_denied' ? 'Google sign-in was cancelled.' : `Google sign-in failed: ${oauthError}`)
        const postBody = url.search.slice(1)
        if (!postBody || postBody.length > 20_000) throw new Error('The Google sign-in callback was empty or too large.')
        if (!requestSession || requestSession.cancelled) throw new Error('Google sign-in was cancelled.')
        const firebaseSession = await firebaseSignInWithAuthResponse({ requestUri: redirectUri, postBody, sessionId: requestSession.sessionId, context }, firebase)
        if (requestSession.cancelled || !sameGoogleSession(googleSession, requestSession)) throw new Error('Google sign-in was cancelled.')
        const serverUser = await verifyServerSession(firebaseSession.idToken, firebase)
        if (requestSession.cancelled || !sameGoogleSession(googleSession, requestSession)) throw new Error('Google sign-in was cancelled.')
        firebaseTokenCache = {
          idToken: firebaseSession.idToken,
          expiresAt: Date.now() + Math.max(60, Number(firebaseSession.expiresIn) || 3600) * 1000,
        }
        firebaseSessionGeneration += 1
        writeFirebaseSession(firebaseSession.refreshToken)
        const claims = decodeIdToken(firebaseSession.idToken) || {}
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
        if (sameGoogleSession(googleSession, requestSession)) firebaseTokenCache = null
        const message = String(error?.message || error)
        res.writeHead(400, { 'content-type': 'text/html; charset=utf-8' }).end(callbackPage(false, `${message} Return to Kaisola and try again.`))
        if (!requestSession?.cancelled && !sender.isDestroyed()) sender.send('app-auth:changed', { ok: false, configured: true, message })
      } finally {
        if (sameGoogleSession(googleSession, requestSession)) closeGoogleSession()
      }
    })

    try {
      const { authUri, sessionId } = await createFirebaseAuthUri(redirectUri, context, firebase)
      if (!sameGoogleSession(googleSession, session) || session.cancelled) throw new Error('The local Google sign-in session closed before it could start.')
      session.sessionId = sessionId
      await shell.openExternal(authUri)
      if (!sameGoogleSession(googleSession, session) || session.cancelled) return { ok: false, configured: true, pending: false, message: 'Google sign-in was cancelled.' }
      return { ok: true, configured: true, pending: true }
    } catch (error) {
      if (sameGoogleSession(googleSession, session)) closeGoogleSession()
      return { ok: false, configured: true, message: String(error?.message || error) }
    }
  })

  ipcMain.handle('app-auth:google-cancel', (event) => {
    if (!canControlGoogleSession(googleSession, event.sender)) {
      return { ok: false, configured: firebaseConfigured(), pending: true, message: 'Google sign-in belongs to another Kaisola window.' }
    }
    closeGoogleSession()
    return { ok: true, configured: firebaseConfigured(), pending: false, profile: readIdentity() }
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
  currentFirebaseIdToken,
  readPublicConfig,
  __test: { decodeIdToken, createFirebaseAuthUri, firebaseSignInWithAuthResponse, escapeHtml, isTerminalRefreshError, readPublicConfig, canControlGoogleSession, sameGoogleSession },
}
