'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const {
  CompanionProjectionError,
  MAX_PROJECTION_BYTES,
  PROJECTION_KIND,
  sanitizeProjection,
} = require('./redaction.cjs')

function projection(overrides = {}) {
  return {
    projectionKind: PROJECTION_KIND,
    revision: 9,
    generatedAt: 1784250000000,
    freshness: 'live',
    projects: [{ id: 'project-kaisola', name: 'Kaisola', repo: 'Kaisola', branch: 'main', connection: 'live', lastContactAt: 1784250000000 }],
    sessions: [
      { id: 'session-running', projectId: 'project-kaisola', kind: 'agent', title: 'Implement protocol', provider: 'Codex', status: 'running', updatedAt: 30, summary: 'Writing fixtures' },
      { id: 'session-waiting', projectId: 'project-kaisola', kind: 'agent', title: 'Review permission', provider: 'Claude', status: 'idle', needsYou: true, unread: true, updatedAt: 20, summary: 'One approval needed' },
      { id: 'session-done', projectId: 'project-kaisola', kind: 'terminal', title: 'Build', status: 'done', updatedAt: 10, summary: 'Passed' },
    ],
    attention: [],
    permissions: [],
    ...overrides,
  }
}

test('projection becomes a compact Running / Needs You / Done board', () => {
  const clean = sanitizeProjection(projection())
  assert.deepEqual(clean.board.columns.map(({ id, title, count }) => ({ id, title, count })), [
    { id: 'running', title: 'Running', count: 1 },
    { id: 'waiting', title: 'Needs You', count: 1 },
    { id: 'done', title: 'Done', count: 1 },
  ])
  assert.equal(clean.board.columns[1].sourceLabel, 'Waiting for review')
  assert.equal(clean.sessions.find((session) => session.id === 'session-waiting').status, 'waiting')
  assert.deepEqual(clean.projects[0].counts, { running: 1, waiting: 1, done: 1, failed: 0 })
  assert.ok(Buffer.byteLength(JSON.stringify(clean)) < MAX_PROJECTION_BYTES)
})

test('attention without a waiting session becomes a waiting card and sorts newest first', () => {
  const clean = sanitizeProjection(projection({
    attention: [
      { id: 'attention-review', projectId: 'project-kaisola', kind: 'review', title: 'Review worktree diff', detail: '3 files changed', createdAt: 40 },
      { id: 'attention-old', projectId: 'project-kaisola', kind: 'blocked', title: 'Agent is blocked', createdAt: 15 },
    ],
  }))
  const waiting = clean.board.columns.find((column) => column.id === 'waiting')
  assert.deepEqual(waiting.cards.map((card) => card.id), ['attention-review', 'session-waiting', 'attention-old'])
})

test('allowlist rejects raw stores and secret-bearing normalized shapes', () => {
  assert.throws(() => sanitizeProjection({ projectTabs: [], workspacePath: '/repo' }), (error) => {
    assert.equal(error instanceof CompanionProjectionError, true)
    assert.equal(error.code, 'not_normalized')
    return true
  })
  assert.throws(() => sanitizeProjection(projection({ token: 'never-cross-this-boundary' })), /forbidden key: token/)
  assert.throws(() => sanitizeProjection(projection({ nested: { env: { API_KEY: 'secret' } } })), /forbidden key: env/)
})

test('permissions keep bounded relative diffs and reject path escape', () => {
  const permission = {
    permId: 'permission-1',
    projectId: 'project-kaisola',
    sessionId: 'session-waiting',
    agent: 'Claude',
    title: 'Edit terminal policy',
    requestedAt: 50,
    options: [{ id: 'allow-once', label: 'Allow once' }, { id: 'reject', label: 'Reject' }],
    diffs: [{ relativePath: 'electron/ipc/terminalManager.cjs', oldText: 'old', newText: 'new' }],
  }
  const clean = sanitizeProjection(projection({ permissions: [permission] }))
  assert.equal(clean.permissions[0].diffs[0].relativePath, 'electron/ipc/terminalManager.cjs')
  assert.throws(
    () => sanitizeProjection(projection({ permissions: [{ ...permission, diffs: [{ ...permission.diffs[0], relativePath: '../.ssh/config' }] }] })),
    /workspace-relative/,
  )
  assert.throws(
    () => sanitizeProjection(projection({ permissions: [{ ...permission, diffs: [{ ...permission.diffs[0], relativePath: '/Users/michael/.ssh/config' }] }] })),
    /workspace-relative/,
  )
})

test('cross-project session and attention references fail closed', () => {
  assert.throws(
    () => sanitizeProjection(projection({ sessions: [{ ...projection().sessions[0], projectId: 'project-other' }] })),
    /unknown project/,
  )
  assert.throws(
    () => sanitizeProjection(projection({ attention: [{ id: 'attention-1', projectId: 'project-kaisola', sessionId: 'missing-session', kind: 'review', title: 'Review', createdAt: 40 }] })),
    /unknown session/,
  )
})

test('the post-redaction byte cap rejects otherwise valid oversized projections', () => {
  const turns = Array.from({ length: 40 }, (_, index) => ({
    kind: index % 2 === 0 ? 'assistant' : 'tool',
    text: `${index}:${'x'.repeat(16 * 1024)}`,
  }))
  assert.throws(
    () => sanitizeProjection(projection({ sessions: [{ ...projection().sessions[0], turns }] })),
    /projection exceeds the companion limit/,
  )
})
