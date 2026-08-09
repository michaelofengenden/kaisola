'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const { terminalReleaseRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')

test('terminal release wire route preserves incomplete deletion status and cleanup action', () => {
  const result = {
    id: 'release-delete-incomplete',
    ok: false,
    released: true,
    deletion: {
      complete: false,
      retryable: true,
      artifacts: [
        { name: 'current', status: 'failed', code: 'EACCES', attempts: 1 },
        { name: 'previous', status: 'absent', attempts: 1 },
        { name: 'metadata', status: 'deleted', attempts: 1 },
      ],
    },
    cleanup: { method: 'terminal.release', id: 'release-delete-incomplete' },
  }
  const calls = []
  const response = terminalReleaseRoute({
    manager: {
      release: (id) => {
        calls.push(['release', id])
        return result
      },
    },
    id: 'release-delete-incomplete',
    requireAllowed: (id) => calls.push(['authorize', id]),
  })

  assert.equal(response, result)
  assert.deepEqual(calls, [
    ['authorize', 'release-delete-incomplete'],
    ['release', 'release-delete-incomplete'],
  ])
})

test('terminal release wire route preserves verified deletion success', () => {
  const result = {
    id: 'release-delete-complete',
    ok: true,
    released: true,
    deletion: { complete: true, retryable: false, artifacts: [] },
    cleanup: null,
  }
  const response = terminalReleaseRoute({
    manager: { release: () => result },
    id: 'release-delete-complete',
    requireAllowed: () => {},
  })

  assert.equal(response, result)
})
