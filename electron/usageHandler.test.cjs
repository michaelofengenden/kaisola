const test = require('node:test')
const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const { PassThrough } = require('node:stream')
const fs = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')

const { codexUsage, codexRateLimitSnapshot, claudeUsage, claudeSessionUsage } = require('./ipc/usageHandler.cjs')

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
  assert.equal(capture.command, 'codex')
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
