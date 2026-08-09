// Disk-backed terminal scrollback. Every byte is eagerly appended while a
// live/visible terminal keeps only an xterm-sized read tail in RAM; detaching
// drops that cache and the pty continues without a hidden renderer or a
// megabyte ring. The pty is NEVER stopped by this class.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const intEnv = (name, fallback, min, max) => {
  const n = Number(process.env[name])
  return Number.isFinite(n) ? Math.min(max, Math.max(min, Math.round(n))) : fallback
}

// Explicit ACP terminal/output requests may set a retention cap. Interactive
// user terminals do not: their log is the durable first-message truth surface
// and stays append-only for as long as it fits the history quota below, while
// snapshots and renderer scrollback stay independently bounded. The legacy env
// cap remains the default only for retentionCap-driven rotation.
const DEFAULT_DISK_CAP = intEnv('KAISOLA_TERMINAL_DISK_MB', 64, 2, 512) * 1024 * 1024
const DEFAULT_HOT_CAP = intEnv('KAISOLA_TERMINAL_HOT_KB', 1024, 128, 4096) * 1024
// How much retained output one reattach/resubscribe returns.
//
// Deliberately independent of the hot cap. The hot cap bounds the RAM the
// broker holds live per terminal; this bounds a single read from the disk
// spool. They used to be the same constant, so reattaching to a terminal that
// had produced more than 1 MiB since you left returned a short tail, which the
// client treats as a stream discontinuity — resetting the terminal and wiping
// the user's scrollback. That is the "history disappears after switching tabs"
// half of the scrollback problem.
const DEFAULT_SNAPSHOT_CAP = intEnv('KAISOLA_TERMINAL_SNAPSHOT_KB', 4096, 256, 16_384) * 1024
const DEFAULT_QUEUE_CAP = intEnv('KAISOLA_TERMINAL_SPOOL_BATCH_KB', 256, 32, 1024) * 1024
const DEFAULT_COLD_TAIL_CAP = 512 * 1024
const SPOOL_APPEND_DEBOUNCE_MS = 750
// Meta is what a restart resurrects a terminal from — exit evidence, cursor
// epoch, DEC modes, view state — so a failed write cannot be dropped the way a
// missed cache write can: the next launch would resurrect a still-running
// terminal from stale state. A failure keeps the spool dirty and retries on a
// bounded backoff, and the last error stays readable through stats().
const META_RETRY_BASE_MS = 250
const META_RETRY_MAX_MS = 8000
const META_RETRY_ATTEMPTS = 6
const SPOOL_DELETE_RETRY_ATTEMPTS = 3
const TRANSIENT_DELETE_CODES = new Set(['EAGAIN', 'EBUSY', 'EINTR', 'EIO', 'EMFILE', 'ENFILE'])
// Retained-history quotas. Interactive terminals used to be append-only with no
// ceiling at all, so one long-lived noisy shell could fill the user's volume.
// Two bounds now apply: how much history a single terminal may keep, and how
// much every spool sharing a directory may keep between them (which is also
// what reclaims the segments a closed-but-restorable terminal left behind).
//
// The per-terminal default is the largest history budget Settings offers, so
// the app's soft "terminal history uses N on disk" warning still fires first at
// every budget a user can pick. These quotas are the backstop underneath it,
// not the number anyone is meant to hit.
const DEFAULT_HISTORY_QUOTA = intEnv('KAISOLA_TERMINAL_HISTORY_MB', 4096, 64, 32_768) * 1024 * 1024
const DEFAULT_TOTAL_HISTORY_QUOTA = intEnv('KAISOLA_TERMINAL_HISTORY_TOTAL_MB', 16_384, 128, 131_072) * 1024 * 1024
// Warn at this share of a quota — before anything is evicted, while the user
// can still copy or close something.
const QUOTA_WARN_RATIO = 0.8
// A directory sweep stats every retained segment, so it is amortized against
// fresh output rather than run per append. A small quota sweeps sooner so the
// ceiling it names is the one actually enforced.
const MAX_SWEEP_INTERVAL = 4 * 1024 * 1024

function safeBase(id) {
  return crypto.createHash('sha256').update(String(id)).digest('hex').slice(0, 32)
}

const { O_APPEND, O_CREAT, O_NOFOLLOW, O_NONBLOCK, O_RDONLY, O_WRONLY } = fs.constants

function spoolPathRefused(code, file) {
  const error = new Error(`refusing unsafe terminal spool path ${file}`)
  error.code = code
  return error
}

// Segment paths are a hash of the terminal id under a directory any local
// process can name, so they are predictable long before the terminal exists.
// Opening one by name would follow a planted symlink and let the broker read
// or overwrite whatever the link points at — with broker authority, not the
// planter's. Every open of a segment therefore refuses to follow a link on the
// final path component (a symlinked spool *directory* still works) and the
// descriptor must be a regular file this uid owns before a byte moves.
// O_NONBLOCK keeps a planted fifo from parking the broker inside open().
function openSegment(file, flags, mode) {
  const fd = fs.openSync(file, flags | O_NOFOLLOW | O_NONBLOCK, mode)
  try {
    const stat = fs.fstatSync(fd)
    if (!stat.isFile()) throw spoolPathRefused('ESPOOLNOTFILE', file)
    if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
      throw spoolPathRefused('ESPOOLNOTOWNED', file)
    }
    return fd
  } catch (err) {
    try { fs.closeSync(fd) } catch { /* noop */ }
    throw err
  }
}

/** Retained size of one segment, or null when the path is absent, is a
 * symlink, or is not a regular file this uid owns. Callers treat null exactly
 * like "no retained segment", so a swapped-in link contributes neither bytes
 * to a byte count nor a read to a snapshot. lstat never resolves the final
 * component; the reads that follow are O_NOFOLLOW anyway, so a race between
 * the two loses nothing. */
function segmentSize(file) {
  try {
    const stat = fs.lstatSync(file)
    if (!stat.isFile()) return null
    if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) return null
    return stat.size
  } catch {
    return null
  }
}

// Private DEC modes that change how the terminal interprets INPUT (bracketed
// paste, cursor keys, mouse, focus) or renders the cursor. They are tracked
// out-of-band because snapshot output must remain an exact stream tail for
// observer byte cursors — and because the enabling sequence routinely scrolls
// past the bounded tail, which made reattached renderers paste multi-line text
// as line-by-line submits (?2004 lost).
const TRACKED_DEC_MODES = new Set([1, 25, 1000, 1002, 1003, 1004, 1006, 2004])
const DEC_MODE_DEFAULTS = { 25: true } // cursor visible; every other tracked mode defaults off
// Also match RIS (ESC c) and DECSTR (CSI ! p): `reset` after a crashed TUI
// emits these instead of individual DECRST sequences, and replaying stale
// mouse/paste enables into a remounted terminal corrupts every click.
const DEC_MODE_RE = /\x1b\[\?([0-9;]+)([hl])|\x1bc|\x1b\[!p/g
// The carry must hold the longest incomplete sequence we track (multi-param
// DECSET like ?1000;1002;1003;1004;1006;2004 is ~34 chars) — a window smaller
// than the sequence drops its ESC prefix and silently loses the modes.
const DEC_CARRY_MAX = 48
const DEC_CARRY_RE = /\x1b(?:\[(?:[?!][0-9;]{0,40})?)?$/

const { atomicJson } = require('./brokerWire.cjs')

// On-disk meta layout version. Readers treat an unknown version as "no prior
// state" (matching projectionStore's fail-closed-to-absent behavior) so the
// format can evolve — or be written by the future Swift runtime — without
// silently misreading a restructured viewState/decModes shape.
const META_VERSION = 1

/** `null` means unbounded. That stays reachable on purpose: a caller (or a test
 * pinning the historic append-only contract) can opt one spool out without
 * disabling the quota for every other terminal. */
function normalizeQuota(value) {
  const n = Number(value)
  return value == null || !Number.isFinite(n) ? null : Math.max(1, Math.floor(n))
}

/** Truncation provenance: how much history was dropped, how often, and why.
 * Persisted with the meta so a restored terminal can still explain a scrollback
 * that no longer reaches byte zero. */
function normalizeTruncation(value) {
  const source = value && typeof value === 'object' ? value : {}
  const count = (input) => (Number.isSafeInteger(input) && input >= 0 ? input : 0)
  const stamp = (input) => (Number.isSafeInteger(input) && input >= 0 ? input : null)
  return {
    evictedBytes: count(source.evictedBytes),
    evictions: count(source.evictions),
    reason: typeof source.reason === 'string' ? source.reason : null,
    firstAt: stamp(source.firstAt),
    lastAt: stamp(source.lastAt),
  }
}

// Open spools, so a directory sweep can tell a segment that still backs a live
// terminal from an orphan left behind by a closed one. Every spool is removed
// again by close(), which terminalManager pairs with every record it drops.
const liveSpools = new Set()

function ownerOf(file) {
  for (const spool of liveSpools) {
    if (spool.file === file || spool.prevFile === file) return spool
  }
  return null
}

/** Stamp the meta of an evicted-but-restorable terminal so the loss survives
 * into the session that reopens it. Returns the terminal id when known. */
function recordOrphanTruncation(dir, segmentName, bytes) {
  const metaFile = path.join(dir, `${segmentName.replace(/(?:\.prev)?\.log$/, '')}.json`)
  let fd
  try {
    fd = openSegment(metaFile, O_RDONLY)
    const meta = JSON.parse(fs.readFileSync(fd, 'utf8'))
    if (!meta || (meta.v != null && meta.v !== META_VERSION)) return null
    const at = Date.now()
    const prior = normalizeTruncation(meta.truncation)
    meta.truncation = {
      evictedBytes: prior.evictedBytes + Math.max(0, Math.floor(Number(bytes) || 0)),
      evictions: prior.evictions + 1,
      reason: 'directory-quota',
      firstAt: prior.firstAt ?? at,
      lastAt: at,
    }
    atomicJson(metaFile, meta)
    return typeof meta.id === 'string' ? meta.id : null
  } catch {
    return null
  } finally {
    if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
  }
}

/** Return at most `bytes` from the end without starting inside a multi-byte
 * UTF-8 code point. ACP explicitly requires character-boundary truncation. */
function utf8Tail(value, bytes) {
  const cap = Number.isFinite(Number(bytes)) ? Math.max(0, Math.floor(Number(bytes))) : 0
  if (cap === 0) return ''
  const buffer = Buffer.isBuffer(value) ? value : Buffer.from(String(value ?? ''), 'utf8')
  if (buffer.length <= cap) return buffer.toString('utf8')
  let start = buffer.length - cap
  while (start < buffer.length && (buffer[start] & 0xc0) === 0x80) start++
  return buffer.subarray(start).toString('utf8')
}

// A segment read ends one of four ways, and only three of them are history:
// the segment is ABSENT (never written, or already rotated away), it is EMPTY
// (a real file holding no bytes), it is OK, or the read itself FAILED (stat,
// open or read refused). Every read used to answer the first three and the
// fourth with the same empty string, so one transient EACCES/EIO read exactly
// like an authoritative empty transcript — and an authoritative empty
// transcript is what makes a client reset the terminal and drop the user's
// scrollback. Callers must be able to tell "there is nothing" from "I could
// not look".
const READ_ABSENT = 'absent'
const READ_EMPTY = 'empty'
const READ_OK = 'ok'
const READ_FAILED = 'failed'
const EMPTY_BUFFER = Buffer.alloc(0)

// A segment that vanished between the stat and the read is absent, not
// broken: close({ remove }) unlinks segments while readers are still running.
function isMissing(err) {
  const code = err && err.code
  return code === 'ENOENT' || code === 'ENOTDIR'
}

function readErrorCode(err) {
  return String((err && err.code) || (err && err.message) || err || 'spool-read-failed')
}

/** Inspect a retained segment through the same non-following, regular-file,
 * owner-checked descriptor used for actual reads. */
function segmentSizeResult(file) {
  let fd
  try {
    fd = openSegment(file, O_RDONLY)
    const size = fs.fstatSync(fd).size
    return { status: size ? READ_OK : READ_EMPTY, size, error: null }
  } catch (err) {
    if (isMissing(err)) return { status: READ_ABSENT, size: 0, error: null }
    return { status: READ_FAILED, size: 0, error: readErrorCode(err) }
  } finally {
    if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
  }
}

/** Evict whole chunks from the front of `chunks` until the retained tail fits
 * `cap`, then trim what is left when a single chunk is still oversized, and
 * return the new byte length. */
function trimChunksToCap(chunks, byteLength, cap) {
  const limit = Number.isFinite(Number(cap)) ? Math.max(0, Math.floor(Number(cap))) : 0
  let length = byteLength
  while (chunks.length > 1 && length > limit) {
    length -= Buffer.byteLength(chunks.shift())
  }
  if (chunks.length === 1 && length > limit) {
    const tail = utf8Tail(chunks[0], limit)
    length = Buffer.byteLength(tail)
    if (length) chunks[0] = tail
    else chunks.length = 0
  }
  return length
}

/** Read at most `bytes` from the end of `file` without starting inside a
 * multi-byte scalar. `text` is history only when `status` is `ok` or `empty`;
 * a `failed` result carries the error code and no bytes. */
function readTail(file, bytes) {
  let fd
  try {
    fd = openSegment(file, O_RDONLY)
    const size = fs.fstatSync(fd).size
    if (!size) return { status: READ_EMPTY, text: '', error: null }
    const cap = Math.max(0, Math.floor(Number(bytes) || 0))
    if (!cap) return { status: READ_OK, text: '', error: null }
    const take = Math.min(size, cap + 3)
    const b = Buffer.allocUnsafe(take)
    fs.readSync(fd, b, 0, take, size - take)
    return { status: READ_OK, text: utf8Tail(b, cap), error: null }
  } catch (err) {
    if (isMissing(err)) return { status: READ_ABSENT, text: '', error: null }
    return { status: READ_FAILED, text: '', error: readErrorCode(err) }
  } finally {
    if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
  }
}

/** Read `length` bytes at `start` as the same typed result. `buffer` is empty
 * for every status except `ok`, so a caller that concatenates blindly still
 * has to consult `status` before treating the bytes as the whole range. */
function readRange(file, start, length) {
  let fd
  try {
    fd = openSegment(file, O_RDONLY)
    const size = fs.fstatSync(fd).size
    if (!size) return { status: READ_EMPTY, buffer: EMPTY_BUFFER, error: null }
    const offset = Math.max(0, Math.min(size, Math.floor(Number(start) || 0)))
    const take = Math.max(0, Math.min(size - offset, Math.floor(Number(length) || 0)))
    if (!take) return { status: READ_OK, buffer: EMPTY_BUFFER, error: null }
    const buffer = Buffer.allocUnsafe(take)
    const read = fs.readSync(fd, buffer, 0, take, offset)
    return { status: READ_OK, buffer: read === take ? buffer : buffer.subarray(0, read), error: null }
  } catch (err) {
    if (isMissing(err)) return { status: READ_ABSENT, buffer: EMPTY_BUFFER, error: null }
    return { status: READ_FAILED, buffer: EMPTY_BUFFER, error: readErrorCode(err) }
  } finally {
    if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
  }
}

// A spool root is private broker storage: transcripts, view state and exit
// evidence all land under it, and the default root is a predictable
// `kaisola-terminal-cache-<pid>` inside the shared temp directory. mkdir with
// `recursive` treats an existing symlink-to-directory as "already there", so a
// local process that pre-creates that path silently redirects every terminal
// write outside broker storage. Validate the whole chain with lstat first and
// refuse to run rather than write through a path we do not trust.
const SPOOL_DIR_MODE = 0o700
const OTHER_WRITE_BITS = 0o022
const STICKY_BIT = 0o1000
const MAX_LINK_HOPS = 8

function unsafeSpoolDir(file, reason) {
  const error = new Error(`refusing terminal spool directory: ${reason} (${file})`)
  error.code = 'ERR_KAISOLA_UNSAFE_SPOOL_DIR'
  return error
}

/** Root-owned ancestors are trusted, because a compromised root already owns
 * the machine, but anything belonging to another account is not. */
function ownedSafely(stat, uid) {
  return stat.uid === uid || stat.uid === 0
}

/** Check every existing ancestor of `target`. Returns once a component is
 * absent: mkdir creates that one and everything under it with our own mode. */
function assertTrustedAncestors(target, uid) {
  let remaining = target.split(path.sep).filter(Boolean)
  remaining.pop() // the leaf is checked separately, after it exists
  let current = path.sep
  let hops = 0
  while (remaining.length) {
    const next = path.join(current, remaining.shift())
    let stat
    try {
      stat = fs.lstatSync(next)
    } catch (error) {
      if (error?.code === 'ENOENT') return
      throw unsafeSpoolDir(next, `unreadable (${error?.code || 'lstat failed'})`)
    }
    if (stat.isSymbolicLink()) {
      // macOS ships /var and /tmp as root-owned links into /private, so an
      // ancestor link is ordinary. Follow one only when the link itself is
      // ours or root's: every directory above it has already been proven not
      // writable by anyone else, so nobody could have planted it. Its target
      // is re-walked from the root, giving each hop the same checks.
      if (!ownedSafely(stat, uid)) throw unsafeSpoolDir(next, 'symlink owned by another user')
      if (++hops > MAX_LINK_HOPS) throw unsafeSpoolDir(next, 'symlink chain too deep')
      const resolved = path.resolve(path.dirname(next), fs.readlinkSync(next))
      remaining = resolved.split(path.sep).filter(Boolean).concat(remaining)
      current = path.sep
      continue
    }
    if (!stat.isDirectory()) throw unsafeSpoolDir(next, 'not a directory')
    if (!ownedSafely(stat, uid)) throw unsafeSpoolDir(next, 'owned by another user')
    // A group- or world-writable ancestor lets another account swap our path
    // out from under us. The sticky bit is the one exception the platform
    // itself relies on: /tmp is 1777, where only an entry's owner may rename
    // or delete it, and the leaf check below still catches a planted entry.
    if ((stat.mode & OTHER_WRITE_BITS) && !(stat.mode & STICKY_BIT)) {
      throw unsafeSpoolDir(next, 'writable by group or others')
    }
    current = next
  }
}

/** True when `dir` exists and is a private directory of ours. Unlike an
 * ancestor, the leaf is a path we create ourselves, so a symlink there means
 * someone got to it first. There is no legitimate version of that. */
function isPrivateSpoolDir(dir, uid) {
  let stat
  try {
    stat = fs.lstatSync(dir)
  } catch (error) {
    if (error?.code === 'ENOENT') return false
    throw unsafeSpoolDir(dir, `unreadable (${error?.code || 'lstat failed'})`)
  }
  if (stat.isSymbolicLink()) throw unsafeSpoolDir(dir, 'symlink')
  if (!stat.isDirectory()) throw unsafeSpoolDir(dir, 'not a directory')
  if (stat.uid !== uid) throw unsafeSpoolDir(dir, 'owned by another user')
  if (stat.mode & OTHER_WRITE_BITS) throw unsafeSpoolDir(dir, 'writable by group or others')
  return true
}

/** Create the spool root only through a chain we have verified, and hand back
 * the resolved path. Throws with code ERR_KAISOLA_UNSAFE_SPOOL_DIR otherwise;
 * a terminal that cannot get private storage must not start. */
function ensurePrivateSpoolDir(dir) {
  const target = path.resolve(String(dir ?? ''))
  // Windows carries neither uid nor POSIX mode, so there is nothing to verify.
  const uid = typeof process.getuid === 'function' ? process.getuid() : null
  if (uid == null) {
    fs.mkdirSync(target, { recursive: true, mode: SPOOL_DIR_MODE })
    return target
  }
  assertTrustedAncestors(target, uid)
  isPrivateSpoolDir(target, uid)
  fs.mkdirSync(target, { recursive: true, mode: SPOOL_DIR_MODE })
  // mkdir accepts an existing symlink-to-directory, so the leaf is checked
  // again here: this pass is what a path planted between the check above and
  // the mkdir itself runs into.
  if (!isPrivateSpoolDir(target, uid)) throw unsafeSpoolDir(target, 'vanished while being created')
  // Spool roots from before this check may carry group/other read bits; they
  // are ours and not writable by anyone else, so tighten instead of refusing.
  try { fs.chmodSync(target, SPOOL_DIR_MODE) } catch { /* ownership already verified */ }
  return target
}

function safeDeletionCode(error) {
  const code = String(error?.code || '')
  return /^[A-Z][A-Z0-9_]{0,63}$/.test(code) ? code : 'EUNLINK'
}

function deleteSpoolArtifact(name, file) {
  for (let attempts = 1; attempts <= SPOOL_DELETE_RETRY_ATTEMPTS; attempts += 1) {
    try {
      fs.unlinkSync(file)
      return { name, status: 'deleted', attempts }
    } catch (error) {
      if (error?.code === 'ENOENT') return { name, status: 'absent', attempts }
      const code = safeDeletionCode(error)
      if (TRANSIENT_DELETE_CODES.has(code) && attempts < SPOOL_DELETE_RETRY_ATTEMPTS) continue
      return { name, status: 'failed', code, attempts }
    }
  }
  return { name, status: 'failed', code: 'EUNLINK', attempts: SPOOL_DELETE_RETRY_ATTEMPTS }
}

function deletionResult(artifacts) {
  const complete = artifacts.every(({ status }) => status !== 'failed')
  return { complete, retryable: !complete, artifacts }
}

function deleteSpoolArtifacts(currentFile, previousFile, metadataFile) {
  return deletionResult([
    deleteSpoolArtifact('current', currentFile),
    deleteSpoolArtifact('previous', previousFile),
    deleteSpoolArtifact('metadata', metadataFile),
  ])
}

function refusedDeletion(error) {
  const code = safeDeletionCode(error)
  return deletionResult(['current', 'previous', 'metadata'].map((name) => ({
    name,
    status: 'failed',
    code,
    attempts: 0,
  })))
}

class TerminalSpool {
  /** Retry a prior removal without constructing a spool, reading retained
   * content, or creating a PTY. The terminal ID is hashed to the same fixed
   * artifact names used by a live spool. */
  static cleanup(id, dir) {
    let root
    try {
      root = ensurePrivateSpoolDir(dir)
    } catch (error) {
      return refusedDeletion(error)
    }
    const base = safeBase(id)
    return deleteSpoolArtifacts(
      path.join(root, `${base}.log`),
      path.join(root, `${base}.prev.log`),
      path.join(root, `${base}.json`),
    )
  }

  static readMeta(id, dir) {
    const terminalId = String(id)
    const metaFile = path.join(dir, `${safeBase(terminalId)}.json`)
    let fd
    try {
      // The meta path is as predictable as the log; a link planted there would
      // otherwise hand arbitrary JSON — or an unrelated file's bytes — to a
      // restoring terminal.
      fd = openSegment(metaFile, O_RDONLY)
      const meta = JSON.parse(fs.readFileSync(fd, 'utf8'))
      if (!meta || meta.id !== terminalId || (meta.v != null && meta.v !== META_VERSION)) return null
      return meta
    } catch {
      return null
    } finally {
      if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
    }
  }

  static coldTail(id, dir, maxBytes = DEFAULT_COLD_TAIL_CAP) {
    const base = safeBase(id)
    const currentFile = path.join(dir, `${base}.log`)
    const prevFile = path.join(dir, `${base}.prev.log`)
    const segments = []
    let readError = null
    for (const file of [prevFile, currentFile]) {
      const result = segmentSizeResult(file)
      if (result.status === READ_FAILED) readError = readError || result.error
      if (result.status === READ_OK || result.status === READ_EMPTY) {
        segments.push({ file, size: result.size })
      }
    }
    // `null` is the answer for "this terminal retained nothing", which callers
    // treat as authoritative. A refused stat is not that answer.
    if (!segments.length && !readError) return null

    const capValue = Number(maxBytes)
    const cap = Number.isFinite(capValue)
      ? Math.max(0, Math.floor(capValue))
      : DEFAULT_COLD_TAIL_CAP
    const totalBytes = segments.reduce((sum, segment) => sum + segment.size, 0)
    const current = readTail(currentFile, cap)
    if (current.status === READ_FAILED) readError = readError || current.error
    const remaining = Math.max(0, cap - Buffer.byteLength(current.text))
    const previous = remaining ? readTail(prevFile, remaining) : { text: '', status: READ_OK }
    if (previous.status === READ_FAILED) readError = readError || previous.error
    return {
      text: previous.text + current.text,
      // A failed read cannot prove it returned the whole retained tail, so the
      // cold tail is truncated by definition once anything below it refused.
      truncated: totalBytes > cap || !!readError,
      ...(readError ? { readError } : {}),
    }
  }

  constructor({
    dir,
    id,
    diskCap = DEFAULT_DISK_CAP,
    hotCap = DEFAULT_HOT_CAP,
    queueCap = DEFAULT_QUEUE_CAP,
    retentionCap = null,
    fresh = false,
    historyQuota = DEFAULT_HISTORY_QUOTA,
    totalHistoryQuota = DEFAULT_TOTAL_HISTORY_QUOTA,
    onQuota = null,
  }) {
    this.id = String(id)
    this.dir = dir
    this.diskCap = diskCap
    this.hotCap = hotCap
    this.queueCap = queueCap
    this.retentionCap = Number.isFinite(retentionCap) ? Math.max(0, Math.floor(retentionCap)) : null
    this.historyQuota = normalizeQuota(historyQuota)
    this.totalHistoryQuota = normalizeQuota(totalHistoryQuota)
    this.onQuota = typeof onQuota === 'function' ? onQuota : null
    this.truncation = normalizeTruncation(null)
    this.quotaWarned = false
    this.directoryQuotaWarned = false
    // Sweep on the first append rather than in the constructor: a directory
    // already over quota when the app launches must not wait for 4 MiB of
    // fresh output, but a spawn should not pay for a readdir it may not need.
    this.bytesSinceSweep = Number.POSITIVE_INFINITY
    this.visible = true
    this.chunks = []
    this.chunksLen = 0
    this.queued = []
    this.queuedLen = 0
    this.appendTimer = null
    this.truncated = false
    this.viewState = null
    this.epochStartOffset = 0
    this.exitedAt = null
    this.exitStatus = null
    const root = ensurePrivateSpoolDir(dir)
    const base = safeBase(this.id)
    this.file = path.join(root, `${base}.log`)
    this.prevFile = path.join(root, `${base}.prev.log`)
    this.metaFile = path.join(root, `${base}.json`)
    if (fresh) {
      // unlink removes the directory entry, never what a link points at, so a
      // planted link is cleared here without touching its target.
      for (const file of [this.file, this.prevFile, this.metaFile]) {
        try { fs.unlinkSync(file) } catch { /* absent or already unavailable */ }
      }
    }
    this.fallbackChunks = []
    this.fallbackLen = 0
    this.diskError = null
    this.metaError = null
    this.metaDirty = false
    this.metaRetryTimer = null
    this.metaRetries = 0
    this.closed = false
    this.decModes = new Map()
    this.decCarry = ''
    const meta = TerminalSpool.readMeta(this.id, root)
    if (meta) {
      this.viewState = meta.viewState || null
      if (Number.isSafeInteger(meta.epochStartOffset) && meta.epochStartOffset >= 0) {
        this.epochStartOffset = meta.epochStartOffset
      }
      if (Number.isSafeInteger(meta.exitedAt) && meta.exitedAt >= 0) {
        this.exitedAt = meta.exitedAt
        this.exitStatus = meta.exitStatus ?? null
      }
      if (meta.decModes && typeof meta.decModes === 'object') {
        for (const [mode, set] of Object.entries(meta.decModes)) {
          const n = Number(mode)
          if (TRACKED_DEC_MODES.has(n)) this.decModes.set(n, !!set)
        }
      }
      // History dropped by a previous session stays dropped: carry the
      // provenance forward so the reopened terminal keeps saying so.
      this.truncation = normalizeTruncation(meta.truncation)
      if (this.truncation.evictions > 0) this.truncated = true
    }
    liveSpools.add(this)
  }

  _trackModes(data) {
    const text = this.decCarry + data
    DEC_MODE_RE.lastIndex = 0
    let m
    while ((m = DEC_MODE_RE.exec(text))) {
      if (m[1] == null) { // RIS or DECSTR — every private mode reverts to default
        this.decModes.clear()
        continue
      }
      const set = m[2] === 'h'
      for (const param of m[1].split(';')) {
        const mode = Number(param)
        if (TRACKED_DEC_MODES.has(mode)) this.decModes.set(mode, set)
      }
    }
    const carry = text.slice(-DEC_CARRY_MAX).match(DEC_CARRY_RE)
    this.decCarry = carry ? carry[0] : ''
  }

  _modePrefix() {
    let prefix = ''
    for (const mode of [...this.decModes.keys()].sort((a, b) => a - b)) {
      const set = this.decModes.get(mode)
      if (set === !!DEC_MODE_DEFAULTS[mode]) continue // default state: nothing to replay
      prefix += `\x1b[?${mode}${set ? 'h' : 'l'}`
    }
    return prefix
  }

  _queue(text) {
    if (!text) return
    if (this.retentionCap === 0) { this.truncated = true; return }
    this.queued.push(text)
    this.queuedLen += Buffer.byteLength(text)
    if (this.queuedLen >= this.queueCap) {
      this.flush()
    } else if (!this.appendTimer) {
      this.appendTimer = setTimeout(() => {
        this.appendTimer = null
        this.flush()
      }, SPOOL_APPEND_DEBOUNCE_MS)
      this.appendTimer.unref?.()
    }
  }

  _append(text) {
    if (!text) return
    if (this.retentionCap === 0) { this.truncated = true; return }
    const recovery = this.fallbackChunks.join('')
    const payload = recovery + text
    let appended = false
    try {
      // Never appendFileSync/chmodSync by path: both follow a symlink, so a
      // planted link would take the append — and the 0600 chmod — to whatever
      // file it names. openSegment refuses the link and this write goes to a
      // regular file we own, or nowhere.
      const size = this._writeSegment(payload)
      appended = true
      this.fallbackChunks = []
      this.fallbackLen = 0
      this.diskError = null
      this.bytesSinceSweep += Buffer.byteLength(payload)
      // Interactive terminals stay append-only for as long as they fit their
      // quota — that is what lets terminal.history reach the literal first
      // byte of an ordinary session. Past it they rotate through the same
      // bounded two-segment scheme as an ACP capture terminal, which sizes its
      // rotation from the explicit retentionCap's disk cap instead.
      const budget = this.retentionCap != null ? this.diskCap : this.historyQuota
      if (budget != null) {
        // A capture terminal rotating inside its own retentionCap is the
        // contract its caller asked for, not history the user is losing: it
        // keeps the provenance but stays quiet and off the extra meta write.
        const quotaDriven = this.retentionCap == null
        if (quotaDriven) this._noteQuotaPressure(size, budget)
        if (size > Math.max(1, Math.floor(budget / 2))) this._rotateSegments(quotaDriven)
      }
      this._sweepDirectoryQuota()
    } catch (err) {
      this.diskError = String((err && err.code) || (err && err.message) || err || 'disk-write-failed')
      this.truncated = true
      // Disk-full/permission errors must never crash Electron main. If append
      // did not land, retain a bounded hot tail so the live shell stays usable.
      if (!appended) this._retainFallback(text)
    }
  }

  /** Append `payload` to the current segment through a no-follow descriptor
   * and return the segment's new size. Throws when the path is not a regular
   * file this uid owns, which `_append` reports as a disk error. */
  _writeSegment(payload) {
    const buffer = Buffer.from(payload, 'utf8')
    const fd = openSegment(this.file, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    try {
      let written = 0
      while (written < buffer.length) {
        written += fs.writeSync(fd, buffer, written, buffer.length - written)
      }
      // Re-assert 0600 on a segment that predates this process (or this fix).
      try { fs.fchmodSync(fd, 0o600) } catch { /* noop */ }
      return fs.fstatSync(fd).size
    } finally {
      try { fs.closeSync(fd) } catch { /* noop */ }
    }
  }

  _emitQuota(event) {
    const payload = { id: this.id, at: Date.now(), ...event }
    this.lastQuotaEvent = payload
    try { this.onQuota?.(payload) } catch { /* diagnostics must never break a write */ }
    return payload
  }

  /** Warn once per approach, before anything is evicted. The warning re-arms
   * after an eviction so a terminal that keeps filling keeps saying so. */
  _noteQuotaPressure(currentSize, budget) {
    const retained = currentSize + (segmentSize(this.prevFile) || 0)
    if (retained < Math.floor(budget * QUOTA_WARN_RATIO)) {
      this.quotaWarned = false
      return
    }
    if (this.quotaWarned) return
    this.quotaWarned = true
    this._emitQuota({ phase: 'warning', scope: 'terminal', retainedBytes: retained, quotaBytes: budget })
  }

  /** In-memory provenance only. Persisting and announcing are the caller's
   * call, because the directory sweep speaks for its own evictions and a
   * capture terminal's rotation is not worth either. */
  _recordEviction(bytes, reason) {
    const at = Date.now()
    this.truncated = true
    this.truncation.evictedBytes += Math.max(0, Math.floor(Number(bytes) || 0))
    this.truncation.evictions += 1
    this.truncation.reason = reason
    if (this.truncation.firstAt == null) this.truncation.firstAt = at
    this.truncation.lastAt = at
    this.quotaWarned = false
  }

  /** Retire the current segment. The previous one, if any, is the history the
   * quota costs us — epochStartOffset indexes the retained spool, so it moves
   * back by exactly the bytes that stopped being retained. */
  _rotateSegments(quotaDriven) {
    // A planted symlink is unlinked but never credited as retained history.
    // Only a verified owned regular file counts as an eviction.
    const priorSize = segmentSize(this.prevFile)
    const discarded = priorSize != null
    const discardedBytes = priorSize || 0
    try { fs.unlinkSync(this.prevFile) } catch { /* first segment */ }
    if (discardedBytes) this.epochStartOffset = Math.max(0, this.epochStartOffset - discardedBytes)
    fs.renameSync(this.file, this.prevFile)
    if (!discarded) return
    this._recordEviction(discardedBytes, quotaDriven ? 'terminal-quota' : 'retention-cap')
    if (!quotaDriven) return
    this.persistMeta()
    this._emitQuota({
      phase: 'evicted',
      scope: 'terminal',
      reason: 'terminal-quota',
      evictedBytes: discardedBytes,
      retainedBytes: this._retainedDiskBytes(),
    })
  }

  /** A directory sweep removed this spool's cold segment out from under it. */
  _noteSegmentEvicted(bytes) {
    if (bytes) this.epochStartOffset = Math.max(0, this.epochStartOffset - bytes)
    this._recordEviction(bytes, 'directory-quota')
    this.persistMeta()
  }

  /** Bound what every spool sharing this directory retains between them. This
   * is the half of the quota that reclaims segments a closed-but-restorable
   * terminal left behind — nothing else ever deletes those. */
  _sweepDirectoryQuota() {
    const quota = this.totalHistoryQuota
    if (quota == null) return
    // A small quota has to be checked often enough to actually hold.
    if (this.bytesSinceSweep < Math.min(MAX_SWEEP_INTERVAL, Math.max(1, Math.floor(quota / 8)))) return
    this.bytesSinceSweep = 0
    const segments = []
    try {
      for (const name of fs.readdirSync(this.dir)) {
        if (!name.endsWith('.log')) continue
        const file = path.join(this.dir, name)
        try {
          const stat = fs.lstatSync(file)
          if (stat.isFile()
              && (typeof process.getuid !== 'function' || stat.uid === process.getuid())) {
            segments.push({ file, name, size: stat.size, mtimeMs: stat.mtimeMs })
          }
        } catch { /* vanished mid-sweep */ }
      }
    } catch { return }

    let total = segments.reduce((sum, segment) => sum + segment.size, 0)
    if (total < Math.floor(quota * QUOTA_WARN_RATIO)) this.directoryQuotaWarned = false
    else if (!this.directoryQuotaWarned) {
      this.directoryQuotaWarned = true
      this._emitQuota({ phase: 'warning', scope: 'directory', retainedBytes: total, quotaBytes: quota })
    }
    if (total <= quota) return

    // Oldest segment first. A rotated `.prev.log` is always older than the
    // `.log` it was renamed from, so mtime order already spends a terminal's
    // cold half before anything a live session is still writing.
    segments.sort((a, b) => a.mtimeMs - b.mtimeMs)
    for (const segment of segments) {
      if (total <= quota) break
      const owner = ownerOf(segment.file)
      if (owner && segment.file === owner.file) continue // never wipe a live tail
      try { fs.unlinkSync(segment.file) } catch { continue }
      total -= segment.size
      let terminalId = null
      if (owner) {
        owner._noteSegmentEvicted(segment.size)
        terminalId = owner.id
      } else {
        terminalId = recordOrphanTruncation(this.dir, segment.name, segment.size)
      }
      this._emitQuota({
        id: terminalId,
        phase: 'evicted',
        scope: 'directory',
        reason: 'directory-quota',
        evictedBytes: segment.size,
        retainedBytes: total,
        quotaBytes: quota,
        segment: segment.name,
      })
    }
  }

  _retainedDiskBytes() {
    return (segmentSize(this.prevFile) || 0) + (segmentSize(this.file) || 0)
  }

  _retainFallback(text) {
    if (!text) return
    this.fallbackChunks.push(text)
    this.fallbackLen += Buffer.byteLength(text)
    this.fallbackLen = trimChunksToCap(this.fallbackChunks, this.fallbackLen, this.hotCap)
  }

  /** Retained segments plus the first read failure that hid one of them.
   * A segment that stats ENOENT is genuinely gone; any other stat error means
   * the segment list below is short by an unknown number of bytes. */
  _diskSegments(startOffset = 0) {
    const segments = []
    let readError = null
    let skip = Math.max(0, Math.floor(Number(startOffset) || 0))
    for (const file of [this.prevFile, this.file]) {
      const result = segmentSizeResult(file)
      if (result.status === READ_FAILED) readError = readError || result.error
      if (result.status !== READ_OK && result.status !== READ_EMPTY) continue
      const size = result.size
      const fileStart = Math.min(size, skip)
      skip -= fileStart
      if (size > fileStart) segments.push({ file, fileStart, length: size - fileStart })
    }
    return { segments, readError }
  }

  _diskTail(bytes, startOffset = 0) {
    const cap = Math.max(0, Math.floor(Number(bytes) || 0))
    if (!cap) return { text: '', readError: null }
    const { segments, readError: segmentError } = this._diskSegments(startOffset)
    let readError = segmentError
    const totalBytes = segments.reduce((sum, segment) => sum + segment.length, 0)
    // Read a few extra bytes so utf8Tail can move a boundary that lands in the
    // middle of a multi-byte scalar without returning less history than needed.
    const startByte = Math.max(0, totalBytes - cap - 3)
    const slices = []
    let segmentStart = 0
    for (const segment of segments) {
      const segmentEnd = segmentStart + segment.length
      const sliceStart = Math.max(startByte, segmentStart)
      if (segmentEnd > sliceStart) {
        const localStart = sliceStart - segmentStart
        const read = readRange(segment.file, segment.fileStart + localStart, segmentEnd - sliceStart)
        if (read.status === READ_FAILED) readError = readError || read.error
        slices.push(read.buffer)
      }
      segmentStart = segmentEnd
    }
    return { text: utf8Tail(Buffer.concat(slices), cap), readError }
  }

  flush() {
    if (this.appendTimer) {
      clearTimeout(this.appendTimer)
      this.appendTimer = null
    }
    if (!this.queuedLen) return
    const text = this.queued.join('')
    this.queued = []
    this.queuedLen = 0
    this._append(text)
  }

  push(data) {
    if (!data || this.closed) return
    this._trackModes(data) // input modes matter even when output is not retained
    if (this.retentionCap === 0) { this.truncated = true; return }
    // Every byte is queued exactly once regardless of renderer visibility.
    // `chunks` below is only a bounded read cache; its evictions are already
    // durable (or represented in the disk-failure fallback) and must never be
    // re-queued.
    this._queue(data)
    if (!this.visible) return
    this.chunks.push(data)
    this.chunksLen += Buffer.byteLength(data)
    this.chunksLen = trimChunksToCap(this.chunks, this.chunksLen, this.hotCap)
  }

  setVisible(visible, viewState) {
    this.visible = !!visible
    if (viewState && typeof viewState === 'object') this.viewState = viewState
    if (!this.visible) {
      this.chunks = []
      this.chunksLen = 0
      this.flush()
      this.persistMeta()
    }
  }

  /** Persist the resurrection metadata now. Every explicit caller (visibility,
   * exit, epoch, close) is writing newer state, so each one restarts the retry
   * budget rather than inheriting an exhausted one. */
  persistMeta() {
    this.metaRetries = 0
    this._clearMetaRetry()
    return this._writeMeta()
  }

  _writeMeta() {
    // A closed spool has nothing left to resurrect, and close({remove}) already
    // deleted the meta file: a late retry must not recreate it.
    if (this.closed) return false
    const exitEvidence = this.exitEvidence()
    const truncation = this.truncationEvidence()
    try {
      atomicJson(this.metaFile, {
        v: META_VERSION,
        id: this.id,
        viewState: this.viewState,
        decModes: Object.fromEntries(this.decModes),
        epochStartOffset: this.epochStartOffset,
        ...(exitEvidence || {}),
        ...(truncation ? { truncation } : {}),
        touchedAt: Date.now(),
      })
      this.metaDirty = false
      this.metaError = null
      this.metaRetries = 0
      return true
    } catch (err) {
      // Never fatal to the live shell, but never silent either: the state stays
      // dirty, the error stays readable, and the write is retried.
      this.metaDirty = true
      this.metaError = String((err && err.code) || (err && err.message) || err || 'meta-write-failed')
      this._scheduleMetaRetry()
      return false
    }
  }

  _scheduleMetaRetry() {
    if (this.metaRetryTimer || this.closed) return
    // Budget exhausted: stop spinning on a disk that is not coming back. The
    // spool stays dirty and the error stays visible until the next explicit
    // persistMeta, which is also the next state actually worth writing.
    if (this.metaRetries >= META_RETRY_ATTEMPTS) return
    const delay = Math.min(META_RETRY_MAX_MS, META_RETRY_BASE_MS * (2 ** this.metaRetries))
    this.metaRetries += 1
    this.metaRetryTimer = setTimeout(() => {
      this.metaRetryTimer = null
      this._writeMeta()
    }, delay)
    this.metaRetryTimer.unref?.()
  }

  _clearMetaRetry() {
    if (!this.metaRetryTimer) return
    clearTimeout(this.metaRetryTimer)
    this.metaRetryTimer = null
  }

  markExited(status) {
    if (this.closed) return null
    this.flush()
    this.exitedAt = Date.now()
    this.exitStatus = status ?? null
    this.persistMeta()
    return this.exitEvidence()
  }

  exitEvidence() {
    if (!Number.isSafeInteger(this.exitedAt) || this.exitedAt < 0) return null
    return { exitedAt: this.exitedAt, exitStatus: this.exitStatus }
  }

  /** Non-null only once a quota has actually dropped history. */
  truncationEvidence() {
    return this.truncation.evictions > 0 ? { ...this.truncation } : null
  }

  retainedByteCount() {
    this.flush()
    return this._retainedDiskBytes() + this.fallbackLen
  }

  startEpoch(offset = this.retainedByteCount()) {
    this.epochStartOffset = Math.max(0, Math.floor(Number(offset) || 0))
    this.persistMeta()
    return this.epochStartOffset
  }

  snapshot(outputCap = DEFAULT_HOT_CAP) {
    this.flush()
    const cap = Number.isFinite(Number(outputCap)) ? Math.max(0, Math.floor(Number(outputCap))) : DEFAULT_HOT_CAP
    const hot = this.chunks.join('')
    const hotBytes = Buffer.byteLength(hot)
    const fallback = this.fallbackChunks.join('')
    const fallbackBytes = Buffer.byteLength(fallback)
    // Eager append means the hot tail overlaps the end of the disk log. Use it
    // directly only when it can satisfy the whole read; otherwise read the
    // authoritative disk tail and append only disk-write fallback bytes.
    let readError = null
    let output
    if (!fallbackBytes && !this.diskError && hotBytes >= cap) {
      output = utf8Tail(hot, cap)
    } else {
      const tail = this._diskTail(cap, this.epochStartOffset)
      readError = tail.readError
      // A failed disk read is not an empty transcript. Answer with the exact
      // stream suffix still held in RAM — both caches end at the live cursor,
      // so the longer one is the most history we can honestly prove — and let
      // `readError` tell the caller this snapshot is not authoritative.
      output = readError
        ? utf8Tail(hotBytes >= fallbackBytes ? hot : fallback, cap)
        : utf8Tail(tail.text + fallback, cap)
    }
    const liveDiskBytes = Math.max(0, this._retainedDiskBytes() - this.epochStartOffset)
    const truncation = this.truncationEvidence()
    return {
      output,
      truncated: this.truncated || !!readError || liveDiskBytes + fallbackBytes > cap,
      ...(truncation ? { truncation } : {}),
      viewState: this.viewState,
      modePrefix: this._modePrefix(),
      ...(readError ? { readError } : {}),
    }
  }

  /** Return one bounded page ending `distanceFromEnd` bytes before the live
   * cursor. Offsets are relative to the complete retained spool (the complete
   * session for interactive terminals) and are
   * translated to absolute stream offsets by terminalManager. */
  historyPage(distanceFromEnd = 0, outputCap = DEFAULT_SNAPSHOT_CAP) {
    this.flush()
    const { segments, readError: segmentError } = this._diskSegments()
    let readError = segmentError
    // `chunks` is a cache of the already-appended disk suffix. Only fallback
    // bytes represent output not present in the disk segments.
    for (const value of [this.fallbackChunks.join('')]) {
      const buffer = Buffer.from(value, 'utf8')
      if (buffer.length > 0) segments.push({ buffer, length: buffer.length })
    }

    const totalBytes = segments.reduce((sum, segment) => sum + segment.length, 0)
    const distance = Math.max(0, Math.floor(Number(distanceFromEnd) || 0))
    const cap = Math.max(0, Math.floor(Number(outputCap) || 0))
    const endByte = Math.max(0, totalBytes - Math.min(totalBytes, distance))
    let startByte = Math.max(0, endByte - cap)
    const slices = []
    let segmentStart = 0
    for (const segment of segments) {
      const segmentEnd = segmentStart + segment.length
      const sliceStart = Math.max(startByte, segmentStart)
      const sliceEnd = Math.min(endByte, segmentEnd)
      if (sliceEnd > sliceStart) {
        const localStart = sliceStart - segmentStart
        const length = sliceEnd - sliceStart
        if (segment.buffer) {
          slices.push(segment.buffer.subarray(localStart, localStart + length))
        } else {
          const read = readRange(segment.file, segment.fileStart + localStart, length)
          if (read.status === READ_FAILED) readError = readError || read.error
          slices.push(read.buffer)
        }
      }
      segmentStart = segmentEnd
    }
    let output = Buffer.concat(slices)
    // Page boundaries may fall inside a multi-byte scalar. Move forward to the
    // first UTF-8 boundary; the skipped continuation bytes remain available in
    // the preceding page, so pages still concatenate exactly as valid text.
    let skipped = 0
    while (skipped < output.length && (output[skipped] & 0xc0) === 0x80) skipped++
    if (skipped) {
      output = output.subarray(skipped)
      startByte += skipped
    }
    const truncation = this.truncationEvidence()
    return {
      output: output.toString('utf8'),
      startByte,
      endByte,
      totalBytes,
      hasMore: startByte > 0,
      // A page assembled over a segment we could not read is short by an
      // unknown amount, which is exactly what `truncated` already means.
      truncated: this.truncated || !!readError,
      ...(truncation ? { truncation } : {}),
      ...(readError ? { readError } : {}),
    }
  }

  stats() {
    return {
      id: this.id,
      visible: this.visible,
      ramBytes: this.chunksLen + this.queuedLen + this.fallbackLen,
      diskBytes: this._retainedDiskBytes(),
      diskError: this.diskError,
      viewState: this.viewState,
      historyQuota: this.historyQuota,
      totalHistoryQuota: this.totalHistoryQuota,
      truncation: this.truncationEvidence(),
      metaError: this.metaError,
      metaDirty: this.metaDirty,
    }
  }

  close({ remove = false } = {}) {
    if (this.closed) {
      return remove
        ? deleteSpoolArtifacts(this.file, this.prevFile, this.metaFile)
        : null
    }
    this.flush()
    this.persistMeta()
    // Late PTY output must not resurrect a closed spool: release() deletes
    // the files synchronously, but the kernel can still deliver buffered
    // onData afterwards through the pty handler's captured spool reference —
    // and a debounced append 750ms later would silently recreate the file
    // the user just asked to be wiped.
    this.closed = true
    // Deregister before any unlink: from here on these segments are an orphan
    // the directory sweep may reclaim, not a live terminal's tail.
    liveSpools.delete(this)
    if (this.appendTimer) {
      clearTimeout(this.appendTimer)
      this.appendTimer = null
    }
    this._clearMetaRetry()
    if (!remove) return null
    // Same as the fresh-start wipe: unlink drops our entry, so a swapped-in
    // link dies with the terminal and the file it named survives untouched.
    return deleteSpoolArtifacts(this.file, this.prevFile, this.metaFile)
  }
}

module.exports = {
  TerminalSpool,
  DEFAULT_DISK_CAP,
  DEFAULT_HOT_CAP,
  DEFAULT_SNAPSHOT_CAP,
  DEFAULT_QUEUE_CAP,
  DEFAULT_COLD_TAIL_CAP,
  DEFAULT_HISTORY_QUOTA,
  DEFAULT_TOTAL_HISTORY_QUOTA,
  QUOTA_WARN_RATIO,
  SPOOL_APPEND_DEBOUNCE_MS,
  READ_ABSENT,
  READ_EMPTY,
  READ_OK,
  READ_FAILED,
  META_RETRY_BASE_MS,
  META_RETRY_MAX_MS,
  META_RETRY_ATTEMPTS,
  SPOOL_DELETE_RETRY_ATTEMPTS,
  ensurePrivateSpoolDir,
  readTail,
  utf8Tail,
  readRange,
}
