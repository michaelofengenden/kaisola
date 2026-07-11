const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')
const output = path.join(root, 'electron', 'firebase-config.json')
const oauthOutput = path.join(root, 'electron', 'google-oauth.json')

const projectId = String(process.env.KAISOLA_FIREBASE_PROJECT_ID || 'kaisola-a9ab7').trim()
const apiKey = String(process.env.KAISOLA_FIREBASE_API_KEY || '').trim()
const googleClientId = String(
  process.env.KAISOLA_GOOGLE_CLIENT_ID ||
    '60313772450-dr4566k39ntm1k2mat1k99jau8sg4du0.apps.googleusercontent.com',
).trim()
const googleClientSecret = String(process.env.KAISOLA_GOOGLE_CLIENT_SECRET || '').trim()
const serverUrl = String(
  process.env.KAISOLA_AUTH_SERVER_URL ||
    `https://us-central1-${projectId}.cloudfunctions.net/session`,
).trim()

if (!/^[a-z0-9][a-z0-9-]{4,60}$/.test(projectId)) {
  throw new Error('KAISOLA_FIREBASE_PROJECT_ID is missing or invalid.')
}
if (!/^[a-zA-Z0-9_-]{20,200}$/.test(apiKey)) {
  throw new Error('KAISOLA_FIREBASE_API_KEY is missing or invalid.')
}
if (!/^[a-zA-Z0-9._-]+\.apps\.googleusercontent\.com$/.test(googleClientId)) {
  throw new Error('KAISOLA_GOOGLE_CLIENT_ID is missing or invalid.')
}
if (!/^[a-zA-Z0-9._-]{8,256}$/.test(googleClientSecret)) {
  throw new Error('KAISOLA_GOOGLE_CLIENT_SECRET is missing or invalid.')
}
if (!/^https:\/\//.test(serverUrl)) {
  throw new Error('KAISOLA_AUTH_SERVER_URL must be an HTTPS URL.')
}

fs.writeFileSync(
  output,
  `${JSON.stringify({ projectId, apiKey, googleClientId, serverUrl }, null, 2)}\n`,
  { mode: 0o600 },
)
fs.writeFileSync(
  oauthOutput,
  `${JSON.stringify({ installed: { client_id: googleClientId, client_secret: googleClientSecret } }, null, 2)}\n`,
  { mode: 0o600 },
)
console.log('Generated Firebase and Google Desktop OAuth config for packaging.')
