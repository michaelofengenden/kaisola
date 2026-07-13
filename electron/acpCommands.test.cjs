const assert = require('node:assert/strict')
const { authUrlFromNotice, authUrlFromUpdate, sanitizedCommands } = require('./ipc/acpHandler.cjs')

const commands = sanitizedCommands([
  { name: '/review', description: ' Review changes ', input: { hint: 'optional instructions' } },
  { name: '$deep-research', description: 'Workspace skill' },
  { name: 'bad command', description: 'must be dropped' },
  null,
])

assert.deepEqual(commands, [
  { name: 'review', description: 'Review changes', inputHint: 'optional instructions' },
  { name: '$deep-research', description: 'Workspace skill', inputHint: undefined },
])

const now = Date.now()
assert.equal(authUrlFromNotice({ kind: 'stderr', text: 'Read docs at https://example.com/reference' }, now, now), null)
assert.equal(authUrlFromNotice({ kind: 'auth', text: 'Continue at https://accounts.example.com/oauth' }, null, now), 'https://accounts.example.com/oauth')
assert.equal(authUrlFromNotice({ kind: 'stderr', text: 'Sign in at https://accounts.example.com/login' }, now, now), 'https://accounts.example.com/login')
assert.equal(authUrlFromNotice({ kind: 'stderr', text: 'Sign in at https://accounts.example.com/login' }, now - 181_000, now), null)
assert.equal(authUrlFromUpdate({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Sign in at https://accounts.example.com/session' } }, now, now), 'https://accounts.example.com/session')
assert.equal(authUrlFromUpdate({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Docs: https://example.com/reference' } }, now, now), null)
assert.equal(authUrlFromUpdate({ sessionUpdate: 'tool_call', content: { text: 'Sign in at https://accounts.example.com/tool' } }, now - 181_000, now), null)

process.stdout.write('ACP_COMMANDS_AUTH=PASS\n')
