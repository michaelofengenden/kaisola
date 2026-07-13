const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { __test } = require('./ipc/toolHandler.cjs')

test('workspace file resolution rejects absolute and sibling-prefix escapes', () => {
  const root = path.resolve('/tmp/kaisola-workspaces')
  assert.equal(__test.safeResolve('project/notes.md', root), path.join(root, 'project', 'notes.md'))
  assert.equal(__test.safeResolve('.', root), root)
  assert.throws(() => __test.safeResolve('../kaisola-workspaces-private/secret', root), /escapes/)
  assert.throws(() => __test.safeResolve(path.resolve('/tmp/outside'), root), /escapes/)
})

test('app-folder containment catches the app root, ancestors, and descendants without prefix collisions', () => {
  const app = path.resolve('/tmp/Kaisola')
  assert.equal(__test.pathContains(app, app), true)
  assert.equal(__test.pathContains('/tmp', app), true)
  assert.equal(__test.pathContains(app, path.join(app, 'electron')), true)
  assert.equal(__test.pathContains(app, '/tmp/Kaisola-backup'), false)
})
