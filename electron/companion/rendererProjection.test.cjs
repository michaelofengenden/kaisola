'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const ts = require('typescript')
const { sanitizeProjection } = require('./redaction.cjs')

function loadProjectionModule() {
  const filename = path.join(__dirname, '..', '..', 'src', 'lib', 'companionProjection.ts')
  const source = fs.readFileSync(filename, 'utf8')
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    fileName: filename,
    reportDiagnostics: true,
  })
  assert.deepEqual((output.diagnostics ?? []).filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error), [])
  const module = { exports: {} }
  Function('require', 'module', 'exports', output.outputText)(require, module, module.exports)
  return module.exports
}

const { buildCompanionProjection, CompanionProjectionRevisions } = loadProjectionModule()

function state() {
  const projectId = 'project-kaisola'
  return {
    activeProjectId: projectId,
    projectTabs: [{ id: projectId, workspacePath: '/Users/test/Kaisola', title: 'Kaisola', hue: '#fff', createdAt: 10 }],
    projectSlices: {},
    terminals: [{ id: 'terminal-codex', singletonKey: 'agent:codex', promptTitle: 'Build companion' }],
    agentTerminals: [],
    panels: [],
    assistantThreads: [{ id: 'thread-1', agentKey: 'codex', autoName: 'Implement projection', busy: true, lastActivityAt: 30 }],
    assistantRuntimes: { 'thread-1': { first: false, turns: [{ kind: 'assistant', text: 'Publishing safe state.', at: 29 }] } },
    needsYou: { 'terminal-codex': true },
    pendingPermissions: [{
      permId: 'permission-1', key: 'codex', agent: 'Codex', title: 'Edit a file', scope: projectId,
      options: [{ optionId: 'allow-once', name: 'Allow once' }],
      diffs: [
        { path: '/Users/test/Kaisola/src/App.tsx', oldText: 'old', newText: 'new' },
        { path: '/Users/test/.ssh/config', oldText: 'secret', newText: 'secret' },
      ],
    }],
    agentTasks: [{ id: 'task-1', agentId: 'hypothesis', label: 'Review result', status: 'ready', at: '1970-01-01T00:00:00.020Z', stage: 'files' }],
    workspacePath: '/Users/test/Kaisola',
    terminalMeta: {
      'terminal-codex': { agentBusy: false, agentCompletedAt: 25, repo: 'Kaisola', branch: 'main', fgProcess: 'codex' },
    },
  }
}

test('renderer projection includes the board facts but never absolute paths or raw stores', () => {
  const raw = buildCompanionProjection(state(), { revision: 1, generatedAt: 100 })
  const clean = sanitizeProjection(raw)
  assert.equal(clean.projects[0].name, 'Kaisola')
  assert.equal(clean.sessions.find((session) => session.id === 'thread-1').status, 'running')
  assert.equal(clean.sessions.find((session) => session.id === 'terminal-codex').status, 'waiting')
  assert.deepEqual(clean.permissions[0].diffs.map((diff) => diff.relativePath), ['src/App.tsx'])
  assert.equal(JSON.stringify(raw).includes('/Users/test'), false)
  assert.equal(Object.prototype.hasOwnProperty.call(raw, 'workspacePath'), false)
})

test('revision publisher ignores timestamp-only rebuilds and advances on meaningful state', () => {
  const revisions = new CompanionProjectionRevisions()
  const mutable = state()
  assert.equal(revisions.next(mutable, 100).revision, 1)
  assert.equal(revisions.next(mutable, 200), null)
  mutable.assistantThreads = [{ ...mutable.assistantThreads[0], busy: false }]
  assert.equal(revisions.next(mutable, 300).revision, 2)
  assert.equal(revisions.current().generatedAt, 300)
})

test('sensitive permission diffs and terminal command lines stay desktop-only', () => {
  const input = state()
  input.pendingPermissions = [{ ...input.pendingPermissions[0], sensitive: true }]
  input.agentTerminals = [{
    terminalId: 'terminal-secret',
    agentName: 'Runner',
    command: 'API_TOKEN=never-mobile run-agent',
  }]
  const raw = buildCompanionProjection(input, { revision: 1, generatedAt: 100 })
  assert.deepEqual(raw.permissions[0].diffs, [])
  assert.equal(JSON.stringify(raw).includes('never-mobile'), false)
})
