'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const {
  BrokerMutationLedger,
  BrokerRequestGate,
  DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT,
  DEFAULT_PROCESS_IN_FLIGHT_LIMIT,
  dispatchBrokerRequest,
} = require('../../runtime/node-broker/ipc/brokerRequestGate.cjs')

function deferred() {
  let resolve
  let reject
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

function settle() {
  return new Promise((resolve) => setImmediate(resolve))
}

function submit({
  gate, client, id, operation, dispatch, responses, mutating = false, events = [], idempotency,
}) {
  return dispatchBrokerRequest({
    gate,
    client,
    requestID: id,
    mutating,
    dispatch: dispatch || (() => operation),
    beginMutation: () => events.push(['begin', id]),
    endMutation: () => events.push(['end', id]),
    respond: (frame) => responses.push(frame),
    onSuccess: () => events.push(['success', id]),
    idempotency,
  })
}

test('duplicate mutation ids join and replay one authoritative outcome', async () => {
  const gate = new BrokerRequestGate({ perClientLimit: 2, processLimit: 2 })
  const ledger = new BrokerMutationLedger({ maximumEntries: 4, maximumBytes: 4_096, ttlMs: 1_000 })
  const client = {}
  const operation = deferred()
  const responses = []
  const events = []
  let applications = 0
  const idempotency = { ledger, key: 'controller|owner|project|mutation', fingerprint: 'same-request' }
  const dispatch = () => {
    applications += 1
    return operation.promise
  }

  assert.equal(submit({
    gate, client, id: 'first', dispatch, responses, mutating: true, events, idempotency,
  }), true)
  assert.equal(submit({
    gate, client, id: 'retry-while-running', dispatch, responses, mutating: true, events, idempotency,
  }), true)
  assert.equal(applications, 1, 'an in-flight retry must join, not dispatch again')

  operation.resolve({ ok: true, receipt: 'applied-once' })
  await settle()
  assert.deepEqual(responses.toSorted((left, right) => left.id.localeCompare(right.id)), [
    { type: 'response', id: 'first', ok: true, result: { ok: true, receipt: 'applied-once' } },
    { type: 'response', id: 'retry-while-running', ok: true, result: { ok: true, receipt: 'applied-once' } },
  ])
  assert.deepEqual(events, [['begin', 'first'], ['end', 'first'], ['success', 'first']])

  assert.equal(submit({
    gate, client, id: 'retry-after-settlement', dispatch, responses, mutating: true, events, idempotency,
  }), true)
  await settle()
  assert.equal(applications, 1, 'a settled retry must replay without dispatch')
  assert.deepEqual(responses.at(-1), {
    type: 'response', id: 'retry-after-settlement', ok: true,
    result: { ok: true, receipt: 'applied-once' },
  })

  assert.equal(submit({
    gate,
    client,
    id: 'reused-for-other-input',
    dispatch,
    responses,
    mutating: true,
    events,
    idempotency: { ...idempotency, fingerprint: 'different-request' },
  }), false)
  assert.deepEqual(responses.at(-1), {
    type: 'response', id: 'reused-for-other-input', ok: false,
    code: 'mutation_id_reused',
    message: 'broker mutation id was reused with different parameters',
  })
  assert.equal(applications, 1)
})

test('mutation ledger rejects new work when only in-flight receipts fill its bound', async () => {
  const gate = new BrokerRequestGate({ perClientLimit: 2, processLimit: 2 })
  const ledger = new BrokerMutationLedger({ maximumEntries: 1, maximumBytes: 1_024, ttlMs: 1_000 })
  const client = {}
  const operation = deferred()
  const responses = []
  assert.equal(submit({
    gate,
    client,
    id: 'retained',
    operation: operation.promise,
    responses,
    mutating: true,
    idempotency: { ledger, key: 'retained', fingerprint: 'first' },
  }), true)
  assert.equal(submit({
    gate,
    client,
    id: 'bounded',
    operation: Promise.resolve({ ok: true }),
    responses,
    mutating: true,
    idempotency: { ledger, key: 'bounded', fingerprint: 'second' },
  }), false)
  assert.deepEqual(responses, [{
    type: 'response', id: 'bounded', ok: false,
    code: 'mutation_ledger_full',
    message: 'broker mutation reconciliation capacity exceeded',
  }])
  operation.resolve({ ok: true })
  await settle()
})

test('a flooded client is rejected while another client remains responsive', async () => {
  const gate = new BrokerRequestGate({ perClientLimit: 2, processLimit: 3 })
  const floodClient = {}
  const healthyClient = {}
  const first = deferred()
  const second = deferred()
  const responses = []

  assert.equal(submit({ gate, client: floodClient, id: 'flood-1', operation: first.promise, responses }), true)
  assert.equal(submit({ gate, client: floodClient, id: 'flood-2', operation: second.promise, responses }), true)
  assert.equal(submit({ gate, client: floodClient, id: 'flood-3', operation: Promise.resolve(), responses }), false)
  assert.deepEqual(responses, [{
    type: 'response',
    id: 'flood-3',
    ok: false,
    code: 'broker_overloaded',
    scope: 'client',
    limit: 2,
    message: 'broker request capacity exceeded',
  }])

  assert.equal(submit({
    gate,
    client: healthyClient,
    id: 'healthy-1',
    operation: Promise.resolve({ ok: true, value: 'still-responsive' }),
    responses,
  }), true)
  await settle()
  assert.deepEqual(responses.at(-1), {
    type: 'response',
    id: 'healthy-1',
    ok: true,
    result: { ok: true, value: 'still-responsive' },
  })

  first.resolve({ ok: true })
  second.resolve({ ok: true })
  await settle()
})

test('production defaults reserve headroom after one client reaches its ceiling', async () => {
  assert.ok(DEFAULT_PROCESS_IN_FLIGHT_LIMIT > DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT)
  const gate = new BrokerRequestGate()
  const floodClient = {}
  const healthyClient = {}
  const pending = Array.from({ length: DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT }, deferred)
  const responses = []

  for (const [index, operation] of pending.entries()) {
    assert.equal(submit({
      gate,
      client: floodClient,
      id: `production-flood-${index}`,
      operation: operation.promise,
      responses,
    }), true)
  }
  assert.equal(submit({
    gate,
    client: floodClient,
    id: 'production-flood-overload',
    operation: Promise.resolve(),
    responses,
  }), false)
  assert.equal(responses.at(-1).scope, 'client')
  assert.equal(responses.at(-1).limit, DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT)

  assert.equal(submit({
    gate,
    client: healthyClient,
    id: 'production-healthy',
    operation: Promise.resolve('available'),
    responses,
  }), true)
  await settle()
  assert.ok(responses.some((frame) => frame.id === 'production-healthy' && frame.ok === true))

  for (const operation of pending) operation.resolve({ ok: true })
  await settle()
})

test('process-wide capacity rejects a different client with a typed response', async () => {
  const gate = new BrokerRequestGate({ perClientLimit: 2, processLimit: 3 })
  const firstClient = {}
  const secondClient = {}
  const rejectedClient = {}
  const pending = [deferred(), deferred(), deferred()]
  const responses = []

  assert.equal(submit({ gate, client: firstClient, id: 'first-1', operation: pending[0].promise, responses }), true)
  assert.equal(submit({ gate, client: firstClient, id: 'first-2', operation: pending[1].promise, responses }), true)
  assert.equal(submit({ gate, client: secondClient, id: 'second-1', operation: pending[2].promise, responses }), true)
  assert.equal(submit({ gate, client: rejectedClient, id: 'process-full', operation: Promise.resolve(), responses }), false)
  assert.deepEqual(responses, [{
    type: 'response',
    id: 'process-full',
    ok: false,
    code: 'broker_overloaded',
    scope: 'process',
    limit: 3,
    message: 'broker request capacity exceeded',
  }])

  for (const operation of pending) operation.resolve({ ok: true })
  await settle()
})

test('resolved and rejected work releases capacity exactly once', async () => {
  const gate = new BrokerRequestGate({ perClientLimit: 1, processLimit: 1 })
  const client = {}
  const responses = []

  assert.equal(submit({ gate, client, id: 'rejected', operation: Promise.reject(new Error('nope')), responses }), true)
  await settle()
  assert.deepEqual(responses, [{
    type: 'response',
    id: 'rejected',
    ok: false,
    message: 'nope',
  }])

  assert.equal(submit({ gate, client, id: 'resolved', operation: Promise.resolve('done'), responses }), true)
  await settle()
  assert.deepEqual(responses.at(-1), {
    type: 'response',
    id: 'resolved',
    ok: true,
    result: 'done',
  })
})

test('mutation accounting wraps only admitted dispatches', async () => {
  const gate = new BrokerRequestGate({ perClientLimit: 1, processLimit: 1 })
  const client = {}
  const operation = deferred()
  const responses = []
  const events = []

  assert.equal(submit({
    gate,
    client,
    id: 'mutation-1',
    operation: operation.promise,
    responses,
    mutating: true,
    events,
  }), true)
  assert.equal(submit({
    gate,
    client,
    id: 'mutation-overload',
    operation: Promise.resolve(),
    responses,
    mutating: true,
    events,
  }), false)
  assert.deepEqual(events, [['begin', 'mutation-1']])

  operation.resolve({ ok: true })
  await settle()
  assert.deepEqual(events, [
    ['begin', 'mutation-1'],
    ['end', 'mutation-1'],
    ['success', 'mutation-1'],
  ])
})
