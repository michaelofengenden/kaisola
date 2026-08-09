'use strict'

// The native controller normally has only a handful of operations outstanding.
// These ceilings leave room for UI bursts while preventing one authenticated
// socket, or a collection of them, from retaining unbounded dispatch promises.
const DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT = 16
const DEFAULT_PROCESS_IN_FLIGHT_LIMIT = 128
const DEFAULT_MUTATION_LEDGER_ENTRIES = 512
const DEFAULT_MUTATION_LEDGER_BYTES = 64 * 1_024 * 1_024
const DEFAULT_MUTATION_LEDGER_TTL_MS = 60_000

function positiveInteger(value, name) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new TypeError(`${name} must be a positive integer`)
  return value
}

class BrokerRequestGate {
  constructor({
    perClientLimit = DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT,
    processLimit = DEFAULT_PROCESS_IN_FLIGHT_LIMIT,
  } = {}) {
    this.perClientLimit = positiveInteger(perClientLimit, 'per-client request limit')
    this.processLimit = positiveInteger(processLimit, 'process request limit')
    this.clientInFlight = new WeakMap()
    this.processInFlight = 0
  }

  acquire(client) {
    if ((typeof client !== 'object' && typeof client !== 'function') || client === null) {
      throw new TypeError('broker request client identity must be an object')
    }
    const clientCount = this.clientInFlight.get(client) || 0
    if (clientCount >= this.perClientLimit) {
      return {
        ok: false,
        code: 'broker_overloaded',
        scope: 'client',
        limit: this.perClientLimit,
        message: 'broker request capacity exceeded',
      }
    }
    if (this.processInFlight >= this.processLimit) {
      return {
        ok: false,
        code: 'broker_overloaded',
        scope: 'process',
        limit: this.processLimit,
        message: 'broker request capacity exceeded',
      }
    }

    this.clientInFlight.set(client, clientCount + 1)
    this.processInFlight += 1
    let released = false
    return {
      ok: true,
      release: () => {
        if (released) return false
        released = true
        const current = this.clientInFlight.get(client) || 0
        if (current <= 1) this.clientInFlight.delete(client)
        else this.clientInFlight.set(client, current - 1)
        this.processInFlight = Math.max(0, this.processInFlight - 1)
        return true
      },
    }
  }
}

/** Bounded process-wide mutation receipts. A reconnecting controller keeps its
 * instance id, so a retry can join an in-flight mutation or replay its exact
 * settled result without applying the operation twice. */
class BrokerMutationLedger {
  constructor({
    maximumEntries = DEFAULT_MUTATION_LEDGER_ENTRIES,
    maximumBytes = DEFAULT_MUTATION_LEDGER_BYTES,
    ttlMs = DEFAULT_MUTATION_LEDGER_TTL_MS,
    now = Date.now,
  } = {}) {
    this.maximumEntries = positiveInteger(maximumEntries, 'mutation ledger entry limit')
    this.maximumBytes = positiveInteger(maximumBytes, 'mutation ledger byte limit')
    this.ttlMs = positiveInteger(ttlMs, 'mutation ledger ttl')
    this.now = now
    this.entries = new Map()
    this.retainedBytes = 0
  }

  lookup(key, fingerprint) {
    this._pruneExpired()
    const entry = this.entries.get(key)
    if (entry) {
      if (entry.fingerprint !== fingerprint) return { status: 'conflict' }
      this.entries.delete(key)
      this.entries.set(key, entry)
      return { status: 'replay', promise: entry.promise }
    }
    while (this.entries.size >= this.maximumEntries && this._evictOldestSettled()) {}
    if (this.entries.size >= this.maximumEntries) return { status: 'full' }
    return { status: 'new' }
  }

  retain(key, fingerprint, promise) {
    const entry = { fingerprint, promise, settledAt: null, bytes: 0 }
    this.entries.set(key, entry)
    void promise.then(
      (result) => this._settle(key, entry, { ok: true, result }),
      (error) => this._settle(key, entry, {
        ok: false,
        message: String(error?.message || error),
      }),
    )
  }

  _settle(key, entry, receipt) {
    if (this.entries.get(key) !== entry) return
    entry.settledAt = this.now()
    try { entry.bytes = Buffer.byteLength(JSON.stringify(receipt)) } catch { entry.bytes = this.maximumBytes + 1 }
    this.retainedBytes += entry.bytes
    while (this.retainedBytes > this.maximumBytes && this._evictOldestSettled()) {}
  }

  _pruneExpired() {
    const cutoff = this.now() - this.ttlMs
    for (const [key, entry] of this.entries) {
      if (entry.settledAt == null || entry.settledAt > cutoff) continue
      this._delete(key, entry)
    }
  }

  _evictOldestSettled() {
    for (const [key, entry] of this.entries) {
      if (entry.settledAt == null) continue
      this._delete(key, entry)
      return true
    }
    return false
  }

  _delete(key, entry) {
    if (!this.entries.delete(key)) return
    this.retainedBytes = Math.max(0, this.retainedBytes - entry.bytes)
  }
}

/** Admit and settle one already-authenticated request. Kept outside the broker
 * executable so overload and release ordering can be tested without sockets or
 * PTYs. Returns false only for a synchronous capacity rejection. */
function dispatchBrokerRequest({
  gate,
  client,
  requestID,
  mutating,
  dispatch,
  beginMutation,
  endMutation,
  respond,
  onSuccess,
  idempotency,
}) {
  if (idempotency) {
    const prior = idempotency.ledger.lookup(idempotency.key, idempotency.fingerprint)
    if (prior.status === 'conflict') {
      respond({
        type: 'response', id: requestID, ok: false,
        code: 'mutation_id_reused', message: 'broker mutation id was reused with different parameters',
      })
      return false
    }
    if (prior.status === 'full') {
      respond({
        type: 'response', id: requestID, ok: false,
        code: 'mutation_ledger_full', message: 'broker mutation reconciliation capacity exceeded',
      })
      return false
    }
    if (prior.status === 'replay') {
      void prior.promise.then(
        (result) => respond({ type: 'response', id: requestID, ok: true, result }),
        (error) => respond({
          type: 'response', id: requestID, ok: false,
          message: String(error?.message || error),
        }),
      )
      return true
    }
  }

  const admission = gate.acquire(client)
  if (!admission.ok) {
    respond({ type: 'response', id: requestID, ok: false, ...admission })
    return false
  }

  let mutationBegan = false
  let operation
  try {
    if (mutating) {
      beginMutation()
      mutationBegan = true
    }
    // Preserve the broker's existing immediate dispatch ordering. Wrapping a
    // synchronous throw still gives the shared settlement path one Promise.
    operation = Promise.resolve(dispatch())
  } catch (error) {
    operation = Promise.reject(error)
  }
  if (idempotency) idempotency.ledger.retain(idempotency.key, idempotency.fingerprint, operation)

  void operation.finally(() => {
    try {
      if (mutationBegan) endMutation()
    } finally {
      // Accounting must never leak even if a diagnostic mutation hook fails.
      admission.release()
    }
  }).then(
    (result) => {
      respond({ type: 'response', id: requestID, ok: true, result })
      onSuccess?.()
    },
    (error) => respond({
      type: 'response',
      id: requestID,
      ok: false,
      message: String(error?.message || error),
    }),
  )
  return true
}

module.exports = {
  BrokerRequestGate,
  BrokerMutationLedger,
  DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT,
  DEFAULT_PROCESS_IN_FLIGHT_LIMIT,
  DEFAULT_MUTATION_LEDGER_ENTRIES,
  DEFAULT_MUTATION_LEDGER_BYTES,
  DEFAULT_MUTATION_LEDGER_TTL_MS,
  dispatchBrokerRequest,
}
