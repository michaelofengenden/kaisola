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

  const claude = terminalsAfterMeta(base, 'one', { fgProcess: 'claude' })
  assert.equal(claude[0].singletonKey, 'agent:claude-cli-one')
  assert.equal(terminalsAfterMeta(claude, 'one', { fgProcess: 'git' })[0].singletonKey, 'agent:claude-cli-one')
  assert.equal(terminalsAfterMeta(claude, 'one', { fgProcess: 'zsh' })[0].singletonKey, undefined)

  const openCode = terminalsAfterMeta(base, 'one', { fgProcess: '/Users/example/.opencode/bin/opencode' })
  assert.equal(openCode[0].name, 'OpenCode')
  assert.equal(openCode[0].singletonKey, 'agent:opencode::cli:one')
  assert.equal(openCode[0].boot, 'opencode --continue --mini --replay-limit 60')

  const kimi = terminalsAfterMeta(base, 'one', { fgProcess: 'kimi' })
  assert.equal(kimi[0].name, 'Kimi')
  assert.equal(kimi[0].boot, 'kimi --continue')
})
