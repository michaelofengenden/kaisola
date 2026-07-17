'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { registerCompanionProjectionHandlers } = require('./projectionHandler.cjs')

function harness(windowOverrides = {}) {
  let listener
  const ipcMain = { on: (channel, callback) => { assert.equal(channel, 'companion:publish-projection'); listener = callback } }
  const win = {
    isDestroyed: () => false,
    __kaisolaPop: false,
    __kaisolaDeleteBoot: false,
    __kaisolaDeleting: false,
    __kaisolaSavedId: 'saved-primary',
    __kaisolaCompanionGeneration: 7,
    ...windowOverrides,
  }
  const calls = []
  const published = []
  const store = {
    publish: (input) => {
      calls.push(input)
      return { ok: true, revision: 3, projection: { revision: 3 } }
    },
  }
  registerCompanionProjectionHandlers(ipcMain, {
    BrowserWindow: { fromWebContents: () => win },
    store,
    onPublished: (...args) => published.push(args),
  })
  const event = { sender: {}, returnValue: null }
  return { event, invoke: (projection = { revision: 3 }) => listener(event, projection), calls, published }
}

test('handler derives window identity and publisher generation in main', () => {
  const h = harness()
  h.invoke({ revision: 3 })
  assert.deepEqual(h.calls, [{ windowId: 'saved-primary', publisherGeneration: 7, projection: { revision: 3 } }])
  assert.equal(h.event.returnValue.ok, true)
  assert.equal(h.published.length, 1)
})

test('pop-outs, deletion boots, and unidentified windows cannot publish', () => {
  for (const overrides of [
    { __kaisolaPop: true },
    { __kaisolaDeleteBoot: true },
    { __kaisolaDeleting: true },
    { __kaisolaSavedId: null },
    { __kaisolaCompanionGeneration: null },
  ]) {
    const h = harness(overrides)
    h.invoke()
    assert.equal(h.event.returnValue.ok, false)
    assert.equal(h.calls.length, 0)
  }
})

