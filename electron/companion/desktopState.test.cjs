'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { CompanionDesktopState } = require('./desktopState.cjs')
const { CompanionProjectionStore } = require('./projectionStore.cjs')

const golden = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'snapshot-board.json'), 'utf8')).body.projection

function setup({ attentionService = null } = {}) {
  let time = 1_000
  const records = new Map()
  const projectionStore = new CompanionProjectionStore({
    epoch: 'desktop-epoch-current',
    get: (key) => records.get(key) ?? null,
    set: (key, value) => records.set(key, value),
    del: (key) => records.delete(key),
    keys: () => [...records.keys()],
    now: () => time,
  })
  const state = new CompanionDesktopState({
    epoch: 'desktop-epoch-current',
    projectionStore,
    attentionService,
    windowLabel: (windowId) => windowId === 'saved-primary' ? 'Kaisola' : 'Research',
    now: () => time,
  })
  return { state, projectionStore, setTime: (value) => { time = value } }
}

test('published projections feed bounded replay and a rebuilt mobile board snapshot', () => {
  const { state, projectionStore } = setup()
  const result = projectionStore.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: golden })
  const event = state.projectionPublished('saved-primary', result)
  assert.equal(event.type, 'project.updated')
  const replay = state.replay({ epoch: 'desktop-epoch-current', afterSeq: 0 })
  assert.deepEqual(replay.events.map(({ type }) => type), ['project.updated'])
  assert.deepEqual(state.snapshot().board.columns.map(({ id, count }) => ({ id, count })), [
    { id: 'running', count: 1 },
    { id: 'waiting', count: 1 },
    { id: 'done', count: 1 },
  ])
  assert.deepEqual(
    state.snapshot().projects.map(({ windowId, windowName }) => ({ windowId, windowName })),
    [{ windowId: 'saved-primary', windowName: 'Kaisola' }],
  )
  assert.equal(event.payload.projection.sessions[0].windowId, 'saved-primary')
})

test('latest window wins a moved project without duplicating sessions', () => {
  const { state, projectionStore, setTime } = setup()
  const first = projectionStore.publish({ windowId: 'saved-primary', publisherGeneration: 1, projection: golden })
  state.projectionPublished('saved-primary', first)
  setTime(2_000)
  const moved = {
    ...golden,
    revision: golden.revision + 1,
    sessions: [{ ...golden.sessions[0], title: 'Moved live session' }],
    attention: [],
    permissions: [],
  }
  const second = projectionStore.publish({ windowId: 'saved-window-2', publisherGeneration: 2, projection: moved })
  state.projectionPublished('saved-window-2', second)
  const snapshot = state.snapshot()
  assert.equal(snapshot.projects.length, 1)
  assert.deepEqual(snapshot.sessions.map(({ title }) => title), ['Moved live session'])
  assert.deepEqual(state.projectIdsForWindow('saved-primary'), [])
  assert.deepEqual(state.projectIdsForWindow('saved-window-2'), ['project-kaisola'])
})

test('terminal observer channels normalize into replay events without exposing a listener', () => {
  const { state } = setup()
  state.terminalObserverEvent('project-kaisola', {
    channel: 'terminal:observer-output',
    payload: { id: 'terminal-1', streamEpoch: 'stream-1', startOffset: 3, endOffset: 7, data: '🙂' },
  })
  state.terminalObserverEvent('project-kaisola', {
    channel: 'terminal:observer-snapshot-required',
    payload: { id: 'terminal-1', streamEpoch: 'stream-1', endOffset: 7, reason: 'slow_consumer' },
  })
  const replay = state.replay({ epoch: 'desktop-epoch-current', afterSeq: 0 })
  assert.deepEqual(replay.events.map(({ type }) => type), ['terminal.output', 'terminal.snapshot'])
  assert.equal(replay.events[0].payload.data, '🙂')
  assert.equal(replay.events[1].payload.snapshotRequired, true)
})

test('authoritative terminal snapshots, ACP events, and ledger updates share one ordered replay', () => {
  const { state } = setup()
  state.terminalObserverSnapshot('project-kaisola', 'terminal-1', {
    ok: true,
    mode: 'snapshot',
    snapshot: {
      streamEpoch: 'stream-1',
      output: 'ready\n',
      startOffset: 0,
      endOffset: 6,
      truncated: false,
      exited: false,
    },
  })
  state.acpSessionEvent({
    type: 'agent.turn.delta',
    projectId: 'project-kaisola',
    targetId: 'codex-session',
    turnId: 'turn-1',
    delta: { text: 'working' },
  })
  state.ledgerEvent({
    type: 'updated',
    task: {
      id: 'task-1',
      projectId: 'project-kaisola',
      status: 'review',
      title: 'Review result',
      updatedAt: 1_000,
    },
  })

  const replay = state.replay({ epoch: 'desktop-epoch-current', afterSeq: 0 })
  assert.deepEqual(replay.events.map(({ type }) => type), [
    'terminal.snapshot',
    'agent.turn.delta',
    'ledger.task.updated',
  ])
  assert.equal(replay.events[0].payload.output, 'ready\n')
  assert.equal(replay.events[1].payload.delta.text, 'working')
  assert.equal(replay.events[2].payload.task.status, 'review')
})

test('ACP deltas skip replay cloning with no companion while attention authority still observes them', () => {
  const observed = []
  const { state } = setup({ attentionService: { handleAcpEvent: (event) => observed.push(event) } })
  const event = {
    type: 'agent.turn.delta',
    projectId: 'project-kaisola',
    targetId: 'codex-session',
    turnId: 'turn-no-device',
    delta: { text: 'working' },
  }
  assert.equal(state.acpSessionEvent(event, { recordReplay: false }), null)
  assert.equal(state.stats().eventLog.currentSeq, 1)
  assert.equal(state.stats().eventLog.droppedThrough, 1)
  assert.equal(state.stats().eventLog.retainedEvents, 0)
  assert.deepEqual(observed[0], event)

  state.acpSessionEvent(event)
  assert.equal(state.stats().eventLog.currentSeq, 2)
})

test('gateway terminal snapshots are byte-bounded before entering replay', () => {
  const { state } = setup()
  const output = `head-${'x'.repeat(300 * 1024)}-tail`
  const bytes = Buffer.byteLength(output)
  state.terminalObserverSnapshot('project-kaisola', 'terminal-large', {
    ok: true,
    mode: 'snapshot',
    snapshot: {
      streamEpoch: 'stream-large',
      output,
      startOffset: 0,
      endOffset: bytes,
      truncated: false,
      exited: false,
    },
  })
  const snapshot = state.replay({ epoch: 'desktop-epoch-current', afterSeq: 0 }).events[0].payload
  assert.ok(Buffer.byteLength(snapshot.output, 'utf8') <= 256 * 1024)
  assert.equal(snapshot.output.endsWith('-tail'), true)
  assert.equal(snapshot.startOffset, bytes - Buffer.byteLength(snapshot.output, 'utf8'))
  assert.equal(snapshot.truncated, true)
})
