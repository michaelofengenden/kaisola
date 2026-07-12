const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { parseInstallUrl, __test } = require('./ipc/mcpCatalog.cjs')

test('normalizes bounded HTTP and stdio server specs', () => {
  assert.equal(__test.normalizeSpec({ url: 'file:///tmp/server' }), null)
  assert.equal(__test.normalizeSpec({ url: 'https://example.test/mcp' }).kind, 'http')
  assert.equal(__test.normalizeSpec({ url: 'https://user:password@example.test/mcp' }), null)
  assert.equal(__test.normalizeSpec({ url: 'https://example.test/mcp?api_key=plaintext' }), null)
  assert.equal(__test.normalizeSpec({ url: 'https://example.test/mcp?api_key=${API_TOKEN}' }).kind, 'http')
  const stdio = __test.normalizeSpec({ command: 'node', args: ['server.js'], env: { API_TOKEN: '${API_TOKEN}' } })
  assert.equal(stdio.kind, 'stdio')
  assert.deepEqual(stdio.args, ['server.js'])
})

test('parses JSON and Streamable HTTP SSE response bodies', () => {
  assert.deepEqual(__test.parseRpcBody('{"jsonrpc":"2.0","id":1,"result":{}}', 'application/json'), {
    jsonrpc: '2.0', id: 1, result: {},
  })
  assert.deepEqual(__test.parseRpcBody('event: message\ndata: {"jsonrpc":"2.0","id":2,"result":{"tools":[]}}\n\n', 'text/event-stream'), {
    jsonrpc: '2.0', id: 2, result: { tools: [] },
  })
})

test('install links reject plaintext secrets and oversized configs', () => {
  const encoded = (config) => Buffer.from(JSON.stringify(config)).toString('base64')
  const safe = `kaisola://mcp/install?name=docs&config=${encodeURIComponent(encoded({ url: 'https://example.test/mcp', headers: { Authorization: '${AUTH_TOKEN}' } }))}`
  assert.equal(parseInstallUrl(safe).name, 'docs')
  const secret = `kaisola://mcp/install?name=docs&config=${encodeURIComponent(encoded({ url: 'https://example.test/mcp', headers: { Authorization: 'Bearer plaintext' } }))}`
  assert.equal(parseInstallUrl(secret), null)
  const oversized = `kaisola://mcp/install?name=docs&config=${'A'.repeat(140_000)}`
  assert.equal(parseInstallUrl(oversized), null)

  const userinfo = `kaisola://mcp/install?name=docs&config=${encodeURIComponent(encoded({ url: 'https://user:password@example.test/mcp' }))}`
  assert.equal(parseInstallUrl(userinfo), null)
  const querySecret = `kaisola://mcp/install?name=docs&config=${encodeURIComponent(encoded({ url: 'https://example.test/mcp?api_key=plaintext' }))}`
  assert.equal(parseInstallUrl(querySecret), null)
  assert.equal(__test.sanitizeRaw({ url: 'https://example.test/mcp?token=plaintext' }), null)
})

test('spec hashes are stable across env/header key order', () => {
  const a = __test.normalizeSpec({ command: 'node', env: { Z: '1', A: '2' } })
  const b = __test.normalizeSpec({ command: 'node', env: { A: '2', Z: '1' } })
  assert.equal(__test.specHash(a), __test.specHash(b))
})

test('extension-owned mutations preserve same-name user servers and user edits', () => {
  const userConfig = {
    mcpServers: { context7: { url: 'https://user.example.test/mcp' } },
    disabled: [],
  }
  const collision = __test.planAddUserServer(userConfig, 'context7', { url: 'https://mcp.context7.com/mcp' }, 'mcp.context7')
  assert.equal(collision.ok, false)
  assert.equal(collision.conflict, true)
  assert.equal(userConfig.mcpServers.context7.url, 'https://user.example.test/mcp')

  const exact = __test.planAddUserServer(userConfig, 'context7', { url: 'https://user.example.test/mcp' }, 'mcp.context7')
  assert.equal(exact.ok, true)
  assert.equal(exact.created, false)
  assert.equal(exact.owned, false)
  const exactRemoval = __test.planRemoveUserServer(exact.config, 'context7', 'mcp.context7')
  assert.equal(exactRemoval.ok, true)
  assert.equal(exactRemoval.preserved, true)
  assert.equal(exactRemoval.config, undefined)

  const created = __test.planAddUserServer({ mcpServers: {}, disabled: ['context7'] }, 'context7', { url: 'https://mcp.context7.com/mcp' }, 'mcp.context7')
  assert.equal(created.ok, true)
  assert.equal(created.created, true)
  assert.equal(created.owned, true)
  assert.deepEqual(created.config.disabled, [])

  const edited = structuredClone(created.config)
  edited.mcpServers.context7 = { url: 'https://user-edited.example.test/mcp' }
  const editedRemoval = __test.planRemoveUserServer(edited, 'context7', 'mcp.context7')
  assert.equal(editedRemoval.ok, true)
  assert.equal(editedRemoval.preserved, true)
  assert.equal(editedRemoval.modified, true)
  assert.equal(editedRemoval.config.mcpServers.context7.url, 'https://user-edited.example.test/mcp')
  assert.equal(editedRemoval.config.extensionOwners.context7, undefined)

  const removed = __test.planRemoveUserServer(created.config, 'context7', 'mcp.context7')
  assert.equal(removed.ok, true)
  assert.equal(removed.removed, true)
  assert.equal(removed.config.mcpServers.context7, undefined)
})

test('MCP state writes are atomic and private', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-mcp-mode-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const file = path.join(root, 'mcp-servers.json')
  __test.writePrivateJson(file, { mcpServers: { docs: { url: 'https://example.test/mcp' } } })
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  assert.deepEqual(fs.readdirSync(root), ['mcp-servers.json'])
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).mcpServers.docs.url, 'https://example.test/mcp')
})

test('Claude handoff preserves secret placeholders instead of expanding them to disk', () => {
  const config = {
    mcpServers: {
      docs: { url: 'https://example.test/mcp', headers: { Authorization: '${AUTH_TOKEN}' } },
      local: { command: 'node', args: ['server.js'], env: { API_TOKEN: '${API_TOKEN}' } },
      off: { command: 'node', args: ['off.js'] },
    },
    disabled: ['off'],
  }
  const entries = __test.claudeEntriesFromConfig(config)
  assert.equal(entries.docs.headers.Authorization, '${AUTH_TOKEN}')
  assert.equal(entries.local.env.API_TOKEN, '${API_TOKEN}')
  assert.equal(entries.off, undefined)
})

test('pinned npx specs rewrite to direct spawns of the bundled bin', () => {
  const pinned = '@modelcontextprotocol/server-sequential-thinking@2025.12.18'
  const direct = __test.directSpawnRewrite('npx', ['-y', pinned])
  assert.ok(direct, 'bundled pinned package should rewrite')
  assert.equal(direct.command, process.execPath)
  assert.ok(fs.existsSync(direct.args[0]), `rewritten bin should exist: ${direct.args[0]}`)
  assert.equal(direct.env.ELECTRON_RUN_AS_NODE, '1')

  // anything not bundled at the exact pinned version keeps riding npx
  assert.equal(__test.directSpawnRewrite('npx', ['-y', '@modelcontextprotocol/server-sequential-thinking@0.0.0']), null)
  assert.equal(__test.directSpawnRewrite('npx', ['-y', '@modelcontextprotocol/server-sequential-thinking']), null)
  assert.equal(__test.directSpawnRewrite('npx', ['-y', 'not-bundled-anywhere@1.0.0']), null)
  assert.equal(__test.directSpawnRewrite('node', ['server.js']), null)

  const entries = __test.claudeEntriesFromConfig({
    mcpServers: { 'sequential-thinking': { command: 'npx', args: ['-y', pinned], env: { FOO: '${FOO}' } } },
  })
  const entry = entries['sequential-thinking']
  assert.equal(entry.command, process.execPath)
  assert.equal(entry.args[0], direct.args[0])
  assert.equal(entry.env.ELECTRON_RUN_AS_NODE, '1')
  assert.equal(entry.env.FOO, '${FOO}')
})

test('Codex MCP TOML discovery preserves env references and supported transports', () => {
  const parsed = __test.parseCodexMcpToml(`
[mcp_servers.docs]
url = "https://developers.example.test/mcp"
bearer_token_env_var = "DOCS_TOKEN"

[mcp_servers.local]
command = "/usr/bin/node"
args = ["server.js", "--quiet"]

[mcp_servers.local.env]
API_TOKEN = "\${LOCAL_TOKEN}"

[mcp_servers.remote.env_http_headers]
"X-API-Key" = "REMOTE_KEY"

[mcp_servers.remote]
url = "https://remote.example.test/mcp"
`)
  assert.equal(parsed.mcpServers.docs.url, 'https://developers.example.test/mcp')
  assert.equal(parsed.mcpServers.docs.headers.Authorization, 'Bearer ${DOCS_TOKEN}')
  assert.deepEqual(parsed.mcpServers.local.args, ['server.js', '--quiet'])
  assert.equal(parsed.mcpServers.local.env.API_TOKEN, '${LOCAL_TOKEN}')
  assert.equal(parsed.mcpServers.remote.headers['X-API-Key'], '${REMOTE_KEY}')
})
