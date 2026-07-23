'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')

const {
  newCrashReports,
  parseArguments,
} = require('../scripts/native-launch-smoke.cjs')

test('native launch smoke parses an app and bounded observation window', () => {
  const options = parseArguments(['--app', '/tmp/Kaisola.app', '--seconds', '12'])
  assert.equal(options.app, '/tmp/Kaisola.app')
  assert.equal(options.seconds, 12)
  assert.throws(() => parseArguments(['--seconds', '2']), /3 through 60/)
  assert.throws(() => parseArguments(['--wat']), /unknown argument/)
})

test('native launch smoke ignores old reports and returns only new post-launch crashes', () => {
  const before = [
    { path: '/reports/old.ips', mtimeMs: 100 },
  ]
  const after = [
    { path: '/reports/old.ips', mtimeMs: 500 },
    { path: '/reports/stale-unseen.ips', mtimeMs: 200 },
    { path: '/reports/new.ips', mtimeMs: 2_100 },
  ]
  assert.deepEqual(
    newCrashReports({ before, after, startedAt: 2_000 }).map((entry) => entry.path),
    ['/reports/new.ips']
  )
})
