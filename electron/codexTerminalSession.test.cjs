const test = require('node:test')
const assert = require('node:assert/strict')

// terminalHandler pulls Electron for registration but these helpers are pure.
const { __test } = require('./ipc/terminalHandler.cjs')

test('extracts the exact Codex rollout id from a session path', () => {
  assert.equal(
    __test.codexIdFromPath('/tmp/.codex/sessions/2026/07/09/rollout-2026-07-09T12-00-00-019f4965-6294-77c0-abf8-ddae5bce85dc.jsonl'),
    '019f4965-6294-77c0-abf8-ddae5bce85dc',
  )
  assert.equal(__test.codexIdFromPath('/tmp/not-a-session.jsonl'), null)
})

test('reads escaped Codex session metadata without parsing a huge JSONL row', () => {
  const head = '{"type":"session_meta","payload":{"session_id":"019f4965-6294-77c0-abf8-ddae5bce85dc","cwd":"/tmp/a\\\\b","originator":"codex-tui"}}'
  assert.equal(__test.jsonStringField(head, 'session_id'), '019f4965-6294-77c0-abf8-ddae5bce85dc')
  assert.equal(__test.jsonStringField(head, 'cwd'), '/tmp/a\\b')
  assert.equal(__test.jsonStringField(head, 'originator'), 'codex-tui')
})
