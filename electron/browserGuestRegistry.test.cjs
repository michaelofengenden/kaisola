const test = require('node:test')
const assert = require('node:assert/strict')
const { BrowserGuestRegistry } = require('./ipc/browserGuestRegistry.cjs')

const guest = (id) => {
  let destroyed
  return {
    id,
    closed: 0,
    stopped: 0,
    once(event, cb) { if (event === 'destroyed') destroyed = cb },
    isDestroyed() { return false },
    stop() { this.stopped++ },
    close() { this.closed++; destroyed?.() },
  }
}

test('embedded browser release is owner-scoped and closes the guest once', () => {
  const registry = new BrowserGuestRegistry()
  const owner = { id: 1 }
  const stranger = { id: 1 }
  const view = guest(41)
  assert.equal(registry.attach(owner, view), true)
  assert.equal(registry.release(stranger, 41), false)
  assert.equal(view.closed, 0)
  assert.equal(registry.release(owner, 41), true)
  assert.equal(view.stopped, 1)
  assert.equal(view.closed, 1)
  assert.equal(registry.count(), 0)
  assert.equal(registry.release(owner, 41), false)
})

test('renderer teardown releases every browser guest it owns', () => {
  const registry = new BrowserGuestRegistry()
  const owner = { id: 2 }
  const other = { id: 3 }
  const first = guest(50)
  const second = guest(51)
  const retained = guest(52)
  registry.attach(owner, first)
  registry.attach(owner, second)
  registry.attach(other, retained)
  assert.equal(registry.releaseOwner(owner), 2)
  assert.equal(registry.count(owner), 0)
  assert.equal(registry.count(other), 1)
  assert.equal(retained.closed, 0)
})
