const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { _mcpTest } = require('./ipc/mcpServer.cjs')

const workspaceA = path.resolve('/tmp/kaisola-project-a')
const workspaceB = path.resolve('/tmp/kaisola-project-b')

test('MCP capabilities are stable per project and distinct across projects', (t) => {
  _mcpTest.resetCapabilities()
  t.after(_mcpTest.resetCapabilities)

  const first = _mcpTest.issueCapability({ projectId: 'project-a', workspace: workspaceA, storeKey: 'kaisola-store' })
  const moved = _mcpTest.issueCapability({ projectId: 'project-a', workspace: workspaceA, storeKey: 'kaisola-store-w2' })
  const other = _mcpTest.issueCapability({ projectId: 'project-b', workspace: workspaceB, storeKey: 'kaisola-store-w2' })

  assert.match(first.token, /^[0-9a-f]{64}$/)
  assert.equal(moved.token, first.token)
  assert.equal(moved.context.storeKey, 'kaisola-store-w2')
  assert.notEqual(other.token, first.token)
  assert.equal(_mcpTest.issueCapability({ projectId: 'project-a', workspace: 'relative/path' }), null)
})

test('persisted MCP reads select only the capability project and exact workspace', () => {
  const state = {
    activeProjectId: 'project-a',
    projectTabs: [
      { id: 'project-a', workspacePath: workspaceA },
      { id: 'project-b', workspacePath: workspaceB },
    ],
    projectSlices: {
      'project-a': {
        workspacePath: workspaceA,
        stage: 'ideas',
        project: { name: 'A', corpus: [{ id: 'a-source' }] },
      },
      'project-b': {
        workspacePath: workspaceB,
        stage: 'runs',
        project: { name: 'B', corpus: [{ id: 'b-source' }] },
      },
    },
  }

  const a = _mcpTest.selectProjectState(state, { projectId: 'project-a', workspace: workspaceA })
  const b = _mcpTest.selectProjectState(state, { projectId: 'project-b', workspace: workspaceB })
  assert.equal(a.project.name, 'A')
  assert.equal(b.project.name, 'B')
  assert.equal(_mcpTest.selectProjectState(state, { projectId: 'project-b', workspace: workspaceA }), null)
  assert.equal(_mcpTest.selectProjectState(state, { projectId: 'missing', workspace: workspaceB }), null)
})

test('persisted MCP reads retain the legacy flat active-project fallback', () => {
  const legacy = {
    activeProjectId: 'project-a',
    projectTabs: [{ id: 'project-a', workspacePath: workspaceA }],
    workspacePath: workspaceA,
    stage: 'ideas',
    project: { name: 'Legacy A' },
    projectSlices: {},
  }

  const selected = _mcpTest.selectProjectState(legacy, { projectId: 'project-a', workspace: workspaceA })
  assert.equal(selected.project.name, 'Legacy A')
  assert.equal(_mcpTest.selectProjectState(legacy, { projectId: 'project-a', workspace: workspaceB }), null)
})

test('normalized MCP project slices win over stale legacy flat fields', () => {
  const mixed = {
    activeProjectId: 'project-a',
    projectTabs: [{ id: 'project-a', workspacePath: workspaceA }],
    workspacePath: workspaceB,
    project: { name: 'Stale flat project' },
    projectSlices: {
      'project-a': { workspacePath: workspaceA, project: { name: 'Normalized A' } },
    },
  }

  const selected = _mcpTest.selectProjectState(mixed, { projectId: 'project-a', workspace: workspaceA })
  assert.equal(selected.project.name, 'Normalized A')
})

test('malformed JSON-RPC values are contained as protocol errors', async () => {
  for (const value of [null, [], 'request', 42]) {
    const reply = await _mcpTest.handleRpc(value, { projectId: 'project-a', workspace: workspaceA })
    assert.equal(reply.error.code, -32600)
    assert.equal(reply.id, null)
  }
})

test('human-gated MCP writes require an ACK from the exact full renderer', async () => {
  const sent = []
  const makeWindow = ({ id, pop = false, loading = false, ack = false, owns = true }) => ({
    owns,
    __kaisolaPop: pop,
    webContents: {
      id,
      isDestroyed: () => false,
      isLoadingMainFrame: () => loading,
      send: (_channel, payload) => {
        sent.push({ id, payload })
        if (ack) queueMicrotask(() => _mcpTest.handleProposalAck(id, { proposalId: payload.proposalId, accepted: true }))
      },
    },
  })
  const pop = makeWindow({ id: 1, pop: true, ack: true })
  const loading = makeWindow({ id: 2, loading: true, ack: true })
  const owner = makeWindow({ id: 3, ack: true })
  const context = { projectId: 'project-a', workspace: workspaceA, webContentsId: 3 }
  const accepted = await _mcpTest.broadcastProposal('claim', { label: 'A' }, context, {
    browserWindow: { getAllWindows: () => [pop, loading, owner] },
    ownsProject: (win) => win.owns,
    timeoutMs: 25,
    unrefTimer: false,
  })
  assert.equal(accepted.ok, true)
  assert.deepEqual(sent.map(({ id }) => id), [3])

  sent.length = 0
  const silentOwner = makeWindow({ id: 3 })
  const rejected = await _mcpTest.broadcastProposal('claim', { label: 'B' }, context, {
    browserWindow: { getAllWindows: () => [silentOwner] },
    ownsProject: (win) => win.owns,
    timeoutMs: 10,
    unrefTimer: false,
  })
  assert.equal(rejected.ok, false)
  assert.equal(rejected.status, 'project_not_open')
})

test('MCP proposals follow project ownership after a window handoff', async () => {
  const sent = []
  const makeWindow = ({ id, owns, accepted }) => ({
    owns,
    webContents: {
      id,
      isDestroyed: () => false,
      isLoadingMainFrame: () => false,
      send: (_channel, payload) => {
        sent.push(id)
        queueMicrotask(() => _mcpTest.handleProposalAck(id, { proposalId: payload.proposalId, accepted }))
      },
    },
  })
  const oldWindow = makeWindow({ id: 3, owns: false, accepted: false })
  const newWindow = makeWindow({ id: 4, owns: true, accepted: true })
  const context = { projectId: 'project-a', workspace: workspaceA, webContentsId: 3 }
  const moved = await _mcpTest.broadcastProposal('claim', { label: 'moved' }, context, {
    browserWindow: { getAllWindows: () => [oldWindow, newWindow] },
    ownsProject: (win) => win.owns,
    timeoutMs: 25,
    unrefTimer: false,
  })
  assert.equal(moved.ok, true)
  assert.deepEqual(sent, [4])
})

test('MCP proposal falls through only after an explicit negative ACK', async () => {
  const sent = []
  const makeWindow = ({ id, accepted }) => ({
    owns: true,
    webContents: {
      id,
      isDestroyed: () => false,
      isLoadingMainFrame: () => false,
      send: (_channel, payload) => {
        sent.push(id)
        queueMicrotask(() => _mcpTest.handleProposalAck(id, { proposalId: payload.proposalId, accepted }))
      },
    },
  })
  const original = makeWindow({ id: 3, accepted: false })
  const moved = makeWindow({ id: 4, accepted: true })
  const result = await _mcpTest.broadcastProposal('claim', { label: 'fallback' }, {
    projectId: 'project-a', workspace: workspaceA, webContentsId: 3,
  }, {
    browserWindow: { getAllWindows: () => [moved, original] },
    ownsProject: (win) => win.owns,
    timeoutMs: 25,
    unrefTimer: false,
  })
  assert.equal(result.ok, true)
  assert.deepEqual(sent, [3, 4])
})
