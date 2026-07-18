'use strict'

const crypto = require('node:crypto')
const { EVENT_TYPES, isPlainObject, validateIdentifier } = require('./protocol.cjs')

const DEFAULT_MAX_EVENTS = 2_048
const DEFAULT_MAX_BYTES = 2 * 1024 * 1024

class CompanionEventLogError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionEventLogError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionEventLogError(code, message)
}

function safeInteger(value, label, { min = 0 } = {}) {
  if (!Number.isSafeInteger(value) || value < min) fail('invalid_cursor', `${label} is invalid`)
  return value
}

function safeLimit(value, label) {
  if (!Number.isSafeInteger(value) || value < 1) fail('invalid_limit', `${label} must be a positive integer`)
  return value
}

function encodeJson(value, label) {
  let encoded
  try {
    encoded = JSON.stringify(value)
  } catch {
    fail('invalid_event', `${label} must be JSON serializable`)
  }
  if (encoded === undefined) fail('invalid_event', `${label} must be JSON serializable`)
  return encoded
}

function safeId(value, label) {
  try {
    return validateIdentifier(value, label)
  } catch {
    fail('invalid_id', `${label} is invalid`)
  }
}

class CompanionEventLog {
  constructor({
    epoch = crypto.randomUUID(),
    maxEvents = DEFAULT_MAX_EVENTS,
    maxBytes = DEFAULT_MAX_BYTES,
  } = {}) {
    this.epoch = safeId(epoch, 'epoch')
    this.maxEvents = safeLimit(maxEvents, 'maxEvents')
    this.maxBytes = safeLimit(maxBytes, 'maxBytes')
    this.events = []
    this.totalBytes = 0
    this.currentSeq = 0
    this.droppedThrough = 0
    this.acknowledgements = new Map()
  }

  append({ type, payload = {}, id, at = Date.now() }) {
    if (!EVENT_TYPES.has(type)) fail('unknown_event', `unsupported event type: ${String(type || '')}`)
    if (!isPlainObject(payload)) fail('invalid_event', 'payload must be an object')
    safeInteger(at, 'at')

    const seq = this.currentSeq + 1
    const eventId = id == null ? `event-${seq}` : safeId(id, 'id')
    const encoded = encodeJson({ epoch: this.epoch, seq, id: eventId, at, type, payload }, 'event')
    const bytes = Buffer.byteLength(encoded, 'utf8')
    if (bytes > this.maxBytes) fail('event_too_large', 'event exceeds the replay byte limit')

    this.currentSeq = seq
    this.events.push({ seq, encoded, bytes })
    this.totalBytes += bytes
    this.#trimToLimits()
    return JSON.parse(encoded)
  }

  /** Advance the durable cursor without retaining or serializing a payload.
   * The next client behind this boundary receives a coherent snapshot. */
  invalidate() {
    this.currentSeq++
    this.droppedThrough = this.currentSeq
    this.events = []
    this.totalBytes = 0
    return this.currentSeq
  }

  replay({ epoch, afterSeq }) {
    safeId(epoch, 'epoch')
    safeInteger(afterSeq, 'afterSeq')
    if (epoch !== this.epoch) return this.#snapshotRequired('epoch_mismatch')
    if (afterSeq > this.currentSeq) return this.#snapshotRequired('cursor_ahead')
    if (afterSeq < this.droppedThrough) return this.#snapshotRequired('event_gap')

    const events = this.events
      .filter((event) => event.seq > afterSeq)
      .map((event) => JSON.parse(event.encoded))
    return {
      kind: 'replay',
      epoch: this.epoch,
      fromSeq: afterSeq + 1,
      toSeq: this.currentSeq,
      events,
    }
  }

  acknowledge(clientId, seq) {
    safeId(clientId, 'clientId')
    safeInteger(seq, 'seq')
    if (seq > this.currentSeq) fail('cursor_ahead', 'acknowledgement is ahead of the event log')
    const previous = this.acknowledgements.get(clientId) ?? 0
    const acknowledged = Math.max(previous, seq)
    this.acknowledgements.set(clientId, acknowledged)
    return acknowledged
  }

  pruneAcknowledged() {
    if (this.acknowledgements.size === 0) return 0
    const pruneThrough = Math.min(...this.acknowledgements.values())
    let pruned = 0
    while (this.events.length > 0 && this.events[0].seq <= pruneThrough) {
      const removed = this.events.shift()
      this.totalBytes -= removed.bytes
      this.droppedThrough = Math.max(this.droppedThrough, removed.seq)
      pruned++
    }
    return pruned
  }

  dropClient(clientId) {
    safeId(clientId, 'clientId')
    return this.acknowledgements.delete(clientId)
  }

  stats() {
    return {
      epoch: this.epoch,
      currentSeq: this.currentSeq,
      droppedThrough: this.droppedThrough,
      earliestSeq: this.events[0]?.seq ?? this.currentSeq + 1,
      retainedEvents: this.events.length,
      retainedBytes: this.totalBytes,
      activeClients: this.acknowledgements.size,
      maxEvents: this.maxEvents,
      maxBytes: this.maxBytes,
    }
  }

  #snapshotRequired(reason) {
    return {
      kind: 'snapshot_required',
      reason,
      epoch: this.epoch,
      currentSeq: this.currentSeq,
      earliestSeq: this.events[0]?.seq ?? this.currentSeq + 1,
    }
  }

  #trimToLimits() {
    while (this.events.length > this.maxEvents || this.totalBytes > this.maxBytes) {
      const removed = this.events.shift()
      this.totalBytes -= removed.bytes
      this.droppedThrough = Math.max(this.droppedThrough, removed.seq)
    }
  }
}

module.exports = {
  CompanionEventLog,
  CompanionEventLogError,
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_EVENTS,
}
