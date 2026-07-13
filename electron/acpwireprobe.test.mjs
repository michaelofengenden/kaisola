import test from 'node:test'
import assert from 'node:assert/strict'

import { createProbeServer } from './acpwireprobe.mjs'

const TOKEN = '0123456789abcdef0123456789abcdef'

const listen = async (server) => {
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })
  const address = server.address()
  return `http://127.0.0.1:${address.port}/`
}

test('ACP wire probe requires a per-run token and rejects browser origins', async (t) => {
  const server = createProbeServer(TOKEN)
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const url = await listen(server)
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })

  const missingToken = await fetch(url, { method: 'POST', body })
  assert.equal(missingToken.status, 401)

  const browserRequest = await fetch(url, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, origin: 'https://attacker.example' },
    body,
  })
  assert.equal(browserRequest.status, 403)

  const nativeRequest = await fetch(url, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}` },
    body,
  })
  assert.equal(nativeRequest.status, 200)
  const response = await nativeRequest.json()
  assert.equal(response.result.serverInfo.name, 'probe')
})

test('ACP wire probe exposes only its narrow test RPC surface', async (t) => {
  const server = createProbeServer(TOKEN)
  t.after(() => new Promise((resolve) => server.close(resolve)))
  const url = await listen(server)
  const response = await fetch(url, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: 7, method: 'tools/call', params: {} }),
  })
  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    jsonrpc: '2.0',
    id: 7,
    error: { code: -32601, message: 'Method not found' },
  })
})
