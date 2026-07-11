'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { __test } = require('./index.js')

test('server accepts one bounded Bearer token and rejects malformed headers', () => {
  assert.equal(__test.bearerToken('Bearer abc.def.ghi'), 'abc.def.ghi')
  assert.equal(__test.bearerToken('Basic abc'), null)
  assert.equal(__test.bearerToken('Bearer one two'), null)
  assert.equal(__test.bearerToken(`Bearer ${'x'.repeat(20_001)}`), null)
})
