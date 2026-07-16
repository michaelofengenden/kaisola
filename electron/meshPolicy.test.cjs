const test = require('node:test')
const assert = require('node:assert/strict')

test('Mesh lifecycle policy blocks close while running and rejects stale stage attempts', async () => {
  const { isCurrentMeshOrchestration, isRunningMeshPhase } = await import('../src/lib/meshPolicy.ts')
  assert.equal(isRunningMeshPhase('executing'), true)
  assert.equal(isRunningMeshPhase('execution-ready'), false)
  // Idea mode's two passes are running stages; its settled state is not.
  assert.equal(isRunningMeshPhase('idea-initial'), true)
  assert.equal(isRunningMeshPhase('idea-reacting'), true)
  assert.equal(isRunningMeshPhase('idea-ready'), false)

  const marker = { groupId: 'mesh-parent', attemptId: 'attempt-1', phase: 'executing' }
  assert.equal(isCurrentMeshOrchestration(marker, [{
    id: 'mesh-parent',
    group: { phase: 'executing', stageAttemptId: 'attempt-1' },
  }]), true)
  assert.equal(isCurrentMeshOrchestration(marker, [{
    id: 'mesh-parent',
    group: { phase: 'executing', stageAttemptId: 'attempt-2' },
  }]), false)
  assert.equal(isCurrentMeshOrchestration(marker, [{
    id: 'mesh-parent',
    group: { phase: 'executing', stageAttemptId: 'attempt-1', paused: true },
  }]), false)
  assert.equal(isCurrentMeshOrchestration(marker, []), false)
  assert.equal(isCurrentMeshOrchestration(undefined, []), true)
})
