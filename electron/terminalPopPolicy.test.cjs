const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

test('terminal pop-out permits user terminals but fails closed for ACP terminals', async () => {
  const { canPopOutTerminal } = await import('../src/lib/terminalPopPolicy.ts')
  const state = {
    terminals: [{ id: 'user-active' }],
    agentTerminals: [{ terminalId: 'acp-active' }],
    projectSlices: {
      parked: {
        terminals: [{ id: 'user-parked' }],
        agentTerminals: [{ terminalId: 'acp-parked' }],
      },
    },
  }

  assert.equal(canPopOutTerminal(state, 'user-active'), true)
  assert.equal(canPopOutTerminal(state, 'user-parked'), true)
  assert.equal(canPopOutTerminal(state, 'acp-active'), false)
  assert.equal(canPopOutTerminal(state, 'acp-parked'), false)
  assert.equal(canPopOutTerminal(state, 'unknown-terminal'), false)
})

test('pop-out crosses the durable store barrier before the new renderer opens', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'store', 'store.ts'), 'utf8')
  const start = source.lastIndexOf('popOutTerminal: (id')
  const end = source.indexOf('syncPoppedTerminals:', start)
  const body = source.slice(start, end)
  const removeAt = body.indexOf('state.removeDockView(id)')
  const flushAt = body.indexOf('flushPersistSync()')
  const openAt = body.indexOf('bridge.windows?.pop?.(')
  assert.ok(removeAt >= 0 && removeAt < flushAt && flushAt < openAt)
})

test('closed pop replay applies state before restore and exact ACK', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'App.tsx'), 'utf8')
  const start = source.indexOf('const acceptClosedPop =')
  const end = source.indexOf('const off = bridge.windows?.onPopClosed', start)
  const body = source.slice(start, end)
  const ownerGuard = body.indexOf('owner !== closed.projectId')
  const applyAt = body.indexOf('applyTerminalMirror(closed)')
  const restoreAt = body.indexOf('restorePoppedTerminal(closed.termId)')
  const ackAt = body.indexOf('ackPopClosed?.(closed.termId, closed.projectId, closed.revision)')

  assert.ok(ownerGuard >= 0 && ownerGuard < applyAt)
  assert.ok(applyAt < restoreAt && restoreAt < ackAt)
})

test('main retains closed pop state and closes pop windows only when their project is removed', () => {
  const source = fs.readFileSync(path.join(__dirname, 'main.cjs'), 'utf8')
  assert.match(source, /createPopMirrorCache\(\{ retentionMs: 10 \* 60_000, maxClosed: 128 \}\)/)
  assert.match(source, /const record = popTerminalMirrors\.close\(termId, projectId\)/)
  assert.match(source, /ipcMain\.handle\('window:pop-closed-ack'/)
  assert.match(source, /closeUnownedProjectPops\(tab\.id\)/)
  assert.match(source, /pop\.__kaisolaDiscardOnClose = true/)
})
