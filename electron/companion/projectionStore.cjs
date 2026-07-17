'use strict'

const { sanitizeProjection } = require('./redaction.cjs')
const { validateIdentifier } = require('./protocol.cjs')

const STORE_VERSION = 2
const STORE_PREFIX = 'kaisola-companion-projection:'
const MAX_RECORD_BYTES = 640 * 1024

class CompanionProjectionStoreError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionProjectionStoreError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionProjectionStoreError(code, message)
}

function safeId(value, label) {
  try {
    return validateIdentifier(value, label, 160)
  } catch {
    fail('invalid_id', `${label} is invalid`)
  }
}

function safeGeneration(value) {
  if (!Number.isSafeInteger(value) || value < 1) fail('invalid_publisher', 'publisherGeneration is invalid')
  return value
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value))
}

function projectionStoreKey(windowId) {
  return `${STORE_PREFIX}${safeId(windowId, 'windowId')}`
}

class CompanionProjectionStore {
  constructor({ epoch, get, set, del = () => {}, keys = () => [], now = Date.now }) {
    this.epoch = safeId(epoch, 'epoch')
    if (typeof get !== 'function' || typeof set !== 'function' || typeof del !== 'function' || typeof keys !== 'function') {
      fail('invalid_storage', 'projection storage is invalid')
    }
    if (typeof now !== 'function') fail('invalid_clock', 'projection clock is invalid')
    this.get = get
    this.set = set
    this.del = del
    this.keys = keys
    this.now = now
  }

  publish({ windowId, publisherGeneration, projection }) {
    const id = safeId(windowId, 'windowId')
    const generation = safeGeneration(publisherGeneration)
    const key = projectionStoreKey(id)
    const existing = this.#readRecord(key)
    if (existing?.epoch === this.epoch) {
      if (generation < existing.publisherGeneration) {
        return { ok: false, stale: true, reason: 'stale_publisher', revision: existing.projection.revision }
      }
      if (generation === existing.publisherGeneration && projection?.revision <= existing.projection.revision) {
        return {
          ok: true,
          duplicate: projection?.revision === existing.projection.revision,
          stale: projection?.revision < existing.projection.revision,
          revision: existing.projection.revision,
        }
      }
    }

    const clean = sanitizeProjection({ ...projection, generatedAt: this.now(), freshness: 'live' })
    const record = {
      storeVersion: STORE_VERSION,
      windowId: id,
      epoch: this.epoch,
      publisherGeneration: generation,
      active: true,
      savedAt: this.now(),
      projection: clean,
    }
    const encoded = JSON.stringify(record)
    if (Buffer.byteLength(encoded, 'utf8') > MAX_RECORD_BYTES) fail('record_too_large', 'projection record exceeds its storage cap')
    this.set(key, encoded)
    return { ok: true, revision: clean.revision, projection: cloneJson(clean) }
  }

  load(windowId) {
    const id = safeId(windowId, 'windowId')
    const record = this.#readRecord(projectionStoreKey(id))
    if (!record) return null
    const freshness = record.epoch === this.epoch && record.active ? 'live' : 'stale'
    return {
      windowId: id,
      epoch: record.epoch,
      publisherGeneration: record.publisherGeneration,
      active: record.active,
      savedAt: record.savedAt,
      projection: { ...cloneJson(record.projection), freshness },
    }
  }

  list() {
    const prefix = STORE_PREFIX
    const out = []
    for (const key of this.keys()) {
      if (typeof key !== 'string' || !key.startsWith(prefix)) continue
      const windowId = key.slice(prefix.length)
      try {
        const loaded = this.load(windowId)
        if (loaded) out.push(loaded)
      } catch { /* one corrupt window cannot hide the others */ }
    }
    return out.sort((a, b) => b.savedAt - a.savedAt || a.windowId.localeCompare(b.windowId))
  }

  delete(windowId) {
    this.del(projectionStoreKey(windowId))
  }

  markStale(windowId, publisherGeneration) {
    const id = safeId(windowId, 'windowId')
    const generation = safeGeneration(publisherGeneration)
    const key = projectionStoreKey(id)
    const record = this.#readRecord(key)
    if (!record || record.epoch !== this.epoch || record.publisherGeneration !== generation || !record.active) return false
    const next = {
      storeVersion: STORE_VERSION,
      windowId: id,
      epoch: record.epoch,
      publisherGeneration: record.publisherGeneration,
      active: false,
      savedAt: this.now(),
      projection: { ...record.projection, freshness: 'stale' },
    }
    this.set(key, JSON.stringify(next))
    return true
  }

  #readRecord(key) {
    const raw = this.get(key)
    if (raw == null) return null
    if (typeof raw !== 'string' || Buffer.byteLength(raw, 'utf8') > MAX_RECORD_BYTES) return null
    let parsed
    try { parsed = JSON.parse(raw) } catch { return null }
    if (!parsed || parsed.storeVersion !== STORE_VERSION || typeof parsed !== 'object') return null
    try {
      const windowId = safeId(parsed.windowId, 'windowId')
      const epoch = safeId(parsed.epoch, 'epoch')
      const publisherGeneration = safeGeneration(parsed.publisherGeneration)
      if (!Number.isSafeInteger(parsed.savedAt) || parsed.savedAt < 0) return null
      const projection = sanitizeProjection(parsed.projection)
      return { windowId, epoch, publisherGeneration, active: parsed.active === true, savedAt: parsed.savedAt, projection }
    } catch {
      return null
    }
  }
}

module.exports = {
  CompanionProjectionStore,
  CompanionProjectionStoreError,
  MAX_RECORD_BYTES,
  STORE_PREFIX,
  STORE_VERSION,
  projectionStoreKey,
}
