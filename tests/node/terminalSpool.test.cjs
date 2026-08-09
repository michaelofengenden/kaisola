'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const {
  TerminalSpool,
  SPOOL_APPEND_DEBOUNCE_MS,
  READ_ABSENT,
  READ_EMPTY,
  READ_FAILED,
  META_RETRY_BASE_MS,
  readTail,
  readRange,
} = require('../../runtime/node-broker/ipc/terminalSpool.cjs')

/** Replace a spool segment with a non-regular path that every descriptor read
 * refuses. This reproduces a transient permission or media
 * failure without chmod, so the test behaves the same for a root runner. */
function breakSegmentReads(file) {
  fs.rmSync(file, { force: true })
  fs.mkdirSync(file)
}

// Three UTF-8 bytes each, so a cap of 10 lands inside a scalar and the tail has
// to move forward to the next character boundary.
const SNOWMAN = '☃'

function fixture(t, options = {}) {
  const dir = options.dir || fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-'))
  const spool = new TerminalSpool({
    dir,
    id: 'terminal-spool-test',
    hotCap: 1024,
    queueCap: 1024 * 1024,
    ...options,
  })
  t.after(() => {
    spool.close()
    if (!options.dir) fs.rmSync(dir, { recursive: true, force: true })
  })
  return spool
}

/** atomicJson stages the meta through `${metaFile}.${pid}.tmp`; a directory
 * parked on that path makes every write fail with EISDIR until it is removed,
 * which is the closest thing to a disk-full window a test can hold open. */
function blockMetaWrites(spool) {
  const tmp = `${spool.metaFile}.${process.pid}.tmp`
  fs.mkdirSync(tmp, { recursive: true })
  return () => fs.rmSync(tmp, { recursive: true, force: true })
}

/** A file outside the spool that a local attacker would want the broker to
 * read from or write to. Its mode is asserted alongside its bytes because the
 * old append path chmod-ed its destination to 0600 by path. */
function bystander(t, contents) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-spool-bystander-'))
  const file = path.join(dir, 'private.txt')
  fs.writeFileSync(file, contents)
  fs.chmodSync(file, 0o644)
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return file
}

/** Push `bytes` of interactive output through the same eager-append path the
 * pty uses, flushing each chunk so the quota sees a realistic segment size. */
function pushBytes(spool, bytes, chunkSize = 1024) {
  for (let written = 0; written < bytes; written += chunkSize) {
    spool.push('x'.repeat(Math.min(chunkSize, bytes - written)))
    spool.flush()
  }
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

test('a lone oversized chunk is trimmed to the hot cap on a character boundary', (t) => {
  const spool = fixture(t, { hotCap: 10 })

  spool.push(SNOWMAN.repeat(8)) // 24 bytes in a single write
  spool.flush()

  const retained = spool.chunks.join('')
  assert.equal(retained, SNOWMAN.repeat(3)) // 9 bytes: the 10th would split a scalar
  assert.equal(spool.stats().ramBytes, 9)
  assert.ok(!retained.includes('\uFFFD'))
  assert.equal(fs.readFileSync(spool.file, 'utf8'), SNOWMAN.repeat(8)) // durable copy is whole
})

test('a lone oversized chunk is trimmed in the disk-failure fallback too', (t) => {
  const spool = fixture(t, { hotCap: 10 })
  // A directory where the log belongs makes every append fail, which is the
  // path that retains a hot tail in RAM instead of on disk.
  fs.mkdirSync(spool.file)
  spool.setVisible(false) // isolate the fallback from the visible read cache

  spool.push(SNOWMAN.repeat(8))
  spool.flush()

  const retained = spool.fallbackChunks.join('')
  assert.ok(spool.diskError)
  assert.equal(retained, SNOWMAN.repeat(3))
  assert.equal(spool.fallbackLen, 9)
  assert.ok(!retained.includes('\uFFFD'))
})

test('a hot cap smaller than the trailing scalar retains nothing', (t) => {
  const spool = fixture(t, { hotCap: 1 })

  spool.push(SNOWMAN)
  spool.flush()

  assert.deepEqual(spool.chunks, [])
  assert.equal(spool.stats().ramBytes, 0)
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

test('close({remove}) reports every artifact and retries transient unlink failures', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-delete-retry' })
  spool.push('previous secret')
  spool.flush()
  fs.renameSync(spool.file, spool.prevFile)
  fs.writeFileSync(spool.file, 'current secret', { mode: 0o600 })
  spool.markExited({ exitCode: 0, signal: null })

  const targets = new Set([spool.file, spool.prevFile, spool.metaFile])
  const attempts = new Map()
  const unlinkSync = fs.unlinkSync
  fs.unlinkSync = (file) => {
    if (targets.has(file)) {
      const attempt = (attempts.get(file) || 0) + 1
      attempts.set(file, attempt)
      if (attempt === 1) {
        const error = new Error('injected transient deletion failure')
        error.code = 'EBUSY'
        throw error
      }
    }
    return unlinkSync(file)
  }

  let deletion
  try {
    deletion = spool.close({ remove: true })
  } finally {
    fs.unlinkSync = unlinkSync
  }

  assert.deepEqual(deletion, {
    complete: true,
    retryable: false,
    artifacts: [
      { name: 'current', status: 'deleted', attempts: 2 },
      { name: 'previous', status: 'deleted', attempts: 2 },
      { name: 'metadata', status: 'deleted', attempts: 2 },
    ],
  })
  for (const file of targets) assert.equal(fs.existsSync(file), false)
})

test('failed deletion is explicit and a closed spool can retry without resurrection', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-delete-cleanup' })
  spool.push('sensitive terminal bytes')
  spool.flush()
  const unlinkSync = fs.unlinkSync
  fs.unlinkSync = (file) => {
    if (file === spool.file) {
      const error = new Error('injected persistent deletion failure')
      error.code = 'EACCES'
      throw error
    }
    return unlinkSync(file)
  }

  let first
  try {
    first = spool.close({ remove: true })
  } finally {
    fs.unlinkSync = unlinkSync
  }

  assert.equal(first.complete, false)
  assert.equal(first.retryable, true)
  assert.deepEqual(first.artifacts, [
    { name: 'current', status: 'failed', code: 'EACCES', attempts: 1 },
    { name: 'previous', status: 'absent', attempts: 1 },
    { name: 'metadata', status: 'deleted', attempts: 1 },
  ])
  assert.equal(fs.readFileSync(spool.file, 'utf8'), 'sensitive terminal bytes')
  assert.equal(JSON.stringify(first).includes(path.dirname(spool.file)), false)

  const retry = spool.close({ remove: true })
  assert.equal(retry.complete, true)
  assert.deepEqual(retry.artifacts.map(({ name, status }) => ({ name, status })), [
    { name: 'current', status: 'deleted' },
    { name: 'previous', status: 'absent' },
    { name: 'metadata', status: 'absent' },
  ])
  spool.push('late bytes after cleanup')
  spool.flush()
  assert.equal(fs.existsSync(spool.file), false)
})

test('standalone cleanup refuses an unsafe spool root without following it', (t) => {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-cleanup-root-'))
  const bystanderDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-cleanup-bystander-'))
  const spoolRoot = path.join(parent, 'spool')
  const sentinel = path.join(bystanderDir, 'private.txt')
  fs.writeFileSync(sentinel, 'must survive cleanup')
  fs.symlinkSync(bystanderDir, spoolRoot)
  t.after(() => {
    fs.rmSync(parent, { recursive: true, force: true })
    fs.rmSync(bystanderDir, { recursive: true, force: true })
  })

  const deletion = TerminalSpool.cleanup('unsafe-cleanup', spoolRoot)
  assert.equal(deletion.complete, false)
  assert.equal(deletion.retryable, true)
  assert.deepEqual(deletion.artifacts, [
    { name: 'current', status: 'failed', code: 'ERR_KAISOLA_UNSAFE_SPOOL_DIR', attempts: 0 },
    { name: 'previous', status: 'failed', code: 'ERR_KAISOLA_UNSAFE_SPOOL_DIR', attempts: 0 },
    { name: 'metadata', status: 'failed', code: 'ERR_KAISOLA_UNSAFE_SPOOL_DIR', attempts: 0 },
  ])
  assert.equal(fs.readFileSync(sentinel, 'utf8'), 'must survive cleanup')
  assert.equal(fs.lstatSync(spoolRoot).isSymbolicLink(), true)
  assert.equal(JSON.stringify(deletion).includes(parent), false)
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

test('a failed meta write stays dirty, reports the error, and retries onto disk', async (t) => {
  const id = 'terminal-spool-meta-retry'
  const spool = fixture(t, { id })
  spool.push('output before the disk went away')
  spool.flush()

  const unblock = blockMetaWrites(spool)
  spool.markExited({ exitCode: 3, signal: null })

  assert.equal(TerminalSpool.readMeta(id, path.dirname(spool.metaFile)), null)
  assert.equal(spool.metaDirty, true)
  assert.equal(spool.stats().metaDirty, true)
  assert.equal(spool.stats().metaError, 'EISDIR')

  unblock()
  await new Promise((resolve) => setTimeout(resolve, META_RETRY_BASE_MS + 400))

  const meta = TerminalSpool.readMeta(id, path.dirname(spool.metaFile))
  assert.ok(meta, 'the bounded retry must land the metadata once the disk recovers')
  assert.deepEqual(meta.exitStatus, { exitCode: 3, signal: null })
  assert.equal(spool.metaDirty, false)
  assert.equal(spool.stats().metaError, null)
})

test('a terminal restarted after an injected meta write failure resurrects its state', async (t) => {
  const id = 'terminal-spool-meta-retry-restart'
  const spool = fixture(t, { id })
  const dir = path.dirname(spool.metaFile)
  spool.push('\x1b[?2004h\x1b[?1000h') // bracketed paste + mouse reporting
  spool.setVisible(false, { scrollTop: 42 })

  const unblock = blockMetaWrites(spool)
  spool.markExited({ exitCode: 0, signal: null })
  assert.equal(spool.metaDirty, true)

  unblock()
  await new Promise((resolve) => setTimeout(resolve, META_RETRY_BASE_MS + 400))

  // Restart: a fresh spool over the same directory is what resurrection reads.
  const restarted = new TerminalSpool({ dir, id })
  t.after(() => restarted.close())
  assert.deepEqual(restarted.exitEvidence(), {
    exitedAt: spool.exitedAt,
    exitStatus: { exitCode: 0, signal: null },
  })
  assert.deepEqual(restarted.viewState, { scrollTop: 42 })
  assert.equal(restarted._modePrefix(), '\x1b[?1000h\x1b[?2004h')
})

test('close({remove}) cancels a pending meta retry instead of recreating the file', async (t) => {
  const id = 'terminal-spool-meta-retry-close'
  const spool = fixture(t, { id })
  const unblock = blockMetaWrites(spool)
  spool.markExited({ exitCode: 0, signal: null })
  assert.equal(spool.metaDirty, true)

  // The retry is still pending when the user wipes the session. Letting the
  // disk recover afterwards must not put the meta file back.
  spool.close({ remove: true })
  unblock()
  await new Promise((resolve) => setTimeout(resolve, META_RETRY_BASE_MS + 400))

  assert.equal(fs.existsSync(spool.metaFile), false)
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

test('a segment read separates absent, empty and failed instead of one empty string', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-read-status-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const absent = path.join(dir, 'never-written.log')
  const empty = path.join(dir, 'empty.log')
  const unreadable = path.join(dir, 'unreadable.log')
  fs.writeFileSync(empty, '', { mode: 0o600 })
  breakSegmentReads(unreadable)

  assert.deepEqual(readTail(absent, 64), { status: READ_ABSENT, text: '', error: null })
  assert.deepEqual(readTail(empty, 64), { status: READ_EMPTY, text: '', error: null })
  const failedTail = readTail(unreadable, 64)
  assert.equal(failedTail.status, READ_FAILED)
  assert.equal(failedTail.text, '')
  assert.equal(failedTail.error, 'ESPOOLNOTFILE')

  assert.equal(readRange(absent, 0, 64).status, READ_ABSENT)
  assert.equal(readRange(empty, 0, 64).status, READ_EMPTY)
  const failedRange = readRange(unreadable, 0, 64)
  assert.equal(failedRange.status, READ_FAILED)
  assert.equal(failedRange.buffer.length, 0)
  assert.equal(failedRange.error, 'ESPOOLNOTFILE')
})

test('a failed spool read is reported, not answered as an empty transcript', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-read-failure' })
  spool.push('retained-history')
  spool.flush()
  // Detaching drops the RAM read cache, so the disk spool is the only source
  // left — the state a reattach or a cold selection reads from.
  spool.setVisible(false)
  const healthy = spool.snapshot(1024)
  assert.equal(healthy.output, 'retained-history')
  assert.equal(healthy.readError, undefined)

  breakSegmentReads(spool.file)

  const snapshot = spool.snapshot(1024)
  assert.equal(snapshot.readError, 'ESPOOLNOTFILE')
  assert.equal(snapshot.output, '')
  assert.equal(snapshot.truncated, true)

  const page = spool.historyPage(0, 1024)
  assert.equal(page.readError, 'ESPOOLNOTFILE')
  assert.equal(page.output, '')
  assert.equal(page.truncated, true)
})

test('a terminal that produced nothing still reads as an authoritative empty spool', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-genuinely-empty' })
  spool.push('')
  spool.flush()
  fs.writeFileSync(spool.file, '', { mode: 0o600 })
  spool.setVisible(false)

  const snapshot = spool.snapshot(1024)
  assert.equal(snapshot.output, '')
  assert.equal(snapshot.truncated, false)
  assert.equal(snapshot.readError, undefined)
})

test('a failed read keeps the RAM tail the spool can still prove', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-read-failure-hot' })
  spool.push('retained-history')
  spool.flush()
  breakSegmentReads(spool.file)

  // The renderer is still attached, so the hot cache holds an exact suffix of
  // the stream. It is the most history the spool can honestly return.
  const snapshot = spool.snapshot(1024)
  assert.equal(snapshot.output, 'retained-history')
  assert.equal(snapshot.readError, 'ESPOOLNOTFILE')
  assert.equal(snapshot.truncated, true)
})

test('coldTail separates a terminal with no spool from one it cannot read', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-cold-read-'))
  const spool = new TerminalSpool({ dir, id: 'cold-read-failure' })
  t.after(() => {
    spool.close()
    fs.rmSync(dir, { recursive: true, force: true })
  })
  assert.equal(TerminalSpool.coldTail('cold-read-failure', dir, 1024), null)

  spool.push('cold-history')
  spool.flush()
  assert.deepEqual(TerminalSpool.coldTail('cold-read-failure', dir, 1024), {
    text: 'cold-history',
    truncated: false,
  })

  breakSegmentReads(spool.file)
  const cold = TerminalSpool.coldTail('cold-read-failure', dir, 1024)
  assert.equal(cold.readError, 'ESPOOLNOTFILE')
  assert.equal(cold.text, '')
  assert.equal(cold.truncated, true)
})

// Spool paths are a hash of the terminal id, so any local process can name
// them before the terminal exists. A link planted at one of them must never
// turn a spool read into "read that file" or a spool append into "overwrite
// that file" under broker authority.

test('a symlinked current segment is never read back as terminal output', (t) => {
  const id = 'terminal-spool-link-read'
  const spool = fixture(t, { id })
  const dir = path.dirname(spool.file)
  const bystanderFile = bystander(t, 'ANTHROPIC_API_KEY=sk-do-not-exfiltrate\n')
  fs.symlinkSync(bystanderFile, spool.file)

  assert.deepEqual(spool.snapshot(4096), {
    output: '',
    truncated: true,
    viewState: null,
    modePrefix: '',
    readError: 'ELOOP',
  })
  const page = spool.historyPage(0, 4096)
  assert.equal(page.output, '')
  assert.equal(page.totalBytes, 0)
  assert.equal(page.readError, 'ELOOP')
  assert.equal(spool.stats().diskBytes, 0)
  assert.equal(spool.retainedByteCount(), 0)
  assert.deepEqual(TerminalSpool.coldTail(id, dir), {
    text: '',
    truncated: true,
    readError: 'ELOOP',
  })
  assert.deepEqual(readTail(spool.file, 4096), { status: READ_FAILED, text: '', error: 'ELOOP' })
  assert.equal(readRange(spool.file, 0, 4096).status, READ_FAILED)
})

test('a symlinked current segment refuses the append instead of writing through it', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-link-append' })
  const bystanderFile = bystander(t, 'original-contents')
  fs.symlinkSync(bystanderFile, spool.file)

  spool.push('pty-output-that-must-not-land-there')
  spool.flush()

  assert.equal(fs.readFileSync(bystanderFile, 'utf8'), 'original-contents')
  assert.equal(fs.statSync(bystanderFile).mode & 0o777, 0o644)
  assert.equal(fs.lstatSync(spool.file).isSymbolicLink(), true)
  assert.ok(spool.stats().diskError, 'a refused segment must surface as a disk error')
  // The refusal must not cost the user their live terminal: the bytes that
  // could not land stay in the bounded hot fallback.
  assert.equal(spool.snapshot(4096).output, 'pty-output-that-must-not-land-there')
})

test('a fifo planted at the segment path is refused instead of parking the broker', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-fifo' })
  execFileSync('/usr/bin/mkfifo', [spool.file])

  assert.deepEqual(readTail(spool.file, 4096), {
    status: READ_FAILED,
    text: '',
    error: 'ESPOOLNOTFILE',
  })
  spool.push('output-with-nowhere-safe-to-go')
  spool.flush()

  assert.ok(spool.stats().diskError, 'a non-regular segment must surface as a disk error')
  assert.equal(fs.lstatSync(spool.file).isFIFO(), true)
})

test('a segment owned by another uid is refused for both reads and appends', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-foreign-owner' })
  spool.push('bytes-written-while-we-owned-the-segment')
  spool.flush()
  assert.ok(spool.stats().diskBytes > 0)

  // Creating a file owned by another user needs root, so stand the check on
  // its head: make this process look like a different uid to everything that
  // consults process.getuid.
  const realGetuid = process.getuid
  process.getuid = () => realGetuid.call(process) + 1
  t.after(() => { process.getuid = realGetuid })

  assert.equal(spool.stats().diskBytes, 0)
  const snapshot = spool.snapshot(4096)
  assert.equal(snapshot.output, 'bytes-written-while-we-owned-the-segment')
  assert.equal(snapshot.readError, 'ESPOOLNOTOWNED')
  assert.deepEqual(readTail(spool.file, 4096), {
    status: READ_FAILED,
    text: '',
    error: 'ESPOOLNOTOWNED',
  })
  spool.push('append-under-a-foreign-owner')
  spool.flush()
  assert.equal(spool.stats().diskError, 'ESPOOLNOTOWNED')
})

test('rotation retires a planted previous-segment link without crediting its bytes', (t) => {
  const spool = fixture(t, {
    id: 'terminal-spool-link-rotate',
    diskCap: 64,
    retentionCap: 4096,
  })
  spool.push('seed')
  spool.flush()
  assert.equal(spool.startEpoch(), 4)

  const bystanderFile = bystander(t, 'x'.repeat(1024))
  fs.symlinkSync(bystanderFile, spool.prevFile)
  spool.push('a'.repeat(64))
  spool.flush()

  // Rotation ran: the current segment became the previous one and the planted
  // link is gone. Its target keeps its bytes, and its size never moved the
  // epoch boundary that history offsets are measured from.
  assert.equal(fs.existsSync(spool.file), false)
  assert.equal(fs.lstatSync(spool.prevFile).isFile(), true)
  assert.equal(fs.readFileSync(spool.prevFile, 'utf8'), `seed${'a'.repeat(64)}`)
  assert.equal(fs.readFileSync(bystanderFile, 'utf8'), 'x'.repeat(1024))
  assert.equal(spool.epochStartOffset, 4)
  assert.equal(spool.truncated, false)
})

test('readMeta refuses a symlinked meta path instead of trusting its JSON', (t) => {
  const id = 'terminal-spool-link-meta-read'
  const spool = fixture(t, { id })
  const planted = bystander(t, JSON.stringify({
    v: 1,
    id,
    viewState: { rows: 1, cols: 1 },
    epochStartOffset: 999,
  }))
  fs.symlinkSync(planted, spool.metaFile)

  assert.equal(TerminalSpool.readMeta(id, path.dirname(spool.metaFile)), null)
})

test('persisting meta refuses a symlinked scratch path instead of writing through it', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-link-meta-write' })
  const bystanderFile = bystander(t, 'scratch-decoy')
  fs.symlinkSync(bystanderFile, `${spool.metaFile}.${process.pid}.tmp`)

  spool.persistMeta() // a cache failure is non-fatal and must stay non-fatal

  assert.equal(fs.readFileSync(bystanderFile, 'utf8'), 'scratch-decoy')
  assert.equal(fs.statSync(bystanderFile).mode & 0o777, 0o644)
})

test('close({remove}) drops planted entries and leaves what they pointed at alone', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-link-delete' })
  const logBystander = bystander(t, 'log-decoy')
  const prevBystander = bystander(t, 'prev-decoy')
  const metaBystander = bystander(t, 'meta-decoy')
  fs.symlinkSync(logBystander, spool.file)
  fs.symlinkSync(prevBystander, spool.prevFile)
  fs.symlinkSync(metaBystander, spool.metaFile)

  spool.close({ remove: true })

  for (const file of [spool.file, spool.prevFile, spool.metaFile]) {
    assert.equal(fs.existsSync(file), false)
    assert.throws(() => fs.lstatSync(file), { code: 'ENOENT' })
  }
  assert.equal(fs.readFileSync(logBystander, 'utf8'), 'log-decoy')
  assert.equal(fs.readFileSync(prevBystander, 'utf8'), 'prev-decoy')
  assert.equal(fs.readFileSync(metaBystander, 'utf8'), 'meta-decoy')
})

test('an interactive terminal stops at its history quota instead of growing without bound', (t) => {
  const quota = 8 * 1024
  const spool = fixture(t, { id: 'terminal-spool-history-quota', historyQuota: quota })

  pushBytes(spool, 64 * 1024)

  // Two bounded segments, each retired a little past quota/2, so the ceiling is
  // the quota plus at most one in-flight chunk per segment.
  assert.ok(
    spool.retainedByteCount() <= quota + 4 * 1024,
    `retained ${spool.retainedByteCount()} bytes for an ${quota}-byte quota`,
  )
  assert.equal(spool.truncated, true)
  assert.ok(spool.truncationEvidence().evictedBytes > 0)
})

test('an explicitly unbounded spool keeps the append-only contract', (t) => {
  const spool = fixture(t, { id: 'terminal-spool-unbounded', historyQuota: null })

  pushBytes(spool, 64 * 1024)

  assert.equal(spool.retainedByteCount(), 64 * 1024)
  assert.equal(spool.truncated, false)
  assert.equal(spool.truncationEvidence(), null)
})

test('the history quota warns before it evicts and keeps the provenance after', (t) => {
  const id = 'terminal-spool-quota-provenance'
  const events = []
  const quota = 8 * 1024
  const spool = fixture(t, { id, historyQuota: quota, onQuota: (event) => events.push(event) })

  pushBytes(spool, 64 * 1024)

  const firstWarning = events.findIndex((event) => event.phase === 'warning')
  const firstEviction = events.findIndex((event) => event.phase === 'evicted')
  assert.ok(firstWarning >= 0, 'no quota warning was emitted')
  assert.ok(firstEviction >= 0, 'no eviction was reported')
  assert.ok(firstWarning < firstEviction, 'the warning must precede the first eviction')
  assert.equal(events[firstWarning].scope, 'terminal')
  assert.equal(events[firstWarning].quotaBytes, quota)
  assert.ok(events[firstEviction].evictedBytes > 0)

  const evidence = spool.truncationEvidence()
  assert.equal(evidence.reason, 'terminal-quota')
  assert.ok(evidence.evictions > 0)
  assert.ok(Number.isSafeInteger(evidence.firstAt))
  assert.deepEqual(spool.snapshot(1024).truncation, evidence)
  assert.deepEqual(spool.historyPage(0, 1024).truncation, evidence)

  // Provenance is durable: a terminal reopened after a broker restart still
  // reports the history its quota dropped.
  const meta = TerminalSpool.readMeta(id, path.dirname(spool.file))
  assert.deepEqual(meta.truncation, evidence)
  const reopened = new TerminalSpool({ dir: path.dirname(spool.file), id, historyQuota: quota })
  t.after(() => reopened.close())
  assert.equal(reopened.truncated, true)
  assert.deepEqual(reopened.truncationEvidence(), evidence)
})

test('a capture terminal keeps its retentionCap rotation and stays off the quota warning', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-capture-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const events = []
  const spool = new TerminalSpool({
    dir,
    id: 'terminal-spool-capture',
    diskCap: 4 * 1024,
    retentionCap: 4 * 1024,
    historyQuota: 64 * 1024,
    onQuota: (event) => events.push(event),
  })
  t.after(() => spool.close())

  pushBytes(spool, 32 * 1024)

  // The explicit cap still wins over the far larger interactive quota…
  assert.ok(spool.retainedByteCount() <= 8 * 1024, `retained ${spool.retainedByteCount()} bytes`)
  assert.equal(spool.truncated, true)
  assert.equal(spool.truncationEvidence().reason, 'retention-cap')
  // …and rotating inside a cap the caller asked for is not a quota event.
  assert.deepEqual(events, [])
})

test('a quota rotation after restore keeps the epoch boundary on the same byte', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-epoch-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const id = 'terminal-spool-epoch-under-quota'
  const quota = 8 * 1024

  const before = new TerminalSpool({ dir, id, historyQuota: quota })
  pushBytes(before, 2 * 1024)
  before.close()

  const restored = new TerminalSpool({ dir, id, historyQuota: quota })
  t.after(() => restored.close())
  restored.startEpoch()
  assert.equal(restored.epochStartOffset, 2 * 1024)
  assert.equal(restored.snapshot(4 * 1024).output, '', 'a restored terminal replays no pre-restart bytes')

  // Rotating without evicting anything leaves the boundary exactly where it was.
  restored.push('N'.repeat(3 * 1024))
  restored.flush()
  assert.equal(restored.epochStartOffset, 2 * 1024)
  assert.equal(restored.snapshot(8 * 1024).output, 'N'.repeat(3 * 1024))

  // The rotation that does evict retires the last pre-restart bytes with it, so
  // the boundary walks back by exactly what stopped being retained rather than
  // pointing into the middle of this session's output.
  restored.push('M'.repeat(5 * 1024))
  restored.flush()
  assert.equal(restored.epochStartOffset, 0)
  assert.equal(restored.snapshot(16 * 1024).output, 'M'.repeat(5 * 1024))
})

test('the directory quota reclaims segments a closed terminal left behind', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-total-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const totalHistoryQuota = 20 * 1024

  // Seed the retained segments directly: this pins the directory sweep on its
  // own, independent of whether the per-terminal quota happened to rotate.
  const closed = new TerminalSpool({ dir, id: 'closed-terminal', totalHistoryQuota })
  fs.writeFileSync(closed.prevFile, 'o'.repeat(9 * 1024), { mode: 0o600 })
  fs.writeFileSync(closed.file, 'o'.repeat(3 * 1024), { mode: 0o600 })
  closed.close()
  // Nothing else in the broker ever deletes a retained-but-closed spool, and a
  // same-millisecond mtime would make the sweep order ambiguous.
  const aged = new Date(Date.now() - 60_000)
  for (const file of [closed.prevFile, closed.file]) {
    fs.utimesSync(file, aged, aged)
  }

  const events = []
  const live = fixture(t, {
    dir,
    id: 'live-terminal',
    historyQuota: 16 * 1024,
    totalHistoryQuota,
    onQuota: (event) => events.push(event),
  })
  pushBytes(live, 48 * 1024)

  assert.equal(fs.existsSync(closed.prevFile), false, 'the orphan segment survived the directory quota')
  assert.equal(fs.existsSync(live.file), true, 'a live terminal must keep the tail it is writing')
  const directoryEviction = events.find((event) => event.scope === 'directory' && event.phase === 'evicted')
  assert.ok(directoryEviction, 'no directory eviction was reported')
  assert.equal(directoryEviction.id, 'closed-terminal')

  // The closed terminal can still be restored, and it still knows what it lost.
  const orphanMeta = TerminalSpool.readMeta('closed-terminal', dir)
  assert.equal(orphanMeta.truncation.reason, 'directory-quota')
  assert.ok(orphanMeta.truncation.evictedBytes > 0)
})

test('directory quota eviction never follows a planted orphan meta link', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-orphan-link-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const base = 'a'.repeat(32)
  const orphanSegment = path.join(dir, `${base}.prev.log`)
  const orphanMeta = path.join(dir, `${base}.json`)
  fs.writeFileSync(orphanSegment, 'o'.repeat(12 * 1024), { mode: 0o600 })
  const aged = new Date(Date.now() - 60_000)
  fs.utimesSync(orphanSegment, aged, aged)

  const bystanderFile = bystander(t, JSON.stringify({
    v: 1,
    id: 'attacker-controlled-id',
    truncation: { evictedBytes: 7, evictions: 1 },
  }))
  const original = fs.readFileSync(bystanderFile, 'utf8')
  fs.symlinkSync(bystanderFile, orphanMeta)

  const live = fixture(t, {
    dir,
    id: 'live-terminal-orphan-meta-link',
    historyQuota: null,
    totalHistoryQuota: 8 * 1024,
  })
  live.push('l'.repeat(1024))
  live.flush()

  assert.equal(fs.existsSync(orphanSegment), false, 'the over-quota orphan segment survived')
  assert.equal(fs.lstatSync(orphanMeta).isSymbolicLink(), true)
  assert.equal(fs.readFileSync(bystanderFile, 'utf8'), original)
  assert.equal(fs.statSync(bystanderFile).mode & 0o777, 0o644)
})
