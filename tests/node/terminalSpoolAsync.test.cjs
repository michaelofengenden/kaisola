'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { performance } = require('node:perf_hooks')
const { TerminalSpool } = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

function deferred() {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return { promise, resolve }
}

function within(promise, milliseconds, message) {
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), milliseconds)
  })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

function asyncFixture(t, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-async-'))
  const spool = new TerminalSpool({
    dir,
    id: options.id || 'terminal-spool-async',
    asyncWriter: true,
    queueCap: options.queueCap || 1024,
    hotCap: 4096,
    ...options,
  })
  t.after(async () => {
    await spool.close({ remove: true })
    fs.rmSync(dir, { recursive: true, force: true })
  })
  return spool
}

test('a slow spool rotation stays bounded while another terminal and control turn remain responsive', async (t) => {
  const entered = deferred()
  const release = deferred()
  const backpressure = []
  let blocked = false
  const slow = asyncFixture(t, {
    id: 'slow-writer',
    queueCap: 1024,
    historyQuota: 1024,
    writerHooks: {
      beforeRotate: async () => {
        if (blocked) return
        blocked = true
        entered.resolve()
        await release.promise
      },
    },
    onWriterBackpressure: (paused) => backpressure.push(paused),
  })
  const fast = asyncFixture(t, { id: 'fast-writer', queueCap: 1024 })

  const flushStartedAt = performance.now()
  slow.push('S'.repeat(1024))
  slow.flush()
  assert.ok(performance.now() - flushStartedAt < 25, 'flush only queues asynchronous work')
  await within(entered.promise, 100, 'slow rotation hook never started')

  const controlStartedAt = performance.now()
  const controlTurn = new Promise((resolve) => setImmediate(() => resolve(performance.now() - controlStartedAt)))
  fast.push('unrelated terminal output')
  fast.flush()
  const [controlLatency] = await within(
    Promise.all([controlTurn, fast.settled()]),
    250,
    'an unrelated terminal or control turn stalled behind slow storage',
  )
  assert.ok(controlLatency < 100, `control latency was ${controlLatency}ms`)
  assert.equal(fs.readFileSync(fast.file, 'utf8'), 'unrelated terminal output')

  for (let index = 0; index < 12; index += 1) {
    slow.push(String(index).padStart(2, '0') + 'x'.repeat(510))
  }
  const blockedStats = slow.stats()
  assert.equal(blockedStats.writerPaused, true)
  assert.ok(blockedStats.writerPendingBytes <= blockedStats.writerMaxBytes)
  assert.equal(blockedStats.writerMaxBytes, 2048)
  assert.equal(blockedStats.truncation.reason, 'writer-backpressure')

  release.resolve()
  await within(slow.settled(), 500, 'slow writer did not drain after storage recovered')
  assert.deepEqual(backpressure, [true, false])
  assert.equal(slow.stats().writerPendingBytes, 0)
})

test('close waits for queued appends before returning the verified deletion receipt', async (t) => {
  const entered = deferred()
  const release = deferred()
  const spool = asyncFixture(t, {
    id: 'async-close-delete',
    writerHooks: {
      beforeAppend: async () => {
        entered.resolve()
        await release.promise
      },
    },
  })

  spool.push('secret queued before close')
  spool.flush()
  await within(entered.promise, 100, 'queued append never reached the asynchronous writer')
  const closing = spool.close({ remove: true })
  assert.equal(typeof closing?.then, 'function')
  let closed = false
  closing.then(() => { closed = true })
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(closed, false, 'deletion must wait for the queued writer generation')

  release.resolve()
  const deletion = await within(closing, 500, 'close did not finish after the writer drained')
  assert.deepEqual(deletion, {
    complete: true,
    retryable: false,
    artifacts: [
      { name: 'current', status: 'deleted', attempts: 1 },
      { name: 'previous', status: 'absent', attempts: 1 },
      { name: 'metadata', status: 'deleted', attempts: 1 },
    ],
  })
  assert.equal(fs.existsSync(spool.file), false)
  spool.push('late output cannot resurrect a closed asynchronous spool')
  spool.flush()
  await spool.settled()
  assert.equal(fs.existsSync(spool.file), false)
})
