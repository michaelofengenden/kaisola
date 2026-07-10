// Headless device-code login — runs a CLI's device-auth command (e.g.
// `codex login --device-auth`) as a background process, parses the URL + code
// it prints, and streams them to an in-app Sign-in card. No visible terminal:
// the user clicks "Open authorization page", signs in, and the process completes.
const { spawn } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const http = require('node:http')
const path = require('node:path')
const { app, shell } = require('electron')
const { agentEnv } = require('./shellEnv.cjs')

const sessions = new Map() // id → child
const ANSI = /\x1b\[[0-9;]*m/g
const URL_RE = /https?:\/\/[^\s"'<>)\]]+/
const CODE_RE = /\b[A-Z0-9]{4}-[A-Z0-9]{4,8}\b/
let googleSession = null

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

const identityPath = () => path.join(app.getPath('userData'), 'app-identity.json')
const oauthConfigPaths = () => [
  path.join(app.getPath('userData'), 'google-oauth.json'),
  path.join(__dirname, '..', 'google-oauth.json'),
  ...(app.isPackaged ? [path.join(process.resourcesPath, 'google-oauth.json')] : []),
]

function googleClientId() {
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

function readIdentity() {
  try {
    const parsed = JSON.parse(fs.readFileSync(identityPath(), 'utf8'))
    if (parsed?.provider !== 'google' || typeof parsed?.id !== 'string' || typeof parsed?.email !== 'string') return null
    return {
      provider: 'google',
      id: parsed.id.slice(0, 320),
      email: parsed.email.slice(0, 320),
      name: typeof parsed.name === 'string' ? parsed.name.slice(0, 320) : undefined,
      signedInAt: Number(parsed.signedInAt) || undefined,
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

const callbackPage = (ok, message) => `<!doctype html><meta charset="utf-8"><title>Kaisola</title><style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;color:#202124;background:#fff}.card{max-width:420px;padding:32px;text-align:center}h1{font-size:22px;margin:0 0 10px}p{color:#6b7280;line-height:1.5}</style><div class="card"><h1>${ok ? 'Signed in to Kaisola' : 'Sign-in did not finish'}</h1><p>${message}</p></div>`

function closeGoogleSession() {
  const current = googleSession
  googleSession = null
  if (!current) return
  clearTimeout(current.timer)
  try { current.server.close() } catch { /* already closed */ }
}

async function exchangeGoogleCode({ code, clientId, redirectUri, verifier, nonce }) {
  const body = new URLSearchParams({
    code,
    client_id: clientId,
    redirect_uri: redirectUri,
    grant_type: 'authorization_code',
    code_verifier: verifier,
  })
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  })
  if (!response.ok) throw new Error(`Google token exchange failed (${response.status}).`)
  const tokens = await response.json()
  const claims = decodeIdToken(tokens.id_token)
  const issuerOk = claims?.iss === 'https://accounts.google.com' || claims?.iss === 'accounts.google.com'
  if (!claims || !issuerOk || claims.aud !== clientId || claims.nonce !== nonce || Number(claims.exp) * 1000 <= Date.now()) {
    throw new Error('Google returned an invalid identity token.')
  }
  if (!claims.sub || !claims.email) throw new Error('Google did not return an email identity.')
  return {
    provider: 'google',
    id: String(claims.sub),
    email: String(claims.email),
    name: typeof claims.name === 'string' ? claims.name : undefined,
    signedInAt: Date.now(),
  }
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

  ipcMain.handle('app-auth:status', () => ({ configured: !!googleClientId(), profile: readIdentity() }))

  ipcMain.handle('app-auth:google-start', async (event) => {
    const clientId = googleClientId()
    if (!clientId) return { ok: false, configured: false, message: 'This build is not linked to a Google OAuth desktop client yet.' }
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
        const profile = await exchangeGoogleCode({ code, clientId, redirectUri, verifier, nonce })
        writeIdentity(profile)
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(callbackPage(true, 'You can close this tab and return to the app.'))
        if (!sender.isDestroyed()) sender.send('app-auth:changed', { ok: true, configured: true, profile })
      } catch (error) {
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
    try { fs.rmSync(identityPath(), { force: true }) } catch { /* already signed out */ }
    return { ok: true, configured: !!googleClientId(), profile: null }
  })
}

function disposeAuth() {
  closeGoogleSession()
  for (const c of sessions.values()) {
    try { c.kill() } catch { /* noop */ }
  }
  sessions.clear()
}

module.exports = { registerAuthHandlers, disposeAuth, __test: { pkceChallenge, decodeIdToken } }
