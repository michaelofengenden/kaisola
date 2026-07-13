const test = require('node:test')
const assert = require('node:assert/strict')

test('concurrent Mesh executions cannot share worktree task ids', async () => {
  const { newMeshWorktreeBatchId, meshWorktreeTaskId } = await import('../src/lib/meshWorktreeId.ts')
  const now = 1_700_000_000_000
  const first = newMeshWorktreeBatchId(now, '11111111-1111-4111-8111-111111111111')
  const second = newMeshWorktreeBatchId(now, '22222222-2222-4222-8222-222222222222')
  const firstIds = [0, 1, 2].map((index) => meshWorktreeTaskId(first, index))
  const secondIds = [0, 1, 2].map((index) => meshWorktreeTaskId(second, index))

  assert.equal(new Set([...firstIds, ...secondIds]).size, 6)
  for (const id of [...firstIds, ...secondIds]) assert.match(id, /^[A-Za-z0-9_-]+$/)
  assert.throws(() => meshWorktreeTaskId('../escape', -1), /Invalid/)
})
