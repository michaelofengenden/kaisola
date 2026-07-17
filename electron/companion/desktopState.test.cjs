'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { CompanionDesktopState } = require('./desktopState.cjs')
const { CompanionProjectionStore } = require('./projectionStore.cjs')

const golden = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'snapshot-board.json'), 'utf8')).body.projection

function setup() {
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
  const state = new CompanionDesktopState({ epoch: 'desktop-epoch-current', projectionStore, now: () => time })
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

