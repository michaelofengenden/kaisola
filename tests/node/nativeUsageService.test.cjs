'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  accountEnvironmentOverrides,
  fixture,
  normalizeClaude,
  normalizeCodex,
  normalizedWindow,
  parseArguments,
} = require('../../scripts/native-usage-service.cjs')

test('native usage bridge normalizes Codex account windows', () => {
  const value = normalizeCodex({
    ok: true,
    email: 'person@example.com',
    plan: 'plus',
    primary: { usedPercent: 41, resetsAt: 1_800_000_000 },
    secondary: { usedPercent: 12 },
    updatedAt: 123,
  }, 999)
  assert.equal(value.provider, 'codex')
  assert.equal(value.ok, true)
  assert.equal(value.account, 'person@example.com')
  assert.deepEqual(value.windows.map((window) => window.label), ['5 hour', 'Weekly'])
  assert.equal(value.windows[0].usedPercent, 41)
})

test('native usage bridge normalizes Claude Agent SDK windows', () => {
  const value = normalizeClaude({
    ok: true,
    subscriptionType: 'max',
    limits: {
      fiveHour: { usedPercent: 28, resetsAt: 1_800_000_000 },
      sevenDay: { usedPercent: 9 },
      modelScoped: [{ label: 'Opus', usedPercent: 4 }],
    },
  }, 999)
  assert.equal(value.provider, 'claude')
  assert.equal(value.plan, 'max')
  assert.equal(value.experimental, true)
  assert.deepEqual(value.windows.map((window) => window.label), ['5 hour', '7 day', 'Opus'])
})

test('native usage bridge preserves actionable authentication failures', () => {
  const expired = normalizeCodex({
    ok: false,
    authRequired: true,
    message: 'Your Codex sign-in expired. Sign in again to refresh usage limits.',
  }, 999)
  assert.equal(expired.authRequired, true)
  assert.match(expired.message, /expired/u)

  const signedOut = normalizeClaude({
    ok: true,
    rateLimitsAvailable: false,
    limits: {},
  }, 999)
  assert.equal(signedOut.ok, false)
  assert.equal(signedOut.authRequired, true)
  assert.match(signedOut.message, /Sign in/u)

  assert.equal(
    normalizeClaude({ ok: false, message: 'Authentication required.' }, 999).authRequired,
    true,
  )

  const ordinaryFailure = normalizeCodex({ ok: false, message: 'Helper timed out.' }, 999)
  assert.equal(ordinaryFailure.authRequired, undefined)
})

test('native usage window rejects malformed percentage and fixture is deterministic in shape', () => {
  assert.equal(normalizedWindow('bad', { usedPercent: 101 }), null)
  const value = fixture(1_700_000_000_000)
  assert.deepEqual(value.providers.map((provider) => provider.provider), ['claude', 'codex'])
  assert.ok(value.providers.every((provider) => provider.windows.length === 2))
})

test('native usage bridge can scope one process to one provider without changing default shape', () => {
  assert.deepEqual(parseArguments([]), {})
  assert.deepEqual(parseArguments(['--provider', 'claude']), { provider: 'claude' })
  assert.deepEqual(fixture(1_700_000_000_000, 'claude').providers.map((value) => value.provider), ['claude'])
  assert.deepEqual(fixture(1_700_000_000_000, 'codex').providers.map((value) => value.provider), ['codex'])
  assert.throws(() => parseArguments(['--provider', 'unknown']), /Usage:/)
})

test('a lone Codex weekly window is not labelled "5 hour"', () => {
  // Codex now reports a weekly limit only, and it arrives in the `primary`
  // slot. Labelling by position drew "5 hour ... resets in 4d" — a five-hour
  // window resetting in four days.
  const now = Date.UTC(2026, 7, 3, 0, 0, 0)
  const fourDaysOut = now / 1000 + 4 * 86_400
  const value = normalizeCodex(
    { ok: true, plan: 'pro', primary: { usedPercent: 36, resetsAt: fourDaysOut }, updatedAt: now },
    now
  )
  assert.equal(value.windows.length, 1, 'one reported window stays one window')
  assert.equal(value.windows[0].label, 'Weekly')
  assert.equal(value.windows[0].usedPercent, 36)
})

test('a Codex window resetting within the day is still the 5-hour one', () => {
  const now = Date.UTC(2026, 7, 3, 0, 0, 0)
  const threeHoursOut = now / 1000 + 3 * 3_600
  const value = normalizeCodex(
    { ok: true, primary: { usedPercent: 10, resetsAt: threeHoursOut }, updatedAt: now },
    now
  )
  assert.equal(value.windows[0].label, '5 hour')
})

test('both Codex windows keep their own names when both are reported', () => {
  const now = Date.UTC(2026, 7, 3, 0, 0, 0)
  const value = normalizeCodex(
    {
      ok: true,
      primary: { usedPercent: 10, resetsAt: now / 1000 + 2 * 3_600 },
      secondary: { usedPercent: 55, resetsAt: now / 1000 + 5 * 86_400 },
      updatedAt: now,
    },
    now
  )
  assert.deepEqual(value.windows.map((w) => w.label), ['5 hour', 'Weekly'])
})

test('the account pointer survives as an explicit argument', () => {
  // Six subscriptions rendered as clones of one because the per-account
  // CLAUDE_CONFIG_DIR/CODEX_HOME was stripped by the compatibility allowlist
  // before either provider reader saw it. Arguments cannot be stripped.
  assert.deepEqual(
    parseArguments(['--provider', 'claude', '--claude-config-dir', '/tmp/claude-work']),
    { provider: 'claude', claudeConfigDir: '/tmp/claude-work' }
  )
  assert.deepEqual(
    parseArguments(['--codex-home', '/tmp/codex-work', '--provider', 'codex']),
    { provider: 'codex', codexHome: '/tmp/codex-work' }
  )
  assert.throws(() => parseArguments(['--claude-config-dir']), /Usage:/)
  assert.throws(() => parseArguments(['--claude-config-dir', '--provider']), /Usage:/)
  assert.throws(() => parseArguments(['--claude-config-dir', ' ']), /Usage:/)
  assert.throws(() => parseArguments(['--provider', 'claude', '--provider', 'claude']), /Usage:/)
  assert.throws(() => parseArguments(['--frobnicate', 'x']), /Usage:/)
})

test('explicit account arguments outrank the spawn environment, which outranks nothing', () => {
  assert.deepEqual(
    accountEnvironmentOverrides(
      { claudeConfigDir: '/arg/claude', codexHome: '/arg/codex' },
      { CLAUDE_CONFIG_DIR: '/env/claude', CODEX_HOME: '/env/codex' }
    ),
    { CLAUDE_CONFIG_DIR: '/arg/claude', CODEX_HOME: '/arg/codex' }
  )
  assert.deepEqual(
    accountEnvironmentOverrides({}, { CLAUDE_CONFIG_DIR: '/env/claude' }),
    { CLAUDE_CONFIG_DIR: '/env/claude' }
  )
  assert.deepEqual(accountEnvironmentOverrides({}, {}), {})
  assert.deepEqual(
    accountEnvironmentOverrides({ claudeConfigDir: '  ' }, { CLAUDE_CONFIG_DIR: '  ' }),
    {}
  )
})

test('agentEnv keeps an account pointer that arrives through extra', () => {
  // The allowlist rebuild is the exact mechanism that deleted the pointer;
  // the extra argument is its documented carrier. Pin that it works, so a
  // future allowlist edit cannot silently orphan per-account probes again.
  const { agentEnv } = require('../../runtime/node-broker/ipc/shellEnv.cjs')
  const env = agentEnv(
    { CLAUDE_CONFIG_DIR: '/tmp/claude-a', CODEX_HOME: '/tmp/codex-b' },
    { environment: { HOME: '/Users/someone', CLAUDE_CONFIG_DIR: '/inherited/ignored' }, loginShellPath: null }
  )
  assert.equal(env.CLAUDE_CONFIG_DIR, '/tmp/claude-a')
  assert.equal(env.CODEX_HOME, '/tmp/codex-b')
  const bare = agentEnv(undefined, {
    environment: { HOME: '/Users/someone', CLAUDE_CONFIG_DIR: '/inherited/ignored' },
    loginShellPath: null,
  })
  assert.equal(bare.CLAUDE_CONFIG_DIR, undefined, 'ambient pointers stay filtered without extra')
})

test('codexUsage merges the explicit home over a caller-supplied environment', async () => {
  // `options.env || agentEnv(extraEnv)` chose one or the other, so the only
  // carrier of CODEX_HOME was discarded whenever a caller (the native usage
  // service, always) supplied its own environment.
  const { codexUsage } = require('../../runtime/node-broker/ipc/usageHandler.cjs')
  const { EventEmitter } = require('node:events')
  const { PassThrough } = require('node:stream')
  let captured
  const spawnImpl = (command, args, options) => {
    captured = options.env
    const proc = new EventEmitter()
    proc.stdin = new PassThrough()
    proc.stdout = new PassThrough()
    proc.stderr = new PassThrough()
    proc.kill = () => proc.emit('exit', 0)
    // The capture happens at spawn; ending the probe immediately through the
    // error path keeps the test synchronous-fast without faking JSON-RPC.
    setImmediate(() => proc.emit('error', new Error('fake app-server stops here')))
    return proc
  }
  await codexUsage('/tmp/codex-account-b', {
    env: { PATH: '/usr/bin', HOME: '/Users/someone' },
    spawnImpl,
    timeoutMs: 10,
  })
  assert.equal(captured.CODEX_HOME, '/tmp/codex-account-b')
  assert.equal(captured.HOME, '/Users/someone', 'the caller environment is kept, not replaced')
})
