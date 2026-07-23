'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const {
  ADAPTER_PACKAGES,
  createVersionReport,
} = require('../scripts/agent-adapter-versions.cjs')
const {
  runOnce,
  startWatch,
} = require('../scripts/agent-adapter-update.cjs')

const versions = {
  '@agentclientprotocol/claude-agent-acp': '0.60.0',
  '@agentclientprotocol/codex-acp': '1.2.0',
  '@zed-industries/claude-code-acp': '0.16.2',
  '@zed-industries/codex-acp': '0.16.0',
  '@modelcontextprotocol/server-sequential-thinking': '2026.1.2',
}

function fakeNpmRunner(overrides = {}) {
  return (packageName) => {
    const value = Object.prototype.hasOwnProperty.call(overrides, packageName) ? overrides[packageName] : versions[packageName]
    if (value instanceof Error) throw value
    if (!value) return { ok: false, code: 1, stderr: 'offline' }
    return {
      ok: true,
      data: {
        version: value,
        'time.modified': packageName.startsWith('@agentclientprotocol/') ? '2026-07-20T00:00:00.000Z' : '2025-01-01T00:00:00.000Z',
      },
    }
  }
}

function report(overrides = {}) {
  return createVersionReport({
    packageJson: {
      dependencies: {
        '@agentclientprotocol/claude-agent-acp': '0.58.1',
        '@agentclientprotocol/codex-acp': '1.1.2',
      },
    },
    packageJsonPath: path.join(os.tmpdir(), 'agent-versions-fixture', 'package.json'),
    installedVersions: {
      '@agentclientprotocol/claude-agent-acp': '0.58.1',
      '@agentclientprotocol/codex-acp': '1.1.2',
    },
    npmRunner: fakeNpmRunner(),
    now: () => '2026-07-22T12:00:00.000Z',
    ...overrides,
  })
}

test('version report has deterministic package and recommendation shapes with an injected npm runner', () => {
  const result = report()
  assert.equal(result.schemaVersion, 1)
  assert.equal(result.checkedAt, '2026-07-22T12:00:00.000Z')
  assert.equal(result.ok, true)
  assert.deepEqual(result.packages.map((entry) => entry.packageName), ADAPTER_PACKAGES.map((entry) => entry.packageName))
  assert.deepEqual(Object.keys(result.recommendations), ['claude', 'codex'])
  assert.equal(result.recommendations.claude.packageName, '@agentclientprotocol/claude-agent-acp')
  assert.equal(result.recommendations.codex.packageName, '@agentclientprotocol/codex-acp')
  assert.equal(result.recommendations.claude.currentPublishedMoreRecently, true)
})

test('version report detects installed adapter versions older than npm latest', () => {
  const result = report()
  const claude = result.packages.find((entry) => entry.packageName === '@agentclientprotocol/claude-agent-acp')
  const codex = result.packages.find((entry) => entry.packageName === '@agentclientprotocol/codex-acp')
  assert.equal(claude.installedVersion, '0.58.1')
  assert.equal(claude.latestVersion, '0.60.0')
  assert.equal(claude.updateAvailable, true)
  assert.equal(codex.updateAvailable, true)
})

test('version report marks current installed versions as having no update', () => {
  const result = report({
    installedVersions: {
      '@agentclientprotocol/claude-agent-acp': '0.60.0',
      '@agentclientprotocol/codex-acp': '1.2.0',
    },
  })
  assert.equal(result.packages.find((entry) => entry.packageName === '@agentclientprotocol/claude-agent-acp').updateAvailable, false)
  assert.equal(result.packages.find((entry) => entry.packageName === '@agentclientprotocol/codex-acp').updateAvailable, false)
})

test('version report returns structured npm failures without throwing when offline', () => {
  const result = report({ npmRunner: () => ({ ok: false, code: 1, stderr: 'network unavailable' }) })
  assert.equal(result.ok, false)
  assert.equal(result.packages.length, 4)
  for (const entry of result.packages) {
    assert.equal(entry.status, 'npm-error')
    assert.equal(entry.latestVersion, null)
    assert.equal(entry.updateAvailable, null)
    assert.match(entry.error, /network unavailable/)
  }
})

test('update once rewrites only declared adapter and MCP package specifiers in a temporary package.json', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-agent-update-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const packageJsonPath = path.join(root, 'package.json')
  fs.writeFileSync(packageJsonPath, `${JSON.stringify({
    name: 'fixture',
    dependencies: {
      '@agentclientprotocol/claude-agent-acp': '0.58.1',
      '@agentclientprotocol/codex-acp': '^1.1.2',
      '@modelcontextprotocol/server-sequential-thinking': '2025.12.18',
      react: '^18.3.1',
    },
  }, null, 2)}\n`)

  const first = runOnce({ packageJsonPath, npmRunner: fakeNpmRunner(), installedVersions: {} })
  assert.equal(first.written, true)
  assert.equal(first.installCommand, 'npm install')
  assert.deepEqual(first.updates.map(({ packageName, from, to }) => ({ packageName, from, to })), [
    { packageName: '@agentclientprotocol/claude-agent-acp', from: '0.58.1', to: '0.60.0' },
    { packageName: '@agentclientprotocol/codex-acp', from: '^1.1.2', to: '^1.2.0' },
    { packageName: '@modelcontextprotocol/server-sequential-thinking', from: '2025.12.18', to: '2026.1.2' },
  ])
  const updated = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'))
  assert.equal(updated.dependencies.react, '^18.3.1')

  const second = runOnce({ packageJsonPath, npmRunner: fakeNpmRunner(), installedVersions: {} })
  assert.equal(second.written, false)
  assert.deepEqual(second.updates, [])
  assert.equal(second.installCommand, null)
})

test('watch runs one guarded tick with an injected clock and npm runner, with no real timers', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-agent-watch-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const packageJsonPath = path.join(root, 'package.json')
  fs.writeFileSync(packageJsonPath, `${JSON.stringify({
    name: 'watch-fixture',
    dependencies: {
      '@agentclientprotocol/claude-agent-acp': '0.60.0',
      '@agentclientprotocol/codex-acp': '1.2.0',
    },
  }, null, 2)}\n`)
  const scheduled = []
  const cleared = []
  const logs = []
  let npmCalls = 0
  const clock = {
    setInterval(callback, milliseconds) {
      scheduled.push({ callback, milliseconds })
      return 'fixture-timer'
    },
    clearInterval(timer) { cleared.push(timer) },
  }
  const watcher = startWatch({
    immediate: false,
    intervalSeconds: 7,
    clock,
    now: () => '2026-07-22T12:00:00.000Z',
    logger: { log: (line) => logs.push(line), error: (line) => logs.push(line) },
    packageJsonPath,
    installedVersions: {
      '@agentclientprotocol/claude-agent-acp': '0.60.0',
      '@agentclientprotocol/codex-acp': '1.2.0',
    },
    npmRunner: (packageName) => {
      npmCalls += 1
      return fakeNpmRunner()(packageName)
    },
  })
  assert.equal(scheduled.length, 1)
  assert.equal(scheduled[0].milliseconds, 7_000)
  assert.equal(npmCalls, 0)
  assert.equal(watcher.tick().ok, true)
  assert.equal(npmCalls, 4)
  assert.match(logs[0], /check 1: ok, 0 update/)
  watcher.stop()
  assert.deepEqual(cleared, ['fixture-timer'])
  assert.deepEqual(watcher.tick(), { ok: false, skipped: true, reason: 'stopped' })
})
