'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')

const {
  PASS_LINES,
  classifyResult,
  parseArguments,
} = require('../../scripts/native-catalog-smoke.cjs')

test('catalog smoke arguments require an explicit app and bounded flags', () => {
  assert.deepEqual(
    parseArguments(['--app', '/tmp/Kaisola.app', '--allow-auth-required']),
    { app: '/tmp/Kaisola.app', allowAuthRequired: true },
  )
  assert.throws(() => parseArguments(['--token', 'secret']), /unknown argument/)
})

test('catalog smoke accepts only the exact ordered lifecycle', () => {
  assert.deepEqual(classifyResult({
    code: 0,
    signal: null,
    stdout: Buffer.from(`${PASS_LINES.join('\n')}\n`),
    stderr: Buffer.alloc(0),
  }), { status: 'PASS', lifecycle: 'publish-read-remove-absent' })

  assert.throws(() => classifyResult({
    code: 0,
    signal: null,
    stdout: Buffer.from(`${PASS_LINES.slice().reverse().join('\n')}\n`),
    stderr: Buffer.alloc(0),
  }), /catalog smoke failed/)
  assert.throws(() => classifyResult({
    code: 0,
    signal: null,
    stdout: Buffer.from(`${PASS_LINES.join('\n')}\nunexpected-token-shaped-output\n`),
    stderr: Buffer.alloc(0),
  }), /catalog smoke failed/)
})

test('auth-required is explicit opt-in and stderr always fails closed', () => {
  const authRequired = Buffer.from('KAISOLA_NATIVE_CATALOG_SMOKE=AUTH_REQUIRED\n')
  assert.throws(() => classifyResult({
    code: 1,
    signal: null,
    stdout: authRequired,
    stderr: Buffer.alloc(0),
  }), /AUTH_REQUIRED/)
  assert.deepEqual(classifyResult({
    code: 1,
    signal: null,
    stdout: authRequired,
    stderr: Buffer.alloc(0),
    allowAuthRequired: true,
  }), { status: 'AUTH_REQUIRED' })
  assert.throws(() => classifyResult({
    code: 1,
    signal: null,
    stdout: authRequired,
    stderr: Buffer.from('framework diagnostic'),
    allowAuthRequired: true,
  }), /unexpected stderr/)
})
