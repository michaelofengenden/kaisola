const test = require('node:test')
const assert = require('node:assert/strict')

test('terminal metadata promotes CLI agents and clears only transient manual sessions', async () => {
  const { terminalsAfterMeta } = await import('../src/lib/terminalMetaPolicy.ts')
  const base = [{ id: 'one', cwd: '/repo' }, { id: 'login', boot: 'claude /login' }]
  const codex = terminalsAfterMeta(base, 'one', { fgProcess: 'codex' })
  assert.deepEqual(codex[0], {
    id: 'one',
    cwd: '/repo',
    singletonKey: 'agent:codex-cli-one',
    restart: true,
    boot: 'codex resume --last',
    name: 'Codex',
  })
  const shell = terminalsAfterMeta(codex, 'one', { fgProcess: 'zsh' })
  assert.equal(shell[0].singletonKey, undefined)
  assert.equal(shell[0].restart, undefined)
  assert.equal(shell[0].boot, undefined)
  assert.equal(terminalsAfterMeta(base, 'login', { fgProcess: 'claude' }), base)
  assert.equal(terminalsAfterMeta(base, 'one', { running: true }), base)
})
