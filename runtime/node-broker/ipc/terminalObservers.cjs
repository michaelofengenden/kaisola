'use strict'

const DEFAULT_OBSERVER_QUEUE_BYTES = 256 * 1024
const MIN_OBSERVER_QUEUE_BYTES = 64 * 1024
const MAX_OBSERVER_QUEUE_BYTES = 2 * 1024 * 1024
const MAX_TERMINAL_OBSERVERS = 8

function queueLimit(value) {
  if (!Number.isFinite(Number(value))) return DEFAULT_OBSERVER_QUEUE_BYTES
  return Math.max(MIN_OBSERVER_QUEUE_BYTES, Math.min(MAX_OBSERVER_QUEUE_BYTES, Math.floor(Number(value))))
}

class TerminalObservers {
  constructor({ terminalId, deliver }) {
    this.terminalId = String(terminalId)
    if (!this.terminalId || typeof deliver !== 'function') throw new Error('terminal observer dependencies are invalid')
    this.deliver = deliver
    this.subscribers = new Map()
  }

  subscribe(owner, { maxQueueBytes } = {}) {
    const key = String(owner || '')
    if (!key || key.length > 500) throw new Error('terminal subscriber is invalid')
    if (!this.subscribers.has(key) && this.subscribers.size >= MAX_TERMINAL_OBSERVERS) {
      throw new Error(`terminal observer limit of ${MAX_TERMINAL_OBSERVERS} reached`)
    }
    this.subscribers.set(key, { maxQueueBytes: queueLimit(maxQueueBytes), paused: false })
    return { subscriberCount: this.subscribers.size, maxQueueBytes: this.subscribers.get(key).maxQueueBytes }
  }

  unsubscribe(owner) {
    return this.subscribers.delete(String(owner || ''))
  }

  unsubscribePrefix(prefix) {
    const value = String(prefix || '')
    if (!value) return 0
    let removed = 0
    for (const owner of this.subscribers.keys()) {
      if (!owner.startsWith(value)) continue
      this.subscribers.delete(owner)
      removed++
    }
    return removed
  }

  broadcast(channel, payload, cursor = {}) {
    let delivered = 0
    let paused = 0
    for (const [owner, subscriber] of this.subscribers) {
      if (subscriber.paused) continue
      const ok = this.deliver(owner, channel, payload, { maxQueueBytes: subscriber.maxQueueBytes }) !== false
      if (ok) {
        delivered++
        continue
      }
      subscriber.paused = true
      paused++
      // One forced, small reset marker is the only permitted overflow. Future
      // deltas are discarded until an explicit resubscribe obtains a snapshot.
      this.deliver(owner, 'terminal:observer-snapshot-required', {
        id: this.terminalId,
        reason: 'slow_consumer',
        ...(cursor.streamEpoch ? { streamEpoch: cursor.streamEpoch } : {}),
        ...(Number.isSafeInteger(cursor.endOffset) ? { endOffset: cursor.endOffset } : {}),
      }, { force: true, maxQueueBytes: subscriber.maxQueueBytes })
    }
    return { delivered, paused }
  }

  stats() {
    return {
      subscribers: this.subscribers.size,
      paused: [...this.subscribers.values()].filter((subscriber) => subscriber.paused).length,
    }
  }
}

module.exports = {
  DEFAULT_OBSERVER_QUEUE_BYTES,
  MAX_OBSERVER_QUEUE_BYTES,
  MAX_TERMINAL_OBSERVERS,
  MIN_OBSERVER_QUEUE_BYTES,
  TerminalObservers,
  queueLimit,
}
