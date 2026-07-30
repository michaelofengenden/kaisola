'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')
const {
  addServer,
  buildSessionServers,
  createRegistry,
  disableServer,
  enableServer,
  listServers,
  removeServer,
  resolveConfigPath,
  validateServer,
} = require('../../scripts/native-mcp-registry.cjs')

const script = path.join(__dirname, '..', '..', 'scripts', 'native-mcp-registry.cjs')

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-mcp-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return {
    root,
    configPath: path.join(root, 'native-application-support', 'mcp', 'workspace.json'),
    workspace: path.join(root, 'workspace'),
  }
}

test('native MCP registry add/list/remove/enable/disable round-trips', (t) => {
  const paths = fixture(t)
  const registry = createRegistry(paths)
  assert.deepEqual(registry.list(), [])

  registry.add({
    id: 'local-tools',
    name: 'local',
    transport: 'stdio',
    command: 'node',
    args: ['server.js'],
    env: { API_TOKEN: '${API_TOKEN}' },
  })
  addServer({
    id: 'remote-docs',
    name: 'docs',
    transport: 'http',
    url: 'https://docs.example.test/mcp',
    headers: { Authorization: 'Bearer ${DOCS_TOKEN}' },
  }, paths)

  assert.deepEqual(listServers(paths).map(({ id, enabled }) => ({ id, enabled })), [
    { id: 'local-tools', enabled: true },
    { id: 'remote-docs', enabled: true },
  ])
  assert.equal(disableServer('local-tools', paths).enabled, false)
  assert.equal(listServers(paths)[0].enabled, false)
  assert.equal(enableServer('local-tools', paths).enabled, true)
  assert.equal(removeServer('remote-docs', paths), true)
  assert.equal(removeServer('remote-docs', paths), false)
  assert.deepEqual(registry.list().map((server) => server.id), ['local-tools'])
})

test('native MCP registry rejects stdio entries without a command', () => {
  assert.throws(() => validateServer({ id: 'bad', name: 'bad', transport: 'stdio' }), /command is required/)
})

test('native MCP registry rejects unknown transports', () => {
  assert.throws(() => validateServer({ id: 'bad', name: 'bad', transport: 'websocket', url: 'https://example.test' }), /bad transport/)
})

test('native MCP registry rejects non-HTTPS remote URLs', () => {
  assert.throws(() => validateServer({ id: 'bad', name: 'bad', transport: 'http', url: 'http://example.test/mcp' }), /must use HTTPS/)
})

test('native MCP registry rejects remote URLs carrying credentials', () => {
  assert.throws(() => validateServer({ id: 'bad', name: 'bad', transport: 'sse', url: 'https://user:secret@example.test/mcp' }), /must not contain credentials/)
})

test('buildSessionServers emits ACP wire shapes and filters by enabled state and agent capabilities', (t) => {
  const paths = fixture(t)
  for (const server of [
    { id: 'local', name: 'local', transport: 'stdio', command: 'node', args: ['server.js'], env: { B: '2', A: '1' } },
    { id: 'http', name: 'docs', transport: 'http', url: 'https://docs.example.test/mcp', headers: { Authorization: 'Bearer ${TOKEN}' } },
    { id: 'sse', name: 'events', transport: 'sse', url: 'https://events.example.test/sse', headers: { Accept: 'text/event-stream' } },
    { id: 'disabled', name: 'off', transport: 'stdio', command: 'node', enabled: false },
  ]) addServer(server, paths)

  assert.deepEqual(buildSessionServers({ ...paths, enabledOnly: true, agentCaps: {} }), [
    {
      name: 'local',
      command: 'node',
      args: ['server.js'],
      env: [{ name: 'B', value: '2' }, { name: 'A', value: '1' }],
    },
  ])
  assert.deepEqual(buildSessionServers({ ...paths, agentCaps: { http: true } }), [
    {
      name: 'local',
      command: 'node',
      args: ['server.js'],
      env: [{ name: 'B', value: '2' }, { name: 'A', value: '1' }],
    },
    {
      type: 'http',
      name: 'docs',
      url: 'https://docs.example.test/mcp',
      headers: [{ name: 'Authorization', value: 'Bearer ${TOKEN}' }],
    },
  ])
  assert.deepEqual(buildSessionServers({ ...paths, agentCaps: { http: true, sse: true } }).at(-1), {
    type: 'sse',
    name: 'events',
    url: 'https://events.example.test/sse',
    headers: [{ name: 'Accept', value: 'text/event-stream' }],
  })
  assert.equal(buildSessionServers({ ...paths, agentCaps: { http: true, sse: true } }).some((entry) => entry.name === 'off'), false)
})

test('registry writes atomically with mode 0600 and leaves no temporary file', (t) => {
  const paths = fixture(t)
  addServer({ id: 'local', name: 'local', transport: 'stdio', command: 'node' }, paths)
  assert.equal(fs.statSync(paths.configPath).mode & 0o777, 0o600)
  assert.deepEqual(fs.readdirSync(path.dirname(paths.configPath)), [path.basename(paths.configPath)])
})

test('corrupt config degrades to an empty list and empty session server array', (t) => {
  const paths = fixture(t)
  fs.mkdirSync(path.dirname(paths.configPath), { recursive: true })
  fs.writeFileSync(paths.configPath, '{ definitely not json')
  assert.doesNotThrow(() => listServers(paths))
  assert.deepEqual(listServers(paths), [])
  assert.deepEqual(buildSessionServers({ ...paths, agentCaps: { http: true, sse: true } }), [])
})

test('default config paths are per-workspace and stay under the injected native base directory', (t) => {
  const paths = fixture(t)
  const first = resolveConfigPath({ baseDir: paths.root, workspace: path.join(paths.root, 'one') })
  const second = resolveConfigPath({ baseDir: paths.root, workspace: path.join(paths.root, 'two') })
  assert.notEqual(first, second)
  assert.equal(path.relative(paths.root, first).startsWith('..'), false)
  assert.equal(path.basename(first).endsWith('.json'), true)
})

test('CLI add, list --json, and build --http --sse --json use the injected config path', (t) => {
  const paths = fixture(t)
  const input = path.join(paths.root, 'server.json')
  fs.writeFileSync(input, JSON.stringify({
    id: 'docs',
    name: 'docs',
    transport: 'http',
    url: 'https://docs.example.test/mcp',
  }))
  const run = (args) => spawnSync(process.execPath, [script, ...args, '--config', paths.configPath], {
    encoding: 'utf8',
    env: process.env,
  })

  const added = run(['add', '--file', input])
  assert.equal(added.status, 0, added.stderr)
  const listed = run(['list', '--json'])
  assert.equal(listed.status, 0, listed.stderr)
  assert.deepEqual(JSON.parse(listed.stdout).map((server) => server.id), ['docs'])
  const built = run(['build', '--http', '--sse', '--json'])
  assert.equal(built.status, 0, built.stderr)
  assert.deepEqual(JSON.parse(built.stdout), [{
    type: 'http',
    name: 'docs',
    url: 'https://docs.example.test/mcp',
    headers: [],
  }])
})
