const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')
const output = path.join(root, 'electron', 'firebase-config.json')

const projectId = String(process.env.KAISOLA_FIREBASE_PROJECT_ID || 'kaisola-a9ab7').trim()
const apiKey = String(process.env.KAISOLA_FIREBASE_API_KEY || '').trim()
const serverUrl = String(
  process.env.KAISOLA_AUTH_SERVER_URL ||
    `https://us-central1-${projectId}.cloudfunctions.net/session`,
).trim()
const relayUrl = String(process.env.KAISOLA_LINK_URL || '').trim()

if (!/^[a-z0-9][a-z0-9-]{4,60}$/.test(projectId)) {
  throw new Error('KAISOLA_FIREBASE_PROJECT_ID is missing or invalid.')
}
if (!/^[a-zA-Z0-9_-]{20,200}$/.test(apiKey)) {
  throw new Error('KAISOLA_FIREBASE_API_KEY is missing or invalid.')
}
if (!/^https:\/\//.test(serverUrl)) {
  throw new Error('KAISOLA_AUTH_SERVER_URL must be an HTTPS URL.')
}
if (relayUrl && !/^https:\/\//.test(relayUrl)) {
  throw new Error('KAISOLA_LINK_URL must be an HTTPS URL.')
}

fs.writeFileSync(
  output,
  `${JSON.stringify({ projectId, apiKey, serverUrl, ...(relayUrl ? { relayUrl } : {}) }, null, 2)}\n`,
  { mode: 0o600 },
)
console.log('Generated Firebase desktop config for packaging.')
