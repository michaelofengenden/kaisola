const test = require('node:test')
const assert = require('node:assert/strict')
const { _modelTest } = require('./ipc/modelHandler.cjs')

test('saved OpenAI credentials are bound to the exact official API endpoint', () => {
  assert.deepEqual(_modelTest.openAIEndpoint({ useStoredKey: true, baseUrl: 'https://api.openai.com/v1/' }), {
    ok: true,
    baseUrl: 'https://api.openai.com/v1',
  })
  for (const baseUrl of [
    'https://evil.example/v1',
    'http://api.openai.com/v1',
    'https://api.openai.com.evil.example/v1',
    'https://api.openai.com/v1/other',
  ]) {
    assert.equal(_modelTest.openAIEndpoint({ useStoredKey: true, baseUrl }).ok, false, baseUrl)
  }
})

test('custom model endpoints require explicit safe http(s) URLs', () => {
  assert.equal(_modelTest.openAIEndpoint({ baseUrl: 'http://localhost:11434/v1' }).ok, true)
  assert.equal(_modelTest.openAIEndpoint({ baseUrl: 'httpx://localhost/v1' }).ok, false)
  assert.equal(_modelTest.openAIEndpoint({ baseUrl: 'https://user:secret@example.com/v1' }).ok, false)
})
