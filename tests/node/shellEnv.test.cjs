'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  agentEnv,
  COMPATIBILITY_ENVIRONMENT_KEYS,
  discoverLoginShellPath,
  resolveLoginShell,
} = require('../../runtime/node-broker/ipc/shellEnv.cjs')

function shellFixture(t, name = 'valid-shell', mode = 0o755) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-shell-env-'))
  const file = path.join(dir, name)
  fs.writeFileSync(file, '#!/bin/sh\nexit 0\n', { mode })
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return file
}

test('a valid absolute executable shell is invoked with fixed separate arguments', (t) => {
  const shell = shellFixture(t)
  const calls = []

  const result = discoverLoginShellPath({
    shell,
    fallbackShells: [],
    run(file, args, options) {
      calls.push({ file, args, options })
      return 'PZPATH:/custom/bin:/usr/bin\n'
    },
  })

  assert.equal(result, '/custom/bin:/usr/bin')
  assert.deepEqual(calls, [{
    file: fs.realpathSync(shell),
    args: ['-lic', 'printf "PZPATH:%s" "$PATH"'],
    options: {
      timeout: 5000,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    },
  }])
})

test('hostile and invalid SHELL values are never selected as executables', async (t) => {
  const validFallback = shellFixture(t)
  const nonExecutable = shellFixture(t, 'non-executable', 0o644)
  const missing = path.join(path.dirname(validFallback), 'missing-shell')
  const hostile = [
    `${validFallback} --extra-argument`,
    `${validFallback};touch-owned`,
    `${validFallback}$(touch-owned)`,
    `${validFallback}\n/bin/sh`,
    'relative/shell',
    nonExecutable,
    missing,
  ]

  for (const value of hostile) {
    await t.test(JSON.stringify(value), () => {
      assert.equal(resolveLoginShell(value, { fallbackShells: [] }), null)

      const calls = []
      const result = discoverLoginShellPath({
        shell: value,
        fallbackShells: [validFallback],
        run(file, args) {
          calls.push({ file, args })
          return 'PZPATH:/safe/fallback\n'
        },
      })

      assert.equal(result, '/safe/fallback')
      assert.deepEqual(calls, [{
        file: fs.realpathSync(validFallback),
        args: ['-lic', 'printf "PZPATH:%s" "$PATH"'],
      }])
    })
  }
})

test('missing output marker and execution failures retain the deterministic null fallback', (t) => {
  const shell = shellFixture(t)

  assert.equal(discoverLoginShellPath({
    shell,
    fallbackShells: [],
    run: () => 'unrelated output',
  }), null)

  assert.equal(discoverLoginShellPath({
    shell,
    fallbackShells: [],
    run: () => { throw new Error('fixture failure') },
  }), null)
})

test('agent environments inherit only the exact compatibility allowlist', () => {
  const inherited = {
    HOME: '/Users/fixture',
    USER: 'fixture',
    LOGNAME: 'fixture',
    SHELL: '/bin/zsh',
    TMPDIR: '/private/tmp/fixture',
    LANG: 'en_US.UTF-8',
    LC_ALL: 'C',
    LC_CTYPE: 'UTF-8',
    SSH_AUTH_SOCK: '/private/tmp/fixture-agent.sock',
    DISPLAY: ':0',
    XAUTHORITY: '/Users/fixture/.Xauthority',
    XDG_CONFIG_HOME: '/Users/fixture/.config',
    __CF_USER_TEXT_ENCODING: '0x1F5:0x0:0x0',
    PATH: '/launch/bin:/usr/bin',
  }

  const env = agentEnv(undefined, {
    environment: inherited,
    home: '/Users/fixture',
    loginShellPath: '/login/bin:/usr/bin',
  })

  for (const key of COMPATIBILITY_ENVIRONMENT_KEYS) {
    if (Object.hasOwn(inherited, key)) assert.equal(env[key], inherited[key], key)
  }
  assert.equal(env.PATH, [
    '/login/bin',
    '/usr/bin',
    '/launch/bin',
    '/opt/homebrew/bin',
    '/opt/homebrew/sbin',
    '/usr/local/bin',
    '/Library/TeX/texbin',
    '/Users/fixture/.local/bin',
    '/Users/fixture/.npm-global/bin',
    '/Users/fixture/.bun/bin',
    '/bin',
    '/usr/sbin',
    '/sbin',
  ].join(':'))
})

test('secret-shaped launch variables never enter an agent or PTY environment', () => {
  const marker = 'kaisola-secret-marker-issue-455'
  const secretKeys = [
    'ANTHROPIC_API_KEY',
    'AWS_SECRET_ACCESS_KEY',
    'CI_JOB_TOKEN',
    'CODEX_THREAD_ID',
    'ELECTRON_RUN_AS_NODE',
    'GITHUB_TOKEN',
    'GOOGLE_APPLICATION_CREDENTIALS',
    'KAISOLA_SESSION_BROKER',
    'LC_SECRET_TOKEN',
    'OPENAI_API_KEY',
    'SENTRY_AUTH_TOKEN',
    'SIGNING_PASSWORD',
    'SSH_PRIVATE_KEY',
    'XDG_SECRET_TOKEN',
  ]
  const environment = {
    HOME: '/Users/fixture',
    PATH: '/usr/bin:/bin',
    ...Object.fromEntries(secretKeys.map((key) => [key, `${marker}-${key}`])),
  }

  const env = agentEnv(undefined, {
    environment,
    home: '/Users/fixture',
    loginShellPath: null,
  })

  for (const key of secretKeys) assert.equal(Object.hasOwn(env, key), false, key)
  assert.doesNotMatch(JSON.stringify(env), new RegExp(marker))
})

test('explicit caller-approved overrides are preserved without reopening launch inheritance', () => {
  const env = agentEnv({
    CODEX_HOME: '/Users/fixture/.codex-work',
    CUSTOM_AGENT_ENDPOINT: 'https://agents.example.test',
  }, {
    environment: {
      HOME: '/Users/fixture',
      PATH: '/usr/bin:/bin',
      CUSTOM_AGENT_ENDPOINT: 'https://unapproved.example.test',
      OPENAI_API_KEY: 'launch-secret',
    },
    home: '/Users/fixture',
    loginShellPath: null,
  })

  assert.equal(env.CODEX_HOME, '/Users/fixture/.codex-work')
  assert.equal(env.CUSTOM_AGENT_ENDPOINT, 'https://agents.example.test')
  assert.equal(Object.hasOwn(env, 'OPENAI_API_KEY'), false)
})
