// Disk-backed terminal scrollback. A live/visible terminal keeps only the hot
// xterm-sized tail in RAM; once its renderer detaches, every byte is flushed to
// this spool and the pty continues without a hidden renderer or a megabyte ring.
// The pty is NEVER stopped by this class.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const intEnv = (name, fallback, min, max) => {
  const n = Number(process.env[name])
  return Number.isFinite(n) ? Math.min(max, Math.max(min, Math.round(n))) : fallback
}

const DEFAULT_DISK_CAP = intEnv('KAISOLA_TERMINAL_DISK_MB', 16, 2, 256) * 1024 * 1024
const DEFAULT_HOT_CAP = intEnv('KAISOLA_TERMINAL_HOT_KB', 1024, 128, 4096) * 1024
const DEFAULT_QUEUE_CAP = intEnv('KAISOLA_TERMINAL_SPOOL_BATCH_KB', 256, 32, 1024) * 1024

function safeBase(id) {
  return crypto.createHash('sha256').update(String(id)).digest('hex').slice(0, 32)
}

function atomicJson(file, value) {
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 })
  fs.renameSync(tmp, file)
  try { fs.chmodSync(file, 0o600) } catch { /* best effort */ }
}

function readTail(file, bytes) {
  if (!bytes || !fs.existsSync(file)) return ''
  let fd
  try {
    const size = fs.statSync(file).size
    const take = Math.min(size, bytes)
    if (!take) return ''
    const b = Buffer.allocUnsafe(take)
    fd = fs.openSync(file, 'r')
    fs.readSync(fd, b, 0, take, size - take)
    return b.toString('utf8')
  } catch {
    return ''
  } finally {
    if (fd != null) try { fs.closeSync(fd) } catch { /* noop */ }
  }
}

class TerminalSpool {
  constructor({ dir, id, diskCap = DEFAULT_DISK_CAP, hotCap = DEFAULT_HOT_CAP, queueCap = DEFAULT_QUEUE_CAP }) {
    this.id = String(id)
    this.diskCap = diskCap
    this.hotCap = hotCap
    this.queueCap = queueCap
    this.visible = true
    this.chunks = []
    this.chunksLen = 0
    this.queued = []
    this.queuedLen = 0
    this.truncated = false
    this.viewState = null
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
    const base = safeBase(this.id)
    this.file = path.join(dir, `${base}.log`)
    this.prevFile = path.join(dir, `${base}.prev.log`)
    this.metaFile = path.join(dir, `${base}.json`)
    this.fallbackChunks = []
    this.fallbackLen = 0
    this.diskError = null
    try {
      const m = JSON.parse(fs.readFileSync(this.metaFile, 'utf8'))
      if (m && m.id === this.id) this.viewState = m.viewState || null
    } catch { /* no prior state */ }
  }

  _queue(text) {
    if (!text) return
    this.queued.push(text)
    this.queuedLen += Buffer.byteLength(text)
    if (this.queuedLen >= this.queueCap) this.flush()
  }

  _append(text) {
    if (!text) return
    const recovery = this.fallbackChunks.join('')
    const payload = recovery + text
    let appended = false
    try {
      fs.appendFileSync(this.file, payload, { mode: 0o600 })
      appended = true
      this.fallbackChunks = []
      this.fallbackLen = 0
      this.diskError = null
      try { fs.chmodSync(this.file, 0o600) } catch { /* noop */ }
      const size = fs.statSync(this.file).size
      // Two bounded segments avoid rewriting a 12MB tail on Electron's main
      // thread. Rotation is a metadata rename; total history stays <= diskCap.
      if (size > Math.max(1, Math.floor(this.diskCap / 2))) {
        const discarded = fs.existsSync(this.prevFile)
        try { fs.unlinkSync(this.prevFile) } catch { /* first segment */ }
        fs.renameSync(this.file, this.prevFile)
        if (discarded) this.truncated = true
      }
    } catch (err) {
      this.diskError = String((err && err.code) || (err && err.message) || err || 'disk-write-failed')
      this.truncated = true
      // Disk-full/permission errors must never crash Electron main. If append
      // did not land, retain a bounded hot tail so the live shell stays usable.
      if (!appended) this._retainFallback(text)
    }
  }

  _retainFallback(text) {
    if (!text) return
    this.fallbackChunks.push(text)
    this.fallbackLen += Buffer.byteLength(text)
    while (this.fallbackChunks.length > 1 && this.fallbackLen > this.hotCap) {
      const old = this.fallbackChunks.shift()
      this.fallbackLen -= Buffer.byteLength(old)
    }
  }

  _diskTail(bytes) {
    if (!bytes) return ''
    const current = readTail(this.file, bytes)
    const remaining = Math.max(0, bytes - Buffer.byteLength(current))
    return (remaining ? readTail(this.prevFile, remaining) : '') + current
  }

  flush() {
    if (!this.queuedLen) return
    const text = this.queued.join('')
    this.queued = []
    this.queuedLen = 0
    this._append(text)
  }

  push(data) {
    if (!data) return
    if (!this.visible) {
      this._queue(data)
      return
    }
    this.chunks.push(data)
    this.chunksLen += Buffer.byteLength(data)
    while (this.chunks.length > 1 && this.chunksLen > this.hotCap) {
      const old = this.chunks.shift()
      this.chunksLen -= Buffer.byteLength(old)
      this._queue(old)
    }
  }

  setVisible(visible, viewState) {
    this.visible = !!visible
    if (viewState && typeof viewState === 'object') this.viewState = viewState
    if (!this.visible) {
      for (const chunk of this.chunks) this._queue(chunk)
      this.chunks = []
      this.chunksLen = 0
      this.flush()
      this.persistMeta()
    }
  }

  persistMeta() {
    try { atomicJson(this.metaFile, { id: this.id, viewState: this.viewState, touchedAt: Date.now() }) } catch { /* cache failure is non-fatal */ }
  }

  snapshot(outputCap = DEFAULT_HOT_CAP) {
    this.flush()
    const hot = this.chunks.join('')
    const hotBytes = Buffer.byteLength(hot)
    const fallback = this.fallbackChunks.join('')
    const liveBytes = Math.min(outputCap, hotBytes + Buffer.byteLength(fallback))
    const old = this._diskTail(Math.max(0, outputCap - liveBytes))
    let output = old + fallback + hot
    if (Buffer.byteLength(output) > outputCap) output = Buffer.from(output).subarray(-outputCap).toString('utf8')
    return { output, truncated: this.truncated, viewState: this.viewState }
  }

  stats() {
    let diskBytes = 0
    for (const file of [this.prevFile, this.file]) {
      try { diskBytes += fs.statSync(file).size } catch { /* absent */ }
    }
    return { id: this.id, visible: this.visible, ramBytes: this.chunksLen + this.queuedLen + this.fallbackLen, diskBytes, diskError: this.diskError, viewState: this.viewState }
  }

  close({ remove = false } = {}) {
    this.flush()
    this.persistMeta()
    if (!remove) return
    try { fs.unlinkSync(this.file) } catch { /* absent */ }
    try { fs.unlinkSync(this.prevFile) } catch { /* absent */ }
    try { fs.unlinkSync(this.metaFile) } catch { /* absent */ }
  }
}

module.exports = { TerminalSpool, DEFAULT_DISK_CAP, DEFAULT_HOT_CAP, DEFAULT_QUEUE_CAP, readTail }
