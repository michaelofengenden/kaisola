// Proves the session/new "Invalid params" root cause: ACP agents zod-reject
// an mcpServers entry whose headers is an OBJECT map; the spec wants
// HttpHeader[] ({name,value} pairs). Speaks raw line-delimited JSON-RPC to
// the real agent binaries, old shape vs new shape vs none.
import { spawn } from 'node:child_process'
import { randomBytes, timingSafeEqual } from 'node:crypto'
import http from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const CWD = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const AGENTS = [
  { id: 'claude', cmd: 'npx', args: ['-y', '@zed-industries/claude-code-acp'] },
  { id: 'codex', cmd: 'npx', args: ['-y', '@zed-industries/codex-acp'] },
]

function once(agent, shapeName, mcpServers) {
  return new Promise((resolve) => {
    const env = { ...process.env }
    delete env.CLAUDECODE
    delete env.CLAUDE_CODE_ENTRYPOINT
    const p = spawn(agent.cmd, agent.args, { cwd: CWD, env, stdio: ['pipe', 'pipe', 'pipe'] })
    let buf = ''
    let nextId = 1
    const pending = new Map()
    const finish = (out) => { try { p.kill() } catch {} ; clearTimeout(timer); resolve({ agent: agent.id, shape: shapeName, ...out }) }
    const timer = setTimeout(() => finish({ outcome: 'timeout' }), 120_000)
    const send = (method, params) => new Promise((res2, rej2) => {
      const id = nextId++
      pending.set(id, { res2, rej2 })
      p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
    })
    p.stdout.on('data', (d) => {
      buf += d.toString()
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim()
        buf = buf.slice(nl + 1)
        if (!line) continue
        let m
        try { m = JSON.parse(line) } catch { continue }
        if (m.id != null && (m.result !== undefined || m.error !== undefined)) {
          const pr = pending.get(m.id)
          if (pr) { pending.delete(m.id); m.error ? pr.rej2(m.error) : pr.res2(m.result) }
        } else if (m.id != null && m.method) {
          // agent → client request (permissions etc.) — refuse politely
          p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'probe' } }) + '\n')
        }
      }
    })
    p.on('error', (e) => finish({ outcome: 'spawn-error', detail: e.message }))
    p.on('exit', (c) => finish({ outcome: `exited(${c})` }))
    ;(async () => {
      try {
        await send('initialize', { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: true } })
        try {
          const s = await send('session/new', { cwd: CWD, mcpServers })
          finish({ outcome: 'SESSION_OK', sessionId: s && s.sessionId ? 'yes' : 'missing' })
        } catch (err) {
          finish({ outcome: 'SESSION_ERR', code: err.code, message: err.message, data: JSON.stringify(err.data || null).slice(0, 300) })
        }
      } catch (err) {
        finish({ outcome: 'INIT_ERR', code: err.code, message: err.message })
      }
    })()
  })
}

const MAX_REQUEST_BYTES = 1024 * 1024
// This probe is for native ACP clients only. An empty exact allowlist means any
// browser Origin is rejected after parsing; native requests omit Origin.
const ALLOWED_BROWSER_ORIGINS = new Set()

const sendJson = (res, statusCode, body) => {
  res.statusCode = statusCode
  res.setHeader('content-type', 'application/json')
  res.end(JSON.stringify(body))
}

const hasAllowedOrigin = (origin) => {
  if (origin == null) return true
  try {
    return ALLOWED_BROWSER_ORIGINS.has(new URL(origin).origin)
  } catch {
    return false
  }
}

const hasValidToken = (authorization, token) => {
  const actual = Buffer.from(typeof authorization === 'string' ? authorization : '', 'utf8')
  const expected = Buffer.from(`Bearer ${token}`, 'utf8')
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

const rpcResult = (message) => {
  if (message.method === 'initialize') {
    return {
      capabilities: {},
      protocolVersion: '2025-03-26',
      serverInfo: { name: 'probe', version: '0' },
    }
  }
  if (message.method === 'ping') return {}
  if (message.method === 'tools/list') return { tools: [] }
  if (message.method === 'resources/list') return { resources: [] }
  if (message.method === 'prompts/list') return { prompts: [] }
  return null
}

export function createProbeServer(token) {
  if (typeof token !== 'string' || token.length < 32) throw new Error('Probe token must contain at least 32 characters')
  return http.createServer((req, res) => {
    if (req.method !== 'POST' || req.url !== '/') {
      res.statusCode = 404
      res.end()
      return
    }
    if (!hasAllowedOrigin(req.headers.origin)) {
      sendJson(res, 403, { error: 'Browser origins are not allowed' })
      return
    }
    if (!hasValidToken(req.headers.authorization, token)) {
      sendJson(res, 401, { error: 'Invalid probe token' })
      return
    }

    let body = ''
    let tooLarge = false
    req.on('data', (chunk) => {
      if (tooLarge) return
      body += chunk
      if (Buffer.byteLength(body, 'utf8') > MAX_REQUEST_BYTES) {
        tooLarge = true
        body = ''
      }
    })
    req.on('end', () => {
      if (tooLarge) {
        sendJson(res, 413, { error: 'Probe request is too large' })
        return
      }
      let message
      try {
        message = JSON.parse(body)
      } catch {
        sendJson(res, 400, { error: 'Invalid JSON' })
        return
      }
      if (message?.jsonrpc !== '2.0' || typeof message.method !== 'string') {
        sendJson(res, 400, { error: 'Invalid JSON-RPC request' })
        return
      }
      if (message.method === 'notifications/initialized' && message.id == null) {
        res.statusCode = 202
        res.end()
        return
      }
      const result = rpcResult(message)
      if (result == null) {
        sendJson(res, 200, { jsonrpc: '2.0', id: message.id ?? null, error: { code: -32601, message: 'Method not found' } })
        return
      }
      sendJson(res, 200, { jsonrpc: '2.0', id: message.id ?? null, result })
    })
  })
}

async function main() {
  const probeToken = randomBytes(32).toString('base64url')
  const mcpSrv = createProbeServer(probeToken)
  await new Promise((resolve, reject) => {
    mcpSrv.once('error', reject)
    mcpSrv.listen(0, '127.0.0.1', resolve)
  })
  const address = mcpSrv.address()
  if (!address || typeof address === 'string') throw new Error('Probe server did not receive a TCP address')
  const url = `http://127.0.0.1:${address.port}/`

  const shapes = {
    oldObj: [{ type: 'http', name: 'kaisola', url, headers: { Authorization: `Bearer ${probeToken}` } }],
    newArr: [{ type: 'http', name: 'kaisola', url, headers: [{ name: 'Authorization', value: `Bearer ${probeToken}` }] }],
    none: [],
  }

  try {
    for (const agent of AGENTS) {
      for (const [name, servers] of Object.entries(shapes)) {
        const result = await once(agent, name, servers)
        console.log(JSON.stringify(result))
      }
    }
  } finally {
    await new Promise((resolve, reject) => mcpSrv.close((error) => error ? reject(error) : resolve()))
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  await main()
}
