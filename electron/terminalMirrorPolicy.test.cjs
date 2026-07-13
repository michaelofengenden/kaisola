const test = require('node:test')
const assert = require('node:assert/strict')
const { createPopMirrorCache, mergeTerminalMirror, popCloseAckMatches, sanitizeTerminalMirror, tabListOwnsProject } = require('./ipc/terminalMirrorPolicy.cjs')

test('pop terminal mirror accepts only its exact bounded project capability', () => {
  const clean = sanitizeTerminalMirror({
    termId: 'term-one',
    projectId: 'project-one',
    meta: {
      fgProcess: 'codex',
      running: true,
      agentBusy: true,
      agentCompletedAt: 42.4,
      cwd: '/repo',
      ports: [5173, 5173, 65535, '8080'],
      injected: { secret: true },
    },
    draft: 'keep this prompt',
    resume: 'codex resume exact-session',
    arbitrary: 'drop me',
  }, 'term-one', 'project-one')

  assert.deepEqual(clean, {
    termId: 'term-one',
    projectId: 'project-one',
    meta: {
      fgProcess: 'codex',
      cwd: '/repo',
      running: true,
      agentBusy: true,
      agentCompletedAt: 42,
      ports: [5173, 8080],
    },
    draft: 'keep this prompt',
    resume: 'codex resume exact-session',
  })
  assert.equal(sanitizeTerminalMirror({ termId: 'other', projectId: 'project-one', draft: 'no' }, 'term-one', 'project-one'), null)
  assert.equal(sanitizeTerminalMirror({ termId: 'term-one', projectId: 'other', draft: 'no' }, 'term-one', 'project-one'), null)
  assert.equal(sanitizeTerminalMirror({ termId: 'term-one', projectId: 'project-one', meta: { injected: true } }, 'term-one', 'project-one'), null)
})

test('pop terminal mirror preserves explicit clears and caps large drafts', () => {
  const clean = sanitizeTerminalMirror({
    termId: 'term-one',
    projectId: 'project-one',
    meta: { fgProcess: null, lastExit: null, ports: [] },
    draft: 'x'.repeat(70 * 1024),
  }, 'term-one', 'project-one')
  assert.equal(clean.meta.fgProcess, null)
  assert.equal(clean.meta.lastExit, null)
  assert.deepEqual(clean.meta.ports, [])
  assert.equal(clean.draft.length, 64 * 1024)
})

test('pop terminal mirror cache merges fields for renderer replacement replay', () => {
  const merged = mergeTerminalMirror(
    { termId: 'term-one', projectId: 'project-one', meta: { running: true, cwd: '/old' }, draft: 'draft' },
    { termId: 'term-one', projectId: 'project-one', meta: { cwd: '/new' }, resume: 'codex resume exact' },
  )
  assert.deepEqual(merged, {
    termId: 'term-one',
    projectId: 'project-one',
    meta: { running: true, cwd: '/new' },
    draft: 'draft',
    resume: 'codex resume exact',
  })
})

test('pop terminal state is routed only to a full window that owns its project tab', () => {
  const tabs = [{ id: 'project-one' }, { id: 'project-two' }]
  assert.equal(tabListOwnsProject(tabs, 'project-one'), true)
  assert.equal(tabListOwnsProject(tabs, 'other'), false)
  assert.equal(tabListOwnsProject(null, 'project-one'), false)
  assert.equal(tabListOwnsProject([{ id: 'project-one' }], undefined), false)
})

test('closed pop handoff requires the exact terminal, project, and revision ACK', () => {
  const record = {
    state: { termId: 'term-one', projectId: 'project-one', draft: 'final' },
    closed: true,
    revision: 7,
  }
  assert.equal(popCloseAckMatches(record, { termId: 'term-one', projectId: 'project-one', revision: 7 }), true)
  assert.equal(popCloseAckMatches(record, { termId: 'term-two', projectId: 'project-one', revision: 7 }), false)
  assert.equal(popCloseAckMatches(record, { termId: 'term-one', projectId: 'project-two', revision: 7 }), false)
  assert.equal(popCloseAckMatches(record, { termId: 'term-one', projectId: 'project-one', revision: 6 }), false)
  assert.equal(popCloseAckMatches({ ...record, closed: false }, { termId: 'term-one', projectId: 'project-one', revision: 7 }), false)
})

test('closed pop cache retains through owner gaps, ACKs exactly, and clears timers', () => {
  const timers = []
  const cleared = []
  const cache = createPopMirrorCache({
    retentionMs: 500,
    maxClosed: 4,
    setTimeoutFn: (fn, ms) => {
      const timer = { fn, ms, unrefCalled: false, unref() { this.unrefCalled = true } }
      timers.push(timer)
      return timer
    },
    clearTimeoutFn: (timer) => cleared.push(timer),
  })

  cache.activate('term-one', 'project-one')
  cache.update({ termId: 'term-one', projectId: 'project-one', draft: 'final draft' })
  const closed = cache.close('term-one', 'project-one')
  assert.deepEqual(closed, {
    state: { termId: 'term-one', projectId: 'project-one', draft: 'final draft' },
    closed: true,
    revision: 1,
  })
  assert.equal(cache.size, 1)
  assert.equal(timers[0].ms, 500)
  assert.equal(timers[0].unrefCalled, true)
  assert.equal(cache.acknowledge({ termId: 'term-one', projectId: 'project-one', revision: 2 }), false)
  assert.equal(cache.size, 1)
  assert.equal(cache.acknowledge({ termId: 'term-one', projectId: 'project-one', revision: 1 }), true)
  assert.equal(cache.size, 0)
  assert.deepEqual(cleared, [timers[0]])
})

test('closed pop cache expires and evicts oldest handoffs with bounded timer cleanup', () => {
  const timers = []
  const cleared = []
  const cache = createPopMirrorCache({
    retentionMs: 250,
    maxClosed: 2,
    setTimeoutFn: (fn) => {
      const timer = { fn, unref() {} }
      timers.push(timer)
      return timer
    },
    clearTimeoutFn: (timer) => cleared.push(timer),
  })

  for (const id of ['one', 'two', 'three']) {
    cache.activate(id, `project-${id}`)
    cache.close(id, `project-${id}`)
  }
  assert.equal(cache.size, 2)
  assert.equal(cache.get('one'), null)
  assert.equal(cleared.includes(timers[0]), true)

  timers[1].fn()
  assert.equal(cache.get('two'), null)
  assert.equal(cache.size, 1)
  // A late expiry callback for an evicted record cannot delete a newer record
  // reusing the same terminal id.
  cache.activate('one', 'project-one')
  timers[0].fn()
  assert.equal(cache.get('one').closed, false)
})
