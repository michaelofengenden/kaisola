'use strict'

const crypto = require('node:crypto')
const { isPlainObject, validateIdentifier } = require('./protocol.cjs')

const DEFAULT_MAX_ENTRIES = 1_024
const DEFAULT_TTL_MS = 10 * 60 * 1_000
const FINGERPRINT_RE = /^[a-f0-9]{64}$/

class CompanionCommandCacheError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionCommandCacheError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionCommandCacheError(code, message)
}

function canonicalize(value, seen = new Set()) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('invalid_command', 'command contains a non-finite number')
    return value
  }
  if (!value || typeof value !== 'object') fail('invalid_command', 'command must be JSON serializable')
  if (seen.has(value)) fail('invalid_command', 'command contains a cycle')
  seen.add(value)
  let clean
  if (Array.isArray(value)) {
    clean = value.map((item) => canonicalize(item, seen))
  } else {
    if (!isPlainObject(value)) fail('invalid_command', 'command contains a non-plain object')
    clean = {}
    for (const key of Object.keys(value).sort()) clean[key] = canonicalize(value[key], seen)
  }
  seen.delete(value)
  return clean
}

function cloneJson(value, label) {
  let encoded
  try {
    encoded = JSON.stringify(value)
  } catch {
    fail('invalid_receipt', `${label} must be JSON serializable`)
  }
  if (encoded === undefined) fail('invalid_receipt', `${label} must be JSON serializable`)
  return JSON.parse(encoded)
}

function fingerprintCommand(command) {
  return crypto.createHash('sha256').update(JSON.stringify(canonicalize(command))).digest('hex')
}

function safeCommandId(value) {
  try {
    return validateIdentifier(value, 'commandId')
  } catch {
    fail('invalid_command_id', 'commandId is invalid')
  }
}

function safeFingerprint(value) {
  if (typeof value !== 'string' || !FINGERPRINT_RE.test(value)) fail('invalid_fingerprint', 'fingerprint is invalid')
  return value
}

class CompanionCommandCache {
  constructor({ maxEntries = DEFAULT_MAX_ENTRIES, ttlMs = DEFAULT_TTL_MS, now = Date.now } = {}) {
    if (!Number.isSafeInteger(maxEntries) || maxEntries < 1) fail('invalid_limit', 'maxEntries must be positive')
    if (!Number.isSafeInteger(ttlMs) || ttlMs < 1) fail('invalid_limit', 'ttlMs must be positive')
    if (typeof now !== 'function') fail('invalid_clock', 'now must be a function')
    this.maxEntries = maxEntries
    this.ttlMs = ttlMs
    this.now = now
    this.receipts = new Map()
    this.inFlight = new Map()
  }

  lookup({ commandId, fingerprint }) {
    safeCommandId(commandId)
    safeFingerprint(fingerprint)
    this.#purgeExpired()
    const entry = this.receipts.get(commandId)
    if (!entry) return null
    this.#assertSameFingerprint(commandId, entry.fingerprint, fingerprint)
    this.receipts.delete(commandId)
    this.receipts.set(commandId, entry)
    return cloneJson(entry.receipt, 'receipt')
  }

  remember({ commandId, fingerprint }, receipt) {
    safeCommandId(commandId)
    safeFingerprint(fingerprint)
    if (!isPlainObject(receipt)) fail('invalid_receipt', 'receipt must be an object')
    this.#purgeExpired()
    const existing = this.receipts.get(commandId)
    if (existing) this.#assertSameFingerprint(commandId, existing.fingerprint, fingerprint)
    const cleanReceipt = cloneJson(receipt, 'receipt')
    this.receipts.delete(commandId)
    this.receipts.set(commandId, {
      fingerprint,
      receipt: cleanReceipt,
      expiresAt: this.now() + this.ttlMs,
    })
    this.#trim()
    return cloneJson(cleanReceipt, 'receipt')
  }

  async execute(descriptor, executor) {
    const { commandId, fingerprint } = descriptor ?? {}
    safeCommandId(commandId)
    safeFingerprint(fingerprint)
    if (typeof executor !== 'function') fail('invalid_executor', 'executor must be a function')

    const cached = this.lookup({ commandId, fingerprint })
    if (cached) return cached
    const active = this.inFlight.get(commandId)
    if (active) {
      this.#assertSameFingerprint(commandId, active.fingerprint, fingerprint)
      return cloneJson(await active.promise, 'receipt')
    }

    let promise
    promise = Promise.resolve()
      .then(executor)
      .then((receipt) => this.remember({ commandId, fingerprint }, receipt))
      .finally(() => {
        if (this.inFlight.get(commandId)?.promise === promise) this.inFlight.delete(commandId)
      })
    this.inFlight.set(commandId, { fingerprint, promise })
    return cloneJson(await promise, 'receipt')
  }

  stats() {
    this.#purgeExpired()
    return {
      cachedReceipts: this.receipts.size,
      inFlightCommands: this.inFlight.size,
      maxEntries: this.maxEntries,
      ttlMs: this.ttlMs,
    }
  }

  #assertSameFingerprint(commandId, existing, requested) {
    if (existing !== requested) fail('command_id_conflict', `commandId ${commandId} was reused with different content`)
  }

  #purgeExpired() {
    const now = this.now()
    for (const [commandId, entry] of this.receipts) {
      if (entry.expiresAt <= now) this.receipts.delete(commandId)
    }
  }

  #trim() {
    while (this.receipts.size > this.maxEntries) {
      this.receipts.delete(this.receipts.keys().next().value)
    }
  }
}

module.exports = {
  CompanionCommandCache,
  CompanionCommandCacheError,
  DEFAULT_MAX_ENTRIES,
  DEFAULT_TTL_MS,
  fingerprintCommand,
}

