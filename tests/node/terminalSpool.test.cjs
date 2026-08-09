'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {
  TerminalSpool,
  SPOOL_APPEND_DEBOUNCE_MS,
} = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

function fixture(t, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-'))
  const spool = new TerminalSpool({
    dir,
    id: options.id || 'terminal-spool-test',
    hotCap: options.hotCap || 1024,
    queueCap: options.queueCap || 1024 * 1024,
  })
  t.after(() => {
    spool.close()
    fs.rmSync(dir, { recursive: true, force: true })
  })
  return spool
}

test('visible output reaches the durable spool on the eager append debounce', async (t) => {
  const spool = fixture(t)
  spool.push('visible-before-restart')

  await new Promise((resolve) => setTimeout(resolve, SPOOL_APPEND_DEBOUNCE_MS + 350))

  assert.equal(fs.readFileSync(spool.file, 'utf8'), 'visible-before-restart')
})

test('evicting the durable hot tail never queues bytes a second time', (t) => {
  const spool = fixture(t, { hotCap: 4 })
  const chunks = ['alpha', '-', 'beta', '-', 'gamma']

  for (const chunk of chunks) spool.push(chunk)
  spool.flush()

  assert.equal(fs.readFileSync(spool.file, 'utf8'), chunks.join(''))
  assert.equal(spool.snapshot(1024).output, chunks.join(''))
})

test('late pty output after close({remove}) cannot resurrect the deleted spool file', async (t) => {
  const spool = fixture(t)
  spool.push('before-close')
  spool.close({ remove: true })
  assert.equal(fs.existsSync(spool.file), false)

  // The kernel can deliver buffered onData after release() already deleted
  // the spool; the debounced append must not recreate the file.
  spool.push('buffered-after-close')
  spool.flush()
  await new Promise((resolve) => setTimeout(resolve, SPOOL_APPEND_DEBOUNCE_MS + 350))
  assert.equal(fs.existsSync(spool.file), false)
})

test('exit evidence and the epoch boundary survive a fresh meta read', (t) => {
  const id = 'terminal-spool-exit-evidence'
  const spool = fixture(t, { id })
  spool.push('completed output')
  spool.markExited({ exitCode: 0, signal: null })

  const meta = TerminalSpool.readMeta(id, path.dirname(spool.file))
  assert.ok(Number.isSafeInteger(meta.exitedAt))
  assert.deepEqual(meta.exitStatus, { exitCode: 0, signal: null })
  assert.equal(meta.epochStartOffset, 0)
  assert.deepEqual(spool.exitEvidence(), {
    exitedAt: meta.exitedAt,
    exitStatus: { exitCode: 0, signal: null },
  })
})

function spoolRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-spool-root-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return root
}

function unsafeDir(dir) {
  return assert.throws(
    () => new TerminalSpool({ dir, id: 'terminal-spool-hostile-path' }),
    (error) => error.code === 'ERR_KAISOLA_UNSAFE_SPOOL_DIR',
  )
}

test('a spool directory pre-created as a symlink is refused before anything is written', (t) => {
  const root = spoolRoot(t)
  const redirect = path.join(root, 'redirect')
  const planted = path.join(root, 'spool')
  fs.mkdirSync(redirect, { mode: 0o700 })
  fs.symlinkSync(redirect, planted)

  unsafeDir(planted)
  assert.deepEqual(fs.readdirSync(redirect), [])
})

test('a spool directory owned by another user is refused', (t) => {
  if (process.getuid() === 0) return t.skip('root owns every path')
  // `/` exists on every machine, belongs to root, and nothing is written to it
  // because the ownership check runs before the first mkdir.
  unsafeDir(path.parse(process.cwd()).root)
})

test('a group- or world-writable spool directory is refused', (t) => {
  const root = spoolRoot(t)
  const permissive = path.join(root, 'spool')
  fs.mkdirSync(permissive, { mode: 0o700 })
  fs.chmodSync(permissive, 0o777)

  unsafeDir(permissive)
  assert.deepEqual(fs.readdirSync(permissive), [])
})

test('a spool directory under a world-writable parent is refused', (t) => {
  const root = spoolRoot(t)
  const parent = path.join(root, 'shared')
  fs.mkdirSync(parent, { mode: 0o700 })
  fs.chmodSync(parent, 0o777)

  unsafeDir(path.join(parent, 'spool'))
  assert.deepEqual(fs.readdirSync(parent), [])
})

test('a sticky world-writable parent still hosts a private spool directory', (t) => {
  const root = spoolRoot(t)
  const parent = path.join(root, 'sticky')
  fs.mkdirSync(parent, { mode: 0o700 })
  fs.chmodSync(parent, 0o1777) // /tmp

  const dir = path.join(parent, 'spool')
  const spool = new TerminalSpool({ dir, id: 'terminal-spool-sticky-parent' })
  t.after(() => spool.close())
  spool.push('sticky-parent')
  spool.flush()

  assert.equal(fs.readFileSync(spool.file, 'utf8'), 'sticky-parent')
  assert.equal(fs.lstatSync(dir).mode & 0o7777, 0o700)
})

test('an owned symlink above the spool directory is followed', (t) => {
  const root = spoolRoot(t)
  const real = path.join(root, 'real')
  fs.mkdirSync(real, { mode: 0o700 })
  fs.symlinkSync(real, path.join(root, 'link')) // /var -> private/var

  const spool = new TerminalSpool({ dir: path.join(root, 'link', 'spool'), id: 'terminal-spool-linked-parent' })
  t.after(() => spool.close())
  spool.push('linked-parent')
  spool.flush()

  assert.equal(fs.readFileSync(path.join(real, 'spool', path.basename(spool.file)), 'utf8'), 'linked-parent')
})

test('a spool directory left readable by an earlier build is tightened, not refused', (t) => {
  const root = spoolRoot(t)
  const legacy = path.join(root, 'spool')
  fs.mkdirSync(legacy, { mode: 0o700 })
  fs.chmodSync(legacy, 0o755)

  const spool = new TerminalSpool({ dir: legacy, id: 'terminal-spool-legacy-mode' })
  t.after(() => spool.close())

  assert.equal(fs.lstatSync(legacy).mode & 0o7777, 0o700)
})

test('a spool without a natural-exit stamp has no exit evidence', (t) => {
  const id = 'terminal-spool-no-exit-evidence'
  const spool = fixture(t, { id })
  spool.persistMeta()

  const meta = TerminalSpool.readMeta(id, path.dirname(spool.file))
  assert.equal(meta.exitedAt, undefined)
  assert.equal(meta.exitStatus, undefined)
  assert.equal(meta.epochStartOffset, 0)
  assert.equal(spool.exitEvidence(), null)
})
