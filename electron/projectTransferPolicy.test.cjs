const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

test('project transfer globals exclude unrelated window drafts and buffers', async () => {
  const { scopeProjectTransferGlobals } = await import('../src/lib/projectTransferPolicy.ts')
  const scoped = scopeProjectTransferGlobals({
    theme: 'dark',
    termDrafts: { moved: 'keep', unrelated: 'private' },
    unsavedBuffers: { '/moved/a.md': 'keep', '/other/b.md': 'private' },
    claudeSessions: { '/moved': 'session-a', '/other': 'session-b' },
    latexMain: { '/moved': '/moved/main.tex', '/other': '/other/main.tex' },
  }, '/moved', ['moved'])
  assert.equal(scoped.theme, 'dark')
  assert.deepEqual(scoped.termDrafts, { moved: 'keep' })
  assert.deepEqual(scoped.unsavedBuffers, { '/moved/a.md': 'keep' })
  assert.deepEqual(scoped.claudeSessions, { '/moved': 'session-a' })
  assert.deepEqual(scoped.latexMain, { '/moved': '/moved/main.tex' })
})

test('project adoption rejects conflicting unsent content but permits identical overlap', async () => {
  const { projectTransferDataConflict } = await import('../src/lib/projectTransferPolicy.ts')
  const current = { termDrafts: { term: 'newer' }, unsavedBuffers: { '/repo/a.md': 'same' } }
  assert.equal(projectTransferDataConflict(current, { termDrafts: { term: 'older' } }), true)
  assert.equal(projectTransferDataConflict(current, { unsavedBuffers: { '/repo/a.md': 'same' } }), false)
  assert.equal(projectTransferDataConflict(current, { termDrafts: { other: 'safe' } }), false)
})

test('cross-renderer project moves journal both durable commits around ownership handoff', () => {
  const source = fs.readFileSync(path.join(__dirname, 'main.cjs'), 'utf8')
  const start = source.indexOf("ipcMain.handle('window:detach-project'")
  const end = source.indexOf("ipcMain.handle('window:finish-transfer'", start)
  const body = source.slice(start, end)
  const physicalMove = body.indexOf("payload.sourceTabCount === 1")
  const sameReturn = body.indexOf("return { ok: true, target: 'same' }", physicalMove)
  const targetFlush = body.indexOf('requestAdoptionPreparation(', sameReturn)
  const journalPrepare = body.indexOf('prepareProjectTransfer({', targetFlush)
  const acpHandoff = body.indexOf('transferAcpProject(', journalPrepare)
  const targetCommit = body.indexOf('markProjectTransferCommitted(', acpHandoff)
  const sourceFinish = body.indexOf('completedTransfers.set(', targetCommit)

  assert.doesNotMatch(source, /CROSS_RENDERER_PROJECT_TRANSFERS_ENABLED/)
  assert.ok(physicalMove >= 0 && physicalMove < sameReturn)
  assert.ok(sameReturn < targetFlush)
  assert.ok(targetFlush < journalPrepare)
  assert.ok(journalPrepare < acpHandoff)
  assert.ok(acpHandoff < targetCommit)
  assert.ok(targetCommit < sourceFinish)
  assert.ok(source.lastIndexOf('recoverProjectTransfers({') < source.lastIndexOf('restoreSavedWindowsOnLaunch()'))
})
