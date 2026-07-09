// Append-only disk archive for Assistant turns outside the renderer's recent
// working set. Writes are acknowledged only after fsync; retrying the same
// batch is idempotent, and stale metadata is rebuilt from the JSONL log.
const crypto = require('node:crypto')
const fs = require('node:fs')
const fsp = require('node:fs/promises')
const path = require('node:path')
const readline = require('node:readline')

const MAX_BATCH_TURNS = 100
const MAX_BATCH_BYTES = 24 * 1024 * 1024
const MAX_RECORD_BYTES = MAX_BATCH_BYTES + 1024
const MAX_PAGE_BYTES = 24 * 1024 * 1024
const MAX_PENDING_BYTES = 32 * 1024 * 1024

const safeId = (id) => crypto.createHash('sha256').update(String(id)).digest('hex').slice(0, 40)
const cleanPart = (value) => typeof value === 'string' && value.length > 0 && value.length <= 240 ? value : null
const scopeKey = (scope) => {
  const projectId = cleanPart(scope?.projectId)
  const threadId = cleanPart(scope?.threadId)
  const epoch = scope?.epoch == null ? '0' : cleanPart(scope.epoch)
  return projectId && threadId && epoch ? JSON.stringify([projectId, threadId, epoch]) : null
}
const decodeRecord = (line) => {
  const parsed = JSON.parse(line)
  if (parsed && typeof parsed === 'object' && parsed.v === 2 && typeof parsed.batchId === 'string' && Array.isArray(parsed.turns)) {
    return { batchId: parsed.batchId, turns: parsed.turns.filter((turn) => turn && typeof turn === 'object') }
  }
  // Compatibility with the short-lived per-turn v1 development format.
  if (parsed && typeof parsed === 'object' && parsed.v === 1 && typeof parsed.batchId === 'string' && parsed.turn && typeof parsed.turn === 'object') {
    return { batchId: parsed.batchId, turns: [parsed.turn] }
  }
  // Compatibility with the first development archive format.
  if (parsed && typeof parsed === 'object') return { batchId: null, turns: [parsed] }
  return null
}

class AssistantArchive {
  constructor(dir) {
    this.dir = dir
    this.queues = new Map()
    this.pendingBytes = 0
  }

  files(key) {
    const base = safeId(key)
    return { log: path.join(this.dir, `${base}.jsonl`), meta: path.join(this.dir, `${base}.json`) }
  }

  async ensure() {
    const created = await fsp.mkdir(this.dir, { recursive: true, mode: 0o700 })
    try { await fsp.chmod(this.dir, 0o700) } catch { /* best effort */ }
    if (created) await this.syncDir(path.dirname(this.dir))
  }

  /** fsync the containing directory after create/rename/unlink. Windows does
   * not expose portable directory handles; those explicit unsupported errors
   * degrade safely, while real macOS/Linux I/O failures reject before ACK. */
  async syncDir(dir = this.dir, allowMissing = false) {
    let handle
    try {
      handle = await fsp.open(dir, 'r')
      await handle.sync()
    } catch (err) {
      if (allowMissing && err?.code === 'ENOENT') return
      if (process.platform === 'win32' && ['EISDIR', 'EPERM', 'EINVAL', 'ENOTSUP'].includes(err?.code)) return
      throw err
    } finally {
      await handle?.close().catch(() => {})
    }
  }

  enqueue(key, task) {
    const prior = this.queues.get(key) || Promise.resolve()
    const next = prior.catch(() => {}).then(task)
    this.queues.set(key, next)
    const cleanup = () => { if (this.queues.get(key) === next) this.queues.delete(key) }
    void next.then(cleanup, cleanup)
    return next
  }

  async writeMeta(key, value) {
    await this.ensure()
    const file = this.files(key).meta
    const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`
    const handle = await fsp.open(tmp, 'w', 0o600)
    try {
      await handle.writeFile(JSON.stringify(value))
      await handle.sync()
    } finally {
      await handle.close()
    }
    await fsp.rename(tmp, file)
    try { await fsp.chmod(file, 0o600) } catch { /* best effort */ }
    await this.syncDir()
  }

  /** Rebuild count/idempotency data without hydrating turns. A non-newline
   * tail is an interrupted append and is truncated before the next retry. */
  async scanLog(key) {
    const file = this.files(key).log
    const batches = new Set()
    let count = 0
    let bytesRead = 0
    let completeBytes = 0
    let parts = []
    let pendingBytes = 0
    try {
      const stream = fs.createReadStream(file)
      for await (const raw of stream) {
        const chunk = Buffer.isBuffer(raw) ? raw : Buffer.from(raw)
        bytesRead += chunk.length
        let offset = 0
        let newline
        while ((newline = chunk.indexOf(0x0a, offset)) >= 0) {
          const tail = chunk.subarray(offset, newline)
          const lineBytes = pendingBytes + tail.length
          const line = parts.length ? Buffer.concat([...parts, tail], lineBytes) : tail
          completeBytes += lineBytes + 1
          parts = []
          pendingBytes = 0
          offset = newline + 1
          if (!line.length || line.length > MAX_RECORD_BYTES) continue
          try {
            const record = decodeRecord(line.toString('utf8'))
            if (!record) continue
            count += record.turns.length
            if (record.batchId) batches.add(record.batchId)
          } catch { /* corrupt complete line: skip, later records stay readable */ }
        }
        if (offset < chunk.length) {
          const tail = chunk.subarray(offset)
          parts.push(tail)
          pendingBytes += tail.length
        }
        // Generated records are bounded. An unterminated oversized tail can
        // only be corruption/interrupted input; stop retaining it in memory.
        if (pendingBytes > MAX_RECORD_BYTES) break
      }
    } catch (err) {
      if (err?.code !== 'ENOENT') throw err
      return { key, count: 0, bytes: 0, batches: [], updatedAt: Date.now() }
    }
    if (pendingBytes || completeBytes < bytesRead) {
      await fsp.truncate(file, completeBytes)
      bytesRead = completeBytes
    }
    return { key, count, bytes: bytesRead, batches: [...batches], updatedAt: Date.now() }
  }

  async meta(key) {
    const files = this.files(key)
    let stored = null
    try { stored = JSON.parse(await fsp.readFile(files.meta, 'utf8')) } catch { /* reconcile below */ }
    let size = 0
    try { size = (await fsp.stat(files.log)).size } catch (err) { if (err?.code !== 'ENOENT') throw err }
    if (
      stored?.key === key && Number.isInteger(stored.count) && stored.count >= 0 &&
      Number.isInteger(stored.bytes) && stored.bytes === size && Array.isArray(stored.batches)
    ) return stored
    const rebuilt = await this.scanLog(key)
    if (rebuilt.bytes || stored) await this.writeMeta(key, rebuilt)
    return rebuilt
  }

  append(key, batchId, turns) {
    if (typeof key !== 'string' || !key || typeof batchId !== 'string' || !batchId || batchId.length > 240 || !Array.isArray(turns) || !turns.length) {
      return Promise.resolve({ ok: false, message: 'Invalid archive batch.' })
    }
    if (turns.length > MAX_BATCH_TURNS) return Promise.resolve({ ok: false, message: `Archive batches are limited to ${MAX_BATCH_TURNS} turns.` })
    const turnCount = turns.length
    // The production renderer already allows only one ACK-gated batch per
    // thread. Reject a second same-key request before serialization so a buggy
    // or hostile caller cannot build an unbounded retained promise chain.
    if (this.queues.has(key)) return Promise.resolve({ ok: false, retryable: true, message: 'Archive key is busy; retry after the current write.' })
    let payload
    try {
      payload = Buffer.from(JSON.stringify({ v: 2, batchId, turns }) + '\n')
      if (payload.length > MAX_BATCH_BYTES) return Promise.resolve({ ok: false, message: 'Archive batch exceeds the safe byte limit.' })
    } catch {
      return Promise.resolve({ ok: false, message: 'Archive batch could not be serialized.' })
    }
    turns = null // payload is the bounded durable representation; release IPC objects before queuing
    if (this.pendingBytes + payload.length > MAX_PENDING_BYTES) {
      return Promise.resolve({ ok: false, retryable: true, message: 'Archive write backlog is full; retry shortly.' })
    }
    this.pendingBytes += payload.length
    const operation = this.enqueue(key, async () => {
      await this.ensure()
      const files = this.files(key)
      const before = await this.meta(key)
      if (before.batches.includes(batchId)) return { ok: true, count: before.count, duplicate: true }
      const handle = await fsp.open(files.log, 'a', 0o600)
      try {
        await handle.writeFile(payload)
        await handle.sync()
      } finally {
        await handle.close()
      }
      try { await fsp.chmod(files.log, 0o600) } catch { /* best effort */ }
      await this.syncDir()
      const next = {
        key,
        count: before.count + turnCount,
        bytes: before.bytes + payload.length,
        batches: [...before.batches, batchId],
        updatedAt: Date.now(),
      }
      await this.writeMeta(key, next)
      return { ok: true, count: next.count }
    })
    const release = () => { this.pendingBytes = Math.max(0, this.pendingBytes - payload.length) }
    return operation.then(
      (result) => { release(); return result },
      (error) => { release(); throw error },
    )
  }

  info(key) {
    if (typeof key !== 'string' || !key) return Promise.resolve({ ok: false, total: 0 })
    return this.enqueue(key, async () => {
      const meta = await this.meta(key)
      return { ok: true, total: meta.count }
    })
  }

  page(key, before, limit = 60) {
    if (typeof key !== 'string' || !key) return Promise.resolve({ ok: false, turns: [], before: 0, total: 0, hasMore: false })
    return this.enqueue(key, async () => {
      const meta = await this.meta(key)
      const end = Math.max(0, Math.min(meta.count, Number.isFinite(Number(before)) ? Math.floor(Number(before)) : meta.count))
      const take = Math.max(1, Math.min(100, Math.floor(Number(limit) || 60)))
      const requestedStart = Math.max(0, end - take)
      const records = []
      let index = 0
      let pageBytes = 0
      let actualStart = requestedStart
      try {
        const stream = fs.createReadStream(this.files(key).log, { encoding: 'utf8' })
        const lines = readline.createInterface({ input: stream, crlfDelay: Infinity })
        outer: for await (const line of lines) {
          if (!line.trim()) continue
          let record
          try { record = decodeRecord(line) } catch { continue }
          if (!record) continue
          for (const turn of record.turns) {
            if (index >= end) break outer
            if (index >= requestedStart) {
              let bytes
              try { bytes = Buffer.byteLength(JSON.stringify(turn)) } catch { index++; continue }
              records.push({ index, turn, bytes })
              pageBytes += bytes
              while (records.length > 1 && pageBytes > MAX_PAGE_BYTES) pageBytes -= records.shift().bytes
              actualStart = records[0]?.index ?? end
            }
            index++
          }
        }
        lines.close()
        stream.destroy()
      } catch (err) {
        if (err?.code !== 'ENOENT') throw err
      }
      return {
        ok: true,
        turns: records.map((record) => record.turn),
        before: actualStart,
        total: meta.count,
        hasMore: actualStart > 0,
        bytes: pageBytes,
      }
    })
  }

  clear(key) {
    if (typeof key !== 'string' || !key) return Promise.resolve({ ok: false })
    return this.enqueue(key, async () => {
      const unlink = async (file) => {
        try { await fsp.unlink(file) } catch (err) { if (err?.code !== 'ENOENT') throw err }
      }
      const files = this.files(key)
      await Promise.all([unlink(files.log), unlink(files.meta)])
      await this.syncDir(this.dir, true)
      return { ok: true }
    })
  }

  async flush() {
    await Promise.allSettled([...this.queues.values()])
  }
}

function registerAssistantArchiveHandlers(ipcMain, dir) {
  const archive = new AssistantArchive(dir)
  ipcMain.handle('assistant-archive:append', (_event, { scope, batchId, turns } = {}) => {
    const key = scopeKey(scope)
    return key ? archive.append(key, batchId, turns).catch((err) => ({ ok: false, message: String(err?.message || err) })) : { ok: false, message: 'Invalid archive scope.' }
  })
  ipcMain.handle('assistant-archive:info', (_event, { scope } = {}) => {
    const key = scopeKey(scope)
    return key ? archive.info(key).catch((err) => ({ ok: false, total: 0, message: String(err?.message || err) })) : { ok: false, total: 0 }
  })
  ipcMain.handle('assistant-archive:page', (_event, { scope, before, limit } = {}) => {
    const key = scopeKey(scope)
    return key ? archive.page(key, before, limit).catch((err) => ({ ok: false, turns: [], message: String(err?.message || err) })) : { ok: false, turns: [] }
  })
  ipcMain.handle('assistant-archive:clear', (_event, { scope } = {}) => {
    const key = scopeKey(scope)
    return key ? archive.clear(key).catch((err) => ({ ok: false, message: String(err?.message || err) })) : { ok: false }
  })
  return archive
}

module.exports = { AssistantArchive, registerAssistantArchiveHandlers, scopeKey }
