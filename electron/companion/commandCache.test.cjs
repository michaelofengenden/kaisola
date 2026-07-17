'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  CompanionCommandCache,
  CompanionCommandCacheError,
  fingerprintCommand,
} = require('./commandCache.cjs')

function descriptor(commandId, command) {
  return { commandId, fingerprint: fingerprintCommand(command) }
}

test('fingerprints are stable across object key order and sensitive to content', () => {
  assert.equal(
    fingerprintCommand({ type: 'agent.cancel', payload: { force: false, reason: 'phone' } }),
    fingerprintCommand({ payload: { reason: 'phone', force: false }, type: 'agent.cancel' }),
  )
  assert.notEqual(
    fingerprintCommand({ type: 'agent.cancel', payload: { force: false } }),
    fingerprintCommand({ type: 'agent.cancel', payload: { force: true } }),
  )
  assert.throws(() => fingerprintCommand({ value: Number.NaN }), /non-finite/)
})

test('duplicate sequential commands replay the cached receipt exactly once', async () => {
  const cache = new CompanionCommandCache()
  const key = descriptor('command-1', { type: 'agent.cancel', sessionId: 'session-1' })
  let executions = 0
  const run = () => cache.execute(key, async () => ({ status: 'applied', execution: ++executions }))
  assert.deepEqual(await run(), { status: 'applied', execution: 1 })
  assert.deepEqual(await run(), { status: 'applied', execution: 1 })
  assert.equal(executions, 1)
})

test('concurrent duplicates join one in-flight execution', async () => {
  const cache = new CompanionCommandCache()
  const key = descriptor('command-2', { type: 'terminal.interrupt', terminalId: 'terminal-1' })
  let release
  const gate = new Promise((resolve) => { release = resolve })
  let executions = 0
  const execute = () => cache.execute(key, async () => {
    executions++
    await gate
    return { status: 'applied' }
  })
  const first = execute()
  const second = execute()
  await Promise.resolve()
  assert.equal(executions, 1)
  assert.equal(cache.stats().inFlightCommands, 1)
  release()
  assert.deepEqual(await Promise.all([first, second]), [{ status: 'applied' }, { status: 'applied' }])
  assert.equal(executions, 1)
})

test('reusing a command id with mutated content fails closed', async () => {
  const cache = new CompanionCommandCache()
  const first = descriptor('command-3', { type: 'terminal.write', data: 'npm test\r' })
  const mutated = descriptor('command-3', { type: 'terminal.write', data: 'rm -rf /\r' })
  await cache.execute(first, async () => ({ status: 'applied' }))
  await assert.rejects(() => cache.execute(mutated, async () => ({ status: 'applied' })), (error) => {
    assert.equal(error instanceof CompanionCommandCacheError, true)
    assert.equal(error.code, 'command_id_conflict')
    return true
  })
})

test('TTL expiry and LRU count bounds permit a deliberate later retry', () => {
  let time = 100
  const cache = new CompanionCommandCache({ maxEntries: 2, ttlMs: 10, now: () => time })
  const one = descriptor('command-one', { order: 1 })
  const two = descriptor('command-two', { order: 2 })
  const three = descriptor('command-three', { order: 3 })
  cache.remember(one, { status: 'applied', order: 1 })
  cache.remember(two, { status: 'applied', order: 2 })
  assert.deepEqual(cache.lookup(one), { status: 'applied', order: 1 })
  cache.remember(three, { status: 'applied', order: 3 })
  assert.equal(cache.lookup(two), null)
  assert.deepEqual(cache.lookup(one), { status: 'applied', order: 1 })
  time = 110
  assert.equal(cache.lookup(one), null)
  assert.equal(cache.stats().cachedReceipts, 0)
})

test('failed executions are not cached and returned receipts cannot mutate cache state', async () => {
  const cache = new CompanionCommandCache()
  const key = descriptor('command-4', { type: 'agent.prompt', text: 'continue' })
  await assert.rejects(() => cache.execute(key, async () => { throw new Error('offline') }), /offline/)
  const receipt = await cache.execute(key, async () => ({ status: 'accepted', nested: { revision: 4 } }))
  receipt.nested.revision = 999
  assert.deepEqual(cache.lookup(key), { status: 'accepted', nested: { revision: 4 } })
})

