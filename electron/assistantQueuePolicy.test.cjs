const test = require('node:test')
const assert = require('node:assert/strict')

test('queue cap rejects new input but preserves one already-accepted recovery', async () => {
  const { addQueuedPrompt, MAX_USER_QUEUED_PROMPTS, MAX_PERSISTED_QUEUED_PROMPTS } = await import('../src/lib/assistantQueuePolicy.ts')
  const full = Array.from({ length: MAX_USER_QUEUED_PROMPTS }, (_, index) => `prompt-${index}`)

  assert.equal(addQueuedPrompt(full, 'new-user-prompt'), null)
  const recovered = addQueuedPrompt(full, 'accepted-before-failure', { front: true, preserveAccepted: true })
  assert.equal(recovered.length, MAX_PERSISTED_QUEUED_PROMPTS)
  assert.equal(recovered[0], 'accepted-before-failure')
  assert.deepEqual(recovered.slice(1), full)
  assert.equal(addQueuedPrompt(recovered, 'another-recovery', { preserveAccepted: true }), null)
})
