'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { TerminalObservers } = require('../../runtime/node-broker/ipc/terminalObservers.cjs')

test('slow consumer stays paused when its forced reset marker is delivered', () => {
  const calls = []
  const observers = new TerminalObservers({
    terminalId: 'terminal-a',
    deliver: (owner, channel, payload, options) => {
      calls.push({ owner, channel, payload, options })
      return channel === 'terminal:observer-snapshot-required'
    },
  })
  observers.subscribe('instance-a|owner-a|project-a', { maxQueueBytes: 64 * 1024 })

  assert.deepEqual(observers.broadcast('terminal:observer-output', { output: 'saturated' }, {
    streamEpoch: 'epoch-a',
    endOffset: 9,
  }), { delivered: 0, paused: 1 })
  assert.deepEqual(observers.stats(), { subscribers: 1, paused: 1 })
  assert.deepEqual(calls, [
    {
      owner: 'instance-a|owner-a|project-a',
      channel: 'terminal:observer-output',
      payload: { output: 'saturated' },
      options: { maxQueueBytes: 64 * 1024 },
    },
    {
      owner: 'instance-a|owner-a|project-a',
      channel: 'terminal:observer-snapshot-required',
      payload: {
        id: 'terminal-a',
        reason: 'slow_consumer',
        streamEpoch: 'epoch-a',
        endOffset: 9,
      },
      options: { force: true, maxQueueBytes: 64 * 1024 },
    },
  ])

  observers.broadcast('terminal:observer-output', { output: 'discarded while paused' })
  assert.equal(calls.length, 2, 'a paused subscription receives no later deltas')
})

test('failed forced reset delivery closes only the saturated subscription and permits recovery', () => {
  const calls = []
  const saturatedOwner = 'instance-a|owner-a|project-a'
  const healthyOwner = 'instance-b|owner-b|project-b'
  let saturated = true
  const observers = new TerminalObservers({
    terminalId: 'terminal-a',
    deliver: (owner, channel, payload, options) => {
      calls.push({ owner, channel, payload, options })
      return !saturated || owner !== saturatedOwner
    },
  })
  observers.subscribe(saturatedOwner, { maxQueueBytes: 64 * 1024 })
  observers.subscribe(healthyOwner, { maxQueueBytes: 128 * 1024 })

  assert.deepEqual(observers.broadcast('terminal:observer-output', { output: 'first' }, {
    streamEpoch: 'epoch-a',
    endOffset: 5,
  }), { delivered: 1, paused: 0 })
  assert.deepEqual(observers.stats(), { subscribers: 1, paused: 0 })
  assert.equal(calls.filter((call) => call.owner === saturatedOwner).length, 2)
  const resetCall = calls.find(
    (call) => call.owner === saturatedOwner && call.channel === 'terminal:observer-snapshot-required',
  )
  assert.equal(resetCall?.options.force, true)

  calls.length = 0
  observers.broadcast('terminal:observer-output', { output: 'second' })
  assert.deepEqual(calls.map((call) => call.owner), [healthyOwner], 'the failed subscription stays closed')

  saturated = false
  observers.subscribe('instance-a|owner-a|project-a', { maxQueueBytes: 64 * 1024 })
  calls.length = 0
  assert.deepEqual(observers.broadcast('terminal:observer-output', { output: 'recovered' }), {
    delivered: 2,
    paused: 0,
  })
  assert.deepEqual(new Set(calls.map((call) => call.owner)), new Set([
    'instance-a|owner-a|project-a',
    healthyOwner,
  ]))
})
