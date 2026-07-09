const test = require('node:test')
const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const { PassThrough } = require('node:stream')
const { spawn } = require('node:child_process')
const fs = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')

const {
  codexUsage,
  codexSubscriptionUsage,
  codexRateLimitSnapshot,
  claudeUsage,
  claudeSessionUsage,
  claudeSubscriptionUsage,
  readClaudeSdkUsage,
  readClaudeStatusLine,
  normalizeClaudeSdkUsage,
  _clearClaudeUsageCacheForTests,
} = require('./ipc/usageHandler.cjs')
const { _buildSettingsForTests, _hasCustomStatusLineForTests } = require('./ipc/claudeHooksHandler.cjs')

function mockCodexSpawn(responses, capture = {}) {
  return (command, args, options) => {
    capture.command = command
    capture.args = args
    capture.env = options.env
    const proc = new EventEmitter()
    proc.stdout = new PassThrough()
    proc.stderr = new PassThrough()
    proc.stdin = new EventEmitter()
    proc.stdin.writable = true
    proc.stdin.write = (chunk) => {
      const request = JSON.parse(String(chunk))
      if (request.id && responses[request.id]) {
        queueMicrotask(() => proc.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: request.id, ...responses[request.id] })}\n`))
      }
      return true
    }
    proc.kill = () => { proc.stdin.writable = false }
    return proc
  }
}

test('Codex usage uses app-server windows and the Codex multi-bucket', async () => {
  const capture = {}
  const result = await codexUsage('~/alternate-codex', {
    timeoutMs: 500,
    env: { PATH: '/probe', CODEX_HOME: '/expanded/alternate-codex' },
    spawnImpl: mockCodexSpawn({
      1: { result: {} },
      2: { result: { account: { type: 'chatgpt', email: 'person@example.com', planType: 'pro' } } },
      3: { result: {
        rateLimits: { primary: { usedPercent: 99 } },
        rateLimitsByLimitId: {
          other: { limitId: 'other', primary: { usedPercent: 80 } },
          codex: { limitId: 'codex', primary: { usedPercent: 12 }, secondary: { usedPercent: 34 } },
        },
      } },
    }, capture),
  })
  assert.match(capture.command, /codex(?:\.exe)?$/)
  assert.deepEqual(capture.args.slice(-1), ['app-server'])
  assert.equal(result.ok, true)
  assert.equal(result.primary.usedPercent, 12)
  assert.equal(result.secondary.usedPercent, 34)
  assert.equal(result.plan, 'pro')
})

test('Codex snapshot falls back to the legacy response', () => {
  const legacy = { planType: 'plus', primary: { usedPercent: 7 } }
  assert.equal(codexRateLimitSnapshot({ rateLimits: legacy }), legacy)
})

test('Codex subscription reads share in-flight work and cache rapid panel opens', async () => {
  _clearClaudeUsageCacheForTests()
  let calls = 0
  let release
  const reader = () => {
    calls++
    return new Promise((resolve) => { release = () => resolve({ ok: true, primary: { usedPercent: 11 } }) })
  }
  const first = codexSubscriptionUsage(undefined, { reader, now: 1000 })
  const second = codexSubscriptionUsage(undefined, { reader, now: 1001 })
  assert.equal(calls, 1)
  release()
  assert.deepEqual(await first, await second)
  const cached = await codexSubscriptionUsage(undefined, { reader, now: 2000 })
  assert.equal(cached.primary.usedPercent, 11)
  assert.equal(calls, 1)
})

test('Claude usage streams nested transcripts and deduplicates mirrored requests', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'kaisola-usage-test-'))
  t.after(() => fs.rm(root, { recursive: true, force: true }))
  const project = path.join(root, 'projects', '-workspace')
  const nested = path.join(project, 'session-id', 'subagents')
  await fs.mkdir(nested, { recursive: true })
  const now = Date.parse('2026-07-09T18:00:00.000Z')
  const recent = {
    timestamp: '2026-07-09T17:00:00.000Z',
    requestId: 'req-1',
    message: { id: 'msg-1', model: 'claude-test', usage: { input_tokens: 10, output_tokens: 3, cache_read_input_tokens: 20, cache_creation_input_tokens: 4 } },
  }
  const weekOnly = {
    timestamp: '2026-07-06T17:00:00.000Z',
    requestId: 'req-2',
    message: { id: 'msg-2', model: 'claude-test', usage: { input_tokens: 5, output_tokens: 2 } },
  }
  await fs.writeFile(path.join(project, 'session-id.jsonl'), `${JSON.stringify(recent)}\n${JSON.stringify(weekOnly)}\n`)
  // A subagent mirror of req-1 must not double count.
  await fs.writeFile(path.join(nested, 'agent.jsonl'), `${JSON.stringify(recent)}\n`)
  const usage = await claudeUsage(root, now)
  assert.equal(usage.ok, true)
  assert.equal(usage.fiveHour.input, 10)
  assert.equal(usage.fiveHour.output, 3)
  assert.equal(usage.week.input, 15)
  assert.equal(usage.week.cacheRead, 20)
  assert.equal(usage.lastActivity, Date.parse(recent.timestamp))

  const session = await claudeSessionUsage(root, 'session-id')
  assert.equal(session.ok, true)
  assert.equal(session.models[0].model, 'claude-test')
  assert.equal(session.models[0].input, 15)
})

const rawClaudeLimits = (used = 5) => ({
  session: {
    total_cost_usd: 0,
    total_api_duration_ms: 0,
    total_duration_ms: 0,
    total_lines_added: 0,
    total_lines_removed: 0,
    model_usage: {},
  },
  subscription_type: 'max',
  rate_limits_available: true,
  rate_limits: {
    five_hour: { utilization: used, resets_at: '2026-07-09T23:00:00.000Z' },
    seven_day: { utilization: 12.5, resets_at: '2026-07-15T23:00:00.000Z' },
    model_scoped: [{ display_name: 'Fable', utilization: 2, resets_at: '2026-07-15T23:00:00.000Z' }],
    extra_usage: { is_enabled: true, monthly_limit: 100, used_credits: 12.25, utilization: 12.25, currency: 'USD' },
  },
  behaviors: null,
})

function mockClaudeSdk(raw, capture = {}, failure) {
  return {
    query(params) {
      capture.params = params
      capture.calls = (capture.calls || 0) + 1
      return {
        initializationResult: async () => ({ account: { tokenSource: 'oauth' } }),
        usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET: async () => {
          if (failure) throw new Error(failure)
          return raw
        },
        close() { capture.closed = true },
      }
    },
  }
}

test('Claude SDK usage normalizes plan, Fable and extra-usage fields without a prompt', async () => {
  const capture = {}
  const usage = await readClaudeSdkUsage('/tmp/claude-plan-test', {
    sdk: mockClaudeSdk(rawClaudeLimits(), capture),
    timeoutMs: 500,
    now: Date.parse('2026-07-09T21:00:00.000Z'),
    env: { PATH: '/probe', ANTHROPIC_API_KEY: 'must-not-win', CLAUDE_CODE_OAUTH_TOKEN: 'wrong-account', ANTHROPIC_BASE_URL: 'https://wrong-provider.invalid' },
  })
  assert.equal(usage.ok, true)
  assert.equal(usage.subscriptionType, 'max')
  assert.equal(usage.limits.fiveHour.usedPercent, 5)
  assert.equal(usage.limits.modelScoped[0].label, 'Fable')
  assert.equal(usage.limits.extraUsage.usedCredits, 12.25)
  assert.deepEqual(capture.params.options.tools, [])
  assert.deepEqual(capture.params.options.mcpServers, {})
  assert.deepEqual(capture.params.options.settingSources, [])
  assert.deepEqual(capture.params.options.plugins, [])
  assert.equal(capture.params.options.persistSession, false)
  assert.equal(capture.params.options.env.CLAUDE_CONFIG_DIR, '/tmp/claude-plan-test')
  assert.equal(capture.params.options.env.ANTHROPIC_API_KEY, undefined)
  assert.equal(capture.params.options.env.CLAUDE_CODE_OAUTH_TOKEN, undefined)
  assert.equal(capture.params.options.env.ANTHROPIC_BASE_URL, undefined)
  assert.equal(capture.closed, true)
})

test('Claude SDK schema rejects malformed experimental responses', () => {
  assert.throws(() => normalizeClaudeSdkUsage({ rate_limits_available: 'yes' }), /rate_limits_available/)
  assert.throws(() => normalizeClaudeSdkUsage({ rate_limits_available: true, subscription_type: 123 }), /subscription type/)
  const unavailable = normalizeClaudeSdkUsage({ rate_limits_available: true, subscription_type: 'max', rate_limits: { five_hour: { utilization: null, resets_at: null } } })
  assert.equal(unavailable.limits.fiveHour, null)
})

test('Claude status-line fallback selects the matching CLAUDE_CONFIG_DIR', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'kaisola-status-test-'))
  t.after(() => fs.rm(root, { recursive: true, force: true }))
  const base = path.join(root, 'account')
  const other = path.join(root, 'other')
  const cache = path.join(root, 'status.jsonl')
  const status = (transcript, five) => JSON.stringify({
    transcript_path: transcript,
    rate_limits: {
      five_hour: { used_percentage: five, resets_at: 1783641600 },
      seven_day: { used_percentage: 34, resets_at: 1784073600 },
    },
  })
  await fs.writeFile(cache, `1783630000\t${status(path.join(base, 'projects', '-repo', 'a.jsonl'), 23)}\n1783630100\t${status(path.join(other, 'projects', '-repo', 'b.jsonl'), 99)}\n`)
  const usage = await readClaudeStatusLine(base, { statusCachePath: cache })
  assert.equal(usage.source, 'status-line')
  assert.equal(usage.limits.fiveHour.usedPercent, 23)
  assert.equal(usage.updatedAt, 1783630000 * 1000)
})

test('Claude hooks status line captures official JSON without exposing it on stdout', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'kaisola-status-command-test-'))
  t.after(() => fs.rm(root, { recursive: true, force: true }))
  const cache = path.join(root, 'status.jsonl')
  const command = _buildSettingsForTests(path.join(root, 'events.jsonl'), cache).statusLine.command
  const input = JSON.stringify({ transcript_path: '/tmp/account/projects/-repo/id.jsonl', rate_limits: { five_hour: { used_percentage: 10 } } })
  const output = await new Promise((resolve, reject) => {
    const proc = spawn('/bin/sh', ['-c', command], { stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    proc.stdout.on('data', (chunk) => { stdout += chunk })
    proc.stderr.on('data', (chunk) => { stderr += chunk })
    proc.on('error', reject)
    proc.on('exit', (code) => code === 0 ? resolve({ stdout, stderr }) : reject(new Error(stderr || `exit ${code}`)))
    proc.stdin.end(input)
  })
  assert.equal(output.stdout, 'Claude · 5h 10%\n')
  assert.equal(output.stderr, '')
  const captured = await fs.readFile(cache, 'utf8')
  const [epoch, json] = captured.trim().split('\t')
  assert.ok(Number(epoch) > 0)
  assert.deepEqual(JSON.parse(json), JSON.parse(input))
})

test('Claude usage fallback preserves an existing account or project status line', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'kaisola-status-preserve-test-'))
  t.after(() => fs.rm(root, { recursive: true, force: true }))
  const configDir = path.join(root, 'account')
  const workspace = path.join(root, 'workspace')
  await fs.mkdir(configDir, { recursive: true })
  await fs.mkdir(path.join(workspace, '.claude'), { recursive: true })
  await fs.writeFile(path.join(configDir, 'settings.json'), JSON.stringify({ statusLine: { type: 'command', command: 'my-status' } }))
  assert.equal(_hasCustomStatusLineForTests(configDir, workspace), true)
  assert.equal(_buildSettingsForTests('/tmp/events', '/tmp/status', false).statusLine, undefined)

  await fs.writeFile(path.join(configDir, 'settings.json'), '{}')
  await fs.writeFile(path.join(workspace, '.claude', 'settings.local.json'), JSON.stringify({ statusLine: { type: 'command', command: 'project-status' } }))
  assert.equal(_hasCustomStatusLineForTests(configDir, workspace), true)
})

test('Claude subscription reader caches and retains last-known-good limits', async (t) => {
  _clearClaudeUsageCacheForTests()
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'kaisola-subscription-test-'))
  t.after(() => fs.rm(root, { recursive: true, force: true }))
  const capture = {}
  const first = await claudeSubscriptionUsage(root, {
    sdk: mockClaudeSdk(rawClaudeLimits(7), capture),
    now: 1_000_000,
    timeoutMs: 500,
    statusCachePath: path.join(root, 'absent'),
  })
  const cached = await claudeSubscriptionUsage(root, {
    sdk: mockClaudeSdk(rawClaudeLimits(99), capture),
    now: 1_001_000,
    timeoutMs: 500,
  })
  assert.equal(first.limits.fiveHour.usedPercent, 7)
  assert.equal(cached.limits.fiveHour.usedPercent, 7)
  assert.equal(capture.calls, 1)

  const failed = await claudeSubscriptionUsage(root, {
    sdk: mockClaudeSdk(null, capture, 'offline'),
    force: true,
    now: 1_002_000,
    timeoutMs: 500,
    statusCachePath: path.join(root, 'absent'),
  })
  assert.equal(failed.limits.fiveHour.usedPercent, 7)
  assert.equal(failed.stale, true)
  assert.match(failed.refreshError, /offline/)
})
