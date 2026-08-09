'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
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
